//! The native selection of Win32 lists (EP-017) in `neo-compute selftest
//! --background`: `select` on the covered test window's drop-down list and
//! list box goes by the lists' own messages, the owner receives the
//! notification a user's choice sends, the drop-down never opens, and the
//! session stays the user's. `bg-select-winforms` proves the path on a
//! WinForms combo box of another process, which raises SelectedIndexChanged
//! only from the notification its form reflects.

const std = @import("std");
const w = @import("win32");
const test_window = @import("test_window.zig");
const TestWindow = test_window.TestWindow;
const bg = @import("selftest_background.zig");
const Bench = bg.Bench;
const selftest = @import("selftest.zig");
const display = @import("core").display;

/// Selections timed by `bg-select-native`.
const cost_reps = 30;
/// US-064: a native selection, settling aside, at the 95th percentile.
const cost_budget_us = 5000;

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

fn has(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

/// Runs `bg-select-native` and `bg-select-notify`. True when the decoy lost
/// the foreground to something else than the server.
pub fn run(b: *Bench) !bool {
    controls(b) catch |err| switch (err) {
        error.DecoyLost => return true,
        else => return err,
    };
    return false;
}

fn controls(b: *Bench) !void {
    const tw = b.tw;
    if (tw.comboDropped()) tw.closeCombo();
    tw.setCombo(0);
    tw.listToTop();
    w.Sleep(50);
    try nativeCombo(b, tw);
    try notifyList(b, tw);
}

/// US-064: `select` with a name on the drop-down list, closed.
fn nativeCombo(b: *Bench, tw: *TestWindow) !void {
    const name = "bg-select-native";
    const combo = b.id("combobox") orelse return b.report.fail(name, "no drop-down list in the target's tree", .{});
    const base = tw.notices();
    const before = b.begin() orelse return error.DecoyLost;
    const res = try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"select\",\"value\":\"{s}\",\"observe\":\"none\"}}", .{ combo, "NEO-COMPUTE OPTION B" });
    var waited: u32 = 0;
    while (tw.notices().combo_changes == base.combo_changes and waited < 500) : (waited += 10) w.Sleep(10);
    const v = b.end(before);
    const now = tw.notices();
    const line = firstLine(res.text);
    var buf: [96]u8 = undefined;
    if (res.is_error or !has(line, "vérifié (sélectionné)") or !has(line, "par messages natifs"))
        return b.report.fail(name, "select answered `{s}`", .{line});
    if (tw.comboSelection() != 1 or tw.comboDropped())
        return b.report.fail(name, "the drop-down shows entry {d}, open {}", .{ tw.comboSelection(), tw.comboDropped() });
    if (now.combo_changes != base.combo_changes + 1 or now.id != test_window.combo_id)
        return b.report.fail(name, "{d} CBN_SELCHANGE received (expected 1), last control id 0x{x} (expected 0x{x})", .{ now.combo_changes - base.combo_changes, now.id, test_window.combo_id });
    if (now.dropdowns != base.dropdowns)
        return b.report.fail(name, "the owner received {d} CBN_DROPDOWN: the list opened", .{now.dropdowns - base.dropdowns});
    if (v.any()) return b.report.fail(name, "the session changed: {s}", .{v.text(&buf)});

    // The cost of the path, settling aside (`observe: none`).
    const entries = [_][]const u8{ "neo-compute option C", "neo-compute option A", "neo-compute option B" };
    const indices = [_]isize{ 2, 0, 1 };
    var cost: [cost_reps]u64 = undefined;
    var wrong: u32 = 0;
    const loop_base = tw.notices();
    const loop_before = b.begin() orelse return error.DecoyLost;
    for (&cost, 0..) |*c, i| {
        const t0 = selftest.qpcUs();
        const r = try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"select\",\"value\":\"{s}\",\"observe\":\"none\"}}", .{ combo, entries[i % entries.len] });
        c.* = selftest.qpcUs() - t0;
        const want = indices[i % entries.len];
        if (r.is_error or !has(firstLine(r.text), "vérifié (sélectionné)") or tw.comboSelection() != want) wrong += 1;
    }
    const loop_v = b.end(loop_before);
    const after = tw.notices();
    std.mem.sort(u64, &cost, {}, std.sort.asc(u64));
    const p95 = cost[(cost_reps * 95 + 99) / 100 - 1];
    if (wrong != 0 or after.combo_changes != loop_base.combo_changes + cost_reps or after.dropdowns != loop_base.dropdowns) {
        b.report.fail(name, "{d} of {d} timed selections without a verified verdict or the entry asked, {d} CBN_SELCHANGE, {d} CBN_DROPDOWN", .{ wrong, cost_reps, after.combo_changes - loop_base.combo_changes, after.dropdowns - loop_base.dropdowns });
    } else if (loop_v.any()) {
        b.report.fail(name, "the timed selections changed the session: {s}", .{loop_v.text(&buf)});
    } else if (p95 >= cost_budget_us) {
        b.report.fail(name, "a native selection took {d} us at p95 (median {d} us), budget {d} us", .{ p95, cost[cost_reps / 2], cost_budget_us });
    } else b.report.ok(name, "the drop-down list took its entry by name through CB_GETLBTEXT and CB_SETCURSEL, closed: 1 CBN_SELCHANGE with id 0x{x} per selection, 0 CBN_DROPDOWN, read back by CB_GETCURSEL, session unchanged; {d} selections at {d} us p95 (median {d} us), budget {d} us", .{ test_window.combo_id, cost_reps, p95, cost[cost_reps / 2], cost_budget_us });
}

