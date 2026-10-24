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
// ep (Empire Planner), dwp (District & Wonder Planner). Their sources are read from reference/ (links made by
// tools/setup_reference.py); nothing of theirs is copied into the repository.
//
// Usage:
//   node tools/compare.mjs [--list] [-s SUBSTRING|^REGEX] [-p sdp,amt,ep] [-j JOBS]
//                          [--only planner:variant,...] [--out FILE] [-v]
//   node tools/compare.mjs --rejudge RESULTS.jsonl --out NEW.jsonl   (score again)
//   node tools/compare.mjs --crossscore RESULTS.jsonl [--scorers amt,ep] --out NEW.jsonl
//       score every plan again with a competitor's own objective
//       (tests/compare/cmp_cross_<scorer>.lua, CmpCross[scorer]); adds
//       row.cross[scorer] = { score, baseline, gain, ... } (design 18.1, item 2)
//   node tools/compare.mjs --dump ID | --snapshot ID
//   node tools/compare.mjs --refscore [-s REF01] [--weights FILE|SPEC] [--reference-only]
//       reference scenes (tools/refscene.py): for each weight vector, the
//       judge's score of the recorded layout and of the optimum (sdp:ORACLE,
//       or sdp:FINE_LAND when the vector has land=1) under the same weights;
//       one row per scene and vector (issue 53)
//   node tools/compare.mjs -s ^S -p sdp --only sdp:ORACLE --weights FILE|SPEC [--out FILE]
//   node tools/compare.mjs --rejudge RESULTS.jsonl --weights FILE|SPEC [--out FILE]
//       the same runs (or judgings) once per named weight vector, which
//       replaces the scenario's own weights for the planner and the judge;
//       each row carries weights = { name, yields } (and a rejudged row
//       planWeights, the vector its plan was made for) (issue 53)
// Results are JSON lines in --out (default tests/compare/results/latest.jsonl).

