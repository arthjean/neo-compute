//! app_launch (US-029, FR-25): starts a Start menu application by name or
//! AUMID, or opens a document or folder with its default application, then
//! finds the window it opened. Executables, scripts, shortcuts, URIs and
//! network paths are refused before any shell call, with no argument ever
//! passed on.

const std = @import("std");
const apps = @import("apps.zig");
const policy = @import("policy.zig");
const timing = @import("timing.zig");
const display = @import("display.zig");
const a11y = @import("a11y.zig");
const Result = @import("mcp.zig").Result;
const fmt = @import("session.zig").fmt;

/// Refused besides PATHEXT, versioned with the PRD (list 2, decision 0010):
/// shortcuts, scripts, installers, control panel items, screen savers,
/// registry files and ClickOnce applications (list 1); compiled help,
/// themes, troubleshooters, app packages, shell search and settings files,
/// the scripts of interpreters that register their own extension, pinned
/// sites, Office add-ins, browser applications and remote desktop
/// connections (list 2).
pub const denied_extensions = [_][]const u8{
    // List 1.
    ".lnk",       ".url",           ".scf",          ".ps1",        ".psm1",        ".vbs",                ".vbe",
    ".js",        ".jse",           ".wsf",          ".wsh",        ".hta",         ".msi",                ".msp",
    ".appref-ms", ".cpl",           ".scr",          ".reg",        ".application",
    // List 2.
    ".chm",                ".theme",
    ".themepack", ".deskthemepack", ".diagcab",      ".diagpkg",    ".diagcfg",     ".msix",               ".msixbundle",
    ".appx",      ".appxbundle",    ".appinstaller", ".library-ms", ".search-ms",   ".searchconnector-ms", ".settingcontent-ms",
    ".py",        ".pyw",           ".pyz",          ".pyzw",       ".sh",          ".bash",               ".jar",
    ".ahk",       ".au3",           ".website",      ".xll",        ".vsto",        ".xbap",               ".rdp",
};

/// Windows' default PATHEXT, refused even when the environment's is
/// shorter.
pub const default_pathext = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC";

const poll_ms = 100;
/// A pid's own window first; after this, any new top-level window counts
/// (a launcher whose process lives on).
const pid_only_ms = 3000;
/// An existing window of the expected application counts once no new
/// window showed up for this long (an application that reuses its window,
/// such as a document opened in a tab).
const existing_after_ms = 1500;

const oom = "Mémoire insuffisante : réessaie.";

fn deniedMessage(arena: std.mem.Allocator, what: []const u8) []const u8 {
    return fmt(arena, "app_launch n'ouvre que des documents et des dossiers : {s} refusé", .{what});
}

/// Extension of the last path component (`.txt`), lowercase, after the
/// trailing dots and spaces Windows ignores; empty when there is none.
pub fn extension(arena: std.mem.Allocator, path: []const u8) []const u8 {
    // `evil.ps1\` names the file `evil.ps1` for some APIs.
    const trimmed = std.mem.trimEnd(u8, path, "\\/");
    const base = trimmed[if (std.mem.lastIndexOfAny(u8, trimmed, "\\/")) |i| i + 1 else 0..];
    const name = std.mem.trimEnd(u8, base, ". ");
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return std.ascii.allocLowerString(arena, name[dot..]) catch name[dot..];
}

fn inList(list: []const u8, ext: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ';');
    while (it.next()) |e| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, e, " "), ext)) return true;
    return false;
}

/// Why `path` is refused before any file system or shell call, or null:
/// a network path, a URI (`scheme:`, any colon but a drive's), an
/// extension of PATHEXT (`pathext`, plus Windows' default) or of the
/// versioned list.
pub fn refusal(arena: std.mem.Allocator, path: []const u8, pathext: []const u8) ?[]const u8 {
    const p = std.mem.trim(u8, path, " \t\"");
    if (std.mem.startsWith(u8, p, "\\\\") or std.mem.startsWith(u8, p, "//"))
        return "app_launch n'ouvre que des documents et des dossiers locaux : chemin réseau refusé";
    if (std.mem.indexOfScalar(u8, p, ':')) |i| {
        const drive = i == 1 and std.ascii.isAlphabetic(p[0]) and std.mem.indexOfScalarPos(u8, p, 2, ':') == null;
        if (!drive) {
            // `C:\a\b.txt:x` names an NTFS stream, `scheme:` a URI.
            const colon = if (i == 1 and std.ascii.isAlphabetic(p[0])) std.mem.indexOfScalarPos(u8, p, 2, ':').? else i;
            if (std.mem.indexOfAny(u8, p[0..colon], "\\/") != null) return deniedMessage(arena, "flux NTFS");
            return deniedMessage(arena, p[0 .. colon + 1]);
        }
    }
    const ext = extension(arena, p);
    if (ext.len == 0) return null;
    for (denied_extensions) |d| if (std.mem.eql(u8, d, ext)) return deniedMessage(arena, ext);
    if (inList(pathext, ext) or inList(default_pathext, ext)) return deniedMessage(arena, ext);
    // A folder named `x.{CLSID}` is a shell junction that runs a handler.
    if (ext.len > 1 and ext[1] == '{') return deniedMessage(arena, ext);
    return null;
}

