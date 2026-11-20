//! Two generations of bindings/linux.zon give the same bytes (US-077).

const std = @import("std");
const generated = @import("generated");

test "two generations of the protocol tables are identical byte for byte" {
    const a = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const first = try cwd.readFileAlloc(std.testing.io, generated.first, a, .limited(16 << 20));
    defer a.free(first);
    const second = try cwd.readFileAlloc(std.testing.io, generated.second, a, .limited(16 << 20));
    defer a.free(second);
    try std.testing.expect(first.len > 0);
    try std.testing.expectEqualSlices(u8, first, second);
}
