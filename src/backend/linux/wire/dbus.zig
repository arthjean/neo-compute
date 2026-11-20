//! A D-Bus client in native Zig (US-078, decision 0014 D12): SASL
//! EXTERNAL, the message format of the specification, file descriptors
//! with `SCM_RIGHTS`, and a deadline on every call so a stopped peer never
//! blocks the server.
//!
//! Members come from the generated `protocols` module (bindings/linux.zon):
//! `call` checks at compile time that the Zig types of its arguments spell
//! the member's signature, so no signature is transcribed by hand. A value
//! of a variant is read and written through `Value`, typed at run time.
//!
//! Every message received is validated before use; a malformed one closes
//! the connection with `error.Malformed` and the reason in `problem`.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("sock.zig");
pub const proto = @import("protocols");
const Allocator = std.mem.Allocator;

pub const Method = proto.Method;
pub const Signal = proto.Signal;
pub const Property = proto.Property;
pub const ifaces = proto.dbus;
const bus = proto.dbus.org_freedesktop_DBus;
const props = proto.dbus.org_freedesktop_DBus_Properties;

pub const Error = error{
    OutOfMemory,
    /// The peer closed the connection, or it was closed after an error.
    Disconnected,
    /// No reply before the call's deadline.
    Timeout,
    /// A message received breaks the specification (`problem` says how).
    Malformed,
    /// The bus refused SASL EXTERNAL.
    AuthFailed,
    /// No usable `unix:` address.
    BadAddress,
    /// The peer answered with an error message (`error_name`, `error_text`).
    RemoteError,
    /// The reply's signature is not the one the member declares.
    SignatureMismatch,
};

// ---------------------------------------------------------------- types

pub const ObjectPath = struct { path: []const u8 };
pub const Signature = struct { sig: []const u8 };
/// A file descriptor. Received, it belongs to the caller once read.
pub const Fd = struct { fd: i32 };

pub const Variant = struct {
    sig: []const u8,
    value: Value,

    /// A variant of a typed value, whose signature comes from its type.
    pub fn of(arena: Allocator, v: anytype) Allocator.Error!Variant {
        const T = @TypeOf(v);
        return .{ .sig = comptime sigOf(T), .value = try toValue(arena, T, v) };
    }

    /// The typed value of this variant, or `SignatureMismatch`.
    pub fn as(self: Variant, comptime T: type) Error!T {
        if (!std.mem.eql(u8, self.sig, comptime sigOf(T))) return error.SignatureMismatch;
        return fromValue(T, self.value);
    }
};

pub fn DictEntry(comptime K: type, comptime V: type) type {
    return struct {
        pub const is_dict_entry = true;
        key: K,
        value: V,
    };
}

/// A value whose type is known at run time only (inside a variant).
pub const Value = union(enum) {
    y: u8,
    b: bool,
    n: i16,
    q: u16,
    i: i32,
    u: u32,
    x: i64,
    t: u64,
    d: f64,
    s: []const u8,
    o: []const u8,
    g: []const u8,
    /// Index into the message's descriptors.
    h: u32,
    v: *const Variant,
    /// Elements of an array, `elem` their signature.
    a: struct { elem: []const u8, items: []const Value },
    /// A dict entry: key then value.
    e: *const [2]Value,
    r: []const Value,
};

/// The signature of a Zig type, at compile time.
pub fn sigOf(comptime T: type) []const u8 {
    return switch (T) {
        u8 => "y",
        bool => "b",
        i16 => "n",
        u16 => "q",
        i32 => "i",
        u32 => "u",
        i64 => "x",
        u64 => "t",
        f64 => "d",
        []const u8 => "s",
        ObjectPath => "o",
        Signature => "g",
        Fd => "h",
        Variant => "v",
        else => switch (@typeInfo(T)) {
            .pointer => |p| blk: {
                if (p.size != .slice) @compileError("no D-Bus type for " ++ @typeName(T));
                const E = p.child;
                if (@hasDecl(E, "is_dict_entry")) break :blk "a{" ++ sigOf(@FieldType(E, "key")) ++ sigOf(@FieldType(E, "value")) ++ "}";
                break :blk "a" ++ sigOf(E);
            },
            .@"struct" => "(" ++ bodySig(T) ++ ")",
            else => @compileError("no D-Bus type for " ++ @typeName(T)),
        },
    };
}

/// The signature of a message body whose arguments are the fields of `T`.
pub fn bodySig(comptime T: type) []const u8 {
    var s: []const u8 = "";
    for (@typeInfo(T).@"struct".field_types) |ft| s = s ++ sigOf(ft);
    return s;
}

fn alignOf(code: u8) usize {
    return switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'x', 't', 'd', '(', '{' => 8,
        else => 4,
    };
}

/// The end of the complete type that starts at `sig[i]`; the signature
/// was validated before.
fn typeEnd(sig: []const u8, i: usize) usize {
    switch (sig[i]) {
        'a' => return typeEnd(sig, i + 1),
        '(', '{' => {
            var depth: usize = 0;
            var j = i;
            while (j < sig.len) : (j += 1) switch (sig[j]) {
                '(', '{' => depth += 1,
                ')', '}' => {
                    depth -= 1;
                    if (depth == 0) return j + 1;
                },
                else => {},
            };
            return sig.len;
        },
        else => return i + 1,
    }
}

// ---------------------------------------------------------------- writing

