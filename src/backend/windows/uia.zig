//! UI Automation on one dedicated worker thread without windows, in the
//! multithreaded apartment (US-011). Every UIA object is created, used and
//! released on that thread; the dispatcher hands it one job at a time and
//! waits. A snapshot reads a window's whole control-view subtree in one
//! cached round trip (FindAllBuildCache with at most 12 properties and the
//! actionable patterns) under a 200 ms provider timeout (IUIAutomation2), and
//! keeps the element references so ui_act reaches an element directly.
//!
//! Each root of a snapshot (the window, then its menus, popups and owned
//! windows, US-023) is read the same way. The main cache also carries the
//! RangeValue and Scroll patterns (patterns, not properties: the 12
//! properties stay), so the elements that have them are known; one cached
//! round trip per such element then adds their positions (US-022). A single
//! FindAllBuildCache over the subtree costs as much as the main read on a
//! large tree (A7, docs/decisions/0009). The focused element's selection is
//! read live through TextPattern.
//!
//! With `text` (US-024), a web document's subtree is read again in the
//! content view, which holds its text nodes, and replaces the control-view
//! subtree in place: reading order is the tree order.
//!
//! A Firefox window whose native UIA is off is served by UIA's MSAA proxy,
//! detected from the document's provider description. Its `edit` elements
//! are checked against MSAA's role and state (labels, protected fields),
//! hidden preloaded pages are dropped, and `invoke` runs the element's MSAA
//! default action (US-025, docs/decisions/0009).

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const uitree = @import("../../core/uitree.zig");
const display = @import("../../core/display.zig");
const uia_events = @import("uia_events.zig");
const check = com.check;
const release = com.release;

/// IUIAutomation2 TransactionTimeout: a provider silent for longer yields a
/// partial tree, and the worker stays available (US-011).
pub const transaction_timeout_ms = 200;
const connection_timeout_ms = 1000;

/// Properties cached per element: at most 12 (US-011).
const properties = [_]w.UIA_PROPERTY_ID{
    w.UIA_RuntimeIdPropertyId,   w.UIA_NamePropertyId,              w.UIA_ControlTypePropertyId,                       w.UIA_BoundingRectanglePropertyId,
    w.UIA_IsOffscreenPropertyId, w.UIA_IsEnabledPropertyId,         w.UIA_HasKeyboardFocusPropertyId,                  w.UIA_IsPasswordPropertyId,
    w.UIA_ValueValuePropertyId,  w.UIA_ToggleToggleStatePropertyId, w.UIA_ExpandCollapseExpandCollapseStatePropertyId, w.UIA_SelectionItemIsSelectedPropertyId,
};

comptime {
    std.debug.assert(properties.len <= 12);
}

/// MSAA's role and state, added to the main properties only for a Firefox
/// window served by UIA's MSAA proxy, which derives every property from
/// them anyway (US-025): the main cache stays at 12.
const msaa_properties = [_]w.UIA_PROPERTY_ID{ w.UIA_LegacyIAccessibleRolePropertyId, w.UIA_LegacyIAccessibleStatePropertyId };

const patterns = [_]struct { id: w.UIA_PATTERN_ID, field: []const u8 }{
    .{ .id = w.UIA_InvokePatternId, .field = "invoke" },
    .{ .id = w.UIA_ValuePatternId, .field = "value" },
    .{ .id = w.UIA_TogglePatternId, .field = "toggle" },
    .{ .id = w.UIA_ExpandCollapsePatternId, .field = "expand_collapse" },
    .{ .id = w.UIA_SelectionItemPatternId, .field = "select" },
    .{ .id = w.UIA_ScrollItemPatternId, .field = "scroll" },
};

/// Patterns cached only to find the elements whose position is read after
/// the walk, and to reach the focused element's selection without a lookup
/// (US-022).
const position_patterns = [_]w.UIA_PATTERN_ID{ w.UIA_RangeValuePatternId, w.UIA_ScrollPatternId, w.UIA_TextPatternId };

/// Elements whose position is read after the walk, at most this many per
/// snapshot (a long list of sliders is rare).
const max_positioned = 64;

/// Name and value lengths read from providers, in UTF-16 units: a document
/// can expose its whole text as a name.
const max_name_units = 256;
/// Name length of a web page's text nodes (US-024): a paragraph.
const max_text_units = 1024;
const max_value_units = 256;

/// IUIAutomationElement::SetFocus calls made by this process: the background
/// selftest proves the background mode makes none (EP-011).
pub var set_focus_calls: std.atomic.Value(u32) = .init(0);

/// Whether a control pattern call may first give the keyboard focus to its
/// target (IUIAutomation2 AutoSetFocus). UI Automation does it by default,
/// which brings the target's window to the foreground past the foreground
/// lock: US-040 measured it on Invoke, Toggle, SetValue, Expand, Collapse and
/// Select, on every reference application. The background mode turns it off
/// (EP-011), which takes the Windows 8 automation object: see `Session.init`.
pub var auto_set_focus: std.atomic.Value(bool) = .init(true);

const no_auto_focus_message = "Mode arrière-plan : UI Automation ne peut pas agir sans prendre le focus sur ce système (CUIAutomation8 indisponible). Aucune action exécutée. Demande à Arthur de relancer en mode a11y.";

pub const closed_message = "Fenêtre fermée : rappelle window_list";
const msaa_set_value_message = "Action set_value indisponible sur cet élément Firefox : clique puis utilise type";
const hung_message = "L'application ne répond plus à UI Automation : réessaie, ou utilise screenshot.";

/// Whether the window's thread answers within the provider timeout. UI
/// Automation does not apply TransactionTimeout to every provider (a Win32
/// window whose thread is blocked holds the call until it answers), so a
/// hung window is detected before any UIA call and never blocks the worker.
fn responsive(hwnd: w.HWND) bool {
    var result: usize = 0;
    return w.SendMessageTimeoutW(hwnd, w.WM_NULL, 0, 0, w.SMTO_ABORTIFHUNG, transaction_timeout_ms, &result) != 0;
}

/// The window element alone, from Win32 (no UIA call): the partial tree of
/// a window that does not answer.
fn hungRoot(arena: std.mem.Allocator, hwnd: w.HWND, desktop: bool) uitree.SnapshotResult {
    var title: [256:0]u16 = undefined;
    // Never sends WM_GETTEXT, unlike GetWindowTextW on our own windows.
    const n: usize = @intCast(@max(0, w.InternalGetWindowText(hwnd, &title, title.len)));
    var r: w.RECT = undefined;
    if (w.GetWindowRect(hwnd, &r) == 0) return .{ .err = closed_message };
    const els = arena.alloc(uitree.Element, 1) catch return .{ .err = "Mémoire insuffisante : réessaie." };
    els[0] = .{
        .key = std.hash.Wyhash.hash(0x6e656f, std.mem.asBytes(&@intFromPtr(hwnd))),
        .depth = 0,
        .role = .window,
        .name = utf8(arena, title[0..n], max_name_units) catch "",
        .rect = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top },
    };
    return .{ .ok = .{ .window = @intFromPtr(hwnd), .elements = els, .partial = true, .desktop = desktop } };
}

const Job = union(enum) {
    snapshot: struct { arena: std.mem.Allocator, hwnd: ?u64, request: uitree.Request, out: uitree.SnapshotResult = undefined },
    act: struct { arena: std.mem.Allocator, window: u64, key: u64, action: uitree.Action, value: ?[]const u8, out: uitree.ActResult = undefined },
    /// Rectangles of the visible password fields of the foreground window,
    /// into `Worker.secret_buf` (no arena: the dispatcher keeps using its
    /// own while the scan runs).
    secrets,
    /// Subscribes to the UI Automation events of `hwnd` in place of the
    /// window watched before; 0: none.
    watch: struct { hwnd: u64, out: bool = false },
    quit,
};

/// Password fields masked per screenshot; more are rare enough to ignore.
pub const max_secrets = 32;

