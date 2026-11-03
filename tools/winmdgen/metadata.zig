//! Minimal ECMA-335 metadata reader: PE container, metadata root, heaps and
//! the physical tables, with typed accessors for the columns winmdgen needs.

const std = @import("std");

pub const Error = error{ BadImage, BadMetadata, OutOfMemory };

pub const Table = enum(u6) {
    Module = 0x00,
    TypeRef = 0x01,
    TypeDef = 0x02,
    FieldPtr = 0x03,
    Field = 0x04,
    MethodPtr = 0x05,
    MethodDef = 0x06,
    ParamPtr = 0x07,
    Param = 0x08,
    InterfaceImpl = 0x09,
    MemberRef = 0x0A,
    Constant = 0x0B,
    CustomAttribute = 0x0C,
    FieldMarshal = 0x0D,
    DeclSecurity = 0x0E,
    ClassLayout = 0x0F,
    FieldLayout = 0x10,
    StandAloneSig = 0x11,
    EventMap = 0x12,
    EventPtr = 0x13,
    Event = 0x14,
    PropertyMap = 0x15,
    PropertyPtr = 0x16,
    Property = 0x17,
    MethodSemantics = 0x18,
    MethodImpl = 0x19,
    ModuleRef = 0x1A,
    TypeSpec = 0x1B,
    ImplMap = 0x1C,
    FieldRVA = 0x1D,
    EncLog = 0x1E,
    EncMap = 0x1F,
    Assembly = 0x20,
    AssemblyProcessor = 0x21,
    AssemblyOS = 0x22,
    AssemblyRef = 0x23,
    AssemblyRefProcessor = 0x24,
    AssemblyRefOS = 0x25,
    File = 0x26,
    ExportedType = 0x27,
    ManifestResource = 0x28,
    NestedClass = 0x29,
    GenericParam = 0x2A,
    MethodSpec = 0x2B,
    GenericParamConstraint = 0x2C,
};
const table_count = 0x2D;

pub const Coded = enum {
    TypeDefOrRef,
    HasConstant,
    HasCustomAttribute,
    HasFieldMarshal,
    HasDeclSecurity,
    MemberRefParent,
    HasSemantics,
    MethodDefOrRef,
    MemberForwarded,
    Implementation,
    CustomAttributeType,
    ResolutionScope,
    TypeOrMethodDef,

    /// Tables addressed by the tag, in tag order. `null` marks unused tags.
    pub fn tables(c: Coded) []const ?Table {
        return switch (c) {
            .TypeDefOrRef => &.{ .TypeDef, .TypeRef, .TypeSpec },
            .HasConstant => &.{ .Field, .Param, .Property },
            .HasCustomAttribute => &.{ .MethodDef, .Field, .TypeRef, .TypeDef, .Param, .InterfaceImpl, .MemberRef, .Module, .DeclSecurity, .Property, .Event, .StandAloneSig, .ModuleRef, .TypeSpec, .Assembly, .AssemblyRef, .File, .ExportedType, .ManifestResource, .GenericParam, .GenericParamConstraint, .MethodSpec },
            .HasFieldMarshal => &.{ .Field, .Param },
            .HasDeclSecurity => &.{ .TypeDef, .MethodDef, .Assembly },
            .MemberRefParent => &.{ .TypeDef, .TypeRef, .ModuleRef, .MethodDef, .TypeSpec },
            .HasSemantics => &.{ .Event, .Property },
            .MethodDefOrRef => &.{ .MethodDef, .MemberRef },
            .MemberForwarded => &.{ .Field, .MethodDef },
            .Implementation => &.{ .File, .AssemblyRef, .ExportedType },
            .CustomAttributeType => &.{ null, null, .MethodDef, .MemberRef, null },
            .ResolutionScope => &.{ .Module, .ModuleRef, .AssemblyRef, .TypeRef },
            .TypeOrMethodDef => &.{ .TypeDef, .MethodDef },
        };
    }

    pub fn tagBits(c: Coded) u5 {
        const n = c.tables().len;
        return @intCast(std.math.log2_int_ceil(usize, n));
    }
};

pub const Col = union(enum) {
    u8,
    u16,
    u32,
    string,
    guid,
    blob,
    index: Table,
    coded: Coded,
};

