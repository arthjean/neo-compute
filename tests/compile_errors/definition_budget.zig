//! Must fail to compile: tool definitions estimated above 4,500 tokens.
const std = @import("std");
const registry = @import("registry");

fn Tool(comptime i: usize) type {
    return struct {
        pub const name = std.fmt.comptimePrint("tool_{d}", .{i});
        pub const description = "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy";
        pub const Args = struct {};
    };
}

const many = blk: {
    var t: [40]type = undefined;
    for (&t, 0..) |*slot, i| slot.* = Tool(i);
    break :blk t;
};

comptime {
    _ = registry.Registry(many).list_result;
}
