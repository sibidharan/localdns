//! Thread-safe ring buffer of recent queries. Port of `QueryLog.swift`.

use std::net::Ipv6Addr;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use uuid::Uuid;

use crate::message::{DnsAnswer, DnsQuery, TYPE_A, TYPE_AAAA};
use crate::rules::DnsResolution;

/// The name the server's liveness watchdog queries itself with (see
/// localdns-server's endpoint supervisor). A heartbeat, not user traffic:
/// `append` drops it, because a red NXDOMAIN row every minute reads as
/// failure and flushes real queries out of the ring. Watchdog *failures* are
/// loud elsewhere (stderr, the status orb); its successes stay out of the
/// log. Mirrors `QueryLog.watchdogProbeName` in QueryLog.swift.
pub const WATCHDOG_PROBE_NAME: &str = "probe.localdns.invalid";

/// How the server answered.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum Outcome {
    /// An answer was returned; the value is the address (e.g. "172.30.0.3").
    Answered(String),
    /// Name matched a rule, but no record of the queried family exists.
    NoData,
    /// No rule matched.
    Nxdomain,
}

/// One DNS query the server handled.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryLogEntry {
    pub id: Uuid,
    /// Unix milliseconds (the log is UI-only, never persisted).
    pub timestamp_ms: u64,
    /// Queried name (normalized).
    pub name: String,
    /// "A", "AAAA", or "TYPE<n>" for anything else.
    pub qtype: String,
    pub outcome: Outcome,
    /// Time taken by the resolver decision, in milliseconds.
    pub latency_ms: f64,
}

impl QueryLogEntry {
    pub fn new(name: impl Into<String>, qtype: impl Into<String>, outcome: Outcome) -> Self {
        Self {
            id: Uuid::new_v4(),
            timestamp_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0),
            name: name.into(),
            qtype: qtype.into(),
            outcome,
            latency_ms: 0.0,
        }
    }

    /// Builds an entry straight from a server query plus its resolution.
    pub fn from_resolution(query: &DnsQuery, resolution: &DnsResolution, latency_ms: f64) -> Self {
        let qtype = match query.qtype {
            TYPE_A => "A".to_string(),
            TYPE_AAAA => "AAAA".to_string(),
            other => format!("TYPE{other}"),
        };
        let outcome = match resolution {
            DnsResolution::Answers(answers) => Outcome::Answered(
                answers
                    .first()
                    .map(describe)
                    .unwrap_or_else(|| "<none>".into()),
            ),
            DnsResolution::NoData => Outcome::NoData,
            DnsResolution::Nxdomain => Outcome::Nxdomain,
        };
        Self {
            latency_ms,
            ..Self::new(query.name.clone(), qtype, outcome)
        }
    }
}

fn describe(answer: &DnsAnswer) -> String {
    match (answer.qtype, answer.rdata.len()) {
        (TYPE_A, 4) => answer
            .rdata
            .iter()
            .map(|b| b.to_string())
            .collect::<Vec<_>>()
            .join("."),
        (TYPE_AAAA, 16) => {
            let mut octets = [0u8; 16];
            octets.copy_from_slice(&answer.rdata);
            Ipv6Addr::from(octets).to_string()
        }
        _ => "<invalid>".into(),
    }
}

/// Thread-safe ring buffer of recent queries, newest first, capacity-capped.
/// Plain struct with no UI coupling; the app layer publishes snapshots.
pub struct QueryLog {
    capacity: usize,
    storage: Mutex<Vec<QueryLogEntry>>, // newest first
}

impl QueryLog {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            storage: Mutex::new(Vec::new()),
        }
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Snapshot of the buffer, newest first.
    pub fn entries(&self) -> Vec<QueryLogEntry> {
        self.storage.lock().unwrap().clone()
    }

    pub fn count(&self) -> usize {
        self.storage.lock().unwrap().len()
    }

    pub fn append(&self, entry: QueryLogEntry) {
        if entry.name == WATCHDOG_PROBE_NAME {
            return;
        }
        let mut storage = self.storage.lock().unwrap();
        storage.insert(0, entry);
        let capacity = self.capacity;
        if storage.len() > capacity {
            storage.truncate(capacity);
        }
    }

    pub fn clear(&self) {
        self.storage.lock().unwrap().clear();
    }
}

