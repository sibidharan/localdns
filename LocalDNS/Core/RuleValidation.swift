import Foundation

/// Pattern validation for DNS rules, shared by the edit sheet and unit tests.
public enum RuleValidation {

    /// Multi-label public suffixes that pass the two-label check but are still
    /// shared infrastructure — wildcarding them breaks ordinary browsing.
    /// (Single-label TLDs like `com` are already rejected by the general
    /// two-label minimum below.)
    static let blockedPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk",
        "com.au", "net.au", "org.au",
        "co.in", "com.br", "com.cn", "com.sg", "com.mx",
        "co.jp", "co.nz", "co.kr", "com.tr", "com.tw",
    ]

    /// Validates `*.something.tld` / `host.tld` patterns. Returns nil when valid.
    ///
    /// Guards beyond basic hostname syntax:
    /// - A wildcard may not cover a shared public suffix (`*.co.uk`): the zone
    ///   registers a resolver for the whole suffix, so every unrelated name in
    ///   it would NXDOMAIN — effectively breaking ordinary browsing.
    public static func patternError(for pattern: String) -> String? {
        let normalized = DNSRule.normalize(pattern.trimmingCharacters(in: .whitespaces))
        if normalized.isEmpty { return "Pattern is required." }
        if normalized.contains(" ") { return "No spaces allowed." }
        let isWildcard = normalized.hasPrefix("*.")
        let body = isWildcard ? String(normalized.dropFirst(2)) : normalized
        if body.contains("*") { return "“*” is only allowed as the leading “*.”." }
        let labels = body.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count < 2 { return "Use a full name like “*.myapp.test” or “host.test”." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            if label.isEmpty { return "Empty label — check the dots." }
            if label.hasPrefix("-") || label.hasSuffix("-") { return "Labels can't start or end with “-”." }
            if label.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                return "Only letters, digits, and “-” per label."
            }
        }
        if isWildcard, blockedPublicSuffixes.contains(body) {
            return "“*.\(body)” covers a shared public suffix — that would break normal browsing. Wildcard your own zone instead (e.g. “*.myapp.\(body)”)."
        }
        return nil
    }

    /// True when the pattern lives under the `.local` TLD, which Bonjour/mDNS
    /// owns. Wildcarding there can interfere with network services — the UI
    /// warns (does not block). Note `*.local` itself is already rejected by
    /// the two-label wildcard guard; this flags `*.myapp.local` / `host.local`.
    public static func usesLocalTLD(_ pattern: String) -> Bool {
        let normalized = DNSRule.normalize(pattern.trimmingCharacters(in: .whitespaces))
        let body = normalized.hasPrefix("*.") ? String(normalized.dropFirst(2)) : normalized
        return body == "local" || body.hasSuffix(".local")
    }
}
