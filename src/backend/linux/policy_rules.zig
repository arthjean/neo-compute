//! The built-in policy rules of the Linux server (US-070, decision 0014 P8,
//! answered by Arthur on 2026-11-20): password managers in `deny`, terminals
//! and code editors in `click`, as the Windows lists. Each application is
//! named by its application ids (`.desktop` and Flatpak) and by the base
//! names of its executables; a rule matches any name of a process,
//! without case (`Policy.levelOfNames`).

const policy = @import("core").policy;

/// KeePassXC, Bitwarden, 1Password, Proton Pass. Proton Pass's Electron
/// binary is `/usr/lib/proton-pass/Proton Pass`, space included.
pub const password_managers = [_][]const u8{
    "org.keepassxc.KeePassXC", "keepassxc",
    "com.bitwarden.desktop",   "bitwarden",
    "1password",               "com.onepassword.OnePassword",
    "proton-pass",             "Proton Pass",
    "me.proton.Pass",
};

/// Terminals (GNOME Terminal, Ptyxis, Konsole, kitty, Alacritty, foot,
/// WezTerm, Ghostty, xterm, Paneflow) and code editors (VS Code, Cursor,
/// Windsurf, Zed): typing there is shell access outside Claude Code's
/// permissions, so only clicks are allowed by default. GNOME Terminal's
/// windows belong to `gnome-terminal-server`; Zed's to `zed-editor`, which
/// its `zed` and `zeditor` launchers start.
pub const shells = [_][]const u8{
    "org.gnome.Terminal",     "gnome-terminal-server", "gnome-terminal",
    "org.gnome.Ptyxis",       "ptyxis",                "org.kde.konsole",
    "konsole",                "kitty",                 "Alacritty",
    "alacritty",              "foot",                  "footclient",
    "org.wezfurlong.wezterm", "wezterm-gui",           "wezterm",
    "com.mitchellh.ghostty",  "ghostty",               "xterm",
    "uxterm",                 "paneflow",              "code",
    "com.visualstudio.code",  "code-insiders",         "cursor",
    "windsurf",               "zed",                   "zeditor",
    "zed-editor",             "dev.zed.Zed",
};

pub const rules = blk: {
    var out: [password_managers.len + shells.len]policy.Rule = undefined;
    for (password_managers, 0..) |name, i| out[i] = .{ .exe = name, .level = .deny };
    for (shells, 0..) |name, i| out[password_managers.len + i] = .{ .exe = name, .level = .click };
    break :blk out;
};

const std = @import("std");
const testing = std.testing;

test "KeePassXC started from a terminal is denied by its executable name alone" {
    const p: policy.Policy = .{ .builtin = &rules };
    // vte-spawn scope: no application id, the executable only.
    try testing.expectEqual(policy.Level.deny, p.levelOfNames(&.{"keepassxc"}));
    try testing.expectEqual(policy.Level.deny, p.levelOfNames(&.{ "KeePassXC", "org.keepassxc.KeePassXC" }));
    // Proton Pass by its application id, whatever its binary is called.
    try testing.expectEqual(policy.Level.deny, p.levelOfNames(&.{ "electron", "proton-pass" }));
    try testing.expectEqual(policy.Level.click, p.levelOfNames(&.{ "gnome-terminal-server", "org.gnome.Terminal" }));
    try testing.expectEqual(policy.Level.click, p.levelOfNames(&.{"ZED-EDITOR"}));
    try testing.expectEqual(policy.Level.click, p.levelOfNames(&.{ "zed", "dev.zed.Zed" }));
    try testing.expectEqual(policy.Level.full, p.levelOfNames(&.{ "gnome-calculator", "org.gnome.Calculator" }));
    // The file's rules come first, by any name.
    const user: policy.Policy = .{ .builtin = &rules, .rules = &.{.{ .exe = "org.gnome.Ptyxis", .level = .full }} };
    try testing.expectEqual(policy.Level.full, user.levelOfNames(&.{ "ptyxis", "org.gnome.Ptyxis" }));
}

test "every application of decision 0014 P8 has a rule" {
    const p: policy.Policy = .{ .builtin = &rules };
    for ([_][]const u8{ "keepassxc", "bitwarden", "1password", "proton-pass" }) |n| try testing.expectEqual(policy.Level.deny, p.levelOfNames(&.{n}));
    for ([_][]const u8{ "gnome-terminal-server", "ptyxis", "konsole", "kitty", "alacritty", "foot", "wezterm-gui", "ghostty", "xterm", "paneflow", "code", "cursor", "windsurf", "zed", "zeditor", "dev.zed.Zed" }) |n|
        try testing.expectEqual(policy.Level.click, p.levelOfNames(&.{n}));
}
