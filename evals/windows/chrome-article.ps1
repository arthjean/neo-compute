param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# US-024: an article read in Chrome. The asked year is drawn for each run,
# away from the decoy years of the page; the model answers in its final
# message (answer.txt).
$yearFile = Join-Path $Work 'year.txt'

switch ($Phase) {
    'setup' {
        $year = Get-Random -Minimum 1951 -Maximum 1990
        Set-Content $yearFile $year -NoNewline
        $page = Join-Path $Work 'article.html'
        (Get-Content "$PSScriptRoot/pages/article.html" -Raw).Replace('__YEAR__', $year) | Set-Content $page -NoNewline
        $profileDir = Join-Path $Work 'chrome-profile'
        $url = 'file:///' + ($page -replace '\\', '/')
        Start-Process 'C:\Program Files\Google\Chrome\Application\chrome.exe' "--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check', '--new-window', $url
        Show-Window (Wait-Window 'Chronique neo-compute*')
    }
    'solve' {
        $line = Wait-UiaText (Find-Window 'Chronique neo-compute*') "n'est qu'en \d{4}"
        Write-Answer $Work ([regex]::Match($line, "n'est qu'en (\d{4})").Groups[1].Value)
    }
    'verify' {
        $year = Get-Content $yearFile -Raw
        $answer = Read-Answer $Work
        if ($null -eq $answer) { return New-Result $false 'aucune réponse' }
        New-Result (($answer -replace '\D', '') -eq $year) "réponse : $answer"
    }
    'cleanup' { Stop-ChromeProfile $Work }
}
