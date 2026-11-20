<#
The final campaign of the background mode PRD (US-063), unattended, for a
night Arthur starts it himself before leaving the machine.

  pwsh evals/night.ps1                    # gates, campaign, report
  pwsh evals/night.ps1 -Resume <stamp>    # after a stop: the runs kept are not played again
  pwsh evals/night.ps1 -DryRun            # the same night without claude -p, nothing billed
  pwsh evals/night.ps1 -DryRun -SkipGates # the chaining alone, in a few minutes

Everything goes to evals/results/<stamp>/: night.log (one line per step),
gate-*.txt (each gate's output), gates.json (their verdicts, which
report.ps1 puts at the head of the report) and the campaign's runs.jsonl.

1. A real night refuses a modified worktree: it measures a commit.
2. The desktop gates run first, on a machine nobody uses: selftest,
   selftest --background, the bench against bench/baseline.json and the eval
   dry run. A failed selftest or dry run ends the night before any claude -p
   run. A failed bench does not: its verdict heads the report.
3. The campaign: the background suite in the background and agent-desktop
   modes and the existing tasks in a11y, 3 repetitions, through
   run.ps1 -StopOnDisturbance. A locked session or a physical input ends it
   with exit code 3: night.ps1 -Resume <stamp> plays the rest.
4. Harness failures are played once more, then evals/report.ps1 writes
   evals/reports/<date>.md.

