#!/usr/bin/env python3
"""pr_wait - one background wait for a batch of pull requests.

    python3 -I tools/pr_wait.py 207 208 [--codex 209 210] [--every 60] [--codex-timeout 1800]

Exits only when every PR is merged, or when one needs someone: never on an
intermediate step (a check finishing, a review arriving). Needs action:
  - a failed CI check (failure, cancelled, timed out, ...) on the PR's head commit;
  - a merge conflict that is not only lines added on both sides (see below);
  - Codex findings that are not resolved yet (`codex_review.py findings N` lists them);
  - a PR closed without merging;
  - a PR still open with auto-merge off and nothing else pending (CI done, no
    Codex review to wait for): nobody would merge it.
PRs after --codex were sent to Codex (`codex_review.py request N`) and opened
without auto-merge. For them the wait reads Codex's verdict as `codex_review.py
wait` does; when the review is clean, or did not happen (no finished review
within --codex-timeout seconds, or Codex reports it failed), it turns on
auto-merge (`gh pr merge N --auto --squash`) and goes on waiting. In the
not-reviewed case it also says so on the PR (docs/maintaining.md, "Codex 审查")
and records that comment as ours (`watch_issues.py --mine`).

A merge conflict where, in every conflicting block, both main and the branch
only added lines (no line of the common base changed or removed; typically
CHANGELOG.md or a text XML) is resolved here and the wait goes on: origin/main
is merged into the branch in a temporary detached worktree, each such block
keeps main's new lines first and the branch's after, and the merge commit is
pushed (a plain push, never forced). It is not tried, and the conflict is an
exit as before, when the PR comes from a fork, when the branch is checked out
in a local worktree that has uncommitted changes or a commit other than the
PR's head (a session may be working there), or when any conflict is of another
kind. A clean local worktree of the branch is fast-forwarded to the pushed
merge. `git stash` is never used (docs/maintaining.md, "共用资源").

Network and gh errors are retried, never an exit. At the end it prints one
line per PR. Exit 0: all merged; 1: something needs action; 2: a PR number
GitHub does not know. Run it in the background: its end is the signal.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import codex_review as cr  # noqa: E402

ROOT = cr.ROOT
FIELDS = ("state,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup,headRefOid,commits,"
          "headRefName,isCrossRepository")
FAILED = ("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR")
NOT_REVIEWED = ("Codex 没审成（%s），按 docs/maintaining.md“Codex 审查”开了自动合并。"
                "\n\nCodex was not able to review this PR (%s); auto-merge is on.")


def checks(pr):
    """(failed check names, any still running) for the head commit, latest run of each check."""
    latest = {}
    for c in pr.get("statusCheckRollup") or []:
        name = c.get("name") or c.get("context") or "?"
        when = c.get("startedAt") or c.get("createdAt") or ""
        if name not in latest or when >= latest[name][0]:
            latest[name] = (when, c)
    failed, running = [], False
    for name in sorted(latest):
        c = latest[name][1]
        if c.get("__typename") == "StatusContext":
            state = c.get("state") or ""
            if state in FAILED:
                failed.append(name)
            elif state in ("PENDING", "EXPECTED", ""):
                running = True
        elif (c.get("status") or "") != "COMPLETED":
            running = True
        elif (c.get("conclusion") or "") in FAILED:
            failed.append(name)
    return failed, running


def git(repo, *args, check=True):
    done = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)
    if check and done.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args[:2]), (done.stderr or done.stdout).strip()[:300]))
    return done


def resolve_added(text):
    """text with diff3 conflict blocks -> resolved text, or None unless every block only adds lines.

    "Only adds" means the block's base part is empty: both sides inserted lines at the
    same place and changed nothing that was there. During `git merge origin/main` on the
    branch, ours is the branch and theirs is main; main's lines come first."""
    out, part, ours, base, theirs, blocks = [], None, [], [], [], 0
    for line in text.splitlines(True):
        bare = line.rstrip("\r\n")
        if part is None:
            if bare.startswith("<<<<<<< ") or bare == "<<<<<<<":
                part, ours, base, theirs = "ours", [], [], []
            else:
                out.append(line)
        elif bare.startswith("||||||| ") or bare == "|||||||":
            if part != "ours":
                return None
            part = "base"
        elif bare == "=======":
            if part != "base":
                return None  # no base part: not diff3 output, cannot tell
            part = "theirs"
        elif bare.startswith(">>>>>>> ") or bare == ">>>>>>>":
            if part != "theirs" or base:
                return None
            out.extend(theirs + ours)
            blocks += 1
            part = None
        elif bare.startswith("<<<<<<<"):
            return None
        else:
            {"ours": ours, "base": base, "theirs": theirs}[part].append(line)
    return "".join(out) if part is None and blocks else None


def branch_worktree(repo, branch):
    """Path of the worktree that has branch checked out, or None."""
    path = None
    for line in git(repo, "worktree", "list", "--porcelain").stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line == "branch refs/heads/" + branch:
            return path
    return None


