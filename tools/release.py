#!/usr/bin/env python3
"""release - the scripted part of a release (CONTRIBUTING.md "发版", .claude/skills/sdp-release).

    python3 -I tools/release.py prep X.Y.Z        # on the release branch, before the PR
    python3 -I tools/release.py notes X.Y.Z       # logs/release-vX.Y.Z.md from the change note
    python3 -I tools/release.py publish X.Y.Z     # after the PR is merged: GitHub release, wait for its files
    python3 -I tools/release.py workshop X.Y.Z    # upload the Workshop package with SteamCMD and check it

prep: modinfo version + 1, VERSION in UI/SDP_Panel.lua, the CHANGELOG's
"未发布" heading becomes "vX.Y.Z（today）", and workshop/changenotes/vX.Y.Z.txt
is started from the CHANGELOG's lines (the Chinese half; the English half is
left as TODO lines to write). Then validate.py and workshop.py check. It
refuses when the CHANGELOG has no "未发布" section or the note exists.

notes: the GitHub release text, English then Chinese, from the last
release's text with its change lists replaced by the change note's and the
zip name updated. Read it before publishing.

publish: `gh release create vX.Y.Z` on origin/main's commit with the notes,
then waits (up to 15 minutes) until the release workflow has attached the
four files, and checks GitHub Pages serves the new report.

workshop: downloads the -workshop.zip into logs/workshop/, writes item.vdf,
uploads with `$STEAMCMD +login $SDP_STEAM_LOGIN +workshop_build_item`
(default ~/steamcmd/steamcmd.sh; the login must be cached: it stops when
SteamCMD asks for a password and never types one), downloads the item back
and compares it with the package's content/. SteamCMD runs with HOME set to
$STEAMCMD_HOME (default ~/steamcmd-home): on macOS it otherwise shares
~/Library/Application Support/Steam with the Steam client, which rewrites
config.vdf and drops SteamCMD's cached login within a day or two, and the
download back would land in the game's Workshop folder (AGENTS.md pitfall
38). Log in once there: HOME=~/steamcmd-home ~/steamcmd/steamcmd.sh +login NAME +quit. Prints the package's
UPLOAD.md first paragraph: what to change on the item page by hand (the
Chinese title and description, the pictures).
"""
import argparse
import datetime
import filecmp
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODINFO = os.path.join(ROOT, "SmartDistrictPlanner", "SmartDistrictPlanner.modinfo")
PANEL = os.path.join(ROOT, "SmartDistrictPlanner", "UI", "SDP_Panel.lua")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
NOTES_DIR = os.path.join(ROOT, "workshop", "changenotes")
LOGS = os.path.join(ROOT, "logs")
ITEM = json.load(open(os.path.join(ROOT, "workshop", "item.json"), encoding="utf-8"))


def sh(cmd, check=True, capture=True, **kw):
    done = subprocess.run(cmd, cwd=ROOT, capture_output=capture, text=True, **kw)
    if check and done.returncode != 0:
        raise SystemExit("%s: %s" % (" ".join(cmd[:3]), (done.stderr or done.stdout or "").strip()[-400:]))
    return done.stdout if capture else ""


def edit(path, old, new, count=1):
    text = open(path, encoding="utf-8").read()
    if old not in text:
        raise SystemExit("%s: did not find %r" % (os.path.relpath(path, ROOT), old[:60]))
    open(path, "w", encoding="utf-8").write(text.replace(old, new, count))


def version_arg(v):
    if not re.fullmatch(r"\d+\.\d+\.\d+", v.lstrip("v")):
        raise argparse.ArgumentTypeError("X.Y.Z")
    return v.lstrip("v")


def unreleased_lines():
    text = open(CHANGELOG, encoding="utf-8").read()
    m = re.search(r"^## 未发布\n(.*?)(?=^## )", text, re.S | re.M)
    if not m:
        raise SystemExit("CHANGELOG.md has no 未发布 section")
    return [l for l in m.group(1).splitlines() if l.startswith("- ")]


