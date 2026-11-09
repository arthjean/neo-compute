param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# US-035: a reference shown by Chrome goes to Notepad. It is drawn at random
# for each run, so it cannot be known ahead.
$file = Join-Path $Work 'dossier.txt'
$refFile = Join-Path $Work 'reference.txt'

switch ($Phase) {
    'setup' {
        $alphabet = [char[]]'ABCDEFGHJKLMNPQRTUVWXY34679'
        $ref = 'NC-' + ((1..3 | ForEach-Object { -join (1..4 | ForEach-Object { $alphabet | Get-Random }) }) -join '-')
        Set-Content $refFile $ref -NoNewline
        Save-UserClipboard
        $page = Join-Path $Work 'dossier.html'
        (Get-Content "$PSScriptRoot/pages/dossier.html" -Raw).Replace('__REF__', $ref) | Set-Content $page -NoNewline
        Set-Content $file 'Numéro : ' -NoNewline
        $profileDir = Join-Path $Work 'chrome-profile'
        $url = 'file:///' + ($page -replace '\\', '/')
        Start-Process 'C:\Program Files\Google\Chrome\Application\chrome.exe' "--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check', '--new-window', $url
        Wait-Window 'Dossier neo-compute*' | Out-Null
        Start-NotepadFile $file
    }
    'solve' {
        # The reference as Chrome shows it, through the clipboard to Notepad.
        $shown = Wait-UiaText (Find-Window 'Dossier neo-compute*') '^NC-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$'
        [Evals.Desk]::SetText($shown, @())
        Show-Window (Find-Window 'dossier.txt*Bloc-notes*')
        Send-Keys '^{END}'
        Send-Keys '^v'
        Send-Keys '^s'
        Start-Sleep -Seconds 1
    }
    'verify' {
        $ref = Get-Content $refFile -Raw
        $text = (Read-Text $file) -replace '\s+', ' '
        New-Result ($text.Trim() -eq "Numéro : $ref") "contenu : $text"
    }
    'cleanup' {
        try { Restore-NotepadSession } finally {
            Stop-ChromeProfile $Work
            Restore-UserClipboard
        }
    }
}