/// US-064: `select` without a value on an entry of the list box keeps
/// UI Automation's Select, then the owner hears of it.
fn notifyList(b: *Bench, tw: *TestWindow) !void {
    const name = "bg-select-notify";
    const needle = test_window.list_prefix ++ "02";
    const entry = b.id(needle) orelse return b.report.fail(name, "no element `{s}` in the target's tree", .{needle});
    const base = tw.notices();
    const before = b.begin() orelse return error.DecoyLost;
    const res = try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"select\",\"observe\":\"none\"}}", .{entry});
    var waited: u32 = 0;
    while (tw.notices().list_changes == base.list_changes and waited < 500) : (waited += 10) w.Sleep(10);
    const v = b.end(before);
    const now = tw.notices();
    const line = firstLine(res.text);
    var buf: [96]u8 = undefined;
    if (res.is_error or !has(line, "vérifié (sélectionné)") or !has(line, "application prévenue par message natif")) {
        b.report.fail(name, "select answered `{s}`", .{line});
    } else if (tw.listSelection() != 1) {
        b.report.fail(name, "the list box shows entry {d}, expected 1", .{tw.listSelection()});
    } else if (now.list_changes != base.list_changes + 1 or now.id != test_window.list_id) {
        b.report.fail(name, "{d} LBN_SELCHANGE received (expected 1), last control id 0x{x} (expected 0x{x})", .{ now.list_changes - base.list_changes, now.id, test_window.list_id });
    } else if (v.any()) {
        b.report.fail(name, "the session changed: {s}", .{v.text(&buf)});
    } else b.report.ok(name, "an entry of the LBS_NOTIFY list box selected by SelectionItem.Select, then 1 LBN_SELCHANGE with id 0x{x} to its owner, session unchanged", .{test_window.list_id});
}

const winforms_title = "neo-compute winforms";

/// What the WinForms window's title says: SelectedIndexChanged and DropDown
/// raised so far, and the selected index.
const Shown = struct {
    changes: u32,
    dropdowns: u32,
    index: i32,

    fn of(hwnd: w.HWND) ?Shown {
        var title: [64:0]u16 = undefined;
        const n: usize = @intCast(@max(0, w.InternalGetWindowText(hwnd, &title, title.len)));
        var utf8: [128]u8 = undefined;
        const text = utf8[0 .. std.unicode.utf16LeToUtf8(&utf8, title[0..n]) catch return null];
        if (!std.mem.startsWith(u8, text, winforms_title ++ " ")) return null;
        var it = std.mem.tokenizeScalar(u8, text[winforms_title.len..], ' ');
        return .{
            .changes = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null,
            .dropdowns = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null,
            .index = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null,
        };
    }
};

/// The top-level window whose title is the WinForms window's.
const Find = struct {
    found: w.HWND = null,

    fn callback(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
        const self: *Find = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (Shown.of(hwnd) == null) return 1;
        self.found = hwnd;
        return 0;
    }
};

