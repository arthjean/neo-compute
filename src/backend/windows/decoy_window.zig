//! `neo-compute selftest-decoy <x> <y> <w> <h>`: the window a user would be
//! working in, in a process of its own (EP-011). It takes the foreground and
//! keeps the keyboard focus in its text field; the background probe and
//! selftest put their target under it and check that no action moves the
//! foreground, the focus or the cursor away. A process of its own matters:
//! Windows lets the foreground process take the foreground at will, so a
//! decoy inside the server's process would grant the server a right it never
//! has while a user works in another application. For the same reason the
//! decoy takes the foreground back by itself when asked (`msg_front`), with
//! an input event of its own, as a user clicking back into their window
//! would: the process that sent the last input may take the foreground, and
//! that must never be the server. The window closes itself after
//! `lifetime_ms`.
const std = @import("std");
const w = @import("win32");

pub const class_name = "NeoComputeDecoy";
pub const title = "neo-compute decoy";
/// Longer than the background probe over the six reference applications.
const lifetime_ms = 30 * 60 * 1000;

/// Posted by the probe or the selftest: take the foreground back.
pub const msg_front = w.WM_APP + 1;

var field: w.HWND = null;

/// Takes the foreground as window_focus does, from this process: a null
/// mouse move makes it the sender of the last input event. The move is sent
/// even when the decoy is already in front: it stands for the user's last
/// keystroke, and Windows locks the foreground only for a while after an
/// input event (ForegroundLockTimeout, 200 s by default). Without it, a
/// measure taken on an idle machine would see every window free to take the
/// foreground.
fn takeForeground(hwnd: w.HWND) void {
    var nudge = [_]w.INPUT{.{ .type = w.INPUT_MOUSE, .Anonymous = .{ .mi = .{ .dx = 0, .dy = 0, .mouseData = 0, .dwFlags = w.MOUSEEVENTF_MOVE, .time = 0, .dwExtraInfo = 0 } } }};
    _ = w.SendInput(1, &nudge, @sizeOf(w.INPUT));
    if (w.GetForegroundWindow() != hwnd) _ = w.SetForegroundWindow(hwnd);
    if (w.GetForegroundWindow() != hwnd) {
        const fg = w.GetForegroundWindow();
        const fg_thread = if (fg != null) w.GetWindowThreadProcessId(fg, null) else 0;
        const me = w.GetCurrentThreadId();
        if (fg_thread != 0 and fg_thread != me) _ = w.AttachThreadInput(me, fg_thread, 1);
        _ = w.BringWindowToTop(hwnd);
        _ = w.SetForegroundWindow(hwnd);
        if (fg_thread != 0 and fg_thread != me) _ = w.AttachThreadInput(me, fg_thread, 0);
    }
    _ = w.SetFocus(field);
    // The user's keystroke: a key the decoy reads itself. Only real-looking
    // key input read by another process ends the foreground right a process
    // inherits from the one that started it. F15 is bound to nothing, and it
    // is sent only while the decoy holds the foreground and the focus.
    if (w.GetForegroundWindow() == hwnd and w.GetFocus() == field) {
        const f15 = 0x7E;
        var keys = [_]w.INPUT{
            .{ .type = w.INPUT_KEYBOARD, .Anonymous = .{ .ki = .{ .wVk = f15, .wScan = 0, .dwFlags = 0, .time = 0, .dwExtraInfo = 0 } } },
            .{ .type = w.INPUT_KEYBOARD, .Anonymous = .{ .ki = .{ .wVk = f15, .wScan = 0, .dwFlags = w.KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 } } },
        };
        _ = w.SendInput(keys.len, &keys, @sizeOf(w.INPUT));
    }
}

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
        .hbrBackground = w.CreateSolidBrush(0x00403020),
        .lpszMenuName = null,
        .lpszClassName = class,
        .hIconSm = null,
    };
    if (w.RegisterClassExW(&wc) == 0) return 1;
    // Not topmost: it covers the target only by being the foreground window,
    // as a user's application does.
    const hwnd = w.CreateWindowExW(w.WS_EX_APPWINDOW, class, std.unicode.utf8ToUtf16LeStringLiteral(title), w.WS_POPUP | w.WS_VISIBLE, r[0], r[1], r[2], r[3], null, null, instance, null);
    if (hwnd == null) return 1;
    field = w.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), std.unicode.utf8ToUtf16LeStringLiteral("decoy: the user types here"), w.WS_CHILD | w.WS_VISIBLE | w.WS_BORDER, 20, 20, 320, 28, hwnd, null, instance, null);
    if (field == null) return 1;
    takeForeground(hwnd);
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
        // The keyboard focus always sits in the field, as in an editor.
        w.WM_SETFOCUS => {
            _ = w.SetFocus(field);
            return 0;
        },
        msg_front => {
            takeForeground(hwnd);
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
