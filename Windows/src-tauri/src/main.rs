#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod process;
mod quota;
mod settings;
mod sync;
mod taskbar;
#[cfg(windows)]
mod taskbar_render;

use serde::Serialize;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager,
};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_opener::OpenerExt;
use tokenbar_helper::{ActivitySnapshot, RequestDetail, RequestSummary};
use tokio::sync::{Mutex, Notify};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Dashboard {
    settings: settings::Settings,
    snapshot: Option<ActivitySnapshot>,
    quotas: quota::Quotas,
    refreshing: bool,
    error: Option<String>,
    memory_status: String,
    remote_snapshots: Vec<sync::Remote>,
    sync_status: String,
}
struct AppState {
    dashboard: Mutex<Dashboard>,
    refresh_lock: Mutex<()>,
    timer_changed: Notify,
    receiver: Mutex<Option<tokio::process::Child>>,
    pinned: AtomicBool,
    taskbar: taskbar::Controller,
    panel_platform: std::sync::Mutex<String>,
    dir: PathBuf,
    helper: PathBuf,
}

fn state(app: &tauri::AppHandle) -> Arc<AppState> {
    app.state::<Arc<AppState>>().inner().clone()
}
fn show(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
        let _ = app.emit("panel-opened", ());
    }
}
async fn publish(app: &tauri::AppHandle, state: &AppState) {
    let dashboard = state.dashboard.lock().await.clone();
    state.taskbar.update(&dashboard);
    if let Some(tray) = app.tray_by_id("tokenbar") {
        let mut lines = vec!["TokenBar".to_string()];
        if let Some(snapshot) = &dashboard.snapshot {
            for source in &snapshot.sources {
                if (source.platform == "claude" && !dashboard.settings.show_claude)
                    || (source.platform == "grok" && !dashboard.settings.show_grok)
                {
                    continue;
                }
                let t = &source.today.tokens;
                let total = t
                    .input
                    .saturating_add(t.output)
                    .saturating_add(t.cache_read)
                    .saturating_add(t.cache_write)
                    .saturating_add(t.reasoning);
                lines.push(format!(
                    "{}: 今日 {:.2}M tokens",
                    source.platform,
                    total as f64 / 1_000_000.0
                ));
            }
        }
        let _ = tray.set_tooltip(Some(lines.join("\n")));
    }
    let _ = app.emit("dashboard-updated", dashboard);
}

fn toggle_panel(app: &tauri::AppHandle, platform: &str, anchor: taskbar::Rect) {
    let state = state(app);
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let mut active = state
        .panel_platform
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    #[cfg(feature = "ui-test")]
    eprintln!(
        "taskbar toggle: platform={platform} active={active} visible={:?}",
        window.is_visible()
    );
    if taskbar::hides_on_click(window.is_visible().unwrap_or(false), &active, platform) {
        let result = window.hide();
        #[cfg(feature = "ui-test")]
        eprintln!(
            "taskbar hide returned {result:?}; visible={:?}",
            window.is_visible()
        );
        let _ = result;
        return;
    }
    *active = platform.to_string();
    drop(active);
    let center_x = (anchor.left + anchor.right) as f64 / 2.0;
    let center_y = (anchor.top + anchor.bottom) as f64 / 2.0;
    if let Ok(Some(monitor)) = window.monitor_from_point(center_x, center_y) {
        let area = monitor.work_area();
        if let Ok(size) = window.outer_size() {
            let (x, y) = taskbar::panel_position(
                anchor,
                taskbar::Rect {
                    left: area.position.x,
                    top: area.position.y,
                    right: area.position.x + area.size.width as i32,
                    bottom: area.position.y + area.size.height as i32,
                },
                size.width as i32,
                size.height as i32,
            );
            let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
        }
    }
    let _ = app.emit("open-platform", platform);
    show(app);
}

