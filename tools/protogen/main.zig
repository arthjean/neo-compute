//! protogen: generates the Zig protocol tables of the Linux backend from
//! pinned XML descriptions (tasks/prd-linux-port.md, US-077), as
//! tools/winmdgen does for Win32.
//!
//! usage: protogen <list.zon> <out.zig> <source>=<dir>...
//!
//! The list names Wayland and EI interfaces and D-Bus interface members;
//! each `<source>=<dir>` maps a source name of the list to the root of a
//! package pinned by hash in build.zig.zon. A Wayland or EI interface is
//! emitted whole: a message's opcode is its rank in the XML, and an event
//! left out would leave its file descriptors unaccounted for. The
//! interfaces its arguments name are emitted too (the closure). A D-Bus
//! interface brings only the members listed. A name absent from its source
//! fails generation and names the closest one; a denied name fails it
//! whatever the list says (FR-61).

const std = @import("std");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;

pub const List = struct {
    wayland: []const Protocol = &.{},
    ei: []const Protocol = &.{},
    dbus: []const DBusEntry = &.{},

    pub const Protocol = struct { source: []const u8, file: []const u8, interfaces: []const []const u8 };
    pub const DBusEntry = struct { source: []const u8, file: []const u8, interface: []const u8, members: []const []const u8 };
};

/// Names the server must never call, whatever bindings/linux.zon asks
/// (FR-61, audit 4.1 and 4.2).
pub const denied = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = "org.gnome.Mutter.RemoteDesktop.Session.SetKeymap", .why = "crashes Mutter 51.1 (SIGSEGV in meta_keymap_description_create_xkb_keymap, audit 4.1)" },
    .{ .name = "org.gnome.ScreenSaver.SetActive", .why = "unlocks the screen without a password (audit 4.1)" },
    .{ .name = "org_kde_kwin_fake_input", .why = "keeps a held key pressed after its client dies (audit 4.2)" },
};

fn deniedWhy(name: []const u8) ?[]const u8 {
    for (denied) |d| if (std.mem.eql(u8, d.name, name)) return d.why;
    return null;
}

// ---------------------------------------------------------------- model

pub const Family = enum { wayland, ei };

pub const Kind = enum { int, uint, fixed, string, object, new_id, array, fd, int64, uint64, float };

pub const Arg = struct {
    name: []const u8,
    kind: Kind,
    interface: ?[]const u8 = null,
    /// Index of the string argument that names a new_id's interface (EI).
    interface_arg: ?usize = null,
    nullable: bool = false,
    enum_name: ?[]const u8 = null,
};

pub const Message = struct { name: []const u8, since: u32, destructor: bool, args: []const Arg };
pub const Entry = struct { name: []const u8, value: u64 };
pub const Enum = struct { name: []const u8, bitfield: bool, entries: []const Entry };

pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const Message,
    events: []const Message,
    enums: []const Enum,
    file: []const u8,
};

pub const Failure = error{ OutOfMemory, Invalid };

/// Reports a generation error on stderr (or into `log` in tests).
pub const Report = struct {
    log: ?*std.Io.Writer = null,

    pub fn err(r: Report, comptime fmt: []const u8, args: anytype) Failure {
        r.note(fmt, args);
        return error.Invalid;
    }

    /// Reports an error and lets generation go on to report the next.
    pub fn note(r: Report, comptime fmt: []const u8, args: anytype) void {
        if (r.log) |w| {
            w.print("protogen: " ++ fmt ++ "\n", args) catch {};
        } else std.debug.print("protogen: " ++ fmt ++ "\n", args);
    }
};

fn parseKind(family: Family, t: []const u8) ?Kind {
    const table: []const struct { []const u8, Kind } = switch (family) {
        .wayland => &.{ .{ "int", .int }, .{ "uint", .uint }, .{ "fixed", .fixed }, .{ "string", .string }, .{ "object", .object }, .{ "new_id", .new_id }, .{ "array", .array }, .{ "fd", .fd } },
        .ei => &.{ .{ "int32", .int }, .{ "uint32", .uint }, .{ "int64", .int64 }, .{ "uint64", .uint64 }, .{ "float", .float }, .{ "string", .string }, .{ "object", .object }, .{ "new_id", .new_id }, .{ "fd", .fd } },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], t)) return e[1];
    return null;
}

fn parseU32(r: Report, file: []const u8, line: u32, what: []const u8, s: ?[]const u8, default: u32) Failure!u32 {
    const v = s orelse return default;
    return std.fmt.parseInt(u32, v, 0) catch r.err("{s}:{d}: invalid {s} `{s}`", .{ file, line, what, v });
}

