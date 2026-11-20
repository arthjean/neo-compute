//! The witness of the real session (US-074, audit section 12). Before and
//! after each test session it reads what the audit's incidents changed:
//! the logind sessions of the user (`LockedHint`, `State`) and the logind
//! inhibitors, the entries and mounts of `/run/user/<uid>`, and the D-Bus
//! and X11 files of `/tmp`. During the session it checks every second that
//! no process of the session started with the real `HOME` or
//! `XDG_RUNTIME_DIR` or holds an inhibitor of the real logind, and that no
//! process carrying the private runtime folder left the session's tree.
//!
//! `/run/user/<uid>` changes on its own while the user works (a terminal
//! pane opens a socket, closes it). An entry that appears or disappears is
//! therefore judged by who holds it: a socket bound at its path, an open
//! descriptor on it or under it, or a `flock` on it. The session's
//! processes are all dead when the after snapshot is taken, so an entry
//! that appeared and that a live process holds belongs to someone else;
//! an entry that disappeared while another process held it went with its
//! holder, unless that holder still listens on it or still has it open,
//! which only an unlink by a third process explains. An entry that
//! appears and that nobody holds is a difference. One that disappears
//! while nobody held it (a stale socket a program sweeps up) carried no
//! live state of the real session: it is noted, not counted. Mounts,
//! logind and `/tmp` are compared strictly.

const std = @import("std");
const linux = std.os.linux;
const proc = @import("proc.zig");

pub const Real = struct {
    uid: u32,
    /// The user's real `HOME`.
    home: []const u8,
    /// The user's real `XDG_RUNTIME_DIR`, `/run/user/<uid>` by default.
    runtime: []const u8,
    /// `/run/user/<uid>`, the folder whose entries are compared.
    run_user: []const u8,
};

const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    inode: u64,
    /// Pids holding it when the snapshot was taken.
    holders: []const i32,
    /// The socket inodes bound at its path or under it.
    sockets: []const u64,
};

const Inhibitor = struct { line: []const u8, pid: u32 };

pub const Snapshot = struct {
    logind: []const []const u8 = &.{},
    logind_error: ?[]const u8 = null,
    inhibitors: []const Inhibitor = &.{},
    entries: []const Entry = &.{},
    mounts: []const []const u8 = &.{},
    tmp: []const []const u8 = &.{},
};

