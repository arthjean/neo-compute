//! The accessibility tools on top of the backend's tree snapshot and element
//! actions: ui_tree and its deltas (US-011, US-012, US-014), ui_find and
//! ui_act (US-013), and the observation every action tool returns once the
//! screen has settled (US-015).

const std = @import("std");
const uitree = @import("uitree.zig");
const display = @import("display.zig");
const screen = @import("screen.zig");
const timing = @import("timing.zig");
const actions = @import("actions.zig");
const session = @import("session.zig");
const policy = @import("policy.zig");
const image = @import("image.zig");
const marks = @import("marks.zig");
const Result = @import("mcp.zig").Result;
const fmt = session.fmt;

pub const Observe = session.Observe;
pub const default_settle_ms = 1500;
pub const max_settle_ms = 10_000;
/// The screen is settled when no dirty rect shows up for this long.
const quiet_ms = 50;
const max_find_lines = 20;
const max_text_output = 8000; // FR-16
const oom = "Mémoire insuffisante : réessaie.";

/// A snapshot with, per root, the mapping of the display it sits on and the
/// part of it on that display (US-023: each root in its own display's
/// screenshot space, FR-03).
const Snap = struct {
    snap: uitree.Snapshot,
    roots: []const uitree.Root,
    maps: []const display.Mapping,
    viewports: []const display.Rect,

    /// Root index of element `index`.
    fn rootOf(s: *const Snap, index: u32) usize {
        var r: usize = 0;
        while (r + 1 < s.roots.len and s.roots[r + 1].start <= index) r += 1;
        return r;
    }
};

const intersection = display.intersection;

/// Snapshot of `window` (the foreground window when null) and the mapping of
/// the display it sits on. With `record`, the mapping becomes the space of
/// incoming coordinates, like a screenshot's (FR-03). Post-action deltas do
/// not record it: a click aimed from a screenshot of another display must
/// keep that display's space.
fn snapshot(ctx: anytype, window: ?u64, record: bool, text: bool) union(enum) { ok: Snap, err: []const u8 } {
    // A `deny` application is absent from the tree (US-017): it is never
    // read. A post-action observation is not a request of its own and
    // leaves the action's audit target alone.
    const ref = if (window) |h| ctx.backend.windowRef(h) else ctx.backend.windowAt(null);
    if (record) {
        if (policy.require(ctx, ref, .observe)) |r| return .{ .err = r.blocks[0].text };
    } else if (ref) |r| if (policy.hidden(ctx, r)) |msg| return .{ .err = msg };
    ctx.timings.start(ctx.io, .accessibility);
    const extras = extraRoots(ctx, window);
    const res = ctx.backend.uiSnapshot(ctx.arena, window, .{ .extra_roots = extras, .text = text });
    ctx.timings.stop(ctx.io, .accessibility);
    const snap = switch (res) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    if (snap.elements.len == 0) return .{ .err = "Arbre d'accessibilité vide : utilise screenshot pour cette fenêtre." };
    const displays = ctx.backend.displays();
    if (displays.len == 0) return .{ .err = "Aucun écran détecté : vérifie qu'un écran est allumé, puis réessaie." };
    const roots = if (snap.roots.len > 0) snap.roots else blk: {
        const one = ctx.arena.alloc(uitree.Root, 1) catch return .{ .err = oom };
        one[0] = .{ .start = 0, .handle = snap.window };
        break :blk one;
    };
    const maps = ctx.arena.alloc(display.Mapping, roots.len) catch return .{ .err = oom };
    const viewports = ctx.arena.alloc(display.Rect, roots.len) catch return .{ .err = oom };
    for (roots, maps, viewports) |root, *m, *vp| {
        const r = snap.elements[root.start].rect;
        const index = @min(display.displayAt(displays, r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h, 2)) orelse 0, display.max_displays - 1, displays.len - 1);
        m.* = display.Mapping.of(index, displays[index].rect, ctx.session.long_side);
        vp.* = intersection(r, displays[index].rect) orelse r;
    }
    if (record) {
        // Every root's display is mapped; the window's stays the space of
        // incoming coordinates.
        for (maps[1..]) |m| ctx.session.shots[m.display] = m;
        ctx.session.recordShot(maps[0]);
    }
    return .{ .ok = .{ .snap = snap, .roots = roots, .maps = maps, .viewports = viewports } };
}

