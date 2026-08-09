//! LocalDNS Linux agent daemon.
//!
//! systemd-resolved never allocates a DNS scope on loopback links, so per-zone
//! routing needs a dedicated dummy interface. This root daemon (hard-sandboxed
//! by its unit file) owns that interface and the resolved configuration:
//!
//! 1. Creates `localdns0` (dummy) and brings it up.
//! 2. Applies persisted state (`/var/lib/localdns/state.json`) on boot:
//!    `SetLinkDomains(ifindex, [(zone, routing-only)])` +
//!    `SetLinkDNSEx(ifindex, [(AF_INET, 127.0.0.1, port, "")])` +
//!    `SetLinkDefaultRoute(ifindex, false)` — resolved supports ports here, so
//!    the DNS server itself stays fully unprivileged on 127.0.0.1:15353.
//! 3. Watches `NameOwnerChanged` for org.freedesktop.resolve1 and re-applies
//!    after resolved restarts (per-link settings are runtime-only).
//! 4. Serves `org.localdns.Agent1` on the system bus: `Sync(zones, port)`,
//!    `UnregisterAll()`, `Status()` — mutating calls are polkit-gated by
//!    `org.localdns.agent.configure` (allow_active=yes: no prompt at console).

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("localdns-agentd is a Linux daemon; nothing to do on this OS.");
}

#[cfg(target_os = "linux")]
#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    agent::run().await
}

#[cfg(target_os = "linux")]
mod agent {
    use std::collections::{BTreeSet, HashMap};
    use std::sync::Arc;

    use futures_util::StreamExt;
    use serde::{Deserialize, Serialize};
    use tokio::sync::Mutex;
    use zbus::zvariant::Value;

    pub const LINK_NAME: &str = "localdns0";
    pub const STATE_PATH: &str = "/var/lib/localdns/state.json";
    pub const ACTION_ID: &str = "org.localdns.agent.configure";
    pub const BUS_NAME: &str = "org.localdns.LocalDNS";
    pub const OBJECT_PATH: &str = "/org/localdns/Agent1";

    #[derive(Debug, Clone, Default, Serialize, Deserialize)]
    pub struct State {
        pub zones: BTreeSet<String>,
        pub port: u16,
    }

    impl State {
        fn load() -> Self {
            std::fs::read(STATE_PATH)
                .ok()
                .and_then(|data| serde_json::from_slice(&data).ok())
                .unwrap_or_default()
        }

        fn save(&self) -> std::io::Result<()> {
            if let Some(parent) = std::path::Path::new(STATE_PATH).parent() {
                std::fs::create_dir_all(parent)?;
            }
            let json = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
            let tmp = format!("{STATE_PATH}.tmp");
            std::fs::write(&tmp, json)?;
            std::fs::rename(&tmp, STATE_PATH)
        }
    }

    // MARK: dummy link (via iproute2 — universal, no netlink crate churn)

    fn link_exists() -> bool {
        std::path::Path::new(&format!("/sys/class/net/{LINK_NAME}")).exists()
    }

    pub fn link_ifindex() -> Option<i32> {
        std::fs::read_to_string(format!("/sys/class/net/{LINK_NAME}/ifindex"))
            .ok()
            .and_then(|s| s.trim().parse().ok())
    }

    fn ip(args: &[&str]) -> std::io::Result<()> {
        let status = std::process::Command::new("ip").args(args).status()?;
        if status.success() {
            Ok(())
        } else {
            Err(std::io::Error::other(format!("ip {args:?} failed: {status}")))
        }
    }

    /// Address carried by the dummy link. systemd-resolved only allocates a
    /// DNS scope for links that are up AND carry an address (verified on
    /// systemd 255: a bare dummy link stays "Current Scopes: none" and every
    /// zone query fails). 198.51.100.53 is TEST-NET-2 — documentation-only
    /// space, never routed, so it can't collide with anything real.
    const LINK_ADDR: &str = "198.51.100.53/32";

    fn ensure_link() -> std::io::Result<i32> {
        if !link_exists() {
            ip(&["link", "add", LINK_NAME, "type", "dummy"])?;
        }
        ip(&["addr", "replace", LINK_ADDR, "dev", LINK_NAME])?;
        ip(&["link", "set", "up", "dev", LINK_NAME])?;
        link_ifindex().ok_or_else(|| std::io::Error::other("ifindex unreadable"))
    }

