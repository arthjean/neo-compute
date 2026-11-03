//! Windows bench scenarios: capture (DXGI acquire + readback of the primary
//! output) and snapshot (UIA cached snapshot of the taskbar, a stable
//! cross-process target present on every Windows desktop).

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const bench = @import("../../core/bench.zig");
const Timings = @import("../../core/timing.zig").Timings;
const CountingAllocator = @import("../../core/counting_allocator.zig").CountingAllocator;
const Capture = @import("capture.zig").Capture;
const Output = @import("capture.zig").Output;
const uia_mod = @import("uia.zig");

const CaptureScenario = struct {
    pub const default_iterations = 300;
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *Output,

    pub fn step(self: *CaptureScenario, t: *Timings) !void {
        t.start(self.io, .capture);
        defer t.stop(self.io, .capture);
        // A static screen yields no new frame: the cached frame is read back,
        // which is what a screenshot of an unchanged screen costs.
        if (!try self.out.acquire(self.gpa, 0)) try self.out.readback();
    }
};

const SnapshotScenario = struct {
    pub const default_iterations = 200;
    io: std.Io,
    uia: *uia_mod.Uia,
    hwnd: w.HWND,

    pub fn step(self: *SnapshotScenario, t: *Timings) !void {
        t.start(self.io, .accessibility);
        defer t.stop(self.io, .accessibility);
        _ = try self.uia.snapshot(self.hwnd, uia_mod.discard);
    }
};

fn unsupported(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) bench.Outcome {
    return .{ .unsupported = std.fmt.allocPrint(gpa, fmt, args) catch "unsupported" };
}

/// Runs one Windows scenario. Missing capabilities are reported as
/// `unsupported` instead of failing.
pub fn run(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, name: []const u8, iterations: ?usize) !bench.Outcome {
    const counted = counter.allocator();
    if (std.mem.eql(u8, name, "capture")) {
        var cap = Capture.init(counted) catch |err|
            return unsupported(gpa, "DXGI Desktop Duplication unavailable: {t} (hr=0x{x})", .{ err, com.lastHr() });
        defer cap.deinit(counted);
        const out = cap.outputAt(0, 0) orelse &cap.outputs.items[0];
        _ = out.acquire(counted, 500) catch |err|
            return unsupported(gpa, "first frame unavailable: {t} (hr=0x{x})", .{ err, com.lastHr() });
        var s: CaptureScenario = .{ .gpa = counted, .io = io, .out = out };
        return bench.measure(gpa, io, &s, iterations orelse CaptureScenario.default_iterations, counter);
    }
    if (std.mem.eql(u8, name, "snapshot")) {
        com.check(w.CoInitializeEx(null, @bitCast(w.COINIT_MULTITHREADED))) catch
            return unsupported(gpa, "COM unavailable (hr=0x{x})", .{com.lastHr()});
        defer w.CoUninitialize();
        const hwnd = w.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd"), null);
        if (hwnd == null) return unsupported(gpa, "reference window Shell_TrayWnd (taskbar) not found", .{});
        var u = uia_mod.Uia.init() catch |err|
            return unsupported(gpa, "UI Automation unavailable: {t} (hr=0x{x})", .{ err, com.lastHr() });
        defer u.deinit();
        var s: SnapshotScenario = .{ .io = io, .uia = &u, .hwnd = hwnd };
        return bench.measure(gpa, io, &s, iterations orelse SnapshotScenario.default_iterations, counter);
    }
    if (std.mem.eql(u8, name, "screenshot")) {
        return unsupported(gpa, "capture + reduction + JPEG encoding pipeline not built yet (US-007)", .{});
    }
    return unsupported(gpa, "unknown scenario", .{});
}
