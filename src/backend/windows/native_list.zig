//! Win32 lists driven by their own messages (US-064, FR-46). Through UI
//! Automation a `ComboBox` must open for its entries to be read, and the
//! selection of a `ComboBox` or `ListBox` changes without its owner hearing
//! of it (decision 0013, "Exploration du 2026-11-13"). The list's own
//! messages read its entries and set its selection closed, and a
//! `WM_COMMAND` tells its owner, as a user's choice does. These are the only
//! control messages neo-compute sends to an application.

const std = @import("std");
const w = @import("win32");
const uitree = @import("core").uitree;
const input = @import("input.zig");
const uia = @import("uia.zig");

/// Bound of every message: a list or an owner that does not answer within
/// it is not waited for.
pub const timeout_ms = 200;

/// Entry text read at most, in UTF-16 units; a longer entry is not a list
/// the native path drives.
const max_entry_units = 4096;

const Class = struct { kind: uitree.NativeKind, notifies: bool };

/// The messages of one kind of list.
const Msgs = struct {
    count: u32,
    text_len: u32,
    text: u32,
    get_cur: u32,
    set_cur: u32,
    changed: u32,

    fn of(kind: uitree.NativeKind) Msgs {
        return switch (kind) {
            .combo_box => .{ .count = w.CB_GETCOUNT, .text_len = w.CB_GETLBTEXTLEN, .text = w.CB_GETLBTEXT, .get_cur = w.CB_GETCURSEL, .set_cur = w.CB_SETCURSEL, .changed = w.CBN_SELCHANGE },
            .list_box => .{ .count = w.LB_GETCOUNT, .text_len = w.LB_GETTEXTLEN, .text = w.LB_GETTEXT, .get_cur = w.LB_GETCURSEL, .set_cur = w.LB_SETCURSEL, .changed = w.LBN_SELCHANGE },
        };
    }
};

fn bits(x: i32) u32 {
    return @bitCast(x);
}

/// The list `hwnd` is, from its real class (`baseClass`) and its styles;
/// null for a window the native path does not drive: another class
/// (`ComboBoxEx32`, `ComboLBox`), or, when its entries are read and its selection set (`by_name`), a list
/// drawn by its owner without strings or a list box with multiple, extended
/// or no selection. An entry UI Automation selected only needs its list
/// box's owner told, as a user's click tells it whatever the list's styles.
fn classify(hwnd: w.HWND, by_name: bool) ?Class {
    var buf: [64:0]u16 = undefined;
    const n = w.RealGetWindowClassW(hwnd, &buf, buf.len);
    const name = baseClass(buf[0..@min(n, buf.len)]);
    const style: u32 = @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(hwnd, w.GWL_STYLE))));
    if (eqlAscii(name, "ComboBox")) {
        const drawn = style & bits(w.CBS_OWNERDRAWFIXED | w.CBS_OWNERDRAWVARIABLE) != 0;
        if (drawn and style & bits(w.CBS_HASSTRINGS) == 0) return null;
        return .{ .kind = .combo_box, .notifies = true };
    }
    if (eqlAscii(name, "ListBox")) {
        const notifies = style & bits(w.LBS_NOTIFY) != 0;
        if (!by_name) return .{ .kind = .list_box, .notifies = notifies };
        const drawn = style & bits(w.LBS_OWNERDRAWFIXED | w.LBS_OWNERDRAWVARIABLE) != 0;
        if (drawn and style & bits(w.LBS_HASSTRINGS) == 0) return null;
        if (style & bits(w.LBS_MULTIPLESEL | w.LBS_EXTENDEDSEL | w.LBS_NOSEL | w.LBS_NODATA) != 0) return null;
        return .{ .kind = .list_box, .notifies = notifies };
    }
    return null;
}

/// The system class a window's real class names. `RealGetWindowClassW`
/// gives a WinForms control's own class, not the one it superclasses
/// (measured on a .NET Framework combo box: `WindowsForms10.COMBOBOX.app.0.
/// 34f5582_r6_ad1`): WinForms names its classes `WindowsForms10.<system
/// class>.app.<...>`, and that second part is the class.
fn baseClass(real: []const u16) []const u16 {
    const prefix = "WindowsForms10.";
    if (real.len <= prefix.len or !eqlAscii(real[0..prefix.len], prefix)) return real;
    const rest = real[prefix.len..];
    return rest[0 .. std.mem.indexOfScalar(u16, rest, '.') orelse rest.len];
}

