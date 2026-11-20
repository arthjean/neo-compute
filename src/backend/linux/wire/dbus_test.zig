//! Tests of the native D-Bus client (US-078): bytes against the messages
//! GDBus sent and received in a gnome test session
//! (tests/linux/golden/dbus/, recorded by its capture.sh), corrupted
//! messages, and a private dbus-daemon for the calls, the signals, the
//! names and a peer stopped by SIGSTOP.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus.zig");
const sock = @import("sock.zig");
const testing = std.testing;

const bus = dbus.ifaces.org_freedesktop_DBus;
const props = dbus.ifaces.org_freedesktop_DBus_Properties;
const rd = dbus.ifaces.org_gnome_Mutter_RemoteDesktop;
const rds = dbus.ifaces.org_gnome_Mutter_RemoteDesktop_Session;

const golden_path = "tests/linux/golden/dbus/mutter-remote-desktop.bin";

/// The messages of a dbus-monitor --binary recording.
fn goldenMessages(a: std.mem.Allocator) ![]const []const u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(testing.io, golden_path, a, .limited(1 << 20));
    var out: std.ArrayList([]const u8) = .empty;
    var off: usize = 0;
    var problem: []const u8 = "";
    while (off < data.len) {
        const len = (try dbus.messageLength(data[off..], &problem)).?;
        try out.append(a, data[off..][0..len]);
        off += len;
    }
    return out.items;
}

/// Parses a recorded message. dbus-monitor receives no descriptor: a
/// message that announces some gets stand-ins.
fn parseGolden(a: std.mem.Allocator, bytes: []const u8) !dbus.Message {
    var problem: []const u8 = "";
    var count: u32 = 0;
    {
        var probe = dbus.parse(a, bytes, &.{}, &problem);
        if (probe) |_| {} else |_| {
            // Find the UNIX_FDS count the recording keeps.
            const fake = try a.alloc(i32, 8);
            @memset(fake, -1);
            var n: u32 = 1;
            while (n <= 8) : (n += 1) {
                probe = dbus.parse(a, bytes, fake[0..n], &problem);
                if (probe) |_| {
                    count = n;
                    break;
                } else |_| {}
            }
        }
    }
    const fds = try a.alloc(i32, count);
    @memset(fds, -1);
    return dbus.parse(a, bytes, fds, &problem) catch |e| {
        std.debug.print("golden message refused: {s}\n", .{problem});
        return e;
    };
}

test "every recorded message parses and re-encodes to the same bytes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = try goldenMessages(a);
    try testing.expect(msgs.len >= 20);
    var kinds: [5]usize = @splat(0);
    for (msgs) |bytes| {
        const m = try parseGolden(a, bytes);
        kinds[@backingInt(m.header.kind)] += 1;
        // Every value, the variants and dictionaries of GetCurrentState
        // and Properties.Get included, typed at run time and written back.
        const vals = try m.values();
        var w: dbus.Writer = .{ .a = a };
        var i: usize = 0;
        for (vals) |v| {
            const end = sigEnd(m.header.signature, i);
            try w.value(m.header.signature[i..end], v);
            i = end;
        }
        const again = try dbus.encode(a, m.header, m.header.order, w.buf.items);
        try testing.expectEqualSlices(u8, bytes, again);
    }
    // Calls, returns, an error-free recording and the bus's signals.
    try testing.expect(kinds[1] >= 10 and kinds[2] >= 10 and kinds[4] >= 2);
}

fn sigEnd(sig: []const u8, i: usize) usize {
    var j = i;
    while (sig[j] == 'a') j += 1;
    if (sig[j] != '(' and sig[j] != '{') return j + 1;
    var depth: usize = 0;
    while (j < sig.len) : (j += 1) switch (sig[j]) {
        '(', '{' => depth += 1,
        ')', '}' => {
            depth -= 1;
            if (depth == 0) return j + 1;
        },
        else => {},
    };
    return sig.len;
}

/// The recorded message as its client sent it: without the SENDER field
/// the bus adds.
fn asSent(a: std.mem.Allocator, m: dbus.Message) ![]u8 {
    var order: std.ArrayList(dbus.Field) = .empty;
    for (m.header.order) |f| if (f != .sender) try order.append(a, f);
    var h = m.header;
    h.sender = null;
    return dbus.encode(a, h, order.items, m.body);
}

