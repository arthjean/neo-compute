//! BGRA image operations of the screenshot pipeline: area-filter reduction
//! vectorized with `@Vector` in reusable buffers, and the rotation that turns
//! a duplicated panel image into desktop orientation.

const std = @import("std");
const Rect = @import("display.zig").Rect;

// ---------------------------------------------------------------- rotation

/// Rotation of a display, as DXGI reports it: the duplicated texture is in
/// panel orientation and must be turned back into desktop orientation.
pub const Rotation = enum { identity, rotate90, rotate180, rotate270 };

/// Panel (texture) pixel that holds desktop pixel (dx, dy) of a desktop of
/// size dw x dh. Follows Microsoft's DXGIDesktopDuplication sample
/// (DisplayManager.cpp, SetDirtyVert): for ROTATE90 desktop x = W - tex y,
/// desktop y = tex x; for ROTATE270 desktop x = tex y, desktop y = H - tex x.
pub fn panelPixel(rotation: Rotation, dw: u32, dh: u32, dx: u32, dy: u32) [2]u32 {
    return switch (rotation) {
        .identity => .{ dx, dy },
        .rotate90 => .{ dy, dw - 1 - dx },
        .rotate180 => .{ dw - 1 - dx, dh - 1 - dy },
        .rotate270 => .{ dh - 1 - dy, dx },
    };
}

/// Desktop rectangle (relative to the display origin) of a panel rectangle,
/// for dirty and move rects. dw x dh is the desktop size.
pub fn panelRectToDesktop(rotation: Rotation, dw: i32, dh: i32, r: Rect) Rect {
    return switch (rotation) {
        .identity => r,
        .rotate90 => .{ .x = dw - r.bottom(), .y = r.x, .w = r.h, .h = r.w },
        .rotate180 => .{ .x = dw - r.right(), .y = dh - r.bottom(), .w = r.w, .h = r.h },
        .rotate270 => .{ .x = r.y, .y = dh - r.right(), .w = r.h, .h = r.w },
    };
}

/// Copies a panel image (`src`, rows `src_pitch` bytes apart) into `dst`,
/// a tightly packed desktop-oriented dw x dh BGRA buffer.
pub fn copyRotated(rotation: Rotation, dst: []u8, dw: u32, dh: u32, src: [*]const u8, src_pitch: usize) void {
    const row = @as(usize, dw) * 4;
    if (rotation == .identity) {
        for (0..dh) |y| @memcpy(dst[y * row ..][0..row], src[y * src_pitch ..][0..row]);
        return;
    }
    const d32: [*]align(1) u32 = @ptrCast(dst.ptr);
    for (0..dh) |y| for (0..dw) |x| {
        const p = panelPixel(rotation, dw, dh, @intCast(x), @intCast(y));
        const s: *align(1) const u32 = @ptrCast(src + p[1] * src_pitch + @as(usize, p[0]) * 4);
        d32[y * dw + x] = s.*;
    };
}

// ---------------------------------------------------------------- reduction

/// Fixed-point weights: each axis sums to 1 << weight_bits, so a channel
/// accumulates at most 255 << 24, which fits u32.
const weight_bits = 12;
const one: u32 = 1 << weight_bits;

