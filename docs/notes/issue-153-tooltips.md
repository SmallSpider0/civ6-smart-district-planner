# #153 面板悬停提示改写

方案和逐条对照表在 #153 的评论里（[方案](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/153#issuecomment-6484074696)、[维护者的决定](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/153#issuecomment-6484387903)），这里记实现。

## 定了什么

- 每个权重、开关、按钮一句话（要先讲清一条游戏规则时最多两句）：调高、调低或打开、关上后地图上的方案会怎么变。
- 不写实测的百分比、秒数、倍数；只留设置本身的值（预设的权重 `{1_K}`、多城默认最多 4 座）。“算得更久”“要手动切换”这类代价用一句不带数字的话。
- 英文按同样的规则改，意思和中文一致。
- 结果里的悬停照旧，只把总分悬停里的排序说明（`LOC_SDP_RESULT_RANKED`）缩成一句。
- 选城址页三个预设各加一句提示。
- “港口、商业中心分城”的两条（`LOC_SDP_APART_TOOLTIP`、`LOC_SDP_APART_RULE`）不动，#152（PR #157）去掉这个开关。

## 做了什么

- 改写 43 条（中英各 43）：方案表里改的 44 条减去分城的 2 条，加上 `LOC_SDP_RESULT_RANKED`。另把没被代码引用的 `LOC_SDP_WEIGHT_FEATURE` 里的“树林”改成游戏译名“森林”。
- 新键 3 个（中英都有）：`LOC_SDP_SITES_PRESET_BALANCED_TOOLTIP`、`LOC_SDP_SITES_PRESET_GROWTH_TOOLTIP`、`LOC_SDP_SITES_PRESET_DISTRICTS_TOOLTIP`。选城址的“均衡”没有开关、魅力默认不计，和单城的 `LOC_SDP_PRESET_BALANCED_TOOLTIP` 说法不同，所以单独一套键，和已有的 `LOC_SDP_SITES_PRESET_CUSTOM_TOOLTIP` 同一前缀。
- `SDP_UI.ShowPreset` 的 `spec.Tips` 可以是键前缀（字符串）；`SDP_PageSites.lua` 传 `"LOC_SDP_SITES_PRESET_"`。单城、多城仍传 `true`（前缀 `LOC_SDP_PRESET_`）。
- 写作规则：`docs/maintaining.md` 第 10 节原来的“开关提示分三段、收益写实测百分比、代价写耗时倍数”换成上面的规则；`sdp-issue` 第 4 节最后一条、`sdp-release` 第 1 节第 2 步（“tooltip numbers whose source changed”改成报告页的数字）、`sdp-offline-runs` 里两处“提示里的实测数字”同步改。`docs/workflow.html` 没写这条规则，不用改。
- 只为提示提供数字的记录（`docs/notes/27-fifth-feedback-land.md`、`29-issue-63-several-cities.md`、`issue-67-ui.md`）留着，各加一句“#153 起不再重跑”。`issue-87-dense.md`、`issue-90-sites-districts.md`、`19-coverage.md` 只是记录当时提示用了哪些数，没有承诺重跑，不改。
- 玩家文档：`docs/install-and-test.md`、`docs/install-en.md` 里“悬停看实测耗时、完整算法、收益和代价”的说法改成现在提示里有的内容。

- 合作者问能不能共用（[评论](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/153#issuecomment-6485094886)），[定的方案](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/153#issuecomment-6485137427)：意思相同的四条三个页签共用一个键。
  - 区域数量 `LOC_SDP_COUNT_TOOLTIP`（单城、多城、选城址），说“每座城”，选城址的新城没有已建的，同一句也对。
  - 区域状态 `LOC_SDP_STATES_TOOLTIP`（三页的“占人口名额的区域”和选城址的“规划”）。写之前核对了默认值：单城、多城的保护区默认不建（`SDP_UI.DefaultState`，魅力规则），军营、航空港默认在候选；选城址三个都默认不建（`SDP_Sites.DefaultState` + `SDP_Rules.Functional`）。三页不一样，所以句子不说“默认不建”，只说它们没有相邻加成、要建就点成必建，三页都成立。
  - 不占名额的区域 `LOC_SDP_STATES_OTHER_TOOLTIP`，半句注明选城址页没有“自动”。
  - 替换旧钉 `LOC_SDP_REPLACE_OWN_TOOLTIP`（单城、多城），不说“这座城”“这些城”。
  - 删掉的键（中英）：`LOC_SDP_COUNT_TOOLTIP_MULTI`、`LOC_SDP_SITES_PLAN_COUNT_TOOLTIP`、`LOC_SDP_SITES_STATES_TOOLTIP`、`LOC_SDP_SITES_STATES_OTHER_TOOLTIP`、`LOC_SDP_REPLACE_OWN_MULTI_TOOLTIP`。没有 Lua 或游戏内测试引用它们。

## 测试

- `validate.py`：0 错误。
- 离线 `spec_panel.lua` 新加 “issue 153: city sites presets have their own tooltips”：经下拉框每一项的按钮 `Click()`，查每项和选中后按钮上的提示是 `LOC_SDP_SITES_PRESET_<名>_TOOLTIP`。去掉 `SDP_PageSites.lua` 的改动时这一项失败（29 过 1 败），改后 30 项全过。
- 离线 `spec_panel.lua` 加 “issue 153: the tabs share the count, states and replace tooltips”：这几条提示写在面板 XML 的容器和标签上，脚本不设，所以直接读 `SDP_Panel.xml`（`offline_tests.mjs` 新给 spec 一个全局 `sdp_root`），查三个页签数量箭头、两个替换勾选框外层的提示键和各分组标签的提示键相同。旧 XML 上失败（`MultiCountLess` 拿到 `LOC_SDP_COUNT_TOOLTIP_MULTI`），改后 `spec_panel.lua` 31 项全过。
- 整套离线测试在第二台机器上跑（`remote.py run offline153b`）：211 过、0 败。
- 游戏内：工作日白天不开游戏，加了夜间队列 #34（中英文各跑 `test_ui`、`test_sites`、`test_settings`、`test_tiers`，并截悬停图看英文有没有截断）。

最终文字贴在 [#153 的评论](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/153#issuecomment-6485194512)。共用这轮的提交已推到 PR #159，并请 Codex 审（`codex_review.py request 159`）；自动合并没开，等审完。

## 没定或没验证的

- 英文提示在游戏里的显示（长度、换行）只在夜间队列里看，还没验证。
- 选城址三个预设的提示没写具体权重值（成长优先把食物、住房调到 2，区域优先把区域调到 2、战略调到 0）；要写的话可像单城预设一样传参数。
