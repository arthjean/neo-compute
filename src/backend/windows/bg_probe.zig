//! `neo-compute bg-probe [dump] [TARGET...]` (US-040): measures which
//! primitives of the background mode take the foreground, the keyboard focus
//! or the cursor away from the user. A decoy window of another process holds
//! the foreground; each primitive then runs five times on a target that is
//! not active and lies under the decoy: the selftest window, then the six
//! reference applications the probe opens itself. A window that was already
//! open is never touched, and an application that cannot be opened is
//! reported as skipped.
//!
//! Targets: `window` (the selftest window), `notepad`, `calculator`,
//! `settings`, `explorer`, `chrome`, `vscode`, `show` (ShowWindow on the
//! selftest window) and `launch` (Calculator and a text document); none
//! means all. `dump` lists a target's actionable elements instead of
//! measuring, to write its steps.
//!
//! Lines go to stderr. A live element's name or value is never printed for
//! an application marked `private` (Notepad restores the user's own tabs):
//! only the step's own description is.

const std = @import("std");
const w = @import("win32");
const Windows = @import("../windows.zig").Windows;
const uitree = @import("../../core/uitree.zig");
const display = @import("../../core/display.zig");
const apps = @import("../../core/apps.zig");
const window = @import("window.zig");
const fixture = @import("bg_fixture.zig");
const test_window = @import("test_window.zig");
const bench = @import("bench.zig");
const TestWindow = test_window.TestWindow;
const Decoy = fixture.Decoy;
const State = fixture.State;

const reps = 5;
/// How long the foreground is watched after a pattern call.
const watch_ms = 700;
/// How long it is watched after a launched window shows up (US-043).
const launch_watch_ms = 2000;

/// How a step finds its element in the target's tree.
pub const Pick = struct {
    role: ?uitree.Role = null,
    /// The name contains one of these, ASCII case ignored; empty: any name.
    names: []const []const u8 = &.{},
    /// Only an element that is off screen (ScrollIntoView).
    offscreen: bool = false,
    /// Skip this many matches.
    nth: usize = 0,
};

/// Ground truth of a step on the selftest window, read from Win32; `uia`
/// reads the element's state back from a new snapshot.
const Truth = enum { uia, command, checkbox, field, combo_open, combo_closed, list_selection, list_top, menu_open, menu_closed };

pub const Undo = struct { action: uitree.Action, pick: Pick, value: ?[]const u8 = null };

pub const Step = struct {
    label: []const u8,
    action: uitree.Action,
    pick: Pick,
    value: ?[]const u8 = null,
    truth: Truth = .uia,
    /// Run unmeasured after each repetition, to put the state back.
    undo: ?Undo = null,
};

/// A16: a menu opened by Expand on a window that is not active.
const Menu = struct {
    expand: Pick,
    /// An item of the open menu, looked for in the snapshot 2 s later.
    item: Pick,
};

pub const App = struct {
    name: []const u8,
    argv: []const []const u8,
    exe: ?[]const u8 = null,
    titles: []const []const u8 = &.{},
    title_contains: bool = false,
    /// Element names may hold the user's own text.
    private: bool = false,
    /// A Chromium window builds its web tree after the first request.
    chromium: bool = false,
    steps: []const Step,
    /// Run once after the series, unmeasured.
    restore: []const Undo = &.{},
    menu: ?Menu = null,
};

const labels = struct {
    const focus = "SetFocus";
    const invoke = "Invoke";
    const toggle = "Toggle";
    const set_value = "ValuePattern.SetValue";
    const expand = "Expand";
    const collapse = "Collapse";
    const select = "SelectionItem.Select";
    const scroll = "ScrollItem.ScrollIntoView";
};

pub const window_steps = [_]Step{
    .{ .label = labels.focus, .action = .focus, .pick = .{ .role = .button, .names = &.{test_window.button_label} } },
    .{ .label = labels.invoke, .action = .invoke, .pick = .{ .role = .button, .names = &.{test_window.button_label} }, .truth = .command },
    .{ .label = labels.toggle, .action = .toggle, .pick = .{ .role = .checkbox, .names = &.{test_window.checkbox_label} }, .truth = .checkbox },
    .{ .label = labels.set_value, .action = .set_value, .pick = .{ .role = .edit, .nth = 1 }, .value = "neo-compute probe", .truth = .field, .undo = .{ .action = .set_value, .pick = .{ .role = .edit, .nth = 1 }, .value = test_window.field_text } },
    .{ .label = labels.expand, .action = .expand, .pick = .{ .role = .combobox }, .truth = .combo_open },
    // No Collapse: a Win32 drop-down closes by itself as soon as the decoy
    // takes the foreground back, before the measure starts.
    .{ .label = labels.select, .action = .select, .pick = .{ .role = .listitem, .names = &.{test_window.list_prefix ++ "03"} }, .truth = .list_selection, .undo = .{ .action = .select, .pick = .{ .role = .listitem, .names = &.{test_window.list_prefix ++ "01"} } } },
    .{ .label = labels.scroll, .action = .scroll_into_view, .pick = .{ .role = .listitem, .names = &.{test_window.list_prefix ++ "25"} }, .truth = .list_top, .undo = .{ .action = .scroll_into_view, .pick = .{ .role = .listitem, .names = &.{test_window.list_prefix ++ "01"} } } },
};

const window_menu: Menu = .{ .expand = .{ .role = .menuitem, .names = &.{test_window.bar_label} }, .item = .{ .role = .menuitem, .names = &.{test_window.bar_item} } };