The machine stays awake with its display on (SetThreadExecutionState) for
the whole night, and goes back to its own settings at the end, even on an
error. A lock that Windows forces anyway (inactivity policy, dynamic lock,
an update restart) is detected and ends the night cleanly.
#>
param(
    [switch]$DryRun,
    [string]$Resume,
    [switch]$SkipGates,
    [int]$Reps = 3
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$runScript = Join-Path $PSScriptRoot 'run.ps1'
$suites = 'background, existing'
$modes = 'background, agent-desktop, a11y'

if (-not $DryRun) {
    $dirty = @(& git -C $root status --porcelain)
    if ($LASTEXITCODE) { throw 'git indisponible : impossible de vérifier que l''arbre de travail est propre' }
    if ($dirty) { throw "arbre de travail modifié : commite ou mets de côté avant la nuit, elle mesure un commit`n$($dirty -join "`n")" }
    $claude = "$env:USERPROFILE\.local\bin\claude.exe"
    if (-not (Test-Path $claude)) { throw "claude absent ($claude)" }
    $agentDesktop = Join-Path $PSScriptRoot 'agent-desktop/node_modules/agent-desktop/bin/agent-desktop-win32-x64.exe'
    if (-not (Test-Path $agentDesktop)) { throw 'agent-desktop absent : lance bun install --frozen-lockfile dans evals/agent-desktop' }
}

$stamp = if ($Resume) { $Resume } else { Get-Date -Format 'yyyy-MM-dd_HHmmss' }
$dir = Join-Path $PSScriptRoot "results/$stamp"
if ($Resume -and -not (Test-Path "$dir/runs.jsonl")) { throw "aucune nuit à reprendre dans $dir" }
New-Item -ItemType Directory -Force $dir | Out-Null
$log = Join-Path $dir 'night.log'
$runs = Join-Path $dir 'runs.jsonl'
# run.ps1 writes into the directory it resumes: an empty runs.jsonl lets the
# night choose the stamp, so every step lands in the same place.
if (-not (Test-Path $runs)) { New-Item -ItemType File $runs | Out-Null }

function Write-Night([string]$Line) {
    $text = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Line"
    Add-Content -LiteralPath $log -Value $text -Encoding utf8
    Write-Host "night: $Line"
}

# One child process per step: run.ps1 ends with exit, which would end the
# night in this process.
function Invoke-Step([string]$Name, [string]$Command) {
    $file = Join-Path $dir "$Name.txt"
    $started = Get-Date
    & pwsh -NoProfile -Command $Command 2>&1 | Tee-Object -FilePath $file | Out-Host
    $code = $LASTEXITCODE
    [pscustomobject]@{ code = $code; seconds = [int]((Get-Date) - $started).TotalSeconds; file = $file }
}

Add-Type -Namespace Evals -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
'@
$continuous = [uint32]'0x80000000'
$awake = $continuous -bor 0x1 -bor 0x2

$manifest = Get-Content "$PSScriptRoot/windows/tasks.json" -Raw | ConvertFrom-Json
$bgTasks = @($manifest.tasks | Where-Object { $_.suite -eq 'background' }).Count
$exTasks = @($manifest.tasks | Where-Object { -not $_.suite }).Count
$budget = $bgTasks * 2 * $Reps + $exTasks * $Reps
$kept = @(Get-Content $runs | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.cause -notin 'harness', 'skipped', 'dry_run' }).Count

$exitCode = 0
[void][Evals.Power]::SetThreadExecutionState($awake)
try {
    Write-Night "start $stamp$(if ($DryRun) { ' (dry run, no claude -p)' }) at commit $("$(& git -C $root rev-parse --short HEAD)".Trim())"
    Write-Night "budget: $budget claude -p runs ($bgTasks background tasks x 2 modes x $Reps, $exTasks existing tasks x $Reps in a11y)$(if ($kept) { ", $kept already kept, $($budget - $kept) left" })"

    $gatesFile = Join-Path $dir 'gates.json'
    $gates = if (Test-Path $gatesFile) { Get-Content $gatesFile -Raw | ConvertFrom-Json } else { $null }
    $gatesDone = $gates -and $gates.selftest.ok -and $gates.selftest_background.ok -and $gates.dry_run.ok
    if ($SkipGates) {
        Write-Night 'gates skipped (-SkipGates)'
    } elseif ($gatesDone) {
        Write-Night 'gates already passed for this night: not played again'
    } else {
        $gates = [ordered]@{}
        $steps = @(
            @{ key = 'selftest'; name = 'gate-selftest'; blocking = $true; command = "Set-Location '$root'; & zig @('build', 'run', '--', 'selftest')" }
            @{ key = 'selftest_background'; name = 'gate-selftest-background'; blocking = $true; command = "Set-Location '$root'; & zig @('build', 'run', '--', 'selftest', '--background')" }
            @{ key = 'bench'; name = 'gate-bench'; blocking = $false; command = "Set-Location '$root'; & zig @('build', 'bench', '--', '--check', 'bench/baseline.json')" }
            @{ key = 'dry_run'; name = 'gate-dry-run'; blocking = $true; command = "Set-Location '$root'; & '$runScript' -DryRun" }
        )
        foreach ($s in $steps) {
            Write-Night "gate $($s.key): start"
            $r = Invoke-Step $s.name $s.command
            $ok = $r.code -eq 0
            $entry = [ordered]@{ ok = $ok; exit_code = $r.code; seconds = $r.seconds }
            if ($s.key -eq 'bench') {
                $hit = Select-String -LiteralPath $r.file -Pattern 'bench: (\d+) regression' | Select-Object -Last 1
                $entry.regressions = if ($hit) { [int]$hit.Matches[0].Groups[1].Value } else { 0 }
            }
            $gates[$s.key] = $entry
            $gates | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $gatesFile -Encoding utf8
            Write-Night "gate $($s.key): $(if ($ok) { 'ok' } else { "FAILED (exit $($r.code))" }) in $($r.seconds) s$(if ($s.key -eq 'bench' -and -not $ok) { ", $($entry.regressions) regression(s), noted at the head of the report" })"
            if (-not $ok -and $s.blocking) {
                throw "gate $($s.key) en échec : la nuit s'arrête avant toute exécution claude -p ; voir $($r.file)"
            }
        }
    }

    $dry = if ($DryRun) { ' -DryRun' } else { '' }
    $campaign = "Set-Location '$root'; & '$runScript' -Suite $suites -Modes $modes -Reps $Reps -Resume $stamp -StopOnDisturbance$dry"
    foreach ($pass in 'campaign', 'harness-replay') {
        if ($pass -eq 'harness-replay') {
            # The last record of each run decides: a harness failure that a
            # later pass played again no longer counts.
            $last = @{}
            Get-Content $runs | Where-Object { $_ } | ForEach-Object { $r = $_ | ConvertFrom-Json; $last["$($r.task)-$($r.mode)-r$($r.rep)"] = $r.cause }
            $failed = @($last.Values | Where-Object { $_ -eq 'harness' }).Count
            if (-not $failed) { break }
            Write-Night "harness-replay: $failed run(s) played once more"
        }
        Write-Night "$($pass): start"
        $r = Invoke-Step $pass $campaign
        if ($r.code -eq 3) {
            $why = Select-String -LiteralPath $r.file -Pattern 'eval: stopped: (.*)$' | Select-Object -Last 1
            Write-Night "$($pass): stopped ($(if ($why) { $why.Matches[0].Groups[1].Value } else { 'cause inconnue' })) ; resume with: pwsh evals/night.ps1 -Resume $stamp"
            $exitCode = 3
            break
        }
        # A dry run exits 1 on a harness failure; a real run records it and goes on.
        if ($r.code -ne 0) { throw "$pass : run.ps1 a échoué (exit $($r.code)) ; voir $($r.file)" }
        Write-Night "$($pass): done in $($r.seconds) s"
    }

    if ($exitCode -eq 0) {
        if ($DryRun) {
            Write-Night 'report: skipped (a dry run records no result to report)'
        } else {
            $r = Invoke-Step 'report' "Set-Location '$root'; & '$PSScriptRoot/report.ps1' -Results '$dir'"
            if ($r.code -ne 0) { throw "report.ps1 a échoué (exit $($r.code)) ; voir $($r.file)" }
            Write-Night "report: evals/reports/$($stamp.Substring(0, 10)).md"
        }
        Write-Night 'end: ok'
    }
} catch {
    Write-Night "end: FAILED: $_"
    $exitCode = 1
} finally {
    [void][Evals.Power]::SetThreadExecutionState($continuous)
}
exit $exitCode
