//! `neo-compute occlusion-probe [chrome|vscode|wpf|a23|durable|flush|pending]...
//! [flush=NAME] [reps=N] [sit=NAME]`
//! (US-058, assumption A19): does the tree of a Chromium or Electron window
//! stay current while the window is covered?
//!
//! A decoy window of another process holds the foreground on the left of the
//! primary display. The probe opens Chrome on the reference page, then VS
//! Code, `reps` times (10) in each of five situations: in view beside the
//! decoy, entirely under it, under it but for a strip of 16 pixels, on the
//! other display, minimized. The window is put in its situation before any
//! UI Automation request reaches its process, so the first read is a first
//! contact. Each launch measures:
//!
//! - the nodes of that first read, and whether the element to act on is in
//!   the tree: at once, after re-reads (4 s at most), or only once the window
//!   is moved into view (a tree that re-reading does not build is held back
//!   by the covering, not merely late);
//! - a cold action, the first one after the first contact, and a warm one:
//!   `ui_act toggle` through the dispatcher of a `--mode background` server,
//!   then the tree read again until the element's state has changed (3 s at
//!   most). An effect that shows in under 1 s counts.
//!
//! One more launch per application runs `expand` and `select` with a name on
//! a combo box (a web `<select>`), in view and covered, and looks for the
//! narrowest visible strip that keeps the tree current. `wpf` reads a WPF
//! window within the second that follows its creation.
//!
//! `a23` (assumption A23), run first: Chrome on `bench/pages/a23.html`,
//! its tree built in view, then covered; 20 `ui_act` per cell for `toggle`,
//! `set_value`, `expand` and `select`, on an element of the web document and
//! on one of the browser's own interface, each asked against the state read
//! just before it, and the verdicts counted. `durable` (US-066): covered
//! toggles, after an uncover-cover cycle and after 10, 60 and 180 s without
//! a request, each verdict counted as read from the covered tree or not,
//! against the truth read in view; then a refused `check` and the cost of
//! the decision. `flush` (US-066): calls that might push the covered tree's
//! pending update without a visible effect, each after 20 toggles, and
//! whether a scroll left pending survives the scroll calls; `flush=<name>`
//! runs one, `pending` the scroll check alone. Lines go to stderr; no
//! element name of a live application is printed.

const std = @import("std");
const w = @import("win32");
const Windows = @import("../windows.zig").Windows;
const uitree = @import("core").uitree;
const display = @import("core").display;
const mcp = @import("core").mcp;
const tools = @import("core").tools;
const a11y = @import("core").a11y;
const window = @import("window.zig");
const fixture = @import("bg_fixture.zig");
const bg = @import("bg_probe.zig");
const selftest = @import("selftest.zig");
const Bench = @import("selftest_background.zig").Bench;
const Caller = selftest.Caller;
const Decoy = fixture.Decoy;
const Server = mcp.Server(Windows, tools.all);

const max_reps = 20;
/// The application loads its page before it is placed, without any request.
const load_ms = 2500;
/// Chromium recomputes the occlusion of its windows after a move.
const settle_ms = 1500;
/// Re-reads of a tree that lacks the element, in place.
const build_wait_ms = 4000;
/// And once the window is back in view.
const unblock_wait_ms = 6000;
/// How long the tree is read again after an action.
const effect_wait_ms = 3000;
/// An effect that shows within this time counts (PRD, US-058).
const fast_ms = 1000;
const threshold_percent = 95;
const strip_px = 16;
/// Widths tried for the narrowest strip that keeps the tree current.
const strip_widths = [_]i32{ 1, 4, 8, 16, 32, 64 };

const Situation = enum {
    visible,
    covered,
    strip,
    other_display,
    minimized,

    fn label(s: Situation) []const u8 {
        return switch (s) {
            .visible => "in view beside the decoy",
            .covered => "entirely under the decoy",
            .strip => "under the decoy but for 16 px",
            .other_display => "on the other display",
            .minimized => "minimized",
        };
    }
};

/// What costs the user least first: nothing shown, a strip, a window on a
/// display they may not look at, a window beside theirs.
const by_cost = [_]Situation{ .minimized, .strip, .other_display, .visible };

/// The element a target is acted on through, and how `ui_find` reaches it.
const Target = struct {
    name: []const u8,
    role: uitree.Role,
    names: []const []const u8,
    queries: []const []const u8,
    /// Start of the element's line after its id.
    needle: []const u8,
    /// The toggle outlives the window (a layout the application saves): the
    /// state is put back when an effect was not read.
    persists: bool = false,
};

const targets = [_]Target{
    .{ .name = "chrome", .role = .checkbox, .names = &.{"Recevoir"}, .queries = &.{"role:checkbox recevoir"}, .needle = " checkbox \"" },
    .{ .name = "vscode", .role = .button, .names = &.{ "Toggle Panel", "Activer/désactiver le panneau" }, .queries = &.{ "role:button toggle panel", "role:button panneau" }, .needle = " button \"", .persists = true },
};

const Series = struct {
    planned: u32 = 0,
    /// The element was not in the tree: nothing to act on.
    no_element: u32 = 0,
    /// The tree showed the effect within `effect_wait_ms`, within `fast_ms`.
    shown: u32 = 0,
    fast: u32 = 0,
    delays: [max_reps * 4]u64 = undefined,
    delays_len: usize = 0,

    fn add(s: *Series, shot: Shot) void {
        s.planned += 1;
        if (shot.missing) {
            s.no_element += 1;
            return;
        }
        const ms = shot.tree_ms orelse return;
        s.shown += 1;
        if (ms < fast_ms) s.fast += 1;
        if (s.delays_len < s.delays.len) {
            s.delays[s.delays_len] = ms;
            s.delays_len += 1;
        }
    }
};

const List = struct {
    items: [max_reps]u64 = undefined,
    len: usize = 0,

    fn add(l: *List, x: u64) void {
        if (l.len == l.items.len) return;
        l.items[l.len] = x;
        l.len += 1;
    }

    fn sorted(l: *List) []const u64 {
        std.mem.sort(u64, l.items[0..l.len], {}, std.sort.asc(u64));
        return l.items[0..l.len];
    }
};

const Cell = struct {
    measured: bool = false,
    skipped: []const u8 = "",
    launches: u32 = 0,
    /// Launches in a process the probe had not met: a first contact.
    fresh: u32 = 0,
    first_nodes: List = .{},
    built_nodes: List = .{},
    /// The element was in the tree at the first read, or after re-reads in
    /// place.
    at_once: u32 = 0,
    in_place: u32 = 0,
    in_place_ms: List = .{},
    /// Launches whose tree needed the window back in view, and got it.
    unblock_tried: u32 = 0,
    unblocked: u32 = 0,
    unblock_ms: List = .{},
    /// Actions whose effect the tree did not show in place, and those of
    /// them it showed once the window was back in view.
    hidden: u32 = 0,
    hidden_shown: u32 = 0,
    cold: Series = .{},
    warm: Series = .{},

    fn share(c: *const Cell) f64 {
        const planned = c.cold.planned + c.warm.planned;
        if (planned == 0) return 0;
        return @as(f64, @floatFromInt(c.cold.fast + c.warm.fast)) * 100 / @as(f64, @floatFromInt(planned));
    }
};

fn qpc() i64 {
    var t: i64 = 0;
    _ = w.QueryPerformanceCounter(&t);
    return t;
}

fn msSince(from: i64) u64 {
    var f: i64 = 1;
    _ = w.QueryPerformanceFrequency(&f);
    return @intCast(@max(0, @divTrunc((qpc() - from) * 1000, f)));
}

fn percentile(sorted: []const u64, p: usize) u64 {
    if (sorted.len == 0) return 0;
    return sorted[@min(sorted.len - 1, (sorted.len * p + 99) / 100 -| 1)];
}

fn pick(els: []const uitree.Element, t: Target) ?uitree.Element {
    for (els) |e| {
        if (e.role != t.role) continue;
        for (t.names) |n| if (std.ascii.findIgnoreCase(e.name, n) != null) return e;
    }
    return null;
}

fn hasDocument(els: []const uitree.Element) bool {
    for (els) |e| if (e.role == .document) return true;
    return false;
}

/// First line of a tool result, cut on a character boundary.
fn firstLine(text: []const u8) []const u8 {
    var line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    if (line.len > 150) {
        var end: usize = 150;
        while (end > 0 and line[end] & 0xc0 == 0x80) end -= 1;
        line = line[0..end];
    }
    return line;
}

/// One measured action.
const Shot = struct {
    missing: bool = false,
    /// `ui_act`, read-back included.
    act_ms: u64 = 0,
    /// From the call to the first tree that shows the effect.
    tree_ms: ?u64 = null,
    result: []const u8 = "",
    /// The element's state before the action.
    was: bool = false,
};