fn schema(t: Table) []const Col {
    return switch (t) {
        .Module => &.{ .u16, .string, .guid, .guid, .guid },
        .TypeRef => &.{ .{ .coded = .ResolutionScope }, .string, .string },
        .TypeDef => &.{ .u32, .string, .string, .{ .coded = .TypeDefOrRef }, .{ .index = .Field }, .{ .index = .MethodDef } },
        .FieldPtr => &.{.{ .index = .Field }},
        .Field => &.{ .u16, .string, .blob },
        .MethodPtr => &.{.{ .index = .MethodDef }},
        .MethodDef => &.{ .u32, .u16, .u16, .string, .blob, .{ .index = .Param } },
        .ParamPtr => &.{.{ .index = .Param }},
        .Param => &.{ .u16, .u16, .string },
        .InterfaceImpl => &.{ .{ .index = .TypeDef }, .{ .coded = .TypeDefOrRef } },
        .MemberRef => &.{ .{ .coded = .MemberRefParent }, .string, .blob },
        .Constant => &.{ .u16, .{ .coded = .HasConstant }, .blob },
        .CustomAttribute => &.{ .{ .coded = .HasCustomAttribute }, .{ .coded = .CustomAttributeType }, .blob },
        .FieldMarshal => &.{ .{ .coded = .HasFieldMarshal }, .blob },
        .DeclSecurity => &.{ .u16, .{ .coded = .HasDeclSecurity }, .blob },
        .ClassLayout => &.{ .u16, .u32, .{ .index = .TypeDef } },
        .FieldLayout => &.{ .u32, .{ .index = .Field } },
        .StandAloneSig => &.{.blob},
        .EventMap => &.{ .{ .index = .TypeDef }, .{ .index = .Event } },
        .EventPtr => &.{.{ .index = .Event }},
        .Event => &.{ .u16, .string, .{ .coded = .TypeDefOrRef } },
        .PropertyMap => &.{ .{ .index = .TypeDef }, .{ .index = .Property } },
        .PropertyPtr => &.{.{ .index = .Property }},
        .Property => &.{ .u16, .string, .blob },
        .MethodSemantics => &.{ .u16, .{ .index = .MethodDef }, .{ .coded = .HasSemantics } },
        .MethodImpl => &.{ .{ .index = .TypeDef }, .{ .coded = .MethodDefOrRef }, .{ .coded = .MethodDefOrRef } },
        .ModuleRef => &.{.string},
        .TypeSpec => &.{.blob},
        .ImplMap => &.{ .u16, .{ .coded = .MemberForwarded }, .string, .{ .index = .ModuleRef } },
        .FieldRVA => &.{ .u32, .{ .index = .Field } },
        .EncLog => &.{ .u32, .u32 },
        .EncMap => &.{.u32},
        .Assembly => &.{ .u32, .u16, .u16, .u16, .u16, .u32, .blob, .string, .string },
        .AssemblyProcessor => &.{.u32},
        .AssemblyOS => &.{ .u32, .u32, .u32 },
        .AssemblyRef => &.{ .u16, .u16, .u16, .u16, .u32, .blob, .string, .string, .blob },
        .AssemblyRefProcessor => &.{ .u32, .{ .index = .AssemblyRef } },
        .AssemblyRefOS => &.{ .u32, .u32, .u32, .{ .index = .AssemblyRef } },
        .File => &.{ .u32, .string, .blob },
        .ExportedType => &.{ .u32, .u32, .string, .string, .{ .coded = .Implementation } },
        .ManifestResource => &.{ .u32, .u32, .string, .{ .coded = .Implementation } },
        .NestedClass => &.{ .{ .index = .TypeDef }, .{ .index = .TypeDef } },
        .GenericParam => &.{ .u16, .u16, .{ .coded = .TypeOrMethodDef }, .string },
        .MethodSpec => &.{ .{ .coded = .MethodDefOrRef }, .blob },
        .GenericParamConstraint => &.{ .{ .index = .GenericParam }, .{ .coded = .TypeDefOrRef } },
    };
}

const max_cols = 9;

const TableInfo = struct {
    rows: u32 = 0,
    row_size: u32 = 0,
    data: []const u8 = &.{},
    col_offset: [max_cols]u8 = @splat(0),
    col_size: [max_cols]u8 = @splat(0),
};

/// A decoded coded index: target table and 1-based row (0 = null).
pub const Ref = struct { table: Table, row: u32 };

