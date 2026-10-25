---
name: sdp-release
description: Release a version of the Smart District Planner (civ6mod) — tests, screenshots, version numbers, change notes, the self-test report, the PR, the GitHub release and the Steam Workshop update, in order. Use when the maintainer says to release, when a bug-fix milestone is due, or when a milestone's issues are done (to prepare it and report it ready).
---

# Releasing vX.Y.Z

Who decides (CONTRIBUTING.md "需求、分支与提交" 5 and "发版"):

- **Bug fixes only**: a patch milestone that holds only bug fixes (text and document fixes count with them) is released when one of these holds: three ordinary bug fixes are merged and not released; seven days have passed since the first unreleased bug fix was merged; a critical bug is fixed (the live version crashes the game, the panel cannot be used, or plans break the game's rules for ordinary setups), released as soon as it is fixed and tested. If fixing a bug raises a question the maintainer must settle (a default, a requirement, a trade-off), that fix waits for the answer like a feature.
- **Anything else** (a feature or an optimisation, any second- or first-digit version) is released when the maintainer decides. Until then: when its issues are done, do §1 steps 0–6 (tests, screenshots, version, notes, report), report it ready (what is in it, what the tests showed, what is left) and go on with other work. After the decision: §1 step 7 and §2.

Bug-fix PRs merge into `main` as usual in the meantime: `main` reaches no player. Windows is not tested before a release. The checklist template (.github/ISSUE_TEMPLATE/release.md) lists the same items.

## 1. Before the PR (on the batch's branch, or a release branch when the fixes are already merged)

0. Keep the screen from locking from the start of the release work (sdp-game-test, Before 1): it runs for hours and touches the game.
1. Every issue of the milestone is closed by this PR or moved on. Version digit: sdp-issue §3.
2. Tests (sdp-game-test, sdp-offline-runs), heavy ones on the second machine while the game tests run here. Book the game for the release tests when another session holds it (`sdplock.py take --next`). Real clicks, screenshots, the stress test and the three rulesets take the screen: when someone works on the machine they go into the night queue (sdp-game-test, When), so a release is often prepared by day, tested in the free hours and published after. Everything that does not need the screen is done first:
   - `python3 -I tools/validate.py`, `node tools/offline_tests.mjs`;
   - `python3 -I tools/run_tests.py --rulesets all`, plus Gathering Storm in English when the UI or text changed;
   - `python3 -I tools/realclick.py suite` when the UI changed;
   - `python3 -I tools/refresh_results.py --check` when the solver or legality changed; explain any lower gain or new violation;
   - tooltip numbers whose source changed (the records in docs/notes/ name them);
   - stress test: load/run/check on the three saves, `tools/refresh_stress_md.py`. Skipped when the release changes only the interface: `git diff vLAST..HEAD -- SmartDistrictPlanner/Scripts` touches nothing but `SDP_Page*.lua` and `SDP_Preview.lua`, and the panel's changes do not alter what is sent to the solver. Say in the self-test report that it was skipped and why.
3. Screenshots when the UI changed: `shots.py` (zh and en, new round number in the name), point README, the report templates (`report/template.html`, `template_en.html`: image names, alt text and captions) and `workshop/src/*.html` at them, `tools/workshop.py render`, look at `workshop/images/`.
4. `python3 -I tools/release.py prep X.Y.Z`, then write the change note's English half and shorten the Chinese half (players' words, no issue numbers). Typographic quotes in the note (`workshop.py check` refuses `"`).
5. When features or limits changed: README (en and zh), `workshop/description.bbcode` and `description_zh.bbcode`, the report pages.
6. Self-test report: a short block for this round at the top of "自动化测试结果" (tests and counts, what was checked by hand, what was not). Keep only the last two rounds there (git has the rest).
7. Commit ("Prepare vX.Y.Z"), push, one PR (title in English imperative; `Closes #N`; tests and platform; generated files and commands; ends with the session's PR footer). Auto-merge (squash) and Auto-fix on.

## 2. After the merge

1. `python3 -I tools/release.py notes X.Y.Z`; read `logs/release-vX.Y.Z.md` (English first, Chinese after; bold lead words per item are fine).
2. `python3 -I tools/release.py publish X.Y.Z`: release on main's commit, waits for the four files, checks GitHub Pages.
3. `SDP_STEAM_LOGIN=... python3 -I tools/release.py workshop X.Y.Z`: uploads (no preview image: the uploader is a contributor), downloads back, compares. If SteamCMD wants a password, stop and give the person who owns the login the command it prints; never type credentials.
4. Item page, as the script's last line says (from the package's UPLOAD.md):
   - Simplified Chinese title and description: a browser signed in to Steam, `https://steamcommunity.com/sharedfiles/itemedittext/?id=ITEM&language=6`, set `#description` to `description_zh.txt`, check the diff is only the intended lines, `ValidateForm()`, reload and check.
   - Pictures: a browser that can upload files, `managepreviews/?id=ITEM`: put the new file on the file input, click 上传, delete the old picture (`#preview_<id> a.btn_grey_black`; tiles are identified by the hash in the image URL, which matches the file name's suffix), click 文件名, 保存并继续, then check the item page's order.
   - A new preview image needs the item's owner (DracoYus).
5. Close the milestone, `python3 -I tools/worktree.py prune`, and report: the release link, what was checked, what was not.