test "each call of the reference client is the bytes the generated members encode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var compared: usize = 0;
    for (try goldenMessages(a)) |bytes| {
        const m = try parseGolden(a, bytes);
        if (m.header.kind != .call) continue;
        const want = try asSent(a, m);
        const h = m.header;
        var fds: std.ArrayList(i32) = .empty;
        const member = h.member.?;
        const ours: []u8 = if (std.mem.eql(u8, member, "Hello"))
            try dbus.buildCall(a, h.serial, h.flags, h.destination, h.path.?, bus.Hello, .{}, &fds)
        else if (std.mem.eql(u8, member, "AddMatch"))
            try dbus.buildCall(a, h.serial, h.flags, h.destination, h.path.?, bus.AddMatch, .{(try m.read(struct { []const u8 }))[0]}, &fds)
        else if (std.mem.eql(u8, member, "GetConnectionUnixProcessID"))
            try dbus.buildCall(a, h.serial, h.flags, h.destination, h.path.?, bus.GetConnectionUnixProcessID, .{(try m.read(struct { []const u8 }))[0]}, &fds)
        else if (std.mem.eql(u8, member, "RequestName")) blk: {
            const args = try m.read(struct { []const u8, u32 });
            break :blk try dbus.buildCall(a, h.serial, h.flags, h.destination, h.path.?, bus.RequestName, .{ args[0], args[1] }, &fds);
        } else if (std.mem.eql(u8, member, "CreateSession"))
            try dbus.buildCall(a, h.serial, h.flags, h.destination, h.path.?, rd.CreateSession, .{}, &fds)
        else if (std.mem.eql(u8, member, "Get"))
            try dbus.buildCall(a, h.serial, h.flags, h.destination, h.path.?, props.Get, .{ @as([]const u8, rds.SessionId.interface), @as([]const u8, rds.SessionId.name) }, &fds)
        else if (std.mem.eql(u8, member, "Start"))
            try dbus.buildCall(a, h.serial, h.flags, h.destination, h.path.?, rds.Start, .{}, &fds)
        else if (std.mem.eql(u8, member, "Stop"))
            try dbus.buildCall(a, h.serial, h.flags, h.destination, h.path.?, rds.Stop, .{}, &fds)
        else if (std.mem.eql(u8, member, "ConnectToEIS"))
            try dbus.buildCall(a, h.serial, h.flags, h.destination, h.path.?, rds.ConnectToEIS, .{@as([]const dbus.DictEntry([]const u8, dbus.Variant), &.{})}, &fds)
        else
            continue; // GetCurrentState: decoded above, not a member of the list
        testing.expectEqualSlices(u8, want, ours) catch |e| {
            std.debug.print("call {s} differs\n", .{member});
            return e;
        };
        compared += 1;
    }
    try testing.expectEqual(@as(usize, 9), compared);
}

test "typed reads of recorded replies: an object path, a variant, a descriptor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = try goldenMessages(a);
    var calls: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    var seen: usize = 0;
    for (msgs) |bytes| {
        const m = try parseGolden(a, bytes);
        if (m.header.kind == .call) try calls.put(a, m.header.serial, m.header.member.?);
        if (m.header.kind != .method_return) continue;
        const member = calls.get(m.header.reply_serial.?) orelse continue;
        if (std.mem.eql(u8, member, "CreateSession")) {
            const r = try m.read(struct { dbus.ObjectPath });
            try testing.expect(std.mem.startsWith(u8, r[0].path, "/org/gnome/Mutter/RemoteDesktop/Session/"));
            seen += 1;
        } else if (std.mem.eql(u8, member, "Get")) {
            const r = try m.read(struct { dbus.Variant });
            try testing.expect((try r[0].as([]const u8)).len > 0);
            seen += 1;
        } else if (std.mem.eql(u8, member, "ConnectToEIS")) {
            try testing.expectEqual(@as(u32, 1), m.header.unix_fds);
            seen += 1;
        } else if (std.mem.eql(u8, member, "GetConnectionUnixProcessID")) {
            try testing.expect((try m.read(struct { u32 }))[0] > 1);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 4), seen);
}

test "a reply whose signature is not the member's is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (try goldenMessages(a)) |bytes| {
        const m = try parseGolden(a, bytes);
        if (m.header.kind == .method_return and std.mem.eql(u8, m.header.signature, "o"))
            try testing.expectError(error.SignatureMismatch, m.read(struct { []const u8 }));
    }
}

