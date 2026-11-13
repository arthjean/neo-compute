//! EP-015 through the real dispatcher against the fake backend (US-061):
//! `screenshot` and `zoom` of one window, the background mode's image of
//! its target, the refusals of a capture, and `ui_tree` marks on a window's
//! image.

const std = @import("std");
const testing = std.testing;
const mcp = @import("mcp.zig");
const a11y = @import("a11y.zig");
const audit = @import("audit.zig");
const display = @import("display.zig");
const t = @import("tools_test.zig");
const Fake = @import("../backend/fake.zig").Fake;
const Harness = t.Harness;
const isError = t.isError;
const text = t.text;
const block = t.block;
const expectContains = t.expectContains;

/// The fixture window: physical (100, 80) 1200x800 on display 0, whose
/// screenshot has scale 2.
const window_text = "window=0x1a2b size=600x400 scale=2 origin=50,40 display=0";

fn background(h: *Harness) void {
    h.initWith(testing.allocator, .{ .mode = .background });
}

fn expectError(res: std.json.ObjectMap, message: []const u8) !void {
    try testing.expect(isError(res));
    try testing.expectEqualStrings(message, text(res));
}

/// Pixel of the last reduced image of the fixture window (600x400) at
/// physical desktop point (x, y).
fn windowPixel(h: *Harness, x: i32, y: i32) [4]u8 {
    const i = (@as(usize, @intCast(@divTrunc(y - 80, 2))) * 600 + @as(usize, @intCast(@divTrunc(x - 100, 2)))) * 4;
    return h.server.session.reducer.out[i..][0..4].*;
}

fn isBlack(px: [4]u8) bool {
    return px[0] == 0 and px[1] == 0 and px[2] == 0;
}

fn imageSize(h: *Harness, res: std.json.ObjectMap) ![2]u16 {
    const img = block(res, 0);
    try testing.expectEqualStrings("image", img.get("type").?.string);
    return t.jpegSize(h.arena.allocator(), img.get("data").?.string);
}

test "screenshot window shows that window alone and says how its pixels relate to ui_tree" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const res = try h.call("screenshot", "{\"window\":\"0x1a2b\"}");
    try testing.expect(!isError(res));
    // The window's 1200x800 at the scale of its display's screenshot.
    try testing.expectEqual([2]u16{ 600, 400 }, try imageSize(&h, res));
    try testing.expectEqualStrings(window_text, text(res));
    // The window was captured, never the screen.
    try testing.expectEqual(@as(u32, 1), h.backend.window_captures);
    try testing.expectEqual(@as(?u64, 0x1a2b), h.backend.captured_window);
    try testing.expectEqual(@as(u32, 0), h.backend.capture_calls);
    // The space of incoming coordinates stays the display's: a click after
    // a window's image still reads its coordinates on a screenshot.
    try testing.expectEqual(@as(?usize, null), h.server.session.current);

    // An image pixel plus the origin is the coordinate ui_tree prints: the
    // "Enregistrer" button, physical (1100, 840), is @550,420 in the tree
    // and at 500,380 in the image.
    const tree = text(try h.call("ui_tree", "{\"window\":\"0x1a2b\"}"));
    try expectContains(tree, "button \"Enregistrer\" @550,420,50,15");
}

test "the window's password fields are blacked out by a scan of that window (FR-09)" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    try testing.expect(!isError(try h.call("screenshot", "{\"window\":\"0x1a2b\"}")));
    // The scan was asked for the window, not for the foreground window.
    try testing.expectEqual(@as(u32, 1), h.backend.secret_scans);
    try testing.expectEqual(@as(?u64, 0x1a2b), h.backend.secret_window);
    // The fixture's password field: physical (100, 840) 400x30.
    try testing.expect(isBlack(windowPixel(&h, 300, 855)));
    try testing.expect(isBlack(windowPixel(&h, 100, 840)));
    try testing.expect(isBlack(windowPixel(&h, 498, 868)));
    try testing.expect(!isBlack(windowPixel(&h, 300, 830)));
    try testing.expect(!isBlack(windowPixel(&h, 520, 855)));
    // zoom on the field, in the window image's pixels: all black.
    const z = try h.call("zoom", "{\"window\":\"0x1a2b\",\"region\":[10,382,190,392]}");
    try testing.expect(!isError(z));
    try testing.expectEqualStrings("window=0x1a2b region=10,382,190,392 size=360x20", text(z));
    const px = h.server.session.reducer.out[0 .. 360 * 20 * 4];
    for (0..px.len / 4) |i| try testing.expect(isBlack(px[i * 4 ..][0..4].*));
}