/// Who holds what under the runtime folder at one instant.
const Holders = struct {
    /// Socket inode bound at a path under `run_user`, by path.
    bound: std.StringHashMapUnmanaged(std.ArrayList(u64)) = .empty,
    /// Pids holding each socket inode.
    socket_pids: std.AutoHashMapUnmanaged(u64, std.ArrayList(i32)) = .empty,
    /// Open descriptors under `run_user`: path to pids. A deleted file
    /// keeps its path with the kernel's " (deleted)" suffix.
    paths: std.StringHashMapUnmanaged(std.ArrayList(i32)) = .empty,
    /// `flock` and POSIX locks: inode to pids.
    locks: std.AutoHashMapUnmanaged(u64, std.ArrayList(i32)) = .empty,

    fn add(comptime K: type, map: anytype, a: std.mem.Allocator, key: K, value: anytype) !void {
        const gop = try map.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, value);
    }

    fn read(a: std.mem.Allocator, io: std.Io, real: Real) !Holders {
        var h: Holders = .{};
        // Sockets bound under the folder.
        const unix = try proc.readAll(a, "/proc/net/unix", 64 * 1024 * 1024);
        var lines = std.mem.splitScalar(u8, unix, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            var col: usize = 0;
            var inode: u64 = 0;
            var path: ?[]const u8 = null;
            while (f.next()) |tok| : (col += 1) {
                if (col == 6) inode = std.fmt.parseInt(u64, tok, 10) catch 0;
                if (col == 7) path = tok;
            }
            const p = path orelse continue;
            if (!under(p, real.run_user)) continue;
            try add([]const u8, &h.bound, a, p, inode);
        }
        // Descriptors of every process the user can read.
        const pids = try proc.allPids(a, io);
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (pids) |pid| {
            var dbuf: [64]u8 = undefined;
            const dpath = std.fmt.bufPrint(&dbuf, "/proc/{d}/fd", .{pid}) catch continue;
            var dir = std.Io.Dir.openDirAbsolute(io, dpath, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |e| {
                var lbuf: [96]u8 = undefined;
                const lpath = std.fmt.bufPrintSentinel(&lbuf, "/proc/{d}/fd/{s}", .{ pid, e.name }, 0) catch continue;
                const rc = linux.readlink(lpath, &link_buf, link_buf.len);
                if (linux.errno(rc) != .SUCCESS) continue;
                const target = link_buf[0..rc];
                if (std.mem.startsWith(u8, target, "socket:[")) {
                    const ino = std.fmt.parseInt(u64, std.mem.trim(u8, target["socket:[".len..], "]"), 10) catch continue;
                    try add(u64, &h.socket_pids, a, ino, pid);
                } else if (under(target, real.run_user)) {
                    try add([]const u8, &h.paths, a, try a.dupe(u8, target), pid);
                }
            }
        }
        // Locks: "1: FLOCK  ADVISORY  WRITE 3934 00:3a:12345 0 EOF".
        if (proc.readAll(a, "/proc/locks", 4 * 1024 * 1024)) |locks| {
            var ll = std.mem.splitScalar(u8, locks, '\n');
            while (ll.next()) |line| {
                var f = std.mem.tokenizeScalar(u8, line, ' ');
                var col: usize = 0;
                var pid: i32 = 0;
                var ino: u64 = 0;
                while (f.next()) |tok| : (col += 1) {
                    if (std.mem.eql(u8, tok, "->")) break; // a waiter
                    if (col == 4) pid = std.fmt.parseInt(i32, tok, 10) catch 0;
                    if (col == 5) if (std.mem.lastIndexOfScalar(u8, tok, ':')) |c| {
                        ino = std.fmt.parseInt(u64, tok[c + 1 ..], 10) catch 0;
                    };
                }
                if (pid > 0 and ino > 0) try add(u64, &h.locks, a, ino, pid);
            }
        } else |_| {}
        return h;
    }

    /// Pids holding `full` (a path under the folder) or anything under it.
    fn of(h: *const Holders, a: std.mem.Allocator, full: []const u8, inode: u64) !struct { pids: []const i32, sockets: []const u64 } {
        var pids: std.ArrayList(i32) = .empty;
        var sockets: std.ArrayList(u64) = .empty;
        var bit = h.bound.iterator();
        while (bit.next()) |kv| if (sameOrUnder(kv.key_ptr.*, full)) for (kv.value_ptr.items) |ino| {
            try sockets.append(a, ino);
            if (h.socket_pids.get(ino)) |ps| try pids.appendSlice(a, ps.items);
        };
        var pit = h.paths.iterator();
        while (pit.next()) |kv| if (sameOrUnder(kv.key_ptr.*, full)) try pids.appendSlice(a, kv.value_ptr.items);
        if (h.locks.get(inode)) |ps| try pids.appendSlice(a, ps.items);
        return .{ .pids = pids.items, .sockets = sockets.items };
    }
};

fn under(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

fn sameOrUnder(path: []const u8, entry: []const u8) bool {
    return std.mem.eql(u8, path, entry) or under(path, entry);
}

/// The runtime folder of a test session, `nc-` and six characters of
/// `[a-z0-9]`: sessions running beside this one change only those. Any
/// other name, `nc-` prefix or not, is compared.
pub fn ownedBySessions(name: []const u8) bool {
    if (name.len != 9 or !std.mem.startsWith(u8, name, "nc-")) return false;
    for (name[3..]) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) return false;
    return true;
}

