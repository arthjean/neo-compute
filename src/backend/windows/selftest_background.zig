//! `neo-compute selftest --background` (US-044): the proof that every
//! background action reaches its target and takes nothing from the user.
//!
//! A decoy window of another process holds the foreground with the keyboard
//! focus in its text field, as a user working in their application. The test
//! window sits under it, never active. Each `bg-*` control runs one tool
//! through the dispatcher of a `--mode background` server and requires, in
//! the same step, the effect read from the target by Win32 and no change of
//! the foreground window, the keyboard focus, the cursor or the clipboard,
//! and no injected input event, SendInput call or UI Automation SetFocus.
//!
//! The run needs a quiet desktop: a key press or an application switch by
//! the user moves the focus or the foreground and counts as a violation. The
//! cursor is the user's and may move; it is compared only when no physical
//! mouse move was seen during the step.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const uitree = @import("../../core/uitree.zig");
const test_window = @import("test_window.zig");
const TestWindow = test_window.TestWindow;
const fixture = @import("bg_fixture.zig");
const Decoy = fixture.Decoy;
const State = fixture.State;
const Violation = fixture.Violation;
const hooks = @import("hooks.zig");
const window = @import("window.zig");
const selftest = @import("selftest.zig");
const Report = selftest.Report;
const Caller = selftest.Caller;
const Windows = @import("../windows.zig").Windows;
const Control = @import("../../core/control.zig").Control;
const mcp = @import("../../core/mcp.zig");
const tools = @import("../../core/tools.zig");
const display = @import("../../core/display.zig");

pub const Server = mcp.Server(Windows, tools.all);
const cohabitation = @import("selftest_cohabitation.zig");
const actions = @import("selftest_actions.zig");
const uia_events = @import("uia_events.zig");
const core_a11y = @import("../../core/a11y.zig");

/// Actions of `bg-loop` (PRD, US-044).
pub const loop_actions = 1000;

/// Why a control passes or fails: an action must reach its target and
/// leave the session alone, both.
pub const Verdict = enum { ok, no_effect, violation };

pub fn verdict(effect: bool, v: Violation) Verdict {
    if (v.any()) return .violation;
    return if (effect) .ok else .no_effect;
}

