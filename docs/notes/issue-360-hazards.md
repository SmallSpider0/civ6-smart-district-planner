# #360 区域规划不考虑会受灾的地块（火山、洪水、海平面上升）

2026-11-11 调研。来源：创意工坊玩家问为什么模组无视火山、把区域都放在火山周围。维护者补充：范围扩成“区域规划没考虑的、固定在地块上的灾害风险”，风暴类只说明为什么不算。只调研，没有改 mod 代码；方案等决定。

## 1. 规则（风云变幻规则库 `DebugGameplay.sqlite`，列名按 `pragma table_info`；文本按 Base 与 DLC 的文本 XML）

只有风云变幻有灾害：`RandomEvents`、`RandomEvent_*`、`Features_XP2`、`CoastalLowlands`、`RealismSettings` 都只在 `DLC/Expansion2/Data/Expansion2_RandomEvents.xml` 等风云变幻文件里定义。原版、迭起兴衰里火山（`FEATURE_VOLCANO`）、火山土、维苏威都不存在；乞力马扎罗在 Base 的 `Features.xml`、艾雅法拉在维京 DLC 里，但不喷发。

### 火山

- 地块：`FEATURE_VOLCANO` 只长在 `TERRAIN_*_MOUNTAIN` 上（`Feature_ValidTerrains`），所以 DMT 按山脉地形算相邻（`Adjacency_YieldChanges` 的 `Mountains_Science*`、`Mountain_Faith*`、梯田的 `*MountainAdjacency`）。火山格本身不能放区域（山脉）。
- `Features_XP2.Volcano = 1`：`FEATURE_VOLCANO`、`FEATURE_VESUVIUS`、`FEATURE_KILIMANJARO`、`FEATURE_EYJAFJALLAJOKULL`。`ValidDistrictPlacement = 1` 的只有火山土和三种泛滥平原：区域可以放上去且保留地貌（DMT `WillDistrictRemoveFeature` / `IsFeatureValidForPlacement`）。
- 活跃比例 `RealismSettings.PercentVolcanoesActive`：最小 45、轻微 60、中等（默认，`GAME_REALISM` 默认值 2）70、严重 80、超现实 95；`ExtraRange` 只在严重、超现实为真。百科（`LOC_PEDIA_CONCEPTS_PAGE_ENVIRONMENTAL_EFFECTS_CHAPTER_VOLCANOES_*`）：火山有休眠、活跃、喷发三态，休眠的和山脉一样，可能变成活跃；喷发损坏周围格；奇观不受影响。维苏威的说明：“It is always active.”
- 喷发事件（`RandomEvents.EffectOperatorType = VOLCANO`；自然奇观的是 `FEATURE` + `NaturalWonder`）与 `RandomEvent_Damages`（`Percentage` 是每格的概率；`ExtraRangePercentage` 推断为严重、超现实下多波及一圈的概率，未在游戏内核实）：

| 事件 | 区域被掠夺 | 建筑被掠夺 | 改良 | 城市中心掉人口 | 多一圈 |
|---|---|---|---|---|---|
| 温和性喷发 `VOLCANO_GENTLE` | — | 100 | 掠夺 100 | — | 0 |
| 灾难性喷发 `VOLCANO_CATASTROPHIC` | 75 | 100 | 摧毁 75、掠夺 100 | 20 | 0 |
| 毁灭性喷发 `VOLCANO_MEGACOLOSSAL` | 80 | 100 | 摧毁 80、掠夺 100 | 35 | 30 |
| 乞力马扎罗 温和 / 灾难 | — / 80 | 100 | 掠夺 / 摧毁 80 | — / 20 | 0 / 50 |
| 艾雅法拉 灾难 / 毁灭 | 75 / 80 | 100 | 摧毁 75 / 80 | 30 / 40 | 0 / 40 |
| 维苏威 毁灭 | 80 | 100 | 摧毁 80 | 100 | 50 |

  没有 `DISTRICT_DESTROYED`：区域只会被掠夺，修好后照旧（相邻加成来自火山格这座“山”，喷发后它仍是山）。`RandomEvent_PillagedDistricts` 对火山没有行（不限区域类型）。
- 次数 `RandomEvent_Frequencies.OccurrencesPerGame`（中等：温和 4、灾难 2.5、毁灭 1.5；维苏威 7）。表里看不出是每座火山还是全图，没有核实；方案不依赖它。
- 好处：`RandomEvent_Yields` 喷发后给周围格加粮食、生产力（较大的还有科技，维苏威加文化），并可能变成火山土（`ReplaceFeature`）。区域占的格用不上这些产出。
- 防护：`DynamicModifiers` 里与灾害有关的只有 `MODIFIER_PLAYER_ADJUST_AVOID_RANDOM_EVENT`（埃及古尼罗河，只对三种洪水）、无单位伤害类（暴风雪、飓风）和梁的“加固材料”（`GOVERNOR_PROMOTION_REINFORCED_INFRASTRUCTURE`，`MODIFIER_GOVERNOR_ADJUST_PREVENET_STRUCTURAL_DAMAGE`：本城改良、建筑、区域不受环境效应损坏）。没有科技、建筑、政策防喷发。

