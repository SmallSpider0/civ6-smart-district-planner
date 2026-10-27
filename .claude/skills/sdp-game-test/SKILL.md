---
name: sdp-game-test
description: Run Civilization VI for the Smart District Planner (civ6mod) — in-game tests in one or all rulesets, the English interface, real mouse clicks, panel screenshots and the late-game stress test, and leave the machine as it was. Use whenever a task needs the game running.
---

# In-game work

Steps are in docs/dev-macos.md (or dev-windows.md) and tools/README.md; this is the order and what goes wrong. Ask first before changing `Mods.sqlite`, or `AppOptions.txt` beyond the display language (`tools/shots.py lang` backs it up and restores it byte for byte). If a personal skill or note for this machine exists (when to take the screen, who runs the night queue, where to report), it comes first.

## When

| Step | Needs |
|---|---|
| `run_tests.py` | the game running; never the front (the game can stay on its own desktop, muted, closed right after) |
| real clicks, screenshots, the stress test, `--rulesets all` before a release | the screen and the mouse for minutes to an hour |

When someone works on the machine, the steps that take the screen wait for a time it is free. Queue them with `python3 -I tools/sdplock.py queue add --what ... --why ... --cmd ...` (one queue for all sessions in the shared folder; it records the worktree and branch). One session runs the queue: for each item, `deploy.py` from that item's worktree, a new game or a game restart as deploy says, the commands, then `queue done ID --result ...` (or `--failed`). An item run outside the queue run, by day with the maintainer's word, is closed the same way right after; an open item keeps showing as queued. The other sessions only add items and read the results. Runs while nobody watches need the screen awake and unlocked (a locked or dark screen takes no clicks and captures only the lock screen) and, on a laptop, the lid open and power connected.

Keep the game in the background unless a step needs the front. `game.py launch`/`newgame` give the front back to the app that had it; real clicks and screenshots bring the game forward and give the front back after each click or capture (`shots.py region` does not: switch back yourself, e.g. `open -b <bundle id>`). Never leave the game in front at the end of a step.

## The game lock

Several sessions may run at once, each in its own worktree, and there is one game, one Tuner connection and one Mods folder. `tools/sdplock.py` keeps a lock on them in a folder shared by the worktrees. `deploy.py`, `game.py`, `run_tests.py`, `realclick.py`, `shots.py`, `stress.py` and `civ6tuner.py serve`/`exec` take it for their worktree by themselves; while another worktree holds it they stop with exit code 4 and say who holds it and why. `civ6tuner.py states` stays free, to look.

- Before any game step: `python3 -I tools/sdplock.py status` (the holder, the night queue, the heavy jobs, the second machine). Say what you need it for: `python3 -I tools/sdplock.py take --purpose "#71 tests"`.
- Busy: `python3 -I tools/sdplock.py wait --take --purpose "..."` in the background; its end is the signal to go on. No polling, no messages asking others to stop.
- Release tests go first: `take --next --purpose "vX.Y.Z release tests"` books the game for when the holder releases it (15 minutes for the booking worktree only).
- `game.py quit` releases the lock and stops this worktree's Tuner daemon. Ending game work without quitting the game: `sdplock.py release`.
- A lock not renewed for 30 minutes while the game is closed or its Tuner daemon is gone is stale: `take --stale` takes it over; then `game.py quit` and start a new game (its state is unknown). `--force` only when you know the holder is gone.
- `run_tests.py` stops when the mod in the Mods folder is not this worktree's: run `deploy.py` (and start a new game) first.

## Before

1. Keep the screen from locking for the whole task, from its first step: a locked screen stops the game drawing, takes no clicks and captures only the lock screen, and long offline steps before the game are enough for it to lock. `caffeinate -dimsu` in the background (macOS), stopped at the end, or the host app's keep-awake.
2. Heavy offline jobs must not run on this machine at the same time: they slow the game to minutes per turn and make timings meaningless. Those started through `sdplock.py heavy` are paused by the lock while the game is held and resumed when it is released; anything else heavy goes to the second machine (sdp-offline-runs).
3. Unattended runs on macOS (the night queue): `python3 -I tools/preflight_night.py` from the session's own shell while someone is still at the machine, so any privacy prompt shows now (docs/dev-macos.md, 隐私弹窗). It must end with `all folders reachable`.
4. `python3 -I tools/deploy.py`. A Lua or UI XML change needs a new game; modinfo or text changes need a game restart (deploy says which).

## Start

- The Tuner daemon (`civ6tuner.py serve`, one Tuner client at a time) is started by `game.py launch`, `newgame` and `load` when none runs; `game.py quit` stops it.
- Not running: `python3 -I tools/game.py launch`, then press the launcher's 开始 (macOS: computer-use `app_click` on bundle `com.aspyr.civ6.steam`, the button's AX element), then `python3 -I tools/game.py newgame --state SDP_Panel --capital --reveal` (waits for the main menu, mutes, fixed map, Rome).
- `run_tests.py` stops when the game loads the Workshop copy of the mod (pitfall 38): move that copy out, never test it.

## Tests

- One change: `python3 -I tools/run_tests.py tests/test_x.lua` (`-k` filters by name).
- For a PR: the test files related to the change (`run_tests.py tests/test_x.lua ...`); before a release the whole set with `--rulesets all` (base, Rise and Fall, Gathering Storm). Skips are tests whose content the ruleset or the account's DLC lacks; report them as skips, not passes.
- English: `game.py quit` → `shots.py lang en` → launch → newgame → tests and English screenshots → `game.py quit` → `shots.py lang restore` (must print "identical").
- Real clicks (macOS, UI changes): `python3 -I tools/realclick.py suite`. It brings the game forward per click and takes the mouse for a few minutes; say so first. "no Civilization VI window on screen": `open -b com.aspyr.civ6.steam`, retry.
- Screenshots: `shots.py stage single|sites|multi`, then `shots.py capture v<round>-panel-<tab>` (and `-en-` for English). Look at every picture before using it. Without the screen recording grant for SDPClick: `shots.py region` and computer-use zoom, then `shots.py save`.
- Stress test (before a release): for each of `pangaea-gs continents-gs islands-rf`: `stress.py load N`, `stress.py run N`; then `stress.py check N` each; `tools/refresh_stress_md.py` writes the tables into the self-test report.
- Popups (natural wonders, historic moments) hold the game's event queue: `game.py popups --close`.

## After

- `python3 -I tools/game.py quit` right after the last in-game step: it releases the game lock and stops the Tuner daemon; restore anything you switched (display language).
- Report what was verified automatically and what needs a person; never call unverified behaviour passed.

## Don't

- No silent waits: before a game command check the game's state (`civ6tuner.py states`); say what a long run does and how long it takes.
- No `until ! pgrep -f ...` loops: they match themselves and never end. Wait on a pid, an exit file (`tools/remote.py wait`) or the tool's own completion.