const Run = struct {
    p: *bg.Probe,
    caller: *Caller,
    call_arena: *std.heap.ArenaAllocator,
    reps: usize,
    /// Visible frames: the decoy's, and the target's size.
    decoy: display.Rect,
    size: [2]i32,
    primary: display.Rect,
    other: ?display.Rect,
    /// Processes the probe opened so far.
    pids: std.ArrayList(u32) = .empty,

    fn spot(r: *const Run, sit: Situation, strip: i32) ?[2]i32 {
        const d = r.decoy;
        return switch (sit) {
            .visible => if (d.right() + 24 + r.size[0] <= r.primary.right()) .{ d.right() + 24, d.y + 40 } else null,
            .covered => .{ d.x + 80, d.y + 80 },
            .strip => .{ d.right() + strip - r.size[0], d.y + 80 },
            .other_display => if (r.other) |o| .{ o.x + 120, o.y + 120 } else null,
            .minimized => .{ d.x + 80, d.y + 80 },
        };
    }

    /// Puts the window in `sit` without activating it, right below the
    /// decoy in the z-order, then gives the decoy its input back.
    fn place(r: *Run, hwnd: u64, sit: Situation, strip: i32) bool {
        const h: w.HWND = @ptrFromInt(hwnd);
        const at = r.spot(sit, strip) orelse return false;
        if (sit == .minimized) {
            _ = window.show(hwnd, .minimized, false);
        } else {
            switch (window.place(hwnd, .{ .x = at[0], .y = at[1], .w = r.size[0], .h = r.size[1] }, false)) {
                .ok => {},
                else => return false,
            }
            r.p.decoy.tuck(h);
        }
        _ = r.p.decoy.front();
        return true;
    }

    /// What of the window shows: `in view`, `hidden`, or the strip's width.
    fn shows(r: *Run, hwnd: u64, buf: []u8) []const u8 {
        const h: w.HWND = @ptrFromInt(hwnd);
        if (w.IsIconic(h) != 0) return "minimized";
        const f = window.rect(h) orelse return "no rectangle";
        const d = r.decoy;
        const front = if (w.GetForegroundWindow() == r.p.decoy.hwnd) "decoy in front" else "DECOY NOT IN FRONT";
        const under = fixture.above(r.p.decoy.hwnd, h);
        if (!f.intersects(d)) return std.fmt.bufPrint(buf, "whole window in view, {s}", .{front}) catch "?";
        if (!under) return std.fmt.bufPrint(buf, "ABOVE THE DECOY, {s}", .{front}) catch "?";
        const out_x = @max(0, f.right() - d.right()) + @max(0, d.x - f.x);
        const out_y = @max(0, f.bottom() - d.bottom()) + @max(0, d.y - f.y);
        if (out_x == 0 and out_y == 0) return std.fmt.bufPrint(buf, "nothing in view, {s}", .{front}) catch "?";
        return std.fmt.bufPrint(buf, "{d} px in view beside the decoy, {s}", .{ @max(out_x, out_y), front }) catch "?";
    }

    fn read(r: *Run, hwnd: u64) ?[]const uitree.Element {
        _ = r.p.scratch.reset(.retain_capacity);
        return r.p.snapshot(hwnd);
    }

    fn idOf(r: *Run, hwnd: u64, queries: []const []const u8, needle: []const u8) ?[]const u8 {
        for (queries) |q| {
            const found = r.caller.call("ui_find", "{{\"query\":\"{s}\",\"window\":\"0x{x}\"}}", .{ q, hwnd }) catch continue;
            if (found.is_error) continue;
            if (Bench.idIn(found.text, needle)) |id| return id;
        }
        return null;
    }

    /// One `ui_act toggle` through the server, then the tree read again
    /// until the element's state has changed.
    fn toggle(r: *Run, hwnd: u64, t: Target) Shot {
        const before = pick(r.read(hwnd) orelse return .{ .missing = true, .result = "tree not readable" }, t) orelse
            return .{ .missing = true, .result = "element not in the tree" };
        const was = before.states.checked;
        const id = r.idOf(hwnd, t.queries, t.needle) orelse return .{ .missing = true, .result = "ui_find does not list the element" };
        const t0 = qpc();
        const res = r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"toggle\",\"observe\":\"none\"}}", .{id}) catch
            return .{ .missing = true, .result = "ui_act: dispatcher error" };
        var shot: Shot = .{ .act_ms = msSince(t0), .result = firstLine(res.text), .was = was };
        while (true) {
            if (r.read(hwnd)) |now| if (pick(now, t)) |e| if (e.states.checked != was) {
                shot.tree_ms = msSince(t0);
                break;
            };
            if (msSince(t0) >= effect_wait_ms) break;
            w.Sleep(40);
        }
        return shot;
    }

    fn logShot(r: *Run, t: Target, what: []const u8, kind: []const u8, n: usize, hwnd: u64, shot: Shot) void {
        var b1: [32]u8 = undefined;
        var b2: [96]u8 = undefined;
        const tree = if (shot.tree_ms) |ms| std.fmt.bufPrint(&b1, "after {d} ms", .{ms}) catch "?" else "NOT within 3000 ms";
        if (shot.missing) {
            r.p.print("{s} | {s} | {s} action #{d} | not run: {s} | {s}", .{ t.name, what, kind, n, shot.result, r.shows(hwnd, &b2) });
        } else r.p.print("{s} | {s} | {s} action #{d} | ui_act returned in {d} ms: {s} | effect in the tree: {s} | {s}", .{ t.name, what, kind, n, shot.act_ms, shot.result, tree, r.shows(hwnd, &b2) });
    }

    /// An action whose effect the tree did not show: was it lost, or only
    /// not shown? The window goes into view, the tree is read again, and
    /// the window goes back to `sit`.
    fn late(r: *Run, t: Target, hwnd: u64, sit: Situation, cell: *Cell, shot: Shot) void {
        if (shot.missing or shot.tree_ms != null or sit == .visible) return;
        cell.hidden += 1;
        if (sit == .minimized) _ = window.show(hwnd, .normal, false);
        if (!(r.place(hwnd, .visible, 0) or r.place(hwnd, .other_display, 0))) return;
        const t0 = qpc();
        var shown: ?u64 = null;
        while (shown == null and msSince(t0) < effect_wait_ms) {
            if (r.read(hwnd)) |now| if (pick(now, t)) |e| if (e.states.checked != shot.was) {
                shown = msSince(t0);
                break;
            };
            w.Sleep(40);
        }
        if (shown) |ms| {
            cell.hidden_shown += 1;
            r.p.print("{s} | {s} | window moved into view: the effect shows after {d} ms: the action was delivered, the tree was not current", .{ t.name, @tagName(sit), ms });
        } else r.p.print("{s} | {s} | window moved into view: still no effect after {d} ms: the action was lost", .{ t.name, @tagName(sit), effect_wait_ms });
        _ = r.place(hwnd, sit, strip_px);
        w.Sleep(settle_ms);
    }

    const Opened = struct { hwnd: u64, pid: u32, fresh: bool };

    /// Starts the application; no UI Automation request is made.
    fn open(r: *Run, a: std.mem.Allocator, app: bg.App) ?Opened {
        const p = r.p;
        var before: std.ArrayList(u32) = .empty;
        if (p.backend.listWindows(a, true)) |wins| {
            for (wins) |win| before.append(a, win.pid) catch {};
        } else |_| {}
        const hwnd = bg.launchApp(p, a, app) orelse return null;
        var pid: u32 = 0;
        _ = w.GetWindowThreadProcessId(@ptrFromInt(hwnd), &pid);
        const known = std.mem.indexOfScalar(u32, before.items, pid) != null or std.mem.indexOfScalar(u32, r.pids.items, pid) != null;
        r.pids.append(p.gpa, pid) catch {};
        return .{ .hwnd = hwnd, .pid = pid, .fresh = !known };
    }

    /// Closes the window and waits for its process to end, so the next
    /// launch starts a new one.
    fn close(r: *Run, name: []const u8, o: Opened) void {
        if (!bg.closeWindow(@ptrFromInt(o.hwnd))) r.p.print("{s} | window 0x{x} still open after WM_CLOSE: close it by hand", .{ name, o.hwnd });
        var waited: u32 = 0;
        while (window.alive(o.pid) and waited < 6000) : (waited += 100) w.Sleep(100);
        if (window.alive(o.pid)) r.p.print("{s} | process {d} still runs 6 s after its window closed: the next first contact may reach it", .{ name, o.pid });
        _ = r.p.decoy.front();
    }

    /// What the perception tools say of the window as it stands (EP-014):
    /// the header of its tree and whether the frozen-tree line follows
    /// (US-059), then its largest container read alone (US-056) and one of
    /// its elements read again (US-057).
    fn perception(r: *Run, t: Target, sit: Situation, rep: usize, hwnd: u64) void {
        const p = r.p;
        const full = r.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{hwnd}) catch return;
        const top = r.caller.call("ui_tree", "{{\"window\":\"0x{x}\",\"depth\":2}}", .{hwnd}) catch return;
        const head = full.text[0 .. std.mem.indexOfScalar(u8, full.text, '\n') orelse full.text.len];
        p.print("{s} | {s} | launch {d} | ui_tree: `{s}`, {d} characters, {d} lines; frozen-tree line {s}", .{
            t.name, @tagName(sit), rep + 1, head, full.text.len, std.mem.count(u8, full.text, "\n") + 1, if (std.mem.indexOf(u8, full.text, "Chromium suspend son rendu") != null) "present" else "absent",
        });
        // The line that stands for the most descendants at depth 2.
        var best: usize = 0;
        var best_id: []const u8 = "";
        var lines = std.mem.splitScalar(u8, top.text, '\n');
        while (lines.next()) |line| {
            const end = std.mem.lastIndexOf(u8, line, " descendants") orelse continue;
            const start = (std.mem.lastIndexOf(u8, line[0..end], " … ") orelse continue) + " … ".len;
            const n = std.fmt.parseInt(usize, line[start..end], 10) catch continue;
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            const id = it.next() orelse continue;
            if (n > best and uitree.parseId(id) != null) {
                best = n;
                best_id = id;
            }
        }
        if (best == 0) return p.print("{s} | {s} | launch {d} | depth 2 folds nothing: {d} lines", .{ t.name, @tagName(sit), rep + 1, std.mem.count(u8, top.text, "\n") + 1 });
        const sub = r.caller.call("ui_tree", "{{\"root\":\"{s}\"}}", .{best_id}) catch return;
        var again: [20]u64 = undefined;
        var reread_ok = true;
        for (&again) |*ms| {
            const t0 = selftest.qpcUs();
            const res = r.caller.call("ui_find", "{{\"query\":\"id:{s}\"}}", .{best_id}) catch return;
            ms.* = selftest.qpcUs() - t0;
            if (res.is_error) reread_ok = false;
        }
        std.mem.sort(u64, &again, {}, std.sort.asc(u64));
        p.print("{s} | {s} | launch {d} | depth 2: {d} lines; root {s} ({d} descendants at depth 2): {s}, {d} characters, {d} lines, {s}; ui_find id:{s}: {s}, median {d} us, p95 {d} us", .{
            t.name,                                @tagName(sit),                       rep + 1,                                std.mem.count(u8, top.text, "\n") + 1,
            best_id,                               best,                                if (sub.is_error) sub.text else "read", sub.text.len,
            std.mem.count(u8, sub.text, "\n") + 1,
            if (std.mem.indexOf(u8, sub.text, "nœuds élagués") != null) "some nodes pruned" else "no node pruned",
            best_id,                               if (reread_ok) "read" else "FAILED", again[again.len / 2],                   again[again.len - 2],
        });
    }

    /// One launch in `sit`: first contact, a cold action and a warm one.
    /// False when the application cannot be opened.
    fn launch(r: *Run, t: Target, app: bg.App, sit: Situation, cell: *Cell, rep: usize) bool {
        const p = r.p;
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        _ = r.call_arena.reset(.retain_capacity);
        const o = r.open(arena_state.allocator(), app) orelse return false;
        defer r.close(t.name, o);
        const hwnd = o.hwnd;
        w.Sleep(load_ms);
        if (!r.place(hwnd, sit, strip_px)) {
            p.print("{s} | {s} | launch {d}: the window cannot be placed", .{ t.name, @tagName(sit), rep + 1 });
            return true;
        }
        w.Sleep(settle_ms);
        cell.measured = true;
        cell.launches += 1;
        cell.fresh += @intFromBool(o.fresh);

        // First contact.
        const t0 = qpc();
        const first = r.read(hwnd);
        const first_ms = msSince(t0);
        const n0 = if (first) |e| e.len else 0;
        const doc0 = if (first) |e| hasDocument(e) else false;
        var built = if (first) |e| pick(e, t) != null else false;
        var initial: ?bool = if (first) |e| (if (pick(e, t)) |el| el.states.checked else null) else null;
        cell.first_nodes.add(n0);
        var n1 = n0;
        var how: []const u8 = "at the first read";
        var hbuf: [64]u8 = undefined;
        if (built) {
            cell.at_once += 1;
            cell.in_place_ms.add(first_ms);
        } else while (msSince(t0) < build_wait_ms) {
            w.Sleep(250);
            const now = r.read(hwnd) orelse continue;
            n1 = now.len;
            if (pick(now, t)) |el| {
                built = true;
                initial = el.states.checked;
                const ms = msSince(t0);
                cell.in_place_ms.add(ms);
                how = std.fmt.bufPrint(&hbuf, "after re-reads, {d} ms", .{ms}) catch "after re-reads";
                break;
            }
        }
        if (built) {
            cell.in_place += 1;
            // The tree may still grow once the element shows.
            w.Sleep(400);
            if (r.read(hwnd)) |now| n1 = now.len;
            cell.built_nodes.add(n1);
        } else how = "NOT in place within 4000 ms of re-reads";
        var b2: [96]u8 = undefined;
        p.print("{s} | {s} | launch {d} | process {d} {s} | first contact: {d} nodes in {d} ms, web document {s} | element to act on: {s} ({d} nodes) | {s}", .{
            t.name, @tagName(sit), rep + 1, o.pid, if (o.fresh) "new" else "ALREADY MET (not a first contact)", n0, first_ms, if (doc0) "present" else "absent", how, n1, r.shows(hwnd, &b2),
        });

        r.perception(t, sit, rep, hwnd);

        // Cold action: the first after the first contact.
        var uncertain = false;
        const cold: Shot = if (built) r.toggle(hwnd, t) else .{ .missing = true, .result = "element not in the tree" };
        cell.cold.add(cold);
        r.logShot(t, @tagName(sit), "cold", rep + 1, hwnd, cold);
        uncertain = uncertain or (!cold.missing and cold.tree_ms == null);
        r.late(t, hwnd, sit, cell, cold);

        // A tree re-reading did not build: does the window in view build it?
        if (!built and sit != .visible) {
            cell.unblock_tried += 1;
            if (sit == .minimized) _ = window.show(hwnd, .normal, false);
            const moved = r.place(hwnd, .visible, 0) or r.place(hwnd, .other_display, 0);
            const tu = qpc();
            while (moved and msSince(tu) < unblock_wait_ms) {
                const now = r.read(hwnd) orelse {
                    w.Sleep(250);
                    continue;
                };
                if (pick(now, t)) |el| {
                    built = true;
                    initial = el.states.checked;
                    n1 = now.len;
                    break;
                }
                w.Sleep(250);
            }
            if (built) {
                const ms = msSince(tu);
                cell.unblocked += 1;
                cell.unblock_ms.add(ms);
                cell.built_nodes.add(n1);
                p.print("{s} | {s} | launch {d} | moved into view: element in the tree after {d} ms ({d} nodes): the covering held the tree back", .{ t.name, @tagName(sit), rep + 1, ms, n1 });
            } else p.print("{s} | {s} | launch {d} | moved into view: element still absent after {d} ms", .{ t.name, @tagName(sit), rep + 1, unblock_wait_ms });
            _ = r.place(hwnd, sit, strip_px);
            w.Sleep(settle_ms);
        }

        // Warm action: the tree was built before it.
        const warm: Shot = if (built) r.toggle(hwnd, t) else .{ .missing = true, .result = "element not in the tree" };
        cell.warm.add(warm);
        r.logShot(t, @tagName(sit), "warm", rep + 1, hwnd, warm);
        uncertain = uncertain or (!warm.missing and warm.tree_ms == null) or (cold.missing != warm.missing);
        r.late(t, hwnd, sit, cell, warm);

        // A layout the application saves goes back to what it was.
        if (t.persists and uncertain) if (initial) |was| r.putBack(hwnd, t, was);
        return true;
    }

    /// Reads the element's state with the window in view and toggles it
    /// back to `was`, unmeasured.
    fn putBack(r: *Run, hwnd: u64, t: Target, was: bool) void {
        if (w.IsIconic(@ptrFromInt(hwnd)) != 0) _ = window.show(hwnd, .normal, false);
        if (!(r.place(hwnd, .visible, 0) or r.place(hwnd, .other_display, 0))) return;
        w.Sleep(settle_ms);
        const el = pick(r.read(hwnd) orelse return, t) orelse return;
        if (el.states.checked == was) return;
        _ = r.p.backend.uiOp(r.p.scratch.allocator(), hwnd, el.key, .toggle);
        w.Sleep(500);
        r.p.print("{s} | state of the toggled element put back, unmeasured", .{t.name});
    }

    /// The element in the tree with the window in view: what the further
    /// measures start from. False when it never shows.
    fn buildInView(r: *Run, hwnd: u64, t: Target) bool {
        if (!(r.place(hwnd, .visible, 0) or r.place(hwnd, .other_display, 0))) return false;
        const t0 = qpc();
        while (msSince(t0) < unblock_wait_ms) {
            if (r.read(hwnd)) |now| if (pick(now, t) != null) return true;
            w.Sleep(250);
        }
        return false;
    }

    /// `expand`, then `select` with a name, on the first combo box of the
    /// window (a web `<select>`), then `collapse`.
    fn combo(r: *Run, t: Target, hwnd: u64, sit: Situation) void {
        const p = r.p;
        if (!r.place(hwnd, sit, strip_px)) return;
        w.Sleep(settle_ms);
        var b: [96]u8 = undefined;
        const id = r.idOf(hwnd, &.{"role:combobox"}, " combobox \"") orelse {
            p.print("{s} | select | {s} | no combo box in the window's tree: not measured", .{ t.name, @tagName(sit) });
            return;
        };
        var options: usize = 0;
        if (r.read(hwnd)) |els| for (els) |e| {
            options += @intFromBool(e.role == .listitem and e.actions.select);
        };
        const expand = r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"expand\",\"observe\":\"none\"}}", .{id}) catch return;
        p.print("{s} | select | {s} | {d} selectable entries listed while closed | expand: {s} | {s}", .{ t.name, @tagName(sit), options, firstLine(expand.text), r.shows(hwnd, &b) });
        const sel = r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"select\",\"value\":\"Suisse\",\"observe\":\"none\"}}", .{id}) catch return;
        p.print("{s} | select | {s} | select with a name: {s}", .{ t.name, @tagName(sit), firstLine(sel.text) });
        const back = r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"collapse\",\"observe\":\"none\"}}", .{id}) catch return;
        p.print("{s} | select | {s} | collapse: {s}", .{ t.name, @tagName(sit), firstLine(back.text) });
        _ = p.decoy.front();
    }

    /// The narrowest strip in view that keeps the tree current, the tree
    /// being built: four actions per width.
    fn strips(r: *Run, t: Target, hwnd: u64) void {
        const p = r.p;
        var narrowest: ?i32 = null;
        for (strip_widths) |px| {
            if (!r.place(hwnd, .strip, px)) continue;
            w.Sleep(settle_ms);
            var s: Series = .{};
            var b: [96]u8 = undefined;
            for (0..4) |_| {
                s.add(r.toggle(hwnd, t));
                w.Sleep(200);
            }
            const d = s.delays[0..s.delays_len];
            std.mem.sort(u64, d, {}, std.sort.asc(u64));
            p.print("{s} | strip {d} px | effect in under {d} ms: {d} of {d}, slowest {d} ms | {s}", .{ t.name, px, fast_ms, s.fast, s.planned, if (d.len > 0) d[d.len - 1] else 0, r.shows(hwnd, &b) });
            if (s.fast == s.planned and narrowest == null) narrowest = px;
            // An odd number of effects: the state goes back.
            if (t.persists and s.shown % 2 == 1) _ = r.toggle(hwnd, t);
        }
        if (narrowest) |px| {
            p.print("{s} | narrowest strip in view that kept the tree current on 4 actions of 4: {d} px", .{ t.name, px });
        } else p.print("{s} | no strip up to {d} px kept the tree current on 4 actions of 4", .{ t.name, strip_widths[strip_widths.len - 1] });
    }

    /// One more launch: the `<select>` case and the strip widths.
    fn extras(r: *Run, t: Target, app: bg.App, covered_holds: bool) void {
        const p = r.p;
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        _ = r.call_arena.reset(.retain_capacity);
        const o = r.open(arena_state.allocator(), app) orelse return;
        defer r.close(t.name, o);
        w.Sleep(load_ms);
        if (!r.buildInView(o.hwnd, t)) {
            p.print("{s} | further measures skipped: the element never showed with the window in view", .{t.name});
            return;
        }
        const initial: ?bool = if (r.read(o.hwnd)) |els| (if (pick(els, t)) |el| el.states.checked else null) else null;
        r.combo(t, o.hwnd, .visible);
        r.combo(t, o.hwnd, .covered);
        if (covered_holds) {
            p.print("{s} | strip widths not searched: the tree stays current entirely covered", .{t.name});
        } else r.strips(t, o.hwnd);
        if (t.persists) if (initial) |was| r.putBack(o.hwnd, t, was);
    }
};

