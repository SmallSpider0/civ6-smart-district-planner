# tools/

开发循环：`validate.py` → `offline_tests.mjs`（不开游戏）→ `deploy.py` → 进入对局 → `run_tests.py`。Python 脚本只用标准库，统一用 `python3 -I` 运行；`luacheck.mjs` 依赖 luaparse（新环境先 `cd tools && npm install`）。

| 脚本 | 作用 | 退出码 |
|------|------|--------|
| `validate.py` | 静态校验 mod 与测试文件 | 0 通过；1 有错误；2 缺工具 |
| `luacheck.mjs` | Lua 语法与陷阱检查（validate 会调用它） | 0 无错误；1 有错误 |
| `offline_tests.mjs` | 不开游戏跑求解逻辑测试与基准（`tests/offline/`） | 0 全过；1 有失败；2 用法错误 |
| `deploy.py` | 校验后把 mod 同步到游戏 Mods 目录 | 0 成功；1 校验失败；2 找不到 Mods 目录 |
| `package.py` | 从最近一次提交打出给合作者的测试包（zip，含测试说明和交付报告） | 0 成功；1 校验失败；2 有未提交的改动 |
| `run_tests.py` | 经 Tuner 在游戏内跑 `tests/test_*.lua` | 0 全过；1 有失败；2 连接问题；3 超时 |
| `game.py` | 退出游戏、经 Steam 启动、从主菜单快速开局（可选建首都） | 0 成功；2 超时 |
| `realclick.py` | 用系统鼠标事件真实点击面板，每步从面板状态读回核对 | 0 全过；1 有失败；2 环境问题 |
| `stress.py` | 发布前在后期存档上做压力测试：AI 自动打出存档、逐步计时、魅力复核 | 0 全过；1 有问题步骤；2 环境问题 |
| `civ6tuner.py` | FireTuner 客户端：收集 Lua 输出、远程执行 Lua | 见下文 |

## validate.py — 静态校验

```bash
python3 -I tools/validate.py            # 校验 SmartDistrictPlanner/ 与 tests/
python3 -I tools/validate.py --strict   # 警告也算失败
```

| 规则 | 检查内容 |
|------|----------|
| `xml` | 所有 `.xml`/`.modinfo` 过 `xmllint --noout` |
| `modinfo` | mod id 固定；`<Dependencies>` 含 DMT；`<Files>` 与磁盘一致（大小写精确）；动作引用的文件都在 `<Files>`；`AddUserInterfaces` 有 `<Context>`（坑 3）；没被任何动作加载的 XML 给警告 |
| `text` | 文本文件根为 `<GameData>`，禁止外部文件用 `<Text id><en_US>` 格式（坑 2）；同一加载阶段 en_US 与 zh_Hans_CN 的 `LOC_SDP_*` 键一致；modinfo `<LocalizedText>` 里的文本与 `Text/*.xml` 同键同语言时必须一致 |
| `loc` | Lua/UI XML 引用的 `LOC_SDP_*` 在对局文本里两种语言都有（以 `_` 结尾的视为运行时拼接前缀，跳过）；modinfo 的名称/描述键在前端阶段能加载（坑 1） |
| `ui` | UI XML（根为 `<Context>`）只用游戏本体与 DLC UI XML 出现过的控件与属性（坑 8）；游戏源码里的拼写错误（`Achnor`、`StachGrowth` 等）单独报错；只出现过一次的属性给警告。需要 `reference/` 符号链接 |
| `lua` | 调用 `luacheck.mjs`，见下 |
| `ui`（点击遮挡） | 模板实例的根是可点击的按钮时，里面不能有 `Size="parent,parent"` 的 Button / GridButton / CheckBox：显示时会接住鼠标，下面的按钮点不到（坑 31） |
| `controls` | 脚本里的 `Controls.<ID>` 都是 UI XML 里的 ID（坑 30） |

## luacheck.mjs — Lua 检查

```bash
node tools/luacheck.mjs [--json] FILE...
```

