# #90 选城址页的区域：必建 / 候选 / 不建和区域数量

Issue：<https://github.com/SmallSpider0/civ6-smart-district-planner/issues/90>。方案 A，DracoYus 2026-10-26 在 issue 里定：

- 选城址页的区域改用单城页的区域格（必建 / 候选 / 不建）和“区域数量”，含义和单城页一样；
- 默认：玩家能建的占人口名额的区域都是候选，保护区、军营、航空港默认不建；区域数量默认 3，上限 6；
- 选城址页的设置和单城页分开存，都记进存档。

## 1. 做法

- **界面**（`SDP_PageSites.lua`、`SDP_Panel.xml`）：勾选框换成单城页的 `DistrictCell` 两组格子（占名额 / 不占名额），用 `SDP_UI.BuildCells`、`SDP_UI.ShowCell`、`SDP_UI.ListRequest`、`SDP_UI.NextState`，没有另写一套。“每个城址按 N 个”换成“区域数量”（`LOC_SDP_COUNT`），上限 `SDP_Sites.MAX_COUNT` = 6，下限是必建个数（同单城页）。原来的 `CheckCell` 模板删掉。
- **和单城页不同的两处**：
  - 不占名额的区域（水渠、堤坝、社区……）没有“自动”：城址还不是城市，不判断缺不缺淡水。默认不建，点一下必建，再点不建（`NextState`）。原来这一组默认也不勾，行为不变。
  - 全帝国限一个的区域（市政广场、外交区）标“不计入”、不能点，悬停说明不按城址估分；原来是灰掉的勾选框。英文标 “Off”：第一夜截图里 “Not used” 压在两行的 “Government Plaza” 上，格子右边只放得下三个字母左右。
- **默认不建的规则**（`SDP_Rules.Functional`）：占人口名额、不受帝国限量的区域里，既没有一条本方特性不排除的 `District_Adjacencies` 相邻产出（`YieldChange > 0`），`Districts.Entertainment`（宜居度）也是 0 的，默认不建；其余默认候选（`SDP_Sites.DefaultState`）。不看科技和市政，所以一局里默认不会变。按缓存的规则库（风云变幻）筛出来是军营、航空港、保护区，外加祖鲁的伊坎达（军营的替代）；娱乐中心、水上乐园、街头狂欢（宜居度）、越南的 Thanh（不占名额）不在内。游戏内测试 `test_sites.lua`“the districts left out by default are the decision's three”在每种规则集里核对：筛出的每个区域的基础区域都是决定里的三个之一，三个里玩家能建的都被筛出。
  - 没用单纯的“没有相邻加成”：那样娱乐中心、水上乐园也会默认不建，和决定（只三个）不一致。
- **存档**（`SDP_Settings`）：新增 `list` 类字段（逗号分隔、逐项按 `Pattern` 校验、排序）。选城址页的 keeper 多两项：`COUNT`（0–6，默认 3）和 `DISTRICTS`（如 `DISTRICT_CAMPUS:M,DISTRICT_PRESERVE:P`，只记和默认不同的）。键仍是 `SDP_Settings_SITES`，和单城页 `SDP_Settings_SINGLE` 分开；读到本局没有的区域类型时丢掉。单城页的三态本来就不记存档，这次不动。
- **求解器**（`SDP_Sites.Context`）：请求多了 `Pool`、`Pick`。`Districts` 是必建的（含不占名额的），进每个城址的计划；`Pool` 里占名额、不限量的进候选池，每个城址挑 `Pick` = 数量 − 必建占名额个数 个（沿用已有的 `Pools`）。`Pick` 等于池子大小时直接并进计划，不挑；`Pick` 为 0 时去掉池子（开发时漏过一次：池子留着而不限个数，搜索把候选当成可放可不放，离线测试慢到十几分钟；`spec_pools` 加了这一条）。旧的 `PlanCount` 请求照旧可用（压力测试、游戏内旧测试）。所需人口按必建占名额个数 + `Pick` 算。

## 2. 离线测量

命令（第二台机器，经 `remote.py`；`cmp_sdp.lua` 加了变体 `<TIER>_GRID[n]`：用页签的默认格子、每个城址 n 个，不用场景自己的三个区域）：

```
python3 -I tools/remote.py run i90-grid --slots 3 -- node tools/compare.mjs -s '^C[0-9]' -p sdp \
  --add sdp:STANDARD_GRID0,sdp:STANDARD_GRID,sdp:STANDARD_GRID6 \
  --only sdp:STANDARD,sdp:STANDARD_GRID0,sdp:STANDARD_GRID,sdp:STANDARD_GRID6 -j 3 --out logs/remote/i90-grid.jsonl
```

12 个 `C` 场景（中期首都，选 2 个城址，最远 5 格），标准档，48 次运行，661 秒，0 失败、0 违规。默认格子的候选池（罗马）：学院、商业中心、娱乐中心、港口、圣地、工业区、剧院广场、水上乐园，8 个。结果文件没有入库（只在 `logs/remote/`）。

