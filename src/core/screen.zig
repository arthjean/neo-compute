//! Screenshot and zoom, and the mapping of incoming screenshot coordinates
//! to physical desktop pixels (FR-03). Backend-independent: the backend
//! only enumerates displays and returns BGRA frames. With a window
//! (US-061) the image is that window alone, as the backend captures it
//! whatever covers it: the background mode's only image, never the screen.

const std = @import("std");
const display = @import("display.zig");
const jpeg = @import("jpeg.zig");
const Result = @import("mcp.zig").Result;
const fmt = @import("session.zig").fmt;
const policy = @import("policy.zig");
const marks = @import("marks.zig");
const windowctl = @import("windowctl.zig");
const Mapping = display.Mapping;

/// Longest side of a `zoom` image (US-007).
pub const zoom_long_side = 1280;

pub const Physical = union(enum) { ok: [2]i32, err: []const u8 };
pub const Target = union(enum) { ok: Mapping, err: []const u8 };

/// Mapping that incoming coordinates refer to: the display of the latest
/// screenshot, else the one a screenshot would capture now.
pub fn targetMapping(ctx: anytype) Target {
    const displays = ctx.backend.displays();
    const index = ctx.session.current orelse ctx.backend.foregroundDisplay() orelse 0;
    return switch (ctx.session.resolve(ctx.arena, displays, index)) {
        .ok => |m| .{ .ok = m },
        .err => |e| .{ .err = e },
    };
}

/// Physical desktop pixel of screenshot coordinate `c`, or the error that
/// names the valid bounds (no input is sent on error).
pub fn toPhysical(ctx: anytype, c: [2]i32) Physical {
    const m = switch (targetMapping(ctx)) {
        .ok => |m| m,
        .err => |e| return .{ .err = e },
    };
    if (!m.inBounds(c[0], c[1]))
        return .{ .err = fmt(ctx.arena, "Coordonnée hors écran ({d}, {d}) : bornes valides 0..{d} x 0..{d} de l'écran {d}. Aucune action exécutée.", .{ c[0], c[1], m.width - 1, m.height - 1, m.display }) };
    return .{ .ok = m.toPhysical(c[0], c[1]) };
}

fn frameOf(ctx: anytype, m: Mapping) union(enum) { ok: display.Frame, err: []const u8 } {
    ctx.timings.start(ctx.io, .capture);
    const cap = ctx.backend.capture(m.display, ctx.arena);
    ctx.timings.stop(ctx.io, .capture);
    const frame = switch (cap) {
        .frame => |f| f,
        .failed => |msg| return .{ .err = msg },
    };
    if (frame.width != m.rect.w or frame.height != m.rect.h) {
        ctx.session.forget(m.display);
        return .{ .err = fmt(ctx.arena, "Écran {d} modifié pendant la capture ({d}x{d} au lieu de {d}x{d}) : refais un screenshot.", .{ m.display, frame.width, frame.height, m.rect.w, m.rect.h }) };
    }
    return .{ .ok = frame };
}

/// Paints `rects` (physical desktop pixels) black in `pixels`, the w x h
/// reduction of `region` (physical, relative to `origin`, the display's
/// top-left). Edges round outward so no masked pixel survives the reduction.
pub fn blackOut(pixels: []u8, w: u32, h: u32, region: display.Rect, origin: [2]i32, rects: []const display.Rect) void {
    const sx = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(region.w));
    const sy = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(region.h));
    for (rects) |r| {
        const rx: f64 = @floatFromInt(r.x - origin[0] - region.x);
        const ry: f64 = @floatFromInt(r.y - origin[1] - region.y);
        const x0: usize = @intFromFloat(std.math.clamp(@floor(rx * sx), 0, @as(f64, @floatFromInt(w))));
        const y0: usize = @intFromFloat(std.math.clamp(@floor(ry * sy), 0, @as(f64, @floatFromInt(h))));
        const x1: usize = @intFromFloat(std.math.clamp(@ceil((rx + @as(f64, @floatFromInt(r.w))) * sx), 0, @as(f64, @floatFromInt(w))));
        const y1: usize = @intFromFloat(std.math.clamp(@ceil((ry + @as(f64, @floatFromInt(r.h))) * sy), 0, @as(f64, @floatFromInt(h))));
        if (x1 <= x0) continue;
        for (y0..y1) |y| {
            const row = pixels[(y * w + x0) * 4 ..][0 .. (x1 - x0) * 4];
            for (0..x1 - x0) |i| row[i * 4 ..][0..4].* = .{ 0, 0, 0, 255 };
        }
    }
}

