//! Wildcard-rule suggestions from hosts-file analysis. Port of `HostsImporter.swift`.
//!
//! All logic is pure and string-injectable; only `load_system_hosts()` touches
//! the real file (which is world-readable, so no privileges are needed).

use std::collections::{BTreeSet, HashMap};
use std::path::PathBuf;

use serde::Serialize;

use crate::rules::{best_match, normalize, rule_with_address, DnsRule};

/// The broadcast address entry is never a suggestion source.
const IGNORED_ADDRESS: &str = "255.255.255.255";
/// Machine-name entries that never produce suggestions.
const IGNORED_NAMES: [&str; 2] = ["localhost", "broadcasthost"];

/// One non-comment line of a hosts file: an address and the names mapped to it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HostsEntry {
    pub ip: String,
    /// Names on the line, normalized (lowercase, no trailing dot).
    pub names: Vec<String>,
}

/// A wildcard-rule suggestion derived from hosts-file analysis.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SuggestedRule {
    /// "*.<parent domain>"
    pub pattern: String,
    pub ip: String,
    /// Distinct hostnames from the hosts file this pattern would cover, sorted.
    pub covered_hostnames: Vec<String>,
}

impl SuggestedRule {
    /// The suggestion as a DnsRule (group "Imported"); v4/v6 chosen by address shape.
    pub fn rule(&self) -> DnsRule {
        rule_with_address(&self.pattern, &self.ip, "Imported")
    }
}

/// Parses hosts-file text: one entry per non-comment, non-empty line.
/// Inline comments are stripped; fields may be space- or tab-separated;
/// lines without any name are skipped.
pub fn parse(text: &str) -> Vec<HostsEntry> {
    let mut entries = Vec::new();
    for raw_line in text.split('\n') {
        let without_comment = raw_line.split('#').next().unwrap_or("");
        let mut fields = without_comment
            .split(|c| c == ' ' || c == '\t' || c == '\r')
            .filter(|f| !f.is_empty());
        let Some(ip) = fields.next() else { continue };
        let names: Vec<String> = fields.map(normalize).collect();
        if names.is_empty() {
            continue;
        }
        entries.push(HostsEntry {
            ip: ip.to_string(),
            names,
        });
    }
    entries
}

/// Groups hostnames by (address, parent domain); every group with at least
/// two distinct hostnames becomes a "*.<parent>" suggestion. Parent domain =
/// everything after the first label. Single-label names, localhost,
/// broadcasthost, and the 255.255.255.255 entry are ignored.
pub fn suggestions(entries: &[HostsEntry]) -> Vec<SuggestedRule> {
    let mut names_by_group: HashMap<(String, String), BTreeSet<String>> = HashMap::new();
    for entry in entries.iter().filter(|e| e.ip != IGNORED_ADDRESS) {
        for name in &entry.names {
            if IGNORED_NAMES.contains(&name.as_str()) {
                continue;
            }
            let Some(first_dot) = name.find('.') else {
                continue;
            };
            let parent = &name[first_dot + 1..];
            if parent.is_empty() {
                continue;
            }
            names_by_group
                .entry((entry.ip.clone(), parent.to_string()))
                .or_default()
                .insert(name.clone());
        }
    }
    let mut result: Vec<SuggestedRule> = names_by_group
        .into_iter()
        .filter(|(_, names)| names.len() >= 2)
        .map(|((ip, parent), names)| SuggestedRule {
            pattern: format!("*.{parent}"),
            ip,
            covered_hostnames: names.into_iter().collect(),
        })
        .collect();
    result.sort_by(|a, b| (&a.pattern, &a.ip).cmp(&(&b.pattern, &b.ip)));
    result
}

/// Multi-label, non-ignored hostnames from `entries` that no enabled rule
/// currently matches — the gaps a user may still want to add rules for.
pub fn uncovered(entries: &[HostsEntry], rules: &[DnsRule]) -> Vec<String> {
    let mut names = BTreeSet::new();
    for entry in entries.iter().filter(|e| e.ip != IGNORED_ADDRESS) {
        for name in entry
            .names
            .iter()
            .filter(|n| n.contains('.') && !IGNORED_NAMES.contains(&n.as_str()))
        {
            names.insert(name.clone());
        }
    }
    names
        .into_iter()
        .filter(|name| best_match(name, rules).is_none())
        .collect()
}

/// The platform's hosts file: /etc/hosts, or %SystemRoot%\System32\drivers\etc\hosts.
pub fn system_hosts_path() -> PathBuf {
    if cfg!(windows) {
        let root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
        PathBuf::from(root).join(r"System32\drivers\etc\hosts")
    } else {
        PathBuf::from("/etc/hosts")
    }
}

