# AGENTS.md — 智能区域规划器（Smart District Planner）

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
├── CLAUDE.md                         # 指向 AGENTS.md
├── README.md                         # 项目简介
├── civ6-mod-from-scratch-prompt.md   # 需求文档（锁定，勿改）
├── docs/
│   ├── design.md                     # 交付物 3：算法结构 / 目标函数 / DMT 接缝
│   └── install-and-test.md           # 交付物 2：安装与测试（含"勿与 AMT 同开"）
├── SmartDistrictPlanner/             # 交付物 1：mod 本体，整目录复制到游戏 Mods 目录
│   ├── SmartDistrictPlanner.modinfo
│   ├── Text/                         # 本地化（数据库格式 XML）
│   ├── UI/                           # InGame 上下文：同名 .xml + .lua
│   └── Scripts/                      # 纯逻辑模块（求解器、相邻表、overlay），经 ImportFiles 导入后 include
├── tools/                            # civ6tuner.py（Lua 执行/输出）；计划中：校验、部署脚本
├── logs/                             # civ6tuner 输出日志，已 gitignore
└── reference/                        # 指向本机 DMT/AMT/Base UI/DLC 源码的符号链接，已 gitignore
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
| 7 | include `dmt_yieldcalculator` 后立即 Remove 其 `DMT_Initialize()` 订阅的 13 个事件（3 LuaEvents + 10 Events） |
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

## 6. 开发环境与工作流

**环境现状**（2026-10-19 检查）：
- 开发与测试都在 macOS 本机进行；工作目录在 iCloud Drive。可用工具：`node`（v26）、`xmllint`、`sqlite3`、`python3`、`git`；`luaparse` 尚未安装（计划 `npm i -D luaparse` 于 `tools/` 下）。
- 文明6 Mac 版（Aspyr）：版本 **1.0.12.54 (951533)**，universal 二进制（原生 arm64），**Expansion1（R&F）、Expansion2（GS）及全部 DLC 已安装**。显示语言 `zh_Hans_CN`，窗口模式（`FullScreen 0`）。
- DMT（2428969051，2024-01-17 版）与 AMT r49（3771382002，2026-09-19 版）已通过创意工坊同步到本机。
- `include("MapTacks")` 来自**游戏本体** `Base/Assets/UI/MapTacks.lua`，不是 DMT。

**Mac 关键路径**（`~/Library/Application Support/` 下）

| 用途 | 路径 |
|------|------|
| 游戏本体 UI 源码 | `Steam/steamapps/common/Sid Meier's Civilization VI/Civ6.app/Contents/Assets/Base/Assets/UI/` |
| DLC / 资料片 | `…/Civ6.app/Contents/Assets/DLC/{Expansion1,Expansion2,…}/` |
| 创意工坊 | `Steam/steamapps/workshop/content/289070/<id>/` |
| 本地 Mods（部署目标） | `Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/` |
| 日志 | `Sid Meier's Civilization VI/Firaxis Games/Sid Meier's Civilization VI/Logs/` |
| 配置 | 同上目录下 `AppOptions.txt`、`Mods.sqlite`（mod 启用状态：`ModGroupItems.Disabled`） |

