"""Offline tests of tools/codex_review.py's reading of Codex's marks on a pull request.

    python3 -I -m unittest discover -s tests/tools -v
"""
import json
import os
import sys
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