pub const reference_apps = [_]App{
    // Notepad restores the user's unsaved tabs: no step writes a value or
    // closes a tab, and no live name is printed.
    .{
        .name = "notepad",
        .argv = &.{"notepad.exe"},
        .exe = "Notepad.exe",
        .private = true,
        .steps = &.{
            .{ .label = labels.focus, .action = .focus, .pick = .{ .role = .menuitem, .names = &.{ "Fichier", "File" } } },
            // Invoke on a menu bar item opens its menu; closed again after.
            .{ .label = labels.invoke, .action = .invoke, .pick = .{ .role = .menuitem, .names = &.{ "Affichage", "View" } }, .undo = .{ .action = .collapse, .pick = .{ .role = .menuitem, .names = &.{ "Affichage", "View" } } } },
            .{ .label = labels.expand, .action = .expand, .pick = .{ .role = .menuitem, .names = &.{ "Fichier", "File" } } },
            .{ .label = labels.collapse, .action = .collapse, .pick = .{ .role = .menuitem, .names = &.{ "Fichier", "File" } } },
            .{ .label = labels.select, .action = .select, .pick = .{ .role = .tabitem } },
            .{ .label = labels.scroll, .action = .scroll_into_view, .pick = .{ .role = .tabitem } },
        },
        .menu = .{ .expand = .{ .role = .menuitem, .names = &.{ "Fichier", "File" } }, .item = .{ .role = .menuitem, .names = &.{ "Nouvel onglet", "New tab" } } },
    },
    .{
        .name = "calculator",
        .argv = &.{"calc.exe"},
        .titles = &.{ "Calculatrice", "Calculator" },
        .steps = &.{
            .{ .label = labels.focus, .action = .focus, .pick = .{ .role = .button, .names = &.{ "Un", "One" } } },
            .{ .label = labels.invoke, .action = .invoke, .pick = .{ .role = .button, .names = &.{ "Un", "One" } } },
            // No toggle and no expandable element of its own: the title bar's
            // system menu is a Win32 menu, never opened here.
            .{ .label = labels.select, .action = .select, .pick = .{ .role = .tabitem, .names = &.{ "Mémoire", "Memory" } } },
            .{ .label = labels.scroll, .action = .scroll_into_view, .pick = .{ .role = .button, .names = &.{ "Zéro", "Zero" } } },
        },
    },
    .{
        .name = "settings",
        .argv = &.{ "explorer.exe", "ms-settings:" },
        .titles = &.{ "Paramètres", "Settings" },
        .steps = &.{
            .{ .label = labels.focus, .action = .focus, .pick = .{ .role = .listitem, .names = &.{ "Système", "System" } } },
            // Navigation only: no step touches a control that changes a
            // setting (the Bluetooth switch, a theme).
            .{ .label = labels.invoke, .action = .invoke, .pick = .{ .role = .listitem, .names = &.{ "Stockage", "Storage" } }, .undo = .{ .action = .select, .pick = .{ .role = .listitem, .names = &.{ "Accueil", "Home" } } } },
            .{ .label = labels.set_value, .action = .set_value, .pick = .{ .role = .edit }, .value = "neo-compute", .undo = .{ .action = .set_value, .pick = .{ .role = .edit }, .value = "" } },
            .{ .label = labels.select, .action = .select, .pick = .{ .role = .listitem, .names = &.{ "Personnalisation", "Personalization" } }, .undo = .{ .action = .select, .pick = .{ .role = .listitem, .names = &.{ "Accueil", "Home" } } } },
            .{ .label = labels.scroll, .action = .scroll_into_view, .pick = .{ .role = .listitem, .names = &.{"Windows Update"} } },
        },
        .restore = &.{.{ .action = .set_value, .pick = .{ .role = .edit }, .value = "" }},
    },
    .{
        .name = "explorer",
        .argv = &.{ "explorer.exe", "{root}\\bench" },
        .exe = "explorer.exe",
        .titles = &.{"bench"},
        .title_contains = true,
        .steps = &.{
            .{ .label = labels.focus, .action = .focus, .pick = .{ .role = .listitem, .names = &.{"baseline"} } },
            .{ .label = labels.invoke, .action = .invoke, .pick = .{ .role = .button, .names = &.{ "Actualiser", "Refresh" } } },
            .{ .label = labels.select, .action = .select, .pick = .{ .role = .listitem, .names = &.{"baseline"} }, .undo = .{ .action = .select, .pick = .{ .role = .listitem, .names = &.{"apps"} } } },
            .{ .label = labels.scroll, .action = .scroll_into_view, .pick = .{ .role = .listitem, .names = &.{"token_calibration"} } },
            .{ .label = labels.expand, .action = .expand, .pick = .{ .role = .treeitem, .names = &.{"(C:)"} } },
            .{ .label = labels.collapse, .action = .collapse, .pick = .{ .role = .treeitem, .names = &.{"(C:)"} } },
        },
    },
    .{
        .name = "chrome",
        .argv = &.{ "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check", "--new-window", "{page_url}" },
        .exe = "chrome.exe",
        .titles = &.{"neo-compute reference page"},
        .title_contains = true,
        .chromium = true,
        .steps = &.{
            .{ .label = labels.focus, .action = .focus, .pick = .{ .role = .edit, .names = &.{"Nom"} } },
            .{ .label = labels.invoke, .action = .invoke, .pick = .{ .role = .link, .names = &.{"Section 2"} } },
            .{ .label = labels.toggle, .action = .toggle, .pick = .{ .role = .checkbox, .names = &.{"Recevoir"} } },
            .{ .label = labels.set_value, .action = .set_value, .pick = .{ .role = .edit, .names = &.{"Nom"} }, .value = "neo-compute probe" },
            .{ .label = labels.expand, .action = .expand, .pick = .{ .role = .combobox, .names = &.{"Pays"} } },
            .{ .label = labels.collapse, .action = .collapse, .pick = .{ .role = .combobox, .names = &.{"Pays"} } },
            .{ .label = labels.scroll, .action = .scroll_into_view, .pick = .{ .role = .link, .names = &.{"Article 40"} } },
        },
    },
    .{
        .name = "vscode",
        .argv = &.{ "cmd.exe", "/c", "code", "--new-window", "{page}" },
        .exe = "Code.exe",
        .titles = &.{"reference.html"},
        .title_contains = true,
        .chromium = true,
        .steps = &.{
            .{ .label = labels.focus, .action = .focus, .pick = .{ .role = .menuitem, .names = &.{ "Fichier", "File" } } },
            .{ .label = labels.expand, .action = .expand, .pick = .{ .role = .menuitem, .names = &.{ "Fichier", "File" } } },
            .{ .label = labels.collapse, .action = .collapse, .pick = .{ .role = .menuitem, .names = &.{ "Fichier", "File" } } },
            .{ .label = labels.select, .action = .select, .pick = .{ .role = .tabitem, .names = &.{ "Rechercher", "Search" } }, .undo = .{ .action = .select, .pick = .{ .role = .tabitem, .names = &.{ "Explorateur", "Explorer" } } } },
            // Invoke shows and hides the chat panel: run again to undo.
            .{ .label = labels.invoke, .action = .invoke, .pick = .{ .role = .button, .names = &.{"Toggle Chat"} }, .undo = .{ .action = .invoke, .pick = .{ .role = .button, .names = &.{"Toggle Chat"} } } },
            .{ .label = labels.toggle, .action = .toggle, .pick = .{ .role = .button, .names = &.{ "Toggle Panel", "Activer/désactiver le panneau" } }, .undo = .{ .action = .toggle, .pick = .{ .role = .button, .names = &.{ "Toggle Panel", "Activer/désactiver le panneau" } } } },
        },
    },
};

const Stat = struct {
    target: []const u8,
    label: []const u8,
    runs: u32 = 0,
    /// The effect was read on the target.
    effect: u32 = 0,
    /// The effect cannot be read back (an Invoke that changes nothing visible).
    unverifiable: u32 = 0,
    foreground: u32 = 0,
    focus: u32 = 0,
    cursor: u32 = 0,
    covered: u32 = 0,
    /// The primitive has no element to run on in this target.
    missing: bool = false,
};

pub fn qpcMs() u64 {
    var t: i64 = 0;
    var f: i64 = 1;
    _ = w.QueryPerformanceCounter(&t);
    _ = w.QueryPerformanceFrequency(&f);
    return @intCast(@divTrunc(t * 1000, f));
}

