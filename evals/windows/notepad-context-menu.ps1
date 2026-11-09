param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# US-023: the control character is inserted from Notepad's context menu
# (Affichage et Unicode > Insérer un caractère de contrôle Unicode), a popup
# root of the snapshot. RLM is U+200F.
$file = Join-Path $Work 'unicode.txt'
$text = 'Bonjour le monde'

switch ($Phase) {
    'setup' {
        Set-Content $file $text -NoNewline
        Start-NotepadFile $file
    }
    'solve' {
        $w = Find-Window 'unicode.txt*Bloc-notes*'
        Show-Window $w
        # Notepad may run a second process: the menu belongs to the window's.
        $np = [Evals.Desk]::ProcessOf($w.Key)
        Send-Keys '^{END}'
        Send-Keys '+{F10}'
        Expand-Uia (Find-UiaInProcess $np 'Affichage et Unicode')
        Expand-Uia (Find-UiaInProcess $np 'Insérer un caractère de contrôle Unicode*')
        Invoke-Uia (Find-UiaInProcess $np 'RLM')
        # Keys sent while the menu closes are lost: back to the editor, then
        # save until the title drops its unsaved mark.
        Wait-Window '`**unicode.txt*' 5 | Out-Null
        for ($i = 0; $i -lt 5 -and (Find-Window '`**unicode.txt*'); $i++) {
            Show-Window $w
            Send-Keys '^s'
            Start-Sleep -Milliseconds 600
        }
    }
    'verify' {
        $got = Read-Text $file
        $shown = -join ($got.ToCharArray() | ForEach-Object { if ([int]$_ -gt 0x7e) { 'U+{0:X4}' -f [int]$_ } else { $_ } })
        # Ordinal: a culture-aware comparison (-eq) ignores U+200F.
        New-Result ([string]::Equals($got, "$text$([char]0x200F)", [StringComparison]::Ordinal)) "contenu : $shown"
    }
    'cleanup' { Restore-NotepadSession }
}
