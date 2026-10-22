# 更新记录

只列要点，细节在链接的设计文档章节里。括号里是这一段的提交。

## 未发布

- 多城：市政广场、外交区这类全帝国限建的区域在共用清单里设为必建时，放在城市列表里最靠前的那座城，其他城标“已达帝国上限”，从候选里补足每城数量（#28）。之前这些城会少规划一个区域。
- 城址钉一环内没有主人的格子留给这座新城，别的城不再在上面规划区域（建城时这些格子归新城）。多城页和单城页都是这样（#26）。
- 启动栏按钮的悬停提示显示版本号，问题反馈模板改为照这里填版本（#27）。
- 上架 Steam 创意工坊：[智能区域规划器](https://steamcommunity.com/sharedfiles/filedetails/?id=3824473635)，内容是 v1.1.0。README、中英安装说明和介绍与评测页把订阅列为第一种装法，并提醒 Mods 文件夹里和创意工坊只留一份：两份都在时游戏只加载其中一份，不一定是新的，也不一定是启用的那份。
- README 改成英文在前、中文在后的完整双语：能做什么、安装、参与开发、许可证都有英文。英文安装说明补上已知限制和已测平台。Release 的压缩包不再带给测试者的说明 `TEST_GUIDE.md`（本地给测试者打的包照旧带）。开发文档仍是中文，入口处加了英文说明。

## v1.1.0（2026-10-22）

第二个公开版本：[发布页](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/tag/v1.1.0)。从这一版起，介绍与评测页有英文版，Release 附带创意工坊提交包。

玩家能看到的变化：

- 选城址：悬停列出每个城址拿到的奢侈、战略资源和份数，标出算作新种类的；行上的奢侈分、战略分按整套方案归属后再算，重叠的资源不再两边都算，各城址的分加起来等于方案总分（[#8](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/8)）。
- 选城址：悬停分别写出离我方最近的城市或已打城址钉的距离、离本方案其他城址的距离（[#9](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/9)）。
- “添加奇观”下拉框按时代排列，同一时代按造价从低到高；悬停显示时代（[#7](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/7)）。
- 英文界面在游戏里逐页检查过：英文分隔符丢了空格（游戏去掉文本首尾的空格）、“奇观”“好位置”“区域清单”“档位”标签被下拉框挡住、按钮和开关文字溢出、过长的区域名和奇观名被截断，都已修好；“1 wonders”这类单复数按游戏的写法处理。补了英文界面截图，用在创意工坊、用法示意图和英文介绍页上（[#2](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/2)）。
- 英文界面改用游戏自己的叫法：tile（不再写 plot）、valid（不再写 legal）、map tack、Specialty districts、Woods / Rainforest / Marsh 等专有名词首字母大写；“Need population”分组改叫“Specialty districts”，“Tier”改叫“Effort”，提醒钉名改为“Don't chop: …”。中文界面和文档里的名称也按游戏中文改：政府广场 → 市政广场，林苑、圣所 → 古树林、避难所，水坝 → 堤坝，航天中心 → 宇航中心，科森 → U型港，苏库巴 → 曼丁哥市场，主菜单的“附加内容” → “额外内容”（[#2](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/2) 的文字部分）。
- “介绍与评测”页有了英文版（前 6 节，附录链接到中文页），与中文页随同一个 Release 发布，数字来自同一份数据；两页顶部互相链接，压缩包和 Release 附件里各有一份单文件版（[#5](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/5)）。
- README 顶部加了英文简介和下载、英文介绍页、英文安装说明三个链接；压缩包里多了英文安装与使用说明 `INSTALL_AND_USE_EN.md`（[#3](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/3)）。

仓库与流程：

- 准备上架 Steam 创意工坊：标题、中英简介、预览图和示意图放在 `workshop/`；每个 Release 附带创意工坊提交包，由合作者在 Windows 上上传。
- 问题反馈模板改为中英并列，新建 Issue 的页面链接介绍与评测页和安装说明；GitHub 发布说明以后英文在前、中文在后（[#4](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/4)、[#6](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/6)）。
- 游戏内测试不再假定所有 DLC 和规则都在：没有保护区（越南和忽必烈包）时、原版规则没有“港口与商业中心分城”这条规则时，相关检查跳过。

## v1.0.0（2026-10-22）

第一个公开版本：[发布页](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/tag/v1.0.0)有压缩包和单文件的介绍与评测页，网页版在 <https://smallspider0.github.io/civ6-smart-district-planner/>。这一版相对上一段只改了仓库和文档，模组本身没有变化。

- 仓库整理，为上 GitHub 和与 Windows 合作开发做准备：
  - 加了 MIT 许可证、`.gitattributes`（统一 LF）、CI（validate 和离线测试，在 Ubuntu 和 Windows 上跑）、Issue 和 PR 模板。
  - 游戏和 Steam 的位置集中到 `tools/paths.py`，Windows 有了默认位置；`tools/setup_reference.py` 在两个平台上建 `reference/` 链接。
  - `game.py` 的退出、开局、关弹窗可以在 Windows 上用。
  - 文档分成共用约定（AGENTS.md、[CONTRIBUTING.md](CONTRIBUTING.md)）和平台环境（[macOS](docs/dev-macos.md)、[Windows](docs/dev-windows.md)）。
- 交付报告改写成面向玩家的“介绍与评测”页：前 6 节讲能做什么、安装与使用、和 AMT、Empire Planner 的对比（只写做法差异和实测结果）、速度、已知限制、反馈；技术说明和完整数据放进折叠的附录。验收表以自测报告为准，后续设计选择移到[多城设计第 18.2 节](docs/multicity-design.md#182-现状2026-10-22)，交付物清单删掉。
- 发布 Release 时自动打包、附上页面，并把页面发布到 GitHub Pages；README 顶部加了下载、介绍与评测、安装三个链接。

## 2026-10-22（c5e70cb）

- 保护区的林苑、圣所给周边地块的产出，只在保护区设为必建时计分；从候选里挑出时只计住房，周边产出照常显示，标"候选，不计分"。

## 2026-10-21 第二轮实测反馈与压力测试（08f6c36、2ffc379）

[多城设计第 22 节](docs/multicity-design.md#22-第二轮实测反馈点击问题港口与商业中心分城社区与保护区2026-10-21)

- 修好三个点击问题：区域格子点到必建后点不动、城址钉取消勾选无效、"替换旧钉"删掉选城址页打的钉。
- 港口与商业中心默认不放在同一座城。
- 社区按魅力计住房，保护区计魅力和周边产出（`SDP_Appeal`），魅力模型按游戏实测校准。
- 娱乐中心和水上乐园不放进同一座城；必建区域抢同一块地时，放下能放的，另一个写明原因。
- 区域占掉农场、牧场时，结果里单列少掉的改良设施住房（只提示，不计分）。
- 真实鼠标点击测试 `realclick.py`；三张后期存档上的压力测试 `stress.py`。

## 2026-10-21 多城标准档的宽束联合起点（98d0960、0096850）

[多城设计第 21 节](docs/multicity-design.md#21-多城标准档宽束联合起点2026-10-21)

## 2026-10-20 第一轮实测反馈，阶段 14–18（8eb7d42、41f9842、cb86697）

[多城设计第 20 节](docs/multicity-design.md#20-实测反馈的改进阶段-14182026-10-20)

- 区域可设为必建、候选或不建，规划器从候选里挑，并给出组合不同的三套方案。
- 距离成本；缺淡水时自动加水渠，泛滥平原多时自动加水坝；"勿砍"提醒钉；面板重新布局。
- 给合作者的测试包和交付报告（55eff74、40d699f）。

## 2026-10-20 游戏内验证与对比（99d2308 至 432d1a7）

[多城设计第 17–19 节](docs/multicity-design.md#17-游戏内验证与校准2026-10-20)

- 在游戏里验证阶段 8–12，修了后台计算、选城址和预览的问题，校准单价和预计耗时。
- 钉按城市编号；遵守文明特性里的相邻和放置规则。
- 用真实规则库和原样的 DMT、AMT、Empire Planner 代码做离线对比，含留出集、多组权重、奇观和选城址。
- 多城逐城清单与模板、游戏引擎可建格复核、撤销记录随存档保存、单城奇观、"好位置"热力图、Shift+L 快捷键。
- 工业区、娱乐中心、水上乐园的覆盖范围。

## 2026-10-19 阶段 0–12（ea554be 至 0db1024）

- 阶段 0：校验、部署、FireTuner 客户端、游戏内测试工具。
- 阶段 1–7：面板骨架、规则与城市扫描、DMT 假想钉层、确定性求解器、面板与打钉撤销、交付文档（[设计说明](docs/design.md)）。
- 阶段 8：求解档位、地块部分、更快的单城搜索（[多城设计第 15 节](docs/multicity-design.md#15-阶段-8-实现记录2026-10-19离线)）。
- 阶段 9–12：多城区域、多套方案与预览、奇观、选城址（[多城设计第 16 节](docs/multicity-design.md#16-阶段-912-实现记录2026-10-19离线)）。
