"""Generate neo-compute logo concept SVGs (black, 256 grid)."""
import math
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(OUT, exist_ok=True)

INK = "#111111"


def svg(d, title, vb="0 0 256 256", extra="", evenodd=False):
    fr = ' fill-rule="evenodd"' if evenodd else ""
    w, h = vb.split()[2:]
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{w}" height="{h}" role="img">'
        f"<title>{title}</title>{extra}"
        + (f'<path fill="{INK}"{fr} d="{d}"/>' if d else "")
        + "</svg>\n"
    )


def save(name, content):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        f.write(content)
    print("wrote", name)


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


# ---------------------------------------------------------------- A: pointer n
def pointer_n(w=52, x0=52, width=152, yt=76, yb=220, spike=52, dy=0):
    """Heavy n; the stem's top-left rises into a 45-degree pointer tip."""
    x1 = x0 + width
    R = width / 2  # outer shoulder radius
    cx = x0 + R
    cy = yt + R
    r = R - w
    tip_y = yt - spike
    d = (
        f"M{f(x0)} {f(yb+dy)}V{f(tip_y+dy)}L{f(x0+spike)} {f(yt+dy)}"
        f"H{f(cx)}A{f(R)} {f(R)} 0 0 1 {f(x1)} {f(cy+dy)}V{f(yb+dy)}H{f(x1-w)}"
        f"V{f(cy+dy)}A{f(r)} {f(r)} 0 0 0 {f(cx)} {f(cy-r+dy)}H{f(x0+w)}V{f(yb+dy)}Z"
    )
    return d


# ---------------------------------------------------------------- B: two cursors
def two_cursors(dx=-8, dy=4, caret_w=36):
    pts = [(52, 32), (52, 200), (92, 160), (120, 216), (152, 200), (124, 144), (164, 144)]
    p = "M" + "L".join(f"{x+dx} {y+dy}" for x, y in pts) + "Z"
    cx0 = 184 + dx
    caret = f"M{cx0} {32+dy}H{cx0+caret_w}V{216+dy}H{cx0}Z"
    return p + caret


# ---------------------------------------------------------------- C: node n
def node_n(stroke=36, node=68, x_stem=76, x_leg=180, y_top=76, yb=212, r=48, feet=False):
    h = stroke / 2
    n2 = node / 2
    d = f"M{x_stem-n2} {y_top-n2}H{x_stem+n2}V{y_top+n2}H{x_stem-n2}Z"  # root node
    # stem
    d += f"M{x_stem-h} {y_top+n2}H{x_stem+h}V{yb}H{x_stem-h}Z"
    # arch band from node to right leg
    ax = x_leg - r
    d += (
        f"M{x_stem+n2} {y_top-h}H{ax}A{r+h} {r+h} 0 0 1 {x_leg+h} {y_top+r}V{yb}H{x_leg-h}"
        f"V{y_top+r}A{r-h} {r-h} 0 0 0 {ax} {y_top+h}H{x_stem+n2}Z"
    )
    return d