test "a web tree that is not built refuses the capture instead of showing unmasked fields" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    h.backend.secret_whole_window = true;
    const res = try h.call("screenshot", "{\"window\":\"0x1a2b\"}");
    try expectError(res, "Capture indisponible : l'arbre web de notepad.exe n'est pas construit, ses champs mot de passe ne peuvent pas être masqués. Si la fenêtre est recouverte, laisse une bande d'au moins 16 px visible avec window_set, puis réessaie ; sinon réessaie dans un instant.");
    try testing.expectEqual(@as(usize, 1), res.get("content").?.array.items.len);
}

test "a scan that cannot vouch for every password field refuses the window's image" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    // The scan failed, or held more fields than it could report.
    h.backend.secret_scan = .failed;
    const failed = "Capture indisponible : les champs mot de passe de notepad.exe n'ont pas pu être lus, l'image ne peut pas être masquée. Réessaie, ou utilise ui_tree.";
    const shot = try h.call("screenshot", "{\"window\":\"0x1a2b\"}");
    try expectError(shot, failed);
    try testing.expectEqual(@as(usize, 1), shot.get("content").?.array.items.len);
    try expectError(try h.call("zoom", "{\"window\":\"0x1a2b\",\"region\":[0,0,10,10]}"), failed);
    // A screenshot of the screen keeps its own rule (decision 0007).
    try testing.expect(!isError(try h.call("screenshot", "{}")));
    h.backend.secret_scan = .ok;
    try testing.expect(!isError(try h.call("screenshot", "{\"window\":\"0x1a2b\"}")));

    // A window of a process of higher integrity: its tree is closed.
    var raised = Fake.windows_fixture;
    raised[0].elevated = true;
    h.backend.windows = &raised;
    try expectError(try h.call("screenshot", "{\"window\":\"0x1a2b\"}"), "Capture indisponible : notepad.exe s'exécute avec des droits élevés, ses champs mot de passe ne peuvent pas être lus pour être masqués. Relance l'application sans élévation, ou agis toi-même.");
}

test "background mode: observe screenshot is the target window's image, never the screen" {
    var h: Harness = .{};
    background(&h);
    defer h.deinit();
    _ = try h.call("ui_tree", "{\"window\":\"0x1a2b\"}");
    const res = try h.call("ui_act", "{\"id\":\"e7\",\"action\":\"invoke\",\"observe\":\"screenshot\"}");
    try testing.expect(!isError(res));
    try testing.expectEqual([2]u16{ 600, 400 }, try imageSize(&h, res));
    // The action's line and its settling, then the image's own line.
    try expectContains(text(res), " ; settle");
    try testing.expect(std.mem.endsWith(u8, text(res), "\n" ++ window_text));
    try testing.expectEqual(@as(usize, 1), h.backend.window_captures);
    try testing.expectEqual(@as(?u64, 0x1a2b), h.backend.captured_window);
    try testing.expectEqual(@as(u32, 0), h.backend.capture_calls);
    try testing.expectEqual(@as(u32, 0), h.backend.foreground_reads);

    // An image that cannot be shown does not undo the action: its line
    // stays, with the reason.
    h.backend.window_capture = .black;
    const dark = try h.call("ui_act", "{\"id\":\"e7\",\"action\":\"invoke\",\"observe\":\"screenshot\"}");
    try testing.expect(!isError(dark));
    try testing.expectEqual(@as(usize, 1), dark.get("content").?.array.items.len);
    try expectContains(text(dark), "\nObservation indisponible : Capture noire : notepad.exe");
}

test "ui_tree marks keeps its tree when the window's image cannot be masked" {
    var h: Harness = .{};
    background(&h);
    defer h.deinit();
    h.backend.secret_scan = .failed;
    const res = try h.call("ui_tree", "{\"window\":\"0x1a2b\",\"marks\":true}");
    try testing.expect(!isError(res));
    try testing.expectEqual(@as(usize, 1), res.get("content").?.array.items.len);
    try expectContains(text(res), "e7 button \"Enregistrer\"");
    try expectContains(text(res), "\nImage indisponible : Capture indisponible : les champs mot de passe de notepad.exe n'ont pas pu être lus");
}

