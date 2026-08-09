//! Config locations shared by the desktop app and the CLI — both read and
//! write the SAME rules.json/settings.json so a headless `localdns add` is
//! immediately visible in the GUI and vice versa.
//!
//! Windows: %APPDATA%\LocalDNS\        Linux: ~/.config/localdns/
//! macOS: ~/Library/Application Support/LocalDNS/
//! Override for tests/fleet setups: LOCALDNS_CONFIG_DIR.

use std::path::PathBuf;

pub fn config_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("LOCALDNS_CONFIG_DIR") {
        return PathBuf::from(dir);
    }
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
