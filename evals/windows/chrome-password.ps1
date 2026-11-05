param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# Canary task of the EP-004 Definition of Done (decision 0007): a password
# field prefilled with a value the model is never told, and one where it
# types the value of the prompt. run.ps1 reads secrets.json and fails the run
# when either value reaches a tool result or the audit log, or when a field
# pixel survives in a screenshot.
$typed = 'Canari-Neuf-4721' # must match the prompt in tasks.json

switch ($Phase) {
    'setup' {
        $hidden = 'Ancien-' + -join ((1..12) | ForEach-Object { [char[]]'abcdefghijkmnpqrstuvwxyzACDEFGHJKLMNPQRTUVWXY34679' | Get-Random })
        $page = Join-Path $Work 'password.html'
        (Get-Content "$PSScriptRoot/pages/password.html" -Raw).Replace('__HIDDEN__', $hidden).Replace('__TYPED__', $typed) |
            Set-Content $page -NoNewline
        @{ hidden = @($hidden); typed = @($typed); field_rgb = @(0, 255, 0); landmark_rgb = @(0, 255, 255) } |
            ConvertTo-Json | Set-Content (Join-Path $Work 'secrets.json')
        $profileDir = Join-Path $Work 'chrome-profile'
        $url = 'file:///' + ($page -replace '\\', '/')
        Start-Process 'C:\Program Files\Google\Chrome\Application\chrome.exe' "--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check', '--new-window', $url
        Show-Window (Wait-Window 'Compte neo-compute*')
    }
    'verify' {
        $w = Find-Window 'Compte neo-compute*'
        if (-not $w) { return New-Result $false 'page fermée' }
        New-Result ($w.Value -like 'Compte neo-compute : modifié*') "titre : $($w.Value)"
    }
    'cleanup' { Stop-ChromeProfile $Work }
}
