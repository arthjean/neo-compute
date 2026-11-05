//! Selftest window: a topmost window with one button, a password field and
//! a trackbar (US-022), and on request a popup menu (US-023),
//! running its own message loop on a dedicated thread. It records what it
//! receives (clicks in client pixels, characters, key downs, wheel deltas,
//! button commands) and on request repaints itself in another color,
//! switches its thread's keyboard layout, animates (a repaint every 15 ms)
//! or stops answering for a while.

const std = @import("std");
const w = @import("win32");

pub const button_label = "neo-compute selftest";
pub const title = "neo-compute selftest window";
pub const magenta: u32 = 0x00FF00FF; // COLORREF 0x00BBGGRR
pub const cyan: u32 = 0x00FFFF00;
/// Initial text of the password field: must never appear in any output.
pub const secret = "hunter2-selftest";

const msg_set_color = w.WM_APP;
const msg_set_layout = w.WM_APP + 1;
const msg_animate = w.WM_APP + 2;
const msg_hang = w.WM_APP + 3;
const msg_menu = w.WM_APP + 4;
const msg_select = w.WM_APP + 5;

/// Text of the plain edit field, and the part `select` selects (US-022).
pub const note_text = "neo-compute selection";
pub const note_selected = "compute";

/// Trackbar range and position (US-022).
pub const slider_min = 0;
pub const slider_max = 100;
pub const slider_pos = 40;
pub const menu_items = [_][]const u8{ "neo-compute menu copy", "neo-compute menu paste" };
const menu_first_id = 100;
const animation_timer = 1;

var last_click: std.atomic.Value(u32) = .init(0xFFFF_FFFF);
var clicks: std.atomic.Value(u32) = .init(0);
var right_clicks: std.atomic.Value(u32) = .init(0);
var chars: [64]std.atomic.Value(u16) = @splat(.init(0));
var char_count: std.atomic.Value(u32) = .init(0);
var last_keydown: std.atomic.Value(u32) = .init(0);
var wheel: std.atomic.Value(i32) = .init(0);
var commands: std.atomic.Value(u32) = .init(0);
/// Item chosen in the last popup menu (0: none, or still open).
var menu_choice: std.atomic.Value(u32) = .init(0);
var menu_open: std.atomic.Value(bool) = .init(false);
var brush: w.HBRUSH = null;
var frame_parity: bool = false;

