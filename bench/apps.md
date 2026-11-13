# Application snapshots (US-011, US-014)

Measured on 2026-11-03 on the reference machine (Windows 11 Pro 10.0.26300,
display 0 at scale 2), ReleaseFast, with `zig build bench -- <scenario>`, one
scenario at a time. Each scenario opens its reference window, times the first
`ui_tree` right after activation, then runs 50 `ui_tree` calls through the
dispatcher and closes what it opened. Raw elements are the ControlView
elements the UIA worker reads, before pruning; lines are the `ui_tree` output
in steady state. The machine is a working desktop (editors, terminals,
browsers open): figures vary by up to about 40 % between runs.

| Scenario | Reference window | Raw elements | First ui_tree | Steady p95 | Budget | Lines |
|---|---|---|---|---|---|---|
| notepad | new Notepad window | 55 | 221 ms | 35.4 ms | 50 ms | 42 |
| explorer | `bench` folder of this repository | 114 to 119 | 252 to 288 ms | 78 to 112 ms | 50 ms or 110 % of the C witness | 82 to 87 |
| settings | `ms-settings:` home | 129 | 219 ms | 30.8 ms | 50 ms | 77 |
| calculator | Calculator 11.2607, standard mode | 54 | 214 ms | 17.1 ms | 50 ms | 48 |
| chrome | `bench/pages/reference.html`, isolated profile, Chrome 156 | 150 | 297 ms | 23.8 ms | 120 ms | 79 |
| vscode | `bench/pages/reference.html` | 151 | 272 ms | 29.7 ms | 120 ms | 77 |

The first snapshot of a Chromium or Electron window returns the frame only
(20 lines for Chrome, 8 for VS Code) with the line "Contenu web pas encore
exposé ...": Chromium builds the web tree after the first UIA request, and the
next snapshot exposes the page (links, form fields, list items) and VS Code's
menus, toolbars, tabs, breadcrumbs and status bar. The editor text itself is
not in the tree unless VS Code's screen reader mode is on.

Explorer's budget is provider-bound (decision 0004): `bench explorer` runs the
C witness probe from US-001 (`zig-out/bin/probe_c.exe 50 <hwnd>`, 3 cached
properties instead of 12 and 6 patterns) on the same window before and after
the series, and the check accepts a p95 within 110 % of their mean. Over the
runs of 2026-11-03 the witness measured 91 to 163 ms p95 against 78 to 112 ms
for the server on the same window: the cost is Explorer's provider, not the
language (PRD, Rust Switch Gate, last paragraph).

The taskbar scenarios `snapshot` and `ui_tree` are provider-relative
(decision 0010): around each series, `probe_c.exe <n> <hwnd> full` reads the
taskbar as the server's main round trip does (12 properties, 9 patterns, the
control-view subtree), and a UIA stage above 110 % of its reference passes
within 110 % of that witness. On 2026-11-05 the commit that recorded the
baseline (24.0 ms) measured 31 to 32 ms, and the server matched the witness
(snapshot 35.7 ms against 35.5 ms, ui_tree 36.7 ms against 37.0 ms).

Edge is not installed on the reference machine: Chrome stands in for it
(decision 0004).

## EP-005 scenarios (US-022 to US-025)

Measured on 2026-11-05 during the EP-005 review, same protocol. The range and
scroll round trip (US-022, assumption A7), with its check that the window
still answers, is timed apart inside each snapshot; decision 0009 records why
it replaced a second `FindAllBuildCache` (25 ms p95 in Notepad).

| Scenario | Reference window | Raw elements | First ui_tree | Steady p95 | Range and scroll p95 | Budget | Lines |
|---|---|---|---|---|---|---|---|
| notepad | Notepad window | 55 | 196 ms | 32.9 ms | 518 µs | 50 ms | 42 |
| notepad-menu | Notepad, context menu open (right click at its center), `ui_tree` without `window` | 88 | 203 ms | 44.8 ms | 969 µs | 50 ms | 58 |
| chrome | `bench/pages/reference.html`, isolated profile | 150 | 192 ms | 23.7 ms | 341 µs | 120 ms | 79 |
| chrome-text | the same page, `ui_tree` `text: true` | 150 | 187 ms | 31.0 ms | 336 µs | 120 ms | 119 |
| firefox | the same page, fresh profile, Firefox 157 (native UIA) | 488 to 492 | 223 to 233 ms | 36.1 to 44.4 ms | 0 µs | 150 ms | 154 |
| firefox-msaa | the same page, `accessibility.uia.enable = 0`: UIA's MSAA proxy, on-screen elements with MSAA role and state | 214 | 284 ms | 131.6 ms | 0 µs | 150 ms | 151 |

Notepad's context menu is a XAML popup that its window's own tree already
holds: it is read once, inside that tree, not as a further root.

`firefox-msaa` costs what UIA's MSAA proxy costs: about 130 ms to read the
on-screen control view of the page, against 24 ms through Firefox's native
UIA (decision 0009). The MSAA corrections themselves take under 0.1 ms.

## EP-006 scenarios (US-026 to US-029)

Measured on 2026-11-05 during the EP-006 implementation, ReleaseFast. The
desktop scenarios run with `zig build bench -- --check bench/baseline.json`
against the absolute budgets of `src/core/bench.zig`; `app_launch` runs on
request.

