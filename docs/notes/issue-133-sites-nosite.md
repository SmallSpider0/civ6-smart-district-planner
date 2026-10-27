# #133 选城址页：区域数量 3 时找不到数量 0 能找到的城址

Issue：<https://github.com/SmallSpider0/civ6-smart-district-planner/issues/133>。bug，v1.5.4。

## 1. 现象

后期存档（`stress.py` 的 continents-gs，风云变幻 · 大陆，第 221 回合，9 座城），选城址页标准档、最远距离 5、新建 3 个、必建为空、候选 8 种区域：数量 0 找到 1 个城址（80,32），区域评估调用 6 次；数量 3、6 都是 `NO_SITE`，区域评估调用 0 次（`tests/bench/sites_count.py continents-gs`，结果 `tests/bench/results/sites_count-continents-gs.json`）。#90 的记录第 4 节末尾记过这个问题。

## 2. 原因

两处，叠在一起：

1. **粗评把城址整个丢掉**（主因）。`SDP_Sites.Coarse` 里 `site.Valid = usable * 2 >= planned`：城址三环内能放区域的格（不是水、山、不可通行）少于计划区域数的一半就记为无效，`SDP_SiteSolver.NewSession` 只留 `Valid` 的城址。计划区域数 = 必建 + 数量（`#ctx.Plan + ctx.Pick`），数量 0 时恒为有效，数量 3 时空地 ≤ 1 格、数量 6 时 ≤ 2 格的城址被丢掉，精评（DMT）一次都不调用。后期地图上城址挤在别国和本方城市之间，空地少，正好撞上。这条规则从阶段 9–12（0db1024）起就有，#90 把默认数量改成 3 后才在默认设置下出现。
2. **候选池要的个数比空地多时一个都不放**。`SDP_Search` 的候选池（`Pools`）按“恰好挑 `count` 个”枚举组合；`count` 只按“有合法格的候选区域个数”截断，没按格子数截断。三个候选、一个空地时每个组合都没有布局（`CountLayouts` 为 0），搜索没有结果，`PlaceWhatFits` 只处理必建，候选一个不放。去掉第 1 条后，这个城址会被保留但区域分为 0；单城页同样：城市周围空地少于“区域数量”时返回 `NO_LEGAL_LAYOUT`（离线复现见第 4 节）。多城页不受影响：`SDP_Multi` 的 `SolveBlock` 本来就放得下几个放几个（离线核对过，改前改后都放 2 个、报 1 个“候选不足”）。

## 3. 改法

- `SDP_Sites.Coarse` 去掉 `Valid`，`SDP_SiteSolver` 保留全部候选城址。空地不够的城址照旧按缺的个数扣 `MISSING_PLOT`（每个 2 分），精评里按放得下的区域打分。区域数量只改变打分，不再筛掉城址。
- `SDP_Search`：候选池的个数再按 `PoolRoom` 截断：本组全部槽位到候选格的最大匹配，减去必建槽位的最大匹配（增广路，槽位和格子按固定顺序，确定性）。可同时放下的槽位集合构成横贯拟阵，放得下的必建集合能扩成最大匹配，所以差值就是“必建尽量放下时还能放几个候选”。截到 0 的组仍按候选池运行，唯一的组合是只放必建。只有要的个数比放得下的多时才有变化，以前这种情况没有结果。
- 合法性用的是 `Singles` 的单独合法表（只看 DMT 对单个区域的判定），截断是上界；组合之间的互斥（`Exclusive`、`Apart`）仍由组合枚举处理。

## 4. 测试

- 离线，`spec_sites.lua`“issue 133: the district count never removes a site…”：山地里一条两格的空地，城址只剩一格放区域；数量 0、1、3、6 找到的城址相同，数量 > 0 时放下 1 个区域。旧代码上数量 3 报 `NO_SITE`；只去掉 `Valid` 时数量 3 的城址区域为 0，也失败。
- 离线，`spec_pools.lua`“issue 133: a count above the free plots places as many candidates as fit, not none”：单城页，城市周围两格空地，数量 3：放 2 个候选；必建学院 + 数量 3：学院和 1 个候选。旧代码上报 `NO_LEGAL_LAYOUT`。FAST、STANDARD 两档。
- 本机：`spec_sites.lua`（约 31 秒）、`spec_pools.lua`（约 20 秒）全过；`validate.py` 通过。
- 第二台机器：整套离线测试（`remote.py run i133-offline`）、离线对比回归检查 `refresh_results.py --check`（`remote.py run i133-check`），结果见 PR。
- 游戏内（主会话安排）：在 continents-gs 存档上重跑 `python3 -I tests/bench/sites_count.py continents-gs`，数量 3、6 应能找到城址（至少包含数量 0 的 80,32），区域评估调用次数大于 0；`tests/test_sites.lua` 照常通过。
