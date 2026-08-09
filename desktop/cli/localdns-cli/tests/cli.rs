//! End-to-end tests against the real `localdns` binary with an isolated
//! config dir (LOCALDNS_CONFIG_DIR) — add/list/remove round-trip, validation
//! failures, and `serve` answering real queries + hot-reloading rules.json.

use std::process::{Child, Command, Stdio};
use std::time::Duration;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_localdns"))
}

struct TempConfig {
    dir: tempfile::TempDir,
}

impl TempConfig {
    fn new() -> Self {
        Self { dir: tempfile::tempdir().unwrap() }
    }
    fn env(&self, cmd: &mut Command) {
        cmd.env("LOCALDNS_CONFIG_DIR", self.dir.path());
        // Deterministic on every OS: never touch the machine's real resolver
        // or hosts file from a test.
        cmd.env("LOCALDNS_BACKEND", "mock");
        cmd.env("LOCALDNS_HOSTS_PATH", self.dir.path().join("hosts"));
    }
    fn write_hosts(&self, content: &str) {
        std::fs::write(self.dir.path().join("hosts"), content).unwrap();
    }
    fn write_settings(&self, port: u16) {
        std::fs::write(
            self.dir.path().join("settings.json"),
            format!(r#"{{"port":{port},"serverEnabled":true,"unregisterOnQuit":false,"launchAtLogin":false}}"#),
        )
        .unwrap();
    }
    fn run(&self, args: &[&str]) -> (bool, String, String) {
        let mut cmd = bin();
        self.env(&mut cmd);
        let out = cmd.args(args).output().unwrap();
        (
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).into_owned(),
            String::from_utf8_lossy(&out.stderr).into_owned(),
        )
    }
}

#[test]
fn add_list_remove_round_trip() {
    let config = TempConfig::new();

    let (ok, stdout, _) = config.run(&["add", "*.cli.test", "172.30.0.7"]);
    assert!(ok, "add failed");
    assert!(stdout.contains("added *.cli.test"));

    let (ok, stdout, _) = config.run(&["list", "--json"]);
    assert!(ok);
    let rules: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(rules.as_array().unwrap().len(), 1);
    assert_eq!(rules[0]["pattern"], "*.cli.test");
    assert_eq!(rules[0]["ipv4"], "172.30.0.7");

    let (ok, stdout, _) = config.run(&["remove", "*.cli.test"]);
    assert!(ok);
    assert!(stdout.contains("removed 1"));

    let (_, stdout, _) = config.run(&["list", "--json"]);
    assert_eq!(stdout.trim(), "[]");
}

#[test]
fn add_rejects_bad_input() {
    let config = TempConfig::new();
    let (ok, _, stderr) = config.run(&["add", "*.co.uk", "10.0.0.1"]);
    assert!(!ok, "public-suffix wildcard must be rejected");
    assert!(stderr.contains("public suffix"));

    let (ok, _, stderr) = config.run(&["add", "*.ok.test", "999.1.2.3"]);
    assert!(!ok);
    assert!(stderr.contains("invalid IPv4"));

    let (ok, _, _) = config.run(&["add", "*.v6.test", "fd00::7"]);
    assert!(ok, "IPv6 add must pass");
}