/// The windows read along with `window` (US-023): what the backend lists,
/// minus the `deny` applications, which are never read (US-017).
fn extraRoots(ctx: anytype, window: ?u64) []const uitree.RootWindow {
    const listed = ctx.backend.uiRoots(ctx.arena, window);
    if (listed.len == 0) return listed;
    const kept = ctx.arena.alloc(uitree.RootWindow, listed.len) catch return &.{};
    var n: usize = 0;
    for (listed) |r| if (policy.resolve(ctx, .{ .handle = r.handle, .pid = r.pid }).level != .deny) {
        kept[n] = r;
        n += 1;
    };
    return kept[0..n];
}

// ---------------------------------------------------------------- ui_tree

/// `ui_tree`: the pruned tree of `window`, or with `since_last` only what
/// changed since the last tree of that window. With `text`, a web page's
/// visible text nodes too (US-024); with `with_marks`, the screenshot of the
/// root's display with each actionable element's id drawn on it (US-031).
pub fn tree(ctx: anytype, window: ?u64, since_last: bool, text: bool, with_marks: bool) Result {
    if (!with_marks) return treeOf(ctx, window, since_last, true, text);
    const s = switch (snapshot(ctx, window, true, text)) {
        .ok => |s| s,
        .err => |e| return Result.err(e),
    };
    var labels: std.ArrayList(marks.Label) = .empty;
    const r = treeText(ctx, s, window == null, since_last, &labels) catch return Result.err(oom);
    return markedTree(ctx, s, r, labels.items) catch Result.err(oom);
}

fn treeOf(ctx: anytype, window: ?u64, since_last: bool, record: bool, text: bool) Result {
    const s = switch (snapshot(ctx, window, record, text)) {
        .ok => |s| s,
        .err => |e| return Result.err(e),
    };
    return treeText(ctx, s, window == null, since_last, null) catch Result.err(oom);
}

/// An element worth a label: one with an action `ui_act` runs. ScrollItem
/// alone does not count, as in the pruning: providers put it everywhere.
fn markable(e: uitree.Element) bool {
    const a = e.actions;
    return a.invoke or a.value or a.toggle or a.expand_collapse or a.select;
}

/// Completes `ui_tree`'s text with the marked screenshot (US-031): the
/// password fields of every root are blacked out with the scanned ones and
/// the `deny` windows before the labels are drawn.
fn markedTree(ctx: anytype, s: Snap, r: Result, labels: []const marks.Label) !Result {
    if (r.is_error) return r;
    var secrets: std.ArrayList(display.Rect) = .empty;
    for (s.snap.elements) |e| if (e.password and !e.states.offscreen) try secrets.append(ctx.arena, e.rect);
    const text = r.blocks[0].text;
    // A complete snapshot of the foreground window already lists its
    // password fields: the scan would read them a second time.
    const fg = ctx.backend.windowAt(null);
    const scan = s.snap.partial or s.snap.web_pending or fg == null or fg.?.handle != s.snap.window;
    const shot = switch (screen.marked(ctx, s.maps[0], labels, secrets.items, scan)) {
        .ok => |o| o,
        .err => |e| return Result.text(try std.fmt.allocPrint(ctx.arena, "{s}\nImage indisponible : {s}", .{ text, e })),
    };
    var out: Result = .{ .len = 2 };
    var w: std.Io.Writer.Allocating = .init(ctx.arena);
    try w.writer.writeAll(text);
    if (labels.len == 0) {
        try w.writer.writeAll("\nAucun élément actionnable à marquer");
    } else if (shot.drawn < labels.len) {
        try w.writer.print("\n… {d} étiquettes omises (place prise ou plus de {d})", .{ labels.len - shot.drawn, marks.max_labels });
    }
    if (shot.gdi) try w.writer.writeAll("\n" ++ screen.gdi_note);
    out.blocks[0] = .{ .text = w.written() };
    out.blocks[1] = shot.image;
    return out;
}

/// Kept elements of every root, in order, with the root of each.
const Pruned = struct { kept: []const uitree.Kept, root_of: []const u16 };

/// Prunes each root on its own viewport, within one node budget.
fn pruneRoots(a: std.mem.Allocator, s: Snap) !Pruned {
    const els = s.snap.elements;
    const text = s.snap.web_text == .read;
    if (s.roots.len == 1) {
        const kept = try uitree.prune(a, els, s.viewports[0], .{ .text = text });
        const root_of = try a.alloc(u16, kept.len);
        @memset(root_of, 0);
        return .{ .kept = kept, .root_of = root_of };
    }
    var kept: std.ArrayList(uitree.Kept) = .empty;
    var root_of: std.ArrayList(u16) = .empty;
    var budget: usize = (uitree.Limits{}).nodes;
    for (s.roots, 0..) |root, ri| {
        if (budget == 0) break;
        const end = s.snap.rootEnd(s.roots, ri);
        const part = try uitree.prune(a, els[root.start..end], s.viewports[ri], .{ .nodes = budget, .text = text });
        for (part) |k| {
            try kept.append(a, .{ .index = k.index + root.start, .depth = k.depth });
            try root_of.append(a, @intCast(ri));
        }
        budget -= part.len;
    }
    return .{ .kept = kept.items, .root_of = root_of.items };
}

