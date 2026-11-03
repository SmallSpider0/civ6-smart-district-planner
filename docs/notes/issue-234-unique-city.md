# #234 多城规划里全帝国唯一的区域、奇观放哪座城

Issue：<https://github.com/SmallSpider0/civ6-smart-district-planner/issues/234>。调研评论（现状与方案 A/B/C）、合作者的决定（[1. 方案 A；2. 是；3. 需要](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/234#issuecomment-6593287772)）、主会话的转述都在 Issue 里。奇观记错城的 bug 另开为 #238（PR #240），本分支基于它。

## 定了、做了的

1. **共用清单里必建的市政广场、外交区**（`SDP_Multi.NewSession` 的分配段，`SDP_Multi.SolveNow`）：要它的城里，自定清单设了必建的先拿；同一类（自定 / 共用）里要的城多于剩下的名额时，按离中心城的距离排（同距按参与者顺序），取前 `HOST_TRIES = 4` 座记成 `HostChoices`。这次求解给 `UniqueTo` 指定的那座，没有就给最近的；`SolveNow` 再对其余几座各解一遍，用 `Session:Beats`（放下的奇观数、放下的格数、总分；同分留先算的，也就是离中心近的）留最好的。两种这样的区域时依次比较：第二种在第一种的最佳城定下后再比较，求解次数是 1 + Σ(候选城数 − 1)，不是乘积。之后照旧做 #182 的“补给的区域换城再算一遍”，基于留下的那个请求。
   - 中心城：请求的 `Center`（面板传 `DefaultGroup` 的中心，即打开面板时选中的城，没有就是首都）；不传时用首都。
   - 统计：留下的会话 `Stats.Hosts = { Tried, Calls, [区域类型] = 城 }`。`SDP_Multi.HOSTS_AGAIN = false` 关掉比较（离线对比、测试用）。
   - 悬停（`LOC_SDP_MULTI_LIMITED_ONE / AUTO / NEAREST`）和面板按同一规则：自定清单设了的城优先；一座就“只放在某城”，几座就“都试一遍”，超过 4 座说“离中心最近的 4 座”。文件头注释同步改了。
2. **自定清单优先**：同上，自定清单（请求里 `Plans[Key]` 存在）的城先分名额。
3. **奇观指定城**：请求 `WonderCities = { [奇观] = 参与者 Key }`。指定后：奇观槽位的 `Allowed` 只有那座城的格子、`City` 字段记下那座城；`Search:OwnDistrictNext` / `WondersServed` / `Singles` 只认那座城的区域；`WonderOwner` 直接返回那座城；缺区域时只补给那座城（`Missing` 按那座城判断），#182 的换城再算跳过指定了城的奇观。指定的城不参与时当“自动”。面板：多城页奇观标签换成 `MultiWonderChip`（标签 + `PullDown`，先例是游戏本体 `Options.xml` 的 `PullDownParameterInstance`），选项“自动”和每座参与的城，状态只在本次会话里记（和自定清单一样，不进存档）。

4. **“自动”的奇观按生产力选城**（合作者 [2026-11-03 选方案 A](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/234#issuecomment-6593790153)，提议见[这条评论](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/234#issuecomment-6593479288)）。`SDP_Multi.Production`：现有城 `city:GetYield(生产力)`（城市面板的每回合数字）；城址 = 市中心格 + `SDP_Land.Workable` 里生产力最高的 `PlanPopulation` 格（和 `ScanSite` 用的人口相同）。`NewSession` 按生产力从高到低（同分按参与者顺序）给没指定城的奇观填 `WonderCity`（记在 `AutoWonder`），跳过 `request.AutoSkip[奇观]` 座；建好搜索后，这样选的奇观没建成槽位（那座城补不了要挨的区域）或 `Singles` 说没有合法格时记 `AutoRetry`，`SolveNow` 的 `Prepared` 把 `AutoSkip` 加一、重建会话（还没求解，只多扫描一遍），直到都放得下或排名用完（用完就照旧在所有城里按总分放）。指定了城的奇观（包括自动选的）不做 #182 的换城再算。
   - `SDP_Multi.WONDER_BY_PRODUCTION = false` 回到按总分在所有城里放（#182 的测试 `spec_wonder_host.lua` 和游戏内 #182 测试用它）。
   - 离线世界新加 `City:GetYield`：给了 `production` 用它，否则 1 + 3 环内最好的“人口”格。
   - 悬停、求解前奇观标签下的补区域说明、安装说明中英文都改成按生产力选城。补区域说明仍只在“参与的城都没有这种区域”时显示（不提前算排名），求解后照旧写明补给了哪座城。

## 测试

- 离线：`spec_multi.lua` 四个 `issue 234` 测试（共用清单留最好的城、`HOST_TRIES` 只试最近的几座、自定清单优先、两座自定清单之间比较、奇观指定城和补区域、按生产力选城，最高的城没有河流放不下空中花园时换下一座），`spec_unique.lua` 两个面板测试（悬停、`Center`、自定清单，奇观下拉框经控件回调），都在 #240 的代码上失败过。`spec_wonder_memory.lua` 跟着改了多城页标签的实例名。
- 离线测试世界的数字（假 DMT，只用来说明）：学院 + 剧院广场 + 市政广场共用清单必建，4 座城各自放市政广场的总加成：S141 16、S211 16、C1（首都）17、C2 14；之前给列表第一座 S141，现在给 C1。
- 游戏内：`tests/test_multi.lua` 的 #28 测试改成“一个市政广场、每座城都试过、不比逐个指定差”，加了奇观指定给城址、自动按生产力选城（核对 `Production` 和城市面板的数字一致）的测试，#182 测试关掉按生产力选城；`tools/realclick.py suite` 加了奇观下拉框的真实点击。排进夜间队列，结果见 PR。
- 开发集 `refresh_results.py --check` 在第二台机器上跑，结果见 PR。
