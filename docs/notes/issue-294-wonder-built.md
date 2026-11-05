# #294 奇观“已建成”的判断

## 定下的

维护者 2026-11-05“都按推荐来”：不再按“地图上见过”判断奇观已建成，改成本方还能不能建。

## 做法和原因

`SDP_Wonders.Built` 只认两种“已建成”：

1. 本方城市里有的（照旧：作为固定邻居，不再规划）；
2. 全世界已建成的数量到了规则上限（`Buildings.MaxWorldInstances`，`-1` 为不限）的，不管在哪、见没见过；只数建成的，在建的不算。

**数法：数每个玩家的城市，不数地图。** 第一版按地块数（`plot:GetWonderType()`），2026-11-06 夜间游戏内测试失败：面板所在的 UI 状态里，本方没揭示的格子读出来没有奇观（`GetWonderType` 为 -1、`IsWonderComplete` 为假，游戏核心状态里是 60 和真）。同一状态里别的玩家（没遇见过的也一样）的城市和城里的建筑照样读得到：`PlayerManager.GetAliveIDs()` 的每个玩家、每座城的 `city:GetBuildings():HasBuilding(奇观)`。在建的奇观（`CreateIncompleteBuilding` 进度 50%）`HasBuilding` 为假，所以只数建成的。

“每人一座”的国家奇观（模组加的，`MaxWorldInstances = -1`、`MaxPlayerInstances = 1`）只看本方城市。原版奇观全部是 `MaxWorldInstances = 1`、`MaxPlayerInstances = -1`（2026-11-05 在 `DebugGameplay.sqlite` 查：没有别的取值；列名按坑 32 用 `pragma table_info` 核对）。

**为什么不用建造菜单的 `BuildQueue:CanProduce`**：它按城判断，没研究科技、本城没有合适的格（沿海、河边）也给“不能建”；本模组从来是提前规划（科技没到也规划，城还没有合适的格时别的城也可以建），只该因为“别处建成了”去掉。游戏内实测（2026-11-06，首都、开局科技）：别处建成的阿尔罕布拉 `CanProduce(hash, false, true)` 返回假、结果表为 nil；没建的大浴场、金字塔、巨石阵等返回假、结果表里有失败原因（“没有合适的位置进行建造。”等）。能分出来，但靠“没有原因”这种隐含的约定，不如数城市直接。

## 测试

- 离线：`spec_multi.lua`“a world wonder built anywhere is built, a national one only in our cities (issue 294)”，在 `main` 和第一版上都失败（别的玩家城里建成、地图上读不到的巨石阵仍可规划）。假世界的奇观行默认 `MaxWorldInstances = 1`，`nationalWonder = true` 加一行国家奇观；假世界和离线对比的模拟引擎都加了 `PlayerManager.GetAliveIDs`。
- 离线对比：开发集里要规划奇观的场景（W、WA 等生成场景）只在本方首都放了已建奇观，真实存档场景不规划奇观，所以方案不变，没有重跑。
- 游戏内：`tests/test_wonder_built.lua`（另一文明在本方没去过的地方建成一座世界奇观 → 不规划；没人建的奇观在科技之前照样规划）2026-11-06 两项都过；`test_multi`、`test_ui`、`test_features`、`test_settings`、`test_support` 也过（1 项需多城存档的跳过）。夹具的拆除脚本先读奇观类型再移除（移除后格子读不到类型，原来报 nil）。
