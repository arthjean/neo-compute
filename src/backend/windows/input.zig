//! SendInput: absolute moves on the virtual desktop in physical pixels,
//! buttons, wheel, keys resolved on the foreground window's layout, Unicode
//! text, and the registry of held keys and buttons that `releaseAll` lets go.

const std = @import("std");
const w = @import("win32");
const core_input = @import("../../core/input.zig");
const keys = @import("../../core/keys.zig");
const InputError = core_input.InputError;

/// SendInput calls made by this process: the background selftest proves
/// the background mode makes none (EP-011).
pub var send_calls: std.atomic.Value(u32) = .init(0);

/// A null relative mouse move: Windows grants the foreground to the process
/// that sent the last input (window_focus).
pub fn nudge() void {
    var inputs = [_]w.INPUT{.{ .type = w.INPUT_MOUSE, .Anonymous = .{ .mi = .{ .dx = 0, .dy = 0, .mouseData = 0, .dwFlags = w.MOUSEEVENTF_MOVE, .time = 0, .dwExtraInfo = 0 } } }};
    send(&inputs) catch {};
}

fn send(inputs: []w.INPUT) InputError!void {
    if (inputs.len == 0) return;
    _ = send_calls.fetchAdd(1, .monotonic);
    const sent = w.SendInput(@intCast(inputs.len), inputs.ptr, @sizeOf(w.INPUT));
    if (sent != inputs.len) return error.InputBlocked;
}

/// Maps a physical desktop pixel to the 0..65535 range SendInput expects
/// with MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK.
pub fn normalize(x: i32, y: i32) [2]i32 {
    const vx = w.GetSystemMetrics(w.SM_XVIRTUALSCREEN);
    const vy = w.GetSystemMetrics(w.SM_YVIRTUALSCREEN);
    const vw = w.GetSystemMetrics(w.SM_CXVIRTUALSCREEN);
    const vh = w.GetSystemMetrics(w.SM_CYVIRTUALSCREEN);
    // Round to the pixel center so the inverse mapping lands on (x, y).
    const nx = @divFloor((@as(i64, x - vx) * 65536 + @divFloor(65536, 2)), vw);
    const ny = @divFloor((@as(i64, y - vy) * 65536 + @divFloor(65536, 2)), vh);
    return .{ @intCast(nx), @intCast(ny) };
}

fn mouse(dx: i32, dy: i32, data: u32, flags: w.MOUSE_EVENT_FLAGS) w.INPUT {
    return .{ .type = w.INPUT_MOUSE, .Anonymous = .{ .mi = .{ .dx = dx, .dy = dy, .mouseData = data, .dwFlags = flags, .time = 0, .dwExtraInfo = 0 } } };
}

fn keyInput(vk: u16, scan: u16, flags: w.KEYBD_EVENT_FLAGS) w.INPUT {
    return .{ .type = w.INPUT_KEYBOARD, .Anonymous = .{ .ki = .{ .wVk = vk, .wScan = scan, .dwFlags = flags, .time = 0, .dwExtraInfo = 0 } } };
}

/// Keys and buttons currently held down by neo-compute.
pub const Held = struct {
    keys: std.StaticBitSet(256) = .empty,
    buttons: [3]bool = @splat(false),

    pub fn count(self: *const Held) usize {
        var n = self.keys.count();
        for (self.buttons) |b| n += @intFromBool(b);
        return n;
    }
};

