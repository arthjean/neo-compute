//! Tool declarations. The first 17 mirror `computer_toolset_20260801`
//! (names and parameters), the others are neo-compute's accessibility,
//! window and application tools (`extension`). Each `run` receives a `*Ctx(Backend)` and
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
const policy = @import("policy.zig");
const windowctl = @import("windowctl.zig");
const launch = @import("launch.zig");
const clipboard_mod = @import("clipboard.zig");
const regread = @import("regread.zig");

const Point = [2]i32;
const Observe = a11y.Observe;
const settle_info = .{ .maximum = a11y.max_settle_ms };

/// Observation after an action (US-015), from the tool's arguments. In
/// background mode `observe: screenshot` is the image of the target window
/// alone (US-061, decision 0013), so no tool refuses it.
fn observed(ctx: anytype, r: Result, args: anytype, window: ?u64) Result {
    return a11y.observeAfter(ctx, r, args.observe, args.settle_timeout_ms, window);
}

pub const screenshot = struct {
    pub const name = "screenshot";
    pub const description = "JPEG screenshot of a display.";
    pub const background_description = "JPEG image of the target window alone (window, else the last one named or launched), even when covered.";
    pub const annotations = .{ .read_only = true, .idempotent = true, .always_load = true, .intrusion = .none };
    /// US-061: in background mode the image is the target window's, never
    /// the screen.
    pub const background = true;
    pub const Args = struct {
        display: ?u32 = null,
        window: ?[]const u8 = null,
        pub const field_info = .{ .window = .{ .description = "Handle: that window alone, even covered" } };
        pub const intrusive = .{ .display = .{ .any = "screenshot display montrerait l'écran de l'utilisateur, pas ta fenêtre cible. Aucune action exécutée. Utilise screenshot sans display, ou avec window." } };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const window = switch (imageWindow(ctx, args.window)) {
            .ok => |h| h orelse return screen.screenshot(ctx, args.display),
            .err => |r| return r,
        };
        if (args.display != null) return Result.err("window et display ne se combinent pas : window montre une fenêtre, display un écran.");
        return screen.screenshotWindow(ctx, window, a11y.imageNote(ctx, window));
    }
};

pub const zoom = struct {
    pub const name = "zoom";
    pub const description = "Region of the last screenshot at full resolution.";
    pub const background_description = "Region of the target window's screenshot at full resolution.";
    pub const annotations = .{ .read_only = true, .idempotent = true, .intrusion = .none };
    pub const background = true;
    pub const Args = struct {
        region: [4]i32,
        window: ?[]const u8 = null,
        pub const field_info = .{ .window = .{ .description = "Handle: region of that window's screenshot" } };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const window = switch (imageWindow(ctx, args.window)) {
            .ok => |h| h orelse return screen.zoom(ctx, args.region),
            .err => |r| return r,
        };
        return screen.zoomWindow(ctx, window, args.region, a11y.imageNote(ctx, window));
    }
};