### 河流洪水

- 只淹泛滥平原（`EffectOperatorType = FLOODPLAIN`；游戏的警告用 `RiverManager.CanBeFlooded(plot)`）。原版、迭起兴衰里泛滥平原不能放区域（EP 源码注释 `ep_rules.lua` 约 404 行，与 `Features_XP2` 只在风云变幻有一致）。
- 中型洪水：建筑、改良全部掠夺；大型：区域 50%、改良摧毁 50%、人口 15%；千年难遇：区域 80%、人口 25%。没有区域摧毁。
- 防护：`Districts_XP2.PreventsFloods`（堤坝，`OnePerRiver`）；`Buildings_XP2.PreventsFloods`（大浴场：所在河流的泛滥平原免疫）；埃及特性 `TRAIT_AVOID_*_FLOOD`；梁的加固材料。堤坝、大浴场让洪水的产出奖励减半（`MitigatedYieldReduction = 50`）。

### 海平面上升（海岸低地）

- `CoastalLowlands`：1 米在 `SEA_LEVEL_RISE2` 淹、`RISE4` 沉没；2 米 `RISE3` / `RISE6`；3 米 `RISE5` / `RISE7`。上升由全世界二氧化碳累积触发（`ClimateChangePoints` 2–8）。
- 被淹（flooded）的格不能放区域（坑 41，`SDP_City` 已排除）。已有区域：百科说可能摧毁淹没格上的改良和区域、城市中心掉人口；沉没的格变成海，永远回不来。规则表没有逐项概率。
- 防护：拦洪坝（`BUILDING_FLOOD_BARRIER`，`Buildings_XP2.BlocksCoastalFlooding`，电脑科技，建在城市中心）保护本城全部海岸低地；淹了再建也完全修复；沉没的修不回来。造价随本城低地格数和海平面上涨（`CostMultiplierPerTile`、`CostMultiplierPerSeaLevel`）。

### 其他

- 核事故（`NUCLEAR_ACCIDENT_*`）：核电站（工业区的建筑）年数越大越容易出事，“重启核反应堆”项目清零（`LOC_PROJECT_RECOMMISSION_REACTOR_DESCRIPTION`）；核芯融毁会摧毁建筑（唯一的 `BUILDING_DESTROYED`）、区域 100% 掠夺并留下辐射。波及范围不在规则表（`Hexes = 0`），由引擎决定。风险来自玩家以后是否建核电站，且能完全防住；本模组不规划建筑。不纳入。
- 风暴（暴风雪、沙尘暴、龙卷风、飓风，`EffectOperatorType = STORM`）：随机生成在对应地形（`RandomEvent_Terrains`），移动 3 回合（`Duration`），会掠夺建筑和改良。同一座城附近哪格都可能被扫到，摆法避不开。不纳入。
- 干旱（`DROUGHT_*`）：只掠夺、摧毁农场、牧场、营地、种植园等改良（`RandomEvent_PillagedImprovements`），不碰区域。不纳入。
- 末日模式的超级灾害（太阳耀斑等）是游戏模式内容，随机选目标，不纳入。

## 2. 游戏和 DMT、本模组现在怎么做

- 游戏自己：`DLC/Expansion2/UI/Additions/SettlerWarningIconManager.lua` 在开拓者视图（`Hex_Coloring_Water_Availablity`）和放区域时的相邻加成视图（`Adjacency_Bonus_Districts`）给三种格画警告图标：`RiverManager.CanBeFlooded`（`LOC_FLOOD_WARNING_ICON_TOOLTIP`“此处易受洪水侵袭。”）、`MapFeatureManager.CanSufferEruption`（`LOC_VOLCANO_WARNING_ICON_TOOLTIP`“此地区易遭受附近火山喷发袭击。”）、`TerrainManager.GetCoastalLowlandType ~= -1` 且 `not TerrainManager.IsProtected`（低地几米的说明）。
- DMT：不区分火山（火山算山脉），不查灾害；`GetPlotTypes` 里“TODO: Add pillage check”，被掠夺的区域按没掠夺算。
- 本模组：区域规划不看灾害；`SDP_City` 只排除已淹没、沉没的海岸低地（`FLOODED`）；选城址页 `SDP_Sites.lua` 约 475 行看到泛滥平原或火山土就记 `Disaster`，`SDP_PageSites.lua` 414 行提示 `LOC_SDP_SITES_DISASTER`（不看火山本身、海岸低地、堤坝）。
- 其他规划模组（`reference/`）：AMT 在一个布局分里给泛滥平原、火山（只按地貌名）各 −1.5；EP、DWP 不看灾害。

## 3. 运行时能读出的（游戏 UI 源码里有先例的接口）

