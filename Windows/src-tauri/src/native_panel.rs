#![cfg(windows)]

//! Small Win32/GDI panel used to compare a native Windows surface with the
//! existing WebView panel. The statistics and synchronization stay in the
//! Rust application state; this module only paints a native view of it.

use crate::{sync::Remote, Dashboard};
use std::{
    mem::{size_of, zeroed},
    ptr::{null, null_mut},
    sync::{
        atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering},
        Arc, OnceLock, RwLock,
    },
};
use tauri::{AppHandle, Emitter};
use tokenbar_helper::{SessionSummary, TokenBreakdown};
use windows_sys::Win32::{
    Foundation::{HWND, HINSTANCE, LPARAM, LRESULT, POINT, RECT, WPARAM},
    Graphics::Gdi::{
        BeginPaint, CreateFontW, CreatePen, CreateSolidBrush, DeleteObject, DrawTextW, EndPaint,
        FillRect, GetMonitorInfoW, InvalidateRect, LineTo, MONITORINFO, MonitorFromPoint, MoveToEx,
        PAINTSTRUCT, SaveDC, ScreenToClient, SelectObject, SetBkMode, SetTextColor, UpdateWindow, CLEARTYPE_QUALITY,
        DEFAULT_CHARSET, DT_END_ELLIPSIS, DT_LEFT, DT_SINGLELINE, DT_VCENTER, FW_BOLD, FW_NORMAL,
        HBRUSH, HDC, HFONT, HPEN, PS_SOLID, TRANSPARENT, MONITOR_DEFAULTTONEAREST,
    },
    UI::Controls::SetScrollInfo,
    System::{LibraryLoader::GetModuleHandleW, Registry::*},
    UI::HiDpi::{GetWindowDpiAwarenessContext, SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2},
    UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetClientRect,
        FindWindowW, GetCursorPos, GetMessageW, GetScrollInfo, GetWindowLongPtrW, LoadCursorW, PostMessageW,
        PostQuitMessage, RegisterClassW, SendMessageW, SetForegroundWindow, SetWindowLongPtrW,
        SetWindowPos, SetWindowTextW, ShowWindow, TranslateMessage, WNDCLASSW, CREATESTRUCTW, GWLP_USERDATA,
        IDC_ARROW, HTCAPTION, SB_BOTTOM, SB_LINEDOWN, SB_LINEUP, SB_PAGEDOWN, SB_TOP,
        SB_PAGEUP, SB_THUMBPOSITION, SB_THUMBTRACK, SB_VERT, SCROLLINFO, SIF_PAGE, SIF_POS,
        SIF_RANGE, SW_HIDE, SW_SHOW, SWP_NOZORDER, WM_APP, WM_CLOSE, WM_SETFONT,
        WM_DESTROY, WM_ERASEBKGND, WM_LBUTTONUP, WM_MOUSEWHEEL, WM_NCCREATE, WM_NCHITTEST,
        WM_NCDESTROY, WM_PAINT, WM_VSCROLL, WS_BORDER, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
        WS_CHILD, WS_VSCROLL, WS_VISIBLE, ES_AUTOVSCROLL, ES_MULTILINE, ES_READONLY,
        WS_EX_CLIENTEDGE,
    },
};

const SHOW: u32 = WM_APP + 60;
const HIDE: u32 = WM_APP + 61;
const UPDATE: u32 = WM_APP + 62;
const HEADER: i32 = 54;
const FOOTER: i32 = 44;
const WIDTH: i32 = 430;
const HEIGHT: i32 = 720;
const CLASS_MANAGER: &str = "TokenBarNativePanelManager";
const CLASS_PANEL: &str = "TokenBarNativePanel";

static CONTROLLER: OnceLock<Controller> = OnceLock::new();

#[derive(Default)]
struct PanelData {
    dashboard: Option<Dashboard>,
    scroll: i32,
}

struct Shared {
    data: RwLock<PanelData>,
    manager: AtomicUsize,
    content_height: AtomicI32,
    show_requested: AtomicBool,
}

#[derive(Clone)]
struct Controller {
    shared: Arc<Shared>,
}

