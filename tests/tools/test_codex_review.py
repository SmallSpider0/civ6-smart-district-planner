"""Offline tests of tools/codex_review.py's reading of Codex's marks on a pull request.

    python3 -I -m unittest discover -s tests/tools -v
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import codex_review as cr  # noqa: E402

HEAD = "a" * 40
OLD = "b" * 40
SINCE = "2026-10-27T03:00:00Z"


def summary(sha, status, unresolved=None):
    state = {"code_review": {"commit_sha": sha, "has_any_findings": unresolved, "has_unresolved_findings": unresolved,
                             "status": status},
             "security_review": {"commit_sha": None, "has_any_findings": None, "has_unresolved_findings": None, "status": None}}
    body = "<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 %s -->\n\n## Codex Review Summary" % json.dumps(state)
    return {"user": {"login": cr.BOT}, "body": body}


class Verdict(unittest.TestCase):
    def test_running_summary_is_not_done(self):
        self.assertIsNone(cr.verdict(HEAD, SINCE, [summary(HEAD, "running")], [], []))

    def test_finished_summary_decides(self):
        self.assertEqual(cr.verdict(HEAD, SINCE, [summary(HEAD, "completed", False)], [], []), "clean")
        self.assertEqual(cr.verdict(HEAD, SINCE, [summary(HEAD, "completed", True)], [], []), "findings")

    def test_failed_summary_is_not_a_review(self):
        # Codex ran out of usage on PR 192 and 193: status "failed" with
        # has_unresolved_findings true but no threads, read as "all resolved".
        self.assertEqual(cr.verdict(HEAD, SINCE, [summary(HEAD, "failed", True)], [], []), "failed")

    def test_summary_of_an_older_commit_is_ignored(self):
        self.assertIsNone(cr.verdict(HEAD, SINCE, [summary(OLD, "completed", False)], [], []))

    def test_review_on_head_means_findings(self):
        reviews = [{"user": {"login": cr.BOT}, "commit_id": HEAD}]
        self.assertEqual(cr.verdict(HEAD, SINCE, [summary(HEAD, "running")], reviews, []), "findings")
        self.assertIsNone(cr.verdict(HEAD, SINCE, [], [{"user": {"login": cr.BOT}, "commit_id": OLD}], []))

    def test_thumbs_up_after_the_head_commit_means_clean(self):
        up = {"user": {"login": cr.BOT}, "content": "+1", "created_at": "2026-10-27T03:05:00Z"}
        self.assertEqual(cr.verdict(HEAD, SINCE, [], [], [up]), "clean")
        self.assertIsNone(cr.verdict(HEAD, SINCE, [], [], [dict(up, created_at="2026-10-27T02:00:00Z")]))
        self.assertIsNone(cr.verdict(HEAD, SINCE, [], [], [dict(up, content="eyes")]))

    def test_other_accounts_are_ignored(self):
        other = summary(HEAD, "completed", False)
        other["user"] = {"login": "someone"}
        self.assertIsNone(cr.verdict(HEAD, SINCE, [other], [{"user": {"login": "someone"}, "commit_id": HEAD}], []))

    def test_state_without_json_is_none(self):
        self.assertIsNone(cr.review_state("no state here"))
        self.assertIsNone(cr.review_state("<!-- codex-review-state:v1 {broken -->"))


if __name__ == "__main__":
    unittest.main()


TABLE = """# Trial

| PR | 日期 | 意见 | 属实 | 误报 | 等了多久 | 备注 |
|---|---|---|---|---|---|---|
| #1 | 2026-10-27 | 0 | 0 | 0 | — | |
| #2 | 2026-10-28 | 1 | 1 | 0 | — | kept note |

