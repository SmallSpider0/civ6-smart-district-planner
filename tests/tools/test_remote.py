"""Offline tests of tools/remote.py: the commands it sends, with ssh replaced.

    python3 -I -m unittest discover -s tests/tools -v
"""
import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import remote  # noqa: E402
import sdplock  # noqa: E402
import sdpsched  # noqa: E402

TOOLS = os.path.dirname(os.path.abspath(remote.__file__))


def isolate(case):
    """Shared folder and local config in a temporary directory: nothing of this machine's is touched."""
    tmp = tempfile.TemporaryDirectory()
    case.addCleanup(tmp.cleanup)
    for key in ("SDP_SHARED", "SDP_LOCAL_CONFIG", "SDP_REMOTE", "SDP_OWNER", "SDP_PLACED"):
        if key in os.environ:
            case.addCleanup(os.environ.__setitem__, key, os.environ[key])
            del os.environ[key]
        else:
            case.addCleanup(os.environ.pop, key, None)
    os.environ["SDP_SHARED"] = os.path.join(tmp.name, "shared")
    os.environ["SDP_LOCAL_CONFIG"] = os.path.join(tmp.name, "local.json")
    os.environ["SDP_REMOTE"] = "second"
    return tmp.name


def patch(case, module, **fakes):
    for name, value in fakes.items():
        case.addCleanup(setattr, module, name, getattr(module, name))
        setattr(module, name, value)


class Run(unittest.TestCase):
    def setUp(self):
        isolate(self)
        patch(self, remote, local_free=lambda: False)  # the heavy slot here is taken: these jobs go there
        self.sent = []
        fakes = {"ssh": lambda cmd, **_kw: self.sent.append(cmd) or "", "rsync": lambda *_a, **_kw: None,
                 "host": lambda: "second", "remote_env": lambda: "export PATH=/opt/homebrew/bin:$PATH",
                 "sync": lambda _args: self.sent.append("SYNC") or 0}
        for name, value in fakes.items():
            self.addCleanup(setattr, remote, name, getattr(remote, name))
            setattr(remote, name, value)

    def test_run_copies_the_worktree_before_cloning_it(self):
        # #210: a worktree that was never synced had no copy there; the clone failed with
        # "cp: ...: No such file or directory" and an empty ssh error, and nothing was queued.
        remote.run(argparse.Namespace(name="job", slots=1, exclusive=False, command=["node", "x.mjs"]))
        clone = [i for i, c in enumerate(self.sent) if "cp -c -R" in c]
        self.assertEqual(len(clone), 1)
        self.assertIn("SYNC", self.sent[:clone[0]])

    def test_prune_runs_with_the_remote_path(self):
        # Without the PATH, python3 on macOS can be a stub that asks for the Xcode license and fails,
        # so prune never ran and snapshots piled up (2026-10-29: 118 of them, 5.9 GB).
        remote.run(argparse.Namespace(name="job", slots=1, exclusive=False, command=["node", "x.mjs"]))
        start = [c for c in self.sent if "sdpsched.py prune" in c]
        self.assertEqual(len(start), 1)
        self.assertLess(start[0].index("export PATH="), start[0].index("sdpsched.py prune"))


class Clean(unittest.TestCase):
    def setUp(self):
        isolate(self)
        self.sent = []
        fakes = {"ssh": lambda cmd, **_kw: self.sent.append(cmd) or "removed job old (1.0 MB)\n",
                 "rsync": lambda *_a, **_kw: None, "host": lambda: "second",
                 "remote_env": lambda: "export PATH=/opt/homebrew/bin:$PATH",
                 "worktree_names": lambda: ["civ6mod", "civ6mod-i1", "it's"]}
        for name, value in fakes.items():
            self.addCleanup(setattr, remote, name, getattr(remote, name))
            setattr(remote, name, value)

    def prune_command(self):
        return [c for c in self.sent if "sdpsched.py prune" in c]

    def test_clean_tells_the_second_machine_which_worktrees_exist(self):
        remote.clean(argparse.Namespace(dry_run=False, keep_days=None))
        (cmd,) = self.prune_command()
        self.assertIn("prune --known civ6mod civ6mod-i1 'it'\"'\"'s'", cmd)
        self.assertNotIn("--dry-run", cmd)
        self.assertLess(cmd.index("export PATH="), cmd.index("sdpsched.py prune"))  # the PATH first, as for run

    def test_clean_passes_dry_run_and_age(self):
        remote.clean(argparse.Namespace(dry_run=True, keep_days=3.0))
        (cmd,) = self.prune_command()
        self.assertTrue(cmd.endswith("--dry-run --keep-days 3.0"))


