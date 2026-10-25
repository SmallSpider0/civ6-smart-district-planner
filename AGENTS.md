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
├── .claude/skills/                   # 固定流程：Issue 处理、游戏内测试、离线重活、发版、监听（sdp-*/SKILL.md）
├── CONTRIBUTING.md                   # 协作约定：分支、提交、测试分工、写作规则
├── CHANGELOG.md                      # 各阶段与各版本改了什么
├── README.md                         # 项目简介（GitHub 首页）
├── LICENSE                           # MIT
├── civ6-mod-from-scratch-prompt.md   # 需求文档（锁定，勿改）
├── .github/                          # CI（validate + 离线测试，Ubuntu 和 Windows）、Issue 与 PR 模板
├── docs/
│   ├── design.md                     # 交付物 3：算法结构 / 目标函数 / DMT 接缝
│   ├── pitfalls.md                   # Civ6 Modding 的坑：完整说明（AGENTS 第 5 节是要点）
│   ├── multicity-design.md           # 选城址、多城、奇观、档位、离线基准的设计（第 1–14 节）
│   ├── notes/                        # 历次实现、实测与修正的记录：NN-主题.md（原第 15–30 节）、issue-<编号>-主题.md
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
完整说明（日期、发现经过、游戏和 DMT 的实际行为、本模组的做法）在 [docs/pitfalls.md](docs/pitfalls.md)，编号相同；动到相关代码前读那一条。

| # | 要点 |
|---|------|
| 1 | mod 名称、描述的文本在 FrontEndActions → UpdateText 加载，modinfo 里也内嵌一份 |
| 2 | 外部文本 XML 只用 `<LocalizedText><Replace Tag Language><Text>`；`<Text id><en_US>` 格式只能内嵌在 modinfo |
| 3 | UI 用 InGameActions → AddUserInterfaces；DMT 写在 `<Dependencies>` |
| 4–5 | 日志 `Lua.log`（Windows 要 `-log`），先搜 `Runtime Error`；本机用 `civ6tuner.py serve` |
| 6 | `InstanceManager:new("模板", "Root", 父)`，模板根控件 `ID="Root"` |
| 7 | include `dmt_yieldcalculator` 后立刻移除它订阅的事件（以源码为准，见 `SDP_Overlay.lua`） |
| 8 | XML 非法属性让控件静默构建失败；控件和属性先在 `Base/Assets/UI/` 找先例（validate.py 查） |
| 9 | 带 String 的 GridButton 自适应撑宽；小步进按钮用 `Controls_ArrowButtonLeft/Right` |
| 10 | 关闭钮 `<Button Style="CloseButtonSmall"/>` |
| 11 | 面板用 `UIManager:QueuePopup(ContextPtr, PopupPriority.Low)` / `DequeuePopup`，先查 `IsInPopupQueue` |
| 12 | 跨上下文 `LookUpControl("/InGame/LaunchBar/ButtonStack")`，在 `Events.LoadScreenClose` 注入 |
| 13–15 | 产出图标只有部分 `ICON_YIELD_*`，文化 `ICON_VICTORY_CULTURE`、信仰 `ICON_RELIGION`；结果明细纯文本，悬停用 DMT tooltip |
| 16 | `TilesRequired` 每凑满 N 个邻居给一份；线性近似只用于排序 |
| 17 | 已建区域由 DMT 从 plot 读 |
| 18 | 特色区域名额 `1 + floor((人口-1)/3)` |
| 19 | 删钉：`DMT_MapPinRemoved` → `DeleteMapPin` → `BroadcastPlayerInfo` → 音效 |
| 20 | 与 AMT 等规划 mod 同开会互相污染（都 hook `GetMapPinSubject`）：一局只开一个 |
| 21 | 新建地图钉后旧的钉对象可能失效，再调用会崩溃：只存 ID，每次 `GetMapPinID` 重取 |
| 22 | `GetMapPin(x, y)` 在空格上会新建钉；只查找时遍历 `GetMapPins()` |
| 23 | 上下文隐藏后 `SetUpdate` 不再被调用：计算中关面板只隐藏窗口（`KeepRunningHidden`） |
| 24 | 自然奇观等弹窗占住事件队列，要调弹窗自己的 Close（`game.py popups --close`） |
| 25 | DMT 的修正缓存（文明、领袖、信仰的相邻与放置规则）要自己建（`SDP_Overlay.RefreshModifiers`） |
| 26 | DMT 的 `CanPlacePin` 不拦奢侈、战略资源：候选格自己排除不可采收的资源 |
| 27 | DMT 不查运河是否连通水域：已拥有的格以引擎可建格为准（`SDP_City.EngineRefused`） |
| 28 | DMT 把沉船等任何水面资源算作海洋资源，引擎不算（已知差异，不改） |
| 29 | 放置图层不管传什么颜色都画绿：分色借政体透镜图层，`LensLayerOn` 时重画 |
| 30 | 写错的 `Controls.<ID>` 运行到那一行才报错：validate.py 检查每个 ID 都在 XML 里 |
| 31 | 按钮里盖一层 `Size="parent,parent"` 的 GridButton 会接住鼠标：选中样式用 Grid |
| 32 | 规则表列名以 `DebugGameplay.sqlite` 的 `pragma table_info` 为准，不凭印象 |
| 33 | 自动回合以观察者身份观察（`PlayerTypes.OBSERVER`），否则外交界面卡住回合 |
| 34 | 地块产出在界面状态里读、等一帧；`GameCore_Tuner` 的 `GetYield` 不含建筑给别格的产出 |
| 35 | 读档前 `Automation.SetAutoStartEnabled(true)`，加载界面才会自己按“继续游戏” |
| 36 | 测试里建区域走正常流程（`RequestOperation` + `FinishProgress`），不用 `CreateDistrict`；魅力、住房在核心状态读 |
| 37 | 游戏去掉 `<Text>` 首尾空格：带空格的分隔符和短句整句写成格式串 |
| 38 | 同一模组 ID 装了两份时游戏加载先登记的那份：只留一份，测试前确认加载的是 deploy 的 |
| 39 | 游戏 Lua 里带 `^` 的 `gsub` 不止替换一次：只改开头用 `sub` 拼 |
| 40 | 城市只能拿挨着自己领土的格：候选按“从领土能连到”筛（`SDP_City.Reach`、`SDP_Search.Reachable`） |
| 41 | 被淹的沿海低地不能放区域，DMT 不查：`SDP_City` 排除（修了防洪堤后恢复） |
| 42 | “需相邻某区域”的奇观只认建奇观那座城的区域 |
| 43 | 阿耳忒弥斯神庙的营地：DMT 不查改良能否建；引擎认本方任意城的营地，不认无主格 |
| 44 | 魅力的两条引擎规则：被掠夺的改良设施让本格和四周 −1、不给住房；学了自然保护后原生树林本格 +1 |

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