Windows 对应路径：Mods 在 `文档\My Games\Sid Meier's Civilization VI\Mods\`，日志在 `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\`。

**参考源码**：`reference/` 下放指向上述位置的符号链接（`dmt`、`amt`、`base-ui`、`dlc`），已 gitignore。**写任何 UI/引擎调用前先在这些源码中找先例**。

**已知环境问题**
- **Lua 日志 → 用 FireTuner 代替**：Mac 版不生成 `Lua.log`（`EnableTuner 1` 也不会）。2026-10-19 已实现 [tools/civ6tuner.py](tools/civ6tuner.py)（用法见 [tools/README.md](tools/README.md)）：`serve` 常驻收集全部 Lua 输出到 `logs/tuner-lua.log`，`exec -s <状态> <代码>` 在游戏内执行 Lua 并返回输出与错误。已在主菜单和对局内实测通过：在游戏内确认了"SDP 测试"组生效，并在对局内调通了 DMT 的 `CanPlacePin`/`GetBonusYields`（状态 `dmt_yieldcalculator`）。游戏 Lua 为 HavokScript（`_VERSION` = `2013.2.0 r13768`）：有 `loadstring`、无 `load`。`AppOptions.txt` 为 CRLF 换行，编辑时需保留 `\r`。**副作用：Tuner 开启时游戏不解锁 Steam 成就**；Tuner 端口只监听 127.0.0.1。
- **每次启动的日志会被清空重写**（Logs 目录在启动时重建）。
- **启动与进入对局（已全自动化）**：`open steam://rungameid/289070` → Aspyr 启动器（bundle `com.aspyr.civ6.steam`，"开始"按钮用 computer-use AXPress 点击）→ 主菜单（开场动画已于 2026-10-19 通过 `PlayIntroVideo 0` 关闭）→ Tuner 在 `MainMenu` 状态执行 `Automation.SetAutoStartEnabled(true); OnPlayCiv6()` → 约 25 秒进入地图。退出用 `Events.UserConfirmedClose()`。详见 [tools/README.md](tools/README.md)。
- **computer-use 限制**：游戏本体窗口（Metal，标题 `Civilization VI (1920x1080 @ 174%)`）不向辅助功能暴露窗口，截图可用但**点击被工具安全校验拒绝**（"Could not verify which document this window is editing"）。需要操作游戏时优先用 civ6tuner 在对应 Lua 状态里直接调用（如 `Mods` 状态的 `Modding.*`）；只有 Lua 做不到的才请用户手动点击。
- **测试用 mod 组**：本机共启用 165/166 个 mod，其中 AMT（hook `GetMapPinSubject`）、Empire Planner（会自建/删除地图钉）及多个改相邻/区域规则的 mod 会干扰测试。2026-10-19 已在 `Mods.sqlite` 新建并选中 **"SDP 测试"** 组（`ModGroupRowId=2`，经 `Modding.log` 验证已生效）：官方内容沿用默认组状态（39 启用、Tutorial 禁用），创意工坊仅启用 DMT。默认组（`ModGroupRowId=1`）未改动，可在游戏"附加内容"界面切回。**本 mod 首次部署、被游戏扫描后，需在该组内勾选启用**（新 mod 在组内的默认状态待验证）。
- **回滚**：同目录下 `AppOptions.txt.bak-20261019`、`Mods.sqlite.bak-20261019` 为修改前备份；修改这两个文件时游戏必须处于关闭状态。
- `Logs/LoadGameViewState.log` 已达约 700MB（反复写 `GAMECORE_LOAD_SAVEFILE_PENDING`），疑似读档卡住时刷出，与本项目无关但占空间。

**每轮改动流程**
1. 校验：全部 XML 过 `xmllint --noout`；全部 Lua 过 luaparse 语法检查（需求文档指定 `luaVersion: 5.3`；但游戏运行时是 Lua 5.1 系的 HavokScript，代码应只用 5.1 子集——不用 `goto`、`//`、位运算符、`utf8` 库）；
2. 部署：整目录 `SmartDistrictPlanner/` 复制到上表的本地 Mods 目录；
3. 验证：回主菜单重读档即可重载 UI 上下文；改 modinfo/文本需重启游戏；
4. 排错：保持 `civ6tuner.py serve` 运行，查 `logs/tuner-lua.log`（Windows 上则查 Lua.log 的 `Runtime Error`）；控件不显示且无日志 → 怀疑 XML 非法属性。

**自动化测试分层**：① 部署 + 监控 `logs/tuner-lua.log`（全自动）；② 独立测试 mod `SDP_Tests` 或直接用 `civ6tuner.py exec` 在 `InGame` 状态跑断言（全自动）；③ computer-use 截图/点击做 UI 验收（半自动，需用户授权）。交付时明确区分"已自动验证"与"需用户确认"的部分，不得声称未经验证的行为已通过。跨平台：mod 无平台相关代码，Windows 上只需按验收清单冒烟测试（重点：性能与界面布局）。

## 7. 验收清单（需求文档第五节）

- [ ] 模组列表正确显示中文名与描述
- [ ] 启动栏出现图标按钮，点击弹出面板
- [ ] 学院+圣地求解秒级出结果；存在相邻互惠更优解时必须给出该解
- [ ] 结果行显示坐标与加成明细；悬停逐项来源与 DMT 图钉数值一致
- [ ] 打钉生成带区域图标的钉；撤销后新钉被真删除
- [ ] 已建区域置灰不可勾选
- [ ] 同一状态求解两次结果一致
- [ ] 勾 3–4 个区域不卡死（停顿 ≤ ~2 秒）

## 8. 代理行为约定

- 需求文档第二节 > 第三、四节硬约束 > 本文其他约定 > 自行设计。
- 不修改需求文档；设计决策写入 `docs/design.md`。
- 不把 DMT/AMT/游戏本体源码复制进 `SmartDistrictPlanner/` 发布目录（版权与依赖关系：DMT 作为依赖 mod 由玩家自行订阅）。
- 回复与文档使用中文；代码标识符与注释用英文或中文均可，但单文件内保持一致。
