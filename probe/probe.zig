//! US-001 probe: drives UI Automation and DXGI Desktop Duplication through
//! COM vtables to decide whether Zig 0.17 holds COM reliably.
//!
//! Usage: probe [--leak N] [--frames N] [--samples N] [--target foreground|taskbar]
//! Everything human-readable goes to stderr; the last line is a single
//! `RESULT {...}` JSON object so the decision record can quote it verbatim.

const std = @import("std");
const w = @import("win");

const Error = error{
    ElementNotAvailable,
    ComCallFailed,
    NoForegroundWindow,
    NoOutputs,
    UnexpectedFrameSize,
    WindowSetupFailed,
    OutOfMemory,
};

var last_hr: w.HRESULT = 0;

fn check(code: w.HRESULT) Error!void {
    if (code >= 0) return;
    last_hr = code;
    // The metadata types UIA_E_* as u32, unlike HRESULT; compare the bits.
    if (@as(u32, @bitCast(code)) == w.UIA_E_ELEMENTNOTAVAILABLE) return error.ElementNotAvailable;
    return error.ComCallFailed;
}

fn release(obj: anytype) void {
    _ = obj.vtable.Release(obj);
}

// ---------------------------------------------------------------- timing

var qpc_freq: i64 = 0;

fn nowNs() u64 {
    var c: i64 = 0;
    _ = w.QueryPerformanceCounter(&c);
    return @intCast(@divTrunc(@as(i128, c) * std.time.ns_per_s, qpc_freq));
}

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const rank: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(sorted.len))));
    return sorted[@min(sorted.len - 1, rank -| 1)];
}

// ---------------------------------------------------------------- UIA

const Uia = struct {
    automation: *w.IUIAutomation,
    cache: *w.IUIAutomationCacheRequest,
    control_view: *w.IUIAutomationCondition,

    fn init() Error!Uia {
        var raw: ?*anyopaque = null;
        try check(w.CoCreateInstance(&w.CLSID_CUIAutomation, null, w.CLSCTX_INPROC_SERVER, &w.IUIAutomation.iid, &raw));
        const automation: *w.IUIAutomation = @ptrCast(@alignCast(raw.?));
        errdefer release(automation);

        var cache: ?*w.IUIAutomationCacheRequest = null;
        try check(automation.vtable.CreateCacheRequest(automation, &cache));
        errdefer release(cache.?);
        try check(cache.?.vtable.AddProperty(cache.?, w.UIA_NamePropertyId));
        try check(cache.?.vtable.AddProperty(cache.?, w.UIA_ControlTypePropertyId));
        try check(cache.?.vtable.AddProperty(cache.?, w.UIA_BoundingRectanglePropertyId));

        var cond: ?*w.IUIAutomationCondition = null;
        try check(automation.vtable.get_ControlViewCondition(automation, &cond));
        return .{ .automation = automation, .cache = cache.?, .control_view = cond.? };
    }

    fn deinit(self: *Uia) void {
        release(self.control_view);
        release(self.cache);
        release(self.automation);
    }

    fn elementFromHandle(self: *Uia, hwnd: w.HWND) Error!*w.IUIAutomationElement {
        var root: ?*w.IUIAutomationElement = null;
        try check(self.automation.vtable.ElementFromHandleBuildCache(self.automation, hwnd, self.cache, &root));
        return root orelse error.ElementNotAvailable;
    }

    /// Reads Name, ControlType and BoundingRectangle of `root` and all its
    /// control-view descendants from one cached round trip. Returns the
    /// number of elements read.
    fn snapshotElement(self: *Uia, root: *w.IUIAutomationElement, sink: ?*std.Io.Writer) Error!usize {
        try emit(root, 0, sink);
        var arr: ?*w.IUIAutomationElementArray = null;
        try check(root.vtable.FindAllBuildCache(root, w.TreeScope_Descendants, self.control_view, self.cache, &arr));
        // A destroyed window still answers FindAllBuildCache with S_OK and an
        // empty array; only a live (uncached) read reports
        // UIA_E_ELEMENTNOTAVAILABLE, so the snapshot ends with one.
        try alive(root);
        const array = arr orelse return 1;
        defer release(array);
        var len: i32 = 0;
        try check(array.vtable.get_Length(array, &len));
        var i: i32 = 0;
        while (i < len) : (i += 1) {
            var el: ?*w.IUIAutomationElement = null;
            try check(array.vtable.GetElement(array, i, &el));
            defer release(el.?);
            try emit(el.?, 1, sink);
        }
        return @as(usize, @intCast(len)) + 1;
    }

    fn snapshot(self: *Uia, hwnd: w.HWND, sink: ?*std.Io.Writer) Error!usize {
        const root = try self.elementFromHandle(hwnd);
        defer release(root);
        return self.snapshotElement(root, sink);
    }

    fn alive(el: *w.IUIAutomationElement) Error!void {
        var name: w.BSTR = null;
        try check(el.vtable.get_CurrentName(el, &name));
        w.SysFreeString(name);
    }

    fn emit(el: *w.IUIAutomationElement, depth: usize, sink: ?*std.Io.Writer) Error!void {
        var name: w.BSTR = null;
        try check(el.vtable.get_CachedName(el, &name));
        defer w.SysFreeString(name);
        var control_type: i32 = 0;
        try check(el.vtable.get_CachedControlType(el, &control_type));
        var rect: w.RECT = undefined;
        try check(el.vtable.get_CachedBoundingRectangle(el, &rect));
        const out = sink orelse return;
        const name_slice: []const u16 = if (name) |n| n[0..w.SysStringLen(name)] else &.{};
        out.splatByteAll(' ', depth * 2) catch {};
        out.print("{d} \"{f}\" @{d},{d},{d},{d}\n", .{
            control_type,           std.unicode.fmtUtf16Le(name_slice),
            rect.left,              rect.top,
            rect.right - rect.left, rect.bottom - rect.top,
        }) catch {};
    }
};

