//! Integration tests of the MCP transport: a scripted stdin drives a real
//! `Server.serve` loop (reader task + dispatcher) against the fake backend.

const std = @import("std");
const testing = std.testing;
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const Fake = @import("../backend/fake.zig").Fake;
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
const timing = @import("timing.zig");

const Server = mcp.Server(Fake, tools.all);

pub const Step = union(enum) {
    line: []const u8,
    /// Blocks the script until the server has handled this many messages.
    wait_messages: usize,
    wait_ms: u64,
};

/// stdin replacement that plays `steps`, then reports end of stream.
pub const ScriptReader = struct {
    interface: std.Io.Reader,
    steps: []const Step,
    io: std.Io,
    pos: usize = 0,
    off: usize = 0,
    eof_ns: std.atomic.Value(i64) = .init(0),

    pub fn init(buffer: []u8, steps: []const Step, io: std.Io) ScriptReader {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .steps = steps,
            .io = io,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ScriptReader = @alignCast(@fieldParentPtr("interface", r));
        while (self.pos < self.steps.len) {
            switch (self.steps[self.pos]) {
                .line => |l| {
                    const n = w.write(limit.sliceConst(l[self.off..])) catch return error.WriteFailed;
                    self.off += n;
                    if (self.off == l.len) {
                        self.pos += 1;
                        self.off = 0;
                    }
                    return n;
                },
                .wait_messages => |n| {
                    while (handled.load(.acquire) < n) self.io.sleep(.fromMilliseconds(1), .awake) catch {};
                    self.pos += 1;
                },
                .wait_ms => |ms| {
                    self.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
                    self.pos += 1;
                },
            }
        }
        self.eof_ns.store(@intCast(timing.now(self.io)), .release);
        return error.EndOfStream;
    }
};

var handled: std.atomic.Value(usize) = .init(0);
var counting: ?*CountingAllocator = null;
var allocs_at: [2]u64 = .{ 0, 0 };
var marks: [2]usize = .{ 0, 0 };

fn onMessage(_: *Server) void {
    const n = handled.fetchAdd(1, .acq_rel) + 1;
    if (counting) |c| {
        for (marks, 0..) |m, i| if (n == m) {
            allocs_at[i] = c.count();
        };
    }
}

const Run = struct {
    out: std.Io.Writer.Allocating,
    backend: Fake,
    eof_to_return_ns: i64,

    fn lines(self: *Run) std.mem.SplitIterator(u8, .scalar) {
        const written = self.out.written();
        return std.mem.splitScalar(u8, std.mem.trimEnd(u8, written, "\n"), '\n');
    }

    fn count(self: *Run) usize {
        if (self.out.written().len == 0) return 0;
        var it = self.lines();
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    fn deinit(self: *Run) void {
        self.out.deinit();
    }
};

fn run(gpa: std.mem.Allocator, steps: []const Step, backend: Fake) !Run {
    handled.store(0, .release);
    var result: Run = .{ .out = .init(testing.allocator), .backend = backend, .eof_to_return_ns = 0 };
    errdefer result.out.deinit();
    var in_buf: [64 * 1024]u8 = undefined;
    var reader: ScriptReader = .init(&in_buf, steps, testing.io);
    var server: Server = .init(gpa, testing.io, &result.backend, .{});
    defer server.deinit();
    server.on_message = onMessage;
    try server.serve(&reader.interface, &result.out.writer);
    result.eof_to_return_ns = @as(i64, @intCast(timing.now(testing.io))) - reader.eof_ns.load(.acquire);
    return result;
}

fn parseLine(arena: std.mem.Allocator, line: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
}

const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}\n";