/// One primitive under watch: the session before it, and the first moment
/// the foreground left the decoy.
const Measure = struct {
    before: State,
    covered: bool,
    t0: u64,
    changed_ms: ?u64 = null,
    changed_to: usize = 0,

    fn poll(self: *Measure) void {
        if (self.changed_ms != null) return;
        const fg = @intFromPtr(w.GetForegroundWindow());
        if (fg == self.before.foreground) return;
        self.changed_ms = qpcMs() - self.t0;
        self.changed_to = fg;
    }

    /// Watches the foreground until `ms` after the primitive started.
    fn watchUntil(self: *Measure, ms: u64) void {
        while (qpcMs() - self.t0 < ms) {
            self.poll();
            w.Sleep(10);
        }
        self.poll();
    }
};

pub const Probe = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    log: *std.Io.Writer,
    backend: *Windows,
    decoy: Decoy,
    scratch: std.heap.ArenaAllocator,
    stats: std.ArrayList(Stat) = .empty,
    /// The decoy could not be put back in front: the run stops.
    lost: bool = false,
    /// A control found this process free to take the foreground.
    lock_open: bool = false,
    /// `only=<label>`: the one primitive to run, to rule out an effect of
    /// the primitive before it.
    only: ?[]const u8 = null,
    /// Why the last snapshot failed.
    snapshot_error: []const u8 = "",
    /// Start of every line (the events probe of US-047 shares this type).
    prefix: []const u8 = "bg-probe",

    pub fn print(p: *Probe, comptime f: []const u8, args: anytype) void {
        p.log.print("{s}: " ++ f ++ "\n", .{p.prefix} ++ args) catch {};
        p.log.flush() catch {};
    }

    fn stat(p: *Probe, target: []const u8, label: []const u8) *Stat {
        for (p.stats.items) |*s| if (std.mem.eql(u8, s.target, target) and std.mem.eql(u8, s.label, label)) return s;
        p.stats.append(p.gpa, .{ .target = target, .label = label }) catch @panic("out of memory");
        return &p.stats.items[p.stats.items.len - 1];
    }

    /// The decoy in front, then the session's state. Null when the decoy
    /// cannot take the foreground back.
    fn begin(p: *Probe, target: ?w.HWND) ?Measure {
        if (!p.decoy.front()) {
            p.lost = true;
            p.print("the decoy cannot take the foreground back: run stopped", .{});
            return null;
        }
        w.Sleep(120);
        // A target that an earlier primitive raised goes back under the decoy.
        if (target) |t| if (w.IsIconic(t) == 0 and !fixture.above(p.decoy.hwnd, t)) {
            p.decoy.tuck(t);
            w.Sleep(60);
        };
        return .{ .before = State.sample(null), .covered = if (target) |t| p.decoy.covers(t) else true, .t0 = qpcMs() };
    }

    /// Logs one repetition and counts it. `effect`: null when it cannot be
    /// read back.
    fn end(p: *Probe, m: *Measure, target: []const u8, label: []const u8, rep: usize, effect: ?bool, detail: []const u8, until_ms: u64) void {
        m.watchUntil(until_ms);
        const after = State.sample(null);
        const s = p.stat(target, label);
        s.runs += 1;
        if (effect) |e| s.effect += @intFromBool(e) else s.unverifiable += 1;
        const fg_changed = m.changed_ms != null;
        const focus_changed = after.focus != m.before.focus or fg_changed;
        const cursor_moved = after.cursor[0] != m.before.cursor[0] or after.cursor[1] != m.before.cursor[1];
        s.foreground += @intFromBool(fg_changed);
        s.focus += @intFromBool(focus_changed);
        s.cursor += @intFromBool(cursor_moved);
        s.covered += @intFromBool(m.covered);
        var who_buf: [160]u8 = undefined;
        var who: []const u8 = "unchanged";
        if (fg_changed) {
            var pid: u32 = 0;
            _ = w.GetWindowThreadProcessId(@ptrFromInt(m.changed_to), &pid);
            const exe = (window.processName(p.scratch.allocator(), pid) catch null) orelse "?";
            who = std.fmt.bufPrint(&who_buf, "CHANGED after {d} ms to 0x{x} ({s})", .{ m.changed_ms.?, m.changed_to, exe }) catch "CHANGED";
        }
        p.print("{s} | {s} #{d} | effect: {s}{s}{s} | foreground 0x{x} -> 0x{x} {s} | focus 0x{x} -> 0x{x} | cursor {d},{d} -> {d},{d} | covered: {s}", .{
            target,                                                       label,                            rep + 1,
            if (effect) |e| (if (e) "yes" else "NO") else "not readable", if (detail.len > 0) ", " else "", detail,
            m.before.foreground,                                          after.foreground,                 who,
            m.before.focus,                                               after.focus,                      m.before.cursor[0],
            m.before.cursor[1],                                           after.cursor[0],                  after.cursor[1],
            if (m.covered) "yes" else "no",
        });
    }

    pub fn snapshot(p: *Probe, hwnd: u64) ?[]const uitree.Element {
        const a = p.scratch.allocator();
        return switch (p.backend.uiSnapshot(a, hwnd, .{ .extra_roots = p.backend.uiRoots(a, hwnd) })) {
            .ok => |s| s.elements,
            .err => |e| blk: {
                p.snapshot_error = e;
                break :blk null;
            },
        };
    }
};

fn supports(e: uitree.Element, action: uitree.Action) bool {
    return switch (action) {
        .invoke => e.actions.invoke,
        .toggle => e.actions.toggle,
        .select => e.actions.select,
        .expand, .collapse => e.actions.expand_collapse,
        .set_value => e.actions.value and !e.password,
        .focus => true,
        .scroll_into_view => e.actions.scroll,
        // The probes measure one pattern each: the composed actions of
        // EP-013 are proven by the selftest.
        .check, .uncheck, .scroll => false,
    };
}

/// The one pattern call the probes measure for `action`, without the waits
/// and the read-back `ui_act` adds around it.
pub fn patternCall(backend: *Windows, arena: std.mem.Allocator, hwnd: u64, key: u64, action: uitree.Action, value: ?[]const u8) uitree.OpResult {
    const op: uitree.Op = switch (action) {
        .invoke => .invoke,
        .toggle => .toggle,
        .select => .select,
        .expand => .expand,
        .collapse => .collapse,
        .focus => .focus,
        .scroll_into_view => .scroll_item,
        .set_value => .{ .set_value = value orelse "" },
        .check, .uncheck, .scroll => return .unsupported,
    };
    return backend.uiOp(arena, hwnd, key, op);
}

pub fn find(els: []const uitree.Element, pick: Pick, action: uitree.Action) ?uitree.Element {
    var skipped: usize = 0;
    for (els) |e| {
        if (!supports(e, action) or e.states.disabled) continue;
        if (pick.role) |r| if (e.role != r) continue;
        if (pick.offscreen and !e.states.offscreen) continue;
        if (action != .scroll_into_view and e.states.offscreen) continue;
        if (pick.names.len > 0) {
            const named = for (pick.names) |n| {
                if (std.ascii.findIgnoreCase(e.name, n) != null) break true;
            } else false;
            if (!named) continue;
        }
        if (skipped < pick.nth) {
            skipped += 1;
            continue;
        }
        return e;
    }
    return null;
}

fn byKey(els: []const uitree.Element, key: u64) ?uitree.Element {
    for (els) |e| if (e.key == key) return e;
    return null;
}

