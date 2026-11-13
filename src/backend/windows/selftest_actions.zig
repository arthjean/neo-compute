//! The complete semantic actions (EP-013) in `neo-compute selftest
//! --background`: each `bg-*` control runs `ui_act` through the dispatcher of
//! the background server on the covered test window, and requires in the
//! same step the effect read from the target by Win32, the verdict the
//! result announces, and an unchanged session (foreground, keyboard focus,
//! cursor, clipboard, no injected event).

const std = @import("std");
const w = @import("win32");
const test_window = @import("test_window.zig");
const TestWindow = test_window.TestWindow;
const bg = @import("selftest_background.zig");
const Bench = bg.Bench;

/// Toggles timed by `bg-verdict`.
const verdict_reps = 40;
/// US-055: what the read-back may add to an action whose effect shows at
/// the first read, at the 95th percentile.
const verdict_budget_ns = 10 * std.time.ns_per_ms;

/// Default actions the legacy control had run before `bg-legacy`.
var legacy_clicks: u32 = 0;

const Step = struct {
    needle: []const u8,
    action: []const u8,
    value: ?[]const u8 = null,
    /// What the first line of the result must hold.
    says: []const u8,
    /// An error result is the expected one (a refusal).
    refused: bool = false,
    effect: *const fn (*TestWindow) bool,
};

const Sent = struct { is_error: bool, text: []const u8 };

fn send(b: *Bench, element: []const u8, action: []const u8, value: ?[]const u8) !Sent {
    const res = if (value) |v|
        try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"{s}\",\"value\":\"{s}\",\"observe\":\"none\"}}", .{ element, action, v })
    else
        try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"{s}\",\"observe\":\"none\"}}", .{ element, action });
    return .{ .is_error = res.is_error, .text = res.text };
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

/// The effect, read from the target for up to 500 ms.
fn within(tw: *TestWindow, effect: *const fn (*TestWindow) bool) bool {
    var waited: u32 = 0;
    while (waited <= 500) : (waited += 10) {
        if (effect(tw)) return true;
        w.Sleep(10);
    }
    return false;
}

/// One `ui_act`. False, with the control reported as failed, when the call,
/// its verdict, its effect or the session is not what the step requires.
fn step(b: *Bench, name: []const u8, s: Step) !bool {
    const element = b.id(s.needle) orelse {
        b.report.fail(name, "no element `{s}` in the target's tree", .{s.needle});
        return false;
    };
    const before = b.begin() orelse return error.DecoyLost;
    const res = try send(b, element, s.action, s.value);
    const reached = within(b.tw, s.effect);
    const v = b.end(before);
    const line = firstLine(res.text);
    var buf: [96]u8 = undefined;
    var state: [200]u8 = undefined;
    if (res.is_error != s.refused) {
        b.report.fail(name, "{s} {s}: {s}", .{ s.action, s.value orelse "", line });
    } else if (std.mem.indexOf(u8, line, s.says) == null) {
        b.report.fail(name, "{s} {s} answered `{s}`, expected `{s}`", .{ s.action, s.value orelse "", line, s.says });
    } else if (!reached) {
        b.report.fail(name, "{s} {s} answered `{s}` and the target does not show it ({s})", .{ s.action, s.value orelse "", line, targetState(b.tw, &state) });
    } else if (v.any()) {
        b.report.fail(name, "{s} {s} changed the session: {s}", .{ s.action, s.value orelse "", v.text(&buf) });
    } else return true;
    return false;
}

/// The target as Win32 gives it, for a failure message.
fn targetState(tw: *TestWindow, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "three-state box {d}, legacy clicks {d}, list top {d} selection {d}, slider {d}, drop-down selection {d} open {}", .{
        tw.tristateState(), tw.legacyClicks(),   tw.listTop(),      tw.listSelection(),
        tw.sliderPos(),     tw.comboSelection(), tw.comboDropped(),
    }) catch "";
}

fn all(b: *Bench, name: []const u8, steps: []const Step) !bool {
    for (steps) |s| if (!try step(b, name, s)) return false;
    return true;
}