pub const Worker = struct {
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    wake: w.HANDLE = null,
    done: w.HANDLE = null,
    job: Job = .quit,
    /// A job was started with `begin` and not yet waited for.
    pending: bool = false,
    secret_buf: [max_secrets]display.Rect = undefined,
    secret_len: usize = 0,
    /// Why the worker could not start UI Automation, if it failed.
    init_error: ?[]const u8 = null,
    /// Range and scroll round trips of the last snapshot, written by the
    /// worker before it signals `done`.
    extras_ns: u64 = 0,
    /// The last snapshot read Firefox through UIA's MSAA proxy (US-025).
    msaa_proxy: bool = false,
    msaa_ns: u64 = 0,

    /// Time of the MSAA corrections of the last snapshot (US-025).
    pub fn lastMsaaNs(self: *const Worker) u64 {
        return self.msaa_ns;
    }

    /// Whether the last snapshot read Firefox through the MSAA proxy.
    pub fn lastMsaaProxy(self: *const Worker) bool {
        return self.msaa_proxy;
    }

    /// Time of the range and scroll round trips of the last snapshot (A7).
    pub fn lastExtrasNs(self: *const Worker) u64 {
        return self.extras_ns;
    }

    pub fn snapshot(self: *Worker, arena: std.mem.Allocator, hwnd: ?u64, request: uitree.Request) uitree.SnapshotResult {
        if (self.start()) |msg| return .{ .err = msg };
        self.job = .{ .snapshot = .{ .arena = arena, .hwnd = hwnd, .request = request } };
        self.run();
        return self.job.snapshot.out;
    }

    pub fn act(self: *Worker, arena: std.mem.Allocator, window: u64, key: u64, action: uitree.Action, value: ?[]const u8) uitree.ActResult {
        if (self.start()) |msg| return .{ .failed = msg };
        self.job = .{ .act = .{ .arena = arena, .window = window, .key = key, .action = action, .value = value } };
        self.run();
        return self.job.act.out;
    }

    /// Subscribes to the UI Automation events of `hwnd` (`uia_events.zig`)
    /// in place of the window watched before; 0 removes the subscription.
    /// False when the window does not answer or refuses the handlers.
    pub fn watch(self: *Worker, hwnd: u64) bool {
        if (self.start() != null) return false;
        self.job = .{ .watch = .{ .hwnd = hwnd } };
        self.run();
        return self.job.watch.out;
    }

    /// Starts the password scan of the foreground window without waiting
    /// (US-019): it runs while the dispatcher captures and reduces.
    pub fn beginSecrets(self: *Worker) void {
        self.secret_len = 0;
        if (self.start() != null) return;
        self.finish();
        self.job = .secrets;
        self.pending = true;
        _ = w.SetEvent(self.wake);
    }

    /// Waits for the scan started by `beginSecrets`; empty when none ran.
    pub fn secretRects(self: *Worker) []const display.Rect {
        self.finish();
        return self.secret_buf[0..self.secret_len];
    }

    fn finish(self: *Worker) void {
        if (!self.pending) return;
        _ = w.WaitForSingleObject(self.done, w.INFINITE);
        self.pending = false;
    }

    pub fn deinit(self: *Worker) void {
        const t = self.thread orelse return;
        self.finish();
        self.job = .quit;
        _ = w.SetEvent(self.wake);
        t.join();
        _ = w.CloseHandle(self.wake);
        _ = w.CloseHandle(self.done);
        self.thread = null;
    }

    /// Starts the thread on first use; returns the failure message if UI
    /// Automation is unavailable.
    fn start(self: *Worker) ?[]const u8 {
        if (self.thread != null) return self.init_error;
        self.wake = w.CreateEventW(null, 0, 0, null);
        self.done = w.CreateEventW(null, 0, 0, null);
        if (self.wake == null or self.done == null) return "UI Automation indisponible : création des événements impossible, réessaie.";
        self.thread = std.Thread.spawn(.{}, loop, .{self}) catch return "UI Automation indisponible : thread de travail impossible à créer, réessaie.";
        _ = w.WaitForSingleObject(self.done, w.INFINITE);
        return self.init_error;
    }

    fn run(self: *Worker) void {
        self.finish();
        _ = w.SetEvent(self.wake);
        _ = w.WaitForSingleObject(self.done, w.INFINITE);
    }

    fn loop(self: *Worker) void {
        var session: ?Session = null;
        const com_ok = if (com.check(w.CoInitializeEx(null, @bitCast(w.COINIT_MULTITHREADED)))) true else |_| false;
        if (com_ok) {
            session = Session.init(self.gpa, !auto_set_focus.load(.monotonic)) catch |err| blk: {
                std.debug.print("neo-compute: UI Automation init failed: {t} hr=0x{x}\n", .{ err, com.lastHr() });
                self.init_error = "UI Automation indisponible (CUIAutomation) : détail sur stderr, utilise screenshot.";
                break :blk null;
            };
        } else self.init_error = "UI Automation indisponible : COM refuse le mode MTA, utilise screenshot.";
        _ = w.SetEvent(self.done);
        while (true) {
            _ = w.WaitForSingleObject(self.wake, w.INFINITE);
            // The background mode is selected after this thread started:
            // its automation object replaces the default one before the
            // first job, while no element is retained yet.
            if (session) |*s| if (!s.background and !auto_set_focus.load(.monotonic) and !s.upgrade_failed) {
                if (Session.init(self.gpa, true)) |fresh| {
                    s.deinit();
                    s.* = fresh;
                } else |err| {
                    std.debug.print("neo-compute: UI Automation without AutoSetFocus unavailable: {t} hr=0x{x}; background actions are refused\n", .{ err, com.lastHr() });
                    s.upgrade_failed = true;
                }
            };
            switch (self.job) {
                .quit => break,
                .snapshot => |*j| {
                    session.?.extras_ns = 0;
                    j.out = session.?.snapshot(j.arena, j.hwnd, j.request);
                    self.extras_ns = session.?.extras_ns;
                    self.msaa_proxy = session.?.last_msaa;
                    self.msaa_ns = session.?.msaa_ns;
                },
                .act => |*j| j.out = session.?.act(j.arena, j.window, j.key, j.action, j.value),
                .secrets => self.secret_len = session.?.secrets(&self.secret_buf),
                .watch => |*j| j.out = session.?.watchWindow(j.hwnd),
            }
            _ = w.SetEvent(self.done);
        }
        if (session) |*s| s.deinit();
        if (com_ok) w.CoUninitialize();
    }
};

/// Element references of the last snapshot of a window, for ui_act.
const Retained = struct {
    hwnd: u64 = 0,
    used: u64 = 0,
    keys: std.ArrayList(u64) = .empty,
    elements: std.ArrayList(*w.IUIAutomationElement) = .empty,
    /// Read through UIA's MSAA proxy: a Firefox without native UIA (US-025).
    msaa_proxy: bool = false,

    fn clear(self: *Retained) void {
        for (self.elements.items) |el| release(el);
        self.elements.clearRetainingCapacity();
        self.keys.clearRetainingCapacity();
        self.msaa_proxy = false;
    }

    /// The retained element of `key`, if this snapshot read it.
    fn find(self: *const Retained, key: u64) ?*w.IUIAutomationElement {
        for (self.keys.items, 0..) |k, i| if (k == key) return self.elements.items[i];
        return null;
    }

    fn deinit(self: *Retained, gpa: std.mem.Allocator) void {
        self.clear();
        self.keys.deinit(gpa);
        self.elements.deinit(gpa);
    }
};

