//! winmdgen: generates Zig bindings for an explicit list of Win32 APIs from
//! the pinned win32metadata package (Windows.Win32.winmd).
//!
//! usage: winmdgen <list.zon> <package.nupkg> <out.zig>
//!
//! The list names functions, types (structs, enums, typedefs, interfaces,
//! coclasses) and constants; a trailing `*` matches every function with that
//! prefix. Everything those APIs reference is emitted too. Interfaces whose
//! methods are not needed (referenced only by pointer) are emitted as
//! `opaque {}`; listed interfaces and their bases get full vtables.

const std = @import("std");
const md = @import("metadata.zig");
const Metadata = md.Metadata;
const Table = md.Table;
const Blob = md.Blob;

const Allocator = std.mem.Allocator;

const List = struct {
    package: []const u8,
    sha256: []const u8,
    dll_aliases: []const [2][]const u8 = &.{},
    apis: []const []const u8,
};

// Column indices.
const TD = struct {
    const flags = 0;
    const name = 1;
    const namespace = 2;
    const extends = 3;
    const fields = 4;
    const methods = 5;
};
const MD = struct {
    const impl_flags = 1;
    const flags = 2;
    const name = 3;
    const signature = 4;
    const params = 5;
};
const FD = struct {
    const flags = 0;
    const name = 1;
    const signature = 2;
};

const Kind = enum { interface, enumeration, delegate, structure, union_type, typedef, class };

