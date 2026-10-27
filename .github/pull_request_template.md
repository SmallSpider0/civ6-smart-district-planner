<!-- 中文或英文都可以。 / Chinese or English are both fine. -->

**What it changes / 改了什么**

Closes #

**Tests / 测试** (platform and result; say why any were skipped / 写明平台和结果，没跑的写原因)
- [ ] `python3 -I tools/validate.py`
- [ ] `node tools/offline_tests.mjs` (or the related spec files / 或相关的测试文件)
- [ ] `python3 -I -m unittest discover -s tests/tools` (changed `tools/` / 改了 `tools/`)
- [ ] In-game / 游戏内 `tools/run_tests.py` (the related test files / 相关的测试文件): platform / 平台 ___, result / 结果 ___
- [ ] Changed the solver or the legality rules / 改了求解器或合法性规则: `node tools/compare.mjs -p sdp` (development set / 开发集)
- [ ] Changed the panel / 改了面板: clicked through it, screenshots attached / 点过一遍，附截图

**Docs / 文档**
- [ ] CHANGELOG.md (under 未发布) and the docs describing the changed behaviour / 行为变了的地方，CHANGELOG.md 的“未发布”和相关文档已更新
- [ ] Generated files and the command that made them / 生成的文件和生成命令:
