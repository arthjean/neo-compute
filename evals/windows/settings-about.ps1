param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' {
        if (Get-Process SystemSettings -ErrorAction SilentlyContinue) { throw 'Paramètres déjà ouverts : ferme-les avant la tâche' }
        Start-Process 'ms-settings:'
        Show-Window (Wait-Window 'Paramètres')
    }
    'verify' {
        $w = Find-Window 'Paramètres'
        if (-not $w) { return New-Result $false 'Paramètres fermés' }
        # Only the Système > Informations système page offers this button.
        $about = @(Get-UiaNames $w) -contains 'Renommer ce PC'
        New-Result $about ($(if ($about) { 'page Informations système affichée' } else { 'autre page affichée' }))
    }
    'cleanup' {
        Get-Process SystemSettings -ErrorAction SilentlyContinue | Stop-Process
    }
}
