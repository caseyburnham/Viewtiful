import Foundation
import Network
import Observation
import Darwin
import ShowControlCore

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

    var argumentSummary: String {
        arguments.map(\.description).joined(separator: ", ")
    }

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
                // A console cues the page number printed on the script, which is
                // what the viewer's own readout shows.
                return .goToLabeledPage(page)
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
            return .goToLabeledPage(Int(page))
        }

        return nil
    }
}

/// A message lifted out of a packet, whether or not Viewtiful can read it.
enum OSCParsedMessage: Equatable, Sendable {
    case message(OSCMessage)
    case unsupported(address: String, argumentTypes: String)

    var address: String {
        switch self {
        case .message(let message): message.address
        case .unsupported(let address, _): address
        }
    }

    var argumentSummary: String {
        switch self {
        case .message(let message): message.argumentSummary
        case .unsupported(_, let argumentTypes): argumentTypes
        }
    }
}

struct OSCNetworkAddress: Identifiable, Equatable, Sendable {
    let interfaceName: String
    let address: String

    var id: String { "\(interfaceName)-\(address)" }
}

@MainActor
@Observable
final class OSCClient: @unchecked Sendable {
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
    private(set) var localAddresses: [OSCNetworkAddress] = []

    @ObservationIgnored private let log: ActivityLog?
    @ObservationIgnored var onAction: ((ViewtifulAction) -> Void)?
    @ObservationIgnored private var isAvailable = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var listeningPort: Int?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [NWConnection] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let queue = DispatchQueue(label: "Viewtiful.OSC", qos: .userInitiated)

    init(defaults: UserDefaults = .standard, log: ActivityLog? = nil) {
        self.defaults = defaults
        self.log = log
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        senderRestrictionEnabled = defaults.bool(forKey: Keys.senderRestrictionEnabled)
        allowedSenderAddress = defaults.string(forKey: Keys.allowedSenderAddress) ?? ""
        let savedPort = defaults.integer(forKey: Keys.port)
        port = savedPort == 0 ? ShowControlDefaults.viewtifulOSCUDPPort : savedPort
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
        controller: OSCClient,
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
                    controller.record(
                        messages: OSCParser.parse(data),
                        sender: senderAddress(for: connection.endpoint)
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

    private func record(messages: [OSCParsedMessage]?, sender: String) {
        guard let messages else {
            // Nothing survived decoding, so the packet is logged as the one
            // thing known about it: that it arrived and could not be read.
            log?.record(ActivityEntry(
                source: .osc,
                status: .invalid("Not a readable OSC packet"),
                message: "Undecodable Packet",
                origin: sender
            ))
            return
        }

        let allowedSender = allowedSenderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !senderRestrictionEnabled || sender == allowedSender else {
            let reason = allowedSender.isEmpty
                ? "Blocked: no allowed sender is set"
                : "Blocked: only \(allowedSender) is allowed"
            for parsed in messages {
                log?.record(ActivityEntry(
                    source: .osc,
                    status: .invalid(reason),
                    message: parsed.address,
                    details: parsed.argumentSummary,
                    origin: sender
                ))
            }
            return
        }

        for parsed in messages {
            guard case .message(let message) = parsed else {
                log?.record(ActivityEntry(
                    source: .osc,
                    status: .invalid("Argument type is not supported"),
                    message: parsed.address,
                    details: parsed.argumentSummary,
                    origin: sender
                ))
                continue
            }

            let action = message.action
            let status: ActivityEntry.Status = if let action {
                .triggered(action.title)
            } else {
                .invalid("Not a valid command")
            }
            log?.record(ActivityEntry(
                source: .osc,
                status: status,
                message: message.address,
                details: message.argumentSummary,
                origin: sender
            ))
            if let action {
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

/// Pure packet decoding with no shared state, so it stays off the main actor
/// and can be called from network callbacks.
nonisolated enum OSCParser {
    nonisolated static func parse(_ data: Data) -> [OSCParsedMessage]? {
        guard let packet = try? ShowControlOSCCodec.decode(data) else { return nil }
        return flatten(packet).map { message in
            let arguments = message.arguments.compactMap(argument)
            guard arguments.count == message.arguments.count else {
                // Kept rather than dropped: a message carrying argument types
                // this app cannot read is the kind of mistake worth showing.
                return .unsupported(
                    address: message.address,
                    argumentTypes: message.arguments.map(typeName).joined(separator: ", ")
                )
            }
            return .message(OSCMessage(address: message.address, arguments: arguments))
        }
    }

    private nonisolated static func typeName(_ value: ShowControlOSCValue) -> String {
        switch value {
        case .integer: "integer"
        case .float: "float"
        case .string: "string"
        case .blob: "blob"
        case .boolean: "boolean"
        case .nilValue: "nil"
        case .impulse: "impulse"
        case .array: "array"
        }
    }

    private nonisolated static func flatten(_ packet: ShowControlOSCPacket) -> [ShowControlOSCMessage] {
        switch packet {
        case .message(let message): [message]
        case .bundle(let bundle): bundle.elements.flatMap(flatten)
        }
    }

    private nonisolated static func argument(_ value: ShowControlOSCValue) -> OSCMessage.Argument? {
        switch value {
        case .integer(let value): .integer(value)
        case .float(let value): .float(value)
        case .string(let value): .string(value)
        case .blob, .boolean, .nilValue, .impulse, .array:
            nil
        }
    }
}
