//! `neo-compute selftest`: checks capture, mouse, keyboard, accessibility
//! (UIA worker, ui_tree, ui_find, ui_act, provider timeout), settling, DPI
//! mapping, windows and input release against a window the test creates
//! itself. Tool checks go through the real dispatcher (`tools/call` JSON in,
//! JSON-RPC line out). Prints one line per subtest and returns the name of
//! the first failing one.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const uitree = @import("../../core/uitree.zig");
const TestWindow = @import("test_window.zig").TestWindow;
const test_window = @import("test_window.zig");
const stall_provider = @import("stall_provider.zig");
const still_window = @import("still_window.zig");
const Windows = @import("../windows.zig").Windows;
const mcp = @import("../../core/mcp.zig");
const tools = @import("../../core/tools.zig");
const display = @import("../../core/display.zig");

const Server = mcp.Server(Windows, tools.all);

const Report = struct {
    log: *std.Io.Writer,
    failed: ?[]const u8 = null,

    pub fn ok(self: *Report, name: []const u8, comptime f: []const u8, args: anytype) void {
        self.log.print("selftest: {s} ok (" ++ f ++ ")\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
    }

    pub fn skip(self: *Report, name: []const u8, comptime f: []const u8, args: anytype) void {
        self.log.print("selftest: {s} skipped (" ++ f ++ ")\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
    }

    pub fn fail(self: *Report, name: []const u8, comptime f: []const u8, args: anytype) void {
        self.log.print("selftest: {s} FAILED: " ++ f ++ "\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
        if (self.failed == null) self.failed = name;
    }
};

fn isColor(px: [4]u8, color: u32) bool {
    // BGRA from DXGI against a COLORREF 0x00BBGGRR.
    const r: u8 = @truncate(color);
    const g: u8 = @truncate(color >> 8);
    const b: u8 = @truncate(color >> 16);
    const close = struct {
        fn f(a: u8, x: u8) bool {
            return @abs(@as(i16, a) - @as(i16, x)) < 16;
        }
    }.f;
    return close(px[0], b) and close(px[1], g) and close(px[2], r);
}

fn waitFor(comptime pred: anytype, args: anytype, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (@call(.auto, pred, args)) return true;
        w.Sleep(5);
    }
    return false;
}

fn qpcUs() u64 {
    var t: i64 = 0;
    var f: i64 = 1;
    _ = w.QueryPerformanceCounter(&t);
    _ = w.QueryPerformanceFrequency(&f);
    return @intCast(@divTrunc(t * 1_000_000, f));
}

/// Calls a tool through the dispatcher and returns its parsed result.
const Caller = struct {
    server: *Server,
    arena: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    id: u32 = 1,

    const Res = struct { is_error: bool, text: []const u8, image_mime: ?[]const u8 };

    pub fn call(self: *Caller, tool: []const u8, comptime args_fmt: []const u8, args: anytype) !Res {
        self.out.clearRetainingCapacity();
        const arguments = try std.fmt.allocPrint(self.arena, args_fmt, args);
        const line = try std.fmt.allocPrint(self.arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ self.id, tool, arguments });
        self.id += 1;
        try self.server.handleMessage(line, &self.out.writer);
        const v = try std.json.parseFromSliceLeaky(std.json.Value, self.arena, try self.arena.dupe(u8, self.out.written()), .{});
        const res = v.object.get("result").?.object;
        var r: Res = .{ .is_error = if (res.get("isError")) |e| e.bool else false, .text = "", .image_mime = null };
        for (res.get("content").?.array.items) |c| {
            const t = c.object.get("type").?.string;
            if (std.mem.eql(u8, t, "text")) r.text = c.object.get("text").?.string;
            if (std.mem.eql(u8, t, "image")) r.image_mime = c.object.get("mimeType").?.string;
        }
        return r;
    }
};

fn moveWindow(tw: *TestWindow, cx: i32, cy: i32) w.RECT {
    _ = w.SetWindowPos(tw.window(), null, cx - 240, cy - 160, 0, 0, w.SWP_NOSIZE | w.SWP_NOZORDER);
    w.Sleep(150);
    var wr: w.RECT = undefined;
    _ = w.GetWindowRect(tw.window(), &wr);
    return wr;
}

fn monitorDpi(x: i32, y: i32) u32 {
    const monitor = w.MonitorFromPoint(.{ .x = x, .y = y }, w.MONITOR_DEFAULTTONEAREST);
    var dx: u32 = 0;
    var dy: u32 = 0;
    _ = w.GetDpiForMonitor(monitor, w.MDT_EFFECTIVE_DPI, &dx, &dy);
    return dx;
}

const gdi_skip = "GDI capture forced (--capture gdi): this check is for DXGI duplication";

/// The GDI fallback (US-032) on a backend forced to it: its frames show the
/// test window, the screenshot says it is a GDI capture, settling compares
/// fingerprints, and ui_find's wait sees a new button.
fn gdiChecks(report: *Report, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, main: *Windows, tw: *TestWindow, primary: display.Rect, probe: [2]i32) !void {
    var gb: Windows = .init(gpa);
    defer gb.deinit();
    gb.force_gdi = true;
    if (gb.displays().len == 0) return report.fail("capture-gdi", "no display enumerated", .{});
    // capture-gdi: the PRD budget is a p95 (< 40 ms), the second slowest
    // of 20 here. The slowest alone is not judged: BitBlt waits on DWM's
    // readback for about two thirds of a call, and under load that wait
    // reached 101 ms while the thread's own CPU stayed at 6 ms. That CPU
    // has a budget of its own, which machine load barely moves (12.5 ms at
    // most over 4000 calls with every core busy), also taken at p95.
    const per_us = cyclesPerUs();
    var walls: [20]u64 = undefined;
    var cpus: [20]u64 = undefined;
    var shows = false;
    var source: display.Frame.Source = .dxgi;
    for (&walls, &cpus) |*wall, *cpu| {
        var c0: u64 = 0;
        _ = w.QueryThreadCycleTime(w.GetCurrentThread(), &c0);
        const t0 = qpcUs();
        const r = gb.capture(0, arena);
        wall.* = qpcUs() - t0;
        var c1: u64 = 0;
        _ = w.QueryThreadCycleTime(w.GetCurrentThread(), &c1);
        cpu.* = @intFromFloat(@as(f64, @floatFromInt(c1 - c0)) / per_us);
        switch (r) {
            .failed => |msg| return report.fail("capture-gdi", "{s}", .{msg}),
            .frame => |f| {
                source = f.source;
                const i = (@as(usize, @intCast(probe[1] - primary.y)) * f.width + @as(usize, @intCast(probe[0] - primary.x))) * 4;
                shows = isColor(f.pixels[i..][0..4].*, test_window.magenta);
            },
        }
    }
    std.mem.sort(u64, &walls, {}, std.sort.asc(u64));
    std.mem.sort(u64, &cpus, {}, std.sort.asc(u64));
    const p95 = walls[walls.len - 2];
    const cpu_p95 = cpus[cpus.len - 2];
    if (shows and source == .gdi and p95 < 40_000 and cpu_p95 < 15_000)
        report.ok("capture-gdi", "{d}x{d} BitBlt frames show the test window, p95 {d} us (budget 40000 us), CPU per call p95 {d} us (budget 15000 us), slowest {d} us", .{ primary.w, primary.h, p95, cpu_p95, walls[walls.len - 1] })
    else
        report.fail("capture-gdi", "window color {}, source {t}, p95 {d} us (budget 40000 us), CPU per call p95 {d} us (budget 15000 us), slowest {d} us", .{ shows, source, p95, cpu_p95, walls[walls.len - 1] });

    // changes-gdi: a look for changes copies the window's area only, and
    // its pixels are that area's.
    {
        var wr: w.RECT = undefined;
        _ = w.GetWindowRect(tw.window(), &wr);
        const area: display.Rect = .{ .x = wr.left, .y = wr.top, .w = wr.right - wr.left, .h = wr.bottom - wr.top };
        // Medians on both sides, for the same reason as above.
        var area_walls: [20]u64 = undefined;
        var part: ?display.Frame = null;
        for (&area_walls) |*wall| {
            const t0 = qpcUs();
            const r = gb.changes(0, arena, area);
            wall.* = qpcUs() - t0;
            part = if (r == .frame) r.frame else null;
        }
        std.mem.sort(u64, &area_walls, {}, std.sort.asc(u64));
        const median = area_walls[area_walls.len / 2];
        const whole = walls[walls.len / 2];
        const ok = if (part) |f| f.area != null and f.width == area.w and f.height == area.h and
            isColor(f.pixels[@as(usize, @intCast(probe[1] - area.y)) * f.stride + @as(usize, @intCast(probe[0] - area.x)) * 4 ..][0..4].*, test_window.magenta) else false;
        if (ok and median < whole) report.ok("changes-gdi", "{d}x{d} window area copied in {d} us median (whole display {d} us)", .{ area.w, area.h, median, whole }) else report.fail("changes-gdi", "area frame {any}, median {d} us (whole display {d} us)", .{ part != null, median, whole });
    }

    // capture-fallback: on the selftest's own backend (a process holds one
    // duplication per output), a duplication that cannot be recreated after
    // a loss uses GDI for that capture only; DXGI_ERROR_UNSUPPORTED turns
    // the display to GDI for good; the secure desktop refuses the GDI path
    // too. The backend is put back on DXGI afterward.
    if (Windows.capture_mode == .gdi) report.skip("capture-fallback", "{s}", .{gdi_skip}) else {
        const sourceOf = struct {
            fn f(r: display.CaptureResult) ?display.Frame.Source {
                return if (r == .frame) r.frame.source else null;
            }
        }.f;
        // DXGI_ERROR_NOT_CURRENTLY_AVAILABLE: too many duplications.
        main.refuse_duplication = @bitCast(@as(u32, 0x887A0022));
        main.dropDuplicationForTest(0);
        const lost = sourceOf(main.capture(0, arena));
        main.refuse_duplication = null;
        const recovered = sourceOf(main.capture(0, arena));
        const transient = !main.gdiOnly(0);
        main.refuse_duplication = w.DXGI_ERROR_UNSUPPORTED;
        main.dropDuplicationForTest(0);
        const unsupported = sourceOf(main.capture(0, arena));
        main.refuse_duplication = null;
        const sticky = sourceOf(main.capture(0, arena));
        const for_good = main.gdiOnly(0);
        main.pretend_secure = true;
        const refused = main.capture(0, arena);
        main.pretend_secure = false;
        main.gdi_only[0] = false;
        main.dropDuplicationForTest(0);
        const back = sourceOf(main.capture(0, arena));
        const secure_msg = @import("../windows.zig").secure_desktop_message;
        const secure_ok = refused == .failed and std.mem.eql(u8, refused.failed, secure_msg);
        if (lost == .gdi and recovered == .dxgi and transient and unsupported == .gdi and sticky == .gdi and for_good and secure_ok and back == .dxgi)
            report.ok("capture-fallback", "UNSUPPORTED: GDI for good; recreation refused after a loss: GDI once, then DXGI; secure desktop: `{s}`", .{refused.failed})
        else
            report.fail("capture-fallback", "lost {?t} then {?t}, unsupported {?t} then {?t} (for good {}), secure refused {}, back to {?t}", .{ lost, recovered, unsupported, sticky, for_good, secure_ok, back });
    }

    var server: Server = .init(gpa, io, &gb, .{});
    defer server.deinit();
    var caller: Caller = .{ .server = &server, .arena = arena, .out = .init(gpa) };
    defer caller.out.deinit();
    const shot = try caller.call("screenshot", "{{\"display\":0}}", .{});
    const note = @import("../../core/screen.zig").gdi_note;
    if (!shot.is_error and shot.image_mime != null and std.mem.indexOf(u8, shot.text, note) != null) report.ok("screenshot-gdi", "`{s}`", .{shot.text}) else report.fail("screenshot-gdi", "{s}", .{shot.text});

    // A click on the still window settles on two equal fingerprints; a
    // window repainting every 15 ms reaches the settle timeout.
    _ = w.SetForegroundWindow(tw.window());
    const m = display.Mapping.of(0, primary, display.default_long_side);
    const c = m.toScreenshot(probe[0], probe[1]);
    const still = try caller.call("left_click", "{{\"coordinate\":[{d},{d}]}}", .{ c[0], c[1] });
    tw.animateRamp(true);
    w.Sleep(50);
    const busy = try caller.call("mouse_move", "{{\"coordinate\":[{d},{d}],\"settle_timeout_ms\":400}}", .{ c[0], c[1] });
    tw.animateRamp(false);
    w.Sleep(100);
    const settled = std.mem.indexOf(u8, still.text, "settled in ") != null;
    const timed_out = std.mem.indexOf(u8, busy.text, "settle timeout") != null;
    if (settled and timed_out) report.ok("settle-gdi", "still window: `{s}`; animated window: settle timeout", .{std.mem.sliceTo(still.text, '\n')}) else report.fail("settle-gdi", "still: {s}\nanimated: {s}", .{ still.text, busy.text });

    // ui_find's wait sees the button through a new fingerprint.
    tw.lateButton(800);
    const t0 = qpcUs();
    const late = try caller.call("ui_find", "{{\"query\":\"{s}\",\"window\":\"0x{x}\",\"wait_ms\":3000}}", .{ test_window.late_label, @intFromPtr(tw.window()) });
    const late_ms = (qpcUs() - t0) / 1000;
    tw.removeLateButton();
    w.Sleep(100);
    if (!late.is_error and std.mem.startsWith(u8, late.text, "found after ") and late_ms < 1100) report.ok("ui-find-wait-gdi", "button created at 800 ms found in {d} ms through fingerprints", .{late_ms}) else report.fail("ui-find-wait-gdi", "{d} ms: {s}", .{ late_ms, late.text });
}

/// Share of the sampled pixels of `area` (desktop coordinates) in `color`,
/// in a whole-display frame whose top-left pixel is `origin`.
fn colorShare(f: display.Frame, origin: display.Rect, area: display.Rect, color: u32) f64 {
    var hits: usize = 0;
    var total: usize = 0;
    var y = area.y;
    while (y < area.bottom()) : (y += 3) {
        var x = area.x;
        while (x < area.right()) : (x += 3) {
            const i = @as(usize, @intCast(y - origin.y)) * f.stride + @as(usize, @intCast(x - origin.x)) * 4;
            total += 1;
            if (isColor(f.pixels[i..][0..4].*, color)) hits += 1;
        }
    }
    return @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(@max(total, 1)));
}

const probe_mod = @import("exclusion_probe.zig");

/// What a capture shows over the probe's area: the probe's own colors,
/// the test window's magenta under it, or neither (no frame).
const Seen = struct {
    probe: f64,
    under: f64,

    fn hidden(self: Seen) bool {
        return self.probe == 0 and self.under > 0.95;
    }

    fn word(self: Seen) []const u8 {
        return if (self.hidden()) "hidden" else if (self.probe > 0.95) "visible" else "mixed";
    }
};

fn seenIn(r: display.CaptureResult, origin: display.Rect, area: display.Rect) ?Seen {
    const f = switch (r) {
        .frame => |f| f,
        .failed => return null,
    };
    if (f.pixels.len == 0) return null;
    return .{ .probe = colorShare(f, origin, area, probe_mod.amber) + colorShare(f, origin, area, probe_mod.green), .under = colorShare(f, origin, area, test_window.magenta) };
}

