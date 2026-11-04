param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$dir = Join-Path $Work 'explorer-move'

switch ($Phase) {
    'setup' {
        New-Item -ItemType Directory -Force (Join-Path $dir 'Tri') | Out-Null
        foreach ($i in 1..30) { Set-Content (Join-Path $dir ('fichier-{0:D2}.txt' -f $i)) "Fichier $i." }
        Start-Process explorer.exe $dir
        Show-Window (Wait-Window 'explorer-move*')
    }
    'verify' {
        $moved = Test-Path (Join-Path $dir 'Tri/fichier-23.txt')
        $left = Test-Path (Join-Path $dir 'fichier-23.txt')
        $count = @(Get-ChildItem $dir -File).Count
        New-Result ($moved -and -not $left -and $count -eq 29) "dans Tri : $((Get-ChildItem (Join-Path $dir 'Tri') -Name) -join ', ') ; $count fichiers à la racine"
    }
    'cleanup' { Close-ExplorerFolder 'explorer-move' }
}
