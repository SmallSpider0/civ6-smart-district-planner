#!/usr/bin/env python3
"""game - start, enter and quit Civilization VI for testing (macOS).

  game.py quit       quit the running game through the tuner, wait for exit
  game.py menu       leave the current game for the main menu (reloads the
                     mod's Lua and UI XML on the next game; not the modinfo)
  game.py popups     list the Lua contexts queued as popups; --close dequeues
                     them all except SDP_Panel (e.g. historic moments that
                     keep the planner panel hidden behind them)
  game.py launch     open the game through Steam (the Aspyr launcher's
                     "开始" button then needs a click: computer-use AXPress)
  game.py newgame    wait for the main menu, quick-start a game, wait until
                     in-game Lua answers; --capital also founds the capital
                     (tests/fixtures/found_capital.lua). The leader and the
                     map/game seeds are fixed (--leader, --seed) so every test
                     game is the same map; --random keeps Play Now's choices.

Exit codes: 0 done, 2 the game did not reach the expected state in time.
"""

import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import civ6tuner  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STEAM_URL = "steam://rungameid/289070"
FOUND_CAPITAL = os.path.join(ROOT, "tests", "fixtures", "found_capital.lua")
DEFAULT_LEADER = "LEADER_TRAJAN"  # Rome: starts on land, every ruleset has it
DEFAULT_SEED = 20261019

# Play Now (MainMenu OnStateTransition) resets the configuration and then
# calls the global GameSetup_RefreshParameters; wrapping it lets us pin the
# leader and the seeds after the defaults are in place.
FIXED_SETUP = """
SDP_TestSetupOriginal = SDP_TestSetupOriginal or GameSetup_RefreshParameters
GameSetup_RefreshParameters = function(...)
  SDP_TestSetupOriginal(...)
  PlayerConfigurations[0]:SetLeaderTypeName("%(leader)s")
  GameConfiguration.SetValue("GAME_SYNC_RANDOM_SEED", %(seed)d)
  MapConfiguration.SetValue("RANDOM_SEED", %(seed)d)
end
"""
RANDOM_SETUP = """
if SDP_TestSetupOriginal then GameSetup_RefreshParameters = SDP_TestSetupOriginal end
"""


def game_running():
    return subprocess.run(["pgrep", "-f", "Civ6_Exe"], capture_output=True).returncode == 0


def exec_lua(state, code, timeout=5.0, raw=False):
    return civ6tuner.request({"op": "exec", "state": state, "code": code, "timeout": timeout, "raw": raw})


def wait_for(label, check, timeout, interval=3.0):
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        if check():
            print("%s after %.0fs" % (label, time.monotonic() - started), flush=True)
            return True
        time.sleep(interval)
    print("timed out waiting for %s (%.0fs)" % (label, timeout), flush=True)
    return False


def has_state(name):
    resp = civ6tuner.request({"op": "states"})
    return resp.get("ok") and any(n == name for _, n in resp["states"])


def cmd_quit(_args):
    if not game_running():
        print("game not running")
        return 0
    exec_lua("InGame", "Events.UserConfirmedClose()", raw=True)
    if not has_state("InGame"):  # main menu: the same event quits there too
        exec_lua("MainMenu", "Events.UserConfirmedClose()", raw=True)
    return 0 if wait_for("game exit", lambda: not game_running(), 60, 2) else 2


def cmd_menu(_args):
    exec_lua("InGame", "Events.ExitToMainMenu()", raw=True)
    gone = lambda: not has_state("InGame") and has_state("MainMenu")  # noqa: E731
    return 0 if wait_for("main menu", gone, 120) else 2


def cmd_popups(args):
    resp = civ6tuner.request({"op": "states"})
    if not resp.get("ok"):
        print(resp.get("error"))
        return 2
    check = "if ContextPtr and UIManager:IsInPopupQueue(ContextPtr) then print('QUEUED') end"
    close = "if ContextPtr and UIManager:IsInPopupQueue(ContextPtr) then UIManager:DequeuePopup(ContextPtr) end"
    for _idx, name in resp["states"]:
        if "QUEUED" in (exec_lua(name, check, timeout=3).get("output") or []):
            if args.close and name != "SDP_Panel":
                exec_lua(name, close, timeout=3)
                print("closed", name)
            else:
                print("queued", name)
    return 0


def cmd_launch(_args):
    subprocess.run(["open", STEAM_URL], check=True)
    ok = wait_for("launcher", game_running, 180, 2)  # Steam can take over a minute
    print("next: press the launcher's start button (computer-use, bundle com.aspyr.civ6.steam)")
    return 0 if ok else 2


def cmd_newgame(args):
    if not wait_for("main menu", lambda: has_state("MainMenu"), args.timeout):
        return 2
    setup = RANDOM_SETUP if args.random else FIXED_SETUP % {"leader": args.leader, "seed": args.seed}
    resp = exec_lua("MainMenu", setup + "Automation.SetAutoStartEnabled(true); OnPlayCiv6()")
    if not resp.get("ok"):
        print("could not start a game: %s" % resp.get("error"))
        return 2
    in_game = lambda: exec_lua(args.state, "print(1)").get("ok")  # noqa: E731
    if not wait_for("state %s" % args.state, in_game, args.timeout, 5):
        return 2
    if args.capital:
        with open(FOUND_CAPITAL, encoding="utf-8") as fh:
            resp = exec_lua("InGame", fh.read())
        print("\n".join(resp.get("output") or []) or resp.get("error"))
        has_capital = lambda: "true" in (exec_lua(  # noqa: E731
            "InGame", "print(tostring(Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity() ~= nil))"
        ).get("output") or [])
        if not wait_for("capital", has_capital, 30, 1):
            return 2
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Start, enter and quit the game for testing")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("quit", help="quit the running game")
    sub.add_parser("menu", help="leave the current game for the main menu")
    pp = sub.add_parser("popups", help="list (or close) queued popups")
    pp.add_argument("--close", action="store_true", help="dequeue every popup except SDP_Panel")
    sub.add_parser("launch", help="open the game through Steam")
    np = sub.add_parser("newgame", help="quick-start a game from the main menu")
    np.add_argument("--state", default="InGame", help="Lua state to wait for (default InGame)")
    np.add_argument("--capital", action="store_true", help="also found the capital")
    np.add_argument("--leader", default=DEFAULT_LEADER, help="local player's leader (default %s)" % DEFAULT_LEADER)
    np.add_argument("--seed", type=int, default=DEFAULT_SEED, help="map and game seed (default %d)" % DEFAULT_SEED)
    np.add_argument("--random", action="store_true", help="keep Play Now's random leader and map")
    np.add_argument("--timeout", type=float, default=300)
    args = ap.parse_args(argv)
    commands = {"quit": cmd_quit, "menu": cmd_menu, "popups": cmd_popups, "launch": cmd_launch, "newgame": cmd_newgame}
    return commands[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
