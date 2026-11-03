//! UI Automation snapshot through one cached round trip
//! (IUIAutomationCacheRequest + FindAllBuildCache). The caller must have
//! initialized COM in the multithreaded apartment on this thread.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const check = com.check;
const release = com.release;

pub const Error = com.Error;

pub const Element = struct {
    name: []const u8,
    control_type: i32,
    rect: w.RECT,
};

pub const Uia = struct {
    automation: *w.IUIAutomation,
    cache: *w.IUIAutomationCacheRequest,
    control_view: *w.IUIAutomationCondition,

    pub fn init() Error!Uia {
        var raw: ?*anyopaque = null;
        try check(w.CoCreateInstance(&w.CLSID_CUIAutomation, null, w.CLSCTX_INPROC_SERVER, &w.IUIAutomation.iid, &raw));
        const automation: *w.IUIAutomation = @ptrCast(@alignCast(raw.?));
        errdefer release(automation);
        var cache: ?*w.IUIAutomationCacheRequest = null;
        try check(automation.vtable.CreateCacheRequest(automation, &cache));
        errdefer release(cache.?);
        for ([_]w.UIA_PROPERTY_ID{ w.UIA_NamePropertyId, w.UIA_ControlTypePropertyId, w.UIA_BoundingRectanglePropertyId }) |p|
            try check(cache.?.vtable.AddProperty(cache.?, p));
        var cond: ?*w.IUIAutomationCondition = null;
        try check(automation.vtable.get_ControlViewCondition(automation, &cond));
        return .{ .automation = automation, .cache = cache.?, .control_view = cond.? };
    }

    pub fn deinit(self: *Uia) void {
        release(self.control_view);
        release(self.cache);
        release(self.automation);
    }

    /// Reads the window's element and its control-view descendants. Each
    /// element is passed to `visit` (names are only valid during the call).
    /// Returns the element count.
    pub fn snapshot(self: *Uia, hwnd: w.HWND, visit: anytype) Error!usize {
        var root: ?*w.IUIAutomationElement = null;
        try check(self.automation.vtable.ElementFromHandleBuildCache(self.automation, hwnd, self.cache, &root));
        const r = root orelse return error.ElementNotAvailable;
        defer release(r);
        try emit(r, visit);
        var arr: ?*w.IUIAutomationElementArray = null;
        try check(r.vtable.FindAllBuildCache(r, w.TreeScope_Descendants, self.control_view, self.cache, &arr));
        // A destroyed window still answers FindAllBuildCache with S_OK and an
        // empty array; only a live read reports UIA_E_ELEMENTNOTAVAILABLE.
        var live: w.BSTR = null;
        try check(r.vtable.get_CurrentName(r, &live));
        w.SysFreeString(live);
        const array = arr orelse return 1;
        defer release(array);
        var len: i32 = 0;
        try check(array.vtable.get_Length(array, &len));
        var i: i32 = 0;
        while (i < len) : (i += 1) {
            var el: ?*w.IUIAutomationElement = null;
            try check(array.vtable.GetElement(array, i, &el));
            defer release(el.?);
            try emit(el.?, visit);
        }
        return @as(usize, @intCast(len)) + 1;
    }

    fn emit(el: *w.IUIAutomationElement, visit: anytype) Error!void {
        var name: w.BSTR = null;
        try check(el.vtable.get_CachedName(el, &name));
        defer w.SysFreeString(name);
        var control_type: w.UIA_CONTROLTYPE_ID = 0;
        try check(el.vtable.get_CachedControlType(el, &control_type));
        var rect: w.RECT = undefined;
        try check(el.vtable.get_CachedBoundingRectangle(el, &rect));
        var utf8: [512]u8 = undefined;
        const wide: []const u16 = if (name) |n| n[0..w.SysStringLen(name)] else &.{};
        const len = std.unicode.wtf16LeToWtf8(&utf8, wide[0..@min(wide.len, utf8.len / 3)]);
        visit.element(.{ .name = utf8[0..len], .control_type = @intCast(control_type), .rect = rect });
    }
};

/// Visitor that ignores elements (latency measurements).
pub const discard = struct {
    pub fn element(_: @This(), _: Element) void {}
}{};
