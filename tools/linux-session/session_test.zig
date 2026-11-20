//! The launcher's own checks (US-074, US-075), run by `zig build test` on
//! a Linux host against the built tools/linux-session. Each starts real
//! sessions; a test whose family is not installed is skipped (code 77).

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const options = @import("test_options");

const Result = struct { code: u8, stderr: []const u8, stdout: []const u8 };

fn launcher(a: std.mem.Allocator, args: []const []const u8, stdin: ?[]const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ options.linux_session_exe, "--log-dir", ".zig-cache/linux-session-tests" });
    try argv.appendSlice(a, args);
    var child = try std.process.spawn(testing.io, .{ .argv = argv.items, .stdin = if (stdin != null) .pipe else .ignore, .stdout = .pipe, .stderr = .pipe });
    if (stdin) |bytes| {
        var wbuf: [256]u8 = undefined;
        var w = child.stdin.?.writerStreaming(testing.io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
        child.stdin.?.close(testing.io);
        child.stdin = null;
    }
    var mbuf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, testing.io, mbuf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    const term = try child.wait(testing.io);
    return .{
        .code = switch (term) {
            .exited => |c| c,
            else => 255,
        },
        .stdout = try mr.toOwnedSlice(0),
        .stderr = try mr.toOwnedSlice(1),
    };
}

fn skipWhenMissing(r: Result) !void {
    if (r.code == 77) {
        std.debug.print("skipped: {s}", .{r.stderr});
        return error.SkipZigTest;
    }
}

fn exists(p: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{p}, 0) catch return false;
    return linux.errno(linux.access(z, linux.F_OK)) == .SUCCESS;
}

/// The session id named by a journal path in a launcher message.
fn journalId(stderr: []const u8) ?[]const u8 {
    const key = "linux-session-tests/";
    const at = std.mem.indexOf(u8, stderr, key) orelse return null;
    const id = stderr[at + key.len ..];
    if (id.len < 6) return null;
    return id[0..6];
}

test "a file the session creates in /tmp is a difference: code 3 and its path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const marker = "/tmp/dbus-nc-witness-test";
    defer std.Io.Dir.cwd().deleteFile(testing.io, marker) catch {};
    const r = try launcher(a, &.{ "gnome", "exec", "--", "sh", "-c", "touch " ++ marker }, null);
    try skipWhenMissing(r);
    try testing.expectEqual(@as(u8, 3), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "apparu : " ++ marker) != null);
}

test "an inhibitor a process of the session takes on the real logind is a difference: code 3" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (!exists("/usr/bin/systemd-inhibit") or !exists("/run/dbus/system_bus_socket")) return error.SkipZigTest;
    // Past the fake system bus, as the gnome-shell of the audit's incident
    // (section 12): an idle inhibitor held 2 s, released with its holder.
    const r = try launcher(a, &.{ "gnome", "exec", "--", "sh", "-c", "DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket exec systemd-inhibit --what=idle --who=nc-witness-test --why=witness sleep 2" }, null);
    try skipWhenMissing(r);
    try testing.expectEqual(@as(u8, 3), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "pendant la session : inhibiteur logind idle (nc-witness-test") != null);
}

/// Binds a Unix socket at `path` and listens on it; the caller closes it.
fn bindSocket(path: []const u8) !i32 {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    var sa: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    @memcpy(sa.path[0..path.len], path);
    if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 1)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

test "a socket another program leaves in the real runtime folder during a session is noted, not a difference" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const started = try launcher(a, &.{ "start", "gnome" }, null);
    try skipWhenMissing(started);
    try testing.expectEqual(@as(u8, 0), started.code);
    const id = std.mem.trim(u8, started.stdout, "\n");
    var stopped = false;
    defer if (!stopped) {
        _ = launcher(a, &.{ "stop", id }, null) catch {};
    };
    // As a program of the real session that dies without removing its
    // socket: bound and listened to for 300 ms, then left behind.
    const stale = try std.fmt.allocPrint(a, "/run/user/{d}/nc-witness-foreign.sock", .{linux.getuid()});
    defer std.Io.Dir.cwd().deleteFile(testing.io, stale) catch {};
    const fd = try bindSocket(stale);
    try std.Io.sleep(testing.io, .fromMilliseconds(300), .awake);
    _ = linux.close(fd);
    const end = try launcher(a, &.{ "stop", id }, null);
    stopped = true;
    try testing.expectEqual(@as(u8, 0), end.code);
}

