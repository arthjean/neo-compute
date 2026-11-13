//! EP-014 targeted perception through the real dispatcher (`tools/call` JSON
//! in, JSON-RPC line out) against the fake backend: `ui_tree` with `root`
//! and `depth` (US-056), `ui_find` with `id:`, `value:` and a quoted name
//! (US-057), the `occluded` flag and the frozen-tree line (US-059).

const std = @import("std");
const testing = std.testing;
const t = @import("tools_test.zig");
const a11y = @import("a11y.zig");
const display = @import("display.zig");
const uitree = @import("uitree.zig");
const fake = @import("../backend/fake.zig");
const Element = uitree.Element;

const gone_e8 = "Élément e8 introuvable : rappelle ui_tree";

// ---------------------------------------------------------------- US-056

test "ui_tree root returns one element's subtree with the ids of the whole tree" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const full = t.text(try h.call("ui_tree", "{}"));
    const before = h.backend.ui_snapshots;

    const sub = try h.call("ui_tree", "{\"root\":\"e2\"}");
    try testing.expect(!t.isError(sub));
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e2 menubar "Application" @50,60,600,20
        \\  e3 menuitem "Fichier" {collapsed} @55,62,40,16
        \\  e4 menuitem "Édition" {collapsed} @100,62,40,16
    , t.text(sub));
    // Read from the element down: the window's tree was not read again.
    try testing.expectEqual(before, h.backend.ui_snapshots);
    try testing.expectEqual(@as(u32, 1), h.backend.ui_subtree_reads);
    // Every line of the subtree is a line of the whole tree, indentation
    // aside: same ids, same text.
    var lines = std.mem.splitScalar(u8, t.text(sub), '\n');
    while (lines.next()) |line| try t.expectContains(full, std.mem.trimStart(u8, line, " "));

    // A leaf is its own subtree, without the note of a bare window.
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e7 button "Enregistrer" @550,420,50,15
    , t.text(try h.call("ui_tree", "{\"root\":\"e7\"}")));

    // The window's last tree is left alone: the next delta compares with
    // the whole tree read first.
    try testing.expectEqualStrings("display=0 scale=2 window=0x1a2b delta: aucun changement", t.text(try h.call("ui_tree", "{\"since\":\"last\"}")));
}

test "ui_tree root: an unknown or gone element, root with since, a password, a deny application" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("ui_tree", "{}");

    const unknown = try h.call("ui_tree", "{\"root\":\"ezz\"}");
    try testing.expect(t.isError(unknown));
    try testing.expectEqualStrings("Élément ezz introuvable : rappelle ui_tree", t.text(unknown));
    const bad = try h.call("ui_tree", "{\"root\":\"bouton\"}");
    try testing.expect(t.isError(bad));
    try t.expectContains(t.text(bad), "Identifiant `bouton` invalide");

    const both = try h.call("ui_tree", "{\"root\":\"e2\",\"since\":\"last\"}");
    try testing.expect(t.isError(both));
    try testing.expectEqualStrings("root et since ne se combinent pas : lis le sous-arbre, puis le delta de la fenêtre.", t.text(both));
    try testing.expectEqual(@as(u32, 0), h.backend.ui_subtree_reads);

    // The password field as a root: masked like anywhere else.
    const secret = t.text(try h.call("ui_tree", "{\"root\":\"e6\"}"));
    try t.expectContains(secret, "e6 edit \"Mot de passe\" [=•••]");
    try testing.expect(std.mem.indexOf(u8, secret, "hunter2") == null);
    const marked = try h.call("ui_tree", "{\"root\":\"e6\",\"marks\":true}");
    try testing.expect(!t.isError(marked));
    try testing.expect(std.mem.indexOf(u8, t.text(marked), "hunter2") == null);

    // The element left the window.
    h.backend.ui_elements = fake.ui_fixture[0..6];
    const gone = try h.call("ui_tree", "{\"root\":\"e8\"}");
    try testing.expect(t.isError(gone));
    try testing.expectEqualStrings(gone_e8, t.text(gone));
    h.backend.ui_elements = &fake.ui_fixture;

    // The handle now belongs to a deny application: never read.
    const vault = [_]display.WindowInfo{
        .{ .handle = 0x1a2b, .title = "Coffre", .exe = "KeePassXC.exe", .pid = 31, .rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 }, .elevated = false, .minimized = false, .cloaked = false },
    };
    h.backend.windows = &vault;
    const reads = h.backend.ui_subtree_reads;
    const denied = try h.call("ui_tree", "{\"root\":\"e2\"}");
    try testing.expect(t.isError(denied));
    try t.expectContains(t.text(denied), "Politique : KeePassXC.exe est en mode deny");
    try testing.expectEqual(reads, h.backend.ui_subtree_reads);
    const reread = try h.call("ui_find", "{\"query\":\"id:e8\"}");
    try testing.expect(t.isError(reread));
    try t.expectContains(t.text(reread), "Politique : KeePassXC.exe est en mode deny");
    try testing.expectEqual(@as(u32, 0), h.backend.ui_element_reads);
}

