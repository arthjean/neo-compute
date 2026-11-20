//! The control socket of a kept session (`start`, `exec`, `stop`).
//!
//! `exec <id> -- <command>` must give the command the caller's own
//! standard streams (the evals run `exec <id> -- neo-compute` as an MCP
//! server on stdio) while the command stays a descendant of the session's
//! launcher, so the witness watches it and `stop` kills it. The client
//! therefore sends its descriptors 0, 1 and 2 with the command line over a
//! `SOCK_SEQPACKET` Unix socket (`SCM_RIGHTS`); the launcher starts the
//! command on them, forwards the client's signals to it, answers its exit
//! code, and kills it when the client disappears.
//!
//! Messages, one packet each, first byte the kind:
//!   client: 'x' cwd NUL argv0 NUL argv1 ... (with three descriptors),
//!           's' signal number, 'q' stop the session
//!   launcher: 'p' pid, 'e' exit code, 'r' one line of the stop report,
//!             'f' a failure message

const std = @import("std");
const linux = std.os.linux;

pub const max_packet = 64 * 1024;

pub fn socketPath(buf: []u8, rt: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/nc/control", .{rt}, 0);
}

fn addr(p: []const u8) !linux.sockaddr.un {
    var sa: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (p.len >= sa.path.len) return error.NameTooLong;
    @memcpy(sa.path[0..p.len], p);
    return sa;
}

pub fn listen(p: [:0]const u8) !i32 {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    const sa = try addr(p);
    if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

pub fn connect(p: [:0]const u8) !i32 {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    const sa = try addr(p);
    if (linux.errno(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

pub fn accept(listen_fd: i32) ?i32 {
    const rc = linux.accept4(listen_fd, null, null, linux.SOCK.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

const Cmsg = extern struct {
    hdr: linux.cmsghdr,
    fds: [3]i32,
};

/// Sends one packet, with `fds` attached when given.
pub fn send(fd: i32, kind: u8, payload: []const u8, fds: ?[3]i32) !void {
    var head = [1]u8{kind};
    const iov = [_]std.posix.iovec_const{ .{ .base = &head, .len = 1 }, .{ .base = payload.ptr, .len = payload.len } };
    var cmsg: Cmsg = undefined;
    var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = iov.len, .control = null, .controllen = 0, .flags = 0 };
    if (fds) |f| {
        cmsg = .{ .hdr = .{ .len = @sizeOf(linux.cmsghdr) + @sizeOf([3]i32), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS }, .fds = f };
        msg.control = &cmsg;
        msg.controllen = @sizeOf(Cmsg);
    }
    const rc = linux.sendmsg(fd, &msg, linux.MSG.NOSIGNAL);
    if (linux.errno(rc) != .SUCCESS) return error.SendFailed;
}

pub const Packet = struct {
    kind: u8,
    payload: []const u8,
    /// The descriptors received with it, -1 when none.
    fds: [3]i32 = .{ -1, -1, -1 },
};

/// Receives one packet into `buf`; null at the end of the connection.
pub fn recv(fd: i32, buf: []u8) !?Packet {
    var iov = [_]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var cmsg: Cmsg align(@alignOf(linux.cmsghdr)) = undefined;
    var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &cmsg, .controllen = @sizeOf(Cmsg), .flags = 0 };
    const rc = linux.recvmsg(fd, &msg, linux.MSG.CMSG_CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.RecvFailed;
    if (rc == 0) return null;
    var p: Packet = .{ .kind = buf[0], .payload = buf[1..rc] };
    if (msg.controllen >= @sizeOf(Cmsg) and cmsg.hdr.level == linux.SOL.SOCKET and cmsg.hdr.type == linux.SCM.RIGHTS) p.fds = cmsg.fds;
    return p;
}

const testing = std.testing;

test "a packet carries three descriptors across a socket pair" {
    var pair: [2]i32 = undefined;
    try testing.expect(linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0, &pair)) == .SUCCESS);
    defer for (pair) |f| {
        _ = linux.close(f);
    };
    try send(pair[0], 'x', "/tmp\x00true", .{ 0, 1, 2 });
    var buf: [256]u8 = undefined;
    const p = (try recv(pair[1], &buf)).?;
    try testing.expectEqual(@as(u8, 'x'), p.kind);
    try testing.expectEqualStrings("/tmp\x00true", p.payload);
    for (p.fds) |f| {
        try testing.expect(f > 2);
        _ = linux.close(f);
    }
    _ = linux.close(pair[0]);
    pair[0] = -1;
    try testing.expect(try recv(pair[1], &buf) == null);
}