#[test]
fn serve_answers_and_hot_reloads() {
    let config = TempConfig::new();
    // Seed a rule and settings with a throwaway port.
    let port = 26353u16;
    std::fs::write(
        config.dir.path().join("settings.json"),
        format!(r#"{{"port":{port},"serverEnabled":true,"unregisterOnQuit":false,"launchAtLogin":false}}"#),
    )
    .unwrap();
    let (ok, _, _) = config.run(&["add", "*.serve.test", "172.30.0.9"]);
    assert!(ok);

    // Capture serve's output so a CI failure explains itself.
    let log_path = config.dir.path().join("serve.log");
    let log_file = std::fs::File::create(&log_path).unwrap();
    let mut serve_cmd = bin();
    config.env(&mut serve_cmd);
    let mut child: Child = serve_cmd
        .args(["serve"])
        .stdout(Stdio::from(log_file.try_clone().unwrap()))
        .stderr(Stdio::from(log_file))
        .spawn()
        .unwrap();
    let serve_log = || std::fs::read_to_string(&log_path).unwrap_or_default();

    // First wait for the bind line, then for real answers via self-test.
    let mut bound = false;
    for _ in 0..60 {
        std::thread::sleep(Duration::from_millis(250));
        if serve_log().contains("serving on") {
            bound = true;
            break;
        }
        if let Ok(Some(status)) = child.try_wait() {
            panic!("serve exited early ({status}):\n{}", serve_log());
        }
    }
    if !bound {
        let _ = child.kill();
        panic!("serve never bound:\n{}", serve_log());
    }
    let mut up = false;
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(250));
        let (ok, _, _) = config.run(&["self-test"]);
        if ok {
            up = true;
            break;
        }
    }
    if !up {
        let _ = child.kill();
        panic!("serve bound but never answered:\n{}", serve_log());
    }

    // Hot reload: swap the rule set from a second process; the watcher (2s
    // poll) must serve the NEW rule without restarting `serve`. self-test
    // probes the first enabled rule, so replacing the old rule with a new one
    // makes a passing self-test proof of the reload.
    let (ok, _, _) = config.run(&["add", "*.hot.test", "172.30.0.10"]);
    assert!(ok);
    let (ok, _, _) = config.run(&["remove", "*.serve.test"]);
    assert!(ok);
    let mut reloaded = false;
    for _ in 0..12 {
        std::thread::sleep(Duration::from_millis(500));
        let (ok_probe, _, _) = config.run(&["self-test"]);
        if ok_probe {
            reloaded = true;
            break;
        }
    }
    assert!(reloaded, "hot reload did not serve the new rule set");

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn import_hosts_suggests_then_applies() {
    let config = TempConfig::new();
    config.write_hosts(
        "127.0.0.1 localhost\n\
         172.30.0.5 api.dev.test\n\
         172.30.0.5 web.dev.test\n\
         172.30.0.5 db.dev.test\n",
    );

    let (ok, stdout, _) = config.run(&["import-hosts"]);
    assert!(ok);
    assert!(stdout.contains("+ *.dev.test"), "expected a + suggestion:\n{stdout}");
    assert!(stdout.contains("--apply"), "dry run must hint at --apply:\n{stdout}");

    let (ok, stdout, _) = config.run(&["import-hosts", "--apply"]);
    assert!(ok);
    assert!(stdout.contains("added 1 rule(s)"), "{stdout}");

    let (_, stdout, _) = config.run(&["list", "--json"]);
    let rules: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(rules[0]["pattern"], "*.dev.test");
    assert_eq!(rules[0]["group"], "Imported");

    // Already covered now: "=" marker, no apply hint.
    let (ok, stdout, _) = config.run(&["import-hosts"]);
    assert!(ok);
    assert!(stdout.contains("= *.dev.test"), "{stdout}");
    assert!(!stdout.contains("--apply"), "{stdout}");
}

#[test]
fn import_hosts_without_candidates() {
    let config = TempConfig::new();
    config.write_hosts("127.0.0.1 localhost\n255.255.255.255 broadcasthost\n");
    let (ok, stdout, _) = config.run(&["import-hosts"]);
    assert!(ok);
    assert!(stdout.contains("no wildcard candidates"), "{stdout}");
}

#[test]
fn sync_status_unregister_via_mock_backend() {
    let config = TempConfig::new();
    // Dedicated dead port: the reachability probe must not find a real server.
    config.write_settings(26155);
    let (ok, _, _) = config.run(&["add", "*.mock.test", "172.30.0.11"]);
    assert!(ok);

    let (ok, stdout, _) = config.run(&["sync"]);
    assert!(ok);
    assert!(stdout.contains("registrations applied"), "{stdout}");

    let (ok, stdout, _) = config.run(&["status"]);
    assert!(ok);
    assert!(stdout.contains("backend : mock"), "{stdout}");
    assert!(stdout.contains("access  : granted"), "{stdout}");
    assert!(stdout.contains("NOT answering"), "{stdout}");
    // The mock is per-process, so this fresh process starts unregistered.
    assert!(stdout.contains("not registered"), "{stdout}");

    let (ok, stdout, _) = config.run(&["status", "--json"]);
    assert!(ok);
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(v["backend"], "mock");
    assert_eq!(v["access"], true);
    assert_eq!(v["serving"], false);
    assert_eq!(v["port"], 26155);
    assert_eq!(v["zones"].as_array().unwrap().len(), 1);

    let (ok, stdout, _) = config.run(&["unregister"]);
    assert!(ok);
    assert!(stdout.contains("already up to date"), "{stdout}");
}

