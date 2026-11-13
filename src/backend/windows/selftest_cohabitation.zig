//! The EP-012 controls of `neo-compute selftest --background`: the agent
//! and the user share the machine. The user's mouse and Escape key pause
//! nothing and one shortcut pauses and resumes (US-045); the indicator is a
//! label on the primary display (US-046); settling and ui_find's wait read
//! the target's change events, never the screen the user works on (US-048,
//! US-049); a dialog of the target that comes in front is sent back behind
//! the user's window (US-050). Same montage as the rest of that selftest:
//! the decoy of another process in the foreground, the target under it.

const std = @import("std");
const w = @import("win32");
const bg = @import("selftest_background.zig");
const Bench = bg.Bench;
const selftest = @import("selftest.zig");
const Report = selftest.Report;
const test_window = @import("test_window.zig");
const TestWindow = test_window.TestWindow;
const popup_window = @import("popup_window.zig");
const uia_events = @import("uia_events.zig");
const fixture = @import("bg_fixture.zig");
const Decoy = fixture.Decoy;
const State = fixture.State;
const Violation = fixture.Violation;
const hooks = @import("hooks.zig");
const input = @import("input.zig");
const Windows = @import("../windows.zig").Windows;
const control = @import("../../core/control.zig");
const core_indicator = @import("../../core/indicator.zig");
const a11y = @import("../../core/a11y.zig");
const display = @import("../../core/display.zig");

const qpcUs = selftest.qpcUs;

/// The default shortcut, as the keyboard sends it.
const chord = [_]u16{ w.VK_LCONTROL, w.VK_LMENU, w.VK_LSHIFT, 'R' };

fn pressChord(ks: *hooks.KillSwitch) void {
    for (chord) |vk| ks.simulateKey(vk, true);
    for (chord) |vk| ks.simulateKey(vk, false);
}

/// Key-downs of the shortcut's key in `holdChord`: the press and the
/// keyboard's repeats. Even, so a repeat that toggled would leave the
/// server running.
const held_downs = 4;

/// The shortcut held long enough for the keyboard to repeat its key.
fn holdChord(ks: *hooks.KillSwitch) void {
    for (chord) |vk| ks.simulateKey(vk, true);
    for (1..held_downs) |_| ks.simulateKey(chord[chord.len - 1], true);
    for (chord) |vk| ks.simulateKey(vk, false);
}

/// Waits until the server is paused (or not), at most `ms`.
fn waitPaused(c: *const control.Control, paused: bool, ms: u32) bool {
    var waited: u32 = 0;
    while (waited < ms) : (waited += 1) {
        if (c.isPaused() == paused) return true;
        w.Sleep(1);
    }
    return c.isPaused() == paused;
}

fn p95(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[(values.len * 95 + 99) / 100 - 1];
}

