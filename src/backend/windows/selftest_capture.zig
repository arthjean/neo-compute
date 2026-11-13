//! The visual pass (EP-015) in `neo-compute selftest --background`: the
//! `bg-capture*` controls run `screenshot`, `zoom` and `ui_tree` marks
//! through the dispatcher of the background server on the test window,
//! entirely under the decoy. Each reads the image the tool encoded (the
//! reduced pixels, before JPEG) against what Win32 says of the window, and
//! requires an unchanged session (foreground, keyboard focus, cursor,
//! clipboard, no injected event).

const std = @import("std");
const w = @import("win32");
const display = @import("../../core/display.zig");
const test_window = @import("test_window.zig");
const window = @import("window.zig");
const selftest = @import("selftest.zig");
const bg = @import("selftest_background.zig");
const Bench = bg.Bench;
const Windows = @import("../windows.zig").Windows;

const qpcUs = selftest.qpcUs;

/// How long the test window's thread stops for `bg-capture-hung`.
const hang_ms = 1500;
/// A capture of a window that does not answer returns within this: the
/// 200 ms check and the dispatcher, never the hang.
const hung_budget_us = 600_000;

/// `window=<handle> size=<w>x<h> scale=<s> origin=<x>,<y> display=<n>`.
const Info = struct {
    handle: u64,
    width: u32,
    height: u32,
    scale: f64,
    origin: [2]i32,

    fn parse(text: []const u8) ?Info {
        const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        var out: Info = undefined;
        var seen: u8 = 0;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |tok| {
            const eq = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
            const key = tok[0..eq];
            const val = tok[eq + 1 ..];
            if (std.mem.eql(u8, key, "window")) {
                out.handle = std.fmt.parseInt(u64, std.mem.trimStart(u8, val, "0x"), 16) catch return null;
                seen |= 1;
            } else if (std.mem.eql(u8, key, "size")) {
                const x = std.mem.indexOfScalar(u8, val, 'x') orelse return null;
                out.width = std.fmt.parseInt(u32, val[0..x], 10) catch return null;
                out.height = std.fmt.parseInt(u32, val[x + 1 ..], 10) catch return null;
                seen |= 2;
            } else if (std.mem.eql(u8, key, "scale")) {
                out.scale = std.fmt.parseFloat(f64, val) catch return null;
                seen |= 4;
            } else if (std.mem.eql(u8, key, "origin")) {
                const c = std.mem.indexOfScalar(u8, val, ',') orelse return null;
                out.origin = .{ std.fmt.parseInt(i32, val[0..c], 10) catch return null, std.fmt.parseInt(i32, val[c + 1 ..], 10) catch return null };
                seen |= 8;
            }
        }
        return if (seen == 15) out else null;
    }
};

/// The image the last tool call encoded: the server's reduced pixels.
const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    /// Physical pixels per image pixel, and the window's frame.
    scale: f64,
    frame: display.Rect,

    fn of(b: *Bench, width: u32, height: u32, scale: f64, frame: display.Rect) ?Image {
        const out = b.caller.server.session.reducer.out;
        const n = @as(usize, width) * height * 4;
        if (out.len < n) return null;
        return .{ .pixels = out[0..n], .width = width, .height = height, .scale = scale, .frame = frame };
    }

    /// The pixel that shows physical desktop point (x, y).
    fn at(self: Image, x: i32, y: i32) ?[3]u8 {
        const ix: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(x - self.frame.x)) / self.scale));
        const iy: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(y - self.frame.y)) / self.scale));
        if (ix < 0 or iy < 0 or ix >= self.width or iy >= self.height) return null;
        const i = (@as(usize, @intCast(iy)) * self.width + @as(usize, @intCast(ix))) * 4;
        return self.pixels[i..][0..3].*;
    }
};

fn isMagenta(px: ?[3]u8) bool {
    const p = px orelse return false;
    return p[0] == 0xFF and p[1] == 0x00 and p[2] == 0xFF;
}

fn isBlack(px: ?[3]u8) bool {
    const p = px orelse return false;
    return p[0] == 0 and p[1] == 0 and p[2] == 0;
}

