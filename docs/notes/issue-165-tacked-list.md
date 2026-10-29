# #165 已有的区域不再当候选

合作者报告：多城页某座城自己的区域清单里，已经放下但没建成的区域还在当候选。

## 复现（离线，`tests/offline/spec_tacked_list.lua` 的世界）

城 1 有一个在建的剧院广场，城 2 有玩家自己打的圣地钉（城 2 的格上），城 3 什么都没有。

- 多城页，城 1、城 2 各自的清单：剧院广场、圣地的格子都显示“候选”，没有变暗。求解器自己会跳过它们（`SDP_City.DistrictStatus` 的 BUILT、`SDP_Multi` 的 `pinnedHere`），所以多城方案里没有第二个，但数量上限 = 已有 + 候选数，把它们也数进去，数量能调得比能规划的多。
- 单城页，城 2：圣地的格子显示“候选”，求解时照样从候选里挑它（`SDP_Solver` 的候选只排除已建，不排除已打钉），方案在原来的钉之外再放一个圣地，打钉后城 2 有两个圣地钉。这违反需求约束 7（已有的钉不动，作为固定邻居）。

## 原因

- 多城页网格的状态只取全帝国上限（`SDP_City.EmpireBuilt`），没用这座城的已建状态；清单发给求解器时用了 `BuiltHereStatus`，但没算已打钉的种类。
- 单城页的状态（`SDP_City.DistrictStatus`）只有已建、不能同城、帝国上限，没有“已为本城打钉”。#144 把已打钉的种类算进“已有”的个数，但清单里它还是候选。

## 修改

- `SDP_City.TackedStatus(playerID, cityID, districts, ignore)`：这座城有钉（`SDP_City.OwnPins`，正在被替换的除外）、没建、一城只能有一个的区域种类，返回 `TACKED`。和 `HaveOf` 共用不扫格子的 `PinScan`。
- 单城页：`m_scanStatus` 是原来的 `DistrictStatus`，`UpdateHave` 每次（选城、打钉、撤销、替换开关、预设）把 `TackedStatus` 并进 `m_status` 并重画网格。热力图下拉仍按 `m_scanStatus`，已打钉的种类照样能看热力图。
- 多城页：`StatusOf(key)` = 帝国上限 + `BuiltHereStatus` + `TackedStatus`，网格（`m_planFor` 是某座城时）和这座城清单的请求都用它；打钉、撤销、预设后经 `ShowHave` 重画这座城的网格。
- 文本 `LOC_SDP_STATUS_TACKED`：已打钉 / Tacked。

结果：这些区域变暗、不能点，不当候选也不当必建（模板设成必建的也略过）。勾了“替换本模组之前打的钉”时本模组的钉不算，照常重新规划；玩家自己打的钉一直算。

#144 写的“某种被钉过、这次又设为必建的会重新规划、只算一次”不再出现在面板上：设为必建的已打钉种类现在被略过，和多城共用清单的“本城已有它的地图钉”一致。`SDP_City.HaveCount` 的这条规则保留（其他调用方仍可传）。

求解器（`SDP_Solver`、`SDP_Multi`）没改：面板不再把这些种类发过去。所以不跑开发集对比。

## 测试

- `tests/offline/spec_tacked_list.lua`（5 项，经面板控件）：在旧代码上 5 项全失败，改后全过。
- `tests/test_tacked_list.lua`（游戏内）：建学院（`build_campus.lua`），在首都的格上打一个玩家自己的钉，查单城页和多城页这座城自己的清单里“已建”“已打钉”，删钉后恢复。
- 旧测试里“已打钉的学院不勾替换再规划一次，放到别处”的断言改成“学院显示已打钉、没有要规划的”（`tests/test_pins.lua`、`tests/test_features.lua`、`tests/offline/spec_panel.lua`）；`spec_panel.lua` 里玩家改过名的学院钉以前留在地图上，现在用完删掉，免得后面的测试里学院一直是“已打钉”。`spec_target.lua` 里“已建的学院在这座城的清单里设为必建”改用模板设（格子已变暗点不动）。
- 2026-10-30 macOS：游戏内整套（罗马、固定种子、首都）127 项通过、4 项跳过（要多城后期存档的）；离线整套在第二台机器上跑，结果写在 PR 里。
