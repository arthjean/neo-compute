//! UI Automation on one dedicated worker thread without windows, in the
//! multithreaded apartment (US-011). Every UIA object is created, used and
//! released on that thread; the dispatcher hands it one job at a time and
//! waits. A snapshot reads a window's whole control-view subtree in one
//! cached round trip (FindAllBuildCache with at most 12 properties and the
//! actionable patterns) under a 200 ms provider timeout (IUIAutomation2), and
//! keeps the element references so ui_act reaches an element directly.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const uitree = @import("../../core/uitree.zig");
const display = @import("../../core/display.zig");
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

const patterns = [_]struct { id: w.UIA_PATTERN_ID, field: []const u8 }{
    .{ .id = w.UIA_InvokePatternId, .field = "invoke" },
    .{ .id = w.UIA_ValuePatternId, .field = "value" },
    .{ .id = w.UIA_TogglePatternId, .field = "toggle" },
    .{ .id = w.UIA_ExpandCollapsePatternId, .field = "expand_collapse" },
    .{ .id = w.UIA_SelectionItemPatternId, .field = "select" },
    .{ .id = w.UIA_ScrollItemPatternId, .field = "scroll" },
};

/// Name and value lengths read from providers, in UTF-16 units: a document
/// can expose its whole text as a name.
const max_name_units = 256;
const max_value_units = 256;

