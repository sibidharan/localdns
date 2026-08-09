//! Rule model, matching, resolution, and JSON persistence. Port of `Rules.swift`.

use std::collections::HashMap;
use std::io::Write;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize, Serializer};
use uuid::Uuid;

use crate::message::{self, DnsAnswer, DnsQuery};

/// Swift's JSONEncoder writes UUIDs uppercase-hyphenated; matching it keeps a
/// rules.json written here loadable-and-identical on the Mac side.
fn serialize_uuid_upper<S: Serializer>(id: &Uuid, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&id.hyphenated().to_string().to_uppercase())
}

/// A single wildcard or exact DNS override rule.
///
/// Field order is alphabetical on purpose: serde_json emits keys in declaration
/// order, which reproduces the `.sortedKeys` output of the macOS app, so the
/// two apps generate interchangeable rules.json files.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DnsRule {
    pub enabled: bool,
    pub group: String,
    #[serde(serialize_with = "serialize_uuid_upper")]
    pub id: Uuid,
    /// e.g. "*.myapp.test" (wildcard) or "host.test" (exact). Case-insensitive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ipv4: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ipv6: Option<String>,
    pub pattern: String,
    pub ttl: u32,
}

impl DnsRule {
    /// Defaults matching the Swift initializer: ttl 60, enabled, group "Default".
    pub fn new(pattern: impl Into<String>) -> Self {
        Self {
            enabled: true,
            group: "Default".into(),
            id: Uuid::new_v4(),
            ipv4: None,
            ipv6: None,
            pattern: pattern.into(),
            ttl: 60,
        }
    }

    pub fn normalized_pattern(&self) -> String {
        normalize(&self.pattern)
    }

    pub fn is_wildcard(&self) -> bool {
        self.normalized_pattern().starts_with("*.")
    }

    /// Matching semantics (dnsmasq-style):
    /// - A wildcard rule "*.suffix" matches "suffix" itself AND any name ending
    ///   in ".suffix", at any depth ("a.b.suffix" matches).
    /// - An exact rule matches equal names only.
    /// `name` is normalized before comparison.
    pub fn matches(&self, name: &str) -> bool {
        let name = normalize(name);
        let pattern = self.normalized_pattern();
        if pattern.is_empty() {
            return false;
        }
        if let Some(suffix) = pattern.strip_prefix("*.") {
            if suffix.is_empty() {
                return false;
            }
            return name == suffix || name.ends_with(&format!(".{suffix}"));
        }
        name == pattern
    }
}

/// Lowercases `name` and strips any trailing dot(s).
pub fn normalize(name: &str) -> String {
    let mut normalized = name.to_lowercase();
    while normalized.ends_with('.') {
        normalized.pop();
    }
    normalized
}

/// Among enabled rules matching `name`, the one with the longest pattern wins
/// ("*.myapp.test" beats "*.test"). Ties keep the earlier rule. Disabled
/// rules are skipped. (Pattern length is counted in characters, as in Swift.)
pub fn best_match<'a>(name: &str, rules: &'a [DnsRule]) -> Option<&'a DnsRule> {
    let mut best: Option<&DnsRule> = None;
    for rule in rules.iter().filter(|r| r.enabled && r.matches(name)) {
        if let Some(current) = best {
            if rule.normalized_pattern().chars().count()
                <= current.normalized_pattern().chars().count()
            {
                continue;
            }
        }
        best = Some(rule);
    }
    best
}

/// The answering decision for a query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DnsResolution {
    /// NOERROR with answer records.
    Answers(Vec<DnsAnswer>),
    /// NOERROR with an empty answer section (NODATA): a rule matched the name but
    /// holds no record of the queried family (e.g. AAAA asked, only IPv4 configured).
    NoData,
    /// No enabled rule matched the name.
    Nxdomain,
}

