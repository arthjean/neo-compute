param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$file = Join-Path $Work 'journal.txt'
$lines = 1..200 | ForEach-Object { if ($_ -eq 150) { 'ligne 150 : TODO à traiter' } else { "ligne $_" } }

switch ($Phase) {
    'setup' {
        Set-Content $file $lines
        Start-VSCodeFile $file
    }
    'verify' {
        $want = ($lines -replace '^ligne 150 : TODO', 'ligne 150 : FAIT') -join "`n"
        $text = Read-Text $file
        $line = @($text -split "`n")[149]
        New-Result ($text -ceq $want) "ligne 150 : $line"
    }
    'cleanup' { Close-Window 'journal.txt*Visual Studio Code*' }
}
