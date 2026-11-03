//! Process-level lifecycle checks on the real server binary: time from
//! process creation to the `initialize` response, and exit after stdin EOF.

const std = @import("std");
const testing = std.testing;
const options = @import("test_options");

const runs = 20;
const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"process_test\",\"version\":\"0\"}}}\n";

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

const Sample = struct { initialize_ns: i96, exit_ns: i96 };

fn once(io: std.Io) !Sample {
    const t0 = nowNs(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{options.server_exe},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    var wbuf: [512]u8 = undefined;
    var w = child.stdin.?.writerStreaming(io, &wbuf);
    try w.interface.writeAll(init_line);
    try w.interface.flush();

    var rbuf: [16 * 1024]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &rbuf);
    const line = (try r.interface.takeDelimiter('\n')) orelse return error.NoResponse;
    const t1 = nowNs(io);
    try testing.expect(std.mem.indexOf(u8, line, "\"protocolVersion\":\"2025-11-25\"") != null);

    child.stdin.?.close(io);
    child.stdin = null;
    const t2 = nowNs(io);
    const term = try child.wait(io);
    const t3 = nowNs(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    return .{ .initialize_ns = t1 - t0, .exit_ns = t3 - t2 };
}

test "initialize is answered within 50 ms of process creation, and EOF exits with code 0 within 50 ms" {
    const io = testing.io;
    var init_ns: [runs]i96 = undefined;
    var exit_ns: [runs]i96 = undefined;
    // The first launch of a freshly linked binary pays a one-time antivirus
    // scan (up to ~1.5 s measured on the reference machine), unrelated to
    // process start-up; it is excluded.
    _ = try once(io);
    for (0..runs) |i| {
        const s = try once(io);
        init_ns[i] = s.initialize_ns;
        exit_ns[i] = s.exit_ns;
    }
    std.mem.sort(i96, &init_ns, {}, std.sort.asc(i96));
    std.mem.sort(i96, &exit_ns, {}, std.sort.asc(i96));
    const p95 = runs * 95 / 100 - 1;
    std.debug.print("process: initialize p50 {d} us p95 {d} us max {d} us; exit after EOF p95 {d} us max {d} us\n", .{
        @divTrunc(init_ns[runs / 2], 1000), @divTrunc(init_ns[p95], 1000),      @divTrunc(init_ns[runs - 1], 1000),
        @divTrunc(exit_ns[p95], 1000),      @divTrunc(exit_ns[runs - 1], 1000),
    });
    try testing.expect(init_ns[p95] < 50 * std.time.ns_per_ms);
    try testing.expect(exit_ns[p95] < 50 * std.time.ns_per_ms);
}
