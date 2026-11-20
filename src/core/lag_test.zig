//! US-066 (FR-47, PRD 1.8) through the real dispatcher against the fake
//! backend: the tree of a covered Chromium page is one action behind
//! (`Fake.ui_lag`), so a `ui_act` on an element of its web document says
//! "délivré, effet non vérifiable" with the frozen-tree line, and `check`
//! and `uncheck`, which decide from the state they read, are refused.
//! Nothing changes for a window in view, a strip in view, VS Code, the
//! browser's own interface or any other window.

const std = @import("std");
const testing = std.testing;
const t = @import("tools_test.zig");
const a11y = @import("a11y.zig");
const audit = @import("audit.zig");
const display = @import("display.zig");
const uitree = @import("uitree.zig");
const Element = uitree.Element;

const frame: display.Rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 };
const r: display.Rect = .{ .x = 200, .y = 200, .w = 100, .h = 30 };

/// A Chromium window: the browser's own toolbar, then the web document.
const web_tree = [_]Element{
    .{ .key = 300, .depth = 0, .role = .window, .name = "Page", .rect = frame },
    .{ .key = 301, .depth = 1, .role = .toolbar, .name = "Barre", .rect = r },
    .{ .key = 302, .depth = 2, .role = .checkbox, .name = "Favori", .actions = .{ .toggle = true }, .rect = r },
    .{ .key = 303, .depth = 2, .role = .button, .name = "Retour", .actions = .{ .invoke = true }, .rect = r },
    .{ .key = 310, .depth = 1, .role = .document, .name = "Formulaire", .scroll = .{ .v = 100 }, .rect = frame },
    .{ .key = 311, .depth = 2, .role = .checkbox, .name = "Recevoir", .states = .{ .checked = true }, .actions = .{ .toggle = true }, .rect = r },
    .{ .key = 312, .depth = 2, .role = .edit, .name = "Nom", .value = "Arthur", .actions = .{ .value = true }, .rect = r },
    .{ .key = 313, .depth = 2, .role = .combobox, .name = "Pays", .states = .{ .collapsed = true }, .actions = .{ .expand_collapse = true }, .rect = r },
    .{ .key = 314, .depth = 3, .role = .listitem, .name = "Suisse", .actions = .{ .select = true }, .rect = r },
    .{ .key = 315, .depth = 3, .role = .listitem, .name = "France", .states = .{ .selected = true }, .actions = .{ .select = true }, .rect = r },
    .{ .key = 316, .depth = 2, .role = .button, .name = "Envoyer", .actions = .{ .invoke = true }, .rect = r },
    .{ .key = 317, .depth = 2, .role = .pane, .name = "Liste", .scroll = .{ .v = 100 }, .rect = r },
};

fn win(handle: u64, exe: []const u8, rect: display.Rect) display.WindowInfo {
    return .{ .handle = handle, .title = "Fenêtre", .exe = exe, .pid = @intCast(handle & 0xffff), .rect = rect, .elevated = false, .minimized = false, .cloaked = false };
}

/// The target 0x1a2b of `exe`, entirely under a window of another process.
fn covered(exe: []const u8) [2]display.WindowInfo {
    return .{ win(0xc0, "explorer.exe", .{ .x = 0, .y = 0, .w = 2000, .h = 1000 }), win(0x1a2b, exe, frame) };
}

/// The same target with nothing above it.
fn visible(exe: []const u8) [2]display.WindowInfo {
    return .{ win(0xc0, "explorer.exe", .{ .x = 1400, .y = 0, .w = 300, .h = 300 }), win(0x1a2b, exe, frame) };
}

/// Under the same window but for a strip of 16 px on its right.
fn strip(exe: []const u8) [2]display.WindowInfo {
    return .{ win(0xc0, "explorer.exe", .{ .x = 0, .y = 0, .w = 1284, .h = 1000 }), win(0x1a2b, exe, frame) };
}