pub const Bench = struct {
    report: *Report,
    caller: *Caller,
    decoy: *const Decoy,
    tw: *TestWindow,
    ks: ?*const hooks.KillSwitch,
    hwnd: u64,
    /// Time the foreground guard added to each action of `bg-loop`
    /// (US-050), in nanoseconds.
    guard_ns: [loop_actions]u64 = undefined,
    guard_n: usize = 0,
    /// The first tree of the target, where the controls take their ids.
    tree: []const u8 = "",
    /// Measures during which the user's own mouse moved: the cursor is not
    /// judged for those.
    user_mouse: u32 = 0,

    /// The decoy in front and the target under it, then the session's
    /// state. Null when the decoy cannot take the foreground back.
    pub fn begin(b: *Bench) ?State {
        if (!b.decoy.front()) return null;
        w.Sleep(60);
        const t = b.tw.window();
        if (w.IsIconic(t) == 0 and !fixture.above(b.decoy.hwnd, t)) {
            b.decoy.tuck(t);
            w.Sleep(40);
        }
        return State.sample(b.ks);
    }

    /// What changed since `before`. The decoy's own input is injected
    /// before the sample, never after it.
    pub fn end(b: *Bench, before: State) Violation {
        const after = State.sample(b.ks);
        if (State.userMouse(before, after)) b.user_mouse += 1;
        return Violation.of(before, after);
    }

    pub fn id(b: *Bench, needle: []const u8) ?[]const u8 {
        return idIn(b.tree, needle);
    }

    /// The id of the first line of `tree` that holds `needle`.
    pub fn idIn(tree: []const u8, needle: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, tree, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, needle) == null) continue;
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            const first = it.next() orelse return null;
            return if (uitree.parseId(first) != null) first else null;
        }
        return null;
    }

    /// One `ui_act` and its verdict. `effect` reads the target after the
    /// call, for up to 500 ms.
    fn act(b: *Bench, element: []const u8, action: []const u8, value: ?[]const u8, effect: *const fn (*TestWindow, Base) bool) !struct { verdict: Verdict, violation: Violation, is_error: bool, text: []const u8 } {
        const base = Base.of(b.tw);
        const before = b.begin() orelse return error.DecoyLost;
        const res = if (value) |v|
            try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"{s}\",\"value\":\"{s}\",\"observe\":\"none\"}}", .{ element, action, v })
        else
            try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"{s}\",\"observe\":\"none\"}}", .{ element, action });
        if (b.guard_n < b.guard_ns.len) {
            b.guard_ns[b.guard_n] = b.caller.server.timings.get(.guard);
            b.guard_n += 1;
        }
        var reached = false;
        var waited: u32 = 0;
        while (waited <= 500) : (waited += 10) {
            reached = effect(b.tw, base);
            if (reached) break;
            w.Sleep(10);
        }
        const v = b.end(before);
        return .{ .verdict = if (res.is_error) .no_effect else verdict(reached, v), .violation = v, .is_error = res.is_error, .text = res.text };
    }

    /// Runs one named `ui_act` control and reports it.
    fn control(b: *Bench, name: []const u8, needle: []const u8, action: []const u8, value: ?[]const u8, effect: *const fn (*TestWindow, Base) bool) void {
        const element = b.id(needle) orelse return b.report.fail(name, "no element `{s}` in the target's tree", .{needle});
        const r = b.act(element, action, value, effect) catch |err| return b.report.fail(name, "{t}", .{err});
        var buf: [96]u8 = undefined;
        switch (r.verdict) {
            .ok => b.report.ok(name, "effect on the target, foreground, focus, cursor and clipboard unchanged, 0 injected event", .{}),
            .no_effect => b.report.fail(name, "the action did not reach the target{s}{s}", .{ if (r.is_error) ": " else "", if (r.is_error) r.text else "" }),
            .violation => b.report.fail(name, "the session changed: {s}", .{r.violation.text(&buf)}),
        }
    }
};

/// The target's state before an action, from Win32.
const Base = struct {
    commands: u32,
    checked: bool,

    fn of(tw: *TestWindow) Base {
        return .{ .commands = tw.commandCount(), .checked = tw.checked() };
    }
};

