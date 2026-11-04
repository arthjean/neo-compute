param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' { Start-ChromePage $Work 'long.html' 'Conditions neo-compute' }
    'verify' {
        $w = Find-Window '*confirmé - *'
        if (-not $w) { return New-Result $false 'formulaire non envoyé' }
        New-Result ($w.Value -like 'confirmé - *') "titre : $($w.Value)"
    }
    'cleanup' { Stop-ChromeProfile $Work }
}
