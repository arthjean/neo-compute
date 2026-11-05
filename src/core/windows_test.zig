//! EP-006 window and application tools through the real dispatcher
//! (`tools/call` JSON in, JSON-RPC line out) against the fake backend:
//! window_set (US-027) and app_launch with the Start menu catalog (US-028,
//! US-029). window_list's display lines (US-026) are in tools_test.zig.

const std = @import("std");
const testing = std.testing;
const mcp = @import("mcp.zig");
const policy = @import("policy.zig");
const audit = @import("audit.zig");
const display = @import("display.zig");
const apps = @import("apps.zig");
const t = @import("tools_test.zig");
const Fake = @import("../backend/fake.zig").Fake;
const Harness = t.Harness;
const isError = t.isError;
const text = t.text;
const expectContains = t.expectContains;

fn harness(h: *Harness, options: mcp.Options) void {
    h.initWith(testing.allocator, options);
    // Short waits keep the timeouts testable.
    h.server.session.close_wait_ms = 200;
    h.server.session.launch_wait_ms = 300;
}

fn expectError(res: std.json.ObjectMap, message: []const u8) !void {
    try testing.expect(isError(res));
    try testing.expectEqualStrings(message, text(res));
}

// ---------------------------------------------------------------- window_set

test "window_set places the visible frame at a rectangle of the window's display and answers the rectangle obtained" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    // Left half of display 0 (1280x720 screenshot, scale 2).
    const res = try h.call("window_set", "{\"window\":\"0x1a2b\",\"rect\":[0,0,640,720],\"observe\":\"none\"}");
    try testing.expect(!isError(res));
    try testing.expectEqualStrings("0x1a2b normal display=0 @0,0,640,720", text(res));
    try testing.expectEqual(display.Rect{ .x = 0, .y = 0, .w = 1280, .h = 1440 }, h.backend.placed.?);
    // The right half of display 1 (scale 1.5, left of the primary one).
    const right = try h.call("window_set", "{\"window\":\"0x1a2b\",\"rect\":[640,0,640,720],\"display\":1,\"observe\":\"none\"}");
    try testing.expectEqualStrings("0x1a2b normal display=1 @640,0,640,720", text(right));
    try testing.expectEqual(display.Rect{ .x = -960, .y = 200, .w = 960, .h = 1080 }, h.backend.placed.?);
}

test "window_set reports an application that imposes its own size" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    h.backend.min_size = .{ 800, 600 };
    const res = try h.call("window_set", "{\"window\":\"0x1a2b\",\"rect\":[0,0,200,100],\"observe\":\"none\"}");
    try testing.expectEqualStrings("0x1a2b normal display=0 @0,0,400,300 (rectangle demandé @0,0,200,100 : l'application impose sa position ou sa taille)", text(res));
}

test "window_set changes the state and observes the window" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    const max = try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"maximized\"}");
    try testing.expectEqual(display.ShowState.maximized, h.backend.shown.?);
    try expectContains(text(max), "0x1a2b maximized display=0 @0,0,1280,720 ; settled in");
    try expectContains(text(max), "window=0x1a2b");
    const min = try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"minimized\",\"observe\":\"none\"}");
    try testing.expectEqualStrings("0x1a2b minimized", text(min));
    // A rectangle then a state: placed, then maximized on that display.
    _ = try h.call("window_set", "{\"window\":\"0x1a2b\",\"display\":1,\"state\":\"normal\",\"observe\":\"none\"}");
    try testing.expectEqual(display.ShowState.normal, h.backend.shown.?);
    try testing.expectEqual(display.Rect{ .x = -1920 + 360, .y = 200 + 140, .w = 1200, .h = 800 }, h.backend.placed.?);
}

test "a rectangle off the screen does nothing and names the valid bounds" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    for ([_][]const u8{ "[0,0,1281,100]", "[1200,600,100,200]", "[-1,0,10,10]", "[0,0,0,10]", "[2147483647,0,1,1]", "[0,1,10,2147483647]" }) |r| {
        const res = try h.call("window_set", try std.fmt.allocPrint(h.arena.allocator(), "{{\"window\":\"0x1a2b\",\"rect\":{s}}}", .{r}));
        try expectError(res, "Rectangle hors écran : bornes valides 0..1279 x 0..719");
    }
    try testing.expectEqual(@as(u32, 0), h.backend.set_calls);
}

