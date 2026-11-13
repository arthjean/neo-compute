//! EP-013 through the real dispatcher (`tools/call` JSON in, JSON-RPC line
//! out) against the fake backend: `check` and `uncheck`, the pattern chains,
//! semantic scrolling, slider values, selection by name, the wait for the
//! preconditions and the delivery verdict of `ui_act`.

const std = @import("std");
const testing = std.testing;
const t = @import("tools_test.zig");
const uitree = @import("uitree.zig");
const fake = @import("../backend/fake.zig");
const audit = @import("audit.zig");
const policy = @import("policy.zig");
const Element = uitree.Element;
const Harness = t.Harness;
const isError = t.isError;
const text = t.text;
const expectContains = t.expectContains;
const Tag = std.meta.Tag(uitree.Op);

const not_replayable = "L'action est partie : ne la rejoue pas sans relire l'arbre.";

/// A form on the primary display (physical pixels).
const form = [_]Element{
    .{ .key = 1, .depth = 0, .role = .window, .name = "Formulaire", .rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 } },
    .{ .key = 2, .depth = 1, .role = .checkbox, .name = "Abonné", .actions = .{ .toggle = true }, .rect = .{ .x = 200, .y = 120, .w = 200, .h = 30 } },
    .{ .key = 3, .depth = 1, .role = .button, .name = "Envoyer", .states = .{ .disabled = true }, .actions = .{ .invoke = true }, .rect = .{ .x = 200, .y = 160, .w = 200, .h = 30 } },
    .{ .key = 4, .depth = 1, .role = .slider, .name = "Volume", .range = .{ .value = 40, .min = 0, .max = 100 }, .rect = .{ .x = 200, .y = 200, .w = 200, .h = 30 } },
    .{ .key = 5, .depth = 1, .role = .combobox, .name = "Pays", .states = .{ .collapsed = true }, .actions = .{ .expand_collapse = true }, .rect = .{ .x = 200, .y = 240, .w = 200, .h = 30 } },
    .{ .key = 6, .depth = 2, .role = .listitem, .name = "France", .states = .{ .selected = true }, .actions = .{ .select = true }, .rect = .{ .x = 200, .y = 270, .w = 200, .h = 20 } },
    .{ .key = 7, .depth = 2, .role = .listitem, .name = "Belgique", .actions = .{ .select = true }, .rect = .{ .x = 200, .y = 290, .w = 200, .h = 20 } },
    .{ .key = 8, .depth = 2, .role = .listitem, .name = "Suisse", .actions = .{ .select = true }, .rect = .{ .x = 200, .y = 310, .w = 200, .h = 20 } },
    .{ .key = 9, .depth = 1, .role = .list, .name = "Articles", .scroll = .{ .v = 0 }, .rect = .{ .x = 200, .y = 400, .w = 300, .h = 100 } },
    .{ .key = 10, .depth = 2, .role = .listitem, .name = "Article 1", .actions = .{ .select = true }, .rect = .{ .x = 200, .y = 400, .w = 300, .h = 20 } },
    // Below the list's view and without ScrollItem: `ui_reveal` shows it
    // once the list is scrolled far enough.
    .{ .key = 11, .depth = 2, .role = .listitem, .name = "Article 40", .actions = .{ .select = true }, .rect = .{ .x = 200, .y = 560, .w = 300, .h = 20 } },
    // No pattern: an MSAA default action when `ui_legacy` names it.
    .{ .key = 12, .depth = 1, .role = .text, .name = "Statut", .rect = .{ .x = 200, .y = 600, .w = 200, .h = 20 } },
    .{ .key = 13, .depth = 1, .role = .link, .name = "Aide", .actions = .{ .invoke = true }, .rect = .{ .x = 200, .y = 640, .w = 200, .h = 20 } },
    .{ .key = 14, .depth = 1, .role = .edit, .name = "Nom", .value = "Ada", .actions = .{ .value = true }, .rect = .{ .x = 200, .y = 680, .w = 200, .h = 30 } },
    .{ .key = 15, .depth = 1, .role = .edit, .name = "Code", .password = true, .actions = .{ .value = true }, .rect = .{ .x = 200, .y = 720, .w = 200, .h = 30 } },
};

const Form = struct {
    h: Harness = .{},
    tree: []const u8 = "",

    fn init(self: *Form, elements: []const Element) !void {
        self.h.init(testing.allocator);
        self.h.backend.ui_elements = elements;
        self.h.backend.ui_reveal = .{ .key = 11, .at = 30 };
        // Short waits: a refused or contradicted action runs them out.
        self.h.server.session.enable_wait_ms = 300;
        self.h.server.session.verify_ms = 100;
        self.tree = text(try self.h.call("ui_tree", "{}"));
    }

    fn deinit(self: *Form) void {
        self.h.deinit();
    }

    /// The id of the first tree line that holds `needle`.
    fn id(self: *Form, needle: []const u8) []const u8 {
        return idIn(self.tree, needle) orelse std.debug.panic("no `{s}` in:\n{s}", .{ needle, self.tree });
    }

    fn act(self: *Form, needle: []const u8, comptime rest: []const u8) !std.json.ObjectMap {
        return self.actOn(self.id(needle), rest);
    }

    fn actOn(self: *Form, element: []const u8, comptime rest: []const u8) !std.json.ObjectMap {
        const args = try std.fmt.allocPrint(self.h.arena.allocator(), "{{\"id\":\"{s}\",\"observe\":\"none\"," ++ rest ++ "}}", .{element});
        return self.h.call("ui_act", args);
    }

    /// Pattern calls received since `from`, as their tags.
    fn ops(self: *Form, from: usize) []const Tag {
        const b = &self.h.backend;
        const out = self.h.arena.allocator().alloc(Tag, b.ui_op_len - from) catch unreachable;
        for (b.ui_ops[from..b.ui_op_len], out) |o, *x| x.* = o.op;
        return out;
    }
};

