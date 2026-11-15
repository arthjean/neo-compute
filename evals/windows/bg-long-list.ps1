param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' { Start-Panel $Work }
    'solve' {
        $w = Get-DeskWindow 'Réglages neo-compute'
        [void](Invoke-DeskAct (Find-DeskId 'Quimper' 'listitem "Quimper"' $w) 'select')
    }
    'verify' {
        $s = Read-PanelState $Work
        if (-not $s) { return New-Result $false 'état de la fenêtre Réglages illisible' }
        New-Result ($s.city -eq 'Quimper' -and $s.quality -eq 'Normale' -and $s.volume -eq 20) "ville : « $($s.city) », qualité : $($s.quality), volume : $($s.volume)"
    }
    'cleanup' { Stop-Panel $Work }
}
