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

pub fn create(app: &AppHandle) -> tauri::Result<()> {
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

fn on_menu_event(app: &AppHandle, id: &str) {
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

fn build_menu(
    app: &AppHandle,
    recent: &[QueryLogEntry],
) -> tauri::Result<Menu<tauri::Wry>> {
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

fn refresh(app: &AppHandle, recent: &[QueryLogEntry]) {
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
pub fn update_status(app: &AppHandle) {
    let entries = app.state::<AppState>().query_log.entries();
    refresh(app, &entries);
}

/// Called from the debounced query-log publisher.
pub fn update_recent_queries(app: &AppHandle, entries: &[QueryLogEntry]) {
    refresh(app, entries);
}