/// True when the decoy could not take the foreground back.
pub fn run(b: *Bench, backend: *Windows, server: *bg.Server, decoy: *const Decoy, io: std.Io, env: *const std.process.Environ.Map, arena: std.mem.Allocator, area: display.Rect) !bool {
    const report = b.report;
    const caller = b.caller;
    const tw = b.tw;
    const ks = backend.kill orelse return false;
    const item_first = test_window.list_prefix ++ "01";

    // The tree and the ids again: the loop moved the list.
    {
        const again = try caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{b.hwnd});
        if (!again.is_error) b.tree = try arena.dupe(u8, again.text);
        const res = try caller.call("ui_find", "{{\"query\":\"{s}\"}}", .{item_first});
        if (!res.is_error) b.tree = try std.mem.concat(arena, u8, &.{ b.tree, "\n", res.text });
    }
    // An action that changes nothing: the first item is already in view.
    const still_id = b.id(item_first) orelse {
        report.fail("bg-settle-covered", "no element `{s}` in the target's tree", .{item_first});
        return false;
    };
    const no_effect = "{{\"id\":\"{s}\",\"action\":\"scroll_into_view\"}}";
    const no_effect_within = "{{\"id\":\"{s}\",\"action\":\"scroll_into_view\",\"settle_timeout_ms\":{d}}}";

    // bg-guard-cost: what the foreground guard added to each of the loop's
    // actions, whose foreground stayed intact (US-050).
    if (b.guard_n > 0) {
        const cost = p95(b.guard_ns[0..b.guard_n]);
        const worst = b.guard_ns[b.guard_n - 1];
        if (cost < 100_000)
            report.ok("bg-guard-cost", "foreground read before and after each of {d} actions: p95 {d:.1} us, slowest {d:.1} us (budget 100 us)", .{ b.guard_n, @as(f64, @floatFromInt(cost)) / 1000, @as(f64, @floatFromInt(worst)) / 1000 })
        else
            report.fail("bg-guard-cost", "guard p95 {d:.1} us over {d} actions (budget 100 us)", .{ @as(f64, @floatFromInt(cost)) / 1000, b.guard_n });
    } else report.fail("bg-guard-cost", "no action of bg-loop was timed", .{});

    // bg-settle-covered: the decoy repaints itself over the target every
    // 15 ms. An action without effect settles on the target's silence.
    {
        decoy.animate(true);
        defer decoy.animate(false);
        w.Sleep(200);
        var settle_ns: [30]u64 = undefined;
        var captured: u64 = 0;
        var violations: u32 = 0;
        var unsettled: u32 = 0;
        for (&settle_ns) |*out| {
            const before = b.begin() orelse return true;
            const res = try caller.call("ui_act", no_effect, .{still_id});
            out.* = server.timings.get(.settle);
            captured += server.timings.get(.capture);
            if (b.end(before).any()) violations += 1;
            if (res.is_error or std.mem.indexOf(u8, res.text, "; settled in ") == null) unsettled += 1;
        }
        const ms = @as(f64, @floatFromInt(p95(&settle_ns))) / std.time.ns_per_ms;
        if (ms < 150 and captured == 0 and violations == 0 and unsettled == 0)
            report.ok("bg-settle-covered", "30 actions without effect under a window repainted every 15 ms: settle p95 {d:.1} ms (budget 150 ms), capture stage 0, session unchanged", .{ms})
        else
            report.fail("bg-settle-covered", "settle p95 {d:.1} ms (budget 150 ms), capture stage {d} ns, {d} violation(s), {d} action(s) not settled", .{ ms, captured, violations, unsettled });
    }

    // bg-settle-timeout: a target that changes without rest.
    {
        tw.churn(true);
        w.Sleep(150);
        const res = try caller.call("ui_act", no_effect_within, .{ still_id, 400 });
        tw.churn(false);
        w.Sleep(150);
        const timed_out = !res.is_error and std.mem.indexOf(u8, res.text, "; settle timeout\n") != null;
        const observed = std.mem.indexOf(u8, res.text, "window=0x") != null or std.mem.indexOf(u8, res.text, test_window.churn_prefix) != null;
        if (timed_out and observed)
            report.ok("bg-settle-timeout", "a label rewritten every 15 ms: `settle timeout` after 400 ms, observation returned", .{})
        else
            report.fail("bg-settle-timeout", "`{s}`", .{res.text[0..@min(res.text.len, 200)]});
    }

    // bg-settle-reread: Windows refuses the event hook.
    {
        backend.refuse_events = true;
        const res = try caller.call("ui_act", no_effect, .{still_id});
        const floor = server.timings.get(.settle) / std.time.ns_per_ms;
        backend.refuse_events = false;
        // Hooked again for what follows.
        const again = try caller.call("ui_act", no_effect, .{still_id});
        const said = !res.is_error and std.mem.indexOf(u8, res.text, " ms (" ++ a11y.reread_note ++ ")\n") != null;
        const back = !again.is_error and std.mem.indexOf(u8, again.text, a11y.reread_note) == null;
        if (said and back and floor >= 200)
            report.ok("bg-settle-reread", "hook refused: settled on two identical reads of the tree in {d} ms, the result says `{s}`; hooked again afterwards", .{ floor, a11y.reread_note })
        else
            report.fail("bg-settle-reread", "refused: `{s}` after {d} ms; hooked again: `{s}`", .{ res.text[0..@min(res.text.len, 120)], floor, again.text[0..@min(again.text.len, 120)] });
    }

    // bg-events-cpu: the thread that receives the events, target at rest.
    cpu: {
        const events = backend.events orelse break :cpu report.fail("bg-events-cpu", "no event watcher: the hook was never installed", .{});
        const thread = events.threadHandle() orelse break :cpu report.fail("bg-events-cpu", "the watcher has no thread", .{});
        const per_us = selftest.cyclesPerUs();
        const seen = events.stamp();
        var c0: u64 = 0;
        var c1: u64 = 0;
        _ = w.QueryThreadCycleTime(thread, &c0);
        const t0 = qpcUs();
        w.Sleep(2000);
        _ = w.QueryThreadCycleTime(thread, &c1);
        const wall = qpcUs() - t0;
        const percent = @as(f64, @floatFromInt(c1 - c0)) / per_us * 100 / @as(f64, @floatFromInt(@max(wall, 1)));
        if (events.hooked and percent < 1)
            report.ok("bg-events-cpu", "event thread over 2 s with the target at rest: {d:.3} % of a core (budget 1 %), {d} event(s)", .{ percent, events.stamp() - seen })
        else
            report.fail("bg-events-cpu", "hooked {}, {d:.3} % of a core (budget 1 %), {d} event(s) in 2 s", .{ events.hooked, percent, events.stamp() - seen });
    }

    // bg-find-wait: a button that appears 800 ms into the wait, in the
    // covered target.
    {
        const before = b.begin() orelse return true;
        tw.lateButton(800);
        const t0 = qpcUs();
        const res = try caller.call("ui_find", "{{\"query\":\"{s}\",\"wait_ms\":5000}}", .{test_window.late_label});
        const ms = @as(i64, @intCast((qpcUs() - t0) / 1000));
        const captured = server.timings.get(.capture);
        const v = b.end(before);
        const found = !res.is_error and std.mem.startsWith(u8, res.text, "found after ") and std.mem.indexOf(u8, res.text, test_window.late_label) != null;
        var buf: [96]u8 = undefined;
        if (found and ms - 800 < 100 and ms >= 700 and captured == 0 and !v.any())
            report.ok("bg-find-wait", "button shown 800 ms into the wait: found {d} ms after it appeared (budget 100 ms), no capture, session unchanged", .{ms - 800})
        else
            report.fail("bg-find-wait", "answered after {d} ms, capture stage {d} ns, session: {s}; `{s}`", .{ ms, captured, v.text(&buf), res.text[0..@min(res.text.len, 160)] });
    }

    // bg-find-gone: the same button goes 300 ms into the wait.
    {
        const Later = struct {
            fn remove(win: *TestWindow) void {
                w.Sleep(300);
                win.removeLateButton();
            }
        };
        const before = b.begin() orelse return true;
        const th = try std.Thread.spawn(.{}, Later.remove, .{tw});
        const t0 = qpcUs();
        const res = try caller.call("ui_find", "{{\"query\":\"{s}\",\"wait_ms\":5000,\"gone\":true}}", .{test_window.late_label});
        const ms = @as(i64, @intCast((qpcUs() - t0) / 1000));
        th.join();
        const v = b.end(before);
        const bare = try caller.call("ui_find", "{{\"query\":\"{s}\",\"gone\":true}}", .{test_window.late_label});
        const went = !res.is_error and std.mem.startsWith(u8, res.text, "Plus aucun élément « " ++ test_window.late_label ++ " » après ");
        const needs_wait = bare.is_error and std.mem.eql(u8, bare.text, "gone demande wait_ms : la durée d'attente maximale.");
        var buf: [96]u8 = undefined;
        if (went and needs_wait and ms >= 250 and ms - 300 < 150 and !v.any())
            report.ok("bg-find-gone", "button removed 300 ms into the wait: `{s}`, answered {d} ms after it went; gone without wait_ms is refused", .{ res.text, ms - 300 })
        else
            report.fail("bg-find-gone", "after {d} ms `{s}`; without wait_ms `{s}`; session: {s}", .{ ms, res.text[0..@min(res.text.len, 120)], bare.text[0..@min(bare.text.len, 120)], v.text(&buf) });
    }

    // bg-find-wait-cpu: a 5 s wait on a still window of another process,
    // by a background server in a process of its own.
    selftest.stillWaitCheckIn(io, env, report, arena, "bg-find-wait-cpu", .{ .x = area.x + 640, .y = area.y + 120, .w = 480, .h = 320 }, "auto", "background");

    // bg-kill-ignore: 500 px of the user's mouse and their Escape key
    // during an action. Both go through the hook's own logic, as physical
    // input: no program can produce a physical event.
    {
        const Later = struct {
            fn run(k: *hooks.KillSwitch) void {
                w.Sleep(250);
                var i: u32 = 0;
                while (i < 10) : (i += 1) {
                    k.simulateMove(50, 0);
                    w.Sleep(5);
                }
                k.simulateKey(w.VK_ESCAPE, true);
                k.simulateKey(w.VK_ESCAPE, false);
            }
        };
        tw.churn(true);
        w.Sleep(150);
        const trips = ks.trips.load(.acquire);
        const consumed = ks.consumed.load(.monotonic);
        const th = try std.Thread.spawn(.{}, Later.run, .{ks});
        const t0 = qpcUs();
        const res = try caller.call("ui_act", no_effect_within, .{ still_id, 900 });
        const ms = (qpcUs() - t0) / 1000;
        th.join();
        w.Sleep(50);
        tw.churn(false);
        const completed = !res.is_error and std.mem.indexOf(u8, res.text, "; settle timeout\n") != null and ms >= 850;
        const quiet = !server.control.isPaused() and ks.trips.load(.acquire) == trips;
        const passed_on = ks.consumed.load(.monotonic) == consumed;
        if (completed and quiet and passed_on)
            report.ok("bg-kill-ignore", "a 500 px mouse move and Escape 250 ms into a {d} ms action: it ran to its end, server not paused, Escape passed on to the foreground application", .{ms})
        else
            report.fail("bg-kill-ignore", "action completed {} after {d} ms, paused {}, trips {d} -> {d}, keys consumed {d} -> {d}; `{s}`", .{ completed, ms, server.control.isPaused(), trips, ks.trips.load(.acquire), consumed, ks.consumed.load(.monotonic), res.text[0..@min(res.text.len, 120)] });
        // Never leave the server paused for what follows.
        if (server.control.isPaused()) _ = server.control.toggle();
    }

    // bg-kill-chord: the shortcut pauses during an action, then resumes.
    {
        const Press = struct {
            ks: *hooks.KillSwitch,
            control: *const control.Control,
            pressed_us: u64 = 0,
            paused_us: ?u64 = null,
            fn run(self: *@This()) void {
                w.Sleep(250);
                self.pressed_us = qpcUs();
                holdChord(self.ks);
                if (waitPaused(self.control, true, 1000)) self.paused_us = qpcUs() - self.pressed_us;
            }
        };
        tw.churn(true);
        w.Sleep(150);
        const consumed = ks.consumed.load(.monotonic);
        var press: Press = .{ .ks = ks, .control = &server.control };
        const th = try std.Thread.spawn(.{}, Press.run, .{&press});
        const res = try caller.call("ui_act", no_effect_within, .{ still_id, 5000 });
        const returned_us = qpcUs();
        th.join();
        tw.churn(false);
        const cancel_ms = if (returned_us > press.pressed_us) (returned_us - press.pressed_us) / 1000 else 0;
        const eaten = ks.consumed.load(.monotonic) - consumed;
        const cancelled = res.is_error and std.mem.eql(u8, res.text, control.paused_message);
        // Paused: an action is refused, an observation still answers.
        const refused = try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"scroll_into_view\",\"observe\":\"none\"}}", .{still_id});
        const tree = try caller.call("ui_tree", "{{}}", .{});
        const held = refused.is_error and std.mem.eql(u8, refused.text, control.paused_message) and !tree.is_error and server.control.isPaused();
        // The same shortcut resumes, and nothing else does.
        pressChord(ks);
        const resumed = waitPaused(&server.control, false, 500);
        const again = try caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"scroll_into_view\",\"observe\":\"none\"}}", .{still_id});
        const paused_ms = if (press.paused_us) |us| @as(f64, @floatFromInt(us)) / 1000 else -1;
        // The press, its repeats and the release of the key, all consumed.
        if (cancelled and press.paused_us != null and paused_ms < 100 and cancel_ms < 300 and eaten == held_downs + 1 and held and resumed and !again.is_error)
            report.ok("bg-kill-chord", "Ctrl+Alt+Shift+R held over {d} key repeats during an action: paused in {d:.1} ms (budget 100 ms) and still paused after the repeats, action cancelled {d} ms after the press with the pause message, the key consumed; paused: ui_act refused, ui_tree served; the same shortcut resumes", .{ held_downs - 1, paused_ms, cancel_ms })
        else
            report.fail("bg-kill-chord", "cancelled {} `{s}`, paused after {d:.1} ms, call back after {d} ms, key events consumed {d} (expected {d}), paused state held {}, resumed {}, action after `{s}`", .{ cancelled, res.text[0..@min(res.text.len, 80)], paused_ms, cancel_ms, eaten, held_downs + 1, held, resumed, again.text[0..@min(again.text.len, 80)] });
        if (server.control.isPaused()) _ = server.control.toggle();
    }

    if (try indicatorCheck(b, backend, server, still_id, no_effect_within)) return true;
    if (try guardCheck(b, server, decoy, ks, io, arena, area)) return true;
    try learnCheck(b, backend, still_id, no_effect);
    return false;
}

