//! Must fail to compile: the always-loaded tool `tool_9` pushes the
//! `anthropic/alwaysLoad` definitions above 1,500 estimated tokens, while
//! every definition together stays under 4,500.
const std = @import("std");
const registry = @import("registry");

fn Tool(comptime i: usize) type {
    return struct {
        pub const name = std.fmt.comptimePrint("tool_{d}", .{i});
        pub const description = "Small always-loaded tool.";
        pub const annotations = .{ .always_load = true };
        pub const Args = if (i == 9) struct {
            text: []const u8,
            pub const field_info = .{ .text = .{ .description = &@as([4000]u8, @splat('z')) } };
        } else struct {};
    };
}

const many = blk: {
    var t: [10]type = undefined;
    for (&t, 0..) |*slot, i| slot.* = Tool(i);
    break :blk t;
};

comptime {
    _ = registry.Registry(many).list_result;
}
