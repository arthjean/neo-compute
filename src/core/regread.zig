//! registry_read (US-036, FR-27): one value, or a key's values then its
//! subkeys, from the 64-bit view. The backend imports no registry write
//! function (tests/process_test.zig checks the binary's imports). A value
//! whose name suggests a secret is shown `<masqué>`; keys known to hold
//! secrets are refused whole, descendants included. The audit records the
//! path and the name, never the data (FR-29).
//!
//! Residual risk: a registry symbolic link created by another program can
//! point an unlisted path at a listed key; the masking by value name still
//! applies there.

const std = @import("std");
const policy = @import("policy.zig");
const Result = @import("mcp.zig").Result;
const fmt = @import("session.zig").fmt;
const max_text_output = @import("tools.zig").max_text_output;

pub const Root = enum {
    hkcu,
    hklm,
    hkcr,
    hku,
    hkcc,

    pub fn label(r: Root) []const u8 {
        return switch (r) {
            .hkcu => "HKCU",
            .hklm => "HKLM",
            .hkcr => "HKCR",
            .hku => "HKU",
            .hkcc => "HKCC",
        };
    }
};

pub const Path = struct {
    root: Root,
    /// Below the root, single backslashes, none leading or trailing; empty
    /// for the root itself.
    sub: []const u8,

    /// `HKCU\Software\Microsoft`.
    pub fn text(p: Path, arena: std.mem.Allocator) []const u8 {
        if (p.sub.len == 0) return p.root.label();
        return fmt(arena, "{s}\\{s}", .{ p.root.label(), p.sub });
    }
};

/// Registry value types (winnt.h `REG_*`).
pub const Kind = enum(u32) {
    none = 0,
    sz = 1,
    expand_sz = 2,
    binary = 3,
    dword = 4,
    dword_big_endian = 5,
    link = 6,
    multi_sz = 7,
    resource_list = 8,
    full_resource_descriptor = 9,
    resource_requirements_list = 10,
    qword = 11,
    _,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .none => "REG_NONE",
            .sz => "REG_SZ",
            .expand_sz => "REG_EXPAND_SZ",
            .binary => "REG_BINARY",
            .dword => "REG_DWORD",
            .dword_big_endian => "REG_DWORD_BIG_ENDIAN",
            .link => "REG_LINK",
            .multi_sz => "REG_MULTI_SZ",
            .resource_list => "REG_RESOURCE_LIST",
            .full_resource_descriptor => "REG_FULL_RESOURCE_DESCRIPTOR",
            .resource_requirements_list => "REG_RESOURCE_REQUIREMENTS_LIST",
            .qword => "REG_QWORD",
            _ => "REG_UNKNOWN",
        };
    }
};

pub const Value = struct {
    /// UTF-8; empty for the default value.
    name: []const u8,
    kind: Kind,
    /// Raw bytes as stored (UTF-16LE for strings), empty when `size`
    /// exceeded what the backend reads.
    data: []const u8,
    /// Full size of the data in bytes.
    size: u32,
    /// REG_EXPAND_SZ: the data with its environment variables expanded.
    expanded: ?[]const u8 = null,
};

pub const Failure = union(enum) {
    missing_key,
    missing_value,
    denied,
    /// Another Win32 error code.
    other: u32,
};

pub const ValueResult = union(enum) { ok: Value, failed: Failure };

pub const Key = struct {
    values: []const Value,
    values_total: usize,
    subkeys: []const []const u8,
    subkeys_total: usize,
};

pub const KeyResult = union(enum) { ok: Key, failed: Failure };

pub const max_values = 100;
pub const max_subkeys = 200;
/// Bytes of a REG_BINARY shown.
pub const max_binary = 256;
/// Data the backend reads per value; a larger one is reported by size.
pub const max_data = 1024 * 1024;

pub const masked = "<masqué>";

/// Words that make a value name a secret, compared without case and
/// without `_`, `-`, `.` and spaces (`API_KEY` is `apikey`).
pub const secret_words = [_][]const u8{ "pass", "pwd", "secret", "token", "credential", "apikey", "private" };

