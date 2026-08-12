import Foundation
import Network

public enum DNSClientError: Error, Equatable, LocalizedError {
    case invalidName
    case invalidPort
    case timeout
    case network(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Invalid query name."
        case .invalidPort: return "Invalid port."
        case .timeout: return "Timed out waiting for a response."
        case .network(let message): return message
        case .malformedResponse(let detail): return "Malformed response (\(detail))."
        }
    }
}

/// The parsed result of one lookup: header RCODE plus the A/AAAA answers
/// formatted as address strings.
public struct DNSLookupResult: Equatable, Sendable {
    public let rcode: UInt8
    public let answers: [String]

    public init(rcode: UInt8, answers: [String]) {
        self.rcode = rcode
        self.answers = answers
    }
}

/// Minimal DNS client, used by the in-app self-test to verify the server
/// answers on 127.0.0.1:<port>. Codec parts are pure functions (unit-tested
/// without any network traffic); `lookup` does one UDP round-trip.
public enum DNSClient {

    /// Builds a wire-format query for `name` (RD set, one question, class IN).
    /// Returns nil for empty names, oversized labels, or oversized packets.
    public static func encodeQuery(id: UInt16, name: String, qtype: UInt16) -> Data? {
        let normalized = DNSRule.normalize(name)
        guard !normalized.isEmpty else { return nil }
        var question = Data()
        for label in normalized.split(separator: ".") {
            guard label.utf8.count <= 63 else { return nil }
            question.append(UInt8(label.utf8.count))
            question.append(contentsOf: label.utf8)
        }
        question.append(0)
        guard question.count <= 255 else { return nil }

        var data = Data()
        func appendU16(_ value: UInt16) {
            data.append(UInt8(value >> 8))
            data.append(UInt8(value & 0xFF))
        }
        appendU16(id)
        appendU16(0x0100) // RD
        appendU16(1)      // QDCOUNT
        appendU16(0)      // ANCOUNT
        appendU16(0)      // NSCOUNT
        appendU16(0)      // ARCOUNT
        data.append(question)
        appendU16(qtype)
        appendU16(DNSMessage.classIN)
        return data
    }

    /// Parses a response packet: verifies the transaction id, reads the RCODE,
    /// skips the question section, and decodes A/AAAA answers to text.
    public static func parseResponse(_ data: Data, expectedID: UInt16) throws -> DNSLookupResult {
        guard data.count >= 12 else { throw DNSClientError.malformedResponse("short header") }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        guard u16(0) == expectedID else { throw DNSClientError.malformedResponse("id mismatch") }
        let rcode = UInt8(u16(2) & 0x000F)
        let qdcount = Int(u16(4))
        let ancount = Int(u16(6))

        var offset = 12
        for _ in 0 ..< qdcount {
            offset = try skipName(bytes, at: offset) + 4
            guard offset <= bytes.count else { throw DNSClientError.malformedResponse("question overrun") }
        }

        var answers: [String] = []
        for _ in 0 ..< ancount {
            let nameEnd = try skipName(bytes, at: offset)
            guard nameEnd + 10 <= bytes.count else { throw DNSClientError.malformedResponse("answer overrun") }
            let type = u16(nameEnd)
            let rdlength = Int(u16(nameEnd + 8))
            let rdataStart = nameEnd + 10
            guard rdataStart + rdlength <= bytes.count else {
                throw DNSClientError.malformedResponse("rdata overrun")
            }
            let rdata = Data(bytes[rdataStart ..< rdataStart + rdlength])
            switch (type, rdlength) {
            case (DNSMessage.typeA, 4):
                answers.append(rdata.map(String.init).joined(separator: "."))
            case (DNSMessage.typeAAAA, 16):
                if let address = IPv6Address(rdata) { answers.append(address.debugDescription) }
            default:
                break // record types we don't display
            }
            offset = rdataStart + rdlength
        }
        return DNSLookupResult(rcode: rcode, answers: answers)
    }