// ---------------------------------------------------------------- DXGI

const Output = struct {
    name: [32]u16,
    adapter_name: [128]u16,
    desc: w.DXGI_OUTPUT_DESC,
    device: *w.ID3D11Device,
    context: *w.ID3D11DeviceContext,
    dup: *w.IDXGIOutputDuplication,
    staging: ?*w.ID3D11Texture2D = null,
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,

    fn expectedSize(self: *const Output) [2]u32 {
        const r = self.desc.DesktopCoordinates;
        const dw: u32 = @intCast(r.right - r.left);
        const dh: u32 = @intCast(r.bottom - r.top);
        // DXGI_MODE_ROTATION_ROTATE90 = 2, ROTATE270 = 4: the duplicated
        // surface keeps the panel's native orientation.
        return if (self.desc.Rotation == 2 or self.desc.Rotation == 4) .{ dh, dw } else .{ dw, dh };
    }

    /// Acquires one frame. Returns false on timeout or a pointer-only update.
    fn acquire(self: *Output, gpa: std.mem.Allocator, timeout_ms: u32) Error!bool {
        var info: w.DXGI_OUTDUPL_FRAME_INFO = undefined;
        var resource: ?*w.IDXGIResource = null;
        const code = self.dup.vtable.AcquireNextFrame(self.dup, timeout_ms, &info, &resource);
        if (code == w.DXGI_ERROR_WAIT_TIMEOUT) return false;
        try check(code);
        defer _ = self.dup.vtable.ReleaseFrame(self.dup);
        defer release(resource.?);
        if (info.LastPresentTime == 0) return false;

        var tex_raw: ?*anyopaque = null;
        try check(resource.?.vtable.QueryInterface(resource.?, &w.ID3D11Texture2D.iid, &tex_raw));
        const tex: *w.ID3D11Texture2D = @ptrCast(@alignCast(tex_raw.?));
        defer release(tex);

        var desc: w.D3D11_TEXTURE2D_DESC = undefined;
        tex.vtable.GetDesc(tex, &desc);
        const expected = self.expectedSize();
        if (desc.Width != expected[0] or desc.Height != expected[1] or desc.Format != w.DXGI_FORMAT_B8G8R8A8_UNORM)
            return error.UnexpectedFrameSize;

        if (self.staging == null or self.width != desc.Width or self.height != desc.Height) {
            if (self.staging) |s| release(s);
            self.staging = null;
            gpa.free(self.pixels);
            self.pixels = &.{};
            var sd = desc;
            sd.MipLevels = 1;
            sd.ArraySize = 1;
            sd.SampleDesc = .{ .Count = 1, .Quality = 0 };
            sd.Usage = w.D3D11_USAGE_STAGING;
            sd.BindFlags = 0;
            sd.CPUAccessFlags = w.D3D11_CPU_ACCESS_READ;
            sd.MiscFlags = 0;
            try check(self.device.vtable.CreateTexture2D(self.device, &sd, null, &self.staging));
            self.pixels = try gpa.alloc(u8, @as(usize, desc.Width) * desc.Height * 4);
            self.width = desc.Width;
            self.height = desc.Height;
        }
        const staging = self.staging.?;
        self.context.vtable.CopyResource(self.context, @ptrCast(staging), @ptrCast(tex));
        var mapped: w.D3D11_MAPPED_SUBRESOURCE = undefined;
        try check(self.context.vtable.Map(self.context, @ptrCast(staging), 0, w.D3D11_MAP_READ, 0, &mapped));
        defer self.context.vtable.Unmap(self.context, @ptrCast(staging), 0);
        const src: [*]const u8 = @ptrCast(mapped.pData.?);
        const row = @as(usize, self.width) * 4;
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            @memcpy(self.pixels[y * row ..][0..row], src[y * mapped.RowPitch ..][0..row]);
        }
        return true;
    }

    fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        if (self.staging) |s| release(s);
        gpa.free(self.pixels);
        release(self.dup);
        release(self.context);
        release(self.device);
    }
};

