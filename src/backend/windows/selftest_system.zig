//! EP-009 selftest: clipboard (US-035) and registry_read (US-036) through
//! the real dispatcher. The clipboard checks place content from the test
//! window, as another application would, and put the text that was there
//! before back at the end. The registry checks only read: the binary
//! imports no registry write function.

const std = @import("std");
const w = @import("win32");
const clipboard = @import("../../core/clipboard.zig");
const policy = @import("../../core/policy.zig");

fn qpcUs() u64 {
    var t: i64 = 0;
    var f: i64 = 1;
    _ = w.QueryPerformanceCounter(&t);
    _ = w.QueryPerformanceFrequency(&f);
    return @intCast(@divTrunc(t * 1_000_000, f));
}

fn p95(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[(samples.len * 95) / 100];
}

fn handles() u32 {
    var n: u32 = 0;
    _ = w.GetProcessHandleCount(w.GetCurrentProcess(), &n);
    return n;
}

fn register(name: []const u8) u32 {
    var wide: [64:0]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&wide, name) catch return 0;
    wide[n] = 0;
    return w.RegisterClipboardFormatW(&wide);
}

fn globalOf(bytes: []const u8) w.HGLOBAL {
    const h = w.GlobalAlloc(w.GMEM_MOVEABLE, @max(bytes.len, 1)) orelse return null;
    const p = w.GlobalLock(h) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(p))[0..bytes.len], bytes);
    _ = w.GlobalUnlock(h);
    return h;
}

fn openRetrying(owner: w.HWND) bool {
    for (0..50) |_| {
        if (w.OpenClipboard(owner) != 0) return true;
        w.Sleep(10);
    }
    return false;
}

/// Puts `text` (when given) and a registered format holding `extra`'s DWORD
/// on the clipboard, owned by `owner`.
fn place(owner: w.HWND, text: ?[]const u8, extra: ?struct { []const u8, u32 }) bool {
    if (!openRetrying(owner)) return false;
    defer _ = w.CloseClipboard();
    if (w.EmptyClipboard() == 0) return false;
    if (text) |t| {
        var wide: [512]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(&wide, t) catch return false;
        wide[n] = 0;
        if (w.SetClipboardData(w.CF_UNICODETEXT, globalOf(std.mem.sliceAsBytes(wide[0 .. n + 1]))) == null) return false;
    }
    if (extra) |e| {
        const v: u32 = e[1];
        if (w.SetClipboardData(register(e[0]), globalOf(std.mem.asBytes(&v))) == null) return false;
    }
    return true;
}

/// The clipboard's text as UTF-8, copied into `arena`; null without text.
fn currentText(arena: std.mem.Allocator) ?[]const u8 {
    if (!openRetrying(null)) return null;
    defer _ = w.CloseClipboard();
    const h = w.GetClipboardData(w.CF_UNICODETEXT) orelse return null;
    const p = w.GlobalLock(h) orelse return null;
    defer _ = w.GlobalUnlock(h);
    const units = std.mem.sliceTo(@as([*]const u16, @ptrCast(@alignCast(p)))[0 .. w.GlobalSize(h) / 2], 0);
    const buf = arena.alloc(u8, units.len * 3) catch return null;
    return buf[0..std.unicode.wtf16LeToWtf8(buf, units)];
}

/// The DWORD of registered format `name`, null when absent.
fn dwordOf(name: []const u8) ?u32 {
    if (!openRetrying(null)) return null;
    defer _ = w.CloseClipboard();
    const h = w.GetClipboardData(register(name)) orelse return null;
    const p = w.GlobalLock(h) orelse return null;
    defer _ = w.GlobalUnlock(h);
    if (w.GlobalSize(h) < 4) return null;
    return @as(*align(1) const u32, @ptrCast(p)).*;
}

const HoldArgs = struct { owner: w.HWND, release: w.HANDLE, held: w.HANDLE };

/// Keeps the clipboard open from a thread of its own until `release`.
fn hold(a: HoldArgs) void {
    if (w.OpenClipboard(a.owner) == 0) {
        _ = w.SetEvent(a.held);
        return;
    }
    _ = w.SetEvent(a.held);
    _ = w.WaitForSingleObject(a.release, 5000);
    _ = w.CloseClipboard();
}

