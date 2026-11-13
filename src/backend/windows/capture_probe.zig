//! `neo-compute capture-probe [window|notepad|calculator|settings|explorer|
//! chrome|vscode]... [reps=N] [save=DIR]` (US-060, assumption A20): does
//! `PrintWindow` with `PW_RENDERFULLCONTENT` capture a window that is
//! entirely covered?
//!
//! A decoy window of another process holds the foreground on the left of the
//! primary display. The probe opens each of the six reference applications
//! and, for each:
//!
//! - puts the window in view beside the decoy and takes the reference: the
//!   DXGI frame of the display, cut to the window's visible frame. A
//!   `PrintWindow` capture of the window in view is compared with it pixel
//!   for pixel, with and without the offset of the invisible resize borders:
//!   which of the two lines up says where the visible frame sits in the
//!   image;
//! - puts the window entirely under the decoy and captures it `reps` times
//!   (20). Each capture gives: whether the image is black, the share of
//!   black pixels, the duration of the call, the distance to the reference
//!   (a 32x32 grid of mean luminance, 0 to 255), whether the foreground
//!   window, the keyboard focus or the cursor changed, and whether the
//!   screen changed over the window's rectangle while it was captured (what
//!   a user would see as a flicker). The same watch of the screen runs
//!   `reps` times without a capture, as a control.
//!
//! Chrome and VS Code get one more measure, of whether a capture taken under
//! the decoy is current: a check box (Chrome) or a panel (VS Code) is
//! toggled by UI Automation while the window is covered, and the capture
//! after it is compared with the one before, then with one taken once the
//! window is back in view.
//!
//! `window` captures the selftest window the same way, checks its known
//! color, then makes its thread stop answering: the capture must be refused
//! within the 200 ms check, never started. Lines go to stderr. `save=DIR`
//! writes the images as JPEG files, except those of an application marked
//! `private` (Notepad restores the user's own tabs).

const std = @import("std");
const w = @import("win32");
const Windows = @import("../windows.zig").Windows;
const display = @import("../../core/display.zig");
const uitree = @import("../../core/uitree.zig");
const image = @import("../../core/image.zig");
const jpeg = @import("../../core/jpeg.zig");
const window = @import("window.zig");
const capture = @import("capture.zig");
const fixture = @import("bg_fixture.zig");
const bg = @import("bg_probe.zig");
const test_window = @import("test_window.zig");
const TestWindow = test_window.TestWindow;
const Decoy = fixture.Decoy;
const State = fixture.State;

const max_reps = 100;
/// The application loads before it is placed.
const load_ms = 2500;
/// Chromium recomputes the occlusion of its windows after a move.
const settle_ms = 1500;
/// How long the screen is watched after a capture.
const watch_ms = 60;
/// PRD, US-060: p95 of a capture.
const budget_ms = 60;
/// Applications that must pass for A20 to hold.
const needed = 5;
/// Side of the fingerprint grid.
const grid = 32;
/// A channel difference above this makes two pixels differ.
const pixel_tolerance = 24;

const Print = [grid * grid]u8;

/// A BGRA image, rows `stride` bytes apart.
const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,

    fn row(self: Image, y: usize) []const u8 {
        return self.pixels[y * self.stride ..][0 .. @as(usize, self.width) * 4];
    }
};

/// Mean luminance of each cell of a `grid` x `grid` cut of the image.
fn fingerprint(img: Image) Print {
    var out: Print = undefined;
    for (0..grid) |cy| {
        const y0 = cy * img.height / grid;
        const y1 = @max(y0 + 1, (cy + 1) * img.height / grid);
        for (0..grid) |cx| {
            const x0 = cx * img.width / grid;
            const x1 = @max(x0 + 1, (cx + 1) * img.width / grid);
            var sum: u64 = 0;
            var n: u64 = 0;
            var y = y0;
            while (y < y1 and y < img.height) : (y += 1) {
                const r = img.row(y);
                var x = x0;
                while (x < x1 and x < img.width) : (x += 1) {
                    const px = r[x * 4 ..][0..4];
                    // Rec. 601 luma, integer weights of 256.
                    sum += (@as(u32, px[2]) * 77 + @as(u32, px[1]) * 150 + @as(u32, px[0]) * 29) >> 8;
                    n += 1;
                }
            }
            out[cy * grid + cx] = @intCast(if (n == 0) 0 else sum / n);
        }
    }
    return out;
}