**每轮改动流程**（命令细节见 [tools/README.md](tools/README.md)）。一批 Issue 修完再开一个 PR（CONTRIBUTING.md“需求、分支与提交”）：修每个 Issue 时只跑相关的测试文件，整套的 0–3 在开 PR 前统一跑一次。
0. 离线：`node tools/offline_tests.mjs` 跑 `tests/offline/spec_*.lua`（不开游戏，几分钟；CI 上 Ubuntu 约 3.5 分钟、Windows 约 5 分钟）。改求解算法时再跑 `tests/offline/bench_single.lua` 对比质量与预计耗时；
1. 校验：`python3 -I tools/validate.py`。检查 XML 格式、modinfo 与磁盘文件一致、双语文本键一致、`LOC_SDP_*` 引用都有定义、UI XML 只用游戏本体出现过的控件和属性（坑 8，需要 `reference/`）、Lua 语法（luaparse 5.3 模式解析，再禁掉 5.1 没有的写法）与禁用全局、确定性（禁 `math.random`/`os.time`）；
2. 部署：`python3 -I tools/deploy.py`。先校验，再把 `SmartDistrictPlanner/` 同步到游戏的 Mods 目录（增量复制，并删除已不存在的文件）；
3. 验证：改 Lua/UI XML 后回主菜单重新进入对局；改 modinfo/文本需重启游戏（deploy 会提示是哪种；重启用 `tools/game.py quit/launch/newgame`）；然后 `python3 -I tools/run_tests.py` 跑 `tests/` 下的游戏内测试；
4. 排错：保持 `civ6tuner.py serve` 运行，查 `logs/tuner-lua.log`（Windows 上也可查 `Lua.log` 的 `Runtime Error`）；控件不显示且无日志 → 怀疑 XML 非法属性。