pub const Writer = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    fds: std.ArrayList(i32) = .empty,

    pub fn pad(w: *Writer, n: usize) Allocator.Error!void {
        while (w.buf.items.len % n != 0) try w.buf.append(w.a, 0);
    }

    fn int(w: *Writer, comptime T: type, v: T) Allocator.Error!void {
        try w.pad(@sizeOf(T));
        try w.buf.appendSlice(w.a, std.mem.asBytes(&std.mem.nativeToLittle(T, v)));
    }

    fn string(w: *Writer, s: []const u8) Allocator.Error!void {
        try w.int(u32, @intCast(s.len));
        try w.buf.appendSlice(w.a, s);
        try w.buf.append(w.a, 0);
    }

    fn signature(w: *Writer, s: []const u8) Allocator.Error!void {
        try w.buf.append(w.a, @intCast(s.len));
        try w.buf.appendSlice(w.a, s);
        try w.buf.append(w.a, 0);
    }

    /// Starts an array; returns what `endArray` needs.
    fn beginArray(w: *Writer, elem_align: usize) Allocator.Error![2]usize {
        try w.int(u32, 0);
        const at = w.buf.items.len - 4;
        try w.pad(elem_align);
        return .{ at, w.buf.items.len };
    }

    fn endArray(w: *Writer, mark: [2]usize) void {
        const len: u32 = @intCast(w.buf.items.len - mark[1]);
        @memcpy(w.buf.items[mark[0]..][0..4], std.mem.asBytes(&std.mem.nativeToLittle(u32, len)));
    }

    pub fn typed(w: *Writer, comptime T: type, v: T) Allocator.Error!void {
        switch (T) {
            u8 => try w.buf.append(w.a, v),
            bool => try w.int(u32, @intFromBool(v)),
            i16, u16, i32, u32, i64, u64 => try w.int(T, v),
            f64 => try w.int(u64, @bitCast(v)),
            []const u8 => try w.string(v),
            ObjectPath => try w.string(v.path),
            Signature => try w.signature(v.sig),
            Fd => {
                try w.int(u32, @intCast(w.fds.items.len));
                try w.fds.append(w.a, v.fd);
            },
            Variant => {
                try w.signature(v.sig);
                try w.value(v.sig, v.value);
            },
            else => switch (@typeInfo(T)) {
                .pointer => {
                    const E = @typeInfo(T).pointer.child;
                    const mark = try w.beginArray(alignOf((comptime sigOf(E))[0]));
                    for (v) |item| try w.typed(E, item);
                    w.endArray(mark);
                },
                .@"struct" => |s| {
                    try w.pad(8);
                    inline for (s.field_names) |n| try w.typed(@FieldType(T, n), @field(v, n));
                },
                else => comptime unreachable,
            },
        }
    }

    /// Writes `v`, whose complete type is `sig`.
    pub fn value(w: *Writer, sig: []const u8, v: Value) Allocator.Error!void {
        switch (v) {
            .y => |x| try w.buf.append(w.a, x),
            .b => |x| try w.int(u32, @intFromBool(x)),
            .n => |x| try w.int(i16, x),
            .q => |x| try w.int(u16, x),
            .i => |x| try w.int(i32, x),
            .u => |x| try w.int(u32, x),
            .x => |x| try w.int(i64, x),
            .t => |x| try w.int(u64, x),
            .d => |x| try w.int(u64, @bitCast(x)),
            .s, .o => |x| try w.string(x),
            .g => |x| try w.signature(x),
            .h => |x| try w.int(u32, x),
            .v => |x| {
                try w.signature(x.sig);
                try w.value(x.sig, x.value);
            },
            .a => |arr| {
                const mark = try w.beginArray(alignOf(arr.elem[0]));
                for (arr.items) |item| try w.value(arr.elem, item);
                w.endArray(mark);
            },
            .e => |kv| {
                try w.pad(8);
                const key_end = typeEnd(sig, 1);
                try w.value(sig[1..key_end], kv[0]);
                try w.value(sig[key_end .. sig.len - 1], kv[1]);
            },
            .r => |fields| {
                try w.pad(8);
                var i: usize = 1;
                for (fields) |f| {
                    const end = typeEnd(sig, i);
                    try w.value(sig[i..end], f);
                    i = end;
                }
            },
        }
    }
};

pub fn toValue(arena: Allocator, comptime T: type, v: T) Allocator.Error!Value {
    return switch (T) {
        u8 => .{ .y = v },
        bool => .{ .b = v },
        i16 => .{ .n = v },
        u16 => .{ .q = v },
        i32 => .{ .i = v },
        u32 => .{ .u = v },
        i64 => .{ .x = v },
        u64 => .{ .t = v },
        f64 => .{ .d = v },
        []const u8 => .{ .s = v },
        ObjectPath => .{ .o = v.path },
        Signature => .{ .g = v.sig },
        Fd => @compileError("a descriptor cannot travel inside a variant built here"),
        Variant => blk: {
            const p = try arena.create(Variant);
            p.* = v;
            break :blk .{ .v = p };
        },
        else => switch (@typeInfo(T)) {
            .pointer => |p| blk: {
                const items = try arena.alloc(Value, v.len);
                for (v, items) |x, *o| o.* = try toValue(arena, p.child, x);
                break :blk .{ .a = .{ .elem = comptime sigOf(p.child), .items = items } };
            },
            .@"struct" => |s| blk: {
                if (@hasDecl(T, "is_dict_entry")) {
                    const kv = try arena.create([2]Value);
                    kv.* = .{ try toValue(arena, @FieldType(T, "key"), v.key), try toValue(arena, @FieldType(T, "value"), v.value) };
                    break :blk .{ .e = kv };
                }
                const fields = try arena.alloc(Value, s.field_names.len);
                inline for (s.field_names, 0..) |n, i| fields[i] = try toValue(arena, @FieldType(T, n), @field(v, n));
                break :blk .{ .r = fields };
            },
            else => comptime unreachable,
        },
    };
}

/// The typed value of `v`, whose signature was checked to be `sigOf(T)`.
pub fn fromValue(comptime T: type, v: Value) Error!T {
    const bad = error.SignatureMismatch;
    return switch (T) {
        u8 => if (v == .y) v.y else bad,
        bool => if (v == .b) v.b else bad,
        i16 => if (v == .n) v.n else bad,
        u16 => if (v == .q) v.q else bad,
        i32 => if (v == .i) v.i else bad,
        u32 => if (v == .u) v.u else bad,
        i64 => if (v == .x) v.x else bad,
        u64 => if (v == .t) v.t else bad,
        f64 => if (v == .d) v.d else bad,
        []const u8 => if (v == .s) v.s else bad,
        ObjectPath => if (v == .o) .{ .path = v.o } else bad,
        Signature => if (v == .g) .{ .sig = v.g } else bad,
        Variant => if (v == .v) v.v.* else bad,
        else => @compileError("read " ++ @typeName(T) ++ " from a message, not from a variant"),
    };
}

// ---------------------------------------------------------------- reading