const Fixture = struct {
    h: t.Harness = .{},
    desk: [2]display.WindowInfo = undefined,

    fn init(f: *Fixture, desk: [2]display.WindowInfo, options: @import("mcp.zig").Options) !void {
        f.h.initWith(testing.allocator, options);
        f.h.server.session.verify_ms = 60;
        f.desk = desk;
        f.h.backend.windows = &f.desk;
        f.h.backend.chromium_windows = &.{0x1a2b};
        f.h.backend.ui_elements = &web_tree;
        f.h.backend.ui_lag = true;
        _ = try f.tree();
    }

    fn deinit(f: *Fixture) void {
        f.h.deinit();
    }

    fn tree(f: *Fixture) ![]const u8 {
        return t.text(try f.h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    }

    /// The id `ui_find` gives the element of `query`.
    fn id(f: *Fixture, query: []const u8) ![]const u8 {
        const a = f.h.arena.allocator();
        const found = t.text(try f.h.call("ui_find", try std.fmt.allocPrint(a, "{{\"query\":\"{s}\",\"window\":\"0x1a2b\"}}", .{query})));
        var lines = std.mem.splitScalar(u8, found, '\n');
        _ = lines.next();
        const line = lines.next() orelse return error.TestUnexpectedResult;
        return a.dupe(u8, line[0..std.mem.indexOfScalar(u8, line, ' ').?]);
    }

    fn act(f: *Fixture, query: []const u8, action: []const u8, value: ?[]const u8) !std.json.ObjectMap {
        const a = f.h.arena.allocator();
        const e = try f.id(query);
        const args = if (value) |v|
            try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"action\":\"{s}\",\"value\":\"{s}\",\"observe\":\"none\"}}", .{ e, action, v })
        else
            try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"action\":\"{s}\",\"observe\":\"none\"}}", .{ e, action });
        return f.h.call("ui_act", args);
    }
};

const Case = struct { query: []const u8, action: []const u8, value: ?[]const u8 = null };

const unverifiable = " : délivré, effet non vérifiable";

test "a ui_act under a covered Chromium page's web document says delivered, effect unknown, with the frozen-tree line" {
    inline for (.{ .a11y, .background }) |mode| {
        for ([_]Case{
            .{ .query = "role:checkbox recevoir", .action = "toggle" },
            .{ .query = "role:edit nom", .action = "set_value", .value = "Jean" },
            .{ .query = "role:combobox pays", .action = "expand" },
            .{ .query = "role:listitem suisse", .action = "select" },
            .{ .query = "role:combobox pays", .action = "select", .value = "Suisse" },
            .{ .query = "role:button envoyer", .action = "invoke" },
        }) |c| {
            var f: Fixture = .{};
            try f.init(covered("chrome.exe"), .{ .mode = mode });
            defer f.deinit();
            const res = try f.act(c.query, c.action, c.value);
            try testing.expect(!t.isError(res));
            const text = t.text(res);
            const head = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
            try t.expectContains(head, unverifiable);
            try testing.expect(std.mem.indexOf(u8, text, "vérifié (") == null);
            try testing.expect(std.mem.indexOf(u8, text, "contredit") == null);
            try testing.expect(std.mem.endsWith(u8, text, "\n" ++ a11y.frozen_covered));
            // The action left all the same.
            try testing.expect(f.h.backend.ui_op_len > 0);
        }
    }
}

test "on that tree a verdict would be wrong: a toggle reads back the state before it" {
    // In view, with the same one-action lag, the read-back denies an
    // action that worked: what US-066 keeps from the model on a covered page.
    var f: Fixture = .{};
    try f.init(visible("chrome.exe"), .{});
    defer f.deinit();
    const res = try f.act("role:checkbox recevoir", "toggle", null);
    try t.expectContains(t.text(res), ": contredit, état lu coché");
    // Covered, the same call says nothing it cannot know.
    f.desk = covered("chrome.exe");
    try t.expectContains(t.text(try f.act("role:checkbox recevoir", "toggle", null)), unverifiable);
}

