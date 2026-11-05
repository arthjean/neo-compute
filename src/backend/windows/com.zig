//! COM helpers over the generated bindings.

const w = @import("win32");

pub const Error = error{ ElementNotAvailable, ComCallFailed };

/// HRESULT of the last failed call on this thread, for diagnostics.
pub threadlocal var last_hr: w.HRESULT = 0;

pub fn check(code: w.HRESULT) Error!void {
    if (code >= 0) return;
    last_hr = code;
    // The metadata types UIA_E_* as u32, unlike HRESULT; compare the bits.
    if (@as(u32, @bitCast(code)) == w.UIA_E_ELEMENTNOTAVAILABLE) return error.ElementNotAvailable;
    return error.ComCallFailed;
}

pub fn release(obj: anytype) void {
    _ = obj.vtable.Release(obj);
}

pub fn lastHr() u32 {
    return @bitCast(last_hr);
}

/// Whether the last failed call returned `code`, a metadata constant typed
/// `u32` (UIA_E_*). Taking `u32` rejects a signed HRESULT at compile time:
/// a u32/i32 comparison compiles in Zig and is never true for an error.
pub fn lastWas(code: u32) bool {
    return lastHr() == code;
}
