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
| `zig build bench -- --check bench/baseline.json` | ReleaseFast p95 within 110 % of the baseline and under the absolute budgets in `src/core/bench.zig`. The taskbar scenarios (`snapshot`, `ui_tree`) are provider-relative: a UIA stage above its reference passes within 110 % of `probe_c ... full` run around the series (decision 0010). `bg-act` and `bg-settle` run the background mode behind the decoy; `bg-settle` is budgeted on its `settle` stage, which every other scenario only reports |
| `zig build run -- selftest` | Capture, mouse, keyboard, UIA and DPI against a window the test creates. `-- selftest --capture gdi` runs it with every capture through the GDI fallback (US-032) and skips the DXGI-only checks |
| `zig build run -- selftest --background` | Background mode (EP-011): each `bg-*` control acts on a covered, inactive test window through the `--mode background` server and requires its effect plus an unchanged foreground, keyboard focus, cursor and clipboard and no injected event; 1,000 actions with 0 violation (`bg-loop`); a witness a11y click that the detector must flag (`bg-must-catch`). Cohabitation (EP-012): the pause shortcut and the ignored mouse and Escape (`bg-kill-*`), the label (`bg-indicator*`), settling and waits on change events (`bg-settle-*`, `bg-events-cpu`, `bg-find-*`; `bg-settle-xaml` on Calculator's UI Automation events, `bg-events-learn` on the subscription learned from changes without an event), the foreground guard (`bg-guard-*`: restored from the foreground event while the user types, left alone after a gesture that changes the foreground window, restored for a dialog that comes after the action returned). Complete semantic actions (EP-013): `bg-check`, `bg-uncheck`, `bg-legacy`, `bg-scroll`, `bg-scroll-ancestor`, `bg-range`, `bg-select-name`, `bg-wait-enabled`, `bg-auto-scroll` each require the effect read from Win32, the verdict on the first line of the result and an unchanged session; `bg-verdict` budgets the read-back (< 10 ms p95). Targeted perception (EP-014): `bg-tree-root` (a subtree with the whole tree's ids, `depth`, `root` within the whole tree's p95), `bg-reread` (`ui_find id:` against the state Win32 gives, < 10 ms p95), `bg-occluded` (the flag under the decoy, gone with a 16 px strip that Win32 hit-tests), `bg-occlusion-cost` (< 1 ms p95 with 50 more windows above the target) |
| `zig build bench -- <app>` | One application scenario (`notepad`, `notepad-menu`, `explorer`, `settings`, `calculator`, `chrome`, `chrome-text`, `firefox`, `firefox-msaa`, `vscode`): opens the app, times `ui_tree`, closes it; `app_launch` launches Calculator and a document through `app_launch` and places and closes them with `window_set` (close Calculator first); figures in `bench/apps.md` |
| `pwsh -NoProfile -Command "& ./evals/run.ps1 -DryRun"` | US-016 and US-037 tasks (`-Suite existing` or `parity`): scripted setup, final-state check and cleanup without `claude -p`, after checking that no parity prompt names a tool. `-Solve` also plays each parity task's scripted solution, which its check must accept. Without `-DryRun` it runs the campaign (see Boundaries) and refuses uncommitted changes under `evals/windows`; `evals/report.ps1` writes `evals/reports/<date>.md` |

A story is done when its PRD acceptance criteria hold and the first five
commands pass. A change under `src/backend/`, `bindings/` or `tools/winmdgen/`
also needs `selftest`, with its output in the report; a change to the
background mode, the intrusion classes or a path they share (`ui_act`,
`window_set`, `app_launch`, `uia.zig`, `window.zig`, `hooks.zig`,
`indicator.zig`, `winevents.zig`, `uia_events.zig`, `guard.zig`, settling
and `ui_find`'s wait in `a11y.zig`) also needs `selftest --background`. `selftest` moves the
cursor, types, raises a topmost window, shows the control indicator and
overwrites the clipboard (its earlier text is put back, other formats are
lost); `selftest --background` puts a large decoy window of a second
neo-compute process in the foreground for about a minute (it presses F15
there), shows the mode's label at the top of the primary display, opens a
second window of a neo-compute process whose dialog takes the foreground about
110 times and a topmost still window for 5 s, moves the test window so 16 px
of it show beside the decoy, opens Calculator, presses one of
its digits 11 times and closes it (skipped when one is already open) and
ends with one real click on the decoy; `neo-compute bg-probe` (US-040) does the
same with the six reference applications, which it opens and closes, as does
`neo-compute occlusion-probe` (US-058: Chrome, VS Code and a WPF window,
about 30 min for the 10 launches per situation, `reps=1` for one) and
`neo-compute events-probe` (US-047, and the UI Automation events of
decision 0013's amendment; `events-probe churn` hides, minimizes and closes
the test window, a popup application and Calculator; a run that panics
leaves the application it had open and the decoy process: close both); `bench` captures the screen, reads the
taskbar, raises a topmost test window (`settle`) and puts the decoy in the
foreground twice for about 15 s (`bg-act`, `bg-settle`); the eval dry run opens the task apps, moves two Explorer
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
- Cohabitation (EP-012, measures in decision 0013). In background mode the
  user's mouse and Escape key pause nothing: `Control.background` makes the
  re-arm shortcut a pause toggle (`hooks.zig`), and the indicator is the
  label alone. The low-level hook sees every auto-repeat key-down of a held
  key: a toggle acts on the first and consumes the rest until the key-up
  (`swallow`). Settling and `ui_find`'s wait read one change counter of
  the target (`windowEvents`), never the screen: the WinEvents of its
  process (`winevents.zig`) plus, where the server subscribed, the UI
  Automation events of its subtree (`uia_events.zig`). A UWP application raises no WinEvent
  of its own and raises UI Automation events only for a subscribed client.
  The subscription is not for every window: it costs the target processor
  time on each of its events (Explorer: 4.6 times the cycles of the same
  actions) where WinEvents already report every change. A UWP frame gets
  it from the start; any other application gets it once its tree changed
  twice in a row while its change counter stood still, and loses it for
  good when two more changes stay silent (`treeObserved` in `windows.zig`,
  told of each tree the core shows). Adding or removing the handlers
  raises events of its own in the target: a count read across such a step
  compares with nothing. Its handlers are
  the only COM objects the client implements: static, never freed, built
  on the generated vtables, and they only count. Adding or removing them
  is a round trip to the provider: check `responsive` first, as
  `watchWindow` in `uia.zig` does. A Win32 STATIC raises nothing when its
  text changes, so 50 ms of silence settles, and a tree re-read every
  250 ms (`reread_floor_ms`) covers a stream of events or a refused hook. A
  fixture that must keep settling busy reports its change itself
  (`NotifyWinEvent`, `TestWindow.churn`). Windows 11 refuses
  SetForegroundWindow to the server even with the foreground thread's
  input attached: the foreground guard gives the foreground back by
  activating the user's window inside the foreground input queue
  (`restoreForeground` in `window.zig`). UI Automation's SetFocus is not a
  substitute: on a top-level window it moves nothing, on a child it leaves
  that child as the foreground window. The guard acts from the WinEvent
  thread on `EVENT_SYSTEM_FOREGROUND` (`core/guard.zig` decides,
  `winevents.zig` acts), while the tool may still wait. That event arrives
  before `GetForegroundWindow` names the new window: the thread remembers
  the window and a 10 ms timer restores once it really is in front. Only a
  gesture that can change the foreground window stops a restoration (a
  click outside the user's window, a key with Alt or Win, in `hooks.zig`):
  ordinary typing does not. The guard stays armed 2 s after the action
  (`linger_ms`): an Invoke may return before its dialog comes in front, and
  the next call's result and audit line (`guard_late`) say what it did. The
  decoy of the selftests and probes is a
  framed window: Chromium ignores a `WS_POPUP` window when it computes
  occlusion.
- Complete semantic actions (EP-013, measures in decision 0013). The core
  owns every loop of `ui_act` in `a11y.zig` (wait for an enabled element,
  one scroll into view, read-back of the verdict, never a replay); the
  backend gives four primitives that neither wait nor retry (`uiLive`,
  `uiOp`, `uiScrollHost`, `uiEntries`). A poll aims at a clock time
  (`sleepUntil`): `ctx.sleep` runs in 10 ms slices that Windows rounds up
  to 15.6 ms, so a 100 ms period asked of it lasts about 156 ms. An action
  costs its round trips, about 0.3 ms each, not its properties (a live
  cache cut from 14 properties to 8 measured the same): a read-back asks
  for one property (`LiveRead`), and the pattern call takes its pattern
  from the copy the read before it left (`read_copy` in `uia.zig`). Every
  standard Win32 control with an MSAA default action has InvokePattern
  too, natively and through the MSAA bridge over an oleacc object: the
  fixture of the `DoDefaultAction` fallback is a window with a provider of
  its own (`legacy_control.zig`). A Win32 drop-down list takes Collapse for
  a cancel and drops the entry selected while it was open (it is selected
  again once collapsed), and its open list returns its last item again and
  again to `FindAll` (entries are deduplicated by RuntimeId). The EP-013
  controls of the test window are opt-in (`TestWindow.actions`): the bench
  and the probes measure the window their references were taken on, and
  those controls alone cost `bg-act` 25 %.
- Targeted perception (EP-014, measures in decision 0013). Chrome stops
  rendering a window nothing of which shows: covered or minimized, it never
  builds its web tree, and an action sent to it is delivered while the tree
  read back stays as it was, so `ui_act` answers "contredit" for an action
  that worked. A strip of 16 px in view keeps it current; VS Code turns that
  calculation off (`renders_covered` in `a11y.zig`) but stops like Chrome
  once minimized. The core decides what
  is occluded (`occlusion` in `a11y.zig`, `hidden` in `display.zig`) from
  one backend primitive, `windowLayers` (the z-order, read once per call;
  `window_list` takes it from the enumeration of its own list, a second
  `EnumWindows` cost it 30 % at p95): a Chromium target is judged as
  Chromium judges itself, on window rectangles and without the popups and
  tool windows its tracker ignores, any other window on visible frames.
  `ui_tree` with `root` and `ui_find` with `id:` read from the element the
  session kept (`uiSubtree`, `uiElement`), never the window: a subtree has a
  slot of its own (`Session.sub`) and leaves the tree the next delta
  compares with alone. A subtree's viewport is its window's frame: a fake
  fixture whose root element and window rectangle differ prunes it wrongly.

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
