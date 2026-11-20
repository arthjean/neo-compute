//! tools/linux-session: headless test sessions isolated from the user's
//! real session, for the selftests, the bench and the evals (PRD Linux
//! port, US-074 to US-076, T5). The shipped server never starts a
//! compositor; this developer tool does, and its witness proves after
//! each session that nothing of the real session changed.
//!
//! Exit codes: the command's own; 2 when the session cannot start; 3 when
//! the witness found a difference in the real session (it wins over the
//! command's code); 77 when a binary of the family is missing.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const proc = @import("proc.zig");
const session = @import("session.zig");
const control = @import("control.zig");
const Session = session.Session;
const Family = session.Family;

const usage =
    \\usage: linux-session [options] <famille> exec -- <commande...>
    \\       linux-session [options] <famille> <arguments de neo-compute...>
    \\       linux-session [options] start <famille>
    \\       linux-session [options] exec <id> -- <commande...>
    \\       linux-session [options] stop <id>
    \\       linux-session [options] cycles <famille> <n>
    \\familles : gnome, kde, sway, labwc
    \\options : --server <neo-compute>    le serveur des formes sans exec
    \\          --log-dir <dossier>       journaux (défaut : $XDG_CACHE_HOME/neo-compute/linux-session)
    \\          --runtime-parent <dossier> parent du dossier d'exécution (défaut : /run/user/<uid>)
    \\          --start-timeout-ms <n>    délai de démarrage (défaut : 30000)
    \\          --test-compositor <cmd>   tests du lanceur : remplace la commande du compositeur
    \\
;

/// A panic stops the session before the default handler reports it.
pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    session.emergencyStop();
    std.debug.defaultPanic(msg, first_trace_addr);
}

var signal_pipe: [2]i32 = .{ -1, -1 };
var aborting: std.atomic.Value(bool) = .init(false);
var last_signal: std.atomic.Value(u32) = .init(0);

fn onSignal(sig: posix.SIG) callconv(.c) void {
    last_signal.store(@backingInt(sig), .release);
    aborting.store(true, .release);
    const b = [1]u8{'s'};
    _ = linux.write(signal_pipe[1], &b, 1);
}

fn installSignals() void {
    _ = linux.pipe2(&signal_pipe, .{ .CLOEXEC = true, .NONBLOCK = true });
    const act: posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = posix.sigemptyset(), .flags = posix.SA.RESTART };
    for ([_]posix.SIG{ .INT, .TERM, .HUP }) |sig| posix.sigaction(sig, &act, null);
}

