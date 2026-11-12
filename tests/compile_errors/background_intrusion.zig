//! Must fail to compile: a tool listed in the background mode whose
//! intrusion class is not `none` (US-041). `click` declares no class, which
//! means `input`.
const registry = @import("registry");

const reader = struct {
    pub const name = "reader";
    pub const description = "Reads.";
    pub const annotations = .{ .read_only = true, .intrusion = .none };
    pub const background = true;
    pub const Args = struct {};
};

const click = struct {
    pub const name = "click";
    pub const description = "Clicks.";
    pub const background = true;
    pub const Args = struct {};
};

comptime {
    _ = registry.Background(.{ reader, click }).list_result;
}
