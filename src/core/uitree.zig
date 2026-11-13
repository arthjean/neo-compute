//! Accessibility trees in the portable core: the elements a backend reads
//! (pre-order, with depth), pruning, the one-line-per-element format
//! (US-011), session-stable ids and differential observations (US-012), and
//! the matching of ui_find (US-013). Nothing here calls a platform API.

const std = @import("std");
const display = @import("display.zig");
const Rect = display.Rect;
const Mapping = display.Mapping;

pub const Role = enum(u8) {
    button,
    calendar,
    checkbox,
    combobox,
    edit,
    link,
    image,
    listitem,
    list,
    menu,
    menubar,
    menuitem,
    progressbar,
    radio,
    scrollbar,
    slider,
    spinner,
    statusbar,
    tab,
    tabitem,
    text,
    toolbar,
    tooltip,
    tree,
    treeitem,
    custom,
    group,
    thumb,
    datagrid,
    dataitem,
    document,
    splitbutton,
    window,
    pane,
    header,
    headeritem,
    table,
    titlebar,
    separator,
    semanticzoom,
    appbar,
    unknown,
};

/// Element states, in output order.
pub const States = packed struct(u8) {
    focused: bool = false,
    disabled: bool = false,
    checked: bool = false,
    mixed: bool = false,
    expanded: bool = false,
    collapsed: bool = false,
    selected: bool = false,
    offscreen: bool = false,

    fn bits(s: States) u8 {
        return @bitCast(s);
    }
};

/// Actionable patterns an element supports.
pub const Actions = packed struct(u8) {
    invoke: bool = false,
    value: bool = false,
    toggle: bool = false,
    expand_collapse: bool = false,
    select: bool = false,
    scroll: bool = false,
    _pad: u2 = 0,

    pub fn any(a: Actions) bool {
        return @as(u8, @bitCast(a)) != 0;
    }
};

/// RangeValue of a slider, spinner or progress bar (US-022).
pub const Range = struct {
    value: f64,
    min: f64,
    max: f64,
    read_only: bool = false,
};

/// Scroll position of a container in percent (US-022); null on an axis that
/// does not scroll (UIA_ScrollPatternNoScroll).
pub const Scroll = struct {
    v: ?f32 = null,
    h: ?f32 = null,

    pub fn any(s: Scroll) bool {
        return s.v != null or s.h != null;
    }
};

/// Characters of a selection shown on the focused element's line.
pub const max_selection_chars = 100;

/// One element as a backend reads it. A backend never fills `value` or
/// `selection` for a password field; the formatter masks them regardless
/// (FR-09).
pub const Element = struct {
    /// Hash of the platform's runtime identifier (UIA RuntimeId).
    key: u64,
    /// Depth below the window element (0).
    depth: u16,
    role: Role,
    name: []const u8 = "",
    value: ?[]const u8 = null,
    password: bool = false,
    states: States = .{},
    actions: Actions = .{},
    /// Physical desktop pixels.
    rect: Rect,
    range: ?Range = null,
    scroll: ?Scroll = null,
    /// Selected text of the element with the keyboard focus, at most
    /// `max_selection_chars` characters.
    selection: ?[]const u8 = null,
};

/// A top-level window read along with the target window (US-023): one it
/// owns, a menu, or a popup of its process.
pub const RootWindow = struct { handle: u64, pid: u32 };

/// A root of a snapshot: its element and the elements after it, up to the
/// next root, are its tree.
pub const Root = struct {
    /// Index of the root element in `Snapshot.elements`.
    start: u32,
    handle: u64,
    /// WindowPattern.IsModal, or an owner window that is disabled.
    modal: bool = false,
    /// Nothing of the window shows under the windows above it (US-059);
    /// filled by the core.
    occluded: bool = false,
};

/// What a snapshot reads beyond the target window's tree.
pub const Request = struct {
    /// Further roots, top of the z-order first, after the policy kept them.
    extra_roots: []const RootWindow = &.{},
    /// The web document's text nodes too (US-024).
    text: bool = false,
};

/// Outcome of `Request.text` (US-024).
pub const WebText = enum {
    not_requested,
    /// The web document's subtree holds its text nodes, in reading order.
    read,
    /// The window has no web document.
    no_document,
};

pub const Snapshot = struct {
    window: u64,
    /// Pre-order; element 0 is the window, and every root element (depth
    /// 0) starts its own tree.
    elements: []const Element,
    /// Empty: a single root, the window.
    roots: []const Root = &.{},
    /// The provider timed out: only part of the tree was read.
    partial: bool = false,
    /// No window was active: this is the taskbar's tree.
    desktop: bool = false,
    /// A Chromium or Electron window whose web content is not in the tree
    /// yet: Chromium builds it after the first UIA request.
    web_pending: bool = false,
    /// A Firefox window that exposes only its frame: its accessibility is
    /// off (`accessibility.force_disabled`, US-025).
    firefox_no_tree: bool = false,
    web_text: WebText = .not_requested,
    /// Vertical scroll position of the web document, when its text was read.
    page: ?Page = null,

    /// The roots; the window alone, in `single`, when the backend listed
    /// none.
    pub fn rootList(self: *const Snapshot, single: *[1]Root) []const Root {
        if (self.roots.len > 0) return self.roots;
        single.* = .{.{ .start = 0, .handle = self.window }};
        return single;
    }

    /// End (exclusive) of root `i`'s elements.
    pub fn rootEnd(self: *const Snapshot, roots: []const Root, i: usize) u32 {
        return if (i + 1 < roots.len) roots[i + 1].start else @intCast(self.elements.len);
    }
};

