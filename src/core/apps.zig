//! Start menu catalog and name matching for app_launch (US-028). The backend
//! enumerates the Start menu's applications (display name, AUMID, packaged
//! or not); this module keeps the catalog for the session and matches a
//! name against it: case and accents ignored, word prefixes first, then
//! Jaro-Winkler similarity for a mistyped letter. An exact AUMID skips the
//! matching. Everything here is portable and tested on fixtures.

const std = @import("std");
const timing = @import("timing.zig");

/// One application of the Start menu.
pub const App = struct {
    /// Display name, in the language of the system (`Calculatrice`).
    name: []const u8,
    /// AppUserModelID: `Microsoft.WindowsCalculator_8wekyb3d8bbwe!App` for
    /// a packaged application, a path or an explicit ID otherwise.
    aumid: []const u8,
    /// Packaged (MSIX/UWP): launched by IApplicationActivationManager.
    packaged: bool,
    /// Executable of a non-packaged application's shortcut (`Code.exe`), so
    /// the policy can refuse a `deny` application before it starts. The
    /// Windows catalog leaves it null: the backend's `appExe` reads it for
    /// the chosen entry only.
    exe: ?[]const u8 = null,
    /// Normalized name and AUMID words, computed once by the catalog so a
    /// lookup allocates nothing per entry.
    keys: ?Keys = null,

    pub const Keys = struct { name: []const u8, aumid: []const u8 };

    fn keysOf(app: App, arena: std.mem.Allocator) !Keys {
        return app.keys orelse .{ .name = try normalize(arena, app.name), .aumid = try aumidWords(arena, app.aumid) };
    }
};

/// The backend's Start menu enumeration.
pub const CatalogResult = union(enum) { ok: []const App, err: []const u8 };

/// How a launched application is asked to show its window: `normal`
/// activates it, the two others ask Windows not to (background mode,
/// US-043). An application is free to ignore the request.
pub const Show = enum { normal, no_activate, minimized };

/// Outcome of a launch (US-029): the process id when Windows gives it.
pub const Launch = union(enum) {
    ok: ?u32,
    /// HRESULT of Windows' refusal.
    refused: u32,
    cancelled,
    /// A message for the model (FR-06).
    unavailable: []const u8,
};

/// What a path names, from the file system only (no shell call).
pub const PathInfo = struct {
    kind: enum { file, directory, missing, remote },
    /// Absolute form of the path.
    full: []const u8,
};

/// Below this quality no candidate is offered: Jaro-Winkler keeps a
/// mistyped, missing, extra or swapped letter in a word of four letters or
/// more above it.
pub const threshold = 0.88;
/// Candidates whose scores differ by less than this share are ambiguous.
pub const ambiguity = 0.05;
pub const max_candidates = 5;

/// Catalog of the session: enumerated on first use, again after a lookup
/// found nothing, at most once a minute.
pub const Catalog = struct {
    arena: ?std.heap.ArenaAllocator = null,
    apps: []const App = &.{},
    loaded: bool = false,
    /// Monotonic time of the last enumeration.
    enumerated_at: i96 = 0,

    pub const refresh_ns: i96 = 60 * std.time.ns_per_s;

    pub fn deinit(self: *Catalog) void {
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }

    /// Replaces the entries with `fresh` (copied into the catalog's own
    /// memory).
    pub fn replace(self: *Catalog, gpa: std.mem.Allocator, fresh: []const App, at: i96) !void {
        if (self.arena == null) self.arena = .init(gpa);
        const a = &self.arena.?;
        // Nothing points into the arena while it is refilled: a failed copy
        // leaves an empty catalog, enumerated again on the next lookup.
        self.apps = &.{};
        self.loaded = false;
        _ = a.reset(.retain_capacity);
        const out = try a.allocator().alloc(App, fresh.len);
        for (fresh, out) |src, *dst| {
            dst.* = .{
                .name = try a.allocator().dupe(u8, src.name),
                .aumid = try a.allocator().dupe(u8, src.aumid),
                .packaged = src.packaged,
                .exe = if (src.exe) |e| try a.allocator().dupe(u8, e) else null,
            };
            dst.keys = try dst.keysOf(a.allocator());
        }
        self.apps = out;
        self.loaded = true;
        self.enumerated_at = at;
    }

    /// Whether a lookup without result may enumerate again.
    pub fn mayRefresh(self: *const Catalog, at: i96) bool {
        return !self.loaded or at - self.enumerated_at >= refresh_ns;
    }
};