/// Every interface of a Wayland or EI protocol file.
pub fn readProtocol(arena: Allocator, r: Report, family: Family, file: []const u8, root: xml.Element) Failure![]const Interface {
    if (!std.mem.eql(u8, root.name, "protocol")) return r.err("{s}: root element is <{s}>, expected <protocol>", .{ file, root.name });
    var out: std.ArrayList(Interface) = .empty;
    var it = root.each("interface");
    while (it.next()) |ie| {
        const name = ie.attr("name") orelse return r.err("{s}:{d}: interface without a name", .{ file, ie.line });
        const version = try parseU32(r, file, ie.line, "version", ie.attr("version"), 0);
        if (version == 0) return r.err("{s}:{d}: interface `{s}` without a version", .{ file, ie.line, name });
        var lists: [2]std.ArrayList(Message) = .{ .empty, .empty };
        for (ie.children) |me| {
            const which: usize = if (std.mem.eql(u8, me.name, "request")) 0 else if (std.mem.eql(u8, me.name, "event")) 1 else continue;
            const mname = me.attr("name") orelse return r.err("{s}:{d}: message without a name", .{ file, me.line });
            var args: std.ArrayList(Arg) = .empty;
            var ait = me.each("arg");
            while (ait.next()) |ae| {
                const aname = ae.attr("name") orelse return r.err("{s}:{d}: argument without a name", .{ file, ae.line });
                const t = ae.attr("type") orelse return r.err("{s}:{d}: argument `{s}` without a type", .{ file, ae.line, aname });
                const kind = parseKind(family, t) orelse return r.err("{s}:{d}: argument `{s}` of unknown type `{s}`", .{ file, ae.line, aname, t });
                try args.append(arena, .{
                    .name = aname,
                    .kind = kind,
                    .interface = ae.attr("interface"),
                    .nullable = if (ae.attr("allow-null")) |v| std.mem.eql(u8, v, "true") else false,
                    .enum_name = ae.attr("enum"),
                });
                if (ae.attr("interface_arg")) |ia| {
                    // Resolved below, once every argument is known.
                    args.items[args.items.len - 1].interface = ia;
                    args.items[args.items.len - 1].interface_arg = std.math.maxInt(usize);
                }
            }
            // EI names a new_id's interface by another argument, either
            // with interface_arg or, in protocol.xml 1.6, with an
            // `interface` that is that argument's name.
            for (args.items) |*a| {
                if (a.kind != .new_id) continue;
                const ref = a.interface orelse continue;
                for (args.items, 0..) |b, bi| if (b.kind == .string and std.mem.eql(u8, b.name, ref)) {
                    a.interface_arg = bi;
                    a.interface = null;
                    break;
                };
                if (a.interface_arg == std.math.maxInt(usize)) return r.err("{s}:{d}: interface_arg `{s}` names no string argument", .{ file, me.line, ref });
            }
            try lists[which].append(arena, .{
                .name = mname,
                .since = try parseU32(r, file, me.line, "since", me.attr("since"), 1),
                .destructor = if (me.attr("type")) |v| std.mem.eql(u8, v, "destructor") else false,
                .args = try args.toOwnedSlice(arena),
            });
        }
        var enums: std.ArrayList(Enum) = .empty;
        var eit = ie.each("enum");
        while (eit.next()) |ee| {
            const ename = ee.attr("name") orelse return r.err("{s}:{d}: enum without a name", .{ file, ee.line });
            var entries: std.ArrayList(Entry) = .empty;
            var xit = ee.each("entry");
            while (xit.next()) |xe| {
                const xname = xe.attr("name") orelse return r.err("{s}:{d}: enum entry without a name", .{ file, xe.line });
                const v = xe.attr("value") orelse return r.err("{s}:{d}: enum entry `{s}` without a value", .{ file, xe.line, xname });
                try entries.append(arena, .{ .name = xname, .value = std.fmt.parseInt(u64, v, 0) catch return r.err("{s}:{d}: invalid enum value `{s}`", .{ file, xe.line, v }) });
            }
            try enums.append(arena, .{
                .name = ename,
                .bitfield = if (ee.attr("bitfield")) |v| std.mem.eql(u8, v, "true") else false,
                .entries = try entries.toOwnedSlice(arena),
            });
        }
        try out.append(arena, .{
            .name = name,
            .version = version,
            .requests = try lists[0].toOwnedSlice(arena),
            .events = try lists[1].toOwnedSlice(arena),
            .enums = try enums.toOwnedSlice(arena),
            .file = file,
        });
    }
    return out.toOwnedSlice(arena);
}

pub const DBusMember = struct {
    pub const Kind = enum { method, signal, property };
    name: []const u8,
    kind: DBusMember.Kind,
    /// Method: in arguments; signal: its arguments; property: its type.
    in: []const u8,
    /// Method: out arguments.
    out: []const u8 = "",
    readable: bool = false,
    writable: bool = false,
};

pub const DBusInterface = struct { name: []const u8, members: []const DBusMember, file: []const u8 };

/// Every interface of a D-Bus introspection file, with signatures checked.
pub fn readIntrospection(arena: Allocator, r: Report, file: []const u8, root: xml.Element) Failure![]const DBusInterface {
    if (!std.mem.eql(u8, root.name, "node")) return r.err("{s}: root element is <{s}>, expected <node>", .{ file, root.name });
    var out: std.ArrayList(DBusInterface) = .empty;
    var it = root.each("interface");
    while (it.next()) |ie| {
        const name = ie.attr("name") orelse return r.err("{s}:{d}: interface without a name", .{ file, ie.line });
        var members: std.ArrayList(DBusMember) = .empty;
        for (ie.children) |me| {
            const kind: DBusMember.Kind = if (std.mem.eql(u8, me.name, "method")) .method else if (std.mem.eql(u8, me.name, "signal")) .signal else if (std.mem.eql(u8, me.name, "property")) .property else continue;
            const mname = me.attr("name") orelse return r.err("{s}:{d}: member without a name", .{ file, me.line });
            if (kind == .property) {
                const t = me.attr("type") orelse return r.err("{s}:{d}: property `{s}` without a type", .{ file, me.line, mname });
                try checkSignature(r, file, me.line, t, true);
                const access = me.attr("access") orelse "read";
                try members.append(arena, .{
                    .name = mname,
                    .kind = .property,
                    .in = t,
                    .readable = std.mem.indexOf(u8, access, "read") != null,
                    .writable = std.mem.indexOf(u8, access, "write") != null,
                });
                continue;
            }
            var in: std.ArrayList(u8) = .empty;
            var outs: std.ArrayList(u8) = .empty;
            var ait = me.each("arg");
            while (ait.next()) |ae| {
                const t = ae.attr("type") orelse return r.err("{s}:{d}: argument of `{s}` without a type", .{ file, ae.line, mname });
                try checkSignature(r, file, ae.line, t, true);
                // A signal's arguments are its body whatever their
                // direction says (gnome-shell marks them `out`).
                const dir_out = kind == .method and if (ae.attr("direction")) |d| std.mem.eql(u8, d, "out") else false;
                try (if (dir_out) &outs else &in).appendSlice(arena, t);
            }
            try checkSignature(r, file, me.line, in.items, false);
            try checkSignature(r, file, me.line, outs.items, false);
            try members.append(arena, .{ .name = mname, .kind = kind, .in = in.items, .out = outs.items });
        }
        try out.append(arena, .{ .name = name, .members = try members.toOwnedSlice(arena), .file = file });
    }
    return out.toOwnedSlice(arena);
}

