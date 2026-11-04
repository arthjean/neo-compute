//! Top-level windows: enumeration in z-order for `window_list`, and
//! foreground activation for `window_focus`.

const std = @import("std");
const w = @import("win32");
const display = @import("../../core/display.zig");
const input = @import("input.zig");

const max_windows = 512;

const Collect = struct {
    hwnds: [max_windows]w.HWND = undefined,
    len: usize = 0,

    /// Keeps visible windows only, so hidden ones (often hundreds) never
    /// use up the cap ahead of visible windows lower in the z-order.
    fn callback(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
        const self: *Collect = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (w.IsWindowVisible(hwnd) == 0) return 1;
        if (self.len == max_windows) return 0;
        self.hwnds[self.len] = hwnd;
        self.len += 1;
        return 1;
    }
};

fn utf8(arena: std.mem.Allocator, wide: []const u16) ![]const u8 {
    const buf = try arena.alloc(u8, wide.len * 3);
    return buf[0..std.unicode.wtf16LeToWtf8(buf, wide)];
}

/// Executable name and elevation of a process, looked up once per pid per
/// call (an app with several windows is opened once).
const ProcessInfo = struct { pid: u32, exe: []const u8, elevated: bool };

fn processInfo(arena: std.mem.Allocator, cache: *std.ArrayList(ProcessInfo), pid: u32) !ProcessInfo {
    for (cache.items) |p| if (p.pid == pid) return p;
    const info: ProcessInfo = .{ .pid = pid, .exe = try exeName(arena, pid), .elevated = input.isElevatedPid(pid) };
    try cache.append(arena, info);
    return info;
}

fn exeName(arena: std.mem.Allocator, pid: u32) ![]const u8 {
    const process = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return "?";
    defer _ = w.CloseHandle(process);
    var path: [1024:0]u16 = undefined;
    var len: u32 = path.len;
    if (w.QueryFullProcessImageNameW(process, w.PROCESS_NAME_WIN32, &path, &len) == 0) return "?";
    const full = path[0..len];
    const base = if (std.mem.lastIndexOfScalar(u16, full, '\\')) |i| full[i + 1 ..] else full;
    return utf8(arena, base);
}

pub fn isCloaked(hwnd: w.HWND) bool {
    var cloaked: u32 = 0;
    if (w.DwmGetWindowAttribute(hwnd, @intCast(w.DWMWA_CLOAKED), &cloaked, @sizeOf(u32)) < 0) return false;
    return cloaked != 0;
}

/// The visible frame of a window, without the invisible resize borders.
pub fn rect(hwnd: w.HWND) ?display.Rect {
    if (hwnd == null or w.IsWindow(hwnd) == 0) return null;
    var r: w.RECT = undefined;
    if (w.DwmGetWindowAttribute(hwnd, @intCast(w.DWMWA_EXTENDED_FRAME_BOUNDS), &r, @sizeOf(w.RECT)) < 0 and w.GetWindowRect(hwnd, &r) == 0) return null;
    return .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
}

/// Visible top-level windows with a title, top of the z-order first.
/// Tool windows (palettes, overlays) are left out unless they ask for a
/// taskbar button; cloaked ones (other virtual desktops, suspended apps)
/// only with `include_hidden`.
pub fn list(arena: std.mem.Allocator, include_hidden: bool) ![]const display.WindowInfo {
    var c: Collect = .{};
    _ = w.EnumWindows(Collect.callback, @bitCast(@intFromPtr(&c)));
    var out: std.ArrayList(display.WindowInfo) = .empty;
    var processes: std.ArrayList(ProcessInfo) = .empty;
    for (c.hwnds[0..c.len]) |hwnd| {
        var title: [512:0]u16 = undefined;
        const tlen = w.GetWindowTextW(hwnd, &title, title.len);
        if (tlen <= 0) continue;
        const ex: u32 = @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(hwnd, w.GWL_EXSTYLE))));
        if (ex & w.WS_EX_TOOLWINDOW != 0 and ex & w.WS_EX_APPWINDOW == 0) continue;
        const cloaked = isCloaked(hwnd);
        if (cloaked and !include_hidden) continue;
        var r: w.RECT = undefined;
        // The visible frame, without the invisible resize borders.
        if (w.DwmGetWindowAttribute(hwnd, @intCast(w.DWMWA_EXTENDED_FRAME_BOUNDS), &r, @sizeOf(w.RECT)) < 0) _ = w.GetWindowRect(hwnd, &r);
        if (r.right <= r.left or r.bottom <= r.top) continue;
        var pid: u32 = 0;
        _ = w.GetWindowThreadProcessId(hwnd, &pid);
        const proc = try processInfo(arena, &processes, pid);
        try out.append(arena, .{
            .handle = @intFromPtr(hwnd),
            .title = try utf8(arena, title[0..@intCast(tlen)]),
            .exe = proc.exe,
            .pid = pid,
            .rect = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top },
            .elevated = proc.elevated,
            .minimized = w.IsIconic(hwnd) != 0,
            .cloaked = cloaked,
        });
    }
    return out.items;
}

/// Brings the window to the foreground, restoring it if minimized, and
/// checks the result with GetForegroundWindow. Windows only grants the
/// foreground to the process that received the last input, so a refused
/// attempt is retried after a null mouse move and with the foreground
/// thread's input attached.
pub fn focus(handle: u64) display.FocusResult {
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return .closed;
    if (w.IsIconic(hwnd) != 0) _ = w.ShowWindow(hwnd, w.SW_RESTORE);
    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        if (w.GetForegroundWindow() == hwnd) return .ok;
        switch (attempt) {
            0 => _ = w.SetForegroundWindow(hwnd),
            1 => {
                var nudge = [_]w.INPUT{.{ .type = w.INPUT_MOUSE, .Anonymous = .{ .mi = .{ .dx = 0, .dy = 0, .mouseData = 0, .dwFlags = w.MOUSEEVENTF_MOVE, .time = 0, .dwExtraInfo = 0 } } }};
                _ = w.SendInput(1, &nudge, @sizeOf(w.INPUT));
                _ = w.SetForegroundWindow(hwnd);
            },
            else => {
                const fg = w.GetForegroundWindow();
                const fg_thread = if (fg != null) w.GetWindowThreadProcessId(fg, null) else 0;
                const me = w.GetCurrentThreadId();
                if (fg_thread != 0 and fg_thread != me) _ = w.AttachThreadInput(me, fg_thread, 1);
                _ = w.BringWindowToTop(hwnd);
                _ = w.SetForegroundWindow(hwnd);
                if (fg_thread != 0 and fg_thread != me) _ = w.AttachThreadInput(me, fg_thread, 0);
            },
        }
        var waited: u32 = 0;
        while (waited < 100) : (waited += 10) {
            if (w.GetForegroundWindow() == hwnd) return .ok;
            w.Sleep(10);
        }
    }
    if (w.IsWindow(hwnd) == 0) return .closed;
    return if (w.GetForegroundWindow() == hwnd) .ok else .refused;
}