/// The window `screenshot` and `zoom` show alone (US-061): the one `window`
/// names, else in background mode the session's target. Null: the screen.
fn imageWindow(ctx: anytype, text: ?[]const u8) union(enum) { ok: ?u64, err: Result } {
    const named = switch (optionalHandle(ctx, text)) {
        .ok => |h| h,
        .err => |r| return .{ .err = r },
    };
    return switch (a11y.resolveWindow(ctx, named)) {
        .ok => |h| .{ .ok = h },
        .err => |e| .{ .err = Result.err(e) },
    };
}

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
    pub const annotations = .{ .read_only = true, .idempotent = true, .intrusion = .none };
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
    /// Not an action: allowed while paused and in a second instance.
    pub const inert = true;
    pub const annotations = .{ .intrusion = .none };
    pub const background = true;
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
    pub const background_description = "Accessibility tree of the target window (window, else the last one named or launched), one line per element id; since=last: changes only.";
    pub const annotations = .{ .read_only = true, .idempotent = true, .always_load = true, .intrusion = .none };
    pub const background = true;
    pub const extension = true;
    pub const Args = struct {
        window: ?[]const u8 = null,
        since: ?enum { last } = null,
        /// US-024: a web page's visible text nodes, in reading order.
        text: bool = false,
        /// US-031: also the screenshot with each actionable element's id
        /// drawn on it (explained in the instructions); in background mode
        /// the image of the window alone (US-061).
        marks: bool = false,
        /// US-056: the subtree of one element, and the levels shown.
        root: ?[]const u8 = null,
        depth: ?u16 = null,
        pub const field_info = .{
            .root = .{ .description = "Element id: its subtree only" },
            .depth = .{ .description = "Levels shown", .minimum = 1, .maximum = 25 },
        };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const handle = switch (optionalHandle(ctx, args.window)) {
            .ok => |h| h,
            .err => |r| return r,
        };
        return a11y.tree(ctx, handle, .{ .since_last = args.since != null, .text = args.text, .marks = args.marks, .root = args.root, .depth = args.depth });
    }
};

pub const ui_find = struct {
    pub const name = "ui_find";
    pub const description = "Find elements: name words, \"exact name\", role:<role>, state:<state>, value:<text>; at most 20 lines. id:<id> alone reads that element again.";
    pub const annotations = .{ .read_only = true, .idempotent = true, .intrusion = .none };
    pub const background = true;
    pub const extension = true;
    pub const Args = struct {
        query: []const u8,
        window: ?[]const u8 = null,
        /// US-030: wait for a match, searching again on screen changes.
        wait_ms: u32 = 0,
        /// US-049: with `wait_ms`, wait until nothing matches any more.
        gone: bool = false,
        pub const field_info = .{
            .wait_ms = .{ .description = "Wait up to this long for a match", .minimum = 0, .maximum = a11y.max_wait_ms },
            .gone = .{ .description = "With wait_ms: wait until no match" },
        };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const handle = switch (optionalHandle(ctx, args.window)) {
            .ok => |h| h,
            .err => |r| return r,
        };
        return a11y.find(ctx, args.query, handle, args.wait_ms, args.gone);
    }
};

pub const ui_act = struct {
    pub const name = "ui_act";
    pub const description = "Act on an element id from ui_tree or ui_find; the first line says whether the effect was read back.";
    pub const annotations = .{ .always_load = true, .intrusion = .none };
    pub const background = true;
    pub const extension = true;
    pub const Args = struct {
        id: []const u8,
        action: uitree.Action,
        value: ?[]const u8 = null,
        fallback: ?enum { click } = null,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{
            .value = .{ .description = "set_value: text, or a slider's number. select: an entry's name in this list, combo box, tabs or tree. scroll: up, down, left or right and notches (down 3), page_up, page_down, top, bottom, 50%" },
            .settle_timeout_ms = settle_info,
        };
        /// What the background mode refuses (US-041), from the measures of
        /// US-040 (decision 0013).
        pub const intrusive = .{
            .action = .{ .focus = "ui_act focus prendrait le focus clavier et le premier plan de l'utilisateur. Aucune action exécutée. Essaie invoke, select ou set_value, qui agissent sans le focus." },
            .fallback = .{ .click = "ui_act fallback click prendrait la souris de l'utilisateur. Aucune action exécutée. Essaie l'action sans fallback, ou une autre action de l'élément." },
        };
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
    pub const annotations = .{ .read_only = true, .idempotent = true, .intrusion = .none };
    pub const background = true;
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
    pub const annotations = .{ .intrusion = .foreground };
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
        if (policy.requireWindow(ctx, handle, .click)) |r| return r;
        const r = switch (ctx.backend.focusWindow(handle)) {
            .ok => blk: {
                a11y.setTarget(ctx, handle);
                break :blk Result.text(fmt(ctx.arena, "0x{x} au premier plan", .{handle}));
            },
            .closed => Result.err("Fenêtre fermée : rappelle window_list"),
            .refused => Result.err(fmt(ctx.arena, "Fenêtre 0x{x} : Windows a refusé le premier plan. Clique sur la fenêtre ou réessaie.", .{handle})),
        };
        return observed(ctx, r, args, handle);
    }
};