struct Native {
    shared: Arc<Shared>,
    app: AppHandle,
    manager: HWND,
    panel: HWND,
    panel_context: Option<Box<PanelHost>>,
}

struct PanelHost {
    shared: Arc<Shared>,
    app: AppHandle,
    content: HWND,
    content_font: HFONT,
}

impl Drop for PanelHost {
    fn drop(&mut self) {
        if !self.content_font.is_null() {
            unsafe {
                DeleteObject(self.content_font as _);
            }
        }
    }
}

pub fn start(app: AppHandle) {
    crate::diagnostics::record("native-panel-start", serde_json::json!({}));
    let controller = Controller {
        shared: Arc::new(Shared {
            data: RwLock::new(PanelData::default()),
            manager: AtomicUsize::new(0),
            content_height: AtomicI32::new(0),
            show_requested: AtomicBool::new(false),
        }),
    };
    if CONTROLLER.set(controller.clone()).is_err() {
        return;
    }
    let shared = controller.shared.clone();
    let _ = std::thread::Builder::new()
        .name("tokenbar-native-panel".into())
        .spawn(move || unsafe { run(shared, app) });
}

pub fn update(dashboard: &Dashboard) {
    let Some(controller) = CONTROLLER.get() else { return };
    let mut data = controller
        .shared
        .data
        .write()
        .unwrap_or_else(|e| e.into_inner());
    data.dashboard = Some(dashboard.clone());
    post(&controller.shared, UPDATE);
}

pub fn show() {
    let Some(controller) = CONTROLLER.get() else { return };
    controller.shared.show_requested.store(true, Ordering::Release);
    post(&controller.shared, SHOW);
}

pub fn stop() {
    if let Some(controller) = CONTROLLER.get() {
        controller.shared.show_requested.store(false, Ordering::Release);
        let manager = controller.shared.manager.load(Ordering::Acquire);
        if manager != 0 {
            unsafe { PostMessageW(manager as HWND, WM_CLOSE, 0, 0) };
        }
    }
}

unsafe fn run(shared: Arc<Shared>, app: AppHandle) {
    // The main Tauri thread and a newly-created Win32 thread can carry
    // different DPI awareness contexts. Set this explicitly so the 430x720
    // logical panel is drawn at the same scale as the rest of the desktop.
    let dpi_context = {
        let reference = FindWindowW(wide("Tauri Window").as_ptr(), wide("TokenBar").as_ptr());
        if reference.is_null() {
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        } else {
            GetWindowDpiAwarenessContext(reference)
        }
    };
    SetThreadDpiAwarenessContext(dpi_context);
    let instance = GetModuleHandleW(null());
    register_class(instance, CLASS_MANAGER, Some(manager_proc));
    register_class(instance, CLASS_PANEL, Some(panel_proc));
    let mut native = Box::new(Native {
        shared: shared.clone(),
        app,
        manager: null_mut(),
        panel: null_mut(),
        panel_context: None,
    });
    let pointer: *mut Native = &mut *native;
    let manager = CreateWindowExW(
        0,
        wide(CLASS_MANAGER).as_ptr(),
        wide("TokenBar native panel manager").as_ptr(),
        WS_POPUP,
        0,
        0,
        0,
        0,
        HWND_MESSAGE,
        null_mut(),
        instance,
        pointer.cast(),
    );
    if manager.is_null() {
        crate::diagnostics::record("native-panel-manager-failed", serde_json::json!({}));
        return;
    }
    crate::diagnostics::record("native-panel-manager-ready", serde_json::json!({}));
    native.manager = manager;
    shared.manager.store(manager as usize, Ordering::Release);
    if shared.show_requested.load(Ordering::Acquire) {
        native.show_panel();
    }
    let mut message: MSG = zeroed();
    while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    native.destroy_panel();
    shared.manager.store(0, Ordering::Release);
}