def merge_main(repo, branch, head, remote="origin", base="main"):
    """Merge remote/base into branch when every conflict only adds lines; push. (done, text)."""
    own = branch_worktree(repo, branch)
    if own:
        if git(own, "status", "--porcelain", "--untracked-files=no").stdout.strip():
            return False, "local worktree %s has uncommitted changes" % own
        if git(own, "rev-parse", "HEAD").stdout.strip() != head:
            return False, "local worktree %s is not at the PR's head" % own
    git(repo, "fetch", "-q", remote, base, branch)
    if git(repo, "rev-parse", "%s/%s" % (remote, branch)).stdout.strip() != head:
        return False, "the branch moved while reading it"
    tmp = tempfile.mkdtemp(prefix="pr_wait-")
    work = os.path.join(tmp, "wt")
    try:
        git(repo, "worktree", "add", "-q", "--detach", work, head)
        merged = git(work, "-c", "merge.conflictStyle=diff3", "merge", "--no-ff", "--no-edit",
                     "%s/%s" % (remote, base), check=False)
        if merged.returncode == 0:
            return False, "no conflict with %s/%s here" % (remote, base)
        stages = {}
        for line in git(work, "ls-files", "-u", "-z").stdout.split("\0"):
            if line:
                meta, name = line.split("\t", 1)
                stages.setdefault(name, set()).add(meta.split()[2])
        if not stages:
            return False, "merge failed: %s" % (merged.stderr or merged.stdout).strip()[:200]
        for name in sorted(stages):
            if stages[name] != {"1", "2", "3"}:
                return False, "%s: not a change on both sides of one file" % name
            path = os.path.join(work, name)
            try:
                with open(path, encoding="utf-8", newline="") as f:
                    text = f.read()
            except (UnicodeDecodeError, OSError):
                return False, "%s: not a text file" % name
            fixed = resolve_added(text)
            if fixed is None:
                return False, "%s: a conflict changes existing lines" % name
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(fixed)
            git(work, "add", "--", name)
        git(work, "commit", "-q", "--no-edit", "-m",
            "Merge %s/%s into %s\n\nBoth sides only added lines in %s; pr_wait.py kept both, %s's first."
            % (remote, base, branch, ", ".join(sorted(stages)), base))
        new = git(work, "rev-parse", "HEAD").stdout.strip()
        git(work, "push", "-q", remote, "HEAD:refs/heads/" + branch)
    finally:
        git(repo, "worktree", "remove", "--force", work, check=False)
        shutil.rmtree(tmp, ignore_errors=True)
        git(repo, "worktree", "prune", check=False)
    if own:
        git(own, "merge", "-q", "--ff-only", new, check=False)
    git(repo, "fetch", "-q", remote, branch, check=False)
    return True, "merged %s/%s into %s (both sides only added lines in %s)" % (
        remote, base, branch, ", ".join(sorted(stages)))


def record_mine(url):
    # the issue watch would otherwise report our own comment as new
    subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tools", "watch_issues.py"), "--mine", url], cwd=ROOT)


class Codex:
    """Where the Codex review of one PR stands."""

    def __init__(self):
        self.head = None      # the head commit being reviewed
        self.since = None
        self.started = None   # when this wait began on that head
        self.verdict = None   # None (waiting), "clean", "not reviewed: ...", "findings"
        self.commented = False
        self.logged = None    # the verdict last written to the trial table
        self.merge_on = False


def log_once(number, st, outcome):
    """Write the trial-table row (codex_review.log_review) once per outcome and head commit."""
    key = (st.head, outcome)
    if st.logged != key:
        st.logged = key
        print(cr.log_review(number, outcome), file=sys.stderr, flush=True)


