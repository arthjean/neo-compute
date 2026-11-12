//! Shared by the background probe (US-040) and the background selftest
//! (US-044): the decoy window of another process in the foreground, and the
//! witness that samples what a user would notice (foreground window,
//! keyboard focus, cursor, clipboard, injected input).

const std = @import("std");
const w = @import("win32");
const display = @import("../../core/display.zig");
const window = @import("window.zig");
const input = @import("input.zig");
const uia = @import("uia.zig");
const hooks = @import("hooks.zig");
const decoy_window = @import("decoy_window.zig");

/// UTF-8 path of this executable.
pub fn selfPath(buf: []u8) []const u8 {
    var path_w: [1024:0]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &path_w, path_w.len);
    return buf[0..std.unicode.wtf16LeToWtf8(buf, path_w[0..n])];
}

/// `neo-compute selftest-decoy` in the foreground, its text field focused.
pub const Decoy = struct {
    child: std.process.Child,
    hwnd: w.HWND,
    rect: display.Rect,

    pub fn start(io: std.Io, r: display.Rect) !Decoy {
        var path: [3 * 1024]u8 = undefined;
        const exe = selfPath(&path);
        var bufs: [4][16]u8 = undefined;
        var argv: [6][]const u8 = .{ exe, "selftest-decoy", "", "", "", "" };
        for ([_]i32{ r.x, r.y, r.w, r.h }, &bufs, argv[2..]) |v, *buf, *arg| arg.* = try std.fmt.bufPrint(buf, "{d}", .{v});
        var child = try std.process.spawn(io, .{ .argv = &argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        errdefer child.kill(io);
        var hwnd: w.HWND = null;
        var waited: u32 = 0;
        while (hwnd == null and waited < 3000) : (waited += 20) {
            hwnd = w.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral(decoy_window.class_name), null);
            if (hwnd == null) w.Sleep(20);
        }
        if (hwnd == null) return error.NoDecoyWindow;
        const d: Decoy = .{ .child = child, .hwnd = hwnd, .rect = r };
        if (!d.front()) return error.DecoyNotForeground;
        return d;
    }

    pub fn isFront(self: *const Decoy) bool {
        return w.GetForegroundWindow() == self.hwnd and focusWindow() != 0;
    }

    /// Asks the decoy to take the foreground back by itself, with the
    /// focus in its field. This process never does it for the decoy: the
    /// input event that grants the foreground would make this process, the
    /// server's, the one allowed to take it next. The decoy's own input
    /// event is an injected one: call this between two measures.
    pub fn front(self: *const Decoy) bool {
        var waited: u32 = 0;
        while (waited < 2000) : (waited += 40) {
            // Sent at least once: it is also the user's last input event.
            _ = w.SendMessageTimeoutW(self.hwnd, decoy_window.msg_front, 0, 0, w.SMTO_ABORTIFHUNG, 500, null);
            if (self.isFront()) return true;
            w.Sleep(40);
        }
        return self.isFront();
    }

    /// Whether `hwnd` lies entirely under the decoy: inside its rectangle and
    /// below it in the z-order.
    pub fn covers(self: *const Decoy, hwnd: w.HWND) bool {
        const r = window.rect(hwnd) orelse return false;
        if (w.IsIconic(hwnd) != 0) return false;
        if (r.x < self.rect.x or r.y < self.rect.y or r.right() > self.rect.right() or r.bottom() > self.rect.bottom()) return false;
        return above(self.hwnd, hwnd);
    }

    /// Puts `hwnd` right below the decoy in the z-order, without activating
    /// it: a window shown without activation still lands on top.
    pub fn tuck(self: *const Decoy, hwnd: w.HWND) void {
        _ = w.SetWindowPos(hwnd, self.hwnd, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
    }

    pub fn stop(self: *Decoy, io: std.Io) void {
        self.child.kill(io);
    }
};

/// Whether top-level window `a` is above `b` in the z-order.
pub fn above(a: w.HWND, b: w.HWND) bool {
    const Order = struct {
        a: w.HWND,
        b: w.HWND,
        first: w.HWND = null,
        fn callback(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
            const self: *@This() = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (hwnd != self.a and hwnd != self.b) return 1;
            self.first = hwnd;
            return 0;
        }
    };
    var o: Order = .{ .a = a, .b = b };
    _ = w.EnumWindows(Order.callback, @bitCast(@intFromPtr(&o)));
    return o.first == a;
}

/// Window with the keyboard focus in the foreground thread, 0 for none.
pub fn focusWindow() usize {
    var info: w.GUITHREADINFO = std.mem.zeroes(w.GUITHREADINFO);
    info.cbSize = @sizeOf(w.GUITHREADINFO);
    if (w.GetGUIThreadInfo(0, &info) == 0) return 0;
    return @intFromPtr(info.hwndFocus);
}

/// What a user would notice, plus this process's own counters.
pub const State = struct {
    foreground: usize,
    focus: usize,
    cursor: [2]i32,
    clipboard: u32,
    /// Injected events seen by the low-level hooks (0 without them).
    injected: u32,
    send_input: u32,
    set_focus: u32,
    /// GetTickCount when the sample started.
    tick: u32,
    /// Physical mouse events seen by the hooks, and the tick of the last
    /// one, read after the cursor (0 without the hooks).
    user_mouse: u32,
    user_mouse_tick: u32,

    pub fn sample(ks: ?*const hooks.KillSwitch) State {
        return .{
            .tick = w.GetTickCount(),
            .foreground = @intFromPtr(w.GetForegroundWindow()),
            .focus = focusWindow(),
            .cursor = input.cursorPosition(),
            .clipboard = w.GetClipboardSequenceNumber(),
            .injected = if (ks) |k| k.injected.load(.monotonic) else 0,
            .send_input = input.send_calls.load(.monotonic),
            .set_focus = uia.set_focus_calls.load(.monotonic),
            .user_mouse = if (ks) |k| k.user_mouse.load(.monotonic) else 0,
            .user_mouse_tick = if (ks) |k| k.user_mouse_tick.load(.monotonic) else 0,
        };
    }

    /// True when the user's own mouse moved between the two samples, or
    /// within 50 ms before the first: the hook sees a move slightly before
    /// the cursor position shows it.
    pub fn userMouse(before: State, after: State) bool {
        if (after.user_mouse == 0) return false;
        if (after.user_mouse != before.user_mouse) return true;
        const since: i32 = @bitCast(after.user_mouse_tick -% before.tick);
        return since >= -50;
    }
};

/// What changed between two samples: each is a violation of non-interference.
pub const Violation = packed struct(u8) {
    foreground: bool = false,
    focus: bool = false,
    cursor: bool = false,
    clipboard: bool = false,
    injected: bool = false,
    send_input: bool = false,
    set_focus: bool = false,
    _: u1 = 0,

    pub fn of(before: State, after: State) Violation {
        return .{
            .foreground = before.foreground != after.foreground,
            .focus = before.focus != after.focus,
            // The cursor is the user's: a move made with their own mouse
            // is not a violation. A move by this process goes through
            // SendInput, which `injected` and `send_input` flag anyway.
            .cursor = (before.cursor[0] != after.cursor[0] or before.cursor[1] != after.cursor[1]) and !State.userMouse(before, after),
            .clipboard = before.clipboard != after.clipboard,
            .injected = before.injected != after.injected,
            .send_input = before.send_input != after.send_input,
            .set_focus = before.set_focus != after.set_focus,
        };
    }

    pub fn any(self: Violation) bool {
        return @as(u8, @bitCast(self)) != 0;
    }

    /// `foreground focus cursor`, or `none`.
    pub fn text(self: Violation, buf: []u8) []const u8 {
        if (!self.any()) return "none";
        var wr: std.Io.Writer = .fixed(buf);
        inline for (.{ "foreground", "focus", "cursor", "clipboard", "injected", "send_input", "set_focus" }) |name| {
            if (@field(self, name)) wr.writeAll(name ++ " ") catch {};
        }
        return std.mem.trimEnd(u8, wr.buffered(), " ");
    }
};
