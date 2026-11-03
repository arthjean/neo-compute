//! Tool declarations. The first 17 mirror `computer_toolset_20260801`
//! (names and parameters), the last 5 are neo-compute's accessibility and
//! window tools. Each `run` receives a `*Ctx(Backend)` and returns a Result.

const std = @import("std");
const Result = @import("mcp.zig").Result;

const Point = [2]i32;

const coordinate_info = .{ .description = "[x, y] in screenshot pixels" };
const modifier_info = .{ .description = "Held modifiers, e.g. shift or ctrl+shift" };

/// Behavior lands with the Windows perception and action epics; until then
/// the tool is listed and validated but reports that it is unavailable.
fn unavailable(ctx: anytype, comptime name: []const u8, comptime story: []const u8) Result {
    _ = ctx;
    return Result.err(name ++ " : pas encore disponible sur ce serveur (" ++ story ++ "). Aucune action exécutée.");
}

pub const screenshot = struct {
    pub const name = "screenshot";
    pub const description = "Capture the display as a JPEG image.";
    pub const annotations = .{ .read_only = true, .idempotent = true, .always_load = true };
    pub const Args = struct {};
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-007");
    }
};

pub const zoom = struct {
    pub const name = "zoom";
    pub const description = "Return a region of the last screenshot at full resolution.";
    pub const annotations = .{ .read_only = true, .idempotent = true };
    pub const Args = struct {
        region: [4]i32,
        pub const field_info = .{ .region = .{ .description = "[x0, y0, x1, y1] in screenshot pixels" } };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-007");
    }
};

fn ClickTool(comptime tool_name: []const u8, comptime desc: []const u8, comptime always: bool) type {
    return struct {
        pub const name = tool_name;
        pub const description = desc;
        pub const annotations = .{ .always_load = always };
        pub const Args = struct {
            coordinate: ?Point = null,
            text: ?[]const u8 = null,
            pub const field_info = .{ .coordinate = coordinate_info, .text = modifier_info };
        };
        pub fn run(ctx: anytype, args: Args) Result {
            _ = args;
            return unavailable(ctx, name, "US-008");
        }
    };
}

pub const left_click = ClickTool("left_click", "Left click at coordinate, or at the cursor when omitted.", true);
pub const right_click = ClickTool("right_click", "Right click at coordinate, or at the cursor.", false);
pub const middle_click = ClickTool("middle_click", "Middle click at coordinate, or at the cursor.", false);
pub const double_click = ClickTool("double_click", "Double click at coordinate, or at the cursor.", false);
pub const triple_click = ClickTool("triple_click", "Triple click at coordinate, or at the cursor.", false);

