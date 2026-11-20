//! `neo-compute selftest` under Linux (EP-021): the native transports
//! against the compositor of a test session. It refuses any other session:
//! the `ei` control moves the pointer and holds a key.
//!
//!   zig build session -- gnome selftest
//!
//! - `dbus`: Hello, a well-known name and its owner's process id; under
//!   GNOME, a Mutter RemoteDesktop session created, started, its SessionId
//!   read 200 times (p50/p95), stopped, and its Closed signal.
//! - `wayland`: the registry against audit table 1.2 for the family, then
//!   a wl_shm buffer on memfd drawn on a surface.
//! - `ei`: under GNOME, Mutter's EIS: the absolute pointer at 20 points of
//!   the fixture's canvas, each read back exact to the logical pixel, the
//!   XKB keymap of the EI keyboard, a held key released < 50 ms after the
//!   context closes while a copy of its descriptor stays open in another
//!   process; under KDE, KWin's EIS seats, devices and capabilities.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("wire/dbus.zig");
const wl = @import("wire/wayland.zig");
const ei = @import("wire/ei.zig");
const xkb = @import("wire/xkb.zig");
const sock = @import("wire/sock.zig");
const capabilities = @import("capabilities.zig");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Report = struct {
    log: *std.Io.Writer,
    failed: ?[]const u8 = null,

    pub fn ok(self: *Report, name: []const u8, comptime f: []const u8, args: anytype) void {
        self.log.print("selftest: {s} ok (" ++ f ++ ")\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
    }

    pub fn skip(self: *Report, name: []const u8, comptime f: []const u8, args: anytype) void {
        self.log.print("selftest: {s} skipped (" ++ f ++ ")\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
    }

    pub fn fail(self: *Report, name: []const u8, comptime f: []const u8, args: anytype) void {
        self.log.print("selftest: {s} FAILED: " ++ f ++ "\n", .{name} ++ args) catch {};
        self.log.flush() catch {};
        if (self.failed == null) self.failed = name;
    }
};

pub const Family = enum { gnome, kde, sway, labwc };

const rd = dbus.ifaces.org_gnome_Mutter_RemoteDesktop;
const rds = dbus.ifaces.org_gnome_Mutter_RemoteDesktop_Session;
const kwin_eis = dbus.ifaces.org_kde_KWin_EIS_RemoteDesktop;
const mutter_rd = "org.gnome.Mutter.RemoteDesktop";

pub fn run(gpa: Allocator, io: std.Io, env: *const Environ.Map, log: *std.Io.Writer) !?[]const u8 {
    var r: Report = .{ .log = log };
    // A test session of tools/linux-session only (AGENTS.md).
    const runtime = env.get("XDG_RUNTIME_DIR") orelse "";
    const family = std.meta.stringToEnum(Family, env.get("NC_SESSION") orelse "") orelse {
        r.fail("platform", "not a test session: run it through `zig build session -- <gnome|kde|sway|labwc> selftest`", .{});
        return r.failed;
    };
    if (std.mem.indexOf(u8, runtime, "/nc-") == null) {
        r.fail("platform", "XDG_RUNTIME_DIR is not a test session's: refused", .{});
        return r.failed;
    }
    var caps: capabilities.Table = .{};
    var lib = xkb.Lib.load(xkb.library_name);
    defer if (lib) |l| {
        _ = std.c.dlclose(l.handle);
    };
    caps.keyboard = lib != null;
    log.print("selftest: session {t}\n", .{family}) catch {};
    caps.write(log) catch {};

    dbusControl(&r, gpa, env, family);
    waylandControl(&r, gpa, env, family);
    eiControl(&r, gpa, io, env, family, if (lib) |*l| l else null);
    return r.failed;
}

// ---------------------------------------------------------------- dbus

fn percentile(sorted: []const u64, p: usize) u64 {
    return sorted[@min(sorted.len - 1, (sorted.len * p + 99) / 100 - 1)];
}

fn dbusControl(r: *Report, gpa: Allocator, env: *const Environ.Map, family: Family) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = dbus.Connection.session(gpa, env, 1000) catch |e| return r.fail("dbus", "session bus: {t}", .{e});
    defer c.deinit();
    const name = "org.neocompute.Selftest";
    const owned = c.requestName(a, name, 1000) catch |e| return r.fail("dbus", "RequestName: {t} {s}", .{ e, c.errorText() });
    if (!owned) return r.fail("dbus", "RequestName {s}: not the primary owner", .{name});
    const pid = c.pidOf(a, name, 1000) catch |e| return r.fail("dbus", "GetConnectionUnixProcessID: {t}", .{e});
    if (pid != linux.getpid()) return r.fail("dbus", "{s} is owned by pid {d}, not {d}", .{ name, pid, linux.getpid() });
    if (family != .gnome) return r.ok("dbus", "{s}, {s} owned by pid {d}; no Mutter RemoteDesktop on {t}", .{ c.uniqueName(), name, pid, family });

    const session = (c.callTyped(a, mutter_rd, "/org/gnome/Mutter/RemoteDesktop", rd.CreateSession, .{}, struct { dbus.ObjectPath }, 1000) catch |e|
        return r.fail("dbus", "CreateSession: {t} {s}", .{ e, c.errorText() }))[0].path;
    const rule = std.fmt.allocPrint(a, "type='signal',interface='{s}',member='Closed',path='{s}'", .{ rds.Closed.interface, session }) catch return;
    c.addMatch(a, rule, 1000) catch |e| return r.fail("dbus", "AddMatch: {t}", .{e});
    _ = c.callTyped(a, mutter_rd, session, rds.Start, .{}, struct {}, 1000) catch |e| return r.fail("dbus", "Start: {t} {s}", .{ e, c.errorText() });
    var lat: [200]u64 = undefined;
    var id: []const u8 = "";
    for (&lat) |*l| {
        var call_arena: std.heap.ArenaAllocator = .init(gpa);
        defer call_arena.deinit();
        const t0 = sock.nowNs();
        const v = c.getProperty(call_arena.allocator(), mutter_rd, session, rds.SessionId, []const u8, 1000) catch |e| return r.fail("dbus", "Get SessionId: {t}", .{e});
        l.* = sock.nowNs() - t0;
        if (id.len == 0) id = a.dupe(u8, v) catch return;
    }
    _ = c.callTyped(a, mutter_rd, session, rds.Stop, .{}, struct {}, 1000) catch |e| return r.fail("dbus", "Stop: {t} {s}", .{ e, c.errorText() });
    const closed = c.waitSignal(a, rds.Closed, session, 2000) catch |e| return r.fail("dbus", "Closed: {t}", .{e});
    if (closed == null) return r.fail("dbus", "no Closed signal within 2 s of Stop", .{});
    std.mem.sort(u64, &lat, {}, std.sort.asc(u64));
    r.ok("dbus", "{s}, {s} owned by pid {d}; RemoteDesktop session {s} created, started, stopped, Closed received; Get SessionId p50 {d}.{d:0>2} ms p95 {d}.{d:0>2} ms over {d} calls (reference 0.16/0.23)", .{
        c.uniqueName(),                   name,                                pid,                              id,
        percentile(&lat, 50) / 1_000_000, percentile(&lat, 50) / 10_000 % 100, percentile(&lat, 95) / 1_000_000, percentile(&lat, 95) / 10_000 % 100,
        lat.len,
    });
}

// ---------------------------------------------------------------- wayland

const any: u32 = std.math.maxInt(u32);

/// Audit table 1.2: the version each family advertises, 0 when absent,
/// `any` when present at any version.
const Row = struct { name: []const u8, gnome: u32, kde: u32, sway: u32, labwc: u32 };
const table_1_2 = [_]Row{
    .{ .name = "zwlr_virtual_pointer_manager_v1", .gnome = 0, .kde = 0, .sway = 2, .labwc = 2 },
    .{ .name = "zwp_virtual_keyboard_manager_v1", .gnome = 0, .kde = 0, .sway = 1, .labwc = 1 },
    .{ .name = "org_kde_kwin_fake_input", .gnome = 0, .kde = 6, .sway = 0, .labwc = 0 },
    .{ .name = "zwlr_screencopy_manager_v1", .gnome = 0, .kde = 0, .sway = 3, .labwc = 3 },
    .{ .name = "ext_image_copy_capture_manager_v1", .gnome = 0, .kde = 0, .sway = 1, .labwc = 1 },
    .{ .name = "ext_foreign_toplevel_image_capture_source_manager_v1", .gnome = 0, .kde = 0, .sway = 1, .labwc = 1 },
    .{ .name = "ext_foreign_toplevel_list_v1", .gnome = 0, .kde = 0, .sway = 1, .labwc = 1 },
    .{ .name = "zwlr_foreign_toplevel_manager_v1", .gnome = 0, .kde = 0, .sway = 3, .labwc = 3 },
    .{ .name = "ext_data_control_manager_v1", .gnome = 0, .kde = 1, .sway = 1, .labwc = 1 },
    .{ .name = "zwlr_data_control_manager_v1", .gnome = 0, .kde = 0, .sway = 2, .labwc = 2 },
    .{ .name = "zwlr_layer_shell_v1", .gnome = 0, .kde = 5, .sway = 5, .labwc = 4 },
    .{ .name = "ext_idle_notifier_v1", .gnome = 0, .kde = 2, .sway = 2, .labwc = 2 },
    .{ .name = "ext_transient_seat_manager_v1", .gnome = 0, .kde = 0, .sway = any, .labwc = 0 },
    .{ .name = "org_kde_plasma_window_management", .gnome = 0, .kde = 21, .sway = 0, .labwc = 0 },
    .{ .name = "zkde_screencast_unstable_v1", .gnome = 0, .kde = 6, .sway = 0, .labwc = 0 },
    .{ .name = "wp_security_context_manager_v1", .gnome = 0, .kde = 1, .sway = 1, .labwc = 1 },
    .{ .name = "xdg_activation_v1", .gnome = 1, .kde = 1, .sway = 1, .labwc = 1 },
    .{ .name = "wl_seat", .gnome = any, .kde = any, .sway = any, .labwc = any },
};

fn waylandControl(r: *Report, gpa: Allocator, env: *const Environ.Map, family: Family) void {
    var c = wl.Connection.connect(gpa, env) catch |e| return r.fail("wayland", "connect: {t}", .{e});
    defer c.deinit();
    const deadline = sock.deadlineIn(3000);
    c.readRegistry(deadline) catch |e| return r.fail("wayland", "registry: {s} {s}", .{ c.describe(e), c.problem });
    var mismatches: usize = 0;
    for (table_1_2) |row| {
        const want = switch (family) {
            inline else => |f| @field(row, @tagName(f)),
        };
        const got: u32 = if (c.global(row.name)) |g| g.version else 0;
        const fine = if (want == any) got > 0 else got == want;
        if (!fine) {
            mismatches += 1;
            r.log.print("selftest: wayland {s}: v{d} advertised, table 1.2 says {s}{d}\n", .{ row.name, got, if (want == any) ">0 " else "v", if (want == any) 0 else want }) catch {};
        }
    }
    if (mismatches > 0) return r.fail("wayland", "{d} rows of audit table 1.2 differ on {t}", .{ mismatches, family });

    // A buffer of wl_shm on memfd, drawn on a surface.
    const ifc = wl.ifaces;
    const shm_g = c.global("wl_shm") orelse return r.fail("wayland", "no wl_shm", .{});
    const comp_g = c.global("wl_compositor") orelse return r.fail("wayland", "no wl_compositor", .{});
    const shm = c.bind(shm_g, ifc.wl_shm) catch |e| return r.fail("wayland", "bind wl_shm: {t}", .{e});
    const comp = c.bind(comp_g, ifc.wl_compositor) catch |e| return r.fail("wayland", "bind wl_compositor: {t}", .{e});
    var pool = wl.ShmPool.create(&c, shm, 64 * 64 * 4) catch |e| return r.fail("wayland", "shm pool: {t}", .{e});
    @memset(pool.memory, 0x80);
    const buffer = pool.buffer(&c, 0, 64, 64, 64 * 4, @intCast(ifc.wl_shm.enums.format.xrgb8888)) catch |e| return r.fail("wayland", "buffer: {t}", .{e});
    const surface = c.newId(&ifc.wl_surface.interface) catch return;
    const steps = [_]struct { u32, u16, []const wl.Arg }{
        .{ comp, ifc.wl_compositor.request.create_surface, &.{.{ .new_id = surface }} },
        .{ surface, ifc.wl_surface.request.attach, &.{ .{ .object = buffer }, .{ .int = 0 }, .{ .int = 0 } } },
        .{ surface, ifc.wl_surface.request.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 64 }, .{ .int = 64 } } },
        .{ surface, ifc.wl_surface.request.commit, &.{} },
    };
    for (steps) |s| c.request(s[0], s[1], s[2]) catch |e| return r.fail("wayland", "surface: {s}", .{c.describe(e)});
    c.roundtrip(deadline, null) catch |e| return r.fail("wayland", "commit: {s} {s}", .{ c.describe(e), c.problem });
    c.request(surface, ifc.wl_surface.request.destroy, &.{}) catch {};
    c.request(buffer, ifc.wl_buffer.request.destroy, &.{}) catch {};
    pool.destroy(&c);
    c.roundtrip(deadline, null) catch |e| return r.fail("wayland", "teardown: {s} {s}", .{ c.describe(e), c.problem });
    r.ok("wayland", "{d} globals, the {d} rows of audit table 1.2 match {t}; wl_shm v{d} buffer 64x64 on memfd committed on a wl_compositor v{d} surface", .{ c.globals.items.len, table_1_2.len, family, @min(shm_g.version, ifc.wl_shm.interface.version), @min(comp_g.version, ifc.wl_compositor.interface.version) });
}