/// D-Bus signature rules (specification, "Type System"): complete types
/// only, at most 255 bytes, 32 nested arrays and 32 nested structures, a
/// dict entry only as an array element with a basic key, no empty
/// structure. `single`: exactly one complete type.
pub fn checkSignature(r: Report, file: []const u8, line: u32, sig: []const u8, single: bool) Failure!void {
    if (validSignature(sig, single)) |why| return r.err("{s}:{d}: invalid D-Bus signature `{s}`: {s}", .{ file, line, sig, why });
}

/// Null when `sig` is valid, else the reason.
pub fn validSignature(sig: []const u8, single: bool) ?[]const u8 {
    if (sig.len > 255) return "longer than 255 bytes";
    var i: usize = 0;
    var count: usize = 0;
    while (i < sig.len) {
        i = completeType(sig, i, 0, 0) catch |e| return @errorName(e);
        count += 1;
    }
    if (single and count != 1) return "not exactly one complete type";
    return null;
}

const SigError = error{ UnknownTypeCode, TooDeep, EmptyStructure, UnterminatedStructure, BadDictEntry, MissingElementType };

fn isBasic(c: u8) bool {
    return std.mem.indexOfScalar(u8, "ybnqiuxtdsogh", c) != null;
}

fn completeType(sig: []const u8, start: usize, arrays: usize, structs: usize) SigError!usize {
    if (start >= sig.len) return error.MissingElementType;
    const c = sig[start];
    if (isBasic(c) or c == 'v') return start + 1;
    switch (c) {
        'a' => {
            if (arrays >= 32) return error.TooDeep;
            if (start + 1 < sig.len and sig[start + 1] == '{') {
                var i = start + 2;
                if (i >= sig.len or !isBasic(sig[i])) return error.BadDictEntry;
                i += 1;
                i = try completeType(sig, i, arrays + 1, structs + 1);
                if (i >= sig.len or sig[i] != '}') return error.BadDictEntry;
                return i + 1;
            }
            return completeType(sig, start + 1, arrays + 1, structs);
        },
        '(' => {
            if (structs >= 32) return error.TooDeep;
            var i = start + 1;
            if (i < sig.len and sig[i] == ')') return error.EmptyStructure;
            while (i < sig.len and sig[i] != ')') i = try completeType(sig, i, arrays, structs + 1);
            if (i >= sig.len) return error.UnterminatedStructure;
            return i + 1;
        },
        '{', '}' => return error.BadDictEntry,
        else => return error.UnknownTypeCode,
    }
}

// ---------------------------------------------------------------- generation

/// Sources by name: `name=dir` arguments.
pub const Sources = struct {
    names: []const []const u8,
    dirs: []const std.Io.Dir,
};

pub const Loader = struct {
    arena: Allocator,
    io: std.Io,
    sources: Sources,
    report: Report,

    pub fn read(l: Loader, source: []const u8, file: []const u8) Failure!xml.Element {
        const dir = for (l.sources.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, source)) break l.sources.dirs[i];
        } else return l.report.err("unknown source `{s}` for {s}; sources: {s}", .{ source, file, joined(l.arena, l.sources.names) });
        const bytes = dir.readFileAlloc(l.io, file, l.arena, .limited(16 << 20)) catch |e|
            return l.report.err("cannot read {s} in source `{s}`: {t}", .{ file, source, e });
        var diag: xml.Diagnostic = .{};
        return xml.parse(l.arena, bytes, &diag) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => l.report.err("{s}/{s}:{d}: {s} ({t})", .{ source, file, diag.line, diag.reason, e }),
        };
    }
};

fn joined(a: Allocator, names: []const []const u8) []const u8 {
    return std.mem.join(a, ", ", names) catch "";
}

