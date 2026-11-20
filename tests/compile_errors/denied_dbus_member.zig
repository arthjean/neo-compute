//! A denied D-Bus member written by hand, not generated, still fails the
//! build (FR-61): `dbus.buildCall` checks it at compile time.
const std = @import("std");
const dbus = @import("dbus");

const set_active: dbus.Method = .{ .interface = "org.gnome.ScreenSaver", .member = "SetActive", .in = "b", .out = "" };

export fn unlock() void {
    var fds: std.ArrayList(i32) = .empty;
    _ = dbus.buildCall(std.heap.page_allocator, 1, 0, "org.gnome.ScreenSaver", "/org/gnome/ScreenSaver", set_active, .{true}, &fds) catch {};
}