/// Captures the area by DXGI until a fresh frame shows `want` (or 1 s).
/// The test window is repainted first: a window that only leaves the
/// capture changes nothing on the monitor, so DXGI would not deliver a frame.
fn dxgiSeen(backend: *Windows, arena: std.mem.Allocator, tw: *TestWindow, origin: display.Rect, area: display.Rect, want: enum { probe, hidden }) ?Seen {
    tw.setColor(test_window.magenta);
    var last: ?Seen = null;
    var tries: u32 = 0;
    while (tries < 60) : (tries += 1) {
        w.Sleep(16);
        const r = backend.capture(0, arena);
        if (r == .frame and !r.frame.fresh and last != null) continue;
        last = seenIn(r, origin, area) orelse continue;
        const done = switch (want) {
            .probe => last.?.probe > 0.95,
            .hidden => last.?.hidden(),
        };
        if (done) break;
    }
    return last;
}

const DirtyCount = struct { rects: u32 = 0, frames: u32 = 0 };

/// Dirty rects over `area` in DXGI looks for changes during 1 s, while the
/// probe is repainted at 30 Hz (`.repaint`), shown and hidden every 100 ms
/// (`.toggle`) or left alone (`.idle`).
fn dirtyOver(backend: *Windows, arena: std.mem.Allocator, probe: *probe_mod.Probe, area: display.Rect, phase: enum { idle, repaint, toggle }) DirtyCount {
    for (0..6) |_| {
        _ = backend.changes(0, arena, null);
        w.Sleep(20);
    }
    var count: DirtyCount = .{};
    const t0 = qpcUs();
    var next: u64 = 0;
    var tick: u32 = 0;
    while (qpcUs() - t0 < 1_000_000) {
        if (qpcUs() - t0 >= next) {
            tick += 1;
            next += 33_333;
            switch (phase) {
                .idle => {},
                .repaint => probe.setColor(if (tick % 2 == 0) probe_mod.amber else probe_mod.green),
                .toggle => if (tick % 3 == 0) probe.show(tick % 6 != 0),
            }
        }
        switch (backend.changes(0, arena, null)) {
            .frame => |f| {
                var hit = false;
                for (f.dirty) |d| if (d.intersects(area)) {
                    count.rects += 1;
                    hit = true;
                };
                if (hit) count.frames += 1;
            },
            .failed => {},
        }
        w.Sleep(8);
    }
    probe.show(true);
    probe.setColor(probe_mod.amber);
    w.Sleep(100);
    _ = backend.changes(0, arena, null);
    return count;
}

/// US-033 (A8): a layered, topmost, click-through window of one color over
/// the test window is captured by DXGI and by GDI, first as any window
/// (control: both captures must show it), then with WDA_EXCLUDEFROMCAPTURE.
/// Dirty rects over it are counted at rest, while it repaints at 30 Hz
/// (captured, then excluded) and while it is shown and hidden. A
/// measurement: the line gives the outcome, which decision 0011 records;
/// only a control that does not hold fails it.
fn exclusionProbe(report: *Report, gpa: std.mem.Allocator, arena: std.mem.Allocator, backend: *Windows, tw: *TestWindow) !void {
    const name = "capture-exclusion";
    _ = w.SetForegroundWindow(tw.window());
    var wr: w.RECT = undefined;
    _ = w.GetWindowRect(tw.window(), &wr);
    // Below the test window's controls, over its magenta background.
    const area: display.Rect = .{ .x = wr.left + 140, .y = wr.top + 150, .w = 200, .h = 120 };
    const origin = backend.displays()[0].rect;
    var probe: probe_mod.Probe = .{ .rect = .{ .left = area.x, .top = area.y, .right = area.right(), .bottom = area.bottom() } };
    try probe.start();
    defer probe.stop();
    w.Sleep(150);

    var gb: Windows = .init(gpa);
    defer gb.deinit();
    gb.force_gdi = true;
    if (gb.displays().len == 0) return report.fail(name, "no display enumerated for GDI", .{});
    const dxgi = Windows.capture_mode != .gdi;

    // Control: without affinity, both captures show the probe.
    const gdi_shown = seenIn(gb.capture(0, arena), origin, area) orelse return report.fail(name, "GDI capture failed", .{});
    const dxgi_shown: ?Seen = if (dxgi) dxgiSeen(backend, arena, tw, origin, area, .probe) else null;
    if (gdi_shown.probe < 0.95 or (dxgi and (dxgi_shown == null or dxgi_shown.?.probe < 0.95)))
        return report.fail(name, "control: the probe without affinity is not captured (GDI {d:.2}, DXGI {d:.2})", .{ gdi_shown.probe, if (dxgi_shown) |s| s.probe else -1 });
    const idle: DirtyCount = if (dxgi) dirtyOver(backend, arena, &probe, area, .idle) else .{};
    const captured: DirtyCount = if (dxgi) dirtyOver(backend, arena, &probe, area, .repaint) else .{};

    if (probe.setAffinity(w.WDA_EXCLUDEFROMCAPTURE)) |code| {
        return report.skip(name, "SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) failed with error {d}: the indicator hides its windows around each capture", .{code});
    }
    const affinity = probe.affinity() orelse 0xFFFF_FFFF;
    w.Sleep(100);
    const gdi_excluded = seenIn(gb.capture(0, arena), origin, area) orelse return report.fail(name, "GDI capture failed", .{});
    if (!dxgi) return report.ok(name, "affinity 0x{x}; GDI: {s} (probe {d:.0} %, window under it {d:.0} %); DXGI not measured (--capture gdi)", .{ affinity, gdi_excluded.word(), gdi_excluded.probe * 100, gdi_excluded.under * 100 });
    const dxgi_excluded = dxgiSeen(backend, arena, tw, origin, area, .hidden) orelse return report.fail(name, "DXGI capture failed", .{});
    const excluded = dirtyOver(backend, arena, &probe, area, .repaint);
    const toggled = dirtyOver(backend, arena, &probe, area, .toggle);
    _ = probe.setAffinity(w.WDA_NONE);
    report.ok(name, "affinity 0x{x}; DXGI: {s} (probe {d:.0} %, window under it {d:.0} %); GDI: {s} (probe {d:.0} %, under {d:.0} %); dirty rects over it in 1 s (rects/frames): idle {d}/{d}, captured at 30 Hz {d}/{d}, excluded at 30 Hz {d}/{d}, excluded shown and hidden every 100 ms {d}/{d}", .{
        affinity,            dxgi_excluded.word(),     dxgi_excluded.probe * 100, dxgi_excluded.under * 100,
        gdi_excluded.word(), gdi_excluded.probe * 100, gdi_excluded.under * 100,  idle.rects,
        idle.frames,         captured.rects,           captured.frames,           excluded.rects,
        excluded.frames,     toggled.rects,            toggled.frames,
    });
}