pub fn sendMouse(held: *Held, events: []const core_input.MouseEvent) InputError!void {
    var buf: [16]w.INPUT = undefined;
    var n: usize = 0;
    const abs = w.MOUSEEVENTF_ABSOLUTE | w.MOUSEEVENTF_VIRTUALDESK;
    for (events) |e| {
        if (n == buf.len) {
            try send(buf[0..n]);
            n = 0;
        }
        buf[n] = switch (e) {
            .move => |p| blk: {
                const np = normalize(p[0], p[1]);
                break :blk mouse(np[0], np[1], 0, w.MOUSEEVENTF_MOVE | abs);
            },
            .down => |b| mouse(0, 0, 0, switch (b) {
                .left => w.MOUSEEVENTF_LEFTDOWN,
                .right => w.MOUSEEVENTF_RIGHTDOWN,
                .middle => w.MOUSEEVENTF_MIDDLEDOWN,
            }),
            .up => |b| mouse(0, 0, 0, switch (b) {
                .left => w.MOUSEEVENTF_LEFTUP,
                .right => w.MOUSEEVENTF_RIGHTUP,
                .middle => w.MOUSEEVENTF_MIDDLEUP,
            }),
            .wheel => |wh| mouse(0, 0, @bitCast(wh.clicks * @as(i32, w.WHEEL_DELTA)), if (wh.horizontal) w.MOUSEEVENTF_HWHEEL else w.MOUSEEVENTF_WHEEL),
        };
        n += 1;
        switch (e) {
            .down => |b| held.buttons[@backingInt(b)] = true,
            .up => |b| held.buttons[@backingInt(b)] = false,
            else => {},
        }
    }
    try send(buf[0..n]);
}

pub fn cursorPosition() [2]i32 {
    var p: w.POINT = .{ .x = 0, .y = 0 };
    _ = w.GetCursorPos(&p);
    return .{ p.x, p.y };
}

/// Layout of the window that receives keyboard input, read at every call
/// so a layout switch during the session is honored.
fn activeLayout() w.HKL {
    const fg = w.GetForegroundWindow();
    return w.GetKeyboardLayout(if (fg != null) w.GetWindowThreadProcessId(fg, null) else 0);
}

const Vk = struct { vk: u16, extended: bool = false };

fn namedVk(key: keys.Key) Vk {
    return switch (key) {
        .enter => .{ .vk = w.VK_RETURN },
        .kp_enter => .{ .vk = w.VK_RETURN, .extended = true },
        .tab => .{ .vk = w.VK_TAB },
        .escape => .{ .vk = w.VK_ESCAPE },
        .backspace => .{ .vk = w.VK_BACK },
        .delete => .{ .vk = w.VK_DELETE, .extended = true },
        .insert => .{ .vk = w.VK_INSERT, .extended = true },
        .home => .{ .vk = w.VK_HOME, .extended = true },
        .end => .{ .vk = w.VK_END, .extended = true },
        .page_up => .{ .vk = w.VK_PRIOR, .extended = true },
        .page_down => .{ .vk = w.VK_NEXT, .extended = true },
        .up => .{ .vk = w.VK_UP, .extended = true },
        .down => .{ .vk = w.VK_DOWN, .extended = true },
        .left => .{ .vk = w.VK_LEFT, .extended = true },
        .right => .{ .vk = w.VK_RIGHT, .extended = true },
        .space => .{ .vk = w.VK_SPACE },
        .caps_lock => .{ .vk = w.VK_CAPITAL },
        .num_lock => .{ .vk = w.VK_NUMLOCK, .extended = true },
        .scroll_lock => .{ .vk = w.VK_SCROLL },
        .pause => .{ .vk = w.VK_PAUSE },
        .print_screen => .{ .vk = w.VK_SNAPSHOT, .extended = true },
        .menu => .{ .vk = w.VK_APPS, .extended = true },
        .shift => .{ .vk = w.VK_LSHIFT },
        .ctrl => .{ .vk = w.VK_LCONTROL },
        .alt => .{ .vk = w.VK_LMENU },
        .super => .{ .vk = w.VK_LWIN, .extended = true },
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24 => .{ .vk = w.VK_F1 + (@backingInt(key) - @backingInt(keys.Key.f1)) },
        .kp_0, .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7, .kp_8, .kp_9 => .{ .vk = w.VK_NUMPAD0 + (@backingInt(key) - @backingInt(keys.Key.kp_0)) },
        .kp_add => .{ .vk = w.VK_ADD },
        .kp_subtract => .{ .vk = w.VK_SUBTRACT },
        .kp_multiply => .{ .vk = w.VK_MULTIPLY },
        .kp_divide => .{ .vk = w.VK_DIVIDE, .extended = true },
        .kp_decimal => .{ .vk = w.VK_DECIMAL },
        .volume_mute => .{ .vk = w.VK_VOLUME_MUTE, .extended = true },
        .volume_up => .{ .vk = w.VK_VOLUME_UP, .extended = true },
        .volume_down => .{ .vk = w.VK_VOLUME_DOWN, .extended = true },
        .media_play => .{ .vk = w.VK_MEDIA_PLAY_PAUSE, .extended = true },
        .media_stop => .{ .vk = w.VK_MEDIA_STOP, .extended = true },
        .media_next => .{ .vk = w.VK_MEDIA_NEXT_TRACK, .extended = true },
        .media_prev => .{ .vk = w.VK_MEDIA_PREV_TRACK, .extended = true },
    };
}

