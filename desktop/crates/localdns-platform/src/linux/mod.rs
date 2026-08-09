//! Linux backend: systemd-resolved via the localdns-agentd system service.
//!
//! Tiered strategy:
//! - **Tier 1 (first-class)**: systemd-resolved present → per-zone routing on
//!   the `localdns0` dummy link, applied by the root agent over D-Bus
//!   (`org.localdns.Agent1`, polkit-gated, no prompts for the console user).
//!   resolved supports `address:port` servers (SetLinkDNSEx), so the DNS
//!   server stays unprivileged on 127.0.0.1:15353.
//! - **Tier 2 (instruct)**: NetworkManager+dnsmasq → show copyable config.
//! - **Tier 3 (instruct)**: plain resolv.conf → explain the limitation.
//!
//! Status reads are unprivileged: resolve1's Manager properties `Domains`
//! (a(isb)) and `DNSEx` (a(iiayqs)) enumerate every link's routing domains and
//! servers; our link's ifindex comes from /sys/class/net/localdns0/ifindex.

use std::collections::BTreeSet;
use std::net::IpAddr;

use crate::{
    derive_status, AccessState, DnsEndpoint, ResolverBackend, SetupInstructions, SetupStep,
    SyncOutcome, SyncPlan, ZoneStatus,
};

pub const LINK_NAME: &str = "localdns0";
pub const AGENT_BUS_NAME: &str = "org.localdns.LocalDNS";

#[derive(serde::Deserialize)]
struct AgentReply {
    ok: bool,
    #[serde(default)]
    changed: bool,
    #[serde(default)]
    error: Option<String>,
}

#[zbus::proxy(
    interface = "org.localdns.Agent1",
    default_service = "org.localdns.LocalDNS",
    default_path = "/org/localdns/Agent1"
)]
trait Agent {
    fn sync(&self, zones: Vec<String>, port: u16) -> zbus::Result<String>;
    fn unregister_all(&self) -> zbus::Result<String>;
    fn status(&self) -> zbus::Result<String>;
}

#[zbus::proxy(
    interface = "org.freedesktop.resolve1.Manager",
    default_service = "org.freedesktop.resolve1",
    default_path = "/org/freedesktop/resolve1"
)]
trait ResolveManager {
    /// (ifindex, domain, routing_only) for every link.
    #[zbus(property, name = "Domains")]
    fn domains(&self) -> zbus::Result<Vec<(i32, String, bool)>>;
    /// (ifindex, family, address, port, server_name) for every link.
    #[zbus(property, name = "DNSEx")]
    fn dns_ex(&self) -> zbus::Result<Vec<(i32, i32, Vec<u8>, u16, String)>>;
}

pub struct ResolvedBackend;

impl ResolvedBackend {
    pub fn new() -> Self {
        Self
    }
}

impl Default for ResolvedBackend {
    fn default() -> Self {
        Self::new()
    }
}

fn system_bus() -> Option<zbus::blocking::Connection> {
    zbus::blocking::Connection::system().ok()
}

fn resolved_active(connection: &zbus::blocking::Connection) -> bool {
    ResolveManagerProxyBlocking::new(connection)
        .and_then(|proxy| proxy.domains())
        .is_ok()
}

fn agent_reachable(connection: &zbus::blocking::Connection) -> bool {
    AgentProxyBlocking::new(connection)
        .and_then(|proxy| proxy.status())
        .is_ok()
}

fn our_ifindex() -> Option<i32> {
    std::fs::read_to_string(format!("/sys/class/net/{LINK_NAME}/ifindex"))
        .ok()
        .and_then(|s| s.trim().parse().ok())
}

