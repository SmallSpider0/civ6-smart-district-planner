#!/usr/bin/env python3
"""Touch every folder an unattended night run uses, from the calling session's own shell, so a
macOS privacy prompt ("... would like to access files in ...") shows now, while someone is at
the computer, and not in the middle of the night, where it blocks the run until morning.

    python3 -I tools/preflight_night.py

Folders: this repository's worktrees (`git worktree list`), the shared folder of sdplock.py,
the game's folders as tools/paths.py finds them, and the optional list `preflight_folders`
in the local config (see sdplock.py). Folders the tools write to get a test file written and
removed; Steam and the game's install are only listed.

Prints each folder with ok / FAILED / missing; a folder that hangs for more than 10 seconds is
reported as "waiting (prompt on screen?)". Exit code 1 if any folder failed or waited.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import paths  # noqa: E402
import sdplock  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TIMEOUT = 10


def worktrees():
    try:
        out = subprocess.run(["git", "-C", ROOT, "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError) as e:
        print("git worktree list failed: %s" % e)
        return [ROOT]
    found = [line[len("worktree "):] for line in out.splitlines() if line.startswith("worktree ")]
    return found or [ROOT]


def _call(fn, *args):
    try:
        return fn(*args)
    except Exception:  # a probe that fails only means that folder is not checked
        return None


def folders():
    """(path, writable) pairs, in a fixed order, without duplicates."""
    out = [(p, True) for p in worktrees()]
    out.append((sdplock.shared_dir(), True))
    for fn in (paths.game_docs, paths.mods_dir, paths.saves_dir, paths.logs_dir):
        out.append((_call(fn), True))
    out.append((_call(paths.steam_root), False))
    for lib in _call(paths.steam_libraries) or []:
        out.append((lib, False))
    out.append((_call(paths.game_assets), False))
    extra = sdplock.local_config().get("preflight_folders") or []
    if isinstance(extra, list):
        out += [(os.path.expanduser(str(p)), True) for p in extra]
    seen, result = set(), []
    for p, writable in out:
        if p and p not in seen:
            seen.add(p)
            result.append((p, writable))
    return result


def touch(path, writable):
    # A child process per folder, so one waiting on a prompt does not stop the others.
    code = "import os,sys; os.listdir(sys.argv[1])"
    if writable:
        code = ("import os,sys; p=sys.argv[1]; os.listdir(p); f=os.path.join(p, '.sdp-preflight'); "
                "open(f, 'a').close(); os.remove(f)")
    try:
        r = subprocess.run([sys.executable, "-I", "-c", code, path], capture_output=True, text=True, timeout=TIMEOUT)
        return "ok" if r.returncode == 0 else "FAILED: " + (r.stderr.strip().splitlines() or ["?"])[-1]
    except subprocess.TimeoutExpired:
        return "waiting (prompt on screen?)"


def main():
    bad = 0
    for p, writable in folders():
        if not os.path.exists(p):
            print("%-10s %s" % ("missing", p))
            continue
        s = touch(p, writable)
        bad += s != "ok"
        print("%-10s %s" % ("ok" if s == "ok" else "PROBLEM", p) + ("" if s == "ok" else "\n    " + s))
    print("all folders reachable" if not bad else
          "%d folder(s) need access: grant it in System Settings > Privacy & Security" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