// ---------------------------------------------------------------- ei

const wanted = [_]ei.Capability{ .pointer, .pointer_absolute, .button, .scroll, .keyboard };

fn listDevices(ctx: *ei.Context, out: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    for (ctx.devices.items, 0..) |*d, i| {
        if (i > 0) w.writeAll("; ") catch break;
        w.print("{s} [", .{d.name()}) catch break;
        var first = true;
        inline for (@typeInfo(ei.Capability).@"enum".field_names) |cap| if (d.has(@field(ei.Capability, cap))) {
            w.print("{s}{s}", .{ if (first) "" else " ", cap }) catch {};
            first = false;
        };
        w.writeAll("]") catch break;
    }
    return w.buffered();
}

fn eiControl(r: *Report, gpa: Allocator, io: std.Io, env: *const Environ.Map, family: Family, lib: ?*const xkb.Lib) void {
    switch (family) {
        .gnome => eiMutter(r, gpa, io, env, lib),
        .kde => eiKwin(r, gpa, env),
        .sway, .labwc => r.skip("ei", "wlroots offers no EIS; input goes through its virtual devices (EP-024)", .{}),
    }
}

fn eiKwin(r: *Report, gpa: Allocator, env: *const Environ.Map) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = dbus.Connection.session(gpa, env, 1000) catch |e| return r.fail("ei", "session bus: {t}", .{e});
    defer c.deinit();
    // Every libeis capability (pointer to text).
    const got = c.callTyped(a, "org.kde.KWin", "/org/kde/KWin/EIS/RemoteDesktop", kwin_eis.connectToEIS, .{@as(i32, 0x7f)}, struct { dbus.Fd, i32 }, 1000) catch |e|
        return r.fail("ei", "connectToEIS: {t} {s}", .{ e, c.errorText() });
    var ctx = ei.Context.init(gpa, got[0].fd, &(wanted ++ [_]ei.Capability{.text})) catch return;
    defer ctx.deinit();
    ctx.waitReady(sock.deadlineIn(3000)) catch |e| return r.fail("ei", "KWin EIS setup: {s} {s}", .{ ei.describe(e), ctx.problem });
    var buf: [512]u8 = undefined;
    const devices = listDevices(&ctx, &buf);
    ctx.close();
    _ = c.callTyped(a, "org.kde.KWin", "/org/kde/KWin/EIS/RemoteDesktop", kwin_eis.disconnect, .{got[1]}, struct {}, 1000) catch {};
    r.ok("ei", "KWin EIS (cookie {d}): {d} devices: {s}", .{ got[1], ctx.devices.items.len, devices });
}