pub const Match = union(enum) {
    found: App,
    /// Display names (or `name (AUMID)` for equal names) of the close
    /// candidates, best first.
    ambiguous: []const []const u8,
    none,
};

// ---------------------------------------------------------------- normalization

/// Lowercase ASCII for an accented Latin letter (Latin-1 and Latin
/// Extended-A cover French, German, Spanish and the other Western
/// languages), as one or two letters; null when the code point is no letter
/// this table knows.
fn fold(cp: u21) ?[]const u8 {
    return switch (cp) {
        'a'...'z', '0'...'9' => null,
        0xE0...0xE5, 0xC0...0xC5, 0x101, 0x103, 0x105, 0x100, 0x102, 0x104 => "a",
        0xE7, 0xC7, 0x107, 0x109, 0x10B, 0x10D, 0x106, 0x108, 0x10A, 0x10C => "c",
        0x10F, 0x111, 0x10E, 0x110 => "d",
        0xE8...0xEB, 0xC8...0xCB, 0x113, 0x115, 0x117, 0x119, 0x11B, 0x112, 0x114, 0x116, 0x118, 0x11A => "e",
        0x11D, 0x11F, 0x121, 0x123, 0x11C, 0x11E, 0x120, 0x122 => "g",
        0xEC...0xEF, 0xCC...0xCF, 0x129, 0x12B, 0x12D, 0x12F, 0x131, 0x128, 0x12A, 0x12C, 0x12E, 0x130 => "i",
        0xF1, 0xD1, 0x144, 0x146, 0x148, 0x143, 0x145, 0x147 => "n",
        0xF2...0xF6, 0xF8, 0xD2...0xD6, 0xD8, 0x14D, 0x14F, 0x151, 0x14C, 0x14E, 0x150 => "o",
        0x155, 0x157, 0x159, 0x154, 0x156, 0x158 => "r",
        0x15B, 0x15D, 0x15F, 0x161, 0x15A, 0x15C, 0x15E, 0x160 => "s",
        0x163, 0x165, 0x162, 0x164 => "t",
        0xF9...0xFC, 0xD9...0xDC, 0x169, 0x16B, 0x16D, 0x16F, 0x171, 0x173, 0x168, 0x16A, 0x16C, 0x16E, 0x170, 0x172 => "u",
        0xFD, 0xFF, 0xDD, 0x178 => "y",
        0x17A, 0x17C, 0x17E, 0x179, 0x17B, 0x17D => "z",
        0xDF => "ss",
        0xE6, 0xC6 => "ae",
        0x153, 0x152 => "oe",
        else => null,
    };
}

/// Lowercase words of `text` without accents, separated by one space.
/// `+` and `#` belong to words (Notepad++, C#); every other character that
/// is no letter or digit separates them.
pub fn normalize(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = (std.unicode.Utf8View.init(text) catch return normalizeBytes(arena, text)).iterator();
    var space = false;
    while (it.nextCodepoint()) |cp| {
        const lower: u21 = if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
        const piece: ?[]const u8 = if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or lower == '+' or lower == '#')
            &[_]u8{@intCast(lower)}
        else
            fold(lower);
        if (piece) |p| {
            if (space and out.items.len > 0) try out.append(arena, ' ');
            space = false;
            try out.appendSlice(arena, p);
        } else space = true;
    }
    return out.items;
}

fn normalizeBytes(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text) |c| {
        const l = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(l) or l == '+' or l == '#') {
            if (space and out.items.len > 0) try out.append(arena, ' ');
            space = false;
            try out.append(arena, l);
        } else space = true;
    }
    return out.items;
}

