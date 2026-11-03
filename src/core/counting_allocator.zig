//! Allocator wrapper that counts calls reaching the backing allocator. Used
//! by tests and the bench to prove the hot path does not allocate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const CountingAllocator = struct {
    backing: Allocator,
    /// alloc, growing resize and remap calls.
    allocations: std.atomic.Value(u64) = .init(0),

    pub fn init(backing: Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn count(self: *const CountingAllocator) u64 {
        return self.allocations.load(.acquire);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.allocations.fetchAdd(1, .acq_rel);
        return self.backing.rawAlloc(len, alignment, ret);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) _ = self.allocations.fetchAdd(1, .acq_rel);
        return self.backing.rawResize(memory, alignment, new_len, ret);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) _ = self.allocations.fetchAdd(1, .acq_rel);
        return self.backing.rawRemap(memory, alignment, new_len, ret);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret);
    }
};
