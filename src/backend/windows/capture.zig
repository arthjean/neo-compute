//! DXGI Desktop Duplication, one persistent duplication per output, created
//! on the adapter that owns the output. Frames are copied in desktop
//! orientation (rotation undone) into a BGRA buffer at the output's physical
//! resolution, and kept: an unchanged screen is served from that buffer.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const display = @import("../../core/display.zig");
const image = @import("../../core/image.zig");
const window = @import("window.zig");
const check = com.check;
const release = com.release;

pub const Error = com.Error || error{ NoOutputs, UnexpectedFrameFormat, OutOfMemory, AccessLost, Unsupported, GdiFailed };

pub const Output = struct {
    desc: w.DXGI_OUTPUT_DESC,
    output1: *w.IDXGIOutput1,
    device: *w.ID3D11Device,
    context: *w.ID3D11DeviceContext,
    dup: ?*w.IDXGIOutputDuplication = null,
    /// HRESULT of the last failed DuplicateOutput, when `dup` is null.
    dup_hr: w.HRESULT = 0,
    rotation: image.Rotation = .identity,
    staging: ?*w.ID3D11Texture2D = null,
    panel_w: u32 = 0,
    panel_h: u32 = 0,
    /// Latest frame, desktop orientation, tightly packed.
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    has_frame: bool = false,
    /// The staging texture holds a newer frame than `pixels`: a look for
    /// changes copied it on the GPU without reading it back (US-030).
    unread: bool = false,
    /// The GDI fallback was reported on stderr since the last duplication
    /// (US-032): once per loss, not once per capture.
    fallback_logged: bool = false,
    name_buf: [96]u8 = undefined,
    name_len: usize = 0,
    adapter_buf: [128]u8 = undefined,
    adapter_len: usize = 0,
    /// Regions updated since the last `beginCapture`, desktop coordinates.
    dirty: std.ArrayList(display.Rect) = .empty,
    moved: std.ArrayList(display.Rect) = .empty,
    meta: []u8 = &.{},

    pub fn rect(self: *const Output) w.RECT {
        return self.desc.DesktopCoordinates;
    }

    pub fn name(self: *const Output) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn adapterName(self: *const Output) []const u8 {
        return self.adapter_buf[0..self.adapter_len];
    }

    /// (Re)creates the duplication. A failure leaves `dup` null and the
    /// HRESULT in `dup_hr`.
    pub fn duplicate(self: *Output) Error!void {
        if (self.dup) |d| release(d);
        self.dup = null;
        var dup: ?*w.IDXGIOutputDuplication = null;
        const hr = self.output1.vtable.DuplicateOutput(self.output1, @ptrCast(self.device), &dup);
        if (hr < 0) {
            self.dup_hr = hr;
            com.last_hr = hr;
            if (hr == w.DXGI_ERROR_UNSUPPORTED) return error.Unsupported;
            return error.ComCallFailed;
        }
        self.dup = dup.?;
        self.fallback_logged = false;
        var dd: w.DXGI_OUTDUPL_DESC = undefined;
        dup.?.vtable.GetDesc(dup.?, &dd);
        self.rotation = switch (dd.Rotation) {
            w.DXGI_MODE_ROTATION_ROTATE90 => .rotate90,
            w.DXGI_MODE_ROTATION_ROTATE180 => .rotate180,
            w.DXGI_MODE_ROTATION_ROTATE270 => .rotate270,
            else => .identity,
        };
        self.has_frame = false;
    }

    pub fn beginCapture(self: *Output) void {
        self.dirty.clearRetainingCapacity();
        self.moved.clearRetainingCapacity();
    }

    /// Acquires a new frame if one is ready within `timeout_ms` and copies
    /// it into `pixels`, or with `read` false only into the staging texture
    /// (`unread`: the CPU copy, about 2 ms at 2560x1440, waits for a caller
    /// that needs the pixels). Returns false when the screen did not change
    /// (the previous frame stays valid). `error.AccessLost` means the
    /// duplication was invalidated (mode change, UAC, exclusive full screen).
    pub fn acquire(self: *Output, gpa: std.mem.Allocator, timeout_ms: u32, read: bool) Error!bool {
        const dup = self.dup orelse return error.AccessLost;
        var info: w.DXGI_OUTDUPL_FRAME_INFO = undefined;
        var resource: ?*w.IDXGIResource = null;
        const code = dup.vtable.AcquireNextFrame(dup, timeout_ms, &info, &resource);
        if (code == w.DXGI_ERROR_WAIT_TIMEOUT) return false;
        if (code == w.DXGI_ERROR_ACCESS_LOST) {
            com.last_hr = code;
            return error.AccessLost;
        }
        try check(code);
        defer _ = dup.vtable.ReleaseFrame(dup);
        defer release(resource.?);
        if (info.LastPresentTime == 0 and self.has_frame) return false; // pointer-only update

        var raw: ?*anyopaque = null;
        try check(resource.?.vtable.QueryInterface(resource.?, &w.ID3D11Texture2D.iid, &raw));
        const tex: *w.ID3D11Texture2D = @ptrCast(@alignCast(raw.?));
        defer release(tex);
        var desc: w.D3D11_TEXTURE2D_DESC = undefined;
        tex.vtable.GetDesc(tex, &desc);
        if (desc.Format != w.DXGI_FORMAT_B8G8R8A8_UNORM) return error.UnexpectedFrameFormat;

        const r = self.rect();
        const dw: u32 = @intCast(r.right - r.left);
        const dh: u32 = @intCast(r.bottom - r.top);
        if (self.staging == null or self.panel_w != desc.Width or self.panel_h != desc.Height or self.width != dw or self.height != dh) {
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
            sd.CPUAccessFlags = @bitCast(w.D3D11_CPU_ACCESS_READ);
            sd.MiscFlags = 0;
            try check(self.device.vtable.CreateTexture2D(self.device, &sd, null, &self.staging));
            self.pixels = try gpa.alloc(u8, @as(usize, dw) * dh * 4);
            self.panel_w = desc.Width;
            self.panel_h = desc.Height;
            self.width = dw;
            self.height = dh;
        }
        if (info.TotalMetadataBufferSize > 0) try self.readRects(gpa, dup, info.TotalMetadataBufferSize);
        if (!self.has_frame) try self.dirty.append(gpa, .{ .x = r.left, .y = r.top, .w = @intCast(dw), .h = @intCast(dh) });
        self.context.vtable.CopyResource(self.context, @ptrCast(self.staging.?), @ptrCast(tex));
        if (read or !self.has_frame) {
            try self.readback();
            self.unread = false;
        } else self.unread = true;
        self.has_frame = true;
        return true;
    }

    /// Dirty and move rects of the acquired frame, turned from panel to
    /// desktop coordinates and appended to the accumulated lists.
    fn readRects(self: *Output, gpa: std.mem.Allocator, dup: *w.IDXGIOutputDuplication, size: u32) Error!void {
        if (self.meta.len < size) {
            gpa.free(self.meta);
            self.meta = &.{};
            self.meta = try gpa.alloc(u8, size);
        }
        const r = self.rect();
        const dw = r.right - r.left;
        const dh = r.bottom - r.top;
        var used: u32 = 0;
        const moves: [*]w.DXGI_OUTDUPL_MOVE_RECT = @ptrCast(@alignCast(self.meta.ptr));
        try check(dup.vtable.GetFrameMoveRects(dup, size, @ptrCast(moves), &used));
        for (moves[0 .. used / @sizeOf(w.DXGI_OUTDUPL_MOVE_RECT)]) |m| {
            const d = image.panelRectToDesktop(self.rotation, dw, dh, fromRect(m.DestinationRect));
            try self.moved.append(gpa, .{ .x = d.x + r.left, .y = d.y + r.top, .w = d.w, .h = d.h });
        }
        const rest = size - used;
        const rects: [*]w.RECT = @ptrCast(@alignCast(self.meta.ptr + used));
        var dirty_used: u32 = 0;
        try check(dup.vtable.GetFrameDirtyRects(dup, rest, @ptrCast(rects), &dirty_used));
        for (rects[0 .. dirty_used / @sizeOf(w.RECT)]) |pr| {
            const d = image.panelRectToDesktop(self.rotation, dw, dh, fromRect(pr));
            try self.dirty.append(gpa, .{ .x = d.x + r.left, .y = d.y + r.top, .w = d.w, .h = d.h });
        }
    }

    /// Copies the staging texture (the latest frame) into `pixels` in
    /// desktop orientation.
    pub fn readback(self: *Output) Error!void {
        const staging = self.staging orelse return;
        var mapped: w.D3D11_MAPPED_SUBRESOURCE = undefined;
        try check(self.context.vtable.Map(self.context, @ptrCast(staging), 0, w.D3D11_MAP_READ, 0, &mapped));
        defer self.context.vtable.Unmap(self.context, @ptrCast(staging), 0);
        image.copyRotated(self.rotation, self.pixels, self.width, self.height, @ptrCast(mapped.pData.?), mapped.RowPitch);
    }

    pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        if (self.staging) |s| release(s);
        gpa.free(self.pixels);
        gpa.free(self.meta);
        self.dirty.deinit(gpa);
        self.moved.deinit(gpa);
        if (self.dup) |d| release(d);
        release(self.output1);
        release(self.context);
        release(self.device);
    }
};

