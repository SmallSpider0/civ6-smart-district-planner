# Contributing

[English](#english) | [中文](#中文)

## English

### Languages

Issues and pull requests can be written in English or Chinese. The development documents (AGENTS.md, docs/, tools/README.md) are in Chinese. Players can start with the English part of the [README](README.md#english) and the [English install guide](docs/install-en.md).

### Before you start

- A feature, a change to a default value or a change to the panel starts as an issue. The maintainers decide the plan there; start coding once it is decided.
- A bug fix can go straight to a pull request. Add a test that fails on the old code and passes with the fix.

### Hard constraints

The full list is in [AGENTS.md](AGENTS.md) (sections 2, 4 and 5). In short:

- The mod is a pure Lua UI mod. No C++ or DLL.
- Whether a district fits on a tile, and its adjacency bonus, come from Detailed Map Tacks. Do not write your own version of these rules.
- Game rules are read from GameInfo. Never hardcode a civilization's, district's or building's rule or number.
- Results are deterministic: the same input gives the same plan.
- Every player-facing text exists in English and Chinese.
- The repository holds no code or data from other mods or from the game. `reference/` and `tests/compare/.cache/` stay on your machine and are git-ignored.

### Setup

Fork the repository and clone your fork. Then install the tools:

```
cd tools && npm ci        # luaparse and fengari for the Lua checks and offline tests
```

Python 3.8 or later is needed; the scripts use only the standard library. The commands below are written `python3 -I`; on Windows use `py -3 -I`.

If you own Civilization VI:

```
python3 -I tools/paths.py             # list where the game, the Workshop and the user folder were found
python3 -I tools/setup_reference.py   # link the game's UI code, Detailed Map Tacks and other references into reference/
```

Set `EnableTuner 1` in `AppOptions.txt` (close the game first) so the tools can talk to the game through FireTuner on 127.0.0.1:4318. Steam achievements are not unlocked while it is on. The setup for each platform is in [docs/dev-macos.md](docs/dev-macos.md) and [docs/dev-windows.md](docs/dev-windows.md) (Chinese).

### Checks without the game

```
python3 -I tools/validate.py                         # XML, modinfo, text keys, Lua syntax, banned globals
node tools/offline_tests.mjs                         # all offline specs, a few minutes
node tools/offline_tests.mjs tests/offline/spec_xxx.lua   # one spec file
python3 -I -m unittest discover -s tests/tools       # tests of the Python tools
```

`validate.py` also checks that the UI XML only uses controls and attributes the game itself uses. That check needs `reference/` and is skipped without it. CI runs these checks on Ubuntu and Windows for every pull request.

### In-game tests

These need the game. In Additional Content, make a mod group with only the official content, Detailed Map Tacks and this mod. Then:

```
python3 -I tools/deploy.py                                       # validate, then copy the mod into the game's Mods folder
python3 -I tools/game.py newgame --state SDP_Panel --capital     # start the fixed test game and found the capital
python3 -I tools/run_tests.py tests/test_xxx.lua                 # run one test file inside the game (-k filters by name)
```

- Do not subscribe to this mod on the Steam Workshop. The game may load the Workshop copy instead of yours ([pitfall 38](docs/pitfalls.md)).
- Keep the modinfo `version` on your branch equal to the one on `main`. A lower version makes the game mark the mod as disabled, and `deploy.py` refuses it ([pitfall 45](docs/pitfalls.md)). Merge `main` into your branch before testing.
- After changing modinfo or text files, restart the game. The full loop and every option are in [tools/README.md](tools/README.md) and AGENTS.md section 6.

### Code conventions

- Prefix our Lua files, globals and LuaEvents with `SDP_` or `sdp_`, and text keys with `LOC_SDP_`. Add every new key in both languages.
- Write plain Lua 5.1. In the game `_G`, `load`, `require`, `debug`, `utf8`, `table.unpack` and some others are nil (AGENTS.md section 6 has the list; `validate.py` reports them).
- No result may depend on the order of `pairs()`. Collect into an array, sort by a stable key, then use `ipairs`. Every tie needs a fixed secondary key. No `math.random` and nothing based on time.
- Tests of the panel go through the controls' own callbacks, not internal functions.
- Tests do not hardcode one civilization's rules. Read them from the rules the test game has.

### Submitting a pull request

- Work on a branch of your fork. One issue per pull request; write `Closes #N` in the description.
- Write the title as an English imperative sentence. Pull requests are squash-merged, so the title becomes the commit on `main`.
- Fill in the pull request template: which tests you ran, on which platform, and why any were skipped.
- If players will notice the change, add a line under 未发布 in [CHANGELOG.md](CHANGELOG.md).
- If you commit generated files (comparison or stress results, images), name them and the command that made them.
- Both CI checks, `offline (ubuntu-latest)` and `offline (windows-latest)`, must pass.
- The maintainers review every pull request. Changes to code also get an automated review by Codex.

### Writing

- Names from the game (districts, buildings, wonders, civilizations, leaders, terrain, resources, interface) use the game's own words in both languages. Do not translate them yourself.
- Settled English words: tile (not plot), valid (not legal), map tack or tack (not pin), specialty districts, City Center, Woods, Rainforest, Marsh, Floodplains, Volcanic Soil, Housing, Appeal, Amenities, Additional Content, Key Bindings, the toolbar at the upper left (not launch bar).
- Write plainly. Say each thing once. Describe a feature directly, without labels such as "new".

### License and third-party content

The code is released under the [MIT license](LICENSE).

Detailed Map Tacks, Auto Map Tacks Planner, Empire Planner and the game belong to their authors. Do not copy their code or data into the repository.

## 中文

### 语言

Issue 和 PR 用中文或英文都可以。开发文档（AGENTS.md、docs/、tools/README.md）是中文的。

### 开始之前

- 功能、默认值的改动、面板的改动，先提 Issue。维护者在 Issue 里定方案，定了再写代码。
- 修 bug 可以直接开 PR，附一个在旧代码上失败、修好后通过的测试。

### 硬约束

完整的在 [AGENTS.md](AGENTS.md) 第 2、4、5 节。要点：

- 纯 Lua UI Mod，不碰 C++/DLL。
- 区域能不能放、相邻加成多少，都用 Detailed Map Tacks 算，不自己重写。
- 规则从 GameInfo 读，不写死任何文明、区域、建筑的规则或数值。
- 结果确定：同样的输入给出同样的方案。
- 玩家看到的文字都有中英文两份。
- 仓库里不放别的模组或游戏本体的代码和数据。`reference/` 和 `tests/compare/.cache/` 只在本机，已 gitignore。

### 环境

fork 仓库，克隆你的 fork，然后装工具：

```
cd tools && npm ci        # 装 luaparse、fengari，Lua 检查和离线测试要用
```

需要 Python 3.8 以上，脚本只用标准库。下文命令写作 `python3 -I`，Windows 上换成 `py -3 -I`。

有《文明6》时：

```
python3 -I tools/paths.py             # 列出找到的游戏、创意工坊和用户目录
python3 -I tools/setup_reference.py   # 在 reference/ 下链接游戏界面代码、Detailed Map Tacks 等参考源码
```

在 `AppOptions.txt` 里设 `EnableTuner 1`（先关游戏），工具经 FireTuner（127.0.0.1:4318）和游戏通信。开着它时不解锁 Steam 成就。两个平台的环境见 [docs/dev-macos.md](docs/dev-macos.md) 和 [docs/dev-windows.md](docs/dev-windows.md)。

### 不开游戏的检查

```
python3 -I tools/validate.py                         # XML、modinfo、文本键、Lua 语法、禁用全局
node tools/offline_tests.mjs                         # 全部离线测试，几分钟
node tools/offline_tests.mjs tests/offline/spec_xxx.lua   # 一个测试文件
python3 -I -m unittest discover -s tests/tools       # Python 工具的测试
```

`validate.py` 还检查界面 XML 只用游戏本体用过的控件和属性，这一项要 `reference/`，没有时跳过。每个 PR 的 CI 在 Ubuntu 和 Windows 上跑这些检查。

### 游戏内测试

要有游戏。在“额外内容”里建一个只开官方内容、Detailed Map Tacks 和本模组的模组组。然后：

```
python3 -I tools/deploy.py                                       # 校验后把模组复制到游戏的 Mods 目录
python3 -I tools/game.py newgame --state SDP_Panel --capital     # 开固定的测试对局并建首都
python3 -I tools/run_tests.py tests/test_xxx.lua                 # 在游戏里跑一个测试文件（-k 按名字筛选）
```

- 不要在创意工坊订阅本模组，游戏可能加载那一份而不是你的（[坑 38](docs/pitfalls.md)）。
- 分支上 modinfo 的 `version` 和 `main` 保持一致。版本号更低时游戏把本模组记成停用，`deploy.py` 会拒绝（[坑 45](docs/pitfalls.md)）。测试前先把 `main` 并进分支。
- 改了 modinfo 或文本要重启游戏。完整流程和各个选项见 [tools/README.md](tools/README.md) 和 AGENTS.md 第 6 节。

### 代码约定

- 自有 Lua 文件、全局符号、LuaEvents 用 `SDP_` 或 `sdp_` 前缀，文本键用 `LOC_SDP_`，新键中英文都加。
- 写纯 Lua 5.1。游戏里 `_G`、`load`、`require`、`debug`、`utf8`、`table.unpack` 等是 nil（清单在 AGENTS.md 第 6 节，`validate.py` 会报）。
- 结果不能依赖 `pairs()` 的顺序：先收集成数组、按稳定的键排序，再用 `ipairs`。同分要有固定的次级键。不用 `math.random`，不用和时间有关的逻辑。
- 面板的测试经过控件自己的回调，不直接调内部函数。
- 测试不写死某个文明的规则，从测试对局的规则里读。

### 提交 PR

- 在你 fork 的分支上做。一个 Issue 一个 PR，描述里写 `Closes #编号`。
- 标题用英文祈使句。PR 以 squash 合并，标题就是 `main` 上的提交。
- 填 PR 模板：跑了哪些测试、在哪个平台，没跑的写原因。
- 玩家能感觉到的变化，在 [CHANGELOG.md](CHANGELOG.md) 的“未发布”下加一行。
- 提交了生成的文件（对比或压力测试结果、图片）时，写明是哪些文件、用什么命令生成的。
- CI 的两项检查 `offline (ubuntu-latest)`、`offline (windows-latest)` 都要通过。
- 每个 PR 由维护者审阅；改了代码的还会由 Codex 自动审一遍。

### 写作

- 游戏里的名称（区域、建筑、奇观、文明、领袖、地貌、资源、界面）中英文都用游戏自己的，不自己翻译。
- 已定的英文：tile（不是 plot）、valid（不是 legal）、map tack / tack（不是 pin）、specialty districts、City Center、Woods / Rainforest / Marsh / Floodplains / Volcanic Soil、Housing、Appeal、Amenities、Additional Content、Key Bindings、the toolbar at the upper left（不是 launch bar）。
- 写得平实，同一个意思只写一次。直接描述功能，不加“新功能”“新加”之类的标签。

### 许可证与第三方内容

代码以 [MIT](LICENSE) 许可发布。

Detailed Map Tacks、Auto Map Tacks Planner、Empire Planner 和游戏本体归各自的作者所有，不要把它们的代码或数据复制进仓库。
