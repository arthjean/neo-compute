//! `neo-compute events-probe [TARGET...]` (US-047, assumption A18): do the
//! WinEvents of a window's process report the changes of its tree while the
//! window is not active and lies under another one? A decoy window of
//! another process holds the foreground; on each target (the selftest
//! window, then the reference applications the probe opens itself) 20
//! actions run through their UI Automation patterns (Invoke, Toggle,
//! ValuePattern.SetValue, Expand). For each action that changed the tree
//! (two snapshots compared) the probe notes whether an event of the target's
//! process arrived within 200 ms, and after how long. The events are the
//! ones the server's own watcher receives (`winevents.zig`): out of context,
//! filtered by process.
//!
//! The same run measures the UI Automation events of the target window
//! (`uia_events.zig`; decision 0013, amendment of 2026-11-13): handlers on
//! the window's element and its subtree, registered after a first series of
//! actions without them and removed again, over two rounds, so that what
//! the subscription costs the target shows (processor cycles of its
//! process per action, on the same actions, and at rest). Each measured
//! action notes both sources.
//!
//! Targets: `window`, `notepad`, `calculator`, `settings`, `explorer`,
//! `chrome`, `vscode`; none means all. `churn`, by name only, times the
//! removal of the handlers after the watched window was hidden, minimized,
//! opened dialogs or closed. Lines go to stderr. No element name is
//! printed: a step is named by its pattern.

const std = @import("std");
const w = @import("win32");
const Windows = @import("../windows.zig").Windows;
const uitree = @import("../../core/uitree.zig");
const display = @import("../../core/display.zig");
const winevents = @import("winevents.zig");
const uia_events = @import("uia_events.zig");
const window = @import("window.zig");
const popup_window = @import("popup_window.zig");
const fixture = @import("bg_fixture.zig");
const test_window = @import("test_window.zig");
const bg = @import("bg_probe.zig");
const TestWindow = test_window.TestWindow;
const Decoy = fixture.Decoy;

/// Actions per target (PRD, US-047).
const actions_per_target = 20;
/// Actions without the UI Automation handlers: what an action costs the
/// target without them. The same actions are then repeated with them.
const plain_actions = 10;
/// Rounds the two series alternate over.
const blocks = 2;
/// An event this soon after the action signals the change.
const signal_ms = 200;
/// How long the events of an action are collected, and the tree left to
/// change, before the second snapshot.
const observe_ms = 500;
const idle_ms = 3000;
/// A source holds for an application when this share of its tree changes is
/// signaled.
const threshold_percent = 95;

/// One change source over the measured actions of a target.
const Signal = struct {
    signaled: u32 = 0,
    /// First event after each tree change, microseconds.
    delays: [actions_per_target]u64 = undefined,
    delays_len: usize = 0,
    idle_per_s: f64 = 0,

    fn rate(s: *const Signal, changed: u32) f64 {
        return @as(f64, @floatFromInt(s.signaled)) * 100 / @as(f64, @floatFromInt(changed));
    }

    fn sorted(s: *Signal) []const u64 {
        const d = s.delays[0..s.delays_len];
        std.mem.sort(u64, d, {}, std.sort.asc(u64));
        return d;
    }
};

const Stat = struct {
    target: []const u8,
    actions: u32 = 0,
    changed: u32 = 0,
    /// Tree changes one source or the other signaled.
    either: u32 = 0,
    /// The tree could not be read after the action.
    unreadable: u32 = 0,
    win: Signal = .{},
    uia: Signal = .{},
    hooked: bool = true,
    subscribed: bool = false,
    add_ms: f64 = 0,
    remove_ms: f64 = 0,
    /// Processor cycles of the target's process: per action without and
    /// with the handlers, and per second at rest.
    plain_cycles: u64 = 0,
    plain_count: u32 = 0,
    /// The actions with the handlers that repeat those without.
    paired_cycles: u64 = 0,
    paired_count: u32 = 0,
    idle_plain_cycles: u64 = 0,
    idle_uia_cycles: u64 = 0,
};