const Lookup = union(enum) { ok: apps.App, err: []const u8 };

fn enumerate(ctx: anytype) ?[]const u8 {
    const listed = switch (ctx.backend.appCatalog(ctx.arena, ctx.cancel)) {
        .ok => |l| l,
        .err => |e| return e,
    };
    ctx.session.catalog.replace(ctx.session.gpa, listed, timing.now(ctx.io)) catch return oom;
    return null;
}

/// The application `name` designates in the session's catalog, enumerated
/// on first use and again after a miss, at most once a minute (US-028).
pub fn lookup(ctx: anytype, name: []const u8) Lookup {
    ctx.timings.start(ctx.io, .catalog);
    defer ctx.timings.stop(ctx.io, .catalog);
    const cat = &ctx.session.catalog;
    if (!cat.loaded) if (enumerate(ctx)) |e| return .{ .err = e };
    var m = apps.match(ctx.arena, cat.apps, name) catch return .{ .err = oom };
    if (m == .none and cat.mayRefresh(timing.now(ctx.io))) {
        if (enumerate(ctx)) |e| return .{ .err = e };
        m = apps.match(ctx.arena, cat.apps, name) catch return .{ .err = oom };
    }
    return switch (m) {
        .found => |app| .{ .ok = app },
        .ambiguous => |names| .{ .err = fmt(ctx.arena, "Plusieurs applications correspondent à « {s} » : {s} ; précise le nom", .{ name, std.mem.join(ctx.arena, ", ", names) catch return .{ .err = oom } }) },
        .none => .{ .err = fmt(ctx.arena, "Aucune application « {s} » dans le menu Démarrer : vérifie le nom ou passe un AUMID", .{name}) },
    };
}

fn contains(list: []const u64, h: u64) bool {
    return std.mem.indexOfScalar(u64, list, h) != null;
}

fn isFrameHost(exe: []const u8) bool {
    return std.ascii.eqlIgnoreCase(exe, "ApplicationFrameHost.exe");
}

/// The window the launch opened: a window of `pid` (a UWP frame hosting
/// it included), else, once the pid is unknown, gone or silent for 3 s, the
/// first new top-level window; else, after 1.5 s, the foreground window
/// when it belongs to `exe` (an instance that reused its window). Null on
/// timeout or cancellation.
fn waitWindow(ctx: anytype, pid: ?u32, before: []const u64, exe: ?[]const u8) ?display.WindowInfo {
    const start = timing.now(ctx.io);
    while (true) {
        const elapsed: u64 = @intCast(@divTrunc(timing.now(ctx.io) - start, std.time.ns_per_ms));
        const wins = ctx.backend.listWindows(ctx.arena, false) catch &.{};
        if (pid) |p| for (wins) |win| {
            if (win.pid == p) return win;
            if (isFrameHost(win.exe) and ctx.backend.appPid(win.handle) == p) return win;
        };
        if (pid == null or elapsed >= pid_only_ms or !ctx.backend.processAlive(pid.?)) {
            for (wins) |win| if (!contains(before, win.handle)) return win;
        }
        if (exe) |e| if (elapsed >= existing_after_ms) if (ctx.backend.windowAt(null)) |fg| for (wins) |win| {
            if (win.handle == fg.handle and std.ascii.eqlIgnoreCase(win.exe, e)) return win;
        };
        if (elapsed >= ctx.session.launch_wait_ms) return null;
        if (!ctx.sleep(poll_ms * std.time.ns_per_ms)) return null;
    }
}

fn denyMessage(ctx: anytype, exe: []const u8) []const u8 {
    return fmt(ctx.arena, "Politique : {s} est en mode deny", .{exe});
}

