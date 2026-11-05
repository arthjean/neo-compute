//! neo-compute: MCP server giving Claude Code perception and action on the
//! desktop. `neo-compute` (or `neo-compute serve`) speaks MCP on stdio.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const mcp = @import("core/mcp.zig");
const tools = @import("core/tools.zig");
const bench = @import("core/bench.zig");
const display = @import("core/display.zig");
const policy = @import("core/policy.zig");
const audit = @import("core/audit.zig");
const keys = @import("core/keys.zig");

pub const Backend = if (builtin.os.tag == .windows and !build_options.fake_backend)
    @import("backend/windows.zig").Windows
else
    @import("backend/fake.zig").Fake;

pub const Server = mcp.Server(Backend, tools.all);

const usage =
    \\usage: neo-compute [serve] [--trace] [--screenshot-size 1024..1920] [--mode a11y|vision]
    \\                   [--policy FILE] [--rearm-key COMBO]
    \\       neo-compute bench <all|transport|diff|capture|snapshot|screenshot|window_list|ui_tree|settle|APP> [--iterations N]
    \\                         [--check BASELINE.json] [--write-baseline FILE]
    \\       neo-compute selftest
    \\       neo-compute --version
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (@hasDecl(Backend, "initProcess")) Backend.initProcess();
    if (args.len > 1 and std.mem.eql(u8, args[1], "bench")) return benchCommand(init, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "selftest")) return selftestCommand(init);

    var trace = false;
    var screenshot_size: u32 = display.default_long_side;
    var mode: mcp.Mode = .a11y;
    var policy_path: ?[]const u8 = null;
    var rearm: keys.Combo = default_rearm;
    var i: usize = 1;
    if (i < args.len and std.mem.eql(u8, args[i], "serve")) i += 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--trace")) {
            trace = true;
        } else if (std.mem.eql(u8, a, "--screenshot-size")) {
            const v = if (i + 1 < args.len) args[i + 1] else "";
            screenshot_size = std.fmt.parseInt(u32, v, 10) catch 0;
            if (screenshot_size < display.min_long_side or screenshot_size > display.max_long_side) {
                std.debug.print("neo-compute: --screenshot-size needs a long side from {d} to {d} pixels\n", .{ display.min_long_side, display.max_long_side });
                return 2;
            }
            i += 1;
        } else if (std.mem.eql(u8, a, "--mode")) {
            const v = if (i + 1 < args.len) args[i + 1] else "";
            mode = std.meta.stringToEnum(mcp.Mode, v) orelse {
                std.debug.print("neo-compute: --mode needs a11y or vision\n", .{});
                return 2;
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--policy")) {
            policy_path = if (i + 1 < args.len) args[i + 1] else {
                std.debug.print("neo-compute: --policy needs a file path\n", .{});
                return 2;
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--rearm-key")) {
            const v = if (i + 1 < args.len) args[i + 1] else "";
            rearm = switch (keys.parse(v)) {
                .ok => |c| c,
                else => {
                    std.debug.print("neo-compute: --rearm-key needs a key combination such as ctrl+alt+shift+r\n", .{});
                    return 2;
                },
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("{s} {s}\n", .{ mcp.server_name, mcp.server_version });
            return 0;
        } else {
            std.debug.print("neo-compute: unknown argument `{s}`\n{s}", .{ a, usage });
            return 2;
        }
    }
    return serve(init, .{ .trace = trace, .screenshot_size = screenshot_size, .mode = mode }, policy_path, rearm);
}

/// The only way to lift a kill switch pause (US-018), physical only.
const default_rearm: keys.Combo = .{ .mods = .{ .ctrl = true, .alt = true, .shift = true }, .key = .{ .char = 'r' } };

fn serve(init: std.process.Init, base: mcp.Options, policy_path: ?[]const u8, rearm: keys.Combo) !u8 {
    const arena = init.arena.allocator();
    const env = init.environ_map;
    var options = base;

    // US-017: %APPDATA%\neo-compute\policy.json unless --policy names a file.
    const path = policy_path orelse if (env.get("APPDATA")) |d| try std.fs.path.join(arena, &.{ d, "neo-compute", "policy.json" }) else null;
    const pol: policy.Policy = if (path) |p| policy.load(arena, init.io, p, policy_path != null) else policy.defaults;
    if (pol.problem) |why| std.debug.print("neo-compute: {s}: every application is limited to observe\n", .{why});
    options.policy = &pol;

    // US-019: %LOCALAPPDATA%\neo-compute\audit.jsonl.
    var log: ?audit.Audit = null;
    if (env.get("LOCALAPPDATA")) |d| {
        log = audit.Audit.open(init.io, try std.fs.path.join(arena, &.{ d, "neo-compute" })) catch |err| blk: {
            std.debug.print("neo-compute: audit log unavailable ({t}): tool calls are not recorded\n", .{err});
            break :blk null;
        };
    } else std.debug.print("neo-compute: LOCALAPPDATA is not set: tool calls are not recorded\n", .{});
    defer if (log) |*l| l.deinit();
    if (log) |*l| options.audit = l;

    // FR-14: one instance controls the desktop; a second one observes.
    options.exclusive = if (@hasDecl(Backend, "acquireInstance")) Backend.acquireInstance() else true;
    if (!options.exclusive) std.debug.print("neo-compute: another neo-compute controls this desktop: this instance refuses actions\n", .{});

    // Longest accepted line; longer lines are answered with -32700.
    const in_buf = try init.gpa.alloc(u8, 1024 * 1024);
    defer init.gpa.free(in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, in_buf);
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);

    var backend: Backend = if (@hasDecl(Backend, "init")) .init(init.gpa) else .{};
    defer if (@hasDecl(Backend, "deinit")) backend.deinit();
    var server: Server = .init(init.gpa, init.io, &backend, options);
    defer server.deinit();
    if (options.exclusive and @hasDecl(Backend, "startKillSwitch")) backend.startKillSwitch(&server.control, rearm);
    defer if (@hasDecl(Backend, "stopKillSwitch")) backend.stopKillSwitch();
    try server.serve(&stdin.interface, &stdout.interface);
    return 0;
}

