# #89 改过预设后显示“自定义”：调研记录（2026-10-26）

Issue（DracoYus）：改了预设的权重后，下拉框显示“均衡（已改）”，数值来自哪个预设已经没有意义，应当显示一个“自定义”预设。

代码按 `main` 的 0b0d082 读，行号同此。

## 1. 现在的代码

### 预设与存档（#49、#57）

| 位置 | 内容 |
|---|---|
| `SmartDistrictPlanner/Scripts/SDP_Settings.lua:34-43` | 单城、多城页共用的 5 个预设：均衡（空表，即全部取默认）、科技（科学 1.5）、文化（文化 3）、宗教（信仰 3）、金币信仰减半（各 0.5）；`PRESET_ORDER` 第一个是默认 |
| `SDP_Settings.lua:63-73` `Encode` | 存档文本 = 版本 + `preset=名字` + 与该预设不同的项，如 `v1;preset=SCIENCE;YIELD_GOLD=2` |
| `SDP_Settings.lua:96-125` `Decode` | 版本不是 `v1` 整段不用（101 行）；不认识的预设名用默认预设（104 行）；只认字段表里的键，别的键丢掉；超范围的值丢掉 |
| `SDP_Settings.lua:129-135` `Changed` | 只比 `Preset = true` 的字段：全部权重列和开关；档位、收起与否不算 |
| `SDP_Settings.lua:193-202` `keeper.Use` | 选预设：把全部 `Preset = true` 的字段设成预设的值（预设没写的取默认），档位和收起不变 |
| `SmartDistrictPlanner/UI/SDP_Panel.lua:230-246` `SettingFields` | 权重列（233-234 行）和开关（237 行）都标 `Preset = true` |
| `SDP_Panel.lua:109-116` | 单城页记的开关：`ALLOW_REMOVAL`、`SWAP`、`REPLACE`、`REMIND`、`APART` |
| `SDP_Panel.lua:290-306` `SDP_UI.ShowPreset` | 下拉框按 `PRESET_ORDER` 建条目；按钮文字是当前预设名，改过时套 `LOC_SDP_FOLD_EDITED` 成“科技（已改）”（301 行）；按钮悬停是当前预设的说明；“恢复”只在改过时可点（305 行） |
| `SDP_Panel.lua:310-317` `SDP_UI.FoldSummary` | 设置摘要同样写“科技（已改）”，后面接不同于平常的设置 |
| `SDP_Panel.lua:1433-1446` `UpdateFold` | 单城页：摘要和下拉框都按 `m_keeper.Changed(m_preset)` |
| `SDP_Panel.lua:1450-1462` `SetPreset` | 选预设 = `keeper.Use`，清结果，刷新权重和勾选框，写存档 |
| `SDP_Panel.lua:2045` | “恢复” = `SetPreset(m_preset)`，即再选一次同一个预设 |
| `SmartDistrictPlanner/Scripts/SDP_PageMulti.lua:63, 66-71, 73, 506-531, 1028` | 多城页同单城页（开关少“允许砍伐”），自己的 `m_preset` 和“恢复” |
| `SmartDistrictPlanner/Scripts/SDP_PageSites.lua:46, 63-66, 69-72, 176-185, 209-221` | 选城址页：自己的三个预设（`SDP_Sites.lua:28-38`：均衡、成长优先、区域优先），没有“恢复”按钮；下拉框按钮只写预设名（184、221 行），**不写（已改）**；设置摘要写“（已改）”（71 行） |
| `SmartDistrictPlanner/UI/SDP_Panel.xml:107-108, 190, 300-301` | 单城、多城页的 `PresetPull`（170 宽）和 `PresetReset`（80 宽）；选城址页 `SitesPresetPull`（180 宽） |
| `Text/SDP_Text_zh_Hans_CN.xml:760-761`、`SDP_Text_en_US.xml:760-761` | `LOC_SDP_FOLD_EDITED`：`{1_Preset}（已改）` / `{1_Preset} (changed)`；只在 `ShowPreset`、`FoldSummary` 两处用 |
| 两份文本 `804-838` | `LOC_SDP_PRESET_TITLE` 预设、`LOC_SDP_PRESET_RESET` 恢复、`LOC_SDP_PRESET_RESET_TOOLTIP`“把权重和开关恢复成这个预设的值（档位不变）”、各预设名和悬停 |

### 行为（按代码读出）