fn summary(p: *bg.Probe, t: Target, cells: *[5]Cell) void {
    p.print("summary | target | situation | launches (first contacts) | nodes at first contact, median (min..max) | nodes once built, median | element in the tree in place: at the first read, in all, median ms | moved into view: built, median ms | cold actions with the effect in under {d} ms | warm actions | delay of the effects shown, median / p95 | share of the actions | effects not shown in place that showed once the window was in view", .{fast_ms});
    for (cells, 0..) |*c, i| {
        const sit: Situation = @fromBackingInt(@intCast(i));
        if (!c.measured) {
            p.print("summary | {s} | {s} | skipped{s}{s}", .{ t.name, @tagName(sit), if (c.skipped.len > 0) ": " else "", c.skipped });
            continue;
        }
        const first = c.first_nodes.sorted();
        const built = c.built_nodes.sorted();
        const in_place = c.in_place_ms.sorted();
        const unblock = c.unblock_ms.sorted();
        var delays: [max_reps * 8]u64 = undefined;
        var n: usize = 0;
        for ([_]*const Series{ &c.cold, &c.warm }) |s| for (s.delays[0..s.delays_len]) |d| {
            delays[n] = d;
            n += 1;
        };
        std.mem.sort(u64, delays[0..n], {}, std.sort.asc(u64));
        var dbuf: [48]u8 = undefined;
        const delay = if (n == 0) "none shown" else std.fmt.bufPrint(&dbuf, "{d} / {d} ms", .{ percentile(delays[0..n], 50), percentile(delays[0..n], 95) }) catch "?";
        p.print("summary | {s} | {s} | {d} ({d}) | {d} ({d}..{d}) | {d} | {d}, {d} of {d}, {d} ms | {d} of {d}, {d} ms | {d} of {d} | {d} of {d} | {s} | {d:.0} % | {d} of {d}", .{
            t.name,                @tagName(sit),                      c.launches,                                     c.fresh,
            percentile(first, 50), if (first.len > 0) first[0] else 0, if (first.len > 0) first[first.len - 1] else 0, percentile(built, 50),
            c.at_once,             c.in_place,                         c.launches,                                     percentile(in_place, 50),
            c.unblocked,           c.unblock_tried,                    percentile(unblock, 50),                        c.cold.fast,
            c.cold.planned,        c.warm.fast,                        c.warm.planned,                                 delay,
            c.share(),             c.hidden_shown,                     c.hidden,
        });
    }
    const covered = &cells[@backingInt(Situation.covered)];
    if (!covered.measured) {
        p.print("verdict | {s} | A19 not measured: the covered situation did not run", .{t.name});
        return;
    }
    if (covered.share() >= threshold_percent) {
        p.print("verdict | {s} | A19 VALIDATED: {d:.0} % of the actions on the entirely covered window showed their effect in under {d} ms (threshold {d} %)", .{ t.name, covered.share(), fast_ms, threshold_percent });
        return;
    }
    const cheapest: ?Situation = for (by_cost) |s| {
        const c = &cells[@backingInt(s)];
        if (c.measured and c.share() >= threshold_percent) break s;
    } else null;
    if (cheapest) |s| {
        p.print("verdict | {s} | A19 REFUTED: {d:.0} % of the actions on the entirely covered window showed their effect in under {d} ms (threshold {d} %); cheapest situation that reaches it: {s} ({s}, {d:.0} %)", .{ t.name, covered.share(), fast_ms, threshold_percent, @tagName(s), s.label(), cells[@backingInt(s)].share() });
    } else p.print("verdict | {s} | A19 REFUTED: {d:.0} % of the actions on the entirely covered window showed their effect in under {d} ms (threshold {d} %); no measured situation reaches it", .{ t.name, covered.share(), fast_ms, threshold_percent });
}