/// Reads a body or a header against its signature, validating as it goes.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    /// Descriptors the message carries; an `h` beyond them is malformed.
    fd_count: u32 = 0,
    arena: Allocator,
    problem: []const u8 = "",

    fn fail(r: *Reader, why: []const u8) error{Malformed} {
        r.problem = why;
        return error.Malformed;
    }

    fn skipPad(r: *Reader, n: usize) error{Malformed}!void {
        const target = std.mem.alignForward(usize, r.pos, n);
        if (target > r.data.len) return r.fail("padding past the end");
        for (r.data[r.pos..target]) |b| if (b != 0) return r.fail("non-zero padding");
        r.pos = target;
    }

    fn int(r: *Reader, comptime T: type) error{Malformed}!T {
        try r.skipPad(@sizeOf(T));
        if (r.pos + @sizeOf(T) > r.data.len) return r.fail("value past the end");
        const v = std.mem.readInt(T, r.data[r.pos..][0..@sizeOf(T)], .little);
        r.pos += @sizeOf(T);
        return v;
    }

    fn boolean(r: *Reader) error{Malformed}!bool {
        return switch (try r.int(u32)) {
            0 => false,
            1 => true,
            else => r.fail("boolean other than 0 or 1"),
        };
    }

    fn string(r: *Reader) error{Malformed}![]const u8 {
        const len = try r.int(u32);
        if (len > r.data.len - r.pos or r.data.len - r.pos - len < 1) return r.fail("string past the end");
        const s = r.data[r.pos..][0..len];
        if (r.data[r.pos + len] != 0) return r.fail("string without its NUL");
        if (std.mem.indexOfScalar(u8, s, 0) != null) return r.fail("NUL inside a string");
        if (!std.unicode.utf8ValidateSlice(s)) return r.fail("string that is not UTF-8");
        r.pos += len + 1;
        return s;
    }

    fn objectPath(r: *Reader) error{Malformed}![]const u8 {
        const s = try r.string();
        if (!validPath(s)) return r.fail("invalid object path");
        return s;
    }

    fn signature(r: *Reader) error{Malformed}![]const u8 {
        if (r.pos >= r.data.len) return r.fail("signature past the end");
        const len = r.data[r.pos];
        if (r.pos + 1 + len >= r.data.len) return r.fail("signature past the end");
        const s = r.data[r.pos + 1 ..][0..len];
        if (r.data[r.pos + 1 + len] != 0) return r.fail("signature without its NUL");
        if (validSignature(s, false) != null) return r.fail("invalid signature");
        r.pos += len + 2;
        return s;
    }

    fn arrayLen(r: *Reader, elem_align: usize) error{Malformed}!usize {
        const len = try r.int(u32);
        if (len > 64 << 20) return r.fail("array longer than 64 MiB");
        try r.skipPad(elem_align);
        if (len > r.data.len - r.pos) return r.fail("array past the end");
        return r.pos + len;
    }

    /// The value of the complete type `sig` at the current position.
    pub fn value(r: *Reader, sig: []const u8, depth: usize) Error!Value {
        if (depth > 64) return r.fail("values nested deeper than 64");
        return switch (sig[0]) {
            'y' => blk: {
                if (r.pos >= r.data.len) return r.fail("byte past the end");
                r.pos += 1;
                break :blk .{ .y = r.data[r.pos - 1] };
            },
            'b' => .{ .b = try r.boolean() },
            'n' => .{ .n = try r.int(i16) },
            'q' => .{ .q = try r.int(u16) },
            'i' => .{ .i = try r.int(i32) },
            'u' => .{ .u = try r.int(u32) },
            'x' => .{ .x = try r.int(i64) },
            't' => .{ .t = try r.int(u64) },
            'd' => .{ .d = @bitCast(try r.int(u64)) },
            's' => .{ .s = try r.string() },
            'o' => .{ .o = try r.objectPath() },
            'g' => .{ .g = try r.signature() },
            'h' => blk: {
                const i = try r.int(u32);
                if (i >= r.fd_count) return r.fail("descriptor index past the descriptors received");
                break :blk .{ .h = i };
            },
            'v' => blk: {
                const s = try r.signature();
                if (s.len == 0 or typeEnd(s, 0) != s.len) return r.fail("variant signature not one complete type");
                const p = try r.arena.create(Variant);
                p.* = .{ .sig = s, .value = try r.value(s, depth + 1) };
                break :blk .{ .v = p };
            },
            'a' => blk: {
                const elem = sig[1..typeEnd(sig, 1)];
                const end = try r.arrayLen(alignOf(elem[0]));
                var items: std.ArrayList(Value) = .empty;
                while (r.pos < end) try items.append(r.arena, try r.value(elem, depth + 1));
                if (r.pos != end) return r.fail("array element past the array");
                break :blk .{ .a = .{ .elem = elem, .items = items.items } };
            },
            '{' => blk: {
                try r.skipPad(8);
                const key_end = typeEnd(sig, 1);
                const kv = try r.arena.create([2]Value);
                kv[0] = try r.value(sig[1..key_end], depth + 1);
                kv[1] = try r.value(sig[key_end .. sig.len - 1], depth + 1);
                break :blk .{ .e = kv };
            },
            '(' => blk: {
                try r.skipPad(8);
                var fields: std.ArrayList(Value) = .empty;
                var i: usize = 1;
                while (sig[i] != ')') {
                    const end = typeEnd(sig, i);
                    try fields.append(r.arena, try r.value(sig[i..end], depth + 1));
                    i = end;
                }
                break :blk .{ .r = fields.items };
            },
            else => r.fail("unknown type code"),
        };
    }

    pub fn typed(r: *Reader, comptime T: type, fds: []i32) Error!T {
        switch (T) {
            u8, bool, i16, u16, i32, u32, i64, u64, f64, []const u8, ObjectPath, Signature, Variant => return fromValue(T, try r.value(comptime sigOf(T), 0)),
            Fd => {
                const v = try r.value("h", 0);
                const fd = fds[v.h];
                if (fd < 0) return r.fail("descriptor read twice");
                fds[v.h] = -1;
                return .{ .fd = fd };
            },
            else => switch (@typeInfo(T)) {
                .pointer => |p| {
                    const end = try r.arrayLen(alignOf((comptime sigOf(p.child))[0]));
                    var items: std.ArrayList(p.child) = .empty;
                    while (r.pos < end) try items.append(r.arena, try r.typed(p.child, fds));
                    if (r.pos != end) return r.fail("array element past the array");
                    return items.items;
                },
                .@"struct" => |s| {
                    try r.skipPad(8);
                    var out: T = undefined;
                    inline for (s.field_names) |n| @field(out, n) = try r.typed(@FieldType(T, n), fds);
                    return out;
                },
                else => comptime unreachable,
            },
        }
    }
};

