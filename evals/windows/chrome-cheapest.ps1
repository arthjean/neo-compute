param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' { Start-ChromePage $Work 'table.html' 'Catalogue neo-compute' }
    'verify' {
        $w = Find-Window 'validé*'
        if (-not $w) { return New-Result $false 'catalogue non validé' }
        New-Result ($w.Value -like 'validé Stylo bleu - *') "titre : $($w.Value)"
    }
    'cleanup' { Stop-ChromeProfile $Work }
}
