//! Selftest window: a topmost window with one button, running its own
//! message loop on a dedicated thread. It records what it receives (clicks
//! in client pixels, characters, key downs, wheel deltas) and can repaint
//! itself in another color or switch its thread's keyboard layout on request.

const std = @import("std");
const w = @import("win32");

pub const button_label = "neo-compute selftest";
pub const title = "neo-compute selftest window";
pub const magenta: u32 = 0x00FF00FF; // COLORREF 0x00BBGGRR
pub const cyan: u32 = 0x00FFFF00;

const msg_set_color = w.WM_APP;
const msg_set_layout = w.WM_APP + 1;

var last_click: std.atomic.Value(u32) = .init(0xFFFF_FFFF);
var clicks: std.atomic.Value(u32) = .init(0);
var right_clicks: std.atomic.Value(u32) = .init(0);
var chars: [64]std.atomic.Value(u16) = @splat(.init(0));
var char_count: std.atomic.Value(u32) = .init(0);
var last_keydown: std.atomic.Value(u32) = .init(0);
var wheel: std.atomic.Value(i32) = .init(0);
var brush: w.HBRUSH = null;

pub const TestWindow = struct {
    hwnd: std.atomic.Value(usize) = .init(0),
    button: std.atomic.Value(usize) = .init(0),
    thread_id: std.atomic.Value(u32) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    rect: w.RECT,
    /// Creates the window DPI-unaware: Windows scales it and hands it
    /// logical coordinates, like a legacy app (calibration window).
    dpi_unaware: bool = false,
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
        clicks.store(0, .release);
        right_clicks.store(0, .release);
        char_count.store(0, .release);
        last_keydown.store(0, .release);
        wheel.store(0, .release);
    }

    /// Last left click in client pixels, if any.
    pub fn lastClick(_: *const TestWindow) ?[2]i32 {
        const v = last_click.load(.acquire);
        if (v == 0xFFFF_FFFF) return null;
        const x: i16 = @bitCast(@as(u16, @truncate(v)));
        const y: i16 = @bitCast(@as(u16, @truncate(v >> 16)));
        return .{ x, y };
    }

    pub fn clickCount(_: *const TestWindow) u32 {
        return clicks.load(.acquire);
    }

    pub fn rightClicks(_: *const TestWindow) u32 {
        return right_clicks.load(.acquire);
    }

    /// Characters received since the last reset (UTF-16 units).
    pub fn received(_: *const TestWindow, out: []u16) []u16 {
        const n = @min(char_count.load(.acquire), out.len, 64);
        for (0..n) |i| out[i] = charAt(i);
        return out[0..n];
    }

    /// Virtual key of the last WM_KEYDOWN, with bit 16 set when Ctrl was
    /// down at that moment.
    pub fn lastKeyDown(_: *const TestWindow) u32 {
        return last_keydown.load(.acquire);
    }

    pub fn wheelDelta(_: *const TestWindow) i32 {
        return wheel.load(.acquire);
    }

    pub fn setColor(self: *TestWindow, color: u32) void {
        _ = w.PostMessageW(self.window(), msg_set_color, color, 0);
    }

    /// Activates `layout` on the window's thread only.
    pub fn setLayout(self: *TestWindow, layout: w.HKL) void {
        _ = w.PostMessageW(self.window(), msg_set_layout, 0, @bitCast(@intFromPtr(layout)));
    }

    fn wndProc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
        switch (msg) {
            w.WM_LBUTTONDOWN => {
                last_click.store(@truncate(@as(usize, @bitCast(lparam))), .release);
                _ = clicks.fetchAdd(1, .acq_rel);
                return 0;
            },
            w.WM_RBUTTONDOWN => {
                _ = right_clicks.fetchAdd(1, .acq_rel);
                return 0;
            },
            w.WM_CHAR => {
                const i = char_count.fetchAdd(1, .acq_rel);
                if (i < 64) chars[i].store(@truncate(wparam), .release);
                return 0;
            },
            w.WM_KEYDOWN => {
                const ctrl: u32 = if (w.GetKeyState(w.VK_CONTROL) < 0) 1 << 16 else 0;
                last_keydown.store(@as(u32, @truncate(wparam)) | ctrl, .release);
                return w.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            w.WM_MOUSEWHEEL => {
                const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                _ = wheel.fetchAdd(delta, .acq_rel);
                return 0;
            },
            msg_set_color => {
                const old = brush;
                brush = w.CreateSolidBrush(@truncate(wparam));
                _ = w.DeleteObject(old);
                _ = w.InvalidateRect(hwnd, null, 1);
                return 0;
            },
            msg_set_layout => {
                _ = w.ActivateKeyboardLayout(@ptrFromInt(@as(usize, @bitCast(lparam))), 0);
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
        if (self.dpi_unaware) _ = w.SetThreadDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_UNAWARE);
        const instance = w.GetModuleHandleW(null);
        const class = std.unicode.utf8ToUtf16LeStringLiteral("NeoComputeSelftest");
        brush = w.CreateSolidBrush(magenta);
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
        // A regular (non-tool) window, so window_list reports it.
        const hwnd = w.CreateWindowExW(w.WS_EX_TOPMOST | w.WS_EX_APPWINDOW, class, std.unicode.utf8ToUtf16LeStringLiteral(title), w.WS_POPUP | w.WS_VISIBLE, r.left, r.top, r.right - r.left, r.bottom - r.top, null, null, instance, null);
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

fn charAt(i: usize) u16 {
    return chars[i].load(.acquire);
}