/// bg-events-learn (decision 0013, amendment of 2026-11-13): the server
/// subscribes to the UI Automation events of an application once its tree
/// changed twice without a change event, and drops the subscription when it
/// brings none. The label of the test window changes without reporting it,
/// as a Win32 STATIC does; each change is seen by the observation of an
/// action without effect.
fn learnCheck(b: *Bench, backend: *Windows, still_id: []const u8, comptime no_effect: []const u8) !void {
    const name = "bg-events-learn";
    const report = b.report;
    const pid = w.GetCurrentProcessId();
    // What the controls before left: nothing learned, the hooks in place,
    // the tree as last shown.
    backend.learned = @splat(.{});
    _ = try b.caller.call("ui_act", no_effect, .{still_id});
    // Enough changes for both steps: the tree that follows a step only
    // starts the next comparison.
    const changes = 2 * Windows.blind_hits + 2;
    var listening_at: ?usize = null;
    var deaf_at: ?usize = null;
    var subscribed_when_listening = false;
    var subscribed_when_deaf = true;
    var unseen: u32 = 0;
    // UI Automation events the label's change raised by itself, and those
    // of the action that follows, once the handlers are in place.
    var of_label: u64 = 0;
    var of_action: u64 = 0;
    for (1..changes + 1) |i| {
        const c0 = uia_events.count.load(.acquire);
        b.tw.silentChange();
        w.Sleep(120);
        const c1 = uia_events.count.load(.acquire);
        const res = try b.caller.call("ui_act", no_effect, .{still_id});
        of_label += c1 - c0;
        of_action += uia_events.count.load(.acquire) - c1;
        if (std.mem.indexOf(u8, res.text, test_window.churn_prefix) == null) unseen += 1;
        const on = backend.uia_listening and backend.uia_window == b.hwnd;
        switch (backend.learnedState(pid)) {
            .unknown => {},
            .listening => if (listening_at == null) {
                listening_at = i;
                subscribed_when_listening = on;
            },
            .deaf => if (deaf_at == null) {
                deaf_at = i;
                subscribed_when_deaf = on;
            },
        }
    }
    const last = backend.learnedState(pid);
    // A change the window reports leaves what was learned alone.
    b.tw.churn(true);
    w.Sleep(60);
    b.tw.churn(false);
    w.Sleep(120);
    _ = try b.caller.call("ui_act", no_effect, .{still_id});
    const after = backend.learnedState(pid);
    const learned = listening_at != null and listening_at.? == Windows.blind_hits and subscribed_when_listening;
    // The handlers either report the label's changes, and the subscription
    // stays, or they do not, and it is dropped.
    const dropped = deaf_at != null and !subscribed_when_deaf and of_label == 0;
    const kept = deaf_at == null and of_label > 0 and last == .listening;
    if (unseen == 0 and learned and (dropped or kept) and after == last) {
        if (dropped)
            report.ok(name, "a label that changes without a change event: after {d} such changes the server subscribed to the window's UI Automation events; they reported none of the next ones (0 event from the label, {d} from the actions) and the subscription was dropped for good at change {d}; a change the window reports changed nothing", .{ Windows.blind_hits, of_action, deaf_at.? })
        else
            report.ok(name, "a label that changes without a change event: after {d} such changes the server subscribed to the window's UI Automation events, which report the next ones ({d} events) and stay; a change the window reports changed nothing", .{ Windows.blind_hits, of_label });
    } else report.fail(name, "{d} change(s) absent from the observation; subscribed at change {?d} (handlers in place: {}), dropped at change {?d} (handlers still in place: {}); {d} UI Automation event(s) from the label, {d} from the actions; state {t}, {t} after a reported change", .{ unseen, listening_at, subscribed_when_listening, deaf_at, subscribed_when_deaf, of_label, of_action, last, after });
    // The rest of the selftest runs as before this control.
    backend.learned = @splat(.{});
    _ = backend.uiaWatch(0);
    backend.uia_window = 0;
    backend.uia_listening = false;
}

