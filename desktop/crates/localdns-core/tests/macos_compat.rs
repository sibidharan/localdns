//! Cross-app persistence compatibility: a rules.json written by the macOS app
//! (fixture generated with the real Swift JSONEncoder: .prettyPrinted +
//! .sortedKeys, nil optionals omitted, uppercase UUIDs) must load here, and our
//! output must be structurally identical (same keys, same casing, same value
//! types) so the macOS app loads our files in turn. Whitespace differs (Swift
//! emits `" : "`, serde `": "`) and is irrelevant to either decoder.

use localdns_core::rules::{DnsRule, RuleStore};
use uuid::Uuid;

const FIXTURE: &str = include_str!("fixtures/rules-macos.json");

fn expected_rules() -> Vec<DnsRule> {
    vec![
        DnsRule {
            enabled: true,
            group: "Docker".into(),
            id: Uuid::parse_str("6BA7B810-9DAD-11D1-80B4-00C04FD430C8").unwrap(),
            ipv4: Some("172.30.0.3".into()),
            ipv6: None,
            pattern: "*.myapp.test".into(),
            ttl: 120,
        },
        DnsRule {
            enabled: false,
            group: "Default".into(),
            id: Uuid::parse_str("0F14D0AB-9605-4A62-A9E4-5ED26688389B").unwrap(),
            ipv4: None,
            ipv6: Some("fd00::1".into()),
            pattern: "exact.test".into(),
            ttl: 60,
        },
    ]
}

#[test]
fn loads_macos_written_rules_json() {
    let rules: Vec<DnsRule> = serde_json::from_str(FIXTURE).unwrap();
    assert_eq!(rules, expected_rules());
}

#[test]
fn resave_is_structurally_identical_to_macos_output() {
    let ours = serde_json::to_string_pretty(&expected_rules()).unwrap();
    let ours_value: serde_json::Value = serde_json::from_str(&ours).unwrap();
    let macos_value: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
    assert_eq!(ours_value, macos_value);

    // Key ORDER also matches (.sortedKeys ⇔ alphabetical declaration order),
    // so diffs between files written by the two apps stay human-readable.
    let our_keys: Vec<&str> = ours
        .lines()
        .filter_map(|l| l.trim().strip_prefix('"').and_then(|l| l.split('"').next()))
        .collect();
    let macos_keys: Vec<&str> = FIXTURE
        .lines()
        .filter_map(|l| l.trim().strip_prefix('"').and_then(|l| l.split('"').next()))
        .collect();
    assert_eq!(our_keys, macos_keys);

    // Uppercase UUIDs, like Swift.
    assert!(ours.contains("6BA7B810-9DAD-11D1-80B4-00C04FD430C8"));
}

#[test]
fn file_round_trip_through_rule_store() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("rules.json");
    std::fs::write(&path, FIXTURE).unwrap();

    let store = RuleStore::load(path.clone());
    assert_eq!(store.rules, expected_rules());

    store.save().unwrap();
    let reloaded = RuleStore::load(path);
    assert_eq!(reloaded.rules, expected_rules());
}
