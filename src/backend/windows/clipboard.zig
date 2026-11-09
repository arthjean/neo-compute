//! Clipboard worker (US-035): a thread of its own with a message-only
//! window that owns what neo-compute writes. Windows sends the owner
//! WM_DESTROYCLIPBOARD from another application's EmptyClipboard and waits
//! for it, so the owner's thread must keep pumping: neither the dispatcher
//! nor the shell worker, which can be held by a launch, may own it.
//!
//! A read checks the secret formats before any data and copies at most the
//! text the core shows. The dispatcher waits in 10 ms slices up to
//! `wait_ms`: GetClipboardData of a format the owner renders on demand
//! waits for that owner, which may hang. An abandoned job finishes into the
//! worker's own buffers, and the next call reports the clipboard busy until
//! it does.

const std = @import("std");
const w = @import("win32");
const clipboard = @import("../../core/clipboard.zig");

/// OpenClipboard is tried once, then retried this many times, this far apart.
pub const retries = 10;
pub const retry_ms = 10;
/// Longest wait of the dispatcher for one job.
pub const wait_ms = 2000;

const max_units = 2 * clipboard.max_read_chars;
const max_formats = 32;
const marker_count = @typeInfo(clipboard.Marker).@"enum".field_names.len;

const Outcome = enum { text, no_text, secret, busy, failed };