fn busctl(a: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "busctl", "--system", "--json=short" });
    try argv.appendSlice(a, args);
    const r = try std.process.run(a, io, .{ .argv = argv.items, .stdout_limit = .limited(4 * 1024 * 1024), .stderr_limit = .limited(64 * 1024) });
    if (r.term != .exited or r.term.exited != 0) return error.BusctlFailed;
    return r.stdout;
}

const Json = std.json.Value;

fn readLogind(a: std.mem.Allocator, io: std.Io, uid: u32, s: *Snapshot) !void {
    const mgr = &[_][]const u8{ "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager" };
    const sessions = try std.json.parseFromSliceLeaky(Json, a, try busctl(a, io, &.{ "call", mgr[0], mgr[1], mgr[2], "ListSessions" }), .{});
    var lines: std.ArrayList([]const u8) = .empty;
    for (sessions.object.get("data").?.array.items[0].array.items) |row| {
        const f = row.array.items;
        if (f[1].integer != uid) continue;
        const path = f[4].string;
        const props = try busctl(a, io, &.{ "get-property", mgr[0], path, "org.freedesktop.login1.Session", "LockedHint", "State" });
        var pl = std.mem.tokenizeScalar(u8, props, '\n');
        const locked = try std.json.parseFromSliceLeaky(Json, a, pl.next() orelse return error.BusctlFailed, .{});
        const state = try std.json.parseFromSliceLeaky(Json, a, pl.next() orelse return error.BusctlFailed, .{});
        try lines.append(a, try std.fmt.allocPrint(a, "session logind {s} : LockedHint={} State={s}", .{ f[0].string, locked.object.get("data").?.bool, state.object.get("data").?.string }));
    }
    s.logind = lines.items;
    s.inhibitors = try readInhibitors(a, io);
}

fn readInhibitors(a: std.mem.Allocator, io: std.Io) ![]const Inhibitor {
    const inh = try std.json.parseFromSliceLeaky(Json, a, try busctl(a, io, &.{ "call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "ListInhibitors" }), .{});
    var inhibitors: std.ArrayList(Inhibitor) = .empty;
    for (inh.object.get("data").?.array.items[0].array.items) |row| {
        const f = row.array.items;
        try inhibitors.append(a, .{
            .line = try std.fmt.allocPrint(a, "inhibiteur logind {s} ({s}, {s}) : {s}, pid {d}", .{ f[0].string, f[1].string, f[3].string, f[2].string, f[5].integer }),
            .pid = @intCast(f[5].integer),
        });
    }
    return inhibitors.items;
}

/// `\040`-style escapes of `/proc/self/mountinfo`, decoded.
fn unescape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 3 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 4], 8)) |c| {
                try out.append(a, c);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(a, s[i]);
    }
    return out.items;
}

