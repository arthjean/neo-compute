//! Generated struct layouts must match the C compiler's view of the
//! mingw-w64 headers: same size, same offset for every generated field.

const std = @import("std");
const win32 = @import("win32");
const reference = @embedFile("layout_c");

const structs = .{
    "INPUT",                   "MOUSEINPUT",                 "KEYBDINPUT",                    "HARDWAREINPUT",
    "DXGI_OUTDUPL_FRAME_INFO", "DXGI_OUTDUPL_DESC",          "DXGI_OUTDUPL_POINTER_POSITION", "DXGI_OUTDUPL_MOVE_RECT",
    "DXGI_OUTPUT_DESC",        "DXGI_ADAPTER_DESC1",         "DXGI_MODE_DESC",                "DXGI_RATIONAL",
    "DXGI_SAMPLE_DESC",        "D3D11_TEXTURE2D_DESC",       "D3D11_MAPPED_SUBRESOURCE",      "VARIANT",
    "SAFEARRAY",               "SAFEARRAYBOUND",             "RECT",                          "POINT",
    "LUID",                    "GUID",                       "WNDCLASSEXW",                   "MSG",
    "PAINTSTRUCT",             "PROCESS_MEMORY_COUNTERS_EX", "MONITORINFO",                   "DECIMAL",
    "CY",
};

fn lookup(kind: u8, key: []const u8) ?usize {
    var it = std.mem.tokenizeAny(u8, reference, "\r\n");
    while (it.next()) |line| {
        if (line.len < 2 or line[0] != kind) continue;
        var parts = std.mem.tokenizeScalar(u8, line[2..], ' ');
        const k = parts.next() orelse continue;
        if (!std.mem.eql(u8, k, key)) continue;
        return std.fmt.parseInt(usize, parts.next() orelse return null, 10) catch null;
    }
    return null;
}

test "at least 20 generated structs match sizeof and offsetof from C" {
    @setEvalBranchQuota(100_000);
    var checked_fields: usize = 0;
    var failures: usize = 0;
    inline for (structs) |name| {
        const T = @field(win32, name);
        const c_size = lookup('S', name) orelse {
            std.debug.print("{s}: no C reference line\n", .{name});
            return error.MissingReference;
        };
        if (@sizeOf(T) != c_size) {
            std.debug.print("{s}: sizeof Zig {d} vs C {d}\n", .{ name, @sizeOf(T), c_size });
            failures += 1;
        }
        inline for (comptime std.meta.fieldNames(T)) |field| {
            const key = name ++ "." ++ field;
            const c_off = lookup('F', key) orelse {
                std.debug.print("{s}: no C reference for field\n", .{key});
                return error.MissingReference;
            };
            // Union members all start at offset 0.
            const zig_off = if (@typeInfo(T) == .@"union") 0 else @offsetOf(T, field);
            if (zig_off != c_off) {
                std.debug.print("{s}: offsetof Zig {d} vs C {d}\n", .{ key, zig_off, c_off });
                failures += 1;
            }
            checked_fields += 1;
        }
    }
    try std.testing.expect(structs.len >= 20);
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expect(checked_fields > 100);
}