pub const Metadata = struct {
    strings: []const u8,
    blobs: []const u8,
    guids: []const u8,
    tables: [table_count]TableInfo = @splat(.{}),
    string_wide: bool,
    guid_wide: bool,
    blob_wide: bool,

    pub fn rowCount(self: *const Metadata, t: Table) u32 {
        return self.tables[@backingInt(t)].rows;
    }

    fn cell(self: *const Metadata, t: Table, row: u32, col: usize) u32 {
        const info = &self.tables[@backingInt(t)];
        std.debug.assert(row >= 1 and row <= info.rows);
        const at = (row - 1) * info.row_size + info.col_offset[col];
        const bytes = info.data[at..];
        return switch (info.col_size[col]) {
            1 => bytes[0],
            2 => std.mem.readInt(u16, bytes[0..2], .little),
            4 => std.mem.readInt(u32, bytes[0..4], .little),
            else => unreachable,
        };
    }

    pub fn int(self: *const Metadata, t: Table, row: u32, col: usize) u32 {
        return self.cell(t, row, col);
    }

    pub fn string(self: *const Metadata, t: Table, row: u32, col: usize) []const u8 {
        const off = self.cell(t, row, col);
        return std.mem.sliceTo(self.strings[off..], 0);
    }

    pub fn blob(self: *const Metadata, t: Table, row: u32, col: usize) []const u8 {
        const off = self.cell(t, row, col);
        var r: Blob = .{ .data = self.blobs[off..] };
        const len = r.compressed() catch return &.{};
        return r.data[r.pos..][0..len];
    }

    pub fn index(self: *const Metadata, t: Table, row: u32, col: usize) u32 {
        return self.cell(t, row, col);
    }

    pub fn coded(self: *const Metadata, t: Table, row: u32, col: usize) ?Ref {
        const c = schema(t)[col].coded;
        const v = self.cell(t, row, col);
        const bits = c.tagBits();
        const tag = v & ((@as(u32, 1) << bits) - 1);
        const r = v >> bits;
        const tabs = c.tables();
        if (tag >= tabs.len or r == 0) return null;
        const target = tabs[tag] orelse return null;
        return .{ .table = target, .row = r };
    }

    /// End (exclusive) of a TypeDef's field or method run.
    pub fn listEnd(self: *const Metadata, t: Table, row: u32, col: usize, target: Table) u32 {
        if (row < self.rowCount(t)) return self.index(t, row + 1, col);
        return self.rowCount(target) + 1;
    }
};

/// Cursor over a signature or custom attribute blob.
pub const Blob = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn byte(self: *Blob) Error!u8 {
        if (self.pos >= self.data.len) return error.BadMetadata;
        defer self.pos += 1;
        return self.data[self.pos];
    }

    pub fn peek(self: *const Blob) Error!u8 {
        if (self.pos >= self.data.len) return error.BadMetadata;
        return self.data[self.pos];
    }

    pub fn compressed(self: *Blob) Error!u32 {
        const b0 = try self.byte();
        if (b0 & 0x80 == 0) return b0;
        if (b0 & 0xC0 == 0x80) return (@as(u32, b0 & 0x3F) << 8) | try self.byte();
        if (b0 & 0xE0 == 0xC0) {
            var v: u32 = b0 & 0x1F;
            for (0..3) |_| v = (v << 8) | try self.byte();
            return v;
        }
        return error.BadMetadata;
    }

    pub fn fixed(self: *Blob, comptime T: type) Error!T {
        const n = @sizeOf(T);
        if (self.pos + n > self.data.len) return error.BadMetadata;
        defer self.pos += n;
        return std.mem.readInt(T, self.data[self.pos..][0..n], .little);
    }

    /// TypeDefOrRefOrSpecEncoded.
    pub fn typeRef(self: *Blob) Error!Ref {
        const v = try self.compressed();
        const table: Table = switch (v & 3) {
            0 => .TypeDef,
            1 => .TypeRef,
            2 => .TypeSpec,
            else => return error.BadMetadata,
        };
        return .{ .table = table, .row = v >> 2 };
    }
};