import { createRequire } from "node:module";
import { readFileSync, existsSync, writeFileSync, mkdirSync, appendFileSync } from "node:fs";
import { join, resolve, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { availableParallelism } from "node:os";

const require = createRequire(import.meta.url);
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const COMPARE = join(ROOT, "tests", "compare");
const GAMEINFO = join(COMPARE, ".cache", "gameinfo.lua");
let RULESET = "RULESET_EXPANSION_2"; // --ruleset; see cmp_lib.lua's scene loading
const EP_DIR = join(ROOT, "reference", "ep", "ui");

// include() search path per planner. The game resolves include() by file
// name across every loaded mod; the order here only matters for duplicates.
const COMMON = [COMPARE, join(ROOT, "reference", "dmt", "ui"), join(ROOT, "reference", "base-ui")];
const SEARCH = {
  judge: COMMON,
  sdp: [join(ROOT, "SmartDistrictPlanner", "Scripts"), join(ROOT, "SmartDistrictPlanner", "UI"), ...COMMON],
  amt: [join(ROOT, "reference", "amt"), ...COMMON],
  ep: [EP_DIR, ...COMMON],
  dwp: [join(ROOT, "reference", "dwp"), ...COMMON],
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
  // A competitor's cross scorer ("cross_amt") loads that competitor's code.
  const search = SEARCH[planner] || SEARCH[planner.replace(/^cross_/, "")];

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
  lua.lua_pushstring(L, to_luastring(RULESET));
  lua.lua_setglobal(L, to_luastring("CMP_RULESET"));
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

function weightsPrefix(v) {
  return v ? `CMP_WEIGHTS = ${luaString(JSON.stringify(v.yields))}\n` : "";
}

// Judge a plan again (after the judge changed), keeping the plan and times;
// with a weight vector `v`, under those weights (issue 53).
function rejudge(row, v) {
  if (v) {
    row = Object.assign({}, row, { planWeights: row.weights ? row.weights.name : null, weights: { name: v.name, yields: v.yields } });
  }
  const judged = runLua("judge", weightsPrefix(v) + `
    include("cmp_lib")
    CmpRun.Judge(${luaString(row.scenario)}, ${luaString(JSON.stringify(row.plan))})
  `, "judge");
  for (const e of judged.emits) if (e.startsWith("SCORE ")) row.score = JSON.parse(e.slice(6));
  if (judged.error) row.judgeError = judged.error;
  else delete row.judgeError;
  return row;
}

// Score a plan with each competitor's own objective, each in a fresh state.
function crossScore(row, scorers) {
  row.cross = row.cross || {};
  for (const scorer of scorers) {
    const out = runLua("cross_" + scorer, `
      include("cmp_lib")
      CmpRun.Cross(${luaString(row.scenario)}, ${luaString(JSON.stringify(row.plan))}, ${luaString(scorer)})
    `, "cross_" + scorer);
    let value = null;
    for (const e of out.emits) if (e.startsWith("CROSS ")) value = JSON.parse(e.slice(6));
    row.cross[scorer] = value || { error: out.error || "no score", log: out.log.slice(-20) };
    if (out.error && value) row.cross[scorer].error = out.error;
  }
  return row;
}

// Weight vectors for --refscore and --weights: a file of JSON lines
// ({"name": "all1", "science": 1, ..., "land": 0}) or inline
// "all1:;half:gold=0.5,faith=0.5;land:land=1". Missing yields weigh 1.
const YIELD_KEYS = { science: "YIELD_SCIENCE", culture: "YIELD_CULTURE", faith: "YIELD_FAITH", gold: "YIELD_GOLD",
  production: "YIELD_PRODUCTION", food: "YIELD_FOOD" };
function weightVector(name, fields) {
  const v = { name, yields: {}, land: false, oracleLimit: null };
  for (const k of Object.keys(YIELD_KEYS)) v.yields[YIELD_KEYS[k]] = 1;
  for (const [k, raw] of Object.entries(fields)) {
    if (k === "name") continue;
    if (k === "land") v.land = raw === true || Number(raw) === 1;
    else if (k === "oracle") v.oracleLimit = Number(raw); // node limit in millions
    else if (YIELD_KEYS[k]) {
      const n = Number(raw);
      if (!Number.isFinite(n)) throw new Error(`weight ${k}=${raw} is not a number`);
      v.yields[YIELD_KEYS[k]] = n;
    } else throw new Error(`unknown weight ${k} (${Object.keys(YIELD_KEYS).join(", ")}, land, oracle)`);
  }
  return v;
}
function parseWeights(spec) {
  if (!spec) return [weightVector("all1", {})];
  if (existsSync(spec)) {
    return readFileSync(spec, "utf8").split("\n").filter((l) => l.trim() && !l.trim().startsWith("#"))
      .map((l, i) => { const o = JSON.parse(l); return weightVector(o.name || "w" + (i + 1), o); });
  }
  return spec.split(";").filter((p) => p.trim()).map((part, i) => {
    const [name, rest] = part.includes(":") ? part.split(/:(.*)/s) : ["w" + (i + 1), part];
    const fields = {};
    for (const kv of (rest || "").split(",").filter((x) => x.trim())) {
      const [k, val] = kv.split("=");
      fields[k.trim()] = val === undefined ? "1" : val.trim();
    }
    return weightVector(name.trim(), fields);
  });
}

// --refscore: the recorded layout of a reference scene and the optimum,
// both judged under one weight vector (CMP_WEIGHTS in every state).
function refScore(task) {
  const v = task.vector;
  const id = luaString(task.scenario);
  const prefix = weightsPrefix(v);
  const row = { scenario: task.scenario, mode: "refscore", weights: v };
  const judge = (planJson) => {
    const out = runLua("judge", prefix + `include("cmp_lib")\nCmpRun.Judge(${id}, ${luaString(planJson)})`, "judge");
    let score = null;
    for (const e of out.emits) if (e.startsWith("SCORE ")) score = JSON.parse(e.slice(6));
    return { score, error: out.error, log: out.log.slice(-20) };
  };
  const refOut = runLua("judge", `include("cmp_lib")\nCmpRun.ReferencePlan(${id})`, "reference");
  const refPlan = refOut.emits.find((e) => e.startsWith("PLAN "));
  if (refOut.error || !refPlan) {
    row.error = refOut.error || "no reference layout";
    return row;
  }
  const refJudged = judge(refPlan.slice(5));
  row.reference = refJudged.score ? Object.assign({ plan: JSON.parse(refPlan.slice(5)).placements }, refJudged.score) : null;
  if (refJudged.error) row.error = "reference judge: " + refJudged.error;
  // The objective the two are compared on: the weighted adjacency gain, or
  // with land on the gain plus the weighted yields of the worked plots.
  const objective = v.land ? "outputWeighted" : "gain";
  row.objective = objective;
  if (task.referenceOnly) return row;
  const variant = v.land ? "FINE_LAND" : "ORACLE" + (v.oracleLimit ? "@" + v.oracleLimit : "");
  const plan = runLua("sdp", prefix + `include("cmp_lib")\nCmpRun.Plan(${id}, "sdp", ${luaString(variant)})`, "plan_sdp");
  const planJson = (plan.emits.find((e) => e.startsWith("PLAN ")) || "").slice(5);
  row.optimum = { planner: "sdp", variant, planSeconds: plan.seconds };
  if (plan.error || !planJson) {
    row.error = "optimum: " + (plan.error || "no plan emitted");
    row.log = plan.log.slice(-40);
    return row;
  }
  const parsed = JSON.parse(planJson);
  row.optimum.plan = parsed.placements;
  row.optimum.stats = parsed.stats;
  row.optimum.notes = parsed.notes;
  const optJudged = judge(planJson);
  if (optJudged.score) Object.assign(row.optimum, optJudged.score);
  if (optJudged.error) row.error = "optimum judge: " + optJudged.error;
  if (row.reference && optJudged.score) {
    const r = row.reference[objective], o = optJudged.score[objective];
    row.summary = { reference: r, optimum: o, gap: o - r, referenceShare: o > 0 ? r / o : null,
      referenceOptimal: r >= o - 1e-9, referenceLegal: row.reference.legal, optimumLegal: optJudged.score.legal,
      proven: parsed.stats && parsed.stats.oracle ? parsed.stats.oracle.proven === true : null };
  }
  return row;
}

// One task: plan scenario `id` with `planner` (+ its variant), then judge it.
function runTask(task) {
  if (task.keep) return task.keep;
  if (task.vector) return refScore(task);
  if (task.rejudge) return rejudge(task.rejudge, task.weights);
  if (task.cross) return crossScore(task.cross, task.scorers);
  const prefix = weightsPrefix(task.weights);
  const plan = runLua(task.planner, prefix + `
    include("cmp_lib")
    CmpRun.Plan(${luaString(task.scenario)}, ${luaString(task.planner)}, ${luaString(task.variant || "")})
  `, "plan_" + task.planner);
  const result = { scenario: task.scenario, planner: task.planner, variant: task.variant || "", planSeconds: plan.seconds };
  if (task.weights) result.weights = { name: task.weights.name, yields: task.weights.yields };
  let planJson = null;
  for (const e of plan.emits) {
    if (e.startsWith("PLAN ")) planJson = e.slice(5);
  }
  if (plan.error || planJson === null) {
    result.error = plan.error || "no plan emitted";
    result.log = plan.log.slice(-40);
    return result;
  }
  const judged = runLua("judge", prefix + `
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

// -s FILTER: a substring of the scenario id, or a regular expression when
// it starts with "^" (e.g. "^C\\d" for the city-site scenarios only).
function matches(id, filter) {
  return filter.startsWith("^") ? new RegExp(filter).test(id) : id.includes(filter);
}

function listScenarios(filter) {
  const out = runLua("judge", `include("cmp_lib") CmpRun.List()`, "list");
  if (out.error) throw new Error(out.error);
  const ids = out.emits.filter((e) => e.startsWith("SCENARIO ")).map((e) => JSON.parse(e.slice(9)));
  return filter ? ids.filter((s) => matches(s.id, filter)) : ids;
}

if (!isMainThread) {
  if (workerData && workerData.ruleset) RULESET = workerData.ruleset;
  parentPort.on("message", (task) => {
    parentPort.postMessage(runTask(task));
  });
} else {
  const argv = process.argv.slice(2);
  let filter = null;
  let planners = ["sdp", "amt", "ep", "dwp"];
  let jobs = Math.max(1, Math.min(8, (availableParallelism ? availableParallelism() : 4) - 2));
  let out = join(COMPARE, "results", "latest.jsonl");
  let verbose = false;
  let list = false;
  let dump = null;
  let snapshot = null;
  let probe = null; // a Lua file to run in this mod's state (ad-hoc checks)
  let probeArg = null; // its PROBE_ARG global
  // The ruleset .cache/gameinfo.lua was exported from (export_gameinfo.py
  // takes the last game loaded); scenes from another ruleset are skipped.
  let ruleset = "RULESET_EXPANSION_2";
  let rejudgeFile = null;
  let crossFile = null;
  let scorers = ["amt", "ep"];
  let refscore = false; // reference scenes against the optimum (issue 53)
  let weightsSpec = null;
  let referenceOnly = false;
  let only = null; // planner:variant keys
  let add = []; // planner:variant runs added to every selected scenario
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-s") filter = argv[++i];
    else if (a === "-p") planners = argv[++i].split(",");
    else if (a === "--only") only = argv[++i].split(",");
    else if (a === "--add") add = argv[++i].split(",");
    else if (a === "-j") jobs = parseInt(argv[++i], 10);
    else if (a === "--out") out = resolve(argv[++i]);
    else if (a === "-v") verbose = true;
    else if (a === "--list") list = true;
    else if (a === "--dump") dump = argv[++i];
    else if (a === "--snapshot") snapshot = argv[++i];
    else if (a === "--probe") probe = argv[++i];
    else if (a === "--arg") probeArg = argv[++i];
    else if (a === "--ruleset") ruleset = argv[++i];
    else if (a === "--rejudge") rejudgeFile = resolve(argv[++i]);
    else if (a === "--crossscore") crossFile = resolve(argv[++i]);
    else if (a === "--scorers") scorers = argv[++i].split(",");
    else if (a === "--refscore") refscore = true;
    else if (a === "--weights") weightsSpec = argv[++i];
    else if (a === "--reference-only") referenceOnly = true;
    else {
      console.error("usage: compare.mjs [--list] [-s SUBSTRING] [-p sdp,amt,ep] [--only P:V,...] [--add P:V,...] [-j JOBS] [--out FILE] [--ruleset RULESET_...] [-v]\n"
        + "       compare.mjs --refscore [-s REF..] [--weights FILE|NAME:KEY=W,...;...] [--reference-only] [-j JOBS] [--out FILE]\n"
        + "       compare.mjs [-s ..] [--only P:V,...] [--rejudge FILE] --weights FILE|NAME:KEY=W,...;... [-j JOBS] [--out FILE]");
      process.exit(2);
    }
  }
  RULESET = ruleset;
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
  if (probe) {
    const out = runLua("sdp", `PROBE_ARG = ${luaString(probeArg || "")}\n` + readFileSync(resolve(probe), "utf8"), "probe");
    console.log(out.log.join("\n"));
    if (out.error) console.log(out.error);
    process.exit(out.error ? 1 : 0);
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
  // --weights without --refscore: every run (or judging) once per vector.
  let runVectors = [null];
  if (weightsSpec && !refscore) {
    try {
      runVectors = parseWeights(weightsSpec);
    } catch (e) {
      console.error("--weights: " + e.message);
      process.exit(2);
    }
    if (crossFile) {
      console.error("--weights does not go with --crossscore");
      process.exit(2);
    }
  }
  const tasks = [];
  if (rejudgeFile || crossFile) {
    for (const line of readFileSync(rejudgeFile || crossFile, "utf8").split("\n")) {
      if (!line.trim()) continue;
      const row = JSON.parse(line);
      if (filter && !matches(row.scenario, filter)) continue;
      if (only && !only.includes(row.planner + ":" + (row.variant || ""))) continue;
      // A run that gave no plan has nothing to score but still counts (as 0 %): keep it.
      if (!row.plan) tasks.push({ scenario: row.scenario, planner: row.planner, variant: row.variant, keep: row });
      else if (rejudgeFile) {
        for (const weights of runVectors) tasks.push({ scenario: row.scenario, planner: row.planner, variant: row.variant, rejudge: row, weights });
      }
      else tasks.push({ scenario: row.scenario, planner: row.planner, variant: row.variant, cross: row, scorers });
    }
  }
  if (refscore) {
    let vectors;
    try {
      vectors = parseWeights(weightsSpec);
    } catch (e) {
      console.error("--weights: " + e.message);
      process.exit(2);
    }
    const refs = scenarios.filter((s) => s.id.startsWith("REF"));
    if (refs.length === 0) {
      console.error("no reference scenes" + (filter ? " match " + filter : "") + " (tools/refscene.py build)");
      process.exit(2);
    }
    for (const s of refs) for (const vector of vectors) tasks.push({ scenario: s.id, vector, referenceOnly });
  }
  for (const s of rejudgeFile || crossFile || refscore ? [] : scenarios) {
    const runs = s.runs.concat(add.map((k) => ({ planner: k.split(":")[0], variant: k.split(":").slice(1).join(":") })));
    for (const run of runs) {
      const key = run.planner + ":" + (run.variant || "");
      if (planners.includes(run.planner) && (!only || only.includes(key)))
        for (const weights of runVectors) tasks.push({ scenario: s.id, planner: run.planner, variant: run.variant, verbose, weights });
    }
  }
  // Longest runs first (AMT's multi-city joint solve, then multi-city), so
  // the pool does not end waiting on one slow straggler.
  const weight = (t) => (/^(H?M|RM|V)/.test(t.scenario) ? 2 : 0) + (t.planner === "amt" ? 1 : 0);
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
      const w = new Worker(fileURLToPath(import.meta.url), { workerData: { ruleset: RULESET },
        resourceLimits: { maxOldGenerationSizeMb: Number(process.env.CMP_HEAP_MB) || 1536 } });
      w.on("message", (r) => {
        done++;
        if (r.error || r.judgeError || Object.values(r.cross || {}).some((c) => !c || c.error)) failed++;
        appendFileSync(out, JSON.stringify(r) + "\n");
        const s = r.score;
        const crossText = r.cross ? Object.entries(r.cross).map(([k, v]) => `${k} ${v && v.error ? "ERROR " + String(v.error).split("\n")[0].slice(0, 80) : v && v.gain}`).join(" ") : "";
        const m = r.summary;
        const summary = r.error ? "ERROR " + r.error.split("\n")[0].slice(0, 160)
          : r.mode === "refscore" ? `[${r.weights.name}] ${r.objective}: reference ${m ? m.reference : r.reference && r.reference[r.objective]}`
            + (m ? ` optimum ${m.optimum}${m.proven === false ? " (not proven)" : ""} gap ${+m.gap.toFixed(3)}${m.referenceOptimal ? " = optimal" : ""}` : "")
            + (r.reference && !r.reference.legal ? " reference ILLEGAL" : "")
          : crossText ? "cross " + crossText
          : s && s.siteValue !== undefined ? `siteValue ${s.siteValue} tiles ${s.tileValue} districts ${s.districtPotential} legal ${s.legal} violations ${s.violations.length}`
          : s ? `gain ${s.gain} output ${s.output} legal ${s.legal} violations ${s.violations.length}` : "no score";
        const who = r.mode === "refscore" ? (r.optimum ? "sdp:" + r.optimum.variant : "reference")
          : r.planner + (r.variant ? ":" + r.variant : "") + (r.weights ? " [" + (r.planWeights !== undefined ? (r.planWeights || "own") + "->" : "") + r.weights.name + "]" : "");
        console.log(`[${done}/${tasks.length}] ${r.scenario} ${who} ${((r.optimum && r.optimum.planSeconds) || r.planSeconds || 0).toFixed(1)}s ${summary}`);
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
