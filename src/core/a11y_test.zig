//! EP-003 accessibility tools through the real dispatcher (`tools/call` JSON
//! in, JSON-RPC line out) against the fake backend: ui_tree format, pruning
//! and limits, ids and deltas, ui_find, ui_act, the post-action observation
//! and the vision mode.

const std = @import("std");
const testing = std.testing;
const t = @import("tools_test.zig");
const uitree = @import("uitree.zig");
const fake = @import("../backend/fake.zig");
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
const Element = uitree.Element;

const golden =
    \\display=0 scale=2 window=0x1a2b
    \\e1 window "Sans titre - Bloc-notes" @50,40,600,400
    \\  e2 menubar "Application" @50,60,600,20
    \\    e3 menuitem "Fichier" {collapsed} @55,62,40,16
    \\    e4 menuitem "Édition" {collapsed} @100,62,40,16
    \\  e5 edit "Éditeur de texte" [=Bonjour 'monde'] {focused} @50,80,600,340
    \\  e6 edit "Mot de passe" [=•••] @50,420,200,15
    \\  e7 button "Enregistrer" @550,420,50,15
    \\  e8 checkbox "Retour automatique à la ligne" {checked} @300,420,150,15
    \\  e9 button "Imprimer" {disabled} @475,420,50,15
    \\  ea text "Ligne 1, colonne 1" @50,435,100,5
    \\… 2 nœuds élagués
;

test "ui_tree prints the pruned tree in the golden one-line format" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const res = try h.call("ui_tree", "{}");
    try testing.expect(!t.isError(res));
    try testing.expectEqualStrings(golden, t.text(res));
    // The tree's display becomes the space of incoming coordinates.
    try testing.expectEqual(@as(?usize, 0), h.server.session.current);
}

test "a password value never appears, in ui_tree, ui_find or ui_act" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const tree = t.text(try h.call("ui_tree", "{}"));
    try t.expectContains(tree, "\"Mot de passe\" [=•••]");
    try testing.expect(std.mem.indexOf(u8, tree, "hunter2") == null);
    const found = t.text(try h.call("ui_find", "{\"query\":\"mot de passe\"}"));
    try t.expectContains(found, "[=•••]");
    try testing.expect(std.mem.indexOf(u8, found, "hunter2") == null);
    const set = try h.call("ui_act", "{\"id\":\"e6\",\"action\":\"set_value\",\"value\":\"s3cret!\",\"observe\":\"none\"}");
    try testing.expect(!t.isError(set));
    try testing.expectEqualStrings("ok : set_value e6", t.text(set));
    try testing.expectEqual(@as(usize, 7), h.backend.ui_last_act.?.value_len);
    try testing.expectEqual(@as(u64, 106), h.backend.ui_last_act.?.key);
}

test "a timed-out provider yields a partial tree flagged first; no foreground window yields the desktop tree" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_partial = true;
    const partial = t.text(try h.call("ui_tree", "{}"));
    try testing.expect(std.mem.startsWith(u8, partial, "{partial: timeout}\ndisplay=0"));
    h.backend.ui_partial = false;
    h.backend.ui_desktop = true;
    const desktop = t.text(try h.call("ui_tree", "{}"));
    try testing.expect(std.mem.startsWith(u8, desktop, "Aucune fenêtre active : arbre du bureau renvoyé\n"));
    const bad = try h.call("ui_tree", "{\"window\":\"0x9999\"}");
    try testing.expect(t.isError(bad));
    try testing.expectEqualStrings("Fenêtre fermée : rappelle window_list", t.text(bad));
}

test "a Chromium window without its web content yet says to retry" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_web_pending = true;
    const pending = t.text(try h.call("ui_tree", "{}"));
    try testing.expect(std.mem.endsWith(u8, pending, "Contenu web pas encore exposé (Chromium le construit à la première lecture) : rappelle ui_tree dans 1 s, ou utilise screenshot."));
    h.backend.ui_web_pending = false;
    const ready = t.text(try h.call("ui_tree", "{}"));
    try testing.expect(std.mem.indexOf(u8, ready, "Contenu web") == null);
}

test "a 20,000-element tree stays under 8,000 characters and a 32 MB arena" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const els = try a.alloc(Element, 20_000);
    els[0] = .{ .key = 1, .depth = 0, .role = .document, .name = "Page", .rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1440 } };
    for (els[1..], 1..) |*e, i| {
        // A web page: nested sections, half of them scrolled out of view.
        const y: i32 = @intCast((i % 400) * 8);
        e.* = .{
            .key = 1000 + i,
            .depth = @intCast(1 + i % 12),
            .role = if (i % 3 == 0) .link else .text,
            .name = try std.fmt.allocPrint(a, "Élément de contenu numéro {d}", .{i}),
            .actions = .{ .invoke = i % 3 == 0 },
            .rect = .{ .x = 10, .y = if (i % 2 == 0) y else 5000 + y, .w = 300, .h = 8 },
        };
    }
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_elements = els;
    const res = try h.call("ui_tree", "{}");
    const out = t.text(res);
    try testing.expect(out.len <= 8000);
    try t.expectContains(out, " nœuds élagués");
    try testing.expect(h.server.arena.queryCapacity() < 32 * 1024 * 1024);
}