const fx = struct {
    fn tristate(comptime state: isize) fn (*TestWindow) bool {
        return struct {
            fn f(tw: *TestWindow) bool {
                return tw.tristateState() == state;
            }
        }.f;
    }
    fn legacyClicked(tw: *TestWindow) bool {
        return tw.legacyClicks() == legacy_clicks + 1;
    }
    fn listTop(comptime top: isize) fn (*TestWindow) bool {
        return struct {
            fn f(tw: *TestWindow) bool {
                return tw.listTop() == top;
            }
        }.f;
    }
    fn listBelow(comptime top: isize) fn (*TestWindow) bool {
        return struct {
            fn f(tw: *TestWindow) bool {
                return tw.listTop() > top;
            }
        }.f;
    }
    fn listSelected(comptime index: isize) fn (*TestWindow) bool {
        return struct {
            fn f(tw: *TestWindow) bool {
                return tw.listSelection() == index;
            }
        }.f;
    }
    fn slider(comptime pos: isize) fn (*TestWindow) bool {
        return struct {
            fn f(tw: *TestWindow) bool {
                return tw.sliderPos() == pos;
            }
        }.f;
    }
    /// The entry chosen, and the drop-down closed again.
    fn combo(comptime index: isize) fn (*TestWindow) bool {
        return struct {
            fn f(tw: *TestWindow) bool {
                return tw.comboSelection() == index and !tw.comboDropped();
            }
        }.f;
    }
};

/// Runs the EP-013 controls. True when the decoy lost the foreground to
/// something else than the server: the run cannot judge any further.
pub fn run(b: *Bench, arena: std.mem.Allocator) !bool {
    return controls(b, arena) catch |err| switch (err) {
        error.DecoyLost => true,
        else => err,
    };
}

