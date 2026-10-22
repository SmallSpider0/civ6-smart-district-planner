#!/usr/bin/env python3
"""workshop - Steam Workshop material and the upload package.

Nothing here talks to Steam: the package is uploaded by hand on Windows
(docs/workshop-upload.md).

    python3 -I tools/workshop.py check            # limits: title, description, change notes, image sizes
    python3 -I tools/workshop.py render           # workshop/src/*.html -> preview.jpg, images/*.jpg (needs Chrome)
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
  images/                         rendered diagrams (src/flow.html, src/compare.html)

pack takes the mod from the release tag (git archive) and everything else from
the last commit, so a package always matches a release.
"""
import argparse
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


def images():
    """(source path, name in the package) for each line of images.txt."""
    out = []
    for line in read(os.path.join(WS, "images.txt")).splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            src = line.split()[0]
            out.append((src, "%02d-%s" % (len(out) + 1, os.path.basename(src))))
    return out


def check_text(errors, label, text, limit, english=False):
    if len(text) > limit or len(text.encode("utf-8")) > limit:
        errors.append("%s: %d characters, %d UTF-8 bytes (limit %d)" % (label, len(text), len(text.encode("utf-8")), limit))
    # Values go into item.vdf between double quotes; keep them free of what would need escaping.
    if '"' in text or "\\" in text:
        errors.append('%s: contains " or \\ (not allowed in item.vdf)' % label)
    if english and re.search("[\u3000-\u9fff\uff00-\uffef]", text):
        errors.append("%s: Chinese text in the English version (it goes into the _zh file)" % label)


def check(_args=None):
    errors, notes = [], []
    for name, limit, english in (("title.txt", TITLE_MAX, True), ("description.bbcode", TEXT_MAX, True),
                                 ("title_zh.txt", TITLE_MAX, False), ("description_zh.bbcode", TEXT_MAX, False)):
        text = read(os.path.join(WS, name))
        check_text(errors, name, text, limit, english)
        if name.startswith("description"):
            notes.append("%s: %d characters, %d UTF-8 bytes" % (name, len(text), len(text.encode("utf-8"))))
    for name in sorted(os.listdir(os.path.join(WS, "changenotes"))):
        check_text(errors, "changenotes/" + name, read(os.path.join(WS, "changenotes", name)), TEXT_MAX)
    for src in ["workshop/preview.jpg"] + [s for s, _ in images()]:
        path = os.path.join(ROOT, src)
        if not os.path.exists(path):
            errors.append("%s: missing" % src)
            continue
        size = os.path.getsize(path)
        notes.append("%s: %d KB" % (src, size // 1024))
        if size >= IMAGE_MAX:
            errors.append("%s: %d bytes (limit %d)" % (src, size, IMAGE_MAX))
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


def compare_page():
    """src/compare.html with the report's case map and styles filled in."""
    sys.path.insert(0, os.path.join(ROOT, "report"))
    import build as report  # noqa: E402
    page, _ = report.build(make_snapshots=False)
    svg = re.search(r'<div class="frame scroll hexmap" id="case-hero">(.*?)</div>\s*<figcaption', page, re.S).group(1)
    svg = svg.replace("本模组 标准档", "Smart District Planner")
    svg = re.sub(r"漏放 (\d+)", lambda m: "· %s left out" % m.group(1), svg)
    tpl = read(os.path.join(ROOT, "report", "template.html"))
    css = tpl[tpl.index("<style>") + 7:tpl.index("</style>")]
    src = read(os.path.join(WS, "src", "compare.html")).replace("{{CSS}}", css).replace("{{SVG}}", svg)
    out = os.path.join(WS, "src", ".compare.rendered.html")  # next to src/ so relative paths resolve
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(src)
    return out


def render(_args):
    shoot(os.path.join(WS, "src", "preview.html"), os.path.join(WS, "preview.jpg"), 1024, 1024)
    shoot(os.path.join(WS, "src", "flow.html"), os.path.join(WS, "images", "flow.jpg"), 1600, 900)
    page = compare_page()
    try:
        shoot(page, os.path.join(WS, "images", "compare.jpg"), 1600, 900)
    finally:
        os.remove(page)
    return 0


VDF = """"workshopitem"
{
	"appid"		"%(appid)s"
	"publishedfileid"		"%(id)s"
	"contentfolder"		"__DIR__/content"
	"previewfile"		"__DIR__/preview.jpg"
%(visibility)s	"title"		"%(title)s"
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
    sub.add_parser("render", help="render the preview and the diagrams (needs Chrome and Pillow)")
    p = sub.add_parser("pack", help="build the upload package for a release tag")
    p.add_argument("version")
    v = sub.add_parser("vdf", help="write item.vdf with absolute paths into an unzipped package")
    v.add_argument("dir")
    args = ap.parse_args(argv)
    return {"check": check, "render": render, "pack": pack, "vdf": vdf}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
