#!/usr/bin/env python3
"""run_tests - run Lua test files inside the running game via the tuner.

A test file (tests/test_*.lua) is a chunk that receives `test` and `T`:

    -- @state dmt_yieldcalculator     Lua state to run in (default InGame)
    -- @timeout 30                    seconds for the whole file (default 30)
    local test, T = ...

    test("campus next to a mountain gets science", function()
      T.eq(GetBonusYields(pid, subject).yields.YIELD_SCIENCE, 1)
    end)

Assertions: T.ok(cond, msg), T.eq(actual, expected, msg),
T.near(actual, expected, eps, msg), T.same(actual, expected, msg) (deep
equality via T.dump, a sorted-key serialization), T.skip(reason). A test fails on any error;
messages carry the file and line (the chunk is named after the file).

Usage: run_tests.py [-k SUBSTRING] [-v] [FILE...]
Exit codes: 0 all passed, 1 failures, 2 connection problem, 3 timeout.
"""

import argparse
import glob
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import civ6tuner  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS_DIR = os.path.join(ROOT, "tests")
SEP = "\x1f"  # ASCII unit separator: cannot clash with test names or messages
PREFIX = "SDP_TEST" + SEP
# Frames of the harness itself in HavokScript's automatic tracebacks.
HARNESS_FRAME = re.compile(r"^\s*(tuner:\d+:|\[C\]: in function 'pcall'|\[string \"local __src)")

HARNESS = r"""
local __src = [{eq}[
{body}
]{eq}]
local __filter = {filter}
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
  if __filter == nil or string.find(t.name, __filter, 1, true) then
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
    rel = os.path.relpath(path, ROOT)
    return path if rel.startswith("..") else rel.replace(os.sep, "/")


def clean_detail(detail):
    """Drop the harness's own frames from an error traceback."""
    lines = [l for l in detail.splitlines() if not HARNESS_FRAME.match(l)]
    if lines and lines[-1].strip() == "stack traceback:":
        lines.pop()
    return "\n".join(lines)


def build(path, body, name_filter):
    level = 0
    while ("]" + "=" * level + "]") in body:
        level += 1
    return HARNESS.format(eq="=" * level, body=body, chunkname=lua_string("@" + display_path(path)),
                          filter=lua_string(name_filter) if name_filter else "nil")


def headers(body):
    """Read `-- @key value` lines from the comment block at the top."""
    found = {}
    for line in body.splitlines():
        if not line.startswith("--"):
            break
        m = re.match(r"--\s*@(\w+)\s+(\S+)", line)
        if m:
            found[m.group(1)] = m.group(2)
    return found


def run_file(path, name_filter, verbose):
    """Returns (counts dict, exit kind or None)."""
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0, "ERROR": 0}
    rel = display_path(path)
    with open(path, encoding="utf-8-sig") as fh:
        body = fh.read()
    opts = headers(body)
    state = opts.get("state", "InGame")
    started = time.monotonic()
    resp = civ6tuner.request({"op": "exec", "state": state, "code": build(path, body, name_filter),
                              "timeout": float(opts.get("timeout", 30))})
    # Wall time of the whole file, tuner round trip included (~0.02 s). The
    # game's own timers (os.clock, Automation.GetTime) tick in whole seconds.
    print("%s  [%s]  %.2fs" % (rel, state, time.monotonic() - started))
    if resp.get("kind") in ("connection", "timeout"):
        print("  ERROR  %s: %s" % (resp["kind"], resp.get("error")))
        counts["ERROR"] += 1
        state_missing = "Lua state" in (resp.get("error") or "")
        return counts, None if state_missing else resp["kind"]
    logs = []
    for item in resp.get("output") or []:
        if not item.startswith(PREFIX):
            logs.append(item)
            continue
        status, name, detail = (item[len(PREFIX):].split(SEP, 2) + ["", ""])[:3]
        counts[status] = counts.get(status, 0) + 1
        if status == "PASS":
            print("  PASS   %s" % name)
        else:
            print("  %-6s %s\n         %s" % (status, name, clean_detail(detail).replace("\n", "\n         ")))
    if resp.get("error"):  # an error escaped the harness itself
        counts["ERROR"] += 1
        print("  ERROR  harness: %s" % resp["error"])
    if logs and (verbose or counts["FAIL"] or counts["ERROR"]):
        print("  output:")
        for item in logs:
            print("    | " + item.replace("\n", "\n    | "))
    return counts, None


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run Lua tests inside the running game")
    ap.add_argument("files", nargs="*", help="test files (default tests/**/test_*.lua)")
    ap.add_argument("-k", dest="name_filter", help="only tests whose name contains this text")
    ap.add_argument("-v", "--verbose", action="store_true", help="show print() output of passing files")
    args = ap.parse_args(argv)

    files = args.files or sorted(glob.glob(os.path.join(TESTS_DIR, "**", "test_*.lua"), recursive=True))
    if not files:
        print("run_tests: no test files found")
        return 1
    total = {"PASS": 0, "FAIL": 0, "SKIP": 0, "ERROR": 0}
    for path in files:
        counts, problem = run_file(os.path.abspath(path), args.name_filter, args.verbose)
        for k, v in counts.items():
            total[k] = total.get(k, 0) + v
        if problem:  # the game is gone or stuck; later files would fail the same way
            print("run_tests: stopped (%s)" % problem)
            return civ6tuner.EXIT_CODES[problem]
    print("run_tests: %d passed, %d failed, %d skipped, %d errors"
          % (total["PASS"], total["FAIL"], total["SKIP"], total["ERROR"]))
    return 1 if total["FAIL"] or total["ERROR"] else 0


if __name__ == "__main__":
    sys.exit(main())