fn fromRect(r: w.RECT) display.Rect {
    return .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
}

fn utf8Into(buf: []u8, wide: []const u16) usize {
    const end = std.mem.indexOfScalar(u16, wide, 0) orelse wide.len;
    return std.unicode.wtf16LeToWtf8(buf, wide[0..@min(end, buf.len / 3)]);
}

pub const Capture = struct {
    factory: *w.IDXGIFactory1,
    /// Primary output first, then by position.
    outputs: std.ArrayList(Output) = .empty,

    /// Enumerates every output attached to the desktop and duplicates it on
    /// its own adapter. An output whose duplication fails is kept, with the
    /// failure recorded, so it can be named in errors.
    /// Without `duplicate` (GDI forced, US-032) the outputs are enumerated
    /// without a duplication: a process holds one per output at most.
    pub fn init(gpa: std.mem.Allocator, duplicate: bool) Error!Capture {
        var raw: ?*anyopaque = null;
        try check(w.CreateDXGIFactory1(&w.IDXGIFactory1.iid, &raw));
        var self: Capture = .{ .factory = @ptrCast(@alignCast(raw.?)) };
        errdefer self.deinit(gpa);

        var ai: u32 = 0;
        while (true) : (ai += 1) {
            var adapter: ?*w.IDXGIAdapter1 = null;
            const ahr = self.factory.vtable.EnumAdapters1(self.factory, ai, &adapter);
            if (ahr == w.DXGI_ERROR_NOT_FOUND) break;
            try check(ahr);
            defer release(adapter.?);
            var adesc: w.DXGI_ADAPTER_DESC1 = undefined;
            try check(adapter.?.vtable.GetDesc1(adapter.?, &adesc));
            var oi: u32 = 0;
            while (true) : (oi += 1) {
                var out: ?*w.IDXGIOutput = null;
                const ohr = adapter.?.vtable.EnumOutputs(adapter.?, oi, &out);
                if (ohr == w.DXGI_ERROR_NOT_FOUND) break;
                try check(ohr);
                defer release(out.?);
                var o1raw: ?*anyopaque = null;
                try check(out.?.vtable.QueryInterface(out.?, &w.IDXGIOutput1.iid, &o1raw));
                const output1: *w.IDXGIOutput1 = @ptrCast(@alignCast(o1raw.?));
                var desc: w.DXGI_OUTPUT_DESC = undefined;
                check(output1.vtable.GetDesc(output1, &desc)) catch |e| {
                    release(output1);
                    return e;
                };
                if (desc.AttachedToDesktop == 0) {
                    release(output1);
                    continue;
                }
                var device: ?*w.ID3D11Device = null;
                var context: ?*w.ID3D11DeviceContext = null;
                check(w.D3D11CreateDevice(@ptrCast(adapter.?), w.D3D_DRIVER_TYPE_UNKNOWN, null, 0, null, 0, w.D3D11_SDK_VERSION, &device, null, &context)) catch |e| {
                    release(output1);
                    return e;
                };
                var o: Output = .{ .desc = desc, .output1 = output1, .device = device.?, .context = context.? };
                o.name_len = utf8Into(&o.name_buf, &desc.DeviceName);
                o.adapter_len = utf8Into(&o.adapter_buf, &adesc.Description);
                if (duplicate) o.duplicate() catch {}; // recorded in dup_hr
                self.outputs.append(gpa, o) catch |e| {
                    o.deinit(gpa);
                    return e;
                };
            }
        }
        if (self.outputs.items.len == 0) return error.NoOutputs;
        std.mem.sort(Output, self.outputs.items, {}, struct {
            fn lt(_: void, a: Output, b: Output) bool {
                const ap = a.desc.DesktopCoordinates.left == 0 and a.desc.DesktopCoordinates.top == 0;
                const bp = b.desc.DesktopCoordinates.left == 0 and b.desc.DesktopCoordinates.top == 0;
                if (ap != bp) return ap;
                if (a.desc.DesktopCoordinates.left != b.desc.DesktopCoordinates.left) return a.desc.DesktopCoordinates.left < b.desc.DesktopCoordinates.left;
                return a.desc.DesktopCoordinates.top < b.desc.DesktopCoordinates.top;
            }
        }.lt);
        return self;
    }

    /// False once the set of adapters or outputs changed (display plugged,
    /// unplugged or reconfigured): the caller re-enumerates.
    pub fn isCurrent(self: *Capture) bool {
        return self.factory.vtable.IsCurrent(self.factory) != 0;
    }

    pub fn deinit(self: *Capture, gpa: std.mem.Allocator) void {
        for (self.outputs.items) |*o| o.deinit(gpa);
        self.outputs.deinit(gpa);
        release(self.factory);
    }
};