test "ids stay stable and since:last returns only additions, removals and changes beyond 4 px" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("ui_tree", "{}");

    var els: [fake.ui_fixture.len]Element = fake.ui_fixture;
    els[8].name = "Retour à la ligne"; // e8 renamed
    els[7].rect.x += 10; // e7 moved by 5 screenshot px
    els[3].rect.x += 4; // e3 moved by 2 screenshot px: ignored
    els[10] = .{ .key = 112, .depth = 2, .role = .button, .name = "Nouveau", .actions = .{ .invoke = true }, .rect = .{ .x = 300, .y = 860, .w = 60, .h = 20 } }; // ea removed, one added
    h.backend.ui_elements = &els;
    const delta = t.text(try h.call("ui_tree", "{\"since\":\"last\"}"));
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b delta +1 -1 ~2
        \\~ e7 button "Enregistrer" @555,420,50,15
        \\~ e8 checkbox "Retour à la ligne" {checked} @300,420,150,15
        \\+ eb button "Nouveau" @150,430,30,10
        \\- ea text
    , delta);
    const same = t.text(try h.call("ui_tree", "{\"since\":\"last\"}"));
    try testing.expectEqualStrings("display=0 scale=2 window=0x1a2b delta: aucun changement", same);
    // The full tree keeps every surviving id.
    const full = t.text(try h.call("ui_tree", "{}"));
    try t.expectContains(full, "  e7 button \"Enregistrer\"");
    try t.expectContains(full, "  eb button \"Nouveau\"");
}

test "since:last after a foreground change returns the new window's full tree with a header" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("ui_tree", "{}");
    const other = [_]Element{
        .{ .key = 500, .depth = 0, .role = .window, .name = "Calculatrice", .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 } },
        .{ .key = 501, .depth = 1, .role = .button, .name = "Un", .actions = .{ .invoke = true }, .rect = .{ .x = 10, .y = 10, .w = 40, .h = 40 } },
        .{ .key = 502, .depth = 1, .role = .button, .name = "Deux", .actions = .{ .invoke = true }, .rect = .{ .x = 60, .y = 10, .w = 40, .h = 40 } },
    };
    h.backend.ui_window = 0x7777;
    h.backend.ui_elements = &other;
    const res = t.text(try h.call("ui_tree", "{\"since\":\"last\"}"));
    try testing.expectEqualStrings(
        \\Fenêtre au premier plan changée : arbre complet de la nouvelle fenêtre.
        \\display=0 scale=2 window=0x7777
        \\eb window "Calculatrice" @0,0,400,300
        \\  ec button "Un" @5,5,20,20
        \\  ed button "Deux" @30,5,20,20
    , res);
}

test "a delta longer than the full tree returns the full tree" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("ui_tree", "{}");
    // Every element but the window replaced: as many removals as additions.
    var els: [fake.ui_fixture.len]Element = fake.ui_fixture;
    for (els[1..]) |*e| e.key += 1000;
    h.backend.ui_elements = &els;
    const res = t.text(try h.call("ui_tree", "{\"since\":\"last\"}"));
    try testing.expect(std.mem.indexOf(u8, res, "delta") == null);
    try testing.expect(std.mem.startsWith(u8, res, "display=0 scale=2 window=0x1a2b\ne1 window"));
}