test "ui_tree root gives a large subtree the whole output limit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A window of 600 named buttons, then a panel of 40 at the end: the
    // whole tree is cut long before the panel.
    const els = try a.alloc(Element, 643);
    els[0] = .{ .key = 1, .depth = 0, .role = .window, .name = "Éditeur", .rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1440 } };
    els[1] = .{ .key = 2, .depth = 1, .role = .toolbar, .name = "Barre", .rect = .{ .x = 0, .y = 0, .w = 2560, .h = 700 } };
    for (els[2..602], 0..) |*e, i| e.* = .{
        .key = 1000 + i,
        .depth = 2,
        .role = .button,
        .name = try std.fmt.allocPrint(a, "Commande numéro {d}", .{i}),
        .actions = .{ .invoke = true },
        .rect = .{ .x = @intCast(4 * (i % 600)), .y = 10, .w = 4, .h = 20 },
    };
    els[602] = .{ .key = 3, .depth = 1, .role = .group, .name = "Panneau", .rect = .{ .x = 0, .y = 700, .w = 2560, .h = 700 } };
    for (els[603..], 0..) |*e, i| e.* = .{
        .key = 5000 + i,
        .depth = 2,
        .role = .button,
        .name = try std.fmt.allocPrint(a, "Action du panneau {d}", .{i}),
        .actions = .{ .invoke = true },
        .rect = .{ .x = @intCast(40 * i), .y = 720, .w = 40, .h = 20 },
    };
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.ui_elements = els;
    const desk = [_]display.WindowInfo{win(0x1a2b, "Code.exe", 4242, els[0].rect)};
    h.backend.windows = &desk;

    const full = t.text(try h.call("ui_tree", "{}"));
    try testing.expect(full.len <= 8000);
    try testing.expect(std.mem.indexOf(u8, full, "Action du panneau 39") == null);

    // Depth 1 shows both containers and what each holds.
    const top = t.text(try h.call("ui_tree", "{\"depth\":1}"));
    try t.expectContains(top, "toolbar \"Barre\" @0,0,1280,350 … 600 descendants");
    try t.expectContains(top, "group \"Panneau\" @0,350,1280,350 … 40 descendants");
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, top, "\n") + 1);

    // The panel's id from that line, as the root of a tree of its own.
    const at = std.mem.indexOf(u8, top, " group \"Panneau\"").?;
    const id = top[std.mem.lastIndexOfScalar(u8, top[0..at], ' ').? + 1 .. at];
    const sub = t.text(try h.call("ui_tree", try std.fmt.allocPrint(a, "{{\"root\":\"{s}\"}}", .{id})));
    try testing.expect(sub.len <= 8000);
    try t.expectContains(sub, try std.fmt.allocPrint(a, "\n{s} group \"Panneau\"", .{id}));
    try t.expectContains(sub, "button \"Action du panneau 0\"");
    try t.expectContains(sub, "button \"Action du panneau 39\"");
    try testing.expect(std.mem.indexOf(u8, sub, "nœuds élagués") == null);
}

