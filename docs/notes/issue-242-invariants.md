# #242 方案不变量检查

2026-11-03。离线测试的每次求解后检查方案必须满足的条件。

## 做了什么

- `tests/offline/invariants.lua`：检查函数，`tools/offline_tests.mjs` 把它装进每个 Lua 状态（全局 `SDP_Invariants`），第一次调用 `SDP_Solver.NewSession` / `SDP_Multi.NewSession` 时给会话的 `Result` 包一层，所以 spec 直接调 `Solve`、`SolveNow`、`Continue`、`SDP_Task` 任务，都会查到。检查不抛错（求解在 `pcall` 里，抛错会变成求解失败），查到的记下来，测试结束时由运行器判失败。
- 检查项（名字是 `OptOut` 用的）：`count`、`unique`、`onecity`、`plot`、`reach`、`wonder`、`parts`、`unplaced`，说明在文件头。规则从测试世界的 `GameInfo`（`MaxPerPlayer`、`OnePerCity`、`RequiresPopulation`、`AdjacentDistrict`、`DistrictReplaces`）、地图、城市和地图钉读，不读求解器内部的槽位和归属表；城市能拿哪些格用扫描（`SDP_City.Scan`、`ScanSite`）的候选格和 `Reach`，和游戏一样。奇观要挨的区域只认记给的那座城自己的：它建的（`scan.Built`）、它的钉（`SDP_City.OwnPins`）、方案里记给它的。
- `tests/offline/spec_invariants.lua`：每项检查都用一个改坏的结果确认能查出来，另查两个求解器的结果都经过检查、`OptOut` 要写原因。

## 结果

- 在 #240 之前的提交（`4e4e734^`）上：`spec_multi.lua` 里两个原有测试（“a wonder counts only its own city's district (issue 45)”、“wonders: legal places, …”）被查出 `[wonder]`：大图书馆、斗兽场记在城址 A 下，A 旁边没有学院、娱乐中心。就是 #238。
- 当前 `main`（4e4e734）：全部离线测试通过，没有查出问题，没有测试需要关掉检查。
- 检查不调假 DMT，`World.Calls` 不变，基准的计数不受影响；耗时和关掉检查时差不多（在噪声内）。