/// Whether `name` contains a secret word, whatever its length (a value name
/// holds up to 16383 characters): the last normalized characters are kept
/// and matched as each one arrives.
pub fn secretName(name: []const u8) bool {
    const longest = comptime blk: {
        var n: usize = 0;
        for (secret_words) |word| n = @max(n, word.len);
        break :blk n;
    };
    var tail: [longest]u8 = undefined;
    var n: usize = 0;
    for (name) |c| {
        if (c == '_' or c == '-' or c == ' ' or c == '.') continue;
        if (n == tail.len) {
            std.mem.copyForwards(u8, tail[0 .. n - 1], tail[1..n]);
            n -= 1;
        }
        tail[n] = std.ascii.toLower(c);
        n += 1;
        for (secret_words) |word| if (n >= word.len and std.mem.eql(u8, tail[n - word.len .. n], word)) return true;
    }
    return false;
}

/// Keys refused whole, versioned with the PRD (list 1): the SAM and LSA
/// hives, the boot key's parts, saved credentials of Windows, Office,
/// Internet Explorer and the OpenSSH agent's keys, and remote access tools
/// known to keep passwords in the registry. `*` matches one key name; a
/// pattern under HKCU also applies under every `HKU\<sid>`, and one under
/// `Software` also under `Software\WOW6432Node`.
pub const protected_keys = [_][]const u8{
    "HKLM\\SAM",
    "HKLM\\SECURITY",
    "HKLM\\SYSTEM\\*\\Control\\Lsa\\Data",
    "HKLM\\SYSTEM\\*\\Control\\Lsa\\GBG",
    "HKLM\\SYSTEM\\*\\Control\\Lsa\\JD",
    "HKLM\\SYSTEM\\*\\Control\\Lsa\\Skew1",
    "HKLM\\SYSTEM\\*\\Services\\SNMP\\Parameters\\ValidCommunities",
    "HKCU\\Software\\Microsoft\\IdentityCRL",
    "HKCU\\Software\\Microsoft\\Internet Explorer\\IntelliForms",
    "HKCU\\Software\\Microsoft\\Protected Storage System Provider",
    "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Windows Messaging Subsystem\\Profiles",
    "HKCU\\Software\\Microsoft\\Office\\*\\Outlook\\Profiles",
    "HKCU\\Software\\OpenSSH\\Agent",
    "HKCU\\Software\\SimonTatham\\PuTTY\\Sessions",
    "HKCU\\Software\\Martin Prikryl\\WinSCP 2\\Sessions",
    "HKCU\\Software\\Martin Prikryl\\WinSCP 2\\Configuration\\Security",
    "HKCU\\Software\\FTPWare\\COREFTP\\Sites",
    "HKCU\\Software\\ORL\\WinVNC3",
    "HKLM\\SOFTWARE\\ORL\\WinVNC3",
    "HKCU\\Software\\RealVNC",
    "HKLM\\SOFTWARE\\RealVNC",
    "HKCU\\Software\\TightVNC",
    "HKLM\\SOFTWARE\\TightVNC",
    "HKCU\\Software\\TigerVNC",
    "HKLM\\SOFTWARE\\TigerVNC",
};

const roots = [_]struct { []const u8, Root }{
    .{ "HKCU", .hkcu }, .{ "HKEY_CURRENT_USER", .hkcu },
    .{ "HKLM", .hklm }, .{ "HKEY_LOCAL_MACHINE", .hklm },
    .{ "HKCR", .hkcr }, .{ "HKEY_CLASSES_ROOT", .hkcr },
    .{ "HKU", .hku },   .{ "HKEY_USERS", .hku },
    .{ "HKCC", .hkcc }, .{ "HKEY_CURRENT_CONFIG", .hkcc },
};

