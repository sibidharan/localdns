//! LocalDNS desktop app shell (Windows/Linux; runs on macOS with the mock
//! backend for development).

mod commands;
mod paths;
mod server_control;
mod settings;
mod state;
mod tray;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tauri::{AppHandle, Emitter, Manager, WindowEvent};
use tauri_plugin_autostart::MacosLauncher;

use localdns_platform::AccessState;
use state::AppState;

/// Set once the main webview reports a finished page load; the watchdog
/// re-navigates natively until it flips (recovers lost cold-start loads).
static PAGE_LOADED: AtomicBool = AtomicBool::new(false);

/// Shows and focuses the main window, pushing a fresh query-log snapshot to it
/// (hidden windows are skipped by the debounced publisher).
pub(crate) fn show_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        let entries = app.state::<AppState>().query_log.entries();
        let _ = app.emit("query-log", &entries);
    }
}

/// Quit path: honor unregister-on-quit, stop the server cleanly, exit.
pub(crate) async fn shutdown_and_exit(app: AppHandle) {
    let state = app.state::<AppState>();
    let unregister = state.settings.lock().unwrap().unregister_on_quit;
    if unregister && matches!(state.backend.access(), AccessState::Granted) {
        let backend = Arc::clone(&state.backend);
        let _ = tauri::async_runtime::spawn_blocking(move || backend.unregister_all()).await;
    }
    let mut guard = state.server.lock().await;
    if let Some(handle) = guard.take() {
        handle.shutdown().await;
    }
    drop(guard);
    app.exit(0);
}

pub fn run() {
    // Create the tokio runtime up front and hand it to tauri, so no lazy
    // runtime initialization can ever happen inside a webview callback.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    tauri::async_runtime::set(runtime.handle().clone());
    std::mem::forget(runtime); // app-lifetime

    // WebKitGTK's GPU compositing renders a black window under virtualized
    // GPUs (Parallels/VMware/QEMU). Fall back to software compositing there;
    // bare metal keeps the fast path. Users can still override explicitly.
    #[cfg(target_os = "linux")]
    {
        let in_vm = std::process::Command::new("systemd-detect-virt")
            .arg("--vm")
            .output()
            .map(|out| out.status.success())
            .unwrap_or(false);
        if in_vm && std::env::var_os("WEBKIT_DISABLE_COMPOSITING_MODE").is_none() {
            std::env::set_var("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
        }
    }

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            show_window(app);
        }))
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec!["--hidden"]),
        ))
        .plugin(tauri_plugin_clipboard_manager::init())
        .setup(|app| {
            app.manage(AppState::load());

            let tray_ok = tray::create(app.handle()).is_ok();
            app.state::<AppState>()
                .tray_available
                .store(tray_ok, Ordering::Release);

            // Autostart launches with --hidden: live in the tray until opened.
            if std::env::args().any(|arg| arg == "--hidden") {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
            }

            // Field diagnosis: LOCALDNS_DEVTOOLS=1 pops the web inspector.
            if std::env::var_os("LOCALDNS_DEVTOOLS").is_some() {
                if let Some(window) = app.get_webview_window("main") {
                    window.open_devtools();
                }
            }

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                server_control::apply_server_state(&handle).await;
            });

            // Page-load watchdog: if the main document hasn't finished loading
            // shortly after launch (cold-start races), force a NATIVE
            // re-navigation — eval() is useless here because wry queues JS
            // until the load completes.
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                for _ in 0..4u32 {
                    tokio::time::sleep(std::time::Duration::from_millis(2000)).await;
                    if PAGE_LOADED.load(Ordering::Acquire) {
                        return;
                    }
                    let Some(window) = handle.get_webview_window("main") else {
                        continue;
                    };
                    let target = if cfg!(windows) {
                        "https://tauri.localhost/"
                    } else {
                        "tauri://localhost/"
                    };
                    if let Ok(url) = target.parse() {
                        let _ = window.navigate(url);
                    }
                }
            });
            Ok(())
        })
        .on_page_load(|window, payload| {
            if window.label() == "main"
                && matches!(payload.event(), tauri::webview::PageLoadEvent::Finished)
            {
                PAGE_LOADED.store(true, Ordering::Release);
            }
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let app = window.app_handle();
                if app.state::<AppState>().tray_available.load(Ordering::Acquire) {
                    // LSUIElement equivalent: close hides to the tray.
                    let _ = window.hide();
                } else {
                    // No tray (some Linux DEs): closing must really quit, or
                    // the app becomes unreachable.
                    let app = app.clone();
                    tauri::async_runtime::spawn(async move {
                        shutdown_and_exit(app).await;
                    });
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_bootstrap,
            commands::add_rule,
            commands::update_rule,
            commands::delete_rule,
            commands::set_rule_enabled,
            commands::set_group_enabled,
            commands::validate_pattern,
            commands::preview_match,
            commands::get_settings,
            commands::set_settings,
            commands::get_status,
            commands::run_self_test,
            commands::get_query_log,
            commands::clear_query_log,
            commands::scan_hosts,
            commands::add_suggested_rules,
            commands::resolver_overview,
            commands::resolver_sync,
            commands::resolver_unregister_all,
            commands::show_main_window,
            commands::quit_app,
        ])
        .run(tauri::generate_context!())
        .expect("error while running LocalDNS");
}
