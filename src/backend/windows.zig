//! Windows backend. Perception and action tools land in EP-002 and EP-003;
//! this file already carries the process setup, the selftest and the bench
//! scenarios that measure the platform primitives.

const std = @import("std");
const w = @import("win32");
const bench = @import("../core/bench.zig");
const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;

pub const Windows = struct {
    /// No tool can hold a key or button yet (hold_key, left_mouse_down and
    /// friends arrive with US-008/US-009, along with the held-input registry
    /// this releases).
    pub fn releaseAllInputs(self: *Windows) void {
        _ = self;
    }

    /// Per-monitor v2 DPI awareness, before any window exists, so Win32,
    /// DXGI and UI Automation all report physical pixels.
    pub fn initProcess() void {
        if (w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == 0) {
            // ERROR_ACCESS_DENIED means awareness was already set (manifest).
            if (w.GetLastError() != w.ERROR_ACCESS_DENIED)
                std.debug.print("neo-compute: SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2) failed: {d}\n", .{w.GetLastError()});
        }
    }

    pub const selftest = @import("windows/selftest.zig").run;

    pub fn benchScenario(gpa: std.mem.Allocator, io: std.Io, counter: *CountingAllocator, name: []const u8, iterations: ?usize) !bench.Outcome {
        return @import("windows/bench.zig").run(gpa, io, counter, name, iterations);
    }
};
