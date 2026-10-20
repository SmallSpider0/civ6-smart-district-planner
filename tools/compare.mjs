#!/usr/bin/env node
// compare.mjs - offline head-to-head of district planners on emulated games.
//
// Each run builds a game world from a scenario (tests/compare/scenarios.lua),
// runs one planner on it in its own Lua state (like a separate game UI
// context) and scores the plan in a fresh state with the real Detailed Map
// Tacks code (tests/compare/judge.lua). Rules come from the game's own
// database, exported by tests/compare/export_gameinfo.py.
//
// Planners: sdp (this mod, Scripts only), amt (Auto Map Tacks Planner r49),
// ep (Empire Planner). Their sources are read from reference/ and the local
// Steam workshop folder; nothing of theirs is copied into the repository.
//
// Usage:
//   node tools/compare.mjs [--list] [-s SUBSTRING] [-p sdp,amt,ep] [-j JOBS]
//                          [--only planner:variant,...] [--out FILE] [-v]
//   node tools/compare.mjs --rejudge RESULTS.jsonl --out NEW.jsonl   (score again)
//   node tools/compare.mjs --dump ID | --snapshot ID
// Results are JSON lines in --out (default tests/compare/results/latest.jsonl).

import { createRequire } from "node:module";
import { readFileSync, existsSync, writeFileSync, mkdirSync, appendFileSync } from "node:fs";
import { join, resolve, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { homedir, availableParallelism } from "node:os";

const require = createRequire(import.meta.url);
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const COMPARE = join(ROOT, "tests", "compare");
const GAMEINFO = join(COMPARE, ".cache", "gameinfo.lua");
const WORKSHOP = join(homedir(), "Library", "Application Support", "Steam", "steamapps", "workshop", "content", "289070");
const EP_DIR = join(WORKSHOP, "3793348626", "ui");

// include() search path per planner. The game resolves include() by file
// name across every loaded mod; the order here only matters for duplicates.
const COMMON = [COMPARE, join(ROOT, "reference", "dmt", "ui"), join(ROOT, "reference", "base-ui")];
const SEARCH = {
  judge: COMMON,
  sdp: [join(ROOT, "SmartDistrictPlanner", "Scripts"), join(ROOT, "SmartDistrictPlanner", "UI"), ...COMMON],
  amt: [join(ROOT, "reference", "amt"), ...COMMON],
  ep: [EP_DIR, ...COMMON],
};
// Game UI files that only build controls; the stubs in game.lua stand in.
const SKIP = new Set(["InstanceManager", "ToolTipHelper", "Colors", "PortraitSupport", "PopupDialog", "CitySupport"]);

// HavokScript type annotations (function f(x:number), local n:string = ...)
// in the game's and DMT's files. Plain Lua 5.1 otherwise.
const TYPES = "number|string|table|boolean|any|object|function|userdata|ifunction|void";
function stripAnnotations(source) {
  source = source.replace(/function(\s*[\w.:]*\s*)\(([^)]*)\)/g, (m, name, params) =>
    "function" + name + "(" + params.replace(/(\w+|\.\.\.)\s*:\s*\w+/g, "$1") + ")");
  // name:type in locals, for loops and multiple assignment (never a method
  // call: those are followed by "(", a string or a table).
  source = source.replace(new RegExp("(\\b[A-Za-z_]\\w*)\\s*:\\s*(" + TYPES + ")\\b(?!\\s*[(\"'{\\[])", "g"), "$1");
  source = source.replace(new RegExp("\\)\\s*:\\s*(" + TYPES + ")\\b", "g"), ")");
  return source;
}

const PRELUDE = String.raw`
unpack = table.unpack
loadstring = load
table.getn = function(t) return #t end
math.pow = function(a, b) return a ^ b end
math.mod = math.fmod
string.gfind = string.gmatch
table.count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
do
  local cg = collectgarbage
  collectgarbage = function(o, ...)
    local ok, r = pcall(cg, o, ...)
    if ok then return r end
    return 0
  end
end
`;

function display(path) {
  return relative(ROOT, path).split("\\").join("/");
}

function loadSource(L, path, source) {
  const status = lauxlib.luaL_loadbuffer(L, to_luastring(source), null, to_luastring("@" + display(path)));
  if (status !== lua.LUA_OK) throw new Error(lua.lua_tojsstring(L, -1));
}

function loadFile(L, path) {
  let source = readFileSync(path, "utf8").replace(/^\uFEFF/, "");
  if (!path.startsWith(join(ROOT, "SmartDistrictPlanner")) && !path.startsWith(COMPARE)) source = stripAnnotations(source);
  loadSource(L, path, source);
}

