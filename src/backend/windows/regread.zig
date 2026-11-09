//! registry_read (US-036) on Windows: RegOpenKeyExW with KEY_WOW64_64KEY,
//! RegQueryValueExW, RegEnumValueW, RegEnumKeyExW and RegQueryInfoKeyW only.
//! No registry write function is declared in bindings/windows.zon, and
//! tests/process_test.zig checks the binary imports none. Keys are opened
//! with the least access the read needs, so a key readable without
//! READ_CONTROL or KEY_NOTIFY still reads.

const std = @import("std");
const w = @import("win32");
const regread = @import("../../core/regread.zig");

fn rootKey(r: regread.Root) w.HKEY {
    return switch (r) {
        .hkcu => w.HKEY_CURRENT_USER,
        .hklm => w.HKEY_LOCAL_MACHINE,
        .hkcr => w.HKEY_CLASSES_ROOT,
        .hku => w.HKEY_USERS,
        .hkcc => w.HKEY_CURRENT_CONFIG,
    };
}

fn failure(code: u32) regread.Failure {
    return switch (code) {
        w.ERROR_FILE_NOT_FOUND => .missing_key,
        w.ERROR_ACCESS_DENIED => .denied,
        else => .{ .other = code },
    };
}

fn wideZ(arena: std.mem.Allocator, s: []const u8) ?[:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, s) catch null;
}

fn utf8(arena: std.mem.Allocator, units: []const u16) []const u8 {
    const buf = arena.alloc(u8, units.len * 3) catch return "?";
    return buf[0..std.unicode.wtf16LeToWtf8(buf, units)];
}

const Opened = union(enum) { ok: w.HKEY, failed: regread.Failure };

fn open(arena: std.mem.Allocator, path: regread.Path, access: u32) Opened {
    const sub = wideZ(arena, path.sub) orelse return .{ .failed = .{ .other = w.ERROR_NOT_ENOUGH_MEMORY } };
    var hk: w.HKEY = null;
    const rc = w.RegOpenKeyExW(rootKey(path.root), sub, 0, access | w.KEY_WOW64_64KEY, &hk);
    if (rc != w.ERROR_SUCCESS) return .{ .failed = failure(rc) };
    return .{ .ok = hk };
}

/// REG_EXPAND_SZ data with its environment variables expanded, UTF-8.
fn expand(arena: std.mem.Allocator, data: []const u8) ?[]const u8 {
    const n = data.len / 2;
    const src = arena.allocSentinel(u16, n, 0) catch return null;
    @memcpy(std.mem.sliceAsBytes(src), data[0 .. n * 2]);
    var size: u32 = 512;
    var tries: u32 = 0;
    while (tries < 3) : (tries += 1) {
        const dst = arena.alloc(u16, size) catch return null;
        const need = w.ExpandEnvironmentStringsW(src, @ptrCast(dst.ptr), size);
        if (need == 0) return null;
        if (need <= size) return utf8(arena, std.mem.sliceTo(dst[0 .. need - 1], 0));
        size = need;
    }
    return null;
}

fn finish(arena: std.mem.Allocator, v: *regread.Value) void {
    if (v.kind == .expand_sz and v.data.len == v.size) v.expanded = expand(arena, v.data);
}

pub fn value(arena: std.mem.Allocator, path: regread.Path, name: []const u8) regread.ValueResult {
    const hk = switch (open(arena, path, w.KEY_QUERY_VALUE)) {
        .ok => |k| k,
        .failed => |f| return .{ .failed = f },
    };
    defer _ = w.RegCloseKey(hk);
    const name_w = wideZ(arena, name) orelse return .{ .failed = .{ .other = w.ERROR_NOT_ENOUGH_MEMORY } };
    var kind: u32 = 0;
    var size: u32 = 0;
    var rc = w.RegQueryValueExW(hk, name_w, null, &kind, null, &size);
    if (rc == w.ERROR_FILE_NOT_FOUND) return .{ .failed = .missing_value };
    if (rc != w.ERROR_SUCCESS) return .{ .failed = failure(rc) };
    var v: regread.Value = .{ .name = name, .kind = @fromBackingInt(@intCast(kind)), .data = "", .size = size };
    if (size > regread.max_data) return .{ .ok = v };
    // The value may grow between the two calls: retry with its new size.
    var tries: u32 = 0;
    while (tries < 3) : (tries += 1) {
        const buf = arena.alloc(u8, @max(size, 1)) catch return .{ .failed = .{ .other = w.ERROR_NOT_ENOUGH_MEMORY } };
        var got: u32 = size;
        rc = w.RegQueryValueExW(hk, name_w, null, &kind, @ptrCast(buf.ptr), &got);
        if (rc == w.ERROR_MORE_DATA and got <= regread.max_data) {
            size = got;
            continue;
        }
        if (rc != w.ERROR_SUCCESS) return .{ .failed = failure(rc) };
        v = .{ .name = name, .kind = @fromBackingInt(@intCast(kind)), .data = buf[0..got], .size = got };
        finish(arena, &v);
        return .{ .ok = v };
    }
    return .{ .failed = .{ .other = w.ERROR_MORE_DATA } };
}

