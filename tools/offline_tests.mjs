#!/usr/bin/env node
// offline_tests.mjs - run the planner's logic tests outside the game.
//
// Lua runs in fengari (a Lua 5.3 VM written in JavaScript). Each file gets a
// fresh state with:
//   - HavokScript shims: unpack, loadstring;
//   - include(name): loads SmartDistrictPlanner/Scripts|UI/<name>.lua or
//     tests/offline/<name>.lua once per state; the game's own files
//     (MapTacks, dmt_yieldcalculator, InstanceManager) are no-ops because
//     tests/offline/world.lua supplies what the scripts need from them;
//   - World: tests/offline/world.lua, a small fake game (hex map, cities,
//     pins, GameInfo, a simplified DMT) that a test builds with World.New;
//   - test(name, fn) and T, the same assertions as tools/run_tests.py.
//
// Tests: tests/offline/spec_*.lua (not test_*.lua, which run_tests.py runs in
// the game). Benchmarks: tests/offline/bench_*.lua, run only when named.
//
// The fake DMT counts its calls (World.Calls), which is how the benchmarks
// measure cost: in the game a DMT call costs far more than a search step, and
// counts do not depend on this VM's speed.
//
// Usage: node tools/offline_tests.mjs [-k SUBSTRING] [-v] [FILE...]
// Exit codes: 0 all passed, 1 failures, 2 bad usage.

import { createRequire } from "node:module";
import { readFileSync, readdirSync, existsSync, writeFileSync } from "node:fs";
import { join, relative, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

const require = createRequire(import.meta.url);
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const OFFLINE = join(ROOT, "tests", "offline");
const SEARCH = [
  join(ROOT, "SmartDistrictPlanner", "Scripts"),
  join(ROOT, "SmartDistrictPlanner", "UI"),
  OFFLINE,
];
// Game files the scripts include; World provides their globals.
const GAME_FILES = new Set(["MapTacks", "dmt_yieldcalculator", "dmt_mappinsubjectmanager", "InstanceManager"]);
const SEP = "\x1f";

const PRELUDE = String.raw`
unpack = table.unpack
loadstring = load
function sdp_install_globals(values)
  for k, v in pairs(values) do _G[k] = v end
end
function sdp_global(name) return _G[name] end

local __tests = {}
function sdp_test(name, fn) __tests[#__tests + 1] = { name = name, fn = fn } end
local function show(v) return type(v) == "string" and string.format("%q", v) or tostring(v) end
T = {}
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
function T.skip(reason) error({ sdp_skip = reason or "skipped" }, 0) end
function T.dump(v)
  if type(v) ~= "table" then return show(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then return type(a) < type(b) end
    return a < b
  end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. show(k) .. "]=" .. T.dump(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
function T.same(actual, expected, msg)
  local a, e = T.dump(actual), T.dump(expected)
  if a ~= e then
    error((msg and msg .. ": " or "") .. "expected " .. e:sub(1, 300) .. ", got " .. a:sub(1, 300), 2)
  end
end

function sdp_run_tests(filter)
  local S = "\31"
  for _, t in ipairs(__tests) do
    if filter == nil or string.find(t.name, filter, 1, true) then
      local ok, err = xpcall(t.fn, function(e)
        if type(e) == "table" then return e end
        return debug.traceback(tostring(e), 2)
      end)
      if ok then
        sdp_emit("SDP_TEST" .. S .. "PASS" .. S .. t.name)
      elseif type(err) == "table" and err.sdp_skip then
        sdp_emit("SDP_TEST" .. S .. "SKIP" .. S .. t.name .. S .. tostring(err.sdp_skip))
      else
        sdp_emit("SDP_TEST" .. S .. "FAIL" .. S .. t.name .. S .. tostring(err))
      end
    end
  end
end
`;

function display(path) {
  return relative(ROOT, path).split("\\").join("/");
}

function loadFile(L, path) {
  const source = readFileSync(path, "utf8").replace(/^\uFEFF/, "");
  const status = lauxlib.luaL_loadbuffer(L, to_luastring(source), null, to_luastring("@" + display(path)));
  if (status !== lua.LUA_OK) throw new Error(lua.lua_tojsstring(L, -1));
}

function newState(output) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const loaded = new Set();

  lua.lua_pushjsfunction(L, (L) => {
    output.push(to_jsstring(lauxlib.luaL_checkstring(L, 1)));
    return 0;
  });
  lua.lua_setglobal(L, to_luastring("sdp_emit"));

  // print() goes to the file's output, shown on failure or with -v.
  lua.lua_pushjsfunction(L, (L) => {
    const n = lua.lua_gettop(L);
    const parts = [];
    for (let i = 1; i <= n; i++) parts.push(to_jsstring(lauxlib.luaL_tolstring(L, i)));
    output.push(parts.join("\t"));
    return 0;
  });
  lua.lua_setglobal(L, to_luastring("print"));

  // Benchmarks keep slow reference results between runs (fengari has no io.open).
  lua.lua_pushjsfunction(L, (L) => {
    const path = to_jsstring(lauxlib.luaL_checkstring(L, 1));
    if (!existsSync(path)) return 0;
    lua.lua_pushstring(L, to_luastring(readFileSync(path, "utf8")));
    return 1;
  });
  lua.lua_setglobal(L, to_luastring("sdp_read_file"));
  lua.lua_pushjsfunction(L, (L) => {
    writeFileSync(to_jsstring(lauxlib.luaL_checkstring(L, 1)), to_jsstring(lauxlib.luaL_checkstring(L, 2)));
    return 0;
  });
  lua.lua_setglobal(L, to_luastring("sdp_write_file"));

  // include(name): like the game's, by file name without extension.
  lua.lua_pushjsfunction(L, (L) => {
    const name = to_jsstring(lauxlib.luaL_checkstring(L, 1)).replace(/\.lua$/, "");
    if (GAME_FILES.has(name) || loaded.has(name)) return 0;
    const path = SEARCH.map((dir) => join(dir, name + ".lua")).find((p) => existsSync(p));
    if (!path) return lauxlib.luaL_error(L, to_luastring("include: no file named " + name));
    loaded.add(name);
    const top = lua.lua_gettop(L);
    try {
      loadFile(L, path);
    } catch (e) {
      return lauxlib.luaL_error(L, to_luastring(String(e.message)));
    }
    lua.lua_call(L, 0, lua.LUA_MULTRET);
    return lua.lua_gettop(L) - top;
  });
  lua.lua_setglobal(L, to_luastring("include"));

  if (lauxlib.luaL_dostring(L, to_luastring(PRELUDE)) !== lua.LUA_OK) {
    throw new Error("prelude: " + lua.lua_tojsstring(L, -1));
  }
  loadFile(L, join(OFFLINE, "world.lua"));
  lua.lua_call(L, 0, 1);
  lua.lua_setglobal(L, to_luastring("World"));
  // A tiny default world, so scripts can be included before a test builds its own.
  if (lauxlib.luaL_dostring(L, to_luastring('World.New({ rows = { "...", "..." } })')) !== lua.LUA_OK) {
    throw new Error("default world: " + lua.lua_tojsstring(L, -1));
  }
  return L;
}

