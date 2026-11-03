//! Portable key syntax of the `key` and `hold_key` tools: xdotool-style
//! names joined by `+` (`ctrl+s`, `alt+F4`, `Return`, `super`). Backends map
//! `Key` to their own codes and resolve characters on the active layout.

const std = @import("std");

pub const Key = enum {
    enter,
    tab,
    escape,
    backspace,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    space,
    caps_lock,
    num_lock,
    scroll_lock,
    pause,
    print_screen,
    menu,
    shift,
    ctrl,
    alt,
    super,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_add,
    kp_subtract,
    kp_multiply,
    kp_divide,
    kp_decimal,
    kp_enter,
    volume_mute,
    volume_up,
    volume_down,
    media_play,
    media_stop,
    media_next,
    media_prev,
};

pub const Mods = packed struct(u4) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn any(m: Mods) bool {
        return @as(u4, @bitCast(m)) != 0;
    }
};

/// The final key of a combination: a named key or a character, which the
/// backend resolves on the active keyboard layout.
pub const Spec = union(enum) {
    key: Key,
    char: u21,
};

pub const Combo = struct {
    mods: Mods = .{},
    key: Spec,
};

const Name = struct { name: []const u8, spec: Spec };

fn k(name: []const u8, key: Key) Name {
    return .{ .name = name, .spec = .{ .key = key } };
}

fn ch(name: []const u8, c: u21) Name {
    return .{ .name = name, .spec = .{ .char = c } };
}

/// Accepted names, matched without case. Keysym names of punctuation map to
/// the character so the active layout decides the physical key.
pub const names = [_]Name{
    k("Return", .enter),                     k("Enter", .enter),              k("Tab", .tab),                   k("Escape", .escape),
    k("Esc", .escape),                       k("BackSpace", .backspace),      k("Delete", .delete),             k("Del", .delete),
    k("Insert", .insert),                    k("Home", .home),                k("End", .end),                   k("Page_Up", .page_up),
    k("Prior", .page_up),                    k("Page_Down", .page_down),      k("Next", .page_down),            k("Up", .up),
    k("Down", .down),                        k("Left", .left),                k("Right", .right),               k("space", .space),
    k("Caps_Lock", .caps_lock),              k("Num_Lock", .num_lock),        k("Scroll_Lock", .scroll_lock),   k("Pause", .pause),
    k("Print", .print_screen),               k("Menu", .menu),                k("shift", .shift),               k("Shift_L", .shift),
    k("Shift_R", .shift),                    k("ctrl", .ctrl),                k("control", .ctrl),              k("Control_L", .ctrl),
    k("Control_R", .ctrl),                   k("alt", .alt),                  k("Alt_L", .alt),                 k("Alt_R", .alt),
    k("super", .super),                      k("Super_L", .super),            k("Super_R", .super),             k("Meta_L", .super),
    k("win", .super),                        k("cmd", .super),                k("F1", .f1),                     k("F2", .f2),
    k("F3", .f3),                            k("F4", .f4),                    k("F5", .f5),                     k("F6", .f6),
    k("F7", .f7),                            k("F8", .f8),                    k("F9", .f9),                     k("F10", .f10),
    k("F11", .f11),                          k("F12", .f12),                  k("F13", .f13),                   k("F14", .f14),
    k("F15", .f15),                          k("F16", .f16),                  k("F17", .f17),                   k("F18", .f18),
    k("F19", .f19),                          k("F20", .f20),                  k("F21", .f21),                   k("F22", .f22),
    k("F23", .f23),                          k("F24", .f24),                  k("KP_0", .kp_0),                 k("KP_1", .kp_1),
    k("KP_2", .kp_2),                        k("KP_3", .kp_3),                k("KP_4", .kp_4),                 k("KP_5", .kp_5),
    k("KP_6", .kp_6),                        k("KP_7", .kp_7),                k("KP_8", .kp_8),                 k("KP_9", .kp_9),
    k("KP_Add", .kp_add),                    k("KP_Subtract", .kp_subtract),  k("KP_Multiply", .kp_multiply),   k("KP_Divide", .kp_divide),
    k("KP_Decimal", .kp_decimal),            k("KP_Enter", .kp_enter),        k("XF86AudioMute", .volume_mute), k("XF86AudioRaiseVolume", .volume_up),
    k("XF86AudioLowerVolume", .volume_down), k("XF86AudioPlay", .media_play), k("XF86AudioStop", .media_stop),  k("XF86AudioNext", .media_next),
    k("XF86AudioPrev", .media_prev),         ch("minus", '-'),                ch("plus", '+'),                  ch("equal", '='),
    ch("comma", ','),                        ch("period", '.'),               ch("slash", '/'),                 ch("backslash", '\\'),
    ch("semicolon", ';'),                    ch("colon", ':'),                ch("apostrophe", '\''),           ch("quotedbl", '"'),
    ch("grave", '`'),                        ch("asciitilde", '~'),           ch("bracketleft", '['),           ch("bracketright", ']'),
    ch("braceleft", '{'),                    ch("braceright", '}'),           ch("parenleft", '('),             ch("parenright", ')'),
    ch("less", '<'),                         ch("greater", '>'),              ch("question", '?'),              ch("exclam", '!'),
    ch("at", '@'),                           ch("numbersign", '#'),           ch("dollar", '$'),                ch("percent", '%'),
    ch("asciicircum", '^'),                  ch("ampersand", '&'),            ch("asterisk", '*'),              ch("underscore", '_'),
    ch("bar", '|'),
};