/// UI Automation objects of the worker thread.
const Session = struct {
    gpa: std.mem.Allocator,
    automation: *w.IUIAutomation,
    /// The Windows 8 automation object with AutoSetFocus off (EP-011).
    background: bool = false,
    /// That object could not be created: actions are refused while
    /// `auto_set_focus` is off.
    upgrade_failed: bool = false,
    subtree: *w.IUIAutomationCacheRequest,
    control_view: *w.IUIAutomationCondition,
    /// The window element's own properties, for a partial tree.
    element_cache: ?*w.IUIAutomationCacheRequest = null,
    /// IsPassword = true, and the properties a masked field needs.
    password_condition: ?*w.IUIAutomationCondition = null,
    secret_cache: ?*w.IUIAutomationCacheRequest = null,
    /// RangeValue and Scroll properties of one element (US-022).
    extras_cache: ?*w.IUIAutomationCacheRequest = null,
    /// RuntimeIds of a window element and its children (US-023).
    probe_cache: ?*w.IUIAutomationCacheRequest = null,
    /// The main cache over the content view, and that view's condition:
    /// a web document with its text nodes (US-024).
    content_cache: ?*w.IUIAutomationCacheRequest = null,
    content_view: ?*w.IUIAutomationCondition = null,
    /// The main cache plus MSAA's role and state, over the on-screen
    /// control view: a Firefox window served by the MSAA proxy (US-025).
    msaa_cache: ?*w.IUIAutomationCacheRequest = null,
    /// The last snapshot came through the MSAA proxy, and the time of its
    /// corrections.
    last_msaa: bool = false,
    msaa_ns: u64 = 0,
    /// Name length `read` keeps, in UTF-16 units.
    name_units: usize = max_name_units,
    extras_ns: u64 = 0,
    retained: [4]Retained = @splat(.{}),
    clock: u64 = 0,
    /// The event handlers registered on the watched window, and those of a
    /// window that did not answer when they had to be removed.
    watched: ?uia_events.Subscription = null,
    stale: ?uia_events.Subscription = null,

    /// `background`: the Windows 8 automation object (CUIAutomation8), the
    /// only one that exposes IUIAutomation2, with AutoSetFocus off. The
    /// default object (CUIAutomation) keeps the Windows 7 behavior, where a
    /// pattern call always focuses its target.
    fn init(gpa: std.mem.Allocator, background: bool) com.Error!Session {
        var raw: ?*anyopaque = null;
        try check(w.CoCreateInstance(if (background) &w.CLSID_CUIAutomation8 else &w.CLSID_CUIAutomation, null, w.CLSCTX_INPROC_SERVER, &w.IUIAutomation.iid, &raw));
        const automation: *w.IUIAutomation = @ptrCast(@alignCast(raw.?));
        errdefer release(automation);
        var raw2: ?*anyopaque = null;
        if (background) {
            try check(automation.vtable.QueryInterface(automation, &w.IUIAutomation2.iid, &raw2));
            const a2: *w.IUIAutomation2 = @ptrCast(@alignCast(raw2.?));
            defer release(a2);
            try check(a2.vtable.put_AutoSetFocus(a2, 0));
            // The timeouts stay at UI Automation's defaults, as the default
            // object runs them: see below and decision 0013.
        } else if (automation.vtable.QueryInterface(automation, &w.IUIAutomation2.iid, &raw2) >= 0) {
            // Bounded waits on providers. US-040 found that CUIAutomation
            // answers this QueryInterface with E_NOINTERFACE on Windows 11:
            // these timeouts have never been applied. Applying them changes
            // every mode's behavior and bench: left to decision 0013.
            const a2: *w.IUIAutomation2 = @ptrCast(@alignCast(raw2.?));
            defer release(a2);
            try check(a2.vtable.put_TransactionTimeout(a2, transaction_timeout_ms));
            try check(a2.vtable.put_ConnectionTimeout(a2, connection_timeout_ms));
        }
        var cond: ?*w.IUIAutomationCondition = null;
        try check(automation.vtable.get_ControlViewCondition(automation, &cond));
        errdefer release(cond.?);
        var cache: ?*w.IUIAutomationCacheRequest = null;
        try check(automation.vtable.CreateCacheRequest(automation, &cache));
        errdefer release(cache.?);
        for (properties) |p| try check(cache.?.vtable.AddProperty(cache.?, p));
        for (patterns) |p| try check(cache.?.vtable.AddPattern(cache.?, p.id));
        for (position_patterns) |id| try check(cache.?.vtable.AddPattern(cache.?, id));
        try check(cache.?.vtable.put_TreeScope(cache.?, w.TreeScope_Subtree));
        try check(cache.?.vtable.put_TreeFilter(cache.?, cond.?));
        return .{ .gpa = gpa, .automation = automation, .background = background, .subtree = cache.?, .control_view = cond.? };
    }

    /// Moves the event subscription to `hwnd` (0: none). Removing handlers
    /// is a round trip to the provider, like adding them: a window whose
    /// thread is stopped would hold either, so its handlers wait in `stale`
    /// until it answers or is gone.
    fn watchWindow(self: *Session, hwnd: u64) bool {
        const h: w.HWND = @ptrFromInt(hwnd);
        if (self.watched) |sub| {
            if (sub.hwnd == h) return true;
            self.watched = null;
            self.unwatch(sub);
        }
        if (self.stale) |sub| {
            self.stale = null;
            self.unwatch(sub);
        }
        if (hwnd == 0 or w.IsWindow(h) == 0 or !responsive(h)) return false;
        self.watched = uia_events.add(self.automation, h);
        return self.watched != null;
    }

    fn unwatch(self: *Session, sub: uia_events.Subscription) void {
        if (w.IsWindow(sub.hwnd) != 0 and !responsive(sub.hwnd)) {
            // A second one while the first still waits: the older keeps its
            // handlers until the process ends. They only count.
            if (self.stale) |old| release(old.element);
            self.stale = sub;
            return;
        }
        uia_events.remove(self.automation, &sub);
    }

    fn deinit(self: *Session) void {
        _ = self.watchWindow(0);
        if (self.stale) |sub| release(sub.element);
        for (&self.retained) |*r| r.deinit(self.gpa);
        if (self.element_cache) |c| release(c);
        if (self.password_condition) |c| release(c);
        if (self.secret_cache) |c| release(c);
        if (self.extras_cache) |c| release(c);
        if (self.probe_cache) |c| release(c);
        if (self.content_cache) |c| release(c);
        if (self.content_view) |c| release(c);
        if (self.msaa_cache) |c| release(c);
        release(self.subtree);
        release(self.control_view);
        release(self.automation);
    }

    /// The window to read: `hwnd`, else the foreground window, else (no
    /// active window, desktop in front) the taskbar.
    fn target(hwnd: ?u64) struct { hwnd: w.HWND, desktop: bool } {
        if (hwnd) |h| return .{ .hwnd = @ptrFromInt(h), .desktop = false };
        const fg = w.GetForegroundWindow();
        if (fg != null and !isDesktop(fg)) return .{ .hwnd = fg, .desktop = false };
        return .{ .hwnd = w.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd"), null), .desktop = true };
    }

    fn isDesktop(hwnd: w.HWND) bool {
        var class: [64:0]u16 = undefined;
        const n = w.GetClassNameW(hwnd, &class, class.len);
        if (n <= 0) return false;
        const name = class[0..@intCast(n)];
        return std.mem.eql(u16, name, std.unicode.utf8ToUtf16LeStringLiteral("Progman")) or
            std.mem.eql(u16, name, std.unicode.utf8ToUtf16LeStringLiteral("WorkerW"));
    }

    /// Chrome, Edge and Electron top-level windows.
    fn isChromium(hwnd: w.HWND) bool {
        var class: [64:0]u16 = undefined;
        const n = w.GetClassNameW(hwnd, &class, class.len);
        if (n <= 0) return false;
        return std.mem.startsWith(u16, class[0..@intCast(n)], std.unicode.utf8ToUtf16LeStringLiteral("Chrome_WidgetWin_"));
    }

    /// Chromium answers the first UIA request with its frame only and builds
    /// the web tree afterward: no document element yet.
    /// A Firefox window with its accessibility off exposes only the frame
    /// Windows builds for it: no toolbar and no document (US-025).
    fn firefoxNoTree(hwnd: w.HWND, elements: []const uitree.Element) bool {
        if (!isFirefox(hwnd)) return false;
        for (elements) |e| if (e.role == .document or e.role == .toolbar) return false;
        return true;
    }

    fn isFirefox(hwnd: w.HWND) bool {
        var class: [64:0]u16 = undefined;
        const n = w.GetClassNameW(hwnd, &class, class.len);
        if (n <= 0) return false;
        return std.mem.eql(u16, class[0..@intCast(n)], std.unicode.utf8ToUtf16LeStringLiteral("MozillaWindowClass"));
    }

    fn webPending(hwnd: w.HWND, elements: []const uitree.Element) bool {
        if (!isChromium(hwnd)) return false;
        for (elements) |e| if (e.role == .document) return false;
        return true;
    }

    fn snapshot(self: *Session, arena: std.mem.Allocator, hwnd: ?u64, request: uitree.Request) uitree.SnapshotResult {
        const t = target(hwnd);
        if (t.hwnd == null or w.IsWindow(t.hwnd) == 0) return .{ .err = if (t.desktop) "Aucune fenêtre active et barre des tâches introuvable : utilise screenshot." else closed_message };
        const window: u64 = @intFromPtr(t.hwnd);
        if (!responsive(t.hwnd)) return hungRoot(arena, t.hwnd, t.desktop);
        var partial = false;
        // Firefox with its native UIA off: UIA serves it through its MSAA
        // proxy, read with MSAA's role and state and on-screen only (US-025).
        self.last_msaa = isFirefox(t.hwnd) and self.windowProxied(t.hwnd);
        const cache = if (self.last_msaa) self.msaaCache() catch self.subtree else self.subtree;
        const root = self.readRootWith(t.hwnd, cache, &partial) catch |err| return .{ .err = switch (err) {
            error.ElementNotAvailable => closed_message,
            error.Timeout => hung_message,
            else => fail(arena, "lecture de l'arbre"),
        } };
        defer release(root);
        const slot = self.slotFor(window);
        var out: std.ArrayList(uitree.Element) = .empty;
        var roots: std.ArrayList(uitree.Root) = .empty;
        var positioned: std.ArrayList(Positioned) = .empty;
        // Keys already read: a XAML popup also shows inside its window's
        // tree, and is read once.
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        const oom: uitree.SnapshotResult = .{ .err = "Mémoire insuffisante : réessaie." };
        roots.append(arena, .{ .start = 0, .handle = window }) catch return oom;
        self.walk(arena, root, slot, &out, &positioned, &seen) catch return oom;
        // The window itself: Win32 only, a modal dialog disables its owner.
        roots.items[0].modal = @import("window.zig").ownerDisabled(t.hwnd);
        var web_text: uitree.WebText = .not_requested;
        var page: ?uitree.Page = null;
        // A Chromium tree without its document yet: not read (web_pending).
        if (request.text and !webPending(t.hwnd, out.items)) {
            const doc: ?usize = if (isBrowser(t.hwnd)) for (out.items, 0..) |e, i| {
                if (e.role == .document) break i;
            } else null else null;
            if (doc) |d| {
                page = self.readWebText(arena, slot, &out, &positioned, &seen, d) catch return oom;
                web_text = .read;
            } else web_text = .no_document;
        }
        self.msaa_ns = 0;
        if (self.last_msaa) {
            const t0 = qpc();
            defer self.msaa_ns = qpcNs(qpc() - t0);
            slot.msaa_proxy = true;
            fixMsaa(arena, slot, &out, &positioned) catch return oom;
        }
        // Menus, popups and owned windows (US-023). One that closes or
        // stops answering meanwhile is left out.
        for (request.extra_roots) |r| {
            const h: w.HWND = @ptrFromInt(r.handle);
            if (w.IsWindow(h) == 0 or w.IsWindowVisible(h) == 0 or !responsive(h)) continue;
            if (self.alreadyRead(h, &seen)) continue;
            var extra_partial = false;
            const el = self.readRoot(h, &extra_partial) catch continue;
            defer release(el);
            const start = out.items.len;
            self.walk(arena, el, slot, &out, &positioned, &seen) catch return oom;
            // A nameless host whose content was already read adds nothing.
            if (out.items.len == start + 1 and !named(out.items[start].name)) {
                out.items.len = start;
                while (positioned.items.len > 0 and positioned.items[positioned.items.len - 1].index >= start) positioned.items.len -= 1;
            }
            if (out.items.len == start) continue;
            out.items[start].depth = 0;
            partial = partial or extra_partial;
            roots.append(arena, .{ .start = @intCast(start), .handle = r.handle, .modal = modal(h, el, out.items[start..]) }) catch return oom;
        }
        self.readPositions(positioned.items, out.items, roots.items, &partial);
        // A provider that stopped answering is not asked again.
        if (!partial) self.readSelection(arena, slot, out.items);
        const single = roots.items.len == 1 and !roots.items[0].modal;
        return .{ .ok = .{ .window = window, .elements = out.items, .roots = if (single) &.{} else roots.items, .partial = partial, .desktop = t.desktop, .web_pending = webPending(t.hwnd, out.items), .firefox_no_tree = firefoxNoTree(t.hwnd, out.items), .web_text = web_text, .page = page } };
    }

    /// Whether the window is served by UIA's MSAA proxy (its provider
    /// description names `Microsoft: MSAA Proxy`), not by Firefox's native
    /// UIA (`xul.dll`). One live read on the window element.
    fn windowProxied(self: *Session, hwnd: w.HWND) bool {
        var found: ?*w.IUIAutomationElement = null;
        if (self.automation.vtable.ElementFromHandle(self.automation, hwnd, &found) < 0) return false;
        const el = found orelse return false;
        defer release(el);
        var v: w.VARIANT = std.mem.zeroes(w.VARIANT);
        if (el.vtable.GetCurrentPropertyValue(el, w.UIA_ProviderDescriptionPropertyId, &v) < 0) return false;
        defer _ = w.VariantClear(&v);
        if (vt(&v) != w.VT_BSTR) return false;
        const b = v.Anonymous.Anonymous.Anonymous.bstrVal orelse return false;
        const text = b[0..w.SysStringLen(b)];
        return std.mem.indexOf(u16, text, std.unicode.utf8ToUtf16LeStringLiteral("MSAA Proxy")) != null;
    }

    /// The main cache with MSAA's role and state added, over the on-screen
    /// control view: a preloaded page hidden in the window, often larger
    /// than the visible one, is never read (US-025).
    fn msaaCache(self: *Session) com.Error!*w.IUIAutomationCacheRequest {
        if (self.msaa_cache) |c| return c;
        var v: w.VARIANT = std.mem.zeroes(w.VARIANT);
        v.Anonymous.Anonymous.vt = w.VT_BOOL;
        v.Anonymous.Anonymous.Anonymous.boolVal = 0; // VARIANT_FALSE
        var on_screen: ?*w.IUIAutomationCondition = null;
        try check(self.automation.vtable.CreatePropertyCondition(self.automation, w.UIA_IsOffscreenPropertyId, v, &on_screen));
        defer release(on_screen.?);
        var filter: ?*w.IUIAutomationCondition = null;
        try check(self.automation.vtable.CreateAndCondition(self.automation, self.control_view, on_screen, &filter));
        defer release(filter.?);
        var cache: ?*w.IUIAutomationCacheRequest = null;
        try check(self.automation.vtable.CreateCacheRequest(self.automation, &cache));
        errdefer release(cache.?);
        for (properties ++ msaa_properties) |p| try check(cache.?.vtable.AddProperty(cache.?, p));
        for (patterns) |p| try check(cache.?.vtable.AddPattern(cache.?, p.id));
        for (position_patterns) |id| try check(cache.?.vtable.AddPattern(cache.?, id));
        try check(cache.?.vtable.put_TreeScope(cache.?, w.TreeScope_Subtree));
        try check(cache.?.vtable.put_TreeFilter(cache.?, filter));
        self.msaa_cache = cache;
        return cache.?;
    }

    /// Corrects a tree read through the MSAA proxy (US-025), from MSAA's
    /// role and state cached with each `edit`:
    /// - a text leaf (ROLE_SYSTEM_TEXT, not focusable) that the proxy maps to
    ///   Edit becomes `text`, so a label never looks like a field;
    /// - STATE_SYSTEM_PROTECTED marks a password, value dropped (FR-09);
    /// - an offscreen subtree without a rectangle (a preloaded New Tab
    ///   page that the on-screen filter let through) is dropped.
    fn fixMsaa(arena: std.mem.Allocator, slot: *Retained, out: *std.ArrayList(uitree.Element), positioned: *std.ArrayList(Positioned)) !void {
        const items = out.items;
        const keep = try arena.alloc(bool, items.len);
        var i: usize = 0;
        while (i < items.len) {
            const e = items[i];
            if (i != 0 and e.states.offscreen and e.rect.w <= 0 and e.rect.h <= 0) {
                var end = i + 1;
                while (end < items.len and items[end].depth > e.depth) end += 1;
                @memset(keep[i..end], false);
                i = end;
                continue;
            }
            keep[i] = true;
            i += 1;
        }
        for (items, keep) |*e, k| {
            if (!k or e.role != .edit) continue;
            const el = slot.find(e.key) orelse continue;
            const msaa_role: u32 = @bitCast(cachedInt(el, w.UIA_LegacyIAccessibleRolePropertyId) orelse continue);
            const state: u32 = @bitCast(cachedInt(el, w.UIA_LegacyIAccessibleStatePropertyId) orelse continue);
            if (state & w.STATE_SYSTEM_PROTECTED != 0) {
                e.password = true;
                e.value = null;
            } else if (msaa_role == w.ROLE_SYSTEM_TEXT and state & w.STATE_SYSTEM_FOCUSABLE == 0) {
                e.role = .text;
                e.actions.value = false;
                e.value = null;
            }
        }
        // Compaction: kept elements in order, positions remapped.
        const gone = std.math.maxInt(u32);
        const map = try arena.alloc(u32, items.len);
        var n: u32 = 0;
        for (items, keep, map) |e, k, *m| {
            m.* = if (k) n else gone;
            if (!k) continue;
            items[n] = e;
            n += 1;
        }
        out.items.len = n;
        var kept: usize = 0;
        for (positioned.items) |p| {
            if (map[p.index] == gone) continue;
            var q = p;
            q.index = map[p.index];
            positioned.items[kept] = q;
            kept += 1;
        }
        positioned.items.len = kept;
    }

    /// Whether `window`'s retained tree came through the MSAA proxy.
    fn msaaWindow(self: *const Session, window: u64) bool {
        for (&self.retained) |*r| if (r.used != 0 and r.hwnd == window) return r.msaa_proxy;
        return false;
    }

    /// Chrome, Edge, Electron and Firefox top-level windows.
    fn isBrowser(hwnd: w.HWND) bool {
        return isChromium(hwnd) or isFirefox(hwnd);
    }

    /// Replaces the control-view subtree of the web document `doc` in `out`
    /// by its content-view subtree, which holds the text nodes, in one
    /// cached round trip (US-024). Returns the document's vertical scroll
    /// position, when it exposes one.
    fn readWebText(self: *Session, arena: std.mem.Allocator, slot: *Retained, out: *std.ArrayList(uitree.Element), positioned: *std.ArrayList(Positioned), seen: *std.AutoHashMapUnmanaged(u64, void), doc: usize) !?uitree.Page {
        const key = out.items[doc].key;
        const doc_el = slot.find(key) orelse return null;
        const page = documentPage(doc_el);
        const cache = self.contentCache() catch return page;
        var arr: ?*w.IUIAutomationElementArray = null;
        check(doc_el.vtable.FindAllBuildCache(doc_el, w.TreeScope_Element, self.content_view, cache, &arr)) catch return page;
        const array = arr orelse return page;
        defer release(array);
        var len: i32 = 0;
        if (array.vtable.get_Length(array, &len) < 0 or len == 0) return page;
        var first: ?*w.IUIAutomationElement = null;
        if (array.vtable.GetElement(array, 0, &first) < 0) return page;
        const root = first orelse return page;
        defer release(root);
        var tmp: std.ArrayList(uitree.Element) = .empty;
        var tmp_positioned: std.ArrayList(Positioned) = .empty;
        var tmp_seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        self.name_units = max_text_units;
        defer self.name_units = max_name_units;
        try self.walk(arena, root, slot, &tmp, &tmp_positioned, &tmp_seen);
        if (tmp.items.len == 0) return page;
        // Splice: the document keeps its place and depth.
        const depth = out.items[doc].depth;
        var end = doc + 1;
        while (end < out.items.len and out.items[end].depth > depth) end += 1;
        for (tmp.items) |*e| e.depth +|= depth;
        try out.replaceRange(arena, doc, end - doc, tmp.items);
        const shift: isize = @as(isize, @intCast(tmp.items.len)) - @as(isize, @intCast(end - doc));
        var kept: usize = 0;
        for (positioned.items) |p| {
            if (p.index >= doc and p.index < end) continue;
            var q = p;
            if (p.index >= end) q.index = @intCast(@as(isize, p.index) + shift);
            positioned.items[kept] = q;
            kept += 1;
        }
        positioned.items.len = kept;
        for (tmp_positioned.items) |p| {
            var q = p;
            q.index += @intCast(doc);
            try positioned.append(arena, q);
        }
        for (tmp.items) |e| try seen.put(arena, e.key, {});
        return page;
    }

    fn contentCache(self: *Session) com.Error!*w.IUIAutomationCacheRequest {
        if (self.content_cache) |c| return c;
        if (self.content_view == null) {
            var cond: ?*w.IUIAutomationCondition = null;
            try check(self.automation.vtable.get_ContentViewCondition(self.automation, &cond));
            self.content_view = cond;
        }
        var cache: ?*w.IUIAutomationCacheRequest = null;
        try check(self.automation.vtable.CreateCacheRequest(self.automation, &cache));
        errdefer release(cache.?);
        for (properties) |p| try check(cache.?.vtable.AddProperty(cache.?, p));
        for (patterns) |p| try check(cache.?.vtable.AddPattern(cache.?, p.id));
        for (position_patterns) |id| try check(cache.?.vtable.AddPattern(cache.?, id));
        try check(cache.?.vtable.put_TreeScope(cache.?, w.TreeScope_Subtree));
        try check(cache.?.vtable.put_TreeFilter(cache.?, self.content_view));
        self.content_cache = cache;
        return cache.?;
    }

    /// The web document's vertical scroll position, read live: Chrome
    /// exposes ScrollPattern on its document.
    fn documentPage(el: *w.IUIAutomationElement) ?uitree.Page {
        var raw: ?*anyopaque = null;
        if (el.vtable.GetCurrentPatternAs(el, w.UIA_ScrollPatternId, &w.IUIAutomationScrollPattern.iid, &raw) < 0) return null;
        const sp: *w.IUIAutomationScrollPattern = @ptrCast(@alignCast(raw orelse return null));
        defer release(sp);
        // A page shorter than its viewport reports no vertical scroll.
        var scrollable: w.BOOL = 0;
        if (sp.vtable.get_CurrentVerticallyScrollable(sp, &scrollable) < 0) return null;
        if (scrollable == 0) return .fits;
        var v: f64 = 0;
        if (sp.vtable.get_CurrentVerticalScrollPercent(sp, &v) < 0) return null;
        return .{ .at = scrollPercent(v) orelse return null };
    }

    /// Whether the window's element or one of its children was read under
    /// an earlier root: a XAML popup also shows inside its window's tree.
    /// One small cached round trip (RuntimeIds only) instead of a walk.
    fn alreadyRead(self: *Session, hwnd: w.HWND, seen: *const std.AutoHashMapUnmanaged(u64, void)) bool {
        const cache = self.probeCache() catch return false;
        var found: ?*w.IUIAutomationElement = null;
        if (self.automation.vtable.ElementFromHandleBuildCache(self.automation, hwnd, cache, &found) < 0) return false;
        const el = found orelse return false;
        defer release(el);
        if (runtimeKey(el)) |k| if (seen.contains(k)) return true;
        var children: ?*w.IUIAutomationElementArray = null;
        if (el.vtable.GetCachedChildren(el, &children) < 0) return false;
        const arr = children orelse return false;
        defer release(arr);
        var len: i32 = 0;
        if (arr.vtable.get_Length(arr, &len) < 0) return false;
        var i: i32 = 0;
        while (i < len) : (i += 1) {
            var child: ?*w.IUIAutomationElement = null;
            if (arr.vtable.GetElement(arr, i, &child) < 0) continue;
            const c = child orelse continue;
            defer release(c);
            if (runtimeKey(c)) |k| if (seen.contains(k)) return true;
        }
        return false;
    }

    fn probeCache(self: *Session) com.Error!*w.IUIAutomationCacheRequest {
        if (self.probe_cache) |c| return c;
        var cache: ?*w.IUIAutomationCacheRequest = null;
        try check(self.automation.vtable.CreateCacheRequest(self.automation, &cache));
        errdefer release(cache.?);
        try check(cache.?.vtable.AddProperty(cache.?, w.UIA_RuntimeIdPropertyId));
        try check(cache.?.vtable.put_TreeScope(cache.?, w.TreeScope_Element | w.TreeScope_Children));
        try check(cache.?.vtable.put_TreeFilter(cache.?, self.control_view));
        self.probe_cache = cache;
        return cache.?;
    }

    /// A modal root: its owner is disabled, or a window element reports
    /// WindowPattern.IsModal (read live, once per root).
    fn modal(hwnd: w.HWND, el: *w.IUIAutomationElement, elements: []const uitree.Element) bool {
        if (@import("window.zig").ownerDisabled(hwnd)) return true;
        if (elements.len == 0 or elements[0].role != .window) return false;
        var v: w.VARIANT = std.mem.zeroes(w.VARIANT);
        if (el.vtable.GetCurrentPropertyValue(el, w.UIA_WindowIsModalPropertyId, &v) < 0) return false;
        defer _ = w.VariantClear(&v);
        return vt(&v) == w.VT_BOOL and v.Anonymous.Anonymous.Anonymous.boolVal != 0;
    }

    /// RangeValue and Scroll of the elements whose cached patterns showed
    /// them, one cached round trip each (US-022). A provider that times out
    /// leaves the remaining fields out and marks the tree partial. UI
    /// Automation does not time out a round trip to a window whose thread
    /// stopped after the main read (measured: it waits until the thread
    /// answers), so each round trip first checks that the element's root
    /// window answers within the provider timeout.
    fn readPositions(self: *Session, list: []const Positioned, elements: []uitree.Element, roots: []const uitree.Root, partial: *bool) void {
        if (list.len == 0) return;
        const t0 = qpc();
        defer self.extras_ns += qpcNs(qpc() - t0);
        const cache = self.extrasCache() catch return;
        for (list) |p| {
            var root = roots[0];
            for (roots) |r| if (r.start <= p.index and r.start >= root.start) {
                root = r;
            };
            if (!responsive(@ptrFromInt(root.handle))) {
                partial.* = true;
                return;
            }
            var updated: ?*w.IUIAutomationElement = null;
            check(p.el.vtable.BuildUpdatedCache(p.el, cache, &updated)) catch {
                if (com.lastWas(w.UIA_E_TIMEOUT)) {
                    partial.* = true;
                    return;
                }
                continue;
            };
            const el = updated orelse continue;
            defer release(el);
            const e = &elements[p.index];
            if (p.range) {
                const value = cachedDouble(el, w.UIA_RangeValueValuePropertyId);
                const min = cachedDouble(el, w.UIA_RangeValueMinimumPropertyId);
                const max = cachedDouble(el, w.UIA_RangeValueMaximumPropertyId);
                if (value != null and min != null and max != null)
                    e.range = .{ .value = value.?, .min = min.?, .max = max.?, .read_only = cachedFlag(el, w.UIA_RangeValueIsReadOnlyPropertyId) };
            }
            if (p.scroll) {
                const sc: uitree.Scroll = .{
                    .v = scrollPercent(cachedDouble(el, w.UIA_ScrollVerticalScrollPercentPropertyId)),
                    .h = scrollPercent(cachedDouble(el, w.UIA_ScrollHorizontalScrollPercentPropertyId)),
                };
                if (sc.any()) e.scroll = sc;
            }
        }
    }

    fn extrasCache(self: *Session) com.Error!*w.IUIAutomationCacheRequest {
        if (self.extras_cache) |c| return c;
        var cache: ?*w.IUIAutomationCacheRequest = null;
        try check(self.automation.vtable.CreateCacheRequest(self.automation, &cache));
        errdefer release(cache.?);
        for ([_]w.UIA_PROPERTY_ID{
            w.UIA_RangeValueValuePropertyId,      w.UIA_RangeValueMinimumPropertyId,           w.UIA_RangeValueMaximumPropertyId,
            w.UIA_RangeValueIsReadOnlyPropertyId, w.UIA_ScrollVerticalScrollPercentPropertyId, w.UIA_ScrollHorizontalScrollPercentPropertyId,
        }) |p| try check(cache.?.vtable.AddProperty(cache.?, p));
        self.extras_cache = cache;
        return cache.?;
    }

    /// The selected text of the element with the keyboard focus, through
    /// TextPattern (US-022). Never read for a password field (FR-09).
    fn readSelection(self: *Session, arena: std.mem.Allocator, slot: *Retained, elements: []uitree.Element) void {
        _ = self;
        // The innermost element with the focus: the last one in pre-order
        // (a window may report the focus of its child too).
        var found: ?*uitree.Element = null;
        for (elements) |*e| if (e.states.focused) {
            found = e;
        };
        const focused = found orelse return;
        if (focused.password) return;
        const el = slot.find(focused.key) orelse return;
        var raw: ?*anyopaque = null;
        // Cached with the subtree; a Win32 proxy serves it live only.
        if (el.vtable.GetCachedPatternAs(el, w.UIA_TextPatternId, &w.IUIAutomationTextPattern.iid, &raw) < 0 or raw == null)
            if (el.vtable.GetCurrentPatternAs(el, w.UIA_TextPatternId, &w.IUIAutomationTextPattern.iid, &raw) < 0) return;
        const tp: *w.IUIAutomationTextPattern = @ptrCast(@alignCast(raw orelse return));
        defer release(tp);
        var ranges: ?*w.IUIAutomationTextRangeArray = null;
        if (tp.vtable.GetSelection(tp, &ranges) < 0) return;
        const arr = ranges orelse return;
        defer release(arr);
        var len: i32 = 0;
        if (arr.vtable.get_Length(arr, &len) < 0 or len == 0) return;
        var range: ?*w.IUIAutomationTextRange = null;
        if (arr.vtable.GetElement(arr, 0, &range) < 0) return;
        const r = range orelse return;
        defer release(r);
        var text: w.BSTR = null;
        // One unit more than shown, so the formatter marks a cut.
        if (r.vtable.GetText(r, uitree.max_selection_chars + 1, &text) < 0) return;
        defer w.SysFreeString(text);
        const sel = bstrText(arena, text, uitree.max_selection_chars + 1) catch return;
        if (sel.len > 0) focused.selection = sel;
    }

    const ReadError = error{ ElementNotAvailable, Timeout, ComCallFailed };

    fn classify(err: com.Error) ReadError {
        if (err == error.ElementNotAvailable) return error.ElementNotAvailable;
        if (com.lastWas(w.UIA_E_TIMEOUT)) return error.Timeout;
        return error.ComCallFailed;
    }

    /// The window element with its control-view subtree cached, in one
    /// round trip. When the provider times out, the window element alone
    /// (a partial tree).
    fn readRoot(self: *Session, hwnd: w.HWND, partial: *bool) ReadError!*w.IUIAutomationElement {
        return self.readRootWith(hwnd, self.subtree, partial);
    }

    fn readRootWith(self: *Session, hwnd: w.HWND, cache: *w.IUIAutomationCacheRequest, partial: *bool) ReadError!*w.IUIAutomationElement {
        var live: ?*w.IUIAutomationElement = null;
        check(self.automation.vtable.ElementFromHandle(self.automation, hwnd, &live)) catch |e| return classify(e);
        const el = live orelse return error.ElementNotAvailable;
        defer release(el);
        var arr: ?*w.IUIAutomationElementArray = null;
        check(el.vtable.FindAllBuildCache(el, w.TreeScope_Element, self.control_view, cache, &arr)) catch |e| {
            const c = classify(e);
            if (c != error.Timeout) return c;
            partial.* = true;
            // The window element alone, from a cache of its own properties.
            var root: ?*w.IUIAutomationElement = null;
            check(el.vtable.BuildUpdatedCache(el, self.elementCache() catch return error.Timeout, &root)) catch return error.Timeout;
            return root orelse error.Timeout;
        };
        const array = arr orelse return error.ElementNotAvailable;
        defer release(array);
        var len: i32 = 0;
        check(array.vtable.get_Length(array, &len)) catch |e| return classify(e);
        if (len == 0) {
            // The window is outside the control view: cache from it directly.
            var root: ?*w.IUIAutomationElement = null;
            check(self.automation.vtable.ElementFromHandleBuildCache(self.automation, hwnd, cache, &root)) catch |e| return classify(e);
            return root orelse error.ElementNotAvailable;
        }
        var root: ?*w.IUIAutomationElement = null;
        check(array.vtable.GetElement(array, 0, &root)) catch |e| return classify(e);
        return root.?;
    }

    /// Rectangles of the on-screen IsPassword elements of the foreground
    /// window, in one cached round trip under the provider timeout. A
    /// failure masks nothing and is reported on stderr.
    fn secrets(self: *Session, out: []display.Rect) usize {
        const t = target(null);
        if (t.desktop or t.hwnd == null or w.IsWindow(t.hwnd) == 0 or !responsive(t.hwnd)) return 0;
        // Chromium builds its web tree only after the first UIA request
        // (webPending): until the document element shows up, a page's
        // password fields are on screen but not in the tree. The scan waits
        // for it, then masks the whole window if it never comes.
        const chromium = isChromium(t.hwnd);
        var waited: u32 = 0;
        while (true) {
            const found = self.findSecrets(t.hwnd, out) catch |err| {
                std.debug.print("neo-compute: password field scan of 0x{x} failed ({t}, hr=0x{x}): screenshot not masked\n", .{ @intFromPtr(t.hwnd), err, com.lastHr() });
                return 0;
            };
            if (!chromium or found.document) return found.n;
            if (waited >= web_wait_ms) {
                var r: w.RECT = undefined;
                if (out.len == 0 or w.GetWindowRect(t.hwnd, &r) == 0) return found.n;
                std.debug.print("neo-compute: web tree of 0x{x} not ready after {d} ms: whole window masked\n", .{ @intFromPtr(t.hwnd), web_wait_ms });
                out[0] = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
                return 1;
            }
            w.Sleep(web_poll_ms);
            waited += web_poll_ms;
        }
    }

    /// Bound and step of the wait for a Chromium web tree. Measured on a
    /// fresh Chrome: the document arrives 10 to 30 ms after the first request.
    const web_wait_ms = 300;
    const web_poll_ms = 10;

    const Found = struct { n: usize, document: bool };

    fn findSecrets(self: *Session, hwnd: w.HWND, out: []display.Rect) com.Error!Found {
        if (self.password_condition == null) {
            var v: w.VARIANT = std.mem.zeroes(w.VARIANT);
            v.Anonymous.Anonymous.vt = w.VT_BOOL;
            v.Anonymous.Anonymous.Anonymous.boolVal = -1; // VARIANT_TRUE
            var is_password: ?*w.IUIAutomationCondition = null;
            try check(self.automation.vtable.CreatePropertyCondition(self.automation, w.UIA_IsPasswordPropertyId, v, &is_password));
            defer release(is_password.?);
            // Documents too, in the same round trip: their presence says a
            // Chromium web tree is built.
            var d: w.VARIANT = std.mem.zeroes(w.VARIANT);
            d.Anonymous.Anonymous.vt = w.VT_I4;
            d.Anonymous.Anonymous.Anonymous.lVal = w.UIA_DocumentControlTypeId;
            var is_document: ?*w.IUIAutomationCondition = null;
            try check(self.automation.vtable.CreatePropertyCondition(self.automation, w.UIA_ControlTypePropertyId, d, &is_document));
            defer release(is_document.?);
            var either: ?*w.IUIAutomationCondition = null;
            try check(self.automation.vtable.CreateOrCondition(self.automation, is_password, is_document, &either));
            defer release(either.?);
            // Within the control view, as ui_tree: a password field is a
            // control, and the raw view of a web page is far larger.
            var cond: ?*w.IUIAutomationCondition = null;
            try check(self.automation.vtable.CreateAndCondition(self.automation, self.control_view, either, &cond));
            self.password_condition = cond;
        }
        if (self.secret_cache == null) {
            var cache: ?*w.IUIAutomationCacheRequest = null;
            try check(self.automation.vtable.CreateCacheRequest(self.automation, &cache));
            errdefer release(cache.?);
            try check(cache.?.vtable.AddProperty(cache.?, w.UIA_BoundingRectanglePropertyId));
            try check(cache.?.vtable.AddProperty(cache.?, w.UIA_IsOffscreenPropertyId));
            try check(cache.?.vtable.AddProperty(cache.?, w.UIA_ControlTypePropertyId));
            self.secret_cache = cache;
        }
        var live: ?*w.IUIAutomationElement = null;
        try check(self.automation.vtable.ElementFromHandle(self.automation, hwnd, &live));
        const el = live orelse return .{ .n = 0, .document = false };
        defer release(el);
        var arr: ?*w.IUIAutomationElementArray = null;
        try check(el.vtable.FindAllBuildCache(el, w.TreeScope_Subtree, self.password_condition, self.secret_cache, &arr));
        const array = arr orelse return .{ .n = 0, .document = false };
        defer release(array);
        var len: i32 = 0;
        try check(array.vtable.get_Length(array, &len));
        var n: usize = 0;
        var document = false;
        var i: i32 = 0;
        while (i < len) : (i += 1) {
            var item: ?*w.IUIAutomationElement = null;
            if (array.vtable.GetElement(array, i, &item) < 0) continue;
            const e = item orelse continue;
            defer release(e);
            var control_type: w.UIA_CONTROLTYPE_ID = 0;
            if (e.vtable.get_CachedControlType(e, &control_type) >= 0 and control_type == w.UIA_DocumentControlTypeId) {
                document = true;
                continue;
            }
            if (n == out.len or cachedBool(e, "get_CachedIsOffscreen")) continue;
            var r: w.RECT = undefined;
            if (e.vtable.get_CachedBoundingRectangle(e, &r) < 0 or r.right <= r.left or r.bottom <= r.top) continue;
            out[n] = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
            n += 1;
        }
        return .{ .n = n, .document = document };
    }

    fn elementCache(self: *Session) com.Error!*w.IUIAutomationCacheRequest {
        if (self.element_cache) |c| return c;
        var cache: ?*w.IUIAutomationCacheRequest = null;
        try check(self.automation.vtable.CreateCacheRequest(self.automation, &cache));
        errdefer release(cache.?);
        for (properties) |p| try check(cache.?.vtable.AddProperty(cache.?, p));
        self.element_cache = cache;
        return cache.?;
    }

    fn slotFor(self: *Session, window: u64) *Retained {
        var slot = &self.retained[0];
        for (&self.retained) |*r| {
            if (r.used != 0 and r.hwnd == window) {
                slot = r;
                break;
            }
            if (r.used < slot.used) slot = r;
        }
        slot.clear();
        self.clock += 1;
        slot.hwnd = window;
        slot.used = self.clock;
        return slot;
    }

    /// Pre-order walk of the cached subtree. Element references move into
    /// `slot`; `root` stays owned by the caller. Elements with a cached
    /// RangeValue or Scroll pattern are listed in `positioned`.
    fn walk(self: *Session, arena: std.mem.Allocator, root: *w.IUIAutomationElement, slot: *Retained, out: *std.ArrayList(uitree.Element), positioned: *std.ArrayList(Positioned), seen: *std.AutoHashMapUnmanaged(u64, void)) !void {
        const Item = struct { el: *w.IUIAutomationElement, depth: u16 };
        var stack: std.ArrayList(Item) = .empty;
        _ = root.vtable.AddRef(root);
        try stack.append(arena, .{ .el = root, .depth = 0 });
        while (stack.pop()) |item| {
            if (out.items.len >= uitree.max_elements) {
                release(item.el);
                continue;
            }
            const e = read(arena, item.el, item.depth, self.name_units) catch {
                release(item.el);
                continue;
            };
            // Read already under another root: skipped with its subtree.
            if ((try seen.getOrPut(arena, e.key)).found_existing) {
                release(item.el);
                continue;
            }
            try out.append(arena, e);
            slot.elements.append(self.gpa, item.el) catch {
                release(item.el);
                continue;
            };
            slot.keys.append(self.gpa, e.key) catch {
                _ = slot.elements.pop();
                release(item.el);
                continue;
            };
            if (positioned.items.len < max_positioned) {
                const range = hasCachedPattern(item.el, w.UIA_RangeValuePatternId);
                const scroll = hasCachedPattern(item.el, w.UIA_ScrollPatternId);
                if (range or scroll) try positioned.append(arena, .{ .index = @intCast(out.items.len - 1), .el = item.el, .range = range, .scroll = scroll });
            }
            var children: ?*w.IUIAutomationElementArray = null;
            if (item.el.vtable.GetCachedChildren(item.el, &children) < 0) continue;
            const arr = children orelse continue;
            defer release(arr);
            var len: i32 = 0;
            if (arr.vtable.get_Length(arr, &len) < 0) continue;
            var i = len;
            while (i > 0) {
                i -= 1;
                var child: ?*w.IUIAutomationElement = null;
                if (arr.vtable.GetElement(arr, i, &child) < 0 or child == null) continue;
                try stack.append(arena, .{ .el = child.?, .depth = item.depth +| 1 });
            }
        }
    }

    fn act(self: *Session, arena: std.mem.Allocator, window: u64, key: u64, action: uitree.Action, value: ?[]const u8) uitree.ActResult {
        const hwnd: w.HWND = @ptrFromInt(window);
        if (w.IsWindow(hwnd) == 0) return .gone;
        // Acting with the focus side effect the background mode excludes is
        // never a fallback.
        if (!self.background and !auto_set_focus.load(.monotonic)) return .{ .failed = no_auto_focus_message };
        if (!responsive(hwnd)) return .{ .failed = hung_message };
        const el = self.find(window, key) orelse blk: {
            // Not in a retained snapshot (evicted): read the window again.
            if (self.snapshot(arena, window, .{}) == .err) return .gone;
            break :blk self.find(window, key) orelse return .gone;
        };
        // MSAA elements (US-025): Firefox refuses accValue writes.
        const msaa = self.msaaWindow(window);
        if (msaa and action == .set_value) return .{ .failed = msaa_set_value_message };
        var enabled: w.BOOL = 0;
        check(el.vtable.get_CurrentIsEnabled(el, &enabled)) catch |e| return actError(arena, e);
        if (enabled == 0) return .disabled;
        if (action != .scroll_into_view) {
            var off: w.BOOL = 0;
            check(el.vtable.get_CurrentIsOffscreen(el, &off)) catch |e| return actError(arena, e);
            if (off != 0) return .offscreen;
        }
        var r: w.RECT = undefined;
        check(el.vtable.get_CurrentBoundingRectangle(el, &r)) catch |e| return actError(arena, e);
        const rect: display.Rect = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
        const hr = switch (action) {
            .focus => blk: {
                _ = set_focus_calls.fetchAdd(1, .monotonic);
                break :blk el.vtable.SetFocus(el);
            },
            // Through the MSAA proxy, the element's default action is
            // accDoDefaultAction (US-025).
            .invoke => if (msaa)
                call(el, w.IUIAutomationLegacyIAccessiblePattern, w.UIA_LegacyIAccessiblePatternId, "DoDefaultAction", .{})
            else
                call(el, w.IUIAutomationInvokePattern, w.UIA_InvokePatternId, "Invoke", .{}),
            .toggle => call(el, w.IUIAutomationTogglePattern, w.UIA_TogglePatternId, "Toggle", .{}),
            .select => call(el, w.IUIAutomationSelectionItemPattern, w.UIA_SelectionItemPatternId, "Select", .{}),
            .expand => call(el, w.IUIAutomationExpandCollapsePattern, w.UIA_ExpandCollapsePatternId, "Expand", .{}),
            .collapse => call(el, w.IUIAutomationExpandCollapsePattern, w.UIA_ExpandCollapsePatternId, "Collapse", .{}),
            .scroll_into_view => call(el, w.IUIAutomationScrollItemPattern, w.UIA_ScrollItemPatternId, "ScrollIntoView", .{}),
            .set_value => setValue(arena, el, value orelse ""),
        } orelse return .{ .unsupported = rect };
        if (hr == read_only_hr) return .read_only;
        if (hr >= 0) return .ok;
        if (@as(u32, @bitCast(hr)) == w.UIA_E_TIMEOUT) return .timeout;
        if (@as(u32, @bitCast(hr)) == w.UIA_E_ELEMENTNOTAVAILABLE) return .gone;
        com.last_hr = hr;
        return .{ .failed = fail(arena, "action") };
    }

    fn find(self: *Session, window: u64, key: u64) ?*w.IUIAutomationElement {
        for (&self.retained) |*r| if (r.used != 0 and r.hwnd == window) {
            for (r.keys.items, 0..) |k, i| if (k == key) return r.elements.items[i];
        };
        for (&self.retained) |*r| if (r.used != 0) {
            for (r.keys.items, 0..) |k, i| if (k == key) return r.elements.items[i];
        };
        return null;
    }
};

fn named(name: []const u8) bool {
    return std.mem.trim(u8, name, " \t").len > 0;
}

/// An element whose position is read after the walk; `el` is owned by the
/// retained slot.
const Positioned = struct { index: u32, el: *w.IUIAutomationElement, range: bool, scroll: bool };

fn hasCachedPattern(el: *w.IUIAutomationElement, id: w.UIA_PATTERN_ID) bool {
    var unk: ?*w.IUnknown = null;
    if (el.vtable.GetCachedPattern(el, id, &unk) < 0) return false;
    const u = unk orelse return false;
    release(u);
    return true;
}

/// Sentinel HRESULT for a read-only Value pattern (never returned by UIA).
const read_only_hr: w.HRESULT = @bitCast(@as(u32, 0xA0000001));

/// Calls `method` of pattern `P` on `el`; null when the pattern is missing.
fn call(el: *w.IUIAutomationElement, comptime P: type, id: w.UIA_PATTERN_ID, comptime method: []const u8, args: anytype) ?w.HRESULT {
    var raw: ?*anyopaque = null;
    if (el.vtable.GetCurrentPatternAs(el, id, &P.iid, &raw) < 0) return null;
    const p: *P = @ptrCast(@alignCast(raw orelse return null));
    defer release(p);
    return @call(.auto, @field(p.vtable, method), .{p} ++ args);
}

/// ValuePattern.SetValue, refused before the call on a read-only element.
/// The value is never logged (FR-09).
fn setValue(arena: std.mem.Allocator, el: *w.IUIAutomationElement, value: []const u8) ?w.HRESULT {
    var raw: ?*anyopaque = null;
    if (el.vtable.GetCurrentPatternAs(el, w.UIA_ValuePatternId, &w.IUIAutomationValuePattern.iid, &raw) < 0) return null;
    const p: *w.IUIAutomationValuePattern = @ptrCast(@alignCast(raw orelse return null));
    defer release(p);
    var ro: w.BOOL = 0;
    if (p.vtable.get_CurrentIsReadOnly(p, &ro) >= 0 and ro != 0) return read_only_hr;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(arena, value) catch return @bitCast(@as(u32, 0x8007000E));
    const bstr = w.SysAllocString(wide.ptr);
    defer w.SysFreeString(bstr);
    @memset(wide, 0);
    return p.vtable.SetValue(p, bstr);
}

fn actError(arena: std.mem.Allocator, err: com.Error) uitree.ActResult {
    if (err == error.ElementNotAvailable) return .gone;
    return .{ .failed = fail(arena, "vérification des préconditions") };
}

fn fail(arena: std.mem.Allocator, what: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "UI Automation a échoué ({s}, hr=0x{x}) : réessaie, ou utilise screenshot et les coordonnées.", .{ what, com.lastHr() }) catch "UI Automation a échoué : réessaie.";
}