/// bg-indicator (US-046): the label alone, on the primary display, shown
/// during an action and one second after it; the pause label while paused.
fn indicatorCheck(b: *Bench, backend: *Windows, server: *bg.Server, still_id: []const u8, comptime no_effect_within: []const u8) !bool {
    const report = b.report;
    const ks = backend.kill.?;
    const ind = backend.indicator orelse {
        report.fail("bg-indicator", "the indicator did not start (see stderr)", .{});
        return false;
    };
    if (!ind.ready(2000)) {
        report.fail("bg-indicator", "its window was not built (see stderr)", .{});
        return false;
    }
    // Hidden again after the action before this control.
    var waited: u32 = 0;
    while (ind.current() != .hidden and waited < 2000) : (waited += 20) w.Sleep(20);
    var hbuf: [display.max_displays * 5]w.HWND = undefined;
    const hwnds = ind.windows(&hbuf);
    if (hwnds.len != 1) {
        report.fail("bg-indicator", "{d} indicator windows, expected the label alone", .{hwnds.len});
        return false;
    }
    const label = hwnds[0];
    var affinity: u32 = 0;
    const excluded = w.GetWindowDisplayAffinity(label, &affinity) != 0 and affinity == w.WDA_EXCLUDEFROMCAPTURE;
    const ex: usize = @bitCast(w.GetWindowLongPtrW(label, w.GWL_EXSTYLE));
    const passive = ex & w.WS_EX_TRANSPARENT != 0 and ex & w.WS_EX_NOACTIVATE != 0;
    var r: w.RECT = undefined;
    _ = w.GetWindowRect(label, &r);
    // Index 0 is the primary display.
    const primary = backend.displays()[0].rect;
    const on_primary = r.left >= primary.x and r.right <= primary.right() and r.top >= primary.y and r.bottom <= primary.bottom();

    const Sample = struct {
        ind: *const @import("indicator.zig").Indicator,
        label: w.HWND,
        look: core_indicator.Look = .hidden,
        visible: bool = false,
        fn run(self: *@This()) void {
            w.Sleep(300);
            self.look = self.ind.current();
            self.visible = w.IsWindowVisible(self.label) != 0;
        }
    };
    b.tw.churn(true);
    w.Sleep(150);
    var sample: Sample = .{ .ind = ind, .label = label };
    const before = b.begin() orelse return true;
    const th = try std.Thread.spawn(.{}, Sample.run, .{&sample});
    _ = try b.caller.call("ui_act", no_effect_within, .{ still_id, 700 });
    const ended = selftest.qpcUs();
    th.join();
    const after = ind.current();
    const v = b.end(before);
    b.tw.churn(false);
    waited = 0;
    while (ind.current() != .hidden and waited < 3000) : (waited += 10) w.Sleep(10);
    const gone_ms = (selftest.qpcUs() - ended) / 1000;
    // Paused, the existing pause label; the shortcut hides it.
    pressChord(ks);
    _ = waitPaused(&server.control, true, 500);
    w.Sleep(100);
    const paused_look = ind.current();
    pressChord(ks);
    _ = waitPaused(&server.control, false, 500);
    if (server.control.isPaused()) _ = server.control.toggle();

    var buf: [96]u8 = undefined;
    var lbuf: [128]u8 = undefined;
    const lingered = gone_ms >= 800 and gone_ms < 1800;
    if (excluded and passive and on_primary and sample.look == .acting and sample.visible and after == .acting and lingered and paused_look == .paused and !v.any())
        report.ok("bg-indicator", "one window, the label `{s}` on the primary display, no frame strip: shown during the action, hidden {d} ms after its end, pause label while paused; excluded from capture, click-through, never activated, session unchanged", .{ core_indicator.backgroundLabel(&lbuf, control.default_rearm), gone_ms })
    else
        report.fail("bg-indicator", "excluded {}, click-through and no-activate {}, on the primary display {}, during the action {t} visible {}, right after {t}, hidden after {d} ms, paused look {t}, session: {s}", .{ excluded, passive, on_primary, sample.look, sample.visible, after, gone_ms, paused_look, v.text(&buf) });

    // bg-indicator-refused: a label Windows will not build (as when it
    // refuses the capture exclusion) is not shown at all, and actions run.
    {
        backend.stopIndicator();
        backend.refuse_indicator = true;
        backend.startIndicator(&server.control, control.default_rearm);
        backend.refuse_indicator = false;
        const refused = backend.indicator;
        const built = if (refused) |ind2| ind2.ready(2000) else false;
        var rbuf: [display.max_displays * 5]w.HWND = undefined;
        const left = if (refused) |ind2| ind2.windows(&rbuf).len else 0;
        const res = try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"scroll_into_view\",\"observe\":\"none\"}}", .{still_id});
        if (refused != null and !built and refused.?.failed.load(.acquire) and left == 0 and !res.is_error)
            report.ok("bg-indicator-refused", "label refused: logged, no window left, ui_act `{s}`", .{res.text})
        else
            report.fail("bg-indicator-refused", "built {}, windows {d}, ui_act `{s}`", .{ built, left, res.text });
        // The label again for what follows.
        backend.stopIndicator();
        backend.startIndicator(&server.control, control.default_rearm);
    }
    return false;
}

