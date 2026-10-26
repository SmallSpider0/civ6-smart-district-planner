**修了什么**（一个 Issue 一个 PR；几个紧密相关的合在一起时每个 Issue 一行）
Closes #


**测试**（写明在哪个平台跑的；没跑的写原因。跑和这个改动相关的测试，整套在发版前跑）
- [ ] `python -I tools/validate.py`
- [ ] `node tools/offline_tests.mjs`
- [ ] 游戏内 `tools/run_tests.py`（相关的测试文件）：平台 ＿＿，结果 ＿＿
- [ ] 改了求解器或合法性规则：`node tools/compare.mjs -p sdp` 开发集
- [ ] 改了界面：真实点击或手动点过，截图附上

**文档**
- [ ] 行为变了的地方，相关文档和 CHANGELOG.md 已更新

**发版**（只有发版准备的 PR 填，见发版清单）
- [ ] 版本号、CHANGELOG、更新说明、自测报告、截图；生成的结果写明是哪些文件、怎么生成的
