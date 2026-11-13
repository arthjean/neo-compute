//! Targeted perception (EP-014) in `neo-compute selftest --background`: the
//! `bg-*` controls below run `ui_tree` and `ui_find` through the dispatcher
//! of the background server on the covered test window. Each requires what
//! the result says, read against the target by Win32 where Win32 can tell,
//! and an unchanged session (foreground, keyboard focus, cursor, clipboard,
//! no injected event).

const std = @import("std");
const w = @import("win32");
const display = @import("../../core/display.zig");
const uitree = @import("../../core/uitree.zig");
const test_window = @import("test_window.zig");
const window = @import("window.zig");
const selftest = @import("selftest.zig");
const bg = @import("selftest_background.zig");
const Bench = bg.Bench;
const Windows = @import("../windows.zig").Windows;

const qpcUs = selftest.qpcUs;

/// Calls timed by each control.
const reps = 40;
/// PRD Quality Gates: `ui_tree` of a native window, p95. US-056 holds
/// `root` to it.
const tree_budget_us = 50_000;
/// US-057: `ui_find id:<id>`, p95.
const reread_budget_us = 10_000;
/// US-059: what the occlusion calculation adds to `ui_tree`, p95, with
/// `cost_windows` top-level windows above the target.
const occlusion_budget_us = 1_000;
const cost_windows = 50;
/// The strip US-058 found enough for Chrome.
const strip_px = 16;

fn p95(sorted: []const u64) u64 {
    return sorted[(sorted.len * 95 + 99) / 100 - 1];
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

fn processCycles() u64 {
    var c: u64 = 0;
    _ = w.QueryProcessCycleTime(w.GetCurrentProcess(), &c);
    return c;
}

/// The line of element `id` in a tree, without its indentation.
fn lineOf(tree: []const u8, id: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, tree, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trimStart(u8, line, " ");
        if (l.len > id.len and std.mem.startsWith(u8, l, id) and l[id.len] == ' ') return l;
    }
    return null;
}

/// Whether the top-level window Win32 hit-tests at (x, y) is `target`.
fn hits(target: w.HWND, x: i32, y: i32) bool {
    const at = w.WindowFromPoint(.{ .x = x, .y = y });
    return at != null and (at == target or w.GetAncestor(at, w.GA_ROOT) == target);
}

/// Runs the EP-014 controls. True when the decoy lost the foreground to
/// something else than the server: the run cannot judge any further.
pub fn run(b: *Bench, backend: *Windows, arena: std.mem.Allocator) !bool {
    controls(b, backend, arena) catch |err| switch (err) {
        error.DecoyLost => return true,
        else => return err,
    };
    return false;
}

fn controls(b: *Bench, backend: *Windows, arena: std.mem.Allocator) !void {
    const tree = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{b.hwnd});
    if (tree.is_error) return b.report.fail("bg-tree-root", "the target's tree cannot be read: {s}", .{tree.text});
    const full = try arena.dupe(u8, tree.text);
    try subtree(b, full);
    try reread(b, full);
    try occluded(b);
    try occlusionCost(b, backend, arena);
}

