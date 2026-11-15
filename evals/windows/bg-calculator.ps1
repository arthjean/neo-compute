param([ValidateSet('available', 'setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'available' { Test-CalculatorAbsent }
    'setup' {
        Start-Calculator
        Hide-UnderDecoy (Find-Window 'Calculatrice')
    }
    'solve' {
        $w = Get-DeskWindow 'Calculatrice'
        foreach ($key in 'Cinq', 'Huit', 'Multiplier par', 'Un', 'Sept', 'Est égal à') {
            [void](Invoke-Desk 'ui_act' @{ id = (Find-DeskId "`"$key`"" "button `"$key`"" $w); action = 'invoke' })
        }
    }
    'verify' {
        $name = Get-CalculatorDisplay
        if ($null -eq $name) { return New-Result $false 'Calculatrice fermée ou affichage introuvable' }
        New-Result (($name -replace '\D', '') -eq '986') "affichage : $name"
    }
    'cleanup' { Get-Process CalculatorApp -ErrorAction SilentlyContinue | Stop-Process }
}