fn controls(b: *Bench, arena: std.mem.Allocator) !bool {
    const tw = b.tw;
    const item = test_window.list_prefix;
    // The target as its own thread left it, and its ids again: the items
    // out of view come from `ui_find`.
    if (tw.comboDropped()) tw.closeCombo();
    tw.setTristate(0);
    tw.listToTop();
    w.Sleep(100);
    {
        const tree = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{b.hwnd});
        if (tree.is_error) {
            b.report.fail("bg-check", "the target's tree cannot be read: {s}", .{tree.text});
            return false;
        }
        b.tree = try arena.dupe(u8, tree.text);
        for ([_][]const u8{ item ++ "01", item ++ "07", item ++ "25" }) |name| {
            const res = try b.caller.call("ui_find", "{{\"query\":\"{s}\"}}", .{name});
            if (!res.is_error) b.tree = try std.mem.concat(arena, u8, &.{ b.tree, "\n", res.text });
        }
    }
    const box = test_window.tristate_label;
    // The list box is the one element of the tree that shows a scroll
    // position.
    const list = "scroll=";

    // US-051. A three-state box runs unchecked, checked, mixed.
    if (try all(b, "bg-check", &.{
        .{ .needle = box, .action = "check", .says = "vérifié (coché)", .effect = fx.tristate(1) },
        .{ .needle = box, .action = "check", .says = "déjà coché", .effect = fx.tristate(1) },
    })) b.report.ok("bg-check", "an unchecked three-state box is checked by one Toggle and read back, a second check calls nothing, session unchanged", .{});
    if (try all(b, "bg-uncheck", &.{
        .{ .needle = box, .action = "uncheck", .says = "vérifié (décoché) ; 2 bascules", .effect = fx.tristate(0) },
        .{ .needle = box, .action = "uncheck", .says = "déjà décoché", .effect = fx.tristate(0) },
    })) b.report.ok("bg-uncheck", "a checked three-state box is unchecked through its mixed state in 2 Toggle calls, a second uncheck calls nothing, session unchanged", .{});
    tw.setTristate(0);
    legacy_clicks = tw.legacyClicks();
    if (try all(b, "bg-legacy", &.{
        .{ .needle = test_window.legacy_label, .action = "invoke", .says = "délivré, effet non vérifiable ; par LegacyIAccessible.DoDefaultAction", .effect = fx.legacyClicked },
    })) b.report.ok("bg-legacy", "invoke on a control that names a default action and has no InvokePattern ran LegacyIAccessible.DoDefaultAction: the control received it, session unchanged", .{});

    // US-052.
    if (try all(b, "bg-scroll", &.{
        .{ .needle = list, .action = "scroll", .value = "down 3", .says = "vérifié (scroll=", .effect = fx.listTop(3) },
        .{ .needle = list, .action = "scroll", .value = "page_down", .says = "vérifié (scroll=", .effect = fx.listBelow(3) },
        .{ .needle = list, .action = "scroll", .value = "bottom", .says = "vérifié (scroll=100%", .effect = fx.listBelow(20) },
        .{ .needle = list, .action = "scroll", .value = "down", .says = "déjà en bas", .effect = fx.listBelow(20) },
        .{ .needle = list, .action = "scroll", .value = "top", .says = "vérifié (scroll=0%", .effect = fx.listTop(0) },
        .{ .needle = list, .action = "scroll", .value = "sideways", .says = "invalide pour scroll", .refused = true, .effect = fx.listTop(0) },
    })) b.report.ok("bg-scroll", "the list scrolled by 3 notches, a page, to its bottom and back to its top without the wheel, each position read back, session unchanged", .{});
    if (try all(b, "bg-scroll-ancestor", &.{
        .{ .needle = item ++ "01", .action = "scroll", .value = "down 2", .says = "; conteneur ", .effect = fx.listTop(2) },
        .{ .needle = box, .action = "scroll", .value = "down", .says = "n'est dans aucun conteneur défilable", .refused = true, .effect = fx.listTop(2) },
    })) b.report.ok("bg-scroll-ancestor", "scroll on a list item moved the list that holds it, and an element in no scrollable container is refused, session unchanged", .{});
    tw.listToTop();

    // US-053.
    if (try all(b, "bg-range", &.{
        .{ .needle = "slider", .action = "set_value", .value = "75", .says = "vérifié (valeur relue identique)", .effect = fx.slider(75) },
        .{ .needle = "slider", .action = "set_value", .value = "150", .says = "Valeur 150 hors plage 0..100", .refused = true, .effect = fx.slider(75) },
        .{ .needle = "slider", .action = "set_value", .value = "fort", .says = "attend un nombre entre 0 et 100", .refused = true, .effect = fx.slider(75) },
        .{ .needle = "slider", .action = "set_value", .value = "40", .says = "vérifié (valeur relue identique)", .effect = fx.slider(test_window.slider_pos) },
    })) b.report.ok("bg-range", "the trackbar went to 75 and back to 40 by RangeValue, a value out of range or not a number is refused, session unchanged", .{});
    if (try all(b, "bg-select-name", &.{
        .{ .needle = "combobox", .action = "select", .value = "NEO-COMPUTE OPTION C", .says = "vérifié (sélectionné)", .effect = fx.combo(2) },
        .{ .needle = "combobox", .action = "select", .value = "neo-compute option z", .says = "Aucune entrée « neo-compute option z »", .refused = true, .effect = fx.combo(2) },
        .{ .needle = "combobox", .action = "select", .value = "neo-compute option a", .says = "vérifié (sélectionné)", .effect = fx.combo(0) },
        .{ .needle = list, .action = "select", .value = item ++ "07", .says = "vérifié (sélectionné)", .effect = fx.listSelected(6) },
    })) b.report.ok("bg-select-name", "the drop-down list took an entry by its name whatever the case and is closed again, an unknown name is refused with the entries, the list box took its seventh item, session unchanged", .{});
    if (tw.comboDropped()) tw.closeCombo();

    // US-054.
    waitEnabled(b) catch |err| if (err == error.DecoyLost) return err else b.report.fail("bg-wait-enabled", "{t}", .{err});
    tw.listToTop();
    w.Sleep(50);
    if (try all(b, "bg-auto-scroll", &.{
        .{ .needle = item ++ "25", .action = "select", .says = "vérifié (sélectionné) ; amené en vue", .effect = fx.listSelected(24) },
    })) b.report.ok("bg-auto-scroll", "an item out of the list's view is scrolled into view, then selected, in one call, session unchanged", .{});
    tw.listToTop();

    // US-055.
    try verdictCost(b);
    return false;
}