/// US-056: the subtree of the list holds its items with the ids of the whole
/// tree; the window's own element as `root` costs what the whole tree does;
/// `depth` folds the list into its line.
fn subtree(b: *Bench, full: []const u8) !void {
    const name = "bg-tree-root";
    var lines = std.mem.splitScalar(u8, full, '\n');
    _ = lines.next();
    const top = Bench.idIn(lines.next() orelse "", " ") orelse return b.report.fail(name, "no element line after the header: {s}", .{firstLine(full)});
    // The list box is the one element of the tree that shows a scroll
    // position.
    const list = Bench.idIn(full, "scroll=") orelse return b.report.fail(name, "no list in the target's tree", .{});

    const before = b.begin() orelse return error.DecoyLost;
    const sub = try b.caller.call("ui_tree", "{{\"root\":\"{s}\"}}", .{list});
    const folded = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\",\"depth\":1}}", .{b.hwnd});
    const gone = try b.caller.call("ui_tree", "{{\"root\":\"ezzzz\"}}", .{});
    const both = try b.caller.call("ui_tree", "{{\"root\":\"{s}\",\"since\":\"last\"}}", .{list});
    const secret = try b.caller.call("ui_tree", "{{\"root\":\"{s}\"}}", .{top});
    var whole: [reps]u64 = undefined;
    var rooted: [reps]u64 = undefined;
    var failed: u32 = 0;
    for (&whole, &rooted) |*a, *r| {
        var t0 = qpcUs();
        const one = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{b.hwnd});
        a.* = qpcUs() - t0;
        t0 = qpcUs();
        const two = try b.caller.call("ui_tree", "{{\"root\":\"{s}\"}}", .{top});
        r.* = qpcUs() - t0;
        if (one.is_error or two.is_error) failed += 1;
    }
    const v = b.end(before);
    std.mem.sort(u64, &whole, {}, std.sort.asc(u64));
    std.mem.sort(u64, &rooted, {}, std.sort.asc(u64));

    // Every line of the subtree is a line of the whole tree: same id, same
    // text. The items scrolled out of view are in neither.
    var items: usize = 0;
    var strangers: usize = 0;
    var sub_lines = std.mem.splitScalar(u8, sub.text, '\n');
    _ = sub_lines.next();
    while (sub_lines.next()) |line| {
        const l = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, l, "…")) continue;
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const id = it.next() orelse continue;
        const same = if (lineOf(full, id)) |known| std.mem.eql(u8, known, l) else false;
        if (!same) strangers += 1;
        if (std.mem.indexOf(u8, l, test_window.list_prefix) != null) items += 1;
    }
    const list_first = std.mem.startsWith(u8, std.mem.trimStart(u8, sub.text[@min(sub.text.len, firstLine(sub.text).len + 1)..], " "), list);
    const fold_line = lineOf(folded.text, list) orelse "";
    var buf: [96]u8 = undefined;
    if (sub.is_error or !list_first or items == 0 or strangers != 0) {
        b.report.fail(name, "root {s}: error={}, list first: {}, {d} items, {d} lines unknown to the whole tree:\n{s}", .{ list, sub.is_error, list_first, items, strangers, sub.text });
    } else if (std.mem.indexOf(u8, sub.text, test_window.button_label) != null) {
        b.report.fail(name, "the subtree of the list holds the window's button:\n{s}", .{sub.text});
    } else if (folded.is_error or std.mem.indexOf(u8, fold_line, " descendants") == null or std.mem.indexOf(u8, folded.text, test_window.list_prefix) != null) {
        b.report.fail(name, "depth 1 does not fold the list into its line: `{s}`", .{fold_line});
    } else if (!gone.is_error or !std.mem.eql(u8, gone.text, "Élément ezzzz introuvable : rappelle ui_tree")) {
        b.report.fail(name, "an unknown root answered `{s}`", .{gone.text});
    } else if (!both.is_error or !std.mem.startsWith(u8, both.text, "root et since ne se combinent pas")) {
        b.report.fail(name, "root with since answered `{s}`", .{both.text});
    } else if (secret.is_error or std.mem.indexOf(u8, secret.text, test_window.secret) != null or std.mem.indexOf(u8, secret.text, "[=" ++ uitree.password_mask ++ "]") == null) {
        b.report.fail(name, "the window's subtree does not show its password field masked", .{});
    } else if (failed != 0) {
        b.report.fail(name, "{d} of {d} timed reads failed", .{ failed, reps });
    } else if (p95(&rooted) >= tree_budget_us or p95(&rooted) * 100 > p95(&whole) * 110 + 50_000) {
        b.report.fail(name, "root on the window's element: p95 {d} us (median {d} us), the whole tree {d} us (median {d} us); budget {d} us and 110 % of the whole tree plus 500 us", .{ p95(&rooted), rooted[reps / 2], p95(&whole), whole[reps / 2], tree_budget_us });
    } else if (v.any()) {
        b.report.fail(name, "the session changed: {s}", .{v.text(&buf)});
    } else b.report.ok(name, "root {s}: the list and its {d} items in view, each line the whole tree's; `{s}` at depth 1; an unknown root and root with since refused; root on the window's element p95 {d} us (median {d} us) against {d} us (median {d} us) for the whole tree, budget {d} us; session unchanged", .{
        list, items, fold_line, p95(&rooted), rooted[reps / 2], p95(&whole), whole[reps / 2], tree_budget_us,
    });
}

