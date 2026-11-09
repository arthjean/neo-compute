<#
Turns evals/results/<stamp>/runs.jsonl into evals/reports/<date>.md: success,
tool calls, model turns, tokens and duration per mode for each suite (the
20 existing tasks of US-016, the parity tasks of US-037), per-task success,
the canary leaks, the median post-action delta (US-012), a verdict on each
Success Metric of tasks/prd-windows-mcp-parity.md, and the verdicts on A2
and A3. A regression of more than 5 points on the existing tasks in a11y
mode (evals/baseline.json) and any canary leak head the report (US-038).
Only aggregated numbers reach the report, never transcript content.

  pwsh evals/report.ps1 [-Results evals/results/<stamp>] [-Out <file.md>]   # latest by default
#>
param([string]$Results, [string]$Out)
$ErrorActionPreference = 'Stop'
if (-not $Results) {
    $Results = (Get-ChildItem "$PSScriptRoot/results" -Directory | Where-Object { Test-Path "$($_.FullName)/runs.jsonl" } | Sort-Object Name | Select-Object -Last 1).FullName
}
$manifest = Get-Content "$PSScriptRoot/windows/tasks.json" -Raw | ConvertFrom-Json
$baseline = Get-Content "$PSScriptRoot/baseline.json" -Raw | ConvertFrom-Json
$byId = @{}
foreach ($t in $manifest.tasks) { $byId[$t.id] = $t }
# Records before US-037 carry no suite: they are the existing tasks.
function SuiteOf($r) { if ($r.suite) { $r.suite } elseif ($byId[$r.task].suite) { $byId[$r.task].suite } else { 'existing' } }
function IsCanary($r) { [bool]$byId[$r.task].canary }

