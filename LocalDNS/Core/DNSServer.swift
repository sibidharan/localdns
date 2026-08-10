import Combine
import Foundation
import Network

public enum DNSServerError: Error, Equatable {
    case invalidPort(UInt16)
}

/// Embedded DNS server bound to the loopback interface only.
///
/// UDP: every received datagram is parsed and answered through `handler`.
/// TCP: DNS-over-TCP framing (RFC 1035 §4.2.2) — each message is preceded by a
/// two-byte big-endian length; the connection stays open for further queries.
///
/// All Network-framework callbacks run on a private serial queue; the published
/// state (`isRunning`, `lastError`) is mirrored to the main queue for SwiftUI.
public final class DNSServer: ObservableObject, @unchecked Sendable {
    /// Parses a query and returns the complete wire response packet.
    public typealias Handler = (DNSQuery) -> Data

    public let port: UInt16

    /// The rule-engine hook. Called on the server's private queue for every
    /// well-formed query; must return a full response packet. Defaults to REFUSED.
    public var handler: Handler

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.localdns.dnsserver", qos: .userInitiated)
    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    /// True between start() and stop(): failures only retry while the server
    /// is *supposed* to be up.
    private var wantsRunning = false
    private static let initialRetryDelay: TimeInterval = 2
    private var retryDelay: TimeInterval = 2
    private var udpReady = false
    private var tcpReady = false
    private var currentError: String?
    private var connections: [NWConnection] = []

    public init(port: UInt16 = 15353, handler: @escaping Handler = { DNSResponseBuilder.refused(to: $0) }) {
        self.port = port
        self.handler = handler
    }

    deinit {
        udpListener?.cancel()
        tcpListener?.cancel()
    }

    /// Starts both listeners. Synchronous errors (invalid port) are thrown;
    /// asynchronous failures (e.g. port already in use) surface via `lastError`.
    public func start() throws {
        guard NWEndpoint.Port(rawValue: port) != nil else {
            throw DNSServerError.invalidPort(port)
        }
        let (udp, tcp) = try Self.makeListeners(port: port)
        queue.async {
            self.wantsRunning = true
            self.retryDelay = Self.initialRetryDelay
            self.install(udp: udp, tcp: tcp)
        }
    }

    public func stop() {
        queue.async {
            self.wantsRunning = false
            self.teardown()
        }
    }

