//! Processes of a test session: spawning with a private environment,
//! reaping (the launcher is a child subreaper, so every orphan of the
//! session comes back to it), the descendant tree read from `/proc`, and
//! the environment a process started with.

const std = @import("std");
const linux = std.os.linux;

/// Reads a small file (a `/proc` entry reports a size of 0, so it is read
/// to the end) into `buf`; null when it cannot be opened or read.
pub fn readSmall(path: []const u8, buf: []u8) ?[]u8 {
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return null;
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = linux.read(fd, buf[len..].ptr, buf.len - len);
        if (linux.errno(n) != .SUCCESS) return null;
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

/// Reads a whole file to its end, at most `limit` bytes. A `/proc` file
/// reports a size of 0, and `std.Io.Dir.readFileAlloc` reads none of it.
pub fn readAll(a: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0);
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    while (true) {
        if (out.items.len >= limit) return error.FileTooBig;
        try out.ensureUnusedCapacity(a, 64 * 1024);
        const room = @min(out.unusedCapacitySlice().len, limit - out.items.len);
        const n = linux.read(fd, out.unusedCapacitySlice().ptr, room);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) return out.toOwnedSlice(a);
        out.items.len += n;
    }
}

/// The value of `key` in the environment `pid` was started with (its
/// `/proc/<pid>/environ`), copied into `out`; null when absent or
/// unreadable (another user's process).
pub fn environValue(pid: i32, key: []const u8, scratch: []u8, out: []u8) ?[]const u8 {
    var pbuf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/proc/{d}/environ", .{pid}) catch return null;
    const data = readSmall(path, scratch) orelse return null;
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |kv| {
        if (kv.len > key.len and std.mem.startsWith(u8, kv, key) and kv[key.len] == '=') {
            const v = kv[key.len + 1 ..];
            if (v.len > out.len) return null;
            @memcpy(out[0..v.len], v);
            return out[0..v.len];
        }
    }
    return null;
}

/// The parent of `pid` (field 4 of `/proc/<pid>/stat`), null when gone.
pub fn parentOf(pid: i32) ?i32 {
    var pbuf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/proc/{d}/stat", .{pid}) catch return null;
    var buf: [1024]u8 = undefined;
    const stat = readSmall(path, &buf) orelse return null;
    // The command name may hold spaces and parentheses: the fields
    // start after the last ')'.
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    _ = it.next() orelse return null; // state
    const ppid = it.next() orelse return null;
    return std.fmt.parseInt(i32, ppid, 10) catch null;
}

/// The command name of `pid` (`/proc/<pid>/comm`), copied into `out`.
pub fn commOf(pid: i32, out: []u8) []const u8 {
    var pbuf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/proc/{d}/comm", .{pid}) catch return "?";
    const c = readSmall(path, out) orelse return "?";
    return std.mem.trimEnd(u8, c, "\n");
}

/// Every pid of `/proc`, the caller's own included.
pub fn allPids(gpa: std.mem.Allocator, io: std.Io) ![]i32 {
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(gpa);
    var dir = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const pid = std.fmt.parseInt(i32, e.name, 10) catch continue;
        try list.append(gpa, pid);
    }
    return list.toOwnedSlice(gpa);
}

/// The descendants of `root` (not `root` itself), read from the parent
/// links of every process at this instant.
pub fn descendants(gpa: std.mem.Allocator, io: std.Io, root: i32) ![]i32 {
    const pids = try allPids(gpa, io);
    defer gpa.free(pids);
    const parents = try gpa.alloc(i32, pids.len);
    defer gpa.free(parents);
    for (pids, parents) |p, *pp| pp.* = parentOf(p) orelse -1;
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, root);
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        const parent = out.items[i];
        for (pids, parents) |p, pp| if (pp == parent and p != root) try out.append(gpa, p);
    }
    const result = try gpa.dupe(i32, out.items[1..]);
    out.deinit(gpa);
    return result;
}

