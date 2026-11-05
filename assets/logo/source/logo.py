"""Build the neo-compute logo masters (symbol, wordmark, lockups) as clean filled SVG.

Run: python assets/logo/source/logo.py   (writes into assets/logo/)

Every shape is constructed from primitives on a 256-unit grid: no fonts, no strokes, no masks.
The wordmark is a custom geometric monoline alphabet drawn as outlines (one contour per glyph,
holes with fill-rule="evenodd").
"""

import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.dirname(HERE)

SIGNAL = "#EB4A22"
INK = "#141416"
PAPER = "#F6F5F1"


def f(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


# ----------------------------------------------------------------------------- symbol
def pointing_n(x0=44, x1=212, top=40, yb=216, w=56, tip_gap=36, tip_y=None):
    """Heavy geometric n. Outer arch: a semicircle. Counter: a pointer tip (vertical left
    edge, 45-degree top edge), so the n's inner space points to the top-left."""
    R = (x1 - x0) / 2
    cx = (x0 + x1) / 2
    cy = top + R
    xi0, xi1 = x0 + w, x1 - w
    y_outer = cy - math.sqrt(R * R - (xi0 - cx) ** 2)
    tip_y = y_outer + tip_gap if tip_y is None else tip_y
    end_y = tip_y + (xi1 - xi0)  # exact 45 degrees
    return (
        f"M{f(x0)} {f(yb)}V{f(cy)}A{f(R)} {f(R)} 0 0 1 {f(x1)} {f(cy)}V{f(yb)}H{f(xi1)}"
        f"V{f(end_y)}L{f(xi0)} {f(tip_y)}V{f(yb)}Z"
    )


SYMBOL = pointing_n()
SYMBOL_BBOX = (44, 40, 212, 216)
# Small-size cut, drawn on the 16 px grid (16 units = 1 px): 4 px stems, a 6 px counter, and the
# 45-degree tip running over whole pixels from (5, 5) to (11, 11), so a 16 px favicon renders crisp.
SYMBOL_SMALL = pointing_n(x0=16, x1=240, top=16, yb=240, w=64, tip_y=80)
# Reversed cut: 2 units lighter, to offset irradiation of light shapes on dark grounds.
SYMBOL_REVERSED = pointing_n(x0=45, x1=211, top=41, yb=216, w=53, tip_gap=37)


# ----------------------------------------------------------------------------- wordmark
def glyphs(sw=18.0, xh=100.0):
    """Return {char: (advance, fn(x0, t) -> path)}; t = x-height top, baseline = t + xh."""
    hs = sw / 2
    a42 = math.radians(42)

    def circ(cx, cy, r, sweep=1):
        return (
            f"M{f(cx+r)} {f(cy)}A{f(r)} {f(r)} 0 1 {sweep} {f(cx-r)} {f(cy)}"
            f"A{f(r)} {f(r)} 0 1 {sweep} {f(cx+r)} {f(cy)}Z"
        )

    def n(x0, t):
        W = 90
        b = t + xh
        rr = (W - sw) / 2
        cx, cy = x0 + W / 2, t + hs + rr
        Ro, Ri = rr + hs, rr - hs
        y1 = cy - math.sqrt(Ro * Ro - (W / 2 - sw) ** 2)
        return (
            f"M{f(x0)} {f(b)}V{f(t)}H{f(x0+sw)}V{f(y1)}A{f(Ro)} {f(Ro)} 0 0 1 {f(x0+W)} {f(cy)}"
            f"V{f(b)}H{f(x0+W-sw)}V{f(cy)}A{f(Ri)} {f(Ri)} 0 0 0 {f(x0+sw)} {f(cy)}V{f(b)}Z"
        )

    def ring_parts(x0, t):
        c, cy = x0 + 50, t + xh / 2
        Ro, Ri = xh / 2, xh / 2 - sw
        return c, cy, Ro, Ri

    def o(x0, t):
        c, cy, Ro, Ri = ring_parts(x0, t)
        return circ(c, cy, Ro, 1) + circ(c, cy, Ri, 0)

    def e(x0, t):
        c, cy, Ro, Ri = ring_parts(x0, t)
        o42 = (c + Ro * math.cos(a42), cy + Ro * math.sin(a42))
        i42 = (c + Ri * math.cos(a42), cy + Ri * math.sin(a42))
        ax = c + math.sqrt(Ro * Ro - hs * hs)
        cxl = c - math.sqrt(Ri * Ri - hs * hs)
        dx = math.sqrt(Ri * Ri - hs * hs)
        outer = (
            f"M{f(o42[0])} {f(o42[1])}A{f(Ro)} {f(Ro)} 0 1 1 {f(ax)} {f(cy+hs)}"
            f"H{f(cxl)}A{f(Ri)} {f(Ri)} 0 0 0 {f(i42[0])} {f(i42[1])}Z"
        )
        eye = f"M{f(c+dx)} {f(cy-hs)}A{f(Ri)} {f(Ri)} 0 0 0 {f(c-dx)} {f(cy-hs)}Z"
        return outer + eye

    def c_(x0, t):
        c, cy, Ro, Ri = ring_parts(x0, t)
        p = lambda r, a: (c + r * math.cos(a), cy + r * math.sin(a))
        o1, o2 = p(Ro, a42), p(Ro, -a42)
        i1, i2 = p(Ri, a42), p(Ri, -a42)
        return (
            f"M{f(o1[0])} {f(o1[1])}A{f(Ro)} {f(Ro)} 0 1 1 {f(o2[0])} {f(o2[1])}"
            f"L{f(i2[0])} {f(i2[1])}A{f(Ri)} {f(Ri)} 0 1 0 {f(i1[0])} {f(i1[1])}Z"
        )

    def m(x0, t):
        W = 126
        b = t + xh
        xm = W / 2
        r1 = (xm - hs) / 2
        c1 = hs + r1
        cy = t + hs + r1
        Ro, Ri = r1 + hs, r1 - hs
        y1 = cy - math.sqrt(Ro * Ro - (c1 - sw) ** 2)
        y2 = cy - math.sqrt(Ro * Ro - (xm - c1) ** 2)
        X = lambda v: f(x0 + v)
        return (
            f"M{X(0)} {f(b)}V{f(t)}H{X(sw)}V{f(y1)}A{f(Ro)} {f(Ro)} 0 0 1 {X(xm)} {f(y2)}"
            f"A{f(Ro)} {f(Ro)} 0 0 1 {X(W)} {f(cy)}V{f(b)}H{X(W-sw)}V{f(cy)}"
            f"A{f(Ri)} {f(Ri)} 0 0 0 {X(xm+hs)} {f(cy)}V{f(b)}H{X(xm-hs)}V{f(cy)}"
            f"A{f(Ri)} {f(Ri)} 0 0 0 {X(sw)} {f(cy)}V{f(b)}Z"
        )

    def p(x0, t):
        c, cy, Ro, Ri = ring_parts(x0, t)
        b = t + xh
        dy = math.sqrt(Ro * Ro - (50 - sw) ** 2)
        outer = (
            f"M{f(x0)} {f(b+58)}V{f(t)}H{f(x0+sw)}V{f(cy-dy)}"
            f"A{f(Ro)} {f(Ro)} 0 1 1 {f(x0+sw)} {f(cy+dy)}V{f(b+58)}Z"
        )
        return outer + circ(c, cy, Ri, 0)

    def u(x0, t):
        W = 90
        b = t + xh
        rr = (W - sw) / 2
        cx, cy = x0 + W / 2, b - hs - rr
        Ro, Ri = rr + hs, rr - hs
        y3 = cy + math.sqrt(Ro * Ro - (W / 2 - sw) ** 2)
        return (
            f"M{f(x0)} {f(t)}H{f(x0+sw)}V{f(cy)}A{f(Ri)} {f(Ri)} 0 0 0 {f(x0+W-sw)} {f(cy)}"
            f"V{f(t)}H{f(x0+W)}V{f(b)}H{f(x0+W-sw)}V{f(y3)}A{f(Ro)} {f(Ro)} 0 0 1 {f(x0)} {f(cy)}Z"
        )

    def tt(x0, t):
        b = t + xh
        s0, s1 = x0 + 18 - hs, x0 + 18 + hs
        return (
            f"M{f(s0)} {f(t-30)}H{f(s1)}V{f(t)}H{f(x0+50)}V{f(t+sw)}H{f(s1)}V{f(b)}"
            f"H{f(s0)}V{f(t+sw)}H{f(x0)}V{f(t)}H{f(s0)}Z"
        )

    def hy(x0, t):
        y = t + xh * 0.56
        return f"M{f(x0)} {f(y-hs)}H{f(x0+38)}V{f(y+hs)}H{f(x0)}Z"

    return {"n": (90, n), "e": (100, e), "o": (100, o), "c": (88, c_), "m": (126, m),
            "p": (100, p), "u": (90, u), "t": (50, tt), "-": (38, hy)}


KERN = {"e": -2, "o": -6, "-": 0, "c": -4, "m": 0, "p": 0, "u": 0, "t": -4}
KERN_AFTER = {("t", "e"): -2, ("n", "e"): -2}


def wordmark(sw=18.0, x=0.0, t=78.0, gap=16.0):
    g = glyphs(sw)
    text = "neo-compute"
    d = ""
    cur = x
    prev = None
    for ch in text:
        if prev is not None:
            cur += KERN_AFTER.get((prev, ch), KERN.get(ch, 0))
        adv, fn = g[ch]
        d += fn(cur, t)
        cur += adv + gap
        prev = ch
    return d, cur - gap - x


# ----------------------------------------------------------------------------- files
def write(name, w, h, body, title):
    w, h = math.ceil(w - 0.01), math.ceil(h - 0.01)
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(w)} {f(h)}" width="{f(w)}" '
        f'height="{f(h)}" role="img" aria-labelledby="title"><title id="title">{title}</title>{body}</svg>\n'
    )
    with open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(svg)
    print("wrote", name)


