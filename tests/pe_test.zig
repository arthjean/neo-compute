//! The import tables of the shipped Windows server (PE32+): no registry
//! write function (US-036) and no network DLL (FR-10). Added to `zig build
//! test` for a Windows target only.

const std = @import("std");
const testing = std.testing;
const options = @import("test_options");

const Imports = struct {
    dlls: []const []const u8,
    /// Functions imported by name, of every DLL.
    functions: []const []const u8,

    fn deinit(self: Imports, gpa: std.mem.Allocator) void {
        gpa.free(self.dlls);
        gpa.free(self.functions);
    }
};

/// Names of the DLLs a PE32+ image imports, directly or delay-loaded.
fn importedDlls(gpa: std.mem.Allocator, image: []const u8) ![]const []const u8 {
    const imports = try importsOf(gpa, image);
    gpa.free(imports.functions);
    return imports.dlls;
}

/// The DLLs and the functions a PE32+ image imports, directly or
/// delay-loaded; functions imported by ordinal have no name and are left
/// out.
fn importsOf(gpa: std.mem.Allocator, image: []const u8) !Imports {
    if (image.len < 0x40 or !std.mem.eql(u8, image[0..2], "MZ")) return error.NotPe;
    const pe = std.mem.readInt(u32, image[0x3c..][0..4], .little);
    if (!std.mem.eql(u8, image[pe..][0..4], "PE\x00\x00")) return error.NotPe;
    const coff = pe + 4;
    const sections = std.mem.readInt(u16, image[coff + 2 ..][0..2], .little);
    const opt_size = std.mem.readInt(u16, image[coff + 16 ..][0..2], .little);
    const opt = coff + 20;
    if (std.mem.readInt(u16, image[opt..][0..2], .little) != 0x20b) return error.NotPe32Plus;
    const dirs = opt + 112;
    const Sections = struct {
        image: []const u8,
        table: usize,
        count: u16,
        fn offset(self: @This(), rva: u32) ?usize {
            for (0..self.count) |i| {
                const s = self.table + i * 40;
                const va = std.mem.readInt(u32, self.image[s + 12 ..][0..4], .little);
                const size = std.mem.readInt(u32, self.image[s + 16 ..][0..4], .little);
                const raw = std.mem.readInt(u32, self.image[s + 20 ..][0..4], .little);
                if (rva >= va and rva < va + size) return raw + (rva - va);
            }
            return null;
        }
    };
    const map: Sections = .{ .image = image, .table = opt + opt_size, .count = sections };
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    var functions: std.ArrayList([]const u8) = .empty;
    errdefer functions.deinit(gpa);
    // Data directory 1: import table (20-byte descriptors, name at +12,
    // name table at +0, address table at +16 when the name table is 0).
    // Data directory 13: delay import table (32-byte descriptors, name at
    // +4, name table at +16).
    for ([_][5]u32{ .{ 1, 20, 12, 0, 16 }, .{ 13, 32, 4, 16, 16 } }) |d| {
        const rva = std.mem.readInt(u32, image[dirs + d[0] * 8 ..][0..4], .little);
        if (rva == 0) continue;
        var at = map.offset(rva) orelse return error.BadImportTable;
        while (true) : (at += d[1]) {
            const name_rva = std.mem.readInt(u32, image[at + d[2] ..][0..4], .little);
            if (name_rva == 0) break;
            const off = map.offset(name_rva) orelse return error.BadImportTable;
            try names.append(gpa, std.mem.sliceTo(image[off..], 0));
            var table = std.mem.readInt(u32, image[at + d[3] ..][0..4], .little);
            if (table == 0) table = std.mem.readInt(u32, image[at + d[4] ..][0..4], .little);
            if (table == 0) continue;
            // 8-byte entries; the high bit marks an ordinal, otherwise the
            // RVA of a 2-byte hint and the name.
            var entry = map.offset(table) orelse return error.BadImportTable;
            while (true) : (entry += 8) {
                const v = std.mem.readInt(u64, image[entry..][0..8], .little);
                if (v == 0) break;
                if (v & (1 << 63) != 0) continue;
                const hint = map.offset(@truncate(v)) orelse return error.BadImportTable;
                try functions.append(gpa, std.mem.sliceTo(image[hint + 2 ..], 0));
            }
        }
    }
    const dlls = try names.toOwnedSlice(gpa);
    errdefer gpa.free(dlls);
    return .{ .dlls = dlls, .functions = try functions.toOwnedSlice(gpa) };
}

