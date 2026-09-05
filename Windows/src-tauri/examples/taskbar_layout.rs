//! Read-only inspection of the primary taskbar's native child-window geometry.
#[cfg(windows)]
fn main() {
    use windows_sys::Win32::{
        Foundation::{HWND, LPARAM, POINT, RECT},
        UI::{
            HiDpi::{
                GetDpiForWindow, SetThreadDpiAwarenessContext,
                DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
            },
            WindowsAndMessaging::*,
        },
    };
    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }
    unsafe fn info(hwnd: HWND) -> serde_json::Value {
        let mut name = [0u16; 256];
        let length = GetClassNameW(hwnd, name.as_mut_ptr(), name.len() as i32);
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);
        let mut rect = RECT {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        };
        GetWindowRect(hwnd, &mut rect);
        serde_json::json!({
            "hwnd": hwnd as usize, "parent":GetParent(hwnd) as usize, "pid":pid,
            "class":String::from_utf16_lossy(&name[..length.max(0) as usize]),
            "visible": IsWindowVisible(hwnd)!=0, "dpi":GetDpiForWindow(hwnd),
            "rect":[rect.left,rect.top,rect.right,rect.bottom],
            "hitAtCenter":WindowFromPoint(POINT{x:(rect.left+rect.right)/2,y:(rect.top+rect.bottom)/2}) as usize,
            "style":format!("{:x}",GetWindowLongPtrW(hwnd,GWL_STYLE)),
            "exStyle":format!("{:x}",GetWindowLongPtrW(hwnd,GWL_EXSTYLE))
        })
    }
    unsafe extern "system" fn visit(hwnd: HWND, state: LPARAM) -> i32 {
        (&mut *(state as *mut Vec<serde_json::Value>)).push(info(hwnd));
        1
    }
    unsafe {
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let root = FindWindowW(wide("Shell_TrayWnd").as_ptr(), std::ptr::null());
        if root.is_null() {
            eprintln!("Primary taskbar is unavailable");
            return;
        }
        let mut rows = vec![info(root)];
        EnumChildWindows(
            root,
            Some(visit),
            (&mut rows as *mut Vec<serde_json::Value>) as LPARAM,
        );
        println!("{}", serde_json::to_string_pretty(&rows).unwrap());
    }
}
#[cfg(not(windows))]
fn main() {
    eprintln!("Windows only");
}