pub fn treeHash(els: []const uitree.Element) u64 {
    var h: std.hash.Wyhash = .init(0);
    for (els) |e| {
        h.update(std.mem.asBytes(&e.key));
        h.update(std.mem.asBytes(&e.states));
        h.update(e.name);
        if (e.value) |v| h.update(v);
    }
    return h.final();
}

/// A visible Win32 menu window (`#32768`) of thread `thread`.
fn menuWindow(thread: u32) bool {
    const Find = struct {
        thread: u32,
        found: bool = false,
        fn callback(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
            const self: *@This() = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (w.IsWindowVisible(hwnd) == 0 or w.GetWindowThreadProcessId(hwnd, null) != self.thread) return 1;
            var class: [16:0]u16 = undefined;
            const n = w.GetClassNameW(hwnd, &class, class.len);
            if (n > 0 and std.mem.eql(u16, class[0..@intCast(n)], std.unicode.utf8ToUtf16LeStringLiteral("#32768"))) {
                self.found = true;
                return 0;
            }
            return 1;
        }
    };
    var f: Find = .{ .thread = thread };
    _ = w.EnumWindows(Find.callback, @bitCast(@intFromPtr(&f)));
    return f.found;
}

/// The step's effect: from Win32 on the selftest window, else from the
/// element's state in a new snapshot. Null: not readable.
fn effectOf(p: *Probe, hwnd: u64, step: Step, before: uitree.Element, hash_before: u64, base: anytype, tw: ?*TestWindow) ?bool {
    if (tw) |t| switch (step.truth) {
        .uia => {},
        .command => return t.commandCount() > base.commands,
        .checkbox => return t.checked() != base.checked,
        .field => {
            var buf: [64:0]u16 = undefined;
            var want: [64]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(&want, step.value orelse "") catch 0;
            return std.mem.eql(u16, t.fieldText(&buf), want[0..n]);
        },
        .combo_open => return t.comboDropped(),
        .combo_closed => return !t.comboDropped(),
        .list_selection => return t.listSelection() == 2,
        .list_top => return t.listTop() > 10,
        .menu_open => return menuWindow(t.thread_id.load(.acquire)),
        .menu_closed => return !menuWindow(t.thread_id.load(.acquire)),
    };
    const after = p.snapshot(hwnd) orelse return null;
    const e = byKey(after, before.key);
    return switch (step.action) {
        .focus => if (e) |x| x.states.focused else null,
        .toggle => if (e) |x| x.states.checked != before.states.checked or x.states.mixed != before.states.mixed else null,
        .set_value => if (e) |x| (if (x.value) |v| std.mem.eql(u8, v, step.value orelse "") else null) else null,
        .expand => if (e) |x| x.states.expanded else null,
        .collapse => if (e) |x| !x.states.expanded else null,
        .select => if (e) |x| x.states.selected else null,
        .scroll_into_view => if (e) |x| !x.states.offscreen else null,
        // An Invoke shows only through what it changes around it.
        .invoke => if (treeHash(after) != hash_before) true else null,
        .check, .uncheck, .scroll => null,
    };
}

fn actText(r: uitree.OpResult) []const u8 {
    return switch (r) {
        .ok => "",
        .timeout => "UIA timeout",
        .gone => "element gone",
        .read_only => "read-only",
        .unsupported => "pattern missing",
        .failed => "UIA call failed",
    };
}

pub fn undo(p: *Probe, hwnd: u64, u: Undo) void {
    const els = p.snapshot(hwnd) orelse return;
    const e = find(els, u.pick, u.action) orelse return;
    _ = patternCall(p.backend, p.scratch.allocator(), hwnd, e.key, u.action, u.value);
    w.Sleep(200);
}

fn runStep(p: *Probe, target: []const u8, hwnd: u64, step: Step, rep: usize, tw: ?*TestWindow) void {
    if (p.only) |o| if (!std.mem.eql(u8, o, step.label)) return;
    _ = p.scratch.reset(.retain_capacity);
    const els = p.snapshot(hwnd) orelse {
        p.print("{s} | {s} #{d} | no snapshot of the target: {s}", .{ target, step.label, rep + 1, p.snapshot_error });
        // What the step before left open (a drop-down, a menu) closes when
        // the decoy takes the foreground back.
        _ = p.decoy.front();
        w.Sleep(200);
        return;
    };
    const el = find(els, step.pick, step.action) orelse {
        const s = p.stat(target, step.label);
        if (!s.missing and s.runs == 0) p.print("{s} | {s} | no element for this pattern in the target (role {s}, {d} name(s) tried)", .{ target, step.label, if (step.pick.role) |r| @tagName(r) else "any", step.pick.names.len });
        s.missing = s.runs == 0;
        return;
    };
    const hash = treeHash(els);
    const base = .{ .commands = if (tw) |t| t.commandCount() else 0, .checked = if (tw) |t| t.checked() else false };
    // Select moves a selection that may be the user's (a Notepad tab): the
    // element selected before is selected again after the measure.
    var selected_before: ?u64 = null;
    if (step.action == .select and step.undo == null) for (els) |e| {
        if (e.role == el.role and e.states.selected and e.key != el.key) selected_before = e.key;
    };
    var m = p.begin(@as(w.HWND, @ptrFromInt(hwnd))) orelse return;
    const r = patternCall(p.backend, p.scratch.allocator(), hwnd, el.key, step.action, step.value);
    // The effect may land after the call returns: read it for up to 500 ms.
    var effect: ?bool = null;
    while (true) {
        m.poll();
        effect = effectOf(p, hwnd, step, el, hash, base, tw);
        if ((effect orelse false) or qpcMs() - m.t0 >= 500) break;
        w.Sleep(50);
    }
    p.end(&m, target, step.label, rep, if (r == .ok or r == .timeout) effect else false, if (r == .failed) r.failed else actText(r), watch_ms);
    if (step.undo) |u| undo(p, hwnd, u);
    // A Win32 drop-down left open makes the next tree read fail (E_FAIL)
    // and swallows the window's system commands.
    if (tw) |t| if (step.truth == .combo_open) {
        t.closeCombo();
        w.Sleep(150);
    };
    if (selected_before) |key| {
        _ = patternCall(p.backend, p.scratch.allocator(), hwnd, key, .select, null);
        w.Sleep(200);
    }
}

