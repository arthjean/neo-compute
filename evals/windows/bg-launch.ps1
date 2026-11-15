param([ValidateSet('available', 'setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'available' { Test-CalculatorAbsent }
    'setup' {
        if (Get-Process CalculatorApp -ErrorAction SilentlyContinue) { throw 'Calculatrice déjà ouverte : ferme-la avant la tâche' }
    }
    'solve' {
        [void](Invoke-Desk 'app_launch' @{ name = 'Calculatrice' })
        [void](Get-DeskWindow 'Calculatrice')
    }
    'verify' {
        $w = Find-Window 'Calculatrice'
        if (-not $w) { return New-Result $false 'aucune fenêtre Calculatrice' }
        $shown = $null -ne (Get-CalculatorDisplay)
        New-Result $shown $(if ($shown) { 'Calculatrice ouverte' } else { 'fenêtre Calculatrice sans affichage' })
    }
    'cleanup' { Get-Process CalculatorApp -ErrorAction SilentlyContinue | Stop-Process }
}