/// US-057: `ui_find id:<id>` gives the box's line as it is now, against the
/// state Win32 gives, in one read of that element.
fn reread(b: *Bench, full: []const u8) !void {
    const name = "bg-reread";
    const tw = b.tw;
    const box = Bench.idIn(full, test_window.checkbox_label) orelse return b.report.fail(name, "no element `{s}` in the target's tree", .{test_window.checkbox_label});
    const field = Bench.idIn(full, "[=" ++ uitree.password_mask ++ "]") orelse return b.report.fail(name, "no password field in the target's tree", .{});
    const per_us = selftest.cyclesPerUs();

    const before = b.begin() orelse return error.DecoyLost;
    var walls: [reps]u64 = undefined;
    var cpus: [reps]u64 = undefined;
    var wrong: u32 = 0;
    var last: []const u8 = "";
    for (&walls, &cpus) |*wall, *cpu| {
        const acted = try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"toggle\",\"observe\":\"none\"}}", .{box});
        if (acted.is_error) wrong += 1;
        const state = tw.checked();
        const c0 = processCycles();
        const t0 = qpcUs();
        const res = try b.caller.call("ui_find", "{{\"query\":\"id:{s}\"}}", .{box});
        wall.* = qpcUs() - t0;
        cpu.* = @intFromFloat(@as(f64, @floatFromInt(processCycles() -| c0)) / per_us);
        const line = lineOf(res.text, box) orelse "";
        last = line;
        const says = std.mem.indexOf(u8, line, "{checked") != null or std.mem.indexOf(u8, line, ",checked") != null;
        if (res.is_error or line.len == 0 or says != state or std.mem.count(u8, res.text, "\n") != 1) wrong += 1;
    }
    const masked = try b.caller.call("ui_find", "{{\"query\":\"id:{s}\"}}", .{field});
    const by_value = try b.caller.call("ui_find", "{{\"query\":\"value:{s}\"}}", .{test_window.secret});
    const gone = try b.caller.call("ui_find", "{{\"query\":\"id:ezzzz\"}}", .{});
    const v = b.end(before);
    std.mem.sort(u64, &walls, {}, std.sort.asc(u64));
    std.mem.sort(u64, &cpus, {}, std.sort.asc(u64));
    var buf: [96]u8 = undefined;
    if (wrong != 0) {
        b.report.fail(name, "{d} of {d} reads failed or disagreed with the box Win32 reads; last line `{s}`", .{ wrong, reps, last });
    } else if (masked.is_error or std.mem.indexOf(u8, masked.text, test_window.secret) != null or std.mem.indexOf(u8, masked.text, "[=" ++ uitree.password_mask ++ "]") == null) {
        b.report.fail(name, "the password field read again is not masked: error={}", .{masked.is_error});
    } else if (std.mem.indexOf(u8, by_value.text, "Aucun élément ne correspond") == null) {
        b.report.fail(name, "value: with the password's text matched something", .{});
    } else if (!gone.is_error or !std.mem.eql(u8, gone.text, "Élément ezzzz introuvable : rappelle ui_tree")) {
        b.report.fail(name, "an unknown id answered `{s}`", .{gone.text});
    } else if (p95(&walls) >= reread_budget_us or p95(&cpus) >= reread_budget_us) {
        b.report.fail(name, "p95 {d} us (median {d} us), process CPU per call p95 {d} us; budget {d} us each", .{ p95(&walls), walls[reps / 2], p95(&cpus), reread_budget_us });
    } else if (v.any()) {
        b.report.fail(name, "the session changed: {s}", .{v.text(&buf)});
    } else b.report.ok(name, "{d} reads of the box after a toggle, each its line alone with the state Win32 gives (`{s}`); p95 {d} us (median {d} us, budget {d} us), process CPU per call p95 {d} us, provider included; the password field stays masked and value: never matches it; an unknown id refused; session unchanged", .{
        reps, last, p95(&walls), walls[reps / 2], reread_budget_us, p95(&cpus),
    });
}

/// The frame of the target moved so that `strip_px` of it show beside the
/// decoy, on the first side where Win32 hit-tests the target in that strip.
fn showStrip(b: *Bench, home: w.RECT, frame: display.Rect, cover: display.Rect) ?[2]i32 {
    const t = b.tw.window();
    const moves = [_]struct { dx: i32, dy: i32, px: i32, py: i32 }{
        .{ .dx = cover.right() + strip_px - frame.right(), .dy = 0, .px = cover.right() + strip_px / 2, .py = frame.y + @divTrunc(frame.h, 2) },
        .{ .dx = cover.x - strip_px - frame.x, .dy = 0, .px = cover.x - strip_px / 2, .py = frame.y + @divTrunc(frame.h, 2) },
        .{ .dx = 0, .dy = cover.bottom() + strip_px - frame.bottom(), .px = frame.x + @divTrunc(frame.w, 2), .py = cover.bottom() + strip_px / 2 },
        .{ .dx = 0, .dy = cover.y - strip_px - frame.y, .px = frame.x + @divTrunc(frame.w, 2), .py = cover.y - strip_px / 2 },
    };
    for (moves) |m| {
        _ = w.SetWindowPos(t, b.decoy.hwnd, home.left + m.dx, home.top + m.dy, 0, 0, w.SWP_NOSIZE | w.SWP_NOACTIVATE);
        w.Sleep(80);
        if (hits(t, m.px, m.py)) return .{ m.px, m.py };
    }
    return null;
}

