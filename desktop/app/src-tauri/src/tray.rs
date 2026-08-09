//! Tray icon + menu — the MenuBarExtra equivalent: status line, master
//! server switch, last 5 queries, Open, Quit. Tauri trays host native menus
//! (not webviews), so the menu is rebuilt from state on each debounced update.

use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

use localdns_core::{Outcome, QueryLogEntry};

use crate::server_control;
use crate::state::AppState;

pub const TRAY_ID: &str = "localdns-tray";

pub fn create<R: tauri::Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    let menu = build_menu(app, &[])?;
    let mut builder = TrayIconBuilder::with_id(TRAY_ID)
        .menu(&menu)
        .show_menu_on_left_click(true)
        .tooltip("LocalDNS")
        .on_menu_event(|app, event| on_menu_event(app, event.id.as_ref()));
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder.build(app)?;
    Ok(())
}

fn on_menu_event<R: tauri::Runtime>(app: &AppHandle<R>, id: &str) {
    match id {
        "toggle-server" => {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                let enabled = {
                    let state = app.state::<AppState>();
                    let mut settings = state.settings.lock().unwrap();
                    settings.server_enabled = !settings.server_enabled;
                    let _ = settings.save(&crate::paths::settings_path());
                    settings.clone()
                };
                server_control::apply_server_state(&app).await;
                use tauri::Emitter;
                let _ = app.emit("settings-changed", &enabled);
            });
        }
        "open" => crate::show_window(app),
        "quit" => {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                crate::shutdown_and_exit(app).await;
            });
        }
        _ => {}
    }
}

fn status_line(status: &server_control::ServerStatus) -> String {
    if let Some(error) = &status.error {
        format!("Error — {error}")
    } else if status.running {
        format!("Live on 127.0.0.1:{}", status.port)
    } else {
        "Stopped".into()
    }
}

fn describe_entry(entry: &QueryLogEntry) -> String {
    let outcome = match &entry.outcome {
        Outcome::Answered(address) => address.clone(),
        Outcome::NoData => "no data".into(),
        Outcome::Nxdomain => "NXDOMAIN".into(),
    };
    format!("{} → {}", entry.name, outcome)
}

fn build_menu<R: tauri::Runtime>(
    app: &AppHandle<R>,
    recent: &[QueryLogEntry],
) -> tauri::Result<Menu<R>> {
    let status = server_control::current_status(app);
    let status_item = MenuItem::with_id(
        app,
        "status",
        status_line(&status),
        false,
        None::<&str>,
    )?;
    let toggle = CheckMenuItem::with_id(
        app,
        "toggle-server",
        "DNS Server",
        true,
        status.enabled,
        None::<&str>,
    )?;
    let open = MenuItem::with_id(app, "open", "Open LocalDNS", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit LocalDNS", true, None::<&str>)?;

    let menu = Menu::new(app)?;
    menu.append(&status_item)?;
    menu.append(&toggle)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    if recent.is_empty() {
        menu.append(&MenuItem::with_id(
            app,
            "no-queries",
            "No queries yet",
            false,
            None::<&str>,
        )?)?;
    } else {
        for (index, entry) in recent.iter().take(5).enumerate() {
            menu.append(&MenuItem::with_id(
                app,
                format!("q{index}"),
                describe_entry(entry),
                false,
                None::<&str>,
            )?)?;
        }
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&open)?;
    menu.append(&quit)?;
    Ok(menu)
}

fn refresh<R: tauri::Runtime>(app: &AppHandle<R>, recent: &[QueryLogEntry]) {
    // Energy: rebuilding a GTK/appindicator menu means D-Bus churn; skip when
    // nothing the tray shows has actually changed (status line + top-5 ids).
    static LAST: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());
    let status = server_control::current_status(app);
    let mut key = status_line(&status);
    key.push('|');
    key.push_str(&status.enabled.to_string());
    for entry in recent.iter().take(5) {
        key.push('|');
        key.push_str(&entry.id.to_string());
    }
    {
        let mut last = LAST.lock().unwrap();
        if *last == key {
            return;
        }
        *last = key;
    }

    // Tray menus are main-thread-only on GTK (and safest everywhere); this is
    // called from async tasks (debounced log publisher, server lifecycle), so
    // marshal — calling GTK from a worker freezes the whole main loop.
    let handle = app.clone();
    let recent = recent.to_vec();
    let _ = app.run_on_main_thread(move || {
        let Some(tray) = handle.tray_by_id(TRAY_ID) else {
            return;
        };
        if let Ok(menu) = build_menu(&handle, &recent) {
            let _ = tray.set_menu(Some(menu));
        }
        let status = server_control::current_status(&handle);
        let _ = tray.set_tooltip(Some(format!("LocalDNS — {}", status_line(&status))));
    });
}

/// Called on server state changes.
pub fn update_status<R: tauri::Runtime>(app: &AppHandle<R>) {
    let entries = app.state::<AppState>().query_log.entries();
    refresh(app, &entries);
}

/// Called from the debounced query-log publisher.
pub fn update_recent_queries<R: tauri::Runtime>(app: &AppHandle<R>, entries: &[QueryLogEntry]) {
    refresh(app, entries);
}

#[cfg(test)]
mod tests {
    use super::*;
    use localdns_core::QueryLogEntry;

    fn status(running: bool, error: Option<&str>) -> server_control::ServerStatus {
        server_control::ServerStatus {
            running,
            enabled: true,
            error: error.map(String::from),
            port: 15353,
            endpoints: vec!["127.0.0.1:15353".into()],
            backend: "mock",
            endpoint_pinned: false,
        }
    }

    #[test]
    fn status_line_variants() {
        assert_eq!(status_line(&status(true, None)), "Live on 127.0.0.1:15353");
        assert_eq!(status_line(&status(false, None)), "Stopped");
        assert!(status_line(&status(false, Some("port busy"))).contains("port busy"));
    }

    #[test]
    fn describe_entry_variants() {
        let mut entry = QueryLogEntry::new("api.dev.test", "A", Outcome::Answered("172.30.0.5".into()));
        assert_eq!(describe_entry(&entry), "api.dev.test → 172.30.0.5");
        entry.outcome = Outcome::NoData;
        assert!(describe_entry(&entry).ends_with("no data"));
        entry.outcome = Outcome::Nxdomain;
        assert!(describe_entry(&entry).ends_with("NXDOMAIN"));
    }
}
