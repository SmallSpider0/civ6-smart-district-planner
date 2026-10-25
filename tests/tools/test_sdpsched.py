"""Offline tests of tools/sdpsched.py (the queue on a second machine) with fake pids.

    python3 -I -m unittest discover -s tests/tools -v
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import sdpsched  # noqa: E402

ALIVE = {11, 12, 13, 14, 15}


def alive(pid):
    return pid in ALIVE


def job(name, state, slots, at, pid=11, exclusive=False):  # the tests use a machine of 8 slots
    return {"name": name, "state": state, "slots": slots, "queued_at": at, "exclusive": exclusive,
            "sched_pid": pid, "pid": pid}


class Decide(unittest.TestCase):
    def test_first_in_line_starts_when_it_fits(self):
        jobs = [job("a", "running", 4, 1), job("b", "queued", 4, 2, 12), job("c", "queued", 1, 3, 13)]
        self.assertEqual(sdpsched.decide(jobs, capacity=8, alive=alive), "b")
        jobs[1]["slots"] = 5
        self.assertIsNone(sdpsched.decide(jobs, capacity=8, alive=alive))  # c waits behind b: strictly in order

    def test_other_compare_processes_count(self):
        jobs = [job("b", "queued", 4, 2, 12)]
        self.assertEqual(sdpsched.decide(jobs, other_slots=4, capacity=8, alive=alive), "b")
        self.assertIsNone(sdpsched.decide(jobs, other_slots=5, capacity=8, alive=alive))

    def test_exclusive_waits_for_an_empty_machine_and_keeps_it(self):
        jobs = [job("a", "running", 1, 1), job("x", "queued", 8, 2, 12, exclusive=True)]
        self.assertIsNone(sdpsched.decide(jobs, capacity=8, alive=alive))
        jobs[0]["state"] = "done"
        self.assertEqual(sdpsched.decide(jobs, capacity=8, alive=alive), "x")
        jobs[1]["state"] = "running"
        jobs.append(job("small", "queued", 1, 3, 13))
        self.assertIsNone(sdpsched.decide(jobs, capacity=8, alive=alive))

    def test_jobs_whose_scheduler_died_do_not_count(self):
        jobs = [job("ghost", "running", 8, 1, pid=99), job("b", "queued", 8, 2, 12)]
        self.assertEqual(sdpsched.decide(jobs, capacity=8, alive=alive), "b")
        jobs = [job("ghost", "queued", 1, 1, pid=99), job("b", "queued", 8, 2, 12)]
        self.assertEqual(sdpsched.decide(jobs, capacity=8, alive=alive), "b")

    def test_a_job_larger_than_the_machine_is_clamped(self):
        self.assertEqual(sdpsched.decide([job("big", "queued", 20, 1)], capacity=8, alive=alive), "big")


class Processes(unittest.TestCase):
    def test_workers_of(self):
        self.assertEqual(sdpsched.workers_of("node tools/compare.mjs -s x -j 6 --out y"), 6)
        self.assertIsNone(sdpsched.workers_of("node tools/compare.mjs -s x"))

    def test_unregistered_compare_processes(self):
        lines = ["  500 node tools/compare.mjs -s ^L0 -j 4 --out a",
                 "  500 node tools/compare.mjs -s ^L0 -j 4 --out a",   # a worker of the same group
                 "  600 node tools/compare.mjs -s ^S0",
                 "  700 node tools/compare.mjs -j 2",                  # started by a job here
                 "  800 python3 sdpsched.py run x -- node tools/compare.mjs",
                 "  900 /bin/zsh"]
        self.assertEqual(sdpsched.unregistered(lines, {700}), {500: 4, 600: sdpsched.SLOTS})


@unittest.skipIf(sys.platform == "win32", "the queue runs on macOS or Linux")
class Run(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for name, value in (("BASE", self.dir.name), ("ps_lines", lambda: [])):
            self.addCleanup(setattr, sdpsched, name, getattr(sdpsched, name))
            setattr(sdpsched, name, value)

    def test_run_records_the_exit_and_check_frees_the_name(self):
        code = sdpsched.main(["run", "quick", "--slots", "1", "--owner", "me", "--",
                              sys.executable, "-c", "import os, sys; sys.exit(int(os.environ['SDP_JOBS']) + 2)"])
        self.assertEqual(code, 3)
        with open(os.path.join(self.dir.name, "quick.exit")) as fh:
            self.assertEqual(fh.read().strip(), "3")
        record = sdpsched.read_json(sdpsched.job_path("quick"))
        self.assertEqual((record["state"], record["exit"], record["owner"]), ("done", 3, "me"))
        self.assertEqual(sdpsched.main(["check", "quick"]), 0)

    def test_check_refuses_a_live_name(self):
        os.makedirs(sdpsched.jobs_dir())
        sdpsched.write_json(sdpsched.job_path("busy"), job("busy", "running", 1, 1, pid=os.getpid()))
        self.assertEqual(sdpsched.main(["check", "busy"]), 1)


if __name__ == "__main__":
    unittest.main()
