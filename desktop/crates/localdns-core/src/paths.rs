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

#[cfg(test)]
mod tests {
    use super::*;

    // One test covers both branches sequentially: env mutation is
    // process-global, so splitting these would race under the parallel runner.
    #[test]
    fn config_dir_override_and_fallback() {
        std::env::set_var("LOCALDNS_CONFIG_DIR", "/custom/spot");
        assert_eq!(config_dir(), PathBuf::from("/custom/spot"));
        assert_eq!(rules_path(), PathBuf::from("/custom/spot/rules.json"));
        assert_eq!(settings_path(), PathBuf::from("/custom/spot/settings.json"));

        std::env::remove_var("LOCALDNS_CONFIG_DIR");
        let dir = config_dir();
        let leaf = if cfg!(target_os = "linux") { "localdns" } else { "LocalDNS" };
        assert_eq!(dir.file_name().unwrap(), leaf);
        assert!(dir.parent().is_some(), "fallback should sit inside the OS config dir");
    }
}