/// What a marked screenshot adds to the image (US-031): password fields the
/// snapshot read, blacked out with the scanned ones, then the labels.
const Overlay = struct {
    secrets: []const display.Rect = &.{},
    /// The foreground window's password scan ran (US-019); without it the
    /// snapshot's own password fields are the foreground's.
    scanned: bool = true,
    labels: []const marks.Label = &.{},
    /// Labels drawn, from `marks.layout`.
    drawn: usize = 0,
    /// The image is one window's own (US-061): no other window is in it,
    /// so no `deny` window is blacked out of it.
    window: bool = false,
};

/// Reduces `region` of `frame` (display `m`) to w x h, blacks out the
/// `deny` windows (US-017) and the visible password fields (US-019, the
/// scan started before the capture), draws the overlay's labels over the
/// masked image (US-031), encodes it as JPEG and fills the image block of
/// `r`.
fn encodeImage(ctx: anytype, r: *Result, m: Mapping, frame: display.Frame, region: display.Rect, w: u32, h: u32, quality: u8, overlay: ?*Overlay) ?[]const u8 {
    std.debug.assert(@max(w, h) <= display.max_long_side); // FR-17
    const s = ctx.session;
    const origin = [2]i32{ m.rect.x, m.rect.y };
    const own = if (overlay) |o| o.window else false;
    const denied: []const display.Rect = if (own) &.{} else policy.deniedRects(ctx, .{ .x = origin[0] + region.x, .y = origin[1] + region.y, .w = region.w, .h = region.h });
    ctx.timings.start(ctx.io, .reduce);
    _ = s.reducer.reduce(s.gpa, frame.pixels, frame.stride, region, w, h) catch {
        ctx.timings.stop(ctx.io, .reduce);
        return "Mémoire insuffisante pour réduire l'image : réessaie.";
    };
    ctx.timings.stop(ctx.io, .reduce);
    const reduced = s.reducer.out[0 .. @as(usize, w) * h * 4];
    ctx.timings.start(ctx.io, .mask);
    const secrets = if (overlay) |o| (if (o.scanned) ctx.backend.secretRects() else &.{}) else ctx.backend.secretRects();
    blackOut(reduced, w, h, region, origin, denied);
    blackOut(reduced, w, h, region, origin, secrets);
    if (overlay) |o| blackOut(reduced, w, h, region, origin, o.secrets);
    ctx.timings.stop(ctx.io, .mask);
    if (overlay) |o| if (o.labels.len > 0) {
        ctx.timings.start(ctx.io, .marks);
        defer ctx.timings.stop(ctx.io, .marks);
        const at = ctx.arena.alloc(?display.Rect, o.labels.len) catch return "Mémoire insuffisante : réessaie.";
        o.drawn = marks.layout(o.labels, w, h, at);
        for (o.labels, at) |*l, place| if (place) |p| marks.draw(reduced, w, l, p);
    };
    ctx.timings.start(ctx.io, .encode);
    defer ctx.timings.stop(ctx.io, .encode);
    const bytes = s.encoder.encode(s.gpa, reduced, w, h, @as(usize, w) * 4, quality) catch
        return "Encodage JPEG impossible : réessaie (détail sur stderr).";
    const b64 = ctx.arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len)) catch
        return "Mémoire insuffisante pour l'image : réessaie.";
    _ = std.base64.standard.Encoder.encode(b64, bytes);
    r.blocks[0] = .{ .image = .{ .data_base64 = b64, .mime = "image/jpeg", .width = w, .height = h } };
    return null;
}

