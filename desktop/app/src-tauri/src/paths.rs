//! Delegates to the shared locations in localdns-core so the CLI and the
//! app always agree on where rules.json/settings.json live.

pub use localdns_core::paths::{config_dir, rules_path, settings_path};
