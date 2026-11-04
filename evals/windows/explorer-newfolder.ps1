param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$dir = Join-Path $Work 'explorer-new'

switch ($Phase) {
    'setup' {
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'budget.txt') 'Budget.'
        Start-Process explorer.exe $dir
        Show-Window (Wait-Window 'explorer-new*')
    }
    'verify' {
        $made = Test-Path (Join-Path $dir 'Archives 2026') -PathType Container
        New-Result $made "contenu : $((Get-ChildItem $dir -Name) -join ', ')"
    }
    'cleanup' { Close-ExplorerFolder 'explorer-new' }
}