test "check and uncheck are refused before any action on a covered Chromium page" {
    for ([_][]const u8{ "check", "uncheck" }) |action| {
        var f: Fixture = .{};
        try f.init(covered("chrome.exe"), .{});
        defer f.deinit();
        const e = try f.id("role:checkbox recevoir");
        const ops = f.h.backend.ui_op_len;
        const res = try f.h.call("ui_act", try std.fmt.allocPrint(f.h.arena.allocator(), "{{\"id\":\"{s}\",\"action\":\"{s}\",\"observe\":\"none\"}}", .{ e, action }));
        try testing.expect(t.isError(res));
        try testing.expectEqualStrings(try std.fmt.allocPrint(f.h.arena.allocator(), "Précondition non remplie : {s} est dans une page Chromium recouverte, dont l'arbre a une action de retard : son état lu n'est pas le sien. Laisse une bande d'au moins 16 px visible avec window_set, puis réessaie. Aucune action exécutée.", .{e}), t.text(res));
        try testing.expectEqual(ops, f.h.backend.ui_op_len);
    }
}

test "nothing changes in view, with a strip in view, for VS Code, for the browser's interface and for another window" {
    const Where = struct { desk: [2]display.WindowInfo, query: []const u8, chromium: bool = true };
    for ([_]Where{
        .{ .desk = visible("chrome.exe"), .query = "role:edit nom" },
        .{ .desk = strip("chrome.exe"), .query = "role:edit nom" },
        .{ .desk = covered("Code.exe"), .query = "role:checkbox recevoir" },
        .{ .desk = covered("chrome.exe"), .query = "role:checkbox favori" },
        .{ .desk = covered("notepad.exe"), .query = "role:edit nom", .chromium = false },
    }) |c| {
        var f: Fixture = .{};
        try f.init(c.desk, .{});
        defer f.deinit();
        f.h.backend.ui_lag = false;
        if (!c.chromium) {
            f.h.backend.chromium_windows = &.{};
            _ = try f.tree();
        }
        const action: []const u8 = if (std.mem.indexOf(u8, c.query, "edit") != null) "set_value" else "toggle";
        const res = try f.act(c.query, action, if (std.mem.eql(u8, action, "set_value")) "Jean" else null);
        const text = t.text(res);
        try t.expectContains(text, ": vérifié (");
        try testing.expect(std.mem.indexOf(u8, text, "Fenêtre recouverte") == null);
        // `check` acts as before.
        if (std.mem.eql(u8, action, "toggle")) try testing.expect(!t.isError(try f.act(c.query, "check", null)));
    }
}

test "the decision reads the z-order for a web element of a Chromium window only" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.server.session.verify_ms = 60;
    _ = try h.call("ui_tree", "{}");
    const reads = h.backend.layer_reads;
    try t.expectContains(t.text(try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"toggle\",\"observe\":\"none\"}")), ": vérifié");
    try testing.expectEqual(reads, h.backend.layer_reads);

    var f: Fixture = .{};
    try f.init(covered("chrome.exe"), .{});
    defer f.deinit();
    const e = try f.id("role:checkbox recevoir");
    const before = f.h.backend.layer_reads;
    _ = try f.h.call("ui_act", try std.fmt.allocPrint(f.h.arena.allocator(), "{{\"id\":\"{s}\",\"action\":\"toggle\",\"observe\":\"none\"}}", .{e}));
    try testing.expectEqual(before + 1, f.h.backend.layer_reads);
}

test "an element reached through ui_tree root or ui_find alone keeps its web flag" {
    {
        var f: Fixture = .{};
        try f.init(covered("chrome.exe"), .{});
        defer f.deinit();
        const doc = try f.id("role:document formulaire");
        _ = try f.h.call("ui_tree", try std.fmt.allocPrint(f.h.arena.allocator(), "{{\"root\":\"{s}\"}}", .{doc}));
        try t.expectContains(t.text(try f.act("role:checkbox recevoir", "toggle", null)), unverifiable);
    }
    // No ui_tree at all: the ids come from ui_find.
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.server.session.verify_ms = 60;
    var desk = covered("chrome.exe");
    h.backend.windows = &desk;
    h.backend.chromium_windows = &.{0x1a2b};
    h.backend.ui_elements = &web_tree;
    h.backend.ui_lag = true;
    const found = t.text(try h.call("ui_find", "{\"query\":\"role:checkbox recevoir\",\"window\":\"0x1a2b\"}"));
    var lines = std.mem.splitScalar(u8, found, '\n');
    _ = lines.next();
    const line = lines.next().?;
    const e = line[0..std.mem.indexOfScalar(u8, line, ' ').?];
    try t.expectContains(t.text(try h.call("ui_act", try std.fmt.allocPrint(h.arena.allocator(), "{{\"id\":\"{s}\",\"action\":\"toggle\",\"observe\":\"none\"}}", .{e}))), unverifiable);
}

