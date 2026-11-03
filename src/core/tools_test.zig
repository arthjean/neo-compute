//! EP-002 tools through the real dispatcher (`tools/call` JSON in, JSON-RPC
//! line out) against the fake backend: screenshot, zoom, mouse, keyboard,
//! held-input release and window tools.

const std = @import("std");
const testing = std.testing;
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const Fake = @import("../backend/fake.zig").Fake;
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
const mcp_test = @import("mcp_test.zig");

const Server = mcp.Server(Fake, tools.all);

const Harness = struct {
    backend: Fake = .{},
    server: Server = undefined,
    out: std.Io.Writer.Allocating = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    next_id: u32 = 1,

    fn init(self: *Harness, gpa: std.mem.Allocator) void {
        self.server = .init(gpa, testing.io, &self.backend, .{});
        self.out = .init(testing.allocator);
        self.arena = .init(testing.allocator);
    }

    fn deinit(self: *Harness) void {
        self.server.deinit();
        self.out.deinit();
        self.arena.deinit();
    }

    /// Calls `tool` with `args` (JSON) and returns the parsed `result`.
    fn call(self: *Harness, tool: []const u8, args: []const u8) !std.json.ObjectMap {
        self.out.clearRetainingCapacity();
        const a = self.arena.allocator();
        const line = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ self.next_id, tool, args });
        self.next_id += 1;
        try self.server.handleMessage(line, &self.out.writer);
        const written = std.mem.trimEnd(u8, self.out.written(), "\n");
        const last = written[(std.mem.lastIndexOfScalar(u8, written, '\n') orelse return self.parse(written)) + 1 ..];
        return self.parse(last);
    }

    fn parse(self: *Harness, line: []const u8) !std.json.ObjectMap {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), try self.arena.allocator().dupe(u8, line), .{});
        return v.object.get("result").?.object;
    }
};

fn isError(res: std.json.ObjectMap) bool {
    return if (res.get("isError")) |e| e.bool else false;
}

fn block(res: std.json.ObjectMap, i: usize) std.json.ObjectMap {
    return res.get("content").?.array.items[i].object;
}

fn text(res: std.json.ObjectMap) []const u8 {
    const items = res.get("content").?.array.items;
    for (items) |it| if (std.mem.eql(u8, it.object.get("type").?.string, "text")) return it.object.get("text").?.string;
    return "";
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("`{s}` lacks `{s}`\n", .{ haystack, needle });
        return error.TestExpectedEqual;
    }
}

/// Width and height from the SOF0 marker of a base64 JPEG.
fn jpegSize(arena: std.mem.Allocator, b64: []const u8) ![2]u16 {
    const bytes = try arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(b64));
    try std.base64.standard.Decoder.decode(bytes, b64);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8 }, bytes[0..2]);
    const sof = std.mem.indexOf(u8, bytes, &.{ 0xFF, 0xC0 }).?;
    return .{ std.mem.readInt(u16, bytes[sof + 7 ..][0..2], .big), std.mem.readInt(u16, bytes[sof + 5 ..][0..2], .big) };
}

test "screenshot returns a 1280 px JPEG and its display, scale and size" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const res = try h.call("screenshot", "{}");
    try testing.expect(!isError(res));
    const img = block(res, 0);
    try testing.expectEqualStrings("image", img.get("type").?.string);
    try testing.expectEqualStrings("image/jpeg", img.get("mimeType").?.string);
    try testing.expectEqual([2]u16{ 1280, 720 }, try jpegSize(h.arena.allocator(), img.get("data").?.string));
    try testing.expectEqualStrings("display=0 scale=2 size=1280x720", text(res));

    // `display` picks the screen: 1920x1080 at 1.5.
    const second = try h.call("screenshot", "{\"display\":1}");
    try testing.expectEqualStrings("display=1 scale=1.5 size=1280x720", text(second));
    try testing.expectEqual([2]u16{ 1280, 720 }, try jpegSize(h.arena.allocator(), block(second, 0).get("data").?.string));

    // Default display: the foreground window's.
    h.backend.foreground = 1;
    try expectContains(text(try h.call("screenshot", "{}")), "display=1");

    const bad = try h.call("screenshot", "{\"display\":5}");
    try testing.expect(isError(bad));
    try expectContains(text(bad), "écrans valides 0..1");
}

