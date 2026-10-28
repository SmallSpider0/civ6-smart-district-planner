"""Offline tests of tools/status/sync.py: release summaries, the hand-written notes' field check,
bundling, the private-string check, pushing only with a push host configured, and the command line
(unknown words and flags are refused and create nothing).

    python3 -I -m unittest discover -s tests/tools -v
"""
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                                "tools", "status"))
import sync  # noqa: E402


NOTES_SITES = """## Smart District Planner v1.5.4

English text first.

## 自 v1.5.3 以来的变化

- 选城址页：城址钉取消勾选后不再留在地图上。
- 单城页：区域明细按产出分开列出（#129）；悬停看来源。
- **多城页**的城市小计改为只算本城。

## 安装

- 这一段不算。
"""

NOTES_LONG = """## 自 v1.5.0 以来的变化

- 求解时把已有的区域、奇观和地图钉都当作固定的邻居一起算，这样给出的方案和游戏里看到的加成完全一致，不会再出现差一两点的情况。
- 第二项。
- 第三项。
- 第四项。
- 第五项。
- 第六项。
- 第七项。
"""


class ReleaseSummary(unittest.TestCase):
    def test_prefix_stays_with_its_item(self):
        self.assertEqual(sync.release_summary(NOTES_SITES),
                         "选城址页：城址钉取消勾选后不再留在地图上；单城页：区域明细按产出分开列出；多城页")

    def test_long_item_is_cut_and_list_folds_after_six(self):
        s = sync.release_summary(NOTES_LONG)
        parts = s.rstrip("…").split("；")
        self.assertEqual(parts[0], "求解时把已有的区域、奇观和地图钉都当作固定的邻居一起算")
        self.assertEqual(len(parts), 6)
        self.assertTrue(s.endswith("……"))

    def test_no_changes_section(self):
        self.assertEqual(sync.release_summary("## Something else\n- item\n"), "")
        self.assertEqual(sync.release_summary(None), "")


