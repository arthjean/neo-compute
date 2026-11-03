//! JPEG encoding through libjpeg-turbo (built by build.zig, BGRA input via
//! JCS_EXT_BGRA). The compressor and the output buffer are kept between
//! calls, so encoding a stream of same-size screenshots allocates nothing.

const std = @import("std");
const c = @import("neo_jpeg");

pub const Error = error{ OutOfMemory, EncodeFailed };

pub const screenshot_quality = 80;
pub const zoom_quality = 90;

pub const Encoder = struct {
    handle: ?*c.neo_jpeg = null,
    out: []u8 = &.{},

    pub fn deinit(self: *Encoder, gpa: std.mem.Allocator) void {
        if (self.handle) |h| c.neo_jpeg_destroy(h);
        gpa.free(self.out);
        self.* = .{};
    }

    /// Encodes `bgra` (rows `stride` bytes apart). The result is owned by
    /// the encoder and valid until the next call.
    pub fn encode(self: *Encoder, gpa: std.mem.Allocator, bgra: []const u8, width: u32, height: u32, stride: usize, quality: u8) Error![]const u8 {
        const h = self.handle orelse blk: {
            self.handle = c.neo_jpeg_create() orelse return error.OutOfMemory;
            break :blk self.handle.?;
        };
        // One byte per pixel holds a screen image at these qualities; the
        // buffer doubles on the rare overflow and is kept afterwards.
        if (self.out.len == 0) try self.grow(gpa, @max(64 * 1024, @as(usize, width) * height));
        while (true) {
            var len: usize = 0;
            const status = c.neo_jpeg_encode_bgra(h, bgra.ptr, width, height, stride, quality, self.out.ptr, self.out.len, &len);
            switch (status) {
                c.NEO_JPEG_OK => return self.out[0..len],
                c.NEO_JPEG_OVERFLOW => try self.grow(gpa, self.out.len * 2),
                else => {
                    std.debug.print("neo-compute: JPEG encoding failed: {s}\n", .{std.mem.sliceTo(c.neo_jpeg_last_error(h), 0)});
                    return error.EncodeFailed;
                },
            }
        }
    }

    fn grow(self: *Encoder, gpa: std.mem.Allocator, len: usize) Error!void {
        gpa.free(self.out);
        self.out = &.{};
        self.out = try gpa.alloc(u8, len);
    }
};

test "encodes a BGRA image to a baseline JPEG and reuses its buffers" {
    const gpa = std.testing.allocator;
    var enc: Encoder = .{};
    defer enc.deinit(gpa);
    const w = 320;
    const h = 200;
    var img: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        img[i..][0..4].* = .{ @truncate(x), @truncate(y), @truncate(x ^ y), 255 };
    };
    const jpg = try enc.encode(gpa, &img, w, h, w * 4, screenshot_quality);
    try std.testing.expect(jpg.len > 100);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8, 0xFF }, jpg[0..3]); // SOI
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, jpg[jpg.len - 2 ..]); // EOI
    // SOF0 carries the dimensions.
    const sof = std.mem.indexOf(u8, jpg, &.{ 0xFF, 0xC0 }).?;
    try std.testing.expectEqual(@as(u16, h), std.mem.readInt(u16, jpg[sof + 5 ..][0..2], .big));
    try std.testing.expectEqual(@as(u16, w), std.mem.readInt(u16, jpg[sof + 7 ..][0..2], .big));
    const first_ptr = enc.out.ptr;
    _ = try enc.encode(gpa, &img, w, h, w * 4, zoom_quality);
    try std.testing.expectEqual(first_ptr, enc.out.ptr);
}

test "a too small output buffer grows and the encoding succeeds" {
    const gpa = std.testing.allocator;
    var enc: Encoder = .{};
    defer enc.deinit(gpa);
    try enc.grow(gpa, 16);
    const w = 128;
    const h = 128;
    const img = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(img);
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(img);
    const jpg = try enc.encode(gpa, img, w, h, w * 4, 100);
    try std.testing.expect(jpg.len > 16 and enc.out.len >= jpg.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, jpg[jpg.len - 2 ..]);
}