**自动化测试分层**：⓪′ 离线对比（`tools/compare.mjs`，见 tools/README.md）：用游戏缓存里导出的真实规则库和原样的 DMT、AMT、EP 代码，在 432 个生成的场景和从真实存档导出的场景（`RS`/`RM`，`tools/snapshot.py`）上比较方案（开发集、留出集、多组权重、奇观、选城址、覆盖范围、真实集，见 tools/README.md），裁判是只加载 DMT 的独立状态，另可用 `--crossscore` 让 AMT、EP 自己的目标函数给方案打分；改算法时只看开发集（`S`/`M`），留出集（`HS`/`HM`）只用来复核；改求解器或合法性规则后跑一遍本 mod（`-p sdp`），看"本 mod 自报的加成 = 裁判的加成"、零违规、漏放的区域都是"no_plot"（裁判判定有位置却没放的记为 "placeable"）；⓪ 离线逻辑测试与基准（`tools/offline_tests.mjs`，fengari 里跑 Lua，DMT 和游戏接口由 `tests/offline/world.lua` 模拟；只证明搜索与记账正确，数值仍以游戏内为准。注意 fengari 的整数是 32 位，游戏里是双精度）；① validate + deploy + 监控 `logs/tuner-lua.log`（全自动）；② `tests/test_*.lua` 经 `run_tests.py` 在指定 Lua 状态里跑断言（全自动；本 mod 面板的 Lua 状态名为 `SDP_Panel`，测试钩子是其中的全局表 `SDP_Panel`；需要改游戏状态的用例用 `@setup`/`@teardown` 在 `GameCore_Tuner` 状态执行 `tests/fixtures/` 脚本；`game.py newgame --ruleset` 可切换三种规则集）；③ computer-use 截图做 UI 验收（仅 macOS，半自动，需用户授权）；另有引擎可建格复核探针 `tests/bench/probe_engine.lua`（新对局的首都）和 `tests/bench/audit_engine.lua`（存档里的每座城，外加需相邻区域的奇观认不认别城的区域；两者都会给玩家全部科技与市政，只在一次性对局或存档里单独跑）；④ 真实鼠标点击 `tools/realclick.py`（仅 macOS：系统鼠标事件，需用户给 SDPClick.app 辅助功能权限，点击期间占用屏幕；Windows 上暂时手动点）；⑤ 发布前在后期存档上做压力测试 `tools/stress.py`（AI 自动打出三张后期存档，逐步计时与核对，结果写进自测报告和交付报告，截图也放进文档）。界面逻辑的测试要经过控件自己的回调（离线替身的 `Control:Click()`、`Toggle()`，取 `State()` 里带出的控件），不要只调内部函数：2026-10-21 合作者发现多城页城址钉取消勾选无效，错在勾选框处理函数里一处 `a and false or nil`（永远得 nil），游戏内和离线测试都直接调规划函数，绕过了它。测试用例不要写死某个文明的规则（如"学院每个相邻区域 +0.5"），按 `ExcludedAdjacencies` 与玩家特性判断；默认测试对局是罗马，换文明（`game.py newgame --leader LEADER_HOJO` 等）能发现这类问题。交付时明确区分"已自动验证"与"需用户确认"的部分，不得声称未经验证的行为已通过。跨平台：mod 无平台相关代码；Windows 上重点看性能与界面布局（缩放、分辨率）。

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
- 不修改需求文档；设计决策写入 `docs/design.md` 或 `docs/multicity-design.md`，一个 Issue 的实现、实测与数字出处写进 `docs/notes/issue-<编号>-<主题>.md`，每段改动在 `CHANGELOG.md` 记一笔。
- 不把 DMT/AMT/EP/游戏本体的源码或数据复制进仓库，更不能进 `SmartDistrictPlanner/` 发布目录（版权与依赖关系：DMT 作为依赖 mod 由玩家自行订阅）。仓库是公开的。
- 回复与文档使用中文；代码标识符与注释用英文或中文均可，但单文件内保持一致。
