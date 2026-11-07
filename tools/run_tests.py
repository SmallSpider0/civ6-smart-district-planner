#!/usr/bin/env python3
"""run_tests - run Lua test files inside the running game via the tuner.

A test file (tests/test_*.lua) is a chunk that receives `test` and `T`:

    -- @state dmt_yieldcalculator     Lua state to run in (default InGame)
    -- @timeout 30                    seconds for the whole file (default 30)
    -- @max_seconds 2.5               fail when the file takes longer (wall time)
    -- @max_seconds_each 2.5          run each test("...") of the file on its own
                                      (names written as string literals) and
                                      fail one that takes longer
    -- @setup GameCore_Tuner tests/fixtures/build_campus.lua
    -- @teardown GameCore_Tuner tests/fixtures/destroy_campus.lua
                                      run a Lua file in a state before / after
                                      the tests (teardown always runs); several
                                      @setup lines run in order, SETUP_PAUSE
                                      seconds apart, closing the popups a step
                                      opened (an order given in a UI state
                                      reaches the game core a few frames later,
                                      and not while a popup holds the event
                                      queue: AGENTS pitfall 24)
    local test, T = ...

    test("campus next to a mountain gets science", function()
      T.eq(GetBonusYields(pid, subject).yields.YIELD_SCIENCE, 1)
    end)

Assertions: T.ok(cond, msg), T.eq(actual, expected, msg),
T.near(actual, expected, eps, msg), T.same(actual, expected, msg) (deep
equality via T.dump, a sorted-key serialization), T.skip(reason). A test fails on any error;
messages carry the file and line (the chunk is named after the file).

Before each file the panel goes back to how a new game shows it
(SDP_Panel.Defaults in the SDP_Panel state, before its @setup: issue 327),
so no file runs on settings, lists or a plan an earlier one left; this
mod's tacks stay (a file undoes its own). A line the panel writes when a
page cannot hold its body (SDP_LAYOUT_OVERFLOW, SDP_UI.CheckFit) fails the
test it shows up in. --shortest-window fits the panel's window at its
minimum height (SDP_UI.WINDOW_MIN, the lowest screens) for the whole run,
then back to the screen's.

Usage: run_tests.py [-k SUBSTRING] [-v] [--shortest-window] [--rulesets all|LIST] [FILE...]
--rulesets starts a new game for each ruleset in turn (tools/game.py newgame
--state SDP_Panel --capital --reveal --ruleset R) and runs the files in each:
`all` is the base game, Rise and Fall and Gathering Storm, as before a release.
It takes the game lock for this worktree (tools/sdplock.py) and stops when the
mod in the game's Mods folder is not this worktree's (run deploy.py).
Exit codes: 0 all passed, 1 failures, 2 connection problem, 3 timeout,
4 the game is held by another worktree.
"""

import argparse
import glob
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import civ6tuner  # noqa: E402
import sdplock  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS_DIR = os.path.join(ROOT, "tests")
SEP = "\x1f"  # ASCII unit separator: cannot clash with test names or messages
PREFIX = "SDP_TEST" + SEP
MOD_ID = "d2b8b724-4174-42cb-943c-8036778c68ba"
# With two copies of the mod installed (Mods and Workshop) the game loads the
# one it registered first, whichever is enabled: its enabled list keeps only
# the mod ID (checked 2026-10-22). Tests must not run a Workshop copy's code.
LOADED_COPY = """
for _, v in ipairs(Modding.GetActiveMods()) do
  if v.Id == "%s" then print("SDP_COPY " .. tostring(v.SubscriptionId or "")) end
end
""" % MOD_ID
# Frames of the harness itself in HavokScript's automatic tracebacks.
HARNESS_FRAME = re.compile(r"^\s*(tuner:\d+:|\[C\]: in function 'pcall'|\[string \"local __src)")

