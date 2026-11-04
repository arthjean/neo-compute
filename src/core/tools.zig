//! Tool declarations. The first 17 mirror `computer_toolset_20260801`
//! (names and parameters), the last 5 are neo-compute's accessibility and
//! window tools (`extension`). Each `run` receives a `*Ctx(Backend)` and
//! returns a Result. Action tools take the optional `observe` and
//! `settle_timeout_ms` extensions (US-015), explained once in the MCP
//! instructions rather than per field to stay within the definition budget.

const std = @import("std");
const Result = @import("mcp.zig").Result;
const screen = @import("screen.zig");
const actions = @import("actions.zig");
const display = @import("display.zig");
const a11y = @import("a11y.zig");
const uitree = @import("uitree.zig");
const fmt = @import("session.zig").fmt;

const Point = [2]i32;
const Observe = a11y.Observe;
const settle_info = .{ .maximum = a11y.max_settle_ms };

/// Observation after an action (US-015), from the tool's arguments.
fn observed(ctx: anytype, r: Result, args: anytype, window: ?u64) Result {
    return a11y.observeAfter(ctx, r, args.observe, args.settle_timeout_ms, window);
}

pub const screenshot = struct {
    pub const name = "screenshot";
    pub const description = "JPEG screenshot of a display.";
    pub const annotations = .{ .read_only = true, .idempotent = true, .always_load = true };
    pub const Args = struct {
        display: ?u32 = null,
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return screen.screenshot(ctx, args.display);
    }
};

pub const zoom = struct {
    pub const name = "zoom";
    pub const description = "Region of the last screenshot at full resolution.";
    pub const annotations = .{ .read_only = true, .idempotent = true };
    pub const Args = struct {
        region: [4]i32,
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return screen.zoom(ctx, args.region);
    }
};

fn ClickTool(comptime tool_name: []const u8, comptime desc: []const u8, comptime always: bool, comptime button: @import("input.zig").Button, comptime count: u8) type {
    return struct {
        pub const name = tool_name;
        pub const description = desc;
        pub const annotations = .{ .always_load = always };
        pub const Args = struct {
            coordinate: ?Point = null,
            text: ?[]const u8 = null,
            observe: ?Observe = null,
            settle_timeout_ms: ?u32 = null,
            pub const field_info = .{ .settle_timeout_ms = settle_info };
        };
        pub fn run(ctx: anytype, args: Args) Result {
            return observed(ctx, actions.click(ctx, args.coordinate, args.text, button, count), args, null);
        }
    };
}

pub const left_click = ClickTool("left_click", "Left click at coordinate or the cursor.", true, .left, 1);
pub const right_click = ClickTool("right_click", "Right click at coordinate or the cursor.", false, .right, 1);
pub const middle_click = ClickTool("middle_click", "Middle click at coordinate or the cursor.", false, .middle, 1);
pub const double_click = ClickTool("double_click", "Double click at coordinate or the cursor.", false, .left, 2);
pub const triple_click = ClickTool("triple_click", "Triple click at coordinate or the cursor.", false, .left, 3);