const Index = struct {
    gpa: Allocator,
    m: *const Metadata,
    types: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    functions: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    constants: std.StringHashMapUnmanaged(u32) = .empty,
    enum_members: std.StringHashMapUnmanaged(u32) = .empty,
    nested_in: []u32,
    nested: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    method_owner: []u32,
    field_owner: []u32,
    attrs: std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty,
    class_layout: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    constant_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    impl_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    base_of: std.AutoHashMapUnmanaged(u32, md.Ref) = .empty,
    field_offset: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    fn key(r: md.Ref) u64 {
        return (@as(u64, @backingInt(r.table)) << 32) | r.row;
    }

    fn build(gpa: Allocator, m: *const Metadata) !Index {
        var ix: Index = .{
            .gpa = gpa,
            .m = m,
            .nested_in = try gpa.alloc(u32, m.rowCount(.TypeDef) + 1),
            .method_owner = try gpa.alloc(u32, m.rowCount(.MethodDef) + 1),
            .field_owner = try gpa.alloc(u32, m.rowCount(.Field) + 1),
        };
        @memset(ix.nested_in, 0);
        @memset(ix.method_owner, 0);
        @memset(ix.field_owner, 0);

        for (1..m.rowCount(.NestedClass) + 1) |r| {
            const row: u32 = @intCast(r);
            const inner = m.index(.NestedClass, row, 0);
            const outer = m.index(.NestedClass, row, 1);
            ix.nested_in[inner] = outer;
            const gop = try ix.nested.getOrPut(gpa, outer);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, inner);
        }
        for (1..m.rowCount(.TypeDef) + 1) |r| {
            const row: u32 = @intCast(r);
            const fstart = m.index(.TypeDef, row, TD.fields);
            const fend = m.listEnd(.TypeDef, row, TD.fields, .Field);
            for (fstart..fend) |f| ix.field_owner[f] = row;
            const mstart = m.index(.TypeDef, row, TD.methods);
            const mend = m.listEnd(.TypeDef, row, TD.methods, .MethodDef);
            for (mstart..mend) |x| ix.method_owner[x] = row;
        }
        for (1..m.rowCount(.CustomAttribute) + 1) |r| {
            const row: u32 = @intCast(r);
            const parent = m.coded(.CustomAttribute, row, 0) orelse continue;
            const gop = try ix.attrs.getOrPut(gpa, key(parent));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, row);
        }
        for (1..m.rowCount(.ClassLayout) + 1) |r| {
            const row: u32 = @intCast(r);
            try ix.class_layout.put(gpa, m.index(.ClassLayout, row, 2), row);
        }
        for (1..m.rowCount(.Constant) + 1) |r| {
            const row: u32 = @intCast(r);
            const parent = m.coded(.Constant, row, 1) orelse continue;
            if (parent.table == .Field) try ix.constant_of.put(gpa, parent.row, row);
        }
        for (1..m.rowCount(.ImplMap) + 1) |r| {
            const row: u32 = @intCast(r);
            const fwd = m.coded(.ImplMap, row, 1) orelse continue;
            if (fwd.table == .MethodDef) try ix.impl_map.put(gpa, fwd.row, row);
        }
        for (1..m.rowCount(.InterfaceImpl) + 1) |r| {
            const row: u32 = @intCast(r);
            const cls = m.index(.InterfaceImpl, row, 0);
            const iface = m.coded(.InterfaceImpl, row, 1) orelse continue;
            if (!ix.base_of.contains(cls)) try ix.base_of.put(gpa, cls, iface);
        }
        for (1..m.rowCount(.FieldLayout) + 1) |r| {
            const row: u32 = @intCast(r);
            try ix.field_offset.put(gpa, m.index(.FieldLayout, row, 1), m.int(.FieldLayout, row, 0));
        }

        for (1..m.rowCount(.TypeDef) + 1) |r| {
            const row: u32 = @intCast(r);
            if (ix.nested_in[row] != 0) continue;
            const name = m.string(.TypeDef, row, TD.name);
            const ns = m.string(.TypeDef, row, TD.namespace);
            if (ns.len == 0) continue; // <Module>
            if (std.mem.eql(u8, name, "Apis")) {
                try ix.indexApis(row);
                continue;
            }
            try appendTo(gpa, &ix.types, name, row);
            if (ix.kindOf(row) == .enumeration) {
                const fstart = m.index(.TypeDef, row, TD.fields);
                const fend = m.listEnd(.TypeDef, row, TD.fields, .Field);
                for (fstart..fend) |f| {
                    const fname = m.string(.Field, @intCast(f), FD.name);
                    if (std.mem.eql(u8, fname, "value__")) continue;
                    try ix.enum_members.put(gpa, fname, row);
                }
            }
        }
        return ix;
    }

    fn appendTo(gpa: Allocator, map: *std.StringHashMapUnmanaged(std.ArrayList(u32)), name: []const u8, row: u32) !void {
        const gop = try map.getOrPut(gpa, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, row);
    }

    fn indexApis(ix: *Index, row: u32) !void {
        const m = ix.m;
        const mstart = m.index(.TypeDef, row, TD.methods);
        const mend = m.listEnd(.TypeDef, row, TD.methods, .MethodDef);
        for (mstart..mend) |x| try appendTo(ix.gpa, &ix.functions, m.string(.MethodDef, @intCast(x), MD.name), @intCast(x));
        const fstart = m.index(.TypeDef, row, TD.fields);
        const fend = m.listEnd(.TypeDef, row, TD.fields, .Field);
        for (fstart..fend) |f| try ix.constants.put(ix.gpa, m.string(.Field, @intCast(f), FD.name), @intCast(f));
    }

    /// Full name of a custom attribute's type, e.g. "GuidAttribute".
    fn attrName(ix: *const Index, ca: u32) []const u8 {
        const m = ix.m;
        const ctor = m.coded(.CustomAttribute, ca, 1) orelse return "";
        switch (ctor.table) {
            .MemberRef => {
                const parent = m.coded(.MemberRef, ctor.row, 0) orelse return "";
                return switch (parent.table) {
                    .TypeRef => m.string(.TypeRef, parent.row, 1),
                    .TypeDef => m.string(.TypeDef, parent.row, TD.name),
                    else => "",
                };
            },
            .MethodDef => return m.string(.TypeDef, ix.method_owner[ctor.row], TD.name),
            else => return "",
        }
    }

    fn findAttr(ix: *const Index, owner: md.Ref, name: []const u8) ?u32 {
        const list = ix.attrs.get(key(owner)) orelse return null;
        for (list.items) |ca| if (std.mem.eql(u8, ix.attrName(ca), name)) return ca;
        return null;
    }

    fn hasAttr(ix: *const Index, owner: md.Ref, name: []const u8) bool {
        return ix.findAttr(owner, name) != null;
    }

    fn guidOf(ix: *const Index, owner: md.Ref) ?[16]u8 {
        const ca = ix.findAttr(owner, "GuidAttribute") orelse return null;
        const v = ix.m.blob(.CustomAttribute, ca, 2);
        if (v.len < 2 + 16) return null;
        return v[2..18].*;
    }

    /// True when the type or function is usable on x64 (no
    /// SupportedArchitecture attribute, or one that includes X64).
    fn supportsX64(ix: *const Index, owner: md.Ref) bool {
        const ca = ix.findAttr(owner, "SupportedArchitectureAttribute") orelse return true;
        const v = ix.m.blob(.CustomAttribute, ca, 2);
        if (v.len < 6) return true;
        const arch = std.mem.readInt(i32, v[2..6], .little);
        return arch & 2 != 0;
    }

    fn pick(ix: *const Index, rows: []const u32, table: Table) ?u32 {
        for (rows) |r| if (ix.supportsX64(.{ .table = table, .row = r })) return r;
        return null;
    }

    fn extendsName(ix: *const Index, row: u32) []const u8 {
        const m = ix.m;
        const ext = m.coded(.TypeDef, row, TD.extends) orelse return "";
        return switch (ext.table) {
            .TypeRef => m.string(.TypeRef, ext.row, 1),
            .TypeDef => m.string(.TypeDef, ext.row, TD.name),
            else => "",
        };
    }

    fn kindOf(ix: *const Index, row: u32) Kind {
        const m = ix.m;
        const flags = m.int(.TypeDef, row, TD.flags);
        if (flags & 0x20 != 0) return .interface;
        const ext = ix.extendsName(row);
        if (std.mem.eql(u8, ext, "Enum")) return .enumeration;
        if (std.mem.eql(u8, ext, "MulticastDelegate")) return .delegate;
        if (std.mem.eql(u8, ext, "ValueType")) {
            if (ix.hasAttr(.{ .table = .TypeDef, .row = row }, "NativeTypedefAttribute")) return .typedef;
            // Coclasses are field-less value types carrying the CLSID.
            const no_fields = m.index(.TypeDef, row, TD.fields) == m.listEnd(.TypeDef, row, TD.fields, .Field);
            if (no_fields and ix.hasAttr(.{ .table = .TypeDef, .row = row }, "GuidAttribute")) return .class;
            if (flags & 0x18 == 0x10) return .union_type;
            return .structure;
        }
        return .class;
    }

    fn typeName(ix: *const Index, row: u32) []const u8 {
        return ix.m.string(.TypeDef, row, TD.name);
    }

    /// Resolves a TypeRef to a TypeDef row in this file, or null for
    /// System types.
    fn resolveTypeRef(ix: *const Index, row: u32) ?u32 {
        const m = ix.m;
        const name = m.string(.TypeRef, row, 1);
        const ns = m.string(.TypeRef, row, 2);
        if (m.coded(.TypeRef, row, 0)) |scope| if (scope.table == .TypeRef) {
            const outer = ix.resolveTypeRef(scope.row) orelse return null;
            const inner = ix.nested.get(outer) orelse return null;
            for (inner.items) |n| if (std.mem.eql(u8, ix.typeName(n), name)) return n;
            return null;
        };
        if (std.mem.startsWith(u8, ns, "System")) return null;
        const rows = ix.types.get(name) orelse return null;
        for (rows.items) |r| {
            if (std.mem.eql(u8, m.string(.TypeDef, r, TD.namespace), ns) and ix.supportsX64(.{ .table = .TypeDef, .row = r })) return r;
        }
        return null;
    }
};

// ---------------------------------------------------------------- type model

