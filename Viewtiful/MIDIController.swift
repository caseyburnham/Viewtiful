import CoreMIDI
import Foundation
import Observation

enum MIDINavigationAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case nextPage
    case previousPage
    case firstPage
    case lastPage

    var id: Self { self }

    var title: String {
        switch self {
        case .nextPage: "Next Page"
        case .previousPage: "Previous Page"
        case .firstPage: "First Page"
        case .lastPage: "Last Page"
        }
    }

    var viewtifulAction: ViewtifulAction {
        switch self {
        case .nextPage: .nextPage
        case .previousPage: .previousPage
        case .firstPage: .firstPage
        case .lastPage: .lastPage
        }
    }
}

struct MIDITrigger: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case note
        case controlChange
        case programChange
    }

    let kind: Kind
    let channel: UInt8
    let number: UInt8

    var description: String {
        let kindName = switch kind {
        case .note: "Note"
        case .controlChange: "CC"
        case .programChange: "Program"
        }
        return "Ch \(channel + 1) · \(kindName) \(number)"
    }
}

struct MIDIInputSource: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
}

struct MIDIActivity: Equatable, Sendable {
    let source: String
    let channel: UInt8
    let kind: MIDITrigger.Kind
    let number: UInt8
    let value: UInt8
    let received: Date

    var description: String {
        let kindName = switch kind {
        case .note: "Note On"
        case .controlChange: "Control Change"
        case .programChange: "Program Change"
        }
        return "\(source) · Ch \(channel + 1) · \(kindName) \(number) · \(value)"
    }
}

@MainActor
@Observable
final class MIDIController: @unchecked Sendable {
    var channelFilter: Int {
        didSet {
            UserDefaults.standard.set(channelFilter, forKey: Keys.channelFilter)
        }
    }

    var programChangeRecallEnabled: Bool {
        didSet {
            UserDefaults.standard.set(programChangeRecallEnabled, forKey: Keys.programRecall)
        }
    }

    var programChangeOffset: Int {
        didSet {
            UserDefaults.standard.set(programChangeOffset, forKey: Keys.programOffset)
        }
    }

    private(set) var sources: [MIDIInputSource] = []
    private(set) var bindings: [MIDINavigationAction: MIDITrigger] = [:]
    private(set) var learningAction: MIDINavigationAction?
    private(set) var lastActivity: MIDIActivity?
    private(set) var setupError: String?

    @ObservationIgnored var onAction: ((ViewtifulAction) -> Void)?
    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var inputPort = MIDIPortRef()
    @ObservationIgnored private var sourceContexts: [UnsafeMutableRawPointer] = []
    @ObservationIgnored private var connectedSources: [MIDIEndpointRef] = []
    @ObservationIgnored private var activeCCs: Set<String> = []

    init() {
        channelFilter = UserDefaults.standard.integer(forKey: Keys.channelFilter)
        programChangeRecallEnabled = UserDefaults.standard.bool(forKey: Keys.programRecall)
        programChangeOffset = UserDefaults.standard.integer(forKey: Keys.programOffset)
        loadBindings()
        setup()
    }

