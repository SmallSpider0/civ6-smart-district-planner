# 设计说明

交付物 3：算法结构、目标函数、与 DMT 的接缝。

> 阶段 8 起单城求解改由 `SDP_Search` + `SDP_Board` 实现（模型集束搜索、增量记忆的 DMT 评估、扰动重建），并新增档位、继续优化和地块部分。下文的模块关系和与 DMT 的接缝仍然适用；求解步骤以 [multicity-design.md](multicity-design.md) 第 4.6、7、15 节为准。

## 模块结构

```
SDP_Panel (UI/SDP_Panel.lua，InGame 上下文，Lua 状态名 SDP_Panel)
 ├─ 启动栏按钮注入、弹窗队列、面板控件、测试钩子
 ├─ SDP_Solver   求解：单项精评 → 穷举 / 线性短名单 → 联合精评 → 局部搜索
 │   ├─ SDP_Overlay  假想摆放层：替换 DMT 的钉读写，调用 DMT 的 CanPlacePin / GetBonusYields
 │   │   └─ DMT（include dmt_yieldcalculator，移除其事件订阅）
 │   ├─ SDP_City     城市扫描：候选格、排除原因、已建区域、锁定钉
 │   └─ SDP_Rules    规则集、可规划区域、区域互惠表（全部读 GameInfo）
 └─ SDP_Pins     打钉与撤销（走 DMT 自己的加钉 / 删钉流程）
```

所有逻辑都在面板这一个 Lua 状态里运行；DMT 在自己的上下文里照常工作，两边只通过地图钉数据和 `LuaEvents.DMT_MapPinAdded/Removed` 交互。

## 目标函数定义

- 单项得分 = Σ 权重[y] × 产出[y]，y 取科学、文化、信仰、金币、生产力五项（`SDP_Rules.YIELDS`），权重 0–3，默认全 1（约束 3）。产出是 DMT `GetBonusYields` 给出的相邻加成，不含政策卡翻倍（约束 4，DMT 本身不算）。
- **联合总分** = 方案里每个新区域的得分 + 每个固定 subject 的得分。固定 subject 是城市四环内本玩家的已建区域（含市中心）和锁定地图钉（`SDP_Overlay.FixedSubjects`），它们的得分会因为新区域相邻而变化。
- **提升（Gain）** = 联合总分 − 基线。基线是不放新区域时固定 subject 的总分。求解器最大化提升；结果里的 `Neighbours` 列出得分变化的固定 subject。

## 求解算法结构（阶段 4，`Scripts/SDP_Solver.lua`）

输入：城市、区域类型列表（每种一个）、权重、是否允许砍伐。
- 先剔除三类区域，记入 `Unplaced`：本文明不能建的（`NOT_AVAILABLE`）、本城已建的（`BUILT`）、全帝国已达上限的（`MAX_PER_PLAYER`）。
- 候选格来自 `SDP_City.Scan`。

1. **单项精评**：DMT 评估每个区域在每个候选格上单独放置时的得分：自身得分，加上它给相邻固定 subject 带来的分数变化。同时得到单独放置时的合法性。没有任何合法格的区域记为 `NO_LEGAL_PLOT`。
2. **小规模直接穷举**：合法摆放组合数不超过 `EXACT_LIMIT`（1200）时，用 DMT 对每个组合做联合精评，保证最优。实测两区域约 460–1000 个组合。
3. **大规模用线性模型**：
   - 布局分 = 各区域单项分之和 + 每对相邻新区域的区域间加成（`SDP_Rules.AdjacencyTable` 双向相加，`TilesRequired` 按比例折算）。
   - 深度优先搜索，区域按请求顺序、格子按 plot index 顺序。上界 = 已得分 + 剩余区域的（最佳单项分 + 全部正区域间加成）。保留线性分最高的 `SHORTLIST`（100）个布局。
   - 对这 100 个布局逐个做 DMT 联合精评，取合法且提升最高者。
4. **局部搜索**：从最佳布局出发，每轮对每个区域试遍其他空闲合法格（其余区域不动），做联合精评，采用提升最大的移动，直到没有严格提升（最多 `MAX_PASSES` 轮）。它兜底线性模型的误差：舍入（坑 16）、新区域移除地貌对邻居的影响、多个新区域共同相邻同一个固定区域时的取整。

