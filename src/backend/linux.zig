//! Linux backend (EP-019 onward). The compositor family (GNOME, KDE,
//! wlroots) is chosen at run time and gives a table of capabilities
//! (`tasks/prd-linux-port.md`, T1); this file is its facade. Each method the
//! core calls unconditionally is declared here. A method not implemented
//! yet acts on nothing: it records the gap (`gap`) and returns the
//! failure value of its type, the gap stops the running tool at its next
//! checkpoint (`gapped`), and the dispatcher answers with `unavailable`:
//! "Linux : <tool> n'est pas encore disponible dans ce build. Aucune action
//! exécutée." Later stories replace these bodies one capability at a time.

const std = @import("std");
const core = @import("core");
const display = core.display;
const input = core.input;
const keys = core.keys;
const uitree = core.uitree;
const guard = core.guard;
const apps = core.apps;
const clipboard = core.clipboard;
const handles = @import("linux/handles.zig");
const proc = @import("linux/common/proc.zig");
const xdg = @import("linux/common/xdg.zig");
const instance = @import("linux/common/instance.zig");
const capabilities = @import("linux/capabilities.zig");
const xkb = @import("linux/wire/xkb.zig");

pub const Linux = struct {
    /// Instructions and added tool descriptions of the Linux server (D7).
    pub const texts = @import("texts_linux");

    /// The first method not implemented yet that the running tool called,
    /// cleared by the dispatcher before each tool.
    missing: ?[]const u8 = null,
    /// The refusal of the running tool when it needs a capability this
    /// system lacks (FR-06), cleared with the gap.
    refused: ?[]const u8 = null,
    /// What this system offers (T1).
    caps: capabilities.Table = .{},
    /// libxkbcommon, loaded at start (P7): without it, no keyboard.
    xkb: ?xkb.Lib = null,
    /// Window handles of the session, by compositor id (D7). No compositor
    /// lists windows yet, so every handle is unknown: a window tool answers
    /// that the window is closed, before any gap.
    windows: handles.Table,
    io: std.Io,

    pub const Options = struct {
        /// The library dlopen loads for keyboard layouts.
        xkb_library: [:0]const u8 = xkb.library_name,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Linux {
        return initWith(gpa, io, .{});
    }

    pub fn initWith(gpa: std.mem.Allocator, io: std.Io, options: Options) Linux {
        var self: Linux = .{ .windows = .init(gpa), .io = io };
        self.xkb = xkb.Lib.load(options.xkb_library);
        self.caps.keyboard = self.xkb != null;
        return self;
    }

    /// `neo-compute selftest` in a test session (EP-021).
    pub const selftest = @import("linux/selftest.zig").run;

    /// The policy file and the audit folder (US-070): XDG base
    /// directories, the audit folder created with mode 0700.
    pub const places = xdg.places;

    /// One server per display (US-072, FR-14): a `flock` in
    /// `$XDG_RUNTIME_DIR/neo-compute/`.
    pub const acquireInstance = instance.acquire;

    /// The built-in rules of the Linux policy (decision 0014, P8).
    pub const policy_rules: []const core.policy.Rule = &@import("linux/policy_rules.zig").rules;

    pub fn deinit(self: *Linux) void {
        if (self.xkb) |lib| _ = std.c.dlclose(lib.handle);
        self.windows.deinit();
    }

    /// Whether `handle` names an open window of the session.
    fn known(self: *const Linux, handle: u64) bool {
        return self.windows.idOf(handle) != null;
    }

    // ---------------------------------------------------------------- gaps

    fn gap(self: *Linux, comptime method: []const u8) void {
        if (self.missing == null) self.missing = method;
    }

    /// Clears the gap before a tool runs.
    pub fn clearGap(self: *Linux) void {
        self.missing = null;
        self.refused = null;
    }

    /// Whether the running tool reached a method not implemented yet: its
    /// waits and polls stop there, since nothing it waits for can happen.
    pub fn gapped(self: *const Linux) bool {
        return self.missing != null or self.refused != null;
    }

    /// The tool error for a tool that reached a method not implemented yet
    /// (US-069, FR-06), or null.
    pub fn unavailable(self: *const Linux, arena: std.mem.Allocator, tool: []const u8) ?[]const u8 {
        // A tool the dispatcher refused before it ran (pause, second
        // instance, background mode) reached no backend method: its own
        // refusal stands.
        if (self.missing == null and self.refused == null) return null;
        // A tool that needs an absent capability is refused as such,
        // wherever it stopped (FR-06).
        if (self.caps.refusal(tool)) |msg| return msg;
        if (self.refused) |msg| return msg;
        return std.fmt.allocPrint(arena, "Linux : {s} n'est pas encore disponible dans ce build. Aucune action exécutée.", .{tool}) catch
            "Linux : cet outil n'est pas encore disponible dans ce build. Aucune action exécutée.";
    }

    // ---------------------------------------------------------------- input

    /// Nothing can be held: no input method is implemented yet.
    pub fn releaseAllInputs(self: *Linux) void {
        _ = self;
    }

    pub fn sendMouse(self: *Linux, events: []const input.MouseEvent) input.InputError!void {
        _ = events;
        self.gap("sendMouse");
        return error.InputBlocked;
    }

    pub fn cursorPosition(self: *Linux) [2]i32 {
        self.gap("cursorPosition");
        return .{ 0, 0 };
    }

    /// Refuses a key or text before any event when no keyboard layout
    /// can be read (US-080).
    fn needKeyboard(self: *Linux) input.InputError!void {
        if (self.caps.keyboard) return;
        self.refused = xkb.missing_text;
        return error.InputBlocked;
    }

    pub fn keyCombo(self: *Linux, combo: keys.Combo, action: input.KeyAction) input.InputError!void {
        _ = .{ combo, action };
        try self.needKeyboard();
        self.gap("keyCombo");
        return error.InputBlocked;
    }

    pub fn typeText(self: *Linux, units: []const u16) input.InputError!void {
        _ = units;
        try self.needKeyboard();
        self.gap("typeText");
        return error.InputBlocked;
    }

    pub fn targetAt(self: *Linux, point: ?[2]i32) input.Target {
        _ = point;
        self.gap("targetAt");
        return .elevated;
    }

    // ---------------------------------------------------------------- displays and capture

    pub fn displays(self: *Linux) []const display.Display {
        self.gap("displays");
        return &.{};
    }

    pub fn displayInfo(self: *Linux, index: usize) display.DisplayInfo {
        _ = index;
        self.gap("displayInfo");
        return .{ .primary = false, .dpi = 96, .work = .{ .x = 0, .y = 0, .w = 0, .h = 0 } };
    }

    pub fn foregroundDisplay(self: *Linux) ?usize {
        self.gap("foregroundDisplay");
        return null;
    }

    pub fn capture(self: *Linux, index: usize, arena: std.mem.Allocator) display.CaptureResult {
        _ = .{ index, arena };
        self.gap("capture");
        return .{ .failed = "unavailable" };
    }

    pub fn changes(self: *Linux, index: usize, arena: std.mem.Allocator, area: ?display.Rect) display.CaptureResult {
        _ = .{ index, arena, area };
        self.gap("changes");
        return .{ .failed = "unavailable" };
    }

    pub fn captureWindow(self: *Linux, handle: u64) display.WindowCapture {
        if (!self.known(handle)) return .closed;
        self.gap("captureWindow");
        return .failed;
    }

    pub fn beginSecretScan(self: *Linux, window: ?u64) void {
        _ = window;
        self.gap("beginSecretScan");
    }

    pub fn secretScan(self: *Linux) display.SecretScan {
        self.gap("secretScan");
        return .failed;
    }

    pub fn secretRects(self: *Linux) []const display.Rect {
        self.gap("secretRects");
        return &.{};
    }

    // ---------------------------------------------------------------- windows

    pub fn foregroundWindow(self: *Linux) ?u64 {
        self.gap("foregroundWindow");
        return null;
    }

    pub fn listWindows(self: *Linux, arena: std.mem.Allocator, include_hidden: bool) error{OutOfMemory}![]const display.WindowInfo {
        _ = .{ arena, include_hidden };
        self.gap("listWindows");
        return &.{};
    }

    pub fn listWindowsLayered(self: *Linux, arena: std.mem.Allocator, include_hidden: bool, stack: ?*[]const display.Layer) error{OutOfMemory}![]const display.WindowInfo {
        _ = .{ arena, include_hidden, stack };
        self.gap("listWindowsLayered");
        return &.{};
    }

    pub fn windowLayers(self: *Linux, arena: std.mem.Allocator) []const display.Layer {
        _ = arena;
        self.gap("windowLayers");
        return &.{};
    }

    pub fn visibleWindows(self: *Linux, arena: std.mem.Allocator) error{OutOfMemory}![]const display.VisibleWindow {
        _ = arena;
        self.gap("visibleWindows");
        return &.{};
    }

    pub fn windowRect(self: *Linux, window: ?u64) ?display.Rect {
        if (window) |h| if (!self.known(h)) return null;
        self.gap("windowRect");
        return null;
    }

    pub fn windowAt(self: *Linux, point: ?[2]i32) ?display.WindowRef {
        _ = point;
        self.gap("windowAt");
        return null;
    }

    pub fn windowRef(self: *Linux, handle: u64) ?display.WindowRef {
        if (!self.known(handle)) return null;
        self.gap("windowRef");
        return null;
    }

    pub fn topWindowStamp(self: *Linux) u64 {
        self.gap("topWindowStamp");
        return 0;
    }

    pub fn windowEvents(self: *Linux, window: u64) ?u64 {
        _ = window;
        self.gap("windowEvents");
        return null;
    }

    pub fn treeObserved(self: *Linux, window: u64, changed: ?bool) void {
        _ = .{ window, changed };
        self.gap("treeObserved");
    }

    pub fn focusWindow(self: *Linux, handle: u64) display.FocusResult {
        if (!self.known(handle)) return .closed;
        self.gap("focusWindow");
        return .refused;
    }

    pub fn windowPlacement(self: *Linux, handle: u64) ?display.Placement {
        if (!self.known(handle)) return null;
        self.gap("windowPlacement");
        return null;
    }

    pub fn placeWindow(self: *Linux, handle: u64, frame: display.Rect, activate: bool) display.SetResult {
        _ = .{ frame, activate };
        if (!self.known(handle)) return .closed;
        self.gap("placeWindow");
        return .failed;
    }

    pub fn showWindow(self: *Linux, handle: u64, state: display.ShowState, activate: bool) display.SetResult {
        _ = .{ state, activate };
        if (!self.known(handle)) return .closed;
        self.gap("showWindow");
        return .failed;
    }

    pub fn closeWindow(self: *Linux, handle: u64) display.SetResult {
        if (!self.known(handle)) return .closed;
        self.gap("closeWindow");
        return .failed;
    }

    // ---------------------------------------------------------------- foreground guard

    pub fn guardArm(self: *Linux, watch: *guard.Watch) void {
        _ = watch;
        self.gap("guardArm");
    }

    pub fn guardLinger(self: *Linux, watch: *guard.Watch, ms: u32) void {
        _ = .{ watch, ms };
        self.gap("guardLinger");
    }

    pub fn guardDisarm(self: *Linux) ?bool {
        self.gap("guardDisarm");
        return null;
    }

    pub fn restoreForeground(self: *Linux, window: u64) bool {
        _ = window;
        self.gap("restoreForeground");
        return false;
    }

    // ---------------------------------------------------------------- processes

    /// The base name of the process's executable (US-070).
    pub fn processName(self: *Linux, arena: std.mem.Allocator, pid: u32) ?[]const u8 {
        return proc.exeName(arena, self.io, pid);
    }

    /// The executable, the application id of the cgroup and the Flatpak
    /// id of the process, for the policy (US-070, D8).
    pub fn processNames(self: *Linux, arena: std.mem.Allocator, pid: u32) []const []const u8 {
        return proc.names(arena, self.io, pid);
    }

    pub fn appPid(self: *Linux, handle: u64) ?u32 {
        if (!self.known(handle)) return null;
        self.gap("appPid");
        return null;
    }

    pub fn processAncestors(self: *Linux, arena: std.mem.Allocator) []const u32 {
        _ = arena;
        self.gap("processAncestors");
        return &.{};
    }

    pub fn processAlive(self: *Linux, pid: u32) bool {
        _ = pid;
        self.gap("processAlive");
        return false;
    }

    pub fn terminateProcess(self: *Linux, pid: u32) bool {
        _ = pid;
        self.gap("terminateProcess");
        return false;
    }

    // ---------------------------------------------------------------- accessibility

    pub fn uiRoots(self: *Linux, arena: std.mem.Allocator, window: ?u64) []const uitree.RootWindow {
        _ = .{ arena, window };
        self.gap("uiRoots");
        return &.{};
    }

    pub fn uiSnapshot(self: *Linux, arena: std.mem.Allocator, window: ?u64, request: uitree.Request) uitree.SnapshotResult {
        _ = .{ arena, window, request };
        self.gap("uiSnapshot");
        return .{ .err = "unavailable" };
    }

    pub fn uiSubtree(self: *Linux, arena: std.mem.Allocator, window: u64, key: u64, request: uitree.Request) uitree.SubtreeResult {
        _ = .{ arena, window, key, request };
        self.gap("uiSubtree");
        return .{ .failed = "unavailable" };
    }

    pub fn uiElement(self: *Linux, arena: std.mem.Allocator, window: u64, key: u64) uitree.ElementResult {
        _ = .{ arena, window, key };
        self.gap("uiElement");
        return .{ .failed = "unavailable" };
    }

    pub fn uiLive(self: *Linux, arena: std.mem.Allocator, window: u64, key: u64, read: uitree.LiveRead) uitree.LiveResult {
        _ = .{ arena, window, key, read };
        self.gap("uiLive");
        return .{ .failed = "unavailable" };
    }

    pub fn uiOp(self: *Linux, arena: std.mem.Allocator, window: u64, key: u64, op: uitree.Op) uitree.OpResult {
        _ = .{ arena, window, key, op };
        self.gap("uiOp");
        return .{ .failed = "unavailable" };
    }

    pub fn uiScrollHost(self: *Linux, arena: std.mem.Allocator, window: u64, key: u64) ?u64 {
        _ = .{ arena, window, key };
        self.gap("uiScrollHost");
        return null;
    }

    pub fn uiEntries(self: *Linux, arena: std.mem.Allocator, window: u64, key: u64) uitree.EntriesResult {
        _ = .{ arena, window, key };
        self.gap("uiEntries");
        return .{ .failed = "unavailable" };
    }

    // ---------------------------------------------------------------- applications

    pub fn appCatalog(self: *Linux, arena: std.mem.Allocator, cancel: *const std.atomic.Value(bool)) apps.CatalogResult {
        _ = .{ arena, cancel };
        self.gap("appCatalog");
        return .{ .err = "unavailable" };
    }

    pub fn launchApp(self: *Linux, arena: std.mem.Allocator, app: apps.App, show: apps.Show, cancel: *const std.atomic.Value(bool)) apps.Launch {
        _ = .{ arena, app, show, cancel };
        self.gap("launchApp");
        return .{ .unavailable = "unavailable" };
    }

    pub fn appExe(self: *Linux, arena: std.mem.Allocator, app: apps.App) ?[]const u8 {
        _ = .{ arena, app };
        self.gap("appExe");
        return null;
    }

    pub fn openPath(self: *Linux, path: []const u8, show: apps.Show, cancel: *const std.atomic.Value(bool)) apps.Launch {
        _ = .{ path, show, cancel };
        self.gap("openPath");
        return .{ .unavailable = "unavailable" };
    }

    pub fn defaultApp(self: *Linux, arena: std.mem.Allocator, ext: []const u8) ?[]const u8 {
        _ = .{ arena, ext };
        self.gap("defaultApp");
        return null;
    }

    pub fn pathInfo(self: *Linux, arena: std.mem.Allocator, path: []const u8) apps.PathInfo {
        _ = arena;
        self.gap("pathInfo");
        return .{ .kind = .missing, .full = path };
    }

    /// Every type counts as unsafe until the Linux file types are read.
    pub fn unsafeType(self: *Linux, ext: []const u8) bool {
        _ = ext;
        self.gap("unsafeType");
        return true;
    }

    pub fn pathExtensions(self: *Linux, arena: std.mem.Allocator) []const u8 {
        _ = arena;
        self.gap("pathExtensions");
        return "";
    }

    // ---------------------------------------------------------------- clipboard

    pub fn clipboardRead(self: *Linux, arena: std.mem.Allocator, max_chars: usize, cancel: *const std.atomic.Value(bool)) clipboard.Read {
        _ = .{ arena, max_chars, cancel };
        self.gap("clipboardRead");
        return .{ .failed = "unavailable" };
    }

    pub fn clipboardWrite(self: *Linux, arena: std.mem.Allocator, text: []const u8, cancel: *const std.atomic.Value(bool)) clipboard.Write {
        _ = .{ arena, text, cancel };
        self.gap("clipboardWrite");
        return .{ .failed = "unavailable" };
    }
};

test {
    _ = handles;
    _ = proc;
    _ = xdg;
    _ = instance;
    _ = @import("linux/policy_rules.zig");
    _ = @import("linux/wire/sock.zig");
    _ = @import("linux/wire/dbus.zig");
    _ = @import("linux/wire/dbus_test.zig");
    _ = @import("linux/wire/wayland.zig");
    _ = @import("linux/wire/wayland_test.zig");
    _ = @import("linux/wire/ei.zig");
    _ = @import("linux/wire/ei_test.zig");
    _ = @import("linux/wire/xkb.zig");
    _ = capabilities;
    _ = @import("linux/selftest.zig");
}

test "without libxkbcommon, type and key answer its absence through the dispatcher and send nothing" {
    const testing = std.testing;
    var backend: Linux = .initWith(testing.allocator, testing.io, .{ .xkb_library = "libxkbcommon-absent.so.0" });
    defer backend.deinit();
    try testing.expect(!backend.caps.keyboard);
    const Server = core.mcp.Server(Linux, core.tools.all);
    var server: Server = .init(testing.allocator, testing.io, &backend, .{});
    defer server.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const calls = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"type\",\"arguments\":{\"text\":\"bonjour\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"key\",\"arguments\":{\"text\":\"ctrl+a\"}}}",
    };
    for (calls) |line| {
        out.clearRetainingCapacity();
        try server.handleMessage(line, &out.writer);
        try testing.expect(std.mem.indexOf(u8, out.written(), "libxkbcommon introuvable : installe-la pour taper du texte.") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") != null);
    }
    // A modifier of a click needs the keyboard too: refused before any
    // key event.
    try testing.expectError(error.InputBlocked, backend.keyCombo(.{ .key = .{ .key = .shift } }, .press));
    try testing.expectEqualStrings("libxkbcommon introuvable : installe-la pour taper du texte.", backend.refused.?);
}

test "without libxkbcommon, a keyboard tool the dispatcher refuses before it runs keeps that refusal" {
    const testing = std.testing;
    var backend: Linux = .initWith(testing.allocator, testing.io, .{ .xkb_library = "libxkbcommon-absent.so.0" });
    defer backend.deinit();
    const Server = core.mcp.Server(Linux, core.tools.all);
    // A second instance: its actions are refused before any backend call.
    var server: Server = .init(testing.allocator, testing.io, &backend, .{ .exclusive = false, .instance_refusal = "second instance refusal" });
    defer server.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"type\",\"arguments\":{\"text\":\"bonjour\"}}}", &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "second instance refusal") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "libxkbcommon") == null);
}

