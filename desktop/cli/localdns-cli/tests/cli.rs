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
