//! `localdns` — headless companion to the LocalDNS desktop app.
//!
//! Reads and writes the SAME rules.json/settings.json as the GUI, serves the
//! same wildcard DNS engine, and registers zones through the same per-OS
//! backend (systemd-resolved agent on Linux, NRPT helper on Windows). A lab
//! box bootstrap is:
//!
//!     localdns add '*.myapp.test' 172.30.0.3
//!     systemctl --user enable --now localdns        # or: localdns serve
//!
//! For dnsmasq people, dnsmasq remains a fine answer — this exists for
//! machines that keep systemd-resolved and for fleets sharing the desktop
//! app's rules format.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use clap::{Parser, Subcommand};

use localdns_core::message::{response, TYPE_A, TYPE_AAAA};
use localdns_core::paths;
use localdns_core::rules::{resolve, DnsResolution, DnsRule, RuleStore};
use localdns_core::zones::desired_zones;
use localdns_core::{hosts, validation};
use localdns_platform::{default_backend, AccessState, DnsEndpoint, SyncOutcome, ZoneState};

#[derive(Parser)]
#[command(
    name = "localdns",
    version,
    about = "Wildcard DNS for local development — headless CLI",
    after_help = "Rules live in the same rules.json as the LocalDNS desktop app."
)]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Add a rule: localdns add '*.myapp.test' 172.30.0.3
    Add {
        /// "*.zone.tld" (wildcard) or "host.tld" (exact)
        pattern: String,
        /// IPv4 or IPv6 address (family detected by shape)
        ip: String,
        #[arg(long, default_value_t = 60)]
        ttl: u32,
        #[arg(long, default_value = "Default")]
        group: String,
    },
    /// Remove rule(s) matching a pattern
    Remove { pattern: String },
    /// List rules
    List {
        #[arg(long)]
        json: bool,
    },
    /// Suggest wildcard rules from /etc/hosts (add them with --apply)
    ImportHosts {
        #[arg(long)]
        apply: bool,
    },
    /// Run the DNS server in the foreground (picks up rule changes live)
    Serve {
        /// Override the port from settings.json
        #[arg(long)]
        port: Option<u16>,
        /// Remove OS registrations when the server exits
        #[arg(long)]
        unregister_on_exit: bool,
    },
    /// Register the current zones with the OS resolver
    Sync,
    /// Zone registration status + server reachability
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Remove every LocalDNS-owned OS registration
    Unregister,
    /// Query the running server for the first enabled rule
    SelfTest,
}

fn settings_port() -> u16 {
    std::fs::read(paths::settings_path())
        .ok()
        .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
        .and_then(|v| v.get("port").and_then(|p| p.as_u64()))
        .map(|p| p as u16)
        .unwrap_or(15353)
}

fn endpoint(port: u16) -> DnsEndpoint {
    let backend = default_backend();
    backend.required_endpoint().unwrap_or(DnsEndpoint {
        addr: "127.0.0.1".parse().unwrap(),
        port,
    })
}

fn fail(message: impl std::fmt::Display) -> ! {
    eprintln!("error: {message}");
    std::process::exit(1);
}

fn main() {
    match Cli::parse().command {
        Cmd::Add { pattern, ip, ttl, group } => add(pattern, ip, ttl, group),
        Cmd::Remove { pattern } => remove(pattern),
        Cmd::List { json } => list(json),
        Cmd::ImportHosts { apply } => import_hosts(apply),
        Cmd::Serve { port, unregister_on_exit } => serve(port, unregister_on_exit),
        Cmd::Sync => sync(),
        Cmd::Status { json } => status(json),
        Cmd::Unregister => unregister(),
        Cmd::SelfTest => self_test(),
    }
}

fn add(pattern: String, ip: String, ttl: u32, group: String) {
    if let Some(error) = validation::pattern_error(&pattern) {
        fail(error);
    }
    if validation::uses_local_tld(&pattern) {
        eprintln!("warning: .local belongs to mDNS/Avahi — this can interfere with network services");
    }
    let is_v6 = ip.contains(':');
    if is_v6 {
        ip.parse::<std::net::Ipv6Addr>().unwrap_or_else(|_| fail("invalid IPv6 address"));
    } else {
        ip.parse::<std::net::Ipv4Addr>().unwrap_or_else(|_| fail("invalid IPv4 address"));
    }

    let mut store = RuleStore::load(paths::rules_path());
    let mut rule = DnsRule::new(pattern.trim());
    if is_v6 {
        rule.ipv6 = Some(ip);
    } else {
        rule.ipv4 = Some(ip);
    }
    rule.ttl = ttl.max(1);
    rule.group = group;
    let shown = rule.pattern.clone();
    store.rules.push(rule);
    store.save().unwrap_or_else(|e| fail(e));
    println!("added {shown}  ({} rule(s) total)", store.rules.len());
    hint_sync();
}