#[test]
fn status_without_rules_has_nothing_to_probe() {
    let config = TempConfig::new();
    config.write_settings(26157);
    let (ok, stdout, _) = config.run(&["status"]);
    assert!(ok);
    assert!(stdout.contains("no enabled rules to probe"), "{stdout}");
    assert!(stdout.contains("zones   : none"), "{stdout}");
}

#[test]
fn list_plain_formats_and_ttl_clamp() {
    let config = TempConfig::new();
    let (ok, stdout, _) = config.run(&["list"]);
    assert!(ok);
    assert!(stdout.contains("no rules"), "{stdout}");

    let (ok, _, _) = config.run(&["add", "*.fmt.test", "172.30.0.12", "--ttl", "0", "--group", "Work"]);
    assert!(ok, "ttl 0 must be accepted and clamped");
    let (ok, _, _) = config.run(&["add", "*.six.test", "fd00::9"]);
    assert!(ok);

    let (ok, stdout, _) = config.run(&["list"]);
    assert!(ok);
    assert!(stdout.contains("on  *.fmt.test"), "{stdout}");
    assert!(stdout.contains("172.30.0.12"), "{stdout}");
    assert!(stdout.contains("fd00::9"), "{stdout}");
    assert!(stdout.contains("group=Work"), "{stdout}");

    let (_, stdout, _) = config.run(&["list", "--json"]);
    let rules: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(rules[0]["ttl"], 1, "ttl 0 clamps to 1");
}

#[test]
fn error_paths_speak_up() {
    let config = TempConfig::new();
    config.write_settings(26159);

    let (ok, _, stderr) = config.run(&["self-test"]);
    assert!(!ok);
    assert!(stderr.contains("add an enabled rule"), "{stderr}");

    let (ok, _, stderr) = config.run(&["remove", "*.ghost.test"]);
    assert!(!ok);
    assert!(stderr.contains("no rule matches"), "{stderr}");

    let (ok, _, stderr) = config.run(&["add", "*.bad6.test", "zz::::1"]);
    assert!(!ok);
    assert!(stderr.contains("invalid IPv6"), "{stderr}");

    let (ok, _, stderr) = config.run(&["add", "*.myapp.local", "10.0.0.1"]);
    // .local subdomains warn (mDNS territory) but are not blocked.
    assert!(ok);
    assert!(stderr.contains("mDNS"), "{stderr}");

    let (ok, _, _) = config.run(&["add", "*.dead.test", "172.30.0.13"]);
    assert!(ok);
    let (ok, _, stderr) = config.run(&["self-test"]);
    assert!(!ok, "no server on the dead port");
    assert!(stderr.contains("did not answer"), "{stderr}");
}

/// SIGTERM must take the graceful path: stop serving and honor
/// --unregister-on-exit. Windows has no SIGTERM equivalent we can send
/// from a test; the ctrl_c path is the same code.
#[cfg(unix)]
#[test]
fn serve_unregisters_on_sigterm() {
    let config = TempConfig::new();
    config.write_settings(26355);
    let (ok, _, _) = config.run(&["add", "*.term.test", "172.30.0.14"]);
    assert!(ok);

    let log_path = config.dir.path().join("serve.log");
    let log_file = std::fs::File::create(&log_path).unwrap();
    let mut serve_cmd = bin();
    config.env(&mut serve_cmd);
    let mut child: Child = serve_cmd
        .args(["serve", "--unregister-on-exit"])
        .stdout(Stdio::from(log_file.try_clone().unwrap()))
        .stderr(Stdio::from(log_file))
        .spawn()
        .unwrap();
    let serve_log = || std::fs::read_to_string(&log_path).unwrap_or_default();

    let mut bound = false;
    for _ in 0..60 {
        std::thread::sleep(Duration::from_millis(250));
        if serve_log().contains("serving on") {
            bound = true;
            break;
        }
    }
    assert!(bound, "serve never bound:\n{}", serve_log());

    let term = Command::new("kill").arg(child.id().to_string()).status().unwrap();
    assert!(term.success());
    let mut exited = false;
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(250));
        if let Ok(Some(status)) = child.try_wait() {
            assert!(status.success(), "clean exit expected:\n{}", serve_log());
            exited = true;
            break;
        }
    }
    if !exited {
        let _ = child.kill();
        panic!("serve ignored SIGTERM:\n{}", serve_log());
    }
    assert!(
        serve_log().contains("registrations removed"),
        "unregister-on-exit must run:\n{}",
        serve_log()
    );
}
