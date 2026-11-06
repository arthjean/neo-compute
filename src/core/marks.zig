//! Element ids drawn on a screenshot (US-031, `ui_tree` `marks`): a 5x8
//! bitmap font of digits and lowercase letters, the placement of one label
//! per actionable element at the top-left corner of its rectangle, and the
//! drawing into the reduced BGRA image, after masking. Each label is an id
//! `ui_act` takes: what the model sees maps to an element without guessing
//! coordinates. Nothing here calls a platform API.

const std = @import("std");
const Rect = @import("display.zig").Rect;

/// Most labels drawn on one image.
pub const max_labels = 150;

const glyph_w = 5;
const glyph_h = 8;
/// One pixel between two glyphs.
const advance = glyph_w + 1;
/// Border and padding around the text, each 1 px.
const inset = 2;
/// Height of a label: the step a label moves down when its place is taken.
pub const label_h = glyph_h + 2 * inset;

/// Longest id text (`e` and seven base-36 digits cover every u32).
const max_text = 8;

/// A label to draw: the id text and the element's rectangle in screenshot
/// pixels.
pub const Label = struct {
    text_buf: [max_text]u8 = undefined,
    text_len: u8 = 0,
    rect: Rect,

    pub fn text(self: *const Label) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    /// The label of element id `id` (`e12`) over `rect`.
    pub fn of(id: u32, rect: Rect) Label {
        var l: Label = .{ .rect = rect };
        var w: std.Io.Writer = .fixed(&l.text_buf);
        w.writeByte('e') catch unreachable;
        w.printInt(id, 36, .lower, .{}) catch unreachable;
        l.text_len = @intCast(w.end);
        return l;
    }
};

