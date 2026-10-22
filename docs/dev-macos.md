# macOS 开发环境

两个平台共用的约定在 [AGENTS.md](../AGENTS.md) 第 6 节。本文只写 Mac 这台机器上的情况，以及只在 Mac 上能用的工具。

## 本机环境（2026-10-19 检查）

- 可用工具：`node`（v26）、`xmllint`、`sqlite3`、`python3`（3.8）、`git`。
- 文明6 Mac 版（Aspyr）：版本 **1.0.12.54 (951533)**，universal 二进制（原生 arm64），**Expansion1（R&F）、Expansion2（GS）及全部 DLC 已安装**（现在的账号没有其中一部分 DLC，见下一节）。显示语言 `zh_Hans_CN`，窗口模式（`FullScreen 0`），开场动画已关（`PlayIntroVideo 0`）。
- DMT（2428969051，2024-01-17 版）、AMT r49（3771382002，2026-09-19 版）、Empire Planner（3793348626）已通过创意工坊同步到本机（2026-10-22 起只订阅 DMT，见下一节）。
- 工作目录在 iCloud Drive。iCloud 会给文件加扩展属性（codesign 因此失败过），也可能同步出"文件 2"这类冲突副本；改用 GitHub 后建议把工作副本移出 iCloud。

## Steam 账号与 DLC（2026-10-22 起）

2026-10-22 起这台 Mac 用维护者自己的 Steam 账号。在此之前的测试、截图和离线对比数据，用的是合作者的账号（全部 DLC）。

- **资料片**：迭起兴衰、风云变幻都有，三种规则集都能测。
- **没有的 DLC**（游戏里 `Modding.GetInstalledMods()` 的 `Allowance=false`）：拜占庭和高卢、越南和忽必烈、玛雅和大哥伦比亚、埃塞俄比亚、巴比伦、葡萄牙、尤里乌斯·凯撒、伟大的建设者、伟大谈判者、伟大指挥官、中国统治者、英国统治者、撒哈拉统治者、凯瑟琳·德·美第奇、泰迪·罗斯福领袖包、猫咪侦察兵。DLC 文件还在磁盘上，但游戏不加载。所以：
  - 规则里没有**保护区**（及古树林、避难所，来自越南和忽必烈包）和**外交区**（来自埃塞俄比亚包），也没有这些包里的文明。涉及它们的游戏内测试按规则跳过，不算失败。
  - 游戏内测试结果（2026-10-22）：风云变幻 94 通过、1 跳过；迭起兴衰 93 通过、2 跳过；原版 89 通过、6 跳过；真实点击 30 通过。
  - 离线对比的规则库 `tests/compare/.cache/gameinfo.lua` 是 2026-10-20 在全 DLC 的账号上导出的，对比场景里有高卢、拜占庭、越南、玛雅。**不要在这个账号上重新导出**，否则这些场景缺规则；确需重导，换一个有全部 DLC 的账号。导出脚本会检查：游戏缓存里的文明比现有规则库少时拒绝覆盖，列出少了哪些。
- **创意工坊**：这个账号只订阅了 DMT（2428969051）。AMT、Empire Planner 没有订阅，离线对比要的代码是本地副本：`reference/amt`、`reference/ep` 是真实文件夹（`setup_reference.py` 不会覆盖），另有备份在 `~/Library/Application Support/SDP-reference-backup/`。游戏的 mod 列表里现在只有 DMT 和本模组，不会和其他规划器同开。
- **第一次用新账号启动游戏**：`steam://rungameid` 停在许可协议（Steam 日志 `console_log.txt` 中 `waiting for user response to ShowEula`），要用户在 Steam 里同意，然后再执行一次 `game.py launch`。
- Steam 的窗口由它的辅助进程显示，computer-use 截不到、点不到。订阅创意工坊物品这类操作请用户在 Steam 里做。

## 路径（`~/Library/Application Support/` 下）

`python3 -I tools/paths.py` 列出实际找到的位置。

| 用途 | 路径 |
|------|------|
| 游戏本体 UI 源码 | `Steam/steamapps/common/Sid Meier's Civilization VI/Civ6.app/Contents/Assets/Base/Assets/UI/` |
| DLC / 资料片 | `…/Civ6.app/Contents/Assets/DLC/{Expansion1,Expansion2,…}/` |
| 创意工坊 | `Steam/steamapps/workshop/content/289070/<id>/` |
| Mods（部署目标）、存档 | `Sid Meier's Civilization VI/Sid Meier's Civilization VI/{Mods,Saves}/` |
| 日志、规则库缓存 | `Sid Meier's Civilization VI/Firaxis Games/Sid Meier's Civilization VI/{Logs,Cache}/` |
| 配置 | 同上目录下 `AppOptions.txt`、`Mods.sqlite`（mod 启用状态：`ModGroupItems.Disabled`） |

