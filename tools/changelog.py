#!/usr/bin/env python3
"""changelog - the change-log fragments in changelog.d/ (issue 217).

A pull request does not edit CHANGELOG.md. It adds changelog.d/<N>.md, N
being its issue or pull request number (a second file for the same number:
<N>-<word>.md), with one or a few lines in players' words, each one entry:

    - 多城页……（#217）

At release time `tools/release.py prep` calls collect(): the fragments' lines,
by number, become the new version's section at the top of CHANGELOG.md
("## vX.Y.Z（date）", a blank line, the lines), and the fragment files are
deleted. Two branches that each add a fragment never touch the same lines, so
merging one does not make the others conflict (before, every pull request
appended to the end of "未发布" and the rest had to be rebased).

problems() is what tools/validate.py checks: the file names, every non-blank
line is a "- " entry, and CHANGELOG.md has no "未发布" section left.

    python3 -I tools/changelog.py           # print the lines the next release collects
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FOLDER = os.path.join(ROOT, "changelog.d")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
NAME = re.compile(r"^(\d+)(-[A-Za-z0-9_-]+)?\.md$")
README = "README.md"


def shown(path):
    """The path as printed in a message: relative to the repository when it
    is inside it, else as given. On Windows os.path.relpath raises ValueError
    for a path on another drive (a temporary folder on C: while the checkout
    is on D:, as on the CI runner)."""
    try:
        rel = os.path.relpath(path, ROOT)
    except ValueError:
        return path
    return path if rel == os.pardir or rel.startswith(os.pardir + os.sep) else rel


def fragment_files(folder=FOLDER):
    """[(number, name, path)] of the fragments: by number, <N>.md before <N>-<word>.md."""
    if not os.path.isdir(folder):
        return []
    found = []
    for name in sorted(os.listdir(folder)):
        m = NAME.match(name)
        if m:
            found.append((int(m.group(1)), m.group(2) or "", name, os.path.join(folder, name)))
    return [(n, name, path) for n, _, name, path in sorted(found)]


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines()


def problems(folder=FOLDER, changelog=CHANGELOG):
    """[(path, line number, message)]: what validate.py reports."""
    out = []
    if os.path.isdir(folder):
        for name in sorted(os.listdir(folder)):
            path = os.path.join(folder, name)
            if name == README or name.startswith("."):
                continue
            if not NAME.match(name) or not os.path.isfile(path):
                out.append((path, 0, "a fragment is named <issue or PR number>.md, "
                                     "or <number>-<word>.md for a second one"))
                continue
            try:
                lines = read_lines(path)
            except UnicodeDecodeError:
                out.append((path, 0, "not UTF-8"))
                continue
            entries = 0
            for lineno, line in enumerate(lines, 1):
                if not line.strip():
                    continue
                if not line.startswith("- ") or not line[2:].strip():
                    out.append((path, lineno, 'every line is one entry starting with "- " '
                                              "(no headings, no continuation lines)"))
                else:
                    entries += 1
            if not entries:
                out.append((path, 0, 'no entry: write one line starting with "- "'))
    if os.path.isfile(changelog):
        for lineno, line in enumerate(read_lines(changelog), 1):
            if re.match(r"^## +未发布", line):
                out.append((changelog, lineno, "no 未发布 section: put the lines in "
                                               "changelog.d/<issue number>.md (CONTRIBUTING.md)"))
    return out


def entries(folder=FOLDER):
    """The lines the next release collects, fragments by number."""
    lines = []
    for _, _, path in fragment_files(folder):
        lines.extend(l.rstrip() for l in read_lines(path) if l.startswith("- ") and l[2:].strip())
    return lines


def check_collect(version, folder=FOLDER, changelog=CHANGELOG):
    """SystemExit when collect() would refuse: a format problem, no
    fragments, or a section for this version already in CHANGELOG.md."""
    bad = problems(folder, changelog)
    if bad:
        raise SystemExit("\n".join("%s:%d: %s" % (shown(p), n, m) for p, n, m in bad))
    if not entries(folder):
        raise SystemExit("changelog.d/ has no fragments: nothing to release")
    with open(changelog, encoding="utf-8") as f:
        if re.search(r"^## v%s[（( ]" % re.escape(version), f.read(), re.M):
            raise SystemExit("CHANGELOG.md already has a v%s section" % version)


def collect(version, date, folder=FOLDER, changelog=CHANGELOG):
    """Write "## vVERSION（DATE）" with the fragments' lines above the newest
    section of CHANGELOG.md and delete the fragments. Returns the lines.
    Refuses as check_collect() does; then nothing is changed."""
    check_collect(version, folder, changelog)
    lines = entries(folder)
    with open(changelog, encoding="utf-8") as f:
        text = f.read()
    section = "## v%s（%s）\n\n%s\n\n" % (version, date, "\n".join(lines))
    m = re.search(r"^## ", text, re.M)
    text = text[:m.start()] + section + text[m.start():] if m else text.rstrip("\n") + "\n\n" + section.rstrip("\n") + "\n"
    with open(changelog, "w", encoding="utf-8") as f:
        f.write(text)
    for _, _, path in fragment_files(folder):
        os.remove(path)
    return lines


def main():
    bad = problems()
    for path, lineno, message in bad:
        print("%s:%d: %s" % (shown(path), lineno, message))
    for line in entries():
        print(line)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
