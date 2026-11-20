//! Keyboard layouts through libxkbcommon, loaded with dlopen (US-080, P7,
//! T3): the binary names no library beyond glibc's, and a system without
//! libxkbcommon keeps every capability but the keyboard. The function
//! types come from the pinned xkbcommon.h through translate-c, never typed
//! by hand.
//!
//! The compositor publishes its keymap on the EI keyboard; `Keymap.find`
//! gives the evdev keycode and the modifiers that produce a keysym in the
//! active layout, so a character absent from it is known before any key
//! is sent (FR-51).

const std = @import("std");
const c = @import("xkbcommon_h");

pub const library_name = "libxkbcommon.so.0";
pub const missing_text = "libxkbcommon introuvable : installe-la pour taper du texte.";

/// The functions this backend calls, resolved by name.
pub const Lib = struct {
    handle: *anyopaque,
    context_new: *const c.xkb_context_new,
    context_unref: *const c.xkb_context_unref,
    keymap_new_from_string: *const c.xkb_keymap_new_from_string,
    keymap_new_from_names: *const c.xkb_keymap_new_from_names,
    keymap_unref: *const c.xkb_keymap_unref,
    keymap_min_keycode: *const c.xkb_keymap_min_keycode,
    keymap_max_keycode: *const c.xkb_keymap_max_keycode,
    keymap_num_layouts: *const c.xkb_keymap_num_layouts,
    keymap_layout_get_name: *const c.xkb_keymap_layout_get_name,
    keymap_num_mods: *const c.xkb_keymap_num_mods,
    keymap_mod_get_name: *const c.xkb_keymap_mod_get_name,
    keymap_num_levels_for_key: *const c.xkb_keymap_num_levels_for_key,
    keymap_key_get_syms_by_level: *const c.xkb_keymap_key_get_syms_by_level,
    keymap_key_get_mods_for_level: *const c.xkb_keymap_key_get_mods_for_level,
    utf32_to_keysym: *const c.xkb_utf32_to_keysym,
    context_set_log_level: *const c.xkb_context_set_log_level,

    /// The library named `name`, or null when it is missing or lacks one
    /// of the functions.
    pub fn load(name: [:0]const u8) ?Lib {
        const handle = std.c.dlopen(name, .{ .NOW = true }) orelse return null;
        var lib: Lib = undefined;
        lib.handle = handle;
        inline for (@typeInfo(Lib).@"struct".field_names) |field| {
            if (comptime std.mem.eql(u8, field, "handle")) continue;
            const sym = std.c.dlsym(handle, "xkb_" ++ field) orelse {
                _ = std.c.dlclose(handle);
                return null;
            };
            @field(lib, field) = @ptrCast(@alignCast(sym));
        }
        return lib;
    }
};

/// A key and the modifiers that produce one keysym.
pub const Stroke = struct {
    /// evdev keycode (an XKB keycode minus 8).
    key: u32,
    /// XKB modifier mask, for `modifierNames`.
    mods: u32,
};