const Distance = struct { mean: f64, max: u8 };

fn distance(a: Print, b: Print) Distance {
    var sum: u64 = 0;
    var max: u8 = 0;
    for (a, b) |x, y| {
        const d: u8 = if (x > y) x - y else y - x;
        sum += d;
        max = @max(max, d);
    }
    return .{ .mean = @as(f64, @floatFromInt(sum)) / @as(f64, grid * grid), .max = max };
}

/// Share of the pixels whose three channels are 0, in percent.
fn blackShare(img: Image) f64 {
    var black: u64 = 0;
    for (0..img.height) |y| {
        const r = img.row(y);
        var x: usize = 0;
        while (x < img.width) : (x += 1) {
            const px = r[x * 4 ..][0..4];
            black += @intFromBool(px[0] == 0 and px[1] == 0 and px[2] == 0);
        }
    }
    return @as(f64, @floatFromInt(black)) * 100 / @as(f64, @floatFromInt(@max(1, @as(u64, img.width) * img.height)));
}

/// Share of the pixels that differ between two images of the same size, in
/// percent; null when the sizes differ.
fn pixelDiff(a: Image, b: Image) ?f64 {
    if (a.width != b.width or a.height != b.height) return null;
    var differ: u64 = 0;
    for (0..a.height) |y| {
        const ra = a.row(y);
        const rb = b.row(y);
        var x: usize = 0;
        while (x < a.width) : (x += 1) {
            const pa = ra[x * 4 ..][0..3];
            const pb = rb[x * 4 ..][0..3];
            var far = false;
            for (pa, pb) |ca, cb| {
                const d: u8 = if (ca > cb) ca - cb else cb - ca;
                far = far or d > pixel_tolerance;
            }
            differ += @intFromBool(far);
        }
    }
    return @as(f64, @floatFromInt(differ)) * 100 / @as(f64, @floatFromInt(@max(1, @as(u64, a.width) * a.height)));
}

/// Pixels that differ between two images of the same size.
fn pixelsChanged(a: Image, b: Image) ?u64 {
    const share = pixelDiff(a, b) orelse return null;
    return @intFromFloat(@round(share / 100 * @as(f64, @floatFromInt(@as(u64, a.width) * a.height))));
}

/// The rows of the grid, top to bottom, whose mean distance is above 4:
/// where two images differ.
fn rowsApart(buf: []u8, a: Print, b: Print) []const u8 {
    var wr: std.Io.Writer = .fixed(buf);
    var any = false;
    for (0..grid) |y| {
        var sum: u32 = 0;
        for (a[y * grid ..][0..grid], b[y * grid ..][0..grid]) |x, z| sum += if (x > z) x - z else z - x;
        if (sum / grid <= 4) continue;
        wr.print("{s}{d}", .{ if (any) "," else "", y }) catch break;
        any = true;
    }
    return if (any) wr.buffered() else "none";
}

/// What the freshness measure toggles in an application.
const Fresh = struct {
    name: []const u8,
    role: uitree.Role,
    names: []const []const u8,
    /// The toggle outlives the window (a layout the application saves): it
    /// is toggled back.
    persists: bool = false,
};

const fresh_targets = [_]Fresh{
    .{ .name = "chrome", .role = .checkbox, .names = &.{"Recevoir"} },
    .{ .name = "vscode", .role = .button, .names = &.{ "Toggle Panel", "Activer/désactiver le panneau" }, .persists = true },
};

fn qpc() i64 {
    var t: i64 = 0;
    _ = w.QueryPerformanceCounter(&t);
    return t;
}

fn usSince(from: i64) u64 {
    var f: i64 = 1;
    _ = w.QueryPerformanceFrequency(&f);
    return @intCast(@max(0, @divTrunc((qpc() - from) * 1_000_000, f)));
}

fn percentile(sorted: []const u64, p: usize) u64 {
    if (sorted.len == 0) return 0;
    return sorted[@min(sorted.len - 1, (sorted.len * p + 99) / 100 -| 1)];
}