/// Runs every subtest; returns null when all pass.
pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, log: *std.Io.Writer) !?[]const u8 {
    var report: Report = .{ .log = log };
    const gdi_forced = Windows.capture_mode == .gdi;
    if (gdi_forced) log.print("selftest: every capture goes through GDI (--capture gdi)\n", .{}) catch {};

    // DPI awareness must be per-monitor v2 so Win32, DXGI and UIA all speak
    // physical pixels.
    const awareness = w.GetAwarenessFromDpiAwarenessContext(w.GetThreadDpiAwarenessContext());
    if (awareness != w.DPI_AWARENESS_PER_MONITOR_AWARE) {
        report.fail("dpi", "process DPI awareness is {d}, expected per-monitor ({d})", .{ awareness, w.DPI_AWARENESS_PER_MONITOR_AWARE });
        return report.failed;
    }

    try com.check(w.CoInitializeEx(null, @bitCast(w.COINIT_MULTITHREADED)));
    defer w.CoUninitialize();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var backend: Windows = .init(gpa);
    defer backend.deinit();
    var server: Server = .init(gpa, io, &backend, .{});
    defer server.deinit();
    var caller: Caller = .{ .server = &server, .arena = arena, .out = .init(gpa) };
    defer caller.out.deinit();

    const displays = backend.displays();
    if (displays.len == 0) {
        report.fail("capture", "no DXGI output enumerated (hr=0x{x})", .{com.lastHr()});
        return report.failed;
    }
    for (displays, 0..) |d, i| log.print("selftest: display {d} {s} {d},{d} {d}x{d} at {d} dpi\n", .{ i, d.name, d.rect.x, d.rect.y, d.rect.w, d.rect.h, monitorDpi(d.rect.x + 1, d.rect.y + 1) }) catch {};

    const primary = displays[0].rect;
    var tw: TestWindow = .{ .rect = .{ .left = primary.x + @divTrunc(primary.w, 2) - 240, .top = primary.y + @divTrunc(primary.h, 2) - 160, .right = primary.x + @divTrunc(primary.w, 2) + 240, .bottom = primary.y + @divTrunc(primary.h, 2) + 160 } };
    tw.start() catch {
        report.fail("window", "cannot create the test window", .{});
        return report.failed;
    };
    defer tw.stop();
    w.Sleep(150); // let the first WM_PAINT land
    _ = w.SetForegroundWindow(tw.window());

    var wr: w.RECT = undefined;
    _ = w.GetWindowRect(tw.window(), &wr);
    var br: w.RECT = undefined;
    _ = w.GetWindowRect(tw.buttonWindow(), &br);
    const probe_x = wr.left + 300;
    const probe_y = wr.top + 200;

    // capture: the persistent duplication shows the window's color.
    {
        var seen = false;
        var tries: u32 = 0;
        var last: display.CaptureResult = undefined;
        while (tries < 60 and !seen) : (tries += 1) {
            last = backend.capture(0, arena);
            switch (last) {
                .failed => |msg| {
                    report.fail("capture", "{s}", .{msg});
                    return report.failed;
                },
                .frame => |f| {
                    const i = (@as(usize, @intCast(probe_y - primary.y)) * f.width + @as(usize, @intCast(probe_x - primary.x))) * 4;
                    seen = isColor(f.pixels[i..][0..4].*, test_window.magenta);
                },
            }
            if (!seen) w.Sleep(16);
        }
        if (seen) report.ok("capture", "{d}x{d} BGRA frame of {s} shows the test window", .{ last.frame.width, last.frame.height, displays[0].name }) else report.fail("capture", "pixel {d},{d} is not the test window color", .{ probe_x, probe_y });
    }

    // capture-cache: an unchanged screen is served without waiting.
    if (gdi_forced) report.skip("capture-cache", "{s}", .{gdi_skip}) else {
        var worst: u64 = 0;
        var cached: u32 = 0;
        for (0..20) |_| {
            const t0 = qpcUs();
            const r = backend.capture(0, arena);
            worst = @max(worst, qpcUs() - t0);
            if (r == .frame and !r.frame.fresh) cached += 1;
        }
        if (worst < 8000) report.ok("capture-cache", "20 captures, slowest {d} us, {d} served from the cached frame", .{ worst, cached }) else report.fail("capture-cache", "slowest capture {d} us, budget 8000 us", .{worst});
    }

    // capture-dirty: a repaint shows up as a dirty rect over the window.
    if (gdi_forced) report.skip("capture-dirty", "{s}", .{gdi_skip}) else {
        const win: display.Rect = .{ .x = wr.left, .y = wr.top, .w = wr.right - wr.left, .h = wr.bottom - wr.top };
        tw.setColor(test_window.cyan);
        var hit = false;
        var recolored = false;
        var tries: u32 = 0;
        while (tries < 60 and !(hit and recolored)) : (tries += 1) {
            w.Sleep(16);
            switch (backend.capture(0, arena)) {
                .failed => {},
                .frame => |f| {
                    for (f.dirty) |d| if (d.intersects(win)) {
                        hit = true;
                    };
                    const i = (@as(usize, @intCast(probe_y - primary.y)) * f.width + @as(usize, @intCast(probe_x - primary.x))) * 4;
                    if (isColor(f.pixels[i..][0..4].*, test_window.cyan)) recolored = true;
                },
            }
        }
        tw.setColor(test_window.magenta);
        w.Sleep(100);
        _ = backend.capture(0, arena);
        if (hit and recolored) report.ok("capture-dirty", "repaint seen with a dirty rect over the window", .{}) else report.fail("capture-dirty", "dirty rect over the window: {}, new color captured: {}", .{ hit, recolored });
    }

    // capture-changes (US-030): a look for changes sees the repaint's dirty
    // rect without reading the frame back, and the next capture still
    // returns that newest frame.
    if (gdi_forced) report.skip("capture-changes", "{s}", .{gdi_skip}) else {
        const win: display.Rect = .{ .x = wr.left, .y = wr.top, .w = wr.right - wr.left, .h = wr.bottom - wr.top };
        tw.setColor(test_window.cyan);
        var hit = false;
        var tries: u32 = 0;
        while (tries < 60 and !hit) : (tries += 1) {
            w.Sleep(16);
            switch (backend.changes(0, arena, null)) {
                .failed => {},
                .frame => |f| for (f.dirty) |d| if (d.intersects(win)) {
                    hit = true;
                },
            }
        }
        w.Sleep(50);
        _ = backend.changes(0, arena, null);
        var recolored = false;
        switch (backend.capture(0, arena)) {
            .failed => {},
            .frame => |f| {
                const i = (@as(usize, @intCast(probe_y - primary.y)) * f.width + @as(usize, @intCast(probe_x - primary.x))) * 4;
                recolored = isColor(f.pixels[i..][0..4].*, test_window.cyan);
            },
        }
        tw.setColor(test_window.magenta);
        w.Sleep(100);
        _ = backend.capture(0, arena);
        if (hit and recolored) report.ok("capture-changes", "dirty rect seen without readback, next capture shows the new color", .{}) else report.fail("capture-changes", "dirty rect seen: {}, next capture shows the new color: {}", .{ hit, recolored });
    }

    // capture-exclusion (US-033, A8): whether WDA_EXCLUDEFROMCAPTURE hides
    // a layered window from DXGI and GDI, and the dirty rects it produces.
    exclusionProbe(&report, gpa, arena, &backend, &tw) catch |err| report.fail("capture-exclusion", "{t}", .{err});

    // access-lost: the recovery path recreates the duplication in < 500 ms
    // and the next capture succeeds.
    {
        const us = backend.recreateForTest(0) catch |err| blk: {
            report.fail("access-lost", "recreation failed: {t} hr=0x{x}", .{ err, com.lastHr() });
            break :blk null;
        };
        if (us) |t| {
            const after = backend.capture(0, arena);
            if (t < 500_000 and after == .frame) report.ok("access-lost", "duplication recreated in {d} us, next capture ok", .{t}) else report.fail("access-lost", "recreated in {d} us, next capture {s}", .{ t, if (after == .frame) "ok" else after.failed });
        }
    }

    // capture-gdi, screenshot-gdi, settle-gdi, ui-find-wait-gdi (US-032):
    // the GDI fallback on a backend forced to it.
    gdiChecks(&report, gpa, io, arena, &backend, &tw, primary, .{ probe_x, probe_y }) catch |err| report.fail("capture-gdi", "{t}", .{err});

    // screenshot: the tool returns a JPEG and its mapping.
    {
        const r = try caller.call("screenshot", "{{\"display\":0}}", .{});
        const m = display.Mapping.of(0, primary, display.default_long_side);
        const want = try std.fmt.allocPrint(arena, "size={d}x{d}", .{ m.width, m.height });
        if (!r.is_error and r.image_mime != null and std.mem.indexOf(u8, r.text, want) != null) report.ok("screenshot", "{s}", .{r.text}) else report.fail("screenshot", "error={} text `{s}`", .{ r.is_error, r.text });
    }

    // accessibility: the UIA worker reads the button with the rectangle
    // Win32 reports.
    const snap = backend.uiSnapshot(arena, @intFromPtr(tw.window()), .{});
    if (snap == .err) {
        report.fail("accessibility", "snapshot failed: {s}", .{snap.err});
        return report.failed;
    }
    var found: ?display.Rect = null;
    for (snap.ok.elements) |e| if (e.role == .button and std.mem.eql(u8, e.name, test_window.button_label)) {
        found = e.rect;
    };
    if (found) |ur| {
        report.ok("accessibility", "{d} elements on the UIA worker, button found", .{snap.ok.elements.len});
        // dpi: Win32, UIA and DXGI agree on physical coordinates.
        const same = ur.x == br.left and ur.y == br.top and ur.right() == br.right and ur.bottom() == br.bottom;
        const frame = backend.capture(0, arena);
        const px = struct {
            fn at(f: display.Frame, origin: display.Rect, x: i32, y: i32) [4]u8 {
                const i = (@as(usize, @intCast(y - origin.y)) * f.width + @as(usize, @intCast(x - origin.x))) * 4;
                return f.pixels[i..][0..4].*;
            }
        }.at;
        if (!same) {
            report.fail("dpi", "UIA button rect {d},{d},{d},{d} differs from Win32 {d},{d},{d},{d}", .{ ur.x, ur.y, ur.right(), ur.bottom(), br.left, br.top, br.right, br.bottom });
        } else if (frame != .frame or isColor(px(frame.frame, primary, ur.x + 10, ur.y + 10), test_window.magenta) or !isColor(px(frame.frame, primary, ur.x - 4, ur.y + 10), test_window.magenta)) {
            report.fail("dpi", "captured pixels do not match the button edge at {d},{d}", .{ ur.x, ur.y });
        } else report.ok("dpi", "per-monitor v2, {d} dpi, Win32 = UIA = DXGI at the button edge", .{monitorDpi(ur.x, ur.y)});
    } else report.fail("accessibility", "button `{s}` not found among {d} elements", .{ test_window.button_label, snap.ok.elements.len });

    var saved: w.POINT = undefined;
    _ = w.GetCursorPos(&saved);
    defer _ = w.SetCursorPos(saved.x, saved.y);

    // mouse: on every display, a left_click at a screenshot coordinate lands
    // within 1 physical px of the pixel the mapping designates.
    for (displays, 0..) |d, di| {
        const name = "mouse";
        const dwr = moveWindow(&tw, d.rect.x + @divTrunc(d.rect.w, 2), d.rect.y + @divTrunc(d.rect.h, 2));
        _ = w.SetForegroundWindow(tw.window());
        const shot = try caller.call("screenshot", "{{\"display\":{d}}}", .{di});
        if (shot.is_error) {
            report.fail(name, "screenshot of display {d}: {s}", .{ di, shot.text });
            continue;
        }
        const m = display.Mapping.of(di, d.rect, display.default_long_side);
        var worst: i32 = 0;
        var landed = true;
        for ([_][2]i32{ .{ 300, 200 }, .{ 33, 71 }, .{ 451, 299 } }) |client| {
            const target = [2]i32{ dwr.left + client[0], dwr.top + client[1] };
            const s = m.toScreenshot(target[0], target[1]);
            const expected = m.toPhysical(s[0], s[1]);
            tw.resetEvents();
            const r = try caller.call("left_click", "{{\"coordinate\":[{d},{d}]}}", .{ s[0], s[1] });
            if (r.is_error) {
                report.fail(name, "left_click on display {d}: {s}", .{ di, r.text });
                landed = false;
                break;
            }
            const clicked = waitFor(struct {
                fn f(t: *TestWindow) bool {
                    return t.lastClick() != null;
                }
            }.f, .{&tw}, 1000);
            if (!clicked) {
                report.fail(name, "no WM_LBUTTONDOWN on display {d} within 1 s", .{di});
                landed = false;
                break;
            }
            const c = tw.lastClick().?;
            const err_px = @max(@abs(dwr.left + c[0] - expected[0]), @abs(dwr.top + c[1] - expected[1]));
            worst = @max(worst, @as(i32, @intCast(err_px)));
        }
        if (landed) {
            if (worst <= 1) report.ok(name, "display {d} at {d} dpi, scale {d:.2}: worst error {d} px", .{ di, monitorDpi(d.rect.x + 1, d.rect.y + 1), m.scale, worst }) else report.fail(name, "display {d}: click {d} px away from the mapped pixel", .{ di, worst });
        }
    }

    // dpi-unaware: a legacy (DPI-unaware) window gets logical coordinates
    // scaled by Windows; a click mapped from the screenshot must land on the
    // logical pixel under the physical target, within 1 logical px.
    dpiUnaware(&report, &caller, &tw, displays[0].rect) catch |err| report.fail("dpi-unaware", "{t}", .{err});

    // Back to the primary display for the remaining checks.
    wr = moveWindow(&tw, primary.x + @divTrunc(primary.w, 2), primary.y + @divTrunc(primary.h, 2));
    _ = w.SetForegroundWindow(tw.window());
    _ = try caller.call("screenshot", "{{\"display\":0}}", .{});
    const m0 = display.Mapping.of(0, primary, display.default_long_side);
    const center = m0.toScreenshot(wr.left + 300, wr.top + 200);

    // mouse-bounds: a coordinate outside the screenshot moves nothing.
    {
        var before: w.POINT = undefined;
        _ = w.GetCursorPos(&before);
        const r = try caller.call("mouse_move", "{{\"coordinate\":[{d},0]}}", .{m0.width});
        var after: w.POINT = undefined;
        _ = w.GetCursorPos(&after);
        if (r.is_error and before.x == after.x and before.y == after.y) report.ok("mouse-bounds", "{s}", .{r.text}) else report.fail("mouse-bounds", "error={} cursor {d},{d} -> {d},{d}", .{ r.is_error, before.x, before.y, after.x, after.y });
    }

    // mouse-buttons: right and double clicks, wheel in 120 units per click.
    {
        tw.resetEvents();
        _ = try caller.call("right_click", "{{\"coordinate\":[{d},{d}]}}", .{ center[0], center[1] });
        _ = try caller.call("double_click", "{{\"coordinate\":[{d},{d}]}}", .{ center[0], center[1] });
        _ = try caller.call("scroll", "{{\"scroll_direction\":\"down\",\"scroll_amount\":2,\"coordinate\":[{d},{d}]}}", .{ center[0], center[1] });
        w.Sleep(150);
        if (tw.rightClicks() == 1 and tw.clickCount() == 2 and tw.wheelDelta() == -240) report.ok("mouse-buttons", "right click, double click, wheel -240", .{}) else report.fail("mouse-buttons", "right clicks {d}, left clicks {d}, wheel {d} (expected 1, 2, -240)", .{ tw.rightClicks(), tw.clickCount(), tw.wheelDelta() });
    }

    // keyboard: keys resolve on the target's layout (AZERTY when installed),
    // text arrives as Unicode, emoji and new line included.
    {
        _ = try caller.call("window_focus", "{{\"window\":\"0x{x}\"}}", .{@intFromPtr(tw.window())});
        var layouts: [32]w.HKL = undefined;
        const nl: usize = @intCast(@max(0, w.GetKeyboardLayoutList(layouts.len, &layouts)));
        var azerty: ?w.HKL = null;
        for (layouts[0..nl]) |hkl| if (@as(u16, @truncate(@intFromPtr(hkl) >> 16)) == 0x040C) {
            azerty = hkl;
        };
        if (azerty) |hkl| {
            tw.setLayout(hkl);
            w.Sleep(50);
        }
        const layout_name: []const u8 = if (azerty != null) "AZERTY 040C" else "active layout (no French layout installed)";
        var buf: [64:0]u16 = undefined;
        tw.resetEvents();
        _ = try caller.call("key", "{{\"text\":\"a\"}}", .{});
        _ = try caller.call("key", "{{\"text\":\";\"}}", .{});
        w.Sleep(100);
        const got_keys = tw.received(&buf);
        const keys_ok = got_keys.len == 2 and got_keys[0] == 'a' and got_keys[1] == ';';
        tw.resetEvents();
        _ = try caller.call("key", "{{\"text\":\"ctrl+a\"}}", .{});
        w.Sleep(100);
        const kd = tw.lastKeyDown();
        const ctrl_ok = (kd & 0xFFFF) == 'A' and (kd >> 16) == 1;
        if (keys_ok and ctrl_ok) report.ok("keyboard", "{s}: a and ; as WM_CHAR, ctrl+a as VK_A with Ctrl", .{layout_name}) else report.fail("keyboard", "{s}: chars {any}, keydown 0x{x}", .{ layout_name, got_keys, kd });

        tw.resetEvents();
        _ = try caller.call("type", "{{\"text\":\"\u{e9}\u{1F600}\\n\"}}", .{});
        w.Sleep(150);
        const typed = tw.received(&buf);
        const want = [_]u16{ 0xE9, 0xD83D, 0xDE00, 0x0D };
        if (std.mem.eql(u16, typed, &want)) report.ok("type", "U+00E9, U+1F600 as a surrogate pair, Return", .{}) else report.fail("type", "received {any}, expected {any}", .{ typed, want });

        // An unknown key name lists close valid names.
        const bad = try caller.call("key", "{{\"text\":\"Retrun\"}}", .{});
        if (bad.is_error and std.mem.indexOf(u8, bad.text, "Return") != null) report.ok("key-names", "{s}", .{bad.text}) else report.fail("key-names", "{s}", .{bad.text});
    }

    uiChecks(&report, &caller, &backend, &tw) catch |err| report.fail("ui", "{t}", .{err});
    // ui-find-wait-cpu (US-030): the capture of this run, DXGI unless
    // --capture gdi. ui-find-wait-cpu-gdi (US-032): GDI on a window that
    // fills display 0, each look copying and fingerprinting all of it (a
    // Debug fingerprint once cost 11.5 ms per look, 8 % of a core).
    stillWaitCheck(io, env, &report, arena, "ui-find-wait-cpu", .{ .x = primary.x + 40, .y = primary.y + 40, .w = 480, .h = 320 }, if (gdi_forced) "gdi" else "auto");
    stillWaitCheck(io, env, &report, arena, "ui-find-wait-cpu-gdi", primary, "gdi");
    rangeTimeoutCheck(io, &report, &caller, &backend, arena);

    // windows: window_list reports the test window; window_focus restores it.
    {
        const handle = try std.fmt.allocPrint(arena, "0x{x} \"{s}\" neo-compute.exe pid={d}", .{ @intFromPtr(tw.window()), test_window.title, w.GetCurrentProcessId() });
        const list = try caller.call("window_list", "{{}}", .{});
        if (!list.is_error and std.mem.indexOf(u8, list.text, handle) != null) report.ok("window-list", "test window listed", .{}) else report.fail("window-list", "`{s}` not in:\n{s}", .{ handle, list.text });

        _ = w.ShowWindow(tw.window(), w.SW_MINIMIZE);
        w.Sleep(200);
        const r = try caller.call("window_focus", "{{\"window\":\"0x{x}\"}}", .{@intFromPtr(tw.window())});
        if (!r.is_error and w.GetForegroundWindow() == tw.window() and w.IsIconic(tw.window()) == 0) report.ok("window-focus", "minimized window restored and in the foreground", .{}) else report.fail("window-focus", "{s}", .{r.text});
    }

    // uipi: an action on an elevated window is refused before injection.
    {
        const list = try caller.call("window_list", "{{}}", .{});
        var lines = std.mem.splitScalar(u8, list.text, '\n');
        var tested = false;
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "{elevated") == null or std.mem.indexOf(u8, line, "display=0 @") == null) continue;
            const at = std.mem.indexOf(u8, line, "display=0 @").? + "display=0 @".len;
            var it = std.mem.tokenizeAny(u8, line[at..], ", ");
            const x = std.fmt.parseInt(i32, it.next() orelse continue, 10) catch continue;
            const y = std.fmt.parseInt(i32, it.next() orelse continue, 10) catch continue;
            const r = try caller.call("mouse_move", "{{\"coordinate\":[{d},{d}]}}", .{ @max(x + 5, 0), @max(y + 5, 0) });
            _ = r;
            const c = try caller.call("left_click", "{{\"coordinate\":[{d},{d}]}}", .{ @max(x + 5, 0), @max(y + 5, 0) });
            if (c.is_error and std.mem.indexOf(u8, c.text, "UIPI") != null) report.ok("uipi", "{s}", .{c.text}) else report.skip("uipi", "elevated window not under its own corner (covered): {s}", .{c.text});
            tested = true;
            break;
        }
        if (!tested) report.skip("uipi", "no elevated window on display 0; open one to exercise this check", .{});
    }

    windowsAndAppsChecks(&report, &caller, &backend, arena) catch |err| report.fail("windows-apps", "{t}", .{err});

    securityChecks(&report, gpa, io, arena, &backend, &tw) catch |err| report.fail("security", "{t}", .{err});

    // EP-009: clipboard (US-035) and registry_read (US-036).
    const system_checks = @import("selftest_system.zig");
    system_checks.clipboardChecks(&report, &caller, gpa, io, arena, &backend, tw.window()) catch |err| report.fail("clipboard", "{t}", .{err});
    system_checks.registryChecks(&report, &caller) catch |err| report.fail("registry", "{t}", .{err});

    // release: the shipped server releases a held key within 50 ms of stdin
    // EOF and exits with code 0.
    releaseCheck(io, &report, arena);
    noIndicatorCheck(io, env, &report, arena, displays.len);

    return report.failed;
}