pub const left_click_drag = struct {
    pub const name = "left_click_drag";
    pub const description = "Press at start_coordinate, drag to coordinate, release.";
    pub const Args = struct {
        start_coordinate: Point,
        coordinate: Point,
        text: ?[]const u8 = null,
        pub const field_info = .{ .start_coordinate = coordinate_info, .coordinate = coordinate_info, .text = modifier_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-008");
    }
};

pub const mouse_move = struct {
    pub const name = "mouse_move";
    pub const description = "Move the cursor without clicking.";
    pub const Args = struct {
        coordinate: Point,
        pub const field_info = .{ .coordinate = coordinate_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-008");
    }
};

fn BareTool(comptime tool_name: []const u8, comptime desc: []const u8, comptime story: []const u8, comptime ann: anytype) type {
    return struct {
        pub const name = tool_name;
        pub const description = desc;
        pub const annotations = ann;
        pub const Args = struct {};
        pub fn run(ctx: anytype, args: Args) Result {
            _ = args;
            return unavailable(ctx, name, story);
        }
    };
}

pub const left_mouse_down = BareTool("left_mouse_down", "Press the left button at the cursor.", "US-008", .{});
pub const left_mouse_up = BareTool("left_mouse_up", "Release the left button at the cursor.", "US-008", .{});
pub const cursor_position = BareTool("cursor_position", "Report the cursor position in screenshot pixels.", "US-008", .{ .read_only = true, .idempotent = true });

pub const scroll = struct {
    pub const name = "scroll";
    pub const description = "Scroll at coordinate, or at the cursor.";
    pub const annotations = .{ .always_load = true };
    pub const Args = struct {
        scroll_direction: enum { up, down, left, right },
        scroll_amount: u32,
        coordinate: ?Point = null,
        text: ?[]const u8 = null,
        pub const field_info = .{
            .scroll_amount = .{ .description = "Wheel clicks", .minimum = 1, .maximum = 100 },
            .coordinate = coordinate_info,
            .text = modifier_info,
        };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-008");
    }
};

pub const @"type" = struct {
    pub const name = "type";
    pub const description = "Type literal text at the keyboard focus.";
    pub const annotations = .{ .always_load = true };
    pub const Args = struct { text: []const u8 };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-009");
    }
};

pub const key = struct {
    pub const name = "key";
    pub const description = "Press a key or +-joined combination (Return, ctrl+s, alt+Tab) repeat times.";
    pub const annotations = .{ .always_load = true };
    pub const Args = struct {
        text: []const u8,
        repeat: u32 = 1,
        pub const field_info = .{ .repeat = .{ .minimum = 1, .maximum = 100 } };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-009");
    }
};

const duration_info = .{ .description = "Seconds", .minimum = 0, .maximum = 300 };

pub const hold_key = struct {
    pub const name = "hold_key";
    pub const description = "Hold a key or combination down for duration seconds.";
    pub const Args = struct {
        text: []const u8,
        duration: f64,
        pub const field_info = .{ .duration = duration_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-009");
    }
};

pub const wait = struct {
    pub const name = "wait";
    pub const description = "Pause for duration seconds.";
    pub const Args = struct {
        duration: f64,
        pub const field_info = .{ .duration = duration_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const ns: u64 = @intFromFloat(args.duration * std.time.ns_per_s);
        if (!ctx.sleep(ns)) return Result.err("wait annulé");
        return Result.text("ok");
    }
};

pub const ui_tree = struct {
    pub const name = "ui_tree";
    pub const description = "Pruned accessibility tree of the foreground window, one line per element with its id.";
    pub const annotations = .{ .read_only = true, .idempotent = true, .always_load = true };
    pub const Args = struct {
        window: ?[]const u8 = null,
        since: ?enum { last } = null,
        pub const field_info = .{
            .window = .{ .description = "Window handle from window_list" },
            .since = .{ .description = "last: only changes since the previous tree" },
        };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-011");
    }
};

pub const ui_find = struct {
    pub const name = "ui_find";
    pub const description = "Find elements by role, name substring or state; at most 20 lines.";
    pub const annotations = .{ .read_only = true, .idempotent = true };
    pub const Args = struct {
        query: []const u8,
        window: ?[]const u8 = null,
    };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-013");
    }
};

pub const ui_act = struct {
    pub const name = "ui_act";
    pub const description = "Act on an element by id from ui_tree or ui_find, without coordinates.";
    pub const annotations = .{ .always_load = true };
    pub const Args = struct {
        id: []const u8,
        action: enum { invoke, toggle, select, expand, collapse, set_value, focus, scroll_into_view },
        value: ?[]const u8 = null,
        fallback: ?enum { click } = null,
        pub const field_info = .{ .value = .{ .description = "Text for set_value" } };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-013");
    }
};

pub const window_list = struct {
    pub const name = "window_list";
    pub const description = "List visible top-level windows with handle, title, process and rectangle.";
    pub const annotations = .{ .read_only = true, .idempotent = true };
    pub const Args = struct { include_hidden: bool = false };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-010");
    }
};

pub const window_focus = struct {
    pub const name = "window_focus";
    pub const description = "Bring a window to the foreground, restoring it if minimized.";
    pub const Args = struct { window: []const u8 };
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return unavailable(ctx, name, "US-010");
    }
};

/// Members of `computer_toolset_20260801`, in documentation order.
pub const toolset = .{
    screenshot,   zoom,            left_click, right_click,     middle_click,  double_click,
    triple_click, left_click_drag, mouse_move, left_mouse_down, left_mouse_up, cursor_position,
    scroll,       @"type",         key,        hold_key,        wait,
};

pub const all = toolset ++ .{ ui_tree, ui_find, ui_act, window_list, window_focus };