# Before each file (issue 327): the panel as a new game shows it.
DEFAULTS = """
if SDP_Panel == nil or SDP_Panel.Defaults == nil then error("SDP_Panel.Defaults is missing: deploy this worktree's mod") end
SDP_Panel.Defaults()
"""
# --shortest-window: the window at its minimum whatever the screen (the
# panel's own FitWindow, with SDP_UI.WindowHeight giving the minimum).
SHORTEST = """
if SDP_TestWindowHeight == nil then SDP_TestWindowHeight = SDP_UI.WindowHeight end
SDP_UI.WindowHeight = function() return SDP_UI.WINDOW_MIN end
SDP_Panel.FitWindow()
"""
SCREEN_WINDOW = """
if SDP_TestWindowHeight ~= nil then SDP_UI.WindowHeight = SDP_TestWindowHeight end
SDP_TestWindowHeight = nil
SDP_Panel.FitWindow()
"""
# The panel's line for a page that cannot hold its body (SDP_UI.OVERFLOW).
OVERFLOW = "SDP_LAYOUT_OVERFLOW"

HARNESS = r"""
local __src = [{eq}[
{body}
]{eq}]
local __filter = {filter}
local __exact = {exact}
local __chunk, __err = loadstring(__src, {chunkname})
local S = "\31"
if not __chunk then print("SDP_TEST" .. S .. "ERROR" .. S .. "(load)" .. S .. tostring(__err)) return end

local __tests = {{}}
local function test(name, fn) __tests[#__tests + 1] = {{ name = name, fn = fn }} end
local function show(v) return type(v) == "string" and string.format("%q", v) or tostring(v) end
local T = {{}}
function T.ok(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
  return cond
end
function T.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg and msg .. ": " or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
  end
end
function T.near(actual, expected, eps, msg)
  if type(actual) ~= "number" or math.abs(actual - expected) > (eps or 1e-9) then
    error((msg and msg .. ": " or "") .. "expected " .. show(expected) .. " +/- " .. tostring(eps or 1e-9)
      .. ", got " .. show(actual), 2)
  end
end
function T.skip(reason) error({{ sdp_skip = reason or "skipped" }}, 0) end
-- Deterministic text form of a value: table keys sorted by type then value.
function T.dump(v)
  if type(v) ~= "table" then return show(v) end
  local keys = {{}}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then return type(a) < type(b) end
    return a < b
  end)
  local parts = {{}}
  for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. show(k) .. "]=" .. T.dump(v[k]) end
  return "{{" .. table.concat(parts, ",") .. "}}"
end
function T.same(actual, expected, msg)
  local a, e = T.dump(actual), T.dump(expected)
  if a ~= e then
    error((msg and msg .. ": " or "") .. "expected " .. e:sub(1, 300) .. ", got " .. a:sub(1, 300), 2)
  end
end

local __ok, __e = pcall(__chunk, test, T)
if not __ok then print("SDP_TEST" .. S .. "ERROR" .. S .. "(file)" .. S .. tostring(__e)) return end
for _, t in ipairs(__tests) do
  if __filter == nil or (__exact and t.name == __filter) or (not __exact and string.find(t.name, __filter, 1, true)) then
    local ok, err = pcall(t.fn)
    if ok then
      print("SDP_TEST" .. S .. "PASS" .. S .. t.name)
    elseif type(err) == "table" and err.sdp_skip then
      print("SDP_TEST" .. S .. "SKIP" .. S .. t.name .. S .. tostring(err.sdp_skip))
    else
      print("SDP_TEST" .. S .. "FAIL" .. S .. t.name .. S .. tostring(err))
    end
  end
end
"""


def lua_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def display_path(path):
    try:
        rel = os.path.relpath(path, ROOT)
    except ValueError:  # another drive on Windows
        return path
    return path if rel.startswith("..") else rel.replace(os.sep, "/")


def clean_detail(detail):
    """Drop the harness's own frames from an error traceback."""
    lines = [l for l in detail.splitlines() if not HARNESS_FRAME.match(l)]
    if lines and lines[-1].strip() == "stack traceback:":
        lines.pop()
    return "\n".join(lines)


def build(path, body, name_filter, exact=False):
    level = 0
    while ("]" + "=" * level + "]") in body:
        level += 1
    return HARNESS.format(eq="=" * level, body=body, chunkname=lua_string("@" + display_path(path)),
                          filter=lua_string(name_filter) if name_filter else "nil",
                          exact="true" if exact else "false")


# Header keys that may appear more than once: a list, in file order.
REPEATED = ("setup", "teardown")
# Seconds between two fixtures of one file (tools/stress.py waits as long
# between ordering a district and finishing it).
SETUP_PAUSE = 2.0


