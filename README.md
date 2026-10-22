# 智能区域规划器（Smart District Planner）

《文明6》区域规划模组：选一座城和想建的区域，它在城市三环内找相邻加成最高的摆法，一键打成带区域图标的地图钉；也能给新城选址，让几座城一起规划。合法性和加成全部由 [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051)（DMT）计算，与地图钉上显示的数一致。

**[下载](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/latest)** · **[介绍与评测](https://smallspider0.github.io/civ6-smart-district-planner/)** · **[安装与使用](docs/install-and-test.md)**

![单城页签：区域分两组排成网格，结果有三套方案](docs/images/v4-panel-single.jpg)

## 能做什么

面板有三个页签：

- **单城**：选一座城，把区域设为必建、候选或不建，给出区域数量和各产出的权重。规划器在城市三环内找加权相邻加成最高的摆法；从候选里挑时给出组合不同的三套方案，点一套就在地图上预览，再一键打钉。单城也能一起放奇观。
- **选城址**：在已探索的地图上给几座新城选位置，考虑水源、耕作地块、奢侈与战略资源、区域潜力，以及新城之间不抢地。给出三套方案，预览后打城址钉。
- **多城**：城址钉和附近的现有城市一起规划区域和奇观，跨城的相邻加成和帝国上限都计入。可以给每座城单独的区域清单，或套用按产出生成的模板（科技城、生产力城……）。

各页签共用：

- 快速、标准、精细三档；规模小时穷举，结果注明是否最优或离上界多远，可以继续优化。同一局面、同样输入，结果每次相同。
- 已建区域和你自己打的钉不挪、不压，并作为邻居计分；全帝国限量的区域（如政府广场）不会重复规划。
- 结果行显示坐标和加成，悬停看 DMT 的逐项来源。
- 社区按魅力计住房，保护区计魅力和周边产出；缺淡水时自动加水渠，泛滥平原多时自动加水坝；方案靠旁边的树林、雨林拿加成时，打钉时在这些格上加“勿砍”提醒钉。
- 耗时长的计算分帧进行，游戏不卡，关掉面板也会算完。可以撤销，撤销记录随存档保存。<kbd>Shift</kbd>+<kbd>L</kbd> 打开面板。
- 原版、迭起兴衰、风云变幻都能用；界面中英双语，跟随游戏语言。

和 Auto Map Tacks Planner、Empire Planner 在同样局面下的对比结果、速度和已知限制，见[介绍与评测](https://smallspider0.github.io/civ6-smart-district-planner/)。

> ⚠️ **一局只开一个规划器**：不要和 Auto Map Tacks Planner、Empire Planner 等区域规划模组同时启用，它们会互相干扰。

## 安装

1. 在创意工坊订阅 [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051)。
2. 从[发布页](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/latest)下载压缩包，把里面的 `SmartDistrictPlanner` 文件夹放进游戏的 Mods 文件夹：
   - Windows：`文档\My Games\Sid Meier's Civilization VI\Mods\`
   - macOS：`~/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/`
3. 主菜单“附加内容”里勾上 Detailed Map Tacks 和“智能区域规划器”，重启游戏。

用法、验收步骤和排错见[安装与使用](docs/install-and-test.md)。问题请在 [Issues](https://github.com/SmallSpider0/civ6-smart-district-planner/issues) 反馈，更新内容见 [CHANGELOG](CHANGELOG.md)。

## 参与开发

先读 [CONTRIBUTING.md](CONTRIBUTING.md)（分支、提交、测试分工、写作规则）和 [AGENTS.md](AGENTS.md)（需求约束、技术方案、模组开发的坑、工作流程）。

| 文档 | 内容 |
|------|------|
| [docs/dev-macos.md](docs/dev-macos.md)、[docs/dev-windows.md](docs/dev-windows.md) | 两个平台的开发环境 |
| [tools/README.md](tools/README.md) | 校验、部署、游戏内测试、离线对比等工具 |
| [docs/workshop-upload.md](docs/workshop-upload.md) | 把提交包上传到 Steam 创意工坊（Windows） |
| [docs/design.md](docs/design.md) | 求解算法、目标函数、与 DMT 的接缝、模块结构 |
| [docs/multicity-design.md](docs/multicity-design.md) | 选城址、多城、奇观、求解档位、离线基准，以及历次实测反馈的改进 |
| [docs/self-test-report.md](docs/self-test-report.md) | 自测报告：验收清单逐项证据、测试结果、截图 |
| [civ6-mod-from-scratch-prompt.md](civ6-mod-from-scratch-prompt.md) | 需求文档 |

```
SmartDistrictPlanner/        模组本体：复制到游戏 Mods 目录即可运行
  SmartDistrictPlanner.modinfo
  Text/                      中英文本
  UI/SDP_Panel.xml/.lua      启动栏按钮与规划面板
  Scripts/                   规则、城市扫描、假想钉层、增量评估（SDP_Board）、搜索引擎（SDP_Search）、
                             单城/多城/城址求解器、档位、分帧任务、预览、打钉、提醒钉
tests/                       游戏内测试（经 FireTuner 执行）；tests/offline 为离线测试与基准，tests/compare 为离线对比
tools/                       校验、部署、测试运行器、游戏控制、打包、路径（paths.py）
report/                      “介绍与评测”页面的生成脚本与模板（发布时由 GitHub Actions 生成并发布）
docs/                        设计、安装说明、自测报告、开发环境、截图
```

## 许可证

[MIT](LICENSE)。本仓库不含 Detailed Map Tacks 及其他模组、游戏本体的代码或数据；玩家需自行订阅 DMT。