**回滚**：同目录下 `AppOptions.txt.bak-20261019`、`Mods.sqlite.bak-20261019` 为修改前备份。

## 日志

- **Mac 版不生成 `Lua.log`**（`EnableTuner 1` 也不会），Lua 输出只能经 FireTuner 拿：`python3 -I tools/civ6tuner.py serve` 常驻，写到 `logs/tuner-lua.log`。
- 每次启动游戏，Logs 目录会被清空重写。
- `Logs/LoadGameViewState.log` 曾长到约 700 MB（反复写 `GAMECORE_LOAD_SAVEFILE_PENDING`），疑似读档卡住时刷出，与本项目无关但占空间。

## 启动与进入对局（已全自动化）

`game.py launch`（`open -g steam://rungameid/289070`）→ Aspyr 启动器（bundle `com.aspyr.civ6.steam`，"开始"按钮用 computer-use 的 `app_click`（AXPress）点，游戏在后台也能点）→ 主菜单 → `game.py newgame` 经 Tuner 在 `MainMenu` 状态执行 `Automation.SetAutoStartEnabled(true); OnPlayCiv6()` → 约 25 秒进入地图。

- `launch` 先记下前台应用，`newgame` 期间游戏一抢到前台就切回去。把文明6分配到单独的桌面后，测试基本不占用户的屏幕和键盘。本机接了多台显示器时，Dock 的"分配给"只有"显示器 N 上的桌面"，没有"此桌面"。
- 游戏不在前台时每秒约 120 帧，在另一个桌面上约 83 帧，测试照常（2026-10-20 实测）。
- `newgame` 进对局时把总音量设为 0（只对本次运行，`SoundOpts.txt` 不变）。
- **Steam 账号在别处运行游戏时**（2026-10-20 遇到）：`steam://rungameid` 会停在 Steam 的"踢掉另一会话"确认框（Steam 日志 `console_log.txt` 中 `waiting for user response to KickingOtherSession`），启动器不会出现。这需要用户决定，不要自行确认。

## computer-use 与真实点击

- 游戏窗口（Metal，标题 `Civilization VI (1920x1080 @ 174%)`）不向辅助功能暴露窗口。computer-use 截图可用（先 `app_release` 释放后台锁），**点击被工具的安全校验拒绝**（"Could not verify which document this window is editing"）。需要操作游戏时优先用 civ6tuner 在对应 Lua 状态里直接调用（如 `Mods` 状态的 `Modding.*`）。
- 真实点击用 `tools/realclick.py`：`tools/click/sdp-click.swift` 编译成 `~/Applications/SDPClick.app`，发系统鼠标事件（CGEvent），要用户在"系统设置 → 隐私与安全性 → 辅助功能"里授权一次。用法见 [tools/README.md](../tools/README.md)。
- 截图：先用 `open -W -n -g ~/Applications/SDPClick.app --args window --out 文件` 取游戏窗口位置，再用 computer-use 的 `zoom` 只截窗口内部（文档里的截图不带 macOS 菜单栏、标题栏和 Dock）。
- 长时间无人值守跑测试时，用 `caffeinate -dims -t 秒数` 防止锁屏，跑完停掉。

## 本机的测试 mod 组

本机共启用 165/166 个 mod。2026-10-19 在 `Mods.sqlite` 新建并选中 **"SDP 测试"** 组（`ModGroupRowId=2`）：官方内容沿用默认组状态（39 启用、Tutorial 禁用），创意工坊仅启用 DMT。默认组（`ModGroupRowId=1`）同时启用了 AMT，切回默认组就会两个规划器同开（坑 20）。

（2026-10-22 起换了 Steam 账号，创意工坊只订阅 DMT，下面这段 TopPanel Extension 的情况已不存在。）

2026-10-20 下午本机订阅了 TopPanel Extension（创意工坊 2997927787），它在"SDP 测试"组里是启用的。它只改顶栏，不碰地图钉；自动回合以观察者观察时它的 `RefreshFood` 会反复报运行错误（它自己的问题）。要停用它需在游戏关闭时改 `Mods.sqlite`，先问用户。