/// EP-006: display lines and virtual desktops in window_list (US-026),
/// window_set on a window of its own (US-027), the Start menu catalog
/// (US-028). Applications are launched by `bench app_launch` only.
fn windowsAndAppsChecks(report: *Report, caller: *Caller, backend: *Windows, arena: std.mem.Allocator) !void {
    const apps = @import("../../core/apps.zig");
    const displays = backend.displays();

    // window-displays: one line per display first, the primary one flagged,
    // the DPI GetDpiForMonitor reports.
    {
        const list = try caller.call("window_list", "{{}}", .{});
        var lines = std.mem.splitScalar(u8, list.text, '\n');
        var good = !list.is_error;
        var primaries: usize = 0;
        for (displays, 0..) |d, i| {
            const line = lines.next() orelse "";
            const want = try std.fmt.allocPrint(arena, "display={d}", .{i});
            const dpi = try std.fmt.allocPrint(arena, " dpi={d} ", .{monitorDpi(d.rect.x + 1, d.rect.y + 1)});
            const physical = try std.fmt.allocPrint(arena, " physical={d}x{d} ", .{ d.rect.w, d.rect.h });
            if (!std.mem.startsWith(u8, line, want) or std.mem.indexOf(u8, line, dpi) == null or std.mem.indexOf(u8, line, physical) == null or std.mem.indexOf(u8, line, " work=") == null) good = false;
            if (std.mem.indexOf(u8, line, " primary ") != null) primaries += 1;
        }
        const first_window = lines.next() orelse "";
        if (good and primaries == 1 and std.mem.startsWith(u8, first_window, "0x")) report.ok("window-displays", "{d} display line(s), one primary, then the windows", .{displays.len}) else report.fail("window-displays", "{d} primary, output:\n{s}", .{ primaries, list.text });
    }

    // virtual-desktops: IVirtualDesktopManager answers on the shell STA and
    // places a window of this desktop on it.
    {
        var own: TestWindow = .{ .rect = .{ .left = displays[0].rect.x + 40, .top = displays[0].rect.y + 40, .right = displays[0].rect.x + 360, .bottom = displays[0].rect.y + 240 } };
        own.start() catch return error.WindowCreationFailed;
        defer own.stop();
        var other = [_]bool{true};
        const handles = [_]u64{@intFromPtr(own.window())};
        const answered = backend.shell.otherDesktops(&handles, &other);
        const hidden = try caller.call("window_list", "{{\"include_hidden\":true}}", .{});
        if (answered and !other[0] and !hidden.is_error) report.ok("virtual-desktops", "IVirtualDesktopManager answers, the test window is on the current desktop", .{}) else if (!answered) report.skip("virtual-desktops", "IVirtualDesktopManager unavailable (Explorer restarted?): cloaked windows keep their flag", .{}) else report.fail("virtual-desktops", "other desktop: {}, window_list: {s}", .{ other[0], hidden.text });
    }

    // window-set: the visible frame lands on the requested rectangle within
    // 2 screenshot pixels, states change, a hung window is reported, force
    // never ends neo-compute, and state closed closes the window.
    {
        var own: TestWindow = .{ .rect = .{ .left = displays[0].rect.x + 100, .top = displays[0].rect.y + 100, .right = displays[0].rect.x + 500, .bottom = displays[0].rect.y + 400 } };
        own.start() catch return error.WindowCreationFailed;
        defer own.stop();
        const h = @intFromPtr(own.window());
        const m = display.Mapping.of(0, displays[0].rect, display.default_long_side);
        const half_w: i32 = @intCast(m.width / 2);
        const want: display.Rect = .{ .x = 0, .y = 0, .w = half_w, .h = @intCast(m.height) };
        var worst_us: u64 = 0;
        var placed_ok = true;
        var last_text: []const u8 = "";
        for (0..10) |i| {
            const x: i32 = if (i % 2 == 0) 0 else half_w;
            const t0 = qpcUs();
            const r = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"rect\":[{d},0,{d},{d}],\"display\":0,\"observe\":\"none\"}}", .{ h, x, want.w, want.h });
            worst_us = @max(worst_us, qpcUs() - t0);
            last_text = r.text;
            const got = m.rectToScreenshot(@import("window.zig").rect(own.window()) orelse return error.WindowGone);
            if (r.is_error or @abs(got.x - x) > 2 or @abs(got.y) > 2 or @abs(got.w - want.w) > 2 or @abs(got.h - want.h) > 2) placed_ok = false;
        }
        if (placed_ok) report.ok("window-set-rect", "10 placements on the halves of display 0 within 2 px, slowest {d} us: {s}", .{ worst_us, last_text }) else report.fail("window-set-rect", "{s}", .{last_text});

        const max = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"maximized\",\"observe\":\"none\"}}", .{h});
        const zoomed = w.IsZoomed(own.window()) != 0;
        const restored = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"normal\",\"observe\":\"none\"}}", .{h});
        const normal = w.IsZoomed(own.window()) == 0 and w.IsIconic(own.window()) == 0;
        const min = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"minimized\",\"observe\":\"none\"}}", .{h});
        const iconic = w.IsIconic(own.window()) != 0;
        if (zoomed and normal and iconic and !max.is_error and !restored.is_error and !min.is_error) report.ok("window-set-state", "{s} / {s} / {s}", .{ max.text, restored.text, min.text }) else report.fail("window-set-state", "zoomed {} normal {} iconic {}: {s} / {s} / {s}", .{ zoomed, normal, iconic, max.text, restored.text, min.text });
        _ = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"normal\",\"observe\":\"none\"}}", .{h});

        own.hang(1500);
        w.Sleep(50);
        const hung = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"maximized\",\"observe\":\"none\"}}", .{h});
        w.Sleep(1600);
        if (hung.is_error and std.mem.indexOf(u8, hung.text, "ne répond pas") != null) report.ok("window-set-hung", "{s}", .{hung.text}) else report.fail("window-set-hung", "{s}", .{hung.text});

        const forced = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"closed\",\"force\":true}}", .{h});
        const still = w.IsWindow(own.window()) != 0;
        if (forced.is_error and still and std.mem.eql(u8, forced.text, "Fermeture forcée refusée : neo-compute.exe est protégé")) report.ok("window-set-protected", "{s}", .{forced.text}) else report.fail("window-set-protected", "window alive {}: {s}", .{ still, forced.text });

        const closed = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"closed\",\"observe\":\"none\"}}", .{h});
        const gone = waitFor(struct {
            fn f(hwnd: w.HWND) bool {
                return w.IsWindow(hwnd) == 0;
            }
        }.f, .{own.window()}, 1000);
        if (!closed.is_error and gone and std.mem.startsWith(u8, closed.text, "0x") and std.mem.indexOf(u8, closed.text, "fermée") != null) report.ok("window-set-close", "{s}", .{closed.text}) else report.fail("window-set-close", "gone {}: {s}", .{ gone, closed.text });
        const after = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"minimized\"}}", .{h});
        if (after.is_error and std.mem.eql(u8, after.text, "Fenêtre fermée : rappelle window_list")) report.ok("window-set-closed-handle", "{s}", .{after.text}) else report.fail("window-set-closed-handle", "{s}", .{after.text});
    }

    // apps-catalog: the Start menu enumerates on the shell STA, with
    // packaged and non-packaged entries, a non-packaged entry's shortcut
    // resolves to its executable (the policy before a launch), and a cached
    // match finds Calculator by its French name.
    {
        var cancel: std.atomic.Value(bool) = .init(false);
        const t0 = qpcUs();
        const listed = backend.appCatalog(arena, &cancel);
        const first_us = qpcUs() - t0;
        switch (listed) {
            .err => |msg| report.fail("apps-catalog", "{s}", .{msg}),
            .ok => |list| {
                var packaged: usize = 0;
                var with_exe: usize = 0;
                var sample: []const u8 = "";
                var lookup_us: u64 = 0;
                for (list) |a| {
                    packaged += @intFromBool(a.packaged);
                    if (a.packaged) continue;
                    const t2 = qpcUs();
                    const exe = backend.appExe(arena, a);
                    lookup_us = @max(lookup_us, qpcUs() - t2);
                    if (exe) |e| {
                        with_exe += 1;
                        if (sample.len == 0) sample = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ a.name, e });
                    }
                }
                var cat: apps.Catalog = .{};
                defer cat.deinit();
                try cat.replace(std.heap.page_allocator, list, 0);
                _ = try apps.match(arena, cat.apps, "warm");
                const t1 = qpcUs();
                const calc = try apps.match(arena, cat.apps, "calculatrice");
                const match_us = qpcUs() - t1;
                const calc_ok = calc == .found and calc.found.packaged and std.mem.startsWith(u8, calc.found.aumid, "Microsoft.WindowsCalculator_");
                // Budgets (300 ms, 1 ms) are checked in ReleaseFast by
                // `bench apps-catalog` and `bench apps`; this Debug build
                // checks the content.
                if (packaged > 0 and with_exe > 0 and calc_ok)
                    report.ok("apps-catalog", "{d} entries ({d} packaged, {d} shortcuts to an exe, slowest lookup {d} us, e.g. {s}) in {d} us (Debug), `calculatrice` -> {s} in {d} us", .{ list.len, packaged, with_exe, lookup_us, sample, first_us, calc.found.aumid, match_us })
                else
                    report.fail("apps-catalog", "{d} entries ({d} packaged, {d} with exe) in {d} us, calculatrice: {t}", .{ list.len, packaged, with_exe, first_us, calc });
            },
        }
    }
}

/// Id of the first ui_tree line containing `needle`.
fn idOf(tree: []const u8, needle: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, tree, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const id = it.next() orelse return null;
        return if (uitree.parseId(id) != null) id else null;
    }
    return null;
}

