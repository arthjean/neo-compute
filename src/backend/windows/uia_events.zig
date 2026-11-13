//! UI Automation events of the target window (decision 0013, amendment of
//! 2026-11-13). A XAML application raises no WinEvent when its tree changes:
//! it raises UI Automation events, and only while a UI Automation client
//! listens. This module is that listener: four handler objects registered on
//! the target window's element, over its subtree.
//!
//! The handlers are the only COM objects the client implements. They are
//! static, never freed (their reference count is a constant) and free
//! threaded: a handler bumps a counter and returns, on whichever thread UI
//! Automation calls it. It makes no UI Automation call and reads no text:
//! what an event carries (a name, a value, a notification's string) is
//! never looked at.
//!
//! Registration and removal run on the UI Automation worker thread
//! (`uia.zig`), which owns the automation object.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const winevents = @import("winevents.zig");

/// Events received since the process started.
pub var count: std.atomic.Value(u64) = .init(0);
/// QueryPerformanceCounter of the last one.
pub var last_qpc: std.atomic.Value(i64) = .init(0);
/// Probe only: every event, the oldest overwritten. Set before the
/// subscription and cleared after its removal.
pub var log: ?[]winevents.Event = null;
pub var log_len: std.atomic.Value(usize) = .init(0);
/// Property events, and those whose value had a type UI Automation does not
/// send for the properties below: the VARIANT comes by value, and a wrong
/// read of that argument would show here.
pub var property_events: std.atomic.Value(u32) = .init(0);
pub var odd_variants: std.atomic.Value(u32) = .init(0);

/// What changes when a control's state does. The bounding rectangle is left
/// out: a scroll moves every element of a list.
const properties = [_]w.UIA_PROPERTY_ID{
    w.UIA_NamePropertyId,
    w.UIA_ValueValuePropertyId,
    w.UIA_IsEnabledPropertyId,
    w.UIA_IsOffscreenPropertyId,
    w.UIA_ToggleToggleStatePropertyId,
    w.UIA_ExpandCollapseExpandCollapseStatePropertyId,
    w.UIA_SelectionItemIsSelectedPropertyId,
    w.UIA_ItemStatusPropertyId,
};

const events = [_]w.UIA_EVENT_ID{
    w.UIA_LiveRegionChangedEventId,
    w.UIA_Text_TextChangedEventId,
    w.UIA_LayoutInvalidatedEventId,
};

fn note(id: w.UIA_EVENT_ID) void {
    var t: i64 = 0;
    _ = w.QueryPerformanceCounter(&t);
    last_qpc.store(t, .release);
    if (log) |l| {
        const i = log_len.fetchAdd(1, .acq_rel);
        l[i % l.len] = .{ .id = @intCast(id), .qpc = t };
    }
    _ = count.fetchAdd(1, .acq_rel);
}

const e_nointerface: w.HRESULT = @bitCast(@as(u32, 0x80004002));
const e_pointer: w.HRESULT = @bitCast(@as(u32, 0x80004003));
/// IAgileObject: the object may be called from any apartment as it is.
const iid_agile: w.GUID = .{ .Data1 = 0x94ea2b94, .Data2 = 0xe9cc, .Data3 = 0x49e0, .Data4 = .{ 0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90 } };

