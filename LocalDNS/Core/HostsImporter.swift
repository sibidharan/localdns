import Foundation

/// One non-comment line of a hosts file: an address and the names mapped to it.
public struct HostsEntry: Equatable, Sendable {
    public let ip: String
    /// Names on the line, normalized (lowercase, no trailing dot).
    public let names: [String]

    public init(ip: String, names: [String]) {
        self.ip = ip
        self.names = names
    }
}

/// A wildcard-rule suggestion derived from hosts-file analysis.
public struct SuggestedRule: Equatable, Sendable {
    /// "*.<parent domain>"
    public let pattern: String
    public let ip: String
    /// Distinct hostnames from the hosts file this pattern would cover, sorted.
    public let coveredHostnames: [String]

    public init(pattern: String, ip: String, coveredHostnames: [String]) {
        self.pattern = pattern
        self.ip = ip
        self.coveredHostnames = coveredHostnames
    }

    /// The suggestion as a DNSRule (group "Imported"); v4/v6 chosen by address shape.
    public var rule: DNSRule {
        ip.contains(":")
            ? DNSRule(pattern: pattern, ipv6: ip, group: "Imported")
            : DNSRule(pattern: pattern, ipv4: ip, group: "Imported")
    }
}

/// Suggests wildcard rules by analyzing hosts-file content — the bridge for
/// migrating from hosts-based setups (e.g. Helm-managed /etc/hosts blocks).
///
/// All logic is pure and string-injectable; only `loadSystemHosts()` touches the
/// real file (which is world-readable, so no privileges are needed).
public enum HostsImporter {
    /// The broadcast address entry is never a suggestion source.
    static let ignoredAddress = "255.255.255.255"
    /// Machine-name entries that never produce suggestions.
    static let ignoredNames: Set<String> = ["localhost", "broadcasthost"]

    /// Parses hosts-file text: one entry per non-comment, non-empty line.
    /// Inline comments are stripped; fields may be space- or tab-separated;
    /// lines without any name are skipped.
    public static func parse(_ text: String) -> [HostsEntry] {
        var entries: [HostsEntry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let withoutComment = rawLine.prefix { $0 != "#" }
            let fields = withoutComment.split { $0 == " " || $0 == "\t" || $0 == "\r" }
            guard let ip = fields.first, fields.count > 1 else { continue }
            entries.append(HostsEntry(ip: String(ip),
                                      names: fields.dropFirst().map { DNSRule.normalize(String($0)) }))
        }
        return entries
    }

    /// Groups hostnames by (address, parent domain); every group with at least
    /// two distinct hostnames becomes a "*.<parent>" suggestion. Parent domain =
    /// everything after the first label. Single-label names, localhost,
    /// broadcasthost, and the 255.255.255.255 entry are ignored.
    public static func suggestions(entries: [HostsEntry]) -> [SuggestedRule] {
        var namesByGroup: [String: (ip: String, parent: String, names: Set<String>)] = [:]
        for entry in entries where entry.ip != ignoredAddress {
            for name in entry.names {
                guard !ignoredNames.contains(name),
                      let firstDot = name.firstIndex(of: ".") else { continue }
                let parent = String(name[name.index(after: firstDot)...])
                guard !parent.isEmpty else { continue }
                let key = "\(entry.ip)\u{1F}\(parent)"
                namesByGroup[key, default: (entry.ip, parent, [])].names.insert(name)
            }
        }
        return namesByGroup.values
            .filter { $0.names.count >= 2 }
            .map { SuggestedRule(pattern: "*.\($0.parent)", ip: $0.ip, coveredHostnames: $0.names.sorted()) }
            .sorted { ($0.pattern, $0.ip) < ($1.pattern, $1.ip) }
    }

    /// Multi-label, non-ignored hostnames from `entries` that no enabled rule
    /// currently matches — the gaps a user may still want to add rules for.
    public static func uncovered(entries: [HostsEntry], rules: [DNSRule]) -> [String] {
        var names = Set<String>()
        for entry in entries where entry.ip != ignoredAddress {
            for name in entry.names where name.contains(".") && !ignoredNames.contains(name) {
                names.insert(name)
            }
        }
        return names
            .filter { RuleMatcher.bestMatch(for: $0, in: rules) == nil }
            .sorted()
    }

    /// Convenience: parses the real /etc/hosts (world-readable; no privileges).
    public static func loadSystemHosts() -> [HostsEntry] {
        guard let text = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else { return [] }
        return parse(text)
    }
}
