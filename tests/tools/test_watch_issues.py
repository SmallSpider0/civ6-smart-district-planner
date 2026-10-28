"""Offline tests of tools/watch_issues.py: which items wake the agent and which are held.

    python3 -I -m unittest discover -s tests/tools -v
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import watch_issues as wi  # noqa: E402

SINCE = "2026-10-28T01:00:00Z"
URL = "https://github.com/o/r/issues/"


def issue(number, login, created="2026-10-28T02:00:00Z", pr=False):
    item = {"number": number, "user": {"login": login}, "title": "t%d" % number,
            "html_url": URL + str(number), "created_at": created}
    if pr:
        item["pull_request"] = {}
    return item


def labeled(login, name="auto"):
    return {"event": "labeled", "label": {"name": name}, "actor": {"login": login}}


def comment(cid, number, login, created="2026-10-28T02:00:00Z"):
    return {"id": cid, "issue_url": "https://api.github.com/repos/o/r/issues/%d" % number,
            "user": {"login": login}, "body": "text %d" % cid, "html_url": URL + "%d#issuecomment-%d" % (number, cid),
            "created_at": created}


class Where(unittest.TestCase):
    def test_labelled_issue_is_reported(self):
        self.assertEqual(wi.where("DracoYus", True, {"DracoYus"}), "report")

    def test_unlabelled_issue_is_held(self):
        self.assertEqual(wi.where("DracoYus", False, {"DracoYus"}), "held")

    def test_other_accounts_stay_others_even_on_a_labelled_issue(self):
        self.assertEqual(wi.where("someone", True, {"DracoYus"}), "others")


class Poll(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.saved = (wi.HELD, wi.OTHERS, wi.gh)
        wi.HELD, wi.OTHERS = os.path.join(self.dir, "held.log"), os.path.join(self.dir, "others.log")
        self.issues = [issue(7, "DracoYus"), issue(8, "DracoYus"), issue(9, "someone"), issue(10, "DracoYus", pr=True)]
        self.comments = [comment(1, 7, "DracoYus"), comment(2, 8, "DracoYus"), comment(3, 7, "someone"),
                         comment(4, 10, "DracoYus"), comment(5, 7, "DracoYus")]
        self.labelled = [{"number": 7}, {"number": 11}]
        self.issues.append(issue(11, "DracoYus"))
        self.events = {7: [labeled("someone"), labeled("DracoYus")],
                       11: [labeled("DracoYus"), labeled("someone")]}
        self.event_reads = []

        def fake(path):
            if "/events" in path:
                number = int(path.split("/issues/")[1].split("/")[0])
                self.event_reads.append(number)
                return self.events.get(number, [])
            if "labels=" in path:
                return self.labelled if "&page=1" in path else []
            if "/comments" in path:
                return self.comments
            return self.issues
        wi.gh = fake

    def tearDown(self):
        wi.HELD, wi.OTHERS, wi.gh = self.saved

    def read(self, path):
        if not os.path.exists(path):
            return ""
        with open(path, encoding="utf-8") as f:
            return f.read()

    def test_only_labelled_items_are_reported(self):
        state = {"since": SINCE, "seen": [], "mine": ["5"], "users": ["DracoYus"]}
        out = wi.poll(state)
        self.assertEqual(len(out), 2)
        self.assertTrue(out[0].startswith("NEW ISSUE #7 "))
        self.assertTrue(out[1].startswith("NEW COMMENT on #7 by DracoYus: text 1"))
        held = self.read(wi.HELD)
        self.assertIn("NEW ISSUE #8 ", held)
        self.assertIn("NEW COMMENT on #8 ", held)
        self.assertIn("NEW COMMENT on #10 ", held)  # a pull request without the label
        self.assertNotIn("#7", held)
        others = self.read(wi.OTHERS)
        self.assertIn("NEW ISSUE #9 ", others)
        self.assertIn("NEW COMMENT on #7 by someone", others)
        self.assertNotIn("text 5", held + others + "".join(out))  # the agent's own comment
        self.assertIn("NEW ISSUE #11 ", held)  # its label was last put on by someone else
        self.assertEqual(sorted(self.event_reads), [7, 11])  # once per issue, not per item

    def test_a_label_from_an_issue_template_does_not_count(self):
        self.labelled = [{"number": 9}]
        self.events = {9: [labeled("someone")]}
        state = {"since": SINCE, "seen": [], "mine": [], "users": ["DracoYus", "someone-else"]}
        self.issues = [issue(9, "someone-else")]
        self.comments = []
        self.assertEqual(wi.poll(state), [])
        self.assertIn("NEW ISSUE #9 ", self.read(wi.HELD))

    def test_other_labels_do_not_count(self):
        self.events = {7: [labeled("DracoYus", "bug")]}
        state = {"since": SINCE, "seen": [], "mine": [], "users": ["DracoYus"]}
        self.assertEqual(wi.poll(state), [])

    def test_seen_items_are_not_written_twice(self):
        state = {"since": SINCE, "seen": [], "mine": [], "users": ["DracoYus"]}
        wi.poll(state)
        state["since"] = SINCE
        self.assertEqual(wi.poll(state), [])
        self.assertEqual(self.read(wi.HELD).count("NEW ISSUE #8 "), 1)

    def test_labels_are_read_page_by_page(self):
        self.labelled = [{"number": n} for n in range(100)]
        pages = []

        def fake(path):
            pages.append(path)
            if "&page=1" in path:
                return self.labelled
            if "&page=2" in path:
                return [{"number": 500}]
            return []
        wi.gh = fake
        self.assertIn(500, wi.labelled())
        self.assertEqual(len(pages), 2)

    def test_held_prints_and_clears(self):
        with open(wi.HELD, "w", encoding="utf-8") as f:
            f.write("a\nb\n")
        wi.held(False)
        self.assertEqual(self.read(wi.HELD), "a\nb\n")
        wi.held(True)
        self.assertEqual(self.read(wi.HELD), "")


if __name__ == "__main__":
    unittest.main()
