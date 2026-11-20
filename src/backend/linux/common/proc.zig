//! The identity of a Linux process for the policy (US-070, decision 0014
//! D8), from three sources: the application id in its systemd cgroup
//! (`app-<launcher>-<id>-<n>.scope`, `app-flatpak-<id>-<n>.scope`), the
//! Flatpak id in `/proc/<pid>/root/.flatpak-info`, and the base name of
//! `/proc/<pid>/exe`. Never `/proc/<pid>/comm`: the kernel cuts it to 15
//! bytes and the process may rewrite it.

const std = @import("std");

/// The application id of a cgroup file (`/proc/<pid>/cgroup`): its unified
/// (`0::`) path ends in an application scope, or null. The systemd XDG
/// convention names it `app[-<launcher>]-<id>-<random>.scope`, `-` within
/// the id escaped as `\x2d`. A launcher has no dot where a reverse-DNS id
/// has some; a dotless id (`app-gnome-paneflow-6352.scope`) follows a
/// launcher.
pub fn appIdFromCgroup(arena: std.mem.Allocator, cgroup: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, cgroup, '\n');
    const path = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) break line[3..];
    } else return null;
    const unit = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return null) + 1 ..];
    if (!std.mem.startsWith(u8, unit, "app-") or !std.mem.endsWith(u8, unit, ".scope")) return null;
    const body = unit["app-".len .. unit.len - ".scope".len];
    // The random part after the last `-`.
    const cut = std.mem.lastIndexOfScalar(u8, body, '-') orelse return null;
    if (cut == 0 or !allDigitsOrHex(body[cut + 1 ..])) return null;
    var named = body[0..cut];
    // A launcher before the id: a first dash-separated word without a dot,
    // when something follows it.
    if (std.mem.indexOfScalar(u8, named, '-')) |dash| {
        if (std.mem.indexOfScalar(u8, named[0..dash], '.') == null and dash + 1 < named.len) named = named[dash + 1 ..];
    }
    if (named.len == 0) return null;
    return unescape(arena, named);
}

fn allDigitsOrHex(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// systemd's unit name escaping: `\xNN` stands for the byte NN.
fn unescape(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, "\\x") == null) return arena.dupe(u8, text) catch null;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 4 <= text.len and text[i] == '\\' and text[i + 1] == 'x') {
            if (std.fmt.parseInt(u8, text[i + 2 .. i + 4], 16)) |byte| {
                out.append(arena, byte) catch return null;
                i += 4;
                continue;
            } else |_| {}
        }
        out.append(arena, text[i]) catch return null;
        i += 1;
    }
    return out.items;
}

/// The `name` of the `[Application]` group of a `.flatpak-info` file.
pub fn flatpakIdFromInfo(info: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, info, '\n');
    var in_application = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            in_application = std.mem.eql(u8, line, "[Application]");
            continue;
        }
        if (!in_application) continue;
        if (std.mem.startsWith(u8, line, "name=")) {
            const id = std.mem.trim(u8, line["name=".len..], " \t");
            return if (id.len > 0) id else null;
        }
    }
    return null;
}

/// The base name of an executable path read from `/proc/<pid>/exe`,
/// without the ` (deleted)` the kernel adds once the file is replaced.
pub fn exeBaseName(target: []const u8) []const u8 {
    const path = if (std.mem.endsWith(u8, target, " (deleted)")) target[0 .. target.len - " (deleted)".len] else target;
    return std.fs.path.basename(path);
}

/// The base name of `/proc/<pid>/exe`, null when the process is gone or
/// belongs to another user.
pub fn exeName(arena: std.mem.Allocator, io: std.Io, pid: u32) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&path_buf, "/proc/{d}/exe", .{pid}) catch return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(io, link, &buf) catch return null;
    return arena.dupe(u8, exeBaseName(buf[0..n])) catch null;
}

fn readProc(arena: std.mem.Allocator, io: std.Io, pid: u32, comptime rest: []const u8) ?[]const u8 {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/" ++ rest, .{pid}) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch null;
}

