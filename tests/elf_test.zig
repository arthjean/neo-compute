//! The dynamic section of the shipped Linux server (EP-021, P7): it needs
//! glibc's libraries alone, and names no symbol of libxkbcommon, which it
//! loads with dlopen. Added to `zig build test` for a Linux target only.

const std = @import("std");
const testing = std.testing;
const options = @import("test_options");

const Dynamic = struct {
    needed: []const []const u8,
    /// Undefined symbols of .dynsym, resolved at load time.
    imports: []const []const u8,
};

fn readInt(comptime T: type, image: []const u8, at: usize) T {
    return std.mem.readInt(T, image[at..][0..@sizeOf(T)], .little);
}

fn cstr(image: []const u8, at: usize) []const u8 {
    return std.mem.sliceTo(image[at..], 0);
}

/// DT_NEEDED entries and undefined dynamic symbols of an ELF64 image.
fn dynamicOf(a: std.mem.Allocator, image: []const u8) !Dynamic {
    if (image.len < 64 or !std.mem.eql(u8, image[0..4], "\x7fELF") or image[4] != 2 or image[5] != 1) return error.NotElf64;
    const shoff = readInt(u64, image, 0x28);
    const shentsize = readInt(u16, image, 0x3a);
    const shnum = readInt(u16, image, 0x3c);
    var needed: std.ArrayList([]const u8) = .empty;
    var imports: std.ArrayList([]const u8) = .empty;
    for (0..shnum) |i| {
        const sh = shoff + i * shentsize;
        const kind = readInt(u32, image, sh + 4);
        const offset = readInt(u64, image, sh + 0x18);
        const size = readInt(u64, image, sh + 0x20);
        const link = readInt(u32, image, sh + 0x28);
        const strtab = readInt(u64, image, shoff + link * shentsize + 0x18);
        switch (kind) {
            std.elf.SHT_DYNAMIC => {
                var at = offset;
                while (at + 16 <= offset + size) : (at += 16) {
                    const tag = readInt(i64, image, at);
                    if (tag == std.elf.DT_NULL) break;
                    if (tag == std.elf.DT_NEEDED) try needed.append(a, cstr(image, strtab + readInt(u64, image, at + 8)));
                }
            },
            std.elf.SHT_DYNSYM => {
                var at = offset + 24; // entry 0 is the null symbol
                while (at + 24 <= offset + size) : (at += 24) {
                    if (readInt(u16, image, at + 6) != std.elf.SHN_UNDEF) continue;
                    try imports.append(a, cstr(image, strtab + readInt(u32, image, at)));
                }
            },
            else => {},
        }
    }
    return .{ .needed = needed.items, .imports = imports.items };
}

/// The shared objects of glibc (P7: the only libraries the server links).
fn isGlibc(name: []const u8) bool {
    const glibc = [_][]const u8{ "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1" };
    for (glibc) |g| if (std.mem.eql(u8, g, name)) return true;
    return std.mem.startsWith(u8, name, "ld-linux-") and std.mem.indexOf(u8, name, ".so.") != null;
}

test "the Linux server needs glibc alone and loads libxkbcommon with dlopen" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const image = try std.Io.Dir.cwd().readFileAlloc(testing.io, options.server_exe, a, .limited(256 << 20));
    const dyn = try dynamicOf(a, image);
    try testing.expect(dyn.needed.len > 0);
    for (dyn.needed) |n| {
        if (!isGlibc(n)) std.debug.print("NEEDED {s} is not a glibc library\n", .{n});
        try testing.expect(isGlibc(n));
    }
    var dlopen = false;
    for (dyn.imports) |s| {
        try testing.expect(!std.mem.startsWith(u8, s, "xkb_"));
        try testing.expect(!std.mem.startsWith(u8, s, "wl_"));
        try testing.expect(!std.mem.startsWith(u8, s, "ei_"));
        try testing.expect(!std.mem.startsWith(u8, s, "dbus_"));
        if (std.mem.eql(u8, s, "dlopen")) dlopen = true;
    }
    try testing.expect(dlopen);
}

test "a non-glibc library is told apart" {
    try testing.expect(isGlibc("ld-linux-x86-64.so.2"));
    try testing.expect(isGlibc("ld-linux-aarch64.so.1"));
    try testing.expect(!isGlibc("libxkbcommon.so.0"));
    try testing.expect(!isGlibc("libwayland-client.so.0"));
}
