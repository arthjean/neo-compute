//! Shell worker (EP-006): one thread in a single-threaded apartment for the
//! shell APIs, which expect an STA that pumps messages. It asks
//! IVirtualDesktopManager which cloaked windows sit on another virtual
//! desktop (US-026), enumerates the Start menu (FOLDERID_AppsFolder, US-028),
//! launches applications (IApplicationActivationManager, ShellExecuteExW) and
//! finds a document's default application (AssocQueryStringW, US-029).
//!
//! The dispatcher hands it one job at a time and waits in 10 ms slices, so a
//! launch that Windows holds can be cancelled. An abandoned job finishes
//! into the worker's own buffers (its input was copied there too), and the
//! next job waits for it or reports it still running.

const std = @import("std");
const w = @import("win32");
const com = @import("com.zig");
const apps = @import("../../core/apps.zig");
const check = com.check;
const release = com.release;

pub const busy_message = "Le lancement précédent est encore en cours : réessaie dans quelques secondes.";

pub const Launch = apps.Launch;
pub const CatalogResult = apps.CatalogResult;

const Job = union(enum) {
    /// Flags `other` for the windows of `hwnds` on another virtual desktop;
    /// `ok` is false when IVirtualDesktopManager does not answer.
    desktops: struct { hwnds: []const u64, other: []bool, ok: bool = false },
    catalog,
    /// `text` holds the AUMID.
    activate,
    /// `text` holds the file ShellExecuteExW opens.
    execute,
    /// `text` holds the extension; the executable goes to `exe_buf`.
    assoc,
    /// `text` holds an AUMID; its shortcut's target goes to `exe_buf`.
    target,
    /// `text` holds the extension; `exe_len` is 1 when Windows classes it
    /// as dangerous or its default command runs the file itself, else 0.
    unsafe,
    quit,
};

/// Start menu entries kept per enumeration; more are dropped.
const max_apps = 2048;

