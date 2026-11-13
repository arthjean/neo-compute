//! Portable display geometry: rectangles on the physical virtual desktop,
//! captured frames, and the mapping between a display's physical pixels and
//! the pixel space of its screenshot (FR-03).

const std = @import("std");

/// Rectangle in physical pixels of the virtual desktop. A secondary display
/// left of or above the primary one has negative coordinates.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }

    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }

    pub fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.x and y >= r.y and x < r.right() and y < r.bottom();
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.right() and b.x < a.right() and a.y < b.bottom() and b.y < a.bottom();
    }

    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
};

/// One display as the backend enumerates it. Index 0 is the primary display.
pub const Display = struct {
    rect: Rect,
    name: []const u8,
};

/// A captured frame: BGRA, top-down, in desktop orientation (rotation
/// already undone), at the display's physical resolution.
pub const Frame = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    /// True when the frame was acquired by this call, false when the screen
    /// had not changed and the cached frame was returned.
    fresh: bool = true,
    /// Regions updated since the previous capture of this display (desktop
    /// coordinates), for stabilization (US-015).
    dirty: []const Rect = &.{},
    /// Destinations of moved regions since the previous capture.
    moved: []const Rect = &.{},
    /// `gdi`: a BitBlt copy (US-032), always fresh and without dirty rects:
    /// changes are found by comparing fingerprints of successive frames.
    source: Source = .dxgi,
    /// Set when the pixels cover only this desktop rectangle, not the whole
    /// display: a GDI look for changes copies just the target window's area
    /// (US-032). Such a frame is only fingerprinted, never encoded.
    area: ?Rect = null,

    pub const Source = enum { dxgi, gdi };
};

/// Outcome of a capture: the frame, or a message for the model (FR-06).
pub const CaptureResult = union(enum) { frame: Frame, failed: []const u8 };

/// What `window_list` prints about a display besides its geometry (US-026).
pub const DisplayInfo = struct {
    primary: bool,
    /// Effective DPI (96 at 100 % scaling).
    dpi: u32,
    /// Work area (without the taskbar), physical pixels of the desktop.
    work: Rect,
};

/// A visible top-level window, top of the z-order first.
pub const WindowInfo = struct {
    handle: u64,
    title: []const u8,
    exe: []const u8,
    pid: u32,
    rect: Rect,
    elevated: bool,
    minimized: bool,
    cloaked: bool,
    /// Cloaked because it sits on another virtual desktop (US-026), as
    /// IVirtualDesktopManager reports; then `cloaked` is false.
    other_desktop: bool = false,
    /// Nothing of it shows under the windows above it (US-059); filled by
    /// the core.
    occluded: bool = false,
};

pub const FocusResult = enum { ok, closed, refused };

/// Where a top-level window is and what state it is in (US-027).
pub const Placement = struct {
    /// Visible frame (DWMWA_EXTENDED_FRAME_BOUNDS), physical pixels; the
    /// restored frame's position is not reported for a minimized window.
    frame: Rect,
    pid: u32,
    minimized: bool,
    maximized: bool,
    /// Runs at a higher integrity level: UIPI blocks what neo-compute sends.
    elevated: bool,
};

/// Outcome of a window_set primitive: the visible frame obtained.
pub const SetResult = union(enum) { ok: Rect, closed, elevated, hung, failed };

pub const ShowState = enum { normal, minimized, maximized };

/// A top-level window and its process, for the policy (US-017).
pub const WindowRef = struct { handle: u64, pid: u32 };

/// A visible top-level window (not minimized, not cloaked), top of the
/// z-order first. `solid` is false for layered or transparent windows,
/// which may show what lies below them.
pub const VisibleWindow = struct { handle: u64, pid: u32, rect: Rect, solid: bool };

/// A visible top-level window in the z-order (US-059). The windows listed
/// before it are above it.
pub const Layer = struct {
    handle: u64,
    /// Visible frame.
    rect: Rect,
    /// Window rectangle, invisible resize borders included: the one
    /// Chromium reads.
    outer: Rect,
    minimized: bool = false,
    /// It hides what lies under it: not minimized, not click-through, not a
    /// translucent or color-keyed layered window, not shaped by a region.
    solid: bool = true,
    /// Chromium's occlusion tracker counts it as a cover. It ignores popups
    /// and tool windows, the taskbar and its own popups aside
    /// (`native_window_occlusion_tracker_win.cc`).
    counted: bool = true,
    /// A Chromium or Electron window (class `Chrome_WidgetWin_*`): it works
    /// out its own occlusion and stops rendering a page nobody can see.
    chromium: bool = false,
};