const Prim = enum { void, bool, char, i8, u8, i16, u16, i32, u32, i64, u64, f32, f64, isize, usize };

const Ty = union(enum) {
    prim: Prim,
    named: u32,
    guid,
    ptr: *const Ty,
    array: struct { elem: *const Ty, len: u32 },
    system: []const u8,
};

const Decoder = struct {
    ix: *const Index,
    arena: Allocator,

    fn ty(d: Decoder, b: *Blob) anyerror!Ty {
        while (true) {
            const e = try b.byte();
            switch (e) {
                0x1f, 0x20 => {
                    _ = try b.typeRef();
                    continue;
                },
                0x01 => return .{ .prim = .void },
                0x02 => return .{ .prim = .bool },
                0x03 => return .{ .prim = .char },
                0x04 => return .{ .prim = .i8 },
                0x05 => return .{ .prim = .u8 },
                0x06 => return .{ .prim = .i16 },
                0x07 => return .{ .prim = .u16 },
                0x08 => return .{ .prim = .i32 },
                0x09 => return .{ .prim = .u32 },
                0x0a => return .{ .prim = .i64 },
                0x0b => return .{ .prim = .u64 },
                0x0c => return .{ .prim = .f32 },
                0x0d => return .{ .prim = .f64 },
                0x18 => return .{ .prim = .isize },
                0x19 => return .{ .prim = .usize },
                0x0e => return .{ .system = "String" },
                0x1c => return .{ .system = "Object" },
                0x0f, 0x10 => {
                    const inner = try d.arena.create(Ty);
                    inner.* = try d.ty(b);
                    return .{ .ptr = inner };
                },
                0x11, 0x12 => {
                    const r = try b.typeRef();
                    return d.named(r);
                },
                0x14 => {
                    const elem = try d.arena.create(Ty);
                    elem.* = try d.ty(b);
                    const rank = try b.compressed();
                    const nsizes = try b.compressed();
                    var len: u32 = 1;
                    for (0..nsizes) |_| len *= try b.compressed();
                    const nlo = try b.compressed();
                    for (0..nlo) |_| _ = try b.compressed();
                    if (rank != 1) return error.UnsupportedArray;
                    return .{ .array = .{ .elem = elem, .len = len } };
                },
                0x1d => {
                    const elem = try d.arena.create(Ty);
                    elem.* = try d.ty(b);
                    return .{ .ptr = elem };
                },
                else => return error.UnsupportedSignature,
            }
        }
    }

    fn named(d: Decoder, r: md.Ref) Ty {
        const m = d.ix.m;
        switch (r.table) {
            .TypeDef => return .{ .named = r.row },
            .TypeRef => {
                if (d.ix.resolveTypeRef(r.row)) |row| return .{ .named = row };
                const name = m.string(.TypeRef, r.row, 1);
                if (std.mem.eql(u8, name, "Guid")) return .guid;
                return .{ .system = name };
            },
            else => return .{ .system = "TypeSpec" },
        }
    }
};

const Sig = struct { ret: Ty, params: []Ty };

fn methodSig(d: Decoder, row: u32) !Sig {
    var b: Blob = .{ .data = d.ix.m.blob(.MethodDef, row, MD.signature) };
    const conv = try b.byte();
    if (conv & 0x10 != 0) _ = try b.compressed(); // generic count
    const n = try b.compressed();
    const ret = try d.ty(&b);
    const params = try d.arena.alloc(Ty, n);
    for (params) |*p| p.* = try d.ty(&b);
    return .{ .ret = ret, .params = params };
}

fn fieldType(d: Decoder, row: u32) !Ty {
    var b: Blob = .{ .data = d.ix.m.blob(.Field, row, FD.signature) };
    if (try b.byte() != 0x06) return error.BadFieldSignature;
    return d.ty(&b);
}

// ---------------------------------------------------------------- generator