**确定性**（约束 6）：
- 只遍历排序后的数组。
- 同分时按各区域所在 plot index 的字典序取小者。
- 预算都是计数（搜索节点数、DMT 评估次数），不用计时。
- 精评结果按布局缓存，局部搜索回到见过的布局时不重复计算。

**性能预算**：`NODE_LIMIT` = 50 万个搜索节点（约 2 微秒/节点，约 1 秒），`EVAL_LIMIT` = 2000 次 DMT 评估（约 0.5 毫秒/次，约 1 秒）。超出预算即停止，`Stats.Truncated` 标记。实测墙钟时间（含 Tuner 往返约 0.03 秒）：

| 区域数 | 方法 | 搜索节点 | DMT 评估 | 耗时 |
|--------|------|----------|----------|------|
| 2（学院+圣地） | 穷举 | — | ~520 | — |
| 3 | 短名单 | ~500 | ~230 | 0.11 s |
| 4 | 短名单 | ~9 千 | ~270 | 0.16–0.19 s |
| 6 | 短名单 | ~7 万 | ~300 | 0.61 s |
| 8 | 短名单 | ~13 万 | ~380 | 0.45–0.51 s |

**验证**（`tests/test_solver*.lua`）：
- 两区域与 DMT 暴力穷举最优一致（全 1 权重与"只看科学"两种权重）。
- 强制走短名单路径时与穷举结果一致。
- 同一请求两次结果完全相同（方案、提升、统计）。
- 锁定钉所在格不会被占用，钉不被挪动。
- 禁止砍伐时方案不落在树林、雨林、沼泽上。
- 3、4、8 个区域分别在 2.5 秒时限内完成。

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

## 界面骨架（阶段 1）

- 一个 InGame 上下文 `UI/SDP_Panel.xml/.lua`（AddUserInterfaces，LoadOrder 14000，依赖 DMT）同时负责启动栏按钮和面板。
- **启动栏按钮**：`Events.LoadScreenClose` 时向 `/InGame/LaunchBar/ButtonStack` 注入 `SDP_LaunchBarItem`（与游戏 `LaunchBarItem` 同形，图标 `ICON_MAP_PIN_DISTRICT`）和一个分隔点，并按游戏 `RealizeBacking()` 的做法调整启动栏底板宽度。热重载（`isReload`）时立即注入；上下文关闭时把这两个控件从启动栏删掉，避免留下失效的重复按钮。
- **面板**：`UIManager:QueuePopup(ContextPtr, PopupPriority.Low)` 打开、`DequeuePopup` 关闭，先查 `IsInPopupQueue`（坑 11）。外框沿用游戏弹窗写法（`DropShadow2` 包 `WindowFrameTitle`，标题 `WindowHeader`，右上角 `CloseButtonSmall`）。Esc 在面板打开时关闭面板，关闭时不拦截。
- **对外接口**：`LuaEvents.SDP_OpenPanel()` / `LuaEvents.SDP_ClosePanel()`。
- **测试钩子**：面板上下文里的全局表 `SDP_Panel`（`Open`/`Close`/`IsOpen`/`HandleInput`/`LaunchButton`），供 `tests/test_panel.lua` 在 `SDP_Panel` Lua 状态里调用。
- **mod 列表文本**：名称、简介、描述同时写在 modinfo `<LocalizedText>`（未启用时也能显示）和 `Text/*.xml`（FrontEndActions，坑 1）。

## 面板（阶段 5，`UI/SDP_Panel.xml/.lua`）

窗口固定在左上（启动栏下方），不铺全屏遮罩，地图大部分仍然可见。自上而下：
- **城市**：下拉框列出本玩家的城市（按城市 ID 排序）。默认选地图上当前选中的本方城市，没有则选首都。
- **要规划的区域**：
  - `PlannableDistricts` 每项一行：复选框、区域图标（`SetIcon("ICON_"..类型, 32)`）、名称，按本地化名称排序。
  - 本城已建或已达帝国上限的区域置灰、不可勾选，右侧注明原因。
  - 求解请求里的区域始终按类型名排序，方案不受勾选顺序影响。
