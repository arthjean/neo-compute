param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# US-029: the model opens Calculator itself, from its name; nothing is open
# at the start.

switch ($Phase) {
    'setup' {
        if (Get-Process CalculatorApp -ErrorAction SilentlyContinue) { throw 'Calculatrice déjà ouverte : ferme-la avant la tâche' }
    }
    'solve' {
        Start-Calculator
        Send-Keys '37*43='
    }
    'verify' {
        $name = Get-CalculatorDisplay
        if ($null -eq $name) { return New-Result $false 'Calculatrice fermée ou affichage introuvable' }
        New-Result (($name -replace '\D', '') -eq '1591') "affichage : $name"
    }
    'cleanup' {
        Get-Process CalculatorApp -ErrorAction SilentlyContinue | Stop-Process
    }
}