/// The fixture's NC_FIXTURE_LOG, read line by line as it grows.
const FixtureLog = struct {
    path: []const u8,
    seen: usize = 0,

    /// The next JSON event satisfying `pred` written after the last one
    /// returned, or null at the deadline.
    fn wait(l: *FixtureLog, a: Allocator, io: std.Io, deadline_ms: u32, ctx: anytype, comptime pred: fn (@TypeOf(ctx), std.json.ObjectMap) bool) ?std.json.ObjectMap {
        const deadline = sock.deadlineIn(deadline_ms).?;
        while (sock.nowNs() < deadline) {
            const text = std.Io.Dir.cwd().readFileAlloc(io, l.path, a, .limited(16 << 20)) catch "";
            var start = l.seen;
            while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |end| {
                const line = text[start..end];
                start = end + 1;
                l.seen = start;
                const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
                if (v == .object and pred(ctx, v.object)) return v.object;
            }
            io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
        return null;
    }

    /// The last `n` lines, for a failure.
    fn tail(l: *FixtureLog, a: Allocator, io: std.Io, w: *std.Io.Writer, n: usize) void {
        const text = std.Io.Dir.cwd().readFileAlloc(io, l.path, a, .limited(16 << 20)) catch return;
        var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        var picked: [16][]const u8 = undefined;
        var k: usize = 0;
        while (lines.next()) |line| : (k += 1) {
            if (k == @min(n, picked.len)) break;
            picked[k] = line;
        }
        while (k > 0) : (k -= 1) w.print("selftest: fixture log: {s}\n", .{picked[k - 1]}) catch {};
    }
};

fn num(v: ?std.json.Value) f64 {
    const x = v orelse return std.math.nan(f64);
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => std.math.nan(f64),
    };
}