pub const SnapshotResult = union(enum) { ok: Snapshot, err: []const u8 };

/// The subtree below one element (US-056): a snapshot whose element 0 is
/// that element, at depth 0, and whose only root is its window.
pub const SubtreeResult = union(enum) { ok: Snapshot, gone, failed: []const u8 };

/// One element read alone, as a snapshot would read it (US-057).
pub const ElementResult = union(enum) { ok: Element, gone, failed: []const u8 };

/// What `ui_act` does to an element. `check`, `uncheck` and `scroll` came
/// with EP-013 (decision 0013).
pub const Action = enum { invoke, toggle, check, uncheck, select, expand, collapse, set_value, scroll, scroll_into_view, focus };

pub const Toggle = enum { off, on, mixed };
pub const Expand = enum { collapsed, expanded, partial, leaf };

/// One element as it is now, read in one round trip before an action (its
/// preconditions) and after it (its effect).
pub const Live = struct {
    enabled: bool = true,
    offscreen: bool = false,
    password: bool = false,
    /// Physical desktop pixels.
    rect: Rect,
    actions: Actions = .{},
    /// The Value pattern refuses writes.
    read_only: bool = false,
    toggle: ?Toggle = null,
    expand: ?Expand = null,
    selected: ?bool = null,
    range: ?Range = null,
    /// The element's own Scroll pattern; null without the pattern.
    scroll: ?Scroll = null,
    /// `textHash` of the Value pattern's text, when the read asked for it.
    /// Never read for a password field (FR-09).
    value_hash: ?u64 = null,
};

pub const LiveResult = union(enum) { ok: Live, gone, failed: []const u8 };

/// What a live read is for. `all`: what an action needs before it runs.
/// `value`: the same plus the value's hash. The others: the one state an
/// action reads back, the only field the result then fills, which costs
/// a backend a single property.
pub const LiveRead = enum { all, value, toggle, expand, selected };

/// Hash of a value as UTF-16, the form a backend reads it in: a value is
/// compared with the one written without either being kept (FR-09).
pub fn textHash(units: []const u16) u64 {
    return std.hash.Wyhash.hash(0x76616c, std.mem.sliceAsBytes(units));
}

/// `textHash` of UTF-8 `text`; null when it is not valid UTF-8.
pub fn textHashUtf8(arena: std.mem.Allocator, text: []const u8) ?u64 {
    const units = std.unicode.utf8ToUtf16LeAlloc(arena, text) catch return null;
    defer @memset(units, 0);
    return textHash(units);
}

pub const ScrollAmount = enum { none, small_back, small_forward, large_back, large_forward };
pub const ScrollStep = struct { h: ScrollAmount = .none, v: ScrollAmount = .none };

/// One pattern call on an element. The core picks it from the action and
/// the element's live state; the backend runs it and nothing else.
pub const Op = union(enum) {
    invoke,
    /// LegacyIAccessible.DoDefaultAction, when the default action is named.
    legacy,
    toggle,
    select,
    expand,
    collapse,
    focus,
    /// ScrollItem.ScrollIntoView.
    scroll_item,
    set_value: []const u8,
    /// RangeValue.SetValue.
    set_range: f64,
    /// Scroll.Scroll, one increment per axis.
    scroll: ScrollStep,
    /// Scroll.SetScrollPercent; a null axis stays where it is.
    scroll_to: struct { h: ?f64 = null, v: ?f64 = null },
};

pub const OpResult = union(enum) {
    ok,
    /// Sent, but the provider did not answer within the UIA timeout.
    timeout,
    /// The element no longer exists.
    gone,
    /// The pattern is missing.
    unsupported,
    read_only,
    failed: []const u8,
};

/// A selectable descendant of a container (US-053).
pub const Entry = struct { key: u64, name: []const u8 };
pub const EntriesResult = union(enum) { ok: []const Entry, gone, failed: []const u8 };
/// Entries read from one container at most.
pub const max_entries = 500;

/// Levels above an element searched for a scrollable container (US-052).
pub const max_scroll_levels = 8;

/// The `value` of `ui_act scroll` (US-052).
pub const ScrollSpec = union(enum) {
    step: struct { dir: Dir, count: u8 },
    page: enum { up, down },
    edge: enum { top, bottom },
    percent: f64,

    pub const Dir = enum { up, down, left, right };
    pub const forms = "up, down, left ou right suivi d'un nombre de crans de 1 à 100 (défaut 1), page_up, page_down, top, bottom, ou <n>% de 0 à 100";

    pub fn parse(text: []const u8) ?ScrollSpec {
        const t = std.mem.trim(u8, text, " ");
        if (t.len == 0) return null;
        if (t[t.len - 1] == '%') {
            const p = std.fmt.parseFloat(f64, std.mem.trim(u8, t[0 .. t.len - 1], " ")) catch return null;
            return if (std.math.isFinite(p) and p >= 0 and p <= 100) .{ .percent = p } else null;
        }
        if (std.mem.eql(u8, t, "page_up")) return .{ .page = .up };
        if (std.mem.eql(u8, t, "page_down")) return .{ .page = .down };
        if (std.mem.eql(u8, t, "top")) return .{ .edge = .top };
        if (std.mem.eql(u8, t, "bottom")) return .{ .edge = .bottom };
        var it = std.mem.tokenizeScalar(u8, t, ' ');
        const dir = std.meta.stringToEnum(Dir, it.next() orelse return null) orelse return null;
        const count: u8 = if (it.next()) |n| std.fmt.parseInt(u8, n, 10) catch return null else 1;
        if (it.next() != null or count < 1 or count > 100) return null;
        return .{ .step = .{ .dir = dir, .count = count } };
    }
};

