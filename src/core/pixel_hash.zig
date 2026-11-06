//! Hash of sampled rows of a BGRA image, for the fingerprints that tell a
//! still screen without dirty rects (US-032). Built as a static library in
//! ReleaseFast whatever the server's mode (build.zig, `addPixelHash`), like
//! libjpeg: a fingerprint of a maximized window took 11.5 ms per GDI look
//! in a Debug server, 0.24 ms here. A module's own `optimize` is not
//! enough: the Zig code of one compilation is optimized at one level, so
//! only a separate artifact runs at ReleaseFast speed in a Debug build.
//! Nothing here calls a platform API.

const std = @import("std");

/// Wyhash of rows `y0`, `y0 + step`, ... below `y1`, each the bytes
/// `[x0 * 4, x1 * 4)` of a row `stride` bytes long starting at `src`.
export fn neo_pixel_hash(src: [*]const u8, stride: usize, x0: usize, x1: usize, y0: usize, y1: usize, step: usize, seed: u64) u64 {
    var h: std.hash.Wyhash = .init(seed);
    var y = y0;
    while (y < y1) : (y += step) h.update(src[y * stride + x0 * 4 ..][0 .. (x1 - x0) * 4]);
    return h.final();
}
