//! In-memory backend for testing the portable core on any OS. It records
//! every input it receives and serves synthetic displays and windows.

const std = @import("std");
const display = @import("../core/display.zig");
const input = @import("../core/input.zig");
const keys = @import("../core/keys.zig");
const uitree = @import("../core/uitree.zig");
const Control = @import("../core/control.zig").Control;

pub const displays_fixture = [_]display.Display{
    .{ .rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1440 }, .name = "FAKE-1" },
    // Left of the primary display: negative desktop coordinates.
    .{ .rect = .{ .x = -1920, .y = 200, .w = 1920, .h = 1080 }, .name = "FAKE-2" },
};

var frame0: [2560 * 1440 * 4]u8 = undefined;
var frame1: [1920 * 1080 * 4]u8 = undefined;
var frames_ready = false;

fn fillFrames() void {
    if (frames_ready) return;
    for ([_][]u8{ &frame0, &frame1 }, displays_fixture) |buf, d| {
        const w: usize = @intCast(d.rect.w);
        for (0..@intCast(d.rect.h)) |y| for (0..w) |x| {
            const i = (y * w + x) * 4;
            buf[i..][0..4].* = .{ @truncate(x), @truncate(y), @truncate((x / 64 + y / 64) * 40), 255 };
        };
    }
    frames_ready = true;
}

/// Inside the fixture window, which settling watches.
const animation_rect = [_]display.Rect{.{ .x = 200, .y = 200, .w = 32, .h = 32 }};

/// Notepad-like tree on the primary display (physical pixels).
pub const ui_fixture = [_]uitree.Element{
    .{ .key = 100, .depth = 0, .role = .window, .name = "Sans titre - Bloc-notes", .rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 } },
    .{ .key = 101, .depth = 1, .role = .pane, .rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 } },
    .{ .key = 102, .depth = 2, .role = .menubar, .name = "Application", .rect = .{ .x = 100, .y = 120, .w = 1200, .h = 40 } },
    .{ .key = 103, .depth = 3, .role = .menuitem, .name = "Fichier", .states = .{ .collapsed = true }, .actions = .{ .expand_collapse = true }, .rect = .{ .x = 110, .y = 124, .w = 80, .h = 32 } },
    .{ .key = 104, .depth = 3, .role = .menuitem, .name = "Édition", .states = .{ .collapsed = true }, .actions = .{ .expand_collapse = true }, .rect = .{ .x = 200, .y = 124, .w = 80, .h = 32 } },
    .{ .key = 105, .depth = 2, .role = .edit, .name = "Éditeur de texte", .value = "Bonjour \"monde\"", .states = .{ .focused = true }, .actions = .{ .value = true }, .rect = .{ .x = 100, .y = 160, .w = 1200, .h = 680 } },
    .{ .key = 106, .depth = 2, .role = .edit, .name = "Mot de passe", .value = "hunter2", .password = true, .actions = .{ .value = true }, .rect = .{ .x = 100, .y = 840, .w = 400, .h = 30 } },
    .{ .key = 107, .depth = 2, .role = .button, .name = "Enregistrer", .actions = .{ .invoke = true }, .rect = .{ .x = 1100, .y = 840, .w = 100, .h = 30 } },
    .{ .key = 108, .depth = 2, .role = .checkbox, .name = "Retour automatique à la ligne", .states = .{ .checked = true }, .actions = .{ .toggle = true }, .rect = .{ .x = 600, .y = 840, .w = 300, .h = 30 } },
    .{ .key = 109, .depth = 2, .role = .button, .name = "Imprimer", .states = .{ .disabled = true }, .actions = .{ .invoke = true }, .rect = .{ .x = 950, .y = 840, .w = 100, .h = 30 } },
    .{ .key = 110, .depth = 2, .role = .text, .name = "Ligne 1, colonne 1", .rect = .{ .x = 100, .y = 870, .w = 200, .h = 10 } },
    .{ .key = 111, .depth = 2, .role = .listitem, .name = "Hors champ", .states = .{ .offscreen = true }, .actions = .{ .select = true, .scroll = true }, .rect = .{ .x = 100, .y = 5000, .w = 200, .h = 20 } },
};

pub const KeyCall = struct { combo: keys.Combo, action: input.KeyAction };

/// A root served with the foreground tree: its window and its elements
/// (the first at depth 0).
pub const ExtraRoot = struct { window: uitree.RootWindow, modal: bool = false, elements: []const uitree.Element };