// ---------------------------------------------------------------- corrupted messages

/// A valid reply with a string, a variant, a dict and a boolean.
fn sample(a: std.mem.Allocator, sig: []const u8, bytes: []const u8, fds: u32) ![]u8 {
    return dbus.encode(a, .{ .kind = .method_return, .flags = 1, .serial = 7, .reply_serial = 3, .destination = ":1.9", .signature = sig, .unix_fds = fds }, &.{ .unix_fds, .destination, .reply_serial, .signature }, bytes);
}

fn body(a: std.mem.Allocator, args: anytype) ![]const u8 {
    var fds: std.ArrayList(i32) = .empty;
    return dbus.encodeBody(a, args, &fds);
}

fn setU32(bytes: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], v, .little);
}

/// The offset of the body of an encoded message.
fn bodyAt(bytes: []const u8) usize {
    return 16 + std.mem.alignForward(usize, std.mem.readInt(u32, bytes[12..16], .little), 8);
}

test "twenty corrupted messages each close the connection with a typed error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Entry = dbus.DictEntry([]const u8, dbus.Variant);
    const good_body = try body(a, .{ @as([]const u8, "name"), try dbus.Variant.of(a, @as(u32, 5)), @as([]const Entry, &.{.{ .key = "k", .value = try dbus.Variant.of(a, @as([]const u8, "v")) }}), true });
    const good = try sample(a, "sva{sv}b", good_body, 0);

    var cases: std.ArrayList([]u8) = .empty;
    const C = struct {
        fn dup(al: std.mem.Allocator, b: []const u8) ![]u8 {
            return al.dupe(u8, b);
        }
    };
    const b0 = bodyAt(good);
    // 1 byte order
    var m = try C.dup(a, good);
    m[0] = 'X';
    try cases.append(a, m);
    // 2 protocol version
    m = try C.dup(a, good);
    m[3] = 2;
    try cases.append(a, m);
    // 3 message type 0, 4 type 9
    for ([_]u8{ 0, 9 }) |t| {
        m = try C.dup(a, good);
        m[1] = t;
        try cases.append(a, m);
    }
    // 5 serial 0
    m = try C.dup(a, good);
    setU32(m, 8, 0);
    try cases.append(a, m);
    // 6 body length beyond 128 MiB
    m = try C.dup(a, good);
    setU32(m, 4, 200 << 20);
    try cases.append(a, m);
    // 7 header fields longer than 64 MiB
    m = try C.dup(a, good);
    setU32(m, 12, 100 << 20);
    try cases.append(a, m);
    // 8 a header field signature that is no type ('u' of REPLY_SERIAL as 'z')
    m = try C.dup(a, good);
    if (std.mem.indexOf(u8, m[16..], &.{ 5, 1, 'u', 0 })) |i| m[16 + i + 2] = 'z';
    try cases.append(a, m);
    // 9 a header field of the wrong type (REPLY_SERIAL as 'i')
    m = try C.dup(a, good);
    if (std.mem.indexOf(u8, m[16..], &.{ 5, 1, 'u', 0 })) |i| m[16 + i + 2] = 'i';
    try cases.append(a, m);
    // 10 non-zero padding in the header
    m = try C.dup(a, good);
    m[b0 - 1] = 0xAA;
    try cases.append(a, m);
    // 11 a string without its NUL
    m = try C.dup(a, good);
    m[b0 + 4 + 4] = 'x';
    try cases.append(a, m);
    // 12 a string that is not UTF-8
    m = try C.dup(a, good);
    m[b0 + 4] = 0xFF;
    try cases.append(a, m);
    // 13 a boolean of 2 (last 4 bytes)
    m = try C.dup(a, good);
    m[m.len - 4] = 2;
    try cases.append(a, m);
    // 14 an array longer than the body
    m = try C.dup(a, good);
    // "name" takes 9 bytes, the variant's signature 3 and its u32 4: the
    // dict's length is at 16.
    setU32(m, b0 + 16, 0xFFFF);
    try cases.append(a, m);
    // 15 a variant whose signature is two types
    {
        const vb = try body(a, .{try dbus.Variant.of(a, @as(u32, 1))});
        m = try sample(a, "v", vb, 0);
        const at = bodyAt(m);
        m[at] = 2; // "\x02u?" : the NUL becomes a type code
        try cases.append(a, m);
    }
    // 16 a descriptor announced and never sent
    m = try sample(a, "h", try body(a, .{@as(u32, 0)}), 1);
    try cases.append(a, m);
    // 17 a reply without its reply serial
    m = try dbus.encode(a, .{ .kind = .method_return, .serial = 2, .signature = "u" }, &.{.signature}, try body(a, .{@as(u32, 1)}));
    try cases.append(a, m);
    // 18 a body shorter than its signature
    m = try sample(a, "uu", try body(a, .{@as(u32, 1)}), 0);
    try cases.append(a, m);
    // 19 variants nested deeper than 64
    {
        var v = try dbus.Variant.of(a, @as(u8, 1));
        for (0..70) |_| v = try dbus.Variant.of(a, v);
        m = try sample(a, "v", try body(a, .{v}), 0);
        try cases.append(a, m);
    }
    // 20 a body signature with a dict entry whose key is a variant
    m = try sample(a, "a{vs}", try body(a, .{@as(u32, 0)}), 0);
    try cases.append(a, m);
    try testing.expectEqual(@as(usize, 20), cases.items.len);

    for (cases.items, 0..) |bad, i| {
        const p = try sock.pair();
        defer _ = linux.close(p[1]);
        var c: dbus.Connection = .adopt(testing.allocator, p[0]);
        defer c.deinit();
        try sock.sendAll(p[1], bad, &.{});
        var msg_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer msg_arena.deinit();
        const got = c.next(msg_arena.allocator(), 1000);
        if (got) |_| {
            std.debug.print("corruption {d} accepted\n", .{i + 1});
            return error.TestUnexpectedResult;
        } else |e| try testing.expectEqual(error.Malformed, e);
        try testing.expect(c.fd < 0);
        try testing.expect(c.problem.len > 0);
        // A closed connection fails every call after it.
        try testing.expectError(error.Disconnected, c.call(msg_arena.allocator(), "x.y", "/", bus.Hello, .{}, 50));
    }
    // The good message itself is accepted, as the signal `next` hands out.
    const p = try sock.pair();
    defer _ = linux.close(p[1]);
    var c: dbus.Connection = .adopt(testing.allocator, p[0]);
    defer c.deinit();
    const good_signal = try dbus.encode(a, .{ .kind = .signal, .serial = 7, .path = "/org/neocompute/Test", .interface = "org.neocompute.Test", .member = "Good", .signature = "sva{sv}b" }, &.{ .path, .interface, .member, .signature }, good_body);
    try sock.sendAll(p[1], good_signal, &.{});
    var msg_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer msg_arena.deinit();
    _ = (try c.next(msg_arena.allocator(), 1000)).?;
}

