"""Offline tests of tools/pr_wait.py with gh replaced: when the one wait for a batch of PRs ends.

    python3 -I -m unittest discover -s tests/tools -v
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import codex_review as cr  # noqa: E402
import pr_wait  # noqa: E402

HEAD = "a" * 40
WHEN = "2026-11-02T15:00:00Z"
AUTO = {"mergeMethod": "SQUASH"}


def check(name, status="COMPLETED", conclusion="SUCCESS", started="2026-11-02T15:01:00Z"):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion, "startedAt": started}


RUNNING = [check("offline (ubuntu-latest)", "IN_PROGRESS", ""), check("offline (windows-latest)", "IN_PROGRESS", "")]
PASSED = [check("offline (ubuntu-latest)"), check("offline (windows-latest)")]


def pr(state="OPEN", rollup=None, auto=AUTO, mergeable="MERGEABLE", head=HEAD):
    return {"state": state, "mergeable": mergeable, "mergeStateStatus": "BLOCKED", "autoMergeRequest": auto,
            "statusCheckRollup": RUNNING if rollup is None else rollup, "headRefOid": head,
            "commits": [{"committedDate": WHEN}]}


def codex_summary(status, unresolved=False):
    state = {"code_review": {"commit_sha": HEAD, "status": status, "has_unresolved_findings": unresolved}}
    return {"user": {"login": cr.BOT}, "body": "<!-- codex-review-state:v1 %s -->" % json.dumps(state)}


class Fake:
    """gh with scripted answers: each PR's `pr view` goes through its list, then repeats the last one."""

    def __init__(self, test, views, comments=None, threads=None, errors=0):
        self.views = {n: list(v) for n, v in views.items()}
        self.comments = comments or {}  # PR -> issue comments (Codex's summary)
        self.threads = threads or []
        self.errors = errors  # this many `pr view` calls fail like a dropped connection first
        self.calls, self.sleeps, self.mine = [], 0, []
        for mod, name, value in ((cr, "gh", self.gh), (pr_wait.time, "sleep", self.sleep),
                                 (pr_wait, "record_mine", self.mine.append)):
            test.addCleanup(setattr, mod, name, getattr(mod, name))
            setattr(mod, name, value)
        self.clock = 1000.0
        test.addCleanup(setattr, pr_wait.time, "time", pr_wait.time.time)
        pr_wait.time.time = lambda: self.clock

    def sleep(self, seconds):
        self.sleeps += 1
        self.clock += seconds
        if self.sleeps > 100:
            raise AssertionError("the wait never ended")

    def gh(self, *args, data=None):
        self.calls.append(args)
        if args[:2] == ("pr", "view"):
            if self.errors:
                self.errors -= 1
                raise RuntimeError("Post \"https://api.github.com/graphql\": unexpected EOF")
            seq = self.views[int(args[2])]
            return json.dumps(seq.pop(0) if len(seq) > 1 else seq[0])
        if args[:2] in (("pr", "merge"), ("pr", "comment")):
            return "https://github.com/o/r/pull/%s#issuecomment-1\n" % args[2]
        if args[0] == "api" and args[1] == "graphql":
            nodes = [{"id": "T1", "isResolved": False, "path": "x.lua", "line": 3,
                      "comments": {"nodes": [{"author": {"login": "chatgpt-codex-connector"}, "url": "u", "body": t}]}}
                     for t in self.threads]
            return json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": nodes}}}}})
        if args[:2] == ("repo", "view"):
            return json.dumps({"owner": {"login": "o"}, "name": "r"})
        if args[0] == "api":
            path = args[-1]
            number = int(path.split("/")[-2])
            if "/comments" in path:
                return json.dumps(self.comments.get(number, []))
            return "[]"
        raise AssertionError("unexpected gh call %r" % (args,))

    def merges(self):
        return [a for a in self.calls if a[:2] == ("pr", "merge")]

    def comments_posted(self):
        return [a for a in self.calls if a[:2] == ("pr", "comment")]