#[tauri::command]
fn get_taskbar_status(app: tauri::AppHandle) -> taskbar::Status {
    state(&app).taskbar.status()
}
#[tauri::command]
fn get_active_platform(app: tauri::AppHandle) -> String {
    state(&app)
        .panel_platform
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}
#[tauri::command]
fn set_active_platform(app: tauri::AppHandle, platform: String) -> Result<(), String> {
    if !["codex", "claude", "grok"].contains(&platform.as_str()) {
        return Err("平台无效。".into());
    }
    *state(&app)
        .panel_platform
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = platform;
    Ok(())
}

async fn update_receiver(state: &AppState, settings: &settings::Settings) -> String {
    let mut receiver = state.receiver.lock().await;
    if !settings.memory_enabled {
        if let Some(mut child) = receiver.take() {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
        return "未启用".into();
    }
    if let Some(child) = receiver.as_mut() {
        if matches!(child.try_wait(), Ok(None)) {
            return "接收中 · 127.0.0.1:4318".into();
        }
        *receiver = None;
    }
    let mut command = process::command(&state.helper, settings);
    command
        .arg("memory-receiver")
        .arg("--database")
        .arg(state.dir.join("memory-telemetry.sqlite"))
        .arg("--status-file")
        .arg(state.dir.join("memory-status.json"))
        .arg("--parent-pid")
        .arg(std::process::id().to_string());
    match command.spawn() {
        Ok(mut child) => {
            tokio::time::sleep(Duration::from_millis(250)).await;
            if matches!(child.try_wait(), Ok(None)) {
                *receiver = Some(child);
                "接收中 · 127.0.0.1:4318".into()
            } else {
                "接收器启动失败，请检查 4318 端口是否被占用。".into()
            }
        }
        Err(_) => "Memory 接收器启动失败。".into(),
    }
}

async fn refresh(app: tauri::AppHandle) {
    let state = state(&app);
    let Ok(_guard) = state.refresh_lock.try_lock() else {
        return;
    };
    let (settings, previous) = {
        let mut dashboard = state.dashboard.lock().await;
        dashboard.refreshing = true;
        dashboard.error = None;
        (dashboard.settings.clone(), dashboard.quotas.clone())
    };
    publish(&app, &state).await;
    let memory_status = update_receiver(&state, &settings).await;
    let quotas = quota::fetch(&settings, &previous).await;
    {
        let mut dashboard = state.dashboard.lock().await;
        dashboard.quotas = quotas.clone();
        dashboard.memory_status = memory_status;
    }
    publish(&app, &state).await;
    let mut command = process::command(&state.helper, &settings);
    command.args(["--days", "30", "--statistics-timezone", "utc"]);
    let now = chrono::Utc::now().timestamp_millis();
    for (platform, flag) in [
        ("codex", "--weekly-reset-ms"),
        ("claude", "--claude-weekly-reset-ms"),
        ("grok", "--grok-weekly-reset-ms"),
    ] {
        if let Some(window) = quotas.get(platform).and_then(|q| q.weekly.as_ref()) {
            if let Some(reset) = window
                .resets_at_ms
                .zip(window.window_minutes)
                .filter(|(_, minutes)| *minutes == 10080)
                .map(|(end, minutes)| end - minutes * 60000)
                .filter(|start| *start > 0 && *start <= now && now - *start <= 8 * 86400000)
            {
                command.arg(flag).arg(reset.to_string());
            }
        }
    }
    let database = state.dir.join("memory-telemetry.sqlite");
    if database.is_file() {
        command.arg("--memory-database").arg(database);
    }
    let result = process::capture(command, 120).await.and_then(|bytes| {
        let snapshot: ActivitySnapshot =
            serde_json::from_slice(&bytes).map_err(|_| "统计数据格式无效。")?;
        if snapshot.schema_version != tokenbar_helper::SCHEMA_VERSION || snapshot.timezone != "UTC"
        {
            return Err("Helper 版本或统计时区不匹配。".into());
        }
        Ok(snapshot)
    });
    let fresh_snapshot = result.as_ref().ok().cloned();
    {
        let mut dashboard = state.dashboard.lock().await;
        match result {
            Ok(snapshot) => dashboard.snapshot = Some(snapshot),
            Err(error) => dashboard.error = Some(error),
        }
    }
    publish(&app, &state).await;
    if settings.sync_enabled {
        if let Some(snapshot) = fresh_snapshot {
            let directory = state.dir.clone();
            let sync_settings = settings.clone();
            let result = tauri::async_runtime::spawn_blocking(move || {
                sync::round(&directory, &sync_settings, &snapshot)
            })
            .await;
            let mut dashboard = state.dashboard.lock().await;
            match result {
                Ok(Ok(remotes)) => {
                    dashboard.sync_status = format!("同步完成 · {} 台其他设备", remotes.len());
                    dashboard.remote_snapshots = remotes;
                }
                Ok(Err(error)) => dashboard.sync_status = error,
                Err(_) => dashboard.sync_status = "同步任务未完成。".into(),
            }
        }
    }
    state.dashboard.lock().await.refreshing = false;
    // Quota contains percentages and timestamps only. Session content stays in memory.
    if let Ok(bytes) = serde_json::to_vec(&quotas) {
        let _ = tokio::fs::write(state.dir.join("quota-cache.json"), bytes).await;
    }
    publish(&app, &state).await;
}

#[tauri::command]
async fn get_dashboard(app: tauri::AppHandle) -> Dashboard {
    state(&app).dashboard.lock().await.clone()
}
#[tauri::command]
fn refresh_dashboard(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(refresh(app));
}
#[tauri::command]
async fn save_settings(
    app: tauri::AppHandle,
    settings: settings::Settings,
    sync_token: Option<String>,
) -> Result<(), String> {
    settings.validate()?;
    let state = state(&app);
    let _guard = state.refresh_lock.lock().await;
    let old = state.dashboard.lock().await.settings.clone();
    if settings.sync_enabled
        && !sync::has_token(&state.dir)
        && sync_token.as_ref().is_none_or(|v| v.is_empty())
    {
        return Err("启用同步前请填写访问令牌。".into());
    }
    let manager = app.autolaunch();
    if settings.autostart != old.autostart {
        if settings.autostart {
            manager.enable()
        } else {
            manager.disable()
        }
        .map_err(|_| "无法更新开机启动设置。")?;
    }
    if let Err(error) = settings::save(&state.dir, &settings) {
        if old.autostart {
            let _ = manager.enable();
        } else {
            let _ = manager.disable();
        }
        return Err(error);
    }
    if let Some(token) = sync_token.filter(|v| !v.is_empty()) {
        if let Err(error) = sync::save_token(&state.dir, token) {
            let _ = settings::save(&state.dir, &old);
            if old.autostart {
                let _ = manager.enable();
            } else {
                let _ = manager.disable();
            }
            return Err(error);
        }
    }
    {
        let mut dashboard = state.dashboard.lock().await;
        if old.codex_home != settings.codex_home
            || old.claude_home != settings.claude_home
            || old.grok_home != settings.grok_home
        {
            dashboard.snapshot = None;
            dashboard.quotas.clear();
        }
        if !settings.sync_enabled || old.sync_endpoint != settings.sync_endpoint {
            dashboard.remote_snapshots.clear();
            dashboard.sync_status = if settings.sync_enabled {
                "等待同步".into()
            } else {
                "未启用".into()
            };
        }
        dashboard.settings = settings;
    }
    drop(_guard);
    state.timer_changed.notify_one();
    publish(&app, &state).await;
    tauri::async_runtime::spawn(refresh(app));
    Ok(())
}
#[tauri::command]
fn set_pinned(app: tauri::AppHandle, pinned: bool) -> Result<(), String> {
    state(&app).pinned.store(pinned, Ordering::Relaxed);
    app.get_webview_window("main")
        .ok_or("窗口不可用。")?
        .set_always_on_top(pinned)
        .map_err(|e| e.to_string())
}

fn find_request<'a>(requests: &'a [RequestSummary], id: &str) -> Option<&'a RequestSummary> {
    for request in requests {
        if request.id == id {
            return Some(request);
        }
        if let Some(found) = find_request(&request.contributions, id) {
            return Some(found);
        }
    }
    None
}
#[tauri::command]
async fn request_detail(
    app: tauri::AppHandle,
    platform: String,
    session_id: String,
    request_id: String,
) -> Result<RequestDetail, String> {
    let state = state(&app);
    let (settings, request) = {
        let dashboard = state.dashboard.lock().await;
        let session = dashboard
            .snapshot
            .as_ref()
            .and_then(|s| {
                s.sessions
                    .iter()
                    .find(|s| s.platform == platform && s.id == session_id)
            })
            .ok_or("会话已更新，请重新打开。")?;
        let request =
            find_request(&session.requests, &request_id).ok_or("请求已更新，请重新打开。")?;
        (dashboard.settings.clone(), request.clone())
    };
    let path = request
        .session_path
        .as_ref()
        .ok_or("此请求没有本地详情。")?;
    let mut command = process::command(&state.helper, &settings);
    command
        .args([
            "request-detail",
            "--platform",
            &platform,
            "--session-path",
            path,
            "--start-ms",
        ])
        .arg(request.started_at_ms.to_string())
        .arg("--end-ms")
        .arg(request.ended_at_ms.to_string());
    let bytes = process::capture(command, 30).await?;
    serde_json::from_slice(&bytes).map_err(|_| "请求详情格式无效。".into())
}
#[tauri::command]
fn copy_text(app: tauri::AppHandle, text: String) -> Result<(), String> {
    if text.len() > 4 * 1024 * 1024 {
        return Err("复制内容过长。".into());
    }
    app.clipboard()
        .write_text(text)
        .map_err(|_| "无法写入剪贴板。".into())
}
#[tauri::command]
async fn open_session(
    app: tauri::AppHandle,
    platform: String,
    session_id: String,
) -> Result<(), String> {
    let state = state(&app);
    let dashboard = state.dashboard.lock().await;
    let session = dashboard
        .snapshot
        .as_ref()
        .and_then(|s| {
            s.sessions
                .iter()
                .find(|s| s.platform == platform && s.id == session_id)
        })
        .ok_or("会话不可用。")?;
    let url = match platform.as_str() {
        "codex" => {
            let id = session
                .id
                .get(session.id.len().saturating_sub(36)..)
                .ok_or("会话标识无效。")?;
            if id.len() != 36 || !id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
                return Err("会话标识无效。".into());
            }
            format!("codex://threads/{id}")
        }
        "claude" => "claude://claude.ai/local_sessions".into(),
        _ => return Err("请复制会话标识，在 Grok Build 中使用 --resume 恢复会话。".into()),
    };
    app.opener()
        .open_url(url, None::<&str>)
        .map_err(|_| "无法打开客户端，请确认已安装并注册应用链接。".into())
}

