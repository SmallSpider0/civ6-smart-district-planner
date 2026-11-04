# #245 把 `SDP_Multi.NewSession` 拆成有名字的步骤

2026-11-04，分支 `mac/split-session`（基于 `main` 03f8ae9，含 #244、#250、#274）。来源：2026-11-03 项目体检第 4 条。纯重构：每一步的代码是原函数对应段落原样搬过去的，只改了几个局部变量从哪来，遍历顺序、排序键、数值和各步的先后都没变。

## 拆成了哪些步骤

`NewSession` 现在只做准备（隐藏要替换的钉、档位参数、权重、扫描选项、参与的城市），然后依次调下面的步骤。都是 `SDP_Multi.lua` 里的 local 函数，开头的注释写了输入（In）和输出（Out）。

| 步骤 | 函数 | 读 | 写 / 返回 |
|---|---|---|---|
| 1 参与城市与清单 | `PlanCities(self, request, options)` | 参与的城市、请求的清单（`Plans`、`Districts`、`Counts`、`Auto`、`Target`） | 每座城的 `Scan`、`Present`、`ForWonder`、`Plan`、`Auto`（城址的 `PlanPopulation`，`Target` 时的 `Have`）；返回 `plannable`、`byType`、`empireCount`、`asked`、`unplaced` |
| 2 帝国唯一区域分配 | `ShareEmpireLimits(self, request, byType, empireCount, asked, unplaced)` | `Center`、`Plans`、`UniqueTo` | 没分到的城从 `Plan` 去掉（记进 `unplaced`）；`self.HostChoices`；返回 `left`（帝国还能建几个，第 4 步接着数） |
| 3 奇观归哪座城 | `WonderCities(self, request)` | `WonderCities`、`Wonders`、`AutoSkip` | `self.WonderCity`、`self.AutoWonder`、`self.Production` |
| 4 为奇观补区域 | `SupplyForWonders(self, request, options, plannable, byType, empireCount, asked, left)` | `Wonders`、`SupplyTo`、`Off`、`Offs` | 补的区域加进 `Plan`、`ForWonder`、`asked`；`self.Supplied`、`Elsewhere`、`NoRoom` |
| 5 候选区域 | `CandidateDistricts(self, request, byType, asked)` | `Pools`、`Pool` | 每座城的 `Pick`、`Pool` |
| 6 候选格 | `CandidatePlots(self)` | 各城扫描的候选格 | `self.Candidates`、每座城的 `Allowed`；返回候选格 |
| 7 固定邻居 | `FixedNeighbours(self)` | 各城扫描 | `self.Fixed`、`Base`、`Board`、`ExtraCalls`；返回固定的 subject |
| 8 人口与地块 | `PopulationAndLand(self, request, byType, fixed)` | `Land`、`Weights` | 每座城的 `Population`、`Land`；返回 `lands` |
| 9 覆盖范围 | `CoveragePart(self, request, options)` | `Coverage`、`Only` | `self.Coverage` |
| 10 区域槽位 | `DistrictSlots(self)` | 各城的 `Plan`、`Pool`、`Pick` | 返回 `slots`、`slotCity`、`pools` |
| 11 奇观槽位 | `WonderSlots(self, request, options, plannable, fixed, candidates, slots, slotCity, unplaced)` | `Wonders`，第 3、4 步的结果 | 奇观槽位接在 `slots` 后；放不了的记进 `unplaced`；`self.WonderGroup`；返回 `wonderSlot` |
| 12 建搜索 | `BuildSearch(self, request, params, candidates, slots, lands, pools, fixed)` | `Swap`、`Distance`、`Apart`、`Weights` | `self.Search`（城址中心、可耕作格、结伴区域、可达范围、`SearchOwners`、`HousingCities`、覆盖和换格的归城） |
| 13 没有合法格的槽位 | `NoLegalPlot(self, request, slots, slotCity, wonderSlot, unplaced)` | `self.Search:Singles()`、`self.AutoWonder` | `NO_LEGAL_PLOT` 记进 `unplaced`；`self.AutoRetry` |
| 14 分块与分组 | `BlocksAndGroups(self, params)` | `self.Search`、`self.WonderGroup` | `self.Blocks`、`Stats`、`Starts`、`NextStartIndex`、`GroupList` |

另外三个小函数：`Has(participants, p, base)`（原来 `NewSession` 里的局部函数，第 4、11 步都用）、`SearchOwners(participants, fixed)`、`HousingCities(participants, playerID)`（第 12 步用）。

和 Issue 列的七块的对应：Issue 的“固定邻居与住房”拆成第 7、8、9 步（住房目标就是第 8 步的人口），“为奇观补区域”拆成第 3、4 步，“槽位”拆成第 10、11 步，“建搜索”之后的收尾拆成第 13、14 步。

各步的先后和原函数相同（`unplaced` 的追加顺序、DMT 调用的先后都由它决定）。只挪了两处不影响结果的：`self.Supplied` 等三张空表从奇观归城之前挪到第 4 步开头；`request.Land ~= false` 挪进第 8 步。

## 核对

- 用到的全局名：拆分前后 `SDP_Multi.lua` 用到的全局（luaparse 带作用域解析）完全相同，没有哪一步漏声明局部变量而读成全局。
- 离线对比，改动前（`origin/main` 03f8ae9，临时工作树）和改动后各跑一遍，逐行比较每次运行的方案（`placements` 和其余字段）、裁判的分数和统计（去掉耗时）：

```bash
python3 -I tools/remote.py run i245-base  -- node tools/compare.mjs -s '^([SM]\d\d-[^~]*$|(W|WA|V)\d)' -p sdp -j 4 --out logs/remote/i245-base.jsonl    # 在 origin/main 的工作树
python3 -I tools/remote.py run i245-after -- node tools/compare.mjs -s '^([SM]\d\d-[^~]*$|(W|WA|V)\d)' -p sdp -j 4 --out logs/remote/i245-after.jsonl   # 在本分支
```

  比较时只去掉耗时字段（`planSeconds`、`judgeSeconds`、`stats.seconds`）和 `env`（`env.code` 是代码的哈希，两边本来就不同：`e675929f3189` 对 `186ccb43c3d6`），DMT 调用次数、工作单位、未放下的区域和原因都比。

  结果：488 次运行（开发集 `S`、`M` 352 次；奇观和覆盖范围 `W`、`WA`、`V` 136 次；共 128 个场景、3301 个放置），0 处不同。第二台机器各 4 格，各约 52 分钟。结果文件只在本机 `logs/remote/i245-*.jsonl`（两个工作树各一份），不入库。
- `node tools/offline_tests.mjs`：340 项全过（含每次求解后的不变量检查；`remote.py run i245-offline`）。
- `python3 -I tools/validate.py`：0 错误。
- 游戏内测试没跑：只搬动代码，方案、未放下的区域和统计在离线对比里逐字不变；`NewSession` 不碰界面。

## 看到但没改的（后续）

- 多城会话的 `self.Auto` 一直是空表，没有地方读（自动加入的区域记在每座城的 `part.Auto`）；`SDP_Solver` 的会话才用 `self.Auto`。
- 第 4 步和第 11 步各调一次 `SDP_Wonders.List`、各排一次奇观、各找一次“替换基础区域的特色区域”（罗马的浴场）。可以由第 3 步算一次传下去。