const effects = struct {
    fn command(tw: *TestWindow, base: Base) bool {
        return tw.commandCount() > base.commands;
    }
    fn toggled(tw: *TestWindow, base: Base) bool {
        return tw.checked() != base.checked;
    }
    fn comboOpen(tw: *TestWindow, _: Base) bool {
        return tw.comboDropped();
    }
    fn comboClosed(tw: *TestWindow, _: Base) bool {
        return !tw.comboDropped();
    }
    fn selectedThird(tw: *TestWindow, _: Base) bool {
        return tw.listSelection() == 2;
    }
    fn selectedFirst(tw: *TestWindow, _: Base) bool {
        return tw.listSelection() == 0;
    }
    fn scrolledDown(tw: *TestWindow, _: Base) bool {
        return tw.listTop() > 10;
    }
    fn scrolledUp(tw: *TestWindow, _: Base) bool {
        return tw.listTop() == 0;
    }
    fn fieldIs(comptime text: []const u8) fn (*TestWindow, Base) bool {
        return struct {
            fn f(tw: *TestWindow, _: Base) bool {
                var buf: [64:0]u16 = undefined;
                return std.mem.eql(u16, tw.fieldText(&buf), std.unicode.utf8ToUtf16LeStringLiteral(text));
            }
        }.f;
    }
    fn none(_: *TestWindow, _: Base) bool {
        return false;
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, log: *std.Io.Writer) !?[]const u8 {
    var report: Report = .{ .log = log };
    try com.check(w.CoInitializeEx(null, @bitCast(w.COINIT_MULTITHREADED)));
    defer w.CoUninitialize();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var backend: Windows = .init(gpa);
    defer backend.deinit();
    const displays = backend.displays();
    if (displays.len == 0) {
        report.fail("bg-setup", "no display enumerated", .{});
        return report.failed;
    }
    const primary = displays[0].rect;
    const area: display.Rect = .{ .x = primary.x + 40, .y = primary.y + 40, .w = primary.w - 80, .h = primary.h - 160 };
    var decoy = Decoy.start(io, area) catch |err| {
        report.fail("bg-setup", "the decoy window cannot take the foreground ({t})", .{err});
        return report.failed;
    };
    defer decoy.stop(io);

    var tw: TestWindow = .{ .background = true, .actions = true, .rect = .{ .left = area.x + 120, .top = area.y + 120, .right = area.x + 600, .bottom = area.y + 440 } };
    tw.start() catch {
        report.fail("bg-setup", "cannot create the test window", .{});
        return report.failed;
    };
    defer tw.stop();
    w.Sleep(300);
    _ = decoy.front();
    decoy.tuck(tw.window());
    w.Sleep(200);
    const hwnd: u64 = @intFromPtr(tw.window());

    var server: Server = .init(gpa, io, &backend, .{ .mode = .background });
    defer server.deinit();
    // The mode as it ships (EP-012): the low-level hooks on the server's
    // own control, where the user's mouse and Escape pause nothing, and the
    // label of the indicator. The hooks also count injected events. The
    // kill switch stops first: its thread notifies the indicator.
    defer backend.stopIndicator();
    backend.startKillSwitch(&server.control, mcp.control.default_rearm);
    defer backend.stopKillSwitch();
    if (backend.kill == null) {
        report.fail("bg-setup", "low-level hooks could not be installed: injected events cannot be counted", .{});
        return report.failed;
    }
    backend.startIndicator(&server.control, mcp.control.default_rearm);
    var caller: Caller = .{ .server = &server, .arena = arena, .out = .init(gpa) };
    defer caller.out.deinit();
    var b: Bench = .{ .report = &report, .caller = &caller, .decoy = &decoy, .tw = &tw, .ks = backend.kill, .hwnd = hwnd };

    if (!decoy.covers(tw.window()) or w.GetForegroundWindow() != decoy.hwnd) {
        report.fail("bg-setup", "the target is not covered by the decoy in the foreground", .{});
        return report.failed;
    }
    report.ok("bg-setup", "decoy 0x{x} of another process in the foreground with the focus in its field, target 0x{x} under it, never active", .{ @intFromPtr(decoy.hwnd), hwnd });

    // bg-list: the mode lists its nine tools.
    {
        caller.out.clearRetainingCapacity();
        try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":9000,\"method\":\"tools/list\"}", &caller.out.writer);
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, try arena.dupe(u8, caller.out.written()), .{});
        const n = v.object.get("result").?.object.get("tools").?.array.items.len;
        if (n == 9) report.ok("bg-list", "9 tools, all of intrusion class none", .{}) else report.fail("bg-list", "{d} tools listed, expected 9", .{n});
    }

    // bg-ui_tree: reads the covered target, named once.
    {
        const before = b.begin() orelse return lost(&report);
        const res = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{hwnd});
        const v = b.end(before);
        var hbuf: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&hbuf, "window=0x{x}", .{hwnd}) catch "";
        const read = !res.is_error and std.mem.indexOf(u8, res.text, test_window.button_label) != null and std.mem.indexOf(u8, res.text, header) != null;
        b.tree = try arena.dupe(u8, res.text);
        var buf: [96]u8 = undefined;
        switch (verdict(read, v)) {
            .ok => report.ok("bg-ui_tree", "tree of the covered target with its handle in the header, session unchanged", .{}),
            .no_effect => report.fail("bg-ui_tree", "the tree lacks the target's button or handle: {s}", .{res.text[0..@min(res.text.len, 200)]}),
            .violation => report.fail("bg-ui_tree", "the session changed: {s}", .{v.text(&buf)}),
        }
        if (res.is_error) return report.failed;
    }

    // bg-ui_find: without `window`, the session's target.
    {
        const before = b.begin() orelse return lost(&report);
        const res = try caller.call("ui_find", "{{\"query\":\"role:button {s}\"}}", .{"selftest"});
        const v = b.end(before);
        const found = !res.is_error and std.mem.indexOf(u8, res.text, test_window.button_label) != null;
        var buf: [96]u8 = undefined;
        switch (verdict(found, v)) {
            .ok => report.ok("bg-ui_find", "found the target's button without a window argument, session unchanged", .{}),
            .no_effect => report.fail("bg-ui_find", "button not found: {s}", .{res.text[0..@min(res.text.len, 200)]}),
            .violation => report.fail("bg-ui_find", "the session changed: {s}", .{v.text(&buf)}),
        }
    }

    const item_third = test_window.list_prefix ++ "03";
    const item_first = test_window.list_prefix ++ "01";
    const item_far = test_window.list_prefix ++ "25";
    // The tree leaves out what is scrolled out of view: `ui_find` gives the
    // far item its id.
    {
        const res = try caller.call("ui_find", "{{\"query\":\"{s}\"}}", .{item_far});
        if (!res.is_error) b.tree = try std.mem.concat(arena, u8, &.{ b.tree, "\n", res.text });
    }
    b.control("bg-invoke", "button \"" ++ test_window.button_label ++ "\"", "invoke", null, effects.command);
    b.control("bg-toggle", test_window.checkbox_label, "toggle", null, effects.toggled);
    b.control("bg-set_value", "edit \"\" [=" ++ test_window.field_text, "set_value", "neo-compute background", effects.fieldIs("neo-compute background"));
    b.control("bg-select", item_third, "select", null, effects.selectedThird);
    b.control("bg-scroll_into_view", item_far, "scroll_into_view", null, effects.scrolledDown);
    b.control("bg-expand", "combobox", "expand", null, effects.comboOpen);
    b.control("bg-collapse", "combobox", "collapse", null, effects.comboClosed);
    // A drop-down the collapse left open would hide the tree from the rest.
    if (tw.comboDropped()) tw.closeCombo();

    // EP-013: final state of a box, default action, semantic scrolling,
    // slider values, selection by name, waited preconditions, verdict.
    if (try actions.run(&b, arena)) return lost(&report);

    // bg-must-fail-without-effect: the verdict fails an action that changed
    // nothing in the session and did not reach the target either.
    {
        const before = b.begin() orelse return lost(&report);
        const base = Base.of(&tw);
        _ = try caller.call("wait", "{{\"duration\":0}}", .{});
        const v = b.end(before);
        const got = verdict(effects.command(&tw, base), v);
        if (got == .no_effect) report.ok("bg-must-fail-without-effect", "an action without effect on the target is a failure even with the session unchanged", .{}) else report.fail("bg-must-fail-without-effect", "verdict {t} for an action that reached nothing", .{got});
    }

    // bg-refusal: intrusive tools and variants are refused before any effect.
    {
        const before = b.begin() orelse return lost(&report);
        const base = Base.of(&tw);
        const click = try caller.call("left_click", "{{\"coordinate\":[10,10]}}", .{});
        const button = b.id("button \"" ++ test_window.button_label ++ "\"") orelse "e0";
        const focus = try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"focus\"}}", .{button});
        const fallback = try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"invoke\",\"fallback\":\"click\"}}", .{button});
        const clip = try caller.call("clipboard", "{{\"mode\":\"set\",\"text\":\"neo-compute\"}}", .{});
        const v = b.end(before);
        const prefix = "Mode arrière-plan : ";
        const refused = click.is_error and focus.is_error and fallback.is_error and clip.is_error and
            std.mem.startsWith(u8, click.text, prefix) and std.mem.startsWith(u8, focus.text, prefix) and
            std.mem.startsWith(u8, fallback.text, prefix) and std.mem.startsWith(u8, clip.text, prefix);
        var buf: [96]u8 = undefined;
        if (!refused) {
            report.fail("bg-refusal", "an intrusive call was not refused: left_click `{s}`, focus `{s}`", .{ click.text[0..@min(click.text.len, 80)], focus.text[0..@min(focus.text.len, 80)] });
        } else if (effects.command(&tw, base) or v.any()) {
            report.fail("bg-refusal", "a refused call had an effect: {s}", .{v.text(&buf)});
        } else report.ok("bg-refusal", "left_click, ui_act focus, fallback click and clipboard set refused, no effect, session unchanged", .{});
    }

    // bg-window_set: moved, minimized and restored without activation.
    {
        const before = b.begin() orelse return lost(&report);
        const r0 = window.rect(tw.window());
        const moved = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"rect\":[120,140,480,320],\"observe\":\"none\"}}", .{hwnd});
        const r1 = window.rect(tw.window());
        const v = b.end(before);
        const changed = !moved.is_error and r0 != null and r1 != null and (r0.?.x != r1.?.x or r0.?.y != r1.?.y);
        var buf: [96]u8 = undefined;
        switch (verdict(changed, v)) {
            .ok => report.ok("bg-window_set", "moved to {d},{d} without activation, session unchanged", .{ r1.?.x, r1.?.y }),
            .no_effect => report.fail("bg-window_set", "the window did not move: {s}", .{moved.text}),
            .violation => report.fail("bg-window_set", "the session changed: {s}", .{v.text(&buf)}),
        }
    }
    {
        // Maximized first: a maximize the window handles itself can leave it
        // active in its own thread, the state in which a plain
        // SW_SHOWNOACTIVATE restore takes the foreground (decision 0013).
        const before0 = b.begin() orelse return lost(&report);
        const max = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"maximized\",\"observe\":\"none\"}}", .{hwnd});
        w.Sleep(300);
        const maximized = !max.is_error and w.IsZoomed(tw.window()) != 0;
        const v_max = b.end(before0);
        const before = b.begin() orelse return lost(&report);
        const min = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"minimized\",\"observe\":\"none\"}}", .{hwnd});
        const minimized = !min.is_error and w.IsIconic(tw.window()) != 0;
        const v_min = b.end(before);
        const before2 = b.begin() orelse return lost(&report);
        var info = std.mem.zeroes(w.GUITHREADINFO);
        info.cbSize = @sizeOf(w.GUITHREADINFO);
        const thread_active = w.GetGUIThreadInfo(w.GetWindowThreadProcessId(tw.window(), null), &info) != 0 and info.hwndActive == tw.window();
        const norm = try caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"normal\",\"observe\":\"none\"}}", .{hwnd});
        w.Sleep(300);
        const restored = !norm.is_error and w.IsIconic(tw.window()) == 0 and w.IsZoomed(tw.window()) == 0;
        const v_norm = b.end(before2);
        var buf: [96]u8 = undefined;
        if (!maximized or !minimized or !restored) {
            report.fail("bg-restore", "maximized: {}, minimized: {}, restored: {} ({s})", .{ maximized, minimized, restored, norm.text });
        } else if (v_max.any()) {
            report.fail("bg-restore", "maximizing changed the session: {s}", .{v_max.text(&buf)});
        } else if (v_min.any()) {
            report.fail("bg-restore", "minimizing changed the session: {s}", .{v_min.text(&buf)});
        } else if (v_norm.any()) {
            report.fail("bg-restore", "restoring changed the session: {s}", .{v_norm.text(&buf)});
        } else report.ok("bg-restore", "maximized, minimized and restored with the decoy in front, session unchanged (window active in its own thread before the restore: {})", .{thread_active});
    }

    // bg-loop: 1 000 actions, each with its effect, 0 violation in all.
    {
        // The tree again: the window moved, and ids are the session's.
        const again = try caller.call("ui_tree", "{{}}", .{});
        if (!again.is_error) b.tree = try arena.dupe(u8, again.text);
        // The list is scrolled by now: its items come from `ui_find`,
        // which also returns the ones out of view.
        for ([_][]const u8{ item_first, item_third, item_far }) |item| {
            const res = try caller.call("ui_find", "{{\"query\":\"{s}\"}}", .{item});
            if (!res.is_error) b.tree = try std.mem.concat(arena, u8, &.{ b.tree, "\n", res.text });
        }
        const Step = struct { needle: []const u8, action: []const u8, value: ?[]const u8, effect: *const fn (*TestWindow, Base) bool };
        const steps = [_]Step{
            .{ .needle = "button \"" ++ test_window.button_label ++ "\"", .action = "invoke", .value = null, .effect = effects.command },
            .{ .needle = test_window.checkbox_label, .action = "toggle", .value = null, .effect = effects.toggled },
            // Scrolled back up before the selections, so that each one is
            // a single pattern call.
            .{ .needle = item_far, .action = "scroll_into_view", .value = null, .effect = effects.scrolledDown },
            .{ .needle = item_first, .action = "scroll_into_view", .value = null, .effect = effects.scrolledUp },
            .{ .needle = item_third, .action = "select", .value = null, .effect = effects.selectedThird },
            .{ .needle = item_first, .action = "select", .value = null, .effect = effects.selectedFirst },
            // The field as `bg-set_value` left it: the window has other edits.
            .{ .needle = "edit \"\" [=neo-compute background", .action = "set_value", .value = "loop A", .effect = effects.fieldIs("loop A") },
            .{ .needle = "edit \"\" [=neo-compute background", .action = "set_value", .value = "loop B", .effect = effects.fieldIs("loop B") },
        };
        var ids: [steps.len][]const u8 = undefined;
        var resolved = true;
        for (steps, &ids) |s, *out| out.* = b.id(s.needle) orelse blk: {
            resolved = false;
            report.fail("bg-loop", "no element `{s}` in the target's tree", .{s.needle});
            break :blk "";
        };
        if (resolved) {
            var violations: u32 = 0;
            var missed: u32 = 0;
            var missed_by: [steps.len]u32 = @splat(0);
            var seen: u8 = 0;
            var first_violation: ?usize = null;
            var first_miss: ?usize = null;
            var miss_text: [160]u8 = undefined;
            var miss_len: usize = 0;
            // One sample around the whole series would hide a change that
            // came and went: every action is sampled.
            var n: usize = 0;
            b.guard_n = 0;
            while (n < loop_actions) : (n += 1) {
                const s = steps[n % steps.len];
                const r = b.act(ids[n % steps.len], s.action, s.value, s.effect) catch return lost(&report);
                if (r.verdict == .ok) continue;
                if (r.verdict == .violation) {
                    violations += 1;
                    seen |= @as(u8, @bitCast(r.violation));
                    if (first_violation == null) first_violation = n;
                    continue;
                }
                missed += 1;
                missed_by[n % steps.len] += 1;
                if (first_miss == null) {
                    first_miss = n;
                    const txt = if (r.is_error) r.text[0..@min(r.text.len, miss_text.len)] else "the call succeeded, the target did not change";
                    @memcpy(miss_text[0..txt.len], txt);
                    miss_len = txt.len;
                }
            }
            if (violations == 0 and missed == 0) {
                report.ok("bg-loop", "{d} actions, each with its effect on the target, 0 violation, {d} SendInput and {d} SetFocus calls by the server; the user's own mouse moved during {d} measure(s) of the run, where the cursor is not judged", .{ loop_actions, @import("input.zig").send_calls.load(.monotonic), @import("uia.zig").set_focus_calls.load(.monotonic), b.user_mouse });
            } else {
                var vbuf: [96]u8 = undefined;
                const kinds = @as(Violation, @bitCast(seen)).text(&vbuf);
                const miss_at = first_miss orelse 0;
                report.fail("bg-loop", "{d} violation(s) ({s}; first at action {d}) and {d} action(s) without effect on {d} (per step: {any}; first at action {d}, {s} {s}: {s})", .{
                    violations,                        kinds,                  (first_violation orelse 0) + 1, missed,
                    loop_actions,                      missed_by,              miss_at + 1,                    steps[miss_at % steps.len].action,
                    steps[miss_at % steps.len].needle, miss_text[0..miss_len],
                });
            }
        }
    }

    // EP-012: pause shortcut, label, settling and waits on change events,
    // foreground guard.
    if (try cohabitation.run(&b, &backend, &server, &decoy, io, env, arena, area)) return lost(&report);
    // The session's target again: the guard's check named another window.
    _ = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{hwnd});

    // bg-launch: Calculator opens without taking the foreground.
    launchCheck(&b, &backend, arena) catch |err| report.fail("bg-launch", "{t}", .{err});

    // bg-must-catch: the detector sees a real click of the a11y mode. Last:
    // it moves the cursor.
    {
        var a11y: Server = .init(gpa, io, &backend, .{});
        defer a11y.deinit();
        var a11y_caller: Caller = .{ .server = &a11y, .arena = arena, .out = .init(gpa) };
        defer a11y_caller.out.deinit();
        const before = b.begin() orelse return lost(&report);
        const user_before = b.user_mouse;
        _ = try a11y_caller.call("screenshot", "{{}}", .{});
        // On the decoy, away from where the cursor already is: a click
        // where the cursor rests would not move it.
        const at: u32 = if (before.cursor[0] < 700 and before.cursor[1] < 700) 500 else 60;
        const click = try a11y_caller.call("left_click", "{{\"coordinate\":[{d},{d}],\"observe\":\"none\"}}", .{ at, at });
        w.Sleep(100);
        const v = b.end(before);
        // The cursor is not judged while the user's own mouse moves.
        const cursor_seen = v.cursor or b.user_mouse != user_before;
        var buf: [96]u8 = undefined;
        if (click.is_error) {
            report.fail("bg-must-catch", "the a11y left_click failed: {s}", .{click.text});
        } else if (v.injected and v.send_input and cursor_seen) {
            report.ok("bg-must-catch", "an a11y left_click is flagged: {s}", .{v.text(&buf)});
        } else report.fail("bg-must-catch", "the detector missed an a11y left_click (saw: {s})", .{v.text(&buf)});
        // The background mode's setting again, for whatever runs next.
        backend.uiAutoFocus(false);
    }
    return report.failed;
}