const wpf_title = "neo-compute wpf probe";
/// A WPF window from Windows PowerShell, which ships with Windows and with
/// the .NET Framework's WPF: a button and a check box, never activated.
const wpf_script =
    "Add-Type -AssemblyName PresentationFramework; " ++
    "$w = New-Object System.Windows.Window; $w.Title = '" ++ wpf_title ++ "'; $w.Width = 420; $w.Height = 240; " ++
    "$w.WindowStartupLocation = 'Manual'; $w.Left = {d}; $w.Top = {d}; $w.ShowActivated = $false; " ++
    "$p = New-Object System.Windows.Controls.StackPanel; " ++
    "$b = New-Object System.Windows.Controls.Button; $b.Content = 'Valider'; [void]$p.Children.Add($b); " ++
    "$c = New-Object System.Windows.Controls.CheckBox; $c.Content = 'Option'; [void]$p.Children.Add($c); " ++
    "$w.Content = $p; [void]$w.ShowDialog()";

/// Reads a WPF window as soon as it exists, then over the two seconds that
/// follow: an empty tree at first is the generic provider Windows gives a
/// window whose own provider is not up yet.
fn wpf(p: *bg.Probe, at: [2]i32) void {
    const title = std.unicode.utf8ToUtf16LeStringLiteral(wpf_title);
    for (0..3) |round| {
        if (w.FindWindowW(null, title) != null) {
            p.print("wpf | skipped: a window titled `{s}` is already open", .{wpf_title});
            return;
        }
        var sbuf: [1024]u8 = undefined;
        // Device-independent units: the position only has to be on screen.
        const script = std.fmt.bufPrint(&sbuf, wpf_script, .{ @divTrunc(at[0], 2), @divTrunc(at[1], 2) }) catch return;
        const argv = [_][]const u8{ "powershell.exe", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", script };
        var child = std.process.spawn(p.io, .{ .argv = &argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
            p.print("wpf | skipped: Windows PowerShell cannot be started ({t}), no WPF application to read", .{err});
            return;
        };
        defer child.kill(p.io);
        var hwnd: w.HWND = null;
        const t0 = qpc();
        while (hwnd == null and msSince(t0) < 20_000) {
            hwnd = w.FindWindowW(null, title);
            if (hwnd == null) w.Sleep(5);
        }
        if (hwnd == null) {
            p.print("wpf | skipped: no WPF window within 20 s (WPF absent from this system)", .{});
            return;
        }
        const born = qpc();
        const handle: u64 = @intFromPtr(hwnd);
        for ([_]u64{ 0, 100, 250, 500, 1000, 2000 }) |at_ms| {
            while (msSince(born) < at_ms) w.Sleep(5);
            _ = p.scratch.reset(.retain_capacity);
            const tr = qpc();
            const els = p.snapshot(handle);
            const took = msSince(tr);
            var controls: usize = 0;
            if (els) |list| for (list) |e| {
                controls += @intFromBool(e.role == .button or e.role == .checkbox);
            };
            // The title bar's own buttons come from Windows, not from WPF.
            const own = if (els) |list| for (list) |e| {
                if (e.role == .checkbox or std.mem.eql(u8, e.name, "Valider")) break true;
            } else false else false;
            p.print("wpf | launch {d} | read {d} ms after the window exists, in {d} ms: {s}, {d} nodes, {d} buttons and check boxes, the window's own controls {s}", .{
                round + 1, msSince(born) - took, took, if (els == null) "NOT READABLE" else "read", if (els) |l| l.len else 0, controls, if (own) "present" else "ABSENT (generic provider: empty tree)",
            });
        }
        _ = w.PostMessageW(hwnd, w.WM_CLOSE, 0, 0);
        var waited: u32 = 0;
        while (w.IsWindow(hwnd) != 0 and waited < 3000) : (waited += 50) w.Sleep(50);
        _ = p.decoy.front();
    }
}

// ---------------------------------------------------------------- US-065

/// Chrome on the A23 page, a second tab of it for the tab strip's Select.
const a23_chrome: bg.App = .{
    .name = "chrome",
    .argv = &.{ "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check", "--new-window", "{a23_url}", "{a23_url}#onglet-2" },
    .exe = "chrome.exe",
    .titles = &.{"neo-compute a23 page"},
    .title_contains = true,
    .chromium = true,
    .steps = &.{},
};

const a23_box: Target = .{ .name = "chrome", .role = .checkbox, .names = &.{"Case A23"}, .queries = &.{"role:checkbox case a23"}, .needle = " checkbox \"" };

/// The four actions A23 is measured for; `expand` stands for expand and
/// collapse, which share ExpandCollapse.
const A23Action = enum { toggle, set_value, expand, select };

const Place = enum {
    web,
    browser,
    fn label(p: Place) []const u8 {
        return switch (p) {
            .web => "web document",
            .browser => "browser interface, outside the document",
        };
    }
};

const a23_actions_per_cell = 20;

const A23Cell = struct {
    measured: bool = false,
    absent: []const u8 = "",
    /// Verified with a change of the state read before the action.
    verified: u32 = 0,
    contradicted: u32 = 0,
    unverifiable: u32 = 0,
    other: u32 = 0,
    first_other: [160]u8 = undefined,
    first_other_len: usize = 0,
    /// One letter per action, in order: V verified, C contradicted, U
    /// unverifiable, X other.
    seq: [a23_actions_per_cell]u8 = @splat('-'),
    seq_len: usize = 0,

    fn note(c: *A23Cell, letter: u8) void {
        if (c.seq_len == c.seq.len) return;
        c.seq[c.seq_len] = letter;
        c.seq_len += 1;
    }
};

/// The element of a cell: one of the page's on the web document, the first
/// one of the browser's own interface with the pattern outside it.
fn a23Element(els: []const uitree.Element, under: []const bool, action: A23Action, place: Place, skip_selected: bool) ?uitree.Element {
    for (els, under) |e, web| {
        if (web != (place == .web)) continue;
        const ok = switch (action) {
            .toggle => e.actions.toggle and (place == .browser or std.mem.indexOf(u8, e.name, "Case A23") != null),
            .set_value => e.actions.value and e.role == .edit and (place == .browser or std.mem.indexOf(u8, e.name, "Champ A23") != null),
            .expand => e.actions.expand_collapse and (place == .browser or std.mem.indexOf(u8, e.name, "Détails A23") != null),
            .select => e.actions.select and (if (place == .web) e.role == .listitem else e.role == .tabitem) and !(skip_selected and e.states.selected),
        };
        if (ok) return e;
    }
    return null;
}

/// The id the server gives element `key`, read from a whole tree.
fn idOfKey(r: *Run, hwnd: u64, key: u64, buf: []u8) ?[]const u8 {
    const ids = &r.caller.server.session.ui.ids;
    if (ids.by_key.get(key) == null) _ = r.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{hwnd}) catch return null;
    const id = ids.by_key.get(key) orelse return null;
    var w_: std.Io.Writer = .fixed(buf);
    uitree.writeId(&w_, id) catch return null;
    return w_.buffered();
}

/// One action of a cell, asked against the state read just before it, so
/// that a verified verdict is one with a change: what US-065 learns from.
fn a23Act(r: *Run, hwnd: u64, action: A23Action, place: Place, cell: *A23Cell, n: usize) void {
    const els = r.read(hwnd) orelse {
        cell.other += 1;
        return;
    };
    const under = uitree.underDocument(r.p.scratch.allocator(), els, false) catch return;
    const e = a23Element(els, under, action, place, true) orelse {
        cell.other += 1;
        return;
    };
    var ib: [16]u8 = undefined;
    const id = idOfKey(r, hwnd, e.key, &ib) orelse {
        cell.other += 1;
        return;
    };
    const res = switch (action) {
        .toggle => r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"toggle\",\"observe\":\"none\"}}", .{id}),
        .set_value => r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"set_value\",\"value\":\"{s}\",\"observe\":\"none\"}}", .{ id, if (n % 2 == 0) "deux" else "un" }),
        .expand => r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"{s}\",\"observe\":\"none\"}}", .{ id, if (e.states.expanded) "collapse" else "expand" }),
        .select => r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"select\",\"observe\":\"none\"}}", .{id}),
    } catch {
        cell.other += 1;
        return;
    };
    const line = firstLine(res.text);
    if (std.mem.indexOf(u8, line, " : vérifié") != null) {
        cell.verified += 1;
        cell.note('V');
    } else if (std.mem.indexOf(u8, line, " : contredit") != null) {
        cell.contradicted += 1;
        cell.note('C');
    } else if (std.mem.indexOf(u8, line, " : délivré") != null) {
        cell.unverifiable += 1;
        cell.note('U');
    } else {
        cell.other += 1;
        cell.note('X');
        if (cell.first_other_len == 0) {
            cell.first_other_len = @min(line.len, cell.first_other.len);
            @memcpy(cell.first_other[0..cell.first_other_len], line[0..cell.first_other_len]);
        }
    }
}