fn levenshtein(a: []const u8, b: []const u8) usize {
    var prev: [256]usize = undefined;
    var cur: [256]usize = undefined;
    if (b.len >= prev.len) return std.math.maxInt(usize);
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

pub fn closest(name: []const u8, candidates: []const []const u8) []const u8 {
    var best: []const u8 = "";
    var best_d: usize = std.math.maxInt(usize);
    for (candidates) |c| {
        const d = levenshtein(name, c);
        if (d < best_d) {
            best_d = d;
            best = c;
        }
    }
    return best;
}

/// The interfaces emitted for one family, in a stable order: the list's
/// order, then the closure in discovery order.
fn resolveFamily(l: Loader, family: Family, protocols: []const List.Protocol) Failure![]const Interface {
    const a = l.arena;
    var all: std.ArrayList(Interface) = .empty;
    var files: std.ArrayList([]const Interface) = .empty;
    for (protocols) |p| {
        const root = try l.read(p.source, p.file);
        const label = try std.fmt.allocPrint(a, "{s}/{s}", .{ p.source, p.file });
        const ifaces = try readProtocol(a, l.report, family, label, root);
        try files.append(a, ifaces);
        try all.appendSlice(a, ifaces);
    }
    var out: std.ArrayList(Interface) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var failed = false;
    for (protocols, files.items) |p, ifaces| {
        for (p.interfaces) |want| {
            if (deniedWhy(want)) |why| {
                l.report.note("`{s}` is denied: it {s}", .{ want, why });
                failed = true;
                continue;
            }
            const found = for (ifaces) |i| {
                if (std.mem.eql(u8, i.name, want)) break i;
            } else {
                var names: std.ArrayList([]const u8) = .empty;
                for (ifaces) |i| try names.append(a, i.name);
                l.report.note("`{s}` not found in {s}/{s}; closest existing name: `{s}`", .{ want, p.source, p.file, closest(want, names.items) });
                failed = true;
                continue;
            };
            if (!(try seen.getOrPut(a, found.name)).found_existing) try out.append(a, found);
        }
    }
    if (failed) return error.Invalid;
    // The closure: interfaces named by arguments and enums.
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        const iface = out.items[i];
        for ([_][]const Message{ iface.requests, iface.events }) |msgs| for (msgs) |m| for (m.args) |arg| {
            var refs: [2]?[]const u8 = .{ arg.interface, null };
            if (arg.enum_name) |e| if (std.mem.indexOfScalar(u8, e, '.')) |dot| {
                refs[1] = e[0..dot];
            };
            for (refs) |maybe| {
                const ref = maybe orelse continue;
                if (seen.contains(ref)) continue;
                if (deniedWhy(ref)) |why| return l.report.err("`{s}` reaches `{s}`, which is denied: it {s}", .{ iface.name, ref, why });
                const found = for (all.items) |c| {
                    if (std.mem.eql(u8, c.name, ref)) break c;
                } else return l.report.err("`{s}` names interface `{s}`, found in no {t} source of the list", .{ iface.name, ref, family });
                try seen.put(a, found.name, {});
                try out.append(a, found);
            }
        };
    }
    return out.toOwnedSlice(a);
}

const ResolvedDBus = struct { interface: []const u8, members: []const DBusMember, source: []const u8 };

fn resolveDBus(l: Loader, entries: []const List.DBusEntry) Failure![]const ResolvedDBus {
    const a = l.arena;
    var out: std.ArrayList(ResolvedDBus) = .empty;
    var failed = false;
    for (entries) |e| {
        const root = try l.read(e.source, e.file);
        const label = try std.fmt.allocPrint(a, "{s}/{s}", .{ e.source, e.file });
        const ifaces = try readIntrospection(a, l.report, label, root);
        const iface = for (ifaces) |i| {
            if (std.mem.eql(u8, i.name, e.interface)) break i;
        } else {
            var names: std.ArrayList([]const u8) = .empty;
            for (ifaces) |i| try names.append(a, i.name);
            l.report.note("`{s}` not found in {s}; closest existing name: `{s}`", .{ e.interface, label, closest(e.interface, names.items) });
            failed = true;
            continue;
        };
        for (out.items) |o| if (std.mem.eql(u8, o.interface, iface.name)) {
            l.report.note("interface `{s}` listed twice", .{iface.name});
            failed = true;
        };
        var members: std.ArrayList(DBusMember) = .empty;
        for (e.members) |want| {
            const full = try std.fmt.allocPrint(a, "{s}.{s}", .{ iface.name, want });
            if (deniedWhy(full)) |why| {
                l.report.note("`{s}` is denied: it {s}", .{ full, why });
                failed = true;
                continue;
            }
            const m = for (iface.members) |m| {
                if (std.mem.eql(u8, m.name, want)) break m;
            } else {
                var names: std.ArrayList([]const u8) = .empty;
                for (iface.members) |m| try names.append(a, m.name);
                l.report.note("`{s}` not found in {s} ({s}); closest existing name: `{s}`", .{ want, iface.name, label, closest(want, names.items) });
                failed = true;
                continue;
            };
            for (members.items) |x| if (std.mem.eql(u8, x.name, m.name)) {
                l.report.note("member `{s}` listed twice", .{full});
                failed = true;
            };
            try members.append(a, m);
        }
        try out.append(a, .{ .interface = iface.name, .members = try members.toOwnedSlice(a), .source = label });
    }
    if (failed) return error.Invalid;
    return out.toOwnedSlice(a);
}

const preamble =
    \\/// A Wayland or EI argument type. `int64`, `uint64` and `float` are EI's.
    \\pub const Kind = enum { int, uint, fixed, string, object, new_id, array, fd, int64, uint64, float };
    \\
    \\pub const Arg = struct {
    \\    name: []const u8,
    \\    kind: Kind,
    \\    /// The interface of an object or new_id argument, when the XML names it.
    \\    interface: ?[]const u8 = null,
    \\    /// The string argument that names a new_id's interface (EI).
    \\    interface_arg: ?u8 = null,
    \\    nullable: bool = false,
    \\};
    \\
    \\pub const Message = struct {
    \\    name: []const u8,
    \\    /// The first interface version that has this message.
    \\    since: u32,
    \\    destructor: bool,
    \\    args: []const Arg,
    \\};
    \\
    \\pub const Interface = struct {
    \\    name: []const u8,
    \\    version: u32,
    \\    /// Indexed by opcode.
    \\    requests: []const Message,
    \\    events: []const Message,
    \\};
    \\
    \\pub const Method = struct { interface: []const u8, member: []const u8, in: []const u8, out: []const u8 };
    \\pub const Signal = struct { interface: []const u8, member: []const u8, signature: []const u8 };
    \\pub const Property = struct { interface: []const u8, name: []const u8, signature: []const u8, readable: bool, writable: bool };
    \\
    \\
