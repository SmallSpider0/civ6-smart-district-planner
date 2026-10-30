#!/usr/bin/env python3
"""workshop - Steam Workshop material and the upload package.

Nothing here talks to Steam: the package is uploaded by hand on Windows
(docs/workshop-upload.md).

    python3 -I tools/workshop.py check            # limits: title, description, change notes, image sizes
    python3 -I tools/workshop.py render           # workshop/src/*.html -> preview.jpg, images/*.jpg, inline/*.jpg (needs Chrome)
    python3 -I tools/workshop.py render --inline  # only the description's pictures, inline/*.jpg
    python3 -I tools/workshop.py pack v1.0.0      # dist/SmartDistrictPlanner-v1.0.0-workshop.zip
    python3 -I tools/workshop.py vdf DIR          # DIR/item.vdf with this machine's absolute paths

workshop/ holds what goes to the item page:
  title.txt, description.bbcode   English title and description (Steam BBCode); uploaded with the package
  title_zh.txt, description_zh.bbcode
                                  the Simplified Chinese version, entered on the item page by hand
                                  (SteamCMD has no field for other languages)
  changenotes/<version>.txt       the update note for each release
  item.json                       app id and, once the item exists, its id (publishedfileid)
  images.txt                      the pictures to add on the item page, in order
  preview.jpg                     the preview image (rendered from src/preview.html)
  images/                         the gallery pictures rendered from src/g*.html (slide.css)
  inline.txt                      the pictures inside the description and their placeholders
  inline/                         those pictures, rendered from src/i<n>-<name>[-en].html (SVG from
                                  tests/compare/refmaps.py --workshop). They go up as Steam screenshots,
                                  not item images, and pack leaves them out

pack takes the mod from the release tag (git archive) and everything else from
the last commit, so a package always matches a release.
"""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS = os.path.join(ROOT, "workshop")
MOD = "SmartDistrictPlanner"
TITLE_MAX = 128
TEXT_MAX = 8000          # description and change note; checked in characters and in UTF-8 bytes
IMAGE_MAX = 1000000      # the preview must be under 1 MB; the other pictures are held to the same size
INLINE_W = 1260          # description pictures: twice Steam's description column of about 630 px
IMG_TAG = re.compile(r"\[img\](.*?)\[/img\]", re.I | re.S)
CHROME = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
          r"C:\Program Files\Google\Chrome\Application\chrome.exe",
          r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
          "google-chrome", "chromium"]


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


def git(*args, binary=False):
    return subprocess.run(["git", "-C", ROOT] + list(args), check=True, capture_output=True,
                          encoding=None if binary else "utf-8").stdout


def images(ref=None):
    """(source path, name in the package) for each line of images.txt, on disk
    or at a git ref.

    Steam keeps the names of deleted item images: an upload under such a name
    fails with error 29, and a re-upload under the same name to replace an
    image lost the picture (2026-10-23). So a rendered diagram
    (workshop/images/) carries a short hash of its content in its name, and a
    changed one gets a new name; screenshots in docs/images/ already get a new
    name when they are retaken."""
    text = git("show", ref + ":workshop/images.txt") if ref else read(os.path.join(WS, "images.txt"))
    out = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        src = line.split()[0]
        stem, ext = os.path.splitext(os.path.basename(src))
        if src.startswith("workshop/images/"):
            path = os.path.join(ROOT, src)
            data = (git("show", "%s:%s" % (ref, src), binary=True) if ref
                    else open(path, "rb").read() if os.path.exists(path) else b"")
            stem += "-" + hashlib.sha1(data).hexdigest()[:6]
        out.append((src, "%02d-%s%s" % (len(out) + 1, stem, ext)))
    return out


def inline():
    """[(path, placeholder)] from inline.txt: the pictures in the descriptions.
    Each one is uploaded as a Steam screenshot and its address replaces the
    placeholder, e.g. [img]STEAM_IMG_REF12_EN[/img]."""
    path = os.path.join(WS, "inline.txt")
    out = []
    if os.path.exists(path):
        for line in read(path).splitlines():
            line = line.split("#", 1)[0].split()
            if len(line) >= 2:
                out.append((line[0], line[1]))
    return out


