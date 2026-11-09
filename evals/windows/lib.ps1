# Helpers shared by the task scripts: top-level windows by title, window
# closing, and UI Automation reads for final-state checks. Verification never
# goes through neo-compute: it reads Win32, UIA, files and the registry itself.

if (-not ('Evals.Win' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Evals {
    public static class Win {
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);

        public static List<KeyValuePair<IntPtr, string>> Top() {
            var r = new List<KeyValuePair<IntPtr, string>>();
            EnumWindows((h, l) => {
                if (IsWindowVisible(h)) {
                    var s = new StringBuilder(512);
                    GetWindowTextW(h, s, 512);
                    if (s.Length > 0) r.Add(new KeyValuePair<IntPtr, string>(h, s.ToString()));
                }
                return true;
            }, IntPtr.Zero);
            return r;
        }
    }
}
'@
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

function New-Result([bool]$Ok, [string]$Detail) {
    [pscustomobject]@{ ok = $Ok; detail = $Detail }
}

# First visible top-level window whose title matches the wildcard pattern.
function Find-Window([string]$Like) {
    [Evals.Win]::Top() | Where-Object { $_.Value -like $Like } | Select-Object -First 1
}

function Wait-Window([string]$Like, [int]$Seconds = 20) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $w = Find-Window $Like
        if ($w) { return $w }
        Start-Sleep -Milliseconds 250
    }
    throw "no window matching '$Like' within $Seconds s"
}

# Brings the window to the foreground and gives it time to render.
function Show-Window($Window) {
    [void][Evals.Win]::SetForegroundWindow($Window.Key)
    Start-Sleep -Milliseconds 1500
}

function Close-Window([string]$Like) {
    foreach ($w in [Evals.Win]::Top() | Where-Object { $_.Value -like $Like }) {
        [void][Evals.Win]::PostMessageW($w.Key, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    }
}

function Get-UiaRoot($Window) {
    [System.Windows.Automation.AutomationElement]::FromHandle($Window.Key)
}

# Descendant names of a window, for checks on what a page shows.
function Get-UiaNames($Window) {
    $all = (Get-UiaRoot $Window).FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) { $e.Current.Name }
}

function Get-UiaByAutomationId($Window, [string]$Id) {
    $c = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::AutomationIdProperty), $Id
    (Get-UiaRoot $Window).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}

# Notepad restores the previous session's tabs at launch, which would put the
# user's own notes in front of the model. A Notepad task moves the session
# aside (rename on the same volume) before launching, and puts it back after.
$notepadState = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState'
$notepadDirs = 'TabState', 'WindowState'

function Suspend-NotepadSession {
    if (Get-Process Notepad -ErrorAction SilentlyContinue) { throw 'Bloc-notes déjà ouvert : ferme-le avant la tâche' }
    foreach ($d in $notepadDirs) {
        $src = Join-Path $notepadState $d
        if (Test-Path "$src.neo-evals") { throw "sauvegarde $src.neo-evals déjà présente : lance Restore-NotepadSession avant la tâche" }
        if (Test-Path $src) { Rename-Item $src "$d.neo-evals" } else { New-Item -ItemType Directory "$src.neo-evals" | Out-Null }
    }
}

function Restore-NotepadSession {
    Get-Process Notepad -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process Notepad -ErrorAction SilentlyContinue | Wait-Process -Timeout 10
    foreach ($d in $notepadDirs) {
        $src = Join-Path $notepadState $d
        if (-not (Test-Path "$src.neo-evals")) { continue }
        # What is there now is the eval session only. Its files stay locked a
        # moment after Notepad exits.
        for ($i = 0; (Test-Path $src) -and $i -lt 40; $i++) {
            try { Remove-Item -Recurse -Force $src } catch { Start-Sleep -Milliseconds 250 }
        }
        if (Test-Path $src) { throw "session du Bloc-notes de l'éval encore verrouillée : $src ; la sauvegarde reste dans $src.neo-evals" }
        Rename-Item "$src.neo-evals" $d
    }
}

function Start-NotepadFile([string]$File) {
    Suspend-NotepadSession
    $title = "$(Split-Path $File -Leaf)*Bloc-notes*"
    Start-Process notepad.exe "`"$File`""
    try { $w = Wait-Window $title } catch {
        # A launch right after a kill sometimes shows no window: once more.
        Get-Process Notepad -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 2
        Start-Process notepad.exe "`"$File`""
        $w = Wait-Window $title
    }
    Show-Window $w
}