/// Assumption A23 (US-065, US-066): on a covered Chrome whose tree was
/// built in view, the verdicts of each kind of action on the web document
/// and on the browser's own interface. Since US-066 the web document's
/// read "délivré, effet non vérifiable": its tree is one action behind.
fn a23(r: *Run) void {
    const p = r.p;
    var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
    defer arena_state.deinit();
    _ = r.call_arena.reset(.retain_capacity);
    const o = r.open(arena_state.allocator(), a23_chrome) orelse return;
    defer r.close("chrome", o);
    w.Sleep(load_ms);
    if (!r.buildInView(o.hwnd, a23_box)) {
        p.print("chrome | a23 | the page's tree never showed with the window in view: A23 not measured", .{});
        return;
    }
    // Every element read once in view, so the covered tree is the one
    // built before the covering.
    _ = r.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{o.hwnd}) catch return;
    if (!r.place(o.hwnd, .covered, 0)) return p.print("chrome | a23 | the window cannot be covered: A23 not measured", .{});
    w.Sleep(settle_ms);
    var b: [96]u8 = undefined;
    const tree = r.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{o.hwnd}) catch return;
    p.print("chrome | a23 | covered: {s}; frozen-tree line {s}", .{ r.shows(o.hwnd, &b), if (std.mem.indexOf(u8, tree.text, "Chromium suspend son rendu") != null) "present" else "ABSENT" });

    var cells: [2][4]A23Cell = @splat(@splat(.{}));
    // The tab strip's Select changes the page shown: it runs last.
    const order = [_]struct { Place, A23Action }{
        .{ .web, .toggle },     .{ .web, .set_value },     .{ .web, .expand },     .{ .web, .select },
        .{ .browser, .toggle }, .{ .browser, .set_value }, .{ .browser, .expand }, .{ .browser, .select },
    };
    for (order) |cell_of| {
        if (p.lost) return;
        const place, const action = cell_of;
        const cell = &cells[@backingInt(place)][@backingInt(action)];
        const els = r.read(o.hwnd) orelse continue;
        const under = uitree.underDocument(p.scratch.allocator(), els, false) catch continue;
        if (a23Element(els, under, action, place, false) == null) {
            cell.absent = if (place == .web) "the page's element is not in the tree" else "no element of the browser's interface has the pattern";
        } else {
            cell.measured = true;
            for (0..a23_actions_per_cell) |n| {
                a23Act(r, o.hwnd, action, place, cell, n);
                w.Sleep(150);
            }
            // An open menu of the browser closes again.
            if (action == .expand and place == .browser) {
                var unused: A23Cell = .{};
                a23Act(r, o.hwnd, .expand, .browser, &unused, 0);
            }
        }
        if (cell.measured) {
            p.print("chrome | a23 | {t} | {s} | verified with a change: {d} of {d} (contradicted {d}, unverifiable {d}, other {d}{s}{s}) | in order {s} | {s}", .{
                action,                                            place.label(),                             cell.verified,             a23_actions_per_cell, cell.contradicted, cell.unverifiable, cell.other,
                if (cell.first_other_len > 0) ", first: " else "", cell.first_other[0..cell.first_other_len], cell.seq[0..cell.seq_len], r.shows(o.hwnd, &b),
            });
        } else p.print("chrome | a23 | {t} | {s} | not measured: {s}", .{ action, place.label(), cell.absent });
        _ = p.decoy.front();
    }
    // US-066: on the covered web document no verdict may come from the
    // tree, which is one action behind.
    var from_tree: u32 = 0;
    for (cells[@backingInt(Place.web)]) |c| from_tree += c.verified + c.contradicted;
    p.print("chrome | a23 | web document: {d} verdict(s) read from the covered tree (US-066 wants 0)", .{from_tree});
}