const Stat = struct {
    name: []const u8,
    measured: bool = false,
    size: [2]u32 = .{ 0, 0 },
    captures: u32 = 0,
    /// The call failed or the window did not answer.
    refused: u32 = 0,
    non_black: u32 = 0,
    us: [max_reps]u64 = undefined,
    us_len: usize = 0,
    black_share_max: f64 = 0,
    reference_black: f64 = 0,
    foreground: u32 = 0,
    focus: u32 = 0,
    cursor: u32 = 0,
    /// Captures, and control watches without a capture, during which the
    /// screen changed over the window's rectangle.
    screen_changed: u32 = 0,
    control_changed: u32 = 0,
    controls: u32 = 0,
    covered: u32 = 0,
    dist: [max_reps]f64 = undefined,
    dist_max: u8 = 0,
    dist_len: usize = 0,
    /// Pixels that differ from the reference, window in view: with the
    /// visible frame's offset, and without it.
    aligned: ?f64 = null,
    unaligned: ?f64 = null,
    reference: bool = false,

    fn p95(s: *Stat) u64 {
        std.mem.sort(u64, s.us[0..s.us_len], {}, std.sort.asc(u64));
        return percentile(s.us[0..s.us_len], 95);
    }

    fn median(s: *Stat) u64 {
        std.mem.sort(u64, s.us[0..s.us_len], {}, std.sort.asc(u64));
        return percentile(s.us[0..s.us_len], 50);
    }

    fn passes(s: *Stat) bool {
        return s.measured and s.captures > 0 and s.non_black == s.captures and s.refused == 0 and s.p95() < budget_ms * 1000;
    }
};