/// `HKCU\Software\X`, `HKEY_LOCAL_MACHINE\...`, or regedit's address bar
/// (`Ordinateur\HKEY_...`, `Computer\HKEY_...`). Repeated and trailing
/// backslashes are dropped; a forward slash is part of a key name. A NUL is
/// refused: Windows would stop the key name there, after the protected-key
/// check had compared the whole segment.
pub fn parsePath(arena: std.mem.Allocator, text: []const u8) ?Path {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return null;
    var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, text, " \t\""), '\\');
    var first = it.next() orelse return null;
    if (std.ascii.eqlIgnoreCase(first, "Computer") or std.ascii.eqlIgnoreCase(first, "Ordinateur")) first = it.next() orelse return null;
    const root = for (roots) |r| {
        if (std.ascii.eqlIgnoreCase(r[0], first)) break r[1];
    } else return null;
    var out: std.ArrayList(u8) = .empty;
    while (it.next()) |seg| {
        if (out.items.len > 0) out.append(arena, '\\') catch return null;
        out.appendSlice(arena, seg) catch return null;
    }
    return .{ .root = root, .sub = out.items };
}

fn matchSegments(pattern: []const u8, segs: []const []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, pattern, '\\');
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (i >= segs.len) return false;
        if (!std.mem.eql(u8, p, "*") and !std.ascii.eqlIgnoreCase(p, segs[i])) return false;
    }
    return true;
}

fn matchesList(segs: []const []const u8) bool {
    for (protected_keys) |p| if (matchSegments(p, segs)) return true;
    return false;
}

/// Whether `p` is a protected key or lies below one.
pub fn protectedKey(arena: std.mem.Allocator, p: Path) bool {
    var segs: std.ArrayList([]const u8) = .empty;
    segs.append(arena, p.root.label()) catch return true;
    var it = std.mem.tokenizeScalar(u8, p.sub, '\\');
    while (it.next()) |s| segs.append(arena, s) catch return true;
    return protectedSegments(arena, segs.items);
}

fn protectedSegments(arena: std.mem.Allocator, segs: []const []const u8) bool {
    if (matchesList(segs)) return true;
    // `Software\WOW6432Node\X` is the 32-bit view of `Software\X`.
    if (segs.len > 2 and std.ascii.eqlIgnoreCase(segs[1], "Software") and std.ascii.eqlIgnoreCase(segs[2], "WOW6432Node")) {
        var view: std.ArrayList([]const u8) = .empty;
        view.appendSlice(arena, segs[0..2]) catch return true;
        view.appendSlice(arena, segs[3..]) catch return true;
        if (protectedSegments(arena, view.items)) return true;
    }
    // `HKU\<sid>` is a user's HKCU.
    if (std.mem.eql(u8, segs[0], "HKU") and segs.len > 1) {
        var user: std.ArrayList([]const u8) = .empty;
        user.append(arena, "HKCU") catch return true;
        user.appendSlice(arena, segs[2..]) catch return true;
        if (protectedSegments(arena, user.items)) return true;
    }
    return false;
}

const oom = "Mémoire insuffisante : réessaie.";
const example = "ex. HKCU\\Software\\Microsoft";

fn failureMessage(ctx: anytype, f: Failure, path: []const u8, name: ?[]const u8) Result {
    return Result.err(switch (f) {
        .missing_key => fmt(ctx.arena, "Clé introuvable : {s} ; vérifie le chemin (" ++ example ++ ")", .{path}),
        .missing_value => fmt(ctx.arena, "Valeur introuvable : {s} dans {s} ; appelle registry_read sans name pour lister ses valeurs", .{ nameLabel(name.?), path }),
        .denied => fmt(ctx.arena, "Accès refusé à {s} : clé réservée à l'administrateur", .{path}),
        .other => |code| fmt(ctx.arena, "Lecture de {s} impossible (erreur Win32 {d}) : réessaie", .{ path, code }),
    });
}

fn nameLabel(name: []const u8) []const u8 {
    return if (name.len == 0) "(default)" else name;
}

