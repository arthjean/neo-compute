//! Windows bench scenarios. `capture` measures the DXGI path the tools use
//! (backend.capture of the primary display), `snapshot` the UIA worker's
//! snapshot of the taskbar, and `screenshot`, `window_list` and `ui_tree`
//! run the real tools through the dispatcher (`tools/call` in, JSON-RPC line
//! out). `settle` times an action's wait for a still test window apart from
//! its observation (US-015). The application scenarios (`notepad` ... `vscode`) open their
//! reference application, time ui_tree on it and close what they opened.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const bench = @import("../../core/bench.zig");
const timing = @import("../../core/timing.zig");
const Timings = timing.Timings;
const CountingAllocator = @import("../../core/counting_allocator.zig").CountingAllocator;
const mcp = @import("../../core/mcp.zig");
const tools = @import("../../core/tools.zig");
const Windows = @import("../windows.zig").Windows;
const display = @import("../../core/display.zig");
const window = @import("window.zig");
const TestWindow = @import("test_window.zig").TestWindow;

const CaptureScenario = struct {
    pub const default_iterations = 300;
    io: std.Io,
    backend: *Windows,
    arena: std.heap.ArenaAllocator,

    pub fn step(self: *CaptureScenario, t: *Timings) !void {
        _ = self.arena.reset(.retain_capacity);
        t.start(self.io, .capture);
        defer t.stop(self.io, .capture);
        switch (self.backend.capture(0, self.arena.allocator())) {
            .frame => {},
            .failed => return error.CaptureFailed,
        }
    }
};

const SnapshotScenario = struct {
    pub const default_iterations = 200;
    io: std.Io,
    backend: *Windows,
    hwnd: u64,
    arena: std.heap.ArenaAllocator,
    extras: Extras = .{},

    pub fn step(self: *SnapshotScenario, t: *Timings) !void {
        _ = self.arena.reset(.retain_capacity);
        t.start(self.io, .accessibility);
        defer t.stop(self.io, .accessibility);
        switch (self.backend.uiSnapshot(self.arena.allocator(), self.hwnd, .{})) {
            .ok => {},
            .err => return error.SnapshotFailed,
        }
        self.extras.add(self.backend);
    }
};

/// Time of the range and scroll round trips inside each snapshot (US-022,
/// assumption A7), printed apart: it is part of the accessibility stage.
const Extras = struct {
    ns: [4096]u64 = undefined,
    len: usize = 0,

    fn add(self: *Extras, backend: *Windows) void {
        if (self.len == self.ns.len) return;
        self.ns[self.len] = backend.ui.lastExtrasNs();
        self.len += 1;
    }

    fn report(self: *Extras, name: []const u8) void {
        if (self.len == 0) return;
        const s = self.ns[0..self.len];
        std.mem.sort(u64, s, {}, std.sort.asc(u64));
        const p95 = s[@min(s.len - 1, (s.len * 95 + 99) / 100 - 1)];
        std.debug.print("bench: {s} range and scroll round trip p50 {d} us, p95 {d} us over {d} snapshots (A7)\n", .{ name, s[s.len / 2] / 1000, p95 / 1000, s.len });
    }
};

const Server = mcp.Server(Windows, tools.all);

/// One `tools/call` per iteration through the dispatcher, into a
/// discarding writer; the server's stage timings become the sample.
const ToolScenario = struct {
    server: Server,
    line: []const u8,
    sink_buf: [64 * 1024]u8 = undefined,
    sink: std.Io.Writer.Discarding = undefined,
    extras: Extras = .{},

    pub fn step(self: *ToolScenario, t: *Timings) !void {
        try self.server.handleMessage(self.line, &self.sink.writer);
        self.extras.add(self.server.backend);
        for (0..timing.stage_count) |s| {
            t.ns[s] += self.server.timings.ns[s];
            t.allocs[s] += self.server.timings.allocs[s];
            if (self.server.timings.used[s]) t.used[s] = true;
        }
    }
};

