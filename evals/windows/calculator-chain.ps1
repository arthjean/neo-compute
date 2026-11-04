param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' { Start-Calculator }
    'verify' {
        $name = Get-CalculatorDisplay
        if ($null -eq $name) { return New-Result $false 'affichage introuvable' }
        New-Result (($name -replace '[^\d,]', '') -eq '12,5') "affichage : $name"
    }
    'cleanup' { Get-Process CalculatorApp -ErrorAction SilentlyContinue | Stop-Process }
}