pub const window_set = struct {
    pub const name = "window_set";
    pub const description = "Move, resize, minimize, maximize or close a window; rect [x, y, w, h] in screenshot pixels of display (default: the window's).";
    pub const annotations = .{ .intrusion = .none };
    pub const background = true;
    pub const extension = true;
    pub const Args = struct {
        window: []const u8,
        rect: ?[4]i32 = null,
        display: ?u32 = null,
        state: ?windowctl.State = null,
        force: bool = false,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{ .force = .{ .description = "With state closed: end the process after 2 s" }, .settle_timeout_ms = settle_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        const handle = parseHandle(args.window) orelse
            return Result.err(fmt(ctx.arena, "Handle `{s}` invalide : utilise un handle de window_list (ex. 0x1a2b).", .{args.window}));
        if (ctx.backend.windowRef(handle) != null) a11y.setTarget(ctx, handle);
        const fg_before: ?u64 = if (ctx.session.background) ctx.backend.foregroundWindow() else null;
        var o = windowctl.set(ctx, handle, args.rect, args.display, args.state, args.force);
        // Background mode (US-043): a state change that brought the window
        // in front says so.
        const open = ctx.backend.windowRef(handle) != null;
        if (ctx.session.background and open and !o.result.is_error and a11y.cameInFront(ctx, handle, fg_before))
            o.result = Result.text(fmt(ctx.arena, "{s}\n0x{x} a pris le premier plan", .{ o.result.blocks[0].text, handle }));
        // A closed target is no longer one.
        if (ctx.session.target == handle and !open) ctx.session.target = null;
        return observed(ctx, o.result, args, o.window);
    }
};

pub const app_launch = struct {
    pub const name = "app_launch";
    pub const description = "Start a Start menu app (name or AUMID) or open a document or folder in its default app; returns the window and its tree.";
    pub const annotations = .{ .intrusion = .none };
    pub const background = true;
    pub const extension = true;
    pub const Args = struct {
        name: ?[]const u8 = null,
        path: ?[]const u8 = null,
        observe: ?Observe = null,
        settle_timeout_ms: ?u32 = null,
        pub const field_info = .{ .settle_timeout_ms = settle_info };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return launch.launch(ctx, args.name, args.path, args.observe, args.settle_timeout_ms);
    }
};

pub const clipboard = struct {
    pub const name = "clipboard";
    pub const description = "Read (get) or write (set) the clipboard's text; content marked secret by its app is refused, and set keeps it out of the history and cloud.";
    pub const annotations = .{ .intrusion = .none };
    pub const background = true;
    pub const extension = true;
    pub const Args = struct {
        mode: clipboard_mod.Mode,
        text: ?[]const u8 = null,
        pub const field_info = .{ .text = .{ .description = "mode set: the text, 1 MiB at most" } };
        pub const intrusive = .{ .mode = .{ .set = "écrire le presse-papiers remplacerait celui de l'utilisateur. Aucune action exécutée. Utilise ui_act set_value." } };
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return clipboard_mod.run(ctx, args.mode, args.text);
    }
};

pub const registry_read = struct {
    pub const name = "registry_read";
    pub const description = "Read a registry value (name; empty for the default) or a key's values and subkeys, 64-bit view; never writes. path: HKCU\\..., HKLM, HKCR, HKU or HKCC.";
    pub const annotations = .{ .read_only = true, .idempotent = true, .intrusion = .none };
    pub const background = true;
    pub const extension = true;
    pub const Args = struct {
        path: []const u8,
        name: ?[]const u8 = null,
    };
    pub fn run(ctx: anytype, args: Args) Result {
        return regread.read(ctx, args.path, args.name);
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

/// One line per display (US-026), then one per window, top of the z-order
/// first: `<handle> "<title>" <exe> pid=<n> display=<n> @x,y,w,h z=<n>
/// {flags}`, the rectangle in screenshot pixels of the window's display.
/// `occluded`: nothing of the window shows under those above it (US-059).
fn windowList(ctx: anytype, include_hidden: bool) Result {
    ctx.timings.start(ctx.io, .windows);
    // US-059: the z-order with the list, from one reading of the desktop.
    var layers: []const display.Layer = &.{};
    const listed = ctx.backend.listWindowsLayered(ctx.arena, include_hidden, &layers);
    ctx.timings.stop(ctx.io, .windows);
    const all_wins = listed catch return Result.err("Mémoire insuffisante : réessaie.");
    // `deny` applications are absent from the list (US-017).
    var kept: std.ArrayList(display.WindowInfo) = .empty;
    for (all_wins) |item| if (ctx.session.policy.levelOf(item.exe) != .deny) {
        var win = item;
        // What its tree says in its header too.
        if (!win.minimized and !win.cloaked and !win.other_desktop) win.occluded = a11y.occlusionIn(ctx, layers, win.handle).occluded;
        kept.append(ctx.arena, win) catch return Result.err("Mémoire insuffisante : réessaie.");
    };
    const wins = kept.items;
    const displays = ctx.backend.displays();
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &out.writer;
    // Display lines come first and are never cut: at most 8 of about 90
    // characters, well within the output limit.
    for (displays, 0..) |d, i| writeDisplay(w, i, d, ctx.backend.displayInfo(i), ctx.session.long_side) catch return Result.err("Mémoire insuffisante : réessaie.");
    if (wins.len == 0) {
        w.writeAll("Aucune fenêtre visible.") catch return Result.err("Mémoire insuffisante : réessaie.");
        return Result.text(out.written());
    }
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
    if (win.elevated or win.minimized or win.cloaked or win.other_desktop or win.occluded) {
        try w.writeAll(" {");
        var first = true;
        inline for (.{ .{ "elevated", "elevated" }, .{ "minimized", "minimized" }, .{ "cloaked", "cloaked" }, .{ "other_desktop", "other-desktop" }, .{ "occluded", "occluded" } }) |flag| if (@field(win, flag[0])) {
            if (!first) try w.writeByte(',');
            try w.writeAll(flag[1]);
            first = false;
        };
        try w.writeByte('}');
    }
    try w.writeByte('\n');
}

/// `display=<n> [primary] physical=<w>x<h> size=<w>x<h> scale=<s> dpi=<n>
/// work=<x>,<y>,<w>,<h>`: physical size, screenshot size and scale as
/// `screenshot` reports them, and the work area in screenshot pixels.
fn writeDisplay(w: *std.Io.Writer, index: usize, d: display.Display, info: display.DisplayInfo, long_side: u32) !void {
    const m = display.Mapping.of(index, d.rect, long_side);
    var sbuf: [16]u8 = undefined;
    try w.print("display={d}{s} physical={d}x{d} size={d}x{d} scale={s} dpi={d}", .{ index, if (info.primary) " primary" else "", d.rect.w, d.rect.h, m.width, m.height, display.scaleText(&sbuf, m.scale), info.dpi });
    const work = m.rectToScreenshot(display.intersection(info.work, d.rect) orelse d.rect);
    try w.print(" work={d},{d},{d},{d}\n", .{ work.x, work.y, work.w, work.h });
}

/// Members of `computer_toolset_20260801`, in documentation order.
pub const toolset = .{
    screenshot,   zoom,            left_click, right_click,     middle_click,  double_click,
    triple_click, left_click_drag, mouse_move, left_mouse_down, left_mouse_up, cursor_position,
    scroll,       @"type",         key,        hold_key,        wait,
};

pub const all = toolset ++ .{ ui_tree, ui_find, ui_act, window_list, window_focus, window_set, app_launch, clipboard, registry_read };