pub fn screenshot(ctx: anytype, display_arg: ?u32) Result {
    const displays = ctx.backend.displays();
    if (displays.len == 0) return Result.err("Aucun écran détecté : vérifie qu'un écran est allumé, puis réessaie.");
    const index: usize = display_arg orelse ctx.backend.foregroundDisplay() orelse 0;
    if (index >= displays.len or index >= display.max_displays)
        return Result.err(fmt(ctx.arena, "Écran {d} inexistant : écrans valides 0..{d}.", .{ index, displays.len - 1 }));
    const m = Mapping.of(index, displays[index].rect, ctx.session.long_side);
    // The password scan runs on the accessibility worker during capture
    // and reduction.
    ctx.backend.beginSecretScan(null);
    const frame = switch (frameOf(ctx, m)) {
        .ok => |f| f,
        .err => |e| return Result.err(e),
    };
    var r: Result = .{ .len = 2 };
    const full: display.Rect = .{ .x = 0, .y = 0, .w = m.rect.w, .h = m.rect.h };
    if (encodeImage(ctx, &r, m, frame, full, m.width, m.height, jpeg.screenshot_quality, null)) |e| return Result.err(e);
    ctx.session.recordShot(m);
    var sbuf: [32]u8 = undefined;
    r.blocks[1] = .{ .text = fmt(ctx.arena, "display={d} scale={s} size={d}x{d}{s}", .{ index, display.scaleText(&sbuf, m.scale), m.width, m.height, gdiNote(frame) }) };
    return r;
}

pub fn zoom(ctx: anytype, region: [4]i32) Result {
    const m = switch (targetMapping(ctx)) {
        .ok => |m| m,
        .err => |e| return Result.err(e),
    };
    const x0, const y0, const x1, const y1 = region;
    if (x0 < 0 or y0 < 0 or x1 > m.width or y1 > m.height or x0 >= x1 or y0 >= y1)
        return Result.err(fmt(ctx.arena, "Région [{d}, {d}, {d}, {d}] invalide (inversée, vide ou hors écran) : bornes valides 0..{d} x 0..{d} avec x0 < x1 et y0 < y1.", .{ x0, y0, x1, y1, m.width, m.height }));
    const phys = m.regionToPhysical(x0, y0, x1, y1);
    ctx.backend.beginSecretScan(null);
    const frame = switch (frameOf(ctx, m)) {
        .ok => |f| f,
        .err => |e| return Result.err(e),
    };
    const w, const h = zoomSize(phys);
    var r: Result = .{ .len = 2 };
    if (encodeImage(ctx, &r, m, frame, phys, w, h, jpeg.zoom_quality, null)) |e| return Result.err(e);
    r.blocks[1] = .{ .text = fmt(ctx.arena, "display={d} region={d},{d},{d},{d} size={d}x{d}{s}", .{ m.display, x0, y0, x1, y1, w, h, gdiNote(frame) }) };
    return r;
}

/// Size of the image of physical region `phys`: its own resolution, the
/// long side capped at zoom_long_side.
fn zoomSize(phys: display.Rect) struct { u32, u32 } {
    const pw: u32 = @intCast(phys.w);
    const ph: u32 = @intCast(phys.h);
    const long = @max(pw, ph);
    if (long <= zoom_long_side) return .{ pw, ph };
    const k = @as(f64, @floatFromInt(long)) / zoom_long_side;
    return .{
        @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(pw)) / k)))),
        @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(ph)) / k)))),
    };
}

// ---------------------------------------------------------------- one window (US-061)

pub const window_closed = "Fenêtre fermée : rappelle window_list";
pub const window_minimized = "Fenêtre minimisée : restaure-la avec window_set (state normal) avant la capture.";

/// One window captured: its frame, the mapping of its image and of the
/// display it sits on, and its password fields.
const WindowShot = struct {
    frame: display.Frame,
    map: Mapping,
    on: Mapping,
    secrets: []const display.Rect,
};

const Captured = union(enum) { ok: WindowShot, err: []const u8 };

