//! Change source of the background mode (US-048): the WinEvents
//! (accessibility notifications of Windows) of the target window's process,
//! received out of context on a dedicated thread with its own message loop.
//! Settling and ui_find's wait read one counter: it moves when the target's
//! process reports a change, whatever covers the window on screen.
//!
//! One target at a time, hooked when it is first asked for and unhooked when
//! another takes its place: a hook on every process would wake this thread
//! for the whole desktop. A UWP frame is watched with the application it
//! hosts, hence two process ids. The callback is a plain C function. The
//! UI Automation events of the same window are the other change source
//! (`uia_events.zig`): the backend adds the two counters.
//!
//! The same thread carries the foreground guard (US-050, `core/guard.zig`):
//! one more hook, on the foreground event alone, of every process. While
//! the dispatcher has a guard armed, a window of the agent's target that
//! comes in front is sent back from here, within milliseconds, whatever the
//! dispatcher is waiting on.

const std = @import("std");
const w = @import("win32");
const indicator = @import("indicator.zig");
const window = @import("window.zig");
const hooks = @import("hooks.zig");
const guard = @import("../../core/guard.zig");

const msg_watch = w.WM_APP + 1;
/// Period of the timer that waits for a foreground change to take effect,
/// and how long it waits before giving the change up.
const pending_poll_ms = 10;
const pending_wait_ms = 250;

/// One event as the probe of US-047 records it.
pub const Event = struct { id: u32, qpc: i64 };

/// The running watcher, for the callback, which has no context argument.
var instance: ?*Watcher = null;

