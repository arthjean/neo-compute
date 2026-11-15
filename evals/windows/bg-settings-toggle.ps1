param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$saved = Join-Path $Work 'shaking.txt'

switch ($Phase) {
    'setup' {
        if (Get-Process SystemSettings -ErrorAction SilentlyContinue) { throw 'Paramètres déjà ouverts : ferme-les avant la tâche' }
        $before = (Get-ItemProperty $key -Name DisallowShaking -ErrorAction SilentlyContinue).DisallowShaking
        Set-Content $saved $(if ($null -eq $before) { 'absent' } else { $before }) -NoNewline
        Set-ItemProperty $key -Name DisallowShaking -Value 1 -Type DWord
        Start-Process 'ms-settings:multitasking'
        $w = Wait-Window 'Paramètres'
        Show-Window $w
        Hide-UnderDecoy $w
    }
    'solve' {
        $w = Get-DeskWindow 'Paramètres'
        [void](Invoke-DeskAct (Find-DeskId 'Secousse' 'button "Secousse de la fenêtre de barre de titre"' $w) 'check')
        Start-Sleep -Milliseconds 500
    }
    'verify' {
        $now = (Get-ItemProperty $key -Name DisallowShaking -ErrorAction SilentlyContinue).DisallowShaking
        New-Result ($now -eq 0) "DisallowShaking : $now"
    }
    'cleanup' {
        Get-Process SystemSettings -ErrorAction SilentlyContinue | Stop-Process
        if (Test-Path $saved) {
            $before = Get-Content $saved -Raw
            if ($before -eq 'absent') { Remove-ItemProperty $key -Name DisallowShaking -ErrorAction SilentlyContinue } else { Set-ItemProperty $key -Name DisallowShaking -Value ([int]$before) -Type DWord }
        }
    }
}