def settle():
    """Between two setup steps: wait, then close the popups a step opened
    (granting a civic can queue one; while it is open the UI states see no
    new game data and orders wait, AGENTS pitfall 24)."""
    time.sleep(SETUP_PAUSE)
    import game  # tools/game.py: closes each popup with its own Close
    game.close_popups()


def headers(body):
    """Read `-- @key value` lines from the comment block at the top."""
    found = {}
    for line in body.splitlines():
        if not line.startswith("--"):
            break
        m = re.match(r"--\s*@(\w+)\s+(.+?)\s*$", line)
        if m:
            if m.group(1) in REPEATED:
                found.setdefault(m.group(1), []).append(m.group(2))
            else:
                found[m.group(1)] = m.group(2)
    return found


def run_fixtures(specs, label):
    """Run each `STATE FILE` of a @setup/@teardown list in order; returns the
    first error or None. Teardowns all run even after an error."""
    problem = None
    for i, spec in enumerate(specs):
        if i > 0:
            if label == "setup":
                settle()
            else:
                time.sleep(SETUP_PAUSE)
        error = run_fixture(spec, label)
        if error and problem is None:
            problem = error
            if label == "setup":
                break
    return problem


def panel_defaults(shortest):
    """The panel back to its defaults (and the window at its minimum with
    `shortest`) before a file. Returns (counts to add, exit kind or None)."""
    counts = {"FAIL": 0, "ERROR": 0}
    resp = civ6tuner.request({"op": "exec", "state": "SDP_Panel", "code": (SHORTEST if shortest else "") + DEFAULTS,
                              "timeout": 30})
    if resp.get("kind") in ("connection", "timeout"):
        if "Lua state" in (resp.get("error") or ""):
            return counts, None  # no game in progress: the file reports that itself
        print("  ERROR  panel defaults: %s: %s" % (resp["kind"], resp.get("error")))
        counts["ERROR"] += 1
        return counts, resp["kind"]
    if not resp.get("ok"):
        print("  ERROR  panel defaults: %s" % resp.get("error"))
        counts["ERROR"] += 1
    overflow = [l for l in resp.get("output") or [] if l.startswith(OVERFLOW)]
    if overflow:
        print("  FAIL   (layout) panel defaults\n         " + "\n         ".join(overflow))
        counts["FAIL"] += 1
    return counts, None


def screen_window():
    """Back to the window the screen gives (after --shortest-window)."""
    civ6tuner.request({"op": "exec", "state": "SDP_Panel", "code": SCREEN_WINDOW, "timeout": 30})


def run_fixture(spec, label):
    """Run `STATE FILE` from a @setup/@teardown header; returns an error or None."""
    parts = spec.split(None, 1)
    if len(parts) != 2:
        return "%s needs a state and a file" % label
    state, rel = parts
    with open(os.path.join(ROOT, rel), encoding="utf-8-sig") as fh:
        resp = civ6tuner.request({"op": "exec", "state": state, "code": fh.read(), "timeout": 10})
    overflow = []
    for line in resp.get("output") or []:
        print("    %s | %s" % (label, line))
        if line.startswith(OVERFLOW):
            overflow.append(line)
    if not resp.get("ok"):
        return "%s %s: %s" % (label, rel, resp.get("error"))
    return "%s %s: %s" % (label, rel, overflow[0]) if overflow else None


def workshop_copy():
    """The Workshop item ID when the game in progress runs a Workshop copy of the mod."""
    resp = civ6tuner.request({"op": "exec", "state": "InGame", "code": LOADED_COPY, "timeout": 10})
    if not resp.get("ok"):
        return None  # no game in progress: the test files report that themselves
    for line in resp.get("output") or []:
        if line.startswith("SDP_COPY ") and line[len("SDP_COPY "):].strip():
            return line[len("SDP_COPY "):].strip()
    return None


def deployed_differences():
    """Files in which the deployed mod differs from this worktree's SmartDistrictPlanner/."""
    import deploy
    import paths
    mods = paths.mods_dir()
    if not mods or not os.path.isdir(mods):
        return []  # no local game folder: the test files report the missing game themselves
    added, updated, removed, _same = deploy.plan(deploy.SOURCE, os.path.join(mods, deploy.MOD_NAME))
    return added + updated + removed