- 改任意一项权重或开关（不论哪一列、哪个开关）后，下拉框和设置摘要都写“当前预设（已改）”，“恢复”可点。
- 点“恢复”：回到当前预设的全部权重和开关。
- 改过以后再选任一预设（包括同一个）：全部权重和开关被预设的值盖掉，改动没有地方找回。
- 改回和预设一样的值，“（已改）”自动消失（`Changed` 是逐项比较，不是记“动过”）。
- 但不会认出“等于另一个预设”：从均衡把科学点到 1.5，值和科技完全一样，仍显示“均衡（已改）”；从科技把科学点回 1，等于均衡，仍显示“科技（已改）”。
- 勾掉“允许砍伐”、勾上“换格”这类开关也算改了预设（开关在预设里，见 #49 决定“预设只改权重和开关”），所以只动开关也会出现“（已改）”。设置摘要本来就另外写“不砍伐”“换格”“替换旧钉”。
- 存档：`preset=最后选的预设` + 与它不同的项。以后版本调了预设的值，玩家没动过的项跟着变（#57 的设计）。
- 选城址页有自己的预设（均衡、成长优先、区域优先），不共用。两处不一致：
  - 下拉框不写“（已改）”，摘要写；
  - `P.SetPreset` 只设 `SDP_Sites.WEIGHT_KEYS` 的 11 个权重，不设“距离”（`DISTANCE`），而 `Changed` 把“距离”也算进去（它是权重列，`Preset = true`）。所以把距离调成非 0 后，选哪个预设摘要都一直写“（已改）”。单城、多城页的 `keeper.Use` 会把距离一起设回 0，没有这个问题。（读代码得出，未跑测试复现。）

### 相关测试

- `tests/offline/spec_panel.lua:809-825`（issue 71：摘要写预设名、改占地后“（已改）”、改回后消失）、`976-1020`（issue 49：经下拉框条目选科技、存档只记预设名、改金币后“LOC_SDP_FOLD_EDITED(LOC_SDP_PRESET_SCIENCE)”、点“恢复”、多城页分开）。
- `tests/offline/spec_settings.lua`：`Encode`/`Decode`/`Changed` 的单元测试（37-59 行），读档后三页签的值（62-84 行）。
- 游戏内 `tests/test_settings.lua` 只在 `PlayerConfiguration` 上写读，和显示无关。

### 玩家文档里的写法

- `docs/install-and-test.md:51`“改过权重时写‘均衡（已改）’”、`:55`“改过以后写‘（已改）’，点恢复回到预设的值”；
- `docs/install-en.md:43, 46` 同上（"Balanced (changed)"、"Reset brings the preset back"）；
- README 只列预设名，不涉及（已改）。

## 2. 游戏和别的模组怎么做

### 文明 6 本体（查了 `reference/base-ui`）