pub fn validPath(s: []const u8) bool {
    if (s.len == 0 or s[0] != '/') return false;
    if (s.len == 1) return true;
    if (s[s.len - 1] == '/') return false;
    var prev: u8 = 0;
    for (s) |c| {
        if (c == '/' and prev == '/') return false;
        if (c != '/' and !std.ascii.isAlphanumeric(c) and c != '_') return false;
        prev = c;
    }
    return true;
}

/// Null when `sig` is a valid signature (one complete type when `single`).
pub fn validSignature(sig: []const u8, single: bool) ?[]const u8 {
    if (sig.len > 255) return "longer than 255 bytes";
    var i: usize = 0;
    var count: usize = 0;
    while (i < sig.len) {
        i = checkType(sig, i, 0, 0) orelse return "invalid type";
        count += 1;
    }
    if (single and count != 1) return "not one complete type";
    return null;
}

fn checkType(sig: []const u8, i: usize, arrays: usize, structs: usize) ?usize {
    if (i >= sig.len) return null;
    switch (sig[i]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => return i + 1,
        'a' => {
            if (arrays >= 32) return null;
            if (i + 1 < sig.len and sig[i + 1] == '{') {
                if (i + 2 >= sig.len or std.mem.indexOfScalar(u8, "ybnqiuxtdsogh", sig[i + 2]) == null) return null;
                const end = checkType(sig, i + 3, arrays + 1, structs + 1) orelse return null;
                if (end >= sig.len or sig[end] != '}') return null;
                return end + 1;
            }
            return checkType(sig, i + 1, arrays + 1, structs);
        },
        '(' => {
            if (structs >= 32 or i + 1 >= sig.len or sig[i + 1] == ')') return null;
            var j = i + 1;
            while (j < sig.len and sig[j] != ')') j = checkType(sig, j, arrays, structs + 1) orelse return null;
            return if (j < sig.len) j + 1 else null;
        },
        else => return null,
    }
}

// ---------------------------------------------------------------- messages

pub const Kind = enum(u8) { call = 1, method_return = 2, @"error" = 3, signal = 4, _ };

pub const flag_no_reply = 0x1;

/// Header field codes (specification, "Message Format").
pub const Field = enum(u8) { path = 1, interface = 2, member = 3, error_name = 4, reply_serial = 5, destination = 6, sender = 7, signature = 8, unix_fds = 9, _ };

pub const Header = struct {
    kind: Kind,
    flags: u8 = 0,
    serial: u32,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: []const u8 = "",
    /// A SIGNATURE field present though empty (GDBus writes one on an
    /// empty reply): kept so the message encodes back to its bytes.
    empty_signature: bool = false,
    unix_fds: u32 = 0,
    /// The fields in the order they came (received messages).
    order: []const Field = &.{},
};

/// Field order of GDBus, the reference client of the byte tests: path,
/// interface, destination, signature, member; then the reply's own.
const send_order = [_]Field{ .unix_fds, .path, .interface, .destination, .signature, .member, .error_name, .reply_serial, .sender };
const reply_order = [_]Field{ .unix_fds, .destination, .error_name, .reply_serial, .signature, .sender };

/// Encodes a message: `order` lists the fields in wire order (fields
/// absent from the header are skipped).
pub fn encode(a: Allocator, h: Header, order: []const Field, body: []const u8) Allocator.Error![]u8 {
    var w: Writer = .{ .a = a };
    try w.buf.appendSlice(a, &.{ 'l', @backingInt(h.kind), h.flags, 1 });
    try w.int(u32, @intCast(body.len));
    try w.int(u32, h.serial);
    const mark = try w.beginArray(8);
    for (order) |f| {
        const sig: u8, const v: Value = switch (f) {
            .path => .{ 'o', .{ .o = h.path orelse continue } },
            .interface => .{ 's', .{ .s = h.interface orelse continue } },
            .member => .{ 's', .{ .s = h.member orelse continue } },
            .error_name => .{ 's', .{ .s = h.error_name orelse continue } },
            .reply_serial => .{ 'u', .{ .u = h.reply_serial orelse continue } },
            .destination => .{ 's', .{ .s = h.destination orelse continue } },
            .sender => .{ 's', .{ .s = h.sender orelse continue } },
            .signature => .{ 'g', .{ .g = if (h.signature.len > 0 or h.empty_signature) h.signature else continue } },
            .unix_fds => .{ 'u', .{ .u = if (h.unix_fds > 0) h.unix_fds else continue } },
            _ => continue,
        };
        try w.pad(8);
        try w.buf.append(a, @backingInt(f));
        try w.signature(&.{sig});
        try w.value(&.{sig}, v);
    }
    w.endArray(mark);
    try w.pad(8);
    try w.buf.appendSlice(a, body);
    return w.buf.items;
}

/// The fields of a message to send, in the order GDBus writes them.
pub fn encodeOutgoing(a: Allocator, h: Header, body: []const u8) Allocator.Error![]u8 {
    return encode(a, h, if (h.kind == .call or h.kind == .signal) &send_order else &reply_order, body);
}

/// A body of typed arguments.
pub fn encodeBody(a: Allocator, args: anytype, fds: *std.ArrayList(i32)) Allocator.Error![]const u8 {
    var w: Writer = .{ .a = a };
    const Args = @TypeOf(args);
    inline for (@typeInfo(Args).@"struct".field_names) |n| try w.typed(@FieldType(Args, n), @field(args, n));
    try fds.appendSlice(a, w.fds.items);
    return w.buf.items;
}

/// A method call to `dest` at `path`, its arguments checked against the
/// member's signature at compile time.
pub fn buildCall(a: Allocator, serial: u32, flags: u8, dest: ?[]const u8, path: []const u8, comptime m: Method, args: anytype, fds: *std.ArrayList(i32)) Allocator.Error![]u8 {
    comptime refuseDenied(m.interface, m.member);
    comptime checkArgs(m.member, m.in, @TypeOf(args));
    const body = try encodeBody(a, args, fds);
    return encodeOutgoing(a, .{
        .kind = .call,
        .flags = flags,
        .serial = serial,
        .path = path,
        .interface = m.interface,
        .member = m.member,
        .destination = dest,
        .signature = m.in,
        .unix_fds = @intCast(fds.items.len),
    }, body);
}

/// A member of the denied list (FR-61) fails the build, even written by
/// hand as a `Method` or `Signal` literal instead of generated.
fn refuseDenied(comptime interface: []const u8, comptime member: []const u8) void {
    const full = interface ++ "." ++ member;
    for (proto.denied) |d| if (std.mem.eql(u8, d, full)) @compileError("`" ++ full ++ "` is denied (FR-61)");
}

