"""The similar-mods table (section 03 of the page, and the README), in Chinese and English.

    python3 -I report/similar.py zh|en      # print the README's Markdown table

One source for both: the page draws its marks as small inline SVG icons in the
page's theme colors; the README uses ✓ / ◐ / — characters. Facts only, no
scores. Checked on 2026-10-26 against each mod's Workshop page and files
(docs/notes/planner-comparison.md); change them here and paste the Markdown
into README.md.
"""
import sys

MODS = [("Auto Map Tacks Planner", "https://steamcommunity.com/sharedfiles/filedetails/?id=3771382002"),
        ("Empire Planner", "https://steamcommunity.com/sharedfiles/filedetails/?id=3793348626"),
        ("District & Wonder Planner", "https://steamcommunity.com/sharedfiles/filedetails/?id=3780936549"),
        (None, None)]  # this mod
THIS = {"zh": "本模组", "en": "This mod"}

# Rows with a mark: (label zh, label en, [(mark, note zh, note en) per mod]); mark "y" yes, "p" partly, "n" no.
MARKED = [
    ("区域", "Districts", [("y", "", ""), ("y", "", ""), ("y", "一次最多 3 种（另加水渠、市政广场）",
                                                          "up to 3 kinds at a time (plus Aqueduct and Government Plaza)"),
                         ("y", "", "")]),
    ("奇观", "Wonders", [("y", "", ""), ("y", "", ""), ("y", "最多 5 座", "up to 5"), ("y", "", "")]),
    ("改良设施", "Improvements", [("y", "含特色改良设施", "unique improvements included"), ("y", "", ""),
                               ("p", "只规划奇观需要的那一种", "only the one a wonder needs"),
                               ("p", "只规划奇观需要的那一种（阿耳忒弥斯神庙旁的营地）",
                                "only the one a wonder needs (the Camp for the Temple of Artemis)")]),
    ("选新城址", "New city sites", [("n", "未来的城用你打的城市中心钉", "future cities from your City Center tacks"),
                                  ("y", "0–6 处", "0–6"),
                                  ("n", "未来的城用你打的城市中心钉", "future cities from your City Center tacks"),
                                  ("y", "", "")]),
    ("几座城一起规划", "Cities planned together", [("y", "最多 4 座", "up to 4"),
                                                ("y", "全部现有城市和新城址一次规划", "every existing city and the new sites, in one go"),
                                                ("y", "可勾选全部城市", "all cities, with a tick"),
                                                ("y", "最多 8 座（含城址钉）", "up to 8 (site tacks included)")]),
    ("打地图钉", "Places map tacks", [("y", "", ""), ("y", "", ""), ("y", "", ""), ("y", "", "")]),
    ("需要 DMT", "Needs DMT", [("y", "", ""), ("n", "作者建议关掉 DMT", "the author advises turning DMT off"),
                               ("y", "", ""), ("y", "", "")]),
]
# Rows of text: (label zh, label en, [(zh, en) per mod]).
TEXT = [
    ("加成由谁计算", "Bonuses computed by", [("DMT", "DMT"), ("自己的规则", "its own rules"), ("DMT", "DMT"), ("DMT", "DMT")]),
    ("规则集", "Rulesets", [("未写明", "not stated"),
                         ("迭起兴衰、风云变幻（作者说原版没测过）", "Rise and Fall, Gathering Storm (the author says the base game is untested)"),
                         ("未写明", "not stated"), ("原版、迭起兴衰、风云变幻", "Base game, Rise and Fall, Gathering Storm")]),
    ("界面语言", "Interface languages", [("英文、简体中文、繁体中文", "English, Simplified Chinese, Traditional Chinese"), ("英文", "English"),
                                     ("英文、简体中文", "English, Simplified Chinese"), ("英文、简体中文", "English, Simplified Chinese")]),
    ("作者写明的同开限制", "Not to be enabled with (as the author states)",
     [("未写", "not stated"), ("DMT", "DMT"), ("未写", "not stated"), ("其他区域规划器", "other district planners")]),
    ("创意工坊页面的更新日期", "Updated on the Workshop",
     [("2026-09-19（r49）", "2026-09-19 (r49)"), ("2026-09-10", "2026-09-10"), ("2026-08-29（v1.1）", "2026-08-29 (v1.1)"),
      ("2026-10-25", "2026-10-25")]),
]
LEGEND = {"zh": [("y", "是"), ("p", "部分"), ("n", "否")], "en": [("y", "yes"), ("p", "partly"), ("n", "no")]}
CHARS = {"y": "✓", "p": "◐", "n": "—"}