pub fn read(ctx: anytype, path_text: []const u8, name: ?[]const u8) Result {
    if (policy.requireSystem(ctx, "registry_read", .registry_read)) |r| return r;
    const path = parsePath(ctx.arena, path_text) orelse
        return Result.err(fmt(ctx.arena, "Chemin de registre invalide : `{s}` ; commence par HKCU, HKLM, HKCR, HKU ou HKCC (" ++ example ++ ")", .{path_text}));
    const shown = path.text(ctx.arena);
    ctx.audit_detail.registry_path = shown;
    ctx.audit_detail.registry_name = name;
    if (protectedKey(ctx.arena, path)) {
        ctx.denied = true;
        return Result.err("Clé protégée : lecture refusée");
    }
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    if (name) |n| {
        if (std.mem.indexOfScalar(u8, n, 0) != null) return Result.err("Nom de valeur invalide : caractère NUL ; retire-le");
        const v = switch (ctx.backend.registryValue(ctx.arena, path, n)) {
            .ok => |v| v,
            .failed => |f| return failureMessage(ctx, f, shown, n),
        };
        // The data's budget leaves room for the name, the type and the
        // omission note within the output limit (FR-16).
        writeValue(&out.writer, v, max_text_output -| (n.len + 120)) catch return Result.err(oom);
        return Result.text(out.written());
    }
    const key = switch (ctx.backend.registryKey(ctx.arena, path, max_values, max_subkeys)) {
        .ok => |k| k,
        .failed => |f| return failureMessage(ctx, f, shown, null),
    };
    writeKey(&out, shown, key) catch return Result.err(oom);
    return Result.text(out.written());
}

/// `[<path>] <n> valeurs, <n> sous-clés`, one line per value (100 at most),
/// then one per subkey with a trailing backslash (200 at most), within the
/// output limit.
pub fn writeKey(w: *std.Io.Writer.Allocating, path: []const u8, key: Key) !void {
    const limit = max_text_output - 120;
    try w.writer.print("[{s}] {d} valeur{s}, {d} sous-clé{s}\n", .{ path, key.values_total, plural(key.values_total), key.subkeys_total, plural(key.subkeys_total) });
    for (key.values, 0..) |v, i| {
        const mark = w.written().len;
        try writeValue(&w.writer, v, 2000);
        try w.writer.writeByte('\n');
        if (w.written().len > limit) {
            w.shrinkRetainingCapacity(mark);
            try w.writer.print("… {d} valeurs omises (limite de sortie) : précise name\n", .{key.values_total - i});
            return finish(w);
        }
    }
    if (key.values_total > key.values.len) try w.writer.print("… {d} valeurs omises ({d} au plus)\n", .{ key.values_total - key.values.len, max_values });
    for (key.subkeys, 0..) |s, i| {
        const mark = w.written().len;
        try writeEscaped(&w.writer, s);
        try w.writer.writeAll("\\\n");
        if (w.written().len > limit) {
            w.shrinkRetainingCapacity(mark);
            try w.writer.print("… {d} sous-clés omises (limite de sortie) : lis une sous-clé\n", .{key.subkeys_total - i});
            return finish(w);
        }
    }
    if (key.subkeys_total > key.subkeys.len) try w.writer.print("… {d} sous-clés omises ({d} au plus)\n", .{ key.subkeys_total - key.subkeys.len, max_subkeys });
    finish(w);
}

fn finish(w: *std.Io.Writer.Allocating) void {
    const trimmed = std.mem.trimEnd(u8, w.written(), "\n");
    w.shrinkRetainingCapacity(trimmed.len);
}

fn plural(n: usize) []const u8 {
    return if (n > 1) "s" else "";
}

/// `<name> <type> = <data>`, the data within `budget` bytes.
pub fn writeValue(w: *std.Io.Writer, v: Value, budget: usize) !void {
    try writeEscaped(w, nameLabel(v.name));
    try w.print(" {s} = ", .{v.kind.label()});
    if (secretName(v.name)) return w.writeAll(masked);
    if (v.data.len < v.size) return w.print("<{d} octets, trop long pour être affiché>", .{v.size});
    const d = v.data;
    switch (v.kind) {
        .sz, .link => _ = try writeText(w, utf16(d), budget),
        .expand_sz => {
            _ = try writeText(w, utf16(d), budget / 2);
            if (v.expanded) |e| {
                try w.writeAll(" -> ");
                try writeUtf8(w, e, budget / 2);
            }
        },
        .multi_sz => {
            // Entries end with a NUL; empty ones (the final terminator) are
            // skipped.
            var rest = utf16(d);
            var used: usize = 0;
            while (rest.len > 0) {
                var end: usize = 0;
                while (end < rest.len and !(rest[end] == 0 and rest[end + 1] == 0)) end += 2;
                const entry = rest[0..end];
                rest = rest[@min(rest.len, end + 2)..];
                if (entry.len == 0) continue;
                if (used >= budget) {
                    try w.writeAll("\n  …");
                    break;
                }
                try w.writeAll("\n  ");
                used += 3 + try writeText(w, entry, budget - used);
            }
        },
        .dword => if (d.len >= 4) {
            const x = std.mem.readInt(u32, d[0..4], .little);
            try w.print("{d} (0x{x})", .{ x, x });
        } else try writeHex(w, d),
        .dword_big_endian => if (d.len >= 4) {
            const x = std.mem.readInt(u32, d[0..4], .big);
            try w.print("{d} (0x{x})", .{ x, x });
        } else try writeHex(w, d),
        .qword => if (d.len >= 8) {
            const x = std.mem.readInt(u64, d[0..8], .little);
            try w.print("{d} (0x{x})", .{ x, x });
        } else try writeHex(w, d),
        else => try writeHex(w, d),
    }
}