def previous_version(v):
    """The newest release tag before vX.Y.Z (pre-releases like -rc.1 left out)."""
    sh(["git", "fetch", "-q", "--tags", "origin"], check=False)
    tags = [t for t in sh(["git", "tag", "--list", "v*", "--sort=-v:refname"]).split()
            if re.fullmatch(r"v\d+\.\d+\.\d+", t) and t != "v" + v]
    return tags[0] if tags else None


def prep(args):
    v = args.version
    note = os.path.join(NOTES_DIR, "v%s.txt" % v)
    if os.path.exists(note):
        raise SystemExit("%s exists" % os.path.relpath(note, ROOT))
    lines = unreleased_lines()
    old = int(re.search(r'<Mod id="[^"]+" version="(\d+)"', open(MODINFO, encoding="utf-8").read()).group(1))
    edit(MODINFO, 'version="%d">' % old, 'version="%d">' % (old + 1))
    panel = open(PANEL, encoding="utf-8").read()
    current = re.search(r'local VERSION = "(v[\d.]+)"', panel).group(1)
    edit(PANEL, 'local VERSION = "%s"' % current, 'local VERSION = "v%s"' % v)
    edit(CHANGELOG, "## 未发布\n", "## v%s（%s）\n" % (v, datetime.date.today().isoformat()))
    prev = previous_version(v) or current
    zh = [re.sub(r"（#\d+(、#\d+)*）", "", l).rstrip() for l in lines]
    with open(note, "w", encoding="utf-8") as fh:
        fh.write("Changes since %s:\n" % prev)
        fh.writelines("- TODO English for: %s\n" % l[2:60] for l in zh)
        fh.write("\n自 %s 以来的变化：\n" % prev)
        fh.writelines(l + "\n" for l in zh)
    print("modinfo version %d -> %d; VERSION %s -> v%s; CHANGELOG dated; %s started (write the English, shorten the "
          "Chinese: no issue numbers, players' words)" % (old, old + 1, current, v, os.path.relpath(note, ROOT)))
    for cmd in (["python3", "-I", "tools/validate.py"], ["python3", "-I", "tools/workshop.py", "check"]):
        out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        print((out.stdout + out.stderr).strip().splitlines()[-1])
    return 0


def note_halves(v):
    text = open(os.path.join(NOTES_DIR, "v%s.txt" % v), encoding="utf-8").read()
    if "TODO" in text:
        raise SystemExit("the change note still has TODO lines")
    en, _, zh = text.partition("\n\n")
    return ([l for l in en.splitlines() if l.startswith("- ")], [l for l in zh.splitlines() if l.startswith("- ")])


def notes(args):
    v = args.version
    en, zh = note_halves(v)
    prev = previous_version(v)
    body = sh(["gh", "release", "view", prev, "--json", "body", "--jq", ".body"])
    pv = prev.lstrip("v")
    body = re.sub(r"## Changes since v[\d.]+\n.*?(?=\n## )", "## Changes since %s\n\n%s\n" % (prev, "\n".join(en)),
                  body, count=1, flags=re.S)
    body = re.sub(r"## 自 v[\d.]+ 以来的变化\n.*?(?=\n## )", "## 自 %s 以来的变化\n\n%s\n" % (prev, "\n".join(zh)),
                  body, count=1, flags=re.S)
    body = body.replace("SmartDistrictPlanner-v%s" % pv, "SmartDistrictPlanner-v%s" % v)
    out = os.path.join(LOGS, "release-v%s.md" % v)
    os.makedirs(LOGS, exist_ok=True)
    open(out, "w", encoding="utf-8").write(body)
    print("wrote %s (from %s's text): read it before publishing" % (os.path.relpath(out, ROOT), prev))
    return 0


