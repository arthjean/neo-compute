//! Process-level lifecycle checks on the real server binary: time from
//! process creation to the `initialize` response, and exit after stdin EOF.

const std = @import("std");
const testing = std.testing;
const options = @import("test_options");

const runs = 20;
const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"process_test\",\"version\":\"0\"}}}\n";

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

const Sample = struct { initialize_ns: i96, exit_ns: i96 };

fn once(io: std.Io) !Sample {
    const t0 = nowNs(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{options.server_exe},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    var wbuf: [512]u8 = undefined;
    var w = child.stdin.?.writerStreaming(io, &wbuf);
    try w.interface.writeAll(init_line);
    try w.interface.flush();

    var rbuf: [16 * 1024]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &rbuf);
    const line = (try r.interface.takeDelimiter('\n')) orelse return error.NoResponse;
    const t1 = nowNs(io);
    try testing.expect(std.mem.indexOf(u8, line, "\"protocolVersion\":\"2025-11-25\"") != null);

    child.stdin.?.close(io);
    child.stdin = null;
    const t2 = nowNs(io);
    const term = try child.wait(io);
    const t3 = nowNs(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    return .{ .initialize_ns = t1 - t0, .exit_ns = t3 - t2 };
}

test "initialize is answered within 50 ms of process creation, and EOF exits with code 0 within 50 ms" {
    const io = testing.io;
    var init_ns: [runs]i96 = undefined;
    var exit_ns: [runs]i96 = undefined;
    // The first launch of a freshly linked binary pays a one-time antivirus
    // scan (up to ~1.5 s measured on the reference machine), unrelated to
    // process start-up; it is excluded.
    _ = try once(io);
    for (0..runs) |i| {
        const s = try once(io);
        init_ns[i] = s.initialize_ns;
        exit_ns[i] = s.exit_ns;
    }
    std.mem.sort(i96, &init_ns, {}, std.sort.asc(i96));
    std.mem.sort(i96, &exit_ns, {}, std.sort.asc(i96));
    const p95 = runs * 95 / 100 - 1;
    std.debug.print("process: initialize p50 {d} us p95 {d} us max {d} us; exit after EOF p95 {d} us max {d} us\n", .{
        @divTrunc(init_ns[runs / 2], 1000), @divTrunc(init_ns[p95], 1000),      @divTrunc(init_ns[runs - 1], 1000),
        @divTrunc(exit_ns[p95], 1000),      @divTrunc(exit_ns[runs - 1], 1000),
    });
    try testing.expect(init_ns[p95] < 50 * std.time.ns_per_ms);
    try testing.expect(exit_ns[p95] < 50 * std.time.ns_per_ms);
}

// ---------------------------------------------------------------- EP-004 on the shipped binary

/// A server process whose LOCALAPPDATA and APPDATA point at a test
/// directory, so its audit log and default policy stay out of the profile.
const Server = struct {
    child: std.process.Child = undefined,
    wbuf: [4096]u8 = undefined,
    rbuf: [64 * 1024]u8 = undefined,
    w: std.Io.File.Writer = undefined,
    r: std.Io.File.Reader = undefined,

    fn start(self: *Server, io: std.Io, env: *const std.process.Environ.Map, extra: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        argv[0] = options.server_exe;
        @memcpy(argv[1..][0..extra.len], extra);
        self.child = try std.process.spawn(io, .{ .argv = argv[0 .. 1 + extra.len], .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .environ_map = env });
        self.w = self.child.stdin.?.writerStreaming(io, &self.wbuf);
        self.r = self.child.stdout.?.readerStreaming(io, &self.rbuf);
    }

    fn send(self: *Server, line: []const u8) ![]const u8 {
        try self.w.interface.writeAll(line);
        try self.w.interface.flush();
        return (try self.r.interface.takeDelimiter('\n')) orelse error.NoResponse;
    }

    fn stop(self: *Server, io: std.Io) void {
        if (self.child.stdin) |f| f.close(io);
        self.child.stdin = null;
        _ = self.child.wait(io) catch {};
    }
};

fn testEnv(gpa: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    try env.put("LOCALAPPDATA", home);
    try env.put("APPDATA", home);
    return env;
}

const left_up = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"left_mouse_up\",\"arguments\":{\"observe\":\"none\"}}}\n";

test "a second instance answers initialize, refuses actions and audits the refusal" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();

    var first: Server = .{};
    try first.start(io, &env, &.{});
    defer first.stop(io);
    _ = try first.send(init_line);
    var second: Server = .{};
    try second.start(io, &env, &.{});
    const init = try second.send(init_line);
    try testing.expect(std.mem.indexOf(u8, init, "\"protocolVersion\":\"2025-11-25\"") != null);
    const refused = try second.send(left_up);
    try testing.expect(std.mem.indexOf(u8, refused, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "Une autre session neo-compute contrôle déjà ce bureau") != null);
    second.stop(io);

    var buf: [4096]u8 = undefined;
    const log = try tmp.dir.readFile(io, "neo-compute/audit.jsonl", &buf);
    try testing.expect(std.mem.indexOf(u8, log, "\"tool\":\"left_mouse_up\"") != null);
    try testing.expect(std.mem.indexOf(u8, log, "\"result\":\"instance\"") != null);
}

