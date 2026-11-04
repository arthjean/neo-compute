param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' { Start-SettingsHome }
    # Only the Système > Écran page shows the monitor layout.
    'verify' { Test-SettingsShows 'Disposition du moniteur' }
    'cleanup' { Get-Process SystemSettings -ErrorAction SilentlyContinue | Stop-Process }
}
