# #178 重新选中同一座城再打开面板不跟随（2026-10-30）

DracoYus 报告：选中城市后打开规划器，不再跳到这座城。

## 原因

不是近几版改出来的：`Open` 和 `FollowSelection`（#63、#76）从 v1.5.0 起没改过。`FollowSelection` 只在打开面板的那一刻看地图上选中的城，和“上次打开面板时选中的城”（`m_followed`）比，同一座就当作“还是上次那次选择”，不跟随。

所以只要两次打开面板之间没有在“什么都没选”时开过面板，重新选中同一座城就被当成旧的选择：

1. 选中城 A，打开面板：跟到 A 的单城页；
2. 在面板里换到城 B 或多城页，关面板；
3. 在地图上取消选择、过几回合，再选中 A，打开面板：停在 B 或多城页。

后台计算中选了一座城（这次选择按设计跳过）、算完后再选同一座城打开，也是一样。默认测试对局只有首都时，城市只有一座，看不出来。

离线复现：`spec_citychips.lua` 的 “selecting the same city again is followed (issue 178)”，在旧代码上第一条断言就失败（上一个用例在计算中选了城 3，这次重新选城 3 不跟随）。

## 修法

`SDP_Panel.lua` 订阅 `Events.CitySelectionChanged`（游戏本体 `CityPanel.lua`、`ProductionManager.lua` 用的同一个事件）：本方的城被选中（`isSelected`）时记一个标记 `m_reselected`。`FollowSelection` 在打开面板时取走这个标记：选中的城和上次一样但标记在，也跟随。没有新的选择事件时照旧（玩家在面板里换的城、页签不被抢回）；后台计算中照旧跳过，标记也清掉。

## 测试

- 离线 `spec_citychips.lua` 新用例，经 `LuaEvents.SDP_OpenPanel`/`SDP_ClosePanel`、城市下拉条目和页签按钮的回调：重新选中同一座城跟随且回到单城页、多城页以它为中心；没有新选择时不抢回玩家换的城；面板开着时选的城下次打开时跟随；别人的城不跟随。旧代码上失败，新代码通过。
- 游戏里 `UI.SelectCity` 之后，`Events.CitySelectionChanged` 在同一次 Tuner 调用里还没送到，下一次调用时已送到（2026-10-31 探针：选中后 0 次，下一次调用时 1 次；取消选择而原来没选城时不发）。所以游戏内测试把“选中、打开、换到多城页、关上、取消选择、再选中”放在 `@setup`（`tests/fixtures/reselect_city.lua`，SDP_Panel 状态），`tests/test_reselect.lua` 再打开面板查单城页、城市和多城页中心，再查没有新选择时页签不变。旧代码上失败（停在多城页），新代码通过。
- `test_citychips.lua` 原有的跟随用例每次选城前先在没选城时开关一次面板（`Unselect`），正好绕开了这个问题，所以以前没测出来。
- 2026-10-31 macOS 游戏内：`test_reselect.lua`、`test_citychips.lua`、`test_panel.lua`、`test_tabs.lua` 11 项全过。
