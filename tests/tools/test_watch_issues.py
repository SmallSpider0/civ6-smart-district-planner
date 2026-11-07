"""Offline tests of tools/watch_issues.py: which items wake the agent and which are held.

    python3 -I -m unittest discover -s tests/tools -v
"""
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

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
        self.assertEqual(wi.where("SmallSpider", True, {"DracoYus", "SmallSpider"}), "report")  # no own account given
        self.assertEqual(wi.where("someone", True, {"DracoYus"}), "others")

    def test_the_shared_account_is_only_seen(self):
        self.assertEqual(wi.where("SmallSpider", True, {"DracoYus", "SmallSpider"}, "SmallSpider"), "seen")


class Poll(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.saved = (wi.HELD, wi.OTHERS, wi.REPORTED, wi.gh)
        wi.HELD, wi.OTHERS = os.path.join(self.dir, "held.log"), os.path.join(self.dir, "others.log")
        wi.REPORTED = os.path.join(self.dir, "reported.log")
        self.issues = [issue(7, "DracoYus"), issue(8, "DracoYus"), issue(9, "someone"), issue(10, "DracoYus", pr=True)]
        self.comments = [comment(1, 7, "DracoYus"), comment(2, 8, "DracoYus"), comment(3, 7, "someone"),
                         comment(4, 10, "DracoYus"), comment(5, 7, "DracoYus")]
        self.labelled = [{"number": 7}, {"number": 11}]
        self.issues.append(issue(11, "DracoYus"))
        self.events = {7: [labeled("someone"), labeled("DracoYus")],
                       11: [labeled("DracoYus"), labeled("someone")]}
        self.event_reads = []

        def fake(path):
            if path == "user":
                return {"login": "SmallSpider"}
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
        wi.HELD, wi.OTHERS, wi.REPORTED, wi.gh = self.saved

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

    def test_own_account_on_an_auto_issue_is_not_reported(self):
        self.issues = [issue(12, "SmallSpider")]
        self.comments = [comment(20, 7, "SmallSpider"), comment(21, 7, "DracoYus")]
        state = {"since": SINCE, "seen": [], "mine": [], "users": ["DracoYus", "SmallSpider"]}
        saved = os.environ.pop("SDP_WATCH_SELF", None)
        try:
            out = wi.poll(state)
        finally:
            if saved is not None:
                os.environ["SDP_WATCH_SELF"] = saved
        self.assertEqual(state["self"], "SmallSpider")  # read once with gh, then cached
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0].startswith("NEW COMMENT on #7 by DracoYus: text 21"))  # the collaborator still wakes it
        self.assertNotIn("SmallSpider", self.read(wi.HELD) + self.read(wi.OTHERS))
        self.assertIn("comment-20", state["seen"])
        self.assertIn("issue-12", state["seen"])

    def test_reported_lines_are_kept_in_a_file(self):
        """#261: the watch's stdout went to a file the side session never read; the reply was lost."""
        state = {"since": SINCE, "seen": [], "mine": ["5"], "users": ["DracoYus"]}
        out = wi.poll(state)
        kept = self.read(wi.REPORTED).splitlines()
        self.assertEqual([line.split(" ", 1)[1] for line in kept], out)
        self.assertNotIn("#8", self.read(wi.REPORTED))  # held, not reported
        state["seen"], state["since"] = [], SINCE
        wi.poll(state)  # appended, never overwritten
        self.assertEqual(len(self.read(wi.REPORTED).splitlines()), 2 * len(out))

    def test_reported_option_prints_the_last_lines(self):
        with open(wi.REPORTED, "w", encoding="utf-8") as f:
            f.write("".join("t%d NEW COMMENT %d\n" % (i, i) for i in range(30)))
        saved = sys.argv
        self.addCleanup(setattr, sys, "argv", saved)
        for argv, first, count in ((["--reported"], 10, 20), (["--reported", "3"], 27, 3)):
            sys.argv = ["watch_issues.py"] + argv
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(wi.main(), 0)
            lines = out.getvalue().splitlines()
            self.assertEqual((lines[0], len(lines)), ("t%d NEW COMMENT %d" % (first, first), count))
        os.remove(wi.REPORTED)
        with redirect_stdout(io.StringIO()) as out:
            wi.main()
        self.assertEqual(out.getvalue().strip(), "nothing reported")

    def test_held_prints_and_clears(self):
        with open(wi.HELD, "w", encoding="utf-8") as f:
            f.write("a\nb\n")
        wi.held(False)
        self.assertEqual(self.read(wi.HELD), "a\nb\n")
        wi.held(True)
        self.assertEqual(self.read(wi.HELD), "")