test "window_set refuses an elevated window, a closed handle and a hung window" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    try expectError(try h.call("window_set", "{\"window\":\"0x3c4d\",\"state\":\"minimized\"}"), "Fenêtre élevée : injection bloquée par UIPI. Relance l'app sans élévation ou agis toi-même.");
    try expectError(try h.call("window_set", "{\"window\":\"0xdead\",\"rect\":[0,0,10,10]}"), "Fenêtre fermée : rappelle window_list");
    try expectError(try h.call("window_set", "{\"window\":\"0xdead\",\"state\":\"closed\"}"), "Fenêtre fermée : rappelle window_list");
    h.backend.hung = true;
    try expectError(try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"maximized\"}"), "La fenêtre 0x1a2b ne répond pas : réessaie, ou ferme-la avec state: closed et force: true.");
    try testing.expectEqual(@as(u32, 0), h.backend.set_calls);
    try testing.expectEqual(@as(u32, 0), h.backend.close_calls);
}

test "window_set argument combinations are checked before anything" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    try expectError(try h.call("window_set", "{\"window\":\"0x1a2b\"}"), "Passe rect, display ou state : window_set n'a rien à faire.");
    try expectError(try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"closed\",\"rect\":[0,0,10,10]}"), "state: closed ne prend ni rect ni display : retire-les.");
    try expectError(try h.call("window_set", "{\"window\":\"0x1a2b\",\"force\":true}"), "force ne s'applique qu'avec state: closed.");
    try expectError(try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"open\"}"), "Champ `state` : une valeur parmi normal, minimized, maximized, closed attendu");
    try testing.expectEqual(@as(u32, 0), h.backend.set_calls + h.backend.close_calls);
}

test "state closed sends the close request and reports the window closed" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    const res = try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"closed\"}");
    try testing.expect(!isError(res));
    try expectContains(text(res), "0x1a2b fermée ; ");
    try testing.expectEqual(@as(u32, 1), h.backend.close_calls);
    try testing.expectEqual(@as(?u32, null), h.backend.terminated);
}

test "a save dialog opened by the close request succeeds and shows in the observation" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    h.backend.on_close = .dialog;
    const res = try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"closed\"}");
    try testing.expect(!isError(res));
    try expectContains(text(res), "0x1a2b : fermeture demandée, un dialogue de l'application est ouvert (voir l'observation)");
    // The observation reads the dialog by its own handle: UIA nests an
    // owned dialog in its owner's tree, where it can be pruned.
    try expectContains(text(res), "\ndisplay=0 scale=2 window=0x9a9a {modal}\n");
    try testing.expect(std.mem.indexOf(u8, text(res), "Sans titre - Bloc-notes") == null);
    try expectContains(text(res), "Ne pas enregistrer");
    try expectContains(text(res), "{modal}");
}

test "a window still open after the wait succeeds without force" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    h.backend.on_close = .stays;
    const res = try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"closed\",\"observe\":\"none\"}");
    try testing.expectEqualStrings("0x1a2b : fermeture demandée, la fenêtre est encore ouverte après 2 s (dialogue ou fermeture lente)", text(res));
    try testing.expectEqual(@as(?u32, null), h.backend.terminated);
}

test "force ends the process still alive after the wait, at level full only, and is audited" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: audit.Audit = .{ .io = testing.io, .dir = tmp.dir };
    defer if (log.file) |f| f.close(testing.io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = policy.parse(arena.allocator(), "{\"apps\": {\"notepad.exe\": \"click\"}}", "p.json");
    {
        var c: Harness = .{};
        harness(&c, .{ .audit = &log, .policy = &p });
        defer c.deinit();
        c.backend.on_close = .stays;
        // `click` moves and closes, never ends a process.
        const refused = try c.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"closed\",\"force\":true}");
        try expectError(refused, "Politique : notepad.exe est en mode click : action refusée. Demande à Arthur de changer son niveau dans policy.json.");
        try testing.expectEqual(@as(u32, 0), c.backend.close_calls);
        try testing.expect(!isError(try c.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"minimized\",\"observe\":\"none\"}")));
    }
    var h: Harness = .{};
    harness(&h, .{ .audit = &log });
    defer h.deinit();
    h.backend.on_close = .stays;
    const res = try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"closed\",\"force\":true}");
    try testing.expect(!isError(res));
    try expectContains(text(res), "0x1a2b : processus notepad.exe (pid 4242) terminé, la fenêtre ne s'était pas fermée en 2 s");
    try testing.expectEqual(@as(?u32, 4242), h.backend.terminated);

    var buf: [4096]u8 = undefined;
    const data = try tmp.dir.readFile(testing.io, audit.file_name, &buf);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    try expectContains(lines.next().?, "\"result\":\"denied\",\"state\":\"closed\"}");
    try expectContains(lines.next().?, "\"result\":\"ok\",\"state\":\"minimized\"}");
    const forced = lines.next().?;
    try expectContains(forced, "\"tool\":\"window_set\",\"app\":\"notepad.exe\",\"pid\":4242,\"policy\":\"full\",");
    try expectContains(forced, "\"state\":\"closed\",\"terminated\":{\"pid\":4242,\"exe\":\"notepad.exe\"}}");
}

