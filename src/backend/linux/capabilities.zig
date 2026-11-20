//! The Linux capability table (T1). US-081 composes it from the detected
//! compositor family and writes it on stderr; this story fills the row the
//! transports alone decide: the keyboard, present only when libxkbcommon
//! loads (US-080, P7). An absent capability names its cause and the next
//! action (FR-06).

const std = @import("std");
const xkb = @import("wire/xkb.zig");

pub const Table = struct {
    /// Keys and text through EI, translated by the active XKB layout.
    keyboard: bool = false,

    /// The refusal of a tool that needs an absent capability, or null.
    pub fn refusal(t: Table, tool: []const u8) ?[]const u8 {
        const keyboard_tools = [_][]const u8{ "type", "key", "hold_key" };
        for (keyboard_tools) |k| if (std.mem.eql(u8, k, tool)) {
            if (!t.keyboard) return xkb.missing_text;
        };
        return null;
    }

    /// One line per row, `name: yes` or `name: no (cause)`.
    pub fn write(t: Table, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (t.keyboard)
            try w.writeAll("keyboard: yes\n")
        else
            try w.print("keyboard: no ({s})\n", .{xkb.missing_text});
    }
};

test "the keyboard row and its refusal follow libxkbcommon" {
    const testing = std.testing;
    const without: Table = .{};
    try testing.expectEqualStrings(xkb.missing_text, without.refusal("type").?);
    try testing.expectEqualStrings(xkb.missing_text, without.refusal("key").?);
    try testing.expect(without.refusal("left_click") == null);
    const with: Table = .{ .keyboard = true };
    try testing.expect(with.refusal("type") == null);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try without.write(&w);
    try testing.expectEqualStrings("keyboard: no (libxkbcommon introuvable : installe-la pour taper du texte.)\n", w.buffered());
}