class Names(unittest.TestCase):
    def test_worktree_names_come_from_git_and_include_this_checkout(self):
        class Done:
            returncode, stderr = 0, ""
            stdout = "worktree /a/civ6mod\nHEAD x\n\nworktree /home/me/civ6mod-i9/\nbranch refs/heads/b\n"
        saved = remote.subprocess.run
        self.addCleanup(setattr, remote.subprocess, "run", saved)
        remote.subprocess.run = lambda *_a, **_kw: Done()
        self.assertEqual(remote.worktree_names(), sorted({remote.NAME, "civ6mod", "civ6mod-i9"}))


def job(name, **kw):
    return argparse.Namespace(name=name, slots=kw.get("slots"), exclusive=kw.get("exclusive", False),
                              remote_only=kw.get("remote_only", False), command=kw.get("command", ["node", "x.mjs"]))


class Placement(unittest.TestCase):
    """#249: remote.py run starts a job here when the second machine cannot start it now and the heavy slot
    here is free; before, it always queued there (2026-11-03: 8/8 slots used, 5 jobs waiting up to 24 min,
    this machine idle)."""

    def setUp(self):
        isolate(self)
        self.calls = []
        self.fits = "no"
        patch(self, remote, ssh=self.ssh, rsync=lambda *_a, **_kw: None, sync=lambda _a: 0,
              remote_env=lambda: "export PATH=/x:$PATH",
              run_here=lambda args, command: self.calls.append(("here", args.name, command)) or 0)

    def ssh(self, cmd, **kw):
        self.calls.append(("ssh", cmd))
        if " fits " in cmd:
            self.assertIn("def startable", kw.get("input_text") or "")  # this worktree's sdpsched.py
            return self.fits + "\n"
        return ""

    def queued_there(self):
        return any(c[0] == "ssh" and "nohup" in c[1] for c in self.calls)

    def test_full_second_machine_and_free_slot_here_runs_here(self):
        remote.run(job("a", slots=2))
        self.assertEqual([c for c in self.calls if c[0] == "here"], [("here", "a", ["node", "x.mjs"])])
        self.assertFalse(self.queued_there())
        (query,) = [c[1] for c in self.calls if c[0] == "ssh"]
        self.assertIn("fits --slots 2 --name a", query)

    def test_second_machine_with_room_takes_it(self):
        self.fits = "yes"
        remote.run(job("a"))
        self.assertTrue(self.queued_there())
        self.assertFalse([c for c in self.calls if c[0] == "here"])

    def test_busy_heavy_slot_here_queues_there(self):
        for holder in ("job", "game"):
            self.calls.clear()
            if holder == "job":
                sdplock._write(os.path.join(sdplock.jobs_dir(), "other.json"), {"name": "other", "pid": os.getpid()})
            else:
                os.remove(os.path.join(sdplock.jobs_dir(), "other.json"))
                sdplock._write(sdplock.game_path(), {"holder": {"tree": "/t", "owner": "o"}})
            remote.run(job("a"))
            self.assertTrue(self.queued_there(), holder)
            self.assertFalse([c for c in self.calls if c[0] == "here" or " fits " in c[1]], holder)

    def test_exclusive_and_remote_only_jobs_stay_there(self):
        for kw in ({"exclusive": True}, {"remote_only": True}):
            self.calls.clear()
            remote.run(job("a", **kw))
            self.assertTrue(self.queued_there(), kw)
            self.assertFalse([c for c in self.calls if c[0] == "here" or " fits " in c[1]], kw)

    def test_a_name_taken_there_is_refused(self):
        self.fits = "taken"
        with self.assertRaises(SystemExit):
            remote.run(job("a"))
        self.assertFalse(self.queued_there())

    def test_ssh_trouble_counts_as_cannot_start_there(self):
        def down(cmd, **_kw):
            raise SystemExit("ssh second: exit 255")
        patch(self, remote, ssh=down)
        remote.run(job("a"))
        self.assertEqual([c[0] for c in self.calls], ["here"])


