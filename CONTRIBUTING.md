# 参与开发

> The development documents of this project are in Chinese. Issues and pull requests in English are welcome. For players: the English part of the [README](README.md#english) and the [English install guide](docs/install-en.md).

仓库：<https://github.com/SmallSpider0/civ6-smart-district-planner>。开发在 macOS 和 Windows 两台机器上进行，双方都用 Claude Code。仓库根目录的 `CLAUDE.md` 让 Claude Code 自动读入 [AGENTS.md](AGENTS.md) 和本文，所以这两份既写给人，也写给代理。

## 先读

- [AGENTS.md](AGENTS.md)：需求约束、技术方案、44 条坑的要点（完整说明在 [docs/pitfalls.md](docs/pitfalls.md)）、每轮改动流程。
- [.claude/skills/](.claude/skills/)：Issue 处理、游戏内测试、离线重活、发版、监听的固定步骤，Claude Code 按需加载；人照着做也一样。
- 当前平台的环境说明：[docs/dev-macos.md](docs/dev-macos.md) 或 [docs/dev-windows.md](docs/dev-windows.md)。
- [tools/README.md](tools/README.md)：每个工具的用法。

## 需求、分支与提交

一轮工作的流程：

1. **记成 Issue**：维护者或合作者在 GitHub 上提；在对话里告诉 Claude 的，由它来提。什么时候挂里程碑（如 `v1.1.0`）：bug 在确认是 bug 时挂到下一个小版本；功能和优化在维护者定了方案时挂，版本号哪一位见下文“发版”第 1 步，那个版本的里程碑还没有就这时建。还在调研、等决定的 Issue 不挂，所以里程碑页面看到的就是这一版定下要做的和还剩几项。
2. **先调研、再确认**（明显的 bug 修复除外）：功能和优化类的 Issue，先用子 agent 调研规则库与游戏本体代码、玩家社区的做法和对比模组的做法，整理成“已查证的规则 / 玩家共识 / 个别意见 / 建议方案”写进 Issue。要维护者拿主意的地方列在评论里（方案 A、B，附建议），方案由维护者在 Claude Code 里拍板，或由合作者在 Issue 下明确回复（选定方案、回答待定问题）来定，定了再开发；只回答了一部分的，答了的部分算定，其余照旧等。两人意见不同时以维护者为准。决定不做的，在 Issue 下写明原因后关掉（选 not planned）；决定以后再说的，打 `later` 标签，不挂里程碑，想做时再拿出来。
3. **一个 Issue 一个分支、一个 PR**：分支上可以分几个提交，提交信息里写 `#编号`；分支上随便推，不开 PR 就不跑 CI。几个改同一块、拆开反而互相依赖的 Issue（比如同一套公式）合成一个 PR。PR 描述里每个 Issue 写一行 `Closes #编号`，合并时自动关闭。
4. **测过就合并**：这个 Issue 相关的测试过了（`validate.py`、相关的离线测试和游戏内测试文件）就开 PR，CI 通过后合并。合并到 `main` 不会到玩家手里，所以不用等同一里程碑的其他 Issue。
5. **里程碑是发版的单位**：一版的 Issue 都合并后，开一个发版准备的 PR（版本号、CHANGELOG、更新说明、截图、自测报告、压力测试结果），整套测试在这时跑一次（见“测试分工”）。
6. **发版**：只有修 bug 的小版本，攒够三个普通 bug、离第一个修复合并满七天，或修好一个严重 bug 时直接发；有功能或优化的版本，测过后由维护者决定什么时候发。然后发 Release、更新创意工坊（见下文“发版”）。

**用 Claude Code 时谁来做**（2026-10-26 定）。三个词：**主会话**是维护者平时对话的那个会话；**子会话**是主会话另开的会话，在侧栏里能打开、能直接对话，有自己的工作树；**子 agent** 是在一个会话里临时派出去、做完把结果交回来的助手，看不到过程。

| 工作 | 谁做 |
|---|---|
| 调研、测量、读大量代码、整理公式（只要结论） | 子 agent |
| 一个 Issue 的开发（自己的分支和 PR，要测试、可能等夜里的游戏内测试、要返工） | 子会话，各用自己的工作树；做完归档 |
| 几行就能改完的小修（文字、提示、只改文档的规则） | 主会话 |
| 分派、转达 Issue 上的决定、里程碑、状态页、夜间队列、Issue 监听、对外页面（创意工坊） | 主会话 |

子会话开工时拿到完整的要求（Issue、已定的方案、分支基于哪里、测什么），之后的决定由主会话转过去。“并行会话”“所有会话共用”里的“会话”指任何一个在用这台机器的会话或人，主会话、子会话都算。

一个 PR 跑一次 CI（每次约 6 分钟；只在 PR 上跑，合并后 `main` 上不再重跑）。这是 2026-10-26 改的，之前是一批 Issue 一个 PR：大多数开源项目一个改动一个 PR，小 PR 好审、好回退，分支活得短不容易冲突，一项卡住也不拖累别的。

- 后续修改推到已开的 PR 上，不另开 PR。往 PR 上推新提交会取消这个 PR 还没跑完的那一轮，所以攒几个提交一起推。
- 只改文档的小修正不单独开 PR，带进下一个 PR。只改文档的 PR（`docs/`、`.md` 文件、问题模板）CI 只跑 `validate.py`，跳过离线测试。
- 游戏内测试只能晚些跑时（比如机器白天有人用），PR 先开着不开自动合并，测完再开。
- `main` 受保护，所有改动（包括错字这类小的文档修正）都在分支上做、开 PR，CI 的两项检查 `offline (ubuntu-latest)`、`offline (windows-latest)`（validate 和离线测试）通过后才能合并。不能直接推送、强制推送或删除 `main`；仓库管理员可以绕过。
- GitHub 不要求审批人数，但合并前请另一人看一下。
- 仓库只允许 squash 合并：一个 PR 在 `main` 上只留一个提交，标题就是 PR 标题。所以 PR 标题用英文祈使句写清做了什么。
- 仓库开了自动合并：PR 页面点 **Enable auto-merge**（或 `gh pr merge 编号 --auto --squash`），两项检查通过后 GitHub 自己合并，检查没过就不合并。合并后 GitHub 自动删掉远端分支，本地分支自己删。
- 分支名写平台或人和主题，如 `win/ui-scale`、`mac/stress-marsh`。
- 分支里的提交信息也用英文祈使句，与 `git log` 里已有的一致。
- 生成的结果在 PR 描述里写明是哪些文件、用什么命令生成的（squash 合并后分支里的提交合成一个，单独提交在 `main` 上看不出来）：
  - `tests/compare/results/`
  - `tests/stress/results/`
  - `docs/images/`、`workshop/images/`
  - 自测报告里由脚本写入的表
- 两人不要同时重跑同一组结果；要重跑时先在 PR 或 Issue 里说一声。
- 行为有变化时同步更新相关文档，并在 [CHANGELOG.md](CHANGELOG.md) 的“未发布”里加一行，写玩家能感觉到的变化。发版时这一段就是更新说明。

## 测试分工

| 测试 | 谁跑 | 什么时候 |
|------|------|----------|
| `validate.py`、离线测试 | CI 自动 | 每个 PR（只改文档时只跑 `validate.py`） |
| 游戏内 `run_tests.py` | 改动者，在自己的平台 | 改了 mod 代码 |
| 离线对比 `compare.mjs -p sdp`（开发集） | 改动者 | 改了求解器或合法性规则 |
| 真实点击 `realclick.py` | macOS | 改了界面 |
| 界面缩放、分辨率、布局 | Windows | 改了界面 |
| 压力测试 `stress.py` | 任一平台 | 发布前（只改界面的版本不跑） |

- 每个 PR 跑和它相关的测试，整套留到发版前跑一次（离线测试几分钟，游戏内一种规则集约 2 分钟，离线对比十几到二十几分钟）：
  - 每个 PR：`validate.py`，相关的测试文件（`node tools/offline_tests.mjs tests/offline/spec_xxx.lua`、`python3 -I tools/run_tests.py tests/test_xxx.lua`，可加 `-k` 按名字筛选），改了求解器或合法性规则时跑离线对比的开发集；整套离线测试 CI 会跑。
  - 发版前：三种规则集的整套游戏内测试、真实点击、压力测试、需要时的离线对比，按发版清单跑一次。中途改了再补跑受影响的部分，不必整套重跑。
- PR 里写明在哪个平台跑了哪些测试，没跑的写原因。
- 先跑游戏内测试，再跑离线的重活。`compare.mjs` 多线程运行时，游戏会被拖到几分钟一回合。
- 游戏内测试可以直接跑，不用事先问。改 `AppOptions.txt`、`Mods.sqlite` 前要先问，并且游戏要关着。
- 汇报时分清"已自动验证"和"需人确认"，不要把没验证过的说成通过。

## 发版

`main` 上攒的改动不会直接到玩家手里，玩家只拿到打了 tag 的版本。步骤见发版清单（新建 Issue 时选“发版清单”模板），大致是：

1. 定版本号，按改动的大小分（2026-10-26 起；之前“同样的设置给出不同方案”就升第二位，结果几乎每版都升第二位）：
   - 第三位（v1.0.1）：修 bug；文字、提示；界面布局的小改；默认值、参数、权重和预设数值的调整；求解和计分的局部改进（方案会变也算）；性能优化；
   - 第二位（v1.1.0）：加了一类新能力（新页签、新玩法开关、新的规划对象），或某块功能大改（如目标公式、评分体系重做）；
   - 第一位：存档或设置不兼容、依赖变了、整体重做。

   版本号不再说明“方案会不会变”，所以会让同样的设置给出不同方案的改动，在 CHANGELOG 和更新说明里写明（如“默认最远距离从 8 改成 5，城址会更密”）。版本号也不决定要不要等维护者：只修 bug 的版本按“需求、分支与提交”第 6 步自动发，其余都等维护者决定，第三位的也一样。

   一版攒几项改动再发，挂在同一个里程碑上，不为单项发版；只有线上版本的严重问题单独发（见下文“其他情况”）。modinfo 的 `version` 每次发版加 1；`SmartDistrictPlanner/UI/SDP_Panel.lua` 的 `VERSION` 改成新版本号，启动栏按钮的悬停提示显示它，`validate.py` 检查它和 CHANGELOG 最新的版本一致。
2. 发版前测试：三种规则集的游戏内测试、macOS 真实点击、后期存档压力测试（只改界面、不动求解和计分的版本不跑；不用在 Windows 上手动测）；改了求解器还要跑离线对比。
3. 准备文字：CHANGELOG 的“未发布”改成 `vX.Y.Z（日期）`；写 `workshop/changenotes/vX.Y.Z.txt`（英文在前、中文在后）；功能或限制变了，同步 README、`workshop/` 的中英简介（`description.bbcode`、`description_zh.bbcode`）和介绍与评测页。这些放在发版准备的 PR 里。
4. 在 GitHub 发布 Release `vX.Y.Z`，发布说明写给玩家，英文在前、中文在后。`.github/workflows/release.yml` 会：
   - 打出 `SmartDistrictPlanner-vX.Y.Z.zip`（mod、中英安装与使用说明、`REPORT.html`、`REPORT_EN.html`；不带给测试者的说明），连同中英两个单文件页面一起附到 Release；
   - 打出 `SmartDistrictPlanner-vX.Y.Z-workshop.zip`（创意工坊提交包，`tools/workshop.py pack`）附到 Release；
   - 生成介绍与评测页，发布到 GitHub Pages（中文 <https://smallspider0.github.io/civ6-smart-district-planner/>，英文在 `en/`）。
5. 用提交包更新创意工坊，见 [docs/workshop-upload.md](docs/workshop-upload.md)：维护者在 Mac 上用 SteamCMD（贡献者账号能更新内容、英文标题与简介、更新说明，不能换预览图），或合作者在 Windows 上传。物品页的图片和简体中文版本在网页上改，提交包里的 UPLOAD.md 写明这次要动哪些。本仓库的工具不连接 Steam。

其他情况：

- **想先给少数人试**：发布时勾选 pre-release，标签如 `v1.1.0-rc.1`。只附压缩包和单文件页面，不更新网页，也不打工坊提交包。
- **线上版本有严重问题，而 `main` 上已有没准备好的改动**：从上一个 tag 拉出 `release/1.0` 分支修好，发 v1.0.1，再把修复合回 `main`。
- **平时给测试者一个包**：本地跑 `python3 -I tools/package.py`，包名是提交号，里面带测试说明 `TEST_GUIDE.md`。
- **并行开发**：几个需求可以在不同分支上同时写，但游戏内测试只有一个游戏、一个 Tuner 连接，只能一个一个跑。

## 写作规则

适用于界面文字、文档、报告和 PR 说明。

- 用中文；代码标识符和注释用英文或中文都可以，但同一个文件里保持一致。例外：README、创意工坊的更新说明和 GitHub 发布说明英文在前、中文在后；创意工坊的标题和简介英文、中文各一份（物品页上的两个语言版本）；问题反馈模板中英并列；英文安装说明 `docs/install-en.md` 和英文介绍页只用英文。README 和安装说明改了中文，英文同步改。
- Issue 里的调研和方案评论写给懂游戏、不看代码的人：方案和待定问题用玩家看得到的东西说（面板上的名字、地图上会变成什么样、举一个具体例子），每个待定问题写成一句能直接回答的问话并附建议；代码位置、公式、命令和数字出处放在评论末尾折叠的“技术细节”（`<details>`）里，正文不出现变量名、公式符号和内部用词。
- 写得平实：
  - 不用套话和 AI 腔，比如“赋能”“全面提升”“值得注意的是”；
  - 同一个意思只写一次，不重复已经说过的话。
- 直接描述功能，不加"新功能""新加""新指标"之类的标签。
- 游戏里的名称（区域、建筑、奇观、文明、领袖、地貌、资源、界面）中英文都用游戏自己的，不自己翻译。核对办法：解析 `Civ6.app/Contents/Assets` 下 Base 和全部 DLC 的文本 XML（`DebugLocalization.sqlite` 只有最后加载的规则集），按 Tag 或中文查。已定的英文：tile（不是 plot）、valid（不是 legal）、map tack / tack（不是 pin）、specialty districts、City Center、Woods / Rainforest / Marsh / Floodplains / Volcanic Soil、Housing、Appeal、Amenities、Additional Content、Key Bindings、the toolbar at the upper left（不是 launch bar）。PR 里列出这次核对过的术语和出处。
- 测试项数、耗时这类数字只写在自测报告和“介绍与评测”页里（由脚本生成或刷新），其他文档链接过去，免得过时。
- 例外：面板开关的悬停提示写给玩家，分三段（中间空一行）：这个开关做什么（背后的游戏规则）、收益、代价；不用“候选格”“求解”这类内部词，不重复勾选框已经显示的默认值。收益尽量写成实测的百分比（如“相邻加成平均高 x%”），代价写手动操作和耗时倍数。数字的出处（场景、档位、命令、结果文件）记在 [docs/notes/](docs/notes/) 里对应 Issue 的记录，结果文件放在 `tests/compare/results/`。改了算法、规则或测试集后，按发版清单重跑并更新这些数字。
- 截图只截游戏画面，不带系统菜单栏、标题栏、任务栏或 Dock。放在 `docs/images/`，按 `v<轮次>-<内容>.jpg` 命名，英文界面的加 `-en-`；有中英文两版的画面两版都拍（`tools/shots.py`）。
- 对外的文档（README、安装说明、介绍页、创意工坊简介和图片、测试者说明）只写本模组自己：能做什么、怎么用、不做什么、局限，数字只和真最优或本模组自己的设置比。别的模组只出现在“同类模组”对照表、“一局只开一个规划器”的提醒和致谢里：对照表只有一张，只列事实（规划什么、依赖、规则集、语言、同开限制，页面里有无用画的图标、README 用 ✓ / ◐ / —），表里没列的功能另列一行，不写“适合……”这类评语；链接对方页面，写明核对日期，不放分数、不排名次。表的内容在 `report/similar.py`，页面和 README 都从它来。配图用自己画的示意图和图表，不用游戏截图，图里同样只放事实。与别的规划模组的离线对比结果写在 [docs/notes/planner-comparison.md](docs/notes/planner-comparison.md)，措辞中性，对外页面不链接。（#82）
- “介绍与评测”页由 `report/build.py` 生成，正文 7 节写给玩家，技术内容放在附录。中文页、英文页内容相同，附录也有英文版；改了一页就同步改另一页（`report/template.html` 与 `report/template_en.html`，附录里的图（`part_*_en.html`、`hexfig_en.svg.txt`）、`build.py` 生成的句子和表格、图表文字（`build.py` 的 `CHART_WORDS`）都要有英文）。用 Claude 做的页面（artifact）沿用这个页面的样式和写法。

## 许可证与第三方内容

代码以 [MIT](LICENSE) 许可发布。

仓库里没有 DMT、AMT、Empire Planner 和游戏本体的代码或数据。`reference/` 和 `tests/compare/.cache/` 只在本机，已 gitignore，不要提交进来。
