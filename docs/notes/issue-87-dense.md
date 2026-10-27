# #87 选城址的密铺（2026-10-27）

决定：[#87 合作者已定](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/87)：开关默认关；先比放得下几座新城，城数一样再比总分；城与城之间按游戏的最小距离（`CITY_MIN_RANGE`），可以接力；新城数量默认 12、可调、记住，关掉回到平时的数；每个城址一个勾选框，默认不勾，有“全选”，只给勾选的打钉；离别的文明的城市多远不变，首都不例外。

## 1. 做法

见 [docs/multicity-design.md](../multicity-design.md) 3.5 的“密铺”一段。代码：`SDP_SiteSolver` 的 `Session:Packings`、`Session:DenseRun`，档位参数 `SDP_Tiers.Sites` 的 `DenseStarts / DenseRefined / DenseImprove / DenseMoves`；界面 `SDP_PageSites`（`SetDense`、`SetTicked`、`TickAll`，城址行用 `SiteRow` 模板）。

## 2. 离线对比：平时与密铺

12 个 `C` 场景（中期首都），面板默认的区域格，标准档，同样的最远距离（场景自带）。`_K6` 是平时最多的 6 座（`tests/compare/cmp_sdp.lua` 的 `<档位>_K<n>`）：

```
python3 -I tools/remote.py run i87-cmp --slots 6 -- node tools/compare.mjs -s '^C[0-9]' -p sdp --add sdp:STANDARD_GRID,sdp:STANDARD_K6_GRID,sdp:STANDARD_DENSE_GRID --only sdp:STANDARD_GRID,sdp:STANDARD_K6_GRID,sdp:STANDARD_DENSE_GRID -j 6 --out logs/remote/i87-cmp.jsonl
```

| | 平时 2 座 | 平时 6 座 | 密铺 |
|---|---|---|---|
| 放下的新城（12 个场景合计） | 24 | 72 | 144（每个场景都是上限 12 座） |
| 违规 | 0 | 0 | 0 |
| 每座城的裁判城址分（最好 8 块地 + 区域潜力） | 34.5 | 30.6 | 28.5（比 6 座低 7%） |
| 与本方城市重叠的格（合计） | 152 | 602 | 1430 |
| 求解耗时中位数（离线秒，6 个并行） | 58 | 72 | 112（6 座的 1.6 倍） |

开关的悬停提示用的就是这三个数：平时最多 6 座、密铺 12 座；每座城的分低约 7%；耗时约 1.6 倍。离线耗时比游戏里长，倍数才有意义。结果文件只在 `logs/`，不入库。

## 3. 测试

- 离线：`spec_sites` 的 “dense packing: most sites first, spaced, linked back, no refined site left that fits; deterministic”；`spec_panel` 的 “issue 87: dense packing through its switch, tick boxes and Select all”（经勾选框自己的回调）。
- 游戏内：夜间队列（`tests/test_sites.lua`、面板截图）。
