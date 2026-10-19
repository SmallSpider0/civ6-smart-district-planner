# tools/

开发循环：`validate.py` → `offline_tests.mjs`（不开游戏）→ `deploy.py` → 进入对局 → `run_tests.py`。Python 脚本只用标准库，统一用 `python3 -I` 运行；`luacheck.mjs` 依赖 luaparse（新环境先 `cd tools && npm install`）。

| 脚本 | 作用 | 退出码 |
|------|------|--------|
| `validate.py` | 静态校验 mod 与测试文件 | 0 通过；1 有错误；2 缺工具 |
| `luacheck.mjs` | Lua 语法与陷阱检查（validate 会调用它） | 0 无错误；1 有错误 |
| `offline_tests.mjs` | 不开游戏跑求解逻辑测试与基准（`tests/offline/`） | 0 全过；1 有失败；2 用法错误 |
| `deploy.py` | 校验后把 mod 同步到游戏 Mods 目录 | 0 成功；1 校验失败；2 找不到 Mods 目录 |
| `run_tests.py` | 经 Tuner 在游戏内跑 `tests/test_*.lua` | 0 全过；1 有失败；2 连接问题；3 超时 |
| `game.py` | 退出游戏、经 Steam 启动、从主菜单快速开局（可选建首都） | 0 成功；2 超时 |
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
- 基准：`bench_single.lua`（单城）、`bench_multi.lua`（多城，`SDP_BENCH_SEEDS` 可选种子）。
- `bench_single.lua` 的环境变量：`SDP_BENCH_REFS=文件` 缓存参照解（算参照解很慢）；`SDP_BENCH_TIERS=FAST,STANDARD` 只跑部分档位；`SDP_BENCH_PARAMS="STANDARD.NodeLimit=60000,FAST.Kicks=2"` 临时覆盖档位参数，用来比较方案。
- **fengari 的整数是 32 位**（游戏里的 Lua 数字是双精度）：超过 2^31 的整数运算会回绕。需要大数的地方写成浮点（如 `1.0`），见 `SDP_Board` 的邻居编码。

## deploy.py — 部署

```bash
python3 -I tools/deploy.py --dry-run    # 只显示会改什么
python3 -I tools/deploy.py              # 校验通过后同步
```

- 目标：Mac `~/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/SmartDistrictPlanner/`，Windows `文档/My Games/Sid Meier's Civilization VI/Mods/SmartDistrictPlanner/`；`--mods-dir` 可改。
- 增量复制，并删除部署目录里源目录已没有的文件；只动 `Mods/SmartDistrictPlanner/` 内部。
- 结尾提示重载方式：改了 modinfo 或 `Text/` 要重启游戏，否则回主菜单重新进入对局即可。

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

## game.py — 启动与进入对局

```bash
python3 -I tools/game.py quit                          # 经 Tuner 退出游戏并等待进程结束
python3 -I tools/game.py menu                          # 退回主菜单（只改了 Lua/UI XML 时用它重载，不必重启）
python3 -I tools/game.py launch                        # open steam://rungameid/289070，等启动器出现（Steam 有时要 1 分钟以上）
# 然后用 computer-use 对启动器（com.aspyr.civ6.steam）的"开始"按钮做 AXPress
python3 -I tools/game.py newgame --state SDP_Panel --capital   # 等主菜单→快速开始→等指定 Lua 状态可用→用开局开拓者建首都
python3 -I tools/game.py popups --close                # 关掉排队中的游戏弹窗（历史时刻等），规划面板才会显示
python3 -I tools/game.py newgame --state SDP_Panel --capital --reveal   # 另外揭示首都周围 12 格（城址、多城测试需要）
```

`popups --close` 调用每个弹窗自己的 `OnClose`/`Close`（与点它的关闭按钮相同），找不到才直接出队；反复检查直到连续两次没有弹窗。原因：自然奇观等弹窗打开时占住游戏的事件队列，只出队不释放，UI 里的游戏数据（如揭示状态）就停止更新（AGENTS 坑 24）。

`--reveal`（与 `--capital` 一起用）：建城后在 `GameCore_Tuner` 执行 `tests/fixtures/reveal_area.lua`，揭示首都周围 12 格，再关掉随之出现的自然奇观弹窗。第 1 回合只揭示了城市附近，城址候选要求三环内多半已揭示，不揭示时城址和多城测试会跳过。

`--ruleset RULESET_STANDARD | RULESET_EXPANSION_1 | RULESET_EXPANSION_2` 指定规则集（默认为"快速开始"的选择，即已安装的最新资料片）。

`newgame` 默认固定领袖（`--leader LEADER_TRAJAN`）和地图/游戏种子（`--seed 20261019`），做法是包装主菜单状态里的全局 `GameSetup_RefreshParameters`："快速开始"重置配置后会调用它。所以每次都是同一张地图；`--random` 恢复随机。

只改了 Lua 或 UI XML：`deploy.py` → `game.py menu` → `game.py newgame --state SDP_Panel --capital` → `run_tests.py`（约 30 秒）。

改 modinfo 或文本后的完整循环：`deploy.py` → `game.py quit` → `game.py launch` → 点"开始" → `game.py newgame --state SDP_Panel --capital` → `run_tests.py`。

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
