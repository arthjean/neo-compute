//! State kept across requests: the display whose screenshot defines the
//! coordinate space (FR-03), the mapping of every captured display, and the
//! buffers of the image pipeline.

const std = @import("std");
const display = @import("display.zig");
const image = @import("image.zig");
const jpeg = @import("jpeg.zig");
const uitree = @import("uitree.zig");
const policy = @import("policy.zig");
const Mapping = display.Mapping;

/// What an action tool returns once the screen has settled (US-015).
pub const Observe = enum {
    delta,
    screenshot,
    none,
    /// Without `"type"`: the enum says it all, and the 15 action tools that
    /// repeat this schema stay within the definition budget.
    pub const json_schema = "{\"enum\":[\"delta\",\"screenshot\",\"none\"]}";
};

/// Period of the tree re-read under the background mode's settling
/// (US-048). US-047 measured that Calculator and Settings do not signal
/// every tree change by a WinEvent (A18 refuted, decision 0013): 250 ms,
/// where a validated A18 would have allowed 1 s.
pub const reread_floor_ms = 250;

pub const Session = struct {
    gpa: std.mem.Allocator,
    long_side: u32 = display.default_long_side,
    /// Display of the latest screenshot; incoming coordinates refer to it.
    current: ?usize = null,
    /// Mapping of the latest screenshot of each display.
    shots: [display.max_displays]?Mapping = @splat(null),
    reducer: image.Reducer = .{},
    encoder: jpeg.Encoder = .{},
    /// Element ids and the last tree shown per window.
    ui: uitree.State = .{},
    /// Observation of action tools without `observe`.
    default_observe: Observe = .delta,
    /// `--mode background` (decision 0013): no tool reads or takes the
    /// foreground, and a tool without `window` works on `target`.
    background: bool = false,
    /// The window the agent works on (US-042): the last one a `window`
    /// argument named, or the one app_launch returned.
    target: ?u64 = null,
    /// Control level per application (US-017) and its pid cache.
    policy: *const policy.Policy = &policy.defaults,
    apps: policy.Cache = .{},
    /// Start menu applications for app_launch (US-028).
    catalog: @import("apps.zig").Catalog = .{},
    /// How long app_launch waits for a window (US-029) and window_set for a
    /// close before `force` (US-027); tests shorten them.
    launch_wait_ms: u32 = 10_000,
    close_wait_ms: u32 = 2000,
    /// Period of the settling floor; tests shorten it.
    reread_ms: u32 = reread_floor_ms,
    /// How long ui_act waits for a disabled element (US-054) and reads an
    /// action's effect back (US-055); tests shorten them.
    enable_wait_ms: u32 = 2000,
    verify_ms: u32 = 400,
    /// Time the last ui_act spent reading its effect back (US-055).
    verify_ns: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, long_side: u32) Session {
        return .{ .gpa = gpa, .long_side = long_side };
    }

    pub fn deinit(self: *Session) void {
        self.reducer.deinit(self.gpa);
        self.encoder.deinit(self.gpa);
        self.ui.deinit(self.gpa);
        self.catalog.deinit();
    }

    pub const Resolved = union(enum) { ok: Mapping, err: []const u8 };

    /// Mapping of display `index` among `displays`. A display whose geometry
    /// changed since its last screenshot (resolution, removal) is reported
    /// instead of silently remapping the model's coordinates.
    pub fn resolve(self: *Session, arena: std.mem.Allocator, displays: []const display.Display, index: usize) Resolved {
        if (displays.len == 0) return .{ .err = "Aucun écran détecté : vérifie qu'un écran est allumé, puis refais un screenshot." };
        if (index >= displays.len or index >= display.max_displays) {
            if (self.shots[@min(index, display.max_displays - 1)] != null)
                return .{ .err = fmt(arena, "Écran {d} déconnecté : refais un screenshot.", .{index}) };
            return .{ .err = fmt(arena, "Écran {d} inexistant : écrans valides 0..{d}.", .{ index, displays.len - 1 }) };
        }
        const now = Mapping.of(index, displays[index].rect, self.long_side);
        if (self.shots[index]) |shot| if (!shot.rect.eql(now.rect))
            return .{ .err = fmt(arena, "Écran {d} modifié (résolution ou position) : refais un screenshot.", .{index}) };
        return .{ .ok = now };
    }

    /// Records a screenshot of `m.display`: its space becomes the one of
    /// incoming coordinates.
    pub fn recordShot(self: *Session, m: Mapping) void {
        self.shots[m.display] = m;
        self.current = m.display;
    }

    /// Forgets the mapping of a display whose geometry changed, so the next
    /// screenshot re-establishes it.
    pub fn forget(self: *Session, index: usize) void {
        if (index < display.max_displays) self.shots[index] = null;
    }
};

pub fn fmt(arena: std.mem.Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, f, args) catch "Mémoire insuffisante : réessaie.";
}