after the table
"""


def thread(resolved, *replies):
    nodes = [{"author": {"login": "chatgpt-codex-connector"}, "url": "u", "body": "P2 finding"}]
    nodes += [{"author": {"login": "me"}, "url": "u", "body": b} for b in replies]
    return {"id": "T", "isResolved": resolved, "path": "a", "line": 1, "comments": {"nodes": nodes}}


class TrialTable(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "trial.md")
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(TABLE)

    def rows(self):
        with open(self.path, encoding="utf-8") as f:
            return [line for line in f.read().split("\n") if line.startswith("| #")]

    def test_counts_true_false_and_unresolved(self):
        threads = [thread(True, "Confirmed, fixed"), thread(True, cr.FALSE_POSITIVE + "no"), thread(False)]
        self.assertEqual(cr.thread_counts(threads), (3, 1, 1, 1))
        self.assertEqual(cr.row_cells((3, 1, 1, 1), "findings", 4.2), ("3", "1（另 1 条待核实）", "1", "约 4 分钟"))
        self.assertEqual(cr.row_cells((1, 0, 0, 1), "findings", 0.3), ("1", "待核实", "0", "不到 1 分钟"))
        self.assertEqual(cr.row_cells((0, 0, 0, 0), "clean", 2), ("0", "0", "0", "约 2 分钟"))

    def test_new_row_is_added_after_the_last_row(self):
        self.assertEqual(cr.upsert_row(self.path, 3, ("0", "0", "0", "约 2 分钟"), "2026-11-03"), "added")
        self.assertEqual(self.rows()[-1], "| #3 | 2026-11-03 | 0 | 0 | 0 | 约 2 分钟 |  |")
        self.assertEqual(len(self.rows()), 3)
        with open(self.path, encoding="utf-8") as f:
            self.assertTrue(f.read().endswith("after the table\n"))

    def test_existing_row_gets_new_counts_but_keeps_date_and_note(self):
        cr.upsert_row(self.path, 2, ("1", "1", "0", "约 3 分钟"), "2026-11-09")
        self.assertEqual(self.rows()[1], "| #2 | 2026-10-28 | 1 | 1 | 0 | 约 3 分钟 | kept note |")
        cr.upsert_row(self.path, 2, ("1", "0", "1", "约 9 分钟"), "2026-11-09")  # the time of the first round stays
        self.assertEqual(self.rows()[1], "| #2 | 2026-10-28 | 1 | 0 | 1 | 约 3 分钟 | kept note |")

    def test_a_failed_review_does_not_overwrite_real_counts(self):
        self.assertEqual(cr.upsert_row(self.path, 2, ("0", "0", "0", "没审"), "2026-11-03"), "kept")
        self.assertEqual(self.rows()[1], "| #2 | 2026-10-28 | 1 | 1 | 0 | — | kept note |")
        self.assertEqual(cr.upsert_row(self.path, 4, ("0", "0", "0", "没审"), "2026-11-03"), "added")

    def test_reviews_are_logged_outside_the_worktree_and_rendered_into_the_table(self):
        saved = (cr.gh, cr.codex_threads, os.environ.get("SDP_SHARED"))

        def restore():
            cr.gh, cr.codex_threads = saved[0], saved[1]
            os.environ.pop("SDP_SHARED", None)
            if saved[2]:
                os.environ["SDP_SHARED"] = saved[2]
        self.addCleanup(restore)
        os.environ["SDP_SHARED"] = os.path.join(self.dir, "shared")
        now = cr.datetime.datetime.now(cr.datetime.timezone.utc)
        asked = (now - cr.datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        cr.gh = lambda *args, data=None: json.dumps([{"body": "@codex review", "created_at": asked}])
        cr.codex_threads = lambda number: [thread(True, "Confirmed"), thread(False)]
        self.assertIn("recorded", cr.log_review(7, "findings"))
        cr.codex_threads = lambda number: [thread(True, "Confirmed"), thread(True, cr.FALSE_POSITIVE + "no")]
        cr.log_review(7, "findings")  # after the replies: counts follow, time and date stay
        cr.codex_threads = lambda number: []
        cr.log_review(8, "failed")
        cr.log_review(7, "failed")  # a failed round does not overwrite a real review
        self.assertEqual(cr.write_table(self.path), (2, 0))
        rows = {r.split("|")[1].strip(): r for r in self.rows()}
        self.assertIn("| 2 | 1 | 1 | 约 5 分钟 |", rows["#7"])
        self.assertIn("| 0 | 0 | 0 | 没审 |", rows["#8"])
        self.assertEqual(cr.write_table(self.path), (0, 1))  # rendering again adds nothing; a "not reviewed" row is kept
        self.assertEqual(len(self.rows()), 4)