pub fn key(arena: std.mem.Allocator, path: regread.Path, max_values: usize, max_subkeys: usize) regread.KeyResult {
    const hk = switch (open(arena, path, w.KEY_QUERY_VALUE | w.KEY_ENUMERATE_SUB_KEYS)) {
        .ok => |k| k,
        .failed => |f| return .{ .failed = f },
    };
    defer _ = w.RegCloseKey(hk);
    var subkeys: u32 = 0;
    var max_subkey: u32 = 0;
    var values: u32 = 0;
    var max_name: u32 = 0;
    var max_len: u32 = 0;
    const rc = w.RegQueryInfoKeyW(hk, null, null, null, &subkeys, &max_subkey, null, &values, &max_name, &max_len, null, null);
    if (rc != w.ERROR_SUCCESS) return .{ .failed = failure(rc) };
    const oom: regread.KeyResult = .{ .failed = .{ .other = w.ERROR_NOT_ENOUGH_MEMORY } };

    // Value names are at most 16383 characters, key names 255.
    const name_buf = arena.alloc(u16, @min(max_name, 16383) + 1) catch return oom;
    const data_buf = arena.alloc(u8, @max(@min(max_len, regread.max_data), 1)) catch return oom;
    var out_values: std.ArrayList(regread.Value) = .empty;
    var i: u32 = 0;
    while (i < values and out_values.items.len < max_values) : (i += 1) {
        var name_len: u32 = @intCast(name_buf.len);
        var kind: u32 = 0;
        var size: u32 = @intCast(data_buf.len);
        var r = w.RegEnumValueW(hk, i, @ptrCast(name_buf.ptr), &name_len, null, &kind, @ptrCast(data_buf.ptr), &size);
        var data: []const u8 = "";
        if (r == w.ERROR_MORE_DATA) {
            // Data above `max_data` (or a value that grew): type and size only.
            name_len = @intCast(name_buf.len);
            r = w.RegEnumValueW(hk, i, @ptrCast(name_buf.ptr), &name_len, null, &kind, null, &size);
        } else if (r == w.ERROR_SUCCESS) {
            data = arena.dupe(u8, data_buf[0..size]) catch return oom;
        }
        if (r == w.ERROR_NO_MORE_ITEMS) break;
        if (r != w.ERROR_SUCCESS) continue;
        var v: regread.Value = .{ .name = utf8(arena, name_buf[0..name_len]), .kind = @fromBackingInt(@intCast(kind)), .data = data, .size = size };
        finish(arena, &v);
        out_values.append(arena, v) catch return oom;
    }

    const key_buf = arena.alloc(u16, @min(max_subkey, 255) + 1) catch return oom;
    var out_keys: std.ArrayList([]const u8) = .empty;
    i = 0;
    while (i < subkeys and out_keys.items.len < max_subkeys) : (i += 1) {
        var len: u32 = @intCast(key_buf.len);
        const r = w.RegEnumKeyExW(hk, i, @ptrCast(key_buf.ptr), &len, null, null, null, null);
        if (r == w.ERROR_NO_MORE_ITEMS) break;
        if (r != w.ERROR_SUCCESS) continue;
        out_keys.append(arena, utf8(arena, key_buf[0..len])) catch return oom;
    }
    return .{ .ok = .{ .values = out_values.items, .values_total = values, .subkeys = out_keys.items, .subkeys_total = subkeys } };
}