def publish(args):
    v = "v" + args.version
    text = os.path.join(LOGS, "release-%s.md" % v)
    if not os.path.exists(text):
        raise SystemExit("run `release.py notes %s` first" % args.version)
    sha = sh(["gh", "api", "repos/{owner}/{repo}/commits/main", "--jq", ".sha"]).strip()
    head = sh(["gh", "api", "repos/{owner}/{repo}/contents/SmartDistrictPlanner/UI/SDP_Panel.lua?ref=" + sha,
               "--jq", ".content"])
    import base64
    if ('local VERSION = "%s"' % v) not in base64.b64decode(head).decode("utf-8"):
        raise SystemExit("main (%s) is not %s yet: merge the release PR first" % (sha[:7], v))
    print(sh(["gh", "release", "create", v, "--target", sha, "--title", v, "--notes-file", text]).strip())
    deadline = time.time() + 900
    while time.time() < deadline:
        names = sh(["gh", "release", "view", v, "--json", "assets", "--jq", ".assets[].name"]).split()
        if len(names) >= 4:
            print("files:", ", ".join(sorted(names)))
            break
        time.sleep(30)
    else:
        raise SystemExit("the release workflow has not attached its files after 15 minutes: gh run list -w release.yml")
    page = subprocess.run(["curl", "-s", "https://smallspider0.github.io/civ6-smart-district-planner/"],
                          capture_output=True, text=True).stdout
    print("GitHub Pages:", "serves %s" % v if v in page else "does not show %s yet (check the pages job)" % v)
    return 0


def workshop(args):
    v = "v" + args.version
    steamcmd = os.path.expanduser(os.environ.get("STEAMCMD", "~/steamcmd/steamcmd.sh"))
    home = os.path.expanduser(os.environ.get("STEAMCMD_HOME", "~/steamcmd-home"))
    os.makedirs(home, exist_ok=True)
    env = dict(os.environ, HOME=home)
    login = os.environ.get("SDP_STEAM_LOGIN")
    if not login or not os.path.exists(steamcmd):
        raise SystemExit("set SDP_STEAM_LOGIN (and STEAMCMD if SteamCMD is elsewhere)")
    work = os.path.join(LOGS, "workshop", v)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    sh(["gh", "release", "download", v, "-p", "*-workshop.zip", "-D", work])
    zipped = [f for f in os.listdir(work) if f.endswith(".zip")][0]
    zipfile.ZipFile(os.path.join(work, zipped)).extractall(work)
    pkg = os.path.join(work, zipped[:-4])
    sh(["python3", "-I", "tools/workshop.py", "vdf", pkg])

    def steam(*cmds):
        done = subprocess.run([steamcmd, "+login", login] + list(cmds) + ["+quit"], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=900, env=env)
        out = done.stdout + done.stderr
        if re.search(r"password|Steam Guard|Two-factor", out, re.I) and "cached credentials" not in out.lower():
            raise SystemExit("SteamCMD wants a password: the user logs in once (HOME=%s %s +login %s +quit)"
                             % (home, steamcmd, login))
        return out

    out = steam("+workshop_build_item", os.path.join(pkg, "item.vdf"))
    if "Success" not in out:
        raise SystemExit("upload failed:\n" + out[-800:])
    print("uploaded")
    item = str(ITEM["publishedfileid"])
    # SteamCMD's own Steam folder under its HOME (macOS layout; elsewhere next to steamcmd).
    roots = [os.path.join(home, "Library", "Application Support", "Steam"), os.path.dirname(steamcmd)]
    targets = [os.path.join(r, "steamapps", "workshop", "content", str(ITEM["appid"]), item) for r in roots]
    out = steam("+workshop_download_item", str(ITEM["appid"]), item)
    target = next((t for t in targets if os.path.isdir(t)), None)
    if target is None:
        raise SystemExit("download back failed:\n" + out[-600:])
    diff = filecmp.dircmp(target, os.path.join(pkg, "content"))
    same = not (diff.left_only or diff.right_only or diff.diff_files or any(
        d.left_only or d.right_only or d.diff_files for d in diff.subdirs.values()))
    shutil.move(target, os.path.join(work, "downloaded"))
    print("downloaded back: %s" % ("identical to the package" if same else "DIFFERS from the package"))
    upload_md = open(os.path.join(pkg, "UPLOAD.md"), encoding="utf-8").read().split("\n\n")
    print("item page:", upload_md[1].strip() if len(upload_md) > 1 else "")
    return 0 if same else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("prep", "notes", "publish", "workshop"):
        sub.add_parser(name).add_argument("version", type=version_arg)
    args = ap.parse_args()
    return {"prep": prep, "notes": notes, "publish": publish, "workshop": workshop}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