/// (owned-and-current, owned-stale, foreign) from resolved's live view.
fn classify(
    connection: &zbus::blocking::Connection,
    zones: &BTreeSet<String>,
    endpoint: DnsEndpoint,
) -> (BTreeSet<String>, BTreeSet<String>, BTreeSet<String>) {
    let mut current = BTreeSet::new();
    let mut stale = BTreeSet::new();
    let mut foreign = BTreeSet::new();

    let Ok(proxy) = ResolveManagerProxyBlocking::new(connection) else {
        return (current, stale, foreign);
    };
    let domains = proxy.domains().unwrap_or_default();
    let servers = proxy.dns_ex().unwrap_or_default();
    let ours = our_ifindex();

    // Does OUR link point at the right server:port?
    let expected_addr: Vec<u8> = match endpoint.addr {
        IpAddr::V4(v4) => v4.octets().to_vec(),
        IpAddr::V6(v6) => v6.octets().to_vec(),
    };
    // resolved reports per-link servers with inconsistent ifindex keying
    // across versions (observed: our SetLinkDNSEx entry surfacing under a
    // different index than the link's). The truth that matters: the expected
    // server:port is present in the DNS server set at all — the routing
    // domain's link binding is checked separately below.
    let _ = ours;
    let link_server_ok = servers
        .iter()
        .any(|(_, _, addr, port, _)| *addr == expected_addr && *port == endpoint.port);

    for (ifindex, domain, _routing_only) in &domains {
        let domain = domain.trim_start_matches('~').to_lowercase();
        if Some(*ifindex) == ours {
            if link_server_ok {
                current.insert(domain);
            } else {
                stale.insert(domain);
            }
        } else if zones.contains(&domain) {
            foreign.insert(domain); // routed by a VPN or another tool
        }
    }
    (current, stale, foreign)
}

fn parse_reply(reply: zbus::Result<String>, conflicts: Vec<String>) -> SyncOutcome {
    match reply {
        Ok(json) => match serde_json::from_str::<AgentReply>(&json) {
            Ok(r) if r.ok && r.changed => SyncOutcome::Applied { conflicts },
            Ok(r) if r.ok => SyncOutcome::UpToDate { conflicts },
            Ok(r) => {
                let error = r.error.unwrap_or_else(|| "agent reported failure".into());
                if error.contains("not authorized") {
                    SyncOutcome::AccessDenied
                } else {
                    SyncOutcome::Failed(error)
                }
            }
            Err(error) => SyncOutcome::Failed(format!("agent protocol error: {error}")),
        },
        Err(_) => SyncOutcome::AccessDenied, // agent not installed/running
    }
}

