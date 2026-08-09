//! IPC command surface — mirrors AppState.swift's operations one-to-one.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

use localdns_core::hosts;
use localdns_core::message::{TYPE_A, TYPE_AAAA};
use localdns_core::rules::{best_match, DnsRule};
use localdns_core::validation;
use localdns_core::zones::desired_zones;
use localdns_core::QueryLogEntry;
use localdns_platform::{
    AccessState, DnsEndpoint, SetupInstructions, SyncOutcome, SyncPlan, ZoneStatus,
};

use crate::server_control::{self, ServerStatus};
use crate::settings::Settings;
use crate::state::AppState;

type CmdResult<T> = Result<T, String>;

/// Apply a mutation to the rules, snapshot for the server, persist, notify,
/// and schedule the debounced resolver auto-sync — `mutateRules` parity.
fn mutate_rules<F: FnOnce(&mut Vec<DnsRule>)>(app: &AppHandle, f: F) -> CmdResult<Vec<DnsRule>> {
    let state = app.state::<AppState>();
    let rules = {
        let mut store = state.store.lock().unwrap();
        f(&mut store.rules);
        state.rules_box.store(Arc::new(store.rules.clone()));
        store.save().map_err(|e| e.to_string())?;
        store.rules.clone()
    };
    let _ = app.emit("rules-changed", &rules);
    server_control::schedule_auto_sync(app);
    Ok(rules)
}

// MARK: Bootstrap

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Bootstrap {
    pub rules: Vec<DnsRule>,
    pub settings: Settings,
    pub status: ServerStatus,
    pub query_log: Vec<QueryLogEntry>,
}

/// One-call hydration for the frontend at startup / window reopen.
#[tauri::command]
pub fn get_bootstrap(app: AppHandle, state: State<AppState>) -> Bootstrap {
    // The settings guard MUST drop before current_status() (which locks
    // settings itself). As struct-literal fields these temporaries live to the
    // end of the whole expression — a same-thread relock self-deadlock that
    // freezes the webview's IPC on the main thread before first paint.
    let rules = state.rules_box.load().as_ref().clone();
    let settings = state.settings.lock().unwrap().clone();
    let status = server_control::current_status(&app);
    let query_log = state.query_log.entries();
    Bootstrap {
        rules,
        settings,
        status,
        query_log,
    }
}

// MARK: Rules CRUD

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuleInput {
    pub pattern: String,
    pub ipv4: Option<String>,
    pub ipv6: Option<String>,
    pub ttl: u32,
    pub group: String,
}

impl RuleInput {
    fn into_rule(self) -> Result<DnsRule, String> {
        if let Some(error) = validation::pattern_error(&self.pattern) {
            return Err(error);
        }
        let clean = |v: Option<String>| v.filter(|s| !s.trim().is_empty());
        let group = if self.group.trim().is_empty() {
            "Default".to_string()
        } else {
            self.group.trim().to_string()
        };
        let mut rule = DnsRule::new(self.pattern.trim());
        rule.ipv4 = clean(self.ipv4);
        rule.ipv6 = clean(self.ipv6);
        rule.ttl = self.ttl.max(1);
        rule.group = group;
        Ok(rule)
    }
}

#[tauri::command]
pub fn add_rule(app: AppHandle, input: RuleInput) -> CmdResult<Vec<DnsRule>> {
    let rule = input.into_rule()?;
    mutate_rules(&app, |rules| rules.push(rule))
}

#[tauri::command]
pub fn update_rule(app: AppHandle, rule: DnsRule) -> CmdResult<Vec<DnsRule>> {
    if let Some(error) = validation::pattern_error(&rule.pattern) {
        return Err(error);
    }
    mutate_rules(&app, |rules| {
        if let Some(slot) = rules.iter_mut().find(|r| r.id == rule.id) {
            *slot = rule;
        }
    })
}

#[tauri::command]
pub fn delete_rule(app: AppHandle, id: Uuid) -> CmdResult<Vec<DnsRule>> {
    mutate_rules(&app, |rules| rules.retain(|r| r.id != id))
}

#[tauri::command]
pub fn set_rule_enabled(app: AppHandle, id: Uuid, enabled: bool) -> CmdResult<Vec<DnsRule>> {
    mutate_rules(&app, |rules| {
        if let Some(rule) = rules.iter_mut().find(|r| r.id == id) {
            rule.enabled = enabled;
        }
    })
}

/// Group master switch — flips every rule in the group.
#[tauri::command]
pub fn set_group_enabled(app: AppHandle, group: String, enabled: bool) -> CmdResult<Vec<DnsRule>> {
    mutate_rules(&app, |rules| {
        for rule in rules.iter_mut().filter(|r| r.group == group) {
            rule.enabled = enabled;
        }
    })
}

// MARK: Edit-sheet helpers

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PatternCheck {
    pub error: Option<String>,
    pub local_tld_warning: bool,
}

