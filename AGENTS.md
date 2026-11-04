# neo-compute

Single-binary MCP server (Zig 0.17.0, stdio) that gives Claude Code perception
and action on the Windows 11 desktop: a mirror of the 17
`computer_toolset_20260801` tools plus UI Automation and window tools. Scope,
stories and acceptance criteria: `tasks/prd-neo-compute.md`. Story status:
`tasks/prd-neo-compute-status.json`.

## Boundaries

Edit code, run any build step below, and fix what the gates report without
asking. Stop and report to Arthur instead of proceeding when:

- a Rust Switch Gate condition (PRD, "Rust Switch Gate") becomes true: the
  language choice is his;
- a change would alter the product contract: tool names or parameters,
  supported MCP versions, security or policy behavior, the Zig version. Once
  he decides, record it in `docs/decisions/` (French, next number, same header
  as `0002-mcp-protocol-version.md`);
- passing the bench gate would require rewriting `bench/baseline.json`. Use
  `--write-baseline` only for a new scenario or at his request, never to clear
  a regression;
- a task needs `zig build calibrate-tokens` or `evals/run.ps1` without
  `-DryRun`: both call `claude -p` on his Claude Code subscription. There is
  no Anthropic API key: never add a step that needs `ANTHROPIC_API_KEY` or
  direct API calls.

Every change keeps these product invariants (PRD FR-07 to FR-18):

- The server opens no network connection and exposes no command or script
  tool.
- stdout carries only JSON-RPC, one message per line, written by the
  dispatcher in `src/core/mcp.zig`. Logs never go to stdout.
- Password field values never appear in text, images, or logs. Text read from
  the screen is untrusted data.
- Held keys and buttons are released within 50 ms on stdin EOF, cancellation,
  kill switch, and error: Claude Code kills the process 300 ms after closing
  stdin.

## Commands and gates

| Command | Checks |
|---|---|
| `zig fmt --check .` | Formatting (`zig fmt <path>` fixes it) |
| `zig build` | Server and probes. The first run downloads the pinned win32metadata nupkg from nuget.org with `curl` and fetches libjpeg-turbo (`build.zig.zon`) into `zig-pkg/`, then serves both from the cache |
| `zig build test -Dtest-filter=<name>` | Core tests on the fake backend, compile-time budget errors, generated bindings and struct layouts, generator failure message, process lifecycle. Omit the filter for the full gate |
| `zig build cross` | Core builds for x86_64-linux-gnu with the fake backend, so no Windows dependency entered `src/core/` |
| `zig build bench -- --check bench/baseline.json` | ReleaseFast p95 within 110 % of the baseline and under the absolute budgets in `src/core/bench.zig` |
| `zig build run -- selftest` | Capture, mouse, keyboard, UIA and DPI against a window the test creates |
| `zig build bench -- <app>` | One application scenario (`notepad`, `explorer`, `settings`, `calculator`, `chrome`, `vscode`): opens the app, times `ui_tree`, closes it; figures in `bench/apps.md` |
| `pwsh -NoProfile -Command "& ./evals/run.ps1 -DryRun"` | US-016 tasks: scripted setup, final-state check and cleanup without `claude -p`. Without `-DryRun` it runs the campaign (see Boundaries); `evals/report.ps1` writes `evals/reports/<date>.md` |

A story is done when its PRD acceptance criteria hold and the first five
commands pass. A change under `src/backend/`, `bindings/` or `tools/winmdgen/`
also needs `selftest`, with its output in the report. `selftest` moves the
cursor, types, and raises a topmost window; `bench` captures the screen,
reads the taskbar and raises a topmost test window (`settle`). Run them one at a time.

## Architecture and gotchas

- `src/core/` calls no Windows API; Windows code lives in
  `src/backend/windows/`. `src/main.zig` selects the backend at comptime,
  optional backend capabilities are probed with `@hasDecl`, and
  `src/backend/fake.zig` implements every method the core calls
  unconditionally.
- Tools are declared in `src/core/tools.zig`; schemas, `tools/list` and
  argument validation derive from each `Args` struct at comptime
  (`src/core/registry.zig`). Allocate tool output from `ctx.arena`, never the
  GPA: steady-state requests allocate nothing from it. Long operations poll
  `ctx.cancelled()` or wait with `ctx.sleep`.
- The first 17 tools must match `tests/fixtures/toolset_20260801.json`, a copy
  of Anthropic's external toolset contract: fix `tools.zig`, never the fixture.
  Extensions are optional parameters only.
- Win32 and COM bindings are generated. Add the API name to
  `bindings/windows.zon` (a trailing `*` matches a function prefix) and
  rebuild; do not hand-write vtables or Win32 declarations, since the manual
  US-001 vtable was off by one slot. Check HRESULTs with `com.check` in
  `src/backend/windows/com.zig`: the metadata types `UIA_E_*` as `u32`.
- Zig 0.17's std (`std.Io`, `std.process.Init`, `std.lang.Optimize`) differs
  from older releases. Verify APIs against the installed std (`std_dir` in
  `zig env`) or against Ghostty, which pins the same version (`C:/dev/ghostty`
  on the reference machine, read-only). There is no `@cImport`: C headers go
  through `b.addTranslateC`, as in Ghostty's `pkg/translate-c/build.zig`.
- A defect fixed in the Zig COM layer (bindings, object lifetime, apartment)
  counts toward Rust Switch Gate condition 3: update its counter in
  `docs/decisions/0001-zig-vs-rust.md` with the attempt count.
- Code, comments, tool descriptions and the MCP `instructions` are in US
  English; the PRD and `docs/decisions/` are in French. Tool error messages use
  the French wording of the PRD (Edge Cases, acceptance criteria) and name the
  cause and the next action (FR-06).
- To check a real client: `claude mcp add -s local neo-compute-check --
  <repo>/zig-out/bin/neo-compute.exe`, then `claude mcp list`, then
  `claude mcp remove -s local neo-compute-check`.

## Report

End a run with the files changed, each gate command and its result, the
`selftest` output for backend changes, bench p95 against the baseline when a
measured path changed, any Rust Switch Gate update, and the decisions left for
Arthur.