const Run = struct {
    p: *bg.Probe,
    shot: capture.WindowShot = .{},
    reps: usize,
    save: ?[]const u8,
    /// Visible frame of the decoy, and the size the targets are given.
    decoy: display.Rect,
    size: [2]i32,
    primary: display.Rect,
    other: ?display.Rect,
    reducer: image.Reducer = .{},
    encoder: jpeg.Encoder = .{},

    fn deinit(r: *Run) void {
        r.shot.deinit();
        r.reducer.deinit(r.p.gpa);
        r.encoder.deinit(r.p.gpa);
    }

    /// Where a window of the targets' size is in view: beside the decoy,
    /// else on the other display.
    fn inView(r: *const Run) ?[2]i32 {
        const d = r.decoy;
        if (d.right() + 24 + r.size[0] <= r.primary.right()) return .{ d.right() + 24, d.y + 40 };
        if (r.other) |o| return .{ o.x + 120, o.y + 120 };
        return null;
    }

    fn place(r: *Run, hwnd: u64, at: [2]i32) bool {
        switch (window.place(hwnd, .{ .x = at[0], .y = at[1], .w = r.size[0], .h = r.size[1] }, false)) {
            .ok => {},
            else => return false,
        }
        r.p.decoy.tuck(@ptrFromInt(hwnd));
        return r.p.decoy.front();
    }

    /// The part of the screen at `rect`, from the DXGI frame of its
    /// display, copied into `a`.
    fn screenCut(r: *Run, a: std.mem.Allocator, rect: display.Rect) ?Image {
        const backend = r.p.backend;
        const displays = backend.displays();
        const index = display.displayAt(displays, rect.x + @divTrunc(rect.w, 2), rect.y + @divTrunc(rect.h, 2)) orelse return null;
        const d = displays[index].rect;
        const part = display.intersection(rect, d) orelse return null;
        if (!part.eql(rect)) return null;
        // Twice: the first call after a change may still hand the frame
        // before it.
        _ = backend.capture(index, a);
        w.Sleep(120);
        const frame = switch (backend.capture(index, a)) {
            .frame => |f| f,
            .failed => return null,
        };
        const width: usize = @intCast(rect.w);
        const height: usize = @intCast(rect.h);
        const out = a.alloc(u8, width * height * 4) catch return null;
        for (0..height) |y| {
            const src = (@as(usize, @intCast(rect.y - d.y)) + y) * frame.stride + @as(usize, @intCast(rect.x - d.x)) * 4;
            @memcpy(out[y * width * 4 ..][0 .. width * 4], frame.pixels[src..][0 .. width * 4]);
        }
        return .{ .pixels = out, .width = @intCast(width), .height = @intCast(height), .stride = width * 4 };
    }

    /// Whether the screen changed over `target` since the last call.
    fn screenChanged(r: *Run, a: std.mem.Allocator, target: display.Rect) bool {
        const backend = r.p.backend;
        const displays = backend.displays();
        const index = display.displayAt(displays, target.x + @divTrunc(target.w, 2), target.y + @divTrunc(target.h, 2)) orelse return false;
        const frame = switch (backend.changes(index, a, null)) {
            .frame => |f| f,
            .failed => return false,
        };
        for (frame.dirty) |d| if (d.intersects(target)) return true;
        for (frame.moved) |d| if (d.intersects(target)) return true;
        return false;
    }

    fn write(r: *Run, name: []const u8, what: []const u8, img: Image) void {
        const dir = r.save orelse return;
        const p = r.p;
        const long = @max(img.width, img.height);
        const k: f64 = if (long > 1280) @as(f64, @floatFromInt(long)) / 1280 else 1;
        const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(img.width)) / k))));
        const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(img.height)) / k))));
        _ = r.reducer.reduce(p.gpa, img.pixels, img.stride, .{ .x = 0, .y = 0, .w = @intCast(img.width), .h = @intCast(img.height) }, dw, dh) catch return;
        const bytes = r.encoder.encode(p.gpa, r.reducer.out[0 .. @as(usize, dw) * dh * 4], dw, dh, @as(usize, dw) * 4, 85) catch return;
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}-{s}.jpg", .{ dir, name, what }) catch return;
        std.Io.Dir.cwd().writeFile(p.io, .{ .sub_path = path, .data = bytes }) catch |err| p.print("{s} | cannot write {s} ({t})", .{ name, path, err });
    }

    fn grabImage(r: *Run, hwnd: u64) ?struct { img: Image, rect: display.Rect } {
        return switch (r.shot.grab(@ptrFromInt(hwnd))) {
            .ok => |s| .{ .img = .{ .pixels = s.pixels, .width = s.width, .height = s.height, .stride = s.stride }, .rect = s.rect },
            else => null,
        };
    }

    /// The window in view: the DXGI reference, and where the visible frame
    /// sits in a PrintWindow image.
    fn reference(r: *Run, a: std.mem.Allocator, s: *Stat, hwnd: u64, private: bool) ?Print {
        const p = r.p;
        const at = r.inView() orelse {
            p.print("{s} | no place in view for the window (one display, too narrow): no DXGI reference, the distance is not measured", .{s.name});
            return null;
        };
        if (!r.place(hwnd, at)) {
            p.print("{s} | the window cannot be placed in view: no DXGI reference", .{s.name});
            return null;
        }
        w.Sleep(settle_ms);
        const frame = window.rect(@ptrFromInt(hwnd)) orelse return null;
        const cut = r.screenCut(a, frame) orelse {
            p.print("{s} | the window in view does not fit one display, or the screen cannot be captured: no DXGI reference", .{s.name});
            return null;
        };
        s.reference = true;
        s.reference_black = blackShare(cut);
        if (!private) r.write(s.name, "visible-dxgi", cut);
        const got = r.grabImage(hwnd) orelse {
            p.print("{s} | in view | PrintWindow gave no image", .{s.name});
            return fingerprint(cut);
        };
        if (!private) r.write(s.name, "visible-printwindow", got.img);
        s.aligned = pixelDiff(got.img, cut);
        // The same size taken from the image's own top-left corner: what
        // the capture would be if the window rectangle were the frame.
        const plain: Image = .{ .pixels = r.shot.bits[0 .. @as(usize, r.shot.width) * 4 * r.shot.height], .width = got.img.width, .height = got.img.height, .stride = @as(usize, r.shot.width) * 4 };
        s.unaligned = pixelDiff(plain, cut);
        const d = distance(fingerprint(got.img), fingerprint(cut));
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        var b3: [128]u8 = undefined;
        p.print("{s} | in view | grid rows (of {d}, top first) where PrintWindow and the DXGI frame are apart: {s}", .{ s.name, grid, rowsApart(&b3, fingerprint(got.img), fingerprint(cut)) });
        p.print("{s} | in view | visible frame {d},{d} {d}x{d}, window rectangle {d}x{d} | PrintWindow against the DXGI frame: distance mean {d:.1}, max {d} | pixels that differ: {s} with the frame's offset, {s} from the image's corner | black pixels: PrintWindow {d:.1} %, DXGI {d:.1} %", .{
            s.name,                                                                                     frame.x,             frame.y,           frame.w, frame.h,
            r.shot.width,                                                                               r.shot.height,       d.mean,            d.max,   if (s.aligned) |x| std.fmt.bufPrint(&b1, "{d:.1} %", .{x}) catch "?" else "sizes differ",
            if (s.unaligned) |x| std.fmt.bufPrint(&b2, "{d:.1} %", .{x}) catch "?" else "sizes differ", blackShare(got.img), s.reference_black,
        });
        return fingerprint(cut);
    }

    /// `reps` captures of the window as it stands, each with its measures.
    fn series(r: *Run, a: std.mem.Allocator, s: *Stat, hwnd: u64, ref: ?Print, private: bool) void {
        const p = r.p;
        const h: w.HWND = @ptrFromInt(hwnd);
        const frame = window.rect(h) orelse return;
        s.measured = true;
        s.size = .{ @intCast(frame.w), @intCast(frame.h) };
        // Control: the screen over the window with no capture running.
        _ = r.screenChanged(a, frame);
        for (0..r.reps) |_| {
            w.Sleep(watch_ms);
            s.controls += 1;
            s.control_changed += @intFromBool(r.screenChanged(a, frame));
        }
        for (0..r.reps) |n| {
            const covered = p.decoy.covers(h);
            _ = r.screenChanged(a, frame);
            const before = State.sample(null);
            const t0 = qpc();
            const res = r.shot.grab(h);
            const us = usSince(t0);
            const after = State.sample(null);
            w.Sleep(watch_ms);
            const changed = r.screenChanged(a, frame);
            s.captures += 1;
            s.covered += @intFromBool(covered);
            s.foreground += @intFromBool(before.foreground != after.foreground);
            s.focus += @intFromBool(before.focus != after.focus);
            s.cursor += @intFromBool(before.cursor[0] != after.cursor[0] or before.cursor[1] != after.cursor[1]);
            s.screen_changed += @intFromBool(changed);
            const got = switch (res) {
                .ok => |x| x,
                else => {
                    s.refused += 1;
                    p.print("{s} | capture #{d} | NO IMAGE: {t} after {d}.{d:0>1} ms", .{ s.name, n + 1, res, us / 1000, us % 1000 / 100 });
                    continue;
                },
            };
            if (s.us_len < s.us.len) {
                s.us[s.us_len] = us;
                s.us_len += 1;
            }
            const img: Image = .{ .pixels = got.pixels, .width = got.width, .height = got.height, .stride = got.stride };
            const black = blackShare(img);
            s.black_share_max = @max(s.black_share_max, black);
            s.non_black += @intFromBool(black < 100);
            var dbuf: [64]u8 = undefined;
            var dtext: []const u8 = "no reference";
            if (ref) |want| {
                const d = distance(fingerprint(img), want);
                if (s.dist_len < s.dist.len) {
                    s.dist[s.dist_len] = d.mean;
                    s.dist_len += 1;
                }
                s.dist_max = @max(s.dist_max, d.max);
                dtext = std.fmt.bufPrint(&dbuf, "mean {d:.1}, max {d}", .{ d.mean, d.max }) catch "?";
            }
            if (n == 0 and !private) r.write(s.name, "covered", img);
            p.print("{s} | capture #{d} | {s} | {d}.{d:0>1} ms | {d}x{d}, black pixels {d:.1} % | distance to the DXGI reference: {s} | foreground {s}, focus {s}, cursor {s} | screen over the window: {s} | entirely covered: {s}", .{
                s.name,                                                                n + 1,                                                       if (black < 100) "image" else "BLACK",
                us / 1000,                                                             us % 1000 / 100,                                             got.width,
                got.height,                                                            black,                                                       dtext,
                if (before.foreground != after.foreground) "CHANGED" else "unchanged", if (before.focus != after.focus) "CHANGED" else "unchanged", if (before.cursor[0] != after.cursor[0] or before.cursor[1] != after.cursor[1]) "moved" else "unchanged",
                if (changed) "CHANGED" else "still",                                   if (covered) "yes" else "NO",
            });
        }
    }

    /// A copy of the window's capture, kept across the next ones.
    fn keep(r: *Run, a: std.mem.Allocator, hwnd: u64) ?Image {
        const got = r.grabImage(hwnd) orelse return null;
        const width: usize = got.img.width;
        const out = a.alloc(u8, width * 4 * got.img.height) catch return null;
        for (0..got.img.height) |y| @memcpy(out[y * width * 4 ..][0 .. width * 4], got.img.row(y));
        return .{ .pixels = out, .width = got.img.width, .height = got.img.height, .stride = width * 4 };
    }

    /// Is a capture taken under the decoy current? One element is toggled
    /// by UI Automation while the window is covered: the capture after it
    /// either shows the change, or shows it only once the window is back
    /// in view (the application stopped rendering, and PrintWindow gave
    /// the last frame it drew).
    fn freshness(r: *Run, a: std.mem.Allocator, hwnd: u64, t: Fresh) void {
        const p = r.p;
        const at = r.inView() orelse return;
        const d = r.decoy;
        const under: [2]i32 = .{ d.x + 80, d.y + 80 };
        if (!r.place(hwnd, at)) return;
        // The tree is read with the window in view: a covered Chromium
        // window never builds it (US-058).
        var key: ?u64 = null;
        const t0 = qpc();
        while (key == null and usSince(t0) < 8_000_000) {
            _ = p.scratch.reset(.retain_capacity);
            if (p.snapshot(hwnd)) |els| for (els) |e| {
                if (e.role != t.role or !e.actions.toggle) continue;
                for (t.names) |n| if (std.ascii.findIgnoreCase(e.name, n) != null) {
                    key = e.key;
                };
            };
            if (key == null) w.Sleep(400);
        }
        const k = key orelse {
            p.print("{s} | freshness | the element to toggle is not in the tree: not measured", .{t.name});
            return;
        };
        if (!r.place(hwnd, under)) return;
        w.Sleep(settle_ms);
        const covered = p.decoy.covers(@ptrFromInt(hwnd));
        const before = r.keep(a, hwnd) orelse return;
        const op = p.backend.uiOp(p.scratch.allocator(), hwnd, k, .toggle);
        w.Sleep(700);
        const after = r.keep(a, hwnd) orelse return;
        const changed = pixelsChanged(before, after) orelse 0;
        _ = r.place(hwnd, at);
        w.Sleep(settle_ms);
        const shown = r.keep(a, hwnd) orelse return;
        const in_view = pixelsChanged(before, shown) orelse 0;
        p.print("{s} | freshness | toggle by UI Automation ({t}) on the window entirely covered ({s}): the capture 700 ms later differs from the one before by {d} pixels; once the window is in view, by {d} pixels: {s}", .{
            t.name,                                                                                                                                                                                                              op, if (covered) "yes" else "NO", changed, in_view,
            if (changed > 0) "the covered capture is CURRENT" else if (in_view > 0) "the covered capture is STALE (the action was delivered, the application had stopped rendering)" else "no change in either: not conclusive",
        });
        if (t.persists) {
            _ = p.backend.uiOp(p.scratch.allocator(), hwnd, k, .toggle);
            w.Sleep(500);
        }
        _ = p.decoy.front();
    }

    fn app(r: *Run, s: *Stat, target: bg.App) void {
        const p = r.p;
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const hwnd = bg.launchApp(p, a, target) orelse return;
        defer {
            if (!bg.closeWindow(@ptrFromInt(hwnd))) p.print("{s} | window 0x{x} still open after WM_CLOSE: close it by hand", .{ s.name, hwnd });
            _ = p.decoy.front();
        }
        w.Sleep(load_ms);
        const ref = r.reference(a, s, hwnd, target.private);
        const d = r.decoy;
        if (!r.place(hwnd, .{ d.x + 80, d.y + 80 })) {
            p.print("{s} | the window cannot be placed under the decoy: not measured", .{s.name});
            return;
        }
        w.Sleep(settle_ms);
        if (!p.decoy.covers(@ptrFromInt(hwnd))) p.print("{s} | the window does not lie entirely under the decoy (an application with a minimum size above the decoy's): measured as it stands", .{s.name});
        r.series(a, s, hwnd, ref, target.private);
        for (fresh_targets) |t| if (std.mem.eql(u8, t.name, target.name)) r.freshness(a, hwnd, t);
    }

    /// The selftest window: a known color, then a thread that does not
    /// answer.
    fn selfWindow(r: *Run, s: *Stat) !void {
        const p = r.p;
        const d = r.decoy;
        var tw: TestWindow = .{ .background = true, .rect = .{ .left = d.x + 120, .top = d.y + 120, .right = d.x + 600, .bottom = d.y + 440 } };
        try tw.start();
        defer tw.stop();
        w.Sleep(300);
        _ = p.decoy.front();
        p.decoy.tuck(tw.window());
        w.Sleep(300);
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const hwnd: u64 = @intFromPtr(tw.window());
        r.series(arena_state.allocator(), s, hwnd, null, false);
        if (r.grabImage(hwnd)) |got| {
            // Bottom-left of the client area: nothing but the background.
            const px = got.img.row(got.img.height - 6)[6 * 4 ..][0..3];
            const magenta = px[0] == 0xFF and px[1] == 0x00 and px[2] == 0xFF;
            p.print("window | pixel 6,{d} of the capture: B={d} G={d} R={d}, the window's background {s}", .{ got.img.height - 6, px[0], px[1], px[2], if (magenta) "as painted (magenta)" else "NOT AS PAINTED" });
        }
        // A thread that stops answering: the capture is refused by the
        // 200 ms check, and PrintWindow never runs.
        tw.hang(2500);
        w.Sleep(100);
        const t0 = qpc();
        const res = r.shot.grab(tw.window());
        const us = usSince(t0);
        p.print("window | thread stopped for 2500 ms | capture: {t} after {d} ms ({s})", .{ res, us / 1000, if (res == .hung and us < 400_000) "refused by the 200 ms check, the probe did not wait for the window" else "NOT REFUSED IN TIME" });
        w.Sleep(2600);
    }
};