/// UTF-8 of at most `max` UTF-16 units of `wide`, lone surrogates replaced.
fn utf8(arena: std.mem.Allocator, wide: []const u16, max: usize) ![]const u8 {
    const src = wide[0..@min(wide.len, max)];
    var out: std.ArrayList(u8) = try .initCapacity(arena, src.len * 3);
    var it = std.unicode.Utf16LeIterator.init(src);
    while (true) {
        const cp = it.nextCodepoint() catch {
            out.appendSliceAssumeCapacity("\u{FFFD}");
            continue;
        } orelse break;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        out.appendSliceAssumeCapacity(buf[0..n]);
    }
    return out.items;
}

fn bstrText(arena: std.mem.Allocator, b: w.BSTR, max: usize) ![]const u8 {
    const p = b orelse return "";
    return utf8(arena, p[0..w.SysStringLen(b)], max);
}

fn cachedVariant(el: *w.IUIAutomationElement, id: w.UIA_PROPERTY_ID) ?w.VARIANT {
    var v: w.VARIANT = std.mem.zeroes(w.VARIANT);
    if (el.vtable.GetCachedPropertyValue(el, id, &v) < 0) return null;
    return v;
}

fn vt(v: *const w.VARIANT) w.VARENUM {
    return v.Anonymous.Anonymous.vt;
}

