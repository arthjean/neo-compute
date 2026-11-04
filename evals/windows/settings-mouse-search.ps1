param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"

switch ($Phase) {
    'setup' { Start-SettingsHome }
    'verify' { Test-SettingsShows 'Vitesse du pointeur de la souris' }
    'cleanup' { Get-Process SystemSettings -ErrorAction SilentlyContinue | Stop-Process }
}