/// The signal that arrived since the last call, consumed; 0 for none.
fn takeSignal() u32 {
    var buf: [16]u8 = undefined;
    const n = linux.read(signal_pipe[0], &buf, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return 0;
    // The pipe only wakes the loop: the abort flag stays set, the next
    // wait of a start gives up.
    return last_signal.load(.acquire);
}

const Opts = struct {
    session: session.Options,
    server: ?[]const u8 = null,
    /// The options as given, for a launcher that starts itself again.
    raw: []const []const u8,
};

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("linux-session : " ++ fmt ++ "\n", args);
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const env = init.environ_map;

    var log_root: []const u8 = undefined;
    if (env.get("XDG_CACHE_HOME")) |c| log_root = try std.fs.path.join(a, &.{ c, "neo-compute/linux-session" }) else if (env.get("HOME")) |h| log_root = try std.fs.path.join(a, &.{ h, ".cache/neo-compute/linux-session" }) else log_root = "/tmp/neo-compute-linux-session";
    var opts: Opts = .{ .session = .{ .log_root = log_root }, .raw = &.{} };
    var i: usize = 1;
    while (i < args.len and std.mem.startsWith(u8, args[i], "--")) : (i += 2) {
        const flag = args[i];
        if (i + 1 >= args.len) return fail("{s} attend une valeur\n{s}", .{ flag, usage });
        const v = args[i + 1];
        if (std.mem.eql(u8, flag, "--server")) {
            opts.server = v;
        } else if (std.mem.eql(u8, flag, "--log-dir")) {
            opts.session.log_root = v;
        } else if (std.mem.eql(u8, flag, "--runtime-parent")) {
            opts.session.runtime_parent = v;
        } else if (std.mem.eql(u8, flag, "--start-timeout-ms")) {
            opts.session.start_timeout_ms = std.fmt.parseInt(u32, v, 10) catch return fail("--start-timeout-ms attend un nombre", .{});
        } else if (std.mem.eql(u8, flag, "--test-compositor")) {
            var parts: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, v, ' ');
            while (it.next()) |p| try parts.append(a, p);
            if (parts.items.len == 0) return fail("--test-compositor attend une commande", .{});
            opts.session.test_compositor = parts.items;
        } else return fail("option inconnue {s}\n{s}", .{ flag, usage });
    }
    // Options are relative to the caller's folder; the session runs
    // elsewhere.
    opts.session.log_root = try absolute(a, init.io, opts.session.log_root);
    if (opts.server) |s| opts.server = try absolute(a, init.io, s);
    opts.raw = try rawOptions(a, opts);
    const rest = args[i..];
    if (rest.len == 0) return fail("{s}", .{usage});

    installSignals();
    const verb = rest[0];
    if (std.mem.eql(u8, verb, "start")) {
        if (rest.len != 2) return fail("{s}", .{usage});
        const family = parseFamily(rest[1]) orelse return fail("famille inconnue {s}\n{s}", .{ rest[1], usage });
        return startDetached(a, init.io, family, opts);
    }
    if (std.mem.eql(u8, verb, "serve-kept")) {
        // The detached launcher of `start`, started by itself.
        const family = parseFamily(rest[1]).?;
        return serveKept(a, init.io, env, family, opts);
    }
    if (std.mem.eql(u8, verb, "exec")) {
        if (rest.len < 4 or !std.mem.eql(u8, rest[2], "--")) return fail("{s}", .{usage});
        return execClient(a, init.io, opts, rest[1], rest[3..]);
    }
    if (std.mem.eql(u8, verb, "stop")) {
        if (rest.len != 2) return fail("{s}", .{usage});
        return stopClient(a, opts, rest[1]);
    }
    if (std.mem.eql(u8, verb, "cycles")) {
        if (rest.len != 3) return fail("{s}", .{usage});
        const family = parseFamily(rest[1]) orelse return fail("famille inconnue {s}", .{rest[1]});
        const n = std.fmt.parseInt(u32, rest[2], 10) catch return fail("cycles attend un nombre", .{});
        return cycles(a, init.io, family, opts, n);
    }
    const family = parseFamily(verb) orelse return fail("famille ou commande inconnue {s}\n{s}", .{ verb, usage });
    var argv: std.ArrayList([]const u8) = .empty;
    if (rest.len >= 2 and std.mem.eql(u8, rest[1], "exec")) {
        if (rest.len < 4 or !std.mem.eql(u8, rest[2], "--")) return fail("{s}", .{usage});
        for (rest[3..]) |x| try argv.append(a, x);
    } else {
        const server = opts.server orelse return fail("--server <neo-compute> est requis pour lancer neo-compute dans la session (zig build session le passe)", .{});
        try argv.append(a, server);
        for (rest[1..]) |x| try argv.append(a, x);
    }
    return oneShot(a, init.io, env, family, opts, argv.items);
}

fn absolute(a: std.mem.Allocator, io: std.Io, p: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, p });
}

fn rawOptions(a: std.mem.Allocator, o: Opts) ![]const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    try l.appendSlice(a, &.{ "--log-dir", o.session.log_root, "--start-timeout-ms", try std.fmt.allocPrint(a, "{d}", .{o.session.start_timeout_ms}) });
    if (o.server) |s| try l.appendSlice(a, &.{ "--server", s });
    if (o.session.runtime_parent) |r| try l.appendSlice(a, &.{ "--runtime-parent", r });
    if (o.session.test_compositor) |c| try l.appendSlice(a, &.{ "--test-compositor", try std.mem.join(a, " ", c) });
    return l.items;
}

fn parseFamily(s: []const u8) ?Family {
    return std.meta.stringToEnum(Family, s);
}

fn printDifferences(s: *const Session) void {
    for (s.notes.items) |n| std.debug.print("linux-session : note du témoin : {s}\n", .{n});
    if (s.differences.items.len == 0) return;
    std.debug.print("linux-session : le témoin a relevé {d} différence(s) de la session réelle :\n", .{s.differences.items.len});
    for (s.differences.items) |d| std.debug.print("  - {s}\n", .{d});
}