/// Maps a parsed query plus the current rules to a resolution. Only the name and
/// qtype matter; the query class is ignored (IN is the only class seen in practice).
pub fn resolve(query: &DnsQuery, rules: &[DnsRule]) -> DnsResolution {
    let Some(rule) = best_match(&query.name, rules) else {
        return DnsResolution::Nxdomain;
    };
    match query.qtype {
        message::TYPE_A => {
            let Some(address) = rule.ipv4.as_deref().and_then(|t| t.parse::<Ipv4Addr>().ok())
            else {
                return DnsResolution::NoData;
            };
            DnsResolution::Answers(vec![DnsAnswer {
                qtype: message::TYPE_A,
                ttl: rule.ttl,
                rdata: address.octets().to_vec(),
            }])
        }
        message::TYPE_AAAA => {
            let Some(address) = rule.ipv6.as_deref().and_then(|t| t.parse::<Ipv6Addr>().ok())
            else {
                return DnsResolution::NoData;
            };
            DnsResolution::Answers(vec![DnsAnswer {
                qtype: message::TYPE_AAAA,
                ttl: rule.ttl,
                rdata: address.octets().to_vec(),
            }])
        }
        // The name exists; we simply hold no records of this type.
        _ => DnsResolution::NoData,
    }
}

/// Convenience: resolve and serialize the wire response in one step.
pub fn response_data(query: &DnsQuery, rules: &[DnsRule]) -> Vec<u8> {
    match resolve(query, rules) {
        DnsResolution::Answers(answers) => message::response::answers(query, &answers),
        DnsResolution::NoData => message::response::empty(query),
        DnsResolution::Nxdomain => message::response::nxdomain(query),
    }
}

/// JSON-backed persistence for DNS rules.
#[derive(Debug, Clone)]
pub struct RuleStore {
    pub rules: Vec<DnsRule>,
    pub path: PathBuf,
}

impl RuleStore {
    /// Loads rules from `path` if present; starts empty otherwise.
    pub fn load(path: PathBuf) -> Self {
        let rules = Self::load_rules(&path).unwrap_or_default();
        Self { rules, path }
    }

    /// In-memory store seeded with `rules` (used by tests).
    pub fn with_rules(path: PathBuf, rules: Vec<DnsRule>) -> Self {
        Self { rules, path }
    }

    pub fn load_rules(path: &Path) -> Result<Vec<DnsRule>, std::io::Error> {
        let data = std::fs::read(path)?;
        serde_json::from_slice(&data).map_err(std::io::Error::other)
    }

    /// Atomic write: pretty JSON to a temp file in the same directory, then rename.
    pub fn save(&self) -> Result<(), std::io::Error> {
        let parent = self.path.parent().unwrap_or_else(|| Path::new("."));
        std::fs::create_dir_all(parent)?;
        let json = serde_json::to_string_pretty(&self.rules).map_err(std::io::Error::other)?;
        let mut tmp = tempfile::NamedTempFile::new_in(parent)?;
        tmp.write_all(json.as_bytes())?;
        tmp.persist(&self.path)?;
        Ok(())
    }
}

/// Live "what will this answer" preview for the edit sheet: the winning rule for
/// a name, if any, among `rules` plus a candidate being edited.
pub fn preview_match<'a>(name: &str, rules: &'a [DnsRule]) -> Option<&'a DnsRule> {
    best_match(name, rules)
}

// Suggestion helper shared with hosts import.
pub(crate) fn rule_with_address(pattern: &str, ip: &str, group: &str) -> DnsRule {
    let mut rule = DnsRule::new(pattern);
    rule.group = group.into();
    if ip.contains(':') {
        rule.ipv6 = Some(ip.into());
    } else {
        rule.ipv4 = Some(ip.into());
    }
    rule
}

/// Groups rules preserving insertion order of first appearance (RulesView shape).
pub fn groups(rules: &[DnsRule]) -> Vec<(String, Vec<&DnsRule>)> {
    let mut order: Vec<String> = Vec::new();
    let mut by_group: HashMap<String, Vec<&DnsRule>> = HashMap::new();
    for rule in rules {
        if !by_group.contains_key(&rule.group) {
            order.push(rule.group.clone());
        }
        by_group.entry(rule.group.clone()).or_default().push(rule);
    }
    order
        .into_iter()
        .map(|g| {
            let rules = by_group.remove(&g).unwrap_or_default();
            (g, rules)
        })
        .collect()
}