;

fn emitMessages(w: *std.Io.Writer, field: []const u8, msgs: []const Message) !void {
    try w.print("        .{s} = &.{{\n", .{field});
    for (msgs) |m| {
        try w.print("            .{{ .name = \"{f}\", .since = {d}, .destructor = {}, .args = &.{{", .{ std.zig.fmtString(m.name), m.since, m.destructor });
        for (m.args, 0..) |arg, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(" .{{ .name = \"{f}\", .kind = .{t}", .{ std.zig.fmtString(arg.name), arg.kind });
            if (arg.interface) |iface| try w.print(", .interface = \"{f}\"", .{std.zig.fmtString(iface)});
            if (arg.interface_arg) |ia| try w.print(", .interface_arg = {d}", .{ia});
            if (arg.nullable) try w.writeAll(", .nullable = true");
            try w.writeAll(" }");
        }
        try w.writeAll(" } },\n");
    }
    try w.writeAll("        },\n");
}

fn emitFamily(w: *std.Io.Writer, family: Family, ifaces: []const Interface) !void {
    try w.print("pub const {t} = struct {{\n", .{family});
    for (ifaces) |iface| {
        try w.print("    /// {s}\n    pub const {f} = struct {{\n", .{ iface.file, std.zig.fmtId(iface.name) });
        try w.print("        pub const interface: Interface = .{{\n            .name = \"{f}\",\n            .version = {d},\n", .{ std.zig.fmtString(iface.name), iface.version });
        try emitMessages(w, "requests", iface.requests);
        try emitMessages(w, "events", iface.events);
        try w.writeAll("        };\n");
        inline for (.{ .{ "request", "requests" }, .{ "event", "events" } }) |pair| {
            const msgs = @field(iface, pair[1]);
            try w.print("        pub const {s} = struct {{\n", .{pair[0]});
            for (msgs, 0..) |m, op| try w.print("            pub const {f}: u16 = {d};\n", .{ std.zig.fmtId(m.name), op });
            try w.writeAll("        };\n");
        }
        try w.writeAll("        pub const enums = struct {\n");
        for (iface.enums) |e| {
            try w.print("            pub const {f} = struct {{\n", .{std.zig.fmtId(e.name)});
            for (e.entries) |x| try w.print("                pub const {f}: u64 = {d};\n", .{ std.zig.fmtIdPU(x.name), x.value });
            try w.writeAll("            };\n");
        }
        try w.writeAll("        };\n    };\n");
    }
    try w.writeAll("    pub const all = [_]*const Interface{\n");
    for (ifaces) |iface| try w.print("        &{f}.interface,\n", .{std.zig.fmtId(iface.name)});
    try w.writeAll("    };\n};\n\n");
}

fn emitDBus(w: *std.Io.Writer, a: Allocator, ifaces: []const ResolvedDBus) !void {
    try w.writeAll("pub const dbus = struct {\n");
    for (ifaces) |iface| {
        const ident = try std.mem.replaceOwned(u8, a, iface.interface, ".", "_");
        try w.print("    /// {s}\n    pub const {f} = struct {{\n        pub const iface = \"{f}\";\n", .{ iface.source, std.zig.fmtId(ident), std.zig.fmtString(iface.interface) });
        for (iface.members) |m| {
            const id = std.zig.fmtId(m.name);
            const name = std.zig.fmtString(m.name);
            const ifn = std.zig.fmtString(iface.interface);
            switch (m.kind) {
                .method => try w.print("        pub const {f}: Method = .{{ .interface = \"{f}\", .member = \"{f}\", .in = \"{f}\", .out = \"{f}\" }};\n", .{ id, ifn, name, std.zig.fmtString(m.in), std.zig.fmtString(m.out) }),
                .signal => try w.print("        pub const {f}: Signal = .{{ .interface = \"{f}\", .member = \"{f}\", .signature = \"{f}\" }};\n", .{ id, ifn, name, std.zig.fmtString(m.in) }),
                .property => try w.print("        pub const {f}: Property = .{{ .interface = \"{f}\", .name = \"{f}\", .signature = \"{f}\", .readable = {}, .writable = {} }};\n", .{ id, ifn, name, std.zig.fmtString(m.in), m.readable, m.writable }),
            }
        }
        try w.writeAll("    };\n");
    }
    try w.writeAll("};\n");
}

/// The denied names, for the transports to refuse at compile time a
/// member written by hand instead of generated (FR-61).
fn emitDenied(w: *std.Io.Writer) !void {
    try w.writeAll("/// Names the server never calls (FR-61), whatever is written by hand.\npub const denied = [_][]const u8{\n");
    for (denied) |d| try w.print("    \"{f}\",\n", .{std.zig.fmtString(d.name)});
    try w.writeAll("};\n\n");
}

