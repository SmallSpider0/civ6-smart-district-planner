"""Offline tests of tools/sdplock.py with fake pids, a fake clock and a fake game.

    python3 -I -m unittest discover -s tests/tools -v
"""
import calendar
import contextlib
import io
import json
import os
import signal
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import sdplock  # noqa: E402

MON_10 = calendar.timegm((2026, 10, 26, 10, 0, 0))  # a Monday, 10:00 (the fake local time is UTC)


class World:
    """Stands in for the clock, the processes and the game."""

    def __init__(self):
        self.t = MON_10
        self.alive = set()
        self.game = False
        self.signals = []

    def install(self, case):
        for name, fake in (("now", lambda: self.t), ("localtime", time.gmtime),
                           ("pid_alive", lambda pid: pid in self.alive), ("game_running", lambda: self.game),
                           ("signal_group", self.group), ("signal_pid", self.pid)):
            original = getattr(sdplock, name)
            setattr(sdplock, name, fake)
            case.addCleanup(setattr, sdplock, name, original)

    def group(self, pgid, sig):
        self.signals.append(("group", pgid, sig))
        return True

    def pid(self, pid, sig):
        self.signals.append(("pid", pid, sig))
        self.alive.discard(pid)
        return True


class LockCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for key in ("SDP_SHARED", "SDP_OWNER", "SDP_LOCAL_CONFIG", "SDP_REMOTE"):
            if key in os.environ:
                self.addCleanup(os.environ.__setitem__, key, os.environ[key])
                del os.environ[key]
            else:
                self.addCleanup(os.environ.pop, key, None)
        os.environ["SDP_SHARED"] = os.path.join(self.dir.name, "shared")
        os.environ["SDP_LOCAL_CONFIG"] = os.path.join(self.dir.name, "local.json")  # none unless a test writes it
        self.a = self.tree("tree-a")
        self.b = self.tree("tree-b")
        self.c = self.tree("tree-c")
        self.w = World()
        self.w.install(self)

    def tree(self, name):
        path = os.path.join(self.dir.name, name)
        os.makedirs(path)
        return path

    def holder(self):
        return sdplock.load_game()["holder"]


class GameLock(LockCase):
    def test_first_claim_takes_and_others_are_refused(self):
        sdplock.claim(self.a, "run_tests")
        self.assertEqual(self.holder()["owner"], "tree-a")
        with self.assertRaises(sdplock.Busy) as caught:
            sdplock.claim(self.b, "deploy")
        self.assertIn("tree-a", str(caught.exception))
        self.assertIn("run_tests", str(caught.exception))

    def test_claims_from_the_holder_renew(self):
        sdplock.claim(self.a, "run_tests")
        self.w.t += 10 * 60
        sdplock.claim(self.a)
        self.assertEqual(self.holder()["renewed"], self.w.t)
        self.assertEqual(self.holder()["purpose"], "run_tests")
        sdplock.claim(self.a, "shots")
        self.assertEqual(self.holder()["purpose"], "shots")

    def test_owner_comes_from_the_environment(self):
        os.environ["SDP_OWNER"] = "v1.5.0 session"
        sdplock.claim(self.a)
        self.assertEqual(self.holder()["owner"], "v1.5.0 session")

    def test_only_the_holder_releases(self):
        sdplock.claim(self.a)
        with self.assertRaises(sdplock.Busy):
            sdplock.release(self.b)
        self.assertEqual(sdplock.release(self.a), "game released")
        sdplock.claim(self.b)
        self.assertEqual(os.path.basename(self.holder()["tree"]), "tree-b")

    def test_release_stops_the_holders_tuner_daemon(self):
        sdplock.claim(self.a)
        self.w.alive.add(4242)
        sdplock.set_serve(self.a, 4242)
        sdplock.release(self.a)
        self.assertIn(("pid", 4242, signal.SIGTERM), self.w.signals)

    def test_stale_needs_time_and_a_dead_game_or_daemon(self):
        sdplock.claim(self.a)
        self.w.alive.add(4242)
        sdplock.set_serve(self.a, 4242)
        self.w.game = True
        self.w.t += sdplock.STALE + 60
        self.assertFalse(sdplock.is_stale(self.holder(), self.w.t))  # game and daemon still there
        self.w.alive.discard(4242)
        self.assertTrue(sdplock.is_stale(self.holder(), self.w.t))   # daemon gone
        self.w.alive.add(4242)
        self.w.game = False
        self.assertTrue(sdplock.is_stale(self.holder(), self.w.t))   # game closed
        self.w.t = MON_10 + sdplock.STALE - 60
        self.assertFalse(sdplock.is_stale(self.holder(), self.w.t))  # not long enough

    def test_take_over_a_stale_lock_only_when_asked(self):
        sdplock.claim(self.a)
        self.w.alive.add(4242)
        sdplock.set_serve(self.a, 4242)
        self.w.t += sdplock.STALE + 60
        with self.assertRaises(sdplock.Busy) as caught:
            sdplock.claim(self.b)
        self.assertIn("stale", str(caught.exception))
        sdplock.take(self.b, "tests", stale=True)
        self.assertEqual(os.path.basename(self.holder()["tree"]), "tree-b")
        self.assertIn(("pid", 4242, signal.SIGTERM), self.w.signals)

    def test_stale_take_of_a_live_lock_is_refused(self):
        sdplock.claim(self.a)
        self.w.game = True
        self.w.alive.add(4242)
        sdplock.set_serve(self.a, 4242)
        with self.assertRaises(sdplock.Busy):
            sdplock.take(self.b, stale=True)
        self.assertIn("took the game over", sdplock.take(self.b, force=True))

    def test_booking_the_next_turn(self):
        sdplock.claim(self.a, "feature tests")
        self.assertIn("booked", sdplock.take(self.b, "release tests", book=True))
        with self.assertRaises(sdplock.Busy):
            sdplock.take(self.c, book=True)  # one booking at a time
        sdplock.release(self.a)
        self.w.t += 60
        with self.assertRaises(sdplock.Busy) as caught:
            sdplock.claim(self.c)
        self.assertIn("booked", str(caught.exception))
        sdplock.claim(self.b)
        self.assertIsNone(sdplock.load_game()["next"])

    def test_booking_lapses(self):
        sdplock.claim(self.a)
        sdplock.take(self.b, book=True)
        sdplock.release(self.a)
        self.w.t += sdplock.BOOKING + 60
        sdplock.claim(self.c)
        self.assertEqual(os.path.basename(self.holder()["tree"]), "tree-c")

    def test_a_left_over_mutex_is_broken(self):
        os.makedirs(sdplock.shared_dir(), exist_ok=True)
        path = os.path.join(sdplock.shared_dir(), ".state.mutex")
        open(path, "w").close()
        old = time.time() - sdplock.MUTEX_STALE - 5
        os.utime(path, (old, old))
        sdplock.claim(self.a)
        self.assertFalse(os.path.exists(path))


class HeavyJobs(LockCase):
    def job(self, name, pid):
        self.w.alive.add(pid)
        sdplock._write(os.path.join(sdplock.jobs_dir(), name + ".json"),
                       {"name": name, "pid": pid, "cmd": ["node"], "owner": "x", "started": self.w.t})

    @unittest.skipUnless(hasattr(signal, "SIGSTOP"), "no SIGSTOP on this platform")
    def test_taking_the_game_pauses_and_releasing_resumes(self):
        self.job("oracle", 777)
        sdplock.claim(self.a)
        self.assertEqual(self.w.signals, [("group", 777, signal.SIGSTOP)])
        sdplock.claim(self.a, "again")  # a renewal does not pause twice
        self.assertEqual(len(self.w.signals), 1)
        sdplock.release(self.a)
        self.assertEqual(self.w.signals[-1], ("group", 777, signal.SIGCONT))
        self.assertEqual(sdplock.heavy_jobs()[0]["pauses"], 1)

    def test_dead_jobs_are_forgotten(self):
        self.job("old", 778)
        self.w.alive.discard(778)
        self.assertEqual(sdplock.heavy_jobs(), [])
        self.assertEqual(os.listdir(sdplock.jobs_dir()), [])

    def test_one_heavy_job_at_a_time(self):
        self.job("oracle", 777)
        with self.assertRaises(sdplock.Busy) as caught:
            sdplock.run_heavy(self.a, "second", [sys.executable, "-c", "pass"], wait=False)
        self.assertIn("oracle", str(caught.exception))
        self.assertEqual(sdplock.heavy_waiting(), [])  # refusing does not queue

    def test_waiting_jobs_go_first_come_first_served(self):
        self.job("oracle", 777)
        self.w.alive.update({11, 12, 13})
        with sdplock._mutex():
            self.assertFalse(sdplock.heavy_turn(self.a, "first", ["node"], 11)[0])
        self.w.t += 60
        with sdplock._mutex():
            ok, ahead = sdplock.heavy_turn(self.b, "second", ["node"], 12)
        self.assertFalse(ok)
        self.assertEqual([j["name"] for j in ahead], ["oracle", "first"])
        self.w.t += 60
        with sdplock._mutex():
            self.assertFalse(sdplock.heavy_turn(self.c, "third", ["node"], 13)[0])
        self.assertEqual([w["name"] for w in sdplock.heavy_waiting()], ["first", "second", "third"])
        self.w.alive.discard(777)  # the slot frees up: a later waiter that asks first still waits
        with sdplock._mutex():
            ok, ahead = sdplock.heavy_turn(self.c, "third", ["node"], 13)
        self.assertFalse(ok)
        self.assertEqual([j["name"] for j in ahead], ["first", "second"])
        with sdplock._mutex():
            self.assertFalse(sdplock.heavy_turn(self.b, "second", ["node"], 12)[0])
        with sdplock._mutex():
            self.assertEqual(sdplock.heavy_turn(self.a, "first", ["node"], 11), (True, []))
        self.assertEqual([w["name"] for w in sdplock.heavy_waiting()], ["second", "third"])

    def test_a_dead_waiter_leaves_the_queue(self):
        self.job("oracle", 777)
        self.w.alive.update({11, 12})
        with sdplock._mutex():
            sdplock.heavy_turn(self.a, "first", ["node"], 11)
            sdplock.heavy_turn(self.b, "second", ["node"], 12)
        self.w.alive.discard(11)  # killed while waiting
        self.w.alive.discard(777)
        with sdplock._mutex():
            self.assertEqual(sdplock.heavy_turn(self.b, "second", ["node"], 12), (True, []))
        self.assertEqual(sdplock._read(sdplock.heavy_queue_path(), None), [])

    def test_run_heavy_waits_its_turn_then_runs(self):
        self.job("oracle", 777)
        me = os.getpid()
        self.w.alive.add(me)
        seen = []

        def sleep(_):
            seen.append([w["pid"] for w in sdplock.heavy_waiting()])
            self.w.alive.discard(777)

        code = sdplock.run_heavy(self.a, "quick", [sys.executable, "-c", "pass"], every=0, sleep=sleep)
        self.assertEqual(code, 0)
        self.assertEqual(seen, [[me]])
        self.assertEqual(sdplock.heavy_waiting(), [])

    def test_an_interrupted_wait_leaves_the_queue(self):
        self.job("oracle", 777)
        self.w.alive.add(os.getpid())

        def sleep(_):
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            sdplock.run_heavy(self.a, "quick", [sys.executable, "-c", "pass"], sleep=sleep)
        self.assertEqual(sdplock.heavy_waiting(), [])

    def test_status_lists_the_waiting_order(self):
        self.job("oracle", 777)
        self.w.alive.update({11, 12})
        with sdplock._mutex():
            sdplock.heavy_turn(self.b, "later", ["node", "b"], 12)
        self.w.t -= 600  # an earlier start of waiting goes first whatever the file order
        with sdplock._mutex():
            sdplock.heavy_turn(self.a, "earlier", ["node", "a"], 11)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            sdplock.print_status(True)
        text = out.getvalue()
        self.assertIn("first come first served", text)
        self.assertLess(text.index("1. earlier"), text.index("2. later"))

    def test_a_heavy_job_runs_and_unregisters(self):
        code = sdplock.run_heavy(self.a, "quick", [sys.executable, "-c", "import sys; sys.exit(3)"])
        self.assertEqual(code, 3)
        self.assertEqual(os.listdir(sdplock.jobs_dir()), [])

    def test_worker_cap_without_a_local_config(self):
        for t in (MON_10, MON_10 + 12 * 3600, MON_10 - 2 * 86400):
            self.assertEqual(sdplock.local_cap(t), 4)

    def test_worker_cap_from_the_local_config(self):
        sdplock._write(os.environ["SDP_LOCAL_CONFIG"], {"workers_day": 3, "workers_night": 7,
                                                        "night": "22:30-06:00", "weekend_is_night": True})
        self.assertEqual(sdplock.local_cap(MON_10), 3)
        self.assertEqual(sdplock.local_cap(MON_10 + 12 * 3600), 3)            # 22:00
        self.assertEqual(sdplock.local_cap(MON_10 + 12 * 3600 + 1800), 7)     # 22:30
        self.assertEqual(sdplock.local_cap(MON_10 - 5 * 3600), 7)             # 05:00
        self.assertEqual(sdplock.local_cap(MON_10 - 4 * 3600), 3)             # 06:00
        self.assertEqual(sdplock.local_cap(MON_10 - 2 * 86400), 7)            # Saturday 10:00
        sdplock._write(os.environ["SDP_LOCAL_CONFIG"], {"workers_day": 2, "night": "01:00-05:00"})
        self.assertEqual(sdplock.local_cap(MON_10 - 7 * 3600), 2)             # 03:00: night, same count
        self.assertEqual(sdplock.local_cap(MON_10 - 2 * 86400), 2)            # weekends not special

    def test_remote_host_from_the_environment_or_the_config(self):
        self.assertIsNone(sdplock.remote_host())
        sdplock._write(os.environ["SDP_LOCAL_CONFIG"], {"remote": "build-box"})
        self.assertEqual(sdplock.remote_host(), "build-box")
        os.environ["SDP_REMOTE"] = "other"
        self.assertEqual(sdplock.remote_host(), "other")

    def test_fit_workers(self):
        self.assertEqual(sdplock.fit_workers(["node", "tools/compare.mjs", "-j", "8", "-s", "x"], 4),
                         ["node", "tools/compare.mjs", "-j", "4", "-s", "x"])
        self.assertEqual(sdplock.fit_workers(["node", "tools/compare.mjs", "-j", "2"], 4),
                         ["node", "tools/compare.mjs", "-j", "2"])
        self.assertEqual(sdplock.fit_workers(["python3", "-I", "tools/refresh_results.py", "--check"], 6),
                         ["python3", "-I", "tools/refresh_results.py", "--check", "-j", "6"])
        self.assertEqual(sdplock.fit_workers(["node", "tools/offline_tests.mjs"], 4), ["node", "tools/offline_tests.mjs"])


class NightQueue(LockCase):
    def test_add_list_done(self):
        first = sdplock.queue_add(self.a, "realclick suite", "v1.5.0 UI", ["python3 -I tools/realclick.py suite"])
        second = sdplock.queue_add(self.b, "shots", "README")
        self.assertEqual((first["id"], second["id"]), (1, 2))
        sdplock.queue_done(1, result="12 passed")
        self.assertEqual([i["id"] for i in sdplock.queue_items()], [2])
        self.assertEqual(sdplock.queue_items(True)[0]["result"], "12 passed")
        with self.assertRaises(sdplock.Busy):
            sdplock.queue_done(9)


class WeeklyTest(LockCase):
    """#329: #314, #319 and #320 only showed in the release tests, since the PRs run their own test
    files and the whole in-game set ran only before a release. The night queue now keeps a weekly
    whole-set run, one ruleset a week in turn, that queues the next one when it is closed."""

    def config(self, **cfg):
        with open(os.environ["SDP_LOCAL_CONFIG"], "w", encoding="utf-8") as fh:
            json.dump(cfg, fh)

    def at(self, day, hhmm):
        h, m = hhmm.split(":")
        return calendar.timegm((2026, 11, day, int(h), int(m), 0))

    def test_queued_from_the_configured_night_and_hidden_before_it(self):
        self.config(night="00:00-08:00", weekly_night="sat")
        self.w.t = self.at(7, "15:00")  # Saturday afternoon: tonight's window (Sunday's) is not the one
        item = sdplock.queue_weekly(self.a)
        self.assertEqual(item["night"], "2026-11-14")
        self.assertEqual(item["weekly"], "RULESET_EXPANSION_2")
        self.assertIn("RULESET_EXPANSION_2", item["cmds"][-1])
        self.assertIn("run_tests.py --rulesets", item["cmds"][-1])
        self.assertIn("风云变幻", item["what"])
        self.assertEqual(sdplock.queue_items(), [])
        self.assertEqual([i["id"] for i in sdplock.queue_later()], [item["id"]])
        self.w.t = self.at(13, "23:59")
        self.assertEqual(sdplock.queue_items(), [])
        self.w.t = self.at(14, "00:00")
        self.assertEqual([i["id"] for i in sdplock.queue_items()], [item["id"]])
        self.assertEqual(sdplock.queue_later(), [])

    def test_closing_it_queues_next_week_with_the_next_ruleset(self):
        self.config(night="00:00-08:00", weekly_night="sat")
        self.w.t = self.at(7, "15:00")
        first = sdplock.queue_weekly(self.a)
        names = []
        for day, failed in ((14, False), (21, True), (28, False)):
            self.w.t = self.at(day, "03:00")
            due = sdplock.queue_items()
            self.assertEqual(len(due), 1)
            names.append(due[0]["weekly"])
            done = sdplock.queue_done(due[0]["id"], failed=failed, result="x")
            self.assertTrue(done["next"])  # a failure still keeps the weekly run going
            self.assertEqual(sdplock.queue_items(), [])
        self.assertEqual(names, ["RULESET_EXPANSION_2", "RULESET_STANDARD", "RULESET_EXPANSION_1"])
        later = sdplock.queue_later()
        self.assertEqual([(i["night"], i["weekly"]) for i in later], [("2026-12-05", "RULESET_EXPANSION_2")])
        self.assertEqual(first["tree"], later[0]["tree"])
        self.assertEqual(later[0]["branch"], "main")

    def test_a_night_run_late_or_past_midnight_lands_on_the_next_weekday(self):
        self.config(night="22:30-06:00", weekly_night="sat")
        self.w.t = self.at(7, "22:40")  # Saturday's window is open already
        item = sdplock.queue_weekly(self.a)
        self.assertEqual(item["night"], "2026-11-14")
        self.w.t = self.at(14, "22:00")
        self.assertEqual(sdplock.queue_items(), [])
        self.w.t = self.at(15, "01:00")  # Saturday's night, after midnight
        self.assertEqual(len(sdplock.queue_items()), 1)
        sdplock.queue_done(item["id"])
        self.assertEqual(sdplock.queue_later()[0]["night"], "2026-11-21")
        self.w.t = self.at(25, "02:00")  # missed a week: still once, then on the weekday after
        due = sdplock.queue_items()
        sdplock.queue_done(due[0]["id"])
        self.assertEqual(sdplock.queue_later()[0]["night"], "2026-11-28")

    def test_closed_before_its_night_the_next_is_a_week_later(self):
        self.config(night="00:00-08:00", weekly_night="sat")
        self.w.t = self.at(7, "15:00")
        item = sdplock.queue_weekly(self.a)  # the 14th
        sdplock.queue_done(item["id"])  # run by day ahead of its night
        self.assertEqual(sdplock.queue_later()[0]["night"], "2026-11-21")

    def test_without_a_weekday_a_week_after_the_last(self):
        self.config(night="00:00-08:00")
        self.w.t = self.at(9, "10:00")  # Monday
        item = sdplock.queue_weekly(self.a, "RULESET_STANDARD", night="2026-11-10")
        self.assertEqual(item["night"], "2026-11-10")
        self.w.t = self.at(10, "05:00")
        sdplock.queue_done(item["id"])
        self.assertEqual(sdplock.queue_later()[0]["night"], "2026-11-17")
        self.assertEqual(sdplock.queue_later()[0]["weekly"], "RULESET_EXPANSION_1")

    def test_one_chain_only_and_last_ends_it(self):
        self.config(night="00:00-08:00", weekly_night="sat")
        item = sdplock.queue_weekly(self.a, night="2026-10-26")
        with self.assertRaises(sdplock.Busy):
            sdplock.queue_weekly(self.b)
        with self.assertRaises(sdplock.Busy):
            sdplock.queue_weekly(self.b, night="next friday")
        done = sdplock.queue_done(item["id"], last=True)
        self.assertNotIn("next", done)
        self.assertEqual(sdplock.queue_items(), [])
        self.assertEqual(sdplock.queue_later(), [])
        sdplock.queue_done(item["id"])  # closing it again does not start a chain
        self.assertEqual(sdplock.queue_later(), [])

    def test_plain_items_are_unchanged(self):
        sdplock.queue_add(self.a, "shots", "README")
        self.assertEqual(len(sdplock.queue_items()), 1)
        self.assertNotIn("next", sdplock.queue_done(1))


if __name__ == "__main__":
    unittest.main()
