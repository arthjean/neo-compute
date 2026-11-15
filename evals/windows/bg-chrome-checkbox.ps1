param([ValidateSet('available', 'setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'available' { if (-not (Test-Path $chromeExe)) { "Chrome absent ($chromeExe)" } }
    'setup' {
        Start-ChromePage $Work 'prefs.html' 'Préférences neo-compute'
        Hide-UnderDecoy (Find-Window 'Préférences neo-compute*')
    }
    'solve' {
        $w = Get-DeskWindow 'Préférences neo-compute'
        $scale = [int][regex]::Match((Invoke-Desk 'window_list'), 'primary.* scale=(\d+)').Groups[1].Value
        $decoy = Get-DecoyRect
        [void](Invoke-Desk 'window_set' @{ window = $w; rect = @(([int](($decoy[0] + $decoy[2]) / $scale) - 300), 20, 400, 300) })
        [void](Invoke-DeskAct (Find-DeskId 'Notifications' 'checkbox "Notifications par courriel"' $w 15000) 'check')
    }
    'verify' {
        $want = 'préférences sombre=oui;notifications=oui;lettre=non'
        $deadline = (Get-Date).AddSeconds(3)
        do {
            $page = Find-Window 'préférences sombre=*'
            if (-not $page) { Start-Sleep -Milliseconds 250 }
        } while (-not $page -and (Get-Date) -lt $deadline)
        if (-not $page) { return New-Result $false 'aucune case modifiée' }
        New-Result ($page.Value -like "$want*") "titre : $($page.Value)"
    }
    'cleanup' { Stop-ChromeProfile $Work }
}