/// The generated file for `list`.
pub fn generate(l: Loader, list: List, list_name: []const u8) Failure![]const u8 {
    const a = l.arena;
    var failed = false;
    const wayland = resolveFamily(l, .wayland, list.wayland) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.Invalid => blk: {
            failed = true;
            break :blk &.{};
        },
    };
    const ei = resolveFamily(l, .ei, list.ei) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.Invalid => blk: {
            failed = true;
            break :blk &.{};
        },
    };
    const dbus = resolveDBus(l, list.dbus) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.Invalid => blk: {
            failed = true;
            break :blk &.{};
        },
    };
    if (failed) return error.Invalid;

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    (blk: {
        w.print("//! Generated by tools/protogen from {s} and the XML sources pinned in\n//! build.zig.zon. Do not edit: change {s} instead.\n\n", .{ list_name, list_name }) catch |e| break :blk e;
        w.writeAll(preamble) catch |e| break :blk e;
        emitDenied(w) catch |e| break :blk e;
        emitFamily(w, .wayland, wayland) catch |e| break :blk e;
        emitFamily(w, .ei, ei) catch |e| break :blk e;
        emitDBus(w, a, dbus) catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return out.written();
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 4 and std.mem.eql(u8, args[1], "dlopen-types")) {
        const cwd = std.Io.Dir.cwd();
        const src = try cwd.readFileAlloc(io, args[2], arena, .limited(16 << 20));
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = try dlopenTypes(arena, src) });
        return 0;
    }
    if (args.len < 3) {
        std.debug.print("usage: protogen <list.zon> <out.zig> <source>=<dir>...\n", .{});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    const list_src = try cwd.readFileAllocOptions(io, args[1], arena, .limited(1 << 20), .of(u8), 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const list = std.zon.parse.fromSlice(List, .{ .gpa = arena, .arena = arena, .source = list_src, .diagnostics = &diag }) catch {
        diag.log(args[1]);
        return 1;
    };
    var names: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList(std.Io.Dir) = .empty;
    for (args[3..]) |s| {
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse {
            std.debug.print("protogen: source `{s}` is not <name>=<dir>\n", .{s});
            return 2;
        };
        try names.append(arena, s[0..eq]);
        try dirs.append(arena, cwd.openDir(io, s[eq + 1 ..], .{}) catch |e| {
            std.debug.print("protogen: cannot open source {s}: {t}\n", .{ s, e });
            return 1;
        });
    }
    const loader: Loader = .{ .arena = arena, .io = io, .sources = .{ .names = names.items, .dirs = dirs.items }, .report = .{} };
    const text = generate(loader, list, std.fs.path.basename(args[1])) catch |e| switch (e) {
        error.Invalid => return 1,
        error.OutOfMemory => return e,
    };
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = text });
    return 0;
}

/// A translate-c module whose functions are types: each
/// `pub extern fn name(params) Ret;` becomes
/// `pub const name = fn (params) callconv(.c) Ret;`. A library loaded
/// with dlopen takes its function types from its own header this way,
/// and the binary keeps no reference to its symbols.
pub fn dlopenTypes(a: Allocator, src: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        const prefix = "pub extern fn ";
        if (!std.mem.startsWith(u8, line, prefix) or !std.mem.endsWith(u8, line, ";")) {
            try out.appendSlice(a, line);
            continue;
        }
        const rest = line[prefix.len..];
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse {
            try out.appendSlice(a, line);
            continue;
        };
        // The parameters end at the parenthesis that closes the first.
        var depth: usize = 0;
        var close: usize = paren;
        for (rest[paren..], paren..) |ch, i| switch (ch) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    close = i;
                    break;
                }
            },
            else => {},
        };
        const name = rest[0..paren];
        const params = rest[paren .. close + 1];
        const ret = std.mem.trim(u8, rest[close + 1 .. rest.len - 1], " ");
        try out.print(a, "pub const {s} = fn {s} callconv(.c) {s};", .{ name, params, ret });
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

test "translate-c functions become function types for dlopen" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try dlopenTypes(arena.allocator(),
        \\pub const struct_x = opaque {};
        \\pub extern fn x_new(flags: c_int) ?*struct_x;
        \\pub extern fn x_cb(f: ?*const fn (c_int) callconv(.c) void, ...) void;
    );
    try testing.expectEqualStrings(
        \\pub const struct_x = opaque {};
        \\pub const x_new = fn (flags: c_int) callconv(.c) ?*struct_x;
        \\pub const x_cb = fn (f: ?*const fn (c_int) callconv(.c) void, ...) callconv(.c) void;
    , out);
}

const testing = std.testing;

test {
    _ = xml;
}

/// Generates `list` against files held in memory, in a temporary folder.
fn generateFromFiles(a: Allocator, files: []const [2][]const u8, list: List, log: *std.Io.Writer) Failure![]const u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (files) |f| tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] }) catch return error.OutOfMemory;
    const dir = tmp.dir;
    const loader: Loader = .{ .arena = a, .io = testing.io, .sources = .{ .names = &.{"t"}, .dirs = &.{dir} }, .report = .{ .log = log } };
    return generate(loader, list, "test.zon");
}

const mini_wayland =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<protocol name="mini">
    \\  <interface name="wl_thing" version="3">
    \\    <request name="make"><arg name="id" type="new_id" interface="wl_other"/><arg name="flag" type="uint" enum="wl_other.mode"/></request>
    \\    <request name="destroy" type="destructor" since="2"/>
    \\    <event name="error"><arg name="code" type="int"/><arg name="message" type="string" allow-null="true"/></event>
    \\    <enum name="error"><entry name="bad" value="0"/><entry name="2d" value="0x10"/></enum>
    \\  </interface>
    \\  <interface name="wl_other" version="1">
    \\    <event name="done"><arg name="fd" type="fd"/></event>
    \\    <enum name="mode" bitfield="true"><entry name="a" value="1"/></enum>
    \\  </interface>
    \\  <interface name="wl_unused" version="1"/>
    \\</protocol>