    deinit {
        let port = inputPort
        if port != 0 {
            connectedSources.forEach { MIDIPortDisconnectSource(port, $0) }
        }
        sourceContexts.forEach {
            Unmanaged<SourceContext>.fromOpaque($0).release()
        }
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    func beginLearning(_ action: MIDINavigationAction) {
        learningAction = action
    }

    func cancelLearning() {
        learningAction = nil
    }

    func clearBinding(_ action: MIDINavigationAction) {
        bindings.removeValue(forKey: action)
        saveBindings()
    }

    private func setup() {
        let controller = self
        let clientStatus = MIDIClientCreateWithBlock("Viewtiful" as CFString, &client) { _ in
            Task { @MainActor in
                controller.refreshSources()
            }
        }
        guard clientStatus == noErr else {
            setupError = "Core MIDI client unavailable (\(clientStatus))."
            return
        }

        let portStatus = MIDIInputPortCreateWithProtocol(
            client,
            "Viewtiful Input" as CFString,
            ._1_0,
            &inputPort
        ) { eventList, sourceContext in
            MIDIEventListForEachEvent(
                eventList,
                { context, _, message in
                    guard let context else { return }
                    let source = Unmanaged<SourceContext>.fromOpaque(context).takeUnretainedValue()
                    let word = withUnsafeBytes(of: message) {
                        $0.load(as: UInt32.self)
                    }
                    source.controller.receive(word: word, source: source.sourceName)
                },
                sourceContext
            )
        }

        guard portStatus == noErr else {
            setupError = "MIDI input unavailable (\(portStatus))."
            return
        }

        refreshSources()
    }

    private func refreshSources() {
        connectedSources.forEach { MIDIPortDisconnectSource(inputPort, $0) }
        connectedSources.removeAll()
        sourceContexts.forEach {
            Unmanaged<SourceContext>.fromOpaque($0).release()
        }
        sourceContexts.removeAll()
        sources.removeAll()

        let sourceCount = MIDIGetNumberOfSources()
        for index in 0..<sourceCount {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }

            let name = Self.endpointName(endpoint)
            var uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            sources.append(MIDIInputSource(id: uniqueID, name: name))

            let context = SourceContext(controller: self, sourceName: name)
            let pointer = Unmanaged.passRetained(context).toOpaque()
            sourceContexts.append(pointer)
            if MIDIPortConnectSource(inputPort, endpoint, pointer) == noErr {
                connectedSources.append(endpoint)
            }
        }

        sources.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated func receive(word: UInt32, source: String) {
        guard let event = Self.decodeMIDI1UMP(word, source: source) else { return }
        Task { @MainActor in
            self.process(event)
        }
    }

    private func process(_ activity: MIDIActivity) {
        lastActivity = activity
        guard channelFilter == 0 || channelFilter == Int(activity.channel) + 1 else { return }

        let trigger = MIDITrigger(
            kind: activity.kind,
            channel: activity.channel,
            number: activity.number
        )

        if let learningAction {
            bindings[learningAction] = trigger
            self.learningAction = nil
            saveBindings()
            return
        }

        guard shouldTrigger(activity) else { return }

        for action in MIDINavigationAction.allCases where bindings[action] == trigger {
            onAction?(action.viewtifulAction)
        }

        if programChangeRecallEnabled, activity.kind == .programChange {
            let page = Int(activity.number) + programChangeOffset
            guard page > 0 else { return }
            onAction?(.goToPage(page))
        }
    }

    private func shouldTrigger(_ activity: MIDIActivity) -> Bool {
        switch activity.kind {
        case .note:
            return activity.value > 0
        case .programChange:
            return true
        case .controlChange:
            let key = "\(activity.channel)-\(activity.number)"
            if activity.value == 0 {
                activeCCs.remove(key)
                return false
            }
            return activeCCs.insert(key).inserted
        }
    }

    nonisolated static func decodeMIDI1UMP(_ word: UInt32, source: String) -> MIDIActivity? {
        guard (word >> 28) == 0x2 else { return nil }
        let status = UInt8((word >> 16) & 0xFF)
        let command = status & 0xF0
        let channel = status & 0x0F
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)

        let kind: MIDITrigger.Kind
        let value: UInt8
        switch command {
        case 0x90 where data2 > 0:
            kind = .note
            value = data2
        case 0xB0:
            kind = .controlChange
            value = data2
        case 0xC0:
            kind = .programChange
            value = data1
        default:
            return nil
        }

        return MIDIActivity(
            source: source,
            channel: channel,
            kind: kind,
            number: data1,
            value: value,
            received: .now
        )
    }

    private static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr else {
            return "MIDI Source"
        }
        return value?.takeRetainedValue() as String? ?? "MIDI Source"
    }

    private func loadBindings() {
        guard
            let data = UserDefaults.standard.data(forKey: Keys.bindings),
            let decoded = try? JSONDecoder().decode([MIDINavigationAction: MIDITrigger].self, from: data)
        else {
            return
        }
        bindings = decoded
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: Keys.bindings)
    }

    private enum Keys {
        static let channelFilter = "midi.channelFilter"
        static let programRecall = "midi.programRecall"
        static let programOffset = "midi.programOffset"
        static let bindings = "midi.bindings"
    }
}

private final class SourceContext: @unchecked Sendable {
    let controller: MIDIController
    let sourceName: String

    init(controller: MIDIController, sourceName: String) {
        self.controller = controller
        self.sourceName = sourceName
    }
}
