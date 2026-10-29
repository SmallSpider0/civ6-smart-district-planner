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
                 "host": lambda: "second", "remote_env": lambda: "export PATH=/opt/homebrew/bin:$PATH"}
        for name, value in fakes.items():
            self.addCleanup(setattr, remote, name, getattr(remote, name))
            setattr(remote, name, value)

    def test_prune_runs_with_the_remote_path(self):
        # Without the PATH, python3 on macOS can be a stub that asks for the Xcode license and fails,
        # so prune never ran and snapshots piled up (2026-10-29: 118 of them, 5.9 GB).
        remote.run(argparse.Namespace(name="job", slots=1, exclusive=False, command=["node", "x.mjs"]))
        start = [c for c in self.sent if "sdpsched.py prune" in c]
        self.assertEqual(len(start), 1)
        self.assertLess(start[0].index("export PATH="), start[0].index("sdpsched.py prune"))


if __name__ == "__main__":
    unittest.main()