def sym(d, color, tx=0.0, ty=0.0, s=1.0):
    tr = "" if (tx, ty, s) == (0, 0, 1) else f' transform="translate({f(tx)} {f(ty)}) scale({f(s)})"'
    return f'<g id="symbol"{tr}><path fill="{color}" d="{d}"/></g>'


def wm(d, color, tx=0.0, ty=0.0):
    tr = "" if (tx, ty) == (0, 0) else f' transform="translate({f(tx)} {f(ty)})"'
    return f'<g id="wordmark"{tr}><path fill="{color}" fill-rule="evenodd" d="{d}"/></g>'


def horizontal(sym_d, sym_color, word_color, sw, name, title):
    pad = 24
    s = 0.8
    l, _, r, b = SYMBOL_BBOX
    base = 178
    d, ww = wordmark(sw)
    gap = 56 * s  # one stem width at lockup scale = clear-space unit
    sx = pad - l * s
    sy = base - b * s
    wx = pad + (r - l) * s + gap
    write(name, wx + ww + pad, 256, sym(sym_d, sym_color, sx, sy, s) + wm(d, word_color, wx), title)


def stacked(sym_d, sym_color, word_color, sw, name, title):
    pad = 48
    d, ww = wordmark(sw)
    s = 1.6
    l, t, r, b = SYMBOL_BBOX
    W = ww + 2 * pad
    sym_w, sym_h = (r - l) * s, (b - t) * s
    sx = (W - sym_w) / 2 - l * s
    sy = pad - t * s
    word_top = pad + sym_h + 72  # gap above the x-height = 1.6 stems... optical
    # wordmark glyphs are built with x-height top at t=78; shift so ascender (t-30) clears the gap
    ty = word_top + 30 - 78
    H = word_top + 30 + 100 + 58 + pad
    write(name, W, H, sym(sym_d, sym_color, sx, sy, s) + wm(d, word_color, pad, ty), title)