# ---------------------------------------------------------------- wordmark (monoline, stroked)
def wordmark(sw=18, x=0, base=178, xh=100, gap=16, color=INK):
    """Custom geometric monoline 'neo-compute'. Returns (svg group, width)."""
    t = base - xh  # x-height top
    hs = sw / 2
    parts = []
    cur = x

    def P(d):
        parts.append(d)

    def o(cx0):
        r = (xh - sw) / 2
        c = cx0 + xh / 2
        cy = t + xh / 2
        P(f"M{f(c-r)} {f(cy)}A{f(r)} {f(r)} 0 1 1 {f(c+r)} {f(cy)}A{f(r)} {f(r)} 0 1 1 {f(c-r)} {f(cy)}Z")
        return xh

    def n(x0):
        wdt = 90
        xs, xr = x0 + hs, x0 + wdt - hs
        rr = (xr - xs) / 2
        P(f"M{f(xs)} {f(base)}V{f(t)}")
        P(f"M{f(xs)} {f(t+hs+rr)}A{f(rr)} {f(rr)} 0 0 1 {f(xr)} {f(t+hs+rr)}V{f(base)}")
        return wdt

    def e(x0):
        r = (xh - sw) / 2
        c = x0 + xh / 2
        cy = t + xh / 2
        a = math.radians(42)
        ex, ey = c + r * math.cos(a), cy + r * math.sin(a)
        P(f"M{f(c-r-hs)} {f(cy)}H{f(c+r)}A{f(r)} {f(r)} 0 1 0 {f(ex)} {f(ey)}")
        return xh

    def c_(x0):
        r = (xh - sw) / 2
        c = x0 + xh / 2
        cy = t + xh / 2
        a = math.radians(42)
        sx, sy = c + r * math.cos(a), cy - r * math.sin(a)
        ex, ey = c + r * math.cos(a), cy + r * math.sin(a)
        P(f"M{f(sx)} {f(sy)}A{f(r)} {f(r)} 0 1 0 {f(ex)} {f(ey)}")
        return xh - 12

    def m(x0):
        wdt = 126
        xs = x0 + hs
        xm = x0 + wdt / 2
        xr = x0 + wdt - hs
        r1 = (xm - xs) / 2
        P(f"M{f(xs)} {f(base)}V{f(t)}")
        P(f"M{f(xs)} {f(t+hs+r1)}A{f(r1)} {f(r1)} 0 0 1 {f(xm)} {f(t+hs+r1)}V{f(base)}")
        P(f"M{f(xm)} {f(t+hs+r1)}A{f(r1)} {f(r1)} 0 0 1 {f(xr)} {f(t+hs+r1)}V{f(base)}")
        return wdt

    def p(x0):
        o(x0)
        P(f"M{f(x0+hs)} {f(t)}V{f(base+58)}")
        return xh

    def u(x0):
        wdt = 90
        xs, xr = x0 + hs, x0 + wdt - hs
        rr = (xr - xs) / 2
        P(f"M{f(xs)} {f(t)}V{f(base-hs-rr)}A{f(rr)} {f(rr)} 0 0 0 {f(xr)} {f(base-hs-rr)}")
        P(f"M{f(xr)} {f(t)}V{f(base)}")
        return wdt

    def tt(x0):
        P(f"M{f(x0+18)} {f(t-30)}V{f(base)}")
        P(f"M{f(x0)} {f(t+hs)}H{f(x0+50)}")
        return 50

    def hy(x0):
        P(f"M{f(x0)} {f(t+xh*0.56)}H{f(x0+38)}")
        return 38

    seq = [(n, 0), (e, -2), (o, -6), (hy, 0), (c_, -4), (o, -6), (m, 0), (p, 0), (u, 0), (tt, -4), (e, -2)]
    for fn, kern in seq:
        cur += kern
        wdt = fn(cur)
        cur += wdt + gap
    cur -= gap
    g = (
        f'<g fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="butt" '
        f'stroke-linejoin="round"><path d="{"".join(parts)}"/></g>'
    )
    return g, cur - x


def lockup(symbol_d, name, title, sw=18, evenodd=False, sym_scale=1.0):
    g, ww = wordmark(sw=sw, x=0)
    gap = 44
    total = 256 + gap + ww + 16
    fr = ' fill-rule="evenodd"' if evenodd else ""
    body = (
        f'<path fill="{INK}"{fr} d="{symbol_d}"/>'
        f'<g transform="translate({256+gap} 0)">{g}</g>'
    )
    content = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(total)} 256" width="{f(total)}" height="256" role="img">'
        f"<title>{title}</title>{body}</svg>\n"
    )
    save(name, content)


if __name__ == "__main__":
    a1 = pointer_n(dy=6)
    a2 = pointer_n(spike=72, yt=88, yb=228, dy=0, w=52)
    save("a-symbol-v1.svg", svg(a1, "neo-compute concept A: pointer n"))
    save("a-symbol-v1b.svg", svg(a2, "neo-compute concept A: pointer n, taller tip"))
    b1 = two_cursors()
    save("b-symbol-v1.svg", svg(b1, "neo-compute concept B: two cursors"))
    c1 = node_n()
    save("c-symbol-v1.svg", svg(c1, "neo-compute concept C: node n"))
    lockup(a1, "a-lockup-v1.svg", "neo-compute lockup A")
    lockup(b1, "b-lockup-v1.svg", "neo-compute lockup B")
    lockup(c1, "c-lockup-v1.svg", "neo-compute lockup C")


