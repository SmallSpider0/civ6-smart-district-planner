# #187 多城页：自定清单改回共用清单

DracoYus 报告：多城页给某座城设了自定清单后，无法回退到共用清单。

## 原因

功能其实一直有（`SDP_PageMulti.ApplyPlan(nil)`，从 d5344e0 起），入口是“套用模板”下拉框最后一项“改回共用清单”，只在“区域清单”选了某座城时出现。下拉框名叫“套用模板”，看不出里面有改回的选项，所以找不到。

## 改法

- “区域清单”下拉框右边加一个返回按钮（`MultiPlanShared`，游戏本体的 `BackButtonSmall` 样式，27×27），只在下拉框选的城有自定清单时显示；悬停写“改回共用清单：……”。点它调 `P.UseShared()`，只去掉这座城的自定清单，不动共用清单，下拉框仍停在这座城。
- 为了放下按钮，`MultiPlanPull` 从 200 宽改成 190；按钮所在的 Stack 加了 ID `MultiPlanStack`，显示或隐藏按钮后 `CalculateSize()`。
- “套用模板”里的“改回共用清单”保留。

## 测试

- 离线：`tests/offline/spec_panel.lua` 的 “a city's own list goes back to the shared list (issue 187)”，经下拉框条目、区域格子和按钮自己的回调。旧代码上失败（按钮不存在，“共用清单上不显示返回按钮”断言失败）。
- 游戏内：`tests/test_features.lua` 的 “...with the back button (issue 187)”，检查按钮显示、隐藏，以及屏幕位置在“区域清单”下拉框右边、“套用模板”下拉框左边，不重叠。
