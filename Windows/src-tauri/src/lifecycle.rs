use crate::{diagnostics, AppState};
use serde_json::json;
use std::sync::{atomic::Ordering, Arc};
use tauri::{Manager, WebviewWindow, WebviewWindowBuilder};

/// Recreate a lost panel on a worker thread; WebView2 creation can deadlock in an event handler.
pub fn with_panel(app: &tauri::AppHandle, ready: impl FnOnce(WebviewWindow) + Send + 'static) {
    if let Some(window) = app.get_webview_window("main") {
        ready(window);
        return;
    }
    let Some(state) = app.try_state::<Arc<AppState>>().map(|s| s.inner().clone()) else {
        return;
    };
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let guard = state.panel_creation.lock().await;
        if state.exiting.load(Ordering::Acquire) {
            return;
        }
        let window = if let Some(window) = app.get_webview_window("main") {
            window
        } else {
            let build_app = app.clone();
            let built = tauri::async_runtime::spawn_blocking(move || {
                let config = build_app
                    .config()
                    .app
                    .windows
                    .iter()
                    .find(|w| w.label == "main")
                    .ok_or_else(|| "main window configuration is missing".to_string())?;
                WebviewWindowBuilder::from_config(&build_app, config)
                    .and_then(|builder| builder.visible(false).build())
                    .map_err(|e| e.to_string())
            })
            .await;
            match built {
                Ok(Ok(window)) => {
                    diagnostics::record("panel-recreated", json!({}));
                    window
                }
                Ok(Err(error)) => {
                    diagnostics::record("panel-recreation-failed", json!({"error":error.chars().take(1024).collect::<String>()}));
                    return;
                }
                Err(error) => {
                    diagnostics::record("panel-recreation-worker-failed", json!({"error":error.to_string().chars().take(1024).collect::<String>()}));
                    return;
                }
            }
        };
        drop(guard);
        let _ = app.run_on_main_thread(move || {
            if !state.exiting.load(Ordering::Acquire) {
                ready(window);
            }
        });
    });
}

pub fn quit(app: &tauri::AppHandle) {
    if let Some(state) = app.try_state::<Arc<AppState>>() {
        state.exiting.store(true, Ordering::Release);
        // Do not leave the Explorer child surface or its message-loop thread
        // alive while Tauri is waiting for WebView2 to close.
        state.taskbar.stop();
    }
    diagnostics::record("quit-selected", json!({}));
    app.exit(0);
    // Tray callbacks run on Tauri's event loop. A blocked WebView2 teardown or
    // a stuck native child window can otherwise keep a resident process alive
    // after app.exit has returned. The normal event-loop exit wins; this is a
    // bounded last resort for the explicit user-selected Quit action only.
    std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_secs(2));
        diagnostics::record("quit-timeout", json!({}));
        std::process::exit(0);
    });
}

pub fn recover_panel(app: &tauri::AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        // Let the destroyed-window event finish removing the old runtime handle.
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        with_panel(&app, |_| {});
    });
}