fn dnsmasq_config(zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> String {
    let mut lines: Vec<String> = zones
        .iter()
        .map(|zone| format!("server=/{zone}/{}#{}", endpoint.addr, endpoint.port))
        .collect();
    if lines.is_empty() {
        lines.push(format!("server=/myapp.test/{}#{}", endpoint.addr, endpoint.port));
    }
    lines.join("\n")
}

impl ResolverBackend for ResolvedBackend {
    fn name(&self) -> &'static str {
        "systemd-resolved"
    }

    fn access(&self) -> AccessState {
        let Some(connection) = system_bus() else {
            return AccessState::NeedsSetup("system D-Bus is unavailable.".into());
        };
        if !resolved_active(&connection) {
            return AccessState::NeedsSetup(
                "systemd-resolved is not active on this system. Enable it \
                 (`sudo systemctl enable --now systemd-resolved`), or use the \
                 dnsmasq instructions below."
                    .into(),
            );
        }
        if !agent_reachable(&connection) {
            return AccessState::NeedsSetup(
                "The LocalDNS agent service is not running. Install the .deb/.rpm \
                 package (it enables localdns-agentd automatically), or start it: \
                 `sudo systemctl enable --now localdns-agentd`."
                    .into(),
            );
        }
        AccessState::Granted
    }

    fn setup_instructions(&self, endpoint: DnsEndpoint) -> SetupInstructions {
        let connection = system_bus();
        let resolved = connection.as_ref().is_some_and(resolved_active);
        let mut steps = Vec::new();

        if resolved {
            steps.push(SetupStep {
                title: "Agent service".into(),
                detail: format!(
                    "The package enables the localdns-agentd system service (one-time \
                     admin consent at install). It owns the {LINK_NAME} interface and \
                     routes your zones to {}:{} in systemd-resolved — re-applied \
                     automatically after reboots and resolved restarts.",
                    endpoint.addr, endpoint.port
                ),
                copy_command: Some("sudo systemctl enable --now localdns-agentd".into()),
            });
            steps.push(SetupStep {
                title: "Verify".into(),
                detail: "After adding a rule, confirm the zone resolves through resolved."
                    .into(),
                copy_command: Some("resolvectl query app.myapp.test".into()),
            });
        } else {
            steps.push(SetupStep {
                title: "systemd-resolved (recommended)".into(),
                detail: "First-class support needs systemd-resolved as the system \
                         resolver. Enable it, then re-check."
                    .into(),
                copy_command: Some("sudo systemctl enable --now systemd-resolved".into()),
            });
            steps.push(SetupStep {
                title: "Alternative: NetworkManager + dnsmasq".into(),
                detail: format!(
                    "If you use dns=dnsmasq, drop this into \
                     /etc/NetworkManager/dnsmasq.d/localdns.conf and reload \
                     NetworkManager:\n{}",
                    dnsmasq_config(&BTreeSet::new(), endpoint)
                ),
                copy_command: Some(format!(
                    "sudo tee /etc/NetworkManager/dnsmasq.d/localdns.conf <<'EOF'\n{}\nEOF\nsudo systemctl reload NetworkManager",
                    dnsmasq_config(&BTreeSet::new(), endpoint)
                )),
            });
        }
        SetupInstructions { steps }
    }

    fn plan(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> SyncPlan {
        let Some(connection) = system_bus() else {
            return SyncPlan::default();
        };
        let (current, stale, foreign) = classify(&connection, zones, endpoint);
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
        let Some(connection) = system_bus() else {
            return derive_status(zones, &BTreeSet::new(), &BTreeSet::new(), &BTreeSet::new());
        };
        let (current, stale, foreign) = classify(&connection, zones, endpoint);
        derive_status(zones, &current, &stale, &foreign)
    }

    fn sync(&self, zones: &BTreeSet<String>, endpoint: DnsEndpoint) -> SyncOutcome {
        let Some(connection) = system_bus() else {
            return SyncOutcome::AccessDenied;
        };
        let plan = self.plan(zones, endpoint);
        // Foreign-routed zones are excluded: the agent applies the rest, and
        // they are reported as conflicts (never touched) — safety contract.
        let desired: Vec<String> = zones
            .iter()
            .filter(|zone| !plan.conflicts.contains(*zone))
            .cloned()
            .collect();
        let reply = AgentProxyBlocking::new(&connection)
            .and_then(|proxy| proxy.sync(desired, endpoint.port));
        parse_reply(reply, plan.conflicts)
    }

    fn unregister_all(&self) -> SyncOutcome {
        let Some(connection) = system_bus() else {
            return SyncOutcome::AccessDenied;
        };
        let reply = AgentProxyBlocking::new(&connection).and_then(|proxy| proxy.unregister_all());
        parse_reply(reply, Vec::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_replies_map_to_sync_outcomes() {
        let applied = parse_reply(Ok(r#"{"ok":true,"changed":true}"#.into()), vec!["v.test".into()]);
        assert_eq!(applied, SyncOutcome::Applied { conflicts: vec!["v.test".into()] });

        let up_to_date = parse_reply(Ok(r#"{"ok":true,"changed":false}"#.into()), vec![]);
        assert_eq!(up_to_date, SyncOutcome::UpToDate { conflicts: vec![] });

        let denied = parse_reply(
            Ok(r#"{"ok":false,"changed":false,"error":"not authorized (org.localdns.agent.configure)"}"#.into()),
            vec![],
        );
        assert_eq!(denied, SyncOutcome::AccessDenied);

        let failed = parse_reply(Ok(r#"{"ok":false,"error":"link create failed"}"#.into()), vec![]);
        assert_eq!(failed, SyncOutcome::Failed("link create failed".into()));

        let unreachable = parse_reply(Err(zbus::Error::InvalidReply), vec![]);
        assert_eq!(unreachable, SyncOutcome::AccessDenied);
    }

    #[test]
    fn dnsmasq_config_lines_per_zone_with_port() {
        let endpoint = DnsEndpoint {
            addr: "127.0.0.1".parse().unwrap(),
            port: 15353,
        };
        let zones: BTreeSet<String> = ["a.test".to_string(), "b.test".to_string()].into();
        let config = dnsmasq_config(&zones, endpoint);
        assert_eq!(
            config,
            "server=/a.test/127.0.0.1#15353\nserver=/b.test/127.0.0.1#15353"
        );
        // Empty zone set still yields a usable example line.
        assert!(dnsmasq_config(&BTreeSet::new(), endpoint).contains("myapp.test"));
    }
}
