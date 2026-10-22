#!/usr/bin/env python3
"""setup_reference - link the game's and the other mods' sources into reference/.

    python3 -I tools/setup_reference.py

reference/ is git-ignored: it points at files on this machine, never copied
into the repository. validate.py reads base-ui/ and dlc/ (UI precedents),
tools/compare.mjs reads dmt/, amt/ and ep/. macOS gets symbolic links;
Windows gets directory junctions (mklink /J), which need no administrator
rights or developer mode. Existing links are replaced; a real folder in
their place is left alone. Missing sources (say, Empire Planner not
subscribed) are reported and skipped. Locations come from tools/paths.py.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import paths  # noqa: E402

REFERENCE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "reference")


def is_link(path):
    if os.path.islink(path):
        return True
    isjunction = getattr(os.path, "isjunction", None)  # Python 3.12+
    if isjunction is not None:
        return isjunction(path)
    try:
        return bool(os.lstat(path).st_file_attributes & 0x400)  # FILE_ATTRIBUTE_REPARSE_POINT
    except (OSError, AttributeError):
        return False


def link(name, target):
    path = os.path.join(REFERENCE, name)
    if target is None or not os.path.isdir(target):
        print("%-8s skipped: source not found" % name)
        return False
    if os.path.lexists(path):
        if not is_link(path):
            print("%-8s skipped: %s is a real folder, not a link" % (name, path))
            return False
        if os.path.isdir(path) and not os.path.islink(path):
            os.rmdir(path)  # a junction: removes the link only
        else:
            os.remove(path)
    if sys.platform == "win32":
        subprocess.run(["cmd", "/c", "mklink", "/J", path, target], check=True, capture_output=True)
    else:
        os.symlink(target, path)
    print("%-8s -> %s" % (name, target))
    return True


def main():
    assets = paths.game_assets()
    sources = [
        ("base-ui", assets and os.path.join(assets, "Base", "Assets", "UI")),
        ("dlc", assets and os.path.join(assets, "DLC")),
        ("dmt", paths.workshop_item(paths.DMT)),
        ("amt", paths.workshop_item(paths.AMT)),
        ("ep", paths.workshop_item(paths.EP)),
    ]
    os.makedirs(REFERENCE, exist_ok=True)
    made = [link(name, target) for name, target in sources]
    # base-ui, dlc and dmt are what validate.py and the mod's own work need.
    return 0 if all(made[:3]) else 2


if __name__ == "__main__":
    sys.exit(main())
