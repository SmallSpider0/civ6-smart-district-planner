# #361 文明、领袖特性给地块的产出

2026-11-20。调研结论和方案在 Issue 的调研评论里（方案 A，客观问题，不等决定）。

## 游戏怎么给

- 特性里改地块产出的是 `EFFECT_ADJUST_PLOT_YIELD`，作用对象 `COLLECTION_PLAYER_PLOT_YIELDS`：只给本方拥有的格。
- **游戏内实测**（2026-11-20，XZC，风云变幻，`game.py newgame --leader LEADER_PETER_GREAT`，首都 (18, 38)）：首都 4 环内 24 个没有资源、改良、区域的陆地格，每格 6 项产出都等于规则库的地形、地貌产出（`Terrain_YieldChanges`、`Feature_YieldChanges`）加上本方的格的特性产出：本方的冻土（如 (19, 38)、(17, 39) 冻土森林）多 +1 生产力 +1 信仰值，领土外的冻土丘陵 (15, 39) 没有。即领土外格子的 `GetYield` 不含特性产出，Issue 里待确认的一点成立。
- 用 `WorldBuilder.CityManager():SetPlotOwner` 把格子给首都后，当回合 `GetYield` 不加特性产出（核心和界面状态都不加，等几秒也不加）；在这格上用 `ImprovementBuilder` 建矿山，界面状态等一帧后有矿山的 +1，仍没有特性的 +1 信仰。所以游戏内测试不改归属，按地图现状对照规则库（`tests/test_traits.lua`）。

## 做法

`SDP_Land`：

- `TraitRules(playerID)`：读玩家（`MapTacks.PlayerTraits`）的特性修正，按 ModifierId 排序。`EFFECT_ADJUST_PLOT_YIELD` + `COLLECTION_PLAYER_PLOT_YIELDS` 的记下产出（`YieldType`、`Amount` 逗号分隔、去空格）和条件；`EFFECT_ADJUST_IMPROVEMENT_VALID_TERRAIN`（加拿大冻土农场）的条件只看玩家时记成改良的额外有效地形。
- 条件解析（`ParseSet`）：TEST_ALL / TEST_ANY、取反、嵌套的 `REQUIREMENT_REQUIREMENTSET_IS_MET`；地块的地形、地貌、改良、有无改良、资源类别、资源可见、是山脉；玩家的科技、市政、游戏时代（`Game.GetEras():GetCurrentEra()`）在建上下文时定下。别的需求类型（魅力、“挨着某区域”等）整条修正不算，不会算多。“挨着某区域”的（高棉）由 `SDP_Improve` 按规划的区域算，这里不算，不重复。
- `Parts`：领土外的格（`GetOwner() ~= playerID`）把当前状态满足的特性产出加进“现在的产出”；本方的格 `GetYield` 已含。
- `PlotValues`、`ImprovementOptions`：每种假想状态（保留或砍掉地貌、保留或采收资源、建哪种改良或不建）按条件算特性产出，减去当前状态的那份（不重复）。`ImprovementOptions` 多了 `Gain`（改良本身加特性的变化，相对同样处理但不建改良），`AssumedImprovement` 用它判断建不建。
- `ValidImprovements` 加上特性给的有效地形。
- 印加的山脉：山脉本来就在城市的候选格和可耕作格里（`SDP_City` 不排除山脉，DMT 不让放区域），只缺领土外山脉的 +2 生产力，`REQUIREMENT_PLOT_IS_MOUNTAIN` 补上了，不用改 `Workable`。
- 改良钉的产出（`SDP_Improve` `Model:Entry`）加 `TraitChange`；城市中心钉的生产力估计（`SDP_Multi.Production`）加领土外格的特性产出。
- 没有这类特性的文明：`TraitOn` 为假，所有路径不变（离线测试全过，方案不变）。

不在本 Issue：万神殿、信仰、政策卡给地块的产出；印加梯田（特色改良，通用改良表本就不收）。

## 测试

- 离线 `tests/offline/spec_traits.lua`：假世界的测试特性（`spec.traitPlotYields`，世界的 `GetYield` 只给本方的格加，模仿游戏）：冻土、矿山（一条修正两项产出带空格）、未改良森林、冻土农场 + 市政条件、未知需求类型；城址分、改良钉产出、城市中心钉生产力。7 项在旧代码上都失败。
- 游戏内 `tests/test_traits.lua`：见上，按玩家自己的修正判断，不写死文明。俄罗斯（风云变幻）：24 格，本方 1 格、领土外 2 格有特性产出，通过；同时跑 test_land、test_sites、test_improve、test_pillaged、test_multi，28 项全过。印加（`LEADER_PACHACUTI`，风云变幻）：30 格，本方 1 格、领土外 6 格有特性产出（山脉），test_traits、test_land、test_sites 15 项全过。马里（`LEADER_MANSA_MUSA`）：特性只在矿山上，地图上没有矿山，test_traits、test_land、test_sites、test_improve 18 项全过（矿山那部分只有离线测试）。罗马、原版规则集：42 格都等于规则库的产出，test_traits、test_land 4 项全过。