def run_file(path, name_filter, verbose, shortest=False):
    """Returns (counts dict, exit kind or None)."""
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0, "ERROR": 0}
    rel = display_path(path)
    with open(path, encoding="utf-8-sig") as fh:
        body = fh.read()
    opts = headers(body)
    state = opts.get("state", "InGame")
    added, problem = panel_defaults(shortest)
    for k, v in added.items():
        counts[k] += v
    if problem:
        print("%s  [%s]" % (rel, state))
        return counts, problem
    if "setup" in opts:
        problem = run_fixtures(opts["setup"], "setup")
        if problem:
            print("%s  [%s]\n  ERROR  %s" % (rel, state, problem))
            counts["ERROR"] += 1
            if "teardown" in opts:
                run_fixtures(opts["teardown"], "teardown")
            return counts, None
        if len(opts["setup"]) > 1:
            settle()  # the UI states see the last step a few frames later
    if "max_seconds_each" in opts:  # one exec per test: each is timed on its own
        print("%s  [%s]" % (rel, state))
        limit = float(opts["max_seconds_each"])
        runs = [(n, True, "  " + n, limit) for n in test_names(body) if not name_filter or name_filter in n]
    else:
        limit = float(opts["max_seconds"]) if "max_seconds" in opts else None
        runs = [(name_filter, False, "%s  [%s]" % (rel, state), limit)]
    problem = None
    for one_filter, exact, label, limit in runs:
        problem = run_chunk(path, body, state, opts, (one_filter, exact), verbose, counts, label, limit)
        if problem:
            break
    if "teardown" in opts:
        error = run_fixtures(opts["teardown"], "teardown")
        if error:
            print("  ERROR  %s" % error)
            counts["ERROR"] += 1
    return counts, problem


def test_names(body):
    """The names of the file's tests, in order, as written: test("name", ...)."""
    return re.findall(r'^\s*test\(\s*"((?:[^"\\]|\\.)*)"', body, re.M)


def run_chunk(path, body, state, opts, name_filter, verbose, counts, label, limit):
    """One exec of the file (its tests matching name_filter: (text, exact)); adds to counts. Returns an exit
    kind when the game is gone or stuck, else None."""
    started = time.monotonic()
    resp = civ6tuner.request({"op": "exec", "state": state, "code": build(path, body, *name_filter),
                              "timeout": float(opts.get("timeout", 30))})
    # Wall time of the exec, tuner round trip included (~0.02 s). The
    # game's own timers (os.clock, Automation.GetTime) tick in whole seconds.
    elapsed = time.monotonic() - started
    print("%s  %.2fs" % (label, elapsed))
    if limit is not None and elapsed > limit and resp.get("ok"):
        counts["FAIL"] += 1
        print("  FAIL   (time limit)\n         took %.2fs, limit %ss" % (elapsed, limit))
    if resp.get("kind") in ("connection", "timeout"):
        print("  ERROR  %s: %s" % (resp["kind"], resp.get("error")))
        counts["ERROR"] += 1
        state_missing = "Lua state" in (resp.get("error") or "")
        return None if state_missing else resp["kind"]
    logs, overflow = [], []
    for item in resp.get("output") or []:
        if not item.startswith(PREFIX):
            logs.append(item)
            if item.startswith(OVERFLOW):  # a page could not hold its body during this test
                overflow.append(item)
            continue
        status, name, detail = (item[len(PREFIX):].split(SEP, 2) + ["", ""])[:3]
        if overflow:
            if status in ("PASS", "SKIP"):
                status, detail = "FAIL", "(layout) " + "\n".join(overflow)
            else:
                detail = detail + "\n(layout) " + "\n".join(overflow)
            overflow = []
        counts[status] = counts.get(status, 0) + 1
        if status == "PASS":
            print("  PASS   %s" % name)
        else:
            print("  %-6s %s\n         %s" % (status, name, clean_detail(detail).replace("\n", "\n         ")))
    if overflow:  # after the last test's line: the file's own code at load
        counts["FAIL"] += 1
        print("  FAIL   (layout) outside a test\n         " + "\n         ".join(overflow))
    if resp.get("error"):  # an error escaped the harness itself
        counts["ERROR"] += 1
        print("  ERROR  harness: %s" % resp["error"])
    if logs and (verbose or counts["FAIL"] or counts["ERROR"]):
        print("  output:")
        for item in logs:
            print("    | " + item.replace("\n", "\n    | "))
    return None


