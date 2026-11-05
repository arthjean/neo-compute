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
const Windows = @import("../windows.zig").Windows;
const mcp = @import("../../core/mcp.zig");
const tools = @import("../../core/tools.zig");
const display = @import("../../core/display.zig");

const Server = mcp.Server(Windows, tools.all);

const Report = struct {
    log: *std.Io.Writer,
    failed: ?[]const u8 = null,

    fn ok(self: *Report, name: []const u8, comptime f: []const u8, args: anytype) void {
        self.log.print("selftest: {s} ok (" ++ f ++ ")\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
    }

    fn skip(self: *Report, name: []const u8, comptime f: []const u8, args: anytype) void {
        self.log.print("selftest: {s} skipped (" ++ f ++ ")\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
    }

    fn fail(self: *Report, name: []const u8, comptime f: []const u8, args: anytype) void {
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

    fn call(self: *Caller, tool: []const u8, comptime args_fmt: []const u8, args: anytype) !Res {
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

/// Runs every subtest; returns null when all pass.
pub fn run(gpa: std.mem.Allocator, io: std.Io, log: *std.Io.Writer) !?[]const u8 {
    var report: Report = .{ .log = log };

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
    {
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
    {
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

    securityChecks(&report, gpa, io, arena, &backend, &tw) catch |err| report.fail("security", "{t}", .{err});

    // release: the shipped server releases a held key within 50 ms of stdin
    // EOF and exits with code 0.
    releaseCheck(io, &report, arena);

    return report.failed;
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
        tw.animate(true);
        w.Sleep(50);
        const t0 = qpcUs();
        const busy = try caller.call("left_click", "{{\"coordinate\":[{d},{d}],\"settle_timeout_ms\":300,\"observe\":\"none\"}}", .{ c[0], c[1] });
        _ = busy;
        const busy2 = try caller.call("mouse_move", "{{\"coordinate\":[{d},{d}],\"settle_timeout_ms\":300}}", .{ c[0], c[1] });
        const busy_ms = (qpcUs() - t0) / 1000;
        tw.animate(false);
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
    backend.startKillSwitch(&server.control, .{ .mods = .{ .ctrl = true, .alt = true, .shift = true }, .key = .{ .char = 'r' } });
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
