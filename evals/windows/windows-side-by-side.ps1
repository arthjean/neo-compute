param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# US-027: two Explorer windows, overlapping at the start, end on the left
# and right halves of the primary monitor's work area. Compared on DWM's
# visible frame, within 3 % of the work area (snap layouts and window_set
# both land there).
$folders = 'cote-gauche', 'cote-droit'

function Test-Half($Window, [int[]]$Area, [bool]$Left) {
    $h = [IntPtr]$Window.HWND
    if ([Evals.Desk]::IsIconic($h)) { return 'réduite' }
    if ([Evals.Desk]::IsZoomed($h)) { return 'agrandie' }
    $f = [Evals.Desk]::Frame($h)
    if (-not $f) { return 'cadre illisible' }
    $w = $Area[2] - $Area[0]
    $mid = $Area[0] + [int]($w / 2)
    $want = if ($Left) { @($Area[0], $Area[1], $mid, $Area[3]) } else { @($mid, $Area[1], $Area[2], $Area[3]) }
    $tolX = 0.03 * $w
    $tolY = 0.03 * ($Area[3] - $Area[1])
    $off = for ($i = 0; $i -lt 4; $i++) { [Math]::Abs($f[$i] - $want[$i]) -gt $(if ($i % 2) { $tolY } else { $tolX }) }
    if ($off -contains $true) { return "cadre $($f -join ',') pour $($want -join ',')" }
    $null
}

switch ($Phase) {
    'setup' {
        $area = [Evals.Desk]::PrimaryWorkArea()
        $w = $area[2] - $area[0]
        $ht = $area[3] - $area[1]
        $i = 0
        foreach ($leaf in $folders) {
            $dir = Join-Path $Work $leaf
            New-Item -ItemType Directory -Force $dir | Out-Null
            Set-Content (Join-Path $dir "$leaf.txt") "Fichier de $leaf."
            Start-Process explorer.exe $dir
            $win = Wait-Window "$leaf*"
            # Overlapping, centered on the primary monitor: neither half holds.
            [Evals.Desk]::Place($win.Key, $area[0] + [int]($w * (0.25 + 0.05 * $i)), $area[1] + [int]($ht * (0.2 + 0.05 * $i)), [int]($w * 0.4), [int]($ht * 0.5))
            $i++
        }
        Show-Window (Wait-Window "$($folders[1])*")
    }
    'solve' {
        # The outer rectangle on each half: the frame inside it is a few
        # pixels of invisible border smaller, well within the tolerance.
        $area = [Evals.Desk]::PrimaryWorkArea()
        $half = [int](($area[2] - $area[0]) / 2)
        foreach ($k in 0..1) {
            $win = Get-ExplorerWindow $folders[$k]
            [Evals.Desk]::Place([IntPtr]$win.HWND, $area[0] + $k * $half, $area[1], $half, $area[3] - $area[1])
        }
        Start-Sleep -Milliseconds 500
    }
    'verify' {
        $area = [Evals.Desk]::PrimaryWorkArea()
        $issues = foreach ($k in 0..1) {
            $win = Get-ExplorerWindow $folders[$k]
            if (-not $win) { "$($folders[$k]) : fermée"; continue }
            $why = Test-Half $win $area ($k -eq 0)
            if ($why) { "$($folders[$k]) : $why" }
        }
        New-Result (-not $issues) $(if ($issues) { $issues -join ' ; ' } else { "côte à côte dans $($area -join ',')" })
    }
    'cleanup' { foreach ($leaf in $folders) { Close-ExplorerFolder $leaf } }
}
