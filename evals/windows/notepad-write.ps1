param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$file = Join-Path $Work 'liste.txt'

switch ($Phase) {
    'setup' {
        Set-Content $file '' -NoNewline
        Start-NotepadFile $file
    }
    'verify' {
        $text = Read-Text $file
        New-Result ($text -eq 'Liste de courses : pain, lait, œufs') "contenu : $text"
    }
    'cleanup' { Restore-NotepadSession }
}
