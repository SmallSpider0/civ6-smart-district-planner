# #327 测试基础设施

#327 调研后“建议直接做的”几项分三个分支做，各写自己的小节。

## 第 1、3 项：面板放回默认、页面装不下就失败（#325 一起修）

分支 `mac/test-reset`。只改测试、测试工具和面板里不改行为的测试入口与自检；方案和面板外观不变。

### 做法

- **`SDP_Panel.Defaults()`**：停掉计算、退出窥视、清掉“结果已算好”的标记和地图预览，三个页签各调自己的 `Defaults`，切回单城页，重排窗口。面板开着还是关着照旧；本模组的钉不动（撤销照旧由测试自己做）。
  - 设置（权重、开关、档位、预设、折叠、单城和多城的奇观、选城址的数量和距离、区域状态等存进存档的项）走存档读回的同一条路：`SDP_Settings.Keeper` 加 `Defaults()`，就是 `Decode(nil)`（存档里什么都没有时）再 `Apply`。先 `Restore` 一次再套默认，免得之后第一次读存档把改过的设置又读回来；套完 `Remember` 写回存档。没有另写一套默认值。
  - 不进存档的状态由各页签清空到模块初值：单城页的城（回到选中的城或首都）、区域状态、各城的数量、好位置图；选城址页翻转过的勾；多城页的共用清单、各城自己的清单、奇观放哪座城、中心城和参与城的开关。三页的方案都清掉。
- **`SDP_UI.CheckFit(name, page, body)`**：三个页签的 `FitPage` 排完版后调一次（多城页在“城的格子缩行”循环之后，中间几次不算）。主体（底下是求解、打钉按钮）比页面高时经 `SDP_UI.Log` 写一行 `SDP_LAYOUT_OVERFLOW <页签>: the body N does not fit the page M`；隐藏的页签不查（切过去时会重排）。
- **`run_tests.py`**：每个文件的 `@setup` 之前在 `SDP_Panel` 状态执行 `SDP_Panel.Defaults()`（单独一次 exec，不计入 `@max_seconds`）。测试输出里出现 `SDP_LAYOUT_OVERFLOW` 时，把它后面那项测试记为失败；放回默认时出现的记为这个文件的失败；`SDP_Panel` 状态里的 fixture 输出它也算 fixture 出错。`--shortest-window`：每个文件开头把 `SDP_UI.WindowHeight` 换成返回 `WINDOW_MIN` 再 `FitWindow`，整个运行结束（含出错）后换回、按屏幕重排；`--rulesets` 会传下去。
- **`shots.py stage`**：执行脚本前先撤销本局本模组打的钉（撤到底），再 `SDP_Panel.Defaults()`；`--as-is` 跳过。`tests/shots/sites.lua` 去掉逐个设回默认状态的那行；`multi.lua` 不再沿用选城址页留下的方案，自己算（与 `stage sites` 同样的设置）。

### 删掉的手写重置

- `test_ui.lua`：`Reset()` 改为先 `Defaults()`，删掉重设权重、清除开关、地块、档位的几行；删掉 #323 加的 `ClearMulti()`（切两次“提醒钉”来清多城方案），改为断言 `Reset()` 后多城页没有方案；#320 那项结尾的逐项还原换成 `Defaults()`。
- `test_features.lua`：`Reset(districts)` 改为先 `Defaults()`，删掉切页签、清奇观、关“替换”、设档位；`Finally` 里关好位置图、关“替换”、清奇观换成 `Defaults()`；覆盖范围那项的 `Solve` 同样改。
- 没删的：其余文件测试之间的还原（`SetTier(tier)`、`SetExisting(id, nil)`、`ApplyPlan({})` 这类）。`Defaults` 只在每个文件开头自动调，同一文件里后面的测试仍靠前面的测试还原；逐个改成 `Defaults()` 要逐项看它是否依赖前一项留下的状态，这次不动。`test_improve.lua` 的 `Setup()` 找的是地图上的格，不是面板重置。

### 测试

- 离线 `tests/offline/spec_defaults.lua`（走控件回调）：三个页签经格子、箭头、勾选框、下拉、城的格子改一遍，多城页算出方案，好位置图打开，窥视；`Defaults()` 后三页的设置、清单、城、方案和新开时一样，存档只剩预设名，`Refresh` 不会读回旧值；计算中、面板关着时调也行；主体比页面高时每个页签各写一行 `SDP_LAYOUT_OVERFLOW`，装得下时不写。旧代码上没有 `Defaults`、不写这行，三项都失败。
- `tests/tools/test_run_tests.py`：放回默认在 `SDP_Panel` 状态、在 `@setup` 之前执行；`SDP_LAYOUT_OVERFLOW` 让它所在的那项（或放回默认这一步）失败；`--shortest-window` 先固定窗口再放回默认，跑完换回。旧代码上都失败。
- 整套离线测试（第二台机器）：375 项全过。
- 游戏内（2026-11-07，周六，macOS，典藏版账号）：`run_tests.py --rulesets all` 原版 138 过 10 跳过、迭起兴衰 143 过 5 跳过、风云变幻 144 过 4 跳过，0 失败。跳过的都是要多城后期存档、或该规则集没有的内容（全部城分组、政府广场、阿耳忒弥斯神庙等）。
- `--shortest-window` 在风云变幻跑整套：144 过 4 跳过，没有一行 `SDP_LAYOUT_OVERFLOW`（窗口 640、页面 540）。手动把单城页压到 250 时日志出现 `SDP_LAYOUT_OVERFLOW SINGLE: the body 338 does not fit the page 250`。
- #325：整套测试之后，在同一局里先把单城页科技值权重改成 3、关掉换格，再 `shots.py stage single`：方案学院 (17,37)、堤坝 (16,37)、商业中心 (17,39)、工业区 (17,38)，+8，与 #325 里新开一局的结果相同，权重和开关回到默认。