/// Words of an AUMID (`Microsoft.WindowsCalculator_8wekyb3d8bbwe!App`):
/// split at punctuation and at lowercase-to-uppercase boundaries, without
/// the package's publisher hash, so an English name finds an application
/// whose display name is localized (`calculator`, `notepad`).
fn aumidWords(arena: std.mem.Allocator, aumid: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < aumid.len) {
        while (i < aumid.len and !std.ascii.isAlphanumeric(aumid[i])) i += 1;
        const start = i;
        while (i < aumid.len and std.ascii.isAlphanumeric(aumid[i])) : (i += 1) {
            if (i > start and std.ascii.isUpper(aumid[i]) and std.ascii.isLower(aumid[i - 1])) break;
        }
        const word = aumid[start..i];
        if (word.len == 0) continue;
        // The publisher hash after `_`: 13 characters with digits.
        if (word.len == 13 and start > 0 and aumid[start - 1] == '_' and std.mem.indexOfAny(u8, word, "0123456789") != null) continue;
        if (out.items.len > 0) try out.append(arena, ' ');
        for (word) |c| try out.append(arena, std.ascii.toLower(c));
    }
    return out.items;
}

// ---------------------------------------------------------------- similarity

/// Jaro-Winkler similarity of two short ASCII strings (0 to 1).
pub fn jaroWinkler(a: []const u8, b: []const u8) f64 {
    if (a.len == 0 or b.len == 0) return if (a.len == b.len) 1 else 0;
    if (a.len > 64 or b.len > 64) return if (std.mem.eql(u8, a, b)) 1 else 0;
    const window = @max(a.len, b.len) / 2 -| 1;
    var a_hit: [64]bool = @splat(false);
    var b_hit: [64]bool = @splat(false);
    var m: usize = 0;
    for (a, 0..) |c, i| {
        const lo = i -| window;
        const hi = @min(b.len, i + window + 1);
        if (lo >= hi) continue;
        for (lo..hi) |j| if (!b_hit[j] and b[j] == c) {
            a_hit[i] = true;
            b_hit[j] = true;
            m += 1;
            break;
        };
    }
    if (m == 0) return 0;
    var t: usize = 0;
    var k: usize = 0;
    for (a, 0..) |c, i| if (a_hit[i]) {
        while (!b_hit[k]) k += 1;
        if (c != b[k]) t += 1;
        k += 1;
    };
    const mf: f64 = @floatFromInt(m);
    const jaro = (mf / @as(f64, @floatFromInt(a.len)) + mf / @as(f64, @floatFromInt(b.len)) + (mf - @as(f64, @floatFromInt(t / 2))) / mf) / 3;
    var prefix: usize = 0;
    while (prefix < @min(4, a.len, b.len) and a[prefix] == b[prefix]) prefix += 1;
    return jaro + @as(f64, @floatFromInt(prefix)) * 0.1 * (1 - jaro);
}

fn letters(words: []const u8) usize {
    return words.len - std.mem.count(u8, words, " ");
}

/// How well a query matches a name: `quality` says whether the letters
/// agree (1 for equal words and word prefixes, the Jaro-Winkler similarity
/// otherwise), `coverage` how much of the name the query accounts for. The
/// threshold applies to quality, so a mistyped first word of a long name
/// still passes; ranking and ambiguity use `rank`, so the name the query
/// covers best wins (`visual studio code` over its Insiders edition).
pub const Score = struct {
    quality: f64 = 0,
    coverage: f64 = 0,

    pub fn rank(s: Score) f64 {
        return s.quality * (0.6 + 0.4 * s.coverage);
    }

    /// The better of two ways to match: one above the threshold first,
    /// then the higher rank.
    fn max(a: Score, b: Score) Score {
        const a_ok = a.quality >= threshold;
        const b_ok = b.quality >= threshold;
        if (a_ok != b_ok) return if (b_ok) b else a;
        return if (b.rank() > a.rank()) b else a;
    }
};

fn ratio(part: usize, whole: usize) f64 {
    return @min(1, @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(@max(whole, 1))));
}