const Filler = struct {
    hwnds: [64]w.HWND = undefined,
    len: usize = 0,

    fn fill(self: *Filler, backend: *Windows, want: usize) void {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const listed: []const display.WindowInfo = backend.listWindows(scratch.allocator(), false) catch &.{};
        const have = listed.len;
        const instance = w.GetModuleHandleW(null);
        const class = std.unicode.utf8ToUtf16LeStringLiteral("NeoComputeBenchWindow");
        const wc: w.WNDCLASSEXW = .{ .cbSize = @sizeOf(w.WNDCLASSEXW), .style = 0, .lpfnWndProc = w.DefWindowProcW, .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = instance, .hIcon = null, .hCursor = null, .hbrBackground = null, .lpszMenuName = null, .lpszClassName = class, .hIconSm = null };
        _ = w.RegisterClassExW(&wc);
        while (have + self.len < want and self.len < self.hwnds.len) : (self.len += 1) {
            const x: i32 = 30000 + @as(i32, @intCast(self.len)) * 10;
            self.hwnds[self.len] = w.CreateWindowExW(w.WS_EX_NOACTIVATE, class, std.unicode.utf8ToUtf16LeStringLiteral("neo-compute bench window"), w.WS_POPUP | w.WS_VISIBLE, x, 30000, 200, 100, null, null, instance, null);
        }
    }

    fn destroy(self: *Filler) void {
        for (self.hwnds[0..self.len]) |h| if (h != null) {
            _ = w.DestroyWindow(h);
        };
    }
};

fn unsupported(gpa: std.mem.Allocator, comptime f: []const u8, args: anytype) bench.Outcome {
    return .{ .unsupported = std.fmt.allocPrint(gpa, f, args) catch "unsupported" };
}

fn runTool(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, backend: *Windows, line: []const u8, iterations: usize) !bench.Outcome {
    const s = try gpa.create(ToolScenario);
    defer gpa.destroy(s);
    s.* = .{ .server = .init(counter.allocator(), io, backend, .{}), .line = line };
    defer s.server.deinit();
    s.sink = .init(&s.sink_buf);
    // Warm the request arena and the image buffers: steady state only.
    for (0..10) |_| {
        var scratch: Timings = .{};
        try s.step(&scratch);
    }
    return bench.measure(gpa, io, s, iterations, counter);
}

/// Runs one Windows scenario. Missing capabilities are reported as
/// `unsupported` instead of failing.
pub fn run(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, name: []const u8, iterations: ?usize) !bench.Outcome {
    const counted = counter.allocator();
    var backend: Windows = .init(counted);
    defer backend.deinit();
    if (std.mem.eql(u8, name, "capture") or std.mem.eql(u8, name, "screenshot")) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        switch (backend.capture(0, arena.allocator())) {
            .frame => {},
            .failed => |msg| return unsupported(gpa, "primary display capture unavailable: {s}", .{msg}),
        }
    }
    if (std.mem.eql(u8, name, "capture")) {
        var s: CaptureScenario = .{ .io = io, .backend = &backend, .arena = .init(gpa) };
        defer s.arena.deinit();
        return bench.measure(gpa, io, &s, iterations orelse CaptureScenario.default_iterations, counter);
    }
    if (std.mem.eql(u8, name, "screenshot")) {
        // Display 0 is the primary display (native resolution to 1280 px).
        return runTool(gpa, io, counter, &backend, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\",\"arguments\":{\"display\":0}}}", iterations orelse 200);
    }
    if (std.mem.eql(u8, name, "window_list")) {
        // The budget is stated for 50 windows: top the desktop up with
        // titled windows parked outside every display, owned by this
        // thread so their titles are read without a message loop.
        var extra: Filler = .{};
        defer extra.destroy();
        extra.fill(&backend, 50);
        return runTool(gpa, io, counter, &backend, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"window_list\",\"arguments\":{}}}", iterations orelse 200);
    }
    if (std.mem.eql(u8, name, "snapshot") or std.mem.eql(u8, name, "ui_tree")) {
        const hwnd = w.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd"), null);
        if (hwnd == null) return unsupported(gpa, "reference window Shell_TrayWnd (taskbar) not found", .{});
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        switch (backend.uiSnapshot(arena.allocator(), @intFromPtr(hwnd), .{})) {
            .ok => {},
            .err => |msg| return unsupported(gpa, "UI Automation unavailable: {s}", .{msg}),
        }
        if (std.mem.eql(u8, name, "ui_tree")) {
            // Steady state of an observation: a delta of an unchanged tree.
            const line = try std.fmt.allocPrint(arena.allocator(), "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"ui_tree\",\"arguments\":{{\"window\":\"0x{x}\",\"since\":\"last\"}}}}}}", .{@intFromPtr(hwnd)});
            return runTool(gpa, io, counter, &backend, line, iterations orelse 200);
        }
        const s = try gpa.create(SnapshotScenario);
        defer gpa.destroy(s);
        s.* = .{ .io = io, .backend = &backend, .hwnd = @intFromPtr(hwnd), .arena = .init(gpa) };
        defer s.arena.deinit();
        const outcome = try bench.measure(gpa, io, s, iterations orelse SnapshotScenario.default_iterations, counter);
        s.extras.report("snapshot");
        return outcome;
    }
    if (std.mem.eql(u8, name, "settle")) {
        // An action on a still window this scenario creates, observed with
        // the default delta: the `settle` stage is the wait, reported apart
        // and kept out of the total (US-015).
        var tw: TestWindow = .{ .rect = .{ .left = 40, .top = 40, .right = 400, .bottom = 300 } };
        tw.start() catch return unsupported(gpa, "settle: test window cannot be created", .{});
        defer tw.stop();
        _ = window.focus(@intFromPtr(tw.window()));
        w.Sleep(200);
        var buf: [160]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"window_focus\",\"arguments\":{{\"window\":\"0x{x}\",\"observe\":\"delta\"}}}}}}", .{@intFromPtr(tw.window())});
        return runTool(gpa, io, counter, &backend, line, iterations orelse 30);
    }
    for (apps) |app| if (std.mem.eql(u8, name, app.name)) return appScenario(gpa, io, counter, &backend, app, iterations orelse 50);
    return unsupported(gpa, "unknown scenario", .{});
}

