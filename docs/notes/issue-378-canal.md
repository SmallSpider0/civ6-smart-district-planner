# #378 运河放到游戏不允许的格子上

状态：现行（第一步）；第二步的真实规则标定待游戏内探针，见文末。

## 报告与复现

创意工坊评论（2026-11-23，英文）：玩家说模组总把运河放在不合法的格子上，只能手动放。本机没有游戏，未做游戏内复现；离线用例把问题钉住（`tests/offline/spec_canal.lua`，其中 4 条在旧代码上失败）。

## 原因（读代码所得）

运河"必须连通水域"只在 GameCore DLL 里，DMT 的 `CanPlacePin` 不查（[pitfalls](../pitfalls.md) 坑 27）。本模组原有的一层复核是 `SDP_City.EngineRefused`：向引擎要该区域的可建格（`CityManager.GetOperationTargets`，游戏放置透镜用的就是它），列表外的本城格判不可放。两处缺口正好覆盖规划场景：

1. `SDP_Overlay.EngineRefuses` 在 `plot:GetOwner() ~= playerID` 时直接放行——城 2/3 环还没买下的格、选城址页的全部格从不复核。
2. `SDP_City.EngineRefused` 在引擎给出空表时返回 nil，交回 DMT。运河 `PrereqTech = TECH_STEAM_POWER`，规划期通常未解锁，引擎必然空表。

规则库（本机 `Cache/DebugGameplay.sqlite`，只读）确认：`Districts_XP2.Canal = 1`；`District_ValidTerrains` 给运河列出草地、平原、沙漠、冻土、雪地（无丘陵）；`Districts` 表 40 列里没有任何距离或水域字段。所以"连通水域"只能自己判，且只能用数据驱动的方式认出运河。

## 做法（第一步：只拦"肯定不可能"）

| 位置 | 内容 |
|---|---|
| `SDP_Rules.IsCanal` | `Districts_XP2.Canal`（与 `AutoKind` 用 `PreventsFloods` 认堤坝同理，不写类型名） |
| `SDP_Rules.ValidTerrains` | `District_ValidTerrains`，按 `GameInfo` 缓存；没有行就返回 nil |
| `SDP_City.WaterLinkPossible` | 六邻有水域、城中心、已建运河 → true；临河、邻格越界 → true（拿不准就放行） |
| `SDP_City.CanalCannotLink` | 运河 + 地形在表里 + 陆地 + 无任何可能连通 → true |
| `SDP_Overlay.EngineRefuses` | 已拥有格：引擎有列表就以引擎为准；引擎没答案或格未拥有：非运河放行，运河走本地判定，并加一条"规划中的城中心钉算连通端"（城中心在一次求解内不动） |

**不做**：规划中的**运河钉**不算连通端。`SDP_Board` 的合法性记忆假设"只取决于本格与固定地图"，纳入要改记忆键，属另一次改动。

## 测试

`tests/offline/spec_canal.lua`（9 条）：规则识别、未拥有内陆格被拒、水/城中心/已建运河放行、城中心钉放行、丘陵/临河/无格放行、非运河不变、引擎有列表时以引擎为准、未解锁仍被拦、求解器不选内陆格。

旧代码上失败 4 条：规则识别（函数不存在）、未拥有内陆格（旧代码 `CanPlace == true`）、丘陵/临河用例（函数不存在）、未解锁（旧代码放行）。`world.lua` 为此新增：`spec.canal` 时才加 `DISTRICT_CANAL` 行、`Districts_XP2.Canal`、`District_ValidTerrains`，另加 `TECH_STEAM_POWER`。

## 待办

- `tests/bench/probe_canal.lua`（游戏内）：给全部科技、城市拥有 3 环，逐格对比引擎可建格与本地判定，标定"两侧相对临水 / 水 + 城中心 / 接入已建运河 / 湖算不算 / 河算不算 / 两格新运河成链 / 地图边界"，再收紧 `CanalCannotLink`。本机没有游戏。
- 用真实存档复核 [25-baseline-real-games.md](25-baseline-real-games.md) 的运河 22/9/15 组：新规则是否覆盖被引擎拒绝的全部、是否误杀引擎允许的。
- `tools/compare.mjs -p sdp` 开发集（本机缺 DMT/AMT/EP 源码与 `.cache`）。
