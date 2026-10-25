---
name: sdp-game-test
description: Run Civilization VI for the Smart District Planner (civ6mod) — in-game tests in one or all rulesets, the English interface, real mouse clicks, panel screenshots and the late-game stress test, and leave the machine as it was. Use whenever a task needs the game running.
---

# In-game work

The maintainer allows in-game tests without asking. Ask first only before changing `Mods.sqlite`, or `AppOptions.txt` beyond the display language (that one is allowed, through `tools/shots.py lang`). Steps are in docs/dev-macos.md (or dev-windows.md) and tools/README.md; this is the order and what goes wrong.

## When

The maintainer works on this machine during the day. Steps that take the screen or the mouse wait for the night:

| Step | When |
|---|---|
| `run_tests.py` (the game stays on its own desktop, the maintainer's app keeps the front) | any time, muted, the game closed right after |
| real clicks, screenshots, the stress test, `--rulesets all` before a release | queued for 21:00–08:00, run together in one game session |
| any of these at weekends (Saturday, Sunday), or when the maintainer says to run them now | any time |

Queue them in logs/night-queue.md (what, which branch, why), tell the maintainer, and run the queue in the night window. To be woken for it, schedule a one-shot prompt for about 21:05 in this session (CronCreate) when the queue is not empty; the maintainer allowed this for the night queue. Night runs need the lid open, power connected and the screen not locked (a closed lid sleeps the Mac; a locked or dark screen takes no clicks and captures only the lock screen); keep-awake comes from the agent. If the maintainer is at the computer anyway, ask at the end of a turn before taking the screen, and keep the queue for the night meanwhile.

Keep the game in the background: the maintainer's app (Claude Code) stays in front. `game.py launch`/`newgame` give the front back by themselves; `run_tests.py` never needs the front. Only real clicks and screenshots need the game in front, and the tools give the front back after each click or capture (`shots.py region` does not: switch back yourself with `open -b com.anthropic.claudefordesktop` or the app that was in front). Never leave the game in front at the end of a step.

## Before

1. Keep the screen from locking for the whole task, from its first step, not just before the launch: a locked screen stops the game drawing, takes no clicks and captures only the lock screen, and long offline steps before the game are enough for it to lock. Desktop app: `request_keep_awake` with `until: "session_idle"`; request it again in a later turn of the same task if the session went idle. Elsewhere: `caffeinate -dimsu` in the background, stopped at the end. Night runs need it most.
2. Heavy offline jobs must not run on this machine at the same time: they slow the game to minutes per turn and make timings meaningless. Run them on the second machine (sdp-offline-runs) or pause them (`kill -STOP`, resume with `-CONT`; a job whose output is written row by row may simply be stopped and the missing rows rerun later).
3. `python3 -I tools/deploy.py`. A Lua or UI XML change needs a new game; modinfo or text changes need a game restart (deploy says which).

## Start

- `python3 -I tools/civ6tuner.py serve` in the background (one Tuner client at a time).
- Not running: `python3 -I tools/game.py launch`, then press the launcher's 开始 (macOS: computer-use `app_click` on bundle `com.aspyr.civ6.steam`, the button's AX element), then `python3 -I tools/game.py newgame --state SDP_Panel --capital --reveal` (waits for the main menu, mutes, fixed map, Rome). newgame gives the front back to the app the maintainer was using.
- `run_tests.py` stops when the game loads the Workshop copy of the mod (pitfall 38): move that copy out, never test it.

## Tests

- One change: `python3 -I tools/run_tests.py tests/test_x.lua` (`-k` filters by name).
- Before a PR: `python3 -I tools/run_tests.py` in Gathering Storm; before a release `--rulesets all` (base, Rise and Fall, Gathering Storm). Skips are tests whose content the ruleset or the account's DLC lacks; report them as skips, not passes.
- English: `game.py quit` → `shots.py lang en` → launch → newgame → tests and English screenshots → `game.py quit` → `shots.py lang restore` (must print "identical").
- Real clicks (macOS, UI changes): `python3 -I tools/realclick.py suite`. It brings the game forward per click and takes the mouse for a few minutes; say so first. "no Civilization VI window on screen": `open -b com.aspyr.civ6.steam`, retry.
- Screenshots: `shots.py stage single|sites|multi`, then `shots.py capture v<round>-panel-<tab>` (and `-en-` for English). Look at every picture before using it. Without the screen recording grant for SDPClick: `shots.py region` and computer-use zoom, then `shots.py save`.
- Stress test (before a release): for each of `pangaea-gs continents-gs islands-rf`: `stress.py load N`, `stress.py run N`; then `stress.py check N` each; `tools/refresh_stress_md.py` writes the tables into the self-test report.
- Popups (natural wonders, historic moments) hold the game's event queue: `game.py popups --close`.

## After

- `python3 -I tools/game.py quit` and stop the Tuner daemon right after the last in-game step; restore anything you switched (display language).
- Report what was verified automatically and what needs a person; never call unverified behaviour passed. Windows is not tested before a release.

## Don't

- No silent waits: before a game command check the game's state (`civ6tuner.py states`); say what a long run does and how long it takes.
- No `until ! pgrep -f ...` loops: they match themselves and never end. Wait on a pid, an exit file (`tools/remote.py wait`) or the tool's own completion.
