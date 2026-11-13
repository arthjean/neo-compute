//! In-memory backend for testing the portable core on any OS. It records
//! every input it receives and serves synthetic displays and windows.

const std = @import("std");
const display = @import("../core/display.zig");
const input = @import("../core/input.zig");
const keys = @import("../core/keys.zig");
const uitree = @import("../core/uitree.zig");
const Control = @import("../core/control.zig").Control;
const guard = @import("../core/guard.zig");
const apps = @import("../core/apps.zig");
const clipboard = @import("../core/clipboard.zig");
const regread = @import("../core/regread.zig");

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

/// Inside the fixture window, which settling watches.
const animation_rect = [_]display.Rect{.{ .x = 200, .y = 200, .w = 32, .h = 32 }};

/// Notepad-like tree on the primary display (physical pixels).
pub const ui_fixture = [_]uitree.Element{
    .{ .key = 100, .depth = 0, .role = .window, .name = "Sans titre - Bloc-notes", .rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 } },
    .{ .key = 101, .depth = 1, .role = .pane, .rect = .{ .x = 100, .y = 80, .w = 1200, .h = 800 } },
    .{ .key = 102, .depth = 2, .role = .menubar, .name = "Application", .rect = .{ .x = 100, .y = 120, .w = 1200, .h = 40 } },
    .{ .key = 103, .depth = 3, .role = .menuitem, .name = "Fichier", .states = .{ .collapsed = true }, .actions = .{ .expand_collapse = true }, .rect = .{ .x = 110, .y = 124, .w = 80, .h = 32 } },
    .{ .key = 104, .depth = 3, .role = .menuitem, .name = "Édition", .states = .{ .collapsed = true }, .actions = .{ .expand_collapse = true }, .rect = .{ .x = 200, .y = 124, .w = 80, .h = 32 } },
    .{ .key = 105, .depth = 2, .role = .edit, .name = "Éditeur de texte", .value = "Bonjour \"monde\"", .states = .{ .focused = true }, .actions = .{ .value = true }, .rect = .{ .x = 100, .y = 160, .w = 1200, .h = 680 } },
    .{ .key = 106, .depth = 2, .role = .edit, .name = "Mot de passe", .value = "hunter2", .password = true, .actions = .{ .value = true }, .rect = .{ .x = 100, .y = 840, .w = 400, .h = 30 } },
    .{ .key = 107, .depth = 2, .role = .button, .name = "Enregistrer", .actions = .{ .invoke = true }, .rect = .{ .x = 1100, .y = 840, .w = 100, .h = 30 } },
    .{ .key = 108, .depth = 2, .role = .checkbox, .name = "Retour automatique à la ligne", .states = .{ .checked = true }, .actions = .{ .toggle = true }, .rect = .{ .x = 600, .y = 840, .w = 300, .h = 30 } },
    .{ .key = 109, .depth = 2, .role = .button, .name = "Imprimer", .states = .{ .disabled = true }, .actions = .{ .invoke = true }, .rect = .{ .x = 950, .y = 840, .w = 100, .h = 30 } },
    .{ .key = 110, .depth = 2, .role = .text, .name = "Ligne 1, colonne 1", .rect = .{ .x = 100, .y = 870, .w = 200, .h = 10 } },
    .{ .key = 111, .depth = 2, .role = .listitem, .name = "Hors champ", .states = .{ .offscreen = true }, .actions = .{ .select = true, .scroll = true }, .rect = .{ .x = 100, .y = 5000, .w = 200, .h = 20 } },
};

/// An element a pattern call changed, and the hash of the value written to
/// it.
pub const Changed = struct { el: uitree.Element, value_hash: ?u64 = null };

pub const KeyCall = struct { combo: keys.Combo, action: input.KeyAction };

/// A root served with the foreground tree: its window and its elements
/// (the first at depth 0).
pub const ExtraRoot = struct { window: uitree.RootWindow, modal: bool = false, elements: []const uitree.Element };

/// A registry key of the fixture: its path as `Path.text` writes it.
pub const RegKey = struct {
    path: []const u8,
    values: []const regread.Value = &.{},
    subkeys: []const []const u8 = &.{},
    denied: bool = false,
};

fn utf16Bytes(comptime s: []const u8) []const u8 {
    const u = std.unicode.utf8ToUtf16LeStringLiteral(s);
    return std.mem.sliceAsBytes(u[0 .. u.len + 1]);
}