pub const closed_message = "Fenêtre fermée : rappelle window_list";
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
    snapshot: struct { arena: std.mem.Allocator, hwnd: ?u64, out: uitree.SnapshotResult = undefined },
    act: struct { arena: std.mem.Allocator, window: u64, key: u64, action: uitree.Action, value: ?[]const u8, out: uitree.ActResult = undefined },
    quit,
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    wake: w.HANDLE = null,
    done: w.HANDLE = null,
    job: Job = .quit,
    /// Why the worker could not start UI Automation, if it failed.
    init_error: ?[]const u8 = null,

    pub fn snapshot(self: *Worker, arena: std.mem.Allocator, hwnd: ?u64) uitree.SnapshotResult {
        if (self.start()) |msg| return .{ .err = msg };
        self.job = .{ .snapshot = .{ .arena = arena, .hwnd = hwnd } };
        self.run();
        return self.job.snapshot.out;
    }

    pub fn act(self: *Worker, arena: std.mem.Allocator, window: u64, key: u64, action: uitree.Action, value: ?[]const u8) uitree.ActResult {
        if (self.start()) |msg| return .{ .failed = msg };
        self.job = .{ .act = .{ .arena = arena, .window = window, .key = key, .action = action, .value = value } };
        self.run();
        return self.job.act.out;
    }

    pub fn deinit(self: *Worker) void {
        const t = self.thread orelse return;
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
        _ = w.SetEvent(self.wake);
        _ = w.WaitForSingleObject(self.done, w.INFINITE);
    }

    fn loop(self: *Worker) void {
        var session: ?Session = null;
        const com_ok = if (com.check(w.CoInitializeEx(null, @bitCast(w.COINIT_MULTITHREADED)))) true else |_| false;
        if (com_ok) {
            session = Session.init(self.gpa) catch |err| blk: {
                std.debug.print("neo-compute: UI Automation init failed: {t} hr=0x{x}\n", .{ err, com.lastHr() });
                self.init_error = "UI Automation indisponible (CUIAutomation) : détail sur stderr, utilise screenshot.";
                break :blk null;
            };
        } else self.init_error = "UI Automation indisponible : COM refuse le mode MTA, utilise screenshot.";
        _ = w.SetEvent(self.done);
        while (true) {
            _ = w.WaitForSingleObject(self.wake, w.INFINITE);
            switch (self.job) {
                .quit => break,
                .snapshot => |*j| j.out = session.?.snapshot(j.arena, j.hwnd),
                .act => |*j| j.out = session.?.act(j.arena, j.window, j.key, j.action, j.value),
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

    fn clear(self: *Retained) void {
        for (self.elements.items) |el| release(el);
        self.elements.clearRetainingCapacity();
        self.keys.clearRetainingCapacity();
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
    subtree: *w.IUIAutomationCacheRequest,
    control_view: *w.IUIAutomationCondition,
    /// The window element's own properties, for a partial tree.
    element_cache: ?*w.IUIAutomationCacheRequest = null,
    retained: [4]Retained = @splat(.{}),
    clock: u64 = 0,

    fn init(gpa: std.mem.Allocator) com.Error!Session {
        var raw: ?*anyopaque = null;
        try check(w.CoCreateInstance(&w.CLSID_CUIAutomation, null, w.CLSCTX_INPROC_SERVER, &w.IUIAutomation.iid, &raw));
        const automation: *w.IUIAutomation = @ptrCast(@alignCast(raw.?));
        errdefer release(automation);
        // Bounded waits on providers (Windows 8+).
        var raw2: ?*anyopaque = null;
        if (automation.vtable.QueryInterface(automation, &w.IUIAutomation2.iid, &raw2) >= 0) {
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
        try check(cache.?.vtable.put_TreeScope(cache.?, w.TreeScope_Subtree));
        try check(cache.?.vtable.put_TreeFilter(cache.?, cond.?));
        return .{ .gpa = gpa, .automation = automation, .subtree = cache.?, .control_view = cond.? };
    }

    fn deinit(self: *Session) void {
        for (&self.retained) |*r| r.deinit(self.gpa);
        if (self.element_cache) |c| release(c);
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
    fn webPending(hwnd: w.HWND, elements: []const uitree.Element) bool {
        if (!isChromium(hwnd)) return false;
        for (elements) |e| if (e.role == .document) return false;
        return true;
    }

    fn snapshot(self: *Session, arena: std.mem.Allocator, hwnd: ?u64) uitree.SnapshotResult {
        const t = target(hwnd);
        if (t.hwnd == null or w.IsWindow(t.hwnd) == 0) return .{ .err = if (t.desktop) "Aucune fenêtre active et barre des tâches introuvable : utilise screenshot." else closed_message };
        const window: u64 = @intFromPtr(t.hwnd);
        if (!responsive(t.hwnd)) return hungRoot(arena, t.hwnd, t.desktop);
        var partial = false;
        const root = self.readRoot(t.hwnd, &partial) catch |err| return .{ .err = switch (err) {
            error.ElementNotAvailable => closed_message,
            error.Timeout => hung_message,
            else => fail(arena, "lecture de l'arbre"),
        } };
        defer release(root);
        const slot = self.slotFor(window);
        var out: std.ArrayList(uitree.Element) = .empty;
        self.walk(arena, root, slot, &out) catch return .{ .err = "Mémoire insuffisante : réessaie." };
        return .{ .ok = .{ .window = window, .elements = out.items, .partial = partial, .desktop = t.desktop, .web_pending = webPending(t.hwnd, out.items) } };
    }

    const ReadError = error{ ElementNotAvailable, Timeout, ComCallFailed };

    fn classify(err: com.Error) ReadError {
        if (err == error.ElementNotAvailable) return error.ElementNotAvailable;
        if (com.lastHr() == w.UIA_E_TIMEOUT) return error.Timeout;
        return error.ComCallFailed;
    }

    /// The window element with its control-view subtree cached, in one
    /// round trip. When the provider times out, the window element alone
    /// (a partial tree).
    fn readRoot(self: *Session, hwnd: w.HWND, partial: *bool) ReadError!*w.IUIAutomationElement {
        var live: ?*w.IUIAutomationElement = null;
        check(self.automation.vtable.ElementFromHandle(self.automation, hwnd, &live)) catch |e| return classify(e);
        const el = live orelse return error.ElementNotAvailable;
        defer release(el);
        var arr: ?*w.IUIAutomationElementArray = null;
        check(el.vtable.FindAllBuildCache(el, w.TreeScope_Element, self.control_view, self.subtree, &arr)) catch |e| {
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
            check(self.automation.vtable.ElementFromHandleBuildCache(self.automation, hwnd, self.subtree, &root)) catch |e| return classify(e);
            return root orelse error.ElementNotAvailable;
        }
        var root: ?*w.IUIAutomationElement = null;
        check(array.vtable.GetElement(array, 0, &root)) catch |e| return classify(e);
        return root.?;
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
    /// `slot`; `root` stays owned by the caller.
    fn walk(self: *Session, arena: std.mem.Allocator, root: *w.IUIAutomationElement, slot: *Retained, out: *std.ArrayList(uitree.Element)) !void {
        const Item = struct { el: *w.IUIAutomationElement, depth: u16 };
        var stack: std.ArrayList(Item) = .empty;
        _ = root.vtable.AddRef(root);
        try stack.append(arena, .{ .el = root, .depth = 0 });
        while (stack.pop()) |item| {
            if (out.items.len >= uitree.max_elements) {
                release(item.el);
                continue;
            }
            const e = read(arena, item.el, item.depth) catch {
                release(item.el);
                continue;
            };
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
        if (!responsive(hwnd)) return .{ .failed = hung_message };
        const el = self.find(window, key) orelse blk: {
            // Not in a retained snapshot (evicted): read the window again.
            if (self.snapshot(arena, window) == .err) return .gone;
            break :blk self.find(window, key) orelse return .gone;
        };
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
            .focus => el.vtable.SetFocus(el),
            .invoke => call(el, w.IUIAutomationInvokePattern, w.UIA_InvokePatternId, "Invoke", .{}),
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

fn cachedInt(el: *w.IUIAutomationElement, id: w.UIA_PROPERTY_ID) ?i32 {
    var v = cachedVariant(el, id) orelse return null;
    defer _ = w.VariantClear(&v);
    return if (vt(&v) == w.VT_I4) v.Anonymous.Anonymous.Anonymous.lVal else null;
}

/// One element from its cached properties and patterns.
fn read(arena: std.mem.Allocator, el: *w.IUIAutomationElement, depth: u16) !uitree.Element {
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
        .name = try bstrText(arena, name, max_name_units),
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
