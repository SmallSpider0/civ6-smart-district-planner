#!/usr/bin/env python3
"""worktree - extra git worktrees that work like the main checkout.

    python3 -I tools/worktree.py add PATH BRANCH [--base main]
    python3 -I tools/worktree.py list
    python3 -I tools/worktree.py prune [--yes]

A new worktree has no tools/node_modules, tests/compare/.cache or
reference/ (all git-ignored). `add` makes the branch from BASE and links
those three to the main checkout's, so validate.py, the offline tests and
compare.mjs run there at once. `list` shows each worktree with its branch
and whether that branch is merged into origin/main; `prune` removes the
merged ones that have no uncommitted changes (asks first unless --yes) and
deletes their local branches. The main checkout is never touched.
macOS and Linux get symbolic links; Windows gets directory junctions.
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHARED = [os.path.join("tools", "node_modules"), os.path.join("tests", "compare", ".cache")]


def git(*args, cwd=ROOT, check=True):
    done = subprocess.run(["git"] + list(args), cwd=cwd, capture_output=True, text=True)
    if check and done.returncode != 0:
        raise SystemExit("git %s: %s" % (" ".join(args), done.stderr.strip()))
    return done.stdout


def worktrees():
    """[(path, branch or None)], the main checkout first."""
    out, path, branch = [], None, None
    for line in git("worktree", "list", "--porcelain").splitlines() + [""]:
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch "):
            branch = line[len("branch refs/heads/"):]
        elif not line and path:
            out.append((path, branch))
            path, branch = None, None
    return out


def link(target, path):
    if os.path.lexists(path):
        return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if sys.platform == "win32":
        subprocess.run(["cmd", "/c", "mklink", "/J", path, target], check=True, capture_output=True)
    else:
        os.symlink(target, path)
    return True


def add(args):
    main = worktrees()[0][0]
    path = os.path.abspath(os.path.expanduser(args.path))
    git("worktree", "add", "-b", args.branch, path, args.base)
    made = []
    for rel in SHARED:
        target = os.path.realpath(os.path.join(main, rel))
        if os.path.isdir(target) and link(target, os.path.join(path, rel)):
            made.append(rel)
    ref = os.path.join(main, "reference")
    if os.path.isdir(ref):
        for name in sorted(os.listdir(ref)):
            source = os.path.join(ref, name)
            if os.path.isdir(source) and link(os.path.realpath(source), os.path.join(path, "reference", name)):
                made.append("reference/" + name)
    print("worktree %s on %s (from %s); linked: %s" % (path, args.branch, args.base, ", ".join(made) or "nothing"))
    return 0


def merged_branches():
    """Branches whose pull request is merged. The repository only squash-merges,
    so git itself never sees a branch as merged (and a branch just made from
    main, with no commits of its own, would look merged to `git branch
    --merged`). A branch name can come back for new work, so the branch's tip
    must be the merged PR's last commit. Needs gh; without it nothing counts."""
    try:
        prs = subprocess.run(["gh", "pr", "list", "--state", "merged", "--limit", "200", "--json",
                              "headRefName,headRefOid", "--jq", '.[] | .headRefName + " " + .headRefOid'],
                             cwd=ROOT, capture_output=True, text=True)
    except FileNotFoundError:
        return set()
    heads = {tuple(line.split()) for line in prs.stdout.splitlines() if line.strip()}
    merged = set()
    for name, oid in heads:
        tip = git("rev-parse", "--verify", "-q", "refs/heads/" + name, check=False).strip()
        if tip and tip == oid:
            merged.add(name)
    return merged


def listing(_args):
    merged = merged_branches()
    for i, (path, branch) in enumerate(worktrees()):
        dirty = git("status", "--porcelain", cwd=path, check=False).strip() != ""
        print("%-45s %-22s %s%s" % (path, branch or "(detached)", "main checkout" if i == 0 else
                                   ("merged" if branch in merged else "open"), ", uncommitted changes" if dirty else ""))
    return 0


def prune(args):
    merged = merged_branches()
    gone = []
    for path, branch in worktrees()[1:]:
        if branch not in merged:
            continue
        if git("status", "--porcelain", "--untracked-files=no", cwd=path, check=False).strip():
            print("kept %s: uncommitted changes" % path)
            continue
        if not args.yes and input("remove %s (%s)? [y/N] " % (path, branch)).strip().lower() != "y":
            continue
        git("worktree", "remove", "--force", path)
        git("branch", "-D", branch, check=False)
        gone.append(path)
    print("removed: %s" % (", ".join(gone) or "nothing"))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("path")
    a.add_argument("branch")
    a.add_argument("--base", default="main")
    sub.add_parser("list")
    p = sub.add_parser("prune")
    p.add_argument("--yes", action="store_true")
    args = ap.parse_args()
    return {"add": add, "list": listing, "prune": prune}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