// Port of RulesTests.swift.
#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::{TYPE_A, TYPE_AAAA};

    fn rule_v4(pattern: &str, ipv4: &str) -> DnsRule {
        DnsRule {
            ipv4: Some(ipv4.into()),
            ..DnsRule::new(pattern)
        }
    }

    fn make_query(name: &str, qtype: u16) -> DnsQuery {
        DnsQuery::new(1, normalize(name), qtype)
    }

    // MARK: Matching

    #[test]
    fn wildcard_matches_apex_and_deep_subdomains() {
        let rule = rule_v4("*.myapp.test", "172.30.0.3");
        assert!(rule.matches("myapp.test")); // apex itself
        assert!(rule.matches("api.myapp.test"));
        assert!(rule.matches("a.b.c.myapp.test")); // any depth
        assert!(rule.matches("API.MyApp.TEST.")); // normalization
        assert!(!rule.matches("other.test"));
        assert!(!rule.matches("notmyapp.test"));
        assert!(!rule.matches("myapp.test.evil.com"));
    }

    #[test]
    fn exact_rule_matches_only_equal_names() {
        let rule = rule_v4("host.test", "10.0.0.1");
        assert!(rule.matches("host.test"));
        assert!(rule.matches("HOST.test."));
        assert!(!rule.matches("sub.host.test"));
        assert!(!rule.matches("host.testx"));
    }

    #[test]
    fn rule_defaults() {
        let rule = DnsRule::new("x.test");
        assert_eq!(rule.ttl, 60);
        assert_eq!(rule.group, "Default");
        assert!(rule.enabled);
        assert!(rule.ipv4.is_none());
        assert!(rule.ipv6.is_none());
    }

    // MARK: Resolution

    #[test]
    fn longest_pattern_wins() {
        let broad = rule_v4("*.test", "10.0.0.1");
        let specific = rule_v4("*.myapp.test", "172.30.0.3");
        let rules = vec![broad, specific];

        let DnsResolution::Answers(hit) = resolve(&make_query("api.myapp.test", TYPE_A), &rules)
        else {
            panic!("expected answers for api.myapp.test");
        };
        assert_eq!(hit[0].rdata, vec![172, 30, 0, 3]);

        let DnsResolution::Answers(other) = resolve(&make_query("elsewhere.test", TYPE_A), &rules)
        else {
            panic!("expected answers for elsewhere.test");
        };
        assert_eq!(other[0].rdata, vec![10, 0, 0, 1]);
    }

    #[test]
    fn disabled_rule_is_skipped() {
        let rule = DnsRule {
            enabled: false,
            ..rule_v4("*.myapp.test", "172.30.0.3")
        };
        assert_eq!(
            resolve(&make_query("api.myapp.test", TYPE_A), &[rule]),
            DnsResolution::Nxdomain
        );
    }

    #[test]
    fn wrong_family_yields_no_data() {
        let v4only = rule_v4("*.myapp.test", "172.30.0.3");
        assert_eq!(
            resolve(&make_query("api.myapp.test", TYPE_AAAA), &[v4only]),
            DnsResolution::NoData
        );
        let v6only = DnsRule {
            ipv6: Some("fd00::3".into()),
            ..DnsRule::new("*.myapp.test")
        };
        assert_eq!(
            resolve(&make_query("api.myapp.test", TYPE_A), &[v6only]),
            DnsResolution::NoData
        );
    }

    #[test]
    fn right_family_yields_answer() {
        let rule = DnsRule {
            ipv4: Some("172.30.0.3".into()),
            ipv6: Some("fd00::3".into()),
            ttl: 120,
            ..DnsRule::new("*.myapp.test")
        };
        let DnsResolution::Answers(answers) =
            resolve(&make_query("api.myapp.test", TYPE_A), std::slice::from_ref(&rule))
        else {
            panic!("expected A answer");
        };
        assert_eq!(
            answers,
            vec![DnsAnswer {
                qtype: TYPE_A,
                ttl: 120,
                rdata: vec![172, 30, 0, 3]
            }]
        );

        let DnsResolution::Answers(v6) =
            resolve(&make_query("api.myapp.test", TYPE_AAAA), &[rule])
        else {
            panic!("expected AAAA answer");
        };
        assert_eq!(v6.len(), 1);
        assert_eq!(v6[0].qtype, TYPE_AAAA);
        assert_eq!(v6[0].rdata.len(), 16);
    }

    #[test]
    fn invalid_ip_address_yields_no_data() {
        let rule = rule_v4("bad.test", "999.1.2.3");
        assert_eq!(
            resolve(&make_query("bad.test", TYPE_A), &[rule]),
            DnsResolution::NoData
        );
    }

    #[test]
    fn unsupported_query_type_is_no_data_when_name_matches() {
        let rule = rule_v4("*.test", "10.0.0.1");
        assert_eq!(
            resolve(&make_query("x.test", 15), &[rule]), // MX
            DnsResolution::NoData
        );
    }

    #[test]
    fn unknown_name_is_nxdomain() {
        let rule = rule_v4("*.myapp.test", "172.30.0.3");
        assert_eq!(
            resolve(&make_query("other.example", TYPE_A), &[rule]),
            DnsResolution::Nxdomain
        );
        assert_eq!(
            resolve(&make_query("api.myapp.test", TYPE_A), &[]),
            DnsResolution::Nxdomain
        );
    }

    // MARK: RuleStore

    #[test]
    fn rule_store_save_load_round_trip() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("rules.json");

        let rules = vec![
            DnsRule {
                ipv4: Some("172.30.0.3".into()),
                ttl: 120,
                group: "Docker".into(),
                ..DnsRule::new("*.myapp.test")
            },
            DnsRule {
                ipv6: Some("fd00::1".into()),
                enabled: false,
                ..DnsRule::new("exact.test")
            },
        ];
        RuleStore::with_rules(file.clone(), rules.clone())
            .save()
            .unwrap();

        let loaded = RuleStore::load(file);
        assert_eq!(loaded.rules, rules);
    }

    #[test]
    fn rule_store_starts_empty_when_file_missing() {
        let file = std::env::temp_dir()
            .join(Uuid::new_v4().to_string())
            .join("rules.json");
        assert_eq!(RuleStore::load(file).rules, vec![]);
    }

    // MARK: Grouping / preview helpers (RulesView + edit-sheet backing)

    #[test]
    fn groups_preserve_first_appearance_order() {
        let mut a = rule_v4("a.test", "1.1.1.1");
        a.group = "Docker".into();
        let mut b = rule_v4("b.test", "1.1.1.2");
        b.group = "Default".into();
        let mut c = rule_v4("c.test", "1.1.1.3");
        c.group = "Docker".into();

        let rules = vec![a, b, c];
        let grouped = groups(&rules);
        let names: Vec<&str> = grouped.iter().map(|(g, _)| g.as_str()).collect();
        assert_eq!(names, vec!["Docker", "Default"]);
        assert_eq!(grouped[0].1.len(), 2);
        assert_eq!(grouped[1].1.len(), 1);
    }

    #[test]
    fn preview_match_uses_real_matcher() {
        let rules = vec![rule_v4("*.test", "10.0.0.1"), rule_v4("*.myapp.test", "172.30.0.3")];
        let hit = preview_match("api.myapp.test", &rules).unwrap();
        assert_eq!(hit.pattern, "*.myapp.test");
        assert!(preview_match("nowhere.example", &rules).is_none());
    }

    #[test]
    fn suggestion_rule_builder_picks_family_by_shape() {
        let v4 = rule_with_address("*.a.test", "10.0.0.1", "Imported");
        assert_eq!(v4.ipv4.as_deref(), Some("10.0.0.1"));
        assert!(v4.ipv6.is_none());
        assert_eq!(v4.group, "Imported");
        let v6 = rule_with_address("*.b.test", "fd00::1", "Imported");
        assert_eq!(v6.ipv6.as_deref(), Some("fd00::1"));
        assert!(v6.ipv4.is_none());
    }
}