fn remove(pattern: String) {
    let normalized = localdns_core::normalize(&pattern);
    let mut store = RuleStore::load(paths::rules_path());
    let before = store.rules.len();
    store.rules.retain(|r| r.normalized_pattern() != normalized);
    if store.rules.len() == before {
        fail(format!("no rule matches {normalized}"));
    }
    store.save().unwrap_or_else(|e| fail(e));
    println!("removed {} rule(s)", before - store.rules.len());
    hint_sync();
}

fn list(json: bool) {
    let store = RuleStore::load(paths::rules_path());
    if json {
        println!("{}", serde_json::to_string_pretty(&store.rules).unwrap());
        return;
    }
    if store.rules.is_empty() {
        println!("no rules — add one: localdns add '*.myapp.test' 172.30.0.3");
        return;
    }
    for rule in &store.rules {
        let addresses = [rule.ipv4.as_deref(), rule.ipv6.as_deref()]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(", ");
        println!(
            "{} {:32} -> {:20} ttl={} group={}",
            if rule.enabled { "on " } else { "off" },
            rule.pattern,
            if addresses.is_empty() { "(no address)" } else { &addresses },
            rule.ttl,
            rule.group,
        );
    }
}

fn import_hosts(apply: bool) {
    let entries = hosts::load_system_hosts();
    let suggestions = hosts::suggestions(&entries);
    if suggestions.is_empty() {
        println!("no wildcard candidates in {}", hosts::system_hosts_path().display());
        return;
    }
    let mut store = RuleStore::load(paths::rules_path());
    let mut added = 0;
    for suggestion in &suggestions {
        let exists = store
            .rules
            .iter()
            .any(|r| r.normalized_pattern() == localdns_core::normalize(&suggestion.pattern));
        let marker = if exists { "=" } else { "+" };
        println!(
            "{marker} {:32} -> {:20} covers {}",
            suggestion.pattern,
            suggestion.ip,
            suggestion.covered_hostnames.len()
        );
        if apply && !exists {
            store.rules.push(suggestion.rule());
            added += 1;
        }
    }
    if apply {
        store.save().unwrap_or_else(|e| fail(e));
        println!("added {added} rule(s) to group Imported");
        hint_sync();
    } else if suggestions.iter().any(|s| {
        !store
            .rules
            .iter()
            .any(|r| r.normalized_pattern() == localdns_core::normalize(&s.pattern))
    }) {
        println!("run with --apply to add the + rows");
    }
}

fn sync() {
    let backend = default_backend();
    match backend.access() {
        AccessState::Granted => {}
        AccessState::NeedsSetup(reason) => fail(format!("setup required: {reason}")),
    }
    let store = RuleStore::load(paths::rules_path());
    let zones = desired_zones(&store.rules);
    let outcome = backend.sync(&zones, endpoint(settings_port()));
    report_outcome(outcome);
}

fn unregister() {
    let outcome = default_backend().unregister_all();
    report_outcome(outcome);
}

fn report_outcome(outcome: SyncOutcome) {
    match outcome {
        SyncOutcome::Applied { conflicts } => {
            println!("registrations applied");
            for zone in conflicts {
                println!("  managed elsewhere (untouched): {zone}");
            }
        }
        SyncOutcome::UpToDate { conflicts } => {
            println!("already up to date");
            for zone in conflicts {
                println!("  managed elsewhere (untouched): {zone}");
            }
        }
        SyncOutcome::AccessDenied => fail("access denied — is the agent/helper installed and running?"),
        SyncOutcome::Failed(error) => fail(error),
    }
}

fn status(json: bool) {
    let backend = default_backend();
    let store = RuleStore::load(paths::rules_path());
    let zones = desired_zones(&store.rules);
    let port = settings_port();
    let statuses = backend.status(&zones, endpoint(port));
    let serving = probe_server(&store.rules, port);

    if json {
        println!(
            "{}",
            serde_json::json!({
                "backend": backend.name(),
                "access": matches!(backend.access(), AccessState::Granted),
                "port": port,
                "serving": serving,
                "zones": statuses,
            })
        );
        return;
    }
    println!("backend : {}", backend.name());
    println!(
        "access  : {}",
        match backend.access() {
            AccessState::Granted => "granted".to_string(),
            AccessState::NeedsSetup(reason) => format!("setup required — {reason}"),
        }
    );
    println!(
        "server  : {}",
        match serving {
            Some(true) => format!("answering on 127.0.0.1:{port}"),
            Some(false) => format!("NOT answering on 127.0.0.1:{port} — run `localdns serve` or open the app"),
            None => format!("no enabled rules to probe (port {port})"),
        }
    );
    if statuses.is_empty() {
        println!("zones   : none");
    }
    for status in statuses {
        let label = match status.state {
            ZoneState::Registered => "registered",
            ZoneState::NeedsResync => "needs re-sync",
            ZoneState::NotRegistered => "not registered",
            ZoneState::ManagedElsewhere => "managed elsewhere",
        };
        println!("zone    : {:32} {label}", status.zone);
    }
}

