<#
Runs the Windows eval tasks (US-016) through `claude -p` on the Claude Code
subscription: no API key, no direct API call. Each run scripts the initial
state, gives the task to a fresh `claude -p` session whose only tools are the
MCP server `desk`, checks the final state with the task script, and appends
one JSON line to evals/results/<stamp>/runs.jsonl. Raw transcripts stay next
to it: they hold screenshots of the desktop, so evals/results/ is not
committed; evals/report.ps1 turns runs.jsonl into the committed report.

Modes:
  a11y         neo-compute, default mode (all tools, observe: delta)
  vision       neo-compute --mode vision (toolset tools only, observe: screenshot)
  windows-mcp  Windows-MCP pinned in evals/windows-mcp.lock.txt, without its
               PowerShell, Registry, FileSystem, Process and Scrape tools and
               without telemetry (decision 0004)

  pwsh evals/run.ps1 -Pilot -Modes a11y,vision -Reps 1
  pwsh evals/run.ps1 -Modes a11y,vision,windows-mcp -Reps 3
  pwsh evals/run.ps1 -DryRun     # setup, verify and cleanup only, no claude
  pwsh evals/run.ps1 -Modes a11y,vision,windows-mcp -Reps 3 -Resume 2026-11-03_183145
                                 # appends to that campaign the runs it lacks

The runs take control of the mouse and keyboard: leave the desktop alone
while they play.
#>
param(
    [ValidateSet('a11y', 'vision', 'windows-mcp')][string[]]$Modes = @('a11y', 'vision', 'windows-mcp'),
    [int]$Reps = 3,
    [string[]]$Tasks,
    [switch]$Pilot,
    [double]$TimeoutMin = 10,
    # Pinned for reproducibility (decision 0005).
    [string]$Model = 'claude-opus-5-5',
    [string]$Claude = "$env:USERPROFILE\.local\bin\claude.exe",
    [switch]$DryRun,
    # Stamp of an interrupted campaign under evals/results: its recorded runs
    # are skipped, harness failures excepted, and the new ones appended.
    [string]$Resume
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content "$PSScriptRoot/windows/tasks.json" -Raw | ConvertFrom-Json
$selected = @($manifest.tasks | Where-Object { (-not $Tasks -or $Tasks -contains $_.id) -and (-not $Pilot -or $_.pilot) })
if (-not $selected) { throw 'no task selected' }
$ratio = (Get-Content "$root/bench/token_calibration.json" -Raw | ConvertFrom-Json).text_bytes_per_token
# Work directories always get a fresh stamp, so a resumed run never finds the
# half-built state of the interrupted one.
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$out = Join-Path $PSScriptRoot "results/$(if ($Resume) { $Resume } else { $stamp })"
$done = @{}
if ($Resume) {
    if (-not (Test-Path "$out/runs.jsonl")) { throw "no campaign to resume in $out" }
    Get-Content "$out/runs.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.cause -ne 'harness' } |
        ForEach-Object { $done["$($_.task)-$($_.mode)-r$($_.rep)"] = $true }
}
New-Item -ItemType Directory -Force $out | Out-Null

$server = Join-Path $PSScriptRoot '.build/bin/neo-compute.exe'
$wmcp = Join-Path $PSScriptRoot '.venv-windows-mcp/Scripts/windows-mcp.exe'
if (-not $DryRun -and ($Modes -contains 'a11y' -or $Modes -contains 'vision')) {
    # The server under test is the ReleaseFast build, apart from zig-out.
    Push-Location $root
    try { & zig build -Doptimize=ReleaseFast -p (Join-Path $PSScriptRoot '.build') } finally { Pop-Location }
    if ($LASTEXITCODE) { throw 'zig build -Doptimize=ReleaseFast failed' }
}
if (-not $DryRun -and $Modes -contains 'windows-mcp' -and -not (Test-Path $wmcp)) {
    throw "Windows-MCP absent: python -m venv evals/.venv-windows-mcp; evals/.venv-windows-mcp/Scripts/python -m pip install -r evals/windows-mcp.lock.txt"
}

Add-Type -Namespace Evals -Name Input -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct LastInput { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LastInput l);
'@

# A run starts on a desktop nobody touched for 10 s: a person at the keyboard
# would race the model, and Windows-MCP hands control back to any physical
# input for the same 10 s.
function Wait-IdleDesktop([int]$Seconds = 10) {
    $said = $false
    while ($true) {
        $l = New-Object Evals.Input+LastInput
        $l.cbSize = 8
        [void][Evals.Input]::GetLastInputInfo([ref]$l)
        $idle = ([uint32][Environment]::TickCount - $l.dwTime) / 1000
        if ($idle -ge $Seconds) { return }
        if (-not $said) { Write-Host "eval: waiting for $Seconds s without keyboard or mouse input"; $said = $true }
        Start-Sleep -Milliseconds 500
    }
}

function Write-McpConfig([string]$Mode, [string]$Path) {
    $desk = switch ($Mode) {
        'a11y' { @{ command = $server; args = @() } }
        'vision' { @{ command = $server; args = @('--mode', 'vision') } }
        'windows-mcp' {
            @{
                command = $wmcp
                args = @('serve', '--transport', 'stdio', '--exclude-tools', 'PowerShell,Registry,FileSystem,Process,Scrape')
                env = @{ ANONYMIZED_TELEMETRY = 'false' }
            }
        }
    }
    @{ mcpServers = @{ desk = $desk } } | ConvertTo-Json -Depth 5 | Set-Content $Path
}

function Invoke-Claude([string]$Prompt, [string]$Config, [string]$Cwd, [string]$Transcript) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Claude)
    $argv = @('-p', $Prompt, '--output-format', 'stream-json', '--verbose',
        '--mcp-config', $Config, '--strict-mcp-config', '--tools', '', '--allowedTools', 'mcp__desk',
        '--no-session-persistence', '--setting-sources', 'project')
    if ($Model) { $argv += @('--model', $Model) }
    foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
    # A session started from inside Claude Code must not look nested.
    foreach ($v in 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT') { [void]$psi.Environment.Remove($v) }
    $psi.WorkingDirectory = $Cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $fs = [System.IO.File]::Create($Transcript)
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($fs)
    $err = $p.StandardError.ReadToEndAsync()
    $done = $p.WaitForExit([int]($TimeoutMin * 60000))
    if (-not $done) {
        & taskkill.exe /T /F /PID $p.Id | Out-Null
        $p.WaitForExit()
    }
    $copy.Wait()
    $fs.Close()
    [pscustomobject]@{
        timed_out = -not $done
        exit_code = if ($done) { $p.ExitCode } else { $null }
        seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        stderr = $err.Result
    }
}

