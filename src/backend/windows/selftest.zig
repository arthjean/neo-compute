//! `neo-compute selftest`: checks capture, mouse, keyboard, accessibility and
//! DPI mapping against a window the test creates itself. Prints one line per
//! subtest and returns the name of the first failing one.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const Capture = @import("capture.zig").Capture;
const Uia = @import("uia.zig").Uia;
const input = @import("input.zig");
const TestWindow = @import("test_window.zig").TestWindow;
const test_window = @import("test_window.zig");

const Report = struct {
    log: *std.Io.Writer,
    failed: ?[]const u8 = null,

    fn ok(self: *Report, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log.print("selftest: {s} ok (" ++ fmt ++ ")\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
    }

    fn fail(self: *Report, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log.print("selftest: {s} FAILED: " ++ fmt ++ "\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
        if (self.failed == null) self.failed = name;
    }
};

fn isMagenta(px: [4]u8) bool {
    // BGRA from DXGI; the COLORREF 0x00FF00FF is R=255 G=0 B=255.
    return px[0] > 240 and px[1] < 16 and px[2] > 240;
}

fn waitFor(comptime pred: anytype, args: anytype, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (@call(.auto, pred, args)) return true;
        w.Sleep(5);
    }
    return false;
}

/// Runs every subtest; returns null when all pass.
pub fn run(gpa: std.mem.Allocator, log: *std.Io.Writer) !?[]const u8 {
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

    const monitor = w.MonitorFromPoint(.{ .x = 0, .y = 0 }, w.MONITOR_DEFAULTTONEAREST);
    var mi: w.MONITORINFO = std.mem.zeroes(w.MONITORINFO);
    mi.cbSize = @sizeOf(w.MONITORINFO);
    _ = w.GetMonitorInfoW(monitor, &mi);
    var dpi_x: u32 = 0;
    var dpi_y: u32 = 0;
    _ = w.GetDpiForMonitor(monitor, w.MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
    const cx = @divTrunc(mi.rcWork.left + mi.rcWork.right, 2);
    const cy = @divTrunc(mi.rcWork.top + mi.rcWork.bottom, 2);
    var tw: TestWindow = .{ .rect = .{ .left = cx - 240, .top = cy - 160, .right = cx + 240, .bottom = cy + 160 } };
    tw.start() catch {
        report.fail("window", "cannot create the test window", .{});
        return report.failed;
    };
    defer tw.stop();
    w.Sleep(100); // let the first WM_PAINT land

    var wr: w.RECT = undefined;
    _ = w.GetWindowRect(tw.window(), &wr);
    var br: w.RECT = undefined;
    _ = w.GetWindowRect(tw.buttonWindow(), &br);

    // capture: the window's magenta client is visible in the duplicated frame.
    var cap = Capture.init(gpa) catch |err| {
        report.fail("capture", "DXGI duplication unavailable: {t} hr=0x{x}", .{ err, com.lastHr() });
        return report.failed;
    };
    defer cap.deinit(gpa);
    const probe_x = wr.left + 300;
    const probe_y = wr.top + 200;
    if (cap.outputAt(probe_x, probe_y)) |out| {
        var seen = false;
        var tries: u32 = 0;
        while (tries < 60 and !seen) : (tries += 1) {
            _ = out.acquire(gpa, 50) catch |err| {
                report.fail("capture", "AcquireNextFrame failed: {t} hr=0x{x}", .{ err, com.lastHr() });
                return report.failed;
            };
            if (out.pixelAt(probe_x, probe_y)) |px| seen = isMagenta(px);
        }
        if (seen) report.ok("capture", "{d}x{d} BGRA frame shows the test window at {d},{d}", .{ out.width, out.height, probe_x, probe_y }) else report.fail("capture", "pixel {d},{d} is not the test window color", .{ probe_x, probe_y });
    } else report.fail("capture", "no duplicated output contains {d},{d}", .{ probe_x, probe_y });

    // accessibility: UIA finds the button with the same rectangle Win32 reports.
    var uia = Uia.init() catch |err| {
        report.fail("accessibility", "CUIAutomation unavailable: {t} hr=0x{x}", .{ err, com.lastHr() });
        return report.failed;
    };
    defer uia.deinit();
    const Finder = struct {
        found: ?w.RECT = null,
        pub fn element(self: *@This(), e: @import("uia.zig").Element) void {
            if (e.control_type == w.UIA_ButtonControlTypeId and std.mem.eql(u8, e.name, test_window.button_label)) self.found = e.rect;
        }
    };
    var finder: Finder = .{};
    const count = uia.snapshot(tw.window(), &finder) catch |err| {
        report.fail("accessibility", "snapshot failed: {t} hr=0x{x}", .{ err, com.lastHr() });
        return report.failed;
    };
    if (finder.found) |ur| {
        report.ok("accessibility", "{d} elements, button found", .{count});
        // dpi: Win32, UIA and DXGI agree on physical coordinates.
        const same = ur.left == br.left and ur.top == br.top and ur.right == br.right and ur.bottom == br.bottom;
        const out = cap.outputAt(ur.left, ur.top);
        const inside = if (out) |o| o.pixelAt(ur.left + 10, ur.top + 10) else null;
        const outside = if (out) |o| o.pixelAt(ur.left - 4, ur.top + 10) else null;
        if (!same) {
            report.fail("dpi", "UIA button rect {d},{d},{d},{d} differs from Win32 {d},{d},{d},{d}", .{ ur.left, ur.top, ur.right, ur.bottom, br.left, br.top, br.right, br.bottom });
        } else if (inside == null or outside == null or isMagenta(inside.?) or !isMagenta(outside.?)) {
            report.fail("dpi", "captured pixels do not match the button edge at {d},{d}", .{ ur.left, ur.top });
        } else report.ok("dpi", "per-monitor v2, {d} dpi, Win32 = UIA = DXGI at the button edge", .{dpi_x});
    } else report.fail("accessibility", "button `{s}` not found among {d} elements", .{ test_window.button_label, count });

    // mouse: an absolute virtual-desktop click lands on the intended pixel.
    var saved: w.POINT = undefined;
    _ = w.GetCursorPos(&saved);
    defer _ = w.SetCursorPos(saved.x, saved.y);
    tw.resetEvents();
    const target = [2]i32{ 300, 200 };
    input.leftClickAt(wr.left + target[0], wr.top + target[1]) catch {
        report.fail("mouse", "SendInput was blocked", .{});
        return report.failed;
    };
    const clicked = waitFor(struct {
        fn f(t: *TestWindow) bool {
            return t.lastClick() != null;
        }
    }.f, .{&tw}, 1000);
    if (!clicked) {
        report.fail("mouse", "no WM_LBUTTONDOWN within 1 s", .{});
    } else {
        const c = tw.lastClick().?;
        const dx = @abs(c[0] - target[0]);
        const dy = @abs(c[1] - target[1]);
        if (dx <= 1 and dy <= 1) report.ok("mouse", "click at client {d},{d}, error {d},{d} px", .{ c[0], c[1], dx, dy }) else report.fail("mouse", "click landed at {d},{d}, expected {d},{d}", .{ c[0], c[1], target[0], target[1] });
    }

    // keyboard: a Unicode character reaches the focused window.
    if (w.GetForegroundWindow() != tw.window()) _ = w.SetForegroundWindow(tw.window());
    const ch: u16 = 0x00E9; // é, outside ASCII on purpose
    input.unicodeChar(ch) catch {
        report.fail("keyboard", "SendInput was blocked", .{});
        return report.failed;
    };
    const typed = waitFor(struct {
        fn f(t: *TestWindow) bool {
            return t.lastChar() != 0;
        }
    }.f, .{&tw}, 1000);
    if (typed and tw.lastChar() == ch) report.ok("keyboard", "WM_CHAR U+{X:0>4}", .{ch}) else report.fail("keyboard", "expected WM_CHAR U+{X:0>4}, got U+{X:0>4}", .{ ch, tw.lastChar() });

    return report.failed;
}
