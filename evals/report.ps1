<#
Turns evals/results/<stamp>/runs.jsonl into evals/reports/<date>.md: success,
tool calls, model turns, input tokens and duration per mode, per-task
success, the median post-action delta (US-012), and the verdicts on A2 and
A3. Only aggregated numbers reach the report, never transcript content.

  pwsh evals/report.ps1 [-Results evals/results/<stamp>]   # latest by default
#>
param([string]$Results)
$ErrorActionPreference = 'Stop'
if (-not $Results) {
    $Results = (Get-ChildItem "$PSScriptRoot/results" -Directory | Where-Object { Test-Path "$($_.FullName)/runs.jsonl" } | Sort-Object Name | Select-Object -Last 1).FullName
}
$all = @(Get-Content "$Results/runs.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.cause -ne 'dry_run' })
# A run the harness could not set up or check says nothing about the model:
# counted apart, out of every rate.
# A harness failure rerun by run.ps1 -Resume is not listed either.
$runs = @($all | Where-Object { $_.cause -ne 'harness' })
$kept = @{}; foreach ($r in $runs) { $kept["$($r.task)/$($r.mode)/r$($r.rep)"] = $true }
$harness = @($all | Where-Object { $_.cause -eq 'harness' -and -not $kept["$($_.task)/$($_.mode)/r$($_.rep)"] })
if (-not $runs) { throw "no run in $Results" }
$stamp = Split-Path $Results -Leaf
$date = $stamp.Substring(0, 10)
$manifest = Get-Content "$PSScriptRoot/windows/tasks.json" -Raw | ConvertFrom-Json

function Median([double[]]$xs) {
    $s = @($xs | Where-Object { $null -ne $_ } | Sort-Object)
    if (-not $s) { return $null }
    $n = $s.Count
    if ($n % 2) { $s[($n - 1) / 2] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
}
function Fmt($x) { if ($null -eq $x) { '-' } else { '{0:N0}' -f $x } }

$modes = @('a11y', 'vision', 'windows-mcp') | Where-Object { $m = $_; $runs | Where-Object { $_.mode -eq $m } }
$by = @{}
foreach ($m in $modes) {
    $r = @($runs | Where-Object { $_.mode -eq $m })
    $ok = @($r | Where-Object { $_.success })
    $by[$m] = [pscustomobject]@{
        runs = $r.Count
        success = $ok.Count / $r.Count
        timeouts = @($r | Where-Object { $_.cause -eq 'timeout' }).Count
        calls = Median ($r | ForEach-Object { $_.tool_calls })
        turns = Median ($r | ForEach-Object { $_.turns })
        input = Median ($r | ForEach-Object { $_.input_tokens })
        output = Median ($r | ForEach-Object { $_.output_tokens })
        seconds = Median ($r | ForEach-Object { $_.seconds })
        # Efficiency on successes only, so a quick failure does not look cheap.
        input_ok = Median ($ok | ForEach-Object { $_.input_tokens })
        calls_ok = Median ($ok | ForEach-Object { $_.tool_calls })
    }
}

$tasks = @($runs | Select-Object -ExpandProperty task -Unique)
$reps = ($runs | Measure-Object rep -Maximum).Maximum
$full = $tasks.Count -ge 20 -and $reps -ge 3
$scope = if ($full) { 'campagne complète' } else { "pilote : $($tasks.Count) tâches, $reps répétition(s)" }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Évals Windows du $date")
$lines.Add('')
$lines.Add("Résultats ``evals/results/$stamp`` ($scope), modèle $(@($runs.model | Where-Object { $_ } | Select-Object -Unique) -join ', '), via ``claude -p`` sur l'abonnement Claude Code. Médianes sur toutes les exécutions ; « entrée (succès) » et « appels (succès) » sur les exécutions réussies. Les tokens d'entrée comptent le cache (création et lecture).")
if ($harness) {
    $lines.Add('')
    $lines.Add("Exécutions écartées (échec du harnais, pas du modèle) : $($harness.Count), $(@($harness | ForEach-Object { "$($_.task)/$($_.mode)/r$($_.rep)" }) -join ', ').")
}
$lines.Add('')
$lines.Add('| Mode | Exécutions | Réussite | Timeouts | Appels d''outils | Tours modèle | Tokens d''entrée | Tokens de sortie | Durée (s) | Entrée (succès) | Appels (succès) |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($m in $modes) {
    $b = $by[$m]
    $lines.Add("| $m | $($b.runs) | $('{0:P0}' -f $b.success) | $($b.timeouts) | $(Fmt $b.calls) | $(Fmt $b.turns) | $(Fmt $b.input) | $(Fmt $b.output) | $(Fmt $b.seconds) | $(Fmt $b.input_ok) | $(Fmt $b.calls_ok) |")
}
$costs = @($runs | ForEach-Object { $_.cost_usd_equivalent } | Where-Object { $null -ne $_ })
if ($costs) {
    $lines.Add('')
    $lines.Add("Coût équivalent API, indicatif (l'abonnement ne facture pas à l'appel) : $('{0:N2}' -f ($costs | Measure-Object -Sum).Sum) `$ au total, $('{0:N3}' -f (Median $costs)) `$ médian par exécution, durée totale $(Fmt (($runs | Measure-Object seconds -Sum).Sum)) s.")
}
$lines.Add('')
$lines.Add('## Par tâche')
$lines.Add('')
$lines.Add('| Tâche | Application | ' + ($modes -join ' | ') + ' |')
$lines.Add('|---|---|' + (($modes | ForEach-Object { '---' }) -join '|') + '|')
foreach ($t in $tasks) {
    $app = ($manifest.tasks | Where-Object { $_.id -eq $t }).app
    $cells = foreach ($m in $modes) {
        $r = @($runs | Where-Object { $_.task -eq $t -and $_.mode -eq $m })
        if (-not $r) { '-' } else {
            $causes = @($r | Where-Object { -not $_.success } | ForEach-Object { $_.cause }) -join ', '
            "$(@($r | Where-Object { $_.success }).Count)/$($r.Count)" + $(if ($causes) { " ($causes)" } else { '' })
        }
    }
    $lines.Add("| $t | $app | $($cells -join ' | ') |")
}

$deltas = @($runs | Where-Object { $_.mode -eq 'a11y' } | ForEach-Object { $_.observation_tokens } | Where-Object { $null -ne $_ })
$deltaMedian = Median $deltas
$lines.Add('')
$lines.Add('## Delta post-action (US-012)')
$lines.Add('')
if ($deltas) {
    $lines.Add("Deltas dans la page : médiane $(Fmt $deltaMedian) tokens sur $($deltas.Count) observations ``delta`` du mode a11y (texte après la ligne ``settled in``, ratio de ``bench/token_calibration.json``), pour un seuil de 150 : $(if ($deltaMedian -le 150) { 'tenu' } else { 'dépassé' }).")
} else {
    $lines.Add('Aucun delta dans la page enregistré.')
}
$replaced = @($runs | Where-Object { $_.mode -eq 'a11y' } | ForEach-Object { $_.replaced_tokens } | Where-Object { $null -ne $_ })
if ($replaced) {
    $lines.Add('')
    $lines.Add("Contenu remplacé (arbre complet, ou delta qui ajoute et retire au moins 10 éléments chacun, décision 0005) : $($replaced.Count) observations, médiane $(Fmt (Median $replaced)) tokens, maximum $(Fmt (($replaced | Measure-Object -Maximum).Maximum)). Hors seuil : le serveur renvoie l'arbre complet dès qu'un delta serait plus long.")
}

# A3: the pruned, differential tree reduces tokens and round trips against
# vision alone, without losing success (10-point tolerance). A reduction under
# 10 % is within run-to-run noise and does not validate.
$lines.Add('')
$lines.Add('## Conclusions')
$lines.Add('')
$prefix = if ($full) { '' } else { 'provisoire (pilote), ' }
if ($by['a11y'] -and $by['vision']) {
    $a = $by['a11y']; $v = $by['vision']
    $fewerTokens = $a.input -le 0.9 * $v.input
    $fewerCalls = $a.calls -le $v.calls
    $kept = $a.success -ge $v.success - 0.10
    $verdict = if ($fewerTokens -and $fewerCalls -and $kept) { 'validée' }
    elseif (($a.input -ge $v.input -and $a.calls -ge $v.calls) -or -not $kept) { 'invalidée' }
    else { 'non concluante' }
    $lines.Add("**A3 : $prefix$verdict.** a11y contre vision : tokens d'entrée médians $(Fmt $a.input) contre $(Fmt $v.input), appels d'outils $(Fmt $a.calls) contre $(Fmt $v.calls), réussite $('{0:P0}' -f $a.success) contre $('{0:P0}' -f $v.success). Règle : validée si a11y consomme au moins 10 % de tokens en moins, au plus autant d'appels, et ne perd pas plus de 10 points de réussite ; invalidée sans réduction ni de tokens ni d'appels, ou avec plus de 10 points perdus ; non concluante sinon.")
} else {
    $lines.Add('**A3 : non concluante.** Il faut les modes a11y et vision.')
}
$lines.Add('')
$indirect = if ($by['vision'] -and $by['windows-mcp']) { " Indicateur indirect : réussite du miroir (vision) $('{0:P0}' -f $by['vision'].success) contre Windows-MCP $('{0:P0}' -f $by['windows-mcp'].success)." } else { '' }
$lines.Add("**A2 : non concluante.** Le toolset natif n'est pas exécutable par ``claude -p`` sous Windows sur abonnement (décision 0004), donc aucune comparaison directe miroir contre natif.$indirect")

New-Item -ItemType Directory -Force "$PSScriptRoot/reports" | Out-Null
$path = "$PSScriptRoot/reports/$date.md"
Set-Content $path ($lines -join "`n") -Encoding utf8NoBOM
Write-Host "report: $path"
