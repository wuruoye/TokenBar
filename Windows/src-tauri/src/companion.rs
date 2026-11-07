use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::Path;
use std::time::Duration;

use tauri::Manager;
use tauri_plugin_opener::OpenerExt;

/// Calls the local Antigravity Language Server (`daemon/hub_*.json` or `ls_*.json`) to update
/// `lastUserViewTime` and clear `markedAsUnread` so Antigravity's own UI also marks the
/// conversation as read.
pub fn sync_antigravity_read_annotation(antigravity_root: &Path, conversation_id: &str) {
    let daemon_dir = antigravity_root.join("daemon");
    let Ok(entries) = fs::read_dir(&daemon_dir) else {
        return;
    };
    let now_rfc3339 = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let body = serde_json::json!({
        "cascadeId": conversation_id,
        "annotations": {
            "lastUserViewTime": now_rfc3339,
            "markedAsUnread": false
        },
        "mergeAnnotations": true
    })
    .to_string();

    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        if !(name.starts_with("hub_") || name.starts_with("ls_")) || !name.ends_with(".json") {
            continue;
        }
        let Ok(bytes) = fs::read(&path) else {
            continue;
        };
        let Ok(info) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            continue;
        };
        let Some(port) = info.get("httpPort").and_then(|v| v.as_u64()) else {
            continue;
        };
        let Some(csrf) = info.get("csrfToken").and_then(|v| v.as_str()) else {
            continue;
        };
        if port == 0 || port > 65535 || csrf.is_empty() {
            continue;
        }
        let addr = SocketAddr::from(([127, 0, 0, 1], port as u16));
        if let Ok(mut stream) = TcpStream::connect_timeout(&addr, Duration::from_millis(250)) {
            let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
            let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
            let request = format!(
                "POST /exa.language_server_pb.LanguageServerService/UpdateConversationAnnotations HTTP/1.1\r\n\
                 Host: 127.0.0.1:{port}\r\n\
                 Content-Type: application/json\r\n\
                 Connect-Protocol-Version: 1\r\n\
                 x-codeium-csrf-token: {csrf}\r\n\
                 Content-Length: {}\r\n\
                 Connection: close\r\n\r\n\
                 {body}",
                body.len()
            );
            if stream.write_all(request.as_bytes()).is_ok() {
                let mut resp = [0u8; 128];
                let _ = stream.read(&mut resp);
            }
        }
    }
}

pub fn open_task_session(
    app: &tauri::AppHandle,
    platform: &str,
    task_id: &str,
    workspace_path: Option<&str>,
    title: Option<&str>,
    antigravity_root: &Path,
) -> Result<(), String> {
    match platform {
        "codex" => {
            let id = task_id
                .get(task_id.len().saturating_sub(36)..)
                .ok_or("会话标识无效。")?;
            if id.len() != 36 || !id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
                return Err("会话标识无效。".into());
            }
            app.opener()
                .open_url(format!("codex://threads/{id}"), None::<&str>)
                .map_err(|_| "无法打开 Codex，请确认已安装并注册应用链接。".into())
        }
        "claude" => {
            let url = if task_id.starts_with("local_") {
                format!("claude://code/continue?session={task_id}")
            } else if let Some(desktop_id) = resolve_claude_desktop_session_id(task_id) {
                format!("claude://code/continue?session={desktop_id}")
            } else {
                "claude://claude.ai/local_sessions".to_string()
            };
            app.opener()
                .open_url(url, None::<&str>)
                .map_err(|_| "无法打开 Claude，请确认已安装并注册应用链接。".into())
        }
        "antigravity" => {
            let conv_id = task_id.to_string();
            let agy_root = antigravity_root.to_path_buf();
            std::thread::spawn(move || {
                sync_antigravity_read_annotation(&agy_root, &conv_id);
            });

            #[cfg(windows)]
            let has_window = !win::antigravity_windows().is_empty();
            #[cfg(not(windows))]
            let has_window = false;
            if !has_window {
                // Bring Antigravity up first, as macOS does with `antigravity://focus`.
                let focused = app.opener().open_url("antigravity://focus", None::<&str>).is_ok();
                if !focused {
                    let exe = crate::find_antigravity_binary().ok_or("未找到 Antigravity 客户端。")?;
                    let mut cmd = std::process::Command::new(exe);
                    if let Some(workspace) = workspace_path
                        .map(str::trim)
                        .filter(|s| !s.is_empty() && Path::new(s).exists())
                    {
                        cmd.arg(workspace);
                    }
                    #[cfg(windows)]
                    {
                        use std::os::windows::process::CommandExt;
                        cmd.creation_flags(0x08000000);
                    }
                    cmd.spawn().map_err(|_| "无法启动 Antigravity。")?;
                }
            }
            #[cfg(windows)]
            win::navigate_antigravity(
                task_id.to_string(),
                title.map(str::to_string),
                workspace_path
                    .and_then(|p| Path::new(p).file_name())
                    .map(|n| n.to_string_lossy().into_owned()),
            );
            Ok(())
        }
        _ => Err("暂不支持直接打开该平台会话。".into()),
    }
}