def _esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def icon(mark):
    """A 16 px mark in the page's colors: filled check, half-filled circle, or an empty circle."""
    if mark == "y":
        body = ('<circle cx="8" cy="8" r="7.5" style="fill: var(--teal)"/>'
                '<path d="M4.6 8.2 l2.3 2.4 l4.4 -4.9" fill="none" stroke-width="1.8" stroke-linecap="round" '
                'stroke-linejoin="round" style="stroke: var(--surface)"/>')
    elif mark == "p":
        body = ('<circle cx="8" cy="8" r="6.8" fill="none" stroke-width="1.5" style="stroke: var(--teal)"/>'
                '<path d="M8 1.2 a6.8 6.8 0 0 1 0 13.6 z" style="fill: var(--teal)"/>')
    else:
        body = '<circle cx="8" cy="8" r="6.8" fill="none" stroke-width="1.4" style="stroke: var(--faint)"/>'
    label = {"y": "✓", "p": "◐", "n": "—"}[mark]
    return '<svg class="mk" viewBox="0 0 16 16" width="16" height="16" role="img" aria-label="%s">%s</svg>' % (label, body)


def table_html(lang="zh"):
    """The table and its legend for the page."""
    li = 0 if lang == "zh" else 1
    head = "".join('<th><a href="%s">%s</a></th>' % (url, _esc(name)) if url else "<th>%s</th>" % THIS[lang]
                   for name, url in MODS)
    rows = []
    for zh, en, cells in MARKED:
        tds = "".join('<td>%s%s</td>' % (icon(m), (" " + _esc((nz, ne)[li])) if (nz, ne)[li] else "") for m, nz, ne in cells)
        rows.append("<tr><td>%s</td>%s</tr>" % ((zh, en)[li], tds))
    for zh, en, cells in TEXT:
        rows.append("<tr><td>%s</td>%s</tr>" % ((zh, en)[li], "".join("<td>%s</td>" % _esc(c[li]) for c in cells)))
    legend = ('<p class="legend">%s</p>' % "".join("<span>%s %s</span>" % (icon(m), t) for m, t in LEGEND[lang]))
    return ('<div class="tablewrap"><table class="similar"><thead><tr><th></th>%s</tr></thead><tbody>%s</tbody></table></div>%s'
            % (head, "".join(rows), legend))


def table_md(lang="zh"):
    """The same table in Markdown for the README."""
    li = 0 if lang == "zh" else 1
    out = ["| | %s |" % " | ".join("[%s](%s)" % (n, u) if u else THIS[lang] for n, u in MODS), "|---|---|---|---|---|"]
    for zh, en, cells in MARKED:
        out.append("| %s | %s |" % ((zh, en)[li], " | ".join(
            CHARS[m] + ((" " + (nz, ne)[li]) if (nz, ne)[li] else "") for m, nz, ne in cells)))
    for zh, en, cells in TEXT:
        out.append("| %s | %s |" % ((zh, en)[li], " | ".join(c[li] for c in cells)))
    out.append("")
    out.append(("✓ 是 · ◐ 部分 · — 否" if lang == "zh" else "✓ yes · ◐ partly · — no"))
    return "\n".join(out)


if __name__ == "__main__":
    print(table_md(sys.argv[1] if len(sys.argv) > 1 else "zh"))