/// The accessibility tools and the post-action observation, through the
/// dispatcher, against the test window.
fn uiChecks(report: *Report, caller: *Caller, backend: *Windows, tw: *TestWindow) !void {
    _ = w.SetForegroundWindow(tw.window());
    const handle = @intFromPtr(tw.window());

    // ui-tree: one line per element with its id; the password stays masked.
    const tree = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{handle});
    const button_line = "button \"" ++ test_window.button_label ++ "\"";
    const button_id = idOf(tree.text, button_line);
    const leaked = std.mem.indexOf(u8, tree.text, test_window.secret) != null;
    if (!tree.is_error and button_id != null and std.mem.indexOf(u8, tree.text, "[=" ++ uitree.password_mask ++ "]") != null and !leaked)
        report.ok("ui-tree", "button is {s}, password field shown as [=•••]", .{button_id.?})
    else
        report.fail("ui-tree", "button id {?s}, password leaked: {}, tree:\n{s}", .{ button_id, leaked, tree.text });
    const id = button_id orelse return;

    // ui-range (US-022): the trackbar's RangeValue, read by the second
    // cached round trip, on its line.
    {
        const want = std.fmt.comptimePrint("[={d}/{d}..{d}]", .{ test_window.slider_pos, test_window.slider_min, test_window.slider_max });
        var lines = std.mem.splitScalar(u8, tree.text, '\n');
        const line = while (lines.next()) |l| {
            if (std.mem.indexOf(u8, l, " slider ") != null) break l;
        } else "";
        const extras_us = backend.ui.lastExtrasNs() / 1000;
        if (std.mem.indexOf(u8, line, want) != null) report.ok("ui-range", "`{s}`, range and scroll round trip {d} us", .{ std.mem.trim(u8, line, " "), extras_us }) else report.fail("ui-range", "no slider line with {s}, tree:\n{s}", .{ want, tree.text });
    }

    // ui-find: by role and accent-insensitive name words.
    const found = try caller.call("ui_find", "{{\"query\":\"role:button SELFTEST\",\"window\":\"0x{x}\"}}", .{handle});
    if (!found.is_error and std.mem.indexOf(u8, found.text, button_line) != null) report.ok("ui-find", "role:button SELFTEST finds {s}", .{id}) else report.fail("ui-find", "{s}", .{found.text});

    // ui-find-wait (US-030): a button created 800 ms into the call is found
    // in under 900 ms; a 5 s wait on a still window costs under 5 % of a
    // core.
    {
        tw.lateButton(800);
        const t0 = qpcUs();
        const late = try caller.call("ui_find", "{{\"query\":\"{s}\",\"window\":\"0x{x}\",\"wait_ms\":3000}}", .{ test_window.late_label, handle });
        const late_ms = (qpcUs() - t0) / 1000;
        tw.removeLateButton();
        const headed = std.mem.startsWith(u8, late.text, "found after ");
        // Forced GDI looks every 100 ms: the 900 ms bound is DXGI's.
        const bound: u64 = if (Windows.capture_mode == .gdi) 1100 else 900;
        if (!late.is_error and headed and std.mem.indexOf(u8, late.text, "button \"" ++ test_window.late_label ++ "\"") != null and late_ms < bound and late_ms >= 800)
            report.ok("ui-find-wait", "button created at 800 ms found in {d} ms: `{s}`", .{ late_ms, std.mem.sliceTo(late.text, '\n') })
        else
            report.fail("ui-find-wait", "found in {d} ms (want 800..{d}), error={}: {s}", .{ late_ms, bound, late.is_error, late.text });
        w.Sleep(100);
    }
    // ui-marks (US-031): ui_tree marks returns the tree and the screenshot
    // of display 0 with the button's id drawn at its corner over the masked
    // password field's neighbor; that id invokes the button.
    {
        const marked = try caller.call("ui_tree", "{{\"window\":\"0x{x}\",\"marks\":true}}", .{handle});
        const mark_id = idOf(marked.text, button_line);
        var br: w.RECT = undefined;
        _ = w.GetWindowRect(tw.buttonWindow(), &br);
        var pr: w.RECT = undefined;
        _ = w.GetWindowRect(tw.passwordWindow(), &pr);
        const m = display.Mapping.of(0, backend.displays()[0].rect, display.default_long_side);
        const out = caller.server.session.reducer.out;
        const px = struct {
            fn at(buf: []const u8, mm: display.Mapping, x: i32, y: i32) [4]u8 {
                const p = mm.toScreenshot(x, y);
                return buf[(@as(usize, @intCast(p[1])) * mm.width + @as(usize, @intCast(p[0]))) * 4 ..][0..4].*;
            }
        }.at;
        const corner = px(out, m, br.left, br.top);
        const field = px(out, m, pr.right - 4, pr.bottom - 4);
        const labeled = corner[0] < 40 and corner[1] > 200 and corner[2] > 200;
        const masked = field[0] < 16 and field[1] < 16 and field[2] < 16;
        const before_marks = tw.commandCount();
        const acted = if (mark_id) |mid| try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"invoke\",\"observe\":\"none\"}}", .{mid}) else null;
        const clicked = waitFor(struct {
            fn f(t: *TestWindow, n: u32) bool {
                return t.commandCount() > n;
            }
        }.f, .{ tw, before_marks }, 1000);
        if (!marked.is_error and marked.image_mime != null and labeled and masked and acted != null and !acted.?.is_error and clicked and std.mem.indexOf(u8, marked.text, test_window.secret) == null)
            report.ok("ui-marks", "{s} drawn at the button's corner (BGRA {any}), password field black, `{s}`", .{ mark_id.?, corner, acted.?.text })
        else
            report.fail("ui-marks", "image={?s} label at corner={} (BGRA {any}) field masked={} id={?s} invoked={}", .{ marked.image_mime, labeled, corner, masked, mark_id, clicked });
    }

    // ui-act: Invoke reaches the button as BN_CLICKED, without coordinates.
    const before = tw.commandCount();
    const invoked = try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"invoke\",\"observe\":\"none\"}}", .{id});
    const clicked = waitFor(struct {
        fn f(t: *TestWindow, n: u32) bool {
            return t.commandCount() > n;
        }
    }.f, .{ tw, before }, 1000);
    if (!invoked.is_error and clicked) report.ok("ui-act", "{s}", .{invoked.text}) else report.fail("ui-act", "error={} BN_CLICKED={} {s}", .{ invoked.is_error, clicked, invoked.text });

    // ui-selection (US-022): the focused field's selection, through its
    // TextPattern; focus goes back to the window afterward.
    {
        tw.select(true);
        w.Sleep(150);
        const t = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{handle});
        tw.select(false);
        w.Sleep(50);
        const want = "sel=\"" ++ test_window.note_selected ++ "\" {focused}";
        var lines = std.mem.splitScalar(u8, t.text, '\n');
        const line = while (lines.next()) |l| {
            if (std.mem.indexOf(u8, l, " sel=") != null) break l;
        } else "";
        if (std.mem.indexOf(u8, line, want) != null and std.mem.indexOf(u8, t.text, test_window.secret) == null) report.ok("ui-selection", "`{s}`", .{std.mem.trim(u8, line, " ")}) else report.fail("ui-selection", "no line with {s}, tree:\n{s}", .{ want, t.text });
    }

    // ui-menu (US-023): a popup menu of the window is a root of its tree,
    // its item is invoked by id, and once the menu is closed the same id
    // is refused without any action.
    {
        var wr: w.RECT = undefined;
        _ = w.GetWindowRect(tw.window(), &wr);
        tw.openMenu(wr.left + 60, wr.top + 200);
        const menu_class = std.unicode.utf8ToUtf16LeStringLiteral("#32768");
        const opened = waitFor(struct {
            fn f(class: [*:0]const u16) bool {
                const m = w.FindWindowW(class, null);
                return m != null and w.IsWindowVisible(m) != 0;
            }
        }.f, .{menu_class}, 2000);
        const menu = w.FindWindowW(menu_class, null);
        const t = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{handle});
        const header = try std.fmt.allocPrint(caller.arena, "window=0x{x}", .{@intFromPtr(menu)});
        const item = "menuitem \"" ++ test_window.menu_items[1] ++ "\"";
        const item_id = idOf(t.text, item);
        if (!opened or item_id == null or std.mem.indexOf(u8, t.text, header) == null) {
            report.fail("ui-menu", "menu open={} id={?s}, tree:\n{s}", .{ opened, item_id, t.text });
            if (menu != null) _ = w.PostMessageW(menu, w.WM_KEYDOWN, w.VK_ESCAPE, 0);
        } else {
            const r = try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"invoke\",\"observe\":\"none\"}}", .{item_id.?});
            const chosen = waitFor(struct {
                fn f(x: *TestWindow) bool {
                    return x.menuChoice() == 2 and !x.menuOpen();
                }
            }.f, .{tw}, 2000);
            const again = try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"invoke\",\"observe\":\"none\"}}", .{item_id.?});
            const gone = try std.fmt.allocPrint(caller.arena, "Élément {s} introuvable : rappelle ui_tree", .{item_id.?});
            if (!r.is_error and chosen and again.is_error and std.mem.eql(u8, again.text, gone)) report.ok("ui-menu", "menu 0x{x} is a root, {s} invoked by id, then `{s}`", .{ @intFromPtr(menu), item_id.?, again.text }) else report.fail("ui-menu", "invoke `{s}` chosen={} after close `{s}`", .{ r.text, chosen, again.text });
            if (tw.menuOpen()) _ = w.PostMessageW(menu, w.WM_KEYDOWN, w.VK_ESCAPE, 0);
        }
        _ = waitFor(struct {
            fn f(x: *TestWindow) bool {
                return !x.menuOpen();
            }
        }.f, .{tw}, 1000);
    }

    // ui-set-value: the password field takes the value, which no output shows.
    if (idOf(tree.text, "[=" ++ uitree.password_mask ++ "]")) |pid| {
        const value = "s3cr3t-neo-compute";
        const set = try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"set_value\",\"value\":\"{s}\",\"observe\":\"delta\"}}", .{ pid, value });
        var buf: [64:0]u16 = undefined;
        const n: usize = @intCast(@max(0, w.GetWindowTextW(tw.passwordWindow(), &buf, buf.len)));
        var utf8: [192]u8 = undefined;
        const got = utf8[0..std.unicode.wtf16LeToWtf8(&utf8, buf[0..n])];
        const shown = std.mem.indexOf(u8, set.text, value) != null;
        if (!set.is_error and std.mem.eql(u8, got, value) and !shown) report.ok("ui-set-value", "password field set through ValuePattern, value absent from the result", .{}) else report.fail("ui-set-value", "error={} field matches={} value shown={} {s}", .{ set.is_error, std.mem.eql(u8, got, value), shown, set.text });
    } else report.fail("ui-set-value", "password field not in the tree", .{});

    // settle: an action on a still window settles; a window repainting every
    // 15 ms reaches settle_timeout_ms without an error.
    {
        const shot = try caller.call("screenshot", "{{\"display\":0}}", .{});
        _ = shot;
        var wr: w.RECT = undefined;
        _ = w.GetWindowRect(tw.window(), &wr);
        const m = display.Mapping.of(0, backend.displays()[0].rect, display.default_long_side);
        const c = m.toScreenshot(wr.left + 300, wr.top + 200);
        const still = try caller.call("left_click", "{{\"coordinate\":[{d},{d}]}}", .{ c[0], c[1] });
        // Two alternating colors can look still to fingerprints taken 50 ms
        // apart: under forced GDI the window takes a new color each frame.
        const gdi = Windows.capture_mode == .gdi;
        if (gdi) tw.animateRamp(true) else tw.animate(true);
        w.Sleep(50);
        const t0 = qpcUs();
        const busy = try caller.call("left_click", "{{\"coordinate\":[{d},{d}],\"settle_timeout_ms\":300,\"observe\":\"none\"}}", .{ c[0], c[1] });
        _ = busy;
        const busy2 = try caller.call("mouse_move", "{{\"coordinate\":[{d},{d}],\"settle_timeout_ms\":300}}", .{ c[0], c[1] });
        const busy_ms = (qpcUs() - t0) / 1000;
        if (gdi) tw.animateRamp(false) else tw.animate(false);
        w.Sleep(100);
        const settled = std.mem.indexOf(u8, still.text, "settled in ") != null and std.mem.indexOf(u8, still.text, "window=0x") != null;
        const timed_out = !busy2.is_error and std.mem.indexOf(u8, busy2.text, "settle timeout") != null;
        if (settled and timed_out) report.ok("settle", "still window: `{s}`; animated window: settle timeout after {d} ms", .{ std.mem.sliceTo(still.text, '\n'), busy_ms }) else report.fail("settle", "still: {s}\nanimated: {s}", .{ still.text, busy2.text });
    }

    // ui-timeout: a window that stops answering yields a partial tree or a
    // bounded error, and the worker still serves other windows.
    {
        tw.hang(1500);
        w.Sleep(50);
        const t0 = qpcUs();
        const hung = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{handle});
        const hung_ms = (qpcUs() - t0) / 1000;
        const taskbar = w.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd"), null);
        const t1 = qpcUs();
        const other = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{@intFromPtr(taskbar)});
        const other_ms = (qpcUs() - t1) / 1000;
        w.Sleep(1500);
        const partial = std.mem.startsWith(u8, hung.text, "{partial: timeout}") or (hung.is_error and std.mem.indexOf(u8, hung.text, "ne répond plus") != null);
        if (hung_ms < 1000 and !other.is_error and other_ms < 1000) {
            if (partial) report.ok("ui-timeout", "hung window answered in {d} ms (`{s}`), taskbar tree next in {d} ms", .{ hung_ms, std.mem.sliceTo(hung.text, '\n'), other_ms }) else report.ok("ui-timeout", "hung window still answered in {d} ms (provider in-process, no timeout needed), taskbar tree next in {d} ms", .{ hung_ms, other_ms });
        } else report.fail("ui-timeout", "hung window {d} ms ({s}), taskbar {d} ms error={}", .{ hung_ms, std.mem.sliceTo(hung.text, '\n'), other_ms, other.is_error });
    }

    // ui-stale: an element destroyed between ui_tree and ui_act.
    {
        var tmp: TestWindow = .{ .rect = .{ .left = 40, .top = 40, .right = 400, .bottom = 300 } };
        try tmp.start();
        w.Sleep(150);
        const t = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{@intFromPtr(tmp.window())});
        const tid = idOf(t.text, button_line);
        tmp.stop();
        w.Sleep(100);
        if (tid) |sid| {
            const r = try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"invoke\"}}", .{sid});
            const want = try std.fmt.allocPrint(caller.arena, "Élément {s} introuvable : rappelle ui_tree", .{sid});
            if (r.is_error and std.mem.eql(u8, r.text, want)) report.ok("ui-stale", "{s}", .{r.text}) else report.fail("ui-stale", "{s}", .{r.text});
        } else report.fail("ui-stale", "temporary button not in the tree:\n{s}", .{t.text});
    }
}

fn dpiUnaware(report: *Report, caller: *Caller, main: *TestWindow, primary: display.Rect) !void {
    _ = w.ShowWindow(main.window(), w.SW_MINIMIZE);
    defer _ = w.ShowWindow(main.window(), w.SW_RESTORE);
    var legacy: TestWindow = .{ .rect = .{ .left = primary.x + 100, .top = primary.y + 100, .right = primary.x + 580, .bottom = primary.y + 420 }, .dpi_unaware = true };
    try legacy.start();
    defer legacy.stop();
    w.Sleep(200);
    _ = w.SetForegroundWindow(legacy.window());
    const dpi = monitorDpi(primary.x + 101, primary.y + 101);
    // Physical client origin, read from this per-monitor-aware thread.
    var origin: w.POINT = .{ .x = 0, .y = 0 };
    _ = w.ClientToScreen(legacy.window(), &origin);
    _ = try caller.call("screenshot", "{{\"display\":0}}", .{});
    const m = display.Mapping.of(0, primary, display.default_long_side);
    const k = @as(f64, @floatFromInt(dpi)) / 96.0;
    var worst: f64 = 0;
    for ([_][2]i32{ .{ 200, 150 }, .{ 37, 61 }, .{ 401, 277 } }) |logical| {
        const target = [2]i32{ origin.x + @as(i32, @intFromFloat(@as(f64, @floatFromInt(logical[0])) * k)), origin.y + @as(i32, @intFromFloat(@as(f64, @floatFromInt(logical[1])) * k)) };
        const s = m.toScreenshot(target[0], target[1]);
        const p = m.toPhysical(s[0], s[1]);
        legacy.resetEvents();
        const r = try caller.call("left_click", "{{\"coordinate\":[{d},{d}]}}", .{ s[0], s[1] });
        if (r.is_error) return report.fail("dpi-unaware", "left_click: {s}", .{r.text});
        const clicked = waitFor(struct {
            fn f(t: *TestWindow) bool {
                return t.lastClick() != null;
            }
        }.f, .{&legacy}, 1000);
        if (!clicked) return report.fail("dpi-unaware", "no WM_LBUTTONDOWN within 1 s", .{});
        const c = legacy.lastClick().?;
        // Logical pixel expected under the mapped physical point.
        const ex = @as(f64, @floatFromInt(p[0] - origin.x)) / k;
        const ey = @as(f64, @floatFromInt(p[1] - origin.y)) / k;
        worst = @max(worst, @max(@abs(@as(f64, @floatFromInt(c[0])) - ex), @abs(@as(f64, @floatFromInt(c[1])) - ey)));
    }
    if (worst <= 1.0) report.ok("dpi-unaware", "DPI-unaware window at {d} dpi: worst error {d:.2} logical px", .{ dpi, worst }) else report.fail("dpi-unaware", "DPI-unaware window at {d} dpi: click {d:.2} logical px away", .{ dpi, worst });
}

/// Pixel of the server's last reduced screenshot at physical point (x, y).
fn shotPixel(server: *Server, m: display.Mapping, x: i32, y: i32) [4]u8 {
    const s = m.toScreenshot(x, y);
    const i = (@as(usize, @intCast(s[1])) * m.width + @as(usize, @intCast(s[0]))) * 4;
    return server.session.reducer.out[i..][0..4].*;
}

fn black(px: [4]u8) bool {
    return px[0] == 0 and px[1] == 0 and px[2] == 0;
}

/// Share of black pixels over `r` (physical), sampled every 4 pixels.
fn blackShare(server: *Server, m: display.Mapping, r: w.RECT) f64 {
    var total: u32 = 0;
    var dark: u32 = 0;
    var y = r.top;
    while (y < r.bottom) : (y += 4) {
        var x = r.left;
        while (x < r.right) : (x += 4) {
            total += 1;
            dark += @intFromBool(black(shotPixel(server, m, x, y)));
        }
    }
    return if (total == 0) 0 else @as(f64, @floatFromInt(dark)) / @as(f64, @floatFromInt(total));
}

fn injectKeys(vks: []const u16, up: bool) void {
    var buf: [8]w.INPUT = undefined;
    for (vks, 0..) |vk, i| buf[i] = .{ .type = w.INPUT_KEYBOARD, .Anonymous = .{ .ki = .{ .wVk = vk, .wScan = 0, .dwFlags = if (up) w.KEYEVENTF_KEYUP else 0, .time = 0, .dwExtraInfo = 0 } } };
    _ = w.SendInput(@intCast(vks.len), &buf, @sizeOf(w.INPUT));
}

