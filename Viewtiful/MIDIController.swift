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
    enum Kind: String, Codable, Sendable, CaseIterable {
        case note
        case controlChange
        case programChange

        var displayName: String {
            switch self {
            case .note: "Note On"
            case .controlChange: "Control Change"
            case .programChange: "Program Change"
            }
        }
    }

    var kind: Kind
    var channel: UInt8
    var byte1: UInt8
    var byte2: UInt8
    /// Legacy Note and Control Change bindings matched any positive value.
    /// Keep that behavior explicit when decoding records without byte2.
    var matchesAnyByte2: Bool

    init(kind: Kind, channel: UInt8, byte1: UInt8, byte2: UInt8, matchesAnyByte2: Bool = false) {
        self.kind = kind
        self.channel = channel
        self.byte1 = byte1
        self.byte2 = byte2
        self.matchesAnyByte2 = matchesAnyByte2
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        channel = try container.decode(UInt8.self, forKey: .channel)
        if let byte1 = try container.decodeIfPresent(UInt8.self, forKey: .byte1) {
            self.byte1 = byte1
        } else {
            self.byte1 = try container.decode(UInt8.self, forKey: .number)
        }
        let hasByte2 = container.contains(.byte2)
        byte2 = try container.decodeIfPresent(UInt8.self, forKey: .byte2) ?? 0
        matchesAnyByte2 = try container.decodeIfPresent(Bool.self, forKey: .matchesAnyByte2)
            ?? (!hasByte2 && kind != .programChange)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(channel, forKey: .channel)
        try container.encode(byte1, forKey: .byte1)
        try container.encode(byte2, forKey: .byte2)
        try container.encode(matchesAnyByte2, forKey: .matchesAnyByte2)
    }

    func matches(_ activity: MIDIActivity) -> Bool {
        guard kind == activity.kind, channel == activity.channel, byte1 == activity.byte1 else { return false }
        // Program Change has no second data byte. Its stored byte 2 is a UI
        // placeholder and must not prevent a manually edited binding firing.
        return kind == .programChange || matchesAnyByte2 || byte2 == activity.byte2
    }

    func conflicts(with other: MIDITrigger) -> Bool {
        guard kind == other.kind, channel == other.channel, byte1 == other.byte1 else { return false }
        return kind == .programChange || matchesAnyByte2 || other.matchesAnyByte2 || byte2 == other.byte2
    }

    private enum CodingKeys: String, CodingKey {
        case kind, channel, byte1, byte2, number, matchesAnyByte2
    }
}

enum MIDIInputSelection: Hashable, Sendable {
    case allSources
    case source(Int32)
}

enum MIDITriggerField: Sendable {
    case channel
    case byte1
    case byte2
}

struct MIDIInputSource: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
}

struct MIDIActivity: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: String
    let sourceID: Int32
    let channel: UInt8
    let kind: MIDITrigger.Kind
    let byte1: UInt8
    let byte2: UInt8
    let received: Date

    nonisolated init(id: UUID = UUID(), source: String, sourceID: Int32, channel: UInt8,
                     kind: MIDITrigger.Kind, byte1: UInt8, byte2: UInt8, received: Date) {
        self.id = id
        self.source = source
        self.sourceID = sourceID
        self.channel = channel
        self.kind = kind
        self.byte1 = byte1
        self.byte2 = byte2
        self.received = received
    }

    var number: UInt8 { byte1 }
    var value: UInt8 {
        kind == .programChange ? byte1 : byte2
    }

    /// How the message reads in the Activity Log.
    var logMessage: String {
        "\(kind.displayName) \(byte1)"
    }

    var logDetails: String {
        kind == .programChange
            ? "Channel \(channel + 1)  ·  Program \(byte1)"
            : "Channel \(channel + 1)  ·  Byte 1 \(byte1)  ·  Byte 2 \(byte2)"
    }
}

