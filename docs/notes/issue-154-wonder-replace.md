# #154 开着“替换本模组之前的钉”时奇观被漏掉

## 原因

主会话 2026-10-29 在游戏里复现（[Issue 评论](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/154#issuecomment-6484050253)）：单城页选剧院广场、圣地（必建）和圣索菲亚大教堂，不开替换求解并打钉；再打开替换、重新求解，方案里没有奇观，`Unplaced` 里也没有。

- 打开替换时，请求带 `IgnorePins`（本模组为这座城打过的钉），求解器和 overlay 当它们不存在（`SDP_Overlay.HidePins`、`SDP_City.ScanOptions`）。
- 奇观的状态来自 `SDP_Wonders.Pinned` / `SDP_Wonders.List`，它们只看地图上有没有这个奇观的钉，不看 `IgnorePins`：奇观仍是 `PINNED`，面板的 `SelectedWonders` 把它去掉，`SDP_Multi` 也不给它留槽位。
- 结果：奇观不规划，它的旧钉又被 overlay 隐藏，旁边的剧院广场少了奇观给的相邻加成（+3 → +1）；打钉时旧的奇观钉被当作“替换”删掉，新方案里又没有奇观，奇观钉就没了。

## 修法

- `SDP_Wonders.Pinned(playerID, ignore)`、`SDP_Wonders.List(playerID, ignore)` 多一个可选参数 `ignore`（`{ [钉 ID] = true }`）：被替换的钉不算，这个奇观的状态回到“未打钉”。
- `SDP_Multi.NewSession` 两处取奇观列表时传 `options.ignorePins`（单城页带奇观时也走 `SDP_Multi`）。
- 单城页（`SDP_Panel.lua`）：`ReplacedPins()` 给出被替换的钉（替换关着时为 nil），`SelectedWonders`、奇观列表（`PopulateWonders`）、“为奇观补区域”（`SDP_UI.WonderNeeds`）都用它；`SetReplace` 和打钉、撤销后（`UpdateReplaceLabel`）重画奇观列表，所以开关一变、钉一变，列表里的状态跟着变。
- 多城页（`SDP_PageMulti.lua`）：同样的 `ReplacedPins()`，用于 `WonderTypes`、补区域提示和奇观列表；奇观列表抽成 `ShowWonders()`，`SetReplace`、`Place`、`Undo` 后都重画（以前打钉后列表里的状态要等下次刷新才变）。
- 不涉及遍历顺序：`ignore` 只做查表，奇观列表照旧按时代、造价、类型排序。

## 测试

- 离线 `tests/offline/spec_wonder_replace.lua`（新）：单城页和多城页各一项，经面板自己的钩子（`SetWonder`、`SetReplace`、`Solve`/`RunTask`、`PlacePins`/`Place`）：打过钉后不开替换，奇观算已打钉；开替换后奇观又被选上，方案里有它，和第一次的方案完全相同（剧院广场的分也相同），再打钉后地图上正好一个奇观钉。旧代码上两项都失败（单城页“with replace the wonder is chosen again”；多城页去掉列表状态的断言后在“the wonder is in the plan”失败）。
- 游戏内 `tests/test_features.lua` 加“replace plans a wonder again when its only pin is one being replaced (issue 154)”：剧院广场、圣地加一个不需相邻区域的空闲奇观，打钉、开替换再求解，方案与第一次相同、每项的分相同，打钉后 DMT 认得新的奇观钉。排进 2026-10-29 夜间队列。
- 本机跑过：`validate.py`，`spec_wonder_replace.lua`、`spec_panel.lua`、`spec_support.lua`；整套离线测试在第二台机器上跑。

## Codex 审查（PR #158，第一轮两条，都属实）

- **测试没经控件回调**（PRRT_kwDOVS5Ar86xXwF2）：`spec_wonder_replace.lua` 改成经控件自己的回调：奇观从“添加奇观”下拉的条目点选（`WonderPull` / `MultiWonderPull` 的 `_entries`），替换和提醒钉开关用勾选框 `Toggle()`，求解、打钉、撤销点按钮（`SolveButton`、`PlaceButton`、`UndoButton` 及 `Multi*` 版）。区域列表、档位和收尾的取消奇观仍用面板钩子准备（不是这次修的入口）。在修复前的源码上三项都失败。
- **多城页求解按钮不跟替换开关变**（PRRT_kwDOVS5Ar86xXwF5）：共享列表（`m_planFor == "ALL"`）只选了一个已打钉的奇观、没有结果时，`P.SetReplace` 只调 `ShowWonders()`，`ClearResult()` 在没有结果时不重画，按钮停在旧状态（开替换后仍灰着，或关替换后仍可点）。修法：这一支再调 `UpdateEstimate()`（它更新按钮和提示），`UpdateEstimate` 改成前置声明的局部函数。新测试“the solve button follows the replace switch for a pinned wonder”：只选奇观、打钉、开关替换三次，每次查按钮和提示；旧代码在“replace off: ... nothing to plan”失败。单城页没有这个缺口：`SetReplace` 总是调 `UpdateEstimate()`，打钉、撤销后调 `UpdateButtons()`。
- 本机跑过：`validate.py`；`spec_wonder_replace.lua`、`spec_panel.lua`、`spec_support.lua`、`spec_citychips.lua`、`spec_target.lua`、`spec_harborchoice.lua` 全过。游戏内测试没改。
