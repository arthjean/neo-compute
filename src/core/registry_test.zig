//! Tests of the comptime registry: schema derivation, the toolset fixture,
//! annotations, and argument validation.

const std = @import("std");
const testing = std.testing;
const registry = @import("registry.zig");
const tools = @import("tools.zig");
const mcp = @import("mcp.zig");
const Fake = @import("../backend/fake.zig").Fake;
const timing = @import("timing.zig");

fn parse(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

const Sample = struct {
    count: u8,
    ratio: f32,
    on: bool,
    mode: enum { fast, slow },
    maybe: ?i32 = null,
    name: []const u8,
    ids: []const u16,
    pair: [2]i32,
    level: u8 = 3,
    pub const field_info = .{ .count = .{ .minimum = 1, .maximum = 9, .description = "How many" } };
};

test "inputSchema is derived from the Args struct" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try parse(a, comptime registry.inputSchema(Sample));
    const expected = try parse(a,
        \\{"type":"object","properties":{
        \\ "count":{"type":"integer","description":"How many","minimum":1,"maximum":9},
        \\ "ratio":{"type":"number"},
        \\ "on":{"type":"boolean"},
        \\ "mode":{"type":"string","enum":["fast","slow"]},
        \\ "maybe":{"type":"integer"},
        \\ "name":{"type":"string"},
        \\ "ids":{"type":"array","items":{"type":"integer"}},
        \\ "pair":{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":2},
        \\ "level":{"type":"integer"}},
        \\ "required":["count","ratio","on","mode","name","ids","pair"]}
    );
    try expectJsonEqual(expected, schema);
}

fn expectJsonEqual(expected: std.json.Value, actual: std.json.Value) !void {
    var a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try std.json.Stringify.value(expected, .{}, &a.writer);
    try std.json.Stringify.value(actual, .{}, &b.writer);
    try testing.expectEqualStrings(a.written(), b.written());
}

const Reg = registry.Registry(tools.all);

fn toolMap(arena: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(std.json.Value) {
    const list = try parse(arena, Reg.list_result);
    var map: std.StringArrayHashMapUnmanaged(std.json.Value) = .empty;
    for (list.object.get("tools").?.array.items) |t| try map.put(arena, t.object.get("name").?.string, t);
    return map;
}

/// Compares the parts of a schema that define the contract (types, shapes,
/// enums, bounds, required), ignoring descriptions.
fn expectSameContract(name: []const u8, want: std.json.Value, got: std.json.Value) !void {
    const wp = want.object.get("properties").?.object;
    const gp = got.object.get("properties").?.object;
    // Properties absent from the fixture are neo-compute extensions and
    // must be optional (FR-01).
    var extra = gp.iterator();
    while (extra.next()) |e| {
        if (wp.get(e.key_ptr.*) != null) continue;
        if (got.object.get("required")) |req| for (req.array.items) |r| {
            if (std.mem.eql(u8, r.string, e.key_ptr.*)) {
                std.debug.print("{s}: extension `{s}` must be optional\n", .{ name, e.key_ptr.* });
                return error.TestExpectedEqual;
            }
        };
    }
    var it = wp.iterator();
    while (it.next()) |e| {
        const g = gp.get(e.key_ptr.*) orelse {
            std.debug.print("{s}: missing property {s}\n", .{ name, e.key_ptr.* });
            return error.TestExpectedEqual;
        };
        for ([_][]const u8{ "type", "enum", "items", "minItems", "maxItems", "minimum", "maximum" }) |k| {
            const wv = e.value_ptr.object.get(k);
            const gv = g.object.get(k);
            if ((wv == null) != (gv == null)) {
                std.debug.print("{s}.{s}: `{s}` presence differs\n", .{ name, e.key_ptr.*, k });
                return error.TestExpectedEqual;
            }
            if (wv) |w| try expectJsonEqual(w, gv.?);
        }
    }
    const empty: std.json.Value = .{ .array = .init(testing.allocator) };
    const wr = want.object.get("required") orelse empty;
    const gr = got.object.get("required") orelse empty;
    try testing.expectEqual(wr.array.items.len, gr.array.items.len);
    for (wr.array.items) |r| {
        const found = for (gr.array.items) |x| {
            if (std.mem.eql(u8, x.string, r.string)) break true;
        } else false;
        if (!found) {
            std.debug.print("{s}: `{s}` should be required\n", .{ name, r.string });
            return error.TestExpectedEqual;
        }
    }
}

test "the 17 computer_toolset_20260801 members match tests/fixtures/toolset_20260801.json" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try parse(a, @embedFile("toolset_fixture"));
    const want = fixture.object.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 17), want.len);
    try testing.expectEqual(@as(usize, 17), tools.toolset.len);
    const map = try toolMap(a);
    inline for (tools.toolset, 0..) |T, i| {
        const w = want[i];
        try testing.expectEqualStrings(w.object.get("name").?.string, T.name);
        const g = map.get(T.name).?;
        try expectSameContract(T.name, w.object.get("inputSchema").?, g.object.get("inputSchema").?);
    }
}