const Gen = struct {
    gpa: Allocator,
    arena: Allocator,
    ix: *const Index,
    dec: Decoder,
    aliases: []const [2][]const u8,
    /// Top-level types to emit, and whether each interface is full.
    types: std.AutoArrayHashMapUnmanaged(u32, bool) = .empty,
    full: std.AutoHashMapUnmanaged(u32, void) = .empty,
    functions: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    constants: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    clsids: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    queue: std.ArrayList(u32) = .empty,
    names: std.StringHashMapUnmanaged(void) = .empty,
    errors: usize = 0,

    fn outermost(g: *const Gen, row: u32) u32 {
        var r = row;
        while (g.ix.nested_in[r] != 0) r = g.ix.nested_in[r];
        return r;
    }

    fn markFull(g: *Gen, row: u32) !void {
        var r: ?u32 = row;
        while (r) |cur| {
            try g.full.put(g.gpa, cur, {});
            const base = g.ix.base_of.get(cur) orelse break;
            r = switch (base.table) {
                .TypeDef => base.row,
                .TypeRef => g.ix.resolveTypeRef(base.row),
                else => null,
            };
        }
    }

    fn need(g: *Gen, row: u32) !void {
        const top = g.outermost(row);
        const gop = try g.types.getOrPut(g.gpa, top);
        if (!gop.found_existing) {
            gop.value_ptr.* = false;
            try g.queue.append(g.gpa, top);
        }
    }

    fn needTy(g: *Gen, t: Ty) anyerror!void {
        switch (t) {
            .named => |row| try g.need(row),
            .ptr => |p| try g.needTy(p.*),
            .array => |a| try g.needTy(a.elem.*),
            else => {},
        }
    }

    fn needSig(g: *Gen, s: Sig) !void {
        try g.needTy(s.ret);
        for (s.params) |p| try g.needTy(p);
    }

    /// Walks a type's own references (fields, methods, bases, nested types).
    fn walk(g: *Gen, row: u32) !void {
        const ix = g.ix;
        const m = ix.m;
        switch (ix.kindOf(row)) {
            .interface => {
                if (!g.full.contains(row)) return;
                if (ix.base_of.get(row)) |base| try g.needTy(g.dec.named(base));
                const s = m.index(.TypeDef, row, TD.methods);
                for (s..m.listEnd(.TypeDef, row, TD.methods, .MethodDef)) |x| try g.needSig(try methodSig(g.dec, @intCast(x)));
            },
            .delegate => {
                const s = m.index(.TypeDef, row, TD.methods);
                for (s..m.listEnd(.TypeDef, row, TD.methods, .MethodDef)) |x| {
                    if (std.mem.eql(u8, m.string(.MethodDef, @intCast(x), MD.name), "Invoke")) try g.needSig(try methodSig(g.dec, @intCast(x)));
                }
            },
            .structure, .union_type, .typedef, .enumeration => {
                const s = m.index(.TypeDef, row, TD.fields);
                for (s..m.listEnd(.TypeDef, row, TD.fields, .Field)) |f| {
                    const flags = m.int(.Field, @intCast(f), FD.flags);
                    if (flags & 0x10 != 0) continue; // static
                    try g.needTy(try fieldType(g.dec, @intCast(f)));
                }
                if (ix.nested.get(row)) |inner| for (inner.items) |n| try g.walk(n);
            },
            .class => {},
        }
    }

    fn closure(g: *Gen) !void {
        var i: usize = 0;
        while (i < g.queue.items.len) : (i += 1) try g.walk(g.queue.items[i]);
    }

    fn request(g: *Gen, name: []const u8, all_names: []const []const u8) !void {
        const ix = g.ix;
        if (std.mem.endsWith(u8, name, "*")) {
            const prefix = name[0 .. name.len - 1];
            var found = false;
            var it = ix.functions.iterator();
            while (it.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, prefix)) {
                if (ix.pick(e.value_ptr.items, .MethodDef)) |row| {
                    try g.functions.put(g.gpa, row, {});
                    found = true;
                }
            };
            if (!found) g.missing(name, all_names);
            return;
        }
        if (ix.functions.get(name)) |rows| {
            const row = ix.pick(rows.items, .MethodDef) orelse return g.missing(name, all_names);
            try g.functions.put(g.gpa, row, {});
            return;
        }
        if (ix.types.get(name)) |rows| {
            const row = ix.pick(rows.items, .TypeDef) orelse return g.missing(name, all_names);
            if (ix.kindOf(row) == .class) {
                try g.clsids.put(g.gpa, row, {});
                return;
            }
            if (ix.kindOf(row) == .interface) try g.markFull(row);
            try g.need(row);
            return;
        }
        if (ix.constants.get(name)) |row| {
            try g.constants.put(g.gpa, row, {});
            return;
        }
        if (ix.enum_members.get(name)) |row| {
            try g.need(row);
            return;
        }
        g.missing(name, all_names);
    }

    fn missing(g: *Gen, name: []const u8, all_names: []const []const u8) void {
        g.errors += 1;
        var best: []const u8 = "";
        var best_d: usize = std.math.maxInt(usize);
        var buf: [2][128]usize = undefined;
        for (all_names) |n| {
            if (n.len > 120 or name.len > 120) continue;
            const diff = if (n.len > name.len) n.len - name.len else name.len - n.len;
            if (diff >= best_d) continue;
            const d = levenshtein(name, n, &buf);
            if (d < best_d) {
                best_d = d;
                best = n;
            }
        }
        std.debug.print("winmdgen: `{s}` not found in Windows.Win32.winmd; closest existing name: `{s}`\n", .{ name, best });
    }
};

fn levenshtein(a: []const u8, b: []const u8, buf: *[2][128]usize) usize {
    var prev = buf[0][0 .. b.len + 1];
    var cur = buf[1][0 .. b.len + 1];
    for (prev, 0..) |*p, j| p.* = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
        }
        std.mem.swap([]usize, &prev, &cur);
    }
    return prev[b.len];
}

// ---------------------------------------------------------------- emission

const keywords = std.StaticStringMap(void).initComptime(.{
    .{"addrspace"},   .{"align"},     .{"allowzero"}, .{"and"},         .{"anyframe"}, .{"anytype"},
    .{"asm"},         .{"break"},     .{"callconv"},  .{"catch"},       .{"comptime"}, .{"const"},
    .{"continue"},    .{"defer"},     .{"else"},      .{"enum"},        .{"errdefer"}, .{"error"},
    .{"export"},      .{"extern"},    .{"fn"},        .{"for"},         .{"if"},       .{"inline"},
    .{"linksection"}, .{"noalias"},   .{"noinline"},  .{"nosuspend"},   .{"opaque"},   .{"or"},
    .{"orelse"},      .{"packed"},    .{"pub"},       .{"resume"},      .{"return"},   .{"struct"},
    .{"suspend"},     .{"switch"},    .{"test"},      .{"threadlocal"}, .{"try"},      .{"union"},
    .{"unreachable"}, .{"var"},       .{"volatile"},  .{"while"},       .{"type"},     .{"bool"},
    .{"void"},        .{"anyopaque"}, .{"anyerror"},  .{"noreturn"},    .{"null"},     .{"true"},
    .{"false"},       .{"undefined"}, .{"isize"},     .{"usize"},       .{"self"},     .{"vtable"},
});