def step_codex(number, pr, st, now, timeout):
    """Advance PR number's Codex state; return a needs-action text or None."""
    head, since = cr.head_since(pr)
    if head != st.head and not st.merge_on:  # a new push before auto-merge: wait for its review
        st.head, st.since, st.started, st.verdict = head, since, now, None
    if st.verdict is None:
        v = cr.fetch_verdict(number, st.head, st.since)
        if v == "findings":
            items = cr.findings(number)
            if items:
                log_once(number, st, "findings")
                return "%d unresolved Codex finding(s) (codex_review.py findings %d)" % (len(items), number)
            v = "clean"  # all answered already
        if v == "clean":
            st.verdict = "clean"
        elif v == "failed":
            st.verdict = "not reviewed: Codex 报审查失败 / Codex reported a failed review"
        elif now - st.started >= timeout:
            st.verdict = "not reviewed: %d 分钟内没审完 / no finished review within %d min" % (
                timeout // 60, timeout // 60)
    if st.verdict == "clean":
        log_once(number, st, "clean")
    elif st.verdict:
        log_once(number, st, "failed" if "失败" in st.verdict else "timeout")
    if st.verdict and st.verdict.startswith("not reviewed") and not st.commented:
        why = st.verdict[len("not reviewed: "):].split(" / ")
        url = cr.gh("pr", "comment", str(number), "--body", NOT_REVIEWED % (why[0], why[-1])).strip()
        st.commented = True
        if url:
            record_mine(url)
    if st.verdict and not st.merge_on and not pr.get("autoMergeRequest"):
        try:
            cr.gh("pr", "merge", str(number), "--auto", "--squash")
        except RuntimeError as problem:
            if "clean status" not in str(problem):
                raise
            cr.gh("pr", "merge", str(number), "--squash")  # checks already passed: nothing to wait for
        st.merge_on = True
    elif st.verdict:
        st.merge_on = True
    return None


def conflict(number, pr, tried):
    """Try merge_main once per head commit; ('waiting' | 'action', text)."""
    head = pr.get("headRefOid")
    if pr.get("isCrossRepository"):
        return "action", "merge conflict (PR from a fork)"
    if not pr.get("headRefName"):
        return "action", "merge conflict"
    if tried.get(number) == head:  # pushed the merge; GitHub still shows the old head
        return "waiting", "merged main, GitHub catching up"
    tried[number] = head
    try:
        done, text = merge_main(ROOT, pr["headRefName"], head)
    except RuntimeError as problem:
        done, text = False, str(problem)
    print("#%d: %s" % (number, text), file=sys.stderr, flush=True)
    if done:
        return "waiting", text
    tried.pop(number)
    return "action", "merge conflict (%s)" % text


def assess(number, pr, codex, now, timeout, tried=None):
    """('merged' | 'action' | 'waiting', short text) for one PR; may turn on auto-merge for --codex PRs,
    and may merge main into the branch when a conflict only adds lines (tried: PR -> head tried)."""
    state = pr.get("state")
    if state == "MERGED":
        return "merged", "merged"
    if state == "CLOSED":
        return "action", "closed without merging"
    failed, running = checks(pr)
    if failed:
        return "action", "CI failed: %s" % ", ".join(failed)
    if pr.get("mergeable") == "CONFLICTING" or pr.get("mergeStateStatus") == "DIRTY":
        return conflict(number, pr, {} if tried is None else tried)
    if codex is not None:
        problem = step_codex(number, pr, codex, now, timeout)
        if problem:
            return "action", problem
        if codex.verdict is None:
            return "waiting", "Codex reviewing" + (", CI running" if running else "")
        if codex.verdict != "clean":
            note = "Codex " + codex.verdict.split(" / ")[-1]
        else:
            note = "Codex clean"
        return "waiting", "%s, auto-merge on%s" % (note, ", CI running" if running else "")
    if running:
        return "waiting", "CI running" + ("" if pr.get("autoMergeRequest") else ", auto-merge off")
    if not pr.get("autoMergeRequest"):
        return "action", "open, CI passed, auto-merge off"
    return "waiting", "auto-merge on, merging"


def watch(numbers, codex_numbers, every, timeout):
    order = sorted(set(numbers) | set(codex_numbers))
    codex = {n: Codex() for n in codex_numbers}
    last = {n: ("waiting", "not read yet") for n in order}
    tried = {}  # PR -> head commit a merge of main was tried on
    while True:
        now = time.time()
        for n in order:
            if last[n][0] == "merged":
                continue
            try:
                pr = cr.ghjson("pr", "view", str(n), "--json", FIELDS)
                last[n] = assess(n, pr, codex.get(n), now, timeout, tried)
            except (RuntimeError, ValueError, KeyError, TypeError) as problem:
                text = str(problem)
                if "Could not resolve to a PullRequest" in text or "no pull requests found" in text:
                    print("#%d: %s" % (n, text.splitlines()[0]))
                    return 2
                print("gh (retrying): %s" % text.splitlines()[0][:200] if text else "gh failed",
                      file=sys.stderr, flush=True)
        kinds = [last[n][0] for n in order]
        if "action" in kinds or all(k == "merged" for k in kinds):
            for n in order:
                print("#%d %s: %s" % (n, "needs action" if last[n][0] == "action" else last[n][0], last[n][1])
                      if last[n][0] != "merged" else "#%d merged" % n)
            return 1 if "action" in kinds else 0
        time.sleep(every)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("numbers", type=int, nargs="*", help="PRs to wait for")
    ap.add_argument("--codex", type=int, nargs="+", default=[], help="PRs waiting for a Codex review (also waited for)")
    ap.add_argument("--every", type=float, default=60, help="seconds between checks (default 60)")
    ap.add_argument("--codex-timeout", type=int, default=1800,
                    help="seconds without a finished Codex review before auto-merge goes on anyway (default 1800)")
    args = ap.parse_args()
    if not args.numbers and not args.codex:
        ap.error("give at least one PR number")
    return watch(args.numbers, args.codex, args.every, args.codex_timeout)


if __name__ == "__main__":
    sys.exit(main())
