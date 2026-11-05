"""Offline tests of tools/run_tests.py's @max_seconds_each (#302: the 3-, 4- and 8-district timing files became
one file whose tests are each timed on their own). The game is a fake tuner.

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
    """Answers an exec as the harness would: PASS for each test the code's filter selects, after `seconds`."""

    def __init__(self, seconds):
        self.seconds, self.calls, self.now = seconds, [], 0.0

    def request(self, req):
        code = req["code"]
        name = re.search(r"^local __filter = (.*)$", code, re.M).group(1)
        exact = re.search(r"^local __exact = (\w+)$", code, re.M).group(1) == "true"
        name = None if name == "nil" else name[1:-1]
        self.calls.append((name, exact))
        names = run_tests.test_names(code)
        chosen = [n for n in names if name is None or (n == name if exact else name in n)]
        self.now += self.seconds.get(name, 0.1)
        return {"ok": True, "output": [run_tests.PREFIX + "PASS" + run_tests.SEP + n for n in chosen]}


class EachTest(unittest.TestCase):
    def run_body(self, body, seconds, name_filter=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "test_x.lua")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        fake = FakeTuner(seconds)
        old = run_tests.civ6tuner.request, run_tests.time.monotonic
        run_tests.civ6tuner.request, run_tests.time.monotonic = fake.request, lambda: fake.now
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                counts, problem = run_tests.run_file(path, name_filter, False)
        finally:
            run_tests.civ6tuner.request, run_tests.time.monotonic = old
        return counts, problem, fake.calls, out.getvalue()

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


if __name__ == "__main__":
    unittest.main()