const Resolved = struct { vk: Vk, mods: keys.Mods };

/// Virtual key of the combination's final key on `layout`. A character
/// adds the modifiers its layout needs (shift for `A`, AltGr = ctrl+alt for
/// `@` on AZERTY).
fn resolve(combo: keys.Combo, layout: w.HKL) InputError!Resolved {
    var mods = combo.mods;
    const vk: Vk = switch (combo.key) {
        .key => |k| namedVk(k),
        .char => |c| blk: {
            if (c > 0xFFFF) return error.Unmappable;
            const scan = w.VkKeyScanExW(@intCast(c), layout);
            if (scan == -1) return error.Unmappable;
            const bits: u16 = @bitCast(scan);
            const state = bits >> 8;
            if (state & 1 != 0) mods.shift = true;
            if (state & 2 != 0) mods.ctrl = true;
            if (state & 4 != 0) mods.alt = true;
            break :blk .{ .vk = bits & 0xFF };
        },
    };
    return .{ .vk = vk, .mods = mods };
}

/// Virtual key of the combination's final key on the active layout, for
/// matching physical key events (the kill switch re-arm shortcut).
pub fn vkOf(combo: keys.Combo) ?u32 {
    const r = resolve(combo, activeLayout()) catch return null;
    return r.vk.vk;
}

fn keyEvent(vk: Vk, up: bool, layout: w.HKL) w.INPUT {
    const sc = w.MapVirtualKeyExW(vk.vk, w.MAPVK_VK_TO_VSC_EX, layout);
    const ext = vk.extended or (sc >> 8) == 0xE0 or (sc >> 8) == 0xE1;
    var flags: w.KEYBD_EVENT_FLAGS = 0;
    if (ext) flags |= w.KEYEVENTF_EXTENDEDKEY;
    if (up) flags |= w.KEYEVENTF_KEYUP;
    return keyInput(vk.vk, @intCast(sc & 0xFF), flags);
}

const mod_vks = [_]struct { field: []const u8, vk: Vk }{
    .{ .field = "ctrl", .vk = .{ .vk = w.VK_LCONTROL } },
    .{ .field = "alt", .vk = .{ .vk = w.VK_LMENU } },
    .{ .field = "shift", .vk = .{ .vk = w.VK_LSHIFT } },
    .{ .field = "super", .vk = .{ .vk = w.VK_LWIN, .extended = true } },
};

pub fn keyCombo(held: *Held, combo: keys.Combo, action: core_input.KeyAction) InputError!void {
    const layout = activeLayout();
    const r = try resolve(combo, layout);
    var buf: [12]w.INPUT = undefined;
    var n: usize = 0;
    if (action != .release) {
        inline for (mod_vks) |m| if (@field(r.mods, m.field)) {
            buf[n] = keyEvent(m.vk, false, layout);
            n += 1;
        };
        buf[n] = keyEvent(r.vk, false, layout);
        n += 1;
    }
    if (action != .press) {
        buf[n] = keyEvent(r.vk, true, layout);
        n += 1;
        comptime var i = mod_vks.len;
        inline while (i > 0) {
            i -= 1;
            if (@field(r.mods, mod_vks[i].field)) {
                buf[n] = keyEvent(mod_vks[i].vk, true, layout);
                n += 1;
            }
        }
    }
    try send(buf[0..n]);
    for (buf[0..n]) |in| {
        const ki = in.Anonymous.ki;
        held.keys.setValue(ki.wVk & 0xFF, ki.dwFlags & w.KEYEVENTF_KEYUP == 0);
    }
}