unsafe fn register_class(instance: HINSTANCE, name: &str, procedure: WNDPROC) {
    let class_name = wide(name);
    let class = WNDCLASSW {
        lpfnWndProc: procedure,
        hInstance: instance,
        hCursor: LoadCursorW(null_mut(), IDC_ARROW),
        lpszClassName: class_name.as_ptr(),
        ..zeroed()
    };
    RegisterClassW(&class);
}

fn post(shared: &Shared, message: u32) {
    let manager = shared.manager.load(Ordering::Acquire);
    if manager != 0 {
        unsafe {
            PostMessageW(manager as HWND, message, 0, 0);
        }
    }
}

impl Native {
    unsafe fn show_panel(&mut self) {
        if self.panel.is_null() {
            let mut host = Box::new(PanelHost {
                shared: self.shared.clone(),
                app: self.app.clone(),
                content: null_mut(),
                content_font: null_mut(),
            });
            let pointer: *mut PanelHost = &mut *host;
            self.panel = CreateWindowExW(
                WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
                wide(CLASS_PANEL).as_ptr(),
                wide("TokenBar").as_ptr(),
                WS_POPUP | WS_BORDER | WS_VSCROLL,
                0,
                0,
                WIDTH,
                HEIGHT,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                pointer.cast(),
            );
            if self.panel.is_null() {
                crate::diagnostics::record("native-panel-create-failed", serde_json::json!({}));
                return;
            }
            crate::diagnostics::record("native-panel-created", serde_json::json!({}));
            host.content_font = font(13, false);
            let initial_text = wide("正在读取同步数据…");
            host.content = CreateWindowExW(
                WS_EX_CLIENTEDGE,
                wide("EDIT").as_ptr(),
                initial_text.as_ptr(),
                WS_CHILD
                    | WS_VISIBLE
                    | ES_MULTILINE as u32
                    | ES_AUTOVSCROLL as u32
                    | ES_READONLY as u32
                    | WS_VSCROLL,
                14,
                HEADER,
                WIDTH - 28,
                HEIGHT - HEADER - FOOTER,
                self.panel,
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            );
            if host.content.is_null() {
                DeleteObject(host.content_font as _);
                DestroyWindow(self.panel);
                self.panel = null_mut();
                return;
            }
            SendMessageW(host.content, WM_SETFONT, host.content_font as usize, 1);
            self.panel_context = Some(host);
        }
        self.update_panel_text();
        let (x, y) = panel_position();
        SetWindowPos(
            self.panel,
            HWND_TOPMOST,
            x,
            y,
            WIDTH,
            HEIGHT,
            SWP_NOZORDER,
        );
        ShowWindow(self.panel, SW_SHOW);
        SetForegroundWindow(self.panel);
        UpdateWindow(self.panel);
        InvalidateRect(self.panel, null(), 0);
    }

    unsafe fn hide_panel(&self) {
        if !self.panel.is_null() {
            ShowWindow(self.panel, SW_HIDE);
        }
    }

    unsafe fn destroy_panel(&mut self) {
        if !self.panel.is_null() {
            DestroyWindow(self.panel);
        }
        self.panel = null_mut();
        self.panel_context = None;
    }

    unsafe fn update_panel_text(&self) {
        let Some(host) = self.panel_context.as_ref() else { return };
        if host.content.is_null() { return; }
        let data = self.shared.data.read().unwrap_or_else(|e| e.into_inner());
        let text = data
            .dashboard
            .as_ref()
            .map(panel_text)
            .unwrap_or_else(|| "正在读取本地活动…".into());
        let ok = SetWindowTextW(host.content, wide(&text).as_ptr());
        crate::diagnostics::record("native-panel-text", serde_json::json!({
            "ok": ok != 0,
            "chars": text.chars().count(),
        }));
    }
}

