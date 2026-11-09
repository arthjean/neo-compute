//! Selftest fixture for US-033: a layered, topmost, click-through popup of
//! one solid color, on a thread of its own, whose display affinity, color
//! and visibility the selftest changes while it captures the area by DXGI
//! and by GDI. It answers whether `WDA_EXCLUDEFROMCAPTURE` hides a window
//! from both captures and whether repainting an excluded window produces
//! DXGI dirty rects (assumption A8), before the control indicator is
//! designed on that answer (decision 0011).

const std = @import("std");
const w = @import("win32");

pub const class_name = "NeoComputeExclusionProbe";
/// Probe colors, COLORREF 0x00BBGGRR: amber and green, both far from the
/// test window's magenta and cyan.
pub const amber: u32 = 0x0000A5FF;
pub const green: u32 = 0x0000C000;

const msg_color = w.WM_APP;
const msg_show = w.WM_APP + 1;

var brush: w.HBRUSH = null;

pub const Probe = struct {
    rect: w.RECT,
    hwnd: std.atomic.Value(usize) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *Probe) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        while (!self.ready.load(.acquire)) w.Sleep(1);
        if (self.failed.load(.acquire)) return error.WindowCreationFailed;
    }

    pub fn stop(self: *Probe) void {
        if (self.hwnd.load(.acquire) != 0) _ = w.PostMessageW(self.window(), w.WM_CLOSE, 0, 0);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn window(self: *const Probe) w.HWND {
        return @ptrFromInt(self.hwnd.load(.acquire));
    }

    /// `WDA_NONE` or `WDA_EXCLUDEFROMCAPTURE`; null on success, else the
    /// Win32 error code.
    pub fn setAffinity(self: *Probe, value: w.WINDOW_DISPLAY_AFFINITY) ?u32 {
        if (w.SetWindowDisplayAffinity(self.window(), value) != 0) return null;
        return w.GetLastError();
    }

    /// The affinity Windows reports for the window.
    pub fn affinity(self: *const Probe) ?u32 {
        var a: u32 = 0;
        if (w.GetWindowDisplayAffinity(self.window(), &a) == 0) return null;
        return a;
    }

    /// Repaints the window in `color`, on its thread.
    pub fn setColor(self: *Probe, color: u32) void {
        _ = w.PostMessageW(self.window(), msg_color, color, 0);
    }

    /// Shows the window without activating it, or hides it.
    pub fn show(self: *Probe, on: bool) void {
        _ = w.PostMessageW(self.window(), msg_show, @intFromBool(on), 0);
    }

    fn wndProc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
        switch (msg) {
            msg_color => {
                const old = brush;
                brush = w.CreateSolidBrush(@truncate(wparam));
                _ = w.DeleteObject(old);
                _ = w.InvalidateRect(hwnd, null, 0);
                return 0;
            },
            msg_show => {
                _ = w.ShowWindow(hwnd, if (wparam != 0) w.SW_SHOWNOACTIVATE else w.SW_HIDE);
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

    fn run(self: *Probe) void {
        const instance = w.GetModuleHandleW(null);
        const class = std.unicode.utf8ToUtf16LeStringLiteral(class_name);
        brush = w.CreateSolidBrush(amber);
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
        // The indicator's styles: layered and transparent to clicks, so
        // the test window under it keeps its input.
        const ex = w.WS_EX_LAYERED | w.WS_EX_TRANSPARENT | w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE;
        const hwnd = w.CreateWindowExW(ex, class, std.unicode.utf8ToUtf16LeStringLiteral("neo-compute exclusion probe"), w.WS_POPUP, r.left, r.top, r.right - r.left, r.bottom - r.top, null, null, instance, null);
        if (hwnd == null or w.SetLayeredWindowAttributes(hwnd, 0, 255, w.LWA_ALPHA) == 0) {
            self.failed.store(true, .release);
            self.ready.store(true, .release);
            return;
        }
        _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
        _ = w.UpdateWindow(hwnd);
        self.hwnd.store(@intFromPtr(hwnd), .release);
        self.ready.store(true, .release);
        var msg: w.MSG = undefined;
        while (w.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        _ = w.DeleteObject(brush);
        brush = null;
    }
};