;

test "a minimal Wayland protocol gives opcodes, signatures, enums and versions, with its closure" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var log: std.Io.Writer.Allocating = .init(arena.allocator());
    const text = try generateFromFiles(arena.allocator(), &.{.{ "w.xml", mini_wayland }}, .{
        .wayland = &.{.{ .source = "t", .file = "w.xml", .interfaces = &.{"wl_thing"} }},
    }, &log.writer);
    for ([_][]const u8{
        "pub const wl_thing = struct",
        ".version = 3,",
        ".{ .name = \"make\", .since = 1, .destructor = false, .args = &.{ .{ .name = \"id\", .kind = .new_id, .interface = \"wl_other\" }, .{ .name = \"flag\", .kind = .uint } } },",
        ".{ .name = \"destroy\", .since = 2, .destructor = true, .args = &.{ } },",
        ".{ .name = \"message\", .kind = .string, .nullable = true }",
        "pub const destroy: u16 = 1;",
        "pub const @\"error\": u16 = 0;",
        "pub const @\"2d\": u64 = 16;",
        // The closure: wl_other is named by an argument of wl_thing.
        "pub const wl_other = struct",
        "&wl_other.interface,",
    }) |want| {
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing `{s}` in:\n{s}\n", .{ want, text });
            return error.TestExpectedEqual;
        }
    }
    // Only the closure is emitted.
    try testing.expect(std.mem.indexOf(u8, text, "wl_unused") == null);
    // The denied names, for the transports' compile-time check.
    try testing.expect(std.mem.indexOf(u8, text, "pub const denied = [_][]const u8{\n    \"org.gnome.Mutter.RemoteDesktop.Session.SetKeymap\",") != null);
}

test "an EI new_id takes its interface from a string argument" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var log: std.Io.Writer.Allocating = .init(arena.allocator());
    const text = try generateFromFiles(arena.allocator(), &.{.{
        "ei.xml",
        \\<protocol name="ei"><interface name="ei_device" version="3">
        \\  <event name="interface"><arg name="object" type="new_id" interface="interface_name"/><arg name="interface_name" type="string"/><arg name="version" type="uint32"/></event>
        \\  <request name="frame"><arg name="last_serial" type="uint32"/><arg name="timestamp" type="uint64"/></request>
        \\</interface></protocol>
    }}, .{ .ei = &.{.{ .source = "t", .file = "ei.xml", .interfaces = &.{"ei_device"} }} }, &log.writer);
    try testing.expect(std.mem.indexOf(u8, text, ".{ .name = \"object\", .kind = .new_id, .interface_arg = 1 }") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".{ .name = \"timestamp\", .kind = .uint64 }") != null);
}

const mini_dbus =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\  <interface name="org.example.Thing">
    \\    <method name="Open"><arg type="a{sv}" direction="in"/><arg type="h" direction="out"/></method>
    \\    <method name="SetKeymap"/>
    \\    <signal name="Closed"><arg type="s" direction="out"/><arg type="a(ii)"/></signal>
    \\    <property name="Version" type="i" access="read"/>
    \\  </interface>
    \\  <interface name="org.gnome.ScreenSaver"><method name="SetActive"><arg type="b" direction="in"/></method></interface>
    \\</node>
;

test "D-Bus members keep their signatures, and only the listed members are emitted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var log: std.Io.Writer.Allocating = .init(arena.allocator());
    const text = try generateFromFiles(arena.allocator(), &.{.{ "d.xml", mini_dbus }}, .{
        .dbus = &.{.{ .source = "t", .file = "d.xml", .interface = "org.example.Thing", .members = &.{ "Open", "Closed", "Version" } }},
    }, &log.writer);
    for ([_][]const u8{
        "pub const org_example_Thing = struct",
        "pub const Open: Method = .{ .interface = \"org.example.Thing\", .member = \"Open\", .in = \"a{sv}\", .out = \"h\" };",
        // A signal's arguments are its body whatever their direction.
        "pub const Closed: Signal = .{ .interface = \"org.example.Thing\", .member = \"Closed\", .signature = \"sa(ii)\" };",
        "pub const Version: Property = .{ .interface = \"org.example.Thing\", .name = \"Version\", .signature = \"i\", .readable = true, .writable = false };",
    }) |want| {
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing `{s}` in:\n{s}\n", .{ want, text });
            return error.TestExpectedEqual;
        }
    }
    try testing.expect(std.mem.indexOf(u8, text, "pub const SetKeymap") == null);
}