unsafe extern "system" fn manager_proc(hwnd: HWND, message: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    if message == WM_NCCREATE {
        let create = &*(l as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
    }
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Native;
    if !pointer.is_null() {
        match message {
            SHOW => {
                (*pointer).show_panel();
                return 0;
            }
            HIDE => {
                (*pointer).hide_panel();
                return 0;
            }
            UPDATE => {
                (*pointer).update_panel_text();
                if !(*pointer).panel.is_null() {
                    InvalidateRect((*pointer).panel, null(), 0);
                }
                return 0;
            }
            WM_CLOSE => {
                (*pointer).destroy_panel();
                DestroyWindow(hwnd);
                return 0;
            }
            WM_DESTROY => {
                PostQuitMessage(0);
                return 0;
            }
            WM_NCDESTROY => {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
                return 0;
            }
            _ => {}
        }
    }
    DefWindowProcW(hwnd, message, w, l)
}

unsafe extern "system" fn panel_proc(hwnd: HWND, message: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    if message == WM_NCCREATE {
        let create = &*(l as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
    }
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut PanelHost;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, message, w, l);
    }
    let host = &*pointer;
    match message {
        WM_PAINT => {
            paint(hwnd, &host.shared);
            0
        }
        WM_ERASEBKGND => 1,
        WM_NCHITTEST => {
            let mut point = POINT {
                x: loword(l),
                y: hiword(l),
            };
            ScreenToClient(hwnd, &mut point);
            if point.y < HEADER && point.x < WIDTH - 58 {
                HTCAPTION as isize
            } else {
                DefWindowProcW(hwnd, message, w, l)
            }
        }
        WM_MOUSEWHEEL => {
            let delta = ((w >> 16) as i16) as i32;
            adjust_scroll(&host.shared, -delta / 2);
            InvalidateRect(hwnd, null(), 0);
            0
        }
        WM_VSCROLL => {
            let amount = match (w & 0xffff) as i32 {
                SB_LINEUP => -24,
                SB_LINEDOWN => 24,
                SB_PAGEUP => -480,
                SB_PAGEDOWN => 480,
                SB_TOP => -10_000,
                SB_BOTTOM => 10_000,
                SB_THUMBPOSITION | SB_THUMBTRACK => {
                    let mut info: SCROLLINFO = zeroed();
                    info.cbSize = size_of::<SCROLLINFO>() as u32;
                    info.fMask = SIF_POS;
                    GetScrollInfo(hwnd, SB_VERT, &mut info);
                    let current = host
                        .shared
                        .data
                        .read()
                        .unwrap_or_else(|e| e.into_inner())
                        .scroll;
                    info.nTrackPos - current
                }
                _ => 0,
            };
            adjust_scroll(&host.shared, amount);
            InvalidateRect(hwnd, null(), 0);
            0
        }
        WM_LBUTTONUP => {
            let x = loword(l);
            let y = hiword(l);
            if y < HEADER && x >= WIDTH - 58 {
                host.shared.show_requested.store(false, Ordering::Release);
                post(&host.shared, HIDE);
            } else if y >= HEIGHT - FOOTER {
                if x < 115 {
                    tauri::async_runtime::spawn(crate::refresh(host.app.clone()));
                } else if x >= WIDTH - 105 {
                    host.shared.show_requested.store(false, Ordering::Release);
                    post(&host.shared, HIDE);
                    crate::show(&host.app);
                    let _ = host.app.emit("open-settings", ());
                }
            }
            0
        }
        WM_CLOSE => {
            host.shared.show_requested.store(false, Ordering::Release);
            post(&host.shared, HIDE);
            0
        }
        WM_NCDESTROY => {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            return 0;
        }
        _ => DefWindowProcW(hwnd, message, w, l),
    }
}

