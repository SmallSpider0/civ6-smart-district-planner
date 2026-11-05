# #294 奇观“已建成”的判断

## 定下的

维护者 2026-11-05“都按推荐来”：不再按“地图上见过”判断奇观已建成，改成本方还能不能建。

## 做法和原因

`SDP_Wonders.Built` 只认两种“已建成”：

1. 本方城市里有的（照旧：作为固定邻居，不再规划）；
2. 全世界已建成的数量到了规则上限（`Buildings.MaxWorldInstances`，`-1` 为不限）的，不管在哪、见没见过；只数建成的（`plot:IsWonderComplete()`），在建的不算。

“每人一座”的国家奇观（模组加的，`MaxWorldInstances = -1`、`MaxPlayerInstances = 1`）只看本方城市。原版奇观全部是 `MaxWorldInstances = 1`、`MaxPlayerInstances = -1`（2026-11-05 在 `DebugGameplay.sqlite` 查：没有别的取值；列名按坑 32 用 `pragma table_info` 核对）。

**为什么不用建造菜单的 `BuildQueue:CanProduce`**：它按城判断，没研究科技、本城没有合适的格（沿海、河边）也给“不能建”；本模组从来是提前规划（科技没到也规划，城还没有合适的格时别的城也可以建），只该因为“别处建成了”去掉。`CanProduce` 的结果表在白天无法进游戏核对它能否分出原因，规则列加全图计数是客观可查的。游戏内测试 `tests/test_wonder_built.lua` 顺带把 `CanProduce` 的返回打印出来留档。

## 测试

- 离线：`spec_multi.lua`“a world wonder built anywhere is built, a national one only in our cities (issue 294)”，在旧代码上失败（没见过的巨石阵仍可规划、看到的国家奇观被记成已建）。假世界的奇观行默认 `MaxWorldInstances = 1`，`nationalWonder = true` 加一行国家奇观，`spec.wonders` 第 4 项为 `false` 表示在建。
- 离线对比：开发集里要规划奇观的场景（W、WA 等生成场景）只在本方首都放了已建奇观，真实存档场景不规划奇观，所以方案不变，没有重跑。
- 游戏内：`tests/test_wonder_built.lua`（另一文明在本方没去过的地方建成一座世界奇观 → 不规划；没人建的奇观在科技之前照样规划），进夜间队列。