test "an invalid D-Bus signature is refused" {
    for ([_][]const u8{ "a", "(", "()", "a{vs}", "{sv}", "(ii", "z", "a{s}", "a{sii}" }) |bad| try testing.expect(validSignature(bad, false) != null);
    for ([_][]const u8{ "", "s", "a{sv}", "a(ii)", "(sa{sv})", "aay", "a{oa{sa{sv}}}", "h", "v" }) |good| try testing.expect(validSignature(good, false) == null);
    try testing.expect(validSignature("ss", true) != null);
    // 33 nested arrays.
    var deep: [34]u8 = undefined;
    @memset(deep[0..33], 'a');
    deep[33] = 'y';
    try testing.expect(validSignature(&deep, true) != null);
    try testing.expect(validSignature(deep[1..], true) == null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var log: std.Io.Writer.Allocating = .init(arena.allocator());
    try testing.expectError(error.Invalid, generateFromFiles(arena.allocator(), &.{.{
        "d.xml",
        \\<node><interface name="org.example.Bad"><method name="M"><arg type="a{vs}" direction="in"/></method></interface></node>
    }}, .{ .dbus = &.{.{ .source = "t", .file = "d.xml", .interface = "org.example.Bad", .members = &.{"M"} }} }, &log.writer));
    try testing.expect(std.mem.indexOf(u8, log.written(), "invalid D-Bus signature `a{vs}`") != null);
}

test "an entity or a DTD in a source is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var log: std.Io.Writer.Allocating = .init(arena.allocator());
    try testing.expectError(error.Invalid, generateFromFiles(arena.allocator(), &.{.{
        "d.xml",
        \\<!DOCTYPE node [<!ENTITY lol "lol">]>
        \\<node><interface name="org.example.A"/></node>
    }}, .{ .dbus = &.{.{ .source = "t", .file = "d.xml", .interface = "org.example.A", .members = &.{} }} }, &log.writer));
    try testing.expect(std.mem.indexOf(u8, log.written(), "internal DTD subset (DtdRefused)") != null);
    log.clearRetainingCapacity();
    try testing.expectError(error.Invalid, generateFromFiles(arena.allocator(), &.{.{
        "w.xml",
        \\<protocol name="p"><interface name="wl_a" version="1" summary="&lol;"/></protocol>
    }}, .{ .wayland = &.{.{ .source = "t", .file = "w.xml", .interfaces = &.{"wl_a"} }} }, &log.writer));
    try testing.expect(std.mem.indexOf(u8, log.written(), "(EntityRefused)") != null);
}

test "a name absent from its source names the closest one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var log: std.Io.Writer.Allocating = .init(arena.allocator());
    try testing.expectError(error.Invalid, generateFromFiles(arena.allocator(), &.{ .{ "w.xml", mini_wayland }, .{ "d.xml", mini_dbus } }, .{
        .wayland = &.{.{ .source = "t", .file = "w.xml", .interfaces = &.{"wl_thnig"} }},
        .dbus = &.{.{ .source = "t", .file = "d.xml", .interface = "org.example.Thing", .members = &.{"Opne"} }},
    }, &log.writer));
    try testing.expect(std.mem.indexOf(u8, log.written(), "`wl_thnig` not found in t/w.xml; closest existing name: `wl_thing`") != null);
    try testing.expect(std.mem.indexOf(u8, log.written(), "`Opne` not found in org.example.Thing (t/d.xml); closest existing name: `Open`") != null);
}

test "a denied name fails generation whatever the list says" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var log: std.Io.Writer.Allocating = .init(arena.allocator());
    const kde =
        \\<protocol name="fake_input"><interface name="org_kde_kwin_fake_input" version="6"/><interface name="wl_a" version="1">
        \\<request name="r"><arg name="i" type="object" interface="org_kde_kwin_fake_input"/></request></interface></protocol>
    ;
    const screensaver =
        \\<node><interface name="org.gnome.ScreenSaver"><method name="SetActive"><arg type="b" direction="in"/></method><method name="GetActive"><arg type="b" direction="out"/></method></interface>
        \\<interface name="org.gnome.Mutter.RemoteDesktop.Session"><method name="SetKeymap"><arg type="a{sv}" direction="in"/></method></interface></node>
    ;
    try testing.expectError(error.Invalid, generateFromFiles(arena.allocator(), &.{ .{ "k.xml", kde }, .{ "s.xml", screensaver } }, .{
        .wayland = &.{.{ .source = "t", .file = "k.xml", .interfaces = &.{"org_kde_kwin_fake_input"} }},
        .dbus = &.{
            .{ .source = "t", .file = "s.xml", .interface = "org.gnome.ScreenSaver", .members = &.{ "GetActive", "SetActive" } },
            .{ .source = "t", .file = "s.xml", .interface = "org.gnome.Mutter.RemoteDesktop.Session", .members = &.{"SetKeymap"} },
        },
    }, &log.writer));
    for (denied) |d| if (std.mem.indexOf(u8, log.written(), d.name) == null) {
        std.debug.print("{s}\n", .{log.written()});
        return error.TestExpectedEqual;
    };
    // Reaching a denied interface through the closure fails too.
    log.clearRetainingCapacity();
    try testing.expectError(error.Invalid, generateFromFiles(arena.allocator(), &.{.{ "k.xml", kde }}, .{
        .wayland = &.{.{ .source = "t", .file = "k.xml", .interfaces = &.{"wl_a"} }},
    }, &log.writer));
    try testing.expect(std.mem.indexOf(u8, log.written(), "`wl_a` reaches `org_kde_kwin_fake_input`, which is denied") != null);
}

test "two generations give the same bytes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var log: std.Io.Writer.Allocating = .init(arena.allocator());
    const list: List = .{
        .wayland = &.{.{ .source = "t", .file = "w.xml", .interfaces = &.{"wl_thing"} }},
        .dbus = &.{.{ .source = "t", .file = "d.xml", .interface = "org.example.Thing", .members = &.{ "Open", "Closed", "Version" } }},
    };
    const files = [_][2][]const u8{ .{ "w.xml", mini_wayland }, .{ "d.xml", mini_dbus } };
    const one = try generateFromFiles(arena.allocator(), &files, list, &log.writer);
    const two = try generateFromFiles(arena.allocator(), &files, list, &log.writer);
    try testing.expectEqualStrings(one, two);
}