/// Score of normalized `query` against normalized `name` (both words
/// separated by spaces): equal strings; every query word starting a
/// distinct name word; else each query word against its most similar name
/// word, or the whole strings without spaces (a missing or extra space).
pub fn score(query: []const u8, name: []const u8) Score {
    if (query.len == 0 or name.len == 0) return .{};
    if (std.mem.eql(u8, query, name)) return .{ .quality = 1, .coverage = 1 };
    var name_words: [16][]const u8 = undefined;
    var n: usize = 0;
    var nit = std.mem.tokenizeScalar(u8, name, ' ');
    while (nit.next()) |word| : (n += 1) {
        if (n == name_words.len) break;
        name_words[n] = word;
    }
    const name_letters = letters(name);
    // Word prefixes.
    var used: [16]bool = @splat(false);
    var all_prefix = true;
    var qit = std.mem.tokenizeScalar(u8, query, ' ');
    while (qit.next()) |q| {
        const hit = for (name_words[0..n], 0..) |word, i| {
            if (!used[i] and std.mem.startsWith(u8, word, q)) break i;
        } else null;
        if (hit) |i| used[i] = true else {
            all_prefix = false;
            break;
        }
    }
    if (all_prefix) return .{ .quality = 1, .coverage = ratio(letters(query), name_letters) };
    // Word by word: each query word against its best name word, whole or
    // cut to the query word's length plus one (a prefix with a typo).
    used = @splat(false);
    var worst: f64 = 1;
    var covered: usize = 0;
    qit.reset();
    while (qit.next()) |q| {
        var best: f64 = 0;
        var best_i: ?usize = null;
        for (name_words[0..n], 0..) |word, i| {
            if (used[i]) continue;
            const cut = word[0..@min(word.len, q.len + 1)];
            const s = @max(jaroWinkler(q, word), if (cut.len < word.len) jaroWinkler(q, cut) else 0);
            if (s > best) {
                best = s;
                best_i = i;
            }
        }
        if (best_i) |i| {
            used[i] = true;
            covered += @min(q.len, name_words[i].len);
        }
        worst = @min(worst, best);
    }
    const by_word: Score = .{ .quality = worst, .coverage = ratio(covered, name_letters) };
    var qbuf: [128]u8 = undefined;
    var nbuf: [128]u8 = undefined;
    const whole: Score = .{ .quality = jaroWinkler(squeeze(&qbuf, query), squeeze(&nbuf, name)), .coverage = ratio(letters(query), name_letters) };
    return by_word.max(whole);
}

fn squeeze(buf: *[128]u8, words: []const u8) []const u8 {
    var len: usize = 0;
    for (words) |c| if (c != ' ' and len < buf.len) {
        buf[len] = c;
        len += 1;
    };
    return buf[0..len];
}

/// English names of inbox applications whose AUMID holds no English word.
const aliases = [_]struct { name: []const u8, aumid: []const u8 }{
    .{ .name = "settings", .aumid = "windows.immersivecontrolpanel" },
};

/// Best score of `app` for normalized `query`: its display name, then the
/// words of its AUMID and the aliases, ranked below a display name.
fn appScore(arena: std.mem.Allocator, app: App, query: []const u8) !Score {
    const keys = try app.keysOf(arena);
    var best = score(query, keys.name);
    if (best.quality == 1 and best.coverage == 1) return best;
    // Only word prefixes count in an AUMID: a fuzzy match on `windows` or
    // `microsoft` would make every inbox application a candidate.
    const from_aumid = score(query, keys.aumid);
    if (from_aumid.quality == 1) best = best.max(.{ .quality = 0.95, .coverage = from_aumid.coverage });
    for (aliases) |al| if (std.mem.eql(u8, query, al.name) and std.ascii.findIgnoreCase(app.aumid, al.aumid) != null) {
        best = best.max(.{ .quality = 0.97, .coverage = 1 });
    };
    return best;
}

const Scored = struct { index: usize, rank: f64 };

fn better(_: void, a: Scored, b: Scored) bool {
    return a.rank > b.rank;
}

/// The application `query` names among `catalog`: an exact AUMID, a single
/// exact name, or the best candidate when no other is within 5 % of it.
pub fn match(arena: std.mem.Allocator, catalog: []const App, query: []const u8) !Match {
    const trimmed = std.mem.trim(u8, query, " \t");
    for (catalog) |app| if (std.ascii.eqlIgnoreCase(app.aumid, trimmed)) return .{ .found = app };
    const q = try normalize(arena, trimmed);
    if (q.len == 0) return .none;
    var scored: std.ArrayList(Scored) = .empty;
    var exact: ?usize = null;
    var exact_count: usize = 0;
    for (catalog, 0..) |app, i| {
        const s = try appScore(arena, app, q);
        if (s.quality == 1 and s.coverage == 1) {
            exact = i;
            exact_count += 1;
        }
        if (s.quality >= threshold) try scored.append(arena, .{ .index = i, .rank = s.rank() });
    }
    if (exact_count == 1) return .{ .found = catalog[exact.?] };
    if (scored.items.len == 0) return .none;
    std.mem.sort(Scored, scored.items, {}, better);
    const top = scored.items[0].rank;
    var close: usize = 1;
    while (close < scored.items.len and top - scored.items[close].rank < ambiguity * top) close += 1;
    if (close == 1) return .{ .found = catalog[scored.items[0].index] };
    const shown = @min(close, max_candidates);
    const names = try arena.alloc([]const u8, shown);
    for (names, scored.items[0..shown]) |*out, s| {
        const app = catalog[s.index];
        const twin = for (scored.items[0..shown]) |o| {
            if (o.index != s.index and std.mem.eql(u8, catalog[o.index].name, app.name)) break true;
        } else false;
        out.* = if (twin) try std.fmt.allocPrint(arena, "{s} ({s})", .{ app.name, app.aumid }) else app.name;
    }
    return .{ .ambiguous = names };
}

