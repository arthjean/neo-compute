//! The single instance of a Linux server (US-072, FR-14): an exclusive
//! `flock` on `$XDG_RUNTIME_DIR/neo-compute/<display>.lock`, the display
//! being `WAYLAND_DISPLAY`, else `DISPLAY`. The descriptor stays open for
//! the life of the process and the kernel drops the lock with it, SIGKILL
//! included, so a stale lock file never blocks the next server. A server of
//! another display takes its own lock.

const std = @import("std");
const linux = std.os.linux;
const Instance = @import("core").mcp.Instance;

pub const no_runtime_dir = "XDG_RUNTIME_DIR absent : impossible de garantir une seule instance. Lance neo-compute depuis une session graphique.";

/// The lock of this process, kept open on purpose.
var held: i32 = -1;

/// `<display>.lock`, a path display (`WAYLAND_DISPLAY` may be absolute)
/// flattened to one file name.
pub fn lockName(buf: []u8, display: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (display) |c| w.writeByte(if (c == '/') '_' else c) catch return null;
    w.writeAll(".lock") catch return null;
    return w.buffered();
}

/// The display as libwayland resolves it: an absolute `WAYLAND_DISPLAY`
/// inside the runtime folder names the socket `wayland-0` names, so both
/// spellings take the same lock.
pub fn displayKey(runtime: []const u8, display: []const u8) []const u8 {
    const dir = std.mem.trimEnd(u8, runtime, "/");
    if (display.len > dir.len + 1 and std.mem.startsWith(u8, display, dir) and display[dir.len] == '/')
        return display[dir.len + 1 ..];
    return display;
}

pub fn acquire(env: *const std.process.Environ.Map) Instance {
    const runtime = env.get("XDG_RUNTIME_DIR") orelse return .{ .refused = no_runtime_dir };
    if (runtime.len == 0 or runtime[0] != '/') return .{ .refused = no_runtime_dir };
    const display = displayKey(runtime, env.get("WAYLAND_DISPLAY") orelse env.get("DISPLAY") orelse "no-display");
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/neo-compute", .{runtime}, 0) catch return .{ .refused = no_runtime_dir };
    // Readable by the user alone, like the runtime folder itself.
    _ = linux.mkdir(dir, 0o700);
    var name_buf: [256]u8 = undefined;
    const name = lockName(&name_buf, display) orelse return .{ .refused = no_runtime_dir };
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ dir, name }, 0) catch return .{ .refused = no_runtime_dir };
    const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return .{ .refused = no_runtime_dir };
    const fd: i32 = @intCast(rc);
    if (linux.errno(linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB)) != .SUCCESS) {
        _ = linux.close(fd);
        return .second;
    }
    held = fd;
    return .exclusive;
}

const testing = std.testing;

test "the lock file of a display, a path display flattened" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("wayland-0.lock", lockName(&buf, "wayland-0").?);
    try testing.expectEqualStrings("_run_user_1000_wayland-1.lock", lockName(&buf, "/run/user/1000/wayland-1").?);
    try testing.expectEqualStrings(":0.lock", lockName(&buf, ":0").?);
}

test "an absolute WAYLAND_DISPLAY in the runtime folder takes the lock of its socket name" {
    try testing.expectEqualStrings("wayland-0", displayKey("/run/user/1000", "/run/user/1000/wayland-0"));
    try testing.expectEqualStrings("wayland-0", displayKey("/run/user/1000/", "/run/user/1000/wayland-0"));
    try testing.expectEqualStrings("wayland-0", displayKey("/run/user/1000", "wayland-0"));
    // Elsewhere, or a sibling folder, keeps its own name.
    try testing.expectEqualStrings("/tmp/wayland-0", displayKey("/run/user/1000", "/tmp/wayland-0"));
    try testing.expectEqualStrings("/run/user/10000/wayland-0", displayKey("/run/user/1000", "/run/user/10000/wayland-0"));
    try testing.expectEqualStrings(":0", displayKey("/run/user/1000", ":0"));
}