test "initialize echoes a supported version and answers the newest otherwise" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r = try run(testing.allocator, &.{
        .{ .line = init_line },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2099-01-01\"}}\n" },
    }, .{});
    defer r.deinit();
    var it = r.lines();
    const first = try parseLine(arena.allocator(), it.next().?);
    const res = first.object.get("result").?.object;
    try testing.expectEqualStrings("2025-06-18", res.get("protocolVersion").?.string);
    try testing.expect(res.get("capabilities").?.object.get("tools") != null);
    const instr = res.get("instructions").?.string;
    try testing.expect(instr.len > 0 and instr.len <= 1500);
    const second = try parseLine(arena.allocator(), it.next().?);
    try testing.expectEqualStrings(mcp.supported_versions[0], second.object.get("result").?.object.get("protocolVersion").?.string);
    try testing.expect(it.next() == null); // the notification got no response
}

test "supported versions are the published initialize-era specs, newest first" {
    // Checked against modelcontextprotocol.io on 2026-11-03; 2026-07-28 drops
    // `initialize` (docs/decisions/0002-mcp-protocol-version.md).
    try testing.expectEqualStrings("2025-11-25", mcp.supported_versions[0]);
    try testing.expectEqual(@as(usize, 4), mcp.supported_versions.len);
}

test "each response is one compact JSON line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r = try run(testing.allocator, &.{
        .{ .line = init_line },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"tools/list\"}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}\r\n" },
    }, .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.count());
    var it = r.lines();
    while (it.next()) |line| {
        try testing.expect(std.mem.indexOfAny(u8, line, "\r\n") == null);
        const v = try parseLine(arena.allocator(), line);
        try testing.expectEqualStrings("2.0", v.object.get("jsonrpc").?.string);
        // Compact: Stringify's default output has no space after separators.
        try testing.expect(std.mem.indexOf(u8, line, "\": ") == null);
    }
}

test "protocol errors: parse error keeps serving, unknown method, unknown tool" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r = try run(testing.allocator, &.{
        .{ .line = "{not json\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"does/not/exist\"}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"no_such_tool\",\"arguments\":{}}}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"ping\"}\n" },
    }, .{});
    defer r.deinit();
    const expected = [_]struct { id: ?i64, code: ?i64 }{
        .{ .id = null, .code = -32700 },
        .{ .id = 4, .code = -32601 },
        .{ .id = 5, .code = -32602 },
        .{ .id = 6, .code = null },
    };
    var it = r.lines();
    for (expected) |e| {
        const v = try parseLine(arena.allocator(), it.next().?);
        const id = v.object.get("id").?;
        if (e.id) |want| try testing.expectEqual(want, id.integer) else try testing.expect(id == .null);
        if (e.code) |code| {
            try testing.expectEqual(code, v.object.get("error").?.object.get("code").?.integer);
        } else try testing.expect(v.object.get("result") != null);
    }
    try testing.expect(it.next() == null);
}

test "a line longer than the input buffer gets -32700 and serving continues" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const filler: [96 * 1024]u8 = @splat('a'); // above ScriptReader's 64 KiB buffer
    const long = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"ping\",\"params\":{\"x\":\"" ++ filler ++ "\"}}\n";
    var r = try run(testing.allocator, &.{
        .{ .line = long },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n" },
    }, .{});
    defer r.deinit();
    var it = r.lines();
    const first = try parseLine(arena.allocator(), it.next().?);
    try testing.expect(first.object.get("id").? == .null);
    try testing.expectEqual(@as(i64, -32700), first.object.get("error").?.object.get("code").?.integer);
    const second = try parseLine(arena.allocator(), it.next().?);
    try testing.expectEqual(@as(i64, 9), second.object.get("id").?.integer);
    try testing.expect(it.next() == null);
}

