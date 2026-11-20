//! A Wayland client in native Zig (US-079, decision 0014 D12). Interfaces
//! come from the generated `protocols` module (bindings/linux.zon); a
//! request is encoded from its generated signature, so no opcode or
//! argument list is written by hand.
//!
//! Events are read the way libwayland reads them: every whole message of
//! a read is decoded at once, wl_display's own events (`error`,
//! `delete_id`) act at that moment, and the others wait in a queue for
//! `dispatch`. Object ids are reused last-freed first, after the
//! compositor's `delete_id`, as libwayland does: the byte tests compare
//! this client with libwayland itself.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("sock.zig");
const proto = @import("protocols");
const Allocator = std.mem.Allocator;

pub const ifaces = proto.wayland;
pub const Interface = proto.Interface;
pub const Message = proto.Message;

pub const disconnected_text = "Compositeur Wayland déconnecté : relance la session graphique.";

pub const Error = error{
    OutOfMemory,
    /// The compositor closed the socket; every request after fails too.
    Disconnected,
    Timeout,
    /// The compositor sent wl_display.error (`protocol_error`).
    Protocol,
    /// A message from the compositor breaks the wire format.
    Malformed,
    /// No `WAYLAND_DISPLAY`, or its socket refuses the connection.
    NoDisplay,
    /// A request whose arguments do not match its generated signature.
    BadArguments,
};

pub const Arg = union(enum) {
    int: i32,
    uint: u32,
    /// 24.8 fixed point.
    fixed: i32,
    string: ?[]const u8,
    /// 0 is null.
    object: u32,
    new_id: u32,
    /// A new_id whose interface the request names (wl_registry.bind).
    untyped_new_id: struct { interface: []const u8, version: u32, id: u32 },
    array: []const u8,
    fd: i32,
};

pub const Event = struct {
    object: u32,
    interface: *const Interface,
    opcode: u16,
    args: []const Arg,

    pub fn is(e: Event, comptime ns: type, comptime opcode: u16) bool {
        return e.interface == &ns.interface and e.opcode == opcode;
    }
};

pub const Global = struct { name: u32, interface: []const u8, version: u32 };

/// What wl_display.error said, kept for the tool's message.
pub const ProtocolError = struct {
    object: u32 = 0,
    interface_buf: [64]u8 = undefined,
    interface_len: usize = 0,
    code: u32 = 0,
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn interface(p: *const ProtocolError) []const u8 {
        return p.interface_buf[0..p.interface_len];
    }

    pub fn message(p: *const ProtocolError) []const u8 {
        return p.message_buf[0..p.message_len];
    }
};

const Slot = struct {
    iface: ?*const Interface = null,
    /// Destroyed by a request, its id not yet released by delete_id: its
    /// events are read (for their descriptors) and discarded.
    zombie: bool = false,
    /// Released by delete_id while still alive here: the id is reused
    /// once this client destroys the object too.
    deleted: bool = false,
};

const Queued = struct { object: u32, iface: *const Interface, opcode: u16, bytes: []u8, fds: []i32 };

