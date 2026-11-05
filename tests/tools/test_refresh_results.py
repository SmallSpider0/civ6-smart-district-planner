"""Offline tests of tools/refresh_results.py's check stamp (#302): the release's development-set check is
skipped when nothing the plans depend on changed since a PR ran it.

    python3 -I -m unittest discover -s tests/tools -p test_refresh_results.py
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import refresh_results as rr  # noqa: E402

FILES = {
    "SmartDistrictPlanner/Scripts/SDP_Solver.lua": "solver",
    "SmartDistrictPlanner/Scripts/SDP_PageSingle.lua": "page",
    "SmartDistrictPlanner/Scripts/SDP_Preview.lua": "preview",
    "SmartDistrictPlanner/UI/SDP_Panel.lua": "panel",
    "tools/compare.mjs": "compare",
    "tools/validate.py": "validate",
    "tests/compare/cmp_sdp.lua": "harness",
    "tests/compare/scenes/a/S01.txt": "scene",
    "tests/compare/results/full_rejudged.jsonl": '{"scenario": "S01", "planner": "sdp", "score": {"gain": 3}}\n',
    "tests/compare/results/land.jsonl": "{}\n",
}


class Stamp(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name
        for rel, text in FILES.items():
            self.put(rel, text)
        self.stamp = os.path.join(self.root, "tests", "compare", "results", "check_stamp.json")
        for name, value in (("ROOT", self.root), ("CHECK_STAMP", self.stamp)):
            self.addCleanup(setattr, rr, name, getattr(rr, name))
            setattr(rr, name, value)

    def put(self, rel, text, mode="w"):
        path = os.path.join(self.root, *rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode, newline="") as fh:
            fh.write(text)

    def test_which_files_count(self):
        self.assertEqual(rr.solved_by(rr.present()), sorted([
            "SmartDistrictPlanner/Scripts/SDP_Solver.lua", "tools/compare.mjs", "tests/compare/cmp_sdp.lua",
            "tests/compare/scenes/a/S01.txt", "tests/compare/results/full_rejudged.jsonl"]))

    def test_interface_and_other_files_leave_the_digest(self):
        before = rr.digest()
        for rel in ("SmartDistrictPlanner/Scripts/SDP_PageSingle.lua", "SmartDistrictPlanner/Scripts/SDP_Preview.lua",
                    "SmartDistrictPlanner/UI/SDP_Panel.lua", "tools/validate.py", "tests/compare/results/land.jsonl"):
            self.put(rel, "changed")
        self.assertEqual(rr.digest(), before)

    def test_line_ends_do_not_count(self):
        self.put("tools/compare.mjs", "a\nb\n")
        before = rr.digest()
        self.put("tools/compare.mjs", "a\r\nb\r\n")
        self.assertEqual(rr.digest(), before)

    def test_solver_harness_scene_and_rows_change_it(self):
        for rel in ("SmartDistrictPlanner/Scripts/SDP_Solver.lua", "tests/compare/cmp_sdp.lua",
                    "tests/compare/scenes/a/S01.txt", "tests/compare/results/full_rejudged.jsonl"):
            before = rr.digest()
            self.put(rel, "changed " + rel)
            self.assertNotEqual(rr.digest(), before, rel)
        before = rr.digest()
        self.put("SmartDistrictPlanner/Scripts/SDP_New.lua", "new")
        self.assertNotEqual(rr.digest(), before, "a new solver file")

    def test_unchanged_since_check(self):
        self.assertIsNone(rr.unchanged_since_check(), "no stamp yet")
        rr.write_stamp({"rows": 270, "lower": 0, "new_violations": 0})
        self.assertEqual(rr.unchanged_since_check()["rows"], 270)
        self.put("SmartDistrictPlanner/Scripts/SDP_PageSingle.lua", "interface only")
        self.assertIsNotNone(rr.unchanged_since_check())
        self.put("SmartDistrictPlanner/Scripts/SDP_Solver.lua", "solver changed")
        self.assertIsNone(rr.unchanged_since_check())

    def run_main(self, argv):
        calls = []
        old_argv, old_rerun = sys.argv, rr.rerun
        sys.argv = ["refresh_results.py"] + argv
        row = {"scenario": "S01", "planner": "sdp", "score": {"gain": 3}}
        rr.rerun = lambda path, jobs: calls.append(path) or ([], {("S01", "sdp", ""): row})
        self.addCleanup(setattr, rr, "WORK", rr.WORK)
        rr.WORK = os.path.join(self.root, "logs", "refresh")
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                code = rr.main()
        finally:
            sys.argv, rr.rerun = old_argv, old_rerun
        return code, calls, out.getvalue()

    def test_release_check_skips_or_runs(self):
        dev = os.path.join(self.root, "tests", "compare", "results", "full_rejudged.jsonl")
        self.patch_dev(dev)
        code, calls, _ = self.run_main(["--check", "--if-changed"])
        self.assertEqual((code, len(calls)), (0, 1), "no stamp: runs")
        self.assertIsNotNone(rr.read_stamp(), "a finished check of the development set writes the stamp")
        code, calls, out = self.run_main(["--check", "--if-changed"])
        self.assertEqual((code, calls), (0, []))
        self.assertIn("skipped", out)
        code, calls, _ = self.run_main(["--check"])
        self.assertEqual(len(calls), 1, "without --if-changed it always runs")
        self.put("tests/compare/cmp_sdp.lua", "judge changed")
        code, calls, _ = self.run_main(["--check", "--if-changed"])
        self.assertEqual(len(calls), 1, "a changed file: runs")

    def patch_dev(self, dev):
        self.addCleanup(setattr, rr, "DEV_SET", rr.DEV_SET)
        rr.DEV_SET = dev


if __name__ == "__main__":
    unittest.main()