pub const reg_fixture = [_]RegKey{
    .{
        .path = "HKCU\\Software\\Microsoft\\Notepad",
        .values = &.{
            .{ .name = "fWrap", .kind = .dword, .data = &.{ 1, 0, 0, 0 }, .size = 4 },
            .{ .name = "lfFaceName", .kind = .sz, .data = utf16Bytes("Consolas"), .size = 18 },
            .{ .name = "ProxyPassword", .kind = .sz, .data = utf16Bytes("hunter2"), .size = 16 },
        },
        .subkeys = &.{ "Recent", "Tabs" },
    },
    .{
        .path = "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",
        .values = &.{
            .{ .name = "ProductName", .kind = .sz, .data = utf16Bytes("Windows 11 Pro"), .size = 30 },
            .{ .name = "SystemRoot", .kind = .expand_sz, .data = utf16Bytes("%SystemDrive%\\WINDOWS"), .size = 44, .expanded = "C:\\WINDOWS" },
        },
    },
    .{ .path = "HKLM\\SOFTWARE\\Verrou", .denied = true },
};

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
    /// Every capture reports a dirty rect, like a video or a spinner.
    animating: bool = false,
    /// `gdi`: frames as the BitBlt fallback returns them (US-032), fresh and
    /// without dirty rects; an animation changes a pixel of the window.
    capture_source: display.Frame.Source = .dxgi,
    /// US-030: from this capture on, `ui_elements` becomes
    /// `appear_elements` and that capture reports a dirty rect over the
    /// window, as a button that shows up and paints itself.
    appear_at_capture: ?u32 = null,
    appear_elements: []const uitree.Element = &.{},
    /// US-030: at this window stamp read, `ui_elements` becomes
    /// `appear_elements` and `appear_windows` the top-level windows, as a
    /// dialog that opens in a window of its own.
    appear_at_stamp: ?u32 = null,
    appear_windows: []const display.WindowInfo = &.{},
    stamp_calls: u32 = 0,
    /// GDI looks for changes that copied a window's area only (US-032).
    gdi_area_looks: u32 = 0,

    // Change events of a window's process (US-048, US-049): the simulated
    // source the background mode settles and waits on.
    /// Windows refused the event hook: `windowEvents` answers null.
    events_refused: bool = false,
    event_reads: u32 = 0,
    event_stamp: u64 = 0,
    /// Reads that still see a new event: a target that changes for a while.
    events_pending: u32 = 0,
    /// Every read sees a new event and every snapshot a new tree: a target
    /// that never rests.
    events_churn: bool = false,
    /// At this read an event arrives and `ui_elements` becomes
    /// `appear_elements`: a control that shows up, or goes.
    appear_at_event: ?u32 = null,
    /// At this read the request is cancelled, as a `notifications/cancelled`
    /// during the wait would.
    cancel_at_event: ?u32 = null,
    // Foreground guard (US-050).
    /// The window that takes the foreground when a pattern runs, as a
    /// dialog the action opens.
    foreground_after_act: ?u64 = null,
    /// Whether the hooks saw a gesture of the user that can change the
    /// foreground window (a click outside their window, Alt+Tab); null: no
    /// hooks.
    gesture: ?bool = false,
    /// The user makes such a gesture while the pattern runs.
    gesture_on_act: bool = false,
    /// False: the foreground event never reaches the guard (hook refused),
    /// so only the look after the action restores.
    foreground_events: bool = true,
    /// The dialog takes the foreground again after each restoration.
    steals_again: bool = false,
    restore_refused: bool = false,
    restores: u32 = 0,
    restored_to: ?u64 = null,
    /// Reads of the change events (settling) done when the guard first
    /// restored: 0 means before settling began.
    restored_at_event_read: ?u32 = null,
    guard_watch: ?*guard.Watch = null,
    /// How long the guard was last left armed after an action.
    lingered_ms: ?u32 = null,
    /// What `treeObserved` was last told, and how many times it was called.
    observed_window: u64 = 0,
    observed_changed: ?bool = null,
    observations: u32 = 0,

    /// At this read the target window closes, with an event.
    close_at_event: ?u32 = null,
    /// At this read the user presses the pause shortcut (US-045).
    pause_at_event: ?u32 = null,

    /// Accessibility tree served by uiSnapshot; tests replace it.
    ui_window: u64 = 0x1a2b,
    ui_elements: []const uitree.Element = &ui_fixture,
    ui_partial: bool = false,
    ui_desktop: bool = false,
    ui_web_pending: bool = false,
    /// A Firefox window with its accessibility off (US-025).
    ui_firefox_no_tree: bool = false,
    /// The foreground root is modal (US-023).
    ui_modal: bool = false,
    /// Served in place of `ui_elements` when the text of a web page is
    /// requested (US-024); null: the window has no web document.
    ui_web: ?[]const uitree.Element = null,
    ui_page: ?uitree.Page = null,
    /// Menus, popups and owned windows listed with the foreground window
    /// (US-023); tests set them.
    ui_extra: []const ExtraRoot = &.{},
    /// Extra roots requested by the last snapshot.
    ui_requested: usize = 0,
    ui_snapshots: u32 = 0,
    /// Last pattern call received, and every one since the test began.
    ui_last_op: ?struct { key: u64, op: std.meta.Tag(uitree.Op), value_len: usize } = null,
    ui_ops: [64]struct { key: u64, op: std.meta.Tag(uitree.Op) } = undefined,
    ui_op_len: usize = 0,
    /// Elements as the pattern calls left them (EP-013): read by `uiLive`
    /// and served by the next snapshot.
    ui_changed: [32]Changed = undefined,
    ui_changed_len: usize = 0,
    /// The states a Toggle call goes through, in order.
    ui_toggle_cycle: []const uitree.Toggle = &.{ .off, .on },
    /// Pattern calls succeed and change nothing: an application that
    /// ignores them.
    ui_stuck: bool = false,
    /// The application rewrites the value it is given.
    ui_reformat: bool = false,
    /// Elements with an MSAA default action.
    ui_legacy: []const u64 = &.{},
    /// At this live read, the element read becomes enabled.
    ui_enable_at_read: ?u32 = null,
    ui_live_reads: u32 = 0,
    /// At this live read the request is cancelled, or the user presses the
    /// pause shortcut.
    ui_cancel_at_read: ?u32 = null,
    ui_pause_at_read: ?u32 = null,
    /// At this read of a container's entries the user presses the pause
    /// shortcut.
    ui_pause_at_entries: ?u32 = null,
    ui_entry_reads: u32 = 0,
    /// Live reads that asked for the element's value.
    ui_value_reads: u32 = 0,
    /// Percent one scroll notch moves a container; a page moves five.
    ui_scroll_step: f32 = 10,
    /// An element out of view until its scrollable ancestor reaches `at`
    /// percent.
    ui_reveal: ?struct { key: u64, at: f32 } = null,
    /// A container lists its entries only while expanded.
    ui_entries_when_open: bool = false,
    /// A container's entries cannot be read while it is expanded.
    ui_entries_fail_open: bool = false,
    /// A collapse drops the selection made while the container was open,
    /// as a Win32 drop-down list does.
    ui_collapse_cancels: bool = false,

    /// Top-level windows, top of the z-order first; tests replace them.
    windows: []const display.WindowInfo = &windows_fixture,
    /// IVirtualDesktopManager answers (false: Explorer restarted, US-026).
    virtual_desktops: bool = true,

    // window_set (US-027)
    /// Windows closed (or whose process ended) since the test started.
    gone_buf: [16]u64 = undefined,
    gone_len: usize = 0,
    placed: ?display.Rect = null,
    shown: ?display.ShowState = null,
    set_calls: u32 = 0,
    close_calls: u32 = 0,
    /// What a close request does: close the window, open a save dialog, or
    /// nothing (a window that ignores it).
    on_close: enum { closes, dialog, stays } = .closes,
    /// The smallest frame the application accepts.
    min_size: ?[2]i32 = null,
    hung: bool = false,
    /// neo-compute's pid and its ancestors.
    ancestors: []const u32 = &.{ 9000, 8000 },
    terminated: ?u32 = null,
    dead_pids: []const u32 = &.{},
    /// UWP frames and the pid of the application each hosts.
    hosted: []const struct { u64, u32 } = &.{},

    // app_launch (US-028, US-029)
    catalog: []const apps.App = &apps.fixture,
    catalog_calls: u32 = 0,
    /// Shortcut targets `appExe` resolves: AUMID and executable.
    shortcut_targets: []const struct { []const u8, []const u8 } = &.{},
    exe_lookups: u32 = 0,
    launched: ?apps.App = null,
    launch_calls: u32 = 0,
    /// How the last launch asked its window to show (US-043).
    launch_show: ?apps.Show = null,
    /// UI Automation AutoSetFocus as the server last set it (US-041).
    auto_focus: bool = true,
    /// Calls that asked which window is in the foreground to work on it
    /// (US-042): the background mode makes none.
    foreground_reads: u32 = 0,
    /// Calls of `foregroundWindow`, which only compares the foreground
    /// before and after a launch (US-043).
    foreground_checks: u32 = 0,
    /// The foreground window `foregroundWindow` reports, and the one it
    /// reports once a launch ran (an application that came in front).
    foreground_window: ?u64 = null,
    foreground_after_launch: ?u64 = null,
    /// The one it reports once showWindow ran (a maximize that activates).
    foreground_after_show: ?u64 = null,
    /// Reads of `foregroundWindow` that find no window once a launch ran:
    /// Windows names none while it switches from one window to the next.
    switching_after_launch: u32 = 0,
    foreground_switching: u32 = 0,
    /// `activate` of the last placeWindow or showWindow, and the calls
    /// that asked to activate.
    last_activate: ?bool = null,
    activations: u32 = 0,
    launch_result: apps.Launch = .{ .ok = 7000 },
    /// The windows once the launch happened (the new window among them).
    after_launch: ?[]const display.WindowInfo = null,
    /// Set on launch, as `notifications/cancelled` would during the wait.
    cancel_on_launch: ?*std.atomic.Value(bool) = null,
    opened_buf: [256]u8 = undefined,
    opened_len: usize = 0,
    files: []const []const u8 = &.{ "C:\\Users\\arthur\\notes.txt", "C:\\Users\\arthur\\coffre.kdbx", "C:\\Users\\arthur\\script.ps1" },
    folders: []const []const u8 = &.{"C:\\Users\\arthur"},
    /// 8.3 names and the long paths they resolve to.
    short_names: []const [2][]const u8 = &.{
        .{ "C:\\Users\\arthur\\DEPLOY~1.APP", "C:\\Users\\arthur\\deploy.appref-ms" },
        .{ "C:\\Users\\arthur\\MODULE~1.PSM", "C:\\Users\\arthur\\module.psm1" },
        .{ "C:\\Users\\arthur\\jeu.pif", "C:\\Users\\arthur\\jeu.pif" },
        .{ "C:\\Users\\arthur\\meteo.gadget", "C:\\Users\\arthur\\meteo.gadget" },
    },
    path_lookups: u32 = 0,
    /// Executable name lookups (the policy caches them per window).
    process_lookups: u32 = 0,
    /// Processes without a top-level window of their own (the application
    /// a UWP frame hosts): pid and executable.
    processes: []const struct { u32, []const u8 } = &.{},
    /// Password scans started by screenshot and zoom (US-019).
    secret_scans: u32 = 0,
    secret_buf: [16]display.Rect = undefined,
    /// Kill switch state handed over by the server (US-018).
    control: ?*Control = null,
    /// Trips the kill switch on the next key press, as a physical Escape
    /// during the action would.
    trip_on_press: bool = false,

    // clipboard (US-035)
    /// Text content (null: no CF_UNICODETEXT) and the other formats.
    clip_text: ?[]const u8 = null,
    clip_formats: []const []const u8 = &.{},
    /// A secret format the content carries.
    clip_marker: ?clipboard.Marker = null,
    clip_owner: ?u32 = null,
    /// Another process keeps the clipboard open through every retry.
    clip_busy: ?u32 = null,
    clip_reads: u32 = 0,
    clip_writes: u32 = 0,
    /// Bytes of the last text written, and its first ones.
    clip_written_len: usize = 0,
    clip_written: [4096]u8 = undefined,

    // registry_read (US-036)
    reg_keys: []const RegKey = &reg_fixture,
    reg_reads: u32 = 0,

    pub fn releaseAllInputs(self: *Fake) void {
        self.held = 0;
        self.release_calls += 1;
    }

    pub fn displays(self: *Fake) []const display.Display {
        return displays_fixture[0..self.displays_len];
    }

    /// Primary display, DPI and work area (the taskbar takes 48 px at the
    /// bottom of the primary display).
    pub fn displayInfo(self: *Fake, index: usize) display.DisplayInfo {
        _ = self;
        const r = displays_fixture[index].rect;
        if (index == 0) return .{ .primary = true, .dpi = 192, .work = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h - 96 } };
        return .{ .primary = false, .dpi = 96, .work = r };
    }

    pub fn foregroundDisplay(self: *Fake) ?usize {
        self.foreground_reads += 1;
        return self.foreground;
    }

    /// The foreground window, to tell whether it changed (never to act on
    /// it).
    pub fn foregroundWindow(self: *Fake) ?u64 {
        self.foreground_checks += 1;
        if (self.foreground_switching > 0) {
            self.foreground_switching -= 1;
            return null;
        }
        return self.foreground_window;
    }

    pub fn capture(self: *Fake, index: usize, arena: std.mem.Allocator) display.CaptureResult {
        _ = arena;
        if (self.capture_failure) |msg| return .{ .failed = msg };
        fillFrames();
        const d = displays_fixture[index];
        const buf: []const u8 = if (index == 0) &frame0 else &frame1;
        self.capture_calls += 1;
        var appeared = false;
        if (self.appear_at_capture) |n| if (self.capture_calls == n) {
            self.ui_elements = self.appear_elements;
            appeared = true;
        };
        if (self.capture_source == .gdi) {
            if (self.animating or appeared) frame0[(200 * 2560 + 200) * 4] +%= 1;
            return .{ .frame = .{ .pixels = buf, .width = @intCast(d.rect.w), .height = @intCast(d.rect.h), .stride = @as(usize, @intCast(d.rect.w)) * 4, .source = .gdi } };
        }
        return .{ .frame = .{
            .pixels = buf,
            .width = @intCast(d.rect.w),
            .height = @intCast(d.rect.h),
            .stride = @as(usize, @intCast(d.rect.w)) * 4,
            .fresh = self.capture_calls == 1 or self.animating or appeared,
            .dirty = if (self.animating or appeared) &animation_rect else &.{},
        } };
    }

    /// Changes since the last look: the fixture's frames are always in
    /// memory, so a capture. Under GDI, like the Windows backend, only
    /// `area` clipped to the display (US-032).
    pub fn changes(self: *Fake, index: usize, arena: std.mem.Allocator, area: ?display.Rect) display.CaptureResult {
        const r = self.capture(index, arena);
        if (r != .frame or r.frame.source != .gdi) return r;
        const d = displays_fixture[index].rect;
        const a = area orelse return r;
        const x0 = std.math.clamp(a.x, d.x, d.right());
        const y0 = std.math.clamp(a.y, d.y, d.bottom());
        const x1 = std.math.clamp(a.right(), d.x, d.right());
        const y1 = std.math.clamp(a.bottom(), d.y, d.bottom());
        if (x1 <= x0 or y1 <= y0) return r;
        var f = r.frame;
        const offset = @as(usize, @intCast(y0 - d.y)) * f.stride + @as(usize, @intCast(x0 - d.x)) * 4;
        f.pixels = f.pixels[offset..];
        f.width = @intCast(x1 - x0);
        f.height = @intCast(y1 - y0);
        f.area = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
        self.gdi_area_looks += 1;
        return .{ .frame = f };
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
        if (action == .press and self.trip_on_press) if (self.control) |c| {
            self.trip_on_press = false;
            _ = c.trip();
        };
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

    /// Windows on another virtual desktop are `other_desktop` in the
    /// fixtures; without IVirtualDesktopManager (Explorer restarted) the
    /// Windows backend reports them as plain `cloaked` (US-026).
    pub fn listWindows(self: *Fake, arena: std.mem.Allocator, include_hidden: bool) error{OutOfMemory}![]const display.WindowInfo {
        var out: std.ArrayList(display.WindowInfo) = .empty;
        for (self.windows) |listed| {
            if (self.live(listed.handle) == null) continue;
            var win = listed;
            if (win.other_desktop and !self.virtual_desktops) {
                win.other_desktop = false;
                win.cloaked = true;
            }
            if (include_hidden or !(win.cloaked or win.other_desktop)) try out.append(arena, win);
        }
        return out.items;
    }

    /// Rectangle of `window`, else of the foreground (accessibility) window.
    pub fn windowRect(self: *Fake, window: ?u64) ?display.Rect {
        if (window == null) self.foreground_reads += 1;
        if (window) |h| for (self.windows) |win| if (win.handle == h) return win.rect;
        return if (self.ui_elements.len > 0) self.ui_elements[0].rect else null;
    }

    fn refOf(win: display.WindowInfo) display.WindowRef {
        return .{ .handle = win.handle, .pid = win.pid };
    }

    /// Top window under physical point `p`, else the foreground window
    /// (`ui_window`).
    pub fn windowAt(self: *Fake, point: ?[2]i32) ?display.WindowRef {
        if (point == null) self.foreground_reads += 1;
        const p = point orelse return self.windowRef(self.ui_window) orelse .{ .handle = self.ui_window, .pid = 0 };
        for (self.windows) |win| if (!win.cloaked and !win.minimized and win.rect.contains(p[0], p[1])) return refOf(win);
        return null;
    }

    pub fn windowRef(self: *Fake, handle: u64) ?display.WindowRef {
        return refOf(self.live(handle) orelse return null);
    }

    /// Arms the foreground guard for the action that begins (US-050).
    pub fn guardArm(self: *Fake, watch: *guard.Watch) void {
        self.guard_watch = watch;
    }

    /// A tree of `window` was shown; `changed`: against the one before.
    pub fn treeObserved(self: *Fake, window: u64, changed: ?bool) void {
        self.observed_window = window;
        self.observed_changed = changed;
        self.observations += 1;
    }

    /// Leaves the guard armed for `ms` once the action has returned.
    pub fn guardLinger(self: *Fake, watch: *guard.Watch, ms: u32) void {
        self.guard_watch = watch;
        self.lingered_ms = ms;
    }

    /// Disarms it. Whether the user made a gesture that can change the
    /// foreground window around the action; null without the hooks.
    pub fn guardDisarm(self: *Fake) ?bool {
        self.guard_watch = null;
        return self.gesture;
    }

    /// Gives the foreground back to `window` without injected input.
    pub fn restoreForeground(self: *Fake, window: u64) bool {
        self.restores += 1;
        if (self.restore_refused) return false;
        self.restored_to = window;
        self.foreground_window = window;
        return true;
    }

    /// `window` takes the foreground while an action runs: what the event
    /// thread of the real backend does with the armed guard.
    pub fn foregroundEvent(self: *Fake, window: u64) void {
        self.foreground_window = window;
        if (!self.foreground_events) return;
        const watch = self.guard_watch orelse return;
        while (watch.onForeground(window, self.appPid(window), if (watch.target != 0) self.appPid(watch.target) else null, self.appPid(watch.prev), self.gesture) == .restore) {
            if (self.restored_at_event_read == null) self.restored_at_event_read = self.event_reads;
            watch.done(self.restoreForeground(watch.prev), 0);
            if (!self.steals_again) break;
            self.foreground_window = window;
        }
    }

    /// A stamp that changes with every event of `window`'s process, null
    /// when the hook is refused (US-048).
    pub fn windowEvents(self: *Fake, window: u64) ?u64 {
        _ = window;
        if (self.events_refused) return null;
        self.event_reads += 1;
        if (self.cancel_at_event) |n| if (self.event_reads == n) if (self.control) |c| c.cancel.store(true, .release);
        if (self.pause_at_event) |n| if (self.event_reads == n) if (self.control) |c| {
            _ = c.toggle();
        };
        var event = self.events_churn;
        if (self.events_pending > 0) {
            self.events_pending -= 1;
            event = true;
        }
        if (self.close_at_event) |n| if (self.event_reads == n) {
            self.markGone(self.ui_window);
            event = true;
        };
        if (self.appear_at_event) |n| if (self.event_reads == n) {
            self.ui_elements = self.appear_elements;
            event = true;
        };
        if (event) self.event_stamp += 1;
        return self.event_stamp;
    }

    /// Changes when a top-level window appears or goes (US-030): a hash of
    /// the live windows' handles.
    pub fn topWindowStamp(self: *Fake) u64 {
        self.stamp_calls += 1;
        if (self.appear_at_stamp) |n| if (self.stamp_calls == n) {
            self.ui_elements = self.appear_elements;
            self.windows = self.appear_windows;
        };
        var h: u64 = 0;
        for (self.windows) |win| if (self.live(win.handle) != null) {
            h = std.hash.Wyhash.hash(h, std.mem.asBytes(&win.handle));
        };
        return h;
    }

    pub fn processName(self: *Fake, arena: std.mem.Allocator, pid: u32) ?[]const u8 {
        _ = arena;
        self.process_lookups += 1;
        for (self.processes) |p| if (p[0] == pid) return p[1];
        for (self.windows) |win| if (win.pid == pid) return win.exe;
        return null;
    }

    pub fn visibleWindows(self: *Fake, arena: std.mem.Allocator) error{OutOfMemory}![]const display.VisibleWindow {
        var out: std.ArrayList(display.VisibleWindow) = .empty;
        for (self.windows) |win| if (!win.cloaked and !win.minimized)
            try out.append(arena, .{ .handle = win.handle, .pid = win.pid, .rect = win.rect, .solid = true });
        return out.items;
    }

    pub fn beginSecretScan(self: *Fake) void {
        self.secret_scans += 1;
    }

    /// Rectangles of the on-screen password elements of the foreground tree.
    pub fn secretRects(self: *Fake) []const display.Rect {
        var n: usize = 0;
        for (self.ui_elements) |e| if (e.password and !e.states.offscreen and n < self.secret_buf.len) {
            self.secret_buf[n] = e.rect;
            n += 1;
        };
        return self.secret_buf[0..n];
    }

    pub fn startKillSwitch(self: *Fake, control: *Control, rearm: keys.Combo) void {
        _ = rearm;
        self.control = control;
    }

    /// Extra roots of the foreground window (`ui_window`).
    pub fn uiRoots(self: *Fake, arena: std.mem.Allocator, window: ?u64) []const uitree.RootWindow {
        if (window == null) self.foreground_reads += 1;
        if (window) |h| if (h != self.ui_window) return &.{};
        const out = arena.alloc(uitree.RootWindow, self.ui_extra.len) catch return &.{};
        for (self.ui_extra, out) |x, *o| o.* = x.window;
        return out;
    }

    pub fn uiSnapshot(self: *Fake, arena: std.mem.Allocator, window: ?u64, request: uitree.Request) uitree.SnapshotResult {
        if (window == null) self.foreground_reads += 1;
        if (window) |h| if (h != self.ui_window) {
            // An owned dialog read by its own handle.
            for (self.ui_extra) |x| if (x.window.handle == h) {
                const roots = arena.alloc(uitree.Root, 1) catch return .{ .err = "Mémoire insuffisante : réessaie." };
                roots[0] = .{ .start = 0, .handle = h, .modal = x.modal };
                return .{ .ok = .{ .window = h, .elements = x.elements, .roots = if (x.modal) roots else &.{} } };
            };
            for (self.windows) |win| if (win.handle == h) {
                const root = arena.alloc(uitree.Element, 1) catch return .{ .err = "Mémoire insuffisante : réessaie." };
                root[0] = .{ .key = win.handle, .depth = 0, .role = .window, .name = win.title, .rect = win.rect };
                return .{ .ok = .{ .window = h, .elements = root } };
            };
            return .{ .err = "Fenêtre fermée : rappelle window_list" };
        };
        if (window) |h| if (std.mem.indexOfScalar(u64, self.gone_buf[0..self.gone_len], h) != null) return .{ .err = "Fenêtre fermée : rappelle window_list" };
        self.ui_snapshots += 1;
        self.ui_requested = request.extra_roots.len;
        var snap: uitree.Snapshot = .{ .window = self.ui_window, .elements = self.withChanges(arena, self.ui_elements), .partial = self.ui_partial, .desktop = self.ui_desktop, .web_pending = self.ui_web_pending, .firefox_no_tree = self.ui_firefox_no_tree };
        // Chromium's web tree is not built yet: its text is not read.
        if (request.text and !self.ui_web_pending) {
            if (self.ui_web) |web| {
                snap.elements = web;
                snap.web_text = .read;
                snap.page = self.ui_page;
            } else snap.web_text = .no_document;
        }
        if (self.events_churn and snap.elements.len > 0) {
            const moved = arena.dupe(uitree.Element, snap.elements) catch return .{ .err = "Mémoire insuffisante : réessaie." };
            moved[moved.len - 1].rect.h += @intCast(self.ui_snapshots);
            snap.elements = moved;
        }
        if (request.extra_roots.len == 0 and !self.ui_modal) return .{ .ok = snap };
        var els: std.ArrayList(uitree.Element) = .empty;
        var roots: std.ArrayList(uitree.Root) = .empty;
        roots.append(arena, .{ .start = 0, .handle = self.ui_window, .modal = self.ui_modal }) catch return .{ .err = "Mémoire insuffisante : réessaie." };
        els.appendSlice(arena, snap.elements) catch return .{ .err = "Mémoire insuffisante : réessaie." };
        for (request.extra_roots) |r| for (self.ui_extra) |x| if (x.window.handle == r.handle) {
            roots.append(arena, .{ .start = @intCast(els.items.len), .handle = r.handle, .modal = x.modal }) catch return .{ .err = "Mémoire insuffisante : réessaie." };
            els.appendSlice(arena, x.elements) catch return .{ .err = "Mémoire insuffisante : réessaie." };
        };
        snap.elements = els.items;
        snap.roots = roots.items;
        return .{ .ok = snap };
    }

    pub fn uiAutoFocus(self: *Fake, enabled: bool) void {
        self.auto_focus = enabled;
    }

    /// The element `key` as the actions left it.
    fn liveElement(self: *Fake, key: u64) ?uitree.Element {
        // An element the window no longer serves is gone, changed or not.
        const e = self.findElement(key) orelse return null;
        for (self.ui_changed[0..self.ui_changed_len]) |c| if (c.el.key == key) return c.el;
        return e;
    }

    /// The element `key` in the set the actions changed, copied there on
    /// its first change.
    fn mutable(self: *Fake, key: u64) ?*Changed {
        const e = self.findElement(key) orelse return null;
        for (self.ui_changed[0..self.ui_changed_len]) |*c| if (c.el.key == key) return c;
        if (self.ui_changed_len == self.ui_changed.len) return null;
        self.ui_changed[self.ui_changed_len] = .{ .el = e };
        self.ui_changed_len += 1;
        return &self.ui_changed[self.ui_changed_len - 1];
    }

    /// `elements` with what the actions changed; the same slice when
    /// nothing did.
    fn withChanges(self: *Fake, arena: std.mem.Allocator, elements: []const uitree.Element) []const uitree.Element {
        if (self.ui_changed_len == 0 and self.ui_reveal == null) return elements;
        const out = arena.dupe(uitree.Element, elements) catch return elements;
        for (out) |*e| {
            if (self.liveElement(e.key)) |c| e.* = c;
            if (self.unrevealed(e.key)) e.states.offscreen = true;
        }
        return out;
    }

    /// Index of `key` in the tree the window serves.
    fn elementIndex(self: *Fake, key: u64) ?usize {
        for (self.ui_elements, 0..) |e, i| if (e.key == key) return i;
        return null;
    }

    /// Key of the nearest ancestor of `key` with a Scroll pattern, within
    /// `max_scroll_levels`.
    fn scrollHostOf(self: *Fake, key: u64) ?u64 {
        var i = self.elementIndex(key) orelse return null;
        var depth = self.ui_elements[i].depth;
        var levels: usize = 0;
        while (i > 0 and levels < uitree.max_scroll_levels) {
            i -= 1;
            const e = self.ui_elements[i];
            if (e.depth >= depth) continue;
            depth = e.depth;
            levels += 1;
            if ((self.liveElement(e.key) orelse e).scroll != null) return e.key;
        }
        return null;
    }

    /// Whether `ui_reveal` still keeps `key` out of view.
    fn unrevealed(self: *Fake, key: u64) bool {
        const r = self.ui_reveal orelse return false;
        if (r.key != key) return false;
        const host = self.liveElement(self.scrollHostOf(key) orelse return true) orelse return true;
        const v = (host.scroll orelse return true).v orelse return true;
        return v < r.at;
    }

    pub fn uiLive(self: *Fake, arena: std.mem.Allocator, window: u64, key: u64, read: uitree.LiveRead) uitree.LiveResult {
        _ = window;
        const want_value = read == .value;
        self.ui_live_reads += 1;
        if (want_value) self.ui_value_reads += 1;
        if (self.ui_cancel_at_read) |n| if (self.ui_live_reads == n) if (self.control) |c| c.cancel.store(true, .release);
        if (self.ui_pause_at_read) |n| if (self.ui_live_reads == n) if (self.control) |c| {
            _ = c.toggle();
        };
        if (self.ui_enable_at_read) |n| if (self.ui_live_reads >= n) if (self.mutable(key)) |c| {
            c.el.states.disabled = false;
        };
        const e = self.liveElement(key) orelse return .gone;
        var l: uitree.Live = .{ .enabled = !e.states.disabled, .offscreen = e.states.offscreen or self.unrevealed(key), .password = e.password, .rect = e.rect, .actions = e.actions, .range = e.range, .scroll = e.scroll };
        if (e.actions.toggle) l.toggle = if (e.states.checked) .on else if (e.states.mixed) .mixed else .off;
        if (e.actions.expand_collapse) l.expand = if (e.states.expanded) .expanded else if (e.states.collapsed) .collapsed else .leaf;
        if (e.actions.select) l.selected = e.states.selected;
        if (want_value and e.actions.value and !e.password) {
            const set = for (self.ui_changed[0..self.ui_changed_len]) |c| {
                if (c.el.key == key) break c.value_hash;
            } else null;
            l.value_hash = set orelse uitree.textHashUtf8(arena, e.value orelse "");
        }
        return .{ .ok = l };
    }

    pub fn uiOp(self: *Fake, arena: std.mem.Allocator, window: u64, key: u64, o: uitree.Op) uitree.OpResult {
        _ = window;
        const e = self.liveElement(key) orelse return .gone;
        const supported = switch (o) {
            .invoke => e.actions.invoke,
            .legacy => std.mem.indexOfScalar(u64, self.ui_legacy, key) != null,
            .toggle => e.actions.toggle,
            .select => e.actions.select,
            .expand, .collapse => e.actions.expand_collapse,
            .focus => true,
            .scroll_item => e.actions.scroll,
            .set_value => e.actions.value,
            .set_range => e.range != null,
            .scroll, .scroll_to => e.scroll != null,
        };
        if (!supported) return .unsupported;
        self.ui_last_op = .{ .key = key, .op = o, .value_len = if (o == .set_value) o.set_value.len else 0 };
        if (self.ui_op_len < self.ui_ops.len) {
            self.ui_ops[self.ui_op_len] = .{ .key = key, .op = o };
            self.ui_op_len += 1;
        }
        if (self.gesture_on_act and self.gesture != null) self.gesture = true;
        if (self.foreground_after_act) |f| self.foregroundEvent(f);
        if (self.ui_stuck) return .ok;
        const c = self.mutable(key) orelse return .ok;
        const s = &c.el.states;
        switch (o) {
            .invoke, .legacy, .focus => {},
            .toggle => {
                const now: uitree.Toggle = if (s.checked) .on else if (s.mixed) .mixed else .off;
                const cycle = self.ui_toggle_cycle;
                const at = std.mem.indexOfScalar(uitree.Toggle, cycle, now) orelse cycle.len - 1;
                const next = cycle[(at + 1) % cycle.len];
                s.checked = next == .on;
                s.mixed = next == .mixed;
            },
            .select => s.selected = true,
            .expand, .collapse => {
                s.expanded = o == .expand;
                s.collapsed = o == .collapse;
                if (o == .collapse and self.ui_collapse_cancels) {
                    for (self.ui_changed[0..self.ui_changed_len]) |*other| other.el.states.selected = false;
                }
            },
            .scroll_item => s.offscreen = false,
            .set_value => |v| c.value_hash = if (self.ui_reformat) uitree.textHash(&.{ 'x', 'y' }) else uitree.textHashUtf8(arena, v),
            .set_range => |x| c.el.range.?.value = if (self.ui_reformat) @round(x / 10) * 10 else x,
            .scroll => |step| {
                var sc = c.el.scroll.?;
                sc.v = scrolledBy(sc.v, step.v, self.ui_scroll_step);
                sc.h = scrolledBy(sc.h, step.h, self.ui_scroll_step);
                c.el.scroll = sc;
            },
            .scroll_to => |to| {
                var sc = c.el.scroll.?;
                if (to.v) |v| if (sc.v != null) {
                    sc.v = @floatCast(v);
                };
                if (to.h) |h| if (sc.h != null) {
                    sc.h = @floatCast(h);
                };
                c.el.scroll = sc;
            },
        }
        return .ok;
    }

    /// One scroll increment on an axis: a notch moves `step` percent, a
    /// page five times as much. An axis that does not scroll stays null.
    fn scrolledBy(at: ?f32, amount: uitree.ScrollAmount, step: f32) ?f32 {
        const p = at orelse return null;
        const delta: f32 = switch (amount) {
            .none => 0,
            .small_back => -step,
            .small_forward => step,
            .large_back => -5 * step,
            .large_forward => 5 * step,
        };
        return std.math.clamp(p + delta, 0, 100);
    }

    pub fn uiScrollHost(self: *Fake, arena: std.mem.Allocator, window: u64, key: u64) ?u64 {
        _ = arena;
        _ = window;
        return self.scrollHostOf(key);
    }

    /// The selectable descendants of `key`. With `ui_entries_when_open`, a
    /// container shows them only while expanded; with `ui_entries_fail_open`
    /// its tree cannot be read while it is, as a Win32 drop-down.
    pub fn uiEntries(self: *Fake, arena: std.mem.Allocator, window: u64, key: u64) uitree.EntriesResult {
        _ = window;
        const i = self.elementIndex(key) orelse return .gone;
        self.ui_entry_reads += 1;
        if (self.ui_pause_at_entries) |n| if (self.ui_entry_reads == n) if (self.control) |c| {
            _ = c.toggle();
        };
        const open = (self.liveElement(key) orelse return .gone).states.expanded;
        if (open and self.ui_entries_fail_open) return .{ .failed = "UI Automation a échoué (lecture des entrées) : réessaie." };
        if (!open and self.ui_entries_when_open) return .{ .ok = &.{} };
        var out: std.ArrayList(uitree.Entry) = .empty;
        const depth = self.ui_elements[i].depth;
        for (self.ui_elements[i + 1 ..]) |e| {
            if (e.depth <= depth) break;
            if (e.actions.select) out.append(arena, .{ .key = e.key, .name = e.name }) catch return .{ .failed = "Mémoire insuffisante : réessaie." };
        }
        return .{ .ok = out.items };
    }

    fn findElement(self: *Fake, key: u64) ?uitree.Element {
        for (self.ui_elements) |el| if (el.key == key) return el;
        for (self.ui_extra) |x| for (x.elements) |el| if (el.key == key) return el;
        return null;
    }

    pub fn focusWindow(self: *Fake, handle: u64) display.FocusResult {
        self.activations += 1;
        for (self.windows) |win| if (win.handle == handle) {
            self.focused = handle;
            return .ok;
        };
        return .closed;
    }

    // ------------------------------------------------------------ window_set (US-027)

    fn live(self: *Fake, handle: u64) ?display.WindowInfo {
        if (std.mem.indexOfScalar(u64, self.gone_buf[0..self.gone_len], handle) != null) return null;
        for (self.windows) |win| if (win.handle == handle) return win;
        return null;
    }

    pub fn markGone(self: *Fake, handle: u64) void {
        if (self.gone_len < self.gone_buf.len) {
            self.gone_buf[self.gone_len] = handle;
            self.gone_len += 1;
        }
    }

    pub fn windowPlacement(self: *Fake, handle: u64) ?display.Placement {
        const win = self.live(handle) orelse return null;
        return .{ .frame = win.rect, .pid = win.pid, .minimized = win.minimized, .maximized = false, .elevated = win.elevated };
    }

    /// Places the frame, as large as `min_size` at least.
    pub fn placeWindow(self: *Fake, handle: u64, frame: display.Rect, activate: bool) display.SetResult {
        _ = self.live(handle) orelse return .closed;
        if (self.hung) return .hung;
        self.last_activate = activate;
        self.activations += @intFromBool(activate);
        var got = frame;
        if (self.min_size) |m| {
            got.w = @max(got.w, m[0]);
            got.h = @max(got.h, m[1]);
        }
        self.placed = got;
        self.set_calls += 1;
        return .{ .ok = got };
    }

    pub fn showWindow(self: *Fake, handle: u64, state: display.ShowState, activate: bool) display.SetResult {
        const win = self.live(handle) orelse return .closed;
        if (self.hung) return .hung;
        self.last_activate = activate;
        self.activations += @intFromBool(activate);
        if (self.foreground_after_show) |f| self.foreground_window = f;
        self.shown = state;
        self.set_calls += 1;
        const r = self.placed orelse win.rect;
        return .{ .ok = if (state == .maximized) displays_fixture[0].rect else r };
    }

    pub fn closeWindow(self: *Fake, handle: u64) display.SetResult {
        _ = self.live(handle) orelse return .closed;
        self.close_calls += 1;
        switch (self.on_close) {
            .closes => self.markGone(handle),
            .dialog => self.ui_extra = &close_dialog,
            .stays => {},
        }
        return .{ .ok = .{ .x = 0, .y = 0, .w = 0, .h = 0 } };
    }

    /// A save dialog of Notepad (pid 4242) owned by the window.
    const close_dialog = [_]ExtraRoot{.{
        .window = .{ .handle = 0x9a9a, .pid = 4242 },
        .modal = true,
        .elements = &.{
            .{ .key = 900, .depth = 0, .role = .window, .name = "Bloc-notes", .rect = .{ .x = 400, .y = 300, .w = 500, .h = 200 } },
            .{ .key = 901, .depth = 1, .role = .button, .name = "Enregistrer", .actions = .{ .invoke = true }, .rect = .{ .x = 450, .y = 450, .w = 100, .h = 30 } },
            .{ .key = 902, .depth = 1, .role = .button, .name = "Ne pas enregistrer", .actions = .{ .invoke = true }, .rect = .{ .x = 600, .y = 450, .w = 150, .h = 30 } },
        },
    }};

    pub fn appPid(self: *Fake, handle: u64) ?u32 {
        const win = self.live(handle) orelse return null;
        for (self.hosted) |h| if (h[0] == handle) return h[1];
        return win.pid;
    }

    pub fn processAncestors(self: *Fake, arena: std.mem.Allocator) []const u32 {
        _ = arena;
        return self.ancestors;
    }

    pub fn processAlive(self: *Fake, pid: u32) bool {
        if (self.terminated == pid) return false;
        return std.mem.indexOfScalar(u32, self.dead_pids, pid) == null;
    }

    pub fn terminateProcess(self: *Fake, pid: u32) bool {
        self.terminated = pid;
        for (self.windows) |win| if (win.pid == pid) self.markGone(win.handle);
        return true;
    }

    // ------------------------------------------------------------ app_launch (US-028, US-029)

    pub fn appCatalog(self: *Fake, arena: std.mem.Allocator, cancel: *const std.atomic.Value(bool)) apps.CatalogResult {
        _ = arena;
        _ = cancel;
        self.catalog_calls += 1;
        return .{ .ok = self.catalog };
    }

    pub fn launchApp(self: *Fake, arena: std.mem.Allocator, app: apps.App, show: apps.Show, cancel: *const std.atomic.Value(bool)) apps.Launch {
        _ = arena;
        _ = cancel;
        self.launched = app;
        self.launch_show = show;
        self.launch_calls += 1;
        if (self.cancel_on_launch) |c| c.store(true, .release);
        if (self.after_launch) |wins| self.windows = wins;
        if (self.foreground_after_launch) |f| self.foreground_window = f;
        self.foreground_switching = self.switching_after_launch;
        return self.launch_result;
    }

    /// Executable a non-packaged entry's shortcut targets, from
    /// `shortcut_targets`.
    pub fn appExe(self: *Fake, arena: std.mem.Allocator, app: apps.App) ?[]const u8 {
        _ = arena;
        self.exe_lookups += 1;
        for (self.shortcut_targets) |t| if (std.mem.eql(u8, t[0], app.aumid)) return t[1];
        return null;
    }

    pub fn openPath(self: *Fake, path: []const u8, show: apps.Show, cancel: *const std.atomic.Value(bool)) apps.Launch {
        _ = cancel;
        self.launch_show = show;
        self.opened_len = @min(path.len, self.opened_buf.len);
        @memcpy(self.opened_buf[0..self.opened_len], path[0..self.opened_len]);
        self.launch_calls += 1;
        if (self.after_launch) |wins| self.windows = wins;
        if (self.foreground_after_launch) |f| self.foreground_window = f;
        self.foreground_switching = self.switching_after_launch;
        return self.launch_result;
    }

    pub fn opened(self: *const Fake) []const u8 {
        return self.opened_buf[0..self.opened_len];
    }

    pub fn defaultApp(self: *Fake, arena: std.mem.Allocator, ext: []const u8) ?[]const u8 {
        _ = self;
        _ = arena;
        if (std.mem.eql(u8, ext, ".txt")) return "notepad.exe";
        if (std.mem.eql(u8, ext, ".kdbx")) return "KeePassXC.exe";
        return null;
    }

    /// A fixture file system: `files` and `folders`, absolute; `Z:` is a
    /// mapped network drive.
    pub fn pathInfo(self: *Fake, arena: std.mem.Allocator, path: []const u8) apps.PathInfo {
        _ = arena;
        self.path_lookups += 1;
        if (std.ascii.startsWithIgnoreCase(path, "Z:")) return .{ .kind = .remote, .full = path };
        for (self.short_names) |s| if (std.ascii.eqlIgnoreCase(s[0], path)) return .{ .kind = .file, .full = s[1] };
        for (self.files) |f| if (std.ascii.eqlIgnoreCase(f, path)) return .{ .kind = .file, .full = f };
        for (self.folders) |f| if (std.ascii.eqlIgnoreCase(f, path)) return .{ .kind = .directory, .full = f };
        return .{ .kind = .missing, .full = path };
    }

    /// `.pif` and `.scr` open as `"%1" %*`: the file runs as a program.
    /// `.gadget` stands for a type only AssocIsDangerous refuses.
    pub fn unsafeType(self: *Fake, ext: []const u8) bool {
        _ = self;
        for ([_][]const u8{ ".pif", ".scr", ".gadget" }) |e| if (std.mem.eql(u8, ext, e)) return true;
        return false;
    }

    pub fn pathExtensions(self: *Fake, arena: std.mem.Allocator) []const u8 {
        _ = self;
        _ = arena;
        return ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PY";
    }

    // ------------------------------------------------------------ clipboard (US-035)

    /// The fixture's content, the text cut to `max_chars` code points.
    pub fn clipboardRead(self: *Fake, arena: std.mem.Allocator, max_chars: usize, cancel: *const std.atomic.Value(bool)) clipboard.Read {
        _ = cancel;
        _ = arena;
        self.clip_reads += 1;
        if (self.clip_busy) |pid| return .{ .busy = pid };
        if (self.clip_marker) |m| return .{ .secret = .{ .marker = m, .owner_pid = self.clip_owner } };
        const t = self.clip_text orelse return .{ .no_text = .{ .formats = self.clip_formats, .owner_pid = self.clip_owner } };
        return .{ .text = .{ .text = clipboard.prefixChars(t, max_chars), .total = std.unicode.utf8CountCodepoints(t) catch t.len, .owner_pid = self.clip_owner } };
    }

    /// Becomes the owner (neo-compute's pid) of a text that, like the
    /// Windows backend's own content, reads back despite its two markers.
    pub fn clipboardWrite(self: *Fake, arena: std.mem.Allocator, text: []const u8, cancel: *const std.atomic.Value(bool)) clipboard.Write {
        _ = cancel;
        _ = arena;
        if (self.clip_busy) |pid| return .{ .busy = pid };
        self.clip_writes += 1;
        self.clip_written_len = text.len;
        const n = @min(text.len, self.clip_written.len);
        @memcpy(self.clip_written[0..n], text[0..n]);
        self.clip_text = self.clip_written[0..n];
        self.clip_marker = null;
        self.clip_owner = self.ancestors[0];
        return .ok;
    }

    // ------------------------------------------------------------ registry_read (US-036)

    fn regKey(self: *Fake, arena: std.mem.Allocator, path: regread.Path) ?RegKey {
        const text = path.text(arena);
        for (self.reg_keys) |k| if (std.ascii.eqlIgnoreCase(k.path, text)) return k;
        return null;
    }

    pub fn registryValue(self: *Fake, arena: std.mem.Allocator, path: regread.Path, name: []const u8) regread.ValueResult {
        self.reg_reads += 1;
        const k = self.regKey(arena, path) orelse return .{ .failed = .missing_key };
        if (k.denied) return .{ .failed = .denied };
        for (k.values) |v| if (std.ascii.eqlIgnoreCase(v.name, name)) return .{ .ok = v };
        return .{ .failed = .missing_value };
    }

    pub fn registryKey(self: *Fake, arena: std.mem.Allocator, path: regread.Path, max_values: usize, max_subkeys: usize) regread.KeyResult {
        self.reg_reads += 1;
        const k = self.regKey(arena, path) orelse return .{ .failed = .missing_key };
        if (k.denied) return .{ .failed = .denied };
        return .{ .ok = .{
            .values = k.values[0..@min(k.values.len, max_values)],
            .values_total = k.values.len,
            .subkeys = k.subkeys[0..@min(k.subkeys.len, max_subkeys)],
            .subkeys_total = k.subkeys.len,
        } };
    }
};