fn idIn(tree: []const u8, needle: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, tree, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        var it = std.mem.tokenizeAny(u8, line, " +~");
        const first = it.next() orelse return null;
        return if (uitree.parseId(first) != null) first else null;
    }
    return null;
}

fn expect(res: std.json.ObjectMap, comptime f: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, f, args), text(res));
}

// ---------------------------------------------------------------- US-051

test "check and uncheck read the state first: one Toggle when needed, none when the state is already there" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const box = f.id("Abonné");
    const b = &f.h.backend;

    const checked = try f.actOn(box, "\"action\":\"check\"");
    try testing.expect(!isError(checked));
    try expect(checked, "check {s} : vérifié (coché)", .{box});
    try testing.expectEqualSlices(Tag, &.{.toggle}, f.ops(0));

    const again = try f.actOn(box, "\"action\":\"check\"");
    try testing.expect(!isError(again));
    try expect(again, "check {s} : déjà coché", .{box});
    try testing.expectEqual(@as(usize, 1), b.ui_op_len);

    try expect(try f.actOn(box, "\"action\":\"uncheck\""), "uncheck {s} : vérifié (décoché)", .{box});
    try expect(try f.actOn(box, "\"action\":\"uncheck\""), "uncheck {s} : déjà décoché", .{box});
    try testing.expectEqualSlices(Tag, &.{ .toggle, .toggle }, f.ops(0));
    // The next tree shows the state the calls left.
    try expectContains(text(try f.h.call("ui_tree", "{}")), "checkbox \"Abonné\" @");
}

test "a three-state box takes two Toggle calls at most, then an error that gives the state read" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const box = f.id("Abonné");
    const b = &f.h.backend;
    // off, on, mixed, off: unchecking a checked box goes through mixed.
    b.ui_toggle_cycle = &.{ .off, .on, .mixed };
    try expect(try f.actOn(box, "\"action\":\"check\""), "check {s} : vérifié (coché)", .{box});
    try expect(try f.actOn(box, "\"action\":\"uncheck\""), "uncheck {s} : vérifié (décoché) ; 2 bascules", .{box});
    try testing.expectEqualSlices(Tag, &.{ .toggle, .toggle, .toggle }, f.ops(0));

    // A box that never reaches `on`: two calls, no third.
    b.ui_toggle_cycle = &.{ .off, .mixed };
    const from = b.ui_op_len;
    const stuck = try f.actOn(box, "\"action\":\"check\"");
    try testing.expect(isError(stuck));
    try expect(stuck, "check {s} : contredit, état lu décoché après 2 bascules, sans atteindre « coché ». " ++ not_replayable, .{box});
    try testing.expectEqualSlices(Tag, &.{ .toggle, .toggle }, f.ops(from));
}

test "check on an element without Toggle does nothing and names the pattern and invoke" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const link = f.id("Aide");
    const res = try f.actOn(link, "\"action\":\"check\"");
    try testing.expect(isError(res));
    try expect(res, "Précondition non remplie : {s} ne supporte pas check (pattern Toggle absent) : son état est inconnu. Essaie invoke. Aucune action exécutée.", .{link});
    // Never a click, even when asked for: the final state could not be told.
    const clicked = try f.actOn(link, "\"action\":\"uncheck\",\"fallback\":\"click\"");
    try testing.expect(isError(clicked));
    try testing.expectEqual(@as(usize, 0), f.h.backend.ui_op_len);
    try testing.expectEqual(@as(usize, 0), f.h.backend.mouse_len);
}

test "invoke falls back on the MSAA default action, toggle on Invoke, and the result names the pattern used" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const status = f.id("Statut");
    // Without a default action either, nothing is called.
    const none = try f.actOn(status, "\"action\":\"invoke\"");
    try testing.expect(isError(none));
    try expectContains(text(none), "ne supporte pas invoke (pattern Invoke absent)");
    try testing.expectEqual(@as(usize, 0), b.ui_op_len);

    b.ui_legacy = &.{12};
    const legacy = try f.actOn(status, "\"action\":\"invoke\"");
    try testing.expect(!isError(legacy));
    try expect(legacy, "invoke {s} : délivré, effet non vérifiable ; par LegacyIAccessible.DoDefaultAction", .{status});
    try testing.expectEqualSlices(Tag, &.{.legacy}, f.ops(0));

    // An element with Invoke is invoked, and says nothing of the chain.
    const link = f.id("Aide");
    try expect(try f.actOn(link, "\"action\":\"invoke\""), "invoke {s} : délivré, effet non vérifiable", .{link});
    const toggled = try f.actOn(link, "\"action\":\"toggle\"");
    try expect(toggled, "toggle {s} : délivré, effet non vérifiable ; par Invoke", .{link});
    try testing.expectEqualSlices(Tag, &.{ .legacy, .invoke, .invoke }, f.ops(0));
}

test "expand and collapse never fall back on Invoke: the error proposes invoke" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const link = f.id("Aide");
    for ([_][]const u8{ "expand", "collapse" }) |action| {
        const args = try std.fmt.allocPrint(f.h.arena.allocator(), "{{\"id\":\"{s}\",\"action\":\"{s}\"}}", .{ link, action });
        const res = try f.h.call("ui_act", args);
        try testing.expect(isError(res));
        try expectContains(text(res), "(pattern ExpandCollapse absent). Son état déplié ou replié est inconnu : essaie invoke");
        try expectContains(text(res), "Aucune action exécutée.");
    }
    try testing.expectEqual(@as(usize, 0), f.h.backend.ui_op_len);

    // With the pattern, the state read back is the verdict.
    const combo = f.id("Pays");
    try expect(try f.actOn(combo, "\"action\":\"expand\""), "expand {s} : vérifié (déplié)", .{combo});
    try expect(try f.actOn(combo, "\"action\":\"collapse\""), "collapse {s} : vérifié (replié)", .{combo});
}