/// One real query against the loopback server for the first enabled rule.
/// None when there is nothing to probe with.
fn probe_server(rules: &[DnsRule], port: u16) -> Option<bool> {
    let rule = rules.iter().find(|r| r.enabled && (r.ipv4.is_some() || r.ipv6.is_some()))?;
    let name = match rule.normalized_pattern().strip_prefix("*.") {
        Some(zone) => format!("probe.{zone}"),
        None => rule.normalized_pattern(),
    };
    let qtype = if rule.ipv4.is_some() { TYPE_A } else { TYPE_AAAA };
    let server: SocketAddr = ([127, 0, 0, 1], port).into();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().ok()?;
    Some(
        runtime
            .block_on(localdns_server::lookup(&name, qtype, server, Duration::from_secs(1)))
            .is_ok(),
    )
}

fn self_test() {
    let store = RuleStore::load(paths::rules_path());
    match probe_server(&store.rules, settings_port()) {
        Some(true) => println!("ok — server answers"),
        Some(false) => fail("server did not answer"),
        None => fail("add an enabled rule with an address first"),
    }
}

fn hint_sync() {
    // Only nag when registrations are actually stale and a backend is usable.
    let backend = default_backend();
    if matches!(backend.access(), AccessState::Granted) {
        let store = RuleStore::load(paths::rules_path());
        let zones = desired_zones(&store.rules);
        let plan = backend.plan(&zones, endpoint(settings_port()));
        if !plan.is_noop() {
            println!("(zones changed — run `localdns sync`, or they sync automatically while `localdns serve` runs)");
        }
    }
}

fn serve(port_override: Option<u16>, unregister_on_exit: bool) {
    let port = port_override.unwrap_or_else(settings_port);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap_or_else(|e| fail(e));
    runtime.block_on(serve_async(port, unregister_on_exit));
}

async fn serve_async(port: u16, unregister_on_exit: bool) {
    use arc_swap::ArcSwap;

    let store = RuleStore::load(paths::rules_path());
    let rules = Arc::new(ArcSwap::from_pointee(store.rules));
    let backend: Arc<dyn localdns_platform::ResolverBackend> = Arc::from(default_backend());

    let handler_rules = Arc::clone(&rules);
    let handler: localdns_server::Handler = Arc::new(move |query| {
        let rules = handler_rules.load();
        match resolve(&query, &rules) {
            DnsResolution::Answers(answers) => response::answers(&query, &answers),
            DnsResolution::NoData => response::empty(&query),
            DnsResolution::Nxdomain => response::nxdomain(&query),
        }
    });

    let backend_endpoint = backend.required_endpoint().unwrap_or(DnsEndpoint {
        addr: "127.0.0.1".parse().unwrap(),
        port,
    });
    let mut addrs: Vec<SocketAddr> = vec![([127, 0, 0, 1], port).into()];
    let pinned = SocketAddr::new(backend_endpoint.addr, backend_endpoint.port);
    if !addrs.contains(&pinned) {
        addrs.push(pinned);
    }

    let handle = localdns_server::start(localdns_server::ServerConfig { addrs }, handler)
        .await
        .unwrap_or_else(|e| fail(e));
    println!("serving on {:?}", handle.bound);

    // Initial registration + re-sync whenever the rule file changes on disk
    // (a `localdns add` from another shell is picked up within ~2s).
    let sync_backend = Arc::clone(&backend);
    let do_sync = move |rules: &[DnsRule]| {
        if matches!(sync_backend.access(), AccessState::Granted) {
            let zones = desired_zones(rules);
            match sync_backend.sync(&zones, backend_endpoint) {
                SyncOutcome::Applied { .. } => println!("zones registered"),
                SyncOutcome::Failed(error) => eprintln!("zone sync failed: {error}"),
                _ => {}
            }
        }
    };
    do_sync(&rules.load());

    let watch_rules = Arc::clone(&rules);
    let watcher = tokio::spawn(async move {
        let path = paths::rules_path();
        let mut last = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        loop {
            tokio::time::sleep(Duration::from_secs(2)).await;
            let current = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
            if current != last {
                last = current;
                let store = RuleStore::load(path.clone());
                println!("rules.json changed — {} rule(s) loaded", store.rules.len());
                watch_rules.store(Arc::new(store.rules.clone()));
                do_sync(&store.rules);
            }
        }
    });

    // SIGTERM (systemd stop) and Ctrl-C both shut down cleanly.
    #[cfg(unix)]
    {
        let mut sigterm =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
        tokio::select! {
            _ = sigterm.recv() => {}
            _ = tokio::signal::ctrl_c() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }

    watcher.abort();
    if unregister_on_exit {
        let _ = backend.unregister_all();
        println!("registrations removed");
    }
    handle.shutdown().await;
    println!("stopped");
}