impl Default for QueryLog {
    fn default() -> Self {
        Self::new(200)
    }
}

// Port of QueryLogTests.swift.
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn entry(n: usize) -> QueryLogEntry {
        QueryLogEntry::new(
            format!("host{n}.test"),
            "A",
            Outcome::Answered(format!("10.0.0.{n}")),
        )
    }

    #[test]
    fn append_keeps_newest_first() {
        let log = QueryLog::new(10);
        log.append(entry(1));
        log.append(entry(2));
        let names: Vec<String> = log.entries().into_iter().map(|e| e.name).collect();
        assert_eq!(names, vec!["host2.test", "host1.test"]);
        assert_eq!(log.count(), 2);
    }

    #[test]
    fn ring_buffer_caps_at_capacity() {
        let log = QueryLog::new(5);
        for i in 1..=7 {
            log.append(entry(i));
        }
        assert_eq!(log.count(), 5);
        let names: Vec<String> = log.entries().into_iter().map(|e| e.name).collect();
        assert_eq!(
            names,
            vec![
                "host7.test",
                "host6.test",
                "host5.test",
                "host4.test",
                "host3.test"
            ]
        );
    }

    #[test]
    fn watchdog_probe_entries_are_not_recorded() {
        let log = QueryLog::new(5);
        log.append(QueryLogEntry::new(WATCHDOG_PROBE_NAME, "A", Outcome::Nxdomain));
        assert_eq!(log.count(), 0);
        log.append(entry(1));
        let names: Vec<String> = log.entries().into_iter().map(|e| e.name).collect();
        assert_eq!(names, vec!["host1.test"]);
    }

    #[test]
    fn clear_empties() {
        let log = QueryLog::new(3);
        log.append(entry(1));
        log.clear();
        assert_eq!(log.count(), 0);
        assert_eq!(log.entries(), vec![]);
    }

    #[test]
    fn concurrent_appends_stay_consistent() {
        let log = Arc::new(QueryLog::new(50));
        let handles: Vec<_> = (0..500)
            .map(|i| {
                let log = Arc::clone(&log);
                std::thread::spawn(move || log.append(entry(i)))
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
        assert_eq!(log.count(), 50);
        let ids: std::collections::HashSet<Uuid> =
            log.entries().into_iter().map(|e| e.id).collect();
        assert_eq!(ids.len(), 50); // every retained entry intact
    }

    #[test]
    fn entry_from_query_and_resolution() {
        let query = DnsQuery::new(1, "api.myapp.test", TYPE_A);
        let entry = QueryLogEntry::from_resolution(
            &query,
            &DnsResolution::Answers(vec![DnsAnswer {
                qtype: TYPE_A,
                ttl: 60,
                rdata: vec![172, 30, 0, 3],
            }]),
            1.5,
        );
        assert_eq!(entry.name, "api.myapp.test");
        assert_eq!(entry.qtype, "A");
        assert_eq!(entry.outcome, Outcome::Answered("172.30.0.3".into()));
        assert_eq!(entry.latency_ms, 1.5);

        let v6_query = DnsQuery::new(2, "v6.test", TYPE_AAAA);
        let v6_addr: Ipv6Addr = "fd00::1".parse().unwrap();
        let v6 = QueryLogEntry::from_resolution(
            &v6_query,
            &DnsResolution::Answers(vec![DnsAnswer {
                qtype: TYPE_AAAA,
                ttl: 60,
                rdata: v6_addr.octets().to_vec(),
            }]),
            0.0,
        );
        assert_eq!(v6.qtype, "AAAA");
        assert_eq!(v6.outcome, Outcome::Answered("fd00::1".into()));

        assert_eq!(
            QueryLogEntry::from_resolution(&query, &DnsResolution::NoData, 0.0).outcome,
            Outcome::NoData
        );
        assert_eq!(
            QueryLogEntry::from_resolution(&query, &DnsResolution::Nxdomain, 0.0).outcome,
            Outcome::Nxdomain
        );
        assert_eq!(
            QueryLogEntry::from_resolution(
                &DnsQuery::new(3, "x.test", 15),
                &DnsResolution::NoData,
                0.0
            )
            .qtype,
            "TYPE15"
        );
    }
}