    /// Skips over a (possibly compressed) name, returning the offset after it.
    private static func skipName(_ bytes: [UInt8], at offset: Int) throws -> Int {
        do {
            return try DNSMessage.decodeName(bytes, offset: offset).nextOffset
        } catch {
            throw DNSClientError.malformedResponse("bad name")
        }
    }

    /// Sends one UDP query to 127.0.0.1:`port` and awaits the parsed response.
    /// Times out after `timeout` seconds.
    public static func lookup(name: String, qtype: UInt16 = DNSMessage.typeA,
                              port: UInt16, timeout: TimeInterval = 3) async throws -> DNSLookupResult {
        let id = UInt16.random(in: 0 ... UInt16.max)
        guard let packet = encodeQuery(id: id, name: name, qtype: qtype) else {
            throw DNSClientError.invalidName
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw DNSClientError.invalidPort
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = LookupSession()
            let connection = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .udp)
            let queue = DispatchQueue(label: "com.localdns.dnsclient")

            session.timeoutItem = DispatchWorkItem {
                if session.tryResume() {
                    connection.cancel()
                    continuation.resume(throwing: DNSClientError.timeout)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: packet, completion: .contentProcessed { error in
                        if error != nil {
                            if session.tryResume() {
                                session.timeoutItem?.cancel()
                                connection.cancel()
                                continuation.resume(throwing: DNSClientError.network("send failed"))
                            }
                            return
                        }
                        connection.receiveMessage { content, _, _, error in
                            guard session.tryResume() else { return }
                            session.timeoutItem?.cancel()
                            connection.cancel()
                            if let content {
                                do {
                                    continuation.resume(returning: try parseResponse(content, expectedID: id))
                                } catch {
                                    continuation.resume(throwing: error)
                                }
                            } else {
                                continuation.resume(throwing: DNSClientError.network(
                                    error?.localizedDescription ?? "no response"))
                            }
                        }
                    })
                case .failed(let error):
                    if session.tryResume() {
                        session.timeoutItem?.cancel()
                        connection.cancel()
                        continuation.resume(throwing: DNSClientError.network(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            if let timeoutItem = session.timeoutItem {
                queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            }
        }
    }
}

/// Resume-once guard plus timeout storage for an in-flight lookup.
/// NW callbacks and the timeout race; only the first wins.
private final class LookupSession: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    var timeoutItem: DispatchWorkItem?

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}


// MARK: - Update check (direct-download builds)

/// Polls GitHub's releases/latest for a newer version — one unauthenticated
/// GET, ETag-cached so repeats are free. Used only by the direct-download
/// build; the App Store build compiles it out (APPSTORE flag) because MAS
/// apps must not self-update or advertise updates outside the store.
public final class UpdateChecker: @unchecked Sendable {
    public static let releasesPage = URL(string: "https://github.com/sibidharan/localdns/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/sibidharan/localdns/releases/latest")!
    private var etag: String?

    public init() {}

    /// Calls back with the newer version string ("0.2.2"), or nil when
    /// current, unreachable, or unchanged since the last check (ETag 304).
    public func check(currentVersion: String, completion: @escaping @Sendable (String?) -> Void) {
        var request = URLRequest(url: Self.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                completion(nil)
                return
            }
            self?.etag = http.value(forHTTPHeaderField: "ETag")
            guard let tag = Self.tagName(in: data),
                  Self.isNewer(tag, than: currentVersion) else {
                completion(nil)
                return
            }
            completion(Self.normalized(tag))
        }.resume()
    }

    /// "v0.2.2" → "0.2.2".
    public static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    public static func tagName(in json: Data) -> String? {
        struct Release: Decodable { let tag_name: String }
        return (try? JSONDecoder().decode(Release.self, from: json))?.tag_name
    }

    /// Numeric per-component compare — "0.10.0" beats "0.9.9"; missing
    /// components count as zero ("1.0" == "1.0.0").
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            normalized(s).split(separator: ".").compactMap { Int($0) }
        }
        let a = parts(tag)
        let b = parts(current)
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