/// A16: the menu opened by Expand stays open 2 s and reads as part of the
/// target's snapshot.
fn menuCheck(p: *Probe, target: []const u8, hwnd: u64, menu: Menu, tw: ?*TestWindow) void {
    _ = p.scratch.reset(.retain_capacity);
    const els = p.snapshot(hwnd) orelse return;
    const el = find(els, menu.expand, .expand) orelse {
        p.print("{s} | A16 menu | no expandable menu item in the target", .{target});
        return;
    };
    var m = p.begin(@as(w.HWND, @ptrFromInt(hwnd))) orelse return;
    const r = patternCall(p.backend, p.scratch.allocator(), hwnd, el.key, .expand, null);
    m.watchUntil(2000);
    const after = p.snapshot(hwnd);
    const open_state = if (after) |a| (if (byKey(a, el.key)) |x| x.states.expanded else false) else false;
    const in_snapshot = if (after) |a| find(a, menu.item, .focus) != null else false;
    const win32_menu = if (tw) |t| menuWindow(t.thread_id.load(.acquire)) else false;
    const still_open = open_state or in_snapshot or win32_menu;
    var detail_buf: [200]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "{s}open after 2 s: {s} (expanded state {}, Win32 menu window {}), item in the snapshot: {}", .{ if (actText(r).len > 0) actText(r) else "", if (still_open) "yes" else "no", open_state, win32_menu, in_snapshot }) catch "";
    p.end(&m, target, "A16 menu by Expand", 0, still_open and in_snapshot, detail, 2000);
    // Closed again, unmeasured.
    if (p.snapshot(hwnd)) |a| if (find(a, menu.expand, .collapse)) |x| {
        _ = patternCall(p.backend, p.scratch.allocator(), hwnd, x.key, .collapse, null);
    };
    w.Sleep(300);
    // A Win32 menu loop that is still running ends on WM_CANCELMODE.
    if (tw) |t| if (menuWindow(t.thread_id.load(.acquire))) {
        _ = w.PostMessageW(t.window(), w.WM_CANCELMODE, 0, 0);
        w.Sleep(200);
    };
}

fn waitShow(hwnd: w.HWND, comptime want: enum { iconic, zoomed, normal }) bool {
    var waited: u32 = 0;
    while (waited < 800) : (waited += 10) {
        const iconic = w.IsIconic(hwnd) != 0;
        const zoomed = w.IsZoomed(hwnd) != 0;
        if (switch (want) {
            .iconic => iconic,
            .zoomed => zoomed,
            .normal => !iconic and !zoomed,
        }) return true;
        w.Sleep(10);
    }
    return false;
}

/// ShowWindow on a window that is not active: minimized and restored
/// without activation, maximized, and the same through a posted
/// SC_MAXIMIZE (a candidate route without activation, US-043).
/// Control of the harness: a plain SetForegroundWindow from this process on
/// the covered target. While a user works in another application Windows
/// refuses it (foreground lock). If it succeeds here, this process holds a
/// foreground right the server never has in real use, and a foreground
/// change measured on a pattern proves nothing about the pattern.
fn lockControl(p: *Probe, target: []const u8, hwnd: w.HWND) void {
    var m = p.begin(hwnd) orelse return;
    const accepted = w.SetForegroundWindow(hwnd) != 0;
    m.watchUntil(300);
    const took = m.changed_ms != null;
    p.print("{s} | control: SetForegroundWindow from this process returned {}, foreground {s}: {s}", .{
        target,                                                                                                                            accepted, if (took) "CHANGED" else "unchanged",
        if (took) "this process may take the foreground, the lock does not hold for it" else "the foreground lock holds for this process",
    });
    p.lock_open = p.lock_open or took;
}

/// One ShowWindow-like primitive, measured.
fn showStep(p: *Probe, target: []const u8, hwnd: w.HWND, label: []const u8, rep: usize, comptime want: @TypeOf(.e), do: *const fn (w.HWND) void) bool {
    if (p.lost or w.IsWindow(hwnd) == 0) return false;
    var m = p.begin(hwnd) orelse return false;
    // What a restore does depends on whether the window is still the
    // active one of its own thread: logged with each measure.
    var info = std.mem.zeroes(w.GUITHREADINFO);
    info.cbSize = @sizeOf(w.GUITHREADINFO);
    const queue_active = w.GetGUIThreadInfo(w.GetWindowThreadProcessId(hwnd, null), &info) != 0 and info.hwndActive == hwnd;
    do(hwnd);
    p.end(&m, target, label, rep, waitShow(hwnd, want), if (queue_active) "active in its thread before" else "not active in its thread before", watch_ms);
    return true;
}

const show = struct {
    fn minNoActive(hwnd: w.HWND) void {
        _ = w.ShowWindow(hwnd, w.SW_SHOWMINNOACTIVE);
    }
    fn noActivate(hwnd: w.HWND) void {
        _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
    }
    fn maximized(hwnd: w.HWND) void {
        _ = w.ShowWindow(hwnd, w.SW_SHOWMAXIMIZED);
    }
    fn postMaximize(hwnd: w.HWND) void {
        _ = w.PostMessageW(hwnd, w.WM_SYSCOMMAND, w.SC_MAXIMIZE, 0);
    }
    fn postRestore(hwnd: w.HWND) void {
        _ = w.PostMessageW(hwnd, w.WM_SYSCOMMAND, w.SC_RESTORE, 0);
    }
    /// Hiding the active window of a thread ends that state; the window
    /// then comes back restored, without activation.
    fn hideThenShow(hwnd: w.HWND) void {
        _ = w.ShowWindow(hwnd, w.SW_HIDE);
        _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
    }
};

/// Each series leaves the window as it found it, normal and under the
/// decoy, and runs alone: what a restore does depends on what the window
/// went through before (the first run measured SW_SHOWNOACTIVATE from
/// minimized without a foreground change once, then with one four times).
fn showMeasures(p: *Probe, target: []const u8, hwnd: w.HWND) void {
    const hide_label = "ShowWindow SW_HIDE then SW_SHOWNOACTIVATE (from minimized)";
    // `only=` naming the last series runs it alone; any other `only=`
    // names a pattern, and no series runs.
    const all = p.only == null;
    if (!all and !std.mem.eql(u8, p.only.?, hide_label)) return;
    // A window that was never maximized.
    if (all) for (0..reps) |rep| {
        if (!showStep(p, target, hwnd, "ShowWindow SW_SHOWMINNOACTIVE", rep, .iconic, show.minNoActive)) return;
        if (!showStep(p, target, hwnd, "ShowWindow SW_SHOWNOACTIVATE (from minimized)", rep, .normal, show.noActivate)) return;
    };
    if (all) for (0..reps) |rep| {
        _ = w.ShowWindow(hwnd, w.SW_SHOWMINNOACTIVE);
        _ = waitShow(hwnd, .iconic);
        if (!showStep(p, target, hwnd, "WM_SYSCOMMAND SC_RESTORE (posted, from minimized)", rep, .normal, show.postRestore)) return;
    };
    if (all) for (0..reps) |rep| {
        if (!showStep(p, target, hwnd, "ShowWindow SW_SHOWMAXIMIZED", rep, .zoomed, show.maximized)) return;
        if (!showStep(p, target, hwnd, "ShowWindow SW_SHOWNOACTIVATE (from maximized)", rep, .normal, show.noActivate)) return;
    };
    if (all) for (0..reps) |rep| {
        if (!showStep(p, target, hwnd, "WM_SYSCOMMAND SC_MAXIMIZE (posted)", rep, .zoomed, show.postMaximize)) return;
        if (!showStep(p, target, hwnd, "WM_SYSCOMMAND SC_RESTORE (posted, from maximized)", rep, .normal, show.postRestore)) return;
    };
    // The same restore once the window has been maximized.
    if (all) for (0..reps) |rep| {
        _ = w.ShowWindow(hwnd, w.SW_SHOWMINNOACTIVE);
        _ = waitShow(hwnd, .iconic);
        if (!showStep(p, target, hwnd, "ShowWindow SW_SHOWNOACTIVATE (from minimized, after a maximize)", rep, .normal, show.noActivate)) return;
    };
    // A system command handled by the window (maximize, restore) leaves it
    // active in its own thread, and the restore of such a window from
    // minimized takes the foreground (SW_MINIMIZE on the minimized window
    // does not end that state: measured, 3 changes on 3 active windows).
    // Hiding it first is measured as the way to end it.
    for (0..reps) |rep| {
        show.postMaximize(hwnd);
        _ = waitShow(hwnd, .zoomed);
        show.postRestore(hwnd);
        _ = waitShow(hwnd, .normal);
        _ = w.ShowWindow(hwnd, w.SW_SHOWMINNOACTIVE);
        _ = waitShow(hwnd, .iconic);
        if (!showStep(p, target, hwnd, hide_label, rep, .normal, show.hideThenShow)) return;
    }
}