test "a socket a process of the session binds in the real runtime folder is a difference: code 3" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ours = try std.fmt.allocPrint(a, "/run/user/{d}/nc-witness-ours.sock", .{linux.getuid()});
    defer std.Io.Dir.cwd().deleteFile(testing.io, ours) catch {};
    const script = try std.fmt.allocPrint(a, "import socket, time; s = socket.socket(socket.AF_UNIX); s.bind('{s}'); s.listen(); time.sleep(1.5)", .{ours});
    const r = try launcher(a, &.{ "gnome", "exec", "--", "python3", "-I", "-c", script }, null);
    try skipWhenMissing(r);
    try testing.expectEqual(@as(u8, 3), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, try std.fmt.allocPrint(a, "tient {s}, apparu pendant la session", .{ours})) != null);
}

test "a compositor that never comes up: code 2, its journal, no difference, the runtime folder gone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try launcher(a, &.{ "--start-timeout-ms", "1500", "--test-compositor", "sleep 60", "gnome", "exec", "--", "true" }, null);
    try skipWhenMissing(r);
    try testing.expectEqual(@as(u8, 2), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "n'a pas démarré en 2 s : journal ") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "/compositor.log") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "témoin") == null);
    const id = journalId(r.stderr) orelse return error.NoJournal;
    try testing.expect(!exists(try std.fmt.allocPrint(a, "/run/user/{d}/nc-{s}", .{ linux.getuid(), id })));
}

test "a socket path over 107 bytes is refused before anything starts, naming the path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parent = "/tmp/nc-socket-path-test-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    const r = try launcher(a, &.{ "--runtime-parent", parent, "gnome", "exec", "--", "true" }, null);
    try skipWhenMissing(r);
    try testing.expectEqual(@as(u8, 2), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "Chemin de socket trop long") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, parent ++ "/nc-") != null);
    try testing.expect(!exists(parent));
}

test "a compositor absent from the system: code 77 and the message that names it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try launcher(arena.allocator(), &.{ "--test-compositor", "nc-no-such-compositor", "sway", "exec", "--", "true" }, null);
    try testing.expectEqual(@as(u8, 77), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "nc-no-such-compositor introuvable : installe-le ou saute cette famille.") != null);
}

test "start keeps a session, exec runs in it on the caller's streams with its code, stop ends it clean" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const started = try launcher(a, &.{ "start", "gnome" }, null);
    try skipWhenMissing(started);
    try testing.expectEqual(@as(u8, 0), started.code);
    const id = std.mem.trim(u8, started.stdout, "\n");
    try testing.expectEqual(@as(usize, 6), id.len);
    var stopped = false;
    defer if (!stopped) {
        _ = launcher(a, &.{ "stop", id }, null) catch {};
    };
    const rt = try std.fmt.allocPrint(a, "/run/user/{d}/nc-{s}", .{ linux.getuid(), id });
    try testing.expect(exists(rt));

    const ran = try launcher(a, &.{ "exec", id, "--", "sh", "-c", "read line; echo \"$line $NC_SESSION $XDG_RUNTIME_DIR $WAYLAND_DISPLAY\"; exit 7" }, "ping\n");
    try testing.expectEqual(@as(u8, 7), ran.code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "ping gnome {s} wayland-nc\n", .{rt}), ran.stdout);

    const end = try launcher(a, &.{ "stop", id }, null);
    stopped = true;
    try testing.expectEqual(@as(u8, 0), end.code);
    try testing.expect(!exists(rt));
}

test "in a gnome session the GTK 4 fixture and the Chrome page write the events real input gives them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try launcher(arena.allocator(), &.{ "gnome", "exec", "--", "python3", "-I", "tests/linux/fixture/smoke.py" }, null);
    try skipWhenMissing(r);
    if (r.code != 0) std.debug.print("{s}{s}", .{ r.stdout, r.stderr });
    try testing.expectEqual(@as(u8, 0), r.code);
    // smoke.py exits 0 only when every expected event of each fixture is
    // in its log.
    for ([_][]const u8{ "gtk : ", "decoy : ", "chrome : " }) |line| try testing.expect(std.mem.indexOf(u8, r.stdout, line) != null);
}

test "without PyGObject the fixture exits with 77 and says what to install" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // -S leaves out site-packages, where PyGObject lives.
    const r = try launcher(arena.allocator(), &.{ "sway", "exec", "--", "python3", "-I", "-S", "tests/linux/fixture/gtk_fixture.py" }, null);
    if (r.code == 77 and std.mem.indexOf(u8, r.stderr, "introuvable") != null) return error.SkipZigTest;
    try testing.expectEqual(@as(u8, 77), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "PyGObject et GTK 4 requis : installe python3-gobject et gtk4.") != null);
}