/// Whether every pixel of the frame is black: what a window that does not
/// let itself be captured off screen gives.
fn blank(frame: display.Frame) bool {
    for (0..frame.height) |y| {
        const row = frame.pixels[y * frame.stride ..][0 .. @as(usize, frame.width) * 4];
        var x: usize = 0;
        while (x < row.len) : (x += 4) if (row[x] != 0 or row[x + 1] != 0 or row[x + 2] != 0) return false;
    }
    return true;
}

fn exeOf(ctx: anytype, window: u64) []const u8 {
    const ref = ctx.backend.windowRef(window) orelse return "l'application";
    return ctx.arena.dupe(u8, policy.resolve(ctx, ref).exe()) catch "l'application";
}

/// Captures `window` alone. A `deny` application is refused by the policy
/// (US-017); a minimized window, one that does not answer and one that
/// comes back black each say so, with nothing shown. The password scan of
/// the window runs on the accessibility worker during the capture (FR-09).
fn captureWindow(ctx: anytype, window: u64) Captured {
    if (policy.requireWindow(ctx, window, .observe)) |r| return .{ .err = r.blocks[0].text };
    const displays = ctx.backend.displays();
    if (displays.len == 0) return .{ .err = "Aucun écran détecté : vérifie qu'un écran est allumé, puis réessaie." };
    ctx.backend.beginSecretScan(window);
    ctx.timings.start(ctx.io, .capture);
    const cap = ctx.backend.captureWindow(window);
    ctx.timings.stop(ctx.io, .capture);
    const got = switch (cap) {
        .ok => |g| g,
        .closed => return .{ .err = window_closed },
        .minimized => return .{ .err = window_minimized },
        .hung => return .{ .err = windowctl.hungText(ctx, window) },
        .scaled => return .{ .err = fmt(ctx.arena, "Capture indisponible : Windows met {s} à l'échelle (application qui ne suit pas le DPI de son écran), son image ne correspondrait à aucun rectangle. Utilise ui_tree.", .{exeOf(ctx, window)}) },
        .failed => return .{ .err = fmt(ctx.arena, "Capture de la fenêtre 0x{x} impossible : réessaie, ou utilise ui_tree.", .{window}) },
    };
    if (blank(got.frame)) return .{ .err = fmt(ctx.arena, "Capture noire : {s} ne se laisse pas capturer hors de l'écran. Utilise ui_tree.", .{exeOf(ctx, window)}) };
    const r = got.rect;
    const index = @min(display.displayAt(displays, r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h, 2)) orelse 0, display.max_displays - 1, displays.len - 1);
    const on = Mapping.of(index, displays[index].rect, ctx.session.long_side);
    const secrets = ctx.backend.secretRects();
    // An image leaves only with every password field of its window masked
    // (FR-09): a scan that cannot vouch for them all refuses it. A
    // screenshot of the screen keeps the rule of decision 0007.
    switch (ctx.backend.secretScan()) {
        .ok => {},
        .elevated => return .{ .err = fmt(ctx.arena, "Capture indisponible : {s} s'exécute avec des droits élevés, ses champs mot de passe ne peuvent pas être lus pour être masqués. Relance l'application sans élévation, ou agis toi-même.", .{exeOf(ctx, window)}) },
        .failed => return .{ .err = fmt(ctx.arena, "Capture indisponible : les champs mot de passe de {s} n'ont pas pu être lus, l'image ne peut pas être masquée. Réessaie, ou utilise ui_tree.", .{exeOf(ctx, window)}) },
    }
    // The scan masks the whole window when a Chromium web tree is not
    // built: its password fields are in the image, and nothing says where.
    for (secrets) |s| if (s.x <= r.x and s.y <= r.y and s.right() >= r.right() and s.bottom() >= r.bottom())
        return .{ .err = fmt(ctx.arena, "Capture indisponible : l'arbre web de {s} n'est pas construit, ses champs mot de passe ne peuvent pas être masqués. Si la fenêtre est recouverte, laisse une bande d'au moins 16 px visible avec window_set, puis réessaie ; sinon réessaie dans un instant.", .{exeOf(ctx, window)}) };
    return .{ .ok = .{ .frame = got.frame, .map = display.windowMapping(on, r, ctx.session.long_side), .on = on, .secrets = secrets } };
}