/// Hash of the element's RuntimeId (an array of ints).
fn runtimeKey(el: *w.IUIAutomationElement) ?u64 {
    var v = cachedVariant(el, w.UIA_RuntimeIdPropertyId) orelse return null;
    defer _ = w.VariantClear(&v);
    if (vt(&v) != w.VT_ARRAY | w.VT_I4) return null;
    const sa = v.Anonymous.Anonymous.Anonymous.parray orelse return null;
    var upper: i32 = -1;
    if (w.SafeArrayGetUBound(sa, 1, &upper) < 0 or upper < 0) return null;
    var data: ?*anyopaque = null;
    if (w.SafeArrayAccessData(sa, &data) < 0) return null;
    defer _ = w.SafeArrayUnaccessData(sa);
    const ints: [*]const i32 = @ptrCast(@alignCast(data.?));
    return std.hash.Wyhash.hash(0x6e656f, std.mem.sliceAsBytes(ints[0..@intCast(upper + 1)]));
}

fn cachedBool(el: *w.IUIAutomationElement, comptime getter: []const u8) bool {
    var b: w.BOOL = 0;
    if (@field(el.vtable, getter)(el, &b) < 0) return false;
    return b != 0;
}

fn cachedDouble(el: *w.IUIAutomationElement, id: w.UIA_PROPERTY_ID) ?f64 {
    var v = cachedVariant(el, id) orelse return null;
    defer _ = w.VariantClear(&v);
    return if (vt(&v) == w.VT_R8) v.Anonymous.Anonymous.Anonymous.dblVal else null;
}

