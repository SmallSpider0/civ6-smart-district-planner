# 工作流的决定和原因

规则正文（[AGENTS.md](../../AGENTS.md)、[docs/maintaining.md](../maintaining.md)、[.claude/skills/sdp-*](../../.claude/skills/)）只写现在怎么做和一句理由；当时出了什么事、为什么这样定，按日期记在这里。和规则正文不一致时以规则正文为准。新定一条工作流规则时在这里加一行（[maintaining.md](../maintaining.md)“工作流怎么改”）。

| 日期 | 定了什么 | 为什么、出过什么事 | 现在的规则在 |
|---|---|---|---|
| 2026-10-19 | 游戏 Lua 运行时的限制（哪些全局是 nil、计时器只有秒级） | 在主菜单与对局内各状态实测；`tests/test_environment.lua` 持续检查 | AGENTS.md 第 6 节 |
| 2026-10-21 | 界面逻辑的测试经过控件自己的回调 | 勾选框处理函数里一处永远得 nil 的 `a and false or nil` 让城址钉取消勾选无效，测试直接调规划函数没发现 | AGENTS.md 第 3 节“代码约定” |
| 2026-10-26 | 主会话、子会话、子 agent 的分工 | 开发默认交给子 agent，因为任何时候都能派出去，后续的活可以按交接说明交给新的；代价是维护者看不到过程，改方向要经主会话转达 | maintaining.md“谁来做” |
| 2026-10-26 | 一个 Issue 一个 PR | 小 PR 好审、好回退；分支活得短不容易冲突；一项卡住不拖累别的 | maintaining.md“一轮工作的流程” |
| 2026-10-26 | 版本号按改动大小分 | 之前“方案会变”就升第二位，几乎每版都升第二位 | maintaining.md“发版” |
| 2026-10-26 | Issue 评论写给懂游戏、不看代码的人 | 合作者觉得之前的评论难懂 | maintaining.md“只对内的写作规则” |
| 2026-10-27 | 子 agent 的上下文保持短、按任务选模型 | 子 agent 每次调用都重读整个上下文，当天的统计里重读占子 agent 花费的九成以上 | maintaining.md“子 agent 怎么派” |
| 2026-10-27 | 结束一轮前安排好会叫醒自己的等待 | 一次发版的 PR 合并后会话停了五个小时，因为没安排等待 | maintaining.md“子 agent 怎么派” |
| 2026-10-27 | Codex 审查试用两周 | 试用结束看 [codex-review-trial.md](codex-review-trial.md) 的统计决定留不留 | maintaining.md“Codex 审查” |
| 2026-10-28 | 只有维护者或合作者打了 `auto` 标签的 Issue 由代理自动处理 | | maintaining.md“一轮工作的流程”，sdp-watch |
| 2026-10-29 | bug 先自己复现，复现不了才问报告人 | | sdp-issue §2 |
| 2026-10-29 | 悬停提示写给玩家，不写实测数字（#153） | | maintaining.md“只对内的写作规则” |
| 2026-10-30 | 描述里的图片由代理在 Chrome 里上传成 Steam 艺术作品，不用问 | | sdp-release §2 |
| 2026-10-31 | 每次发版都等维护者决定，只修 bug 的也一样 | | maintaining.md“一轮工作的流程”，sdp-release |
| 2026-11-02 | 一批 PR 只挂一个 `pr_wait.py`，不用只看 PR 开没开着的循环 | #207 的 CI 失败了，只看 PR 开没开着的循环一个半小时没发现 | maintaining.md“子 agent 怎么派”，tools/README.md“pr_wait.py” |
| 2026-11-02 | 不用 `git stash` | stash 是同一仓库所有工作树共用的，两个会话同时 stash、pop，取到了对方的改动 | maintaining.md“共用资源” |
| 2026-11-03 | 客观的问题代理自己定，主观的等人 | | maintaining.md“一轮工作的流程”，sdp-issue §2 |
| 2026-11-03 | 创意工坊评论只记进待看列表，维护者说了才处理；只回复问题已经解决的，回复先给维护者确认（#229） | 维护者选了方案 B；“评论别直接回待我确认” | sdp-watch“Steam Workshop comments” |
| 2026-11-03 | 主会话只分派、上下文小、随时可清空；常驻的等待放在值守子会话上 | 10-19 到 11-02 主会话的重读是子 agent 的两倍多，约四分之一来自后台命令和子 agent 叫醒它；压缩后也要从约 15 万 token 重新开始，大半是工具定义、CLAUDE.md、记忆这些固定的部分。会话里有在跑的后台命令、子 agent 或没到点的会话定时任务时清空不了（桌面版的定时任务不挡，当天实测） | maintaining.md“子 agent 怎么派”第 5 条 |
| 2026-11-03 | 更新记录写成 `changelog.d/` 的片段（#217） | 之前每个 PR 都往 CHANGELOG 的同一处末尾加行，冲突逼出了大量变基 | CONTRIBUTING.md“提交 PR”，maintaining.md“PR 与 CI 的内部细则” |
| 2026-11-03 | 每次发版按 CHANGELOG 的每一条查对外文档 | v1.7.0 取消多城上限后，旧的数字留在了没人列出的地方 | sdp-release §1 第 5 步 |
| 2026-11-03 | 清理记忆和规则文档：每个第二位版本之后，或最多隔 3 个第三位版本 | 不发版时项目不在动，所以只按版本号算 | sdp-release §2 第 6 步，[rules-cleanup.md](rules-cleanup.md) |
| 2026-11-03 | 工作流改动先开 `workflow` Issue，发版时一起定 | 之前每出一次流程问题当天就加一条规则或一个工具，规则只增不减、互相对不上 | maintaining.md“工作流怎么改” |
| 2026-11-03 | 每条规则只留一处（#252） | 同一条规则写在好几处，改一条要改好几处；开工要读的三份文档约 8 万字节，步骤在 skill 里又写一遍，规则里夹着事故经过 | AGENTS.md 第 8 节“规则在哪” |
| 2026-11-03 | Chrome 连不上时先自己打开、重试 3 次，才报告；用完退出 Chrome | | sdp-release §2 第 4 步 |
| 2026-11-03 | 等夜间游戏内测试的 PR 进同一批的 `pr_wait.py`（`--night`），测过后由跑测试的人开自动合并（#255） | #254 要等夜间测试又要 Codex 审：`--codex` 审完没意见就开自动合并，太早；不带它又因为“没开自动合并”马上退出，只好另挂一个 `codex_review.py wait`，同一批分成两个等待 | sdp-issue §4，sdp-game-test“When”，maintaining.md“PR 与 CI 的内部细则” |
| 2026-11-03 | 监听在后台直接跑、不重定向输出；退出了却没有输出时先看 `--reported`，不当成无新事（#261） | 值守会话把监听的输出重定向进文件，退出后后台任务的输出是空的，就当成无新事重启了；那一条已记成看过、不会再报，DracoYus 在 #227 的回复漏了 | sdp-watch“Run” |
| 2026-11-03 | 值守子会话常开防锁屏（`caffeinate -di`），别的会话不另开、不结束它 | 夜间队列曾因屏保锁屏停下；一次游戏测试收尾时停掉了所有 caffeinate（维护者要求） | maintaining.md §4 第 5 条 |
| 2026-11-04 | 交 PR 用 `pr_wait.py add` 放进等待名单、不发消息；值守常驻 `pr_wait.py --list`，只在要主会话动手时结束一轮报告；子 agent 一段等待只放一次后台；等 Codex 只用 `pr_wait.py`（先不合并的加 `--hold`），不单独挂 `codex_review.py wait`（#275） | #274 合并的报告被压住约 6 小时：连续的自动叫醒有上限。11-03 全天主会话约 103 次自动叫醒，约四成不用动手（值守回“已挂上”“已改挂” 27 次，子 agent 放后台等待时的中途提示 13 次，单独的 Codex 等待报“没意见” 3 次，监听“没有新事”之类约 3 次）；那一夜连续约 18 次后，第 19 次（#274 合并）被压住 | maintaining.md §4 第 2、5 条，sdp-watch“Who runs it”，sdp-issue §4，sdp-offline-runs，tools/README.md“pr_wait.py” |
| 2026-11-05 | 发版时的开发集复核在上次核对之后求解相关文件没变时由工具跳过（`refresh_results.py --check --if-changed`）；真实点击每类控件只点一下；要多城存档的游戏内测试在压力测试读入 pangaea-gs 时跑；`test_solver_perf3/4/8` 并成一个文件，每项单独计时（`@max_seconds_each`）；共用的 `durations.json` 自动去掉已不存在的文件（#302） | v1.7.3 发版时复核 268 行约 85 分钟，而改求解器的 PR 合并前已经跑过；真实点击 71 下里约 22 下是格子状态循环，控件回调的测试已覆盖；三个要多城存档的测试文件在全套测试的新对局里一直跳过，等于没测 | sdp-release §1，sdp-game-test“Tests”，tools/README.md“refresh_results.py”“realclick.py”“stress.py”“run_tests.py” |
