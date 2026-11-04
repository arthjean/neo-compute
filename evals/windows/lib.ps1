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
