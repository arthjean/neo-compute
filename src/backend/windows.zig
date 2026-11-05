//! Windows backend: DXGI capture, SendInput, window enumeration, plus the
//! process setup, the selftest and the bench scenarios. Implements every
//! method the core calls on `ctx.backend`.

const std = @import("std");
const w = @import("win32");
const bench = @import("../core/bench.zig");
const display = @import("../core/display.zig");
const core_input = @import("../core/input.zig");
const keys = @import("../core/keys.zig");
const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;
const capture_mod = @import("windows/capture.zig");
const input = @import("windows/input.zig");
const window = @import("windows/window.zig");
const com = @import("windows/com.zig");
const uia = @import("windows/uia.zig");
const hooks = @import("windows/hooks.zig");
const Control = @import("../core/control.zig").Control;
const uitree = @import("../core/uitree.zig");
const Capture = capture_mod.Capture;
const fmt = @import("../core/session.zig").fmt;

pub const secure_desktop_message = "Bureau sécurisé actif (UAC ou verrouillage) : capture impossible, réessaie après sa fermeture";

pub const Windows = struct {
    gpa: std.mem.Allocator,
    cap: ?Capture = null,
    displays_buf: [display.max_displays]display.Display = undefined,
    names: [display.max_displays][96]u8 = undefined,
    displays_len: usize = 0,
    held: input.Held = .{},
    /// Guards `held`: the kill switch thread releases inputs too (US-018).
    held_lock: w.SRWLOCK = .{ .Ptr = null },
    ui: uia.Worker,
    kill: ?*hooks.KillSwitch = null,

    pub fn init(gpa: std.mem.Allocator) Windows {
        return .{ .gpa = gpa, .ui = .{ .gpa = gpa } };
    }

    pub fn deinit(self: *Windows) void {
        self.stopKillSwitch();
        self.ui.deinit();
        if (self.cap) |*c| c.deinit(self.gpa);
        self.cap = null;
    }

    /// Per-monitor v2 DPI awareness, before any window exists, so Win32,
    /// DXGI and UI Automation all report physical pixels.
    pub fn initProcess() void {
        if (w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == 0) {
            // ERROR_ACCESS_DENIED means awareness was already set (manifest).
            if (w.GetLastError() != w.ERROR_ACCESS_DENIED)
                std.debug.print("neo-compute: SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2) failed: {d}\n", .{w.GetLastError()});
        }
    }

    // ------------------------------------------------------------ displays and capture

    /// The DXGI outputs, re-enumerated when the display configuration
    /// changed (IDXGIFactory1::IsCurrent).
    fn ensure(self: *Windows) ?*Capture {
        if (self.cap) |*c| {
            if (c.isCurrent()) return c;
            c.deinit(self.gpa);
            self.cap = null;
        }
        self.cap = Capture.init(self.gpa) catch |err| {
            std.debug.print("neo-compute: DXGI output enumeration failed: {t} hr=0x{x}\n", .{ err, com.lastHr() });
            return null;
        };
        const c = &self.cap.?;
        self.displays_len = @min(c.outputs.items.len, display.max_displays);
        for (c.outputs.items[0..self.displays_len], 0..) |*o, i| {
            const r = o.rect();
            const n = o.name();
            @memcpy(self.names[i][0..n.len], n);
            self.displays_buf[i] = .{ .rect = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top }, .name = self.names[i][0..n.len] };
        }
        return c;
    }

    pub fn displays(self: *Windows) []const display.Display {
        if (self.ensure() == null) return &.{};
        return self.displays_buf[0..self.displays_len];
    }

    pub fn foregroundDisplay(self: *Windows) ?usize {
        const c = self.ensure() orelse return null;
        const fg = w.GetForegroundWindow();
        if (fg == null) return null;
        const mon = w.MonitorFromWindow(fg, w.MONITOR_DEFAULTTONEAREST);
        for (c.outputs.items[0..self.displays_len], 0..) |o, i| if (o.desc.Monitor == mon) return i;
        return null;
    }

    /// Latest frame of display `index`: a new one when the screen changed,
    /// the cached one otherwise, without waiting.
    pub fn capture(self: *Windows, index: usize, arena: std.mem.Allocator) display.CaptureResult {
        // `failure` classifies by the HRESULT of this call only: a stale
        // E_ACCESSDENIED would turn an allocation failure into the
        // secure-desktop message.
        com.last_hr = 0;
        const c = self.ensure() orelse return .{ .failed = if (capture_mod.secureDesktopActive()) secure_desktop_message else "DXGI indisponible : aucune sortie d'écran énumérée, réessaie." };
        if (index >= self.displays_len) return .{ .failed = fmt(arena, "Écran {d} déconnecté : refais un screenshot.", .{index}) };
        const o = &c.outputs.items[index];
        o.beginCapture();
        if (o.dup == null) self.recreate(o) catch |err| return self.failure(arena, index, o, err);
        const fresh = o.acquire(self.gpa, if (o.has_frame) 0 else 500) catch |err| switch (err) {
            error.AccessLost => blk: {
                // Mode change, UAC, exclusive full screen: recreate the
                // duplication and try once more.
                self.recreate(o) catch |e| return self.failure(arena, index, o, e);
                break :blk o.acquire(self.gpa, 500) catch |e| return self.failure(arena, index, o, e);
            },
            else => return self.failure(arena, index, o, err),
        };
        if (!o.has_frame) return .{ .failed = "Capture réinitialisée : réessaie." };
        return .{ .frame = .{
            .pixels = o.pixels,
            .width = o.width,
            .height = o.height,
            .stride = @as(usize, o.width) * 4,
            .fresh = fresh,
            .dirty = o.dirty.items,
            .moved = o.moved.items,
        } };
    }

    /// Recreates a lost duplication; logs when it misses the 500 ms budget.
    fn recreate(self: *Windows, o: *capture_mod.Output) capture_mod.Error!void {
        _ = self;
        var t0: i64 = 0;
        _ = w.QueryPerformanceCounter(&t0);
        try o.duplicate();
        var t1: i64 = 0;
        var freq: i64 = 1;
        _ = w.QueryPerformanceCounter(&t1);
        _ = w.QueryPerformanceFrequency(&freq);
        const ms = @divTrunc((t1 - t0) * 1000, freq);
        if (ms >= 500) std.debug.print("neo-compute: duplication of {s} recreated in {d} ms (budget 500 ms)\n", .{ o.name(), ms });
    }

    /// Forces the recreation of display `index`'s duplication and returns
    /// its duration in microseconds (selftest of the ACCESS_LOST path).
    pub fn recreateForTest(self: *Windows, index: usize) !u64 {
        const c = self.ensure() orelse return error.NoOutputs;
        const o = &c.outputs.items[index];
        var t0: i64 = 0;
        var t1: i64 = 0;
        var freq: i64 = 1;
        _ = w.QueryPerformanceFrequency(&freq);
        _ = w.QueryPerformanceCounter(&t0);
        try self.recreate(o);
        _ = w.QueryPerformanceCounter(&t1);
        return @intCast(@divTrunc((t1 - t0) * 1_000_000, freq));
    }

    fn failure(self: *Windows, arena: std.mem.Allocator, index: usize, o: *capture_mod.Output, err: capture_mod.Error) display.CaptureResult {
        const hr = com.last_hr;
        if (capture_mod.secureDesktopActive() or hr == w.E_ACCESSDENIED) return .{ .failed = secure_desktop_message };
        if (err == error.Unsupported or hr == w.DXGI_ERROR_UNSUPPORTED)
            return .{ .failed = fmt(arena, "Écran {d} ({s}, adaptateur {s}) : DXGI Desktop Duplication non supportée (DXGI_ERROR_UNSUPPORTED). Le repli Windows.Graphics.Capture n'est pas disponible en v1 : capture un autre écran.", .{ index, o.name(), o.adapterName() }) };
        if (hr == w.DXGI_ERROR_SESSION_DISCONNECTED)
            return .{ .failed = "Session Windows inactive : capture impossible tant que la session n'est pas au premier plan" };
        // Device removed, driver reset or a stale output: start over on
        // the next call.
        std.debug.print("neo-compute: capture of {s} failed: {t} hr=0x{x}\n", .{ o.name(), err, com.lastHr() });
        if (self.cap) |*c| c.deinit(self.gpa);
        self.cap = null;
        return .{ .failed = "Capture réinitialisée : réessaie." };
    }

    // ------------------------------------------------------------ input

    pub fn sendMouse(self: *Windows, events: []const core_input.MouseEvent) core_input.InputError!void {
        w.AcquireSRWLockExclusive(&self.held_lock);
        defer w.ReleaseSRWLockExclusive(&self.held_lock);
        return input.sendMouse(&self.held, events);
    }

    pub fn cursorPosition(self: *Windows) [2]i32 {
        _ = self;
        return input.cursorPosition();
    }

    pub fn keyCombo(self: *Windows, combo: keys.Combo, action: core_input.KeyAction) core_input.InputError!void {
        w.AcquireSRWLockExclusive(&self.held_lock);
        defer w.ReleaseSRWLockExclusive(&self.held_lock);
        return input.keyCombo(&self.held, combo, action);
    }

    /// Pause after each typed character. TranslateMessage reads a VK_PACKET
    /// character from the thread's latest packet, not from the message, so a
    /// target that pumps late (Notepad) turns queued characters into the last
    /// one sent ("Fin du ........."). Measured on Notepad 11: 4 ms still
    /// drops characters, 8 ms and more types them all.
    pub const type_pace_ns = 10 * std.time.ns_per_ms;

    pub fn typeText(self: *Windows, units: []const u16) core_input.InputError!void {
        _ = self;
        return input.typeText(units);
    }

    pub fn targetAt(self: *Windows, point: ?[2]i32) core_input.Target {
        _ = self;
        return input.targetAt(point);
    }

    /// Lets go of every key and button neo-compute holds (FR-07). Called
    /// from the dispatcher and from the kill switch thread.
    pub fn releaseAllInputs(self: *Windows) void {
        w.AcquireSRWLockExclusive(&self.held_lock);
        defer w.ReleaseSRWLockExclusive(&self.held_lock);
        if (self.held.count() > 0) input.releaseAll(&self.held);
    }

    // ------------------------------------------------------------ human control (EP-004)

    /// Starts the physical kill switch (US-018) on its own thread. Without
    /// it (hooks refused) the server runs and says so on stderr.
    pub fn startKillSwitch(self: *Windows, control: *Control, rearm: keys.Combo) void {
        const vk = input.vkOf(rearm) orelse {
            std.debug.print("neo-compute: re-arm key has no virtual key on this layout: the physical kill switch is off\n", .{});
            return;
        };
        const ks = self.gpa.create(hooks.KillSwitch) catch return;
        ks.* = .{ .control = control, .rearm = .{ .vk = vk, .mods = rearm.mods }, .release_ctx = self, .release = releaseFromHook };
        ks.start() catch |err| {
            std.debug.print("neo-compute: kill switch unavailable ({t})\n", .{err});
            self.gpa.destroy(ks);
            return;
        };
        self.kill = ks;
    }

    fn releaseFromHook(ctx: *anyopaque) void {
        const self: *Windows = @ptrCast(@alignCast(ctx));
        self.releaseAllInputs();
    }

    pub fn stopKillSwitch(self: *Windows) void {
        const ks = self.kill orelse return;
        ks.stop();
        self.gpa.destroy(ks);
        self.kill = null;
    }

    /// Takes the session-wide named mutex (US-019, FR-14). False when
    /// another neo-compute already controls this desktop. The owner keeps
    /// the handle until it exits.
    pub fn acquireInstance() bool {
        const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\neo-compute-desktop");
        const handle = w.CreateMutexW(null, 0, name);
        if (handle == null) return true;
        if (w.GetLastError() == w.ERROR_ALREADY_EXISTS) {
            _ = w.CloseHandle(handle);
            return false;
        }
        return true;
    }

    // ------------------------------------------------------------ policy targets and masking

    pub fn windowAt(self: *Windows, point: ?[2]i32) ?display.WindowRef {
        _ = self;
        return window.at(point);
    }

    pub fn windowRef(self: *Windows, handle: u64) ?display.WindowRef {
        _ = self;
        return window.ref(handle);
    }

    pub fn processName(self: *Windows, arena: std.mem.Allocator, pid: u32) ?[]const u8 {
        _ = self;
        return window.processName(arena, pid) catch null;
    }

    pub fn visibleWindows(self: *Windows, arena: std.mem.Allocator) error{OutOfMemory}![]const display.VisibleWindow {
        _ = self;
        return window.visible(arena);
    }

    /// Starts the foreground window's password field scan on the UIA worker.
    pub fn beginSecretScan(self: *Windows) void {
        self.ui.beginSecrets();
    }

    pub fn secretRects(self: *Windows) []const display.Rect {
        return self.ui.secretRects();
    }

    // ------------------------------------------------------------ accessibility

    /// Tree of `window` (the foreground window when null), read on the UIA
    /// worker thread.
    pub fn uiSnapshot(self: *Windows, arena: std.mem.Allocator, hwnd: ?u64) uitree.SnapshotResult {
        return self.ui.snapshot(arena, hwnd);
    }

    pub fn uiAct(self: *Windows, arena: std.mem.Allocator, hwnd: u64, key: u64, action: uitree.Action, value: ?[]const u8) uitree.ActResult {
        return self.ui.act(arena, hwnd, key, action, value);
    }

    // ------------------------------------------------------------ windows

    /// Visible frame of `hwnd`, else of the foreground window (settling).
    pub fn windowRect(self: *Windows, hwnd: ?u64) ?display.Rect {
        _ = self;
        return window.rect(if (hwnd) |h| @ptrFromInt(h) else w.GetForegroundWindow());
    }

    pub fn listWindows(self: *Windows, arena: std.mem.Allocator, include_hidden: bool) error{OutOfMemory}![]const display.WindowInfo {
        _ = self;
        return window.list(arena, include_hidden);
    }

    pub fn focusWindow(self: *Windows, handle: u64) display.FocusResult {
        _ = self;
        return window.focus(handle);
    }

    // ------------------------------------------------------------ tooling

    pub const selftest = @import("windows/selftest.zig").run;

    pub fn benchScenario(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, name: []const u8, iterations: ?usize) !bench.Outcome {
        return @import("windows/bench.zig").run(gpa, io, counter, name, iterations);
    }
};
