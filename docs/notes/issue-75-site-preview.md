# #75 选城址：一套方案里逐个看各城址（2026-10-25）

调研和方案在 #75 的评论里；维护者定方案 A，待定问题都按建议：看地图时有“下一个城址”，用再点方案按钮切换（不加一排小按钮），多城页这次不做。

## 做法

| 位置 | 改动 |
|---|---|
| `SDP_PageSites.SelectSolution` | 点的是已选中的方案（面板开着）时不重画，镜头移到下一个城址（`P.NextSite`）；只有一个城址时移回它 |
| `SDP_PageSites.LookAtSite`、`CanStep`、`NextSite` | 记下镜头最后到的城址（`m_site`），下一个 = `m_site % 城址数 + 1`；新结果、换方案时回到 1（`P.Preview` 移镜头时） |
| 城址的结果行 | 点击走 `LookAtSite`，“下一个”从点的那个城址接着走 |
| 方案按钮的提示 | 城址不止一个时加一行 `LOC_SDP_SITES_SOLUTION_NEXT` |
| `SDP_UI.ResultRow`（三个页签共用） | 带坐标的行：提示第一行 `LOC_SDP_RESULT_LOOK`；`HoverArea` 里一层 `AlphaAnim ShowOnMouseOver` 包着方案按钮选中时的浅色底图（`Controls_Tab`；先试的 tan 按钮底图太深，深色字看不清，2026-10-25 截图）（游戏的城市横幅 `CityBannerInstances.xml` 的写法），没坐标的行隐藏它。只是一个 Grid，不接鼠标（坑 31） |
| `PeekNextSite`（`SDP_Panel.xml`） | 看地图时、选城址页、选中的方案不止一个城址时显示在“返回规划器”右边，点击 = `NextSite` |

结果行返回的 `ToolTip` 仍是原来的提示（测试和 DMT 比对用），只有控件上显示的多一行。

## 测试

- 离线：`spec_panel.lua` 的 “issue 75” 用例经控件自己的 `Click()`：两个城址时再点方案按钮镜头 1 → 2 → 1，点第 2 个城址的行后“下一个城址”回到 1，看地图时按钮显示、结束看地图后消失、单城页不显示，一个城址时提示里没有“再点一次”、看地图时没有按钮；“issue 67” 用例检查结果行提示第一行。
- 游戏内真实点击：`realclick.py` 的选城址步骤（见 PR）。悬停高亮的样子在真实点击的截图里看。