# ================================================================ v2
POINTER = [(48, 28), (48, 200), (88, 160), (116, 216), (148, 200), (120, 144), (160, 144)]


def poly(pts, dx=0, dy=0):
    return "M" + "L".join(f"{f(x+dx)} {f(y+dy)}" for x, y in pts) + "Z"


def two_cursors_v2(dx=0, caret_w=32, gap=24):
    p = poly(POINTER, dx)
    cx0 = 160 + gap + dx
    return p + f"M{cx0} 32H{cx0+caret_w}V216H{cx0}Z", (48 + dx, cx0 + caret_w)


def clip_band(pts, y0, y1):
    """Sutherland-Hodgman clip of a polygon to the slab y0<=y<=y1."""
    def clip(poly_, inside, inter):
        out = []
        for i in range(len(poly_)):
            cur, prev = poly_[i], poly_[i - 1]
            if inside(cur):
                if not inside(prev):
                    out.append(inter(prev, cur))
                out.append(cur)
            elif inside(prev):
                out.append(inter(prev, cur))
        return out

    def iy(yc):
        return lambda a, b: (a[0] + (b[0] - a[0]) * (yc - a[1]) / (b[1] - a[1]), yc)

    r = clip(pts, lambda p: p[1] >= y0, iy(y0))
    r = clip(r, lambda p: p[1] <= y1, iy(y1)) if r else r
    return r


def scanned_pointer(bands=4, gap=14, dx=16, top=28, bottom=216):
    h = (bottom - top - gap * (bands - 1)) / bands
    d = ""
    for i in range(bands):
        y0 = top + i * (h + gap)
        y1 = y0 + h
        part = clip_band(POINTER, y0, y1)
        if len(part) >= 3:
            d += poly(part, dx)
    return d


def sloped_n(x0=48, width=160, w=52, tip_y=36, yb=220, angle=30, rc=56, dy=0):
    """n whose top slopes down from a pointer-like tip at the top-left."""
    t = math.tan(math.radians(angle))
    x1 = x0 + width
    y_at = lambda x: tip_y + (x - x0) * t
    off = w / math.cos(math.radians(angle))
    # outer: tip -> slope -> rounded corner -> right leg
    # corner: tangent arc between slope line and vertical x=x1, radius rc
    # center of arc: (x1-rc, y_c) where distance to slope line == rc
    # line: t*x - y + (tip_y - x0*t) = 0 ; distance from (x1-rc, yc)
    k = tip_y - x0 * t
    norm = math.sqrt(t * t + 1)
    xc = x1 - rc
    yc = t * xc + k + rc * norm  # below the line
    # tangent point on slope
    nx, ny = t / norm, -1 / norm  # normal pointing up (toward line) from center
    tpx, tpy = xc + nx * rc, yc + ny * rc
    xi0, xi1 = x0 + w, x1 - w
    ri = max(rc - w, 4)
    yci = t * (xi1 - ri) + k + off + ri * norm
    xci = xi1 - ri
    tix, tiy = xci + nx * ri, yci + ny * ri
    d = (
        f"M{f(x0)} {f(yb+dy)}V{f(tip_y+dy)}L{f(tpx)} {f(tpy+dy)}"
        f"A{f(rc)} {f(rc)} 0 0 1 {f(x1)} {f(yc+dy)}V{f(yb+dy)}H{f(xi1)}V{f(yci+dy)}"
        f"A{f(ri)} {f(ri)} 0 0 0 {f(tix)} {f(tiy+dy)}L{f(xi0)} {f(y_at(xi0)+off+dy)}V{f(yb+dy)}Z"
    )
    return d


if __name__ == "__main__":
    a, (l, r) = two_cursors_v2()
    shift = 128 - (l + r) / 2
    a, _ = two_cursors_v2(dx=shift)
    save("a-symbol-v2.svg", svg(a, "neo-compute concept A: two cursors"))
    b = scanned_pointer()
    save("b-symbol-v2.svg", svg(b, "neo-compute concept B: scanned pointer"))
    b5 = scanned_pointer(bands=5, gap=12)
    save("b-symbol-v2b.svg", svg(b5, "neo-compute concept B: scanned pointer, 5 rows"))
    c = sloped_n()
    save("c-symbol-v2.svg", svg(c, "neo-compute concept C: pointed n"))
    c2 = sloped_n(angle=38, tip_y=28, rc=60)
    save("c-symbol-v2b.svg", svg(c2, "neo-compute concept C: pointed n, steeper"))