// ---------------------------------------------------------------- reference applications

const App = struct {
    name: []const u8,
    /// `{page}` is replaced by the absolute path of bench/pages/reference.html,
    /// `{page_url}` by its file URL, `{root}` by the repository root and
    /// `{profile}` by a scratch directory, `{firefox_profile}` by another.
    argv: []const []const u8,
    /// Executable of the window, compared without case; null for any.
    exe: ?[]const u8 = null,
    /// Accepted titles (exact), or with `title_contains` substrings.
    titles: []const []const u8 = &.{},
    title_contains: bool = false,
    /// Also time the C witness probe on the window (provider-bound budget).
    witness: bool = false,
    /// Open the window's context menu (right click at its center) and time
    /// ui_tree without `window`, which reads the menu as a further root
    /// (US-023).
    context_menu: bool = false,
    /// Time ui_tree with `text: true` (US-024).
    text: bool = false,
    /// Written to `{firefox_profile}\user.js` before the launch.
    user_js: ?[]const u8 = null,
    /// Directory of `{firefox_profile}` under `.zig-cache`.
    firefox_profile: []const u8 = "bench-firefox-profile",
    /// The window must be read through UIA's MSAA proxy (US-025).
    msaa: bool = false,
    /// Reported when the executable is missing, in place of the generic
    /// message.
    absent: ?[]const u8 = null,
};

/// A fresh Firefox profile without its first-run pages, default-browser
/// prompt or updates (US-025).
const firefox_user_js =
    \\user_pref("browser.shell.checkDefaultBrowser", false);
    \\user_pref("browser.aboutwelcome.enabled", false);
    \\user_pref("browser.startup.homepage_override.mstone", "ignore");
    \\user_pref("startup.homepage_welcome_url", "");
    \\user_pref("startup.homepage_welcome_url.additional", "");
    \\user_pref("browser.startup.firstrunSkipsHomepage", true);
    \\user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
    \\user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
    \\user_pref("browser.tabs.warnOnClose", false);
    \\user_pref("app.update.auto", false);
    \\user_pref("browser.sessionstore.resume_from_crash", false);
    \\
;

const page = "bench/pages/reference.html";

