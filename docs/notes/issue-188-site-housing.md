# #188 选城址悬停里的“住房 11”（2026-10-31）

合作者报告：选城址页一个挨着淡水、计划里有港口的城址，悬停写“住房 11”，和游戏不符。

## 这个数是怎么来的

`SDP_Sites.WaterPart`（#55、#56 起）：城址的住房 = 水源住房 + 第一个时代的市中心建筑 + 计划里沿海区域（港口）的建筑。报告里的城址（风云变幻规则）：

| 来源 | 住房 | 规则 |
|---|---|---|
| 水源（淡水） | 5 | `GlobalParameters.CITY_POPULATION_RIVER_LAKE` |
| 粮仓 | 2 | `Buildings.Housing`，远古时代、陶器 |
| 灯塔 | 1 + 2 | `Buildings.Housing` 1；`LIGHTHOUSE_COASTAL_CITY_HOUSING`（`MODIFIER_CITY_OWNER_ADJUST_BUILDING_HOUSING`，`PLOT_IS_ADJACENT_TO_COAST`，Amount 2），只在 `DLC/Expansion2/Data/Expansion2_Buildings.xml` |
| 码头 | 1 | `Buildings.Housing`，电力 |
| 合计 | 11 | |

没有重复计算，也没有翻倍。

## 游戏里实测

2026-10-31，固定测试对局（风云变幻），在 `GameCore_Tuner` 里用 `WorldBuilder.CityManager():Create` 建三座城，`CreateDistrict` 建港口，`GetBuildQueue():CreateIncompleteBuilding(建筑, 格, 100)` 逐个加建筑，在 `InGame` 状态读 `CityGrowth:GetHousing()`（`WorldBuilder.CityManager():CreateBuilding` 传序号时不建，要传类型字符串；这里改用 `CreateIncompleteBuilding`）：

| 城 | 刚建 | +粮仓 | +灯塔 | +船坞 | +码头 |
|---|---|---|---|---|---|
| 河边且挨着海 (62, 6) | 5 | 7 | 8 | 10 | 11 |
| 只挨着湖，港口建在湖上 (32, 7) | 5 | 7 | 8 | 10 | 11 |
| 只挨着海 (37, 6) | 3 | 5 | 6 | 8 | 9 |

船坞自己没有住房（`Buildings.Housing` 0）；+2 在加船坞那一步才出现，看来是灯塔的修正晚一步生效，建齐后的数与上表相同。湖边城市也拿到灯塔的 +2（`plot:IsCoastalLand()` 对湖边格也是 true，与游戏一致）。所以 11 是建好粮仓、灯塔、码头以后的真实住房，新城刚建好只有 5。

## 原因与修改

悬停只写总数“住房 11”，紧跟在“有淡水”下面，读起来像新城一建好就有 11。改成分开写：“住房 11（水源 5，建好后另加：粮仓 +2, 灯塔 +3, 码头 +1）”，建筑名用游戏的（`SDP_UI.TypeName`）。

- `SDP_Land.CenterHousingParts`、`SDP_Land.BuildingHousingParts` 列出给住房的建筑和各自的住房（修正的数量算在它的建筑上）；`CenterHousing`、`BuildingHousing` 改为它们的和，数值不变。
- `SDP_Sites.WaterPart` 把水源那份和建筑列表记在 `Info.HousingWater`、`Info.HousingParts`；城址分不变，所以没有重跑离线对比的选城址集。
- 文本键 `LOC_SDP_SITES_HOUSING_BUILT`、`LOC_SDP_SITES_HOUSING_PART`（中英文）；没有建筑可列时仍用 `LOC_SDP_SITES_HOUSING`。
- 测试：`tests/offline/spec_site_housing.lua`（经面板控件把港口设为必建、求解，核对悬停；旧代码上失败）；`tests/offline/world.lua` 加 `housingBuildings` 选项（粮仓、灯塔住房、码头、风云变幻的灯塔修正）；游戏内 `tests/test_land.lua`（各部分加起来等于总数）、`tests/test_sites.lua`（悬停的住房行）。

## 留给维护者

城址分里码头（现代时代、要电力）也算进去了，而市中心只算第一个时代的建筑（粮仓）。只影响计划里有港口的城址，且多出的 1 点住房多半已过拐点、按半价以下计。是否只算到灯塔，在 Issue 下问了，建议维持现状。

## 只算已研究的建筑（2026-11-02，v1.7.0）

合作者在 Issue 下要求住房按当前科技算，维护者定了：选城址的住房只算玩家已经研究到的建筑（科技和市政都看），码头没研究电力前也不算。上一节“留给维护者”的问题由此作废。

- `SDP_Land.BuildingResearched(playerID, 建筑)` 查 `Buildings.PrereqTech`、`PrereqCivic`；`SDP_Land.SplitResearched` 把住房各部分分成已研究、未研究两组，顺序不变。不传玩家时全部计入（只看规则，`test_land.lua` 的规则检查用）。
- `SDP_Sites.Context` 只把已研究的市中心建筑计入 `Housing.Center`（无水城址的基线也用它）；`WaterPart` 按区域类型和是否沿海缓存港口建筑的两组，未研究的记在 `Info.HousingLater`，不加住房。
- `SDP_Land.ScanHousing`（多城、单城页里城址钉的住房）也只算已研究的市中心建筑。
- 悬停：有已研究和未研究的写“住房 10（水源 5，建好后另加：粮仓 +2, 灯塔 +3；还没研究、未计入：码头 +1）”，只有未研究的写“住房 5（水源 5；还没研究、未计入：粮仓 +2）”。新键 `LOC_SDP_SITES_HOUSING_BUILT_LATER`、`LOC_SDP_SITES_HOUSING_LATER`。
- 城址分会变：开局（没有制陶术、天文导航）挨着海、计划了港口的城址住房分下降。没有重跑离线对比的选城址集。
- 测试：`tests/offline/spec_site_housing.lua` 三种研究状态（全有、只有天文导航、都没有）和城址钉的粮仓，经面板控件求解后核对住房和悬停，旧代码上 3 项失败；`world.lua` 给灯塔、码头加了前置科技，`w:SetTech`、`w:SetCivic` 改玩家的科技。游戏内 `test_land.lua`（`BuildingResearched` 与玩家的科技树一致，未研究电力时码头不计）、`test_sites.lua`（悬停的住房行四种写法）。2026-11-02 macOS 风云变幻：游戏内 12 项通过；固定对局第 1 回合 `CenterHousing(玩家)` = 0、港口建筑 0（不传玩家时 2、4）。
