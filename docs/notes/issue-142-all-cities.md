# #142 多城页规划全部城市

## 要求与决定

多城页原来最多 8 座城一起规划（`SDP_Multi.MAX_CITIES`）。维护者 2026-11-02 定下要做“全部城市”；合作者问过城多时怎么分组。两种做法用实验比：

- **A 分组**：全部城市都参与，超过一定座数时按位置分成相邻的几组，轮流规划；规划一组时其他城的区域留在原处、作固定邻居（两组交界处的城也能和邻组的区域凑在一起）。
- **B 只放开上限**：全部城市放进一次搜索。

<!-- RESULTS -->

## 实现

- `SDP_Multi.Participants` 不再截断，没有上限。
- `SDP_Multi.Groups(participants, size)`：组数 = ⌈n / size⌉，每组目标大小 = ⌈剩下的 / 剩下的组数⌉（各组大小差不多）。每组从剩下的城里离其他城总距离最大的那座开始（先切边上的），再逐个加入“到组里最远一座的距离”最小的城（同距离比距离和、再比序号）。确定，不用 `pairs()`。
- `Session:RunGroups`：先逐城规划全部城市（和原来的起点 1 相同，作为“不比逐城差”的参照 `FirstGain`），再按组轮流搜索 `GROUP_PASSES` 遍：`SetFocus(group)` 把别组的区域固定在当前最好方案的位置，只动本组的槽（`SDP_Search.Active`、`ActiveGroups`，局部搜索、踢动、类型互换都只碰本组），每组用档位的完整预算。最后 `Repair`。
- `Continue`（“再算一会儿”）在分组时再轮一遍。
- `EstimateUnits`：分组时 = 遍数 × 组数 × 一组的估计。
- 面板：城市格子不再变暗；标题右侧加 **全部城市**（`P.AllCities`），全都选上时变灰。
- **一条河一个堤坝**：全部城市参与后，两座城共用一条河很常见，求解给两座城都放了堤坝，DMT 不认第二个（`IsValidDamPosition`：每条河的泛滥平原只能有一个堤坝）。`SDP_Board` 按格子记合法性，看不到两个规划中的堤坝互相冲突；原来靠最后的完整评估发现，结果标为不一致。现在 `SDP_Search` 读 `Districts_XP2.OnePerRiver`，按 `RiverManager.GetRiverForFloodplain` 记每个候选格的河，同一条河上放了两个这种区域的布局判为不合法。离线假世界加了河（相连的河流格）和这条规则；`spec_multi` 的“one dam per river”在旧代码上失败（不一致）。

## 测试

- 离线：`spec_multi`（分组、无上限、一条河一个堤坝）、`spec_citychips`（经 **全部城市** 按钮的回调选上全部，求解分组、不比逐城差）。
- 游戏内：`tests/test_allcities.lua`（城和城址钉多于一组时）。2026-11-02 在新对局（首都 + 12 个密集城址钉，13 座）通过；`test_multi`、`test_citychips`、`test_incremental` 通过。

## 还没做

- README、创意工坊简介、`report/similar.py`、`docs/notes/planner-comparison.md` 里“最多 8 座”留到发版准备时改。