fn enumerateOutputs(gpa: std.mem.Allocator, list: *std.ArrayList(Output), log: *std.Io.Writer) Error!void {
    var factory_raw: ?*anyopaque = null;
    try check(w.CreateDXGIFactory1(&w.IDXGIFactory1.iid, &factory_raw));
    const factory: *w.IDXGIFactory1 = @ptrCast(@alignCast(factory_raw.?));
    defer release(factory);

    var ai: u32 = 0;
    while (true) : (ai += 1) {
        var adapter: ?*w.IDXGIAdapter1 = null;
        const ahr = factory.vtable.EnumAdapters1(factory, ai, &adapter);
        if (ahr == w.DXGI_ERROR_NOT_FOUND) break;
        try check(ahr);
        defer release(adapter.?);
        var adesc: w.DXGI_ADAPTER_DESC1 = undefined;
        try check(adapter.?.vtable.GetDesc1(adapter.?, &adesc));

        var oi: u32 = 0;
        while (true) : (oi += 1) {
            var out_raw: ?*w.IDXGIOutput = null;
            const ohr = adapter.?.vtable.EnumOutputs(adapter.?, oi, &out_raw);
            if (ohr == w.DXGI_ERROR_NOT_FOUND) break;
            try check(ohr);
            defer release(out_raw.?);
            var o1_raw: ?*anyopaque = null;
            try check(out_raw.?.vtable.QueryInterface(out_raw.?, &w.IDXGIOutput1.iid, &o1_raw));
            const output1: *w.IDXGIOutput1 = @ptrCast(@alignCast(o1_raw.?));
            defer release(output1);
            var odesc: w.DXGI_OUTPUT_DESC = undefined;
            try check(output1.vtable.GetDesc(output1, &odesc));
            if (odesc.AttachedToDesktop == 0) continue;

            // One device per output keeps the probe simple; the duplication
            // must be created on the adapter that owns the output.
            var device: ?*w.ID3D11Device = null;
            var context: ?*w.ID3D11DeviceContext = null;
            try check(w.D3D11CreateDevice(@ptrCast(adapter.?), w.D3D_DRIVER_TYPE_UNKNOWN, null, 0, null, 0, w.D3D11_SDK_VERSION, &device, null, &context));
            errdefer {
                release(context.?);
                release(device.?);
            }
            var dup: ?*w.IDXGIOutputDuplication = null;
            try check(output1.vtable.DuplicateOutput(output1, @ptrCast(device.?), &dup));
            log.print("output {f} on {f}: desktop {d},{d} {d}x{d} rotation={d}\n", .{
                std.unicode.fmtUtf16Le(std.mem.sliceTo(&odesc.DeviceName, 0)),
                std.unicode.fmtUtf16Le(std.mem.sliceTo(&adesc.Description, 0)),
                odesc.DesktopCoordinates.left,
                odesc.DesktopCoordinates.top,
                odesc.DesktopCoordinates.right - odesc.DesktopCoordinates.left,
                odesc.DesktopCoordinates.bottom - odesc.DesktopCoordinates.top,
                odesc.Rotation,
            }) catch {};
            try list.append(gpa, .{
                .name = odesc.DeviceName,
                .adapter_name = adesc.Description,
                .desc = odesc,
                .device = device.?,
                .context = context.?,
                .dup = dup.?,
            });
        }
    }
    if (list.items.len == 0) return error.NoOutputs;
}

