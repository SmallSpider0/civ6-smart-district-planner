// place.mjs - hand a run of offline_tests.mjs or compare.mjs started by hand to
// `tools/remote.py direct` (#249), which registers it and puts it on the right
// machine: short runs here, long ones on the second machine or this machine's
// heavy slot. The tools set SDP_PLACED for the commands they start, so those
// run as asked. Without the local config (CI, a fresh clone) nothing changes.
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join, relative, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// Returns only when the run should go on in this process; otherwise exits with the placed run's code.
export function placeRun(scriptUrl) {
  if (process.env.SDP_PLACED) return;
  const config = process.env.SDP_LOCAL_CONFIG || join(homedir(), ".config", "sdp", "local.json");
  if (!existsSync(config)) return;
  const [python, ...pyArgs] = process.env.SDP_PYTHON
    ? [process.env.SDP_PYTHON]
    : process.platform === "win32" ? ["py", "-3", "-I"] : ["python3", "-I"];
  const script = relative(process.cwd(), fileURLToPath(scriptUrl));
  const r = spawnSync(python, [...pyArgs, join(ROOT, "tools", "remote.py"), "direct", "--",
    "node", script, ...process.argv.slice(2)], { stdio: "inherit" });
  if (r.error) {
    console.error(`place.mjs: could not start tools/remote.py (${r.error.message}); running here unregistered`);
    return;
  }
  process.exit(r.status === null ? 1 : r.status);
}