pub const TestWindow = struct {
    hwnd: std.atomic.Value(usize) = .init(0),
    button: std.atomic.Value(usize) = .init(0),
    password: std.atomic.Value(usize) = .init(0),
    note: std.atomic.Value(usize) = .init(0),
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

    pub fn passwordWindow(self: *const TestWindow) w.HWND {
        return @ptrFromInt(self.password.load(.acquire));
    }

    /// BN_CLICKED notifications from the button (UIA Invoke lands here).
    pub fn commandCount(_: *const TestWindow) u32 {
        return commands.load(.acquire);
    }

    /// Starts or stops repainting in alternating colors every 15 ms.
    pub fn animate(self: *TestWindow, on: bool) void {
        _ = w.PostMessageW(self.window(), msg_animate, @intFromBool(on), 0);
    }

    /// Opens a popup menu at screen point (x, y) on the window's thread,
    /// which runs the menu loop until an item is chosen or the menu closes.
    pub fn openMenu(self: *TestWindow, x: i32, y: i32) void {
        menu_choice.store(0, .release);
        menu_open.store(true, .release);
        _ = w.PostMessageW(self.window(), msg_menu, @as(u32, @bitCast(x)), @as(isize, y));
    }

    pub fn menuOpen(_: *const TestWindow) bool {
        return menu_open.load(.acquire);
    }

    /// 1-based index of the item chosen in the last menu, 0 for none.
    pub fn menuChoice(_: *const TestWindow) u32 {
        return menu_choice.load(.acquire);
    }

    /// Focuses the plain edit field and selects `note_selected` in it
    /// (`on`), or gives the focus back to the window.
    pub fn select(self: *TestWindow, on: bool) void {
        _ = w.PostMessageW(self.window(), msg_select, @intFromBool(on), @bitCast(self.note.load(.acquire)));
    }

    /// Makes the window's thread stop answering messages for `ms`.
    pub fn hang(self: *TestWindow, ms: u32) void {
        _ = w.PostMessageW(self.window(), msg_hang, ms, 0);
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
            w.WM_COMMAND => {
                if ((wparam >> 16) & 0xFFFF == w.BN_CLICKED) _ = commands.fetchAdd(1, .acq_rel);
                return 0;
            },
            msg_animate => {
                if (wparam != 0) {
                    _ = w.SetTimer(hwnd, animation_timer, 15, null);
                } else {
                    _ = w.KillTimer(hwnd, animation_timer);
                    _ = w.PostMessageW(hwnd, msg_set_color, magenta, 0);
                }
                return 0;
            },
            w.WM_TIMER => {
                frame_parity = !frame_parity;
                _ = w.PostMessageW(hwnd, msg_set_color, if (frame_parity) cyan else magenta, 0);
                return 0;
            },
            msg_menu => {
                const menu = w.CreatePopupMenu();
                for (menu_items, 0..) |item, i| {
                    var wide: [64:0]u16 = undefined;
                    const n = std.unicode.utf8ToUtf16Le(&wide, item) catch 0;
                    wide[n] = 0;
                    _ = w.AppendMenuW(menu, w.MF_STRING, menu_first_id + i, &wide);
                }
                _ = w.SetForegroundWindow(hwnd);
                const x: i32 = @bitCast(@as(u32, @truncate(wparam)));
                const y: i32 = @intCast(lparam);
                const chosen = w.TrackPopupMenu(menu, w.TPM_RETURNCMD, x, y, 0, hwnd, null);
                if (chosen >= menu_first_id) menu_choice.store(@intCast(chosen - menu_first_id + 1), .release);
                _ = w.DestroyMenu(menu);
                menu_open.store(false, .release);
                return 0;
            },
            msg_select => {
                const note: w.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (wparam != 0) {
                    _ = w.SetFocus(note);
                    const at = std.mem.indexOf(u8, note_text, note_selected).?;
                    _ = w.SendMessageW(note, w.EM_SETSEL, at, @intCast(at + note_selected.len));
                } else _ = w.SetFocus(hwnd);
                return 0;
            },
            msg_hang => {
                w.Sleep(@truncate(wparam));
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
        const password = w.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), std.unicode.utf8ToUtf16LeStringLiteral(secret), w.WS_CHILD | w.WS_VISIBLE | w.WS_BORDER | @as(u32, @intCast(w.ES_PASSWORD)), 20, 80, 200, 28, hwnd, null, instance, null);
        const icc: w.INITCOMMONCONTROLSEX = .{ .dwSize = @sizeOf(w.INITCOMMONCONTROLSEX), .dwICC = w.ICC_BAR_CLASSES };
        _ = w.InitCommonControlsEx(&icc);
        const slider = w.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("msctls_trackbar32"), std.unicode.utf8ToUtf16LeStringLiteral("neo-compute slider"), w.WS_CHILD | w.WS_VISIBLE, 260, 20, 180, 30, hwnd, null, instance, null);
        if (slider != null) {
            _ = w.SendMessageW(slider, w.TBM_SETRANGE, 1, (slider_max << 16) | slider_min);
            _ = w.SendMessageW(slider, w.TBM_SETPOS, 1, slider_pos);
        }
        // RichEdit implements TextPattern itself; the Win32 EDIT proxy does
        // not expose it.
        _ = w.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("msftedit.dll"));
        const note = w.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("RICHEDIT50W"), std.unicode.utf8ToUtf16LeStringLiteral(note_text), w.WS_CHILD | w.WS_VISIBLE | w.WS_BORDER, 260, 60, 180, 24, hwnd, null, instance, null);
        if (hwnd == null or button == null or password == null or slider == null or note == null) {
            self.failed.store(true, .release);
            self.ready.store(true, .release);
            return;
        }
        _ = w.UpdateWindow(hwnd);
        self.hwnd.store(@intFromPtr(hwnd), .release);
        self.button.store(@intFromPtr(button), .release);
        self.password.store(@intFromPtr(password), .release);
        self.note.store(@intFromPtr(note), .release);
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
