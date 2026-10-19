#!/usr/bin/env node
// luacheck.mjs - syntax and pitfall checks for Civ6 Lua files.
//
// Civ6 runs HavokScript, a Lua 5.1 derivative. Files are parsed in luaparse's
// 5.3 mode (as the requirements specify; its 5.1 mode wrongly rejects the
// valid `break;`) and the constructs 5.1 lacks are then reported by rule.
// HavokScript's own extensions (type annotations, hstructure) appear in the
// game's and DMT's sources but are not accepted here: our code stays plain Lua.
//
// Rules (suppress one on a line with a comment: `-- lint: allow <rule>`):
//   syntax         file does not parse                                 (error)
//   lua51          goto/labels, bitwise or `//` operators, mid-block break (error)
//   banned-global  global that is nil or harmful in the game           (error)
//   banned-call    nil in Civ6 or nondeterministic (constraint 6)      (error)
//   global-assign  global write without the SDP_/sdp_ prefix           (warning)
//
// Usage: node tools/luacheck.mjs [--json] FILE...
// Exit code: 0 no errors, 1 errors found, 2 bad usage.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import luaparse from "luaparse";

// Verified nil in the MainMenu, InGame, GameCore_Tuner and dmt_yieldcalculator
// states on macOS 1.0.12.54 (tests/test_environment.lua keeps checking it).
const BANNED_GLOBALS = {
  _G: "_G is nil in Civ6 Lua states; reference globals by name",
  _ENV: "_ENV is Lua 5.2+; HavokScript is Lua 5.1",
  load: "load is nil in HavokScript; use loadstring",
  require: "require is nil in Civ6; use include()",
  dofile: "dofile is nil in Civ6; use include()",
  module: "module is nil in Civ6",
  setfenv: "setfenv is nil in Civ6",
  getfenv: "getfenv is nil in Civ6",
  debug: "the debug library is nil in Civ6",
  utf8: "utf8 is a Lua 5.3 library and is nil in Civ6",
  bit: "no bit library in Civ6",
  bit32: "no bit32 library in Civ6",
};

const BANNED_MEMBERS = {
  "table.unpack": "table.unpack is nil in Civ6; use unpack",
  "table.getn": "table.getn is nil in Civ6; use #",
  "math.random": "random numbers break determinism (requirement constraint 6)",
  "math.randomseed": "random numbers break determinism (requirement constraint 6)",
  "os.time": "time-dependent logic breaks determinism (requirement constraint 6)",
  "os.date": "time-dependent logic breaks determinism (requirement constraint 6)",
};

const NOT_IN_LUA51_OPS = new Set(["&", "|", "~", "<<", ">>", "//"]);

const GLOBAL_PREFIX = /^(SDP_|sdp_)/;

// Chunk.globals repeats global identifiers already reached through the body.
const SKIP_KEYS = new Set(["loc", "range", "globals", "comments"]);

function suppressions(comments) {
  const byLine = new Map();
  for (const c of comments || []) {
    const m = /lint:\s*allow\s+([\w,\s-]+)/.exec(c.value);
    if (!m) continue;
    const rules = m[1].split(/[\s,]+/).filter(Boolean);
    const line = c.loc.start.line;
    byLine.set(line, new Set([...(byLine.get(line) || []), ...rules]));
  }
  return byLine;
}

export function checkSource(file, source) {
  const diags = [];
  let ast;
  try {
    ast = luaparse.parse(source.replace(/^\uFEFF/, ""), {
      luaVersion: "5.3",
      scope: true,
      locations: true,
      comments: true,
    });
  } catch (e) {
    if (!(e instanceof SyntaxError) || e.line === undefined) throw e;
    const message = e.message.replace(/^\[\d+:\d+\]\s*/, "");
    return [{ file, line: e.line, column: e.column + 1, severity: "error", rule: "syntax", message }];
  }

  const allowed = suppressions(ast.comments);
  const report = (node, severity, rule, message) => {
    const line = node.loc.start.line;
    if (allowed.get(line)?.has(rule)) return;
    diags.push({ file, line, column: node.loc.start.column + 1, severity, rule, message });
  };

  const checkGlobalWrite = (target) => {
    if (target && target.type === "Identifier" && !target.isLocal && !GLOBAL_PREFIX.test(target.name)) {
      report(target, "warning", "global-assign",
        `global '${target.name}' is written without the SDP_/sdp_ prefix (missing 'local'?)`);
    }
  };

  const walk = (node) => {
    if (Array.isArray(node)) {
      node.forEach(walk);
      return;
    }
    if (!node || typeof node !== "object" || typeof node.type !== "string") return;

    if (Array.isArray(node.body)) {
      node.body.forEach((stmt, i) => {
        if (stmt.type === "BreakStatement" && i < node.body.length - 1) {
          report(stmt, "error", "lua51", "break must be the last statement of its block in Lua 5.1");
        }
      });
    }
    switch (node.type) {
      case "GotoStatement":
      case "LabelStatement":
        report(node, "error", "lua51", "goto and ::labels:: are Lua 5.2+; HavokScript is Lua 5.1");
        return;
      case "BinaryExpression":
      case "UnaryExpression":
        if (NOT_IN_LUA51_OPS.has(node.operator)) {
          report(node, "error", "lua51", `operator '${node.operator}' is Lua 5.3; HavokScript is Lua 5.1`);
        }
        break;
      case "Identifier":
        if (!node.isLocal && Object.hasOwn(BANNED_GLOBALS, node.name)) {
          report(node, "error", "banned-global", BANNED_GLOBALS[node.name]);
        }
        return;
      case "MemberExpression": {
        const base = node.base;
        if (base.type === "Identifier" && !base.isLocal) {
          const key = `${base.name}.${node.identifier.name}`;
          if (Object.hasOwn(BANNED_MEMBERS, key)) report(node, "error", "banned-call", `${key}: ${BANNED_MEMBERS[key]}`);
        }
        walk(base); // node.identifier is a field name, not a variable
        return;
      }
      case "TableKeyString":
        walk(node.value); // node.key is a field name, not a variable
        return;
      case "AssignmentStatement":
        node.variables.forEach(checkGlobalWrite);
        break;
      case "FunctionDeclaration":
        if (!node.isLocal) checkGlobalWrite(node.identifier);
        break;
    }
    for (const [key, value] of Object.entries(node)) {
      if (!SKIP_KEYS.has(key)) walk(value);
    }
  };
  walk(ast);
  return diags;
}

function main(argv) {
  const json = argv.includes("--json");
  const files = argv.filter((a) => a !== "--json");
  if (files.length === 0) {
    console.error("usage: node tools/luacheck.mjs [--json] FILE...");
    return 2;
  }
  const diags = files.flatMap((f) => checkSource(f, readFileSync(f, "utf8")));
  if (json) {
    process.stdout.write(JSON.stringify(diags) + "\n");
  } else {
    for (const d of diags) console.log(`${d.severity.toUpperCase()} ${d.file}:${d.line}:${d.column} [${d.rule}] ${d.message}`);
    console.log(`${files.length} file(s), ${diags.filter((d) => d.severity === "error").length} error(s), `
      + `${diags.filter((d) => d.severity === "warning").length} warning(s)`);
  }
  return diags.some((d) => d.severity === "error") ? 1 : 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  process.exitCode = main(process.argv.slice(2));
}
