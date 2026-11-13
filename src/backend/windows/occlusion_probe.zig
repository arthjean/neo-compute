//! `neo-compute occlusion-probe [chrome|vscode|wpf]... [reps=N] [sit=NAME]`
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
//! window within the second that follows its creation. Lines go to stderr;
//! no element name of a live application is printed.

const std = @import("std");
const w = @import("win32");
const Windows = @import("../windows.zig").Windows;
const uitree = @import("../../core/uitree.zig");
const display = @import("../../core/display.zig");
const mcp = @import("../../core/mcp.zig");
const tools = @import("../../core/tools.zig");
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
        } else if (std.mem.eql(u8, arg, "chrome") or std.mem.eql(u8, arg, "vscode") or std.mem.eql(u8, arg, "wpf")) {
            try wanted.append(gpa, arg);
        } else {
            log.print("occlusion-probe: unknown argument `{s}` (chrome, vscode, wpf, reps=N, sit=NAME)\n", .{arg}) catch {};
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