test "the audit records the unverifiable verdict, and check refused as a refusal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: audit.Audit = .{ .io = testing.io, .dir = tmp.dir };
    defer if (log.file) |file| file.close(testing.io);
    var f: Fixture = .{};
    try f.init(covered("chrome.exe"), .{ .audit = &log });
    defer f.deinit();
    var buf: [16384]u8 = undefined;
    _ = try f.act("role:checkbox recevoir", "toggle", null);
    try t.expectContains(try lastLine(&tmp, &buf), "\"result\":\"ok\",\"verdict\":\"unverifiable\"}");
    _ = try f.act("role:checkbox recevoir", "check", null);
    const refused = try lastLine(&tmp, &buf);
    try t.expectContains(refused, "\"result\":\"error\"}");
    try testing.expect(std.mem.indexOf(u8, refused, "verdict") == null);
}

fn lastLine(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const data = try tmp.dir.readFile(testing.io, audit.file_name, buf);
    const lines = std.mem.trimEnd(u8, data, "\n");
    return lines[(std.mem.lastIndexOfScalar(u8, lines, '\n') orelse return lines) + 1 ..];
}

test "underDocument: nested documents, several roots, a subtree under a document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = [_]Element{
        .{ .key = 1, .depth = 0, .role = .window, .rect = r },
        .{ .key = 2, .depth = 1, .role = .document, .rect = r },
        .{ .key = 3, .depth = 2, .role = .document, .rect = r },
        .{ .key = 4, .depth = 3, .role = .button, .rect = r },
        .{ .key = 5, .depth = 2, .role = .button, .rect = r },
        .{ .key = 6, .depth = 1, .role = .toolbar, .rect = r },
        .{ .key = 7, .depth = 0, .role = .window, .rect = r },
        .{ .key = 8, .depth = 1, .role = .button, .rect = r },
    };
    const under = try uitree.underDocument(arena.allocator(), &els, false);
    // A document is part of its own page: its scroll position lags too.
    try testing.expectEqualSlices(bool, &.{ false, true, true, true, true, false, false, false }, under);
    const sub = try uitree.underDocument(arena.allocator(), els[5..6], true);
    try testing.expectEqualSlices(bool, &.{true}, sub);
}

test "a lagging tree is read back once, not polled for 400 ms" {
    var f: Fixture = .{};
    try f.init(covered("chrome.exe"), .{});
    defer f.deinit();
    f.h.server.session.verify_ms = 400;
    try t.expectContains(t.text(try f.act("role:checkbox recevoir", "toggle", null)), unverifiable);
    try testing.expect(f.h.server.session.verify_ns < 50 * std.time.ns_per_ms);
}

test "a scroll leaves even where the lagging tree says the end is reached" {
    // The document itself scrolls the page: its position lags as its
    // descendants' states do (decision 0013, pending scroll at 28.7 %).
    for ([_][]const u8{ "role:pane liste", "role:document formulaire" }) |query| for ([_][]const u8{ "down", "bottom" }) |where| {
        var f: Fixture = .{};
        try f.init(covered("chrome.exe"), .{});
        defer f.deinit();
        const ops = f.h.backend.ui_op_len;
        const text = t.text(try f.act(query, "scroll", where));
        try t.expectContains(text, unverifiable);
        try testing.expect(std.mem.indexOf(u8, text, "déjà") == null);
        try testing.expect(f.h.backend.ui_op_len > ops);
    };
    // In view, the same position is the end: nothing leaves.
    var f: Fixture = .{};
    try f.init(visible("chrome.exe"), .{});
    defer f.deinit();
    try t.expectContains(t.text(try f.act("role:pane liste", "scroll", "down")), "déjà en bas");
}