fn eqlAscii(wide: []const u16, comptime ascii: []const u8) bool {
    if (wide.len != ascii.len) return false;
    for (wide, ascii) |c, a| {
        if (c > 0x7f or std.ascii.toLower(@intCast(c)) != std.ascii.toLower(a)) return false;
    }
    return true;
}

/// One message, bounded; null when the window did not answer in time.
fn send(hwnd: w.HWND, msg: u32, wparam: usize, lparam: isize) ?isize {
    var result: usize = 0;
    if (w.SendMessageTimeoutW(hwnd, msg, wparam, lparam, w.SMTO_ABORTIFHUNG, timeout_ms, &result) == 0) return null;
    return @bitCast(result);
}

/// The list of window `handle` (null entries unless `entries`), checked
/// for its class, its styles and its integrity before any message.
pub fn read(arena: std.mem.Allocator, handle: u64, entries: bool) uitree.NativeListResult {
    if (handle == 0) return .none;
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return .{ .failed = uia.closed_message };
    const class = classify(hwnd, entries) orelse return .none;
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    if (input.isElevatedPid(pid)) return .elevated;
    const m = Msgs.of(class.kind);
    const hung: uitree.NativeListResult = .{ .failed = uia.hung_message };
    const current = send(hwnd, m.get_cur, 0, 0) orelse return hung;
    var list: uitree.NativeList = .{
        .handle = handle,
        .kind = class.kind,
        .current = if (current < 0) null else @intCast(current),
        .notifies = class.notifies,
    };
    if (!entries) return .{ .ok = list };
    const count = send(hwnd, m.count, 0, 0) orelse return hung;
    // A list that answers nothing sensible, or holds more than UI
    // Automation's path reads, keeps that path.
    if (count < 0 or count > uitree.max_entries) return .none;
    const names = arena.alloc([]const u8, @intCast(count)) catch return .{ .failed = "Mémoire insuffisante : réessaie." };
    for (names, 0..) |*name, i| {
        const len = send(hwnd, m.text_len, i, 0) orelse return hung;
        if (len < 0 or len > max_entry_units) return .none;
        // The text message takes no size: the buffer holds the length the
        // list gave and its terminator.
        const buf = arena.alloc(u16, @as(usize, @intCast(len)) + 1) catch return .{ .failed = "Mémoire insuffisante : réessaie." };
        @memset(buf, 0);
        const got = send(hwnd, m.text, i, @bitCast(@intFromPtr(buf.ptr))) orelse return hung;
        if (got < 0) return .none;
        const units = buf[0..@min(@as(usize, @intCast(got)), buf.len - 1)];
        name.* = uia.utf8(arena, units, uia.max_name_units) catch return .{ .failed = "Mémoire insuffisante : réessaie." };
    }
    list.entries = names;
    return .{ .ok = list };
}

/// Sets entry `index` of the list of window `handle` (none: the selection
/// stays, for an entry UI Automation selected), tells its owner when the
/// list notifies, then reads the selection back.
pub fn select(handle: u64, index: ?usize) uitree.NativeSelectResult {
    const hwnd: w.HWND = @ptrFromInt(handle);
    if (w.IsWindow(hwnd) == 0) return .{ .failed = uia.closed_message };
    const class = classify(hwnd, index != null) orelse return .{ .failed = uia.closed_message };
    const m = Msgs.of(class.kind);
    if (index) |i| _ = send(hwnd, m.set_cur, i, 0) orelse return .{ .failed = uia.hung_message };
    var notice: uitree.NativeNotice = .none;
    if (class.notifies) {
        // The owner of a child control is its parent window, which
        // receives its notifications with the control's identifier.
        const owner = w.GetAncestor(hwnd, w.GA_PARENT);
        const id: u16 = @truncate(@as(u32, @bitCast(w.GetDlgCtrlID(hwnd))));
        const wparam = (@as(usize, @as(u16, @truncate(m.changed))) << 16) | id;
        notice = if (owner != null and send(owner, w.WM_COMMAND, wparam, @bitCast(handle)) != null) .sent else .timeout;
    }
    const current = send(hwnd, m.get_cur, 0, 0);
    return .{ .ok = .{ .current = if (current) |c| (if (c < 0) null else @as(usize, @intCast(c))) else null, .notice = notice } };
}