fn benchCommand(init: std.process.Init, args: []const [:0]const u8) !u8 {
    const arena = init.arena.allocator();
    var which: []const u8 = "all";
    var iterations: ?usize = null;
    var check_path: ?[]const u8 = null;
    var baseline_out: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const value = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--iterations")) {
            iterations = std.fmt.parseInt(usize, value, 10) catch {
                std.debug.print("neo-compute bench: --iterations needs a number\n", .{});
                return 2;
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--check")) {
            check_path = value;
            i += 1;
        } else if (std.mem.eql(u8, a, "--write-baseline")) {
            baseline_out = value;
            i += 1;
        } else if (!std.mem.startsWith(u8, a, "--")) {
            which = a;
        } else {
            std.debug.print("neo-compute bench: unknown flag `{s}`\n{s}", .{ a, usage });
            return 2;
        }
    }

    const results = bench.run(Backend, arena, init.io, which, iterations) catch |err| switch (err) {
        error.UnknownScenario => {
            std.debug.print("neo-compute bench: unknown scenario `{s}`\n{s}", .{ which, usage });
            return 2;
        },
        else => return err,
    };

    var out_buf: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    try bench.writeReport(results, &stdout.interface);
    try stdout.interface.flush();

    const cwd = std.Io.Dir.cwd();
    if (baseline_out) |path| {
        // The reference is the worst p95 over several runs (see mergeWorstP95).
        for (1..bench.baseline_runs) |_| bench.mergeWorstP95(results, try bench.run(Backend, arena, init.io, which, iterations));
        var buf: std.Io.Writer.Allocating = .init(arena);
        try bench.writeBaseline(results, &buf.writer);
        try cwd.writeFile(init.io, .{ .sub_path = path, .data = buf.written() });
    }
    if (check_path) |path| {
        const baseline = cwd.readFileAlloc(init.io, path, arena, .limited(1 << 20)) catch |err| {
            std.debug.print("neo-compute bench: cannot read {s}: {t}\n", .{ path, err });
            return 2;
        };
        var err_buf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
        const violations = try bench.check(arena, baseline, results, &stderr.interface);
        if (violations > 0)
            try stderr.interface.print("bench: {d} regression(s) against {s}\n", .{ violations, path })
        else
            try stderr.interface.print("bench: no regression against {s}\n", .{path});
        try stderr.interface.flush();
        if (violations > 0) return 1;
    }
    return 0;
}

fn selftestCommand(init: std.process.Init) !u8 {
    var err_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
    defer stderr.interface.flush() catch {};
    if (!@hasDecl(Backend, "selftest")) {
        try stderr.interface.print("selftest: platform FAILED: this build has no platform backend\n", .{});
        return 1;
    }
    const failed = try Backend.selftest(init.gpa, init.io, &stderr.interface);
    if (failed) |name| {
        try stderr.interface.print("selftest: FAILED ({s})\n", .{name});
        return 1;
    }
    try stderr.interface.print("selftest: all subtests passed\n", .{});
    return 0;
}

test {
    _ = @import("core/mcp_test.zig");
    _ = @import("core/registry_test.zig");
    _ = @import("core/bench_test.zig");
    _ = @import("core/tokens.zig");
    _ = @import("core/display.zig");
    _ = @import("core/image.zig");
    _ = @import("core/jpeg.zig");
    _ = @import("core/keys.zig");
    _ = @import("core/tools_test.zig");
    _ = @import("core/uitree.zig");
    _ = @import("core/a11y_test.zig");
    _ = @import("core/policy.zig");
    _ = @import("core/audit.zig");
    _ = @import("core/security_test.zig");
}