test "check, uncheck and scroll are clicks for the policy: an observe application refuses them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = policy.parse(arena.allocator(), "{\"apps\": {\"notepad.exe\": \"observe\"}}", "policy.json");
    var h: Harness = .{};
    h.initWith(testing.allocator, .{ .policy = &p });
    defer h.deinit();
    try testing.expect(!isError(try h.call("ui_tree", "{}")));
    for ([_][]const u8{ "\"action\":\"uncheck\"", "\"action\":\"check\"", "\"action\":\"scroll\",\"value\":\"down\"" }) |rest| {
        const args = try std.fmt.allocPrint(h.arena.allocator(), "{{\"id\":\"e8\",{s}}}", .{rest});
        const res = try h.call("ui_act", args);
        try testing.expect(isError(res));
        try expectContains(text(res), "Politique : notepad.exe est en mode observe");
    }
    try testing.expectEqual(@as(usize, 0), h.backend.ui_op_len);
    try testing.expectEqual(@as(u32, 0), h.backend.ui_live_reads);

    // At the default level the same call goes through.
    var full: Harness = .{};
    full.init(testing.allocator);
    defer full.deinit();
    _ = try full.call("ui_tree", "{}");
    try testing.expectEqualStrings("uncheck e8 : vérifié (décoché)", text(try full.call("ui_act", "{\"id\":\"e8\",\"action\":\"uncheck\",\"observe\":\"none\"}")));
}

// ---------------------------------------------------------------- US-052

test "scroll takes notches, pages, edges and percentages, and refuses any other value with the accepted forms" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const list = f.id("list \"Articles\"");
    for ([_][]const u8{ "sideways", "down 0", "down 101", "150%", "up 2 3", "" }) |bad| {
        const args = try std.fmt.allocPrint(f.h.arena.allocator(), "{{\"id\":\"{s}\",\"action\":\"scroll\",\"value\":\"{s}\"}}", .{ list, bad });
        const res = try f.h.call("ui_act", args);
        try testing.expect(isError(res));
        try expectContains(text(res), "invalide pour scroll : formes acceptées up, down, left ou right suivi d'un nombre de crans de 1 à 100 (défaut 1), page_up, page_down, top, bottom, ou <n>% de 0 à 100. Aucune action exécutée.");
    }
    const missing = try f.actOn(list, "\"action\":\"scroll\"");
    try testing.expect(isError(missing));
    try testing.expectEqual(@as(usize, 0), b.ui_op_len);

    // Notches: one Scroll call each, a small increment.
    try expect(try f.actOn(list, "\"action\":\"scroll\",\"value\":\"down 3\""), "scroll {s} : vérifié (scroll=30%)", .{list});
    try testing.expectEqualSlices(Tag, &.{ .scroll, .scroll, .scroll }, f.ops(0));
    try expect(try f.actOn(list, "\"action\":\"scroll\",\"value\":\"up\""), "scroll {s} : vérifié (scroll=20%)", .{list});
    // A page: one large increment (five notches of the fake).
    try expect(try f.actOn(list, "\"action\":\"scroll\",\"value\":\"page_down\""), "scroll {s} : vérifié (scroll=70%)", .{list});
    try testing.expectEqual(Tag.scroll, b.ui_last_op.?.op);
    // Edges and percentages: SetScrollPercent.
    try expect(try f.actOn(list, "\"action\":\"scroll\",\"value\":\"bottom\""), "scroll {s} : vérifié (scroll=100%)", .{list});
    try testing.expectEqual(Tag.scroll_to, b.ui_last_op.?.op);
    try expect(try f.actOn(list, "\"action\":\"scroll\",\"value\":\"25%\""), "scroll {s} : vérifié (scroll=25%)", .{list});
    try expect(try f.actOn(list, "\"action\":\"scroll\",\"value\":\"top\""), "scroll {s} : vérifié (scroll=0%)", .{list});
}

test "a container already at the requested limit answers without an error and without a call" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const list = f.id("list \"Articles\"");
    for ([_][2][]const u8{ .{ "up", "déjà en haut" }, .{ "page_up", "déjà en haut" }, .{ "top", "déjà en haut" }, .{ "left 2", "déjà à gauche" }, .{ "right", "déjà à droite" }, .{ "0%", "déjà à 0%" } }) |c| {
        const args = try std.fmt.allocPrint(f.h.arena.allocator(), "{{\"id\":\"{s}\",\"action\":\"scroll\",\"value\":\"{s}\",\"observe\":\"none\"}}", .{ list, c[0] });
        const res = try f.h.call("ui_act", args);
        try testing.expect(!isError(res));
        try expect(res, "scroll {s} : {s}", .{ list, c[1] });
    }
    try testing.expectEqual(@as(usize, 0), b.ui_op_len);
    _ = try f.actOn(list, "\"action\":\"scroll\",\"value\":\"bottom\"");
    const from = b.ui_op_len;
    try expect(try f.actOn(list, "\"action\":\"scroll\",\"value\":\"down 5\""), "scroll {s} : déjà en bas", .{list});
    try expect(try f.actOn(list, "\"action\":\"scroll\",\"value\":\"bottom\""), "scroll {s} : déjà en bas", .{list});
    try testing.expectEqual(from, b.ui_op_len);
}

