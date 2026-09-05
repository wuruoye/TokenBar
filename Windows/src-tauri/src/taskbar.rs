//! Native taskbar buttons. Only our own windows are created, moved and destroyed.
//! Explorer's task buttons and notification area are never resized.
use crate::Dashboard;
use serde::Serialize;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc, RwLock,
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}
impl Rect {
    pub fn width(self) -> i32 {
        self.right - self.left
    }
    pub fn height(self) -> i32 {
        self.bottom - self.top
    }
    fn intersects(self, other: Self) -> bool {
        self.left < other.right
            && self.right > other.left
            && self.top < other.bottom
            && self.bottom > other.top
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Segment {
    pub platform: String,
    pub title: String,
    pub today: String,
    pub quota: String,
    pub stale: bool,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Model {
    enabled: bool,
    left: bool,
    segments: Vec<Segment>,
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub attached: bool,
    pub message: String,
    pub rect: Option<Rect>,
    pub taskbar_rect: Option<Rect>,
    pub segment_count: usize,
    pub painted: bool,
}
struct Shared {
    model: RwLock<Model>,
    status: RwLock<Status>,
    manager: AtomicUsize,
    layout: RwLock<Option<Layout>>,
    paint_mask: AtomicUsize,
}
#[derive(Clone)]
struct Layout {
    parent: usize,
    bounds: Rect,
    occupied: Vec<Rect>,
}
#[derive(Clone)]
pub struct Controller(Arc<Shared>);
impl Controller {
    pub fn new() -> Self {
        Self(Arc::new(Shared {
            model: RwLock::new(Model::default()),
            status: RwLock::new(Status::default()),
            manager: AtomicUsize::new(0),
            layout: RwLock::new(None),
            paint_mask: AtomicUsize::new(0),
        }))
    }
    pub fn start(&self, app: tauri::AppHandle) {
        #[cfg(windows)]
        native::start(self.clone(), app);
        #[cfg(not(windows))]
        let _ = app;
    }
    pub fn update(&self, dashboard: &Dashboard) {
        *self.0.model.write().unwrap_or_else(|e| e.into_inner()) = model(dashboard);
        #[cfg(windows)]
        native::wake(self.0.manager.load(Ordering::Acquire));
    }
    pub fn status(&self) -> Status {
        self.0
            .status
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
    fn set_status(&self, value: Status) {
        *self.0.status.write().unwrap_or_else(|e| e.into_inner()) = value;
    }
    pub fn pointer_pressed(&self) -> bool {
        #[cfg(windows)]
        {
            native::pointer_pressed(self.status().rect)
        }
        #[cfg(not(windows))]
        {
            false
        }
    }
    pub fn stop(&self) {
        #[cfg(windows)]
        native::stop(self.0.manager.load(Ordering::Acquire));
    }
    #[cfg(all(windows, feature = "ui-test"))]
    pub fn test_click(&self, index: usize) {
        native::test_click(self.0.manager.load(Ordering::Acquire), index);
    }
}
fn compact(value: i64) -> String {
    match value {
        v if v >= 1_000_000_000 => format!("{:.0}B", v as f64 / 1_000_000_000.0),
        v if v >= 1_000_000 => format!("{:.0}M", v as f64 / 1_000_000.0),
        v if v >= 1_000 => format!("{:.0}K", v as f64 / 1_000.0),
        v => v.max(0).to_string(),
    }
}
fn model(dashboard: &Dashboard) -> Model {
    let settings = &dashboard.settings;
    let platforms = [("codex", "Codex"), ("claude", "Claude"), ("grok", "Grok")];
    let segments = platforms
        .into_iter()
        .filter(|(platform, _)| {
            if settings.taskbar_platform != "all" {
                return *platform == settings.taskbar_platform;
            }
            *platform == "codex"
                || (*platform == "claude" && settings.show_claude)
                || (*platform == "grok" && settings.show_grok)
        })
        .map(|(platform, title)| {
            let today = dashboard
                .snapshot
                .as_ref()
                .and_then(|s| s.sources.iter().find(|s| s.platform == platform))
                .map(|s| {
                    let t = &s.today.tokens;
                    compact(
                        t.input
                            .saturating_add(t.output)
                            .saturating_add(t.cache_read)
                            .saturating_add(t.cache_write)
                            .saturating_add(t.reasoning),
                    )
                })
                .unwrap_or_else(|| "—".into());
            let quota = dashboard.quotas.get(platform);
            let weekly = quota
                .and_then(|q| q.weekly.as_ref())
                .map(|w| format!("{:.0}%", (100.0 - w.used_percent).clamp(0.0, 100.0).round()))
                .unwrap_or_else(|| "—".into());
            Segment {
                platform: platform.into(),
                title: title.into(),
                today,
                quota: weekly,
                stale: (dashboard.error.is_some() && dashboard.snapshot.is_some())
                    || quota.is_some_and(|q| q.error.is_some() && q.weekly.is_some()),
            }
        })
        .collect();
    Model {
        enabled: settings.taskbar_enabled,
        left: settings.taskbar_position == "left",
        segments,
    }
}

/// Find a free interval without covering task buttons, widgets or the tray.
fn free_slot(
    start: i32,
    end: i32,
    occupied: &[(i32, i32)],
    desired: i32,
    minimum: i32,
    left: bool,
) -> Option<(i32, i32)> {
    if desired <= 0 || minimum <= 0 || end <= start {
        return None;
    }
    let mut intervals: Vec<_> = occupied
        .iter()
        .map(|&(a, b)| (a.max(start), b.min(end)))
        .filter(|(a, b)| b > a)
        .collect();
    intervals.sort_unstable();
    let mut gaps = Vec::new();
    let mut cursor = start;
    for (a, b) in intervals {
        if a > cursor {
            gaps.push((cursor, a));
        }
        cursor = cursor.max(b);
    }
    if cursor < end {
        gaps.push((cursor, end));
    }
    if !left {
        gaps.reverse();
    }
    let gap = gaps.iter().find(|(a, b)| b - a >= desired).or_else(|| {
        gaps.iter()
            .filter(|(a, b)| b - a >= minimum)
            .max_by_key(|(a, b)| b - a)
    })?;
    let width = desired.min(gap.1 - gap.0);
    Some((if left { gap.0 } else { gap.1 - width }, width))
}

pub fn panel_position(anchor: Rect, work: Rect, width: i32, height: i32) -> (i32, i32) {
    let gap = 8;
    let (x, y) = if anchor.bottom <= work.top {
        (anchor.left + (anchor.width() - width) / 2, work.top + gap)
    } else if anchor.right <= work.left {
        (work.left + gap, anchor.top)
    } else if anchor.left >= work.right {
        (work.right - width - gap, anchor.top)
    } else {
        (
            anchor.left + (anchor.width() - width) / 2,
            anchor.top - height - gap,
        )
    };
    (
        x.clamp(work.left, (work.right - width).max(work.left)),
        y.clamp(work.top, (work.bottom - height).max(work.top)),
    )
}
pub fn hides_on_click(visible: bool, active: &str, clicked: &str) -> bool {
    visible && active == clicked
}

fn foreign_window_obstacle(
    bounds: Rect,
    item: Rect,
    visible: bool,
    pid: u32,
    shell_pid: u32,
    own_pid: u32,
    padding: i32,
) -> Option<Rect> {
    (visible
        && pid != 0
        && pid != shell_pid
        && pid != own_pid
        && item.width() > 0
        && item.height() > 0
        && bounds.intersects(item))
    .then_some(Rect {
        left: item.left - padding,
        top: item.top - padding,
        right: item.right + padding,
        bottom: item.bottom + padding,
    })
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::{
        mem::{size_of, zeroed},
        ptr::{null, null_mut},
    };
    use windows::Win32::{
        System::Com::{
            CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
            COINIT_MULTITHREADED,
        },
        UI::Accessibility::{
            CUIAutomation, IUIAutomation, TreeScope_Descendants, UIA_BoundingRectanglePropertyId,
            UIA_ButtonControlTypeId, UIA_ControlTypePropertyId, UIA_EditControlTypeId,
            UIA_IsOffscreenPropertyId, UIA_ListItemControlTypeId, UIA_ProcessIdPropertyId,
        },
    };
    use windows_sys::Win32::{
        Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM},
        Graphics::Gdi::*,
        System::{LibraryLoader::GetModuleHandleW, Registry::*},
        UI::{
            HiDpi::{GetDpiForWindow, GetWindowDpiAwarenessContext, SetThreadDpiAwarenessContext},
            Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON},
            WindowsAndMessaging::*,
        },
    };
    const UPDATE: u32 = WM_APP + 20;
    #[cfg(feature = "ui-test")]
    const TEST_CLICK: u32 = WM_APP + 21;
    const TIMER: usize = 41;
    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }
    fn rect(rect: RECT) -> Rect {
        Rect {
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
        }
    }
    unsafe fn window_rect(hwnd: HWND) -> Option<Rect> {
        let mut value = zeroed();
        (GetWindowRect(hwnd, &mut value) != 0).then(|| rect(value))
    }

    pub fn start(controller: Controller, app: tauri::AppHandle) {
        let error_controller = controller.clone();
        if let Err(error) = std::thread::Builder::new()
            .name("tokenbar-taskbar".into())
            .spawn(move || unsafe {
                let module = GetModuleHandleW(null());
                let classes: [(&str, WNDPROC); 2] = [
                    ("TokenBarTaskbarManager", Some(manager_proc)),
                    ("TokenBarTaskbarWindow", Some(host_proc)),
                ];
                for (name, proc) in classes {
                    let name = wide(name);
                    let class = WNDCLASSW {
                        lpfnWndProc: proc,
                        hInstance: module,
                        lpszClassName: name.as_ptr(),
                        hCursor: LoadCursorW(null_mut(), IDC_ARROW),
                        ..zeroed()
                    };
                    RegisterClassW(&class);
                }
                let mut context = Box::new(Native {
                    controller: controller.clone(),
                    app,
                    host: null_mut(),
                    parent: null_mut(),
                    buttons: vec![],
                    host_context: None,
                    last_model: Model::default(),
                    last_rect: None,
                    light: true,
                });
                let pointer: *mut Native = &mut *context;
                let manager = CreateWindowExW(
                    0,
                    wide("TokenBarTaskbarManager").as_ptr(),
                    wide("TokenBar taskbar manager").as_ptr(),
                    0,
                    0,
                    0,
                    0,
                    0,
                    HWND_MESSAGE,
                    null_mut(),
                    module,
                    pointer.cast(),
                );
                if manager.is_null() {
                    controller.set_status(Status {
                        message: "无法创建任务栏显示，请使用托盘图标。".into(),
                        ..Default::default()
                    });
                } else {
                    controller
                        .0
                        .manager
                        .store(manager as usize, Ordering::Release);
                    start_layout_worker(controller.clone());
                    SetTimer(manager, TIMER, 1500, None);
                    PostMessageW(manager, UPDATE, 0, 0);
                    let mut message = zeroed();
                    while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
                        TranslateMessage(&message);
                        DispatchMessageW(&message);
                    }
                    controller.0.manager.store(0, Ordering::Release);
                }
                context.destroy_host();
                drop(context);
            })
        {
            error_controller.set_status(Status {
                message: format!("任务栏显示未启动：{error}"),
                ..Default::default()
            });
        }
    }
    fn start_layout_worker(controller: Controller) {
        // UIA must run on an MTA thread that owns no windows. Querying our
        // taskbar buttons on their message-loop thread can deadlock Win32 focus.
        let _ = std::thread::Builder::new()
            .name("tokenbar-taskbar-layout".into())
            .spawn(move || unsafe {
                if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
                    return;
                }
                let automation: Option<IUIAutomation> =
                    CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok();
                while controller.0.manager.load(Ordering::Acquire) != 0 {
                    let parent = FindWindowW(wide("Shell_TrayWnd").as_ptr(), null());
                    let layout = automation.as_ref().and_then(|automation| {
                        let bounds = window_rect(parent)?;
                        let dpi = GetDpiForWindow(parent).max(96);
                        let occupied =
                            Native::occupied(automation, parent, bounds, (5 * dpi / 96) as i32)?;
                        Some(Layout {
                            parent: parent as usize,
                            bounds,
                            occupied,
                        })
                    });
                    *controller
                        .0
                        .layout
                        .write()
                        .unwrap_or_else(|e| e.into_inner()) = layout;
                    wake(controller.0.manager.load(Ordering::Acquire));
                    std::thread::sleep(std::time::Duration::from_millis(1500));
                }
                drop(automation);
                CoUninitialize();
            });
    }
    pub fn wake(hwnd: usize) {
        if hwnd != 0 {
            unsafe {
                PostMessageW(hwnd as HWND, UPDATE, 0, 0);
            }
        }
    }
    pub fn stop(hwnd: usize) {
        if hwnd != 0 {
            unsafe {
                PostMessageW(hwnd as HWND, WM_CLOSE, 0, 0);
            }
        }
    }
    #[cfg(feature = "ui-test")]
    pub fn test_click(hwnd: usize, index: usize) {
        if hwnd != 0 {
            unsafe {
                PostMessageW(hwnd as HWND, TEST_CLICK, index, 0);
            }
        }
    }
    pub fn pointer_pressed(area: Option<Rect>) -> bool {
        let Some(area) = area else {
            return false;
        };
        unsafe {
            let mut point = POINT { x: 0, y: 0 };
            GetAsyncKeyState(VK_LBUTTON as i32) < 0
                && GetCursorPos(&mut point) != 0
                && point.x >= area.left
                && point.x < area.right
                && point.y >= area.top
                && point.y < area.bottom
        }
    }
    struct Native {
        controller: Controller,
        app: tauri::AppHandle,
        host: HWND,
        parent: HWND,
        buttons: Vec<HWND>,
        host_context: Option<Box<Host>>,
        last_model: Model,
        last_rect: Option<Rect>,
        light: bool,
    }
    struct Host {
        controller: Controller,
        app: tauri::AppHandle,
    }
    unsafe fn foreign_windows(taskbar: HWND, bounds: Rect, padding: i32) -> Vec<Rect> {
        struct Probe {
            bounds: Rect,
            padding: i32,
            shell_pid: u32,
            rectangles: Vec<Rect>,
        }
        unsafe extern "system" fn visit(hwnd: HWND, pointer: LPARAM) -> i32 {
            let probe = &mut *(pointer as *mut Probe);
            let mut pid = 0;
            GetWindowThreadProcessId(hwnd, &mut pid);
            if let Some(item) = window_rect(hwnd) {
                if let Some(item) = foreign_window_obstacle(
                    probe.bounds,
                    item,
                    IsWindowVisible(hwnd) != 0,
                    pid,
                    probe.shell_pid,
                    std::process::id(),
                    probe.padding,
                ) {
                    probe.rectangles.push(item);
                }
            }
            1
        }
        let mut shell_pid = 0;
        GetWindowThreadProcessId(taskbar, &mut shell_pid);
        let mut probe = Probe {
            bounds,
            padding,
            shell_pid,
            rectangles: vec![],
        };
        EnumChildWindows(taskbar, Some(visit), (&mut probe as *mut Probe) as LPARAM);
        probe.rectangles
    }
    impl Native {
        unsafe fn own_host(&self) -> bool {
            if self.host.is_null() || IsWindow(self.host) == 0 {
                return false;
            }
            let mut pid = 0;
            GetWindowThreadProcessId(self.host, &mut pid);
            let mut name = [0u16; 80];
            let length = GetClassNameW(self.host, name.as_mut_ptr(), name.len() as i32);
            pid == std::process::id()
                && String::from_utf16_lossy(&name[..length.max(0) as usize])
                    == "TokenBarTaskbarWindow"
        }
        unsafe fn destroy_host(&mut self) {
            if self.own_host() {
                DestroyWindow(self.host);
            }
            self.host_context = None;
            self.host = null_mut();
            self.buttons.clear();
            self.last_rect = None;
            self.controller.0.paint_mask.store(0, Ordering::Release);
        }
        unsafe fn occupied(
            automation: &IUIAutomation,
            taskbar: HWND,
            bounds: Rect,
            padding: i32,
        ) -> Option<Vec<Rect>> {
            let root = automation
                .ElementFromHandle(windows::Win32::Foundation::HWND(taskbar))
                .ok()?;
            let condition = automation.CreateTrueCondition().ok()?;
            let cache = automation.CreateCacheRequest().ok()?;
            for property in [
                UIA_ProcessIdPropertyId,
                UIA_ControlTypePropertyId,
                UIA_IsOffscreenPropertyId,
                UIA_BoundingRectanglePropertyId,
            ] {
                cache.AddProperty(property).ok()?;
            }
            let elements = root
                .FindAllBuildCache(TreeScope_Descendants, &condition, &cache)
                .ok()?;
            let mut occupied = Vec::new();
            for index in 0..elements.Length().ok()?.min(512) {
                let Ok(element) = elements.GetElement(index) else {
                    continue;
                };
                if element.CachedProcessId().ok() == Some(std::process::id() as i32)
                    || element
                        .CachedIsOffscreen()
                        .map(|v| v.as_bool())
                        .unwrap_or(true)
                {
                    continue;
                }
                let Ok(kind) = element.CachedControlType() else {
                    continue;
                };
                if kind != UIA_ButtonControlTypeId
                    && kind != UIA_ListItemControlTypeId
                    && kind != UIA_EditControlTypeId
                {
                    continue;
                }
                if let Ok(r) = element.CachedBoundingRectangle() {
                    let item = Rect {
                        left: r.left,
                        top: r.top,
                        right: r.right,
                        bottom: r.bottom,
                    };
                    if item.width() > 0 && item.height() > 0 && bounds.intersects(item) {
                        occupied.push(Rect {
                            left: item.left - padding,
                            right: item.right + padding,
                            top: item.top - padding,
                            bottom: item.bottom + padding,
                        });
                    }
                }
            }
            // Reserve the complete notification area even if its accessibility children are hidden.
            for class in ["TrayNotifyWnd", "Start", "ReBarWindow32"] {
                let child = FindWindowExW(taskbar, null_mut(), wide(class).as_ptr(), null());
                if let Some(r) =
                    window_rect(child).filter(|r| r.width() > 0 && bounds.intersects(*r))
                {
                    occupied.push(Rect {
                        left: r.left - padding,
                        right: r.right + padding,
                        ..r
                    });
                }
            }
            // Custom taskbar tools may expose no UIA buttons (and can retain
            // WS_POPUP after SetParent). Native enumeration still finds them.
            occupied.extend(foreign_windows(taskbar, bounds, padding));
            // An empty UIA result cannot prove that a region is free.
            if occupied.is_empty() {
                None
            } else {
                Some(occupied)
            }
        }
        unsafe fn tick(&mut self) {
            let model = self
                .controller
                .0
                .model
                .read()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            if !model.enabled {
                self.destroy_host();
                self.controller.set_status(Status {
                    message: "任务栏用量已关闭".into(),
                    ..Default::default()
                });
                return;
            }
            let parent = FindWindowW(wide("Shell_TrayWnd").as_ptr(), null());
            let Some(bounds) = window_rect(parent).filter(|r| r.width() > 0 && r.height() > 0)
            else {
                self.destroy_host();
                self.controller.set_status(Status {
                    message: "等待 Windows 任务栏".into(),
                    ..Default::default()
                });
                return;
            };
            let dpi = GetDpiForWindow(parent).max(96);
            let px = |value: i32| ((value as i64 * dpi as i64) / 96) as i32;
            let vertical = bounds.height() > bounds.width();
            let layout = self
                .controller
                .0
                .layout
                .read()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            let Some(layout) = layout.filter(|l| l.parent == parent as usize && l.bounds == bounds)
            else {
                self.destroy_host();
                self.controller.set_status(Status {
                    message: "暂时无法读取任务栏布局，稍后自动重试。".into(),
                    taskbar_rect: Some(bounds),
                    ..Default::default()
                });
                return;
            };
            let mut occupied = layout.occupied;
            // Recheck custom windows immediately before placement instead of
            // waiting for the accessibility snapshot to catch up.
            occupied.extend(foreign_windows(parent, bounds, px(8)));
            let count = model.segments.len().max(1) as i32;
            let widths: Vec<i32> = model
                .segments
                .iter()
                .map(|s| crate::taskbar_render::label_width(s, dpi))
                .collect();
            let total_width = widths.iter().sum::<i32>() + px(7) * (count - 1);
            let intervals: Vec<_> = occupied
                .iter()
                .map(|r| {
                    if vertical {
                        (r.top, r.bottom)
                    } else {
                        (r.left, r.right)
                    }
                })
                .collect();
            let (start, end, desired, minimum) = if vertical {
                (
                    bounds.top + px(4),
                    bounds.bottom - px(4),
                    px(32) * count,
                    px(32) * count,
                )
            } else {
                (
                    bounds.left + px(8),
                    bounds.right - px(8),
                    total_width,
                    total_width,
                )
            };
            let Some((position, extent)) =
                free_slot(start, end, &intervals, desired, minimum, model.left)
            else {
                self.destroy_host();
                self.controller.set_status(Status {
                    message: "任务栏空位不足，可减少显示平台；托盘图标仍可打开面板。".into(),
                    taskbar_rect: Some(bounds),
                    ..Default::default()
                });
                return;
            };
            let area = if vertical {
                Rect {
                    left: bounds.left + px(2),
                    right: bounds.right - px(2),
                    top: position,
                    bottom: position + extent,
                }
            } else {
                let height = px(32).min(bounds.height());
                Rect {
                    left: position,
                    right: position + extent,
                    top: bounds.bottom - (bounds.height() + height) / 2,
                    bottom: bounds.bottom - (bounds.height() - height) / 2,
                }
            };
            if !self.own_host() || parent != self.parent {
                self.destroy_host();
                // Match Explorer's DPI context before creating a cross-process child.
                SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(parent));
                let mut context = Box::new(Host {
                    controller: self.controller.clone(),
                    app: self.app.clone(),
                });
                let pointer: *mut Host = &mut *context;
                self.host_context = Some(context);
                self.host = CreateWindowExW(
                    WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
                    wide("TokenBarTaskbarWindow").as_ptr(),
                    wide("TokenBar 任务栏用量").as_ptr(),
                    WS_POPUP | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
                    0,
                    0,
                    1,
                    1,
                    null_mut(),
                    null_mut(),
                    GetModuleHandleW(null()),
                    pointer.cast(),
                );
                if self.host.is_null() {
                    self.host_context = None;
                    self.controller.set_status(Status {
                        message: "Windows 未能创建任务栏用量区域。".into(),
                        ..Default::default()
                    });
                    return;
                }
                // Explorer's DirectComposition bridge clips regular WS_CHILD
                // GDI surfaces. Keep a layered popup surface while parenting
                // it into the taskbar, as required by the Windows 11 host.
                SetParent(self.host, parent);
                if GetAncestor(self.host, GA_PARENT) != parent {
                    self.destroy_host();
                    self.controller.set_status(Status {
                        message: "无法连接任务栏绘制表面，请使用托盘图标。".into(),
                        ..Default::default()
                    });
                    return;
                }
                self.parent = parent;
            }
            let rebuild = self.buttons.len() != model.segments.len()
                || self
                    .last_model
                    .segments
                    .iter()
                    .map(|s| &s.platform)
                    .ne(model.segments.iter().map(|s| &s.platform));
            if rebuild {
                self.controller.0.paint_mask.store(0, Ordering::Release);
                for button in self.buttons.drain(..) {
                    DestroyWindow(button);
                }
                for (index, _) in model.segments.iter().enumerate() {
                    let button = CreateWindowExW(
                        0,
                        wide("BUTTON").as_ptr(),
                        wide("TokenBar").as_ptr(),
                        WS_CHILD | WS_VISIBLE | BS_OWNERDRAW as u32,
                        0,
                        0,
                        1,
                        1,
                        self.host,
                        (index + 100) as HMENU,
                        GetModuleHandleW(null()),
                        null(),
                    );
                    if button.is_null() {
                        self.destroy_host();
                        self.controller.set_status(Status {
                            message: "无法创建任务栏按钮。".into(),
                            ..Default::default()
                        });
                        return;
                    }
                    self.buttons.push(button);
                }
            }
            let mut origin = POINT {
                x: area.left,
                y: area.top,
            };
            ScreenToClient(parent, &mut origin);
            SetWindowPos(
                self.host,
                if self.last_rect.is_none() {
                    HWND_TOP
                } else {
                    null_mut()
                },
                origin.x,
                origin.y,
                area.width(),
                area.height(),
                SWP_NOACTIVATE
                    | SWP_SHOWWINDOW
                    | if self.last_rect.is_some() {
                        SWP_NOZORDER
                    } else {
                        0
                    },
            );
            let light = light_theme();
            for (index, (button, segment)) in self.buttons.iter().zip(&model.segments).enumerate() {
                let (x, y, w, h) = if vertical {
                    (
                        0,
                        index as i32 * area.height() / count,
                        area.width(),
                        area.height() / count,
                    )
                } else {
                    (
                        widths[..index].iter().sum::<i32>() + px(7) * index as i32,
                        0,
                        widths[index] + if index + 1 < widths.len() { px(7) } else { 0 },
                        area.height(),
                    )
                };
                SetWindowPos(
                    *button,
                    null_mut(),
                    x,
                    y,
                    w,
                    h,
                    SWP_NOACTIVATE | SWP_NOZORDER,
                );
                if rebuild || model != self.last_model {
                    SetWindowTextW(
                        *button,
                        wide(&format!(
                            "{} 今日 {} tokens，周额度剩余 {}{}；点击展开",
                            segment.title,
                            segment.today,
                            segment.quota,
                            if segment.stale {
                                "（上次结果）"
                            } else {
                                ""
                            }
                        ))
                        .as_ptr(),
                    );
                }
                if rebuild
                    || model != self.last_model
                    || self.last_rect != Some(area)
                    || self.light != light
                {
                    InvalidateRect(*button, null(), 0);
                }
            }
            if rebuild
                || model != self.last_model
                || self.last_rect != Some(area)
                || self.light != light
                || self.controller.0.paint_mask.load(Ordering::Acquire) != (1 << count) - 1
            {
                let painted = crate::taskbar_render::render(
                    self.host,
                    &model.segments,
                    &widths,
                    area,
                    vertical,
                    dpi,
                    light,
                );
                self.controller.0.paint_mask.store(
                    if painted { (1 << count) - 1 } else { 0 },
                    Ordering::Release,
                );
            }
            self.light = light;
            self.last_model = model;
            self.last_rect = Some(area);
            let painted = self.controller.0.paint_mask.load(Ordering::Acquire) & ((1 << count) - 1)
                == (1 << count) - 1;
            self.controller.set_status(Status {
                attached: painted && IsWindowVisible(self.host) != 0,
                message: if painted {
                    "任务栏用量已显示"
                } else {
                    "任务栏区域正在绘制"
                }
                .into(),
                rect: window_rect(self.host),
                taskbar_rect: Some(bounds),
                segment_count: count as usize,
                painted,
            });
        }
    }
    unsafe extern "system" fn manager_proc(
        hwnd: HWND,
        message: u32,
        w: WPARAM,
        l: LPARAM,
    ) -> LRESULT {
        if message == WM_NCCREATE {
            let create = &*(l as *const CREATESTRUCTW);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
        }
        let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Native;
        if !pointer.is_null() {
            match message {
                #[cfg(feature = "ui-test")]
                TEST_CLICK => {
                    let native = &*pointer;
                    eprintln!(
                        "native test click: index={w} buttons={}",
                        native.buttons.len()
                    );
                    if let Some(&button) = native.buttons.get(w) {
                        SendMessageW(button, BM_CLICK, 0, 0);
                    }
                    return 0;
                }
                UPDATE | WM_TIMER => {
                    (*pointer).tick();
                    return 0;
                }
                WM_CLOSE => {
                    (*pointer).destroy_host();
                    DestroyWindow(hwnd);
                    return 0;
                }
                WM_DESTROY => {
                    PostQuitMessage(0);
                    return 0;
                }
                WM_NCDESTROY => {
                    SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
                }
                _ => {}
            }
        }
        DefWindowProcW(hwnd, message, w, l)
    }
    unsafe extern "system" fn host_proc(hwnd: HWND, message: u32, w: WPARAM, l: LPARAM) -> LRESULT {
        if message == WM_NCCREATE {
            let create = &*(l as *const CREATESTRUCTW);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
        }
        let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Host;
        if !pointer.is_null() {
            let host = &*pointer;
            match message {
                WM_MOUSEACTIVATE => return MA_NOACTIVATE as isize,
                WM_ERASEBKGND => return 1,
                // Button children provide input and accessibility. The parent
                // draws all text into one premultiplied-alpha bitmap.
                WM_DRAWITEM => return 1,
                WM_COMMAND if (w >> 16) == BN_CLICKED as usize => {
                    #[cfg(feature = "ui-test")]
                    eprintln!("native BN_CLICKED: id={} hwnd={l}", w & 0xffff);
                    let index = (w & 0xffff).saturating_sub(100);
                    let model = host
                        .controller
                        .0
                        .model
                        .read()
                        .unwrap_or_else(|e| e.into_inner())
                        .clone();
                    if let Some(segment) = model.segments.get(index) {
                        if let Some(area) = window_rect(l as HWND) {
                            let platform = segment.platform.clone();
                            let app = host.app.clone();
                            let _ = host.app.run_on_main_thread(move || {
                                crate::toggle_panel(&app, &platform, area)
                            });
                        }
                    }
                    return 0;
                }
                WM_NCDESTROY => {
                    SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
                }
                _ => {}
            }
        }
        DefWindowProcW(hwnd, message, w, l)
    }
    unsafe fn light_theme() -> bool {
        let mut light = 1u32;
        let mut bytes = size_of::<u32>() as u32;
        RegGetValueW(
            HKEY_CURRENT_USER,
            wide("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize").as_ptr(),
            wide("SystemUsesLightTheme").as_ptr(),
            RRF_RT_REG_DWORD,
            null_mut(),
            (&mut light as *mut u32).cast(),
            &mut bytes,
        );
        light != 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reserves_traffic_monitor_even_when_it_has_no_accessibility_button() {
        let taskbar = Rect {
            left: 0,
            top: 2064,
            right: 3840,
            bottom: 2160,
        };
        let traffic = Rect {
            left: 3041,
            top: 2080,
            right: 3364,
            bottom: 2144,
        };
        let obstacle =
            foreign_window_obstacle(taskbar, traffic, true, 7732, 52340, 55096, 16).unwrap();
        let occupied = [(1244, 2242), (3352, 3840), (obstacle.left, obstacle.right)];
        let (left, width) = free_slot(16, 3824, &occupied, 300, 300, false).unwrap();
        let bar = Rect {
            left,
            top: 2084,
            right: left + width,
            bottom: 2140,
        };
        assert!(!bar.intersects(traffic));
        assert!(bar.right < traffic.left);
        assert!(foreign_window_obstacle(taskbar, traffic, false, 7732, 52340, 55096, 16).is_none());
        assert!(foreign_window_obstacle(taskbar, traffic, true, 55096, 52340, 55096, 16).is_none());
    }
    #[test]
    fn placement_uses_real_gaps_and_keeps_notifications_and_buttons_clear() {
        let occupied = [(0, 180), (700, 1200), (1700, 1920)];
        assert_eq!(
            free_slot(8, 1912, &occupied, 344, 256, false),
            Some((1356, 344))
        );
        assert_eq!(
            free_slot(8, 1912, &occupied, 344, 256, true),
            Some((180, 344))
        );
        assert!(free_slot(0, 200, &[(0, 100), (140, 200)], 172, 128, false).is_none());
    }
    #[test]
    fn overlapping_occupied_rectangles_and_negative_monitor_coordinates_are_supported() {
        assert_eq!(
            free_slot(
                -1920,
                0,
                &[(-1200, -800), (-1000, -600), (-300, 0)],
                172,
                128,
                false
            ),
            Some((-472, 172))
        );
        assert_eq!(
            free_slot(0, 500, &[(0, 150), (140, 320)], 200, 128, false),
            Some((320, 180))
        );
    }
    #[test]
    fn panel_stays_in_work_area_for_top_bottom_and_secondary_monitors() {
        let work = Rect {
            left: -1920,
            top: 0,
            right: 0,
            bottom: 1040,
        };
        assert_eq!(
            panel_position(
                Rect {
                    left: -250,
                    top: 1040,
                    right: -70,
                    bottom: 1080
                },
                work,
                520,
                780
            ),
            (-520, 252)
        );
        let top_work = Rect {
            left: 0,
            top: 48,
            right: 1920,
            bottom: 1080,
        };
        assert_eq!(
            panel_position(
                Rect {
                    left: 1500,
                    top: 0,
                    right: 1700,
                    bottom: 48
                },
                top_work,
                520,
                780
            ),
            (1340, 56)
        );
    }
    #[test]
    fn same_platform_click_closes_but_other_platform_switches() {
        assert!(hides_on_click(true, "codex", "codex"));
        assert!(!hides_on_click(true, "codex", "claude"));
        assert!(!hides_on_click(false, "codex", "codex"));
    }
    #[test]
    fn taskbar_summary_keeps_missing_quota_unknown_and_platform_totals_separate() {
        let mut dashboard = Dashboard {
            settings: crate::settings::Settings {
                taskbar_platform: "all".into(),
                ..Default::default()
            },
            snapshot: None,
            quotas: Default::default(),
            refreshing: false,
            error: None,
            memory_status: String::new(),
            remote_snapshots: vec![],
            sync_status: String::new(),
        };
        let loading = model(&dashboard);
        assert_eq!(loading.segments.len(), 3);
        assert_eq!(loading.segments[0].today, "—");
        assert_eq!(loading.segments[0].quota, "—");
        dashboard.quotas.insert(
            "claude".into(),
            crate::quota::Quota {
                weekly: Some(crate::quota::Window {
                    used_percent: 45.0,
                    window_minutes: Some(10080),
                    resets_at_ms: None,
                }),
                ..Default::default()
            },
        );
        let loaded = model(&dashboard);
        assert_eq!(loaded.segments[0].quota, "—");
        assert_eq!(loaded.segments[1].quota, "55%");
        dashboard.settings.show_claude = false;
        assert_eq!(model(&dashboard).segments.len(), 2);
    }
    #[test]
    fn compact_counts_match_mac_status_values() {
        assert_eq!(compact(1200), "1K");
        assert_eq!(compact(1234567), "1M");
        assert_eq!(compact(20800000), "21M");
        assert_eq!(compact(999999), "1000K");
    }
}