test "notifications/cancelled stops the running tool and suppresses its response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t0 = timing.now(testing.io);
    var r = try run(testing.allocator, &.{
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"wait\",\"arguments\":{\"duration\":5}}}\n" },
        .{ .wait_ms = 50 },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":10,\"reason\":\"user\"}}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"ping\"}\n" },
        .{ .wait_messages = 2 },
    }, .{});
    defer r.deinit();
    const elapsed_ms = @divTrunc(timing.now(testing.io) - t0, std.time.ns_per_ms);
    try testing.expect(elapsed_ms < 1000); // far below the 5 s wait
    try testing.expectEqual(@as(usize, 1), r.count());
    var it = r.lines();
    const v = try parseLine(arena.allocator(), it.next().?);
    try testing.expectEqual(@as(i64, 11), v.object.get("id").?.integer);
}

test "a completed tool call is answered" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r = try run(testing.allocator, &.{
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"wait\",\"arguments\":{\"duration\":0.02}}}\n" },
        .{ .wait_messages = 1 },
    }, .{});
    defer r.deinit();
    var it = r.lines();
    const v = try parseLine(arena.allocator(), it.next().?);
    const res = v.object.get("result").?.object;
    try testing.expect(res.get("isError") == null);
    try testing.expectEqualStrings("ok", res.get("content").?.array.items[0].object.get("text").?.string);
}

test "end of stdin releases held inputs and returns within 50 ms, even mid-tool" {
    var r = try run(testing.allocator, &.{
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/call\",\"params\":{\"name\":\"wait\",\"arguments\":{\"duration\":300}}}\n" },
        .{ .wait_ms = 30 },
    }, .{ .held = 2 });
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), r.backend.held);
    try testing.expectEqual(@as(u32, 1), r.backend.release_calls);
    try testing.expectEqual(@as(usize, 0), r.count()); // the cancelled wait is not answered
    try testing.expect(r.eof_to_return_ns < 50 * std.time.ns_per_ms);
}

test "--trace adds a token estimate to each tool result" {
    handled.store(0, .release);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var backend: Fake = .{};
    var server: Server = .init(testing.allocator, testing.io, &backend, .{ .trace = true });
    defer server.deinit();
    try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"tools/call\",\"params\":{\"name\":\"key\",\"arguments\":{\"text\":\"a\",\"repeat\":0}}}", &out.writer);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parseLine(arena.allocator(), std.mem.trimEnd(u8, out.written(), "\n"));
    const res = v.object.get("result").?.object;
    const text = res.get("content").?.array.items[0].object.get("text").?.string;
    const tokens = res.get("_meta").?.object.get("neo-compute/tokens").?.integer;
    try testing.expectEqual(@as(i64, @intCast(@import("tokens.zig").text(text.len))), tokens);
}

test "1000 pings after 100 warm-up pings allocate nothing from the backing allocator" {
    var counter: CountingAllocator = .init(testing.allocator);
    counting = &counter;
    defer counting = null;
    marks = .{ 100, 1100 };
    const ping = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\n";
    var steps: [1100]Step = @splat(.{ .line = ping });
    var r = try run(counter.allocator(), &steps, .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1100), r.count());
    try testing.expect(allocs_at[0] > 0); // warm-up did allocate
    try testing.expectEqual(allocs_at[0], allocs_at[1]);
}

test "notifications/cancelled stops a ui_find wait at its next checkpoint, unanswered" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t0 = timing.now(testing.io);
    var r = try run(testing.allocator, &.{
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"tools/call\",\"params\":{\"name\":\"ui_find\",\"arguments\":{\"query\":\"introuvable\",\"wait_ms\":30000}}}\n" },
        .{ .wait_ms = 80 },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":30,\"reason\":\"user\"}}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"ping\"}\n" },
        .{ .wait_messages = 2 },
    }, .{});
    defer r.deinit();
    const elapsed_ms = @divTrunc(timing.now(testing.io) - t0, std.time.ns_per_ms);
    try testing.expect(elapsed_ms < 1000); // far below the 30 s wait
    try testing.expectEqual(@as(usize, 1), r.count());
    var it = r.lines();
    const v = try parseLine(arena.allocator(), it.next().?);
    try testing.expectEqual(@as(i64, 31), v.object.get("id").?.integer);
}