pub fn launch(ctx: anytype, name: ?[]const u8, path: ?[]const u8, observe: ?a11y.Observe, settle_timeout_ms: ?u32) Result {
    if ((name == null) == (path == null)) return Result.err("Passe soit name, soit path");
    if (policy.requireSystem(ctx, "app_launch", .app_launch)) |r| return r;
    var label: []const u8 = undefined;
    var exe: ?[]const u8 = null;
    var started: apps.Launch = undefined;
    var before: []const u64 = &.{};
    if (name) |n| {
        const app = switch (lookup(ctx, n)) {
            .ok => |a| a,
            .err => |e| return Result.err(e),
        };
        ctx.audit_detail.launched = app.aumid;
        label = app.name;
        exe = app.exe orelse if (app.packaged) null else ctx.backend.appExe(ctx.arena, app);
        // A `deny` application known before the launch never starts.
        if (exe) |e| if (ctx.session.policy.levelOf(e) == .deny) {
            ctx.denied = true;
            return Result.err(denyMessage(ctx, e));
        };
        before = snapshotHandles(ctx) orelse return Result.err(oom);
        started = ctx.backend.launchApp(ctx.arena, app, ctx.cancel);
    } else {
        const p = path.?;
        const pathext = ctx.backend.pathExtensions(ctx.arena);
        if (refusal(ctx.arena, p, pathext)) |why| {
            ctx.denied = true;
            const ext = extension(ctx.arena, p);
            ctx.audit_detail.launched = if (ext.len > 0) ext else "refused";
            return Result.err(why);
        }
        const info = ctx.backend.pathInfo(ctx.arena, p);
        const ext = extension(ctx.arena, info.full);
        ctx.audit_detail.launched = if (info.kind == .directory) "folder" else if (ext.len > 0) ext else "file";
        switch (info.kind) {
            .missing => return Result.err(fmt(ctx.arena, "Introuvable : {s}. Vérifie le chemin d'un fichier ou d'un dossier existant.", .{p})),
            .remote => {
                ctx.denied = true;
                return Result.err("app_launch n'ouvre que des documents et des dossiers locaux : chemin réseau refusé");
            },
            .file, .directory => {},
        }
        // The shell opens the long name an 8.3 one stands for
        // (`DEPLOY~1.APP` is a `.appref-ms`), and runs code from a type
        // Windows classes as dangerous or whose command is the file itself
        // (`.pif`): both are checked on the resolved path.
        if (refusal(ctx.arena, info.full, pathext)) |why| {
            ctx.denied = true;
            return Result.err(why);
        }
        if (info.kind == .file and ext.len > 0 and ctx.backend.unsafeType(ext)) {
            ctx.denied = true;
            return Result.err(deniedMessage(ctx.arena, ext));
        }
        exe = if (info.kind == .directory) "explorer.exe" else if (ext.len > 0) ctx.backend.defaultApp(ctx.arena, ext) else null;
        if (exe) |e| if (ctx.session.policy.levelOf(e) == .deny) {
            ctx.denied = true;
            return Result.err(denyMessage(ctx, e));
        };
        label = exe orelse if (ext.len > 0) ext else "le document";
        before = snapshotHandles(ctx) orelse return Result.err(oom);
        started = ctx.backend.openPath(info.full, ctx.cancel);
    }
    const pid = switch (started) {
        .ok => |pid| pid,
        .refused => |hr| return Result.err(fmt(ctx.arena, "Lancement de {s} refusé par Windows (0x{x:0>8}) : vérifie que l'application est installée", .{ label, hr })),
        .cancelled => return Result.err("app_launch annulé"),
        .unavailable => |msg| return Result.err(msg),
    };
    const win = waitWindow(ctx, pid, before, exe) orelse {
        if (ctx.cancelled()) return Result.err("app_launch annulé");
        if (pid) |p| return Result.err(fmt(ctx.arena, "{s} lancée (pid {d}) mais aucune fenêtre après 10 s : rappelle window_list", .{ label, p }));
        return Result.err(fmt(ctx.arena, "{s} lancée (pid inconnu) mais aucune fenêtre après 10 s : rappelle window_list", .{label}));
    };
    // A window of a `deny` application stays hidden (US-017): its own
    // process, or the application a UWP frame hosts.
    const t = policy.resolve(ctx, .{ .handle = win.handle, .pid = win.pid });
    ctx.target = t.*;
    if (t.level == .deny) {
        ctx.denied = true;
        return Result.err(denyMessage(ctx, t.exe()));
    }
    // A UWP frame names the application it hosts, found through the frame
    // even when the launch gave no pid (an existing window activated).
    var app_pid = win.pid;
    var app_exe = win.exe;
    if (isFrameHost(win.exe)) if (ctx.backend.appPid(win.handle)) |p| if (p != win.pid) if (ctx.backend.processName(ctx.arena, p)) |hosted| {
        if (ctx.session.policy.levelOf(hosted) == .deny) {
            ctx.denied = true;
            return Result.err(denyMessage(ctx, hosted));
        }
        app_pid = p;
        app_exe = hosted;
    };
    // The agent types into the foreground window next.
    if (ctx.backend.windowAt(null)) |fg| {
        if (fg.handle != win.handle) _ = ctx.backend.focusWindow(win.handle);
    } else _ = ctx.backend.focusWindow(win.handle);
    var title: std.Io.Writer.Allocating = .init(ctx.arena);
    var chars: usize = 0;
    var it = (std.unicode.Utf8View.init(win.title) catch std.unicode.Utf8View.initUnchecked("?")).iterator();
    while (it.nextCodepointSlice()) |cp| : (chars += 1) {
        if (chars == 80) {
            title.writer.writeAll("…") catch break;
            break;
        }
        title.writer.writeAll(if (cp[0] == '\n' or cp[0] == '\r' or cp[0] == '"') " " else cp) catch break;
    }
    const line = fmt(ctx.arena, "0x{x} \"{s}\" {s} pid={d}", .{ win.handle, title.written(), app_exe, app_pid });
    return a11y.observeWith(ctx, Result.text(line), observe, settle_timeout_ms, win.handle, true);
}