/// Types UTF-16 units as Unicode key presses: two events per unit, at most
/// `core_input.type_batch_units` units (64 events) per SendInput call. The
/// core sends one character per call, `type_pace_ns` apart.
pub fn typeText(units: []const u16) InputError!void {
    std.debug.assert(units.len <= core_input.type_batch_units);
    var buf: [core_input.type_batch_units * 2]w.INPUT = undefined;
    for (units, 0..) |u, i| {
        buf[2 * i] = keyInput(0, u, w.KEYEVENTF_UNICODE);
        buf[2 * i + 1] = keyInput(0, u, w.KEYEVENTF_UNICODE | w.KEYEVENTF_KEYUP);
    }
    try send(buf[0 .. units.len * 2]);
}

/// Releases every key and button neo-compute holds (FR-07), in one call.
pub fn releaseAll(held: *Held) void {
    var buf: [256 + 3]w.INPUT = undefined;
    var n: usize = 0;
    const layout = activeLayout();
    var it = held.keys.iterator(.{});
    while (it.next()) |vk| {
        const ext = vk == w.VK_LWIN or vk == w.VK_RWIN or vk == w.VK_DELETE or vk == w.VK_INSERT or
            (vk >= w.VK_PRIOR and vk <= w.VK_DOWN) or vk == w.VK_NUMLOCK or vk == w.VK_DIVIDE or vk == w.VK_SNAPSHOT or vk == w.VK_APPS;
        buf[n] = keyEvent(.{ .vk = @intCast(vk), .extended = ext }, true, layout);
        n += 1;
    }
    const ups = [_]w.MOUSE_EVENT_FLAGS{ w.MOUSEEVENTF_LEFTUP, w.MOUSEEVENTF_RIGHTUP, w.MOUSEEVENTF_MIDDLEUP };
    for (held.buttons, ups) |b, f| if (b) {
        buf[n] = mouse(0, 0, 0, f);
        n += 1;
    };
    send(buf[0..n]) catch std.debug.print("neo-compute: releasing {d} held inputs failed\n", .{n});
    held.* = .{};
}

// ---------------------------------------------------------------- injection target (UIPI)

/// Mandatory integrity RID of a process, null when its token cannot be read.
fn integrityOf(process: w.HANDLE) ?u32 {
    var token: w.HANDLE = null;
    if (w.OpenProcessToken(process, w.TOKEN_QUERY, &token) == 0) return null;
    defer _ = w.CloseHandle(token);
    var buf: [128]u8 align(8) = undefined;
    var len: u32 = 0;
    if (w.GetTokenInformation(token, w.TokenIntegrityLevel, &buf, buf.len, &len) == 0) return null;
    const label: *const w.TOKEN_MANDATORY_LABEL = @ptrCast(&buf);
    const sid = label.Label.Sid;
    const count = (w.GetSidSubAuthorityCount(sid) orelse return null).*;
    if (count == 0) return null;
    return (w.GetSidSubAuthority(sid, count - 1) orelse return null).*;
}

var own_integrity: ?u32 = null;

/// True when the process runs at a higher integrity level than this one,
/// so UIPI silently drops injected input into its windows. A token we may
/// not read belongs to such a process.
pub fn isElevatedPid(pid: u32) bool {
    if (pid == w.GetCurrentProcessId()) return false;
    const own = own_integrity orelse blk: {
        own_integrity = integrityOf(w.GetCurrentProcess()) orelse 0x2000;
        break :blk own_integrity.?;
    };
    const process = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer _ = w.CloseHandle(process);
    const other = integrityOf(process) orelse return true;
    return other > own;
}

/// Whether input aimed at `point` (physical), or at the foreground window
/// when null, would reach a window of higher integrity.
pub fn targetAt(point: ?[2]i32) core_input.Target {
    const hwnd = if (point) |p| w.WindowFromPoint(.{ .x = p[0], .y = p[1] }) else w.GetForegroundWindow();
    if (hwnd == null) return .ok;
    const root = w.GetAncestor(hwnd, w.GA_ROOT) orelse hwnd;
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(root, &pid);
    if (pid == 0) return .ok;
    return if (isElevatedPid(pid)) .elevated else .ok;
}
