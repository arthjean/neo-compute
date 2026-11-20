//! XDG base directories of the Linux server (US-070, decision 0014 D8):
//! the policy in `$XDG_CONFIG_HOME/neo-compute/policy.json`, the audit log
//! in `$XDG_STATE_HOME/neo-compute/audit.jsonl`, each with its default
//! under `$HOME` when the variable is absent, empty or not absolute (the
//! XDG Base Directory specification ignores a relative path).

const std = @import("std");
const audit = @import("core").audit;

/// `$<variable>` when it is an absolute path, else `$HOME/<fallback>`;
/// null without either.
fn base(arena: std.mem.Allocator, env: *const std.process.Environ.Map, variable: []const u8, fallback: []const u8) !?[]const u8 {
    if (env.get(variable)) |v| if (std.fs.path.isAbsolute(v)) return v;
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(arena, &.{ home, fallback });
}

pub fn policyPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    const dir = try base(arena, env, "XDG_CONFIG_HOME", ".config") orelse return null;
    return try std.fs.path.join(arena, &.{ dir, "neo-compute", "policy.json" });
}

pub fn auditDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    const dir = try base(arena, env, "XDG_STATE_HOME", ".local/state") orelse return null;
    return try std.fs.path.join(arena, &.{ dir, "neo-compute" });
}

/// The places of the Linux server. The audit folder is created here with
/// mode 0700, readable by the user alone, its parents with the default
/// mode; one that already exists keeps its own.
pub fn places(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !audit.Places {
    const dir = try auditDir(arena, env);
    if (dir) |d| {
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(d)) |parent| cwd.createDirPath(io, parent) catch {};
        cwd.createDir(io, d, .fromMode(0o700)) catch {};
    }
    return .{
        .policy = try policyPath(arena, env),
        .audit = dir,
        .audit_unset = "neither XDG_STATE_HOME nor HOME is set: tool calls are not recorded",
    };
}

const testing = std.testing;

fn envOf(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(testing.allocator);
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "the policy and the audit follow XDG_CONFIG_HOME and XDG_STATE_HOME, else HOME" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var env = try envOf(&.{ .{ "HOME", "/home/u" }, .{ "XDG_CONFIG_HOME", "/cfg" }, .{ "XDG_STATE_HOME", "/st" } });
        defer env.deinit();
        try testing.expectEqualStrings("/cfg/neo-compute/policy.json", (try policyPath(a, &env)).?);
        try testing.expectEqualStrings("/st/neo-compute", (try auditDir(a, &env)).?);
    }
    // Absent, empty or relative: the default under HOME.
    for ([_]?[]const u8{ null, "", "relative/dir" }) |value| {
        var env = try envOf(&.{.{ "HOME", "/home/u" }});
        defer env.deinit();
        if (value) |v| {
            try env.put("XDG_CONFIG_HOME", v);
            try env.put("XDG_STATE_HOME", v);
        }
        try testing.expectEqualStrings("/home/u/.config/neo-compute/policy.json", (try policyPath(a, &env)).?);
        try testing.expectEqualStrings("/home/u/.local/state/neo-compute", (try auditDir(a, &env)).?);
    }
    var none = try envOf(&.{});
    defer none.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try policyPath(a, &none));
    try testing.expectEqual(@as(?[]const u8, null), try auditDir(a, &none));
}