/// Whether a shell command line (an extension's default verb, UTF-16) runs
/// the file being opened as its program (`"%1" %*` for `.pif`, `%1 /S` for
/// `.scr`): app_launch refuses such a file as an executable (FR-25).
pub fn commandRunsFile(cmd: []const u16) bool {
    var i: usize = 0;
    while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
    if (i < cmd.len and cmd[i] == '"') i += 1;
    if (i + 1 >= cmd.len or cmd[i] != '%') return false;
    return cmd[i + 1] == '1' or cmd[i + 1] == 'L' or cmd[i + 1] == 'l';
}

test "a command whose program is %1 or %L runs the file itself" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expect(commandRunsFile(L("\"%1\" %*")));
    try std.testing.expect(commandRunsFile(L("%1 /S")));
    try std.testing.expect(commandRunsFile(L(" \"%L\"")));
    try std.testing.expect(!commandRunsFile(L("C:\\WINDOWS\\system32\\NOTEPAD.EXE %1")));
    try std.testing.expect(!commandRunsFile(L("\"C:\\WINDOWS\\hh.exe\" %1")));
    try std.testing.expect(!commandRunsFile(L("")));
}

/// Monotonic now, for the catalog's refresh.
pub fn now(io: std.Io) i96 {
    return timing.now(io);
}

// ---------------------------------------------------------------- tests

/// The catalog of the core tests (US-028): French display names, as on the
/// reference machine.
pub const fixture = [_]App{
    .{ .name = "Calculatrice", .aumid = "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App", .packaged = true },
    .{ .name = "Paramètres", .aumid = "windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel", .packaged = true },
    .{ .name = "Visual Studio Code", .aumid = "Microsoft.VisualStudioCode", .packaged = false, .exe = "Code.exe" },
    .{ .name = "Bloc-notes", .aumid = "Microsoft.WindowsNotepad_8wekyb3d8bbwe!App", .packaged = true },
    .{ .name = "Visual Studio Code - Insiders", .aumid = "Microsoft.VisualStudioCode.Insiders", .packaged = false, .exe = "Code - Insiders.exe" },
    .{ .name = "Explorateur de fichiers", .aumid = "Microsoft.Windows.Explorer", .packaged = false, .exe = "explorer.exe" },
    .{ .name = "Paint", .aumid = "Microsoft.Paint_8wekyb3d8bbwe!App", .packaged = true },
    .{ .name = "Notepad++", .aumid = "Notepad++", .packaged = false, .exe = "notepad++.exe" },
};

fn expectFound(query: []const u8, name: []const u8) !void {
    return expectFoundIn(&fixture, query, name);
}

fn expectFoundIn(catalog: []const App, query: []const u8, name: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try match(arena.allocator(), catalog, query);
    switch (m) {
        .found => |app| std.testing.expectEqualStrings(name, app.name) catch |err| {
            std.debug.print("`{s}` found `{s}`, expected `{s}`\n", .{ query, app.name, name });
            return err;
        },
        else => {
            std.debug.print("`{s}`: {t}, expected `{s}`\n", .{ query, m, name });
            return error.TestExpectedEqual;
        },
    }
}

