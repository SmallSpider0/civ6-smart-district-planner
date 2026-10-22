---
name: 发版清单
about: 发一个新版本前逐项勾选（每次发版开一个）
title: "发布 vX.Y.Z"
labels: release
---

**版本**：vX.Y.Z（modinfo version 改为 N）
**里程碑**：vX.Y.Z 里的 Issue 都已关闭或移到下一版

**测试**（写明平台和结果）
- [ ] 游戏内 `run_tests.py`：原版、迭起兴衰、风云变幻
- [ ] 真实点击 `realclick.py`（macOS）
- [ ] 改了求解器或合法性规则：`compare.mjs -p sdp` 开发集，必要时刷新对比结果
- [ ] 后期存档压力测试 `stress.py`，`refresh_stress_md.py` 刷新自测报告
- [ ] 界面变了：重新截图（`docs/images/`），需要时重做工坊图片（`tools/workshop.py render`）

**文字**
- [ ] CHANGELOG：“未发布”改成 `vX.Y.Z（日期）`，每条都是玩家能看懂的变化
- [ ] `workshop/changenotes/vX.Y.Z.txt`：英文在前、中文在后
- [ ] GitHub 发布说明的草稿：英文在前、中文在后，写给玩家（可以从更新说明和 CHANGELOG 改写）
- [ ] 功能或限制变了：README、`workshop/` 的中英简介（`description.bbcode`、`description_zh.bbcode`）、介绍与评测页（`report/template.html`）同步

**发布**
- [ ] 以上改动经 PR 合并到 main，CI 通过
- [ ] 在 GitHub 发布 Release `vX.Y.Z`，贴上双语发布说明
- [ ] Release 页上有四个附件：压缩包、中英两个单文件页面、`-workshop.zip`；GitHub Pages 的中文页和 `en/` 英文页都已是新版本
- [ ] 上传创意工坊（`docs/workshop-upload.md`），订阅后在游戏里确认能加载；中文标题或简介改过时，在物品页更新简体中文版本（提交包里 UPLOAD.md 的开头会写明）