class Fits(unittest.TestCase):
    def jobs(self, *specs):
        return [{"name": n, "state": st, "slots": sl, "queued_at": i, "sched_pid": 1, "pid": 1,
                 "started_at": i if st == "running" else None} for i, (n, st, sl) in enumerate(specs)]

    def test_room_left(self):
        self.assertTrue(sdpsched.fits(self.jobs(("a", "running", 4)), 4, capacity=8, alive=lambda p: True))

    def test_full(self):
        self.assertFalse(sdpsched.fits(self.jobs(("a", "running", 8)), 1, capacity=8, alive=lambda p: True))

    def test_waiting_jobs_ahead_that_fit_take_the_room_first(self):
        jobs = self.jobs(("a", "running", 4), ("b", "queued", 4))
        self.assertFalse(sdpsched.fits(jobs, 2, capacity=8, alive=lambda p: True))


class LocalJobs(unittest.TestCase):
    """A job placed here answers status, wait --fetch and fetch --job like one there, from its snapshot."""

    def setUp(self):
        self.tmp = isolate(self)
        self.root = os.path.join(self.tmp, "tree")
        os.makedirs(self.root)
        patch(self, remote, ROOT=self.root, ssh=self.no_ssh)

    def no_ssh(self, *_a, **_kw):
        raise AssertionError("a job placed here needs no ssh")

    def place(self, name, code=None, pid=None):
        snap = remote.runs_dir("snap", name)
        os.makedirs(os.path.join(snap, "logs", "remote"))
        with open(os.path.join(snap, "logs", "remote", name + ".jsonl"), "w") as fh:
            fh.write("row\n")
        sdplock._write(remote.runs_dir(name + ".json"), {"name": name, "pid": pid or os.getpid(), "snap": snap,
                                                        "owner": "mac/x", "started": time.time()})
        with open(remote.runs_dir(name + ".log"), "w") as fh:
            fh.write("[3/3] done\n")
        if code is not None:
            with open(remote.runs_dir(name + ".exit"), "w") as fh:
                fh.write("%d\n" % code)

    def test_wait_fetches_from_the_snapshot_and_returns_the_exit_code(self):
        self.place("j", code=1)
        code = remote.wait(argparse.Namespace(name="j", fetch=["logs/remote/j.jsonl"], every=0))
        self.assertEqual(code, 1)
        with open(os.path.join(self.root, "logs", "remote", "j.jsonl")) as fh:
            self.assertEqual(fh.read(), "row\n")

    def test_state_running_then_lost(self):
        self.place("j")
        self.assertEqual(remote.state("j"), (None, "[3/3] done"))
        patch(self, sdplock, pid_alive=lambda pid: False)
        self.assertEqual(remote.state("j")[0], 1)

    def test_status_names_the_machine(self):
        self.place("j", code=0)
        patch(self, remote, install_sched=lambda: None, sched=lambda *_a, **_kw: "slots in use: 0 of 8\n")
        out = self.capture(remote.status, argparse.Namespace(name="j"))
        self.assertIn("this machine", out)
        out = self.capture(remote.status, argparse.Namespace(name=None))
        self.assertIn("this machine", out)
        self.assertIn("j ", out)
        self.assertIn("slots in use", out)

    def capture(self, fn, args):
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            fn(args)
        return buf.getvalue()

    def test_local_run_goes_through_heavy_and_writes_the_exit_code(self):
        seen = {}

        def heavy(root, name, cmd, me=None, **_kw):
            seen.update(root=root, name=name, cmd=cmd, me=me)
            return 3
        patch(self, sdplock, run_heavy=heavy)
        code = remote.local_run(argparse.Namespace(name="j", owner="mac/x", tree="/w", command=["node", "a.mjs"]))
        self.assertEqual(code, 3)
        self.assertEqual(seen, {"root": self.root, "name": "j", "cmd": ["node", "a.mjs"],
                                "me": {"owner": "mac/x", "tree": "/w"}})
        self.assertEqual(remote.read_exit(remote.runs_dir("j.exit")), 3)

    def test_a_running_name_here_is_refused(self):
        self.place("j")
        with self.assertRaises(SystemExit):
            remote.run(job("j"))

    def test_old_jobs_here_are_pruned(self):
        self.place("old", code=0)
        os.utime(remote.runs_dir("old.exit"), (time.time() - 8 * 86400,) * 2)
        self.place("new", code=0)
        self.assertEqual(remote.prune_local(), ["old"])
        self.assertFalse(os.path.exists(remote.runs_dir("snap", "old")))
        self.assertTrue(os.path.exists(remote.runs_dir("snap", "new")))


@unittest.skipUnless(shutil.which("git") and sys.platform != "win32", "needs git and symbolic links")
class Snapshot(unittest.TestCase):
    def test_later_edits_do_not_reach_the_snapshot(self):
        tmp = isolate(self)
        src, dest = os.path.join(tmp, "src"), os.path.join(tmp, "snap")
        os.makedirs(os.path.join(src, "tools"))
        os.makedirs(os.path.join(tmp, "mods"))
        subprocess.run(["git", "init", "-q", src], check=True)
        for rel, text in (("tools/a.py", "one"), (".gitignore", "logs/\n"), ("new.txt", "untracked"),
                          ("logs/big.log", "ignored")):
            os.makedirs(os.path.dirname(os.path.join(src, rel)), exist_ok=True)
            with open(os.path.join(src, rel), "w") as fh:
                fh.write(text)
        subprocess.run(["git", "add", "tools/a.py", ".gitignore"], cwd=src, check=True)
        os.symlink(os.path.join(tmp, "mods"), os.path.join(src, "tools", "node_modules"))
        remote.snapshot(src, dest)
        with open(os.path.join(src, "tools", "a.py"), "w") as fh:
            fh.write("two")
        with open(os.path.join(dest, "tools", "a.py")) as fh:
            self.assertEqual(fh.read(), "one")
        self.assertTrue(os.path.exists(os.path.join(dest, "new.txt")))
        self.assertFalse(os.path.exists(os.path.join(dest, "logs", "big.log")))
        self.assertTrue(os.path.isdir(os.path.join(dest, "logs", "remote")))
        self.assertEqual(os.path.realpath(os.path.join(dest, "tools", "node_modules")),
                         os.path.realpath(os.path.join(tmp, "mods")))


@unittest.skipUnless(shutil.which("git") and shutil.which("rsync") and sys.platform != "win32",
                     "needs git, rsync and sh")
class Sync(unittest.TestCase):
    """#269: a tracked file deleted but not committed made rsync --files-from fail, so run never started.
    ssh is a script that runs the command here in a home directory of its own; rsync is the real one."""

    def setUp(self):
        tmp = isolate(self)
        self.root, self.home, fake = (os.path.join(tmp, d) for d in ("tree", "home", "bin"))
        os.makedirs(self.home)
        os.makedirs(fake)
        with open(os.path.join(fake, "ssh"), "w") as fh:  # ssh [-o opt]... host command...
            fh.write('#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\n'
                     'export HOME=%s\ncd "$HOME" && exec sh -c "$*"\n' % shlex.quote(self.home))
        os.chmod(os.path.join(fake, "ssh"), 0o755)
        self.addCleanup(os.environ.__setitem__, "PATH", os.environ["PATH"])
        os.environ["PATH"] = fake + os.pathsep + os.environ["PATH"]
        subprocess.run(["git", "init", "-q", self.root], check=True)
        for rel in ("keep.txt", "changelog.d/1.md"):
            os.makedirs(os.path.dirname(os.path.join(self.root, rel)), exist_ok=True)
            with open(os.path.join(self.root, rel), "w") as fh:
                fh.write(rel)
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        patch(self, remote, ROOT=self.root, install_sched=lambda: None)

    def there(self, rel):
        return os.path.exists(os.path.join(self.home, remote.TREE, rel))

    def test_a_deleted_uncommitted_file_is_removed_there_too(self):
        remote.sync(None)
        self.assertTrue(self.there("changelog.d/1.md"))
        os.remove(os.path.join(self.root, "changelog.d", "1.md"))
        self.assertEqual(remote.sync(None), 0)
        self.assertFalse(self.there("changelog.d/1.md"))
        self.assertTrue(self.there("keep.txt"))


class Direct(unittest.TestCase):
    """#249: offline_tests.mjs and compare.mjs started by hand register themselves; long ones are placed
    like remote.py run. Before, 7 such runs showed as unregistered on the status page in one day."""

    def setUp(self):
        self.tmp = isolate(self)

    def test_estimate(self):
        remote.record_duration("spec_slow", 300)
        remote.record_duration("spec_quick", 2)
        node = ["node", "tools/offline_tests.mjs"]
        self.assertLess(remote.estimate(node + ["tests/offline/spec_new.lua"])[1], remote.LONG)
        self.assertEqual(remote.estimate(node + ["tests/offline/spec_new.lua"])[0], "spec_new")
        self.assertLess(remote.estimate(node + ["tests/offline/spec_quick.lua"])[1], remote.LONG)
        self.assertGreater(remote.estimate(node + ["tests/offline/spec_slow.lua"])[1], remote.LONG)
        self.assertGreater(remote.estimate(node + ["tests/offline/spec_multi.lua"])[1], remote.LONG)
        self.assertGreater(remote.estimate(node + ["tests/offline/bench_dense_trace.lua"])[1], remote.LONG)
        self.assertGreater(remote.estimate(node)[1], remote.LONG)  # the whole suite
        self.assertIsNone(remote.estimate(node + ["-k", "x", "tests/offline/spec_new.lua"])[0])
        self.assertGreater(remote.estimate(["node", "tools/compare.mjs", "-s", "^S"])[1], remote.LONG)
        self.assertLess(remote.estimate(["node", "tools/compare.mjs", "--probe", "p.lua"])[1], remote.LONG)

    def test_short_run_is_registered_here_and_timed(self):
        check = ("import glob, os, sys; shared = os.environ['SDP_SHARED']; "
                 "shown = [p for p in glob.glob(shared + '/light/*.json') if not p.endswith('-caller.json')]; "
                 "sys.exit(0 if shown and os.environ.get('SDP_PLACED') else 5)")
        cmd = [sys.executable, "-c", check, "tests/offline/spec_tiny.lua"]
        argv = sys.argv
        self.addCleanup(setattr, sys, "argv", argv)
        code = remote.direct(argparse.Namespace(command=cmd))
        self.assertEqual(code, 0)
        self.assertIn("spec_tiny", remote.durations())
        self.assertEqual(sdplock.light_jobs(), [])  # forgotten when done

    def test_long_run_goes_where_remote_run_would(self):
        calls = []
        patch(self, remote, can_go_remote=lambda cmd, cwd: True,
              run_remote_and_wait=lambda name, cmd: calls.append("there") or 0)
        patch(self, sdplock, run_heavy=lambda root, name, cmd, **kw: calls.append("here") or 0)
        cmd = ["node", "tools/offline_tests.mjs", "tests/offline/spec_multi.lua"]
        for free, fits, where in ((True, "no", "here"), (True, "yes", "there"), (False, "no", "there")):
            calls.clear()
            patch(self, remote, local_free=lambda: free, remote_fits=lambda name, slots: fits)
            self.assertEqual(remote.direct(argparse.Namespace(command=cmd)), 0)
            self.assertEqual(calls, [where], (free, fits))

    def test_long_run_sent_there_names_worktree_paths_relatively(self):
        # the job runs in the copy on the second machine: an absolute path into this worktree must not
        # survive, or the test file is missing there and --out writes outside the snapshot fetched back
        sent = []
        patch(self, remote, can_go_remote=lambda cmd, cwd: True, local_free=lambda: False,
              run_remote_and_wait=lambda name, cmd: sent.append(cmd) or 0)
        spec = os.path.join(remote.ROOT, "tests", "offline", "spec_multi.lua")
        out = os.path.join(remote.ROOT, "logs", "remote", "a.jsonl")
        remote.direct(argparse.Namespace(command=["node", "tools/offline_tests.mjs", spec, "--out", out]))
        self.assertEqual(sent, [["node", "tools/offline_tests.mjs", os.path.join("tests", "offline", "spec_multi.lua"),
                                 "--out", os.path.join("logs", "remote", "a.jsonl")]])

    def test_long_run_that_cannot_go_there_runs_heavy_here(self):
        calls = []
        patch(self, remote, can_go_remote=lambda cmd, cwd: False,
              run_remote_and_wait=lambda name, cmd: calls.append("there") or 0)
        patch(self, sdplock, run_heavy=lambda root, name, cmd, **kw: calls.append("here") or 0)
        remote.direct(argparse.Namespace(command=["node", "tools/offline_tests.mjs", "tests/offline/bench_x.lua"]))
        self.assertEqual(calls, ["here"])

    def test_outputs_and_eligibility(self):
        self.assertEqual(remote.outputs(["node", "tools/compare.mjs", "--out", "logs/remote/a.jsonl"]),
                         [os.path.join("logs", "remote", "a.jsonl")])
        self.assertEqual(remote.outputs(["node", "tools/offline_tests.mjs"]), [])
        root = remote.ROOT
        self.assertFalse(remote.can_go_remote(["node", "tools/compare.mjs", "--out", "/tmp/x.jsonl"], root))
        self.assertFalse(remote.can_go_remote(["node", "tools/offline_tests.mjs"], os.path.dirname(root)))
        self.assertTrue(remote.can_go_remote(["node", "tools/offline_tests.mjs", "tests/offline/spec_multi.lua"],
                                             root))


