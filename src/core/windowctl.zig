//! window_set (US-027): places a window's visible frame at a rectangle of a
//! display's screenshot space, restores, minimizes or maximizes it, or
//! closes it as its close button would. `force` ends the window's process
//! when it is still alive 2 s after the close request, never neo-compute's
//! own process, its ancestors (Claude Code) or a system process.

const std = @import("std");
const display = @import("display.zig");
const policy = @import("policy.zig");
const actions = @import("actions.zig");
const timing = @import("timing.zig");
const Result = @import("mcp.zig").Result;
const fmt = @import("session.zig").fmt;

pub const State = enum { normal, minimized, maximized, closed };

/// Processes `force` never terminates, besides neo-compute and its
/// ancestors. ApplicationFrameHost.exe hosts every UWP window: ending it
/// would close them all, so a frame whose application is unknown is
/// protected too.
pub const protected = [_][]const u8{ "explorer.exe", "csrss.exe", "winlogon.exe", "lsass.exe", "services.exe", "ApplicationFrameHost.exe" };

const poll_ms = 50;
/// Screenshot pixels between the requested and obtained rectangles that
/// still count as placed.
pub const tolerance = 2;

const closed_message = "Fenêtre fermée : rappelle window_list";
const oom = "Mémoire insuffisante : réessaie.";

/// The tool's answer and the window its observation reads (null: the
/// foreground window, once the window is closed or minimized).
pub const Outcome = struct { result: Result, window: ?u64 };

fn fail(msg: []const u8) Outcome {
    return .{ .result = Result.err(msg), .window = null };
}

/// What a window whose thread does not answer gets (window_set, and the
/// capture of US-061, which sends it messages too).
pub fn hungText(ctx: anytype, handle: u64) []const u8 {
    return fmt(ctx.arena, "La fenêtre 0x{x} ne répond pas : réessaie, ou ferme-la avec state: closed et force: true.", .{handle});
}

fn setError(ctx: anytype, handle: u64, r: display.SetResult) ?Outcome {
    return switch (r) {
        .ok => null,
        .closed => fail(closed_message),
        .elevated => fail(actions.uipi_message),
        .hung => fail(hungText(ctx, handle)),
        .failed => fail(fmt(ctx.arena, "Windows a refusé de modifier la fenêtre 0x{x} : réessaie, ou utilise window_focus puis la souris.", .{handle})),
    };
}

pub fn set(ctx: anytype, handle: u64, rect: ?[4]i32, display_index: ?u32, state: ?State, force: bool) Outcome {
    if (force and state != .closed)
        return fail("force ne s'applique qu'avec state: closed.");
    if (rect == null and display_index == null and state == null)
        return fail("Passe rect, display ou state : window_set n'a rien à faire.");
    if (state == .closed and (rect != null or display_index != null))
        return fail("state: closed ne prend ni rect ni display : retire-les.");
    ctx.audit_detail.state = if (state) |s| @tagName(s) else "placement";
    // Moving, resizing, changing the state or closing needs `click`;
    // ending a process needs `full`.
    if (policy.requireWindow(ctx, handle, if (force) .full else .click)) |r| return .{ .result = r, .window = null };
    const p = ctx.backend.windowPlacement(handle) orelse return fail(closed_message);
    if (p.elevated) return fail(actions.uipi_message);
    if (state == .closed) return close(ctx, handle, p, force);

    var placed: ?display.Rect = null;
    var asked: ?display.Rect = null;
    const displays = ctx.backend.displays();
    if (rect != null or display_index != null) {
        // The window's display, else the primary one for a minimized
        // window, whose frame is parked off screen.
        const current = if (p.minimized) 0 else display.displayAt(displays, p.frame.x + @divTrunc(p.frame.w, 2), p.frame.y + @divTrunc(p.frame.h, 2)) orelse 0;
        const index: usize = if (display_index) |d| d else current;
        const m = switch (ctx.session.resolve(ctx.arena, displays, index)) {
            .ok => |m| m,
            .err => |e| return fail(e),
        };
        const frame = if (rect) |r| blk: {
            // Sums in i64: `[2147483647, 0, 1, 1]` must not overflow.
            if (r[2] < 1 or r[3] < 1 or r[0] < 0 or r[1] < 0 or @as(i64, r[0]) + r[2] > m.width or @as(i64, r[1]) + r[3] > m.height)
                return fail(fmt(ctx.arena, "Rectangle hors écran : bornes valides 0..{d} x 0..{d}", .{ m.width - 1, m.height - 1 }));
            asked = .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] };
            const rel = m.regionToPhysical(r[0], r[1], r[0] + r[2], r[1] + r[3]);
            break :blk display.Rect{ .x = m.rect.x + rel.x, .y = m.rect.y + rel.y, .w = rel.w, .h = rel.h };
        } else blk: {
            // `display` alone: the same size, centered on that display.
            const w = @min(p.frame.w, m.rect.w);
            const h = @min(p.frame.h, m.rect.h);
            break :blk display.Rect{ .x = m.rect.x + @divTrunc(m.rect.w - w, 2), .y = m.rect.y + @divTrunc(m.rect.h - h, 2), .w = w, .h = h };
        };
        const r = ctx.backend.placeWindow(handle, frame, !ctx.session.background);
        if (setError(ctx, handle, r)) |o| return o;
        placed = r.ok;
    }
    var final_state: display.ShowState = if (p.maximized and placed == null) .maximized else if (p.minimized and placed == null) .minimized else .normal;
    if (state) |s| {
        const show: display.ShowState = switch (s) {
            .normal => .normal,
            .minimized => .minimized,
            .maximized => .maximized,
            .closed => unreachable,
        };
        const r = ctx.backend.showWindow(handle, show, !ctx.session.background);
        if (setError(ctx, handle, r)) |o| return o;
        final_state = show;
        placed = r.ok;
    }
    const frame = placed orelse p.frame;
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &out.writer;
    w.print("0x{x} {t}", .{ handle, final_state }) catch return fail(oom);
    if (final_state != .minimized) {
        const d = display.displayAt(displays, frame.x + @divTrunc(frame.w, 2), frame.y + @divTrunc(frame.h, 2)) orelse 0;
        const m = display.Mapping.of(d, displays[d].rect, ctx.session.long_side);
        const got = m.rectToScreenshot(frame);
        w.print(" display={d} @{d},{d},{d},{d}", .{ d, got.x, got.y, got.w, got.h }) catch return fail(oom);
        if (asked) |a| if (final_state == .normal and (@abs(got.x - a.x) > tolerance or @abs(got.y - a.y) > tolerance or @abs(got.w - a.w) > tolerance or @abs(got.h - a.h) > tolerance))
            w.print(" (rectangle demandé @{d},{d},{d},{d} : l'application impose sa position ou sa taille)", .{ a.x, a.y, a.w, a.h }) catch return fail(oom);
    }
    return .{ .result = Result.text(out.written()), .window = if (final_state == .minimized) null else handle };
}