fn qpc() i64 {
    var t: i64 = 0;
    _ = w.QueryPerformanceCounter(&t);
    return t;
}

fn usSince(from: i64, to: i64) i64 {
    var f: i64 = 1;
    _ = w.QueryPerformanceFrequency(&f);
    return @divTrunc((to - from) * 1_000_000, f);
}

fn cycles(process: w.HANDLE) u64 {
    var c: u64 = 0;
    if (process != null) _ = w.QueryProcessCycleTime(process, &c);
    return c;
}

fn mega(c: u64) f64 {
    return @as(f64, @floatFromInt(c)) / 1_000_000;
}

fn measured(action: uitree.Action) bool {
    return switch (action) {
        .invoke, .toggle, .set_value, .expand => true,
        else => false,
    };
}

/// The events of one source during one action.
const Seen = struct {
    total: usize = 0,
    within: u32 = 0,
    first_us: ?u64 = null,
    ids: [6]u32 = undefined,
    ids_len: usize = 0,

    fn scan(log: []const winevents.Event, from: usize, to: usize, t0: i64) Seen {
        var seen: Seen = .{ .total = to - from };
        var i = from;
        while (i < to) : (i += 1) {
            const e = log[i % log.len];
            const us: u64 = @intCast(@max(usSince(t0, e.qpc), 0));
            if (seen.first_us == null) seen.first_us = us;
            if (us <= signal_ms * 1000) seen.within += 1;
            const known = std.mem.indexOfScalar(u32, seen.ids[0..seen.ids_len], e.id) != null;
            if (!known and seen.ids_len < seen.ids.len) {
                seen.ids[seen.ids_len] = e.id;
                seen.ids_len += 1;
            }
        }
        return seen;
    }

    fn first(seen: *const Seen, buf: []u8) []const u8 {
        const us = seen.first_us orelse return "none";
        return std.fmt.bufPrint(buf, "{d}.{d} ms", .{ us / 1000, us % 1000 / 100 }) catch "?";
    }

    fn idText(seen: *const Seen, buf: []u8, comptime hex: bool) []const u8 {
        var iw: std.Io.Writer = .fixed(buf);
        for (seen.ids[0..seen.ids_len]) |id| iw.print(if (hex) " 0x{x}" else " {d}", .{id}) catch {};
        return iw.buffered();
    }

    fn tally(seen: *const Seen, sig: *Signal) void {
        if (seen.within > 0) sig.signaled += 1;
        if (seen.first_us) |us| {
            sig.delays[sig.delays_len] = us;
            sig.delays_len += 1;
        }
    }
};