class TempShared(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = mock.patch.object(sync, "MANUAL", os.path.join(self.tmp.name, "status", "manual.json"))
        p.start()
        self.addCleanup(p.stop)

    def manual(self):
        with open(sync.MANUAL, encoding="utf-8") as fh:
            return json.load(fh)


class FieldCheck(TempShared):
    def test_unknown_field_refused(self):
        with self.assertRaises(SystemExit):
            sync.edit_manual("set", "decisions/x", {"title": "t", "state": "open"})
        self.assertFalse(os.path.exists(sync.MANUAL))

    def test_releases_refused(self):
        for op, data in (("set", {"summary": "s"}), ("update", {"summary": "s"}), ("delete", None)):
            with self.assertRaises(SystemExit):
                sync.edit_manual(op, "releases/v1.6.0", data)

    def test_bad_paths_refused(self):
        for path in ("meta/page", "decisions", "decisions/a/b", "other/x"):
            with self.assertRaises(SystemExit):
                sync.edit_manual("set", path, {"title": "t"})

    def test_set_needs_required_fields(self):
        with self.assertRaises(SystemExit):
            sync.edit_manual("set", "decisions/x", {"status": "open"})
        with self.assertRaises(SystemExit):
            sync.edit_manual("set", "jobs/x", {"where": "here"})
        sync.edit_manual("set", "milestones/x", {"goal": "g"})  # milestones need nothing
        self.assertEqual(self.manual()["milestones"]["x"], {"goal": "g"})

    def test_update_merges_and_null_deletes(self):
        sync.edit_manual("set", "decisions/x", {"title": "t", "status": "open", "recommendation": "A"})
        sync.edit_manual("update", "decisions/x", {"status": "done", "doneAt": "2026-10-28", "recommendation": None})
        d = self.manual()
        self.assertEqual(d["decisions"]["x"], {"title": "t", "status": "done", "doneAt": "2026-10-28"})
        self.assertTrue(d["meta"]["page"]["updated"])
        with self.assertRaises(SystemExit):  # update may not blank a required field
            sync.edit_manual("update", "decisions/x", {"title": ""})

    def test_delete(self):
        sync.edit_manual("set", "jobs/a", {"what": "w"})
        sync.edit_manual("delete", "jobs/a")
        self.assertEqual(self.manual()["jobs"], {})


class Bundle(TempShared):
    def fake_out(self):
        out = os.path.join(self.tmp.name, "out")
        for sub, name, doc in (("machines", "macbook", {"name": "m1", "running": [], "cap": 4}),
                               ("work", "releases", {"items": [{"version": "v1.6.0", "summary": "s"}]}),
                               ("work", "issues", {"items": [{"n": 1}]})):
            os.makedirs(os.path.join(out, sub), exist_ok=True)
            with open(os.path.join(out, sub, name + ".json"), "w", encoding="utf-8") as fh:
                json.dump(doc, fh)
        return out

    def test_bundle_collects_everything(self):
        out = self.fake_out()
        sync.edit_manual("set", "decisions/b", {"title": "second", "status": "open"})
        sync.edit_manual("set", "decisions/a", {"title": "first", "status": "open"})
        text = sync.bundle(out)
        with open(os.path.join(out, "status.json"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), text)
        b = json.loads(text)
        self.assertEqual([d["id"] for d in b["decisions"]], ["a", "b"])
        self.assertEqual([m["id"] for m in b["machines"]], ["macbook"])
        self.assertEqual(b["work"]["releases"]["items"][0]["version"], "v1.6.0")
        self.assertIsNone(b["work"]["branches"])
        self.assertEqual(b["jobs"], [])
        self.assertTrue(b["meta"]["updated"])


class Private(unittest.TestCase):
    def test_generic_patterns(self):
        for s in ("/Users/someone/x", "/home/someone", "/private/tmp/x", "/var/lib/x", "/etc/hosts",
                  "~/.ssh/key", "10.1.2.3", "someone@example.org"):
            self.assertTrue(sync.private_hits('{"a":"%s"}' % s, {}), s)

    def test_clean_text(self):
        text = json.dumps({"v": "v1.5.4", "pr": "#148", "t": "2026-10-28 12:00", "b": "mac/status-in-repo",
                           "p": "tools/status/sync.py", "c": "1.2.3"}, ensure_ascii=False)
        self.assertEqual(sync.private_hits(text, {}), [])

    def test_config_words(self):
        st = {"private_words": ["alice", "build-box"], "push_host": "page-push", "page_host": "status.example.net"}
        self.assertTrue(sync.private_hits('{"o":"Alice"}', st))
        self.assertTrue(sync.private_hits('{"o":"ran on BUILD-BOX"}', st))
        self.assertTrue(sync.private_hits('{"o":"page-push"}', st))
        self.assertTrue(sync.private_hits('{"o":"status.example.net"}', st))
        self.assertEqual(sync.private_hits('{"o":"bob"}', st), [])
        self.assertEqual(sync.private_hits('{"o":"alice"}', {}), [])  # only with the config

    def test_settings_ignores_a_bad_status_entry(self):
        self.assertEqual(sync.settings({}), {})
        self.assertEqual(sync.settings({"status": "x"}), {})
        self.assertEqual(sync.settings({"status": {"push_host": "h"}}), {"push_host": "h"})


class Push(TempShared):
    def setUp(self):
        super().setUp()
        self.out = os.path.join(self.tmp.name, "out")
        os.makedirs(self.out)
        self.sent = []
        for target, fake in (("send", lambda host, name, path: self.sent.append((host, name))),
                             ("PAGE", os.path.join(self.tmp.name, "page.html"))):
            p = mock.patch.object(sync, target, fake)
            p.start()
            self.addCleanup(p.stop)
        with open(sync.PAGE, "w") as fh:
            fh.write("<!doctype html>")

    def config(self, cfg):
        p = mock.patch.object(sync, "config", lambda: cfg)
        p.start()
        self.addCleanup(p.stop)

    def test_no_push_without_config(self):
        self.config({})
        with mock.patch.object(sync.subprocess, "run") as run:
            sync.push(self.out)
        run.assert_not_called()
        self.assertEqual(self.sent, [])
        self.assertTrue(os.path.exists(os.path.join(self.out, "status.json")))

    def test_push_with_host_then_only_on_change(self):
        self.config({"status": {"push_host": "page-push"}})
        sync.push(self.out)
        self.assertEqual(self.sent, [("page-push", "index.html"), ("page-push", "status.json")])
        sync.push(self.out)
        self.assertEqual(len(self.sent), 2)  # nothing changed, PUSH_EVERY not passed
        sync.edit_manual("set", "jobs/a", {"what": "w"})
        sync.push(self.out)
        self.assertEqual(self.sent[-1], ("page-push", "status.json"))

    def test_private_string_stops_the_push(self):
        self.config({"status": {"push_host": "page-push", "private_words": ["alice"]}})
        sync.edit_manual("set", "jobs/a", {"what": "alice's job"})
        with self.assertRaises(SystemExit) as e:
            sync.push(self.out)
        self.assertEqual(e.exception.code, 4)
        self.assertEqual(self.sent, [])


class Arguments(unittest.TestCase):
    """An unknown word or flag exits with the usage and creates nothing (2026-10-27: `sync.py list`
    took "list" for the output directory and left a list/ folder of snapshots in the repository)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cwd = os.path.join(self.tmp.name, "cwd")
        os.makedirs(self.cwd)
        old = os.getcwd()
        os.chdir(self.cwd)
        self.addCleanup(os.chdir, old)
        for target, value in (("OUT", os.path.join(self.tmp.name, "out")),
                              ("MANUAL", os.path.join(self.tmp.name, "manual.json"))):
            p = mock.patch.object(sync, target, value)
            p.start()
            self.addCleanup(p.stop)
        for target in ("macbook", "macmini", "full", "push", "edit_manual"):
            p = mock.patch.object(sync, target, side_effect=AssertionError(target + " must not run"))
            p.start()
            self.addCleanup(p.stop)

    def refused(self, argv):
        err = io.StringIO()
        with redirect_stderr(err), self.assertRaises(SystemExit) as e:
            sync.main(argv)
        self.assertEqual(e.exception.code, 2, argv)
        self.assertIn("usage:", err.getvalue())
        self.assertEqual(os.listdir(self.tmp.name), ["cwd"], argv)  # neither OUT nor manual.json
        self.assertEqual(os.listdir(self.cwd), [], argv)

    def test_unknown_word(self):
        for argv in (["list"], ["--quick", "list"], ["status", "--push"]):
            self.refused(argv)

    def test_unknown_flag(self):
        for argv in (["--bogus"], ["--quick", "-x"], ["--out"], ["--out", "--push"], ["--out="]):
            self.refused(argv)

    def test_edits_check_their_arguments(self):
        for argv in (["set", "jobs/a"], ["delete"], ["delete", "jobs/a", "x"], ["get", "a", "b"],
                     ["update", "jobs/a", "{}", "--push"]):
            self.refused(argv)

    def test_known_arguments(self):
        d = os.path.join(self.tmp.name, "elsewhere")
        self.assertEqual(sync.parse_args(["--out", d, "--push", "--quick"]),
                         (None, [], {"out": d, "push": True, "quick": True}))
        self.assertEqual(sync.parse_args(["--out=" + d])[2]["out"], d)
        self.assertEqual(sync.parse_args([]), (None, [], {"out": sync.OUT, "push": False, "quick": False}))
        self.assertEqual(sync.parse_args(["get"]), ("get", [], {}))
        self.assertEqual(sync.parse_args(["delete", "jobs/a"]), ("delete", ["jobs/a"], {}))

    def test_watch_passes_the_folder_as_an_option(self):
        import watch
        with mock.patch.object(watch.subprocess, "run") as run:
            watch.sync("/some/dir", quick=True)
        cmd = run.call_args[0][0]
        self.assertEqual(sync.parse_args(cmd[3:])[2], {"out": "/some/dir", "push": True, "quick": True})


if __name__ == "__main__":
    unittest.main()
