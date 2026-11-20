//! Process-level lifecycle checks on the real server binary: time from
//! process creation to the `initialize` response, and exit after stdin EOF.

const std = @import("std");
const builtin = @import("builtin");
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

/// A server process whose policy, audit and lock folders point at a test
/// directory (APPDATA and LOCALAPPDATA on Windows; XDG_CONFIG_HOME,
/// XDG_STATE_HOME and XDG_RUNTIME_DIR on Linux), so they stay out of the
/// profile and away from a server of the real session.
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
    try env.put("XDG_CONFIG_HOME", home);
    try env.put("XDG_STATE_HOME", home);
    try env.put("XDG_RUNTIME_DIR", home);
    try env.put("WAYLAND_DISPLAY", "wayland-nc-test");
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

// ---------------------------------------------------------------- US-069 on the Linux server

fn call(comptime id: u32, comptime tool: []const u8, comptime args: []const u8) []const u8 {
    return std.fmt.comptimePrint("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}\n", .{ id, tool, args });
}

test "the Linux server lists the 17 toolset tools and refuses what it cannot do yet, then keeps answering" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();
    var s: Server = .{};
    try s.start(io, &env, &.{});
    defer s.stop(io);
    _ = try s.send(init_line);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = try std.json.parseFromSliceLeaky(std.json.Value, a, try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n"), .{ .allocate = .alloc_always });
    const fixture = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("toolset_fixture"), .{});
    for (fixture.object.get("tools").?.array.items) |want| {
        const name = want.object.get("name").?.string;
        for (listed.object.get("result").?.object.get("tools").?.array.items) |t| {
            if (std.mem.eql(u8, t.object.get("name").?.string, name)) break;
        } else {
            std.debug.print("tools/list lacks {s}\n", .{name});
            return error.MissingTool;
        }
    }

    const shot = try s.send(call(3, "screenshot", "{}"));
    try testing.expect(std.mem.indexOf(u8, shot, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, shot, "Linux : screenshot n'est pas encore disponible dans ce build. Aucune action exécutée.") != null);
    const click = try s.send(call(4, "left_click", "{\"coordinate\":[5,5]}"));
    try testing.expect(std.mem.indexOf(u8, click, "Linux : left_click n'est pas encore disponible dans ce build. Aucune action exécutée.") != null);
    const pong = try s.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}", pong);
}

test "the Linux server speaks Linux in every mode and does not know registry_read" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();
    for ([_][]const u8{ "a11y", "vision", "background" }) |mode| {
        var s: Server = .{};
        try s.start(io, &env, &.{ "--mode", mode });
        defer s.stop(io);
        // Each reply lives in the reader's buffer until the next one.
        const init = try testing.allocator.dupe(u8, try s.send(init_line));
        defer testing.allocator.free(init);
        const list = try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n");
        try testing.expect(std.mem.indexOf(u8, init, "neo-compute ") != null);
        for ([_][]const u8{ "Windows", "Start menu", "AUMID", "HKCU", "registry" }) |word| for ([_][]const u8{ init, list }) |text| {
            if (std.mem.indexOf(u8, text, word) != null) {
                std.debug.print("--mode {s} names `{s}`\n", .{ mode, word });
                return error.WindowsWord;
            }
        };
        const unknown = try s.send(call(3, "registry_read", "{\"path\":\"HKCU\\\\Software\"}"));
        try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32602,\"message\":\"Unknown tool: registry_read\"}}", unknown);
    }
}

test "the Linux server answers an unknown window handle with the closed-window message" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();
    var s: Server = .{};
    try s.start(io, &env, &.{});
    defer s.stop(io);
    _ = try s.send(init_line);
    const closed = "{\"type\":\"text\",\"text\":\"Fenêtre fermée : rappelle window_list\"}],\"isError\":true}}";
    const focus = try s.send(call(3, "window_focus", "{\"window\":\"0x1a2b\"}"));
    try testing.expect(std.mem.endsWith(u8, focus, closed));
    const set = try s.send(call(4, "window_set", "{\"window\":\"0x1a2b\",\"state\":\"minimized\"}"));
    try testing.expect(std.mem.endsWith(u8, set, closed));
}

