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

Edge is not installed on the reference machine: Chrome stands in for it
(decision 0004).