pub fn snapshot(a: std.mem.Allocator, io: std.Io, real: Real) !Snapshot {
    var s: Snapshot = .{};
    readLogind(a, io, real.uid, &s) catch |err| {
        s.logind_error = try std.fmt.allocPrint(a, "logind illisible par busctl ({t})", .{err});
    };

    // The entries first, then their holders: an entry created while the
    // holders were read would otherwise be listed with none.
    var entries: std.ArrayList(Entry) = .empty;
    {
        var dir = try std.Io.Dir.openDirAbsolute(io, real.run_user, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind == .directory and ownedBySessions(e.name)) continue;
            try entries.append(a, .{ .name = try a.dupe(u8, e.name), .kind = e.kind, .inode = e.inode, .holders = &.{}, .sockets = &.{} });
        }
    }
    const holders = try Holders.read(a, io, real);
    for (entries.items) |*e| {
        const h = try holders.of(a, try std.fs.path.join(a, &.{ real.run_user, e.name }), e.inode);
        e.holders = h.pids;
        e.sockets = h.sockets;
    }
    s.entries = entries.items;

    var mounts: std.ArrayList([]const u8) = .empty;
    const info = try proc.readAll(a, "/proc/self/mountinfo", 16 * 1024 * 1024);
    var ml = std.mem.splitScalar(u8, info, '\n');
    while (ml.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        var col: usize = 0;
        var point: []const u8 = "";
        while (f.next()) |tok| : (col += 1) {
            if (col == 4) point = try unescape(a, tok);
            if (std.mem.eql(u8, tok, "-")) break;
        }
        const fstype = f.next() orelse continue;
        if (!sameOrUnder(point, real.run_user)) continue;
        // A mount anywhere in a test session's runtime folder is its own.
        if (under(point, real.run_user)) {
            const rel = point[real.run_user.len + 1 ..];
            if (ownedBySessions(rel[0 .. std.mem.indexOfScalar(u8, rel, '/') orelse rel.len])) continue;
        }
        try mounts.append(a, try std.fmt.allocPrint(a, "montage {s} ({s})", .{ point, fstype }));
    }
    s.mounts = mounts.items;

    var tmp: std.ArrayList([]const u8) = .empty;
    for ([_][3][]const u8{ .{ "/tmp", "dbus-", "" }, .{ "/tmp", ".X", "-lock" }, .{ "/tmp/.X11-unix", "X", "" } }) |pat| {
        var d = std.Io.Dir.openDirAbsolute(io, pat[0], .{ .iterate = true }) catch continue;
        defer d.close(io);
        var di = d.iterate();
        while (try di.next(io)) |e| {
            if (std.mem.startsWith(u8, e.name, pat[1]) and std.mem.endsWith(u8, e.name, pat[2]))
                try tmp.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ pat[0], e.name }));
        }
    }
    s.tmp = tmp.items;
    return s;
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn findEntry(list: []const Entry, name: []const u8) ?Entry {
    for (list) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

/// Pids of processes that took part in the session, seen by the live scan.
pub const SessionPids = std.AutoHashMapUnmanaged(i32, void);

/// Entries created in `/run/user/<uid>` while the session runs, judged
/// the moment they appear (inotify): another program of the real session
/// may create one and die without removing it, so that nobody holds it
/// any more by the after snapshot. An entry a process outside the session
/// held when it appeared is that process's; one a process of the session
/// held is a difference at once.
pub const Watch = struct {
    fd: i32 = -1,
    /// Names held by a process outside the session when they appeared.
    foreign: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(real: Real) Watch {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return .{};
        const fd: i32 = @intCast(rc);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{real.run_user}, 0) catch {
            _ = linux.close(fd);
            return .{};
        };
        if (linux.errno(linux.inotify_add_watch(fd, z, linux.IN.CREATE | linux.IN.MOVED_TO | linux.IN.ONLYDIR)) != .SUCCESS) {
            _ = linux.close(fd);
            return .{};
        }
        return .{ .fd = fd };
    }

    pub fn deinit(w: *Watch) void {
        if (w.fd >= 0) _ = linux.close(w.fd);
        w.fd = -1;
    }

    /// Judges the entries created since the last call. Cheap when none
    /// was: one read that does not block.
    pub fn poll(w: *Watch, a: std.mem.Allocator, io: std.Io, real: Real, root: i32, out: *std.ArrayList([]const u8)) void {
        if (w.fd < 0) return;
        const gpa = std.heap.page_allocator;
        var scratch_arena: std.heap.ArenaAllocator = .init(gpa);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();
        var names: std.ArrayList([]const u8) = .empty;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const n = linux.read(w.fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                off += @sizeOf(linux.inotify_event) + ev.len;
                const name = ev.getName() orelse continue;
                if (ownedBySessions(name)) continue;
                names.append(scratch, scratch.dupe(u8, name) catch continue) catch {};
            }
        }
        if (names.items.len == 0) return;
        const holders = Holders.read(scratch, io, real) catch return;
        const desc = proc.descendants(gpa, io, root) catch return;
        defer gpa.free(desc);
        var comm: [64]u8 = undefined;
        for (names.items) |name| {
            const full = std.fs.path.join(scratch, &.{ real.run_user, name }) catch continue;
            const h = holders.of(scratch, full, 0) catch continue;
            const ours: ?i32 = for (h.pids) |pid| {
                if (pid == root or std.mem.indexOfScalar(i32, desc, pid) != null) break pid;
            } else null;
            if (ours) |pid| {
                const line = std.fmt.allocPrint(a, "pendant la session : pid {d} ({s}) tient {s}, apparu pendant la session", .{ pid, proc.commOf(pid, &comm), full }) catch continue;
                if (!containsStr(out.items, line)) out.append(a, line) catch {};
            } else if (h.pids.len > 0) {
                w.foreign.put(a, a.dupe(u8, name) catch continue, {}) catch {};
            }
        }
    }
};

