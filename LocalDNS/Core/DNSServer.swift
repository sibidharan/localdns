import Combine
import Darwin
import Foundation
import os

public enum DNSServerError: Error, Equatable {
    case invalidPort(UInt16)
}

/// Embedded DNS server bound to the loopback interface only.
///
/// UDP: every received datagram is parsed and answered through `handler`.
/// TCP: DNS-over-TCP framing (RFC 1035 §4.2.2) — each message is preceded by a
/// two-byte big-endian length; the connection stays open for further queries.
///
/// Transport is BSD sockets + DispatchSource, deliberately NOT
/// Network.framework: NW listeners on recent macOS can silently stop
/// delivering after sleep while still reporting `.ready` (bound port, peer
/// pseudo-connections created, zero callbacks — observed in the field three
/// days running). Kernel sockets have no such lifecycle: a bound loopback
/// socket keeps receiving after wake, and if anything ever goes silent anyway,
/// the watchdog (a real self-query) tears down and rebinds.
///
/// Everything below runs on a private serial queue; the published state
/// (`isRunning`, `lastError`) is mirrored to the main queue for SwiftUI.
public final class DNSServer: ObservableObject, @unchecked Sendable {
    /// Parses a query and returns the complete wire response packet.
    public typealias Handler = (DNSQuery) -> Data

    public let port: UInt16

    /// The rule-engine hook. Called on the server's private queue for every
    /// well-formed query; must return a full response packet. Defaults to REFUSED.
    public var handler: Handler

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?

    private static let log = Logger(subsystem: "com.localdns.app", category: "server")

    private let queue = DispatchQueue(label: "com.localdns.dnsserver", qos: .userInitiated)
    private var udpSource: DispatchSourceRead?
    private var tcpSource: DispatchSourceRead?
    private var udpFD: Int32 = -1
    private var tcpFD: Int32 = -1

    private final class TCPClient {
        let source: DispatchSourceRead
        var buffer = Data()
        init(source: DispatchSourceRead) { self.source = source }
    }

    private var clients: [Int32: TCPClient] = [:]

    /// True between start() and stop(): failures only retry while the server
    /// is *supposed* to be up.
    private var wantsRunning = false
    private static let initialRetryDelay: TimeInterval = 2
    private var retryDelay: TimeInterval = 2
    private var currentError: String?
    private var watchdog: DispatchSourceTimer?

    public init(port: UInt16 = 15353, handler: @escaping Handler = { DNSResponseBuilder.refused(to: $0) }) {
        self.port = port
        self.handler = handler
    }

    deinit {
        udpSource?.cancel()
        tcpSource?.cancel()
        for client in clients.values { client.source.cancel() }
        watchdog?.cancel()
    }

    /// Starts both sockets. Synchronous errors (invalid port) are thrown;
    /// asynchronous failures (e.g. port already in use) surface via `lastError`
    /// and keep retrying with backoff until stop().
    public func start() throws {
        guard port != 0 else { throw DNSServerError.invalidPort(port) }
        queue.async {
            self.wantsRunning = true
            self.retryDelay = Self.initialRetryDelay
            self.attemptBind()
            self.armWatchdog()
        }
    }

    public func stop() {
        queue.async {
            self.wantsRunning = false
            self.watchdog?.cancel()
            self.watchdog = nil
            self.teardown()
        }
    }

    /// Schedules an immediate liveness probe (e.g. after system wake).
    public func probeNow() {
        queue.async { self.selfProbe() }
    }

    // MARK: - Binding (on `queue`)

    private func attemptBind() {
        guard wantsRunning, udpFD < 0, tcpFD < 0 else { return }
        guard let udp = Self.makeBoundSocket(type: SOCK_DGRAM, port: port) else {
            bindFailed("UDP bind on 127.0.0.1:\(port) failed (\(Self.errnoText())) — the port may be in use by another app; retrying")
            return
        }
        guard let tcp = Self.makeBoundSocket(type: SOCK_STREAM, port: port) else {
            close(udp)
            bindFailed("TCP bind on 127.0.0.1:\(port) failed (\(Self.errnoText())) — the port may be in use by another app; retrying")
            return
        }
        guard listen(tcp, 16) == 0 else {
            close(udp)
            close(tcp)
            bindFailed("TCP listen failed (\(Self.errnoText())); retrying")
            return
        }

        udpFD = udp
        tcpFD = tcp

        let udpSrc = DispatchSource.makeReadSource(fileDescriptor: udp, queue: queue)
        udpSrc.setEventHandler { [weak self] in self?.drainUDP() }
        udpSrc.setCancelHandler { close(udp) }
        udpSrc.resume()
        udpSource = udpSrc

        let tcpSrc = DispatchSource.makeReadSource(fileDescriptor: tcp, queue: queue)
        tcpSrc.setEventHandler { [weak self] in self?.acceptClients() }
        tcpSrc.setCancelHandler { close(tcp) }
        tcpSrc.resume()
        tcpSource = tcpSrc

        currentError = nil
        retryDelay = Self.initialRetryDelay
        publish()
        Self.log.info("bound 127.0.0.1:\(self.port, privacy: .public) (udp+tcp)")
    }