/// US-065 (PRD 1.7): whether, and how long, the tree of a covered Chrome
/// stays current once an action has read back. `toggle` on the A23 page's
/// box right after the covering, twice more, then the window in view: the
/// state it shows there is the truth the covered reads are compared with.
/// Covered again, two actions, then after 10 s, 60 s and 180 s without any
/// request, and the truth once more. A contradicted verdict is followed by
/// 3 s of tree reads: the effect late, or never.
fn durable(r: *Run) void {
    const p = r.p;
    var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
    defer arena_state.deinit();
    _ = r.call_arena.reset(.retain_capacity);
    durable_counts = .{};
    const o = r.open(arena_state.allocator(), a23_chrome) orelse return;
    defer r.close("chrome", o);
    w.Sleep(load_ms);
    if (!r.buildInView(o.hwnd, a23_box)) return p.print("chrome | durable | the page's tree never showed in view: not measured", .{});
    _ = r.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{o.hwnd}) catch return;
    var toggles: u32 = 0;
    const start = truth(r, o.hwnd, "in view before any action", null, null) orelse return;
    if (!r.place(o.hwnd, .covered, 0)) return p.print("chrome | durable | the window cannot be covered: not measured", .{});
    w.Sleep(settle_ms);
    var last: ?bool = null;
    for ([_][]const u8{ "first after the covering", "second", "third" }) |label| {
        if (p.lost) return;
        last = durableAct(r, o.hwnd, label) orelse last;
        toggles += 1;
        w.Sleep(150);
    }
    _ = truth(r, o.hwnd, "in view after 3 covered toggles", last, if (toggles % 2 == 0) start else !start);
    if (!r.place(o.hwnd, .covered, 0)) return;
    w.Sleep(settle_ms);
    for ([_][]const u8{ "first after uncovered then covered again", "second after the cycle" }) |label| {
        if (p.lost) return;
        last = durableAct(r, o.hwnd, label) orelse last;
        toggles += 1;
        w.Sleep(150);
    }
    for ([_]u32{ 10, 60, 180 }) |sec| {
        if (p.lost) return;
        w.Sleep(sec * 1000);
        var lb: [48]u8 = undefined;
        last = durableAct(r, o.hwnd, std.fmt.bufPrint(&lb, "after {d} s without a request", .{sec}) catch "?") orelse last;
        toggles += 1;
    }
    _ = truth(r, o.hwnd, "in view at the end", last, if (toggles % 2 == 0) start else !start);
    p.print("chrome | durable | {d} covered toggles: {d} verdict(s) read from the covered tree, {d} delivered without a verdict (US-066 wants 0 from the tree)", .{ toggles, durable_counts.from_tree, durable_counts.unverifiable });
    // `check` decides from the state it reads: refused, nothing sent.
    const before = truthQuiet(r, o.hwnd);
    if (!r.place(o.hwnd, .covered, 0)) return;
    w.Sleep(settle_ms);
    decisionCost(r, o.hwnd);
    _ = p.decoy.front();
    var ib: [16]u8 = undefined;
    const els = r.read(o.hwnd) orelse return;
    const box = pick(els, a23_box) orelse return;
    const id = idOfKey(r, o.hwnd, box.key, &ib) orelse return;
    const verb: []const u8 = if (before orelse false) "uncheck" else "check";
    const res = r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"{s}\",\"observe\":\"none\"}}", .{ id, verb }) catch return;
    const refused = std.mem.indexOf(u8, res.text, "une action de retard") != null;
    const after = truthQuiet(r, o.hwnd);
    p.print("chrome | durable | covered {s}: {s} | truth before {s}, after {s}: {s}", .{
        verb, if (refused) "refused" else "NOT REFUSED", stateName(before), stateName(after), if (before != null and std.meta.eql(before, after)) "unchanged" else "CHANGED OR UNREAD",
    });
}

/// What `durableAct` counted since the start of `durable`.
var durable_counts: struct { from_tree: u32 = 0, unverifiable: u32 = 0 } = .{};

fn stateName(x: ?bool) []const u8 {
    return if (x) |v| (if (v) "coché" else "décoché") else "unread";
}

/// The box's state in view, printed by nobody.
fn truthQuiet(r: *Run, hwnd: u64) ?bool {
    if (!(r.place(hwnd, .visible, 0) or r.place(hwnd, .other_display, 0))) return null;
    w.Sleep(settle_ms);
    var seen: ?bool = null;
    const t0 = qpc();
    while (msSince(t0) < 1500) {
        if (r.read(hwnd)) |els| if (pick(els, a23_box)) |e| {
            seen = e.states.checked;
        };
        w.Sleep(250);
    }
    return seen;
}

/// The box's state with the window in view (the tree is current there,
/// US-058), against the last covered read and the state every delivered
/// toggle would give. The window stays in view.
fn truth(r: *Run, hwnd: u64, label: []const u8, covered_read: ?bool, delivered_or_null: ?bool) ?bool {
    const p = r.p;
    if (!(r.place(hwnd, .visible, 0) or r.place(hwnd, .other_display, 0))) return null;
    w.Sleep(settle_ms);
    const t0 = qpc();
    var seen: ?bool = null;
    while (msSince(t0) < 2000) {
        if (r.read(hwnd)) |els| if (pick(els, a23_box)) |e| {
            seen = e.states.checked;
        };
        w.Sleep(250);
    }
    const now = seen orelse {
        p.print("chrome | durable | {s} | the box is not in the tree", .{label});
        return null;
    };
    const name = struct {
        fn f(x: bool) []const u8 {
            return if (x) "coché" else "décoché";
        }
    }.f;
    const delivered = delivered_or_null orelse {
        p.print("chrome | durable | {s} | truth {s}", .{ label, name(now) });
        return now;
    };
    if (covered_read) |c| {
        p.print("chrome | durable | {s} | truth {s} | last covered read {s}: {s} | every toggle delivered would give {s}: {s}", .{
            label, name(now), name(c), if (c == now) "current" else "BEHIND", name(delivered), if (delivered == now) "all delivered" else "SOME LOST",
        });
    } else p.print("chrome | durable | {s} | truth {s} | no covered read | every toggle delivered would give {s}: {s}", .{ label, name(now), name(delivered), if (delivered == now) "all delivered" else "SOME LOST" });
    return now;
}

/// One covered toggle; the state it read back, null when it read none.
fn durableAct(r: *Run, hwnd: u64, label: []const u8) ?bool {
    const p = r.p;
    _ = p.decoy.front();
    const els = r.read(hwnd) orelse {
        p.print("chrome | durable | {s} | tree not readable", .{label});
        return null;
    };
    const e = pick(els, a23_box) orelse {
        p.print("chrome | durable | {s} | the box is not in the tree", .{label});
        return null;
    };
    const was = e.states.checked;
    var ib: [16]u8 = undefined;
    const id = idOfKey(r, hwnd, e.key, &ib) orelse {
        p.print("chrome | durable | {s} | the box has no id", .{label});
        return null;
    };
    const t0 = qpc();
    const res = r.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"toggle\",\"observe\":\"none\"}}", .{id}) catch return null;
    const act_ms = msSince(t0);
    const line = r.call_arena.allocator().dupe(u8, firstLine(res.text)) catch "";
    var b: [96]u8 = undefined;
    if (std.mem.indexOf(u8, line, " : vérifié") != null or std.mem.indexOf(u8, line, " : contredit") != null) durable_counts.from_tree += 1;
    if (std.mem.indexOf(u8, line, " : délivré, effet non vérifiable") != null) {
        durable_counts.unverifiable += 1;
        p.print("chrome | durable | {s} | {s} in {d} ms | {s}", .{ label, line, act_ms, r.shows(hwnd, &b) });
        return null;
    }
    const read: ?bool = if (std.mem.indexOf(u8, line, "(décoché)") != null or std.mem.indexOf(u8, line, "lu décoché") != null) false else if (std.mem.indexOf(u8, line, "(coché)") != null or std.mem.indexOf(u8, line, "lu coché") != null) true else null;
    if (std.mem.indexOf(u8, line, " : vérifié") != null) {
        p.print("chrome | durable | {s} | {s} in {d} ms | {s}", .{ label, line, act_ms, r.shows(hwnd, &b) });
        return read;
    }
    var late: ?u64 = null;
    while (msSince(t0) < act_ms + effect_wait_ms) {
        if (r.read(hwnd)) |now| if (pick(now, a23_box)) |el| if (el.states.checked != was) {
            late = msSince(t0);
            break;
        };
        w.Sleep(40);
    }
    var lb: [48]u8 = undefined;
    p.print("chrome | durable | {s} | {s} | effect in the tree: {s} | {s}", .{ label, line, if (late) |ms| std.fmt.bufPrint(&lb, "after {d} ms", .{ms}) catch "?" else "NOT within 3 s", r.shows(hwnd, &b) });
    return if (late != null) !was else read;
}