| 变体 | 含义 | 裁判城址分合计 | 地块值 | 区域潜力 | 重叠格 | 离线求解秒数中位数 |
|---|---|---|---|---|---|---|
| `STANDARD_GRID0` | 以前的默认：一个区域都不勾 | 810 | 664 | 146 | 151 | 5.8 |
| `STANDARD` | 场景指定的学院、圣地、商业中心全计入 | 840 | 675 | 165 | 144 | 19.6 |
| `STANDARD_GRID` | 现在的默认：8 个候选里挑 3 个 | 842 | 677 | 165 | 144 | 45.8 |
| `STANDARD_GRID6` | 数量 6 | 846 | 677 | 169 | 140 | 70.9 |

- 以前的默认 → 现在的默认：12 个场景里 5 个选出的城址不同（C01、C02、C06、C08、C12），裁判城址分 4 个高、8 个相同、没有低的；合计 +4%（810 → 842），区域潜力 +13%（146 → 165）。耗时中位数是 7.6 倍。
- 和 issue 调研里的“6 选 3 慢 1.7 倍”比：默认池子是 8 个（多了娱乐中心、水上乐园），比 3 个区域全计入慢 2.3 倍（中位数）。娱乐中心、水上乐园没有相邻加成，几乎挑不中，但按决定仍是候选。issue 里游戏内标准档精评 40 个城址约 0.75–1 秒，按 2.3 倍估是 1.7–2.3 秒；分帧执行，界面不假死。游戏内的实际耗时等夜间 `test_sites.lua` 的墙钟时间。
- 数量 6：再慢约 60%（相对数量 3 的中位数比 1.60），7 个场景城址不同，裁判分 4 高 3 低（裁判的区域潜力只看学院、圣地、商业中心三个）。
- “区域数量”悬停提示里的收益、代价就是这几行：数量 3 比数量 0 有 5/12 个场景城址不同、相邻加成合计 +13%、没有变差；耗时约 7 倍（只放 3 个必建时的 2.3 倍），数量 6 再多约 60%。离线秒数只作相对比较。

## 3. 测试

- 离线（经控件自己的回调）：`spec_panel.lua`“issue 90: city sites tab: the district grid and the count…”（默认状态、点一圈、限量区域点不动、必建计入数量、上限 6 下限必建、求解后每个城址都有必建的学院、单城页不受影响）；`spec_settings.lua`（`list` 字段、读档恢复三态和数量、点格子后立刻记下、回到默认不写）；`spec_pools.lua`（求解器：必建在每个城址、候选补足、池子里去掉限量和不占名额的、挑满等于全必建、`SDP_Rules.Functional`）。
- 之后的选城址离线测试把数量降到必建个数（`SetDistrictCount(0)`），保持原来的耗时。
- 真实点击（2026-10-26 夜，a96af34）：`realclick.py` 67 项全过，含选城址区域格一圈和数量箭头 3→4→3。
- 游戏内第一夜（a96af34）：原版、风云变幻各 9 过 1 败，败的是 `test_sites` 里经格子点击那项：游戏的控件没有 `Click`（只有离线替身有）。改成调用格子行带出的 `Click`，它就是格子注册的点击回调（`SDP_UI.BuildCells`，离线测试核对两者是同一个函数）。`test_sites` 文件耗时 1.2 秒。
- 游戏内（夜间队列）：`test_sites.lua`（默认不建的三个、经格子点击、默认格子求解）、`test_tabs.lua`、`test_settings.lua`；真实点击 `realclick.py` 加了选城址页的区域格一圈和数量箭头。

## 4. #124 游戏内实测

选城址页，标准档，新建 3 个城址，最远距离 5，3 轮取中位数（单位秒）。存档由 `python3 -I tools/stress.py prepare mid-gs` 等准备，测量用 `python3 -I tests/bench/sites_count.py 存档名`，结果在 `tests/bench/results/sites_count-*.json`，日志 `logs/sites_count.log`。

| 存档 | 回合 | 数量 0 | 数量 3 | 数量 6 |
|---|---|---|---|---|
| 中期，风云变幻，大陆（mid-gs，3 座城） | 101 | 0.09 | 1.13 | 1.63 |
| 后期，风云变幻，盘古大陆 | 201 | 0.09 | 1.17 | 1.64 |
| 后期，海岛（原版加 R&F） | 210 | 0.08 | 0.42 | 0.41 |

数量 3 比数量 0 慢约 12 倍（海岛约 5 倍）。“区域数量”的悬停提示据此改写，不再用上文离线的 7 倍。

未解决的问题（另开 Issue）：后期大陆存档（回合 221）里，数量 0 只找到 1 个城址，数量 3 和 6 一个也没找到（0.03 秒就结束）。这里没有解释，也没有改。原因和修正见 [issue-133-sites-nosite.md](issue-133-sites-nosite.md)（#133）。

