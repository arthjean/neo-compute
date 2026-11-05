//! Per-application control levels (US-017, FR-08): `deny`, `observe`,
//! `click`, `full`, read from `%APPDATA%\neo-compute\policy.json` or the
//! `--policy` file, over the versioned defaults below. Every action resolves
//! its target application (window under the point, foreground window or
//! element owner) and checks its level before the first event is sent.

const std = @import("std");
const display = @import("display.zig");
const Result = @import("mcp.zig").Result;
const fmt = @import("session.zig").fmt;

/// Ordered: each level allows everything the previous ones allow.
/// `observe`: screenshots and accessibility reads; `click`: plus left-button
/// mouse actions, scrolling, focus and element actions other than
/// set_value; `full`: plus keyboard input, set_value, right and middle
/// clicks (a right or middle click pastes in most terminals).
pub const Level = enum {
    deny,
    observe,
    click,
    full,

    pub fn allows(have: Level, need: Level) bool {
        return @backingInt(have) >= @backingInt(need);
    }
};

pub const Rule = struct { exe: []const u8, level: Level };

/// Password managers: hidden and untouchable unless the policy file says
/// otherwise. Executable names, compared without case.
pub const password_managers = [_][]const u8{
    "1Password.exe", "Bitwarden.exe", "KeePass.exe",  "KeePassXC.exe",  "Dashlane.exe",
    "Enpass.exe",    "NordPass.exe",  "RoboForm.exe", "ProtonPass.exe", "Proton Pass.exe",
    "LastPass.exe",  "Keeper.exe",
};

/// Terminals and IDEs: typing there is shell access outside Claude Code's
/// permissions, so only clicks are allowed by default. A console window
/// reports the process of its shell, hence the shells.
pub const shells = [_][]const u8{
    "WindowsTerminal.exe", "OpenConsole.exe",    "conhost.exe",         "cmd.exe",    "powershell.exe",
    "pwsh.exe",            "wsl.exe",            "bash.exe",            "mintty.exe", "alacritty.exe",
    "wezterm-gui.exe",     "Code.exe",           "Code - Insiders.exe", "Cursor.exe", "Windsurf.exe",
    "Zed.exe",             "powershell_ise.exe",
};

pub const default_rules = blk: {
    var out: [password_managers.len + shells.len]Rule = undefined;
    for (password_managers, 0..) |exe, i| out[i] = .{ .exe = exe, .level = .deny };
    for (shells, 0..) |exe, i| out[password_managers.len + i] = .{ .exe = exe, .level = .click };
    break :blk out;
};

pub const Policy = struct {
    /// Level of an application no rule names.
    default: Level = .full,
    /// Rules of the policy file, checked before `default_rules`.
    rules: []const Rule = &.{},
    /// Every level is capped at this: `observe` when the file is invalid.
    cap: Level = .full,
    /// Why the policy file was rejected (US English, for the instructions).
    problem: ?[]const u8 = null,

    pub fn levelOf(self: *const Policy, exe: ?[]const u8) Level {
        const level = blk: {
            const e = exe orelse break :blk self.default;
            for (self.rules) |r| if (std.ascii.eqlIgnoreCase(r.exe, e)) break :blk r.level;
            for (default_rules) |r| if (std.ascii.eqlIgnoreCase(r.exe, e)) break :blk r.level;
            break :blk self.default;
        };
        return if (level.allows(self.cap)) self.cap else level;
    }
};

pub const defaults: Policy = .{};

/// Policy of `path`. A missing file at the default location means the
/// defaults; a missing `--policy` file (`explicit`), an unreadable or
/// invalid one, starts in global `observe` with the reason.
pub fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8, explicit: bool) Policy {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
        if (err == error.FileNotFound and !explicit) return defaults;
        return invalid(fmt(arena, "Policy file {s} cannot be read ({t})", .{ path, err }));
    };
    return parse(arena, source, path);
}

fn invalid(problem: []const u8) Policy {
    return .{ .default = .observe, .cap = .observe, .problem = problem };
}

/// Parses `{"default": "<level>", "apps": {"<exe>": "<level>", ...}}`. Any
/// error names its line and quotes it.
pub fn parse(arena: std.mem.Allocator, source: []const u8, path: []const u8) Policy {
    var diag: std.json.Diagnostics = .{};
    var scanner: std.json.Scanner = .initCompleteInput(arena, source);
    scanner.enableDiagnostics(&diag);
    var p: Policy = .{};
    var rules: std.ArrayList(Rule) = .empty;
    const why = walk(arena, &scanner, &p, &rules) catch |err| switch (err) {
        error.OutOfMemory => "out of memory",
        else => "invalid JSON",
    };
    if (why) |reason| {
        const line = diag.getLine();
        return invalid(fmt(arena, "Policy file {s} is invalid at line {d} (`{s}`): {s}", .{ path, line, lineText(source, line), reason }));
    }
    p.rules = rules.items;
    return p;
}