class Exits(unittest.TestCase):
    def test_failed_ci_on_an_open_pr_ends_the_wait(self):
        # 2026-11-02: PR #207's CI failed at 23:07 while its wait looped on `state != OPEN`; nobody
        # noticed for 1.5 hours. A wait that only looks at the state never ends here.
        failed = [check("offline (ubuntu-latest)", conclusion="FAILURE"), check("offline (windows-latest)")]
        fake = Fake(self, {207: [pr(), pr(), pr(rollup=failed)]})
        self.assertEqual(pr_wait.watch([207], [], 60, 1800), 1)
        self.assertEqual(fake.sleeps, 2)

    def test_does_not_end_on_intermediate_steps(self):
        fake = Fake(self, {1: [pr(), pr(rollup=PASSED), pr(rollup=PASSED), pr("MERGED", PASSED)],
                           2: [pr(), pr(), pr(), pr(), pr(rollup=PASSED), pr("MERGED", PASSED)]})
        self.assertEqual(pr_wait.watch([1, 2], [], 60, 1800), 0)
        self.assertEqual(fake.sleeps, 5)

    def test_merge_conflict_needs_action(self):
        Fake(self, {3: [pr(), pr(mergeable="CONFLICTING")]})
        self.assertEqual(pr_wait.watch([3], [], 60, 1800), 1)

    def test_open_with_auto_merge_off_needs_action_once_ci_is_done(self):
        fake = Fake(self, {4: [pr(auto=None), pr(auto=None), pr(rollup=PASSED, auto=None)]})
        self.assertEqual(pr_wait.watch([4], [], 60, 1800), 1)
        self.assertEqual(fake.sleeps, 2)
        self.assertEqual(fake.merges(), [])  # not a --codex PR: not ours to merge

    def test_closed_without_merging_needs_action(self):
        Fake(self, {5: [pr("CLOSED")]})
        self.assertEqual(pr_wait.watch([5], [], 60, 1800), 1)

    def test_a_rerun_check_counts_by_its_latest_run(self):
        rerun = [check("offline (ubuntu-latest)", conclusion="FAILURE", started="2026-11-02T15:01:00Z"),
                 check("offline (ubuntu-latest)", "IN_PROGRESS", "", started="2026-11-02T15:30:00Z")]
        self.assertEqual(pr_wait.checks({"statusCheckRollup": rerun}), ([], True))

    def test_network_errors_are_retried(self):
        fake = Fake(self, {6: [pr(), pr("MERGED", PASSED)]}, errors=3)
        self.assertEqual(pr_wait.watch([6], [], 60, 1800), 0)
        self.assertGreaterEqual(fake.sleeps, 3)

    def test_unknown_pr_stops(self):
        fake = Fake(self, {7: [pr()]})
        fake.views = {}

        def missing(*args, data=None):
            raise RuntimeError("GraphQL: Could not resolve to a PullRequest with the number of 7.")
        cr.gh = missing
        self.assertEqual(pr_wait.watch([7], [], 60, 1800), 2)


class CodexReview(unittest.TestCase):
    def test_clean_review_turns_on_auto_merge_and_waits_on(self):
        views = [pr(auto=None), pr(auto=None), pr(auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {8: views}, comments={8: []})
        fake.comments_after = None
        # the summary shows up after the first check
        orig = fake.gh

        def gh(*args, data=None):
            if fake.sleeps >= 1:
                fake.comments[8] = [codex_summary("completed", False)]
            return orig(*args, data=data)
        cr.gh = gh
        self.assertEqual(pr_wait.watch([], [8], 60, 1800), 0)
        self.assertEqual(fake.merges(), [("pr", "merge", "8", "--auto", "--squash")])
        self.assertEqual(fake.comments_posted(), [])

    def test_failed_review_turns_on_auto_merge_and_says_so_once(self):
        views = [pr(auto=None), pr(auto=AUTO), pr(auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {9: views}, comments={9: [codex_summary("failed", True)]})
        self.assertEqual(pr_wait.watch([], [9], 60, 1800), 0)
        self.assertEqual(len(fake.merges()), 1)
        self.assertEqual(len(fake.comments_posted()), 1)
        self.assertEqual(len(fake.mine), 1)

    def test_no_review_in_time_turns_on_auto_merge(self):
        views = [pr(auto=None)] * 40 + [pr(auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {10: views}, comments={10: []})
        self.assertEqual(pr_wait.watch([], [10], 60, 1800), 0)
        self.assertEqual(len(fake.merges()), 1)
        self.assertIn("30", fake.comments_posted()[0][4])
        # not before the 30 minutes were up
        first = next(i for i, a in enumerate(fake.calls) if a[:2] == ("pr", "merge"))
        views_before = sum(1 for a in fake.calls[:first] if a[:2] == ("pr", "view"))
        self.assertGreaterEqual(views_before, 31)

    def test_unresolved_findings_need_action(self):
        fake = Fake(self, {11: [pr(auto=None)]}, comments={11: [codex_summary("completed", True)]},
                    threads=["P1: this breaks"])
        self.assertEqual(pr_wait.watch([], [11], 60, 1800), 1)
        self.assertEqual(fake.merges(), [])

    def test_findings_all_resolved_count_as_clean(self):
        fake = Fake(self, {12: [pr(auto=None), pr("MERGED", PASSED)]},
                    comments={12: [codex_summary("completed", True)]}, threads=[])
        self.assertEqual(pr_wait.watch([], [12], 60, 1800), 0)
        self.assertEqual(len(fake.merges()), 1)

    def test_waiting_for_codex_with_auto_merge_off_is_not_an_action(self):
        fake = Fake(self, {13: [pr(rollup=PASSED, auto=None)] * 3 + [pr(rollup=PASSED, auto=AUTO), pr("MERGED", PASSED)]},
                    comments={13: []})
        orig = fake.gh

        def gh(*args, data=None):
            if fake.sleeps >= 2:
                fake.comments[13] = [codex_summary("completed", False)]
            return orig(*args, data=data)
        cr.gh = gh
        self.assertEqual(pr_wait.watch([], [13], 60, 1800), 0)


if __name__ == "__main__":
    unittest.main()
