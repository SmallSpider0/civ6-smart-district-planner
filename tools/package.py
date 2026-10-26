#!/usr/bin/env python3
"""package - build the mod package (a zip for players and testers; attached to each release).

The zip is built from the last commit, not the working tree, so its name (the
version, by default the short commit hash) says exactly what is inside:

  SmartDistrictPlanner/   the mod, as committed
  TEST_GUIDE.md           docs/tester-guide.md with the version filled in (not with --release)
  INSTALL_AND_USE.md      docs/install-and-test.md (links to other docs made plain text)
  INSTALL_AND_USE_EN.md   docs/install-en.md, the same way
  REPORT.html             the mod's page (introduction and evaluation) as one self-contained file (report/build.py)
  REPORT_EN.html          the English page (sections 1-6), the same way

The static checks in validate.py run first, and uncommitted changes to the mod,
to those two documents or to anything the report reads stop the build (the
report is built from the working tree, which that check makes equal to the
commit). File names in the zip are ASCII so
that Windows' built-in zip tool shows them correctly. Entries carry the commit
time, so the same commit gives the same zip.

Usage: package.py [--out DIR] [--version V]   (default DIR: dist/, V: the short commit hash)
Exit codes: 0 built, 1 validation failed, 2 uncommitted changes.
"""

import argparse
import os
import re
import subprocess
import sys
import time
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import validate  # noqa: E402

sys.path.insert(0, os.path.join(validate.ROOT, "report"))
import build as report  # noqa: E402

MOD_NAME = "SmartDistrictPlanner"
GUIDE = "docs/tester-guide.md"
INSTALL = "docs/install-and-test.md"
INSTALL_EN = "docs/install-en.md"


def git(*args, text=True):
    # Git writes UTF-8; say so, or Windows decodes with the ANSI code page.
    return subprocess.run(["git", "-C", validate.ROOT] + list(args), check=True,
                          capture_output=True, encoding="utf-8" if text else None).stdout


def plain_links(markdown):
    """[label](other.md) -> label: the other docs are not in the zip."""
    return re.sub(r"\[([^\]]+)\]\((?!https?:)[^)]*\)", r"\1", markdown)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build the collaborator test package")
    ap.add_argument("--out", default=os.path.join(validate.ROOT, "dist"), help="output folder")
    ap.add_argument("--version", help="version for the zip name, the guide and the page (default: the commit)")
    ap.add_argument("--release", action="store_true",
                    help="the zip for a GitHub release: the players' files only, without the testers' guide")
    args = ap.parse_args(argv)

    code, _report = validate.run(quiet=True)
    if code != 0:
        print("package: validation failed; run tools/validate.py for the details")
        return 1
    dirty = git("status", "--porcelain", "--", MOD_NAME, GUIDE, INSTALL, INSTALL_EN, *report.INPUTS).strip()
    if dirty:
        print("package: commit these first (the zip is built from the last commit):")
        print(dirty)
        return 2

    commit = args.version or git("rev-parse", "--short", "HEAD").strip()
    stamp = int(git("log", "-1", "--format=%ct").strip())
    date = time.strftime("%Y-%m-%d", time.localtime(stamp))
    when = time.localtime(stamp)[:6]

    files = sorted(git("ls-tree", "-r", "--name-only", "HEAD", "--", MOD_NAME).split("\n"))
    files = [f for f in files if f]
    guide = git("show", "HEAD:" + GUIDE).replace("{{VERSION}}", commit).replace("{{DATE}}", date)
    install = plain_links(git("show", "HEAD:" + INSTALL))
    install_en = plain_links(git("show", "HEAD:" + INSTALL_EN))
    page, _data = report.build(version=commit, date=date)
    page_en, _data = report.build(version=commit, date=date, lang="en")
    image = lambda name: git("show", "HEAD:docs/images/" + name, text=False)  # noqa: E731
    report_html = report.standalone(page, image)
    report_en = report.standalone(page_en, image, "en")

    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "%s-%s.zip" % (MOD_NAME, commit))

    def add(zf, name, data):
        info = zipfile.ZipInfo(name, date_time=when)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        zf.writestr(info, data)

    with zipfile.ZipFile(path, "w") as zf:
        for name in files:
            add(zf, name, subprocess.run(["git", "-C", validate.ROOT, "show", "HEAD:" + name],
                                         check=True, capture_output=True).stdout)
        if not args.release:
            add(zf, "TEST_GUIDE.md", guide.encode("utf-8"))
        add(zf, "INSTALL_AND_USE.md", install.encode("utf-8"))
        add(zf, "INSTALL_AND_USE_EN.md", install_en.encode("utf-8"))
        add(zf, "REPORT.html", report_html.encode("utf-8"))
        add(zf, "REPORT_EN.html", report_en.encode("utf-8"))

    print("package: %s (%d mod files + %d guides + 2 pages, %d KB, commit %s of %s)"
          % (path, len(files), 2 if args.release else 3, os.path.getsize(path) // 1024, commit, date))
    return 0


if __name__ == "__main__":
    sys.exit(main())