/// `window=<handle> size=<w>x<h> scale=<s> origin=<x>,<y> display=<n>`:
/// the origin is the image's top-left corner in the pixels `ui_tree` gives
/// for that display, so an image pixel plus the origin is a tree
/// coordinate (at the display's scale).
fn windowText(ctx: anytype, window: u64, s: WindowShot) []const u8 {
    var sbuf: [32]u8 = undefined;
    const origin = s.on.toScreenshot(s.map.rect.x, s.map.rect.y);
    return fmt(ctx.arena, "window=0x{x} size={d}x{d} scale={s} origin={d},{d} display={d}", .{ window, s.map.width, s.map.height, display.scaleText(&sbuf, s.map.scale), origin[0], origin[1], s.on.display });
}

fn remember(ctx: anytype, window: u64, s: WindowShot) void {
    ctx.session.window_shot = .{ .window = window, .w = s.map.rect.w, .h = s.map.rect.h };
}

/// `screenshot` of one window (US-061): its image alone, password fields
/// blacked out, with what relates a pixel to a rectangle of `ui_tree`.
/// `note` follows that line.
pub fn screenshotWindow(ctx: anytype, window: u64, note: []const u8) Result {
    const s = switch (captureWindow(ctx, window)) {
        .ok => |s| s,
        .err => |e| return Result.err(e),
    };
    var r: Result = .{ .len = 2 };
    var overlay: Overlay = .{ .window = true, .scanned = false, .secrets = s.secrets };
    const full: display.Rect = .{ .x = 0, .y = 0, .w = s.map.rect.w, .h = s.map.rect.h };
    if (encodeImage(ctx, &r, s.map, s.frame, full, s.map.width, s.map.height, jpeg.screenshot_quality, &overlay)) |e| return Result.err(e);
    remember(ctx, window, s);
    r.blocks[1] = .{ .text = fmt(ctx.arena, "{s}{s}", .{ windowText(ctx, window, s), note }) };
    return r;
}

/// `zoom` in one window's image (US-061): `region` in the pixels of that
/// window's screenshot, at the window's own resolution.
pub fn zoomWindow(ctx: anytype, window: u64, region: [4]i32, note: []const u8) Result {
    const s = switch (captureWindow(ctx, window)) {
        .ok => |s| s,
        .err => |e| return Result.err(e),
    };
    const m = s.map;
    // A region read on an image of another size would land elsewhere.
    if (ctx.session.window_shot) |last| if (last.window == window and (last.w != m.rect.w or last.h != m.rect.h)) {
        ctx.session.window_shot = null;
        return Result.err(fmt(ctx.arena, "Fenêtre 0x{x} redimensionnée depuis son screenshot ({d}x{d} au lieu de {d}x{d}) : refais un screenshot.", .{ window, m.rect.w, m.rect.h, last.w, last.h }));
    };
    const x0, const y0, const x1, const y1 = region;
    if (x0 < 0 or y0 < 0 or x1 > m.width or y1 > m.height or x0 >= x1 or y0 >= y1)
        return Result.err(fmt(ctx.arena, "Région [{d}, {d}, {d}, {d}] invalide (inversée, vide ou hors de l'image de la fenêtre) : bornes valides 0..{d} x 0..{d} avec x0 < x1 et y0 < y1.", .{ x0, y0, x1, y1, m.width, m.height }));
    const phys = m.regionToPhysical(x0, y0, x1, y1);
    const w, const h = zoomSize(phys);
    var r: Result = .{ .len = 2 };
    var overlay: Overlay = .{ .window = true, .scanned = false, .secrets = s.secrets };
    if (encodeImage(ctx, &r, m, s.frame, phys, w, h, jpeg.zoom_quality, &overlay)) |e| return Result.err(e);
    r.blocks[1] = .{ .text = fmt(ctx.arena, "window=0x{x} region={d},{d},{d},{d} size={d}x{d}{s}", .{ window, x0, y0, x1, y1, w, h, note }) };
    return r;
}