function newState(planner, output) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const loaded = new Set();
  const search = SEARCH[planner];

  const push = (name, fn) => {
    lua.lua_pushjsfunction(L, fn);
    lua.lua_setglobal(L, to_luastring(name));
  };
  push("cmp_emit", (L) => {
    output.emits.push(to_jsstring(lauxlib.luaL_checkstring(L, 1)));
    return 0;
  });
  push("print", (L) => {
    const n = lua.lua_gettop(L);
    const parts = [];
    for (let i = 1; i <= n; i++) parts.push(to_jsstring(lauxlib.luaL_tolstring(L, i)));
    if (output.log.length < 4000) output.log.push(parts.join("\t"));
    return 0;
  });
  push("cmp_now", (L) => {
    lua.lua_pushnumber(L, performance.now() / 1000);
    return 1;
  });
  push("cmp_read_file", (L) => {
    const path = to_jsstring(lauxlib.luaL_checkstring(L, 1));
    if (!existsSync(path)) return 0;
    lua.lua_pushstring(L, to_luastring(readFileSync(path, "utf8")));
    return 1;
  });
  push("include", (L) => {
    const name = to_jsstring(lauxlib.luaL_checkstring(L, 1)).replace(/\.lua$/, "");
    if (SKIP.has(name) || loaded.has(name)) return 0;
    const path = search.map((dir) => join(dir, name + ".lua")).find((p) => existsSync(p));
    if (!path) {
      output.log.push("include: no file named " + name);
      return 0;
    }
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
  if (lauxlib.luaL_dostring(L, to_luastring(PRELUDE)) !== lua.LUA_OK) throw new Error("prelude: " + lua.lua_tojsstring(L, -1));
  lua.lua_pushstring(L, to_luastring(planner));
  lua.lua_setglobal(L, to_luastring("CMP_PLANNER"));
  lua.lua_pushstring(L, to_luastring(GAMEINFO));
  lua.lua_setglobal(L, to_luastring("CMP_GAMEINFO"));
  return L;
}

// Run `code` (a Lua chunk) in a fresh state for `planner`; returns emits/log.
function runLua(planner, code, label) {
  const output = { emits: [], log: [] };
  const started = performance.now();
  let error = null;
  try {
    const L = newState(planner, output);
    loadSource(L, join(COMPARE, label + ".lua"), code);
    const handler = (L) => {
      const msg = lua.lua_tojsstring(L, 1);
      lauxlib.luaL_traceback(L, L, to_luastring(msg), 1);
      return 1;
    };
    lua.lua_pushjsfunction(L, handler);
    lua.lua_insert(L, 1);
    if (lua.lua_pcall(L, 0, 0, 1) !== lua.LUA_OK) error = lua.lua_tojsstring(L, -1);
  } catch (e) {
    error = String(e.message || e);
  }
  return { emits: output.emits, log: output.log, error, seconds: (performance.now() - started) / 1000 };
}

function luaString(s) {
  return JSON.stringify(s).replace(/\\u([0-9a-fA-F]{4})/g, (m, h) => {
    const c = parseInt(h, 16);
    return c < 128 ? "\\" + String(c).padStart(3, "0") : m;
  });
}

// Judge a plan again (after the judge changed), keeping the plan and times.
function rejudge(row) {
  const judged = runLua("judge", `
    include("cmp_lib")
    CmpRun.Judge(${luaString(row.scenario)}, ${luaString(JSON.stringify(row.plan))})
  `, "judge");
  for (const e of judged.emits) if (e.startsWith("SCORE ")) row.score = JSON.parse(e.slice(6));
  if (judged.error) row.judgeError = judged.error;
  else delete row.judgeError;
  return row;
}

// One task: plan scenario `id` with `planner` (+ its variant), then judge it.
function runTask(task) {
  if (task.rejudge) return rejudge(task.rejudge);
  const plan = runLua(task.planner, `
    include("cmp_lib")
    CmpRun.Plan(${luaString(task.scenario)}, ${luaString(task.planner)}, ${luaString(task.variant || "")})
  `, "plan_" + task.planner);
  const result = { scenario: task.scenario, planner: task.planner, variant: task.variant || "", planSeconds: plan.seconds };
  let planJson = null;
  for (const e of plan.emits) {
    if (e.startsWith("PLAN ")) planJson = e.slice(5);
  }
  if (plan.error || planJson === null) {
    result.error = plan.error || "no plan emitted";
    result.log = plan.log.slice(-40);
    return result;
  }
  const judged = runLua("judge", `
    include("cmp_lib")
    CmpRun.Judge(${luaString(task.scenario)}, ${luaString(planJson)})
  `, "judge");
  result.judgeSeconds = judged.seconds;
  result.plan = JSON.parse(planJson);
  for (const e of judged.emits) {
    if (e.startsWith("SCORE ")) result.score = JSON.parse(e.slice(6));
  }
  if (judged.error) result.judgeError = judged.error;
  if (task.verbose || judged.error) result.log = plan.log.slice(-40).concat(judged.log.slice(-20));
  return result;
}

function listScenarios(filter) {
  const out = runLua("judge", `include("cmp_lib") CmpRun.List()`, "list");
  if (out.error) throw new Error(out.error);
  const ids = out.emits.filter((e) => e.startsWith("SCENARIO ")).map((e) => JSON.parse(e.slice(9)));
  return filter ? ids.filter((s) => s.id.includes(filter)) : ids;
}

if (!isMainThread) {
  parentPort.on("message", (task) => {
    parentPort.postMessage(runTask(task));
  });
} else {
  const argv = process.argv.slice(2);
  let filter = null;
  let planners = ["sdp", "amt", "ep"];
  let jobs = Math.max(1, Math.min(8, (availableParallelism ? availableParallelism() : 4) - 2));
  let out = join(COMPARE, "results", "latest.jsonl");
  let verbose = false;
  let list = false;
  let dump = null;
  let snapshot = null;
  let rejudgeFile = null;
  let only = null; // planner:variant keys
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-s") filter = argv[++i];
    else if (a === "-p") planners = argv[++i].split(",");
    else if (a === "--only") only = argv[++i].split(",");
    else if (a === "-j") jobs = parseInt(argv[++i], 10);
    else if (a === "--out") out = resolve(argv[++i]);
    else if (a === "-v") verbose = true;
    else if (a === "--list") list = true;
    else if (a === "--dump") dump = argv[++i];
    else if (a === "--snapshot") snapshot = argv[++i];
    else if (a === "--rejudge") rejudgeFile = resolve(argv[++i]);
    else {
      console.error("usage: compare.mjs [--list] [-s SUBSTRING] [-p sdp,amt,ep] [-j JOBS] [--out FILE] [-v]");
      process.exit(2);
    }
  }
  if (!existsSync(GAMEINFO)) {
    console.error("missing " + display(GAMEINFO) + ": run python3 -I tests/compare/export_gameinfo.py");
    process.exit(2);
  }
  if (dump) {
    const out = runLua("judge", `include("cmp_lib") CmpRun.Dump(${luaString(dump)})`, "dump");
    console.log(out.log.join("\n"));
    if (out.error) console.log(out.error);
    process.exit(0);
  }
  if (snapshot) {
    const out = runLua("judge", `include("cmp_lib") CmpRun.Snapshot(${luaString(snapshot)})`, "snapshot");
    if (out.error) console.error(out.error);
    for (const e of out.emits) if (e.startsWith("SNAP ")) console.log(e.slice(5));
    process.exit(0);
  }
  const scenarios = listScenarios(filter);
  if (list) {
    for (const s of scenarios) console.log(s.id + "  " + (s.title || "") + "  [" + (s.planners || []).join(",") + "]");
    process.exit(0);
  }
  const tasks = [];
  if (rejudgeFile) {
    for (const line of readFileSync(rejudgeFile, "utf8").split("\n")) {
      if (!line.trim()) continue;
      const row = JSON.parse(line);
      if (row.plan && (!filter || row.scenario.includes(filter))) tasks.push({ scenario: row.scenario, planner: row.planner, variant: row.variant, rejudge: row });
    }
  }
  for (const s of rejudgeFile ? [] : scenarios) {
    for (const run of s.runs) {
      const key = run.planner + ":" + (run.variant || "");
      if (planners.includes(run.planner) && (!only || only.includes(key)))
        tasks.push({ scenario: s.id, planner: run.planner, variant: run.variant, verbose });
    }
  }
  // Longest runs first (AMT's multi-city joint solve, then multi-city), so
  // the pool does not end waiting on one slow straggler.
  const weight = (t) => (t.scenario.startsWith("M") ? 2 : 0) + (t.planner === "amt" ? 1 : 0);
  tasks.sort((a, b) => weight(b) - weight(a));
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, "");
  console.log(`${tasks.length} runs on ${scenarios.length} scenarios, ${jobs} workers -> ${display(out)}`);
  const started = performance.now();
  let next = 0;
  let done = 0;
  let failed = 0;
  const workers = [];
  await new Promise((resolveAll) => {
    const feed = (w) => {
      if (next >= tasks.length) {
        w.terminate();
        if (done >= tasks.length) resolveAll();
        return;
      }
      w.postMessage(tasks[next++]);
    };
    for (let i = 0; i < Math.min(jobs, tasks.length); i++) {
      const w = new Worker(fileURLToPath(import.meta.url), { resourceLimits: { maxOldGenerationSizeMb: 1536 } });
      w.on("message", (r) => {
        done++;
        if (r.error || r.judgeError) failed++;
        appendFileSync(out, JSON.stringify(r) + "\n");
        const s = r.score;
        const summary = r.error ? "ERROR " + r.error.split("\n")[0].slice(0, 160)
          : s ? `gain ${s.gain} output ${s.output} legal ${s.legal} violations ${s.violations.length}` : "no score";
        console.log(`[${done}/${tasks.length}] ${r.scenario} ${r.planner}${r.variant ? ":" + r.variant : ""} ${r.planSeconds.toFixed(1)}s ${summary}`);
        if ((verbose || r.error || r.judgeError) && r.log) for (const line of r.log.slice(-15)) console.log("    | " + line);
        if (done >= tasks.length) {
          for (const x of workers) x.terminate();
          resolveAll();
        } else feed(w);
      });
      w.on("error", (e) => {
        console.error("worker error", e);
        done++;
        failed++;
        if (done >= tasks.length) resolveAll();
        else feed(w);
      });
      workers.push(w);
      feed(w);
    }
    if (tasks.length === 0) resolveAll();
  });
  console.log(`done in ${((performance.now() - started) / 1000).toFixed(0)}s, ${failed} failed`);
  process.exit(0);
}