/// US-059: under the decoy the target's header and its window_list line say
/// `occluded`; with a strip in view, which Win32 hit-tests, they do not.
fn occluded(b: *Bench) !void {
    const name = "bg-occluded";
    const t = b.tw.window();
    const frame = window.rect(t) orelse return b.report.fail(name, "the target has no frame", .{});
    const cover = window.rect(b.decoy.hwnd) orelse return b.report.fail(name, "the decoy has no frame", .{});
    var home: w.RECT = undefined;
    _ = w.GetWindowRect(t, &home);
    var hbuf: [40]u8 = undefined;
    const handle = std.fmt.bufPrint(&hbuf, "\n0x{x} ", .{b.hwnd}) catch "";

    const before = b.begin() orelse return error.DecoyLost;
    // Nothing of the target answers a hit test: corners and center.
    var shown: u32 = 0;
    for ([_][2]i32{ .{ frame.x + 2, frame.y + 2 }, .{ frame.right() - 3, frame.y + 2 }, .{ frame.x + 2, frame.bottom() - 3 }, .{ frame.right() - 3, frame.bottom() - 3 }, .{ frame.x + @divTrunc(frame.w, 2), frame.y + @divTrunc(frame.h, 2) } }) |pt| shown += @intFromBool(hits(t, pt[0], pt[1]));
    const under = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{b.hwnd});
    const found = try b.caller.call("ui_find", "{{\"query\":\"role:button selftest\"}}", .{});
    const list = try b.caller.call("window_list", "{{}}", .{});
    const listed = if (std.mem.indexOf(u8, list.text, handle)) |at| firstLine(list.text[at + 1 ..]) else "";

    // The same window with a strip beside the decoy.
    const strip = showStrip(b, home, frame, cover);
    const peeking = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{b.hwnd});
    const list_strip = try b.caller.call("window_list", "{{}}", .{});
    const listed_strip = if (std.mem.indexOf(u8, list_strip.text, handle)) |at| firstLine(list_strip.text[at + 1 ..]) else "";
    _ = w.SetWindowPos(t, b.decoy.hwnd, home.left, home.top, 0, 0, w.SWP_NOSIZE | w.SWP_NOACTIVATE);
    w.Sleep(80);
    const back = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{b.hwnd});
    const v = b.end(before);

    const flag = " {occluded}";
    var buf: [96]u8 = undefined;
    if (shown != 0) {
        b.report.fail(name, "the target answers {d} of 5 hit tests under the decoy: it is not covered", .{shown});
    } else if (under.is_error or !std.mem.endsWith(u8, firstLine(under.text), flag) or !std.mem.endsWith(u8, firstLine(found.text), flag)) {
        b.report.fail(name, "covered by the decoy, ui_tree is headed `{s}` and ui_find `{s}`", .{ firstLine(under.text), firstLine(found.text) });
    } else if (std.mem.indexOf(u8, listed, "occluded") == null) {
        b.report.fail(name, "covered by the decoy, window_list says `{s}`", .{listed});
    } else if (std.mem.indexOf(u8, under.text, "Chromium suspend") != null) {
        b.report.fail(name, "a Win32 window received Chromium's frozen-tree line", .{});
    } else if (strip == null) {
        b.report.fail(name, "no side of the decoy leaves a {d} px strip of the target that Win32 hit-tests", .{strip_px});
    } else if (peeking.is_error or std.mem.indexOf(u8, firstLine(peeking.text), "occluded") != null or std.mem.indexOf(u8, listed_strip, "occluded") != null) {
        b.report.fail(name, "with a {d} px strip in view at {d},{d}, ui_tree is headed `{s}` and window_list says `{s}`", .{ strip_px, strip.?[0], strip.?[1], firstLine(peeking.text), listed_strip });
    } else if (!std.mem.endsWith(u8, firstLine(back.text), flag)) {
        b.report.fail(name, "back under the decoy, ui_tree is headed `{s}`", .{firstLine(back.text)});
    } else if (v.any()) {
        b.report.fail(name, "the session changed: {s}", .{v.text(&buf)});
    } else b.report.ok(name, "under the decoy, where no point of the target answers a hit test: `{s}` in ui_tree and ui_find, `{s}` in window_list, no Chromium line for a Win32 window; with a {d} px strip in view (hit-tested at {d},{d}): `{s}`; back under: flagged again; session unchanged", .{
        firstLine(under.text), listed, strip_px, strip.?[0], strip.?[1], firstLine(peeking.text),
    });
}