# Chrome on an isolated profile under the run directory, showing one of
# evals/windows/pages.
function Start-ChromePage([string]$Work, [string]$Page, [string]$Title) {
    $profileDir = Join-Path $Work 'chrome-profile'
    $copy = Join-Path $Work $Page
    Copy-Item "$PSScriptRoot/pages/$Page" $copy
    $url = 'file:///' + ($copy -replace '\\', '/')
    Start-Process 'C:\Program Files\Google\Chrome\Application\chrome.exe' "--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check', '--new-window', $url
    Show-Window (Wait-Window "$Title*")
}

function Stop-ChromeProfile([string]$Work) {
    $profileDir = Join-Path $Work 'chrome-profile'
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
        Where-Object { $_.CommandLine -like "*$profileDir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
}

# Closes the windows on that folder or below it: the model may have opened a
# subfolder (explorer-move leaves windows on Tri).
function Close-ExplorerFolder([string]$Leaf) {
    (New-Object -ComObject Shell.Application).Windows() |
        Where-Object { $_.LocationURL -like "*/$Leaf" -or $_.LocationURL -like "*/$Leaf/*" } |
        ForEach-Object { $_.Quit() }
}

function Start-VSCodeFile([string]$File) {
    Start-Process cmd.exe '/c', 'code', '--new-window', "`"$File`"" -WindowStyle Hidden
    Show-Window (Wait-Window "$(Split-Path $File -Leaf)*Visual Studio Code*" 30)
}

function Start-Calculator {
    if (Get-Process CalculatorApp -ErrorAction SilentlyContinue) { throw 'Calculatrice déjà ouverte : ferme-la avant la tâche' }
    Start-Process calc.exe
    Show-Window (Wait-Window 'Calculatrice')
}

function Get-CalculatorDisplay {
    $w = Find-Window 'Calculatrice'
    if (-not $w) { return $null }
    $display = Get-UiaByAutomationId $w 'CalculatorResults'
    if ($display) { $display.Current.Name } else { $null }
}

function Start-SettingsHome {
    if (Get-Process SystemSettings -ErrorAction SilentlyContinue) { throw 'Paramètres déjà ouverts : ferme-les avant la tâche' }
    Start-Process 'ms-settings:'
    Show-Window (Wait-Window 'Paramètres')
}

# Whether the Settings window shows an element of that exact name.
function Test-SettingsShows([string]$Name) {
    $w = Find-Window 'Paramètres'
    if (-not $w) { return New-Result $false 'Paramètres fermés' }
    $shown = @(Get-UiaNames $w) -contains $Name
    New-Result $shown ($(if ($shown) { "« $Name » affiché" } else { "« $Name » absent" }))
}

# Text of a file with CRLF folded to LF and the final newline dropped.
function Read-Text([string]$File) {
    ([System.IO.File]::ReadAllText($File) -replace "`r`n", "`n").TrimEnd("`n")
}

# Parity tasks (US-037): window geometry, clipboard and Firefox helpers.
# Geometry is read per-monitor DPI aware, like the server: DWM frame bounds
# are physical pixels whatever the caller's awareness.
if (-not ('Evals.Desk' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Evals {
    public static class Desk {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT mon; public RECT work; public uint flags; }
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int n);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint f);
        [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr m, ref MONITORINFO i);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

        public static int ProcessOf(IntPtr h) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return (int)pid;
        }
        [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr h);
        [DllImport("user32.dll")] static extern bool CloseClipboard();
        [DllImport("user32.dll")] static extern bool EmptyClipboard();
        [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint f, IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint f);
        [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint f);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormatW(string name);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint f, UIntPtr n);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
        [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr h);

        static readonly IntPtr PerMonitorV2 = new IntPtr(-4);
        const uint CF_UNICODETEXT = 13;
        // The formats US-035 treats as a secret marker.
        public static readonly string[] Markers = {
            "ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore",
            "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard" };

        static int[] Rect(RECT r) { return new[] { r.l, r.t, r.r, r.b }; }

        // Visible frame of a window (DWMWA_EXTENDED_FRAME_BOUNDS): l, t, r, b.
        public static int[] Frame(IntPtr h) {
            var old = SetThreadDpiAwarenessContext(PerMonitorV2);
            try {
                RECT r;
                if (DwmGetWindowAttribute(h, 9, out r, 16) != 0) return null;
                return Rect(r);
            } finally { SetThreadDpiAwarenessContext(old); }
        }

        // Work area of the primary monitor: l, t, r, b.
        public static int[] PrimaryWorkArea() {
            var old = SetThreadDpiAwarenessContext(PerMonitorV2);
            try {
                var i = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
                GetMonitorInfoW(MonitorFromPoint(new POINT(), 1), ref i);
                return Rect(i.work);
            } finally { SetThreadDpiAwarenessContext(old); }
        }

        // Whether the window is mostly on the primary monitor.
        public static bool OnPrimary(IntPtr h) {
            var i = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
            GetMonitorInfoW(MonitorFromWindow(h, 2), ref i);
            return (i.flags & 1) != 0;
        }

        // Restores the window and moves its outer rectangle, in physical pixels.
        public static void Place(IntPtr h, int x, int y, int w, int ht) {
            var old = SetThreadDpiAwarenessContext(PerMonitorV2);
            try {
                ShowWindow(h, 9); // SW_RESTORE
                SetWindowPos(h, IntPtr.Zero, x, y, w, ht, 0x0014); // SWP_NOZORDER | SWP_NOACTIVATE
            } finally { SetThreadDpiAwarenessContext(old); }
        }

        static bool Open() {
            for (int i = 0; i < 20; i++) {
                if (OpenClipboard(IntPtr.Zero)) return true;
                Thread.Sleep(10);
            }
            return false;
        }

        static IntPtr Global(byte[] bytes) {
            var g = GlobalAlloc(0x0002, (UIntPtr)bytes.Length); // GMEM_MOVEABLE
            var p = GlobalLock(g);
            Marshal.Copy(bytes, 0, p, bytes.Length);
            GlobalUnlock(g);
            return g;
        }

        // Replaces the clipboard with the text and the given marker formats,
        // each a DWORD 0 as password managers write them.
        public static void SetText(string text, string[] markers) {
            if (!Open()) throw new InvalidOperationException("clipboard busy");
            try {
                EmptyClipboard();
                if (text != null) {
                    var t = Global(System.Text.Encoding.Unicode.GetBytes(text + "\0"));
                    if (SetClipboardData(CF_UNICODETEXT, t) == IntPtr.Zero) { GlobalFree(t); throw new InvalidOperationException("SetClipboardData failed"); }
                }
                foreach (var m in markers ?? new string[0]) {
                    var g = Global(new byte[4]);
                    if (SetClipboardData(RegisterClipboardFormatW(m), g) == IntPtr.Zero) GlobalFree(g);
                }
            } finally { CloseClipboard(); }
        }

        public static bool HasMarker() {
            foreach (var m in Markers) if (IsClipboardFormatAvailable(RegisterClipboardFormatW(m))) return true;
            return false;
        }

        public static bool HasFormat(string name) {
            return IsClipboardFormatAvailable(RegisterClipboardFormatW(name));
        }

        public static string GetText() {
            if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return null;
            if (!Open()) return null;
            try {
                var h = GetClipboardData(CF_UNICODETEXT);
                if (h == IntPtr.Zero) return null;
                var p = GlobalLock(h);
                try { return Marshal.PtrToStringUni(p); } finally { GlobalUnlock(h); }
            } finally { CloseClipboard(); }
        }
    }
}
'@
}

# The user's clipboard text, kept in memory between the setup and cleanup
# phases (run.ps1 calls both in its own process), never on disk. Content a
# password manager marked secret is not kept: it would come back unmarked
# and enter the clipboard history.
function Save-UserClipboard {
    $global:NeoEvalsClipboard = if ([Evals.Desk]::HasMarker()) { $null } else { [Evals.Desk]::GetText() }
}

function Restore-UserClipboard {
    [Evals.Desk]::SetText($global:NeoEvalsClipboard, @())
    $global:NeoEvalsClipboard = $null
}

# The model's last « RÉPONSE : » line, which run.ps1 writes to answer.txt
# from the final message of the session; $null before the run.
function Read-Answer([string]$Work) {
    $file = Join-Path $Work 'answer.txt'
    if (-not (Test-Path $file)) { return $null }
    $hits = [regex]::Matches([System.IO.File]::ReadAllText($file), '(?im)^\W*R[ÉE]PONSE\W*:\s*(.+?)\s*$')
    if (-not $hits.Count) { return $null }
    $hits[$hits.Count - 1].Groups[1].Value.Trim(' ', '*', '`', '"', '«', '»', '.')
}

# Firefox on an isolated profile without its first-run pages, as in the
# bench (US-025). NEO_EVALS_FIREFOX points elsewhere to prove the skip on a
# machine without Firefox.
$firefoxExe = if ($env:NEO_EVALS_FIREFOX) { $env:NEO_EVALS_FIREFOX } else { 'C:\Program Files\Mozilla Firefox\firefox.exe' }

function Start-FirefoxPage([string]$Work, [string]$Page, [string]$Title) {
    $profileDir = Join-Path $Work 'firefox-profile'
    New-Item -ItemType Directory -Force $profileDir | Out-Null
    @(
        'user_pref("browser.shell.checkDefaultBrowser", false);'
        'user_pref("browser.aboutwelcome.enabled", false);'
        'user_pref("browser.startup.homepage_override.mstone", "ignore");'
        'user_pref("startup.homepage_welcome_url", "");'
        'user_pref("startup.homepage_welcome_url.additional", "");'
        'user_pref("browser.startup.firstrunSkipsHomepage", true);'
        'user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);'
        'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);'
        'user_pref("browser.tabs.warnOnClose", false);'
        'user_pref("app.update.auto", false);'
        'user_pref("browser.sessionstore.resume_from_crash", false);'
    ) | Set-Content (Join-Path $profileDir 'user.js')
    $copy = Join-Path $Work $Page
    Copy-Item "$PSScriptRoot/pages/$Page" $copy
    $url = 'file:///' + ($copy -replace '\\', '/')
    Start-Process $firefoxExe '-profile', "`"$profileDir`"", '-no-remote', '-new-window', $url
    Show-Window (Wait-Window "$Title*" 30)
}

function Stop-FirefoxProfile([string]$Work) {
    $profileDir = Join-Path $Work 'firefox-profile'
    Get-CimInstance Win32_Process -Filter "Name='firefox.exe'" |
        Where-Object { $_.CommandLine -like "*$profileDir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
}

# Scripted solutions (run.ps1 -DryRun -Solve) drive the applications through
# UIA and SendKeys, never through neo-compute, to prove that each check
# accepts the final state the prompt asks for.

# First element of the process, in any of its top-level windows (menus and
# dialogs included), whose name matches the wildcard pattern.
function Find-UiaInProcess([int]$ProcessId, [string]$Like, [int]$Seconds = 10) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $c = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        foreach ($top in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $c)) {
            if ($top.Current.Name -like $Like) { return $top }
            $hit = $top.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.Name -like $Like } | Select-Object -First 1
            if ($hit) { return $hit }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "élément « $Like » introuvable dans le processus $ProcessId"
}

function Invoke-Uia($Element) {
    $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Expand-Uia($Element) {
    $Element.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
}

function Send-Keys([string]$Keys) {
    (New-Object -ComObject WScript.Shell).SendKeys($Keys)
    Start-Sleep -Milliseconds 400
}

# Names shown by a window, retried while a browser builds its tree for the
# first UIA client.
function Wait-UiaText($Window, [string]$Pattern, [int]$Seconds = 15) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $hit = @(Get-UiaNames $Window) | Where-Object { $_ -match $Pattern } | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "texte /$Pattern/ absent de la fenêtre « $($Window.Value) »"
}

function Write-Answer([string]$Work, [string]$Answer) {
    [System.IO.File]::WriteAllText((Join-Path $Work 'answer.txt'), "TERMINÉ`nRÉPONSE : $Answer")
}

# Explorer window on a folder of the run, by its location.
function Get-ExplorerWindow([string]$Leaf) {
    (New-Object -ComObject Shell.Application).Windows() |
        Where-Object { $_.LocationURL -like "*/$Leaf" } | Select-Object -First 1
}
