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

    pub fn init(gpa: std.mem.Allocator) Windows {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Windows) void {
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
        return input.sendMouse(&self.held, events);
    }

    pub fn cursorPosition(self: *Windows) [2]i32 {
        _ = self;
        return input.cursorPosition();
    }

    pub fn keyCombo(self: *Windows, combo: keys.Combo, action: core_input.KeyAction) core_input.InputError!void {
        return input.keyCombo(&self.held, combo, action);
    }

    pub fn typeText(self: *Windows, units: []const u16) core_input.InputError!void {
        _ = self;
        return input.typeText(units);
    }

    pub fn targetAt(self: *Windows, point: ?[2]i32) core_input.Target {
        _ = self;
        return input.targetAt(point);
    }

    /// Lets go of every key and button neo-compute holds (FR-07).
    pub fn releaseAllInputs(self: *Windows) void {
        if (self.held.count() > 0) input.releaseAll(&self.held);
    }

    // ------------------------------------------------------------ windows

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