$all = @(Get-Content "$Results/runs.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.cause -ne 'dry_run' })
# A run the harness could not set up or check, or a task whose application
# is absent, says nothing about the model: counted apart, out of every rate.
# A harness failure rerun by run.ps1 -Resume is not listed either.
$runs = @($all | Where-Object { $_.cause -notin 'harness', 'skipped' })
$kept = @{}; foreach ($r in $runs) { $kept["$($r.task)/$($r.mode)/r$($r.rep)"] = $true }
$harness = @($all | Where-Object { $_.cause -eq 'harness' -and -not $kept["$($_.task)/$($_.mode)/r$($_.rep)"] })
$skipped = @($all | Where-Object { $_.cause -eq 'skipped' -and -not $kept["$($_.task)/$($_.mode)/r$($_.rep)"] })
if (-not $runs) { throw "no run in $Results" }
$stamp = Split-Path $Results -Leaf
$date = $stamp.Substring(0, 10)

function Median([double[]]$xs) {
    $s = @($xs | Where-Object { $null -ne $_ } | Sort-Object)
    if (-not $s) { return $null }
    $n = $s.Count
    if ($n % 2) { $s[($n - 1) / 2] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
}
function Fmt($x) { if ($null -eq $x) { '-' } else { '{0:N0}' -f $x } }
function Pct($x) { if ($null -eq $x) { '-' } else { '{0:P0}' -f $x } }

$modes = @('a11y', 'vision', 'windows-mcp') | Where-Object { $m = $_; $runs | Where-Object { $_.mode -eq $m } }
function Summarize($Set) {
    $by = @{}
    foreach ($m in $modes) {
        $r = @($Set | Where-Object { $_.mode -eq $m })
        if (-not $r) { continue }
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
    $by
}

# The canaries measure leaks, not success: out of the suites' rates, so a
# mode that leaks is not also scored on them.
$existing = @($runs | Where-Object { (SuiteOf $_) -eq 'existing' -and -not (IsCanary $_) })
$parity = @($runs | Where-Object { (SuiteOf $_) -eq 'parity' -and -not (IsCanary $_) })
$canary = @($runs | Where-Object { IsCanary $_ })
$ex = Summarize $existing
$pa = Summarize $parity
$reps = ($runs | Measure-Object rep -Maximum).Maximum
$exTasks = @($existing | Select-Object -ExpandProperty task -Unique).Count
$paTasks = @($parity | Select-Object -ExpandProperty task -Unique).Count
$exFull = $exTasks -ge 20 -and $reps -ge 3
$paFull = $paTasks -ge 8 -and $reps -ge 3
$scope = @(
    "tâches existantes : $exTasks$(if (-not $exFull -and $exTasks) { ' (pilote)' })"
    "tâches de parité : $paTasks$(if (-not $paFull -and $paTasks) { ' (pilote)' })"
    "canaris : $(@($canary | Select-Object -ExpandProperty task -Unique).Count)"
    "$reps répétition(s)"
) -join ', '

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Évals Windows du $date")
$lines.Add('')

# US-038: a regression on the existing tasks and any canary leak come first.
$alerts = [System.Collections.Generic.List[string]]::new()
if ($ex['a11y']) {
    $drop = $baseline.existing_a11y_success - $ex['a11y'].success
    if ($drop -gt 0.05) {
        $failed = @($existing | Where-Object { $_.mode -eq 'a11y' -and -not $_.success } | ForEach-Object { "$($_.task)/r$($_.rep) ($($_.cause))" })
        $alerts.Add("> **Régression sur les tâches existantes, mode a11y :** réussite $(Pct $ex['a11y'].success) contre $(Pct $baseline.existing_a11y_success) le $($baseline.date) ($('{0:N0}' -f (100 * $drop)) points perdus, seuil 5). Échecs : $($failed -join ', '). Ouvrir une story de correction dans ``tasks/prd-windows-mcp-parity.md`` avant de conclure sur la parité.")
    }
}
$ownLeaks = @($canary | Where-Object { $_.mode -ne 'windows-mcp' -and $_.cause -eq 'leak' })
if ($ownLeaks) {
    $alerts.Add("> **Fuite de secret dans neo-compute :** $(@($ownLeaks | ForEach-Object { "$($_.task)/$($_.mode)/r$($_.rep) ($($_.leak))" }) -join ', ').")
}
foreach ($a in $alerts) { $lines.Add($a); $lines.Add('') }

$tick = '`'
$commits = @($all | ForEach-Object { $_.tasks_commit } | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { $tick + $_.Substring(0, 7) + $tick })
$commitText = if ($commits) { ', tâches du commit ' + ($commits -join ', ') } else { '' }
$lines.Add("Résultats ``evals/results/$stamp`` ($scope), modèle $(@($runs.model | Where-Object { $_ } | Select-Object -Unique) -join ', '), via ``claude -p`` sur l'abonnement Claude Code$commitText. Médianes sur toutes les exécutions ; « entrée (succès) » et « appels (succès) » sur les exécutions réussies. Les tokens d'entrée comptent le cache (création et lecture).")
if ($harness) {
    $lines.Add('')
    $lines.Add("Exécutions écartées (échec du harnais, pas du modèle) : $($harness.Count), $(@($harness | ForEach-Object { "$($_.task)/$($_.mode)/r$($_.rep)" }) -join ', ').")
}
if ($skipped) {
    $lines.Add('')
    $lines.Add("Exécutions ignorées (application absente, hors de tout taux) : $($skipped.Count), $(@($skipped | ForEach-Object { "$($_.task)/$($_.mode)/r$($_.rep)" }) -join ', ') : $(@($skipped | ForEach-Object { $_.detail } | Select-Object -Unique) -join ' ; ').")
}

function Add-ModeTable($Title, $By) {
    $lines.Add('')
    $lines.Add("## $Title")
    $lines.Add('')
    if (-not $By.Count) { $lines.Add('Aucune exécution.'); return }
    $lines.Add('| Mode | Exécutions | Réussite | Timeouts | Appels d''outils | Tours modèle | Tokens d''entrée | Tokens de sortie | Durée (s) | Entrée (succès) | Appels (succès) |')
    $lines.Add('|---|---|---|---|---|---|---|---|---|---|---|')
    foreach ($m in $modes) {
        $b = $By[$m]
        if (-not $b) { continue }
        $lines.Add("| $m | $($b.runs) | $(Pct $b.success) | $($b.timeouts) | $(Fmt $b.calls) | $(Fmt $b.turns) | $(Fmt $b.input) | $(Fmt $b.output) | $(Fmt $b.seconds) | $(Fmt $b.input_ok) | $(Fmt $b.calls_ok) |")
    }
}
Add-ModeTable 'Tâches existantes (US-016, hors canari)' $ex
Add-ModeTable 'Tâches de parité (US-037, hors canari)' $pa

$costs = @($runs | ForEach-Object { $_.cost_usd_equivalent } | Where-Object { $null -ne $_ })
if ($costs) {
    $lines.Add('')
    $lines.Add("Coût équivalent API, indicatif (l'abonnement ne facture pas à l'appel) : $('{0:N2}' -f ($costs | Measure-Object -Sum).Sum) `$ au total, $('{0:N3}' -f (Median $costs)) `$ médian par exécution, durée totale $(Fmt (($runs | Measure-Object seconds -Sum).Sum)) s.")
}

$lines.Add('')
$lines.Add('## Canaris')
$lines.Add('')
if ($canary) {
    $lines.Add('| Tâche | ' + ($modes -join ' | ') + ' |')
    $lines.Add('|---|' + (($modes | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($t in @($canary | Select-Object -ExpandProperty task -Unique)) {
        $cells = foreach ($m in $modes) {
            $r = @($canary | Where-Object { $_.task -eq $t -and $_.mode -eq $m })
            if (-not $r) { '-' } else { "$(@($r | Where-Object { $_.cause -eq 'leak' }).Count) fuite(s) sur $($r.Count)" }
        }
        $lines.Add("| $t | $($cells -join ' | ') |")
    }
    $lines.Add('')
    $lines.Add('Une fuite : la valeur cachée dans le transcript, la valeur saisie dans un résultat d''outil, l''une ou l''autre dans le journal d''audit, ou des pixels de champ non masqués (`Test-Leak` de `evals/run.ps1`). Windows-MCP n''a pas d''audit vérifié et sert de référence.')
} else {
    $lines.Add('Aucune exécution canari.')
}

$lines.Add('')
$lines.Add('## Par tâche')
$lines.Add('')
$lines.Add('| Tâche | Suite | Application | ' + ($modes -join ' | ') + ' |')
$lines.Add('|---|---|---|' + (($modes | ForEach-Object { '---' }) -join '|') + '|')
$present = @($runs | Select-Object -ExpandProperty task -Unique)
$ordered = @($manifest.tasks | ForEach-Object { $_.id } | Where-Object { $present -contains $_ }) + @($present | Where-Object { -not $byId[$_] })
foreach ($t in $ordered) {
    $r0 = $runs | Where-Object { $_.task -eq $t } | Select-Object -First 1
    $suite = "$(SuiteOf $r0)$(if (IsCanary $r0) { ', canari' })"
    $cells = foreach ($m in $modes) {
        $r = @($runs | Where-Object { $_.task -eq $t -and $_.mode -eq $m })
        if (-not $r) { '-' } else {
            $causes = @($r | Where-Object { -not $_.success } | ForEach-Object { $_.cause }) -join ', '
            "$(@($r | Where-Object { $_.success }).Count)/$($r.Count)" + $(if ($causes) { " ($causes)" } else { '' })
        }
    }
    $lines.Add("| $t | $suite | $($r0.app) | $($cells -join ' | ') |")
}

$deltas = @($runs | Where-Object { $_.mode -eq 'a11y' } | ForEach-Object { $_.observation_tokens } | Where-Object { $null -ne $_ })
$deltaMedian = Median $deltas
$lines.Add('')
$lines.Add('## Delta post-action (US-012)')
$lines.Add('')
if ($deltas) {
    $lines.Add("Deltas dans la page : médiane $(Fmt $deltaMedian) tokens sur $($deltas.Count) observations ``delta`` du mode a11y, toutes suites (texte après la ligne ``settled in``, ratio de ``bench/token_calibration.json``), pour un seuil de 150 : $(if ($deltaMedian -le 150) { 'tenu' } else { 'dépassé' }).")
} else {
    $lines.Add('Aucun delta dans la page enregistré.')
}
$replaced = @($runs | Where-Object { $_.mode -eq 'a11y' } | ForEach-Object { $_.replaced_tokens } | Where-Object { $null -ne $_ })
if ($replaced) {
    $lines.Add('')
    $lines.Add("Contenu remplacé (arbre complet, ou delta qui ajoute et retire au moins 10 éléments chacun, décision 0005) : $($replaced.Count) observations, médiane $(Fmt (Median $replaced)) tokens, maximum $(Fmt (($replaced | Measure-Object -Maximum).Maximum)). Hors seuil : le serveur renvoie l'arbre complet dès qu'un delta serait plus long.")
}

# One verdict per row of the PRD's Success Metrics. The rows the campaign
# does not measure name the gate that does.
function Held([bool]$Ok) { if ($Ok) { 'tenue' } else { 'non tenue' } }
$prov = { param($full) if ($full) { '' } else { 'provisoire (pilote), ' } }
$metrics = [System.Collections.Generic.List[string[]]]::new()
$metrics.Add(@('Outils de Windows-MCP couverts', '17 sur 21', 'hors campagne', 'mesurée par l''inventaire de la décision 0008, revu à la clôture'))
if ($pa['a11y']) {
    $s = $pa['a11y'].success
    $metrics.Add(@('Réussite sur les tâches de parité, a11y', '≥ 90 %, puis ≥ 95 %', (Pct $s), "$(& $prov $paFull)$(Held ($s -ge 0.90)) au mois 1 ; $(if ($s -ge 0.95) { 'cible du mois 6 déjà atteinte' } else { 'cible du mois 6 (95 %) non atteinte' })"))
} else { $metrics.Add(@('Réussite sur les tâches de parité, a11y', '≥ 90 %, puis ≥ 95 %', '-', 'non concluante : aucune exécution a11y de parité')) }
if ($pa['a11y'] -and $pa['windows-mcp']) {
    $a = $pa['a11y'].success; $w = $pa['windows-mcp'].success
    $metrics.Add(@('Réussite de parité contre windows-mcp', '≥ windows-mcp, puis + 10 points', "$(Pct $a) contre $(Pct $w)", "$(& $prov $paFull)$(Held ($a -ge $w)) au mois 1 ; $(if ($a -ge $w + 0.10) { 'écart de 10 points du mois 6 déjà atteint' } else { 'écart de 10 points du mois 6 non atteint' })"))
    $metrics.Add(@('Appels d''outils médians par tâche de parité, a11y', '≤ windows-mcp', "$(Fmt $pa['a11y'].calls) contre $(Fmt $pa['windows-mcp'].calls)", "$(& $prov $paFull)$(Held ($pa['a11y'].calls -le $pa['windows-mcp'].calls))"))
} else {
    $metrics.Add(@('Réussite de parité contre windows-mcp', '≥ windows-mcp, puis + 10 points', '-', 'non concluante : il faut les modes a11y et windows-mcp'))
    $metrics.Add(@('Appels d''outils médians par tâche de parité, a11y', '≤ windows-mcp', '-', 'non concluante : il faut les modes a11y et windows-mcp'))
}
if ($ex['a11y']) {
    $metrics.Add(@('Réussite sur les 20 tâches existantes, a11y', '≥ 95 %', (Pct $ex['a11y'].success), "$(& $prov $exFull)$(Held ($ex['a11y'].success -ge 0.95)) (référence $(Pct $baseline.existing_a11y_success) le $($baseline.date))"))
} else { $metrics.Add(@('Réussite sur les 20 tâches existantes, a11y', '≥ 95 %', '-', 'non concluante : aucune exécution a11y des tâches existantes')) }
$metrics.Add(@('Snapshot UIA p95, Bloc-notes', '≤ 110 % de la baseline et < 50 ms', 'hors campagne', 'mesurée par `zig build bench -- --check bench/baseline.json`'))
$metrics.Add(@('Tokens des définitions `alwaysLoad`', '≤ 1 500', 'hors campagne', 'mesurée par le test du registre (US-020), `zig build test`'))
$metrics.Add(@('Tokens de toutes les définitions', '≤ 4 500', 'hors campagne', 'mesurée par le test du registre (US-020), `zig build test`'))
$own = @($canary | Where-Object { $_.mode -ne 'windows-mcp' })
$ref = @($canary | Where-Object { $_.mode -eq 'windows-mcp' })
if ($own) {
    $refText = if ($ref) { " ; référence windows-mcp : $(@($ref | Where-Object { $_.cause -eq 'leak' }).Count) fuite(s) sur $($ref.Count)" } else { '' }
    $metrics.Add(@('Fuites de secret sur les tâches canari', '0, presse-papiers compris', "$($ownLeaks.Count) sur $($own.Count) exécutions a11y et vision", "$(Held (-not $ownLeaks))$refText"))
} else { $metrics.Add(@('Fuites de secret sur les tâches canari', '0, presse-papiers compris', '-', 'non concluante : aucune exécution canari de neo-compute')) }
$metrics.Add(@('Médiane de tokens par delta', '≤ 150', (Fmt $deltaMedian), $(if ($deltas) { Held ($deltaMedian -le 150) } else { 'non concluante : aucun delta' })))

$lines.Add('')
$lines.Add('## Success Metrics')
$lines.Add('')
$lines.Add('Lignes de `tasks/prd-windows-mcp-parity.md`, taux hors canaris.')
$lines.Add('')
$lines.Add('| Métrique | Cible | Mesure | Conclusion |')
$lines.Add('|---|---|---|---|')
foreach ($m in $metrics) { $lines.Add("| $($m -join ' | ') |") }

# A3: the pruned, differential tree reduces tokens and round trips against
# vision alone, without losing success (10-point tolerance), on the tasks it
# was stated for (US-016). A reduction under 10 % is within run-to-run noise
# and does not validate.
$lines.Add('')
$lines.Add('## Conclusions')
$lines.Add('')
if ($ex['a11y'] -and $ex['vision']) {
    $a = $ex['a11y']; $v = $ex['vision']
    $fewerTokens = $a.input -le 0.9 * $v.input
    $fewerCalls = $a.calls -le $v.calls
    $keptSuccess = $a.success -ge $v.success - 0.10
    $verdict = if ($fewerTokens -and $fewerCalls -and $keptSuccess) { 'validée' }
    elseif (($a.input -ge $v.input -and $a.calls -ge $v.calls) -or -not $keptSuccess) { 'invalidée' }
    else { 'non concluante' }
    $lines.Add("**A3 : $(& $prov $exFull)$verdict.** a11y contre vision sur les tâches existantes : tokens d'entrée médians $(Fmt $a.input) contre $(Fmt $v.input), appels d'outils $(Fmt $a.calls) contre $(Fmt $v.calls), réussite $(Pct $a.success) contre $(Pct $v.success). Règle : validée si a11y consomme au moins 10 % de tokens en moins, au plus autant d'appels, et ne perd pas plus de 10 points de réussite ; invalidée sans réduction ni de tokens ni d'appels, ou avec plus de 10 points perdus ; non concluante sinon.")
} else {
    $lines.Add('**A3 : non concluante.** Il faut les modes a11y et vision sur les tâches existantes.')
}
$lines.Add('')
$indirect = if ($ex['vision'] -and $ex['windows-mcp']) { " Indicateur indirect : réussite du miroir (vision) $(Pct $ex['vision'].success) contre Windows-MCP $(Pct $ex['windows-mcp'].success) sur les tâches existantes." } else { '' }
$lines.Add("**A2 : non concluante.** Le toolset natif n'est pas exécutable par ``claude -p`` sous Windows sur abonnement (décision 0004), donc aucune comparaison directe miroir contre natif.$indirect")

if (-not $Out) {
    New-Item -ItemType Directory -Force "$PSScriptRoot/reports" | Out-Null
    $Out = "$PSScriptRoot/reports/$date.md"
}
Set-Content $Out ($lines -join "`n") -Encoding utf8NoBOM
Write-Host "report: $Out"
