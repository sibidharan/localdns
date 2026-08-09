//! The per-OS resolver-registration seam.
//!
//! Modeled on `ResolverSetup.swift` / `ResolverAccess.swift`: a backend turns
//! the set of desired zones into OS registrations (NRPT rules on Windows,
//! systemd-resolved routing domains on Linux, /etc/resolver files on macOS) and
//! reports per-zone status for the Setup view.
//!
//! Safety contract carried over from the macOS app: a backend only ever
//! creates, rewrites, or removes registrations *it* owns (proven by an
//! ownership marker — file marker line, NRPT rule comment, or the dedicated
//! dummy link). Foreign registrations covering a desired zone are reported as
//! conflicts / `ManagedElsewhere` and never touched.

use std::collections::BTreeSet;
use std::net::IpAddr;

use serde::Serialize;

pub mod mock;

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(windows)]
pub mod windows;

/// Where the OS should send zone queries — i.e. where the DNS server listens.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct DnsEndpoint {
    pub addr: IpAddr,
    pub port: u16,
}

/// Per-zone registration state, mirroring SetupView's four states.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ZoneState {
    /// Registered and current.
    Registered,
    /// Ours, but stale (e.g. port changed) — next sync rewrites it.
    NeedsResync,
    /// No registration yet.
    NotRegistered,
    /// A foreign registration covers this zone; left untouched.
    ManagedElsewhere,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ZoneStatus {
    pub zone: String,
    pub state: ZoneState,
}

/// The difference between desired and installed state (ResolverSyncPlan).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct SyncPlan {
    /// Zones whose registration must be (re)written (new, or owned-but-stale).
    pub installs: Vec<String>,
    /// Owned zones whose registration must be removed. Never contains foreign entries.
    pub removals: Vec<String>,
    /// Desired zones blocked by a foreign registration (left untouched).
    pub conflicts: Vec<String>,
}

impl SyncPlan {
    pub fn is_noop(&self) -> bool {
        self.installs.is_empty() && self.removals.is_empty()
    }
}

/// The result of a sync/unregister (ResolverSyncOutcome).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum SyncOutcome {
    /// Nothing to change. Carries any foreign-registration conflicts detected.
    UpToDate { conflicts: Vec<String> },
    /// Registrations were written/removed. Carries any conflicts left unresolved.
    Applied { conflicts: Vec<String> },
    /// One-time setup missing (helper/agent not installed, or grant revoked).
    AccessDenied,
    /// An error that was not permission-related.
    Failed(String),
}

/// Whether the one-time privileged setup is in place.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum AccessState {
    /// Registrations can be written right now.
    Granted,
    /// One-time setup required; the string explains what is missing.
    NeedsSetup(String),
}

/// One numbered step of the Setup view.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupStep {
    pub title: String,
    pub detail: String,
    /// A command the user can copy (the macOS "one Terminal command" pattern),
    /// when this step needs one.
    pub copy_command: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct SetupInstructions {
    pub steps: Vec<SetupStep>,
}

/// One implementation per OS. All methods are synchronous and may block
/// (PowerShell, D-Bus, file IO) — the app calls them inside spawn_blocking.
pub trait ResolverBackend: Send + Sync {
    /// "nrpt" | "systemd-resolved" | "mock" — shown in diagnostics.
    fn name(&self) -> &'static str;

    /// If Some, the DNS server must bind exactly this endpoint (Windows NRPT
    /// has no port field, so the server must answer on port 53 of a dedicated
    /// loopback address). None = the user-configurable port applies.
    fn required_endpoint(&self) -> Option<DnsEndpoint> {
        None
    }

    fn access(&self) -> AccessState;

    fn setup_instructions(&self, endpoint: DnsEndpoint) -> SetupInstructions;

    /// Pure diff between desired zones and installed registrations.
    fn plan(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> SyncPlan;

    /// Per-zone state for the Setup table, in zone order.
    fn status(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> Vec<ZoneStatus>;

    /// Applies the plan. Only owned registrations are ever written or removed.
    fn sync(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> SyncOutcome;

    /// Removes every owned registration; foreign ones are left untouched.
    fn unregister_all(&self) -> SyncOutcome;
}

/// The backend for the current OS. On macOS (development host) and any OS
/// without a real implementation yet, the in-memory mock keeps the app fully
/// functional minus actual OS registration.
pub fn default_backend() -> Box<dyn ResolverBackend> {
    #[cfg(windows)]
    {
        Box::new(windows::NrptBackend::new())
    }
    #[cfg(target_os = "linux")]
    {
        Box::new(linux::ResolvedBackend::new())
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Box::new(mock::MockBackend::new())
    }
}

/// Shared status derivation used by every backend: given the desired zones and
/// the backend's view of (owned-and-current, owned-but-stale, foreign) zones,
/// produce the four-state table exactly like SetupView does.
pub fn derive_status(
    zones: &BTreeSet<String>,
    owned_current: &BTreeSet<String>,
    owned_stale: &BTreeSet<String>,
    foreign: &BTreeSet<String>,
) -> Vec<ZoneStatus> {
    zones
        .iter()
        .map(|zone| {
            let state = if foreign.contains(zone) {
                ZoneState::ManagedElsewhere
            } else if owned_stale.contains(zone) {
                ZoneState::NeedsResync
            } else if owned_current.contains(zone) {
                ZoneState::Registered
            } else {
                ZoneState::NotRegistered
            };
            ZoneStatus {
                zone: zone.clone(),
                state,
            }
        })
        .collect()
}
