//! One headless test session (US-074, US-075): a private runtime folder
//! `/run/user/<uid>/nc-<id>`, a private `HOME` and XDG folders inside it, a
//! private session bus that activates only dconf, the permission store and
//! the portals, a fake system bus with its stand-in services, PipeWire and
//! WirePlumber without hardware, the AT-SPI bus, and the compositor of the
//! family. Every process starts from an empty environment (`env -i`) plus
//! the variables set here, and descends from the launcher, a child
//! subreaper, so stopping the session kills them all.

const std = @import("std");
const linux = std.os.linux;
const proc = @import("proc.zig");
const witness = @import("witness.zig");

pub const Family = enum {
    gnome,
    kde,
    sway,
    labwc,

    pub fn compositor(f: Family) []const u8 {
        return switch (f) {
            .gnome => "gnome-shell",
            .kde => "kwin_wayland",
            .sway => "sway",
            .labwc => "labwc",
        };
    }
};

pub const Options = struct {
    /// The parent of the private runtime folder, `/run/user/<uid>` by default.
    runtime_parent: ?[]const u8 = null,
    /// The compositor and service logs go to `<log_root>/<id>/`.
    log_root: []const u8,
    start_timeout_ms: u32 = 30_000,
    /// Tests only: replaces the compositor's command line.
    test_compositor: ?[]const []const u8 = null,
};

/// The system PATH of the session: none of the user's own folders.
const session_path = "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin";
const libexec = "/usr/libexec";
/// sockaddr_un holds 108 bytes, the terminating NUL included.
pub const max_socket_path = 107;

pub const Failure = struct {
    code: u8,
    message: []const u8,
};