/// Hexadecimal bytes, the first `max_binary` of them.
fn writeHex(w: *std.Io.Writer, d: []const u8) !void {
    if (d.len == 0) return w.writeAll("(vide)");
    for (d[0..@min(d.len, max_binary)], 0..) |b, i| try w.print("{s}{x:0>2}", .{ if (i == 0) "" else " ", b });
    if (d.len > max_binary) try w.print(" … ({d} octets)", .{d.len});
}

/// The UTF-16LE bytes of `d` without the trailing NUL units (an odd last
/// byte is dropped).
fn utf16(d: []const u8) []const u8 {
    var n = d.len & ~@as(usize, 1);
    while (n >= 2 and d[n - 1] == 0 and d[n - 2] == 0) n -= 2;
    return d[0..n];
}

/// UTF-16 text as UTF-8, control characters escaped, within `budget`
/// bytes, then `… <n> caractères omis`; returns the bytes written.
fn writeText(w: *std.Io.Writer, bytes: []const u8, budget: usize) !usize {
    var it: std.unicode.Wtf16LeIterator = .{ .bytes = bytes, .i = 0 };
    var used: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (used >= budget) {
            var rest: usize = 1;
            while (it.nextCodepoint()) |_| rest += 1;
            const note = "… {d} caractères omis";
            try w.print(note, .{rest});
            return used + std.fmt.count(note, .{rest});
        }
        used += try writeCodepoint(w, cp);
    }
    return used;
}

fn writeUtf8(w: *std.Io.Writer, s: []const u8, budget: usize) !void {
    var it = (std.unicode.Utf8View.init(s) catch return w.writeAll("?")).iterator();
    var used: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (used >= budget) return w.writeAll("…");
        used += try writeCodepoint(w, cp);
    }
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    var it = (std.unicode.Utf8View.init(s) catch return w.writeAll(s)).iterator();
    while (it.nextCodepoint()) |cp| _ = try writeCodepoint(w, cp);
}

/// Writes one code point, a control character as `\n`, `\t`, `\0` or
/// `\x1f`; returns the bytes written.
fn writeCodepoint(w: *std.Io.Writer, cp: u21) !usize {
    switch (cp) {
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0 => try w.writeAll("\\0"),
        1...8, 11, 12, 14...0x1f, 0x7f => {
            try w.print("\\x{x:0>2}", .{cp});
            return 4;
        },
        else => {
            var buf: [4]u8 = undefined;
            // A lone surrogate from WTF-16 becomes U+FFFD.
            const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
            try w.writeAll(buf[0..n]);
            return n;
        },
    }
    return 2;
}

fn wide(comptime s: []const u8) []const u8 {
    const u = std.unicode.utf8ToUtf16LeStringLiteral(s);
    return std.mem.sliceAsBytes(u[0 .. u.len + 1]);
}