test "ui_find matches name words without case or accents, role and state; at most 20 lines" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e1 edit "Éditeur de texte" [=Bonjour 'monde'] {focused} @50,80,600,340
    , t.text(try h.call("ui_find", "{\"query\":\"EDITEUR\"}")));
    const buttons = t.text(try h.call("ui_find", "{\"query\":\"role:button\"}"));
    try t.expectContains(buttons, "button \"Enregistrer\"");
    try t.expectContains(buttons, "button \"Imprimer\" {disabled}");
    try t.expectContains(t.text(try h.call("ui_find", "{\"query\":\"state:checked \\\"automatique à\\\"\"}")), "checkbox \"Retour automatique");
    // Off-screen elements are found, so scroll_into_view can reach them.
    try t.expectContains(t.text(try h.call("ui_find", "{\"query\":\"hors champ\"}")), "{offscreen}");
    const bad = try h.call("ui_find", "{\"query\":\"role:bouton\"}");
    try testing.expect(t.isError(bad));
    try t.expectContains(t.text(bad), "Rôle `bouton` inconnu : rôles valides button, ");
    try t.expectContains(t.text(try h.call("ui_find", "{\"query\":\"zzz\"}")), "Aucun élément ne correspond à `zzz`");

    var many: [30]Element = undefined;
    many[0] = fake.ui_fixture[0];
    for (many[1..], 1..) |*e, i| e.* = .{ .key = 900 + i, .depth = 1, .role = .listitem, .name = "Fichier récent", .rect = .{ .x = 100, .y = 100, .w = 50, .h = 10 } };
    h.backend.ui_elements = &many;
    const capped = t.text(try h.call("ui_find", "{\"query\":\"fichier recent\"}"));
    try testing.expectEqual(@as(usize, 22), std.mem.count(u8, capped, "\n") + 1);
    try t.expectContains(capped, "… 9 autres résultats : précise la requête.");
}

test "ui_act checks preconditions, reports stale ids and falls back to a click" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("ui_tree", "{}");
    const ok = try h.call("ui_act", "{\"id\":\"e7\",\"action\":\"invoke\",\"observe\":\"none\"}");
    try testing.expectEqualStrings("ok : invoke e7", t.text(ok));
    try testing.expectEqual(uitree.Action.invoke, h.backend.ui_last_act.?.action);

    const unknown = try h.call("ui_act", "{\"id\":\"e1k\",\"action\":\"invoke\"}");
    try testing.expect(t.isError(unknown));
    try testing.expectEqualStrings("Élément e1k introuvable : rappelle ui_tree", t.text(unknown));
    const disabled = try h.call("ui_act", "{\"id\":\"e9\",\"action\":\"invoke\"}");
    try t.expectContains(t.text(disabled), "Précondition non remplie : e9 est désactivé");
    const unsupported = try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"invoke\"}");
    try testing.expect(t.isError(unsupported));
    try t.expectContains(t.text(unsupported), "e8 ne supporte pas invoke (pattern Invoke absent)");
    try testing.expectEqual(@as(usize, 0), h.backend.mouse_len);
    const no_value = try h.call("ui_act", "{\"id\":\"e5\",\"action\":\"set_value\"}");
    try t.expectContains(t.text(no_value), "set_value demande le champ `value`");

    // Pattern missing with fallback: a click at the center of the element.
    const clicked = try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"invoke\",\"fallback\":\"click\",\"observe\":\"none\"}");
    try testing.expect(!t.isError(clicked));
    try t.expectContains(t.text(clicked), "clic gauche injecté au centre de l'élément (fallback)");
    try testing.expectEqual(@as(usize, 3), h.backend.mouse_len);
    try testing.expectEqual([2]i32{ 750, 855 }, h.backend.mouse[0].move);

    // Off-screen: refused except for scroll_into_view.
    _ = try h.call("ui_find", "{\"query\":\"hors champ\"}");
    const off = try h.call("ui_act", "{\"id\":\"eb\",\"action\":\"select\"}");
    try t.expectContains(t.text(off), "eb est hors écran");
    try testing.expect(!t.isError(try h.call("ui_act", "{\"id\":\"eb\",\"action\":\"scroll_into_view\",\"observe\":\"none\"}")));

    // The element disappears between ui_tree and ui_act.
    h.backend.ui_elements = fake.ui_fixture[0..5];
    const gone = try h.call("ui_act", "{\"id\":\"e7\",\"action\":\"invoke\"}");
    try testing.expectEqualStrings("Élément e7 introuvable : rappelle ui_tree", t.text(gone));
}

