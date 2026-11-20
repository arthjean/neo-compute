//! Unix stream sockets shared by the native transports (D-Bus, Wayland,
//! EI): connection, file descriptors passed with `SCM_RIGHTS`, and waits
//! bounded by a monotonic deadline. Every descriptor received is
//! close-on-exec (`MSG_CMSG_CLOEXEC`): an application started later never
//! inherits a copy, which would keep an EIS context alive past `Stop`
//! (audit 4.1).

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ ConnectFailed, PathTooLong, Disconnected, Timeout, TooManyFds, Interrupted };

/// Most descriptors one message carries or one read takes.
pub const max_fds = 16;

pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// The deadline `ms` from now, in `nowNs` time; null waits forever.
pub fn deadlineIn(ms: ?u32) ?u64 {
    return if (ms) |m| nowNs() + @as(u64, m) * std.time.ns_per_ms else null;
}

/// Connects to a unix socket: a path, or an abstract name.
pub fn connectUnix(path: []const u8, abstract: bool) Error!i32 {
    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    const off: usize = if (abstract) 1 else 0;
    if (path.len + off >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[off..][0..path.len], path);
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ConnectFailed;
    const fd: i32 = @intCast(rc);
    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + off + path.len + @intFromBool(!abstract));
    if (linux.errno(linux.connect(fd, &addr, len)) != .SUCCESS) {
        _ = linux.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

/// A connected pair, for tests and peers in the same process.
pub fn pair() Error![2]i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS) return error.ConnectFailed;
    return fds;
}

const Control = extern struct {
    hdr: linux.cmsghdr,
    fds: [max_fds]i32,
};

/// Sends all of `bytes`, with `fds` attached to the first byte.
pub fn sendAll(fd: i32, bytes: []const u8, fds: []const i32) Error!void {
    if (fds.len > max_fds) return error.TooManyFds;
    var sent: usize = 0;
    var first = true;
    while (sent < bytes.len or (first and fds.len > 0)) {
        var iov = [1]std.posix.iovec_const{.{ .base = bytes[sent..].ptr, .len = bytes.len - sent }};
        var ctl: Control = undefined;
        var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
        if (first and fds.len > 0) {
            ctl.hdr = .{ .len = @sizeOf(linux.cmsghdr) + fds.len * @sizeOf(i32), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
            @memcpy(ctl.fds[0..fds.len], fds);
            msg.control = &ctl;
            msg.controllen = std.mem.alignForward(usize, ctl.hdr.len, linux.cmsg_align);
        }
        const rc = linux.sendmsg(fd, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => continue,
            else => return error.Disconnected,
        }
        first = false;
        sent += rc;
    }
}

/// Reads what is there into `buf` and the descriptors that came with it
/// into `fds_out`, waiting until `deadline` for the first byte. Returns
/// the byte count; 0 never (a closed peer is `Disconnected`).
pub fn recvSome(fd: i32, buf: []u8, fds_out: *std.ArrayList(i32), gpa: std.mem.Allocator, deadline: ?u64) (Error || error{OutOfMemory})!usize {
    try waitReadable(fd, deadline);
    var iov = [1]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var ctl: Control align(@alignOf(linux.cmsghdr)) = undefined;
    var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &ctl, .controllen = @sizeOf(Control), .flags = 0 };
    while (true) {
        const rc = linux.recvmsg(fd, &msg, linux.MSG.CMSG_CLOEXEC | linux.MSG.DONTWAIT);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            .AGAIN => {
                try waitReadable(fd, deadline);
                continue;
            },
            else => return error.Disconnected,
        }
        if (msg.controllen >= @sizeOf(linux.cmsghdr) and ctl.hdr.level == linux.SOL.SOCKET and ctl.hdr.type == linux.SCM.RIGHTS) {
            const n = (ctl.hdr.len - @sizeOf(linux.cmsghdr)) / @sizeOf(i32);
            try fds_out.appendSlice(gpa, ctl.fds[0..@min(n, max_fds)]);
        }
        if (rc == 0) return error.Disconnected;
        return rc;
    }
}

/// Waits until `fd` can be read, or fails with `Timeout` at `deadline`.
pub fn waitReadable(fd: i32, deadline: ?u64) Error!void {
    while (true) {
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        var ts: linux.timespec = undefined;
        var tsp: ?*linux.timespec = null;
        if (deadline) |d| {
            const now = nowNs();
            if (now >= d) return error.Timeout;
            const left = d - now;
            ts = .{ .sec = @intCast(left / std.time.ns_per_s), .nsec = @intCast(left % std.time.ns_per_s) };
            tsp = &ts;
        }
        const rc = linux.ppoll(&pfd, 1, tsp, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Disconnected,
        }
        if (rc == 0) continue; // the deadline check above ends the wait
        if (pfd[0].revents & linux.POLL.IN != 0) return;
        if (pfd[0].revents & (linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL) != 0) return error.Disconnected;
    }
}

pub fn closeAll(fds: []const i32) void {
    for (fds) |f| if (f >= 0) {
        _ = linux.close(f);
    };
}

const testing = std.testing;

test "descriptors cross a socket pair, close-on-exec on arrival" {
    const p = try pair();
    defer closeAll(&p);
    const pipe = blk: {
        var fds: [2]i32 = undefined;
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{})));
        break :blk fds;
    };
    defer closeAll(&pipe);
    try sendAll(p[0], "hello", &.{pipe[0]});
    var fds: std.ArrayList(i32) = .empty;
    defer fds.deinit(testing.allocator);
    var buf: [16]u8 = undefined;
    const n = try recvSome(p[1], &buf, &fds, testing.allocator, deadlineIn(1000));
    try testing.expectEqualStrings("hello", buf[0..n]);
    try testing.expectEqual(@as(usize, 1), fds.items.len);
    defer closeAll(fds.items);
    const flags = linux.fcntl(fds.items[0], linux.F.GETFD, 0);
    try testing.expect(flags & linux.FD_CLOEXEC != 0);
}

test "a wait ends at its deadline" {
    const p = try pair();
    defer closeAll(&p);
    const start = nowNs();
    try testing.expectError(error.Timeout, waitReadable(p[0], deadlineIn(30)));
    const took = nowNs() - start;
    try testing.expect(took >= 30 * std.time.ns_per_ms and took < 60 * std.time.ns_per_ms);
}