@unittest.skipUnless(shutil.which("node") and sys.platform != "win32", "needs node and a shell")
class PlaceMjs(unittest.TestCase):
    """tools/place.mjs hands a run by hand to remote.py direct, except in CI (no local config) and for the
    runs the tools start (SDP_PLACED)."""

    def run_node(self, **env):
        tmp = isolate(self)
        log = os.path.join(tmp, "argv")
        fake = os.path.join(tmp, "fake-python")
        with open(fake, "w") as fh:
            fh.write('#!/bin/sh\necho "$@" > %s\nexit 7\n' % log)
        os.chmod(fake, 0o755)
        environ = dict(os.environ, SDP_PYTHON=fake, **env)
        if env.get("SDP_LOCAL_CONFIG") == "write":
            with open(os.path.join(tmp, "local.json"), "w") as fh:
                json.dump({}, fh)
            environ["SDP_LOCAL_CONFIG"] = os.path.join(tmp, "local.json")
        done = subprocess.run(["node", "tools/offline_tests.mjs", "--bad-flag"], cwd=os.path.dirname(TOOLS),
                              env=environ, capture_output=True, text=True, timeout=60)
        argv = None
        if os.path.exists(log):
            with open(log) as fh:
                argv = fh.read().split()
        return done.returncode, argv

    def test_with_local_config_it_goes_through_remote_py_direct(self):
        code, argv = self.run_node(SDP_LOCAL_CONFIG="write")
        self.assertEqual(code, 7)
        self.assertEqual(argv[1:], ["direct", "--", "node", os.path.join("tools", "offline_tests.mjs"), "--bad-flag"])
        self.assertTrue(argv[0].endswith("remote.py"))

    def test_without_local_config_or_when_placed_it_runs_as_asked(self):
        self.assertEqual(self.run_node(), (2, None))  # usage error from offline_tests.mjs itself
        self.assertEqual(self.run_node(SDP_LOCAL_CONFIG="write", SDP_PLACED="1"), (2, None))


if __name__ == "__main__":
    unittest.main()