test "scroll on an element without Scroll moves its first scrollable ancestor, within 8 levels" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const list = f.id("list \"Articles\"");
    const item = f.id("Article 1");
    const res = try f.actOn(item, "\"action\":\"scroll\",\"value\":\"down 2\"");
    try testing.expect(!isError(res));
    try expect(res, "scroll {s} : vérifié (scroll=20%) ; conteneur {s}", .{ item, list });
    try testing.expectEqual(@as(u64, 9), b.ui_last_op.?.key);

    // No scrollable ancestor: nothing is called.
    const box = f.id("Abonné");
    const nowhere = try f.actOn(box, "\"action\":\"scroll\",\"value\":\"down\"");
    try testing.expect(isError(nowhere));
    try expect(nowhere, "{s} n'est dans aucun conteneur défilable. Aucune action exécutée.", .{box});

    // Nine levels up is too far.
    var deep: [12]Element = undefined;
    deep[0] = form[0];
    deep[1] = .{ .key = 50, .depth = 1, .role = .list, .name = "Lointain", .scroll = .{ .v = 0 }, .rect = .{ .x = 200, .y = 200, .w = 400, .h = 400 } };
    for (deep[2..11], 2..) |*e, d| e.* = .{ .key = 50 + d, .depth = @intCast(d), .role = .group, .name = "Niveau", .rect = .{ .x = 200, .y = 200, .w = 400, .h = 400 } };
    deep[11] = .{ .key = 70, .depth = 11, .role = .button, .name = "Fond", .actions = .{ .invoke = true }, .rect = .{ .x = 220, .y = 220, .w = 100, .h = 30 } };
    b.ui_elements = &deep;
    const far = idIn(text(try f.h.call("ui_find", "{\"query\":\"Fond\"}")), "Fond").?;
    const from = b.ui_op_len;
    const too_far = try f.actOn(far, "\"action\":\"scroll\",\"value\":\"down\"");
    try testing.expect(isError(too_far));
    try expectContains(text(too_far), "n'est dans aucun conteneur défilable");
    try testing.expectEqual(from, b.ui_op_len);
}

test "scroll_into_view without ScrollItem scrolls the ancestor by increments until the element shows, and the delta shows the new position" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const list = f.id("list \"Articles\"");
    // Out of view: the tree leaves it out, ui_find gives its id.
    const far = idIn(text(try f.h.call("ui_find", "{\"query\":\"Article 40\"}")), "Article 40").?;
    const args = try std.fmt.allocPrint(f.h.arena.allocator(), "{{\"id\":\"{s}\",\"action\":\"scroll_into_view\"}}", .{far});
    const res = try f.h.call("ui_act", args);
    try testing.expect(!isError(res));
    const head = try std.fmt.allocPrint(f.h.arena.allocator(), "scroll_into_view {s} : délivré, effet non vérifiable ; par défilement de {s} ; settled in ", .{ far, list });
    try testing.expect(std.mem.startsWith(u8, text(res), head));
    // Three notches reach the 30 % where the element shows.
    try testing.expectEqualSlices(Tag, &.{ .scroll, .scroll, .scroll }, f.ops(0));
    try expectContains(text(res), "list \"Articles\" scroll=30%");
    try expectContains(text(res), "+ ");

    // In view by now: nothing left to do.
    try expect(try f.actOn(far, "\"action\":\"scroll_into_view\""), "scroll_into_view {s} : déjà en vue", .{far});
    try testing.expectEqual(@as(usize, 3), b.ui_op_len);
}

test "a container that reaches its end before the element shows stops the scroll at 50 increments at most" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const far = idIn(text(try f.h.call("ui_find", "{\"query\":\"Article 40\"}")), "Article 40").?;
    // Never revealed: the list runs to its end, then stays there.
    b.ui_reveal = .{ .key = 11, .at = 1000 };
    const res = try f.actOn(far, "\"action\":\"scroll_into_view\"");
    try testing.expect(isError(res));
    try expectContains(text(res), "n'a pas pu être amené en vue : le conteneur est au bout de sa course. Le conteneur a défilé : relis l'arbre.");
    try testing.expectEqual(@as(usize, 11), b.ui_op_len);

    // A list that moves a hair per notch: 50 increments, then it gives up.
    b.ui_op_len = 0;
    b.ui_scroll_step = 0.001;
    _ = try f.actOn(f.id("list \"Articles\""), "\"action\":\"scroll\",\"value\":\"top\"");
    b.ui_op_len = 0;
    const slow = try f.actOn(far, "\"action\":\"scroll_into_view\"");
    try testing.expect(isError(slow));
    try expectContains(text(slow), "toujours hors écran après 50 incréments");
    try testing.expectEqual(@as(usize, 50), b.ui_op_len);
}

// ---------------------------------------------------------------- US-053

test "set_value on a slider calls RangeValue with a number, and refuses a value out of range or not a number" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const slider = f.id("Volume");
    const over = try f.actOn(slider, "\"action\":\"set_value\",\"value\":\"150\"");
    try testing.expect(isError(over));
    try testing.expectEqualStrings("Valeur 150 hors plage 0..100. Aucune action exécutée.", text(over));
    const word = try f.actOn(slider, "\"action\":\"set_value\",\"value\":\"fort\"");
    try testing.expect(isError(word));
    try expect(word, "{s} attend un nombre entre 0 et 100. Aucune action exécutée.", .{slider});
    try testing.expectEqual(@as(usize, 0), b.ui_op_len);

    const set = try f.actOn(slider, "\"action\":\"set_value\",\"value\":\"62,5\"");
    try testing.expect(!isError(set));
    try expect(set, "set_value {s} : vérifié (valeur relue identique)", .{slider});
    try testing.expectEqualSlices(Tag, &.{.set_range}, f.ops(0));
    try expectContains(text(try f.h.call("ui_tree", "{}")), "slider \"Volume\" [=62.5/0..100]");

    // A slider that snaps to its own steps: delivered, not an error.
    b.ui_reformat = true;
    const snapped = try f.actOn(slider, "\"action\":\"set_value\",\"value\":\"33\"");
    try testing.expect(!isError(snapped));
    try expect(snapped, "set_value {s} : délivré, valeur reformatée par l'application", .{slider});
}

