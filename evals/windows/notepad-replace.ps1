param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$file = Join-Path $Work 'histoire.txt'
$original = "Le chat dort au soleil.`nLe chat mange.`nUn chat passe devant la fenêtre.`nFin."

switch ($Phase) {
    'setup' {
        Set-Content $file $original
        Start-NotepadFile $file
    }
    'verify' {
        $text = Read-Text $file
        New-Result ($text -ceq ($original -replace 'chat', 'chien')) "contenu : $($text -replace "`n", ' / ')"
    }
    'cleanup' { Restore-NotepadSession }
}
