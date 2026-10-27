#!/usr/bin/env python3
"""deploy - mirror SmartDistrictPlanner/ into the game's local Mods folder.

New and changed files are copied; files that no longer exist in the source are
removed from the deployed copy (only inside Mods/SmartDistrictPlanner). The
static checks in validate.py run first and block the deploy on errors.

The game reads the modinfo and text only at startup, so changes to those need
a game restart; Lua and UI XML changes load when a game is (re)entered.

A modinfo with a lower version than the deployed one is refused: on
2026-10-27 deploying a branch at version 12 over 13 left the mod unticked in
Additional Content, and every game after that started without it (pitfall 45).
Merge main into the branch first, or pass --allow-downgrade.

The game has one Mods folder, so a deploy takes the game lock for this
worktree (tools/sdplock.py) and refuses while another worktree holds it.

Usage: deploy.py [--dry-run] [--skip-validate] [--allow-downgrade] [--mods-dir DIR] [--source DIR]
Exit codes: 0 deployed, 1 validation failed, 2 Mods folder not found,
4 the game is held by another worktree, 5 the modinfo version would go down.
"""

import argparse
import filecmp
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import paths  # noqa: E402
import sdplock  # noqa: E402
import validate  # noqa: E402

MOD_NAME = "SmartDistrictPlanner"
SOURCE = os.path.join(validate.ROOT, MOD_NAME)


def modinfo_version(mod_dir):
    """The version attribute of <Mod> in MOD_DIR's modinfo, or None."""
    try:
        with open(os.path.join(mod_dir, MOD_NAME + ".modinfo"), encoding="utf-8") as fh:
            m = re.search(r'<Mod\b[^>]*\bversion="(\d+)"', fh.read())
    except OSError:
        return None
    return int(m.group(1)) if m else None


def plan(source, target):
    """Return (added, updated, removed, unchanged) relative paths."""
    src = set(validate.list_files(source))
    dst = set(validate.list_files(target)) if os.path.isdir(target) else set()
    added = sorted(src - dst)
    updated, unchanged = [], []
    for rel in sorted(src & dst):
        same = filecmp.cmp(os.path.join(source, rel), os.path.join(target, rel), shallow=False)
        (unchanged if same else updated).append(rel)
    return added, updated, sorted(dst - src), unchanged


def apply(source, target, added, updated, removed):
    for rel in added + updated:
        dst = os.path.join(target, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(source, rel), dst)
    for rel in removed:
        os.remove(os.path.join(target, rel))
    # Drop folders emptied by removals (dotfiles such as .DS_Store keep a folder).
    for dirpath, _dirs, _files in sorted(os.walk(target), key=lambda w: -len(w[0])):
        if dirpath != target and not os.listdir(dirpath):
            os.rmdir(dirpath)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Deploy the mod into the game's Mods folder")
    ap.add_argument("--dry-run", action="store_true", help="show what would change")
    ap.add_argument("--skip-validate", action="store_true", help="deploy even if validate.py fails")
    ap.add_argument("--allow-downgrade", action="store_true",
                    help="deploy a modinfo version lower than the deployed one (unticks the mod, pitfall 45)")
    ap.add_argument("--mods-dir", default=paths.mods_dir(), help="the game's Mods folder")
    ap.add_argument("--source", default=SOURCE, help=argparse.SUPPRESS)  # for testing the tool
    args = ap.parse_args(argv)

    if not args.skip_validate:
        code, _report = validate.run(mod_dir=os.path.abspath(args.source))
        if code != 0:
            print("deploy: validation failed; nothing deployed (use --skip-validate to override)")
            return 1
    if not args.mods_dir or not os.path.isdir(args.mods_dir):
        print("deploy: Mods folder not found: %s" % args.mods_dir)
        return 2

    target = os.path.join(os.path.abspath(args.mods_dir), MOD_NAME)
    source = os.path.abspath(args.source)
    new, old = modinfo_version(source), modinfo_version(target)
    if new is not None and old is not None and new < old and not args.allow_downgrade:
        print("deploy: the modinfo version would go down from %d to %d; the game then unticks the mod in "
              "Additional Content (pitfall 45). Merge main into this branch first, or pass --allow-downgrade; "
              "nothing deployed" % (old, new))
        return 5
    if not args.dry_run:
        sdplock.claim_or_exit(validate.ROOT)  # one Mods folder: only the game's holder deploys
    added, updated, removed, unchanged = plan(source, target)
    for label, items in (("add", added), ("update", updated), ("remove", removed)):
        for rel in items:
            print("  %-6s %s" % (label, rel))
    if not args.dry_run:
        apply(source, target, added, updated, removed)
    print("deploy%s: %s -> %s: %d added, %d updated, %d removed, %d unchanged"
          % (" (dry run)" if args.dry_run else "", MOD_NAME, target,
             len(added), len(updated), len(removed), len(unchanged)))

    changed = added + updated + removed
    if any(rel.endswith(".modinfo") or rel.startswith("Text/") for rel in changed):
        print("note: modinfo or text changed; restart the game to load it")
    elif changed:
        print("note: reload by returning to the main menu and entering a game again")
    return 0


if __name__ == "__main__":
    sys.exit(main())