test "names match without case or accents, by word prefix" {
    try expectFound("Calculatrice", "Calculatrice");
    try expectFound("calculatrice", "Calculatrice");
    try expectFound("CALC", "Calculatrice");
    try expectFound("Paramètres", "Paramètres");
    try expectFound("parametres", "Paramètres");
    try expectFound("PARAMETRES", "Paramètres");
    try expectFound("bloc-notes", "Bloc-notes");
    try expectFound("bloc notes", "Bloc-notes");
    try expectFound("visual studio code", "Visual Studio Code");
    try expectFound("code insiders", "Visual Studio Code - Insiders");
    try expectFound("explorateur", "Explorateur de fichiers");
    try expectFound("Notepad++", "Notepad++");
}

test "a mistyped, missing or extra letter still finds the application" {
    try expectFound("calculatrise", "Calculatrice");
    try expectFound("calcultrice", "Calculatrice");
    try expectFound("calcullatrice", "Calculatrice");
    try expectFound("paramtres", "Paramètres");
    try expectFound("parametrse", "Paramètres");
    try expectFound("blocnotes", "Bloc-notes");
    try expectFound("bloc-ntoes", "Bloc-notes");
    try expectFound("visual studio cde", "Visual Studio Code");
    try expectFound("visual stuido code", "Visual Studio Code");
    try expectFound("pint", "Paint");
}

test "English names find localized inbox applications through their AUMID" {
    try expectFound("calculator", "Calculatrice");
    try expectFoundIn(fixture[0..7], "notepad", "Bloc-notes");
    // A display name beats the words of an AUMID.
    try expectFound("notepad", "Notepad++");
    try expectFound("settings", "Paramètres");
}

test "an exact AUMID skips matching" {
    try expectFound("Microsoft.WindowsCalculator_8wekyb3d8bbwe!App", "Calculatrice");
    try expectFound("microsoft.visualstudiocode", "Visual Studio Code");
}

test "close candidates are ambiguous, at most five, best first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code = try match(a, &fixture, "code");
    try std.testing.expectEqual(@as(usize, 2), code.ambiguous.len);
    try std.testing.expectEqualStrings("Visual Studio Code", code.ambiguous[0]);
    try std.testing.expectEqualStrings("Visual Studio Code - Insiders", code.ambiguous[1]);
    // A single letter starts many words: five names at most.
    var many: [12]App = undefined;
    for (&many, 0..) |*app, i| app.* = .{ .name = try std.fmt.allocPrint(a, "Outil {d}", .{i}), .aumid = try std.fmt.allocPrint(a, "Tool{d}", .{i}), .packaged = false };
    const tools = try match(a, &many, "outil");
    try std.testing.expectEqual(@as(usize, max_candidates), tools.ambiguous.len);
    // Equal names show their AUMID.
    const twins = [_]App{
        .{ .name = "Outil", .aumid = "A.Tool", .packaged = false },
        .{ .name = "Outil", .aumid = "B.Tool", .packaged = false },
    };
    const t = try match(a, &twins, "outil");
    try std.testing.expectEqualStrings("Outil (A.Tool)", t.ambiguous[0]);
}

test "no candidate above the threshold is no match" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "photoshop", "zzz", "", "  ", "terminal" }) |q| {
        try std.testing.expectEqual(Match.none, try match(arena.allocator(), &fixture, q));
    }
}

test "normalization folds accents and keeps + and #" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("parametres", try normalize(a, "Paramètres"));
    try std.testing.expectEqualStrings("bloc notes", try normalize(a, "Bloc-notes"));
    try std.testing.expectEqualStrings("oeuvre a l ecole", try normalize(a, "Œuvre à l'École"));
    try std.testing.expectEqualStrings("notepad++ c#", try normalize(a, "Notepad++ (C#)"));
    try std.testing.expectEqualStrings("microsoft windows calculator app", try aumidWords(a, "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"));
}

test "the catalog enumerates again after a miss at most once a minute" {
    var c: Catalog = .{};
    defer c.deinit();
    try std.testing.expect(c.mayRefresh(0));
    try c.replace(std.testing.allocator, &fixture, 1000);
    try std.testing.expectEqual(fixture.len, c.apps.len);
    try std.testing.expect(!c.mayRefresh(1000 + 59 * std.time.ns_per_s));
    try std.testing.expect(c.mayRefresh(1000 + 60 * std.time.ns_per_s));
    try c.replace(std.testing.allocator, fixture[0..2], 2000);
    try std.testing.expectEqual(@as(usize, 2), c.apps.len);
    try std.testing.expectEqualStrings("Paramètres", c.apps[1].name);
}
