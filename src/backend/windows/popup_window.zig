//! `neo-compute selftest-popup <x> <y>`: an application whose button opens a
//! dialog that takes the foreground, in a process of its own (US-050). The
//! background selftest acts on its button while the decoy is in front: the
//! dialog comes in front of the user's window, and the foreground guard
//! must give the foreground back. A process of its own matters: a dialog of
//! the server's process would make the server the foreground process, free
//! to hand the foreground to anyone. Windows lets a background process take
//! the foreground only when the foreground process allowed it
//! (`AllowSetForegroundWindow`), which the decoy does before each action.
//! The window closes itself after `lifetime_ms`.
const std = @import("std");
const w = @import("win32");

pub const class_name = "NeoComputePopup";
pub const dialog_class_name = "NeoComputePopupDialog";
pub const title = "neo-compute popup";
pub const button_label = "neo-compute open dialog";

pub const dialog_title = "neo-compute dialog";
const lifetime_ms = 10 * 60 * 1000;

/// Posted by the selftest: close the dialog.
pub const msg_close_dialog = w.WM_APP + 1;

var dialog: w.HWND = null;
var instance: w.HINSTANCE = null;

fn utf16(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

pub fn run(args: []const [:0]const u8) u8 {
    if (args.len != 2) return 2;
    var at: [2]i32 = undefined;
    for (args, &at) |a, *v| v.* = std.fmt.parseInt(i32, a, 10) catch return 2;
    instance = w.GetModuleHandleW(null);
    var wc: w.WNDCLASSEXW = .{
        .cbSize = @sizeOf(w.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = w.CreateSolidBrush(0x00604030),
        .lpszMenuName = null,
        .lpszClassName = utf16(class_name),
        .hIconSm = null,
    };
    if (w.RegisterClassExW(&wc) == 0) return 1;
    wc.lpfnWndProc = dialogProc;
    wc.lpszClassName = utf16(dialog_class_name);
    wc.hbrBackground = w.CreateSolidBrush(0x00306040);
    if (w.RegisterClassExW(&wc) == 0) return 1;
    // Created hidden, then shown without activation, under whatever the
    // user works in.
    const hwnd = w.CreateWindowExW(w.WS_EX_APPWINDOW, utf16(class_name), utf16(title), w.WS_POPUP, at[0], at[1], 360, 200, null, null, instance, null);
    if (hwnd == null) return 1;
    if (w.CreateWindowExW(0, utf16("BUTTON"), utf16(button_label), w.WS_CHILD | w.WS_VISIBLE, 20, 20, 240, 40, hwnd, null, instance, null) == null) return 1;
    _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
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
        w.WM_COMMAND => {
            if (lparam != 0 and (wparam >> 16) & 0xFFFF == w.BN_CLICKED and dialog == null) {
                var r: w.RECT = undefined;
                _ = w.GetWindowRect(hwnd, &r);
                dialog = w.CreateWindowExW(0, utf16(dialog_class_name), utf16(dialog_title), w.WS_POPUP | w.WS_BORDER, r.left + 40, r.top + 40, 280, 120, hwnd, null, instance, null);
                if (dialog != null) {
                    _ = w.ShowWindow(dialog, w.SW_SHOW);
                    // What a dialog does: it comes in front.
                    _ = w.SetForegroundWindow(dialog);
                }
            }
            return 0;
        },
        msg_close_dialog => {
            if (dialog != null) _ = w.DestroyWindow(dialog);
            dialog = null;
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

fn dialogProc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}
