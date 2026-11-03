//! Portable input events the tools hand to the backend. Coordinates are
//! physical pixels of the virtual desktop.

pub const Button = enum { left, right, middle };

pub const MouseEvent = union(enum) {
    move: [2]i32,
    down: Button,
    up: Button,
    /// Wheel clicks; positive is up (vertical) or right (horizontal).
    wheel: struct { horizontal: bool, clicks: i32 },
};

/// What a key action does with the combination.
pub const KeyAction = enum { tap, press, release };

/// Result of checking the window an action would reach.
pub const Target = enum { ok, elevated };

/// Largest number of UTF-16 units handed to `typeText` per call; each unit
/// is a key down and a key up, so a batch is at most 64 input events.
pub const type_batch_units = 32;

pub const InputError = error{
    /// The system refused the injection (another desktop is active, or
    /// SendInput was blocked).
    InputBlocked,
    /// The character has no key on the active layout.
    Unmappable,
};