pub const Watcher = struct {
    thread: ?std.Thread = null,
    thread_id: u32 = 0,
    ready: w.HANDLE = null,
    /// Signaled when the thread has applied the last `watch` request.
    applied: w.HANDLE = null,
    /// Selftest only: Windows refuses the hook.
    refuse: bool = false,

    // Dispatcher side: the processes last asked for.
    asked: [2]u32 = .{ 0, 0 },
    asked_refuse: bool = false,
    hooked: bool = false,
    /// Moves each time the hooks are installed anew: counts read under two
    /// different values do not compare.
    epoch: u32 = 0,

    // Hook thread state.
    hooks: [2]w.HWINEVENTHOOK = .{ null, null },
    /// The foreground event of every process, for the guard.
    foreground_hook: w.HWINEVENTHOOK = null,

    // Foreground guard, under `guard_lock`: the dispatcher arms and disarms
    // it, the hook thread acts on it.
    guard_lock: w.SRWLOCK = .{ .Ptr = null },
    guard: ?*guard.Watch = null,
    /// The input hooks, which know the user's gestures; null without them.
    guard_kill: ?*const hooks.KillSwitch = null,
    /// GetTickCount when the guard was armed.
    guard_tick: u32 = 0,
    /// A guard left armed after its action: GetTickCount when it was, and
    /// for how long it acts; 0 for a guard that acts until it is disarmed.
    guard_from: u32 = 0,
    guard_ms: u32 = 0,
    /// The window a foreground event named and that is not in front yet;
    /// when the event came (tick, and performance counter of the first
    /// event of the change); the thread timer that waits for it, 0 for none.
    pending: w.HWND = null,
    pending_tick: u32 = 0,
    pending_qpc: i64 = 0,
    timer: usize = 0,

    /// Change events of the watched processes since the thread started.
    count: std.atomic.Value(u64) = .init(0),
    /// QueryPerformanceCounter of the last one.
    last_qpc: std.atomic.Value(i64) = .init(0),
    /// Probe only (US-047): every event, the oldest overwritten.
    log: ?[]Event = null,
    log_len: std.atomic.Value(usize) = .init(0),

    pub fn start(self: *Watcher) !void {
        self.ready = w.CreateEventW(null, 0, 0, null);
        self.applied = w.CreateEventW(null, 0, 0, null);
        if (self.ready == null or self.applied == null) return error.EventCreationFailed;
        instance = self;
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        _ = w.WaitForSingleObject(self.ready, w.INFINITE);
    }

    pub fn stop(self: *Watcher) void {
        const t = self.thread orelse return;
        _ = w.PostThreadMessageW(self.thread_id, w.WM_QUIT, 0, 0);
        t.join();
        self.thread = null;
        _ = w.CloseHandle(self.ready);
        _ = w.CloseHandle(self.applied);
        instance = null;
    }

    /// Hooks the events of processes `pids` (0: none) in place of the ones
    /// watched before. False when Windows refuses the hook: the caller falls
    /// back to reading the tree again. Called from the dispatcher only.
    pub fn watch(self: *Watcher, pids: [2]u32) bool {
        if (self.asked[0] == pids[0] and self.asked[1] == pids[1] and self.asked_refuse == self.refuse) return self.hooked;
        self.asked = pids;
        self.asked_refuse = self.refuse;
        self.hooked = false;
        self.epoch +%= 1;
        if (w.PostThreadMessageW(self.thread_id, msg_watch, pids[0], pids[1]) == 0) return false;
        if (w.WaitForSingleObject(self.applied, 1000) != w.WAIT_OBJECT_0) return false;
        self.hooked = self.hooks[0] != null;
        return self.hooked;
    }

    pub fn stamp(self: *const Watcher) u64 {
        return self.count.load(.acquire);
    }

    /// Handle of the hook thread, for its CPU time (selftest).
    pub fn threadHandle(self: *const Watcher) ?w.HANDLE {
        return if (self.thread) |t| t.getHandle() else null;
    }

    /// Arms the foreground guard for the action that begins. `armed` stays
    /// the dispatcher's: it is not touched after `disarm` returns.
    pub fn arm(self: *Watcher, armed: *guard.Watch, kill: ?*const hooks.KillSwitch, tick: u32) void {
        w.AcquireSRWLockExclusive(&self.guard_lock);
        defer w.ReleaseSRWLockExclusive(&self.guard_lock);
        self.guard = armed;
        self.guard_kill = kill;
        self.guard_tick = tick;
        self.guard_ms = 0;
    }

    /// Arms the guard for `ms` from now: the action has returned, and a
    /// dialog it opened may still come in front.
    pub fn armFor(self: *Watcher, armed: *guard.Watch, kill: ?*const hooks.KillSwitch, tick: u32, ms: u32) void {
        w.AcquireSRWLockExclusive(&self.guard_lock);
        defer w.ReleaseSRWLockExclusive(&self.guard_lock);
        self.guard = armed;
        self.guard_kill = kill;
        self.guard_tick = tick;
        self.guard_from = w.GetTickCount();
        self.guard_ms = ms;
    }

    /// The armed guard, unless its time is over. Called under `guard_lock`.
    fn live(self: *Watcher) ?*guard.Watch {
        const g = self.guard orelse return null;
        if (self.guard_ms != 0 and w.GetTickCount() -% self.guard_from >= self.guard_ms) return null;
        return g;
    }

    /// Waits for a restoration in progress, then stops acting.
    pub fn disarm(self: *Watcher) void {
        w.AcquireSRWLockExclusive(&self.guard_lock);
        defer w.ReleaseSRWLockExclusive(&self.guard_lock);
        self.guard = null;
        // The timer, the hook thread's own, stops at its next tick.
        self.pending = null;
    }

    /// The foreground event names `hwnd`. Windows raises it when the switch
    /// starts: for a few milliseconds the foreground window is still the
    /// old one (measured: GetForegroundWindow kept answering the user's
    /// window on every event of the selftest). The window is remembered and
    /// a timer of this thread acts once it really is in front.
    fn onForeground(self: *Watcher, hwnd: w.HWND) void {
        w.AcquireSRWLockExclusive(&self.guard_lock);
        defer w.ReleaseSRWLockExclusive(&self.guard_lock);
        const g = self.live() orelse return;
        if (@intFromPtr(hwnd) == g.prev) {
            // The user's window again: a restoration, or their own return.
            self.pending = null;
            return;
        }
        if (self.pending == null) _ = w.QueryPerformanceCounter(&self.pending_qpc);
        self.pending = hwnd;
        self.pending_tick = w.GetTickCount();
        if (self.timer == 0) self.timer = w.SetTimer(null, 0, pending_poll_ms, null);
        self.settlePending(g);
    }

    /// The timer of a pending foreground change, on the hook thread.
    fn onTimer(self: *Watcher) void {
        w.AcquireSRWLockExclusive(&self.guard_lock);
        defer w.ReleaseSRWLockExclusive(&self.guard_lock);
        const g = self.live();
        if (g) |armed| self.settlePending(armed);
        if (g == null or self.pending == null) {
            _ = w.KillTimer(null, self.timer);
            self.timer = 0;
            self.pending = null;
        }
    }

    /// Once the pending window is in front: with no gesture of the user
    /// around the action, a window of the agent's target is sent back
    /// behind the user's window. Called under `guard_lock`.
    fn settlePending(self: *Watcher, g: *guard.Watch) void {
        const hwnd = self.pending orelse return;
        if (w.GetForegroundWindow() != hwnd) {
            // The switch never happened, or someone else took over.
            if (w.GetTickCount() -% self.pending_tick > pending_wait_ms) self.pending = null;
            return;
        }
        self.pending = null;
        const gesture: ?bool = if (self.guard_kill) |k| k.gestureSince(self.guard_tick -% guard.gesture_slack_ms) else null;
        const target: ?u32 = if (g.target != 0) window.appPid(g.target) else null;
        if (g.onForeground(@intFromPtr(hwnd), window.appPid(@intFromPtr(hwnd)), target, window.appPid(g.prev), gesture) != .restore) return;
        var t0: i64 = 0;
        var t1: i64 = 0;
        var f: i64 = 1;
        _ = w.QueryPerformanceCounter(&t0);
        const ok = window.restoreForeground(g.prev);
        _ = w.QueryPerformanceCounter(&t1);
        _ = w.QueryPerformanceFrequency(&f);
        g.done(ok, @intCast(@divTrunc(@max(t1 - t0, 0) * 1_000_000_000, f)));
        g.exposed_ns = @max(g.exposed_ns, @as(u64, @intCast(@divTrunc(@max(t1 - self.pending_qpc, 0) * 1_000_000_000, f))));
    }

    fn unhook(self: *Watcher) void {
        for (&self.hooks) |*h| {
            if (h.* != null) _ = w.UnhookWinEvent(h.*);
            h.* = null;
        }
    }

    fn apply(self: *Watcher, pids: [2]u32) void {
        self.unhook();
        if (self.refuse) return;
        for (pids, &self.hooks) |pid, *h| {
            if (pid == 0) continue;
            h.* = w.SetWinEventHook(w.EVENT_MIN, w.EVENT_MAX, null, callback, pid, 0, w.WINEVENT_OUTOFCONTEXT);
        }
        // The window's own process is the one that must be hooked.
        if (self.hooks[0] == null) {
            std.debug.print("neo-compute: SetWinEventHook refused for process {d} (error {d}): settling reads the tree again instead\n", .{ pids[0], w.GetLastError() });
            self.unhook();
        }
    }

    fn loop(self: *Watcher) void {
        self.thread_id = w.GetCurrentThreadId();
        var msg: w.MSG = undefined;
        // Creates the thread's message queue before anyone posts to it.
        _ = w.PeekMessageW(&msg, null, 0, 0, w.PM_NOREMOVE);
        // Refused: the guard still looks when the action ends.
        self.foreground_hook = w.SetWinEventHook(w.EVENT_SYSTEM_FOREGROUND, w.EVENT_SYSTEM_FOREGROUND, null, foregroundCallback, 0, 0, w.WINEVENT_OUTOFCONTEXT);
        if (self.foreground_hook == null) std.debug.print("neo-compute: SetWinEventHook refused for the foreground event (error {d}): the foreground guard acts when the action ends\n", .{w.GetLastError()});
        _ = w.SetEvent(self.ready);
        // Out-of-context events are delivered while this loop waits.
        while (w.GetMessageW(&msg, null, 0, 0) > 0) {
            if (msg.message == msg_watch) {
                self.apply(.{ @truncate(msg.wParam), @truncate(@as(usize, @bitCast(msg.lParam))) });
                _ = w.SetEvent(self.applied);
            } else if (msg.message == w.WM_TIMER) self.onTimer();
        }
        self.unhook();
        if (self.foreground_hook != null) _ = w.UnhookWinEvent(self.foreground_hook);
        self.foreground_hook = null;
    }

    fn foregroundCallback(_: w.HWINEVENTHOOK, _: u32, hwnd: w.HWND, _: i32, _: i32, _: u32, _: u32) callconv(.winapi) void {
        const self = instance orelse return;
        if (hwnd != null) self.onForeground(hwnd);
    }

    fn callback(_: w.HWINEVENTHOOK, event: u32, hwnd: w.HWND, id_object: i32, _: i32, _: u32, _: u32) callconv(.winapi) void {
        const self = instance orelse return;
        // The cursor is the user's, and the control indicator is the
        // server's own window (a target in the server's process exists only
        // in the selftest): neither is a change of the target.
        if (id_object == w.OBJID_CURSOR or indicator.owns(hwnd)) return;
        var t: i64 = 0;
        _ = w.QueryPerformanceCounter(&t);
        self.last_qpc.store(t, .release);
        if (self.log) |log| {
            const i = self.log_len.fetchAdd(1, .acq_rel);
            log[i % log.len] = .{ .id = event, .qpc = t };
        }
        _ = self.count.fetchAdd(1, .acq_rel);
    }
};
