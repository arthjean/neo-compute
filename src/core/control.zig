//! Human control shared by the dispatcher and the kill switch (US-018): the
//! cancellation flag of the running request, whether an action is running,
//! and the pause that only a physical gesture lifts (FR-12). The backend's
//! hook thread calls `trip` and `rearm`; no MCP tool can reach `rearm`.

const std = @import("std");

pub const paused_message = "En pause par l'utilisateur : attends qu'Arthur réarme";

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

    /// Kill switch: during an action, cancels it and pauses the server.
    /// Returns false (and does nothing) when no action runs.
    pub fn trip(self: *Control) bool {
        if (!self.busy.load(.acquire)) return false;
        self.paused.store(true, .release);
        self.tripped.store(true, .release);
        self.cancel.store(true, .release);
        return true;
    }

    /// Physical re-arm shortcut. Returns whether the server was paused.
    pub fn rearm(self: *Control) bool {
        return self.paused.swap(false, .acq_rel);
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
    }

    /// Ends the action; returns whether the kill switch fired during it.
    pub fn endAction(self: *Control) bool {
        self.busy.store(false, .release);
        return self.tripped.swap(false, .acq_rel);
    }
};