# ================================================================ v3
def pointer_underscore(bar_h=32):
    """Pointer + terminal underscore: the '>_' prompt with a pointer instead of the chevron."""
    pts = [(56, 32), (56, 172), (89, 139), (112, 186), (139, 172), (116, 126), (149, 126)]
    p = poly(pts)
    y0 = 216 - bar_h
    return p + f"M160 {y0}H216V216H160Z"


def pointing_o(cx=128, cy=128, R=88, ri=40):
    tip = (cx - R, cy - R)
    outer = f"M{f(tip[0])} {f(tip[1])}H{f(cx)}A{R} {R} 0 1 1 {f(cx-R)} {f(cy)}Z"
    hole = f"M{f(cx+ri)} {f(cy)}A{ri} {ri} 0 1 0 {f(cx-ri)} {f(cy)}A{ri} {ri} 0 1 0 {f(cx+ri)} {f(cy)}Z"
    return outer + hole


def counter_n(x0=44, x1=212, top=40, yb=216, w=52, slope_gap=44):
    R = (x1 - x0) / 2
    cx = (x0 + x1) / 2
    cy = top + R
    xi0, xi1 = x0 + w, x1 - w
    y_outer = lambda x: cy - math.sqrt(R * R - (x - cx) ** 2)
    tip_y = y_outer(xi0) + slope_gap
    end_y = tip_y + (xi1 - xi0)
    return (
        f"M{f(x0)} {f(yb)}V{f(cy)}A{f(R)} {f(R)} 0 0 1 {f(x1)} {f(cy)}V{f(yb)}H{f(xi1)}"
        f"V{f(end_y)}L{f(xi0)} {f(tip_y)}V{f(yb)}Z"
    )


if __name__ == "__main__":
    save("a-symbol-v3.svg", svg(two_cursors_v2(dx=128 - (48 + 160 + 24 + 32) / 2)[0], "neo-compute concept A: two cursors"))
    save("a-symbol-v3b.svg", svg(pointer_underscore(), "neo-compute concept A: pointer prompt"))
    save("b-symbol-v3.svg", svg(pointing_o(), "neo-compute concept B: pointing o", evenodd=True))
    save("c-symbol-v3.svg", svg(counter_n(), "neo-compute concept C: pointer counter n"))


# ================================================================ v4
def arch_band(x0, x1, top, yb, w):
    """n-shaped band (outer semicircle arch + two legs) of thickness w."""
    R = (x1 - x0) / 2
    cx = (x0 + x1) / 2
    cy = top + R
    r = R - w
    return (
        f"M{f(x0)} {f(yb)}V{f(cy)}A{f(R)} {f(R)} 0 0 1 {f(x1)} {f(cy)}V{f(yb)}H{f(x1-w)}"
        f"V{f(cy)}A{f(r)} {f(r)} 0 0 0 {f(x0+w)} {f(cy)}V{f(yb)}Z"
    )


def nested_n(x0=40, x1=216, top=36, yb=220, w=36, gap=20, levels=2):
    d = ""
    for i in range(levels):
        o = i * (w + gap)
        d += arch_band(x0 + o, x1 - o, top + o, yb, w)
    o = levels * (w + gap)
    R = (x1 - x0) / 2 - o
    cx = (x0 + x1) / 2
    cy = top + o + R
    # solid core: stadium top
    d += f"M{f(cx-R)} {f(yb)}V{f(cy)}A{f(R)} {f(R)} 0 0 1 {f(cx+R)} {f(cy)}V{f(yb)}Z"
    return d


def pointer_prompt(scale=1.0):
    """Pointer + underscore on one baseline: '>_' with a pointer for a chevron."""
    base = [(0, 0), (0, 172), (40, 132), (68, 188), (100, 172), (72, 116), (112, 116)]
    tipx, tipy = 44, 32
    pts = [(tipx + x * scale, tipy + y * scale) for x, y in base]
    bottom = tipy + 188 * scale
    bar_w, bar_h = 64, 34
    bx = tipx + 112 * scale + 8
    return poly(pts) + f"M{f(bx)} {f(bottom-bar_h)}H{f(bx+bar_w)}V{f(bottom)}H{f(bx)}Z", (tipx, bx + bar_w, tipy, bottom)