# Post-action observations of neo-compute: "<result> ; settled in N ms\n<tree>".
$observation = [regex]'^[^\n]* ; (settled in \d+ ms|settle timeout|settle indisponible[^\n]*)\n'
$deltaHeader = [regex]' delta (\+(\d+) -(\d+) ~\d+|: aucun changement)'

# An observation replaces the content when it is a full tree (first read of a
# window, foreground change, delta longer than the tree) or a delta that adds
# and removes at least 10 elements each (a page change). Otherwise it is an
# in-page delta, the one US-012 budgets at 150 tokens.
function Get-ObservationKind([string]$Body) {
    $h = $deltaHeader.Match($Body)
    if (-not $h.Success) { return 'replaced' }
    if ($h.Groups[2].Success -and [int]$h.Groups[2].Value -ge 10 -and [int]$h.Groups[3].Value -ge 10) { return 'replaced' }
    'in_page'
}

function Read-Transcript([string]$Path) {
    $calls = 0
    $images = 0
    $obs = [System.Collections.Generic.List[double]]::new()
    $replaced = [System.Collections.Generic.List[double]]::new()
    $result = $null
    $model = $null
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (-not $line.StartsWith('{')) { continue }
        $m = $line | ConvertFrom-Json -Depth 64
        switch ($m.type) {
            'system' { if ($m.subtype -eq 'init') { $model = $m.model } }
            'assistant' { $calls += @($m.message.content | Where-Object { $_.type -eq 'tool_use' }).Count }
            'user' {
                foreach ($c in @($m.message.content | Where-Object { $_.type -eq 'tool_result' })) {
                    $blocks = if ($c.content -is [string]) { @([pscustomobject]@{ type = 'text'; text = $c.content }) } else { @($c.content) }
                    # A screenshot observation carries an image: only text
                    # deltas count as observation tokens (US-012).
                    $shot = @($blocks | Where-Object { $_.type -eq 'image' }).Count -gt 0
                    foreach ($b in $blocks) {
                        if ($b.type -eq 'image') { $images++ }
                        elseif ($b.type -eq 'text' -and -not $shot) {
                            $hit = $observation.Match($b.text)
                            if ($hit.Success) {
                                $body = $b.text.Substring($hit.Length)
                                $tokens = [System.Text.Encoding]::UTF8.GetByteCount($body) / $ratio
                                if ((Get-ObservationKind $body) -eq 'in_page') { $obs.Add($tokens) } else { $replaced.Add($tokens) }
                            }
                        }
                    }
                }
            }
            'result' { $result = $m }
        }
    }
    $u = if ($result) { $result.usage } else { $null }
    [pscustomobject]@{
        model = $model
        tool_calls = $calls
        turns = if ($result) { $result.num_turns } else { $null }
        input_tokens = if ($u) { [long]$u.input_tokens + [long]$u.cache_creation_input_tokens + [long]$u.cache_read_input_tokens } else { $null }
        output_tokens = if ($u) { [long]$u.output_tokens } else { $null }
        images = $images
        observation_tokens = @($obs | ForEach-Object { [Math]::Round($_) })
        replaced_tokens = @($replaced | ForEach-Object { [Math]::Round($_) })
        is_error = if ($result) { [bool]$result.is_error } else { $true }
        cost_usd_equivalent = if ($result) { $result.total_cost_usd } else { $null }
    }
}

