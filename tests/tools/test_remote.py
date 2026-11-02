"""Offline tests of tools/remote.py: the commands it sends, with ssh replaced.

    python3 -I -m unittest discover -s tests/tools -v
"""
import argparse
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import remote  # noqa: E402


class Run(unittest.TestCase):
    def setUp(self):
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


if __name__ == "__main__":
    unittest.main()