/// US-064: the path on a WinForms combo box of another process, which
/// raises SelectedIndexChanged only from the WM_COMMAND its form reflects.
/// Skipped without the .NET Framework compiler. Changes the session's
/// target: the caller names its own again.
pub fn winforms(b: *Bench, io: std.Io, env: *const std.process.Environ.Map, arena: std.mem.Allocator, area: display.Rect) !void {
    const name = "bg-select-winforms";
    const windir = env.get("WINDIR") orelse env.get("windir") orelse return b.report.skip(name, "WINDIR unset: .NET Framework not found", .{});
    const csc = try std.fmt.allocPrint(arena, "{s}\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe", .{windir});
    std.Io.Dir.cwd().access(io, csc, .{}) catch return b.report.skip(name, "no .NET Framework compiler at {s}", .{csc});
    const dir = ".zig-cache\\selftest-winforms";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const source = dir ++ "\\winforms_combo.cs";
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = @embedFile("winforms_combo.cs") }) catch |err| return b.report.fail(name, "the WinForms source cannot be written ({t})", .{err});
    const exe = dir ++ "\\neo-winforms.exe";
    {
        var compile = std.process.spawn(io, .{ .argv = &.{ csc, "-nologo", "-target:winexe", "-out:" ++ exe, source }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err|
            return b.report.skip(name, "the .NET Framework compiler does not start ({t})", .{err});
        const term = compile.wait(io) catch return b.report.fail(name, "the compiler could not be waited for", .{});
        if (term != .exited or term.exited != 0) return b.report.fail(name, "the WinForms window does not compile ({any})", .{term});
    }
    const x = try std.fmt.allocPrint(arena, "{d}", .{area.x + 160});
    const y = try std.fmt.allocPrint(arena, "{d}", .{area.y + 180});
    var child = std.process.spawn(io, .{ .argv = &.{ exe, x, y }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err|
        return b.report.fail(name, "the WinForms window does not start ({t})", .{err});
    defer child.kill(io);
    var find: Find = .{};
    var waited: u32 = 0;
    while (find.found == null and waited < 10_000) : (waited += 100) {
        w.Sleep(100);
        _ = w.EnumWindows(Find.callback, @bitCast(@intFromPtr(&find)));
    }
    const hwnd = find.found orelse return b.report.fail(name, "no window `{s} ...` after 10 s", .{winforms_title});
    w.Sleep(300);
    if (!b.decoy.front()) return error.DecoyLost;
    b.decoy.tuck(hwnd);
    w.Sleep(100);
    const handle: u64 = @intFromPtr(hwnd);
    const tree = try b.caller.call("ui_tree", "{{\"window\":\"0x{x}\"}}", .{handle});
    if (tree.is_error) return b.report.fail(name, "the WinForms tree cannot be read: {s}", .{tree.text});
    const combo = Bench.idIn(tree.text, "combobox") orelse return b.report.fail(name, "no combo box in the WinForms tree", .{});
    const base = Shown.of(hwnd) orelse return b.report.fail(name, "the WinForms window's title cannot be read", .{});
    const before = b.begin() orelse return error.DecoyLost;
    const res = try b.caller.call("ui_act", "{{\"id\":\"{s}\",\"action\":\"select\",\"value\":\"{s}\",\"observe\":\"none\"}}", .{ combo, "neo-compute winforms c" });
    var shown = base;
    waited = 0;
    while (waited <= 1000) : (waited += 20) {
        shown = Shown.of(hwnd) orelse base;
        if (shown.changes != base.changes and shown.index == 2) break;
        w.Sleep(20);
    }
    const v = b.end(before);
    const line = firstLine(res.text);
    var buf: [96]u8 = undefined;
    if (res.is_error or !has(line, "vérifié (sélectionné)") or !has(line, "par messages natifs")) {
        b.report.fail(name, "select answered `{s}`", .{line});
    } else if (shown.index != 2 or shown.changes != base.changes + 1 or shown.dropdowns != base.dropdowns) {
        b.report.fail(name, "the WinForms combo box shows index {d}, {d} SelectedIndexChanged and {d} DropDown since the call (expected 2, 1 and 0)", .{ shown.index, shown.changes - base.changes, shown.dropdowns - base.dropdowns });
    } else if (v.any()) {
        b.report.fail(name, "the session changed: {s}", .{v.text(&buf)});
    } else b.report.ok(name, "a WinForms combo box of another process took its entry closed: SelectedIndexChanged raised once through the reflected WM_COMMAND, DropDown never, session unchanged", .{});
}
