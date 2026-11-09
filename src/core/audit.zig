//! Audit log (US-019, FR-13): one JSON line per tool call in
//! `%LOCALAPPDATA%\neo-compute\audit.jsonl`: time, tool, target application,
//! pid, policy level, duration and result. Typed text is never recorded,
//! only its length. Rotated at 10 MB, 5 files kept (`audit.jsonl` and
//! `audit.jsonl.1` to `.4`). A write failure never blocks the tool: it is
//! reported once on stderr until a write succeeds again.

const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");

pub const file_name = "audit.jsonl";
pub const max_bytes = 10 * 1024 * 1024;
pub const kept_files = 5;

/// What a tool of EP-006 or EP-009 adds to its line: never a window title,
/// a document path, clipboard text or registry data (FR-29).
pub const Detail = struct {
    /// window_set: the requested state, or `placement` (US-027).
    state: ?[]const u8 = null,
    /// window_set force: the process it terminated.
    terminated_pid: ?u32 = null,
    terminated_exe_buf: [64]u8 = undefined,
    terminated_exe_len: u8 = 0,
    /// app_launch: the AUMID, or the document's extension (US-029).
    launched: ?[]const u8 = null,
    /// clipboard: the mode and the text's length in characters (US-035).
    clipboard_mode: ?[]const u8 = null,
    clipboard_len: ?usize = null,
    /// registry_read: the key and the value name (US-036).
    registry_path: ?[]const u8 = null,
    registry_name: ?[]const u8 = null,

    pub fn setTerminatedExe(self: *Detail, exe: []const u8) void {
        self.terminated_exe_len = @intCast(@min(exe.len, self.terminated_exe_buf.len));
        @memcpy(self.terminated_exe_buf[0..self.terminated_exe_len], exe[0..self.terminated_exe_len]);
    }

    fn terminatedExe(self: *const Detail) []const u8 {
        return self.terminated_exe_buf[0..self.terminated_exe_len];
    }
};

pub const Entry = struct {
    tool: []const u8,
    target: ?policy.Target = null,
    duration_ns: u64,
    /// ok, error, denied, paused, instance, cancelled.
    result: []const u8,
    /// Characters of `type`'s text, the only argument recorded.
    text_len: ?usize = null,
    detail: Detail = .{},
};

pub const Audit = struct {
    io: Io,
    dir: Io.Dir,
    file: ?Io.File = null,
    warned: bool = false,
    /// Bytes per file before rotation (tests lower it).
    limit: u64 = max_bytes,

    /// Opens (creating it) the directory `path` that holds the log.
    pub fn open(io: Io, path: []const u8) !Audit {
        const dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
        return .{ .io = io, .dir = dir };
    }

    pub fn deinit(self: *Audit) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
        self.dir.close(self.io);
    }

    pub fn record(self: *Audit, e: Entry) void {
        var buf: [1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        format(&w, e, Io.Clock.real.now(self.io).toNanoseconds()) catch return self.warn(error.LineTooLong);
        self.append(w.buffered()) catch |err| return self.warn(err);
        self.warned = false;
    }

    fn warn(self: *Audit, err: anyerror) void {
        if (self.warned) return;
        self.warned = true;
        std.debug.print("neo-compute: audit log write failed ({t}); tools keep running without it\n", .{err});
    }

    fn append(self: *Audit, line: []const u8) !void {
        const f = self.file orelse blk: {
            self.file = try self.dir.createFile(self.io, file_name, .{ .truncate = false });
            break :blk self.file.?;
        };
        // Another instance may append too: read the end every time.
        var end = try f.length(self.io);
        if (end > 0 and end + line.len > self.limit) {
            try self.rotate();
            end = 0;
        }
        try self.file.?.writePositionalAll(self.io, line, end);
    }

    fn rotate(self: *Audit) !void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
        var from: [32]u8 = undefined;
        var to: [32]u8 = undefined;
        var i: usize = kept_files - 1;
        while (i > 0) : (i -= 1) {
            const dst = try std.fmt.bufPrint(&to, "{s}.{d}", .{ file_name, i });
            const src = if (i == 1) file_name else try std.fmt.bufPrint(&from, "{s}.{d}", .{ file_name, i - 1 });
            self.dir.deleteFile(self.io, dst) catch {};
            self.dir.rename(src, self.dir, dst, self.io) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        self.file = try self.dir.createFile(self.io, file_name, .{ .truncate = false });
    }
};

