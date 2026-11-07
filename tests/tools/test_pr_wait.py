"""Offline tests of tools/pr_wait.py with gh replaced: when the one wait for a batch of PRs ends.

    python3 -I -m unittest discover -s tests/tools -v
"""
import calendar
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import codex_review as cr  # noqa: E402
import pr_wait  # noqa: E402

HEAD = "a" * 40
WHEN = "2026-11-02T15:00:00Z"
AUTO = {"mergeMethod": "SQUASH"}
ROOT = pr_wait.ROOT


def check(name, status="COMPLETED", conclusion="SUCCESS", started="2026-11-02T15:01:00Z"):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion, "startedAt": started}


RUNNING = [check("offline (ubuntu-latest)", "IN_PROGRESS", ""), check("offline (windows-latest)", "IN_PROGRESS", "")]
PASSED = [check("offline (ubuntu-latest)"), check("offline (windows-latest)")]


def pr(state="OPEN", rollup=None, auto=AUTO, mergeable="MERGEABLE", head=HEAD):
    return {"state": state, "mergeable": mergeable, "mergeStateStatus": "BLOCKED", "autoMergeRequest": auto,
            "statusCheckRollup": RUNNING if rollup is None else rollup, "headRefOid": head,
            "commits": [{"committedDate": WHEN}], "headRefName": "mac/x", "isCrossRepository": False}


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
        self.calls, self.sleeps, self.mine, self.merged, self.logged = [], 0, [], [], []
        test.addCleanup(setattr, cr, "log_review", cr.log_review)
        cr.log_review = lambda number, outcome, here=False: self.logged.append((number, outcome)) or "row"
        self.merge_result = (False, "a conflict changes existing lines")
        for mod, name, value in ((cr, "gh", self.gh), (pr_wait.time, "sleep", self.sleep),
                                 (pr_wait, "record_mine", self.mine.append),
                                 (pr_wait, "merge_main", self.merge_main)):
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

    def merge_main(self, repo, branch, head):
        self.merged.append((branch, head))
        return self.merge_result

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
        fake = Fake(self, {3: [pr(), pr(mergeable="CONFLICTING")]})
        self.assertEqual(pr_wait.watch([3], [], 60, 1800), 1)
        self.assertEqual(fake.merged, [("mac/x", HEAD)])  # tried, and the conflict was of another kind

    def test_conflict_that_only_adds_lines_is_merged_and_the_wait_goes_on(self):
        # 2026-11-02: one night, 11 branches ran 27 CI rounds, most after someone woke up to merge
        # main for a CHANGELOG.md conflict where both sides had only added lines.
        new = "b" * 40
        fake = Fake(self, {14: [pr(), pr(mergeable="CONFLICTING"), pr(mergeable="CONFLICTING"),
                                pr(head=new), pr("MERGED", PASSED, head=new)]})
        fake.merge_result = (True, "merged origin/main into mac/x")
        self.assertEqual(pr_wait.watch([14], [], 60, 1800), 0)
        self.assertEqual(fake.merged, [("mac/x", HEAD)])  # once: the second view still showed the old head

    def test_conflict_on_a_fork_pr_is_not_merged(self):
        fork = dict(pr(mergeable="CONFLICTING"), isCrossRepository=True)
        fake = Fake(self, {15: [fork]})
        self.assertEqual(pr_wait.watch([15], [], 60, 1800), 1)
        self.assertEqual(fake.merged, [])

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
        self.assertEqual(fake.logged, [(8, "clean")])  # once, not once per poll

    def test_failed_review_turns_on_auto_merge_and_says_so_once(self):
        views = [pr(auto=None), pr(auto=AUTO), pr(auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {9: views}, comments={9: [codex_summary("failed", True)]})
        self.assertEqual(pr_wait.watch([], [9], 60, 1800), 0)
        self.assertEqual(len(fake.merges()), 1)
        self.assertEqual(len(fake.comments_posted()), 1)
        self.assertEqual(len(fake.mine), 1)
        self.assertEqual(fake.logged, [(9, "failed")])

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
        self.assertEqual(fake.logged, [(10, "timeout")])

    def test_unresolved_findings_need_action(self):
        fake = Fake(self, {11: [pr(auto=None)]}, comments={11: [codex_summary("completed", True)]},
                    threads=["P1: this breaks"])
        self.assertEqual(pr_wait.watch([], [11], 60, 1800), 1)
        self.assertEqual(fake.merges(), [])
        self.assertEqual(fake.logged, [(11, "findings")])

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


class NightTest(unittest.TestCase):
    """#255: PR #254 changed the panel and had to wait for the night in-game test before auto-merge, and
    for Codex too. --codex turned auto-merge on too early; without it the wait ended at once."""

    def test_auto_merge_off_is_not_an_exit_and_is_never_turned_on(self):
        views = [pr(rollup=PASSED, auto=None)] * 10 + [pr(rollup=PASSED, auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {16: views})
        self.assertEqual(pr_wait.watch([], [], 60, 1800, night={16}), 0)
        self.assertEqual(fake.sleeps, 11)
        self.assertEqual(fake.merges(), [])

    def test_clean_review_leaves_auto_merge_to_the_night_test(self):
        views = [pr(rollup=PASSED, auto=None)] * 5 + [pr(rollup=PASSED, auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {17: views}, comments={17: [codex_summary("completed", False)]})
        self.assertEqual(pr_wait.watch([], [17], 60, 1800, night={17}), 0)
        self.assertEqual(fake.merges(), [])
        self.assertEqual(fake.logged, [(17, "clean")])

    def test_no_review_in_time_says_so_without_turning_on_auto_merge(self):
        views = [pr(rollup=PASSED, auto=None)] * 40 + [pr(rollup=PASSED, auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {18: views}, comments={18: []})
        self.assertEqual(pr_wait.watch([], [18], 60, 1800, night={18}), 0)
        self.assertEqual(fake.merges(), [])
        self.assertEqual(len(fake.comments_posted()), 1)
        self.assertIn("night", fake.comments_posted()[0][4])

    def test_findings_and_failed_ci_still_end_the_wait(self):
        fake = Fake(self, {19: [pr(auto=None)]}, comments={19: [codex_summary("completed", True)]},
                    threads=["P1: this breaks"])
        self.assertEqual(pr_wait.watch([], [19], 60, 1800, night={19}), 1)
        self.assertEqual(fake.merges(), [])
        failed = [check("offline (ubuntu-latest)", conclusion="FAILURE"), check("offline (windows-latest)")]
        Fake(self, {20: [pr(auto=None), pr(rollup=failed, auto=None)]})
        self.assertEqual(pr_wait.watch([], [], 60, 1800, night={20}), 1)

    def test_night_option_on_the_command_line(self):
        seen = []
        self.addCleanup(setattr, pr_wait, "watch", pr_wait.watch)
        pr_wait.watch = lambda *a: seen.append(a) or 0
        self.addCleanup(setattr, sys, "argv", sys.argv)
        sys.argv = ["pr_wait.py", "1", "--codex", "254", "--night", "254"]
        self.assertEqual(pr_wait.main(), 0)
        self.assertEqual(seen, [([1], [254], 60, 1800, {254}, set())])


class Hold(unittest.TestCase):
    """#275: some PRs stay open on purpose (say, until a release is done) and only wait for Codex; that took
    a separate `codex_review.py wait`, whose "no findings" report woke the main session for nothing."""

    def test_clean_review_is_no_exit_and_auto_merge_stays_off(self):
        views = [pr(rollup=PASSED, auto=None)] * 10 + [pr(rollup=PASSED, auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {21: views}, comments={21: [codex_summary("completed", False)]})
        self.assertEqual(pr_wait.watch([], [21], 60, 1800, hold={21}), 0)
        self.assertEqual(fake.merges(), [])
        self.assertEqual(fake.sleeps, 11)
        self.assertEqual(fake.logged, [(21, "clean")])

    def test_without_codex_auto_merge_off_is_no_exit(self):
        views = [pr(rollup=PASSED, auto=None)] * 4 + [pr("MERGED", PASSED)]
        fake = Fake(self, {22: views})
        self.assertEqual(pr_wait.watch([], [], 60, 1800, hold={22}), 0)
        self.assertEqual(fake.sleeps, 4)
        self.assertEqual(fake.merges(), [])

    def test_no_review_in_time_says_held(self):
        views = [pr(rollup=PASSED, auto=None)] * 40 + [pr("MERGED", PASSED)]
        fake = Fake(self, {23: views}, comments={23: []})
        self.assertEqual(pr_wait.watch([], [23], 60, 1800, hold={23}), 0)
        self.assertEqual(fake.merges(), [])
        self.assertEqual(len(fake.comments_posted()), 1)
        self.assertIn("held", fake.comments_posted()[0][4])

    def test_findings_and_failed_ci_still_end_the_wait(self):
        Fake(self, {24: [pr(auto=None)]}, comments={24: [codex_summary("completed", True)]},
             threads=["P1: this breaks"])
        self.assertEqual(pr_wait.watch([], [24], 60, 1800, hold={24}), 1)
        failed = [check("offline (ubuntu-latest)", conclusion="FAILURE"), check("offline (windows-latest)")]
        Fake(self, {25: [pr(auto=None), pr(rollup=failed, auto=None)]})
        self.assertEqual(pr_wait.watch([], [], 60, 1800, hold={25}), 1)

    def test_hold_on_the_command_line(self):
        seen = []
        self.addCleanup(setattr, pr_wait, "watch", pr_wait.watch)
        pr_wait.watch = lambda *a: seen.append(a) or 0
        self.assertEqual(pr_wait.main(["--codex", "26", "--hold", "26"]), 0)
        self.assertEqual(seen, [([], [26], 60, 1800, set(), {26})])

def clean(auto=AUTO, head=HEAD):
    view = pr(rollup=PASSED, auto=auto, head=head)
    view["mergeStateStatus"] = "CLEAN"
    return view


class StalledAutoMerge(unittest.TestCase):
    """#323 (2026-11-06): auto-merge on, both checks passed at 23:45, CLEAN, and GitHub did not merge it
    until a manual `gh pr merge 323 --squash` at 00:35. pr_wait now runs that plain merge itself once the
    PR has sat so for STALL_MINUTES."""

    def run_wait(self, fake, *numbers, **kw):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = pr_wait.watch(list(numbers), [], 60, 1800, kw.get("night", set()), kw.get("hold", set()))
        return code, out.getvalue()

    def test_stalled_past_the_threshold_is_merged_and_reported_as_merged(self):
        fake = Fake(self, {323: [clean()]})
        code, out = self.run_wait(fake, 323)
        self.assertEqual(code, 0)
        self.assertEqual(fake.merges(), [("pr", "merge", "323", "--squash")])  # plain: no --admin, no --auto
        self.assertEqual(fake.sleeps, pr_wait.STALL_MINUTES)  # first seen, then STALL_MINUTES checks a minute apart
        self.assertIn("#323 merged (merged by pr_wait", out)

    def test_not_before_the_threshold(self):
        views = [clean()] * pr_wait.STALL_MINUTES + [pr("MERGED", PASSED)]  # GitHub merges just in time
        fake = Fake(self, {324: views})
        code, out = self.run_wait(fake, 324)
        self.assertEqual(code, 0)
        self.assertEqual(fake.merges(), [])
        self.assertEqual(out.strip(), "#324 merged")

    def test_the_clock_restarts_on_a_new_head(self):
        views = [clean()] * 6 + [clean(head="b" * 40)] * 6 + [pr("MERGED", PASSED)]
        fake = Fake(self, {325: views})
        self.assertEqual(self.run_wait(fake, 325)[0], 0)
        self.assertEqual(fake.merges(), [])

    def test_the_clock_restarts_when_the_pr_leaves_clean(self):
        blocked = clean()
        blocked["mergeStateStatus"] = "BLOCKED"
        views = [clean()] * 6 + [blocked] + [clean()] * 6 + [pr("MERGED", PASSED)]
        fake = Fake(self, {326: views})
        self.assertEqual(self.run_wait(fake, 326)[0], 0)
        self.assertEqual(fake.merges(), [])

    def test_hold_is_never_merged_here(self):
        views = [clean()] * (pr_wait.STALL_MINUTES * 3) + [pr("MERGED", PASSED)]
        fake = Fake(self, {327: views})
        self.assertEqual(self.run_wait(fake, 327, hold={327})[0], 0)
        self.assertEqual(fake.merges(), [])

    def test_auto_merge_off_is_never_merged_here(self):
        # night PR waiting for its test: CLEAN, checks passed, auto-merge off
        views = [clean(auto=None)] * (pr_wait.STALL_MINUTES * 3) + [pr("MERGED", PASSED)]
        fake = Fake(self, {328: views})
        self.assertEqual(self.run_wait(fake, 328, night={328})[0], 0)
        self.assertEqual(fake.merges(), [])

    def test_a_night_pr_whose_auto_merge_was_turned_on_is_merged_when_stalled(self):
        fake = Fake(self, {329: [clean()]})
        self.assertEqual(self.run_wait(fake, 329, night={329})[0], 0)
        self.assertEqual(fake.merges(), [("pr", "merge", "329", "--squash")])

    def test_a_failed_merge_needs_action_with_the_error(self):
        fake = Fake(self, {330: [clean()]})
        gh = fake.gh

        def refuse(*args, data=None):
            if args[:2] == ("pr", "merge"):
                fake.calls.append(args)
                raise RuntimeError("gh pr merge: Pull request is not mergeable: the base branch policy prohibits it")
            return gh(*args, data=data)
        cr.gh = refuse
        code, out = self.run_wait(fake, 330)
        self.assertEqual(code, 1)
        self.assertEqual(len(fake.merges()), 1)
        self.assertIn("#330 needs action: auto-merge stalled", out)
        self.assertIn("base branch policy prohibits it", out)

    def test_a_merge_that_github_beat_us_to_is_merged(self):
        views = [clean()] * (pr_wait.STALL_MINUTES + 1) + [pr("MERGED", PASSED)]
        fake = Fake(self, {331: views})
        gh = fake.gh

        def late(*args, data=None):
            if args[:2] == ("pr", "merge"):
                fake.calls.append(args)
                raise RuntimeError("Pull request #331 was already merged")
            return gh(*args, data=data)
        cr.gh = late
        code, out = self.run_wait(fake, 331)
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), "#331 merged")

    def test_from_the_waiting_list_after_a_clean_codex_review(self):
        tmp = tempfile.mkdtemp(prefix="pr_wait_stall-")
        self.addCleanup(shutil.rmtree, tmp, True)
        set_env(self, "SDP_SHARED", tmp)
        set_env(self, "SDP_LOCAL_CONFIG", os.path.join(tmp, "no-local.json"))
        views = [pr(rollup=PASSED, auto=None)] + [clean()]
        fake = Fake(self, {332: views}, comments={332: [codex_summary("completed", False)]})
        pr_wait.add(332, codex=True)
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(pr_wait.watch_list(60, 1800), 0)
        self.assertEqual(fake.merges(), [("pr", "merge", "332", "--auto", "--squash"), ("pr", "merge", "332", "--squash")])
        self.assertIn("merged by pr_wait", out.getvalue())
        self.assertEqual(pr_wait.read_list(), {})


def set_env(test, name, value):
    old = os.environ.get(name)
    test.addCleanup(lambda: os.environ.__setitem__(name, old) if old is not None else os.environ.pop(name, None))
    os.environ[name] = value


class WaitingList(unittest.TestCase):
    """#275: handing a PR to the watch side session took a message, and its reply ("put on the wait") woke
    the main session once more; on 2026-11-04 that held back #274's merge report for about 6 hours. Now
    a session puts the PR on a shared list and the standing `--list` wait picks it up by itself."""

    def setUp(self):
        tmp = tempfile.mkdtemp(prefix="pr_wait_list-")
        self.addCleanup(shutil.rmtree, tmp, True)
        old = os.environ.get("SDP_SHARED")
        self.addCleanup(lambda: os.environ.__setitem__("SDP_SHARED", old) if old is not None
                        else os.environ.pop("SDP_SHARED", None))
        os.environ["SDP_SHARED"] = tmp
        set_env(self, "SDP_LOCAL_CONFIG", os.path.join(tmp, "no-local.json"))  # no night window here

    def test_the_list_sits_next_to_the_codex_log(self):
        self.assertEqual(os.path.dirname(pr_wait.list_path()), os.path.dirname(cr.log_path()))

    def test_add_writes_the_list_and_returns(self):
        self.assertEqual(pr_wait.main(["add", "31", "--codex", "--night"]), 0)
        self.assertEqual(pr_wait.main(["add", "32"]), 0)
        items = pr_wait.read_list()
        self.assertEqual(sorted(items), [31, 32])
        self.assertEqual((items[31]["codex"], items[31]["night"]), (True, True))
        self.assertEqual((items[32]["codex"], items[32]["night"]), (False, False))
        pr_wait.main(["add", "31"])  # options change, the time it was added stays
        again = pr_wait.read_list()
        self.assertFalse(again[31]["codex"])
        self.assertEqual(again[31]["added"], items[31]["added"])

    def test_a_pr_added_while_waiting_is_picked_up_and_its_merge_ends_the_wait(self):
        fake = Fake(self, {41: [pr()], 42: [pr(), pr("MERGED", PASSED)]})
        pr_wait.add(41)
        sleep = fake.sleep

        def sleep_and_add(seconds):
            sleep(seconds)
            if fake.sleeps == 2:
                pr_wait.add(42)  # another session hands a PR over while the wait runs
        pr_wait.time.sleep = sleep_and_add
        self.assertEqual(pr_wait.watch_list(60, 1800), 0)
        self.assertEqual(fake.sleeps, 3)  # 42 read after the 2nd sleep, merged on the next check
        self.assertEqual(sorted(pr_wait.read_list()), [41])  # 42 ended and left the list; 41 still waits

    def test_an_empty_list_keeps_waiting(self):
        fake = Fake(self, {43: [pr("MERGED", PASSED)]})
        sleep = fake.sleep

        def sleep_and_add(seconds):
            sleep(seconds)
            if fake.sleeps == 5:
                pr_wait.add(43)
        pr_wait.time.sleep = sleep_and_add
        self.assertEqual(pr_wait.watch_list(60, 1800), 0)
        self.assertEqual(fake.sleeps, 5)
        self.assertEqual(pr_wait.read_list(), {})

    def test_needs_action_ends_the_wait_and_leaves_the_list(self):
        failed = [check("offline (ubuntu-latest)", conclusion="FAILURE"), check("offline (windows-latest)")]
        Fake(self, {44: [pr(), pr(rollup=failed)], 45: [pr()]})
        pr_wait.add(44)
        pr_wait.add(45)
        self.assertEqual(pr_wait.watch_list(60, 1800), 1)
        self.assertEqual(sorted(pr_wait.read_list()), [45])

    def test_hold_from_the_list(self):
        views = [pr(rollup=PASSED, auto=None)] * 5 + [pr(rollup=PASSED, auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {49: views}, comments={49: [codex_summary("completed", False)]})
        self.assertEqual(pr_wait.main(["add", "49", "--codex", "--hold"]), 0)
        self.assertTrue(pr_wait.read_list()[49]["hold"])
        self.assertEqual(pr_wait.watch_list(60, 1800), 0)
        self.assertEqual(fake.sleeps, 6)  # the clean review ended nothing; the merge did
        self.assertEqual(fake.merges(), [])

    def test_night_and_codex_options_from_the_list(self):
        views = [pr(rollup=PASSED, auto=None)] * 5 + [pr(rollup=PASSED, auto=AUTO), pr("MERGED", PASSED)]
        fake = Fake(self, {46: views}, comments={46: [codex_summary("completed", False)]})
        pr_wait.add(46, codex=True, night=True)
        self.assertEqual(pr_wait.watch_list(60, 1800), 0)
        self.assertEqual(fake.merges(), [])  # night: auto-merge waits for the night test
        self.assertEqual(fake.logged, [(46, "clean")])

    def test_the_codex_clock_starts_when_the_pr_was_added(self):
        # a restarted standing wait must not give Codex another 30 minutes
        fake = Fake(self, {47: [pr(rollup=PASSED, auto=None)] * 3 + [pr("MERGED", PASSED)]}, comments={47: []})
        pr_wait.change_list(lambda items: items.update({47: {"codex": True, "night": False,
                                                              "added": fake.clock - 1800}}))
        self.assertEqual(pr_wait.watch_list(60, 1800), 0)
        self.assertEqual(len(fake.merges()), 1)  # timed out on the first check: auto-merge on at once
        self.assertEqual(fake.sleeps, 3)

    def test_a_pr_github_does_not_know_leaves_the_list(self):
        fake = Fake(self, {48: [pr()]})
        fake.views = {}

        def missing(*args, data=None):
            raise RuntimeError("GraphQL: Could not resolve to a PullRequest with the number of 48.")
        cr.gh = missing
        pr_wait.add(48)
        self.assertEqual(pr_wait.watch_list(60, 1800), 2)
        self.assertEqual(pr_wait.read_list(), {})

    def test_the_old_command_line_still_works(self):
        seen = []
        self.addCleanup(setattr, pr_wait, "watch", pr_wait.watch)
        pr_wait.watch = lambda *a: seen.append(a) or 0
        self.assertEqual(pr_wait.main(["207", "208", "--codex", "209", "--night", "209"]), 0)
        self.assertEqual(seen, [([207, 208], [209], 60, 1800, {209}, set())])
        self.assertEqual(pr_wait.read_list(), {})  # the old way does not touch the list

def run(cwd, *args):
    done = subprocess.run(["git"] + list(args), cwd=cwd, capture_output=True, text=True)
    if done.returncode != 0:
        raise AssertionError("git %s: %s" % (" ".join(args), done.stderr))
    return done.stdout.strip()


class MergeMain(unittest.TestCase):
    """merge_main on real git repositories: a bare remote, a clone, main and a branch that both changed a file."""

    BASE = "# Changelog\n\n## Unreleased\n\n- one\n\n## v1.0\n\n- first\n"

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="test_pr_wait-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.remote = os.path.join(self.tmp, "remote.git")
        self.repo = os.path.join(self.tmp, "repo")
        run(self.tmp, "init", "-q", "--bare", "-b", "main", self.remote)
        run(self.tmp, "clone", "-q", self.remote, self.repo)
        for k, v in (("user.name", "t"), ("user.email", "t@t"), ("commit.gpgsign", "false")):
            run(self.repo, "config", k, v)
        run(self.repo, "checkout", "-q", "-b", "main")
        self.commit({"CHANGELOG.md": self.BASE, "other.txt": "a\nb\n"}, "base")
        run(self.repo, "push", "-q", "origin", "main")

    def commit(self, files, message, cwd=None):
        cwd = cwd or self.repo
        for name, text in files.items():
            with open(os.path.join(cwd, name), "w", newline="") as f:
                f.write(text)
        run(cwd, "add", "-A")
        run(cwd, "commit", "-q", "-m", message)

    def diverge(self, main_text, branch_text):
        run(self.repo, "checkout", "-q", "-b", "mac/x")
        self.commit({"CHANGELOG.md": branch_text, "other.txt": "a\nb\nc\n"}, "branch")
        run(self.repo, "push", "-q", "origin", "mac/x")
        head = run(self.repo, "rev-parse", "HEAD")
        run(self.repo, "checkout", "-q", "main")
        self.commit({"CHANGELOG.md": main_text}, "main")
        run(self.repo, "push", "-q", "origin", "main")
        run(self.repo, "checkout", "-q", "--detach")
        run(self.repo, "branch", "-q", "-D", "mac/x")  # the branch is only on the remote, like a PR's
        return head

    def remote_file(self, name):
        return run(self.repo, "show", "origin/mac/x:" + name)

    def test_both_sides_only_added_lines(self):
        head = self.diverge(self.BASE.replace("- one\n", "- one\n- from main\n"),
                            self.BASE.replace("- one\n", "- one\n- from branch\n- and more\n"))
        done, text = pr_wait.merge_main(self.repo, "mac/x", head)
        self.assertTrue(done, text)
        self.assertEqual(self.remote_file("CHANGELOG.md") + "\n",
                         self.BASE.replace("- one\n", "- one\n- from main\n- from branch\n- and more\n"))
        self.assertEqual(self.remote_file("other.txt"), "a\nb\nc")
        parents = run(self.repo, "log", "-1", "--format=%P", "origin/mac/x").split()
        self.assertEqual(parents, [head, run(self.repo, "rev-parse", "origin/main")])
        self.assertEqual(len(run(self.repo, "worktree", "list").splitlines()), 1)  # temporary worktree gone

    def test_a_changed_line_is_left_for_a_person(self):
        head = self.diverge(self.BASE.replace("- one\n", "- one, from main\n"),
                            self.BASE.replace("- one\n", "- one\n- from branch\n"))
        done, text = pr_wait.merge_main(self.repo, "mac/x", head)
        self.assertFalse(done)
        self.assertIn("CHANGELOG.md", text)
        self.assertEqual(run(self.repo, "rev-parse", "origin/mac/x"), head)  # nothing pushed
        self.assertEqual(len(run(self.repo, "worktree", "list").splitlines()), 1)

    def test_a_worktree_with_uncommitted_changes_is_left_alone(self):
        head = self.diverge(self.BASE.replace("- one\n", "- one\n- from main\n"),
                            self.BASE.replace("- one\n", "- one\n- from branch\n"))
        own = os.path.join(self.tmp, "own")
        run(self.repo, "worktree", "add", "-q", "-b", "mac/x", own, "origin/mac/x")
        with open(os.path.join(own, "other.txt"), "a") as f:
            f.write("work in progress\n")
        done, text = pr_wait.merge_main(self.repo, "mac/x", head)
        self.assertFalse(done)
        self.assertIn("uncommitted", text)
        self.assertEqual(run(self.repo, "rev-parse", "origin/mac/x"), head)

    def test_a_clean_worktree_of_the_branch_follows_the_merge(self):
        head = self.diverge(self.BASE.replace("- one\n", "- one\n- from main\n"),
                            self.BASE.replace("- one\n", "- one\n- from branch\n"))
        own = os.path.join(self.tmp, "own")
        run(self.repo, "worktree", "add", "-q", "-b", "mac/x", own, "origin/mac/x")
        done, text = pr_wait.merge_main(self.repo, "mac/x", head)
        self.assertTrue(done, text)
        self.assertEqual(run(own, "rev-parse", "HEAD"), run(self.repo, "rev-parse", "origin/mac/x"))


class ResolveAdded(unittest.TestCase):
    def test_keeps_main_lines_first(self):
        text = "a\r\n<<<<<<< HEAD\r\nbranch\r\n||||||| base\r\n=======\r\nmain\r\n>>>>>>> origin/main\r\nz\r\n"
        self.assertEqual(pr_wait.resolve_added(text), "a\r\nmain\r\nbranch\r\nz\r\n")

    def test_any_base_line_in_a_block_refuses(self):
        text = "<<<<<<< HEAD\nx\n||||||| base\nold\n=======\ny\n>>>>>>> origin/main\n"
        self.assertIsNone(pr_wait.resolve_added(text))

    def test_without_a_base_part_refuses(self):
        self.assertIsNone(pr_wait.resolve_added("<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> origin/main\n"))


if __name__ == "__main__":
    unittest.main()


class NightQueue(unittest.TestCase):
    """2026-11-06: four items were queued by day by different agents; nobody told the watch side session,
    so no reminder was set and nothing started when the night window opened. The standing `--list` wait
    now ends once per night a few minutes after the window opens when the queue has items."""

    def setUp(self):
        tmp = tempfile.mkdtemp(prefix="pr_wait_night-")
        self.addCleanup(shutil.rmtree, tmp, True)
        set_env(self, "SDP_SHARED", tmp)
        cfg = os.path.join(tmp, "local.json")
        with open(cfg, "w", encoding="utf-8") as fh:
            json.dump({"night": "00:00-08:00", "weekend_is_night": True}, fh)
        set_env(self, "SDP_LOCAL_CONFIG", cfg)
        self.addCleanup(setattr, pr_wait.sdplock, "localtime", pr_wait.sdplock.localtime)
        pr_wait.sdplock.localtime = lambda t: __import__("time").gmtime(t)  # the fake clock reads as UTC here
        # queue_add asks git who is queuing; git waits through time.sleep, which these tests replace
        # (and sleep_or_stop raises there), so give the identity without running git
        self.addCleanup(setattr, pr_wait.sdplock, "identity", pr_wait.sdplock.identity)
        pr_wait.sdplock.identity = lambda root: {"tree": root, "branch": "test", "commit": "0", "owner": "test"}

    def at(self, day, hhmm):
        """Epoch seconds of 2026-11-<day> hh:mm UTC (local here, see setUp)."""
        h, m = hhmm.split(":")
        return float(calendar.timegm((2026, 11, day, int(h), int(m), 0)))

    def queue(self, what="真实点击测试 #300"):
        pr_wait.sdplock.queue_add(ROOT, what, "PR #300 等它")

    def run_list(self, start, sleeps_before_stop=3):
        """Run watch_list from clock start with an empty PR list; its exit code, or None if it kept waiting."""
        fake = Fake(self, {})
        fake.clock = start
        sleep = fake.sleep

        def sleep_or_stop(seconds):
            sleep(seconds)
            if fake.sleeps >= sleeps_before_stop:
                raise StopIteration
        pr_wait.time.sleep = sleep_or_stop
        try:
            return pr_wait.watch_list(60, 1800)
        except StopIteration:
            return None

    def test_fires_once_when_items_are_queued_and_the_window_has_opened(self):
        self.queue("真实点击测试 #300")
        self.queue("英文界面截图")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(self.run_list(self.at(7, "00:06")), 3)
        line = out.getvalue().strip()
        self.assertIn("夜间队列到点", line)
        self.assertIn("2 项", line)
        self.assertIn("#1 真实点击测试 #300", line)
        self.assertIn("#2 英文界面截图", line)

    def test_fires_when_the_window_opened_a_few_minutes_into_the_wait(self):
        self.queue()
        # 23:58: two checks before midnight, then 00:00, 00:01 ... until the delay has passed
        self.assertEqual(self.run_list(self.at(6, "23:58"), sleeps_before_stop=50), 3)

    def test_fires_on_a_stdout_that_cannot_show_chinese(self):
        self.queue("真实点击测试 #300")
        raw = io.BytesIO()
        out = io.TextIOWrapper(raw, encoding="cp1252", errors="strict")
        with contextlib.redirect_stdout(out):
            self.assertEqual(self.run_list(self.at(7, "00:06")), 3)
            out.flush()
        self.assertIn(b"#1", raw.getvalue())

    def test_not_before_the_window(self):
        self.queue()
        self.assertIsNone(self.run_list(self.at(6, "23:50")))
        self.assertIsNone(pr_wait.night_due(self.at(7, "00:02")))  # opened, but not a few minutes ago yet
        self.assertIsNone(pr_wait.night_due(self.at(7, "08:00")))  # closed again
        self.assertIsNone(pr_wait.night_due(self.at(7, "14:00")))

    def test_not_twice_the_same_night(self):
        self.queue()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.run_list(self.at(7, "00:06")), 3)
        self.assertIsNone(self.run_list(self.at(7, "00:08")))  # the wait started again
        self.assertIsNone(pr_wait.night_due(self.at(7, "03:00")))
        self.assertIsNotNone(pr_wait.night_due(self.at(8, "00:06")))  # the next night fires again

    def test_not_with_an_empty_queue(self):
        self.assertIsNone(self.run_list(self.at(7, "00:06")))
        item = pr_wait.sdplock.queue_add(ROOT, "跑过了", "x")
        pr_wait.sdplock.queue_done(item["id"])
        self.assertIsNone(pr_wait.night_due(self.at(7, "00:10")))  # only done items
        self.queue()
        self.assertIsNotNone(pr_wait.night_due(self.at(7, "02:00")))  # added later that night: still once

    def test_not_for_the_weekly_test_before_its_night(self):
        # #329: the weekly in-game test is queued a week ahead; it is due only from its own night
        pr_wait.sdplock.queue_weekly(ROOT, night="2026-11-14")
        self.assertIsNone(pr_wait.night_due(self.at(7, "00:06")))
        self.assertIsNone(pr_wait.night_due(self.at(13, "00:06")))
        line = pr_wait.night_due(self.at(14, "00:06"))
        self.assertIn("每周整套游戏内测试", line)

    def test_the_window_comes_from_the_config_and_may_cross_midnight(self):
        with open(os.environ["SDP_LOCAL_CONFIG"], "w", encoding="utf-8") as fh:
            json.dump({"night": "22:30-06:00"}, fh)
        self.assertIsNone(pr_wait.night_key(self.at(6, "22:06")))  # not open yet
        self.assertEqual(pr_wait.night_key(self.at(6, "22:40")), "2026-11-06")
        self.assertEqual(pr_wait.night_key(self.at(7, "01:00")), "2026-11-06")  # same night after midnight
        self.assertIsNone(pr_wait.night_key(self.at(7, "06:00")))
        with open(os.environ["SDP_LOCAL_CONFIG"], "w", encoding="utf-8") as fh:
            json.dump({"weekend_is_night": True}, fh)
        self.assertIsNone(pr_wait.night_key(self.at(7, "00:06")))  # no window: never (weekends do not count)

    @unittest.skipUnless(hasattr(__import__("time"), "tzset"), "time.tzset is Unix only")
    def test_the_window_is_in_local_time(self):
        import time
        pr_wait.sdplock.localtime = time.localtime
        self.addCleanup(time.tzset)  # runs after TZ is restored
        set_env(self, "TZ", "Asia/Shanghai")
        time.tzset()
        # 16:06 UTC on 11-06 is 00:06 on 11-07 in Shanghai
        self.assertEqual(pr_wait.night_key(self.at(6, "16:06")), "2026-11-07")
        self.assertIsNone(pr_wait.night_key(self.at(7, "00:06")))  # 08:06 there: closed
