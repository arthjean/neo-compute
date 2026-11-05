//! Screenshot and zoom, and the mapping of incoming screenshot coordinates
//! to physical desktop pixels (FR-03). Backend-independent: the backend
//! only enumerates displays and returns BGRA frames.

const std = @import("std");
const display = @import("display.zig");
const jpeg = @import("jpeg.zig");
const Result = @import("mcp.zig").Result;
const fmt = @import("session.zig").fmt;
const policy = @import("policy.zig");
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

/// Reduces `region` of `frame` (display `m`) to w x h, blacks out the
/// `deny` windows (US-017) and the visible password fields (US-019, the
/// scan started before the capture), encodes it as JPEG and fills the image
/// block of `r`.
fn encodeImage(ctx: anytype, r: *Result, m: Mapping, frame: display.Frame, region: display.Rect, w: u32, h: u32, quality: u8) ?[]const u8 {
    std.debug.assert(@max(w, h) <= display.max_long_side); // FR-17
    const s = ctx.session;
    const origin = [2]i32{ m.rect.x, m.rect.y };
    const denied = policy.deniedRects(ctx, .{ .x = origin[0] + region.x, .y = origin[1] + region.y, .w = region.w, .h = region.h });
    ctx.timings.start(ctx.io, .reduce);
    _ = s.reducer.reduce(s.gpa, frame.pixels, frame.stride, region, w, h) catch {
        ctx.timings.stop(ctx.io, .reduce);
        return "Mémoire insuffisante pour réduire l'image : réessaie.";
    };
    ctx.timings.stop(ctx.io, .reduce);
    const reduced = s.reducer.out[0 .. @as(usize, w) * h * 4];
    ctx.timings.start(ctx.io, .mask);
    const secrets = ctx.backend.secretRects();
    blackOut(reduced, w, h, region, origin, denied);
    blackOut(reduced, w, h, region, origin, secrets);
    ctx.timings.stop(ctx.io, .mask);
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
    ctx.backend.beginSecretScan();
    const frame = switch (frameOf(ctx, m)) {
        .ok => |f| f,
        .err => |e| return Result.err(e),
    };
    var r: Result = .{ .len = 2 };
    const full: display.Rect = .{ .x = 0, .y = 0, .w = m.rect.w, .h = m.rect.h };
    if (encodeImage(ctx, &r, m, frame, full, m.width, m.height, jpeg.screenshot_quality)) |e| return Result.err(e);
    ctx.session.recordShot(m);
    var sbuf: [32]u8 = undefined;
    r.blocks[1] = .{ .text = fmt(ctx.arena, "display={d} scale={s} size={d}x{d}", .{ index, display.scaleText(&sbuf, m.scale), m.width, m.height }) };
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
    ctx.backend.beginSecretScan();
    const frame = switch (frameOf(ctx, m)) {
        .ok => |f| f,
        .err => |e| return Result.err(e),
    };
    // Physical resolution, the long side capped at zoom_long_side.
    const pw: u32 = @intCast(phys.w);
    const ph: u32 = @intCast(phys.h);
    const long = @max(pw, ph);
    var w = pw;
    var h = ph;
    if (long > zoom_long_side) {
        const k = @as(f64, @floatFromInt(long)) / zoom_long_side;
        w = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(pw)) / k))));
        h = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(ph)) / k))));
    }
    var r: Result = .{ .len = 2 };
    if (encodeImage(ctx, &r, m, frame, phys, w, h, jpeg.zoom_quality)) |e| return Result.err(e);
    r.blocks[1] = .{ .text = fmt(ctx.arena, "display={d} region={d},{d},{d},{d} size={d}x{d}", .{ m.display, x0, y0, x1, y1, w, h }) };
    return r;
}