fn cachedFlag(el: *w.IUIAutomationElement, id: w.UIA_PROPERTY_ID) bool {
    var v = cachedVariant(el, id) orelse return false;
    defer _ = w.VariantClear(&v);
    return vt(&v) == w.VT_BOOL and v.Anonymous.Anonymous.Anonymous.boolVal != 0;
}

/// A scroll percentage; UIA_ScrollPatternNoScroll (-1) means the axis does
/// not scroll.
fn scrollPercent(p: ?f64) ?f32 {
    const x = p orelse return null;
    if (x == w.UIA_ScrollPatternNoScroll or x < 0 or !std.math.isFinite(x)) return null;
    return @floatCast(@min(x, 100));
}

fn qpc() i64 {
    var t: i64 = 0;
    _ = w.QueryPerformanceCounter(&t);
    return t;
}

fn qpcNs(ticks: i64) u64 {
    var f: i64 = 0;
    _ = w.QueryPerformanceFrequency(&f);
    if (f <= 0 or ticks <= 0) return 0;
    return @intCast(@divTrunc(@as(i128, ticks) * std.time.ns_per_s, f));
}

fn cachedInt(el: *w.IUIAutomationElement, id: w.UIA_PROPERTY_ID) ?i32 {
    var v = cachedVariant(el, id) orelse return null;
    defer _ = w.VariantClear(&v);
    return if (vt(&v) == w.VT_I4) v.Anonymous.Anonymous.Anonymous.lVal else null;
}