    fn delete_link() {
        if link_exists() {
            let _ = ip(&["link", "del", LINK_NAME]);
        }
    }

    // MARK: resolved D-Bus surface

    #[zbus::proxy(
        interface = "org.freedesktop.resolve1.Manager",
        default_service = "org.freedesktop.resolve1",
        default_path = "/org/freedesktop/resolve1"
    )]
    trait ResolveManager {
        fn set_link_domains(&self, ifindex: i32, domains: Vec<(String, bool)>) -> zbus::Result<()>;
        #[zbus(name = "SetLinkDNSEx")]
        fn set_link_dns_ex(
            &self,
            ifindex: i32,
            addresses: Vec<(i32, Vec<u8>, u16, String)>,
        ) -> zbus::Result<()>;
        fn set_link_default_route(&self, ifindex: i32, enable: bool) -> zbus::Result<()>;
        fn revert_link(&self, ifindex: i32) -> zbus::Result<()>;
        fn flush_caches(&self) -> zbus::Result<()>;
    }

    const AF_INET: i32 = 2;

    async fn apply(connection: &zbus::Connection, state: &State) -> Result<(), String> {
        let ifindex = ensure_link().map_err(|e| e.to_string())?;
        let resolved = ResolveManagerProxy::new(connection)
            .await
            .map_err(|e| e.to_string())?;

        if state.zones.is_empty() {
            resolved
                .revert_link(ifindex)
                .await
                .map_err(|e| e.to_string())?;
        } else {
            let domains: Vec<(String, bool)> = state
                .zones
                .iter()
                .map(|zone| (zone.clone(), true)) // routing-only (~zone)
                .collect();
            resolved
                .set_link_domains(ifindex, domains)
                .await
                .map_err(|e| e.to_string())?;
            resolved
                .set_link_dns_ex(
                    ifindex,
                    vec![(AF_INET, vec![127, 0, 0, 1], state.port, String::new())],
                )
                .await
                .map_err(|e| e.to_string())?;
            resolved
                .set_link_default_route(ifindex, false)
                .await
                .map_err(|e| e.to_string())?;
        }
        let _ = resolved.flush_caches().await;
        Ok(())
    }

    // MARK: polkit

    #[zbus::proxy(
        interface = "org.freedesktop.PolicyKit1.Authority",
        default_service = "org.freedesktop.PolicyKit1",
        default_path = "/org/freedesktop/PolicyKit1/Authority"
    )]
    trait PolkitAuthority {
        /// Reply is a single struct out-arg `(bba{ss})`:
        /// (is_authorized, is_challenge, details).
        #[allow(clippy::type_complexity)]
        fn check_authorization(
            &self,
            subject: &(&str, HashMap<&str, Value<'_>>),
            action_id: &str,
            details: HashMap<&str, &str>,
            flags: u32,
            cancellation_id: &str,
        ) -> zbus::Result<(bool, bool, HashMap<String, String>)>;
    }

    /// Is the D-Bus caller authorized for our action? (allow_active=yes ⇒
    /// silent yes for the console user; AllowUserInteraction lets polkit
    /// prompt otherwise.)
    async fn authorized(connection: &zbus::Connection, sender: Option<&str>) -> bool {
        let Some(sender) = sender else { return false };
        let Ok(authority) = PolkitAuthorityProxy::new(connection).await else {
            return false;
        };
        let mut subject_details = HashMap::new();
        subject_details.insert("name", Value::from(sender));
        match authority
            .check_authorization(
                &("system-bus-name", subject_details),
                ACTION_ID,
                HashMap::new(),
                1, // AllowUserInteraction
                "",
            )
            .await
        {
            Ok((is_authorized, _, _)) => is_authorized,
            Err(error) => {
                eprintln!("localdns-agentd: polkit check failed: {error}");
                false
            }
        }
    }

    // MARK: the Agent1 interface

    #[derive(Serialize)]
    struct Reply {
        ok: bool,
        changed: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    }

    impl Reply {
        fn json(self) -> String {
            serde_json::to_string(&self).unwrap_or_else(|_| r#"{"ok":false}"#.into())
        }
        fn ok(changed: bool) -> String {
            Reply { ok: true, changed, error: None }.json()
        }
        fn fail(error: impl Into<String>) -> String {
            Reply { ok: false, changed: false, error: Some(error.into()) }.json()
        }
    }

    pub struct Agent {
        pub state: Arc<Mutex<State>>,
    }

    fn valid_zone(zone: &str) -> bool {
        localdns_core::validation::pattern_error(zone).is_none()
    }

    #[zbus::interface(name = "org.localdns.Agent1")]
    impl Agent {
        /// Declarative sync: the desired zone set + server port.
        async fn sync(
            &self,
            zones: Vec<String>,
            port: u16,
            #[zbus(connection)] connection: &zbus::Connection,
            #[zbus(header)] header: zbus::message::Header<'_>,
        ) -> String {
            let sender = header.sender().map(|s| s.as_str().to_owned());
            if !authorized(connection, sender.as_deref()).await {
                return Reply::fail("not authorized (org.localdns.agent.configure)");
            }
            if port < 1024 {
                return Reply::fail("port must be >= 1024");
            }
            let invalid: Vec<&String> = zones.iter().filter(|z| !valid_zone(z)).collect();
            if !invalid.is_empty() {
                return Reply::fail(format!("invalid zone name(s): {invalid:?}"));
            }

            let mut state = self.state.lock().await;
            let desired: BTreeSet<String> = zones.into_iter().collect();
            let changed = state.zones != desired || state.port != port;
            state.zones = desired;
            state.port = port;
            if let Err(error) = state.save() {
                return Reply::fail(format!("state persist failed: {error}"));
            }
            match apply(connection, &state).await {
                Ok(()) => Reply::ok(changed),
                Err(error) => Reply::fail(error),
            }
        }

        async fn unregister_all(
            &self,
            #[zbus(connection)] connection: &zbus::Connection,
            #[zbus(header)] header: zbus::message::Header<'_>,
        ) -> String {
            let sender = header.sender().map(|s| s.as_str().to_owned());
            if !authorized(connection, sender.as_deref()).await {
                return Reply::fail("not authorized (org.localdns.agent.configure)");
            }
            let mut state = self.state.lock().await;
            let changed = !state.zones.is_empty();
            state.zones.clear();
            let _ = state.save();
            match apply(connection, &state).await {
                Ok(()) => Reply::ok(changed),
                Err(error) => Reply::fail(error),
            }
        }

        /// Read-only: current agent state (no polkit needed).
        async fn status(&self) -> String {
            let state = self.state.lock().await;
            serde_json::json!({
                "zones": state.zones,
                "port": state.port,
                "ifindex": link_ifindex(),
            })
            .to_string()
        }
    }

    // MARK: daemon lifecycle

    pub async fn run() -> Result<(), Box<dyn std::error::Error>> {
        let state = Arc::new(Mutex::new(State::load()));

        let connection = zbus::connection::Builder::system()?
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, Agent { state: Arc::clone(&state) })?
            .build()
            .await?;

        // Boot-time apply of persisted state.
        {
            let state = state.lock().await;
            if let Err(error) = apply(&connection, &state).await {
                eprintln!("localdns-agentd: initial apply failed: {error}");
            }
        }

        // Re-apply whenever resolved gets a new bus owner (restart).
        let watcher_conn = connection.clone();
        let watcher_state = Arc::clone(&state);
        tokio::spawn(async move {
            let Ok(dbus) = zbus::fdo::DBusProxy::new(&watcher_conn).await else {
                return;
            };
            let Ok(mut stream) = dbus.receive_name_owner_changed().await else {
                return;
            };
            while let Some(signal) = stream.next().await {
                let Ok(args) = signal.args() else { continue };
                if args.name.as_str() == "org.freedesktop.resolve1" && args.new_owner.is_some() {
                    // Give resolved a beat to enumerate links, then re-apply.
                    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
                    let state = watcher_state.lock().await;
                    if let Err(error) = apply(&watcher_conn, &state).await {
                        eprintln!("localdns-agentd: re-apply after resolved restart failed: {error}");
                    }
                }
            }
        });

        // Run until SIGTERM/SIGINT; delete the link on the way out (resolved
        // forgets per-link settings with it — clean teardown).
        let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! {
            _ = sigterm.recv() => {}
            _ = tokio::signal::ctrl_c() => {}
        }
        delete_link();
        Ok(())
    }
}
