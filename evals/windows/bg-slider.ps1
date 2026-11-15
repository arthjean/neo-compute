param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' { Start-Panel $Work }
    'solve' {
        $w = Get-DeskWindow 'Réglages neo-compute'
        [void](Invoke-DeskAct (Find-DeskId 'Volume' 'slider' $w) 'set_value' '70')
    }
    'verify' {
        $s = Read-PanelState $Work
        if (-not $s) { return New-Result $false 'état de la fenêtre Réglages illisible' }
        New-Result ($s.volume -eq 70 -and $s.quality -eq 'Normale' -and $s.city -eq '') "volume : $($s.volume), qualité : $($s.quality), ville : « $($s.city) »"
    }
    'cleanup' { Stop-Panel $Work }
}
