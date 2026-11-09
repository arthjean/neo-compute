//! clipboard (US-035, FR-26): reads and writes the clipboard's text. A read
//! is refused when the content carries a format password managers and
//! private browsing set to keep monitors away, or when its owner is a
//! `deny` application; nothing of a refused content leaves the backend. A
//! write sets the formats that keep it out of the clipboard history and the
//! cloud clipboard. The audit records the mode and the length only (FR-29).

const std = @import("std");
const policy = @import("policy.zig");
const Result = @import("mcp.zig").Result;
const fmt = @import("session.zig").fmt;
const max_text_output = @import("tools.zig").max_text_output;

/// Largest text `set` accepts, in UTF-8 bytes.
pub const max_set_bytes = 1024 * 1024;

/// Characters the backend copies at most: an output's limit (FR-16).
pub const max_read_chars = max_text_output;

/// Characters of a cut text, leaving room for the omission line within the
/// output limit.
const cut_chars = max_text_output - 40;

/// Registered formats that mark a content secret (Clipboard Formats,
/// learn.microsoft.com; `Clipboard Viewer Ignore` from CopyQ's security
/// notes). The two `Can...` formats mark it only when their DWORD is 0.
pub const Marker = enum {
    exclude_monitor,
    viewer_ignore,
    no_history,
    no_cloud,

    pub fn format(m: Marker) []const u8 {
        return switch (m) {
            .exclude_monitor => "ExcludeClipboardContentFromMonitorProcessing",
            .viewer_ignore => "Clipboard Viewer Ignore",
            .no_history => "CanIncludeInClipboardHistory",
            .no_cloud => "CanUploadToCloudClipboard",
        };
    }
};

pub const Read = union(enum) {
    /// The text cut to `max_read_chars` code points, and its full length.
    text: struct { text: []const u8, total: usize, owner_pid: ?u32 },
    /// No CF_UNICODETEXT: the formats present, by name.
    no_text: struct { formats: []const []const u8, owner_pid: ?u32 },
    /// Marked secret: no data was read.
    secret: struct { marker: Marker, owner_pid: ?u32 },
    /// Another window kept the clipboard open through every retry; the
    /// process holding it, when Windows says.
    busy: ?u32,
    failed: []const u8,
};

pub const Write = union(enum) {
    ok,
    busy: ?u32,
    failed: []const u8,
};

pub const Mode = enum { get, set };

const oom = "Mémoire insuffisante : réessaie.";

/// Names of the standard formats (winuser.h `CF_*`), by id.
pub fn standardName(id: u32) ?[]const u8 {
    return switch (id) {
        1 => "CF_TEXT",
        2 => "CF_BITMAP",
        3 => "CF_METAFILEPICT",
        4 => "CF_SYLK",
        5 => "CF_DIF",
        6 => "CF_TIFF",
        7 => "CF_OEMTEXT",
        8 => "CF_DIB",
        9 => "CF_PALETTE",
        10 => "CF_PENDATA",
        11 => "CF_RIFF",
        12 => "CF_WAVE",
        13 => "CF_UNICODETEXT",
        14 => "CF_ENHMETAFILE",
        15 => "CF_HDROP",
        16 => "CF_LOCALE",
        17 => "CF_DIBV5",
        0x80 => "CF_OWNERDISPLAY",
        0x81 => "CF_DSPTEXT",
        0x82 => "CF_DSPBITMAP",
        0x83 => "CF_DSPMETAFILEPICT",
        0x8E => "CF_DSPENHMETAFILE",
        else => null,
    };
}

/// Executable of process `pid` for a message, `une application inconnue`
/// when Windows does not say.
fn appName(ctx: anytype, pid: ?u32) []const u8 {
    const p = pid orelse return "une application inconnue";
    return ctx.backend.processName(ctx.arena, p) orelse "une application inconnue";
}

fn secretMessage(ctx: anytype, pid: ?u32) Result {
    ctx.denied = true;
    return Result.err(fmt(ctx.arena, "Presse-papiers marqué secret par {s} : lecture refusée", .{appName(ctx, pid)}));
}

fn busyMessage(ctx: anytype, pid: ?u32) Result {
    return Result.err(fmt(ctx.arena, "Presse-papiers occupé par {s} : réessaie", .{appName(ctx, pid)}));
}