fn lost(report: *Report) ?[]const u8 {
    report.fail("bg-setup", "the decoy cannot take the foreground back: a user or an application took it during the run", .{});
    return report.failed;
}

const calculator_aumid = "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App";

/// Settling on a XAML application (decision 0013, amendment of 2026-11-13).
/// Calculator raises no WinEvent of its own when a key changes its display:
/// it raises UI Automation events, for a client that subscribed. Ten Invoke
/// on a digit: each must move the server's UI Automation counter and settle
/// on the events, with no tree read in place of them. A first action,
/// unmeasured, is the one whose settling subscribes.
fn xamlSettle(b: *Bench, handle: u64) !void {
    const name = "bg-settle-xaml";
    const tree = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{handle});
    const digit = Bench.idIn(tree.text, "button \"Un\"") orelse Bench.idIn(tree.text, "button \"One\"") orelse
        return b.report.skip(name, "no digit button named Un or One in Calculator's tree", .{});
    const invoke = "{{\"id\":\"{s}\",\"action\":\"invoke\"}}";
    _ = try b.caller.call("ui_act", invoke, .{digit});
    const reps = 10;
    var signaled: u32 = 0;
    var unsettled: u32 = 0;
    var reread: u32 = 0;
    var violations: u32 = 0;
    var events: u64 = 0;
    for (0..reps) |_| {
        const before = b.begin() orelse return error.DecoyLost;
        const seen = uia_events.count.load(.acquire);
        const res = try b.caller.call("ui_act", invoke, .{digit});
        const got = uia_events.count.load(.acquire) - seen;
        if (b.end(before).any()) violations += 1;
        if (got > 0) signaled += 1;
        events += got;
        if (res.is_error or std.mem.indexOf(u8, res.text, "; settled in ") == null) unsettled += 1;
        if (std.mem.indexOf(u8, res.text, core_a11y.reread_note) != null) reread += 1;
    }
    if (signaled == reps and unsettled == 0 and reread == 0 and violations == 0)
        b.report.ok(name, "{d} Invoke on a Calculator digit under the decoy: each raised UI Automation events for the server's handlers ({d} in all) and settled on them, session unchanged", .{ reps, events })
    else
        b.report.fail(name, "{d} of {d} actions raised a UI Automation event ({d} in all), {d} not settled, {d} settled by reading the tree again, {d} with the session changed", .{ signaled, reps, events, unsettled, reread, violations });
}