const apps = [_]App{
    .{ .name = "notepad", .argv = &.{"notepad.exe"}, .exe = "notepad.exe" },
    .{ .name = "notepad-menu", .argv = &.{"notepad.exe"}, .exe = "notepad.exe", .context_menu = true },
    .{ .name = "calculator", .argv = &.{"calc.exe"}, .titles = &.{ "Calculatrice", "Calculator" } },
    // A folder of a few entries: the budget is stated for at most 400 nodes.
    .{ .name = "explorer", .argv = &.{ "explorer.exe", "{root}\\bench" }, .exe = "explorer.exe", .titles = &.{"bench"}, .title_contains = true, .witness = true },
    .{ .name = "settings", .argv = &.{ "explorer.exe", "ms-settings:" }, .titles = &.{ "Paramètres", "Settings" } },
    // A profile of its own: no extension, restored tab or sign-in page.
    .{ .name = "chrome", .argv = &.{ "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check", "--new-window", "{page_url}" }, .exe = "chrome.exe", .titles = &.{"neo-compute reference page"}, .title_contains = true },
    .{ .name = "chrome-text", .argv = &.{ "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check", "--new-window", "{page_url}" }, .exe = "chrome.exe", .titles = &.{"neo-compute reference page"}, .title_contains = true, .text = true },
    .{ .name = "firefox", .argv = &.{ "C:\\Program Files\\Mozilla Firefox\\firefox.exe", "-profile", "{firefox_profile}", "-no-remote", "-new-window", "{page_url}" }, .exe = "firefox.exe", .titles = &.{"neo-compute reference page"}, .title_contains = true, .user_js = firefox_user_js, .absent = "Firefox absent de la machine" },
    // Native UIA off: UIA reads Firefox through its MSAA proxy (US-025).
    .{ .name = "firefox-msaa", .argv = &.{ "C:\\Program Files\\Mozilla Firefox\\firefox.exe", "-profile", "{firefox_profile}", "-no-remote", "-new-window", "{page_url}" }, .exe = "firefox.exe", .titles = &.{"neo-compute reference page"}, .title_contains = true, .user_js = firefox_user_js ++ "user_pref(\"accessibility.uia.enable\", 0);\n", .firefox_profile = "bench-firefox-msaa-profile", .msaa = true, .absent = "Firefox absent de la machine" },
    .{ .name = "vscode", .argv = &.{ "cmd.exe", "/c", "code", "--new-window", "{page}" }, .exe = "Code.exe", .titles = &.{"reference.html"}, .title_contains = true },
};

fn matches(app: App, win: display.WindowInfo) bool {
    if (app.exe) |e| if (!std.ascii.eqlIgnoreCase(e, win.exe)) return false;
    if (app.titles.len == 0) return true;
    for (app.titles) |t| {
        if (app.title_contains and std.mem.indexOf(u8, win.title, t) != null) return true;
        if (!app.title_contains and std.mem.eql(u8, win.title, t)) return true;
    }
    return false;
}

/// A window of `app`, minimized ones included: an existing window is used
/// as is and never closed.
fn findApp(backend: *Windows, app: App) ?u64 {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const listed = backend.listWindows(scratch.allocator(), false) catch return null;
    for (listed) |win| if (matches(app, win)) return win.handle;
    return null;
}

fn expandArgs(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8, firefox_profile: []const u8) ![]const []const u8 {
    const out = try arena.dupe([]const u8, argv);
    const abs = std.Io.Dir.cwd().realPathFileAlloc(io, page, arena) catch return error.PageNotFound;
    const root = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch return error.PageNotFound;
    for (out) |*a| {
        var arg = a.*;
        arg = try std.mem.replaceOwned(u8, arena, arg, "{page_url}", try std.fmt.allocPrint(arena, "file:///{s}", .{abs}));
        arg = try std.mem.replaceOwned(u8, arena, arg, "{page}", abs);
        arg = try std.mem.replaceOwned(u8, arena, arg, "{firefox_profile}", try std.fmt.allocPrint(arena, "{s}\\.zig-cache\\{s}", .{ root, firefox_profile }));
        arg = try std.mem.replaceOwned(u8, arena, arg, "{profile}", try std.fmt.allocPrint(arena, "{s}\\.zig-cache\\bench-chrome-profile", .{root}));
        arg = try std.mem.replaceOwned(u8, arena, arg, "{root}", root);
        a.* = arg;
    }
    return out;
}