/// EP-004 against the test window: policy resolution cost, `deny`
/// blackout and hiding, password field masking, and the kill switch with
/// real low-level hooks (physical events are fed to the hook logic on its
/// thread; injected ones go through Windows).
fn securityChecks(report: *Report, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, backend: *Windows, tw: *TestWindow) !void {
    const policy = @import("../../core/policy.zig");
    const control = @import("../../core/control.zig");
    _ = w.SetForegroundWindow(tw.window());
    w.Sleep(150);
    const handle = @intFromPtr(tw.window());
    const m = display.Mapping.of(0, backend.displays()[0].rect, display.default_long_side);
    var wr: w.RECT = undefined;
    _ = w.GetWindowRect(tw.window(), &wr);
    const cx = @divTrunc(wr.left + wr.right, 2);
    const cy = @divTrunc(wr.top + wr.bottom, 2);

    // policy-resolve: the target of an action costs < 0.2 ms once cached.
    {
        var server: Server = .init(gpa, io, backend, .{});
        defer server.deinit();
        var ctx: Server.ToolCtx = .{ .arena = arena, .io = io, .backend = backend, .cancel = &server.control.cancel, .timings = &server.timings, .session = &server.session };
        const t0 = qpcUs();
        const first = policy.requireAt(&ctx, .{ cx, cy }, .full);
        const first_us = qpcUs() - t0;
        var samples: [1000]u64 = undefined;
        for (&samples) |*s| {
            var a: i64 = 0;
            var b: i64 = 0;
            var f: i64 = 1;
            _ = w.QueryPerformanceCounter(&a);
            _ = policy.requireAt(&ctx, .{ cx, cy }, .full);
            _ = w.QueryPerformanceCounter(&b);
            _ = w.QueryPerformanceFrequency(&f);
            s.* = @intCast(@divTrunc((b - a) * 1_000_000_000, f));
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        const p95_ns = samples[949];
        const exe = if (ctx.target) |*t| t.exe() else "?";
        if (first == null and std.ascii.eqlIgnoreCase(exe, "neo-compute.exe") and p95_ns < 200_000)
            report.ok("policy-resolve", "test window resolves to {s} at full; first lookup {d} us, cached p95 {d:.1} us (budget 200 us)", .{ exe, first_us, @as(f64, @floatFromInt(p95_ns)) / 1000 })
        else
            report.fail("policy-resolve", "exe {s}, refused {}, first {d} us, cached p95 {d} ns", .{ exe, first != null, first_us, p95_ns });
    }

    // policy-deny: neo-compute.exe at deny is black in screenshots and
    // absent from window_list and ui_tree; a click on it is refused.
    {
        const pol = policy.parse(arena, "{\"apps\": {\"neo-compute.exe\": \"deny\"}}", "selftest");
        var server: Server = .init(gpa, io, backend, .{ .policy = &pol });
        defer server.deinit();
        var caller: Caller = .{ .server = &server, .arena = arena, .out = .init(gpa) };
        defer caller.out.deinit();
        const shot = try caller.call("screenshot", "{{\"display\":0}}", .{});
        const share = blackShare(&server, m, .{ .left = wr.left + 2, .top = wr.top + 2, .right = wr.right - 2, .bottom = wr.bottom - 2 });
        const list = try caller.call("window_list", "{{}}", .{});
        const listed = std.mem.indexOf(u8, list.text, try std.fmt.allocPrint(arena, "0x{x} ", .{handle})) != null;
        const tree = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{handle});
        const c = m.toScreenshot(cx, cy);
        const click = try caller.call("left_click", "{{\"coordinate\":[{d},{d}],\"observe\":\"none\"}}", .{ c[0], c[1] });
        const refused = tree.is_error and std.mem.indexOf(u8, tree.text, "mode deny") != null and click.is_error and std.mem.indexOf(u8, click.text, "neo-compute.exe est en mode deny") != null;
        if (!shot.is_error and share == 1 and !listed and refused)
            report.ok("policy-deny", "test window 100 % black in the screenshot, absent from window_list, ui_tree and left_click refused: `{s}`", .{click.text})
        else
            report.fail("policy-deny", "black share {d:.3}, listed {}, ui_tree `{s}`, click `{s}`", .{ share, listed, tree.text, click.text });
    }

    // password-mask: the ES_PASSWORD field is black before encoding, the
    // window around it is not.
    {
        var server: Server = .init(gpa, io, backend, .{});
        defer server.deinit();
        var caller: Caller = .{ .server = &server, .arena = arena, .out = .init(gpa) };
        defer caller.out.deinit();
        var pr: w.RECT = undefined;
        _ = w.GetWindowRect(tw.passwordWindow(), &pr);
        const t0 = qpcUs();
        const shot = try caller.call("screenshot", "{{\"display\":0}}", .{});
        const shot_us = qpcUs() - t0;
        const field = blackShare(&server, m, .{ .left = pr.left + 1, .top = pr.top + 1, .right = pr.right - 1, .bottom = pr.bottom - 1 });
        const around = blackShare(&server, m, .{ .left = pr.right + 8, .top = pr.top, .right = pr.right + 60, .bottom = pr.bottom });
        if (!shot.is_error and field == 1 and around < 0.5)
            report.ok("password-mask", "password field {d}x{d} 100 % black, beside it {d:.0} % black; screenshot {d} us", .{ pr.right - pr.left, pr.bottom - pr.top, around * 100, shot_us })
        else
            report.fail("password-mask", "field black share {d:.3}, beside {d:.3}, error {}", .{ field, around, shot.is_error });
    }

    // kill-switch: hooks on their own thread; a physical Escape during
    // hold_key cancels it, releases shift and pauses.
    var server: Server = .init(gpa, io, backend, .{});
    defer server.deinit();
    var caller: Caller = .{ .server = &server, .arena = arena, .out = .init(gpa) };
    defer caller.out.deinit();
    const rearm_combo: @import("../../core/keys.zig").Combo = .{ .mods = .{ .ctrl = true, .alt = true, .shift = true }, .key = .{ .char = 'r' } };
    // The control indicator runs with the kill switch (US-034), so the kill
    // checks below also time the hooks with it. Stopped after the kill
    // switch, whose thread notifies it.
    backend.startIndicator(&server.control, rearm_combo);
    defer backend.stopIndicator();
    backend.startKillSwitch(&server.control, rearm_combo);
    defer backend.stopKillSwitch();
    const ks = backend.kill orelse {
        report.fail("kill-switch", "low-level hooks could not be installed", .{});
        return;
    };
    const Later = struct {
        tripped_at: std.atomic.Value(u64) = .init(0),
        fn escape(self: *@This(), k: *@import("hooks.zig").KillSwitch) void {
            w.Sleep(300);
            self.tripped_at.store(qpcUs(), .release);
            k.simulateKey(w.VK_ESCAPE, true);
            k.simulateKey(w.VK_ESCAPE, false);
        }
        fn move(self: *@This(), k: *@import("hooks.zig").KillSwitch) void {
            w.Sleep(300);
            self.tripped_at.store(qpcUs(), .release);
            k.simulateMove(12, 0);
        }
    };
    {
        var later: Later = .{};
        const th = try std.Thread.spawn(.{}, Later.escape, .{ &later, ks });
        const r = try caller.call("hold_key", "{{\"text\":\"shift\",\"duration\":5,\"observe\":\"none\"}}", .{});
        const end = qpcUs();
        th.join();
        const cancel_ms = (end - later.tripped_at.load(.acquire)) / 1000;
        const released = w.GetAsyncKeyState(w.VK_LSHIFT) >= 0;
        if (r.is_error and std.mem.eql(u8, r.text, control.paused_message) and cancel_ms < 100 and released and server.control.isPaused())
            report.ok("kill-escape", "physical Escape during hold_key: cancelled in {d} ms, shift released, `{s}`", .{ cancel_ms, r.text })
        else
            report.fail("kill-escape", "after {d} ms: error {} released {} paused {} `{s}`", .{ cancel_ms, r.is_error, released, server.control.isPaused(), r.text });
    }
    {
        const c = m.toScreenshot(cx, cy);
        const click = try caller.call("left_click", "{{\"coordinate\":[{d},{d}],\"observe\":\"none\"}}", .{ c[0], c[1] });
        const shot = try caller.call("screenshot", "{{\"display\":0}}", .{});
        // An injected re-arm shortcut (any SendInput caller) is ignored.
        const combo = [_]u16{ w.VK_LCONTROL, w.VK_LMENU, w.VK_LSHIFT, 'R' };
        injectKeys(&combo, false);
        injectKeys(&combo, true);
        w.Sleep(150);
        const still = server.control.isPaused();
        // The physical shortcut re-arms.
        for (combo) |vk| ks.simulateKey(if (vk == 'R') 'R' else vk, true);
        for (combo) |vk| ks.simulateKey(vk, false);
        w.Sleep(100);
        const rearmed = !server.control.isPaused();
        if (click.is_error and std.mem.eql(u8, click.text, control.paused_message) and !shot.is_error and still and rearmed)
            report.ok("kill-pause", "paused: left_click refused, screenshot served; injected Ctrl+Alt+Shift+R ignored, physical one re-arms", .{})
        else
            report.fail("kill-pause", "click `{s}`, screenshot error {}, paused after injected re-arm {}, re-armed {}", .{ click.text, shot.is_error, still, rearmed });
    }
    {
        // An injected Escape (key Escape) during an action never trips.
        const r = try caller.call("key", "{{\"text\":\"Escape\",\"observe\":\"none\"}}", .{});
        w.Sleep(100);
        var later: Later = .{};
        const th = try std.Thread.spawn(.{}, Later.move, .{ &later, ks });
        const moved = try caller.call("hold_key", "{{\"text\":\"shift\",\"duration\":5,\"observe\":\"none\"}}", .{});
        const end = qpcUs();
        th.join();
        const cancel_ms = (end - later.tripped_at.load(.acquire)) / 1000;
        const ok_key = !r.is_error and ks.trips.load(.acquire) == 2;
        _ = server.control.rearm();
        const proc_us = @as(f64, @floatFromInt(ks.max_proc_ns.load(.acquire))) / 1000;
        if (ok_key and moved.is_error and std.mem.eql(u8, moved.text, control.paused_message) and cancel_ms < 100 and proc_us < 1000)
            report.ok("kill-mouse", "injected Escape ignored; physical 12 px move cancelled hold_key in {d} ms; slowest hook call {d:.1} us (budget 1000 us)", .{ cancel_ms, proc_us })
        else
            report.fail("kill-mouse", "key Escape error {} trips {d}; move: `{s}` after {d} ms; slowest hook {d:.1} us", .{ r.is_error, ks.trips.load(.acquire), moved.text, cancel_ms, proc_us });
    }
    {
        // Hooks removed behind our back (LowLevelHooksTimeout) are noticed
        // at the next input and reinstalled.
        const before = ks.reinstalls.load(.acquire);
        ks.simulateRemoval();
        w.Sleep(300);
        // A 1 px move and back: a null move is no input at all.
        var nudge = [_]w.INPUT{
            .{ .type = w.INPUT_MOUSE, .Anonymous = .{ .mi = .{ .dx = 1, .dy = 0, .mouseData = 0, .dwFlags = w.MOUSEEVENTF_MOVE, .time = 0, .dwExtraInfo = 0 } } },
            .{ .type = w.INPUT_MOUSE, .Anonymous = .{ .mi = .{ .dx = -1, .dy = 0, .mouseData = 0, .dwFlags = w.MOUSEEVENTF_MOVE, .time = 0, .dwExtraInfo = 0 } } },
        };
        _ = w.SendInput(2, &nudge, @sizeOf(w.INPUT));
        const t0 = qpcUs();
        while (ks.reinstalls.load(.acquire) == before and qpcUs() - t0 < 3_000_000) w.Sleep(20);
        const after = ks.reinstalls.load(.acquire);
        const seen_before = ks.last_event_tick.load(.acquire);
        w.Sleep(20);
        _ = w.SendInput(2, &nudge, @sizeOf(w.INPUT));
        w.Sleep(100);
        const live = ks.last_event_tick.load(.acquire) != seen_before;
        if (after > before and live)
            report.ok("hook-reinstall", "removed hooks reinstalled {d} ms after the missed input, and see input again", .{(qpcUs() - t0) / 1000})
        else
            report.fail("hook-reinstall", "reinstalls {d} -> {d}, hooks live {}", .{ before, after, live });
    }
    indicatorChecks(report, gpa, arena, &caller, &server, backend, ks, tw, rearm_combo) catch |err| report.fail("indicator", "{t}", .{err});
}

const IndicatorLook = @import("../../core/indicator.zig").Look;
const Indicator = @import("indicator.zig").Indicator;

fn waitLook(ind: *const Indicator, look: IndicatorLook, timeout_ms: u32) ?u64 {
    const t0 = qpcUs();
    while (qpcUs() - t0 < @as(u64, timeout_ms) * 1000) {
        if (ind.current() == look) return (qpcUs() - t0) / 1000;
        w.Sleep(5);
    }
    return null;
}

fn allVisible(hwnds: []const w.HWND, visible: bool) bool {
    for (hwnds) |h| if ((w.IsWindowVisible(h) != 0) != visible) return false;
    return hwnds.len > 0;
}

/// Points the indicator covers on every display: the middle of the left
/// strip and the middle of the label (`geometry` order: 5 acting rects,
/// then the paused label, per display).
fn indicatorPoints(ind: *Indicator, out: *[2 * display.max_displays][2]i32) [][2]i32 {
    var buf: [display.max_displays * 6]display.Rect = undefined;
    const g = ind.geometry(&buf);
    var n: usize = 0;
    var i: usize = 0;
    while (i + 6 <= g.len) : (i += 6) {
        const left = g[i + 2];
        const label = g[i + 4];
        out[n] = .{ left.x + 1, left.y + @divTrunc(left.h, 2) };
        out[n + 1] = .{ label.x + @divTrunc(label.w, 2), label.y + @divTrunc(label.h, 2) - 2 };
        n += 2;
    }
    return out[0..n];
}

/// Share of `points` in the indicator's amber in each display's frame,
/// for `backend`'s captures (DXGI, or GDI when forced).
fn amberAt(backend: *Windows, arena: std.mem.Allocator, points: []const [2]i32) !usize {
    const displays = backend.displays();
    var hits: usize = 0;
    for (displays, 0..) |d, di| {
        const f = switch (backend.capture(di, arena)) {
            .frame => |f| f,
            .failed => |msg| {
                std.debug.print("selftest: capture of display {d} failed: {s}\n", .{ di, msg });
                return error.CaptureFailed;
            },
        };
        for (points) |p| {
            if (!d.rect.contains(p[0], p[1])) continue;
            const i = @as(usize, @intCast(p[1] - d.rect.y)) * f.stride + @as(usize, @intCast(p[0] - d.rect.x)) * 4;
            if (isColor(f.pixels[i..][0..4].*, @import("indicator.zig").acting_fill)) hits += 1;
        }
    }
    return hits;
}

