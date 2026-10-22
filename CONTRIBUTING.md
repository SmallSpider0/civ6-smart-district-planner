# 参与开发

仓库：<https://github.com/SmallSpider0/civ6-smart-district-planner>。开发在 macOS 和 Windows 两台机器上进行，双方都用 Claude Code。仓库根目录的 `CLAUDE.md` 让 Claude Code 自动读入 [AGENTS.md](AGENTS.md) 和本文，所以这两份既写给人，也写给代理。

## 先读

- [AGENTS.md](AGENTS.md)：需求约束、技术方案、36 条坑、每轮改动流程。
- 当前平台的环境说明：[docs/dev-macos.md](docs/dev-macos.md) 或 [docs/dev-windows.md](docs/dev-windows.md)。
- [tools/README.md](tools/README.md)：每个工具的用法。

## 分支与提交

- `main` 上的每个提交都要能通过 validate 和离线测试，CI 在 Ubuntu 和 Windows 上检查。
- 改动在分支上做，开 PR，另一人看过再合并。错字这类小的文档修正可以直接提交到 `main`。
- 分支名写平台或人和主题，如 `win/ui-scale`、`mac/stress-marsh`。
- 提交信息用英文，第一行用祈使句说做了什么，与 `git log` 里已有的一致。一个提交只做一件事。
- 生成的结果单独提交，提交信息写明怎么生成的：
  - `tests/compare/results/`
  - `tests/stress/results/`
  - `report/snaps/`
  - `docs/images/`
  - 自测报告里由脚本写入的表
- 两人不要同时重跑同一组结果；要重跑时先在 PR 或 Issue 里说一声。
- 行为有变化时同步更新相关文档和 [CHANGELOG.md](CHANGELOG.md)。

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

## 发布

- 测试包：`python3 -I tools/package.py`。它从最近一次提交打出 `dist/SmartDistrictPlanner-<提交号>.zip`，里面有 mod、测试说明、安装说明和 `REPORT.html`。
- 测试包发到 GitHub Releases，标签用提交号或版本号。
- 发布前跑一遍压力测试，结果写进自测报告和交付报告。

## 写作规则

适用于界面文字、文档、报告和 PR 说明。

- 用中文；代码标识符和注释用英文或中文都可以，但同一个文件里保持一致。
- 写得平实：
  - 不用套话和 AI 腔，比如“赋能”“全面提升”“值得注意的是”；
  - 同一个意思只写一次，不重复已经说过的话。
- 直接描述功能，不加"新功能""新加""新指标"之类的标签。
- 测试项数、耗时这类数字只写在自测报告和交付报告里（由脚本生成或刷新），其他文档链接过去，免得过时。
- 截图只截游戏画面，不带系统菜单栏、标题栏、任务栏或 Dock。放在 `docs/images/`，按 `v<版本>-<内容>.jpg` 命名。
- 交付报告由 `report/build.py` 生成。用 Claude 做的页面（artifact）沿用交付报告的样式和写法。

## 许可证与第三方内容

代码以 [MIT](LICENSE) 许可发布。

仓库里没有 DMT、AMT、Empire Planner 和游戏本体的代码或数据。`reference/` 和 `tests/compare/.cache/` 只在本机，已 gitignore，不要提交进来。