/// US-054: a button disabled when `ui_act` is called and enabled 500 ms
/// later is invoked by that one call.
fn waitEnabled(b: *Bench) !void {
    const name = "bg-wait-enabled";
    const tw = b.tw;
    const element = b.id(test_window.wait_label) orelse return b.report.fail(name, "no element `{s}` in the target's tree", .{test_window.wait_label});
    const before = b.begin() orelse return error.DecoyLost;
    const commands = tw.waitCommands();
    tw.enableLater(500);
    var posted: u32 = 0;
    while (tw.waitEnabled() and posted < 200) : (posted += 5) w.Sleep(5);
    if (tw.waitEnabled()) return b.report.fail(name, "the test window did not disable its button", .{});
    const start = w.GetTickCount();
    const res = try send(b, element, "invoke", null);
    const took = w.GetTickCount() - start;
    // Invoke returns before the button's thread handles the click.
    var settled: u32 = 0;
    while (tw.waitCommands() == commands and settled < 500) : (settled += 10) w.Sleep(10);
    const reached = tw.waitCommands() == commands + 1;
    const v = b.end(before);
    const line = firstLine(res.text);
    var buf: [96]u8 = undefined;
    const marker = " ; activé après ";
    const waited: ?u64 = if (std.mem.indexOf(u8, line, marker)) |at| blk: {
        var it = std.mem.tokenizeScalar(u8, line[at + marker.len ..], ' ');
        break :blk std.fmt.parseInt(u64, it.next() orelse "", 10) catch null;
    } else null;
    if (res.is_error) {
        b.report.fail(name, "{s}", .{line});
    } else if (waited == null or waited.? < 200 or waited.? > 1000) {
        b.report.fail(name, "the result does not give a wait near 500 ms: `{s}`", .{line});
    } else if (!reached) {
        b.report.fail(name, "`{s}` and the button received no click", .{line});
    } else if (v.any()) {
        b.report.fail(name, "the session changed: {s}", .{v.text(&buf)});
    } else b.report.ok(name, "a button disabled at the call and enabled 500 ms later was invoked by that call after a wait of {d} ms ({d} ms in all), session unchanged", .{ waited.?, took });
}

/// US-055: the read-back of an action whose effect shows at the first read.
fn verdictCost(b: *Bench) !void {
    const name = "bg-verdict";
    const tw = b.tw;
    const element = b.id(test_window.checkbox_label) orelse return b.report.fail(name, "no element `{s}` in the target's tree", .{test_window.checkbox_label});
    var cost: [verdict_reps]u64 = undefined;
    var unverified: u32 = 0;
    var missed: u32 = 0;
    for (&cost) |*c| {
        const state = tw.checked();
        const res = try send(b, element, "toggle", null);
        // The session keeps the read-back time of its last action.
        c.* = b.caller.server.session.verify_ns;
        const want = if (state) "vérifié (décoché)" else "vérifié (coché)";
        if (res.is_error or std.mem.indexOf(u8, firstLine(res.text), want) == null) unverified += 1;
        if (tw.checked() == state) missed += 1;
    }
    std.mem.sort(u64, &cost, {}, std.sort.asc(u64));
    const p95 = cost[(verdict_reps * 95 + 99) / 100 - 1];
    if (unverified != 0 or missed != 0) {
        b.report.fail(name, "{d} of {d} toggles without a verified verdict, {d} without effect on the box", .{ unverified, verdict_reps, missed });
    } else if (p95 >= verdict_budget_ns) {
        b.report.fail(name, "the read-back added {d} us at p95 (median {d} us), budget {d} us", .{ p95 / 1000, cost[verdict_reps / 2] / 1000, verdict_budget_ns / 1000 });
    } else b.report.ok(name, "{d} toggles, each verified at the first read against the state Win32 gives; the read-back added {d} us at p95 (median {d} us), budget {d} us", .{ verdict_reps, p95 / 1000, cost[verdict_reps / 2] / 1000, verdict_budget_ns / 1000 });
}
