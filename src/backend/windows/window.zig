//! Top-level windows: enumeration in z-order for `window_list`, and
//! foreground activation for `window_focus`.

const std = @import("std");
const w = @import("win32");
const display = @import("../../core/display.zig");
const input = @import("input.zig");
const indicator = @import("indicator.zig");

const max_windows = 512;

const Collect = struct {
    hwnds: [max_windows]w.HWND = undefined,
    len: usize = 0,

    /// Keeps visible windows only, so hidden ones (often hundreds) never
    /// use up the cap ahead of visible windows lower in the z-order. The
    /// control indicator's windows (US-034) are never part of the desktop
    /// neo-compute reports: window_list, ui_tree roots, masking, the
    /// window stamp of ui_find's wait.
    fn callback(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
        const self: *Collect = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (w.IsWindowVisible(hwnd) == 0 or indicator.owns(hwnd)) return 1;
        if (self.len == max_windows) return 0;
        self.hwnds[self.len] = hwnd;
        self.len += 1;
        return 1;
    }
};

/// Hash of the set of visible top-level windows: it changes when one
/// appears or goes (US-030, a dialog that opens), not when the z-order does.
pub fn stamp() u64 {
    var c: Collect = .{};
    _ = w.EnumWindows(Collect.callback, @bitCast(@intFromPtr(&c)));
    const handles: []usize = @ptrCast(c.hwnds[0..c.len]);
    std.mem.sort(usize, handles, {}, std.sort.asc(usize));
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(handles));
}

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
                input.nudge();
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

/// Longest wait for Windows to show a window it agreed to put in front.
const restore_wait_ms = 100;

fn inFront(hwnd: w.HWND, ms: u32) bool {
    var waited: u32 = 0;
    while (true) : (waited += 5) {
        if (w.GetForegroundWindow() == hwnd) return true;
        if (waited >= ms) return false;
        w.Sleep(5);
    }
}