/// US-034: the control indicator of the selftest's server, the kill switch
/// running. Shown during an action and 1 s after, paused until the re-arm,
/// drawn but absent from every capture, its own dirty rects dropped,
/// absent from window_list, point resolution, the policy and ui_tree, a
/// state change cheap for the caller; a failure to start leaves tools
/// working.
fn indicatorChecks(report: *Report, gpa: std.mem.Allocator, arena: std.mem.Allocator, caller: *Caller, server: *Server, backend: *Windows, ks: *@import("hooks.zig").KillSwitch, tw: *TestWindow, rearm: @import("../../core/keys.zig").Combo) !void {
    const core_ind = @import("../../core/indicator.zig");
    const policy = @import("../../core/policy.zig");
    const ind = backend.indicator orelse return report.fail("indicator-start", "the indicator did not start (see stderr)", .{});
    if (!ind.ready(2000)) return report.fail("indicator-start", "its windows were not built (see stderr)", .{});
    var hbuf: [display.max_displays * 5]w.HWND = undefined;
    const hwnds = ind.windows(&hbuf);
    const displays = backend.displays();
    _ = w.SetForegroundWindow(tw.window());
    var wr: w.RECT = undefined;
    _ = w.GetWindowRect(tw.window(), &wr);
    const m = display.Mapping.of(0, displays[0].rect, display.default_long_side);
    const center = m.toScreenshot(@divTrunc(wr.left + wr.right, 2), @divTrunc(wr.top + wr.bottom, 2));

    // indicator-start: five excluded windows per display (four strips and
    // the label), hidden at rest.
    _ = waitLook(ind, .hidden, 2000);
    {
        var excluded: usize = 0;
        for (hwnds) |h| {
            var a: u32 = 0;
            if (w.GetWindowDisplayAffinity(h, &a) != 0 and a == w.WDA_EXCLUDEFROMCAPTURE) excluded += 1;
        }
        if (hwnds.len == 5 * displays.len and excluded == hwnds.len and allVisible(hwnds, false))
            report.ok("indicator-start", "{d} layered windows, five per display, WDA_EXCLUDEFROMCAPTURE, hidden at rest", .{hwnds.len})
        else
            report.fail("indicator-start", "{d} window(s) for {d} display(s), {d} excluded, hidden {}", .{ hwnds.len, displays.len, excluded, allVisible(hwnds, false) });
    }

    // indicator-acting: shown during hold_key, still 1 s after, then gone.
    {
        const Sample = struct {
            look: IndicatorLook = .hidden,
            visible: bool = false,
            fn run(self: *@This(), i: *const Indicator, hs: []const w.HWND) void {
                w.Sleep(300);
                self.look = i.current();
                self.visible = allVisible(hs, true);
            }
        };
        var sample: Sample = .{};
        const th = try std.Thread.spawn(.{}, Sample.run, .{ &sample, ind, hwnds });
        const r = try caller.call("hold_key", "{{\"text\":\"shift\",\"duration\":0.8,\"observe\":\"none\"}}", .{});
        th.join();
        const end = qpcUs();
        const after = ind.current();
        const lingered = allVisible(hwnds, true);
        const gone = waitLook(ind, .hidden, 2500);
        const gone_ms = (qpcUs() - end) / 1000;
        if (!r.is_error and sample.look == .acting and sample.visible and after == .acting and lingered and gone != null and gone_ms >= 900 and gone_ms <= 1300 and allVisible(hwnds, false))
            report.ok("indicator-acting", "`{s}` on every display during hold_key, still shown after it, hidden {d} ms after its end", .{ core_ind.acting_label, gone_ms })
        else
            report.fail("indicator-acting", "during: {t} visible {}; after: {t} visible {}; hidden after {d} ms ({any}); `{s}`", .{ sample.look, sample.visible, after, lingered, gone_ms, gone, r.text });
    }

    // indicator-settle: a click that changes nothing settles as fast with
    // the indicator appearing (its dirty rects dropped) as without it
    // (observer detached, the indicator stays hidden): medians of three, in
    // the same run. An echo left in settling cost about 15 ms under DXGI.
    {
        const Click = struct {
            fn settledMs(c: *Caller, at: [2]i32) !u32 {
                const r = try c.call("left_click", "{{\"coordinate\":[{d},{d}]}}", .{ at[0], at[1] });
                const line = std.mem.sliceTo(r.text, '\n');
                const i = std.mem.indexOf(u8, line, "settled in ") orelse return error.NotSettled;
                return std.fmt.parseInt(u32, std.mem.sliceTo(line[i + "settled in ".len ..], ' '), 10);
            }
        };
        var with: [3]u32 = undefined;
        var without: [3]u32 = undefined;
        for (&with) |*ms| {
            _ = waitLook(ind, .hidden, 2500);
            ms.* = try Click.settledMs(caller, center);
        }
        _ = waitLook(ind, .hidden, 2500);
        server.control.observe(null);
        for (&without) |*ms| ms.* = try Click.settledMs(caller, center);
        server.control.observe(&ind.observer);
        const stayed_hidden = ind.current() == .hidden;
        std.mem.sort(u32, &with, {}, std.sort.asc(u32));
        std.mem.sort(u32, &without, {}, std.sort.asc(u32));
        // GDI settling compares fingerprints 50 ms apart: its own noise is
        // tens of ms, and the excluded indicator is not in its captures.
        const tolerance: u32 = if (Windows.capture_mode == .gdi) 50 else 8;
        if (stayed_hidden and with[1] <= without[1] + tolerance)
            report.ok("indicator-settle", "left_click on the still test window settles in {d} ms median with the indicator appearing, {d} ms without it (tolerance {d} ms)", .{ with[1], without[1], tolerance })
        else
            report.fail("indicator-settle", "medians {d} ms with the indicator, {d} ms without (tolerance {d} ms), hidden while detached {}", .{ with[1], without[1], tolerance, stayed_hidden });
        _ = waitLook(ind, .hidden, 2500);
    }

    // indicator-capture: shown, it is in no DXGI or GDI frame; let into the
    // capture, the same points are its amber (drawn on every display).
    {
        var pbuf: [2 * display.max_displays][2]i32 = undefined;
        const points = indicatorPoints(ind, &pbuf);
        var gb: Windows = .init(gpa);
        defer gb.deinit();
        gb.force_gdi = true;
        server.control.beginAction();
        _ = waitLook(ind, .acting, 500);
        w.Sleep(100);
        const dxgi_hits: ?usize = if (Windows.capture_mode == .gdi) null else try amberAt(backend, arena, points);
        const gdi_hits = try amberAt(&gb, arena, points);
        const exposed = ind.excludeFromCapture(false);
        w.Sleep(150);
        const drawn = try amberAt(&gb, arena, points);
        const restored = ind.excludeFromCapture(true);
        _ = server.control.endAction();
        w.Sleep(100);
        if ((dxgi_hits orelse 0) == 0 and gdi_hits == 0 and exposed and restored and drawn == points.len)
            report.ok("indicator-capture", "{d} frame and label points: in no DXGI frame{s} nor GDI frame; without the exclusion, {d}/{d} are its amber", .{ points.len, if (dxgi_hits == null) " (not measured, --capture gdi)" else "", drawn, points.len })
        else
            report.fail("indicator-capture", "amber points: DXGI {any}, GDI {d}, drawn {d}/{d} (exposed {}, restored {})", .{ dxgi_hits, gdi_hits, drawn, points.len, exposed, restored });
        _ = waitLook(ind, .hidden, 2500);
    }

    // indicator-echo: the dirty rects of its appearance and of its
    // disappearance, looked at seconds later, are dropped as its own.
    if (Windows.capture_mode == .gdi) report.skip("indicator-echo", "{s}", .{gdi_skip}) else {
        var gbuf: [display.max_displays * 6]display.Rect = undefined;
        const g = ind.geometry(&gbuf);
        const Count = struct {
            var seen: [16]display.Rect = undefined;
            var seen_len: usize = 0;
            fn left(b: *Windows, a: std.mem.Allocator, n: usize, geo: []const display.Rect) usize {
                var count: usize = 0;
                for (0..n) |di| switch (b.changes(di, a, null)) {
                    .frame => |f| for (f.dirty) |d| {
                        if (core_ind.covered(geo, d)) count += 1;
                        var touches = false;
                        for (geo) |r| if (r.intersects(d)) {
                            touches = true;
                        };
                        if (touches and seen_len < seen.len) {
                            seen[seen_len] = d;
                            seen_len += 1;
                        }
                    },
                    .failed => {},
                };
                return count;
            }
        };
        for (0..3) |_| {
            _ = Count.left(backend, arena, displays.len, g);
            w.Sleep(30);
        }
        const dropped0 = ind.dropped.load(.acquire);
        server.control.beginAction();
        var shown_left: usize = 0;
        for (0..20) |_| {
            shown_left += Count.left(backend, arena, displays.len, g);
            w.Sleep(10);
        }
        _ = server.control.endAction();
        const dropped_shown = ind.dropped.load(.acquire) - dropped0;
        // No look while it lingers and hides: the next one, 1.5 s later,
        // gets the disappearance's dirty rects.
        w.Sleep(1500);
        const hidden_left = Count.left(backend, arena, displays.len, g);
        const dropped_hidden = ind.dropped.load(.acquire) - dropped0 - dropped_shown;
        if (shown_left == 0 and hidden_left == 0 and dropped_shown > 0 and dropped_hidden > 0 and ind.current() == .hidden)
            report.ok("indicator-echo", "its own dirty rects dropped: {d} when it appears, {d} when it hides (looked at 1.5 s later); none left over its frame or label", .{ dropped_shown, dropped_hidden })
        else
            report.fail("indicator-echo", "dropped {d} shown, {d} hidden; left over it {d} shown, {d} hidden; now {t}; dirty rects touching it {any}; geometry {any}", .{ dropped_shown, dropped_hidden, shown_left, hidden_left, ind.current(), Count.seen[0..Count.seen_len], g });
    }

    // indicator-paused: a physical Escape during hold_key turns the label
    // to the pause, which stays until the physical re-arm.
    var stamp_hidden: u64 = 0;
    var stamp_shown: u64 = 0;
    {
        const Escape = struct {
            fn run(k: *@import("hooks.zig").KillSwitch) void {
                w.Sleep(300);
                k.simulateKey(w.VK_ESCAPE, true);
                k.simulateKey(w.VK_ESCAPE, false);
            }
        };
        stamp_hidden = backend.topWindowStamp();
        const th = try std.Thread.spawn(.{}, Escape.run, .{ks});
        const r = try caller.call("hold_key", "{{\"text\":\"shift\",\"duration\":5,\"observe\":\"none\"}}", .{});
        th.join();
        const first = ind.current();
        stamp_shown = backend.topWindowStamp();
        w.Sleep(1500);
        const later = ind.current();
        const visible = allVisible(hwnds, true);
        var lbuf: [96]u8 = undefined;
        const label = core_ind.pausedLabel(&lbuf, rearm);
        if (r.is_error and first == .paused and later == .paused and visible)
            report.ok("indicator-paused", "`{s}` from the trip, still shown 1.5 s after the cancelled action", .{label})
        else
            report.fail("indicator-paused", "after the trip {t}, 1.5 s later {t}, visible {}; `{s}`", .{ first, later, visible, r.text });
    }

    // indicator-absent (while paused, so shown): not in window_list, not
    // the window under a point of it (policy target), not a
    // ui_tree root of this process's test window, no new window stamp.
    {
        const list = try caller.call("window_list", "{{\"include_hidden\":true}}", .{});
        var listed = false;
        for (hwnds) |h| {
            if (std.mem.indexOf(u8, list.text, try std.fmt.allocPrint(arena, "0x{x} ", .{@intFromPtr(h)})) != null) listed = true;
        }
        var pbuf: [2 * display.max_displays][2]i32 = undefined;
        const points = indicatorPoints(ind, &pbuf);
        var under = false;
        var ctx: Server.ToolCtx = .{ .arena = arena, .io = caller.server.io, .backend = backend, .cancel = &server.control.cancel, .timings = &server.timings, .session = &server.session };
        for (points) |p| {
            if (backend.windowAt(p)) |ref| for (hwnds) |h| if (ref.handle == @intFromPtr(h)) {
                under = true;
            };
            ctx.target = null;
            _ = policy.requireAt(&ctx, p, .observe);
            if (ctx.target) |t| for (hwnds) |h| if (t.handle == @intFromPtr(h)) {
                under = true;
            };
        }
        var rooted = false;
        for (backend.uiRoots(arena, @intFromPtr(tw.window()))) |root| for (hwnds) |h| if (root.handle == @intFromPtr(h)) {
            rooted = true;
        };
        const tree = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{@intFromPtr(tw.window())});
        for (hwnds) |h| {
            if (std.mem.indexOf(u8, tree.text, try std.fmt.allocPrint(arena, "0x{x}", .{@intFromPtr(h)})) != null) rooted = true;
        }
        const same_stamp = stamp_shown == stamp_hidden;
        if (allVisible(hwnds, true) and !listed and !under and !rooted and same_stamp)
            report.ok("indicator-absent", "shown, yet absent from window_list (include_hidden), the window and policy target under {d} of its points, ui_tree roots, and the window stamp", .{points.len})
        else
            report.fail("indicator-absent", "visible {}, listed {}, under a point {}, ui_tree root {}, same stamp {}", .{ allVisible(hwnds, true), listed, under, rooted, same_stamp });
    }

    // The physical re-arm hides it at once.
    {
        const combo = [_]u16{ w.VK_LCONTROL, w.VK_LMENU, w.VK_LSHIFT, 'R' };
        const t0 = qpcUs();
        for (combo) |vk| ks.simulateKey(vk, true);
        for (combo) |vk| ks.simulateKey(vk, false);
        const gone = waitLook(ind, .hidden, 500);
        const gone_ms = (qpcUs() - t0) / 1000;
        if (gone != null and !server.control.isPaused() and gone_ms < 200) report.ok("indicator-rearm", "hidden {d} ms after the physical re-arm", .{gone_ms}) else report.fail("indicator-rearm", "paused {}, look {t} after {d} ms", .{ server.control.isPaused(), ind.current(), gone_ms });
    }

    // indicator-cost: every state change (an action's start and end, the
    // kill switch's trip and re-arm, which run on the hook thread) costs
    // the calling thread one posted message (budget 2 ms); the hooks' own
    // budget is kill-mouse's.
    {
        var samples: [400]u64 = undefined;
        var k: usize = 0;
        for (0..100) |_| {
            const c = &server.control;
            var t: [5]u64 = undefined;
            t[0] = qpcUs();
            c.beginAction();
            t[1] = qpcUs();
            _ = c.trip();
            t[2] = qpcUs();
            _ = c.endAction();
            t[3] = qpcUs();
            _ = c.rearm();
            t[4] = qpcUs();
            for (0..4) |j| samples[k + j] = t[j + 1] - t[j];
            k += 4;
        }
        server.control.cancel.store(false, .release);
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        const p95 = samples[379];
        const worst = samples[399];
        const gone = waitLook(ind, .hidden, 2500);
        const hook_us = @as(f64, @floatFromInt(ks.max_proc_ns.load(.acquire))) / 1000;
        if (worst < 2000 and gone != null and hook_us < 1000)
            report.ok("indicator-cost", "400 state changes (begin, trip, end, re-arm): p95 {d} us, slowest {d} us for the caller (budget 2000 us); slowest hook call so far {d:.1} us (budget 1000 us)", .{ p95, worst, hook_us })
        else
            report.fail("indicator-cost", "state change p95 {d} us, slowest {d} us; hidden after {any}; slowest hook {d:.1} us", .{ p95, worst, gone, hook_us });
    }

    // indicator-brief: an action that begins and ends before the
    // indicator's thread wakes up is never seen busy, yet still shows the
    // indicator and its 1 s linger.
    {
        _ = waitLook(ind, .hidden, 2500);
        server.control.beginAction();
        _ = server.control.endAction();
        const end = qpcUs();
        const shown = waitLook(ind, .acting, 200);
        const gone = waitLook(ind, .hidden, 2500);
        const gone_ms = (qpcUs() - end) / 1000;
        if (shown != null and gone != null and gone_ms >= 900 and gone_ms <= 1300)
            report.ok("indicator-brief", "an action ended before the indicator saw it: shown after {d} ms, hidden {d} ms after its end", .{ shown.?, gone_ms })
        else
            report.fail("indicator-brief", "shown {any}, hidden after {d} ms ({any})", .{ shown, gone_ms, gone });
    }

    // indicator-rebuild: a display change during the linger rebuilds the
    // windows, which still hide about 1 s later instead of staying shown.
    {
        server.control.beginAction();
        _ = waitLook(ind, .acting, 500);
        _ = server.control.endAction();
        w.Sleep(200);
        var before: [display.max_displays * 5]w.HWND = undefined;
        const old = ind.windows(&before);
        const t0 = qpcUs();
        _ = w.SendMessageW(old[0], w.WM_DISPLAYCHANGE, 0, 0);
        var rebuilt = false;
        var after: [display.max_displays * 5]w.HWND = undefined;
        var n: usize = 0;
        while (qpcUs() - t0 < 1_000_000 and !rebuilt) : (w.Sleep(5)) {
            const now = ind.windows(&after);
            n = now.len;
            rebuilt = n == 5 * displays.len and now[0] != old[0];
        }
        // The windows exist before the look is applied to them.
        const look: IndicatorLook = if (waitLook(ind, .acting, 200) != null) .acting else ind.current();
        const gone = waitLook(ind, .hidden, 2500);
        const gone_ms = (qpcUs() - t0) / 1000;
        if (rebuilt and look == .acting and gone != null and gone_ms >= 800 and gone_ms <= 1400)
            report.ok("indicator-rebuild", "display change during the linger: {d} windows rebuilt, still acting, hidden {d} ms later", .{ n, gone_ms })
        else
            report.fail("indicator-rebuild", "rebuilt {} ({d} windows), look {t}, hidden after {d} ms ({any})", .{ rebuilt, n, look, gone_ms, gone });
    }

    // indicator-refused: windows that cannot be built are logged on stderr
    // by the indicator's thread, and the tools keep working, state changes
    // included.
    {
        backend.stopIndicator();
        backend.refuse_indicator = true;
        backend.startIndicator(&server.control, rearm);
        backend.refuse_indicator = false;
        const refused = backend.indicator orelse return report.fail("indicator-refused", "the indicator thread did not start", .{});
        const built = refused.ready(2000);
        var rbuf: [display.max_displays * 5]w.HWND = undefined;
        const left = refused.windows(&rbuf).len;
        const r = try caller.call("left_click", "{{\"coordinate\":[{d},{d}],\"observe\":\"none\"}}", .{ center[0], center[1] });
        if (!built and refused.failed.load(.acquire) and left == 0 and !r.is_error) report.ok("indicator-refused", "windows refused: logged, none left, left_click `{s}`", .{r.text}) else report.fail("indicator-refused", "built {}, windows {d}, left_click `{s}`", .{ built, left, r.text });
    }
}

