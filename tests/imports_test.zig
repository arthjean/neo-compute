//! Module boundaries of the source tree (US-069): no file of src/core/
//! imports a file of src/backend/, and the Linux backend (src/backend/linux.zig
//! and linux/) and the Windows backend (src/backend/windows.zig and windows/)
//! import nothing of each other, by file or by module name. The compiler
//! already refuses a module's file import outside its directory; this check
//! names the offending file for every case, the two backends included, whose
//! root files share src/backend/. Runs from the repository root.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Side = enum { core, windows, linux, backend, other };

fn sideOf(path: []const u8) Side {
    if (std.mem.startsWith(u8, path, "src/core/")) return .core;
    if (std.mem.eql(u8, path, "src/backend/windows.zig") or std.mem.startsWith(u8, path, "src/backend/windows/")) return .windows;
    if (std.mem.eql(u8, path, "src/backend/linux.zig") or std.mem.startsWith(u8, path, "src/backend/linux/")) return .linux;
    if (std.mem.startsWith(u8, path, "src/backend/")) return .backend;
    return .other;
}

/// The side a module name stands for, as build.zig names the modules.
fn moduleSide(name: []const u8) Side {
    for ([_][]const u8{ "backend_windows", "win32", "texts_windows" }) |m| if (std.mem.eql(u8, name, m)) return .windows;
    for ([_][]const u8{ "backend_linux", "texts_linux" }) |m| if (std.mem.eql(u8, name, m)) return .linux;
    return .other;
}

/// Why `from` may not import `to`, or null when it may.
fn forbidden(from: Side, to: Side, to_file: bool) ?[]const u8 {
    return switch (from) {
        .core => if (to_file and (to == .windows or to == .linux or to == .backend))
            "src/core/ imports no file of src/backend/"
        else if (!to_file and (to == .windows or to == .linux))
            "src/core/ imports no backend module"
        else
            null,
        .linux => if (to == .windows) "the Linux backend imports nothing of the Windows backend" else null,
        .windows => if (to == .linux) "the Windows backend imports nothing of the Linux backend" else null,
        else => null,
    };
}

/// `path` relative to the repository root, with `..` and `.` resolved.
fn resolve(buf: []u8, dir: []const u8, rel: []const u8) ?[]const u8 {
    var parts: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, dir, '/');
    while (it.next()) |p| : (n += 1) parts[n] = p;
    var rt = std.mem.tokenizeScalar(u8, rel, '/');
    while (rt.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (n == 0) return null;
            n -= 1;
            continue;
        }
        parts[n] = p;
        n += 1;
    }
    var w: Io.Writer = .fixed(buf);
    for (parts[0..n], 0..) |p, i| {
        if (i > 0) w.writeByte('/') catch return null;
        w.writeAll(p) catch return null;
    }
    return w.buffered();
}

/// Writes one line per forbidden import of `source` (the file at `path`)
/// and returns how many there are.
fn checkFile(path: []const u8, source: []const u8, out: *Io.Writer) !usize {
    const from = sideOf(path);
    if (from == .other or from == .backend) return 0;
    const dir = std.fs.path.dirname(path) orelse "";
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        // Comments may name a file without importing it.
        const line = if (std.mem.indexOf(u8, raw, "//")) |c| raw[0..c] else raw;
        var rest = line;
        while (std.mem.indexOf(u8, rest, "@import(\"")) |at| {
            rest = rest[at + "@import(\"".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const name = rest[0..end];
            rest = rest[end..];
            var buf: [512]u8 = undefined;
            const is_file = std.mem.endsWith(u8, name, ".zig");
            const to: Side = if (is_file) sideOf(resolve(&buf, dir, name) orelse continue) else moduleSide(name);
            if (forbidden(from, to, is_file)) |why| {
                try out.print("{s} imports \"{s}\": {s}\n", .{ path, name, why });
                count += 1;
            }
        }
    }
    return count;
}

/// Checks every .zig file under `root`/src and returns the number of
/// forbidden imports, each named on `out`.
fn checkTree(gpa: std.mem.Allocator, io: Io, root: Io.Dir, out: *Io.Writer) !usize {
    var src = try root.openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.mem.concat(gpa, u8, &.{ "src/", entry.path });
        defer gpa.free(path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 << 20));
        defer gpa.free(source);
        count += try checkFile(path, source, out);
    }
    return count;
}

test "no file of src/core/ imports src/backend/, and neither backend imports the other" {
    var buf: [16 * 1024]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    const count = try checkTree(testing.allocator, testing.io, Io.Dir.cwd(), &out);
    if (count > 0) std.debug.print("{s}", .{out.buffered()});
    try testing.expectEqual(@as(usize, 0), count);
}

test "each forbidden import is reported with the file that makes it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "src/core/a.zig", "const fake = @import(\"../backend/fake.zig\");\n// @import(\"../backend/windows.zig\") in a comment\n" },
        .{ "src/core/b.zig", "const w = @import(\"backend_windows\");\nconst ok = @import(\"display.zig\");\n" },
        .{ "src/backend/linux/x.zig", "const y = @import(\"../windows/y.zig\");\nconst c = @import(\"core\");\n" },
        .{ "src/backend/linux.zig", "const w = @import(\"win32\");\nconst x = @import(\"linux/x.zig\");\n" },
        .{ "src/backend/windows.zig", "const z = @import(\"linux/z.zig\");\nconst u = @import(\"windows/uia.zig\");\n" },
        .{ "src/backend/fake.zig", "const c = @import(\"core\");\n" },
    };
    for (files) |f| {
        try tmp.dir.createDirPath(io, std.fs.path.dirname(f[0]).?);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    var buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    const count = try checkTree(testing.allocator, io, tmp.dir, &out);
    try testing.expectEqual(@as(usize, 5), count);
    const report = out.buffered();
    for ([_][]const u8{
        "src/core/a.zig imports \"../backend/fake.zig\": src/core/ imports no file of src/backend/",
        "src/core/b.zig imports \"backend_windows\": src/core/ imports no backend module",
        "src/backend/linux/x.zig imports \"../windows/y.zig\": the Linux backend imports nothing of the Windows backend",
        "src/backend/linux.zig imports \"win32\": the Linux backend imports nothing of the Windows backend",
        "src/backend/windows.zig imports \"linux/z.zig\": the Windows backend imports nothing of the Linux backend",
    }) |want| {
        if (std.mem.indexOf(u8, report, want) == null) {
            std.debug.print("missing: {s}\nreport:\n{s}", .{ want, report });
            return error.TestExpectedEqual;
        }
    }
}

/// The environment variables and folders of an OS are the backend's
/// (US-070): none of their names appears in src/core/.
const os_names = [_][]const u8{ "APPDATA", "LOCALAPPDATA", "XDG_", "HOME" };

test "src/core/ names no environment variable of an OS" {
    const io = testing.io;
    var core = try Io.Dir.cwd().openDir(io, "src/core", .{ .iterate = true });
    defer core.close(io);
    var walker = try core.walk(testing.allocator);
    defer walker.deinit();
    var found: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const source = try entry.dir.readFileAlloc(io, entry.basename, testing.allocator, .limited(4 << 20));
        defer testing.allocator.free(source);
        for (os_names) |name| if (std.mem.indexOf(u8, source, name) != null) {
            std.debug.print("src/core/{s} contains `{s}`: the backend gives OS paths and variables\n", .{ entry.path, name });
            found += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), found);
}