/// Reads the document into `p` and `rules`; returns the reason it is
/// rejected, at the scanner's current line.
fn walk(arena: std.mem.Allocator, s: *std.json.Scanner, p: *Policy, rules: *std.ArrayList(Rule)) !?[]const u8 {
    if (try s.next() != .object_begin) return "expected an object {\"default\": ..., \"apps\": {...}}";
    while (true) {
        const key = switch (try s.nextAlloc(arena, .alloc_if_needed)) {
            .object_end => break,
            .string, .allocated_string => |k| k,
            else => unreachable,
        };
        if (std.mem.eql(u8, key, "default")) {
            p.default = switch (try levelValue(arena, s)) {
                .ok => |l| l,
                .bad => |why| return why,
            };
        } else if (std.mem.eql(u8, key, "apps")) {
            if (try s.next() != .object_begin) return "`apps` must be an object of executable names to levels";
            while (true) {
                const exe = switch (try s.nextAlloc(arena, .alloc_always)) {
                    .object_end => break,
                    .allocated_string => |k| k,
                    else => unreachable,
                };
                const level = switch (try levelValue(arena, s)) {
                    .ok => |l| l,
                    .bad => |why| return why,
                };
                try rules.append(arena, .{ .exe = exe, .level = level });
            }
        } else return fmt(arena, "unknown key `{s}` (valid keys: default, apps)", .{key});
    }
    if (try s.next() != .end_of_document) return "unexpected content after the object";
    return null;
}

fn levelValue(arena: std.mem.Allocator, s: *std.json.Scanner) !union(enum) { ok: Level, bad: []const u8 } {
    const text = switch (try s.nextAlloc(arena, .alloc_if_needed)) {
        .string, .allocated_string => |t| t,
        else => return .{ .bad = "a level must be a string: deny, observe, click or full" },
    };
    if (std.meta.stringToEnum(Level, text)) |l| return .{ .ok = l };
    return .{ .bad = fmt(arena, "unknown level `{s}` (deny, observe, click or full)", .{text}) };
}

/// Line `n` (1-based) of `source`, trimmed and cut to 80 bytes.
fn lineText(source: []const u8, n: u64) []const u8 {
    var it = std.mem.splitScalar(u8, source, '\n');
    var i: u64 = 1;
    while (it.next()) |line| : (i += 1) if (i == n) {
        const t = std.mem.trim(u8, line, " \t\r");
        return t[0..@min(t.len, 80)];
    };
    return "";
}

// ---------------------------------------------------------------- resolution

/// The application an action reaches, as recorded in the audit log.
pub const Target = struct {
    handle: u64,
    pid: u32,
    level: Level,
    exe_buf: [64]u8 = undefined,
    exe_len: u8 = 0,

    pub fn exe(self: *const Target) []const u8 {
        return self.exe_buf[0..self.exe_len];
    }
};

/// Level per (pid, window): the executable name is read once per window,
/// so a cached resolution costs two Win32 calls (US-017: < 0.2 ms). The
/// window handle in the key keeps a reused pid from inheriting a level.
pub const Cache = struct {
    entries: [64]Target = undefined,
    len: usize = 0,
    next: usize = 0,

    fn get(self: *Cache, ref: display.WindowRef) ?*const Target {
        for (self.entries[0..self.len]) |*t| if (t.pid == ref.pid and t.handle == ref.handle) return t;
        return null;
    }

    fn put(self: *Cache, t: Target) *const Target {
        const i = if (self.len < self.entries.len) self.len else self.next;
        if (self.len < self.entries.len) self.len += 1 else self.next = (self.next + 1) % self.entries.len;
        self.entries[i] = t;
        return &self.entries[i];
    }
};

/// Level and executable of the window `ref`.
pub fn resolve(ctx: anytype, ref: display.WindowRef) *const Target {
    const s = ctx.session;
    if (s.apps.get(ref)) |t| return t;
    const name = ctx.backend.processName(ctx.arena, ref.pid);
    var t: Target = .{ .handle = ref.handle, .pid = ref.pid, .level = s.policy.levelOf(name) };
    const shown = name orelse "?";
    t.exe_len = @intCast(@min(shown.len, t.exe_buf.len));
    @memcpy(t.exe_buf[0..t.exe_len], shown[0..t.exe_len]);
    return s.apps.put(t);
}

/// Refuses the action when the application of `ref` (null: none found, the
/// default level applies) is below `need`; records the target for the audit.
pub fn require(ctx: anytype, ref: ?display.WindowRef, need: Level) ?Result {
    ctx.timings.start(ctx.io, .policy);
    defer ctx.timings.stop(ctx.io, .policy);
    const r = ref orelse {
        const level = ctx.session.policy.levelOf(null);
        if (level.allows(need)) return null;
        ctx.denied = true;
        return Result.err(fmt(ctx.arena, "Politique : aucune application cible, niveau par défaut {t} : action refusée. Demande à Arthur de changer policy.json.", .{level}));
    };
    const t = resolve(ctx, r);
    ctx.target = t.*;
    if (t.level.allows(need)) return null;
    ctx.denied = true;
    return Result.err(fmt(ctx.arena, "Politique : {s} est en mode {t} : action refusée. Demande à Arthur de changer son niveau dans policy.json.", .{ t.exe(), t.level }));
}