/// One line: `{"ts":"2026-11-04T09:12:03.456Z","tool":"left_click","app":"notepad.exe","pid":4242,"policy":"full","ms":12.3,"result":"ok"}`.
pub fn format(w: *Io.Writer, e: Entry, now_ns: i96) !void {
    const ms_total: u64 = @intCast(@divTrunc(@max(now_ns, 0), std.time.ns_per_ms));
    const secs: std.time.epoch.EpochSeconds = .{ .secs = ms_total / 1000 };
    const day = secs.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = secs.getDaySeconds();
    try w.print("{{\"ts\":\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\",\"tool\":", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), ms_total % 1000,
    });
    try std.json.Stringify.value(e.tool, .{}, w);
    if (e.target) |t| {
        try w.writeAll(",\"app\":");
        try std.json.Stringify.value(t.exe(), .{}, w);
        try w.print(",\"pid\":{d},\"policy\":\"{t}\"", .{ t.pid, t.level });
    } else try w.writeAll(",\"app\":null,\"pid\":null,\"policy\":null");
    try w.print(",\"ms\":{d:.1},\"result\":\"{s}\"", .{ @as(f64, @floatFromInt(e.duration_ns)) / std.time.ns_per_ms, e.result });
    if (e.text_len) |n| try w.print(",\"text_len\":{d}", .{n});
    if (e.detail.state) |s| {
        try w.writeAll(",\"state\":");
        try std.json.Stringify.value(s, .{}, w);
    }
    if (e.detail.terminated_pid) |pid| {
        try w.print(",\"terminated\":{{\"pid\":{d},\"exe\":", .{pid});
        try std.json.Stringify.value(e.detail.terminatedExe(), .{}, w);
        try w.writeByte('}');
    }
    if (e.detail.launched) |l| {
        try w.writeAll(",\"launched\":");
        // An AUMID is at most a few hundred bytes; cut to keep the line.
        try std.json.Stringify.value(l[0..@min(l.len, 256)], .{}, w);
    }
    if (e.detail.clipboard_mode) |m| {
        try w.print(",\"clipboard\":{{\"mode\":\"{s}\"", .{m});
        if (e.detail.clipboard_len) |n| try w.print(",\"len\":{d}", .{n});
        try w.writeByte('}');
    }
    if (e.detail.registry_path) |p| {
        try w.writeAll(",\"registry\":{\"path\":");
        try std.json.Stringify.value(prefix(p, 384), .{}, w);
        if (e.detail.registry_name) |n| {
            try w.writeAll(",\"name\":");
            try std.json.Stringify.value(prefix(n, 128), .{}, w);
        }
        try w.writeByte('}');
    }
    try w.writeAll("}\n");
}

/// At most `n` bytes of UTF-8 `s`, cut at a code point boundary so the line
/// stays valid JSON.
fn prefix(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var end = n;
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

test "clipboard and registry_read lines carry the mode, the length, the path and the name, never the data" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try format(&w, .{ .tool = "clipboard", .duration_ns = 1, .result = "ok", .detail = .{ .clipboard_mode = "set", .clipboard_len = 42 } }, 0);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), ",\"result\":\"ok\",\"clipboard\":{\"mode\":\"set\",\"len\":42}}\n"));
    w = .fixed(&buf);
    try format(&w, .{ .tool = "registry_read", .duration_ns = 1, .result = "ok", .detail = .{ .registry_path = "HKCU\\Software\\Microsoft\\Notepad", .registry_name = "fWrap" } }, 0);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), ",\"registry\":{\"path\":\"HKCU\\\\Software\\\\Microsoft\\\\Notepad\",\"name\":\"fWrap\"}}\n"));
    // A long path is cut at a code point, within the line's buffer.
    var long: [2 * 400 + 5]u8 = undefined;
    @memcpy(long[0..5], "HKCU\\");
    for (0..400) |i| @memcpy(long[5 + 2 * i ..][0..2], "é");
    const name: [300]u8 = @splat('n');
    w = .fixed(&buf);
    try format(&w, .{ .tool = "registry_read", .duration_ns = 1, .result = "ok", .detail = .{ .registry_path = &long, .registry_name = &name } }, 0);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    parsed.deinit();
}

test "window_set and app_launch lines carry the state, the terminated process and the AUMID or extension" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Detail = .{ .state = "closed", .terminated_pid = 4242 };
    d.setTerminatedExe("notepad.exe");
    try format(&w, .{ .tool = "window_set", .duration_ns = 2_000_000, .result = "ok", .detail = d }, 0);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), ",\"state\":\"closed\",\"terminated\":{\"pid\":4242,\"exe\":\"notepad.exe\"}}\n"));
    w = .fixed(&buf);
    try format(&w, .{ .tool = "app_launch", .duration_ns = 1, .result = "ok", .detail = .{ .launched = ".txt" } }, 0);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), ",\"launched\":\".txt\"}\n"));
}

test "an audit line carries time, tool, target, level, duration and result, never typed text" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var t: policy.Target = .{ .handle = 1, .pid = 4242, .level = .full };
    @memcpy(t.exe_buf[0..11], "notepad.exe");
    t.exe_len = 11;
    // 2026-11-04T09:12:03.456Z
    try format(&w, .{ .tool = "type", .target = t, .duration_ns = 12_345_678, .result = "ok", .text_len = 42 }, 1_793_783_523_456 * std.time.ns_per_ms);
    try std.testing.expectEqualStrings("{\"ts\":\"2026-11-04T09:12:03.456Z\",\"tool\":\"type\",\"app\":\"notepad.exe\",\"pid\":4242,\"policy\":\"full\",\"ms\":12.3,\"result\":\"ok\",\"text_len\":42}\n", w.buffered());
}

test "the log rotates at its size limit and keeps 5 files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: Audit = .{ .io = io, .dir = tmp.dir, .limit = 300 };
    defer if (a.file) |f| f.close(io);
    for (0..40) |_| a.record(.{ .tool = "screenshot", .duration_ns = 1000, .result = "ok" });
    for ([_][]const u8{ "audit.jsonl", "audit.jsonl.1", "audit.jsonl.2", "audit.jsonl.3", "audit.jsonl.4" }) |name| {
        const st = try tmp.dir.statFile(io, name, .{});
        try std.testing.expect(st.size > 0 and st.size <= 300);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "audit.jsonl.5", .{}));
}