fn checkArgs(comptime member: []const u8, comptime want: []const u8, comptime Args: type) void {
    const got = bodySig(Args);
    if (!std.mem.eql(u8, got, want)) @compileError(member ++ " takes `" ++ want ++ "`, these arguments spell `" ++ got ++ "`");
}

pub const max_message = 128 << 20;

/// The length of the message that starts `data`, once its fixed header is
/// there; null while fewer than 16 bytes are buffered.
pub fn messageLength(data: []const u8, problem: *[]const u8) error{Malformed}!?usize {
    if (data.len < 16) return null;
    if (data[0] != 'l' and data[0] != 'B') {
        problem.* = "unknown byte order";
        return error.Malformed;
    }
    if (data[3] != 1) {
        problem.* = "protocol version other than 1";
        return error.Malformed;
    }
    const endian: std.builtin.Endian = if (data[0] == 'l') .little else .big;
    const body = std.mem.readInt(u32, data[4..8], endian);
    const fields = std.mem.readInt(u32, data[12..16], endian);
    if (fields > 64 << 20 or body > max_message) {
        problem.* = "message longer than 128 MiB";
        return error.Malformed;
    }
    const total = 16 + std.mem.alignForward(usize, fields, 8) + @as(usize, body);
    if (total > max_message) {
        problem.* = "message longer than 128 MiB";
        return error.Malformed;
    }
    return total;
}

pub const Message = struct {
    header: Header,
    body: []const u8,
    /// The whole message as received.
    raw: []const u8 = "",
    /// Descriptors the message carried; read ones are set to -1.
    fds: []i32,
    arena: Allocator,

    /// The body as the fields of `T`, checked against its signature.
    pub fn read(m: Message, comptime T: type) Error!T {
        if (!std.mem.eql(u8, m.header.signature, comptime bodySig(T))) return error.SignatureMismatch;
        var r: Reader = .{ .data = m.body, .fd_count = @intCast(m.fds.len), .arena = m.arena };
        var out: T = undefined;
        inline for (@typeInfo(T).@"struct".field_names) |n| @field(out, n) = try r.typed(@FieldType(T, n), m.fds);
        if (r.pos != m.body.len) return error.Malformed;
        return out;
    }

    /// Every argument, typed at run time.
    pub fn values(m: Message) Error![]const Value {
        var r: Reader = .{ .data = m.body, .fd_count = @intCast(m.fds.len), .arena = m.arena };
        var out: std.ArrayList(Value) = .empty;
        var i: usize = 0;
        while (i < m.header.signature.len) {
            const end = typeEnd(m.header.signature, i);
            try out.append(m.arena, try r.value(m.header.signature[i..end], 0));
            i = end;
        }
        if (r.pos != m.body.len) return error.Malformed;
        return out.items;
    }

    /// Closes the descriptors nobody read.
    pub fn closeFds(m: Message) void {
        sock.closeAll(m.fds);
        @memset(m.fds, -1);
    }

    pub fn is(m: Message, comptime s: Signal) bool {
        return m.header.kind == .signal and eqlOpt(m.header.interface, s.interface) and eqlOpt(m.header.member, s.member);
    }
};

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

/// Parses and validates a whole message (`bytes` is `messageLength`
/// long). `fds` are the descriptors that came with it.
pub fn parse(arena: Allocator, bytes: []const u8, fds: []i32, problem: *[]const u8) Error!Message {
    var r: Reader = .{ .data = bytes, .arena = arena };
    errdefer problem.* = r.problem;
    if (bytes[0] != 'l') return r.fail("big-endian message");
    var h: Header = .{ .kind = @fromBackingInt(@intCast(bytes[1])), .flags = bytes[2], .serial = std.mem.readInt(u32, bytes[8..12], .little) };
    switch (h.kind) {
        .call, .method_return, .@"error", .signal => {},
        _ => return r.fail("unknown message type"),
    }
    if (h.serial == 0) return r.fail("serial 0");
    const body_len = std.mem.readInt(u32, bytes[4..8], .little);
    r.pos = 12;
    const end = try r.arrayLen(8);
    var order: std.ArrayList(Field) = .empty;
    while (r.pos < end) {
        try r.skipPad(8);
        if (r.pos >= end) return r.fail("header field past the fields");
        const code: Field = @fromBackingInt(@intCast(r.data[r.pos]));
        r.pos += 1;
        const s = try r.signature();
        if (s.len == 0 or typeEnd(s, 0) != s.len) return r.fail("header field signature not one complete type");
        const want: ?u8 = switch (code) {
            .path => 'o',
            .interface, .member, .error_name, .destination, .sender => 's',
            .reply_serial, .unix_fds => 'u',
            .signature => 'g',
            _ => null,
        };
        if (want) |c| if (s.len != 1 or s[0] != c) return r.fail("header field of the wrong type");
        const v = try r.value(s, 1);
        try order.append(arena, code);
        switch (code) {
            .path => h.path = v.o,
            .interface => h.interface = v.s,
            .member => h.member = v.s,
            .error_name => h.error_name = v.s,
            .reply_serial => h.reply_serial = v.u,
            .destination => h.destination = v.s,
            .sender => h.sender = v.s,
            .signature => {
                h.signature = v.g;
                h.empty_signature = v.g.len == 0;
            },
            .unix_fds => h.unix_fds = v.u,
            _ => {},
        }
    }
    if (r.pos != end) return r.fail("header field past the fields");
    h.order = order.items;
    switch (h.kind) {
        .call => if (h.path == null or h.member == null) return r.fail("method call without path or member"),
        .signal => if (h.path == null or h.member == null or h.interface == null) return r.fail("signal without path, interface or member"),
        .method_return => if (h.reply_serial == null) return r.fail("reply without reply serial"),
        .@"error" => if (h.reply_serial == null or h.error_name == null) return r.fail("error without reply serial or name"),
        _ => unreachable,
    }
    if (h.unix_fds != fds.len) return r.fail("descriptor count differs from UNIX_FDS");
    try r.skipPad(8);
    if (bytes.len - r.pos != body_len) return r.fail("body length differs from the header");
    const m: Message = .{ .header = h, .body = bytes[r.pos..], .raw = bytes, .fds = fds, .arena = arena };
    // The body is validated here, once, against its signature.
    _ = m.values() catch |e| {
        var rr: Reader = .{ .data = m.body, .fd_count = @intCast(fds.len), .arena = arena };
        _ = rr.value(if (h.signature.len > 0) h.signature[0..typeEnd(h.signature, 0)] else "y", 0) catch {};
        r.problem = if (rr.problem.len > 0) rr.problem else "body does not match its signature";
        return e;
    };
    return m;
}