/// Convenience: parses the real hosts file (world-readable; no privileges).
pub fn load_system_hosts() -> Vec<HostsEntry> {
    match std::fs::read_to_string(system_hosts_path()) {
        Ok(text) => parse(&text),
        Err(_) => Vec::new(),
    }
}

// Port of HostsImporterTests.swift.
#[cfg(test)]
mod tests {
    use super::*;

    // MARK: Parsing

    #[test]
    fn parse_basics() {
        let text = "# full-line comment\n\
                    127.0.0.1 localhost\n\
                    172.30.0.3 api.myapp.test web.myapp.test # inline comment\n\
                    172.30.0.3\tdb.myapp.test\n\
                    \n\
                    ::1 ip6-localhost";
        let entries = parse(text);
        assert_eq!(entries.len(), 4);
        assert_eq!(
            entries[0],
            HostsEntry {
                ip: "127.0.0.1".into(),
                names: vec!["localhost".into()]
            }
        );
        assert_eq!(
            entries[1],
            HostsEntry {
                ip: "172.30.0.3".into(),
                names: vec!["api.myapp.test".into(), "web.myapp.test".into()]
            }
        );
        assert_eq!(
            entries[2],
            HostsEntry {
                ip: "172.30.0.3".into(),
                names: vec!["db.myapp.test".into()]
            }
        );
        assert_eq!(
            entries[3],
            HostsEntry {
                ip: "::1".into(),
                names: vec!["ip6-localhost".into()]
            }
        );
    }

    #[test]
    fn parse_normalizes_names() {
        let entries = parse("10.0.0.5 UPPER.Test.\n");
        assert_eq!(entries[0].names, vec!["upper.test"]);
    }

    #[test]
    fn parse_skips_blank_comment_and_address_only_lines() {
        assert_eq!(parse("\n# nothing\n   \n\t\n10.0.0.1\n"), vec![]);
    }

    // MARK: Suggestions

    #[test]
    fn suggestions_group_by_address_and_parent() {
        let entries = parse(
            "172.30.0.3 api.myapp.test web.myapp.test\n\
             172.30.0.3 db.myapp.test\n\
             10.0.0.2 api.other.test web.other.test\n\
             172.30.0.3 a.else.test b.else.test\n\
             10.0.0.9 solo.test\n\
             9.9.9.9 singlelabel",
        );
        let suggestions = suggestions(&entries);
        assert_eq!(suggestions.len(), 3);

        let myapp = suggestions
            .iter()
            .find(|s| s.pattern == "*.myapp.test")
            .unwrap();
        assert_eq!(myapp.ip, "172.30.0.3");
        assert_eq!(
            myapp.covered_hostnames,
            vec!["api.myapp.test", "db.myapp.test", "web.myapp.test"]
        );
        assert_eq!(myapp.rule().ipv4.as_deref(), Some("172.30.0.3"));
        assert_eq!(myapp.rule().group, "Imported");

        assert!(suggestions
            .iter()
            .any(|s| s.pattern == "*.other.test" && s.ip == "10.0.0.2"));
        assert!(suggestions
            .iter()
            .any(|s| s.pattern == "*.else.test" && s.ip == "172.30.0.3"));
        // one-host groups and single-label names never yield suggestions
        assert!(!suggestions.iter().any(|s| s.pattern == "*.test"));
    }

    #[test]
    fn suggestions_skip_ignored_entries() {
        let entries = parse(
            "127.0.0.1 localhost\n\
             255.255.255.255 broadcasthost\n\
             ::1 localhost\n\
             255.255.255.255 foo.bar.test baz.bar.test",
        );
        assert_eq!(suggestions(&entries), vec![]);
    }

    #[test]
    fn ipv6_suggestion() {
        let entries = parse("fd00::3 a.v6.test b.v6.test\n");
        let suggestions = suggestions(&entries);
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].pattern, "*.v6.test");
        assert_eq!(suggestions[0].rule().ipv6.as_deref(), Some("fd00::3"));
        assert!(suggestions[0].rule().ipv4.is_none());
    }

    // MARK: Coverage

    #[test]
    fn uncovered_names() {
        let entries = parse(
            "172.30.0.3 api.myapp.test db.myapp.test\n\
             10.0.0.2 stray.other.test\n\
             127.0.0.1 localhost\n\
             9.9.9.9 singlelabel",
        );
        let rules = vec![DnsRule {
            ipv4: Some("172.30.0.3".into()),
            ..DnsRule::new("*.myapp.test")
        }];
        assert_eq!(uncovered(&entries, &rules), vec!["stray.other.test"]);
        // a disabled rule covers nothing
        let disabled = vec![DnsRule {
            ipv4: Some("1.2.3.4".into()),
            enabled: false,
            ..DnsRule::new("*.myapp.test")
        }];
        assert_eq!(
            uncovered(&entries, &disabled),
            vec!["api.myapp.test", "db.myapp.test", "stray.other.test"]
        );
    }
}