test "action tools return the observation after the screen settles" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("screenshot", "{\"display\":0}");
    const first = t.text(try h.call("left_click", "{\"coordinate\":[10,10]}"));
    try testing.expect(std.mem.startsWith(u8, first, "ok ; settled in "));
    try t.expectContains(first, "Aucun arbre précédent de cette fenêtre : arbre complet.\ndisplay=0 scale=2 window=0x1a2b\ne1 window");
    const second = t.text(try h.call("key", "{\"text\":\"a\"}"));
    try t.expectContains(second, "\ndisplay=0 scale=2 window=0x1a2b delta: aucun changement");
    try testing.expectEqualStrings("ok", t.text(try h.call("key", "{\"text\":\"a\",\"observe\":\"none\"}")));

    const shot = try h.call("type", "{\"text\":\"x\",\"observe\":\"screenshot\"}");
    try testing.expectEqualStrings("image", t.block(shot, 0).get("type").?.string);
    try t.expectContains(t.text(shot), "settled in ");
    try t.expectContains(t.text(shot), "display=0 scale=2 size=1280x720");

    // ui_act observes the element's window.
    const acted = t.text(try h.call("ui_act", "{\"id\":\"e7\",\"action\":\"invoke\"}"));
    try testing.expect(std.mem.startsWith(u8, acted, "ok : invoke e7 ; settled in "));

    // Continuous animation: the wait expires without an error.
    h.backend.animating = true;
    const busy = try h.call("scroll", "{\"scroll_direction\":\"down\",\"scroll_amount\":1,\"settle_timeout_ms\":60}");
    try testing.expect(!t.isError(busy));
    try testing.expect(std.mem.startsWith(u8, t.text(busy), "ok ; settle timeout\n"));
    const too_long = try h.call("key", "{\"text\":\"a\",\"settle_timeout_ms\":10001}");
    try testing.expect(t.isError(too_long));
    try t.expectContains(t.text(too_long), "settle_timeout_ms");
    // A failed action is returned without waiting or observing.
    const failed = try h.call("left_click", "{\"coordinate\":[5000,0]}");
    try testing.expect(t.isError(failed));
    try testing.expect(std.mem.indexOf(u8, t.text(failed), "settle") == null);
}

test "vision mode lists only the toolset and observes with screenshots" {
    var h: t.Harness = .{};
    h.initWith(testing.allocator, .{ .mode = .vision });
    defer h.deinit();
    h.out.clearRetainingCapacity();
    try h.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", &h.out.writer);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), h.out.written(), .{});
    const listed = list.object.get("result").?.object.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, tools.toolset.len), listed.len);
    for (listed) |tool| try testing.expect(!std.mem.startsWith(u8, tool.object.get("name").?.string, "ui_"));

    h.out.clearRetainingCapacity();
    try h.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ui_tree\",\"arguments\":{}}}", &h.out.writer);
    try t.expectContains(h.out.written(), "\"code\":-32602");

    const click = try h.call("left_click", "{\"coordinate\":[10,10]}");
    try testing.expectEqualStrings("image", t.block(click, 0).get("type").?.string);

    // Its instructions name no tool it does not list.
    h.out.clearRetainingCapacity();
    try h.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}", &h.out.writer);
    const init = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), h.out.written(), .{});
    const instr = init.object.get("result").?.object.get("instructions").?.string;
    try testing.expectEqualStrings(@import("mcp.zig").vision_instructions, instr);
    for ([_][]const u8{ "ui_tree", "ui_find", "ui_act", "window_list" }) |name| try testing.expect(std.mem.indexOf(u8, instr, name) == null);
}

test "ui_tree since:last allocates nothing from the backing allocator in steady state" {
    var counter: CountingAllocator = .init(testing.allocator);
    var h: t.Harness = .{};
    h.init(counter.allocator());
    defer h.deinit();
    for (0..100) |_| _ = try h.call("ui_tree", "{\"since\":\"last\"}");
    const warm = counter.count();
    for (0..1000) |_| _ = try h.call("ui_tree", "{\"since\":\"last\"}");
    try testing.expectEqual(warm, counter.count());
}

// ---------------------------------------------------------------- US-022

const slider_tree = [_]Element{
    .{ .key = 600, .depth = 0, .role = .window, .name = "Réglages", .rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 } },
    .{ .key = 601, .depth = 1, .role = .slider, .name = "Volume", .range = .{ .value = 40, .min = 0, .max = 100 }, .rect = .{ .x = 10, .y = 10, .w = 200, .h = 20 } },
    .{ .key = 602, .depth = 1, .role = .progressbar, .name = "Copie", .range = .{ .value = 0.25, .min = 0, .max = 1.5, .read_only = true }, .rect = .{ .x = 10, .y = 40, .w = 200, .h = 20 } },
    .{ .key = 603, .depth = 1, .role = .pane, .name = "Liste", .scroll = .{ .v = 40, .h = 12.6 }, .rect = .{ .x = 10, .y = 70, .w = 400, .h = 300 } },
    .{ .key = 604, .depth = 1, .role = .pane, .name = "Large", .scroll = .{ .h = 0 }, .rect = .{ .x = 10, .y = 380, .w = 400, .h = 100 } },
    .{ .key = 605, .depth = 1, .role = .pane, .name = "Fixe", .scroll = .{}, .rect = .{ .x = 10, .y = 490, .w = 400, .h = 100 } },
    .{ .key = 606, .depth = 1, .role = .edit, .name = "Note", .value = "Bonjour le monde", .selection = "le monde", .states = .{ .focused = true }, .actions = .{ .value = true }, .rect = .{ .x = 500, .y = 10, .w = 400, .h = 30 } },
    .{ .key = 607, .depth = 1, .role = .edit, .name = "Code", .password = true, .selection = "hunter2", .actions = .{ .value = true }, .rect = .{ .x = 500, .y = 50, .w = 400, .h = 30 } },
};