pub const Limits = struct {
    depth: u16 = 25,
    nodes: usize = 1500,
    chars: usize = 8000,
    /// A web page's text is read (US-024): a wrapper whose name holds more
    /// than its one kept descendant's name stays, since that name is text.
    text: bool = false,
};

/// Raw elements beyond this count are not read (arena bound for huge trees).
pub const max_elements = 50_000;

// ---------------------------------------------------------------- pruning

pub const Kept = struct {
    index: u32,
    /// Depth among kept elements, for indentation.
    depth: u16,
};

/// ScrollItem alone does not make an element worth showing: XAML and web
/// providers expose it on nearly every element. An empty value counts only
/// for a field the model can type into.
fn actionable(e: Element) bool {
    // A slider or a scrollable container: its position is what the model
    // reads (US-022).
    if (e.range != null) return true;
    if (e.scroll) |sc| if (sc.any()) return true;
    var a = e.actions;
    a.scroll = false;
    a.value = false;
    if (a.any() or e.password) return true;
    const v = e.value orelse return false;
    return v.len > 0 or e.role == .edit or e.role == .combobox;
}

/// A nameless container or text whose only action is Invoke: web providers
/// expose Invoke on every element with a click handler (VS Code wraps each
/// button in such divs), and the line says nothing the model can act on.
fn weakInvoke(e: Element) bool {
    if (e.range != null) return false;
    if (e.scroll) |sc| if (sc.any()) return false;
    switch (e.role) {
        .group, .pane, .text, .custom, .unknown => {},
        else => return false,
    }
    var a = e.actions;
    a.scroll = false;
    a.invoke = false;
    a.value = false;
    if (a.any() or e.password) return false;
    const v = e.value orelse return true;
    return v.len == 0;
}

/// A name with something besides spaces (web pages expose " " separators)
/// and icon-font glyphs (Private Use Area, as VS Code's codicons).
fn named(e: Element) bool {
    var it = (std.unicode.Utf8View.init(e.name) catch return e.name.len > 0).iterator();
    while (it.nextCodepoint()) |c| switch (c) {
        ' ', '\t', '\r', '\n', 0xa0, 0xe000...0xf8ff => {},
        else => return true,
    };
    return false;
}

/// Keeps elements inside `viewport` that have a name or an actionable
/// pattern, plus the named ancestors of kept elements; removes the others
/// (their kept descendants move up), merges non-actionable containers with a
/// single kept child into that child, and drops a non-actionable leaf that
/// only repeats its parent's name (a button's own label). The window element
/// is always kept. At most `limits.nodes` elements, in pre-order.
pub fn prune(arena: std.mem.Allocator, elements: []const Element, viewport: Rect, limits: Limits) ![]Kept {
    const n = elements.len;
    if (n == 0) return &.{};
    const parent = try arena.alloc(u32, n);
    const depth = try arena.alloc(u16, n);
    const below = try arena.alloc(u32, n);
    const keep = try arena.alloc(bool, n);
    // A nearest kept descendant of i: the only one when below[i] == 1.
    const rep = try arena.alloc(u32, n);
    const stack = try arena.alloc(u32, @min(n, std.math.maxInt(u16)));
    @memset(below, 0);

    // Depths are made well-formed: a child is one level below its parent.
    for (elements, 0..) |e, i| {
        const d: u16 = if (i == 0) 0 else @max(1, @min(e.depth, depth[i - 1] + 1, @as(u16, @intCast(stack.len - 1))));
        depth[i] = d;
        stack[d] = @intCast(i);
        parent[i] = if (d == 0) 0 else stack[d - 1];
    }

    // Children follow their parent in pre-order, so a reverse walk sees every
    // descendant before its ancestor. `below[i]` counts the nearest kept
    // descendants of i.
    var i = n;
    while (i > 0) {
        i -= 1;
        const e = elements[i];
        if (depth[i] > limits.depth) {
            keep[i] = false;
            continue;
        }
        const visible = !e.states.offscreen and e.rect.w > 0 and e.rect.h > 0 and e.rect.intersects(viewport);
        const has_name = named(e);
        const act = actionable(e) and (has_name or !weakInvoke(e));
        var k = i == 0 or (visible and (has_name or act)) or (has_name and below[i] > 0);
        if (k and i != 0 and !act and below[i] == 1 and !(limits.text and e.name.len > elements[rep[i]].name.len)) k = false;
        if (k and i != 0 and !act and below[i] == 0 and std.mem.eql(u8, e.name, elements[parent[i]].name)) k = false;
        // A wrapper around one actionable element of the same name (web
        // status bars: group "LF" > button "LF"): the element stays.
        if (k and i != 0 and below[i] == 1 and has_name and actionable(elements[rep[i]]) and std.mem.eql(u8, e.name, elements[rep[i]].name)) k = false;
        keep[i] = k;
        if (i != 0) {
            const contributes = k or below[i] > 0;
            if (contributes) rep[parent[i]] = if (k) @intCast(i) else rep[i];
            below[parent[i]] += if (k) 1 else below[i];
        }
    }

    var out: std.ArrayList(Kept) = .empty;
    try out.ensureTotalCapacity(arena, @min(n, limits.nodes));
    // Kept-ancestor depth, reusing `below`.
    for (0..n) |j| {
        const kd: u32 = if (j == 0) 0 else below[parent[j]] + @intFromBool(keep[parent[j]]);
        if (j != 0) below[j] = kd else below[0] = 0;
        if (keep[j] and out.items.len < limits.nodes) out.appendAssumeCapacity(.{ .index = @intCast(j), .depth = @intCast(@min(kd, limits.depth)) });
    }
    return out.items;
}

