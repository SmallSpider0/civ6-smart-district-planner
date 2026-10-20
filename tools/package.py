#!/usr/bin/env python3
"""package - build the test package for a collaborator (a zip to unpack on Windows).

The zip is built from the last commit, not the working tree, so its name (the
short commit hash) says exactly what is inside:

  SmartDistrictPlanner/   the mod, as committed
  TEST_GUIDE.md           docs/tester-guide.md with the version filled in
  INSTALL_AND_USE.md      docs/install-and-test.md (links to other docs made plain text)

The static checks in validate.py run first, and uncommitted changes to the mod
or to those two documents stop the build. File names in the zip are ASCII so
that Windows' built-in zip tool shows them correctly. Entries carry the commit
time, so the same commit gives the same zip.

Usage: package.py [--out DIR]   (default DIR: dist/)
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

MOD_NAME = "SmartDistrictPlanner"
GUIDE = "docs/tester-guide.md"
INSTALL = "docs/install-and-test.md"


def git(*args, text=True):
    return subprocess.run(["git", "-C", validate.ROOT] + list(args), check=True,
                          capture_output=True, text=text).stdout


def plain_links(markdown):
    """[label](other.md) -> label: the other docs are not in the zip."""
    return re.sub(r"\[([^\]]+)\]\((?!https?:)[^)]*\)", r"\1", markdown)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build the collaborator test package")
    ap.add_argument("--out", default=os.path.join(validate.ROOT, "dist"), help="output folder")
    args = ap.parse_args(argv)

    code, _report = validate.run(quiet=True)
    if code != 0:
        print("package: validation failed; run tools/validate.py for the details")
        return 1
    dirty = git("status", "--porcelain", "--", MOD_NAME, GUIDE, INSTALL).strip()
    if dirty:
        print("package: commit these first (the zip is built from the last commit):")
        print(dirty)
        return 2

    commit = git("rev-parse", "--short", "HEAD").strip()
    stamp = int(git("log", "-1", "--format=%ct").strip())
    date = time.strftime("%Y-%m-%d", time.localtime(stamp))
    when = time.localtime(stamp)[:6]

    files = sorted(git("ls-tree", "-r", "--name-only", "HEAD", "--", MOD_NAME).split("\n"))
    files = [f for f in files if f]
    guide = git("show", "HEAD:" + GUIDE).replace("{{VERSION}}", commit).replace("{{DATE}}", date)
    install = plain_links(git("show", "HEAD:" + INSTALL))

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
        add(zf, "TEST_GUIDE.md", guide.encode("utf-8"))
        add(zf, "INSTALL_AND_USE.md", install.encode("utf-8"))

    print("package: %s (%d mod files + 2 guides, %d KB, commit %s of %s)"
          % (path, len(files), os.path.getsize(path) // 1024, commit, date))
    return 0


if __name__ == "__main__":
    sys.exit(main())