pub const Connection = struct {
    gpa: Allocator,
    fd: i32 = -1,
    /// Client objects by id - 1 (wl_display is id 1).
    objects: std.ArrayList(Slot) = .empty,
    /// Released ids, reused last first.
    free_ids: std.ArrayList(u32) = .empty,
    rx: std.ArrayList(u8) = .empty,
    rx_fds: std.ArrayList(i32) = .empty,
    queue: std.ArrayList(Queued) = .empty,
    /// The event `dispatch` returned last, freed by the next call.
    current: ?Queued = null,
    current_args: std.ArrayList(Arg) = .empty,
    registry: u32 = 0,
    globals: std.ArrayList(Global) = .empty,
    protocol_error: ProtocolError = .{},
    /// When set, every request and event, in the format of
    /// WAYLAND_DEBUG=client without its time and queue.
    log: ?*std.Io.Writer = null,
    /// Why the last message was refused.
    problem: []const u8 = "",

    pub const display_id = 1;

    /// Connects to `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` (an absolute
    /// `WAYLAND_DISPLAY` is used as it is).
    pub fn connect(gpa: Allocator, env: *const std.process.Environ.Map) Error!Connection {
        const display = env.get("WAYLAND_DISPLAY") orelse return error.NoDisplay;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = if (std.fs.path.isAbsolute(display)) display else std.fmt.bufPrint(&buf, "{s}/{s}", .{ env.get("XDG_RUNTIME_DIR") orelse return error.NoDisplay, display }) catch return error.NoDisplay;
        const fd = sock.connectUnix(path, false) catch return error.NoDisplay;
        return adopt(gpa, fd);
    }

    /// A connection on a connected socket (tests).
    pub fn adopt(gpa: Allocator, fd: i32) Error!Connection {
        var c: Connection = .{ .gpa = gpa, .fd = fd };
        try c.objects.append(gpa, .{ .iface = &ifaces.wl_display.interface });
        return c;
    }

    pub fn deinit(c: *Connection) void {
        c.close();
        c.objects.deinit(c.gpa);
        c.free_ids.deinit(c.gpa);
        c.rx.deinit(c.gpa);
        c.rx_fds.deinit(c.gpa);
        c.queue.deinit(c.gpa);
        c.current_args.deinit(c.gpa);
        for (c.globals.items) |g| c.gpa.free(g.interface);
        c.globals.deinit(c.gpa);
    }

    /// Closes the socket and every descriptor still held.
    pub fn close(c: *Connection) void {
        if (c.fd >= 0) _ = linux.close(c.fd);
        c.fd = -1;
        c.releaseCurrent();
        for (c.queue.items) |q| c.freeQueued(q);
        c.queue.clearRetainingCapacity();
        sock.closeAll(c.rx_fds.items);
        c.rx_fds.clearRetainingCapacity();
    }

    fn freeQueued(c: *Connection, q: Queued) void {
        sock.closeAll(q.fds);
        c.gpa.free(q.fds);
        c.gpa.free(q.bytes);
    }

    fn releaseCurrent(c: *Connection) void {
        if (c.current) |q| c.freeQueued(q);
        c.current = null;
    }

    fn slot(c: *Connection, id: u32) ?*Slot {
        if (id == 0 or id > c.objects.items.len) return null;
        const s = &c.objects.items[id - 1];
        return if (s.iface != null) s else null;
    }

    /// A new client object of `iface`.
    pub fn newId(c: *Connection, iface: *const Interface) Error!u32 {
        if (c.free_ids.pop()) |id| {
            c.objects.items[id - 1] = .{ .iface = iface };
            return id;
        }
        try c.objects.append(c.gpa, .{ .iface = iface });
        return @intCast(c.objects.items.len);
    }

    fn findInterface(name: []const u8) ?*const Interface {
        for (ifaces.all) |i| if (std.mem.eql(u8, i.name, name)) return i;
        return null;
    }

    /// Sends `opcode` of `object`, its arguments checked against the
    /// generated signature; new objects are registered.
    pub fn request(c: *Connection, object: u32, opcode: u16, args: []const Arg) Error!void {
        if (c.fd < 0) return error.Disconnected;
        const s = c.slot(object) orelse return error.BadArguments;
        const iface = s.iface.?;
        if (s.zombie or opcode >= iface.requests.len) return error.BadArguments;
        const msg = iface.requests[opcode];
        if (msg.args.len != args.len) return error.BadArguments;
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var fds: [sock.max_fds]i32 = undefined;
        var nfds: usize = 0;
        put(&w, u32, object) catch unreachable;
        put(&w, u32, 0) catch unreachable;
        for (msg.args, args) |spec, a| {
            const ok = switch (spec.kind) {
                .int => a == .int,
                .uint => a == .uint,
                .fixed => a == .fixed,
                .string => a == .string and (a.string != null or spec.nullable),
                .object => a == .object and (a.object != 0 or spec.nullable),
                .new_id => (spec.interface != null and a == .new_id) or (spec.interface == null and a == .untyped_new_id),
                .array => a == .array,
                .fd => a == .fd,
                else => false,
            };
            if (!ok) return error.BadArguments;
            (switch (a) {
                .int => |v| put(&w, i32, v),
                .uint => |v| put(&w, u32, v),
                .fixed => |v| put(&w, i32, v),
                .string => |v| putString(&w, v),
                .object, .new_id => |v| put(&w, u32, v),
                .untyped_new_id => |v| blk: {
                    putString(&w, v.interface) catch |e| break :blk e;
                    put(&w, u32, v.version) catch |e| break :blk e;
                    break :blk put(&w, u32, v.id);
                },
                .array => |v| putArray(&w, v),
                .fd => |v| blk: {
                    if (nfds == fds.len) return error.BadArguments;
                    fds[nfds] = v;
                    nfds += 1;
                    break :blk {};
                },
            }) catch return error.BadArguments;
        }
        const bytes = w.buffered();
        const size: u32 = @intCast(bytes.len);
        std.mem.writeInt(u32, bytes[4..8], (size << 16) | opcode, .little);
        // New objects take their ids once the request is valid.
        for (msg.args, args) |spec, a| switch (a) {
            .new_id => |id| try c.claim(id, findInterface(spec.interface.?)),
            .untyped_new_id => |v| try c.claim(v.id, findInterface(v.interface)),
            else => {},
        };
        if (c.log) |l| formatLine(l, c, true, object, iface, msg, args) catch {};
        if (msg.destructor) try c.destroyObject(object);
        sock.sendAll(c.fd, bytes, fds[0..nfds]) catch {
            c.close();
            return error.Disconnected;
        };
    }

    /// Registers `id`, allocated by `newId`, with its interface.
    fn claim(c: *Connection, id: u32, iface: ?*const Interface) Error!void {
        const s = if (id > 0 and id <= c.objects.items.len) &c.objects.items[id - 1] else return error.BadArguments;
        s.* = .{ .iface = iface orelse return error.BadArguments };
    }

    /// Reads what the socket holds and decodes every whole message.
    fn readEvents(c: *Connection, deadline: ?u64) Error!void {
        if (c.fd < 0) return error.Disconnected;
        var buf: [16 * 1024]u8 = undefined;
        const n = sock.recvSome(c.fd, &buf, &c.rx_fds, c.gpa, deadline) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                c.close();
                return error.Disconnected;
            },
        };
        try c.rx.appendSlice(c.gpa, buf[0..n]);
        while (c.rx.items.len >= 8) {
            const object = std.mem.readInt(u32, c.rx.items[0..4], .little);
            const header = std.mem.readInt(u32, c.rx.items[4..8], .little);
            const size: usize = header >> 16;
            const opcode: u16 = @truncate(header);
            if (size < 8 or size % 4 != 0) return c.malformed("message size below its header or not a multiple of 4");
            if (c.rx.items.len < size) break;
            const s = c.slot(object) orelse return c.malformed("event of an unknown object");
            const iface = s.iface.?;
            if (opcode >= iface.events.len) return c.malformed("event opcode beyond its interface");
            var nfds: usize = 0;
            for (iface.events[opcode].args) |a| nfds += @intFromBool(a.kind == .fd);
            if (nfds > c.rx_fds.items.len) return c.malformed("descriptors announced and not received");
            if (s.zombie) {
                // Read for its descriptors, then dropped, as libwayland
                // does at read time.
                if (c.log) |l| l.print("discarded [unknown]#{d}.[event {d}]({d} fd, {d} byte)\n", .{ object, opcode, nfds, size }) catch {};
                sock.closeAll(c.rx_fds.items[0..nfds]);
                c.rx_fds.replaceRangeAssumeCapacity(0, nfds, &.{});
                c.rx.replaceRangeAssumeCapacity(0, size, &.{});
                continue;
            }
            const bytes = try c.gpa.dupe(u8, c.rx.items[0..size]);
            const fds = c.gpa.dupe(i32, c.rx_fds.items[0..nfds]) catch |e| {
                c.gpa.free(bytes);
                return e;
            };
            c.rx.replaceRangeAssumeCapacity(0, size, &.{});
            c.rx_fds.replaceRangeAssumeCapacity(0, nfds, &.{});
            const q: Queued = .{ .object = object, .iface = iface, .opcode = opcode, .bytes = bytes, .fds = fds };
            if (object == display_id) {
                defer c.freeQueued(q);
                try c.displayEvent(q);
            } else c.queue.append(c.gpa, q) catch |e| {
                c.freeQueued(q);
                return e;
            };
        }
    }

    fn malformed(c: *Connection, why: []const u8) Error {
        c.problem = why;
        c.close();
        return error.Malformed;
    }

    fn decode(c: *Connection, q: Queued, out: *std.ArrayList(Arg)) Error!void {
        out.clearRetainingCapacity();
        var pos: usize = 8;
        var fd_i: usize = 0;
        const b = q.bytes;
        for (q.iface.events[q.opcode].args) |spec| {
            const a: Arg = switch (spec.kind) {
                .int => .{ .int = @bitCast(try word(b, &pos)) },
                .uint => .{ .uint = try word(b, &pos) },
                .fixed => .{ .fixed = @bitCast(try word(b, &pos)) },
                .object => .{ .object = try word(b, &pos) },
                .new_id => .{ .new_id = try word(b, &pos) },
                .string => blk: {
                    const len = try word(b, &pos);
                    if (len == 0) break :blk .{ .string = null };
                    const padded = std.mem.alignForward(usize, len, 4);
                    if (padded > b.len - pos or b[pos + len - 1] != 0) return error.Malformed;
                    const s = b[pos..][0 .. len - 1];
                    pos += padded;
                    break :blk .{ .string = s };
                },
                .array => blk: {
                    const len = try word(b, &pos);
                    const padded = std.mem.alignForward(usize, len, 4);
                    if (padded > b.len - pos) return error.Malformed;
                    const s = b[pos..][0..len];
                    pos += padded;
                    break :blk .{ .array = s };
                },
                .fd => blk: {
                    const fd = q.fds[fd_i];
                    fd_i += 1;
                    break :blk .{ .fd = fd };
                },
                else => return error.Malformed,
            };
            try out.append(c.gpa, a);
        }
        if (pos != b.len) return error.Malformed;
    }

    fn word(b: []const u8, pos: *usize) Error!u32 {
        if (b.len - pos.* < 4) return error.Malformed;
        const v = std.mem.readInt(u32, b[pos.*..][0..4], .little);
        pos.* += 4;
        return v;
    }

    fn displayEvent(c: *Connection, q: Queued) Error!void {
        var args: std.ArrayList(Arg) = .empty;
        defer args.deinit(c.gpa);
        c.decode(q, &args) catch return c.malformed("arguments past the message");
        if (c.log) |l| formatLine(l, c, false, q.object, q.iface, q.iface.events[q.opcode], args.items) catch {};
        if (q.opcode == ifaces.wl_display.event.@"error") {
            const p = &c.protocol_error;
            p.object = args.items[0].object;
            const name = if (c.slot(p.object)) |s| s.iface.?.name else "[unknown]";
            p.interface_len = @min(name.len, p.interface_buf.len);
            @memcpy(p.interface_buf[0..p.interface_len], name[0..p.interface_len]);
            p.code = args.items[1].uint;
            const text = args.items[2].string orelse "";
            p.message_len = @min(text.len, p.message_buf.len);
            @memcpy(p.message_buf[0..p.message_len], text[0..p.message_len]);
            c.close();
            return error.Protocol;
        }
        if (q.opcode == ifaces.wl_display.event.delete_id) {
            const id = args.items[0].uint;
            if (id <= 1 or id > c.objects.items.len) return c.malformed("delete_id of an id never used");
            const s = &c.objects.items[id - 1];
            if (s.iface == null) return;
            if (s.zombie) try c.release(id) else s.deleted = true;
        }
    }

    /// This client destroys `id`: its id is reused once the compositor's
    /// delete_id came, as libwayland does.
    fn destroyObject(c: *Connection, id: u32) Error!void {
        const s = &c.objects.items[id - 1];
        if (s.deleted) try c.release(id) else s.zombie = true;
    }

    fn release(c: *Connection, id: u32) Error!void {
        c.objects.items[id - 1] = .{};
        try c.free_ids.append(c.gpa, id);
    }

    /// The next queued event, reading when the queue is empty. The event
    /// lives until the next call; its descriptors belong to the caller.
    pub fn dispatch(c: *Connection, deadline: ?u64) Error!Event {
        c.releaseCurrent();
        while (c.queue.items.len == 0) try c.readEvents(deadline);
        const q = c.queue.orderedRemove(0);
        c.current = q;
        c.decode(q, &c.current_args) catch return c.malformed("arguments past the message");
        // Descriptors now belong to the caller.
        @memset(q.fds, -1);
        if (c.log) |l| formatLine(l, c, false, q.object, q.iface, q.iface.events[q.opcode], c.current_args.items) catch {};
        const e: Event = .{ .object = q.object, .interface = q.iface, .opcode = q.opcode, .args = c.current_args.items };
        if (q.object == c.registry) try c.registryEvent(e);
        // A destructor event (wl_callback.done) ends the object here.
        if (q.iface.events[q.opcode].destructor) try c.destroyObject(q.object);
        return e;
    }

    fn registryEvent(c: *Connection, e: Event) Error!void {
        if (e.opcode == ifaces.wl_registry.event.global) {
            const name = try c.gpa.dupe(u8, e.args[1].string orelse "");
            errdefer c.gpa.free(name);
            try c.globals.append(c.gpa, .{ .name = e.args[0].uint, .interface = name, .version = e.args[2].uint });
        } else if (e.opcode == ifaces.wl_registry.event.global_remove) {
            for (c.globals.items, 0..) |g, i| if (g.name == e.args[0].uint) {
                c.gpa.free(g.interface);
                _ = c.globals.orderedRemove(i);
                break;
            };
        }
    }

    /// wl_display.sync: a callback whose `done` ends a round trip.
    pub fn sync(c: *Connection) Error!u32 {
        const cb = try c.newId(&ifaces.wl_callback.interface);
        try c.request(display_id, ifaces.wl_display.request.sync, &.{.{ .new_id = cb }});
        return cb;
    }

    /// Dispatches until the compositor has handled every request sent;
    /// `sink` sees each other event.
    pub fn roundtrip(c: *Connection, deadline: ?u64, sink: anytype) Error!void {
        const cb = try c.sync();
        while (true) {
            const e = try c.dispatch(deadline);
            if (e.object == cb and e.is(ifaces.wl_callback, ifaces.wl_callback.event.done)) return;
            if (@TypeOf(sink) != @TypeOf(null)) sink.event(c, e);
        }
    }

    /// Gets the registry and reads every global.
    pub fn readRegistry(c: *Connection, deadline: ?u64) Error!void {
        c.registry = try c.newId(&ifaces.wl_registry.interface);
        try c.request(display_id, ifaces.wl_display.request.get_registry, &.{.{ .new_id = c.registry }});
        try c.roundtrip(deadline, null);
    }

    pub fn global(c: *const Connection, name: []const u8) ?Global {
        for (c.globals.items) |g| if (std.mem.eql(u8, g.interface, name)) return g;
        return null;
    }

    /// Binds `g` at the smaller of its advertised version and the
    /// generated one.
    pub fn bind(c: *Connection, g: Global, comptime ns: type) Error!u32 {
        const version = @min(g.version, ns.interface.version);
        const id = try c.newId(&ns.interface);
        try c.request(c.registry, ifaces.wl_registry.request.bind, &.{ .{ .uint = g.name }, .{ .untyped_new_id = .{ .interface = ns.interface.name, .version = version, .id = id } } });
        return id;
    }

    /// The text of a failure, for a tool result (FR-06).
    pub fn describe(c: *const Connection, err: Error) []const u8 {
        _ = c;
        return switch (err) {
            error.Disconnected, error.NoDisplay => disconnected_text,
            error.Timeout => "Le compositeur Wayland ne répond pas dans le délai : réessaie dans un instant.",
            error.Protocol, error.Malformed, error.BadArguments => "Erreur du protocole Wayland : connexion fermée, réessaie l'action.",
            error.OutOfMemory => "Mémoire insuffisante.",
        };
    }
};