// ---------------------------------------------------------------- format

const max_name_chars = 80;
const max_value_chars = 60;

/// Text of an element's name or value: quotes become apostrophes, control
/// characters spaces, truncated to `max` code points with an ellipsis.
fn writeText(w: *std.Io.Writer, text: []const u8, max: usize) !void {
    const view = std.unicode.Utf8View.init(text) catch return w.writeByte('?');
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepointSlice()) |cp| : (count += 1) {
        if (count == max) return w.writeAll("…");
        if (cp.len == 1 and (cp[0] < 0x20 or cp[0] == 0x7f)) {
            try w.writeByte(' ');
        } else if (cp.len == 1 and cp[0] == '"') {
            try w.writeByte('\'');
        } else try w.writeAll(cp);
    }
}

pub fn writeId(w: *std.Io.Writer, id: u32) !void {
    try w.writeByte('e');
    try w.printInt(id, 36, .lower, .{});
}

/// Parses an element id (`e1k`).
pub fn parseId(text: []const u8) ?u32 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len < 2 or t[0] != 'e') return null;
    for (t[1..]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'z')) return null;
    const v = std.fmt.parseInt(u32, t[1..], 36) catch return null;
    return if (v == 0) null else v;
}

pub const password_mask = "•••";

/// A number with at most two decimals, trailing zeros dropped.
pub fn writeNumber(w: *std.Io.Writer, x: f64) !void {
    if (!std.math.isFinite(x) or @abs(x) > 1e15) return w.writeByte('?');
    const r = @round(x * 100) / 100;
    if (r == @round(r)) return w.print("{d}", .{@as(i64, @intFromFloat(r))});
    var buf: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.2}", .{r}) catch return w.writeByte('?');
    try w.writeAll(std.mem.trimEnd(u8, text, "0"));
}

fn percent(p: f32) i32 {
    if (!std.math.isFinite(p)) return 0;
    return @intFromFloat(@round(std.math.clamp(p, 0, 100)));
}

/// `<id> <role> "<name>" [=value] sel="<text>" {states} scroll=<v>%,h<h>%
/// @x,y,w,h` (US-011, US-022), the rectangle in screenshot pixels of `m`'s
/// display. A range shows as `[=<value>/<min>..<max>]` in place of a value.
pub fn writeLine(w: *std.Io.Writer, indent: u16, id: u32, e: Element, m: Mapping) !void {
    return writeLineMax(w, indent, id, e, m, max_name_chars, null);
}

/// Characters of a text node's name in a web page's text (US-024).
pub const max_text_chars = 400;

/// A web document's vertical position (US-024).
pub const Page = union(enum) {
    /// Scrolled to this percent of its height.
    at: f32,
    /// Shorter than its viewport: nothing to scroll.
    fits,
};

/// A line of a web page's text (US-024): a text node, or an element that
/// is not actionable and carries text under its name, as a Chromium list
/// item whose name joins its link and the text after it.
pub fn textLine(e: Element) bool {
    return e.role == .text or (!actionable(e) and named(e));
}

/// `writeLine` with a name limit, and for a web document the page
/// position (` page=<p>%`, then ` début` or ` fin` at an end, US-024).
pub fn writeLineMax(w: *std.Io.Writer, indent: u16, id: u32, e: Element, m: Mapping, name_max: usize, page: ?Page) !void {
    try w.splatByteAll(' ', @as(usize, indent) * 2);
    try writeId(w, id);
    try w.print(" {t} \"", .{e.role});
    try writeText(w, e.name, name_max);
    try w.writeByte('"');
    // A link's value is its URL: costly, and the name is enough to act.
    if (e.password) {
        try w.writeAll(" [=" ++ password_mask ++ "]");
    } else if (e.range) |r| {
        try w.writeAll(" [=");
        try writeNumber(w, r.value);
        try w.writeByte('/');
        try writeNumber(w, r.min);
        try w.writeAll("..");
        try writeNumber(w, r.max);
        try w.writeByte(']');
    } else if (e.value) |v| if (v.len > 0 and e.role != .link) {
        try w.writeAll(" [=");
        try writeText(w, v, max_value_chars);
        try w.writeByte(']');
    };
    // FR-09: a password field never shows a selection.
    if (!e.password) if (e.selection) |sel| if (sel.len > 0) {
        try w.writeAll(" sel=\"");
        try writeText(w, sel, max_selection_chars);
        try w.writeByte('"');
    };
    if (e.states.bits() != 0) {
        try w.writeAll(" {");
        var first = true;
        inline for (@typeInfo(States).@"struct".field_names) |f| if (@field(e.states, f)) {
            if (!first) try w.writeByte(',');
            try w.writeAll(f);
            first = false;
        };
        try w.writeByte('}');
    }
    if (e.scroll) |sc| if (sc.any()) {
        try w.writeByte(' ');
        try writeScroll(w, sc);
    };
    if (page) |pg| switch (pg) {
        .at => |p| {
            try w.print(" page={d}%", .{percent(p)});
            if (p <= 0) try w.writeAll(" début") else if (p >= 100) try w.writeAll(" fin");
        },
        // Not scrollable: the top and the bottom are both in view.
        .fits => try w.writeAll(" page=0% début fin"),
    };
    const r = m.rectToScreenshot(e.rect);
    try w.print(" @{d},{d},{d},{d}\n", .{ r.x, r.y, r.w, r.h });
}