test "the long side follows --screenshot-size and never exceeds 1920" {
    for ([_]u32{ 1024, 1920 }) |size| {
        var backend: Fake = .{};
        var server: Server = .init(testing.allocator, testing.io, &backend, .{ .screenshot_size = size });
        defer server.deinit();
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\",\"arguments\":{}}}", &out.writer);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), out.written(), .{});
        const res = v.object.get("result").?.object;
        const dims = try jpegSize(arena.allocator(), block(res, 0).get("data").?.string);
        try testing.expectEqual(@as(u16, @intCast(size)), dims[0]);
        try testing.expect(@max(dims[0], dims[1]) <= 1920);
    }
}

test "screenshot reports a capture failure as isError with the backend's message" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.capture_failure = "Bureau sécurisé actif (UAC ou verrouillage) : capture impossible, réessaie après sa fermeture";
    const res = try h.call("screenshot", "{}");
    try testing.expect(isError(res));
    try testing.expectEqualStrings(h.backend.capture_failure.?, text(res));
}

test "steady-state screenshots allocate nothing from the backing allocator" {
    var counter: CountingAllocator = .init(testing.allocator);
    var h: Harness = .{};
    h.init(counter.allocator());
    defer h.deinit();
    for (0..3) |_| _ = try h.call("screenshot", "{}");
    const warm = counter.count();
    for (0..10) |_| try testing.expect(!isError(try h.call("screenshot", "{}")));
    try testing.expectEqual(warm, counter.count());
}

test "zoom returns the region at physical resolution and rejects invalid regions" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("screenshot", "{}");
    // 640x360 screenshot pixels = 1280x720 physical, the long side cap.
    const res = try h.call("zoom", "{\"region\":[0,0,640,360]}");
    try testing.expect(!isError(res));
    try testing.expectEqual([2]u16{ 1280, 720 }, try jpegSize(h.arena.allocator(), block(res, 0).get("data").?.string));
    try testing.expectEqualStrings("display=0 region=0,0,640,360 size=1280x720", text(res));
    // A small region keeps physical pixels: 50x40 -> 100x80.
    const small = try h.call("zoom", "{\"region\":[10,10,60,50]}");
    try testing.expectEqual([2]u16{ 100, 80 }, try jpegSize(h.arena.allocator(), block(small, 0).get("data").?.string));
    // The full screen is capped at 1280 px.
    const full = try h.call("zoom", "{\"region\":[0,0,1280,720]}");
    try testing.expectEqual([2]u16{ 1280, 720 }, try jpegSize(h.arena.allocator(), block(full, 0).get("data").?.string));

    for ([_][]const u8{ "[100,100,50,50]", "[10,10,10,20]", "[0,0,1281,10]", "[-1,0,10,10]" }) |region| {
        const args = try std.fmt.allocPrint(h.arena.allocator(), "{{\"region\":{s}}}", .{region});
        const bad = try h.call("zoom", args);
        try testing.expect(isError(bad));
        try expectContains(text(bad), "bornes valides 0..1280 x 0..720");
    }
}