// ---------------------------------------------------------------- a private bus

const PrivateBus = struct {
    tmp: std.testing.TmpDir,
    daemon: std.process.Child,
    address: []const u8,
    buf: [256]u8,

    fn start(self: *PrivateBus) !void {
        self.tmp = testing.tmpDir(.{});
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = dir_buf[0..try self.tmp.dir.realPath(testing.io, &dir_buf)];
        var conf_buf: [2048]u8 = undefined;
        const conf = try std.fmt.bufPrint(&conf_buf,
            \\<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
            \\ "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
            \\<busconfig>
            \\  <type>session</type>
            \\  <listen>unix:path={s}/bus</listen>
            \\  <auth>EXTERNAL</auth>
            \\  <policy context="default">
            \\    <allow send_destination="*" eavesdrop="true"/>
            \\    <allow eavesdrop="true"/>
            \\    <allow own="*"/>
            \\  </policy>
            \\</busconfig>
            \\
        , .{dir});
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "bus.conf", .data = conf });
        var arg_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const arg = try std.fmt.bufPrint(&arg_buf, "--config-file={s}/bus.conf", .{dir});
        self.daemon = try std.process.spawn(testing.io, .{ .argv = &.{ "dbus-daemon", "--nofork", "--nopidfile", arg }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        self.address = try std.fmt.bufPrint(&self.buf, "unix:path={s}/bus", .{dir});
        const deadline = sock.deadlineIn(5000).?;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/bus", .{dir}, 0);
        while (sock.nowNs() < deadline) {
            if (linux.errno(linux.access(path, 0)) == .SUCCESS) return;
            _ = linux.nanosleep(&.{ .sec = 0, .nsec = 10 * std.time.ns_per_ms }, null);
        }
        return error.DaemonDidNotStart;
    }

    fn stop(self: *PrivateBus) void {
        self.daemon.kill(testing.io);
        self.tmp.cleanup();
    }
};