test "without window, screenshot and zoom of a11y and vision never capture a window" {
    for ([_]mcp.Mode{ .a11y, .vision }) |mode| {
        var h: Harness = .{};
        h.initWith(testing.allocator, .{ .mode = mode });
        defer h.deinit();
        const shot = try h.call("screenshot", "{}");
        try testing.expectEqualStrings("display=0 scale=2 size=1280x720", text(shot));
        const z = try h.call("zoom", "{\"region\":[100,100,200,150]}");
        try testing.expectEqualStrings("display=0 region=100,100,200,150 size=200x100", text(z));
        try testing.expectEqual(@as(u32, 0), h.backend.window_captures);
        try testing.expectEqual(@as(u32, 2), h.backend.capture_calls);
    }
}

test "window and display do not combine; a bad handle names the format" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    try expectError(try h.call("screenshot", "{\"window\":\"0x1a2b\",\"display\":0}"), "window et display ne se combinent pas : window montre une fenêtre, display un écran.");
    try expectError(try h.call("screenshot", "{\"window\":\"fenêtre\"}"), "Handle `fenêtre` invalide : utilise un handle de window_list (ex. 0x1a2b).");
    try expectError(try h.call("zoom", "{\"window\":\"0\",\"region\":[0,0,10,10]}"), "Handle `0` invalide : utilise un handle de window_list (ex. 0x1a2b).");
    try testing.expectEqual(@as(u32, 0), h.backend.window_captures);
}

test "background mode: screenshot and zoom show the target window, never a screen" {
    var h: Harness = .{};
    background(&h);
    defer h.deinit();
    // No target yet: nothing to show, and no screen in its place.
    try expectError(try h.call("screenshot", "{}"), a11y.target_missing);
    try expectError(try h.call("zoom", "{\"region\":[0,0,10,10]}"), a11y.target_missing);

    _ = try h.call("ui_tree", "{\"window\":\"0x1a2b\"}");
    const shot = try h.call("screenshot", "{}");
    try testing.expect(!isError(shot));
    try testing.expectEqual([2]u16{ 600, 400 }, try imageSize(&h, shot));
    try testing.expectEqualStrings(window_text, text(shot));
    // 100x100 image pixels are 200x200 of the window.
    const z = try h.call("zoom", "{\"region\":[0,0,100,100]}");
    try testing.expect(!isError(z));
    try testing.expectEqual([2]u16{ 200, 200 }, try imageSize(&h, z));
    try testing.expectEqualStrings("window=0x1a2b region=0,0,100,100 size=200x200", text(z));
    // A region is read in the window's image: its bounds are the image's.
    try expectError(try h.call("zoom", "{\"region\":[0,0,601,100]}"), "Région [0, 0, 601, 100] invalide (inversée, vide ou hors de l'image de la fenêtre) : bornes valides 0..600 x 0..400 avec x0 < x1 et y0 < y1.");

    // A window named on the call becomes the target.
    const other = [_]display.WindowInfo{
        Fake.windows_fixture[0],
        .{ .handle = 0x2222, .title = "Calculatrice", .exe = "CalculatorApp.exe", .pid = 61, .rect = .{ .x = 1400, .y = 100, .w = 400, .h = 600 }, .elevated = false, .minimized = false, .cloaked = false },
    };
    h.backend.windows = &other;
    const named = try h.call("screenshot", "{\"window\":\"0x2222\"}");
    try testing.expectEqualStrings("window=0x2222 size=200x300 scale=2 origin=700,50 display=0", text(named));
    try testing.expectEqual(@as(?u64, 0x2222), h.server.session.target);
    try expectContains(text(try h.call("screenshot", "{}")), "window=0x2222 ");

    // Nothing read the screen or the foreground window.
    try testing.expectEqual(@as(u32, 0), h.backend.capture_calls);
    try testing.expectEqual(@as(u32, 0), h.backend.foreground_reads);
}

test "background mode refuses a display: a screen is the user's" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: audit.Audit = .{ .io = testing.io, .dir = tmp.dir };
    defer if (log.file) |f| f.close(testing.io);
    var h: Harness = .{};
    h.initWith(testing.allocator, .{ .mode = .background, .audit = &log });
    defer h.deinit();
    _ = try h.call("ui_tree", "{\"window\":\"0x1a2b\"}");
    for ([_][]const u8{ "{\"display\":0}", "{\"display\":1,\"window\":\"0x1a2b\"}" }) |args|
        try expectError(try h.call("screenshot", args), "Mode arrière-plan : screenshot display montrerait l'écran de l'utilisateur, pas ta fenêtre cible. Aucune action exécutée. Utilise screenshot sans display, ou avec window.");
    try testing.expectEqual(@as(u32, 0), h.backend.capture_calls);
    try testing.expectEqual(@as(u32, 0), h.backend.window_captures);
    var buf: [4096]u8 = undefined;
    const data = try tmp.dir.readFile(testing.io, audit.file_name, &buf);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    _ = lines.next();
    const refused = lines.next().?;
    try expectContains(refused, "\"tool\":\"screenshot\"");
    try expectContains(refused, "\"result\":\"denied\"");
}

