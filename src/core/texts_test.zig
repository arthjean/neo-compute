//! The texts of each OS (US-071, decision 0014 D7): the Windows server says
//! byte for byte what it said before the texts moved to the backends, and
//! the Linux texts name nothing of Windows, list no `registry_read`, and
//! hold the same budgets, checked at compile time.

const std = @import("std");
const testing = std.testing;
const mcp = @import("mcp.zig");
const registry = @import("registry.zig");
const tools = @import("tools.zig");
const Fake = @import("fake").Fake;
const t = @import("tools_test.zig");

const Server = mcp.Server(Fake, tools.all);

/// `initialize` instructions and `tools/list` of the three modes, as the
/// server answered them before US-071 (captured from the build of that
/// commit).
const before = @embedFile("windows_texts");

test "the Windows texts are the bytes of before US-071, in the three modes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), before, .{});
    inline for (.{ .a11y, .vision, .background }) |mode| {
        const want = v.object.get(@tagName(mode)).?.object;
        var h: t.Harness = .{};
        h.initWith(testing.allocator, .{ .mode = mode });
        defer h.deinit();
        try testing.expectEqualStrings(want.get("instructions").?.string, h.server.instructions);
        const listed = switch (mode) {
            .a11y => Server.Reg.list_result,
            .vision => Server.VisionReg.list_result,
            .background => Server.BgReg.list_result,
            else => unreachable,
        };
        try testing.expectEqualStrings(want.get("tools_list").?.string, listed);
    }
}

/// The registry of a backend that speaks the Linux texts and reads no
/// registry, as `mcp.Server` builds it for the Linux backend.
const LinuxShape = struct {
    pub const texts = Fake.linux_texts;
};
const linux_served = registry.available(LinuxShape, tools.all);
const LinuxReg = registry.RegistryWith(linux_served, LinuxShape.texts);
const LinuxBgReg = registry.BackgroundWith(linux_served, LinuxShape.texts);

comptime {
    // The instruction budgets, and through `list_result` the definition
    // and alwaysLoad budgets, of the Linux texts.
    mcp.checkTexts(LinuxShape.texts);
    _ = LinuxReg.list_result;
    _ = LinuxBgReg.list_result;
}

const windows_words = [_][]const u8{ "Windows", "Start menu", "AUMID", "HKCU", "registry" };

fn expectNoWindowsWord(text: []const u8) !void {
    for (windows_words) |w| if (std.mem.indexOf(u8, text, w)) |at| {
        std.debug.print("`{s}` at {d}: ...{s}...\n", .{ w, at, text[at -| 60..@min(text.len, at + 40)] });
        return error.WindowsWord;
    };
}

test "no Linux text names Windows, the Start menu, an AUMID, HKCU or the registry" {
    try expectNoWindowsWord(LinuxShape.texts.instructions);
    try expectNoWindowsWord(LinuxShape.texts.vision_instructions);
    try expectNoWindowsWord(comptime mcp.backgroundText(LinuxShape.texts));
    try expectNoWindowsWord(LinuxReg.list_result);
    try expectNoWindowsWord(LinuxBgReg.list_result);
    try testing.expect(!LinuxReg.has("registry_read"));
    try testing.expect(!LinuxBgReg.has("registry_read"));
    // The same tools otherwise, with the same parameters.
    try testing.expectEqual(Server.Reg.names.len - 1, LinuxReg.names.len);
    std.debug.print("Linux tools/list: {d} bytes, about {d} tokens (limit {d}); alwaysLoad definitions about {d} tokens (limit {d})\n", .{
        LinuxReg.list_result.len, LinuxReg.definition_tokens, registry.max_definition_tokens, LinuxReg.always_load_tokens, registry.max_always_load_tokens,
    });
}

test "a tool that requires a backend method is listed only where the backend has it" {
    const needy = struct {
        pub const name = "needy";
        pub const description = "Needs a method.";
        pub const requires = "special";
        pub const Args = struct {};
        pub fn run(ctx: anytype, args: Args) mcp.Result {
            _ = .{ ctx, args };
            return mcp.Result.text("ok");
        }
    };
    const With = struct {
        pub fn special() void {}
    };
    const Without = struct {};
    try testing.expectEqual(@as(usize, 1), (comptime registry.available(With, .{needy})).len);
    try testing.expectEqual(@as(usize, 0), (comptime registry.available(Without, .{needy})).len);
}