// ---------------------------------------------------------------- US-070 on the Linux server

test "the Linux server reads its policy and writes its audit at the XDG places, the folder in mode 0700" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();
    // An invalid default policy: global observe, as on Windows, named in
    // the instructions; the refused action is in the audit log.
    try tmp.dir.createDirPath(io, "cfg/neo-compute");
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/neo-compute/policy.json", .data = "{\n  \"default\": \"full\",\n  \"apps\": { \"keepassxc\": \"wirte\" }\n}\n" });
    const cfg = try std.fs.path.join(testing.allocator, &.{ home, "cfg" });
    defer testing.allocator.free(cfg);
    const state = try std.fs.path.join(testing.allocator, &.{ home, "state" });
    defer testing.allocator.free(state);
    try env.put("XDG_CONFIG_HOME", cfg);
    try env.put("XDG_STATE_HOME", state);
    {
        var s: Server = .{};
        try s.start(io, &env, &.{});
        defer s.stop(io);
        const init = try s.send(init_line);
        try testing.expect(std.mem.indexOf(u8, init, "is invalid at line 3") != null);
        try testing.expect(std.mem.indexOf(u8, init, "limited to observe") != null);
        const launch = try s.send(call(3, "app_launch", "{\"name\":\"calculator\"}"));
        try testing.expect(std.mem.indexOf(u8, launch, "Politique : app_launch est désactivé (system.app_launch dans policy.json)") != null);
    }
    var buf: [4096]u8 = undefined;
    const log = try tmp.dir.readFile(io, "state/neo-compute/audit.jsonl", &buf);
    try testing.expect(std.mem.indexOf(u8, log, "\"tool\":\"app_launch\"") != null);
    try testing.expect(std.mem.indexOf(u8, log, "\"result\":\"denied\"") != null);
    const st = try tmp.dir.statFile(io, "state/neo-compute", .{});
    try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}

test "without XDG_CONFIG_HOME and XDG_STATE_HOME the Linux server uses ~/.config and ~/.local/state" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();
    _ = env.swapRemove("XDG_CONFIG_HOME");
    try env.put("XDG_STATE_HOME", "");
    try env.put("HOME", home);
    // A valid policy that turns app_launch off: it was read.
    try tmp.dir.createDirPath(io, ".config/neo-compute");
    try tmp.dir.writeFile(io, .{ .sub_path = ".config/neo-compute/policy.json", .data = "{\"system\": {\"app_launch\": \"deny\"}}\n" });
    {
        var s: Server = .{};
        try s.start(io, &env, &.{});
        defer s.stop(io);
        const init = try s.send(init_line);
        try testing.expect(std.mem.indexOf(u8, init, "invalid") == null);
        const launch = try s.send(call(3, "app_launch", "{\"name\":\"calculator\"}"));
        try testing.expect(std.mem.indexOf(u8, launch, "Politique : app_launch est désactivé") != null);
    }
    var buf: [4096]u8 = undefined;
    const log = try tmp.dir.readFile(io, ".local/state/neo-compute/audit.jsonl", &buf);
    try testing.expect(std.mem.indexOf(u8, log, "\"tool\":\"app_launch\"") != null);
}

// ---------------------------------------------------------------- US-072 on Linux

/// Reads lines of `r` until one contains `needle`.
fn waitLine(r: *std.Io.Reader, needle: []const u8) !void {
    while (try r.takeDelimiter('\n')) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return;
    }
    return error.EndOfStream;
}

