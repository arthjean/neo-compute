//! The generated bindings must compile in full with Zig 0.17: every
//! declaration is analyzed and every extern function is linked.

const std = @import("std");
const win32 = @import("win32");

test "every generated declaration compiles and links" {
    @setEvalBranchQuota(200_000);
    inline for (@typeInfo(win32).@"struct".decl_names) |name| {
        const T = @TypeOf(@field(win32, name));
        if (@typeInfo(T) == .@"fn") _ = &@field(win32, name);
        if (T == type) {
            const D = @field(win32, name);
            switch (@typeInfo(D)) {
                .@"struct", .@"union" => {
                    _ = @sizeOf(D);
                    if (@hasDecl(D, "VTable")) _ = @sizeOf(D.VTable);
                },
                else => {},
            }
        }
    }
}
