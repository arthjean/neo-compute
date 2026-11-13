//! A control of the background test window that names a default action
//! and has no InvokePattern (US-051), as a Chromium element with a click
//! handler does.
//!
//! No standard Win32 control is in that case: UI Automation's proxies, and
//! its MSAA bridge over an oleacc object, give InvokePattern to everything
//! that has a default action (measured on Windows 11 26300: push button,
//! check box, radio button, list item, each with both). The control is
//! therefore a window with a UI Automation provider of its own, which
//! implements the LegacyIAccessible pattern and nothing else.
//!
//! The provider is one static object, never freed: it holds no state but
//! the count of default actions it ran.

const std = @import("std");
const w = @import("win32");

pub const label = "neo-compute legacy";
const default_action = "Activate";

/// Default actions the control ran.
pub var actions: std.atomic.Value(u32) = .init(0);

const Simple = w.IRawElementProviderSimple;
const Legacy = w.ILegacyIAccessibleProvider;

const e_nointerface: w.HRESULT = @bitCast(@as(u32, 0x80004002));
const e_pointer: w.HRESULT = @bitCast(@as(u32, 0x80004003));
const e_notimpl: w.HRESULT = @bitCast(@as(u32, 0x80004001));

var simple: Simple = .{ .vtable = &simple_vtable };
var legacy: Legacy = .{ .vtable = &legacy_vtable };
/// The window the provider stands for.
var host: w.HWND = null;

