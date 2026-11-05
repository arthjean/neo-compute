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
    return try processName(arena, pid) orelse "?";
}

/// Executable file name of process `pid` (`notepad.exe`), null when the
/// process cannot be queried.
pub fn processName(arena: std.mem.Allocator, pid: u32) !?[]const u8 {
    const process = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = w.CloseHandle(process);
    var path: [1024:0]u16 = undefined;
    var len: u32 = path.len;
    if (w.QueryFullProcessImageNameW(process, w.PROCESS_NAME_WIN32, &path, &len) == 0) return null;
    const full = path[0..len];
    const base = if (std.mem.lastIndexOfScalar(u16, full, '\\')) |i| full[i + 1 ..] else full;
    return try utf8(arena, base);
}

fn refOf(hwnd: w.HWND) ?display.WindowRef {
    if (hwnd == null) return null;
    var pid: u32 = 0;
    if (w.GetWindowThreadProcessId(hwnd, &pid) == 0) return null;
    return .{ .handle = @intFromPtr(hwnd), .pid = pid };
}

/// Top-level window under physical point `p`, else the foreground window.
pub fn at(point: ?[2]i32) ?display.WindowRef {
    const hwnd = if (point) |p| w.WindowFromPoint(.{ .x = p[0], .y = p[1] }) else w.GetForegroundWindow();
    if (hwnd == null) return null;
    return refOf(w.GetAncestor(hwnd, w.GA_ROOT) orelse hwnd);
}

pub fn ref(handle: u64) ?display.WindowRef {
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return null;
    return refOf(hwnd);
}

/// Visible, non-minimized, non-cloaked top-level windows, top of the
/// z-order first, for the screenshot blackout of `deny` windows. Layered
/// and transparent windows are not `solid`.
pub fn visible(arena: std.mem.Allocator) ![]const display.VisibleWindow {
    var c: Collect = .{};
    _ = w.EnumWindows(Collect.callback, @bitCast(@intFromPtr(&c)));
    var out: std.ArrayList(display.VisibleWindow) = .empty;
    for (c.hwnds[0..c.len]) |hwnd| {
        if (w.IsIconic(hwnd) != 0 or isCloaked(hwnd)) continue;
        const r = rect(hwnd) orelse continue;
        if (r.w <= 0 or r.h <= 0) continue;
        var pid: u32 = 0;
        _ = w.GetWindowThreadProcessId(hwnd, &pid);
        const ex: u32 = @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(hwnd, w.GWL_EXSTYLE))));
        const solid = ex & (w.WS_EX_LAYERED | w.WS_EX_TRANSPARENT) == 0;
        try out.append(arena, .{ .handle = @intFromPtr(hwnd), .pid = pid, .rect = r, .solid = solid });
    }
    return out.items;
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

// ---------------------------------------------------------------- snapshot roots

/// Further roots read with a window's tree (US-023), at most this many.
pub const max_extra_roots = 8;

fn className(hwnd: w.HWND, buf: *[64:0]u16) []const u16 {
    const n = w.GetClassNameW(hwnd, buf, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else &.{};
}

fn isDesktopClass(class: []const u16) bool {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    for ([_][]const u16{ L("Progman"), L("WorkerW"), L("Shell_TrayWnd"), L("Shell_SecondaryTrayWnd") }) |c| if (std.mem.eql(u16, class, c)) return true;
    return false;
}

/// Whether `owner` is up `hwnd`'s GW_OWNER chain.
fn ownedBy(hwnd: w.HWND, owner: w.HWND) bool {
    var h = hwnd;
    var depth: u32 = 0;
    while (depth < 8) : (depth += 1) {
        h = w.GetWindow(h, w.GW_OWNER) orelse return false;
        if (h == owner) return true;
    }
    return false;
}

fn style(hwnd: w.HWND) u32 {
    return @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(hwnd, w.GWL_STYLE))));
}

/// The visible top-level windows read with `target`'s tree (the foreground
/// window when null), top of the z-order first: the windows it owns
/// (GW_OWNER chain), menus (`#32768`), and the popups of its UI thread, such
/// as XAML context menus and drop-down lists. A popup is captionless and
/// asks for no taskbar button, so another top-level window of the same
/// process (a second browser window) is never one. The desktop and the
/// taskbar have none.
pub fn extraRoots(arena: std.mem.Allocator, target_handle: ?u64) []const @import("../../core/uitree.zig").RootWindow {
    const RootWindow = @import("../../core/uitree.zig").RootWindow;
    const target: w.HWND = if (target_handle) |h| @ptrFromInt(h) else w.GetForegroundWindow();
    if (target == null or w.IsWindow(target) == 0) return &.{};
    var cbuf: [64:0]u16 = undefined;
    if (isDesktopClass(className(target, &cbuf))) return &.{};
    var target_pid: u32 = 0;
    const target_thread = w.GetWindowThreadProcessId(target, &target_pid);
    var c: Collect = .{};
    _ = w.EnumWindows(Collect.callback, @bitCast(@intFromPtr(&c)));
    var out: std.ArrayList(RootWindow) = .empty;
    const menu_class = std.unicode.utf8ToUtf16LeStringLiteral("#32768");
    for (c.hwnds[0..c.len]) |hwnd| {
        if (hwnd == target or w.IsIconic(hwnd) != 0 or isCloaked(hwnd)) continue;
        const r = rect(hwnd) orelse continue;
        if (r.w < 4 or r.h < 4) continue;
        var pid: u32 = 0;
        const thread = w.GetWindowThreadProcessId(hwnd, &pid);
        const class = className(hwnd, &cbuf);
        const keep = ownedBy(hwnd, target) or std.mem.eql(u16, class, menu_class) or blk: {
            if (thread != target_thread or isDesktopClass(class)) break :blk false;
            const st = style(hwnd);
            const ex: u32 = @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(hwnd, w.GWL_EXSTYLE))));
            break :blk st & w.WS_POPUP != 0 and st & w.WS_CHILD == 0 and st & w.WS_CAPTION != w.WS_CAPTION and ex & w.WS_EX_APPWINDOW == 0;
        };
        if (!keep) continue;
        out.append(arena, .{ .handle = @intFromPtr(hwnd), .pid = pid }) catch break;
        if (out.items.len == max_extra_roots) break;
    }
    return out.items;
}

/// A modal root: its owner window is disabled while it is open.
pub fn ownerDisabled(hwnd: w.HWND) bool {
    const owner = w.GetWindow(hwnd, w.GW_OWNER) orelse return false;
    return w.IsWindowEnabled(owner) == 0;
}