pub const Fake = struct {
    /// Inputs currently held (keys or buttons), as a count.
    held: u32 = 0,
    release_calls: u32 = 0,

    displays_len: usize = displays_fixture.len,
    foreground: ?usize = 0,
    capture_calls: u32 = 0,
    capture_failure: ?[]const u8 = null,
    cursor: [2]i32 = .{ 100, 100 },
    elevated: bool = false,
    /// A single physical point over an elevated window.
    elevated_at: ?[2]i32 = null,
    /// A character the fake layout cannot map.
    unmappable: ?u21 = null,

    mouse: [256]input.MouseEvent = undefined,
    mouse_len: usize = 0,
    key_calls: [256]KeyCall = undefined,
    key_len: usize = 0,
    typed: [4096]u16 = undefined,
    typed_len: usize = 0,
    type_calls: u32 = 0,
    largest_type_batch: usize = 0,
    focused: ?u64 = null,
    /// Every capture reports a dirty rect, like a video or a spinner.
    animating: bool = false,

    /// Accessibility tree served by uiSnapshot; tests replace it.
    ui_window: u64 = 0x1a2b,
    ui_elements: []const uitree.Element = &ui_fixture,
    ui_partial: bool = false,
    ui_desktop: bool = false,
    ui_web_pending: bool = false,
    /// A Firefox window with its accessibility off (US-025).
    ui_firefox_no_tree: bool = false,
    /// The foreground root is modal (US-023).
    ui_modal: bool = false,
    /// Served in place of `ui_elements` when the text of a web page is
    /// requested (US-024); null: the window has no web document.
    ui_web: ?[]const uitree.Element = null,
    ui_page: ?uitree.Page = null,
    /// Menus, popups and owned windows listed with the foreground window
    /// (US-023); tests set them.
    ui_extra: []const ExtraRoot = &.{},
    /// Extra roots requested by the last snapshot.
    ui_requested: usize = 0,
    ui_snapshots: u32 = 0,
    /// Last element action received.
    ui_last_act: ?struct { key: u64, action: uitree.Action, value_len: usize } = null,

    /// Top-level windows, top of the z-order first; tests replace them.
    windows: []const display.WindowInfo = &windows_fixture,
    /// Executable name lookups (the policy caches them per window).
    process_lookups: u32 = 0,
    /// Password scans started by screenshot and zoom (US-019).
    secret_scans: u32 = 0,
    secret_buf: [16]display.Rect = undefined,
    /// Kill switch state handed over by the server (US-018).
    control: ?*Control = null,
    /// Trips the kill switch on the next key press, as a physical Escape
    /// during the action would.
    trip_on_press: bool = false,

    pub fn releaseAllInputs(self: *Fake) void {
        self.held = 0;
        self.release_calls += 1;
    }

    pub fn displays(self: *Fake) []const display.Display {
        return displays_fixture[0..self.displays_len];
    }

    pub fn foregroundDisplay(self: *Fake) ?usize {
        return self.foreground;
    }

    pub fn capture(self: *Fake, index: usize, arena: std.mem.Allocator) display.CaptureResult {
        _ = arena;
        if (self.capture_failure) |msg| return .{ .failed = msg };
        fillFrames();
        const d = displays_fixture[index];
        const buf: []const u8 = if (index == 0) &frame0 else &frame1;
        self.capture_calls += 1;
        return .{ .frame = .{
            .pixels = buf,
            .width = @intCast(d.rect.w),
            .height = @intCast(d.rect.h),
            .stride = @as(usize, @intCast(d.rect.w)) * 4,
            .fresh = self.capture_calls == 1 or self.animating,
            .dirty = if (self.animating) &animation_rect else &.{},
        } };
    }

    pub fn sendMouse(self: *Fake, events: []const input.MouseEvent) input.InputError!void {
        for (events) |e| {
            switch (e) {
                .move => |p| self.cursor = p,
                .down => self.held += 1,
                .up => self.held -|= 1,
                .wheel => {},
            }
            if (self.mouse_len < self.mouse.len) {
                self.mouse[self.mouse_len] = e;
                self.mouse_len += 1;
            }
        }
    }

    pub fn cursorPosition(self: *Fake) [2]i32 {
        return self.cursor;
    }

    pub fn keyCombo(self: *Fake, combo: keys.Combo, action: input.KeyAction) input.InputError!void {
        if (combo.key == .char and self.unmappable != null and combo.key.char == self.unmappable.?) return error.Unmappable;
        switch (action) {
            .tap => {},
            .press => self.held += 1,
            .release => self.held -|= 1,
        }
        if (action == .press and self.trip_on_press) if (self.control) |c| {
            self.trip_on_press = false;
            _ = c.trip();
        };
        if (self.key_len < self.key_calls.len) {
            self.key_calls[self.key_len] = .{ .combo = combo, .action = action };
            self.key_len += 1;
        }
    }

    pub fn typeText(self: *Fake, units: []const u16) input.InputError!void {
        self.type_calls += 1;
        // Two events (down, up) per UTF-16 unit, as SendInput receives them.
        self.largest_type_batch = @max(self.largest_type_batch, units.len * 2);
        const n = @min(units.len, self.typed.len - self.typed_len);
        @memcpy(self.typed[self.typed_len..][0..n], units[0..n]);
        self.typed_len += n;
    }

    pub fn targetAt(self: *Fake, point: ?[2]i32) input.Target {
        if (self.elevated) return .elevated;
        if (point) |p| if (self.elevated_at) |e| if (p[0] == e[0] and p[1] == e[1]) return .elevated;
        return .ok;
    }

    pub const windows_fixture = [_]display.WindowInfo{
        .{ .handle = 0x1a2b, .title = "Bloc-notes", .exe = "notepad.exe", .pid = 4242, .rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 }, .elevated = false, .minimized = false, .cloaked = false },
        .{ .handle = 0x3c4d, .title = "Administrateur : PowerShell", .exe = "WindowsTerminal.exe", .pid = 77, .rect = .{ .x = -1800, .y = 300, .w = 900, .h = 600 }, .elevated = true, .minimized = false, .cloaked = false },
        .{ .handle = 0x5e6f, .title = "Paramètres", .exe = "SystemSettings.exe", .pid = 99, .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .elevated = false, .minimized = false, .cloaked = true },
    };

    pub fn listWindows(self: *Fake, arena: std.mem.Allocator, include_hidden: bool) error{OutOfMemory}![]const display.WindowInfo {
        var out: std.ArrayList(display.WindowInfo) = .empty;
        for (self.windows) |win| if (include_hidden or !win.cloaked) try out.append(arena, win);
        return out.items;
    }

    /// Rectangle of `window`, else of the foreground (accessibility) window.
    pub fn windowRect(self: *Fake, window: ?u64) ?display.Rect {
        if (window) |h| for (self.windows) |win| if (win.handle == h) return win.rect;
        return if (self.ui_elements.len > 0) self.ui_elements[0].rect else null;
    }

    fn refOf(win: display.WindowInfo) display.WindowRef {
        return .{ .handle = win.handle, .pid = win.pid };
    }

    /// Top window under physical point `p`, else the foreground window
    /// (`ui_window`).
    pub fn windowAt(self: *Fake, point: ?[2]i32) ?display.WindowRef {
        const p = point orelse return self.windowRef(self.ui_window) orelse .{ .handle = self.ui_window, .pid = 0 };
        for (self.windows) |win| if (!win.cloaked and !win.minimized and win.rect.contains(p[0], p[1])) return refOf(win);
        return null;
    }

    pub fn windowRef(self: *Fake, handle: u64) ?display.WindowRef {
        for (self.windows) |win| if (win.handle == handle) return refOf(win);
        return null;
    }

    pub fn processName(self: *Fake, arena: std.mem.Allocator, pid: u32) ?[]const u8 {
        _ = arena;
        self.process_lookups += 1;
        for (self.windows) |win| if (win.pid == pid) return win.exe;
        return null;
    }

    pub fn visibleWindows(self: *Fake, arena: std.mem.Allocator) error{OutOfMemory}![]const display.VisibleWindow {
        var out: std.ArrayList(display.VisibleWindow) = .empty;
        for (self.windows) |win| if (!win.cloaked and !win.minimized)
            try out.append(arena, .{ .handle = win.handle, .pid = win.pid, .rect = win.rect, .solid = true });
        return out.items;
    }

    pub fn beginSecretScan(self: *Fake) void {
        self.secret_scans += 1;
    }

    /// Rectangles of the on-screen password elements of the foreground tree.
    pub fn secretRects(self: *Fake) []const display.Rect {
        var n: usize = 0;
        for (self.ui_elements) |e| if (e.password and !e.states.offscreen and n < self.secret_buf.len) {
            self.secret_buf[n] = e.rect;
            n += 1;
        };
        return self.secret_buf[0..n];
    }

    pub fn startKillSwitch(self: *Fake, control: *Control, rearm: keys.Combo) void {
        _ = rearm;
        self.control = control;
    }

    /// Extra roots of the foreground window (`ui_window`).
    pub fn uiRoots(self: *Fake, arena: std.mem.Allocator, window: ?u64) []const uitree.RootWindow {
        if (window) |h| if (h != self.ui_window) return &.{};
        const out = arena.alloc(uitree.RootWindow, self.ui_extra.len) catch return &.{};
        for (self.ui_extra, out) |x, *o| o.* = x.window;
        return out;
    }

    pub fn uiSnapshot(self: *Fake, arena: std.mem.Allocator, window: ?u64, request: uitree.Request) uitree.SnapshotResult {
        if (window) |h| if (h != self.ui_window) {
            for (self.windows) |win| if (win.handle == h) {
                const root = arena.alloc(uitree.Element, 1) catch return .{ .err = "Mémoire insuffisante : réessaie." };
                root[0] = .{ .key = win.handle, .depth = 0, .role = .window, .name = win.title, .rect = win.rect };
                return .{ .ok = .{ .window = h, .elements = root } };
            };
            return .{ .err = "Fenêtre fermée : rappelle window_list" };
        };
        self.ui_snapshots += 1;
        self.ui_requested = request.extra_roots.len;
        var snap: uitree.Snapshot = .{ .window = self.ui_window, .elements = self.ui_elements, .partial = self.ui_partial, .desktop = self.ui_desktop, .web_pending = self.ui_web_pending, .firefox_no_tree = self.ui_firefox_no_tree };
        // Chromium's web tree is not built yet: its text is not read.
        if (request.text and !self.ui_web_pending) {
            if (self.ui_web) |web| {
                snap.elements = web;
                snap.web_text = .read;
                snap.page = self.ui_page;
            } else snap.web_text = .no_document;
        }
        if (request.extra_roots.len == 0 and !self.ui_modal) return .{ .ok = snap };
        var els: std.ArrayList(uitree.Element) = .empty;
        var roots: std.ArrayList(uitree.Root) = .empty;
        roots.append(arena, .{ .start = 0, .handle = self.ui_window, .modal = self.ui_modal }) catch return .{ .err = "Mémoire insuffisante : réessaie." };
        els.appendSlice(arena, snap.elements) catch return .{ .err = "Mémoire insuffisante : réessaie." };
        for (request.extra_roots) |r| for (self.ui_extra) |x| if (x.window.handle == r.handle) {
            roots.append(arena, .{ .start = @intCast(els.items.len), .handle = r.handle, .modal = x.modal }) catch return .{ .err = "Mémoire insuffisante : réessaie." };
            els.appendSlice(arena, x.elements) catch return .{ .err = "Mémoire insuffisante : réessaie." };
        };
        snap.elements = els.items;
        snap.roots = roots.items;
        return .{ .ok = snap };
    }

    pub fn uiAct(self: *Fake, arena: std.mem.Allocator, window: u64, key: u64, action: uitree.Action, value: ?[]const u8) uitree.ActResult {
        _ = arena;
        _ = window;
        const e = self.findElement(key) orelse return .gone;
        if (e.states.disabled) return .disabled;
        if (e.states.offscreen and action != .scroll_into_view) return .offscreen;
        const supported = switch (action) {
            .invoke => e.actions.invoke,
            .toggle => e.actions.toggle,
            .select => e.actions.select,
            .expand, .collapse => e.actions.expand_collapse,
            .set_value => e.actions.value,
            .focus => true,
            .scroll_into_view => e.actions.scroll,
        };
        if (!supported) return .{ .unsupported = e.rect };
        self.ui_last_act = .{ .key = key, .action = action, .value_len = if (value) |v| v.len else 0 };
        return .ok;
    }

    fn findElement(self: *Fake, key: u64) ?uitree.Element {
        for (self.ui_elements) |el| if (el.key == key) return el;
        for (self.ui_extra) |x| for (x.elements) |el| if (el.key == key) return el;
        return null;
    }

    pub fn focusWindow(self: *Fake, handle: u64) display.FocusResult {
        for (self.windows) |win| if (win.handle == handle) {
            self.focused = handle;
            return .ok;
        };
        return .closed;
    }
};
