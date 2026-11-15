param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' { Start-Panel $Work }
    'solve' {
        $w = Get-DeskWindow 'Réglages neo-compute'
        [void](Invoke-DeskAct (Find-DeskId 'Qualité' 'combobox' $w) 'select' 'Maximale')
    }
    'verify' {
        $s = Read-PanelState $Work
        if (-not $s) { return New-Result $false 'état de la fenêtre Réglages illisible' }
        New-Result ($s.quality -eq 'Maximale' -and $s.volume -eq 20 -and $s.city -eq '') "qualité : $($s.quality), volume : $($s.volume), ville : « $($s.city) »"
    }
    'cleanup' { Stop-Panel $Work }
}