fn rd(comptime T: type, bytes: []const u8, at: usize) Error!T {
    if (at + @sizeOf(T) > bytes.len) return error.BadImage;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

/// Parses `image` (a .winmd PE file). The returned metadata borrows `image`.
pub fn parse(image: []const u8) Error!Metadata {
    if (image.len < 0x40 or image[0] != 'M' or image[1] != 'Z') return error.BadImage;
    const pe = try rd(u32, image, 0x3C);
    if (try rd(u32, image, pe) != 0x00004550) return error.BadImage;
    const coff = pe + 4;
    const sections = try rd(u16, image, coff + 2);
    const opt_size = try rd(u16, image, coff + 16);
    const opt = coff + 20;
    const magic = try rd(u16, image, opt);
    const dirs = opt + @as(usize, if (magic == 0x20b) 112 else 96);
    const cli_rva = try rd(u32, image, dirs + 14 * 8);
    const section_table = opt + opt_size;

    const toOffset = struct {
        fn f(img: []const u8, table: usize, count: u16, rva: u32) Error!usize {
            for (0..count) |i| {
                const s = table + i * 40;
                const va = try rd(u32, img, s + 12);
                const vsize = @max(try rd(u32, img, s + 8), try rd(u32, img, s + 16));
                if (rva >= va and rva < va + vsize) return rva - va + try rd(u32, img, s + 20);
            }
            return error.BadImage;
        }
    }.f;

    const cli = try toOffset(image, section_table, sections, cli_rva);
    const md_rva = try rd(u32, image, cli + 8);
    const md = try toOffset(image, section_table, sections, md_rva);
    if (try rd(u32, image, md) != 0x424A5342) return error.BadMetadata;
    const ver_len = try rd(u32, image, md + 12);
    var p = md + 16 + ver_len;
    p += 2; // flags
    const stream_count = try rd(u16, image, p);
    p += 2;

    var tables_stream: []const u8 = &.{};
    var strings: []const u8 = &.{};
    var blobs: []const u8 = &.{};
    var guids: []const u8 = &.{};
    for (0..stream_count) |_| {
        const off = try rd(u32, image, p);
        const size = try rd(u32, image, p + 4);
        const name = std.mem.sliceTo(image[p + 8 ..], 0);
        p += 8 + std.mem.alignForward(usize, name.len + 1, 4);
        if (md + off + size > image.len) return error.BadMetadata;
        const data = image[md + off ..][0..size];
        if (std.mem.eql(u8, name, "#~") or std.mem.eql(u8, name, "#-")) tables_stream = data else if (std.mem.eql(u8, name, "#Strings")) strings = data else if (std.mem.eql(u8, name, "#Blob")) blobs = data else if (std.mem.eql(u8, name, "#GUID")) guids = data;
    }
    if (tables_stream.len < 24) return error.BadMetadata;

    const heap_sizes = tables_stream[6];
    var m: Metadata = .{
        .strings = strings,
        .blobs = blobs,
        .guids = guids,
        .string_wide = heap_sizes & 1 != 0,
        .guid_wide = heap_sizes & 2 != 0,
        .blob_wide = heap_sizes & 4 != 0,
    };
    const valid = try rd(u64, tables_stream, 8);
    var q: usize = 24;
    for (0..64) |i| {
        if (valid & (@as(u64, 1) << @intCast(i)) == 0) continue;
        if (i >= table_count) return error.BadMetadata;
        m.tables[i].rows = try rd(u32, tables_stream, q);
        q += 4;
    }

    // Column sizes depend on row counts, so compute every layout first.
    for (0..table_count) |i| {
        const t: Table = @fromBackingInt(@intCast(i));
        const info = &m.tables[i];
        var off: u32 = 0;
        for (schema(t), 0..) |c, ci| {
            const size: u8 = switch (c) {
                .u8 => 1,
                .u16 => 2,
                .u32 => 4,
                .string => if (m.string_wide) 4 else 2,
                .guid => if (m.guid_wide) 4 else 2,
                .blob => if (m.blob_wide) 4 else 2,
                .index => |target| if (m.tables[@backingInt(target)].rows < (1 << 16)) 2 else 4,
                .coded => |cd| blk: {
                    var max_rows: u32 = 0;
                    for (cd.tables()) |ot| if (ot) |tt| {
                        max_rows = @max(max_rows, m.tables[@backingInt(tt)].rows);
                    };
                    break :blk if (max_rows < (@as(u32, 1) << @intCast(16 - @as(u32, cd.tagBits())))) 2 else 4;
                },
            };
            info.col_offset[ci] = @intCast(off);
            info.col_size[ci] = size;
            off += size;
        }
        info.row_size = off;
    }
    for (0..table_count) |i| {
        const info = &m.tables[i];
        const len = @as(usize, info.rows) * info.row_size;
        if (q + len > tables_stream.len) return error.BadMetadata;
        info.data = tables_stream[q..][0..len];
        q += len;
    }
    return m;
}