#[tauri::command]
pub fn validate_pattern(pattern: String) -> PatternCheck {
    PatternCheck {
        error: validation::pattern_error(&pattern),
        local_tld_warning: validation::uses_local_tld(&pattern),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftRule {
    /// Present when editing an existing rule (it is excluded from the pool
    /// and replaced by this draft, exactly like the macOS edit sheet).
    pub id: Option<Uuid>,
    pub pattern: String,
    pub ipv4: Option<String>,
    pub ipv6: Option<String>,
    pub ttl: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MatchPreview {
    pub pattern: String,
    pub ipv4: Option<String>,
    pub ipv6: Option<String>,
    pub ttl: u32,
    pub is_draft: bool,
}

/// Live "what will this answer" preview using the real matcher.
#[tauri::command]
pub fn preview_match(
    state: State<AppState>,
    name: String,
    draft: Option<DraftRule>,
) -> Option<MatchPreview> {
    let mut pool: Vec<DnsRule> = state.rules_box.load().as_ref().clone();
    let draft_id = Uuid::new_v4();
    if let Some(draft) = draft {
        if let Some(id) = draft.id {
            pool.retain(|r| r.id != id);
        }
        let mut rule = DnsRule::new(draft.pattern);
        rule.id = draft_id;
        rule.ipv4 = draft.ipv4.filter(|s| !s.trim().is_empty());
        rule.ipv6 = draft.ipv6.filter(|s| !s.trim().is_empty());
        rule.ttl = draft.ttl;
        pool.push(rule);
    }
    best_match(&name, &pool).map(|rule| MatchPreview {
        pattern: rule.pattern.clone(),
        ipv4: rule.ipv4.clone(),
        ipv6: rule.ipv6.clone(),
        ttl: rule.ttl,
        is_draft: rule.id == draft_id,
    })
}

// MARK: Settings

#[tauri::command]
pub fn get_settings(state: State<AppState>) -> Settings {
    state.settings.lock().unwrap().clone()
}

/// Applies the whole settings struct: persists, restarts the server on
/// port/enabled changes, toggles autostart, and re-syncs zones.
#[tauri::command]
pub async fn set_settings(app: AppHandle, settings: Settings) -> CmdResult<Settings> {
    let (server_changed, login_changed) = {
        let state = app.state::<AppState>();
        let mut current = state.settings.lock().unwrap();
        let server_changed = current.port != settings.port
            || current.server_enabled != settings.server_enabled;
        let login_changed = current.launch_at_login != settings.launch_at_login;
        *current = settings.clone();
        current
            .save(&crate::paths::settings_path())
            .map_err(|e| e.to_string())?;
        (server_changed, login_changed)
    };

    if login_changed {
        apply_launch_at_login(&app, settings.launch_at_login);
    }
    if server_changed {
        server_control::apply_server_state(&app).await;
        server_control::schedule_auto_sync(&app); // port changes re-write registrations
    }
    let _ = app.emit("settings-changed", &settings);
    Ok(settings)
}

fn apply_launch_at_login(app: &AppHandle, enabled: bool) {
    use tauri_plugin_autostart::ManagerExt;
    let autostart = app.autolaunch();
    let result = if enabled {
        autostart.enable()
    } else {
        autostart.disable()
    };
    if let Err(error) = result {
        eprintln!("autostart change failed: {error}");
    }
}

// MARK: Server status / self-test

#[tauri::command]
pub fn get_status(app: AppHandle) -> ServerStatus {
    server_control::current_status(&app)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SelfTestResult {
    pub ok: bool,
    pub message: String,
}

/// Sends a real UDP query to the loopback endpoint and compares the answer to
/// what the rule engine says it should be — end-to-end through the socket.
#[tauri::command]
pub async fn run_self_test(app: AppHandle) -> SelfTestResult {
    let (rule, port) = {
        let state = app.state::<AppState>();
        let rules = state.rules_box.load();
        let rule = rules
            .iter()
            .find(|r| r.enabled && (r.ipv4.is_some() || r.ipv6.is_some()))
            .cloned();
        let port = state.settings.lock().unwrap().port;
        (rule, port)
    };
    let Some(rule) = rule else {
        return SelfTestResult {
            ok: false,
            message: "Add an enabled rule with an address first.".into(),
        };
    };

    let pattern = rule.normalized_pattern();
    let name = match pattern.strip_prefix("*.") {
        Some(zone) => format!("selftest.{zone}"),
        None => pattern.clone(),
    };
    let (qtype, qtype_label, expected) = if let Some(ipv4) = &rule.ipv4 {
        (TYPE_A, "A", ipv4.clone())
    } else {
        (TYPE_AAAA, "AAAA", rule.ipv6.clone().unwrap_or_default())
    };

    let server: SocketAddr = ([127, 0, 0, 1], port).into();
    match localdns_server::lookup(&name, qtype, server, Duration::from_secs(3)).await {
        Ok(result) if result.answers.iter().any(|a| a == &expected) => SelfTestResult {
            ok: true,
            message: format!("{name} → {expected} ({qtype_label}) via 127.0.0.1:{port}"),
        },
        Ok(result) => SelfTestResult {
            ok: false,
            message: format!(
                "Expected {expected}, got rcode {} answers [{}].",
                result.rcode,
                result.answers.join(", ")
            ),
        },
        Err(error) => SelfTestResult {
            ok: false,
            message: format!("Query to 127.0.0.1:{port} failed: {error}"),
        },
    }
}

// MARK: Query log

#[tauri::command]
pub fn get_query_log(state: State<AppState>) -> Vec<QueryLogEntry> {
    state.query_log.entries()
}

#[tauri::command]
pub fn clear_query_log(app: AppHandle, state: State<AppState>) -> Vec<QueryLogEntry> {
    state.query_log.clear();
    crate::state::publish_query_log(&app);
    Vec::new()
}

// MARK: Hosts import

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostsScan {
    pub path: String,
    pub suggestions: Vec<hosts::SuggestedRule>,
    pub uncovered: Vec<String>,
}

#[tauri::command]
pub async fn scan_hosts(app: AppHandle) -> HostsScan {
    let rules: Vec<DnsRule> = app.state::<AppState>().rules_box.load().as_ref().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let entries = hosts::load_system_hosts();
        HostsScan {
            path: hosts::system_hosts_path().display().to_string(),
            suggestions: hosts::suggestions(&entries),
            uncovered: hosts::uncovered(&entries, &rules),
        }
    })
    .await
    .unwrap_or(HostsScan {
        path: hosts::system_hosts_path().display().to_string(),
        suggestions: vec![],
        uncovered: vec![],
    })
}

#[derive(Deserialize)]
pub struct SuggestionInput {
    pub pattern: String,
    pub ip: String,
}

/// Adds hosts-import suggestions (group "Imported"), skipping patterns that
/// already exist — Add / Add All share this path.
#[tauri::command]
pub fn add_suggested_rules(app: AppHandle, items: Vec<SuggestionInput>) -> CmdResult<Vec<DnsRule>> {
    mutate_rules(&app, |rules| {
        for item in items {
            let suggestion = hosts::SuggestedRule {
                pattern: item.pattern,
                ip: item.ip,
                covered_hostnames: vec![],
            };
            let rule = suggestion.rule();
            let duplicate = rules
                .iter()
                .any(|r| r.normalized_pattern() == rule.normalized_pattern());
            if !duplicate {
                rules.push(rule);
            }
        }
    })
}

// MARK: Resolver / Setup view

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolverOverview {
    pub backend: &'static str,
    pub access: AccessState,
    pub endpoint: DnsEndpoint,
    pub statuses: Vec<ZoneStatus>,
    pub plan: SyncPlan,
    pub instructions: SetupInstructions,
}

/// Everything the Setup view renders, in one call (backend work off-thread).
#[tauri::command]
pub async fn resolver_overview(app: AppHandle) -> ResolverOverview {
    let state = app.state::<AppState>();
    let backend = Arc::clone(&state.backend);
    let zones = desired_zones(&state.rules_box.load());
    let endpoint = state.registration_endpoint();
    tauri::async_runtime::spawn_blocking(move || ResolverOverview {
        backend: backend.name(),
        access: backend.access(),
        endpoint,
        statuses: backend.status(&zones, endpoint),
        plan: backend.plan(&zones, endpoint),
        instructions: backend.setup_instructions(endpoint),
    })
    .await
    .expect("resolver overview task panicked")
}

#[tauri::command]
pub async fn resolver_sync(app: AppHandle) -> SyncOutcome {
    let state = app.state::<AppState>();
    let backend = Arc::clone(&state.backend);
    let zones = desired_zones(&state.rules_box.load());
    let endpoint = state.registration_endpoint();
    let outcome = tauri::async_runtime::spawn_blocking(move || backend.sync(&zones, endpoint))
        .await
        .unwrap_or(SyncOutcome::Failed("sync task panicked".into()));
    let _ = app.emit("resolver-changed", ());
    outcome
}

#[tauri::command]
pub async fn resolver_unregister_all(app: AppHandle) -> SyncOutcome {
    let state = app.state::<AppState>();
    let backend = Arc::clone(&state.backend);
    let outcome = tauri::async_runtime::spawn_blocking(move || backend.unregister_all())
        .await
        .unwrap_or(SyncOutcome::Failed("unregister task panicked".into()));
    let _ = app.emit("resolver-changed", ());
    outcome
}

// MARK: Window / lifecycle

#[tauri::command]
pub fn show_main_window(app: AppHandle) {
    crate::show_window(&app);
}

/// Quit honoring unregister-on-quit, then a clean server shutdown — `quit()` parity.
#[tauri::command]
pub async fn quit_app(app: AppHandle) {
    crate::shutdown_and_exit(app).await;
}