@MainActor
@Observable
final class MIDIController: @unchecked Sendable {
    @ObservationIgnored private let defaults: UserDefaults

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            if !enabled { activeCCs.removeAll() }
        }
    }

    var channelFilter: Int {
        didSet {
            defaults.set(channelFilter, forKey: Keys.channelFilter)
        }
    }

    var acceptsAllSources: Bool {
        didSet {
            defaults.set(acceptsAllSources, forKey: Keys.acceptsAllSources)
        }
    }

    private(set) var selectedSourceIDs: Set<Int32> {
        didSet {
            defaults.set(selectedSourceIDs.map(Int.init), forKey: Keys.selectedSourceIDs)
        }
    }

    var programChangeRecallEnabled: Bool {
        didSet {
            defaults.set(programChangeRecallEnabled, forKey: Keys.programRecall)
        }
    }

    var programChangeOffset: Int {
        didSet {
            defaults.set(programChangeOffset, forKey: Keys.programOffset)
        }
    }

    private(set) var sources: [MIDIInputSource] = []
    private(set) var bindings: [MIDINavigationAction: MIDITrigger] = [:]
    private(set) var learningAction: MIDINavigationAction?
    private(set) var lastActivity: MIDIActivity?
    private(set) var setupError: String?

    @ObservationIgnored private let log: ActivityLog?
    @ObservationIgnored var onAction: ((ViewtifulAction) -> Void)?
    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var inputPort = MIDIPortRef()
    @ObservationIgnored private var sourceContexts: [UnsafeMutableRawPointer] = []
    @ObservationIgnored private var connectedSources: [MIDIEndpointRef] = []
    @ObservationIgnored private var activeCCs: Set<CCKey> = []
    @ObservationIgnored private var inputGeneration: UInt64 = 0

    init(defaults: UserDefaults = .standard, connectsToDevices: Bool = true, log: ActivityLog? = nil) {
        self.defaults = defaults
        self.log = log
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        channelFilter = defaults.integer(forKey: Keys.channelFilter)
        acceptsAllSources = defaults.object(forKey: Keys.acceptsAllSources) as? Bool ?? true
        selectedSourceIDs = Set((defaults.array(forKey: Keys.selectedSourceIDs) as? [NSNumber] ?? []).map(\.int32Value))
        programChangeRecallEnabled = defaults.bool(forKey: Keys.programRecall)
        programChangeOffset = defaults.object(forKey: Keys.programOffset) as? Int ?? 1
        loadBindings()
        if connectsToDevices { setup() }
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

    var inputSelection: MIDIInputSelection {
        get {
            guard !acceptsAllSources, let sourceID = selectedSourceIDs.sorted().first else {
                return .allSources
            }
            return .source(sourceID)
        }
        set {
            switch newValue {
            case .allSources:
                acceptsAllSources = true
                selectedSourceIDs.removeAll()
            case .source(let sourceID):
                acceptsAllSources = false
                selectedSourceIDs = [sourceID]
            }
        }
    }

    func beginLearning(_ action: MIDINavigationAction) {
        activeCCs.removeAll()
        learningAction = action
    }

    func cancelLearning() {
        learningAction = nil
    }

    func clearBinding(_ action: MIDINavigationAction) {
        bindings.removeValue(forKey: action)
        saveBindings()
    }

    func bindingFieldValue(_ action: MIDINavigationAction, field: MIDITriggerField) -> Int? {
        guard let binding = bindings[action] else { return nil }
        switch field {
        case .channel: return Int(binding.channel) + 1
        case .byte1: return Int(binding.byte1)
        case .byte2: return Int(binding.byte2)
        }
    }

    func setBindingField(_ action: MIDINavigationAction, field: MIDITriggerField, value: Int) {
        guard var binding = bindings[action] else { return }
        switch field {
        case .channel:
            binding.channel = UInt8(min(max(value, 1), 16) - 1)
        case .byte1:
            binding.byte1 = UInt8(min(max(value, 0), 127))
        case .byte2:
            binding.byte2 = UInt8(min(max(value, 0), 127))
            binding.matchesAnyByte2 = false
        }
        replaceBinding(action, with: binding)
    }

    func setBindingKind(_ action: MIDINavigationAction, kind: MIDITrigger.Kind) {
        guard var binding = bindings[action] else { return }
        binding.kind = kind
        replaceBinding(action, with: binding)
    }

    func createBinding(_ action: MIDINavigationAction, kind: MIDITrigger.Kind,
                       channel: Int, byte1: Int, byte2: Int) {
        let clampedChannel = UInt8(min(max(channel, 1), 16) - 1)
        let clampedByte1 = UInt8(min(max(byte1, 0), 127))
        let clampedByte2 = UInt8(min(max(byte2, 0), 127))
        replaceBinding(action, with: MIDITrigger(kind: kind, channel: clampedChannel,
                                                  byte1: clampedByte1, byte2: clampedByte2))
    }

    private func replaceBinding(_ action: MIDINavigationAction, with binding: MIDITrigger) {
        bindings = bindings.filter { $0.key == action || !$0.value.conflicts(with: binding) }
        bindings[action] = binding
        saveBindings()
    }

    private func setup() {
        let clientStatus = MIDIClientCreateWithBlock("Viewtiful" as CFString, &client) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSources()
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
                    source.controller?.receive(message: message, source: source.sourceName,
                                                sourceID: source.sourceID, generation: source.generation)
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
        guard inputPort != 0 else { return }
        inputGeneration &+= 1
        let generation = inputGeneration
        connectedSources.forEach { MIDIPortDisconnectSource(inputPort, $0) }
        connectedSources.removeAll()
        sourceContexts.forEach {
            Unmanaged<SourceContext>.fromOpaque($0).release()
        }
        sourceContexts.removeAll()
        sources.removeAll()
        activeCCs.removeAll()

        let sourceCount = MIDIGetNumberOfSources()
        for index in 0..<sourceCount {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }

            let name = Self.endpointName(endpoint)
            var uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)

            let context = SourceContext(controller: self, sourceName: name, sourceID: uniqueID,
                                        generation: generation)
            let pointer = Unmanaged.passRetained(context).toOpaque()
            sourceContexts.append(pointer)
            if MIDIPortConnectSource(inputPort, endpoint, pointer) == noErr {
                connectedSources.append(endpoint)
                sources.append(MIDIInputSource(id: uniqueID, name: name))
            }
        }

        sources.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated func receive(message: MIDIUniversalMessage, source: String, sourceID: Int32,
                                     generation: UInt64) {
        guard let event = Self.decodeMIDIMessage(message, source: source, sourceID: sourceID) else { return }
        Task { @MainActor [weak self] in
            guard let self, generation == self.inputGeneration else { return }
            self.process(event)
        }
    }

    func process(_ activity: MIDIActivity) {
        guard enabled else { return }
        lastActivity = activity

        guard acceptsAllSources || selectedSourceIDs.contains(activity.sourceID) else {
            record(activity, status: .ignored("Source is not selected"))
            return
        }
        guard channelFilter == 0 || channelFilter == Int(activity.channel) + 1 else {
            record(activity, status: .ignored("Channel \(channelFilter) only"))
            return
        }

        let trigger = MIDITrigger(
            kind: activity.kind,
            channel: activity.channel,
            byte1: activity.byte1,
            byte2: activity.byte2
        )

        if let learningAction {
            if let reason = rejectionReason(for: activity, allowUnboundControlChange: true) {
                record(activity, status: .ignored(reason))
                return
            }
            // One physical control must produce one navigation action.
            replaceBinding(learningAction, with: trigger)
            self.learningAction = nil
            record(activity, status: .triggered("Captured \(learningAction.title)"))
            return
        }

        if let reason = rejectionReason(for: activity, allowUnboundControlChange: false) {
            record(activity, status: .ignored(reason))
            return
        }

        for action in MIDINavigationAction.allCases where bindings[action]?.matches(activity) == true {
            record(activity, status: .triggered(action.title))
            onAction?(action.viewtifulAction)
            return
        }

        if programChangeRecallEnabled, activity.kind == .programChange {
            let page = Int(activity.byte1) + programChangeOffset
            guard page > 0 else {
                record(activity, status: .invalid(
                    "Program \(activity.byte1) with offset \(programChangeOffset) is page \(page)"
                ))
                return
            }
            record(activity, status: .triggered(ViewtifulAction.goToPage(page).title))
            onAction?(.goToPage(page))
            return
        }

        record(activity, status: .ignored("No mapping"))
    }

    private func record(_ activity: MIDIActivity, status: ActivityEntry.Status) {
        log?.record(ActivityEntry(
            timestamp: activity.received,
            source: .midi,
            status: status,
            message: activity.logMessage,
            details: activity.logDetails,
            origin: activity.source
        ))
    }

    /// Why the message will not fire an action, or `nil` when it should. The
    /// reason doubles as the Activity Log's account of what happened, so the
    /// decision is made once whether or not anyone is watching the log.
    private func rejectionReason(for activity: MIDIActivity, allowUnboundControlChange: Bool) -> String? {
        switch activity.kind {
        case .note:
            return activity.value > 0 ? nil : "Note released"
        case .programChange:
            return nil
        case .controlChange:
            let key = CCKey(sourceID: activity.sourceID, channel: activity.channel,
                            controller: activity.number)
            if activity.value == 0 {
                activeCCs.remove(key)
                return "Control released"
            }
            if !allowUnboundControlChange && !hasBindingMatch(for: activity) {
                return "No mapping"
            }
            return activeCCs.insert(key).inserted ? nil : "Control already held"
        }
    }

    private func hasBindingMatch(for activity: MIDIActivity) -> Bool {
        MIDINavigationAction.allCases.contains { bindings[$0]?.matches(activity) == true }
    }

    nonisolated static func decodeMIDIMessage(_ message: MIDIUniversalMessage, source: String, sourceID: Int32) -> MIDIActivity? {
        // The event visitor supplies a decoded struct, not the original packed UMP word.
        guard message.type == .channelVoice1 else { return nil }
        let voice = message.channelVoice1

        let kind: MIDITrigger.Kind
        let number: UInt8
        let value: UInt8
        switch voice.status {
        case .noteOn where voice.note.velocity > 0:
            kind = .note
            number = voice.note.number
            value = voice.note.velocity
        case .controlChange:
            kind = .controlChange
            number = voice.controlChange.index
            value = voice.controlChange.data
        case .programChange:
            kind = .programChange
            number = voice.program
            value = voice.program
        default:
            return nil
        }

        return MIDIActivity(
            source: source,
            sourceID: sourceID,
            channel: voice.channel,
            kind: kind,
            byte1: number,
            byte2: kind == .programChange ? 0 : value,
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
            let data = defaults.data(forKey: Keys.bindings),
            let decoded = try? JSONDecoder().decode([MIDINavigationAction: MIDITrigger].self, from: data)
        else {
            return
        }
        bindings = decoded
        // Re-encode after decoding so legacy records are upgraded to the
        // explicit byte-2 matching representation without changing behavior.
        if decoded.values.contains(where: { $0.matchesAnyByte2 }) {
            saveBindings()
        }
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Keys.bindings)
    }

    private enum Keys {
        static let channelFilter = "midi.channelFilter"
        static let enabled = "midi.enabled"
        static let acceptsAllSources = "midi.acceptsAllSources"
        static let selectedSourceIDs = "midi.selectedSourceIDs"
        static let programRecall = "midi.programRecall"
        static let programOffset = "midi.programOffset"
        static let bindings = "midi.bindings"
    }
}

private final class SourceContext: @unchecked Sendable {
    weak var controller: MIDIController?
    let sourceName: String
    let sourceID: Int32
    let generation: UInt64

    init(controller: MIDIController, sourceName: String, sourceID: Int32, generation: UInt64) {
        self.controller = controller
        self.sourceName = sourceName
        self.sourceID = sourceID
        self.generation = generation
    }
}

private struct CCKey: Hashable, Sendable {
    let sourceID: Int32
    let channel: UInt8
    let controller: UInt8
}