/// Rows of each glyph, top first; bit 4 is the leftmost column. Digits sit
/// on rows 0 to 6, letters on a baseline at row 6 with descenders on row 7.
const font = blk: {
    const rows = .{
        .{ '0', .{ ".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###.", "....." } },
        .{ '1', .{ "..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###.", "....." } },
        .{ '2', .{ ".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####", "....." } },
        .{ '3', .{ "#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###.", "....." } },
        .{ '4', .{ "...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#.", "....." } },
        .{ '5', .{ "#####", "#....", "####.", "....#", "....#", "#...#", ".###.", "....." } },
        .{ '6', .{ "..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###.", "....." } },
        .{ '7', .{ "#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#...", "....." } },
        .{ '8', .{ ".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###.", "....." } },
        .{ '9', .{ ".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##..", "....." } },
        .{ 'a', .{ ".....", ".....", ".###.", "....#", ".####", "#...#", ".####", "....." } },
        .{ 'b', .{ "#....", "#....", "#.##.", "##..#", "#...#", "#...#", "####.", "....." } },
        .{ 'c', .{ ".....", ".....", ".###.", "#....", "#....", "#...#", ".###.", "....." } },
        .{ 'd', .{ "....#", "....#", ".##.#", "#..##", "#...#", "#...#", ".####", "....." } },
        .{ 'e', .{ ".....", ".....", ".###.", "#...#", "#####", "#....", ".###.", "....." } },
        .{ 'f', .{ "..##.", ".#..#", ".#...", "###..", ".#...", ".#...", ".#...", "....." } },
        .{ 'g', .{ ".....", ".....", ".####", "#...#", "#...#", ".####", "....#", ".###." } },
        .{ 'h', .{ "#....", "#....", "#.##.", "##..#", "#...#", "#...#", "#...#", "....." } },
        .{ 'i', .{ "..#..", ".....", ".##..", "..#..", "..#..", "..#..", ".###.", "....." } },
        .{ 'j', .{ "...#.", ".....", "..##.", "...#.", "...#.", "...#.", "#..#.", ".##.." } },
        .{ 'k', .{ "#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "....." } },
        .{ 'l', .{ ".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###.", "....." } },
        .{ 'm', .{ ".....", ".....", "##.#.", "#.#.#", "#.#.#", "#...#", "#...#", "....." } },
        .{ 'n', .{ ".....", ".....", "#.##.", "##..#", "#...#", "#...#", "#...#", "....." } },
        .{ 'o', .{ ".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###.", "....." } },
        .{ 'p', .{ ".....", ".....", "####.", "#...#", "#...#", "####.", "#....", "#...." } },
        .{ 'q', .{ ".....", ".....", ".####", "#...#", "#...#", ".####", "....#", "....#" } },
        .{ 'r', .{ ".....", ".....", "#.##.", "##..#", "#....", "#....", "#....", "....." } },
        .{ 's', .{ ".....", ".....", ".####", "#....", ".###.", "....#", "####.", "....." } },
        .{ 't', .{ ".#...", ".#...", "###..", ".#...", ".#...", ".#..#", "..##.", "....." } },
        .{ 'u', .{ ".....", ".....", "#...#", "#...#", "#...#", "#..##", ".##.#", "....." } },
        .{ 'v', .{ ".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#..", "....." } },
        .{ 'w', .{ ".....", ".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#.", "....." } },
        .{ 'x', .{ ".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....." } },
        .{ 'y', .{ ".....", ".....", "#...#", "#...#", "#...#", ".####", "....#", ".###." } },
        .{ 'z', .{ ".....", ".....", "#####", "...#.", "..#..", ".#...", "#####", "....." } },
    };
    @setEvalBranchQuota(10_000);
    var table: [128][glyph_h]u8 = @splat(@splat(0));
    for (rows) |entry| {
        for (entry[1], 0..) |row, y| {
            if (row.len != glyph_w) @compileError("glyph row is not 5 columns wide");
            var bits: u8 = 0;
            for (row) |c| bits = (bits << 1) | @intFromBool(c == '#');
            table[entry[0]][y] = bits;
        }
    }
    break :blk table;
};

/// Bits of `c`'s row `y` (bit 4 leftmost); 0 for a character outside the
/// font.
pub fn glyphRow(c: u8, y: usize) u8 {
    return if (c < font.len) font[c][y] else 0;
}

fn labelRect(l: *const Label, x: i32, y: i32) Rect {
    return .{ .x = x, .y = y, .w = @as(i32, l.text_len) * advance - 1 + 2 * inset, .h = label_h };
}

fn overlap(a: Rect, b: Rect) i64 {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.right(), b.right());
    const y1 = @min(a.bottom(), b.bottom());
    if (x1 <= x0 or y1 <= y0) return 0;
    return @as(i64, x1 - x0) * (y1 - y0);
}

/// Whether `r` covers more than half of a placed label (or a placed label
/// more than half of `r`).
fn crowded(r: Rect, placed: []const Rect) bool {
    const area = @as(i64, r.w) * r.h;
    for (placed) |p| {
        const o = overlap(r, p);
        if (o * 2 > area or o * 2 > @as(i64, p.w) * p.h) return true;
    }
    return false;
}

/// Where each label goes on a `width` x `height` image: the top-left corner
/// of its element, kept inside the image; one line lower when that covers
/// more than half of a label already placed; left out when that place is
/// taken too, or past `max_labels`. Fills `out` (as long as `labels`) with
/// the label rectangles, null for a label left out, and returns the number
/// placed.
pub fn layout(labels: []const Label, width: u32, height: u32, out: []?Rect) usize {
    std.debug.assert(out.len >= labels.len);
    var placed: [max_labels]Rect = undefined;
    var n: usize = 0;
    for (labels, out[0..labels.len]) |*l, *o| {
        o.* = null;
        if (n == max_labels) continue;
        const size = labelRect(l, 0, 0);
        if (size.w > width or size.h > height) continue;
        const max_x: i32 = @as(i32, @intCast(width)) - size.w;
        const max_y: i32 = @as(i32, @intCast(height)) - size.h;
        const x = std.math.clamp(l.rect.x, 0, max_x);
        const y0 = std.math.clamp(l.rect.y, 0, max_y);
        const first = labelRect(l, x, y0);
        const r = if (!crowded(first, placed[0..n])) first else blk: {
            const lower = labelRect(l, x, @min(y0 + label_h, max_y));
            if (lower.y == y0 or crowded(lower, placed[0..n])) break :blk null;
            break :blk lower;
        } orelse continue;
        placed[n] = r;
        n += 1;
        o.* = r;
    }
    return n;
}

const black = [4]u8{ 0, 0, 0, 255 };
const white = [4]u8{ 255, 255, 255, 255 };
/// BGRA yellow: the border stands out on dark and light surfaces alike.
const yellow = [4]u8{ 0, 255, 255, 255 };

/// Draws `l` at `r` (from `layout`, inside the image) into `pixels`, a
/// tightly packed `width`-pixel-wide BGRA image: a yellow 1 px border, a
/// black box and the id in white.
pub fn draw(pixels: []u8, width: u32, l: *const Label, r: Rect) void {
    const stride = @as(usize, width) * 4;
    const x0: usize = @intCast(r.x);
    const y0: usize = @intCast(r.y);
    const w: usize = @intCast(r.w);
    const h: usize = @intCast(r.h);
    for (0..h) |dy| {
        const row = pixels[(y0 + dy) * stride + x0 * 4 ..][0 .. w * 4];
        for (0..w) |dx| {
            const edge = dy == 0 or dy == h - 1 or dx == 0 or dx == w - 1;
            row[dx * 4 ..][0..4].* = if (edge) yellow else black;
        }
    }
    for (l.text(), 0..) |c, i| {
        const gx = x0 + inset + i * advance;
        for (0..glyph_h) |gy| {
            const bits = glyphRow(c, gy);
            const row = pixels[(y0 + inset + gy) * stride ..];
            for (0..glyph_w) |b| if (bits & (@as(u8, 0x10) >> @intCast(b)) != 0) {
                row[(gx + b) * 4 ..][0..4].* = white;
            };
        }
    }
}

test "every id character has a glyph, and the glyphs differ" {
    const chars = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (chars, 0..) |a, i| {
        var any = false;
        for (0..glyph_h) |y| any = any or glyphRow(a, y) != 0;
        try std.testing.expect(any);
        for (chars[i + 1 ..]) |b| {
            var same = true;
            for (0..glyph_h) |y| same = same and glyphRow(a, y) == glyphRow(b, y);
            try std.testing.expect(!same);
        }
    }
}

test "labels go to the top-left corner, move one line down when crowded, else are left out" {
    const labels = [_]Label{
        .of(1, .{ .x = 10, .y = 10, .w = 100, .h = 40 }),
        // Same corner: one line lower.
        .of(2, .{ .x = 10, .y = 10, .w = 80, .h = 30 }),
        // Same corner again: both places are taken.
        .of(3, .{ .x = 12, .y = 11, .w = 50, .h = 20 }),
        // Past the right edge: pulled back inside the image.
        .of(4, .{ .x = 195, .y = 80, .w = 30, .h = 20 }),
    };
    var out: [labels.len]?Rect = undefined;
    try std.testing.expectEqual(@as(usize, 3), layout(&labels, 200, 100, &out));
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 15, .h = label_h }, out[0].?);
    try std.testing.expectEqual(@as(i32, 10 + label_h), out[1].?.y);
    try std.testing.expect(out[2] == null);
    try std.testing.expect(out[3].?.right() <= 200);
    // A small overlap (under half a label) keeps the label in place.
    const near = [_]Label{ .of(1, .{ .x = 0, .y = 0, .w = 9, .h = 9 }), .of(2, .{ .x = 9, .y = 0, .w = 9, .h = 9 }) };
    var out2: [2]?Rect = undefined;
    _ = layout(&near, 200, 100, &out2);
    try std.testing.expectEqual(@as(i32, 0), out2[1].?.y);
}

