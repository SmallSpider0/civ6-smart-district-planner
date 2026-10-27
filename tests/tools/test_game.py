"""Offline tests of tools/game.py's check that the mod is ticked (pitfall 45).

    python3 -I -m unittest discover -s tests/tools -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import game  # noqa: E402


class ModEnabledTest(unittest.TestCase):
    def test_ticked(self):
        self.assertEqual(game.mod_enabled(["SDP_MOD true 201"]), (True, ""))

    def test_unticked(self):
        ok, why = game.mod_enabled(["noise", "SDP_MOD false 201"])
        self.assertFalse(ok)
        self.assertIn("unticked", why)
        self.assertIn("EnableMod(201, true)", why)

    def test_one_of_two_copies_ticked(self):
        self.assertTrue(game.mod_enabled(["SDP_MOD false 12", "SDP_MOD true 201"])[0])

    def test_not_installed(self):
        ok, why = game.mod_enabled([])
        self.assertFalse(ok)
        self.assertIn("not installed", why)

    def test_check_reads_the_main_menu(self):
        calls = []
        saved = game.exec_lua
        game.exec_lua = lambda state, code, **kw: calls.append((state, code)) or {"ok": True, "output": ["SDP_MOD false 201"]}
        try:
            self.assertFalse(game.check_mod_enabled())
        finally:
            game.exec_lua = saved
        self.assertEqual(calls[0][0], "MainMenu")
        self.assertIn(game.MOD_ID, calls[0][1])


if __name__ == "__main__":
    unittest.main()