test "ui_tree shows ranges, scroll positions and the focused selection, never a password's" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_elements = &slider_tree;
    const tree = t.text(try h.call("ui_tree", "{}"));
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e1 window "Réglages" @0,0,500,400
        \\  e2 slider "Volume" [=40/0..100] @5,5,100,10
        \\  e3 progressbar "Copie" [=0.25/0..1.5] @5,20,100,10
        \\  e4 pane "Liste" scroll=40%,h13% @5,35,200,150
        \\  e5 pane "Large" scroll=h0% @5,190,200,50
        \\  e6 pane "Fixe" @5,245,200,50
        \\  e7 edit "Note" [=Bonjour le monde] sel="le monde" {focused} @250,5,200,15
        \\  e8 edit "Code" [=•••] @250,25,200,15
    , tree);
    try testing.expect(std.mem.indexOf(u8, tree, "hunter2") == null);
}

test "a selection is cut at 100 characters, and a nameless scrollable container is kept" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const long: [150]u8 = @splat('x');
    const els = [_]Element{
        slider_tree[0],
        .{ .key = 610, .depth = 1, .role = .pane, .scroll = .{ .v = 100 }, .rect = .{ .x = 10, .y = 10, .w = 200, .h = 200 } },
        .{ .key = 611, .depth = 2, .role = .edit, .name = "Texte", .selection = &long, .states = .{ .focused = true }, .rect = .{ .x = 10, .y = 10, .w = 200, .h = 30 } },
    };
    h.backend.ui_elements = &els;
    const tree = t.text(try h.call("ui_tree", "{}"));
    try t.expectContains(tree, "  e2 pane \"\" scroll=100% @5,5,100,100");
    const shown: [100]u8 = @splat('x');
    try t.expectContains(tree, " sel=\"" ++ shown ++ "…\" {focused}");
}

test "since:last reports a change of value, bounds, scroll position or selection" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    var els: [slider_tree.len]Element = slider_tree;
    h.backend.ui_elements = &els;
    _ = try h.call("ui_tree", "{}");
    els[1].range.?.value = 55; // value
    els[2].range.?.max = 2; // bounds
    els[3].scroll.?.v = 80; // scroll
    els[6].selection = "Bonjour"; // selection
    els[4].scroll.?.h = 0.2; // rounds to the same percentage: no change
    const delta = t.text(try h.call("ui_tree", "{\"since\":\"last\"}"));
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b delta +0 -0 ~4
        \\~ e2 slider "Volume" [=55/0..100] @5,5,100,10
        \\~ e3 progressbar "Copie" [=0.25/0..2] @5,20,100,10
        \\~ e4 pane "Liste" scroll=80%,h13% @5,35,200,150
        \\~ e7 edit "Note" [=Bonjour le monde] sel="Bonjour" {focused} @250,5,200,15
    , delta);
    // A selection that empties is a change too.
    els[6].selection = null;
    try t.expectContains(t.text(try h.call("ui_tree", "{\"since\":\"last\"}")), "~ e7 edit \"Note\" [=Bonjour le monde] {focused}");
}

// ---------------------------------------------------------------- US-023

const display_mod = @import("display.zig");

/// A context menu on display 1 (left of the primary display), and a modal
/// dialog owned by Notepad on display 0.
const context_menu = [_]Element{
    .{ .key = 700, .depth = 0, .role = .menu, .name = "Contexte", .rect = .{ .x = -1800, .y = 300, .w = 300, .h = 200 } },
    .{ .key = 701, .depth = 1, .role = .menuitem, .name = "Annuler", .actions = .{ .invoke = true }, .rect = .{ .x = -1790, .y = 310, .w = 280, .h = 30 } },
    .{ .key = 702, .depth = 1, .role = .menuitem, .name = "Coller", .actions = .{ .invoke = true }, .rect = .{ .x = -1790, .y = 350, .w = 280, .h = 30 } },
};

const save_dialog = [_]Element{
    .{ .key = 800, .depth = 0, .role = .window, .name = "Enregistrer sous", .rect = .{ .x = 400, .y = 300, .w = 600, .h = 400 } },
    .{ .key = 801, .depth = 1, .role = .edit, .name = "Code d'accès", .value = "s3cret", .password = true, .actions = .{ .value = true }, .rect = .{ .x = 420, .y = 340, .w = 300, .h = 30 } },
    .{ .key = 802, .depth = 1, .role = .button, .name = "Enregistrer", .actions = .{ .invoke = true }, .rect = .{ .x = 800, .y = 640, .w = 100, .h = 30 } },
};