/// The tree's text; `labels`, when given, receives one label per actionable
/// element shown on the root's display, in tree order.
fn treeText(ctx: anytype, s: Snap, foreground: bool, since_last: bool, labels: ?*std.ArrayList(marks.Label)) !Result {
    const a = ctx.arena;
    const gpa = ctx.session.gpa;
    const ui = &ctx.session.ui;
    const els = s.snap.elements;
    const win = s.snap.window;
    const p = try pruneRoots(a, s);
    const ids = try a.alloc(u32, p.kept.len);
    const shown = try a.alloc(uitree.Shown, p.kept.len);
    for (p.kept, p.root_of, 0..) |k, ri, i| {
        ids[i] = try ui.ids.assignIn(gpa, els[k.index].key, s.roots[ri].handle, win);
        shown[i] = uitree.shownOf(ids[i], els[k.index], s.maps[ri]);
    }
    const handles = try a.alloc(u64, s.roots.len);
    for (s.roots, handles) |r, *h| h.* = r.handle;
    if (labels) |out| {
        const on = s.maps[0];
        for (p.kept, p.root_of, ids) |k, ri, id| {
            const e = els[k.index];
            if (!markable(e) or e.states.offscreen or s.maps[ri].display != on.display or !e.rect.intersects(on.rect)) continue;
            try out.append(a, marks.Label.of(id, on.rectToScreenshot(e.rect)));
        }
    }

    var note: ?[]const u8 = null;
    var delta: ?[]const u8 = null;
    if (since_last) {
        const last = ui.store.last_window;
        if (foreground and last != null and last.? != win) {
            note = "Fenêtre au premier plan changée : arbre complet de la nouvelle fenêtre.";
        } else if (ui.store.getLast(win)) |prev| {
            ctx.timings.start(ctx.io, .diff);
            const d = uitree.diff(a, prev.nodes, shown);
            ctx.timings.stop(ctx.io, .diff);
            delta = try deltaText(a, s, p, shown, try d, prev.roots);
        } else note = "Aucun arbre précédent de cette fenêtre : arbre complet.";
    }
    const full = try fullText(a, s, p, ids, els.len, note);
    try ui.store.putRoots(gpa, win, shown, handles);
    if (delta) |d| if (d.len <= full.len) return Result.text(d);
    return Result.text(full);
}

fn writeFlags(w: *std.Io.Writer, snap: uitree.Snapshot) !void {
    if (snap.partial) try w.writeAll("{partial: timeout}\n");
    if (snap.desktop) try w.writeAll("Aucune fenêtre active : arbre du bureau renvoyé\n");
}

fn fullText(a: std.mem.Allocator, s: Snap, p: Pruned, ids: []const u32, total: usize, note: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try writeFlags(w, s.snap);
    if (note) |n| try w.print("{s}\n", .{n});
    var shown: usize = 0;
    var current: ?u16 = null;
    const text = s.snap.web_text == .read;
    var page_shown = false;
    for (p.kept, p.root_of, ids) |k, ri, id| {
        const mark = out.written().len;
        // Each root opens with its header (US-023).
        if (current != ri) {
            try uitree.writeRootHeader(w, s.maps[ri], s.roots[ri]);
            try w.writeByte('\n');
            current = ri;
        }
        const e = s.snap.elements[k.index];
        // A web page's text (US-024): longer text lines, the page position
        // on its document's line.
        const name_max: usize = if (text and uitree.textLine(e)) uitree.max_text_chars else 80;
        const page = if (text and !page_shown and e.role == .document) s.snap.page else null;
        if (page != null) page_shown = true;
        try uitree.writeLineMax(w, k.depth, id, e, s.maps[ri], name_max, page);
        if (out.written().len > max_text_output - 160) {
            out.shrinkRetainingCapacity(mark);
            break;
        }
        shown += 1;
    }
    if (total > shown) try w.print("… {d} nœuds élagués\n", .{total - shown});
    if (text and shown < p.kept.len) {
        var omitted: usize = 0;
        for (p.kept[shown..]) |k| omitted += @intFromBool(uitree.textLine(s.snap.elements[k.index]));
        if (omitted > 0) try w.print("… {d} lignes de texte omises : fais défiler puis rappelle ui_tree\n", .{omitted});
    }
    if (s.snap.firefox_no_tree) {
        try w.writeAll("Firefox n'expose pas son arbre d'accessibilité : vérifie accessibility.force_disabled ou utilise screenshot\n");
    } else if (s.snap.web_pending) {
        try w.writeAll("Contenu web pas encore exposé (Chromium le construit à la première lecture) : rappelle ui_tree dans 1 s, ou utilise screenshot.\n");
    } else if (s.snap.web_text == .no_document) {
        try w.writeAll("Aucun document web dans cette fenêtre : texte non disponible\n");
    } else if (p.kept.len <= 2) {
        // Electron apps without accessibility expose a bare window.
        try w.writeAll("Arbre presque vide (fréquent avec Electron) : utilise screenshot pour voir cette fenêtre.\n");
    }
    return std.mem.trimEnd(u8, out.written(), "\n");
}