test "clicks map screenshot pixels to physical desktop pixels, secondary display included" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("screenshot", "{}");
    try testing.expect(!isError(try h.call("left_click", "{\"coordinate\":[640,360]}")));
    try testing.expectEqual(@as(usize, 3), h.backend.mouse_len);
    try testing.expectEqual([2]i32{ 1281, 721 }, h.backend.mouse[0].move);
    try testing.expectEqual(.left, h.backend.mouse[1].down);
    try testing.expectEqual(.left, h.backend.mouse[2].up);

    // After a screenshot of display 1 (x from -1920), coordinates refer to it.
    _ = try h.call("screenshot", "{\"display\":1}");
    h.backend.mouse_len = 0;
    _ = try h.call("right_click", "{\"coordinate\":[0,0]}");
    try testing.expectEqual([2]i32{ -1920, 200 }, h.backend.mouse[0].move);
    try testing.expectEqual(.right, h.backend.mouse[1].down);
    h.backend.mouse_len = 0;
    _ = try h.call("triple_click", "{\"coordinate\":[1279,719]}");
    try testing.expectEqual(@as(usize, 7), h.backend.mouse_len);
    try testing.expectEqual([2]i32{ -1, 1279 }, h.backend.mouse[0].move);
}

test "an out-of-screen coordinate is refused with the valid bounds and no movement" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("screenshot", "{}");
    for ([_][]const u8{ "left_click", "mouse_move", "double_click" }) |tool| {
        const res = try h.call(tool, "{\"coordinate\":[1280,10]}");
        try testing.expect(isError(res));
        try expectContains(text(res), "bornes valides 0..1279 x 0..719");
    }
    const drag = try h.call("left_click_drag", "{\"start_coordinate\":[10,10],\"coordinate\":[10,900]}");
    try testing.expect(isError(drag));
    try testing.expectEqual(@as(usize, 0), h.backend.mouse_len);
}

test "an elevated target is refused before any injection (UIPI)" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.elevated = true;
    for ([_][2][]const u8{ .{ "left_click", "{\"coordinate\":[5,5]}" }, .{ "key", "{\"text\":\"Return\"}" }, .{ "type", "{\"text\":\"x\"}" }, .{ "scroll", "{\"scroll_direction\":\"up\",\"scroll_amount\":1}" } }) |c| {
        const res = try h.call(c[0], c[1]);
        try testing.expect(isError(res));
        try expectContains(text(res), "Fenêtre élevée : injection bloquée par UIPI");
    }
    try testing.expectEqual(@as(usize, 0), h.backend.mouse_len);
    try testing.expectEqual(@as(usize, 0), h.backend.key_len);
    try testing.expectEqual(@as(usize, 0), h.backend.typed_len);
}

test "a drag that drops onto an elevated window is refused before any injection" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("screenshot", "{}");
    // Screenshot pixel (640, 360) of the 2560x1440 display is physical (1281, 721).
    h.backend.elevated_at = .{ 1281, 721 };
    const res = try h.call("left_click_drag", "{\"start_coordinate\":[10,10],\"coordinate\":[640,360],\"text\":\"shift\"}");
    try testing.expect(isError(res));
    try expectContains(text(res), "Fenêtre élevée : injection bloquée par UIPI");
    try testing.expectEqual(@as(usize, 0), h.backend.mouse_len);
    try testing.expectEqual(@as(usize, 0), h.backend.key_len);
}

test "click modifiers are held around the click and unknown modifiers send nothing" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("left_click", "{\"coordinate\":[5,5],\"text\":\"ctrl+shift\"}");
    try testing.expectEqual(@as(usize, 4), h.backend.key_len);
    try testing.expectEqual(.press, h.backend.key_calls[0].action);
    try testing.expectEqual(.ctrl, h.backend.key_calls[0].combo.key.key);
    try testing.expectEqual(.shift, h.backend.key_calls[1].combo.key.key);
    try testing.expectEqual(.release, h.backend.key_calls[3].action);
    try testing.expectEqual(@as(u32, 0), h.backend.held);

    h.backend.mouse_len = 0;
    const bad = try h.call("left_click", "{\"coordinate\":[5,5],\"text\":\"hyper\"}");
    try testing.expect(isError(bad));
    try expectContains(text(bad), "shift, ctrl, alt, super");
    try testing.expectEqual(@as(usize, 0), h.backend.mouse_len);
}