fn resolve_claude_desktop_session_id(cli_session_id: &str) -> Option<String> {
    let appdata = std::env::var_os("APPDATA")?;
    let root = Path::new(&appdata).join("Claude/claude-code-sessions");
    if !root.is_dir() {
        return None;
    }
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "json") {
                let Ok(bytes) = fs::read(&path) else {
                    continue;
                };
                let Ok(val) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
                    continue;
                };
                let cli_id = val.get("cliSessionId").and_then(|v| v.as_str());
                let sess_id = val.get("sessionId").and_then(|v| v.as_str());
                if cli_id == Some(cli_session_id) || sess_id == Some(cli_session_id) {
                    if let Some(id) = sess_id {
                        return Some(id.to_string());
                    }
                }
            }
        }
    }
    None
}

#[cfg(windows)]
mod win {
    use std::{
        mem::{size_of, zeroed},
        path::Path,
        ptr::null_mut,
        sync::{
            atomic::{AtomicBool, Ordering},
            Mutex,
        },
        time::Duration,
    };
    use windows::Win32::{
        System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED},
        UI::Accessibility::{
            CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationInvokePattern,
            IUIAutomationLegacyIAccessiblePattern, IUIAutomationSelectionItemPattern, IUIAutomationValuePattern,
            TreeScope_Descendants, UIA_ButtonControlTypeId, UIA_ControlTypePropertyId, UIA_HyperlinkControlTypeId,
            UIA_InvokePatternId, UIA_LegacyIAccessiblePatternId, UIA_ListItemControlTypeId, UIA_NamePropertyId,
            UIA_SelectionItemPatternId, UIA_ValuePatternId,
        },
    };
    use windows_sys::Win32::{
        Foundation::{CloseHandle, FILETIME, HWND, LPARAM, RECT},
        Graphics::Gdi::{GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST},
        System::{
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
            },
            Threading::{
                GetCurrentProcessId, GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
                PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
        UI::{
            Accessibility::{SetWinEventHook, HWINEVENTHOOK},
            WindowsAndMessaging::{
                DispatchMessageW, EnumWindows, GetClassNameW, GetDesktopWindow, GetForegroundWindow, GetMessageW,
                GetShellWindow, GetWindowLongW, GetWindowRect, GetWindowTextW, GetWindowThreadProcessId, IsIconic,
                IsWindowVisible, IsZoomed, SetForegroundWindow, SetWindowPos, ShowWindow, TranslateMessage,
                EVENT_SYSTEM_FOREGROUND, GWL_EXSTYLE, GWL_STYLE, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE,
                SWP_NOSIZE, SWP_NOZORDER, SW_RESTORE, SW_SHOW, WINEVENT_OUTOFCONTEXT, WS_CAPTION, WS_EX_TRANSPARENT,
            },
        },
    };

    static FOREGROUND_EVENTS: Mutex<Vec<(Option<&'static str>, i64)>> = Mutex::new(Vec::new());
    static LAST_FULLSCREEN: AtomicBool = AtomicBool::new(false);

    fn now_ms() -> i64 {
        chrono::Utc::now().timestamp_millis()
    }

    unsafe fn process_path_lower(pid: u32) -> Option<String> {
        if pid == 0 {
            return None;
        }
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return None;
        }
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, buf.as_mut_ptr(), &mut len);
        CloseHandle(process);
        if ok == 0 {
            return None;
        }
        Some(String::from_utf16_lossy(&buf[..len as usize]).to_ascii_lowercase())
    }

    unsafe fn platform_of_window(hwnd: HWND) -> Option<&'static str> {
        if hwnd.is_null() {
            return None;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, &mut pid);
        let path = process_path_lower(pid)?;
        let stem = Path::new(&path)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        if stem == "antigravity" {
            Some("antigravity")
        } else if stem == "codex" || stem == "chatgpt" || path.contains("openai.codex") {
            Some("codex")
        } else if stem == "claude" || path.contains("anthropic.claude") {
            Some("claude")
        } else {
            None
        }
    }

    pub fn foreground_platform() -> Option<&'static str> {
        unsafe { platform_of_window(GetForegroundWindow()) }
    }

    /// Detects whether the current foreground window covers its entire monitor
    /// in fullscreen mode (excluding the desktop shell, taskbar, and TokenBar itself).
    pub fn is_foreground_fullscreen() -> bool {
        unsafe {
            let hwnd = GetForegroundWindow();
            if hwnd.is_null() {
                LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                return false;
            }
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, &mut pid);
            if pid == GetCurrentProcessId() {
                return LAST_FULLSCREEN.load(Ordering::Relaxed);
            }
            if hwnd == GetDesktopWindow() || hwnd == GetShellWindow() {
                LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                return false;
            }
            if IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0 {
                LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                return false;
            }
            let ex_style = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
            if (ex_style & WS_EX_TRANSPARENT) != 0 {
                LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                return false;
            }
            let mut class_buf = [0u16; 128];
            let class_len = GetClassNameW(hwnd, class_buf.as_mut_ptr(), class_buf.len() as i32);
            if class_len > 0 {
                let class_name = String::from_utf16_lossy(&class_buf[..class_len as usize]);
                if matches!(
                    class_name.as_str(),
                    "Progman"
                        | "WorkerW"
                        | "Shell_TrayWnd"
                        | "Shell_SecondaryTrayWnd"
                        | "XamlExplorerHostIslandWindow"
                        | "MultitaskingViewFrame"
                ) {
                    LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                    return false;
                }
            }
            let mut rc: RECT = zeroed();
            if GetWindowRect(hwnd, &mut rc) == 0 {
                LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                return false;
            }
            let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            if monitor.is_null() {
                LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                return false;
            }
            let mut mi: MONITORINFO = zeroed();
            mi.cbSize = size_of::<MONITORINFO>() as u32;
            if GetMonitorInfoW(monitor, &mut mi) == 0 {
                LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                return false;
            }
            let m = mi.rcMonitor;
            let w = mi.rcWork;
            let covers_monitor =
                rc.left <= m.left && rc.top <= m.top && rc.right >= m.right && rc.bottom >= m.bottom;
            if !covers_monitor {
                LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                return false;
            }
            let work_equals_monitor = (w.left - m.left).abs() <= 2
                && (w.top - m.top).abs() <= 2
                && (w.right - m.right).abs() <= 2
                && (w.bottom - m.bottom).abs() <= 2;
            if work_equals_monitor {
                let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
                if IsZoomed(hwnd) != 0 && (style & WS_CAPTION) == WS_CAPTION && rc.top < m.top {
                    LAST_FULLSCREEN.store(false, Ordering::Relaxed);
                    return false;
                }
            }
            LAST_FULLSCREEN.store(true, Ordering::Relaxed);
            true
        }
    }

    pub fn raise_window_no_activate(hwnd_raw: isize) {
        unsafe {
            let _ = SetWindowPos(
                hwnd_raw as HWND,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            );
        }
    }

    pub fn set_window_rect_no_activate(hwnd_raw: isize, x: i32, y: i32, width: i32, height: i32) {
        unsafe {
            let _ = SetWindowPos(
                hwnd_raw as HWND,
                null_mut(),
                x,
                y,
                width,
                height,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
    }

    unsafe extern "system" fn on_foreground(
        _hook: HWINEVENTHOOK,
        _event: u32,
        hwnd: HWND,
        _object: i32,
        _child: i32,
        _thread: u32,
        _time: u32,
    ) {
        let platform = platform_of_window(hwnd);
        if let Ok(mut events) = FOREGROUND_EVENTS.lock() {
            events.push((platform, now_ms()));
            if events.len() > 256 {
                events.drain(..128);
            }
        }
    }

    /// Records every foreground switch as it happens, so visits to an app have
    /// accurate start and end times (macOS uses `didActivateApplicationNotification`).
    pub fn start_foreground_hook() {
        let _ = std::thread::Builder::new()
            .name("tokenbar-foreground".into())
            .spawn(|| unsafe {
                let hook = SetWinEventHook(
                    EVENT_SYSTEM_FOREGROUND,
                    EVENT_SYSTEM_FOREGROUND,
                    null_mut(),
                    Some(on_foreground),
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT,
                );
                if hook.is_null() {
                    return;
                }
                let mut message = zeroed();
                while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
                    TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
            });
    }

    pub fn drain_foreground_events() -> Vec<(Option<&'static str>, i64)> {
        FOREGROUND_EVENTS
            .lock()
            .map(|mut events| std::mem::take(&mut *events))
            .unwrap_or_default()
    }

    fn filetime_ms(time: FILETIME) -> i64 {
        let ticks = ((time.dwHighDateTime as u64) << 32) | time.dwLowDateTime as u64;
        (ticks / 10_000) as i64 - 11_644_473_600_000
    }

    /// Whether a process with this executable name runs, and the earliest start time among them.
    pub fn app_process_state(exe_name: &str) -> (bool, Option<i64>) {
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snapshot.is_null() || snapshot as isize == -1 {
                return (true, None);
            }
            let mut entry: PROCESSENTRY32W = zeroed();
            entry.dwSize = size_of::<PROCESSENTRY32W>() as u32;
            let mut running = false;
            let mut earliest: Option<i64> = None;
            let mut ok = Process32FirstW(snapshot, &mut entry) != 0;
            while ok {
                let len = entry.szExeFile.iter().position(|&c| c == 0).unwrap_or(entry.szExeFile.len());
                let name = String::from_utf16_lossy(&entry.szExeFile[..len]);
                if name.eq_ignore_ascii_case(exe_name) {
                    running = true;
                    let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID);
                    if !process.is_null() {
                        let (mut created, mut exited, mut kernel, mut user) = (zeroed(), zeroed(), zeroed(), zeroed());
                        if GetProcessTimes(process, &mut created, &mut exited, &mut kernel, &mut user) != 0 {
                            let at = filetime_ms(created);
                            earliest = Some(earliest.map_or(at, |e: i64| e.min(at)));
                        }
                        CloseHandle(process);
                    }
                }
                ok = Process32NextW(snapshot, &mut entry) != 0;
            }
            CloseHandle(snapshot);
            (running, earliest)
        }
    }

    /// Visible top-level windows owned by Antigravity, with their titles.
    pub fn antigravity_windows() -> Vec<(usize, String)> {
        unsafe extern "system" fn visit(hwnd: HWND, lparam: LPARAM) -> i32 {
            if IsWindowVisible(hwnd) == 0 {
                return 1;
            }
            let mut title = [0u16; 512];
            let len = GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32);
            if len <= 0 || platform_of_window(hwnd) != Some("antigravity") {
                return 1;
            }
            let list = &mut *(lparam as *mut Vec<(usize, String)>);
            list.push((hwnd as usize, String::from_utf16_lossy(&title[..len as usize])));
            1
        }
        let mut windows: Vec<(usize, String)> = Vec::new();
        unsafe {
            EnumWindows(Some(visit), (&mut windows as *mut Vec<(usize, String)>) as LPARAM);
        }
        // The Agent Manager (hub) window first, then workspace windows.
        windows.sort_by_key(|(_, title)| {
            let lower = title.to_ascii_lowercase();
            !(lower == "antigravity" || lower.starts_with("antigravity - "))
        });
        windows
    }

    unsafe fn activate_window(hwnd: usize) {
        let hwnd = hwnd as HWND;
        ShowWindow(hwnd, if IsIconic(hwnd) != 0 { SW_RESTORE } else { SW_SHOW });
        SetForegroundWindow(hwnd);
    }

    unsafe fn invoke(element: &IUIAutomationElement) -> bool {
        if let Ok(pattern) = element.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId) {
            if pattern.Invoke().is_ok() {
                return true;
            }
        }
        if let Ok(pattern) = element.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId) {
            if pattern.Select().is_ok() {
                return true;
            }
        }
        if let Ok(pattern) =
            element.GetCurrentPatternAs::<IUIAutomationLegacyIAccessiblePattern>(UIA_LegacyIAccessiblePatternId)
        {
            return pattern.DoDefaultAction().is_ok();
        }
        false
    }

    /// Finds the sidebar link to `/c/<id>`, or else an item named like the conversation.
    unsafe fn find_conversation(
        uia: &IUIAutomation,
        hwnd: usize,
        conversation_id: &str,
        title: Option<&str>,
    ) -> Option<IUIAutomationElement> {
        let root = uia.ElementFromHandle(windows::Win32::Foundation::HWND(hwnd as _)).ok()?;
        let condition = uia.CreateTrueCondition().ok()?;
        let cache = uia.CreateCacheRequest().ok()?;
        cache.AddProperty(UIA_ControlTypePropertyId).ok()?;
        cache.AddProperty(UIA_NamePropertyId).ok()?;
        let elements = root.FindAllBuildCache(TreeScope_Descendants, &condition, &cache).ok()?;
        let target = format!("/c/{conversation_id}");
        let mut by_name = None;
        for index in 0..elements.Length().ok()?.min(4000) {
            let Ok(element) = elements.GetElement(index) else { continue };
            let Ok(kind) = element.CachedControlType() else { continue };
            if kind == UIA_HyperlinkControlTypeId {
                let url = element
                    .GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                    .and_then(|p| p.CurrentValue())
                    .map(|v| v.to_string())
                    .unwrap_or_default();
                if url.contains(&target) {
                    return Some(element);
                }
            }
            if by_name.is_none() && (kind == UIA_HyperlinkControlTypeId || kind == UIA_ListItemControlTypeId) {
                if let Some(title) = title {
                    let name = element.CachedName().map(|n| n.to_string()).unwrap_or_default();
                    let name = name.trim();
                    if !name.is_empty() && (name == title || name.starts_with(title)) {
                        by_name = Some(element);
                    }
                }
            }
        }
        by_name
    }

    unsafe fn find_button(uia: &IUIAutomation, hwnd: usize, label: &str) -> Option<IUIAutomationElement> {
        let root = uia.ElementFromHandle(windows::Win32::Foundation::HWND(hwnd as _)).ok()?;
        let condition = uia.CreateTrueCondition().ok()?;
        let cache = uia.CreateCacheRequest().ok()?;
        cache.AddProperty(UIA_ControlTypePropertyId).ok()?;
        cache.AddProperty(UIA_NamePropertyId).ok()?;
        let elements = root.FindAllBuildCache(TreeScope_Descendants, &condition, &cache).ok()?;
        let label = label.to_ascii_lowercase();
        for index in 0..elements.Length().ok()?.min(4000) {
            let Ok(element) = elements.GetElement(index) else { continue };
            if element.CachedControlType().ok() != Some(UIA_ButtonControlTypeId) {
                continue;
            }
            let name = element.CachedName().map(|n| n.to_string()).unwrap_or_default();
            if name.to_ascii_lowercase().contains(&label) {
                return Some(element);
            }
        }
        None
    }

    /// Port of `AntigravityConversationNavigator`: Chromium fills its UIA tree
    /// lazily, so the search retries; a collapsed sidebar is opened once.
    pub fn navigate_antigravity(conversation_id: String, title: Option<String>, workspace_label: Option<String>) {
        let _ = std::thread::Builder::new()
            .name("tokenbar-antigravity-open".into())
            .spawn(move || unsafe {
                let com_ok = CoInitializeEx(None, COINIT_MULTITHREADED).is_ok();
                let automation: Option<IUIAutomation> =
                    CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok();
                let mut opened = false;
                if let Some(uia) = &automation {
                    let mut toggled = false;
                    for attempt in 0..16 {
                        let windows = antigravity_windows();
                        for &(hwnd, _) in &windows {
                            if let Some(element) = find_conversation(uia, hwnd, &conversation_id, title.as_deref()) {
                                activate_window(hwnd);
                                if invoke(&element) {
                                    opened = true;
                                    break;
                                }
                            }
                        }
                        if opened {
                            break;
                        }
                        if attempt >= 3 && !toggled && !windows.is_empty() {
                            toggled = windows.iter().any(|&(hwnd, _)| {
                                find_button(uia, hwnd, "toggle sidebar").is_some_and(|button| invoke(&button))
                            });
                        }
                        std::thread::sleep(Duration::from_millis(if windows.is_empty() { 400 } else { 150 }));
                    }
                }
                if !opened {
                    let windows = antigravity_windows();
                    let chosen = workspace_label
                        .as_deref()
                        .map(str::to_ascii_lowercase)
                        .and_then(|label| windows.iter().find(|(_, t)| t.to_ascii_lowercase().contains(&label)))
                        .or_else(|| windows.first());
                    if let Some(&(hwnd, _)) = chosen {
                        activate_window(hwnd);
                    }
                }
                drop(automation);
                if com_ok {
                    CoUninitialize();
                }
            });
    }
}

