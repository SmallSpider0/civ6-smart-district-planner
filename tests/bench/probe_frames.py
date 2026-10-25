"""Frame length and the sliced task's share by window state (issue 65).

On a loaded game (macOS): times every frame in the SDP_Panel state, first
with nothing running, then with a synthetic task stepped once per frame as
the panel does (tests/bench/probe_frames.lua), in each window state:

  front    the game is the frontmost app (its desktop is shown)
  behind   another app is in front (the game's desktop is not shown)
  hidden   the game is hidden (Cmd-H); skipped if macOS refuses

--slow-ms N instead runs the task only, the game left where it is, with N ms
of extra busy work in every frame outside the task (a slow game).

Brings the game to the front for the "front" phases, then gives the front
back to the app that had it. Prints one line per phase and writes
tests/bench/results/probe_frames.json. Also times AT_ONCE units in one
request, for the units-per-second of a solve at once.

    python3 -I tests/bench/probe_frames.py [--seconds 8] [--at-once 20000] [--slow-ms 60]
"""
import argparse
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import civ6tuner  # noqa: E402
import game  # noqa: E402

RESULTS = os.path.join(ROOT, "tests", "bench", "results")


def run(code, timeout=120):
    resp = civ6tuner.request({"op": "exec", "state": "SDP_Panel", "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise SystemExit("SDP_Panel: %s" % resp.get("error"))
    return resp.get("output") or []


def activate(bundle):
    subprocess.run(["open", "-b", bundle], capture_output=True)


def hide_game():
    script = ('tell application "System Events" to set visible of '
              '(first process whose bundle identifier is "%s") to false' % game.CIV6_BUNDLE)
    done = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return done.returncode == 0, done.stderr.strip()


def phases(user_app, seconds, label):
    walls = {}

    def phase(name, setup):
        ok = setup()
        if ok is False:
            print("  %s: skipped" % name, flush=True)
            return
        time.sleep(1.5)  # let the switch settle before counting
        run('SDP_Frames.Phase("%s-%s")' % (label, name))
        started = time.monotonic()
        time.sleep(seconds)
        walls["%s-%s" % (label, name)] = time.monotonic() - started
        run('SDP_Frames.Phase("%s-%s-after")' % (label, name))

    def hidden():
        ok, err = hide_game()
        if not ok:
            print("  hide refused: %s" % err, flush=True)
        return ok

    phase("front", lambda: activate(game.CIV6_BUNDLE))
    phase("behind", lambda: activate(user_app))
    phase("hidden", hidden)
    activate(user_app)
    return walls


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=8)
    ap.add_argument("--at-once", type=int, default=20000)
    ap.add_argument("--slow-ms", type=float)
    args = ap.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("macOS only")
    user_app = game.front_app()
    if user_app in (None, game.CIV6_BUNDLE, game.FINDER_BUNDLE):
        user_app = game.FINDER_BUNDLE
    with open(os.path.join(ROOT, "tests", "bench", "probe_frames.lua"), encoding="utf-8") as fh:
        run(fh.read())

    started = time.monotonic()
    run("SDP_Frames.AtOnce(%d)" % args.at_once, timeout=300)
    at_once = args.at_once / (time.monotonic() - started)
    print("at once: %.0f units/s" % at_once, flush=True)

    out = {"AtOnceUnitsPerSecond": at_once, "Runs": {}}
    runs = (("idle", False), ("task", True))
    slow = "nil"
    if args.slow_ms:
        runs = (("slow", True),)
        slow = str(int(args.slow_ms / 1000 * at_once * 2500))  # 2500 rounds per unit (probe_frames.lua)
        out["SlowMs"] = args.slow_ms
    for label, with_task in runs:
        print(label, run("SDP_Frames.Start(%s, %s)" % ("true" if with_task else "false", slow)), flush=True)
        if args.slow_ms:
            walls = {}
            time.sleep(1.5)
            run('SDP_Frames.Phase("slow")')
            started = time.monotonic()
            time.sleep(args.seconds)
            walls["slow"] = time.monotonic() - started
            run('SDP_Frames.Phase("slow-after")')
        else:
            walls = phases(user_app, args.seconds, label)
        run("SDP_Frames.Stop()")
        rows = []
        for line in run("SDP_Frames.Report()"):
            if line.startswith("SDP_FRAMES "):
                row = json.loads(line[len("SDP_FRAMES "):])
                row["Wall"] = walls.get(row["Phase"])
                rows.append(row)
                print("  %-22s frames %5d  mean %.3fs  median %.3fs  max %.2fs  units/s %7.0f  slice %4d->%4d  wall %s" % (
                    row["Phase"], row["Frames"], row["MeanFrame"], row["MedianFrame"], row["MaxFrame"],
                    row["UnitsPerSecond"], row["MedianSlice"], row["LastSlice"],
                    "%.1f" % row["Wall"] if row["Wall"] else "-"), flush=True)
            elif line.startswith("SDP_SPEED "):
                out["Runs"].setdefault(label, {})["SpeedAfter"] = float(line.split()[1])
                print("  task speed after: %s units/s" % line.split()[1], flush=True)
        out["Runs"].setdefault(label, {})["Phases"] = rows
    os.makedirs(RESULTS, exist_ok=True)
    path = os.path.join(RESULTS, "probe_frames%s.json" % ("-slow" if args.slow_ms else ""))
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1)
    print("wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    main()