$runs = Join-Path $out 'runs.jsonl'
foreach ($task in $selected) {
    $script = Join-Path $PSScriptRoot "windows/$($task.id).ps1"
    foreach ($mode in $Modes) {
        foreach ($rep in 1..$Reps) {
            $name = "$($task.id)-$mode-r$rep"
            if ($done[$name]) { continue }
            $work = Join-Path $PSScriptRoot "work/$stamp/$name"
            $cwd = Join-Path $work 'session'
            New-Item -ItemType Directory -Force $cwd | Out-Null
            if (-not $DryRun) { Wait-IdleDesktop }
            Write-Host "eval: $name"
            $record = [ordered]@{ task = $task.id; app = $task.app; mode = $mode; rep = $rep; success = $false; cause = $null }
            try {
                & $script -Phase setup -Work $work
                $before = & $script -Phase verify -Work $work
                if ($before.ok) { throw "état final déjà atteint avant la tâche ($($before.detail))" }
                if ($DryRun) {
                    $record.cause = 'dry_run'
                } else {
                    $config = Join-Path $work 'mcp.json'
                    Write-McpConfig $mode $config
                    $transcript = Join-Path $out "$name.jsonl"
                    $run = Invoke-Claude "$($manifest.instructions)`n`n$($task.prompt)" $config $cwd $transcript
                    $stats = Read-Transcript $transcript
                    $after = & $script -Phase verify -Work $work
                    $record.success = [bool]$after.ok -and -not $run.timed_out
                    $record.cause = if ($run.timed_out) { 'timeout' } elseif ($after.ok) { $null } elseif ($stats.is_error) { 'error' } else { 'verify_failed' }
                    $record.detail = $after.detail
                    $record.seconds = $run.seconds
                    foreach ($p in $stats.PSObject.Properties) { $record[$p.Name] = $p.Value }
                    if ($run.stderr) { Set-Content (Join-Path $out "$name.stderr.txt") $run.stderr }
                }
            } catch {
                $record.cause = 'harness'
                $record.detail = "$_"
            } finally {
                try { & $script -Phase cleanup -Work $work } catch { Write-Host "eval: cleanup $name : $_" }
                Start-Sleep -Seconds 2
            }
            ($record | ConvertTo-Json -Compress -Depth 5) | Add-Content $runs
            Write-Host ("eval: {0} success={1} cause={2} calls={3} turns={4} input={5} s={6}" -f $name, $record.success, $record.cause, $record.tool_calls, $record.turns, $record.input_tokens, $record.seconds)
        }
    }
}
Write-Host "eval: results in $runs"