test "scroll sends wheel clicks in the requested direction" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("scroll", "{\"scroll_direction\":\"down\",\"scroll_amount\":3,\"coordinate\":[10,10]}");
    const v = h.backend.mouse[1].wheel;
    try testing.expect(!v.horizontal and v.clicks == -3);
    _ = try h.call("scroll", "{\"scroll_direction\":\"right\",\"scroll_amount\":2}");
    const r = h.backend.mouse[3].wheel;
    try testing.expect(r.horizontal and r.clicks == 2);
}

test "cursor_position reports screenshot pixels and the display" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.cursor = .{ 101, 100 };
    try testing.expectEqualStrings("x=50 y=50 display=0", text(try h.call("cursor_position", "{}")));
    h.backend.cursor = .{ -1920, 200 };
    try testing.expectEqualStrings("x=0 y=0 display=1", text(try h.call("cursor_position", "{}")));
}

test "key sends the parsed combination repeat times and suggests names for unknown keys" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    try testing.expect(!isError(try h.call("key", "{\"text\":\"ctrl+s\",\"repeat\":3}")));
    try testing.expectEqual(@as(usize, 3), h.backend.key_len);
    const c = h.backend.key_calls[0];
    try testing.expect(c.combo.mods.ctrl and c.combo.key.char == 's' and c.action == .tap);

    const bad = try h.call("key", "{\"text\":\"ctrl+Retrun\"}");
    try testing.expect(isError(bad));
    try expectContains(text(bad), "Touche inconnue `Retrun`");
    try expectContains(text(bad), "Return");
    // Five names, comma separated.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, text(bad), ", "));

    // A character outside the layout is typed when it has no modifier.
    h.backend.unmappable = 0x263A;
    try testing.expect(!isError(try h.call("key", "{\"text\":\"☺\"}")));
    try testing.expectEqual(@as(u16, 0x263A), h.backend.typed[0]);
    try testing.expect(isError(try h.call("key", "{\"text\":\"ctrl+☺\"}")));
}

test "type sends UTF-16 in batches of at most 64 events, emoji and new lines included" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    try testing.expect(!isError(try h.call("type", "{\"text\":\"é😀\\nab\\r\\nc\"}")));
    try testing.expectEqualSlices(u16, &.{ 0xE9, 0xD83D, 0xDE00, 'a', 'b', 'c' }, h.backend.typed[0..h.backend.typed_len]);
    // Each new line (\n and \r\n) is one Return key.
    try testing.expectEqual(@as(usize, 2), h.backend.key_len);
    try testing.expectEqual(.enter, h.backend.key_calls[0].combo.key.key);

    h.backend.typed_len = 0;
    // 900 units; surrogate pairs must not be split across batches.
    const long = comptime blk: {
        @setEvalBranchQuota(10_000);
        var s: []const u8 = "";
        for (0..300) |_| s = s ++ "\u{1F600}a";
        break :blk s;
    };
    const args = try std.fmt.allocPrint(h.arena.allocator(), "{{\"text\":\"{s}\"}}", .{long});
    try testing.expect(!isError(try h.call("type", args)));
    try testing.expectEqual(@as(usize, 900), h.backend.typed_len);
    try testing.expect(h.backend.largest_type_batch <= 64);
    for (0..300) |i| try testing.expectEqual(@as(u16, 0xD83D), h.backend.typed[i * 3]);
}

test "hold_key presses then releases, with progress every second when asked" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    try testing.expect(!isError(try h.call("hold_key", "{\"text\":\"shift\",\"duration\":0.05}")));
    try testing.expectEqual(.press, h.backend.key_calls[0].action);
    try testing.expectEqual(.release, h.backend.key_calls[1].action);
    try testing.expectEqual(@as(u32, 0), h.backend.held);

    h.out.clearRetainingCapacity();
    try h.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"tools/call\",\"params\":{\"name\":\"wait\",\"arguments\":{\"duration\":2},\"_meta\":{\"progressToken\":\"p1\"}}}", &h.out.writer);
    const written = h.out.written();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, written, "\"method\":\"notifications/progress\""));
    try expectContains(written, "\"progressToken\":\"p1\",\"progress\":1,\"total\":2");
    try expectContains(written, "\"id\":99");
}