test "observation tools are read-only and idempotent; core tools are always loaded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const map = try toolMap(arena.allocator());
    const observers = [_][]const u8{ "screenshot", "zoom", "cursor_position", "ui_tree", "ui_find", "window_list", "registry_read" };
    for (observers) |n| {
        const ann = map.get(n).?.object.get("annotations").?.object;
        try testing.expect(ann.get("readOnlyHint").?.bool);
        try testing.expect(ann.get("idempotentHint").?.bool);
    }
    const always = [_][]const u8{ "screenshot", "left_click", "type", "key", "scroll", "ui_tree", "ui_act" };
    for (always) |n| {
        const meta = map.get(n).?.object.get("_meta").?.object;
        try testing.expect(meta.get("anthropic/alwaysLoad").?.bool);
    }
    var it = map.iterator();
    while (it.next()) |e| {
        const is_observer = for (observers) |n| {
            if (std.mem.eql(u8, n, e.key_ptr.*)) break true;
        } else false;
        if (!is_observer) if (e.value_ptr.object.get("annotations")) |ann| try testing.expect(!ann.object.get("readOnlyHint").?.bool);
        const is_always = for (always) |n| {
            if (std.mem.eql(u8, n, e.key_ptr.*)) break true;
        } else false;
        try testing.expectEqual(is_always, e.value_ptr.object.get("_meta") != null);
    }
}

test "tool definitions stay within the token and description budgets" {
    try testing.expectEqual(@as(usize, 1500), registry.max_always_load_tokens);
    try testing.expectEqual(@as(usize, 4500), registry.max_definition_tokens);
    try testing.expect(Reg.always_load_tokens <= registry.max_always_load_tokens);
    try testing.expect(Reg.definition_tokens <= registry.max_definition_tokens);
    try testing.expect(Reg.always_load_tokens < Reg.definition_tokens);
    inline for (tools.all) |T| try testing.expect(T.description.len <= registry.max_description_len);
    std.debug.print("tools/list: {d} bytes, about {d} tokens (limit {d}); alwaysLoad definitions about {d} tokens (limit {d})\n", .{
        Reg.list_result.len, Reg.definition_tokens, registry.max_definition_tokens, Reg.always_load_tokens, registry.max_always_load_tokens,
    });
}

test "the tools of the Windows-MCP parity PRD are never always loaded (FR-22)" {
    for ([_][]const u8{ "window_set", "app_launch", "clipboard", "registry_read" }) |n| {
        if (!Reg.has(n)) continue;
        try testing.expect(!Reg.alwaysLoaded(n));
    }
}

// A tool that records whether it ran, to prove invalid arguments never reach `run`.
const recorder = struct {
    pub const name = "recorder";
    pub const description = "Test tool.";
    pub const Args = struct {
        repeat: u32 = 1,
        direction: enum { up, down },
        point: ?[2]i32 = null,
        pub const field_info = .{ .repeat = .{ .minimum = 1, .maximum = 100 } };
    };
    pub fn run(ctx: anytype, args: Args) mcp.Result {
        _ = args;
        ctx.backend.held += 1;
        return mcp.Result.text("ran");
    }
};

