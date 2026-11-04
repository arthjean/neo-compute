param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$dir = Join-Path $Work 'explorer-rename'

switch ($Phase) {
    'setup' {
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'rapport-brouillon.txt') 'Rapport trimestriel, version de travail.'
        Set-Content (Join-Path $dir 'annexe.txt') 'Annexe.'
        Start-Process explorer.exe $dir
        Show-Window (Wait-Window 'explorer-rename*')
    }
    'verify' {
        $final = Test-Path (Join-Path $dir 'rapport-final.txt')
        $draft = Test-Path (Join-Path $dir 'rapport-brouillon.txt')
        $names = (Get-ChildItem $dir -Name) -join ', '
        New-Result ($final -and -not $draft) "fichiers : $names"
    }
    'cleanup' {
        (New-Object -ComObject Shell.Application).Windows() |
            Where-Object { $_.LocationURL -like '*/explorer-rename' } |
            ForEach-Object { $_.Quit() }
    }
}
