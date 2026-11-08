"""Offline tests of tools/refresh_results.py's check stamp (#302): the release's development-set check is
skipped when nothing the plans depend on changed since a PR ran it; and of the check itself (#327: both
files of the development set, the gain this mod reports against the judge's; #350: the new coverage too).

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
    "SmartDistrictPlanner/Scripts/SDP_PageKit.lua": "kit",
    "SmartDistrictPlanner/Scripts/SDP_PageMulti.lua": "multi page",
    "SmartDistrictPlanner/Scripts/SDP_PageSites.lua": "sites page",
    "SmartDistrictPlanner/Scripts/SDP_Preview.lua": "preview",
    "SmartDistrictPlanner/UI/SDP_Panel.lua": "panel",
    "tools/compare.mjs": "compare",
    "tools/validate.py": "validate",
    "tests/compare/cmp_sdp.lua": "harness",
    "tests/compare/scenes/a/S01.txt": "scene",
    "tests/compare/results/full_rejudged.jsonl": '{"scenario": "S01", "planner": "sdp", "score": {"gain": 3}}\n',
    "tests/compare/results/panel_default.jsonl":
        '{"scenario": "S01", "planner": "sdp", "variant": "PANEL", "score": {"gain": 3}}\n',
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
        # The panel and the single-city tab hold the defaults the PANEL rows are solved with (#327).
        self.assertEqual(rr.solved_by(rr.present()), sorted([
            "SmartDistrictPlanner/Scripts/SDP_Solver.lua", "tools/compare.mjs", "tests/compare/cmp_sdp.lua",
            "tests/compare/scenes/a/S01.txt", "tests/compare/results/full_rejudged.jsonl",
            "tests/compare/results/panel_default.jsonl", "SmartDistrictPlanner/UI/SDP_Panel.lua",
            "SmartDistrictPlanner/Scripts/SDP_PageSingle.lua", "SmartDistrictPlanner/Scripts/SDP_PageKit.lua"]))

    def test_interface_and_other_files_leave_the_digest(self):
        before = rr.digest()
        for rel in ("SmartDistrictPlanner/Scripts/SDP_PageMulti.lua", "SmartDistrictPlanner/Scripts/SDP_PageSites.lua",
                    "SmartDistrictPlanner/Scripts/SDP_Preview.lua", "tools/validate.py", "tests/compare/results/land.jsonl"):
            self.put(rel, "changed")
        self.assertEqual(rr.digest(), before)

    def test_line_ends_do_not_count(self):
        self.put("tools/compare.mjs", "a\nb\n")
        before = rr.digest()
        self.put("tools/compare.mjs", "a\r\nb\r\n")
        self.assertEqual(rr.digest(), before)

    def test_solver_harness_scene_and_rows_change_it(self):
        for rel in ("SmartDistrictPlanner/Scripts/SDP_Solver.lua", "tests/compare/cmp_sdp.lua",
                    "tests/compare/scenes/a/S01.txt", "tests/compare/results/full_rejudged.jsonl",
                    "tests/compare/results/panel_default.jsonl", "SmartDistrictPlanner/UI/SDP_Panel.lua",
                    "SmartDistrictPlanner/Scripts/SDP_PageSingle.lua"):
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
        self.put("SmartDistrictPlanner/Scripts/SDP_PageMulti.lua", "interface only")
        self.assertIsNotNone(rr.unchanged_since_check())
        self.put("SmartDistrictPlanner/Scripts/SDP_Solver.lua", "solver changed")
        self.assertIsNone(rr.unchanged_since_check())

    def run_main(self, argv, reported=None, covered=None):
        calls = []
        old_argv, old_rerun = sys.argv, rr.rerun
        sys.argv = ["refresh_results.py"] + argv

        def rerun(path, jobs):
            calls.append(path)
            variant = "PANEL" if path.endswith("panel_default.jsonl") else ""
            row = {"scenario": "S01", "planner": "sdp", "variant": variant, "score": {"gain": 3}}
            if reported is not None:
                row["plan"] = {"stats": {"sdpGain": reported}}
            if covered is not None:
                row["plan"] = {"stats": {"sdpGain": 3, "sdpCovered": covered[0]}}
                row["score"]["coverageGain"] = covered[1]
            return [], {("S01", "sdp", variant): row}
        rr.rerun = rerun
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
        self.assertEqual((code, len(calls)), (0, 2), "no stamp: runs both files of the development set")
        self.assertIsNotNone(rr.read_stamp(), "a finished check of the development set writes the stamp")
        code, calls, out = self.run_main(["--check", "--if-changed"])
        self.assertEqual((code, calls), (0, []))
        self.assertIn("skipped", out)
        code, calls, _ = self.run_main(["--check"])
        self.assertEqual(len(calls), 2, "without --if-changed it always runs")
        self.put("tests/compare/cmp_sdp.lua", "judge changed")
        code, calls, _ = self.run_main(["--check", "--if-changed"])
        self.assertEqual(len(calls), 2, "a changed file: runs")
        self.assertEqual(rr.read_stamp()["rows"], 2, "the stamp counts the rows of both files")

    def test_a_reported_gain_not_the_judges_fails(self):
        """The gain this mod reports for a plan is the judge's (AGENTS.md section 6), in both files (#327)."""
        self.patch_dev(os.path.join(self.root, "tests", "compare", "results", "full_rejudged.jsonl"))
        code, _, out = self.run_main(["--check"], reported=3)
        self.assertEqual(code, 0, out)
        self.assertEqual(rr.read_stamp()["mismatched"], 0)
        code, _, out = self.run_main(["--check"], reported=2.5)
        self.assertEqual(code, 1)
        self.assertIn("REPORTED S01 PANEL: this mod 2.5, the judge 3", out)
        self.assertEqual(rr.read_stamp()["mismatched"], 2)
        code, calls, _ = self.run_main(["--check", "--if-changed"])
        self.assertEqual((code, calls), (1, []), "a skipped check keeps the stamped mismatch")

    def test_a_reported_coverage_not_the_judges_fails(self):
        """The new coverage this mod reports is the judge's coverageGain too (#350: RP16 reported 0, judged 6)."""
        self.patch_dev(os.path.join(self.root, "tests", "compare", "results", "full_rejudged.jsonl"))
        code, _, out = self.run_main(["--check"], covered=(6, 6))
        self.assertEqual(code, 0, out)
        self.assertEqual(rr.read_stamp()["mismatched"], 0)
        code, _, out = self.run_main(["--check"], covered=(0, 6))
        self.assertEqual(code, 1, out)
        self.assertIn("REPORTED coverage S01 PANEL: this mod 0, the judge 6", out)
        self.assertEqual(rr.read_stamp()["mismatched"], 2)

    def test_a_skipped_check_keeps_the_stamped_failure(self):
        """A check that found lower gains stamps them; skipping it on a retry exits 1 too (Codex, PR 303)."""
        self.patch_dev(os.path.join(self.root, "tests", "compare", "results", "full_rejudged.jsonl"))
        rr.write_stamp({"rows": 270, "lower": 1, "new_violations": 0})
        code, calls, out = self.run_main(["--check", "--if-changed"])
        self.assertEqual((code, calls), (1, []))
        self.assertIn("skipped", out)
        rr.write_stamp({"rows": 270, "lower": 0, "new_violations": 2})
        self.assertEqual(self.run_main(["--check", "--if-changed"])[0], 1)

    def patch_dev(self, dev):
        self.addCleanup(setattr, rr, "DEV_SET", rr.DEV_SET)
        self.addCleanup(setattr, rr, "DEV_SETS", rr.DEV_SETS)
        rr.DEV_SET = dev
        rr.DEV_SETS = [dev, os.path.join(os.path.dirname(dev), "panel_default.jsonl")]


if __name__ == "__main__":
    unittest.main()
