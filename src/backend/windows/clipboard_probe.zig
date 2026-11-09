//! `neo-compute clipboard-probe [SECONDS]` (US-035, assumption A11): prints
//! one line per new clipboard content with its owner's executable, every
//! format it carries, the DWORD of the two `Can...` formats, and whether
//! `clipboard` would refuse it. The content itself is never read. Run it,
//! copy a password from each installed password manager, and record the
//! lines in the decision that answers A11.

const std = @import("std");
const w = @import("win32");
const clipboard = @import("../../core/clipboard.zig");
const window = @import("window.zig");

fn register(name: []const u8) u32 {
    var wide: [64:0]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&wide, name) catch return 0;
    wide[n] = 0;
    return w.RegisterClipboardFormatW(&wide);
}

fn dword(id: u32) ?u32 {
    const h = w.GetClipboardData(id) orelse return null;
    const p = w.GlobalLock(h) orelse return null;
    defer _ = w.GlobalUnlock(h);
    if (w.GlobalSize(h) < 4) return null;
    return @as(*align(1) const u32, @ptrCast(p)).*;
}

fn describe(out: *std.Io.Writer, arena: std.mem.Allocator, seq: u32) !void {
    var opened = false;
    for (0..20) |_| {
        if (w.OpenClipboard(null) != 0) {
            opened = true;
            break;
        }
        w.Sleep(10);
    }
    if (!opened) return out.print("clipboard-probe: seq {d}: clipboard held open, skipped\n", .{seq});
    defer _ = w.CloseClipboard();
    var pid: u32 = 0;
    const owner = w.GetClipboardOwner();
    if (owner != null) _ = w.GetWindowThreadProcessId(owner, &pid);
    const exe = (window.processName(arena, pid) catch null) orelse "?";
    try out.print("clipboard-probe: seq {d} owner {s} (pid {d}):", .{ seq, exe, pid });
    var markers: [4]u32 = undefined;
    inline for (@typeInfo(clipboard.Marker).@"enum".field_names, 0..) |name, i| markers[i] = register(@field(clipboard.Marker, name).format());
    var verdict: ?clipboard.Marker = null;
    var id: u32 = 0;
    var first = true;
    while (true) {
        id = w.EnumClipboardFormats(id);
        if (id == 0) break;
        try out.writeAll(if (first) " " else ", ");
        first = false;
        if (clipboard.standardName(id)) |n| try out.writeAll(n) else {
            var wide: [128]u16 = undefined;
            const n = w.GetClipboardFormatNameW(id, @ptrCast(&wide), wide.len);
            if (n > 0) {
                var buf: [384]u8 = undefined;
                try out.writeAll(buf[0..std.unicode.wtf16LeToWtf8(&buf, wide[0..@intCast(n)])]);
            } else try out.print("0x{x}", .{id});
        }
        for (markers, 0..) |m, i| if (id == m) {
            const marker: clipboard.Marker = @fromBackingInt(@intCast(i));
            switch (marker) {
                .exclude_monitor, .viewer_ignore => verdict = verdict orelse marker,
                .no_history, .no_cloud => {
                    const v = dword(id);
                    if (v) |x| try out.print("={d}", .{x}) else try out.writeAll("=?");
                    if (v == null or v.? == 0) verdict = verdict orelse marker;
                },
            }
        };
    }
    if (verdict) |m| try out.print(" -> refused by clipboard ({s})\n", .{m.format()}) else try out.writeAll(" -> no secret format\n");
}

pub fn run(io: std.Io, seconds: u32) u8 {
    var buf: [4096]u8 = undefined;
    var file = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file.interface;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    out.print("clipboard-probe: watching the clipboard for {d} s; copy a password from each password manager (content is never read)\n", .{seconds}) catch {};
    out.flush() catch {};
    var last = w.GetClipboardSequenceNumber();
    var waited: u32 = 0;
    while (waited < seconds * 1000) : (waited += 100) {
        w.Sleep(100);
        const seq = w.GetClipboardSequenceNumber();
        if (seq == last) continue;
        last = seq;
        // Let the owner finish setting its formats.
        w.Sleep(50);
        _ = arena_state.reset(.retain_capacity);
        describe(out, arena_state.allocator(), seq) catch {};
        out.flush() catch {};
    }
    return 0;
}