- 用 luaparse 的 5.3 模式解析（需求文档指定；5.1 模式会误报合法的 `break;`），再按规则禁掉 Lua 5.1 没有的写法：`goto`/标签、位运算、`//`、块中间的 `break`。
- `banned-global` / `banned-call`：游戏里为 nil 的全局（`_G`、`require`、`setfenv`、`debug`、`table.unpack` 等，2026-10-19 实测）；破坏确定性的 `math.random`、`os.time`、`os.date`。
- `global-assign`（警告）：写入不带 `SDP_`/`sdp_` 前缀的全局，通常是漏了 `local`。
- 单行豁免：行尾加 `-- lint: allow <规则名>`（如替换 DMT 的 `GetMapPinSubject` 时用 `global-assign`）。
- 游戏本体与 DMT 源码用了 HavokScript 扩展语法（类型标注），本检查不接受；我们的代码保持纯 Lua。

## offline_tests.mjs — 离线逻辑测试与基准

```bash
node tools/offline_tests.mjs                                   # 跑 tests/offline/spec_*.lua
node tools/offline_tests.mjs -v -k k6 tests/offline/bench_single.lua   # 单城基准（只跑名字含 k6 的组）
```

- Lua 跑在 [fengari](https://github.com/fengari-lua/fengari)（JavaScript 写的 Lua 5.3 虚拟机，`tools/node_modules`，`npm install` 安装）里，不需要游戏。每个文件一个新状态，提供 `unpack`、`loadstring`、`include`（按名字找 `SmartDistrictPlanner/Scripts|UI/` 或 `tests/offline/`），游戏自己的文件（`MapTacks`、`dmt_yieldcalculator` 等）由假世界提供。
- `tests/offline/world.lua` 是一个小的假游戏：六边形地图（文字描述或按种子随机生成）、城市、区域、地图钉、`GameInfo` 的相关表，以及**简化的 DMT**（`CanPlacePin`、`GetBonusYields`、钉子数据）。规则照游戏数据缩减，只用来测求解器的搜索和记账；游戏里的真实数值一律来自真正的 DMT，所以离线通过之后仍要在游戏里跑 `tests/test_*.lua`。
- 测试文件写法与游戏内测试相同（`local test, T = ...`）；文件名用 `spec_` 前缀（`test_` 开头的会被 `run_tests.py` 当成游戏内测试）。基准文件用 `bench_` 前缀，只在点名时运行。
- 假 DMT 统计调用次数（`World.Calls`）。基准用"调用次数 + 布局评估次数 + 搜索节点数"按游戏内单价折算预计耗时，不依赖本虚拟机的速度。
- `tests/offline/ui.lua` 提供面板用到的 UI 对象替身（`Controls`、`ContextPtr`、`UIManager`、`InstanceManager`、透镜），`spec_panel.lua` 用它加载整个面板跑三个页签。布局和真实点击仍要在游戏里看。
- 基准：`bench_single.lua`（单城）、`bench_multi.lua`（多城，`SDP_BENCH_SEEDS` 可选种子）、`bench_pools.lua`（单城从候选里挑区域，参照为逐个组合单独求解的最好结果）、`bench_multipools.lua`（多城每城挑区域，参照为“各城单独挑好再联合求解”和最好已知结果）。
- `bench_single.lua`（其余基准同理）的环境变量：`SDP_BENCH_REFS=文件` 缓存参照解（算参照解很慢）；`SDP_BENCH_TIERS=FAST,STANDARD` 只跑部分档位；`SDP_BENCH_PARAMS="STANDARD.NodeLimit=60000,FAST.Kicks=2"` 临时覆盖档位参数，用来比较方案。覆盖只作用于被测的档位本身，不作用于它的前置档位（前置读 `SDP_Tiers` 里的值）。**参照解缓存会过时**：合法性规则变了（例如 2026-10-20 起候选格排除奢侈、战略资源），旧参照里可能有现在不合法的布局，比例会显得变差；改了合法性后删掉缓存重算（multicity-design.md 第 21 节）。
- **fengari 的整数是 32 位**（游戏里的 Lua 数字是双精度）：超过 2^31 的整数运算会回绕。需要大数的地方写成浮点（如 `1.0`），见 `SDP_Board` 的邻居编码。

## compare.mjs — 与其他规划模组的离线对比

```bash
python3 -I tests/compare/export_gameinfo.py        # 一次：从游戏缓存导出规则数据库（tests/compare/.cache/，不入库）
node tools/compare.mjs --list                       # 场景列表
node tools/compare.mjs -s S04-japan -p sdp,amt,ep -j 4 -v   # 某些场景、某些规划器（-s 是编号的子串）
node tools/compare.mjs -s '^C\d' -p sdp,ep -j 3            # 以 ^ 开头时按正则匹配（子串 "C" 也会匹配 "~SCI"）
node tools/compare.mjs -j 8 --out tests/compare/results/full.jsonl   # 全部（约 1–2 小时）
node tools/compare.mjs --only sdp:STANDARD_LAND -j 4 --out tests/compare/results/land.jsonl   # 只跑某个规划器的某个设置
node tools/compare.mjs --rejudge tests/compare/results/full.jsonl -j 4 --out NEW.jsonl   # 方案不变，用当前裁判重新打分（几分钟）
node tools/compare.mjs --crossscore RESULTS.jsonl --scorers amt,ep -j 4 --out CROSS.jsonl   # 用 AMT、EP 自己的目标函数给每个方案打分
python3 -I tests/compare/summarize.py tests/compare/results/full_rejudged.jsonl tests/compare/results/land.jsonl   # 汇总（后面的文件覆盖前面的同名运行）
node tools/compare.mjs --dump S01-rome-temperate-mid       # 场景地图的文字图
node tools/compare.mjs --snapshot S01-rome-temperate-mid   # 场景地图数据（报告画图用）
```

- 不开游戏，在 fengari 里比较本 mod、Auto Map Tacks Planner r49（AMT）和 Empire Planner（EP）的区域规划。**规则是真的**：`GameInfo` 来自游戏写在缓存里的规则数据库 `Cache/DebugGameplay.sqlite`（最后一次加载的对局的规则集，目前是风云变幻；导出文件是 Firaxis 的数据，只放在被忽略的 `.cache/`）。**代码是真的**：DMT、AMT、EP 的 Lua 原样从 `reference/` 和本机创意工坊目录加载，不改一行。**引擎是模拟的**：`tests/compare/cmp_game.lua` 实现地图、城市、地图钉、玩家配置、可见性、河流与泛滥平原、修正系统（`GameEffects`，DMT 从它读文明特性的相邻规则）和 UI 替身。
- 每次运行：一个新 Lua 状态生成场景世界（`cmp_mapgen.lua`，种子固定，同场景同地图）、加载一个规划器（`cmp_sdp.lua` / `cmp_amt.lua` / `cmp_ep.lua`，像玩家一样点它自己的按钮）、输出方案；另一个只加载 DMT 的新状态（`CmpRun.Judge`）把方案打成地图钉，用 DMT 打分，并检查 DMT 没查的游戏规则（不可移除的资源、3 环、领土归属、每城一个、帝国上限、人口槽位、压钉、漏放）。
- 场景在 `cmp_scenarios.lua`，共 432 个，按编号前缀分组（`summarize.group`）：
  - `S`/`M`：开发集，17 个文明 × 8 种地形 × 前/中/后期的 72 个单城场景，加 12 个 3–4 城的多城场景；部分有邻国、城邦、自然奇观、未探索格、玩家手打的钉。改算法时只用这一组。
  - `HS`/`HM`：留出集，同样的设计、新的种子（50000 起），改算法时不看，只用来复核结论（第 18.1 节第 5 条）。
  - `S…~SCI`、`~PROD`、`~FAITH`：开发集单城场景换一组产出权重（该项 ×3，其余 1），规划器和裁判都用这组权重（第 4 条）。
  - `W`：24 个中期单城场景，另要两个与地形相符的奇观（`request.wonders`；裁判用 DMT 判奇观合法性，报告 `wondersPlaced`）。
  - `C`：12 个选城址场景（kind `sites`，`request.sites = { count = 2, distance = 8 }`），只比本模组与 EP。裁判 `JudgeSites` 不用任何一方的评分，独立计算合法性与间距、各城址最好 8 块地的产出、淡水、新的奢侈与战略资源种类、区域潜力（城址处打市中心钉后各区域在 DMT 下的最好相邻加成）、重叠格，`siteValue` = 地块产出 + 区域潜力。
  - `V`：12 个覆盖范围场景（multicity-design.md 19.5）：后期 3–4 座城，每座城自己一张清单（`scn.plans`，请求里是 `request.plans[城市 ID]`），只有一两座城要工业区、娱乐中心。本模组跑标准档、精细档各三种覆盖权重（变体 `STANDARD`、`STANDARD_COV1`、`STANDARD_COV3`、`FINE`…；`_COV<n>` 即多城页签的覆盖权重 n），AMT 用同样的逐城清单（它自带覆盖）；EP 不能逐城给清单，不参加。裁判按城检查"没要求的区域"和漏放，并独立计算覆盖：每类基础区域取通用建筑最大的 `RegionalRange`，数玩家城市被覆盖的（城市, 类别）个数，方案前后各一次（`coverageBefore`、`coverage`、`coverageGain`）。
  - 对手各跑两种设置：权重与裁判一致（与场景权重相同）和它们面板的默认设置。
- 模拟层缺的接口会记在输出的 `missingApi` 里；HavokScript 的类型标注在加载时去掉。AMT 的多城联合很慢（离线一局 3–40 分钟），全量对比建议在机器空闲时跑。每个工作线程的 JS 堆上限默认 1536 MB，AMT 的 4 城联合偶尔会超出（线程被终止，那次运行和同线程排队的一次都没有结果，日志里是 `ERR_WORKER_OUT_OF_MEMORY`）；用环境变量 `CMP_HEAP_MB=6144` 单独补跑缺的运行。
- 交叉评分（第 18.1 节第 2 条）：`--crossscore` 对结果文件里每个方案，在新的 Lua 状态里调用 `tests/compare/cmp_cross_<打分方>.lua` 的 `CmpCross[打分方](request, plan, w)`，返回该对手自己的目标函数对这个方案的分数（`score`、空方案的 `baseline`、`gain`），写进 `row.cross`；`summarize.py` 以 `cross_amt`、`cross_ep` 字段汇总。
- `summarize.py` 按场景集分组列表，并给出本模组标准档对每个对手的逐场景配对比较：胜/平/负、平均差及其 95% 自助法置信区间（2000 次确定性重抽样）、符号检验 p 值；城市总产出用本模组的"计入地块"一组比较。覆盖场景另列覆盖与相邻加成两项的帕累托比较（`pareto`：两项都不差且至少一项更好 / 更差 / 相同 / 各有胜负）和各设置的平均值。
- 结果 JSON lines：方案、裁判分（`gain`、`violations`、`items`、城市总产出 `output = gain + worked`、漏放 `missing` 与其中有位置却没放的 `missingPlaceable`）、耗时、DMT 调用次数。`summarize.py` 以每个场景所有合法方案里的最高加成为参照，算质量、达到最高的比例、合法率、漏放、城市总产出、确定性（"#2" 重复运行与原运行比方案）。
- 入库的结果（2026-10-20）：开发集 `full_rejudged.jsonl`（588 次运行）与 `land.jsonl`（本 mod 计入地块的 84 次）、留出集 `heldout.jsonl`、三组权重 `profiles_{SCI,PROD,FAITH}.jsonl`、奇观 `wonders_sdp_ep.jsonl` + `wonders_amt.jsonl`（本 mod 加入补放后重跑的是 `wonders_sdp_repair.jsonl`）、选城址 `sites.jsonl`，以及交叉评分 `*_cross.jsonl`；覆盖范围 `coverage_sdp.jsonl`、`coverage_amt.jsonl`。汇总时把后者放在后面，同名运行以后面的为准。

## deploy.py — 部署

```bash
python3 -I tools/deploy.py --dry-run    # 只显示会改什么
python3 -I tools/deploy.py              # 校验通过后同步
```

- 目标：Mac `~/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/SmartDistrictPlanner/`，Windows `文档/My Games/Sid Meier's Civilization VI/Mods/SmartDistrictPlanner/`；`--mods-dir` 可改。
- 增量复制，并删除部署目录里源目录已没有的文件；只动 `Mods/SmartDistrictPlanner/` 内部。
- 结尾提示重载方式：改了 modinfo 或 `Text/` 要重启游戏，否则回主菜单重新进入对局即可。

## package.py — 给合作者的测试包

```bash
python3 -I tools/package.py             # 输出 dist/SmartDistrictPlanner-<提交号>.zip
```

- 内容：`SmartDistrictPlanner/`（模组本体）、`TEST_GUIDE.md`（`docs/tester-guide.md`，填好版本号和日期）、`INSTALL_AND_USE.md`（`docs/install-and-test.md`，指向其他文档的链接改成纯文本）、`REPORT.html`（交付报告的单文件版，见下一节）。
- 从最近一次提交打包：先校验；模组、这两份文档或交付报告读到的文件（`report/build.py` 的 `INPUTS`）有未提交的改动时拒绝打包。文件名里的提交号就是版本号，合作者反馈时报这个号。
- 压缩包里的文件名都是 ASCII，Windows 自带的解压工具不会显示乱码；条目时间取提交时间，同一次提交打出的包相同。`dist/` 不入库。

## report/build.py — 交付报告

```bash
python3 -I report/build.py              # 输出 dist/report/index.html 和 report.html
```

- 读 `tests/compare/results/` 里的对比结果（文件列表见 `RESULTS`），套进 `report/template.html`（第 3、4 节分别来自 `part_arch.html`、`part_algo.html`，图表脚本 `charts.js`，地图案例 `hexmap.py`）。
- `index.html` 是发布为 artifact 的页面，截图写成 `images/<文件名>`，发布时把 `docs/images/` 里对应的图一起上传；`report.html` 是同一页的单文件版，截图内嵌，可直接用浏览器打开，`package.py` 打进测试包。
- 案例地图的场景数据缓存在 `report/snaps/`，缺的会用 `node tools/compare.mjs --snapshot` 生成（需要 `tests/compare/.cache/`），生成后要提交；`package.py` 不生成，缺了就报错。
- 同样的输入得到同样的页面。改了报告内容或对比结果后重新生成、提交，再打包和更新 artifact。

## run_tests.py — 游戏内测试

```bash
python3 -I tools/run_tests.py                     # 跑 tests/**/test_*.lua
python3 -I tools/run_tests.py -k campus -v tests/test_dmt.lua
```

测试文件格式：

```lua
-- @state dmt_yieldcalculator      -- 在哪个 Lua 状态执行（默认 InGame）
-- @timeout 30                     -- 整个文件的超时秒数（默认 30）
-- @max_seconds 2.5                -- 可选：整个文件的墙钟时间超过即判失败（性能验收用）
local test, T = ...

test("名称", function()
  T.eq(实际值, 期望值, "说明")      -- 还有 T.ok(cond, msg)、T.near(a, b, eps, msg)、T.same(a, b, msg)（深比较）、T.skip(原因)
end)
```

- `@setup <状态> <文件>` / `@teardown <状态> <文件>`：在测试前后到指定 Lua 状态执行脚本，teardown 总会执行。例如 `test_built.lua` 先在 `GameCore_Tuner` 里用 `tests/fixtures/build_campus.lua` 建一座学院，测完再拆除。
- `tests/fixtures/` 下是测试前置脚本（不以 `test_` 开头，不会被当成测试跑），如 `found_capital.lua`：新开局还没有城市时用开拓者建首都，`game.py newgame --capital` 会调用它。
- `T.dump(v)` 把值序列化为按键排序的文本，`T.same` 用它比较，适合检查"同输入同输出"。
- 文件内容经 `loadstring` 以文件名作 chunk 名加载，错误信息带 `tests/xxx.lua:行号`，并去掉 harness 自身的调用栈帧。
- 失败或 `-v` 时显示该文件的 `print()` 输出。
- 计时为单文件墙钟时间（含约 0.02 秒 Tuner 往返）。游戏内 `os.clock` 等计时器只有秒级，不能在 Lua 里测耗时。
- 已验证：通过/失败/跳过/语法错误/加载期错误、72 KB 的测试文件、内容含 `]]`、测试名含 `|` 和中文、状态名写错（只记该文件出错，其余继续）。

## realclick.py — 真实鼠标点击

游戏窗口不向辅助功能暴露控件，电脑操作工具的点击会被拒绝。这里用一个小应用发系统鼠标事件：

```bash
python3 -I tools/realclick.py build     # 编译 tools/click/sdp-click.swift 为 ~/Applications/SDPClick.app（一次）
python3 -I tools/realclick.py trusted   # 检查辅助功能权限
python3 -I tools/realclick.py suite     # 30 项点击检查，需要有首都的对局（game.py newgame --capital --reveal）
python3 -I tools/realclick.py at 'Controls.SolveButton'   # 点 SDP_Panel 状态里这个 Lua 表达式给出的控件
```

- 编译好的应用要在"系统设置 → 隐私与安全性 → 辅助功能"里授权一次（由用户操作）。必须是用 `open` 启动的独立应用：macOS 按启动命令行工具的应用判断权限。应用放在 iCloud 之外，因为 iCloud 给文件加的扩展属性会让 codesign 失败。
- 坐标来自游戏：控件的 `GetScreenOffset` 与尺寸（UI 单位 1920 × 1080）按窗口大小换算，不靠截图估计。
- 每次点击前检查游戏在最前（不在时 `open -b com.aspyr.civ6.steam`）、点在游戏窗口内、该点最上层的窗口属于游戏，任一不满足就不点。套件开始前先关掉排队的弹窗；结束后把前台还给原来的应用。
- 点击期间游戏会到前台，会占用屏幕和鼠标，跑之前告诉用户。

## stress.py — 后期存档压力测试（发布前）

```bash
python3 -I tools/stress.py prepare pangaea-gs     # 主菜单开局，AI 自动打 N 回合，存为 SDP_stress_pangaea-gs
python3 -I tools/stress.py load pangaea-gs        # 回主菜单读这个存档
python3 -I tools/stress.py run pangaea-gs         # tests/bench/stress.lua 的各步，逐步计时，结果写 tests/stress/results/
python3 -I tools/stress.py check pangaea-gs       # 按玩家的建造流程建出"魅力"一步的方案，比较魅力与住房（会改动当前对局，最后跑）
python3 -I tools/refresh_stress_md.py             # 把汇总表写进 docs/self-test-report.md（报告第 5.10 节由 report/build.py 生成）
python3 -I tools/stress.py summary                # 汇总表
```

- 三个场景（`SCENARIOS`）：风云变幻盘古大陆标准图（北条时宗，远古开局 200 回合）、风云变幻大陆大图（威廉明娜，中世纪开局 150 回合）、迭起兴衰群岛（伯里克利，古典开局 170 回合），都用联机速度。存档在游戏自己的存档目录，不进仓库。
- 自动回合用游戏的 `AutoplayManager`，界面以观察者身份观察：以玩家 0 观察时，AI 的外交（初次见面、交易）会发到本地界面等回答，回合停住。
- 各步：普查（城市、区域、奇观、钉数）；AI 自己建的保护区周边产出与规则对照；人口最多的几座城各做候选池（快速、标准，标准档跑两次核对确定性）与必建求解；社区 + 保护区 + 工业区；港口与商业中心；精细档；选城址与打城址钉；4 城、8 城多城（标准、精细）与打钉；再打 150 个钉后重复单城与多城；面板开关各页签；撤销全部。每步记录耗时、加成、DMT 自报与裁判是否一致、引擎拒绝的格数。
- `check` 在格上下令建造（`CityOperationTypes.BUILD`）再 `FinishProgress` 建完，事先只给这座城补上这些区域的前置科技、市政和人口；不用 `CreateDistrict`（AGENTS 坑 36）。魅力、住房在核心状态读。
- 计时是 Tuner 一次请求的墙钟时间，求解一次算完；面板里同样的计算分帧进行，所以是玩家要等的时间，不是卡顿。
- 生成存档和计时时不要同时跑离线对比这类重活：2026-10-21 生成大陆存档时并行跑对比（6 个工作线程），回合推进从每分钟约 5 回合掉到 5 分钟 1 回合，游戏画面也很卡。

## game.py — 启动与进入对局

```bash
python3 -I tools/game.py quit                          # 经 Tuner 退出游戏并等待进程结束
python3 -I tools/game.py menu                          # 退回主菜单（只改了 Lua/UI XML 时用它重载，不必重启）
python3 -I tools/game.py launch                        # 记下前台应用，open -g steam://rungameid/289070，等启动器出现（Steam 有时要 1 分钟以上）
# 然后用 computer-use 对启动器（com.aspyr.civ6.steam）的"开始"按钮做 AXPress
python3 -I tools/game.py newgame --state SDP_Panel --capital   # 等主菜单→快速开始→等指定 Lua 状态可用→用开局开拓者建首都
python3 -I tools/game.py popups --close                # 关掉排队中的游戏弹窗（历史时刻等），规划面板才会显示
python3 -I tools/game.py newgame --state SDP_Panel --capital --reveal   # 另外揭示首都周围 12 格（城址、多城测试需要）
```

**不占用户的屏幕**：启动器和游戏窗口出现时会把自己切到前台（`activateIgnoringOtherApps`）。

- `launch` 先用 `lsappinfo` 记下前台应用（存在 `logs/front-app.txt`），再用 `open -g` 打开 Steam，Steam 不会被带到前台。`--stay` 不做记录，游戏留在前台。
- 接下来的 `newgame` 在等待期间每 0.5 秒查一次：游戏一到前台，就用 `open -b` 切回用户最后在用的应用（用户中途换了应用就跟着换）。`newgame` 结束后不再干预，记录随之删除。
- 没有 `launch` 的记录时，`newgame` 开始时前台若不是游戏，同样替用户守住；用户正在看游戏则不管。
- 配合的一次性设置（由用户在系统里做）：调度中心新建一个桌面；游戏运行时在那个桌面上右键 Dock 里的文明6图标 → 选项 → 分配给"此桌面"。启动器和游戏窗口共用一个 bundle（`com.aspyr.civ6.steam`），之后都会出现在那个桌面。屏幕只在启动器出现到按下"开始"这段时间停在那里。
- 游戏不在前台时照常运行（`AppOptions.txt` 里 `ThrottleWhileInactive 0`）。2026-10-20 实测：被别的窗口挡住时每秒约 120 帧，挪到另一个桌面后约 83 帧。
- 静音：`SoundOpts.txt` 里 `Mute Focus 1`（失去焦点即静音）；`newgame` 另外在主菜单和进对局后把总音量设为 0（`Options.SetAudioOption(..., 0, 0)`，与选项界面拖动滑块时相同，只对本次运行，保存的音量不变）。
- computer-use 的 `app_click` 对启动器的"开始"做 AXPress 时不需要把启动器拿到前台。
- 访达不算“用户在用的应用”：游戏窗口切换时系统会把前台交给访达（实测见过一次），跟随它会把用户留在访达里。
- 接了多台显示器时，Dock 的“分配给”只有“显示器 N 上的桌面”，没有“此桌面”；不分配也行，游戏窗口挪到哪个桌面，这次运行就一直在那里。

`popups --close` 调用每个弹窗自己的 `OnClose`/`Close`（与点它的关闭按钮相同），找不到才直接出队；反复检查直到连续两次没有弹窗。原因：自然奇观等弹窗打开时占住游戏的事件队列，只出队不释放，UI 里的游戏数据（如揭示状态）就停止更新（AGENTS 坑 24）。

`--reveal`（与 `--capital` 一起用）：建城后在 `GameCore_Tuner` 执行 `tests/fixtures/reveal_area.lua`，揭示首都周围 12 格，再关掉随之出现的自然奇观弹窗。第 1 回合只揭示了城市附近，城址候选要求三环内多半已揭示，不揭示时城址和多城测试会跳过。

`--ruleset RULESET_STANDARD | RULESET_EXPANSION_1 | RULESET_EXPANSION_2` 指定规则集（默认为"快速开始"的选择，即已安装的最新资料片）。

`newgame` 默认固定领袖（`--leader LEADER_TRAJAN`）和地图/游戏种子（`--seed 20261019`），做法是包装主菜单状态里的全局 `GameSetup_RefreshParameters`："快速开始"重置配置后会调用它。所以每次都是同一张地图；`--random` 恢复随机。

只改了 Lua 或 UI XML：`deploy.py` → `game.py menu` → `game.py newgame --state SDP_Panel --capital` → `run_tests.py`（约 30 秒）。

改 modinfo 或文本后的完整循环：`deploy.py` → `game.py quit` → `game.py launch` → 点"开始" → `game.py newgame --state SDP_Panel --capital` → `run_tests.py`。

**截图**（游戏要在前台，2026-10-20 用过的做法）：

- `game.py launch --stay` 让游戏留在前台；`newgame` 开始时游戏在前台就不会切走。
- 附加内容界面：在 `MainMenu` 状态执行 `OnMods()`。名为 `Mods` 的 Lua 状态有两个（`ModsMenu`、`ModsContext`），屏幕上的是 `ContextPtr:GetID()` 为 `ModsContext` 的那个，按序号 `exec -s <序号>`，在里面用 `SelectMod(handle)` 选中本模组。
- 地图镜头：在 `WorldInput` 状态执行 `UI.SetMapZoom(z, 0, 0)` 和 `UI.LookAtPlotScreenPosition(x, y, 横向比例, 纵向比例)`。在面板的状态里调 `SetMapZoom` 不生效。
- 揭示地图、移动镜头后会弹出与苏格兰的首次相遇外交画面：在 `DiplomacyActionView` 状态执行 `OnForceClose()`，出现回复选项时再执行一次；随后的"尤里卡"用 `popups --close` 关。
- 用 computer-use 的 `zoom` 只截游戏窗口内的区域，裁掉 macOS 的菜单栏、窗口标题栏和 Dock。结果列表用 `Controls.MultiResultScroll:SetScrollValue(v)` 滚动；悬停提示要用真实的鼠标移动（`mouse_move`），滚动位置可能被重绘复位，移动鼠标后马上截。

## civ6tuner.py — FireTuner 客户端（Lua 输出 + 远程执行 Lua）

Mac 版文明6不写 `Lua.log`，本工具通过游戏的 FireTuner 调试端口（127.0.0.1:4318）代替它：收集所有 Lua `print()` 输出，并在任意 Lua 状态中执行代码。纯 Python 标准库，无依赖。

**前提**：`AppOptions.txt` 中 `EnableTuner 1`（已配置）。游戏**同一时间只接受一个 Tuner 客户端**。

```bash
# 常驻：独占连接，自动重连，全部 Lua 输出追加到 logs/tuner-lua.log
python3 -I tools/civ6tuner.py serve

# 列出当前 Lua 状态（主菜单与对局内不同；对局内有 InGame、GameCore_Tuner 等）
python3 -I tools/civ6tuner.py states

# 执行 Lua（默认状态 InGame），代码也可用 -f 文件 或 stdin 传入
python3 -I tools/civ6tuner.py exec -s MainMenu 'print(_VERSION)'
```

- `exec`/`states` 优先走 `serve` 守护进程（控制端口 127.0.0.1:43180），没有守护进程时直接连游戏。其他脚本通过 `civ6tuner.request()` 复用同一逻辑。
- 代码经 `loadstring` + `pcall` 包装：语法错误和运行时错误（含 traceback）都会返回。
- 退出码：0 成功；1 Lua 错误；2 连接/协议问题（含状态名不存在）；3 超时。
- `--json` 输出完整结果；`--raw` 不做包装直接发送（无错误捕获）。

**已验证**（2026-10-19，Mac 版 1.0.12.54，主菜单与对局内）：握手、状态列表、输出（含中文、多行）、运行时与语法错误捕获、守护进程日志；对局内调用 DMT `CanPlacePin`/`GetBonusYields` 得到合法性、产出与中文 tooltip。游戏 Lua 为 HavokScript（`_VERSION` = `2013.2.0 r13768`），有 `loadstring`、无 `load`。

**自动进入对局**（2026-10-19 实测，从点启动器到地图约 1 分钟，无需人工）：

1. `open steam://rungameid/289070`，再用 computer-use 对启动器窗口（bundle `com.aspyr.civ6.steam`）的"开始"按钮做 AXPress（启动器支持辅助功能；游戏本体窗口不支持）。
2. 等 `states` 里出现 `MainMenu`（开场动画已在 `AppOptions.txt` 关闭）。
3. `exec -s MainMenu 'Automation.SetAutoStartEnabled(true); OnPlayCiv6()'`：以默认设置"快速开始"，读取完成后自动越过"开始"按钮。
4. 等 `exec -s InGame 'print(Game.GetCurrentGameTurn())'` 有输出即进入地图。首次进 GS 对局会有资料片欢迎弹窗，不影响 Lua 调用。
5. 退出：`exec -s InGame --raw 'Events.UserConfirmedClose()'`。

**常用 Lua 状态**（对局内）：`InGame`（UI 主上下文）、`GameCore_Tuner`（游戏核心，读状态用）、`dmt_yieldcalculator`（DMT 的 `CanPlacePin`/`GetBonusYields` 等都在这里）、`MapPinManager`、`SDP_Panel`（本 mod 的面板）。UI 状态中 `_G` 为 nil，直接用全局名访问。

**注意**：
- 开启 Tuner 时游戏**不会解锁 Steam 成就**。
- 游戏退出或重载时连接会断，`serve` 每 2 秒自动重连。
- **读取画面期间 Tuner 不响应握手和状态查询**（输出帧照常推送）；此时若断开连接，4318 会暂停监听，直到进入对局才恢复。所以读档/开局期间不要重启 `serve`。
- 4319 端口能连上但不处理请求，客户端默认只用 4318。
- 协议说明见 `civ6tuner.py` 文件头注释；协议格式参考了社区项目 [lmwilki/civ6-mcp](https://github.com/lmwilki/civ6-mcp)（MIT）的公开说明，代码为独立实现。
