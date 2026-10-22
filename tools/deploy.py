#!/usr/bin/env python3
"""deploy - mirror SmartDistrictPlanner/ into the game's local Mods folder.

New and changed files are copied; files that no longer exist in the source are
removed from the deployed copy (only inside Mods/SmartDistrictPlanner). The
static checks in validate.py run first and block the deploy on errors.

The game reads the modinfo and text only at startup, so changes to those need
a game restart; Lua and UI XML changes load when a game is (re)entered.

Usage: deploy.py [--dry-run] [--skip-validate] [--mods-dir DIR] [--source DIR]
Exit codes: 0 deployed, 1 validation failed, 2 Mods folder not found.
"""

import argparse
import filecmp
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import paths  # noqa: E402
import validate  # noqa: E402

MOD_NAME = "SmartDistrictPlanner"
SOURCE = os.path.join(validate.ROOT, MOD_NAME)


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
