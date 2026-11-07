"""Many wonders on the Several cities tab: does the game keep drawing (issue 307)?

On the loaded game (a save with several cities, e.g. tools/stress.py load
pangaea-gs): for each case CITIES:WONDERS[:all] (WONDERS "all" for every wonder
the player can build; a third part "all" makes every district required,
issue 331) the tab is set as a player would (the CITIES cities
nearest the capital, the first WONDERS wonders ticked, the tier) and solved
with the Solve button's own function, over frames as in play
(tests/bench/wonders_frames.lua times every frame). Prints per case the
frames, the longest frame, frames over 0.5 s and 2 s, the wall time and
whether the plan came; writes tests/bench/results/wonders_frames-NAME.json.
Fails (exit 1) when a frame took over --max-frame seconds or a case did not
end within --timeout. Changes nothing in the game (no pins).

    python3 -I tests/bench/wonders_frames.py NAME [--cases 6:19,6:all,6:all:all] [--tier STANDARD]
"""
import argparse
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import civ6tuner  # noqa: E402

RESULTS = os.path.join(ROOT, "tests", "bench", "results")


def run(code, timeout=60):
    resp = civ6tuner.request({"op": "exec", "state": "SDP_Panel", "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise SystemExit("SDP_Panel: %s" % resp.get("error"))
    return resp.get("output") or []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name", help="a label for the results file (the save's name)")
    ap.add_argument("--cases", default="6:19,6:all")
    ap.add_argument("--tier", default="STANDARD")
    ap.add_argument("--timeout", type=float, default=900)
    ap.add_argument("--max-frame", type=float, default=2.0)
    args = ap.parse_args()
    with open(os.path.join(ROOT, "tests", "bench", "wonders_frames.lua"), encoding="utf-8") as fh:
        run(fh.read())
    rows, failed = [], False
    for case in args.cases.split(","):
        parts = case.split(":")
        cities, wonders = parts[0], parts[1]
        every = len(parts) > 2 and parts[2] == "all"
        n = -1 if wonders == "all" else int(wonders)
        out = run('SDP_WonderFrames.Start(%d, %d, "%s", %s)' % (int(cities), n, args.tier, "true" if every else "false"))
        print(case, " ".join(out), flush=True)
        started = time.monotonic()
        timed_out = False
        while True:
            if any(line.startswith("RUNNING 0") for line in run("SDP_WonderFrames.Running()")):
                break
            if time.monotonic() - started > args.timeout:
                timed_out = True
                break
            time.sleep(0.5)
        wall = time.monotonic() - started
        row = None
        for line in run("SDP_WonderFrames.Report()"):
            if line.startswith("SDP_WFRAMES "):
                row = json.loads(line[len("SDP_WFRAMES "):])
        run("SDP_WonderFrames.Clear()")
        row = row or {}
        row.update({"Case": case, "Tier": args.tier, "Wall": round(wall, 1), "TimedOut": timed_out})
        rows.append(row)
        bad = timed_out or row.get("MaxFrame", 0) > args.max_frame or not row.get("Ok")
        failed = failed or bad
        print("  %-8s frames %5d  max %.2fs  mean %.3fs  >0.5s %d  >2s %d  wall %.0fs  ok=%s wonders placed %s%s" % (
            case, row.get("Frames", 0), row.get("MaxFrame", 0), row.get("MeanFrame", 0),
            (row.get("Over") or [0, 0, 0])[1], (row.get("Over") or [0, 0, 0])[2], wall, row.get("Ok"),
            row.get("WondersPlaced"), "  TIMED OUT" if timed_out else ""), flush=True)
    os.makedirs(RESULTS, exist_ok=True)
    path = os.path.join(RESULTS, "wonders_frames-%s.json" % args.name)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=1)
    print("wrote", os.path.relpath(path, ROOT))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