#[cfg(windows)]
pub use win::{
    app_process_state, drain_foreground_events, foreground_platform, is_foreground_fullscreen,
    raise_window_no_activate, set_window_rect_no_activate, start_foreground_hook,
};

#[cfg(not(windows))]
pub fn foreground_platform() -> Option<&'static str> {
    None
}
#[cfg(not(windows))]
pub fn is_foreground_fullscreen() -> bool {
    false
}
#[cfg(not(windows))]
pub fn raise_window_no_activate(_hwnd_raw: isize) {}
#[cfg(not(windows))]
pub fn set_window_rect_no_activate(_hwnd_raw: isize, _x: i32, _y: i32, _width: i32, _height: i32) {}
#[cfg(not(windows))]
pub fn app_process_state(_exe_name: &str) -> (bool, Option<i64>) {
    (true, None)
}
#[cfg(not(windows))]
pub fn drain_foreground_events() -> Vec<(Option<&'static str>, i64)> {
    Vec::new()
}
#[cfg(not(windows))]
pub fn start_foreground_hook() {}

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CompanionAnchor {
    pub right: i32,
    pub bottom: i32,
}

static COMPANION_ANCHOR: std::sync::Mutex<Option<CompanionAnchor>> = std::sync::Mutex::new(None);
static COMPANION_RESIZING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn anchor_path(app: &tauri::AppHandle) -> Option< std::path::PathBuf> {
    app.path().app_local_data_dir().ok().map(|d| d.join("companion-position.json"))
}