fn contains(list: []const u64, x: u64) bool {
    return std.mem.findScalar(u64, list, x) != null;
}

/// Changes since the last tree. A root that appeared opens with `+ ` and
/// its header, one that vanished is `- window=0x<handle>`; the elements of
/// a further root follow its header, in its display's space (US-023).
fn deltaText(a: std.mem.Allocator, s: Snap, p: Pruned, shown: []const uitree.Shown, d: uitree.Delta, prev_roots: []const u64) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try writeFlags(w, s.snap);
    try uitree.writeRootHeader(w, s.maps[0], s.roots[0]);
    var roots_changed = false;
    for (s.roots) |r| roots_changed = roots_changed or !contains(prev_roots, r.handle);
    for (prev_roots) |h| {
        const still = for (s.roots) |r| {
            if (r.handle == h) break true;
        } else false;
        roots_changed = roots_changed or !still;
    }
    if (d.entries.len == 0 and d.removed.len == 0 and !roots_changed) {
        try w.writeAll(" delta: aucun changement");
        return out.written();
    }
    var added: usize = 0;
    for (d.entries) |e| added += @intFromBool(e.kind == .added);
    try w.print(" delta +{d} -{d} ~{d}\n", .{ added, d.removed.len, d.entries.len - added });
    const opened = try a.alloc(bool, s.roots.len);
    @memset(opened, false);
    opened[0] = true;
    for (d.entries) |e| {
        const ri = p.root_of[e.index];
        if (!opened[ri]) {
            if (!contains(prev_roots, s.roots[ri].handle)) try w.writeAll("+ ");
            try uitree.writeRootHeader(w, s.maps[ri], s.roots[ri]);
            try w.writeByte('\n');
            opened[ri] = true;
        }
        try w.writeAll(if (e.kind == .added) "+ " else "~ ");
        try uitree.writeLine(w, 0, shown[e.index].id, s.snap.elements[p.kept[e.index].index], s.maps[ri]);
    }
    for (s.roots, opened, s.maps) |r, o, m| if (!o and !contains(prev_roots, r.handle)) {
        try w.writeAll("+ ");
        try uitree.writeRootHeader(w, m, r);
        try w.writeByte('\n');
    };
    for (prev_roots) |h| {
        const still = for (s.roots) |r| {
            if (r.handle == h) break true;
        } else false;
        if (!still) try w.print("- window=0x{x}\n", .{h});
    }
    for (d.removed) |r| {
        try w.writeAll("- ");
        try uitree.writeId(w, r.id);
        try w.print(" {t}\n", .{r.role});
    }
    return std.mem.trimEnd(u8, out.written(), "\n");
}

// ---------------------------------------------------------------- ui_find

/// Longest wait of `ui_find` (US-030).
pub const max_wait_ms = 30_000;
/// While waiting, a change on screen starts a new search at most this often,
/// and without any change one runs this often anyway (US-030).
const research_min_ms = 100;
const research_max_ms = 1000;
/// Interval between two looks for changes while waiting: a DXGI capture
/// with nothing new returns at once, so this costs well under 1 % of a core.
const wait_poll_ms = 20;
/// Area a GDI look copies every `research_min_ms`: a larger window is looked
/// at less often, one more `research_min_ms` per such area (US-030, US-032).
/// A BitBlt of a whole 2560x1440 display costs 2 to 7 ms of CPU depending
/// on the GPU and DWM, so a maximized window looked at every 100 ms took
/// 2 to 7 % of a core; every 200 ms keeps it under the 5 % budget.
const gdi_look_area = 1920 * 1080;