/// Repetitions of `bg-guard-restore` (PRD, reliability: the foreground is
/// given back on at least 95 % of 100).
const guard_reps = 100;

/// The popup application of another process, under the decoy, and the id
/// of its button.
const Popup = struct {
    hwnd: w.HWND,
    pid: u32,
    open: []const u8,

    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    fn dialogOpen() bool {
        return w.FindWindowW(L(popup_window.dialog_class_name), null) != null;
    }

    fn closeDialog(self: Popup) void {
        _ = w.PostMessageW(self.hwnd, popup_window.msg_close_dialog, 0, 0);
        var waited: u32 = 0;
        while (dialogOpen() and waited < 1000) : (waited += 10) w.Sleep(10);
    }
};

/// The user types: a letter and Enter, as the keyboard sends them.
fn typeKeys(ks: *hooks.KillSwitch) void {
    for ([_]u16{ 'A', w.VK_RETURN }) |vk| {
        ks.simulateKey(vk, true);
        ks.simulateKey(vk, false);
    }
}

/// The foreground guard (US-050; decision 0013, amendment of 2026-11-13),
/// on an application of another process whose buttons open a dialog that
/// takes the foreground. The decoy, in front, grants that process the right
/// once per action, as Windows does for an application the user just used.
/// `bg-guard-restore`: the foreground is given back, from the event thread,
/// while the user types. `bg-guard-user`: a gesture of the user that can
/// change the foreground window leaves it alone.
fn guardCheck(b: *Bench, server: *bg.Server, decoy: *const Decoy, ks: *hooks.KillSwitch, io: std.Io, arena: std.mem.Allocator, area: display.Rect) !bool {
    const report = b.report;
    const name = "bg-guard-restore";
    var path: [3 * 1024]u8 = undefined;
    const exe = fixture.selfPath(&path);
    var xbuf: [16]u8 = undefined;
    var ybuf: [16]u8 = undefined;
    const argv = [_][]const u8{ exe, "selftest-popup", try std.fmt.bufPrint(&xbuf, "{d}", .{area.x + 640}), try std.fmt.bufPrint(&ybuf, "{d}", .{area.y + 140}) };
    var child = std.process.spawn(io, .{ .argv = &argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        report.fail(name, "cannot start {s} selftest-popup: {t}", .{ exe, err });
        return false;
    };
    defer child.kill(io);
    var hwnd: w.HWND = null;
    var waited: u32 = 0;
    while (hwnd == null and waited < 3000) : (waited += 20) {
        hwnd = w.FindWindowW(Popup.L(popup_window.class_name), null);
        if (hwnd == null) w.Sleep(20);
    }
    if (hwnd == null) {
        report.fail(name, "no selftest-popup window after 3 s", .{});
        return false;
    }
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    if (!decoy.front()) return true;
    decoy.tuck(hwnd);
    w.Sleep(200);
    const tree = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{@intFromPtr(hwnd)});
    const popup: Popup = .{
        .hwnd = hwnd,
        .pid = pid,
        .open = Bench.idIn(tree.text, "button \"" ++ popup_window.button_label ++ "\"") orelse "",
    };
    if (popup.open.len == 0) {
        report.fail(name, "no button in the popup's tree: {s}", .{tree.text[0..@min(tree.text.len, 200)]});
        return false;
    }
    const invoke = "{{\"id\":\"{s}\",\"action\":\"invoke\"}}";

    var restored: u32 = 0;
    var early: u32 = 0;
    var refused: u32 = 0;
    var user: u32 = 0;
    var missed: u32 = 0;
    var violations: u32 = 0;
    var worst_ns: u64 = 0;
    var exposed_ns: u64 = 0;
    var seen: u8 = 0;
    var line: []const u8 = "";
    var miss: []const u8 = "";
    const sends = input.send_calls.load(.monotonic);
    var n: u32 = 0;
    while (n < guard_reps) : (n += 1) {
        if (!decoy.front()) return true;
        w.Sleep(60);
        if (!fixture.above(decoy.hwnd, hwnd)) decoy.tuck(hwnd);
        // After the decoy's own input, which would withdraw the grant.
        const granted = decoy.allow(pid);
        const before = State.sample(b.ks);
        // The user keeps typing in their own window: no reason to leave
        // the dialog in front, and every reason not to.
        typeKeys(ks);
        const res = try b.caller.call("ui_act", invoke, .{popup.open});
        const watch = server.last_guard;
        w.Sleep(30);
        const v = Violation.of(before, State.sample(b.ks));
        const took = std.mem.indexOf(u8, res.text, "\nPremier plan pris par ") != null;
        if (took and std.mem.indexOf(u8, res.text, ", rendu à ") != null and w.GetForegroundWindow() == decoy.hwnd) {
            restored += 1;
            if (watch.early) early += 1;
            worst_ns = @max(worst_ns, watch.restore_ns);
            exposed_ns = @max(exposed_ns, watch.exposed_ns);
            if (line.len == 0) line = try arena.dupe(u8, res.text[std.mem.lastIndexOfScalar(u8, res.text, '\n').? + 1 ..]);
            if (v.any()) {
                violations += 1;
                seen |= @as(u8, @bitCast(v));
            }
        } else if (took) {
            refused += 1;
        } else if (std.mem.indexOf(u8, res.text, "entrée de l'utilisateur") != null) {
            user += 1;
        } else {
            missed += 1;
            if (miss.len == 0) miss = try std.fmt.allocPrint(arena, "grant {}, dialog {}, `{s}`", .{ granted, Popup.dialogOpen(), res.text[0..@min(res.text.len, 160)] });
        }
        popup.closeDialog();
    }
    const injected = input.send_calls.load(.monotonic) - sends;
    const worst_ms = @as(f64, @floatFromInt(worst_ns)) / std.time.ns_per_ms;
    const exposed_ms = @as(f64, @floatFromInt(exposed_ns)) / std.time.ns_per_ms;
    var vbuf: [96]u8 = undefined;
    if (restored * 100 >= guard_reps * 95 and early * 100 >= guard_reps * 95 and exposed_ms < 200 and injected == 0 and violations == 0)
        report.ok(name, "a dialog of another process took the foreground on {d} of {d} actions while the user typed, and the decoy got it back on {d}, with its focus (`{s}`), {d} times from the foreground event before the action ended: in front {d:.1} ms at most from its event to the end of the restoration (budget 200 ms), the restoration itself {d:.1} ms, 0 SendInput call", .{ restored + refused, guard_reps, restored, line, early, exposed_ms, worst_ms })
    else
        report.fail(name, "{d} restored ({d} from the foreground event), {d} refused by Windows, {d} left to the user, {d} where the dialog did not come in front ({s}) on {d}; in front up to {d:.1} ms, slowest restoration {d:.1} ms; {d} SendInput call(s); {d} with the session changed ({s})", .{ restored, early, refused, user, missed, miss, guard_reps, exposed_ms, worst_ms, injected, violations, @as(Violation, @bitCast(seen)).text(&vbuf) });

    // bg-guard-user: what the user does to change window themselves. Each
    // gesture goes through the hook's own logic, as physical input.
    {
        var taskbar: w.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const tray = w.FindWindowW(Popup.L("Shell_TrayWnd"), null);
        if (tray != null) _ = w.GetWindowRect(tray, &taskbar);
        var home: w.RECT = undefined;
        _ = w.GetWindowRect(decoy.hwnd, &home);
        const Gesture = enum { alt_tab, click_away, click_home };
        var left: [3]u32 = .{ 0, 0, 0 };
        var back: [3]u32 = .{ 0, 0, 0 };
        var first: []const u8 = "";
        const reps = 2;
        for ([_]Gesture{ .alt_tab, .click_away, .click_home }, 0..) |g, i| {
            var r: u32 = 0;
            while (r < reps) : (r += 1) {
                // Past the slack of the gesture before.
                w.Sleep(600);
                if (!decoy.front()) return true;
                w.Sleep(60);
                if (!fixture.above(decoy.hwnd, hwnd)) decoy.tuck(hwnd);
                _ = decoy.allow(pid);
                switch (g) {
                    .alt_tab => {
                        ks.simulateKey(w.VK_LMENU, true);
                        ks.simulateKey(w.VK_TAB, true);
                        ks.simulateKey(w.VK_TAB, false);
                        ks.simulateKey(w.VK_LMENU, false);
                    },
                    .click_away => ks.simulateClick(.{ @divTrunc(taskbar.left + taskbar.right, 2), @divTrunc(taskbar.top + taskbar.bottom, 2) }),
                    // Inside the decoy, away from the popup under it.
                    .click_home => ks.simulateClick(.{ home.left + 200, home.bottom - 60 }),
                }
                // The hook thread reads the gesture before the action.
                w.Sleep(30);
                const res = try b.caller.call("ui_act", invoke, .{popup.open});
                w.Sleep(30);
                const kept = std.mem.indexOf(u8, res.text, "\nPremier plan changé pendant l'action (entrée de l'utilisateur) : non restauré") != null and w.GetForegroundWindow() != decoy.hwnd;
                const returned = std.mem.indexOf(u8, res.text, ", rendu à ") != null and w.GetForegroundWindow() == decoy.hwnd;
                if (kept) left[i] += 1;
                if (returned) back[i] += 1;
                if (first.len == 0 and !kept and !returned) first = try std.fmt.allocPrint(arena, "{t}: `{s}`", .{ g, res.text[0..@min(res.text.len, 160)] });
                popup.closeDialog();
            }
        }
        w.Sleep(600);
        if (!decoy.front()) return true;
        if (left[0] == reps and left[1] == reps and back[2] == reps)
            report.ok("bg-guard-user", "Alt+Tab, then a click on the taskbar, while the dialog comes in front: left there {d} times of {d}, `entrée de l'utilisateur`; a click inside the user's own window: given back {d} times of {d}", .{ left[0] + left[1], 2 * reps, back[2], reps })
        else
            report.fail("bg-guard-user", "left in front after Alt+Tab {d}/{d}, after a click on the taskbar {d}/{d}; given back after a click in the user's own window {d}/{d}; {s}", .{ left[0], reps, left[1], reps, back[2], reps, first });
    }

    // bg-guard-late: without observation Invoke returns at once, and the
    // dialog comes in front when no tool runs any more. The guard left
    // armed sends it back, and the next call says so.
    {
        const quiet = "{{\"id\":\"{s}\",\"action\":\"invoke\",\"observe\":\"none\"}}";
        const reps = 5;
        var late: u32 = 0;
        var during: u32 = 0;
        var said: u32 = 0;
        var exposed: u64 = 0;
        var first: []const u8 = "";
        for (0..reps) |_| {
            if (!decoy.front()) return true;
            w.Sleep(60);
            if (!fixture.above(decoy.hwnd, hwnd)) decoy.tuck(hwnd);
            _ = decoy.allow(pid);
            typeKeys(ks);
            const res = try b.caller.call("ui_act", quiet, .{popup.open});
            const in_result = std.mem.indexOf(u8, res.text, ", rendu à ") != null;
            w.Sleep(400);
            const opened = Popup.dialogOpen();
            const home = w.GetForegroundWindow() == decoy.hwnd;
            // Any call ends the guard's stay and carries its line.
            const next = try b.caller.call("window_list", "{{}}", .{});
            const watch = server.linger;
            const told = std.mem.indexOf(u8, next.text, " après l'action précédente, rendu à ") != null;
            if (in_result and home) {
                during += 1;
            } else if (opened and home and watch.restores > 0) {
                late += 1;
                exposed = @max(exposed, watch.exposed_ns);
                if (told) said += 1;
            } else if (first.len == 0) first = try std.fmt.allocPrint(arena, "dialog open {}, decoy in front {}, {d} restoration(s), `{s}` then `{s}`", .{ opened, home, watch.restores, res.text[0..@min(res.text.len, 80)], next.text[0..@min(next.text.len, 80)] });
            popup.closeDialog();
        }
        if (!decoy.front()) return true;
        const late_ms = @as(f64, @floatFromInt(exposed)) / std.time.ns_per_ms;
        if (late + during == reps and late > 0 and said == late and late_ms < 200)
            report.ok("bg-guard-late", "Invoke without observation returned before its dialog came in front on {d} of {d} actions: the guard left armed gave the foreground back each time, the dialog in front {d:.1} ms at most (budget 200 ms), and the next call said `Premier plan pris par … après l'action précédente, rendu à …`; on {d} the dialog came during the action", .{ late, reps, late_ms, during })
        else
            report.fail("bg-guard-late", "{d} given back after the action ({d} said by the next call), {d} during it, of {d}; in front up to {d:.1} ms; {s}", .{ late, said, during, reps, late_ms, first });
    }

    return false;
}
