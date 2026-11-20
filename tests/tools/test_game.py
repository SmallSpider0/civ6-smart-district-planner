"""Offline tests of tools/game.py: the check that the mod is ticked (pitfall 45), new games.

    python3 -I -m unittest discover -s tests/tools -v
"""
import os
import sys
import types
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


class NewGameTest(unittest.TestCase):
    def test_capital_closes_queued_popups_before_founding(self):
        # The base game's advisor popup holds the event queue: the found-city
        # request waits behind it until the capital times out (#373).
        events = []
        saved = {name: getattr(game, name) for name in
                 ("has_state", "wait_for", "check_mod_enabled", "exec_lua", "close_popups")}

        def exec_lua(state, code, **kw):
            if "FOUND_CITY" in code:
                events.append("found")
            return {"ok": True, "output": ["true"]}

        game.has_state = lambda name: name == "MainMenu"
        game.wait_for = lambda label, check, timeout, interval=3.0: check() or True
        game.check_mod_enabled = lambda: True
        game.exec_lua = exec_lua
        game.close_popups = lambda rounds=20: events.append("close") or True
        args = types.SimpleNamespace(timeout=5, ruleset="RULESET_STANDARD", random=False, leader="LEADER_TRAJAN",
                                     seed=1, state="SDP_Panel", capital=True, reveal=False)
        try:
            self.assertEqual(game.start_game(args), 0)
        finally:
            for name, value in saved.items():
                setattr(game, name, value)
        self.assertIn("found", events)
        self.assertIn("close", events[:events.index("found")])