fn treeText(arena: std.mem.Allocator, written: []const u8) []const u8 {
    const reply = std.json.parseFromSliceLeaky(std.json.Value, arena, written, .{}) catch return written;
    return reply.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
}

/// ui_tree of the application's window: the first snapshot after
/// activation is timed and printed apart (US-014), then the steady state is
/// measured. Trees are printed only for a window opened here (an existing
/// window holds the user's own content), which is closed at the end.
fn appScenario(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, backend: *Windows, app: App, iterations: usize) !bench.Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var launched = false;
    var hwnd = findApp(backend, app);
    if (hwnd == null) {
        const argv = expandArgs(arena, io, app.argv, app.firefox_profile) catch
            return unsupported(gpa, "{s} not found: run the bench from the repository root", .{page});
        if (app.absent) |msg| std.Io.Dir.cwd().access(io, argv[0], .{}) catch return unsupported(gpa, "{s}", .{msg});
        if (app.user_js) |prefs| {
            const sub = try std.fmt.allocPrint(arena, ".zig-cache\\{s}", .{app.firefox_profile});
            var dir = std.Io.Dir.cwd().createDirPathOpen(io, sub, .{}) catch |err|
                return unsupported(gpa, "{s}: profile cannot be created ({t})", .{ app.name, err });
            defer dir.close(io);
            dir.writeFile(io, .{ .sub_path = "user.js", .data = prefs }) catch |err|
                return unsupported(gpa, "{s}: user.js cannot be written ({t})", .{ app.name, err });
        }
        _ = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err|
            return unsupported(gpa, "{s} cannot be started ({t})", .{ app.argv[0], err });
        var waited: u32 = 0;
        while (hwnd == null and waited < 15_000) : (waited += 200) {
            w.Sleep(200);
            hwnd = findApp(backend, app);
        }
        if (hwnd == null) return unsupported(gpa, "{s}: no window within 15 s after `{s}` (application installed?)", .{ app.name, app.argv[app.argv.len - 1] });
        launched = true;
    }
    const h = hwnd.?;
    defer if (launched) {
        _ = w.PostMessageW(@ptrFromInt(h), w.WM_CLOSE, 0, 0);
    };
    if (window.focus(h) != .ok) std.debug.print("bench: {s}: window 0x{x} not brought to the foreground\n", .{ app.name, h });
    w.Sleep(1500); // let the application render and its provider settle
    // Menu items shown before the context menu opens (the menu bar's).
    var closed_items: usize = 0;
    if (app.context_menu) {
        switch (backend.uiSnapshot(arena, h, .{})) {
            .ok => |snap| for (snap.elements) |e| {
                closed_items += @intFromBool(e.role == .menuitem);
            },
            .err => {},
        }
        const r = window.rect(@ptrFromInt(h)) orelse return unsupported(gpa, "{s}: window 0x{x} has no rectangle", .{ app.name, h });
        const center = [2]i32{ r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h, 2) };
        backend.sendMouse(&.{ .{ .move = center }, .{ .down = .right }, .{ .up = .right } }) catch
            return unsupported(gpa, "{s}: right click refused by Windows", .{app.name});
        w.Sleep(800);
    }
    defer if (app.context_menu) {
        // Escape closes the menu before the window is closed.
        backend.keyCombo(.{ .key = .{ .key = .escape } }, .tap) catch {};
        w.Sleep(200);
    };

    const line = if (app.context_menu)
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"ui_tree\",\"arguments\":{}}}"
    else
        try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"ui_tree\",\"arguments\":{{\"window\":\"0x{x}\"{s}}}}}}}", .{ h, if (app.text) ",\"text\":true" else "" });
    const s = try gpa.create(ToolScenario);
    defer gpa.destroy(s);
    s.* = .{ .server = .init(counter.allocator(), io, backend, .{}), .line = line };
    defer s.server.deinit();
    s.sink = .init(&s.sink_buf);

    var first: std.Io.Writer.Allocating = .init(arena);
    const t0 = timing.now(io);
    try s.server.handleMessage(line, &first.writer);
    const first_us = @divTrunc(timing.now(io) - t0, std.time.ns_per_us);
    const text = treeText(arena, first.written());
    if (app.context_menu) {
        // The menu's items must be in the tree, as a further root (Win32
        // menus) or inside the window's own tree (XAML popups, read once).
        const roots = std.mem.count(u8, text, " window=0x");
        const items = std.mem.count(u8, text, " menuitem ");
        if (items <= closed_items) {
            std.debug.print("{s}\n", .{text});
            return unsupported(gpa, "{s}: the context menu is not in ui_tree ({d} menu items, {d} before it opened)", .{ app.name, items, closed_items });
        }
        std.debug.print("bench: {s} context menu in ui_tree: {d} menu items ({d} before it opened), {d} root(s)\n", .{ app.name, items, closed_items, roots });
    }
    std.debug.print("bench: {s} first ui_tree {d}.{d:0>3} ms, {d} lines ({s} window)\n", .{ app.name, @divTrunc(first_us, 1000), @as(u64, @intCast(@mod(first_us, 1000))), std.mem.count(u8, text, "\n") + 1, if (launched) "new" else "existing" });
    if (launched) std.debug.print("{s}\n", .{text});
    // The witness runs before and after the series and is averaged, so a
    // provider that speeds up or slows down meanwhile weighs on both sides.
    const witness_before = if (app.witness) witnessP95(arena, io, h) else null;
    s.extras.len = 0;
    var outcome = try bench.measure(gpa, io, s, iterations, counter);
    s.extras.report(app.name);
    if (app.msaa) {
        // A profile whose pref was ignored would time native UIA instead.
        if (!backend.ui.lastMsaaProxy()) return unsupported(gpa, "{s}: Firefox still serves native UIA (accessibility.uia.enable ignored)", .{app.name});
        std.debug.print("bench: {s} read through the MSAA proxy: {d} edit and {d} text lines in the first ui_tree, corrections {d} us in the last snapshot\n", .{ app.name, std.mem.count(u8, text, " edit \""), std.mem.count(u8, text, " text \""), backend.ui.lastMsaaNs() / 1000 });
    }
    if (witness_before) |before| if (witnessP95(arena, io, h)) |after| if (outcome == .ok) {
        outcome.ok.witness_p95_ns = (before + after) / 2;
    };
    // Raw element count (before pruning), against the 400-node statement.
    switch (backend.uiSnapshot(arena, h, .{})) {
        .ok => |snap| std.debug.print("bench: {s} window has {d} UIA elements\n", .{ app.name, snap.elements.len }),
        .err => {},
    }
    // Chromium builds its web tree once a client asks: the steady-state tree.
    var last: std.Io.Writer.Allocating = .init(arena);
    try s.server.handleMessage(line, &last.writer);
    const last_text = treeText(arena, last.written());
    std.debug.print("bench: {s} ui_tree after {d} snapshots: {d} lines\n", .{ app.name, iterations + 1, std.mem.count(u8, last_text, "\n") + 1 });
    if (launched) std.debug.print("{s}\n", .{last_text});
    return outcome;
}

/// p95 of the US-001 C witness probe (zig-out/bin/probe_c.exe, installed by
/// `zig build`) over 50 snapshots of the same window, or null when it cannot
/// run.
fn witnessP95(arena: std.mem.Allocator, io: std.Io, hwnd: u64) ?u64 {
    const handle = std.fmt.allocPrint(arena, "0x{x}", .{hwnd}) catch return null;
    const r = std.process.run(arena, io, .{ .argv = &.{ "zig-out\\bin\\probe_c.exe", "50", handle } }) catch |err| {
        std.debug.print("bench: witness probe not run ({t})\n", .{err});
        return null;
    };
    const key = "\"snapshot_p95_us\":";
    const at = std.mem.indexOf(u8, r.stderr, key) orelse return null;
    const rest = r.stderr[at + key.len ..];
    const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    const p95_us = std.fmt.parseInt(u64, rest[0..end], 10) catch return null;
    std.debug.print("bench: witness probe_c p95 {d} us on the same window\n", .{p95_us});
    return p95_us * std.time.ns_per_us;
}
