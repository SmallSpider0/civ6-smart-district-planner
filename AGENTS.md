# AGENTS.md — 智能区域规划器（Smart District Planner）

> The development documents of this project are in Chinese. Issues and pull requests in English are welcome. For players: the English part of the [README](README.md#english) and the [English install guide](docs/install-en.md).

给接手本项目的 AI 代理/开发者的工作约定。**需求唯一来源**：[civ6-mod-from-scratch-prompt.md](civ6-mod-from-scratch-prompt.md)（下称"需求文档"）。本文是它的执行摘要与工程约定；两者冲突时以需求文档第二节（需求约束）为准。

## 1. 项目概述

《文明6》（含 R&F / GS）纯 Lua UI Mod：玩家在面板中选城市、勾选区域、调权重 → 穷举城市 3 环内合法摆放 → 给出加权相邻加成最大的方案 → 一键生成带区域图标的地图钉。

- **MVP 范围**：单城规划。多城联合、奇观求解为后续阶段——本期不做，但求解器接口不得假设"只有一个城市"（城市作为参数传入，锁定钉/已占格作为输入集合）。
- **改进对象**：Auto Map Tacks Planner r49（AMT，Steam 3771382002）——多城不符预期、全局唯一区域乱放、结果非最优。
- **硬依赖**：Detailed Map Tacks（DMT，Steam 2428969051，mod id `4ecfcc62-5471-4435-b295-590df213e8d8`）。合法性判定与相邻加成计算**必须复用 DMT**，禁止自行重写。

## 2. 不可更改的需求约束（摘自需求文档第二节）

1. 纯 Lua UI Mod，不碰 C++/DLL；
2. 相邻规则全部从 GameInfo 动态读取，**禁止硬编码**任何文明/区域规则；
3. 目标函数 = 分类型加权和：科学/文化/信仰/金币/生产力，权重 0–3，默认全 1；
4. 政策卡翻倍不计入；
5. 砍树/雨林/沼泽默认允许，面板提供开关可禁止；
6. **确定性**：无随机数、固定遍历顺序，同输入必同输出；
7. 已有地图钉 = 硬约束：永不挪动，作为固定邻居参与计算；
8. 结果 = 带区域图标的规划钉；结果列表悬停显示逐项加成来源（直接用 DMT tooltip）；
9. 运行时检测规则集兼容原版/R&F/GS（运河/堤坝仅 GS）；
10. en_US + zh_Hans_CN 双语，界面默认中文。

## 3. 目录结构

```
civ6mod/
├── AGENTS.md                         # 本文件（代理工作约定）
├── CLAUDE.md                         # 让 Claude Code 读入 AGENTS.md 和 CONTRIBUTING.md
├── CONTRIBUTING.md                   # 协作约定：分支、提交、测试分工、写作规则
├── CHANGELOG.md                      # 各阶段与各版本改了什么
├── README.md                         # 项目简介（GitHub 首页）
├── LICENSE                           # MIT
├── civ6-mod-from-scratch-prompt.md   # 需求文档（锁定，勿改）
├── .github/                          # CI（validate + 离线测试，Ubuntu 和 Windows）、Issue 与 PR 模板
├── docs/
│   ├── design.md                     # 交付物 3：算法结构 / 目标函数 / DMT 接缝
│   ├── multicity-design.md           # 选城址、多城、奇观、档位、离线基准
│   ├── install-and-test.md           # 交付物 2：安装、使用与验收（含"勿与 AMT 同开"）
│   ├── install-en.md                 # 英文安装与使用说明（README 英文部分链接它，package.py 打进压缩包）
│   ├── tester-guide.md               # 给测试者的说明，tools/package.py 打进测试包
│   ├── self-test-report.md           # 自测报告
│   ├── dev-macos.md                  # macOS 开发环境与只在 Mac 上能用的工具
│   ├── dev-windows.md                # Windows 开发环境
│   └── workshop-upload.md            # 在 Windows 上把提交包上传到创意工坊（也是提交包里的 UPLOAD.md）
├── SmartDistrictPlanner/             # 交付物 1：mod 本体，整目录复制到游戏 Mods 目录
│   ├── SmartDistrictPlanner.modinfo
│   ├── Text/                         # 本地化（数据库格式 XML）
│   ├── UI/                           # InGame 上下文：同名 .xml + .lua
│   └── Scripts/                      # 纯逻辑模块（求解器、相邻表、overlay、提醒钉），经 ImportFiles 导入后 include
├── tests/                            # 游戏内 Lua 测试（test_*.lua），由 tools/run_tests.py 经 Tuner 执行；不随 mod 发布
│   ├── offline/                      # 离线测试（spec_*.lua）与基准（bench_*.lua），tools/offline_tests.mjs 在 fengari 里跑，用假世界 world.lua
│   ├── compare/                      # 与 AMT、Empire Planner 的离线对比：真实规则库 + 真实 DMT/AMT/EP 代码 + 模拟引擎，tools/compare.mjs 运行
│   ├── stress/                       # 后期存档压力测试的结果（tools/stress.py）
│   └── bench/                        # 游戏内基准、单价校准与探针（不以 test_ 开头，单独运行）
├── workshop/                         # 创意工坊的标题、中英简介、更新说明、预览图与示意图（源文件在 src/），tools/workshop.py 打提交包
├── report/                           # “介绍与评测”页：build.py 从 tests/compare/results 生成 dist/report/（中文页、英文页，各有单文件版和 GitHub Pages 版），package.py 打进压缩包
├── tools/                            # paths.py、civ6tuner.py、validate.py、deploy.py、run_tests.py、game.py 等，见 tools/README.md
├── logs/                             # civ6tuner 输出日志，已 gitignore
└── reference/                        # 指向本机 DMT/AMT/EP/Base UI/DLC 源码的链接（tools/setup_reference.py 建），已 gitignore
```

命名约定：
- Mod 目录与 modinfo 名：`SmartDistrictPlanner`；Mod GUID：`d2b8b724-4174-42cb-943c-8036778c68ba`（已生成，固定不变）。
- 自有 Lua 文件、全局符号、LuaEvents 统一前缀 `SDP_` / `sdp_`，避免与 DMT（`dmt_`）、AMT 冲突。
- 本地化键前缀 `LOC_SDP_`。

## 4. 核心技术方案要点（硬约束，详见需求文档第三节）

**DMT 接入**
```lua
include("MapTacks");                  -- 游戏本体文件；MapTacks.PlayerTraits / PlayerDistricts
include("dmt_mappinsubjectmanager");
include("dmt_yieldcalculator");       -- 尾部会执行 DMT_Initialize()，见坑 7
```
- `CanPlacePin(pid, subject)` 合法性；`GetBonusYields(pid, subject)` → `yields` + `tooltip`；
- `GetMapPinSubject(pid, x, y)` 是仿真挂钩点；`UpdatePinYields(pid, {})` = 只清特征缓存；
- subject：`{ Key = "DISTRICT_CAMPUS", Type = "DISTRICT", X = x, Y = y }`。

**仿真 overlay**
- 临时替换全局 `GetMapPinSubject` 与 `UpdateMapPinSubject`，让假想 subject 对 DMT 可见；写入存 `subject or false`，读取时 `false → nil`，防止写穿透真实状态。
- 安装后、恢复后、overlay 内每次改动布局后都 `pcall(UpdatePinYields, pid, {})`——DMT 按坐标缓存邻格特征，不清缓存即读陈旧数据。
- 恢复必须在任何错误路径上都执行（用 `pcall` 包住评估体，finally 式恢复）。

**评分**
- 联合总分 = Σ overlay 中**全部** subject（含锁定钉）的加权分；提升 = 联合总分 − 锁定钉基线分。

**性能（主线程停顿 ≤ ~2 秒）**
- 阶段 1：线性查表模型（`District_Adjacencies` → `Adjacency_YieldChanges` 预计算互惠）对全部组合毫秒级排序；
- 阶段 2：仅对 top ~100 做 DMT 精确评估；
- 阶段 3：逐区域局部搜索（其他固定、试全部合法格、迭代到无改进）兜底短名单截断。
- 可替换为等效方案，但不得假死、结果不劣于此。
- 阶段 8 起已替换：`SDP_Search`（模型集束搜索 → 精评 → 局部搜索 → 扰动重建）+ `SDP_Board`（增量 + 记忆的 DMT 评估）。离线基准上质量和耗时都优于上面三段式，见 [docs/multicity-design.md](docs/multicity-design.md) 第 15 节。

**确定性（约束 6 的落地规则）**
- 禁止 `math.random`、依赖时间的逻辑；
- **禁止用 `pairs()` 的遍历顺序影响结果**：凡参与求解/排序的集合，先收集为数组并按稳定键排序（如区域按 Type 字符串、格子按 `(Y, X)` 或 plot index）后用 `ipairs`；
- 同分比较必须有确定的次级排序键（如格子序列字典序）。

## 5. Civ6 Modding 硬坑速查（需求文档第四节，违反必出错）

| # | 要点 |
|---|------|
| 1 | mod 名称/描述的文本在 **FrontEndActions → UpdateText** 加载，否则模组列表显示 `LOC_` 原始键 |
| 2 | 外部文本 XML 只能用 `<LocalizedText><Replace Tag="…" Language="zh_Hans_CN"><Text>…</Text></Replace>`；`<Text id><en_US>` 格式只能内嵌在 modinfo，放外部文件会连累整阶段加载失败 |
| 3 | UI 用 `InGameActions → AddUserInterfaces`（`<Context>InGame</Context>` + LoadOrder）；DMT 依赖写在 `<Dependencies>` |
| 4–5 | 日志：Windows `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log`，需 Steam 启动项 `-log`；跨启动追加；先搜 `Runtime Error` |
| 6 | `include("InstanceManager")`，`InstanceManager:new("模板", "Root", 父)`（冒号），模板根控件 `ID="Root"` |
| 7 | include `dmt_yieldcalculator` 后立即 Remove 其 `DMT_Initialize()` 订阅的事件（需求文档写 3 LuaEvents + 10 Events；本机 DMT 实为 3 + 11，以源码为准，见 `Scripts/SDP_Overlay.lua`） |
| 8 | XML 非法属性 = 控件**静默**构建失败、无日志。Stack 用 `StackPadding`；`AutoSizePadding="w,h"`；一律先在 `Base/Assets/UI/` 找先例 |
| 9 | 带 String 的 GridButton 自适应撑宽；小步进按钮用 `Controls_ArrowButtonLeft/Right` 纹理 |
| 10 | 关闭钮 `<Button Style="CloseButtonSmall"/>` |
| 11 | 打开面板：`UIManager:QueuePopup(ContextPtr, PopupPriority.Low)`；关闭 `DequeuePopup`；先查 `IsInPopupQueue` |
| 12 | 跨上下文 `ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")`；注入时机 `Events.LoadScreenClose` |
| 13–15 | yield 图标只有 `ICON_YIELD_{FOOD,GOLD,PRODUCTION,SCIENCE}_1..5`；文化用 `ICON_VICTORY_CULTURE`、信仰用 `ICON_RELIGION`；`SetIcon(name)` 不带尺寸，区域图标 `SetIcon("ICON_"..dt, 32)`；结果明细用纯文本（"科+2 文+1"），悬停用 DMT tooltip |
| 16 | `TilesRequired` = 每凑满 N 个邻居给一份；线性近似会轻微高估，仅用于排序 |
| 17 | 已建区域由 DMT 从 plot 读，无需特殊处理 |
| 18 | 特色区域名额（GS）：`1 + floor((人口-1)/3)` |
| 19 | 删钉：`LuaEvents.DMT_MapPinRemoved(pin); cfg:DeleteMapPin(pin:GetID()); Network.BroadcastPlayerInfo(); UI.PlaySound("Map_Pin_Remove")` |
| 20 | 与 AMT 等规划 mod 同开会互相污染（都 hook `GetMapPinSubject`）——文档必须注明一局只开一个规划器 |
| 21 | （2026-10-19 实测）新建地图钉后，之前拿到的钉对象可能失效，再调用其方法会让游戏直接崩溃（SIGSEGV）。只保存钉 ID，每次用 `cfg:GetMapPinID(id)` 重新取（DMT 弹窗的 `GetEditPinConfig` 也是这样做的） |
| 22 | `PlayerConfiguration:GetMapPin(x, y)` 在没有钉的格子上会**新建**一个钉；只想查找时遍历 `GetMapPins()` |
| 23 | （2026-10-20 实测）上下文隐藏后 `ContextPtr:SetUpdate` **不再被调用**。弹窗出队（`DequeuePopup`）会隐藏上下文，所以关闭面板后分帧计算会停住。做法：计算进行中关闭面板时，保持上下文显示、只隐藏窗口控件（`SDP_Panel.lua` 的 `KeepRunningHidden`），算完再隐藏上下文 |
| 24 | （2026-10-20 实测）自然奇观、历史时刻等弹窗打开时会**占住游戏的事件队列**（`PopupManager:Lock` → `UI.ReferenceCurrentEvent`），UI 状态里的游戏数据（如 `PlayersVisibility`）停止更新，直到弹窗自己的 `Close` 调用 `Unlock` 释放。只 `DequeuePopup` 不会释放。测试工具关弹窗要调用该弹窗自己的 `OnClose`/`Close`（`tools/game.py popups --close` 已这样做） |
| 25 | （2026-10-20 离线对比发现）DMT 的**修正缓存**（文明/领袖特性、信仰里的相邻规则与放置规则：日本区域互邻、巴西雨林、荷兰河流、高卢"特色区域不挨市中心"、越南"特色区域只建在地貌上"）只由它的 `LoadGameViewStateDone` / `LocalPlayerTurnBegin` 处理函数建立（`InitializeModifierCalculator` + `CacheEffectiveModifiers`）。按坑 7 移除这两个处理函数的上下文必须自己建：`SDP_Overlay.RefreshModifiers`（`InitializeModifierCalculator` 只能调一次，它往表里追加） |
| 26 | （2026-10-20 离线对比发现）DMT 的 `CanPlacePin` 对区域钉**不拦奢侈、战略资源**：`GetRealizedPlotFeatures` 在评估区域钉时先把格上的资源去掉，"不能采收的资源"检查永远不触发。游戏不允许区域压在不能移除的资源上，所以候选格要自己排除（`SDP_City` 的 `RESOURCE`：可见、且 `Resource_Harvests` 里没有的资源） |
| 27 | （2026-10-20 游戏内引擎复核发现）DMT 的 `CanPlacePin` **不检查运河是否连通水域**：首都旁 13 格 DMT 判运河可放，游戏引擎（`CityManager.GetOperationTargets`）不允许。运河的合法性在引擎 C++ 里，GameInfo 读不到。已加引擎复核（`SDP_City.EngineRefused`，经 `SDP_Overlay.CanPlace` 生效），城市已拥有的格子上以引擎为准；离线对比框架的模拟引擎不给可建格，复核在那里不生效。其余区域在罗马、日本、高卢三局复核中与引擎完全一致（`tests/bench/probe_engine.lua`）。引擎只对已解锁的区域、城市已拥有的格给出可建格 |
| 28 | （2026-10-20 游戏内裁判校准发现）DMT 把水面上**任何**可见资源都算作海洋资源（`AdjacentSeaResource`），沉船（`RESOURCECLASS_ARTIFACT`）也算，引擎不算：港口挨着沉船时 DMT 比引擎多 1 金币。相邻加成按约定用 DMT，未修，列为已知问题；`tests/bench/calibrate_judge.lua` 把这种差异单独列出。另：引擎对特色区域的可建格受人口名额限制（坑 18），校准前置因此把首都人口设为 25 |
| 29 | （2026-10-20 截图时发现）透镜图层 `Hex_Coloring_Placement`（游戏放置区域时用的那层）**不管传什么颜色都画成同一种绿**，`SetLayerHexesColoredArea` 的颜色参数无效。要分色用魅力透镜的图层 `Hex_Coloring_Appeal_Level`；但打开它会触发 `Events.LensLayerOn`，小地图（`MinimapPanel.lua` 的 `OnLensLayerOn` → `SetAppealHexes`）随后往同一层填满魅力颜色，所以收到该事件时要清掉重画自己的格（`SDP_Preview`） |
| 30 | （2026-10-20 游戏内测试发现）脚本里写错或已删掉的 `Controls.<ID>` 在游戏里是 nil，**只有运行到那一行才报错**，离线的控件替身按需造控件，发现不了。`validate.py` 现在检查每个 `Controls.<ID>` 都是 UI XML 里的 ID |
| 31 | （2026-10-21 合作者实测发现）按钮里盖一层 `Size="parent,parent"` 的 GridButton（游戏页签的选中样式 `TabButtonSelected`，带 `ConsumeMouseOver="1"`），显示时会**接住鼠标**，下面的按钮点不到。游戏页签没事是因为选中的页签不用再点；需要反复点的格子用 Grid 画选中样式（`Texture="Controls_Tab" SliceStart="0,136" SliceCorner="21,16"`，即 `TabButtonSelectedGrid`）。`validate.py` 检查实例里可点击的根控件上没有这样的按钮。合成点击进不了游戏窗口，这类问题只有真人点击能发现 |
| 32 | （2026-10-21 离线对比发现）规则表的列名以 `Cache/DebugGameplay.sqlite` 为准（`sqlite3 … "pragma table_info(表名)"`），不要照印象写：`AppealHousingChanges` 的列是 `AppealChange`，不是 `AppealHousingChange`。读到 nil 只在用到那一行时才报错；离线假世界的表是照着代码写的，测不出列名错，只有用真实规则的对比框架（`tools/compare.mjs`）和游戏内会暴露 |
| 33 | （2026-10-21 压力测试发现）`AutoplayManager` 以玩家 0 身份观察（`SetObserveAsPlayer(0)`）时，AI 的外交会话（初次见面、交易）发到本地的外交界面等回答，回合停住。以观察者身份观察（`SetObserveAsPlayer(PlayerTypes.OBSERVER)`，`SetReturnAsPlayer(0)`），与游戏自带的自动化测试相同。强行关外交界面（`OnForceClose`）后游戏崩溃过一次（崩在游戏自己的网络线程，原因不明），不要这样关 |
| 34 | （2026-10-21 压力测试发现）`GameCore_Tuner` 状态里的 `Plot:GetYield` 不含建筑给别的地块的产出，连刚放的农场也不反映；界面状态（`InGame`、`SDP_Panel`）读到的才是玩家看到的产出，且要等一帧。读地块产出一律在界面状态里读。保护区古树林、避难所给周边地块的产出（`Adjacent_AppealYieldChanges`）因此曾被误判为“游戏不给”（`tests/bench/probe_preserve.py`） |
| 35 | （2026-10-21 压力测试发现）读档后加载界面停在“继续游戏”按钮，等玩家点。读档前在主菜单状态执行 `Automation.SetAutoStartEnabled(true)`，加载界面会自己按（`LoadScreen.lua` 的 `OnLoadGameViewStateDone`），与开新局相同 |
| 36 | （2026-10-21 压力测试发现）测试里用建造队列的 `CreateDistrict` 直接建出的区域，清不清格上的地貌和玩家正常放置不一样（群岛存档：玩家有采矿，直接建在树林上的商业中心，树林留在区域下面），还绕过人口名额和前置科技。校准“建区域会改变什么”要走正常流程：界面状态里 `CityManager.RequestOperation(city, CityOperationTypes.BUILD, {X, Y, DISTRICT_TYPE})` 下令，再在核心状态 `city:GetBuildQueue():FinishProgress()` 建完（`tools/stress.py check`、`tests/bench/probe_ownplot.py`）；区域不能用金币购买。界面状态里的魅力、住房读数也会滞后，一律在 `GameCore_Tuner` 里读魅力和住房，在界面状态里读地块产出（坑 34） |
| 37 | （2026-10-22 英文界面检查发现）游戏载入文本时去掉 `<Text>` 首尾的空格：英文分隔符 `"; "` 读出来是 `";"`，`" / "` 是 `"/"`。中文全角标点不受影响，所以中文界面看不出来。分隔符写进格式串（`LOC_SDP_LIST_JOIN` = `{1_A}; {2_B}`，`SDP_UI.Join`）；需要前后空格的短文本同样整句写成格式串（如 `LOC_SDP_SITES_NEW_KIND` = `{1_Name} {2_Count} (new)`） |
| 38 | （2026-10-22 实测）同一个模组 ID 装了两份（Mods 文件夹和创意工坊）时，“额外内容”里两份都列出、可以分别启用，但对局的启用列表（`GameConfiguration.GetEnabledMods()`）只记模组 ID，开局时游戏加载 `Mods.sqlite` 里先登记的那份（`ModRowId` 小），与启用的是哪一份无关：Mods 那份启用、创意工坊那份停用，对局里 `Modding.GetActiveMods()` 给出的仍是创意工坊那份（带 `SubscriptionId`）。哪份先登记取决于安装经过（`deploy.py` 改了文件后，本地那份会重新登记、排到后面），不一定是新的那份。所以只留一份；开发机上测试前确认加载的是 deploy 的那份 |
| 39 | （2026-10-22 英文界面截图时发现）游戏的 Lua 里带 `^` 锚点的 `string.gsub` 不止替换一次：`("at most"):gsub("^%l", string.upper)` 得到 `"AT most"`，次数 2。标准 Lua（离线测试的 fengari）只替换一次，所以离线测不出。要只改开头，用 `s:sub(1, 1):upper() .. s:sub(2)` 或 `find` 加 `sub` |

## 6. 开发环境与工作流

开发在 macOS 和 Windows 两台机器上进行。**开工前读当前平台的环境说明**：macOS 见 [docs/dev-macos.md](docs/dev-macos.md)，Windows 见 [docs/dev-windows.md](docs/dev-windows.md)。分支、提交、测试分工和写作规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。

**两个平台共用**
- 工具：`node`（`cd tools && npm ci` 装 luaparse、fengari）、Python 3.8 以上、`git`；`xmllint` 可选。文档里的命令写作 `python3 -I`，Windows 上换成 `py -3 -I`。
- 游戏、创意工坊和游戏用户目录的位置由 [tools/paths.py](tools/paths.py) 给出，`python3 -I tools/paths.py` 列出找到的位置；不在默认位置时设环境变量 `SDP_STEAM`、`SDP_GAME_DOCS`、`SDP_GAME_DATA`。
- **参考源码**：`python3 -I tools/setup_reference.py` 在 `reference/` 下建链接（`dmt`、`amt`、`ep`、`base-ui`、`dlc`；macOS 是符号链接，Windows 是目录联接），已 gitignore。**写任何 UI/引擎调用前先在这些源码中找先例**。`include("MapTacks")` 来自**游戏本体** `Base/Assets/UI/MapTacks.lua`，不是 DMT。
- **FireTuner**：`AppOptions.txt` 里设 `EnableTuner 1` 后，游戏在 127.0.0.1:4318 监听，同一时间只接受一个客户端（开着官方 FireTuner 时本项目的工具连不上）。[tools/civ6tuner.py](tools/civ6tuner.py) `serve` 常驻收集全部 Lua 输出到 `logs/tuner-lua.log`，`exec -s <状态> <代码>` 在游戏内执行 Lua 并返回输出与错误。`AppOptions.txt` 为 CRLF 换行，编辑时保留 `\r`。**副作用：Tuner 开启时游戏不解锁 Steam 成就。**
- **改 `AppOptions.txt`、`Mods.sqlite` 时游戏必须关闭，并先问用户。**
- **游戏 Lua 运行时（2026-10-19 在主菜单与对局内各状态实测，[tests/test_environment.lua](tests/test_environment.lua) 持续检查）**：
  - 以下为 nil，[tools/luacheck.mjs](tools/luacheck.mjs) 会报错：`_G`、`load`、`require`、`dofile`、`module`、`setfenv`、`getfenv`、`debug`、`utf8`、`bit`、`bit32`、`table.unpack`、`table.getn`。可用 `loadstring`、`unpack`、`include`。
  - 游戏 Lua 为 HavokScript（`_VERSION` = `2013.2.0 r13768`）。游戏本体和 DMT 源码里有它的扩展语法（类型标注 `function f(x:number)`、`hstructure`），我们的代码**不用**，保持纯 Lua 5.1。
  - **计时器只有秒级**：`os.clock`、`Automation.GetTime` 按整秒跳，`UI.GetElapsedTime` 按帧更新，一次调用内都不变，无法在 Lua 内测耗时。性能（停顿 ≤ ~2 秒）用 `run_tests.py` 报告的单文件墙钟时间测量（Tuner 往返约 0.02 秒）。
  - 执行很快：3000 万次简单循环约 0.1 秒。
- **测试对局固定**：`tools/game.py newgame` 默认把本地玩家设为图拉真（罗马，陆地开局）、地图与游戏种子设为 20261019，每次都是同一张图，测试结果可复现。城址与多城测试需要已探索的地图：`game.py newgame --capital --reveal` 在建城后揭示首都周围 12 格（`tests/fixtures/reveal_area.lua`）并关掉随之出现的自然奇观弹窗。随机开局里可能出现毛利这类海上开局的文明，开拓者第 1 回合无法建城，导致测试前置失败。新建城市后会弹出"历史时刻"等弹窗，低优先级的规划面板会排在它们后面；截图核对前用 `game.py popups --close` 关掉。退出游戏用 `game.py quit`（`Events.UserConfirmedClose()`）。
- **测试用 mod 组**：AMT（hook `GetMapPinSubject`）、Empire Planner（会自建/删除地图钉）及改相邻/区域规则的 mod 会干扰测试。在"额外内容"里建一个只开官方内容、DMT 和本 mod 的 mod 组再测。新 mod 在新建的组里**默认禁用**，可在主菜单用 `Modding.EnableMod(handle, true)` 启用、`Modding.DisableMod(handle)` 停用（游戏自己的启用逻辑，见 Base `FrontEnd/Mods.lua`）。开发机不要订阅本模组的创意工坊版（3824473635），否则游戏可能加载创意工坊那份，测的是旧代码（坑 38）。取消订阅后 Steam 不一定马上删掉下载的文件夹（`steamapps/workshop/content/289070/3824473635`），游戏仍会扫到它，要自己移走。`run_tests.py` 开测前检查加载的是哪一份，是创意工坊那份就停下。
  - **mod 列表的名称**：mod 未启用时，`FrontEndActions` 的文本不加载，列表显示 `LOC_SDP_MOD_NAME` 原文；列表和详情（`Modding.GetModText`）读的是 modinfo 内嵌的 `<LocalizedText>`。所以名称、简介、描述在 modinfo 里也写一份，validate.py 检查两份一致。

**每轮改动流程**（命令细节见 [tools/README.md](tools/README.md)）
0. 离线：`node tools/offline_tests.mjs` 跑 `tests/offline/spec_*.lua`（不开游戏，几秒到十几秒）。改求解算法时再跑 `tests/offline/bench_single.lua` 对比质量与预计耗时；
1. 校验：`python3 -I tools/validate.py`。检查 XML 格式、modinfo 与磁盘文件一致、双语文本键一致、`LOC_SDP_*` 引用都有定义、UI XML 只用游戏本体出现过的控件和属性（坑 8，需要 `reference/`）、Lua 语法（luaparse 5.3 模式解析，再禁掉 5.1 没有的写法）与禁用全局、确定性（禁 `math.random`/`os.time`）；
2. 部署：`python3 -I tools/deploy.py`。先校验，再把 `SmartDistrictPlanner/` 同步到游戏的 Mods 目录（增量复制，并删除已不存在的文件）；
3. 验证：改 Lua/UI XML 后回主菜单重新进入对局；改 modinfo/文本需重启游戏（deploy 会提示是哪种；重启用 `tools/game.py quit/launch/newgame`）；然后 `python3 -I tools/run_tests.py` 跑 `tests/` 下的游戏内测试；
4. 排错：保持 `civ6tuner.py serve` 运行，查 `logs/tuner-lua.log`（Windows 上也可查 `Lua.log` 的 `Runtime Error`）；控件不显示且无日志 → 怀疑 XML 非法属性。

**自动化测试分层**：⓪′ 离线对比（`tools/compare.mjs`，见 tools/README.md）：用游戏缓存里导出的真实规则库和原样的 DMT、AMT、EP 代码，在 432 个场景上比较方案（开发集、留出集、多组权重、奇观、选城址、覆盖范围，见 tools/README.md），裁判是只加载 DMT 的独立状态，另可用 `--crossscore` 让 AMT、EP 自己的目标函数给方案打分；改算法时只看开发集（`S`/`M`），留出集（`HS`/`HM`）只用来复核；改求解器或合法性规则后跑一遍本 mod（`-p sdp`），看"本 mod 自报的加成 = 裁判的加成"、零违规、漏放的区域都是"no_plot"（裁判判定有位置却没放的记为 "placeable"）；⓪ 离线逻辑测试与基准（`tools/offline_tests.mjs`，fengari 里跑 Lua，DMT 和游戏接口由 `tests/offline/world.lua` 模拟；只证明搜索与记账正确，数值仍以游戏内为准。注意 fengari 的整数是 32 位，游戏里是双精度）；① validate + deploy + 监控 `logs/tuner-lua.log`（全自动）；② `tests/test_*.lua` 经 `run_tests.py` 在指定 Lua 状态里跑断言（全自动；本 mod 面板的 Lua 状态名为 `SDP_Panel`，测试钩子是其中的全局表 `SDP_Panel`；需要改游戏状态的用例用 `@setup`/`@teardown` 在 `GameCore_Tuner` 状态执行 `tests/fixtures/` 脚本；`game.py newgame --ruleset` 可切换三种规则集）；③ computer-use 截图做 UI 验收（仅 macOS，半自动，需用户授权）；另有引擎可建格复核探针 `tests/bench/probe_engine.lua`（会给玩家全部科技与市政，只在一次性对局里单独跑）；④ 真实鼠标点击 `tools/realclick.py`（仅 macOS：系统鼠标事件，需用户给 SDPClick.app 辅助功能权限，点击期间占用屏幕；Windows 上暂时手动点）；⑤ 发布前在后期存档上做压力测试 `tools/stress.py`（AI 自动打出三张后期存档，逐步计时与核对，结果写进自测报告和交付报告，截图也放进文档）。界面逻辑的测试要经过控件自己的回调（离线替身的 `Control:Click()`、`Toggle()`，取 `State()` 里带出的控件），不要只调内部函数：2026-10-21 合作者发现多城页城址钉取消勾选无效，错在勾选框处理函数里一处 `a and false or nil`（永远得 nil），游戏内和离线测试都直接调规划函数，绕过了它。测试用例不要写死某个文明的规则（如"学院每个相邻区域 +0.5"），按 `ExcludedAdjacencies` 与玩家特性判断；默认测试对局是罗马，换文明（`game.py newgame --leader LEADER_HOJO` 等）能发现这类问题。交付时明确区分"已自动验证"与"需用户确认"的部分，不得声称未经验证的行为已通过。跨平台：mod 无平台相关代码；Windows 上重点看性能与界面布局（缩放、分辨率）。

## 7. 验收清单（需求文档第五节）

2026-10-19 在 macOS 上完成自测，逐项证据见 [docs/self-test-report.md](docs/self-test-report.md)。标 ◐ 的项逻辑已自动验证，但真实鼠标点击或画面需用户确认。

- [x] 模组列表正确显示中文名与描述（Lua 验证 + 额外内容界面截图）
- [◐] 启动栏出现图标按钮，点击弹出面板（按钮截图 + 回调测试；游戏窗口拒绝合成点击）
- [x] 学院+圣地求解秒级出结果；存在相邻互惠更优解时必须给出该解（与暴力枚举最优一致）
- [x] 结果行显示坐标与加成明细；悬停逐项来源与 DMT 图钉数值一致（悬停截图 + DMT 存储比对）
- [x] 打钉生成带区域图标的钉；撤销后新钉被真删除
- [x] 已建区域置灰不可勾选
- [x] 同一状态求解两次结果一致
- [x] 勾 3–4 个区域不卡死（停顿 ≤ ~2 秒；实测 ≤ 0.2 秒）
- [◐] Windows 实测：合作者 2026-10-20、10-21 两轮实测，意见已处理（见 [docs/multicity-design.md](docs/multicity-design.md) 第 20、22 节）；完整验收清单还没在 Windows 上走过

## 8. 代理行为约定

- 需求文档第二节 > 第三、四节硬约束 > 本文其他约定 > 自行设计。
- 不修改需求文档；设计决策写入 `docs/design.md` 或 `docs/multicity-design.md`，每段改动在 `CHANGELOG.md` 记一笔。
- 不把 DMT/AMT/EP/游戏本体的源码或数据复制进仓库，更不能进 `SmartDistrictPlanner/` 发布目录（版权与依赖关系：DMT 作为依赖 mod 由玩家自行订阅）。仓库是公开的。
- 回复与文档使用中文；代码标识符与注释用英文或中文均可，但单文件内保持一致。