/// The differences between two snapshots, one French line each, appended
/// to `out`. `after` is read after the session's processes died.
pub fn compare(a: std.mem.Allocator, io: std.Io, real: Real, before: Snapshot, after: Snapshot, session_pids: *const SessionPids, watch: *const Watch, out: *std.ArrayList([]const u8), notes: *std.ArrayList([]const u8)) !void {
    if (before.logind_error orelse after.logind_error) |e| try out.append(a, e);
    for (before.logind) |l| if (!containsStr(after.logind, l)) try out.append(a, try std.fmt.allocPrint(a, "avant : {s}", .{l}));
    for (after.logind) |l| if (!containsStr(before.logind, l)) try out.append(a, try std.fmt.allocPrint(a, "après : {s}", .{l}));
    // An inhibitor is taken by a process and dies with it: one of the
    // session's processes is the only kind the witness can blame.
    for (after.inhibitors) |inh| {
        if (session_pids.contains(@intCast(inh.pid))) try out.append(a, try std.fmt.allocPrint(a, "apparu : {s} (processus de la session)", .{inh.line}));
    }
    for (before.mounts) |m| if (!containsStr(after.mounts, m)) try out.append(a, try std.fmt.allocPrint(a, "disparu : {s}", .{m}));
    for (after.mounts) |m| if (!containsStr(before.mounts, m)) try out.append(a, try std.fmt.allocPrint(a, "apparu : {s}", .{m}));
    for (before.tmp) |t| if (!containsStr(after.tmp, t)) try out.append(a, try std.fmt.allocPrint(a, "disparu : {s}", .{t}));
    for (after.tmp) |t| if (!containsStr(before.tmp, t)) try out.append(a, try std.fmt.allocPrint(a, "apparu : {s}", .{t}));

    // The holders now, for the entries that went away.
    const now = try Holders.read(a, io, real);
    for (before.entries) |old| {
        const new = findEntry(after.entries, old.name);
        if (new != null and new.?.inode == old.inode) continue;
        const full = try std.fs.path.join(a, &.{ real.run_user, old.name });
        if (old.holders.len == 0) {
            try notes.append(a, try std.fmt.allocPrint(a, "disparu : {s} (aucun processus ne le tenait : pas d'état vivant de la session réelle)", .{full}));
            continue;
        }
        if (try goneUnexplained(a, &now, full, old)) |why|
            try out.append(a, try std.fmt.allocPrint(a, "disparu : {s} ({s})", .{ full, why }));
    }
    for (after.entries) |new| {
        const old = findEntry(before.entries, new.name);
        if (old != null and old.?.inode == new.inode) continue;
        if (new.holders.len > 0) continue;
        const full = try std.fs.path.join(a, &.{ real.run_user, new.name });
        // The session's processes are dead: only a process outside it can
        // have removed it since the after snapshot.
        if (!exists(full)) {
            try notes.append(a, try std.fmt.allocPrint(a, "apparu puis retiré : {s} (par un processus hors de la session)", .{full}));
            continue;
        }
        if (watch.foreign.contains(new.name)) {
            try notes.append(a, try std.fmt.allocPrint(a, "apparu : {s} (tenu par un processus hors de la session quand il est apparu)", .{full}));
            continue;
        }
        try out.append(a, try std.fmt.allocPrint(a, "apparu : {s} (aucun processus ne le tient)", .{full}));
    }
}