const Run = struct {
    p: *bg.Probe,
    ev: *winevents.Watcher,
    s: *Stat,
    hwnd: u64,
    kinds: []const bg.Step,
    tw: ?*TestWindow,
    process: w.HANDLE,
    round: usize = 0,
    /// Measured actions left that repeat the block without the handlers.
    paired_left: u32 = 0,

    /// `n` actions. `full`: both sources and the tree are measured;
    /// otherwise only what the action costs the target. False when the run
    /// must stop.
    fn pass(r: *Run, n: u32, full: bool) bool {
        const p = r.p;
        const s = r.s;
        const hwnd = r.hwnd;
        var done: u32 = 0;
        var missing_in_a_row: usize = 0;
        while (done < n and missing_in_a_row < r.kinds.len) : (r.round += 1) {
            if (w.IsWindow(@ptrFromInt(hwnd)) == 0) return false;
            const step = r.kinds[r.round % r.kinds.len];
            _ = p.scratch.reset(.retain_capacity);
            const els = p.snapshot(hwnd) orelse {
                // What the step before left open closes when the decoy takes
                // the foreground back.
                _ = p.decoy.front();
                w.Sleep(300);
                missing_in_a_row += 1;
                continue;
            };
            const el = bg.find(els, step.pick, step.action) orelse {
                missing_in_a_row += 1;
                continue;
            };
            missing_in_a_row = 0;
            const hash = bg.treeHash(els);
            if (!p.decoy.front()) {
                p.lost = true;
                p.print("the decoy cannot take the foreground back: run stopped", .{});
                return false;
            }
            w.Sleep(200);
            const covered = p.decoy.covers(@ptrFromInt(hwnd));
            const win_from = r.ev.log_len.load(.acquire);
            const uia_from = uia_events.log_len.load(.acquire);
            const c0 = cycles(r.process);
            const t0 = qpc();
            const result = bg.patternCall(p.backend, p.scratch.allocator(), hwnd, el.key, step.action, step.value);
            w.Sleep(observe_ms);
            const spent = cycles(r.process) -| c0;
            done += 1;
            if (full) {
                const win: Seen = .scan(r.ev.log.?, win_from, r.ev.log_len.load(.acquire), t0);
                const uia: Seen = .scan(uia_events.log.?, uia_from, uia_events.log_len.load(.acquire), t0);
                const after = p.snapshot(hwnd);
                const changed: ?bool = if (after) |a| bg.treeHash(a) != hash else null;
                s.actions += 1;
                if (r.paired_left > 0) {
                    r.paired_left -= 1;
                    s.paired_cycles += spent;
                    s.paired_count += 1;
                }
                if (changed) |c| {
                    if (c) {
                        s.changed += 1;
                        win.tally(&s.win);
                        uia.tally(&s.uia);
                        if (win.within > 0 or uia.within > 0) s.either += 1;
                    }
                } else s.unreadable += 1;
                var b1: [32]u8 = undefined;
                var b2: [32]u8 = undefined;
                var b3: [96]u8 = undefined;
                var b4: [96]u8 = undefined;
                p.print("{s} | {s} #{d} | call: {s} | tree changed: {s} | WinEvents within {d} ms: {d} of {d}, first after {s}, ids:{s} | UIA events within {d} ms: {d} of {d}, first after {s}, ids:{s} | target {d:.1} Mcycles | covered: {s}", .{
                    r.s.target,                                                    step.label,             s.actions,
                    switch (result) {
                        .ok => "ok",
                        .timeout => "UIA timeout",
                        .failed => "failed",
                        else => "refused",
                    },
                    if (changed) |c| (if (c) "yes" else "no") else "not readable", signal_ms,              win.within,
                    win.total,                                                     win.first(&b1),         win.idText(&b3, true),
                    signal_ms,                                                     uia.within,             uia.total,
                    uia.first(&b2),                                                uia.idText(&b4, false), mega(spent),
                    if (covered) "yes" else "no",
                });
            } else {
                s.plain_cycles += spent;
                s.plain_count += 1;
            }
            // The state back, unmeasured: the next measure starts 400 ms later.
            if (step.undo) |u| {
                bg.undo(p, hwnd, u);
            } else if (step.action == .expand) {
                bg.undo(p, hwnd, .{ .action = .collapse, .pick = step.pick });
            }
            if (r.tw) |t| if (t.comboDropped()) t.closeCombo();
            w.Sleep(400);
        }
        return true;
    }
};