- **特色区域名额提示**：显示已建数、本次勾选数、当前人口上限。超出时只提示（"方案供人口增长后建造"），不阻止。
- **产出权重**：五列，每列一个图标加左右箭头（`ArrowButtonLeft/Right` 样式），取值 0–3。图标用城邦使者加成图标 `ICON_ENVOY_BONUS_{SCIENCE,CULTURE,FAITH,GOLD,PRODUCTION}`：
  - 游戏没有单独的产出图标；`ICON_YIELD_*_1` 是 64 px 图集，缩小后只剩小点（坑 13/14）；
  - 使者图标一套五个齐全；原图为白色，用 `Color` 着成深蓝，才能在浅色窗口上看清。
- **允许砍伐树林、雨林、沼泽**：复选框，默认勾选。
- **求解**：同步调用 `SDP_Solver.Solve`。
- **结果**：
  - 汇总行显示加权提升，悬停显示方法、DMT 评估次数、搜索节点数；预算用尽时追加提示。
  - 每个新区域一行：名称（坐标）＋纯文本产出（"科+2 文+1"，坑 15），悬停显示 DMT 的 tooltip（逐项来源）。
  - 得分会变化的已有区域或锁定钉也各列一行（"已有 学院 (x, y)，加权分 a → b"），未放置的区域列出原因。
- **打钉 / 撤销**：见下节。

任何输入（城市、区域、权重、砍伐开关）改变都会清空已显示的结果，"打钉"只会打出当前显示的方案。面板状态（选择、权重）在整局游戏中保留。测试钩子见 `SDP_Panel` 全局表。

## 图钉（阶段 6，`Scripts/SDP_Pins.lua`）

- **打钉**：
  - 方案中每个区域一个钉，名称为所属城市的编号（`SDP_City.CityNumbers`：按城市 ID 即建城顺序编号，首都通常为 1），图标为 `ICON_<区域类型>`。DMT 据图标识别出区域 subject（`CreateMapPinSubject`），在钉上显示产出。
  - 流程与 DMT 地图钉弹窗的"确定"一致：建钉 → 设名称与图标 → `Network.BroadcastPlayerInfo()` → 逐个 `LuaEvents.DMT_MapPinAdded(钉)` → 播放音效。
  - 已有钉的格子跳过，不覆盖玩家的钉（约束 7）。
- **只保存钉 ID**：新建钉会让之前取到的钉对象失效，调用失效对象会使游戏崩溃（2026-10-19 实测，AGENTS 坑 21）。所以每次使用都用 `GetMapPinID` 重新取。
- **撤销**：
  - 撤销最近一批（栈，可多次撤销）。按坑 19 的顺序逐个处理：`LuaEvents.DMT_MapPinRemoved(钉)` → `DeleteMapPin` → 广播 → 音效。钉被真正删除，DMT 的记录也一并清除，不会残留成默认钉。
  - 玩家已删除或移动过的钉不再处理。
  - 撤销记录只保存在内存中，读档后不能再撤销，此时可用 DMT 的右键删除。
- **锁定**：打出的钉就是普通地图钉，下次求解时作为锁定钉参与计算，不会被覆盖。

**实测**（2026-10-19，罗马，种子 20261019）：
- 勾选学院、圣地、剧院广场、商业中心，科学权重 3，求解提升 +12。
- 打钉后，地图上四个钉的 DMT 数值与面板结果行一致：金+3、科+2、文+1、信+2。
- 撤销后四个钉全部消失，地图钉数归零。

## 后续扩展预留

- **多城联合规划**：
  - `SDP_City.Scan` 和 `SDP_Overlay` 都以玩家与城市为参数，没有"只有一个城市"的假设。
  - 联合规划可以合并多座城市的候选格（同一格只能归一座城市），把各城的已建区域与锁定钉合并成一份固定 subject，再用同一个 `Evaluate` 计算联合总分。
  - 求解器的布局表示（区域 → 候选格下标）可以扩展为（城市, 区域）→ 格。
- **奇观规划**：DMT 已支持 `Type = "WONDER"` 的 subject 及其合法性（`CanPlaceWonderCheckHelper`）。需要做的是把奇观加入可规划列表，并在相邻表里加入 `AdjacentWonder` 一类行（如剧院广场 +2 文化/奇观）。
- **同类区域多个**：如社区。目前请求里同一类型只放一个；放多个需要在求解器里允许重复类型，并在同分比较中对同类区域做对称性去重。