/// Prefixes of every function that writes to the registry (advapi32's
/// `Reg*` and their kernelbase forwards, shlwapi's `SH*` helpers, ntdll's
/// key calls), in their A and W forms (US-036).
const registry_writes = [_][]const u8{
    "RegSetValue",   "RegSetKeyValue", "RegCreateKey",      "RegDeleteKey",        "RegDeleteValue",       "RegDeleteTree",
    "RegCopyTree",   "RegRenameKey",   "RegRestoreKey",     "RegLoadKey",          "RegLoadAppKey",        "RegUnLoadKey",
    "RegReplaceKey", "RegSaveKey",     "RegSetKeySecurity", "RegFlushKey",         "RegOverridePredefKey", "SHSetValue",
    "SHDeleteKey",   "SHDeleteValue",  "SHDeleteEmptyKey",  "SHRegSet",            "SHRegWrite",           "SHRegCreate",
    "SHRegDelete",   "SHCopyKey",      "NtSetValueKey",     "ZwSetValueKey",       "NtCreateKey",          "ZwCreateKey",
    "NtDeleteKey",   "ZwDeleteKey",    "NtDeleteValueKey",  "ZwDeleteValueKey",    "NtRenameKey",          "NtSaveKey",
    "NtRestoreKey",  "NtLoadKey",      "NtReplaceKey",      "NtSetInformationKey",
};

test "the shipped binary imports no registry write function, and the read ones registry_read uses" {
    const io = testing.io;
    const image = try std.Io.Dir.cwd().readFileAlloc(io, options.server_exe, testing.allocator, .limited(64 << 20));
    defer testing.allocator.free(image);
    const imports = try importsOf(testing.allocator, image);
    defer imports.deinit(testing.allocator);
    var reads: usize = 0;
    for (imports.functions) |f| {
        for (registry_writes) |p| if (std.mem.startsWith(u8, f, p)) {
            std.debug.print("{s} imports {s}\n", .{ options.server_exe, f });
            return error.RegistryWriteImport;
        };
        if (std.mem.startsWith(u8, f, "Reg")) reads += 1;
    }
    // The parser reads the real name tables: registry_read's own calls are
    // there.
    for ([_][]const u8{ "RegOpenKeyExW", "RegQueryValueExW", "RegEnumValueW", "RegEnumKeyExW", "RegQueryInfoKeyW", "RegCloseKey" }) |want| {
        for (imports.functions) |f| {
            if (std.mem.eql(u8, f, want)) break;
        } else {
            std.debug.print("{s} does not import {s}\n", .{ options.server_exe, want });
            return error.MissingImport;
        }
    }
    std.debug.print("process: {d} imported functions, {d} registry reads, no registry write\n", .{ imports.functions.len, reads });
}

test "the shipped binary imports no network DLL (ws2_32, winhttp, wininet)" {
    const io = testing.io;
    const image = try std.Io.Dir.cwd().readFileAlloc(io, options.server_exe, testing.allocator, .limited(64 << 20));
    defer testing.allocator.free(image);
    const dlls = try importedDlls(testing.allocator, image);
    defer testing.allocator.free(dlls);
    var has_kernel32 = false;
    for (dlls) |dll| {
        has_kernel32 = has_kernel32 or std.ascii.eqlIgnoreCase(dll, "kernel32.dll");
        for ([_][]const u8{ "ws2_32.dll", "winhttp.dll", "wininet.dll" }) |net| if (std.ascii.eqlIgnoreCase(dll, net)) {
            std.debug.print("{s} imports {s}\n", .{ options.server_exe, dll });
            return error.NetworkImport;
        };
    }
    // The parser reads the real table: kernel32 is always there.
    try testing.expect(has_kernel32);
    std.debug.print("process: {d} imported DLLs, none of them a network library\n", .{dlls.len});
}
