# neo-compute logo guidelines

## 1. The logo

**Idea.** The n of neo, whose counter (the space inside the letter) is a pointer tip: a vertical left
edge and a 45-degree top edge. It reads as a letter first and as a pointer on the second look, which
is what neo-compute does: it acts on the desktop on behalf of Claude Code.

**Versions.** Horizontal (primary), stacked, symbol only, wordmark only. Each one comes in a standard
version for light grounds and a reversed version for dark grounds.

| Use | File |
|---|---|
| Primary logo, light ground | `neo-compute-horizontal.svg` |
| Primary logo, dark ground | `neo-compute-horizontal-reversed.svg` |
| Square or narrow spaces | `neo-compute-stacked.svg`, `neo-compute-stacked-reversed.svg` |
| Symbol, 32 px and up | `neo-compute-symbol.svg` |
| Symbol, below 32 px (favicons, tabs, tray) | `neo-compute-symbol-small.svg` |
| Symbol, light on dark | `neo-compute-symbol-reversed.svg` |
| Wordmark alone | `neo-compute-wordmark.svg`, `neo-compute-wordmark-reversed.svg` |
| One-colour black, white or Signal, PNG exports | `variants/` |
| Favicons, app icons, web manifest, `<head>` snippet | `web/` |
| Presentation board and mockups | `presentation/board.html`, `presentation/slides/` |

## 2. Construction

Every shape is built from primitives on a 256-unit grid, with no fonts, strokes, masks or effects.

- **Symbol**: the outer arch is a semicircle of radius 84. The stem and the leg are 56 wide, and so is the
  counter. The tip of the counter sits 36 units below the arch, and its top edge runs at exactly 45 degrees.
- **Small cut**: drawn on a 16 px grid (16 units = 1 px). It has 4 px stems, a wider 6 px counter, and a tip
  that runs over whole pixels from (5, 5) to (11, 11). This keeps a 16 px favicon crisp.
- **Reversed cut**: 2 to 3 units lighter. Light shapes on a dark ground look heavier than they are
  (irradiation), and the lighter cut compensates for it.
- **Wordmark**: a custom geometric monoline alphabet. The x-height is 100, the stroke is 18 (17 when
  reversed), and the bowls are true circles. It is drawn as outlines: never retype it in a font.

`source/logo.py` regenerates every master: `python assets/logo/source/logo.py`.

## 3. Clear space

The unit is **one stem width** of the symbol, which is one third of the symbol's width. Keep at least one
unit of empty space on every side of any version. The gap between the symbol and the wordmark in the
lockups is also one unit; do not change it.

## 4. Minimum size

| Version | Screen | Print |
|---|---|---|
| Horizontal | 120 px wide | 30 mm wide |
| Stacked | 120 px wide | 25 mm wide |
| Symbol | 16 px, using the small cut below 32 px | 5 mm |

## 5. Colour

| Name | HEX | RGB | CMYK (approx.) | Use |
|---|---|---|---|---|
| Signal | `#EB4A22` | 235 74 34 | 0 69 86 8 | Symbol, accents |
| Ink | `#141416` | 20 20 22 | 60 40 40 100 (rich black) | Wordmark, dark grounds, app-icon tile |
| Paper | `#F6F5F1` | 246 245 241 | 0 0 2 4 | Light grounds, reversed wordmark |

The CMYK values are direct sRGB conversions. Match Signal against a Pantone swatch book before any print
run: 172 C and 1665 C are the closest candidates.

Measured contrast: Signal on white is 3.8:1, on Paper 3.5:1 and on Ink 4.9:1. Ink on Paper is 16.9:1. Every
pair passes the 3:1 minimum for graphics.

**Approved pairs:**
- Signal symbol with Ink wordmark, on white or Paper (primary).
- Signal symbol with Paper wordmark, on Ink (reversed).
- One colour in Ink, black or white.
- White symbol on a Signal tile.

On a photo, use the one-colour white or black version over a calm area.

Signal was chosen to stay clear of Windows blue and of the blue that most developer tools use. It also
reads as "live control", like a recording light, which suits an agent that drives the desktop.

## 6. Typography

The wordmark is artwork, not a font. For headings and body text next to the logo, use a neutral sans (the
system UI stack is enough), and a monospace font for code. Do not set "neo-compute" in another typeface
as a substitute for the wordmark.

## 7. Don'ts

- Don't stretch, squash, rotate or mirror the logo. Mirroring turns the pointer tip away.
- Don't recolour it outside the palette.
- Don't add shadows, outlines, gradients or glows.
- Don't rearrange or resize the parts of a lockup.
- Don't use the large symbol below 32 px; use the small cut instead.
- Don't put the Signal symbol on mid greys or on saturated colours.

## 8. Handover notes

**Tests run** (logo-design skill scripts):
- SVG audit: 99 to 100/100 on every master. The only notes are informational: the extra-wide horizontal
  lockup, for which the stacked version exists.
- Size ladder from 16 to 256 px, with a pixel test at 16, 32 and 48 px.
- Light, dark, photographic and patterned grounds.
- One-colour, greyscale and reversed versions.
- Squint (blur) test, mirror and 180-degree rotation: no unintended reading.

**Open items:**
- Trademark clearance is not done. Run a search in the relevant trademark databases, plus a reverse image
  search, before any public launch.
- Pantone matching for Signal (see section 5).
- `mark-focus.svg`, `mark-pointer-window.svg` and `mark-reticle.svg` in this folder predate this kit and are
  not part of it.
- The terminal mockup in `presentation/` shows placeholder commands, not neo-compute's real interface.
- `concepts/` keeps round 1 (three directions) and its explorations, for the record.