/// The first 64 KiB of the regular file at `path`, or null. Opened without
/// blocking and checked before any read: `/proc/<pid>/root/` is the
/// process's own root, so a process in a mount namespace of its own chooses
/// what `.flatpak-info` is there, a FIFO that would block the dispatcher
/// included.
fn readRegular(arena: std.mem.Allocator, path: [:0]const u8) ?[]const u8 {
    const linux = std.os.linux;
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &st)) != .SUCCESS) return null;
    if (!st.mask.TYPE or !linux.S.ISREG(st.mode)) return null;
    const buf = arena.alloc(u8, 64 * 1024) catch return null;
    var len: usize = 0;
    while (len < buf.len) {
        const n = linux.read(fd, buf[len..].ptr, buf.len - len);
        if (linux.errno(n) != .SUCCESS) return null;
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

/// The `.flatpak-info` of the process's root, a regular file only.
fn flatpakInfo(arena: std.mem.Allocator, pid: u32) ?[]const u8 {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/root/.flatpak-info", .{pid}, 0) catch return null;
    return readRegular(arena, path);
}

/// Every name of the process `pid` for the policy, its executable first
/// (the name the audit log shows), then its application id and its
/// Flatpak id when it has them and they differ. Empty when the process is
/// gone.
pub fn names(arena: std.mem.Allocator, io: std.Io, pid: u32) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (exeName(arena, io, pid)) |exe| out.append(arena, exe) catch return out.items;
    const app = if (readProc(arena, io, pid, "cgroup")) |c| appIdFromCgroup(arena, c) else null;
    const flatpak = if (flatpakInfo(arena, pid)) |i| flatpakIdFromInfo(i) else null;
    for ([_]?[]const u8{ app, flatpak }) |maybe| if (maybe) |n| {
        for (out.items) |have| {
            if (std.ascii.eqlIgnoreCase(have, n)) break;
        } else out.append(arena, n) catch return out.items;
    };
    return out.items;
}

const testing = std.testing;

test "the application id of a cgroup, with or without a launcher, escapes undone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-paneflow-6352.scope\n", "paneflow" },
        .{ "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-org.gnome.Terminal-4021.scope\n", "org.gnome.Terminal" },
        .{ "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-org.keepassxc.KeePassXC-12.scope\n", "org.keepassxc.KeePassXC" },
        .{ "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.kde.konsole-7a3f.scope\n", "org.kde.konsole" },
        .{ "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-proton\\x2dpass-881.scope\n", "proton-pass" },
        .{ "12:pids:/x\n0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-neocompute-com.mitchellh.ghostty-3.scope\n", "com.mitchellh.ghostty" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], appIdFromCgroup(a, c[0]).?);
    // A terminal tab, a session scope, a service: no application id.
    for ([_][]const u8{
        "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.gnome.Terminal.slice/vte-spawn-2c1e5d0f-9f5a-4b2e-8f0a-1d2c3b4a5e6f.scope\n",
        "0::/user.slice/user-1000.slice/session-2.scope\n",
        "0::/system.slice/sshd.service\n",
        "",
    }) |c| try testing.expectEqual(@as(?[]const u8, null), appIdFromCgroup(a, c));
}

test "the Flatpak id of a .flatpak-info file" {
    try testing.expectEqualStrings("org.keepassxc.KeePassXC", flatpakIdFromInfo("[Application]\nname=org.keepassxc.KeePassXC\nruntime=runtime/org.kde.Platform\n\n[Instance]\ninstance-id=1\n").?);
    try testing.expectEqual(@as(?[]const u8, null), flatpakIdFromInfo("[Instance]\nname=nope\n"));
}

test "a FIFO in place of .flatpak-info is refused without blocking, a regular file is read" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fifo = try std.fmt.allocPrintSentinel(a, "{s}/.flatpak-info", .{dir}, 0);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mknodat(std.os.linux.AT.FDCWD, fifo, std.os.linux.S.IFIFO | 0o600, 0)));
    // No writer ever opens it: a blocking open or read would hang here.
    try testing.expectEqual(@as(?[]const u8, null), readRegular(a, fifo));
    try tmp.dir.writeFile(io, .{ .sub_path = "info", .data = "[Application]\nname=org.keepassxc.KeePassXC\n" });
    const file = try std.fmt.allocPrintSentinel(a, "{s}/info", .{dir}, 0);
    try testing.expectEqualStrings("org.keepassxc.KeePassXC", flatpakIdFromInfo(readRegular(a, file).?).?);
    try testing.expectEqual(@as(?[]const u8, null), readRegular(a, "/nonexistent/.flatpak-info"));
}

test "the executable base name, a replaced file included" {
    try testing.expectEqualStrings("keepassxc", exeBaseName("/usr/bin/keepassxc"));
    try testing.expectEqualStrings("Proton Pass", exeBaseName("/usr/lib/proton-pass/Proton Pass (deleted)"));
}
