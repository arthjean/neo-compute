//! In-memory backend for testing the portable core on any OS.

pub const Fake = struct {
    /// Inputs currently held (keys or buttons), as a count.
    held: u32 = 0,
    release_calls: u32 = 0,

    pub fn releaseAllInputs(self: *Fake) void {
        self.held = 0;
        self.release_calls += 1;
    }
};
