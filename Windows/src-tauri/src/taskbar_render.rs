//! Per-pixel text surface, with an almost transparent background hit region.
use crate::taskbar::{Rect, Segment};
use std::{
    mem::{size_of, zeroed},
    ptr::{null, null_mut},
};
use windows_sys::Win32::{
    Foundation::{HWND, POINT, RECT, SIZE},
    Graphics::Gdi::*,
    UI::WindowsAndMessaging::{UpdateLayeredWindow, ULW_ALPHA},
};

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}
fn lines(segment: &Segment) -> [String; 2] {
    [
        format!("{} 今日: {}", segment.title, segment.today),
        format!("周剩余: {}", segment.quota),
    ]
}
unsafe fn font(dpi: u32) -> HFONT {
    CreateFontW(
        -((9 * dpi / 72) as i32).max(10),
        0,
        0,
        0,
        FW_NORMAL as i32,
        0,
        0,
        0,
        DEFAULT_CHARSET as u32,
        0,
        0,
        ANTIALIASED_QUALITY as u32,
        0,
        wide("微软雅黑").as_ptr(),
    )
}
pub unsafe fn label_width(segment: &Segment, dpi: u32) -> i32 {
    let dc = GetDC(null_mut());
    let font = font(dpi);
    let previous = SelectObject(dc, font);
    let width = lines(segment)
        .iter()
        .map(|line| {
            let value = wide(line);
            let mut size: SIZE = zeroed();
            GetTextExtentPoint32W(dc, value.as_ptr(), value.len() as i32 - 1, &mut size);
            size.cx
        })
        .max()
        .unwrap_or(0)
        + (8 * dpi / 96) as i32;
    SelectObject(dc, previous);
    DeleteObject(font);
    ReleaseDC(null_mut(), dc);
    width
}

fn text_alpha(pixels: &mut [u8], light: bool) {
    for pixel in pixels.chunks_exact_mut(4) {
        let coverage = pixel[0].max(pixel[1]).max(pixel[2]);
        // A nonzero alpha preserves the complete rectangular mouse target
        // while leaving the taskbar wallpaper visible between glyphs.
        let alpha = coverage.max(1);
        let value = if light { 0 } else { alpha };
        pixel.copy_from_slice(&[value, value, value, alpha]);
    }
}
struct Surface {
    dc: HDC,
    bitmap: HBITMAP,
    previous: HGDIOBJ,
    bits: *mut u8,
    length: usize,
}
impl Surface {
    unsafe fn new(width: i32, height: i32) -> Option<Self> {
        if width <= 0 || height <= 0 || width > 8192 || height > 2048 {
            return None;
        }
        let dc = CreateCompatibleDC(null_mut());
        if dc.is_null() {
            return None;
        }
        let mut info: BITMAPINFO = zeroed();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..zeroed()
        };
        let mut bits = null_mut();
        let bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &mut bits, null_mut(), 0);
        if bitmap.is_null() || bits.is_null() {
            if !bitmap.is_null() {
                DeleteObject(bitmap);
            }
            DeleteDC(dc);
            return None;
        }
        let previous = SelectObject(dc, bitmap);
        let length = width as usize * height as usize * 4;
        std::ptr::write_bytes(bits.cast::<u8>(), 0, length);
        Some(Self {
            dc,
            bitmap,
            previous,
            bits: bits.cast(),
            length,
        })
    }
}
impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.previous);
            DeleteObject(self.bitmap);
            DeleteDC(self.dc);
        }
    }
}
pub unsafe fn render(
    hwnd: HWND,
    segments: &[Segment],
    widths: &[i32],
    area: Rect,
    vertical: bool,
    dpi: u32,
    light: bool,
) -> bool {
    let Some(surface) = Surface::new(area.width(), area.height()) else {
        return false;
    };
    let font = font(dpi);
    let previous = SelectObject(surface.dc, font);
    SetTextColor(surface.dc, 0x00ffffff);
    SetBkMode(surface.dc, TRANSPARENT as i32);
    let px = |n: i32| ((n as i64 * dpi as i64) / 96) as i32;
    let count = segments.len().max(1) as i32;
    for (index, segment) in segments.iter().enumerate() {
        let (x, y, width, height) = if vertical {
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
                widths[index],
                area.height(),
            )
        };
        let top = y + (height - px(32)) / 2;
        for (line_index, text) in lines(segment).iter().enumerate() {
            let mut rect = RECT {
                left: x + px(4),
                right: x + width - px(4),
                top: top + px(16) * line_index as i32,
                bottom: top + px(16) * (line_index as i32 + 1),
            };
            DrawTextW(
                surface.dc,
                wide(text).as_ptr(),
                -1,
                &mut rect,
                DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS,
            );
        }
    }
    SelectObject(surface.dc, previous);
    DeleteObject(font);
    GdiFlush();
    text_alpha(
        std::slice::from_raw_parts_mut(surface.bits, surface.length),
        light,
    );
    let size = SIZE {
        cx: area.width(),
        cy: area.height(),
    };
    let origin = POINT { x: 0, y: 0 };
    let blend = BLENDFUNCTION {
        BlendOp: AC_SRC_OVER as u8,
        BlendFlags: 0,
        SourceConstantAlpha: 255,
        AlphaFormat: AC_SRC_ALPHA as u8,
    };
    UpdateLayeredWindow(
        hwnd,
        null_mut(),
        null(),
        &size,
        surface.dc,
        &origin,
        0,
        &blend,
        ULW_ALPHA,
    ) != 0
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn transparent_background_keeps_hit_target_and_text_has_premultiplied_alpha() {
        let source = [0, 0, 0, 0, 128, 128, 128, 0, 255, 255, 255, 0];
        let mut light = source;
        text_alpha(&mut light, true);
        assert_eq!(light, [0, 0, 0, 1, 0, 0, 0, 128, 0, 0, 0, 255]);
        let mut dark = source;
        text_alpha(&mut dark, false);
        assert_eq!(dark, [1, 1, 1, 1, 128, 128, 128, 128, 255, 255, 255, 255]);
    }
}