function runFile(path, filter, verbose) {
  const counts = { PASS: 0, FAIL: 0, SKIP: 0, ERROR: 0 };
  const output = [];
  const started = performance.now();
  const lines = [];
  try {
    const L = newState(output);
    loadFile(L, path);
    lua.lua_getglobal(L, to_luastring("sdp_test"));
    lua.lua_getglobal(L, to_luastring("T"));
    if (lua.lua_pcall(L, 2, 0, 0) !== lua.LUA_OK) throw new Error(lua.lua_tojsstring(L, -1));
    lua.lua_getglobal(L, to_luastring("sdp_run_tests"));
    if (filter) lua.lua_pushstring(L, to_luastring(filter));
    else lua.lua_pushnil(L);
    if (lua.lua_pcall(L, 1, 0, 0) !== lua.LUA_OK) throw new Error(lua.lua_tojsstring(L, -1));
  } catch (e) {
    counts.ERROR++;
    lines.push("  ERROR  " + String(e.message || e).replace(/\n/g, "\n         "));
  }
  const logs = [];
  for (const item of output) {
    if (!item.startsWith("SDP_TEST" + SEP)) {
      logs.push(item);
      continue;
    }
    const [, status, name, detail] = item.split(SEP);
    counts[status] = (counts[status] || 0) + 1;
    if (status === "PASS") lines.push("  PASS   " + name);
    else lines.push(`  ${status.padEnd(6)} ${name}\n         ${(detail || "").replace(/\n/g, "\n         ")}`);
  }
  const seconds = (performance.now() - started) / 1000;
  console.log(`${display(path)}  ${seconds.toFixed(2)}s`);
  for (const line of lines) console.log(line);
  if (logs.length && (verbose || counts.FAIL || counts.ERROR)) {
    console.log("  output:");
    for (const item of logs) console.log("    | " + item.replace(/\n/g, "\n    | "));
  }
  return counts;
}

function main(argv) {
  let filter = null;
  let verbose = false;
  const files = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-k") filter = argv[++i];
    else if (a === "-v") verbose = true;
    else if (a.startsWith("-")) {
      console.error("usage: offline_tests.mjs [-k SUBSTRING] [-v] [FILE...]");
      return 2;
    } else files.push(resolve(a));
  }
  if (files.length === 0) {
    for (const f of readdirSync(OFFLINE).sort()) {
      if (/^spec_.*\.lua$/.test(f)) files.push(join(OFFLINE, f));
    }
  }
  const total = { PASS: 0, FAIL: 0, SKIP: 0, ERROR: 0 };
  for (const f of files) {
    const c = runFile(f, filter, verbose);
    for (const k of Object.keys(total)) total[k] += c[k] || 0;
  }
  console.log(`\n${total.PASS} passed, ${total.FAIL} failed, ${total.SKIP} skipped, ${total.ERROR} errors`);
  return total.FAIL || total.ERROR ? 1 : 0;
}

process.exit(main(process.argv.slice(2)));
