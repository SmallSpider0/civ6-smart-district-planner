# 参与开发

> The development documents of this project are in Chinese. Issues and pull requests in English are welcome. For players: the English part of the [README](README.md#english) and the [English install guide](docs/install-en.md).

仓库：<https://github.com/SmallSpider0/civ6-smart-district-planner>。开发在 macOS 和 Windows 两台机器上进行，双方都用 Claude Code。仓库根目录的 `CLAUDE.md` 让 Claude Code 自动读入 [AGENTS.md](AGENTS.md) 和本文，所以这两份既写给人，也写给代理。

## 先读

- [AGENTS.md](AGENTS.md)：需求约束、技术方案、37 条坑、每轮改动流程。
- 当前平台的环境说明：[docs/dev-macos.md](docs/dev-macos.md) 或 [docs/dev-windows.md](docs/dev-windows.md)。
- [tools/README.md](tools/README.md)：每个工具的用法。

## 需求、分支与提交

- 每个需求或问题开一个 Issue。打算放进下一版的，挂到对应的里程碑（如 `v1.1.0`）上；里程碑页面能看到这一版还剩几项，全部关掉就该发版了。
- 一个 Issue 对应一个分支、一个 PR，PR 描述里写 `Closes #编号`，合并时 Issue 自动关闭。
- `main` 受保护，所有改动（包括错字这类小的文档修正）都在分支上做、开 PR，CI 的两项检查 `offline (ubuntu-latest)`、`offline (windows-latest)`（validate 和离线测试）通过后才能合并。不能直接推送、强制推送或删除 `main`；仓库管理员可以绕过。
- GitHub 不要求审批人数，但合并前请另一人看一下。
- 仓库只允许 squash 合并：一个 PR 在 `main` 上只留一个提交，标题就是 PR 标题。所以 PR 标题用英文祈使句写清做了什么。
- 分支名写平台或人和主题，如 `win/ui-scale`、`mac/stress-marsh`。
- 分支里的提交信息也用英文祈使句，与 `git log` 里已有的一致。
- 生成的结果单独提交，提交信息写明怎么生成的：
  - `tests/compare/results/`
  - `tests/stress/results/`
  - `report/snaps/`
  - `docs/images/`
  - 自测报告里由脚本写入的表
- 两人不要同时重跑同一组结果；要重跑时先在 PR 或 Issue 里说一声。
- 行为有变化时同步更新相关文档，并在 [CHANGELOG.md](CHANGELOG.md) 的“未发布”里加一行，写玩家能感觉到的变化。发版时这一段就是更新说明。

## 测试分工

| 测试 | 谁跑 | 什么时候 |
|------|------|----------|
| `validate.py`、离线测试 | CI 自动 | 每次推送和 PR |
| 游戏内 `run_tests.py` | 改动者，在自己的平台 | 改了 mod 代码 |
| 离线对比 `compare.mjs -p sdp`（开发集） | 改动者 | 改了求解器或合法性规则 |
| 真实点击 `realclick.py` | macOS | 改了界面 |
| 界面缩放、分辨率、布局 | Windows | 改了界面 |
| 压力测试 `stress.py` | 任一平台 | 发布前 |

- PR 里写明在哪个平台跑了哪些测试，没跑的写原因。
- 先跑游戏内测试，再跑离线的重活。`compare.mjs` 多线程运行时，游戏会被拖到几分钟一回合。
- 游戏内测试可以直接跑，不用事先问。改 `AppOptions.txt`、`Mods.sqlite` 前要先问，并且游戏要关着。
- 汇报时分清"已自动验证"和"需人确认"，不要把没验证过的说成通过。

## 发版

`main` 上攒的改动不会直接到玩家手里，玩家只拿到打了 tag 的版本。步骤见发版清单（新建 Issue 时选“发版清单”模板），大致是：

1. 定版本号：修问题改第三位（v1.0.1），加功能改第二位（v1.1.0），大的不兼容改动改第一位。modinfo 的 `version` 每次发版加 1。
2. 发版前测试：三种规则集的游戏内测试、macOS 真实点击、Windows 冒烟测试、后期存档压力测试；改了求解器还要跑离线对比。
3. 准备文字：CHANGELOG 的“未发布”改成 `vX.Y.Z（日期）`；写 `workshop/changenotes/vX.Y.Z.txt`（英文在前、中文在后）；功能或限制变了，同步 README、`workshop/description.bbcode` 和介绍与评测页。这些也走 PR。
4. 在 GitHub 发布 Release `vX.Y.Z`，发布说明写给玩家，英文在前、中文在后。`.github/workflows/release.yml` 会：
   - 打出 `SmartDistrictPlanner-vX.Y.Z.zip`（mod、中英安装与使用说明、`REPORT.html`、`REPORT_EN.html`；不带给测试者的说明），连同中英两个单文件页面一起附到 Release；
   - 打出 `SmartDistrictPlanner-vX.Y.Z-workshop.zip`（创意工坊提交包，`tools/workshop.py pack`）附到 Release；
   - 生成介绍与评测页，发布到 GitHub Pages（中文 <https://smallspider0.github.io/civ6-smart-district-planner/>，英文在 `en/`）。
5. 合作者在 Windows 上用提交包上传创意工坊，见 [docs/workshop-upload.md](docs/workshop-upload.md)。本仓库的工具不连接 Steam。

其他情况：

- **想先给少数人试**：发布时勾选 pre-release，标签如 `v1.1.0-rc.1`。只附压缩包和单文件页面，不更新网页，也不打工坊提交包。
- **线上版本有严重问题，而 `main` 上已有没准备好的改动**：从上一个 tag 拉出 `release/1.0` 分支修好，发 v1.0.1，再把修复合回 `main`。
- **平时给测试者一个包**：本地跑 `python3 -I tools/package.py`，包名是提交号，里面带测试说明 `TEST_GUIDE.md`。
- **并行开发**：几个需求可以在不同分支上同时写，但游戏内测试只有一个游戏、一个 Tuner 连接，只能一个一个跑。

## 写作规则

适用于界面文字、文档、报告和 PR 说明。

- 用中文；代码标识符和注释用英文或中文都可以，但同一个文件里保持一致。例外：README、创意工坊的标题、简介和更新说明，以及 GitHub 发布说明，英文在前、中文在后；问题反馈模板中英并列；英文安装说明 `docs/install-en.md` 和英文介绍页只用英文。README 和安装说明改了中文，英文同步改。
- 写得平实：
  - 不用套话和 AI 腔，比如“赋能”“全面提升”“值得注意的是”；
  - 同一个意思只写一次，不重复已经说过的话。
- 直接描述功能，不加"新功能""新加""新指标"之类的标签。
- 测试项数、耗时这类数字只写在自测报告和“介绍与评测”页里（由脚本生成或刷新），其他文档链接过去，免得过时。
- 截图只截游戏画面，不带系统菜单栏、标题栏、任务栏或 Dock。放在 `docs/images/`，按 `v<版本>-<内容>.jpg` 命名。
- “介绍与评测”页由 `report/build.py` 生成，前 6 节写给玩家，技术内容放在附录。英文页只有前 6 节，改中文页前 6 节时同步改 `report/template_en.html`。用 Claude 做的页面（artifact）沿用这个页面的样式和写法。

## 许可证与第三方内容

代码以 [MIT](LICENSE) 许可发布。

仓库里没有 DMT、AMT、Empire Planner 和游戏本体的代码或数据。`reference/` 和 `tests/compare/.cache/` 只在本机，已 gitignore，不要提交进来。
