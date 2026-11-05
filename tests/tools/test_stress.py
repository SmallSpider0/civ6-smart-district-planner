"""Offline tests of tools/stress.py's save tests (#302): the in-game cases that need a late save with many
cities ran only in run_tests.py's full run, on a new game with one city, and always skipped there.

    python3 -I -m unittest discover -s tests/tools -p test_stress.py
"""
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import stress  # noqa: E402


class SaveTests(unittest.TestCase):
    def result(self, code, output):
        return stress.save_test_result("tests/test_x.lua", None, code, output)["Problem"]

    def test_passed(self):
        self.assertIsNone(self.result(0, "x\nrun_tests: 2 passed, 0 failed, 0 skipped, 0 errors\n"))

    def test_a_skip_on_the_save_is_a_problem(self):
        self.assertEqual(self.result(0, "run_tests: 1 passed, 0 failed, 1 skipped, 0 errors\n"), "skipped a case")

    def test_failures_nothing_run_and_no_summary(self):
        self.assertEqual(self.result(1, "run_tests: 1 passed, 1 failed, 0 skipped, 0 errors\n"), "failed")
        self.assertEqual(self.result(0, "run_tests: 0 passed, 0 failed, 0 skipped, 0 errors\n"), "ran nothing")
        self.assertEqual(self.result(4, "sdplock: busy\n"), "no summary (exit 4)")

    def test_the_cases_exist(self):
        """Each listed file exists and its filter picks at least one test of it: a renamed case would
        otherwise only show as "ran nothing" in the release run."""
        import run_tests
        for path, name_filter, setup in stress.SAVE_TESTS:
            with open(os.path.join(ROOT, path), encoding="utf-8") as fh:
                names = run_tests.test_names(fh.read())
            self.assertTrue([n for n in names if not name_filter or name_filter in n], path)
            if setup:
                with open(stress.STEPS, encoding="utf-8") as fh:
                    self.assertIn("function S.%s(" % setup.split(".")[1].split("(")[0], fh.read(), setup)
        self.assertTrue(set(stress.SAVE_TESTS_ON) <= set(stress.SCENARIOS))


if __name__ == "__main__":
    unittest.main()
