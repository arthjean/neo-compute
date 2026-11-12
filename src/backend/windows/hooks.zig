//! Physical kill switch (US-018): `WH_KEYBOARD_LL` and `WH_MOUSE_LL` hooks on
//! a dedicated thread with its own message loop. Injected events (ours or
//! any other SendInput caller's, `LLKHF_INJECTED`, `LLMHF_INJECTED`) never
//! count. During an action, a physical Escape (consumed) or a physical mouse
//! displacement over 8 px trips the switch: the action is cancelled, held
//! inputs are released from this thread, and the server pauses until the
//! physical re-arm shortcut. Windows silently removes a hook that exceeds
//! `LowLevelHooksTimeout`; a once-per-second check notices input the hooks
//! missed, reinstalls them and logs it.

const std = @import("std");
const w = @import("win32");
const Control = @import("../../core/control.zig").Control;
const keys = @import("../../core/keys.zig");

/// Physical displacement during an action that trips the switch.
pub const move_threshold_px = 8;
const check_ms = 1000;
/// The hooks see every input before the timer check runs on their thread:
/// system input newer than their last event by more than this (two tick
/// periods) means they were removed.
const missed_ms = 40;

const msg_release = w.WM_APP + 1;
const msg_simulate_key = w.WM_APP + 2;
const msg_simulate_move = w.WM_APP + 3;
const msg_remove = w.WM_APP + 4;
const msg_rearmed = w.WM_APP + 5;

/// Why the switch tripped (`msg_release` wParam).
const Cause = enum(usize) { escape, mouse };

pub const Rearm = struct { vk: u32, mods: keys.Mods };

