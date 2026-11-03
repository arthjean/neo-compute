//! DXGI Desktop Duplication, one duplication per output, created on the
//! adapter that owns the output. Frames are copied to a BGRA buffer at the
//! output's physical resolution.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const check = com.check;
const release = com.release;

pub const Error = com.Error || error{ NoOutputs, UnexpectedFrameFormat, OutOfMemory };

pub const Output = struct {
    desc: w.DXGI_OUTPUT_DESC,
    device: *w.ID3D11Device,
    context: *w.ID3D11DeviceContext,
    dup: *w.IDXGIOutputDuplication,
    staging: ?*w.ID3D11Texture2D = null,
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    has_frame: bool = false,

    pub fn rect(self: *const Output) w.RECT {
        return self.desc.DesktopCoordinates;
    }

    /// Acquires a new frame if one is ready within `timeout_ms` and copies it
    /// into `pixels`. Returns false when the screen did not change (the
    /// previous frame stays valid).
    pub fn acquire(self: *Output, gpa: std.mem.Allocator, timeout_ms: u32) Error!bool {
        var info: w.DXGI_OUTDUPL_FRAME_INFO = undefined;
        var resource: ?*w.IDXGIResource = null;
        const code = self.dup.vtable.AcquireNextFrame(self.dup, timeout_ms, &info, &resource);
        if (code == w.DXGI_ERROR_WAIT_TIMEOUT) return false;
        try check(code);
        defer _ = self.dup.vtable.ReleaseFrame(self.dup);
        defer release(resource.?);
        if (info.LastPresentTime == 0 and self.has_frame) return false; // pointer-only update

        var raw: ?*anyopaque = null;
        try check(resource.?.vtable.QueryInterface(resource.?, &w.ID3D11Texture2D.iid, &raw));
        const tex: *w.ID3D11Texture2D = @ptrCast(@alignCast(raw.?));
        defer release(tex);
        var desc: w.D3D11_TEXTURE2D_DESC = undefined;
        tex.vtable.GetDesc(tex, &desc);
        if (desc.Format != w.DXGI_FORMAT_B8G8R8A8_UNORM) return error.UnexpectedFrameFormat;

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
            sd.CPUAccessFlags = @bitCast(w.D3D11_CPU_ACCESS_READ);
            sd.MiscFlags = 0;
            try check(self.device.vtable.CreateTexture2D(self.device, &sd, null, &self.staging));
            self.pixels = try gpa.alloc(u8, @as(usize, desc.Width) * desc.Height * 4);
            self.width = desc.Width;
            self.height = desc.Height;
        }
        self.context.vtable.CopyResource(self.context, @ptrCast(self.staging.?), @ptrCast(tex));
        try self.readback();
        self.has_frame = true;
        return true;
    }

    /// Copies the staging texture (the latest frame) into `pixels`.
    pub fn readback(self: *Output) Error!void {
        const staging = self.staging orelse return;
        var mapped: w.D3D11_MAPPED_SUBRESOURCE = undefined;
        try check(self.context.vtable.Map(self.context, @ptrCast(staging), 0, w.D3D11_MAP_READ, 0, &mapped));
        defer self.context.vtable.Unmap(self.context, @ptrCast(staging), 0);
        const src: [*]const u8 = @ptrCast(mapped.pData.?);
        const row = @as(usize, self.width) * 4;
        for (0..self.height) |y| @memcpy(self.pixels[y * row ..][0..row], src[y * mapped.RowPitch ..][0..row]);
    }

    /// BGRA pixel at desktop coordinates, if inside this output.
    pub fn pixelAt(self: *const Output, x: i32, y: i32) ?[4]u8 {
        const r = self.rect();
        if (x < r.left or y < r.top or x >= r.right or y >= r.bottom or self.pixels.len == 0) return null;
        const px: usize = @intCast(x - r.left);
        const py: usize = @intCast(y - r.top);
        const i = (py * self.width + px) * 4;
        return self.pixels[i..][0..4].*;
    }

    pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        if (self.staging) |s| release(s);
        gpa.free(self.pixels);
        release(self.dup);
        release(self.context);
        release(self.device);
    }
};

pub const Capture = struct {
    outputs: std.ArrayList(Output) = .empty,

    pub fn init(gpa: std.mem.Allocator) Error!Capture {
        var self: Capture = .{};
        errdefer self.deinit(gpa);
        var raw: ?*anyopaque = null;
        try check(w.CreateDXGIFactory1(&w.IDXGIFactory1.iid, &raw));
        const factory: *w.IDXGIFactory1 = @ptrCast(@alignCast(raw.?));
        defer release(factory);

        var ai: u32 = 0;
        while (true) : (ai += 1) {
            var adapter: ?*w.IDXGIAdapter1 = null;
            const ahr = factory.vtable.EnumAdapters1(factory, ai, &adapter);
            if (ahr == w.DXGI_ERROR_NOT_FOUND) break;
            try check(ahr);
            defer release(adapter.?);
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
                defer release(output1);
                var desc: w.DXGI_OUTPUT_DESC = undefined;
                try check(output1.vtable.GetDesc(output1, &desc));
                if (desc.AttachedToDesktop == 0) continue;
                var device: ?*w.ID3D11Device = null;
                var context: ?*w.ID3D11DeviceContext = null;
                try check(w.D3D11CreateDevice(@ptrCast(adapter.?), w.D3D_DRIVER_TYPE_UNKNOWN, null, 0, null, 0, w.D3D11_SDK_VERSION, &device, null, &context));
                errdefer {
                    release(context.?);
                    release(device.?);
                }
                var dup: ?*w.IDXGIOutputDuplication = null;
                try check(output1.vtable.DuplicateOutput(output1, @ptrCast(device.?), &dup));
                try self.outputs.append(gpa, .{ .desc = desc, .device = device.?, .context = context.?, .dup = dup.? });
            }
        }
        if (self.outputs.items.len == 0) return error.NoOutputs;
        return self;
    }

    /// Output whose desktop rectangle contains the point.
    pub fn outputAt(self: *Capture, x: i32, y: i32) ?*Output {
        for (self.outputs.items) |*o| {
            const r = o.rect();
            if (x >= r.left and y >= r.top and x < r.right and y < r.bottom) return o;
        }
        return null;
    }

    pub fn deinit(self: *Capture, gpa: std.mem.Allocator) void {
        for (self.outputs.items) |*o| o.deinit(gpa);
        self.outputs.deinit(gpa);
    }
};
