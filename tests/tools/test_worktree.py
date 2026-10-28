"""Offline tests of tools/worktree.py's search for left-over branches, on throwaway git repositories.

    python3 -I -m unittest discover -s tests/tools -v
"""
import argparse
import io
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import worktree as wt  # noqa: E402

LATER = 3 * wt.DAY  # "now" this far ahead makes every branch old enough


def run(cwd, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@example.invalid", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run(["git"] + list(args), cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout


class LeftOver(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.origin = os.path.join(self.tmp, "origin.git")
        self.repo = os.path.join(self.tmp, "repo")
        run(self.tmp, "init", "-q", "--bare", "-b", "main", self.origin)
        run(self.tmp, "clone", "-q", self.origin, self.repo)
        run(self.repo, "checkout", "-q", "-b", "main")
        self.commit("a.txt", "one")
        run(self.repo, "push", "-q", "-u", "origin", "main")
        self.saved = (wt.ROOT, wt.merged_heads, wt.open_pr_branches)
        wt.ROOT = self.repo
        self.merged, self.busy = set(), set()
        wt.merged_heads = lambda: self.merged
        wt.open_pr_branches = lambda: self.busy

    def tearDown(self):
        wt.ROOT, wt.merged_heads, wt.open_pr_branches = self.saved
        shutil.rmtree(self.tmp, ignore_errors=True)

    def commit(self, name, text, cwd=None):
        cwd = cwd or self.repo
        with open(os.path.join(cwd, name), "w") as fh:
            fh.write(text)
        run(cwd, "add", name)
        run(cwd, "commit", "-q", "-m", "write " + name)
        return run(cwd, "rev-parse", "HEAD").strip()

    def branch_with(self, branch, name, text, push=True):
        run(self.repo, "checkout", "-q", "-b", branch, "main")
        tip = self.commit(name, text)
        if push:
            run(self.repo, "push", "-q", "origin", branch)
        run(self.repo, "checkout", "-q", "main")
        return tip

    def rows(self, later=LATER, remote=True):
        run(self.repo, "fetch", "-q", "--prune", "origin")
        return {(r["where"], r["branch"]): r for r in wt.stale_branches(remote=remote, now=time.time() + later)}

    def test_branch_with_nothing_of_its_own_may_go(self):
        run(self.repo, "branch", "old")
        row = self.rows()[("local", "old")]
        self.assertEqual((row["reason"], row["removable"]), ("in-main", True))

    def test_squashed_into_main_by_another_pull_request(self):
        self.branch_with("research", "note.md", "findings")
        self.commit("other.md", "main moved on")
        self.commit("note.md", "findings")
        run(self.repo, "push", "-q", "origin", "main")
        rows = self.rows()
        self.assertEqual((rows[("remote", "research")]["reason"], rows[("remote", "research")]["removable"]), ("squashed", True))
        self.assertEqual(rows[("local", "research")]["reason"], "squashed")

    def test_changes_main_lacks_are_kept(self):
        self.branch_with("idea", "idea.md", "draft")
        self.commit("idea.md", "other text")
        row = self.rows()[("remote", "idea")]
        self.assertEqual((row["reason"], row["removable"]), ("unique", False))

    def test_release_branch_held_by_a_tag(self):
        self.branch_with("release/1.0", "notes.txt", "v1.0.1")
        run(self.repo, "tag", "v1.0.1", "release/1.0")
        self.commit("notes.txt", "later notes")
        row = self.rows()[("remote", "release/1.0")]
        self.assertEqual((row["reason"], row["removable"]), ("tagged", True))

    def test_open_pull_request_branches_are_in_progress(self):
        self.branch_with("feature", "f.txt", "x")
        self.branch_with("release/2.0", "r.txt", "y")
        self.busy = {"feature", "main", "release/2.0"}  # release/2.0 is the base of an open PR
        rows = self.rows()
        self.assertNotIn(("remote", "feature"), rows)
        self.assertNotIn(("remote", "release/2.0"), rows)

    def test_merged_pull_request_goes_at_once(self):
        tip = self.branch_with("fix", "fix.txt", "x")
        self.merged = {("fix", tip)}
        row = self.rows(later=0)[("remote", "fix")]
        self.assertEqual((row["reason"], row["removable"]), ("merged", True))

    def test_a_reused_branch_name_is_not_taken_for_merged(self):
        old = self.branch_with("fix", "fix.txt", "x")
        self.merged = {("fix", old)}
        run(self.repo, "checkout", "-q", "fix")
        self.commit("fix.txt", "more")
        run(self.repo, "push", "-q", "origin", "fix")
        run(self.repo, "checkout", "-q", "main")
        self.assertEqual(self.rows()[("remote", "fix")]["reason"], "unique")

    def test_recent_unmerged_branches_are_not_listed(self):
        self.branch_with("today", "t.txt", "x")
        rows = self.rows(later=0)
        self.assertNotIn(("remote", "today"), rows)
        self.assertNotIn(("local", "today"), rows)

    def test_without_gh_nothing_is_removable(self):
        run(self.repo, "branch", "old")
        wt.merged_heads = lambda: None
        row = self.rows()[("local", "old")]
        self.assertEqual((row["reason"], row["removable"]), ("no-gh", False))

    def test_worktrees_without_own_commits_or_with_changes_are_only_listed(self):
        empty = os.path.join(self.tmp, "empty")
        run(self.repo, "worktree", "add", "-q", "-b", "empty", empty, "main")
        busy = os.path.join(self.tmp, "busy")
        run(self.repo, "worktree", "add", "-q", "-b", "busy", busy, "main")
        self.commit("b.txt", "x", cwd=busy)
        with open(os.path.join(busy, "b.txt"), "w") as fh:
            fh.write("edited")
        detached = os.path.join(self.tmp, "detached")
        run(self.repo, "worktree", "add", "-q", "--detach", detached, "main")
        rows = self.rows()
        self.assertEqual((rows[("worktree", "empty")]["reason"], rows[("worktree", "empty")]["removable"]), ("no-commits", False))
        self.assertEqual((rows[("worktree", "busy")]["reason"], rows[("worktree", "busy")]["removable"]), ("uncommitted", False))
        self.assertEqual((rows[("worktree", None)]["reason"], rows[("worktree", None)]["removable"]), ("detached", False))

    def test_prune_deletes_on_github_only_with_remote(self):
        self.branch_with("research", "note.md", "findings")
        self.branch_with("idea", "idea.md", "draft")
        self.commit("other.md", "main moved on")
        self.commit("note.md", "findings")
        run(self.repo, "push", "-q", "origin", "main")
        real = wt.stale_branches
        wt.stale_branches = lambda remote=True, now=None: real(remote=remote, now=time.time() + LATER)
        try:
            with redirect_stdout(io.StringIO()):
                wt.prune(argparse.Namespace(yes=True, remote=False))
            self.assertIn("research", run(self.origin, "branch"))
            self.assertNotIn("research", run(self.repo, "branch"))
            with redirect_stdout(io.StringIO()):
                wt.prune(argparse.Namespace(yes=True, remote=True))
        finally:
            wt.stale_branches = real
        heads = run(self.origin, "branch")
        self.assertNotIn("research", heads)
        self.assertIn("idea", heads)
        self.assertIn("main", heads)


if __name__ == "__main__":
    unittest.main()
