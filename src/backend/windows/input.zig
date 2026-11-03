//! SendInput helpers: absolute moves on the virtual desktop in physical
//! pixels, left clicks and Unicode characters.

const w = @import("win32");

pub const Error = error{InputBlocked};

fn send(inputs: []w.INPUT) Error!void {
    const sent = w.SendInput(@intCast(inputs.len), inputs.ptr, @sizeOf(w.INPUT));
    if (sent != inputs.len) return error.InputBlocked;
}

/// Maps a physical desktop pixel to the 0..65535 range SendInput expects
/// with MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK.
pub fn normalize(x: i32, y: i32) [2]i32 {
    const vx = w.GetSystemMetrics(w.SM_XVIRTUALSCREEN);
    const vy = w.GetSystemMetrics(w.SM_YVIRTUALSCREEN);
    const vw = w.GetSystemMetrics(w.SM_CXVIRTUALSCREEN);
    const vh = w.GetSystemMetrics(w.SM_CYVIRTUALSCREEN);
    // Round to the pixel center so the inverse mapping lands on (x, y).
    const nx = @divFloor((@as(i64, x - vx) * 65536 + @divFloor(65536, 2)), vw);
    const ny = @divFloor((@as(i64, y - vy) * 65536 + @divFloor(65536, 2)), vh);
    return .{ @intCast(nx), @intCast(ny) };
}

fn mouse(dx: i32, dy: i32, flags: w.MOUSE_EVENT_FLAGS) w.INPUT {
    return .{ .type = w.INPUT_MOUSE, .Anonymous = .{ .mi = .{ .dx = dx, .dy = dy, .mouseData = 0, .dwFlags = flags, .time = 0, .dwExtraInfo = 0 } } };
}

pub fn moveTo(x: i32, y: i32) Error!void {
    const n = normalize(x, y);
    var in = [_]w.INPUT{mouse(n[0], n[1], w.MOUSEEVENTF_MOVE | w.MOUSEEVENTF_ABSOLUTE | w.MOUSEEVENTF_VIRTUALDESK)};
    try send(&in);
}

pub fn leftClickAt(x: i32, y: i32) Error!void {
    const n = normalize(x, y);
    const abs = w.MOUSEEVENTF_ABSOLUTE | w.MOUSEEVENTF_VIRTUALDESK;
    var in = [_]w.INPUT{
        mouse(n[0], n[1], w.MOUSEEVENTF_MOVE | abs),
        mouse(n[0], n[1], w.MOUSEEVENTF_LEFTDOWN | abs),
        mouse(n[0], n[1], w.MOUSEEVENTF_LEFTUP | abs),
    };
    try send(&in);
}

/// Types one UTF-16 code unit as a Unicode key press and release.
pub fn unicodeChar(unit: u16) Error!void {
    var in = [_]w.INPUT{
        .{ .type = w.INPUT_KEYBOARD, .Anonymous = .{ .ki = .{ .wVk = 0, .wScan = unit, .dwFlags = w.KEYEVENTF_UNICODE, .time = 0, .dwExtraInfo = 0 } } },
        .{ .type = w.INPUT_KEYBOARD, .Anonymous = .{ .ki = .{ .wVk = 0, .wScan = unit, .dwFlags = w.KEYEVENTF_UNICODE | w.KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 } } },
    };
    try send(&in);
}
