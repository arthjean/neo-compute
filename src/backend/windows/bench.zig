//! Windows bench scenarios. `capture` measures the DXGI path the tools use
//! (backend.capture of the primary display), `snapshot` a UIA cached
//! snapshot of the taskbar, and `screenshot` and `window_list` run the real
//! tools through the dispatcher (`tools/call` in, JSON-RPC line out).

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const bench = @import("../../core/bench.zig");
const timing = @import("../../core/timing.zig");
const Timings = timing.Timings;
const CountingAllocator = @import("../../core/counting_allocator.zig").CountingAllocator;
const mcp = @import("../../core/mcp.zig");
const tools = @import("../../core/tools.zig");
const Windows = @import("../windows.zig").Windows;
const uia_mod = @import("uia.zig");
const display = @import("../../core/display.zig");

const CaptureScenario = struct {
    pub const default_iterations = 300;
    io: std.Io,
    backend: *Windows,
    arena: std.heap.ArenaAllocator,

    pub fn step(self: *CaptureScenario, t: *Timings) !void {
        _ = self.arena.reset(.retain_capacity);
        t.start(self.io, .capture);
        defer t.stop(self.io, .capture);
        switch (self.backend.capture(0, self.arena.allocator())) {
            .frame => {},
            .failed => return error.CaptureFailed,
        }
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

const Server = mcp.Server(Windows, tools.all);

/// One `tools/call` per iteration through the dispatcher, into a
/// discarding writer; the server's stage timings become the sample.
const ToolScenario = struct {
    server: Server,
    line: []const u8,
    sink_buf: [64 * 1024]u8 = undefined,
    sink: std.Io.Writer.Discarding = undefined,

    pub fn step(self: *ToolScenario, t: *Timings) !void {
        try self.server.handleMessage(self.line, &self.sink.writer);
        for (0..timing.stage_count) |s| {
            t.ns[s] += self.server.timings.ns[s];
            t.allocs[s] += self.server.timings.allocs[s];
            if (self.server.timings.used[s]) t.used[s] = true;
        }
    }
};

const Filler = struct {
    hwnds: [64]w.HWND = undefined,
    len: usize = 0,

    fn fill(self: *Filler, backend: *Windows, want: usize) void {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const listed: []const display.WindowInfo = backend.listWindows(scratch.allocator(), false) catch &.{};
        const have = listed.len;
        const instance = w.GetModuleHandleW(null);
        const class = std.unicode.utf8ToUtf16LeStringLiteral("NeoComputeBenchWindow");
        const wc: w.WNDCLASSEXW = .{ .cbSize = @sizeOf(w.WNDCLASSEXW), .style = 0, .lpfnWndProc = w.DefWindowProcW, .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = instance, .hIcon = null, .hCursor = null, .hbrBackground = null, .lpszMenuName = null, .lpszClassName = class, .hIconSm = null };
        _ = w.RegisterClassExW(&wc);
        while (have + self.len < want and self.len < self.hwnds.len) : (self.len += 1) {
            const x: i32 = 30000 + @as(i32, @intCast(self.len)) * 10;
            self.hwnds[self.len] = w.CreateWindowExW(w.WS_EX_NOACTIVATE, class, std.unicode.utf8ToUtf16LeStringLiteral("neo-compute bench window"), w.WS_POPUP | w.WS_VISIBLE, x, 30000, 200, 100, null, null, instance, null);
        }
    }

    fn destroy(self: *Filler) void {
        for (self.hwnds[0..self.len]) |h| if (h != null) {
            _ = w.DestroyWindow(h);
        };
    }
};

fn unsupported(gpa: std.mem.Allocator, comptime f: []const u8, args: anytype) bench.Outcome {
    return .{ .unsupported = std.fmt.allocPrint(gpa, f, args) catch "unsupported" };
}

fn runTool(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, backend: *Windows, line: []const u8, iterations: usize) !bench.Outcome {
    const s = try gpa.create(ToolScenario);
    defer gpa.destroy(s);
    s.* = .{ .server = .init(counter.allocator(), io, backend, .{}), .line = line };
    defer s.server.deinit();
    s.sink = .init(&s.sink_buf);
    // Warm the request arena and the image buffers: steady state only.
    for (0..10) |_| {
        var scratch: Timings = .{};
        try s.step(&scratch);
    }
    return bench.measure(gpa, io, s, iterations, counter);
}

/// Runs one Windows scenario. Missing capabilities are reported as
/// `unsupported` instead of failing.
pub fn run(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, name: []const u8, iterations: ?usize) !bench.Outcome {
    const counted = counter.allocator();
    var backend: Windows = .init(counted);
    defer backend.deinit();
    if (std.mem.eql(u8, name, "capture") or std.mem.eql(u8, name, "screenshot")) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        switch (backend.capture(0, arena.allocator())) {
            .frame => {},
            .failed => |msg| return unsupported(gpa, "primary display capture unavailable: {s}", .{msg}),
        }
    }
    if (std.mem.eql(u8, name, "capture")) {
        var s: CaptureScenario = .{ .io = io, .backend = &backend, .arena = .init(gpa) };
        defer s.arena.deinit();
        return bench.measure(gpa, io, &s, iterations orelse CaptureScenario.default_iterations, counter);
    }
    if (std.mem.eql(u8, name, "screenshot")) {
        // Display 0 is the primary display (native resolution to 1280 px).
        return runTool(gpa, io, counter, &backend, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\",\"arguments\":{\"display\":0}}}", iterations orelse 200);
    }
    if (std.mem.eql(u8, name, "window_list")) {
        // The budget is stated for 50 windows: top the desktop up with
        // titled windows parked outside every display, owned by this
        // thread so their titles are read without a message loop.
        var extra: Filler = .{};
        defer extra.destroy();
        extra.fill(&backend, 50);
        return runTool(gpa, io, counter, &backend, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"window_list\",\"arguments\":{}}}", iterations orelse 200);
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
    return unsupported(gpa, "unknown scenario", .{});
}
