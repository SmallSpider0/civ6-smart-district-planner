"""Offline tests of tools/sdpsched.py (the queue on a second machine) with fake pids.

    python3 -I -m unittest discover -s tests/tools -v
"""
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import sdpsched  # noqa: E402

ALIVE = {11, 12, 13, 14, 15}


def alive(pid):
    return pid in ALIVE


def job(name, state, slots, at, pid=11, exclusive=False, started=None):  # the tests use a machine of 8 slots
    record = {"name": name, "state": state, "slots": slots, "queued_at": at, "exclusive": exclusive,
              "sched_pid": pid, "pid": pid}
    if started is not None or state == "running":
        record["started_at"] = at if started is None else started
    return record


class Decide(unittest.TestCase):
    def test_jobs_start_in_line_order_while_they_fit(self):
        jobs = [job("a", "running", 4, 1), job("b", "queued", 3, 2, 12), job("c", "queued", 1, 3, 13),
                job("d", "queued", 1, 4, 14)]
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), ["b", "c"])  # d: no slot left

    def test_a_later_job_that_fits_backfills(self):
        # 6 of 8 slots in use, first in line wants 4: the 2-slot jobs behind it start, the 3-slot one waits
        jobs = [job("a", "running", 6, 1), job("big", "queued", 4, 2, 12), job("mid", "queued", 3, 3, 13),
                job("s1", "queued", 2, 4, 14), job("s2", "queued", 2, 5, 15)]
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), ["s1"])
        jobs[3].update(state="running", started_at=6)
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), [])  # full
        jobs[0]["state"] = "done"  # 6 slots free again: big first, then whatever fits
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), ["big", "s2"])

    def test_a_job_passed_three_times_keeps_its_place(self):
        jobs = [job("a", "running", 6, 1), job("big", "queued", 4, 2, 12),
                job("p1", "done", 1, 3, started=3), job("p2", "running", 1, 4, started=4),
                job("small", "queued", 1, 5, 13)]
        self.assertEqual(sdpsched.passed(jobs[1], jobs), 2)
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), ["small"])
        jobs[4].update(state="running", started_at=6)  # the third pass
        jobs.append(job("late", "queued", 1, 7, 14))
        jobs[3]["state"] = "done"  # a slot frees: big still does not fit, and late may not pass it again
        self.assertEqual(sdpsched.passed(jobs[1], jobs), sdpsched.MAX_PASSED)
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), [])
        jobs[0]["state"] = "done"
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), ["big", "late"])

    def test_jobs_ahead_do_not_count_as_passing(self):
        jobs = [job("old", "done", 4, 1, started=1), job("b", "queued", 4, 2, 12)]
        self.assertEqual(sdpsched.passed(jobs[1], jobs), 0)

    def test_other_compare_processes_count(self):
        jobs = [job("b", "queued", 4, 2, 12)]
        self.assertEqual(sdpsched.startable(jobs, other_slots=4, capacity=8, alive=alive), ["b"])
        self.assertEqual(sdpsched.startable(jobs, other_slots=5, capacity=8, alive=alive), [])

    def test_exclusive_waits_for_an_empty_machine_and_keeps_it(self):
        jobs = [job("a", "running", 1, 1), job("x", "queued", 8, 2, 12, exclusive=True),
                job("small", "queued", 1, 3, 13)]
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), [])  # no backfill past it
        jobs[0]["state"] = "done"
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), ["x"])
        jobs[1].update(state="running", started_at=4)
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), [])

    def test_an_exclusive_job_behind_others_waits_its_turn(self):
        jobs = [job("a", "queued", 4, 1, 12), job("x", "queued", 8, 2, 13, exclusive=True),
                job("b", "queued", 1, 3, 14)]
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), ["a"])

    def test_jobs_whose_scheduler_died_do_not_count(self):
        jobs = [job("ghost", "running", 8, 1, pid=99), job("b", "queued", 8, 2, 12)]
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), ["b"])
        jobs = [job("ghost", "queued", 1, 1, pid=99), job("b", "queued", 8, 2, 12)]
        self.assertEqual(sdpsched.startable(jobs, capacity=8, alive=alive), ["b"])

    def test_a_job_larger_than_the_machine_is_clamped(self):
        self.assertEqual(sdpsched.startable([job("big", "queued", 20, 1)], capacity=8, alive=alive), ["big"])


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

    def test_run_backfills_past_a_job_that_does_not_fit(self):
        self.addCleanup(setattr, sdpsched, "SLOTS", sdpsched.SLOTS)
        sdpsched.SLOTS = 8
        os.makedirs(sdpsched.jobs_dir())
        me = os.getpid()
        sdpsched.write_json(sdpsched.job_path("hog"), job("hog", "running", 6, 1, pid=me))
        sdpsched.write_json(sdpsched.job_path("big"), job("big", "queued", 4, 2, pid=me))
        self.assertEqual(sdpsched.main(["run", "small", "--slots", "2", "--", sys.executable, "-c", "pass"]), 0)
        record = sdpsched.read_json(sdpsched.job_path("small"))
        self.assertEqual((record["state"], record["exit"]), ("done", 0))
        self.assertEqual(sdpsched.passed(sdpsched.read_json(sdpsched.job_path("big")), sdpsched.load_jobs()), 1)

    def test_prune_drops_old_snapshots_and_unused_trees(self):
        base, old = self.dir.name, time.time() - sdpsched.KEEP - 3600
        os.makedirs(sdpsched.jobs_dir())

        def make(path, synced=None, age=old):
            os.makedirs(os.path.join(base, path, "tools"))
            open(os.path.join(base, path, "tools", "sdpsched.py"), "w").close()
            if synced is not None:
                open(os.path.join(base, path, sdpsched.SYNCED), "w").close()
                os.utime(os.path.join(base, path, sdpsched.SYNCED), (synced, synced))
            os.utime(os.path.join(base, path), (age, age))

        for name, ended, tree in (("done-old", old, "t-old"), ("done-new", time.time(), "t-recent")):
            sdpsched.write_json(sdpsched.job_path(name), dict(job(name, "done", 1, old), ended_at=ended, tree=tree))
            make(os.path.join("snap", name))
        make(os.path.join("snap", "no-record"))
        sdpsched.write_json(sdpsched.job_path("busy"), dict(job("busy", "running", 1, old, pid=os.getpid()), tree="t-live"))
        make("t-old", synced=old)               # synced long ago, its job ended long ago
        make("t-unmarked")                      # copied before the marker existed, no job
        make("t-live", synced=old)              # a live job uses it
        make("t-recent", synced=old)            # its job ended just now
        make("t-synced", synced=time.time())    # synced just now
        os.makedirs(os.path.join(base, "logs"))  # not a worktree copy
        os.utime(os.path.join(base, "logs"), (old, old))
        self.assertEqual(sdpsched.main(["prune"]), 0)
        self.assertEqual(sorted(os.listdir(os.path.join(base, "snap"))), ["done-new"])
        left = sorted(n for n in os.listdir(base) if n.startswith("t-") or n == "logs")
        self.assertEqual(left, ["logs", "t-live", "t-recent", "t-synced"])

    def test_check_refuses_a_live_name(self):
        os.makedirs(sdpsched.jobs_dir())
        sdpsched.write_json(sdpsched.job_path("busy"), job("busy", "running", 1, 1, pid=os.getpid()))
        self.assertEqual(sdpsched.main(["check", "busy"]), 1)


if __name__ == "__main__":
    unittest.main()