fn measure(p: *bg.Probe, ev: *winevents.Watcher, stats: *std.ArrayList(Stat), target: []const u8, hwnd: u64, steps: []const bg.Step, tw: ?*TestWindow) void {
    var s: Stat = .{ .target = target };
    defer stats.append(p.gpa, s) catch {};
    if (p.backend.windowEvents(hwnd) == null) {
        s.hooked = false;
        p.print("{s} | SetWinEventHook refused for the target's process: not measured", .{target});
        return;
    }
    // The backend's count adds the UI Automation events: the WinEvents
    // alone are read from the watcher.
    const first = ev.stamp();
    const pid = window.appPid(hwnd) orelse 0;
    const process: w.HANDLE = if (pid != 0) w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) else null;
    defer if (process != null) {
        _ = w.CloseHandle(process);
    };
    // At rest: nothing acts on the target for 3 s.
    var c0 = cycles(process);
    w.Sleep(idle_ms);
    s.idle_plain_cycles = cycles(process) -| c0;
    s.win.idle_per_s = @as(f64, @floatFromInt(ev.stamp() - first)) * 1000 / idle_ms;
    p.print("{s} | at rest without UIA handlers: {d:.1} WinEvents/s, target {d:.1} Mcycles/s over {d} ms", .{ target, s.win.idle_per_s, mega(s.idle_plain_cycles) * 1000 / idle_ms, idle_ms });

    var kinds: [16]bg.Step = undefined;
    var kinds_len: usize = 0;
    for (steps) |step| if (measured(step.action) and kinds_len < kinds.len) {
        kinds[kinds_len] = step;
        kinds_len += 1;
    };
    if (kinds_len == 0) return;
    var run_state: Run = .{ .p = p, .ev = ev, .s = &s, .hwnd = hwnd, .kinds = kinds[0..kinds_len], .tw = tw, .process = process };
    // Two rounds, so that neither series is always the first: a block
    // without the handlers, then the same actions with them and as many
    // more.
    for (0..blocks) |block| {
        const from = run_state.round;
        if (!run_state.pass(plain_actions / blocks, false)) return;
        var t0 = qpc();
        s.subscribed = p.backend.uiaWatch(hwnd);
        s.add_ms = @max(s.add_ms, @as(f64, @floatFromInt(usSince(t0, qpc()))) / 1000);
        if (s.subscribed and block == 0) {
            const before = uia_events.count.load(.acquire);
            c0 = cycles(process);
            w.Sleep(idle_ms);
            s.idle_uia_cycles = cycles(process) -| c0;
            s.uia.idle_per_s = @as(f64, @floatFromInt(uia_events.count.load(.acquire) - before)) * 1000 / idle_ms;
            p.print("{s} | UIA handlers registered in {d:.1} ms; at rest with them: {d:.1} UIA events/s, target {d:.1} Mcycles/s over {d} ms", .{ target, s.add_ms, s.uia.idle_per_s, mega(s.idle_uia_cycles) * 1000 / idle_ms, idle_ms });
        } else if (!s.subscribed) p.print("{s} | UIA handlers refused after {d:.1} ms (hr=0x{x}): WinEvents alone are measured", .{ target, s.add_ms, @import("com.zig").lastHr() });
        run_state.round = from;
        run_state.paired_left = plain_actions / blocks;
        const more = run_state.pass(actions_per_target / blocks, true);
        if (s.subscribed) {
            t0 = qpc();
            _ = p.backend.uiaWatch(0);
            s.remove_ms = @max(s.remove_ms, @as(f64, @floatFromInt(usSince(t0, qpc()))) / 1000);
        }
        if (!more) break;
    }
    if (s.plain_count > 0 and s.paired_count > 0) p.print("{s} | target per action, the same {d} actions: {d:.1} Mcycles without the UIA handlers, {d:.1} with them; handlers added in {d:.1} ms at most, removed in {d:.1} ms", .{
        target,
        s.plain_count,
        mega(s.plain_cycles) / @as(f64, @floatFromInt(s.plain_count)),
        mega(s.paired_cycles) / @as(f64, @floatFromInt(s.paired_count)),
        s.add_ms,
        s.remove_ms,
    });
    if (s.actions == 0) p.print("{s} | no element for Invoke, Toggle, SetValue or Expand in the target's tree: not measured", .{target});
}

fn percentile(sorted: []const u64, p: usize) u64 {
    if (sorted.len == 0) return 0;
    return sorted[@min(sorted.len - 1, (sorted.len * p + 99) / 100 -| 1)];
}