pub const ParseError = union(enum) {
    ok: Combo,
    /// A segment that names no key.
    unknown: []const u8,
    /// A segment before the last one that is not a modifier.
    not_modifier: []const u8,
    empty,
};

fn lookup(segment: []const u8) ?Spec {
    for (names) |n| if (std.ascii.eqlIgnoreCase(n.name, segment)) return n.spec;
    // A single character (any code point) is typed through the layout.
    const len = std.unicode.utf8ByteSequenceLength(segment[0]) catch return null;
    if (len != segment.len) return null;
    const cp = std.unicode.utf8Decode(segment) catch return null;
    return .{ .char = cp };
}

fn modifierOf(spec: Spec) ?Mods {
    return switch (spec) {
        .key => |key| switch (key) {
            .shift => .{ .shift = true },
            .ctrl => .{ .ctrl = true },
            .alt => .{ .alt = true },
            .super => .{ .super = true },
            else => null,
        },
        .char => null,
    };
}

/// Parses `ctrl+shift+t`. A trailing `+` (`ctrl++`) or a lone `+` names
/// the plus key.
pub fn parse(text: []const u8) ParseError {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return .empty;
    var combo: Combo = .{ .key = undefined };
    var rest = t;
    while (true) {
        const plus = std.mem.indexOfScalarPos(u8, rest, 1, '+');
        const segment = if (plus) |p| rest[0..p] else rest;
        const spec = lookup(segment) orelse return .{ .unknown = segment };
        if (plus) |p| {
            const m = modifierOf(spec) orelse return .{ .not_modifier = segment };
            combo.mods = @bitCast(@as(u4, @bitCast(combo.mods)) | @as(u4, @bitCast(m)));
            rest = rest[p + 1 ..];
            if (rest.len == 0) return .{ .unknown = "" };
        } else {
            combo.key = spec;
            return .{ .ok = combo };
        }
    }
}

/// Up to five accepted names closest to `bad` (edit distance, no case).
pub fn closest(bad: []const u8, out: *[5][]const u8) [][]const u8 {
    var best: [5]struct { d: usize, i: usize } = @splat(.{ .d = std.math.maxInt(usize), .i = 0 });
    for (names, 0..) |n, i| {
        const d = distance(bad, n.name);
        var j: usize = best.len;
        while (j > 0 and best[j - 1].d > d) : (j -= 1) {}
        if (j == best.len) continue;
        var m: usize = best.len - 1;
        while (m > j) : (m -= 1) best[m] = best[m - 1];
        best[j] = .{ .d = d, .i = i };
    }
    for (best, 0..) |b, i| out[i] = names[b.i].name;
    return out[0..best.len];
}

fn distance(a: []const u8, b: []const u8) usize {
    var prev: [64]usize = undefined;
    var cur: [64]usize = undefined;
    const bl = @min(b.len, prev.len - 1);
    const al = @min(a.len, 63);
    for (0..bl + 1) |j| prev[j] = j;
    for (0..al) |i| {
        cur[0] = i + 1;
        for (0..bl) |j| {
            const cost: usize = if (std.ascii.toLower(a[i]) == std.ascii.toLower(b[j])) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. bl + 1], cur[0 .. bl + 1]);
    }
    return prev[bl];
}

test "toolset key syntax: combinations, names without case, characters" {
    const s = parse("ctrl+s").ok;
    try std.testing.expect(s.mods.ctrl and !s.mods.shift);
    try std.testing.expectEqual(Spec{ .char = 's' }, s.key);
    const f4 = parse("alt+F4").ok;
    try std.testing.expect(f4.mods.alt);
    try std.testing.expectEqual(Spec{ .key = .f4 }, f4.key);
    try std.testing.expectEqual(Spec{ .key = .enter }, parse("Return").ok.key);
    try std.testing.expectEqual(Spec{ .key = .enter }, parse("return").ok.key);
    try std.testing.expectEqual(Spec{ .key = .super }, parse("super").ok.key);
    const multi = parse("ctrl+shift+Tab").ok;
    try std.testing.expect(multi.mods.ctrl and multi.mods.shift);
    try std.testing.expectEqual(Spec{ .char = '+' }, parse("ctrl++").ok.key);
    try std.testing.expectEqual(Spec{ .char = '+' }, parse("+").ok.key);
    try std.testing.expectEqual(Spec{ .char = 'é' }, parse("é").ok.key);
    try std.testing.expectEqual(Spec{ .char = ';' }, parse("semicolon").ok.key);
    try std.testing.expectEqualStrings("Retrun", parse("ctrl+Retrun").unknown);
    try std.testing.expectEqualStrings("a", parse("a+b").not_modifier);
}

test "an unknown key name suggests the five closest valid names" {
    var buf: [5][]const u8 = undefined;
    const near = closest("Retrun", &buf);
    try std.testing.expectEqual(@as(usize, 5), near.len);
    try std.testing.expectEqualStrings("Return", near[0]);
    try std.testing.expectEqualStrings("BackSpace", closest("Backspce", &buf)[0]);
}