/// True when the input desktop is not the user's default desktop: UAC
/// prompt, Ctrl+Alt+Del screen or lock screen. A non-system process cannot
/// even open the secure desktop.
pub fn secureDesktopActive() bool {
    const desk = w.OpenInputDesktop(0, 0, w.DESKTOP_READOBJECTS) orelse return true;
    defer _ = w.CloseDesktop(desk);
    var name: [64]u16 = undefined;
    var needed: u32 = 0;
    if (w.GetUserObjectInformationW(desk, w.UOI_NAME, &name, @sizeOf(@TypeOf(name)), &needed) == 0) return false;
    const len = std.mem.indexOfScalar(u16, &name, 0) orelse name.len;
    return !std.mem.eql(u16, name[0..len], std.unicode.utf8ToUtf16LeStringLiteral("Default"));
}

/// BitBlt copy of one display into a top-down 32-bit DIB section (US-032),
/// the fallback when DXGI duplication is refused: `CAPTUREBLT` includes
/// layered windows, and a window protected against capture
/// (`WDA_MONITOR`, DRM video) shows black. No dirty rects: the core tells a
/// still screen by fingerprints.
pub const Gdi = struct {
    screen: w.HDC = null,
    memory: w.HDC = null,
    bitmap: w.HBITMAP = null,
    previous: w.HGDIOBJ = null,
    bits: [*]u8 = undefined,
    width: u32 = 0,
    height: u32 = 0,

    /// Copies `part` (desktop coordinates, inside display `r`: the whole
    /// display, or the window a look for changes watches) to the top-left
    /// of a DIB section the size of `r`, and returns its BGRA pixels, rows
    /// `r.w * 4` bytes apart, valid until the next call. A window costs a
    /// fraction of a full 2560x1440 copy (about 20 ms).
    pub fn grab(self: *Gdi, r: display.Rect, part: display.Rect) Error![]const u8 {
        std.debug.assert(part.x >= r.x and part.y >= r.y and part.right() <= r.right() and part.bottom() <= r.bottom());
        const width: u32 = @intCast(r.w);
        const height: u32 = @intCast(r.h);
        if (self.bitmap == null or self.width != width or self.height != height) try self.allocate(width, height);
        if (w.BitBlt(self.memory, 0, 0, part.w, part.h, self.screen, part.x, part.y, w.SRCCOPY | w.CAPTUREBLT) == 0) return error.GdiFailed;
        // A DIB section's bits are current only once GDI's batch is flushed.
        _ = w.GdiFlush();
        const stride = @as(usize, width) * 4;
        return self.bits[0 .. (@as(usize, @intCast(part.h)) - 1) * stride + @as(usize, @intCast(part.w)) * 4];
    }

    fn allocate(self: *Gdi, width: u32, height: u32) Error!void {
        self.deinit();
        self.screen = w.GetDC(null) orelse return error.GdiFailed;
        self.memory = w.CreateCompatibleDC(self.screen) orelse return error.GdiFailed;
        var info = std.mem.zeroes(w.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = @intCast(width);
        // Negative: top-down rows, as the rest of the pipeline expects.
        info.bmiHeader.biHeight = -@as(i32, @intCast(height));
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = w.BI_RGB;
        var bits: ?*anyopaque = null;
        self.bitmap = w.CreateDIBSection(self.memory, &info, w.DIB_RGB_COLORS, &bits, null, 0) orelse return error.GdiFailed;
        self.bits = @ptrCast(bits orelse return error.GdiFailed);
        self.previous = w.SelectObject(self.memory, self.bitmap);
        self.width = width;
        self.height = height;
    }

    pub fn deinit(self: *Gdi) void {
        if (self.memory != null) {
            if (self.previous != null) _ = w.SelectObject(self.memory, self.previous);
            _ = w.DeleteDC(self.memory);
        }
        if (self.bitmap != null) _ = w.DeleteObject(self.bitmap);
        if (self.screen != null) _ = w.ReleaseDC(null, self.screen);
        self.* = .{};
    }
};

/// PrintWindow copy of one window into a top-down 32-bit DIB section
/// (US-061): the window as DWM composes it, whatever covers it on screen
/// (`PW_RENDERFULLCONTENT`; without the flag a window drawn by DirectX,
/// Chromium or XAML, comes back black). Measured by `capture-probe`
/// (US-060, decision 0013). The call sends the window messages: a window
/// whose thread does not answer is never captured.
pub const WindowShot = struct {
    screen: w.HDC = null,
    memory: w.HDC = null,
    bitmap: w.HBITMAP = null,
    previous: w.HGDIOBJ = null,
    bits: [*]u8 = undefined,
    width: u32 = 0,
    height: u32 = 0,

    pub const Shot = struct {
        /// BGRA rows of the visible frame, `stride` bytes apart, valid
        /// until the next call.
        pixels: []const u8,
        width: u32,
        height: u32,
        stride: usize,
        /// The visible frame, physical desktop pixels.
        rect: display.Rect,
    };

    pub const Result = union(enum) {
        ok: Shot,
        closed,
        minimized,
        /// The window's thread did not answer within 200 ms.
        hung,
        /// Windows scales the window (an application without per-monitor
        /// DPI support on a scaled display): PrintWindow renders it at its
        /// own resolution, where no desktop rectangle applies.
        scaled,
        failed,
    };

    pub fn grab(self: *WindowShot, hwnd: w.HWND) Result {
        if (hwnd == null or w.IsWindow(hwnd) == 0) return .closed;
        if (w.IsIconic(hwnd) != 0) return .minimized;
        if (!window.answers(hwnd)) return .hung;
        var wr: w.RECT = undefined;
        if (w.GetWindowRect(hwnd, &wr) == 0) return .closed;
        const frame = window.rect(hwnd) orelse return .closed;
        if (wr.right <= wr.left or wr.bottom <= wr.top or frame.w <= 0 or frame.h <= 0) return .failed;
        if (scaledByWindows(hwnd)) return .scaled;
        const width: u32 = @intCast(wr.right - wr.left);
        const height: u32 = @intCast(wr.bottom - wr.top);
        if (self.bitmap == null or self.width != width or self.height != height) self.allocate(width, height) catch return .failed;
        const stride = @as(usize, width) * 4;
        // A call that draws nothing must read as black, never as the
        // capture before it.
        @memset(self.bits[0 .. stride * height], 0);
        if (w.PrintWindow(hwnd, self.memory, w.PW_RENDERFULLCONTENT) == 0) return .failed;
        _ = w.GdiFlush();
        // The image is the window rectangle; its invisible resize borders
        // are left out, as in every rectangle neo-compute reports.
        const x0: u32 = @intCast(std.math.clamp(frame.x - wr.left, 0, @as(i32, @intCast(width)) - 1));
        const y0: u32 = @intCast(std.math.clamp(frame.y - wr.top, 0, @as(i32, @intCast(height)) - 1));
        const fw: u32 = @min(@as(u32, @intCast(frame.w)), width - x0);
        const fh: u32 = @min(@as(u32, @intCast(frame.h)), height - y0);
        const start = y0 * stride + @as(usize, x0) * 4;
        return .{ .ok = .{
            .pixels = self.bits[start .. start + @as(usize, fh - 1) * stride + @as(usize, fw) * 4],
            .width = fw,
            .height = fh,
            .stride = stride,
            .rect = .{ .x = wr.left + @as(i32, @intCast(x0)), .y = wr.top + @as(i32, @intCast(y0)), .w = @intCast(fw), .h = @intCast(fh) },
        } };
    }

    fn allocate(self: *WindowShot, width: u32, height: u32) Error!void {
        self.deinit();
        self.screen = w.GetDC(null) orelse return error.GdiFailed;
        self.memory = w.CreateCompatibleDC(self.screen) orelse return error.GdiFailed;
        var info = std.mem.zeroes(w.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = @intCast(width);
        info.bmiHeader.biHeight = -@as(i32, @intCast(height));
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = w.BI_RGB;
        var bits: ?*anyopaque = null;
        self.bitmap = w.CreateDIBSection(self.memory, &info, w.DIB_RGB_COLORS, &bits, null, 0) orelse return error.GdiFailed;
        self.bits = @ptrCast(bits orelse return error.GdiFailed);
        self.previous = w.SelectObject(self.memory, self.bitmap);
        self.width = width;
        self.height = height;
    }

    pub fn deinit(self: *WindowShot) void {
        if (self.memory != null) {
            if (self.previous != null) _ = w.SelectObject(self.memory, self.previous);
            _ = w.DeleteDC(self.memory);
        }
        if (self.bitmap != null) _ = w.DeleteObject(self.bitmap);
        if (self.screen != null) _ = w.ReleaseDC(null, self.screen);
        self.* = .{};
    }
};

/// Whether the window renders at another DPI than its display's: this
/// process sees physical pixels (per-monitor v2), a window that does not is
/// drawn at its own DPI and stretched by DWM.
fn scaledByWindows(hwnd: w.HWND) bool {
    const own = w.GetDpiForWindow(hwnd);
    if (own == 0) return false;
    var dx: u32 = 0;
    var dy: u32 = 0;
    if (w.GetDpiForMonitor(w.MonitorFromWindow(hwnd, w.MONITOR_DEFAULTTONEAREST), w.MDT_EFFECTIVE_DPI, &dx, &dy) < 0) return false;
    return dx != 0 and dx != own;
}
