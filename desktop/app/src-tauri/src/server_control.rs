//! DNS server lifecycle: start/stop/restart on settings changes, the query
//! handler, and the debounced resolver auto-sync (`scheduleAutoSync` parity).

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

use localdns_core::message::response;
use localdns_core::rules::{resolve, DnsResolution};
use localdns_core::zones::desired_zones;
use localdns_core::QueryLogEntry;
use localdns_platform::AccessState;
use localdns_server::{Handler, ServerConfig};

use crate::state::AppState;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerStatus {
    pub running: bool,
    pub enabled: bool,
    pub error: Option<String>,
    pub port: u16,
    pub endpoints: Vec<String>,
    pub backend: &'static str,
    /// True when the backend pins the endpoint (Windows NRPT: port 53) and the
    /// Settings port field should render read-only with a note.
    pub endpoint_pinned: bool,
}

pub fn current_status(app: &AppHandle) -> ServerStatus {
    let state = app.state::<AppState>();
    let settings = state.settings.lock().unwrap().clone();
    let running = state
        .server
        .try_lock()
        .map(|guard| guard.is_some())
        .unwrap_or(true); // locked ⇒ a restart is in flight; treat as running
    let error = state.server_error.lock().unwrap().clone();
    let status = ServerStatus {
        running,
        enabled: settings.server_enabled,
        error,
        port: settings.port,
        endpoints: state.server_addrs().iter().map(|a| a.to_string()).collect(),
        backend: state.backend.name(),
        endpoint_pinned: state.backend.required_endpoint().is_some(),
    };
    status
}

pub fn emit_server_status(app: &AppHandle) {
    let _ = app.emit("server-status", current_status(app));
    crate::tray::update_status(app);
}

/// Stops any running server, then starts one when enabled — the swap pattern
/// of `applyPortChange()`. Handler state (rules snapshot, query log) is shared,
/// so nothing is lost across restarts.
pub async fn apply_server_state(app: &AppHandle) {
    let state = app.state::<AppState>();
    let mut guard = state.server.lock().await;
    if let Some(handle) = guard.take() {
        handle.shutdown().await;
    }
    *state.server_error.lock().unwrap() = None;

    let enabled = state.settings.lock().unwrap().server_enabled;
    if enabled {
        let config = ServerConfig {
            addrs: state.server_addrs(),
        };
        match localdns_server::start(config, make_handler(app.clone())).await {
            Ok(handle) => *guard = Some(handle),
            Err(error) => *state.server_error.lock().unwrap() = Some(error.to_string()),
        }
    }
    drop(guard);
    emit_server_status(app);
}

/// The rule-engine hook: resolve against the lock-free snapshot, log with
/// latency, poke the debounced publisher, serialize the response.
fn make_handler(app: AppHandle) -> Handler {
    Arc::new(move |query| {
        let state = app.state::<AppState>();
        let started = Instant::now();
        let rules = state.rules_box.load();
        let resolution = resolve(&query, &rules);
        let latency_ms = started.elapsed().as_secs_f64() * 1000.0;
        state
            .query_log
            .append(QueryLogEntry::from_resolution(&query, &resolution, latency_ms));
        state.log_gate.poke(app.clone());
        match resolution {
            DnsResolution::Answers(answers) => response::answers(&query, &answers),
            DnsResolution::NoData => response::empty(&query),
            DnsResolution::Nxdomain => response::nxdomain(&query),
        }
    })
}

/// Debounced (300 ms, cancel-and-restart) resolver sync after rule/port
/// changes, only when the backend is granted — `scheduleAutoSync` parity.
pub fn schedule_auto_sync(app: &AppHandle) {
    let state = app.state::<AppState>();
    let mut slot = state.autosync.lock().unwrap();
    if let Some(pending) = slot.take() {
        pending.abort();
    }
    let app = app.clone();
    *slot = Some(tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        run_resolver_sync(&app).await;
    }));
}

/// Runs a backend sync off the main thread and notifies the Setup view.
pub async fn run_resolver_sync(app: &AppHandle) {
    let state = app.state::<AppState>();
    if !matches!(state.backend.access(), AccessState::Granted) {
        return;
    }
    let backend = Arc::clone(&state.backend);
    let zones = desired_zones(&state.rules_box.load());
    let endpoint = state.registration_endpoint();
    let _ = tauri::async_runtime::spawn_blocking(move || backend.sync(&zones, endpoint)).await;
    let _ = app.emit("resolver-changed", ());
}