/// What an image says once captured through GDI (US-032).
pub const gdi_note = "Capture GDI : les fenêtres protégées contre la capture apparaissent en noir";

fn gdiNote(frame: display.Frame) []const u8 {
    return if (frame.source == .gdi) " ; " ++ gdi_note else "";
}

/// An element to mark: its id and its rectangle, physical desktop pixels.
pub const Mark = struct { id: u32, rect: display.Rect };

pub const Marked = union(enum) {
    ok: struct {
        image: @import("mcp.zig").Content,
        /// Labels the image had room for, of `total` elements in it.
        drawn: usize,
        total: usize,
        gdi: bool = false,
        /// What relates a pixel of a window's image to the tree.
        note: []const u8 = "",
    },
    err: []const u8,
};

/// One label per element of `list` that shows in the image `m` maps.
fn labelsOf(ctx: anytype, m: Mapping, list: []const Mark) ?[]const marks.Label {
    const out = ctx.arena.alloc(marks.Label, list.len) catch return null;
    var n: usize = 0;
    for (list) |mark| {
        if (!mark.rect.intersects(m.rect)) continue;
        out[n] = marks.Label.of(mark.id, m.rectToScreenshot(mark.rect));
        n += 1;
    }
    return out[0..n];
}

/// The screenshot of display `m` (format and scale of `screenshot`, FR-17)
/// with the id of each element of `list` drawn after the masking of `deny`
/// windows and password fields, `secrets` among them (US-031). Its space
/// becomes the one of incoming coordinates and of `zoom`. With `scan`
/// false, `secrets` already hold the foreground window's password fields
/// (its complete snapshot), and the scan of US-019 is not run again.
pub fn marked(ctx: anytype, m: Mapping, list: []const Mark, secrets: []const display.Rect, scan: bool) Marked {
    const labels = labelsOf(ctx, m, list) orelse return .{ .err = "Mémoire insuffisante : réessaie." };
    if (scan) ctx.backend.beginSecretScan(null);
    const frame = switch (frameOf(ctx, m)) {
        .ok => |f| f,
        .err => |e| return .{ .err = e },
    };
    var r: Result = .{ .len = 1 };
    var overlay: Overlay = .{ .secrets = secrets, .labels = labels, .scanned = scan };
    const full: display.Rect = .{ .x = 0, .y = 0, .w = m.rect.w, .h = m.rect.h };
    if (encodeImage(ctx, &r, m, frame, full, m.width, m.height, jpeg.screenshot_quality, &overlay)) |e| return .{ .err = e };
    ctx.session.recordShot(m);
    return .{ .ok = .{ .image = r.blocks[0], .drawn = overlay.drawn, .total = labels.len, .gdi = frame.source == .gdi } };
}

/// `marked` on the image of one window (US-061): what the background mode
/// draws the ids on. `secrets`: the password fields the snapshot read,
/// masked with those the window's own scan finds.
pub fn markedWindow(ctx: anytype, window: u64, list: []const Mark, secrets: []const display.Rect) Marked {
    const s = switch (captureWindow(ctx, window)) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    const labels = labelsOf(ctx, s.map, list) orelse return .{ .err = "Mémoire insuffisante : réessaie." };
    const all = std.mem.concat(ctx.arena, display.Rect, &.{ s.secrets, secrets }) catch return .{ .err = "Mémoire insuffisante : réessaie." };
    var r: Result = .{ .len = 1 };
    var overlay: Overlay = .{ .window = true, .scanned = false, .secrets = all, .labels = labels };
    const full: display.Rect = .{ .x = 0, .y = 0, .w = s.map.rect.w, .h = s.map.rect.h };
    if (encodeImage(ctx, &r, s.map, s.frame, full, s.map.width, s.map.height, jpeg.screenshot_quality, &overlay)) |e| return .{ .err = e };
    remember(ctx, window, s);
    return .{ .ok = .{ .image = r.blocks[0], .drawn = overlay.drawn, .total = labels.len, .note = windowText(ctx, window, s) } };
}
