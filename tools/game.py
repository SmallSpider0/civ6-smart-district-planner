#!/usr/bin/env python3
"""game - start, enter and quit Civilization VI for testing.

  game.py quit       quit the running game through the tuner, wait for exit
  game.py menu       leave the current game for the main menu (reloads the
                     mod's Lua and UI XML on the next game; not the modinfo)
  game.py popups     list the Lua contexts queued as popups; --close closes
                     them all except SDP_Panel (e.g. historic moments that
                     keep the planner panel hidden behind them) through the
                     popup's own Close/OnClose: popups such as natural wonders
                     hold the engine's event queue until they release it, and
                     a plain dequeue leaves the UI's copy of the game stale
  game.py launch     open the game through Steam (the Aspyr launcher's
                     "开始" button then needs a click: computer-use AXPress).
                     Notes the app in front first; the next newgame gives the
                     front back to it whenever the game takes it while
                     loading (--stay: leave the game in front)
  game.py newgame    wait for the main menu, quick-start a game, wait until
                     in-game Lua answers; --capital also founds the capital
                     (tests/fixtures/found_capital.lua); --reveal then
                     reveals the land around it (tests/fixtures/reveal_area.lua)
                     and closes the popups that follows. The leader and the
                     map/game seeds are fixed (--leader, --seed) so every test
                     game is the same map; --random keeps Play Now's choices;
                     --ruleset picks the base game, Rise and Fall or GS.
                     While it waits, the game is kept out of the front if
                     another app was in front (see launch). Mutes the game
                     for the run (the saved volume is not changed).
  game.py load NAME  load the single-player save Saves/Single/NAME.Civ6Save
                     from the main menu (leaves a game first), the load
                     screen pressing its own continue button; waits until
                     in-game Lua answers and closes the popups. Mutes too.
                     A save asking for content this account lacks stops at
                     the game's own warning (timeout, exit code 2).

Every command takes the game lock for this worktree (tools/sdplock.py) and
refuses, with exit code 4, while another worktree holds it; quit releases it
and stops this worktree's Tuner daemon. launch, newgame and load start that
daemon (civ6tuner.py serve, output in logs/tuner-serve.out) when none answers.

quit, menu, popups and newgame work through the tuner on macOS and Windows.
launch opens Steam on both; the launcher click and keeping the game out of
the front are macOS only (on Windows the game simply comes to the front).

Exit codes: 0 done, 2 the game did not reach the expected state in time,
4 the game is held by another worktree.
"""

import argparse
import os
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import civ6tuner  # noqa: E402
import sdplock  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STEAM_URL = "steam://rungameid/289070"
FOUND_CAPITAL = os.path.join(ROOT, "tests", "fixtures", "found_capital.lua")
REVEAL_AREA = os.path.join(ROOT, "tests", "fixtures", "reveal_area.lua")
DEFAULT_LEADER = "LEADER_TRAJAN"  # Rome: starts on land, every ruleset has it
DEFAULT_SEED = 20261019
CIV6_BUNDLE = "com.aspyr.civ6.steam"  # the launcher and the game window alike
# macOS hands the front to Finder when the game's window goes away while the
# game is active (seen in the game 2026-10-20 between the main menu and the
# map): Finder is then not where the user is, so it is never followed.
FINDER_BUNDLE = "com.apple.finder"
FRONT_RECORD = os.path.join(ROOT, "logs", "front-app.txt")  # launch writes it, newgame uses it up
FRONT_RECORD_TTL = 900  # seconds; older records are from a launch that never got to newgame

# Play Now (MainMenu OnStateTransition) resets the configuration and then
# calls the global GameSetup_RefreshParameters; wrapping it lets us pin the
# leader and the seeds after the defaults are in place.
FIXED_SETUP = """
SDP_TestSetupOriginal = SDP_TestSetupOriginal or GameSetup_RefreshParameters
GameSetup_RefreshParameters = function(...)
  %(ruleset)s
  SDP_TestSetupOriginal(...)
  PlayerConfigurations[0]:SetLeaderTypeName("%(leader)s")
  GameConfiguration.SetValue("GAME_SYNC_RANDOM_SEED", %(seed)d)
  MapConfiguration.SetValue("RANDOM_SEED", %(seed)d)
end
"""
RANDOM_SETUP = """
if SDP_TestSetupOriginal then GameSetup_RefreshParameters = SDP_TestSetupOriginal end
"""
# Master volume 0 for this run only: the last argument 0 is what the options
# screen's slider uses while dragging (applied, not committed), so
# SoundOpts.txt and the player's own volume stay as they are.
MUTE = 'Options.SetAudioOption("Sound", "Master Volume", 0, 0)'