- **图形设置**（`Options.lua:605-623, 773-860, 968-1221`）：“性能影响”“内存影响”两条滑杆的档位是 最低/低/中/高/超高/**自定义**（`LOC_OPTIONS_CUSTOM`，中文“自定义”，英文“Custom”）。改任意一项单独的图形设置，滑杆就跳到“自定义”；把滑杆拖到某个档位，全部单项被那一档覆盖（`PopulateGraphicsOptions`）。“自定义”只是显示状态，拖到别的档位再拖回“自定义”，之前的单项值不会回来。
- **游戏设置的多选项**（`FrontEnd/GameSetupLogic.lua:326-345`、`AdvancedSetup.lua:536-737`）：全选写“全部”，全不选写“无”，其余写“自定义（n）”（`LOC_SELECTION_CUSTOM`）。同样是按当前值推出的标签。

### 别的规划模组（`reference/ep`、`amt`、`dwp`）

- Empire Planner：“策略侧重”是一排按钮（均衡、科学、文化、金币、信仰、生产力），没有可调的权重，也就没有“自定义”。
- AMT：预设只用来批量勾选区域（`ApplyCurrentCategoryPreset`），没有权重预设。
- District & Wonder Planner：没有预设。

### 别的游戏、软件（网上的个别报告，不是设计规范）

- 魔兽世界：单项图形设置和总滑杆不同时，滑杆下写“Custom”（[wowinterface](https://wowinterface.com/forums/showthread.php?p=320268)）。
- 上古卷轴 OL：有玩家抱怨更新后预设变成“Custom”，单项看起来和“Extreme”完全一样，分不清（[ESO 论坛](https://forums.elderscrollsonline.com/en/discussion/comment/8277024)）。即“自定义”标签要按值判断，值等于某个预设时就显示那个预设。
- 微软模拟飞行：玩家报告改成 Custom 后的表现和预设不同（[MSFS 论坛](https://forums.flightsimulator.com/t/asobo-regarding-ultra-graphics-preset/454402)）。
- Blender 2004 年的讨论：改了任何一项就切到“custom”，除非这些值恰好构成某个预设（[bf-funboard](https://lists.blender.org/pipermail/bf-funboard/2004-February/001775.html)）。

没找到“自定义”单独存一份、换到别的预设再换回来能找回的例子（常见做法是“另存为命名预设”，这需要跨对局保存，#57 已查证做不到，只能随存档记）。

## 3. 方案

### 方案 A（建议）：按值推出“自定义”标签

- 下拉框按钮和设置摘要：值等于当前预设 → 写它的名字；不等于当前预设但等于另一个预设 → 写那个预设，并把它记成当前预设；都不等 → 写“自定义”。下拉框的条目不变（还是 5 个预设，不加“自定义”条目，跟游戏图形设置一样）。
- 悬停：“自定义”时写“权重或开关和每个预设都不同”，再加一句“恢复”回到哪个预设。
- “恢复”：回到最后选的那个预设（待定问题 2），悬停写出预设名。
- 存档：格式不变（`v1;preset=最后选的预设;改过的项`），v1.5.0 写的存档照读；本版写的存档 v1.5.0 也照读（显示回“科技（已改）”）。
- 选城址页：下拉框和摘要同样写“自定义”；选预设改用 `keeper.Use`，把“距离”一起设回 0（修上面的不一致）。不加“恢复”按钮（待定问题 4）。
- 代码：`SDP_Settings` 加 `Match(values)`（按 `PRESET_ORDER` 找第一个值完全相同的预设，没有返回 nil），`ShowPreset`、`FoldSummary` 用它；删 `LOC_SDP_FOLD_EDITED`，加 `LOC_SDP_PRESET_CUSTOM`（自定义 / Custom，游戏的词）、`LOC_SDP_PRESET_CUSTOM_TOOLTIP`，`LOC_SDP_PRESET_RESET_TOOLTIP` 带预设名。
- 测试：`spec_panel.lua` 的 issue 49、71 两项改断言（“自定义”代替 `FOLD_EDITED(...)`）；加：均衡把科学点到 1.5 显示“科技”、存档记 `preset=SCIENCE`；改后“恢复”回到最后选的预设；选城址页调距离后选预设不再显示“自定义”；读档 `v1;preset=SCIENCE;YIELD_GOLD=2` 显示“自定义”。`spec_settings.lua` 加 `Match` 的单元测试。
- 文档：install-and-test.md、install-en.md 的两处说明，CHANGELOG 一行，`docs/notes/issue-89-*.md`。

### 方案 B：真正的“自定义”条目，另存一份

- 下拉框加第 6 个条目“自定义”。改了任何一项，当前值记成“自定义”，下拉框切到它；之后选别的预设看看，再选“自定义”能找回自己的值。
- 存档：仍是 `v1`（换版本号会让 v1.5.0 整段丢掉）。当前是自定义时写 `preset=CUSTOM` 加与默认不同的项；当前是别的预设而自定义里有值时，另加一组键（如 `c_YIELD_GOLD=2`）。v1.5.0 读到 `preset=CUSTOM` 用均衡，与默认不同的项照套，值不变，显示“均衡（已改）”；`c_` 键它不认识，丢掉。读 v1.5.0 的 `preset=SCIENCE;YIELD_GOLD=2`：转成自定义。
- 难处：
  - 在科技上改一项，自定义里原来存的值就被盖掉，所以“找回”只在“先选预设看看、不动它、再选回自定义”时有用；
  - 还没改过时“自定义”条目是空的，要灰掉或等于均衡；
  - “恢复”在自定义上不知道回哪儿；
  - 以后版本调了预设的值，自定义不跟着变（这点和 A 一样可以接受）。
- 代码、测试比 A 多一组值的编码、解码、迁移和条目的状态。

### 方案 C：不改

保留“均衡（已改）”。它告诉玩家从哪个预设改来、“恢复”回哪儿；缺点就是 issue 说的：改多了以后来源没意义，且认不出等于另一个预设的值。

## 4. 待定问题与建议

1. A、B、C 哪个？建议 A：跟游戏自己的图形设置一样；存档格式不变，前后版本都能读。B 的“找回”只在少数操作顺序下有用，却要多存一份值。
2. 显示“自定义”时“恢复”回到哪儿？建议回到最后选的预设，悬停写出名字（“回到科技的权重和开关，档位不变”）；改错一下能一键撤回。另两种：回到均衡（和下拉框选均衡重复）；去掉“恢复”（下拉框再选一次同一个预设效果相同，能省出 80 宽）。
3. 值恰好等于另一个预设时显示那个预设吗？建议显示，并把它记成当前预设（存档里少记几项）。
4. 开关还算不算预设的一部分？#49 定的是“预设只改权重和开关”，所以只勾“换格”也会变成“自定义”，选预设时开关也被设回默认。建议：维持 #49 的决定，本 issue 不动；若改成“预设只管权重”，单列一项再定（摘要本来就单独写“不砍伐”“换格”“替换旧钉”，不会丢信息）。
5. 选城址页要不要一起改？建议一起改：下拉框和摘要写“自定义”，选预设时把“距离”也设回 0；不加“恢复”按钮（这页从来没有，选预设就是恢复）。注意 #84 会给这页存档加“新城数量”“最远距离”两项，它们不属于预设，不影响“自定义”的判断。

## 5. 版本与工作量

- 按 2026-10-26 的版本规则（#93，CONTRIBUTING.md“发版”：第三位管修 bug、文字、小的界面改动、默认值和参数；第二位只给一类新能力或重做一部分；第一位给不兼容的存档/设置或重写）：
  - A：只改界面显示，存档格式不变，v1.5.0 的存档照读 → 第三位。
  - B：存档仍是 `v1`，只多一组 `c_` 键；v1.5.0 的存档照读（转成自定义），本版写的存档 v1.5.0 也能读（丢掉 `c_` 键）→ 仍兼容，第三位。只有把格式版本改成 `v2` 而不再读 `v1` 才算不兼容（第一位），两个方案都不需要这样做。
  - 放进下一次发版（已开的 v1.6.0 里程碑，#84 在里面），不单独发版。
- 工作量（A）：`SDP_Settings.Match` 和三页签的显示约 40 行，中英文本 3 个键，离线测试改 2 项、加 4–5 项，文档 4 处；约半天。游戏内只需中英两种界面各截一次下拉框（夜间队列，sdp-game-test）。B 约 1–1.5 天。

## 6. 决定与实现（2026-10-26）

合作者在 Issue 下选了方案 A，并去掉“恢复”按钮（待定问题 2 的第三种）。其余待定问题按建议：值等于另一个预设时显示它并记成当前预设（3）；开关仍是预设的一部分（4）；选城址页一起改（5）。

| 位置 | 改动 |
|---|---|
| `SDP_Settings.Match(name, values, fields, presets, order)` | 值等于 `name` 时返回它；否则按 `order` 返回第一个相等的预设；都不等返回 nil。keeper 的 `Changed` 换成 `Match` |
| `SDP_UI.PresetName`、`ShowPreset`、`FoldSummary`（`SDP_Panel.lua`） | 按 `Match` 的结果写预设名，nil 写 `LOC_SDP_PRESET_CUSTOM`（自定义 / Custom，同游戏的 `LOC_OPTIONS_CUSTOM`），按钮悬停 `LOC_SDP_PRESET_CUSTOM_TOOLTIP`；`ShowPreset` 加 `spec`（`Order`、`Tips`、`CustomTip`），选城址页也用它 |
| 三个页签的 `Remember`、`Restore` | 先 `m_preset = Match(m_preset) or m_preset`：等于另一个预设时换成它，再写存档；读档后同样 |
| 选城址页 `P.SetPreset` | 改用 `keeper.Use`：全部权重（含距离成本）设成预设的值，新城数量、最远距离、档位不变 |
| `SDP_Panel.xml` | 删 `PresetReset`、`MultiPresetReset`；权重标题行只剩“预设”和下拉框（170 宽），比原来窄 84 |
| 文本 | 删 `LOC_SDP_FOLD_EDITED`、`LOC_SDP_PRESET_RESET`、`LOC_SDP_PRESET_RESET_TOOLTIP`；加 `LOC_SDP_PRESET_CUSTOM`、`LOC_SDP_PRESET_CUSTOM_TOOLTIP`、`LOC_SDP_SITES_PRESET_CUSTOM_TOOLTIP` |

存档格式不变（`v1;preset=最后选的预设;不同的项`）：v1.5.0 的存档照读，`v1;preset=SCIENCE;YIELD_GOLD=2` 读出来显示“自定义”，当前预设仍是科技。

测试（离线）：`spec_settings.lua` 加 `Match` 的单元测试，多城页的存档换成 `v1;preset=SCIENCE;YIELD_GOLD=2` 并检查显示“自定义”，选城址页读档后显示“自定义”；`spec_panel.lua` 的 issue 49、71 两项改断言，加两项 issue 89（均衡把科学点到 1.5 显示科技并记成当前；再改金币显示自定义和悬停；改后选同一个、另一个预设；开关；多城页；选城址页调距离成本后显示自定义、选预设后回到 0 并显示预设名、权重等于成长优先时显示它）。都经控件自己的回调（下拉框条目、权重列的加号、勾选框）。