const kp_window = [_]Element{
    .{ .key = 900, .depth = 0, .role = .window, .name = "Coffre", .rect = .{ .x = 1000, .y = 500, .w = 400, .h = 300 } },
    .{ .key = 901, .depth = 1, .role = .edit, .name = "Entrée secrète", .value = "top-secret", .actions = .{ .value = true }, .rect = .{ .x = 1010, .y = 510, .w = 300, .h = 30 } },
};

/// Notepad, plus a KeePassXC window (deny by default) listed as a root.
const root_windows = fake.Fake.windows_fixture ++ [_]display_mod.WindowInfo{
    .{ .handle = 0x7a7a, .title = "Coffre", .exe = "KeePassXC.exe", .pid = 31, .rect = .{ .x = 1000, .y = 500, .w = 400, .h = 300 }, .elevated = false, .minimized = false, .cloaked = false },
};

const menu_root: fake.ExtraRoot = .{ .window = .{ .handle = 0x9100, .pid = 4242 }, .elements = &context_menu };
const dialog_root: fake.ExtraRoot = .{ .window = .{ .handle = 0x9200, .pid = 4242 }, .modal = true, .elements = &save_dialog };
const denied_root: fake.ExtraRoot = .{ .window = .{ .handle = 0x7a7a, .pid = 31 }, .elements = &kp_window };

test "a snapshot lists menus, popups and owned windows as roots, each in its own display's space" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.windows = &root_windows;
    h.backend.ui_elements = fake.ui_fixture[0..3];
    const extra = [_]fake.ExtraRoot{ menu_root, denied_root, dialog_root };
    h.backend.ui_extra = &extra;
    const tree = t.text(try h.call("ui_tree", "{}"));
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e1 window "Sans titre - Bloc-notes" @50,40,600,400
        \\  e2 menubar "Application" @50,60,600,20
        \\display=1 scale=1.5 window=0x9100
        \\e3 menu "Contexte" @80,66,200,134
        \\  e4 menuitem "Annuler" @86,73,188,21
        \\  e5 menuitem "Coller" @86,100,188,20
        \\display=0 scale=2 window=0x9200 {modal}
        \\e6 window "Enregistrer sous" @200,150,300,200
        \\  e7 edit "Code d'accès" [=•••] @210,170,150,15
        \\  e8 button "Enregistrer" @400,320,50,15
        \\… 1 nœuds élagués
    , tree);
    // The deny application is never read: the core did not request it.
    try testing.expectEqual(@as(usize, 2), h.backend.ui_requested);
    try testing.expect(std.mem.indexOf(u8, tree, "Coffre") == null);
    try testing.expect(std.mem.indexOf(u8, tree, "top-secret") == null);
    try testing.expect(std.mem.indexOf(u8, tree, "s3cret") == null);
    // The window's display stays the space of incoming coordinates.
    try testing.expectEqual(@as(?usize, 0), h.server.session.current);
}

test "ids of a root that persists stay stable; the delta shows roots appearing and vanishing" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_elements = fake.ui_fixture[0..3];
    _ = try h.call("ui_tree", "{}");
    const with_menu = [_]fake.ExtraRoot{menu_root};
    h.backend.ui_extra = &with_menu;
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b delta +3 -0 ~0
        \\+ display=1 scale=1.5 window=0x9100
        \\+ e3 menu "Contexte" @80,66,200,134
        \\+ e4 menuitem "Annuler" @86,73,188,21
        \\+ e5 menuitem "Coller" @86,100,188,20
    , t.text(try h.call("ui_tree", "{\"since\":\"last\"}")));
    // Unchanged: same ids, no change.
    try testing.expectEqualStrings("display=0 scale=2 window=0x1a2b delta: aucun changement", t.text(try h.call("ui_tree", "{\"since\":\"last\"}")));
    const full = t.text(try h.call("ui_tree", "{}"));
    try t.expectContains(full, "e4 menuitem \"Annuler\"");
    h.backend.ui_extra = &.{};
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b delta +0 -3 ~0
        \\- window=0x9100
        \\- e3 menu
        \\- e4 menuitem
        \\- e5 menuitem
    , t.text(try h.call("ui_tree", "{\"since\":\"last\"}")));
}

