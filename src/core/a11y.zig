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

const Snap = struct { snap: uitree.Snapshot, m: display.Mapping, viewport: display.Rect };

fn intersection(a: display.Rect, b: display.Rect) ?display.Rect {
    if (!a.intersects(b)) return null;
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    return .{ .x = x, .y = y, .w = @min(a.right(), b.right()) - x, .h = @min(a.bottom(), b.bottom()) - y };
}

/// Snapshot of `window` (the foreground window when null) and the mapping of
/// the display it sits on. With `record`, the mapping becomes the space of
/// incoming coordinates, like a screenshot's (FR-03). Post-action deltas do
/// not record it: a click aimed from a screenshot of another display must
/// keep that display's space.
fn snapshot(ctx: anytype, window: ?u64, record: bool) union(enum) { ok: Snap, err: []const u8 } {
    ctx.timings.start(ctx.io, .accessibility);
    const res = ctx.backend.uiSnapshot(ctx.arena, window);
    ctx.timings.stop(ctx.io, .accessibility);
    const snap = switch (res) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    if (snap.elements.len == 0) return .{ .err = "Arbre d'accessibilité vide : utilise screenshot pour cette fenêtre." };
    const displays = ctx.backend.displays();
    if (displays.len == 0) return .{ .err = "Aucun écran détecté : vérifie qu'un écran est allumé, puis réessaie." };
    const root = snap.elements[0].rect;
    const index = @min(display.displayAt(displays, root.x + @divTrunc(root.w, 2), root.y + @divTrunc(root.h, 2)) orelse 0, display.max_displays - 1);
    const m = display.Mapping.of(index, displays[index].rect, ctx.session.long_side);
    if (record) ctx.session.recordShot(m);
    return .{ .ok = .{ .snap = snap, .m = m, .viewport = intersection(root, displays[index].rect) orelse root } };
}

// ---------------------------------------------------------------- ui_tree

/// `ui_tree`: the pruned tree of `window`, or with `since_last` only what
/// changed since the last tree of that window.
pub fn tree(ctx: anytype, window: ?u64, since_last: bool) Result {
    return treeOf(ctx, window, since_last, true);
}

fn treeOf(ctx: anytype, window: ?u64, since_last: bool, record: bool) Result {
    const s = switch (snapshot(ctx, window, record)) {
        .ok => |s| s,
        .err => |e| return Result.err(e),
    };
    return treeText(ctx, s, window == null, since_last) catch Result.err(oom);
}

fn treeText(ctx: anytype, s: Snap, foreground: bool, since_last: bool) !Result {
    const a = ctx.arena;
    const gpa = ctx.session.gpa;
    const ui = &ctx.session.ui;
    const els = s.snap.elements;
    const win = s.snap.window;
    const kept = try uitree.prune(a, els, s.viewport, .{});
    const ids = try a.alloc(u32, kept.len);
    const shown = try a.alloc(uitree.Shown, kept.len);
    for (kept, 0..) |k, i| {
        ids[i] = try ui.ids.assign(gpa, els[k.index].key, win);
        shown[i] = uitree.shownOf(ids[i], els[k.index], s.m);
    }

    var note: ?[]const u8 = null;
    var delta: ?[]const u8 = null;
    if (since_last) {
        const last = ui.store.last_window;
        if (foreground and last != null and last.? != win) {
            note = "Fenêtre au premier plan changée : arbre complet de la nouvelle fenêtre.";
        } else if (ui.store.get(win)) |prev| {
            ctx.timings.start(ctx.io, .diff);
            const d = uitree.diff(a, prev, shown);
            ctx.timings.stop(ctx.io, .diff);
            delta = try deltaText(a, s, kept, shown, try d);
        } else note = "Aucun arbre précédent de cette fenêtre : arbre complet.";
    }
    const full = try fullText(a, s, kept, ids, els.len, note);
    try ui.store.put(gpa, win, shown);
    if (delta) |d| if (d.len <= full.len) return Result.text(d);
    return Result.text(full);
}

fn writeFlags(w: *std.Io.Writer, snap: uitree.Snapshot) !void {
    if (snap.partial) try w.writeAll("{partial: timeout}\n");
    if (snap.desktop) try w.writeAll("Aucune fenêtre active : arbre du bureau renvoyé\n");
}

fn fullText(a: std.mem.Allocator, s: Snap, kept: []const uitree.Kept, ids: []const u32, total: usize, note: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try writeFlags(w, s.snap);
    if (note) |n| try w.print("{s}\n", .{n});
    try uitree.writeHeader(w, s.m, s.snap.window);
    try w.writeByte('\n');
    var shown: usize = 0;
    for (kept, ids) |k, id| {
        const mark = out.written().len;
        try uitree.writeLine(w, k.depth, id, s.snap.elements[k.index], s.m);
        if (out.written().len > max_text_output - 160) {
            out.shrinkRetainingCapacity(mark);
            break;
        }
        shown += 1;
    }
    if (total > shown) try w.print("… {d} nœuds élagués\n", .{total - shown});
    if (s.snap.web_pending) {
        try w.writeAll("Contenu web pas encore exposé (Chromium le construit à la première lecture) : rappelle ui_tree dans 1 s, ou utilise screenshot.\n");
    } else if (kept.len <= 2) {
        // Electron apps without accessibility expose a bare window.
        try w.writeAll("Arbre presque vide (fréquent avec Electron) : utilise screenshot pour voir cette fenêtre.\n");
    }
    return std.mem.trimEnd(u8, out.written(), "\n");
}