// ---------------------------------------------------------------- connection

pub const Connection = struct {
    gpa: Allocator,
    fd: i32 = -1,
    serial: u32 = 0,
    unique_buf: [256]u8 = undefined,
    unique_len: usize = 0,
    /// Bytes and descriptors read and not yet parsed.
    rx: std.ArrayList(u8) = .empty,
    rx_fds: std.ArrayList(i32) = .empty,
    /// Messages received while waiting for something else.
    inbox: std.ArrayList(Owned) = .empty,
    /// Why the connection closed, or why the last message was refused.
    problem: []const u8 = "",
    error_name_buf: [256]u8 = undefined,
    error_name_len: usize = 0,
    error_text_buf: [512]u8 = undefined,
    error_text_len: usize = 0,
    line_buf: [256]u8 = undefined,

    const Owned = struct { bytes: []u8, fds: []i32 };
    const inbox_limit = 4096;

    /// Connects to `address` (`unix:path=` or `unix:abstract=`, the first
    /// that works of a `;` list), authenticates and says Hello.
    pub fn open(gpa: Allocator, address: []const u8, timeout_ms: u32) Error!Connection {
        var c: Connection = .{ .gpa = gpa };
        errdefer c.deinit();
        c.fd = try connectAddress(address);
        try c.authenticate(sock.deadlineIn(timeout_ms));
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const name = try c.callTyped(arena.allocator(), "org.freedesktop.DBus", "/org/freedesktop/DBus", bus.Hello, .{}, struct { []const u8 }, timeout_ms);
        if (name[0].len > c.unique_buf.len) return error.Malformed;
        @memcpy(c.unique_buf[0..name[0].len], name[0]);
        c.unique_len = name[0].len;
        return c;
    }

    /// The session bus of `env` (`DBUS_SESSION_BUS_ADDRESS`).
    pub fn session(gpa: Allocator, env: *const std.process.Environ.Map, timeout_ms: u32) Error!Connection {
        return open(gpa, env.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.BadAddress, timeout_ms);
    }

    /// A connection already authenticated on `fd` (tests).
    pub fn adopt(gpa: Allocator, fd: i32) Connection {
        return .{ .gpa = gpa, .fd = fd };
    }

    pub fn deinit(c: *Connection) void {
        c.close("");
        c.rx.deinit(c.gpa);
        c.rx_fds.deinit(c.gpa);
        c.inbox.deinit(c.gpa);
    }

    /// Closes the socket and every descriptor it still holds.
    pub fn close(c: *Connection, why: []const u8) void {
        if (c.fd >= 0) _ = linux.close(c.fd);
        c.fd = -1;
        if (why.len > 0) c.problem = why;
        for (c.inbox.items) |o| {
            sock.closeAll(o.fds);
            c.gpa.free(o.fds);
            c.gpa.free(o.bytes);
        }
        c.inbox.clearRetainingCapacity();
        sock.closeAll(c.rx_fds.items);
        c.rx_fds.clearRetainingCapacity();
        c.rx.clearRetainingCapacity();
    }

    pub fn uniqueName(c: *const Connection) []const u8 {
        return c.unique_buf[0..c.unique_len];
    }

    pub fn errorName(c: *const Connection) []const u8 {
        return c.error_name_buf[0..c.error_name_len];
    }

    pub fn errorText(c: *const Connection) []const u8 {
        return c.error_text_buf[0..c.error_text_len];
    }

    fn connectAddress(address: []const u8) Error!i32 {
        var it = std.mem.splitScalar(u8, address, ';');
        while (it.next()) |one| {
            if (!std.mem.startsWith(u8, one, "unix:")) continue;
            var kv = std.mem.splitScalar(u8, one["unix:".len..], ',');
            while (kv.next()) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                const key = pair[0..eq];
                const abstract = std.mem.eql(u8, key, "abstract");
                if (!abstract and !std.mem.eql(u8, key, "path")) continue;
                var buf: [108]u8 = undefined;
                const path = unescape(pair[eq + 1 ..], &buf) orelse continue;
                return sock.connectUnix(path, abstract) catch continue;
            }
        }
        return error.BadAddress;
    }

    /// Decodes the %XX escapes of an address value.
    fn unescape(s: []const u8, buf: []u8) ?[]const u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (n += 1) {
            if (n >= buf.len) return null;
            if (s[i] == '%') {
                if (i + 3 > s.len) return null;
                buf[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
                i += 3;
            } else {
                buf[n] = s[i];
                i += 1;
            }
        }
        return buf[0..n];
    }

    fn authenticate(c: *Connection, deadline: ?u64) Error!void {
        var uid_buf: [16]u8 = undefined;
        const uid = std.fmt.bufPrint(&uid_buf, "{d}", .{linux.getuid()}) catch unreachable;
        var line: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&line);
        w.writeAll("\x00AUTH EXTERNAL ") catch unreachable;
        for (uid) |d| w.print("{x:0>2}", .{d}) catch unreachable;
        w.writeAll("\r\n") catch unreachable;
        try c.sendRaw(w.buffered(), &.{});
        if (!std.mem.startsWith(u8, try c.readLine(deadline), "OK ")) return error.AuthFailed;
        try c.sendRaw("NEGOTIATE_UNIX_FD\r\n", &.{});
        _ = try c.readLine(deadline); // AGREE_UNIX_FD, or ERROR: descriptors refused
        try c.sendRaw("BEGIN\r\n", &.{});
    }

    fn readLine(c: *Connection, deadline: ?u64) Error![]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, c.rx.items, "\r\n")) |end| {
                const n = @min(end, c.line_buf.len);
                @memcpy(c.line_buf[0..n], c.rx.items[0..n]);
                c.rx.replaceRangeAssumeCapacity(0, end + 2, &.{});
                return c.line_buf[0..n];
            }
            if (c.rx.items.len > 4096) return error.AuthFailed;
            try c.fill(deadline);
        }
    }

    fn sendRaw(c: *Connection, bytes: []const u8, fds: []const i32) Error!void {
        if (c.fd < 0) return error.Disconnected;
        sock.sendAll(c.fd, bytes, fds) catch {
            c.close("the peer closed the connection");
            return error.Disconnected;
        };
    }

    fn fill(c: *Connection, deadline: ?u64) Error!void {
        if (c.fd < 0) return error.Disconnected;
        var buf: [64 * 1024]u8 = undefined;
        const n = sock.recvSome(c.fd, &buf, &c.rx_fds, c.gpa, deadline) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                c.close("the peer closed the connection");
                return error.Disconnected;
            },
        };
        try c.rx.appendSlice(c.gpa, buf[0..n]);
    }

    pub fn nextSerial(c: *Connection) u32 {
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        return c.serial;
    }

    /// Sends a whole message with its descriptors.
    pub fn send(c: *Connection, bytes: []const u8, fds: []const i32) Error!void {
        try c.sendRaw(bytes, fds);
    }

    /// Reads until one whole message is buffered, then validates it.
    fn receiveOne(c: *Connection, arena: Allocator, deadline: ?u64) Error!Message {
        while (true) {
            if (c.fd < 0) return error.Disconnected;
            const len = messageLength(c.rx.items, &c.problem) catch {
                c.close(c.problem);
                return error.Malformed;
            };
            if (len) |total| if (c.rx.items.len >= total) {
                const bytes = try arena.dupe(u8, c.rx.items[0..total]);
                c.rx.replaceRangeAssumeCapacity(0, total, &.{});
                const nfds = if (total >= 16) countFds(bytes) else 0;
                if (nfds > c.rx_fds.items.len) {
                    c.close("descriptors announced and not received");
                    return error.Malformed;
                }
                const fds = try arena.dupe(i32, c.rx_fds.items[0..nfds]);
                c.rx_fds.replaceRangeAssumeCapacity(0, nfds, &.{});
                return parse(arena, bytes, fds, &c.problem) catch |e| {
                    sock.closeAll(fds);
                    c.close(c.problem);
                    return e;
                };
            };
            try c.fill(deadline);
        }
    }

    /// The UNIX_FDS field of a raw message, read without validation: the
    /// count of descriptors that came with it.
    fn countFds(bytes: []const u8) usize {
        var arena_buf: [8192]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&arena_buf);
        var r: Reader = .{ .data = bytes, .arena = fba.allocator() };
        r.pos = 12;
        const end = r.arrayLen(8) catch return 0;
        while (r.pos < end) {
            r.skipPad(8) catch return 0;
            if (r.pos >= end) return 0;
            const code = r.data[r.pos];
            r.pos += 1;
            const s = r.signature() catch return 0;
            if (s.len == 0) return 0;
            const v = r.value(s, 1) catch return 0;
            if (code == @backingInt(Field.unix_fds) and v == .u) return v.u;
        }
        return 0;
    }

    /// Keeps a message received while waiting for something else, for
    /// `next` and `waitSignal`. A reply is never kept: calls do not
    /// overlap, so a reply that is not the one awaited answers a call that
    /// already timed out, and nothing waits for it any more.
    fn keep(c: *Connection, m: Message) Error!void {
        if (m.header.kind == .method_return or m.header.kind == .@"error") {
            m.closeFds();
            return;
        }
        if (c.inbox.items.len >= inbox_limit) {
            const old = c.inbox.orderedRemove(0);
            sock.closeAll(old.fds);
            c.gpa.free(old.fds);
            c.gpa.free(old.bytes);
        }
        const bytes = try c.gpa.dupe(u8, m.raw);
        errdefer c.gpa.free(bytes);
        try c.inbox.append(c.gpa, .{ .bytes = bytes, .fds = try c.gpa.dupe(i32, m.fds) });
    }

    /// Sends a call and waits for its reply until the deadline. An error
    /// reply is `RemoteError` (`errorName`, `errorText`); other messages
    /// received meanwhile wait in the inbox.
    pub fn call(c: *Connection, arena: Allocator, dest: ?[]const u8, path: []const u8, comptime m: Method, args: anytype, timeout_ms: u32) Error!Message {
        var fds: std.ArrayList(i32) = .empty;
        const serial = c.nextSerial();
        const bytes = try buildCall(arena, serial, 0, dest, path, m, args, &fds);
        try c.send(bytes, fds.items);
        return c.waitReply(arena, serial, sock.deadlineIn(timeout_ms));
    }

    /// `call`, with the reply read as the fields of `Out`, checked at
    /// compile time against the member's out signature.
    pub fn callTyped(c: *Connection, arena: Allocator, dest: ?[]const u8, path: []const u8, comptime m: Method, args: anytype, comptime Out: type, timeout_ms: u32) Error!Out {
        comptime checkArgs(m.member ++ " (reply)", m.out, Out);
        const answer = try c.call(arena, dest, path, m, args, timeout_ms);
        errdefer answer.closeFds();
        return answer.read(Out);
    }

    /// A property through org.freedesktop.DBus.Properties.Get.
    pub fn getProperty(c: *Connection, arena: Allocator, dest: []const u8, path: []const u8, comptime p: Property, comptime T: type, timeout_ms: u32) Error!T {
        comptime if (!std.mem.eql(u8, sigOf(T), p.signature)) @compileError(p.name ++ " is `" ++ p.signature ++ "`");
        const v = try c.callTyped(arena, dest, path, props.Get, .{ @as([]const u8, p.interface), @as([]const u8, p.name) }, struct { Variant }, timeout_ms);
        return v[0].as(T);
    }

    fn waitReply(c: *Connection, arena: Allocator, serial: u32, deadline: ?u64) Error!Message {
        while (true) {
            const m = try c.receiveOne(arena, deadline);
            const is_reply = (m.header.kind == .method_return or m.header.kind == .@"error") and m.header.reply_serial == serial;
            if (!is_reply) {
                try c.keep(m);
                continue;
            }
            if (m.header.kind == .@"error") {
                const name = m.header.error_name orelse "";
                c.error_name_len = @min(name.len, c.error_name_buf.len);
                @memcpy(c.error_name_buf[0..c.error_name_len], name[0..c.error_name_len]);
                const text: []const u8 = if (std.mem.startsWith(u8, m.header.signature, "s")) blk: {
                    const vs = m.values() catch break :blk "";
                    break :blk vs[0].s;
                } else "";
                c.error_text_len = @min(text.len, c.error_text_buf.len);
                @memcpy(c.error_text_buf[0..c.error_text_len], text[0..c.error_text_len]);
                m.closeFds();
                return error.RemoteError;
            }
            return m;
        }
    }

    /// The next message other than a reply (a signal, or a call to this
    /// connection), from the inbox first; null at the deadline. A late
    /// reply to a call that timed out is dropped on the way.
    pub fn next(c: *Connection, arena: Allocator, timeout_ms: ?u32) Error!?Message {
        if (c.inbox.items.len > 0) {
            const o = c.inbox.orderedRemove(0);
            defer c.gpa.free(o.bytes);
            defer c.gpa.free(o.fds);
            const bytes = try arena.dupe(u8, o.bytes);
            const fds = try arena.dupe(i32, o.fds);
            return try parse(arena, bytes, fds, &c.problem);
        }
        const deadline = sock.deadlineIn(timeout_ms);
        while (true) {
            const m = c.receiveOne(arena, deadline) catch |e| switch (e) {
                error.Timeout => return null,
                else => return e,
            };
            if (m.header.kind == .method_return or m.header.kind == .@"error") {
                m.closeFds();
                continue;
            }
            return m;
        }
    }

    /// The next signal `s`, other messages kept for `next`; null at the
    /// deadline.
    pub fn waitSignal(c: *Connection, arena: Allocator, comptime s: Signal, path: ?[]const u8, timeout_ms: u32) Error!?Message {
        for (c.inbox.items, 0..) |o, i| {
            const m = try parse(arena, try arena.dupe(u8, o.bytes), try arena.dupe(i32, o.fds), &c.problem);
            if (m.is(s) and (path == null or eqlOpt(m.header.path, path.?))) {
                c.gpa.free(o.bytes);
                c.gpa.free(o.fds);
                _ = c.inbox.orderedRemove(i);
                return m;
            }
        }
        const deadline = sock.deadlineIn(timeout_ms);
        while (true) {
            const m = c.receiveOne(arena, deadline) catch |e| switch (e) {
                error.Timeout => return null,
                else => return e,
            };
            if (m.is(s) and (path == null or eqlOpt(m.header.path, path.?))) return m;
            try c.keep(m);
        }
    }

    /// Answers a method call received with `next`.
    pub fn reply(c: *Connection, arena: Allocator, to: Message, args: anytype) Error!void {
        var fds: std.ArrayList(i32) = .empty;
        const body = try encodeBody(arena, args, &fds);
        const bytes = try encodeOutgoing(arena, .{
            .kind = .method_return,
            .flags = flag_no_reply,
            .serial = c.nextSerial(),
            .reply_serial = to.header.serial,
            .destination = to.header.sender,
            .signature = comptime bodySig(@TypeOf(args)),
            .unix_fds = @intCast(fds.items.len),
        }, body);
        try c.send(bytes, fds.items);
    }

    /// Sends signal `s` from `path`.
    pub fn emit(c: *Connection, arena: Allocator, path: []const u8, comptime s: Signal, args: anytype) Error!void {
        comptime refuseDenied(s.interface, s.member);
        comptime checkArgs(s.member, s.signature, @TypeOf(args));
        var fds: std.ArrayList(i32) = .empty;
        const body = try encodeBody(arena, args, &fds);
        const bytes = try encodeOutgoing(arena, .{
            .kind = .signal,
            .flags = flag_no_reply,
            .serial = c.nextSerial(),
            .path = path,
            .interface = s.interface,
            .member = s.member,
            .signature = s.signature,
            .unix_fds = @intCast(fds.items.len),
        }, body);
        try c.send(bytes, fds.items);
    }

    /// Answers a method call with an error.
    pub fn replyError(c: *Connection, arena: Allocator, to: Message, name: []const u8, text: []const u8) Error!void {
        var fds: std.ArrayList(i32) = .empty;
        const body = try encodeBody(arena, .{text}, &fds);
        const bytes = try encodeOutgoing(arena, .{
            .kind = .@"error",
            .flags = flag_no_reply,
            .serial = c.nextSerial(),
            .reply_serial = to.header.serial,
            .destination = to.header.sender,
            .error_name = name,
            .signature = "s",
        }, body);
        try c.send(bytes, &.{});
    }

    // ------------------------------------------------------------ the bus

    pub fn addMatch(c: *Connection, arena: Allocator, rule: []const u8, timeout_ms: u32) Error!void {
        _ = try c.callTyped(arena, "org.freedesktop.DBus", "/org/freedesktop/DBus", bus.AddMatch, .{rule}, struct {}, timeout_ms);
    }

    pub const name_primary_owner = 1;
    pub const name_do_not_queue = 4;

    /// Requests `name` without queueing; whether this connection owns it.
    pub fn requestName(c: *Connection, arena: Allocator, name: []const u8, timeout_ms: u32) Error!bool {
        const r = try c.callTyped(arena, "org.freedesktop.DBus", "/org/freedesktop/DBus", bus.RequestName, .{ name, @as(u32, name_do_not_queue) }, struct { u32 }, timeout_ms);
        return r[0] == name_primary_owner;
    }

    /// The process id of the connection that owns `name`.
    pub fn pidOf(c: *Connection, arena: Allocator, name: []const u8, timeout_ms: u32) Error!u32 {
        const r = try c.callTyped(arena, "org.freedesktop.DBus", "/org/freedesktop/DBus", bus.GetConnectionUnixProcessID, .{name}, struct { u32 }, timeout_ms);
        return r[0];
    }

    /// The unique name owning `name`, or null when nobody does.
    pub fn ownerOf(c: *Connection, arena: Allocator, name: []const u8, timeout_ms: u32) Error!?[]const u8 {
        const r = c.callTyped(arena, "org.freedesktop.DBus", "/org/freedesktop/DBus", bus.GetNameOwner, .{name}, struct { []const u8 }, timeout_ms) catch |e| switch (e) {
            error.RemoteError => return null,
            else => return e,
        };
        return r[0];
    }
};

/// The French text of a transport failure, for a tool result (FR-06).
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Timeout => "Le service D-Bus ne répond pas dans le délai : réessaie dans un instant.",
        error.Disconnected => "Bus D-Bus de la session déconnecté : relance la session graphique.",
        error.Malformed => "Message D-Bus mal formé reçu : connexion fermée, réessaie l'action.",
        error.AuthFailed, error.BadAddress => "Bus D-Bus de la session introuvable : lance neo-compute depuis une session graphique.",
        error.RemoteError, error.SignatureMismatch => "Le service D-Bus a refusé l'appel.",
        error.OutOfMemory => "Mémoire insuffisante.",
    };
}
