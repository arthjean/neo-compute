param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# US-036: a value planted under HKCU for the run, drawn at random so the
# answer can only come from the registry. The model answers in its final
# message (answer.txt).
$key = 'HKCU:\Software\neo-compute-evals\edition'
$valueFile = Join-Path $Work 'value.txt'

switch ($Phase) {
    'setup' {
        $alphabet = [char[]]'ABCDEFGHJKLMNPQRTUVWXY34679'
        $value = 'Edition-' + -join (1..8 | ForEach-Object { $alphabet | Get-Random })
        Set-Content $valueFile $value -NoNewline
        New-Item -Force $key | Out-Null
        New-ItemProperty -Path $key -Name 'CodeEdition' -Value $value -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name 'Revision' -Value 7 -PropertyType DWord -Force | Out-Null
    }
    'solve' { Write-Answer $Work (Get-ItemPropertyValue $key 'CodeEdition') }
    'verify' {
        $value = Get-Content $valueFile -Raw
        $answer = Read-Answer $Work
        if ($null -eq $answer) { return New-Result $false 'aucune réponse' }
        New-Result ($answer -ceq $value) "réponse : $answer"
    }
    'cleanup' { Remove-Item -Recurse -Force 'HKCU:\Software\neo-compute-evals' -ErrorAction SilentlyContinue }
}
