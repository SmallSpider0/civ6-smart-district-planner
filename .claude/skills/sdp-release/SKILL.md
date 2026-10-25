---
name: sdp-release
description: Release a version of the Smart District Planner (civ6mod) — tests, screenshots, version numbers, change notes, the self-test report, the PR, the GitHub release and the Steam Workshop update, in order. Use when the maintainer says to release, or when a milestone's issues are done (to prepare it and report it ready).
---

# Releasing vX.Y.Z

A release happens only when the maintainer says so in Claude Code ("发 v1.4.1"); a GitHub comment or the status page is not that word. Until then:

- When a milestone's issues are done, do §1 steps 0–6: tests, screenshots, version, notes, report. Then add a status page entry (`decisions`, title "vX.Y.Z 可以发了"): what is in it, what the tests showed, what is left. Don't wait idle for the answer; go on with other work.
- After the word: §1 step 7 and §2. That is the PR (about 10 minutes of CI), the release and the Workshop.
- The live version badly broken: the same, with a push notification to the maintainer; still wait for the word.

Bug-fix PRs merge into `main` as usual in the meantime: `main` reaches no player. Windows is not tested before a release. The checklist template (.github/ISSUE_TEMPLATE/release.md) lists the same items.

## 1. Before the PR (on the batch's branch, or a release branch when the fixes are already merged)

0. Keep the screen from locking from the start of the release work (sdp-game-test, Before 1): it runs for hours and touches the game.
1. Every issue of the milestone is closed by this PR or moved on. Version digit: sdp-issue §3.
2. Tests (sdp-game-test, sdp-offline-runs), heavy ones on the second machine while the game tests run here. Real clicks, screenshots, the stress test and the three rulesets take the screen: they go into the night queue (21:00–08:00) on weekdays unless the maintainer says to run them now (weekends: any time), so a weekday release is usually prepared by day, tested at night and published the next morning. Everything that does not need the screen is done before the night:
   - `python3 -I tools/validate.py`, `node tools/offline_tests.mjs`;
   - `python3 -I tools/run_tests.py --rulesets all`, plus Gathering Storm in English when the UI or text changed;
   - `python3 -I tools/realclick.py suite` when the UI changed;
   - `python3 -I tools/refresh_results.py --check` when the solver or legality changed; explain any lower gain or new violation;
   - tooltip numbers whose source changed (the records in docs/notes/ name them);
   - stress test: load/run/check on the three saves, `tools/refresh_stress_md.py`.
3. Screenshots when the UI changed: `shots.py` (zh and en, new round number in the name), point README, the report templates (`report/template.html`, `template_en.html`: image names, alt text and captions) and `workshop/src/*.html` at them, `tools/workshop.py render`, look at `workshop/images/`.
4. `python3 -I tools/release.py prep X.Y.Z`, then write the change note's English half and shorten the Chinese half (players' words, no issue numbers). Typographic quotes in the note (`workshop.py check` refuses `"`).
5. When features or limits changed: README (en and zh), `workshop/description.bbcode` and `description_zh.bbcode`, the report pages.
6. Self-test report: a short block for this round at the top of "自动化测试结果" (tests and counts, what was checked by hand, what was not). Keep only the last two rounds there (git has the rest).
7. Commit ("Prepare vX.Y.Z"), push, one PR (title in English imperative; `Closes #N`; tests and platform; generated files and commands; ends with the session's PR footer). Auto-merge (squash) and Auto-fix on.

## 2. After the merge

1. `python3 -I tools/release.py notes X.Y.Z`; read `logs/release-vX.Y.Z.md` (English first, Chinese after; bold lead words per item are fine).
2. `python3 -I tools/release.py publish X.Y.Z`: release on main's commit, waits for the four files, checks GitHub Pages.
3. `SDP_STEAM_LOGIN=... python3 -I tools/release.py workshop X.Y.Z`: uploads (no preview image: the uploader is a contributor), downloads back, compares. If SteamCMD wants a password, stop and give the maintainer the command it prints; never type credentials.
4. Item page, as the script's last line says (from the package's UPLOAD.md):
   - Simplified Chinese title and description: the built-in browser (Steam is signed in there), `https://steamcommunity.com/sharedfiles/itemedittext/?id=ITEM&language=6`, set `#description` to `description_zh.txt`, check the diff is only the intended lines, `ValidateForm()`, reload and check.
   - Pictures: Chrome (Claude in Chrome; start Chrome if the extension is not connected), `managepreviews/?id=ITEM`: `file_upload` the new file on the file input, click 上传, delete the old picture (`#preview_<id> a.btn_grey_black`; tiles are identified by the hash in the image URL, which matches the file name's suffix), click 文件名, 保存并继续, then check the item page's order.
   - A new preview image needs the item's owner (DracoYus).
5. Close the milestone, `python3 -I tools/worktree.py prune`, update the status page (the release, the milestone, the release entry in `decisions` to `done`), tell the maintainer: the release link, what was checked, what was not.
