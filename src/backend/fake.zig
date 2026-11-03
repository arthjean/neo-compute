//! In-memory backend for testing the portable core on any OS. It records
//! every input it receives and serves synthetic displays and windows.

const std = @import("std");
const display = @import("../core/display.zig");
const input = @import("../core/input.zig");
const keys = @import("../core/keys.zig");

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
            .fresh = self.capture_calls == 1,
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

    pub fn listWindows(self: *Fake, arena: std.mem.Allocator, include_hidden: bool) error{OutOfMemory}![]const display.WindowInfo {
        _ = self;
        var out: std.ArrayList(display.WindowInfo) = .empty;
        for (windows_fixture) |win| if (include_hidden or !win.cloaked) try out.append(arena, win);
        return out.items;
    }

    pub fn focusWindow(self: *Fake, handle: u64) display.FocusResult {
        for (windows_fixture) |win| if (win.handle == handle) {
            self.focused = handle;
            return .ok;
        };
        return .closed;
    }
};
