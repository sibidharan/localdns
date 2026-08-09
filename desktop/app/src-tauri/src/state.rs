//! Managed app state — the Rust analogue of AppState.swift.
//!
//! The DNS handler runs on server tasks and reads rules through `rules_box`
//! (a lock-free snapshot, the `RulesBox` equivalent); every mutation stores a
//! fresh snapshot and persists via `store`. Query-log publication to the UI is
//! debounced 300 ms (`log_gate`) — the idle-CPU lesson from the macOS app.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use arc_swap::ArcSwap;
use tauri::{AppHandle, Emitter, Manager};

use localdns_core::rules::{DnsRule, RuleStore};
use localdns_core::QueryLog;
use localdns_platform::{DnsEndpoint, ResolverBackend};
use localdns_server::ServerHandle;

use crate::paths;
use crate::settings::Settings;

pub struct AppState {
    pub rules_box: Arc<ArcSwap<Vec<DnsRule>>>,
    pub query_log: Arc<QueryLog>,
    pub store: Mutex<RuleStore>,
    pub settings: Mutex<Settings>,
    /// tokio Mutex: shutdown is async and must not block the main thread.
    pub server: tokio::sync::Mutex<Option<ServerHandle>>,
    pub server_error: Mutex<Option<String>>,
    pub backend: Arc<dyn ResolverBackend>,
    pub log_gate: DebounceGate,
    pub autosync: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    /// When the tray failed to initialize (some Linux DEs), closing the window
    /// quits instead of hiding, so the app can't become unreachable.
    pub tray_available: AtomicBool,
}

impl AppState {
    pub fn load() -> Self {
        let store = RuleStore::load(paths::rules_path());
        let rules = store.rules.clone();
        Self {
            rules_box: Arc::new(ArcSwap::from_pointee(rules)),
            query_log: Arc::new(QueryLog::default()),
            store: Mutex::new(store),
            settings: Mutex::new(Settings::load(&paths::settings_path())),
            server: tokio::sync::Mutex::new(None),
            server_error: Mutex::new(None),
            backend: Arc::from(localdns_platform::default_backend()),
            log_gate: DebounceGate::default(),
            autosync: Mutex::new(None),
            tray_available: AtomicBool::new(false),
        }
    }

    /// Where the OS registration should point queries — the backend's pinned
    /// endpoint (Windows: port 53 on a dedicated loopback address) or the
    /// user-configured port on 127.0.0.1.
    pub fn registration_endpoint(&self) -> DnsEndpoint {
        self.backend.required_endpoint().unwrap_or(DnsEndpoint {
            addr: IpAddr::V4(Ipv4Addr::LOCALHOST),
            port: self.settings.lock().unwrap().port,
        })
    }

    /// Everything the server must bind: the user-visible loopback port always
    /// (self-test parity across OSes), plus the backend-pinned endpoint if any.
    pub fn server_addrs(&self) -> Vec<SocketAddr> {
        let port = self.settings.lock().unwrap().port;
        let mut addrs = vec![SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port)];
        if let Some(endpoint) = self.backend.required_endpoint() {
            let pinned = SocketAddr::new(endpoint.addr, endpoint.port);
            if !addrs.contains(&pinned) {
                addrs.push(pinned);
            }
        }
        addrs
    }
}

/// Leading-gated trailing debounce, the exact shape of
/// `AppState.schedulePublishQueryLog`: pokes while a publish is pending are
/// no-ops; one publish fires per busy window with the latest snapshot.
#[derive(Default)]
pub struct DebounceGate {
    pending: AtomicBool,
}

impl DebounceGate {
    pub fn poke(&self, app: AppHandle) {
        if self.pending.swap(true, Ordering::AcqRel) {
            return;
        }
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            let state = app.state::<AppState>();
            state.log_gate.pending.store(false, Ordering::Release);
            publish_query_log(&app);
        });
    }
}

/// Emits the query-log snapshot to the window (only when visible — a hidden
/// webview shouldn't be woken 3×/second) and refreshes the tray's recent list.
pub fn publish_query_log(app: &AppHandle) {
    let state = app.state::<AppState>();
    let entries = state.query_log.entries();
    let visible = app
        .get_webview_window("main")
        .and_then(|w| w.is_visible().ok())
        .unwrap_or(false);
    if visible {
        let _ = app.emit("query-log", &entries);
    }
    crate::tray::update_recent_queries(app, &entries);
}
