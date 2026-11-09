//! Control indicator (US-034), the portable part: what the indicator shows
//! for a control state, its labels, its geometry on one display, and
//! whether a DXGI dirty rect is covered by that geometry. The Windows
//! backend draws it (`src/backend/windows/indicator.zig`).
//!
//! Decision 0011 (US-033): a window excluded from capture never shows in a
//! DXGI or GDI frame, but showing, hiding or repainting it still produces
//! dirty rects over its area. So the indicator never animates, changes only
//! on a state change, and the dirty rects its own changes produce are
//! dropped from settling and from ui_find's wait.

const std = @import("std");
const display = @import("display.zig");
const keys = @import("keys.zig");

pub const acting_label = "neo-compute is acting: Esc pauses";
/// The indicator stays this long after an action and its settling.
pub const linger_ms = 1000;
/// Dirty rects covered by the indicator are its own for this long after
/// one of its changes: DWM composes a change at the next refresh, and a
/// look for changes collects it within a few frames.
pub const echo_ms = 150;
/// Frame width at 96 dpi, scaled with the display's DPI.
pub const frame_px = 4;

pub const Look = enum { hidden, acting, paused };

/// What the indicator shows: the pause wins over everything until the
/// re-arm; an action (settling included) shows `acting`, which lingers
/// `linger_ms` after it ends.
pub fn lookOf(paused: bool, busy: bool, lingering: bool) Look {
    if (paused) return .paused;
    if (busy or lingering) return .acting;
    return .hidden;
}

/// What a state update does to the linger timer. `began`: an action began
/// since the previous update (the control's epoch moved), so an action
/// that began and ended before the indicator's thread woke up still
/// lingers `linger_ms`, as one seen running does.
pub const Linger = enum { stop, start, keep };

pub fn lingerOf(paused: bool, busy: bool, began: bool, look: Look, lingering: bool) Linger {
    if (paused or busy) return .stop;
    if (began or (look == .acting and !lingering)) return .start;
    return .keep;
}

/// "neo-compute paused: Ctrl+Alt+Shift+R resumes", with the re-arm
/// shortcut actually configured (`--rearm-key`).
pub fn pausedLabel(buf: []u8, rearm: keys.Combo) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("neo-compute paused: ") catch return "neo-compute paused";
    writeCombo(&w, rearm) catch return "neo-compute paused";
    w.writeAll(" resumes") catch return "neo-compute paused";
    return w.buffered();
}

/// A shortcut as Windows writes it: `Ctrl+Alt+Shift+Win+R`.
pub fn writeCombo(w: *std.Io.Writer, combo: keys.Combo) !void {
    if (combo.mods.ctrl) try w.writeAll("Ctrl+");
    if (combo.mods.alt) try w.writeAll("Alt+");
    if (combo.mods.shift) try w.writeAll("Shift+");
    if (combo.mods.super) try w.writeAll("Win+");
    switch (combo.key) {
        .char => |c| {
            const upper: u21 = if (c < 128) std.ascii.toUpper(@intCast(c)) else c;
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(upper, &tmp) catch 0;
            try w.writeAll(tmp[0..n]);
        },
        .key => |k| try w.writeAll(keyName(k)),
    }
}

fn keyName(k: keys.Key) []const u8 {
    for (keys.names) |n| if (n.spec == .key and n.spec.key == k) return n.name;
    return @tagName(k);
}

/// Frame width on a display of `dpi`: 4 px at 96 dpi, never thinner.
pub fn frameWidth(dpi: u32) i32 {
    return @max(frame_px, @as(i32, @intCast((frame_px * dpi + 48) / 96)));
}

/// The indicator on one display: four strips along its edges and the label
/// box hanging from the middle of the top edge, desktop coordinates.
pub const Layout = struct {
    rects: [5]display.Rect,

    pub fn strips(self: *const Layout) []const display.Rect {
        return self.rects[0..4];
    }

    pub fn label(self: *const Layout) display.Rect {
        return self.rects[4];
    }
};

