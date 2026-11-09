//! Control indicator (US-034): a 4 px frame and a label on every display
//! while an action runs (settling included) and 1 s after, or while the
//! kill switch holds the server paused. A dedicated thread owns the
//! windows: per display, four strips along the edges and the label box,
//! each a small layered window, topmost, transparent to clicks, never
//! activated, and excluded from capture (`WDA_EXCLUDEFROMCAPTURE`,
//! decision 0011).
//!
//! Five small windows rather than one per display shaped by a region: DWM
//! reports a change of a window as a dirty rect of its whole rectangle, so
//! a display-sized window turned every appearance into a dirty rect of the
//! whole display, which no settling could tell from a real change. A strip
//! dirties its own 4 px only.
//!
//! The control state reaches the thread as a posted message from the
//! `Control` observer, so a change costs the thread that made it one
//! PostThreadMessageW, the low-level hook thread included. The indicator
//! never animates: an excluded window still produces DXGI dirty rects
//! (US-033), and those of its own changes are dropped from captures
//! (`dropEchoes`), so settling and ui_find's wait do not see it.

const std = @import("std");
const w = @import("win32");
const display = @import("../../core/display.zig");
const core = @import("../../core/indicator.zig");
const keys = @import("../../core/keys.zig");
const control_mod = @import("../../core/control.zig");

pub const class_name = "NeoComputeIndicator";
const max_screens = display.max_displays;
/// Top, bottom, left and right strips, then the label.
const parts = 5;
const label_part = 4;

const msg_update = w.WM_APP + 1;
const msg_rebuild = w.WM_APP + 2;

/// COLORREF 0x00BBGGRR. Acting: near-black on amber (#F5A623, contrast
/// 10:1); paused: white on red (#C62828, 5.6:1). The label text says the
/// state, so color is never the only cue.
pub const acting_fill: u32 = 0x0023A6F5;
const acting_ink: u32 = 0x001A1A1A;
const paused_fill: u32 = 0x002828C6;
const paused_ink: u32 = 0x00FFFFFF;
/// Label text height at 96 dpi.
const text_px = 15;

/// The indicator's windows, which window enumerations skip (`owns`).
var owned: [max_screens * parts]std.atomic.Value(usize) = @splat(.init(0));
/// The running indicator, for the window procedure.
var instance: ?*Indicator = null;

/// Whether `hwnd` is one of the indicator's windows.
pub fn owns(hwnd: w.HWND) bool {
    const h = @intFromPtr(hwnd);
    if (h == 0) return false;
    for (&owned) |*o| if (o.load(.acquire) == h) return true;
    return false;
}

const Screen = struct {
    hwnds: [parts]w.HWND = @splat(null),
    monitor: display.Rect,
    dpi: u32,
    font: w.HFONT = null,
    acting: core.Layout,
    paused: core.Layout,

    fn layoutOf(self: *const Screen, look: core.Look) *const core.Layout {
        return if (look == .paused) &self.paused else &self.acting;
    }
};