fn summary(p: *bg.Probe, stats: []Stat) void {
    p.print("summary | target | actions | tree changed | WinEvents within {d} ms | UIA events within {d} ms | either | WinEvents first median / p95 | UIA first median / p95 | at rest WinEvents/s, UIA events/s | handlers added, removed | target Mcycles per action without, with (the same actions) | target Mcycles/s at rest without, with", .{ signal_ms, signal_ms });
    var win_failed: usize = 0;
    var uia_failed: usize = 0;
    var uia_counted: usize = 0;
    var counted: usize = 0;
    for (stats) |*s| {
        if (!s.hooked) {
            p.print("summary | {s} | hook refused", .{s.target});
            continue;
        }
        if (s.changed == 0) {
            p.print("summary | {s} | {d} | 0 | not measured: no action changed a readable tree ({d} not readable) | {d:.1}", .{ s.target, s.actions, s.unreadable, s.win.idle_per_s });
            continue;
        }
        const wd = s.win.sorted();
        const ud = s.uia.sorted();
        const paired: f64 = @floatFromInt(@max(s.paired_count, 1));
        const plain: f64 = @floatFromInt(@max(s.plain_count, 1));
        p.print("summary | {s} | {d} | {d} | {d} ({d:.0} %) | {d} ({d:.0} %) | {d} ({d:.0} %) | {d:.1} / {d:.1} ms | {d:.1} / {d:.1} ms | {d:.1}, {d:.1} | {d:.1} ms, {d:.1} ms | {d:.1}, {d:.1} | {d:.1}, {d:.1}", .{
            s.target,                                           s.actions,                                          s.changed,
            s.win.signaled,                                     s.win.rate(s.changed),                              s.uia.signaled,
            s.uia.rate(s.changed),                              s.either,                                           @as(f64, @floatFromInt(s.either)) * 100 / @as(f64, @floatFromInt(s.changed)),
            @as(f64, @floatFromInt(percentile(wd, 50))) / 1000, @as(f64, @floatFromInt(percentile(wd, 95))) / 1000, @as(f64, @floatFromInt(percentile(ud, 50))) / 1000,
            @as(f64, @floatFromInt(percentile(ud, 95))) / 1000, s.win.idle_per_s,                                   s.uia.idle_per_s,
            s.add_ms,                                           s.remove_ms,                                        mega(s.plain_cycles) / plain,
            mega(s.paired_cycles) / paired,                     mega(s.idle_plain_cycles) * 1000 / idle_ms,         mega(s.idle_uia_cycles) * 1000 / idle_ms,
        });
        counted += 1;
        if (s.win.rate(s.changed) < threshold_percent) {
            win_failed += 1;
            p.print("A18 REFUTED for {s}: {d:.0} % of its tree changes signaled by WinEvents (threshold {d} %)", .{ s.target, s.win.rate(s.changed), threshold_percent });
        }
        if (!s.subscribed) {
            p.print("UIA events not measured for {s}: the handlers were refused", .{s.target});
            continue;
        }
        uia_counted += 1;
        if (s.uia.rate(s.changed) < threshold_percent) {
            uia_failed += 1;
            p.print("UIA events FALL SHORT for {s}: {d:.0} % of its tree changes signaled (threshold {d} %)", .{ s.target, s.uia.rate(s.changed), threshold_percent });
        }
    }
    if (counted == 0) {
        p.print("verdict | not measured: no target had a tree change to signal", .{});
        return;
    }
    if (win_failed == 0) {
        p.print("verdict | WinEvents (A18) validated on the {d} target(s) measured", .{counted});
    } else p.print("verdict | WinEvents (A18) refuted on {d} of {d} target(s) measured", .{ win_failed, counted });
    if (uia_counted == 0) {
        p.print("verdict | UIA events not measured: no target accepted the handlers", .{});
    } else if (uia_failed == 0) {
        p.print("verdict | UIA events signal the tree changes of the {d} target(s) measured", .{uia_counted});
    } else p.print("verdict | UIA events fall short on {d} of {d} target(s) measured", .{ uia_failed, uia_counted });
}

/// Cycles of each arm of `events-probe churn`.
const churn_cycles = 10;