/// Contributions of source samples to each destination sample of one axis.
const Axis = struct {
    start: []u32 = &.{},
    weights: []u16 = &.{},
    taps: usize = 0,

    fn build(self: *Axis, gpa: std.mem.Allocator, src_len: u32, dst_len: u32) !void {
        const ratio = @as(f64, @floatFromInt(src_len)) / @as(f64, @floatFromInt(dst_len));
        const taps: usize = @as(usize, @intFromFloat(@ceil(ratio))) + 1;
        if (self.start.len < dst_len) {
            gpa.free(self.start);
            self.start = &.{};
            self.start = try gpa.alloc(u32, dst_len);
        }
        if (self.weights.len < @as(usize, dst_len) * taps) {
            gpa.free(self.weights);
            self.weights = &.{};
            self.weights = try gpa.alloc(u16, @as(usize, dst_len) * taps);
        }
        self.taps = taps;
        for (0..dst_len) |i| {
            const lo = @as(f64, @floatFromInt(i)) * ratio;
            const hi = @min(@as(f64, @floatFromInt(i + 1)) * ratio, @as(f64, @floatFromInt(src_len)));
            const first: u32 = @intFromFloat(@floor(lo));
            self.start[i] = first;
            const w = self.weights[i * taps ..][0..taps];
            @memset(w, 0);
            var sum: u32 = 0;
            var last: usize = 0;
            for (0..taps) |t| {
                const s = first + @as(u32, @intCast(t));
                if (s >= src_len) break;
                const a = @max(lo, @as(f64, @floatFromInt(s)));
                const b = @min(hi, @as(f64, @floatFromInt(s + 1)));
                if (b <= a) continue;
                const q: u32 = @intFromFloat(@round((b - a) / (hi - lo) * one));
                w[t] = @intCast(q);
                sum += q;
                last = t;
            }
            // Rounding drift goes to the last contributing tap so each
            // destination sample sums exactly to `one`.
            w[last] = @intCast(@as(i64, w[last]) + @as(i64, one) - @as(i64, sum));
        }
    }

    fn deinit(self: *Axis, gpa: std.mem.Allocator) void {
        gpa.free(self.start);
        gpa.free(self.weights);
    }
};

/// Area-filter reducer. Buffers grow on the first use of a size and are
/// reused afterwards, so a steady stream of screenshots allocates nothing.
pub const Reducer = struct {
    x: Axis = .{},
    y: Axis = .{},
    /// One accumulated source row (4 channels per pixel).
    acc: []u32 = &.{},
    out: []u8 = &.{},

    pub fn deinit(self: *Reducer, gpa: std.mem.Allocator) void {
        self.x.deinit(gpa);
        self.y.deinit(gpa);
        gpa.free(self.acc);
        gpa.free(self.out);
    }

    /// Reduces the `region` of `src` (BGRA, `stride` bytes per row) to
    /// dst_w x dst_h with an area filter. Returns a tightly packed BGRA
    /// buffer owned by the reducer, valid until the next call.
    pub fn reduce(self: *Reducer, gpa: std.mem.Allocator, src: []const u8, stride: usize, region: Rect, dst_w: u32, dst_h: u32) ![]const u8 {
        const sw: u32 = @intCast(region.w);
        const sh: u32 = @intCast(region.h);
        std.debug.assert(dst_w <= sw and dst_h <= sh and dst_w > 0 and dst_h > 0);
        const out_len = @as(usize, dst_w) * dst_h * 4;
        if (self.out.len < out_len) {
            gpa.free(self.out);
            self.out = &.{};
            self.out = try gpa.alloc(u8, out_len);
        }
        if (self.acc.len < @as(usize, sw) * 4) {
            gpa.free(self.acc);
            self.acc = &.{};
            self.acc = try gpa.alloc(u32, @as(usize, sw) * 4);
        }
        try self.x.build(gpa, sw, dst_w);
        try self.y.build(gpa, sh, dst_h);

        const base = @as(usize, @intCast(region.y)) * stride + @as(usize, @intCast(region.x)) * 4;
        const row_len = @as(usize, sw) * 4;
        const acc = self.acc[0..row_len];
        const lanes = 16;
        const V = @Vector(lanes, u32);
        for (0..dst_h) |oy| {
            // Vertical pass: weighted sum of the contributing source rows.
            @memset(acc, 0);
            const wy = self.y.weights[oy * self.y.taps ..][0..self.y.taps];
            for (wy, 0..) |wt, t| {
                if (wt == 0) continue;
                const row = src[base + (self.y.start[oy] + t) * stride ..][0..row_len];
                const wv: V = @splat(wt);
                var i: usize = 0;
                while (i + lanes <= row_len) : (i += lanes) {
                    const px: @Vector(lanes, u8) = row[i..][0..lanes].*;
                    const a: V = acc[i..][0..lanes].*;
                    acc[i..][0..lanes].* = a + @as(V, px) * wv;
                }
                while (i < row_len) : (i += 1) acc[i] += @as(u32, row[i]) * wt;
            }
            // Horizontal pass, one BGRA pixel per 4-lane vector.
            const out_row = self.out[oy * dst_w * 4 ..][0 .. dst_w * 4];
            const P = @Vector(4, u32);
            const half: P = @splat(1 << (2 * weight_bits - 1));
            for (0..dst_w) |ox| {
                const wx = self.x.weights[ox * self.x.taps ..][0..self.x.taps];
                const sx = self.x.start[ox];
                var sum: P = half;
                for (wx, 0..) |wt, t| {
                    if (wt == 0) continue;
                    const p: P = acc[(sx + t) * 4 ..][0..4].*;
                    sum += p * @as(P, @splat(wt));
                }
                const v: @Vector(4, u8) = @intCast(sum >> @splat(2 * weight_bits));
                out_row[ox * 4 ..][0..4].* = v;
            }
        }
        return self.out[0..out_len];
    }
};