/// One element from its cached properties and patterns.
fn read(arena: std.mem.Allocator, el: *w.IUIAutomationElement, depth: u16, name_units: usize) !uitree.Element {
    var name: w.BSTR = null;
    try check(el.vtable.get_CachedName(el, &name));
    defer w.SysFreeString(name);
    var control_type: w.UIA_CONTROLTYPE_ID = 0;
    try check(el.vtable.get_CachedControlType(el, &control_type));
    var r: w.RECT = undefined;
    try check(el.vtable.get_CachedBoundingRectangle(el, &r));
    const password = cachedBool(el, "get_CachedIsPassword");
    var e: uitree.Element = .{
        .key = runtimeKey(el) orelse @intFromPtr(el),
        .depth = depth,
        .role = role(control_type),
        .name = try bstrText(arena, name, name_units),
        .password = password,
        .rect = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top },
    };
    e.states.offscreen = cachedBool(el, "get_CachedIsOffscreen");
    e.states.disabled = !cachedBool(el, "get_CachedIsEnabled");
    e.states.focused = cachedBool(el, "get_CachedHasKeyboardFocus");
    inline for (patterns) |p| {
        var unk: ?*w.IUnknown = null;
        if (el.vtable.GetCachedPattern(el, p.id, &unk) >= 0) if (unk) |u| {
            @field(e.actions, p.field) = true;
            release(u);
        };
    }
    // Pattern properties of an element without the pattern hold their
    // defaults (ToggleState Indeterminate, Value ""): read them only with
    // the pattern.
    // FR-09: a password's value is never read into memory we own.
    if (e.actions.value and !password) if (cachedVariant(el, w.UIA_ValueValuePropertyId)) |v0| {
        var v = v0;
        defer _ = w.VariantClear(&v);
        if (vt(&v) == w.VT_BSTR) e.value = try bstrText(arena, v.Anonymous.Anonymous.Anonymous.bstrVal, max_value_units);
    };
    if (e.actions.toggle) if (cachedInt(el, w.UIA_ToggleToggleStatePropertyId)) |s| {
        e.states.checked = s == w.ToggleState_On;
        e.states.mixed = s == w.ToggleState_Indeterminate;
    };
    if (e.actions.expand_collapse) if (cachedInt(el, w.UIA_ExpandCollapseExpandCollapseStatePropertyId)) |s| {
        e.states.collapsed = s == w.ExpandCollapseState_Collapsed;
        e.states.expanded = s == w.ExpandCollapseState_Expanded or s == w.ExpandCollapseState_PartiallyExpanded;
    };
    if (e.actions.select) if (cachedVariant(el, w.UIA_SelectionItemIsSelectedPropertyId)) |v0| {
        var v = v0;
        defer _ = w.VariantClear(&v);
        e.states.selected = vt(&v) == w.VT_BOOL and v.Anonymous.Anonymous.Anonymous.boolVal != 0;
    };
    return e;
}