/// `text` is the size of the label's text in pixels; the box adds padding
/// scaled with `dpi` and stays inside the display.
pub fn layout(monitor: display.Rect, dpi: u32, text: [2]i32) Layout {
    const f = frameWidth(dpi);
    const pad_x: i32 = @intCast((12 * dpi + 48) / 96);
    const pad_y: i32 = @intCast((4 * dpi + 48) / 96);
    const lw = @min(text[0] + 2 * pad_x, monitor.w);
    const lh = @min(text[1] + 2 * pad_y + f, monitor.h);
    const m = monitor;
    return .{ .rects = .{
        .{ .x = m.x, .y = m.y, .w = m.w, .h = f },
        .{ .x = m.x, .y = m.bottom() - f, .w = m.w, .h = f },
        .{ .x = m.x, .y = m.y + f, .w = f, .h = m.h - 2 * f },
        .{ .x = m.right() - f, .y = m.y + f, .w = f, .h = m.h - 2 * f },
        .{ .x = m.x + @divTrunc(m.w - lw, 2), .y = m.y, .w = lw, .h = lh },
    } };
}

/// Whether every pixel of `r` lies in the union of `rects`.
pub fn covered(rects: []const display.Rect, r: display.Rect) bool {
    if (r.w <= 0 or r.h <= 0) return true;
    if (rects.len == 0) return false;
    const c = rects[0];
    if (!c.intersects(r)) return covered(rects[1..], r);
    // What `c` leaves of `r`: up to four bands, each checked against the
    // remaining rectangles.
    const top = c.y - r.y;
    const bottom = r.bottom() - c.bottom();
    const mid_y = @max(r.y, c.y);
    const mid_h = @min(r.bottom(), c.bottom()) - mid_y;
    const rest = rects[1..];
    if (top > 0 and !covered(rest, .{ .x = r.x, .y = r.y, .w = r.w, .h = top })) return false;
    if (bottom > 0 and !covered(rest, .{ .x = r.x, .y = c.bottom(), .w = r.w, .h = bottom })) return false;
    if (c.x > r.x and !covered(rest, .{ .x = r.x, .y = mid_y, .w = c.x - r.x, .h = mid_h })) return false;
    if (r.right() > c.right() and !covered(rest, .{ .x = c.right(), .y = mid_y, .w = r.right() - c.right(), .h = mid_h })) return false;
    return true;
}

/// Removes from `dirty` the rects the indicator's own change produced: those
/// covered by `rects`. Returns how many were removed.
pub fn dropEchoes(dirty: []display.Rect, rects: []const display.Rect) struct { kept: usize, dropped: usize } {
    var kept: usize = 0;
    for (dirty) |d| {
        if (covered(rects, d)) continue;
        dirty[kept] = d;
        kept += 1;
    }
    return .{ .kept = kept, .dropped = dirty.len - kept };
}

test "look follows pause, action and linger" {
    try std.testing.expectEqual(Look.hidden, lookOf(false, false, false));
    try std.testing.expectEqual(Look.acting, lookOf(false, true, false));
    try std.testing.expectEqual(Look.acting, lookOf(false, false, true));
    try std.testing.expectEqual(Look.paused, lookOf(true, true, true));
    try std.testing.expectEqual(Look.paused, lookOf(true, false, false));
}

test "linger: an action seen running, or begun and ended between two updates, lingers" {
    // Seen running, then ended: the linger starts once.
    try std.testing.expectEqual(Linger.stop, lingerOf(false, true, true, .hidden, false));
    try std.testing.expectEqual(Linger.start, lingerOf(false, false, false, .acting, false));
    try std.testing.expectEqual(Linger.keep, lingerOf(false, false, false, .acting, true));
    // Begun and ended before the update: shown, lingering.
    try std.testing.expectEqual(Linger.start, lingerOf(false, false, true, .hidden, false));
    try std.testing.expectEqual(Look.acting, lookOf(false, false, true));
    // Another brief action during a linger restarts it.
    try std.testing.expectEqual(Linger.start, lingerOf(false, false, true, .acting, true));
    // At rest, and after the re-arm: nothing lingers.
    try std.testing.expectEqual(Linger.keep, lingerOf(false, false, false, .hidden, false));
    try std.testing.expectEqual(Linger.keep, lingerOf(false, false, false, .paused, false));
    try std.testing.expectEqual(Linger.stop, lingerOf(true, false, true, .acting, true));
}