fn handlesOf(p: *Probe, a: std.mem.Allocator) []const u64 {
    const wins = p.backend.listWindows(a, true) catch return &.{};
    const out = a.alloc(u64, wins.len) catch return &.{};
    for (wins, out) |win, *h| h.* = win.handle;
    return out;
}

fn matches(app: App, win: display.WindowInfo) bool {
    if (app.exe) |e| if (!std.ascii.eqlIgnoreCase(e, win.exe)) return false;
    if (app.titles.len == 0) return true;
    for (app.titles) |t| {
        if (app.title_contains and std.mem.indexOf(u8, win.title, t) != null) return true;
        if (!app.title_contains and std.mem.eql(u8, win.title, t)) return true;
    }
    return false;
}

/// A window of `app` that is not in `before`, waited for up to 15 s.
fn newWindow(p: *Probe, a: std.mem.Allocator, app: App, before: []const u64) ?u64 {
    var waited: u32 = 0;
    while (waited < 15_000) : (waited += 200) {
        const wins = p.backend.listWindows(a, false) catch return null;
        for (wins) |win| if (matches(app, win) and std.mem.indexOfScalar(u64, before, win.handle) == null) return win.handle;
        w.Sleep(200);
    }
    return null;
}

pub fn closeWindow(hwnd: w.HWND) bool {
    _ = w.PostMessageW(hwnd, w.WM_CLOSE, 0, 0);
    var waited: u32 = 0;
    while (waited < 4000) : (waited += 50) {
        if (w.IsWindow(hwnd) == 0 or w.IsWindowVisible(hwnd) == 0) return true;
        w.Sleep(50);
    }
    return false;
}

/// Puts `hwnd` under the decoy without activating it.
fn tuck(p: *Probe, hwnd: w.HWND) void {
    if (w.IsZoomed(hwnd) != 0 or w.IsIconic(hwnd) != 0) _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
    const d = p.decoy.rect;
    _ = w.SetWindowPos(hwnd, null, d.x + 80, d.y + 80, @min(1200, d.w - 160), @min(800, d.h - 160), w.SWP_NOZORDER | w.SWP_NOACTIVATE);
    _ = p.decoy.front();
    p.decoy.tuck(hwnd);
    w.Sleep(400);
}

/// Opens a reference application in a window of its own, under the decoy,
/// and makes the first request to it. Null: skipped, with its reason
/// printed.
pub fn openApp(p: *Probe, a: std.mem.Allocator, app: App) ?u64 {
    const hwnd = launchApp(p, a, app) orelse return null;
    w.Sleep(2500);
    tuck(p, @ptrFromInt(hwnd));
    if (app.chromium) {
        // The first request makes Chromium build its web tree.
        var waited: u32 = 0;
        const ready = while (waited < 8000) : (waited += 500) {
            _ = p.scratch.reset(.retain_capacity);
            if (p.snapshot(hwnd)) |els| {
                const has_document = for (els) |e| {
                    if (e.role == .document) break true;
                } else false;
                if (has_document) break true;
            }
            w.Sleep(500);
        } else false;
        if (!ready) p.print("{s} | no web document in the tree after 8 s under the decoy", .{app.name});
    }
    return hwnd;
}

/// Starts a reference application and returns its new window, left where
/// it opened and never read: no UI Automation request reaches it here
/// (`occlusion-probe` measures the first one). Null: skipped, with its
/// reason printed.
pub fn launchApp(p: *Probe, a: std.mem.Allocator, app: App) ?u64 {
    const before = handlesOf(p, a);
    const listed = p.backend.listWindows(a, true) catch &.{};
    // An application that reuses its window would hand the probe a window
    // of the user's.
    for (listed) |win| if (matches(app, win) and !app.title_contains) {
        p.print("{s} | skipped: a window of this application is already open (0x{x}), and the probe never touches a window it did not open", .{ app.name, win.handle });
        return null;
    };
    const argv = bench.expandArgs(a, p.io, app.argv, "bench-firefox-profile") catch {
        p.print("{s} | skipped: bench/pages/reference.html not found, run the probe from the repository root", .{app.name});
        return null;
    };
    if (std.fs.path.isAbsolute(argv[0])) std.Io.Dir.cwd().access(p.io, argv[0], .{}) catch {
        p.print("{s} | skipped: {s} is not installed", .{ app.name, argv[0] });
        return null;
    };
    _ = std.process.spawn(p.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        p.print("{s} | skipped: {s} cannot be started ({t})", .{ app.name, app.argv[0], err });
        return null;
    };
    return newWindow(p, a, app, before) orelse {
        p.print("{s} | skipped: no new window within 15 s (application absent, or it reused a window)", .{app.name});
        return null;
    };
}

fn textRole(r: uitree.Role) bool {
    return switch (r) {
        .tabitem, .edit, .document, .text, .window, .titlebar, .pane, .group, .listitem => true,
        else => false,
    };
}

fn dump(p: *Probe, target: []const u8, hwnd: u64, private: bool) void {
    _ = p.scratch.reset(.retain_capacity);
    const els = p.snapshot(hwnd) orelse {
        p.print("{s} | no snapshot", .{target});
        return;
    };
    p.print("{s} | {d} elements, covered: {}", .{ target, els.len, p.decoy.covers(@ptrFromInt(hwnd)) });
    for (els) |e| {
        if (!e.actions.any() and e.role != .edit and e.role != .document) continue;
        const name: []const u8 = if (private and textRole(e.role)) "<hidden>" else e.name[0..@min(e.name.len, 60)];
        p.print("  d{d} {t} \"{s}\"{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}", .{
            e.depth,                                                                                  e.role,                                       name,
            if (e.actions.invoke) " invoke" else "",                                                  if (e.actions.value) " value" else "",        if (e.actions.toggle) " toggle" else "",
            if (e.actions.expand_collapse) " expand" else "",                                         if (e.actions.select) " select" else "",      if (e.actions.scroll) " scrollitem" else "",
            if (e.states.offscreen) " {offscreen}" else "",                                           if (e.states.disabled) " {disabled}" else "", if (e.states.selected) " {selected}" else "",
            if (e.states.expanded) " {expanded}" else if (e.states.collapsed) " {collapsed}" else "",
        });
    }
}

