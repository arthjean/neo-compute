param([ValidateSet('setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# US-030 and US-023: the export dialog opens 8 s after the click, longer
# than the settle after an action, as a modal window owned by the export
# window. helpers/export.ps1 writes the choice to export-result.txt.
$result = Join-Path $Work 'export-result.txt'
$pidFile = Join-Path $Work 'export.pid'

switch ($Phase) {
    'setup' {
        # The console of run.ps1, not a hidden one: SW_HIDE in the startup
        # info would also apply to the form's first ShowWindow.
        $p = Start-Process pwsh -PassThru -NoNewWindow -ArgumentList '-NoProfile', '-STA', '-File', "`"$PSScriptRoot/helpers/export.ps1`"", '-Result', "`"$result`"", '-DelaySeconds', 8
        Set-Content $pidFile $p.Id
        Show-Window (Wait-Window 'Export neo-compute*')
    }
    'solve' {
        [int]$helper = Get-Content $pidFile
        Invoke-Uia (Find-UiaInProcess $helper "Lancer l'export")
        $t0 = Get-Date
        Wait-Window 'Export terminé' 20 | Out-Null
        $waited = ((Get-Date) - $t0).TotalSeconds
        if ($waited -lt 6) { throw "dialogue ouvert après $([Math]::Round($waited, 1)) s au lieu de 8" }
        Invoke-Uia (Find-UiaInProcess $helper 'Conserver')
        Start-Sleep -Seconds 1
    }
    'verify' {
        if (-not (Test-Path $result)) { return New-Result $false 'aucun choix dans le dialogue' }
        $choice = Get-Content $result -Raw
        New-Result ($choice -eq 'Conserver') "choix : $choice"
    }
    'cleanup' {
        if (Test-Path $pidFile) { Stop-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue }
    }
}