game_running = sdplock.game_running
SERVE_OUT = os.path.join(ROOT, "logs", "tuner-serve.out")


def ensure_serve(wait=15.0):
    """Start this worktree's Tuner daemon (civ6tuner.py serve) unless one
    answers. quit stops it; without it, the direct connections newgame and
    load fall back to are refused while the game loads (2026-10-26)."""
    if civ6tuner.daemon_request({"op": "states"}, 2.0) is not None:
        return
    os.makedirs(os.path.dirname(SERVE_OUT), exist_ok=True)
    out = open(SERVE_OUT, "ab")
    flags = {"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP} \
        if sys.platform == "win32" else {"start_new_session": True}
    proc = subprocess.Popen([sys.executable, "-I", os.path.join(ROOT, "tools", "civ6tuner.py"), "serve"],
                            stdin=subprocess.DEVNULL, stdout=out, stderr=out, **flags)
    out.close()
    deadline = time.time() + wait
    while time.time() < deadline:
        if civ6tuner.daemon_request({"op": "states"}, 2.0) is not None:
            print("started the Tuner daemon (pid %d, output %s)" % (proc.pid, SERVE_OUT), flush=True)
            return
        if proc.poll() is not None:
            break
        time.sleep(0.5)
    print("the Tuner daemon did not come up (see %s); going on with direct connections" % SERVE_OUT, flush=True)


def front_app():
    """Bundle id of the frontmost regular app (one with a Dock icon), else None (always None off macOS)."""
    if sys.platform != "darwin":
        return None
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    if not asn:
        return None
    info = subprocess.run(["lsappinfo", "info", asn], capture_output=True, text=True).stdout
    bundle = re.search(r'bundleID="([^"]+)"', info)
    kind = re.search(r'\btype="([^"]+)"', info)
    if bundle is None or kind is None or kind.group(1) != "Foreground":
        return None
    return bundle.group(1)


def app_running(bundle):
    found = subprocess.run(["lsappinfo", "find", "bundleid=" + bundle], capture_output=True, text=True)
    return bool(found.stdout.strip())


class FrontGuard(threading.Thread):
    """While the game starts, give the front back to the app the user is in.

    The launcher and the game window bring themselves to the front when they
    appear (activateIgnoringOtherApps). With the game assigned to its own
    desktop that also switches the screen there. Each time the game takes the
    front, this reactivates the last other app that had it, which switches
    the screen back.
    """

    def __init__(self, bundle):
        super().__init__(daemon=True)
        self.bundle = bundle
        self.done = threading.Event()

    def run(self):
        while not self.done.wait(0.5):
            front = front_app()
            if front is None:
                continue
            if front == FINDER_BUNDLE:
                continue
            if front != CIV6_BUNDLE:
                self.bundle = front  # the user moved on: follow them
            elif app_running(self.bundle):
                subprocess.run(["open", "-b", self.bundle], capture_output=True)
                print("front given back to %s" % self.bundle, flush=True)
                self.done.wait(1.5)  # activation takes a moment; don't ask twice

    def stop(self):
        self.done.set()
        self.join()


def recorded_front():
    """The app that was in front when launch ran, if that was recent."""
    try:
        if time.time() - os.path.getmtime(FRONT_RECORD) > FRONT_RECORD_TTL:
            return None
        with open(FRONT_RECORD, encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def forget_front():
    try:
        os.remove(FRONT_RECORD)
    except OSError:
        pass


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
    sdplock.claim_or_exit(ROOT)  # never quit another worktree's game
    if game_running():
        exec_lua("InGame", "Events.UserConfirmedClose()", raw=True)
        if not has_state("InGame"):  # main menu: the same event quits there too
            exec_lua("MainMenu", "Events.UserConfirmedClose()", raw=True)
        if not wait_for("game exit", lambda: not game_running(), 60, 2):
            return 2
    else:
        print("game not running")
    print(sdplock.release(ROOT))  # also stops this worktree's Tuner daemon
    return 0


def cmd_menu(_args):
    exec_lua("InGame", "Events.ExitToMainMenu()", raw=True)
    gone = lambda: not has_state("InGame") and has_state("MainMenu")  # noqa: E731
    return 0 if wait_for("main menu", gone, 120) else 2


CHECK_QUEUED = "if ContextPtr and UIManager:IsInPopupQueue(ContextPtr) then print('QUEUED') end"
# Close a popup the way its own close button does, so it also releases the
# engine event it holds (PopupManager:Unlock); dequeue only as a fallback.
CLOSE_POPUP = """
if ContextPtr and UIManager:IsInPopupQueue(ContextPtr) then
  local close = (type(OnClose) == "function" and OnClose) or (type(Close) == "function" and Close) or nil
  if close then pcall(close) end
  if UIManager:IsInPopupQueue(ContextPtr) then UIManager:DequeuePopup(ContextPtr) end
end
"""


def queued_popups():
    resp = civ6tuner.request({"op": "states"})
    if not resp.get("ok"):
        return None
    return [name for _idx, name in resp["states"]
            if name != "SDP_Panel" and "QUEUED" in (exec_lua(name, CHECK_QUEUED, timeout=3).get("output") or [])]


def close_popups(rounds=20):
    """Close queued popups until none comes back for two checks in a row."""
    quiet = 0
    for _ in range(rounds):
        names = queued_popups()
        if names is None:
            return False
        if not names:
            quiet += 1
            if quiet >= 2:
                return True
        else:
            quiet = 0
            for name in names:
                exec_lua(name, CLOSE_POPUP, timeout=3)
                print("closed", name, flush=True)
        time.sleep(1.5)  # the next queued popup shows a frame later
    return False


def cmd_popups(args):
    if args.close:
        return 0 if close_popups() else 2
    names = queued_popups()
    if names is None:
        return 2
    for name in names:
        print("queued", name)
    return 0


def cmd_launch(args):
    sdplock.claim_or_exit(ROOT)
    ensure_serve()
    front = None if args.stay else front_app()
    forget_front()
    if front is not None and front != CIV6_BUNDLE:
        os.makedirs(os.path.dirname(FRONT_RECORD), exist_ok=True)
        with open(FRONT_RECORD, "w", encoding="utf-8") as fh:
            fh.write(front)
        print("in front: %s (newgame gives the front back to it)" % front, flush=True)
    if sys.platform == "win32":
        os.startfile(STEAM_URL)
    else:
        subprocess.run(["open", "-g", STEAM_URL], check=True)  # -g: leave Steam itself in the background
    ok = wait_for("game process", game_running, 180, 2)  # Steam can take over a minute
    if sys.platform == "darwin":
        print("next: press the launcher's start button (computer-use, bundle %s), then newgame" % CIV6_BUNDLE)
    else:
        print("next: if a launcher window asks, start the game by hand, then newgame")
    return 0 if ok else 2


def cmd_newgame(args):
    # Right after launch the game is in front and the record says where the
    # user was; otherwise keep them in the app they are in, unless that is
    # the game itself (they are watching it).
    back_to = recorded_front()
    if back_to is None:
        front = front_app()
        back_to = front if front != CIV6_BUNDLE else None
    guard = FrontGuard(back_to) if back_to else None
    if guard:
        guard.start()
    try:
        sdplock.claim_or_exit(ROOT)
        ensure_serve()
        return start_game(args)
    finally:
        if guard:
            guard.stop()
        forget_front()


def start_game(args):
    # Called inside a game, leave it first: waiting for the main menu would
    # only run into the timeout (2026-10-22).
    if has_state("InGame") and cmd_menu(args) != 0:
        return 2
    if not wait_for("main menu", lambda: has_state("MainMenu"), args.timeout):
        return 2
    ruleset = 'GameConfiguration.SetValue("RULESET", "%s")' % args.ruleset if args.ruleset else ""
    setup = RANDOM_SETUP if args.random else FIXED_SETUP % {"leader": args.leader, "seed": args.seed, "ruleset": ruleset}
    resp = exec_lua("MainMenu", MUTE + "; " + setup + "Automation.SetAutoStartEnabled(true); OnPlayCiv6()")
    if not resp.get("ok"):
        print("could not start a game: %s" % resp.get("error"))
        return 2
    in_game = lambda: exec_lua(args.state, "print(1)").get("ok")  # noqa: E731
    if not wait_for("state %s" % args.state, in_game, args.timeout, 5):
        return 2
    exec_lua("InGame", MUTE)  # again: loading a game may reapply the saved volume
    if args.capital:
        with open(FOUND_CAPITAL, encoding="utf-8") as fh:
            resp = exec_lua("InGame", fh.read())
        print("\n".join(resp.get("output") or []) or resp.get("error"))
        has_capital = lambda: "true" in (exec_lua(  # noqa: E731
            "InGame", "print(tostring(Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity() ~= nil))"
        ).get("output") or [])
        if not wait_for("capital", has_capital, 30, 1):
            return 2
    if args.reveal:
        with open(REVEAL_AREA, encoding="utf-8") as fh:
            resp = exec_lua("GameCore_Tuner", fh.read())
        print("\n".join(resp.get("output") or []) or resp.get("error"))
        close_popups()
    return 0


LOAD_SAVE = """
Automation.SetAutoStartEnabled(true)
Network.LoadGame({ Name = "%s", Location = SaveLocations.LOCAL_STORAGE, Type = SaveTypes.SINGLE_PLAYER,
  IsAutosave = false, IsQuicksave = false, Directory = SaveDirectories.DEFAULT }, ServerType.SERVER_TYPE_NONE)
"""


def cmd_load(args):
    sdplock.claim_or_exit(ROOT)
    ensure_serve()
    if has_state("InGame") and cmd_menu(args) != 0:
        return 2
    if not wait_for("main menu", lambda: has_state("MainMenu"), args.timeout):
        return 2
    resp = exec_lua("MainMenu", MUTE + "; " + LOAD_SAVE % args.name.replace("\\", "\\\\").replace('"', '\\"'))
    if not resp.get("ok"):
        print("could not load %s: %s" % (args.name, resp.get("error")))
        return 2
    in_game = lambda: exec_lua(args.state, "print(1)").get("ok")  # noqa: E731
    if not wait_for("state %s" % args.state, in_game, args.timeout, 5):
        return 2
    exec_lua("InGame", MUTE)
    time.sleep(5)
    close_popups()
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Start, enter and quit the game for testing")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("quit", help="quit the running game")
    sub.add_parser("menu", help="leave the current game for the main menu")
    pp = sub.add_parser("popups", help="list (or close) queued popups")
    pp.add_argument("--close", action="store_true", help="close every popup except SDP_Panel")
    lp = sub.add_parser("launch", help="open the game through Steam")
    lp.add_argument("--stay", action="store_true", help="leave the game in front (newgame does not give it back)")
    np = sub.add_parser("newgame", help="quick-start a game from the main menu")
    np.add_argument("--state", default="InGame", help="Lua state to wait for (default InGame)")
    np.add_argument("--capital", action="store_true", help="also found the capital")
    np.add_argument("--reveal", action="store_true", help="with --capital: reveal the land around it")
    np.add_argument("--leader", default=DEFAULT_LEADER, help="local player's leader (default %s)" % DEFAULT_LEADER)
    np.add_argument("--seed", type=int, default=DEFAULT_SEED, help="map and game seed (default %d)" % DEFAULT_SEED)
    np.add_argument("--random", action="store_true", help="keep Play Now's random leader and map")
    np.add_argument("--ruleset", help="RULESET_STANDARD, RULESET_EXPANSION_1 or RULESET_EXPANSION_2 "
                    "(default: Play Now's choice, the newest installed)")
    np.add_argument("--timeout", type=float, default=300)
    ldp = sub.add_parser("load", help="load a single-player save from the main menu")
    ldp.add_argument("name", help="file name in Saves/Single without .Civ6Save")
    ldp.add_argument("--state", default="InGame", help="Lua state to wait for (default InGame)")
    ldp.add_argument("--timeout", type=float, default=600)
    args = ap.parse_args(argv)
    commands = {"quit": cmd_quit, "menu": cmd_menu, "popups": cmd_popups, "launch": cmd_launch, "newgame": cmd_newgame,
                "load": cmd_load}
    return commands[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