if __name__ == "__main__":
    T = "neo-compute logo"
    write("neo-compute-symbol.svg", 256, 256, sym(SYMBOL, SIGNAL), T)
    write("neo-compute-symbol-small.svg", 256, 256, sym(SYMBOL_SMALL, SIGNAL), T + ", small-size cut")
    write("neo-compute-symbol-reversed.svg", 256, 256, sym(SYMBOL_REVERSED, PAPER), T + ", reversed")
    d, ww = wordmark(18)
    write("neo-compute-wordmark.svg", ww + 48, 256, wm(d, INK, 24), T + ", wordmark")
    d, ww = wordmark(17)
    write("neo-compute-wordmark-reversed.svg", ww + 48, 256, wm(d, PAPER, 24), T + ", wordmark reversed")
    horizontal(SYMBOL, SIGNAL, INK, 18, "neo-compute-horizontal.svg", T)
    horizontal(SYMBOL, SIGNAL, PAPER, 17, "neo-compute-horizontal-reversed.svg", T + ", reversed")
    stacked(SYMBOL, SIGNAL, INK, 18, "neo-compute-stacked.svg", T + ", stacked")
    stacked(SYMBOL, SIGNAL, PAPER, 17, "neo-compute-stacked-reversed.svg", T + ", stacked reversed")