/// Exact area average in f64, the reference the vectorized reducer is
/// checked against.
pub fn reduceReference(out: []u8, src: []const u8, stride: usize, sw: u32, sh: u32, dw: u32, dh: u32) void {
    const rx = @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(dw));
    const ry = @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(dh));
    for (0..dh) |oy| for (0..dw) |ox| {
        const x0 = @as(f64, @floatFromInt(ox)) * rx;
        const x1 = x0 + rx;
        const y0 = @as(f64, @floatFromInt(oy)) * ry;
        const y1 = y0 + ry;
        var sum: [4]f64 = @splat(0);
        var yy: usize = @intFromFloat(@floor(y0));
        while (@as(f64, @floatFromInt(yy)) < y1 and yy < sh) : (yy += 1) {
            const wy = @min(y1, @as(f64, @floatFromInt(yy + 1))) - @max(y0, @as(f64, @floatFromInt(yy)));
            var xx: usize = @intFromFloat(@floor(x0));
            while (@as(f64, @floatFromInt(xx)) < x1 and xx < sw) : (xx += 1) {
                const wx = @min(x1, @as(f64, @floatFromInt(xx + 1))) - @max(x0, @as(f64, @floatFromInt(xx)));
                for (0..4) |c| sum[c] += wx * wy * @as(f64, @floatFromInt(src[yy * stride + xx * 4 + c]));
            }
        }
        for (0..4) |c| out[(oy * dw + ox) * 4 + c] = @intFromFloat(@round(sum[c] / (rx * ry)));
    };
}

fn testPattern(buf: []u8, w: u32, h: u32) void {
    // Gradients, a checkerboard and hard edges: the cases where a wrong
    // weight shows.
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        const checker: u8 = if (((x / 3) + (y / 3)) % 2 == 0) 255 else 0;
        buf[i + 0] = @truncate(x * 255 / w);
        buf[i + 1] = @truncate(y * 255 / h);
        buf[i + 2] = checker;
        buf[i + 3] = if (x > w / 2) 255 else 17;
    };
}

test "vectorized area reduction stays within 2 per channel of the exact reference" {
    const gpa = std.testing.allocator;
    var r: Reducer = .{};
    defer r.deinit(gpa);
    const cases = [_][4]u32{
        .{ 2560, 1440, 1280, 720 }, // 2:1
        .{ 1920, 1080, 1280, 720 }, // 1.5:1
        .{ 1707, 960, 1280, 720 }, // non-integer, odd widths
        .{ 333, 211, 101, 67 },
        .{ 64, 64, 64, 64 }, // identity
    };
    for (cases) |c| {
        const src = try gpa.alloc(u8, c[0] * c[1] * 4);
        defer gpa.free(src);
        testPattern(src, c[0], c[1]);
        const want = try gpa.alloc(u8, c[2] * c[3] * 4);
        defer gpa.free(want);
        reduceReference(want, src, c[0] * 4, c[0], c[1], c[2], c[3]);
        const got = try r.reduce(gpa, src, c[0] * 4, .{ .x = 0, .y = 0, .w = @intCast(c[0]), .h = @intCast(c[1]) }, c[2], c[3]);
        var worst: u32 = 0;
        for (got, want) |g, wv| worst = @max(worst, @abs(@as(i32, g) - @as(i32, wv)));
        if (worst > 2) {
            std.debug.print("{d}x{d} -> {d}x{d}: max error {d}\n", .{ c[0], c[1], c[2], c[3], worst });
            return error.TestExpectedEqual;
        }
    }
}

