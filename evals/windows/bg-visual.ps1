param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
$codeFile = Join-Path $Work 'code.txt'

switch ($Phase) {
    'setup' {
        $code = '{0}' -f (Get-Random -Minimum 1000 -Maximum 10000)
        Set-Content $codeFile $code -NoNewline
        Start-Panel $Work $code
    }
    'solve' {
        $w = Get-DeskWindow 'Réglages neo-compute'
        $desk = $global:NeoEvalsDesk
        $desk.calls++
        $shot = Send-Desk $desk 'tools/call' @{ name = 'screenshot'; arguments = @{ window = $w } }
        $image = @($shot.content | Where-Object { $_.type -eq 'image' })[0]
        if ($shot.isError -or -not $image) { throw "desk : capture de la fenêtre recouverte refusée : $(@($shot.content | ForEach-Object { $_.text }) -join ' ')" }
        $ink = [Evals.Ink]::Dark([Convert]::FromBase64String($image.data), 0.64)
        if ($ink -lt 400) { throw "capture sans le code : $ink pixels sombres dans sa zone" }
        Write-Answer $Work (Get-Content $codeFile -Raw)
    }
    'verify' {
        $answer = Read-Answer $Work
        if ($null -eq $answer) { return New-Result $false 'aucune réponse' }
        New-Result (($answer -replace '\D', '') -eq (Get-Content $codeFile -Raw)) "réponse : $answer"
    }
    'cleanup' { Stop-Panel $Work }
}