if __name__ == "__main__":
    save("b-symbol-v4.svg", svg(nested_n(), "neo-compute concept B: nested n"))
    save("b-symbol-v4b.svg", svg(nested_n(levels=1, w=44, gap=26), "neo-compute concept B: nested n, two levels"))
    d, (l, r, t, b) = pointer_prompt()
    save("a-symbol-v4b.svg", svg(d, "neo-compute concept A: pointer prompt"))
    save("c-symbol-v4.svg", svg(counter_n(slope_gap=36, w=56), "neo-compute concept C: pointer counter n"))


# ================================================================ v5 (finals for checkpoint)
PTR = [(0, 0), (0, 172), (40, 132), (68, 188), (100, 172), (72, 116), (116, 116)]  # exact 45/63.4 deg


def ptr(tx, ty):
    return [(tx + x, ty + y) for x, y in PTR]


def concept_prompt():
    tx, ty = 40, 32
    bar_w, bar_h = 64, 36
    bx = tx + 116 + 12
    bottom = ty + 188
    d = poly(ptr(tx, ty)) + f"M{bx} {bottom-bar_h}H{bx+bar_w}V{bottom}H{bx}Z"
    return d, (tx, bx + bar_w)


def concept_caret():
    tx, ty = 52, 34
    cw = 34
    cx0 = tx + 116 + 22
    d = poly(ptr(tx, ty)) + f"M{cx0} {ty+2}H{cx0+cw}V{ty+188}H{cx0}Z"
    return d, (tx, cx0 + cw)


def centered(fn):
    d, (l, r) = fn()
    shift = 128 - (l + r) / 2
    return re.sub(r"([MLH])(-?[\d.]+)", lambda m: m.group(1) + f(float(m.group(2)) + shift), d)


import re

if __name__ == "__main__":
    a = centered(concept_prompt)
    b = centered(concept_caret)
    c = counter_n(slope_gap=36, w=56)
    save("a-prompt-symbol.svg", svg(a, "neo-compute concept A: pointer prompt"))
    save("b-cursors-symbol.svg", svg(b, "neo-compute concept B: two cursors"))
    save("c-pointing-n-symbol.svg", svg(c, "neo-compute concept C: pointing n"))
    lockup(a, "a-prompt-lockup.svg", "neo-compute lockup A")
    lockup(b, "b-cursors-lockup.svg", "neo-compute lockup B")
    lockup(c, "c-pointing-n-lockup.svg", "neo-compute lockup C")


# ================================================================ v6 lockups on the wordmark baseline
def lockup_aligned(symbol_d, name, title, bbox, scale=0.78, evenodd=False):
    """bbox = (left, top, right, bottom) of the symbol art in its 256 grid."""
    l, t, r, b = bbox
    base = 178
    ty = base - b * scale
    tx = 24 - l * scale
    sym_w = (r - l) * scale
    gap = 44
    g, ww = wordmark(sw=18, x=0)
    wx = 24 + sym_w + gap
    total = wx + ww + 24
    fr = ' fill-rule="evenodd"' if evenodd else ""
    content = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(total)} 256" width="{f(total)}" height="256" role="img">'
        f"<title>{title}</title>"
        f'<g id="symbol" transform="translate({f(tx)} {f(ty)}) scale({scale})"><path fill="{INK}"{fr} d="{symbol_d}"/></g>'
        f'<g id="wordmark" transform="translate({f(wx)} 0)">{g}</g></svg>\n'
    )
    save(name, content)


if __name__ == "__main__":
    lockup_aligned(a, "a-prompt-lockup.svg", "neo-compute lockup A", (32, 32, 224, 220))
    lockup_aligned(b, "b-cursors-lockup.svg", "neo-compute lockup B", (42, 34, 214, 222))
    lockup_aligned(c, "c-pointing-n-lockup.svg", "neo-compute lockup C", (44, 40, 212, 216), scale=0.8)