RULESETS = ["RULESET_STANDARD", "RULESET_EXPANSION_1", "RULESET_EXPANSION_2"]


def run_rulesets(args):
    """A new game per ruleset, then this script again on the same files; one summary line each."""
    import subprocess
    names = RULESETS if args.rulesets == "all" else [r.strip() for r in args.rulesets.split(",") if r.strip()]
    tools = os.path.dirname(os.path.abspath(__file__))
    rest = list(args.files) + (["-k", args.name_filter] if args.name_filter else []) + (["-v"] if args.verbose else [])
    rest += ["--shortest-window"] if args.shortest_window else []
    results, worst = [], 0
    for ruleset in names:
        started = subprocess.run([sys.executable, "-I", os.path.join(tools, "game.py"), "newgame", "--state",
                                  "SDP_Panel", "--capital", "--reveal", "--ruleset", ruleset])
        if started.returncode != 0:
            results.append((ruleset, "new game failed"))
            worst = max(worst, 2)
            continue
        done = subprocess.run([sys.executable, "-I", os.path.abspath(__file__)] + rest, capture_output=True, text=True)
        sys.stdout.write(done.stdout)
        last = [l for l in done.stdout.splitlines() if l.startswith("run_tests:")]
        results.append((ruleset, last[-1][len("run_tests: "):] if last else "no summary (exit %d)" % done.returncode))
        worst = max(worst, done.returncode)
    for ruleset, line in results:
        print("run_tests %-20s %s" % (ruleset, line))
    return worst


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run Lua tests inside the running game")
    ap.add_argument("files", nargs="*", help="test files (default tests/**/test_*.lua)")
    ap.add_argument("-k", dest="name_filter", help="only tests whose name contains this text")
    ap.add_argument("-v", "--verbose", action="store_true", help="show print() output of passing files")
    ap.add_argument("--rulesets", help="all, or RULESET_... names separated by commas: a new game for each")
    ap.add_argument("--shortest-window", action="store_true",
                    help="fit the panel's window at its minimum height for the run (the lowest screens)")
    args = ap.parse_args(argv)
    what = args.rulesets or (" ".join(os.path.basename(f) for f in args.files[:3]) or "all files")
    sdplock.claim_or_exit(ROOT, "run_tests " + what)
    if args.rulesets:
        return run_rulesets(args)

    files = args.files or sorted(glob.glob(os.path.join(TESTS_DIR, "**", "test_*.lua"), recursive=True))
    if not files:
        print("run_tests: no test files found")
        return 1
    differ = deployed_differences()
    if differ:
        print("run_tests: the mod in the game's Mods folder is not this worktree's (%d file(s) differ, e.g. %s). "
              "Run tools/deploy.py, then start a new game." % (len(differ), ", ".join(differ[:3])))
        return 1
    item = workshop_copy()
    if item:
        print("run_tests: the game runs the Workshop copy of the mod (item %s), not the one deploy.py put "
              "in Mods. Unsubscribe it and remove its folder (AGENTS.md section 6), then start a new game." % item)
        return 1
    total = {"PASS": 0, "FAIL": 0, "SKIP": 0, "ERROR": 0}
    try:
        for path in files:
            counts, problem = run_file(os.path.abspath(path), args.name_filter, args.verbose, args.shortest_window)
            for k, v in counts.items():
                total[k] = total.get(k, 0) + v
            if problem:  # the game is gone or stuck; later files would fail the same way
                print("run_tests: stopped (%s)" % problem)
                return civ6tuner.EXIT_CODES[problem]
    finally:
        if args.shortest_window:
            screen_window()
    print("run_tests: %d passed, %d failed, %d skipped, %d errors"
          % (total["PASS"], total["FAIL"], total["SKIP"], total["ERROR"]))
    return 1 if total["FAIL"] or total["ERROR"] else 0


if __name__ == "__main__":
    sys.exit(main())
