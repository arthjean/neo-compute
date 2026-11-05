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
const shell_mod = @import("windows/shell.zig");
const apps = @import("../core/apps.zig");
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
    /// Shell APIs on their own STA thread (EP-006).
    shell: shell_mod.Shell,
    kill: ?*hooks.KillSwitch = null,

    pub fn init(gpa: std.mem.Allocator) Windows {
        return .{ .gpa = gpa, .ui = .{ .gpa = gpa }, .shell = .init(gpa) };
    }

    pub fn deinit(self: *Windows) void {
        self.stopKillSwitch();
        self.ui.deinit();
        self.shell.deinit();
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
    pub fn uiSnapshot(self: *Windows, arena: std.mem.Allocator, hwnd: ?u64, request: uitree.Request) uitree.SnapshotResult {
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

    pub fn placeWindow(self: *Windows, handle: u64, frame: display.Rect) display.SetResult {
        _ = self;
        return window.place(handle, frame);
    }

    pub fn showWindow(self: *Windows, handle: u64, state: display.ShowState) display.SetResult {
        _ = self;
        return window.show(handle, state);
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
    pub fn launchApp(self: *Windows, arena: std.mem.Allocator, app: apps.App, cancel: *const std.atomic.Value(bool)) apps.Launch {
        if (app.packaged) return self.shell.activate(app.aumid, cancel);
        const file = std.fmt.allocPrint(arena, "shell:AppsFolder\\{s}", .{app.aumid}) catch return .{ .unavailable = "Mémoire insuffisante : réessaie." };
        return self.shell.execute(file, cancel);
    }

    /// Executable a non-packaged Start menu entry's shortcut starts, read
    /// for the chosen entry so the policy applies before the launch.
    pub fn appExe(self: *Windows, arena: std.mem.Allocator, app: apps.App) ?[]const u8 {
        return self.shell.targetExe(arena, app.aumid);
    }

    /// Opens a document or folder with its default application.
    pub fn openPath(self: *Windows, path: []const u8, cancel: *const std.atomic.Value(bool)) apps.Launch {
        return self.shell.execute(path, cancel);
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

    // ------------------------------------------------------------ tooling

    pub const selftest = @import("windows/selftest.zig").run;
    /// `selftest-stall`: the out-of-process provider the selftest times out on.
    pub const stallProvider = @import("windows/stall_provider.zig").run;

    pub fn benchScenario(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, name: []const u8, iterations: ?usize) !bench.Outcome {
        return @import("windows/bench.zig").run(gpa, io, counter, name, iterations);
    }
};