/// Why an entry that disappeared is a difference, or null when its holder
/// took it away.
fn goneUnexplained(a: std.mem.Allocator, now: *const Holders, full: []const u8, old: Entry) !?[]const u8 {
    // A socket still listened to lost its path to someone else.
    for (old.sockets) |ino| if (now.socket_pids.get(ino)) |ps| {
        return try std.fmt.allocPrint(a, "pid {d} écoute encore ce socket", .{ps.items[0]});
    };
    // A file still open under its deleted name.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const deleted = std.fmt.bufPrint(&buf, "{s} (deleted)", .{full}) catch return null;
    if (now.paths.get(deleted)) |ps| return try std.fmt.allocPrint(a, "pid {d} l'a encore ouvert", .{ps.items[0]});
    return null;
}

/// The live check, run every second during the session: no descendant of
/// `root` started with the real `HOME` or `XDG_RUNTIME_DIR` or holds an
/// inhibitor of the real logind, and every process that carries the
/// private runtime folder is a descendant.
/// Records each pid it saw in `session_pids`; appends new violations
/// (once per pid) to `out`.
pub fn live(a: std.mem.Allocator, io: std.Io, real: Real, root: i32, private_runtime: []const u8, session_pids: *SessionPids, reported: *SessionPids, out: *std.ArrayList([]const u8)) !void {
    const gpa = std.heap.page_allocator;
    const desc = try proc.descendants(gpa, io, root);
    defer gpa.free(desc);
    const scratch = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(scratch);
    var value: [4096]u8 = undefined;
    var comm: [64]u8 = undefined;
    for (desc) |pid| {
        try session_pids.put(a, pid, {});
        if (reported.contains(pid)) continue;
        const home = proc.environValue(pid, "HOME", scratch, &value);
        if (home != null and std.mem.eql(u8, home.?, real.home)) {
            try reported.put(a, pid, {});
            try out.append(a, try std.fmt.allocPrint(a, "pendant la session : pid {d} ({s}) a le HOME réel {s}", .{ pid, proc.commOf(pid, &comm), real.home }));
            continue;
        }
        const rt = proc.environValue(pid, "XDG_RUNTIME_DIR", scratch, &value);
        if (rt != null and std.mem.eql(u8, rt.?, real.runtime)) {
            try reported.put(a, pid, {});
            try out.append(a, try std.fmt.allocPrint(a, "pendant la session : pid {d} ({s}) a le XDG_RUNTIME_DIR réel {s}", .{ pid, proc.commOf(pid, &comm), real.runtime }));
        }
    }
    // An inhibitor of the real logind dies with the process that took it
    // (audit 12: a gnome-shell that reached the real system bus took one
    // and let it go), so only a read while the session runs can blame one
    // of its processes. A logind that cannot be read is already reported
    // by the snapshots.
    {
        var scratch_arena: std.heap.ArenaAllocator = .init(gpa);
        defer scratch_arena.deinit();
        if (readInhibitors(scratch_arena.allocator(), io)) |inhibitors| {
            for (inhibitors) |inh| {
                if (std.mem.indexOfScalar(i32, desc, @intCast(inh.pid)) == null) continue;
                const line = try std.fmt.allocPrint(a, "pendant la session : {s} (processus de la session)", .{inh.line});
                if (!containsStr(out.items, line)) try out.append(a, line);
            }
        } else |_| {}
    }
    // Escapes: the private folder outside the tree.
    const all = try proc.allPids(gpa, io);
    defer gpa.free(all);
    for (all) |pid| {
        if (pid == root or session_pids.contains(pid) or reported.contains(pid)) continue;
        const rt = proc.environValue(pid, "XDG_RUNTIME_DIR", scratch, &value) orelse continue;
        if (!std.mem.eql(u8, rt, private_runtime)) continue;
        // It may have been born since the tree was read.
        if (!proc.alive(pid) or isDescendant(pid, root)) continue;
        try reported.put(a, pid, {});
        try out.append(a, try std.fmt.allocPrint(a, "pendant la session : pid {d} ({s}) porte le XDG_RUNTIME_DIR de la session hors de son arbre", .{ pid, proc.commOf(pid, &comm) }));
    }
}

