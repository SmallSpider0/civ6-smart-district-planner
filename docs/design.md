# 设计说明（待编写）

交付物 3。开发时补全以下章节：

## 求解算法结构
<!-- 线性查表排序 → top-N DMT 精评 → 局部搜索兜底；确定性保证 -->

## 目标函数定义
<!-- 分类型加权和、联合总分与锁定钉基线 -->

## 与 DMT 的接缝
<!-- include 列表、overlay 安装/恢复、缓存清理、事件订阅移除 -->

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