/// `events-probe churn`: what removing the UI Automation handlers costs
/// once the watched window has been hidden and shown, minimized and
/// restored, has opened and closed dialogs, or is gone. Another project
/// measured a removal of 86 s after its window was hidden and shown, against
/// 64 ms without (agent-desktop, `probes/windows/FINDINGS.md`, A8-3, on
/// Windows Server 2019). The server removes its handlers on the UI
/// Automation worker thread: a slow removal would hold every `ui_tree` and
/// `ui_act`. Each arm also reads the tree while the handlers are in place.
const Churn = struct {
    p: *bg.Probe,
    label: []const u8,
    hwnd: u64,
    /// Longest removal over the arms, for the verdict.
    worst_ms: *f64,

    const Kind = enum { still, hide_show, minimize_restore, dialogs };
    const Armed = struct { add_ms: f64, events: u64 };

    fn begin(c: Churn) ?Armed {
        const t0 = qpc();
        if (!c.p.backend.uiaWatch(c.hwnd)) {
            c.p.print("churn | {s} | UIA handlers refused (hr=0x{x}): arm not measured", .{ c.label, @import("com.zig").lastHr() });
            return null;
        }
        return .{ .add_ms = @as(f64, @floatFromInt(usSince(t0, qpc()))) / 1000, .events = uia_events.count.load(.acquire) };
    }

    fn end(c: Churn, arm_name: []const u8, armed: Armed) void {
        w.Sleep(500);
        _ = c.p.scratch.reset(.retain_capacity);
        var t0 = qpc();
        const read = c.p.snapshot(c.hwnd) != null;
        const read_ms = @as(f64, @floatFromInt(usSince(t0, qpc()))) / 1000;
        const got = uia_events.count.load(.acquire) - armed.events;
        t0 = qpc();
        _ = c.p.backend.uiaWatch(0);
        const remove_ms = @as(f64, @floatFromInt(usSince(t0, qpc()))) / 1000;
        c.worst_ms.* = @max(c.worst_ms.*, remove_ms);
        c.p.print("churn | {s} | {s} | handlers added in {d:.1} ms | {d} UIA events | tree read with the handlers in place: {s} in {d:.1} ms | handlers removed in {d:.1} ms", .{ c.label, arm_name, armed.add_ms, got, if (read) "ok" else "not readable", read_ms, remove_ms });
    }

    fn arm(c: Churn, kind: Kind) void {
        const armed = c.begin() orelse return;
        const h: w.HWND = @ptrFromInt(c.hwnd);
        switch (kind) {
            .still => w.Sleep(1000),
            .hide_show => for (0..churn_cycles) |_| {
                _ = w.ShowWindow(h, w.SW_HIDE);
                w.Sleep(100);
                _ = w.ShowWindow(h, w.SW_SHOWNOACTIVATE);
                w.Sleep(100);
            },
            .minimize_restore => for (0..churn_cycles) |_| {
                _ = window.show(c.hwnd, .minimized, false);
                w.Sleep(50);
                _ = window.show(c.hwnd, .normal, false);
                w.Sleep(50);
            },
            .dialogs => for (0..churn_cycles) |_| {
                const dialog_class = std.unicode.utf8ToUtf16LeStringLiteral(popup_window.dialog_class_name);
                _ = w.PostMessageW(h, w.WM_COMMAND, @as(usize, w.BN_CLICKED) << 16, 1);
                var waited: u32 = 0;
                while (w.FindWindowW(dialog_class, null) == null and waited < 1000) : (waited += 10) w.Sleep(10);
                w.Sleep(100);
                _ = w.PostMessageW(h, popup_window.msg_close_dialog, 0, 0);
                waited = 0;
                while (w.FindWindowW(dialog_class, null) != null and waited < 1000) : (waited += 10) w.Sleep(10);
                w.Sleep(50);
            },
        }
        _ = c.p.decoy.front();
        c.end(switch (kind) {
            .still => "window left alone for 1 s",
            .hide_show => "hidden and shown 10 times",
            .minimize_restore => "minimized and restored 10 times",
            .dialogs => "a dialog opened and closed 10 times",
        }, armed);
    }
};