pub const Keymap = struct {
    lib: *const Lib,
    context: *c.struct_xkb_context,
    keymap: *c.struct_xkb_keymap,

    /// Compiles the keymap text the compositor published.
    pub fn fromString(lib: *const Lib, text: []const u8, buf: []u8) ?Keymap {
        if (text.len + 1 > buf.len) return null;
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        const ctx = lib.context_new(c.XKB_CONTEXT_NO_ENVIRONMENT_NAMES) orelse return null;
        // A keymap the compositor sent is checked here, not logged.
        lib.context_set_log_level(ctx, c.XKB_LOG_LEVEL_CRITICAL);
        const km = lib.keymap_new_from_string(ctx, buf.ptr, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
            lib.context_unref(ctx);
            return null;
        };
        return .{ .lib = lib, .context = ctx, .keymap = km };
    }

    pub fn deinit(k: Keymap) void {
        k.lib.keymap_unref(k.keymap);
        k.lib.context_unref(k.context);
    }

    pub fn layoutName(k: Keymap, group: u32) []const u8 {
        const p = k.lib.keymap_layout_get_name(k.keymap, group) orelse return "";
        return std.mem.span(p);
    }

    /// The key that types `keysym` in layout `group` with the fewest
    /// modifiers; null when the layout has none.
    pub fn find(k: Keymap, keysym: u32, group: u32) ?Stroke {
        var best: ?Stroke = null;
        var best_bits: usize = std.math.maxInt(usize);
        var kc = k.lib.keymap_min_keycode(k.keymap);
        const max = k.lib.keymap_max_keycode(k.keymap);
        while (kc <= max) : (kc += 1) {
            if (kc < 8) continue;
            const levels = k.lib.keymap_num_levels_for_key(k.keymap, kc, group);
            var level: u32 = 0;
            while (level < levels) : (level += 1) {
                var syms: [*c]const c.xkb_keysym_t = undefined;
                const n = k.lib.keymap_key_get_syms_by_level(k.keymap, kc, group, level, &syms);
                if (n != 1 or syms[0] != keysym) continue;
                var masks: [4]c.xkb_mod_mask_t = undefined;
                const nm = k.lib.keymap_key_get_mods_for_level(k.keymap, kc, group, level, &masks, masks.len);
                for (masks[0..nm]) |m| {
                    const bits = @popCount(m);
                    if (bits < best_bits) {
                        best_bits = bits;
                        best = .{ .key = kc - 8, .mods = m };
                    }
                }
            }
        }
        return best;
    }

    /// The keysym of a Unicode code point (xkb_utf32_to_keysym).
    pub fn keysymOf(k: Keymap, code: u21) u32 {
        return k.lib.utf32_to_keysym(code);
    }

    /// The names of the modifiers of `mask` (Shift, Lock, Control, Mod1,
    /// Mod5...), into `out`.
    pub fn modifierNames(k: Keymap, mask: u32, out: [][]const u8) [][]const u8 {
        var n: usize = 0;
        var i: u32 = 0;
        const count = k.lib.keymap_num_mods(k.keymap);
        while (i < count and i < 32) : (i += 1) {
            if (mask & (@as(u32, 1) << @intCast(i)) == 0 or n == out.len) continue;
            const p = k.lib.keymap_mod_get_name(k.keymap, i) orelse continue;
            out[n] = std.mem.span(p);
            n += 1;
        }
        return out[0..n];
    }
};

const testing = std.testing;

/// A keymap compiled from the system's layouts (xkeyboard-config).
fn named(lib: *const Lib, layout: [*:0]const u8) ?Keymap {
    const ctx = lib.context_new(c.XKB_CONTEXT_NO_ENVIRONMENT_NAMES) orelse return null;
    const names: c.struct_xkb_rule_names = .{ .rules = "evdev", .model = "pc105", .layout = layout };
    const km = lib.keymap_new_from_names(ctx, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
        lib.context_unref(ctx);
        return null;
    };
    return .{ .lib = lib, .context = ctx, .keymap = km };
}

test "a missing library gives no keyboard" {
    try testing.expect(Lib.load("libxkbcommon-absent.so.0") == null);
}

test "a keysym gives its evdev keycode and modifiers in the active layout" {
    var lib = Lib.load(library_name) orelse return error.SkipZigTest;
    const us = named(&lib, "us") orelse return error.SkipZigTest;
    defer us.deinit();
    // KEY_A is 30.
    try testing.expectEqual(Stroke{ .key = 30, .mods = 0 }, us.find(us.keysymOf('a'), 0).?);
    const upper = us.find(us.keysymOf('A'), 0).?;
    try testing.expectEqual(@as(u32, 30), upper.key);
    var names: [8][]const u8 = undefined;
    try testing.expectEqualStrings("Shift", us.modifierNames(upper.mods, &names)[0]);
    // No key types é in us: known before anything is sent.
    try testing.expect(us.find(us.keysymOf('é'), 0) == null);

    const fr = named(&lib, "fr") orelse return error.SkipZigTest;
    defer fr.deinit();
    // é is the unshifted 2 (KEY_2 is 3) in fr; @ is AltGr+0 (KEY_0 is 11).
    try testing.expectEqual(Stroke{ .key = 3, .mods = 0 }, fr.find(fr.keysymOf('é'), 0).?);
    const at = fr.find(fr.keysymOf('@'), 0).?;
    try testing.expectEqual(@as(u32, 11), at.key);
    try testing.expectEqualStrings("Mod5", fr.modifierNames(at.mods, &names)[0]);
    try testing.expectEqualStrings("French", fr.layoutName(0));
}

test "a keymap text compiles, and garbage does not" {
    var lib = Lib.load(library_name) orelse return error.SkipZigTest;
    var buf: [64]u8 = undefined;
    try testing.expect(Keymap.fromString(&lib, "xkb_keymap { garbage", &buf) == null);
}