/// What the US-066 decision adds to an action on a web element of a
/// covered Chromium window: the z-order read and judged by Chromium's rules
/// (< 1 ms p95).
fn decisionCost(r: *Run, hwnd: u64) void {
    const p = r.p;
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    var judge: [200]u64 = undefined;
    for (&judge) |*us| {
        _ = scratch.reset(.retain_capacity);
        const a = scratch.allocator();
        const t0 = selftest.qpcUs();
        const layers = p.backend.windowLayers(a);
        if (a11y.layerIndex(layers, hwnd)) |at| _ = a11y.coveredIn(a, layers, at, p.backend.displays(), true);
        us.* = selftest.qpcUs() - t0;
    }
    std.mem.sort(u64, &judge, {}, std.sort.asc(u64));
    const p95 = judge[judge.len * 95 / 100];
    p.print("chrome | decision cost | z-order and Chromium's rules: median {d} us, p95 {d} us, budget 1000 us: {s}", .{ judge[judge.len / 2], p95, if (p95 < 1000) "within" else "OVER" });
}

// ---------------------------------------------------------------- US-066

/// Calls that might push a covered Chrome's pending tree update without a
/// visible effect (US-066). `reread` and `snapshot` are controls.
const Flush = enum {
    reread,
    snapshot,
    text,
    scroll_item,
    scroll_to,
    scroll_noscroll,
    scroll_noamount,
    collapse_collapsed,
    same_value,

    fn label(f: Flush) []const u8 {
        return switch (f) {
            .reread => "control: the box read again 300 ms later",
            .snapshot => "control: the whole tree read again",
            .text => "the tree read with the web text (ui_tree text)",
            .scroll_item => "ScrollItem.ScrollIntoView on the box, already in view",
            .scroll_to => "ScrollPattern.SetScrollPercent of the document to where it is",
            .scroll_noscroll => "ScrollPattern.SetScrollPercent(NoScroll, NoScroll) on the document",
            .scroll_noamount => "ScrollPattern.Scroll(NoAmount, NoAmount) on the document",
            .collapse_collapsed => "ExpandCollapse.Collapse on the collapsed <details>",
            .same_value => "ValuePattern.SetValue of the text field to its own value",
        };
    }
};

const flush_toggles = 20;
/// `flush=<candidate>`: that one alone.
var flush_only: ?Flush = null;

/// What the page shows in view: the box, the document's scroll position,
/// the focused element.
const PageState = struct { box: bool, scroll: ?f32, focused: ?u64 };

fn pageInView(r: *Run, hwnd: u64, box_key: u64, host: ?u64) ?PageState {
    if (!(r.place(hwnd, .visible, 0) or r.place(hwnd, .other_display, 0))) return null;
    w.Sleep(settle_ms);
    var st: ?PageState = null;
    const t0 = qpc();
    while (msSince(t0) < 1500) {
        if (r.read(hwnd)) |els| {
            var box: ?bool = null;
            var focused: ?u64 = null;
            for (els) |e| {
                if (e.key == box_key) box = e.states.checked;
                if (e.states.focused) focused = e.key;
            }
            const scroll: ?f32 = if (host) |h| switch (r.p.backend.uiLive(r.p.scratch.allocator(), hwnd, h, .all)) {
                .ok => |l| if (l.scroll) |sc| sc.v else null,
                else => null,
            } else null;
            if (box) |b| st = .{ .box = b, .scroll = scroll, .focused = focused };
        }
        w.Sleep(250);
    }
    return st;
}

fn liveBox(r: *Run, hwnd: u64, key: u64) ?bool {
    return switch (r.p.backend.uiLive(r.p.scratch.allocator(), hwnd, key, .toggle)) {
        .ok => |l| if (l.toggle) |t| t == .on else null,
        else => null,
    };
}

/// One candidate call; false when it failed or is unavailable.
fn flushCall(r: *Run, f: Flush, hwnd: u64, box_key: u64, host: ?u64, details: ?u64, field: ?u64, field_value: []const u8) bool {
    const b = r.p.backend;
    const a = r.p.scratch.allocator();
    switch (f) {
        .reread => w.Sleep(300),
        .snapshot => _ = b.uiSnapshot(a, hwnd, .{}),
        .text => _ = b.uiSnapshot(a, hwnd, .{ .text = true }),
        .scroll_item => return b.uiOp(a, hwnd, box_key, .scroll_item) == .ok,
        .scroll_to => {
            const h = host orelse return false;
            const now: ?f32 = switch (b.uiLive(a, hwnd, h, .all)) {
                .ok => |l| if (l.scroll) |sc| sc.v else null,
                else => null,
            };
            return now != null and b.uiOp(a, hwnd, h, .{ .scroll_to = .{ .v = now.? } }) == .ok;
        },
        .scroll_noscroll => return b.uiOp(a, hwnd, host orelse return false, .{ .scroll_to = .{} }) == .ok,
        .scroll_noamount => return b.uiOp(a, hwnd, host orelse return false, .{ .scroll = .{ .h = .none, .v = .none } }) == .ok,
        .collapse_collapsed => return b.uiOp(a, hwnd, details orelse return false, .collapse) == .ok,
        .same_value => return b.uiOp(a, hwnd, field orelse return false, .{ .set_value = field_value }) == .ok,
    }
    return true;
}

/// A scroll of the covered document left pending, then the candidate: does
/// the call keep it (the truth in view moved) or put the stale position
/// back?
fn pendingScroll(r: *Run, f: Flush, hwnd: u64, box_key: u64, host: u64, in_view: bool) void {
    const p = r.p;
    const start = pageInView(r, hwnd, box_key, host) orelse return;
    if (!in_view) {
        if (!r.place(hwnd, .covered, 0)) return;
        w.Sleep(settle_ms);
    }
    _ = p.scratch.reset(.retain_capacity);
    const moved = p.backend.uiOp(p.scratch.allocator(), hwnd, host, .{ .scroll = .{ .h = .none, .v = .large_forward } }) == .ok;
    const called = flushCall(r, f, hwnd, box_key, host, null, null, "");
    w.Sleep(200);
    const read: ?f32 = switch (p.backend.uiLive(p.scratch.allocator(), hwnd, host, .all)) {
        .ok => |l| if (l.scroll) |sc| sc.v else null,
        else => null,
    };
    const end = pageInView(r, hwnd, box_key, host) orelse return;
    const kept = !std.meta.eql(start.scroll, end.scroll);
    p.print("chrome | flush | {s}scroll, then {s} | scroll {s}, call {s} | covered read {d:.1} %, in view before {d:.1} % and after {d:.1} % | {s}", .{
        if (in_view) "IN VIEW (control) " else "pending covered ",   f.label(), if (moved) "sent" else "FAILED", if (called) "ok" else "FAILED", read orelse -1, start.scroll orelse -1, end.scroll orelse -1,
        if (kept) "the scroll is kept" else "THE SCROLL WAS UNDONE",
    });
    // Back to the top for the next measure.
    _ = p.backend.uiOp(p.scratch.allocator(), hwnd, host, .{ .scroll_to = .{ .v = 0 } });
    w.Sleep(300);
}

/// US-066: the scroll test alone, with its controls: a scroll in view, a
/// pending covered scroll with no call after it, then each call that sets
/// no position.
fn pending(r: *Run) void {
    const p = r.p;
    var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
    defer arena_state.deinit();
    _ = r.call_arena.reset(.retain_capacity);
    const o = r.open(arena_state.allocator(), a23_chrome) orelse return;
    defer r.close("chrome", o);
    w.Sleep(load_ms);
    if (!r.buildInView(o.hwnd, a23_box)) return;
    const els = r.read(o.hwnd) orelse return;
    const box = pick(els, a23_box) orelse return;
    const host = p.backend.uiScrollHost(p.scratch.allocator(), o.hwnd, box.key) orelse return p.print("chrome | flush | no scroll host", .{});
    pendingScroll(r, .reread, o.hwnd, box.key, host, true);
    pendingScroll(r, .reread, o.hwnd, box.key, host, false);
    for ([_]Flush{ .scroll_noscroll, .scroll_noamount, .scroll_to }) |f| pendingScroll(r, f, o.hwnd, box.key, host, false);
}