fn load_or_cached_anchor(app: &tauri::AppHandle) -> Option<CompanionAnchor> {
    if let Ok(guard) = COMPANION_ANCHOR.lock() {
        if let Some(anchor) = *guard {
            return Some(anchor);
        }
    }
    let path = anchor_path(app)?;
    let bytes = fs::read(path).ok()?;
    let anchor: CompanionAnchor = serde_json::from_slice(&bytes).ok()?;
    if let Ok(mut guard) = COMPANION_ANCHOR.lock() {
        *guard = Some(anchor);
    }
    Some(anchor)
}

fn persist_anchor(app: &tauri::AppHandle, anchor: CompanionAnchor) {
    if let Ok(mut guard) = COMPANION_ANCHOR.lock() {
        if *guard == Some(anchor) {
            return;
        }
        *guard = Some(anchor);
    }
    if let Some(path) = anchor_path(app) {
        if let Ok(bytes) = serde_json::to_vec(&anchor) {
            let _ = fs::write(path, bytes);
        }
    }
}

fn clamp_anchor_to_monitors(window: &tauri::WebviewWindow, anchor: CompanionAnchor) -> CompanionAnchor {
    let mut monitors = window.available_monitors().unwrap_or_default();
    if monitors.is_empty() {
        if let Ok(Some(primary)) = window.primary_monitor() {
            monitors.push(primary);
        }
    }
    if monitors.is_empty() {
        return anchor;
    }
    let probe_x = anchor.right - 36;
    let probe_y = anchor.bottom - 36;
    let chosen = monitors
        .iter()
        .find(|m| {
            let a = m.work_area();
            let left = a.position.x;
            let top = a.position.y;
            let right = left + a.size.width as i32;
            let bottom = top + a.size.height as i32;
            probe_x >= left && probe_x <= right && probe_y >= top && probe_y <= bottom
        })
        .or_else(|| {
            monitors.iter().min_by_key(|m| {
                let a = m.work_area();
                let cx = a.position.x + a.size.width as i32 / 2;
                let cy = a.position.y + a.size.height as i32 / 2;
                (cx - probe_x).saturating_pow(2) + (cy - probe_y).saturating_pow(2)
            })
        });
    let Some(monitor) = chosen else {
        return anchor;
    };
    let area = monitor.work_area();
    let min_right = area.position.x + 64;
    let max_right = area.position.x + area.size.width as i32;
    let min_bottom = area.position.y + 64;
    let max_bottom = area.position.y + area.size.height as i32;
    CompanionAnchor {
        right: anchor.right.clamp(min_right, max_right.max(min_right)),
        bottom: anchor.bottom.clamp(min_bottom, max_bottom.max(min_bottom)),
    }
}