/// Starts a session, runs `argv` in it with the launcher's own standard
/// streams, stops the session, and returns the command's code (3 on a
/// difference).
fn oneShot(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, family: Family, opts: Opts, argv: []const []const u8) !u8 {
    var s = switch (try Session.init(a, io, family, opts.session, env, &aborting)) {
        .ok => |s| s,
        .failed => |f| {
            std.debug.print("linux-session : {s}\n", .{f.message});
            return f.code;
        },
    };
    if (try s.start()) |f| {
        std.debug.print("linux-session : {s}\n", .{f.message});
        printDifferences(&s);
        return if (s.differences.items.len > 0) 3 else f.code;
    }
    const pid = s.spawnCommand(argv, null, .inherit, .inherit, .inherit) catch |err| {
        s.stop();
        printDifferences(&s);
        std.debug.print("linux-session : {s} n'a pas pu démarrer ({t})\n", .{ argv[0], err });
        return if (s.differences.items.len > 0) 3 else 127;
    };
    const code = while (true) {
        const sig = takeSignal();
        if (sig != 0) _ = linux.kill(pid, @fromBackingInt(@intCast(sig)));
        s.tick();
        if (s.reaper.take(pid)) |st| break proc.exitCode(st);
        var pfd = [_]linux.pollfd{.{ .fd = signal_pipe[0], .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&pfd, 1, 50);
    };
    s.stop();
    printDifferences(&s);
    return if (s.differences.items.len > 0) 3 else code;
}

/// `start <famille>`: starts a detached launcher that keeps the session,
/// waits until it is ready and prints its id.
fn startDetached(a: std.mem.Allocator, io: std.Io, family: Family, opts: Opts) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, try std.process.executablePathAlloc(io, a));
    try argv.appendSlice(a, opts.raw);
    try argv.appendSlice(a, &.{ "serve-kept", @tagName(family) });
    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .pipe, .stderr = .inherit });
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &buf);
    const line = (r.interface.takeDelimiter('\n') catch null) orelse {
        std.debug.print("linux-session : le lanceur détaché s'est arrêté sans répondre\n", .{});
        return 2;
    };
    if (std.mem.startsWith(u8, line, "ready ")) {
        var out = std.Io.File.stdout().writerStreaming(io, &.{});
        try out.interface.print("{s}\n", .{line["ready ".len..]});
        return 0;
    }
    // "fail <code> <message>"
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next();
    const code = std.fmt.parseInt(u8, it.next() orelse "2", 10) catch 2;
    std.debug.print("linux-session : {s}\n", .{it.rest()});
    return code;
}

const Client = struct {
    fd: i32,
    pid: i32 = 0,
};