test "after a right click the delta lists the context menu, and ui_act invokes one of its items" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_elements = fake.ui_fixture[0..3];
    _ = try h.call("ui_tree", "{}");
    // The click opens the menu (the fake serves it from now on).
    const with_menu = [_]fake.ExtraRoot{menu_root};
    h.backend.ui_extra = &with_menu;
    const clicked = t.text(try h.call("right_click", "{\"coordinate\":[300,200]}"));
    try t.expectContains(clicked, "+ display=1 scale=1.5 window=0x9100\n+ e3 menu \"Contexte\"");
    try t.expectContains(clicked, "+ e5 menuitem \"Coller\"");
    const acted = t.text(try h.call("ui_act", "{\"id\":\"e5\",\"action\":\"invoke\",\"observe\":\"none\"}"));
    try testing.expectEqualStrings("ok : invoke e5", acted);
    try testing.expectEqual(@as(u64, 702), h.backend.ui_last_act.?.key);
    // The item belongs to the menu, its observation reads Notepad's tree.
    const owner = h.server.session.ui.ids.owner(5).?;
    try testing.expectEqual(@as(u64, 0x9100), owner.window);
    try testing.expectEqual(@as(u64, 0x1a2b), owner.tree);
    const observed = t.text(try h.call("ui_act", "{\"id\":\"e4\",\"action\":\"invoke\"}"));
    try t.expectContains(observed, "ok : invoke e4 ; settled in ");
    try t.expectContains(observed, "window=0x1a2b");
}

test "a menu closed between ui_tree and ui_act: no action, the element is gone" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_elements = fake.ui_fixture[0..3];
    const with_menu = [_]fake.ExtraRoot{menu_root};
    h.backend.ui_extra = &with_menu;
    _ = try h.call("ui_tree", "{}");
    h.backend.ui_extra = &.{};
    const r = try h.call("ui_act", "{\"id\":\"e4\",\"action\":\"invoke\"}");
    try testing.expect(t.isError(r));
    try testing.expectEqualStrings("Élément e4 introuvable : rappelle ui_tree", t.text(r));
    try testing.expect(h.backend.ui_last_act == null);
}

test "ui_find searches every root and opens each one's header" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_elements = fake.ui_fixture[0..3];
    const with_menu = [_]fake.ExtraRoot{menu_root};
    h.backend.ui_extra = &with_menu;
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\display=1 scale=1.5 window=0x9100
        \\e1 menuitem "Coller" @86,100,188,20
    , t.text(try h.call("ui_find", "{\"query\":\"coller\"}")));
}

// ---------------------------------------------------------------- US-024

const web_page = [_]Element{
    .{ .key = 1000, .depth = 0, .role = .window, .name = "Article - Google Chrome", .rect = .{ .x = 0, .y = 0, .w = 2000, .h = 1400 } },
    .{ .key = 1001, .depth = 1, .role = .document, .name = "Article", .rect = .{ .x = 0, .y = 100, .w = 2000, .h = 1300 } },
    .{ .key = 1002, .depth = 2, .role = .text, .name = "Titre de l'article", .rect = .{ .x = 20, .y = 120, .w = 800, .h = 40 } },
    .{ .key = 1003, .depth = 2, .role = .link, .name = "Lien", .actions = .{ .invoke = true }, .rect = .{ .x = 20, .y = 170, .w = 80, .h = 20 } },
    .{ .key = 1004, .depth = 3, .role = .text, .name = "Lien", .rect = .{ .x = 20, .y = 170, .w = 80, .h = 20 } },
    .{ .key = 1005, .depth = 2, .role = .text, .name = " : la suite du paragraphe, qui continue bien au-delà de quatre-vingts caractères pour montrer que le texte n'est pas coupé.", .rect = .{ .x = 100, .y = 170, .w = 1800, .h = 20 } },
    .{ .key = 1006, .depth = 2, .role = .text, .name = "Plus bas", .states = .{ .offscreen = true }, .rect = .{ .x = 20, .y = 3000, .w = 800, .h = 20 } },
};

test "ui_tree text:true shows a web page's visible text in reading order with the page position" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_web = &web_page;
    h.backend.ui_page = .{ .at = 40 };
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e1 window "Article - Google Chrome" @0,0,1000,700
        \\  e2 document "Article" page=40% @0,50,1000,650
        \\    e3 text "Titre de l'article" @10,60,400,20
        \\    e4 link "Lien" @10,85,40,10
        \\    e5 text " : la suite du paragraphe, qui continue bien au-delà de quatre-vingts caractères pour montrer que le texte n'est pas coupé." @50,85,900,10
        \\… 2 nœuds élagués
    , t.text(try h.call("ui_tree", "{\"text\":true}")));
    h.backend.ui_page = .{ .at = 0 };
    try t.expectContains(t.text(try h.call("ui_tree", "{\"text\":true}")), "document \"Article\" page=0% début @");
    h.backend.ui_page = .{ .at = 100 };
    try t.expectContains(t.text(try h.call("ui_tree", "{\"text\":true}")), "document \"Article\" page=100% fin @");
    // Without text, the tree is the usual one (FR-23).
    const plain = t.text(try h.call("ui_tree", "{}"));
    try testing.expect(std.mem.indexOf(u8, plain, "page=") == null);
    try testing.expectEqual(@as(usize, 0), h.backend.ui_requested);
}