class MineRace(unittest.TestCase):
    """A --mine recorded while the loop polls must not be overwritten by its save."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.saved = (wi.DIR, wi.STATE, wi.poll, wi.workshop, sys.argv)
        wi.DIR, wi.STATE = self.dir, os.path.join(self.dir, "state.json")
        wi.save({"since": SINCE, "seen": [], "mine": ["1"]})

    def tearDown(self):
        wi.DIR, wi.STATE, wi.poll, wi.workshop, sys.argv = self.saved

    def test_mine_written_during_a_poll_survives(self):
        def poll(state):  # another process runs --mine while this one polls
            sys.argv = ["watch_issues.py", "--mine", URL + "7#issuecomment-99"]
            wi.main()
            return []
        wi.poll, wi.workshop = poll, lambda state, every: None
        sys.argv = ["watch_issues.py", "--once"]
        wi.main()
        self.assertEqual(sorted(wi.load()["mine"]), ["1", "99"])


class LabelAdded(unittest.TestCase):
    """#338: the maintainer labelled #336 and #329 `auto` and nobody commented; the watch never woke."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.saved = (wi.HELD, wi.OTHERS, wi.REPORTED, wi.gh)
        wi.HELD, wi.OTHERS = os.path.join(self.dir, "held.log"), os.path.join(self.dir, "others.log")
        wi.REPORTED = os.path.join(self.dir, "reported.log")
        self.labelled = [{"number": 7, "title": "t7", "html_url": URL + "7"}]
        self.events = {7: [labeled("someone")]}
        self.event_reads = []
        self.env = os.environ.pop("SDP_WATCH_SELF", None)

        def fake(path):
            if path == "user":
                return {"login": "SmallSpider"}
            if "/events" in path:
                number = int(path.split("/issues/")[1].split("/")[0])
                self.event_reads.append(number)
                return [dict(e, id=i + 1) for i, e in enumerate(self.events.get(number, []))]
            if "labels=" in path:
                return self.labelled if "&page=1" in path else []
            return []
        wi.gh = fake

    def tearDown(self):
        wi.HELD, wi.OTHERS, wi.REPORTED, wi.gh = self.saved
        if self.env is not None:
            os.environ["SDP_WATCH_SELF"] = self.env

    def read(self, path):
        if not os.path.exists(path):
            return ""
        with open(path, encoding="utf-8") as f:
            return f.read()

    def add(self, number, login):
        self.labelled.append({"number": number, "title": "t%d" % number, "html_url": URL + str(number)})
        self.events.setdefault(number, []).append(labeled(login))

    def state(self):
        return {"since": SINCE, "seen": [], "mine": [], "users": ["DracoYus", "SmallSpider"]}

    def test_first_run_takes_the_labels_already_there_as_seen(self):
        state = self.state()
        self.assertEqual(wi.poll(state), [])
        self.assertEqual(self.event_reads, [])  # no events read for labels that were already there
        self.assertIn("7", state["labels"])

    def test_the_shared_account_adding_the_label_wakes_the_agent(self):
        state = self.state()
        wi.poll(state)
        self.add(336, "SmallSpider")
        out = wi.poll(state)
        self.assertEqual(out, ["LABELLED #336 auto by SmallSpider: t336 " + URL + "336"])
        self.assertIn(out[0], self.read(wi.REPORTED))
        self.assertEqual(wi.poll(state), [])  # once per labelling
        self.assertEqual(self.event_reads, [336])  # events read only for the new one

    def test_a_collaborator_adding_the_label_wakes_the_agent(self):
        state = self.state()
        wi.poll(state)
        self.add(329, "DracoYus")
        self.assertEqual(wi.poll(state), ["LABELLED #329 auto by DracoYus: t329 " + URL + "329"])

    def test_anyone_else_adding_the_label_goes_to_others(self):
        state = self.state()
        wi.poll(state)
        self.add(40, "someone")
        self.assertEqual(wi.poll(state), [])
        self.assertIn("LABELLED #40 auto by someone", self.read(wi.OTHERS))
        self.assertEqual(wi.poll(state), [])
        self.assertEqual(self.read(wi.OTHERS).count("#40"), 1)

    def test_removed_then_added_again_counts_again(self):
        state = self.state()
        wi.poll(state)
        self.add(336, "SmallSpider")
        self.assertEqual(len(wi.poll(state)), 1)
        self.labelled = [i for i in self.labelled if i["number"] != 336]
        self.assertEqual(wi.poll(state), [])
        self.assertNotIn("336", state["labels"])
        self.add(336, "DracoYus")
        self.assertEqual(wi.poll(state), ["LABELLED #336 auto by DracoYus: t336 " + URL + "336"])

    def test_a_new_issue_opened_with_the_label_is_reported_once(self):
        state = {"since": SINCE, "seen": [], "mine": [], "users": ["DracoYus"]}
        wi.poll(state)
        state["since"] = SINCE  # the issue below was opened after it
        self.add(50, "DracoYus")
        issues = [issue(50, "DracoYus")]
        fake = wi.gh
        wi.gh = lambda path: issues if path.startswith("repos/{owner}/{repo}/issues?state=all&sort") else fake(path)
        out = wi.poll(state)
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0].startswith("NEW ISSUE #50 "))
        self.assertIn("50", state["labels"])

    def test_an_issue_the_shared_account_opens_with_the_label_is_its_own(self):
        state = self.state()
        wi.poll(state)
        state["since"] = SINCE
        self.add(51, "SmallSpider")
        issues = [issue(51, "SmallSpider")]
        fake = wi.gh
        wi.gh = lambda path: issues if path.startswith("repos/{owner}/{repo}/issues?state=all&sort") else fake(path)
        self.assertEqual(wi.poll(state), [])  # an agent filed it and is already on it
        self.assertIn("51", state["labels"])


if __name__ == "__main__":
    unittest.main()