test "select with a name expands a collapsed container, selects the entry whatever the case and accents, and collapses it again" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const combo = f.id("Pays");
    const entry = f.id("Belgique");
    const res = try f.actOn(combo, "\"action\":\"select\",\"value\":\" BELGÏQUE \"");
    try testing.expect(!isError(res));
    try expect(res, "select {s} : vérifié (sélectionné) ; entrée {s}", .{ combo, entry });
    try testing.expectEqualSlices(Tag, &.{ .expand, .select, .collapse }, f.ops(0));
    try testing.expectEqual(@as(u64, 7), b.ui_ops[1].key);
    try expectContains(text(try f.h.call("ui_tree", "{}")), "combobox \"Pays\" {collapsed}");

    // A container that was already open stays open.
    _ = try f.actOn(combo, "\"action\":\"expand\"");
    const from = b.ui_op_len;
    try testing.expect(!isError(try f.actOn(combo, "\"action\":\"select\",\"value\":\"suisse\"")));
    try testing.expectEqualSlices(Tag, &.{.select}, f.ops(from));
    try expectContains(text(try f.h.call("ui_tree", "{}")), "combobox \"Pays\" {expanded}");
}

test "select with a name no entry bears leaves the container as it was and lists the entries" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const combo = f.id("Pays");
    const res = try f.actOn(combo, "\"action\":\"select\",\"value\":\"Italie\"");
    try testing.expect(isError(res));
    try expect(res, "Aucune entrée « Italie » dans {s}. Entrées : « France », « Belgique », « Suisse ». Aucune sélection faite, conteneur replié comme avant.", .{combo});
    try testing.expectEqualSlices(Tag, &.{ .expand, .collapse }, f.ops(0));
    try expectContains(text(try f.h.call("ui_tree", "{}")), "combobox \"Pays\" {collapsed}");

    // At most 10 names.
    var many: [14]Element = undefined;
    many[0] = form[0];
    many[1] = .{ .key = 80, .depth = 1, .role = .list, .name = "Longue", .rect = .{ .x = 200, .y = 200, .w = 300, .h = 400 } };
    for (many[2..], 2..) |*e, i| e.* = .{ .key = 80 + i, .depth = 2, .role = .listitem, .name = try std.fmt.allocPrint(f.h.arena.allocator(), "Choix {d}", .{i - 1}), .actions = .{ .select = true }, .rect = .{ .x = 200, .y = @intCast(200 + 20 * i), .w = 300, .h = 20 } };
    f.h.backend.ui_elements = &many;
    const long = idIn(text(try f.h.call("ui_tree", "{}")), "list \"Longue\"").?;
    const none = try f.actOn(long, "\"action\":\"select\",\"value\":\"Absent\"");
    try testing.expect(isError(none));
    try expectContains(text(none), "« Choix 10 », … 2 autres. Aucune action exécutée.");
    try testing.expect(std.mem.indexOf(u8, text(none), "Choix 11") == null);
}

test "select with a name two entries bear selects nothing and gives their ids" {
    var f: Form = .{};
    var twins = form;
    twins[7].name = "Belgique";
    try f.init(&twins);
    defer f.deinit();
    const combo = f.id("Pays");
    const res = try f.actOn(combo, "\"action\":\"select\",\"value\":\"belgique\"");
    try testing.expect(isError(res));
    var lines = std.mem.splitScalar(u8, f.tree, '\n');
    var ids: [2][]const u8 = undefined;
    var n: usize = 0;
    while (lines.next()) |line| if (std.mem.indexOf(u8, line, "\"Belgique\"") != null) {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        ids[n] = it.next().?;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 2), n);
    try expect(res, "2 entrées nommées « belgique » dans {s} : {s}, {s}. Choisis-en une par son id avec select sans value. Aucune sélection faite, conteneur replié comme avant.", .{ combo, ids[0], ids[1] });
    try testing.expectEqualSlices(Tag, &.{ .expand, .collapse }, f.ops(0));
}

test "select without a value keeps selecting the element itself" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const entry = f.id("Suisse");
    const res = try f.actOn(entry, "\"action\":\"select\"");
    try expect(res, "select {s} : vérifié (sélectionné)", .{entry});
    try testing.expectEqualSlices(Tag, &.{.select}, f.ops(0));
    try testing.expectEqual(@as(u64, 8), f.h.backend.ui_last_op.?.key);
    // A container is not selectable itself.
    const combo = try f.actOn(f.id("Pays"), "\"action\":\"select\"");
    try testing.expect(isError(combo));
    try expectContains(text(combo), "pattern SelectionItem absent");
}

test "entries that show only once the container is open, or that cannot be read while it is, are both found" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const combo = f.id("Pays");
    b.ui_entries_when_open = true;
    try testing.expect(!isError(try f.actOn(combo, "\"action\":\"select\",\"value\":\"Suisse\"")));
    try testing.expectEqualSlices(Tag, &.{ .expand, .select, .collapse }, f.ops(0));

    // A Win32 drop-down: unreadable while open, read once closed again.
    b.ui_entries_when_open = false;
    b.ui_entries_fail_open = true;
    const from = b.ui_op_len;
    const res = try f.actOn(combo, "\"action\":\"select\",\"value\":\"France\"");
    try testing.expect(!isError(res));
    try expectContains(text(res), "vérifié (sélectionné)");
    try expectContains(text(res), "entrées lues conteneur replié");
    try testing.expectEqualSlices(Tag, &.{ .expand, .collapse, .select }, f.ops(from));
}

test "an entry a drop-down drops when it collapses is selected again once it is closed" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const combo = f.id("Pays");
    const entry = f.id("Suisse");
    b.ui_collapse_cancels = true;
    const res = try f.actOn(combo, "\"action\":\"select\",\"value\":\"Suisse\"");
    try testing.expect(!isError(res));
    try expect(res, "select {s} : vérifié (sélectionné) ; sélection refaite conteneur replié ; entrée {s}", .{ combo, entry });
    try testing.expectEqualSlices(Tag, &.{ .expand, .select, .collapse, .select }, f.ops(0));
    try expectContains(text(try f.h.call("ui_tree", "{}")), "combobox \"Pays\" {collapsed}");
}

// ---------------------------------------------------------------- US-054