/// `scroll=<v>%,h<h>%`: the axes that scroll; nothing when none does.
pub fn writeScroll(w: *std.Io.Writer, sc: Scroll) !void {
    if (!sc.any()) return;
    try w.writeAll("scroll=");
    if (sc.v) |v| try w.print("{d}%", .{percent(v)});
    if (sc.h) |h| try w.print("{s}h{d}%", .{ if (sc.v != null) "," else "", percent(h) });
}

/// `display=<n> scale=<s> window=0x<handle>`. The root element's line that
/// follows gives the root's role and name.
pub fn writeHeader(w: *std.Io.Writer, m: Mapping, window: u64) !void {
    var sbuf: [32]u8 = undefined;
    try w.print("display={d} scale={s} window=0x{x}", .{ m.display, display.scaleText(&sbuf, m.scale), window });
}

/// The header of a root, ` {modal}` after it for a modal one (US-023) and
/// ` {occluded}` for one entirely covered (US-059).
pub fn writeRootHeader(w: *std.Io.Writer, m: Mapping, root: Root) !void {
    try writeHeader(w, m, root.handle);
    if (root.modal) try w.writeAll(" {modal}");
    if (root.occluded) try w.writeAll(" {occluded}");
}

// ---------------------------------------------------------------- ids

/// Session-stable element ids: an element keeps its id as long as it
/// exists, and an id is never reused (FR-05).
pub const Ids = struct {
    by_key: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    owners: std.ArrayList(Owner) = .empty,

    /// `window`: the root the element belongs to, which the policy checks
    /// and the action targets; `tree`: the window whose tree listed it,
    /// which the post-action observation reads (a menu closes once used).
    pub const Owner = struct { key: u64, window: u64, tree: u64 };

    pub fn deinit(self: *Ids, gpa: std.mem.Allocator) void {
        self.by_key.deinit(gpa);
        self.owners.deinit(gpa);
    }

    pub fn assign(self: *Ids, gpa: std.mem.Allocator, key: u64, window: u64) !u32 {
        return self.assignIn(gpa, key, window, window);
    }

    pub fn assignIn(self: *Ids, gpa: std.mem.Allocator, key: u64, window: u64, tree: u64) !u32 {
        const gop = try self.by_key.getOrPut(gpa, key);
        if (gop.found_existing) {
            const o = &self.owners.items[gop.value_ptr.* - 1];
            o.window = window;
            o.tree = tree;
            return gop.value_ptr.*;
        }
        self.owners.append(gpa, .{ .key = key, .window = window, .tree = tree }) catch |err| {
            self.by_key.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.value_ptr.* = @intCast(self.owners.items.len);
        return gop.value_ptr.*;
    }

    pub fn owner(self: *const Ids, id: u32) ?Owner {
        if (id == 0 or id > self.owners.items.len) return null;
        return self.owners.items[id - 1];
    }
};

// ---------------------------------------------------------------- diff

/// What the model was last shown of an element, for deltas.
pub const Shown = struct {
    id: u32,
    role: Role,
    states: States,
    name_hash: u64,
    value_hash: u64,
    /// Screenshot pixels.
    rect: Rect,
};

fn hashText(t: []const u8) u64 {
    return std.hash.Wyhash.hash(0, t);
}

pub fn shownOf(id: u32, e: Element, m: Mapping) Shown {
    const value: []const u8 = if (e.password) password_mask else e.value orelse "";
    var states = e.states;
    states.offscreen = false; // scrolling must not flood deltas with state changes
    return .{ .id = id, .role = e.role, .states = states, .name_hash = hashText(e.name), .value_hash = valueHash(e, value), .rect = m.rectToScreenshot(e.rect) };
}

/// Hash of what the line shows besides the name: value, range, scroll
/// position and selection (US-022), as formatted, so a change too small to
/// show does not count.
fn valueHash(e: Element, value: []const u8) u64 {
    if (e.range == null and e.scroll == null and e.selection == null) return hashText(value);
    var h: std.hash.Wyhash = .init(0);
    h.update(value);
    if (e.range) |r| {
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        writeNumber(&w, r.value) catch {};
        w.writeByte('/') catch {};
        writeNumber(&w, r.min) catch {};
        w.writeByte('/') catch {};
        writeNumber(&w, r.max) catch {};
        h.update("\x01");
        h.update(w.buffered());
    }
    if (e.scroll) |sc| {
        const v: i32 = if (sc.v) |x| percent(x) else -1;
        const hz: i32 = if (sc.h) |x| percent(x) else -1;
        h.update("\x02");
        h.update(std.mem.asBytes(&v));
        h.update(std.mem.asBytes(&hz));
    }
    if (!e.password) if (e.selection) |sel| {
        h.update("\x03");
        h.update(sel);
    };
    return h.final();
}

/// Position changes up to this many screenshot pixels are ignored.
pub const move_threshold = 4;

fn moved(a: Rect, b: Rect) bool {
    return @abs(a.x - b.x) > move_threshold or @abs(a.y - b.y) > move_threshold or
        @abs(a.w - b.w) > move_threshold or @abs(a.h - b.h) > move_threshold;
}

pub const Change = enum { added, changed };

pub const Delta = struct {
    /// Indexes into the new list with their kind, in its order.
    entries: []const struct { index: u32, kind: Change },
    removed: []const Shown,
};

/// Changes from `old` to `new`: additions, removals, and changes of name,
/// value, states or position beyond `move_threshold`.
pub fn diff(arena: std.mem.Allocator, old: []const Shown, new: []const Shown) !Delta {
    var index: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try index.ensureTotalCapacity(arena, @intCast(old.len));
    for (old, 0..) |s, i| index.putAssumeCapacity(s.id, @intCast(i));
    const seen = try arena.alloc(bool, old.len);
    @memset(seen, false);
    const DeltaEntry = @typeInfo(@FieldType(Delta, "entries")).pointer.child;
    var entries: std.ArrayList(DeltaEntry) = .empty;
    for (new, 0..) |s, i| {
        const j = index.get(s.id) orelse {
            try entries.append(arena, .{ .index = @intCast(i), .kind = .added });
            continue;
        };
        seen[j] = true;
        const o = old[j];
        if (o.name_hash != s.name_hash or o.value_hash != s.value_hash or o.states.bits() != s.states.bits() or o.role != s.role or moved(o.rect, s.rect))
            try entries.append(arena, .{ .index = @intCast(i), .kind = .changed });
    }
    var removed: std.ArrayList(Shown) = .empty;
    for (old, seen) |o, s| if (!s) try removed.append(arena, o);
    return .{ .entries = entries.items, .removed = removed.items };
}

/// The last tree shown for a few windows, and the window of the last one.
pub const Store = struct {
    slots: [slot_count]Slot = @splat(.{}),
    clock: u64 = 0,
    last_window: ?u64 = null,

    const slot_count = 4;
    const Slot = struct {
        window: u64 = 0,
        used: u64 = 0,
        nodes: std.ArrayList(Shown) = .empty,
        /// Handles of the roots shown, the window first (US-023).
        roots: std.ArrayList(u64) = .empty,
    };

    pub const Last = struct { nodes: []const Shown, roots: []const u64 };

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        for (&self.slots) |*s| {
            s.nodes.deinit(gpa);
            s.roots.deinit(gpa);
        }
    }

    pub fn get(self: *const Store, window: u64) ?[]const Shown {
        const last = self.getLast(window) orelse return null;
        return last.nodes;
    }

    pub fn getLast(self: *const Store, window: u64) ?Last {
        for (&self.slots) |*s| if (s.used != 0 and s.window == window) return .{ .nodes = s.nodes.items, .roots = s.roots.items };
        return null;
    }

    /// Records `nodes` as the last tree of `window`, evicting the least
    /// recently used window. Capacity is retained across calls.
    pub fn put(self: *Store, gpa: std.mem.Allocator, window: u64, nodes: []const Shown) !void {
        return self.putRoots(gpa, window, nodes, &.{window});
    }

    pub fn putRoots(self: *Store, gpa: std.mem.Allocator, window: u64, nodes: []const Shown, roots: []const u64) !void {
        var slot = &self.slots[0];
        for (&self.slots) |*s| {
            if (s.used != 0 and s.window == window) {
                slot = s;
                break;
            }
            if (s.used < slot.used) slot = s;
        }
        self.clock += 1;
        slot.window = window;
        slot.used = self.clock;
        slot.nodes.clearRetainingCapacity();
        slot.roots.clearRetainingCapacity();
        try slot.nodes.appendSlice(gpa, nodes);
        try slot.roots.appendSlice(gpa, roots);
        self.last_window = window;
    }
};

/// Session state of the accessibility tools.
pub const State = struct {
    ids: Ids = .{},
    store: Store = .{},

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.ids.deinit(gpa);
        self.store.deinit(gpa);
    }
};

// ---------------------------------------------------------------- search

/// Case- and accent-insensitive form of `text` (Latin letters), for
/// substring matching.
pub fn fold(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, text.len);
    var len: usize = 0;
    const view = std.unicode.Utf8View.init(text) catch return std.ascii.lowerString(out, text);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp_bytes| {
        const cp = std.unicode.utf8Decode(cp_bytes) catch unreachable;
        const base: ?u8 = if (cp < 0x80)
            std.ascii.toLower(@intCast(cp))
        else if (cp >= 0xC0 and cp <= 0xFF)
            latin1[cp - 0xC0]
        else if (cp >= 0x100 and cp <= 0x17F)
            latin_ext_a[cp - 0x100]
        else
            null;
        if (base) |b| {
            out[len] = b;
            len += 1;
        } else {
            @memcpy(out[len..][0..cp_bytes.len], cp_bytes);
            len += cp_bytes.len;
        }
    }
    return out[0..len];
}

const latin1 = "aaaaaaaceeeeiiiidnooooo*ouuuuytsaaaaaaaceeeeiiiidnooooo/ouuuuyty";
const latin_ext_a = "aaaaaa" ++ "cccccccc" ++ "dddd" ++ "eeeeeeeeee" ++ "gggggggg" ++ "hhhh" ++ "iiiiiiiiii" ++ "ii" ++ "jj" ++ "kkk" ++
    "llllllllll" ++ "nnnnnnnnn" ++ "oooooo" ++ "oo" ++ "rrrrrr" ++ "ssssssss" ++ "tttttt" ++ "uuuuuuuuuuuu" ++ "ww" ++ "yyy" ++ "zzzzzz" ++ "s";

comptime {
    std.debug.assert(latin1.len == 64);
    std.debug.assert(latin_ext_a.len == 128);
}

