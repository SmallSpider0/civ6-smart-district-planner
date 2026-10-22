# Windows 开发环境

两个平台共用的约定在 [AGENTS.md](../AGENTS.md) 第 6 节。本文写怎么在 Windows 上把环境搭起来，以及哪些工具暂时只能在 Mac 上用。

**这些步骤还没有在 Windows 上完整走过。** 第一次照做时，遇到和实际不符的地方，请直接改本文并提交。

## 1. 装工具

- Git for Windows：默认设置即可。仓库的 `.gitattributes` 让工作副本保持 LF 换行。
- Python 3.8 以上（python.org 的安装包，带 `py` 启动器）。文档里的 `python3 -I …` 在 Windows 上写成 `py -3 -I …`。
- Node.js 22 或更新。
- Claude Code：在仓库根目录启动，它会读 `CLAUDE.md`。
- 设用户环境变量 `PYTHONUTF8=1`，让 Python 默认用 UTF-8。中文 Windows 默认是 GBK，工具里的文件读写虽然都写明了 UTF-8，控制台输出中文时仍可能出错。

## 2. 取代码

```bat
git clone https://github.com/<账号>/<仓库>.git
cd <仓库>\tools
npm ci
cd ..
```

不要放在 OneDrive 同步的文件夹里，同步会和 git 抢文件。

## 3. 指向游戏和其他 mod

1. 在创意工坊订阅 Detailed Map Tacks（2428969051，必需）。离线对比还要 Auto Map Tacks Planner（3771382002）和 Empire Planner（3793348626），不跑对比可以不订。
2. 检查位置：

   ```bat
   py -3 -I tools\paths.py
   ```

   每行显示 `ok` 或 `missing`。默认位置：

   | 用途 | 位置 |
   |------|------|
   | Steam | 注册表 `SteamPath`，其他库从 `libraryfolders.vdf` 读 |
   | Mods、存档 | `文档\My Games\Sid Meier's Civilization VI\{Mods,Saves}` |
   | 日志、规则库缓存 | `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\{Logs,Cache}`（缓存在"文档"那边也会找） |

   "文档"被 OneDrive 挪走时，按系统记录的位置找。仍然不对，就设环境变量：
   - `SDP_STEAM`：Steam 文件夹；
   - `SDP_GAME_DOCS`：放 Mods 的那个 `Sid Meier's Civilization VI` 文件夹；
   - `SDP_GAME_DATA`：放 Logs 的那个文件夹。
3. 建参考源码链接。下面的命令用目录联接，不需要管理员权限或开发者模式：

   ```bat
   py -3 -I tools\setup_reference.py
   ```

## 4. 打开 FireTuner 和 Lua 日志

先关掉游戏。

- 在 `AppOptions.txt` 里把 `EnableTuner` 改成 `1`。这个文件一般在 `文档\My Games\Sid Meier's Civilization VI\`，找不到就在 `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\` 找。改之前先复制一份备份。
- 打开 Tuner 后，游戏只在本机 127.0.0.1:4318 上监听，并且不再解锁 Steam 成就。不要同时开官方 FireTuner：游戏只接受一个连接。
- 在 Steam 里打开文明6的属性，启动选项填 `-log`。之后 Lua 日志写在 `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log`。Mac 版没有这个文件，这是 Windows 上额外多出的排错手段。

## 5. 测试用 mod 组

在游戏的"附加内容"里新建一个 mod 组，只开官方内容、DMT 和本 mod。不要同时开 AMT、Empire Planner 等规划器（坑 20）。

## 6. 每轮流程

```bat
py -3 -I tools\validate.py
node tools\offline_tests.mjs
py -3 -I tools\deploy.py
```

另开一个终端，让 Tuner 客户端常驻：

```bat
py -3 -I tools\civ6tuner.py serve
```

启动游戏：

- 从 Steam 启动，或者用 `py -3 -I tools\game.py launch`。
- 有启动器窗口时手动点开始。

然后进入测试对局，跑游戏内测试：

```bat
py -3 -I tools\game.py newgame --state SDP_Panel --capital --reveal
py -3 -I tools\run_tests.py
```

`game.py` 的 `quit`、`menu`、`popups`、`newgame` 都经 Tuner 执行，与 Mac 相同。

## 7. 暂时只能在 Mac 上用的

| 工具 | 原因 | Windows 上现在怎么做 |
|------|------|----------------------|
| `realclick.py` 真实点击 | 用 macOS 的 CGEvent 发鼠标事件，靠辅助功能授权 | 手动点。以后要移植，只需重写那个小的点击程序（改用 `SendInput`）。点哪里、点完怎么核对，都由游戏里的 Lua 算出，可以直接复用。 |
| `game.py launch` 的前台切换 | 用 `lsappinfo`、`open -b` | 游戏启动时会到前台，等它进对局即可 |
| 文档截图 | Mac 上用 computer-use 截取游戏窗口 | 用系统截图（Win+Shift+S）只截游戏画面 |

`stress.py` 经 Tuner 运行，存档位置由 `paths.py` 给出，应该能直接用，但还没在 Windows 上跑过。

## 8. Windows 上重点看什么

- 界面布局：在 100% 和 150% 界面缩放、不同分辨率下各看一次。Mac 上只测了一种缩放。
- 耗时：同样的操作和 Mac 上的数字对比（见自测报告）。
- 游戏有 DirectX 11 和 DirectX 12 两个程序，界面问题注明用的是哪个。
