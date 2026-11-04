param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$file = Join-Path $Work 'compte-rendu.txt'
$original = "Compte rendu de réunion`nPrésents : équipe produit`nDécision : livrer vendredi"

switch ($Phase) {
    'setup' {
        Set-Content $file $original
        Start-NotepadFile $file
    }
    'verify' {
        $text = Read-Text $file
        New-Result ($text -ceq "$original`nFin du document.") "dernière ligne : $(@($text -split "`n")[-1])"
    }
    'cleanup' { Restore-NotepadSession }
}
