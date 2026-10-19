# tools/

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

- `exec`/`states` 优先走 `serve` 守护进程（控制端口 127.0.0.1:43180），没有守护进程时直接连游戏。
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

**常用 Lua 状态**（对局内）：`InGame`（UI 主上下文）、`GameCore_Tuner`（游戏核心，读状态用）、`dmt_yieldcalculator`（DMT 的 `CanPlacePin`/`GetBonusYields` 等都在这里）、`MapPinManager`。UI 状态中 `_G` 为 nil，直接用全局名访问。

**注意**：
- 开启 Tuner 时游戏**不会解锁 Steam 成就**。
- 游戏退出或重载时连接会断，`serve` 每 2 秒自动重连。
- **读取画面期间 Tuner 不响应握手和状态查询**（输出帧照常推送）；此时若断开连接，4318 会暂停监听，直到进入对局才恢复。所以读档/开局期间不要重启 `serve`。
- 4319 端口能连上但不处理请求，客户端默认只用 4318。
- 协议说明见 `civ6tuner.py` 文件头注释；协议格式参考了社区项目 [lmwilki/civ6-mcp](https://github.com/lmwilki/civ6-mcp)（MIT）的公开说明，代码为独立实现。