pub const Shell = struct {
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    wake: w.HANDLE = null,
    done: w.HANDLE = null,
    job: Job = .quit,
    /// A job was abandoned by a cancelled wait and may still run.
    pending: bool = false,
    init_error: ?[]const u8 = null,
    /// Input of the current job, owned by the worker so an abandoned job
    /// never reads the dispatcher's request arena.
    text: [2048:0]u16 = undefined,
    /// How `execute` asks the application to show its window.
    show: apps.Show = .normal,
    // Outputs, written by the worker before it signals `done`.
    catalog_arena: std.heap.ArenaAllocator,
    catalog_apps: []const apps.App = &.{},
    catalog_error: ?[]const u8 = null,
    catalog_ns: u64 = 0,
    launch: Launch = .{ .ok = null },
    exe_buf: [520]u16 = undefined,
    exe_len: usize = 0,
    // Worker-thread objects.
    vdm: ?*w.IVirtualDesktopManager = null,
    activation: ?*w.IApplicationActivationManager = null,

    pub fn init(gpa: std.mem.Allocator) Shell {
        return .{ .gpa = gpa, .catalog_arena = .init(gpa) };
    }

    pub fn deinit(self: *Shell) void {
        if (self.thread) |t| {
            if (self.pending) _ = w.WaitForSingleObject(self.done, 5000);
            self.job = .quit;
            _ = w.SetEvent(self.wake);
            t.join();
            _ = w.CloseHandle(self.wake);
            _ = w.CloseHandle(self.done);
            self.thread = null;
        }
        self.catalog_arena.deinit();
    }

    // ------------------------------------------------------------ dispatcher side

    /// Cloaked windows on another virtual desktop (US-026). False when the
    /// manager is unavailable (Explorer restarted): the windows stay cloaked.
    pub fn otherDesktops(self: *Shell, hwnds: []const u64, other: []bool) bool {
        @memset(other, false);
        if (hwnds.len == 0) return true;
        if (self.begin() != null) return false;
        self.job = .{ .desktops = .{ .hwnds = hwnds, .other = other } };
        _ = self.wait(null);
        return self.job.desktops.ok;
    }

    /// The Start menu's applications, copied into `arena`.
    pub fn catalog(self: *Shell, arena: std.mem.Allocator, cancel: *const std.atomic.Value(bool)) CatalogResult {
        if (self.begin()) |msg| return .{ .err = msg };
        self.job = .catalog;
        if (!self.wait(cancel)) return .{ .err = "Énumération du menu Démarrer annulée." };
        if (self.catalog_error) |msg| return .{ .err = msg };
        const out = arena.alloc(apps.App, self.catalog_apps.len) catch return .{ .err = "Mémoire insuffisante : réessaie." };
        for (self.catalog_apps, out) |src, *dst| dst.* = .{
            .name = arena.dupe(u8, src.name) catch return .{ .err = "Mémoire insuffisante : réessaie." },
            .aumid = arena.dupe(u8, src.aumid) catch return .{ .err = "Mémoire insuffisante : réessaie." },
            .packaged = src.packaged,
            .exe = if (src.exe) |e| arena.dupe(u8, e) catch return .{ .err = "Mémoire insuffisante : réessaie." } else null,
        };
        return .{ .ok = out };
    }

    /// Time of the last enumeration (bench, A13).
    pub fn lastCatalogNs(self: *const Shell) u64 {
        return self.catalog_ns;
    }

    /// Launches a packaged application by AUMID.
    pub fn activate(self: *Shell, aumid: []const u8, cancel: *const std.atomic.Value(bool)) Launch {
        return self.launchJob(.activate, aumid, .normal, cancel);
    }

    /// Opens `file` (`shell:AppsFolder\<AUMID>` or a document) with
    /// ShellExecuteExW, without arguments or verb, asking for `show`.
    pub fn execute(self: *Shell, file: []const u8, show: apps.Show, cancel: *const std.atomic.Value(bool)) Launch {
        return self.launchJob(.execute, file, show, cancel);
    }

    fn launchJob(self: *Shell, comptime kind: std.meta.Tag(Job), input: []const u8, show: apps.Show, cancel: *const std.atomic.Value(bool)) Launch {
        if (self.begin()) |msg| return .{ .unavailable = msg };
        if (!self.setText(input)) return .{ .unavailable = "Nom ou chemin trop long." };
        self.show = show;
        self.job = kind;
        if (!self.wait(cancel)) return .cancelled;
        return self.launch;
    }

    /// Executable file name of `ext`'s default application (`.txt` ->
    /// `notepad.exe`), null when Windows does not say.
    pub fn defaultExe(self: *Shell, arena: std.mem.Allocator, ext: []const u8) ?[]const u8 {
        if (self.begin() != null) return null;
        if (!self.setText(ext)) return null;
        self.job = .assoc;
        _ = self.wait(null);
        return self.baseName(arena);
    }

    /// Whether `ext` is a type Windows classes as dangerous to open
    /// (AssocIsDangerous: its built-in list and `FTA_AlwaysUnsafe`), or
    /// whose default verb runs the file itself as a program (`"%1" %*`, as
    /// `.pif` and `.scr` do): code whatever the versioned list says
    /// (FR-25, decision 0010). Unknown when the shell is busy: refused.
    pub fn unsafeType(self: *Shell, ext: []const u8) bool {
        if (self.begin() != null) return true;
        if (!self.setText(ext)) return true;
        self.job = .unsafe;
        _ = self.wait(null);
        return self.exe_len != 0;
    }

    /// Executable file name a non-packaged Start menu entry's shortcut
    /// targets (`Code.exe`), null when the target is no executable. Read for
    /// the chosen entry only: reading every target during the enumeration
    /// costs a third of it (A13).
    pub fn targetExe(self: *Shell, arena: std.mem.Allocator, aumid: []const u8) ?[]const u8 {
        if (self.begin() != null) return null;
        if (!self.setText(aumid)) return null;
        self.job = .target;
        _ = self.wait(null);
        const name = self.baseName(arena) orelse return null;
        return if (std.ascii.endsWithIgnoreCase(name, ".exe")) name else null;
    }

    /// UTF-8 file name of the path in `exe_buf`.
    fn baseName(self: *Shell, arena: std.mem.Allocator) ?[]const u8 {
        if (self.exe_len == 0) return null;
        const full = self.exe_buf[0..self.exe_len];
        const base = if (std.mem.lastIndexOfScalar(u16, full, '\\')) |i| full[i + 1 ..] else full;
        const buf = arena.alloc(u8, base.len * 3) catch return null;
        return buf[0..std.unicode.wtf16LeToWtf8(buf, base)];
    }

    fn setText(self: *Shell, utf8: []const u8) bool {
        const n = std.unicode.wtf8ToWtf16Le(&self.text, utf8) catch return false;
        if (n >= self.text.len) return false;
        self.text[n] = 0;
        return true;
    }

    /// Starts the thread on first use and settles an abandoned job; returns
    /// why no job can run, if so.
    fn begin(self: *Shell) ?[]const u8 {
        if (self.thread == null) {
            self.wake = w.CreateEventW(null, 0, 0, null);
            self.done = w.CreateEventW(null, 0, 0, null);
            if (self.wake == null or self.done == null) return "Shell indisponible : création des événements impossible, réessaie.";
            self.thread = std.Thread.spawn(.{}, loop, .{self}) catch return "Shell indisponible : thread de travail impossible à créer, réessaie.";
            _ = w.WaitForSingleObject(self.done, w.INFINITE);
        }
        if (self.init_error) |msg| return msg;
        if (self.pending) {
            if (w.WaitForSingleObject(self.done, 0) != w.WAIT_OBJECT_0) return busy_message;
            self.pending = false;
        }
        return null;
    }

    /// Runs the job set in `self.job`; false when `cancel` fired first (the
    /// job keeps running and is settled by the next `begin`).
    fn wait(self: *Shell, cancel: ?*const std.atomic.Value(bool)) bool {
        _ = w.SetEvent(self.wake);
        while (true) {
            if (w.WaitForSingleObject(self.done, 10) == w.WAIT_OBJECT_0) return true;
            if (cancel) |c| if (c.load(.acquire)) {
                self.pending = true;
                return false;
            };
        }
    }

    // ------------------------------------------------------------ worker side

    fn loop(self: *Shell) void {
        const com_ok = if (check(w.CoInitializeEx(null, @bitCast(w.COINIT_APARTMENTTHREADED)))) true else |_| false;
        if (!com_ok) self.init_error = "Shell indisponible : COM refuse le mode STA.";
        _ = w.SetEvent(self.done);
        while (true) {
            const r = w.MsgWaitForMultipleObjects(1, @ptrCast(&self.wake), 0, w.INFINITE, w.QS_ALLINPUT);
            if (r == w.WAIT_OBJECT_0 + 1) {
                pump();
                continue;
            }
            if (r != w.WAIT_OBJECT_0) continue;
            switch (self.job) {
                .quit => break,
                .desktops => |*j| j.ok = self.desktops(j.hwnds, j.other),
                .catalog => self.enumerate(),
                .activate => self.launch = self.runActivate(),
                .execute => self.launch = self.runExecute(),
                .assoc => self.exe_len = self.runAssoc(),
                .target => self.exe_len = self.runTarget(),
                .unsafe => self.exe_len = @intFromBool(self.runUnsafe()),
            }
            _ = w.SetEvent(self.done);
        }
        if (self.vdm) |v| release(v);
        if (self.activation) |a| release(a);
        if (com_ok) w.CoUninitialize();
    }

    /// Dispatches the messages COM and the shell post to this STA.
    fn pump() void {
        var msg: w.MSG = undefined;
        while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
    }

    fn manager(self: *Shell) ?*w.IVirtualDesktopManager {
        if (self.vdm) |v| return v;
        var raw: ?*anyopaque = null;
        check(w.CoCreateInstance(&w.CLSID_VirtualDesktopManager, null, w.CLSCTX_ALL, &w.IVirtualDesktopManager.iid, &raw)) catch return null;
        self.vdm = @ptrCast(@alignCast(raw.?));
        return self.vdm;
    }

    fn desktops(self: *Shell, hwnds: []const u64, other: []bool) bool {
        for (hwnds, other) |h, *o| {
            var retried = false;
            while (true) {
                const vdm = self.manager() orelse return false;
                var on: w.BOOL = 1;
                const hr = vdm.vtable.IsWindowOnCurrentVirtualDesktop(vdm, @ptrFromInt(h), &on);
                if (hr >= 0) {
                    o.* = on == 0;
                    break;
                }
                // A window the manager does not track (E_INVALIDARG): not
                // on another desktop. Any other failure usually means
                // Explorer restarted: reconnect once.
                if (@as(u32, @bitCast(hr)) == 0x80070057) break;
                release(vdm);
                self.vdm = null;
                if (retried) return false;
                retried = true;
            }
        }
        return true;
    }

    fn enumerate(self: *Shell) void {
        var t0: i64 = 0;
        var t1: i64 = 0;
        var freq: i64 = 1;
        _ = w.QueryPerformanceFrequency(&freq);
        _ = w.QueryPerformanceCounter(&t0);
        defer {
            _ = w.QueryPerformanceCounter(&t1);
            self.catalog_ns = @intCast(@divTrunc((t1 - t0) * std.time.ns_per_s, freq));
        }
        _ = self.catalog_arena.reset(.retain_capacity);
        self.catalog_apps = &.{};
        self.catalog_error = null;
        self.catalog_apps = self.enumerateApps() catch |err| {
            std.debug.print("neo-compute: Start menu enumeration failed: {t} hr=0x{x}\n", .{ err, com.lastHr() });
            self.catalog_error = "Menu Démarrer illisible (FOLDERID_AppsFolder) : réessaie, ou utilise key et type.";
            return;
        };
    }

    fn enumerateApps(self: *Shell) ![]const apps.App {
        const a = self.catalog_arena.allocator();
        var raw: ?*anyopaque = null;
        try check(w.SHGetKnownFolderItem(&w.FOLDERID_AppsFolder, w.KF_FLAG_DEFAULT, null, &w.IShellItem.iid, &raw));
        const folder: *w.IShellItem = @ptrCast(@alignCast(raw.?));
        defer release(folder);
        var raw_enum: ?*anyopaque = null;
        try check(folder.vtable.BindToHandler(folder, null, &w.BHID_EnumItems, &w.IEnumShellItems.iid, &raw_enum));
        const items: *w.IEnumShellItems = @ptrCast(@alignCast(raw_enum.?));
        defer release(items);
        var out: std.ArrayList(apps.App) = .empty;
        var batch: [64]?*w.IShellItem = undefined;
        while (out.items.len < max_apps) {
            var fetched: u32 = 0;
            const hr = items.vtable.Next(items, batch.len, &batch, &fetched);
            if (hr < 0 or fetched == 0) break;
            for (batch[0..fetched]) |maybe| {
                const item = maybe orelse continue;
                defer release(item);
                if (out.items.len < max_apps) if (try entry(a, item)) |app| try out.append(a, app);
            }
            if (hr != w.S_OK) break;
        }
        return out.items;
    }

    /// Display name and AUMID (PKEY_AppUserModel_ID) of one Start menu item;
    /// null for an item without AUMID.
    fn entry(a: std.mem.Allocator, item: *w.IShellItem) !?apps.App {
        var raw: ?*anyopaque = null;
        if (item.vtable.QueryInterface(item, &w.IShellItem2.iid, &raw) < 0) return null;
        const item2: *w.IShellItem2 = @ptrCast(@alignCast(raw.?));
        defer release(item2);
        const aumid = try stringProperty(a, item2, &w.PKEY_AppUserModel_ID) orelse return null;
        var name_w: w.PWSTR = null;
        if (item2.vtable.GetDisplayName(item2, w.SIGDN_NORMALDISPLAY, &name_w) < 0) return null;
        const name = try takeString(a, name_w);
        // A packaged application's AUMID is `<package family>!<app id>`. A
        // shortcut's executable is resolved at launch (`targetExe`).
        return .{ .name = name, .aumid = aumid, .packaged = std.mem.indexOfScalar(u8, aumid, '!') != null };
    }

    fn stringProperty(a: std.mem.Allocator, item: *w.IShellItem2, key: *const w.PROPERTYKEY) !?[]const u8 {
        var s: w.PWSTR = null;
        if (item.vtable.GetString(item, key, &s) < 0 or s == null) return null;
        const v = try takeString(a, s);
        return if (v.len == 0) null else v;
    }

    /// UTF-8 copy of a CoTaskMemAlloc'd string, which is freed.
    fn takeString(a: std.mem.Allocator, s: w.PWSTR) ![]const u8 {
        const p = s orelse return "";
        defer w.CoTaskMemFree(@ptrCast(p));
        const wide = std.mem.span(@as([*:0]const u16, @ptrCast(p)));
        const buf = try a.alloc(u8, wide.len * 3);
        return buf[0..std.unicode.wtf16LeToWtf8(buf, wide)];
    }

    fn runActivate(self: *Shell) Launch {
        const act = self.activation orelse blk: {
            var raw: ?*anyopaque = null;
            check(w.CoCreateInstance(&w.CLSID_ApplicationActivationManager, null, w.CLSCTX_ALL, &w.IApplicationActivationManager.iid, &raw)) catch
                return .{ .refused = com.lastHr() };
            self.activation = @ptrCast(@alignCast(raw.?));
            break :blk self.activation.?;
        };
        var pid: u32 = 0;
        const hr = act.vtable.ActivateApplication(act, &self.text, null, w.AO_NONE, &pid);
        if (hr < 0) return .{ .refused = @bitCast(hr) };
        return .{ .ok = if (pid != 0) pid else null };
    }

    fn runExecute(self: *Shell) Launch {
        var info: w.SHELLEXECUTEINFOW = std.mem.zeroes(w.SHELLEXECUTEINFOW);
        info.cbSize = @sizeOf(w.SHELLEXECUTEINFOW);
        info.fMask = w.SEE_MASK_NOCLOSEPROCESS | w.SEE_MASK_FLAG_NO_UI;
        info.lpFile = &self.text;
        info.nShow = switch (self.show) {
            .normal => w.SW_SHOWNORMAL,
            .no_activate => w.SW_SHOWNOACTIVATE,
            .minimized => w.SW_SHOWMINNOACTIVE,
        };
        if (w.ShellExecuteExW(&info) == 0) {
            const err = w.GetLastError();
            return .{ .refused = 0x80070000 | (err & 0xFFFF) };
        }
        // A NULL hProcess is a normal outcome: the shell or an existing
        // instance handled the request.
        const h = info.hProcess orelse return .{ .ok = null };
        defer _ = w.CloseHandle(h);
        const pid = w.GetProcessId(h);
        return .{ .ok = if (pid != 0) pid else null };
    }

    /// Target path of the shortcut behind `shell:AppsFolder\<AUMID>`.
    fn runTarget(self: *Shell) usize {
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral("shell:AppsFolder\\");
        var path: [prefix.len + 2048:0]u16 = undefined;
        const n = std.mem.indexOfSentinel(u16, 0, &self.text);
        @memcpy(path[0..prefix.len], prefix);
        @memcpy(path[prefix.len..][0..n], self.text[0..n]);
        path[prefix.len + n] = 0;
        var raw: ?*anyopaque = null;
        if (w.SHCreateItemFromParsingName(&path, null, &w.IShellItem2.iid, &raw) < 0) return 0;
        const item: *w.IShellItem2 = @ptrCast(@alignCast(raw.?));
        defer release(item);
        var s: w.PWSTR = null;
        if (item.vtable.GetString(item, &w.PKEY_Link_TargetParsingPath, &s) < 0) return 0;
        const p = s orelse return 0;
        defer w.CoTaskMemFree(@ptrCast(p));
        const wide = std.mem.span(@as([*:0]const u16, @ptrCast(p)));
        if (wide.len > self.exe_buf.len) return 0;
        @memcpy(self.exe_buf[0..wide.len], wide);
        return wide.len;
    }

    /// Windows classes the extension in `text` as dangerous, or its default
    /// verb's command line starts with the file itself (`%1` or `%L`,
    /// quoted or not).
    fn runUnsafe(self: *Shell) bool {
        if (w.AssocIsDangerous(&self.text) != 0) return true;
        var cmd: [1024]u16 = undefined;
        var len: u32 = cmd.len;
        // No verb: the default one, as ShellExecuteExW without lpVerb.
        if (w.AssocQueryStringW(w.ASSOCF_INIT_IGNOREUNKNOWN, w.ASSOCSTR_COMMAND, &self.text, null, @ptrCast(&cmd), &len) < 0) return false;
        const n = if (len > 0) len - 1 else 0;
        return apps.commandRunsFile(cmd[0..n]);
    }

    fn runAssoc(self: *Shell) usize {
        var len: u32 = self.exe_buf.len;
        const open = std.unicode.utf8ToUtf16LeStringLiteral("open");
        if (w.AssocQueryStringW(w.ASSOCF_INIT_IGNOREUNKNOWN, w.ASSOCSTR_EXECUTABLE, &self.text, open, @ptrCast(&self.exe_buf), &len) < 0) return 0;
        // `len` counts the terminating zero.
        return if (len > 1) len - 1 else 0;
    }
};