/// The refusal of a `deny` window, without recording anything (an
/// observation that follows an action).
pub fn hidden(ctx: anytype, ref: display.WindowRef) ?[]const u8 {
    const t = resolve(ctx, ref);
    if (t.level != .deny) return null;
    return fmt(ctx.arena, "Politique : {s} est en mode deny.", .{t.exe()});
}

/// `require` for the window under physical point `p` (null: the foreground
/// window, which receives the keyboard).
pub fn requireAt(ctx: anytype, p: ?[2]i32, need: Level) ?Result {
    return require(ctx, ctx.backend.windowAt(p), need);
}

/// `require` for top-level window `handle` (a closed window passes: the
/// action reports it).
pub fn requireWindow(ctx: anytype, handle: u64, need: Level) ?Result {
    const ref = ctx.backend.windowRef(handle) orelse return null;
    return require(ctx, ref, need);
}

/// Physical rectangles of `deny` windows visible on `area`: each window's
/// rectangle minus the opaque windows above it, so a password manager behind
/// a maximized window costs no pixel of it. Layered windows may be
/// transparent and never uncover anything.
pub fn deniedRects(ctx: anytype, area: display.Rect) []const display.Rect {
    ctx.timings.start(ctx.io, .policy);
    defer ctx.timings.stop(ctx.io, .policy);
    const wins = ctx.backend.visibleWindows(ctx.arena) catch return &.{};
    var out: std.ArrayList(display.Rect) = .empty;
    for (wins, 0..) |win, z| {
        if (!win.rect.intersects(area)) continue;
        if (resolve(ctx, .{ .handle = win.handle, .pid = win.pid }).level != .deny) continue;
        var pieces: std.ArrayList(display.Rect) = .empty;
        pieces.append(ctx.arena, display.intersection(win.rect, area).?) catch return out.items;
        for (wins[0..z]) |above| {
            if (!above.solid or pieces.items.len == 0) continue;
            display.subtract(ctx.arena, &pieces, above.rect) catch {
                // Too fragmented: hide the whole window.
                pieces.clearRetainingCapacity();
                pieces.append(ctx.arena, display.intersection(win.rect, area).?) catch {};
                break;
            };
        }
        out.appendSlice(ctx.arena, pieces.items) catch return out.items;
    }
    return out.items;
}

test "levels: user rules first, then the versioned defaults, capped when invalid" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Level.deny, defaults.levelOf("keepassxc.EXE"));
    try std.testing.expectEqual(Level.click, defaults.levelOf("WindowsTerminal.exe"));
    try std.testing.expectEqual(Level.full, defaults.levelOf("notepad.exe"));
    try std.testing.expectEqual(Level.full, defaults.levelOf(null));

    const p = parse(a,
        \\{
        \\  "default": "click",
        \\  "apps": { "Code.exe": "full", "notepad.exe": "observe", "KeePassXC.exe": "observe" }
        \\}
    , "policy.json");
    try std.testing.expectEqual(@as(?[]const u8, null), p.problem);
    try std.testing.expectEqual(Level.full, p.levelOf("code.exe"));
    try std.testing.expectEqual(Level.observe, p.levelOf("notepad.exe"));
    try std.testing.expectEqual(Level.observe, p.levelOf("KeePassXC.exe"));
    try std.testing.expectEqual(Level.deny, p.levelOf("1Password.exe"));
    try std.testing.expectEqual(Level.click, p.levelOf("mspaint.exe"));
}

test "an invalid policy file starts in global observe and names its line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad_level = parse(a, "{\n  \"apps\": {\n    \"Code.exe\": \"wirte\"\n  }\n}\n", "C:\\p.json");
    try std.testing.expectEqualStrings("Policy file C:\\p.json is invalid at line 3 (`\"Code.exe\": \"wirte\"`): unknown level `wirte` (deny, observe, click or full)", bad_level.problem.?);
    try std.testing.expectEqual(Level.observe, bad_level.levelOf("notepad.exe"));
    try std.testing.expectEqual(Level.observe, bad_level.levelOf("WindowsTerminal.exe"));
    try std.testing.expectEqual(Level.deny, bad_level.levelOf("KeePass.exe"));

    const syntax = parse(a, "{\n  \"default\": \"full\",\n  \"apps\": {\"a.exe\": \"full\",}\n}", "p.json");
    try std.testing.expect(std.mem.indexOf(u8, syntax.problem.?, "at line 3") != null);
    const key = parse(a, "{\"defaults\": \"full\"}", "p.json");
    try std.testing.expect(std.mem.indexOf(u8, key.problem.?, "unknown key `defaults`") != null);
    const not_string = parse(a, "{\"default\": 3}", "p.json");
    try std.testing.expect(std.mem.indexOf(u8, not_string.problem.?, "must be a string") != null);
}