/// Interval until the next look for changes after `frame`: DXGI's are free
/// when nothing changed; a GDI look copies the window's area.
fn lookMs(frame: display.Frame) u64 {
    if (frame.source != .gdi) return wait_poll_ms;
    const area = @as(u64, frame.width) * frame.height;
    return research_min_ms * @max(1, std.math.divCeil(u64, area, gdi_look_area) catch 1);
}

test "a GDI look waits 100 ms per 1920x1080 of window, a DXGI look 20 ms" {
    const gdi = struct {
        fn of(w: u32, h: u32) display.Frame {
            return .{ .pixels = &.{}, .width = w, .height = h, .stride = 0, .source = .gdi };
        }
    }.of;
    try std.testing.expectEqual(@as(u64, 100), lookMs(gdi(480, 320)));
    try std.testing.expectEqual(@as(u64, 100), lookMs(gdi(1920, 1080)));
    try std.testing.expectEqual(@as(u64, 200), lookMs(gdi(2560, 1440)));
    try std.testing.expectEqual(@as(u64, 300), lookMs(gdi(3840, 1600)));
    try std.testing.expectEqual(@as(u64, 20), lookMs(.{ .pixels = &.{}, .width = 2560, .height = 1440, .stride = 0 }));
}

/// `ui_find`: elements of `window` matching `query`, at most 20 lines in the
/// ui_tree format. Off-screen elements are included (scroll_into_view).
/// With `wait_ms`, searches again until a match or the deadline (US-030).
pub fn find(ctx: anytype, query: []const u8, window: ?u64, wait_ms: u32) Result {
    const q = switch (uitree.Query.parse(ctx.arena, query) catch return Result.err(oom)) {
        .ok => |q| q,
        .err => |e| return Result.err(e),
    };
    if (wait_ms > 0) return findWaiting(ctx, q, query, window, wait_ms);
    const s = switch (snapshot(ctx, window, true, false)) {
        .ok => |s| s,
        .err => |e| return Result.err(e),
    };
    const found = findText(ctx, q, query, s, null) catch return Result.err(oom);
    return found.result;
}

/// Searches at once, then again after a change near the target window (a
/// DXGI dirty or move rect, or a new fingerprint under GDI), a move of that
/// window or a new top-level window, at most every 100 ms and at least every
/// second, until a match or `wait_ms`. Not an action: it runs while paused,
/// like `wait`, and stops at its next checkpoint once cancelled. Each search
/// gets a scratch arena reset before the next, so a 30 s wait holds one
/// snapshot at a time.
fn findWaiting(ctx: anytype, q: uitree.Query, query: []const u8, window: ?u64, wait_ms: u32) Result {
    const ms = std.time.ns_per_ms;
    const start = timing.now(ctx.io);
    const deadline = start + @as(i96, wait_ms) * ms;
    const request_arena = ctx.arena;
    var scratch: std.heap.ArenaAllocator = .init(request_arena);
    ctx.arena = scratch.allocator();
    defer ctx.arena = request_arena;
    var watch: Watch = .{};
    // A GDI look copies the window's area with BitBlt: it runs only as
    // often as a search may, and less often for a large window (`lookMs`).
    var poll_ms: u64 = wait_poll_ms;
    while (true) {
        _ = scratch.reset(.retain_capacity);
        // The state the search sees: a change from now on calls for another.
        // The look taken here drains the dirty rects from before the search
        // and gives GDI its first fingerprint, so neither starts a search
        // of its own.
        const before = Watch.target(ctx, window);
        var area = before.area;
        var stamp = ctx.backend.topWindowStamp();
        switch (Watch.look(ctx, before)) {
            .failed => {},
            .frame => |f| {
                poll_ms = lookMs(f);
                _ = watch.changed(ctx, f, before.index, before.area);
            },
        }
        const searched = timing.now(ctx.io);
        const s = switch (snapshot(ctx, window, true, false)) {
            .ok => |s| s,
            .err => |e| return Result.err(request_arena.dupe(u8, e) catch oom),
        };
        const elapsed: u64 = @intCast(@divTrunc(@max(timing.now(ctx.io) - start, 0), ms));
        const found = findText(ctx, q, query, s, elapsed) catch return Result.err(oom);
        if (found.matched > 0) return Result.text(request_arena.dupe(u8, found.result.blocks[0].text) catch oom);
        // Watch until the next search is due.
        var pending = false;
        while (true) {
            const t = timing.now(ctx.io);
            if (t >= deadline) {
                if (pending) break;
                return Result.err(fmt(request_arena, "Aucun élément « {s} » après {d} ms : vérifie la requête ou augmente wait_ms", .{ query, wait_ms }));
            }
            if (t - searched >= research_max_ms * ms or (pending and t - searched >= research_min_ms * ms)) break;
            const left: u64 = @intCast(deadline - t);
            if (!ctx.sleep(@min(poll_ms * ms, left))) return Result.err("ui_find annulé");
            const at = Watch.target(ctx, window);
            const now_stamp = ctx.backend.topWindowStamp();
            if (!sameRect(area, at.area) or now_stamp != stamp) pending = true;
            area = at.area;
            stamp = now_stamp;
            switch (Watch.look(ctx, at)) {
                // Without a capture (secure desktop), only the window and
                // the one-second searches remain.
                .failed => {},
                .frame => |f| {
                    poll_ms = lookMs(f);
                    if (watch.changed(ctx, f, at.index, at.area)) pending = true;
                },
            }
        }
    }
}

