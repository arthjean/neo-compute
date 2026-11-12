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
  tool. Judge a candidate tool by what neo-compute's own code would do: a
  native file, registry or process tool runs no command, even when another
  server implements it through PowerShell.
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
| `zig build bench -- --check bench/baseline.json` | ReleaseFast p95 within 110 % of the baseline and under the absolute budgets in `src/core/bench.zig`. The taskbar scenarios (`snapshot`, `ui_tree`) are provider-relative: a UIA stage above its reference passes within 110 % of `probe_c ... full` run around the series (decision 0010) |
| `zig build run -- selftest` | Capture, mouse, keyboard, UIA and DPI against a window the test creates. `-- selftest --capture gdi` runs it with every capture through the GDI fallback (US-032) and skips the DXGI-only checks |
| `zig build run -- selftest --background` | Background mode (EP-011): each `bg-*` control acts on a covered, inactive test window through the `--mode background` server and requires its effect plus an unchanged foreground, keyboard focus, cursor and clipboard and no injected event; 1,000 actions with 0 violation (`bg-loop`); a witness a11y click that the detector must flag (`bg-must-catch`) |
| `zig build bench -- <app>` | One application scenario (`notepad`, `notepad-menu`, `explorer`, `settings`, `calculator`, `chrome`, `chrome-text`, `firefox`, `firefox-msaa`, `vscode`): opens the app, times `ui_tree`, closes it; `app_launch` launches Calculator and a document through `app_launch` and places and closes them with `window_set` (close Calculator first); figures in `bench/apps.md` |
| `pwsh -NoProfile -Command "& ./evals/run.ps1 -DryRun"` | US-016 and US-037 tasks (`-Suite existing` or `parity`): scripted setup, final-state check and cleanup without `claude -p`, after checking that no parity prompt names a tool. `-Solve` also plays each parity task's scripted solution, which its check must accept. Without `-DryRun` it runs the campaign (see Boundaries) and refuses uncommitted changes under `evals/windows`; `evals/report.ps1` writes `evals/reports/<date>.md` |

A story is done when its PRD acceptance criteria hold and the first five
commands pass. A change under `src/backend/`, `bindings/` or `tools/winmdgen/`
also needs `selftest`, with its output in the report; a change to the
background mode, the intrusion classes or a path they share (`ui_act`,
`window_set`, `app_launch`, `uia.zig`, `window.zig`) also needs
`selftest --background`. `selftest` moves the
cursor, types, raises a topmost window, shows the control indicator and
overwrites the clipboard (its earlier text is put back, other formats are
lost); `selftest --background` puts a large decoy window of a second
neo-compute process in the foreground for about a minute (it presses F15
there), opens and closes Calculator (skipped when one is already open) and
ends with one real click on the decoy; `neo-compute bg-probe` (US-040) does the
same with the six reference applications, which it opens and closes; `bench`
captures the screen, reads the taskbar and raises a topmost test
window (`settle`); the eval dry run opens the task apps, moves two Explorer
windows and overwrites the clipboard the same way. Run them one at a time.

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
  `src/backend/windows/com.zig`: the metadata types `UIA_E_*` as `u32`, and a
  `u32`/`i32` comparison compiles but is never true for an error, so test a
  failed call's code with `com.lastWas(w.UIA_E_*)`.
- UIA's `TransactionTimeout` does not bound a call to a window whose thread
  stops after the element was read, nor a slow provider call: the call waits
  until the thread answers. Before a UIA round trip that must stay bounded,
  check the window with `responsive` in `uia.zig` (selftest
  `ui-range-timeout` proves it through `neo-compute selftest-stall`).
- Background mode (decision 0013). A tool's `intrusion` class defaults to
  `input`; only class `none` tools may set `background = true` (compile
  error otherwise), and an intrusive variant of a listed tool is declared in
  its `Args.intrusive` table, refused before the tool runs. Three measured
  facts carry the mode. UIA focuses the target of every pattern call and
  brings its window in front unless `AutoSetFocus` is off, and only the
  `CUIAutomation8` object exposes that setting (`IUIAutomation2`): the
  background session is created from it. `SW_SHOWNOACTIVATE` on a minimized
  window that is still the active window of its own thread takes the
  foreground past the foreground lock: restore through `restoreQuiet` in
  `window.zig`. A process started from a chain that received the last input
  may take the foreground: a non-interference measure is valid only once the
  decoy has pressed a key itself (`decoy_window.zig`), and each `bg-probe`
  target prints that control line.
- A window with `WDA_EXCLUDEFROMCAPTURE` is absent from DXGI and GDI frames,
  but each change of it still produces DXGI dirty rects, and DWM dirties a
  window's whole rectangle whatever its region. An overlay that must not
  disturb settling stays small and static, and its windows are skipped by
  `Collect` in `window.zig`, as the control indicator does (decision 0011).
- Zig 0.17's std (`std.Io`, `std.process.Init`, `std.lang.Optimize`) differs
  from older releases. Verify APIs against the installed std (`std_dir` in
  `zig env`) or against Ghostty, which pins the same version (`C:/dev/ghostty`
  on the reference machine, read-only). There is no `@cImport`: C headers go
  through `b.addTranslateC`, as in Ghostty's `pkg/translate-c/build.zig`.
- The server builds Debug by default. A module's own `optimize` does not
  change how the Zig code of one compilation is optimized: a per-frame pixel
  loop that must stay fast in Debug goes in a separate ReleaseFast library,
  as libjpeg and `src/core/pixel_hash.zig` do. std's `XxHash3` runs about
  370 MB/s here; prefer `Wyhash`. Time CPU budgets against a window of
  another process (`selftest-still`): an in-process window's UIA provider
  counts as the server's CPU. Judge a selftest wall-time budget at the PRD's
  p95, never on the slowest call, and pair it with a thread-CPU budget
  (`QueryThreadCycleTime`): a GDI BitBlt waits on DWM for two thirds of its
  time, and under load that wait alone reached 101 ms (`capture-gdi`).
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
