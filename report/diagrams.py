"""Diagrams drawn for the page and the README, in Chinese and English.

    python3 -I report/diagrams.py      # writes docs/images/similar-mods-{zh,en}-{light,dark}.svg

similar_svg(lang) is the "what each planner plans" matrix (section 03 and
the README's similar-mods table): facts only, no scores. Inline in the page
it colors itself with the page's CSS variables, so it follows the page's
theme; the README gets one file per theme (<picture> picks it).
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Checked on 2026-10-26 against each mod's Workshop page and files (docs/notes/planner-comparison.md).
# Each cell: (mark, note): mark "y" plans it, "p" only the one a wonder needs, "n" does not, "t" plain text.
SIMILAR = {
    "cols": {"zh": ["区域", "奇观", "改良设施", "选新城址", "多城一起规划", "需要 DMT"],
             "en": ["Districts", "Wonders", "Improvements", "New city sites", "Cities together", "Needs DMT"]},
    "rows": [
        ("Auto Map Tacks Planner", None, [
            ("y", ("", "")), ("y", ("", "")), ("y", ("含特色改良", "unique ones too")), ("n", ("", "")),
            ("y", ("最多 4 座", "up to 4")), ("t", ("需要", "yes"))]),
        ("Empire Planner", None, [
            ("y", ("", "")), ("y", ("", "")), ("y", ("", "")), ("y", ("0–6 处", "0–6")),
            ("y", ("全部城市", "every city")), ("t", ("不需要", "no"))]),
        ("District & Wonder Planner", None, [
            ("y", ("一次 3 种", "3 kinds at a time")), ("y", ("最多 5 座", "up to 5")), ("p", ("奇观所需", "for a wonder")),
            ("n", ("", "")), ("y", ("可勾选全部", "all, with a tick")), ("t", ("需要", "yes"))]),
        ("本模组", "This mod", [
            ("y", ("", "")), ("y", ("", "")), ("p", ("奇观所需", "for a wonder")), ("y", ("", "")),
            ("y", ("最多 8 座", "up to 8")), ("t", ("需要", "yes"))]),
    ],
    "legend": {"zh": [("y", "规划"), ("p", "只规划奇观需要的那一种"), ("n", "不规划")],
               "en": [("y", "plans it"), ("p", "only the one a wonder needs"), ("n", "does not plan it")]},
}

# Colors of a standalone file, per theme (the page uses its own CSS variables instead).
THEMES = {
    "light": {"fg": "#14202a", "muted": "#56646e", "line": "#d4dce1", "mark": "#1d6470", "soft": "#dcecef"},
    "dark": {"fg": "#e3eaee", "muted": "#9fb0ba", "line": "#2a3a44", "mark": "#6ab9c6", "soft": "#173039"},
}
PAGE = {"fg": "var(--fg)", "muted": "var(--muted)", "line": "var(--line)", "mark": "var(--teal)", "soft": "var(--teal-soft)"}


def _esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _mark(kind, cx, cy, c):
    r = 9
    if kind == "y":
        return ('<circle cx="%g" cy="%g" r="%g" fill="%s"/>'
                '<path d="M%g %g l3.6 3.8 l6.6 -7.4" fill="none" stroke="%s" stroke-width="2.2" stroke-linecap="round" '
                'stroke-linejoin="round"/>' % (cx, cy, r, c["mark"], cx - 5, cy, c["soft"]))
    if kind == "p":
        return ('<circle cx="%g" cy="%g" r="%g" fill="none" stroke="%s" stroke-width="2"/>'
                '<path d="M%g %g a%g %g 0 0 1 0 %g z" fill="%s"/>' % (cx, cy, r - 1, c["mark"], cx, cy - r + 1, r - 1, r - 1,
                                                                    2 * (r - 1), c["mark"]))
    return '<circle cx="%g" cy="%g" r="%g" fill="none" stroke="%s" stroke-width="1.6"/>' % (cx, cy, r - 1, c["muted"])


def similar_svg(lang="zh", theme=None):
    """The matrix as an SVG string; theme None colors it with the page's CSS variables."""
    c = PAGE if theme is None else THEMES[theme]
    li = 0 if lang == "zh" else 1
    font = ('"Noto Sans SC", "PingFang SC", "Microsoft YaHei", system-ui, sans-serif' if lang == "zh"
            else 'system-ui, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif')
    name_w, col_w, head_h, row_h = 196, 104, 44, 58
    cols = SIMILAR["cols"][lang]
    W = name_w + col_w * len(cols) + 8
    H = head_h + row_h * len(SIMILAR["rows"]) + 44
    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" role="img" font-family=\'%s\' aria-label="%s">'
           % (W, H, font, _esc("各模组规划什么" if lang == "zh" else "What each planner plans"))]
    for i, name in enumerate(cols):
        x = name_w + col_w * i + col_w / 2
        out.append('<text x="%g" y="%d" text-anchor="middle" font-size="12.5" fill="%s">%s</text>' % (x, head_h - 16, c["muted"], _esc(name)))
    for r, (zh, en, cells) in enumerate(SIMILAR["rows"]):
        y0 = head_h + row_h * r
        out.append('<line x1="0" x2="%d" y1="%d" y2="%d" stroke="%s"/>' % (W, y0, y0, c["line"]))
        label = zh if li == 0 or en is None else en
        out.append('<text x="10" y="%d" font-size="14" font-weight="600" fill="%s">%s</text>' % (y0 + row_h / 2 + 5, c["fg"], _esc(label)))
        for i, (kind, notes) in enumerate(cells):
            cx = name_w + col_w * i + col_w / 2
            note = notes[li]
            if kind == "t":
                out.append('<text x="%g" y="%d" text-anchor="middle" font-size="13" fill="%s">%s</text>' % (cx, y0 + row_h / 2 + 5, c["fg"], _esc(note)))
                continue
            cy = y0 + (row_h / 2 - 7 if note else row_h / 2)
            out.append(_mark(kind, cx, cy, c))
            if note:
                out.append('<text x="%g" y="%d" text-anchor="middle" font-size="11.5" fill="%s">%s</text>' % (cx, cy + 25, c["muted"], _esc(note)))
    yb = head_h + row_h * len(SIMILAR["rows"])
    out.append('<line x1="0" x2="%d" y1="%d" y2="%d" stroke="%s"/>' % (W, yb, yb, c["line"]))
    x = 12
    for kind, text in SIMILAR["legend"][lang]:
        out.append(_mark(kind, x + 9, yb + 24, c))
        out.append('<text x="%d" y="%d" font-size="12.5" fill="%s">%s</text>' % (x + 24, yb + 29, c["muted"], _esc(text)))
        x += 34 + int(len(text) * (13 if lang == "zh" else 6.6))
    out.append("</svg>")
    return "".join(out)


def write_files():
    """docs/images/similar-mods-<lang>-<theme>.svg for the README."""
    for lang in ("zh", "en"):
        for theme in THEMES:
            path = os.path.join(REPO, "docs", "images", "similar-mods-%s-%s.svg" % (lang, theme))
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(similar_svg(lang, theme) + "\n")
            print(os.path.relpath(path, REPO))


if __name__ == "__main__":
    write_files()