fn sameRect(a: ?display.Rect, b: ?display.Rect) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

const Found = struct { result: Result, matched: usize };

/// The matching lines; with `found_after` (a wait), headed by
/// `found after <n> ms`.
fn findText(ctx: anytype, q: uitree.Query, query: []const u8, s: Snap, found_after: ?u64) !Found {
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &out.writer;
    if (found_after) |n| try w.print("found after {d} ms\n", .{n});
    try writeFlags(w, s.snap);
    try uitree.writeRootHeader(w, s.maps[0], s.roots[0]);
    try w.writeByte('\n');
    var matched: usize = 0;
    var current: usize = 0;
    for (s.snap.elements, 0..) |e, i| {
        if (!try q.matches(ctx.arena, e)) continue;
        matched += 1;
        if (matched > max_find_lines) continue;
        const ri = s.rootOf(@intCast(i));
        if (ri != current) {
            try uitree.writeRootHeader(w, s.maps[ri], s.roots[ri]);
            try w.writeByte('\n');
            current = ri;
        }
        const id = try ctx.session.ui.ids.assignIn(ctx.session.gpa, e.key, s.roots[ri].handle, s.snap.window);
        try uitree.writeLine(w, 0, id, e, s.maps[ri]);
    }
    if (matched == 0) try w.print("Aucun élément ne correspond à `{s}` : essaie un autre nom, role:<rôle>, state:<état> ou ui_tree.\n", .{query});
    if (matched > max_find_lines) try w.print("… {d} autres résultats : précise la requête.\n", .{matched - max_find_lines});
    return .{ .result = Result.text(std.mem.trimEnd(u8, out.written(), "\n")), .matched = matched };
}

// ---------------------------------------------------------------- ui_act

fn patternName(action: uitree.Action) []const u8 {
    return switch (action) {
        .invoke => "Invoke",
        .toggle => "Toggle",
        .select => "SelectionItem",
        .expand, .collapse => "ExpandCollapse",
        .set_value => "Value",
        .focus => "Focus",
        .scroll_into_view => "ScrollItem",
    };
}

/// Window whose tree listed the element `id_text`, for the post-action
/// observation: a menu item's window closes once the item is used.
pub fn windowOf(ctx: anytype, id_text: []const u8) ?u64 {
    const id = uitree.parseId(id_text) orelse return null;
    return if (ctx.session.ui.ids.owner(id)) |o| o.tree else null;
}

/// `ui_act`: runs `action` on element `id_text` through its pattern, after
/// the backend checked it exists, is enabled, on screen and supports it.
/// The value of `set_value` never appears in the result (FR-09).
pub fn act(ctx: anytype, id_text: []const u8, action: uitree.Action, value: ?[]const u8, fallback_click: bool) Result {
    const id = uitree.parseId(id_text) orelse
        return Result.err(fmt(ctx.arena, "Identifiant `{s}` invalide : utilise un id de ui_tree ou ui_find (ex. e1k). Aucune action exécutée.", .{id_text}));
    const name = std.mem.trim(u8, id_text, " ");
    const gone = fmt(ctx.arena, "Élément {s} introuvable : rappelle ui_tree", .{name});
    const owner = ctx.session.ui.ids.owner(id) orelse return Result.err(gone);
    if (action == .set_value and value == null)
        return Result.err("set_value demande le champ `value` : le texte à écrire. Aucune action exécutée.");
    // Writing a value is typing; every other pattern is a click (US-017).
    if (policy.requireWindow(ctx, owner.window, if (action == .set_value) .full else .click)) |r| return r;
    ctx.timings.start(ctx.io, .accessibility);
    const r = ctx.backend.uiAct(ctx.arena, owner.window, owner.key, action, value);
    ctx.timings.stop(ctx.io, .accessibility);
    return switch (r) {
        .ok => Result.text(fmt(ctx.arena, "ok : {t} {s}", .{ action, name })),
        .timeout => Result.text(fmt(ctx.arena, "{t} envoyé à {s}, mais l'application n'a pas répondu dans le délai UIA : vérifie son état.", .{ action, name })),
        .gone => Result.err(gone),
        .disabled => Result.err(fmt(ctx.arena, "Précondition non remplie : {s} est désactivé. Aucune action exécutée.", .{name})),
        .offscreen => Result.err(fmt(ctx.arena, "Précondition non remplie : {s} est hors écran. Fais d'abord scroll_into_view. Aucune action exécutée.", .{name})),
        .read_only => Result.err(fmt(ctx.arena, "Précondition non remplie : {s} est en lecture seule. Aucune action exécutée.", .{name})),
        .unsupported => |rect| if (fallback_click)
            clickCenter(ctx, rect, action, name)
        else
            Result.err(fmt(ctx.arena, "Précondition non remplie : {s} ne supporte pas {t} (pattern {s} absent). Essaie une autre action ou fallback: \"click\". Aucune action exécutée.", .{ name, action, patternName(action) })),
        .failed => |msg| Result.err(msg),
    };
}

