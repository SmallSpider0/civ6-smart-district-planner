---
name: 发版清单
about: 发一个新版本前逐项勾选（每次发版开一个）
title: "发布 vX.Y.Z"
labels: release
---

步骤和命令见 `.claude/skills/sdp-release/SKILL.md`（`tools/release.py` 做版本号、更新说明、发布和创意工坊上传）。

**版本**：vX.Y.Z（modinfo version 改为 N，`UI/SDP_Panel.lua` 的 `VERSION` 改为 vX.Y.Z）
**里程碑**：vX.Y.Z 里的 Issue 都已关闭或移到下一版

**测试**（写明平台和结果）
- [ ] 游戏内 `run_tests.py`：原版、迭起兴衰、风云变幻
- [ ] 真实点击 `realclick.py`（macOS）
- [ ] 改了求解器或合法性规则：`compare.mjs -p sdp` 开发集，必要时刷新对比结果
- [ ] 改了算法、规则或测试集：重跑开关提示里实测数字的那几项对比（出处见 multicity-design.md，如换格开关的第 27.2 节），更新中英文提示和那一节
- [ ] 后期存档压力测试 `stress.py`，`refresh_stress_md.py` 刷新自测报告（只改界面的版本不跑，自测报告里写明）
- [ ] 界面变了：重新截图（`docs/images/`），需要时重做工坊图片（`tools/workshop.py render`）
- [ ] 打开 `workshop/preview.jpg` 和 `workshop/images/` 看一遍：封面与创意工坊上正在用的一致（换封面要物品主人上传），图上的截图是这一版的

**文字**
- [ ] CHANGELOG：“未发布”改成 `vX.Y.Z（日期）`，每条都是玩家能看懂的变化
- [ ] `workshop/changenotes/vX.Y.Z.txt`：英文在前、中文在后
- [ ] GitHub 发布说明的草稿：英文在前、中文在后，写给玩家（可以从更新说明和 CHANGELOG 改写）
- [ ] 功能或限制变了：README、`workshop/` 的中英简介（`description.bbcode`、`description_zh.bbcode`）、介绍与评测页（`report/template.html`）同步

**发布**
- [ ] 以上改动在发版准备的 PR 里合并到 main，CI 通过
- [ ] 在 GitHub 发布 Release `vX.Y.Z`，贴上双语发布说明
- [ ] Release 页上有四个附件：压缩包、中英两个单文件页面、`-workshop.zip`；GitHub Pages 的中文页和 `en/` 英文页都已是新版本
- [ ] 更新创意工坊（`docs/workshop-upload.md`）：Mac 上用 SteamCMD 或合作者在 Windows 上传，下载回来或订阅后核对是这一版（开发机核对完把下载的那份移走，悬停启动栏按钮看版本号）；物品页的图片和简体中文版本照提交包里 UPLOAD.md 开头写的改