fn probeApp(p: *Probe, app: App, dump_only: bool) void {
    var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hwnd = openApp(p, a, app) orelse return;
    defer {
        if (!closeWindow(@ptrFromInt(hwnd))) p.print("{s} | window 0x{x} still open after WM_CLOSE: close it by hand", .{ app.name, hwnd });
        _ = p.decoy.front();
    }
    if (dump_only) return dump(p, app.name, hwnd, app.private);
    p.print("{s} | window 0x{x} opened by the probe, covered by the decoy: {}", .{ app.name, hwnd, p.decoy.covers(@ptrFromInt(hwnd)) });
    lockControl(p, app.name, @ptrFromInt(hwnd));
    for (0..reps) |rep| for (app.steps) |step| {
        if (p.lost or w.IsWindow(@ptrFromInt(hwnd)) == 0) return;
        runStep(p, app.name, hwnd, step, rep, null);
    };
    for (app.restore) |u| undo(p, hwnd, u);
    if (app.menu) |menu| menuCheck(p, app.name, hwnd, menu, null);
    showMeasures(p, app.name, @ptrFromInt(hwnd));
}

fn probeWindow(p: *Probe, dump_only: bool, show_only: bool) !void {
    const d = p.decoy.rect;
    var tw: TestWindow = .{ .background = true, .rect = .{ .left = d.x + 120, .top = d.y + 120, .right = d.x + 600, .bottom = d.y + 440 } };
    try tw.start();
    defer tw.stop();
    w.Sleep(300);
    _ = p.decoy.front();
    p.decoy.tuck(tw.window());
    w.Sleep(200);
    const hwnd: u64 = @intFromPtr(tw.window());
    if (dump_only) return dump(p, "window", hwnd, false);
    p.print("window | selftest window 0x{x}, covered by the decoy: {}", .{ hwnd, p.decoy.covers(tw.window()) });
    lockControl(p, "window", tw.window());
    if (!show_only) {
        for (0..reps) |rep| for (window_steps) |step| {
            if (p.lost) return;
            runStep(p, "window", hwnd, step, rep, &tw);
        };
        menuCheck(p, "window", hwnd, window_menu, &tw);
    }
    showMeasures(p, "window", tw.window());
}

const Route = struct {
    label: []const u8,
    activate: bool = false,
    show: apps.Show = .normal,
    /// Label of the restore measured on a window that started minimized.
    restore: []const u8 = "",
};

/// Waits for a top-level window that is not in `before`, visible or
/// minimized, while watching the foreground.
fn launchedWindow(p: *Probe, a: std.mem.Allocator, m: *Measure, before: []const u64, exes: []const []const u8) ?display.WindowInfo {
    var waited: u32 = 0;
    while (waited < 10_000) : (waited += 50) {
        m.poll();
        const wins = p.backend.listWindows(a, false) catch return null;
        for (wins) |win| {
            if (std.mem.indexOfScalar(u64, before, win.handle) != null) continue;
            for (exes) |e| if (std.ascii.eqlIgnoreCase(e, win.exe)) return win;
        }
        w.Sleep(50);
    }
    return null;
}

fn launchSeries(p: *Probe, target: []const u8, routes: []const Route, exes: []const []const u8, aumid: ?[]const u8, file: []const u8) void {
    var cancel: std.atomic.Value(bool) = .init(false);
    for (routes) |route| for (0..reps) |rep| {
        if (p.lost) return;
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const before = handlesOf(p, a);
        var m = p.begin(null) orelse return;
        const started = if (route.activate) p.backend.shell.activate(aumid.?, &cancel) else p.backend.shell.execute(file, route.show, &cancel);
        if (started != .ok) {
            p.end(&m, target, route.label, rep, false, "launch refused by Windows", watch_ms);
            continue;
        }
        const win = launchedWindow(p, a, &m, before, exes) orelse {
            p.end(&m, target, route.label, rep, false, "no window within 10 s", watch_ms);
            continue;
        };
        const hwnd: w.HWND = @ptrFromInt(win.handle);
        const shown_ms = qpcMs() - m.t0;
        m.watchUntil(shown_ms + launch_watch_ms);
        var detail_buf: [160]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "window after {d} ms, minimized: {}, above the decoy: {}", .{ shown_ms, w.IsIconic(hwnd) != 0, fixture.above(hwnd, p.decoy.hwnd) }) catch "";
        p.end(&m, target, route.label, rep, true, detail, shown_ms + launch_watch_ms);
        // A window that started minimized is restored behind the decoy.
        if (w.IsIconic(hwnd) != 0) {
            var r = p.begin(hwnd) orelse return;
            _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
            const restored = waitShow(hwnd, .normal);
            p.end(&r, target, route.restore, rep, restored, "", watch_ms);
        }
        closeLaunched(p, win);
        _ = p.decoy.front();
        w.Sleep(500);
    };
}

/// Closes what a launch opened. In Notepad, the probe's own tab first, by
/// its close button: the user's restored tabs stay.
fn closeLaunched(p: *Probe, win: display.WindowInfo) void {
    if (std.ascii.eqlIgnoreCase(win.exe, "Notepad.exe")) {
        _ = p.scratch.reset(.retain_capacity);
        if (p.snapshot(win.handle)) |els| {
            var in_tab = false;
            var depth: u16 = 0;
            for (els) |e| {
                if (e.role == .tabitem) {
                    in_tab = std.mem.indexOf(u8, e.name, scratch_name) != null;
                    depth = e.depth;
                    continue;
                }
                if (in_tab and e.depth > depth and e.role == .button and e.actions.invoke) {
                    _ = patternCall(p.backend, p.scratch.allocator(), win.handle, e.key, .invoke, null);
                    w.Sleep(400);
                    break;
                }
            }
        }
    }
    if (!closeWindow(@ptrFromInt(win.handle))) p.print("launch | window 0x{x} ({s}) still open after WM_CLOSE: close it by hand", .{ win.handle, win.exe });
}

const scratch_name = "neo-compute-probe";