/// Whether the owner of the content is a `deny` application (a password
/// manager by default, US-017).
fn ownerDenied(ctx: anytype, pid: ?u32) bool {
    const p = pid orelse return false;
    return ctx.session.policy.levelOf(ctx.backend.processName(ctx.arena, p)) == .deny;
}

pub fn run(ctx: anytype, mode: Mode, text: ?[]const u8) Result {
    ctx.audit_detail.clipboard_mode = @tagName(mode);
    return switch (mode) {
        .get => get(ctx, text),
        .set => set(ctx, text),
    };
}

fn get(ctx: anytype, text: ?[]const u8) Result {
    if (text != null) return Result.err("text ne s'utilise qu'avec mode: set : retire-le pour lire le presse-papiers.");
    if (policy.requireSystem(ctx, "clipboard", .{ .clipboard = .read })) |r| return r;
    return switch (ctx.backend.clipboardRead(ctx.arena, max_read_chars, ctx.cancel)) {
        .secret => |s| secretMessage(ctx, s.owner_pid),
        .busy => |pid| busyMessage(ctx, pid),
        .failed => |msg| Result.err(msg),
        .no_text => |n| blk: {
            if (ownerDenied(ctx, n.owner_pid)) break :blk secretMessage(ctx, n.owner_pid);
            const list = if (n.formats.len == 0) "aucun" else std.mem.join(ctx.arena, ", ", n.formats) catch break :blk Result.err(oom);
            break :blk Result.err(fmt(ctx.arena, "Le presse-papiers ne contient pas de texte (formats : {s})", .{list}));
        },
        .text => |t| blk: {
            if (ownerDenied(ctx, t.owner_pid)) break :blk secretMessage(ctx, t.owner_pid);
            ctx.audit_detail.clipboard_len = t.total;
            if (t.total <= max_text_output) break :blk Result.text(t.text);
            const kept = prefixChars(t.text, cut_chars);
            break :blk Result.text(fmt(ctx.arena, "{s}\n… {d} caractères omis", .{ kept, t.total - (std.unicode.utf8CountCodepoints(kept) catch kept.len) }));
        },
    };
}

fn set(ctx: anytype, text: ?[]const u8) Result {
    const t = text orelse return Result.err("Passe text avec mode: set : le texte à écrire dans le presse-papiers.");
    if (policy.requireSystem(ctx, "clipboard", .{ .clipboard = .write })) |r| return r;
    if (t.len > max_set_bytes) return Result.err(fmt(ctx.arena, "Texte trop long : {d} octets, 1 Mio (1 048 576 octets) au plus. Découpe-le.", .{t.len}));
    const chars = std.unicode.utf8CountCodepoints(t) catch return Result.err("Texte invalide : UTF-8 attendu.");
    ctx.audit_detail.clipboard_len = chars;
    return switch (ctx.backend.clipboardWrite(ctx.arena, t, ctx.cancel)) {
        .ok => Result.text(fmt(ctx.arena, "Presse-papiers : {d} caractères écrits, exclus de l'historique et du cloud", .{chars})),
        .busy => |pid| busyMessage(ctx, pid),
        .failed => |msg| Result.err(msg),
    };
}

/// The first `n` code points of UTF-8 `s`.
pub fn prefixChars(s: []const u8, n: usize) []const u8 {
    var it = (std.unicode.Utf8View.init(s) catch return s[0..@min(s.len, n)]).iterator();
    var i: usize = 0;
    while (i < n) : (i += 1) if (it.nextCodepointSlice() == null) return s;
    return s[0..it.i];
}

test "prefixChars cuts at a code point boundary" {
    try std.testing.expectEqualStrings("é€", prefixChars("é€x", 2));
    try std.testing.expectEqualStrings("ab", prefixChars("ab", 5));
    try std.testing.expectEqualStrings("", prefixChars("abc", 0));
}

test "standard format names" {
    try std.testing.expectEqualStrings("CF_HDROP", standardName(15).?);
    try std.testing.expectEqualStrings("CF_DIBV5", standardName(17).?);
    try std.testing.expectEqual(@as(?[]const u8, null), standardName(0xC123));
}