def img_problems(label, text, placeholders):
    """(errors, placeholders still in the text) for the [img] tags of a
    description: each is an http(s) address or a placeholder of inline.txt."""
    errors, left = [], []
    for target in IMG_TAG.findall(text):
        target = target.strip()
        if target in placeholders:
            left.append(target)
        elif not re.match(r"https?://\S+$", target):
            errors.append("%s: [img]%s[/img] is neither an http(s) address nor a placeholder of inline.txt"
                          % (label, target))
    return errors, left


def inline_size(svg_path, width=INLINE_W):
    """The JPEG size for a description picture: INLINE_W wide, the SVG's aspect."""
    head = open(svg_path, encoding="utf-8").read(2000)
    w, h = (float(v) for v in re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', head).groups())
    return width, int(round(width * h / w))


def images_note(version, first):
    """What to change on the item page's images, against the previous release."""
    names = [name for _, name in images()]
    if first:
        return "第一次上传，`images/` 里的 %d 张图都按文件名顺序上传" % len(names)
    try:
        prev = git("describe", "--tags", "--abbrev=0", version + "^").strip()
        old = [name for _, name in images(prev)]
    except subprocess.CalledProcessError:
        return "找不到上一版的图片清单，对照物品页上的文件名逐张检查"
    add = [n for n in names if n not in old]
    drop = [n for n in old if n not in names]
    if not add and not drop:
        return "和 %s 相同，不用动" % prev
    parts = []
    if add:
        parts.append("上传 " + "、".join("`%s`" % n for n in add))
    if drop:
        parts.append("删除 " + "、".join("`%s`" % n for n in drop))
    return "与 %s 相比，%s；然后在“管理图片”下点“图像排序依据：文件名”，再点“保存并继续”" % (prev, "，".join(parts))


def check_text(errors, label, text, limit, english=False):
    if len(text) > limit or len(text.encode("utf-8")) > limit:
        errors.append("%s: %d characters, %d UTF-8 bytes (limit %d)" % (label, len(text), len(text.encode("utf-8")), limit))
    # Values go into item.vdf between double quotes; keep them free of what would need escaping.
    if '"' in text or "\\" in text:
        errors.append('%s: contains " or \\ (not allowed in item.vdf)' % label)
    if english and re.search("[\u3000-\u9fff\uff00-\uffef]", text):
        errors.append("%s: Chinese text in the English version (it goes into the _zh file)" % label)


def problems():
    """(errors, notes) for the texts, change notes and images: what pack
    would refuse. validate.py reports the errors too, so a PR catches them
    before the release workflow does."""
    errors, notes = [], []
    placeholders = {name: src for src, name in inline()}
    for name, limit, english in (("title.txt", TITLE_MAX, True), ("description.bbcode", TEXT_MAX, True),
                                 ("title_zh.txt", TITLE_MAX, False), ("description_zh.bbcode", TEXT_MAX, False)):
        text = read(os.path.join(WS, name))
        check_text(errors, name, text, limit, english)
        if name.startswith("description"):
            notes.append("%s: %d characters, %d UTF-8 bytes" % (name, len(text), len(text.encode("utf-8"))))
            bad, left = img_problems(name, text, placeholders)
            errors += bad
            for ph in left:
                notes.append("%s: placeholder %s - upload %s as a Steam screenshot and put its address here "
                             "before the description goes to Steam" % (name, ph, placeholders[ph]))
    for name in sorted(os.listdir(os.path.join(WS, "changenotes"))):
        check_text(errors, "changenotes/" + name, read(os.path.join(WS, "changenotes", name)), TEXT_MAX)
    for src in ["workshop/preview.jpg"] + [s for s, _ in images()] + [s for s, _ in inline()]:
        path = os.path.join(ROOT, src)
        if not os.path.exists(path):
            errors.append("%s: missing" % src)
            continue
        size = os.path.getsize(path)
        notes.append("%s: %d KB" % (src, size // 1024))
        if size >= IMAGE_MAX:
            errors.append("%s: %d bytes (limit %d)" % (src, size, IMAGE_MAX))
    return errors, notes


def check(_args=None):
    errors, notes = problems()
    for n in notes:
        print(n)
    for e in errors:
        print("ERROR " + e)
    print("workshop check: %d error(s)" % len(errors))
    return 1 if errors else 0


def chrome():
    for c in CHROME:
        if os.path.exists(c) or shutil.which(c):
            return c
    raise SystemExit("render needs Google Chrome or Chromium")


def shoot(html_path, out_jpg, width, height):
    """Render a page with headless Chrome and save it as a JPEG under IMAGE_MAX."""
    from PIL import Image  # only render needs Pillow
    import pathlib
    with tempfile.TemporaryDirectory() as tmp:
        png = os.path.join(tmp, "shot.png")
        subprocess.run([chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--window-size=%d,%d" % (width, height), "--screenshot=" + png,
                        pathlib.Path(html_path).resolve().as_uri()], check=True, capture_output=True)
        img = Image.open(png).convert("RGB")
        for quality in (90, 85, 80, 75, 70):
            img.save(out_jpg, "JPEG", quality=quality, optimize=True, progressive=True)
            if os.path.getsize(out_jpg) < IMAGE_MAX:
                break
    print("%s: %dx%d, %d KB" % (os.path.relpath(out_jpg, ROOT), width, height, os.path.getsize(out_jpg) // 1024))


CITY_COLORS = ["#2f8fb5", "#e0703a", "#9a5cc8"]
TERRAIN_FILL = {"TERRAIN_GRASS": "#8fae5a", "TERRAIN_PLAINS": "#c2b170", "TERRAIN_GRASS_HILLS": "#7d9450",
                "TERRAIN_COAST": "#6fa8c7"}
LABEL = {"DISTRICT_COMMERCIAL_HUB": "CH", "DISTRICT_HANSA": "H"}


def multi_svg(spec, items, x0=5, x1=13, y0=3, y1=9, s=33.0):
    """One plan of the triangle probe as a hex map: districts in their city's
    color, city centers numbered. Pointy-top hexes, odd rows shifted right,
    north up (as in the game)."""
    import math
    w = math.sqrt(3) * s
    cities = [tuple(c) for c in spec["cities"]]
    ids = sorted({it["city"] for it in items})
    color = {cid: CITY_COLORS[i % len(CITY_COLORS)] for i, cid in enumerate(ids)}
    at = {(it["x"], it["y"]): it for it in items}

    def center(x, y):
        return (x - x0 + 0.5 * (y & 1)) * w + w / 2 + 6, (y1 - y) * 1.5 * s + s + 6

    def hexagon(cx, cy, r):
        pts = []
        for k in range(6):
            a = math.radians(60 * k - 30)
            pts.append("%.1f,%.1f" % (cx + r * math.cos(a), cy + r * math.sin(a)))
        return " ".join(pts)
    out = []
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            p = spec["plots"][y * spec["width"] + x]
            cx, cy = center(x, y)
            out.append('<polygon points="%s" fill="%s" stroke="#33402a" stroke-width="1.2"/>'
                       % (hexagon(cx, cy, s - 0.6), TERRAIN_FILL.get(p["t"], "#8fae5a")))
            if p["t"].endswith("_HILLS"):
                out.append('<path d="M%.1f %.1f l9 -10 l9 10" fill="none" stroke="#4d5c33" stroke-width="2.4"/>' % (cx - 9, cy + 12))
            if p.get("f") == "FEATURE_FOREST" and (x, y) not in at:
                for dx in (-8, 6):
                    out.append('<path d="M%.1f %.1f l6 -13 l6 13 z" fill="#3f6a32"/>' % (cx + dx - 6, cy + 6))
    for y in range(y0, y1 + 1):  # the river runs between columns 8 and 9
        if 3 <= y <= 12:
            cx, cy = center(8, y)
            out.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#3b7fd0" stroke-width="7" stroke-linecap="round"/>'
                       % (cx + w / 2, cy - s / 2, cx + w / 2, cy + s / 2))
    for (x, y), it in at.items():
        cx, cy = center(x, y)
        out.append('<polygon points="%s" fill="%s" stroke="#fff" stroke-width="2.5"/>' % (hexagon(cx, cy, s - 3), color[it["city"]]))
        out.append('<text x="%.1f" y="%.1f" text-anchor="middle" font-size="19" font-weight="700" fill="#fff">%s</text>'
                   % (cx, cy - 2, LABEL.get(it["type"], "?")))
        out.append('<text x="%.1f" y="%.1f" text-anchor="middle" font-size="17" font-weight="600" fill="#fff">+%d</text>'
                   % (cx, cy + 17, it["adj"]))
    for n, (x, y) in enumerate(cities):
        cx, cy = center(x, y)
        cid = 65536 + n
        out.append('<polygon points="%s" fill="#1d2326" stroke="%s" stroke-width="5"/>' % (hexagon(cx, cy, s - 3), color.get(cid, "#fff")))
        out.append('<text x="%.1f" y="%.1f" text-anchor="middle" font-size="26" font-weight="700" fill="#fff">%d</text>' % (cx, cy + 9, n + 1))
    W = (x1 - x0 + 1.5) * w + 12
    H = (y1 - y0) * 1.5 * s + 2 * s + 12
    return ('<svg viewBox="0 0 %.0f %.0f" font-family="Helvetica Neue, Arial, sans-serif">%s</svg>' % (W, H, "".join(out)))


def multi_probe():
    """The triangle probe (tests/compare/cmp_workshop_multi.lua): the map,
    the two plans and their gains."""
    run = subprocess.run(["node", os.path.join(ROOT, "tools", "compare.mjs"), "--probe",
                          os.path.join(ROOT, "tests", "compare", "cmp_workshop_multi.lua")],
                         cwd=ROOT, capture_output=True, text=True, check=True)
    spec, plans, gains = None, {}, {}
    for line in run.stdout.splitlines():
        if line.startswith("SPEC "):
            spec = json.loads(line[5:])
        elif line.startswith("RESULT "):
            _, label, gain = line.split()
            gains[label] = int(float(gain))
        elif line.startswith("ITEM "):
            _, label, city, dtype, x, y, ylds = (line.split() + [""])[:7]
            adj = sum(int(v.split("=")[1]) for v in ylds.split(",") if "=" in v)
            plans.setdefault("joint" if label == "joint" else "single", []).append(
                {"city": int(city), "type": dtype, "x": int(x), "y": int(y), "adj": adj})
        elif line.startswith("SINGLE_TOTAL "):
            gains["single"] = int(float(line.split()[1]))
    return spec, plans, gains


def multi_page(probe):
    """src/g1-multi.html with the triangle probe's two plans drawn in."""
    spec, plans, gains = probe
    src = read(os.path.join(WS, "src", "g1-multi.html"))
    src = (src.replace("{{SINGLE_SVG}}", multi_svg(spec, plans["single"])).replace("{{JOINT_SVG}}", multi_svg(spec, plans["joint"]))
              .replace("{{SINGLE}}", "+%d" % gains["single"]).replace("{{JOINT}}", "+%d" % gains["joint"]))
    out = os.path.join(WS, "src", ".g1-multi.rendered.html")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(src)
    return out


def render_inline():
    """src/i<n>-<name>[-en].html -> inline/i<n>-<name>[-en].jpg, INLINE_W wide.
    Not images/: pack uploads that folder to the item's gallery."""
    os.makedirs(os.path.join(WS, "inline"), exist_ok=True)
    for name in sorted(os.listdir(os.path.join(WS, "src"))):
        m = re.match(r"(i\d-[a-z0-9]+(?:-en)?)\.html$", name)
        if m:
            width, height = inline_size(os.path.join(WS, "src", m.group(1) + ".svg"))
            shoot(os.path.join(WS, "src", name), os.path.join(WS, "inline", m.group(1) + ".jpg"), width, height)


def render(args):
    """The preview (src/preview.html, 1024 x 1024), then the gallery
    pictures: src/g<n>-<name>.html and src/g1-multi.html (with the probe's
    plans drawn in) -> images/<n>-<name>.jpg, 1920 x 1080; then the
    description's pictures (render_inline). --inline: only those."""
    if getattr(args, "inline", False):
        render_inline()
        return 0
    shoot(os.path.join(WS, "src", "preview.html"), os.path.join(WS, "preview.jpg"), 1024, 1024)
    probe = multi_probe()
    os.makedirs(os.path.join(WS, "images"), exist_ok=True)
    for name in sorted(os.listdir(os.path.join(WS, "src"))):
        m = re.match(r"g(\d)-([a-z]+)\.html$", name)
        if m and name != "g1-multi.html":
            shoot(os.path.join(WS, "src", name), os.path.join(WS, "images", "0%s-%s.jpg" % m.groups()), 1920, 1080)
    page = multi_page(probe)
    try:
        shoot(page, os.path.join(WS, "images", "01-multi.jpg"), 1920, 1080)
    finally:
        os.remove(page)
    render_inline()
    return 0


VDF = """"workshopitem"
{
	"appid"		"%(appid)s"
	"publishedfileid"		"%(id)s"
	"contentfolder"		"__DIR__/content"
%(preview)s%(visibility)s	"title"		"%(title)s"
	"description"		"%(description)s"
	"changenote"		"%(changenote)s"
}
"""


def changelog_ok(version):
    return ("## " + version) in read(os.path.join(ROOT, "CHANGELOG.md"))


def zh_note(version, first):
    """What the uploader does about the Chinese version, which the package cannot set."""
    if first:
        return "第一次上传：上传后在物品页添加简体中文版本（见下文）"
    try:
        prev = git("describe", "--tags", "--abbrev=0", version + "^").strip()
    except subprocess.CalledProcessError:
        prev = ""
    if not prev:
        return "没有更早的版本可比，上传后到物品页核对简体中文版本（见下文）"
    if git("diff", "--name-only", prev, "HEAD", "--", "workshop/title_zh.txt", "workshop/description_zh.bbcode").strip():
        return "自 %s 以来有改动，上传后到物品页更新简体中文版本（见下文）" % prev
    return "自 %s 以来没有改动，物品页的中文版本不用动" % prev


def pack(args):
    version = args.version
    if check() != 0:
        return 1
    try:
        git("rev-parse", "--verify", "refs/tags/" + version)
    except subprocess.CalledProcessError:
        print("pack: no tag %s" % version)
        return 2
    note_path = os.path.join(WS, "changenotes", version + ".txt")
    if not os.path.exists(note_path):
        print("pack: write workshop/changenotes/%s.txt first (English, then Chinese)" % version)
        return 2
    if not changelog_ok(version):
        print("pack: CHANGELOG.md has no section for %s" % version)
        return 2
    dirty = git("status", "--porcelain", "--", "workshop", "docs/images", "docs/workshop-upload.md").strip()
    if dirty:
        print("pack: commit these first (the package is built from the last commit):\n" + dirty)
        return 2
    item = json.loads(read(os.path.join(WS, "item.json")))
    modinfo = git("show", "%s:%s/%s.modinfo" % (version, MOD, MOD))
    mod_version = re.search(r'<Mod id="[^"]+" version="(\d+)"', modinfo).group(1)
    first = not item.get("publishedfileid")
    vdf = VDF % {
        "appid": item["appid"], "id": item.get("publishedfileid") or "0",
        "visibility": '\t"visibility"\t\t"2"\n' if first else "",  # first upload: private until checked in game
        # An update leaves the preview image alone: with it, the upload from a
        # contributor's account was refused (Access Denied, 2026-10-23).
        "preview": '\t"previewfile"\t\t"__DIR__/preview.jpg"\n' if first else "",
        "title": read(os.path.join(WS, "title.txt")),
        "description": read(os.path.join(WS, "description.bbcode")),
        "changenote": read(note_path),
    }
    name = "%s-%s-workshop" % (MOD, version)
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    path = os.path.join(ROOT, "dist", name + ".zip")
    stamp = (2026, 1, 1, 0, 0, 0)

    def add(zf, arc, data):
        info = zipfile.ZipInfo(name + "/" + arc, date_time=stamp)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        zf.writestr(info, data)

    with zipfile.ZipFile(path, "w") as zf:
        mod_tar = tarfile.open(fileobj=io.BytesIO(git("archive", "--format=tar", version, MOD, binary=True)))
        files = 0
        for member in mod_tar.getmembers():
            if member.isfile():
                add(zf, "content/" + member.name[len(MOD) + 1:], mod_tar.extractfile(member).read())
                files += 1
        add(zf, "preview.jpg", git("show", "HEAD:workshop/preview.jpg", binary=True))
        for src, arc in images():
            add(zf, "images/" + arc, git("show", "HEAD:" + src, binary=True))
        add(zf, "title.txt", (read(os.path.join(WS, "title.txt")) + "\n").encode("utf-8"))
        add(zf, "description.txt", (read(os.path.join(WS, "description.bbcode")) + "\n").encode("utf-8"))
        add(zf, "title_zh.txt", (read(os.path.join(WS, "title_zh.txt")) + "\n").encode("utf-8"))
        add(zf, "description_zh.txt", (read(os.path.join(WS, "description_zh.bbcode")) + "\n").encode("utf-8"))
        add(zf, "changenote.txt", (read(note_path) + "\n").encode("utf-8"))
        add(zf, "item.vdf.template", vdf.encode("utf-8"))
        guide = re.sub(r"<!--.*?-->\n*", "", read(os.path.join(ROOT, "docs", "workshop-upload.md")), flags=re.S)
        guide = guide.replace("{{VERSION}}", version).replace("{{MOD_VERSION}}", mod_version)
        guide = guide.replace("{{UPLOAD}}", "第一次上传（新建物品，可见性：私密）" if first else
                              "更新已有物品 %s" % item["publishedfileid"])
        guide = guide.replace("{{ZH}}", zh_note(version, first))
        note = images_note(version, first)
        left = sorted({ph for _, ph in inline()
                       if ph in read(os.path.join(WS, "description.bbcode")) + read(os.path.join(WS, "description_zh.bbcode"))})
        if left:
            note += "。简介里还有占位符 %s：先把 `workshop/inline/` 里对应的图作为 Steam 截图上传（不放进物品页图片），" \
                    "再把图片地址填进简介" % "、".join(left)
        guide = guide.replace("{{IMAGES}}", note)
        add(zf, "UPLOAD.md", (guide + "\n").encode("utf-8"))
    print("workshop: %s (%d mod files from tag %s, modinfo version %s, %s, %d KB)" % (
        os.path.relpath(path, ROOT), files, version, mod_version,
        "new item, private" if first else "update of " + item["publishedfileid"], os.path.getsize(path) // 1024))
    return 0


def vdf(args):
    folder = os.path.abspath(args.dir)
    template = os.path.join(folder, "item.vdf.template")
    if not os.path.exists(template):
        print("vdf: %s has no item.vdf.template (unzip the workshop package first)" % folder)
        return 2
    with open(template, encoding="utf-8") as fh:
        text = fh.read()
    text = text.replace("__DIR__", folder.replace("\\", "/"))
    out = os.path.join(folder, "item.vdf")
    with open(out, "w", encoding="utf-8", newline="\n") as fh:  # UTF-8 without BOM
        fh.write(text)
    print("vdf: " + out)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Steam Workshop material and upload package")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="check the limits")
    r = sub.add_parser("render", help="render the preview and the diagrams (needs Chrome and Pillow)")
    r.add_argument("--inline", action="store_true", help="only the description's pictures (workshop/inline/)")
    p = sub.add_parser("pack", help="build the upload package for a release tag")
    p.add_argument("version")
    v = sub.add_parser("vdf", help="write item.vdf with absolute paths into an unzipped package")
    v.add_argument("dir")
    args = ap.parse_args(argv)
    return {"check": check, "render": render, "pack": pack, "vdf": vdf}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
