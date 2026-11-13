//! Human control shared by the dispatcher and the kill switch (US-018): the
//! cancellation flag of the running request, whether an action is running,
//! and the pause that only a physical gesture lifts (FR-12). The backend's
//! hook thread calls `trip` and `rearm`; no MCP tool can reach `rearm`.
//! An observer (the control indicator, US-034) hears of every change.
//!
//! In background mode (decision 0013, point 2) the user's mouse and Escape
//! are theirs: the hook thread calls neither `trip` nor `rearm`, and the
//! re-arm shortcut becomes `toggle`, which pauses a running server and
//! re-arms a paused one (US-045). FR-12 holds: only that physical shortcut
//! lifts a pause.

const std = @import("std");
const keys = @import("keys.zig");

/// The shortcut that lifts a pause, and in background mode sets it too,
/// unless `--rearm-key` names another.
pub const default_rearm: keys.Combo = .{ .mods = .{ .ctrl = true, .alt = true, .shift = true }, .key = .{ .char = 'r' } };

pub const paused_message = "En pause par l'utilisateur : attends qu'Arthur réarme";

/// Told of every change of `busy` or `paused`. `notify` runs on the
/// thread that made the change, the low-level hook thread included: it
/// must return within microseconds (post a message, set an event).
pub const Observer = struct {
    ctx: *anyopaque,
    notify: *const fn (*anyopaque) void,
};

pub const Control = struct {
    /// Set to stop the running tool at its next checkpoint.
    cancel: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    /// An action tool (settling included) is running.
    busy: std.atomic.Value(bool) = .init(false),
    /// The kill switch fired during the running action.
    tripped: std.atomic.Value(bool) = .init(false),
    /// Incremented when an action starts, so the hook thread restarts its
    /// mouse displacement count.
    epoch: std.atomic.Value(u32) = .init(0),
    observer: std.atomic.Value(?*const Observer) = .init(null),
    /// `--mode background`, set before the hook and indicator threads
    /// start: they read it to choose their behavior.
    background: std.atomic.Value(bool) = .init(false),

    pub const Toggled = enum { paused, rearmed };

    /// Installs or removes (null) the observer. Remove it before freeing it.
    pub fn observe(self: *Control, observer: ?*const Observer) void {
        self.observer.store(observer, .release);
    }

    fn changed(self: *Control) void {
        if (self.observer.load(.acquire)) |o| o.notify(o.ctx);
    }

    /// Kill switch: during an action, cancels it and pauses the server.
    /// Returns false (and does nothing) when no action runs.
    pub fn trip(self: *Control) bool {
        if (!self.busy.load(.acquire)) return false;
        self.paused.store(true, .release);
        self.tripped.store(true, .release);
        self.cancel.store(true, .release);
        self.changed();
        return true;
    }

    /// Physical re-arm shortcut. Returns whether the server was paused.
    pub fn rearm(self: *Control) bool {
        const was = self.paused.swap(false, .acq_rel);
        if (was) self.changed();
        return was;
    }

    /// Background mode: the physical shortcut pauses the server, cancelling
    /// the action that runs, or lifts the pause it set.
    pub fn toggle(self: *Control) Toggled {
        if (self.rearm()) return .rearmed;
        self.paused.store(true, .release);
        // An action that begins from now on reads `paused` and is refused;
        // one that runs stops at its next checkpoint.
        if (self.busy.load(.acquire)) {
            self.tripped.store(true, .release);
            self.cancel.store(true, .release);
        }
        self.changed();
        return .paused;
    }

    pub fn isPaused(self: *const Control) bool {
        return self.paused.load(.acquire);
    }

    /// Marks an action as running. Call after the request's cancellation
    /// flag was reset, so a trip from now on reaches the tool.
    pub fn beginAction(self: *Control) void {
        self.tripped.store(false, .release);
        _ = self.epoch.fetchAdd(1, .acq_rel);
        self.busy.store(true, .release);
        self.changed();
    }

    /// Ends the action; returns whether the kill switch fired during it.
    pub fn endAction(self: *Control) bool {
        self.busy.store(false, .release);
        const tripped = self.tripped.swap(false, .acq_rel);
        self.changed();
        return tripped;
    }
};

test "the observer hears every change of busy and paused" {
    const Count = struct {
        n: u32 = 0,
        fn notify(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
        }
    };
    var count: Count = .{};
    const observer: Observer = .{ .ctx = &count, .notify = Count.notify };
    var c: Control = .{};
    c.observe(&observer);
    c.beginAction();
    try std.testing.expect(c.trip());
    _ = c.endAction();
    try std.testing.expect(c.rearm());
    // Nothing changes: a trip outside an action, a re-arm without pause.
    try std.testing.expect(!c.trip());
    try std.testing.expect(!c.rearm());
    try std.testing.expectEqual(@as(u32, 4), count.n);
    c.observe(null);
    c.beginAction();
    try std.testing.expectEqual(@as(u32, 4), count.n);
}

test "toggle pauses a running server, cancels the action that runs and re-arms a paused one" {
    var c: Control = .{ .background = .init(true) };
    // At rest: paused, nothing to cancel.
    try std.testing.expectEqual(Control.Toggled.paused, c.toggle());
    try std.testing.expect(c.isPaused());
    try std.testing.expect(!c.cancel.load(.acquire));
    try std.testing.expectEqual(Control.Toggled.rearmed, c.toggle());
    try std.testing.expect(!c.isPaused());
    // During an action: it is cancelled and reported as stopped by the user.
    c.beginAction();
    try std.testing.expectEqual(Control.Toggled.paused, c.toggle());
    try std.testing.expect(c.cancel.load(.acquire));
    try std.testing.expect(c.endAction());
    try std.testing.expect(c.isPaused());
    try std.testing.expectEqual(Control.Toggled.rearmed, c.toggle());
}