/// Whether nothing of `target` shows: each part of it on a display lies
/// under `covers`. A target on no display shows nothing either. When the
/// covers cut it into more pieces than `subtract` follows, it is taken to
/// show.
pub fn hidden(arena: std.mem.Allocator, target: Rect, displays: []const Display, covers: []const Rect) bool {
    var pieces: std.ArrayList(Rect) = .empty;
    for (displays) |d| if (intersection(target, d.rect)) |part| pieces.append(arena, part) catch return false;
    for (covers) |c| {
        if (pieces.items.len == 0) break;
        subtract(arena, &pieces, c) catch return false;
    }
    return pieces.items.len == 0;
}

pub fn intersection(a: Rect, b: Rect) ?Rect {
    if (!a.intersects(b)) return null;
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    return .{ .x = x, .y = y, .w = @min(a.right(), b.right()) - x, .h = @min(a.bottom(), b.bottom()) - y };
}

/// Most pieces `subtract` keeps before giving up.
pub const max_pieces = 64;

/// Replaces `pieces` by their parts outside `cut` (up to four per piece).
pub fn subtract(arena: std.mem.Allocator, pieces: *std.ArrayList(Rect), cut: Rect) !void {
    var out: std.ArrayList(Rect) = .empty;
    for (pieces.items) |r| {
        const c = intersection(r, cut) orelse {
            try out.append(arena, r);
            continue;
        };
        if (c.y > r.y) try out.append(arena, .{ .x = r.x, .y = r.y, .w = r.w, .h = c.y - r.y });
        if (c.bottom() < r.bottom()) try out.append(arena, .{ .x = r.x, .y = c.bottom(), .w = r.w, .h = r.bottom() - c.bottom() });
        if (c.x > r.x) try out.append(arena, .{ .x = r.x, .y = c.y, .w = c.x - r.x, .h = c.h });
        if (c.right() < r.right()) try out.append(arena, .{ .x = c.right(), .y = c.y, .w = r.right() - c.right(), .h = c.h });
    }
    if (out.items.len > max_pieces) return error.TooFragmented;
    pieces.* = out;
}

pub const max_displays = 8;
pub const default_long_side = 1280;
pub const min_long_side = 1024;
pub const max_long_side = 1920;

/// Physical display <-> screenshot pixel mapping. A screenshot pixel covers
/// `scale` physical pixels on each axis.
pub const Mapping = struct {
    display: usize,
    rect: Rect,
    width: u32,
    height: u32,
    scale: f64,

    /// Mapping of `rect` for a screenshot whose long side is at most
    /// `long_side`; smaller displays are never upscaled.
    pub fn of(display: usize, rect: Rect, long_side: u32) Mapping {
        const long: u32 = @intCast(@max(rect.w, rect.h));
        if (long <= long_side) return .{ .display = display, .rect = rect, .width = @intCast(rect.w), .height = @intCast(rect.h), .scale = 1 };
        const scale = @as(f64, @floatFromInt(long)) / @as(f64, @floatFromInt(long_side));
        return .{
            .display = display,
            .rect = rect,
            .width = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(rect.w)) / scale)))),
            .height = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(rect.h)) / scale)))),
            .scale = scale,
        };
    }

    pub fn inBounds(m: Mapping, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < m.width and y < m.height;
    }

    /// Physical desktop pixel at the center of screenshot pixel (x, y).
    pub fn toPhysical(m: Mapping, x: i32, y: i32) [2]i32 {
        return .{
            m.rect.x + axisToPhysical(x, m.scale, m.rect.w),
            m.rect.y + axisToPhysical(y, m.scale, m.rect.h),
        };
    }

    /// Screenshot pixel containing the physical desktop pixel (px, py).
    /// Points outside the display map outside the screenshot bounds.
    pub fn toScreenshot(m: Mapping, px: i32, py: i32) [2]i32 {
        return .{
            @intFromFloat(@floor(@as(f64, @floatFromInt(px - m.rect.x)) / m.scale)),
            @intFromFloat(@floor(@as(f64, @floatFromInt(py - m.rect.y)) / m.scale)),
        };
    }

    /// Physical rectangle (relative to the display origin) covered by the
    /// screenshot region [x0, x1) x [y0, y1).
    pub fn regionToPhysical(m: Mapping, x0: i32, y0: i32, x1: i32, y1: i32) Rect {
        const px0 = edgeToPhysical(x0, m.scale, m.rect.w);
        const py0 = edgeToPhysical(y0, m.scale, m.rect.h);
        const px1 = edgeToPhysical(x1, m.scale, m.rect.w);
        const py1 = edgeToPhysical(y1, m.scale, m.rect.h);
        return .{ .x = px0, .y = py0, .w = @max(1, px1 - px0), .h = @max(1, py1 - py0) };
    }

    /// Screenshot-space rectangle of a physical desktop rectangle.
    pub fn rectToScreenshot(m: Mapping, r: Rect) Rect {
        const a = m.toScreenshot(r.x, r.y);
        const x1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.right() - m.rect.x)) / m.scale));
        const y1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.bottom() - m.rect.y)) / m.scale));
        return .{ .x = a[0], .y = a[1], .w = x1 - a[0], .h = y1 - a[1] };
    }
};