fn role(id: w.UIA_CONTROLTYPE_ID) uitree.Role {
    return switch (id) {
        w.UIA_ButtonControlTypeId => .button,
        w.UIA_CalendarControlTypeId => .calendar,
        w.UIA_CheckBoxControlTypeId => .checkbox,
        w.UIA_ComboBoxControlTypeId => .combobox,
        w.UIA_EditControlTypeId => .edit,
        w.UIA_HyperlinkControlTypeId => .link,
        w.UIA_ImageControlTypeId => .image,
        w.UIA_ListItemControlTypeId => .listitem,
        w.UIA_ListControlTypeId => .list,
        w.UIA_MenuControlTypeId => .menu,
        w.UIA_MenuBarControlTypeId => .menubar,
        w.UIA_MenuItemControlTypeId => .menuitem,
        w.UIA_ProgressBarControlTypeId => .progressbar,
        w.UIA_RadioButtonControlTypeId => .radio,
        w.UIA_ScrollBarControlTypeId => .scrollbar,
        w.UIA_SliderControlTypeId => .slider,
        w.UIA_SpinnerControlTypeId => .spinner,
        w.UIA_StatusBarControlTypeId => .statusbar,
        w.UIA_TabControlTypeId => .tab,
        w.UIA_TabItemControlTypeId => .tabitem,
        w.UIA_TextControlTypeId => .text,
        w.UIA_ToolBarControlTypeId => .toolbar,
        w.UIA_ToolTipControlTypeId => .tooltip,
        w.UIA_TreeControlTypeId => .tree,
        w.UIA_TreeItemControlTypeId => .treeitem,
        w.UIA_CustomControlTypeId => .custom,
        w.UIA_GroupControlTypeId => .group,
        w.UIA_ThumbControlTypeId => .thumb,
        w.UIA_DataGridControlTypeId => .datagrid,
        w.UIA_DataItemControlTypeId => .dataitem,
        w.UIA_DocumentControlTypeId => .document,
        w.UIA_SplitButtonControlTypeId => .splitbutton,
        w.UIA_WindowControlTypeId => .window,
        w.UIA_PaneControlTypeId => .pane,
        w.UIA_HeaderControlTypeId => .header,
        w.UIA_HeaderItemControlTypeId => .headeritem,
        w.UIA_TableControlTypeId => .table,
        w.UIA_TitleBarControlTypeId => .titlebar,
        w.UIA_SeparatorControlTypeId => .separator,
        w.UIA_SemanticZoomControlTypeId => .semanticzoom,
        w.UIA_AppBarControlTypeId => .appbar,
        else => .unknown,
    };
}
