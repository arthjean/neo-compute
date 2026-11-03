//! Token estimates for tool results (`--trace`) and tool definitions.
//! Images follow the documented ceil(w/28) x ceil(h/28) rule; text uses the
//! bytes-per-token ratio from bench/token_calibration.json, injected by
//! build.zig as a build option.

const build_options = @import("build_options");

pub const text_bytes_per_token: f64 = build_options.text_bytes_per_token;

pub fn text(bytes: usize) usize {
    if (bytes == 0) return 0;
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(bytes)) / text_bytes_per_token));
}

pub fn image(width: u32, height: u32) usize {
    return @as(usize, (width + 27) / 28) * ((height + 27) / 28);
}

test image {
    const std = @import("std");
    // 1280x720 is documented as 1,196 tokens (46 x 26).
    try std.testing.expectEqual(@as(usize, 46 * 26), image(1280, 720));
}