/// US-066: on a covered Chrome whose tree was built in view, each candidate
/// call after each of 20 toggles of the A23 box, then the box read back for
/// 400 ms as `ui_act` does: how many reads equal the truth (every toggle is
/// delivered, checked in view at the end), what the call costs, and whether
/// the page's scroll position or focus moved.
fn flush(r: *Run) void {
    const p = r.p;
    var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
    defer arena_state.deinit();
    _ = r.call_arena.reset(.retain_capacity);
    const o = r.open(arena_state.allocator(), a23_chrome) orelse return;
    defer r.close("chrome", o);
    w.Sleep(load_ms);
    if (!r.buildInView(o.hwnd, a23_box)) return p.print("chrome | flush | the page's tree never showed in view: not measured", .{});
    const hwnd = o.hwnd;
    const els0 = r.read(hwnd) orelse return;
    const box = pick(els0, a23_box) orelse return;
    const box_key = box.key;
    const under = uitree.underDocument(p.scratch.allocator(), els0, false) catch return;
    var details: ?u64 = null;
    var field: ?u64 = null;
    var field_value: []const u8 = "";
    for (els0, under) |e, web| {
        if (!web) continue;
        if (details == null and e.actions.expand_collapse and std.mem.indexOf(u8, e.name, "Détails A23") != null) details = e.key;
        if (field == null and e.role == .edit and std.mem.indexOf(u8, e.name, "Champ A23") != null) {
            field = e.key;
            field_value = arena_state.allocator().dupe(u8, e.value orelse "") catch "";
        }
    }
    const host = p.backend.uiScrollHost(p.scratch.allocator(), hwnd, box_key);
    p.print("chrome | flush | scroll host of the box: {s}; <details>: {s}; text field: {s}", .{ if (host != null) "found" else "NONE", if (details != null) "found" else "NONE", if (field != null) "found" else "NONE" });

    for (std.enums.values(Flush)) |f| {
        if (p.lost) return;
        if (flush_only) |only| if (only != f) continue;
        const start = pageInView(r, hwnd, box_key, host) orelse return p.print("chrome | flush | {s} | the page cannot be read in view: not measured", .{f.label()});
        if (!r.place(hwnd, .covered, 0)) return;
        w.Sleep(settle_ms);
        var state = start.box;
        var right: u32 = 0;
        var first_right = false;
        var costs: [flush_toggles]u64 = undefined;
        var n_cost: usize = 0;
        var seq: [flush_toggles]u8 = @splat('-');
        var unsupported = false;
        for (0..flush_toggles) |i| {
            _ = r.call_arena.reset(.retain_capacity);
            _ = p.scratch.reset(.retain_capacity);
            const a = p.scratch.allocator();
            if (p.backend.uiOp(a, hwnd, box_key, .toggle) != .ok) {
                seq[i] = 'X';
                continue;
            }
            state = !state;
            const t0 = selftest.qpcUs();
            unsupported = !flushCall(r, f, hwnd, box_key, host, details, field, field_value) or unsupported;
            if (f != .reread and n_cost < costs.len) {
                costs[n_cost] = selftest.qpcUs() - t0;
                n_cost += 1;
            }
            // The read-back of `ui_act`: 400 ms at most, every 50 ms.
            const r0 = qpc();
            var ok = false;
            while (true) {
                if (liveBox(r, hwnd, box_key)) |b| if (b == state) {
                    ok = true;
                    break;
                };
                if (msSince(r0) >= 400) break;
                w.Sleep(50);
            }
            seq[i] = if (ok) 'R' else 'w';
            right += @intFromBool(ok);
            if (i == 0) first_right = ok;
            w.Sleep(100);
        }
        const end = pageInView(r, hwnd, box_key, host) orelse return;
        std.mem.sort(u64, costs[0..n_cost], {}, std.sort.asc(u64));
        const p95 = if (n_cost > 0) costs[n_cost * 95 / 100] else 0;
        const moved_scroll = !std.meta.eql(start.scroll, end.scroll);
        const moved_focus = start.focused != end.focused;
        const delivered = end.box == state;
        p.print("chrome | flush | {s} | reads equal to the truth: {d} of {d} (first after the covering: {s}) | in order {s} | call p95 {d} us | in view at the end: every toggle {s}, scroll {s}, focus {s}{s}", .{
            f.label(),                                 right,                                                           flush_toggles,                                       if (first_right) "right" else "wrong",
            seq[0..],                                  p95,                                                             if (delivered) "delivered" else "NOT ALL DELIVERED", if (moved_scroll) "MOVED" else "unchanged",
            if (moved_focus) "MOVED" else "unchanged", if (unsupported) " | the call FAILED or is unavailable" else "",
        });
        _ = p.decoy.front();
        switch (f) {
            .scroll_item, .scroll_to, .scroll_noscroll, .scroll_noamount => if (host) |h| pendingScroll(r, f, hwnd, box_key, h, false),
            else => {},
        }
    }
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, log: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    _ = env;
    var reps: usize = 10;
    var only: ?Situation = null;
    var wanted: std.ArrayList([]const u8) = .empty;
    defer wanted.deinit(gpa);
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "reps=")) {
            reps = std.fmt.parseInt(usize, arg["reps=".len..], 10) catch 0;
            if (reps < 1 or reps > max_reps) {
                log.print("occlusion-probe: reps takes 1 to {d}\n", .{max_reps}) catch {};
                return 2;
            }
        } else if (std.mem.startsWith(u8, arg, "sit=")) {
            only = std.meta.stringToEnum(Situation, arg["sit=".len..]) orelse {
                log.print("occlusion-probe: unknown situation `{s}` (visible, covered, strip, other_display, minimized)\n", .{arg["sit=".len..]}) catch {};
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "flush=")) {
            flush_only = std.meta.stringToEnum(Flush, arg["flush=".len..]) orelse {
                log.print("occlusion-probe: unknown flush candidate `{s}`\n", .{arg["flush=".len..]}) catch {};
                return 2;
            };
            try wanted.append(gpa, "flush");
        } else if (std.mem.eql(u8, arg, "chrome") or std.mem.eql(u8, arg, "vscode") or std.mem.eql(u8, arg, "wpf") or std.mem.eql(u8, arg, "a23") or std.mem.eql(u8, arg, "durable") or std.mem.eql(u8, arg, "flush") or std.mem.eql(u8, arg, "pending")) {
            try wanted.append(gpa, arg);
        } else {
            log.print("occlusion-probe: unknown argument `{s}` (chrome, vscode, wpf, a23, durable, flush, flush=NAME, pending, reps=N, sit=NAME)\n", .{arg}) catch {};
            return 2;
        }
    }
    const want = struct {
        fn f(list: []const []const u8, name: []const u8) bool {
            if (list.len == 0) return true;
            for (list) |x| if (std.mem.eql(u8, x, name)) return true;
            return false;
        }
    }.f;

    var backend: Windows = .init(gpa);
    defer backend.deinit();
    const displays = backend.displays();
    if (displays.len == 0) {
        log.print("occlusion-probe: no display enumerated\n", .{}) catch {};
        return 1;
    }
    const primary = displays[0].rect;
    const other: ?display.Rect = if (displays.len > 1) displays[1].rect else null;
    // The decoy holds the left of the primary display: the target fits
    // beside it, in view, without leaving the display.
    const area: display.Rect = .{ .x = primary.x + 40, .y = primary.y + 40, .w = @min(1300, primary.w - 80), .h = @min(1000, primary.h - 200) };
    var decoy = Decoy.start(io, area) catch |err| {
        log.print("occlusion-probe: the decoy window cannot take the foreground ({t}): run the probe from a terminal the user is not typing in\n", .{err}) catch {};
        return 1;
    };
    defer decoy.stop(io);
    var p: bg.Probe = .{ .gpa = gpa, .io = io, .log = log, .backend = &backend, .decoy = decoy, .scratch = .init(gpa), .prefix = "occlusion-probe" };
    defer p.scratch.deinit();
    defer p.stats.deinit(gpa);

    // The actions go through the dispatcher of the mode they are for.
    var server: Server = .init(gpa, io, &backend, .{ .mode = .background });
    defer server.deinit();
    backend.uiAutoFocus(false);
    var call_arena: std.heap.ArenaAllocator = .init(gpa);
    defer call_arena.deinit();
    var caller: Caller = .{ .server = &server, .arena = call_arena.allocator(), .out = .init(gpa) };
    defer caller.out.deinit();

    const frame = window.rect(decoy.hwnd) orelse area;
    var r: Run = .{ .p = &p, .caller = &caller, .call_arena = &call_arena, .reps = reps, .decoy = frame, .size = .{ @min(1100, frame.w - 160), @min(800, frame.h - 160) }, .primary = primary, .other = other };
    defer r.pids.deinit(gpa);
    p.print("decoy 0x{x} of another process in the foreground, visible frame {d},{d} {d}x{d}; target frame {d}x{d}; {d} launch(es) per situation, a cold and a warm `ui_act toggle` each, through a --mode background server; {d} display(s)", .{ @intFromPtr(decoy.hwnd), frame.x, frame.y, frame.w, frame.h, r.size[0], r.size[1], reps, displays.len });

    // A23 first (US-065): what learning may rely on.
    if (want(wanted.items, "a23") and !p.lost) a23(&r);
    if (want(wanted.items, "durable") and !p.lost) durable(&r);
    if (want(wanted.items, "flush") and !p.lost) flush(&r);
    if (want(wanted.items, "pending") and !p.lost) pending(&r);
    for (targets) |t| if (!p.lost and want(wanted.items, t.name)) {
        const app = for (bg.reference_apps) |a| {
            if (std.mem.eql(u8, a.name, t.name)) break a;
        } else continue;
        var cells: [5]Cell = @splat(.{});
        var opened = true;
        for (&cells, 0..) |*cell, i| {
            const sit: Situation = @fromBackingInt(@intCast(i));
            if (only) |o| if (o != sit) {
                cell.skipped = "not asked for";
                continue;
            };
            if (r.spot(sit, strip_px) == null) {
                cell.skipped = if (sit == .other_display) "one display only" else "the primary display is too narrow for the window beside the decoy";
                continue;
            }
            if (!opened) {
                cell.skipped = "the application could not be opened";
                continue;
            }
            for (0..reps) |rep| {
                if (p.lost) break;
                if (!r.launch(t, app, sit, cell, rep)) {
                    opened = false;
                    break;
                }
            }
        }
        if (opened and only == null and !p.lost) r.extras(t, app, cells[@backingInt(Situation.covered)].share() >= threshold_percent);
        summary(&p, t, &cells);
    };
    if (want(wanted.items, "wpf") and !p.lost) wpf(&p, .{ frame.x + 200, frame.y + 200 });
    return if (p.lost) 1 else 0;
}