const test_iface = "org.neocompute.Test";
const pipe_method: dbus.Method = .{ .interface = test_iface, .member = "Pipe", .in = "s", .out = "hs" };
const ping_signal: dbus.Signal = .{ .interface = test_iface, .member = "Ping", .signature = "a(ii)" };

test "Hello, a name, the pid of its owner, a signal by match rule and a descriptor through a private bus" {
    var b: PrivateBus = undefined;
    b.start() catch |e| if (e == error.FileNotFound) return error.SkipZigTest else return e;
    defer b.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var client = try dbus.Connection.open(testing.allocator, b.address, 2000);
    defer client.deinit();
    var service = try dbus.Connection.open(testing.allocator, b.address, 2000);
    defer service.deinit();
    try testing.expect(std.mem.startsWith(u8, client.uniqueName(), ":1."));
    try testing.expect(!std.mem.eql(u8, client.uniqueName(), service.uniqueName()));

    try testing.expect(try service.requestName(a, "org.neocompute.Peer", 1000));
    try testing.expectEqual(@as(u32, @intCast(linux.getpid())), try client.pidOf(a, "org.neocompute.Peer", 1000));
    try testing.expectEqualStrings(service.uniqueName(), (try client.ownerOf(a, "org.neocompute.Peer", 1000)).?);
    try testing.expect(try client.ownerOf(a, "org.neocompute.Nobody", 1000) == null);
    // A second owner is refused (no queueing).
    try testing.expect(!try client.requestName(a, "org.neocompute.Peer", 1000));

    // A signal reaches a connection whose rule matches it.
    try client.addMatch(a, "type='signal',interface='org.neocompute.Test',member='Ping'", 1000);
    const Pair = struct { i32, i32 };
    try service.emit(a, "/org/neocompute/Test", ping_signal, .{@as([]const Pair, &.{ .{ 1, 2 }, .{ 3, -4 } })});
    const sig = (try client.waitSignal(a, ping_signal, "/org/neocompute/Test", 2000)).?;
    const pairs = (try sig.read(struct { []const Pair }))[0];
    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqual(@as(i32, -4), pairs[1][1]);

    // A method call answered with a descriptor (SCM_RIGHTS), read by the
    // service from its inbox while the client waits in another thread.
    var pipe: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer sock.closeAll(&pipe);
    const Serve = struct {
        fn run(svc: *dbus.Connection, fd: i32) void {
            var sa: std.heap.ArenaAllocator = .init(testing.allocator);
            defer sa.deinit();
            // NameAcquired comes first: the call is the first call.
            const call = while (true) {
                const m = (svc.next(sa.allocator(), 2000) catch return) orelse return;
                if (m.header.kind == .call) break m;
            };
            const arg = (call.read(struct { []const u8 }) catch return)[0];
            svc.reply(sa.allocator(), call, .{ dbus.Fd{ .fd = fd }, arg }) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Serve.run, .{ &service, pipe[1] });
    const r = try client.callTyped(a, "org.neocompute.Peer", "/org/neocompute/Test", pipe_method, .{@as([]const u8, "echo")}, struct { dbus.Fd, []const u8 }, 2000);
    t.join();
    defer _ = linux.close(r[0].fd);
    try testing.expectEqualStrings("echo", r[1]);
    try testing.expect(linux.fcntl(r[0].fd, linux.F.GETFD, 0) & linux.FD_CLOEXEC != 0);
    // The descriptor is the pipe's write end: a byte through it arrives.
    try testing.expectEqual(@as(usize, 1), linux.write(r[0].fd, "z", 1));
    var one: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), linux.read(pipe[0], &one, 1));

    // An error reply names its error.
    try testing.expectError(error.RemoteError, client.call(a, "org.neocompute.Nobody", "/", bus.Hello, .{}, 1000));
    try testing.expect(std.mem.startsWith(u8, client.errorName(), "org.freedesktop.DBus.Error."));
}