fn launchMeasures(p: *Probe, env: *const std.process.Environ.Map) void {
    var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var cancel: std.atomic.Value(bool) = .init(false);

    // Calculator, a packaged application.
    calc: {
        const listed = switch (p.backend.appCatalog(a, &cancel)) {
            .ok => |l| l,
            .err => |e| {
                p.print("launch calculator | skipped: {s}", .{e});
                break :calc;
            },
        };
        const app = for (listed) |x| {
            if (std.mem.startsWith(u8, x.aumid, "Microsoft.WindowsCalculator_")) break x;
        } else {
            p.print("launch calculator | skipped: Calculator is not in the Start menu", .{});
            break :calc;
        };
        for (p.backend.listWindows(a, true) catch &.{}) |win| if (std.mem.eql(u8, win.title, "Calculatrice") or std.mem.eql(u8, win.title, "Calculator")) {
            p.print("launch calculator | skipped: a Calculator window is already open (0x{x})", .{win.handle});
            break :calc;
        };
        const file = std.fmt.allocPrint(a, "shell:AppsFolder\\{s}", .{app.aumid}) catch break :calc;
        launchSeries(p, "launch calculator", &.{
            .{ .label = "IApplicationActivationManager AO_NONE", .activate = true },
            .{ .label = "ShellExecuteEx SW_SHOWNORMAL" },
            .{ .label = "ShellExecuteEx SW_SHOWNOACTIVATE", .show = .no_activate },
            .{ .label = "ShellExecuteEx SW_SHOWMINNOACTIVE", .show = .minimized, .restore = "ShellExecuteEx SW_SHOWMINNOACTIVE, then SW_SHOWNOACTIVATE" },
        }, &.{ "ApplicationFrameHost.exe", "CalculatorApp.exe" }, app.aumid, file);
    }

    // A text document. `.txt` may open in the user's editor: a scratch
    // `.log`, which Notepad opens on the reference machine.
    doc: {
        const exe = p.backend.defaultApp(a, ".log") orelse {
            p.print("launch document | skipped: no default application for .log", .{});
            break :doc;
        };
        if (!std.ascii.eqlIgnoreCase(exe, "Notepad.exe")) {
            p.print("launch document | skipped: .log opens in {s}, not Notepad: the probe would act in a window of the user's editor", .{exe});
            break :doc;
        }
        for (p.backend.listWindows(a, true) catch &.{}) |win| if (std.ascii.eqlIgnoreCase(win.exe, exe)) {
            p.print("launch document | skipped: a {s} window is already open (0x{x})", .{ exe, win.handle });
            break :doc;
        };
        const temp = env.get("TEMP") orelse {
            p.print("launch document | skipped: TEMP is not set", .{});
            break :doc;
        };
        const path = std.fs.path.join(a, &.{ temp, scratch_name ++ ".log" }) catch break :doc;
        std.Io.Dir.cwd().writeFile(p.io, .{ .sub_path = path, .data = "neo-compute background probe\r\n" }) catch {
            p.print("launch document | skipped: cannot write {s}", .{path});
            break :doc;
        };
        defer std.Io.Dir.cwd().deleteFile(p.io, path) catch {};
        launchSeries(p, "launch document", &.{
            .{ .label = "ShellExecuteEx SW_SHOWNORMAL" },
            .{ .label = "ShellExecuteEx SW_SHOWNOACTIVATE", .show = .no_activate },
            .{ .label = "ShellExecuteEx SW_SHOWMINNOACTIVE", .show = .minimized, .restore = "ShellExecuteEx SW_SHOWMINNOACTIVE, then SW_SHOWNOACTIVATE" },
        }, &.{exe}, null, path);
    }
}

fn summary(p: *Probe) void {
    p.print("summary | target | primitive | runs | effect read | effect not readable | foreground changed | focus changed | cursor moved | runs fully covered", .{});
    for (p.stats.items) |s| {
        if (s.missing) {
            p.print("summary | {s} | {s} | no element", .{ s.target, s.label });
            continue;
        }
        p.print("summary | {s} | {s} | {d} | {d} | {d} | {d} | {d} | {d} | {d}", .{ s.target, s.label, s.runs, s.effect, s.unverifiable, s.foreground, s.focus, s.cursor, s.covered });
    }
    var intrusive: usize = 0;
    for (p.stats.items) |s| if (s.foreground > 0 or s.focus > 0 or s.cursor > 0) {
        intrusive += 1;
        p.print("INTRUSIVE | {s} | {s} | foreground {d}/{d}, focus {d}/{d}, cursor {d}/{d}", .{ s.target, s.label, s.foreground, s.runs, s.focus, s.runs, s.cursor, s.runs });
    };
    if (intrusive == 0) p.print("no primitive changed the foreground, the focus or the cursor", .{});
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, log: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    var dump_only = false;
    var only: ?[]const u8 = null;
    // `autofocus=on` measures UI Automation as it comes (AutoSetFocus on, the
    // a11y and vision modes); the default measures what the background mode
    // runs, AutoSetFocus off.
    var auto_focus = false;
    var wanted: std.ArrayList([]const u8) = .empty;
    defer wanted.deinit(gpa);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "dump")) {
            dump_only = true;
        } else if (std.mem.startsWith(u8, arg, "only=")) {
            only = arg["only=".len..];
        } else if (std.mem.eql(u8, arg, "autofocus=on")) {
            auto_focus = true;
        } else if (std.mem.eql(u8, arg, "autofocus=off")) {
            auto_focus = false;
        } else try wanted.append(gpa, arg);
    }
    const want = struct {
        fn f(list: []const []const u8, name: []const u8) bool {
            if (list.len == 0) return true;
            for (list) |x| if (std.mem.eql(u8, x, name)) return true;
            return false;
        }
    }.f;
    for (wanted.items) |name| {
        const known = for ([_][]const u8{ "window", "show", "launch" }) |k| {
            if (std.mem.eql(u8, k, name)) break true;
        } else for (reference_apps) |app| {
            if (std.mem.eql(u8, app.name, name)) break true;
        } else false;
        if (!known) {
            log.print("bg-probe: unknown target `{s}` (window, show, launch, notepad, calculator, settings, explorer, chrome, vscode)\n", .{name}) catch {};
            return 2;
        }
    }

    var backend: Windows = .init(gpa);
    defer backend.deinit();
    const displays = backend.displays();
    if (displays.len == 0) {
        log.print("bg-probe: no display enumerated\n", .{}) catch {};
        return 1;
    }
    // The decoy takes most of the primary display; the targets go under it.
    const primary = displays[0].rect;
    const area: display.Rect = .{ .x = primary.x + 40, .y = primary.y + 40, .w = primary.w - 80, .h = primary.h - 160 };
    var decoy = Decoy.start(io, area) catch |err| {
        log.print("bg-probe: the decoy window cannot take the foreground ({t}): run the probe from a terminal the user is not typing in\n", .{err}) catch {};
        return 1;
    };
    defer decoy.stop(io);
    var p: Probe = .{ .gpa = gpa, .io = io, .log = log, .backend = &backend, .decoy = decoy, .scratch = .init(gpa) };
    defer p.scratch.deinit();
    defer p.stats.deinit(gpa);
    p.only = only;
    backend.uiAutoFocus(auto_focus);
    p.print("UI Automation AutoSetFocus: {s}", .{if (auto_focus) "on (UI Automation's default, a11y and vision modes)" else "off (background mode)"});
    p.print("decoy 0x{x} of another process in the foreground at {d},{d} {d}x{d}; every primitive runs {d} times on a target that is not active", .{ @intFromPtr(decoy.hwnd), area.x, area.y, area.w, area.h, reps });

    if (want(wanted.items, "window") or want(wanted.items, "show")) try probeWindow(&p, dump_only, wanted.items.len > 0 and !want(wanted.items, "window"));
    for (reference_apps) |app| if (!p.lost and want(wanted.items, app.name)) probeApp(&p, app, dump_only);
    if (!dump_only and !p.lost and want(wanted.items, "launch")) launchMeasures(&p, env);
    if (!dump_only) summary(&p);
    return if (p.lost) 1 else 0;
}