pub const Clipboard = struct {
    thread: ?std.Thread = null,
    wake: w.HANDLE = null,
    done: w.HANDLE = null,
    hwnd: w.HWND = null,
    /// High-resolution waitable timer of the worker, for the retries.
    timer: w.HANDLE = null,
    init_error: ?[]const u8 = null,
    /// A job was abandoned (cancelled or too slow) and may still run.
    pending: bool = false,
    job: enum { read, write, quit } = .quit,
    /// Registered ids of the secret formats, in `Marker` order.
    markers: [marker_count]u32 = @splat(0),
    /// Clipboard sequence number right after neo-compute's last write: the
    /// content it wrote carries two of the markers itself.
    own_seq: u32 = 0,
    // Input of a write: the CF_UNICODETEXT memory, owned by the worker
    // once the job starts.
    mem: w.HGLOBAL = null,
    max_chars: usize = clipboard.max_read_chars,
    // Outputs, written by the worker before it signals `done`.
    outcome: Outcome = .failed,
    marker: clipboard.Marker = .exclude_monitor,
    owner_pid: u32 = 0,
    holder_pid: u32 = 0,
    failure: []const u8 = "",
    text: [max_units]u16 = undefined,
    text_len: usize = 0,
    total_chars: usize = 0,
    format_ids: [max_formats]u32 = undefined,
    format_count: usize = 0,
    formats_total: usize = 0,

    pub fn deinit(self: *Clipboard) void {
        const t = self.thread orelse return;
        if (self.pending) _ = w.WaitForSingleObject(self.done, 5000);
        self.job = .quit;
        _ = w.SetEvent(self.wake);
        t.join();
        _ = w.CloseHandle(self.wake);
        _ = w.CloseHandle(self.done);
        self.thread = null;
    }

    // ------------------------------------------------------------ dispatcher side

    /// The clipboard's text cut to `max_chars` code points, or why it is
    /// not given, copied into `arena`.
    pub fn read(self: *Clipboard, arena: std.mem.Allocator, max_chars: usize, cancel: *const std.atomic.Value(bool)) clipboard.Read {
        if (self.begin()) |r| return switch (r) {
            .busy => |pid| .{ .busy = pid },
            .failed => |msg| .{ .failed = msg },
        };
        self.max_chars = @min(max_chars, clipboard.max_read_chars);
        self.job = .read;
        if (!self.wait(cancel)) return .{ .busy = pidOrNull(self.owner_pid) };
        const owner = pidOrNull(self.owner_pid);
        return switch (self.outcome) {
            .busy => .{ .busy = pidOrNull(self.holder_pid) },
            .failed => .{ .failed = self.failure },
            .secret => .{ .secret = .{ .marker = self.marker, .owner_pid = owner } },
            .text => blk: {
                const units = self.text[0..self.text_len];
                const buf = arena.alloc(u8, units.len * 3) catch break :blk .{ .failed = oom };
                // A lone surrogate becomes U+FFFD rather than invalid UTF-8.
                var out: std.ArrayList(u8) = .initBuffer(buf);
                var it: std.unicode.Wtf16LeIterator = .init(units);
                while (it.nextCodepoint()) |cp| {
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &enc) catch std.unicode.utf8Encode(0xFFFD, &enc) catch unreachable;
                    out.appendSliceAssumeCapacity(enc[0..n]);
                }
                break :blk .{ .text = .{ .text = out.items, .total = self.total_chars, .owner_pid = owner } };
            },
            .no_text => blk: {
                const extra: usize = if (self.formats_total > self.format_count) 1 else 0;
                const names = arena.alloc([]const u8, self.format_count + extra) catch break :blk .{ .failed = oom };
                for (self.format_ids[0..self.format_count], names[0..self.format_count]) |id, *name| name.* = formatName(arena, id);
                if (extra == 1) names[self.format_count] = std.fmt.allocPrint(arena, "… {d} autres", .{self.formats_total - self.format_count}) catch "…";
                break :blk .{ .no_text = .{ .formats = names, .owner_pid = owner } };
            },
        };
    }

    /// Writes `text` as CF_UNICODETEXT with CanIncludeInClipboardHistory and
    /// CanUploadToCloudClipboard at 0.
    pub fn write(self: *Clipboard, text: []const u8, cancel: *const std.atomic.Value(bool)) clipboard.Write {
        if (self.begin()) |r| return switch (r) {
            .busy => |pid| .{ .busy = pid },
            .failed => |msg| .{ .failed = msg },
        };
        const units = std.unicode.calcWtf16LeLen(text) catch return .{ .failed = "Texte invalide : UTF-8 attendu." };
        const mem = w.GlobalAlloc(w.GMEM_MOVEABLE, (units + 1) * 2) orelse return .{ .failed = oom };
        const p = w.GlobalLock(mem) orelse {
            _ = w.GlobalFree(mem);
            return .{ .failed = oom };
        };
        const dst = @as([*]u16, @ptrCast(@alignCast(p)))[0 .. units + 1];
        _ = std.unicode.wtf8ToWtf16Le(dst, text) catch unreachable;
        dst[units] = 0;
        _ = w.GlobalUnlock(mem);
        self.mem = mem;
        self.job = .write;
        if (!self.wait(cancel)) return .{ .busy = pidOrNull(self.owner_pid) };
        return switch (self.outcome) {
            .busy => .{ .busy = pidOrNull(self.holder_pid) },
            .failed => .{ .failed = self.failure },
            else => .ok,
        };
    }

    const Refusal = union(enum) { busy: ?u32, failed: []const u8 };

    /// Starts the thread on first use and settles an abandoned job.
    fn begin(self: *Clipboard) ?Refusal {
        if (self.thread == null) {
            self.wake = w.CreateEventW(null, 0, 0, null);
            self.done = w.CreateEventW(null, 0, 0, null);
            if (self.wake == null or self.done == null) return .{ .failed = "Presse-papiers indisponible : création des événements impossible, réessaie." };
            self.thread = std.Thread.spawn(.{}, loop, .{self}) catch return .{ .failed = "Presse-papiers indisponible : thread de travail impossible à créer, réessaie." };
            _ = w.WaitForSingleObject(self.done, w.INFINITE);
        }
        if (self.init_error) |msg| return .{ .failed = msg };
        if (self.pending) {
            if (w.WaitForSingleObject(self.done, 0) != w.WAIT_OBJECT_0) return .{ .busy = pidOrNull(self.owner_pid) };
            self.pending = false;
        }
        return null;
    }

    /// Runs the job set in `self.job`; false when `cancel` fired or the job
    /// outlasted `wait_ms` (it keeps running and is settled by `begin`).
    fn wait(self: *Clipboard, cancel: *const std.atomic.Value(bool)) bool {
        _ = w.SetEvent(self.wake);
        var waited: u32 = 0;
        while (true) : (waited += 10) {
            if (w.WaitForSingleObject(self.done, 10) == w.WAIT_OBJECT_0) return true;
            if (cancel.load(.acquire) or waited >= wait_ms) {
                self.pending = true;
                return false;
            }
        }
    }

    // ------------------------------------------------------------ worker side

    fn loop(self: *Clipboard) void {
        self.setup();
        _ = w.SetEvent(self.done);
        while (true) {
            const r = w.MsgWaitForMultipleObjects(1, @ptrCast(&self.wake), 0, w.INFINITE, w.QS_ALLINPUT);
            if (r == w.WAIT_OBJECT_0 + 1) {
                pump();
                continue;
            }
            if (r != w.WAIT_OBJECT_0) continue;
            switch (self.job) {
                .quit => break,
                .read => self.runRead(),
                .write => self.runWrite(),
            }
            _ = w.SetEvent(self.done);
        }
        if (self.hwnd != null) _ = w.DestroyWindow(self.hwnd);
        if (self.timer != null) _ = w.CloseHandle(self.timer);
    }

    fn setup(self: *Clipboard) void {
        self.timer = w.CreateWaitableTimerExW(null, null, w.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, w.TIMER_ALL_ACCESS);
        // A marker Windows would not register could never be detected:
        // refuse every read rather than miss one.
        inline for (@typeInfo(clipboard.Marker).@"enum".field_names, 0..) |name, i| {
            const m: clipboard.Marker = @field(clipboard.Marker, name);
            var wide: [64:0]u16 = undefined;
            const n = std.unicode.wtf8ToWtf16Le(&wide, m.format()) catch unreachable;
            wide[n] = 0;
            self.markers[i] = w.RegisterClipboardFormatW(&wide);
            if (self.markers[i] == 0) {
                self.init_error = "Presse-papiers indisponible : formats de secret non enregistrés par Windows, réessaie.";
                return;
            }
        }
        const module = w.GetModuleHandleW(null);
        const class = std.unicode.utf8ToUtf16LeStringLiteral("neo-compute-clipboard");
        const wc: w.WNDCLASSEXW = .{
            .cbSize = @sizeOf(w.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = module,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class,
            .hIconSm = null,
        };
        _ = w.RegisterClassExW(&wc);
        self.hwnd = w.CreateWindowExW(0, class, null, 0, 0, 0, 0, 0, w.HWND_MESSAGE, null, module, null);
        if (self.hwnd == null) self.init_error = "Presse-papiers indisponible : fenêtre propriétaire impossible à créer, réessaie.";
    }

    fn wndProc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
        return w.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    fn pump() void {
        var msg: w.MSG = undefined;
        while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
    }

    /// OpenClipboard, then `retries` more tries `retry_ms` apart. Sleep(10)
    /// lasts a whole 15.6 ms tick at the default timer resolution: a
    /// high-resolution waitable timer keeps the interval at 10 ms.
    fn open(self: *Clipboard) bool {
        var i: u32 = 0;
        while (true) : (i += 1) {
            if (w.OpenClipboard(self.hwnd) != 0) return true;
            if (i == retries) return false;
            self.pause();
        }
    }

    fn pause(self: *Clipboard) void {
        const due: i64 = -@as(i64, retry_ms) * 10_000; // relative, 100 ns units
        if (self.timer != null and w.SetWaitableTimer(self.timer, &due, 0, null, null, 0) != 0 and w.WaitForSingleObject(self.timer, retry_ms * 4) == w.WAIT_OBJECT_0) return;
        w.Sleep(retry_ms);
    }

    fn busy(self: *Clipboard) void {
        self.outcome = .busy;
        self.holder_pid = pidOf(w.GetOpenClipboardWindow());
    }

    fn fail(self: *Clipboard, msg: []const u8) void {
        self.outcome = .failed;
        self.failure = msg;
    }

    fn runRead(self: *Clipboard) void {
        self.owner_pid = 0;
        self.holder_pid = 0;
        if (!self.open()) return self.busy();
        defer _ = w.CloseClipboard();
        const owner = w.GetClipboardOwner();
        self.owner_pid = pidOf(owner);
        const own = owner != null and owner == self.hwnd and w.GetClipboardSequenceNumber() == self.own_seq;
        if (!own) if (self.secretMarker()) |m| {
            self.outcome = .secret;
            self.marker = m;
            return;
        };
        if (w.IsClipboardFormatAvailable(w.CF_UNICODETEXT) == 0) return self.listFormats();
        const h = w.GetClipboardData(w.CF_UNICODETEXT) orelse return self.fail("Presse-papiers illisible : l'application propriétaire n'a pas fourni le texte, réessaie.");
        const p = w.GlobalLock(h) orelse return self.fail("Presse-papiers illisible : réessaie.");
        defer _ = w.GlobalUnlock(h);
        const units = @as([*]const u16, @ptrCast(@alignCast(p)))[0 .. w.GlobalSize(h) / 2];
        var i: usize = 0;
        var chars: usize = 0;
        var copied: usize = 0;
        while (i < units.len and units[i] != 0) : (chars += 1) {
            const n: usize = if (std.unicode.utf16IsHighSurrogate(units[i]) and i + 1 < units.len and std.unicode.utf16IsLowSurrogate(units[i + 1])) 2 else 1;
            if (chars < self.max_chars) {
                @memcpy(self.text[copied..][0..n], units[i..][0..n]);
                copied += n;
            }
            i += n;
        }
        self.text_len = copied;
        self.total_chars = chars;
        self.outcome = .text;
    }

    /// The first secret format present, the `Can...` ones only at 0. One
    /// whose value cannot be read counts as set.
    fn secretMarker(self: *Clipboard) ?clipboard.Marker {
        inline for (@typeInfo(clipboard.Marker).@"enum".field_names, 0..) |name, i| {
            const m: clipboard.Marker = @field(clipboard.Marker, name);
            if (w.IsClipboardFormatAvailable(self.markers[i]) != 0) switch (m) {
                .exclude_monitor, .viewer_ignore => return m,
                .no_history, .no_cloud => if (!dwordIsNonZero(self.markers[i])) return m,
            };
        }
        return null;
    }

    fn dwordIsNonZero(format: u32) bool {
        const h = w.GetClipboardData(format) orelse return false;
        const p = w.GlobalLock(h) orelse return false;
        defer _ = w.GlobalUnlock(h);
        if (w.GlobalSize(h) < 4) return false;
        return @as(*align(1) const u32, @ptrCast(p)).* != 0;
    }

    fn listFormats(self: *Clipboard) void {
        self.format_count = 0;
        self.formats_total = 0;
        var id: u32 = 0;
        while (true) {
            id = w.EnumClipboardFormats(id);
            if (id == 0) break;
            if (self.format_count < max_formats) {
                self.format_ids[self.format_count] = id;
                self.format_count += 1;
            }
            self.formats_total += 1;
        }
        self.outcome = .no_text;
    }

    fn runWrite(self: *Clipboard) void {
        const mem = self.mem;
        self.mem = null;
        self.owner_pid = 0;
        self.holder_pid = 0;
        if (!self.open()) {
            _ = w.GlobalFree(mem);
            return self.busy();
        }
        if (w.EmptyClipboard() == 0) {
            _ = w.GlobalFree(mem);
            _ = w.CloseClipboard();
            return self.fail("Presse-papiers : Windows a refusé de le vider, réessaie.");
        }
        if (w.SetClipboardData(w.CF_UNICODETEXT, mem) == null) {
            _ = w.GlobalFree(mem);
            _ = w.CloseClipboard();
            return self.fail("Presse-papiers : Windows a refusé le texte, réessaie.");
        }
        // Without both markers the text would enter the history or the
        // cloud: take it out again.
        for ([_]clipboard.Marker{ .no_history, .no_cloud }) |m| {
            if (!setZero(self.markers[@backingInt(m)])) {
                _ = w.EmptyClipboard();
                _ = w.CloseClipboard();
                return self.fail("Presse-papiers : Windows a refusé l'exclusion de l'historique, texte retiré ; réessaie.");
            }
        }
        _ = w.CloseClipboard();
        self.own_seq = w.GetClipboardSequenceNumber();
        self.outcome = .text;
    }

    fn setZero(format: u32) bool {
        const h = w.GlobalAlloc(w.GMEM_MOVEABLE, 4) orelse return false;
        const p = w.GlobalLock(h) orelse {
            _ = w.GlobalFree(h);
            return false;
        };
        @as(*align(1) u32, @ptrCast(p)).* = 0;
        _ = w.GlobalUnlock(h);
        if (w.SetClipboardData(format, h) != null) return true;
        _ = w.GlobalFree(h);
        return false;
    }
};

const oom = "Mémoire insuffisante : réessaie.";

fn pidOf(hwnd: w.HWND) u32 {
    if (hwnd == null) return 0;
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    return pid;
}

fn pidOrNull(pid: u32) ?u32 {
    return if (pid == 0) null else pid;
}

/// `CF_HDROP`, a registered format's name, or the id in hexadecimal.
fn formatName(arena: std.mem.Allocator, id: u32) []const u8 {
    if (clipboard.standardName(id)) |n| return n;
    var wide: [128]u16 = undefined;
    const n = w.GetClipboardFormatNameW(id, @ptrCast(&wide), wide.len);
    if (n <= 0) return std.fmt.allocPrint(arena, "0x{x}", .{id}) catch "?";
    const buf = arena.alloc(u8, @as(usize, @intCast(n)) * 3) catch return "?";
    return buf[0..std.unicode.wtf16LeToWtf8(buf, wide[0..@intCast(n)])];
}
