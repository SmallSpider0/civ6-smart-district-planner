"""Offline tests of tools/run_tests.py's @max_seconds_each (#302: the 3-, 4- and 8-district timing files became
one file whose tests are each timed on their own), the panel's defaults before each file, the layout self-check's
line and --shortest-window (#327). The game is a fake tuner.

    python3 -I -m unittest discover -s tests/tools -p test_run_tests.py
"""
import contextlib
import io
import os
import re
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import run_tests  # noqa: E402

BODY = '''-- @state SDP_Panel
-- @max_seconds_each 2.5
local test, T = ...
test("solve 3 districts", function() end)
test("solve 3 districts and more", function() end)
  test( "slow one", function() end)
'''


class FakeTuner:
    """Answers an exec as the harness would: PASS for each test the code's filter selects, after `seconds`.
    Other code (the panel's defaults, fixtures) is kept in `other`; `logs` maps a test name to lines printed
    before its result."""

    def __init__(self, seconds, logs=None, other_output=None):
        self.seconds, self.calls, self.now = seconds, [], 0.0
        self.logs, self.other_output, self.other, self.order = logs or {}, other_output or [], [], []

    def request(self, req):
        code = req["code"]
        if "local __filter" not in code:
            self.other.append((req["state"], code))
            self.order.append("other")
            return {"ok": True, "output": list(self.other_output)}
        self.order.append("file")
        name = re.search(r"^local __filter = (.*)$", code, re.M).group(1)
        exact = re.search(r"^local __exact = (\w+)$", code, re.M).group(1) == "true"
        name = None if name == "nil" else name[1:-1]
        self.calls.append((name, exact))
        names = run_tests.test_names(code)
        chosen = [n for n in names if name is None or (n == name if exact else name in n)]
        self.now += self.seconds.get(name, 0.1)
        out = []
        for n in chosen:
            out += self.logs.get(n, [])
            out.append(run_tests.PREFIX + "PASS" + run_tests.SEP + n)
        return {"ok": True, "output": out}


class FileRun(unittest.TestCase):
    def run_body(self, body, seconds, name_filter=None, **fake_args):
        shortest = fake_args.pop("shortest", False)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "test_x.lua")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        fake = FakeTuner(seconds, **fake_args)
        self.fake = fake
        old = run_tests.civ6tuner.request, run_tests.time.monotonic
        run_tests.civ6tuner.request, run_tests.time.monotonic = fake.request, lambda: fake.now
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                counts, problem = run_tests.run_file(path, name_filter, False, shortest)
        finally:
            run_tests.civ6tuner.request, run_tests.time.monotonic = old
        return counts, problem, fake.calls, out.getvalue()


class EachTest(FileRun):

    def test_names(self):
        self.assertEqual(run_tests.test_names(BODY), ["solve 3 districts", "solve 3 districts and more", "slow one"])

    def test_each_test_runs_alone_with_its_own_limit(self):
        counts, problem, calls, out = self.run_body(BODY, {"slow one": 3.0, "solve 3 districts": 2.0,
                                                           "solve 3 districts and more": 2.0})
        self.assertIsNone(problem)
        self.assertEqual(calls, [("solve 3 districts", True), ("solve 3 districts and more", True),
                                 ("slow one", True)])
        # each passes once (the exact filter does not pick the longer name twice); only the slow one is too slow
        self.assertEqual((counts["PASS"], counts["FAIL"]), (3, 1))
        self.assertIn("took 3.00s, limit 2.5s", out)

    def test_name_filter_narrows_the_runs(self):
        _c, _p, calls, _o = self.run_body(BODY, {}, name_filter="slow")
        self.assertEqual(calls, [("slow one", True)])

    def test_whole_file_limit_unchanged(self):
        body = BODY.replace("@max_seconds_each", "@max_seconds")
        counts, _p, calls, out = self.run_body(body, {None: 3.0})
        self.assertEqual(calls, [(None, False)])
        self.assertEqual((counts["PASS"], counts["FAIL"]), (3, 1))


class PanelDefaultsTest(FileRun):
    """#327: every file starts on the panel's defaults; a layout overflow line fails the test it shows in."""

    def test_defaults_run_in_the_panel_state_before_the_file(self):
        counts, problem, _calls, _out = self.run_body(BODY.replace("@max_seconds_each 2.5", "@timeout 30"), {})
        self.assertIsNone(problem)
        self.assertEqual(self.fake.order, ["other", "file"])
        state, code = self.fake.other[0]
        self.assertEqual(state, "SDP_Panel")
        self.assertIn("SDP_Panel.Defaults()", code)
        self.assertNotIn("WINDOW_MIN", code)
        self.assertEqual(counts["PASS"], 3)

    def test_defaults_come_before_the_setup(self):
        body = "-- @state SDP_Panel\n-- @setup SDP_Panel tests/fixtures/reselect_city.lua\n" + BODY.split("\n", 2)[2]
        self.run_body(body, {})
        self.assertIn("SDP_Panel.Defaults()", self.fake.other[0][1])
        self.assertNotIn("SDP_Panel.Defaults()", self.fake.other[1][1])  # the fixture itself

    def test_an_overflow_line_fails_the_test_it_shows_in(self):
        line = run_tests.OVERFLOW + " MULTI: the body 477 does not fit the page 450"
        counts, _p, _c, out = self.run_body(BODY.replace("@max_seconds_each 2.5", "@timeout 30"), {},
                                            logs={"solve 3 districts and more": [line]})
        self.assertEqual((counts["PASS"], counts["FAIL"]), (2, 1))
        self.assertIn("FAIL   solve 3 districts and more", out)
        self.assertIn(line, out)

    def test_an_overflow_while_resetting_fails_the_file(self):
        line = run_tests.OVERFLOW + " SINGLE: the body 700 does not fit the page 540"
        counts, _p, _c, out = self.run_body(BODY.replace("@max_seconds_each 2.5", "@timeout 30"), {},
                                            other_output=[line])
        self.assertEqual((counts["PASS"], counts["FAIL"]), (3, 1))
        self.assertIn("(layout) panel defaults", out)

    def test_shortest_window_fits_the_window_at_its_minimum_first(self):
        self.run_body(BODY.replace("@max_seconds_each 2.5", "@timeout 30"), {}, shortest=True)
        code = self.fake.other[0][1]
        self.assertIn("SDP_UI.WINDOW_MIN", code)
        self.assertLess(code.index("WINDOW_MIN"), code.index("SDP_Panel.Defaults()"))

    def test_shortest_window_gives_the_screen_window_back_after_the_run(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "test_x.lua")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(BODY.replace("@max_seconds_each 2.5", "@timeout 30"))
        fake = FakeTuner({})
        saved = (run_tests.civ6tuner.request, run_tests.sdplock.claim_or_exit, run_tests.deployed_differences,
                 run_tests.workshop_copy)
        run_tests.civ6tuner.request = fake.request
        run_tests.sdplock.claim_or_exit = lambda *a: None
        run_tests.deployed_differences = lambda: []
        run_tests.workshop_copy = lambda: None
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                code = run_tests.main(["--shortest-window", path])
        finally:
            (run_tests.civ6tuner.request, run_tests.sdplock.claim_or_exit, run_tests.deployed_differences,
             run_tests.workshop_copy) = saved
        self.assertEqual(code, 0)
        self.assertIn("SDP_TestWindowHeight = nil", fake.other[-1][1])


if __name__ == "__main__":
    unittest.main()
