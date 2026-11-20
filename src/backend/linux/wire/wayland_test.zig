//! Tests of the native Wayland client (US-079). The byte test replays the
//! compositor's side of a libwayland session recorded in a gnome test
//! session (tests/linux/golden/wayland/, capture.sh): the native client
//! runs the same requests and must send the same bytes, and its log must
//! read as WAYLAND_DEBUG=client did.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wayland.zig");
const sock = @import("sock.zig");
const testing = std.testing;
const ifc = wl.ifaces;

const dir = "tests/linux/golden/wayland/";

fn readGolden(a: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    return std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.bufPrint(&buf, dir ++ "{s}", .{name}), a, .limited(1 << 20));
}

/// The compositor's side of the recording: it reads what the client sent
/// before each answer, then writes that answer.
const Replay = struct {
    fd: i32,
    chunks: []const u8,
    received: []const u8,
    sent: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    failed: bool = false,

    fn run(r: *Replay) void {
        var lines = std.mem.tokenizeScalar(u8, r.chunks, '\n');
        var off: usize = 0;
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const kind = parts.next() orelse continue;
            const n = std.fmt.parseInt(usize, parts.next() orelse continue, 10) catch continue;
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
                sock.sendAll(r.fd, r.received[off..][0..n], &.{}) catch {
                    r.failed = true;
                    return;
                };
                off += n;
            }
        }
    }
};

/// Binds wl_compositor and wl_shm as their globals arrive, as the
/// reference client does in its registry listener.
const Binder = struct {
    compositor: u32 = 0,
    shm: u32 = 0,

    pub fn event(b: *Binder, c: *wl.Connection, e: wl.Event) void {
        if (!e.is(ifc.wl_registry, ifc.wl_registry.event.global)) return;
        const name = e.args[1].string.?;
        const g: wl.Global = .{ .name = e.args[0].uint, .interface = name, .version = e.args[2].uint };
        if (std.mem.eql(u8, name, "wl_compositor")) b.compositor = c.bind(g, ifc.wl_compositor) catch 0;
        if (std.mem.eql(u8, name, "wl_shm")) b.shm = c.bind(g, ifc.wl_shm) catch 0;
    }
};

/// A trace line without its time, queue and `discarded` marker, and with
/// descriptor numbers dropped (they differ between processes).
fn normalize(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    var s = line;
    if (std.mem.startsWith(u8, s, "[")) s = s[(std.mem.indexOfScalar(u8, s, ']') orelse return s) + 2 ..];
    if (std.mem.startsWith(u8, s, "{")) s = s[(std.mem.indexOfScalar(u8, s, '}') orelse return s) + 2 ..];
    if (std.mem.startsWith(u8, s, "discarded ")) s = s["discarded ".len..];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "fd ")) {
            try out.appendSlice(a, "fd N");
            i += 3;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}

test "the native client sends libwayland's bytes and reads the compositor as libwayland did" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try sock.pair();
    var replay: Replay = .{ .fd = p[1], .chunks = try readGolden(a, "gnome.chunks"), .received = try readGolden(a, "gnome-received.bin"), .a = a };
    const t = try std.Thread.spawn(.{}, Replay.run, .{&replay});

    var log: std.Io.Writer.Allocating = .init(a);
    var c = try wl.Connection.adopt(testing.allocator, p[0]);
    defer c.deinit();
    c.log = &log.writer;
    const deadline = sock.deadlineIn(5000);

    c.registry = try c.newId(&ifc.wl_registry.interface);
    try c.request(wl.Connection.display_id, ifc.wl_display.request.get_registry, &.{.{ .new_id = c.registry }});
    var binder: Binder = .{};
    try c.roundtrip(deadline, &binder);
    try testing.expect(binder.compositor != 0 and binder.shm != 0);
    try testing.expect(c.global("wl_seat") != null);

    var pool = try wl.ShmPool.create(&c, binder.shm, 64 * 64 * 4);
    const buffer = try pool.buffer(&c, 0, 64, 64, 64 * 4, @intCast(ifc.wl_shm.enums.format.xrgb8888));
    const surface = try c.newId(&ifc.wl_surface.interface);
    try c.request(binder.compositor, ifc.wl_compositor.request.create_surface, &.{.{ .new_id = surface }});
    try c.request(surface, ifc.wl_surface.request.attach, &.{ .{ .object = buffer }, .{ .int = 0 }, .{ .int = 0 } });
    try c.request(surface, ifc.wl_surface.request.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 64 }, .{ .int = 64 } });
    try c.request(surface, ifc.wl_surface.request.commit, &.{});
    c.roundtrip(deadline, null) catch |e| {
        std.debug.print("{s}\n{s}\n", .{ c.problem, log.written() });
        return e;
    };
    try c.request(surface, ifc.wl_surface.request.destroy, &.{});
    try c.request(buffer, ifc.wl_buffer.request.destroy, &.{});
    // The pool's memory stays mapped until its destroy request.
    pool.memory[0] = 0xff;
    pool.destroy(&c);
    try c.request(binder.shm, ifc.wl_shm.request.release, &.{});
    try c.roundtrip(deadline, null);
    t.join();
    try testing.expect(!replay.failed);

    // The same bytes as libwayland, ids reused after delete_id included.
    try testing.expectEqualSlices(u8, try readGolden(a, "gnome-sent.bin"), replay.sent.items);
    // The same requests and events, in the order libwayland logged them.
    var want: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, try readGolden(a, "gnome.trace"), '\n');
    while (it.next()) |line| try want.append(a, try normalize(a, line));
    var got: std.ArrayList([]const u8) = .empty;
    var it2 = std.mem.tokenizeScalar(u8, log.written(), '\n');
    while (it2.next()) |line| try got.append(a, try normalize(a, line));
    try testing.expectEqual(want.items.len, got.items.len);
    for (want.items, got.items) |w, g| try testing.expectEqualStrings(w, g);
}

