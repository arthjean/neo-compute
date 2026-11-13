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

pub const target_missing = "Aucune fenêtre cible : passe window (handle de window_list) ou lance l'application avec app_launch.";
pub const target_closed = "Fenêtre cible fermée : rappelle window_list";

/// Makes `window` the session's target (US-042): the window a later call
/// without `window` works on in background mode.
pub fn setTarget(ctx: anytype, window: u64) void {
    ctx.session.target = window;
}

/// Longest wait for Windows to name a foreground window again.
const front_wait_ms = 200;
const front_poll_ms = 10;

/// Whether `window` came in front of the user since `before` was read
/// (US-043): an application that activated itself whatever the launch or
/// the state change asked. Windows names no foreground window while it
/// switches from one to the next (US-040 saw it as Notepad opened a
/// document), so a read without one is made again, for 200 ms at most.
pub fn cameInFront(ctx: anytype, window: u64, before: ?u64) bool {
    const b = before orelse return if (ctx.backend.foregroundWindow()) |fg| fg == window else false;
    if (b == window) return false;
    var waited: u32 = 0;
    while (true) : (waited += front_poll_ms) {
        if (ctx.backend.foregroundWindow()) |fg| return fg == window;
        if (waited >= front_wait_ms or !ctx.sleep(front_poll_ms * std.time.ns_per_ms)) return false;
    }
}

/// The window a tool reads: `window`, which becomes the session's target,
/// else the foreground window (null). In background mode the foreground
/// window is the user's: a call without `window` reads the target, and
/// says so when there is none or when it was closed.
pub fn resolveWindow(ctx: anytype, window: ?u64) union(enum) { ok: ?u64, err: []const u8 } {
    if (window) |h| {
        if (ctx.backend.windowRef(h) != null) setTarget(ctx, h);
        return .{ .ok = h };
    }
    if (!ctx.session.background) return .{ .ok = null };
    const t = ctx.session.target orelse return .{ .err = target_missing };
    if (ctx.backend.windowRef(t) == null) {
        ctx.session.target = null;
        return .{ .err = target_closed };
    }
    return .{ .ok = t };
}

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
    // Background mode (US-042): only the target's own process. A menu open
    // in the application the user works in is theirs, not the target's.
    const only_pid: ?u32 = if (ctx.session.background) blk: {
        const h = window orelse return &.{};
        break :blk ctx.backend.appPid(h) orelse (ctx.backend.windowRef(h) orelse return &.{}).pid;
    } else null;
    const kept = ctx.arena.alloc(uitree.RootWindow, listed.len) catch return &.{};
    var n: usize = 0;
    for (listed) |r| {
        if (only_pid) |pid| if (r.pid != pid and ctx.backend.appPid(r.handle) != pid) continue;
        if (policy.resolve(ctx, .{ .handle = r.handle, .pid = r.pid }).level == .deny) continue;
        kept[n] = r;
        n += 1;
    }
    return kept[0..n];
}

// ---------------------------------------------------------------- ui_tree