fn callRecorder(arena: std.mem.Allocator, backend: *Fake, args_json: []const u8) !mcp.Result {
    var cancel: std.atomic.Value(bool) = .init(false);
    var timings: timing.Timings = .{};
    var session: mcp.Session = .init(testing.allocator, 1280);
    defer session.deinit();
    var ctx: mcp.Ctx(Fake) = .{ .arena = arena, .io = testing.io, .backend = backend, .cancel = &cancel, .timings = &timings, .session = &session };
    const v = try parse(arena, args_json);
    return registry.Registry(.{recorder}).call(&ctx, "recorder", v).?;
}

test "invalid arguments return isError naming the field and constraint, and run nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var backend: Fake = .{};
    const cases = [_]struct { args: []const u8, needles: []const []const u8 }{
        .{ .args = "{\"repeat\":0,\"direction\":\"up\"}", .needles = &.{ "repeat", "entre 1 et 100", "reçu 0" } },
        .{ .args = "{\"repeat\":101,\"direction\":\"up\"}", .needles = &.{ "repeat", "entre 1 et 100" } },
        .{ .args = "{\"direction\":\"diagonal\"}", .needles = &.{ "direction", "up, down" } },
        .{ .args = "{\"direction\":\"up\",\"repeat\":\"three\"}", .needles = &.{ "repeat", "entier" } },
        .{ .args = "{\"direction\":\"up\",\"point\":[1]}", .needles = &.{ "point", "tableau de 2" } },
        .{ .args = "{}", .needles = &.{ "direction", "requis" } },
        .{ .args = "{\"direction\":\"up\",\"extra\":1}", .needles = &.{ "extra", "inconnu" } },
    };
    for (cases) |c| {
        const r = try callRecorder(a, &backend, c.args);
        try testing.expect(r.is_error);
        const msg = r.content()[0].text;
        for (c.needles) |n| {
            if (std.mem.indexOf(u8, msg, n) == null) {
                std.debug.print("args {s}: message `{s}` lacks `{s}`\n", .{ c.args, msg, n });
                return error.TestExpectedEqual;
            }
        }
    }
    try testing.expectEqual(@as(u32, 0), backend.held);
    const ok = try callRecorder(a, &backend, "{\"direction\":\"down\",\"point\":[3,4]}");
    try testing.expect(!ok.is_error);
    try testing.expectEqual(@as(u32, 1), backend.held);
}

test "toolset validation errors through tools/call name the field (repeat 0, diagonal scroll, wrong type)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: std.atomic.Value(bool) = .init(false);
    var timings: timing.Timings = .{};
    var backend: Fake = .{};
    var session: mcp.Session = .init(testing.allocator, 1280);
    defer session.deinit();
    var ctx: mcp.Ctx(Fake) = .{ .arena = a, .io = testing.io, .backend = &backend, .cancel = &cancel, .timings = &timings, .session = &session };
    const cases = [_]struct { tool: []const u8, args: []const u8, field: []const u8 }{
        .{ .tool = "key", .args = "{\"text\":\"a\",\"repeat\":0}", .field = "repeat" },
        .{ .tool = "scroll", .args = "{\"scroll_direction\":\"diagonal\",\"scroll_amount\":1}", .field = "scroll_direction" },
        .{ .tool = "left_click", .args = "{\"coordinate\":\"10,20\"}", .field = "coordinate" },
        .{ .tool = "wait", .args = "{\"duration\":301}", .field = "duration" },
    };
    for (cases) |c| {
        const r = Reg.call(&ctx, c.tool, try parse(a, c.args)).?;
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content()[0].text, c.field) != null);
    }
}

test "arguments are parsed into the request arena only" {
    // parseArgs receives no allocator but the arena; backing that arena with
    // a small fixed buffer shows the whole parse fits in it.
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var arena: std.heap.ArenaAllocator = .init(fba.allocator());
    const a = arena.allocator();
    const v = try parse(a, "{\"direction\":\"up\",\"point\":[1,2],\"repeat\":7}");
    const parsed = registry.parseArgs(recorder.Args, a, v);
    try testing.expectEqual(@as(u32, 7), parsed.ok.repeat);
    try testing.expectEqual(@as(i32, 2), parsed.ok.point.?[1]);
}