    /// Exclusive bind, deliberately: with address reuse a rebind could win the
    /// port while a dying socket still owned datagram delivery — bound but
    /// silent. Exclusive binding fails loudly until the old socket is gone.
    private static func makeBoundSocket(type: Int32, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return fd
    }

    private func bindFailed(_ message: String) {
        currentError = message
        publish()
        Self.log.error("\(message, privacy: .public)")
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard wantsRunning else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptBind()
        }
    }

    private func teardown() {
        udpSource?.cancel()
        udpSource = nil
        tcpSource?.cancel()
        tcpSource = nil
        udpFD = -1
        tcpFD = -1
        for client in clients.values { client.source.cancel() }
        clients.removeAll()
        publish()
    }

    private func publish() {
        let running = udpFD >= 0 && tcpFD >= 0
        let error = currentError
        DispatchQueue.main.async {
            if self.isRunning != running { self.isRunning = running }
            if self.lastError != error { self.lastError = error }
        }
    }

    // MARK: - UDP (on `queue`)

    private func drainUDP() {
        guard udpFD >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var peer = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(udpFD, &buf, buf.count, 0, sa, &peerLen)
                }
            }
            guard received > 0 else { break } // EWOULDBLOCK or transient error: wait for the next event
            guard let reply = process(Data(bytes: buf, count: received)) else { continue }
            _ = withUnsafePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    reply.withUnsafeBytes { raw in
                        sendto(udpFD, raw.baseAddress, reply.count, 0, sa, peerLen)
                    }
                }
            }
        }
    }

    // MARK: - TCP (on `queue`)

    private func acceptClients() {
        guard tcpFD >= 0 else { return }
        while true {
            let fd = accept(tcpFD, nil, nil)
            guard fd >= 0 else { break } // EWOULDBLOCK: no more pending
            var yes: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.clientReadable(fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            clients[fd] = TCPClient(source: source)
        }
    }

    private func clientReadable(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                client.buffer.append(contentsOf: buf[0 ..< n])
                continue
            }
            if n == 0 {
                dropClient(fd) // EOF
                return
            }
            if errno == EWOULDBLOCK || errno == EAGAIN { break }
            dropClient(fd)
            return
        }

        // RFC 1035 §4.2.2 framing with pipelining: drain every complete
        // message in the buffer; a partial one waits for more bytes.
        while client.buffer.count >= 2 {
            let head = [UInt8](client.buffer.prefix(2))
            let length = Int(head[0]) << 8 | Int(head[1])
            guard length > 0 else {
                dropClient(fd)
                return
            }
            guard client.buffer.count >= 2 + length else { break }
            let query = Data(client.buffer.dropFirst(2).prefix(length))
            client.buffer = Data(client.buffer.dropFirst(2 + length))
            guard let reply = process(query), reply.count <= Int(UInt16.max) else { continue }
            var framed = Data([UInt8(reply.count >> 8), UInt8(reply.count & 0xFF)])
            framed.append(reply)
            guard writeAll(fd, framed) else {
                dropClient(fd)
                return
            }
        }
    }

    /// Loopback writes rarely block; when they do, wait briefly for POLLOUT.
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if n > 0 {
                sent += n
                continue
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, 1000) > 0 else { return false }
        }
        return true
    }

    private func dropClient(_ fd: Int32) {
        clients.removeValue(forKey: fd)?.source.cancel()
    }

    // MARK: - Watchdog (on `queue`)

    /// Trust only real answers: every minute (and on demand after wake) fire
    /// an actual query at the socket from outside the server queue. Silence
    /// while we believe we're bound means the transport is lying — tear down
    /// and rebind. This is the net for failure modes nobody has met yet.
    private func armWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.selfProbe() }
        timer.resume()
        watchdog = timer
    }

    private func selfProbe() {
        guard wantsRunning, udpFD >= 0 else { return }
        let port = self.port
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let alive = Self.probeOnce(port: port)
            guard let self else { return }
            self.queue.async {
                guard self.wantsRunning, self.udpFD >= 0 else { return }
                if alive {
                    return
                }
                Self.log.fault("liveness probe got no answer on 127.0.0.1:\(port, privacy: .public) — rebinding")
                self.currentError = "Server went silent — rebinding."
                self.teardown()
                self.retryDelay = Self.initialRetryDelay
                self.attemptBind()
            }
        }
    }

    /// One UDP query from a throwaway socket; ANY reply (even NXDOMAIN or
    /// REFUSED) proves the pipeline is alive.
    private static func probeOnce(port: UInt16) -> Bool {
        guard let query = DNSClient.encodeQuery(
            id: UInt16.random(in: 1 ... .max),
            name: "probe.localdns.invalid",
            qtype: DNSMessage.typeA
        ) else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sent = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                query.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, query.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return false }
        var buf = [UInt8](repeating: 0, count: 512)
        return recv(fd, &buf, buf.count, 0) > 0
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }

    /// Parses the datagram; malformed packets are dropped (no id to answer with).
    private func process(_ data: Data) -> Data? {
        guard let query = try? DNSMessage.parseQuery(data) else { return nil }
        return handler(query)
    }
}
