//! Command-layer tests on tauri's mock runtime: the same `#[tauri::command]`
//! functions the webview invokes, driven directly against a managed AppState
//! with an isolated config dir and the mock resolver backend.
//!
//! Env vars are process-global, so every test holds ENV_LOCK for its whole
//! body — they run serialized, each in a fresh temp config dir.

use std::sync::{Mutex, MutexGuard};

use tauri::test::MockRuntime;
use tauri::{App, Listener, Manager};

use crate::commands::{self, DraftRule, RuleInput, SuggestionInput};
use crate::state::AppState;
use crate::{server_control, tray};

static ENV_LOCK: Mutex<()> = Mutex::new(());

struct TestApp {
    _guard: MutexGuard<'static, ()>,
    dir: tempfile::TempDir,
    app: App<MockRuntime>,
}

impl TestApp {
    fn new() -> Self {
        let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("LOCALDNS_CONFIG_DIR", dir.path());
        std::env::set_var("LOCALDNS_BACKEND", "mock");
        let app = tauri::test::mock_builder()
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .unwrap();
        app.manage(AppState::load());
        Self { _guard: guard, dir, app }
    }

    fn handle(&self) -> tauri::AppHandle<MockRuntime> {
        self.app.handle().clone()
    }

    fn state(&self) -> tauri::State<'_, AppState> {
        self.app.state::<AppState>()
    }

    fn add(&self, pattern: &str, ipv4: &str) -> Vec<localdns_core::rules::DnsRule> {
        commands::add_rule(
            self.handle(),
            RuleInput {
                pattern: pattern.into(),
                ipv4: Some(ipv4.into()),
                ipv6: None,
                ttl: 60,
                group: String::new(),
            },
        )
        .expect("add_rule")
    }
}

#[test]
fn bootstrap_reports_defaults_and_never_deadlocks() {
    let t = TestApp::new();
    // Regression guard: get_bootstrap once self-deadlocked via a settings
    // guard held across a struct-literal field boundary. Calling it twice
    // back-to-back would hang here if that ever returns.
    let first = commands::get_bootstrap(t.handle(), t.state());
    let again = commands::get_bootstrap(t.handle(), t.state());
    assert!(first.rules.is_empty());
    assert_eq!(first.settings.port, 15353);
    assert_eq!(first.status.backend, "mock");
    assert!(!first.status.running, "no server was started");
    assert!(!first.status.endpoint_pinned);
    assert!(again.query_log.is_empty());
}

#[test]
fn rules_crud_persists_and_notifies() {
    let t = TestApp::new();
    let (tx, rx) = std::sync::mpsc::channel::<()>();
    t.app.listen("rules-changed", move |_| {
        let _ = tx.send(());
    });

    let rules = t.add("*.crud.test", "172.30.0.21");
    assert_eq!(rules.len(), 1);
    rx.recv_timeout(std::time::Duration::from_secs(2))
        .expect("rules-changed event");
    assert!(t.dir.path().join("rules.json").exists(), "rule file persisted");

    let mut rule = rules[0].clone();
    rule.ttl = 300;
    let rules = commands::update_rule(t.handle(), rule.clone()).unwrap();
    assert_eq!(rules[0].ttl, 300);

    let rules = commands::set_rule_enabled(t.handle(), rule.id, false).unwrap();
    assert!(!rules[0].enabled);

    let rules = commands::set_group_enabled(t.handle(), "Default".into(), true).unwrap();
    assert!(rules[0].enabled, "group switch re-enabled the rule");

    let rules = commands::delete_rule(t.handle(), rule.id).unwrap();
    assert!(rules.is_empty());

    // Validation runs before mutation.
    let err = commands::add_rule(
        t.handle(),
        RuleInput {
            pattern: "*.co.uk".into(),
            ipv4: Some("10.0.0.1".into()),
            ipv6: None,
            ttl: 60,
            group: String::new(),
        },
    )
    .unwrap_err();
    assert!(err.contains("public suffix"), "{err}");
    let err = commands::update_rule(t.handle(), {
        let mut bad = rule.clone();
        bad.pattern = "not a hostname".into();
        bad
    })
    .unwrap_err();
    assert!(!err.is_empty());
}

#[test]
fn pattern_validation_and_match_preview() {
    let t = TestApp::new();

    let check = commands::validate_pattern("*.ok.test".into());
    assert!(check.error.is_none() && !check.local_tld_warning);
    let check = commands::validate_pattern("*.myapp.local".into());
    assert!(check.error.is_none() && check.local_tld_warning);
    let check = commands::validate_pattern("*.co.uk".into());
    assert!(check.error.is_some());

    t.add("*.app.test", "172.30.0.22");

    // Existing rule answers.
    let preview = commands::preview_match(t.state(), "api.app.test".into(), None).unwrap();
    assert_eq!(preview.pattern, "*.app.test");
    assert!(!preview.is_draft);

    // A longer draft pattern wins and is flagged as the draft.
    let preview = commands::preview_match(
        t.state(),
        "x.deep.app.test".into(),
        Some(DraftRule {
            id: None,
            pattern: "*.deep.app.test".into(),
            ipv4: Some("172.30.0.23".into()),
            ipv6: None,
            ttl: 60,
        }),
    )
    .unwrap();
    assert!(preview.is_draft);
    assert_eq!(preview.ipv4.as_deref(), Some("172.30.0.23"));

    // No match at all.
    assert!(commands::preview_match(t.state(), "nothing.example".into(), None).is_none());
}

