//! Tests of the native EI client (US-080). The byte test replays Mutter's
//! side of a libei 1.6 conversation recorded in a gnome test session
//! (tests/linux/golden/ei/, capture.sh): the native client must send
//! libei's bytes, from the handshake to the end of the absolute motion.

const std = @import("std");
const linux = std.os.linux;
const ei = @import("ei.zig");
const sock = @import("sock.zig");
const testing = std.testing;

const dir = "tests/linux/golden/ei/";

fn readGolden(a: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    return std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.bufPrint(&buf, dir ++ "{s}", .{name}), a, .limited(1 << 20));
}

/// Mutter's side: reads what the client sent before each answer, writes
/// the answer, with a stand-in keymap descriptor where Mutter sent one.
const Replay = struct {
    fd: i32,
    chunks: []const u8,
    received: []const u8,
    /// Stop before this many answers (0: all).
    answers: usize = 0,
    sent: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    failed: bool = false,

    fn run(r: *Replay) void {
        var lines = std.mem.tokenizeScalar(u8, r.chunks, '\n');
        var off: usize = 0;
        var answered: usize = 0;
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const kind = parts.next() orelse continue;
            const n = std.fmt.parseInt(usize, parts.next() orelse continue, 10) catch continue;
            const nfds = std.fmt.parseInt(usize, parts.next() orelse "0", 10) catch 0;
            if (r.answers > 0 and answered == r.answers) return;
            if (std.mem.eql(u8, kind, "send")) {
                var got: usize = 0;
                while (got < n) {
                    var buf: [4096]u8 = undefined;
                    var fds: std.ArrayList(i32) = .empty;
                    defer {
                        sock.closeAll(fds.items);
                        fds.deinit(r.a);
                    }
                    const k = sock.recvSome(r.fd, buf[0..@min(buf.len, n - got)], &fds, r.a, sock.deadlineIn(3000)) catch {
                        r.failed = true;
                        return;
                    };
                    r.sent.appendSlice(r.a, buf[0..k]) catch return;
                    got += k;
                }
            } else {
                answered += 1;
                var fds: [1]i32 = undefined;
                if (nfds > 0) {
                    fds[0] = @intCast(linux.memfd_create("nc-keymap", linux.MFD.CLOEXEC));
                    _ = linux.ftruncate(fds[0], 1 << 20);
                }
                defer if (nfds > 0) {
                    _ = linux.close(fds[0]);
                };
                sock.sendAll(r.fd, r.received[off..][0..n], fds[0..@min(nfds, 1)]) catch {
                    r.failed = true;
                    return;
                };
                off += n;
            }
        }
    }
};

const wanted = [_]ei.Capability{ .pointer, .pointer_absolute, .button, .keyboard };

test "the native client sends libei's bytes from the handshake to an absolute motion" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try sock.pair();
    defer _ = linux.close(p[1]);
    var replay: Replay = .{ .fd = p[1], .chunks = try readGolden(a, "mutter.chunks"), .received = try readGolden(a, "mutter-received.bin"), .a = a };
    const t = try std.Thread.spawn(.{}, Replay.run, .{&replay});

    var c = try ei.Context.init(testing.allocator, p[0], &wanted);
    defer c.deinit();
    c.client_name = "neo-compute golden";
    const deadline = sock.deadlineIn(5000);
    const d = try c.waitDevice(.pointer_absolute, deadline);
    try testing.expectEqualStrings("neo-compute golden shared virtual absolute pointer", d.name());
    try testing.expectEqual(@as(usize, 1), d.region_count);
    try testing.expectEqual(@as(u32, 1920), d.regions[0].width);
    try testing.expectEqual(@as(u32, 1080), d.regions[0].height);
    try testing.expect(c.keymap() != null);
    try c.start(d);
    try c.moveTo(d, 100, 200);
    try c.frame(d, 1000000);
    try c.stop(d);
    // libei then releases each device; the native client does too, with
    // every interface object (libei 1.6 leaves the absolute pointer's).
    c.close();
    t.join();
    try testing.expect(!replay.failed);
    const golden = try readGolden(a, "mutter-sent.bin");
    // Up to stop_emulating: the teardown is compared by its messages.
    const teardown = 10 * 16;
    try testing.expectEqualSlices(u8, golden[0 .. golden.len - teardown], replay.sent.items[0 .. golden.len - teardown]);
}

test "a paused device refuses every action and sends nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try sock.pair();
    defer _ = linux.close(p[1]);
    // The whole setup, up to the absolute pointer resumed.
    var replay: Replay = .{ .fd = p[1], .chunks = try readGolden(a, "mutter.chunks"), .received = try readGolden(a, "mutter-received.bin"), .a = a };
    replay.answers = 6;
    const t = try std.Thread.spawn(.{}, Replay.run, .{&replay});
    var c = try ei.Context.init(testing.allocator, p[0], &wanted);
    defer c.deinit();
    c.client_name = "neo-compute golden"; // the replay counts the recorded bytes
    const d = try c.waitDevice(.pointer_absolute, sock.deadlineIn(5000));
    t.join();
    // Mutter pauses the device: ei_device.paused(serial 6).
    var msg: [20]u8 = undefined;
    std.mem.writeInt(u64, msg[0..8], d.id, .little);
    std.mem.writeInt(u32, msg[8..12], 20, .little);
    std.mem.writeInt(u32, msg[12..16], ei.ifaces.ei_device.event.paused, .little);
    std.mem.writeInt(u32, msg[16..20], 6, .little);
    try sock.sendAll(p[1], &msg, &.{});
    try c.dispatch(sock.deadlineIn(1000));
    try testing.expect(!d.resumed);
    try testing.expectError(error.Suspended, c.start(d));
    try testing.expectError(error.Suspended, c.moveTo(d, 10, 10));
    try testing.expectError(error.Suspended, c.button(d, 0x110, true));
    try testing.expectError(error.Suspended, c.frame(d, 1));
    try testing.expectEqualStrings("Entrée suspendue par le compositeur : réessaie dans un instant.", ei.describe(error.Suspended));
    // Nothing reached the server.
    try testing.expectError(error.Timeout, sock.waitReadable(p[1], sock.deadlineIn(50)));
}

test "a disconnected event and a malformed message end the context with a typed error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_]bool{ true, false }) |disconnect| {
        const p = try sock.pair();
        defer _ = linux.close(p[1]);
        var c = try ei.Context.init(testing.allocator, p[0], &wanted);
        defer c.deinit();
        var msg: [16]u8 = undefined;
        std.mem.writeInt(u64, msg[0..8], 0, .little);
        std.mem.writeInt(u32, msg[8..12], if (disconnect) 12 else 16, .little); // a length below the header
        std.mem.writeInt(u32, msg[12..16], 0, .little);
        if (disconnect) _ = linux.close(p[1]) else try sock.sendAll(p[1], &msg, &.{});
        const want: ei.Error = if (disconnect) error.Disconnected else error.Malformed;
        if (disconnect) {
            try testing.expectError(want, c.dispatch(sock.deadlineIn(1000)));
        } else {
            // handshake_version with no argument: shorter than its signature.
            try testing.expectError(error.Malformed, c.dispatch(sock.deadlineIn(1000)));
        }
        try testing.expect(c.fd < 0);
        try testing.expectError(error.Disconnected, c.dispatch(null));
    }
}