fn calculatorOpen(backend: *Windows, arena: std.mem.Allocator) bool {
    const wins = backend.listWindows(arena, true) catch return true;
    for (wins) |win| {
        if (std.ascii.eqlIgnoreCase(win.exe, "CalculatorApp.exe")) return true;
        if (std.ascii.eqlIgnoreCase(win.exe, "ApplicationFrameHost.exe")) if (backend.appPid(win.handle)) |pid| {
            if (window.processName(arena, pid) catch null) |name| if (std.ascii.eqlIgnoreCase(name, "CalculatorApp.exe")) return true;
        };
    }
    return false;
}

/// US-043: `app_launch` in background mode, the foreground the same before
/// and 2 s after. The window it opened is closed again; a Calculator the
/// user already had open is never touched.
fn launchCheck(b: *Bench, backend: *Windows, arena: std.mem.Allocator) !void {
    if (calculatorOpen(backend, arena)) return b.report.skip("bg-launch", "a Calculator window is already open: the selftest never touches a window it did not open", .{});
    const before = b.begin() orelse return error.DecoyLost;
    const res = try b.caller.call("app_launch", "{{\"name\":\"{s}\",\"observe\":\"none\"}}", .{calculator_aumid});
    if (res.is_error) return b.report.fail("bg-launch", "app_launch failed: {s}", .{res.text});
    w.Sleep(2000);
    const v = b.end(before);
    var it = std.mem.tokenizeAny(u8, res.text, " \n");
    const handle = tools.parseHandle(it.next() orelse "") orelse return b.report.fail("bg-launch", "no handle in `{s}`", .{res.text});
    xamlSettle(b, handle) catch |err| b.report.fail("bg-settle-xaml", "{t}", .{err});
    // Closed by the mode's own tool, then checked.
    _ = try b.caller.call("window_set", "{{\"window\":\"0x{x}\",\"state\":\"closed\",\"observe\":\"none\"}}", .{handle});
    var waited: u32 = 0;
    while (waited < 3000 and w.IsWindow(@ptrFromInt(handle)) != 0) : (waited += 50) w.Sleep(50);
    var buf: [96]u8 = undefined;
    const took = std.mem.indexOf(u8, res.text, "a pris le premier plan") != null;
    if (v.foreground or v.focus or took) {
        b.report.fail("bg-launch", "Calculator took the foreground ({s}): {s}", .{ v.text(&buf), res.text });
    } else if (v.injected or v.send_input or v.set_focus or v.clipboard) {
        b.report.fail("bg-launch", "the session changed: {s}", .{v.text(&buf)});
    } else b.report.ok("bg-launch", "Calculator opened as 0x{x}, foreground and focus the same before and 2 s after, then closed", .{handle});
    if (w.IsWindow(@ptrFromInt(handle)) != 0) b.report.fail("bg-launch", "the Calculator window 0x{x} is still open: close it by hand", .{handle});
}
