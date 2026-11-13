//! Per-request stage timings on the monotonic clock, plus allocation counts
//! per stage when a counting allocator is attached. Fixed-size, so recording
//! never allocates.

const std = @import("std");
const Io = std.Io;
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;

/// `settle` (waiting for the screen to stop changing, US-015) is reported
/// apart and kept out of totals and budgets. `policy` is the target
/// resolution of US-017, `mask` the wait for password rectangles and the
/// blackout of US-017 and US-019, `catalog` the Start menu enumeration and
/// name matching of US-028, `marks` the layout and drawing of element ids on
/// an image (US-031).
pub const Stage = enum { parse, dispatch, capture, reduce, encode, accessibility, diff, windows, policy, mask, settle, serialize, write, catalog, marks, guard };
pub const stage_count = @typeInfo(Stage).@"enum".field_names.len;

pub fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).toNanoseconds();
}

pub const Timings = struct {
    ns: [stage_count]u64 = @splat(0),
    allocs: [stage_count]u64 = @splat(0),
    used: [stage_count]bool = @splat(false),
    started: [stage_count]i96 = @splat(0),
    alloc_start: [stage_count]u64 = @splat(0),
    counter: ?*const CountingAllocator = null,

    /// Clears the previous request.
    pub fn begin(self: *Timings, io: Io) void {
        _ = io;
        self.ns = @splat(0);
        self.allocs = @splat(0);
        self.used = @splat(false);
    }

    pub fn start(self: *Timings, io: Io, stage: Stage) void {
        const i = @backingInt(stage);
        if (self.counter) |c| self.alloc_start[i] = c.count();
        self.started[i] = now(io);
    }

    pub fn stop(self: *Timings, io: Io, stage: Stage) void {
        const i = @backingInt(stage);
        const elapsed = now(io) - self.started[i];
        self.ns[i] += @intCast(@max(elapsed, 0));
        self.used[i] = true;
        if (self.counter) |c| self.allocs[i] += c.count() - self.alloc_start[i];
    }

    pub fn get(self: *const Timings, stage: Stage) u64 {
        return self.ns[@backingInt(stage)];
    }
};
