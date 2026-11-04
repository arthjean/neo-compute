param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$file = Join-Path $Work 'bonjour.txt'

switch ($Phase) {
    'setup' {
        Set-Content $file "Texte à remplacer.`nDeuxième ligne."
        Start-Process cmd.exe '/c', 'code', '--new-window', "`"$file`"" -WindowStyle Hidden
        Show-Window (Wait-Window 'bonjour.txt*Visual Studio Code*' 30)
    }
    'verify' {
        $text = (Get-Content $file -Raw).Trim()
        New-Result ($text -eq 'neo-compute pilote') "contenu : $($text.Substring(0, [Math]::Min(60, $text.Length)))"
    }
    'cleanup' {
        Close-Window 'bonjour.txt*Visual Studio Code*'
    }
}