/// A compositor that answers the first sync with `answer`, then waits.
fn serveOnce(fd: i32, answer: []const u8, close_after: bool) void {
    var buf: [4096]u8 = undefined;
    var fds: std.ArrayList(i32) = .empty;
    defer fds.deinit(testing.allocator);
    _ = sock.recvSome(fd, &buf, &fds, testing.allocator, sock.deadlineIn(2000)) catch return;
    if (answer.len > 0) sock.sendAll(fd, answer, &.{}) catch return;
    if (close_after) _ = linux.close(fd);
}

fn event(a: std.mem.Allocator, object: u32, opcode: u16, args: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, std.mem.asBytes(&object));
    const word: u32 = (@as(u32, @intCast(8 + args.len)) << 16) | opcode;
    try out.appendSlice(a, std.mem.asBytes(&word));
    try out.appendSlice(a, args);
    return out.items;
}

test "wl_display.error becomes a typed error naming the object, the code and the message" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try sock.pair();
    defer _ = linux.close(p[1]);
    // error(object 2, code 7, "bad thing")
    var args: std.ArrayList(u8) = .empty;
    for ([_]u32{ 2, 7, 10 }) |v| try args.appendSlice(a, std.mem.asBytes(&v));
    try args.appendSlice(a, "bad thing\x00\x00\x00");
    const answer = try event(a, 1, ifc.wl_display.event.@"error", args.items);
    const t = try std.Thread.spawn(.{}, serveOnce, .{ p[1], answer, false });
    var c = try wl.Connection.adopt(testing.allocator, p[0]);
    defer c.deinit();
    c.registry = try c.newId(&ifc.wl_registry.interface);
    try c.request(1, ifc.wl_display.request.get_registry, &.{.{ .new_id = c.registry }});
    try testing.expectError(error.Protocol, c.roundtrip(sock.deadlineIn(2000), null));
    t.join();
    try testing.expectEqual(@as(u32, 2), c.protocol_error.object);
    try testing.expectEqualStrings("wl_registry", c.protocol_error.interface());
    try testing.expectEqual(@as(u32, 7), c.protocol_error.code);
    try testing.expectEqualStrings("bad thing", c.protocol_error.message());
    try testing.expectError(error.Disconnected, c.sync());
}

test "a socket closed by the compositor fails the pending request and every one after, without a crash" {
    const p = try sock.pair();
    const t = try std.Thread.spawn(.{}, serveOnce, .{ p[1], "", true });
    var c = try wl.Connection.adopt(testing.allocator, p[0]);
    defer c.deinit();
    try testing.expectError(error.Disconnected, c.roundtrip(sock.deadlineIn(2000), null));
    t.join();
    try testing.expectError(error.Disconnected, c.sync());
    try testing.expectError(error.Disconnected, c.request(1, ifc.wl_display.request.sync, &.{.{ .new_id = 9 }}));
    try testing.expectEqualStrings("Compositeur Wayland déconnecté : relance la session graphique.", c.describe(error.Disconnected));
}

test "an event of a size below its header closes the connection as malformed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try sock.pair();
    defer _ = linux.close(p[1]);
    const bad = [_]u8{ 1, 0, 0, 0, 0, 0, 4, 0 };
    const t = try std.Thread.spawn(.{}, serveOnce, .{ p[1], &bad, false });
    var c = try wl.Connection.adopt(testing.allocator, p[0]);
    defer c.deinit();
    try testing.expectError(error.Malformed, c.roundtrip(sock.deadlineIn(2000), null));
    t.join();
    try testing.expect(c.fd < 0);
}

test "a request whose arguments do not match its signature is refused before any byte" {
    var c = try wl.Connection.adopt(testing.allocator, -1);
    defer c.objects.deinit(testing.allocator);
    c.fd = 0x7fff; // never written: the check comes first
    try testing.expectError(error.BadArguments, c.request(1, ifc.wl_display.request.sync, &.{.{ .uint = 3 }}));
    try testing.expectError(error.BadArguments, c.request(1, ifc.wl_display.request.sync, &.{}));
    try testing.expectError(error.BadArguments, c.request(42, 0, &.{}));
    c.fd = -1;
}