test "ui_tree depth stops at a level and counts what each line stands for; without it the output is unchanged" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const shallow = try h.call("ui_tree", "{\"depth\":1}");
    try testing.expect(!t.isError(shallow));
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e1 window "Sans titre - Bloc-notes" @50,40,600,400
        \\  e2 menubar "Application" @50,60,600,20 … 2 descendants
        \\  e5 edit "Éditeur de texte" [=Bonjour 'monde'] {focused} @50,80,600,340
        \\  e6 edit "Mot de passe" [=•••] @50,420,200,15
        \\  e7 button "Enregistrer" @550,420,50,15
        \\  e8 checkbox "Retour automatique à la ligne" {checked} @300,420,150,15
        \\  e9 button "Imprimer" {disabled} @475,420,50,15
        \\  ea text "Ligne 1, colonne 1" @50,435,100,5
        \\… 2 nœuds élagués
    , t.text(shallow));
    // The element at the limit keeps its id: it is a valid root, and depth
    // applies below it.
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e2 menubar "Application" @50,60,600,20
        \\  e3 menuitem "Fichier" {collapsed} @55,62,40,16
        \\  e4 menuitem "Édition" {collapsed} @100,62,40,16
    , t.text(try h.call("ui_tree", "{\"root\":\"e2\",\"depth\":1}")));
    // A limit deeper than the tree changes nothing, as no limit at all.
    const deep = t.text(try h.call("ui_tree", "{\"depth\":25}"));
    const plain = t.text(try h.call("ui_tree", "{}"));
    try testing.expectEqualStrings(plain, deep);
    try testing.expect(std.mem.indexOf(u8, plain, "descendants") == null);
    try t.expectContains(plain, "    e3 menuitem \"Fichier\"");
    // 1 to 25.
    try testing.expect(t.isError(try h.call("ui_tree", "{\"depth\":0}")));
    try testing.expect(t.isError(try h.call("ui_tree", "{\"depth\":26}")));
}

// ---------------------------------------------------------------- US-057

test "ui_find id reads one element again without reading the window" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    _ = try h.call("ui_tree", "{}");
    const before = h.backend.ui_snapshots;

    const line = try h.call("ui_find", "{\"query\":\"id:e8\"}");
    try testing.expect(!t.isError(line));
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e8 checkbox "Retour automatique à la ligne" {checked} @300,420,150,15
    , t.text(line));
    try testing.expectEqual(@as(u32, 1), h.backend.ui_element_reads);

    // Its state now, after an action, still without a tree.
    try testing.expect(!t.isError(try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"toggle\",\"observe\":\"none\"}")));
    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e8 checkbox "Retour automatique à la ligne" @300,420,150,15
    , t.text(try h.call("ui_find", "{\"query\":\"  id:e8 \"}")));
    try testing.expectEqual(before, h.backend.ui_snapshots);
    try testing.expectEqual(@as(u32, 0), h.backend.ui_subtree_reads);

    // A password field stays masked.
    const secret = t.text(try h.call("ui_find", "{\"query\":\"id:e6\"}"));
    try t.expectContains(secret, "e6 edit \"Mot de passe\" [=•••]");
    try testing.expect(std.mem.indexOf(u8, secret, "hunter2") == null);

    // Unknown, then gone from the window.
    const unknown = try h.call("ui_find", "{\"query\":\"id:ezz\"}");
    try testing.expect(t.isError(unknown));
    try testing.expectEqualStrings("Élément ezz introuvable : rappelle ui_tree", t.text(unknown));
    h.backend.ui_elements = fake.ui_fixture[0..6];
    const gone = try h.call("ui_find", "{\"query\":\"id:e8\"}");
    try testing.expect(t.isError(gone));
    try testing.expectEqualStrings(gone_e8, t.text(gone));

    // id: reads one element: no other term, no wait.
    const mixed = try h.call("ui_find", "{\"query\":\"id:e8 role:checkbox\"}");
    try testing.expect(t.isError(mixed));
    try t.expectContains(t.text(mixed), "id:<id> s'utilise seul");
    const waited = try h.call("ui_find", "{\"query\":\"id:e8\",\"wait_ms\":500}");
    try testing.expect(t.isError(waited));
    try t.expectContains(t.text(waited), "retire wait_ms");
    const invalid = try h.call("ui_find", "{\"query\":\"id:bouton\"}");
    try testing.expect(t.isError(invalid));
    try t.expectContains(t.text(invalid), "Identifiant `bouton` invalide");
}

