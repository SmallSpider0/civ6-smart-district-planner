# #379 支持把城市工作范围扩到 3 环以外的模组

状态：结论"暂不做"（2026-11-25，维护者倾向 + 离线基准支持）。不进里程碑，Issue 打 `later`。

## 1. 这类模组到底改了什么

| 模组 | 改法 | 需要 DLL | 外环能建区域/奇观 |
|---|---|---|---|
| [Workable 4th Ring](https://steamcommunity.com/sharedfiles/filedetails/?id=3220078106)（3220078106） | 两条 SQL：`UPDATE GlobalParameters SET Value='4' WHERE Name='CITY_MAX_BUY_PLOT_RANGE'` + 把 `GameCores` 三行指向自带 `GameCore_*_Mod` DLL | **是**（整份 GameCore 替换，仅 Windows） | **能**（玩家实测 + 依赖它的模组作者说明） |
| [CypRyan's Workable Outer Rings](https://steamcommunity.com/sharedfiles/filedetails/?id=3208124358)（3208124358，"拓荒驻地"） | 新增区域 + 专家槽模拟外环产出 | 否（推断） | **不能**：页面原文 "Wonders or districts cannot be placed in the outer rings" |
| [Wide Cities: Six-Ring Territory](https://steamcommunity.com/workshop/filedetails/?id=3780476835)（3780476835） | 改参数 + 换 GameCore DLL，6 环 | 是（页面自述"不能与其他替换 GameCore DLL 的模组同时使用"） | 未查到 |

机制（CivFanatics LeeS，2016/2017/2021 三次实测与结论）：原版"工作格 / 买地 / 区域与奇观距离"是 DLL 里**同一个硬编码常量 3**；`CITY_MAX_BUY_PLOT_RANGE` 引擎基本不读（改成 4/5 后买不到、也上不了人口）；`Districts` 表 40 列里没有任何距离字段。Lua 侧也没有"工作半径"API（`City` 只有 `GetOwnedPlots`/`GetPlot`，`CityPlots` 只有 `GetPurchasedPlots`/`GetWorkingCity`；`GetBuyPlotDistance` 在 Civ6 不存在）。

**对实现的两个含义**：
1. "参数 > 3"不能当开关：假四环模组参数仍 3，只改 SQL 的坏模组参数会撒谎；唯一可信信号是引擎可建格列表的最大环，而它只覆盖"已解锁 + 城市已拥有"的格，是下界。
2. 真四环模组下区域**也能**放到第 4 环，所以"只扩地块、区域仍三环"是半个功能。

## 2. 耗时与质量：离线基准（`tests/offline/bench_radius.lua`）

同一世界、同一请求，只把 `SDP_City.RADIUS` 设成 3 与 4（所有读取点都是运行时读这个字段）。单位 = `SDP_Tiers` 工作单位（1 次 DMT 调用 = 1 单位），不随本机速度变；秒是 fengari 的（约为游戏 20 倍），只看比值。假 DMT 不查三环，所以 r=4 的方案在游戏里不合法：这里量的是工作量，不是质量。

| 场景 | 候选格 / 工作格 | 单位 | 单位比 | fengari 秒比 | 备注 |
|---|---|---|---|---|---|
| `SDP_Land.ForScan`（单城） | 35→57 / 36→60 | 每格调用 36→60，每格成本 ×0.97 | — | ×1.65 | 地块模型成本与格数成正比 |
| `SDP_Sites.Coarse`（每候选城址） | 候选城址 206→206 | — | — | 每址 15.2ms→17.9ms（×1.18） | 选城址页最贵的一段 |
| 单城 k4 标准 | 35→57 | 2520→3526 | ×1.40 | ×1.01 | 增益 9.00→9.00 |
| 单城 k6 标准 | 同上 | 3772→5466 | ×1.45 | ×1.24 | 13.00→13.00 |
| 单城 k8 标准 | 同上 | 6087→7882 | ×1.29 | ×1.12 | 20.00→20.00 |
| 多城 3 城 FAST | 每城同上 | 12071→18565 | ×1.54 | ×1.88 | 增益 40→41 |
| 多城 4 城 FAST | 每城同上 | 16824→21599 | ×1.28 | ×1.60 | 增益 52→53；**r=4 撞上限被截断，r=3 没有** |

命令：`node tools/offline_tests.mjs -v tests/offline/bench_radius.lua`（单 seed 11，约 4 分钟）。

## 3. 判定（门槛在动手前定好）

全扩（区域也到 4 环）：
- **G1 质量**：后期多城标准档 `Tries` ≤ 61%（现 71%）→ 直接破；基准里 4 城 FAST 在 r=4 就已 `Truncated`，即方案会静默变差。
- **G3 总时长**：多城 +60–88%（vm）→ 破（门槛 ≤25%）。
- 结论：**不做**。与维护者"更倾向于不扩"一致。

只扩地块（区域仍三环）：
- 成本确实小：land model ×1.65（绝对值约 0.006s→0.010s fengari/城，折合游戏约零点几毫秒），选城址页 Coarse 每址 +18%。
- 但收益是半个：真四环模组下区域也能放 4 环，只算地块会让"这格产出"和"能不能建"不一致；而半径又读不到可靠值（见第 1 节）。
- 结论：**也不做**。若将来只想要地块分，它可独立成一个小改动，前提是先有可靠的半径判定（引擎探针）。

## 4. 将来若要做，先解决

1. **探针**（2026-11-25 已测，`tests/bench/probe_radius.lua`，装 Workable 4th Ring、首都拥有 1–4 环、全部科技）：`GlobalParameters.CITY_MAX_BUY_PLOT_RANGE` = **4**（不装该模组时 = 3，同一台机器实测）；引擎给该校区的可建格 27 个里 **10 个在第 4 环**，最大环 = **4**（样本 `20,34 19,34 18,34 17,34 16,34 15,35 15,36 14,37 14,38 14,39`）。即：**该模组下区域确实能建到第 4 环**，"只扩地块、区域仍三环"是半个功能这一判断成立。注意第 4 环地块是 `WorldBuilder.CityManager():SetPlotOwner` 给的，未验证"金币买第 4 环"这条路；`CITY_MAX_DISTRICT_RANGE` 这个参数不存在。
2. **预算与束宽**：`SDP_Tiers` 的 `TryLimit`/`CallLimit` 现按三环标定；4 环下 4 城 FAST 已截断，要先按实测调预算或缩束宽，并复量质量。
3. **ETA**：`SDP_Multi.lua` 的 `n = 30`（"每城可用格"）硬编码，4 环会低估 1.65 倍，进度与"预计 X 秒"失准；`SDP_SiteSolver.EstimateUnits` 不含 n。
4. **记轻的记账**：`SDP_Sites.Coarse` 只记 `Extra(5)` 单位，实测随格数增长，4 环下更容易打穿单帧配额。

## 5. 出处

- 工坊页与 FAQ：3220078106、3208124358、3780476835、3641900716（"遷移區域和奇觀"作者说明区域可到"能上人口的环"）。
- 规则讨论：CivFanatics [City Workable Plot Range](https://forums.civfanatics.com/threads/city-workable-plot-range.603963/)（2016）、[Increase Workable Tile Radius](https://forums.civfanatics.com/threads/increase-workable-tile-radius.611402/)（2017–2024）、[Larger active city distance](https://forums.civfanatics.com/threads/larger-active-city-distance-and-adding-population.667487/)（2021，LeeS 的硬编码结论）。
- 本机规则库（只读）：`GlobalParameters.CITY_MAX_BUY_PLOT_RANGE = 3`、`Districts` 40 列无距离字段、`DebugConfiguration.sqlite` 的 `GameCores` 行。
- 代码：`SDP_City.RADIUS`（`SDP_City.lua:9`）的 24 处读取点、`SDP_Land.Workable`/`ForScan`、`SDP_Sites.Coarse`、`SDP_Tiers`。
