# 设计说明（待编写）

交付物 3。开发时补全以下章节：

## 求解算法结构
<!-- 线性查表排序 → top-N DMT 精评 → 局部搜索兜底；确定性保证 -->

## 目标函数定义
<!-- 分类型加权和、联合总分与锁定钉基线 -->

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

## 界面骨架（阶段 1）

- 一个 InGame 上下文 `UI/SDP_Panel.xml/.lua`（AddUserInterfaces，LoadOrder 14000，依赖 DMT）同时负责启动栏按钮和面板。
- **启动栏按钮**：`Events.LoadScreenClose` 时向 `/InGame/LaunchBar/ButtonStack` 注入 `SDP_LaunchBarItem`（与游戏 `LaunchBarItem` 同形，图标 `ICON_MAP_PIN_DISTRICT`）和一个分隔点，并按游戏 `RealizeBacking()` 的做法调整启动栏底板宽度。热重载（`isReload`）时立即注入；上下文关闭时把这两个控件从启动栏删掉，避免留下失效的重复按钮。
- **面板**：`UIManager:QueuePopup(ContextPtr, PopupPriority.Low)` 打开、`DequeuePopup` 关闭，先查 `IsInPopupQueue`（坑 11）。外框沿用游戏弹窗写法（`DropShadow2` 包 `WindowFrameTitle`，标题 `WindowHeader`，右上角 `CloseButtonSmall`）。Esc 在面板打开时关闭面板，关闭时不拦截。
- **对外接口**：`LuaEvents.SDP_OpenPanel()` / `LuaEvents.SDP_ClosePanel()`。
- **测试钩子**：面板上下文里的全局表 `SDP_Panel`（`Open`/`Close`/`IsOpen`/`HandleInput`/`LaunchButton`），供 `tests/test_panel.lua` 在 `SDP_Panel` Lua 状态里调用。
- **mod 列表文本**：名称、简介、描述同时写在 modinfo `<LocalizedText>`（未启用时也能显示）和 `Text/*.xml`（FrontEndActions，坑 1）。

## 数据层（阶段 2）

两个纯逻辑模块，经 modinfo `ImportFiles` 导入，由 `SDP_Panel.lua` 先 `include("MapTacks")`（游戏本体文件）再 include。所有返回的列表都已排序，不依赖 `pairs()` 顺序。

**`Scripts/SDP_Rules.lua`**（全部从 GameInfo 读，约束 2）
- `Ruleset()`：`GameConfiguration.GetRuleSet()`，即 `RULESET_STANDARD` / `RULESET_EXPANSION_1` / `RULESET_EXPANSION_2`。运河、水坝等只在 GS 的 GameInfo 里存在，不需要按规则集写分支。
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
- `DistrictStatus(scan, districts)`：`BUILT`（本城已建且每城限一个，面板置灰）或 `MAX_PER_PLAYER`（全帝国数量已达上限，如政府广场），用来避免 AMT 那样乱放全局唯一区域。尚未计入别城地图钉上规划的全局唯一区域，这一点在阶段 3 能读到钉的区域类型后补上。

## 后续扩展预留
<!-- 多城联合、奇观求解 -->