test "ui_find value filters on the value, never a password's; a quoted term is the exact name" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();

    try testing.expectEqualStrings(
        \\display=0 scale=2 window=0x1a2b
        \\e1 edit "Éditeur de texte" [=Bonjour 'monde'] {focused} @50,80,600,340
    , t.text(try h.call("ui_find", "{\"query\":\"value:MONDE\"}")));
    try t.expectContains(t.text(try h.call("ui_find", "{\"query\":\"role:edit value:bonjour\"}")), "edit \"Éditeur de texte\"");
    // Combined with a name that does not go with it: nothing.
    try t.expectContains(t.text(try h.call("ui_find", "{\"query\":\"enregistrer value:bonjour\"}")), "Aucun élément ne correspond");
    // The password's value never matches, whole or in part.
    for ([_][]const u8{ "{\"query\":\"value:hunter2\"}", "{\"query\":\"value:hunter\"}", "{\"query\":\"value:•••\"}" }) |args| {
        const res = t.text(try h.call("ui_find", args));
        try t.expectContains(res, "Aucun élément ne correspond");
        try testing.expect(std.mem.indexOf(u8, res, "Mot de passe") == null);
    }
    const empty = try h.call("ui_find", "{\"query\":\"value:\"}");
    try testing.expect(t.isError(empty));
    try t.expectContains(t.text(empty), "value: demande un texte");

    // Words match inside a name; a quoted term must be the whole name.
    const words = t.text(try h.call("ui_find", "{\"query\":\"ligne\"}"));
    try t.expectContains(words, "checkbox \"Retour automatique à la ligne\"");
    try t.expectContains(words, "text \"Ligne 1, colonne 1\"");
    const exact = t.text(try h.call("ui_find", "{\"query\":\"\\\"Ligne 1, colonne 1\\\"\"}"));
    try t.expectContains(exact, "text \"Ligne 1, colonne 1\"");
    try testing.expect(std.mem.indexOf(u8, exact, "checkbox") == null);
    try t.expectContains(t.text(try h.call("ui_find", "{\"query\":\"\\\"Ligne 1\\\"\"}")), "Aucun élément ne correspond");
    try t.expectContains(t.text(try h.call("ui_find", "{\"query\":\"role:button \\\"enregistrer\\\"\"}")), "button \"Enregistrer\"");
}

test "ui_find past 20 matches says how many first" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    var many: [46]Element = undefined;
    many[0] = fake.ui_fixture[0];
    for (many[1..], 1..) |*e, i| e.* = .{ .key = 900 + i, .depth = 1, .role = .listitem, .name = "Fichier récent", .rect = .{ .x = 100, .y = 100, .w = 50, .h = 10 } };
    h.backend.ui_elements = &many;
    const capped = t.text(try h.call("ui_find", "{\"query\":\"\\\"fichier recent\\\"\"}"));
    try testing.expect(std.mem.startsWith(u8, capped, "45 correspondances, 20 affichées\ndisplay=0 scale=2 window=0x1a2b\n"));
    try testing.expectEqual(@as(usize, 20), std.mem.count(u8, capped, "listitem \"Fichier récent\""));
    // Twenty or fewer: no count line.
    h.backend.ui_elements = many[0..21];
    const all = t.text(try h.call("ui_find", "{\"query\":\"fichier recent\"}"));
    try testing.expect(std.mem.startsWith(u8, all, "display=0 scale=2 window=0x1a2b\n"));
    try testing.expectEqual(@as(usize, 20), std.mem.count(u8, all, "listitem \"Fichier récent\""));
}

