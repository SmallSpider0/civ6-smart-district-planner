# #84 选城址的“最远距离”默认值：调研记录（2026-10-26）

Issue：DracoYus，“选城址，默认最远距离调整”。理由：暴铺是主流，城要在有限区域里多放；两城太近每城地块少；“最常见和通用的两城间隔是 5 格”。

## 1. 现在的代码

| 项 | 位置 | 内容 |
|---|---|---|
| 面板上的数 | `SmartDistrictPlanner/Scripts/SDP_PageSites.lua:42-43` | `m_k, m_d = 3, 8`；`MIN_D, MAX_D = 4, 15`；步进 1（`:519-520`） |
| 夹取 | `SDP_PageSites.lua:157-163` | `SetDistance` 夹到 4–15，改了就清掉结果 |
| 传给求解器 | `SDP_PageSites.lua:115` | `D = m_d` |
| 不记在存档 | `SDP_PageSites.lua:63-66` | `SDP_UI.Keeper` 只记预设、权重、档位、折叠；新城数量 K 和最远距离 D 读档后回到 3、8 |
| 标签 | `UI/SDP_Panel.xml:178-181` | `LOC_SDP_SITES_DISTANCE` = “最远距离” / “Max distance”（`Text/SDP_Text_zh_Hans_CN.xml:328`、`Text/SDP_Text_en_US.xml:328`），**没有悬停提示** |
| 求解器默认 | `Scripts/SDP_SiteSolver.lua:41` | `self.D = request.D or 8` |
| 候选范围 | `Scripts/SDP_Sites.lua:117` | 离本方城市超过 `K × D` 的格不作候选（`options.D or 8`） |
| 最小间距 | `Scripts/SDP_Sites.lua:63-64, 102`；`SDP_SiteSolver.lua:288` | `GlobalParameters.CITY_MIN_RANGE`（3），距离 ≤ 3 的排除，即中心相距至少 4 |
| D 的用法 | `SDP_SiteSolver.lua:60-71, 102-109, 189-215` | 只是连通条件：每个城址离本方城市、市中心钉或本方案另一个城址不超过 D 格（接力）。不进评分 |
| 距离怎么量 | 全部 `Map.GetPlotDistance` | 两个格中心之间的六边形距离（中心相邻 = 1） |
| 结果提示 | `LOC_SDP_SITES_OWN_DISTANCE`、`LOC_SDP_SITES_SITE_DISTANCE` | “离我方最近的城市或已打的城址钉 N 格”“离本方案的其他城址最近 N 格”，同一种量法 |
| 文档 | `docs/multicity-design.md` 3.1、第 11 节；`docs/install-and-test.md:75`；`docs/install-en.md:54` | “最远距离（4–15 格：新城离本方城市或另一座新城最多几格）”，默认 8 是 2026-10-19 第一轮评审定的 |

评分里没有任何项鼓励“靠近”：组合修正把重叠格只算给一座城（`SDP_SiteSolver.lua` 第 3 步），所以重叠只会扣分。结果是**求解器总把城址推到 D 的上限**（见第 5 节实测），D 实际上就是间距。

页签上另有一列“距离”权重（`LOC_SDP_WEIGHT_DISTANCE`）：管的是区域离市中心的远近，与城址间距无关。

## 2. 游戏规则

`Cache/DebugGameplay.sqlite`（`pragma table_info(GlobalParameters)`：`Name`、`Value`）：

| 参数 | 值 | 出处 |
|---|---|---|
| `CITY_MIN_RANGE` | 3 | Base `Gameplay/Data/GlobalParameters.xml:98`；与已有城市距离 ≤ 3 不能建城，即中心至少相距 4、中间隔 3 格 |
| `CITY_MAX_BUY_PLOT_RANGE` | 3 | 买地、工作范围 3 环 |
| `CITY_MIN_DISTANCE_FOR_INCURSION` | 8 | 离别国城市 8 格内建城算“侵犯”（外交） |

两座 3 环城市在不同中心距离下共用的格数（脚本按立方坐标数，每座城 3 环 37 格含市中心）：

| 中心距离 | 中间隔几格 | 共用格数 |
|---|---|---|
| 4 | 3 | 9–13 |
| 5 | 4 | 4–8 |
| 6 | 5 | 1–4 |
| 7 | 6 | 0 |

### “间隔 5 格”指什么

两种读法：中心距离 5（面板上的数），或中间隔 5 格（中心距离 6）。