fn clickCenter(ctx: anytype, rect: display.Rect, action: uitree.Action, name: []const u8) Result {
    if (rect.w <= 0 or rect.h <= 0)
        return Result.err(fmt(ctx.arena, "Pattern {s} absent sur {s} et rectangle vide : clic de repli impossible. Aucune action exécutée.", .{ patternName(action), name }));
    const p = [2]i32{ rect.x + @divTrunc(rect.w, 2), rect.y + @divTrunc(rect.h, 2) };
    if (ctx.backend.targetAt(p) == .elevated) return Result.err(actions.uipi_message);
    ctx.backend.sendMouse(&.{ .{ .move = p }, .{ .down = .left }, .{ .up = .left } }) catch
        return Result.err("Injection refusée par Windows (bureau sécurisé, verrouillage ou session inactive) : réessaie quand le bureau est accessible.");
    return Result.text(fmt(ctx.arena, "Pattern {s} absent sur {s} : clic gauche injecté au centre de l'élément (fallback).", .{ patternName(action), name }));
}

// ---------------------------------------------------------------- settle and observe

pub const Settled = union(enum) { settled: u64, timeout, unavailable: []const u8, cancelled };

fn touches(rects: []const display.Rect, area: ?display.Rect) bool {
    const a = area orelse return rects.len > 0;
    for (rects) |r| if (r.intersects(a)) return true;
    return false;
}

/// Interval between two GDI captures while settling: without dirty rects,
/// two equal fingerprints this far apart mean a still screen (US-032).
const gdi_interval_ms = 50;

/// Whether the screen changed around a window between successive captures:
/// a DXGI frame's dirty and move rects, else (GDI) the fingerprint of the
/// area compared with the previous capture's (US-032).
const Watch = struct {
    fingerprint: ?u64 = null,

    /// The target window's rectangle (`window`, else the foreground one,
    /// read again on every look so a dialog that opens counts) and the
    /// display it sits on.
    fn target(ctx: anytype, window: ?u64) Target {
        const area = ctx.backend.windowRect(window);
        const displays = ctx.backend.displays();
        const index = if (area) |a| display.displayAt(displays, a.x + @divTrunc(a.w, 2), a.y + @divTrunc(a.h, 2)) orelse 0 else ctx.backend.foregroundDisplay() orelse 0;
        return .{ .area = area, .index = index };
    }

    const Target = struct { area: ?display.Rect, index: usize };

    /// What changed on the target's display. Under GDI the backend copies
    /// only the target's area, which is all a fingerprint reads: at
    /// 2560x1440 a whole display costs about 20 ms of BitBlt, a window a
    /// fraction of it (US-030 CPU budget).
    fn look(ctx: anytype, at: Target) display.CaptureResult {
        return ctx.backend.changes(at.index, ctx.arena, at.area);
    }

    /// Changes in `area` since the previous call. Changes elsewhere, such as
    /// the client's own spinner in its terminal, are ignored. The first GDI
    /// frame counts as a change: nothing to compare it with yet.
    fn changed(self: *Watch, ctx: anytype, frame: display.Frame, index: usize, area: ?display.Rect) bool {
        if (frame.source == .dxgi) return frame.fresh and (touches(frame.dirty, area) or touches(frame.moved, area));
        // A copy of the area alone: the whole frame is the area.
        const whole: display.Rect = .{ .x = 0, .y = 0, .w = @intCast(frame.width), .h = @intCast(frame.height) };
        if (frame.area != null) return self.differs(image.fingerprint(frame.pixels, frame.stride, frame.width, frame.height, whole));
        const displays = ctx.backend.displays();
        const origin: display.Rect = if (index < displays.len) displays[index].rect else .{ .x = 0, .y = 0, .w = @intCast(frame.width), .h = @intCast(frame.height) };
        const local = if (area) |a| if (intersection(a, origin)) |r| display.Rect{ .x = r.x - origin.x, .y = r.y - origin.y, .w = r.w, .h = r.h } else whole else whole;
        return self.differs(image.fingerprint(frame.pixels, frame.stride, frame.width, frame.height, local));
    }

    fn differs(self: *Watch, f: u64) bool {
        defer self.fingerprint = f;
        return self.fingerprint == null or self.fingerprint.? != f;
    }
};