// ---------------------------------------------------------------- US-059

const notepad_rect: display.Rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 };

fn win(handle: u64, exe: []const u8, pid: u32, rect: display.Rect) display.WindowInfo {
    return .{ .handle = handle, .title = "Fenêtre", .exe = exe, .pid = pid, .rect = rect, .elevated = false, .minimized = false, .cloaked = false };
}

const header = "display=0 scale=2 window=0x1a2b";

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

/// The window_list line of window `handle`.
fn listed(list: []const u8, comptime handle: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, list, "\n" ++ handle ++ " ").? + 1;
    return list[at..][0 .. std.mem.indexOfScalar(u8, list[at..], '\n') orelse list.len - at];
}

test "a window covered by one window is occluded in ui_tree, ui_find and window_list" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const desk = [_]display.WindowInfo{
        win(0xc0, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 2000, .h = 1000 }),
        win(0x1a2b, "notepad.exe", 4242, notepad_rect),
    };
    h.backend.windows = &desk;
    const tree = t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    try testing.expectEqualStrings(header ++ " {occluded}", firstLine(tree));
    // Not a Chromium window: its tree stays current, nothing to warn of.
    try testing.expect(std.mem.indexOf(u8, tree, "Fenêtre recouverte") == null);
    try testing.expectEqualStrings(header ++ " {occluded}", firstLine(t.text(try h.call("ui_find", "{\"query\":\"enregistrer\",\"window\":\"0x1a2b\"}"))));
    try testing.expectEqualStrings(header ++ " {occluded}", firstLine(t.text(try h.call("ui_find", "{\"query\":\"id:e7\"}"))));
    try testing.expectEqualStrings(header ++ " {occluded}", firstLine(t.text(try h.call("ui_tree", "{\"root\":\"e2\"}"))));

    const list = t.text(try h.call("window_list", "{}"));
    try testing.expect(std.mem.endsWith(u8, listed(list, "0x1a2b"), " z=1 {occluded}"));
    try testing.expect(std.mem.endsWith(u8, listed(list, "0xc0"), " z=0"));

    // One pixel in view: not occluded.
    const peek = [_]display.WindowInfo{
        win(0xc0, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 1299, .h = 1000 }),
        win(0x1a2b, "notepad.exe", 4242, notepad_rect),
    };
    h.backend.windows = &peek;
    try testing.expectEqualStrings(header, firstLine(t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"))));
    try testing.expect(std.mem.endsWith(u8, listed(t.text(try h.call("window_list", "{}")), "0x1a2b"), " z=1"));
}

test "the union of two windows occludes; a visible strip between them does not" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const joined = [_]display.WindowInfo{
        win(0xc1, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 700, .h = 1000 }),
        win(0xc2, "mspaint.exe", 51, .{ .x = 700, .y = 0, .w = 1300, .h = 1000 }),
        win(0x1a2b, "notepad.exe", 4242, notepad_rect),
    };
    h.backend.windows = &joined;
    try testing.expectEqualStrings(header ++ " {occluded}", firstLine(t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"))));

    // 16 px between the two: the strip US-058 recommends.
    const strip = [_]display.WindowInfo{
        win(0xc1, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 700, .h = 1000 }),
        win(0xc2, "mspaint.exe", 51, .{ .x = 716, .y = 0, .w = 1300, .h = 1000 }),
        win(0x1a2b, "notepad.exe", 4242, notepad_rect),
    };
    h.backend.windows = &strip;
    try testing.expectEqualStrings(header, firstLine(t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"))));

    // Minimized and cloaked windows above cover nothing.
    var ghosts = joined;
    ghosts[0].minimized = true;
    h.backend.windows = &ghosts;
    try testing.expectEqualStrings(header, firstLine(t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"))));
    ghosts[0].minimized = false;
    ghosts[1].cloaked = true;
    try testing.expectEqualStrings(header, firstLine(t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"))));
}

test "a window on another display, or across two, is not occluded by a window of one display" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    // The cover fills display 0; the target sits on display 1 (x < 0).
    const far = [_]display.WindowInfo{
        win(0xc0, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 2560, .h = 1440 }),
        win(0x2222, "notepad.exe", 4242, .{ .x = -1800, .y = 300, .w = 900, .h = 600 }),
    };
    h.backend.windows = &far;
    const tree = t.text(try h.call("ui_tree", "{\"window\":\"0x2222\"}"));
    try testing.expectEqualStrings("display=1 scale=1.5 window=0x2222", firstLine(tree));
    try testing.expect(std.mem.endsWith(u8, listed(t.text(try h.call("window_list", "{}")), "0x2222"), " z=1"));

    // Across both displays: display 0's part is covered, display 1's shows.
    const across = [_]display.WindowInfo{
        win(0xc0, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 2560, .h = 1440 }),
        win(0x2222, "notepad.exe", 4242, .{ .x = -400, .y = 300, .w = 900, .h = 600 }),
    };
    h.backend.windows = &across;
    try testing.expect(std.mem.indexOf(u8, firstLine(t.text(try h.call("ui_tree", "{\"window\":\"0x2222\"}"))), "occluded") == null);
    // Covered on display 1 as well: occluded.
    const both = [_]display.WindowInfo{
        win(0xc0, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 2560, .h = 1440 }),
        win(0xc3, "mspaint.exe", 51, .{ .x = -1920, .y = 200, .w = 1920, .h = 1080 }),
        win(0x2222, "notepad.exe", 4242, .{ .x = -400, .y = 300, .w = 900, .h = 600 }),
    };
    h.backend.windows = &both;
    try testing.expect(std.mem.endsWith(u8, firstLine(t.text(try h.call("ui_tree", "{\"window\":\"0x2222\"}"))), " {occluded}"));
}

test "a covered Chromium window says its tree may be frozen; Chromium's rules decide what covers it" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.server.session.verify_ms = 100;
    const desk = [_]display.WindowInfo{
        win(0xc0, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 2000, .h = 1000 }),
        win(0x1a2b, "chrome.exe", 4242, notepad_rect),
    };
    h.backend.windows = &desk;
    h.backend.chromium_windows = &.{0x1a2b};

    const tree = t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    try testing.expectEqualStrings(header ++ " {occluded}", firstLine(tree));
    try testing.expect(std.mem.endsWith(u8, tree, "\n" ++ a11y.frozen_covered));
    try testing.expect(std.mem.startsWith(u8, a11y.frozen_covered, "Fenêtre recouverte : Chromium suspend son rendu, l'arbre peut être figé. Déplace-la avec window_set pour "));
    // It replaces the advice to read again: reading builds nothing.
    h.backend.ui_web_pending = true;
    const pending = t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    try testing.expect(std.mem.endsWith(u8, pending, "\n" ++ a11y.frozen_covered));
    try testing.expect(std.mem.indexOf(u8, pending, "rappelle ui_tree dans 1 s") == null);
    h.backend.ui_web_pending = false;
    // An unchanged tree may only be one that is not current.
    try testing.expectEqualStrings(header ++ " {occluded} delta: aucun changement\n" ++ a11y.frozen_covered, t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\",\"since\":\"last\"}")));
    // An action whose effect does not show: delivered or not, the tree
    // cannot tell.
    h.backend.ui_stuck = true;
    const stuck = try h.call("ui_act", "{\"id\":\"e8\",\"action\":\"toggle\",\"observe\":\"none\"}");
    try testing.expect(t.isError(stuck));
    try testing.expect(std.mem.startsWith(u8, t.text(stuck), "toggle e8 : contredit, état lu coché."));
    try testing.expect(std.mem.endsWith(u8, t.text(stuck), "\n" ++ a11y.frozen_covered));
    h.backend.ui_stuck = false;

    // Chromium's tracker ignores a popup above: the window keeps rendering.
    h.backend.popup_windows = &.{0xc0};
    const under_popup = t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    try testing.expectEqualStrings(header, firstLine(under_popup));
    try testing.expect(std.mem.indexOf(u8, under_popup, "Fenêtre recouverte") == null);
    h.backend.popup_windows = &.{};

    // A strip in view: no flag, no line.
    const strip = [_]display.WindowInfo{
        win(0xc0, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 1284, .h = 1000 }),
        win(0x1a2b, "chrome.exe", 4242, notepad_rect),
    };
    h.backend.windows = &strip;
    const peeking = t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    try testing.expectEqualStrings(header, firstLine(peeking));
    try testing.expect(std.mem.indexOf(u8, peeking, "Chromium suspend") == null);

    // Minimized: not covered, frozen all the same.
    var hidden = desk;
    hidden[1].minimized = true;
    h.backend.windows = &hidden;
    const minimized = t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    try testing.expectEqualStrings(header, firstLine(minimized));
    try testing.expect(std.mem.endsWith(u8, minimized, "\n" ++ a11y.frozen_minimized));
}

