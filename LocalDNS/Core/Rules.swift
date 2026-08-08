import Foundation
import Network

/// A single wildcard or exact DNS override rule.
public struct DNSRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// e.g. "*.myapp.test" (wildcard) or "host.test" (exact). Case-insensitive.
    public var pattern: String
    public var ipv4: String?
    public var ipv6: String?
    public var ttl: UInt32
    public var enabled: Bool
    public var group: String

    public init(id: UUID = UUID(), pattern: String, ipv4: String? = nil, ipv6: String? = nil,
                ttl: UInt32 = 60, enabled: Bool = true, group: String = "Default") {
        self.id = id
        self.pattern = pattern
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.ttl = ttl
        self.enabled = enabled
        self.group = group
    }

    /// Lowercases `name` and strips any trailing dot(s).
    public static func normalize(_ name: String) -> String {
        var normalized = name.lowercased()
        while normalized.hasSuffix(".") { normalized.removeLast() }
        return normalized
    }

    public var normalizedPattern: String { DNSRule.normalize(pattern) }
    public var isWildcard: Bool { normalizedPattern.hasPrefix("*.") }

    /// Matching semantics (dnsmasq-style):
    /// - A wildcard rule "*.suffix" matches "suffix" itself AND any name ending
    ///   in ".suffix", at any depth ("a.b.suffix" matches).
    /// - An exact rule matches equal names only.
    /// `name` is normalized before comparison.
    public func matches(name: String) -> Bool {
        let name = DNSRule.normalize(name)
        let pattern = normalizedPattern
        guard !pattern.isEmpty else { return false }
        if isWildcard {
            let suffix = String(pattern.dropFirst(2))
            guard !suffix.isEmpty else { return false }
            return name == suffix || name.hasSuffix("." + suffix)
        }
        return name == pattern
    }
}

/// Picks the winning rule for a name.
public enum RuleMatcher {
    /// Among enabled rules matching `name`, the one with the longest pattern wins
    /// ("*.myapp.test" beats "*.test"). Ties keep the earlier rule. Disabled
    /// rules are skipped.
    public static func bestMatch(for name: String, in rules: [DNSRule]) -> DNSRule? {
        var best: DNSRule?
        for rule in rules where rule.enabled && rule.matches(name: name) {
            if let current = best, rule.normalizedPattern.count <= current.normalizedPattern.count {
                continue
            }
            best = rule
        }
        return best
    }
}

/// JSON-backed persistence for DNS rules.
public struct RuleStore: Sendable {
    public var rules: [DNSRule]
    public let fileURL: URL

    /// Loads rules from `fileURL` if present; starts empty otherwise.
    public init(fileURL: URL = RuleStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.rules = (try? RuleStore.loadRules(from: fileURL)) ?? []
    }

    /// In-memory store seeded with `rules` (used by tests).
    public init(fileURL: URL, rules: [DNSRule]) {
        self.fileURL = fileURL
        self.rules = rules
    }

    /// rules.json inside the (sandbox container's) Application Support directory.
    public static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("LocalDNS", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    public static func loadRules(from url: URL) throws -> [DNSRule] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([DNSRule].self, from: data)
    }

    /// Atomic-ish write: encode, then Data.write with .atomic (temp file + rename).
    public func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: fileURL, options: .atomic)
    }
}

/// The answering decision for a query.
public enum DNSResolution: Equatable, Sendable {
    /// NOERROR with answer records.
    case answers([DNSAnswer])
    /// NOERROR with an empty answer section (NODATA): a rule matched the name but
    /// holds no record of the queried family (e.g. AAAA asked, only IPv4 configured).
    case noData
    /// No enabled rule matched the name.
    case nxdomain
}

/// Maps a parsed query plus the current rules to a resolution. Only the name and
/// qtype matter; the query class is ignored (IN is the only class seen in practice).
public enum DNSResolver {
    public static func resolve(_ query: DNSQuery, rules: [DNSRule]) -> DNSResolution {
        guard let rule = RuleMatcher.bestMatch(for: query.name, in: rules) else {
            return .nxdomain
        }
        switch query.qtype {
        case DNSMessage.typeA:
            guard let text = rule.ipv4, let address = IPv4Address(text) else { return .noData }
            return .answers([DNSAnswer(qtype: DNSMessage.typeA, ttl: rule.ttl, rdata: address.rawValue)])
        case DNSMessage.typeAAAA:
            guard let text = rule.ipv6, let address = IPv6Address(text) else { return .noData }
            return .answers([DNSAnswer(qtype: DNSMessage.typeAAAA, ttl: rule.ttl, rdata: address.rawValue)])
        default:
            // The name exists; we simply hold no records of this type.
            return .noData
        }
    }

    /// Convenience: resolve and serialize the wire response in one step.
    public static func responseData(for query: DNSQuery, rules: [DNSRule]) -> Data {
        switch resolve(query, rules: rules) {
        case .answers(let answers):
            return DNSResponseBuilder.response(to: query, answers: answers)
        case .noData:
            return DNSResponseBuilder.empty(to: query)
        case .nxdomain:
            return DNSResponseBuilder.nxdomain(to: query)
        }
    }
}
