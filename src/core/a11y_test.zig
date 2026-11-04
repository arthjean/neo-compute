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