| Scenario | What it times | First call | Steady p95 | Budget |
|---|---|---|---|---|
| window_set | `window_set` rect on a test window, alternating halves of display 0, through the dispatcher | - | 4.6 to 5.3 µs | 20 ms |
| apps-catalog | one `FOLDERID_AppsFolder` enumeration on the shell STA (177 entries, 30 packaged) | 170 to 190 ms | 152 to 183 ms | 300 ms |
| apps | a name lookup in the cached catalog | - | 250 to 380 µs | 1 ms |
| app_launch | `app_launch` of Calculator: launch, window, full tree; closed with `window_set` after each run | 0.86 to 1.1 s dispatch, settle included | 30 ms outside settle | - |

`IEnumShellItems::Next` holds 99 % of the enumeration: the shell's
AppsFolder provider builds its list there, and reading the name and AUMID of
each entry costs under 1 ms in all. A shortcut's target is read for the
chosen entry only, at launch (`targetExe`, 15 to 38 ms in Debug): reading it
for every entry raised the enumeration p95 to 219 to 246 ms. Under load from
another build on the machine the enumeration reached 305 to 578 ms.

`app_launch` never moves or closes a window it did not open: it needs
Calculator closed, and skips the document while the default `.txt`
application already runs (Zed on the reference machine). On a desktop where
it ran, the document window and Calculator were placed on the left half of
display 0 with a DWM frame of exactly `0,0,640,720` screenshot pixels, then
closed by `window_set`.

## Covered windows (US-058) and targeted perception (EP-014)

Measured on 2026-11-13 with `neo-compute occlusion-probe` (Debug build), full
output in `docs/decisions/0013-occlusion-probe-run.txt`. Each launch starts a
new process, places its 1100x800 window in one situation before any UI
Automation request, then runs a cold and a warm `ui_act toggle` through a
`--mode background` server while a framed decoy window of another process
holds the foreground. An action counts when its effect shows in the tree in
under 1 s. Chrome's target is a check box of `bench/pages/reference.html`,
VS Code's is its "Toggle Panel" button. 10 launches per situation.

| Target | Situation | Nodes at first contact | Nodes once built | Tree built in place | Actions with effect < 1 s | Delay median / p95 |
|---|---|---|---|---|---|---|
| chrome | visible, inactive | 37 | 150 | 10 of 10 (308 ms) | 20 of 20 (100 %) | 79 / 89 ms |
| chrome | entirely covered | 37 | 150 | 0 of 10 | 0 of 20 (0 %) | none shown |
| chrome | covered but a 16 px strip | 37 | 150 | 10 of 10 (321 ms) | 20 of 20 (100 %) | 79 / 82 ms |
| chrome | other display | 37 | 150 | 10 of 10 (321 ms) | 20 of 20 (100 %) | 80 / 82 ms |
| chrome | minimized | 37 | 150 | 0 of 10 | 0 of 20 (0 %) | none shown |
| vscode | visible, inactive | 14 | 147 | 10 of 10 (308 ms) | 19 of 20 (95 %) | 145 / 288 ms |
| vscode | entirely covered | 14 | 147 | 10 of 10 (309 ms) | 19 of 20 (95 %) | 193 / 289 ms |
| vscode | covered but a 16 px strip | 14 | 147 | 10 of 10 (309 ms) | 20 of 20 (100 %) | 193 / 291 ms |
| vscode | other display | 14 | 147 | 10 of 10 (320 ms) | 20 of 20 (100 %) | 198 / 286 ms |
| vscode | minimized | 14 | 147 | 0 of 10 | 0 of 20 (0 %) | none shown |

Chrome refutes A19: entirely covered or minimized, it never builds its web
tree and no action shows its effect, although all 20 were delivered (each
effect showed once the window was back in view; uncovering builds the tree in
290 ms, restoring in 25 ms). The cheapest situation that reaches 95 % is the
16 px strip; 1 px was enough on 4 actions of 4. VS Code validates A19: it
turns Chromium's occlusion calculation off and keeps its tree current while
covered. Its two missed actions, one visible and one covered, were lost by
VS Code itself (no effect once in view either), and one launch on the other
display started with the decoy not in front. Minimized, VS Code freezes like
Chrome. A `<select>` of the Chrome page lists no entry while closed and does
not open through ExpandCollapse, visible or covered. The WPF window shows its
own 11 nodes at the first read, 0 ms after the window exists (first read 90
to 103 ms, then 8 to 11 ms), on 3 launches of 3.

The same probe with the EP-014 tools on each window (one launch per
situation): `ui_tree` heads a covered Chrome window with `{occluded}` and
ends with the frozen-tree line, a covered VS Code window gets the flag
without the line, and neither appears with the 16 px strip in view.
`ui_tree` with `depth: 2` gives 19 lines for Chrome and 8 for VS Code; the
container that stands for the most descendants, read with `root`, gives 45
lines (1,809 characters) for Chrome and 70 lines (3,674 characters) for
VS Code. `ui_find` with `id:` reads one element again in 0.56 to 0.71 ms
median, 0.69 to 0.92 ms p95, on both.

On the test window (`selftest --background`, Debug build, provider in the
same process): `root` on the window's own element 30.9 ms p95 against 31.5 ms
for the whole tree, `ui_find id:` 0.87 ms p95, reading the z-order and the
occlusion calculation 0.14 ms p95 with 51 windows above the target (62 in
the z-order). `window_list` with the flag (ReleaseFast bench): `dispatch`
0.43 to 0.61 ms p95 against a 0.61 ms reference.
