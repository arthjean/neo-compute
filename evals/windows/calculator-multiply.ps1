param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' {
        if (Get-Process CalculatorApp -ErrorAction SilentlyContinue) { throw 'Calculatrice déjà ouverte : ferme-la avant la tâche' }
        Start-Process calc.exe
        Show-Window (Wait-Window 'Calculatrice')
    }
    'verify' {
        $w = Find-Window 'Calculatrice'
        if (-not $w) { return New-Result $false 'Calculatrice fermée' }
        $display = Get-UiaByAutomationId $w 'CalculatorResults'
        if (-not $display) { return New-Result $false 'affichage introuvable' }
        $name = $display.Current.Name
        New-Result (($name -replace '\D', '') -eq '69104') "affichage : $name"
    }
    'cleanup' {
        Get-Process CalculatorApp -ErrorAction SilentlyContinue | Stop-Process
    }
}