pub fn save_anchor_on_move(
    app: &tauri::AppHandle,
    window: &tauri::WebviewWindow,
    pos: tauri::PhysicalPosition<i32>,
) {
    if COMPANION_RESIZING.load(std::sync::atomic::Ordering::Acquire) {
        return;
    }
    let Ok(size) = window.outer_size() else {
        return;
    };
    if size.width == 0 || size.height == 0 {
        return;
    }
    let anchor = CompanionAnchor {
        right: pos.x + size.width as i32,
        bottom: pos.y + size.height as i32,
    };
    persist_anchor(app, anchor);
}

pub fn resize_companion_anchored(
    app: &tauri::AppHandle,
    window: &tauri::WebviewWindow,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let scale = window.scale_factor().map_err(|e| e.to_string())?;
    let position = window.outer_position().map_err(|e| e.to_string())?;
    let size = window.outer_size().map_err(|e| e.to_string())?;
    let new_width = (width.clamp(40.0, 640.0) * scale).round() as u32;
    let new_height = (height.clamp(40.0, 900.0) * scale).round() as u32;
    let anchor = load_or_cached_anchor(app).unwrap_or(CompanionAnchor {
        right: position.x + size.width as i32,
        bottom: position.y + size.height as i32,
    });
    let target_x = anchor.right - new_width as i32;
    let target_y = anchor.bottom - new_height as i32;
    if new_width == size.width && new_height == size.height && position.x == target_x && position.y == target_y {
        return Ok(());
    }
    COMPANION_RESIZING.store(true, std::sync::atomic::Ordering::Release);
    #[cfg(windows)]
    if let Ok(hwnd) = window.hwnd() {
        set_window_rect_no_activate(hwnd.0 as isize, target_x, target_y, new_width as i32, new_height as i32);
    } else {
        let _ = window.set_size(tauri::PhysicalSize::new(new_width, new_height));
        let _ = window.set_position(tauri::PhysicalPosition::new(target_x, target_y));
    }
    #[cfg(not(windows))]
    {
        let _ = window.set_size(tauri::PhysicalSize::new(new_width, new_height));
        let _ = window.set_position(tauri::PhysicalPosition::new(target_x, target_y));
    }
    COMPANION_RESIZING.store(false, std::sync::atomic::Ordering::Release);
    Ok(())
}