test "an Electron application that turns occlusion off is flagged without the frozen-tree line" {
    var h: t.Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const desk = [_]display.WindowInfo{
        win(0xc0, "explorer.exe", 50, .{ .x = 0, .y = 0, .w = 2000, .h = 1000 }),
        win(0x1a2b, "Code.exe", 4242, notepad_rect),
    };
    h.backend.windows = &desk;
    h.backend.chromium_windows = &.{0x1a2b};
    const tree = t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    try testing.expectEqualStrings(header ++ " {occluded}", firstLine(tree));
    try testing.expect(std.mem.indexOf(u8, tree, "Chromium suspend") == null);
    // It is judged like any window: a popup above covers it.
    h.backend.popup_windows = &.{0xc0};
    try testing.expectEqualStrings(header ++ " {occluded}", firstLine(t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"))));
    // Minimized, it stops rendering like Chrome (US-058: 0 effect of 20):
    // no flag, the line that says to restore it.
    var hidden = desk;
    hidden[1].minimized = true;
    h.backend.windows = &hidden;
    const minimized = t.text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    try testing.expectEqualStrings(header, firstLine(minimized));
    try testing.expect(std.mem.endsWith(u8, minimized, "\n" ++ a11y.frozen_minimized));
}

test "hidden: one cover, the union of two, a strip, another display, too many pieces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const displays = fake.displays_fixture[0..];
    const target: display.Rect = .{ .x = 100, .y = 100, .w = 800, .h = 600 };
    try testing.expect(!display.hidden(a, target, displays, &.{}));
    try testing.expect(display.hidden(a, target, displays, &.{.{ .x = 0, .y = 0, .w = 1000, .h = 800 }}));
    try testing.expect(display.hidden(a, target, displays, &.{ .{ .x = 0, .y = 0, .w = 500, .h = 800 }, .{ .x = 500, .y = 0, .w = 500, .h = 800 } }));
    try testing.expect(!display.hidden(a, target, displays, &.{ .{ .x = 0, .y = 0, .w = 500, .h = 800 }, .{ .x = 501, .y = 0, .w = 500, .h = 800 } }));
    // The part outside every display counts for nothing.
    const edge: display.Rect = .{ .x = 2000, .y = 1000, .w = 1000, .h = 1000 };
    try testing.expect(display.hidden(a, edge, displays, &.{.{ .x = 1900, .y = 900, .w = 660, .h = 540 }}));
    try testing.expect(display.hidden(a, .{ .x = 5000, .y = 5000, .w = 100, .h = 100 }, displays, &.{}));
    // On display 1, a cover of display 0 hides nothing.
    try testing.expect(!display.hidden(a, .{ .x = -1800, .y = 300, .w = 900, .h = 600 }, displays, &.{displays[0].rect}));
}