fn same(a: *const w.GUID, b: *const w.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// IUnknown of the one object behind both interfaces.
fn Unknown(comptime I: type) type {
    return struct {
        fn queryInterface(_: *I, riid: ?*const w.GUID, out: ?*?*anyopaque) callconv(.winapi) w.HRESULT {
            const o = out orelse return e_pointer;
            o.* = null;
            const id = riid orelse return e_nointerface;
            if (same(id, &Legacy.iid)) {
                o.* = &legacy;
            } else if (same(id, &Simple.iid) or same(id, &w.IUnknown.iid)) {
                o.* = &simple;
            } else return e_nointerface;
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

fn bstr(out: ?*w.BSTR, comptime text: ?[]const u8) w.HRESULT {
    const o = out orelse return e_pointer;
    o.* = if (text) |t| w.SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral(t)) else null;
    return 0;
}

fn providerOptions(_: *Simple, out: ?*w.ProviderOptions) callconv(.winapi) w.HRESULT {
    (out orelse return e_pointer).* = w.ProviderOptions_ServerSideProvider;
    return 0;
}

fn patternProvider(_: *Simple, pattern: w.UIA_PATTERN_ID, out: ?*?*w.IUnknown) callconv(.winapi) w.HRESULT {
    const o = out orelse return e_pointer;
    o.* = if (pattern == w.UIA_LegacyIAccessiblePatternId) @ptrCast(&legacy) else null;
    return 0;
}

fn propertyValue(_: *Simple, property: w.UIA_PROPERTY_ID, out: ?*w.VARIANT) callconv(.winapi) w.HRESULT {
    const v = out orelse return e_pointer;
    v.* = std.mem.zeroes(w.VARIANT);
    switch (property) {
        w.UIA_ControlTypePropertyId => {
            v.Anonymous.Anonymous.vt = w.VT_I4;
            v.Anonymous.Anonymous.Anonymous.lVal = w.UIA_CustomControlTypeId;
        },
        w.UIA_NamePropertyId => {
            v.Anonymous.Anonymous.vt = w.VT_BSTR;
            v.Anonymous.Anonymous.Anonymous.bstrVal = w.SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral(label));
        },
        w.UIA_IsControlElementPropertyId, w.UIA_IsContentElementPropertyId => {
            v.Anonymous.Anonymous.vt = w.VT_BOOL;
            v.Anonymous.Anonymous.Anonymous.boolVal = -1;
        },
        // The window's own provider answers the rest.
        else => {},
    }
    return 0;
}

fn hostProvider(_: *Simple, out: ?*?*Simple) callconv(.winapi) w.HRESULT {
    return w.UiaHostProviderFromHwnd(host, out orelse return e_pointer);
}

fn doDefaultAction(_: *Legacy) callconv(.winapi) w.HRESULT {
    _ = actions.fetchAdd(1, .acq_rel);
    return 0;
}

fn unsupportedSelect(_: *Legacy, _: i32) callconv(.winapi) w.HRESULT {
    return e_notimpl;
}

fn unsupportedSetValue(_: *Legacy, _: ?[*:0]const u16) callconv(.winapi) w.HRESULT {
    return e_notimpl;
}

fn noAccessible(_: *Legacy, out: ?*?*w.IAccessible) callconv(.winapi) w.HRESULT {
    (out orelse return e_pointer).* = null;
    return 0;
}

fn childId(_: *Legacy, out: ?*i32) callconv(.winapi) w.HRESULT {
    (out orelse return e_pointer).* = 0;
    return 0;
}

fn getName(_: *Legacy, out: ?*w.BSTR) callconv(.winapi) w.HRESULT {
    return bstr(out, label);
}

fn getEmpty(_: *Legacy, out: ?*w.BSTR) callconv(.winapi) w.HRESULT {
    return bstr(out, null);
}

fn getDefaultAction(_: *Legacy, out: ?*w.BSTR) callconv(.winapi) w.HRESULT {
    return bstr(out, default_action);
}

fn getRole(_: *Legacy, out: ?*u32) callconv(.winapi) w.HRESULT {
    (out orelse return e_pointer).* = w.ROLE_SYSTEM_GRAPHIC;
    return 0;
}

fn getState(_: *Legacy, out: ?*u32) callconv(.winapi) w.HRESULT {
    (out orelse return e_pointer).* = 0;
    return 0;
}

fn noSelection(_: *Legacy, out: ?*?*w.SAFEARRAY) callconv(.winapi) w.HRESULT {
    (out orelse return e_pointer).* = null;
    return 0;
}

const simple_vtable: Simple.VTable = .{
    .QueryInterface = Unknown(Simple).queryInterface,
    .AddRef = Unknown(Simple).addRef,
    .Release = Unknown(Simple).release,
    .get_ProviderOptions = providerOptions,
    .GetPatternProvider = patternProvider,
    .GetPropertyValue = propertyValue,
    .get_HostRawElementProvider = hostProvider,
};

const legacy_vtable: Legacy.VTable = .{
    .QueryInterface = Unknown(Legacy).queryInterface,
    .AddRef = Unknown(Legacy).addRef,
    .Release = Unknown(Legacy).release,
    .Select = unsupportedSelect,
    .DoDefaultAction = doDefaultAction,
    .SetValue = unsupportedSetValue,
    .GetIAccessible = noAccessible,
    .get_ChildId = childId,
    .get_Name = getName,
    .get_Value = getEmpty,
    .get_Description = getEmpty,
    .get_Role = getRole,
    .get_State = getState,
    .get_Help = getEmpty,
    .get_KeyboardShortcut = getEmpty,
    .GetSelection = noSelection,
    .get_DefaultAction = getDefaultAction,
};

fn proc(hwnd: w.HWND, msg: u32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (msg == w.WM_GETOBJECT and @as(i32, @truncate(lparam)) == w.UiaRootObjectId)
        return w.UiaReturnRawElementProvider(hwnd, wparam, lparam, &simple);
    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Creates the control as a child of `parent`, on the calling thread. Null
/// when the window cannot be created.
pub fn create(parent: w.HWND, instance: anytype, x: i32, y: i32, width: i32, height: i32) w.HWND {
    const class = std.unicode.utf8ToUtf16LeStringLiteral("NeoComputeLegacy");
    var wc = std.mem.zeroes(w.WNDCLASSEXW);
    wc.cbSize = @sizeOf(w.WNDCLASSEXW);
    wc.lpfnWndProc = proc;
    wc.hInstance = instance;
    wc.lpszClassName = class;
    _ = w.RegisterClassExW(&wc);
    host = w.CreateWindowExW(0, class, std.unicode.utf8ToUtf16LeStringLiteral(label), w.WS_CHILD | w.WS_VISIBLE, x, y, width, height, parent, null, instance, null);
    return host;
}