fn isDescendant(pid: i32, root: i32) bool {
    var p = pid;
    var hops: usize = 0;
    while (hops < 4096) : (hops += 1) {
        const parent = proc.parentOf(p) orelse return false;
        if (parent == root) return true;
        if (parent <= 1) return false;
        p = parent;
    }
    return false;
}

/// After the session: no process left carries `NC_SESSION` with the
/// session's runtime folder, or with a test runtime folder that no longer
/// exists (an orphan of an earlier session).
pub fn leftovers(a: std.mem.Allocator, io: std.Io, private_runtime: []const u8, out: *std.ArrayList([]const u8)) !void {
    const gpa = std.heap.page_allocator;
    const all = try proc.allPids(gpa, io);
    defer gpa.free(all);
    const scratch = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(scratch);
    var value: [4096]u8 = undefined;
    var rtv: [4096]u8 = undefined;
    var comm: [64]u8 = undefined;
    const me = linux.getpid();
    for (all) |pid| {
        if (pid == me) continue;
        const family = proc.environValue(pid, "NC_SESSION", scratch, &value) orelse continue;
        if (!proc.alive(pid)) continue;
        const rt = proc.environValue(pid, "XDG_RUNTIME_DIR", scratch, &rtv) orelse "";
        const ours = std.mem.eql(u8, rt, private_runtime);
        const orphan = !ours and !exists(rt);
        if (ours or orphan) try out.append(a, try std.fmt.allocPrint(a, "après la session : pid {d} ({s}) porte NC_SESSION={s} ({s})", .{
            pid, proc.commOf(pid, &comm), family,
            if (ours) "cette session" else "dossier d'exécution supprimé",
        }));
    }
}

fn exists(path: []const u8) bool {
    if (path.len == 0) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return false;
    return linux.errno(linux.access(z, linux.F_OK)) == .SUCCESS;
}

const testing = std.testing;

test "mountinfo escapes are decoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/run/user/1000/a b", try unescape(arena.allocator(), "/run/user/1000/a\\040b"));
}

test "only a session's runtime folder name is left out of the comparison" {
    try testing.expect(ownedBySessions("nc-ab12cd"));
    try testing.expect(!ownedBySessions("nc-monitor.txt"));
    try testing.expect(!ownedBySessions("nc-AB12CD"));
    try testing.expect(!ownedBySessions("nc-ab12c"));
}

test "paths under a folder" {
    try testing.expect(under("/run/user/1000/bus", "/run/user/1000"));
    try testing.expect(!under("/run/user/10000/bus", "/run/user/1000"));
    try testing.expect(sameOrUnder("/run/user/1000/doc", "/run/user/1000/doc"));
    try testing.expect(sameOrUnder("/run/user/1000/doc/x", "/run/user/1000/doc"));
    try testing.expect(!sameOrUnder("/run/user/1000/docs", "/run/user/1000/doc"));
}

test "the snapshot lists the real mounts under the runtime folder" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_user = try std.fmt.allocPrint(a, "/run/user/{d}", .{linux.getuid()});
    const info = try proc.readAll(a, "/proc/self/mountinfo", 16 * 1024 * 1024);
    const needle = try std.fmt.allocPrint(a, " {s}/", .{run_user});
    // The document portal's FUSE folder, on a desktop that runs one.
    if (std.mem.indexOf(u8, info, needle) == null) return error.SkipZigTest;
    const s = try snapshot(a, testing.io, .{ .uid = linux.getuid(), .home = "", .runtime = run_user, .run_user = run_user });
    try testing.expect(s.mounts.len > 0);
}
