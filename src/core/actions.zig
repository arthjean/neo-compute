//! Mouse and keyboard tools of the toolset, on top of the backend's input
//! primitives. Every check (bounds, modifiers, key names, elevated target)
//! runs before the first event is sent.

const std = @import("std");
const input = @import("input.zig");
const keys = @import("keys.zig");
const display = @import("display.zig");
const screen = @import("screen.zig");
const policy = @import("policy.zig");
const Result = @import("mcp.zig").Result;
const fmt = @import("session.zig").fmt;

pub const uipi_message = "Fenêtre élevée : injection bloquée par UIPI. Relance l'app sans élévation ou agis toi-même.";
const blocked_message = "Injection refusée par Windows (bureau sécurisé, verrouillage ou session inactive) : réessaie quand le bureau est accessible.";

const Mods = union(enum) { ok: keys.Mods, err: []const u8 };

/// Parses the `text` modifiers of a click or scroll (`shift`, `ctrl+alt`).
pub fn parseMods(arena: std.mem.Allocator, text: ?[]const u8) Mods {
    const t = text orelse return .{ .ok = .{} };
    if (std.mem.trim(u8, t, " ").len == 0) return .{ .ok = .{} };
    var mods: keys.Mods = .{};
    var it = std.mem.splitScalar(u8, t, '+');
    while (it.next()) |raw| {
        const seg = std.mem.trim(u8, raw, " ");
        const parsed = keys.parse(seg);
        const named = if (parsed == .ok and parsed.ok.key == .key and !parsed.ok.mods.any()) parsed.ok.key.key else null;
        switch (named orelse .enter) {
            .shift => mods.shift = true,
            .ctrl => mods.ctrl = true,
            .alt => mods.alt = true,
            .super => mods.super = true,
            else => return .{ .err = fmt(arena, "Modificateur `{s}` inconnu : valeurs possibles shift, ctrl, alt, super, combinées par + (ex. ctrl+shift).", .{seg}) },
        }
    }
    return .{ .ok = mods };
}

fn holdMods(ctx: anytype, mods: keys.Mods, action: input.KeyAction) input.InputError!void {
    const order = [_]struct { on: bool, key: keys.Key }{
        .{ .on = mods.ctrl, .key = .ctrl },
        .{ .on = mods.alt, .key = .alt },
        .{ .on = mods.shift, .key = .shift },
        .{ .on = mods.super, .key = .super },
    };
    for (order) |o| if (o.on) try ctx.backend.keyCombo(.{ .key = .{ .key = o.key } }, action);
}

fn inputError(err: input.InputError) Result {
    return Result.err(switch (err) {
        error.InputBlocked => blocked_message,
        error.Unmappable => "Caractère absent de la disposition clavier active : utilise type pour le saisir.",
    });
}

const Point = union(enum) { ok: [2]i32, err: Result };

/// Physical point of an optional screenshot coordinate (the cursor when
/// omitted), after the policy (US-017) and elevated-target checks.
fn actionPoint(ctx: anytype, coordinate: ?[2]i32, need: policy.Level) Point {
    const p = if (coordinate) |c| switch (screen.toPhysical(ctx, c)) {
        .ok => |p| p,
        .err => |e| return .{ .err = Result.err(e) },
    } else ctx.backend.cursorPosition();
    if (policy.requireAt(ctx, p, need)) |r| return .{ .err = r };
    if (ctx.backend.targetAt(p) == .elevated) return .{ .err = Result.err(uipi_message) };
    return .{ .ok = p };
}

/// Level a mouse button needs: a right or middle click pastes in most
/// terminals, which `click` must not allow.
fn buttonLevel(btn: input.Button) policy.Level {
    return if (btn == .left) .click else .full;
}

/// Sends `events` with `mods` held around them.
fn withMods(ctx: anytype, mods: keys.Mods, events: []const input.MouseEvent) Result {
    holdMods(ctx, mods, .press) catch |e| return inputError(e);
    const sent = ctx.backend.sendMouse(events);
    holdMods(ctx, mods, .release) catch |e| return inputError(e);
    sent catch |e| return inputError(e);
    return Result.text("ok");
}