- 中文社区把最小间距叫“3 格”：知乎“相邻的城之间……达到 3 格的极限距离”、“城市之间最小距离是 3 单元格”，也就是数中间隔的格数（游戏的最小中心距离是 4）。按这个习惯，“间隔 5 格”= 中心距离 6。
- 游民星空“两城之间刚好 5~6 格，互不冲突”：互不冲突要中心距离 7，也像是数中间的格。
- 英文多说 “N tiles apart”，一般指中心距离（CivFanatics 上 bigv32 的“4-6 apart (3-5 blank tiles between)”）。
- issue 的理由“太近则每城地块更少”与中心距离 6（两城 3 环只碰边，共用 1–4 格）更贴；但“暴铺”又偏向更密。

判断：较可能是中心距离 6，但不确定，列为待定问题，请 DracoYus 确认。不论哪种，面板上都该写明怎么数。

## 3. 玩家共识与个别意见（来源）

- CivFanatics “optimal city spacing”（Civ6 策略版，2017）：<https://forums.civfanatics.com/threads/optimal-city-spacing.605459> —— 说法分散：核心城 4–5、其余 6+；约 5；“中间 4–5 格可用格”；也有人主张尽量贴最小间距以多放城、叠工业区。
- CivFanatics “City distances”（Civ6，2020）：<https://forums.civfanatics.com/threads/city-distances.663482> —— 常见建议约 4 apart，也有 4–5、5–6；理由是城很少长到用满 3 环，靠近还能共享区域相邻；要淡水或少城时放宽。
- CivFanatics “optimal best distance between cities”：<https://forums.civfanatics.com/threads/optimal-best-distance-between-cities.658176> —— 从 6+ 改为 4–5；后期补城可到最小间距。
- 游民星空：<https://www.gamersky.com/handbook/201611/830225.shtml>（“理想间距三到六格”）、<https://www.gamersky.com/handbook/201704/894142.shtml>（第二城放在首都 5–6 格处）。
- 0x 资讯“文明6：城市应该相距多远”：<https://0xzx.com/2021080322121638709.html>（城市中心之间 4 格是经验法则）。
- 知乎：<https://www.zhihu.com/question/476942595/answer/2036246134>（密铺到 3 格极限）、<https://www.zhihu.com/question/397145858/answer/1784399407>（最小 3、分组布局，组内 3、组间 5）。知乎页面直接抓取被拒（403），内容来自搜索摘要。
- 巴哈姆特“城市間距離幾格效益最好”：<https://forum.gamer.com.tw/C.php?bsn=5114&snA=2962>（搜索摘要：有人主张刚好 6 格，也有人说 6 格不更划算）。

归纳：常见范围是中心距离 4–6；“约 4–5 apart”在英文社区最多，中文攻略多说“5~6 格”。没有人把 8 当作常用间距。尽量贴最小间距（叠工业区、多放城）和 6 格以上不重叠都是少数做法。

## 4. 其他规划器

- Empire Planner（`reference/ep/ui/ep_planner.lua:32-48`、`ep_meta.lua:1100-1150, 1368-1380`）：硬性最小 4（本方）、5（他国城市）；只在本方城市 10 格内找城址；评分里有“舒适半径” 5（中心距离），离最近本方城市每多 1 格扣 0.5×超出²，每少 1 格扣 1.0×不足²；日本改为 4。也就是用软偏好把间距拉向 5。
- AMT、District & Wonder Planner：不选城址（只读地图上的市中心钉）。

## 5. 实测：最远距离 4–8 的选城址场景

命令（在仓库的一份临时拷贝里给 `tests/compare/cmp_sdp.lua` 临时加了 `_D<n>` 变体，覆盖 `request.sites.distance`，并把每个城址的 `OwnDistance`、`SiteDistance` 写进结果；仓库本身没改）：

```
python3 -I tools/sdplock.py heavy issue84-sitesD -- node tools/compare.mjs -s '^C[0-9]' -p sdp \
  --add sdp:STANDARD_D4,sdp:STANDARD_D5,sdp:STANDARD_D6,sdp:STANDARD_D7,sdp:STANDARD_D8 \
  --only sdp:STANDARD_D4,sdp:STANDARD_D5,sdp:STANDARD_D6,sdp:STANDARD_D7,sdp:STANDARD_D8 -j 4 --out sitesD.jsonl
```

12 个 `C` 场景（中期首都，选 2 个城址，学院、圣地、商业中心），标准档，60 次运行，本机 364 秒，0 失败。D8 的 12 个方案与入库的 `tests/compare/results/sites_v150.jsonl`（STANDARD）完全相同。