test "a deny application is refused by the policy message, and nothing is captured" {
    const desk = [_]display.WindowInfo{
        Fake.windows_fixture[0],
        .{ .handle = 0x7a7a, .title = "Coffre - KeePassXC", .exe = "KeePassXC.exe", .pid = 31, .rect = .{ .x = 1000, .y = 500, .w = 800, .h = 400 }, .elevated = false, .minimized = false, .cloaked = false },
    };
    for ([_]mcp.Mode{ .a11y, .background }) |mode| {
        var h: Harness = .{};
        h.initWith(testing.allocator, .{ .mode = mode });
        defer h.deinit();
        h.backend.windows = &desk;
        const message = "Politique : KeePassXC.exe est en mode deny : action refusée. Demande à Arthur de changer son niveau dans policy.json.";
        try expectError(try h.call("screenshot", "{\"window\":\"0x7a7a\"}"), message);
        try expectError(try h.call("zoom", "{\"window\":\"0x7a7a\",\"region\":[0,0,10,10]}"), message);
        try testing.expectEqual(@as(u32, 0), h.backend.window_captures);
        try testing.expectEqual(@as(u32, 0), h.backend.secret_scans);
    }
}

test "a minimized, closed, hung, scaled or black window says so, with no image" {
    var h: Harness = .{};
    background(&h);
    defer h.deinit();
    _ = try h.call("ui_tree", "{\"window\":\"0x1a2b\"}");

    // A window that does not answer in 200 ms: no capture is attempted.
    h.backend.hung = true;
    try expectError(try h.call("screenshot", "{}"), "La fenêtre 0x1a2b ne répond pas : réessaie, ou ferme-la avec state: closed et force: true.");
    try testing.expectEqual(@as(u32, 0), h.backend.window_captures);
    h.backend.hung = false;

    h.backend.window_capture = .black;
    const black = try h.call("screenshot", "{}");
    try expectError(black, "Capture noire : notepad.exe ne se laisse pas capturer hors de l'écran. Utilise ui_tree.");
    try testing.expectEqual(@as(usize, 1), black.get("content").?.array.items.len);
    try expectError(try h.call("zoom", "{\"region\":[0,0,10,10]}"), "Capture noire : notepad.exe ne se laisse pas capturer hors de l'écran. Utilise ui_tree.");

    h.backend.window_capture = .scaled;
    try expectError(try h.call("screenshot", "{}"), "Capture indisponible : Windows met notepad.exe à l'échelle (application qui ne suit pas le DPI de son écran), son image ne correspondrait à aucun rectangle. Utilise ui_tree.");
    h.backend.window_capture = .failed;
    try expectError(try h.call("screenshot", "{}"), "Capture de la fenêtre 0x1a2b impossible : réessaie, ou utilise ui_tree.");
    h.backend.window_capture = .frame;

    var hidden = Fake.windows_fixture;
    hidden[0].minimized = true;
    h.backend.windows = &hidden;
    try expectError(try h.call("screenshot", "{\"window\":\"0x1a2b\"}"), "Fenêtre minimisée : restaure-la avec window_set (state normal) avant la capture.");
    h.backend.windows = &Fake.windows_fixture;

    // Closed since it was named: the target is gone.
    h.backend.markGone(0x1a2b);
    try expectError(try h.call("screenshot", "{}"), a11y.target_closed);
    try expectError(try h.call("screenshot", "{\"window\":\"0x1a2b\"}"), "Fenêtre fermée : rappelle window_list");
}

test "zoom on a window resized since its screenshot asks for a new one" {
    var h: Harness = .{};
    background(&h);
    defer h.deinit();
    _ = try h.call("screenshot", "{\"window\":\"0x1a2b\"}");
    var resized = Fake.windows_fixture;
    resized[0].rect = .{ .x = 100, .y = 80, .w = 1000, .h = 800 };
    h.backend.windows = &resized;
    try expectError(try h.call("zoom", "{\"region\":[0,0,100,100]}"), "Fenêtre 0x1a2b redimensionnée depuis son screenshot (1000x800 au lieu de 1200x800) : refais un screenshot.");
    // A window that only moved keeps its image's pixels.
    _ = try h.call("screenshot", "{}");
    var moved = resized;
    moved[0].rect = .{ .x = 300, .y = 200, .w = 1000, .h = 800 };
    h.backend.windows = &moved;
    try testing.expect(!isError(try h.call("zoom", "{\"region\":[0,0,100,100]}")));
}