fn isEvent(o: std.json.ObjectMap, name: []const u8) bool {
    const e = o.get("event") orelse return false;
    return e == .string and std.mem.eql(u8, e.string, name);
}

/// The `socket:[inode]` a descriptor names.
fn linkOf(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, f, args, 0) catch return "";
    const n = linux.readlink(path, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return "";
    return buf[0..n];
}

/// Whether process `pid` holds a descriptor on `target`.
fn holds(pid: i32, target: []const u8) bool {
    var link: [128]u8 = undefined;
    for (0..256) |fd| if (std.mem.eql(u8, linkOf(&link, "/proc/{d}/fd/{d}", .{ pid, fd }), target)) return true;
    return false;
}

fn eiMutter(r: *Report, gpa: Allocator, io: std.Io, env: *const Environ.Map, lib: ?*const xkb.Lib) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = dbus.Connection.session(gpa, env, 1000) catch |e| return r.fail("ei", "session bus: {t}", .{e});
    defer c.deinit();
    const session = (c.callTyped(a, mutter_rd, "/org/gnome/Mutter/RemoteDesktop", rd.CreateSession, .{}, struct { dbus.ObjectPath }, 1000) catch |e|
        return r.fail("ei", "CreateSession: {t} {s}", .{ e, c.errorText() }))[0].path;
    _ = c.callTyped(a, mutter_rd, session, rds.Start, .{}, struct {}, 1000) catch |e| return r.fail("ei", "Start: {t} {s}", .{ e, c.errorText() });
    defer _ = c.callTyped(a, mutter_rd, session, rds.Stop, .{}, struct {}, 1000) catch {};
    const Entry = dbus.DictEntry([]const u8, dbus.Variant);
    const fd = (c.callTyped(a, mutter_rd, session, rds.ConnectToEIS, .{@as([]const Entry, &.{})}, struct { dbus.Fd }, 1000) catch |e|
        return r.fail("ei", "ConnectToEIS: {t} {s}", .{ e, c.errorText() }))[0].fd;
    var ctx = ei.Context.init(gpa, fd, &wanted) catch return;
    defer ctx.deinit();
    ctx.waitReady(sock.deadlineIn(3000)) catch |e| return r.fail("ei", "EIS setup: {s} {s}", .{ ei.describe(e), ctx.problem });
    // Mutter announces one device per capability group, one after another.
    for ([_]ei.Capability{ .pointer_absolute, .keyboard }) |cap|
        _ = ctx.waitDevice(cap, sock.deadlineIn(3000)) catch |e| return r.fail("ei", "no resumed {t} device: {s} {s}", .{ cap, ei.describe(e), ctx.problem });
    var dev_buf: [512]u8 = undefined;
    const devices = listDevices(&ctx, &dev_buf);
    var eis_link_buf: [128]u8 = undefined;
    const eis_link = linkOf(&eis_link_buf, "/proc/self/fd/{d}", .{fd});

    // The keymap of the EI keyboard, read through libxkbcommon.
    var layout: []const u8 = "no libxkbcommon";
    var key_a: u32 = 30; // KEY_A
    var keymap: ?xkb.Keymap = null;
    defer if (keymap) |k| k.deinit();
    if (lib) |l| {
        const km = ctx.keymap() orelse return r.fail("ei", "the EI keyboard published no keymap", .{});
        const text_buf = a.alloc(u8, km.text.len + 1) catch return;
        keymap = xkb.Keymap.fromString(l, km.text, text_buf) orelse return r.fail("ei", "the EI keymap does not compile ({d} bytes)", .{km.text.len});
        layout = keymap.?.layoutName(km.group);
        const s = keymap.?.find(keymap.?.keysymOf('a'), km.group) orelse return r.fail("ei", "no key types `a` in layout {s}", .{layout});
        key_a = s.key;
    }

    // The fixture, full screen at scale 1, started after the descriptor
    // came: it must not hold a copy of it.
    const log_path = std.fmt.allocPrint(a, "{s}/nc-selftest-ei.log", .{env.get("XDG_RUNTIME_DIR").?}) catch return;
    std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
    var fixture_env = env.clone(a) catch return;
    fixture_env.put("NC_FIXTURE_LOG", log_path) catch return;
    var fixture = std.process.spawn(io, .{
        .argv = &.{ "python3", "-I", "tests/linux/fixture/gtk_fixture.py", "--fullscreen" },
        .environ_map = &fixture_env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |e| return r.fail("ei", "fixture: {t}", .{e});
    defer fixture.kill(io);
    var flog: FixtureLog = .{ .path = log_path };
    const Pred = struct {
        fn active(_: void, o: std.json.ObjectMap) bool {
            return isEvent(o, "layout") and (o.get("active") orelse std.json.Value{ .bool = false }) == .bool and o.get("active").?.bool;
        }
    };
    const lay = flog.wait(a, io, 20_000, {}, Pred.active) orelse return r.fail("ei", "the fixture wrote no active layout within 20 s", .{});
    if (holds(@intCast(fixture.id.?), eis_link)) return r.fail("ei", "the fixture inherited the EIS descriptor ({s})", .{eis_link});
    const canvas = lay.get("controls").?.object.get("canvas").?.array.items;
    const cx = num(canvas[0]);
    const cy = num(canvas[1]);
    const cw = num(canvas[2]);
    const ch = num(canvas[3]);

    // 20 points of the canvas, each read back by the fixture.
    const abs = ctx.waitDevice(.pointer_absolute, sock.deadlineIn(1000)) catch |e| return r.fail("ei", "absolute pointer: {s}", .{ei.describe(e)});
    ctx.start(abs) catch |e| return r.fail("ei", "start_emulating: {s}", .{ei.describe(e)});
    // The pointer enters the canvas first: GTK reports an entry, not a
    // motion, for the move that crosses into a widget.
    ctx.moveTo(abs, @floatCast(cx + 2), @floatCast(cy + 2)) catch |e| return r.fail("ei", "motion_absolute: {s}", .{ei.describe(e)});
    ctx.frame(abs, ei.Context.nowUs()) catch |e| return r.fail("ei", "frame: {s}", .{ei.describe(e)});
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    var worst: f64 = 0;
    for (0..20) |i| {
        const px: f32 = @floatCast(@floor(cx + cw * (@as(f64, @floatFromInt(i % 5)) + 0.5) / 5));
        const py: f32 = @floatCast(@floor(cy + ch * (@as(f64, @floatFromInt(i / 5)) + 0.5) / 4));
        ctx.moveTo(abs, px, py) catch |e| return r.fail("ei", "motion_absolute: {s}", .{ei.describe(e)});
        ctx.frame(abs, ei.Context.nowUs()) catch |e| return r.fail("ei", "frame: {s}", .{ei.describe(e)});
        const Want = struct { x: f64, y: f64 };
        const want: Want = .{ .x = px - cx, .y = py - cy };
        const P = struct {
            fn at(w: Want, o: std.json.ObjectMap) bool {
                return isEvent(o, "pointer") and @abs(num(o.get("x")) - w.x) < 1 and @abs(num(o.get("y")) - w.y) < 1;
            }
        };
        const got = flog.wait(a, io, 2000, want, P.at) orelse {
            flog.tail(a, io, r.log, 3);
            // A refusal of the compositor would be waiting on the socket.
            ctx.dispatch(sock.deadlineIn(100)) catch |e| r.log.print("selftest: ei context: {t} {s}\n", .{ e, ctx.problem }) catch {};
            return r.fail("ei", "point {d} ({d}, {d}): the canvas read no motion within 1 logical px of ({d:.1}, {d:.1})", .{ i, px, py, want.x, want.y });
        };
        worst = @max(worst, @max(@abs(num(got.get("x")) - want.x), @abs(num(got.get("y")) - want.y)));
    }

    // A click, a continuous then a discrete scroll on the canvas, and a
    // relative motion: each in its own frame, each read by the fixture.
    const Ev = struct {
        fn click(_: void, o: std.json.ObjectMap) bool {
            return isEvent(o, "click") and num(o.get("button")) == 1;
        }
        fn wheel(_: void, o: std.json.ObjectMap) bool {
            return isEvent(o, "wheel") and num(o.get("dy")) > 0;
        }
    };
    const btn_left = 0x110;
    for ([_]bool{ true, false }) |press| {
        ctx.button(abs, btn_left, press) catch |e| return r.fail("ei", "button: {s}", .{ei.describe(e)});
        ctx.frame(abs, ei.Context.nowUs()) catch |e| return r.fail("ei", "frame: {s}", .{ei.describe(e)});
    }
    _ = flog.wait(a, io, 2000, {}, Ev.click) orelse return r.fail("ei", "the fixture read no left click", .{});
    ctx.scroll(abs, 0, 10) catch |e| return r.fail("ei", "scroll: {s}", .{ei.describe(e)});
    ctx.frame(abs, ei.Context.nowUs()) catch |e| return r.fail("ei", "frame: {s}", .{ei.describe(e)});
    const smooth = flog.wait(a, io, 2000, {}, Ev.wheel) orelse return r.fail("ei", "the fixture read no continuous scroll", .{});
    ctx.scrollDiscrete(abs, 0, 120) catch |e| return r.fail("ei", "scroll_discrete: {s}", .{ei.describe(e)});
    ctx.frame(abs, ei.Context.nowUs()) catch |e| return r.fail("ei", "frame: {s}", .{ei.describe(e)});
    const notch = flog.wait(a, io, 2000, {}, Ev.wheel) orelse return r.fail("ei", "the fixture read no wheel notch", .{});
    ctx.stop(abs) catch {};
    const rel = ctx.waitDevice(.pointer, sock.deadlineIn(1000)) catch |e| return r.fail("ei", "relative pointer: {s}", .{ei.describe(e)});
    ctx.start(rel) catch |e| return r.fail("ei", "relative start_emulating: {s}", .{ei.describe(e)});
    const last_x: f64 = @floatCast(@floor(cx + cw * 4.5 / 5) - cx);
    ctx.moveBy(rel, -40, 0) catch |e| return r.fail("ei", "motion_relative: {s}", .{ei.describe(e)});
    ctx.frame(rel, ei.Context.nowUs()) catch |e| return r.fail("ei", "frame: {s}", .{ei.describe(e)});
    ctx.stop(rel) catch {};
    const Left = struct {
        fn of(from: f64, o: std.json.ObjectMap) bool {
            return isEvent(o, "pointer") and num(o.get("x")) < from;
        }
    };
    const back = flog.wait(a, io, 2000, last_x, Left.of) orelse return r.fail("ei", "the fixture read no relative motion to the left", .{});

    // A held key, a copy of the descriptor left open in another process:
    // closing the context must release the key all the same.
    const kbd = ctx.waitDevice(.keyboard, sock.deadlineIn(1000)) catch |e| return r.fail("ei", "keyboard: {s}", .{ei.describe(e)});
    ctx.start(kbd) catch |e| return r.fail("ei", "keyboard start_emulating: {s}", .{ei.describe(e)});
    ctx.key(kbd, key_a, true) catch |e| return r.fail("ei", "key: {s}", .{ei.describe(e)});
    ctx.frame(kbd, ei.Context.nowUs()) catch |e| return r.fail("ei", "frame: {s}", .{ei.describe(e)});
    const xkb_code: f64 = @floatFromInt(key_a + 8);
    const KeyWant = struct { code: f64, pressed: bool };
    const K = struct {
        fn key(want: KeyWant, o: std.json.ObjectMap) bool {
            const p = o.get("pressed") orelse return false;
            return isEvent(o, "key") and num(o.get("keycode")) == want.code and p == .bool and p.bool == want.pressed;
        }
    };
    _ = flog.wait(a, io, 2000, KeyWant{ .code = xkb_code, .pressed = true }, K.key) orelse return r.fail("ei", "the fixture read no key press", .{});
    const copy: i32 = @intCast(linux.dup(fd));
    var holder = std.process.spawn(io, .{
        .argv = &.{ "sleep", "10" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .inherit_files = &.{.{ .handle = copy, .flags = .{ .nonblocking = false } }},
    }) catch |e| return r.fail("ei", "holder: {t}", .{e});
    defer holder.kill(io);
    _ = linux.close(copy);
    if (!holds(@intCast(holder.id.?), eis_link)) return r.fail("ei", "the holder process did not keep the EIS descriptor", .{});
    const t0 = sock.nowNs();
    ctx.close();
    _ = c.callTyped(a, mutter_rd, session, rds.Stop, .{}, struct {}, 1000) catch {};
    const up = flog.wait(a, io, 2000, KeyWant{ .code = xkb_code, .pressed = false }, K.key) orelse
        return r.fail("ei", "the key stayed held 2 s after the context closed while another process kept its descriptor", .{});
    const up_ns: u64 = @intFromFloat(@max(0, num(up.get("mono_ns"))));
    const release_ns: u64 = up_ns -| t0;
    if (release_ns >= 50 * std.time.ns_per_ms) return r.fail("ei", "key released {d} ms after close, budget 50 ms", .{release_ns / std.time.ns_per_ms});
    std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
    r.ok("ei", "Mutter EIS: {s}; keymap layout {s}, `a` is evdev {d}; 20 absolute points on the canvas, worst error {d:.2} logical px; click, scroll dy {d:.1} then notch dy {d:.1}, relative motion -40 read as {d:.1} px; key held then released {d}.{d:0>1} ms after close with a copy of the descriptor open in pid {d}", .{
        devices, layout, key_a, worst, num(smooth.get("dy")), num(notch.get("dy")), num(back.get("x")) - last_x, release_ns / std.time.ns_per_ms, release_ns % std.time.ns_per_ms / 100_000, holder.id.?,
    });
}