test "a call to a peer stopped by SIGSTOP fails between 200 and 220 ms" {
    var b: PrivateBus = undefined;
    b.start() catch |e| if (e == error.FileNotFound) return error.SkipZigTest else return e;
    defer b.stop();
    var ready: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&ready, .{ .CLOEXEC = true })));
    defer sock.closeAll(&ready);
    const pid_rc = linux.fork();
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(pid_rc));
    if (pid_rc == 0) {
        // The peer: owns a name, says so, and never answers.
        var peer = dbus.Connection.open(std.heap.page_allocator, b.address, 2000) catch linux.exit_group(1);
        var pa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        _ = peer.requestName(pa.allocator(), "org.neocompute.Stopped", 1000) catch linux.exit_group(1);
        _ = linux.write(ready[1], "r", 1);
        while (true) _ = linux.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);
    }
    const pid: linux.pid_t = @intCast(pid_rc);
    defer {
        _ = linux.kill(pid, .KILL);
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
    }
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), linux.read(ready[0], &byte, 1));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.kill(pid, .STOP)));

    var client = try dbus.Connection.open(testing.allocator, b.address, 2000);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var worst: u64 = 0;
    for (0..5) |_| {
        const start = sock.nowNs();
        try testing.expectError(error.Timeout, client.call(arena.allocator(), "org.neocompute.Stopped", "/", props.GetAll, .{@as([]const u8, "x.y")}, 200));
        const took = sock.nowNs() - start;
        try testing.expect(took >= 200 * std.time.ns_per_ms);
        worst = @max(worst, took);
    }
    try testing.expect(worst < 220 * std.time.ns_per_ms);
    // The connection outlives a timeout.
    try testing.expect(client.fd >= 0);
    try testing.expectEqual(@as(u32, @intCast(linux.getpid())), try client.pidOf(arena.allocator(), client.uniqueName(), 1000));
}

test "a reply that comes after its call timed out is dropped, never handed out by next" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try sock.pair();
    defer _ = linux.close(p[1]);
    var c: dbus.Connection = .adopt(testing.allocator, p[0]);
    defer c.deinit();
    try testing.expectError(error.Timeout, c.call(a, "org.neocompute.Slow", "/", bus.Hello, .{}, 30));
    const late_serial = c.serial;
    // The peer answers late, then sends a signal; a second late reply
    // arrives while the client waits for a later call.
    const late = try dbus.encode(a, .{ .kind = .method_return, .serial = 40, .reply_serial = late_serial, .signature = "s" }, &.{ .reply_serial, .signature }, try body(a, .{@as([]const u8, ":1.5")}));
    const ping = try dbus.encode(a, .{ .kind = .signal, .serial = 41, .path = "/org/neocompute/Test", .interface = test_iface, .member = "Ping", .signature = "a(ii)" }, &.{ .path, .interface, .member, .signature }, try body(a, .{@as([]const struct { i32, i32 }, &.{})}));
    try sock.sendAll(p[1], late, &.{});
    try sock.sendAll(p[1], ping, &.{});
    const m = (try c.next(a, 1000)).?;
    try testing.expect(m.is(ping_signal));
    try testing.expect((try c.next(a, 30)) == null);

    try testing.expectError(error.Timeout, c.call(a, "org.neocompute.Slow", "/", bus.Hello, .{}, 30));
    const late2 = try dbus.encode(a, .{ .kind = .method_return, .serial = 42, .reply_serial = c.serial, .signature = "s" }, &.{ .reply_serial, .signature }, try body(a, .{@as([]const u8, ":1.6")}));
    const answer = try dbus.encode(a, .{ .kind = .method_return, .serial = 43, .reply_serial = c.serial + 1, .signature = "s" }, &.{ .reply_serial, .signature }, try body(a, .{@as([]const u8, ":1.7")}));
    try sock.sendAll(p[1], late2, &.{});
    try sock.sendAll(p[1], answer, &.{});
    const name = try c.callTyped(a, "org.neocompute.Slow", "/", bus.Hello, .{}, struct { []const u8 }, 1000);
    try testing.expectEqualStrings(":1.7", name[0]);
    // The late reply waited for nothing: it is not in the inbox.
    try testing.expectEqual(@as(usize, 0), c.inbox.items.len);
}
