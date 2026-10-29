# #152 去掉“港口、商业中心分城”开关

合作者 DracoYus 提出（#152）：#106 定下“两者都是候选、一座城只挑一个时按城挑”（靠海无淡水的城挑港口，其他城挑商业中心）以后，分城开关关掉也没有用处。维护者 2026-10-29 定：去掉。

## 做了什么

- 面板：单城页、多城页的开关（`ApartBox`/`ApartCheck`/`ApartLabel`、`MultiApart*`）、`SDP_UI.ShowApart`、`SetApart` 钩子、设置项 `APART` 都删了；两页的请求固定 `Apart = true`。
- 求解器保留 `Request.Apart == false` 的分支：离线测试（`spec_apart.lua`、`spec_harborchoice.lua`）和游戏内 `test_feedback2.lua` 用它对照“不分城时按分数会挑什么”，面板不再发出这种请求。
- 存档里 v1.6.1 及以前记的 `APART=0`：`SDP_Settings.Decode` 把不认识的键丢掉，读档后照样分城（`spec_settings.lua` 测）。
- 文字：删掉只给开关用的 `LOC_SDP_APART_SHORT`、`_SHORT_ANY`、`_TOOLTIP`；开关悬停里“一座城不同时挑、已有一个就不挑另一个、凑不够数量或都必建才同城”的说明挪到结果里“同城”那一行的悬停（`LOC_SDP_RESULT_TOGETHER_TOOLTIP`，前面仍是 `LOC_SDP_APART_RULE` 那句规则）。
- 测试：`spec_panel.lua` 新测“两页都没有开关、请求总是分城”，`spec_settings.lua` 测旧存档值被忽略，两者在旧代码上失败；`realclick.py` 删掉点分城开关的 4 步。

## 还没验证

游戏内：`tests/test_feedback2.lua` 等和真实点击排在夜间队列。
