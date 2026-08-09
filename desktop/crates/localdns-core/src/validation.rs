//! Pattern validation for DNS rules. Port of `RuleValidation.swift`.

use crate::rules::normalize;

/// Multi-label public suffixes that pass the two-label check but are still
/// shared infrastructure — wildcarding them breaks ordinary browsing.
/// (Single-label TLDs like `com` are already rejected by the general
/// two-label minimum below.)
const BLOCKED_PUBLIC_SUFFIXES: [&str; 17] = [
    "co.uk", "org.uk", "ac.uk", "gov.uk", //
    "com.au", "net.au", "org.au", //
    "co.in", "com.br", "com.cn", "com.sg", "com.mx", //
    "co.jp", "co.nz", "co.kr", "com.tr", "com.tw",
];

/// Validates `*.something.tld` / `host.tld` patterns. Returns None when valid.
///
/// Guards beyond basic hostname syntax:
/// - A wildcard may not cover a shared public suffix (`*.co.uk`): the zone
///   registers a resolver for the whole suffix, so every unrelated name in
///   it would NXDOMAIN — effectively breaking ordinary browsing.
pub fn pattern_error(pattern: &str) -> Option<String> {
    let normalized = normalize(pattern.trim());
    if normalized.is_empty() {
        return Some("Pattern is required.".into());
    }
    if normalized.contains(' ') {
        return Some("No spaces allowed.".into());
    }
    let is_wildcard = normalized.starts_with("*.");
    let body = if is_wildcard {
        &normalized[2..]
    } else {
        normalized.as_str()
    };
    if body.contains('*') {
        return Some("“*” is only allowed as the leading “*.”.".into());
    }
    let labels: Vec<&str> = body.split('.').collect();
    if labels.len() < 2 {
        return Some("Use a full name like “*.myapp.test” or “host.test”.".into());
    }
    for label in &labels {
        if label.is_empty() {
            return Some("Empty label — check the dots.".into());
        }
        if label.starts_with('-') || label.ends_with('-') {
            return Some("Labels can't start or end with “-”.".into());
        }
        if label
            .chars()
            .any(|c| !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'))
        {
            return Some("Only letters, digits, and “-” per label.".into());
        }
    }
    if is_wildcard && BLOCKED_PUBLIC_SUFFIXES.contains(&body) {
        return Some(format!(
            "“*.{body}” covers a shared public suffix — that would break normal browsing. Wildcard your own zone instead (e.g. “*.myapp.{body}”)."
        ));
    }
    None
}

/// True when the pattern lives under the `.local` TLD, which Bonjour/mDNS
/// owns. Wildcarding there can interfere with network services — the UI
/// warns (does not block). Note `*.local` itself is already rejected by
/// the two-label wildcard guard; this flags `*.myapp.local` / `host.local`.
pub fn uses_local_tld(pattern: &str) -> bool {
    let normalized = normalize(pattern.trim());
    let body = normalized.strip_prefix("*.").unwrap_or(&normalized);
    body == "local" || body.ends_with(".local")
}

// Port of RuleValidationTests.swift.
#[cfg(test)]
mod tests {
    use super::*;

    // MARK: Existing syntax behavior (preserved from the sheet's validator)

    #[test]
    fn valid_patterns_pass() {
        assert_eq!(pattern_error("*.myapp.test"), None);
        assert_eq!(pattern_error("host.test"), None);
        assert_eq!(pattern_error("*.local.selfmade.codes"), None);
        assert_eq!(pattern_error("  *.spaced.test  "), None); // trimmed
    }

    #[test]
    fn syntax_errors() {
        assert!(pattern_error("").is_some());
        assert!(pattern_error("bad pattern").is_some()); // space
        assert!(pattern_error("foo.*.test").is_some()); // * mid-name
        assert!(pattern_error("single").is_some()); // < 2 labels
        assert!(pattern_error("a..test").is_some()); // empty label
        assert!(pattern_error("-a.test").is_some()); // leading -
        assert!(pattern_error("a-.test").is_some()); // trailing -
        assert!(pattern_error("münchen.test").is_some()); // non-ascii
    }

    // MARK: Public-suffix foot-guns

    /// Single-label TLDs are already rejected by the two-label minimum.
    #[test]
    fn tld_wildcards_are_blocked() {
        assert!(pattern_error("*.com").is_some());
        assert!(pattern_error("*.test").is_some());
        assert!(pattern_error("*.local").is_some());
        assert!(pattern_error("*.in").is_some());
    }

    /// Multi-label public suffixes pass the two-label check but must still be
    /// blocked — wildcarding them breaks ordinary browsing.
    #[test]
    fn public_suffix_wildcards_are_blocked() {
        for suffix in ["co.uk", "com.au", "co.in", "com.br"] {
            assert!(
                pattern_error(&format!("*.{suffix}")).is_some(),
                "*.{suffix} should be blocked"
            );
        }
    }

    /// Wildcarding YOUR OWN zone under a public suffix is fine.
    #[test]
    fn own_zone_under_public_suffix_is_allowed() {
        assert_eq!(pattern_error("*.myapp.co.uk"), None);
    }

    /// Exact rules on public suffixes are not blocked (they only claim one name;
    /// the zone-wide effect is a documented trade-off).
    #[test]
    fn exact_rule_on_public_suffix_is_allowed() {
        assert_eq!(pattern_error("host.co.uk"), None);
    }

    // MARK: .local warning

    #[test]
    fn uses_local_tld_flags() {
        assert!(uses_local_tld("*.myapp.local"));
        assert!(uses_local_tld("host.local"));
        assert!(uses_local_tld("*.deep.myapp.local"));
        assert!(!uses_local_tld("*.myapp.test"));
        assert!(!uses_local_tld("local.selfmade.codes")); // not the TLD
        assert!(!uses_local_tld("*.localselfmade.codes"));
    }
}
