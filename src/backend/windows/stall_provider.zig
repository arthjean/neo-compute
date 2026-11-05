//! `neo-compute selftest-stall`: a window with two Win32 trackbars that
//! answer the snapshot's main read, then stop answering during the range
//! round trip. The selftest starts it in a process of its own to prove the
//! US-022 timeout branch: the main tree comes back, range fields are left
//! out and the tree is partial.
//!
//! UIA's Win32 proxy reads a trackbar's range with TBM_GETPOS,
//! TBM_GETRANGEMIN and TBM_GETRANGEMAX, in that order; the main read caches
//! the RangeValue pattern without them. The first trackbar's TBM_GETRANGEMAX,
//! the last message of its round trip, is answered and posts a message that
//! blocks the thread for `stall_ms`: the second trackbar's round trip finds
//! the window not answering. The window closes itself after `lifetime_ms`.
const std = @import("std");
const w = @import("win32");

pub const class_name = "NeoComputeStallProvider";
/// How long the thread stays blocked: well past the 200 ms provider timeout.
const stall_ms = 1500;
const lifetime_ms = 20_000;
const wm_stall = w.WM_APP + 1;
/// commctrl.h TBM_GETRANGEMAX (WM_USER + 2), which the metadata leaves out
/// (it has TBM_SETPOS and TBM_SETRANGE).
const tbm_getrangemax = w.WM_USER + 2;

var stalled = false;

pub fn run() u8 {
    const instance = w.GetModuleHandleW(null);
    const class = std.unicode.utf8ToUtf16LeStringLiteral(class_name);
    const wc: w.WNDCLASSEXW = .{
        .cbSize = @sizeOf(w.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class,
        .hIconSm = null,
    };
    if (w.RegisterClassExW(&wc) == 0) return 1;
    const hwnd = w.CreateWindowExW(w.WS_EX_TOPMOST, class, std.unicode.utf8ToUtf16LeStringLiteral("neo-compute stall provider"), w.WS_POPUP | w.WS_VISIBLE, 40, 420, 240, 80, null, null, instance, null);
    if (hwnd == null) return 1;
    const icc: w.INITCOMMONCONTROLSEX = .{ .dwSize = @sizeOf(w.INITCOMMONCONTROLSEX), .dwICC = w.ICC_BAR_CLASSES };
    _ = w.InitCommonControlsEx(&icc);
    for (0..2) |i| {
        const slider = w.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("msctls_trackbar32"), null, w.WS_CHILD | w.WS_VISIBLE, 10, 10 + @as(i32, @intCast(i)) * 34, 220, 26, hwnd, null, instance, null);
        if (slider == null) return 1;
        _ = w.SendMessageW(slider, w.TBM_SETRANGE, 1, 100 << 16);
        _ = w.SendMessageW(slider, w.TBM_SETPOS, 1, 50);
        if (w.SetWindowSubclass(slider, sliderProc, 1, @intFromPtr(hwnd)) == 0) return 1;
    }
    _ = w.SetTimer(hwnd, 1, lifetime_ms, null);
    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    return 0;
}

fn wndProc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        wm_stall => {
            w.Sleep(stall_ms);
            return 0;
        },
        w.WM_TIMER => {
            _ = w.DestroyWindow(hwnd);
            return 0;
        },
        w.WM_DESTROY => {
            w.PostQuitMessage(0);
            return 0;
        },
        else => return w.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// The first range read is answered, then blocks the thread.
fn sliderProc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM, _: usize, parent: usize) callconv(.winapi) w.LRESULT {
    if (!stalled and msg == tbm_getrangemax) {
        stalled = true;
        _ = w.PostMessageW(@ptrFromInt(parent), wm_stall, 0, 0);
    }
    return w.DefSubclassProc(hwnd, msg, wparam, lparam);
}
