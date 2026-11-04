param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# An isolated profile: no extension, sync or restored tab of the user's own.
$profileDir = Join-Path $Work 'chrome-profile'
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'

switch ($Phase) {
    'setup' {
        $page = Join-Path $Work 'form.html'
        Copy-Item "$PSScriptRoot/pages/form.html" $page
        $url = 'file:///' + ($page -replace '\\', '/')
        Start-Process $chrome "--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check', '--new-window', $url
        Show-Window (Wait-Window 'Formulaire neo-compute*')
    }
    'verify' {
        $want = 'envoyé nom=Ada Lovelace;pays=Belgique;abonne=oui'
        $sent = Find-Window 'envoyé nom=*'
        if (-not $sent) { return New-Result $false 'formulaire non envoyé' }
        New-Result ($sent.Value -like "$want*") "titre : $($sent.Value)"
    }
    'cleanup' {
        Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
            Where-Object { $_.CommandLine -like "*$profileDir*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    }
}