pub const Session = struct {
    a: std.mem.Allocator,
    io: std.Io,
    family: Family,
    opts: Options,
    id: [6]u8,
    rt: []const u8,
    home: []const u8,
    nc: []const u8,
    log_dir: []const u8,
    /// The environment of the session's clients (WAYLAND_DISPLAY once the
    /// compositor is up).
    env: std.process.Environ.Map,
    real: witness.Real,
    root: i32,
    reaper: proc.Reaper = .{},
    compositor_pid: i32 = 0,
    /// The commands run in the session, stopped with the compositor.
    commands: std.ArrayList(i32) = .empty,
    compositor_log: []const u8 = "",
    before: witness.Snapshot = .{},
    session_pids: witness.SessionPids = .empty,
    reported: witness.SessionPids = .empty,
    differences: std.ArrayList([]const u8) = .empty,
    /// The entries created in `/run/user/<uid>` during the session.
    watch: witness.Watch = .{},
    /// Changes of the real session the witness saw but blames on no one.
    notes: std.ArrayList([]const u8) = .empty,
    last_live_ns: i96 = 0,
    started: bool = false,
    /// Set by a stop signal: the waits of the start give up.
    abort: *const std.atomic.Value(bool),
    binaries: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Checks the binaries and the socket paths before anything starts.
    pub fn init(a: std.mem.Allocator, io: std.Io, family: Family, opts: Options, real_env: *const std.process.Environ.Map, abort: *const std.atomic.Value(bool)) !union(enum) { ok: Session, failed: Failure } {
        const uid = linux.getuid();
        const run_user = try std.fmt.allocPrint(a, "/run/user/{d}", .{uid});
        const parent = opts.runtime_parent orelse run_user;
        var id: [6]u8 = undefined;
        randomId(&id);
        const rt = try std.fmt.allocPrint(a, "{s}/nc-{s}", .{ parent, id });
        var s: Session = .{
            .a = a,
            .io = io,
            .family = family,
            .opts = opts,
            .id = id,
            .rt = rt,
            .home = try std.fmt.allocPrint(a, "{s}/home", .{rt}),
            .nc = try std.fmt.allocPrint(a, "{s}/nc", .{rt}),
            .log_dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ opts.log_root, id }),
            .env = .init(a),
            .real = .{
                .uid = uid,
                .home = real_env.get("HOME") orelse "",
                .runtime = real_env.get("XDG_RUNTIME_DIR") orelse run_user,
                .run_user = run_user,
            },
            .root = linux.getpid(),
            .abort = abort,
        };

        // Every binary first: a missing one skips the family (code 77).
        var needed: std.ArrayList([]const u8) = .empty;
        if (opts.test_compositor) |cmd| try needed.append(a, cmd[0]) else try needed.append(a, family.compositor());
        try needed.appendSlice(a, &.{ "dbus-daemon", "gdbus", "dconf", "python3", "pipewire", "wireplumber", libexec ++ "/at-spi-bus-launcher", libexec ++ "/at-spi2-registryd" });
        for (needed.items) |name| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const found = proc.which(&buf, session_path, name) orelse
                return .{ .failed = .{ .code = 77, .message = try std.fmt.allocPrint(a, "{s} introuvable : installe-le ou saute cette famille.", .{name}) } };
            try s.binaries.put(a, name, try a.dupe(u8, found));
        }

        // The longest socket paths the session creates.
        const suffixes = [_][]const u8{
            "/bus",                            "/system_bus_socket",
            "/wayland-nc",                     "/wayland-32",
            "/at-spi/bus_0",                   "/pipewire-0-manager",
            "/nc/control",                     "/sway-ipc.4294967295.4194304.sock",
            "/home/.cache/ibus/dbus-XXXXXXXX",
        };
        for (suffixes) |suffix| {
            if (rt.len + suffix.len > max_socket_path) return .{ .failed = .{ .code = 2, .message = try std.fmt.allocPrint(
                a,
                "Chemin de socket trop long ({d} octets, limite {d}) : {s}{s}. Choisis un dossier d'exécution plus court.",
                .{ rt.len + suffix.len, max_socket_path, rt, suffix },
            ) } };
        }

        try s.setEnv(real_env);
        return .{ .ok = s };
    }

    fn bin(s: *const Session, name: []const u8) []const u8 {
        return s.binaries.get(name).?;
    }

    fn setEnv(s: *Session, real_env: *const std.process.Environ.Map) !void {
        const e = &s.env;
        try e.put("HOME", s.home);
        try e.put("XDG_RUNTIME_DIR", s.rt);
        try e.put("XDG_CONFIG_HOME", try s.path(&.{ s.home, ".config" }));
        try e.put("XDG_DATA_HOME", try s.path(&.{ s.home, ".local/share" }));
        try e.put("XDG_STATE_HOME", try s.path(&.{ s.home, ".local/state" }));
        try e.put("XDG_CACHE_HOME", try s.path(&.{ s.home, ".cache" }));
        try e.put("PATH", session_path);
        try e.put("LANG", "C.UTF-8");
        if (real_env.get("USER")) |v| try e.put("USER", v);
        if (real_env.get("LOGNAME")) |v| try e.put("LOGNAME", v);
        try e.put("DBUS_SESSION_BUS_ADDRESS", try std.fmt.allocPrint(s.a, "unix:path={s}/bus", .{s.rt}));
        try e.put("DBUS_SYSTEM_BUS_ADDRESS", try std.fmt.allocPrint(s.a, "unix:path={s}/system_bus_socket", .{s.rt}));
        try e.put("XDG_SESSION_ID", "nc-none");
        try e.put("XDG_SESSION_TYPE", "wayland");
        try e.put("XDG_CURRENT_DESKTOP", switch (s.family) {
            .gnome => "GNOME",
            .kde => "KDE",
            .sway => "sway",
            .labwc => "labwc:wlroots",
        });
        try e.put("XDG_SESSION_DESKTOP", @tagName(s.family));
        try e.put("GIO_USE_VFS", "local");
        try e.put("GVFS_DISABLE_FUSE", "1");
        try e.put("NC_SESSION", @tagName(s.family));
        try e.put("NC_SESSION_ID", &s.id);
    }

    fn path(s: *const Session, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(s.a, parts);
    }

    fn nowNs(s: *const Session) i96 {
        return std.Io.Clock.awake.now(s.io).toNanoseconds();
    }

    /// Every wait of the session also judges the entries created in
    /// `/run/user/<uid>` since the last one, while their creator lives.
    fn sleepMs(s: *Session, ms: i64) void {
        s.watch.poll(s.a, s.io, s.real, s.root, &s.differences);
        std.Io.sleep(s.io, .fromMilliseconds(ms), .awake) catch {};
    }

    /// Takes the witness's first snapshot, then starts every process of
    /// the session. On failure the session is already stopped.
    pub fn start(s: *Session) !?Failure {
        _ = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
        sweepStale(s.a, s.io, s.real.run_user, s.opts.runtime_parent orelse s.real.run_user);
        s.watch = .init(s.real);
        s.before = try witness.snapshot(s.a, s.io, s.real);
        s.started = true;
        active = s;
        if (try s.startProcesses()) |f| {
            s.stop();
            return f;
        }
        return null;
    }

    fn startProcesses(s: *Session) !?Failure {
        const cwd = std.Io.Dir.cwd();
        // The runtime folder, readable by the user alone, then the rest.
        const rt_z = try std.fmt.allocPrintSentinel(s.a, "{s}", .{s.rt}, 0);
        if (linux.errno(linux.mkdir(rt_z, 0o700)) != .SUCCESS)
            return .{ .code = 2, .message = try std.fmt.allocPrint(s.a, "Impossible de créer {s}.", .{s.rt}) };
        for ([_][]const u8{ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME" }) |v|
            try cwd.createDirPath(s.io, s.env.get(v).?);
        try cwd.createDirPath(s.io, try s.path(&.{ s.nc, "services" }));
        // Who owns the folder: a later launcher removes it once this pid is dead.
        try s.writeFile(try s.path(&.{ s.nc, "launcher.pid" }), try std.fmt.allocPrint(s.a, "{d}\n", .{s.root}));
        try cwd.createDirPath(s.io, s.log_dir);
        try s.writeConfigs();

        // The fake system bus and its services.
        const system_conf = try s.path(&.{ s.nc, "system.conf" });
        const sys_pid = try s.spawnService("system-bus", &.{ s.bin("dbus-daemon"), "--nofork", "--nopidfile", try std.fmt.allocPrint(s.a, "--config-file={s}", .{system_conf}) }, &s.env);
        if (try s.waitPath(try s.path(&.{ s.rt, "system_bus_socket" }), sys_pid, "dbus-daemon (bus système factice)", "system-bus")) |f| return f;
        const fake = try s.path(&.{ s.nc, "fake_system_bus.py" });
        switch (s.family) {
            .gnome => {
                const pid = try s.spawnService("fake-gdm", &.{ s.bin("python3"), "-I", fake, "--gdm" }, &s.env);
                if (try s.waitName("--system", "org.gnome.DisplayManager", pid, "faux GDM", "fake-gdm")) |f| return f;
            },
            .sway, .labwc => {
                const pid = try s.spawnService("fake-login1", &.{ s.bin("python3"), "-I", fake, "--login1" }, &s.env);
                if (try s.waitName("--system", "org.freedesktop.login1", pid, "faux logind", "fake-login1")) |f| return f;
            },
            .kde => {},
        }

        // The private session bus.
        const session_conf = try s.path(&.{ s.nc, "session.conf" });
        const bus_pid = try s.spawnService("session-bus", &.{ s.bin("dbus-daemon"), "--nofork", "--nopidfile", try std.fmt.allocPrint(s.a, "--config-file={s}", .{session_conf}) }, &s.env);
        if (try s.waitPath(try s.path(&.{ s.rt, "bus" }), bus_pid, "dbus-daemon (bus de session)", "session-bus")) |f| return f;

        // dconf with locking and sleep off, compiled before any reader.
        const dconf_dir = try s.path(&.{ s.env.get("XDG_CONFIG_HOME").?, "dconf" });
        try cwd.createDirPath(s.io, dconf_dir);
        const compiled = try s.runOnce("dconf", &.{ s.bin("dconf"), "compile", try s.path(&.{ dconf_dir, "user" }), try s.path(&.{ s.nc, "dconf.d" }) });
        if (!compiled) return .{ .code = 2, .message = try std.fmt.allocPrint(s.a, "dconf compile a échoué : journal {s}/dconf.log", .{s.log_dir}) };

        // PipeWire and WirePlumber, without audio, Bluetooth or cameras.
        const pw = try s.spawnService("pipewire", &.{s.bin("pipewire")}, &s.env);
        if (try s.waitPath(try s.path(&.{ s.rt, "pipewire-0" }), pw, "pipewire", "pipewire")) |f| return f;
        _ = try s.spawnService("wireplumber", &.{s.bin("wireplumber")}, &s.env);

        // The AT-SPI bus, then its registry.
        const atspi = try s.spawnService("at-spi-bus-launcher", &.{ s.bin(libexec ++ "/at-spi-bus-launcher"), "--launch-immediately" }, &s.env);
        if (try s.waitName("--session", "org.a11y.Bus", atspi, "at-spi-bus-launcher", "at-spi-bus-launcher")) |f| return f;
        _ = try s.spawnService("at-spi2-registryd", &.{s.bin(libexec ++ "/at-spi2-registryd")}, &s.env);

        return s.startCompositor();
    }

    fn startCompositor(s: *Session) !?Failure {
        var env = try s.env.clone(s.a);
        const name = s.family.compositor();
        var argv: std.ArrayList([]const u8) = .empty;
        var display: ?[]const u8 = "wayland-nc";
        if (s.opts.test_compositor) |cmd| {
            try argv.append(s.a, s.bin(cmd[0]));
            try argv.appendSlice(s.a, cmd[1..]);
        } else switch (s.family) {
            .gnome => try argv.appendSlice(s.a, &.{ s.bin(name), "--headless", "--wayland", "--no-x11", "--virtual-monitor", "1920x1080", "--wayland-display=wayland-nc" }),
            .kde => {
                try argv.appendSlice(s.a, &.{ s.bin(name), "--virtual", "--socket", "wayland-nc", "--width", "1280", "--height", "800" });
                // KWin's own Qt platform; its clients keep Wayland.
                try env.put("QT_QPA_PLATFORM", "offscreen");
            },
            .sway, .labwc => {
                if (s.family == .sway)
                    try argv.appendSlice(s.a, &.{ s.bin(name), "-c", try s.path(&.{ s.nc, "sway.conf" }) })
                else
                    try argv.appendSlice(s.a, &.{ s.bin(name), "-C", try s.path(&.{ s.nc, "labwc" }) });
                try env.put("WLR_BACKENDS", "headless");
                try env.put("WLR_RENDERER", "pixman");
                try env.put("WLR_LIBINPUT_NO_DEVICES", "1");
                // labwc has no switch for Xwayland: wlroots still binds a
                // lazy X socket in the shared /tmp/.X11-unix for the
                // session's life (removed at its end, which the witness
                // checks), but without a binary no X server ever starts.
                try env.put("WLR_XWAYLAND", "/nonexistent/Xwayland");
                // wlroots names its socket itself: wayland-0 in this folder.
                display = null;
            },
        }
        s.compositor_log = try std.fmt.allocPrint(s.a, "{s}/compositor.log", .{s.log_dir});
        s.compositor_pid = try s.spawnService("compositor", argv.items, &env);

        const deadline = s.nowNs() + @as(i96, s.opts.start_timeout_ms) * std.time.ns_per_ms;
        const fail: Failure = .{ .code = 2, .message = try std.fmt.allocPrint(s.a, "Le compositeur {s} n'a pas démarré en {d} s : journal {s}", .{ name, @divTrunc(s.opts.start_timeout_ms + 999, 1000), s.compositor_log }) };
        // Its Wayland socket.
        const socket = while (true) {
            if (s.abort.load(.acquire)) return fail;
            if (display) |d| {
                if (exists(try s.path(&.{ s.rt, d }))) break d;
            } else if (try s.findEntry("wayland-", "")) |d| {
                if (!std.mem.endsWith(u8, d, ".lock")) break d;
            }
            if (s.nowNs() > deadline or !s.running(s.compositor_pid)) return fail;
            s.sleepMs(20);
        };
        try s.env.put("WAYLAND_DISPLAY", socket);
        // Its D-Bus name, the sign that it is ready to serve.
        const bus_name: ?[]const u8 = switch (s.family) {
            .gnome => "org.gnome.Shell",
            .kde => "org.kde.KWin",
            else => null,
        };
        if (bus_name) |bn| {
            while (true) {
                if (s.abort.load(.acquire) or s.nowNs() > deadline or !s.running(s.compositor_pid)) return fail;
                if (try s.nameOwned("--session", bn)) break;
                s.sleepMs(50);
            }
        }
        if (s.family == .gnome and s.opts.test_compositor == null) {
            if (try s.leaveOverview(deadline)) |f| return f;
        }
        if (s.family == .sway) {
            const sock = while (true) {
                if (try s.findEntry("sway-ipc.", ".sock")) |n| break n;
                if (s.abort.load(.acquire) or s.nowNs() > deadline or !s.running(s.compositor_pid)) return fail;
                s.sleepMs(20);
            };
            try s.env.put("SWAYSOCK", try s.path(&.{ s.rt, sock }));
        }
        return null;
    }

    /// GNOME Shell starts on its overview, where clicks and keys go to the
    /// Shell, not to windows. The session is ready once the startup
    /// animation has shown it and the launcher has hidden it again
    /// (`OverviewActive`, a property any client of the bus may set).
    /// A Shell that never shows it within 5 s is taken as it is.
    fn leaveOverview(s: *Session, deadline: i96) !?Failure {
        const prop = [_][]const u8{ "--session", "--dest", "org.gnome.Shell", "--object-path", "/org/gnome/Shell", "--method" };
        const shown_by = @min(deadline, s.nowNs() + 5 * std.time.ns_per_s);
        var seen = false;
        while (s.nowNs() < (if (seen) deadline else shown_by)) {
            if (s.abort.load(.acquire) or !s.running(s.compositor_pid)) break;
            const out = try s.gdbusCall(&(prop ++ [_][]const u8{ "org.freedesktop.DBus.Properties.Get", "org.gnome.Shell", "OverviewActive" }));
            if (std.mem.indexOf(u8, out, "true") != null) {
                seen = true;
                _ = try s.gdbusCall(&(prop ++ [_][]const u8{ "org.freedesktop.DBus.Properties.Set", "org.gnome.Shell", "OverviewActive", "<false>" }));
            } else if (seen) return null;
            s.sleepMs(50);
        }
        if (!seen and s.running(s.compositor_pid)) return null;
        return .{ .code = 2, .message = try std.fmt.allocPrint(s.a, "La vue d'ensemble de GNOME Shell ne s'est pas fermée : journal {s}", .{s.compositor_log}) };
    }

    /// `gdbus call` in the session; its standard output.
    fn gdbusCall(s: *Session, args: []const []const u8) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(s.a, &.{ s.bin("gdbus"), "call" });
        try argv.appendSlice(s.a, args);
        const r = try std.process.run(s.a, s.io, .{ .argv = argv.items, .environ_map = &s.env, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) });
        return r.stdout;
    }

    fn findEntry(s: *Session, prefix: []const u8, suffix: []const u8) !?[]const u8 {
        var dir = std.Io.Dir.openDirAbsolute(s.io, s.rt, .{ .iterate = true }) catch return null;
        defer dir.close(s.io);
        var it = dir.iterate();
        while (try it.next(s.io)) |e| {
            if (std.mem.startsWith(u8, e.name, prefix) and std.mem.endsWith(u8, e.name, suffix)) return try s.a.dupe(u8, e.name);
        }
        return null;
    }

    fn running(s: *Session, pid: i32) bool {
        s.reaper.reap(s.a);
        return !s.reaper.statuses.contains(pid);
    }

    fn logFile(s: *Session, name: []const u8) !std.Io.File {
        const p = try std.fmt.allocPrint(s.a, "{s}/{s}.log", .{ s.log_dir, name });
        return std.Io.Dir.cwd().createFile(s.io, p, .{ .truncate = false });
    }

    fn spawnService(s: *Session, name: []const u8, argv: []const []const u8, env: *const std.process.Environ.Map) !i32 {
        const log = try s.logFile(name);
        defer log.close(s.io);
        const pid = try proc.spawn(s.io, argv, env, s.rt, .ignore, .{ .file = log }, .{ .file = log });
        try s.session_pids.put(s.a, pid, {});
        return pid;
    }

    /// Runs a short command of the session to its end; true on code 0.
    fn runOnce(s: *Session, name: []const u8, argv: []const []const u8) !bool {
        const pid = try s.spawnService(name, argv, &s.env);
        while (true) {
            s.reaper.reap(s.a);
            if (s.reaper.take(pid)) |st| return proc.exitCode(st) == 0;
            s.sleepMs(10);
        }
    }

    fn nameOwned(s: *Session, bus: []const u8, name: []const u8) !bool {
        const pid = try proc.spawn(s.io, &.{ s.bin("gdbus"), "wait", bus, "--timeout", "1", name }, &s.env, s.rt, .ignore, .ignore, .ignore);
        try s.session_pids.put(s.a, pid, {});
        while (true) {
            s.reaper.reap(s.a);
            if (s.reaper.take(pid)) |st| return proc.exitCode(st) == 0;
            s.sleepMs(10);
        }
    }

    fn waitPath(s: *Session, p: []const u8, pid: i32, what: []const u8, log: []const u8) !?Failure {
        const deadline = s.nowNs() + @as(i96, s.opts.start_timeout_ms) * std.time.ns_per_ms;
        while (!exists(p)) {
            if (s.abort.load(.acquire) or s.nowNs() > deadline or !s.running(pid))
                return .{ .code = 2, .message = try std.fmt.allocPrint(s.a, "{s} n'a pas démarré : journal {s}/{s}.log", .{ what, s.log_dir, log }) };
            s.sleepMs(10);
        }
        return null;
    }

    fn waitName(s: *Session, bus: []const u8, name: []const u8, pid: i32, what: []const u8, log: []const u8) !?Failure {
        const deadline = s.nowNs() + @as(i96, s.opts.start_timeout_ms) * std.time.ns_per_ms;
        while (!try s.nameOwned(bus, name)) {
            if (s.abort.load(.acquire) or s.nowNs() > deadline or !s.running(pid))
                return .{ .code = 2, .message = try std.fmt.allocPrint(s.a, "{s} n'a pas démarré : journal {s}/{s}.log", .{ what, s.log_dir, log }) };
        }
        return null;
    }

    fn writeFile(s: *Session, p: []const u8, data: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = p, .data = data });
    }

    fn writeConfigs(s: *Session) !void {
        const header =
            \\<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
            \\ "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
            \\
        ;
        const policy =
            \\  <policy context="default">
            \\    <allow user="*"/>
            \\    <allow own="*"/>
            \\    <allow send_type="method_call"/>
            \\    <allow send_destination="*" eavesdrop="true"/>
            \\    <allow eavesdrop="true"/>
            \\  </policy>
            \\
        ;
        // The session bus activates only the services copied below; no
        // standard service folder, no systemd activation.
        try s.writeFile(try s.path(&.{ s.nc, "session.conf" }), try std.fmt.allocPrint(s.a, "{s}<busconfig>\n  <type>session</type>\n  <keep_umask/>\n  <listen>unix:path={s}/bus</listen>\n  <auth>EXTERNAL</auth>\n  <servicedir>{s}/services</servicedir>\n{s}</busconfig>\n", .{ header, s.rt, s.nc, policy }));
        try s.writeFile(try s.path(&.{ s.nc, "system.conf" }), try std.fmt.allocPrint(s.a, "{s}<busconfig>\n  <type>system</type>\n  <listen>unix:path={s}/system_bus_socket</listen>\n  <auth>EXTERNAL</auth>\n{s}</busconfig>\n", .{ header, s.rt, policy }));

        var services: std.ArrayList([]const u8) = .empty;
        try services.appendSlice(s.a, &.{ "ca.desrt.dconf", "org.freedesktop.impl.portal.PermissionStore", "org.freedesktop.portal.Desktop" });
        switch (s.family) {
            .gnome => try services.appendSlice(s.a, &.{ "org.freedesktop.impl.portal.desktop.gnome", "org.freedesktop.impl.portal.desktop.gtk" }),
            .kde => try services.append(s.a, "org.freedesktop.impl.portal.desktop.kde"),
            .sway, .labwc => try services.appendSlice(s.a, &.{ "org.freedesktop.impl.portal.desktop.wlr", "org.freedesktop.impl.portal.desktop.gtk" }),
        }
        for (services.items) |name| {
            const src = try std.fmt.allocPrint(s.a, "/usr/share/dbus-1/services/{s}.service", .{name});
            const text = std.Io.Dir.cwd().readFileAlloc(s.io, src, s.a, .limited(64 * 1024)) catch continue;
            var lines = std.mem.splitScalar(u8, text, '\n');
            const exec = while (lines.next()) |l| {
                if (std.mem.startsWith(u8, l, "Exec=")) break l;
            } else continue;
            try s.writeFile(try std.fmt.allocPrint(s.a, "{s}/services/{s}.service", .{ s.nc, name }), try std.fmt.allocPrint(s.a, "[D-BUS Service]\nName={s}\n{s}\n", .{ name, exec }));
        }

        try std.Io.Dir.cwd().createDirPath(s.io, try s.path(&.{ s.nc, "dconf.d" }));
        try s.writeFile(try s.path(&.{ s.nc, "dconf.d", "00-nc" }),
            \\[org/gnome/desktop/screensaver]
            \\lock-enabled=false
            \\idle-activation-enabled=false
            \\
            \\[org/gnome/desktop/session]
            \\idle-delay=uint32 0
            \\
            \\[org/gnome/settings-daemon/plugins/power]
            \\sleep-inactive-ac-type='nothing'
            \\sleep-inactive-battery-type='nothing'
            \\idle-dim=false
            \\
            \\[org/gnome/shell]
            \\welcome-dialog-last-shown-version='999'
            \\
        );

        const wp = try s.path(&.{ s.env.get("XDG_CONFIG_HOME").?, "wireplumber", "wireplumber.conf.d" });
        try std.Io.Dir.cwd().createDirPath(s.io, wp);
        try s.writeFile(try s.path(&.{ wp, "50-nc-session.conf" }),
            \\# A test session reaches no sound card, Bluetooth device or camera.
            \\wireplumber.profiles = {
            \\  main = {
            \\    hardware.audio = disabled
            \\    hardware.bluetooth = disabled
            \\    hardware.video-capture = disabled
            \\    support.logind = disabled
            \\  }
            \\}
            \\
        );

        try s.writeFile(try s.path(&.{ s.nc, "fake_system_bus.py" }), @embedFile("fake_system_bus.py"));

        switch (s.family) {
            .kde => try s.writeFile(try s.path(&.{ s.env.get("XDG_CONFIG_HOME").?, "kscreenlockerrc" }),
                \\[Daemon]
                \\Autolock=false
                \\LockOnResume=false
                \\
            ),
            .sway => try s.writeFile(try s.path(&.{ s.nc, "sway.conf" }),
                \\# A test session of neo-compute: no Xwayland, no bar, no idle daemon.
                \\xwayland disable
                \\
            ),
            .labwc => {
                try std.Io.Dir.cwd().createDirPath(s.io, try s.path(&.{ s.nc, "labwc" }));
                try s.writeFile(try s.path(&.{ s.nc, "labwc", "rc.xml" }),
                    \\<?xml version="1.0"?>
                    \\<labwc_config>
                    \\  <core><decoration>server</decoration></core>
                    \\</labwc_config>
                    \\
                );
            },
            .gnome => {},
        }
    }

    /// Starts `argv` in the session with the given standard streams.
    pub fn spawnCommand(s: *Session, argv: []const []const u8, cwd: ?[]const u8, stdin: proc.Stdio, stdout: proc.Stdio, stderr: proc.Stdio) !i32 {
        const pid = try proc.spawn(s.io, argv, &s.env, cwd, stdin, stdout, stderr);
        try s.session_pids.put(s.a, pid, {});
        try s.commands.append(s.a, pid);
        return pid;
    }

    /// Reaps exited children and, once a second, runs the witness's live
    /// check.
    pub fn tick(s: *Session) void {
        s.reaper.reap(s.a);
        s.watch.poll(s.a, s.io, s.real, s.root, &s.differences);
        const now = s.nowNs();
        if (now - s.last_live_ns < std.time.ns_per_s) return;
        s.last_live_ns = now;
        witness.live(s.a, s.io, s.real, s.root, s.rt, &s.session_pids, &s.reported, &s.differences) catch |err| {
            s.differences.append(s.a, std.fmt.allocPrint(s.a, "contrôle de la session impossible ({t})", .{err}) catch return) catch {};
        };
    }

    /// Kills every process of the session, removes its runtime folder, and
    /// lets the witness compare. Idempotent.
    pub fn stop(s: *Session) void {
        if (!s.started) return;
        s.started = false;
        active = null;
        // One last live check before anything dies.
        s.last_live_ns = 0;
        s.tick();
        s.killAll();
        s.unmountPrivate();
        std.Io.Dir.cwd().deleteTree(s.io, s.rt) catch |err| {
            s.differences.append(s.a, std.fmt.allocPrint(s.a, "{s} n'a pas pu être supprimé ({t})", .{ s.rt, err }) catch return) catch {};
        };
        if (exists(s.rt)) s.differences.append(s.a, std.fmt.allocPrint(s.a, "{s} existe encore après l'arrêt", .{s.rt}) catch return) catch {};
        defer s.watch.deinit();
        const after = witness.snapshot(s.a, s.io, s.real) catch |err| {
            s.differences.append(s.a, std.fmt.allocPrint(s.a, "second relevé du témoin impossible ({t})", .{err}) catch return) catch {};
            return;
        };
        s.watch.poll(s.a, s.io, s.real, s.root, &s.differences);
        witness.compare(s.a, s.io, s.real, s.before, after, &s.session_pids, &s.watch, &s.differences, &s.notes) catch {};
        witness.leftovers(s.a, s.io, s.rt, &s.differences) catch {};
    }

    fn killAll(s: *Session) void {
        const gpa = std.heap.page_allocator;
        // The compositor and its clients first, then the services, the
        // buses last, so nothing sees a service vanish while it still
        // runs; then whatever remains.
        const Phase = enum { compositor, services, buses, kill };
        const phases = [_]struct { what: Phase, sig: linux.SIG, ms: i64 }{
            .{ .what = .compositor, .sig = .TERM, .ms = 3000 },
            .{ .what = .services, .sig = .TERM, .ms = 3000 },
            .{ .what = .buses, .sig = .TERM, .ms = 2000 },
            .{ .what = .kill, .sig = .KILL, .ms = 2000 },
        };
        for (phases) |ph| {
            const desc = proc.descendants(gpa, s.io, s.root) catch continue;
            defer gpa.free(desc);
            var targets: std.ArrayList(i32) = .empty;
            defer targets.deinit(gpa);
            for (desc) |pid| {
                var comm: [64]u8 = undefined;
                const c = proc.commOf(pid, &comm);
                const is_bus = std.mem.startsWith(u8, c, "dbus-daemon") or std.mem.startsWith(u8, c, "dbus-broker");
                switch (ph.what) {
                    .compositor => if (pid != s.compositor_pid and std.mem.indexOfScalar(i32, s.commands.items, pid) == null) continue,
                    .services => if (is_bus) continue,
                    .buses, .kill => {},
                }
                s.session_pids.put(s.a, pid, {}) catch {};
                _ = linux.kill(pid, ph.sig);
                targets.append(gpa, pid) catch {};
            }
            const deadline = s.nowNs() + @as(i96, ph.ms) * std.time.ns_per_ms;
            while (s.nowNs() < deadline) {
                s.reaper.reap(s.a);
                var any = false;
                for (targets.items) |pid| if (proc.alive(pid)) {
                    any = true;
                    break;
                };
                if (!any) break;
                s.sleepMs(10);
            }
        }
        s.reaper.reap(s.a);
    }

    /// A FUSE folder a service mounted in the private runtime folder.
    fn unmountPrivate(s: *Session) void {
        const info = proc.readAll(s.a, "/proc/self/mountinfo", 16 * 1024 * 1024) catch return;
        var lines = std.mem.splitScalar(u8, info, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            var col: usize = 0;
            while (f.next()) |tok| : (col += 1) {
                if (col != 4) continue;
                if (std.mem.startsWith(u8, tok, s.rt)) {
                    const pid = proc.spawn(s.io, &.{ "fusermount3", "-u", "-z", tok }, &s.env, null, .ignore, .ignore, .ignore) catch break;
                    while (s.reaper.take(pid) == null) {
                        s.reaper.reap(s.a);
                        s.sleepMs(10);
                    }
                }
                break;
            }
        }
    }
};