test "a disabled element is read again every 100 ms and the action leaves as soon as it is enabled" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    f.h.server.session.enable_wait_ms = 2000;
    const send = f.id("Envoyer");
    // Enabled at the fourth read: three waits of 100 ms.
    b.ui_live_reads = 0;
    b.ui_enable_at_read = 4;
    const res = try f.actOn(send, "\"action\":\"invoke\"");
    try testing.expect(!isError(res));
    const said = text(res);
    const prefix = try std.fmt.allocPrint(f.h.arena.allocator(), "invoke {s} : délivré, effet non vérifiable ; activé après ", .{send});
    try testing.expect(std.mem.startsWith(u8, said, prefix));
    const waited = try std.fmt.parseInt(u32, said[prefix.len..std.mem.indexOfPos(u8, said, prefix.len, " ms").?], 10);
    try testing.expect(waited >= 300 and waited < 1000);
    try testing.expectEqual(@as(u32, 4), b.ui_live_reads);
    try testing.expectEqualSlices(Tag, &.{.invoke}, f.ops(0));
}

test "an element still disabled at the end of the wait runs no action" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const send = f.id("Envoyer");
    const res = try f.actOn(send, "\"action\":\"invoke\"");
    try testing.expect(isError(res));
    try expect(res, "Précondition non remplie : {s} est resté désactivé 300 ms. Aucune action exécutée.", .{send});
    try testing.expectEqual(@as(usize, 0), f.h.backend.ui_op_len);
    // Read at once, then every 100 ms until the 300 ms the test allows.
    try testing.expectEqual(@as(u32, 4), f.h.backend.ui_live_reads);
    // The wait's length is the session's: 2000 ms as shipped.
    try testing.expectEqual(@as(u32, 2000), (@import("session.zig").Session{ .gpa = testing.allocator }).enable_wait_ms);
}

test "an element out of view is scrolled into view once, then acted on" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("ui_tree", "{}");
    // The fixture's off-screen list item, with ScrollItem.
    _ = try h.call("ui_find", "{\"query\":\"hors champ\"}");
    const res = try h.call("ui_act", "{\"id\":\"eb\",\"action\":\"select\",\"observe\":\"none\"}");
    try testing.expect(!isError(res));
    try testing.expectEqualStrings("select eb : vérifié (sélectionné) ; amené en vue", text(res));
    try testing.expectEqual(@as(usize, 2), h.backend.ui_op_len);
    try testing.expectEqual(Tag.scroll_item, h.backend.ui_ops[0].op);
    try testing.expectEqual(Tag.select, h.backend.ui_ops[1].op);

    // Without ScrollItem, the ancestor is scrolled (US-052), then the
    // element is acted on.
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const far = idIn(text(try f.h.call("ui_find", "{\"query\":\"Article 40\"}")), "Article 40").?;
    const picked = try f.actOn(far, "\"action\":\"select\"");
    try expect(picked, "select {s} : vérifié (sélectionné) ; amené en vue", .{far});
    try testing.expectEqualSlices(Tag, &.{ .scroll, .scroll, .scroll, .select }, f.ops(0));

    // An element nothing brings into view is not acted on.
    f.h.backend.ui_elements = form[0..9] ++ [_]Element{.{ .key = 90, .depth = 1, .role = .button, .name = "Perdu", .states = .{ .offscreen = true }, .actions = .{ .invoke = true }, .rect = .{ .x = 200, .y = 5000, .w = 100, .h = 30 } }};
    const lost = idIn(text(try f.h.call("ui_find", "{\"query\":\"Perdu\"}")), "Perdu").?;
    const from = f.h.backend.ui_op_len;
    const refused = try f.actOn(lost, "\"action\":\"invoke\"");
    try testing.expect(isError(refused));
    try expect(refused, "Précondition non remplie : {s} est hors écran et n'a pas pu être amené en vue (pattern ScrollItem absent et aucun conteneur défilable). Aucune action exécutée.", .{lost});
    try testing.expectEqual(from, f.h.backend.ui_op_len);
}

test "an element gone before the action is an immediate error, without a wait" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const send = f.id("Envoyer");
    f.h.backend.ui_elements = form[0..2];
    f.h.backend.ui_live_reads = 0;
    const res = try f.actOn(send, "\"action\":\"invoke\"");
    try testing.expect(isError(res));
    try expect(res, "Élément {s} introuvable : rappelle ui_tree", .{send});
    try testing.expectEqual(@as(u32, 1), f.h.backend.ui_live_reads);
}

test "a cancellation or a pause during the wait stops it at the next checkpoint" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    f.h.server.session.enable_wait_ms = 2000;
    const send = f.id("Envoyer");
    b.startKillSwitch(&f.h.server.control, @import("control.zig").default_rearm);

    // Cancelled at the second read: no response, no action, well before
    // the 2 s of the wait.
    b.ui_live_reads = 0;
    b.ui_cancel_at_read = 2;
    f.h.out.clearRetainingCapacity();
    const line = try std.fmt.allocPrint(f.h.arena.allocator(), "{{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"tools/call\",\"params\":{{\"name\":\"ui_act\",\"arguments\":{{\"id\":\"{s}\",\"action\":\"invoke\"}}}}}}", .{send});
    try f.h.server.handleMessage(line, &f.h.out.writer);
    try testing.expectEqual(@as(usize, 0), f.h.out.written().len);
    try testing.expectEqual(@as(u32, 2), b.ui_live_reads);
    try testing.expectEqual(@as(usize, 0), b.ui_op_len);

    // Paused by the user's shortcut: the pause message, no action.
    b.ui_cancel_at_read = null;
    b.ui_live_reads = 0;
    b.ui_pause_at_read = 2;
    const paused = try f.actOn(send, "\"action\":\"invoke\"");
    try testing.expect(isError(paused));
    try testing.expectEqualStrings(@import("control.zig").paused_message, text(paused));
    try testing.expectEqual(@as(u32, 2), b.ui_live_reads);
    try testing.expectEqual(@as(usize, 0), b.ui_op_len);
}