test "an invalid --policy file is named with its line in the instructions" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "policy.json", .data = "{\n  \"default\": \"full\",\n  \"apps\": { \"Code.exe\": \"wirte\" }\n}\n" });
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();
    const policy_path = try std.fs.path.join(testing.allocator, &.{ home, "policy.json" });
    defer testing.allocator.free(policy_path);

    var s: Server = .{};
    try s.start(io, &env, &.{ "--policy", policy_path });
    defer s.stop(io);
    const init = try s.send(init_line);
    try testing.expect(std.mem.indexOf(u8, init, "is invalid at line 3") != null);
    try testing.expect(std.mem.indexOf(u8, init, "unknown level `wirte`") != null);
    try testing.expect(std.mem.indexOf(u8, init, "limited to observe") != null);
}

/// Names of the DLLs a PE32+ image imports, directly or delay-loaded.
fn importedDlls(gpa: std.mem.Allocator, image: []const u8) ![]const []const u8 {
    if (image.len < 0x40 or !std.mem.eql(u8, image[0..2], "MZ")) return error.NotPe;
    const pe = std.mem.readInt(u32, image[0x3c..][0..4], .little);
    if (!std.mem.eql(u8, image[pe..][0..4], "PE\x00\x00")) return error.NotPe;
    const coff = pe + 4;
    const sections = std.mem.readInt(u16, image[coff + 2 ..][0..2], .little);
    const opt_size = std.mem.readInt(u16, image[coff + 16 ..][0..2], .little);
    const opt = coff + 20;
    if (std.mem.readInt(u16, image[opt..][0..2], .little) != 0x20b) return error.NotPe32Plus;
    const dirs = opt + 112;
    const Sections = struct {
        image: []const u8,
        table: usize,
        count: u16,
        fn offset(self: @This(), rva: u32) ?usize {
            for (0..self.count) |i| {
                const s = self.table + i * 40;
                const va = std.mem.readInt(u32, self.image[s + 12 ..][0..4], .little);
                const size = std.mem.readInt(u32, self.image[s + 16 ..][0..4], .little);
                const raw = std.mem.readInt(u32, self.image[s + 20 ..][0..4], .little);
                if (rva >= va and rva < va + size) return raw + (rva - va);
            }
            return null;
        }
    };
    const map: Sections = .{ .image = image, .table = opt + opt_size, .count = sections };
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    // Data directory 1: import table (20-byte descriptors, name at +12).
    // Data directory 13: delay import table (32-byte descriptors, name at +4).
    for ([_][3]u32{ .{ 1, 20, 12 }, .{ 13, 32, 4 } }) |d| {
        const rva = std.mem.readInt(u32, image[dirs + d[0] * 8 ..][0..4], .little);
        if (rva == 0) continue;
        var at = map.offset(rva) orelse return error.BadImportTable;
        while (true) : (at += d[1]) {
            const name_rva = std.mem.readInt(u32, image[at + d[2] ..][0..4], .little);
            if (name_rva == 0) break;
            const off = map.offset(name_rva) orelse return error.BadImportTable;
            try names.append(gpa, std.mem.sliceTo(image[off..], 0));
        }
    }
    return names.toOwnedSlice(gpa);
}

test "the shipped binary imports no network DLL (ws2_32, winhttp, wininet)" {
    const io = testing.io;
    const image = try std.Io.Dir.cwd().readFileAlloc(io, options.server_exe, testing.allocator, .limited(64 << 20));
    defer testing.allocator.free(image);
    const dlls = try importedDlls(testing.allocator, image);
    defer testing.allocator.free(dlls);
    var has_kernel32 = false;
    for (dlls) |dll| {
        has_kernel32 = has_kernel32 or std.ascii.eqlIgnoreCase(dll, "kernel32.dll");
        for ([_][]const u8{ "ws2_32.dll", "winhttp.dll", "wininet.dll" }) |net| if (std.ascii.eqlIgnoreCase(dll, net)) {
            std.debug.print("{s} imports {s}\n", .{ options.server_exe, dll });
            return error.NetworkImport;
        };
    }
    // The parser reads the real table: kernel32 is always there.
    try testing.expect(has_kernel32);
    std.debug.print("process: {d} imported DLLs, none of them a network library\n", .{dlls.len});
}