pub const KillSwitch = struct {
    control: *Control,
    rearm: Rearm,
    release_ctx: *anyopaque,
    release: *const fn (*anyopaque) void,
    thread: ?std.Thread = null,
    thread_id: u32 = 0,
    ready: w.HANDLE = null,
    keyboard: w.HHOOK = null,
    mouse: w.HHOOK = null,

    // Hook thread state.
    mods: keys.Mods = .{},
    /// Key whose key-up is consumed with its key-down.
    swallow: ?u32 = null,
    last_pt: ?[2]i32 = null,
    moved: [2]i64 = .{ 0, 0 },
    seen_epoch: u32 = 0,
    last_log_tick: ?u32 = null,

    /// GetTickCount of the last event either hook saw.
    last_event_tick: std.atomic.Value(u32) = .init(0),
    reinstalls: std.atomic.Value(u32) = .init(0),
    trips: std.atomic.Value(u32) = .init(0),
    /// Injected events either hook saw, whoever sent them: never part of
    /// the kill switch, counted for the background selftest (EP-011).
    injected: std.atomic.Value(u32) = .init(0),
    /// Physical mouse events the hook saw and the tick of the last one,
    /// counted for the same selftest: a cursor that moved with the user's
    /// own mouse is not the server's doing. Never part of the kill switch.
    user_mouse: std.atomic.Value(u32) = .init(0),
    user_mouse_tick: std.atomic.Value(u32) = .init(0),
    /// Longest time spent in a hook procedure (selftest: < 1 ms).
    max_proc_ns: std.atomic.Value(u64) = .init(0),

    /// Installs the hooks on a new thread; returns once they are in place.
    pub fn start(self: *KillSwitch) !void {
        self.ready = w.CreateEventW(null, 0, 0, null);
        if (self.ready == null) return error.EventCreationFailed;
        instance = self;
        self.last_event_tick.store(w.GetTickCount(), .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        _ = w.WaitForSingleObject(self.ready, w.INFINITE);
        if (self.keyboard == null or self.mouse == null) {
            self.stop();
            return error.HookInstallFailed;
        }
    }

    pub fn stop(self: *KillSwitch) void {
        const t = self.thread orelse return;
        _ = w.PostThreadMessageW(self.thread_id, w.WM_QUIT, 0, 0);
        t.join();
        self.thread = null;
        _ = w.CloseHandle(self.ready);
        instance = null;
    }

    /// Feeds a physical key event to the hook logic on the hook thread, as
    /// if it came from the keyboard (selftest: no program can type a
    /// physical key).
    pub fn simulateKey(self: *KillSwitch, vk: u32, down: bool) void {
        _ = w.PostThreadMessageW(self.thread_id, msg_simulate_key, vk, @intFromBool(down));
    }

    /// Feeds a physical relative mouse move to the hook logic.
    pub fn simulateMove(self: *KillSwitch, dx: i32, dy: i32) void {
        _ = w.PostThreadMessageW(self.thread_id, msg_simulate_move, @as(u32, @bitCast(dx)), @as(i32, dy));
    }

    /// Unhooks without telling the check, as Windows does after a timeout.
    pub fn simulateRemoval(self: *KillSwitch) void {
        _ = w.PostThreadMessageW(self.thread_id, msg_remove, 0, 0);
    }

    fn install(self: *KillSwitch) void {
        const module = w.GetModuleHandleW(null);
        self.keyboard = w.SetWindowsHookExW(w.WH_KEYBOARD_LL, keyboardProc, module, 0);
        self.mouse = w.SetWindowsHookExW(w.WH_MOUSE_LL, mouseProc, module, 0);
        if (self.keyboard == null or self.mouse == null)
            std.debug.print("neo-compute: low-level hook installation failed ({d}): the physical kill switch is off\n", .{w.GetLastError()});
    }

    fn uninstall(self: *KillSwitch) void {
        if (self.keyboard != null) _ = w.UnhookWindowsHookEx(self.keyboard);
        if (self.mouse != null) _ = w.UnhookWindowsHookEx(self.mouse);
        self.keyboard = null;
        self.mouse = null;
    }

    fn loop(self: *KillSwitch) void {
        self.thread_id = w.GetCurrentThreadId();
        var msg: w.MSG = undefined;
        // Creates the thread's message queue before anyone posts to it.
        _ = w.PeekMessageW(&msg, null, 0, 0, w.PM_NOREMOVE);
        self.install();
        _ = w.SetTimer(null, 0, check_ms, null);
        _ = w.SetEvent(self.ready);
        while (w.GetMessageW(&msg, null, 0, 0) > 0) switch (msg.message) {
            w.WM_TIMER => self.check(),
            // Logged here, never inside a hook procedure: a blocked stderr
            // would hold the procedure past LowLevelHooksTimeout.
            msg_release => {
                self.release(self.release_ctx);
                std.debug.print("neo-compute: kill switch ({s}): action cancelled, server paused until the re-arm shortcut\n", .{if (msg.wParam == @backingInt(Cause.escape)) "Escape" else "mouse moved"});
            },
            msg_rearmed => std.debug.print("neo-compute: re-armed by the physical shortcut\n", .{}),
            msg_simulate_key => _ = self.onKey(@intCast(msg.wParam), msg.lParam != 0, false),
            msg_simulate_move => {
                const p = self.last_pt orelse cursor();
                self.last_pt = p;
                const dx: i32 = @bitCast(@as(u32, @truncate(msg.wParam)));
                const dy: i32 = @truncate(msg.lParam);
                self.onMouse(w.WM_MOUSEMOVE, .{ p[0] + dx, p[1] + dy }, false);
            },
            msg_remove => self.uninstall(),
            else => {},
        };
        self.uninstall();
    }

    /// Reinstalls the hooks when the system saw input they did not.
    fn check(self: *KillSwitch) void {
        var li: w.LASTINPUTINFO = .{ .cbSize = @sizeOf(w.LASTINPUTINFO), .dwTime = 0 };
        if (w.GetLastInputInfo(&li) == 0) return;
        const gap = li.dwTime -% self.last_event_tick.load(.acquire);
        if (gap >= 0x8000_0000 or gap <= missed_ms) return;
        self.uninstall();
        self.install();
        self.last_event_tick.store(w.GetTickCount(), .release);
        const n = self.reinstalls.fetchAdd(1, .acq_rel) + 1;
        const now = w.GetTickCount();
        if (self.last_log_tick == null or now -% self.last_log_tick.? > 60_000) {
            self.last_log_tick = now;
            std.debug.print("neo-compute: low-level hooks removed by Windows (LowLevelHooksTimeout) or bypassed: reinstalled ({d} time(s) so far)\n", .{n});
        }
    }

    /// Inputs are released, and the trip logged, from the message loop
    /// right after the hook procedure returns.
    fn trip(self: *KillSwitch, cause: Cause) bool {
        if (!self.control.trip()) return false;
        _ = self.trips.fetchAdd(1, .acq_rel);
        _ = w.PostThreadMessageW(self.thread_id, msg_release, @backingInt(cause), 0);
        return true;
    }

    /// Returns whether the event is consumed.
    fn onKey(self: *KillSwitch, vk: u32, down: bool, injected: bool) bool {
        if (injected) return false;
        if (modifierOf(vk)) |m| {
            const bits: u4 = @bitCast(self.mods);
            const bit: u4 = @bitCast(m);
            self.mods = @bitCast(if (down) bits | bit else bits & ~bit);
        }
        if (!down) {
            if (self.swallow != vk) return false;
            self.swallow = null;
            return true;
        }
        if (vk == w.VK_ESCAPE and self.trip(.escape)) {
            self.swallow = vk;
            return true;
        }
        if (vk == self.rearm.vk and @as(u4, @bitCast(self.mods)) == @as(u4, @bitCast(self.rearm.mods)) and self.control.rearm()) {
            self.swallow = vk;
            _ = w.PostThreadMessageW(self.thread_id, msg_rearmed, 0, 0);
            return true;
        }
        return false;
    }

    fn onMouse(self: *KillSwitch, message: u32, pt: [2]i32, injected: bool) void {
        const prev = self.last_pt;
        self.last_pt = pt;
        if (message != w.WM_MOUSEMOVE or injected) return;
        const p = prev orelse return;
        const epoch = self.control.epoch.load(.acquire);
        if (epoch != self.seen_epoch) {
            self.seen_epoch = epoch;
            self.moved = .{ 0, 0 };
        }
        if (!self.control.busy.load(.acquire)) return;
        self.moved[0] += pt[0] - p[0];
        self.moved[1] += pt[1] - p[1];
        if (self.moved[0] * self.moved[0] + self.moved[1] * self.moved[1] > move_threshold_px * move_threshold_px) {
            if (self.trip(.mouse)) self.moved = .{ 0, 0 };
        }
    }

    fn recordLatency(self: *KillSwitch, t0: i64) void {
        var t1: i64 = 0;
        var f: i64 = 1;
        _ = w.QueryPerformanceCounter(&t1);
        _ = w.QueryPerformanceFrequency(&f);
        const ns: u64 = @intCast(@divTrunc((t1 - t0) * 1_000_000_000, f));
        _ = self.max_proc_ns.fetchMax(ns, .acq_rel);
    }
};

/// The hook procedures have no context argument.
var instance: ?*KillSwitch = null;

fn modifierOf(vk: u32) ?keys.Mods {
    return switch (vk) {
        w.VK_SHIFT, w.VK_LSHIFT, w.VK_RSHIFT => .{ .shift = true },
        w.VK_CONTROL, w.VK_LCONTROL, w.VK_RCONTROL => .{ .ctrl = true },
        w.VK_MENU, w.VK_LMENU, w.VK_RMENU => .{ .alt = true },
        w.VK_LWIN, w.VK_RWIN => .{ .super = true },
        else => null,
    };
}

fn cursor() [2]i32 {
    var p: w.POINT = .{ .x = 0, .y = 0 };
    _ = w.GetCursorPos(&p);
    return .{ p.x, p.y };
}

fn qpc() i64 {
    var t: i64 = 0;
    _ = w.QueryPerformanceCounter(&t);
    return t;
}

fn keyboardProc(code: i32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    const ks = instance orelse return w.CallNextHookEx(null, code, wparam, lparam);
    if (code != w.HC_ACTION) return w.CallNextHookEx(null, code, wparam, lparam);
    const t0 = qpc();
    const info: *const w.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    ks.last_event_tick.store(w.GetTickCount(), .release);
    const down = wparam == w.WM_KEYDOWN or wparam == w.WM_SYSKEYDOWN;
    if (info.flags & w.LLKHF_INJECTED != 0) _ = ks.injected.fetchAdd(1, .monotonic);
    const eat = ks.onKey(info.vkCode, down, info.flags & w.LLKHF_INJECTED != 0);
    ks.recordLatency(t0);
    return if (eat) 1 else w.CallNextHookEx(null, code, wparam, lparam);
}

fn mouseProc(code: i32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    const ks = instance orelse return w.CallNextHookEx(null, code, wparam, lparam);
    if (code != w.HC_ACTION) return w.CallNextHookEx(null, code, wparam, lparam);
    const t0 = qpc();
    const info: *const w.MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    ks.last_event_tick.store(w.GetTickCount(), .release);
    if (info.flags & w.LLMHF_INJECTED != 0) {
        _ = ks.injected.fetchAdd(1, .monotonic);
    } else {
        ks.user_mouse_tick.store(w.GetTickCount(), .monotonic);
        _ = ks.user_mouse.fetchAdd(1, .monotonic);
    }
    ks.onMouse(@intCast(wparam), .{ info.pt.x, info.pt.y }, info.flags & w.LLMHF_INJECTED != 0);
    ks.recordLatency(t0);
    return w.CallNextHookEx(null, code, wparam, lparam);
}