fn rectOf(hwnd: w.HWND) display.Rect {
    var r: w.RECT = undefined;
    _ = w.GetWindowRect(hwnd, &r);
    return .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
}

/// Runs the EP-015 controls. True when the decoy lost the foreground to
/// something else than the server: the run cannot judge any further.
pub fn run(b: *Bench, backend: *Windows, arena: std.mem.Allocator) !bool {
    controls(b, backend, arena) catch |err| switch (err) {
        error.DecoyLost => return true,
        else => return err,
    };
    return false;
}

fn controls(b: *Bench, backend: *Windows, arena: std.mem.Allocator) !void {
    _ = arena;
    const tw = b.tw;
    // The session's target, named once: the calls below pass no window.
    const named = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{b.hwnd});
    if (named.is_error) return b.report.fail("bg-capture", "the target's tree cannot be read: {s}", .{named.text});
    const first = b.begin() orelse return error.DecoyLost;
    _ = first;
    if (!b.decoy.covers(tw.window())) return b.report.fail("bg-capture", "the test window does not lie entirely under the decoy", .{});
    const frame = window.rect(tw.window()) orelse return b.report.fail("bg-capture", "the test window has no rectangle", .{});
    const field = rectOf(tw.passwordWindow());
    const button = rectOf(tw.buttonWindow());

    // bg-capture: the covered window's own pixels, the session unchanged.
    var shot: Image = undefined;
    {
        const before = b.begin() orelse return error.DecoyLost;
        const t0 = qpcUs();
        const res = try b.caller.call("screenshot", "{{}}", .{});
        const us = qpcUs() - t0;
        const v = b.end(before);
        var buf: [96]u8 = undefined;
        if (res.is_error or res.image_mime == null) return b.report.fail("bg-capture", "screenshot gave no image: {s}", .{res.text});
        const info = Info.parse(res.text) orelse return b.report.fail("bg-capture", "the image's line does not name its window, size, scale and origin: `{s}`", .{res.text});
        const want_w: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(frame.w)) / info.scale));
        const want_h: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(frame.h)) / info.scale));
        shot = Image.of(b, info.width, info.height, info.scale, frame) orelse return b.report.fail("bg-capture", "the server holds no image of {d}x{d}", .{ info.width, info.height });
        // The window paints magenta around its controls: just above the
        // password field, under it, and in the bottom-left corner. The
        // decoy over it is dark: these are the window's own pixels.
        const above = shot.at(field.x + 10, field.y - 8);
        const below = shot.at(field.x + 10, field.bottom() + 8);
        const corner = shot.at(frame.x + 8, frame.bottom() - 8);
        const on_button = shot.at(button.x + @divTrunc(button.w, 2), button.y + 6);
        if (info.handle != b.hwnd or info.width != want_w or info.height != want_h) {
            b.report.fail("bg-capture", "`{s}` for window 0x{x} whose frame is {d}x{d}", .{ res.text, b.hwnd, frame.w, frame.h });
        } else if (!isMagenta(above) or !isMagenta(below) or !isMagenta(corner) or isMagenta(on_button)) {
            b.report.fail("bg-capture", "the image is not the window as it paints itself: background above the field {any}, below {any}, corner {any} (magenta expected), on the button {any} (not magenta expected)", .{ above, below, corner, on_button });
        } else if (v.any()) {
            b.report.fail("bg-capture", "the session changed: {s}", .{v.text(&buf)});
        } else b.report.ok("bg-capture", "screenshot of the window entirely under the decoy: {d}x{d} at scale {d}, its magenta background and its button where Win32 puts them, foreground, focus, cursor and clipboard unchanged, {d} ms", .{ info.width, info.height, info.scale, us / 1000 });
    }

    // bg-capture-password: the field is black in the tool's image and in a
    // zoom on it, and it is the masking that blackens it: the capture the
    // backend hands over shows the field.
    {
        var unmasked = false;
        switch (backend.captureWindow(b.hwnd)) {
            .ok => |raw| {
                const x: usize = @intCast(field.x + @divTrunc(field.w, 2) - raw.rect.x);
                const y: usize = @intCast(field.y + @divTrunc(field.h, 2) - raw.rect.y);
                // A row across the field: its background, or its bullets.
                const row = raw.frame.pixels[y * raw.frame.stride ..];
                var lit: usize = 0;
                for (x - 20..x + 20) |i| lit += @intFromBool(row[i * 4] != 0 or row[i * 4 + 1] != 0 or row[i * 4 + 2] != 0);
                unmasked = lit > 0;
            },
            else => {},
        }
        var black: usize = 0;
        var total: usize = 0;
        var y = field.y;
        while (y < field.bottom()) : (y += 1) {
            var x = field.x;
            while (x < field.right()) : (x += 1) {
                total += 1;
                black += @intFromBool(isBlack(shot.at(x, y)));
            }
        }
        const before = b.begin() orelse return error.DecoyLost;
        // The field and 8 px around it, in the image's pixels.
        const s = shot.scale;
        const x0: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(field.x - 8 - frame.x)) / s));
        const y0: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(field.y - 8 - frame.y)) / s));
        const x1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(field.right() + 8 - frame.x)) / s));
        const y1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(field.bottom() + 8 - frame.y)) / s));
        const z = try b.caller.call("zoom", "{{\"region\":[{d},{d},{d},{d}]}}", .{ x0, y0, x1, y1 });
        const v = b.end(before);
        // The zoom is at the window's own resolution: one pixel each.
        const zw: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(x1 - x0)) * s));
        const zh: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(y1 - y0)) * s));
        const zoom: ?Image = if (z.is_error) null else Image.of(b, zw, zh, 1, .{ .x = frame.x + @as(i32, @intFromFloat(@as(f64, @floatFromInt(x0)) * s)), .y = frame.y + @as(i32, @intFromFloat(@as(f64, @floatFromInt(y0)) * s)), .w = @intCast(zw), .h = @intCast(zh) });
        const zoom_center = if (zoom) |img| img.at(field.x + @divTrunc(field.w, 2), field.y + @divTrunc(field.h, 2)) else null;
        const zoom_outside = if (zoom) |img| img.at(field.x + 10, field.y - 5) else null;
        var buf: [96]u8 = undefined;
        if (!unmasked) {
            b.report.fail("bg-capture-password", "the raw capture shows nothing where the password field is: the control cannot tell masking from an empty image", .{});
        } else if (black != total) {
            b.report.fail("bg-capture-password", "{d} of the field's {d} pixels are black in the screenshot", .{ black, total });
        } else if (z.is_error or !isBlack(zoom_center) or !isMagenta(zoom_outside)) {
            b.report.fail("bg-capture-password", "zoom on the field: center {any} (black expected), above it {any} (magenta expected): {s}", .{ zoom_center, zoom_outside, z.text });
        } else if (std.mem.indexOf(u8, z.text, test_window.secret) != null) {
            b.report.fail("bg-capture-password", "the password's text is in the result", .{});
        } else if (v.any()) {
            b.report.fail("bg-capture-password", "the session changed: {s}", .{v.text(&buf)});
        } else b.report.ok("bg-capture-password", "the password field, which the raw capture shows, is black on its {d} pixels in screenshot and in a zoom on it, by the scan of the target window", .{total});
    }

    // bg-capture-marks: the ids drawn on the window's image.
    {
        const before = b.begin() orelse return error.DecoyLost;
        const res = try b.caller.call("ui_tree", "{{\"marks\":true}}", .{});
        const v = b.end(before);
        var buf: [96]u8 = undefined;
        const at = std.mem.lastIndexOf(u8, res.text, "\nImage : ");
        const info: ?Info = if (at) |i| Info.parse(res.text[i + "\nImage : ".len ..]) else null;
        const img: ?Image = if (info) |n| Image.of(b, n.width, n.height, n.scale, frame) else null;
        // A label is a yellow box at the top-left corner of its element.
        var yellow = false;
        if (img) |m| for (0..4) |dy| for (0..4) |dx| {
            const px = m.at(button.x + @as(i32, @intCast(dx)), button.y + @as(i32, @intCast(dy))) orelse continue;
            yellow = yellow or (px[0] == 0 and px[1] == 0xFF and px[2] == 0xFF);
        };
        if (res.is_error or res.image_mime == null or info == null) {
            b.report.fail("bg-capture-marks", "ui_tree marks gave no image of the window: {s}", .{res.text[0..@min(res.text.len, 200)]});
        } else if (info.?.handle != b.hwnd or !yellow) {
            b.report.fail("bg-capture-marks", "no label at the button's corner in the image of 0x{x} (image of 0x{x})", .{ b.hwnd, info.?.handle });
        } else if (!isBlack(img.?.at(field.x + @divTrunc(field.w, 2), field.y + @divTrunc(field.h, 2)))) {
            b.report.fail("bg-capture-marks", "the password field is not black under the labels", .{});
        } else if (v.any()) {
            b.report.fail("bg-capture-marks", "the session changed: {s}", .{v.text(&buf)});
        } else b.report.ok("bg-capture-marks", "ui_tree marks drew the button's id at its corner on the covered window's own image, password field black, session unchanged", .{});
    }

    // bg-observe-shot: `observe: screenshot` after an action is the covered
    // window's own image, never the screen (decision 0013).
    observe: {
        const name = "bg-observe-shot";
        const box = Bench.idIn(named.text, test_window.checkbox_label) orelse {
            b.report.fail(name, "no element `{s}` in the target's tree", .{test_window.checkbox_label});
            break :observe;
        };
        const before = b.begin() orelse return error.DecoyLost;
        const res = try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"toggle\",\"observe\":\"screenshot\"}}", .{box});
        const v = b.end(before);
        // The box goes back to the state the next controls expect.
        _ = try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"toggle\",\"observe\":\"none\"}}", .{box});
        var buf: [96]u8 = undefined;
        const at = std.mem.lastIndexOf(u8, res.text, "window=0x");
        const info: ?Info = if (at) |i| Info.parse(res.text[i..]) else null;
        const img: ?Image = if (info) |n| Image.of(b, n.width, n.height, n.scale, frame) else null;
        if (res.is_error or res.image_mime == null or info == null or img == null) {
            b.report.fail(name, "ui_act observe screenshot gave no image of the window: {s}", .{res.text[0..@min(res.text.len, 200)]});
        } else if (info.?.handle != b.hwnd or !isMagenta(img.?.at(frame.x + 8, frame.bottom() - 8)) or !isBlack(img.?.at(field.x + @divTrunc(field.w, 2), field.y + @divTrunc(field.h, 2)))) {
            b.report.fail(name, "the image is not the target's (image of 0x{x}), or its password field is not black", .{info.?.handle});
        } else if (v.any()) {
            b.report.fail(name, "the session changed: {s}", .{v.text(&buf)});
        } else b.report.ok(name, "ui_act toggle with observe screenshot returned the covered window's own image ({d}x{d}), password field black, session unchanged", .{ info.?.width, info.?.height });
    }

    // bg-capture-hung: a window that does not answer is never captured.
    {
        const before = b.begin() orelse return error.DecoyLost;
        tw.hang(hang_ms);
        w.Sleep(60);
        const t0 = qpcUs();
        const res = try b.caller.call("screenshot", "{{}}", .{});
        const us = qpcUs() - t0;
        const v = b.end(before);
        // The window answers again before the next control.
        w.Sleep(hang_ms);
        var buf: [96]u8 = undefined;
        if (!res.is_error or res.image_mime != null or std.mem.indexOf(u8, res.text, "ne répond pas") == null) {
            b.report.fail("bg-capture-hung", "a window whose thread is stopped was not refused: {s}", .{res.text[0..@min(res.text.len, 200)]});
        } else if (us > hung_budget_us) {
            b.report.fail("bg-capture-hung", "the refusal took {d} ms (budget {d} ms): the capture waited for the window", .{ us / 1000, hung_budget_us / 1000 });
        } else if (v.any()) {
            b.report.fail("bg-capture-hung", "the session changed: {s}", .{v.text(&buf)});
        } else b.report.ok("bg-capture-hung", "thread stopped for {d} ms: screenshot refused in {d} ms by the 200 ms check, no capture attempted", .{ hang_ms, us / 1000 });
    }
}