/// Waits until no dirty rect touches the target window (`window`, else the
/// foreground one) on two captures at least 50 ms apart, or until
/// `timeout_ms`. A GDI capture has no dirty rects: two captures 50 ms apart
/// with the same fingerprint of the window's area are settled (US-032).
/// Timed as the `settle` stage, apart from the capture budgets.
pub fn settle(ctx: anytype, timeout_ms: u32, window: ?u64) Settled {
    ctx.timings.start(ctx.io, .settle);
    defer ctx.timings.stop(ctx.io, .settle);
    const start = timing.now(ctx.io);
    const ms = std.time.ns_per_ms;
    var quiet_since: ?i96 = null;
    var watch: Watch = .{};
    while (true) {
        const at = Watch.target(ctx, window);
        const frame = switch (Watch.look(ctx, at)) {
            .frame => |f| f,
            .failed => |msg| return .{ .unavailable = msg },
        };
        const t = timing.now(ctx.io);
        const gdi = frame.source == .gdi;
        if (watch.changed(ctx, frame, at.index, at.area)) {
            quiet_since = null;
        } else if (gdi) {
            return .{ .settled = @intCast(@divTrunc(t - start, ms)) };
        } else if (quiet_since) |q| {
            if (t - q >= quiet_ms * ms) return .{ .settled = @intCast(@divTrunc(t - start, ms)) };
        } else quiet_since = t;
        if (t - start >= @as(i96, timeout_ms) * ms) return .timeout;
        if (!ctx.sleep(@as(u64, if (gdi) gdi_interval_ms else 10) * ms)) return .cancelled;
    }
}

/// Completes the result of an action tool with the requested observation
/// (`observe`, default delta, screenshot in vision mode) once the screen has
/// settled. A failed action, or `observe: "none"`, returns as is.
pub fn observeAfter(ctx: anytype, r: Result, observe: ?Observe, settle_timeout_ms: ?u32, window: ?u64) Result {
    return observeWith(ctx, r, observe, settle_timeout_ms, window, false);
}

/// `observeAfter` whose `delta` is the full tree when `full` (app_launch
/// returns the whole tree of the window it opened, US-029).
pub fn observeWith(ctx: anytype, r: Result, observe: ?Observe, settle_timeout_ms: ?u32, window: ?u64, full: bool) Result {
    if (r.is_error or r.len == 0 or r.blocks[0] != .text) return r;
    const mode = observe orelse ctx.session.default_observe;
    if (mode == .none) return r;
    const status = switch (settle(ctx, settle_timeout_ms orelse default_settle_ms, window)) {
        .settled => |n| fmt(ctx.arena, "settled in {d} ms", .{n}),
        .timeout => "settle timeout",
        .unavailable => |msg| fmt(ctx.arena, "settle indisponible ({s})", .{msg}),
        .cancelled => return r,
    };
    const done = r.blocks[0].text;
    switch (mode) {
        .none => unreachable,
        .delta => {
            const obs = treeOf(ctx, window, !full, false, false);
            const body = obs.blocks[0].text;
            if (obs.is_error) return Result.text(fmt(ctx.arena, "{s} ; {s}\nObservation indisponible : {s}", .{ done, status, body }));
            return Result.text(fmt(ctx.arena, "{s} ; {s}\n{s}", .{ done, status, body }));
        },
        .screenshot => {
            var shot = screen.screenshot(ctx, null);
            if (shot.is_error) return Result.text(fmt(ctx.arena, "{s} ; {s}\nObservation indisponible : {s}", .{ done, status, shot.blocks[0].text }));
            shot.blocks[1] = .{ .text = fmt(ctx.arena, "{s} ; {s}\n{s}", .{ done, status, shot.blocks[1].text }) };
            return shot;
        },
    }
}