pub fn clipboardChecks(report: anytype, caller: anytype, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, backend: anytype, owner: w.HWND) !void {
    const Server = @TypeOf(caller.server.*);
    const saved = currentText(arena);
    defer if (saved) |s| {
        if (place(owner, s, null)) report.ok("clipboard-restore", "previous text put back ({d} bytes)", .{s.len}) else report.fail("clipboard-restore", "could not put the previous text back", .{});
    } else report.skip("clipboard-restore", "the clipboard held no text before the selftest: nothing restored", .{});

    // clipboard-set-get: set writes CF_UNICODETEXT with both markers at 0,
    // and get reads the agent's own text back.
    {
        const text = "neo-compute \u{e9}\u{1F600} presse-papiers";
        const set = try caller.call("clipboard", "{{\"mode\":\"set\",\"text\":\"{s}\"}}", .{text});
        const direct = currentText(arena) orelse "";
        const history = dwordOf(clipboard.Marker.no_history.format());
        const cloud = dwordOf(clipboard.Marker.no_cloud.format());
        const get = try caller.call("clipboard", "{{\"mode\":\"get\"}}", .{});
        if (!set.is_error and std.mem.eql(u8, direct, text) and history == 0 and cloud == 0 and !get.is_error and std.mem.eql(u8, get.text, text))
            report.ok("clipboard-set-get", "`{s}`; CanIncludeInClipboardHistory 0, CanUploadToCloudClipboard 0; read back", .{set.text})
        else
            report.fail("clipboard-set-get", "set `{s}`, on the clipboard `{s}`, history {?d}, cloud {?d}, get `{s}`", .{ set.text, direct, history, cloud, get.text });
    }

    // clipboard-secret: content placed by another window with each secret
    // format is refused; the `Can...` formats at 1 are not secret.
    {
        var refused: usize = 0;
        var last: []const u8 = "";
        for ([_]clipboard.Marker{ .exclude_monitor, .viewer_ignore, .no_history, .no_cloud }) |m| {
            if (!place(owner, "canari-selftest-0451", .{ m.format(), 0 })) break;
            const r = try caller.call("clipboard", "{{\"mode\":\"get\"}}", .{});
            if (r.is_error and std.mem.eql(u8, r.text, "Presse-papiers marqué secret par neo-compute.exe : lecture refusée")) refused += 1 else last = r.text;
        }
        var allowed: usize = 0;
        for ([_]clipboard.Marker{ .no_history, .no_cloud }) |m| {
            if (!place(owner, "texte ordinaire", .{ m.format(), 1 })) break;
            const r = try caller.call("clipboard", "{{\"mode\":\"get\"}}", .{});
            if (!r.is_error and std.mem.eql(u8, r.text, "texte ordinaire")) allowed += 1 else last = r.text;
        }
        if (refused == 4 and allowed == 2) report.ok("clipboard-secret", "4 secret formats refused, CanInclude/CanUpload at 1 read", .{}) else report.fail("clipboard-secret", "{d}/4 refused, {d}/2 read; last `{s}`", .{ refused, allowed, last });
    }

    // clipboard-deny: content owned by a `deny` application is refused.
    {
        const pol = policy.parse(arena, "{\"apps\": {\"neo-compute.exe\": \"deny\"}}", "selftest");
        var server: Server = .init(gpa, io, backend, .{ .policy = &pol });
        defer server.deinit();
        var c: @TypeOf(caller.*) = .{ .server = &server, .arena = arena, .out = .init(gpa) };
        defer c.out.deinit();
        const ok = place(owner, "texte d'une application deny", null);
        const r = try c.call("clipboard", "{{\"mode\":\"get\"}}", .{});
        if (ok and r.is_error and std.mem.indexOf(u8, r.text, "marqué secret par neo-compute.exe") != null) report.ok("clipboard-deny", "{s}", .{r.text}) else report.fail("clipboard-deny", "placed {}, got `{s}`", .{ ok, r.text });
    }

    // clipboard-no-text: the formats of a content without text are named.
    {
        const ok = place(owner, null, .{ "neo-compute-selftest-format", 7 });
        const r = try caller.call("clipboard", "{{\"mode\":\"get\"}}", .{});
        if (ok and r.is_error and std.mem.eql(u8, r.text, "Le presse-papiers ne contient pas de texte (formats : neo-compute-selftest-format)")) report.ok("clipboard-no-text", "{s}", .{r.text}) else report.fail("clipboard-no-text", "placed {}, got `{s}`", .{ ok, r.text });
    }

    // clipboard-busy: a clipboard held open is retried 10 times 10 ms
    // apart, then refused with the holder's name.
    {
        const release = w.CreateEventW(null, 1, 0, null);
        const held = w.CreateEventW(null, 1, 0, null);
        defer _ = w.CloseHandle(release);
        defer _ = w.CloseHandle(held);
        const t = try std.Thread.spawn(.{}, hold, .{HoldArgs{ .owner = owner, .release = release, .held = held }});
        _ = w.WaitForSingleObject(held, 2000);
        const t0 = qpcUs();
        const r = try caller.call("clipboard", "{{\"mode\":\"get\"}}", .{});
        const ms = (qpcUs() - t0) / 1000;
        _ = w.SetEvent(release);
        t.join();
        // 1 try and 10 retries 10 ms apart: about 100 ms.
        if (r.is_error and std.mem.eql(u8, r.text, "Presse-papiers occupé par neo-compute.exe : réessaie") and ms >= 100 and ms < 250) report.ok("clipboard-busy", "refused after {d} ms: {s}", .{ ms, r.text }) else report.fail("clipboard-busy", "after {d} ms (expected 100 to 250): `{s}`", .{ ms, r.text });
    }

    // clipboard-time: get and set under 10 ms p95 (NFR) on a free
    // clipboard, no handle drift over 500 more calls. Each write wakes the
    // clipboard listeners (Windows' clipboard history among them), which
    // open the clipboard to read it: samples are 50 ms apart so the server
    // is timed, not their reaction to the previous write, which the
    // back-to-back figure shows.
    {
        _ = place(owner, "mesure du presse-papiers", null);
        var get_us: [100]u64 = undefined;
        var set_us: [100]u64 = undefined;
        for (&get_us, &set_us) |*g, *s| {
            w.Sleep(50);
            var t0 = qpcUs();
            _ = try caller.call("clipboard", "{{\"mode\":\"get\"}}", .{});
            g.* = qpcUs() - t0;
            t0 = qpcUs();
            _ = try caller.call("clipboard", "{{\"mode\":\"set\",\"text\":\"mesure du presse-papiers\"}}", .{});
            s.* = qpcUs() - t0;
        }
        var tight_us: [500]u64 = undefined;
        const before = handles();
        for (0..250) |i| {
            var t0 = qpcUs();
            _ = try caller.call("clipboard", "{{\"mode\":\"get\"}}", .{});
            tight_us[2 * i] = qpcUs() - t0;
            t0 = qpcUs();
            _ = try caller.call("clipboard", "{{\"mode\":\"set\",\"text\":\"x\"}}", .{});
            tight_us[2 * i + 1] = qpcUs() - t0;
        }
        const drift = @as(i64, handles()) - before;
        const g95 = p95(&get_us);
        const s95 = p95(&set_us);
        const t95 = p95(&tight_us);
        if (g95 < 10_000 and s95 < 10_000 and drift <= 0) report.ok("clipboard-time", "get p95 {d} us, set p95 {d} us (budget 10000 us); back to back p95 {d} us; handles {d} over 500 calls", .{ g95, s95, t95, drift }) else report.fail("clipboard-time", "get p95 {d} us, set p95 {d} us (budget 10000 us), back to back p95 {d} us, handles {d}", .{ g95, s95, t95, drift });
    }
}