/// Handles of the top-level windows before the launch, cloaked ones
/// included (a suspended window that shows again is not new).
fn snapshotHandles(ctx: anytype) ?[]const u64 {
    const wins = ctx.backend.listWindows(ctx.arena, true) catch return null;
    const out = ctx.arena.alloc(u64, wins.len) catch return null;
    for (wins, out) |win, *h| h.* = win.handle;
    return out;
}

test "extensions of PATHEXT, of the versioned list and URIs are refused before any call" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pathext = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PY";
    for (denied_extensions) |ext| {
        const p = try std.fmt.allocPrint(a, "C:\\Users\\arthur\\fichier{s}", .{ext});
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "app_launch n'ouvre que des documents et des dossiers : {s} refusé", .{ext}), refusal(a, p, "").?);
        // Case, trailing dots and spaces change nothing.
        const upper = try std.fmt.allocPrint(a, "C:\\x\\F{s}. .", .{try std.ascii.allocUpperString(a, ext)});
        try std.testing.expect(refusal(a, upper, "") != null);
    }
    for ([_][]const u8{ ".exe", ".com", ".bat", ".cmd", ".msc", ".js", ".py" }) |ext| {
        const p = try std.fmt.allocPrint(a, "D:\\outils\\script{s}", .{ext});
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "app_launch n'ouvre que des documents et des dossiers : {s} refusé", .{ext}), refusal(a, p, pathext).?);
    }
    // The default PATHEXT applies even when the environment's lacks it.
    try std.testing.expect(refusal(a, "C:\\a\\b.exe", ".TXT") != null);
    try std.testing.expectEqualStrings("app_launch n'ouvre que des documents et des dossiers : ms-settings: refusé", refusal(a, "ms-settings:display", pathext).?);
    try std.testing.expectEqualStrings("app_launch n'ouvre que des documents et des dossiers : https: refusé", refusal(a, "https://example.com", pathext).?);
    try std.testing.expectEqualStrings("app_launch n'ouvre que des documents et des dossiers : flux NTFS refusé", refusal(a, "C:\\a\\notes.txt:flux", pathext).?);
    try std.testing.expectEqualStrings("app_launch n'ouvre que des documents et des dossiers locaux : chemin réseau refusé", refusal(a, "\\\\serveur\\partage\\doc.txt", pathext).?);
    try std.testing.expect(refusal(a, "//serveur/partage/doc.txt", pathext) != null);
    try std.testing.expect(refusal(a, "C:\\Bureau\\dossier.{20D04FE0-3AEA-1069-A2D8-08002B30309D}", pathext) != null);
    // Documents and folders pass.
    for ([_][]const u8{ "C:\\Users\\arthur\\notes.txt", "C:\\Users\\arthur\\rapport.pdf", "C:\\Users\\arthur", "C:\\Users\\arthur\\.config", "notes.md", "C:\\a\\b.ps1.txt", "C:\\a\\sans extension" }) |p| {
        if (refusal(a, p, pathext)) |why| {
            std.debug.print("`{s}` refused: {s}\n", .{ p, why });
            return error.TestUnexpectedResult;
        }
    }
}