test "text:true keeps a Chromium list item's text, joined with its link in the item's name; a page that fits shows both ends" {
    // Chromium folds `<li><a>Article 1</a> : note</li>` into a list item
    // named "Article 1 : note" over its link: no text node of its own.
    const items = [_]Element{
        web_page[0],
        web_page[1],
        .{ .key = 1100, .depth = 2, .role = .list, .rect = .{ .x = 20, .y = 200, .w = 1800, .h = 60 } },
        .{ .key = 1101, .depth = 3, .role = .listitem, .name = "Article 1 : note de synthèse numéro 1", .rect = .{ .x = 40, .y = 200, .w = 1800, .h = 20 } },
        .{ .key = 1102, .depth = 4, .role = .link, .name = "Article 1", .actions = .{ .invoke = true }, .rect = .{ .x = 40, .y = 200, .w = 80, .h = 20 } },
        .{ .key = 1103, .depth = 3, .role = .listitem, .name = "Article 2", .rect = .{ .x = 40, .y = 220, .w = 1800, .h = 20 } },
        .{ .key = 1104, .depth = 4, .role = .link, .name = "Article 2", .actions = .{ .invoke = true }, .rect = .{ .x = 40, .y = 220, .w = 80, .h = 20 } },
    };
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_web = &items;
    h.backend.ui_page = .fits;
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e1 window "Article - Google Chrome" @0,0,1000,700
        \\  e2 document "Article" page=0% début fin @0,50,1000,650
        \\    e3 listitem "Article 1 : note de synthèse numéro 1" @20,100,900,10
        \\      e4 link "Article 1" @20,100,40,10
        \\    e5 link "Article 2" @20,110,40,10
        \\… 2 nœuds élagués
    , t.text(try h.call("ui_tree", "{\"text\":true}")));
    // Without text, the item is a wrapper around its link and goes.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try uitree.prune(arena.allocator(), &items, items[0].rect, .{})) |k| try testing.expect(items[k.index].role != .listitem);
}

test "a web page's text stays under 8,000 characters and says how many text lines were left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const els = try a.alloc(Element, 302);
    els[0] = web_page[0];
    els[1] = web_page[1];
    for (els[2..], 0..) |*e, i| e.* = .{
        .key = 2000 + i,
        .depth = 2,
        .role = .text,
        .name = try std.fmt.allocPrint(a, "Paragraphe {d} : un texte assez long pour remplir la sortie avant la fin de la page.", .{i}),
        .rect = .{ .x = 20, .y = @intCast(120 + i * 4), .w = 1800, .h = 4 },
    };
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_web = els;
    const out = t.text(try h.call("ui_tree", "{\"text\":true}"));
    try testing.expect(out.len <= 8000);
    const tail = out[std.mem.lastIndexOfScalar(u8, out, '\n').? + 1 ..];
    try testing.expect(std.mem.startsWith(u8, tail, "… "));
    try testing.expect(std.mem.endsWith(u8, tail, " lignes de texte omises : fais défiler puis rappelle ui_tree"));
}

test "text:true on a window without a web document returns the tree with a note; a pending web tree says to retry" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const out = t.text(try h.call("ui_tree", "{\"text\":true}"));
    try t.expectContains(out, "e5 edit \"Éditeur de texte\"");
    try testing.expect(std.mem.endsWith(u8, out, "Aucun document web dans cette fenêtre : texte non disponible"));
    h.backend.ui_web = &web_page;
    h.backend.ui_web_pending = true;
    const pending = t.text(try h.call("ui_tree", "{\"text\":true}"));
    try testing.expect(std.mem.endsWith(u8, pending, "rappelle ui_tree dans 1 s, ou utilise screenshot."));
    try testing.expect(std.mem.indexOf(u8, pending, "Titre de l'article") == null);
}

// ---------------------------------------------------------------- US-025

test "a Firefox window with its accessibility off says so after its frame" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_firefox_no_tree = true;
    const out = t.text(try h.call("ui_tree", "{}"));
    try t.expectContains(out, "e1 window");
    try testing.expect(std.mem.endsWith(u8, out, "\nFirefox n'expose pas son arbre d'accessibilité : vérifie accessibility.force_disabled ou utilise screenshot"));
    // With text requested, the same note replaces the missing-document one.
    const text = t.text(try h.call("ui_tree", "{\"text\":true}"));
    try testing.expect(std.mem.endsWith(u8, text, "ou utilise screenshot"));
    try testing.expect(std.mem.indexOf(u8, text, "Aucun document web") == null);
}

test "the instructions say a web page's text is untrusted data" {
    try t.expectContains(mcp.instructions, "text: true");
    try t.expectContains(mcp.instructions, "untrusted data");
}
