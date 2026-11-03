# #244 区域状态、奇观归城各只留一个入口

2026-11-04，分支 `mac/one-entry`（基于 #266 合并后的 `main`）。来源：2026-11-03 项目体检第 3 条。纯重构，方案不变；界面上只有一处跟着求解器变了（见“看得到的变化”）。

## 改了什么

**区域状态（已建、不能同城、帝国上限、已打钉）**

- 以前四个函数各判断一部分：单城页 = `DistrictStatus`（扫描时不去掉正在被替换的钉）+ `TackedStatus`；多城页格子 = `EmpireBuilt`（帝国上限只数已建，不数钉）+ `BuiltHereStatus` + `TackedStatus`；求解器 = `DistrictStatus`（去掉正在被替换的钉）；`SDP_Multi` 分配限建区域时另数一遍已建和钉（`builtByPlayer`、`pinnedAnywhere`）。
- 现在：
  - `SDP_City.EmpireCounts(playerID, ignore)`：帝国上限只在这一处数（已建 + 钉，建成后的钉只算一次，正在被替换的钉不算）。`DistrictStatus` 和 `SDP_Multi.NewSession` 的 `left` 都读它。
  - `SDP_City.DistrictStatus(scan, districts)`：求解器跳过哪些区域，照旧。
  - `SDP_City.ListStatus(playerID, cityID, districts, ignore)`：面板清单置灰哪些 = 对不扫格子的 `PinScan` 调 `DistrictStatus`，再加 `TACKED`。单城页（`UpdateHave`）、多城页格子和请求（`StatusOf`、共用清单的 `ListOf`）都只调它。`cityID` 为空（共用清单、城址钉）只有帝国上限。
  - 删掉 `BuiltHereStatus`、`TackedStatus`。`EmpireBuilt` 只留给多城页写“已建、建在哪”的文字（#108 的措辞），不再决定置灰。
  - `PinScan` 不再把市中心记进 `Built`，和 `SDP_City.Scan` 一样（`SpecialtyHave`、`TackedDistricts` 本来就不看市中心）。
- 单城页的热力图下拉框仍用 `m_scanStatus`（`DistrictStatus`，没改）。

**奇观记在哪座城**

- `SDP_Multi` 的 `SlotCity(participants, playerID, search, m, i, layout)`：搜索里的 `SlotOwner`（覆盖不带方案、换格带正在试的方案）和定稿的 `Session:OwnerOf` 都只调它，只差传不传方案。以前是两份几乎一样的包装。
- `Search:SuppliedNext(m, i, layout)`：“为奇观补的区域放下了没有、挨不挨着、它的城能不能拿这一格”。合法性（`Search:WondersServed`）和归城（`WonderOwner` 第 2 步）以前各写一遍，现在都调它。
- 等价性：`WonderOwner` 的 `pool` = 能拿这一格的城 = `Owners.Wonder[i]`（`Owners.Wonder` 就是从各城的 `Allowed` 建的），所以“补的区域的城在 `pool` 里”和 `SuppliedNext` 的 `cities[group]` 是同一个条件；`RequiresM`、`layout` 为空的处理也相同。

**复制的小函数**

- `SDP_Rules.YieldWeights`：替换 `SDP_Solver`、`SDP_Multi` 里逐字相同的 `DefaultWeights`。
- `SDP_Rules.Serves`：替换 `SDP_Search`、`SDP_Multi` 里逐字相同的 `Serves`。
- 没合并的：三个页签的 `SetWeight`（各改各的模块状态，合并要多传三个参数，没有省事）；`SDP_City`、`SDP_Wonders` 的 `Flooded`（一个管区域、算被淹没的，一个管改良设施，规则不同）；`SDP_Coverage.BaseOf`（与 `SDP_Rules.BaseDistrict` 相同，但覆盖模块不依赖 `SDP_Rules`，离线测试单独加载它）。

## 看得到的变化

帝国上限现在两个页签都按求解器的数法：

- 多城页：市政广场这类区域在别的城打了钉（不是正在被替换的本模组旧钉）时，格子置灰、写“已达帝国上限”，悬停只写“全帝国限 1”，也不再发给求解器。以前格子能点，求解器照样不放第二个（每城的 `DistrictStatus` 都是 `MAX_PER_PLAYER`），城址钉还会在结果里列一条“已达帝国上限”。测试：`spec_unique.lua` 的“a government plaza tacked in a city is greyed out in every list”（旧代码上失败）。
- 单城页：勾了“替换本模组旧钉”、而别的城那个市政广场钉正是要替换的旧钉时，格子不再置灰（求解器本来就不算它）。

方案本身：只有在 `MaxPerPlayer` ≥ 2 并且一个钉压在同种已建区域上时，`left` 才会和以前差 1；游戏规则里两种限建区域的 `MaxPerPlayer` 都是 1（`tests/compare/.cache/gameinfo.lua`），离线世界里也没有更大的。

## 核对

- 离线对比，改动前（`origin/main` 69eca97）和改动后各跑一遍，逐行比较每次运行的方案（`placements` 和其余字段）、裁判的分数和统计（去掉耗时；DMT 调用次数、工作单位也比）：
  - 开发集 `node tools/compare.mjs -s '^[SM]\d\d-[^~]*$' -p sdp -j 8`：352 次运行，0 处不同；
  - 奇观和覆盖范围 `node tools/compare.mjs -s '^(W|WA|V)\d' -p sdp -j 4`：136 次运行（108 个奇观放置），0 处不同。
  - 结果文件只在本机 `logs/remote/i244-*.jsonl`，不入库。
- `node tools/offline_tests.mjs`：340 项全过（含每次求解后的不变量检查）；`spec_unique.lua` 新加的一项在旧代码上失败。
- `python3 -I tools/validate.py`：0 错误。
- 游戏内：夜间队列 #43（风云变幻，`test_tacked_list`、`test_unique`、`test_built`、`test_tacked`、`test_tabs`、`test_ui`），结果写在 PR 里。