| 要知道的 | 接口 | 先例 |
|---|---|---|
| 会被火山喷发波及 | `MapFeatureManager.CanSufferEruption(plot)` | SettlerWarningIconManager |
| 是火山、活跃、正在喷发 | `MapFeatureManager.IsVolcano / IsActiveVolcano / IsVolcanoErupting(plot)` | PlotTooltip_Expansion2、MapSearchPanel_Expansion2 |
| 会被洪水淹 | `RiverManager.CanBeFlooded(plot)`；河流 `GetRiverForFloodplain`、`GetFloodplainPlots` | SettlerWarningIconManager、NaturalDisasterPopup（DMT 也用） |
| 海岸低地几米、已受保护、已淹、已沉没 | `TerrainManager.GetCoastalLowlandType / IsProtected / IsFlooded / IsSubmerged(plot)` | SettlerWarningIconManager、PlotTooltip_Expansion2 |
| 堤坝、大浴场、埃及特性、梁 | `Districts_XP2.PreventsFloods`、`Buildings_XP2.PreventsFloods`、`TraitModifiers` 里 `MODIFIER_PLAYER_ADJUST_AVOID_RANDOM_EVENT`；城市的总督 | 规则表 |

都要先判断接口存在（其他规则集没有 `MapFeatureManager.CanSufferEruption` 等）。待游戏内核实：`CanSufferEruption` 对休眠火山周围的格是否也为真；“多一圈”是否就是 `ExtraRangePercentage`。

## 4. 离线实验

`tests/compare/cmp_sdp.lua` 加了实验变体 `STANDARD_HAZ<字母>`（`KeepHazardsFree`）：把危险格当作已淹没的低地，`SDP_City` 就不往上放区域。V = 与火山（普通火山或三座火山奇观）相邻；F = 泛滥平原；A = 1 米海岸低地；L = 任意高度的海岸低地。只用不带地块分的 `STANDARD`（`_LAND` 也读淹没状态，会混进别的影响）；有奇观的场景里奇观也被挡在这些格外，实际游戏里奇观不受灾害，所以略高估代价。场景是从真实存档导出的 R、RP 组（风云变幻 61 个，迭起兴衰 5 个不受影响）。`tests/compare/hazard360.py` 汇总。

命令（第二台机器，368 秒）：

```
python3 -I tools/remote.py run haz360 -- node tools/compare.mjs -s '^R[SMCP][0-9]' -p sdp \
  --only sdp:STANDARD,sdp:STANDARD_HAZV,sdp:STANDARD_HAZF,sdp:STANDARD_HAZA,sdp:STANDARD_HAZL,sdp:STANDARD_HAZVFA \
  --add sdp:STANDARD_HAZV,sdp:STANDARD_HAZF,sdp:STANDARD_HAZA,sdp:STANDARD_HAZL,sdp:STANDARD_HAZVFA \
  --out logs/remote/haz360.jsonl
python3 -I tests/compare/hazard360.py logs/remote/haz360.jsonl
```

现在的方案（`STANDARD`，254 个区域）落在危险格上的：与火山相邻 1 个（1 个场景）、泛滥平原 21 个（10 个场景）、1 米低地 0 个、任意低地 10 个（9 个场景）。两套独立的判断（Lua 变体与 Python 汇总）对“与火山相邻”给出同一个场景。

| 变体 | 裁判总加成 | 放下的区域 | 放不下的 | 变了的场景与其中的加成变化 |
|---|---|---|---|---|
| STANDARD | 1030 | 254 | 4 | — |
| 避开火山旁 V | 1029 | 254 | 4 | 1 个场景，−1（9→8，RP27 罗马） |
| 避开泛滥平原 F | 982 | 248 | 10 | 9 个，−48（−24.6%） |
| 避开 1 米低地 A | 1030 | 254 | 4 | 0 |
| 避开全部低地 L | 1004 | 251 | 7 | 9 个，−26（−12.4%） |
| 三者 VFA | 981 | 248 | 10 | 10 个，−49（−24.0%） |

- 泛滥平原、低地的变化集中在荷兰（大陆图）几座沿河沿海的城，和日本、波兰的几座；RC12/RS12、RC14/RS14 是同一座城的多城与单城场景。
- 硬排除会让区域放不下：避开泛滥平原时 RC14、RS14、RM05 各少放 2 个（工业区、娱乐中心、剧院广场），城里能放的格几乎都是泛滥平原或低地。所以开关应是“能避就避”：没有安全格时仍放在危险格上并提示，而不是放不下。
- 放下数量不变的场景里，避开泛滥平原少 1–6 点（RP17 波兰 10→4），避开低地少 1–4 点。
- 结论：火山旁在这些真实场景里很少被用到，避开几乎没代价；泛滥平原代价最大（河边的学院、商业中心、工业区常常最好的格就在泛滥平原上）。

## 5. 方案（写在 Issue 评论里，等决定）

见 Issue 评论。开关名按建议定为“避开灾害地块”（Avoid Disaster Tiles）。
