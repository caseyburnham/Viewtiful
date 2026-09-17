import Foundation
import Network
import Observation

enum OSCListenerStatus: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .failed: "Unavailable"
        }
    }

    var isRunning: Bool {
        self == .running
    }
}

struct OSCMessage: Equatable, Sendable {
    enum Argument: Equatable, Sendable {
        case integer(Int32)
        case float(Float)
        case string(String)

        var description: String {
            switch self {
            case .integer(let value): "\(value)"
            case .float(let value): "\(value)"
            case .string(let value): value
            }
        }
    }

    let address: String
    let arguments: [Argument]

    var action: ViewtifulAction? {
        guard arguments.isEmpty else {
            if address == "/viewtiful/page",
               arguments.count == 1,
               case .integer(let page) = arguments[0],
               page > 0 {
                return .goToPage(Int(page))
            }
            return nil
        }

        switch address {
        case "/viewtiful/next":
            return .nextPage
        case "/viewtiful/previous":
            return .previousPage
        case "/viewtiful/first":
            return .firstPage
        case "/viewtiful/last":
            return .lastPage
        default:
            return nil
        }
    }
}

@MainActor
@Observable
final class OSCController: @unchecked Sendable {
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            applyConfiguration()
        }
    }

    var port: Int {
        didSet {
            UserDefaults.standard.set(port, forKey: Keys.port)
        }
    }

    private(set) var status: OSCListenerStatus = .stopped
    private(set) var lastMessage: OSCMessage?
    private(set) var lastSender = ""
    private(set) var lastReceived: Date?
    private(set) var rejectedPacketCount = 0

    @ObservationIgnored var onAction: ((ViewtifulAction) -> Void)?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [NWConnection] = []
    @ObservationIgnored private let queue = DispatchQueue(label: "Viewtiful.OSC", qos: .userInitiated)

    init() {
        enabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
        let savedPort = UserDefaults.standard.integer(forKey: Keys.port)
        port = savedPort == 0 ? 53_000 : savedPort
    }

    func applyConfiguration() {
        stop()
        guard enabled else { return }
        start()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        status = .stopped
    }

    private func start() {
        guard (1...65_535).contains(port), let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            status = .failed("Invalid UDP port")
            return
        }

        do {
            let listener = try NWListener(using: .udp, on: networkPort)
            self.listener = listener
            status = .starting

            let controller = self
            listener.stateUpdateHandler = { newState in
                Task { @MainActor in
                    controller.handleListenerState(newState)
                }
            }

            listener.newConnectionHandler = { connection in
                Task { @MainActor in
                    controller.accept(connection)
                }
            }
            listener.start(queue: queue)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            status = .running
        case .failed(let error):
            status = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
        case .cancelled:
            if listener == nil {
                status = .stopped
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        if connections.count > 32 {
            connections.removeFirst().cancel()
        }
        connection.start(queue: queue)
        Self.receiveMessages(on: connection, controller: self)
    }

    private nonisolated static func receiveMessages(
        on connection: NWConnection,
        controller: OSCController
    ) {
        connection.receiveMessage { data, _, isComplete, error in
            if let data, !data.isEmpty {
                let messages = OSCParser.parse(data)
                let sender = String(describing: connection.endpoint)
                Task { @MainActor in
                    controller.record(messages: messages, sender: sender, packetWasValid: messages != nil)
                }
            }

            if error == nil, !isComplete {
                receiveMessages(on: connection, controller: controller)
            } else if error == nil {
                receiveMessages(on: connection, controller: controller)
            }
        }
    }

    private func record(messages: [OSCMessage]?, sender: String, packetWasValid: Bool) {
        guard packetWasValid, let messages else {
            rejectedPacketCount += 1
            return
        }

        for message in messages {
            lastMessage = message
            lastSender = sender
            lastReceived = .now
            if let action = message.action {
                onAction?(action)
            }
        }
    }

    private enum Keys {
        static let enabled = "osc.enabled"
        static let port = "osc.port"
    }
}

enum OSCParser {
    static func parse(_ data: Data) -> [OSCMessage]? {
        guard data.count <= 1_048_576 else { return nil }
        return parsePacket(Array(data), depth: 0)
    }

    private static func parsePacket(_ bytes: [UInt8], depth: Int) -> [OSCMessage]? {
        guard depth <= 8 else { return nil }

        if bytes.starts(with: Array("#bundle\0".utf8)) {
            return parseBundle(bytes, depth: depth)
        }

        guard let message = parseMessage(bytes) else { return nil }
        return [message]
    }

    private static func parseBundle(_ bytes: [UInt8], depth: Int) -> [OSCMessage]? {
        guard bytes.count >= 16 else { return nil }
        var offset = 16
        var messages: [OSCMessage] = []

        while offset < bytes.count {
            guard let size = readInt32(bytes, at: offset), size > 0 else { return nil }
            offset += 4
            let elementSize = Int(size)
            guard elementSize <= bytes.count - offset else { return nil }

            let element = Array(bytes[offset..<(offset + elementSize)])
            if let parsed = parsePacket(element, depth: depth + 1) {
                messages.append(contentsOf: parsed)
            }
            offset += elementSize
        }

        return offset == bytes.count ? messages : nil
    }

    private static func parseMessage(_ bytes: [UInt8]) -> OSCMessage? {
        var offset = 0
        guard
            let address = readString(bytes, offset: &offset),
            address.hasPrefix("/"),
            let typeTags = readString(bytes, offset: &offset),
            typeTags.first == ","
        else {
            return nil
        }

        var arguments: [OSCMessage.Argument] = []
        for tag in typeTags.dropFirst() {
            switch tag {
            case "i":
                guard let value = readInt32(bytes, at: offset) else { return nil }
                arguments.append(.integer(value))
                offset += 4
            case "f":
                guard let bits = readUInt32(bytes, at: offset) else { return nil }
                arguments.append(.float(Float(bitPattern: bits)))
                offset += 4
            case "s":
                guard let value = readString(bytes, offset: &offset) else { return nil }
                arguments.append(.string(value))
            default:
                return nil
            }
        }

        guard offset == bytes.count else { return nil }
        return OSCMessage(address: address, arguments: arguments)
    }

    private static func readString(_ bytes: [UInt8], offset: inout Int) -> String? {
        guard offset < bytes.count, let terminator = bytes[offset...].firstIndex(of: 0) else { return nil }
        guard let value = String(bytes: bytes[offset..<terminator], encoding: .utf8) else { return nil }

        let consumed = terminator - offset + 1
        let paddedLength = (consumed + 3) & ~3
        guard paddedLength <= bytes.count - offset else { return nil }
        offset += paddedLength
        return value
    }

    private static func readInt32(_ bytes: [UInt8], at offset: Int) -> Int32? {
        guard let value = readUInt32(bytes, at: offset) else { return nil }
        return Int32(bitPattern: value)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
