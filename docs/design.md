# 设计说明

交付物 3：算法结构、目标函数、与 DMT 的接缝。带图的说明见[介绍与评测](https://smallspider0.github.io/civ6-smart-district-planner/)页的附录 A（`report/part_algo.html`）；各项改动的来龙去脉和实验见 [multicity-design.md](multicity-design.md)。

## 模块结构

```
SDP_Panel (UI/SDP_Panel.lua，InGame 上下文，Lua 状态名 SDP_Panel)
 ├─ 启动栏按钮注入、弹窗队列、面板控件、测试钩子
 ├─ SDP_Solver   单城求解（SDP_Search：穷举 / 模型集束搜索 → 精评 → 局部搜索 → 扰动重建；候选池时先挑组合）
 ├─ SDP_Multi    多城联合（同一个 SDP_Search；可选的地块部分 SDP_Land、覆盖项 SDP_Coverage；
 │                依赖魅力的区域另有住房与魅力项 SDP_Appeal）
 │   ├─ SDP_Overlay  假想摆放层：替换 DMT 的钉读写，调用 DMT 的 CanPlacePin / GetBonusYields；可隐藏一格的地貌
 │   │   └─ DMT（include dmt_yieldcalculator，移除其事件订阅）
 │   ├─ SDP_City     城市扫描：候选格、排除原因、已建区域、锁定钉、淡水、距离成本
 │   └─ SDP_Rules    规则集、可规划区域、区域互惠表、自动区域的种类、要分城的区域（全部读 GameInfo）
 ├─ SDP_Remind   方案靠哪些树林、雨林拿相邻加成（提醒钉）
 └─ SDP_Pins     打钉与撤销（走 DMT 自己的加钉 / 删钉流程）
```

所有逻辑都在面板这一个 Lua 状态里运行；DMT 在自己的上下文里照常工作，两边只通过地图钉数据和 `LuaEvents.DMT_MapPinAdded/Removed` 交互。

## 目标函数定义

- 单项得分 = Σ 权重[y] × 产出[y]，y 取科学、文化、信仰、金币、生产力五项（`SDP_Rules.YIELDS`），权重 0–3，默认全 1（约束 3）。产出是 DMT `GetBonusYields` 给出的相邻加成，不含政策卡翻倍（约束 4，DMT 本身不算）。
- **联合总分** = 方案里每个新区域的得分 + 每个固定 subject 的得分。固定 subject 是城市四环内本玩家的已建区域（含市中心）和锁定地图钉（`SDP_Overlay.FixedSubjects`），它们的得分会因为新区域相邻而变化。
- **提升（Gain）** = 联合总分 − 基线。基线是不放新区域时固定 subject 的总分。求解器最大化提升；结果里的 `Neighbours` 列出得分变化的固定 subject。
- **可选的三项**：面板打开"计入地块"时加上地块部分（`SDP_Land`，区域占掉的格少耕作的产出）；多城页签的覆盖权重不为 0 时加上覆盖项（`SDP_Coverage`，权重 × 方案新覆盖的（城市, 类别）个数，见 multicity-design.md 第 19 节）；距离成本权重不为 0 时减去距离成本（每个区域、奇观 权重 × (到最近的本方市中心的格数 − 1)，见 multicity-design.md 第 20.3 节）。覆盖项和距离成本默认关，关时目标就是五项加权和（加上默认打开的地块部分）。
- **住房与魅力项**（2026-10-21）：方案里有依赖魅力的区域（`AppealHousingChanges` 有行的：社区、保护区），或城市旁已有、已打钉的这类区域时，加上住房权重 × 它们的住房，以及必建保护区的古树林、避难所给周围未开发地块的产出（从候选里挑出的保护区只显示不计分；`SDP_Appeal`，multicity-design.md 第 22.3 节）。住房按所在格的魅力定，魅力随方案变化（相邻区域的 `Districts.Appeal`、建区域清掉的地貌和改良设施）。DMT 不算这一项。住房权重默认 1。
- **分城**（2026-10-21）：从候选里挑区域时，同一座城不同时挑港口和商业中心（以及其他贸易路线互斥的区域，规则从修正读：灯塔的贸易路线容量要求本城没有市场）。这是挑选时的约束，不进目标函数；凑不够数量时放行；面板默认打开（multicity-design.md 第 22.2 节）。
- **互斥**（2026-10-21 压力测试）：一座城不能同时有的区域（`MutuallyExclusiveDistricts`：娱乐中心与水上乐园及其特色版本）。DMT 只拿已建区域检查，规划器自己挡：两个都必建时后写的那个不放并写明原因，候选组合永不同时含两者，城里已建其一时另一个置灰（`SDP_Rules.Exclusive`）。

## 求解算法结构（`SDP_Search`，单城、多城、选城址共用）

1. **单项表**：每个区域在每个候选格上单独放下时，DMT 判合法、给分（含对已有区域的影响）。没有合法格的区域记为 `NO_LEGAL_PLOT`。
2. **小规模穷举**：合法布局数不超过档位上限（快速 1000 / 标准 3000 / 精细 40000）时逐个精确评估，结果最优。
3. **大规模**：线性模型（单放分 + 相邻两区域的互惠 − 地块损失）做集束搜索，取模型分最高的一批布局用 DMT 精确评估，再做局部搜索（移动、交换、整组平移）和“拆一片再重放”。
4. **放不下时**：一个完整方案都没有（几个必建区域抢同几格）时，少放 1 个必建区域再解，还不行少放 2 个……放得最多的胜出，没放下的记为 `NO_FREE_PLOT`。
5. **从候选里挑**：给出区域数量后，候选组合按乐观分排序，依次粗解前几个，换类型，前三名完整求解，给三套组合不同的方案。
6. **多城**：所有城共用候选格，按城分块求解（一次重解一座城，其他城固定），跑一组固定起点取最好，最后补放没放上的对象。

精确分一律来自 DMT，由 `SDP_Board` 增量计算并按（区域，格，6 个邻格上的规划）记忆，相同局面不重复调用 DMT。

**确定性**（约束 6）：只遍历排序后的数组；同分按格子序列的字典序；预算都是计数（节点数、DMT 调用数、布局尝试数），不看时间。

**耗时**：游戏内单城 6–8 个区域标准档不到 0.3 秒，3 城联合约 2–3 秒，精细档、多城、选城址分帧计算，游戏照常响应（`SDP_Task`）。后期存档的实测见自测报告。

**验证**：`tests/test_solver*.lua`（与 DMT 暴力穷举一致、确定性、锁定钉不被占、禁砍伐、耗时上限）；离线 `tests/offline/`；与 AMT、EP 的离线对比 `tools/compare.mjs`。

## 与 DMT 的接缝（阶段 3，`Scripts/SDP_Overlay.lua`）

**include 与事件**：`SDP_Overlay.lua` 顶部 `include("dmt_yieldcalculator")`（它再 include `civ6common`、`dmt_modifiercalculator`、`dmt_mappinsubjectmanager`），文件末尾的 `DMT_Initialize()` 会在我们的 Lua 状态里再订阅一遍 DMT 的处理函数。紧接着逐个 `Remove`：本机 DMT（2024-01-17 版）实际是 3 个 LuaEvents + 11 个 Events（需求文档写的是 3 + 10），以 `DMT_Initialize` 源码为准。`InitializeCache()` 等初始化保留。

**假想摆放层**：
- DMT 只通过全局 `GetMapPinSubject` / `UpdateMapPinSubject` 读写地图钉。`Install(pid)` 时替换这两个全局：
  - 读：先查层，再查真实钉快照；快照用 DMT 的 `LoadMapPinSubjectTable` 一次性反序列化，因为原版每次调用都要反序列化整张表。
  - 写：只写进层，写入值为 `subject or false`，读到 `false` 当作 nil。
  - 其他玩家的读写交回原函数。
- `Uninstall()` 恢复原函数；`With(pid, fn, ...)` 用 `pcall` 包住 `fn`，任何路径都会卸载，然后重新抛出错误。
- `Set(x, y, subject|false|nil)` 用来手动放置或隐藏真实钉。

**缓存**：DMT 的 `GetRealizedPlotFeatures` 按坐标缓存地块特征，缓存键不含 subject。所以一个格子是"候选区域本身"还是"别人的邻居"，结果取决于谁先算。为此安装、卸载、每次改层以及每次评估前后都执行 `pcall(UpdatePinYields, pid, {})`。传空列表时它只清缓存，`BroadcastMapPinSubjects` 也不会发网络消息，因为本状态没有未广播的改动。

**评估**：`Evaluate(placements, fixed, weights)`。
- 把 placements 放上层，清缓存。
- 对每个 placement 依次调 `GetBonusYields` 和 `CanPlacePin`，对每个 fixed subject 调 `GetBonusYields`。
- 结束后把层恢复成评估前的样子，再清一次缓存。
- 返回 `Legal`（全部可放）、`Total`（所有项的加权分之和，即联合总分）以及逐项的产出、DMT tooltip、得分、可放性与原因。
- DMT 抛错时只标记该项（`Error`，并视为不可放），不中断整次评估。

**固定 subject**（`FixedSubjects(scan)`）：城市四环内本玩家的已建区域（含市中心，不含奇观）和非普通地图钉（锁定钉）。它们的产出会因新区域相邻而变化，计入联合总分。提升 = 方案总分 − 不放新区域时的基线总分。

**实测**（2026-10-19，GS）：
- 6 种区域 × 6 个候选格共 36 个假想 subject，与 DMT 对真实钉计算并保存的结果逐项一致：产出 tooltip、产出、可放性、不可放原因。其中 26 个可放，10 个不可放。
- 锁定学院钉旁边规划两个区域后，学院的 tooltip 与产出和放真实钉时完全一致，科技 +1。
- 单次评估（2 个区域加固定邻居）约 0.45 毫秒，2 秒预算内大约能做 4000 次精确评估。

**未揭示格**：DMT 在未揭示的格子上读不到地形，对部分区域（如需要海岸的）`CanPlacePin` 会报错。城市扫描把未揭示格排除（`UNREVEALED`）。

## 数据层（阶段 2）

两个纯逻辑模块，经 modinfo `ImportFiles` 导入，由 `SDP_Panel.lua` 先 `include("MapTacks")`（游戏本体文件）再 include。所有返回的列表都已排序，不依赖 `pairs()` 顺序。

**`Scripts/SDP_Rules.lua`**（全部从 GameInfo 读，约束 2）
- `Ruleset()`：`GameConfiguration.GetRuleSet()`，即 `RULESET_STANDARD` / `RULESET_EXPANSION_1` / `RULESET_EXPANSION_2`。运河、堤坝等只在 GS 的 GameInfo 里存在，不需要按规则集写分支。
- `PlannableDistricts(pid)`：沿用地图钉弹窗的 `MapTacks.PlayerDistricts`（本文明特色区域替换其基础区域，其他文明的特色区域与奇观伪区域 `DISTRICT_WONDER` 剔除），再去掉 `CityCenter`；按 `DistrictType` 排序。字段：`Type`、`Name`、`Icon`（`ICON_` + 类型）、`Specialty`（`RequiresPopulation`，占特色区域名额）、`OnePerCity`、`MaxPerPlayer`。
- `AdjacencyTable(pid)`：线性排序模型用的区域互惠表。只取 `District_Adjacencies` → `Adjacency_YieldChanges` 中 `OtherDistrictAdjacent`（任意相邻区域）和 `AdjacentDistrict`（指定类型）两类行。`TilesRequired = N` 折算为每个邻居 `YieldChange / N`（坑 16：会略微高估，只用于排序）。按 DMT 的口径过滤：科技/市政前置与过时、`ExcludedAdjacencies` 中本玩家特性排除的行。
- `NeighbourGain(adj, D, X)`：D 从一个相邻 X 区域获得的五项计分产出（`Any` + `From[X]`）。

**`Scripts/SDP_City.lua`**
- `PlotsInRange(x, y, r)`：r 环内格子（不含中心），按 plot index 排序。
- `PinsInRange(pid, x, y, r)`：只读 `GetMapPins()`。注意 `PlayerConfiguration:GetMapPin(x, y)` 在没有钉的位置会**新建**一个钉。
- `Scan(pid, cityID, {allowFeatureRemoval})`：
  - 三环内格子分为候选格和排除格（附原因：城市中心、已有区域、奇观、自然奇观、已有地图钉、他国领土、本国其他城市的领土、禁砍伐时的可移除地貌）。
  - 无主格保留为候选，因为可以买地或扩张获得。
  - 已有地图钉（四环内，即所有候选格的邻居范围）全部视为锁定：钉所在格不可用，钉本身作为固定邻居交给阶段 3 的 overlay。
  - "可移除地貌"取自 `GameInfo.Features.Removable`，本机 GS 数据为树林、雨林、沼泽，正好对应约束 5。
- `SpecialtyCapacity(pop)` = `1 + floor((pop-1)/3)`（坑 18）；扫描结果附带已用名额 `SpecialtyBuilt`。
- `DistrictStatus(scan, districts)`：`BUILT`（本城已建且每城限一个，面板置灰）、`EXCLUSIVE`（本城已建与它互斥的区域）或 `MAX_PER_PLAYER`（全帝国数量已达上限，如市政广场，已建和已打钉的都算），用来避免 AMT 那样乱放全局唯一区域。

## 界面骨架（阶段 1）

- 一个 InGame 上下文 `UI/SDP_Panel.xml/.lua`（AddUserInterfaces，LoadOrder 14000，依赖 DMT）同时负责启动栏按钮和面板。
- **启动栏按钮**：`Events.LoadScreenClose` 时向 `/InGame/LaunchBar/ButtonStack` 注入 `SDP_LaunchBarItem`（与游戏 `LaunchBarItem` 同形，图标 `ICON_MAP_PIN_DISTRICT`）和一个分隔点，并按游戏 `RealizeBacking()` 的做法调整启动栏底板宽度。热重载（`isReload`）时立即注入；上下文关闭时把这两个控件从启动栏删掉，避免留下失效的重复按钮。
- **面板**：`UIManager:QueuePopup(ContextPtr, PopupPriority.Low)` 打开、`DequeuePopup` 关闭，先查 `IsInPopupQueue`（坑 11）。外框沿用游戏弹窗写法（`DropShadow2` 包 `WindowFrameTitle`，标题 `WindowHeader`，右上角 `CloseButtonSmall`）。Esc 在面板打开时关闭面板，关闭时不拦截。
- **对外接口**：`LuaEvents.SDP_OpenPanel()` / `LuaEvents.SDP_ClosePanel()`。
- **测试钩子**：面板上下文里的全局表 `SDP_Panel`（`Open`/`Close`/`IsOpen`/`HandleInput`/`LaunchButton`），供 `tests/test_panel.lua` 在 `SDP_Panel` Lua 状态里调用。
- **mod 列表文本**：名称、简介、描述同时写在 modinfo `<LocalizedText>`（未启用时也能显示）和 `Text/*.xml`（FrontEndActions，坑 1）。

## 面板（`UI/SDP_Panel.xml/.lua`）

窗口固定在左上（启动栏下方），560 × 920，不铺全屏遮罩，地图大部分仍然可见。三个页签共用同一套控件写法；单城页自上而下：
- **城市与区域数量**：下拉框列出本玩家的城市（按城市 ID 排序），默认选地图上当前选中的本方城市，没有则选首都。右侧"区域数量"步进：要规划几个占人口名额的区域，必建的也算在内（反馈第 1 条，见 multicity-design.md 第 20 节）。
- **特色区域名额提示**：已建数、本次数量、当前人口上限。超出时只提示，不阻止。
- **区域网格**：`PlannableDistricts` 分两组、各排成三列（反馈第 6、7 条），按本地化名称排序：
  - 占人口名额的区域（`RequiresPopulation`），状态 必建 / 候选 / 不建，默认候选；全帝国限一个的（市政广场）只有必建 / 不建，默认不建。
  - 不占名额的区域，状态 自动 / 必建 / 不建；能自动的（`SDP_Rules.AutoKind`：水渠类、堤坝）默认自动，其余默认不建。
  - 点一下按 候选（或自动）→ 必建 → 不建 循环（`SDP_UI.NextState`）。必建和自动用选中的亮底；不建、本城已建或已达帝国上限的变暗，后两者不能点，格子右侧写原因。
  - 求解请求里的区域始终按类型名排序，方案不受点击顺序影响。
- **奇观与好位置**：选中的奇观显示成标签，点一下去掉；"添加奇观"下拉框只列还没选的（反馈第 2 条）。右侧是好位置下拉框。
- **权重**：八列，每列图标在上、左右箭头在下：五种产出和食物用游戏的字体图标（`[ICON_Science]` 等，同一张 `FontIcons.dds` 里的圆形产出图标，反馈第 3 条）；地貌（只用于地块部分）和距离成本（步长 0.5，默认 0，反馈第 9 条）写短字：字体图标里能对应它们的地形、移动、范围都是黑底方块，与产出图标风格不同（2026-10-20 在游戏里对比过）。悬停显示名称和含义。
- **开关一行**：计入占地、允许砍伐、替换旧钉（n）、提醒钉（反馈第 5 条）。短标签，完整说明在悬停提示里。
- **档位、预计耗时、求解 / 继续优化**：计算中"继续优化"换成"取消"。挑选候选、选了奇观或精细档时分帧计算。
- **结果**：
  - 汇总行："加权提升（相邻、地块、距离……）"，只列打开的部分；悬停显示方法、DMT 调用次数等。
  - 有多套方案时列出方案行，点一行即显示该方案并在地图上预览（区域图标和数值、提醒钉的位置；`SDP_Preview`）。
  - 每个区域一行：名称（坐标）＋纯文本产出（"科+2 文+1"，坑 15），自动加入、从候选挑出的另有标注；悬停显示 DMT 的逐项来源。
  - 提醒行（"勿砍树林 (x, y)"，砍掉会少的产出）、得分会变化的已有区域或锁定钉、未放置的区域及原因。
- **打钉 / 撤销**：打的是当前显示的方案，提醒钉一起打；见下节。

任何输入改变都会清空已显示的结果。面板状态（区域状态、数量、权重、开关）在整局游戏中保留。测试钩子见 `SDP_Panel` 全局表（`SetState`、`SetCount`、`SetRemind`、`SelectSolution` 等）。

## 图钉（阶段 6，`Scripts/SDP_Pins.lua`）

- **打钉**：
  - 方案中每个区域一个钉，名称为所属城市的编号（`SDP_City.CityNumbers`：按城市 ID 即建城顺序编号，首都通常为 1），图标为 `ICON_<区域类型>`。DMT 据图标识别出区域 subject（`CreateMapPinSubject`），在钉上显示产出。
  - 流程与 DMT 地图钉弹窗的"确定"一致：建钉 → 设名称与图标 → `Network.BroadcastPlayerInfo()` → 逐个 `LuaEvents.DMT_MapPinAdded(钉)` → 播放音效。
  - 已有钉的格子跳过，不覆盖玩家的钉（约束 7）。
- **只保存钉 ID**：新建钉会让之前取到的钉对象失效，调用失效对象会使游戏崩溃（2026-10-19 实测，AGENTS 坑 21）。所以每次使用都用 `GetMapPinID` 重新取。
- **撤销**：
  - 撤销最近一批（栈，可多次撤销）。按坑 19 的顺序逐个处理：`LuaEvents.DMT_MapPinRemoved(钉)` → `DeleteMapPin` → 广播 → 音效。钉被真正删除，DMT 的记录也一并清除，不会残留成默认钉。
  - 玩家已删除或移动过的钉不再处理。
  - 撤销记录保存在玩家配置的 `SDP_PinBatches` 值里（随存档保存），读档后仍可撤销。每条记录是钉的 ID、坐标、图标和名称；只有这四样都没变的钉才算本模组的，玩家改过或删掉的钉从记录里去掉，以后也不会动。
- **替换本模组之前的钉**（第 18 节第 4 项，面板开关，默认关）：`SDP_Pins.Own(玩家, 城市编号)` 找出本模组为这些城市打、仍未改动的钉；求解请求带 `IgnorePins`，`SDP_City.Scan` 不把它们当锁定钉，`SDP_Overlay.HidePins` 从假想钉层的 DMT 数据副本里去掉它们（真实数据不动，每次安装假想钉层后重新去掉）；打钉时 `SDP_Pins.Place(…, { Replace = … })` 先删旧钉，这一批记下被替换的钉，撤销时删新钉、按原图标原名称重建旧钉。默认关是为了保持"已有的钉都是硬约束"（约束 7）。
- **锁定**：打出的钉就是普通地图钉，下次求解时作为锁定钉参与计算，不会被覆盖。
- **提醒钉**（反馈第 5 条）：图标 `SDP_Pins.REMIND_ICON`（游戏自带的"移除地貌"），名称以城市编号开头（"1 勿砍：圣地 信-1"），所以 `Own` 把它算作本模组为这座城打的钉，"替换"时一起替换。名称里的 `, ; |` 会换成空格（`SafeName`），以免破坏记录格式。DMT 不认这个图标（UNKNOWN 钉），不影响任何加成；我们的城市扫描把它所在格当作锁定格，正好不会在那里放区域。

**实测**（2026-10-19，罗马，种子 20261019）：
- 勾选学院、圣地、剧院广场、商业中心，科学权重 3，求解提升 +12。
- 打钉后，地图上四个钉的 DMT 数值与面板结果行一致：金+3、科+2、文+1、信+2。
- 撤销后四个钉全部消失，地图钉数归零。

## 第 18 节吸收的功能（2026-10-20，离线与游戏内已验证）

- **多城逐城清单与模板**（第 1、2 项，`SDP_PageMulti`）：请求的 `Plans[参与者 Key]` 覆盖共用清单。全帝国限量的区域（市政广场）放在要它的城里参与者顺序最靠前的那座（城址在前，按城市列表从上到下），其余的城记“已达帝国上限”，候选名额加一（第 28 号问题）；所以只写进一座城的清单就等于锁定在这座城。模板 `SDP_Rules.Templates`：对五种产出，列出本玩家有相邻规则产出它的可规划区域（`District_Adjacencies` + `Adjacency_YieldChanges`，按特性排除的行不算），不硬编码。
- **引擎可建格复核**（第 3 项，`SDP_City.EngineRefused`、`SDP_Overlay.EngineRefuses`）：对城市已拥有的格，若游戏引擎为该区域给出了非空的可建格列表（`CityManager.GetOperationTargets`，游戏的放置透镜用的就是它），列表外的格判为不可放（DMT 判可放也一样，结果行原因为"游戏不允许"）。按（城市, 区域）每回合查一次；列表为空（区域未解锁、没有空槽位等）或格子不属于该城时，仍以 DMT 为准。所有合法性判断都经过 `SDP_Overlay.CanPlace` / `Evaluate`，所以求解、热力图、多城、奇观都一致。
- **单城奇观**（第 5 项）：选了奇观时，单城请求转成只有这一座城的 `SDP_Multi` 请求（`Only = { 城市 }`，不含城址钉），沿用多城的奇观逻辑。
- **好位置热力图**（第 6 项，`SDP_Solver.Heat`）：对候选格逐个评估该区域单独放下的加权增益（含它给邻居带来的变化），合法的按最高到最低分四档用预览层着色并标数值。
- **快捷键**（第 8 项，`Config/SDP_Input.xml`）：前端数据库里加输入动作 `SDP_OpenPlanner`，默认 Shift+L，面板监听 `Events.InputActionTriggered`。
- **覆盖范围**（第 7 项，`SDP_Coverage`，离线与游戏内已验证）：覆盖半径从 `GameInfo.Buildings.RegionalRange` 读，按基础区域取最大值（通用建筑和本文明特性的建筑），奇观用自己的半径。被覆盖的对象是玩家的全部城市和本次规划的新城；已建、已打钉的同类区域已覆盖的不再计。`SDP_Search` 的精确评估加上"权重 × 新覆盖的（城市, 类别）个数"，模型的单放值加上单独放下时新覆盖的城数（偏乐观）。多城、单城两个页签都有（单城见 multicity-design.md 19.7），权重 0（默认）时不建模型，结果与没有这项时逐字相同。

## 后续扩展

多城联合规划和奇观规划已在阶段 9–12 实现，见 [multicity-design.md](multicity-design.md)。还没做的：

- **同类区域多个**：如社区。目前请求里同一类型只放一个；放多个需要在求解器里允许重复类型，并在同分比较中对同类区域做对称性去重。
