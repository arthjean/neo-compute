//! Selftest window: a topmost magenta popup with one button, running its own
//! message loop on a dedicated thread. It records the last left click
//! (client pixels) and the last character it received.

const std = @import("std");
const w = @import("win32");

pub const button_label = "neo-compute selftest";
pub const color: u32 = 0x00FF00FF; // COLORREF 0x00BBGGRR: magenta

var last_click: std.atomic.Value(u32) = .init(0xFFFF_FFFF);
var last_char: std.atomic.Value(u32) = .init(0);
var brush: w.HBRUSH = null;

pub const TestWindow = struct {
    hwnd: std.atomic.Value(usize) = .init(0),
    button: std.atomic.Value(usize) = .init(0),
    thread_id: std.atomic.Value(u32) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    rect: w.RECT,
    thread: ?std.Thread = null,

    pub fn start(self: *TestWindow) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        while (!self.ready.load(.acquire)) w.Sleep(1);
        if (self.failed.load(.acquire)) return error.WindowCreationFailed;
    }

    pub fn stop(self: *TestWindow) void {
        if (self.hwnd.load(.acquire) != 0) _ = w.PostMessageW(self.window(), w.WM_CLOSE, 0, 0);
        if (self.thread) |t| t.join();
    }

    pub fn window(self: *const TestWindow) w.HWND {
        return @ptrFromInt(self.hwnd.load(.acquire));
    }

    pub fn buttonWindow(self: *const TestWindow) w.HWND {
        return @ptrFromInt(self.button.load(.acquire));
    }

    pub fn resetEvents(_: *TestWindow) void {
        last_click.store(0xFFFF_FFFF, .release);
        last_char.store(0, .release);
    }

    /// Last click in client pixels, if any.
    pub fn lastClick(_: *const TestWindow) ?[2]i32 {
        const v = last_click.load(.acquire);
        if (v == 0xFFFF_FFFF) return null;
        const x: i16 = @bitCast(@as(u16, @truncate(v)));
        const y: i16 = @bitCast(@as(u16, @truncate(v >> 16)));
        return .{ x, y };
    }

    pub fn lastChar(_: *const TestWindow) u32 {
        return last_char.load(.acquire);
    }

    fn wndProc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
        switch (msg) {
            w.WM_LBUTTONDOWN => {
                last_click.store(@truncate(@as(usize, @bitCast(lparam))), .release);
                return 0;
            },
            w.WM_CHAR => {
                last_char.store(@truncate(wparam), .release);
                return 0;
            },
            w.WM_PAINT => {
                var ps: w.PAINTSTRUCT = undefined;
                const hdc = w.BeginPaint(hwnd, &ps);
                _ = w.FillRect(hdc, &ps.rcPaint, brush);
                _ = w.EndPaint(hwnd, &ps);
                return 0;
            },
            w.WM_DESTROY => {
                w.PostQuitMessage(0);
                return 0;
            },
            else => return w.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    fn run(self: *TestWindow) void {
        const instance = w.GetModuleHandleW(null);
        const class = std.unicode.utf8ToUtf16LeStringLiteral("NeoComputeSelftest");
        brush = w.CreateSolidBrush(color);
        const wc: w.WNDCLASSEXW = .{
            .cbSize = @sizeOf(w.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class,
            .hIconSm = null,
        };
        _ = w.RegisterClassExW(&wc);
        const r = self.rect;
        const hwnd = w.CreateWindowExW(w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW, class, class, w.WS_POPUP | w.WS_VISIBLE, r.left, r.top, r.right - r.left, r.bottom - r.top, null, null, instance, null);
        const button = w.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral(button_label), w.WS_CHILD | w.WS_VISIBLE, 20, 20, 200, 40, hwnd, null, instance, null);
        if (hwnd == null or button == null) {
            self.failed.store(true, .release);
            self.ready.store(true, .release);
            return;
        }
        _ = w.UpdateWindow(hwnd);
        self.hwnd.store(@intFromPtr(hwnd), .release);
        self.button.store(@intFromPtr(button), .release);
        self.thread_id.store(w.GetCurrentThreadId(), .release);
        self.ready.store(true, .release);
        var msg: w.MSG = undefined;
        while (w.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        _ = w.DeleteObject(brush);
    }
};