fn summary(p: *bg.Probe, stats: []Stat, reps: usize) void {
    p.print("summary | target | size | captures | not black | median ms | p95 ms | most black pixels in a capture (reference in view) | distance to the DXGI reference, median (largest cell) | pixels that differ in view: with the frame's offset / from the corner | foreground changed | focus changed | cursor moved | screen changed over the window: with a capture / control without | captures entirely covered", .{});
    var passed: usize = 0;
    var measured: usize = 0;
    for (stats) |*s| {
        const reference_app = !std.mem.eql(u8, s.name, "window");
        if (!s.measured) {
            if (s.captures == 0 and s.name.len > 0) p.print("summary | {s} | not measured", .{s.name});
            continue;
        }
        std.mem.sort(f64, s.dist[0..s.dist_len], {}, std.sort.asc(f64));
        var b1: [48]u8 = undefined;
        var b2: [48]u8 = undefined;
        const dist = if (s.dist_len == 0) "no reference" else std.fmt.bufPrint(&b1, "{d:.1} ({d})", .{ s.dist[s.dist_len / 2], s.dist_max }) catch "?";
        const align_text = if (s.aligned != null and s.unaligned != null) std.fmt.bufPrint(&b2, "{d:.1} % / {d:.1} %", .{ s.aligned.?, s.unaligned.? }) catch "?" else "not compared";
        const med = s.median();
        const p95 = s.p95();
        p.print("summary | {s} | {d}x{d} | {d} | {d} | {d}.{d:0>1} | {d}.{d:0>1} | {d:.1} % ({d:.1} %) | {s} | {s} | {d} | {d} | {d} | {d} / {d} | {d}", .{
            s.name,            s.size[0],        s.size[1],         s.captures,       s.non_black,
            med / 1000,        med % 1000 / 100, p95 / 1000,        p95 % 1000 / 100, s.black_share_max,
            s.reference_black, dist,             align_text,        s.foreground,     s.focus,
            s.cursor,          s.screen_changed, s.control_changed, s.covered,
        });
        if (!reference_app) continue;
        measured += 1;
        passed += @intFromBool(s.passes());
        if (!s.passes()) p.print("verdict | {s} | FAILS: {d} of {d} captures not black, {d} without an image, p95 {d}.{d:0>1} ms (budget {d} ms)", .{ s.name, s.non_black, s.captures, s.refused, p95 / 1000, p95 % 1000 / 100, budget_ms });
    }
    if (measured == 0) return;
    const total = bg.reference_apps.len;
    if (passed >= needed) {
        p.print("verdict | A20 VALIDATED: {d} of the {d} reference applications ({d} measured) gave {d} captures of {d} that are not black, entirely covered, with a p95 under {d} ms: US-061 uses PrintWindow", .{ passed, total, measured, reps, reps, budget_ms });
    } else if (measured < total and passed + (total - measured) >= needed) {
        p.print("verdict | A20 NOT DECIDED: {d} of {d} measured applications pass and {d} were not measured: run the probe again with every application", .{ passed, measured, total - measured });
    } else {
        p.print("verdict | A20 REFUTED: {d} of the {d} reference applications pass ({d} needed): US-061 is BLOCKED. Q13 for Arthur: extend tools/winmdgen to the WinRT metadata for Windows.Graphics.Capture, at the price of a larger COM surface against the Rust Switch Gate?", .{ passed, total, needed });
    }
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, log: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    _ = env;
    var reps: usize = 20;
    var save: ?[]const u8 = null;
    var wanted: std.ArrayList([]const u8) = .empty;
    defer wanted.deinit(gpa);
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "reps=")) {
            reps = std.fmt.parseInt(usize, arg["reps=".len..], 10) catch 0;
            if (reps < 1 or reps > max_reps) {
                log.print("capture-probe: reps takes 1 to {d}\n", .{max_reps}) catch {};
                return 2;
            }
        } else if (std.mem.startsWith(u8, arg, "save=")) {
            save = arg["save=".len..];
        } else {
            const known = std.mem.eql(u8, arg, "window") or for (bg.reference_apps) |a| {
                if (std.mem.eql(u8, a.name, arg)) break true;
            } else false;
            if (!known) {
                log.print("capture-probe: unknown argument `{s}` (window, notepad, calculator, settings, explorer, chrome, vscode, reps=N, save=DIR)\n", .{arg}) catch {};
                return 2;
            }
            try wanted.append(gpa, arg);
        }
    }
    const want = struct {
        fn f(list: []const []const u8, name: []const u8) bool {
            if (list.len == 0) return true;
            for (list) |x| if (std.mem.eql(u8, x, name)) return true;
            return false;
        }
    }.f;

    var backend: Windows = .init(gpa);
    defer backend.deinit();
    const displays = backend.displays();
    if (displays.len == 0) {
        log.print("capture-probe: no display enumerated\n", .{}) catch {};
        return 1;
    }
    const primary = displays[0].rect;
    const other: ?display.Rect = if (displays.len > 1) displays[1].rect else null;
    // The decoy holds the left of the primary display: the target fits
    // beside it, in view, for the DXGI reference.
    const area: display.Rect = .{ .x = primary.x + 40, .y = primary.y + 40, .w = @min(1300, primary.w - 80), .h = @min(1000, primary.h - 200) };
    var decoy = Decoy.start(io, area) catch |err| {
        log.print("capture-probe: the decoy window cannot take the foreground ({t}): run the probe from a terminal the user is not typing in\n", .{err}) catch {};
        return 1;
    };
    defer decoy.stop(io);
    var p: bg.Probe = .{ .gpa = gpa, .io = io, .log = log, .backend = &backend, .decoy = decoy, .scratch = .init(gpa), .prefix = "capture-probe" };
    defer p.scratch.deinit();
    defer p.stats.deinit(gpa);

    // No pattern call gives the focus to its target: the freshness measure
    // acts as the background mode does.
    backend.uiAutoFocus(false);
    const frame = window.rect(decoy.hwnd) orelse area;
    var r: Run = .{ .p = &p, .reps = reps, .save = save, .decoy = frame, .size = .{ @min(1100, frame.w - 160), @min(800, frame.h - 160) }, .primary = primary, .other = other };
    defer r.deinit();
    p.print("decoy 0x{x} of another process in the foreground, visible frame {d},{d} {d}x{d}; target frame {d}x{d}; {d} PrintWindow capture(s) with PW_RENDERFULLCONTENT per target, entirely under the decoy; {d} display(s)", .{ @intFromPtr(decoy.hwnd), frame.x, frame.y, frame.w, frame.h, r.size[0], r.size[1], reps, displays.len });

    var stats: [bg.reference_apps.len + 1]Stat = undefined;
    stats[0] = .{ .name = "window" };
    for (bg.reference_apps, stats[1..]) |a, *s| s.* = .{ .name = a.name };
    if (want(wanted.items, "window")) try r.selfWindow(&stats[0]) else stats[0].name = "";
    for (bg.reference_apps, stats[1..]) |a, *s| {
        if (p.lost) break;
        if (!want(wanted.items, a.name)) {
            s.name = "";
            continue;
        }
        if (!decoy.front()) {
            p.lost = true;
            p.print("the decoy cannot take the foreground back: run stopped", .{});
            break;
        }
        r.app(s, a);
    }
    summary(&p, &stats, reps);
    return if (p.lost) 1 else 0;
}