/// A parsed ui_find query: `role:<role>`, `state:<state>`, `value:<text>`,
/// name words and quoted names, all required; or `id:<id>` alone, which
/// reads one element again (US-057).
pub const Query = struct {
    role: ?Role = null,
    states: States = .{},
    /// Folded words the name must contain.
    words: []const []const u8 = &.{},
    /// Folded quoted terms: the whole name must be one of each.
    exact: []const []const u8 = &.{},
    /// Folded text the value must contain.
    value: ?[]const u8 = null,
    /// `id:<id>`: the element to read again, and its id as written.
    id: ?u32 = null,
    id_text: []const u8 = "",

    pub const Parsed = union(enum) { ok: Query, err: []const u8 };

    /// End of the quoted text that starts at `from`, and where the scan
    /// goes on.
    fn quoted(text: []const u8, from: usize) struct { end: usize, next: usize } {
        const end = std.mem.indexOfScalarPos(u8, text, from, '"') orelse text.len;
        return .{ .end = end, .next = @min(end + 1, text.len) };
    }

    pub fn parse(arena: std.mem.Allocator, text: []const u8) !Parsed {
        var q: Query = .{};
        var words: std.ArrayList([]const u8) = .empty;
        var exact: std.ArrayList([]const u8) = .empty;
        var terms: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == ' ') {
                i += 1;
                continue;
            }
            if (text[i] == '"') {
                const span = quoted(text, i + 1);
                const term = std.mem.trim(u8, text[i + 1 .. span.end], " ");
                i = span.next;
                if (term.len == 0) continue;
                try exact.append(arena, try fold(arena, term));
                terms += 1;
                continue;
            }
            // `value:"two words"`: the quotes hold the spaces.
            if (std.mem.startsWith(u8, text[i..], "value:\"")) {
                const span = quoted(text, i + 7);
                q.value = try fold(arena, text[i + 7 .. span.end]);
                i = span.next;
                terms += 1;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, text, i, ' ') orelse text.len;
            const term = text[i..end];
            i = end;
            terms += 1;
            if (std.mem.startsWith(u8, term, "role:")) {
                q.role = std.meta.stringToEnum(Role, term[5..]) orelse
                    return .{ .err = try std.fmt.allocPrint(arena, "Rôle `{s}` inconnu : rôles valides {s}.", .{ term[5..], role_names }) };
            } else if (std.mem.startsWith(u8, term, "state:")) {
                var found = false;
                inline for (@typeInfo(States).@"struct".field_names) |f| if (std.mem.eql(u8, f, term[6..])) {
                    @field(q.states, f) = true;
                    found = true;
                };
                if (!found) return .{ .err = try std.fmt.allocPrint(arena, "État `{s}` inconnu : états valides {s}.", .{ term[6..], state_names }) };
            } else if (std.mem.startsWith(u8, term, "value:")) {
                q.value = try fold(arena, term[6..]);
            } else if (std.mem.startsWith(u8, term, "id:")) {
                q.id_text = term[3..];
                q.id = parseId(term[3..]) orelse
                    return .{ .err = try std.fmt.allocPrint(arena, "Identifiant `{s}` invalide : id:<id> prend un id de ui_tree ou ui_find (ex. id:e1k).", .{term[3..]}) };
            } else try words.append(arena, try fold(arena, term));
        }
        q.words = words.items;
        q.exact = exact.items;
        if (q.value) |v| if (v.len == 0) return .{ .err = "value: demande un texte : value:<texte>, ou value:\"deux mots\"." };
        if (terms == 0)
            return .{ .err = "Requête vide : donne un nom, role:<rôle> ou state:<état>, par exemple role:button enregistrer." };
        if (q.id != null and terms > 1)
            return .{ .err = "id:<id> s'utilise seul : il relit un élément. Retire les autres termes, ou cherche sans id:." };
        return .{ .ok = q };
    }

    /// Whether `e` matches every term. A password field never matches
    /// `value:` (FR-09): a match would tell what it holds.
    pub fn matches(q: Query, arena: std.mem.Allocator, e: Element) !bool {
        if (q.role) |r| if (e.role != r) return false;
        if (e.states.bits() & q.states.bits() != q.states.bits()) return false;
        if (q.value) |want| {
            if (e.password) return false;
            var buf: [48]u8 = undefined;
            var number: std.Io.Writer = .fixed(&buf);
            // A slider's value is its number, as its line shows it.
            const shown: []const u8 = if (e.range) |r| blk: {
                writeNumber(&number, r.value) catch {};
                break :blk number.buffered();
            } else e.value orelse return false;
            if (std.mem.indexOf(u8, try fold(arena, shown), want) == null) return false;
        }
        if (q.words.len == 0 and q.exact.len == 0) return true;
        const name = try fold(arena, e.name);
        for (q.words) |word| if (std.mem.indexOf(u8, name, word) == null) return false;
        for (q.exact) |whole| if (!std.mem.eql(u8, std.mem.trim(u8, name, " "), whole)) return false;
        return true;
    }
};

const role_names = blk: {
    var s: []const u8 = "";
    for (@typeInfo(Role).@"enum".field_names, 0..) |n, i| s = s ++ (if (i == 0) "" else ", ") ++ n;
    break :blk s;
};