#[test]
fn server_lifecycle_self_test_and_query_log() {
    let t = TestApp::new();

    // Enable the server on a dedicated port via the real settings path.
    let mut settings = commands::get_settings(t.state());
    settings.port = 26251;
    settings.server_enabled = true;
    let saved = tauri::async_runtime::block_on(commands::set_settings(t.handle(), settings))
        .expect("set_settings");
    assert_eq!(saved.port, 26251);
    assert!(t.dir.path().join("settings.json").exists());

    let status = commands::get_status(t.handle());
    assert!(status.running, "server must be up: {:?}", status.error);
    assert!(status.endpoints.iter().any(|e| e.ends_with(":26251")));

    // Nothing to probe yet.
    let result = tauri::async_runtime::block_on(commands::run_self_test(t.handle()));
    assert!(!result.ok);
    assert!(result.message.contains("Add an enabled rule"), "{}", result.message);

    // Real UDP round-trip through the running server.
    t.add("*.selftest.test", "172.30.0.24");
    let result = tauri::async_runtime::block_on(commands::run_self_test(t.handle()));
    assert!(result.ok, "{}", result.message);
    assert!(result.message.contains("172.30.0.24"));

    // The handler logged the query; clear empties it.
    assert!(!commands::get_query_log(t.state()).is_empty());
    assert!(commands::clear_query_log(t.handle(), t.state()).is_empty());
    assert!(commands::get_query_log(t.state()).is_empty());

    // Debounced publisher: poke twice (second is gated), let it fire.
    t.state().log_gate.poke(t.handle());
    t.state().log_gate.poke(t.handle());
    std::thread::sleep(std::time::Duration::from_millis(450));

    // Disabling stops the server; self-test now fails at the socket.
    let mut settings = commands::get_settings(t.state());
    settings.server_enabled = false;
    tauri::async_runtime::block_on(commands::set_settings(t.handle(), settings)).unwrap();
    let status = commands::get_status(t.handle());
    assert!(!status.running);
    let result = tauri::async_runtime::block_on(commands::run_self_test(t.handle()));
    assert!(!result.ok);
    assert!(result.message.contains("failed"), "{}", result.message);
}

#[test]
fn hosts_scan_and_suggested_rules() {
    let t = TestApp::new();
    let hosts = t.dir.path().join("hosts");
    std::fs::write(
        &hosts,
        "127.0.0.1 localhost\n172.30.0.5 api.dev.test\n172.30.0.5 web.dev.test\n172.30.0.5 db.dev.test\n",
    )
    .unwrap();
    std::env::set_var("LOCALDNS_HOSTS_PATH", &hosts);

    let scan = tauri::async_runtime::block_on(commands::scan_hosts(t.handle()));
    std::env::remove_var("LOCALDNS_HOSTS_PATH");
    assert_eq!(scan.path, hosts.display().to_string());
    assert!(
        scan.suggestions.iter().any(|s| s.pattern == "*.dev.test"),
        "expected a wildcard suggestion, got {:?}",
        scan.suggestions
    );

    let rules = commands::add_suggested_rules(
        t.handle(),
        vec![SuggestionInput { pattern: "*.dev.test".into(), ip: "172.30.0.5".into() }],
    )
    .unwrap();
    assert_eq!(rules.len(), 1);
    assert_eq!(rules[0].group, "Imported");

    // Duplicates are skipped, not doubled.
    let rules = commands::add_suggested_rules(
        t.handle(),
        vec![SuggestionInput { pattern: "*.dev.test".into(), ip: "172.30.0.5".into() }],
    )
    .unwrap();
    assert_eq!(rules.len(), 1);
}

#[test]
fn resolver_commands_share_one_mock_backend() {
    let t = TestApp::new();
    t.add("*.zones.test", "172.30.0.25");

    let overview = tauri::async_runtime::block_on(commands::resolver_overview(t.handle()));
    assert_eq!(overview.backend, "mock");
    assert!(matches!(overview.access, localdns_platform::AccessState::Granted));
    assert_eq!(overview.plan.installs, vec!["zones.test".to_string()]);
    assert!(!overview.instructions.steps.is_empty());

    let outcome = tauri::async_runtime::block_on(commands::resolver_sync(t.handle()));
    assert!(matches!(outcome, localdns_platform::SyncOutcome::Applied { .. }));
    // Same in-process backend: now up to date, and the status table agrees.
    let outcome = tauri::async_runtime::block_on(commands::resolver_sync(t.handle()));
    assert!(matches!(outcome, localdns_platform::SyncOutcome::UpToDate { .. }));
    let overview = tauri::async_runtime::block_on(commands::resolver_overview(t.handle()));
    assert!(overview
        .statuses
        .iter()
        .all(|s| s.state == localdns_platform::ZoneState::Registered));

    let outcome = tauri::async_runtime::block_on(commands::resolver_unregister_all(t.handle()));
    assert!(matches!(outcome, localdns_platform::SyncOutcome::Applied { .. }));
    let outcome = tauri::async_runtime::block_on(commands::resolver_unregister_all(t.handle()));
    assert!(matches!(outcome, localdns_platform::SyncOutcome::UpToDate { .. }));
}

#[test]
fn state_derivations_and_traylike_paths() {
    let t = TestApp::new();

    // Mock backend pins nothing: registration follows the settings port.
    let endpoint = t.state().registration_endpoint();
    assert_eq!(endpoint.port, 15353);
    assert_eq!(t.state().server_addrs().len(), 1);

    // No tray and no window on the mock runtime: these must be safe no-ops —
    // the second update exercises the rebuild diff-guard.
    tray::update_status(&t.handle());
    tray::update_status(&t.handle());
    server_control::emit_server_status(&t.handle());
    crate::state::publish_query_log(&t.handle());
    crate::show_window(&t.handle());

    // show_main_window command goes through the same guard.
    commands::show_main_window(t.handle());
}

