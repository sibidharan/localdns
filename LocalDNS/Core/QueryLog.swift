import Foundation
import Network

/// One DNS query the server handled.
public struct QueryLogEntry: Codable, Equatable, Identifiable, Sendable {
    /// How the server answered.
    public enum Outcome: Codable, Equatable, Sendable {
        /// An answer was returned; the value is the address (e.g. "172.30.0.3").
        case answered(String)
        /// Name matched a rule, but no record of the queried family exists.
        case noData
        /// No rule matched.
        case nxdomain
    }

    public let id: UUID
    public let timestamp: Date
    /// Queried name (normalized).
    public let name: String
    /// "A", "AAAA", or "TYPE<n>" for anything else.
    public let qtype: String
    public let outcome: Outcome
    /// Time taken by the resolver decision, in milliseconds.
    public let latencyMs: Double

    public init(id: UUID = UUID(), timestamp: Date = Date(), name: String, qtype: String,
                outcome: Outcome, latencyMs: Double = 0) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.qtype = qtype
        self.outcome = outcome
        self.latencyMs = latencyMs
    }

    /// Builds an entry straight from a server query plus its resolution.
    public init(query: DNSQuery, resolution: DNSResolution, latencyMs: Double) {
        let qtype: String
        switch query.qtype {
        case DNSMessage.typeA: qtype = "A"
        case DNSMessage.typeAAAA: qtype = "AAAA"
        default: qtype = "TYPE\(query.qtype)"
        }
        let outcome: Outcome
        switch resolution {
        case .answers(let answers):
            outcome = .answered(answers.first.map(QueryLogEntry.describe) ?? "<none>")
        case .noData:
            outcome = .noData
        case .nxdomain:
            outcome = .nxdomain
        }
        self.init(name: query.name, qtype: qtype, outcome: outcome, latencyMs: latencyMs)
    }

    private static func describe(_ answer: DNSAnswer) -> String {
        switch answer.qtype {
        case DNSMessage.typeA where answer.rdata.count == 4:
            return answer.rdata.map(String.init).joined(separator: ".")
        case DNSMessage.typeAAAA where answer.rdata.count == 16:
            return IPv6Address(answer.rdata)?.debugDescription ?? "<invalid>"
        default:
            return "<invalid>"
        }
    }
}

/// Thread-safe ring buffer of recent queries, newest first, capacity-capped.
/// Plain class with no Combine/SwiftUI so Core stays UI-framework-free;
/// AppState will publish snapshots for the UI.
public final class QueryLog: @unchecked Sendable {
    public let capacity: Int
    private var storage: [QueryLogEntry] = [] // newest first
    private let lock = NSLock()

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    /// Snapshot of the buffer, newest first.
    public var entries: [QueryLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    public func append(_ entry: QueryLogEntry) {
        lock.lock()
        storage.insert(entry, at: 0)
        if storage.count > capacity {
            storage.removeLast(storage.count - capacity)
        }
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}