fn churnAll(p: *bg.Probe, io: std.Io, area: display.Rect) !void {
    var worst_ms: f64 = 0;
    p.print("churn | removal of the UI Automation handlers after the watched window was hidden, minimized, opened dialogs or closed; {d} cycles per arm", .{churn_cycles});

    // The selftest window, in this process.
    {
        var tw: TestWindow = .{ .background = true, .rect = .{ .left = area.x + 120, .top = area.y + 120, .right = area.x + 600, .bottom = area.y + 440 } };
        try tw.start();
        var open = true;
        defer if (open) tw.stop();
        w.Sleep(300);
        _ = p.decoy.front();
        p.decoy.tuck(tw.window());
        w.Sleep(200);
        const c: Churn = .{ .p = p, .label = "window (this process)", .hwnd = @intFromPtr(tw.window()), .worst_ms = &worst_ms };
        c.arm(.still);
        c.arm(.hide_show);
        c.arm(.minimize_restore);
        if (c.begin()) |armed| {
            tw.stop();
            open = false;
            c.end("closed while watched", armed);
        }
    }

    // A Win32 application of another process, which opens dialogs.
    popup: {
        var path: [3 * 1024]u8 = undefined;
        const exe = fixture.selfPath(&path);
        var xbuf: [16]u8 = undefined;
        var ybuf: [16]u8 = undefined;
        const argv = [_][]const u8{ exe, "selftest-popup", try std.fmt.bufPrint(&xbuf, "{d}", .{area.x + 640}), try std.fmt.bufPrint(&ybuf, "{d}", .{area.y + 140}) };
        var child = std.process.spawn(io, .{ .argv = &argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
            p.print("churn | popup | cannot start {s} selftest-popup: {t}", .{ exe, err });
            break :popup;
        };
        defer child.kill(io);
        var hwnd: w.HWND = null;
        var waited: u32 = 0;
        while (hwnd == null and waited < 3000) : (waited += 20) {
            hwnd = w.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral(popup_window.class_name), null);
            if (hwnd == null) w.Sleep(20);
        }
        if (hwnd == null) {
            p.print("churn | popup | no selftest-popup window after 3 s", .{});
            break :popup;
        }
        w.Sleep(300);
        _ = p.decoy.front();
        p.decoy.tuck(hwnd);
        w.Sleep(200);
        const c: Churn = .{ .p = p, .label = "popup (another process, Win32)", .hwnd = @intFromPtr(hwnd), .worst_ms = &worst_ms };
        c.arm(.still);
        c.arm(.hide_show);
        c.arm(.minimize_restore);
        c.arm(.dialogs);
        if (c.begin()) |armed| {
            _ = bg.closeWindow(hwnd);
            c.end("closed while watched", armed);
        }
    }

    // Calculator: a UWP frame, the kind of window the server subscribes to.
    calc: {
        const app = for (bg.reference_apps) |a| {
            if (std.mem.eql(u8, a.name, "calculator")) break a;
        } else break :calc;
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const hwnd = bg.openApp(p, arena_state.allocator(), app) orelse break :calc;
        var open = true;
        defer if (open) {
            if (!bg.closeWindow(@ptrFromInt(hwnd))) p.print("churn | calculator | window 0x{x} still open after WM_CLOSE: close it by hand", .{hwnd});
            _ = p.decoy.front();
        };
        const c: Churn = .{ .p = p, .label = "calculator (UWP frame)", .hwnd = hwnd, .worst_ms = &worst_ms };
        c.arm(.still);
        c.arm(.hide_show);
        c.arm(.minimize_restore);
        if (c.begin()) |armed| {
            open = !bg.closeWindow(@ptrFromInt(hwnd));
            _ = p.decoy.front();
            c.end("closed while watched", armed);
        }
    }
    p.print("churn | verdict | slowest removal of the handlers: {d:.1} ms", .{worst_ms});
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, log: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    _ = env;
    const want = struct {
        fn f(list: []const [:0]const u8, name: []const u8) bool {
            if (list.len == 0) return true;
            for (list) |x| if (std.mem.eql(u8, x, name)) return true;
            return false;
        }
    }.f;
    for (args) |name| {
        const known = std.mem.eql(u8, name, "window") or std.mem.eql(u8, name, "churn") or for (bg.reference_apps) |app| {
            if (std.mem.eql(u8, app.name, name)) break true;
        } else false;
        if (!known) {
            log.print("events-probe: unknown target `{s}` (window, notepad, calculator, settings, explorer, chrome, vscode, churn)\n", .{name}) catch {};
            return 2;
        }
    }

    var backend: Windows = .init(gpa);
    defer backend.deinit();
    const displays = backend.displays();
    if (displays.len == 0) {
        log.print("events-probe: no display enumerated\n", .{}) catch {};
        return 1;
    }
    const primary = displays[0].rect;
    const area: display.Rect = .{ .x = primary.x + 40, .y = primary.y + 40, .w = primary.w - 80, .h = primary.h - 160 };
    var decoy = Decoy.start(io, area) catch |err| {
        log.print("events-probe: the decoy window cannot take the foreground ({t}): run the probe from a terminal the user is not typing in\n", .{err}) catch {};
        return 1;
    };
    defer decoy.stop(io);
    var p: bg.Probe = .{ .gpa = gpa, .io = io, .log = log, .backend = &backend, .decoy = decoy, .scratch = .init(gpa), .prefix = "events-probe" };
    defer p.scratch.deinit();
    defer p.stats.deinit(gpa);
    // As the background mode acts: no focus given to the pattern's target.
    backend.uiAutoFocus(false);
    // The probe registers the handlers itself, after the series without them.
    backend.no_uia_events = true;
    const ev = backend.eventWatcher() orelse {
        log.print("events-probe: the WinEvent thread cannot start\n", .{}) catch {};
        return 1;
    };
    const ring = try gpa.alloc(winevents.Event, 1 << 16);
    defer gpa.free(ring);
    ev.log = ring;
    defer ev.log = null;
    const uia_ring = try gpa.alloc(winevents.Event, 1 << 16);
    defer gpa.free(uia_ring);
    uia_events.log = uia_ring;
    // Every subscription is removed before the ring goes.
    defer uia_events.log = null;
    defer _ = backend.uiaWatch(0);
    p.print("decoy 0x{x} of another process in the foreground; WinEvents out of context, EVENT_MIN to EVENT_MAX, filtered by the target's process; {d} actions per target", .{ @intFromPtr(decoy.hwnd), actions_per_target });

    var stats: std.ArrayList(Stat) = .empty;
    defer stats.deinit(gpa);
    if (want(args, "window")) {
        var tw: TestWindow = .{ .background = true, .rect = .{ .left = area.x + 120, .top = area.y + 120, .right = area.x + 600, .bottom = area.y + 440 } };
        try tw.start();
        defer tw.stop();
        w.Sleep(300);
        _ = decoy.front();
        decoy.tuck(tw.window());
        w.Sleep(200);
        measure(&p, ev, &stats, "window", @intFromPtr(tw.window()), &bg.window_steps, &tw);
    }
    for (bg.reference_apps) |app| if (!p.lost and want(args, app.name)) {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const hwnd = bg.openApp(&p, arena_state.allocator(), app) orelse {
            p.print("summary | {s} | skipped (reason above): not counted in the verdict", .{app.name});
            continue;
        };
        defer {
            if (!bg.closeWindow(@ptrFromInt(hwnd))) p.print("{s} | window 0x{x} still open after WM_CLOSE: close it by hand", .{ app.name, hwnd });
            _ = decoy.front();
        }
        measure(&p, ev, &stats, app.name, hwnd, app.steps, null);
        for (app.restore) |u| bg.undo(&p, hwnd, u);
    };
    // Asked for by name only: it is not part of the series above.
    const churn = for (args) |x| {
        if (std.mem.eql(u8, x, "churn")) break true;
    } else false;
    if (churn and !p.lost) try churnAll(&p, io, area);
    if (!churn or stats.items.len > 0) summary(&p, stats.items);
    p.print("handlers | {d} property events received, {d} with a VARIANT type UI Automation does not send for the subscribed properties", .{ uia_events.property_events.load(.monotonic), uia_events.odd_variants.load(.monotonic) });
    return if (p.lost) 1 else 0;
}