/// `ui_tree`: the pruned tree of `window`, or with `since_last` only what
/// changed since the last tree of that window. With `text`, a web page's
/// visible text nodes too (US-024); with `with_marks`, the screenshot of the
/// root's display with each actionable element's id drawn on it (US-031).
pub fn tree(ctx: anytype, named: ?u64, since_last: bool, text: bool, with_marks: bool) Result {
    const window = switch (resolveWindow(ctx, named)) {
        .ok => |h| h,
        .err => |e| return Result.err(e),
    };
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
    // Whether this tree differs from the last one shown of the window; null
    // when the two were not compared.
    var changed: ?bool = null;
    if (since_last) {
        const last = ui.store.last_window;
        if (foreground and last != null and last.? != win) {
            note = "Fenêtre au premier plan changée : arbre complet de la nouvelle fenêtre.";
        } else if (ui.store.getLast(win)) |prev| {
            ctx.timings.start(ctx.io, .diff);
            const compared = uitree.diff(a, prev.nodes, shown);
            ctx.timings.stop(ctx.io, .diff);
            const d = try compared;
            changed = d.entries.len > 0 or d.removed.len > 0;
            delta = try deltaText(a, s, p, shown, d, prev.roots);
        } else note = "Aucun arbre précédent de cette fenêtre : arbre complet.";
    }
    const full = try fullText(a, s, p, ids, els.len, note);
    try ui.store.putRoots(gpa, win, shown, handles);
    // The backend learns which applications change without an event: a
    // tree that changed while its change counter stood still.
    if (ctx.session.background) ctx.backend.treeObserved(win, changed);
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
/// With `wait_ms`, searches again until a match or the deadline (US-030);
/// with `gone` as well, until nothing matches any more (US-049).
pub fn find(ctx: anytype, query: []const u8, named: ?u64, wait_ms: u32, gone: bool) Result {
    if (gone and wait_ms == 0) return Result.err("gone demande wait_ms : la durée d'attente maximale.");
    const q = switch (uitree.Query.parse(ctx.arena, query) catch return Result.err(oom)) {
        .ok => |q| q,
        .err => |e| return Result.err(e),
    };
    const window = switch (resolveWindow(ctx, named)) {
        .ok => |h| h,
        .err => |e| return Result.err(e),
    };
    if (wait_ms > 0) return findWaiting(ctx, q, query, window, wait_ms, gone);
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
///
/// In background mode the target is covered and its pixels are the user's:
/// a change event of the target's process calls for the next search instead
/// (US-049), and no capture is taken. With `gone`, the wait ends when
/// nothing matches any more, or when the window itself is closed.
fn findWaiting(ctx: anytype, q: uitree.Query, query: []const u8, window: ?u64, wait_ms: u32, gone: bool) Result {
    const by_events = ctx.session.background and window != null;
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
        var events: ?u64 = if (by_events) ctx.backend.windowEvents(window.?) else null;
        if (!by_events) switch (Watch.look(ctx, before)) {
            .failed => {},
            .frame => |f| {
                poll_ms = lookMs(f);
                _ = watch.changed(ctx, f, before.index, before.area);
            },
        };
        const searched = timing.now(ctx.io);
        const snap = snapshot(ctx, window, true, false);
        const elapsed: u64 = @intCast(@divTrunc(@max(timing.now(ctx.io) - start, 0), ms));
        const none_left = "Plus aucun élément « {s} » après {d} ms";
        const s = switch (snap) {
            .ok => |s| s,
            .err => |e| {
                // The window went with its elements.
                if (gone and window != null and ctx.backend.windowRef(window.?) == null) return Result.text(fmt(request_arena, none_left, .{ query, elapsed }));
                return Result.err(request_arena.dupe(u8, e) catch oom);
            },
        };
        const found = findText(ctx, q, query, s, elapsed) catch return Result.err(oom);
        if (gone) {
            if (found.matched == 0) return Result.text(fmt(request_arena, none_left, .{ query, elapsed }));
        } else if (found.matched > 0) return Result.text(request_arena.dupe(u8, found.result.blocks[0].text) catch oom);
        // Watch until the next search is due.
        var pending = false;
        while (true) {
            const t = timing.now(ctx.io);
            if (t >= deadline) {
                if (pending) break;
                if (gone) return Result.err(fmt(request_arena, "Élément « {s} » toujours présent après {d} ms", .{ query, wait_ms }));
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
            if (by_events) {
                // A refused hook leaves the window and the one-second
                // searches.
                const now_events = ctx.backend.windowEvents(window.?);
                if (now_events != null and events != null and now_events.? != events.?) pending = true;
                events = now_events;
            } else switch (Watch.look(ctx, at)) {
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

/// Interval between two reads of a disabled element (US-054); the wait
/// lasts `Session.enable_wait_ms` at most.
const enable_poll_ms = 100;
/// Interval between two reads of an action's effect (US-055); they last
/// `Session.verify_ms` at most.
const verify_poll_ms = 50;
/// Bounds of the scroll toward an element without ScrollItem (US-052).
const into_view_steps = 50;
const into_view_ms = 2000;
/// Toggle calls `check` and `uncheck` make at most: a three-state box
/// reaches any state in two (US-051).
const max_toggles = 2;
const not_replayable = "L'action est partie : ne la rejoue pas sans relire l'arbre.";
const uia_timeout_note = "l'application n'a pas répondu dans le délai UIA";
const reformatted = "délivré, valeur reformatée par l'application";

fn patternName(action: uitree.Action) []const u8 {
    return switch (action) {
        .invoke => "Invoke",
        .toggle, .check, .uncheck => "Toggle",
        .select => "SelectionItem",
        .expand, .collapse => "ExpandCollapse",
        .set_value => "Value",
        .focus => "Focus",
        .scroll => "Scroll",
        .scroll_into_view => "ScrollItem",
    };
}

/// Window whose tree listed the element `id_text`, for the post-action
/// observation: a menu item's window closes once the item is used.
pub fn windowOf(ctx: anytype, id_text: []const u8) ?u64 {
    const id = uitree.parseId(id_text) orelse return null;
    return if (ctx.session.ui.ids.owner(id)) |o| o.tree else null;
}

/// The element an action works on: its root window, which the backend
/// reaches it through, the window whose tree listed it, and its id.
const Elem = struct { window: u64, key: u64, tree: u64, name: []const u8 };

/// What the first line of the result says of the action (US-055).
pub const Verdict = enum {
    /// The state read back shows the effect.
    verified,
    /// Delivered; nothing readable tells whether it took effect.
    unverifiable,
    /// The state read back denies the effect.
    contradicted,
    /// The requested state was already there: no pattern was called.
    noop,
};

const Outcome = struct {
    verdict: Verdict = .unverifiable,
    /// The state read back, or what a call with nothing to do found.
    state: []const u8 = "",
    /// What an unverifiable action says.
    delivered: []const u8 = "délivré, effet non vérifiable",
    notes: [4][]const u8 = undefined,
    n: u8 = 0,

    fn note(self: *Outcome, text: []const u8) void {
        if (self.n == self.notes.len) return;
        self.notes[self.n] = text;
        self.n += 1;
    }

    fn set(self: *Outcome, verdict: Verdict, state: []const u8) void {
        self.verdict = verdict;
        self.state = state;
    }

    /// `<action> <id> : <verdict>`, then what the wait, the scroll and the
    /// pattern chain did. A contradicted action is an error that ends with
    /// the warning not to replay it.
    fn result(self: *const Outcome, ctx: anytype, t: Elem, action: uitree.Action) Result {
        var o = self.*;
        // A read-back that a cancellation or a pause cut short denies
        // nothing: the action left and its effect was not read.
        if (o.verdict == .contradicted and ctx.cancelled()) o = .{ .notes = self.notes, .n = self.n };
        ctx.audit_detail.verdict = @tagName(o.verdict);
        var out: std.Io.Writer.Allocating = .init(ctx.arena);
        o.write(&out.writer, t, action) catch return Result.err(oom);
        return if (o.verdict == .contradicted) Result.err(out.written()) else Result.text(out.written());
    }

    fn write(self: *const Outcome, w: *std.Io.Writer, t: Elem, action: uitree.Action) !void {
        try w.print("{t} {s} : ", .{ action, t.name });
        switch (self.verdict) {
            .verified => try w.print("vérifié ({s})", .{self.state}),
            .unverifiable => try w.writeAll(self.delivered),
            .contradicted => try w.print("contredit, état lu {s}", .{self.state}),
            .noop => try w.writeAll(self.state),
        }
        for (self.notes[0..self.n]) |n| try w.print(" ; {s}", .{n});
        if (self.verdict == .contradicted) try w.writeAll(". " ++ not_replayable);
    }
};

fn liveOf(ctx: anytype, window: u64, key: u64, read: uitree.LiveRead) uitree.LiveResult {
    ctx.timings.start(ctx.io, .accessibility);
    defer ctx.timings.stop(ctx.io, .accessibility);
    return ctx.backend.uiLive(ctx.arena, window, key, read);
}

fn opOn(ctx: anytype, window: u64, key: u64, o: uitree.Op) uitree.OpResult {
    ctx.timings.start(ctx.io, .accessibility);
    defer ctx.timings.stop(ctx.io, .accessibility);
    return ctx.backend.uiOp(ctx.arena, window, key, o);
}

fn goneResult(ctx: anytype, t: Elem) Result {
    return Result.err(fmt(ctx.arena, "Élément {s} introuvable : rappelle ui_tree", .{t.name}));
}

/// The id of element `key`, which `t`'s tree listed or holds.
fn idText(ctx: anytype, t: Elem, key: u64) []const u8 {
    const id = ctx.session.ui.ids.assignIn(ctx.session.gpa, key, t.window, t.tree) catch return "?";
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    uitree.writeId(&out.writer, id) catch return "?";
    return out.written();
}

fn numberText(arena: std.mem.Allocator, x: f64) []const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    uitree.writeNumber(&out.writer, x) catch return "?";
    return out.written();
}

fn toggleText(s: uitree.Toggle) []const u8 {
    return switch (s) {
        .on => "coché",
        .off => "décoché",
        .mixed => "indéterminé",
    };
}

fn expandText(s: uitree.Expand) []const u8 {
    return switch (s) {
        .collapsed => "replié",
        .expanded => "déplié",
        .partial => "partiellement déplié",
        .leaf => "sans enfant",
    };
}

/// `scroll=<v>%,h<h>%`, as the tree writes it.
fn scrollText(arena: std.mem.Allocator, sc: uitree.Scroll) []const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    uitree.writeScroll(&out.writer, sc) catch return "?";
    return if (out.written().len == 0) "aucun défilement" else out.written();
}

/// `ui_act`: runs `action` on element `id_text` through its patterns.
/// A disabled element is waited for and one out of view is scrolled into
/// view first (US-054); a pattern the element lacks falls back on the next
/// of its chain (US-051); the element's state is read back and the first
/// line of the result says whether the action took effect (US-055). The
/// action is never replayed. The value of `set_value` never appears in the
/// result (FR-09).
pub fn act(ctx: anytype, id_text: []const u8, action: uitree.Action, value: ?[]const u8, fallback_click: bool) Result {
    const id = uitree.parseId(id_text) orelse
        return Result.err(fmt(ctx.arena, "Identifiant `{s}` invalide : utilise un id de ui_tree ou ui_find (ex. e1k). Aucune action exécutée.", .{id_text}));
    const name = std.mem.trim(u8, id_text, " ");
    const owner = ctx.session.ui.ids.owner(id) orelse return Result.err(fmt(ctx.arena, "Élément {s} introuvable : rappelle ui_tree", .{name}));
    if (action == .set_value and value == null)
        return Result.err("set_value demande le champ `value` : le texte à écrire, ou un nombre pour un curseur. Aucune action exécutée.");
    var spec: uitree.ScrollSpec = undefined;
    if (action == .scroll) spec = uitree.ScrollSpec.parse(value orelse "") orelse
        return Result.err(fmt(ctx.arena, "value `{s}` invalide pour scroll : formes acceptées {s}. Aucune action exécutée.", .{ value orelse "", uitree.ScrollSpec.forms }));
    // Writing a value is typing; every other pattern is a click (US-017).
    if (policy.requireWindow(ctx, owner.window, if (action == .set_value) .full else .click)) |r| return r;
    const t: Elem = .{ .window = owner.window, .key = owner.key, .tree = owner.tree, .name = name };
    ctx.session.verify_ns = 0;
    var out: Outcome = .{};
    const live = switch (ready(ctx, t, action, &out)) {
        .ok => |l| l,
        .stop => |r| return r,
    };
    const early: ?Result = switch (action) {
        .invoke => doInvoke(ctx, t, live, &out, fallback_click),
        .toggle => doToggle(ctx, t, live, &out, fallback_click),
        .check => doCheck(ctx, t, live, &out, .on),
        .uncheck => doCheck(ctx, t, live, &out, .off),
        .select => if (value) |v| selectByName(ctx, t, live, &out, v) else doSelect(ctx, t, live, &out, fallback_click),
        .expand, .collapse => doExpand(ctx, t, live, &out, action, fallback_click),
        .set_value => doSetValue(ctx, t, live, &out, value.?, fallback_click),
        .scroll => doScroll(ctx, t, live, &out, spec),
        .scroll_into_view => doIntoView(ctx, t, live, &out),
        .focus => sent(ctx, t, live, &out, .focus, opOn(ctx, t.window, t.key, .focus), fallback_click),
    };
    return early orelse out.result(ctx, t, action);
}

const Ready = union(enum) { ok: uitree.Live, stop: Result };

/// The preconditions of an action (US-054). An element out of view is
/// scrolled into view once; a disabled one is read again every 100 ms for
/// 2 s at most. The scrolling actions take the element as it is.
fn ready(ctx: anytype, t: Elem, action: uitree.Action, out: *Outcome) Ready {
    const ms = std.time.ns_per_ms;
    var live = switch (liveOf(ctx, t.window, t.key, .all)) {
        .ok => |l| l,
        .gone => return .{ .stop = goneResult(ctx, t) },
        .failed => |m| return .{ .stop = Result.err(m) },
    };
    if (action == .scroll or action == .scroll_into_view) return .{ .ok = live };
    var scrolled = false;
    var since: ?i96 = null;
    var polls: u32 = 0;
    while (true) {
        if (live.offscreen) {
            if (scrolled) return .{ .stop = Result.err(fmt(ctx.arena, "Précondition non remplie : {s} est resté hors écran après scroll_into_view. Aucune action exécutée.", .{t.name})) };
            switch (intoView(ctx, t, live)) {
                .item, .container, .in_view => {},
                .gone => return .{ .stop = goneResult(ctx, t) },
                .cancelled => return .{ .stop = Result.err("ui_act annulé. Aucune action exécutée.") },
                .failed => |f| return .{ .stop = Result.err(fmt(ctx.arena, "Précondition non remplie : {s} est hors écran et n'a pas pu être amené en vue ({s}). Aucune action exécutée.", .{ t.name, f.why })) },
            }
            scrolled = true;
            out.note("amené en vue");
            // A provider may report the new position a moment later.
            const back = readBack(ctx, t, .all, OnScreen{}) orelse return .{ .stop = goneResult(ctx, t) };
            live = back.live;
            continue;
        }
        if (live.enabled) break;
        const now = timing.now(ctx.io);
        if (since == null) since = now;
        const waited: u64 = @intCast(@divTrunc(@max(now - since.?, 0), ms));
        if (waited >= ctx.session.enable_wait_ms)
            return .{ .stop = Result.err(fmt(ctx.arena, "Précondition non remplie : {s} est resté désactivé {d} ms. Aucune action exécutée.", .{ t.name, ctx.session.enable_wait_ms })) };
        polls += 1;
        if (!sleepUntil(ctx, since.? + @as(i96, polls) * enable_poll_ms * ms)) return .{ .stop = Result.err(fmt(ctx.arena, "ui_act annulé pendant l'attente de {s}. Aucune action exécutée.", .{t.name})) };
        live = switch (liveOf(ctx, t.window, t.key, .all)) {
            .ok => |l| l,
            .gone => return .{ .stop = goneResult(ctx, t) },
            .failed => |m| return .{ .stop = Result.err(m) },
        };
    }
    if (since) |s| out.note(fmt(ctx.arena, "activé après {d} ms", .{@as(u64, @intCast(@divTrunc(@max(timing.now(ctx.io) - s, 0), ms)))}));
    return .{ .ok = live };
}

const ReadBack = struct { live: uitree.Live, met: bool };

/// Reads `read` of `t` again until `want.met`, every 50 ms for 400 ms at most
/// (US-055). The first read comes at once: an effect readable by then costs
/// one round trip. Null when the element can no longer be read.
fn readBack(ctx: anytype, t: Elem, read: uitree.LiveRead, want: anytype) ?ReadBack {
    const ms = std.time.ns_per_ms;
    const start = timing.now(ctx.io);
    defer ctx.session.verify_ns += @intCast(@max(timing.now(ctx.io) - start, 0));
    var last: ?uitree.Live = null;
    var polls: u32 = 0;
    while (true) {
        switch (liveOf(ctx, t.window, t.key, read)) {
            .ok => |l| {
                if (want.met(l)) return .{ .live = l, .met = true };
                last = l;
            },
            else => break,
        }
        if (timing.now(ctx.io) - start >= @as(i96, ctx.session.verify_ms) * ms) break;
        polls += 1;
        if (!sleepUntil(ctx, start + @as(i96, polls) * verify_poll_ms * ms)) break;
    }
    return if (last) |l| .{ .live = l, .met = false } else null;
}

/// Waits until the clock reads `at`. `ctx.sleep` runs in 10 ms slices that
/// Windows rounds up to its 15.6 ms tick, so a 100 ms period asked of it
/// lasts about 156 ms: the polls aim at a time, never at a duration.
fn sleepUntil(ctx: anytype, at: i96) bool {
    while (true) {
        const left = at - timing.now(ctx.io);
        if (left <= 0) return !ctx.cancelled();
        if (!ctx.sleep(@intCast(@min(left, 10 * std.time.ns_per_ms)))) return false;
    }
}

const OnScreen = struct {
    fn met(_: OnScreen, l: uitree.Live) bool {
        return !l.offscreen;
    }
};

const ToggleLeft = struct {
    from: uitree.Toggle,
    fn met(self: ToggleLeft, l: uitree.Live) bool {
        return if (l.toggle) |s| s != self.from else false;
    }
};

const ExpandIs = struct {
    open: bool,
    fn met(self: ExpandIs, l: uitree.Live) bool {
        const s = l.expand orelse return false;
        return if (self.open) s == .expanded or s == .partial else s == .collapsed;
    }
};

const Selected = struct {
    fn met(_: Selected, l: uitree.Live) bool {
        return l.selected orelse false;
    }
};

const ValueIs = struct {
    hash: u64,
    fn met(self: ValueIs, l: uitree.Live) bool {
        return if (l.value_hash) |h| h == self.hash else false;
    }
};

const RangeIs = struct {
    value: f64,
    fn met(self: RangeIs, l: uitree.Live) bool {
        const r = l.range orelse return false;
        return @abs(r.value - self.value) <= 1e-6 * @max(1, @abs(self.value));
    }
};

const ScrollLeft = struct {
    vertical: bool,
    from: ?f32,
    fn met(self: ScrollLeft, l: uitree.Live) bool {
        const sc = l.scroll orelse return false;
        const now = if (self.vertical) sc.v else sc.h;
        if (now == null or self.from == null) return (now == null) != (self.from == null);
        return @abs(now.? - self.from.?) > 0.01;
    }
};

/// What a pattern call that did not go through means for the result: null
/// when the action left, with a note when the provider did not answer in
/// time.
fn sent(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome, action: uitree.Action, r: uitree.OpResult, fallback_click: bool) ?Result {
    switch (r) {
        .ok => return null,
        .timeout => {
            out.note(uia_timeout_note);
            return null;
        },
        .gone => return goneResult(ctx, t),
        .read_only => return Result.err(fmt(ctx.arena, "Précondition non remplie : {s} est en lecture seule. Aucune action exécutée.", .{t.name})),
        .unsupported => return unsupported(ctx, t, live, action, fallback_click),
        .failed => |msg| return Result.err(msg),
    }
}

/// The element lacks the pattern of `action` and every fallback of its
/// chain: the click fallback when asked for, else the refusal.
fn unsupported(ctx: anytype, t: Elem, live: uitree.Live, action: uitree.Action, fallback_click: bool) Result {
    const pattern = patternName(action);
    if (fallback_click) {
        const r = clickCenter(ctx, live.rect, action, t.name);
        if (!r.is_error) ctx.audit_detail.verdict = @tagName(Verdict.unverifiable);
        return r;
    }
    const folded = action == .expand or action == .collapse;
    // The background mode refuses fallback click: the message never names
    // it (PRD, Edge Cases 5).
    const advice: []const u8 = if (ctx.session.background)
        (if (folded) "Son état déplié ou replié est inconnu : essaie invoke." else if (action == .set_value) "En arrière-plan, aucune saisie clavier n'est possible : essaie une autre action, ou demande à Arthur de relancer en mode a11y." else "En arrière-plan, aucun clic n'est possible : essaie une autre action, ou demande à Arthur de relancer en mode a11y.")
    else if (folded) "Son état déplié ou replié est inconnu : essaie invoke, ou fallback: \"click\"." else "Essaie une autre action ou fallback: \"click\".";
    return Result.err(fmt(ctx.arena, "Précondition non remplie : {s} ne supporte pas {t} (pattern {s} absent). {s} Aucune action exécutée.", .{ t.name, action, pattern, advice }));
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

/// Invoke, else the element's MSAA default action (US-051): the effect of
/// either is not readable, the observation's delta is the proof.
fn doInvoke(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome, fallback_click: bool) ?Result {
    if (live.actions.invoke) return sent(ctx, t, live, out, .invoke, opOn(ctx, t.window, t.key, .invoke), fallback_click);
    if (sent(ctx, t, live, out, .invoke, opOn(ctx, t.window, t.key, .legacy), fallback_click)) |r| return r;
    out.note("par LegacyIAccessible.DoDefaultAction");
    return null;
}

/// Toggle, else Invoke (US-051). With Toggle the state must leave the one
/// read before.
fn doToggle(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome, fallback_click: bool) ?Result {
    if (!live.actions.toggle) {
        if (!live.actions.invoke) return unsupported(ctx, t, live, .toggle, fallback_click);
        if (sent(ctx, t, live, out, .toggle, opOn(ctx, t.window, t.key, .invoke), fallback_click)) |r| return r;
        out.note("par Invoke");
        return null;
    }
    if (sent(ctx, t, live, out, .toggle, opOn(ctx, t.window, t.key, .toggle), fallback_click)) |r| return r;
    const from = live.toggle orelse return null;
    const back = readBack(ctx, t, .toggle, ToggleLeft{ .from = from }) orelse return null;
    const now = back.live.toggle orelse return null;
    out.set(if (back.met) .verified else .contradicted, toggleText(now));
    return null;
}

/// `check` and `uncheck` (US-051): the state is read first and nothing is
/// called when it is already there. A three-state box takes two Toggle
/// calls at most; the second leaves only once the first was seen to change
/// the state, so no call is ever a replay.
fn doCheck(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome, want: uitree.Toggle) ?Result {
    const action: uitree.Action = if (want == .on) .check else .uncheck;
    var state = (if (live.actions.toggle) live.toggle else null) orelse
        return Result.err(fmt(ctx.arena, "Précondition non remplie : {s} ne supporte pas {t} (pattern Toggle absent) : son état est inconnu. Essaie invoke. Aucune action exécutée.", .{ t.name, action }));
    if (state == want) {
        out.set(.noop, if (want == .on) "déjà coché" else "déjà décoché");
        return null;
    }
    var calls: u8 = 0;
    while (calls < max_toggles) {
        const r = opOn(ctx, t.window, t.key, .toggle);
        if (calls == 0) {
            if (sent(ctx, t, live, out, action, r, false)) |early| return early;
        } else if (r != .ok and r != .timeout) {
            out.set(.contradicted, toggleText(state));
            return null;
        }
        calls += 1;
        const back = readBack(ctx, t, .toggle, ToggleLeft{ .from = state }) orelse return null;
        const now = back.live.toggle orelse return null;
        if (!back.met) {
            out.set(.contradicted, toggleText(now));
            return null;
        }
        state = now;
        if (state == want) {
            out.set(.verified, toggleText(state));
            if (calls > 1) out.note(fmt(ctx.arena, "{d} bascules", .{calls}));
            return null;
        }
    }
    out.set(.contradicted, fmt(ctx.arena, "{s} après {d} bascules, sans atteindre « {s} »", .{ toggleText(state), calls, toggleText(want) }));
    return null;
}

/// Expand and collapse have no Invoke fallback (US-051): without the
/// pattern the state is unknown, and an Invoke could close what was open.
fn doExpand(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome, action: uitree.Action, fallback_click: bool) ?Result {
    if (!live.actions.expand_collapse) return unsupported(ctx, t, live, action, fallback_click);
    const o: uitree.Op = if (action == .expand) .expand else .collapse;
    if (sent(ctx, t, live, out, action, opOn(ctx, t.window, t.key, o), fallback_click)) |r| return r;
    const back = readBack(ctx, t, .expand, ExpandIs{ .open = action == .expand }) orelse return null;
    const now = back.live.expand orelse return null;
    if (now == .leaf) return null;
    out.set(if (back.met) .verified else .contradicted, expandText(now));
    return null;
}

fn doSelect(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome, fallback_click: bool) ?Result {
    if (!live.actions.select) return unsupported(ctx, t, live, .select, fallback_click);
    if (sent(ctx, t, live, out, .select, opOn(ctx, t.window, t.key, .select), fallback_click)) |r| return r;
    const back = readBack(ctx, t, .selected, Selected{}) orelse return null;
    if (back.live.selected == null) return null;
    out.set(if (back.met) .verified else .contradicted, if (back.met) "sélectionné" else "non sélectionné");
    return null;
}

fn entriesOf(ctx: anytype, t: Elem) uitree.EntriesResult {
    ctx.timings.start(ctx.io, .accessibility);
    defer ctx.timings.stop(ctx.io, .accessibility);
    return ctx.backend.uiEntries(ctx.arena, t.window, t.key);
}

/// Names shown when no entry matches (US-053).
const max_entry_names = 10;

/// `select` with a name on a container (US-053): the selectable descendant
/// whose name is `wanted`, whatever the case and the accents. A collapsed
/// container is expanded for the search and collapsed again whatever comes
/// of it. No entry, or several of that name: nothing is selected.
fn selectByName(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome, wanted: []const u8) ?Result {
    const a = ctx.arena;
    const ms = std.time.ns_per_ms;
    var opened = false;
    if (live.expand == .collapsed) switch (opOn(ctx, t.window, t.key, .expand)) {
        .ok, .timeout => opened = true,
        .gone => return goneResult(ctx, t),
        // The entries of a container that does not open may still be read.
        .unsupported, .read_only, .failed => {},
    };
    // An opened list fills in a moment later with some providers; one whose
    // tree cannot be read while open (a Win32 drop-down, decision 0013) is
    // closed and read as it was.
    var entries: []const uitree.Entry = &.{};
    const start = timing.now(ctx.io);
    while (true) {
        switch (entriesOf(ctx, t)) {
            .ok => |es| entries = es,
            .gone => return goneResult(ctx, t),
            .failed => |msg| if (!opened) return Result.err(msg),
        }
        if (entries.len > 0 or !opened) break;
        if (timing.now(ctx.io) - start < @as(i96, ctx.session.verify_ms) * ms and ctx.sleep(verify_poll_ms * ms)) continue;
        _ = opOn(ctx, t.window, t.key, .collapse);
        // Cancelled or paused while the list filled in: nothing is selected.
        if (ctx.cancelled()) return Result.err("ui_act annulé. Aucune sélection faite, conteneur replié comme avant.");
        opened = false;
        out.note("entrées lues conteneur replié");
    }
    const want = uitree.fold(a, std.mem.trim(u8, wanted, " ")) catch return Result.err(oom);
    var found: ?uitree.Entry = null;
    var matches: usize = 0;
    var same: std.Io.Writer.Allocating = .init(a);
    for (entries) |e| {
        const folded = uitree.fold(a, std.mem.trim(u8, e.name, " ")) catch return Result.err(oom);
        if (!std.mem.eql(u8, folded, want)) continue;
        matches += 1;
        found = e;
        same.writer.print("{s}{s}", .{ if (matches > 1) ", " else "", idText(ctx, t, e.key) }) catch return Result.err(oom);
    }
    const restored: []const u8 = if (opened) "Aucune sélection faite, conteneur replié comme avant." else "Aucune action exécutée.";
    if (matches != 1) {
        if (opened) _ = opOn(ctx, t.window, t.key, .collapse);
        if (matches > 1) return Result.err(fmt(a, "{d} entrées nommées « {s} » dans {s} : {s}. Choisis-en une par son id avec select sans value. {s}", .{ matches, wanted, t.name, same.written(), restored }));
        if (entries.len == 0) return Result.err(fmt(a, "{s} n'a aucune entrée sélectionnable : select avec value vise une liste, une liste déroulante, des onglets ou un arbre. {s}", .{ t.name, restored }));
        var names: std.Io.Writer.Allocating = .init(a);
        for (entries[0..@min(entries.len, max_entry_names)], 0..) |e, i| names.writer.print("{s}« {s} »", .{ if (i > 0) ", " else "", e.name }) catch return Result.err(oom);
        if (entries.len > max_entry_names) names.writer.print(", … {d} autres", .{entries.len - max_entry_names}) catch {};
        return Result.err(fmt(a, "Aucune entrée « {s} » dans {s}. Entrées : {s}. {s}", .{ wanted, t.name, names.written(), restored }));
    }
    const entry: Elem = .{ .window = t.window, .key = found.?.key, .tree = t.tree, .name = idText(ctx, t, found.?.key) };
    // Brought into view first: some providers select only what they show.
    switch (liveOf(ctx, entry.window, entry.key, .all)) {
        .ok => |l| if (l.offscreen) {
            _ = intoView(ctx, entry, l);
        },
        else => {},
    }
    const r = opOn(ctx, entry.window, entry.key, .select);
    var back: ?ReadBack = if (r == .ok or r == .timeout) readBack(ctx, entry, .selected, Selected{}) else null;
    if (opened) {
        _ = opOn(ctx, t.window, t.key, .collapse);
        if (back != null and back.?.met) back = keptAfterCollapse(ctx, t, entry, out) orelse back;
    }
    switch (r) {
        .ok => {},
        .timeout => out.note(uia_timeout_note),
        .gone => return goneResult(ctx, entry),
        .unsupported, .read_only => return Result.err(fmt(a, "Précondition non remplie : l'entrée {s} ne supporte pas select (pattern SelectionItem absent). {s}", .{ entry.name, restored })),
        .failed => |msg| return Result.err(msg),
    }
    out.note(fmt(a, "entrée {s}", .{entry.name}));
    const b = back orelse return null;
    if (b.live.selected == null) return null;
    out.set(if (b.met) .verified else .contradicted, if (b.met) "sélectionné" else "non sélectionné");
    return null;
}

/// A Win32 drop-down list takes a collapse for a cancel and puts its former
/// entry back (measured, decision 0013). Once the container reads collapsed,
/// an entry that lost its selection is selected again, container closed.
/// Null when the entry can no longer be read.
fn keptAfterCollapse(ctx: anytype, t: Elem, entry: Elem, out: *Outcome) ?ReadBack {
    _ = readBack(ctx, t, .expand, ExpandIs{ .open = false });
    const now = switch (liveOf(ctx, entry.window, entry.key, .all)) {
        .ok => |l| l,
        else => return null,
    };
    if (now.selected != false) return .{ .live = now, .met = true };
    switch (opOn(ctx, entry.window, entry.key, .select)) {
        .ok, .timeout => {},
        else => return .{ .live = now, .met = false },
    }
    out.note("sélection refaite conteneur replié");
    return readBack(ctx, entry, .selected, Selected{});
}

/// A number as the model writes it: a decimal point or comma.
fn parseNumber(arena: std.mem.Allocator, text: []const u8) ?f64 {
    const t = arena.dupe(u8, std.mem.trim(u8, text, " ")) catch return null;
    std.mem.replaceScalar(u8, t, ',', '.');
    const x = std.fmt.parseFloat(f64, t) catch return null;
    return if (std.math.isFinite(x)) x else null;
}

/// Value, else RangeValue for a slider (US-053). The value read back is
/// compared by its hash and never written anywhere (FR-09); a password
/// field is not read back at all.
fn doSetValue(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome, value: []const u8, fallback_click: bool) ?Result {
    const a = ctx.arena;
    if (live.range) |range| if (!live.actions.value or live.read_only) {
        const lo = numberText(a, range.min);
        const hi = numberText(a, range.max);
        const x = parseNumber(a, value) orelse
            return Result.err(fmt(a, "{s} attend un nombre entre {s} et {s}. Aucune action exécutée.", .{ t.name, lo, hi }));
        if (x < range.min or x > range.max)
            return Result.err(fmt(a, "Valeur {s} hors plage {s}..{s}. Aucune action exécutée.", .{ numberText(a, x), lo, hi }));
        if (range.read_only) return Result.err(fmt(a, "Précondition non remplie : {s} est en lecture seule. Aucune action exécutée.", .{t.name}));
        if (sent(ctx, t, live, out, .set_value, opOn(ctx, t.window, t.key, .{ .set_range = x }), fallback_click)) |r| return r;
        const back = readBack(ctx, t, .all, RangeIs{ .value = x }) orelse return null;
        if (back.live.range == null) return null;
        if (back.met) out.set(.verified, "valeur relue identique") else out.delivered = reformatted;
        return null;
    };
    if (!live.actions.value) return unsupported(ctx, t, live, .set_value, fallback_click);
    if (sent(ctx, t, live, out, .set_value, opOn(ctx, t.window, t.key, .{ .set_value = value }), fallback_click)) |r| return r;
    if (live.password) return null;
    const hash = uitree.textHashUtf8(a, value) orelse return null;
    const back = readBack(ctx, t, .value, ValueIs{ .hash = hash }) orelse return null;
    if (back.live.value_hash == null) return null;
    if (back.met) out.set(.verified, "valeur relue identique") else out.delivered = reformatted;
    return null;
}

fn scrollHost(ctx: anytype, t: Elem) ?u64 {
    ctx.timings.start(ctx.io, .accessibility);
    defer ctx.timings.stop(ctx.io, .accessibility);
    return ctx.backend.uiScrollHost(ctx.arena, t.window, t.key);
}

/// `scroll` (US-052): the element's own Scroll pattern, else the one of its
/// first ancestor that has it. Notches and pages are Scroll calls, an edge
/// or a percentage is SetScrollPercent. A container already where it is
/// asked to go is not an error.
fn doScroll(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome, spec: uitree.ScrollSpec) ?Result {
    const a = ctx.arena;
    const nowhere = "{s} n'est dans aucun conteneur défilable. Aucune action exécutée.";
    var host = t;
    var hl = live;
    if (live.scroll == null) {
        host.key = scrollHost(ctx, t) orelse return Result.err(fmt(a, nowhere, .{t.name}));
        host.name = idText(ctx, t, host.key);
        hl = switch (liveOf(ctx, host.window, host.key, .all)) {
            .ok => |l| l,
            .gone => return goneResult(ctx, host),
            .failed => |m| return Result.err(m),
        };
        out.note(fmt(a, "conteneur {s}", .{host.name}));
    }
    const sc = hl.scroll orelse return Result.err(fmt(a, nowhere, .{t.name}));
    const vertical = switch (spec) {
        .step => |s| s.dir == .up or s.dir == .down,
        else => true,
    };
    const forward = switch (spec) {
        .step => |s| s.dir == .down or s.dir == .right,
        .page => |p| p == .down,
        .edge => |e| e == .bottom,
        .percent => true,
    };
    const pos: ?f32 = if (vertical) sc.v else sc.h;
    // An axis that does not scroll shows all of its content: both ends are
    // in view.
    const at_end = if (pos) |p| (if (forward) p >= 100 else p <= 0) else true;
    switch (spec) {
        .percent => |p| if (pos == null or @abs(pos.? - p) < 0.5) {
            out.set(.noop, if (pos == null) "pas de défilement vertical, tout est déjà en vue" else fmt(a, "déjà à {s}%", .{numberText(a, p)}));
            return null;
        },
        else => if (at_end) {
            out.set(.noop, if (vertical) (if (forward) "déjà en bas" else "déjà en haut") else if (forward) "déjà à droite" else "déjà à gauche");
            return null;
        },
    }
    const first: uitree.Op, const repeat: u8 = switch (spec) {
        .step => |s| .{ stepOp(vertical, forward, false), s.count },
        .page => .{ stepOp(vertical, forward, true), 1 },
        .edge => |e| .{ .{ .scroll_to = .{ .v = if (e == .top) 0 else 100 } }, 1 },
        .percent => |p| .{ .{ .scroll_to = .{ .v = p } }, 1 },
    };
    var done: u8 = 0;
    while (done < repeat) : (done += 1) {
        const r = opOn(ctx, host.window, host.key, first);
        if (done == 0) {
            if (sent(ctx, host, hl, out, .scroll, r, false)) |early| return early;
        } else if (r != .ok and r != .timeout) break;
        if (ctx.cancelled()) break;
    }
    const back = readBack(ctx, host, .all, ScrollLeft{ .vertical = vertical, .from = pos }) orelse return null;
    const now = back.live.scroll orelse return null;
    out.set(if (back.met) .verified else .contradicted, scrollText(a, now));
    return null;
}

fn stepOp(vertical: bool, forward: bool, large: bool) uitree.Op {
    const amount: uitree.ScrollAmount = if (large) (if (forward) .large_forward else .large_back) else if (forward) .small_forward else .small_back;
    return .{ .scroll = if (vertical) .{ .v = amount } else .{ .h = amount } };
}

const IntoView = union(enum) {
    /// ScrollItem.ScrollIntoView was called.
    item,
    /// The scrollable ancestor of this key was scrolled until the element
    /// showed.
    container: u64,
    /// Already in view and without ScrollItem: nothing to do.
    in_view,
    gone,
    cancelled,
    /// `moved`: the container scrolled before the attempt gave up.
    failed: struct { why: []const u8, moved: bool = false },
};

/// The increment that brings `el` closer to the view of `host`: a page when
/// it is further than one, a notch otherwise. Null when `el` has no
/// rectangle or already lies within `host`.
fn toward(el: display.Rect, host: display.Rect) ?uitree.ScrollStep {
    if (el.w <= 0 or el.h <= 0) return null;
    var s: uitree.ScrollStep = .{};
    if (el.y + el.h > host.y + host.h) {
        s.v = if (el.y - (host.y + host.h) > host.h) .large_forward else .small_forward;
    } else if (el.y < host.y) {
        s.v = if (host.y - (el.y + el.h) > host.h) .large_back else .small_back;
    }
    if (el.x + el.w > host.x + host.w) {
        s.h = if (el.x - (host.x + host.w) > host.w) .large_forward else .small_forward;
    } else if (el.x < host.x) {
        s.h = if (host.x - (el.x + el.w) > host.w) .large_back else .small_back;
    }
    return if (s.v == .none and s.h == .none) null else s;
}

fn sameScroll(x: ?uitree.Scroll, y: ?uitree.Scroll) bool {
    const p = x orelse return y == null;
    const q = y orelse return false;
    return p.v == q.v and p.h == q.h;
}

/// Brings `t` into view (US-052): ScrollItem when the element has it, else
/// its scrollable ancestor moved by increments toward it, 50 increments or
/// 2 s at most, until the element is no longer off-screen.
fn intoView(ctx: anytype, t: Elem, first: uitree.Live) IntoView {
    if (first.actions.scroll) return switch (opOn(ctx, t.window, t.key, .scroll_item)) {
        .ok, .timeout => .item,
        .gone => .gone,
        .failed => |m| .{ .failed = .{ .why = m } },
        .unsupported, .read_only => .{ .failed = .{ .why = "pattern ScrollItem absent" } },
    };
    if (!first.offscreen) return .in_view;
    const ms = std.time.ns_per_ms;
    const host_key = scrollHost(ctx, t) orelse return .{ .failed = .{ .why = "pattern ScrollItem absent et aucun conteneur défilable" } };
    var host = switch (liveOf(ctx, t.window, host_key, .all)) {
        .ok => |l| l,
        else => return .{ .failed = .{ .why = "conteneur défilable illisible" } },
    };
    const start = timing.now(ctx.io);
    var live = first;
    var steps: u32 = 0;
    while (live.offscreen) {
        const moved = steps > 0;
        if (steps == into_view_steps or timing.now(ctx.io) - start >= into_view_ms * ms)
            return .{ .failed = .{ .why = fmt(ctx.arena, "toujours hors écran après {d} incréments", .{steps}), .moved = moved } };
        const step = toward(live.rect, host.rect) orelse return .{ .failed = .{ .why = "sa position par rapport au conteneur est inconnue", .moved = moved } };
        switch (opOn(ctx, t.window, host_key, .{ .scroll = step })) {
            .ok, .timeout => {},
            .gone => return .gone,
            .failed => |m| return .{ .failed = .{ .why = m, .moved = moved } },
            .unsupported, .read_only => return .{ .failed = .{ .why = "le conteneur ne défile pas", .moved = moved } },
        }
        steps += 1;
        if (ctx.cancelled()) return .cancelled;
        live = switch (liveOf(ctx, t.window, t.key, .all)) {
            .ok => |l| l,
            else => return .gone,
        };
        if (!live.offscreen) break;
        var after = switch (liveOf(ctx, t.window, host_key, .all)) {
            .ok => |l| l,
            else => return .{ .failed = .{ .why = "conteneur défilable illisible", .moved = true } },
        };
        if (sameScroll(host.scroll, after.scroll)) {
            // At its limit, or a provider that reports a moment later.
            if (!ctx.sleep(verify_poll_ms * ms)) return .cancelled;
            after = switch (liveOf(ctx, t.window, host_key, .all)) {
                .ok => |l| l,
                else => return .{ .failed = .{ .why = "conteneur défilable illisible", .moved = true } },
            };
            if (sameScroll(host.scroll, after.scroll)) return .{ .failed = .{ .why = "le conteneur est au bout de sa course", .moved = steps > 1 } };
        }
        host = after;
    }
    return .{ .container = host_key };
}

/// `scroll_into_view`: delivered, its effect shows in the observation.
fn doIntoView(ctx: anytype, t: Elem, live: uitree.Live, out: *Outcome) ?Result {
    switch (intoView(ctx, t, live)) {
        .item => {},
        .container => |key| out.note(fmt(ctx.arena, "par défilement de {s}", .{idText(ctx, t, key)})),
        .in_view => out.set(.noop, "déjà en vue"),
        .gone => return goneResult(ctx, t),
        .cancelled => return Result.err("ui_act annulé."),
        .failed => |f| return Result.err(fmt(ctx.arena, "{s} n'a pas pu être amené en vue : {s}. {s}", .{ t.name, f.why, if (f.moved) "Le conteneur a défilé : relis l'arbre." else "Aucune action exécutée." })),
    }
    return null;
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
        // Background mode never asks where the foreground window is.
        const index = if (area) |a| display.displayAt(displays, a.x + @divTrunc(a.w, 2), a.y + @divTrunc(a.h, 2)) orelse 0 else if (ctx.session.background) 0 else ctx.backend.foregroundDisplay() orelse 0;
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

/// What the result says when the event hook was refused and the tree
/// re-read alone settled (US-048).
pub const reread_note = "stabilisation par relecture";

/// Hash of what the tree of `window` shows, with the menus and popups read
/// along with it; 0 when it cannot be read. Read into `scratch`, which the
/// next read reuses.
fn treeStamp(ctx: anytype, scratch: *std.heap.ArenaAllocator, window: u64) u64 {
    // A `deny` application is never read (US-017).
    if (ctx.backend.windowRef(window)) |ref| if (policy.hidden(ctx, ref) != null) return 0;
    const request_arena = ctx.arena;
    _ = scratch.reset(.retain_capacity);
    ctx.arena = scratch.allocator();
    defer ctx.arena = request_arena;
    const snap = switch (ctx.backend.uiSnapshot(ctx.arena, window, .{ .extra_roots = extraRoots(ctx, window) })) {
        .ok => |snap| snap,
        .err => return 0,
    };
    var h: std.hash.Wyhash = .init(snap.elements.len);
    for (snap.elements) |e| {
        std.hash.autoHash(&h, e.key);
        std.hash.autoHash(&h, e.depth);
        std.hash.autoHash(&h, e.role);
        std.hash.autoHash(&h, e.states);
        std.hash.autoHash(&h, e.rect);
        std.hash.autoHash(&h, e.name.len);
        h.update(e.name);
        if (e.value) |v| {
            std.hash.autoHash(&h, v.len);
            h.update(v);
        }
    }
    return h.final();
}

/// Settling of the background mode (US-048): the target is covered by what
/// the user works on, so the screen says nothing about it. It is settled
/// once its process raised no change event for 50 ms. A floor covers what
/// events miss (US-047: some applications raise none): the tree is read
/// again every `reread_ms` and two identical reads are settled, whatever
/// the events say. Without the hook, the floor alone settles, and `reread`
/// says so. No capture is taken.
fn settleEvents(ctx: anytype, timeout_ms: u32, window: u64) struct { settled: Settled, reread: bool } {
    ctx.timings.start(ctx.io, .settle);
    defer ctx.timings.stop(ctx.io, .settle);
    const ms = std.time.ns_per_ms;
    const start = timing.now(ctx.io);
    const period = @as(i96, ctx.session.reread_ms) * ms;
    var scratch: std.heap.ArenaAllocator = .init(ctx.arena);
    var stamp = ctx.backend.windowEvents(window);
    const hooked = stamp != null;
    var last_event = start;
    var last_read: ?i96 = null;
    var last_tree: u64 = 0;
    while (true) {
        const t = timing.now(ctx.io);
        const since: u64 = @intCast(@divTrunc(t - start, ms));
        if (hooked) {
            const now_stamp = ctx.backend.windowEvents(window);
            if (now_stamp != null and now_stamp.? != stamp.?) {
                stamp = now_stamp;
                last_event = t;
            } else if (t - last_event >= quiet_ms * ms) return .{ .settled = .{ .settled = since }, .reread = false };
        }
        if (if (last_read) |r| t - r >= period else !hooked or t - start >= period) {
            const tree_now = treeStamp(ctx, &scratch, window);
            if (last_read != null and tree_now == last_tree) return .{ .settled = .{ .settled = since }, .reread = !hooked };
            last_tree = tree_now;
            last_read = t;
        }
        if (t - start >= @as(i96, timeout_ms) * ms) return .{ .settled = .timeout, .reread = !hooked };
        if (!ctx.sleep(10 * ms)) return .{ .settled = .cancelled, .reread = !hooked };
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
pub fn observeWith(ctx: anytype, r: Result, observe: ?Observe, settle_timeout_ms: ?u32, named: ?u64, full: bool) Result {
    if (r.is_error or r.len == 0 or r.blocks[0] != .text) return r;
    const mode = observe orelse ctx.session.default_observe;
    if (mode == .none) return r;
    // Background mode observes the target, never the foreground window; an
    // action that left no window to observe (a minimize, a close) returns
    // its own line.
    const window = if (named == null and ctx.session.background) blk: {
        const t = ctx.session.target orelse return r;
        if (ctx.backend.windowRef(t) == null) return r;
        break :blk t;
    } else named;
    const timeout = settle_timeout_ms orelse default_settle_ms;
    var reread = false;
    // The pixels around a covered target are the user's: background mode
    // settles on the target's own change events.
    const settled = if (ctx.session.background and window != null) blk: {
        const s = settleEvents(ctx, timeout, window.?);
        reread = s.reread;
        break :blk s.settled;
    } else settle(ctx, timeout, window);
    const note = if (reread) " (" ++ reread_note ++ ")" else "";
    const status = switch (settled) {
        .settled => |n| fmt(ctx.arena, "settled in {d} ms{s}", .{ n, note }),
        .timeout => fmt(ctx.arena, "settle timeout{s}", .{note}),
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