pub const left_click_drag = struct {
    pub const name = "left_click_drag";
    pub const description = "Drag from start_coordinate to coordinate.";
    pub const Args = struct {
        start_coordinate: Point,
        coordinate: Point,
        text: ?[]const u8 = null,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{ .settle_timeout_ms = settle_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return observed(ctx, actions.drag(ctx, args.start_coordinate, args.coordinate, args.text), args, null);
    }
};

pub const mouse_move = struct {
    pub const name = "mouse_move";
    pub const description = "Move the cursor without clicking.";
    pub const Args = struct {
        coordinate: Point,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{ .settle_timeout_ms = settle_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return observed(ctx, actions.move(ctx, args.coordinate), args, null);
    }
};

fn ButtonTool(comptime tool_name: []const u8, comptime desc: []const u8, comptime down: bool) type {
    return struct {
        pub const name = tool_name;
        pub const description = desc;
        pub const Args = struct {
            observe: ?Observe = null,
            settle_timeout_ms: ?u32 = null,
            pub const field_info = .{ .settle_timeout_ms = settle_info };
        };
        pub fn run(ctx: anytype, args: Args) Result {
            return observed(ctx, actions.button(ctx, down), args, null);
        }
    };
}

pub const left_mouse_down = ButtonTool("left_mouse_down", "Press the left button at the cursor.", true);
pub const left_mouse_up = ButtonTool("left_mouse_up", "Release the left button at the cursor.", false);

pub const cursor_position = struct {
    pub const name = "cursor_position";
    pub const description = "Cursor position in screenshot pixels.";
    pub const annotations = .{ .read_only = true, .idempotent = true };
    pub const Args = struct {};
    pub fn run(ctx: anytype, args: Args) Result {
        _ = args;
        return actions.cursorPosition(ctx);
    }
};

pub const scroll = struct {
    pub const name = "scroll";
    pub const description = "Scroll at coordinate or the cursor.";
    pub const annotations = .{ .always_load = true };
    pub const Args = struct {
        scroll_direction: enum { up, down, left, right },
        scroll_amount: u32,
        coordinate: ?Point = null,
        text: ?[]const u8 = null,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{
            .scroll_amount = .{ .minimum = 1, .maximum = 100 },
            .settle_timeout_ms = settle_info,
        };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return observed(ctx, actions.scroll(ctx, args.scroll_direction, args.scroll_amount, args.coordinate, args.text), args, null);
    }
};

pub const @"type" = struct {
    pub const name = "type";
    pub const description = "Type text at the keyboard focus.";
    pub const annotations = .{ .always_load = true };
    pub const Args = struct {
        text: []const u8,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{ .settle_timeout_ms = settle_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return observed(ctx, actions.typeText(ctx, args.text), args, null);
    }
};

pub const key = struct {
    pub const name = "key";
    pub const description = "Press a key or combination (Return, ctrl+s) repeat times.";
    pub const annotations = .{ .always_load = true };
    pub const Args = struct {
        text: []const u8,
        repeat: u32 = 1,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{ .repeat = .{ .minimum = 1, .maximum = 100 }, .settle_timeout_ms = settle_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return observed(ctx, actions.key(ctx, args.text, args.repeat), args, null);
    }
};

const duration_info = .{ .minimum = 0, .maximum = 300 };

pub const hold_key = struct {
    pub const name = "hold_key";
    pub const description = "Hold a key or combination for duration seconds.";
    pub const Args = struct {
        text: []const u8,
        duration: f64,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{ .duration = duration_info, .settle_timeout_ms = settle_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return observed(ctx, actions.holdKey(ctx, args.text, args.duration), args, null);
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
        if (!ctx.sleepReporting(args.duration)) return Result.err("wait annulé");
        return Result.text("ok");
    }
};

pub const ui_tree = struct {
    pub const name = "ui_tree";
    pub const description = "Accessibility tree of the foreground window, one line per element id; since=last: changes only.";
    pub const annotations = .{ .read_only = true, .idempotent = true, .always_load = true };
    pub const extension = true;
    pub const Args = struct {
        window: ?[]const u8 = null,
        since: ?enum { last } = null,
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const handle = switch (optionalHandle(ctx, args.window)) {
            .ok => |h| h,
            .err => |r| return r,
        };
        return a11y.tree(ctx, handle, args.since != null);
    }
};

pub const ui_find = struct {
    pub const name = "ui_find";
    pub const description = "Find elements: name words, role:<role>, state:<state>; at most 20 lines.";
    pub const annotations = .{ .read_only = true, .idempotent = true };
    pub const extension = true;
    pub const Args = struct {
        query: []const u8,
        window: ?[]const u8 = null,
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const handle = switch (optionalHandle(ctx, args.window)) {
            .ok => |h| h,
            .err => |r| return r,
        };
        return a11y.find(ctx, args.query, handle);
    }
};

pub const ui_act = struct {
    pub const name = "ui_act";
    pub const description = "Act on an element id from ui_tree or ui_find.";
    pub const annotations = .{ .always_load = true };
    pub const extension = true;
    pub const Args = struct {
        id: []const u8,
        action: uitree.Action,
        value: ?[]const u8 = null,
        fallback: ?enum { click } = null,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{ .settle_timeout_ms = settle_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const r = a11y.act(ctx, args.id, args.action, args.value, args.fallback != null);
        return observed(ctx, r, args, a11y.windowOf(ctx, args.id));
    }
};

/// The window handle of an optional `window` argument.
fn optionalHandle(ctx: anytype, text: ?[]const u8) union(enum) { ok: ?u64, err: Result } {
    const t = text orelse return .{ .ok = null };
    if (parseHandle(t)) |h| return .{ .ok = h };
    return .{ .err = Result.err(fmt(ctx.arena, "Handle `{s}` invalide : utilise un handle de window_list (ex. 0x1a2b).", .{t})) };
}

pub const window_list = struct {
    pub const name = "window_list";
    pub const description = "Visible top-level windows: handle, title, process, rectangle.";
    pub const annotations = .{ .read_only = true, .idempotent = true };
    pub const extension = true;
    pub const Args = struct {
        include_hidden: bool = false,
        pub const field_info = .{ .include_hidden = .{ .description = "Include cloaked windows" } };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return windowList(ctx, args.include_hidden);
    }
};

pub const window_focus = struct {
    pub const name = "window_focus";
    pub const description = "Bring a window to the foreground, restoring it.";
    pub const extension = true;
    pub const Args = struct {
        window: []const u8,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{ .settle_timeout_ms = settle_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const handle = parseHandle(args.window) orelse
            return Result.err(fmt(ctx.arena, "Handle `{s}` invalide : utilise un handle de window_list (ex. 0x1a2b).", .{args.window}));
        const r = switch (ctx.backend.focusWindow(handle)) {
            .ok => Result.text(fmt(ctx.arena, "0x{x} au premier plan", .{handle})),
            .closed => Result.err("Fenêtre fermée : rappelle window_list"),
            .refused => Result.err(fmt(ctx.arena, "Fenêtre 0x{x} : Windows a refusé le premier plan. Clique sur la fenêtre ou réessaie.", .{handle})),
        };
        return observed(ctx, r, args, handle);
    }
};

/// Parses a window handle as printed by window_list (`0x1a2b` or `1a2b`).
pub fn parseHandle(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " ");
    const digits = if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) t[2..] else t;
    if (digits.len == 0) return null;
    const v = std.fmt.parseInt(u64, digits, 16) catch return null;
    return if (v == 0) null else v;
}

pub const max_text_output = 8000; // FR-16
const max_title_chars = 80;

/// One line per window, top of the z-order first:
/// `<handle> "<title>" <exe> pid=<n> display=<n> @x,y,w,h z=<n> {flags}`,
/// the rectangle in screenshot pixels of the window's display.
fn windowList(ctx: anytype, include_hidden: bool) Result {
    ctx.timings.start(ctx.io, .windows);
    const listed = ctx.backend.listWindows(ctx.arena, include_hidden);
    ctx.timings.stop(ctx.io, .windows);
    const wins = listed catch return Result.err("Mémoire insuffisante : réessaie.");
    if (wins.len == 0) return Result.text("Aucune fenêtre visible.");
    const displays = ctx.backend.displays();
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &out.writer;
    for (wins, 0..) |win, z| {
        const mark = out.written().len;
        writeWindow(w, win, z, displays, ctx.session.long_side) catch return Result.err("Mémoire insuffisante : réessaie.");
        if (out.written().len > max_text_output - 64) {
            out.shrinkRetainingCapacity(mark);
            w.print("… {d} fenêtres omises (limite de sortie)\n", .{wins.len - z}) catch {};
            break;
        }
    }
    return Result.text(std.mem.trimEnd(u8, out.written(), "\n"));
}

fn writeWindow(w: *std.Io.Writer, win: display.WindowInfo, z: usize, displays: []const display.Display, long_side: u32) !void {
    try w.print("0x{x} \"", .{win.handle});
    var chars: usize = 0;
    var it = (std.unicode.Utf8View.init(win.title) catch std.unicode.Utf8View.initUnchecked("?")).iterator();
    while (it.nextCodepointSlice()) |cp| : (chars += 1) {
        if (chars == max_title_chars) {
            try w.writeAll("…");
            break;
        }
        try w.writeAll(if (cp[0] == '\n' or cp[0] == '\r' or cp[0] == '"') " " else cp);
    }
    try w.print("\" {s} pid={d}", .{ win.exe, win.pid });
    const cx = win.rect.x + @divTrunc(win.rect.w, 2);
    const cy = win.rect.y + @divTrunc(win.rect.h, 2);
    if (win.minimized) {
        try w.writeAll(" @-");
    } else if (display.displayAt(displays, cx, cy)) |d| {
        const m = display.Mapping.of(d, displays[d].rect, long_side);
        const r = m.rectToScreenshot(win.rect);
        try w.print(" display={d} @{d},{d},{d},{d}", .{ d, r.x, r.y, r.w, r.h });
    }
    try w.print(" z={d}", .{z});
    if (win.elevated or win.minimized or win.cloaked) {
        try w.writeAll(" {");
        var first = true;
        inline for (.{ "elevated", "minimized", "cloaked" }) |flag| if (@field(win, flag)) {
            if (!first) try w.writeByte(',');
            try w.writeAll(flag);
            first = false;
        };
        try w.writeByte('}');
    }
    try w.writeByte('\n');
}

/// Members of `computer_toolset_20260801`, in documentation order.
pub const toolset = .{
    screenshot,   zoom,            left_click, right_click,     middle_click,  double_click,
    triple_click, left_click_drag, mouse_move, left_mouse_down, left_mouse_up, cursor_position,
    scroll,       @"type",         key,        hold_key,        wait,
};

pub const all = toolset ++ .{ ui_tree, ui_find, ui_act, window_list, window_focus };