    /// Loopback only: pinning requiredLocalEndpoint makes the listeners bind
    /// 127.0.0.1 exclusively — nothing external can reach the server.
    /// (requiredInterfaceType = .loopback does NOT constrain the bind address;
    /// verified empirically — the listener still binds 0.0.0.0 without this.)
    private static func makeListeners(port: UInt16) throws -> (NWListener, NWListener) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw DNSServerError.invalidPort(port)
        }
        let localEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpointPort)
        let udpParameters = NWParameters.udp
        udpParameters.requiredLocalEndpoint = localEndpoint
        udpParameters.allowLocalEndpointReuse = true
        let tcpParameters = NWParameters.tcp
        tcpParameters.requiredLocalEndpoint = localEndpoint
        tcpParameters.allowLocalEndpointReuse = true
        return (try NWListener(using: udpParameters), try NWListener(using: tcpParameters))
    }

    // MARK: - Private; everything below runs on `queue`.

    private func install(udp: NWListener, tcp: NWListener) {
        teardown()
        currentError = nil
        udpListener = udp
        tcpListener = tcp
        udp.stateUpdateHandler = { [weak self] state in self?.listenerState(state, isUDP: true) }
        tcp.stateUpdateHandler = { [weak self] state in self?.listenerState(state, isUDP: false) }
        udp.newConnectionHandler = { [weak self] connection in self?.handleUDP(connection) }
        tcp.newConnectionHandler = { [weak self] connection in self?.handleTCP(connection) }
        udp.start(queue: queue)
        tcp.start(queue: queue)
        publish()
    }

    private func teardown() {
        udpListener?.cancel()
        udpListener = nil
        tcpListener?.cancel()
        tcpListener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
        udpReady = false
        tcpReady = false
        publish()
    }

    private func listenerState(_ state: NWListener.State, isUDP: Bool) {
        switch state {
        case .ready:
            if isUDP { udpReady = true } else { tcpReady = true }
            if udpReady && tcpReady {
                currentError = nil
                retryDelay = Self.initialRetryDelay
            }
            publish()
        case .failed(let error):
            // Listeners die for transient reasons too (sleep/wake, network
            // transitions, a port briefly held by another process) — a DNS
            // server that stays silently dead until a manual toggle is worse
            // than one that keeps retrying with backoff.
            currentError = "\(isUDP ? "UDP" : "TCP") listener on port \(self.port) failed — the port may be in use by another app; retrying. (\(error.localizedDescription))"
            teardown()
            scheduleRetry()
        case .cancelled:
            if isUDP { udpReady = false } else { tcpReady = false }
            publish()
        default:
            break
        }
    }

    private func scheduleRetry() {
        guard wantsRunning else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsRunning, self.udpListener == nil else { return }
            guard let (udp, tcp) = try? Self.makeListeners(port: self.port) else {
                self.scheduleRetry()
                return
            }
            self.install(udp: udp, tcp: tcp)
        }
    }

    private func publish() {
        let running = udpReady && tcpReady
        let error = currentError
        DispatchQueue.main.async {
            if self.isRunning != running { self.isRunning = running }
            if self.lastError != error { self.lastError = error }
        }
    }

    // MARK: Connections

    /// UDP is connectionless; Network framework hands us a pseudo-connection per
    /// peer. We keep receiving datagrams until the peer goes away or errors.
    private func handleUDP(_ connection: NWConnection) {
        track(connection)
        connection.start(queue: queue)
        receiveUDP(connection)
    }

    private func receiveUDP(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection else { return }
            if let content, !content.isEmpty, let reply = self.process(content) {
                connection.send(content: reply, completion: .contentProcessed { _ in })
            }
            if error != nil {
                self.untrack(connection)
            } else {
                self.receiveUDP(connection)
            }
        }
    }

    private func handleTCP(_ connection: NWConnection) {
        track(connection)
        connection.start(queue: queue)
        receiveTCPLength(connection)
    }

    /// Reads the two-byte big-endian length prefix of the next DNS-over-TCP message.
    private func receiveTCPLength(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self, weak connection] content, _, _, error in
            guard let self, let connection else { return }
            let bytes = content.map { [UInt8]($0) } ?? []
            guard error == nil, bytes.count == 2 else {
                self.untrack(connection)
                return
            }
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            guard length > 0 else {
                self.untrack(connection)
                return
            }
            self.receiveTCPQuery(connection, length: length)
        }
    }

    /// Reads exactly `length` bytes (the query), then writes the framed response.
    private func receiveTCPQuery(_ connection: NWConnection, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak connection] content, _, _, error in
            guard let self, let connection else { return }
            guard error == nil, let content, content.count == length else {
                self.untrack(connection)
                return
            }
            if let reply = self.process(content), reply.count <= Int(UInt16.max) {
                var framed = Data()
                framed.append(UInt8(reply.count >> 8))
                framed.append(UInt8(reply.count & 0xFF))
                framed.append(contentsOf: reply)
                connection.send(content: framed, completion: .contentProcessed { [weak self, weak connection] _ in
                    guard let self, let connection else { return }
                    self.receiveTCPLength(connection)
                })
            } else {
                self.receiveTCPLength(connection)
            }
        }
    }

    private func track(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.untrack(connection)
            default:
                break
            }
        }
    }

    private func untrack(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        connection.cancel()
    }

    /// Parses the datagram; malformed packets are dropped (no id to answer with).
    private func process(_ data: Data) -> Data? {
        guard let query = try? DNSMessage.parseQuery(data) else { return nil }
        return handler(query)
    }
}
