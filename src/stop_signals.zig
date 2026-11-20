//! The stop signals of a Linux server (US-072, PRD T15). Claude Code stops
//! a Linux MCP server with SIGINT, then SIGTERM 100 ms later and SIGKILL
//! 400 ms after that; a terminal that closes sends SIGHUP. Each of the three
//! writes one byte to a pipe and returns: a signal handler may only make
//! async-signal-safe calls (`signal-safety(7)`), while releasing input goes
//! through sockets and the server's state. The dispatcher watches the read
//! end (`Server.serveUntil`) and stops the way it stops at the end of
//! stdin, so there is one release path.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

var pipe_write: i32 = -1;
/// The last stop signal received, 0 before any.
var received: std.atomic.Value(u32) = .init(0);

fn onSignal(sig: posix.SIG) callconv(.c) void {
    received.store(@backingInt(sig), .release);
    const byte = [1]u8{'s'};
    // Async-signal-safe: one raw write, its result ignored (a full pipe
    // already holds a stop).
    _ = linux.write(pipe_write, &byte, 1);
}

/// Installs the handlers and returns the pipe's read end, or null when the
/// pipe cannot be made (the server then stops at the end of stdin only).
pub fn install() ?std.Io.File {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
    pipe_write = fds[1];
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    for ([_]posix.SIG{ .INT, .TERM, .HUP }) |sig| posix.sigaction(sig, &act, null);
    return .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
}

/// The name of the signal that stopped the server, for stderr.
pub fn name() []const u8 {
    return switch (received.load(.acquire)) {
        @backingInt(posix.SIG.INT) => "SIGINT",
        @backingInt(posix.SIG.TERM) => "SIGTERM",
        @backingInt(posix.SIG.HUP) => "SIGHUP",
        else => "a stop signal",
    };
}
