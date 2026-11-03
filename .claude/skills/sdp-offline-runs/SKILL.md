---
name: sdp-offline-runs
description: Run the Smart District Planner's (civ6mod) offline checks and heavy experiments — offline tests, the development-set check, refreshing stored comparison results, oracle (true optimum) runs — on the right machine, with a scope that fits, and get the results back. Use before starting any compare.mjs run or anything that takes more than a few minutes of CPU.
---

# Offline runs

## Pick the smallest run that answers the question

| Question | Run | Size |
|---|---|---|
| Did the logic break? | `node tools/offline_tests.mjs` (or one `spec_*.lua`) | ~5 min, local |
| Did the solver change plans for the worse? (solver or legality changed; before a release) | `python3 -I tools/refresh_results.py --check` | ~270 runs |
| A measured number in the report after an algorithm change | the commands recorded in docs/notes/ for it | as recorded |
| Refresh a stored result file for the report | `python3 -I tools/refresh_results.py tests/compare/results/F.jsonl` | the file's sdp rows |
| True optimum, weight profiles, reference scenes | `compare.mjs ... sdp:ORACLE...` | hours |

Before any compare.mjs run: `node tools/compare.mjs --list -s 'REGEX'` and count the scenes × variants. A loose regex such as `'^[SM][0-9][0-9]-'` also takes the weight profiles (`~SCI`, `~RND`...) and, with `-p sdp`, the oracle variants: 856 runs and hours instead of minutes. Exclude profiles with `[^~]*$`; pick variants with `--only`.

## Where

First `python3 -I tools/sdplock.py status`: the game lock, the heavy job on this machine and, when there is a second machine, its slots and queue (all sessions share them).

The tools choose the machine; do not choose it yourself (#249, details in tools/README.md "remote.py"):

- `node tools/offline_tests.mjs [FILE...]` and `node tools/compare.mjs ...` started by hand register themselves. Short ones (by the time recorded for each test file) run here; long ones (the full suite, `spec_multi`, benchmarks, comparisons) are placed like `remote.py run` below, and the command waits and prints their output. Run them from the worktree's root so a long one can go to the second machine.
- A job you start in the background, or anything else heavy (refreshes, `--check`, oracle runs, experiments): `remote.py run`. It starts the job on the second machine when it can start there now, else in a snapshot on this machine when the heavy slot here is free and the game lock is not held, else queues it on the second machine (one queue for all sessions, first come, first served). Never start jobs on the second machine by hand.
- Only both machines on one job (splitting the scenes, rerunning only missing rows, when the maintainer says so) or a job that needs this machine's files outside the worktree uses `python3 -I tools/sdplock.py heavy NAME -- CMD` directly: one at a time (later ones wait first come, first served; `status` shows the order), with the workers the local config allows (4 without one; `-j` is lowered to fit), paused while the game lock is held. A job that was paused says so at the end: its timing fields are not usable.

```bash
python3 -I tools/remote.py run NAME [--slots N] -- node tools/compare.mjs ... --out logs/remote/NAME.jsonl
python3 -I tools/remote.py wait NAME --fetch logs/remote/NAME.jsonl     # in the background, wherever it runs
```

- Slots default to the command's `-j` (all slots without one); ask for what the job needs, not the whole machine. Names are unique across sessions: prefix them with your topic.
- The job runs in its own snapshot of the worktree, so `sync` again at any time; `wait --fetch` and `fetch --job NAME` take results from that snapshot.
- Runs whose seconds get reported: `--exclusive` (waits for an empty machine and keeps it), and say which machine.
- `wait` ends when the job ends: that notification is when to carry on. Results there equal this machine's except timing fields.

## Afterwards

- Read the result, don't just count rows: for `--check`, "lower" gains and new violations must be explained before a release (violations "no_plot", a district with no legal tile in range, are not faults).
- Results that go into the repository: in `tests/compare/results/` or `tests/bench/results/`, and the PR description names each file and the exact command.
- Numbers in the report come from those files; record the source in the issue's record in docs/notes/. Tooltips carry no measured numbers (docs/maintaining.md §10).
- Background helpers you started: stop them when done; never leave wait loops behind.
