//! The portable core as one module (`core` in build.zig): every file of
//! src/core/ that a backend or main.zig uses, re-exported by name. No file
//! here imports a file of src/backend/; the tests reach the fake backend
//! through the `fake` module, which the test build alone adds.

pub const a11y = @import("a11y.zig");
pub const actions = @import("actions.zig");
pub const apps = @import("apps.zig");
pub const audit = @import("audit.zig");
pub const bench = @import("bench.zig");
pub const clipboard = @import("clipboard.zig");
pub const control = @import("control.zig");
pub const counting_allocator = @import("counting_allocator.zig");
pub const display = @import("display.zig");
pub const guard = @import("guard.zig");
pub const image = @import("image.zig");
pub const indicator = @import("indicator.zig");
pub const input = @import("input.zig");
pub const jpeg = @import("jpeg.zig");
pub const keys = @import("keys.zig");
pub const launch = @import("launch.zig");
pub const marks = @import("marks.zig");
pub const mcp = @import("mcp.zig");
pub const policy = @import("policy.zig");
pub const registry = @import("registry.zig");
pub const regread = @import("regread.zig");
pub const screen = @import("screen.zig");
pub const session = @import("session.zig");
pub const timing = @import("timing.zig");
pub const tokens = @import("tokens.zig");
pub const tools = @import("tools.zig");
pub const uitree = @import("uitree.zig");
pub const windowctl = @import("windowctl.zig");

test {
    _ = @import("mcp_test.zig");
    _ = @import("registry_test.zig");
    _ = @import("bench_test.zig");
    _ = @import("tokens.zig");
    _ = @import("display.zig");
    _ = @import("image.zig");
    _ = @import("marks.zig");
    _ = @import("jpeg.zig");
    _ = @import("keys.zig");
    _ = @import("tools_test.zig");
    _ = @import("uitree.zig");
    _ = @import("a11y_test.zig");
    _ = @import("perception_test.zig");
    _ = @import("lag_test.zig");
    _ = @import("act_test.zig");
    _ = @import("policy.zig");
    _ = @import("control.zig");
    _ = @import("guard.zig");
    _ = @import("indicator.zig");
    _ = @import("audit.zig");
    _ = @import("security_test.zig");
    _ = @import("apps.zig");
    _ = @import("launch.zig");
    _ = @import("windows_test.zig");
    _ = @import("clipboard.zig");
    _ = @import("regread.zig");
    _ = @import("system_test.zig");
    _ = @import("background_test.zig");
    _ = @import("capture_test.zig");
    _ = @import("texts_test.zig");
    _ = @import("fake");
}
