//! App settings — the port/flags quartet the macOS app keeps in UserDefaults.

use std::io::Write;
use std::path::Path;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub port: u16,
    pub server_enabled: bool,
    pub unregister_on_quit: bool,
    pub launch_at_login: bool,
    /// Daily update check against GitHub Releases (one unauthenticated GET;
    /// no other network calls — see README's no-telemetry promise).
    pub check_updates: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            port: 15353,
            server_enabled: true,
            unregister_on_quit: false,
            launch_at_login: false,
            check_updates: true,
        }
    }
}

impl Settings {
    /// Missing or corrupt file → defaults (never fails the app).
    pub fn load(path: &Path) -> Self {
        std::fs::read(path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> Result<(), std::io::Error> {
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        std::fs::create_dir_all(parent)?;
        let json = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        let mut tmp = tempfile::NamedTempFile::new_in(parent)?;
        tmp.write_all(json.as_bytes())?;
        tmp.persist(path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_macos_userdefaults() {
        let settings = Settings::default();
        assert_eq!(settings.port, 15353);
        assert!(settings.server_enabled);
        assert!(!settings.unregister_on_quit);
        assert!(!settings.launch_at_login);
    }

    #[test]
    fn save_load_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let settings = Settings {
            port: 5399,
            server_enabled: false,
            unregister_on_quit: true,
            launch_at_login: true,
            check_updates: false,
        };
        settings.save(&path).unwrap();
        assert_eq!(Settings::load(&path), settings);
    }

    #[test]
    fn missing_or_corrupt_file_yields_defaults() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(Settings::load(&dir.path().join("nope.json")), Settings::default());
        let bad = dir.path().join("bad.json");
        std::fs::write(&bad, b"{not json").unwrap();
        assert_eq!(Settings::load(&bad), Settings::default());
    }

    #[test]
    fn json_uses_camel_case_keys() {
        let json = serde_json::to_string(&Settings::default()).unwrap();
        assert!(json.contains("serverEnabled"));
        assert!(json.contains("unregisterOnQuit"));
        assert!(json.contains("launchAtLogin"));
    }
}