pub fn click(ctx: anytype, coordinate: ?[2]i32, text: ?[]const u8, btn: input.Button, count: u8) Result {
    const mods = switch (parseMods(ctx.arena, text)) {
        .ok => |m| m,
        .err => |e| return Result.err(e),
    };
    const p = switch (actionPoint(ctx, coordinate, buttonLevel(btn))) {
        .ok => |p| p,
        .err => |r| return r,
    };
    var events: [7]input.MouseEvent = undefined;
    events[0] = .{ .move = p };
    for (0..count) |i| {
        events[1 + 2 * i] = .{ .down = btn };
        events[2 + 2 * i] = .{ .up = btn };
    }
    return withMods(ctx, mods, events[0 .. 1 + 2 * @as(usize, count)]);
}

pub fn drag(ctx: anytype, start: [2]i32, end: [2]i32, text: ?[]const u8) Result {
    const mods = switch (parseMods(ctx.arena, text)) {
        .ok => |m| m,
        .err => |e| return Result.err(e),
    };
    const a = switch (actionPoint(ctx, start, .click)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    const b = switch (screen.toPhysical(ctx, end)) {
        .ok => |p| p,
        .err => |e| return Result.err(e),
    };
    // The drop reaches the window under the end point: the policy applies
    // there, and UIPI would drop it silently there too.
    if (policy.requireAt(ctx, b, .click)) |r| return r;
    if (ctx.backend.targetAt(b) == .elevated) return Result.err(uipi_message);
    holdMods(ctx, mods, .press) catch |e| return inputError(e);
    ctx.backend.sendMouse(&.{ .{ .move = a }, .{ .down = .left } }) catch |e| return inputError(e);
    // Intermediate moves with short pauses: drag detection in most toolkits
    // needs motion after the press, not a jump.
    const steps = 8;
    for (1..steps + 1) |i| {
        if (!ctx.sleep(15 * std.time.ns_per_ms)) return Result.err("Glisser annulé : bouton relâché.");
        const t = @as(f64, @floatFromInt(i)) / steps;
        const x: i32 = a[0] + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(b[0] - a[0])) * t)));
        const y: i32 = a[1] + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(b[1] - a[1])) * t)));
        ctx.backend.sendMouse(&.{.{ .move = .{ x, y } }}) catch |e| return inputError(e);
    }
    ctx.backend.sendMouse(&.{.{ .up = .left }}) catch |e| return inputError(e);
    holdMods(ctx, mods, .release) catch |e| return inputError(e);
    return Result.text("ok");
}

pub fn move(ctx: anytype, coordinate: [2]i32) Result {
    const p = switch (screen.toPhysical(ctx, coordinate)) {
        .ok => |p| p,
        .err => |e| return Result.err(e),
    };
    if (policy.requireAt(ctx, p, .click)) |r| return r;
    ctx.backend.sendMouse(&.{.{ .move = p }}) catch |e| return inputError(e);
    return Result.text("ok");
}

