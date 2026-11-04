param([ValidateSet('setup', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$file = Join-Path $Work 'config.txt'
$original = "foo = 1`nbar = 2`nfoo_max = foo * 3`n# foo reste un exemple`nbaz = foo + bar`nfin"

switch ($Phase) {
    'setup' {
        Set-Content $file $original
        Start-VSCodeFile $file
    }
    'verify' {
        $text = Read-Text $file
        New-Result ($text -ceq ($original -replace 'foo', 'qux')) "occurrences de foo restantes : $(([regex]::Matches($text, 'foo')).Count)"
    }
    'cleanup' { Close-Window 'config.txt*Visual Studio Code*' }
}