test "SIGINT, SIGTERM and SIGHUP release a held key within 50 ms and exit with code 0" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |sig| {
        var child = try std.process.spawn(io, .{ .argv = &.{options.fake_server_exe}, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
        errdefer child.kill(io);
        var wbuf: [512]u8 = undefined;
        var w = child.stdin.?.writerStreaming(io, &wbuf);
        var rbuf: [16 * 1024]u8 = undefined;
        var r = child.stdout.?.readerStreaming(io, &rbuf);
        var ebuf: [4096]u8 = undefined;
        var e = child.stderr.?.readerStreaming(io, &ebuf);
        try w.interface.writeAll(init_line);
        try w.interface.flush();
        _ = (try r.interface.takeDelimiter('\n')) orelse return error.NoResponse;
        // The tool holds shift for 30 s: no answer comes before the signal.
        try w.interface.writeAll(call(2, "hold_key", "{\"text\":\"shift\",\"duration\":30}"));
        try w.interface.flush();
        try waitLine(&e.interface, "fake: key press");
        const t0 = nowNs(io);
        try std.posix.kill(child.id.?, sig);
        try waitLine(&e.interface, "fake: key release");
        const released = nowNs(io) - t0;
        try waitLine(&e.interface, "held inputs released, exiting");
        const term = try child.wait(io);
        std.debug.print("process: {t}: key released {d} us after the signal\n", .{ sig, @divTrunc(released, 1000) });
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
        try testing.expect(released < 50 * std.time.ns_per_ms);
    }
}

test "a stop signal writes the audit line of the running tool" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();
    var s: Server = .{};
    try s.start(io, &env, &.{});
    _ = try s.send(init_line);
    try s.w.interface.writeAll(call(2, "wait", "{\"duration\":30}"));
    try s.w.interface.flush();
    // The wait is running once the dispatcher took it.
    try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    try std.posix.kill(s.child.id.?, .TERM);
    const term = try s.child.wait(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    var buf: [4096]u8 = undefined;
    const log = try tmp.dir.readFile(io, "neo-compute/audit.jsonl", &buf);
    try testing.expect(std.mem.indexOf(u8, log, "\"tool\":\"wait\"") != null);
    try testing.expect(std.mem.indexOf(u8, log, "\"result\":\"cancelled\"") != null);
}

const left_up_linux = "Linux : left_mouse_up n'est pas encore disponible dans ce build. Aucune action exécutée.";

test "the Linux lock is per display, and a killed server leaves it to the next one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();

    var first: Server = .{};
    try first.start(io, &env, &.{});
    _ = try first.send(init_line);
    // Another display: not blocked (its action reaches the backend).
    var other_env = try testEnv(testing.allocator, home);
    defer other_env.deinit();
    try other_env.put("WAYLAND_DISPLAY", "wayland-nc-other");
    {
        var other: Server = .{};
        try other.start(io, &other_env, &.{});
        defer other.stop(io);
        _ = try other.send(init_line);
        try testing.expect(std.mem.indexOf(u8, try other.send(left_up), left_up_linux) != null);
    }
    // The same display after SIGKILL of the first: the lock is free again.
    first.child.kill(io);
    var next: Server = .{};
    try next.start(io, &env, &.{});
    defer next.stop(io);
    _ = try next.send(init_line);
    const answer = try next.send(left_up);
    try testing.expect(std.mem.indexOf(u8, answer, "Une autre session neo-compute") == null);
    try testing.expect(std.mem.indexOf(u8, answer, left_up_linux) != null);
}

test "without XDG_RUNTIME_DIR the Linux server refuses every action and says why" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var env = try testEnv(testing.allocator, home);
    defer env.deinit();
    _ = env.swapRemove("XDG_RUNTIME_DIR");
    var s: Server = .{};
    try s.start(io, &env, &.{});
    defer s.stop(io);
    _ = try s.send(init_line);
    for ([_][]const u8{ left_up, call(3, "key", "{\"text\":\"Return\"}"), call(4, "app_launch", "{\"name\":\"calculator\"}") }) |line| {
        const answer = try s.send(line);
        try testing.expect(std.mem.indexOf(u8, answer, "XDG_RUNTIME_DIR absent : impossible de garantir une seule instance. Lance neo-compute depuis une session graphique.") != null);
        try testing.expect(std.mem.indexOf(u8, answer, "\"isError\":true") != null);
    }
}