// ---------------------------------------------------------------- US-055

test "an action whose effect is read back at once costs one read, and one the application ignores is contradicted, never replayed" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const box = f.id("Abonné");
    b.ui_live_reads = 0;
    const ok = try f.actOn(box, "\"action\":\"toggle\"");
    try testing.expect(!isError(ok));
    try expect(ok, "toggle {s} : vérifié (coché)", .{box});
    // One read for the preconditions, one for the verdict.
    try testing.expectEqual(@as(u32, 2), b.ui_live_reads);

    b.ui_stuck = true;
    b.ui_live_reads = 0;
    const from = b.ui_op_len;
    const refused = try f.actOn(box, "\"action\":\"toggle\"");
    try testing.expect(isError(refused));
    try expect(refused, "toggle {s} : contredit, état lu coché. " ++ not_replayable, .{box});
    try testing.expectEqualSlices(Tag, &.{.toggle}, f.ops(from));
    // Read again every 50 ms for the 100 ms the test allows.
    try testing.expect(b.ui_live_reads >= 3 and b.ui_live_reads <= 5);

    // Every action with a readable state is contradicted the same way.
    const combo = f.id("Pays");
    const list = f.id("list \"Articles\"");
    const entry = f.id("Suisse");
    try expect(try f.actOn(combo, "\"action\":\"expand\""), "expand {s} : contredit, état lu replié. " ++ not_replayable, .{combo});
    try expect(try f.actOn(entry, "\"action\":\"select\""), "select {s} : contredit, état lu non sélectionné. " ++ not_replayable, .{entry});
    try expect(try f.actOn(list, "\"action\":\"scroll\",\"value\":\"down\""), "scroll {s} : contredit, état lu scroll=0%. " ++ not_replayable, .{list});
    try expect(try f.actOn(box, "\"action\":\"uncheck\""), "uncheck {s} : contredit, état lu coché. " ++ not_replayable, .{box});
    // The session's bound is 400 ms as shipped.
    try testing.expectEqual(@as(u32, 400), (@import("session.zig").Session{ .gpa = testing.allocator }).verify_ms);
}

test "set_value compares the value read back without ever writing it, and never reads a password back" {
    var f: Form = .{};
    try f.init(&form);
    defer f.deinit();
    const b = &f.h.backend;
    const name = f.id("edit \"Nom\"");
    const same = try f.actOn(name, "\"action\":\"set_value\",\"value\":\"Grace Hopper\"");
    try testing.expect(!isError(same));
    try expect(same, "set_value {s} : vérifié (valeur relue identique)", .{name});
    try testing.expect(std.mem.indexOf(u8, text(same), "Grace") == null);

    b.ui_reformat = true;
    const changed = try f.actOn(name, "\"action\":\"set_value\",\"value\":\"12/11/2026\"");
    try testing.expect(!isError(changed));
    try expect(changed, "set_value {s} : délivré, valeur reformatée par l'application", .{name});
    try testing.expect(std.mem.indexOf(u8, text(changed), "12/11") == null);

    b.ui_reformat = false;
    b.ui_value_reads = 0;
    b.ui_live_reads = 0;
    const code = f.id("edit \"Code\"");
    const secret = try f.actOn(code, "\"action\":\"set_value\",\"value\":\"s3cret!\"");
    try testing.expect(!isError(secret));
    try expect(secret, "set_value {s} : délivré, effet non vérifiable", .{code});
    // The preconditions were read; nothing was read after the write.
    try testing.expectEqual(@as(u32, 0), b.ui_value_reads);
    try testing.expectEqual(@as(u32, 1), b.ui_live_reads);
    try testing.expectEqual(@as(usize, 7), b.ui_last_op.?.value_len);
}

test "invoke, scroll_into_view and focus are delivered without a verdict to read, and a refusal keeps its safe-retry sentence" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("ui_tree", "{}");
    _ = try h.call("ui_find", "{\"query\":\"hors champ\"}");
    h.backend.ui_live_reads = 0;
    try testing.expectEqualStrings("invoke e7 : délivré, effet non vérifiable", text(try h.call("ui_act", "{\"id\":\"e7\",\"action\":\"invoke\",\"observe\":\"none\"}")));
    try testing.expectEqualStrings("scroll_into_view eb : délivré, effet non vérifiable", text(try h.call("ui_act", "{\"id\":\"eb\",\"action\":\"scroll_into_view\",\"observe\":\"none\"}")));
    try testing.expectEqualStrings("focus e7 : délivré, effet non vérifiable", text(try h.call("ui_act", "{\"id\":\"e7\",\"action\":\"focus\",\"observe\":\"none\"}")));
    // One read each, for the preconditions: none after the call.
    try testing.expectEqual(@as(u32, 3), h.backend.ui_live_reads);

    h.server.session.enable_wait_ms = 100;
    for ([_][]const u8{
        "{\"id\":\"e9\",\"action\":\"invoke\"}",
        "{\"id\":\"e8\",\"action\":\"invoke\"}",
        "{\"id\":\"e7\",\"action\":\"check\"}",
        "{\"id\":\"e7\",\"action\":\"scroll\",\"value\":\"nulle part\"}",
        "{\"id\":\"e5\",\"action\":\"set_value\"}",
    }) |args| {
        const res = try h.call("ui_act", args);
        try testing.expect(isError(res));
        try expectContains(text(res), "Aucune action exécutée.");
        try testing.expect(std.mem.indexOf(u8, text(res), not_replayable) == null);
    }
}

test "the audit line of a ui_act carries its verdict, and a refusal carries none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: audit.Audit = .{ .io = testing.io, .dir = tmp.dir };
    defer if (log.file) |f| f.close(testing.io);
    var h: Harness = .{};
    h.initWith(testing.allocator, .{ .audit = &log });
    defer h.deinit();
    h.server.session.verify_ms = 100;
    h.server.session.enable_wait_ms = 100;
    _ = try h.call("ui_tree", "{}");
    var buf: [8192]u8 = undefined;
    const Case = struct { args: []const u8, want: ?[]const u8 };
    for ([_]Case{
        .{ .args = "{\"id\":\"e8\",\"action\":\"uncheck\",\"observe\":\"none\"}", .want = "\"result\":\"ok\",\"verdict\":\"verified\"}" },
        .{ .args = "{\"id\":\"e8\",\"action\":\"uncheck\",\"observe\":\"none\"}", .want = "\"result\":\"ok\",\"verdict\":\"noop\"}" },
        .{ .args = "{\"id\":\"e7\",\"action\":\"invoke\",\"observe\":\"none\"}", .want = "\"result\":\"ok\",\"verdict\":\"unverifiable\"}" },
        .{ .args = "{\"id\":\"e9\",\"action\":\"invoke\"}", .want = null },
        .{ .args = "{\"id\":\"e7\",\"action\":\"check\"}", .want = null },
    }) |c| {
        _ = try h.call("ui_act", c.args);
        const line = try lastLine(&tmp, &buf);
        try expectContains(line, "\"tool\":\"ui_act\"");
        if (c.want) |w| try expectContains(line, w) else {
            try testing.expect(std.mem.indexOf(u8, line, "verdict") == null);
            try expectContains(line, "\"result\":\"error\"}");
        }
    }
    h.backend.ui_stuck = true;
    try testing.expect(isError(try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"toggle\"}")));
    try expectContains(try lastLine(&tmp, &buf), "\"result\":\"error\",\"verdict\":\"contradicted\"}");
    // Another tool's line has no verdict.
    _ = try h.call("ui_tree", "{}");
    try testing.expect(std.mem.indexOf(u8, try lastLine(&tmp, &buf), "verdict") == null);
}

test "a pause while the effect is read back is audited as unverifiable, never as contradicted; one while a list fills in selects nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: audit.Audit = .{ .io = testing.io, .dir = tmp.dir };
    defer if (log.file) |f| f.close(testing.io);
    var f: Form = .{};
    f.h.initWith(testing.allocator, .{ .audit = &log });
    defer f.deinit();
    const b = &f.h.backend;
    b.ui_elements = &form;
    f.h.server.session.verify_ms = 100;
    f.tree = text(try f.h.call("ui_tree", "{}"));
    b.startKillSwitch(&f.h.server.control, @import("control.zig").default_rearm);
    var buf: [8192]u8 = undefined;

    // The box has not changed yet when the user pauses, at the first read
    // after the Toggle: the read-back stops there.
    b.ui_stuck = true;
    b.ui_live_reads = 0;
    b.ui_pause_at_read = 2;
    const paused = try f.act("Abonné", "\"action\":\"toggle\"");
    try testing.expectEqualStrings(@import("control.zig").paused_message, text(paused));
    try testing.expectEqualSlices(Tag, &.{.toggle}, f.ops(0));
    try expectContains(try lastLine(&tmp, &buf), "\"result\":\"paused\",\"verdict\":\"unverifiable\"}");

    // Re-armed. A drop-down that cannot be read while open, paused at its
    // first read: closed again, and no entry is selected afterwards.
    _ = f.h.server.control.toggle();
    b.ui_stuck = false;
    b.ui_pause_at_read = null;
    b.ui_entries_fail_open = true;
    b.ui_pause_at_entries = 1;
    const from = b.ui_op_len;
    const cut = try f.act("Pays", "\"action\":\"select\",\"value\":\"Suisse\"");
    try testing.expectEqualStrings(@import("control.zig").paused_message, text(cut));
    try testing.expectEqualSlices(Tag, &.{ .expand, .collapse }, f.ops(from));
    try testing.expect(std.mem.indexOf(u8, try lastLine(&tmp, &buf), "verdict") == null);
}

fn lastLine(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const data = try tmp.dir.readFile(testing.io, audit.file_name, buf);
    const lines = std.mem.trimEnd(u8, data, "\n");
    return lines[(std.mem.lastIndexOfScalar(u8, lines, '\n') orelse return lines) + 1 ..];
}

test "the new actions work the same in the background mode, where fallback click stays refused" {
    var h: Harness = .{};
    h.initWith(testing.allocator, .{ .mode = .background });
    defer h.deinit();
    _ = try h.call("ui_tree", "{\"window\":\"0x1a2b\"}");
    try testing.expectEqualStrings("uncheck e8 : vérifié (décoché)", text(try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"uncheck\",\"observe\":\"none\"}")));
    try testing.expectEqualStrings("check e8 : vérifié (coché)", text(try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"check\",\"observe\":\"none\"}")));
    const nowhere = try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"scroll\",\"value\":\"down\"}");
    try testing.expect(isError(nowhere));
    try expectContains(text(nowhere), "n'est dans aucun conteneur défilable");
    const fallback = try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"check\",\"fallback\":\"click\"}");
    try testing.expect(isError(fallback));
    try testing.expect(std.mem.startsWith(u8, text(fallback), "Mode arrière-plan : "));
    try testing.expectEqual(@as(usize, 0), h.backend.mouse_len);
}

test "ScrollSpec parses the documented forms only" {
    const S = uitree.ScrollSpec;
    try testing.expectEqual(S{ .step = .{ .dir = .down, .count = 1 } }, S.parse("down").?);
    try testing.expectEqual(S{ .step = .{ .dir = .left, .count = 100 } }, S.parse(" left 100 ").?);
    try testing.expectEqual(S{ .page = .up }, S.parse("page_up").?);
    try testing.expectEqual(S{ .edge = .bottom }, S.parse("bottom").?);
    try testing.expectEqual(S{ .percent = 37.5 }, S.parse("37.5%").?);
    for ([_][]const u8{ "", "down 0", "down 101", "down -1", "down x", "page_left", "101%", "-1%", "%", "DOWN", "down 1 2" }) |bad| try testing.expect(S.parse(bad) == null);
}