/// Collapsed companion size in logical pixels; the page resizes it as content changes.
const COMPANION_WIDTH: f64 = 150.0;
const COMPANION_HEIGHT: f64 = 104.0;

pub async fn ensure_companion_window(
    app: &tauri::AppHandle,
    visible: bool,
    focus: bool,
) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("companion") {
        if visible {
            let _ = window.show();
            if focus {
                let _ = window.set_focus();
            }
        } else {
            let _ = window.hide();
        }
        return Ok(());
    }
    if !visible {
        return Ok(());
    }
    let build_app = app.clone();
    let window = tauri::async_runtime::spawn_blocking(move || {
        tauri::WebviewWindowBuilder::new(
            &build_app,
            "companion",
            tauri::WebviewUrl::App("companion.html".into()),
        )
        .title("TokenBar 任务宠物")
        .inner_size(COMPANION_WIDTH, COMPANION_HEIGHT)
        .transparent(true)
        .shadow(false)
        .decorations(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build()
        .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())??;

    if let Ok(size) = window.outer_size() {
        let anchor = if let Some(saved) = load_or_cached_anchor(app) {
            clamp_anchor_to_monitors(&window, saved)
        } else if let Ok(Some(monitor)) = window.primary_monitor() {
            let area = monitor.work_area();
            CompanionAnchor {
                right: area.position.x + area.size.width as i32 - 12,
                bottom: area.position.y + area.size.height as i32 - 96,
            }
        } else {
            CompanionAnchor {
                right: 1200,
                bottom: 800,
            }
        };
        if let Ok(mut guard) = COMPANION_ANCHOR.lock() {
            *guard = Some(anchor);
        }
        COMPANION_RESIZING.store(true, std::sync::atomic::Ordering::Release);
        let _ = window.set_position(tauri::PhysicalPosition::new(
            anchor.right - size.width as i32,
            anchor.bottom - size.height as i32,
        ));
        COMPANION_RESIZING.store(false, std::sync::atomic::Ordering::Release);
    }
    let _ = window.show();
    if focus {
        let _ = window.set_focus();
    }
    Ok(())
}