fn put(w: *std.Io.Writer, comptime T: type, v: T) std.Io.Writer.Error!void {
    try w.writeInt(T, v, .little);
}

fn putString(w: *std.Io.Writer, s: ?[]const u8) std.Io.Writer.Error!void {
    const v = s orelse return put(w, u32, 0);
    try put(w, u32, @intCast(v.len + 1));
    try w.writeAll(v);
    try w.splatByteAll(0, std.mem.alignForward(usize, v.len + 1, 4) - v.len);
}

fn putArray(w: *std.Io.Writer, a: []const u8) std.Io.Writer.Error!void {
    try put(w, u32, @intCast(a.len));
    try w.writeAll(a);
    try w.splatByteAll(0, std.mem.alignForward(usize, a.len, 4) - a.len);
}

/// One line of WAYLAND_DEBUG=client (libwayland's `wl_closure_print`),
/// without the time and queue.
fn formatLine(w: *std.Io.Writer, c: *Connection, is_request: bool, object: u32, iface: *const Interface, msg: Message, args: []const Arg) std.Io.Writer.Error!void {
    if (is_request) try w.writeAll(" -> ");
    try w.print("{s}#{d}.{s}(", .{ iface.name, object, msg.name });
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeAll(", ");
        switch (a) {
            .int => |v| try w.print("{d}", .{v}),
            .uint => |v| try w.print("{d}", .{v}),
            .fixed => |v| try w.print("{d:.6}", .{@as(f64, @floatFromInt(v)) / 256.0}),
            .string => |v| if (v) |s| try w.print("\"{s}\"", .{s}) else try w.writeAll("nil"),
            .object => |v| if (v == 0) try w.writeAll("nil") else {
                const name = if (c.slot(v)) |s| s.iface.?.name else "[unknown]";
                try w.print("{s}#{d}", .{ name, v });
            },
            .new_id => |v| try w.print("new id {s}#{d}", .{ msg.args[i].interface orelse "[unknown]", v }),
            .untyped_new_id => |v| try w.print("\"{s}\", {d}, new id [unknown]#{d}", .{ v.interface, v.version, v.id }),
            .array => |v| try w.print("array[{d}]", .{v.len}),
            .fd => |v| try w.print("fd {d}", .{v}),
        }
    }
    try w.writeAll(")\n");
}