pub fn button(ctx: anytype, down: bool) Result {
    const p = switch (actionPoint(ctx, null, .click)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    _ = p;
    const e: input.MouseEvent = if (down) .{ .down = .left } else .{ .up = .left };
    ctx.backend.sendMouse(&.{e}) catch |err| return inputError(err);
    return Result.text("ok");
}

pub fn cursorPosition(ctx: anytype) Result {
    const p = ctx.backend.cursorPosition();
    const displays = ctx.backend.displays();
    const index = display.displayAt(displays, p[0], p[1]) orelse
        return Result.err("Aucun écran détecté : position du curseur inconnue.");
    const m = display.Mapping.of(index, displays[index].rect, ctx.session.long_side);
    const s = m.toScreenshot(p[0], p[1]);
    return Result.text(fmt(ctx.arena, "x={d} y={d} display={d}", .{ s[0], s[1], index }));
}

pub fn scroll(ctx: anytype, direction: anytype, amount: u32, coordinate: ?[2]i32, text: ?[]const u8) Result {
    const mods = switch (parseMods(ctx.arena, text)) {
        .ok => |m| m,
        .err => |e| return Result.err(e),
    };
    const p = switch (actionPoint(ctx, coordinate, .click)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    const n: i32 = @intCast(amount);
    const wheel: input.MouseEvent = switch (direction) {
        .up => .{ .wheel = .{ .horizontal = false, .clicks = n } },
        .down => .{ .wheel = .{ .horizontal = false, .clicks = -n } },
        .right => .{ .wheel = .{ .horizontal = true, .clicks = n } },
        .left => .{ .wheel = .{ .horizontal = true, .clicks = -n } },
    };
    return withMods(ctx, mods, &.{ .{ .move = p }, wheel });
}

// ---------------------------------------------------------------- keyboard

const ComboResult = union(enum) { ok: keys.Combo, err: []const u8 };

pub fn parseCombo(arena: std.mem.Allocator, text: []const u8) ComboResult {
    return switch (keys.parse(text)) {
        .ok => |c| .{ .ok = c },
        .empty => .{ .err = "Touche vide : écris une touche ou une combinaison, par exemple Return ou ctrl+s." },
        .not_modifier => |seg| .{ .err = fmt(arena, "`{s}` n'est pas un modificateur : seuls shift, ctrl, alt et super précèdent un +, par exemple ctrl+a.", .{seg}) },
        .unknown => |seg| blk: {
            var buf: [5][]const u8 = undefined;
            const near = keys.closest(seg, &buf);
            break :blk .{ .err = fmt(arena, "Touche inconnue `{s}` : noms valides proches {s}, {s}, {s}, {s}, {s}.", .{ seg, near[0], near[1], near[2], near[3], near[4] }) };
        },
    };
}

/// Keyboard input reaches the foreground window: it needs `full` there.
fn foregroundCheck(ctx: anytype) ?Result {
    if (policy.requireAt(ctx, null, .full)) |r| return r;
    if (ctx.backend.targetAt(null) == .elevated) return Result.err(uipi_message);
    return null;
}

pub fn key(ctx: anytype, text: []const u8, repeat: u32) Result {
    const combo = switch (parseCombo(ctx.arena, text)) {
        .ok => |c| c,
        .err => |e| return Result.err(e),
    };
    if (foregroundCheck(ctx)) |r| return r;
    for (0..repeat) |i| {
        if (i > 0 and !ctx.sleep(10 * std.time.ns_per_ms)) return Result.err("key annulé.");
        ctx.backend.keyCombo(combo, .tap) catch |err| switch (err) {
            // A character outside the layout, without modifiers, is typed.
            error.Unmappable => if (combo.key == .char and !combo.mods.any()) {
                var units: [2]u16 = undefined;
                const len = utf16Of(combo.key.char, &units);
                ctx.backend.typeText(units[0..len]) catch |e| return inputError(e);
            } else return Result.err(fmt(ctx.arena, "Touche `{s}` absente de la disposition clavier active : retire les modificateurs ou utilise type.", .{text})),
            else => return inputError(err),
        };
    }
    return Result.text("ok");
}

fn utf16Of(cp: u21, out: *[2]u16) usize {
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

pub fn holdKey(ctx: anytype, text: []const u8, duration: f64) Result {
    const combo = switch (parseCombo(ctx.arena, text)) {
        .ok => |c| c,
        .err => |e| return Result.err(e),
    };
    if (foregroundCheck(ctx)) |r| return r;
    ctx.backend.keyCombo(combo, .press) catch |e| return inputError(e);
    const done = ctx.sleepReporting(duration);
    ctx.backend.keyCombo(combo, .release) catch |e| return inputError(e);
    if (!done) return Result.err("hold_key annulé : touches relâchées.");
    return Result.text("ok");
}

/// Types `text` one character per backend call (a surrogate pair stays
/// whole, so at most 4 events per SendInput), new lines as the Return key.
/// A backend that declares `type_pace_ns` gets that pause after each
/// character: Windows needs it because a target that pumps late reads queued
/// VK_PACKET characters wrong. Progress goes out every 100 characters.
pub fn typeText(ctx: anytype, text: []const u8) Result {
    const view = std.unicode.Utf8View.init(text) catch return Result.err("Texte invalide : UTF-8 attendu.");
    if (foregroundCheck(ctx)) |r| return r;
    const Backend = @typeInfo(@TypeOf(ctx.backend)).pointer.child;
    const pace: u64 = if (@hasDecl(Backend, "type_pace_ns")) Backend.type_pace_ns else 0;
    var it = view.iterator();
    var prev_cr = false;
    var count: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n' or cp == '\r') {
            const skip = cp == '\n' and prev_cr;
            prev_cr = cp == '\r';
            if (skip) continue;
            ctx.backend.keyCombo(.{ .key = .{ .key = .enter } }, .tap) catch |e| return inputError(e);
        } else {
            prev_cr = false;
            var units: [2]u16 = undefined;
            const n = utf16Of(cp, &units);
            ctx.backend.typeText(units[0..n]) catch |e| return inputError(e);
        }
        count += 1;
        if (!ctx.sleep(pace)) return Result.err("type annulé.");
        if (count % 100 == 0) ctx.progress(@floatFromInt(it.i), @floatFromInt(text.len));
    }
    return Result.text("ok");
}
