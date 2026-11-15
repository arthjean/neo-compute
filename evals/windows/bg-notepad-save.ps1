param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$file = Join-Path $Work 'note.txt'
$other = Join-Path $Work 'annexe.txt'
$text = 'Compte rendu du 13 novembre'
$added = ' (relu)'

switch ($Phase) {
    'setup' {
        Set-Content $other 'Annexe : liste des participants.' -NoNewline
        Set-Content $file $text -NoNewline
        Start-NotepadFile $other
        Start-Process notepad.exe "`"$file`""
        Show-Window (Wait-Window 'note.txt*Bloc-notes*')
        Send-Keys '^{END}'
        Send-Keys $added.Replace('(', '{(}').Replace(')', '{)}')
        $w = Wait-Window '`**note.txt*Bloc-notes*' 10
        Hide-UnderDecoy $w
    }
    'solve' {
        $w = Get-DeskWindow '\*?note.txt'
        [void](Invoke-DeskAct (Find-DeskId 'Fichier' 'menuitem "Fichier"' $w) 'expand')
        [void](Invoke-Desk 'ui_act' @{ id = (Find-DeskId 'role:menuitem Fermer' 'menuitem "Fermer l.onglet"' $w); action = 'invoke' })
        [void](Invoke-Desk 'ui_act' @{ id = (Find-DeskId 'role:button Enregistrer' 'button "Enregistrer"' $w); action = 'invoke' })
        [void](Invoke-Desk 'ui_find' @{ query = 'role:button Enregistrer'; window = $w; wait_ms = 3000; gone = $true })
    }
    'verify' {
        $got = Read-Text $file
        $notepad = Find-Window '*Bloc-notes*'
        $open = $notepad -and (@(Get-UiaNames $notepad) -like 'note.txt*')
        New-Result ($got -eq "$text$added" -and -not $open) "note.txt : « $got », onglet $(if ($open) { 'ouvert' } else { 'fermé' })"
    }
    'cleanup' { Restore-NotepadSession }
}