/// Whether `pid` (executable `exe`) is neo-compute, one of its ancestors or
/// a protected system process.
fn isProtected(ctx: anytype, pid: u32, exe: []const u8) bool {
    for (protected) |name| if (std.ascii.eqlIgnoreCase(name, exe)) return true;
    return std.mem.indexOfScalar(u32, ctx.backend.processAncestors(ctx.arena), pid) != null;
}

/// A dialog of the window's process opened by the close request (save
/// changes?): an owned window or popup of the same process, topmost first.
/// The observation reads it by its own handle: UIA lists an owned dialog
/// inside its owner's tree, where pruning drops it when it lies outside the
/// owner's frame.
fn dialogOpen(ctx: anytype, handle: u64, pid: u32) ?u64 {
    for (ctx.backend.uiRoots(ctx.arena, handle)) |r| if (r.pid == pid) return r.handle;
    return null;
}

fn close(ctx: anytype, handle: u64, p: display.Placement, force: bool) Outcome {
    const pid = ctx.backend.appPid(handle) orelse p.pid;
    const exe = ctx.backend.processName(ctx.arena, pid) orelse "?";
    if (force and isProtected(ctx, pid, exe)) return fail(fmt(ctx.arena, "Fermeture forcée refusée : {s} est protégé", .{exe}));
    if (setError(ctx, handle, ctx.backend.closeWindow(handle))) |o| return o;
    const start = timing.now(ctx.io);
    while (timing.now(ctx.io) - start < @as(i96, ctx.session.close_wait_ms) * std.time.ns_per_ms) {
        if (ctx.backend.windowRef(handle) == null) return .{ .result = Result.text(fmt(ctx.arena, "0x{x} fermée", .{handle})), .window = null };
        if (!force) if (dialogOpen(ctx, handle, p.pid)) |dialog|
            return .{ .result = Result.text(fmt(ctx.arena, "0x{x} : fermeture demandée, un dialogue de l'application est ouvert (voir l'observation)", .{handle})), .window = dialog };
        if (!ctx.sleep(poll_ms * std.time.ns_per_ms)) return fail("window_set annulé");
    }
    if (!force) return .{ .result = Result.text(fmt(ctx.arena, "0x{x} : fermeture demandée, la fenêtre est encore ouverte après 2 s (dialogue ou fermeture lente)", .{handle})), .window = handle };
    // Still open after 2 s: end its process, if it is still the same one.
    const still = ctx.backend.windowRef(handle) orelse return .{ .result = Result.text(fmt(ctx.arena, "0x{x} fermée", .{handle})), .window = null };
    const now_pid = ctx.backend.appPid(handle) orelse still.pid;
    if (now_pid != pid) return fail(fmt(ctx.arena, "Fenêtre 0x{x} : son processus a changé pendant la fermeture, aucune fin forcée : rappelle window_list.", .{handle}));
    if (!ctx.backend.processAlive(pid)) return .{ .result = Result.text(fmt(ctx.arena, "0x{x} fermée", .{handle})), .window = null };
    if (!ctx.backend.terminateProcess(pid))
        return fail(fmt(ctx.arena, "Fermeture forcée de {s} (pid {d}) refusée par Windows : ferme l'application toi-même.", .{ exe, pid }));
    ctx.audit_detail.terminated_pid = pid;
    ctx.audit_detail.setTerminatedExe(exe);
    return .{ .result = Result.text(fmt(ctx.arena, "0x{x} : processus {s} (pid {d}) terminé, la fenêtre ne s'était pas fermée en 2 s", .{ handle, exe, pid })), .window = null };
}
