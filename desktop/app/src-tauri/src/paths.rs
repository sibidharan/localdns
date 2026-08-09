//! Per-OS locations for rules.json and settings.json.
//!
//! Windows: %APPDATA%\LocalDNS\        Linux: ~/.config/localdns/
//! macOS (dev host): ~/Library/Application Support/LocalDNS/ — the same JSON
//! schema as the sandboxed Mac app, so users can copy rules.json across.

use std::path::PathBuf;

pub fn config_dir() -> PathBuf {
    let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
    if cfg!(target_os = "linux") {
        base.join("localdns")
    } else {
        base.join("LocalDNS")
    }
}

pub fn rules_path() -> PathBuf {
    config_dir().join("rules.json")
}

pub fn settings_path() -> PathBuf {
    config_dir().join("settings.json")
}