| D | 裁判城址分合计 | 比 D8 | 地块值 | 区域潜力 | 重叠格合计 | 每个城址离最近的城（本方城市或另一城址） | 求解耗时中位数（离线秒） | 场景 低/同/高 |
|---|---|---|---|---|---|---|---|---|
| 4 | 786 | −6.7% | 647 | 139 | 259 | 4：24 个 | 17.8 | 9/0/3 |
| 5 | 840 | −0.2% | 675 | 165 | 144 | 5：24 个 | 21.1 | 5/1/6 |
| 6 | 835 | −0.8% | 685 | 150 | 85 | 5：8，6：16 | 23.5 | 5/2/5 |
| 7 | 849 | +0.8% | 698 | 151 | 33 | 5：3，6：8，7：13 | 26.0 | 3/7/2 |
| 8 | 842 | 0 | 695 | 147 | 30 | 5：4，6：6，7：8，8：6 | 28.0 | — |

读法：
- 求解器几乎总用满 D：D8 时 24 个城址里 14 个离最近的城 7–8 格；D5 全部 5 格，D6 三分之二 6 格。所以默认 D 就是默认间距。
- 裁判的城址分（每城最好 8 块地 + 区域潜力）在 D5–D8 之间差不到 1%，D4 才明显低（−6.7%）。裁判只看早期能用的 8 块地，不管 3 环用满后的地块，也不衡量“留出的地方还能再放几座城”——这正是 issue 的理由，裁判量不到。
- 重叠格（两城 3 环共用的格）：D8 平均每场景 2.5 格，D6 7 格，D5 12 格，D4 22 格。
- 耗时：候选范围是 K × D，D 小了候选少；离线秒数只作相对比较：D6 比 D8 少约 16%，D5 少约 25%。

## 6. 方案与工作量

- 方案 A：默认 6（中间隔 5 格，两城 3 环只碰边），范围 4–15 不变；给“最远距离”加悬停提示，写明按两城市中心之间的格数算、最小是 4（中间隔 3 格）、求解器通常用满这个距离。
- 方案 B：默认 5（按面板的数直接读“5 格”）。更密，重叠多一些（每对 4–8 格）。
- 方案 C：默认不变，只加悬停提示。
- 方案 D（不建议现在做）：仿 EP 加“理想间距”软偏好进评分。改评分，要重新调参、重跑对比，工作量大；而实测表明上限本身就决定了间距，用不着。

附带：K 和 D 不记在存档（#57 只记了权重、档位），建议一并记住。

工作量（A 或 B）：改 3 处默认值（`SDP_PageSites.lua:42`、`SDP_SiteSolver.lua:41`、`SDP_Sites.lua:117`），中英悬停提示各一条，`docs/multicity-design.md` 3.1 和第 11 节、中英安装说明、CHANGELOG；离线 `spec_panel` 加默认值断言；游戏内 `test_sites` 跑一遍。约半天。对比场景 `C` 和压力测试都显式传 8，可以不动（介绍页的“选城址 · 3 个、8 格内”照旧）；若要跟默认一致，再重跑 `sites.jsonl` 和压力测试。记住 K、D 另加约 1 小时。

版本：默认值变了，同样的设置给出不同方案 → 第二位（下一个 v1.6.0）。

## 7. 决定与实现（2026-10-26）

- 维护者先定方案 A（默认 6），随后改为默认 **5**，并定“所有涉及这个参数的地方都同步为 5”（DracoYus 在 issue 里也认为按 8 测的结果对新默认没有意义）：离线对比的 `C` 场景（`cmp_scenarios.lua`，`sites.jsonl` 用 `refresh_results.py` 重跑）、压力测试的选城址一步（`stress.py`，介绍页和自测报告的行标题从结果里读距离）、游戏内和离线测试里写死的 8 都改成 5。其余照方案 A：“最远距离”加悬停提示（中英各一条，耗时比较按上表：D8 比 D5 约多三分之一），新城数量 K 和最远距离 D 记在存档里（`SDP_PageSites.lua` 的 keeper `Extra`，`SDP_UI.SettingFields` 让 Extra 也能是带范围的数）。
- 求解器、候选范围在请求里没给 D 时也按 5（`SDP_SiteSolver.lua`、`SDP_Sites.lua`）。
- 测试：`spec_panel` 断言默认 5；`spec_settings` 读档恢复 K、D，经按钮改回默认不写，越界回默认。
