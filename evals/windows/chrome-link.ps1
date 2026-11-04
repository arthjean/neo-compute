param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' { Start-ChromePage $Work 'links.html' 'Liste neo-compute' }
    'verify' {
        $w = Find-Window 'ouvert article *'
        if (-not $w) { return New-Result $false 'aucun article ouvert' }
        New-Result ($w.Value -like 'ouvert article 47 *') "titre : $($w.Value)"
    }
    'cleanup' { Stop-ChromeProfile $Work }
}