unsafe fn paint(hwnd: HWND, shared: &Shared) {
    let mut paint: PAINTSTRUCT = zeroed();
    let dc = BeginPaint(hwnd, &mut paint);
    let mut client: RECT = zeroed();
    GetClientRect(hwnd, &mut client);
    let light = light_theme();
    let colors = Colors::new(light);
    fill(dc, client, colors.background);
    let (dashboard, scroll) = {
        let data = shared.data.read().unwrap_or_else(|e| e.into_inner());
        (data.dashboard.clone(), data.scroll)
    };
    let mut title_rect = RECT { left: 20, top: 13, right: WIDTH - 60, bottom: 43 };
    draw(dc, "TokenBar", &mut title_rect, 20, true, colors.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    let mut close_rect = RECT { left: WIDTH - 48, top: 14, right: WIDTH - 16, bottom: 44 };
    draw(dc, "×", &mut close_rect, 22, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    line(dc, 0, HEADER - 1, WIDTH, HEADER - 1, colors.border);

    SaveDC(dc);
    let body_bottom = client.bottom - FOOTER;
    windows_sys::Win32::Graphics::Gdi::IntersectClipRect(dc, 0, HEADER, WIDTH, body_bottom);
    let mut y = HEADER + 16 - scroll;
    let content_height = if let Some(dashboard) = dashboard.as_ref() {
        draw_dashboard(dc, dashboard, &mut y, &colors);
        y + 18 + scroll
    } else {
        let mut rect = RECT { left: 20, top: y, right: WIDTH - 20, bottom: y + 32 };
        draw(dc, "正在读取本地活动…", &mut rect, 14, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        y + 80 + scroll
    };
    windows_sys::Win32::Graphics::Gdi::RestoreDC(dc, -1);
    shared.content_height.store(content_height.max(0), Ordering::Release);
    set_scrollbar(hwnd, content_height, body_bottom - HEADER, scroll);

    line(dc, 0, body_bottom, WIDTH, body_bottom, colors.border);
    let mut refresh = RECT { left: 18, top: body_bottom + 7, right: 125, bottom: body_bottom + 37 };
    draw(dc, "↻  刷新", &mut refresh, 12, false, colors.accent, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    let mut settings = RECT { left: WIDTH - 105, top: body_bottom + 7, right: WIDTH - 16, bottom: body_bottom + 37 };
    draw(dc, "设置", &mut settings, 12, false, colors.accent, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    EndPaint(hwnd, &paint);
}

unsafe fn draw_dashboard(dc: HDC, dashboard: &Dashboard, y: &mut i32, colors: &Colors) {
    let mut status = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 24 };
    draw(dc, &format!("同步  {}", dashboard.sync_status), &mut status, 12, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    *y += 28;
    let mut devices = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 24 };
    draw(dc, &format!("全部设备  ·  本机 + {} 台其他设备", dashboard.remote_snapshots.len()), &mut devices, 12, false, colors.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    *y += 34;
    line(dc, 20, *y, WIDTH - 20, *y, colors.border);
    *y += 18;

    if let Some(snapshot) = dashboard.snapshot.as_ref() {
        section_heading(dc, "Today", y, colors);
        let total = total(&snapshot.today.tokens);
        let mut total_rect = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 34 };
        draw(dc, &format!("{} tokens", compact(total)), &mut total_rect, 24, true, colors.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        *y += 40;
        let price = if snapshot.today.cost_usd > 0.0 { format!("~${:.2}", snapshot.today.cost_usd) } else { "—".into() };
        draw_pair(dc, "Input", compact(snapshot.today.tokens.input + snapshot.today.tokens.cache_write), "Output", compact(snapshot.today.tokens.output), y, colors);
        *y += 27;
        draw_pair(dc, "Cache", compact(snapshot.today.tokens.cache_read), "Reasoning", compact(snapshot.today.tokens.reasoning), y, colors);
        *y += 27;
        let mut cost_rect = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 22 };
        draw(dc, &format!("{} sessions · {} turns", snapshot.today.session_count, snapshot.today.request_count), &mut cost_rect, 11, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        let mut price_rect = RECT { left: WIDTH - 115, top: *y, right: WIDTH - 20, bottom: *y + 22 };
        draw(dc, &price, &mut price_rect, 12, false, colors.cost, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        *y += 40;

        section_heading(dc, "Quota", y, colors);
        if let Some(quota) = dashboard.quotas.get("codex") {
            if let Some(weekly) = quota.weekly.as_ref() {
                draw_quota(dc, "Weekly", weekly.used_percent, y, colors);
                *y += 29;
            }
            if let Some(session) = quota.session.as_ref() {
                draw_quota(dc, "5-hour", session.used_percent, y, colors);
                *y += 29;
            }
        } else {
            let mut rect = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 22 };
            draw(dc, "额度等待更新", &mut rect, 11, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
            *y += 28;
        }
        *y += 10;

        section_heading(dc, "Recent Sessions", y, colors);
        *y += 3;
        for session in snapshot.sessions.iter().take(dashboard.settings.recent_limit) {
            draw_session(dc, session, y, colors);
        }
        if snapshot.sessions.is_empty() {
            let mut rect = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 22 };
            draw(dc, "还没有会话记录", &mut rect, 11, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
            *y += 28;
        }
    } else {
        let mut rect = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 22 };
        draw(dc, "正在读取本地统计…", &mut rect, 13, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        *y += 32;
    }

    if !dashboard.remote_snapshots.is_empty() {
        *y += 10;
        section_heading(dc, "同步设备", y, colors);
        for remote in &dashboard.remote_snapshots {
            draw_remote(dc, remote, y, colors);
        }
    }
}

unsafe fn draw_session(dc: HDC, session: &SessionSummary, y: &mut i32, colors: &Colors) {
    let title = session.title.as_deref().filter(|v| !v.is_empty()).unwrap_or("未命名会话");
    let mut title_rect = RECT { left: 20, top: *y, right: WIDTH - 145, bottom: *y + 22 };
    draw(dc, title, &mut title_rect, 12, false, colors.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    let mut usage = RECT { left: WIDTH - 140, top: *y, right: WIDTH - 20, bottom: *y + 22 };
    draw(dc, &format!("{}  {}", compact(total(&session.tokens)), cost(session.cost_usd)), &mut usage, 11, false, colors.cost, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    *y += 21;
    let mut detail = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 20 };
    draw(dc, &session_models(session), &mut detail, 10, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    *y += 26;
}

unsafe fn draw_remote(dc: HDC, remote: &Remote, y: &mut i32, colors: &Colors) {
    let mut rect = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 22 };
    draw(dc, &format!("{}  ·  {} sessions", remote.device_name, remote.snapshot.sessions.len()), &mut rect, 11, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    *y += 24;
}

unsafe fn draw_pair(dc: HDC, left: &str, left_value: String, right: &str, right_value: String, y: &i32, colors: &Colors) {
    let mut a = RECT { left: 20, top: *y, right: WIDTH / 2 - 8, bottom: *y + 21 };
    draw(dc, &format!("{}  {}", left, left_value), &mut a, 11, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    let mut b = RECT { left: WIDTH / 2 + 8, top: *y, right: WIDTH - 20, bottom: *y + 21 };
    draw(dc, &format!("{}  {}", right, right_value), &mut b, 11, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
}

unsafe fn draw_quota(dc: HDC, label: &str, used: f64, y: &i32, colors: &Colors) {
    let mut text = RECT { left: 20, top: *y, right: WIDTH - 150, bottom: *y + 20 };
    draw(dc, label, &mut text, 11, false, colors.muted, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    let mut value = RECT { left: WIDTH - 140, top: *y, right: WIDTH - 20, bottom: *y + 20 };
    draw(dc, &format!("{:.0}% left", (100.0 - used).clamp(0.0, 100.0)), &mut value, 11, false, colors.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    let width = WIDTH - 40;
    let fill_width = ((100.0 - used).clamp(0.0, 100.0) / 100.0 * width as f64) as i32;
    let bar = RECT { left: 20, top: *y + 22, right: WIDTH - 20, bottom: *y + 28 };
    fill(dc, bar, colors.border);
    let fill_rect = RECT { left: 20, top: *y + 22, right: 20 + fill_width, bottom: *y + 28 };
    fill(dc, fill_rect, colors.accent);
}

unsafe fn section_heading(dc: HDC, title: &str, y: &mut i32, colors: &Colors) {
    let mut rect = RECT { left: 20, top: *y, right: WIDTH - 20, bottom: *y + 25 };
    draw(dc, title, &mut rect, 15, true, colors.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    *y += 30;
}

fn session_models(session: &SessionSummary) -> String {
    let mut values = Vec::new();
    for request in &session.requests {
        let effort = request.reasoning_effort.as_deref().unwrap_or("未记录");
        let value = format!("{} · effort: {}", request.model, effort);
        if !values.contains(&value) {
            values.push(value);
        }
        if values.len() >= 3 {
            break;
        }
    }
    if values.is_empty() {
        session.models.join(" / ")
    } else {
        values.join(" / ")
    }
}

fn total(tokens: &TokenBreakdown) -> i64 {
    tokens
        .input
        .saturating_add(tokens.output)
        .saturating_add(tokens.cache_read)
        .saturating_add(tokens.cache_write)
        .saturating_add(tokens.reasoning)
}

fn compact(value: i64) -> String {
    match value {
        v if v >= 1_000_000_000 => format!("{:.1}B", v as f64 / 1_000_000_000.0),
        v if v >= 1_000_000 => format!("{:.1}M", v as f64 / 1_000_000.0),
        v if v >= 1_000 => format!("{:.1}K", v as f64 / 1_000.0),
        v => v.max(0).to_string(),
    }
}

fn cost(value: f64) -> String {
    if value.is_finite() && value > 0.0 {
        format!("~${value:.2}")
    } else {
        "—".into()
    }
}

fn panel_text(dashboard: &Dashboard) -> String {
    let mut lines = vec![
        "TokenBar · 原生 Win32 面板试用".to_string(),
        format!("同步：{}", dashboard.sync_status),
        format!("设备：本机 + {} 台其他设备", dashboard.remote_snapshots.len()),
        String::new(),
    ];
    if let Some(snapshot) = dashboard.snapshot.as_ref() {
        lines.push(format!(
            "Today   {} tokens   {}",
            compact(total(&snapshot.today.tokens)),
            cost(snapshot.today.cost_usd)
        ));
        lines.push(format!(
            "Input       {}        Output      {}",
            compact(snapshot.today.tokens.input + snapshot.today.tokens.cache_write),
            compact(snapshot.today.tokens.output)
        ));
        lines.push(format!(
            "Cache       {}        Reasoning   {}",
            compact(snapshot.today.tokens.cache_read),
            compact(snapshot.today.tokens.reasoning)
        ));
        lines.push(format!(
            "{} sessions · {} turns",
            snapshot.today.session_count, snapshot.today.request_count
        ));
        lines.push(String::new());
        lines.push("Quota".into());
        if let Some(quota) = dashboard.quotas.get("codex") {
            if let Some(window) = quota.weekly.as_ref() {
                lines.push(format!(
                    "Weekly      {:.0}% left",
                    (100.0 - window.used_percent).clamp(0.0, 100.0)
                ));
            }
            if let Some(window) = quota.session.as_ref() {
                lines.push(format!(
                    "5-hour      {:.0}% left",
                    (100.0 - window.used_percent).clamp(0.0, 100.0)
                ));
            }
        }
        lines.push(String::new());
        lines.push("Recent Sessions".into());
        for session in snapshot
            .sessions
            .iter()
            .take(dashboard.settings.recent_limit)
        {
            let title = session
                .title
                .as_deref()
                .filter(|v| !v.is_empty())
                .unwrap_or("未命名会话");
            lines.push(format!(
                "{}  ·  {}  {}",
                title,
                compact(total(&session.tokens)),
                cost(session.cost_usd)
            ));
            lines.push(format!("    {}", session_models(session)));
        }
    } else {
        lines.push("正在读取本地统计…".into());
    }
    if !dashboard.remote_snapshots.is_empty() {
        lines.push(String::new());
        lines.push("同步设备".into());
        for remote in &dashboard.remote_snapshots {
            lines.push(format!(
                "{}  ·  {} sessions",
                remote.device_name,
                remote.snapshot.sessions.len()
            ));
        }
    }
    lines.join("\r\n")
}

fn adjust_scroll(shared: &Shared, delta: i32) {
    let max = (shared.content_height.load(Ordering::Acquire) - (HEIGHT - HEADER - FOOTER)).max(0);
    let mut data = shared.data.write().unwrap_or_else(|e| e.into_inner());
    data.scroll = (data.scroll + delta).clamp(0, max);
}

unsafe fn set_scrollbar(hwnd: HWND, content_height: i32, page: i32, position: i32) {
    let mut info: SCROLLINFO = zeroed();
    info.cbSize = size_of::<SCROLLINFO>() as u32;
    info.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    info.nMin = 0;
    info.nMax = content_height.max(page);
    info.nPage = page.max(0) as u32;
    info.nPos = position.max(0);
    SetScrollInfo(hwnd, SB_VERT, &info, 1);
}

struct Colors {
    background: u32,
    text: u32,
    muted: u32,
    border: u32,
    accent: u32,
    cost: u32,
}
impl Colors {
    fn new(light: bool) -> Self {
        if light {
            Self { background: 0x00FAFAFA, text: 0x00292929, muted: 0x00828282, border: 0x00DEDEDE, accent: 0x0023784A, cost: 0x00C52847 }
        } else {
            Self { background: 0x00252525, text: 0x00EDEDED, muted: 0x00AAAAAA, border: 0x00454545, accent: 0x0093DFB7, cost: 0x00E58AA0 }
        }
    }
}

unsafe fn draw(dc: HDC, text: &str, rect: &mut RECT, size: i32, bold: bool, color: u32, flags: u32) {
    let font = font(size, bold);
    let old = SelectObject(dc, font as _);
    SetTextColor(dc, color);
    SetBkMode(dc, TRANSPARENT as i32);
    DrawTextW(dc, wide(text).as_ptr(), -1, rect, flags);
    SelectObject(dc, old);
    DeleteObject(font as _);
}

unsafe fn font(size: i32, bold: bool) -> HFONT {
    CreateFontW(
        -size,
        0,
        0,
        0,
        if bold { FW_BOLD as i32 } else { FW_NORMAL as i32 },
        0,
        0,
        0,
        DEFAULT_CHARSET as u32,
        0,
        0,
        CLEARTYPE_QUALITY as u32,
        0,
        wide("Segoe UI").as_ptr(),
    )
}

unsafe fn fill(dc: HDC, rect: RECT, color: u32) {
    let brush: HBRUSH = CreateSolidBrush(color);
    FillRect(dc, &rect, brush);
    DeleteObject(brush as _);
}

unsafe fn line(dc: HDC, x1: i32, y1: i32, x2: i32, y2: i32, color: u32) {
    let pen: HPEN = CreatePen(PS_SOLID, 1, color);
    let old = SelectObject(dc, pen as _);
    MoveToEx(dc, x1, y1, null_mut());
    LineTo(dc, x2, y2);
    SelectObject(dc, old);
    DeleteObject(pen as _);
}

unsafe fn panel_position() -> (i32, i32) {
    let mut cursor = POINT { x: 0, y: 0 };
    GetCursorPos(&mut cursor);
    let monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    let mut info: MONITORINFO = zeroed();
    info.cbSize = size_of::<MONITORINFO>() as u32;
    if !monitor.is_null() && GetMonitorInfoW(monitor, &mut info) != 0 {
        (
            (info.rcWork.right - WIDTH - 14).max(info.rcWork.left),
            (info.rcWork.bottom - HEIGHT - 12).max(info.rcWork.top),
        )
    } else {
        (100, 100)
    }
}

unsafe fn light_theme() -> bool {
    let mut value = 1u32;
    let mut bytes = size_of::<u32>() as u32;
    RegGetValueW(
        HKEY_CURRENT_USER,
        wide("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize").as_ptr(),
        wide("AppsUseLightTheme").as_ptr(),
        RRF_RT_REG_DWORD,
        null_mut(),
        (&mut value as *mut u32).cast(),
        &mut bytes,
    );
    value != 0
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

fn loword(value: LPARAM) -> i32 {
    (value as u32 as u16 as i16) as i32
}
fn hiword(value: LPARAM) -> i32 {
    (((value as u32 >> 16) as u16) as i16) as i32
}

// The raw Win32 aliases are kept local so this module does not affect the
// existing taskbar implementation on other platforms.
use windows_sys::Win32::UI::WindowsAndMessaging::{MSG, WNDPROC, HWND_MESSAGE, HWND_TOPMOST};
