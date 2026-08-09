//! Windows backend: NRPT (Name Resolution Policy Table).
//!
//! NRPT routes suffix-matched queries to a nameserver — but has no port field,
//! so the DNS server answers on port 53 of a dedicated loopback address
//! (`127.65.43.53`; any 127/8 address works on Windows without an alias, and a
//! specific-address bind coexists with Docker/ICS binding 0.0.0.0:53).
//!
//! Split of responsibilities:
//! - **Status/plan (this process, unprivileged)**: local NRPT rules live under
//!   `HKLM\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig`
//!   (world-readable) — read directly, no elevation.
//! - **Writes (privileged)**: sent as JSON lines over the named pipe
//!   `\\.\pipe\LocalDNSHelper` to the demand-start LocalSystem service
//!   installed once by the installer (`localdns-helper.exe`). The helper only
//!   ever touches rules whose Comment is "LocalDNS".
//!
//! Group Policy caveat: if ANY GPO NRPT rules exist, Windows ignores ALL local
//! rules — surfaced as a NeedsSetup-style warning in the setup instructions.

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::{
    derive_status, AccessState, DnsEndpoint, ResolverBackend, SetupInstructions, SetupStep,
    SyncOutcome, SyncPlan, ZoneStatus,
};

pub const PIPE_PATH: &str = r"\\.\pipe\LocalDNSHelper";
pub const SERVICE_NAME: &str = "localdns-helper";
pub const OWNER_COMMENT: &str = "LocalDNS";
/// Dedicated loopback address so 0.0.0.0:53 squatters (Docker/ICS) don't collide.
pub const SERVER_ADDR: Ipv4Addr = Ipv4Addr::new(127, 65, 43, 53);

const LOCAL_NRPT_KEY: &str =
    r"SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig";
const GPO_NRPT_KEY: &str = r"SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\DnsPolicyConfig";

/// Request/response protocol with the helper (JSON lines over the pipe).
#[derive(Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum HelperRequest<'a> {
    Sync {
        zones: &'a BTreeSet<String>,
        nameserver: String,
    },
    UnregisterAll,
    Ping,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HelperResponse {
    pub ok: bool,
    #[serde(default)]
    pub changed: bool,
    #[serde(default)]
    pub error: Option<String>,
}

pub struct NrptBackend;

impl NrptBackend {
    pub fn new() -> Self {
        Self
    }
}

impl Default for NrptBackend {
    fn default() -> Self {
        Self::new()
    }
}

/// One local NRPT rule as read from the registry.
#[derive(Debug, Clone)]
pub struct NrptRule {
    /// Registry subkey name — the rule GUID, used by Remove-DnsClientNrptRule.
    pub key: String,
    pub namespaces: Vec<String>,
    pub servers: String,
    pub comment: String,
}

impl NrptRule {
    pub fn is_ours(&self) -> bool {
        self.comment == OWNER_COMMENT
    }

    /// The zone this rule covers (lowercased first namespace minus leading dot).
    pub fn zone(&self) -> Option<String> {
        self.namespaces
            .first()
            .map(|ns| zone_of_namespace(ns).to_lowercase())
    }
}

/// Reads the local (non-GPO) NRPT rules. World-readable — no elevation needed.
pub fn read_local_rules() -> Vec<NrptRule> {
    use winreg::enums::HKEY_LOCAL_MACHINE;
    use winreg::RegKey;

    let Ok(key) = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey(LOCAL_NRPT_KEY) else {
        return Vec::new();
    };
    let mut rules = Vec::new();
    for name in key.enum_keys().flatten() {
        let Ok(rule_key) = key.open_subkey(&name) else {
            continue;
        };
        let namespaces: Vec<String> = rule_key.get_value("Name").unwrap_or_default();
        let servers: String = rule_key.get_value("GenericDNSServers").unwrap_or_default();
        let comment: String = rule_key.get_value("Comment").unwrap_or_default();
        rules.push(NrptRule {
            key: name,
            namespaces,
            servers,
            comment,
        });
    }
    rules
}

fn gpo_rules_present() -> bool {
    use winreg::enums::HKEY_LOCAL_MACHINE;
    use winreg::RegKey;
    RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey(GPO_NRPT_KEY)
        .map(|key| key.enum_keys().flatten().next().is_some())
        .unwrap_or(false)
}