/// The session this process runs, for the panic handler.
var active: ?*Session = null;

/// On a panic of the launcher: kill the session and remove its runtime
/// folder, so no private compositor outlives it. Best effort, no witness.
pub fn emergencyStop() void {
    const s = active orelse return;
    active = null;
    const gpa = std.heap.page_allocator;
    for (0..3) |_| {
        const desc = proc.descendants(gpa, s.io, s.root) catch return;
        defer gpa.free(desc);
        if (desc.len == 0) break;
        for (desc) |pid| _ = linux.kill(pid, .KILL);
        s.reaper.reap(gpa);
        std.Io.sleep(s.io, .fromMilliseconds(50), .awake) catch {};
    }
    std.Io.Dir.cwd().deleteTree(s.io, s.rt) catch {};
}

/// Removes the test runtime folders of launchers that died without
/// stopping their session (SIGKILL): their processes first, then the
/// folder. Each one is named on stderr.
fn sweepStale(a: std.mem.Allocator, io: std.Io, run_user: []const u8, parent: []const u8) void {
    _ = run_user;
    var dir = std.Io.Dir.openDirAbsolute(io, parent, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, "nc-") or e.kind != .directory) continue;
        const rt = std.fs.path.join(a, &.{ parent, e.name }) catch continue;
        var buf: [32]u8 = undefined;
        const pid_path = std.fs.path.join(a, &.{ rt, "nc", "launcher.pid" }) catch continue;
        const text = proc.readSmall(pid_path, &buf) orelse continue;
        const pid = std.fmt.parseInt(i32, std.mem.trim(u8, text, " \n"), 10) catch continue;
        if (proc.alive(pid)) continue;
        const gpa = std.heap.page_allocator;
        const pids = proc.allPids(gpa, io) catch continue;
        defer gpa.free(pids);
        const scratch = gpa.alloc(u8, 1024 * 1024) catch continue;
        defer gpa.free(scratch);
        var value: [4096]u8 = undefined;
        var killed: usize = 0;
        for (pids) |p| {
            const v = proc.environValue(p, "XDG_RUNTIME_DIR", scratch, &value) orelse continue;
            if (!std.mem.eql(u8, v, rt)) continue;
            _ = linux.kill(p, .KILL);
            killed += 1;
        }
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        std.Io.Dir.cwd().deleteTree(io, rt) catch {};
        std.debug.print("linux-session : session orpheline {s} (lanceur {d} mort) supprimée, {d} processus tués\n", .{ rt, pid, killed });
    }
}

fn exists(p: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{p}, 0) catch return false;
    return linux.errno(linux.access(z, linux.F_OK)) == .SUCCESS;
}

fn randomId(out: *[6]u8) void {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    var bytes: [6]u8 = undefined;
    _ = linux.getrandom(&bytes, bytes.len, 0);
    for (out, bytes) |*c, b| c.* = alphabet[b % alphabet.len];
}