pub fn alive(pid: i32) bool {
    // A zombie still answers kill(0): ask /proc for its state.
    var pbuf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/proc/{d}/stat", .{pid}) catch return false;
    var buf: [512]u8 = undefined;
    const stat = readSmall(path, &buf) orelse return false;
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
    return !(close + 2 < stat.len and (stat[close + 2] == 'Z' or stat[close + 2] == 'X'));
}

/// Exit statuses collected by `reap`, by pid.
pub const Reaper = struct {
    statuses: std.AutoHashMapUnmanaged(i32, u32) = .empty,

    /// Collects every child that has exited, orphans of the session
    /// included, without blocking.
    pub fn reap(r: *Reaper, gpa: std.mem.Allocator) void {
        while (true) {
            var status: i32 = 0;
            const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return;
            r.statuses.put(gpa, @intCast(rc), @bitCast(status)) catch {};
        }
    }

    /// The status of `pid` once it has exited, consumed.
    pub fn take(r: *Reaper, pid: i32) ?u32 {
        const kv = r.statuses.fetchRemove(pid) orelse return null;
        return kv.value;
    }

    pub fn deinit(r: *Reaper, gpa: std.mem.Allocator) void {
        r.statuses.deinit(gpa);
    }
};

/// A shell exit code for a wait status: the code, or 128 plus the signal.
pub fn exitCode(status: u32) u8 {
    if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
    if (linux.W.IFSIGNALED(status)) return @truncate(128 + @backingInt(linux.W.TERMSIG(status)));
    return 1;
}

pub const Stdio = union(enum) { inherit, file: std.Io.File, ignore };

/// Starts `argv` with exactly `env` as its environment (the session starts
/// from `env -i`), in `cwd` when given. Returns its pid; the caller reaps
/// it through a `Reaper`.
pub fn spawn(io: std.Io, argv: []const []const u8, env: *const std.process.Environ.Map, cwd: ?[]const u8, stdin: Stdio, stdout: Stdio, stderr: Stdio) !i32 {
    const conv = struct {
        fn of(s: Stdio) std.process.SpawnOptions.StdIo {
            return switch (s) {
                .inherit => .inherit,
                .ignore => .ignore,
                .file => |f| .{ .file = f },
            };
        }
    };
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .stdin = conv.of(stdin),
        .stdout = conv.of(stdout),
        .stderr = conv.of(stderr),
    });
    return child.id.?;
}

/// The absolute path of `name`: itself when it holds a slash, else the
/// first executable match in `path` (a colon-separated list).
pub fn which(buf: []u8, path: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const z = std.fmt.bufPrintSentinel(buf, "{s}", .{name}, 0) catch return null;
        if (linux.errno(linux.access(z, linux.X_OK)) != .SUCCESS) return null;
        return z;
    }
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const z = std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (linux.errno(linux.access(z, linux.X_OK)) == .SUCCESS) return z;
    }
    return null;
}

const testing = std.testing;

test "a process's parent and environment are read from /proc" {
    const me = linux.getpid();
    try testing.expect(parentOf(me) != null);
    try testing.expect(alive(me));
    var scratch: [256 * 1024]u8 = undefined;
    var out: [4096]u8 = undefined;
    // PATH is set in any test environment.
    try testing.expect(environValue(me, "PATH", &scratch, &out) != null);
    try testing.expect(environValue(me, "NC_NO_SUCH_VARIABLE_HERE", &scratch, &out) == null);
}

test "a /proc file that reports a size of 0 is read to its end" {
    const data = try readAll(testing.allocator, "/proc/self/mountinfo", 16 * 1024 * 1024);
    defer testing.allocator.free(data);
    // Every process has a root mount: a line whose mount point is "/".
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    const root = while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        for (0..4) |_| _ = f.next();
        if (std.mem.eql(u8, f.next() orelse "", "/")) break true;
    } else false;
    try testing.expect(root);
}

test "exit codes of wait statuses" {
    try testing.expectEqual(@as(u8, 3), exitCode(3 << 8));
    try testing.expectEqual(@as(u8, 128 + 9), exitCode(9));
}
