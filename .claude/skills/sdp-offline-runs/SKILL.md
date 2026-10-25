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
| A tooltip's measured numbers after an algorithm change | the commands recorded in docs/notes/ for that tooltip | as recorded |
| Refresh a stored result file for the report | `python3 -I tools/refresh_results.py tests/compare/results/F.jsonl` | the file's sdp rows |
| True optimum, weight profiles, reference scenes | `compare.mjs ... sdp:ORACLE...` | hours |

Before any compare.mjs run: `node tools/compare.mjs --list -s 'REGEX'` and count the scenes × variants. A loose regex such as `'^[SM][0-9][0-9]-'` also takes the weight profiles (`~SCI`, `~RND`...) and, with `-p sdp`, the oracle variants: 856 runs and hours instead of minutes. Exclude profiles with `[^~]*$`; pick variants with `--only`.

## Where

Heavy runs (more than ~15 minutes of CPU, every oracle run) go to the second machine when there is one (`$SDP_REMOTE`), so this machine stays free for the game and the maintainer:

```bash
python3 -I tools/remote.py sync                       # this worktree, including uncommitted files
python3 -I tools/remote.py run NAME -- node tools/compare.mjs ... --out logs/remote/NAME.jsonl
python3 -I tools/remote.py wait NAME --fetch logs/remote/NAME.jsonl     # in the background
```

`wait` ends when the job ends: that notification is when to carry on. Results there equal this machine's except timing fields; runs whose seconds get reported stay on one machine (say which). Never run heavy jobs here while the game is running (sdp-game-test).

## Afterwards

- Read the result, don't just count rows: for `--check`, "lower" gains and new violations must be explained before a release (violations "no_plot", a district with no legal tile in range, are not faults).
- Results that go into the repository: in `tests/compare/results/` or `tests/bench/results/`, and the PR description names each file and the exact command.
- Numbers in tooltips and the report come from those files; record the source in the issue's record in docs/notes/.
- Background helpers you started: stop them when done; never leave wait loops behind.
