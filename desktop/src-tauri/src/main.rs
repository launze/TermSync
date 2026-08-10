// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod api_client;
mod commands;
mod lan_direct;
mod pty_manager;
mod wss_client;

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use tauri::Manager;

fn debug_log_path() -> PathBuf {
    std::env::temp_dir().join("termsync-desktop-debug.log")
}

pub(crate) fn log_debug(message: &str) {
    eprintln!("[TermSync] {message}");
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(debug_log_path())
    {
        let _ = writeln!(file, "[TermSync] {message}");
    }
}

fn main() {
    log_debug("main:start");
    eprintln!("[TermSync] debug-log-file={}", debug_log_path().display());
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .on_page_load(|window, payload| {
            log_debug(&format!(
                "page-load window={} url={}",
                window.label(),
                payload.url()
            ));
        })
        .invoke_handler(tauri::generate_handler![
            commands::connect_server,
            commands::disconnect_server,
            commands::create_session,
            commands::close_session,
            commands::send_input,
            commands::resize_terminal_cmd,
            commands::update_session_meta,
            commands::list_local_sessions,
            commands::get_server_status,
            commands::get_default_device_name,
            commands::register_device,
            commands::generate_pairing_code,
            commands::complete_pairing,
            commands::start_lan_direct_server,
            commands::stop_lan_direct_server,
            commands::get_lan_direct_status,
            commands::generate_lan_pairing_code,
            commands::clear_lan_paired_receivers,
            commands::unbind_lan_receiver,
            commands::publish_layout_snapshot,
            commands::publish_layout_patch,
            commands::publish_pane_meta,
            commands::subscribe_workspace,
            commands::subscribe_screen,
            commands::unsubscribe_screen,
            commands::publish_screen_delta,
            commands::publish_screen_snapshot,
            commands::publish_screen_history,
            commands::request_screen_resync,
            commands::ack_screen,
            commands::send_remote_input_v3,
            commands::request_layout_action,
            commands::check_desktop_update,
            commands::download_desktop_update,
            commands::install_desktop_update,
            commands::debug_log,
            commands::write_clipboard_text,
            commands::read_clipboard_text,
            commands::save_clipboard_image_to_screenshots,
            commands::window_minimize,
            commands::window_toggle_maximize,
            commands::window_is_maximized,
            commands::window_start_dragging,
            commands::window_close,
            commands::window_destroy,
            commands::proxy_ai_request,
            commands::proxy_default_ai_request,
        ])
        .setup(|app| {
            // Initialize app state
            log_debug("setup:start");
            let lan_direct = lan_direct::LanDirectState::default();
            app.manage(wss_client::WssClientState::new(lan_direct.clone()));
            app.manage(lan_direct);
            app.manage(pty_manager::PtyManager::default());
            if let Some(window) = app.get_webview_window("main") {
                log_debug(&format!("setup:window-ready label={}", window.label()));
                #[cfg(target_os = "windows")]
                {
                    if let Err(err) = window.set_decorations(false) {
                        log_debug(&format!("setup:window-undecorated-failed error={}", err));
                    } else {
                        log_debug("setup:window-undecorated");
                    }
                }
                if let Err(err) = window.maximize() {
                    log_debug(&format!("setup:window-maximize-failed error={}", err));
                } else {
                    log_debug("setup:window-maximized");
                }
            } else {
                log_debug("setup:window-missing");
            }
            Ok(())
        });

    #[cfg(not(debug_assertions))]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
        log_debug("single-instance:secondary-launch");
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.unminimize();
            let _ = window.show();
            let _ = window.set_focus();
        }
    }));

    #[cfg(debug_assertions)]
    log_debug("single-instance:disabled-in-debug");

    builder
        .run(tauri::generate_context!())
        .expect("error while running TermSync");
}