/// Gives the foreground back to the window that had it before a window of
/// the agent's target took it (US-050), without injected input.
///
/// The server holds no foreground right of its own, and Windows 11 refuses
/// it SetForegroundWindow, alone or with the foreground thread's input
/// attached (20 refusals out of 20 on build 26300, the attach itself
/// succeeding). What Windows does allow is an activation inside the input
/// queue that holds the foreground: this thread and the thread of the
/// user's window both join the queue of the window that took the
/// foreground, the user's window is raised and made the active window of
/// that queue, and the threads are detached again. The window gets the
/// activation messages it gets when the user switches back to it, so it
/// puts the keyboard focus where it keeps it (20 out of 20, focus
/// included, decision 0013).
///
/// The activation messages are sent to both windows: neither is touched
/// when its thread does not answer (`answers`): they would hold the
/// dispatcher.
pub fn restoreForeground(handle: u64) bool {
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return false;
    const fg = w.GetForegroundWindow();
    if (fg == hwnd) return true;
    if (w.SetForegroundWindow(hwnd) != 0) return inFront(hwnd, restore_wait_ms);
    if (fg == null or !answers(hwnd) or !answers(fg)) return false;
    const holder = w.GetWindowThreadProcessId(fg, null);
    const owner = w.GetWindowThreadProcessId(hwnd, null);
    const me = w.GetCurrentThreadId();
    if (holder == 0 or owner == 0) return false;
    const joined = holder != me and w.AttachThreadInput(me, holder, 1) != 0;
    const lent = owner != holder and w.AttachThreadInput(owner, holder, 1) != 0;
    if (joined and (lent or owner == holder)) {
        _ = w.BringWindowToTop(hwnd);
        _ = w.SetActiveWindow(hwnd);
    }
    if (lent) _ = w.AttachThreadInput(owner, holder, 0);
    if (joined) _ = w.AttachThreadInput(me, holder, 0);
    return inFront(hwnd, restore_wait_ms);
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

// ---------------------------------------------------------------- window_set (US-027)

/// Whether the window's thread answers within 200 ms: SetWindowPos and
/// ShowWindow send it messages and would block on a hung window.
fn answers(hwnd: w.HWND) bool {
    var result: usize = 0;
    return w.SendMessageTimeoutW(hwnd, w.WM_NULL, 0, 0, w.SMTO_ABORTIFHUNG, 200, &result) != 0;
}

pub fn placement(handle: u64) ?display.Placement {
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return null;
    var pid: u32 = 0;
    if (w.GetWindowThreadProcessId(hwnd, &pid) == 0) return null;
    return .{
        .frame = rect(hwnd) orelse return null,
        .pid = pid,
        .minimized = w.IsIconic(hwnd) != 0,
        .maximized = w.IsZoomed(hwnd) != 0,
        .elevated = input.isElevatedPid(pid),
    };
}

fn near(a: display.Rect, b: display.Rect) bool {
    return @abs(a.x - b.x) <= 1 and @abs(a.y - b.y) <= 1 and @abs(a.w - b.w) <= 1 and @abs(a.h - b.h) <= 1;
}

/// Places the visible frame of `handle` at `frame` (physical pixels),
/// restoring a minimized or maximized window first. SetWindowPos takes the
/// window rectangle, invisible resize borders included, so they are added;
/// a move to a display of another DPI resizes the window and its borders
/// (WM_DPICHANGED), hence up to three corrections.
pub fn place(handle: u64, frame: display.Rect, activate: bool) display.SetResult {
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return .closed;
    if (!answers(hwnd)) return .hung;
    if (w.IsIconic(hwnd) != 0 or w.IsZoomed(hwnd) != 0) {
        if (activate) _ = w.ShowWindow(hwnd, w.SW_RESTORE) else restoreQuiet(hwnd);
    }
    var got = rect(hwnd) orelse return .closed;
    var attempt: u32 = 0;
    while (attempt < 3 and !near(got, frame)) : (attempt += 1) {
        var wr: w.RECT = undefined;
        if (w.GetWindowRect(hwnd, &wr) == 0) return .closed;
        const l = got.x - wr.left;
        const t = got.y - wr.top;
        const r = wr.right - got.right();
        const b = wr.bottom - got.bottom();
        if (w.SetWindowPos(hwnd, null, frame.x - l, frame.y - t, frame.w + l + r, frame.h + t + b, w.SWP_NOZORDER | w.SWP_NOACTIVATE) == 0)
            return if (w.GetLastError() == w.ERROR_ACCESS_DENIED) .elevated else .failed;
        got = rect(hwnd) orelse return .closed;
    }
    return .{ .ok = got };
}

/// Restores `hwnd` without activating it (decision 0013, US-040).
/// SW_SHOWNOACTIVATE on a minimized window that is still the active window
/// of its own thread brings it to the foreground, past the foreground lock:
/// a maximize or restore the window handled itself leaves it in that state.
/// Hiding it first ends the state, and the window then comes back without
/// activation (35 restores out of 35 on the test window and the six
/// reference applications).
fn restoreQuiet(hwnd: w.HWND) void {
    if (w.IsIconic(hwnd) != 0) {
        var info = std.mem.zeroes(w.GUITHREADINFO);
        info.cbSize = @sizeOf(w.GUITHREADINFO);
        if (w.GetGUIThreadInfo(w.GetWindowThreadProcessId(hwnd, null), &info) != 0 and info.hwndActive == hwnd)
            _ = w.ShowWindow(hwnd, w.SW_HIDE);
    }
    _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
}

/// Restores, minimizes or maximizes `handle`, then waits up to 500 ms for
/// the state to show.
pub fn show(handle: u64, state: display.ShowState, activate: bool) display.SetResult {
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return .closed;
    if (!answers(hwnd)) return .hung;
    if (activate) {
        _ = w.ShowWindow(hwnd, switch (state) {
            .normal => w.SW_RESTORE,
            .minimized => w.SW_MINIMIZE,
            .maximized => w.SW_MAXIMIZE,
        });
    } else switch (state) {
        // The routes US-040 measured (decision 0013). SW_MAXIMIZE activates
        // the window; the title bar's own command, posted, does not.
        .normal => {
            restoreQuiet(hwnd);
            // A window minimized while maximized comes back maximized.
            if (w.IsZoomed(hwnd) != 0) _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
        },
        .minimized => _ = w.ShowWindow(hwnd, w.SW_SHOWMINNOACTIVE),
        .maximized => {
            if (w.IsIconic(hwnd) != 0) restoreQuiet(hwnd);
            _ = w.PostMessageW(hwnd, w.WM_SYSCOMMAND, w.SC_MAXIMIZE, 0);
        },
    }
    var waited: u32 = 0;
    while (waited < 500) : (waited += 10) {
        if (w.IsWindow(hwnd) == 0) return .closed;
        const iconic = w.IsIconic(hwnd) != 0;
        const zoomed = w.IsZoomed(hwnd) != 0;
        const reached = switch (state) {
            .normal => !iconic and !zoomed,
            .minimized => iconic,
            .maximized => zoomed,
        };
        if (reached) break;
        w.Sleep(10);
    }
    return .{ .ok = rect(hwnd) orelse return .closed };
}

/// Asks `handle` to close as its title bar's close button does
/// (WM_SYSCOMMAND / SC_CLOSE), posted so a hung window never blocks.
pub fn close(handle: u64) display.SetResult {
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return .closed;
    if (w.PostMessageW(hwnd, w.WM_SYSCOMMAND, w.SC_CLOSE, 0) == 0)
        return if (w.GetLastError() == w.ERROR_ACCESS_DENIED) .elevated else .failed;
    return .{ .ok = rect(hwnd) orelse .{ .x = 0, .y = 0, .w = 0, .h = 0 } };
}

const Hosted = struct { frame_pid: u32, pid: u32 = 0 };

fn hostedChild(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
    const h: *Hosted = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != 0 and pid != h.frame_pid) {
        h.pid = pid;
        return 0;
    }
    return 1;
}