fn isPrimitiveName(s: []const u8) bool {
    if (s.len < 2) return false;
    if ((s[0] == 'i' or s[0] == 'u' or s[0] == 'f') and std.ascii.isDigit(s[1])) {
        for (s[1..]) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    return std.mem.startsWith(u8, s, "c_");
}

const Emitter = struct {
    g: *Gen,
    w: *std.Io.Writer,

    fn ident(e: Emitter, s: []const u8) !void {
        if (keywords.has(s) or isPrimitiveName(s)) return e.w.print("@\"{s}\"", .{s});
        try e.w.writeAll(s);
    }

    /// Parameter names must not shadow top-level declarations.
    fn paramName(e: Emitter, s: []const u8) !void {
        if (s.len == 0) return e.w.writeAll("p");
        if (e.g.names.contains(s)) return e.w.print("{s}_", .{s});
        try e.ident(s);
    }

    fn qualified(e: Emitter, row: u32) !void {
        const ix = e.g.ix;
        if (ix.nested_in[row] != 0) {
            try e.qualified(ix.nested_in[row]);
            try e.w.writeByte('.');
        }
        try e.ident(ix.typeName(row));
    }

    const Pos = struct { is_const: bool = false, many: bool = false };

    fn ty(e: Emitter, t: Ty, pos: Pos) anyerror!void {
        const w = e.w;
        const ix = e.g.ix;
        switch (t) {
            .prim => |p| try w.writeAll(switch (p) {
                .void => "void",
                .bool => "u8",
                .char => "u16",
                inline else => |x| @tagName(x),
            }),
            .guid => try w.writeAll("GUID"),
            .system => |s| {
                if (std.mem.eql(u8, s, "IntPtr")) try w.writeAll("isize") else if (std.mem.eql(u8, s, "UIntPtr")) try w.writeAll("usize") else try w.writeAll("*anyopaque");
            },
            .named => |row| switch (ix.kindOf(row)) {
                // COM objects and delegates are reference types in the metadata.
                .interface => {
                    try w.writeAll("?*");
                    try e.qualified(row);
                },
                .typedef => {
                    // A [Const] PWSTR/PSTR parameter is a const string.
                    if (pos.is_const) if (e.stringTypedef(row)) |unit| {
                        try w.print("?[*:0]const {s}", .{unit});
                        return;
                    };
                    try e.qualified(row);
                },
                else => try e.qualified(row),
            },
            .ptr => |inner| {
                if (inner.* == .prim and inner.prim == .void) {
                    try w.writeAll(if (pos.is_const) "?*const anyopaque" else "?*anyopaque");
                    return;
                }
                try w.writeAll(if (pos.many) "?[*]" else "?*");
                if (pos.is_const) try w.writeAll("const ");
                try e.ty(inner.*, .{});
            },
            .array => |a| {
                try w.print("[{d}]", .{a.len});
                try e.ty(a.elem.*, .{});
            },
        }
    }

    fn paramPos(e: Emitter, method: u32, seq: usize) Pos {
        const ix = e.g.ix;
        const m = ix.m;
        const start = m.index(.MethodDef, method, MD.params);
        const end = m.listEnd(.MethodDef, method, MD.params, .Param);
        for (start..end) |p| {
            const prow: u32 = @intCast(p);
            if (m.int(.Param, prow, 1) != seq) continue;
            const ref: md.Ref = .{ .table = .Param, .row = prow };
            return .{ .is_const = ix.hasAttr(ref, "ConstAttribute"), .many = ix.hasAttr(ref, "NativeArrayInfoAttribute") };
        }
        return .{};
    }

    fn paramNameOf(e: Emitter, method: u32, seq: usize) []const u8 {
        const m = e.g.ix.m;
        const start = m.index(.MethodDef, method, MD.params);
        const end = m.listEnd(.MethodDef, method, MD.params, .Param);
        for (start..end) |p| if (m.int(.Param, @intCast(p), 1) == seq) return m.string(.Param, @intCast(p), 2);
        return "";
    }

    fn fnType(e: Emitter, method: u32, self_type: ?u32) !void {
        const w = e.w;
        const s = try methodSig(e.g.dec, method);
        try w.writeAll("fn (");
        var first = true;
        if (self_type) |st| {
            try w.writeAll("self: *");
            try e.qualified(st);
            first = false;
        }
        for (s.params, 1..) |p, seq| {
            if (!first) try w.writeAll(", ");
            first = false;
            const pname = e.paramNameOf(method, seq);
            if (std.mem.eql(u8, pname, "self")) try w.writeAll("self_") else try e.paramName(pname);
            try w.writeAll(": ");
            try e.ty(p, e.paramPos(method, seq));
        }
        try w.writeAll(") callconv(.winapi) ");
        try e.ty(s.ret, .{});
    }

    fn guid(e: Emitter, g: [16]u8) !void {
        try e.w.print(".{{ .Data1 = 0x{x:0>8}, .Data2 = 0x{x:0>4}, .Data3 = 0x{x:0>4}, .Data4 = .{{ ", .{
            std.mem.readInt(u32, g[0..4], .little),
            std.mem.readInt(u16, g[4..6], .little),
            std.mem.readInt(u16, g[6..8], .little),
        });
        for (g[8..16], 0..) |b, i| try e.w.print("{s}0x{x:0>2}", .{ if (i == 0) "" else ", ", b });
        try e.w.writeAll(" } }");
    }

    fn fields(e: Emitter, row: u32, depth: usize) anyerror!void {
        const ix = e.g.ix;
        const m = ix.m;
        const w = e.w;
        const pack: u16 = if (ix.class_layout.get(row)) |cl| @intCast(m.int(.ClassLayout, cl, 0)) else 0;
        if (ix.nested.get(row)) |inner| for (inner.items) |n| {
            try w.splatByteAll(' ', depth * 4);
            try w.writeAll("pub const ");
            try e.ident(ix.typeName(n));
            try w.writeAll(" = ");
            try e.container(n, depth);
            try w.writeAll(";\n");
        };
        const s = m.index(.TypeDef, row, TD.fields);
        for (s..m.listEnd(.TypeDef, row, TD.fields, .Field)) |f| {
            const frow: u32 = @intCast(f);
            if (m.int(.Field, frow, FD.flags) & 0x10 != 0) continue;
            try w.splatByteAll(' ', depth * 4);
            try e.ident(m.string(.Field, frow, FD.name));
            try w.writeAll(": ");
            const t = try fieldType(e.g.dec, frow);
            const pos: Pos = .{ .is_const = ix.hasAttr(.{ .table = .Field, .row = frow }, "ConstAttribute") };
            try e.ty(t, pos);
            if (pack != 0 and pack < 8) {
                try w.print(" align(@min({d}, @alignOf(", .{pack});
                try e.ty(t, pos);
                try w.writeAll(")))");
            }
            try w.writeAll(",\n");
        }
    }

    fn container(e: Emitter, row: u32, depth: usize) anyerror!void {
        const w = e.w;
        try w.writeAll(if (e.g.ix.kindOf(row) == .union_type) "extern union {\n" else "extern struct {\n");
        try e.fields(row, depth + 1);
        try w.splatByteAll(' ', depth * 4);
        try w.writeAll("}");
    }

    fn constValue(e: Emitter, crow: u32) !void {
        const m = e.g.ix.m;
        const t = m.int(.Constant, crow, 0) & 0xff;
        const v = m.blob(.Constant, crow, 2);
        const w = e.w;
        switch (t) {
            0x02, 0x05 => try w.print("{d}", .{v[0]}),
            0x04 => try w.print("{d}", .{@as(i8, @bitCast(v[0]))}),
            0x03, 0x07 => try w.print("{d}", .{std.mem.readInt(u16, v[0..2], .little)}),
            0x06 => try w.print("{d}", .{std.mem.readInt(i16, v[0..2], .little)}),
            0x08 => try w.print("{d}", .{std.mem.readInt(i32, v[0..4], .little)}),
            0x09 => try w.print("{d}", .{std.mem.readInt(u32, v[0..4], .little)}),
            0x0a => try w.print("{d}", .{std.mem.readInt(i64, v[0..8], .little)}),
            0x0b => try w.print("{d}", .{std.mem.readInt(u64, v[0..8], .little)}),
            0x0c => try w.print("{d}", .{@as(f32, @bitCast(std.mem.readInt(u32, v[0..4], .little)))}),
            0x0d => try w.print("{d}", .{@as(f64, @bitCast(std.mem.readInt(u64, v[0..8], .little)))}),
            else => return error.UnsupportedConstant,
        }
    }

    fn isPointerTypedef(e: Emitter, row: u32) bool {
        const t = e.typedefTarget(row) catch return false;
        return t == .ptr or (t == .prim and (t.prim == .isize or t.prim == .usize) and std.mem.startsWith(u8, e.g.ix.typeName(row), "H"));
    }

    fn typedefTarget(e: Emitter, row: u32) !Ty {
        const m = e.g.ix.m;
        const s = m.index(.TypeDef, row, TD.fields);
        return fieldType(e.g.dec, s);
    }

    /// Code unit of a NUL-terminated string typedef (PWSTR, BSTR, PSTR...).
    fn stringTypedef(e: Emitter, row: u32) ?[]const u8 {
        const t = e.typedefTarget(row) catch return null;
        if (t != .ptr or t.ptr.* != .prim) return null;
        return switch (t.ptr.prim) {
            .char => "u16",
            .u8 => "u8",
            else => null,
        };
    }

    fn typedef(e: Emitter, row: u32) !void {
        const w = e.w;
        const t = try e.typedefTarget(row);
        const name = e.g.ix.typeName(row);
        if (e.stringTypedef(row)) |unit| {
            const const_ = std.mem.startsWith(u8, name, "PC");
            try w.print("?[*:0]{s}{s}", .{ if (const_) "const " else "", unit });
        } else if (e.isPointerTypedef(row)) {
            try w.writeAll("?*anyopaque");
        } else try e.ty(t, .{});
    }

    fn enumUnderlying(e: Emitter, row: u32) !Ty {
        const m = e.g.ix.m;
        const s = m.index(.TypeDef, row, TD.fields);
        for (s..m.listEnd(.TypeDef, row, TD.fields, .Field)) |f| {
            if (std.mem.eql(u8, m.string(.Field, @intCast(f), FD.name), "value__")) return fieldType(e.g.dec, @intCast(f));
        }
        return .{ .prim = .i32 };
    }

    fn topType(e: Emitter, row: u32, full: bool) !void {
        const ix = e.g.ix;
        const m = ix.m;
        const w = e.w;
        const name = ix.typeName(row);
        switch (ix.kindOf(row)) {
            .interface => {
                try w.writeAll("pub const ");
                try e.ident(name);
                if (!full) {
                    try w.writeAll(" = opaque {");
                    if (ix.guidOf(.{ .table = .TypeDef, .row = row })) |g| {
                        try w.writeAll("\n    pub const iid: GUID = ");
                        try e.guid(g);
                        try w.writeAll(";\n");
                    }
                    try w.writeAll("};\n");
                    return;
                }
                try w.writeAll(" = extern struct {\n");
                if (ix.guidOf(.{ .table = .TypeDef, .row = row })) |g| {
                    try w.writeAll("    pub const iid: GUID = ");
                    try e.guid(g);
                    try w.writeAll(";\n");
                }
                try w.writeAll("    vtable: *const VTable,\n    pub const VTable = extern struct {\n");
                var chain: std.ArrayList(u32) = .empty;
                var cur: ?u32 = row;
                while (cur) |c| {
                    try chain.append(e.g.arena, c);
                    const base = ix.base_of.get(c) orelse break;
                    cur = switch (base.table) {
                        .TypeDef => base.row,
                        .TypeRef => ix.resolveTypeRef(base.row),
                        else => null,
                    };
                }
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                var i = chain.items.len;
                while (i > 0) {
                    i -= 1;
                    const iface = chain.items[i];
                    try w.print("        // {s}\n", .{ix.typeName(iface)});
                    const s = m.index(.TypeDef, iface, TD.methods);
                    for (s..m.listEnd(.TypeDef, iface, TD.methods, .MethodDef)) |x| {
                        const mrow: u32 = @intCast(x);
                        var mname = m.string(.MethodDef, mrow, MD.name);
                        if (seen.contains(mname)) mname = try std.fmt.allocPrint(e.g.arena, "{s}_{d}", .{ mname, mrow });
                        try seen.put(e.g.arena, mname, {});
                        try w.writeAll("        ");
                        try e.ident(mname);
                        try w.writeAll(": *const ");
                        try e.fnType(mrow, row);
                        try w.writeAll(",\n");
                    }
                }
                try w.writeAll("    };\n};\n");
            },
            .enumeration => {
                try w.writeAll("pub const ");
                try e.ident(name);
                try w.writeAll(" = ");
                try e.ty(try e.enumUnderlying(row), .{});
                try w.writeAll(";\n");
                const s = m.index(.TypeDef, row, TD.fields);
                for (s..m.listEnd(.TypeDef, row, TD.fields, .Field)) |f| {
                    const frow: u32 = @intCast(f);
                    const fname = m.string(.Field, frow, FD.name);
                    if (std.mem.eql(u8, fname, "value__")) continue;
                    const c = ix.constant_of.get(frow) orelse continue;
                    try w.writeAll("pub const ");
                    try e.ident(fname);
                    try w.writeAll(": ");
                    try e.ident(name);
                    try w.writeAll(" = ");
                    try e.constValue(c);
                    try w.writeAll(";\n");
                }
            },
            .delegate => {
                try w.writeAll("pub const ");
                try e.ident(name);
                try w.writeAll(" = ?*const ");
                const s = m.index(.TypeDef, row, TD.methods);
                for (s..m.listEnd(.TypeDef, row, TD.methods, .MethodDef)) |x| {
                    if (std.mem.eql(u8, m.string(.MethodDef, @intCast(x), MD.name), "Invoke")) try e.fnType(@intCast(x), null);
                }
                try w.writeAll(";\n");
            },
            .typedef => {
                try w.writeAll("pub const ");
                try e.ident(name);
                try w.writeAll(" = ");
                try e.typedef(row);
                try w.writeAll(";\n");
            },
            .structure, .union_type => {
                try w.writeAll("pub const ");
                try e.ident(name);
                try w.writeAll(" = ");
                try e.container(row, 0);
                try w.writeAll(";\n");
            },
            .class => {},
        }
    }

    fn function(e: Emitter, row: u32, aliases: []const [2][]const u8) !void {
        const ix = e.g.ix;
        const m = ix.m;
        const w = e.w;
        const im = ix.impl_map.get(row) orelse return error.NoImplMap;
        const scope = m.index(.ImplMap, im, 3);
        var dll = m.string(.ModuleRef, scope, 0);
        if (std.ascii.endsWithIgnoreCase(dll, ".dll")) dll = dll[0 .. dll.len - 4];
        const lower = try std.ascii.allocLowerString(e.g.arena, dll);
        var lib: []const u8 = lower;
        for (aliases) |a| if (std.mem.eql(u8, a[0], lower)) {
            lib = a[1];
        };
        try w.print("pub extern \"{s}\" ", .{lib});
        const s = try methodSig(e.g.dec, row);
        try w.writeAll("fn ");
        try e.ident(m.string(.MethodDef, row, MD.name));
        try w.writeAll("(");
        for (s.params, 1..) |p, seq| {
            if (seq > 1) try w.writeAll(", ");
            try e.paramName(e.paramNameOf(row, seq));
            try w.writeAll(": ");
            try e.ty(p, e.paramPos(row, seq));
        }
        try w.writeAll(") callconv(.winapi) ");
        try e.ty(s.ret, .{});
        try w.writeAll(";\n");
    }

    fn constant(e: Emitter, row: u32) !void {
        const ix = e.g.ix;
        const m = ix.m;
        const w = e.w;
        const name = m.string(.Field, row, FD.name);
        const t = try fieldType(e.g.dec, row);
        if (t == .guid) {
            const g = ix.guidOf(.{ .table = .Field, .row = row }) orelse return error.UnsupportedConstant;
            try w.writeAll("pub const ");
            try e.ident(name);
            try w.writeAll(": GUID = ");
            try e.guid(g);
            try w.writeAll(";\n");
            return;
        }
        // Property keys (PKEY_*, DEVPKEY_*) are a ConstantAttribute string
        // holding a C initializer: `{Data1, Data2, Data3, b0, ..., b7}, pid`.
        if (t == .named and isPropertyKey(ix.typeName(t.named))) if (ix.findAttr(.{ .table = .Field, .row = row }, "ConstantAttribute")) |ca| {
            const v = m.blob(.CustomAttribute, ca, 2);
            var b: Blob = .{ .data = v };
            _ = try b.byte(); // prolog 0x0001
            _ = try b.byte();
            const len = try b.compressed();
            if (b.data.len < b.pos + len) return error.UnsupportedConstant;
            const text = b.data[b.pos..][0..len];
            var nums: [12]u64 = undefined;
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, text, "{}, ");
            while (it.next()) |tok| : (n += 1) {
                if (n == nums.len) return error.UnsupportedConstant;
                nums[n] = std.fmt.parseInt(u64, tok, 0) catch return error.UnsupportedConstant;
            }
            if (n != nums.len) return error.UnsupportedConstant;
            var g: [16]u8 = undefined;
            std.mem.writeInt(u32, g[0..4], @intCast(nums[0]), .little);
            std.mem.writeInt(u16, g[4..6], @intCast(nums[1]), .little);
            std.mem.writeInt(u16, g[6..8], @intCast(nums[2]), .little);
            for (g[8..16], nums[3..11]) |*d, x| d.* = @intCast(x);
            try w.writeAll("pub const ");
            try e.ident(name);
            try w.writeAll(": ");
            try e.ty(t, .{});
            try w.writeAll(" = .{ .fmtid = ");
            try e.guid(g);
            try w.print(", .pid = {d} }};\n", .{nums[11]});
            return;
        };
        const c = ix.constant_of.get(row) orelse {
            std.debug.print("winmdgen: constant `{s}` has no literal value (attribute-encoded constants are not supported)\n", .{name});
            return error.UnsupportedConstant;
        };
        try w.writeAll("pub const ");
        try e.ident(name);
        try w.writeAll(": ");
        try e.ty(t, .{});
        try w.writeAll(" = ");
        if (t == .named and ix.kindOf(t.named) == .typedef and e.isPointerTypedef(t.named)) {
            try w.writeAll("@ptrFromInt(@as(usize, @bitCast(@as(isize, ");
            try e.constValue(c);
            try w.writeAll("))))");
        } else try e.constValue(c);
        try w.writeAll(";\n");
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 4) {
        std.debug.print("usage: winmdgen <list.zon> <package.nupkg> <out.zig>\n", .{});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();

    const list_src = try cwd.readFileAllocOptions(io, args[1], gpa, .limited(1 << 20), .of(u8), 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const list = std.zon.parse.fromSlice(List, .{ .gpa = gpa, .arena = gpa, .source = list_src, .diagnostics = &diag }) catch {
        diag.log(args[1]);
        return 1;
    };

    // Verify the pinned package before trusting its contents.
    const pkg = try cwd.readFileAlloc(io, args[2], gpa, .limited(64 << 20));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pkg, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, list.sha256)) {
        std.debug.print("winmdgen: {s} has sha256 {s}, expected {s} ({s})\n", .{ args[2], &hex, list.sha256, list.package });
        return 1;
    }
    const winmd = try extractWinmd(gpa, io, args[2]);

    var m = try md.parse(winmd);
    _ = &m;
    var ix = try Index.build(gpa, &m);

    var all_names: std.ArrayList([]const u8) = .empty;
    inline for (.{ &ix.types, &ix.functions }) |map| {
        var it = map.keyIterator();
        while (it.next()) |k| try all_names.append(gpa, k.*);
    }
    inline for (.{ &ix.constants, &ix.enum_members }) |map| {
        var it = map.keyIterator();
        while (it.next()) |k| try all_names.append(gpa, k.*);
    }

    var g: Gen = .{ .gpa = gpa, .arena = gpa, .ix = &ix, .dec = .{ .ix = &ix, .arena = gpa }, .aliases = list.dll_aliases };
    for (list.apis) |name| try g.request(name, all_names.items);
    if (g.errors > 0) return 1;
    for (g.functions.keys()) |f| try g.needSig(try methodSig(g.dec, f));
    for (g.constants.keys()) |c| try g.needTy(try fieldType(g.dec, c));
    try g.closure();
    for (g.types.keys()) |row| g.types.getPtr(row).?.* = g.full.contains(row);

    // Collision check on the flat namespace and parameter-shadowing set.
    for (g.types.keys()) |row| {
        const gop = try g.names.getOrPut(gpa, ix.typeName(row));
        if (gop.found_existing) {
            std.debug.print("winmdgen: two types named `{s}`; flat namespace cannot hold both\n", .{ix.typeName(row)});
            return 1;
        }
        if (ix.kindOf(row) == .enumeration) {
            const s = m.index(.TypeDef, row, TD.fields);
            for (s..m.listEnd(.TypeDef, row, TD.fields, .Field)) |f| try g.names.put(gpa, m.string(.Field, @intCast(f), FD.name), {});
        }
    }
    for (g.functions.keys()) |f| try g.names.put(gpa, m.string(.MethodDef, f, MD.name), {});
    for (g.constants.keys()) |c| try g.names.put(gpa, m.string(.Field, c, FD.name), {});
    try g.names.put(gpa, "GUID", {});

    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    const e: Emitter = .{ .g = &g, .w = w };
    try w.print("//! Generated by tools/winmdgen from {s} (Windows.Win32.winmd). Do not edit:\n//! change bindings/windows.zon instead.\n\n", .{list.package});
    try w.writeAll("pub const GUID = extern struct { Data1: u32, Data2: u16, Data3: u16, Data4: [8]u8 };\n\n");

    const SortCtx = struct {
        names: []const []const u8,
        pub fn lessThan(c: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, c.names[a], c.names[b]);
        }
    };
    {
        const keys = g.types.keys();
        const names = try gpa.alloc([]const u8, keys.len);
        for (keys, names) |k, *n| n.* = ix.typeName(k);
        const order = try gpa.alloc(usize, keys.len);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, SortCtx{ .names = names }, struct {
            fn f(c: SortCtx, a: usize, b: usize) bool {
                return c.lessThan(a, b);
            }
        }.f);
        for (order) |i| try e.topType(keys[i], g.types.values()[i]);
    }
    try w.writeAll("\n");
    for (g.clsids.keys()) |row| {
        const guid = ix.guidOf(.{ .table = .TypeDef, .row = row }) orelse return error.CoclassWithoutGuid;
        try w.print("pub const CLSID_{s}: GUID = ", .{ix.typeName(row)});
        try e.guid(guid);
        try w.writeAll(";\n");
    }
    for (g.constants.keys()) |c| try e.constant(c);
    try w.writeAll("\n");
    for (g.functions.keys()) |f| try e.function(f, list.dll_aliases);

    try cwd.writeFile(io, .{ .sub_path = args[3], .data = out.written() });
    return 0;
}

fn extractWinmd(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    var it = try std.zip.Iterator.init(&fr);
    var name_buf: [256]u8 = undefined;
    while (try it.next()) |entry| {
        const name = try entry.getFilename(&fr, &name_buf, .{});
        if (!std.mem.eql(u8, name, "Windows.Win32.winmd")) continue;
        var out: std.Io.Writer.Allocating = .init(gpa);
        try entry.extractTo(&fr, &out.writer);
        return out.written();
    }
    return error.WinmdNotInPackage;
}

/// Struct types whose constants are written as a `{guid}, pid` initializer.
fn isPropertyKey(name: []const u8) bool {
    return std.mem.eql(u8, name, "PROPERTYKEY") or std.mem.eql(u8, name, "DEVPROPKEY");
}
