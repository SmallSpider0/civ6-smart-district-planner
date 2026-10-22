**这一批修了什么**（一批 Issue 一个 PR，每个 Issue 一行）
Closes #


**测试**（写明在哪个平台跑的；没跑的写原因。修每个 Issue 时跑相关的测试文件，下面这些在开 PR 前统一跑一次）
- [ ] `python -I tools/validate.py`
- [ ] `node tools/offline_tests.mjs`
- [ ] 游戏内 `tools/run_tests.py`：平台 ＿＿，结果 ＿＿
- [ ] 改了求解器或合法性规则：`node tools/compare.mjs -p sdp` 开发集
- [ ] 改了界面：真实点击或手动点过，截图附上

**文档**
- [ ] 行为变了的地方，相关文档和 CHANGELOG.md 已更新

**发版**（这一批要发版时，发版准备放在本 PR 里，见发版清单）
- [ ] 版本号、CHANGELOG、更新说明、自测报告、截图；生成的结果写明是哪些文件、怎么生成的