fn same(a: *const w.GUID, b: *const w.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// IUnknown of a static handler of interface `I`.
fn Unknown(comptime I: type) type {
    return struct {
        fn queryInterface(self: *I, riid: ?*const w.GUID, out: ?*?*anyopaque) callconv(.winapi) w.HRESULT {
            const o = out orelse return e_pointer;
            o.* = null;
            const id = riid orelse return e_nointerface;
            if (!same(id, &I.iid) and !same(id, &w.IUnknown.iid) and !same(id, &iid_agile)) return e_nointerface;
            o.* = self;
            return 0;
        }

        fn addRef(_: *I) callconv(.winapi) u32 {
            return 2;
        }

        fn release(_: *I) callconv(.winapi) u32 {
            return 1;
        }
    };
}

const Structure = w.IUIAutomationStructureChangedEventHandler;
const Property = w.IUIAutomationPropertyChangedEventHandler;
const Plain = w.IUIAutomationEventHandler;
const Notification = w.IUIAutomationNotificationEventHandler;

fn onStructure(_: *Structure, _: ?*w.IUIAutomationElement, _: w.StructureChangeType, _: ?*w.SAFEARRAY) callconv(.winapi) w.HRESULT {
    note(w.UIA_StructureChangedEventId);
    return 0;
}

fn onProperty(_: *Property, _: ?*w.IUIAutomationElement, _: w.UIA_PROPERTY_ID, value: w.VARIANT) callconv(.winapi) w.HRESULT {
    _ = property_events.fetchAdd(1, .monotonic);
    switch (value.Anonymous.Anonymous.vt) {
        w.VT_EMPTY, w.VT_I4, w.VT_BSTR, w.VT_BOOL, w.VT_UNKNOWN => {},
        else => _ = odd_variants.fetchAdd(1, .monotonic),
    }
    note(w.UIA_AutomationPropertyChangedEventId);
    return 0;
}

fn onEvent(_: *Plain, _: ?*w.IUIAutomationElement, id: w.UIA_EVENT_ID) callconv(.winapi) w.HRESULT {
    note(id);
    return 0;
}

fn onNotification(_: *Notification, _: ?*w.IUIAutomationElement, _: w.NotificationKind, _: w.NotificationProcessing, _: w.BSTR, _: w.BSTR) callconv(.winapi) w.HRESULT {
    note(w.UIA_NotificationEventId);
    return 0;
}

const structure_vtable: Structure.VTable = .{
    .QueryInterface = Unknown(Structure).queryInterface,
    .AddRef = Unknown(Structure).addRef,
    .Release = Unknown(Structure).release,
    .HandleStructureChangedEvent = onStructure,
};
const property_vtable: Property.VTable = .{
    .QueryInterface = Unknown(Property).queryInterface,
    .AddRef = Unknown(Property).addRef,
    .Release = Unknown(Property).release,
    .HandlePropertyChangedEvent = onProperty,
};
const event_vtable: Plain.VTable = .{
    .QueryInterface = Unknown(Plain).queryInterface,
    .AddRef = Unknown(Plain).addRef,
    .Release = Unknown(Plain).release,
    .HandleAutomationEvent = onEvent,
};
const notification_vtable: Notification.VTable = .{
    .QueryInterface = Unknown(Notification).queryInterface,
    .AddRef = Unknown(Notification).addRef,
    .Release = Unknown(Notification).release,
    .HandleNotificationEvent = onNotification,
};

var structure_handler: Structure = .{ .vtable = &structure_vtable };
var property_handler: Property = .{ .vtable = &property_vtable };
var event_handler: Plain = .{ .vtable = &event_vtable };
var notification_handler: Notification = .{ .vtable = &notification_vtable };

/// The handlers registered on one window.
pub const Subscription = struct {
    hwnd: w.HWND,
    element: *w.IUIAutomationElement,
    property: bool = false,
    events: [events.len]bool = @splat(false),
    notification: bool = false,
};

/// Registers the handlers on `hwnd`'s element and its subtree. Null when
/// the element cannot be read or the structure handler is refused: it is
/// the one a XAML application answers every change of its tree with. The
/// others are kept when they register.
pub fn add(automation: *w.IUIAutomation, hwnd: w.HWND) ?Subscription {
    var raw: ?*w.IUIAutomationElement = null;
    com.check(automation.vtable.ElementFromHandle(automation, hwnd, &raw)) catch return null;
    const el = raw orelse return null;
    com.check(automation.vtable.AddStructureChangedEventHandler(automation, el, w.TreeScope_Subtree, null, &structure_handler)) catch {
        com.release(el);
        return null;
    };
    var sub: Subscription = .{ .hwnd = hwnd, .element = el };
    var props = properties;
    sub.property = automation.vtable.AddPropertyChangedEventHandlerNativeArray(automation, el, w.TreeScope_Subtree, null, &property_handler, &props, props.len) >= 0;
    for (events, &sub.events) |id, *ok| ok.* = automation.vtable.AddAutomationEventHandler(automation, id, el, w.TreeScope_Subtree, null, &event_handler) >= 0;
    var raw5: ?*anyopaque = null;
    if (automation.vtable.QueryInterface(automation, &w.IUIAutomation5.iid, &raw5) >= 0) {
        const a5: *w.IUIAutomation5 = @ptrCast(@alignCast(raw5.?));
        defer com.release(a5);
        sub.notification = a5.vtable.AddNotificationEventHandler(a5, el, w.TreeScope_Subtree, null, &notification_handler) >= 0;
    }
    return sub;
}

/// Removes the handlers of `sub` and drops its element.
pub fn remove(automation: *w.IUIAutomation, sub: *const Subscription) void {
    const el = sub.element;
    _ = automation.vtable.RemoveStructureChangedEventHandler(automation, el, &structure_handler);
    if (sub.property) _ = automation.vtable.RemovePropertyChangedEventHandler(automation, el, &property_handler);
    for (events, sub.events) |id, ok| {
        if (ok) _ = automation.vtable.RemoveAutomationEventHandler(automation, id, el, &event_handler);
    }
    if (sub.notification) {
        var raw5: ?*anyopaque = null;
        if (automation.vtable.QueryInterface(automation, &w.IUIAutomation5.iid, &raw5) >= 0) {
            const a5: *w.IUIAutomation5 = @ptrCast(@alignCast(raw5.?));
            defer com.release(a5);
            _ = a5.vtable.RemoveNotificationEventHandler(a5, el, &notification_handler);
        }
    }
    com.release(el);
}
