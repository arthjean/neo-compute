//! In-memory backend for testing the portable core on any OS. It records
//! every input it receives and serves synthetic displays and windows.

const std = @import("std");
const display = @import("../core/display.zig");
const input = @import("../core/input.zig");
const keys = @import("../core/keys.zig");
const uitree = @import("../core/uitree.zig");

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
    ui_snapshots: u32 = 0,
    /// Last element action received.
    ui_last_act: ?struct { key: u64, action: uitree.Action, value_len: usize } = null,

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

    /// Window element of each fixture window, for snapshots by handle.
    const win_roots = blk: {
        var out: [windows_fixture.len]uitree.Element = undefined;
        for (windows_fixture, 0..) |win, i| out[i] = .{ .key = win.handle, .depth = 0, .role = .window, .name = win.title, .rect = win.rect };
        break :blk out;
    };

    pub fn listWindows(self: *Fake, arena: std.mem.Allocator, include_hidden: bool) error{OutOfMemory}![]const display.WindowInfo {
        _ = self;
        var out: std.ArrayList(display.WindowInfo) = .empty;
        for (windows_fixture) |win| if (include_hidden or !win.cloaked) try out.append(arena, win);
        return out.items;
    }

    /// Rectangle of `window`, else of the foreground (accessibility) window.
    pub fn windowRect(self: *Fake, window: ?u64) ?display.Rect {
        if (window) |h| for (windows_fixture) |win| if (win.handle == h) return win.rect;
        return if (self.ui_elements.len > 0) self.ui_elements[0].rect else null;
    }

    pub fn uiSnapshot(self: *Fake, arena: std.mem.Allocator, window: ?u64) uitree.SnapshotResult {
        _ = arena;
        if (window) |h| if (h != self.ui_window) {
            for (windows_fixture, 0..) |win, i| if (win.handle == h) return .{ .ok = .{ .window = h, .elements = win_roots[i..][0..1] } };
            return .{ .err = "Fenêtre fermée : rappelle window_list" };
        };
        self.ui_snapshots += 1;
        return .{ .ok = .{ .window = self.ui_window, .elements = self.ui_elements, .partial = self.ui_partial, .desktop = self.ui_desktop, .web_pending = self.ui_web_pending } };
    }

    pub fn uiAct(self: *Fake, arena: std.mem.Allocator, window: u64, key: u64, action: uitree.Action, value: ?[]const u8) uitree.ActResult {
        _ = arena;
        _ = window;
        const e = for (self.ui_elements) |el| {
            if (el.key == key) break el;
        } else return .gone;
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

    pub fn focusWindow(self: *Fake, handle: u64) display.FocusResult {
        for (windows_fixture) |win| if (win.handle == handle) {
            self.focused = handle;
            return .ok;
        };
        return .closed;
    }
};
