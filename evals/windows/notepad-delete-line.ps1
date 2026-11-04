param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$file = Join-Path $Work 'lignes.txt'
$lines = 1..40 | ForEach-Object { "Ligne $_" }

switch ($Phase) {
    'setup' {
        Set-Content $file $lines
        Start-NotepadFile $file
    }
    'verify' {
        $want = ($lines | Where-Object { $_ -ne 'Ligne 27' }) -join "`n"
        $text = Read-Text $file
        $count = @($text -split "`n").Count
        New-Result ($text -ceq $want) "$count lignes, Ligne 27 présente : $($text -match '(?m)^Ligne 27$')"
    }
    'cleanup' { Restore-NotepadSession }
}
