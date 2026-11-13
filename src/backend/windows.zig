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
const indicator_mod = @import("windows/indicator.zig");
const winevents = @import("windows/winevents.zig");
const uia_events = @import("windows/uia_events.zig");
const shell_mod = @import("windows/shell.zig");
const clip_mod = @import("windows/clipboard.zig");
const reg_mod = @import("windows/regread.zig");
const clipboard = @import("../core/clipboard.zig");
const regread = @import("../core/regread.zig");
const apps = @import("../core/apps.zig");
const Control = @import("../core/control.zig").Control;
const guard = @import("../core/guard.zig");
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
    /// Shell APIs on their own STA thread (EP-006).
    shell: shell_mod.Shell,
    /// Clipboard worker (US-035), created on first use.
    clip: ?*clip_mod.Clipboard = null,
    kill: ?*hooks.KillSwitch = null,
    /// Control indicator (US-034), null when off or unavailable.
    indicator: ?*indicator_mod.Indicator = null,
    /// Selftest only: the indicator fails to start, as if its windows
    /// could not be created.
    refuse_indicator: bool = false,
    /// WinEvents of the background target's process (US-048), started on
    /// first use.
    events: ?*winevents.Watcher = null,
    /// Selftest only: Windows refuses the WinEvent hook.
    refuse_events: bool = false,
    /// The window whose UI Automation events are subscribed to, whether the
    /// subscription holds, and GetTickCount of the last attempt.
    uia_window: u64 = 0,
    uia_listening: bool = false,
    uia_tick: u32 = 0,
    /// Probe only (`events-probe`): `windowEvents` subscribes to nothing,
    /// the probe registers the handlers itself.
    no_uia_events: bool = false,
    /// The change count just before the last tree of a window was read.
    snap_window: u64 = 0,
    snap_count: u64 = 0,
    /// The window whose tree was last shown, the change count before that
    /// read, and the hooks it was read under (`treeObserved`).
    seen_window: u64 = 0,
    seen_count: u64 = 0,
    seen_epoch: u32 = 0,
    /// What the changes of each application taught: see `treeObserved`.
    learned: [8]Learned = @splat(.{}),
    learned_next: usize = 0,
    /// GetTickCount when the foreground guard was last armed.
    guard_tick: u32 = 0,
    /// Per display, the indicator change its last look saw (`dropEchoes`).
    indicator_seen: [display.max_displays]i64 = @splat(0),
    /// GDI capture per display (US-032), and the displays whose duplication
    /// Windows refuses for good (DXGI_ERROR_UNSUPPORTED).
    gdi: [display.max_displays]capture_mod.Gdi = @splat(.{}),
    gdi_only: [display.max_displays]bool = @splat(false),
    /// Every capture goes through GDI (`--capture gdi`, the selftest and
    /// bench `capture-gdi`).
    force_gdi: bool = false,
    /// Selftest only: DuplicateOutput fails with this HRESULT, and the
    /// secure desktop is reported active, so the fallback paths run.
    refuse_duplication: ?w.HRESULT = null,
    pretend_secure: bool = false,

    /// `--capture gdi`: backends created from now on capture through GDI.
    pub var capture_mode: enum { auto, gdi } = .auto;

    pub fn init(gpa: std.mem.Allocator) Windows {
        return .{ .gpa = gpa, .ui = .{ .gpa = gpa }, .shell = .init(gpa), .force_gdi = capture_mode == .gdi };
    }

    /// Applies `--capture` (auto or gdi) to the backends created afterward.
    pub fn setCaptureMode(name: []const u8) bool {
        capture_mode = std.meta.stringToEnum(@TypeOf(capture_mode), name) orelse return false;
        return true;
    }

    pub fn deinit(self: *Windows) void {
        self.stopKillSwitch();
        self.stopIndicator();
        self.stopEvents();
        self.ui.deinit();
        self.shell.deinit();
        if (self.clip) |c| {
            c.deinit();
            self.gpa.destroy(c);
            self.clip = null;
        }
        for (&self.gdi) |*g| g.deinit();
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
        self.cap = Capture.init(self.gpa, !self.force_gdi) catch |err| {
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

    /// Primary flag, effective DPI and work area of display `index`
    /// (US-026), read when asked: the work area moves with the taskbar.
    pub fn displayInfo(self: *Windows, index: usize) display.DisplayInfo {
        const r = if (index < self.displays_len) self.displays_buf[index].rect else display.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        var info: display.DisplayInfo = .{ .primary = index == 0, .dpi = 96, .work = r };
        const c = self.ensure() orelse return info;
        if (index >= self.displays_len) return info;
        const mon = c.outputs.items[index].desc.Monitor;
        var mi: w.MONITORINFO = .{ .cbSize = @sizeOf(w.MONITORINFO), .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
        if (w.GetMonitorInfoW(mon, &mi) != 0) {
            info.primary = mi.dwFlags & w.MONITORINFOF_PRIMARY != 0;
            info.work = .{ .x = mi.rcWork.left, .y = mi.rcWork.top, .w = mi.rcWork.right - mi.rcWork.left, .h = mi.rcWork.bottom - mi.rcWork.top };
        }
        var dx: u32 = 96;
        var dy: u32 = 96;
        if (w.GetDpiForMonitor(mon, w.MDT_EFFECTIVE_DPI, &dx, &dy) >= 0) info.dpi = dx;
        return info;
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
        return self.grab(index, arena, true, null);
    }

    /// What changed on display `index` since the last look, as `capture`
    /// reports it but without the CPU copy of a new frame's pixels: the
    /// frame's `pixels` are empty. Settling and ui_find's wait look at the
    /// dirty rects only, so a busy screen elsewhere (a spinner) costs them a
    /// GPU copy per look rather than about 2 ms of CPU (US-030). Under GDI
    /// the look copies only `area` (the target window, desktop coordinates)
    /// clipped to the display, the part a fingerprint reads (US-032).
    pub fn changes(self: *Windows, index: usize, arena: std.mem.Allocator, area: ?display.Rect) display.CaptureResult {
        return self.grab(index, arena, false, area);
    }

    fn grab(self: *Windows, index: usize, arena: std.mem.Allocator, read: bool, area: ?display.Rect) display.CaptureResult {
        // `failure` classifies by the HRESULT of this call only: a stale
        // E_ACCESSDENIED would turn an allocation failure into the
        // secure-desktop message.
        com.last_hr = 0;
        const c = self.ensure() orelse return .{ .failed = if (capture_mod.secureDesktopActive()) secure_desktop_message else "DXGI indisponible : aucune sortie d'écran énumérée, réessaie." };
        if (index >= self.displays_len) return .{ .failed = fmt(arena, "Écran {d} déconnecté : refais un screenshot.", .{index}) };
        const o = &c.outputs.items[index];
        if (self.force_gdi or self.gdi_only[index]) return self.gdiFrame(index, area);
        o.beginCapture();
        if (o.dup == null) self.recreate(o) catch |err| return self.failure(arena, index, o, err, true);
        const fresh = o.acquire(self.gpa, if (o.has_frame) 0 else 500, read) catch |err| switch (err) {
            error.AccessLost => blk: {
                // Mode change, UAC, exclusive full screen: recreate the
                // duplication and try once more.
                self.recreate(o) catch |e| return self.failure(arena, index, o, e, true);
                break :blk o.acquire(self.gpa, 500, read) catch |e| return self.failure(arena, index, o, e, false);
            },
            else => return self.failure(arena, index, o, err, false),
        };
        // The indicator's own changes are not changes of the screen (US-034).
        if (self.indicator) |ind| ind.dropEchoes(&o.dirty, &self.indicator_seen[index]);
        if (!o.has_frame) return .{ .failed = "Capture réinitialisée : réessaie." };
        // A look for changes left the newest frame on the GPU.
        if (read and o.unread) {
            o.readback() catch |err| return self.failure(arena, index, o, err, false);
            o.unread = false;
        }
        return .{ .frame = .{
            .pixels = if (read) o.pixels else &.{},
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
        if (self.refuse_duplication) |hr| {
            com.last_hr = hr;
            return if (hr == w.DXGI_ERROR_UNSUPPORTED) error.Unsupported else error.ComCallFailed;
        }
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

    /// A failed duplication call. Windows refusing duplication for good
    /// (DXGI_ERROR_UNSUPPORTED), or a duplication that cannot be recreated
    /// (`recreating`, after DXGI_ERROR_ACCESS_LOST), falls back to GDI
    /// (US-032); the secure desktop stays refused on both paths.
    fn failure(self: *Windows, arena: std.mem.Allocator, index: usize, o: *capture_mod.Output, err: capture_mod.Error, recreating: bool) display.CaptureResult {
        _ = arena;
        const hr = com.last_hr;
        if (self.secure() or hr == w.E_ACCESSDENIED) return .{ .failed = secure_desktop_message };
        if (hr == w.DXGI_ERROR_SESSION_DISCONNECTED)
            return .{ .failed = "Session Windows inactive : capture impossible tant que la session n'est pas au premier plan" };
        if (err == error.Unsupported or hr == w.DXGI_ERROR_UNSUPPORTED) {
            if (!o.fallback_logged) std.debug.print("neo-compute: {s} (adapter {s}) refuses DXGI duplication (DXGI_ERROR_UNSUPPORTED): captured through GDI from now on\n", .{ o.name(), o.adapterName() });
            o.fallback_logged = true;
            self.gdi_only[index] = true;
            return self.gdiFrame(index, null);
        }
        if (recreating) {
            if (!o.fallback_logged) std.debug.print("neo-compute: duplication of {s} cannot be recreated ({t} hr=0x{x}): this capture goes through GDI\n", .{ o.name(), err, com.lastHr() });
            o.fallback_logged = true;
            return self.gdiFrame(index, null);
        }
        // Device removed, driver reset or a stale output: start over on
        // the next call.
        std.debug.print("neo-compute: capture of {s} failed: {t} hr=0x{x}\n", .{ o.name(), err, com.lastHr() });
        if (self.cap) |*c| c.deinit(self.gpa);
        self.cap = null;
        return .{ .failed = "Capture réinitialisée : réessaie." };
    }

    fn secure(self: *const Windows) bool {
        return self.pretend_secure or capture_mod.secureDesktopActive();
    }

    /// Selftest only: drops display `index`'s duplication, as an
    /// ACCESS_LOST that the next capture must recover from.
    pub fn dropDuplicationForTest(self: *Windows, index: usize) void {
        const c = self.ensure() orelse return;
        const o = &c.outputs.items[index];
        if (o.dup) |d| com.release(d);
        o.dup = null;
    }

    /// Whether display `index` is captured through GDI for good.
    pub fn gdiOnly(self: *const Windows, index: usize) bool {
        return self.gdi_only[index];
    }

    /// Display `index` through GDI (US-032), or only `area` (desktop
    /// coordinates) clipped to it, the window a look for changes watches;
    /// refused on the secure desktop like a duplication (Edge Case 7).
    fn gdiFrame(self: *Windows, index: usize, area: ?display.Rect) display.CaptureResult {
        if (self.secure()) return .{ .failed = secure_desktop_message };
        const r = self.displays_buf[index].rect;
        const part: display.Rect = if (area) |a| clip: {
            const x0 = @max(a.x, r.x);
            const y0 = @max(a.y, r.y);
            const x1 = @min(a.right(), r.right());
            const y1 = @min(a.bottom(), r.bottom());
            break :clip if (x1 > x0 and y1 > y0) .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 } else r;
        } else r;
        const pixels = self.gdi[index].grab(r, part) catch {
            std.debug.print("neo-compute: GDI capture of display {d} failed (error {d})\n", .{ index, w.GetLastError() });
            return .{ .failed = "Capture GDI impossible : réessaie, ou vérifie que la session est au premier plan." };
        };
        return .{ .frame = .{
            .pixels = pixels,
            .width = @intCast(part.w),
            .height = @intCast(part.h),
            .stride = @as(usize, @intCast(r.w)) * 4,
            .source = .gdi,
            .area = if (area != null) part else null,
        } };
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

    /// Starts the control indicator (US-034) on its own thread and has
    /// `control` tell it of every state change. Its windows are built in
    /// the background; a failure is logged on stderr and leaves every tool
    /// working without it.
    pub fn startIndicator(self: *Windows, control: *Control, rearm: keys.Combo) void {
        const ind = self.gpa.create(indicator_mod.Indicator) catch return;
        ind.* = .{ .control = control, .refuse = self.refuse_indicator };
        ind.start(rearm) catch |err| {
            std.debug.print("neo-compute: control indicator unavailable ({t}): tools run without it\n", .{err});
            self.gpa.destroy(ind);
            return;
        };
        control.observe(&ind.observer);
        self.indicator = ind;
    }

    /// Stop the kill switch first: its hook thread notifies the indicator.
    pub fn stopIndicator(self: *Windows) void {
        const ind = self.indicator orelse return;
        ind.control.observe(null);
        ind.stop();
        self.gpa.destroy(ind);
        self.indicator = null;
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

    /// Changes when a visible top-level window appears or goes (US-030).
    pub fn topWindowStamp(self: *Windows) u64 {
        _ = self;
        return window.stamp();
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
    pub fn uiSnapshot(self: *Windows, arena: std.mem.Allocator, hwnd: ?u64, request: uitree.Request) uitree.SnapshotResult {
        if (hwnd) |h| {
            self.snap_window = h;
            self.snap_count = self.changeCount();
        }
        return self.ui.snapshot(arena, hwnd, request);
    }

    /// Menus, popups and owned windows read with `hwnd`'s tree (US-023),
    /// from Win32 on the dispatcher thread.
    pub fn uiRoots(self: *Windows, arena: std.mem.Allocator, hwnd: ?u64) []const uitree.RootWindow {
        _ = self;
        return window.extraRoots(arena, hwnd);
    }

    pub fn uiAct(self: *Windows, arena: std.mem.Allocator, hwnd: u64, key: u64, action: uitree.Action, value: ?[]const u8) uitree.ActResult {
        return self.ui.act(arena, hwnd, key, action, value);
    }

    /// Whether a control pattern call first gives the focus to its target
    /// (UI Automation's default). Off in background mode: that focus brings
    /// the target's window to the foreground.
    pub fn uiAutoFocus(self: *Windows, enabled: bool) void {
        _ = self;
        uia.auto_set_focus.store(enabled, .monotonic);
    }

    // ------------------------------------------------------------ change events (US-048)

    /// The WinEvent watcher, started on first use.
    pub fn eventWatcher(self: *Windows) ?*winevents.Watcher {
        if (self.events) |e| return e;
        const e = self.gpa.create(winevents.Watcher) catch return null;
        e.* = .{};
        e.start() catch |err| {
            std.debug.print("neo-compute: WinEvent thread unavailable ({t}): settling reads the tree again instead\n", .{err});
            self.gpa.destroy(e);
            return null;
        };
        self.events = e;
        return e;
    }

    pub fn stopEvents(self: *Windows) void {
        const e = self.events orelse return;
        e.stop();
        self.gpa.destroy(e);
        self.events = null;
    }

    /// Count of the changes `hwnd` reported since the server started: it
    /// moves when the window's tree may have changed, whatever covers the
    /// window. Two sources add up (decision 0013, amendment of 2026-11-13).
    /// The WinEvents of the window's process, with those of the application
    /// a UWP frame hosts, are what a Win32 control raises: they signaled
    /// every tree change of the Win32, Explorer, Notepad and VS Code targets
    /// of `events-probe`. A UWP application raises none of its own: it
    /// raises UI Automation events, and only for a client that subscribed
    /// (`uia_events.zig`), which signaled every tree change of Calculator
    /// and Settings within 11 ms. The subscription is for those windows
    /// and for the applications `treeObserved` found changing without an
    /// event: it costs the target processor time on each of its events
    /// (Explorer: 4.6 times the cycles of the same actions), for changes
    /// its WinEvents already report. Null when the window is gone or
    /// Windows refuses the WinEvent hook: the caller reads the tree again
    /// instead. The first call for a window hooks its process and, for
    /// such a window, subscribes to its events.
    pub fn windowEvents(self: *Windows, hwnd: u64) ?u64 {
        const ref = window.ref(hwnd) orelse return null;
        const app = window.appPid(hwnd) orelse ref.pid;
        const e = self.eventWatcher() orelse return null;
        e.refuse = self.refuse_events;
        if (!e.watch(.{ ref.pid, if (app != ref.pid) app else 0 })) return null;
        if (!self.no_uia_events) self.uiaListen(if (window.uwpFrame(hwnd) or self.learnedState(app) == .listening) hwnd else 0);
        return self.changeCount();
    }

    fn changeCount(self: *const Windows) u64 {
        return (if (self.events) |e| e.stamp() else 0) +% uia_events.count.load(.acquire);
    }

    /// What the server knows of an application's change events.
    /// `listening`: it changed its tree without raising any, so the server
    /// subscribes to its UI Automation events. `deaf`: it still raised none
    /// with the subscription, which is dropped for good: the handlers cost
    /// the target processor time and bought nothing.
    pub const LearnState = enum { unknown, listening, deaf };
    const Learned = struct { pid: u32 = 0, hits: u8 = 0, state: LearnState = .unknown };
    /// Changes without an event, in a row, before the state moves.
    pub const blind_hits = 2;

    pub fn learnedState(self: *const Windows, pid: u32) LearnState {
        for (self.learned) |l| if (l.pid == pid and pid != 0) return l.state;
        return .unknown;
    }

    fn learnedOf(self: *Windows, pid: u32) *Learned {
        for (&self.learned) |*l| if (l.pid == pid) return l;
        const l = &self.learned[self.learned_next];
        self.learned_next = (self.learned_next + 1) % self.learned.len;
        l.* = .{ .pid = pid };
        return l;
    }

    /// The core showed a tree of `hwnd`; `changed`: whether it differs from
    /// the one shown before, null when the two were not compared. A tree
    /// that changed while the window's change count stood still, from
    /// before the earlier read to now and under the same hooks, is a change
    /// no event reported. Twice in a row, the server subscribes to the
    /// application's UI Automation events (decision 0013, amendment of
    /// 2026-11-13): what a XAML island or a WinUI 3 window needs, found by
    /// what the application does rather than by its window class. Twice
    /// more with the subscription, it is dropped. A UWP frame is subscribed
    /// to from the start and is not judged here.
    pub fn treeObserved(self: *Windows, hwnd: u64, changed: ?bool) void {
        const e = self.events orelse return;
        const before = if (self.snap_window == hwnd) self.snap_count else self.changeCount();
        const comparable = self.seen_window == hwnd and self.seen_epoch == e.epoch and e.hooked;
        const since = self.seen_count;
        self.seen_window = hwnd;
        self.seen_count = before;
        self.seen_epoch = e.epoch;
        if (changed != true or !comparable or self.no_uia_events or window.uwpFrame(hwnd)) return;
        const ref = window.ref(hwnd) orelse return;
        if (e.asked[0] != ref.pid) return;
        const l = self.learnedOf(window.appPid(hwnd) orelse ref.pid);
        if (self.changeCount() != since) {
            // Reported: the count moved with the tree.
            l.hits = 0;
            return;
        }
        l.hits += 1;
        if (l.hits < blind_hits) return;
        l.hits = 0;
        switch (l.state) {
            .unknown => {
                l.state = .listening;
                std.debug.print("neo-compute: process {d} changed its tree {d} times without a change event: subscribing to its UI Automation events\n", .{ l.pid, blind_hits });
                self.uiaListen(hwnd);
            },
            .listening => {
                l.state = .deaf;
                std.debug.print("neo-compute: process {d} still changed its tree without an event: UI Automation subscription dropped\n", .{l.pid});
                self.uiaListen(0);
            },
            .deaf => {},
        }
        // Adding or removing the handlers raises events of its own in the
        // target: the next tree starts a new comparison.
        self.seen_window = 0;
    }

    /// Moves the UI Automation subscription to `hwnd`; 0 removes it. A
    /// refusal (a window that does not answer) is tried again a second
    /// later, not on every read of the count.
    fn uiaListen(self: *Windows, hwnd: u64) void {
        if (hwnd == 0 and self.uia_window == 0) return;
        const now = w.GetTickCount();
        if (self.uia_window == hwnd and (self.uia_listening or now -% self.uia_tick < 1000)) return;
        self.uia_window = hwnd;
        self.uia_tick = now;
        self.uia_listening = self.ui.watch(hwnd);
    }

    /// Probe only: subscribes to the UI Automation events of `hwnd` in
    /// place of the window watched before (0: none).
    pub fn uiaWatch(self: *Windows, hwnd: u64) bool {
        return self.ui.watch(hwnd);
    }

    // ------------------------------------------------------------ windows

    /// Visible frame of `hwnd`, else of the foreground window (settling).
    pub fn windowRect(self: *Windows, hwnd: ?u64) ?display.Rect {
        _ = self;
        return window.rect(if (hwnd) |h| @ptrFromInt(h) else w.GetForegroundWindow());
    }

    /// With `include_hidden`, a cloaked window on another virtual desktop
    /// is flagged `other_desktop` instead (US-026); without
    /// IVirtualDesktopManager it stays `cloaked`.
    pub fn listWindows(self: *Windows, arena: std.mem.Allocator, include_hidden: bool) error{OutOfMemory}![]const display.WindowInfo {
        const wins = try window.list(arena, include_hidden);
        if (!include_hidden) return wins;
        var cloaked: std.ArrayList(u64) = .empty;
        for (wins) |win| if (win.cloaked) try cloaked.append(arena, win.handle);
        if (cloaked.items.len == 0) return wins;
        const other = try arena.alloc(bool, cloaked.items.len);
        if (!self.shell.otherDesktops(cloaked.items, other)) return wins;
        const out = try arena.dupe(display.WindowInfo, wins);
        var k: usize = 0;
        for (out) |*win| if (win.cloaked) {
            if (other[k]) {
                win.other_desktop = true;
                win.cloaked = false;
            }
            k += 1;
        };
        return out;
    }

    pub fn focusWindow(self: *Windows, handle: u64) display.FocusResult {
        _ = self;
        return window.focus(handle);
    }

    // ------------------------------------------------------------ window_set (US-027)

    pub fn windowPlacement(self: *Windows, handle: u64) ?display.Placement {
        _ = self;
        return window.placement(handle);
    }

    /// `activate` false (background mode): a minimized or maximized window
    /// is restored without being activated.
    pub fn placeWindow(self: *Windows, handle: u64, frame: display.Rect, activate: bool) display.SetResult {
        _ = self;
        return window.place(handle, frame, activate);
    }

    /// `activate` false (background mode): the state changes by the routes
    /// US-040 measured without a foreground change.
    pub fn showWindow(self: *Windows, handle: u64, state: display.ShowState, activate: bool) display.SetResult {
        _ = self;
        return window.show(handle, state, activate);
    }

    /// The foreground window, to tell whether it changed around a launch
    /// (US-043). Never the window to act on.
    pub fn foregroundWindow(self: *Windows) ?u64 {
        _ = self;
        const fg = w.GetForegroundWindow();
        return if (fg == null) null else @intFromPtr(fg);
    }

    /// Arms the foreground guard for the action that begins (US-050):
    /// from now on the event thread gives the foreground back when a
    /// window of the session's target takes it without a gesture of the
    /// user. Without that thread, the dispatcher's look after the action
    /// still restores.
    pub fn guardArm(self: *Windows, watch: *guard.Watch) void {
        self.guard_tick = w.GetTickCount();
        if (self.kill) |k| {
            var pid: u32 = 0;
            _ = w.GetWindowThreadProcessId(@ptrFromInt(watch.prev), &pid);
            k.home_pid.store(pid, .release);
        }
        if (self.eventWatcher()) |e| e.arm(watch, self.kill, self.guard_tick);
    }

    /// Leaves the guard armed for `ms` after the action ended
    /// (`guard.linger_ms`). The gestures that count are still those since
    /// shortly before the action began.
    pub fn guardLinger(self: *Windows, watch: *guard.Watch, ms: u32) void {
        if (self.kill) |k| {
            var pid: u32 = 0;
            _ = w.GetWindowThreadProcessId(@ptrFromInt(watch.prev), &pid);
            k.home_pid.store(pid, .release);
        }
        if (self.events) |e| e.armFor(watch, self.kill, self.guard_tick, ms);
    }

    /// Disarms it, once a restoration in progress has ended. Whether the
    /// user made a gesture that can change the foreground window since
    /// shortly before the action began; null without the input hooks.
    pub fn guardDisarm(self: *Windows) ?bool {
        if (self.events) |e| e.disarm();
        const k = self.kill orelse return null;
        k.home_pid.store(0, .release);
        return k.gestureSince(self.guard_tick -% guard.gesture_slack_ms);
    }

    /// Gives the foreground back to `handle` (US-050), without injected
    /// input.
    pub fn restoreForeground(self: *Windows, handle: u64) bool {
        _ = self;
        return window.restoreForeground(handle);
    }

    pub fn closeWindow(self: *Windows, handle: u64) display.SetResult {
        _ = self;
        return window.close(handle);
    }

    /// Process of the application a window shows (a UWP frame's hosted
    /// application rather than ApplicationFrameHost.exe).
    pub fn appPid(self: *Windows, handle: u64) ?u32 {
        _ = self;
        return window.appPid(handle);
    }

    pub fn processAncestors(self: *Windows, arena: std.mem.Allocator) []const u32 {
        _ = self;
        return window.ancestors(arena);
    }

    pub fn processAlive(self: *Windows, pid: u32) bool {
        _ = self;
        return window.alive(pid);
    }

    pub fn terminateProcess(self: *Windows, pid: u32) bool {
        _ = self;
        return window.terminate(pid);
    }

    // ------------------------------------------------------------ app_launch (US-028, US-029)

    pub fn appCatalog(self: *Windows, arena: std.mem.Allocator, cancel: *const std.atomic.Value(bool)) apps.CatalogResult {
        return self.shell.catalog(arena, cancel);
    }

    /// A packaged application through IApplicationActivationManager, which
    /// gives its pid; any other through `shell:AppsFolder\<AUMID>`.
    pub fn launchApp(self: *Windows, arena: std.mem.Allocator, app: apps.App, show: apps.Show, cancel: *const std.atomic.Value(bool)) apps.Launch {
        if (app.packaged and show == .normal) return self.shell.activate(app.aumid, cancel);
        const file = std.fmt.allocPrint(arena, "shell:AppsFolder\\{s}", .{app.aumid}) catch return .{ .unavailable = "Mémoire insuffisante : réessaie." };
        return self.shell.execute(file, show, cancel);
    }

    /// Executable a non-packaged Start menu entry's shortcut starts, read
    /// for the chosen entry so the policy applies before the launch.
    pub fn appExe(self: *Windows, arena: std.mem.Allocator, app: apps.App) ?[]const u8 {
        return self.shell.targetExe(arena, app.aumid);
    }

    /// Opens a document or folder with its default application.
    pub fn openPath(self: *Windows, path: []const u8, show: apps.Show, cancel: *const std.atomic.Value(bool)) apps.Launch {
        return self.shell.execute(path, show, cancel);
    }

    /// Executable of the default application of extension `ext`.
    pub fn defaultApp(self: *Windows, arena: std.mem.Allocator, ext: []const u8) ?[]const u8 {
        return self.shell.defaultExe(arena, ext);
    }

    /// Absolute form of `path` and what it names, from kernel32 only (no
    /// shell call): a file, a folder, nothing, or a network location.
    pub fn pathInfo(self: *Windows, arena: std.mem.Allocator, path: []const u8) apps.PathInfo {
        _ = self;
        var wide: [1024:0]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(&wide, path) catch return .{ .kind = .missing, .full = path };
        if (n >= wide.len) return .{ .kind = .missing, .full = path };
        wide[n] = 0;
        var full_w: [1024:0]u16 = undefined;
        const len = w.GetFullPathNameW(&wide, full_w.len, @ptrCast(&full_w), null);
        if (len == 0 or len >= full_w.len) return .{ .kind = .missing, .full = path };
        full_w[len] = 0;
        const buf = arena.alloc(u8, len * 3) catch return .{ .kind = .missing, .full = path };
        const full = buf[0..std.unicode.wtf16LeToWtf8(buf, full_w[0..len])];
        const backslash: u16 = '\\';
        if (full_w[0] == backslash and full_w[1] == backslash) return .{ .kind = .remote, .full = full };
        // A mapped network drive: reading it would open a connection.
        if (len >= 3 and full_w[1] == ':') {
            var root = [_:0]u16{ full_w[0], ':', backslash };
            if (w.GetDriveTypeW(&root) == w.DRIVE_REMOTE) return .{ .kind = .remote, .full = full };
        }
        const attrs = w.GetFileAttributesW(&full_w);
        if (attrs == w.INVALID_FILE_ATTRIBUTES) return .{ .kind = .missing, .full = full };
        const kind: @FieldType(apps.PathInfo, "kind") = if (attrs & w.FILE_ATTRIBUTE_DIRECTORY != 0) .directory else .file;
        // The long form of 8.3 components: the shell opens `DEPLOY~1.APP` as
        // the `.appref-ms` it names, so the core checks this name.
        var long_w: [1024:0]u16 = undefined;
        const ln = w.GetLongPathNameW(&full_w, @ptrCast(&long_w), long_w.len);
        if (ln == 0 or ln >= long_w.len) return .{ .kind = kind, .full = full };
        const lbuf = arena.alloc(u8, ln * 3) catch return .{ .kind = .missing, .full = path };
        return .{ .kind = kind, .full = lbuf[0..std.unicode.wtf16LeToWtf8(lbuf, long_w[0..ln])] };
    }

    /// Whether Windows classes extension `ext` as unsafe to open
    /// (AssocIsDangerous) or opens it by running the file itself (`.pif`).
    pub fn unsafeType(self: *Windows, ext: []const u8) bool {
        return self.shell.unsafeType(ext);
    }

    /// PATHEXT of this process's environment (`.COM;.EXE;...`).
    pub fn pathExtensions(self: *Windows, arena: std.mem.Allocator) []const u8 {
        _ = self;
        var buf: [1024:0]u16 = undefined;
        const n = w.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("PATHEXT"), @ptrCast(&buf), buf.len);
        if (n == 0 or n >= buf.len) return "";
        const out = arena.alloc(u8, n * 3) catch return "";
        return out[0..std.unicode.wtf16LeToWtf8(out, buf[0..n])];
    }

    // ------------------------------------------------------------ clipboard (US-035)

    /// The clipboard worker, started on first use.
    fn clipboardWorker(self: *Windows) ?*clip_mod.Clipboard {
        if (self.clip) |c| return c;
        const c = self.gpa.create(clip_mod.Clipboard) catch return null;
        c.* = .{};
        self.clip = c;
        return c;
    }

    pub fn clipboardRead(self: *Windows, arena: std.mem.Allocator, max_chars: usize, cancel: *const std.atomic.Value(bool)) clipboard.Read {
        const c = self.clipboardWorker() orelse return .{ .failed = "Mémoire insuffisante : réessaie." };
        return c.read(arena, max_chars, cancel);
    }

    pub fn clipboardWrite(self: *Windows, arena: std.mem.Allocator, text: []const u8, cancel: *const std.atomic.Value(bool)) clipboard.Write {
        _ = arena;
        const c = self.clipboardWorker() orelse return .{ .failed = "Mémoire insuffisante : réessaie." };
        return c.write(text, cancel);
    }

    // ------------------------------------------------------------ registry_read (US-036)

    pub fn registryValue(self: *Windows, arena: std.mem.Allocator, path: regread.Path, name: []const u8) regread.ValueResult {
        _ = self;
        return reg_mod.value(arena, path, name);
    }

    pub fn registryKey(self: *Windows, arena: std.mem.Allocator, path: regread.Path, max_values: usize, max_subkeys: usize) regread.KeyResult {
        _ = self;
        return reg_mod.key(arena, path, max_values, max_subkeys);
    }

    // ------------------------------------------------------------ tooling

    pub const selftest = @import("windows/selftest.zig").run;
    /// `selftest --background`: every background action reaches its target
    /// and takes nothing from the user (US-044).
    pub const selftestBackground = @import("windows/selftest_background.zig").run;
    /// `selftest-stall`: the out-of-process provider the selftest times out on.
    pub const stallProvider = @import("windows/stall_provider.zig").run;
    /// `selftest-still`: the still window of another process the selftest
    /// times ui_find's GDI wait on.
    pub const stillWindow = @import("windows/still_window.zig").run;
    /// `selftest-decoy`: the foreground window of another process the
    /// background probe and selftest work behind (EP-011).
    pub const decoyWindow = @import("windows/decoy_window.zig").run;
    /// `selftest-popup`: the application of another process whose dialog
    /// takes the foreground, for the foreground guard (US-050).
    pub const popupWindow = @import("windows/popup_window.zig").run;
    /// `bg-probe`: which background primitives take the foreground (US-040).
    pub const bgProbe = @import("windows/bg_probe.zig").run;
    /// `events-probe`: do WinEvents report the changes of a covered window (US-047).
    pub const eventsProbe = @import("windows/events_probe.zig").run;
    /// `clipboard-probe`: formats and owner of each new clipboard content (A11).
    pub const clipboardProbe = @import("windows/clipboard_probe.zig").run;

    pub fn benchScenario(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, name: []const u8, iterations: ?usize) !bench.Outcome {
        return @import("windows/bench.zig").run(gpa, io, counter, name, iterations);
    }
};
