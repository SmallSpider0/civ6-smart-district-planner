# Smart District Planner（智能区域规划器）

《文明6》纯 Lua UI 模组。用法：选一座城市，勾选要建的区域，调好各产出的权重，规划器会在城市三环内穷举所有合法摆放，求出加权相邻加成最高的方案，并一键打成带区域图标的地图钉。合法性判定和相邻加成计算直接复用 [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051)（DMT），所以方案里的数值与 DMT 图钉显示的完全一致。

![面板与结果](docs/images/panel-result.jpg)

相比 Auto Map Tacks Planner（AMT）的改进：
- **最优**：两个区域时穷举全部组合，与暴力枚举的最优解一致；区域多时用线性模型筛出短名单，交给 DMT 精确评估，再做局部搜索。
- **确定性**：同一局面、同样输入，求解结果每次相同。
- **已有地图钉锁定**：不挪动、不覆盖，并作为固定邻居计入总分；已建区域置灰。
- **全局唯一区域**：全帝国已达上限的区域（如政府广场）不会被重复规划。
- **可解释**：结果行显示坐标与产出，悬停显示 DMT 的逐项来源；受影响的已有区域也会列出。
- **速度**：4 个区域约 0.2 秒，8 个区域约 0.5 秒（Mac 实测）。
- 原版、迭起兴衰、风云变幻规则集都能用；界面中英双语，按游戏语言显示。

> ⚠️ **不要与 Auto Map Tacks Planner（AMT）等其他区域规划模组同时启用。**

## 文档

| 文档 | 内容 |
|------|------|
| [docs/install-and-test.md](docs/install-and-test.md) | 安装、使用、验收测试步骤、排错、已知限制 |
| [docs/design.md](docs/design.md) | 求解算法、目标函数、与 DMT 的接缝、模块结构 |
| [docs/multicity-design.md](docs/multicity-design.md) | 多城规划设计（选城址、多城区域、奇观）、求解档位、阶段 8 起的新算法与离线基准 |
| [docs/self-test-report.md](docs/self-test-report.md) | 自测报告：验收清单逐项证据、测试结果、截图 |
| [AGENTS.md](AGENTS.md) | 开发约定、环境、模组开发的坑 |
| [tools/README.md](tools/README.md) | 校验、部署、游戏内测试工具 |
| [civ6-mod-from-scratch-prompt.md](civ6-mod-from-scratch-prompt.md) | 需求文档 |

## 目录

```
SmartDistrictPlanner/        模组本体：复制到游戏 Mods 目录即可运行
  SmartDistrictPlanner.modinfo
  Text/                      中英文本
  UI/SDP_Panel.xml/.lua      启动栏按钮与规划面板
  Scripts/                   SDP_Rules、SDP_City、SDP_Overlay、SDP_Solver、SDP_Pins
tests/                       游戏内测试（经 FireTuner 执行）
tools/                       校验、部署、测试运行器、游戏控制
docs/                        设计、安装测试说明、自测报告、截图
```

状态：MVP（单城规划）已完成。macOS 上三种规则集的自动化测试全部通过；Windows 需按安装测试文档做一次冒烟测试。
