//! An EI client in native Zig (US-080, decision 0014 D12, D14): a sender
//! context on the descriptor that `ConnectToEIS` gives, whether Mutter's
//! RemoteDesktop session, KWin's `org.kde.KWin.EIS.RemoteDesktop` or the
//! RemoteDesktop portal returned it. Interfaces come from the generated
//! `protocols` module; the request sequence is libei 1.6's, which the byte
//! test replays against Mutter's recorded answers.
//!
//! The context owns the only copy of its descriptor (received
//! close-on-exec, never duplicated): `close` releases every device and
//! closes it, so the compositor releases what is held before the session's
//! `Stop` (audit 4.1, the duplicated descriptor trap).

const std = @import("std");
const linux = std.os.linux;
const sock = @import("sock.zig");
const proto = @import("protocols");
const Allocator = std.mem.Allocator;

pub const ifaces = proto.ei;
pub const Interface = proto.Interface;

pub const suspended_text = "Entrée suspendue par le compositeur : réessaie dans un instant.";

pub const Error = error{
    OutOfMemory,
    Disconnected,
    Timeout,
    /// A message from the server breaks the wire format.
    Malformed,
    /// The device is paused by the compositor: nothing was sent.
    Suspended,
    /// The device has no such capability.
    Unsupported,
    BadArguments,
};

pub const Arg = union(enum) {
    uint: u32,
    int: i32,
    uint64: u64,
    int64: i64,
    float: f32,
    string: ?[]const u8,
    object: u64,
    new_id: u64,
    fd: i32,
};

/// The capabilities a seat offers, by the interface that carries them.
pub const Capability = enum { pointer, pointer_absolute, scroll, button, keyboard, touchscreen, text };

pub const Region = struct { x: u32, y: u32, width: u32, height: u32, scale: f32 };

pub const Device = struct {
    id: u64,
    name_buf: [128]u8 = undefined,
    name_len: usize = 0,
    /// The objects of its interfaces, 0 when absent, in Capability order.
    objects: [7]u64 = @splat(0),
    /// Interface objects in the order the server created them.
    created: [7]u64 = @splat(0),
    created_len: usize = 0,
    regions: [8]Region = undefined,
    region_count: usize = 0,
    done: bool = false,
    resumed: bool = false,
    emulating: bool = false,
    sequence: u32 = 0,

    pub fn name(d: *const Device) []const u8 {
        return d.name_buf[0..d.name_len];
    }

    pub fn has(d: *const Device, cap: Capability) bool {
        return d.objects[@backingInt(cap)] != 0;
    }

    pub fn object(d: *const Device, cap: Capability) Error!u64 {
        const o = d.objects[@backingInt(cap)];
        return if (o != 0) o else error.Unsupported;
    }
};

pub const Keymap = struct {
    /// The XKB keymap text, mapped from the keyboard's descriptor.
    text: []const u8,
    group: u32 = 0,
};

pub const Context = struct {
    gpa: Allocator,
    fd: i32,
    rx: std.ArrayList(u8) = .empty,
    rx_fds: std.ArrayList(i32) = .empty,
    objects: std.AutoHashMapUnmanaged(u64, *const Interface) = .empty,
    next_id: u64 = 1,
    connection: u64 = 0,
    seat: u64 = 0,
    /// Capability masks of the seat, by Capability.
    seat_masks: [7]u64 = @splat(0),
    seat_done: bool = false,
    wanted: []const Capability,
    devices: std.ArrayList(Device) = .empty,
    last_serial: u32 = 0,
    sync_id: u64 = 0,
    synced: bool = false,
    keymap_map: ?[]align(std.heap.page_size_min) u8 = null,
    keymap_group: u32 = 0,
    /// Why the server disconnected or the last message was refused.
    problem: []const u8 = "",
    problem_buf: [256]u8 = undefined,
    /// The name the handshake gives the compositor.
    client_name: []const u8 = "neo-compute",

    /// Starts the handshake on `fd`, which the context now owns; `wanted`
    /// are the capabilities its seat binds.
    pub fn init(gpa: Allocator, fd: i32, wanted: []const Capability) Error!Context {
        var c: Context = .{ .gpa = gpa, .fd = fd, .wanted = wanted };
        try c.objects.put(gpa, 0, &ifaces.ei_handshake.interface);
        return c;
    }

    pub fn deinit(c: *Context) void {
        if (c.fd >= 0) _ = linux.close(c.fd);
        c.fd = -1;
        sock.closeAll(c.rx_fds.items);
        c.rx_fds.deinit(c.gpa);
        c.rx.deinit(c.gpa);
        c.objects.deinit(c.gpa);
        c.devices.deinit(c.gpa);
        if (c.keymap_map) |m| _ = linux.munmap(m.ptr, m.len);
        c.keymap_map = null;
    }

    /// Releases every device as libei does, disconnects, and closes the
    /// descriptor: the compositor releases any key or button still held.
    pub fn close(c: *Context) void {
        if (c.fd >= 0 and c.connection != 0) {
            for (c.devices.items) |*d| {
                for (d.created[0..d.created_len]) |o| c.request(o, 0, &.{}) catch {}; // every interface's `release` is opcode 0
                c.request(d.id, ifaces.ei_device.request.release, &.{}) catch {};
            }
            c.request(c.connection, ifaces.ei_connection.request.disconnect, &.{}) catch {};
        }
        if (c.fd >= 0) _ = linux.close(c.fd);
        c.fd = -1;
    }

    fn fail(c: *Context, err: Error, why: []const u8) Error {
        const n = @min(why.len, c.problem_buf.len);
        @memcpy(c.problem_buf[0..n], why[0..n]);
        c.problem = c.problem_buf[0..n];
        if (c.fd >= 0) _ = linux.close(c.fd);
        c.fd = -1;
        return err;
    }

    pub fn request(c: *Context, object: u64, opcode: u16, args: []const Arg) Error!void {
        if (c.fd < 0) return error.Disconnected;
        const iface = c.objects.get(object) orelse return error.BadArguments;
        if (opcode >= iface.requests.len) return error.BadArguments;
        const msg = iface.requests[opcode];
        if (msg.args.len != args.len) return error.BadArguments;
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var fds: [4]i32 = undefined;
        var nfds: usize = 0;
        w.writeInt(u64, object, .little) catch unreachable;
        w.writeInt(u32, 0, .little) catch unreachable;
        w.writeInt(u32, opcode, .little) catch unreachable;
        for (msg.args, args) |spec, a| {
            const ok = switch (spec.kind) {
                .uint => a == .uint,
                .int => a == .int,
                .uint64 => a == .uint64,
                .int64 => a == .int64,
                .float => a == .float,
                .string => a == .string,
                .object => a == .object,
                .new_id => a == .new_id,
                .fd => a == .fd,
                else => false,
            };
            if (!ok) return error.BadArguments;
            (switch (a) {
                .uint => |v| w.writeInt(u32, v, .little),
                .int => |v| w.writeInt(i32, v, .little),
                .uint64, .object, .new_id => |v| w.writeInt(u64, v, .little),
                .int64 => |v| w.writeInt(i64, v, .little),
                .float => |v| w.writeInt(u32, @bitCast(v), .little),
                .string => |v| blk: {
                    const s = v orelse break :blk w.writeInt(u32, 0, .little);
                    w.writeInt(u32, @intCast(s.len + 1), .little) catch |e| break :blk e;
                    w.writeAll(s) catch |e| break :blk e;
                    break :blk w.splatByteAll(0, std.mem.alignForward(usize, s.len + 1, 4) - s.len);
                },
                .fd => |v| blk: {
                    fds[nfds] = v;
                    nfds += 1;
                    break :blk {};
                },
            }) catch return error.BadArguments;
        }
        const bytes = w.buffered();
        std.mem.writeInt(u32, bytes[8..12], @intCast(bytes.len), .little);
        for (msg.args, args) |spec, a| if (a == .new_id) {
            const target = for (ifaces.all) |i| {
                if (std.mem.eql(u8, i.name, spec.interface orelse "")) break i;
            } else return error.BadArguments;
            try c.objects.put(c.gpa, a.new_id, target);
        };
        sock.sendAll(c.fd, bytes, fds[0..nfds]) catch return c.fail(error.Disconnected, "the EIS server closed the connection");
    }

    /// Reads once and handles every whole message.
    pub fn dispatch(c: *Context, deadline: ?u64) Error!void {
        if (c.fd < 0) return error.Disconnected;
        var buf: [16 * 1024]u8 = undefined;
        const n = sock.recvSome(c.fd, &buf, &c.rx_fds, c.gpa, deadline) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            error.OutOfMemory => return error.OutOfMemory,
            else => return c.fail(error.Disconnected, "the EIS server closed the connection"),
        };
        try c.rx.appendSlice(c.gpa, buf[0..n]);
        while (c.rx.items.len >= 16) {
            const object = std.mem.readInt(u64, c.rx.items[0..8], .little);
            const len = std.mem.readInt(u32, c.rx.items[8..12], .little);
            const opcode = std.mem.readInt(u32, c.rx.items[12..16], .little);
            if (len < 16 or len % 4 != 0 or len > 64 * 1024) return c.fail(error.Malformed, "message length below its header or above 64 KiB");
            if (c.rx.items.len < len) break;
            var msg_buf: [64 * 1024]u8 = undefined;
            const bytes = msg_buf[0..len];
            @memcpy(bytes, c.rx.items[0..len]);
            c.rx.replaceRangeAssumeCapacity(0, len, &.{});
            const iface = c.objects.get(object) orelse continue; // an object released here: dropped
            if (opcode >= iface.events.len) return c.fail(error.Malformed, "event opcode beyond its interface");
            try c.handle(object, iface, @intCast(opcode), bytes);
        }
    }

    fn handle(c: *Context, object: u64, iface: *const Interface, opcode: u16, bytes: []const u8) Error!void {
        const msg = iface.events[opcode];
        var args: [8]Arg = undefined;
        var pos: usize = 16;
        for (msg.args, 0..) |spec, i| {
            args[i] = switch (spec.kind) {
                .uint => .{ .uint = try c.u32At(bytes, &pos) },
                .int => .{ .int = @bitCast(try c.u32At(bytes, &pos)) },
                .float => .{ .float = @bitCast(try c.u32At(bytes, &pos)) },
                .uint64, .object, .new_id, .int64 => blk: {
                    const lo = try c.u32At(bytes, &pos);
                    const hi = try c.u32At(bytes, &pos);
                    const v = (@as(u64, hi) << 32) | lo;
                    break :blk switch (spec.kind) {
                        .uint64 => .{ .uint64 = v },
                        .int64 => .{ .int64 = @bitCast(v) },
                        .object => .{ .object = v },
                        else => .{ .new_id = v },
                    };
                },
                .string => blk: {
                    const len = try c.u32At(bytes, &pos);
                    if (len == 0) break :blk .{ .string = null };
                    const padded = std.mem.alignForward(usize, len, 4);
                    if (padded > bytes.len - pos or bytes[pos + len - 1] != 0) return c.fail(error.Malformed, "string past the message");
                    const s = bytes[pos..][0 .. len - 1];
                    pos += padded;
                    break :blk .{ .string = s };
                },
                .fd => blk: {
                    if (c.rx_fds.items.len == 0) return c.fail(error.Malformed, "descriptor announced and not received");
                    break :blk .{ .fd = c.rx_fds.orderedRemove(0) };
                },
                else => return c.fail(error.Malformed, "argument type outside EI"),
            };
        }
        if (pos != bytes.len) return c.fail(error.Malformed, "message longer than its arguments");
        const a = args[0..msg.args.len];
        // Objects the server creates take their interface from the XML or
        // from the string argument that names it.
        for (msg.args, a) |spec, v| if (v == .new_id) {
            const name = if (spec.interface) |n| n else if (spec.interface_arg) |ia| (a[ia].string orelse "") else "";
            if (findInterface(name)) |target| try c.objects.put(c.gpa, v.new_id, target);
        };
        try c.event(object, iface, opcode, a);
    }

    fn u32At(c: *Context, bytes: []const u8, pos: *usize) Error!u32 {
        if (bytes.len - pos.* < 4) return c.fail(error.Malformed, "argument past the message");
        const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
        pos.* += 4;
        return v;
    }

    fn findInterface(name: []const u8) ?*const Interface {
        for (ifaces.all) |i| if (std.mem.eql(u8, i.name, name)) return i;
        return null;
    }

    fn device(c: *Context, id: u64) ?*Device {
        for (c.devices.items) |*d| if (d.id == id) return d;
        return null;
    }

    fn deviceOf(c: *Context, object: u64) ?*Device {
        for (c.devices.items) |*d| for (d.created[0..d.created_len]) |o| if (o == object) return d;
        return null;
    }

    fn event(c: *Context, object: u64, iface: *const Interface, opcode: u16, a: []const Arg) Error!void {
        const E = struct {
            fn is(i: *const Interface, comptime ns: type) bool {
                return i == &ns.interface;
            }
        };
        if (E.is(iface, ifaces.ei_handshake)) {
            switch (opcode) {
                ifaces.ei_handshake.event.handshake_version => try c.hello(),
                ifaces.ei_handshake.event.connection => {
                    c.last_serial = a[0].uint;
                    c.connection = a[1].new_id;
                    // libei confirms the connection with a round trip.
                    c.sync_id = c.newId();
                    try c.request(c.connection, ifaces.ei_connection.request.sync, &.{ .{ .new_id = c.sync_id }, .{ .uint = ifaces.ei_callback.interface.version } });
                },
                else => {},
            }
        } else if (E.is(iface, ifaces.ei_connection)) {
            switch (opcode) {
                ifaces.ei_connection.event.ping => try c.request(a[0].new_id, ifaces.ei_pingpong.request.done, &.{.{ .uint64 = 0 }}),
                ifaces.ei_connection.event.seat => c.seat = a[0].new_id,
                ifaces.ei_connection.event.disconnected => {
                    var why_buf: [200]u8 = undefined;
                    const why = std.fmt.bufPrint(&why_buf, "disconnected by the EIS server (reason {d}): {s}", .{ a[1].uint, a[2].string orelse "" }) catch "disconnected by the EIS server";
                    return c.fail(error.Disconnected, why);
                },
                else => {},
            }
        } else if (E.is(iface, ifaces.ei_callback)) {
            if (object == c.sync_id) c.synced = true;
            _ = c.objects.remove(object);
        } else if (E.is(iface, ifaces.ei_seat)) {
            switch (opcode) {
                ifaces.ei_seat.event.capability => if (capabilityOf(a[1].string)) |cap| {
                    c.seat_masks[@backingInt(cap)] = a[0].uint64;
                },
                ifaces.ei_seat.event.done => {
                    c.seat_done = true;
                    var mask: u64 = 0;
                    for (c.wanted) |cap| mask |= c.seat_masks[@backingInt(cap)];
                    try c.request(c.seat, ifaces.ei_seat.request.bind, &.{.{ .uint64 = mask }});
                },
                ifaces.ei_seat.event.device => try c.devices.append(c.gpa, .{ .id = a[0].new_id }),
                else => {},
            }
        } else if (E.is(iface, ifaces.ei_device)) {
            const d = c.device(object) orelse return;
            switch (opcode) {
                ifaces.ei_device.event.name => {
                    const s = a[0].string orelse "";
                    d.name_len = @min(s.len, d.name_buf.len);
                    @memcpy(d.name_buf[0..d.name_len], s[0..d.name_len]);
                },
                ifaces.ei_device.event.region => if (d.region_count < d.regions.len) {
                    d.regions[d.region_count] = .{ .x = a[0].uint, .y = a[1].uint, .width = a[2].uint, .height = a[3].uint, .scale = a[4].float };
                    d.region_count += 1;
                },
                ifaces.ei_device.event.interface => {
                    if (capabilityOf(a[1].string)) |cap| d.objects[@backingInt(cap)] = a[0].new_id;
                    if (d.created_len < d.created.len) {
                        d.created[d.created_len] = a[0].new_id;
                        d.created_len += 1;
                    }
                },
                ifaces.ei_device.event.done => d.done = true,
                ifaces.ei_device.event.resumed => {
                    c.last_serial = a[0].uint;
                    d.resumed = true;
                },
                ifaces.ei_device.event.paused => {
                    c.last_serial = a[0].uint;
                    d.resumed = false;
                    d.emulating = false;
                },
                ifaces.ei_device.event.destroyed => {
                    c.last_serial = a[0].uint;
                    _ = c.objects.remove(object);
                    for (c.devices.items, 0..) |x, i| if (x.id == object) {
                        _ = c.devices.orderedRemove(i);
                        break;
                    };
                },
                else => {},
            }
        } else if (E.is(iface, ifaces.ei_keyboard)) {
            switch (opcode) {
                ifaces.ei_keyboard.event.keymap => {
                    const fd = a[2].fd;
                    defer _ = linux.close(fd);
                    if (a[0].uint != ifaces.ei_keyboard.enums.keymap_type.xkb or a[1].uint == 0) return;
                    const addr = linux.mmap(null, a[1].uint, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
                    if (linux.errno(addr) != .SUCCESS) return;
                    if (c.keymap_map) |m| _ = linux.munmap(m.ptr, m.len);
                    c.keymap_map = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(addr))[0..a[1].uint];
                },
                ifaces.ei_keyboard.event.modifiers => {
                    c.last_serial = a[0].uint;
                    c.keymap_group = a[4].uint;
                },
                else => {},
            }
        } else if (std.mem.eql(u8, iface.events[opcode].name, "destroyed")) {
            _ = c.objects.remove(object);
        }
    }

    fn newId(c: *Context) u64 {
        const id = c.next_id;
        c.next_id += 1;
        return id;
    }

    /// The handshake, in libei's order: versions, context type, name,
    /// every interface this client knows at its generated version, finish.
    fn hello(c: *Context) Error!void {
        try c.request(0, ifaces.ei_handshake.request.handshake_version, &.{.{ .uint = ifaces.ei_handshake.interface.version }});
        try c.request(0, ifaces.ei_handshake.request.context_type, &.{.{ .uint = @intCast(ifaces.ei_handshake.enums.context_type.sender) }});
        try c.request(0, ifaces.ei_handshake.request.name, &.{.{ .string = c.client_name }});
        for (ifaces.all) |i| if (i != &ifaces.ei_handshake.interface)
            try c.request(0, ifaces.ei_handshake.request.interface_version, &.{ .{ .string = i.name }, .{ .uint = i.version } });
        try c.request(0, ifaces.ei_handshake.request.finish, &.{});
    }

    /// Dispatches until the connection is set up and every device the
    /// seat announced is done.
    pub fn waitReady(c: *Context, deadline: ?u64) Error!void {
        while (!(c.synced and c.seat_done and c.devices.items.len > 0 and allDone(c.devices.items))) try c.dispatch(deadline);
    }

    fn allDone(ds: []const Device) bool {
        for (ds) |d| if (!d.done) return false;
        return true;
    }

    /// Dispatches until a device with `cap` is resumed.
    pub fn waitDevice(c: *Context, cap: Capability, deadline: ?u64) Error!*Device {
        while (true) {
            if (c.deviceWith(cap)) |d| if (d.done and d.resumed) return d;
            try c.dispatch(deadline);
        }
    }

    /// The first device with `cap`.
    pub fn deviceWith(c: *Context, cap: Capability) ?*Device {
        for (c.devices.items) |*d| if (d.has(cap)) return d;
        return null;
    }

    /// The keymap the compositor published, or null before it came.
    pub fn keymap(c: *const Context) ?Keymap {
        const m = c.keymap_map orelse return null;
        const end = std.mem.indexOfScalar(u8, m, 0) orelse m.len;
        return .{ .text = m[0..end], .group = c.keymap_group };
    }

    // ------------------------------------------------------------ sending

    /// Starts a sequence of events on `d`; refused while it is paused.
    pub fn start(c: *Context, d: *Device) Error!void {
        if (!d.resumed) return error.Suspended;
        if (d.emulating) return;
        d.sequence += 1;
        try c.request(d.id, ifaces.ei_device.request.start_emulating, &.{ .{ .uint = c.last_serial }, .{ .uint = d.sequence } });
        d.emulating = true;
    }

    pub fn stop(c: *Context, d: *Device) Error!void {
        if (!d.emulating) return;
        d.emulating = false;
        try c.request(d.id, ifaces.ei_device.request.stop_emulating, &.{.{ .uint = c.last_serial }});
    }

    /// Ends a frame stamped `time_us` (CLOCK_MONOTONIC, microseconds).
    pub fn frame(c: *Context, d: *Device, time_us: u64) Error!void {
        if (!d.resumed) return error.Suspended;
        try c.request(d.id, ifaces.ei_device.request.frame, &.{ .{ .uint = c.last_serial }, .{ .uint64 = time_us } });
    }

    pub fn nowUs() u64 {
        return sock.nowNs() / std.time.ns_per_us;
    }

    /// Absolute motion to `x`, `y` in the device's regions (logical
    /// coordinates).
    pub fn moveTo(c: *Context, d: *Device, x: f32, y: f32) Error!void {
        if (!d.resumed) return error.Suspended;
        try c.request(try d.object(.pointer_absolute), ifaces.ei_pointer_absolute.request.motion_absolute, &.{ .{ .float = x }, .{ .float = y } });
    }

    pub fn moveBy(c: *Context, d: *Device, dx: f32, dy: f32) Error!void {
        if (!d.resumed) return error.Suspended;
        try c.request(try d.object(.pointer), ifaces.ei_pointer.request.motion_relative, &.{ .{ .float = dx }, .{ .float = dy } });
    }

    /// A button by its evdev code (BTN_LEFT is 0x110).
    pub fn button(c: *Context, d: *Device, code: u32, press: bool) Error!void {
        if (!d.resumed) return error.Suspended;
        try c.request(try d.object(.button), ifaces.ei_button.request.button, &.{ .{ .uint = code }, .{ .uint = @intFromBool(press) } });
    }

    pub fn scroll(c: *Context, d: *Device, dx: f32, dy: f32) Error!void {
        if (!d.resumed) return error.Suspended;
        try c.request(try d.object(.scroll), ifaces.ei_scroll.request.scroll, &.{ .{ .float = dx }, .{ .float = dy } });
    }

    /// Wheel notches, in 1/120 of a notch.
    pub fn scrollDiscrete(c: *Context, d: *Device, dx: i32, dy: i32) Error!void {
        if (!d.resumed) return error.Suspended;
        try c.request(try d.object(.scroll), ifaces.ei_scroll.request.scroll_discrete, &.{ .{ .int = dx }, .{ .int = dy } });
    }

    /// A key by its evdev code.
    pub fn key(c: *Context, d: *Device, code: u32, press: bool) Error!void {
        if (!d.resumed) return error.Suspended;
        try c.request(try d.object(.keyboard), ifaces.ei_keyboard.request.key, &.{ .{ .uint = code }, .{ .uint = @intFromBool(press) } });
    }

    /// UTF-8 text, where the compositor offers ei_text (KWin).
    pub fn text(c: *Context, d: *Device, utf8: []const u8) Error!void {
        if (!d.resumed) return error.Suspended;
        try c.request(try d.object(.text), ifaces.ei_text.request.utf8, &.{.{ .string = utf8 }});
    }
};

/// The capability an interface name carries (`ei_pointer` is `pointer`).
fn capabilityOf(name: ?[]const u8) ?Capability {
    const n = name orelse return null;
    if (!std.mem.startsWith(u8, n, "ei_")) return null;
    return std.meta.stringToEnum(Capability, n[3..]);
}

pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Suspended => suspended_text,
        error.Disconnected => "Canal d'entrée EI fermé par le compositeur : relance l'action.",
        error.Timeout => "Le compositeur ne répond pas sur le canal d'entrée EI : réessaie dans un instant.",
        error.Malformed, error.BadArguments => "Message EI mal formé : canal d'entrée fermé, relance l'action.",
        error.Unsupported => "Le compositeur n'offre pas ce périphérique d'entrée.",
        error.OutOfMemory => "Mémoire insuffisante.",
    };
}