test "paused label names the configured re-arm shortcut" {
    var buf: [96]u8 = undefined;
    const default: keys.Combo = .{ .mods = .{ .ctrl = true, .alt = true, .shift = true }, .key = .{ .char = 'r' } };
    try std.testing.expectEqualStrings("neo-compute paused: Ctrl+Alt+Shift+R resumes", pausedLabel(&buf, default));
    const f12: keys.Combo = .{ .mods = .{ .super = true }, .key = .{ .key = .f12 } };
    try std.testing.expectEqualStrings("neo-compute paused: Win+F12 resumes", pausedLabel(&buf, f12));
    var small: [8]u8 = undefined;
    try std.testing.expectEqualStrings("neo-compute paused", pausedLabel(&small, default));
}

test "layout: a 4 px frame at 96 dpi, scaled above, label centered on the top edge" {
    const m: display.Rect = .{ .x = 2560, .y = 0, .w = 2560, .h = 1440 };
    const l = layout(m, 96, .{ 240, 16 });
    try std.testing.expectEqual(@as(i32, 4), l.rects[0].h);
    try std.testing.expect(l.rects[1].eql(.{ .x = 2560, .y = 1436, .w = 2560, .h = 4 }));
    try std.testing.expect(l.rects[2].eql(.{ .x = 2560, .y = 4, .w = 4, .h = 1432 }));
    try std.testing.expect(l.rects[3].eql(.{ .x = 5116, .y = 4, .w = 4, .h = 1432 }));
    try std.testing.expect(l.label().eql(.{ .x = 2560 + (2560 - 264) / 2, .y = 0, .w = 264, .h = 28 }));
    try std.testing.expectEqual(@as(i32, 6), frameWidth(144));
    try std.testing.expectEqual(@as(i32, 4), frameWidth(72));
    // A label wider than the display is clipped to it.
    const narrow = layout(.{ .x = 0, .y = 0, .w = 100, .h = 50 }, 96, .{ 400, 16 });
    try std.testing.expect(narrow.label().eql(.{ .x = 0, .y = 0, .w = 100, .h = 28 }));
}

test "covered: a rect inside the union of the frame and label, and one that is not" {
    const m: display.Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    const l = layout(m, 96, .{ 200, 16 });
    // One strip, a corner spanning two strips, the label with the top strip.
    try std.testing.expect(covered(&l.rects, .{ .x = 0, .y = 596, .w = 1000, .h = 4 }));
    try std.testing.expect(covered(&l.rects, .{ .x = 0, .y = 0, .w = 4, .h = 300 }));
    try std.testing.expect(covered(&l.rects, .{ .x = l.label().x, .y = 0, .w = l.label().w, .h = l.label().h }));
    try std.testing.expect(covered(&l.rects, .{ .x = 0, .y = 0, .w = 1000, .h = 4 }));
    // A rect reaching one pixel into the inside, or the whole display.
    try std.testing.expect(!covered(&l.rects, .{ .x = 0, .y = 0, .w = 5, .h = 300 }));
    try std.testing.expect(!covered(&l.rects, m));
    try std.testing.expect(!covered(&.{}, .{ .x = 0, .y = 0, .w = 1, .h = 1 }));
    try std.testing.expect(covered(&.{}, .{ .x = 0, .y = 0, .w = 0, .h = 1 }));
}

test "dropEchoes keeps the dirty rects the indicator does not cover" {
    const l = layout(.{ .x = 0, .y = 0, .w = 1000, .h = 600 }, 96, .{ 200, 16 });
    var dirty = [_]display.Rect{
        .{ .x = 0, .y = 0, .w = 1000, .h = 4 },
        .{ .x = 100, .y = 100, .w = 50, .h = 50 },
        .{ .x = 996, .y = 10, .w = 4, .h = 20 },
        .{ .x = 0, .y = 0, .w = 1000, .h = 600 },
    };
    const r = dropEchoes(&dirty, &l.rects);
    try std.testing.expectEqual(@as(usize, 2), r.dropped);
    try std.testing.expectEqual(@as(usize, 2), r.kept);
    try std.testing.expect(dirty[0].eql(.{ .x = 100, .y = 100, .w = 50, .h = 50 }));
    try std.testing.expect(dirty[1].eql(.{ .x = 0, .y = 0, .w = 1000, .h = 600 }));
}