pub fn registryChecks(report: anytype, caller: anytype) !void {
    // registry-value: one value of the 64-bit view, a REG_SZ and a
    // REG_EXPAND_SZ shown raw then expanded.
    {
        const pf = try caller.call("registry_read", "{{\"path\":\"HKLM\\\\SOFTWARE\\\\Microsoft\\\\Windows\\\\CurrentVersion\",\"name\":\"ProgramFilesDir\"}}", .{});
        const env = try caller.call("registry_read", "{{\"path\":\"HKLM\\\\SYSTEM\\\\CurrentControlSet\\\\Control\\\\Session Manager\\\\Environment\",\"name\":\"windir\"}}", .{});
        const pf_ok = !pf.is_error and std.mem.startsWith(u8, pf.text, "ProgramFilesDir REG_SZ = ") and std.mem.endsWith(u8, pf.text, "\\Program Files");
        const env_ok = !env.is_error and std.mem.startsWith(u8, env.text, "windir REG_EXPAND_SZ = %SystemRoot% -> ") and std.ascii.endsWithIgnoreCase(env.text, "\\WINDOWS");
        if (pf_ok and env_ok) report.ok("registry-value", "`{s}` (64-bit view); `{s}`", .{ pf.text, env.text }) else report.fail("registry-value", "`{s}`; `{s}`", .{ pf.text, env.text });
    }

    // registry-key: a key's header, values, then subkeys with a backslash.
    {
        const r = try caller.call("registry_read", "{{\"path\":\"HKLM\\\\SOFTWARE\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\"}}", .{});
        const ok = !r.is_error and std.mem.startsWith(u8, r.text, "[HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion] ") and std.mem.indexOf(u8, r.text, "\nCurrentBuild REG_SZ = ") != null and std.mem.indexOf(u8, r.text, "\nWinlogon\\") != null and r.text.len <= 8000;
        const head = r.text[0 .. std.mem.indexOfScalar(u8, r.text, '\n') orelse r.text.len];
        if (ok) report.ok("registry-key", "`{s}`, {d} characters", .{ head, r.text.len }) else report.fail("registry-key", "{s}", .{r.text});
    }

    // registry-errors: a missing key, a protected one, and an
    // administrator-only one when this run is not elevated.
    {
        const missing = try caller.call("registry_read", "{{\"path\":\"HKCU\\\\Software\\\\neo-compute-selftest-absente\"}}", .{});
        const sam = try caller.call("registry_read", "{{\"path\":\"HKLM\\\\SAM\\\\SAM\"}}", .{});
        const ok = missing.is_error and std.mem.eql(u8, missing.text, "Clé introuvable : HKCU\\Software\\neo-compute-selftest-absente ; vérifie le chemin (ex. HKCU\\Software\\Microsoft)") and sam.is_error and std.mem.eql(u8, sam.text, "Clé protégée : lecture refusée");
        if (ok) report.ok("registry-errors", "`{s}`; `{s}`", .{ missing.text, sam.text }) else report.fail("registry-errors", "`{s}`; `{s}`", .{ missing.text, sam.text });
        const admin = try caller.call("registry_read", "{{\"path\":\"HKLM\\\\SOFTWARE\\\\Microsoft\\\\Windows Defender\\\\Exclusions\"}}", .{});
        if (admin.is_error and std.mem.eql(u8, admin.text, "Accès refusé à HKLM\\SOFTWARE\\Microsoft\\Windows Defender\\Exclusions : clé réservée à l'administrateur"))
            report.ok("registry-denied", "{s}", .{admin.text})
        else
            report.skip("registry-denied", "Defender's exclusions key answered `{s}` (an elevated run, or no Defender)", .{admin.text[0..@min(admin.text.len, 120)]});
    }

    // registry-time: a value read under 5 ms p95 through the dispatcher,
    // no handle drift over 2000 more reads.
    {
        var us: [200]u64 = undefined;
        for (&us) |*s| {
            const t0 = qpcUs();
            _ = try caller.call("registry_read", "{{\"path\":\"HKLM\\\\SOFTWARE\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\",\"name\":\"CurrentBuild\"}}", .{});
            s.* = qpcUs() - t0;
        }
        const before = handles();
        for (0..2000) |_| _ = try caller.call("registry_read", "{{\"path\":\"HKCU\\\\Control Panel\\\\Desktop\",\"name\":\"WheelScrollLines\"}}", .{});
        const drift = @as(i64, handles()) - before;
        const v95 = p95(&us);
        if (v95 < 5000 and drift <= 0) report.ok("registry-time", "value read p95 {d} us (budget 5000 us); handles {d} over 2000 reads", .{ v95, drift }) else report.fail("registry-time", "value read p95 {d} us (budget 5000 us), handles {d}", .{ v95, drift });
    }
}
