//! Pure LocalDNS logic — a 1:1 port of the macOS app's `LocalDNS/Core` layer.
//!
//! Nothing here touches the network or any OS integration; the DNS server,
//! self-test client, and resolver backends live in sibling crates. The Swift
//! sources (and their XCTest suites) are the behavioral oracle: any divergence
//! from `DNSMessage.swift` / `Rules.swift` / `RuleValidation.swift` /
//! `HostsImporter.swift` / `QueryLog.swift` is a porting bug.

pub mod hosts;
pub mod message;
pub mod paths;
pub mod query_log;
pub mod rules;
pub mod validation;
pub mod zones;

pub use message::{DnsAnswer, DnsParseError, DnsQuery};
pub use query_log::{Outcome, QueryLog, QueryLogEntry, WATCHDOG_PROBE_NAME};
pub use rules::{best_match, normalize, resolve, response_data, DnsResolution, DnsRule, RuleStore};