fn axisToPhysical(v: i32, scale: f64, extent: i32) i32 {
    const p: i32 = @intFromFloat(@floor((@as(f64, @floatFromInt(v)) + 0.5) * scale));
    return std.math.clamp(p, 0, extent - 1);
}

fn edgeToPhysical(v: i32, scale: f64, extent: i32) i32 {
    const p: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(v)) * scale));
    return std.math.clamp(p, 0, extent);
}

/// Scale factor without trailing zeros (2, 1.5, 1.333).
pub fn scaleText(buf: []u8, scale: f64) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d:.3}", .{scale}) catch return "?";
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

/// Index of the display containing (x, y), else the one nearest to it.
pub fn displayAt(displays: []const Display, x: i32, y: i32) ?usize {
    var best: ?usize = null;
    var best_d: i64 = std.math.maxInt(i64);
    for (displays, 0..) |d, i| {
        if (d.rect.contains(x, y)) return i;
        const dx: i64 = if (x < d.rect.x) d.rect.x - x else if (x >= d.rect.right()) x - d.rect.right() + 1 else 0;
        const dy: i64 = if (y < d.rect.y) d.rect.y - y else if (y >= d.rect.bottom()) y - d.rect.bottom() + 1 else 0;
        const dist = dx * dx + dy * dy;
        if (dist < best_d) {
            best_d = dist;
            best = i;
        }
    }
    return best;
}

test "mapping keeps the ratio, never upscales and stays within 1 px at scales up to 2" {
    const m = Mapping.of(0, .{ .x = 0, .y = 0, .w = 2560, .h = 1440 }, 1280);
    try std.testing.expectEqual(@as(u32, 1280), m.width);
    try std.testing.expectEqual(@as(u32, 720), m.height);
    try std.testing.expectEqual(@as(f64, 2), m.scale);
    const small = Mapping.of(1, .{ .x = -1024, .y = 0, .w = 1024, .h = 768 }, 1280);
    try std.testing.expectEqual(@as(f64, 1), small.scale);
    try std.testing.expectEqual(@as(u32, 1024), small.width);

    // Physical -> screenshot -> physical lands within ceil(scale / 2) px,
    // i.e. 1 px for the 100 %, 125 %, 150 % and 200 % ratios.
    for ([_][2]i32{ .{ 1280, 720 }, .{ 1600, 900 }, .{ 1920, 1080 }, .{ 2560, 1440 } }) |size| {
        const r: Rect = .{ .x = -size[0], .y = -37, .w = size[0], .h = size[1] };
        const mm = Mapping.of(0, r, 1280);
        var px = r.x;
        while (px < r.right()) : (px += 7) {
            const s = mm.toScreenshot(px, r.y + 5);
            try std.testing.expect(mm.inBounds(s[0], s[1]));
            const back = mm.toPhysical(s[0], s[1]);
            try std.testing.expect(@abs(back[0] - px) <= 1);
        }
    }
}

test "subtract keeps the parts of a rectangle outside the cut" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var pieces: std.ArrayList(Rect) = .empty;
    try pieces.append(arena.allocator(), .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try subtract(arena.allocator(), &pieces, .{ .x = 25, .y = 25, .w = 50, .h = 50 });
    var area: i64 = 0;
    for (pieces.items) |r| area += @as(i64, r.w) * r.h;
    try std.testing.expectEqual(@as(i64, 100 * 100 - 50 * 50), area);
    try subtract(arena.allocator(), &pieces, .{ .x = -10, .y = -10, .w = 200, .h = 200 });
    try std.testing.expectEqual(@as(usize, 0), pieces.items.len);
}

test "displayAt picks the containing display, else the nearest" {
    const ds = [_]Display{
        .{ .rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1440 }, .name = "a" },
        .{ .rect = .{ .x = -1920, .y = 200, .w = 1920, .h = 1080 }, .name = "b" },
    };
    try std.testing.expectEqual(@as(?usize, 1), displayAt(&ds, -5, 300));
    try std.testing.expectEqual(@as(?usize, 0), displayAt(&ds, 3000, 10));
}