/// US-059: the calculation with `cost_windows` more top-level windows above
/// the target, each overlapping it, so every one goes through every test.
fn occlusionCost(b: *Bench, backend: *Windows, arena: std.mem.Allocator) !void {
    const name = "bg-occlusion-cost";
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const t = b.tw.window();
    const frame = window.rect(t) orelse return b.report.fail(name, "the target has no frame", .{});
    const per_us = selftest.cyclesPerUs();

    const before = b.begin() orelse return error.DecoyLost;
    var made: [cost_windows]w.HWND = undefined;
    var n: usize = 0;
    defer for (made[0..n]) |h| {
        _ = w.DestroyWindow(h);
    };
    // Shown without activation and tucked under the decoy: above the
    // target, never in front of the user.
    for (0..cost_windows) |i| {
        const off: i32 = @intCast(i * 4);
        const h = w.CreateWindowExW(w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE, L("Static"), null, w.WS_POPUP, frame.x + off, frame.y + off, 120, 80, null, null, null, null) orelse continue;
        made[n] = h;
        n += 1;
        _ = w.SetWindowPos(h, b.decoy.hwnd, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE | w.SWP_SHOWWINDOW);
    }
    w.Sleep(60);
    var walls: [200]u64 = undefined;
    var cpus: [200]u64 = undefined;
    var covers: usize = 0;
    var total: usize = 0;
    var hidden = false;
    var scratch: std.heap.ArenaAllocator = .init(arena);
    for (&walls, &cpus) |*wall, *cpu| {
        _ = scratch.reset(.retain_capacity);
        const a = scratch.allocator();
        var c0: u64 = 0;
        _ = w.QueryThreadCycleTime(w.GetCurrentThread(), &c0);
        const t0 = qpcUs();
        // What `occlusionIn` in a11y.zig does for a window that is not
        // Chromium's.
        const layers = backend.windowLayers(a);
        const at = for (layers, 0..) |l, i| {
            if (l.handle == b.hwnd) break i;
        } else return b.report.fail(name, "the target is not among the {d} windows of the z-order", .{layers.len});
        const rects = try a.alloc(display.Rect, at);
        var above: usize = 0;
        for (layers[0..at]) |l| {
            if (l.minimized or !l.solid or !l.rect.intersects(layers[at].rect)) continue;
            rects[above] = l.rect;
            above += 1;
        }
        hidden = display.hidden(a, layers[at].rect, backend.displays(), rects[0..above]);
        total = layers.len;
        wall.* = qpcUs() - t0;
        var c1: u64 = 0;
        _ = w.QueryThreadCycleTime(w.GetCurrentThread(), &c1);
        cpu.* = @intFromFloat(@as(f64, @floatFromInt(c1 -| c0)) / per_us);
        covers = above;
    }
    // Through the tool, with the same windows in place.
    const tree = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{b.hwnd});
    const v = b.end(before);
    std.mem.sort(u64, &walls, {}, std.sort.asc(u64));
    std.mem.sort(u64, &cpus, {}, std.sort.asc(u64));
    var buf: [96]u8 = undefined;
    if (n != cost_windows or covers < cost_windows + 1) {
        b.report.fail(name, "{d} of {d} windows created, {d} counted above the target", .{ n, cost_windows, covers });
    } else if (!hidden or !std.mem.endsWith(u8, firstLine(tree.text), " {occluded}")) {
        b.report.fail(name, "under the decoy and {d} windows the target is not occluded: `{s}`", .{ n, firstLine(tree.text) });
    } else if (p95(&walls) >= occlusion_budget_us or p95(&cpus) >= occlusion_budget_us) {
        b.report.fail(name, "{d} windows above the target: p95 {d} us (median {d} us), thread CPU p95 {d} us; budget {d} us each", .{ covers, p95(&walls), walls[walls.len / 2], p95(&cpus), occlusion_budget_us });
    } else if (v.any()) {
        b.report.fail(name, "the session changed: {s}", .{v.text(&buf)});
    } else b.report.ok(name, "{d} top-level windows above the target and overlapping it ({d} made for the measure, the decoy), {d} in the z-order: reading it and the calculation take p95 {d} us (median {d} us, budget {d} us), thread CPU p95 {d} us, over {d} runs (Debug build); the target stays occluded; session unchanged", .{
        covers, n, total, p95(&walls), walls[walls.len / 2], occlusion_budget_us, p95(&cpus), walls.len,
    });
}
