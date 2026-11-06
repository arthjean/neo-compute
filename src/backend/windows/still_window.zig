//! `neo-compute selftest-still <x> <y> <w> <h>`: a still, solid, topmost
//! window over that desktop rectangle with one password field, in a
//! process of its own. The selftest times ui_find's GDI wait on it (US-030,
//! US-032) and the bench `screenshot` scenario puts it in the foreground
//! for the password scan (US-019): a window of another process, as in real
//! use, whose UI Automation provider and painting are not counted as the
//! server's time. The window closes itself after `lifetime_ms`.
const std = @import("std");
const w = @import("win32");

pub const class_name = "NeoComputeStillWindow";
/// Long enough for the bench `screenshot` series.
const lifetime_ms = 60_000;

pub fn run(args: []const [:0]const u8) u8 {
    if (args.len != 4) return 2;
    var r: [4]i32 = undefined;
    for (args, &r) |a, *v| v.* = std.fmt.parseInt(i32, a, 10) catch return 2;
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
        .hbrBackground = w.CreateSolidBrush(0x00805020),
        .lpszMenuName = null,
        .lpszClassName = class,
        .hIconSm = null,
    };
    if (w.RegisterClassExW(&wc) == 0) return 1;
    const hwnd = w.CreateWindowExW(w.WS_EX_TOPMOST, class, std.unicode.utf8ToUtf16LeStringLiteral("neo-compute still window"), w.WS_POPUP | w.WS_VISIBLE, r[0], r[1], r[2], r[3], null, null, instance, null);
    if (hwnd == null) return 1;
    // Empty: its value never matters, only that the scan finds it.
    const field = w.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), null, w.WS_CHILD | w.WS_VISIBLE | w.WS_BORDER | @as(u32, @intCast(w.ES_PASSWORD)), 20, 20, 200, 28, hwnd, null, instance, null);
    if (field == null) return 1;
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
