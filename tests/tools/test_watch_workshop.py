"""Offline tests of tools/watch_workshop.py and the Workshop part of watch_issues.py.

The pages in tests/tools/workshop/ are trimmed copies of the public Steam pages
with made-up text; nothing here goes to the network.

    python3 -I -m unittest discover -s tests/tools -v
"""
import json
import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "tools"))
import watch_issues as wi  # noqa: E402
import watch_workshop as ww  # noqa: E402

DATA = os.path.join(HERE, "workshop")
OWNER, CONTRIBUTOR = 139098577, 147401921


def page(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        return f.read()


class Site:
    """Stands in for steamcommunity.com: answers with the stored pages and records each request."""

    def __init__(self):
        self.pages = {"item": page("item.html"), "comments": page("comments.json"),
                      "discussions": page("discussions.html"), "topic": page("topic.html")}
        self.asked, self.down = [], False

    def get(self, url):
        self.asked.append(url)
        if self.down:
            raise RuntimeError("network down")
        if "/comment/PublishedFile_Public/render/" in url:
            return self.pages["comments"]
        if "/discussions/" in url:
            return self.pages["discussions"]
        if "/discussion/" in url:
            return self.pages["topic"]
        return self.pages["item"]


NUMBERS = {"subscribers": 1234, "visitors": 4321, "favorites": 98, "collections": 41, "stars": 4, "ratings": 27}


class Stats(unittest.TestCase):
    """The item's numbers on the item page and their change in a day."""

    def test_all_numbers(self):
        self.assertEqual(ww.stats(page("item.html")), NUMBERS)

    def test_the_chinese_page(self):
        zh = (page("item.html").replace("Unique Visitors", "不重复访客数").replace("Current Subscribers", "当前订阅者")
              .replace("Current Favorites", "当前收藏人数").replace("27 ratings", "27 个评价")
              .replace("41 collections", "41 个合集"))
        self.assertEqual(ww.stats(zh), NUMBERS)

    def test_missing_numbers_are_none(self):
        item = page("item.html")
        no_table = re.sub(r'<table class="stats_table">.*?</table>', "", item, flags=re.S)
        got = ww.stats(no_table)
        self.assertEqual((got["subscribers"], got["visitors"], got["favorites"]), (None, None, None))
        self.assertEqual(got["collections"], 41)
        got = ww.stats(item.replace("4-star_large", "not-yet_large").replace("27 ratings", "Not enough ratings"))
        self.assertEqual((got["stars"], got["ratings"], got["subscribers"]), (None, None, 1234))
        self.assertEqual(ww.stats("<html></html>"), dict.fromkeys(ww.STATS))

    def test_change_in_a_day(self):
        hour, st = 3600, None
        for h in range(0, 30):
            st = ww.record(st, dict(NUMBERS, subscribers=1000 + 10 * h, stars=None if h == 29 else 4), 1793800000 + h * hour)
        base, diff = ww.change(st)
        self.assertEqual(base, 1793800000 + 5 * hour)  # 24 h before the reading at hour 29
        self.assertEqual(diff["subscribers"], 240)
        self.assertEqual(diff["favorites"], 0)
        self.assertNotIn("stars", diff)  # missing now: no change shown

    def test_no_change_within_the_first_day(self):
        st = ww.record(None, NUMBERS, 1793800000)
        st = ww.record(st, NUMBERS, 1793800000 + 20 * 3600)
        self.assertEqual(ww.change(st), (None, {}))
        self.assertEqual(ww.change(None), (None, {}))

    def test_old_readings_one_a_day(self):
        st = None
        for h in range(0, 24 * 10, 6):
            st = ww.record(st, NUMBERS, 1793800000 + h * 3600)
        times = [t for t, _ in st["history"]]
        self.assertEqual(times, sorted(times))
        recent = [t for t in times if t >= st["at"] - ww.RECENT]
        self.assertEqual(len(recent), 9)  # every 6 hours over the last two days
        self.assertLessEqual(len(times) - len(recent), 9)

    def test_a_read_records_the_numbers(self):
        ws, site = ww.fresh(1793100000), Site()
        ww.poll(ws, get=site.get, now=1793800000)
        self.assertEqual(ws["stats"]["values"], NUMBERS)
        self.assertEqual(ws["stats"]["at"], 1793800000)
        self.assertEqual(len([u for u in site.asked if "filedetails/?id=" in u]), 1)  # no extra request

    def test_a_page_without_numbers_keeps_the_last_ones(self):
        ws, site = ww.fresh(1793100000), Site()
        ww.poll(ws, get=site.get, now=1793800000)
        site.pages["item"] = re.sub(r'<div class="workshopItemDetailsHeader">.*?</div>\n</div>', "",
                                    page("item.html"), flags=re.S).replace("stats_table", "x").replace(
                                    "parentCollectionsNumOthers", "x")
        ww.poll(ws, get=site.get, now=1793900000)
        self.assertEqual((ws["stats"]["at"], ws["failed"]), (1793800000, 1793900000))
        ww.poll(ws, get=Site().get, now=1794000000)
        self.assertNotIn("failed", ws)


class Parse(unittest.TestCase):
    def test_owner_and_contributors(self):
        owner, own = ww.accounts(page("item.html"))
        self.assertEqual(owner, "76561198099364305")
        self.assertEqual(own, {OWNER, CONTRIBUTOR})

    def test_a_changed_item_page_is_an_error_not_a_crash(self):
        with self.assertRaises(RuntimeError):
            ww.accounts("<html>nothing here</html>")

    def test_comments(self):
        got = ww.comments(json.loads(page("comments.json"))["comments_html"])
        self.assertEqual([c["id"] for c in got], ["900000000000000003", "900000000000000002",
                                                  "900000000000000001", "900000000000000000"])
        first = got[0]
        self.assertEqual((first["account"], first["name"], first["time"]), (380000001, "Player & One", 1793654299))
        self.assertTrue(first["text"].startswith("面板上的按钮能不能放大一点？ 小屏幕上看不清。"))
        self.assertNotIn("<", first["text"])
        self.assertNotIn("linkfilter", first["text"])  # the link's text is kept, not its target
        self.assertIn("旧评论早就有了", got[3]["text"])  # text after a nested quote is kept

    def test_topics(self):
        got = ww.topics(page("discussions.html"))
        self.assertEqual([(t["id"], t["replies"], t["last"]) for t in got],
                         [("800000000000000002", 2, 1793700000), ("800000000000000001", 0, 1792000000)])
        self.assertEqual(got[0]["title"], 'Crash when planning "two" cities')
        self.assertTrue(got[0]["url"].endswith("/discussion/3824473635/800000000000000002/"))

    def test_topic_page(self):
        op = ww.opening(page("topic.html"))
        self.assertEqual((op["account"], op["name"], op["time"]), (380000003, "Player Two", 1793650000))
        self.assertEqual(op["text"], "Two cities selected, the panel stops at 40%. log line Any idea?")
        replies = ww.comments(page("topic.html"))
        self.assertEqual([(r["account"], r["text"]) for r in replies],
                         [(CONTRIBUTOR, "Which leader?"), (380000003, "Rome, on a small map.")])


class Poll(unittest.TestCase):
    def setUp(self):
        self.site = Site()

    def test_new_posts_without_own_accounts(self):
        ws = ww.fresh(1793100000)
        out = ww.poll(ws, get=self.site.get, now=1793800000)
        self.assertEqual(len(out), 3, out)
        self.assertTrue(out[0].startswith("WORKSHOP COMMENT by Player & One (2026-11-02T21:18:19Z): 面板上"))
        self.assertTrue(out[0].endswith("/sharedfiles/filedetails/comments/3824473635#comment_900000000000000003"))
        self.assertTrue(out[1].startswith('WORKSHOP TOPIC in "Crash when planning "two" cities" by Player Two'))
        self.assertTrue(out[2].startswith('WORKSHOP REPLY in "Crash when planning "two" cities" by Player Two'))
        text = "\n".join(out)
        for word in ("Owner", "Contributor", "Which leader", "旧评论", "Old topic"):
            self.assertNotIn(word, text)  # own accounts; older than the start; a topic with no new post

    def test_each_post_once(self):
        ws = ww.fresh(1793100000)
        ww.poll(ws, get=self.site.get, now=1793800000)
        self.site.asked = []
        self.assertEqual(ww.poll(ws, get=self.site.get, now=1793900000), [])
        self.assertFalse(any("/discussion/" in u for u in self.site.asked))  # no new post: topic not read again

    def test_only_new_replies_are_read(self):
        ws = ww.fresh(1793100000)
        ww.poll(ws, get=self.site.get, now=1793800000)
        self.site.pages["discussions"] = self.site.pages["discussions"].replace(
            "> 2\t", "> 40\t").replace('data-timestamp="1793700000"', 'data-timestamp="1793750000"')
        self.site.asked = []
        ww.poll(ws, get=self.site.get, now=1793900000)
        self.assertEqual([u.rsplit("?", 1)[1] for u in self.site.asked if "/discussion/" in u],
                         ["ctp=1", "ctp=2", "ctp=3"])

    def test_a_topic_over_the_page_budget_waits_for_the_next_check(self):
        saved, ww.TOPIC_PAGES = ww.TOPIC_PAGES, 0
        try:
            ws = ww.fresh(1793100000)
            out = ww.poll(ws, get=self.site.get, now=1793800000)
            self.assertFalse(any("TOPIC" in line for line in out))
            self.assertEqual(ws["topics"], {})
        finally:
            ww.TOPIC_PAGES = saved
        self.assertEqual(len(ww.poll(ws, get=self.site.get, now=1793900000)), 2)

    def test_a_failure_leaves_the_state_alone(self):
        ws = ww.fresh(1793100000)
        self.site.down = True
        with self.assertRaises(RuntimeError):
            ww.poll(ws, get=self.site.get, now=1793800000)
        self.assertEqual(ws, ww.fresh(1793100000))

    def test_an_error_answer_is_an_error(self):
        self.site.pages["comments"] = json.dumps({"success": False, "error": "busy"})
        with self.assertRaises(RuntimeError):
            ww.poll(ww.fresh(1793100000), get=self.site.get, now=1793800000)


class Watch(unittest.TestCase):
    """The Workshop part of watch_issues: due times, the held list, never waking anyone."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.saved = (wi.HELD, wi.ITEM)
        wi.HELD, wi.ITEM = os.path.join(self.dir, "held.log"), ww.ITEM
        self.site, self.clock = Site(), [1793800000]

    def tearDown(self):
        wi.HELD, wi.ITEM = self.saved

    def run_once(self, state):
        wi.workshop(state, 2700, clock=lambda: self.clock[0], get=self.site.get)

    def held(self):
        if not os.path.exists(wi.HELD):
            return ""
        with open(wi.HELD, encoding="utf-8") as f:
            return f.read()

    def test_new_posts_go_to_the_held_list(self):
        state = {"workshop": ww.fresh(1793100000)}
        self.run_once(state)
        self.assertEqual(self.held().count(" WORKSHOP "), 3)
        self.assertEqual(state["workshop"]["next"], 1793800000 + 2700)

    def test_not_read_before_it_is_due(self):
        state = {"workshop": ww.fresh(1793100000)}
        self.run_once(state)
        self.site.asked = []
        self.clock[0] += 600
        self.run_once(state)
        self.assertEqual(self.site.asked, [])
        self.clock[0] += 2100
        self.run_once(state)
        self.assertNotEqual(self.site.asked, [])

    def test_a_failure_is_tried_again_sooner_and_does_not_raise(self):
        state = {"workshop": ww.fresh(1793100000)}
        self.site.down = True
        self.run_once(state)
        self.assertEqual(state["workshop"]["next"], 1793800000 + wi.WORKSHOP_RETRY)
        self.assertEqual(state["workshop"]["failed"], 1793800000)
        self.assertNotIn("stats", state["workshop"])
        self.assertEqual(self.held(), "")

    def test_a_first_run_starts_from_now(self):
        state = {}
        self.run_once(state)
        self.assertEqual(state["workshop"]["since"], 1793800000)
        self.assertEqual(self.held(), "")  # everything on the stored pages is older

    def test_turned_off(self):
        wi.ITEM = ""
        state = {}
        self.run_once(state)
        self.assertEqual((state, self.site.asked), ({}, []))

    def test_held_counts_the_workshop_lines(self):
        with open(wi.HELD, "w", encoding="utf-8") as f:
            f.write("t NEW ISSUE #1 by a: x u\nt WORKSHOP COMMENT by b (t): y u\n")
        from io import StringIO
        out, real = StringIO(), sys.stdout
        sys.stdout = out
        try:
            wi.held(False)
        finally:
            sys.stdout = real
        self.assertIn("(1 from the Steam Workshop)", out.getvalue())


if __name__ == "__main__":
    unittest.main()
