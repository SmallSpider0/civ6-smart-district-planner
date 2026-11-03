# #250 单城页按“只有一座城的多城请求”求解：离线实验

2026-11-03。只做实验，模组没改。结论和建议贴在 #250，由维护者定。

## 做法

- 离线对比的开发集单城场景（`S01`–`S24` × 前/中/后期，72 个），每个场景用当前代码各跑两遍：单城管线（`SDP_Solver.Solve`）和面板勾了奇观时的那条路（`SDP_Multi.Solve`，`Only` 只有这座城，`Plans` 是这座城自己的清单，和 `SDP_Panel` 的 `WonderRequest` 相同，只是不带奇观）。
- 档位：快速、标准、精细（只算相邻）；标准、精细（计入地块）；面板默认（标准、计入地块、换格、距离 0.5，变体 `STANDARD_SWAP_LAND_DIST050`）。另跑同一提交的真最优：`ORACLE`（裁判的相邻加成）和 `ORACLE_LAND`（本模组自己的目标），72 个场景全部证明。
- 耗时：`cmp_sdp.lua` 记下每次求解经 `SDP_Task.Tick` 报的工作单位（`stats.sdpUnits`），按游戏内实测的速度折算：单城快速、标准档一次算完，约 20000 单位/秒（`SDP_Tiers`）；单城精细档和多城一律分帧，一座城约 7400–9900 单位/秒（`SDP_Task`），按 9000 算。fengari 的墙钟只看量级。面板自己的预计（`stats.sdpEstimate`）也记下，比对准不准。

```bash
node tools/compare.mjs -s '^S[0-9][0-9]-[^~]*$' -p sdp \
  --only sdp:FAST,sdp:STANDARD,sdp:FINE,sdp:STANDARD_LAND,sdp:FINE_LAND,sdp:STANDARD_SWAP_LAND_DIST050,sdp:FAST_ASMULTI,sdp:STANDARD_ASMULTI,sdp:FINE_ASMULTI,sdp:STANDARD_LAND_ASMULTI,sdp:FINE_LAND_ASMULTI,sdp:STANDARD_SWAP_LAND_DIST050_ASMULTI,sdp:ORACLE,sdp:ORACLE_LAND \
  --add sdp:FINE_LAND,sdp:STANDARD_SWAP_LAND_DIST050,sdp:FAST_ASMULTI,sdp:STANDARD_ASMULTI,sdp:FINE_ASMULTI,sdp:STANDARD_LAND_ASMULTI,sdp:FINE_LAND_ASMULTI,sdp:STANDARD_SWAP_LAND_DIST050_ASMULTI,sdp:ORACLE,sdp:ORACLE_LAND \
  -j 8 --out tests/compare/results/one_city_as_multi.jsonl     # 1008 次，第二台机器 8 格约 38 分钟
python3 -I tests/compare/asmulti250.py tests/compare/results/one_city_as_multi.jsonl
```

## 结果

**质量**（达到真最优的场景数 / 72，括号里是 72 个场景合计差了几点）：

| 档位 | 单城 | 多城一座城 | 多城比单城 胜/平/负 |
|---|---|---|---|
| 快速 | 66（6） | 65（7） | 1 / 69 / 2 |
| 标准 | 71（1） | 71（1） | 0 / 72 / 0 |
| 精细 | 71（1） | 71（1） | 0 / 72 / 0 |
| 标准，计入地块 | 71（1） | 71（1） | 1 / 70 / 1 |
| 精细，计入地块 | 72（0） | 72（0） | 0 / 72 / 0 |
| 面板默认（无真最优） | — | — | 目标值 1 / 71 / 0 |

- 标准、精细两档没到最优的都是 `S14-mali-desert-late`（差 1）。计入地块时单城差在 `S22-rome-volcanic-late`，多城差在 `S19-kongo-jungle-late`，各差 1。面板默认多城赢的一个是 `S16-indonesia-island-late`（目标值 +0.5）。
- 方案完全相同的：标准 68、精细 68、面板默认 67 个场景，其余是同分的别的摆法或上面几处。

**违规、漏放**：两条路都是 0 违规；每档都漏放 5 个，全是“范围内没有合法格”（no_plot），没有“有位置却没放”。没放下的区域及原因两条路逐场景相同。

**工作量与预计耗时**（中位数 / 最慢；秒数按上面的速度折算）：

| 档位 | 单城 | 多城一座城 | 倍数（中位 / 最大） |
|---|---|---|---|
| 快速 | 1025 / 2097 单位，0.05 / 0.10 秒（一次算完） | 2255 / 4620，0.25 / 0.51 秒（分帧） | 2.1 / 2.5 |
| 标准 | 2451 / 5645，0.12 / 0.28 秒（一次算完） | 10995 / 25409，1.2 / 2.8 秒（分帧） | 4.6 / 6.3 |
| 精细 | 5786 / 16138，0.64 / 1.79 秒（分帧） | 24556 / 59170，2.7 / 6.6 秒 | 4.2 / 11.5 |
| 面板默认 | 2421 / 5855，0.12 / 0.29 秒（一次算完） | 11129 / 28102，1.2 / 3.1 秒 | 4.6 / 6.9 |
| 精细，计入地块 | 5856 / 17469，0.65 / 1.94 秒 | 24451 / 61637，2.7 / 6.8 秒 | 4.2 / 11.5 |

- 最慢的都是后期场景：面板默认 `S05-japan-temperate-late` 28102 单位（约 3.1 秒，单城 0.28 秒），`S17-egypt-desert-late`、`S01-rome-temperate-late`、`S18-byzantium-temperate-late` 约 2.7–2.8 秒。精细档计入地块最慢 `S05` 约 6.8 秒（单城 1.9 秒）。
- 多城走分帧，画面不卡、有进度条，所以不违反“停顿不超过约 2 秒”；代价是玩家从“点了马上出”变成等 1–3 秒（精细档 3–7 秒）。
- 同样的工作量，单城更好：多城快速档的工作量（中位 2255）和单城标准档（2451）相当，达到最优的却是 65 对 71。多出的工作在多城求解器的固定流程（标准档先跑一遍快速档，再 5 个起点、24 轮扰动、留 3 个备选方案；单城标准档 3 个起点、4 轮扰动），一座城时这些多半白做：标准、精细两档的结果和单城一样。
- 面板的预计：单城的预计 / 实际约 0.93–1.04，多城一座城约 1.33–1.41（偏长三到四成）。

## 结论（写在 #250）

照现在的样子统一不划算：质量、合法性、漏放都一样，工作量却是 4–5 倍。#154 那类问题出在算完之后（替换钉、提醒钉、打钉、显示），不在搜索本身。

## 文件

- 结果：`tests/compare/results/one_city_as_multi.jsonl`（1008 行，`env.code` 是本分支的提交）。
- 汇总：`tests/compare/asmulti250.py`。
- 对比里的变体：`cmp_sdp.lua` 的 `_ASMULTI`；每次运行都记 `stats.sdpUnits`、`stats.sdpEstimate`。