pub const Indicator = struct {
    control: *control_mod.Control,
    acting_text: [64:0]u16 = undefined,
    paused_text: [128:0]u16 = undefined,
    observer: control_mod.Observer = undefined,
    thread: ?std.Thread = null,
    thread_id: std.atomic.Value(u32) = .init(0),
    /// Selftest only: the windows fail to build, as if Windows refused them.
    refuse: bool = false,
    /// Why the windows could not be built, for the stderr line.
    failure: ?[]const u8 = null,
    failure_code: u32 = 0,
    /// The windows exist (`built`), or building them failed (`failed`).
    built: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    /// `stop` was called: a build in progress gives up.
    quit: std.atomic.Value(bool) = .init(false),

    // Indicator thread state.
    screens: [max_screens]Screen = undefined,
    count: usize = 0,
    look: core.Look = .hidden,
    linger_timer: usize = 0,
    /// The control's action epoch at the last update.
    epoch: u32 = 0,

    // Shared with captures and the selftest.
    lock: w.SRWLOCK = .{ .Ptr = null },
    /// Per display: the acting frame and label, then the paused label,
    /// desktop coordinates.
    rects: [max_screens * 6]display.Rect = undefined,
    rects_len: usize = 0,
    /// QPC milliseconds of the last change on screen.
    changed_at: std.atomic.Value(i64) = .init(std.math.minInt(i64) / 2),
    shown: std.atomic.Value(u8) = .init(@backingInt(core.Look.hidden)),
    /// Dirty rects dropped as the indicator's own (selftest).
    dropped: std.atomic.Value(u32) = .init(0),

    /// Starts the thread, which builds the windows without holding up the
    /// caller (about 10 ms that `initialize` would otherwise wait for). A
    /// failure to build them is logged on stderr by the thread, and the
    /// indicator stays off.
    pub fn start(self: *Indicator, rearm: keys.Combo) !void {
        var buf: [128]u8 = undefined;
        setWide(&self.acting_text, core.acting_label);
        setWide(&self.paused_text, core.pausedLabel(&buf, rearm));
        self.observer = .{ .ctx = self, .notify = notify };
        instance = self;
        self.thread = std.Thread.spawn(.{}, loop, .{self}) catch |err| {
            instance = null;
            return err;
        };
    }

    /// Ends the thread and destroys the windows. Remove the observer from
    /// the control first.
    pub fn stop(self: *Indicator) void {
        const t = self.thread orelse return;
        // A build in progress stops at its next window, so a server whose
        // stdin closes right after it started exits at once.
        self.quit.store(true, .release);
        // WM_QUIT needs the thread's queue, created before its id is set.
        while (self.thread_id.load(.acquire) == 0) w.Sleep(1);
        _ = w.PostThreadMessageW(self.thread_id.load(.acquire), w.WM_QUIT, 0, 0);
        t.join();
        self.thread = null;
        instance = null;
    }

    /// Waits until the windows exist (true) or failed to build (false).
    pub fn ready(self: *const Indicator, timeout_ms: u32) bool {
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 5) {
            if (self.built.load(.acquire)) return true;
            if (self.failed.load(.acquire)) return false;
            w.Sleep(5);
        }
        return false;
    }

    /// What the displays show now.
    pub fn current(self: *const Indicator) core.Look {
        return @fromBackingInt(@intCast(self.shown.load(.acquire)));
    }

    /// The windows, five per display (selftest).
    pub fn windows(_: *const Indicator, out: *[max_screens * parts]w.HWND) []w.HWND {
        var n: usize = 0;
        for (&owned) |*o| {
            const h = o.load(.acquire);
            if (h == 0) continue;
            out[n] = @ptrFromInt(h);
            n += 1;
        }
        return out[0..n];
    }

    /// Selftest only: lets captures see the windows (`excluded` false), to
    /// prove they are drawn, or excludes them again. Returns whether every
    /// window took the affinity.
    pub fn excludeFromCapture(self: *Indicator, excluded: bool) bool {
        var buf: [max_screens * parts]w.HWND = undefined;
        var all = true;
        for (self.windows(&buf)) |h| {
            if (w.SetWindowDisplayAffinity(h, if (excluded) w.WDA_EXCLUDEFROMCAPTURE else w.WDA_NONE) == 0) all = false;
        }
        return all;
    }

    /// The indicator's rectangles, six per display: the acting frame's
    /// four strips and label, then the paused label (selftest).
    pub fn geometry(self: *Indicator, out: []display.Rect) []display.Rect {
        w.AcquireSRWLockExclusive(&self.lock);
        defer w.ReleaseSRWLockExclusive(&self.lock);
        const n = @min(out.len, self.rects_len);
        @memcpy(out[0..n], self.rects[0..n]);
        return out[0..n];
    }

    /// Drops from a capture's dirty rects those the indicator's own last
    /// change produced: covered by its frame or labels, on the first look
    /// at a display since the change (DXGI accumulates dirty rects until
    /// someone looks, seconds later when idle) and on every look within
    /// `echo_ms` of it (DWM composes the change at a later refresh). A
    /// change of the screen that also reaches outside the indicator is
    /// kept whole. `seen` is the display's last change looked at.
    pub fn dropEchoes(self: *Indicator, dirty: *std.ArrayList(display.Rect), seen: *i64) void {
        const at = self.changed_at.load(.acquire);
        const first = at != seen.*;
        seen.* = at;
        if (dirty.items.len == 0) return;
        if (!first and nowMs() - at > core.echo_ms) return;
        w.AcquireSRWLockExclusive(&self.lock);
        defer w.ReleaseSRWLockExclusive(&self.lock);
        const r = core.dropEchoes(dirty.items, self.rects[0..self.rects_len]);
        dirty.shrinkRetainingCapacity(r.kept);
        if (r.dropped > 0) _ = self.dropped.fetchAdd(@intCast(r.dropped), .acq_rel);
    }

    /// The control observer: runs on the thread that changed the state. A
    /// change before the thread has its queue is lost, and caught up by
    /// the `update` that follows the build.
    fn notify(ctx: *anyopaque) void {
        const self: *Indicator = @ptrCast(@alignCast(ctx));
        _ = w.PostThreadMessageW(self.thread_id.load(.acquire), msg_update, 0, 0);
    }

    fn loop(self: *Indicator) void {
        var msg: w.MSG = undefined;
        // Creates the thread's message queue before anyone posts to it.
        _ = w.PeekMessageW(&msg, null, 0, 0, w.PM_NOREMOVE);
        self.thread_id.store(w.GetCurrentThreadId(), .release);
        if (self.refuse) self.fail("refused by the selftest") else self.build();
        if (self.failure) |why| {
            std.debug.print("neo-compute: control indicator unavailable ({s}, error {d}): tools run without it\n", .{ why, self.failure_code });
            self.destroy();
            self.failed.store(true, .release);
            return;
        }
        if (self.quit.load(.acquire)) return self.destroy();
        self.built.store(true, .release);
        // The state may have changed while the windows were being built.
        self.update();
        while (w.GetMessageW(&msg, null, 0, 0) > 0) {
            if (msg.hwnd == null) switch (msg.message) {
                msg_update => self.update(),
                msg_rebuild => self.rebuild(),
                w.WM_TIMER => if (msg.wParam == self.linger_timer) self.lingerEnded(),
                else => {},
            } else _ = w.DispatchMessageW(&msg);
        }
        self.destroy();
    }

    fn fail(self: *Indicator, why: []const u8) void {
        if (self.failure == null) {
            self.failure = why;
            self.failure_code = w.GetLastError();
        }
    }

    fn build(self: *Indicator) void {
        const module = w.GetModuleHandleW(null);
        const class = std.unicode.utf8ToUtf16LeStringLiteral(class_name);
        const wc: w.WNDCLASSEXW = .{
            .cbSize = @sizeOf(w.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = module,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class,
            .hIconSm = null,
        };
        // Registered once per process; a second start finds it.
        _ = w.RegisterClassExW(&wc);
        self.count = 0;
        const enumerated = w.EnumDisplayMonitors(null, null, monitorProc, @bitCast(@intFromPtr(self))) != 0;
        if (self.quit.load(.acquire)) return;
        if (!enumerated or self.count == 0) return self.fail("no display enumerated");
        const ex = w.WS_EX_LAYERED | w.WS_EX_TRANSPARENT | w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE;
        var n: usize = 0;
        for (self.screens[0..self.count], 0..) |*s, i| {
            for (&s.hwnds, s.acting.rects, 0..) |*hwnd, r, p| {
                if (self.quit.load(.acquire)) return;
                hwnd.* = w.CreateWindowExW(ex, class, null, w.WS_POPUP, r.x, r.y, r.w, r.h, null, null, module, null);
                if (hwnd.* == null) return self.fail("CreateWindowExW failed");
                owned[i * parts + p].store(@intFromPtr(hwnd.*), .release);
                if (w.SetLayeredWindowAttributes(hwnd.*, 0, 255, w.LWA_ALPHA) == 0) return self.fail("SetLayeredWindowAttributes failed");
                // Without exclusion the indicator would show in every
                // capture: no indicator rather than a visible one.
                if (w.SetWindowDisplayAffinity(hwnd.*, w.WDA_EXCLUDEFROMCAPTURE) == 0) return self.fail("SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) failed");
            }
            @memcpy(self.rects[n..][0..5], &s.acting.rects);
            self.rects[n + 5] = s.paused.label();
            n += 6;
        }
        w.AcquireSRWLockExclusive(&self.lock);
        self.rects_len = n;
        w.ReleaseSRWLockExclusive(&self.lock);
    }

    fn destroy(self: *Indicator) void {
        self.stopLinger();
        for (self.screens[0..self.count], 0..) |*s, i| {
            for (&s.hwnds, 0..) |*hwnd, p| {
                owned[i * parts + p].store(0, .release);
                if (hwnd.* != null) _ = w.DestroyWindow(hwnd.*);
                hwnd.* = null;
            }
            if (s.font != null) _ = w.DeleteObject(s.font);
            s.font = null;
        }
        w.AcquireSRWLockExclusive(&self.lock);
        self.rects_len = 0;
        w.ReleaseSRWLockExclusive(&self.lock);
        self.count = 0;
        self.look = .hidden;
        self.shown.store(@backingInt(core.Look.hidden), .release);
    }

    /// A display was added, removed, moved or rescaled.
    fn rebuild(self: *Indicator) void {
        const want = self.look;
        self.destroy();
        self.build();
        if (self.failure) |why| {
            std.debug.print("neo-compute: control indicator lost after a display change ({s}, error {d})\n", .{ why, self.failure_code });
            self.destroy();
            return;
        }
        self.apply(want);
        // `destroy` killed a linger in progress: without a new one, an
        // `acting` look would stay until the next action.
        self.update();
    }

    fn monitorProc(monitor: w.HMONITOR, _: w.HDC, _: ?*w.RECT, data: w.LPARAM) callconv(.winapi) w.BOOL {
        const self: *Indicator = @ptrFromInt(@as(usize, @bitCast(data)));
        if (self.count == max_screens or self.quit.load(.acquire)) return 0;
        var mi: w.MONITORINFO = .{ .cbSize = @sizeOf(w.MONITORINFO), .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
        if (w.GetMonitorInfoW(monitor, &mi) == 0) return 1;
        var dx: u32 = 96;
        var dy: u32 = 96;
        if (w.GetDpiForMonitor(monitor, w.MDT_EFFECTIVE_DPI, &dx, &dy) < 0) dx = 96;
        const r = mi.rcMonitor;
        const rect: display.Rect = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
        const font = w.CreateFontW(-@as(i32, @intCast((text_px * dx + 48) / 96)), 0, 0, 0, w.FW_SEMIBOLD, 0, 0, 0, 1, 0, 0, w.CLEARTYPE_QUALITY, 0, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"));
        self.screens[self.count] = .{
            .monitor = rect,
            .dpi = dx,
            .font = font,
            .acting = core.layout(rect, dx, textSize(font, &self.acting_text)),
            .paused = core.layout(rect, dx, textSize(font, &self.paused_text)),
        };
        self.count += 1;
        return 1;
    }

    /// Re-reads the control state and shows what it calls for. An action
    /// shorter than this thread's wake-up is never seen busy: the epoch
    /// still tells it ran.
    fn update(self: *Indicator) void {
        const epoch = self.control.epoch.load(.acquire);
        const paused = self.control.isPaused();
        const busy = self.control.busy.load(.acquire);
        const began = epoch != self.epoch;
        self.epoch = epoch;
        switch (core.lingerOf(paused, busy, began, self.look, self.linger_timer != 0)) {
            .stop => self.stopLinger(),
            .start => {
                self.stopLinger();
                self.linger_timer = w.SetTimer(null, 0, core.linger_ms, null);
            },
            .keep => {},
        }
        self.apply(core.lookOf(paused, busy, self.linger_timer != 0));
    }

    /// Not `update`: with the look still `acting`, it would start another
    /// linger.
    fn lingerEnded(self: *Indicator) void {
        self.stopLinger();
        self.apply(core.lookOf(self.control.isPaused(), self.control.busy.load(.acquire), false));
    }

    fn stopLinger(self: *Indicator) void {
        if (self.linger_timer != 0) _ = w.KillTimer(null, self.linger_timer);
        self.linger_timer = 0;
    }

    /// Shows `look` on every display. The strips never move; the label
    /// box takes the width of its text.
    fn apply(self: *Indicator, look: core.Look) void {
        if (look == self.look) return;
        self.look = look;
        for (self.screens[0..self.count]) |*s| for (s.hwnds, 0..) |hwnd, p| {
            if (look == .hidden) {
                _ = w.ShowWindow(hwnd, w.SW_HIDE);
                continue;
            }
            _ = w.InvalidateRect(hwnd, null, 0);
            // Topmost again: a topmost window raised since then would cover it.
            const flags = w.SWP_NOACTIVATE | w.SWP_SHOWWINDOW;
            if (p == label_part) {
                const r = s.layoutOf(look).label();
                _ = w.SetWindowPos(hwnd, w.HWND_TOPMOST, r.x, r.y, r.w, r.h, flags);
            } else _ = w.SetWindowPos(hwnd, w.HWND_TOPMOST, 0, 0, 0, 0, flags | w.SWP_NOMOVE | w.SWP_NOSIZE);
        };
        self.changed_at.store(nowMs(), .release);
        self.shown.store(@backingInt(look), .release);
    }

    fn paint(self: *Indicator, hwnd: w.HWND) void {
        var ps: w.PAINTSTRUCT = undefined;
        const hdc = w.BeginPaint(hwnd, &ps);
        defer _ = w.EndPaint(hwnd, &ps);
        const look = if (self.look == .hidden) core.Look.acting else self.look;
        const fill = w.CreateSolidBrush(if (look == .paused) paused_fill else acting_fill);
        defer _ = w.DeleteObject(fill);
        var rc: w.RECT = undefined;
        _ = w.GetClientRect(hwnd, &rc);
        _ = w.FillRect(hdc, &rc, fill);
        const s = for (self.screens[0..self.count]) |*s| {
            if (s.hwnds[label_part] == hwnd) break s;
        } else return;
        const old = w.SelectObject(hdc, s.font);
        defer _ = w.SelectObject(hdc, old);
        _ = w.SetBkMode(hdc, @intCast(w.TRANSPARENT));
        _ = w.SetTextColor(hdc, if (look == .paused) paused_ink else acting_ink);
        // Below the top strip the label box continues.
        rc.top += core.frameWidth(s.dpi);
        _ = w.DrawTextW(hdc, if (look == .paused) &self.paused_text else &self.acting_text, -1, &rc, w.DT_CENTER | w.DT_VCENTER | w.DT_SINGLELINE);
    }

    fn wndProc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
        const self = instance orelse return w.DefWindowProcW(hwnd, msg, wparam, lparam);
        switch (msg) {
            w.WM_PAINT => {
                self.paint(hwnd);
                return 0;
            },
            w.WM_DISPLAYCHANGE, w.WM_DPICHANGED => {
                // Every window hears it: rebuild once, from the loop.
                if (self.count > 0 and hwnd == self.screens[0].hwnds[0]) _ = w.PostThreadMessageW(self.thread_id.load(.acquire), msg_rebuild, 0, 0);
                return 0;
            },
            else => return w.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
};

fn textSize(font: w.HFONT, text: [*:0]const u16) [2]i32 {
    const hdc = w.GetDC(null);
    defer _ = w.ReleaseDC(null, hdc);
    const old = w.SelectObject(hdc, font);
    defer _ = w.SelectObject(hdc, old);
    var rc: w.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w.DrawTextW(hdc, text, -1, &rc, w.DT_CALCRECT | w.DT_SINGLELINE);
    return .{ rc.right - rc.left, rc.bottom - rc.top };
}

fn setWide(out: anytype, text: []const u8) void {
    const n = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], text) catch 0;
    out[n] = 0;
}

fn nowMs() i64 {
    var t: i64 = 0;
    var f: i64 = 1;
    _ = w.QueryPerformanceCounter(&t);
    _ = w.QueryPerformanceFrequency(&f);
    return @divTrunc(t * 1000, f);
}