test "an error result releases held inputs" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("left_mouse_down", "{}");
    try testing.expectEqual(@as(u32, 1), h.backend.held);
    const released = h.backend.release_calls;
    try testing.expect(isError(try h.call("key", "{\"text\":\"Retrun\"}")));
    try testing.expectEqual(@as(u32, 0), h.backend.held);
    try testing.expectEqual(released + 1, h.backend.release_calls);
}

test "end of stdin during hold_key or left_mouse_down releases within 50 ms" {
    const Step = mcp_test.Step;
    var backend: Fake = .{};
    var in_buf: [64 * 1024]u8 = undefined;
    const steps = [_]Step{
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"left_mouse_down\",\"arguments\":{}}}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"hold_key\",\"arguments\":{\"text\":\"shift\",\"duration\":300}}}\n" },
        .{ .wait_ms = 50 },
    };
    var reader: mcp_test.ScriptReader = .init(&in_buf, &steps, testing.io);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var server: Server = .init(testing.allocator, testing.io, &backend, .{});
    defer server.deinit();
    try server.serve(&reader.interface, &out.writer);
    const elapsed = @as(i64, @intCast(@import("timing.zig").now(testing.io))) - reader.eof_ns.load(.acquire);
    try testing.expectEqual(@as(u32, 0), backend.held);
    try testing.expect(elapsed < 50 * std.time.ns_per_ms);
}

test "notifications/cancelled during hold_key releases the key and suppresses the response" {
    const Step = mcp_test.Step;
    var backend: Fake = .{};
    var in_buf: [64 * 1024]u8 = undefined;
    const steps = [_]Step{
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"hold_key\",\"arguments\":{\"text\":\"ctrl\",\"duration\":300}}}\n" },
        .{ .wait_ms = 50 },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":7}}\n" },
        .{ .wait_ms = 100 },
    };
    var reader: mcp_test.ScriptReader = .init(&in_buf, &steps, testing.io);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var server: Server = .init(testing.allocator, testing.io, &backend, .{});
    defer server.deinit();
    try server.serve(&reader.interface, &out.writer);
    try testing.expectEqual(@as(u32, 0), backend.held);
    // Released by hold_key itself on cancellation, before end of stdin.
    try testing.expectEqual(.release, backend.key_calls[1].action);
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "window_list maps rectangles to screenshot pixels and hides cloaked windows by default" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const res = text(try h.call("window_list", "{}"));
    var lines = std.mem.splitScalar(u8, res, '\n');
    try testing.expectEqualStrings("0x1a2b \"Bloc-notes\" notepad.exe pid=4242 display=0 @50,40,600,400 z=0", lines.next().?);
    try testing.expectEqualStrings("0x3c4d \"Administrateur : PowerShell\" WindowsTerminal.exe pid=77 display=1 @80,66,600,401 z=1 {elevated}", lines.next().?);
    try testing.expect(lines.next() == null);
    try expectContains(text(try h.call("window_list", "{\"include_hidden\":true}")), "{cloaked}");
}

test "window_focus activates by handle and reports closed windows" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    try testing.expect(!isError(try h.call("window_focus", "{\"window\":\"0x1a2b\"}")));
    try testing.expectEqual(@as(?u64, 0x1a2b), h.backend.focused);
    const closed = try h.call("window_focus", "{\"window\":\"0xdead\"}");
    try testing.expect(isError(closed));
    try testing.expectEqualStrings("Fenêtre fermée : rappelle window_list", text(closed));
    try testing.expect(isError(try h.call("window_focus", "{\"window\":\"zz\"}")));
}