fn service_installed() -> bool {
    std::process::Command::new("sc.exe")
        .args(["query", SERVICE_NAME])
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

/// The namespaces a zone registers: suffix form + apex form (docs are
/// ambiguous on whether ".zone" matches the apex; carrying both is free).
pub fn namespaces_for(zone: &str) -> [String; 2] {
    [format!(".{zone}"), zone.to_string()]
}

pub fn zone_of_namespace(namespace: &str) -> &str {
    namespace.trim_start_matches('.')
}

/// (owned-and-current, owned-stale, foreign) among the desired zones,
/// mirroring the /etc/resolver scan in ResolverSetup.swift.
fn classify(
    zones: &BTreeSet<String>,
    endpoint: DnsEndpoint,
) -> (BTreeSet<String>, BTreeSet<String>, BTreeSet<String>) {
    let expected_server = endpoint.addr.to_string();
    let rules = read_local_rules();
    let mut current = BTreeSet::new();
    let mut stale = BTreeSet::new();
    let mut foreign = BTreeSet::new();

    for rule in &rules {
        let ours = rule.comment == OWNER_COMMENT;
        for namespace in &rule.namespaces {
            let zone = zone_of_namespace(namespace).to_lowercase();
            if ours {
                let complete = rule.namespaces.len() == 2 && rule.servers == expected_server;
                if complete {
                    current.insert(zone);
                } else {
                    stale.insert(zone);
                }
            } else if zones.contains(&zone) {
                // A foreign rule covering a desired zone: managed elsewhere.
                foreign.insert(zone);
            }
        }
    }
    (current, stale, foreign)
}

/// Talk to the helper: connect to the pipe (demand-starting the service if
/// needed), send one request line, read one response line.
fn helper_call(request: &HelperRequest) -> Result<HelperResponse, String> {
    let payload = serde_json::to_string(request).map_err(|e| e.to_string())?;

    let mut attempts = 0;
    let file = loop {
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(PIPE_PATH)
        {
            Ok(file) => break file,
            Err(_) if attempts == 0 => {
                // Pipe absent: demand-start the service (start rights granted
                // to interactive users at install time via `sc.exe sdset`).
                let _ = std::process::Command::new("sc.exe")
                    .args(["start", SERVICE_NAME])
                    .output();
                attempts += 1;
                std::thread::sleep(Duration::from_millis(600));
            }
            Err(_) if attempts < 6 => {
                attempts += 1;
                std::thread::sleep(Duration::from_millis(400));
            }
            Err(error) => {
                return Err(format!(
                    "helper service unreachable ({error}); reinstall LocalDNS to repair it"
                ))
            }
        }
    };

    let mut writer = &file;
    writer
        .write_all(payload.as_bytes())
        .and_then(|_| writer.write_all(b"\n"))
        .map_err(|e| format!("helper write failed: {e}"))?;

    let mut reader = BufReader::new(&file);
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .map_err(|e| format!("helper read failed: {e}"))?;
    serde_json::from_str(&line).map_err(|e| format!("helper protocol error: {e}"))
}

fn outcome_from(response: Result<HelperResponse, String>, conflicts: Vec<String>) -> SyncOutcome {
    match response {
        Ok(r) if r.ok && r.changed => SyncOutcome::Applied { conflicts },
        Ok(r) if r.ok => SyncOutcome::UpToDate { conflicts },
        Ok(r) => SyncOutcome::Failed(r.error.unwrap_or_else(|| "helper reported failure".into())),
        Err(message) if message.contains("unreachable") => SyncOutcome::AccessDenied,
        Err(message) => SyncOutcome::Failed(message),
    }
}

impl ResolverBackend for NrptBackend {
    fn name(&self) -> &'static str {
        "nrpt"
    }

    fn required_endpoint(&self) -> Option<DnsEndpoint> {
        Some(DnsEndpoint {
            addr: IpAddr::V4(SERVER_ADDR),
            port: 53,
        })
    }

    fn access(&self) -> AccessState {
        if service_installed() {
            AccessState::Granted
        } else {
            AccessState::NeedsSetup(
                "The LocalDNS helper service is not installed. Re-run the installer \
                 (it sets up the service once, with administrator approval)."
                    .into(),
            )
        }
    }

    fn setup_instructions(&self, endpoint: DnsEndpoint) -> SetupInstructions {
        let mut steps = vec![SetupStep {
            title: "Helper service".into(),
            detail: format!(
                "The installer registered the demand-start service “{SERVICE_NAME}” \
                 (one-time administrator approval). It writes NRPT rules routing your \
                 zones to {}:{} and never touches rules owned by other software.",
                endpoint.addr, endpoint.port
            ),
            copy_command: None,
        }];
        if gpo_rules_present() {
            steps.push(SetupStep {
                title: "Group Policy conflict".into(),
                detail: "This machine has Group Policy NRPT rules — Windows ignores ALL \
                         locally created rules while any exist. Ask your administrator, or \
                         remove the policy, for LocalDNS zones to resolve."
                    .into(),
                copy_command: None,
            });
        }
        steps.push(SetupStep {
            title: "Verify".into(),
            detail: "After adding a rule, resolve a name in the zone to confirm end-to-end."
                .into(),
            copy_command: Some("Resolve-DnsName app.myapp.test".into()),
        });
        SetupInstructions { steps }
    }

    fn plan(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> SyncPlan {
        let (current, stale, foreign) = classify(zones, endpoint);
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
        SyncPlan {
            installs,
            removals: owned.difference(zones).cloned().collect(),
            conflicts,
        }
    }

    fn status(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> Vec<ZoneStatus> {
        let (current, stale, foreign) = classify(zones, endpoint);
        derive_status(zones, &current, &stale, &foreign)
    }

    fn sync(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> SyncOutcome {
        let plan = self.plan(zones, endpoint);
        if plan.is_noop() {
            return SyncOutcome::UpToDate {
                conflicts: plan.conflicts,
            };
        }
        // The helper re-derives the actual writes itself; zones are the desired
        // end state, keeping the privileged surface small and declarative.
        let desired: BTreeSet<String> = zones
            .iter()
            .filter(|zone| !plan.conflicts.contains(*zone))
            .cloned()
            .collect();
        let response = helper_call(&HelperRequest::Sync {
            zones: &desired,
            nameserver: endpoint.addr.to_string(),
        });
        outcome_from(response, plan.conflicts)
    }

    fn unregister_all(&self) -> SyncOutcome {
        outcome_from(helper_call(&HelperRequest::UnregisterAll), Vec::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn namespaces_carry_suffix_and_apex() {
        assert_eq!(
            namespaces_for("myapp.test"),
            [".myapp.test".to_string(), "myapp.test".to_string()]
        );
        assert_eq!(zone_of_namespace(".myapp.test"), "myapp.test");
        assert_eq!(zone_of_namespace("myapp.test"), "myapp.test");
    }

    #[test]
    fn ownership_is_the_comment_marker() {
        let ours = NrptRule {
            key: "{guid}".into(),
            namespaces: vec![".a.test".into(), "a.test".into()],
            servers: "127.65.43.53".into(),
            comment: OWNER_COMMENT.into(),
        };
        assert!(ours.is_ours());
        assert_eq!(ours.zone().as_deref(), Some("a.test"));

        let foreign = NrptRule {
            comment: "SomeVPN".into(),
            ..ours.clone()
        };
        assert!(!foreign.is_ours());
    }

    #[test]
    fn helper_outcomes_map_to_sync_outcomes() {
        let applied = outcome_from(
            Ok(HelperResponse { ok: true, changed: true, error: None }),
            vec!["c.test".into()],
        );
        assert_eq!(applied, SyncOutcome::Applied { conflicts: vec!["c.test".into()] });

        let up_to_date = outcome_from(
            Ok(HelperResponse { ok: true, changed: false, error: None }),
            vec![],
        );
        assert_eq!(up_to_date, SyncOutcome::UpToDate { conflicts: vec![] });

        let denied = outcome_from(Err("helper service unreachable (x)".into()), vec![]);
        assert_eq!(denied, SyncOutcome::AccessDenied);

        let failed = outcome_from(
            Ok(HelperResponse { ok: false, changed: false, error: Some("boom".into()) }),
            vec![],
        );
        assert_eq!(failed, SyncOutcome::Failed("boom".into()));
    }
}