test "paths: short and long roots, regedit's address bar, separators" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = parsePath(a, "hkey_current_user\\\\Software\\Microsoft\\").?;
    try std.testing.expectEqual(Root.hkcu, p.root);
    try std.testing.expectEqualStrings("Software\\Microsoft", p.sub);
    try std.testing.expectEqualStrings("HKCU\\Software\\Microsoft", p.text(a));
    try std.testing.expectEqualStrings("HKLM", parsePath(a, "Ordinateur\\HKEY_LOCAL_MACHINE").?.text(a));
    try std.testing.expectEqualStrings("HKCR\\.txt", parsePath(a, "Computer\\HKCR\\.txt").?.text(a));
    try std.testing.expectEqualStrings("HKU\\S-1-5-18\\a/b", parsePath(a, "HKU\\S-1-5-18\\a/b").?.text(a));
    try std.testing.expectEqual(Root.hkcc, parsePath(a, "HKCC\\System").?.root);
    for ([_][]const u8{ "", "\\", "HKXX\\Software", "Software\\Microsoft", "Computer" }) |bad| try std.testing.expectEqual(@as(?Path, null), parsePath(a, bad));
}

test "value names that suggest a secret are masked" {
    for ([_][]const u8{ "Password", "DefaultPassword", "ProxyPass", "pwd", "ClientSecret", "AccessToken", "Credentials", "ApiKey", "API_KEY", "x-api-key", "PrivateKey", "private.key" }) |n| try std.testing.expect(secretName(n));
    for ([_][]const u8{ "", "fWrap", "Path", "Version", "DisplayName", "KeyboardDelay" }) |n| try std.testing.expect(!secretName(n));
    // A false positive is accepted: `Passive` contains `pass`.
    try std.testing.expect(secretName("Passive"));
}

test "protected keys: listed keys, their descendants, other control sets, WOW6432Node and HKU" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (protected_keys) |k| try std.testing.expect(protectedKey(a, parsePath(a, std.mem.replaceOwned(u8, a, k, "*", "x") catch unreachable).?));
    for ([_][]const u8{
        "HKLM\\SAM",
        "hklm\\sam\\SAM\\Domains",
        "HKEY_LOCAL_MACHINE\\SECURITY\\Policy\\Secrets",
        "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Lsa\\JD",
        "HKLM\\SYSTEM\\ControlSet001\\Control\\Lsa\\Skew1",
        "HKCU\\Software\\SimonTatham\\PuTTY\\Sessions\\server",
        "HKU\\S-1-5-21-1-2-3-1001\\Software\\Microsoft\\IdentityCRL",
        "HKLM\\SOFTWARE\\WOW6432Node\\TightVNC\\Server",
        "HKCU\\Software\\Microsoft\\Office\\16.0\\Outlook\\Profiles\\Outlook",
        "HKCU\\Software\\OpenSSH\\Agent\\Keys",
    }) |k| {
        if (!protectedKey(a, parsePath(a, k).?)) {
            std.debug.print("`{s}` is not protected\n", .{k});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "HKLM", "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Lsa", "HKCU\\Software\\Microsoft\\Notepad", "HKU\\S-1-5-18", "HKCU\\Software\\SimonTatham\\PuTTY", "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion" }) |k| {
        if (protectedKey(a, parsePath(a, k).?)) {
            std.debug.print("`{s}` is protected\n", .{k});
            return error.TestUnexpectedResult;
        }
    }
}

