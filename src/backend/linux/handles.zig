//! Window handles of the Linux backend (decision 0014, D7; T14). The
//! contract keeps window ids as integers shown in hexadecimal; a compositor
//! names its windows otherwise (a Mutter window id, a KWin UUID, a
//! foreign-toplevel identifier). This table gives each compositor window a
//! `u64` handle for the session and never hands the same handle out twice
//! in the life of the process, so a handle of a closed window can never
//! name another one: it stays unknown, and the tools answer with their
//! closed-window message.

const std = @import("std");

pub const Table = struct {
    gpa: std.mem.Allocator,
    /// Compositor id of each open window, by handle.
    by_handle: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    /// Handle of each open window, by compositor id (the same bytes as the
    /// value of `by_handle`).
    by_id: std.StringHashMapUnmanaged(u64) = .empty,
    /// The next handle: only ever grows, from 1 (0 is no window).
    next: u64 = 1,

    pub fn init(gpa: std.mem.Allocator) Table {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Table) void {
        var it = self.by_handle.valueIterator();
        while (it.next()) |id| self.gpa.free(id.*);
        self.by_handle.deinit(self.gpa);
        self.by_id.deinit(self.gpa);
    }

    /// The handle of the open window the compositor names `id`: the one it
    /// already has, else a new one.
    pub fn handleOf(self: *Table, id: []const u8) error{OutOfMemory}!u64 {
        if (self.by_id.get(id)) |h| return h;
        const own = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(own);
        try self.by_handle.ensureUnusedCapacity(self.gpa, 1);
        try self.by_id.ensureUnusedCapacity(self.gpa, 1);
        const h = self.next;
        self.next += 1;
        self.by_handle.putAssumeCapacityNoClobber(h, own);
        self.by_id.putAssumeCapacityNoClobber(own, h);
        return h;
    }

    /// The compositor id of an open window, null for a handle never handed
    /// out or one whose window closed.
    pub fn idOf(self: *const Table, handle: u64) ?[]const u8 {
        return self.by_handle.get(handle);
    }

    /// The window the compositor names `id` closed: its handle becomes
    /// unknown for good, and a later window of the same id gets a new one.
    pub fn closed(self: *Table, id: []const u8) void {
        const kv = self.by_id.fetchRemove(id) orelse return;
        _ = self.by_handle.remove(kv.value);
        self.gpa.free(kv.key);
    }

    pub fn count(self: *const Table) usize {
        return self.by_handle.count();
    }
};

const testing = std.testing;

test "a handle is never handed out twice over 10,000 windows, ids reused or not" {
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(testing.allocator);
    var open: std.ArrayList(struct { id: []const u8, handle: u64 }) = .empty;
    defer {
        for (open.items) |w| testing.allocator.free(w.id);
        open.deinit(testing.allocator);
    }
    var closed_handles: std.ArrayList(u64) = .empty;
    defer closed_handles.deinit(testing.allocator);
    var prng: std.Random.DefaultPrng = .init(0x9e3779b97f4a7c15);
    const random = prng.random();
    for (0..10_000) |i| {
        // A Mutter id comes back after a while: half the windows reuse an
        // id of a window that closed.
        const reuse = i > 0 and random.boolean();
        const id = try std.fmt.allocPrint(testing.allocator, "mutter:{d}", .{if (reuse) random.uintLessThan(usize, i) else i});
        // The same open window keeps its handle.
        const h = try table.handleOf(id);
        try testing.expectEqual(h, try table.handleOf(id));
        if (table.count() > open.items.len) {
            try testing.expect(!seen.contains(h));
            try seen.put(testing.allocator, h, {});
            try open.append(testing.allocator, .{ .id = id, .handle = h });
        } else testing.allocator.free(id);
        // A third of the time a window closes.
        if (open.items.len > 0 and random.uintLessThan(u8, 3) == 0) {
            const w = open.swapRemove(random.uintLessThan(usize, open.items.len));
            table.closed(w.id);
            try closed_handles.append(testing.allocator, w.handle);
            testing.allocator.free(w.id);
        }
    }
    try testing.expect(seen.count() > 5_000);
    for (closed_handles.items) |h| try testing.expectEqual(@as(?[]const u8, null), table.idOf(h));
    for (open.items) |w| try testing.expectEqualStrings(w.id, table.idOf(w.handle).?);
    try testing.expectEqual(@as(?[]const u8, null), table.idOf(0));
    try testing.expectEqual(@as(?[]const u8, null), table.idOf(table.next));
}
