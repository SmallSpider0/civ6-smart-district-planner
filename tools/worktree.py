#!/usr/bin/env python3
"""worktree - extra git worktrees that work like the main checkout.

    python3 -I tools/worktree.py add PATH BRANCH [--base main]
    python3 -I tools/worktree.py list
    python3 -I tools/worktree.py stale [--json]
    python3 -I tools/worktree.py prune [--yes] [--remote]

A new worktree has no tools/node_modules, tests/compare/.cache or
reference/ (all git-ignored). `add` makes the branch from BASE and links
those three to the main checkout's, so validate.py, the offline tests and
compare.mjs run there at once. `list` shows each worktree with its branch
and whether that branch is merged into origin/main.

`stale` lists every branch left over: worktrees, local branches and (after a
fetch) branches on GitHub that no open pull request uses, with why each is
there. It may be removed when nothing on it is missing from origin/main:
its pull request is merged; or it is older than a day and its tip is in
origin/main, every file it changed reads the same on origin/main (squashed
in by another pull request), or a release tag holds its tip (a release
branch). Anything else is kept and listed as "unique". `prune` removes what
may be removed: worktrees without uncommitted changes with their branches,
local branches, and with --remote the branches on GitHub (asks first unless
--yes). The main checkout and main are never touched; a detached worktree or
a worktree branch with no commits of its own is only listed. Without gh
nothing is removed.
macOS and Linux get symbolic links; Windows gets directory junctions.
"""
import argparse
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHARED = [os.path.join("tools", "node_modules"), os.path.join("tests", "compare", ".cache")]
REMOTE = "origin"
MAIN = "main"
KEEP = {MAIN, "gh-pages"}
DAY = 24 * 3600


def git(*args, cwd=None, check=True):
    done = subprocess.run(["git"] + list(args), cwd=cwd or ROOT, capture_output=True, text=True)
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


def gh_json(args):
    """Parsed output of `gh ARGS --json ...`, or None when gh is missing or fails."""
    try:
        done = subprocess.run(["gh"] + args, cwd=ROOT, capture_output=True, text=True)
    except FileNotFoundError:
        return None
    if done.returncode != 0:
        return None
    try:
        return json.loads(done.stdout or "[]")
    except ValueError:
        return None


def merged_heads():
    """{(branch, last commit)} of merged pull requests, or None without gh."""
    prs = gh_json(["pr", "list", "--state", "merged", "--limit", "500", "--json", "headRefName,headRefOid"])
    return None if prs is None else {(p["headRefName"], p["headRefOid"]) for p in prs}


def open_pr_branches():
    """Branches an open pull request comes from or goes into, or None without gh."""
    prs = gh_json(["pr", "list", "--state", "open", "--limit", "500", "--json", "headRefName,baseRefName"])
    return None if prs is None else {p["headRefName"] for p in prs} | {p["baseRefName"] for p in prs}


def merged_branches():
    """Local branches whose pull request is merged. The repository only squash-merges,
    so git itself never sees a branch as merged (and a branch just made from
    main, with no commits of its own, would look merged to `git branch
    --merged`). A branch name can come back for new work, so the branch's tip
    must be the merged PR's last commit. Needs gh; without it nothing counts."""
    heads = merged_heads() or set()
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


def is_ancestor(ref, of):
    return subprocess.run(["git", "merge-base", "--is-ancestor", ref, of], cwd=ROOT,
                          capture_output=True).returncode == 0


def in_main(ref, main):
    """Why nothing on REF is missing from MAIN, or None: "in-main" (its tip is in
    main, or it changed nothing), "squashed" (every file it changed reads the same
    on main), "tagged" (a release tag holds its tip)."""
    if is_ancestor(ref, main):
        return "in-main"
    base = git("merge-base", main, ref, check=False).strip()
    if base:
        changed = set(git("diff", "--no-renames", "--name-only", base, ref).splitlines())
        differ = set(git("diff", "--no-renames", "--name-only", main, ref).splitlines())
        if not changed & differ:
            return "squashed"
    if git("tag", "--list", "v*", "--contains", ref, check=False).strip():
        return "tagged"
    return None


def born(ref):
    """When this clone first saw REF (its oldest reflog entry), 0 when unknown."""
    if not ref.startswith("refs/"):
        return 0
    lines = git("reflog", "show", "--date=unix", "--format=%gd", ref, check=False).split()
    try:
        return int(lines[-1].rsplit("@{", 1)[1].rstrip("}"))
    except (IndexError, ValueError):
        return 0


