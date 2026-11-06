# #297 密铺：城数一样时先比挤不挤（2026-11-06）

Issue：DracoYus 问选城址怎么算（[#297](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/297)），其中一问是“城数少、地方大、每套都放得满时，怎么判断哪个更密”。代理按代码回答：不判断，城数一样只比总分，而总分偏向松（共用的格少），挪位常把城往外挪 1～2 格。建议城数一样先比挤不挤、再比总分，挪位不许变松；合作者 2026-11-06 回复“遵循建议”（[评论](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/297#issuecomment-6681366641)）。住房一问的调研和实验见 [issue-297-sites.md](issue-297-sites.md)。

## 1. 做法

见 [docs/multicity-design.md](../multicity-design.md) 3.5 的“密铺”一段。代码在 `SDP_SiteSolver`：

- `SDP_SiteSolver.Spread(sites, anchors)`：本方城市和城市中心钉（`Session.Anchors`）算作已连通，用 Prim 把城址一个个连进来，每次连离已连部分最近的那个，连线长度（`Map.GetPlotDistance`，和间距、D 同一种距离）相加。没有本方城市时第一座不计。
- `Earlier`：城数 → `Spread` 小 → 总分 → 格子编号；只在两边都有 `Spread` 时比它，平时模式（`Combine`）的组合没有这一项，排序不变。
- `Packings`：排布按城数 → `Spread` → 粗评分合计 → 编号排序，所以“最好那套排布”（它的城址周围 2 格内也精评）是最挤的那套。
- `DenseRun` 的挪位：`Better(entry, cur)`，城数一样时 `Spread` 变小，或相同而总分高 1e-9 以上才换。`Spread` 是整数，所以挪位按（`Spread`，总分）严格变好，不会来回换。
- 补位 `Grow`：每次在还放得下、连得回去的精评城址里取离已有城市、钉和已选城址最近的，同距离取精评分高的（`Pool` 的次序），直到放满。以前按精评分从高到低补，会补进远处的城址。
- 结果的每套方案带 `Spread`（只有密铺）。

### 为什么用生成树，而不是“每座城到最近的城或城址的距离相加”

方案原话是“每座新城离它最近的城或城址有几格，加起来越小越挤”。照字面算，两座新城可以互相当“最近”：首都外 5 格放一座、它外侧 4 格再放一座，两座各自最近都是 4 格，和两座都贴着首都 4 格一样“挤”，于是挪位可以把一对新城一起往外挪 1 格而不算变松。生成树里每座城只连一次，连到它之前已经连进来的城或城址，所以往外挪的那一段会算进去。城数少、地方宽时两种算法的最好值都是 4K（每座城离最近的 4 格）；差别只在“一样挤”的判定。这是距离怎么算的技术选择（合作者让代理按代码定），在 Issue 下说明了。

### 平局

城数一样、`Spread` 一样时比总分，再一样比城址编号序列（原来的次级键）。补位同距离按精评分，再按 `Pool` 次序（精评分、编号）。

## 2. 离线对比

12 个 `C` 场景（中期首都）和 48 个 `ZS` 场景（城址分校准用的场景），标准档，面板默认的区域格；改前在 `origin/main`（e64e71b）的临时工作树里跑，`cmp_sdp.lua` 两边都是本 PR 的版本（它新记 `sdpSpread`，由对比程序自己按同样的生成树算，旧代码也有这个数）。机器由 `remote.py` 选：

```
python3 -I tools/remote.py run i297-after-k3 -- node tools/compare.mjs -s '^(C[0-9]|ZS)' -p sdp --add sdp:STANDARD_DENSE_K3_GRID,sdp:STANDARD_K3_GRID --only sdp:STANDARD_DENSE_K3_GRID,sdp:STANDARD_K3_GRID -j 6 --out logs/remote/i297-after-k3.jsonl
python3 -I tools/remote.py run i297-after-12 -- node tools/compare.mjs -s '^C[0-9]' -p sdp --add sdp:STANDARD_DENSE_GRID --only sdp:STANDARD_DENSE_GRID -j 4 --out logs/remote/i297-after-12.jsonl
# 改前：同样两条，在 origin/main 的工作树里，只跑密铺的变体（i297-before-k3、i297-before-12）
```

每城的数是 60 个（或 12 个）场景合计后除以放下的城数。“挤”是 `sdpSpread` ÷ 城数，4.00 就是每座新城离最近的城或城址都是 4 格。“共用格”是裁判的 `overlap`（离两个城址、或一个城址和一座城都在 3 格内的格）。

| | 城数 | 违规 | 每城裁判城址分 | 每城共用格 | 挤（每城格数） |
|---|---|---|---|---|---|
| 密铺 3 座，`C`，改前 | 36 | 0 | 31.78 | 7.78 | 4.72 |
| 密铺 3 座，`C`，改后 | 36 | 0 | 31.78（不变） | 10.86 | 4.00 |
| 密铺 3 座，`ZS`，改前 | 144 | 0 | 31.53 | 8.08 | 4.67 |
| 密铺 3 座，`ZS`，改后 | 144 | 0 | 31.06（−1.5%） | 10.68 | 4.00 |
| 密铺 12 座，`C`，改前 | 144 | 0 | 28.50 | 9.93 | 4.36 |
| 密铺 12 座，`C`，改后 | 144 | 0 | 28.12（−1.3%） | 11.28 | 4.00 |
| 平时 3 座，`C`（不受影响，参照） | 36 | 0 | 32.75 | 6.92 | 4.78 |
| 平时 3 座，`ZS`（参照） | 144 | 0 | 32.00 | 7.67 | 4.75 |

- 72 个场景逐个比：改后每个都比改前挤（`sdpSpread` 变小），没有一个变松，城数没有一个变少。
- 每城裁判分只低 0～1.5%：裁判的地块分只看最好的几格，共用多了 3 格左右，最好的几格多半还在。#191 时密铺 3 座比平时 3 座每城低约 3%，现在 `C` 上仍是 −3%、`ZS` 上 −2.9%。
- 耗时：改前、改后的几组不在同一台机器上跑（`remote.py` 按空闲选），只看量级：中位数都在 1 分钟左右，没有明显变化。

结果文件只在 `logs/remote/`，不入库。

开发集（`python3 -I tools/remote.py run i297-check --slots 6 -- python3 -I tools/refresh_results.py --check`）：268 行重跑，方案全部不变，提升没有变高变低，没有新违规（开发集是单城、多城场景，不走密铺）。核对戳 `tests/compare/results/check_stamp.json` 随 PR 提交。

## 3. 测试

- 离线：`spec_sites` 的 “issue 297: dense packing with room to spare puts every site as near as the spacing allows”（随机地图 30 × 24，首都居中，3 座新城，D = 6：最好方案的 `Spread` 必须是 3 × 4 = 12，每座城离最近的城或城址正好 4 格，每套方案报告的 `Spread` 等于测试自己算的；平时模式的方案没有 `Spread`、按总分排）。旧代码上失败：`expected 12, got 16.0`。“dense packing: most sites first …” 的排序检查改为城数 → 挤 → 总分。
- 调参时的观察（同一个随机地图生成器，12 个种子 × 3 座、2 座）：旧代码最好方案的 `Spread` 3 座 13～17、2 座 8～11；新代码全部是最小值 12、8。每套方案的总分低约 5～15%（假世界的数字，只看方向）。
- 游戏内：`tests/test_sites.lua` 的 “issue 191” 一项加了“城数一样时挤的在前、`Spread` 有值”；夜间队列 #57。

## 4. 没改的

- 面板上“最远距离”的悬停提示对密铺不成立（密铺本来就放最近的位置，最远距离只管中间被挡住时能跳多远、挪位最远挪到哪）。文案要人定，这次不改，在 Issue 下提了。
- 粗打分不含区域、两座新城的区域互相给的相邻加成不算：和以前一样（Issue 的说明“局限”一节）。