const protected_desk = [_]display.WindowInfo{
    .{ .handle = 0x1111, .title = "Explorateur", .exe = "explorer.exe", .pid = 500, .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    .{ .handle = 0x2222, .title = "Claude Code", .exe = "claude.exe", .pid = 8000, .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    .{ .handle = 0x3333, .title = "neo-compute", .exe = "neo-compute.exe", .pid = 9000, .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    .{ .handle = 0x4444, .title = "Calculatrice", .exe = "ApplicationFrameHost.exe", .pid = 600, .rect = .{ .x = 0, .y = 0, .w = 400, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    .{ .handle = 0x5555, .title = "Paramètres", .exe = "ApplicationFrameHost.exe", .pid = 600, .rect = .{ .x = 0, .y = 0, .w = 400, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    .{ .handle = 0x6666, .title = "csrss", .exe = "csrss.exe", .pid = 700, .rect = .{ .x = 0, .y = 0, .w = 400, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    .{ .handle = 0x7777, .title = "winlogon", .exe = "winlogon.exe", .pid = 701, .rect = .{ .x = 0, .y = 0, .w = 400, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    .{ .handle = 0x8888, .title = "lsass", .exe = "lsass.exe", .pid = 702, .rect = .{ .x = 0, .y = 0, .w = 400, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    .{ .handle = 0x9999, .title = "services", .exe = "services.exe", .pid = 703, .rect = .{ .x = 0, .y = 0, .w = 400, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    .{ .handle = 0x1234, .title = "Calculatrice", .exe = "CalculatorApp.exe", .pid = 610, .rect = .{ .x = 0, .y = 0, .w = 400, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
};

test "force refuses neo-compute, its ancestors and the protected system processes" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    h.backend.windows = &protected_desk;
    h.backend.on_close = .stays;
    // 0x4444 hosts CalculatorApp.exe (pid 610); 0x5555's application is unknown.
    h.backend.hosted = &.{.{ 0x4444, 610 }};
    const cases = [_]struct { handle: []const u8, exe: []const u8 }{
        .{ .handle = "0x1111", .exe = "explorer.exe" },
        .{ .handle = "0x2222", .exe = "claude.exe" },
        .{ .handle = "0x3333", .exe = "neo-compute.exe" },
        .{ .handle = "0x5555", .exe = "ApplicationFrameHost.exe" },
        .{ .handle = "0x6666", .exe = "csrss.exe" },
        .{ .handle = "0x7777", .exe = "winlogon.exe" },
        .{ .handle = "0x8888", .exe = "lsass.exe" },
        .{ .handle = "0x9999", .exe = "services.exe" },
    };
    for (cases) |c| {
        const res = try h.call("window_set", try std.fmt.allocPrint(h.arena.allocator(), "{{\"window\":\"{s}\",\"state\":\"closed\",\"force\":true}}", .{c.handle}));
        try expectError(res, try std.fmt.allocPrint(h.arena.allocator(), "Fermeture forcée refusée : {s} est protégé", .{c.exe}));
    }
    try testing.expectEqual(@as(u32, 0), h.backend.close_calls);
    // A UWP frame ends the application it hosts, never ApplicationFrameHost.exe.
    const uwp = try h.call("window_set", "{\"window\":\"0x4444\",\"state\":\"closed\",\"force\":true,\"observe\":\"none\"}");
    try expectContains(text(uwp), "processus CalculatorApp.exe (pid 610) terminé");
    try testing.expectEqual(@as(?u32, 610), h.backend.terminated);
}

test "moving or closing without force needs click; observe refuses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = policy.parse(arena.allocator(), "{\"apps\": {\"notepad.exe\": \"observe\"}}", "p.json");
    var h: Harness = .{};
    harness(&h, .{ .policy = &p });
    defer h.deinit();
    for ([_][]const u8{ "{\"window\":\"0x1a2b\",\"rect\":[0,0,100,100]}", "{\"window\":\"0x1a2b\",\"state\":\"maximized\"}", "{\"window\":\"0x1a2b\",\"state\":\"closed\"}" }) |args| {
        try expectError(try h.call("window_set", args), "Politique : notepad.exe est en mode observe : action refusée. Demande à Arthur de changer son niveau dans policy.json.");
    }
    try testing.expectEqual(@as(u32, 0), h.backend.set_calls + h.backend.close_calls);
}

test "window_set is an action: refused while paused" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    h.server.control.paused.store(true, .release);
    try expectError(try h.call("window_set", "{\"window\":\"0x1a2b\",\"state\":\"closed\"}"), "En pause par l'utilisateur : attends qu'Arthur réarme");
    try testing.expectEqual(@as(u32, 0), h.backend.close_calls);
}

// ---------------------------------------------------------------- app_launch

const calc_window: display.WindowInfo = .{ .handle = 0xca1c, .title = "Calculatrice", .exe = "ApplicationFrameHost.exe", .pid = 600, .rect = .{ .x = 200, .y = 100, .w = 400, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false };
const notes_window: display.WindowInfo = .{ .handle = 0x7e57, .title = "notes.txt - Bloc-notes", .exe = "notepad.exe", .pid = 7000, .rect = .{ .x = 300, .y = 100, .w = 900, .h = 700 }, .elevated = false, .minimized = false, .cloaked = false };
const with_calc = [_]display.WindowInfo{calc_window} ++ Fake.windows_fixture;
const with_notes = [_]display.WindowInfo{notes_window} ++ Fake.windows_fixture;

test "app_launch takes exactly one of name and path" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    try expectError(try h.call("app_launch", "{}"), "Passe soit name, soit path");
    try expectError(try h.call("app_launch", "{\"name\":\"Calculatrice\",\"path\":\"C:\\\\Users\\\\arthur\\\\notes.txt\"}"), "Passe soit name, soit path");
    try testing.expectEqual(@as(u32, 0), h.backend.launch_calls + h.backend.catalog_calls + h.backend.path_lookups);
}

test "a packaged application launches by AUMID and returns its window (UWP frame) with the full tree" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    h.backend.launch_result = .{ .ok = 610 };
    h.backend.hosted = &.{.{ 0xca1c, 610 }};
    h.backend.processes = &.{.{ 610, "CalculatorApp.exe" }};
    h.backend.after_launch = &with_calc;
    const res = try h.call("app_launch", "{\"name\":\"calculatrise\"}");
    try testing.expect(!isError(res));
    try testing.expectEqualStrings("Microsoft.WindowsCalculator_8wekyb3d8bbwe!App", h.backend.launched.?.aumid);
    try testing.expect(h.backend.launched.?.packaged);
    try testing.expect(std.mem.startsWith(u8, text(res), "0xca1c \"Calculatrice\" CalculatorApp.exe pid=610 ; settled in "));
    // The full tree of the new window, not a delta.
    try expectContains(text(res), "display=0 scale=2 window=0xca1c");
    try testing.expect(std.mem.indexOf(u8, text(res), "delta") == null);
    try testing.expectEqual(@as(?u64, 0xca1c), h.backend.focused);
}

test "an application already open returns its existing window" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    // Notepad (pid 4242) is open; Windows activates it again.
    h.backend.launch_result = .{ .ok = 4242 };
    const res = try h.call("app_launch", "{\"name\":\"Bloc-notes\",\"observe\":\"none\"}");
    try testing.expectEqualStrings("0x1a2b \"Bloc-notes\" notepad.exe pid=4242", text(res));
}

test "without a pid, the first new top-level window is the launched one" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    h.backend.launch_result = .{ .ok = null };
    h.backend.after_launch = &with_notes;
    const res = try h.call("app_launch", "{\"name\":\"Visual Studio Code\",\"observe\":\"none\"}");
    try testing.expect(!h.backend.launched.?.packaged);
    try testing.expectEqualStrings("0x7e57 \"notes.txt - Bloc-notes\" notepad.exe pid=7000", text(res));
}

test "ambiguous and unknown names list the candidates or say so, and enumerate again at most once a minute" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    try expectError(try h.call("app_launch", "{\"name\":\"code\"}"), "Plusieurs applications correspondent à « code » : Visual Studio Code, Visual Studio Code - Insiders ; précise le nom");
    try testing.expectEqual(@as(u32, 1), h.backend.catalog_calls);
    try expectError(try h.call("app_launch", "{\"name\":\"Photoshop\"}"), "Aucune application « Photoshop » dans le menu Démarrer : vérifie le nom ou passe un AUMID");
    // The catalog was enumerated less than a minute ago: no new enumeration.
    try testing.expectEqual(@as(u32, 1), h.backend.catalog_calls);
    // A minute later, a miss enumerates again, once.
    h.server.session.catalog.enumerated_at -= 61 * std.time.ns_per_s;
    _ = try h.call("app_launch", "{\"name\":\"Photoshop\"}");
    try testing.expectEqual(@as(u32, 2), h.backend.catalog_calls);
    _ = try h.call("app_launch", "{\"name\":\"Photoshop\"}");
    try testing.expectEqual(@as(u32, 2), h.backend.catalog_calls);
    try testing.expectEqual(@as(u32, 0), h.backend.launch_calls);
}

test "a document opens with its default application, the audit keeps only its extension" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: audit.Audit = .{ .io = testing.io, .dir = tmp.dir };
    defer if (log.file) |f| f.close(testing.io);
    var h: Harness = .{};
    harness(&h, .{ .audit = &log });
    defer h.deinit();
    h.backend.after_launch = &with_notes;
    const res = try h.call("app_launch", "{\"path\":\"C:\\\\Users\\\\arthur\\\\notes.txt\",\"observe\":\"none\"}");
    try testing.expectEqualStrings("0x7e57 \"notes.txt - Bloc-notes\" notepad.exe pid=7000", text(res));
    try testing.expectEqualStrings("C:\\Users\\arthur\\notes.txt", h.backend.opened());
    _ = try h.call("app_launch", "{\"name\":\"Calculatrice\",\"observe\":\"none\"}");
    var buf: [4096]u8 = undefined;
    const data = try tmp.dir.readFile(testing.io, audit.file_name, &buf);
    try testing.expect(std.mem.indexOf(u8, data, "arthur") == null);
    try testing.expect(std.mem.indexOf(u8, data, "notes") == null);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    try expectContains(lines.next().?, "\"tool\":\"app_launch\",\"app\":\"notepad.exe\",\"pid\":7000,\"policy\":\"full\",");
    try testing.expect(std.mem.endsWith(u8, data[0 .. std.mem.indexOfScalar(u8, data, '\n').? + 1], ",\"launched\":\".txt\"}\n"));
    try expectContains(lines.next().?, ",\"launched\":\"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App\"}");
}

test "executables, scripts, shortcuts, URIs and network paths are refused before any file or shell call" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    const a = h.arena.allocator();
    for (@import("launch.zig").denied_extensions ++ [_][]const u8{ ".exe", ".bat", ".cmd", ".com", ".msc", ".py" }) |ext| {
        const res = try h.call("app_launch", try std.fmt.allocPrint(a, "{{\"path\":\"C:\\\\Users\\\\arthur\\\\x{s}\"}}", .{ext}));
        try expectError(res, try std.fmt.allocPrint(a, "app_launch n'ouvre que des documents et des dossiers : {s} refusé", .{ext}));
    }
    try expectError(try h.call("app_launch", "{\"path\":\"ms-settings:display\"}"), "app_launch n'ouvre que des documents et des dossiers : ms-settings: refusé");
    try expectError(try h.call("app_launch", "{\"path\":\"\\\\\\\\serveur\\\\partage\\\\a.txt\"}"), "app_launch n'ouvre que des documents et des dossiers locaux : chemin réseau refusé");
    try testing.expectEqual(@as(u32, 0), h.backend.path_lookups + h.backend.launch_calls);
    // A mapped network drive is known after the file system lookup only.
    try expectError(try h.call("app_launch", "{\"path\":\"Z:\\\\partage\\\\a.txt\"}"), "app_launch n'ouvre que des documents et des dossiers locaux : chemin réseau refusé");
    try expectError(try h.call("app_launch", "{\"path\":\"C:\\\\absent.txt\"}"), "Introuvable : C:\\absent.txt. Vérifie le chemin d'un fichier ou d'un dossier existant.");
    try testing.expectEqual(@as(u32, 0), h.backend.launch_calls);
}

test "an 8.3 name of a refused file, a type Windows classes as dangerous and a file that runs itself are refused before any launch" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    // The shell opens `DEPLOY~1.APP` as the `.appref-ms` it names.
    try expectError(try h.call("app_launch", "{\"path\":\"C:\\\\Users\\\\arthur\\\\DEPLOY~1.APP\"}"), "app_launch n'ouvre que des documents et des dossiers : .appref-ms refusé");
    try expectError(try h.call("app_launch", "{\"path\":\"C:\\\\Users\\\\arthur\\\\MODULE~1.PSM\"}"), "app_launch n'ouvre que des documents et des dossiers : .psm1 refusé");
    // `.pif` is in no list, but Windows runs it as a program (`"%1" %*`).
    try expectError(try h.call("app_launch", "{\"path\":\"C:\\\\Users\\\\arthur\\\\jeu.pif\"}"), "app_launch n'ouvre que des documents et des dossiers : .pif refusé");
    // `.gadget` is in no list, but AssocIsDangerous classes it as unsafe.
    try expectError(try h.call("app_launch", "{\"path\":\"C:\\\\Users\\\\arthur\\\\meteo.gadget\"}"), "app_launch n'ouvre que des documents et des dossiers : .gadget refusé");
    // A trailing separator hides no extension.
    try expectError(try h.call("app_launch", "{\"path\":\"C:\\\\Users\\\\arthur\\\\x.ps1\\\\\"}"), "app_launch n'ouvre que des documents et des dossiers : .ps1 refusé");
    try testing.expectEqual(@as(u32, 0), h.backend.launch_calls);
}

test "a deny application is never launched; a deny window found after the launch stays hidden" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    // KeePassXC opens .kdbx: deny by default, refused before the launch.
    try expectError(try h.call("app_launch", "{\"path\":\"C:\\\\Users\\\\arthur\\\\coffre.kdbx\"}"), "Politique : KeePassXC.exe est en mode deny");
    try testing.expectEqual(@as(u32, 0), h.backend.launch_calls);
    // A Start menu shortcut the catalog lists without its executable: the
    // backend resolves the target of the chosen entry before the launch.
    h.backend.catalog = &.{.{ .name = "KeePassXC", .aumid = "org.keepassxc.KeePassXC", .packaged = false }};
    h.backend.shortcut_targets = &.{.{ "org.keepassxc.KeePassXC", "KeePassXC.exe" }};
    try expectError(try h.call("app_launch", "{\"name\":\"KeePassXC\"}"), "Politique : KeePassXC.exe est en mode deny");
    try testing.expectEqual(@as(u32, 1), h.backend.exe_lookups);
    try testing.expectEqual(@as(u32, 0), h.backend.launch_calls);
    h.backend.shortcut_targets = &.{};
    // An application whose executable is unknown before the launch.
    const vault = [_]display.WindowInfo{.{ .handle = 0x7a7a, .title = "Coffre - KeePassXC", .exe = "KeePassXC.exe", .pid = 31, .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false }} ++ Fake.windows_fixture;
    h.backend.catalog = &.{.{ .name = "KeePassXC", .aumid = "org.keepassxc.KeePassXC", .packaged = false }};
    h.backend.launch_result = .{ .ok = null };
    h.backend.after_launch = &vault;
    const res = try h.call("app_launch", "{\"name\":\"KeePassXC\"}");
    try expectError(res, "Politique : KeePassXC.exe est en mode deny");
    try testing.expect(std.mem.indexOf(u8, text(res), "Coffre") == null);
    try testing.expectEqual(@as(?u64, null), h.backend.focused);
}

test "a UWP frame whose hosted application is deny stays hidden, even without a launch pid" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = policy.parse(arena.allocator(), "{\"apps\": {\"CalculatorApp.exe\": \"deny\"}}", "p.json");
    var h: Harness = .{};
    harness(&h, .{ .policy = &p });
    defer h.deinit();
    h.backend.launch_result = .{ .ok = null };
    h.backend.hosted = &.{.{ 0xca1c, 610 }};
    h.backend.processes = &.{.{ 610, "CalculatorApp.exe" }};
    h.backend.after_launch = &with_calc;
    const res = try h.call("app_launch", "{\"name\":\"Calculatrice\"}");
    try expectError(res, "Politique : CalculatorApp.exe est en mode deny");
    try testing.expect(std.mem.indexOf(u8, text(res), "0xca1c") == null);
    try testing.expectEqual(@as(?u64, null), h.backend.focused);
}

test "system.app_launch deny, a pause and a second instance refuse app_launch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = policy.parse(arena.allocator(), "{\"system\": {\"app_launch\": \"deny\"}}", "p.json");
    const cases = [_]struct { options: mcp.Options, paused: bool, message: []const u8 }{
        .{ .options = .{ .policy = &p }, .paused = false, .message = "Politique : app_launch est désactivé (system.app_launch dans policy.json)" },
        .{ .options = .{}, .paused = true, .message = "En pause par l'utilisateur : attends qu'Arthur réarme" },
        .{ .options = .{ .exclusive = false }, .paused = false, .message = mcp.instance_message },
    };
    for (cases) |c| {
        var h: Harness = .{};
        harness(&h, c.options);
        defer h.deinit();
        h.server.control.paused.store(c.paused, .release);
        try expectError(try h.call("app_launch", "{\"name\":\"Calculatrice\"}"), c.message);
        try testing.expectEqual(@as(u32, 0), h.backend.launch_calls + h.backend.catalog_calls);
    }
}

test "a launch Windows refuses and a launch without window name the cause" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    h.backend.launch_result = .{ .refused = 0x80270254 };
    try expectError(try h.call("app_launch", "{\"name\":\"Calculatrice\"}"), "Lancement de Calculatrice refusé par Windows (0x80270254) : vérifie que l'application est installée");
    h.backend.launch_result = .{ .ok = 7777 };
    try expectError(try h.call("app_launch", "{\"name\":\"Calculatrice\"}"), "Calculatrice lancée (pid 7777) mais aucune fenêtre après 10 s : rappelle window_list");
    h.backend.launch_result = .{ .ok = null };
    try expectError(try h.call("app_launch", "{\"name\":\"Paint\"}"), "Paint lancée (pid inconnu) mais aucune fenêtre après 10 s : rappelle window_list");
}

test "notifications/cancelled stops the window wait and suppresses the response" {
    var h: Harness = .{};
    harness(&h, .{});
    defer h.deinit();
    h.server.session.launch_wait_ms = 10_000;
    h.backend.launch_result = .{ .ok = 7777 };
    // The cancel flag is set as the reader would on notifications/cancelled.
    h.backend.cancel_on_launch = &h.server.control.cancel;
    h.out.clearRetainingCapacity();
    const started = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    try h.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"app_launch\",\"arguments\":{\"name\":\"Calculatrice\"}}}", &h.out.writer);
    const ms = @divTrunc(std.Io.Clock.awake.now(testing.io).toNanoseconds() - started, std.time.ns_per_ms);
    try testing.expect(ms < 1000);
    try testing.expectEqual(@as(usize, 0), h.out.written().len);
}

test "the new tools are deferred and their schemas carry the PRD parameters" {
    const Reg = @import("registry.zig").Registry(@import("tools.zig").all);
    try testing.expect(!Reg.alwaysLoaded("window_set"));
    try testing.expect(!Reg.alwaysLoaded("app_launch"));
    try testing.expect(Reg.isAction("window_set"));
    try testing.expect(Reg.isAction("app_launch"));
    const tools = @import("tools.zig");
    const set_schema = comptime @import("registry.zig").inputSchema(tools.window_set.Args);
    try expectContains(set_schema, "\"rect\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"},\"minItems\":4,\"maxItems\":4}");
    try expectContains(set_schema, "\"state\":{\"type\":\"string\",\"enum\":[\"normal\",\"minimized\",\"maximized\",\"closed\"]}");
    try expectContains(set_schema, "\"required\":[\"window\"]");
    const launch_schema = comptime @import("registry.zig").inputSchema(tools.app_launch.Args);
    try expectContains(launch_schema, "\"name\":{\"type\":\"string\"}");
    try expectContains(launch_schema, "\"path\":{\"type\":\"string\"}");
    try testing.expect(std.mem.indexOf(u8, launch_schema, "required") == null);
}