fn main() {
    macro_rules! command_handler {
        ($($extra:path),*) => {
            tauri::generate_handler![
                get_dashboard, refresh_dashboard, save_settings, set_pinned,
                request_detail, copy_text, open_session,
                get_taskbar_status, get_active_platform, set_active_platform
                $(,$extra)*
            ]
        };
    }
    #[cfg(all(windows, feature = "ui-test"))]
    let handler: Box<dyn Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync> =
        Box::new(command_handler![test_taskbar_click]);
    #[cfg(not(all(windows, feature = "ui-test")))]
    let handler: Box<dyn Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync> =
        Box::new(command_handler![]);
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| show(app)))
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .arg("--background")
                .build(),
        )
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(handler)
        .setup(|app| {
            let dir = app.path().app_local_data_dir()?;
            std::fs::create_dir_all(&dir)?;
            let (mut settings, error) = match settings::load(&dir) {
                Ok(settings) => (settings, None),
                Err(error) => (settings::Settings::default(), Some(error)),
            };
            settings.autostart = app.autolaunch().is_enabled().unwrap_or(settings.autostart);
            let sibling = std::env::current_exe()?
                .parent()
                .unwrap()
                .join("tokenbar-helper.exe");
            let helper = if sibling.is_file() {
                sibling
            } else {
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("binaries/tokenbar-helper-x86_64-pc-windows-msvc.exe")
            };
            let quotas = std::fs::read(dir.join("quota-cache.json"))
                .ok()
                .and_then(|b| serde_json::from_slice(&b).ok())
                .unwrap_or_default();
            app.manage(Arc::new(AppState {
                dashboard: Mutex::new(Dashboard {
                    settings,
                    snapshot: None,
                    quotas,
                    refreshing: false,
                    error,
                    memory_status: "未启用".into(),
                    remote_snapshots: vec![],
                    sync_status: "未同步".into(),
                }),
                refresh_lock: Mutex::new(()),
                timer_changed: Notify::new(),
                receiver: Mutex::new(None),
                pinned: AtomicBool::new(false),
                taskbar: taskbar::Controller::new(),
                panel_platform: std::sync::Mutex::new("codex".into()),
                dir,
                helper,
            }));
            state(app.handle()).taskbar.start(app.handle().clone());
            let open = MenuItem::with_id(app, "open", "打开 TokenBar", true, None::<&str>)?;
            let refresh_item = MenuItem::with_id(app, "refresh", "刷新", true, None::<&str>)?;
            let settings_item = MenuItem::with_id(app, "settings", "设置", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 TokenBar", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &refresh_item, &settings_item, &quit])?;
            TrayIconBuilder::with_id("tokenbar")
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("TokenBar")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => show(app),
                    "refresh" => {
                        tauri::async_runtime::spawn(refresh(app.clone()));
                    }
                    "settings" => {
                        show(app);
                        let _ = app.emit("open-settings", ());
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        position,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        let platform = get_active_platform(app.clone());
                        toggle_panel(
                            app,
                            &platform,
                            taskbar::Rect {
                                left: position.x as i32 - 12,
                                right: position.x as i32 + 12,
                                top: position.y as i32 - 12,
                                bottom: position.y as i32 + 12,
                            },
                        );
                    }
                })
                .build(app)?;
            if std::env::args().any(|a| a == "--background") {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
            }
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                refresh(handle.clone()).await;
                loop {
                    let app_state = state(&handle);
                    let seconds = app_state
                        .dashboard
                        .lock()
                        .await
                        .settings
                        .refresh_seconds
                        .clamp(60, 3600);
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_secs(seconds)) => {},
                        _ = app_state.timer_changed.notified() => continue,
                    }
                    refresh(handle.clone()).await;
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| match event {
            tauri::WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                let _ = window.hide();
            }
            tauri::WindowEvent::Focused(false)
                if !state(window.app_handle()).pinned.load(Ordering::Relaxed)
                    && !state(window.app_handle()).taskbar.pointer_pressed() =>
            {
                let _ = window.hide();
            }
            _ => {}
        })
        .build(tauri::generate_context!())
        .expect("TokenBar could not start")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                state(app).taskbar.stop();
            }
        });
}

#[cfg(all(windows, feature = "ui-test"))]
#[tauri::command]
fn test_taskbar_click(app: tauri::AppHandle, index: usize) -> Result<(), String> {
    if index >= 3 {
        return Err("无效的任务栏按钮索引。".into());
    }
    state(&app).taskbar.test_click(index);
    Ok(())
}
