//! In-memory backend: development host (macOS) and app-level tests.
//! Behaves like a fully granted, conflict-free OS so the whole UI flow —
//! setup, sync, per-zone status, unregister — is exercisable anywhere.

use std::collections::BTreeSet;
use std::sync::Mutex;

use crate::{
    derive_status, AccessState, DnsEndpoint, ResolverBackend, SetupInstructions, SetupStep,
    SyncOutcome, SyncPlan, ZoneStatus,
};

#[derive(Default)]
pub struct MockBackend {
    /// (zone, port-it-was-registered-with)
    registered: Mutex<Vec<(String, u16)>>,
    /// Zones that report ManagedElsewhere (settable by tests).
    pub foreign: Mutex<BTreeSet<String>>,
}

impl MockBackend {
    pub fn new() -> Self {
        Self::default()
    }

    fn snapshot(
        &self,
        endpoint: DnsEndpoint,
    ) -> (BTreeSet<String>, BTreeSet<String>, BTreeSet<String>) {
        let registered = self.registered.lock().unwrap();
        let foreign = self.foreign.lock().unwrap().clone();
        let current: BTreeSet<String> = registered
            .iter()
            .filter(|(_, port)| *port == endpoint.port)
            .map(|(zone, _)| zone.clone())
            .collect();
        let stale: BTreeSet<String> = registered
            .iter()
            .filter(|(_, port)| *port != endpoint.port)
            .map(|(zone, _)| zone.clone())
            .collect();
        (current, stale, foreign)
    }
}

impl ResolverBackend for MockBackend {
    fn name(&self) -> &'static str {
        "mock"
    }

    fn access(&self) -> AccessState {
        AccessState::Granted
    }

    fn setup_instructions(&self, endpoint: DnsEndpoint) -> SetupInstructions {
        SetupInstructions {
            steps: vec![SetupStep {
                title: "Development mode".into(),
                detail: format!(
                    "Mock backend: registrations are kept in memory only. The DNS server \
                     answers on {}:{} but the OS is not configured to use it.",
                    endpoint.addr, endpoint.port
                ),
                copy_command: None,
            }],
        }
    }

    fn plan(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> SyncPlan {
        let (current, stale, foreign) = self.snapshot(endpoint);
        let mut installs = Vec::new();
        let mut conflicts = Vec::new();
        for zone in zones {
            if foreign.contains(zone) {
                conflicts.push(zone.clone());
            } else if !current.contains(zone) || stale.contains(zone) {
                installs.push(zone.clone());
            }
        }
        let owned: BTreeSet<String> = current.union(&stale).cloned().collect();
        let removals: Vec<String> = owned.difference(zones).cloned().collect();
        SyncPlan {
            installs,
            removals,
            conflicts,
        }
    }

    fn status(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> Vec<ZoneStatus> {
        let (current, stale, foreign) = self.snapshot(endpoint);
        derive_status(zones, &current, &stale, &foreign)
    }

    fn sync(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> SyncOutcome {
        let plan = self.plan(zones, endpoint);
        if plan.is_noop() {
            return SyncOutcome::UpToDate {
                conflicts: plan.conflicts,
            };
        }
        let mut registered = self.registered.lock().unwrap();
        registered.retain(|(zone, _)| !plan.removals.contains(zone) && !plan.installs.contains(zone));
        for zone in &plan.installs {
            registered.push((zone.clone(), endpoint.port));
        }
        SyncOutcome::Applied {
            conflicts: plan.conflicts,
        }
    }

    fn unregister_all(&self) -> SyncOutcome {
        let mut registered = self.registered.lock().unwrap();
        if registered.is_empty() {
            return SyncOutcome::UpToDate { conflicts: vec![] };
        }
        registered.clear();
        SyncOutcome::Applied { conflicts: vec![] }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ZoneState;
    use std::net::{IpAddr, Ipv4Addr};

    fn endpoint(port: u16) -> DnsEndpoint {
        DnsEndpoint {
            addr: IpAddr::V4(Ipv4Addr::LOCALHOST),
            port,
        }
    }

    fn zones(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn sync_then_status_reports_registered() {
        let backend = MockBackend::new();
        let desired = zones(&["myapp.test", "other.test"]);
        assert_eq!(
            backend.sync(&desired, endpoint(15353)),
            SyncOutcome::Applied { conflicts: vec![] }
        );
        let status = backend.status(&desired, endpoint(15353));
        assert!(status.iter().all(|s| s.state == ZoneState::Registered));

        // Same zones again: up to date.
        assert_eq!(
            backend.sync(&desired, endpoint(15353)),
            SyncOutcome::UpToDate { conflicts: vec![] }
        );
    }

    #[test]
    fn port_change_marks_needs_resync_and_resyncs() {
        let backend = MockBackend::new();
        let desired = zones(&["myapp.test"]);
        backend.sync(&desired, endpoint(15353));

        let status = backend.status(&desired, endpoint(5399));
        assert_eq!(status[0].state, ZoneState::NeedsResync);

        backend.sync(&desired, endpoint(5399));
        let status = backend.status(&desired, endpoint(5399));
        assert_eq!(status[0].state, ZoneState::Registered);
    }

    #[test]
    fn removed_zone_is_unregistered_on_next_sync() {
        let backend = MockBackend::new();
        backend.sync(&zones(&["a.test", "b.test"]), endpoint(15353));
        let plan = backend.plan(&zones(&["a.test"]), endpoint(15353));
        assert_eq!(plan.removals, vec!["b.test"]);
        backend.sync(&zones(&["a.test"]), endpoint(15353));
        let status = backend.status(&zones(&["a.test", "b.test"]), endpoint(15353));
        assert_eq!(status[0].state, ZoneState::Registered); // a.test
        assert_eq!(status[1].state, ZoneState::NotRegistered); // b.test
    }

    #[test]
    fn foreign_zone_is_conflict_and_never_touched() {
        let backend = MockBackend::new();
        backend.foreign.lock().unwrap().insert("vpn.test".into());
        let desired = zones(&["vpn.test", "mine.test"]);

        let outcome = backend.sync(&desired, endpoint(15353));
        assert_eq!(
            outcome,
            SyncOutcome::Applied {
                conflicts: vec!["vpn.test".into()]
            }
        );
        let status = backend.status(&desired, endpoint(15353));
        assert_eq!(status[1].state, ZoneState::ManagedElsewhere); // vpn.test (sorted order: mine, vpn)
        assert_eq!(status[0].state, ZoneState::Registered); // mine.test
    }
}