test "reduction of a sub-region matches reducing the cropped image" {
    const gpa = std.testing.allocator;
    var r: Reducer = .{};
    defer r.deinit(gpa);
    const w = 400;
    const h = 300;
    const src = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(src);
    testPattern(src, w, h);
    const region: Rect = .{ .x = 37, .y = 21, .w = 200, .h = 150 };
    const got = try gpa.dupe(u8, try r.reduce(gpa, src, w * 4, region, 100, 75));
    defer gpa.free(got);
    const want = try gpa.alloc(u8, 100 * 75 * 4);
    defer gpa.free(want);
    reduceReference(want, src[(21 * w + 37) * 4 ..], w * 4, 200, 150, 100, 75);
    for (got, want) |g, wv| try std.testing.expect(@abs(@as(i32, g) - @as(i32, wv)) <= 2);
}

test "a steady stream of same-size reductions allocates nothing after the first" {
    var counter = @import("counting_allocator.zig").CountingAllocator.init(std.testing.allocator);
    const gpa = counter.allocator();
    var r: Reducer = .{};
    defer r.deinit(gpa);
    var src: [96 * 54 * 4]u8 = undefined;
    testPattern(&src, 96, 54);
    _ = try r.reduce(gpa, &src, 96 * 4, .{ .x = 0, .y = 0, .w = 96, .h = 54 }, 64, 36);
    const after_first = counter.count();
    for (0..10) |_| _ = try r.reduce(gpa, &src, 96 * 4, .{ .x = 0, .y = 0, .w = 96, .h = 54 }, 64, 36);
    try std.testing.expectEqual(after_first, counter.count());
}

test "rotated panels come back in desktop orientation (90, 180, 270)" {
    // Desktop 3x2, pixel value = 10 * y + x. Build each panel image from the
    // desktop with the sample's mapping, then undo it.
    const dw = 3;
    const dh = 2;
    var desktop: [dw * dh]u32 = undefined;
    for (0..dh) |y| for (0..dw) |x| {
        desktop[y * dw + x] = @intCast(10 * y + x);
    };
    for ([_]Rotation{ .identity, .rotate90, .rotate180, .rotate270 }) |rot| {
        const pw: u32 = if (rot == .rotate90 or rot == .rotate270) dh else dw;
        var panel: [dw * dh]u32 = undefined;
        for (0..dh) |y| for (0..dw) |x| {
            const p = panelPixel(rot, dw, dh, @intCast(x), @intCast(y));
            panel[p[1] * pw + p[0]] = desktop[y * dw + x];
        };
        var out: [dw * dh * 4]u8 = undefined;
        copyRotated(rot, &out, dw, dh, @ptrCast(&panel), pw * 4);
        var got: [dw * dh]u32 = undefined;
        @memcpy(std.mem.sliceAsBytes(&got), &out);
        try std.testing.expectEqualSlices(u32, &desktop, &got);
    }
    // ROTATE90 per the sample: a panel rect (left 0, top 0, right 1, bottom 2)
    // lands at desktop left W - 2, top 0.
    const r = panelRectToDesktop(.rotate90, 3, 2, .{ .x = 0, .y = 0, .w = 1, .h = 2 });
    try std.testing.expectEqual(Rect{ .x = 1, .y = 0, .w = 2, .h = 1 }, r);
}