const state_names = blk: {
    var s: []const u8 = "";
    for (@typeInfo(States).@"struct".field_names, 0..) |n, i| s = s ++ (if (i == 0) "" else ", ") ++ n;
    break :blk s;
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "prune drops nameless and off-viewport elements, keeps named ancestors and merges single-child containers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const vp: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    const r: Rect = .{ .x = 10, .y = 10, .w = 50, .h = 20 };
    const off: Rect = .{ .x = 10, .y = 5000, .w = 50, .h = 20 };
    const els = [_]Element{
        .{ .key = 1, .depth = 0, .role = .window, .name = "W", .rect = vp },
        .{ .key = 2, .depth = 1, .role = .pane, .rect = r }, // nameless: removed, children move up
        .{ .key = 3, .depth = 2, .role = .button, .name = "A", .actions = .{ .invoke = true }, .rect = r },
        .{ .key = 4, .depth = 2, .role = .button, .name = "B", .actions = .{ .invoke = true }, .rect = r },
        .{ .key = 5, .depth = 1, .role = .group, .name = "Solo", .rect = r }, // one kept child: merged
        .{ .key = 6, .depth = 2, .role = .checkbox, .name = "C", .actions = .{ .toggle = true }, .rect = r },
        .{ .key = 7, .depth = 1, .role = .document, .name = "Doc", .rect = off }, // off viewport, named ancestor of kept
        .{ .key = 8, .depth = 2, .role = .link, .name = "L1", .actions = .{ .invoke = true }, .rect = r },
        .{ .key = 9, .depth = 2, .role = .link, .name = "L2", .actions = .{ .invoke = true }, .rect = r },
        .{ .key = 10, .depth = 2, .role = .link, .name = "Gone", .actions = .{ .invoke = true }, .rect = off },
        .{ .key = 11, .depth = 1, .role = .text, .name = "Hidden", .states = .{ .offscreen = true }, .rect = r },
        .{ .key = 12, .depth = 1, .role = .image, .actions = .{ .scroll = true }, .rect = r }, // ScrollItem alone
        .{ .key = 13, .depth = 1, .role = .button, .name = "OK", .actions = .{ .invoke = true }, .rect = r },
        .{ .key = 14, .depth = 2, .role = .text, .name = "OK", .rect = r }, // repeats its parent's name
        .{ .key = 15, .depth = 1, .role = .text, .name = " ", .rect = r }, // spaces only
        .{ .key = 16, .depth = 1, .role = .group, .value = "", .actions = .{ .value = true }, .rect = r }, // empty value, not a field
        .{ .key = 17, .depth = 1, .role = .edit, .value = "", .actions = .{ .value = true }, .rect = r }, // empty field: kept
        .{ .key = 18, .depth = 1, .role = .group, .actions = .{ .invoke = true }, .rect = r }, // nameless clickable div
        .{ .key = 19, .depth = 2, .role = .button, .name = "Toggle", .actions = .{ .invoke = true }, .rect = r }, // kept, promoted
        .{ .key = 20, .depth = 3, .role = .text, .actions = .{ .invoke = true }, .rect = r }, // icon glyph
        .{ .key = 21, .depth = 1, .role = .button, .actions = .{ .invoke = true }, .rect = r }, // nameless icon button: kept
        .{ .key = 22, .depth = 1, .role = .group, .name = "LF", .actions = .{ .invoke = true }, .rect = r }, // wraps its namesake
        .{ .key = 23, .depth = 2, .role = .button, .name = "LF", .actions = .{ .invoke = true }, .rect = r }, // kept
        .{ .key = 24, .depth = 1, .role = .text, .name = "\u{eb99}", .rect = r }, // icon glyph only
    };
    const kept = try prune(arena.allocator(), &els, vp, .{});
    var got: [16]u64 = undefined;
    var depths: [16]u16 = undefined;
    for (kept, 0..) |k, i| {
        got[i] = els[k.index].key;
        depths[i] = k.depth;
    }
    try testing.expectEqualSlices(u64, &.{ 1, 3, 4, 6, 7, 8, 9, 13, 17, 19, 21, 23 }, got[0..kept.len]);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 1 }, depths[0..kept.len]);
}

test "prune honors the depth and node limits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vp: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var els: [40]Element = undefined;
    for (&els, 0..) |*e, i| e.* = .{ .key = i, .depth = @intCast(i), .role = .button, .name = try std.fmt.allocPrint(a, "b{d}", .{i}), .actions = .{ .invoke = true }, .rect = vp };
    try testing.expectEqual(@as(usize, 26), (try prune(a, &els, vp, .{})).len);
    try testing.expectEqual(@as(usize, 5), (try prune(a, &els, vp, .{ .nodes = 5 })).len);
}

test "ids are base 36, stable per key and never reused" {
    var ids: Ids = .{};
    defer ids.deinit(testing.allocator);
    for (0..40) |k| _ = try ids.assign(testing.allocator, k, 1);
    try testing.expectEqual(@as(u32, 36), try ids.assign(testing.allocator, 35, 2));
    try testing.expectEqual(@as(?u32, 36), parseId("e10"));
    try testing.expectEqual(@as(?u32, 56), parseId("e1k"));
    try testing.expectEqual(@as(?u32, null), parseId("x12"));
    try testing.expectEqual(@as(?u32, null), parseId("e"));
    try testing.expectEqual(@as(u64, 2), ids.owner(36).?.window);
}

test "fold ignores case and Latin accents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("parametres eleve", try fold(arena.allocator(), "PARAMÈTRES Élevé"));
    try testing.expectEqualStrings("coeur ca", try fold(arena.allocator(), "cOEur ÇA"));
}

test "diff reports additions, removals and changes beyond 4 px" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const base: Shown = .{ .id = 1, .role = .button, .states = .{}, .name_hash = 1, .value_hash = 0, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 } };
    var moved_a = base;
    moved_a.id = 2;
    var moved_b = moved_a;
    moved_b.rect.x = 4; // within threshold
    var renamed = base;
    renamed.id = 3;
    var renamed_b = renamed;
    renamed_b.name_hash = 9;
    var gone = base;
    gone.id = 4;
    var added = base;
    added.id = 5;
    const d = try diff(arena.allocator(), &.{ base, moved_a, renamed, gone }, &.{ base, moved_b, renamed_b, added });
    try testing.expectEqual(@as(usize, 2), d.entries.len);
    try testing.expectEqual(Change.changed, d.entries[0].kind);
    try testing.expectEqual(@as(u32, 2), d.entries[0].index);
    try testing.expectEqual(Change.added, d.entries[1].kind);
    try testing.expectEqual(@as(usize, 1), d.removed.len);
    try testing.expectEqual(@as(u32, 4), d.removed[0].id);
}