/// The detached launcher: keeps the session until `stop <id>` or a stop
/// signal, starting each `exec` on the descriptors its client sent.
fn serveKept(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, family: Family, opts: Opts) !u8 {
    _ = linux.setsid();
    const stdout = std.Io.File.stdout();
    var w = stdout.writerStreaming(io, &.{});
    var s = switch (try Session.init(a, io, family, opts.session, env, &aborting)) {
        .ok => |s| s,
        .failed => |f| {
            try w.interface.print("fail {d} {s}\n", .{ f.code, f.message });
            return f.code;
        },
    };
    if (try s.start()) |f| {
        const code: u8 = if (s.differences.items.len > 0) 3 else f.code;
        try w.interface.print("fail {d} {s}{s}\n", .{ code, f.message, if (code == 3) " ; le témoin a relevé une différence" else "" });
        return code;
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const listen_fd = try control.listen(try control.socketPath(&path_buf, s.rt));
    try w.interface.print("ready {s}\n", .{s.id});
    // From now on the launcher talks only through its socket and log.
    const log = try std.Io.Dir.cwd().createFile(io, try std.fmt.allocPrint(a, "{s}/launcher.log", .{s.log_dir}), .{ .truncate = false });
    _ = linux.dup2(log.handle, 1);
    _ = linux.dup2(log.handle, 2);

    var clients: std.ArrayList(Client) = .empty;
    var buf: [control.max_packet]u8 = undefined;
    var stop_requested: ?i32 = null;
    // Reused on every turn: a kept session may run for hours.
    var pfds: std.ArrayList(linux.pollfd) = .empty;
    var num_buf: [16]u8 = undefined;
    while (stop_requested == null) {
        pfds.clearRetainingCapacity();
        try pfds.append(a, .{ .fd = signal_pipe[0], .events = linux.POLL.IN, .revents = 0 });
        try pfds.append(a, .{ .fd = listen_fd, .events = linux.POLL.IN, .revents = 0 });
        for (clients.items) |c| try pfds.append(a, .{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 });
        _ = linux.poll(pfds.items.ptr, pfds.items.len, 100);
        if (takeSignal() != 0) break;
        if (pfds.items[1].revents & linux.POLL.IN != 0) if (control.accept(listen_fd)) |fd| try clients.append(a, .{ .fd = fd });
        var ci: usize = 0;
        while (ci < clients.items.len) {
            const c = &clients.items[ci];
            const re = if (ci + 2 < pfds.items.len) pfds.items[ci + 2].revents else 0;
            var closed = false;
            if (re & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
                const packet = control.recv(c.fd, &buf) catch null;
                if (packet) |p| switch (p.kind) {
                    'x' => c.pid = startExec(&s, p) catch |err| blk: {
                        control.send(c.fd, 'f', std.fmt.allocPrint(a, "la commande n'a pas pu démarrer ({t})", .{err}) catch "", null) catch {};
                        control.send(c.fd, 'e', "127", null) catch {};
                        closed = true;
                        break :blk 0;
                    },
                    's' => if (c.pid > 0) {
                        const sig = std.fmt.parseInt(u32, p.payload, 10) catch 15;
                        _ = linux.kill(c.pid, @fromBackingInt(@intCast(sig)));
                    },
                    'q' => stop_requested = c.fd,
                    else => {},
                } else {
                    // The client is gone: so is its command.
                    if (c.pid > 0) _ = linux.kill(c.pid, .KILL);
                    closed = true;
                }
                if (packet) |p| if (p.kind == 'x' and c.pid > 0) {
                    control.send(c.fd, 'p', std.fmt.bufPrint(&num_buf, "{d}", .{c.pid}) catch "", null) catch {};
                };
            }
            if (closed) {
                if (stop_requested != c.fd) _ = linux.close(c.fd);
                _ = clients.swapRemove(ci);
                continue;
            }
            ci += 1;
        }
        s.tick();
        for (clients.items) |*c| if (c.pid > 0) if (s.reaper.take(c.pid)) |st| {
            control.send(c.fd, 'e', std.fmt.bufPrint(&num_buf, "{d}", .{proc.exitCode(st)}) catch "1", null) catch {};
            c.pid = 0;
        };
    }
    s.stop();
    const code: u8 = if (s.differences.items.len > 0) 3 else 0;
    printDifferences(&s);
    for (clients.items) |c| {
        if (c.fd == stop_requested) {
            if (s.differences.items.len > 0) {
                control.send(c.fd, 'r', std.fmt.allocPrint(a, "le témoin a relevé {d} différence(s) de la session réelle :", .{s.differences.items.len}) catch "", null) catch {};
                for (s.differences.items) |d| control.send(c.fd, 'r', std.fmt.allocPrint(a, "  - {s}", .{d}) catch "", null) catch {};
            }
            control.send(c.fd, 'e', if (code == 3) "3" else "0", null) catch {};
        } else {
            control.send(c.fd, 'f', "la session s'est arrêtée", null) catch {};
            control.send(c.fd, 'e', "2", null) catch {};
        }
        _ = linux.close(c.fd);
    }
    return code;
}

fn startExec(s: *Session, p: control.Packet) !i32 {
    defer for (p.fds) |fd| if (fd >= 0) {
        _ = linux.close(fd);
    };
    if (p.fds[0] < 0) return error.NoDescriptors;
    var parts = std.mem.splitScalar(u8, p.payload, 0);
    const cwd = parts.next() orelse return error.BadPacket;
    var argv: std.ArrayList([]const u8) = .empty;
    while (parts.next()) |x| try argv.append(s.a, try s.a.dupe(u8, x));
    if (argv.items.len == 0) return error.BadPacket;
    const f = struct {
        fn file(fd: i32) proc.Stdio {
            return .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } };
        }
    };
    return s.spawnCommand(argv.items, if (cwd.len > 0) cwd else null, f.file(p.fds[0]), f.file(p.fds[1]), f.file(p.fds[2]));
}