/// no-indicator: the shipped server builds its indicator windows (five per
/// display, hidden) once started, and none with `--no-indicator` (looked
/// for 500 ms). Skipped when another neo-compute controls the desktop:
/// a second instance never shows the indicator.
fn noIndicatorCheck(io: std.Io, env: *const std.process.Environ.Map, report: *Report, arena: std.mem.Allocator, displays: usize) void {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\neo-compute-desktop");
    const mutex = w.CreateMutexW(null, 0, name);
    const taken = mutex != null and w.GetLastError() == w.ERROR_ALREADY_EXISTS;
    if (mutex != null) _ = w.CloseHandle(mutex);
    if (taken) return report.skip("no-indicator", "another neo-compute controls this desktop: its second instance never shows the indicator", .{});
    const with = indicatorWindowsOf(io, env, arena, false) catch |err| return report.fail("no-indicator", "server without the flag: {t}", .{err});
    const without = indicatorWindowsOf(io, env, arena, true) catch |err| return report.fail("no-indicator", "server with --no-indicator: {t}", .{err});
    if (with == 5 * displays and without == 0) report.ok("no-indicator", "shipped server: {d} indicator windows, five per display; with --no-indicator: none", .{with}) else report.fail("no-indicator", "{d} window(s) without the flag (expected {d}), {d} with --no-indicator", .{ with, 5 * displays, without });
}

/// Indicator windows of a `neo-compute [--no-indicator]` server once it
/// answered `initialize`. Its policy and audit log go to a scratch
/// directory.
fn indicatorWindowsOf(io: std.Io, env: *const std.process.Environ.Map, arena: std.mem.Allocator, flag: bool) !usize {
    var path_w: [1024:0]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &path_w, path_w.len);
    const path = try arena.alloc(u8, n * 3);
    const exe = path[0..std.unicode.wtf16LeToWtf8(path, path_w[0..n])];
    const temp = env.get("TEMP") orelse return error.NoTempDirectory;
    const home = try std.fs.path.join(arena, &.{ temp, "neo-compute-selftest-indicator" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var server_env = try env.clone(arena);
    try server_env.put("APPDATA", home);
    try server_env.put("LOCALAPPDATA", home);
    const argv: []const []const u8 = if (flag) &.{ exe, "--no-indicator" } else &.{exe};
    var server = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .environ_map = &server_env });
    defer server.kill(io);
    var wbuf: [1024]u8 = undefined;
    var sw = server.stdin.?.writerStreaming(io, &wbuf);
    var rbuf: [16 * 1024]u8 = undefined;
    var sr = server.stdout.?.readerStreaming(io, &rbuf);
    _ = try rpc(&sw, &sr, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"selftest\",\"version\":\"0\"}}}\n", true);
    const Find = struct {
        pid: u32,
        count: usize = 0,
        fn callback(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
            const self: *@This() = @ptrFromInt(@as(usize, @bitCast(lparam)));
            var pid: u32 = 0;
            _ = w.GetWindowThreadProcessId(hwnd, &pid);
            if (pid != self.pid) return 1;
            var class: [64:0]u16 = undefined;
            const len = w.GetClassNameW(hwnd, &class, class.len);
            if (len > 0 and std.mem.eql(u16, class[0..@intCast(len)], std.unicode.utf8ToUtf16LeStringLiteral(@import("indicator.zig").class_name))) self.count += 1;
            return 1;
        }
    };
    // Built in the background: wait up to 2 s for them.
    var find: Find = .{ .pid = w.GetProcessId(@ptrCast(server.id.?)) };
    var waited: u32 = 0;
    while (true) : (waited += 20) {
        find.count = 0;
        _ = w.EnumWindows(Find.callback, @bitCast(@intFromPtr(&find)));
        if (find.count > 0 or waited >= 2000 or flag and waited >= 500) break;
        w.Sleep(20);
    }
    // The first windows exist: let the build finish, then count them all.
    if (find.count > 0) {
        w.Sleep(300);
        find.count = 0;
        _ = w.EnumWindows(Find.callback, @bitCast(@intFromPtr(&find)));
    }
    return find.count;
}

/// ui-find-wait-cpu (US-030): a 5 s ui_find wait without change on a still
/// window over `rect` costs the server under 5 % of a core. Both sides are
/// processes of their own, as in real use: the window (`selftest-still`)
/// and a `neo-compute --capture <capture>` server driven over stdio, whose
/// CPU alone is counted, in cycles. Measured on this process instead, the
/// test window's UIA provider, the UIA worker and the 15.6 ms ticks of
/// GetProcessTimes made the same wait read 0.9 to 5.3 %. The server's
/// policy and audit log go to a scratch directory, not the user's.
fn stillWaitCheck(io: std.Io, env: *const std.process.Environ.Map, report: *Report, arena: std.mem.Allocator, name: []const u8, rect: display.Rect, capture: []const u8) void {
    const measured = cpuOfWait(io, env, arena, rect, capture) catch |err| return report.fail(name, "{t}", .{err});
    const m = switch (measured) {
        .ok => |m| m,
        .failed => |why| return report.fail(name, "{s}", .{why}),
    };
    const percent = @as(f64, @floatFromInt(m.cpu_us)) * 100 / @as(f64, @floatFromInt(@max(m.wall_us, 1)));
    const expected = "Aucun élément « neo-compute absent element » après 5000 ms : vérifie la requête ou augmente wait_ms";
    const answered = std.mem.indexOf(u8, m.response, "\"isError\":true") != null and std.mem.indexOf(u8, m.response, expected) != null;
    if (answered and m.placed and percent < 5)
        report.ok(name, "5 s wait without change on a {d}x{d} window, server --capture {s} in a process of its own: {d:.2} % of a core ({d} us CPU over {d} ms)", .{ rect.w, rect.h, capture, percent, m.cpu_us, m.wall_us / 1000 })
    else
        report.fail(name, "{d}x{d} window placed={}, --capture {s}: {d:.2} % of a core (budget 5 %), response `{s}`", .{ rect.w, rect.h, m.placed, capture, percent, m.response });
}

const Wait = union(enum) {
    ok: struct { cpu_us: u64, wall_us: u64, placed: bool, response: []const u8 },
    failed: []const u8,
};

fn rpc(wr: *std.Io.File.Writer, rd: *std.Io.File.Reader, line: []const u8, answer: bool) ![]const u8 {
    try wr.interface.writeAll(line);
    try wr.interface.flush();
    if (!answer) return "";
    return (try rd.interface.takeDelimiter('\n')) orelse error.NoResponse;
}

fn cpuOfWait(io: std.Io, env: *const std.process.Environ.Map, arena: std.mem.Allocator, rect: display.Rect, capture: []const u8) !Wait {
    var path_w: [1024:0]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &path_w, path_w.len);
    const path = try arena.alloc(u8, n * 3);
    const exe = path[0..std.unicode.wtf16LeToWtf8(path, path_w[0..n])];

    var rect_args: [4][16]u8 = undefined;
    var still_argv: [6][]const u8 = .{ exe, "selftest-still", "", "", "", "" };
    for ([_]i32{ rect.x, rect.y, rect.w, rect.h }, &rect_args, still_argv[2..]) |v, *buf, *arg| arg.* = try std.fmt.bufPrint(buf, "{d}", .{v});
    var still = try std.process.spawn(io, .{ .argv = &still_argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer still.kill(io);
    var hwnd: w.HWND = null;
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 20) {
        hwnd = w.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral(still_window.class_name), null);
        if (hwnd != null) break;
        w.Sleep(20);
    }
    if (hwnd == null) return .{ .failed = "no selftest-still window after 3 s" };
    w.Sleep(300);
    var r: w.RECT = undefined;
    _ = w.GetWindowRect(hwnd, &r);
    const placed = r.left == rect.x and r.top == rect.y and r.right - r.left == rect.w and r.bottom - r.top == rect.h;

    // The server's policy.json and audit.jsonl in a scratch directory.
    const temp = env.get("TEMP") orelse return .{ .failed = "TEMP is not set: no scratch directory for the server" };
    const home = try std.fs.path.join(arena, &.{ temp, "neo-compute-selftest-cpu" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var server_env = try env.clone(arena);
    try server_env.put("APPDATA", home);
    try server_env.put("LOCALAPPDATA", home);
    var server = try std.process.spawn(io, .{ .argv = &.{ exe, "--capture", capture }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .environ_map = &server_env });
    defer server.kill(io);
    var wbuf: [1024]u8 = undefined;
    var sw = server.stdin.?.writerStreaming(io, &wbuf);
    var rbuf: [16 * 1024]u8 = undefined;
    var sr = server.stdout.?.readerStreaming(io, &rbuf);
    _ = try rpc(&sw, &sr, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"selftest\",\"version\":\"0\"}}}\n", true);
    _ = try rpc(&sw, &sr, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n", false);
    const call = "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"ui_find\",\"arguments\":{{\"query\":\"neo-compute absent element\",\"window\":\"0x{x}\",\"wait_ms\":{d}}}}}}}\n";
    var line_buf: [256]u8 = undefined;
    // Not measured: the server's first UIA and capture setup.
    _ = try rpc(&sw, &sr, try std.fmt.bufPrint(&line_buf, call, .{ 2, @intFromPtr(hwnd), 800 }), true);

    const per_us = cyclesPerUs();
    var c0: u64 = 0;
    if (w.QueryProcessCycleTime(server.id.?, &c0) == 0) return .{ .failed = "QueryProcessCycleTime failed on the server process" };
    const t0 = qpcUs();
    const response = try arena.dupe(u8, try rpc(&sw, &sr, try std.fmt.bufPrint(&line_buf, call, .{ 3, @intFromPtr(hwnd), 5000 }), true));
    const wall = qpcUs() - t0;
    var c1: u64 = 0;
    if (w.QueryProcessCycleTime(server.id.?, &c1) == 0) return .{ .failed = "QueryProcessCycleTime failed on the server process" };
    return .{ .ok = .{ .cpu_us = @intFromFloat(@as(f64, @floatFromInt(c1 - c0)) / per_us), .wall_us = wall, .placed = placed, .response = response } };
}

/// Cycles per microsecond of the counter QueryProcessCycleTime reads,
/// against QueryPerformanceCounter over a 100 ms busy loop of this thread.
fn cyclesPerUs() f64 {
    var c0: u64 = 0;
    _ = w.QueryThreadCycleTime(w.GetCurrentThread(), &c0);
    const t0 = qpcUs();
    while (qpcUs() - t0 < 100_000) {}
    var c1: u64 = 0;
    _ = w.QueryThreadCycleTime(w.GetCurrentThread(), &c1);
    return @as(f64, @floatFromInt(c1 - c0)) / @as(f64, @floatFromInt(qpcUs() - t0));
}

/// ui-range-timeout (US-022): a slider whose provider, in a process of its
/// own (`selftest-stall`), answers the main read but stalls past the
/// provider timeout on its RangeValue value. The tree comes back partial,
/// with the slider and without its range.
fn rangeTimeoutCheck(io: std.Io, report: *Report, caller: *Caller, backend: *Windows, arena: std.mem.Allocator) void {
    const name = "ui-range-timeout";
    var path_w: [1024:0]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &path_w, path_w.len);
    const path = arena.alloc(u8, n * 3) catch return;
    const exe = path[0..std.unicode.wtf16LeToWtf8(path, path_w[0..n])];
    var child = std.process.spawn(io, .{ .argv = &.{ exe, "selftest-stall" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        report.fail(name, "cannot start {s} selftest-stall: {t}", .{ exe, err });
        return;
    };
    defer child.kill(io);
    var hwnd: w.HWND = null;
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 20) {
        hwnd = w.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral(stall_provider.class_name), null);
        if (hwnd != null) break;
        w.Sleep(20);
    }
    if (hwnd == null) return report.fail(name, "no stalled provider window after 3 s", .{});
    w.Sleep(100);
    const t0 = qpcUs();
    const tree = caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{@intFromPtr(hwnd)}) catch |err| return report.fail(name, "{t}", .{err});
    const ms = (qpcUs() - t0) / 1000;
    // Both trackbars come from the main read (one thumb each); only the
    // first keeps its range. The second, nameless and without a range, is
    // pruned from the output.
    var thumbs: usize = 0;
    var ranged: usize = 0;
    var line: []const u8 = "";
    var lines = std.mem.splitScalar(u8, tree.text, '\n');
    while (lines.next()) |l| {
        if (std.mem.indexOf(u8, l, " thumb ") != null) thumbs += 1;
        if (std.mem.indexOf(u8, l, " slider ") == null or std.mem.indexOf(u8, l, "[=") == null) continue;
        ranged += 1;
        line = l;
    }
    const partial = std.mem.startsWith(u8, tree.text, "{partial: timeout}");
    if (!tree.is_error and partial and thumbs == 2 and ranged == 1 and ms < 1000)
        report.ok(name, "second range round trip refused after the main read: tree in {d} ms, `{s}`, 1 of 2 sliders with `{s}`", .{ ms, std.mem.sliceTo(tree.text, '\n'), std.mem.trim(u8, line, " ") })
    else
        report.fail(name, "{d} ms, range round trip {d} us, partial={}, tree:\n{s}", .{ ms, backend.ui.lastExtrasNs() / 1000, partial, tree.text });
}

fn releaseCheck(io: std.Io, report: *Report, arena: std.mem.Allocator) void {
    var path_w: [1024:0]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &path_w, path_w.len);
    const path = arena.alloc(u8, n * 3) catch return;
    const exe = path[0..std.unicode.wtf16LeToWtf8(path, path_w[0..n])];
    var child = std.process.spawn(io, .{ .argv = &.{ exe, "serve" }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore }) catch |err| {
        report.fail("release", "cannot start {s}: {t}", .{ exe, err });
        return;
    };
    var wbuf: [1024]u8 = undefined;
    var wr = child.stdin.?.writerStreaming(io, &wbuf);
    wr.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"selftest\",\"version\":\"0\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"hold_key\",\"arguments\":{\"text\":\"shift\",\"duration\":30}}}\n") catch {};
    wr.interface.flush() catch {};
    const down = waitFor(struct {
        fn f() bool {
            return w.GetAsyncKeyState(w.VK_LSHIFT) < 0;
        }
    }.f, .{}, 2000);
    if (!down) {
        child.kill(io);
        report.fail("release", "hold_key shift never pressed the key", .{});
        return;
    }
    child.stdin.?.close(io);
    child.stdin = null;
    const t0 = qpcUs();
    const up = waitFor(struct {
        fn f() bool {
            return w.GetAsyncKeyState(w.VK_LSHIFT) >= 0;
        }
    }.f, .{}, 300);
    const release_us = qpcUs() - t0;
    const term = child.wait(io) catch {
        report.fail("release", "wait failed", .{});
        return;
    };
    const exit_us = qpcUs() - t0;
    const exited_ok = term == .exited and term.exited == 0;
    if (up and release_us < 50_000 and exited_ok) report.ok("release", "shift released {d} us after stdin EOF, exit code 0 after {d} us", .{ release_us, exit_us }) else report.fail("release", "released: {} after {d} us, exit {any} after {d} us", .{ up, release_us, term, exit_us });
}
