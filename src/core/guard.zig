//! Foreground guard of the background mode (US-050; decision 0013, amendment
//! of 2026-11-13), the portable part: what the guard does when a window
//! comes in front of the user's during an action.
//!
//! No Windows signal says who caused a change of the foreground window, so
//! the guard attributes it. A window of the agent's target that comes in
//! front during the agent's own action, with no gesture of the user that can
//! change the foreground window, is the action's doing: the foreground goes
//! back to the user's window at once, on the backend's event thread, while
//! the tool may still be waiting (a provider's Invoke can stay blocked for
//! as long as the modal dialog it opened). Ordinary typing is no such
//! gesture: it changes no foreground window, and it is what would land in
//! the dialog. The dispatcher looks again when the action ends and names
//! the outcome, then leaves the guard armed for `linger_ms`.

const std = @import("std");

/// What the guard saw around an action, as the audit log records it.
/// `third_party`: another application came in front on its own.
/// `same_app`: the user was already in a window of the target's process.
/// `unknown`: without the input hooks nothing tells the user's own switch
/// from the application's. None of the three is restored.
pub const Outcome = enum { intact, restored, refused, user, third_party, same_app, unknown };

/// A gesture this long before the action still explains a foreground change
/// during it: Windows activates the window the user asked for a moment after
/// the click or the key.
pub const gesture_slack_ms = 500;

/// How long the guard stays armed after the action ended. A provider's
/// Invoke may return at once and the dialog it asked for come in front
/// afterwards, when no tool is running any more. The dispatcher says what
/// happened in the result of the next call.
pub const linger_ms = 2000;

/// Restorations per action. A target that takes the foreground again each
/// time is left in front: the guard never fights over it.
pub const max_restores = 3;

/// The guard around one action. The dispatcher arms it, the backend's event
/// thread calls `onForeground` and `done`, and the backend serializes the
/// two: no field is read by one side while the other writes it.
pub const Watch = struct {
    /// The window that had the foreground when the action began.
    prev: u64,
    /// The session's target window when the action began, 0 for none.
    target: u64 = 0,
    restores: u8 = 0,
    /// The last restoration put `prev` back in front.
    restored: bool = false,
    /// A restoration ran on the foreground event, before the action ended.
    early: bool = false,
    /// Process of the window the event thread took the foreground from.
    taker_pid: u32 = 0,
    /// Longest restoration, in nanoseconds.
    restore_ns: u64 = 0,
    /// Longest time a window of the target stayed in front, from the
    /// foreground event to the end of its restoration, in nanoseconds.
    exposed_ns: u64 = 0,

    pub const Decision = enum { ignore, restore };

    /// `window` came to the foreground during the action. `taker`, `target`
    /// and `home` are the processes of `window`, of the session's target and
    /// of `prev` (the application a UWP frame hosts); `gesture`: whether the
    /// user made a gesture that can change the foreground window, null
    /// without the input hooks.
    pub fn onForeground(self: *Watch, window: u64, taker: ?u32, target: ?u32, home: ?u32, gesture: ?bool) Decision {
        if (window == self.prev) return .ignore;
        // Unknown counts as the user's: never fight the user.
        if (gesture orelse true) return .ignore;
        const pid = taker orelse return .ignore;
        if (target == null or target.? != pid) return .ignore;
        if (home != null and home.? == pid) return .ignore;
        if (self.restores >= max_restores) return .ignore;
        self.taker_pid = pid;
        self.early = true;
        return .restore;
    }

    /// A restoration ended: `ok` when `prev` is in front again.
    pub fn done(self: *Watch, ok: bool, ns: u64) void {
        self.restores += 1;
        self.restored = ok;
        self.restore_ns = @max(self.restore_ns, ns);
    }
};

test "a window of the target that comes in front without a gesture of the user is sent back, three times at most" {
    var w: Watch = .{ .prev = 1, .target = 2 };
    try std.testing.expectEqual(Watch.Decision.restore, w.onForeground(3, 42, 42, 7, false));
    try std.testing.expect(w.early);
    try std.testing.expectEqual(@as(u32, 42), w.taker_pid);
    w.done(true, 5);
    w.done(true, 9);
    try std.testing.expectEqual(Watch.Decision.restore, w.onForeground(3, 42, 42, 7, false));
    w.done(false, 2);
    try std.testing.expectEqual(@as(u64, 9), w.restore_ns);
    try std.testing.expect(!w.restored);
    try std.testing.expectEqual(Watch.Decision.ignore, w.onForeground(3, 42, 42, 7, false));
}

test "the user's own switch, another application, the user's own application and the echo of a restoration are left alone" {
    var w: Watch = .{ .prev = 1, .target = 2 };
    // The user's window again: the echo of a restoration.
    try std.testing.expectEqual(Watch.Decision.ignore, w.onForeground(1, 7, 42, 7, false));
    // The user clicked or pressed Alt+Tab; or no hook can tell.
    try std.testing.expectEqual(Watch.Decision.ignore, w.onForeground(3, 42, 42, 7, true));
    try std.testing.expectEqual(Watch.Decision.ignore, w.onForeground(3, 42, 42, 7, null));
    // Another application, a window that is already gone, no target yet.
    try std.testing.expectEqual(Watch.Decision.ignore, w.onForeground(3, 99, 42, 7, false));
    try std.testing.expectEqual(Watch.Decision.ignore, w.onForeground(3, null, 42, 7, false));
    try std.testing.expectEqual(Watch.Decision.ignore, w.onForeground(3, 42, null, 7, false));
    // The user works in the target's own application.
    try std.testing.expectEqual(Watch.Decision.ignore, w.onForeground(3, 42, 42, 42, false));
    try std.testing.expect(!w.early);
    try std.testing.expectEqual(@as(u8, 0), w.restores);
}