/// Whether `handle` is the frame ApplicationFrameHost.exe shows a UWP
/// application in. Its content is XAML alone: no Win32 control under it
/// raises a WinEvent.
pub fn uwpFrame(handle: u64) bool {
    var cbuf: [64:0]u16 = undefined;
    return std.mem.eql(u16, className(@ptrFromInt(handle), &cbuf), std.unicode.utf8ToUtf16LeStringLiteral("ApplicationFrameWindow"));
}

/// Process of the application a window shows: a UWP frame
/// (`ApplicationFrameWindow`, owned by ApplicationFrameHost.exe, which hosts
/// every UWP window) shows the process of its CoreWindow child.
pub fn appPid(handle: u64) ?u32 {
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return null;
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    if (!uwpFrame(handle)) return pid;
    var h: Hosted = .{ .frame_pid = pid };
    _ = w.EnumChildWindows(hwnd, hostedChild, @bitCast(@intFromPtr(&h)));
    return if (h.pid != 0) h.pid else pid;
}

fn creationTime(pid: u32) ?u64 {
    const process = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = w.CloseHandle(process);
    var created: w.FILETIME = undefined;
    var exited: w.FILETIME = undefined;
    var kernel: w.FILETIME = undefined;
    var user: w.FILETIME = undefined;
    if (w.GetProcessTimes(process, &created, &exited, &kernel, &user) == 0) return null;
    return (@as(u64, created.dwHighDateTime) << 32) | created.dwLowDateTime;
}

/// This process and its ancestors (Claude Code among them), nearest first.
/// A parent pid whose process started after its child is a reused pid: the
/// chain stops there.
pub fn ancestors(arena: std.mem.Allocator) []const u32 {
    var out: std.ArrayList(u32) = .empty;
    const me = w.GetCurrentProcessId();
    out.append(arena, me) catch return &.{};
    const snap = w.CreateToolhelp32Snapshot(w.TH32CS_SNAPPROCESS, 0);
    if (snap == w.INVALID_HANDLE_VALUE or snap == null) return out.items;
    defer _ = w.CloseHandle(snap);
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var e: w.PROCESSENTRY32W = undefined;
    e.dwSize = @sizeOf(w.PROCESSENTRY32W);
    var more = w.Process32FirstW(snap, &e) != 0;
    while (more) : (more = w.Process32NextW(snap, &e) != 0) parents.put(arena, e.th32ProcessID, e.th32ParentProcessID) catch return out.items;
    var child = me;
    var child_created = creationTime(me) orelse std.math.maxInt(u64);
    while (out.items.len < 32) {
        const parent = parents.get(child) orelse break;
        if (parent == 0 or parent == 4 or std.mem.indexOfScalar(u32, out.items, parent) != null) break;
        const created = creationTime(parent) orelse break;
        if (created > child_created) break;
        out.append(arena, parent) catch break;
        child = parent;
        child_created = created;
    }
    return out.items;
}

pub fn alive(pid: u32) bool {
    const process = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer _ = w.CloseHandle(process);
    var code: u32 = 0;
    if (w.GetExitCodeProcess(process, &code) == 0) return false;
    return code == @as(u32, @bitCast(w.STILL_ACTIVE));
}

/// Terminates process `pid` and waits up to 1 s for it to exit.
pub fn terminate(pid: u32) bool {
    const process = w.OpenProcess(w.PROCESS_TERMINATE | w.PROCESS_SYNCHRONIZE, 0, pid) orelse return false;
    defer _ = w.CloseHandle(process);
    if (w.TerminateProcess(process, 1) == 0) return false;
    _ = w.WaitForSingleObject(process, 1000);
    return true;
}