test "ui_tree marks in background mode draws the ids on the target window's image" {
    var h: Harness = .{};
    background(&h);
    defer h.deinit();
    const res = try h.call("ui_tree", "{\"window\":\"0x1a2b\",\"marks\":true}");
    try testing.expect(!isError(res));
    try testing.expectEqual(@as(usize, 2), res.get("content").?.array.items.len);
    const img = res.get("content").?.array.items[1].object;
    try testing.expectEqual([2]u16{ 600, 400 }, try t.jpegSize(h.arena.allocator(), img.get("data").?.string));
    const tree = text(res);
    try expectContains(tree, "e7 button \"Enregistrer\"");
    try testing.expect(std.mem.endsWith(u8, tree, "\nImage : " ++ window_text));
    // The "Enregistrer" button, physical (1100, 840), carries its label at
    // its own place in the window's image.
    try testing.expectEqual([4]u8{ 0, 255, 255, 255 }, windowPixel(&h, 1100, 840));
    // The password field is black under the labels.
    try testing.expect(isBlack(windowPixel(&h, 300, 855)));
    // The window, never the screen or the foreground.
    try testing.expectEqual(@as(u32, 1), h.backend.window_captures);
    try testing.expectEqual(@as(u32, 0), h.backend.capture_calls);
    try testing.expectEqual(@as(u32, 0), h.backend.foreground_reads);

    // A window that cannot be captured keeps its tree and says why.
    h.backend.window_capture = .black;
    const no_image = try h.call("ui_tree", "{\"marks\":true}");
    try testing.expect(!isError(no_image));
    try testing.expect(std.mem.endsWith(u8, text(no_image), "\nImage indisponible : Capture noire : notepad.exe ne se laisse pas capturer hors de l'écran. Utilise ui_tree."));
}

test "ui_tree marks of the a11y mode still draws on the display's screenshot" {
    var h: Harness = .{};
    h.init(testing.allocator);
    defer h.deinit();
    const res = try h.call("ui_tree", "{\"marks\":true}");
    try testing.expect(!isError(res));
    const img = res.get("content").?.array.items[1].object;
    try testing.expectEqual([2]u16{ 1280, 720 }, try t.jpegSize(h.arena.allocator(), img.get("data").?.string));
    try testing.expect(std.mem.indexOf(u8, text(res), "Image : ") == null);
    try testing.expectEqual(@as(u32, 0), h.backend.window_captures);
    try testing.expectEqual(@as(u32, 1), h.backend.capture_calls);
}

test "the image of a covered Chromium window says it may show an old frame" {
    var h: Harness = .{};
    background(&h);
    defer h.deinit();
    const desk = [_]display.WindowInfo{
        .{ .handle = 0xc0, .title = "Explorateur", .exe = "explorer.exe", .pid = 50, .rect = .{ .x = 0, .y = 0, .w = 2000, .h = 1000 }, .elevated = false, .minimized = false, .cloaked = false },
        .{ .handle = 0x1a2b, .title = "Page", .exe = "chrome.exe", .pid = 4242, .rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 }, .elevated = false, .minimized = false, .cloaked = false },
    };
    h.backend.windows = &desk;
    h.backend.chromium_windows = &.{0x1a2b};
    const shot = try h.call("screenshot", "{\"window\":\"0x1a2b\"}");
    try testing.expect(!isError(shot));
    try testing.expectEqualStrings(window_text ++ "\n" ++ a11y.frozen_image, text(shot));
    try testing.expect(std.mem.startsWith(u8, a11y.frozen_image, "Fenêtre recouverte : Chromium suspend son rendu, l'image peut être figée. Déplace-la avec window_set pour "));
    const z = try h.call("zoom", "{\"region\":[0,0,100,100]}");
    try testing.expect(std.mem.endsWith(u8, text(z), "\n" ++ a11y.frozen_image));
    // A window of another application under the same cover: its image is
    // current.
    h.backend.chromium_windows = &.{};
    try testing.expectEqualStrings(window_text, text(try h.call("screenshot", "{}")));
}