fn deltaText(a: std.mem.Allocator, s: Snap, kept: []const uitree.Kept, shown: []const uitree.Shown, d: uitree.Delta) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try writeFlags(w, s.snap);
    try uitree.writeHeader(w, s.m, s.snap.window);
    if (d.entries.len == 0 and d.removed.len == 0) {
        try w.writeAll(" delta: aucun changement");
        return out.written();
    }
    var added: usize = 0;
    for (d.entries) |e| added += @intFromBool(e.kind == .added);
    try w.print(" delta +{d} -{d} ~{d}\n", .{ added, d.removed.len, d.entries.len - added });
    for (d.entries) |e| {
        try w.writeAll(if (e.kind == .added) "+ " else "~ ");
        try uitree.writeLine(w, 0, shown[e.index].id, s.snap.elements[kept[e.index].index], s.m);
    }
    for (d.removed) |r| {
        try w.writeAll("- ");
        try uitree.writeId(w, r.id);
        try w.print(" {t}\n", .{r.role});
    }
    return std.mem.trimEnd(u8, out.written(), "\n");
}

// ---------------------------------------------------------------- ui_find

/// `ui_find`: elements of `window` matching `query`, at most 20 lines in the
/// ui_tree format. Off-screen elements are included (scroll_into_view).
pub fn find(ctx: anytype, query: []const u8, window: ?u64) Result {
    const q = switch (uitree.Query.parse(ctx.arena, query) catch return Result.err(oom)) {
        .ok => |q| q,
        .err => |e| return Result.err(e),
    };
    const s = switch (snapshot(ctx, window, true)) {
        .ok => |s| s,
        .err => |e| return Result.err(e),
    };
    return findText(ctx, q, query, s) catch Result.err(oom);
}

fn findText(ctx: anytype, q: uitree.Query, query: []const u8, s: Snap) !Result {
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &out.writer;
    try writeFlags(w, s.snap);
    try uitree.writeHeader(w, s.m, s.snap.window);
    try w.writeByte('\n');
    var matched: usize = 0;
    for (s.snap.elements) |e| {
        if (!try q.matches(ctx.arena, e)) continue;
        matched += 1;
        if (matched > max_find_lines) continue;
        const id = try ctx.session.ui.ids.assign(ctx.session.gpa, e.key, s.snap.window);
        try uitree.writeLine(w, 0, id, e, s.m);
    }
    if (matched == 0) try w.print("Aucun élément ne correspond à `{s}` : essaie un autre nom, role:<rôle>, state:<état> ou ui_tree.\n", .{query});
    if (matched > max_find_lines) try w.print("… {d} autres résultats : précise la requête.\n", .{matched - max_find_lines});
    return Result.text(std.mem.trimEnd(u8, out.written(), "\n"));
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

/// Window of the element `id_text`, for the post-action observation.
pub fn windowOf(ctx: anytype, id_text: []const u8) ?u64 {
    const id = uitree.parseId(id_text) orelse return null;
    return if (ctx.session.ui.ids.owner(id)) |o| o.window else null;
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

/// Waits until no dirty rect touches the target window (`window`, else the
/// foreground one, read again on every capture so a dialog that opens counts)
/// on two captures at least 50 ms apart, or until `timeout_ms`. Changes
/// elsewhere, such as the client's own spinner in its terminal, are ignored.
/// Timed as the `settle` stage, apart from the capture budgets.
pub fn settle(ctx: anytype, timeout_ms: u32, window: ?u64) Settled {
    ctx.timings.start(ctx.io, .settle);
    defer ctx.timings.stop(ctx.io, .settle);
    const start = timing.now(ctx.io);
    const ms = std.time.ns_per_ms;
    var quiet_since: ?i96 = null;
    while (true) {
        const area = ctx.backend.windowRect(window);
        const displays = ctx.backend.displays();
        const index = if (area) |a| display.displayAt(displays, a.x + @divTrunc(a.w, 2), a.y + @divTrunc(a.h, 2)) orelse 0 else ctx.backend.foregroundDisplay() orelse 0;
        const frame = switch (ctx.backend.capture(index, ctx.arena)) {
            .frame => |f| f,
            .failed => |msg| return .{ .unavailable = msg },
        };
        const t = timing.now(ctx.io);
        if (frame.fresh and (touches(frame.dirty, area) or touches(frame.moved, area))) {
            quiet_since = null;
        } else if (quiet_since) |q| {
            if (t - q >= quiet_ms * ms) return .{ .settled = @intCast(@divTrunc(t - start, ms)) };
        } else quiet_since = t;
        if (t - start >= @as(i96, timeout_ms) * ms) return .timeout;
        if (!ctx.sleep(10 * ms)) return .cancelled;
    }
}

/// Completes the result of an action tool with the requested observation
/// (`observe`, default delta, screenshot in vision mode) once the screen has
/// settled. A failed action, or `observe: "none"`, returns as is.
pub fn observeAfter(ctx: anytype, r: Result, observe: ?Observe, settle_timeout_ms: ?u32, window: ?u64) Result {
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
            const obs = treeOf(ctx, window, true, false);
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