// ---------------------------------------------------------------- fixture windows

/// Runs on its own thread with a message loop: small animated tiles on every
/// output (so duplication always has fresh frames) and disposable target
/// windows for the element-not-available test.
const Fixture = struct {
    thread_id: std.atomic.Value(u32) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    tiles: []const w.RECT,
    targets: []w.HWND,

    var tick: u32 = 0;
    var brushes: [2]w.HBRUSH = .{ null, null };

    fn wndProc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
        switch (msg) {
            w.WM_TIMER => {
                tick +%= 1;
                _ = w.InvalidateRect(hwnd, null, 0);
                return 0;
            },
            w.WM_PAINT => {
                var ps: w.PAINTSTRUCT = undefined;
                const hdc = w.BeginPaint(hwnd, &ps);
                _ = w.FillRect(hdc, &ps.rcPaint, brushes[tick & 1]);
                _ = w.EndPaint(hwnd, &ps);
                return 0;
            },
            else => return w.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    fn run(self: *Fixture) void {
        const instance = w.GetModuleHandleW(null);
        const class = std.unicode.utf8ToUtf16LeStringLiteral("NeoComputeProbeFixture");
        brushes = .{ w.CreateSolidBrush(0x00FF00FF), w.CreateSolidBrush(0x0000FF00) };
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
        if (w.RegisterClassExW(&wc) == 0) return self.fail();
        for (self.tiles) |r| {
            const tile = w.CreateWindowExW(w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE, class, null, w.WS_POPUP, r.left, r.top, r.right - r.left, r.bottom - r.top, null, null, instance, null);
            if (tile == null) return self.fail();
            _ = w.ShowWindow(tile, w.SW_SHOWNOACTIVATE);
            _ = w.SetTimer(tile, 1, 10, null);
        }
        const button = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
        for (self.targets) |*t| {
            t.* = w.CreateWindowExW(w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE, class, std.unicode.utf8ToUtf16LeStringLiteral("neo-compute probe target"), w.WS_OVERLAPPEDWINDOW, 40, 40, 320, 200, null, null, instance, null);
            if (t.* == null) return self.fail();
            for (0..8) |i| {
                const y: i32 = @intCast(i * 20);
                _ = w.CreateWindowExW(0, button, std.unicode.utf8ToUtf16LeStringLiteral("probe button"), w.WS_CHILD | w.WS_VISIBLE, 4, y, 120, 18, t.*, null, instance, null);
            }
        }
        self.thread_id.store(w.GetCurrentThreadId(), .release);
        self.ready.store(true, .release);
        var msg: w.MSG = undefined;
        while (w.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
    }

    fn fail(self: *Fixture) void {
        self.failed.store(true, .release);
        self.ready.store(true, .release);
    }

    fn waitReady(self: *Fixture) Error!void {
        while (!self.ready.load(.acquire)) w.Sleep(1);
        if (self.failed.load(.acquire)) return error.WindowSetupFailed;
    }

    fn stop(self: *Fixture) void {
        _ = w.PostThreadMessageW(self.thread_id.load(.acquire), w.WM_QUIT, 0, 0);
    }
};

// ---------------------------------------------------------------- process counters

const Counters = struct { private_bytes: usize, handles: u32 };

fn counters() Counters {
    var pmc: w.PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(w.PROCESS_MEMORY_COUNTERS_EX);
    pmc.cb = @sizeOf(w.PROCESS_MEMORY_COUNTERS_EX);
    _ = w.K32GetProcessMemoryInfo(w.GetCurrentProcess(), @ptrCast(&pmc), pmc.cb);
    var handles: u32 = 0;
    _ = w.GetProcessHandleCount(w.GetCurrentProcess(), &handles);
    return .{ .private_bytes = pmc.PrivateUsage, .handles = handles };
}

// ---------------------------------------------------------------- main

const Options = struct {
    leak: usize = 10_000,
    frames: usize = 100,
    samples: usize = 200,
    closed_targets: usize = 100,
    target: enum { foreground, taskbar } = .taskbar,
};

fn parseArgs(args: []const [:0]const u8) !Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (i + 1 >= args.len) return error.MissingValue;
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--leak")) o.leak = try std.fmt.parseInt(usize, v, 10) else if (std.mem.eql(u8, a, "--frames")) o.frames = try std.fmt.parseInt(usize, v, 10) else if (std.mem.eql(u8, a, "--samples")) o.samples = try std.fmt.parseInt(usize, v, 10) else if (std.mem.eql(u8, a, "--target")) o.target = std.meta.stringToEnum(@TypeOf(o.target), v) orelse return error.BadTarget else return error.UnknownFlag;
    }
    return o;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = parseArgs(args) catch |err| {
        std.debug.print("probe: {t}\nusage: probe [--leak N] [--frames N] [--samples N] [--target foreground|taskbar]\n", .{err});
        return 2;
    };
    _ = w.QueryPerformanceFrequency(&qpc_freq);
    if (w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == 0)
        std.debug.print("probe: SetProcessDpiAwarenessContext failed\n", .{});

    var err_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
    const log = &stderr_writer.interface;
    defer log.flush() catch {};

    try check(w.CoInitializeEx(null, @bitCast(w.COINIT_MULTITHREADED)));
    defer w.CoUninitialize();

    // 1. Snapshot of the foreground window, printed to stderr.
    var uia = try Uia.init();
    defer uia.deinit();
    const fg = w.GetForegroundWindow();
    if (fg == null) return error.NoForegroundWindow;
    try log.print("== foreground snapshot (hwnd 0x{x})\n", .{@intFromPtr(fg)});
    const fg_nodes = try uia.snapshot(fg, log);
    try log.print("== {d} elements\n", .{fg_nodes});
    try log.flush();

    // 2. Outputs and fixture tiles (one 24x24 tile at each output's top-left corner + 8 px).
    var outputs: std.ArrayList(Output) = .empty;
    defer {
        for (outputs.items) |*o| o.deinit(gpa);
        outputs.deinit(gpa);
    }
    try enumerateOutputs(gpa, &outputs, log);
    const tiles = try gpa.alloc(w.RECT, outputs.items.len);
    defer gpa.free(tiles);
    for (outputs.items, tiles) |o, *t| {
        const r = o.desc.DesktopCoordinates;
        t.* = .{ .left = r.left + 8, .top = r.top + 8, .right = r.left + 32, .bottom = r.top + 32 };
    }
    const targets = try gpa.alloc(w.HWND, opts.closed_targets);
    defer gpa.free(targets);
    var fixture: Fixture = .{ .tiles = tiles, .targets = targets };
    const fixture_thread = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    defer {
        fixture.stop();
        fixture_thread.join();
    }
    try fixture.waitReady();

    // 3. N frames per output, each copied to a BGRA buffer at physical size.
    var frames_ok: usize = 0;
    for (outputs.items) |*o| {
        var got: usize = 0;
        var attempts: usize = 0;
        while (got < opts.frames and attempts < opts.frames * 20) : (attempts += 1) {
            if (try o.acquire(gpa, 100)) got += 1;
        }
        try log.print("output {f}: {d}/{d} frames copied as BGRA {d}x{d}\n", .{ std.unicode.fmtUtf16Le(std.mem.sliceTo(&o.name, 0)), got, opts.frames, o.width, o.height });
        if (got == opts.frames) frames_ok += 1;
    }

    // 4. Snapshot latency (p50/p95) on the reference target.
    const target_hwnd = switch (opts.target) {
        .foreground => fg,
        .taskbar => w.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd"), null),
    };
    const lat = try gpa.alloc(u64, opts.samples);
    defer gpa.free(lat);
    var target_nodes: usize = 0;
    for (lat) |*l| {
        const t0 = nowNs();
        target_nodes = try uia.snapshot(target_hwnd, null);
        l.* = nowNs() - t0;
    }
    std.mem.sort(u64, lat, {}, std.sort.asc(u64));
    const p50 = percentile(lat, 0.50);
    const p95 = percentile(lat, 0.95);
    try log.print("snapshot {t}: {d} elements, p50 {d} us, p95 {d} us over {d} samples\n", .{ opts.target, target_nodes, p50 / 1000, p95 / 1000, opts.samples });

    // 5. Target closed mid-snapshot: the element is obtained, its window is
    // destroyed, then the descendant query must fail with a typed error.
    var closed_before = counters();
    var typed_errors: usize = 0;
    for (targets, 0..) |t, ti| {
        if (ti == targets.len / 2) closed_before = counters();
        const root = try uia.elementFromHandle(t);
        defer release(root);
        _ = w.PostMessageW(t, w.WM_CLOSE, 0, 0);
        while (w.IsWindow(t) != 0) w.Sleep(1);
        if (uia.snapshotElement(root, null)) |_| {} else |err| switch (err) {
            error.ElementNotAvailable => typed_errors += 1,
            else => {
                try log.print("closed target: unexpected {t} hr=0x{x}\n", .{ err, @as(u32, @bitCast(last_hr)) });
            },
        }
    }
    const closed_after = counters();
    try log.print("closed targets: {d}/{d} returned error.ElementNotAvailable; second half: handles {d} -> {d}, private {d} -> {d} KB\n", .{ typed_errors, targets.len, closed_before.handles, closed_after.handles, closed_before.private_bytes / 1024, closed_after.private_bytes / 1024 });

    // 6. Leak test: N iterations of snapshot + frame.
    var leak_before: Counters = counters();
    var leak_after: Counters = leak_before;
    var leak_frames: usize = 0;
    if (opts.leak > 0) {
        const warmup = @min(opts.leak, 200);
        for (0..warmup) |_| {
            _ = try uia.snapshot(target_hwnd, null);
            _ = try outputs.items[0].acquire(gpa, 0);
        }
        leak_before = counters();
        for (0..opts.leak) |i| {
            _ = try uia.snapshot(target_hwnd, null);
            if (try outputs.items[0].acquire(gpa, 0)) leak_frames += 1;
            if ((i + 1) % 2000 == 0) {
                const c = counters();
                try log.print("leak {d}: private {d} KB, handles {d}\n", .{ i + 1, c.private_bytes / 1024, c.handles });
                try log.flush();
            }
        }
        leak_after = counters();
    }
    const closed_handle_drift: i64 = @as(i64, closed_after.handles) - @as(i64, closed_before.handles);
    const drift_bytes: i64 = @as(i64, @intCast(leak_after.private_bytes)) - @as(i64, @intCast(leak_before.private_bytes));
    const drift_handles: i64 = @as(i64, leak_after.handles) - @as(i64, leak_before.handles);
    try log.print("leak: {d} iterations ({d} new frames), private bytes drift {d} KB, handle drift {d}\n", .{ opts.leak, leak_frames, @divTrunc(drift_bytes, 1024), drift_handles });

    try log.print("RESULT {{\"foreground_elements\":{d},\"outputs\":{d},\"outputs_with_all_frames\":{d},\"frames_per_output\":{d},\"snapshot_target\":\"{t}\",\"snapshot_elements\":{d},\"snapshot_p50_us\":{d},\"snapshot_p95_us\":{d},\"closed_targets\":{d},\"closed_typed_errors\":{d},\"closed_handle_drift\":{d},\"leak_iterations\":{d},\"leak_frames\":{d},\"private_drift_bytes\":{d},\"handle_drift\":{d}}}\n", .{
        fg_nodes,    outputs.items.len, frames_ok,           opts.frames, opts.target, target_nodes, p50 / 1000,    p95 / 1000,
        targets.len, typed_errors,      closed_handle_drift, opts.leak,   leak_frames, drift_bytes,  drift_handles,
    });

    const ok = frames_ok == outputs.items.len and typed_errors == targets.len and closed_handle_drift <= 0 and
        drift_bytes < 5 * 1024 * 1024 and drift_handles <= 0;
    return if (ok) 0 else 1;
}