def stale_branches(remote=True, now=None):
    """[{branch, where: worktree|local|remote, path, reason, removable, last, subject}],
    every branch left over, in a fixed order. Branches an open PR uses are in
    progress and not listed; so are unmerged ones younger than a day."""
    now = time.time() if now is None else now
    merged, busy = merged_heads(), open_pr_branches()
    gh = merged is not None and busy is not None
    trees = worktrees()
    main_checkout = trees[0][1]
    main = "refs/remotes/%s/%s" % (REMOTE, MAIN)
    if not git("rev-parse", "--verify", "-q", main, check=False).strip():
        main = "refs/heads/" + MAIN
    out = []

    def entry(name, where, ref, path=None, dirty=False, own_commits=True):
        tip = git("rev-parse", ref).strip()
        when, subject = git("log", "-1", "--format=%ct%x00%s", ref).rstrip("\n").split("\x00", 1)
        row = {"branch": name, "where": where, "path": path, "reason": "", "removable": False,
               "last": time.strftime("%Y-%m-%d", time.localtime(int(when))), "subject": subject}
        recent = now - max(int(when), born(ref)) < DAY
        if not gh:
            row["reason"] = "no-gh"
        elif name and name in busy:
            return
        elif name and (name, tip) in merged:
            row.update(reason="merged", removable=True)
        elif recent:
            return
        elif dirty:
            row["reason"] = "uncommitted"
        else:
            why = in_main(ref, main)
            if why and not own_commits:
                row["reason"] = "detached" if not name else "no-commits"
            else:
                row.update(reason=why or "unique", removable=bool(why) and name is not None)
        out.append(row)

    in_trees = set()
    for path, branch in trees[1:]:
        dirty = git("status", "--porcelain", "--untracked-files=no", cwd=path, check=False).strip() != ""
        if branch:
            in_trees.add(branch)
            own = not is_ancestor("refs/heads/" + branch, main)
            entry(branch, "worktree", "refs/heads/" + branch, path, dirty, own)
        else:
            entry(None, "worktree", git("rev-parse", "HEAD", cwd=path).strip(), path, dirty, False)
    for name in sorted(git("for-each-ref", "--format=%(refname:short)", "refs/heads/").split()):
        if name not in KEEP and name != main_checkout and name not in in_trees:
            entry(name, "local", "refs/heads/" + name)
    if remote:
        prefix = REMOTE + "/"
        for short in sorted(git("for-each-ref", "--format=%(refname:short)", "refs/remotes/" + REMOTE).split()):
            name = short[len(prefix):] if short.startswith(prefix) else ""
            if name and name != "HEAD" and name not in KEEP:
                entry(name, "remote", "refs/remotes/" + short)
    return out


REASONS = {"merged": "its pull request is merged", "in-main": "its tip is in main",
           "squashed": "every file it changed reads the same on main", "tagged": "a release tag holds it",
           "unique": "has changes main does not have", "uncommitted": "uncommitted changes",
           "detached": "detached worktree", "no-commits": "worktree with no commits of its own",
           "no-gh": "gh unavailable, cannot tell"}


def fetch():
    git("fetch", "--prune", "--quiet", REMOTE, check=False)


def stale(args):
    fetch()
    rows = stale_branches()
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
        return 0
    for r in rows:
        print("%-8s %-28s %-10s %s  %s%s" % (r["where"], r["branch"] or r["path"], r["reason"], r["last"],
                                           REASONS.get(r["reason"], ""), "  -> prune removes it" if r["removable"] else ""))
    print("%d left over, %d removable" % (len(rows), sum(r["removable"] for r in rows)))
    return 0


def prune(args):
    if args.remote:
        fetch()
    gone, kept = [], []
    for r in stale_branches(remote=args.remote):
        label = "%s %s" % (r["where"], r["branch"] or r["path"])
        if not r["removable"]:
            kept.append("%s (%s)" % (label, r["reason"]))
            continue
        if not args.yes and input("remove %s (%s)? [y/N] " % (label, REASONS[r["reason"]])).strip().lower() != "y":
            continue
        if r["where"] == "worktree":
            git("worktree", "remove", "--force", r["path"])
            git("branch", "-D", r["branch"], check=False)
        elif r["where"] == "local":
            git("branch", "-D", r["branch"])
        else:
            git("push", REMOTE, "--delete", r["branch"])
        gone.append(label)
    git("worktree", "prune", check=False)
    print("removed: %s" % (", ".join(gone) or "nothing"))
    if kept:
        print("kept: %s" % ", ".join(kept))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("path")
    a.add_argument("branch")
    a.add_argument("--base", default="main")
    sub.add_parser("list")
    st = sub.add_parser("stale")
    st.add_argument("--json", action="store_true")
    p = sub.add_parser("prune")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--remote", action="store_true", help="also delete left-over branches on GitHub")
    args = ap.parse_args()
    return {"add": add, "list": listing, "stale": stale, "prune": prune}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