fn controlPath(a: std.mem.Allocator, opts: Opts, id: []const u8) ![:0]const u8 {
    if (id.len != 6) return error.BadId;
    const parent = opts.session.runtime_parent orelse try std.fmt.allocPrint(a, "/run/user/{d}", .{linux.getuid()});
    return std.fmt.allocPrintSentinel(a, "{s}/nc-{s}/nc/control", .{ parent, id }, 0);
}

fn execClient(a: std.mem.Allocator, io: std.Io, opts: Opts, id: []const u8, argv: []const []const u8) !u8 {
    const p = controlPath(a, opts, id) catch return fail("identifiant de session invalide : {s}", .{id});
    const fd = control.connect(p) catch return fail("aucune session {s} : lance d'abord linux-session start <famille>", .{id});
    var payload: std.ArrayList(u8) = .empty;
    try payload.appendSlice(a, try std.process.currentPathAlloc(io, a));
    for (argv) |x| {
        try payload.append(a, 0);
        try payload.appendSlice(a, x);
    }
    try control.send(fd, 'x', payload.items, .{ 0, 1, 2 });
    var buf: [control.max_packet]u8 = undefined;
    while (true) {
        var pfds = [_]linux.pollfd{
            .{ .fd = signal_pipe[0], .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = linux.poll(&pfds, 2, -1);
        const sig = takeSignal();
        if (sig != 0) control.send(fd, 's', try std.fmt.allocPrint(a, "{d}", .{sig}), null) catch {};
        if (pfds[1].revents == 0) continue;
        const packet = (control.recv(fd, &buf) catch null) orelse return fail("la session {s} a fermé la connexion", .{id});
        switch (packet.kind) {
            'e' => return std.fmt.parseInt(u8, packet.payload, 10) catch 1,
            'f' => std.debug.print("linux-session : {s}\n", .{packet.payload}),
            else => {},
        }
    }
}

fn stopClient(a: std.mem.Allocator, opts: Opts, id: []const u8) !u8 {
    const p = controlPath(a, opts, id) catch return fail("identifiant de session invalide : {s}", .{id});
    const fd = control.connect(p) catch return fail("aucune session {s}", .{id});
    try control.send(fd, 'q', "", null);
    var buf: [control.max_packet]u8 = undefined;
    while (true) {
        const packet = (control.recv(fd, &buf) catch null) orelse return fail("la session {s} a fermé la connexion sans rapport", .{id});
        switch (packet.kind) {
            'e' => return std.fmt.parseInt(u8, packet.payload, 10) catch 1,
            'r', 'f' => std.debug.print("linux-session : {s}\n", .{packet.payload}),
            else => {},
        }
    }
}

/// `cycles <famille> <n>`: n sessions in a row, each `<famille> exec --
/// true` in a launcher of its own; code 0 only when every one exits with
/// 0 and the witness relieves nothing.
fn cycles(a: std.mem.Allocator, io: std.Io, family: Family, opts: Opts, n: u32) !u8 {
    const self = try std.process.executablePathAlloc(io, a);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, self);
    try argv.appendSlice(a, opts.raw);
    try argv.appendSlice(a, &.{ @tagName(family), "exec", "--", "true" });
    var failures: u32 = 0;
    for (0..n) |k| {
        const t0 = std.Io.Clock.awake.now(io).toNanoseconds();
        var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore });
        const term = try child.wait(io);
        const ms = @divTrunc(std.Io.Clock.awake.now(io).toNanoseconds() - t0, std.time.ns_per_ms);
        const code: u8 = switch (term) {
            .exited => |c| c,
            else => 1,
        };
        if (code != 0) failures += 1;
        std.debug.print("cycle {d}/{d} {s} : code {d}, {d} ms\n", .{ k + 1, n, @tagName(family), code, ms });
        if (aborting.load(.acquire)) break;
    }
    std.debug.print("{s} : {d} cycle(s) sur {d} en échec\n", .{ @tagName(family), failures, n });
    return if (failures == 0) 0 else 1;
}

test {
    _ = proc;
    _ = control;
    _ = @import("witness.zig");
}
