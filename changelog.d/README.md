# changelog.d

One file per pull request: `<issue or PR number>.md` (a second one for the same number: `<number>-<word>.md`). Each line is one entry starting with `- `, in players' words, in Chinese like [CHANGELOG.md](../CHANGELOG.md), ending with the issue number, for example `- 多城页……（#217）。` A change players do not notice needs no file. At release time `tools/release.py prep` moves the lines, by number, into the new version's section of CHANGELOG.md and deletes the files; `tools/validate.py` checks the format.

每个 PR 一个文件：`<Issue 或 PR 编号>.md`（同一编号的第二个：`<编号>-<词>.md`）。每行一条，以 `- ` 开头，用玩家的话、和 [CHANGELOG.md](../CHANGELOG.md) 一样写中文，结尾写 Issue 编号，如 `- 多城页……（#217）。` 玩家感觉不到的改动不用写。发版时 `tools/release.py prep` 把各行按编号收进 CHANGELOG.md 新版本的一节并删掉这些文件；`tools/validate.py` 检查格式。