test "values: strings, numbers, binary cut at 256 bytes, multi-strings, expandable strings, masking" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const cases = [_]struct { Value, []const u8 }{
        .{ .{ .name = "", .kind = .sz, .data = wide("Bloc-notes"), .size = 22 }, "(default) REG_SZ = Bloc-notes" },
        .{ .{ .name = "Line", .kind = .sz, .data = wide("a\nb\tc"), .size = 12 }, "Line REG_SZ = a\\nb\\tc" },
        .{ .{ .name = "fWrap", .kind = .dword, .data = &.{ 1, 0, 0, 0 }, .size = 4 }, "fWrap REG_DWORD = 1 (0x1)" },
        .{ .{ .name = "Big", .kind = .dword_big_endian, .data = &.{ 0, 0, 1, 0 }, .size = 4 }, "Big REG_DWORD_BIG_ENDIAN = 256 (0x100)" },
        .{ .{ .name = "Q", .kind = .qword, .data = &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .size = 8 }, "Q REG_QWORD = 18446744073709551615 (0xffffffffffffffff)" },
        .{ .{ .name = "Bin", .kind = .binary, .data = &.{ 0x01, 0xab, 0x00 }, .size = 3 }, "Bin REG_BINARY = 01 ab 00" },
        .{ .{ .name = "Empty", .kind = .binary, .data = "", .size = 0 }, "Empty REG_BINARY = (vide)" },
        .{ .{ .name = "List", .kind = .multi_sz, .data = wide("un\x00deux\x00"), .size = 18 }, "List REG_MULTI_SZ = \n  un\n  deux" },
        .{ .{ .name = "Path", .kind = .expand_sz, .data = wide("%SystemRoot%\\x"), .size = 30, .expanded = "C:\\WINDOWS\\x" }, "Path REG_EXPAND_SZ = %SystemRoot%\\x -> C:\\WINDOWS\\x" },
        .{ .{ .name = "DefaultPassword", .kind = .sz, .data = wide("hunter2"), .size = 16 }, "DefaultPassword REG_SZ = <masqué>" },
        .{ .{ .name = "Huge", .kind = .binary, .data = "", .size = 5_000_000 }, "Huge REG_BINARY = <5000000 octets, trop long pour être affiché>" },
    };
    for (cases) |c| {
        buf.clearRetainingCapacity();
        try writeValue(&buf.writer, c[0], max_text_output);
        try std.testing.expectEqualStrings(c[1], buf.written());
    }
    var blob: [600]u8 = undefined;
    for (&blob, 0..) |*b, i| b.* = @truncate(i);
    buf.clearRetainingCapacity();
    try writeValue(&buf.writer, .{ .name = "Blob", .kind = .binary, .data = &blob, .size = blob.len }, max_text_output);
    try std.testing.expect(std.mem.endsWith(u8, buf.written(), " fe ff … (600 octets)"));
    try std.testing.expectEqual(@as(usize, "Blob REG_BINARY = ".len + 256 * 3 - 1 + " … (600 octets)".len), buf.written().len);
}

test "a key lists its values then its subkeys, with the omitted counts" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const values = [_]Value{.{ .name = "fWrap", .kind = .dword, .data = &.{ 1, 0, 0, 0 }, .size = 4 }};
    try writeKey(&buf, "HKCU\\Software\\Microsoft\\Notepad", .{ .values = &values, .values_total = 130, .subkeys = &.{ "A", "B" }, .subkeys_total = 250 });
    try std.testing.expectEqualStrings(
        \\[HKCU\Software\Microsoft\Notepad] 130 valeurs, 250 sous-clés
        \\fWrap REG_DWORD = 1 (0x1)
        \\… 129 valeurs omises (100 au plus)
        \\A\
        \\B\
        \\… 248 sous-clés omises (200 au plus)
    , buf.written());
}

test "a key's listing stays within the output limit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, 2 * 3000);
    for (std.mem.bytesAsSlice(u16, long)) |*u| u.* = 'x';
    var values: [max_values]Value = undefined;
    for (&values, 0..) |*v, i| v.* = .{ .name = try std.fmt.allocPrint(a, "v{d}", .{i}), .kind = .sz, .data = long, .size = @intCast(long.len) };
    var buf: std.Io.Writer.Allocating = .init(a);
    try writeKey(&buf, "HKCU\\X", .{ .values = &values, .values_total = values.len, .subkeys = &.{}, .subkeys_total = 0 });
    try std.testing.expect(buf.written().len <= max_text_output);
    try std.testing.expect(std.mem.endsWith(u8, buf.written(), "valeurs omises (limite de sortie) : précise name"));
}

test "a NUL in the path or the name is refused: Windows would read the key before it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?Path, null), parsePath(a, "HKCU\\Software\\SimonTatham\\PuTTY\\Sessions\x00x"));
    try std.testing.expectEqual(@as(?Path, null), parsePath(a, "HKCU\\Software\\SimonTatham\\PuTTY\\Sessions\x00"));
}

test "a secret word past the 256th character of a long value name is still masked" {
    var name: [400]u8 = @splat('a');
    @memcpy(name[300..308], "Password");
    try std.testing.expect(secretName(&name));
    @memcpy(name[390..400], "credential");
    try std.testing.expect(secretName(name[310..]));
    try std.testing.expect(!secretName(name[0..300]));
}