/// A buffer pool on a memfd, for the surfaces the server draws.
pub const ShmPool = struct {
    id: u32,
    fd: i32,
    memory: []align(std.heap.page_size_min) u8,

    pub fn create(c: *Connection, shm: u32, size: usize) Error!ShmPool {
        const rc = linux.memfd_create("neo-compute-shm", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
        if (linux.errno(rc) != .SUCCESS) return error.OutOfMemory;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.OutOfMemory;
        const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(addr) != .SUCCESS) return error.OutOfMemory;
        const memory: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(addr))[0..size];
        errdefer _ = linux.munmap(memory.ptr, memory.len);
        const id = try c.newId(&ifaces.wl_shm_pool.interface);
        try c.request(shm, ifaces.wl_shm.request.create_pool, &.{ .{ .new_id = id }, .{ .fd = fd }, .{ .int = @intCast(size) } });
        return .{ .id = id, .fd = fd, .memory = memory };
    }

    pub fn buffer(p: *ShmPool, c: *Connection, offset: i32, width: i32, height: i32, stride: i32, format: u32) Error!u32 {
        const id = try c.newId(&ifaces.wl_buffer.interface);
        try c.request(p.id, ifaces.wl_shm_pool.request.create_buffer, &.{ .{ .new_id = id }, .{ .int = offset }, .{ .int = width }, .{ .int = height }, .{ .int = stride }, .{ .uint = format } });
        return id;
    }

    /// Destroys the pool (buffers made from it stay valid) and unmaps it.
    pub fn destroy(p: *ShmPool, c: *Connection) void {
        c.request(p.id, ifaces.wl_shm_pool.request.destroy, &.{}) catch {};
        _ = linux.munmap(p.memory.ptr, p.memory.len);
        _ = linux.close(p.fd);
        p.fd = -1;
    }
};
