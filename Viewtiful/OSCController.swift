import Foundation
import Network
import Observation
import Darwin

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
        case .failed(let reason): "Unavailable: \(reason)"
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
        if arguments.isEmpty {
            let pagePrefix = "/viewtiful/page/"
            if address.hasPrefix(pagePrefix) {
                let pageText = String(address.dropFirst(pagePrefix.count))
                guard !pageText.isEmpty,
                      pageText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let page = Int(pageText),
                      page > 0 else {
                    return nil
                }
                return .goToPage(page)
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

        // Continue accepting the original argument form for existing show files.
        if address == "/viewtiful/page",
           arguments.count == 1,
           case .integer(let page) = arguments[0],
           page > 0 {
            return .goToPage(Int(page))
        }

        return nil
    }
}

struct OSCActivity: Identifiable, Equatable, Sendable {
    let id: UUID
    let message: OSCMessage
    let sender: String
    let received: Date

    init(message: OSCMessage, sender: String, received: Date = .now) {
        id = UUID()
        self.message = message
        self.sender = sender
        self.received = received
    }
}

struct OSCNetworkAddress: Identifiable, Equatable, Sendable {
    let interfaceName: String
    let address: String

    var id: String { "\(interfaceName)-\(address)" }
}

@MainActor
@Observable
final class OSCController: @unchecked Sendable {
    @ObservationIgnored private let defaults: UserDefaults

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            applyConfiguration()
        }
    }

    var port: Int {
        didSet {
            defaults.set(port, forKey: Keys.port)
            applyConfiguration()
        }
    }

    var senderRestrictionEnabled: Bool {
        didSet {
            defaults.set(senderRestrictionEnabled, forKey: Keys.senderRestrictionEnabled)
        }
    }

    var allowedSenderAddress: String {
        didSet {
            defaults.set(allowedSenderAddress, forKey: Keys.allowedSenderAddress)
        }
    }

    private(set) var status: OSCListenerStatus = .stopped
    private(set) var messageHistory: [OSCActivity] = []
    private(set) var malformedPacketCount = 0
    private(set) var blockedPacketCount = 0
    private(set) var localAddresses: [OSCNetworkAddress] = []

    var rejectedPacketCount: Int {
        malformedPacketCount + blockedPacketCount
    }

    @ObservationIgnored var onAction: ((ViewtifulAction) -> Void)?
    @ObservationIgnored private var isAvailable = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var listeningPort: Int?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [NWConnection] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let queue = DispatchQueue(label: "Viewtiful.OSC", qos: .userInitiated)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        senderRestrictionEnabled = defaults.bool(forKey: Keys.senderRestrictionEnabled)
        allowedSenderAddress = defaults.string(forKey: Keys.allowedSenderAddress) ?? ""
        let savedPort = defaults.integer(forKey: Keys.port)
        port = savedPort == 0 ? 53_001 : savedPort
        refreshLocalAddresses()
        startPathMonitor()
    }

    deinit {
        pathMonitor?.cancel()
    }

    func setAvailable(_ available: Bool) {
        isAvailable = available
        if available {
            refreshLocalAddresses()
            if listener == nil { applyConfiguration() }
        } else {
            stop()
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLocalAddresses()
            }
        }
        monitor.start(queue: queue)
    }

    private func refreshLocalAddresses() {
        localAddresses = Self.currentLocalAddresses()
    }

    private nonisolated static func currentLocalAddresses() -> [OSCNetworkAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var addresses: [OSCNetworkAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = current {
            let flags = interface.pointee.ifa_flags
            guard let socketAddress = interface.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else {
                current = interface.pointee.ifa_next
                continue
            }

            var address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let converted = inet_ntop(AF_INET, &address, &host, socklen_t(INET_ADDRSTRLEN))
            if converted != nil {
                let interfaceName = String(cString: interface.pointee.ifa_name)
                let address = String(cString: host)
                addresses.append(OSCNetworkAddress(interfaceName: interfaceName, address: address))
            }

            current = interface.pointee.ifa_next
        }

        return addresses.sorted {
            if $0.interfaceName == $1.interfaceName {
                return $0.address < $1.address
            }
            return $0.interfaceName.localizedStandardCompare($1.interfaceName) == .orderedAscending
        }
    }

    func applyConfiguration() {
        if enabled, isAvailable, listener != nil, listeningPort == port { return }
        stop()
        guard enabled, isAvailable else { return }
        start()
    }

    func stop() {
        generation = UUID()
        listeningPort = nil
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
            listeningPort = port
            let generation = self.generation
            status = .starting

            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.handleListenerState(newState)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { connection.cancel(); return }
                    self.accept(connection)
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
            stop()
            status = .failed(error.localizedDescription)
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
        Self.receiveMessages(on: connection, controller: self, generation: generation)
    }

    private nonisolated static func receiveMessages(
        on connection: NWConnection,
        controller: OSCController,
        generation: UUID
    ) {
        connection.receiveMessage { [weak controller, weak connection] data, _, _, error in
            Task { @MainActor [weak controller, weak connection] in
                guard let controller, let connection,
                      controller.generation == generation,
                      controller.connections.contains(where: { $0 === connection }) else {
                    connection?.cancel()
                    return
                }
                if let data, !data.isEmpty {
                    let messages = OSCParser.parse(data)
                    controller.record(
                        messages: messages,
                        sender: senderAddress(for: connection.endpoint),
                        packetWasValid: messages != nil
                    )
                }
                if error == nil {
                    receiveMessages(on: connection, controller: controller, generation: generation)
                } else {
                    controller.connections.removeAll { $0 === connection }
                    connection.cancel()
                }
            }
        }
    }

    private nonisolated static func senderAddress(for endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else {
            return String(describing: endpoint)
        }
        return String(describing: host)
    }

    private func record(messages: [OSCMessage]?, sender: String, packetWasValid: Bool) {
        guard packetWasValid, let messages else {
            malformedPacketCount += 1
            return
        }

        guard !senderRestrictionEnabled || sender == allowedSenderAddress.trimmingCharacters(in: .whitespacesAndNewlines) else {
            blockedPacketCount += 1
            return
        }

        for message in messages {
            let activity = OSCActivity(message: message, sender: sender)
            messageHistory.insert(activity, at: 0)
            if messageHistory.count > 200 { messageHistory.removeLast() }
            if let action = message.action {
                onAction?(action)
            }
        }
    }

    private enum Keys {
        static let enabled = "osc.enabled"
        static let port = "osc.port"
        static let senderRestrictionEnabled = "osc.senderRestrictionEnabled"
        static let allowedSenderAddress = "osc.allowedSenderAddress"
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
        guard bytes[terminator..<(offset + paddedLength)].allSatisfy({ $0 == 0 }) else { return nil }
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