test "a keepassxc process started outside any application scope is denied by its executable" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A copy of sleep named keepassxc: /proc/<pid>/exe names the copy.
    const sleep = std.Io.Dir.cwd().readFileAlloc(io, "/usr/bin/sleep", testing.allocator, .limited(16 << 20)) catch return error.SkipZigTest;
    defer testing.allocator.free(sleep);
    try tmp.dir.writeFile(io, .{ .sub_path = "keepassxc", .data = sleep, .flags = .{ .permissions = .executable_file } });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const exe = try std.fs.path.join(testing.allocator, &.{ dir, "keepassxc" });
    defer testing.allocator.free(exe);
    var child = try std.process.spawn(io, .{ .argv = &.{ exe, "5" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer {
        child.kill(io);
    }
    var backend: Linux = .init(testing.allocator, io);
    defer backend.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pid: u32 = @intCast(child.id.?);
    const names = backend.processNames(arena.allocator(), pid);
    try testing.expectEqualStrings("keepassxc", names[0]);
    try testing.expectEqualStrings("keepassxc", backend.processName(arena.allocator(), pid).?);
    const p: core.policy.Policy = .{ .builtin = Linux.policy_rules };
    try testing.expectEqual(core.policy.Level.deny, p.levelOfNames(names));
    // A gone process has no name.
    try testing.expectEqual(@as(usize, 0), backend.processNames(arena.allocator(), 0x7fff_fff0).len);
}