test "at most 150 labels" {
    var labels: [200]Label = undefined;
    for (&labels, 0..) |*l, i| l.* = .of(@intCast(i + 1), .{ .x = @intCast(i % 20 * 40), .y = @intCast(i / 20 * 30), .w = 30, .h = 20 });
    var out: [200]?Rect = undefined;
    try std.testing.expectEqual(@as(usize, max_labels), layout(&labels, 1280, 720, &out));
    try std.testing.expect(out[max_labels - 1] != null and out[max_labels] == null);
}

test "a drawn label has a yellow border, a black box and the id's glyphs in white" {
    const w = 40;
    var pixels: [w * 20 * 4]u8 = @splat(128);
    const l: Label = .of(1, .{ .x = 3, .y = 2, .w = 10, .h = 10 });
    var out: [1]?Rect = undefined;
    _ = layout(&.{l}, w, 20, &out);
    const r = out[0].?;
    draw(&pixels, w, &l, r);
    const px = struct {
        fn at(p: []const u8, x: usize, y: usize) [4]u8 {
            return p[(y * w + x) * 4 ..][0..4].*;
        }
    }.at;
    try std.testing.expectEqual(yellow, px(&pixels, 3, 2));
    try std.testing.expectEqual(yellow, px(&pixels, @intCast(r.right() - 1), @intCast(r.bottom() - 1)));
    try std.testing.expectEqual(black, px(&pixels, 4, 3));
    // `e`, row 2 (".###."): columns 1 to 3 lit, 0 and 4 dark.
    const gy: usize = 2 + inset + 2;
    try std.testing.expectEqual(black, px(&pixels, 3 + inset, gy));
    try std.testing.expectEqual(white, px(&pixels, 3 + inset + 1, gy));
    try std.testing.expectEqual(white, px(&pixels, 3 + inset + 3, gy));
    // Around the label the image is untouched.
    try std.testing.expectEqual([4]u8{ 128, 128, 128, 128 }, px(&pixels, 2, 2));
    try std.testing.expectEqualStrings("e1", l.text());
    try std.testing.expectEqualStrings("e1k", Label.of(56, r).text());
}
