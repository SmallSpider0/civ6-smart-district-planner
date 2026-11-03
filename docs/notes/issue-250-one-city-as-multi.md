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
- 方案完全相同的（按城、区域、种类、坐标比，`asmulti250.py` 输出）：快速 62、标准 68、精细 68、标准计入地块 62、精细计入地块 70、面板默认 67 个场景，其余是同分的别的摆法或上面几处。

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
- Codex 审查（PR #262）后：汇总脚本改成按城、区域、种类、坐标比较方案（多城分支写 `kind`，单城分支不写，原来直接比 JSON 得 0/72）；`_ASMULTI` 也传候选池和数量（`Pool`、`Count`，和面板的 `WonderRequest` 一样），只影响 `P` 系列这类带候选池的场景，本实验的 `S` 场景没有候选池，结果不变、不用重跑。`P01`、`P02` 标准档试跑：多城一座城也从候选池选了区域，和单城选的相同。

## 方案 A 的实现（维护者 2026-11-03 定）

求解保持两套（不勾奇观 `SDP_Solver`，勾了奇观 `SDP_Multi` 只规划这座城），算完之后合成一条路，都在 `SDP_Panel.lua`：

- `Keep(result, request)`：`Solve` 的三支（奇观、分帧、一次算完）和 `Continue` 的两支都经它存结果，带上面板自己的请求（`PanelRequest`：摘要的分项、要替换的钉、继续时的预计，原来从两种 session 的 `Request` 读，多城那份没有 `MustSpecialty`）。
- `SDP_UI.CityResult(result, cityID)`：结果到了先整理一次，每个方案都有同样的字段：`Unplaced`（这个方案自己的；候选不够记成一条 `POOL_SHORT`）、`Picked`、`Together`；顶层的同名字段跟第一个方案。
- `SDP_UI.CityRows`（结果行）、`SDP_UI.CityIcons`（预览）、`SDP_UI.CityTacks`（打钉，含奇观要的改良设施和提醒钉）、`SDP_UI.CitySolution`（第 n 个方案）只读这些字段，`ShowResult`、`Preview`、`PlacePins` 调它们。

两条路原来不一致的地方，改成哪边、为什么：

| 不一致 | 原来 | 现在 |
|---|---|---|
| 候选不够（数量要的比放得下的多，#133 的“放得下几个挑几个”） | 多城报 `POOL_SHORT`，单城页把它当成叫 `POOL` 的区域显示，原因空着；单城不报 | 两条路都报，按多城页的样子显示一行“候选不够：城名”“少挑了 N 个”。单城的个数 = `Session.Pick`（已按能共存的封顶）− 方案挑出的个数，和多城的算法相同 |
| 方案按钮的提示 | 单城列挑出的区域；多城的方案没有顶层 `Picked`（在 `Cities[1].Picked`），只写“N 个区域” | 都列挑出的区域 |
| 每个方案没放下的 | 多城每个方案自己的；单城一律是第一个方案的，第二、三个方案可能把放下了的区域列成没放下 | 都是每个方案自己的：`SDP_Solver` 的 `Session:UnplacedFor(layout)`，每个方案带 `Unplaced`（顶层 `Unplaced` 仍是第一个方案的，离线对比的记录不变） |
| 自动加入的区域没地方放（`NO_FREE_PLOT`） | 单城写“自动加入的……放不下”；多城没带 `Auto`，只写“……放不下” | `SDP_Multi.PlanFor` 给这条带上 `Auto`，多城页也跟着改 |
| 结伴区域（`Together`） | 单城在方案上，多城在 `Cities[1]` 上，显示时临时兜底 | `CityResult` 统一放到方案上 |

两条路本来就一样、没改的：替换钉（都用面板请求的 `IgnorePins`）、提醒钉、换格（单城读候选格的 `Swap`，多城按格子所属的城算，同一个意思）、覆盖范围（键都是 `C<城 ID>`）、改良设施的住房、邻居、奇观要的改良设施。

没改：方案按钮在没挑区域时写“N 个区域”，多城的 N 把奇观也算进去了。只在勾了奇观、方案不止一个、又没从候选里挑时出现，离线世界里造不出来（多城没挑区域时只给一个方案），没有能经控件回调的测试，先不动。

测试：`tests/offline/spec_one_city_result.lua`，三项都经控件回调（数量加减钮、奇观下拉条目、求解钮、方案按钮），不勾奇观和勾了奇观各走一遍；旧代码上三项都失败（候选不够那行、勾奇观时方案提示、不勾奇观时第 3 个方案把放下了的商业中心列成没放下），只换回旧的 `SDP_Multi.lua` 时第三项在“自动加入的水渠”失败。求解器看到的东西没变（搜索、目标、候选都没动），离线对比不用重跑。
