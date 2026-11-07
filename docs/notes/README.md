# docs/notes 索引

每个文件一行：主题，以及后来的改动有没有取代它。笔记是当时的记录，不随代码更新；多城加奇观现在的规则见 [multicity-design.md](../multicity-design.md) 4.8，与笔记不一致时以代码为准。新建笔记时在这里加一行；后来的改动推翻了某篇笔记的做法时，改这一篇的“状态”。

状态的写法：

- **现行**：做法仍是这样（细节可能被后来的小改动调整过）。
- **部分已取代**：写明哪一部分、被哪个 Issue 改了。
- **调研**、**实验**：调研或离线实验的记录，结论已写进 Issue 或别的笔记，本身不描述代码。

## 原设计文档第 15–30 节

| 文件 | 主题 | 状态 |
|---|---|---|
| [15-stage8.md](15-stage8.md) | 阶段 8：单城求解改写（`SDP_Search`、`SDP_Board`），算法迭代和离线基准 | 现行（算法在 design 4.5–4.6；基准数字是当时的） |
| [16-stages9-12.md](16-stages9-12.md) | 阶段 9–12：城址、多城、档位、分帧的模块，与设计的出入，多城基准 | 部分已取代：默认参与的城改为跟随选中的城、默认 4 座（#63），参与城数不设上限（#142） |
| [17-ingame-calibration.md](17-ingame-calibration.md) | 游戏内验证、发现的问题、耗时校准 | 现行（耗时数字是当时的） |
| [18-other-planners.md](18-other-planners.md) | AMT、Empire Planner 有而本模组没有的功能（2026-10-20 评估） | 调研 |
| [19-coverage.md](19-coverage.md) | 覆盖范围：规则、目标、搜索、界面，单城页（#61） | 现行 |
| [20-first-feedback.md](20-first-feedback.md) | 第一轮实测反馈：区域的必建 / 候选 / 不建、距离成本、自动加入、提醒钉、界面 | 现行（细节后来多有调整，以代码为准） |
| [21-wide-beam.md](21-wide-beam.md) | 多城标准档的宽束联合起点 | 现行 |
| [22-second-feedback.md](22-second-feedback.md) | 第二轮反馈：点击问题、港口与商业中心分城、社区与保护区、真实点击、压力测试 | 部分已取代：分城改为按城挑（#106），面板上的分城开关去掉（#152） |
| [23-third-feedback.md](23-third-feedback.md) | 第三轮反馈：城址一环、帝国限建区域（#28）、奇观顺序 | 部分已取代：限建区域按城市列表顺序分改为按离中心城的距离试几座、留最好的（#234，design 4.8.1） |
| [24-fourth-feedback.md](24-fourth-feedback.md) | 第四轮反馈：领土连通、预览显示、预览图（v1.1.2） | 现行 |
| [25-baseline-real-games.md](25-baseline-real-games.md) | 评测基线：真实对局的场景与引擎审计（#37、#42） | 现行 |
| [26-v120-lowlands-wonders.md](26-v120-lowlands-wonders.md) | 淹没的沿海低地；奇观只认同城的区域（#44、#45） | 现行；#238 起奇观也记给建它的城（design 4.8.4） |
| [27-fifth-feedback-land.md](27-fifth-feedback-land.md) | 第五轮反馈：地块价值、换格、住房（#52、#54、#55、#56） | 部分已取代：换格开关默认打开、同分不换格（#162）；提示不再写实测数字（#153） |
| [28-issue-51-wonder-improvements.md](28-issue-51-wonder-improvements.md) | 奇观要挨着的改良设施（阿耳忒弥斯神庙的营地） | 现行 |
| [29-issue-63-several-cities.md](29-issue-63-several-cities.md) | 多城页参与的城：跟随选中的城、默认 4 座、格子列表 | 部分已取代：最多 8 座改为不设上限（#142）；提示不再写耗时数字（#153） |
| [30-issue-65-slow-frames.md](30-issue-65-slow-frames.md) | 游戏帧慢时分帧计算不再停住 | 现行 |

## Issue 记录（按编号）

| 文件 | 主题 | 状态 |
|---|---|---|
| [issue-40-multi-city-bounds.md](issue-40-multi-city-bounds.md) | 多城的长跑参照与上界 | 实验 |
| [issue-48-land-oracle.md](issue-48-land-oracle.md) | 计入地块时的真最优与潜力产出 | 实验 |
| [issue-48-true-optimum-sets.md](issue-48-true-optimum-sets.md) | 真最优测试集：大城、候选挑选、奇观，更紧的界 | 实验 |
| [issue-49-presets.md](issue-49-presets.md) | 玩法预设 | 部分已取代：改过预设后显示“自定义”，不再是“（已改）”（#89） |
| [issue-53-plot-weights.md](issue-53-plot-weights.md) | 地块产出按固定倍数计（v1.5.0） | 现行 |
| [issue-53-reference-layouts.md](issue-53-reference-layouts.md) | 用参照布局反推权重与地块系数 | 实验 |
| [issue-53-weight-robustness.md](issue-53-weight-robustness.md) | 默认权重的稳健性 | 实验 |
| [issue-57-remember-settings.md](issue-57-remember-settings.md) | 按存档记住设置 | 现行 |
| [issue-66-wonder-districts.md](issue-66-wonder-districts.md) | 需要相邻区域的奇观带上区域 | 部分已取代：补的区域奇观必须挨着（#180），别的城挑了同种区域时换城再算（#182），奇观定了城时只补给那座城（#234）；现在的规则见 design 4.8.3 |
| [issue-67-ui.md](issue-67-ui.md) | v1.4.1 的界面小改动 | 部分已取代：档位提示不再写实测数字（#153） |
| [issue-71-fit-fold-peek.md](issue-71-fit-fold-peek.md) | 窗口按屏幕高度、设置区折叠、看地图、方案一行、区域数量默认 3 | 现行 |
| [issue-75-site-preview.md](issue-75-site-preview.md) | 选城址：一套方案里逐个看各城址 | 现行 |
| [issue-76-open-tab.md](issue-76-open-tab.md) | 选中另一座城时打开规划器切到单城页 | 现行 |
| [issue-84-site-distance.md](issue-84-site-distance.md) | 选城址“最远距离”默认值（改为 5） | 调研（结论已实现） |
| [issue-87-dense.md](issue-87-dense.md) | 选城址的密铺 | 部分已取代：密铺不再单独记新城数量、默认 12，改为和平时共用一个数（#191）；城数一样先比挤不挤、挪位不许变松（#297） |
| [issue-88-sites-score.md](issue-88-sites-score.md) | 选城址计分：各项折成每回合点数 | 现行 |
| [issue-89-custom-preset.md](issue-89-custom-preset.md) | 改过预设后显示“自定义” | 调研（结论已实现） |
| [issue-90-sites-districts.md](issue-90-sites-districts.md) | 选城址页的区域：必建 / 候选 / 不建和区域数量 | 现行 |
| [issue-91-housing-value.md](issue-91-housing-value.md) | 1 点住房值几分 | 调研（结论已实现） |
| [issue-91-objective.md](issue-91-objective.md) | 三个页签的目标公式与权重（按 v1.5.0 的代码写） | 调研；之后 #91 的 PR（#114、#122）按它改了几处 |
| [issue-106-harbor-commercial-hub.md](issue-106-harbor-commercial-hub.md) | 港口与商业中心：玩家怎么选 | 调研（决定见 issue-106-harbor-choice.md） |
| [issue-106-harbor-choice.md](issue-106-harbor-choice.md) | 港口还是商业中心：按城市挑 | 部分已取代：分城开关去掉（#152），按城挑的规则仍是现行 |
| [issue-107-base-game-apart.md](issue-107-base-game-apart.md) | 原版规则集里的港口、商业中心分城 | 现行（面板开关后来由 #152 去掉） |
| [issue-126-district-parts.md](issue-126-district-parts.md) | 每个区域的分项、每座城的小计、按产出的相邻加成 | 现行 |
| [issue-133-sites-nosite.md](issue-133-sites-nosite.md) | 选城址页区域数量 3 时找不到城址 | 现行 |
| [issue-142-all-cities.md](issue-142-all-cities.md) | 多城页规划全部城市（分组） | 现行 |
| [issue-152-no-apart-switch.md](issue-152-no-apart-switch.md) | 去掉“港口、商业中心分城”开关 | 现行 |
| [issue-153-tooltips.md](issue-153-tooltips.md) | 面板悬停提示改写 | 现行 |
| [issue-154-wonder-replace.md](issue-154-wonder-replace.md) | 开着“替换本模组之前的钉”时奇观被漏掉 | 现行 |
| [issue-162-swap-default.md](issue-162-swap-default.md) | “从本方其他城换格”默认打开，同分不换格 | 现行 |
| [issue-165-tacked-list.md](issue-165-tacked-list.md) | 已有的区域不再当候选 | 部分已取代：清单状态的函数由 #244 合成 `SDP_City.ListStatus` |
| [issue-166-wonder-memory.md](issue-166-wonder-memory.md) | 多城页的奇观设置记不住 | 现行 |
| [issue-177-count-exceeded.md](issue-177-count-exceeded.md) | 多城页“每城数量”被超出：复现记录 | 现行 |
| [issue-178-reselect-city.md](issue-178-reselect-city.md) | 重新选中同一座城再打开面板不跟随 | 现行 |
| [issue-180-wonder-district-next-to-wonder.md](issue-180-wonder-district-next-to-wonder.md) | 为奇观补的区域要挨着奇观 | 现行（design 4.8.3） |
| [issue-182-wonder-district-elsewhere.md](issue-182-wonder-district-elsewhere.md) | 别的城挑了同种区域时补的区域换城再算 | 部分已取代：定了城的奇观（#234，默认按生产力选城）不再换城，只在奇观没定城时做（design 4.8.3） |
| [issue-186-site-order.md](issue-186-site-order.md) | 选城址页的城址顺序 | 现行 |
| [issue-187-shared-list.md](issue-187-shared-list.md) | 多城页：自定清单改回共用清单 | 现行 |
| [issue-188-site-housing.md](issue-188-site-housing.md) | 选城址悬停里的“住房 11” | 现行 |
| [issue-189-plan-order.md](issue-189-plan-order.md) | 多城方案的顺序 | 现行 |
| [issue-191-site-count.md](issue-191-site-count.md) | 密铺时新城数量不变 | 现行 |
| [issue-197-regional-range.md](issue-197-regional-range.md) | 城邦宗主加成让覆盖范围变大 | 现行 |
| [issue-198-clean-runs.md](issue-198-clean-runs.md) | 第二台机器上的实验目录自动清理 | 现行 |
| [issue-199-solve-on-screen.md](issue-199-solve-on-screen.md) | 勾了奇观后“求解”按钮落到屏幕下面 | 现行 |
| [issue-226-dense-sites-stall.md](issue-226-dense-sites-stall.md) | 选城址页打开密铺后进度停在 24% | 现行 |
| [issue-227-improvement-tacks.md](issue-227-improvement-tacks.md) | 规划区域时一起规划给区域相邻加成、产出的改良设施，可选给耕作的格打改良钉 | 现行 |
| [issue-234-unique-city.md](issue-234-unique-city.md) | 全帝国限建区域、奇观放哪座城（按生产力自动选城） | 现行（design 4.8.1、4.8.2） |
| [issue-242-invariants.md](issue-242-invariants.md) | 每次离线求解后检查方案不变量 | 现行（design 4.8.5） |
| [issue-244-one-entry.md](issue-244-one-entry.md) | 区域状态、奇观归城各只留一个入口；合并复制的小函数 | 现行（design 4.8.4，design.md 城市扫描） |
| [issue-250-one-city-as-multi.md](issue-250-one-city-as-multi.md) | 单城页按“只有一座城的多城请求”求解 | 实验（待维护者定） |
| [issue-277-hebutong.md](issue-277-hebutong.md) | 与“和而不同”的兼容性：读源码、离线和游戏内实测；“覆盖”不计它的范围效果（DracoYus 定：不适配，安装说明和创意工坊简介各写一句） | 现行 |
| [issue-297-sites.md](issue-297-sites.md) | 选城址的实际步骤、共用地格和住房怎么算；住房只算水源、建筑折半的离线实验，海边城址的分项 | 已定：保持按科技解锁计港口住房（#188 的做法），计分不改 |
| [issue-297-dense-spread.md](issue-297-dense-spread.md) | 密铺：城数一样时先比挤不挤（最小生成树的连线长度），挪位不许变松 | 现行 |
| [mod-compat-research.md](mod-compat-research.md) | 和热门模组的兼容（#295）：热门榜、别的模组怎么做兼容、对本模组的影响、武则天 +2 为什么没算、玩家需求 | 已定：只修本模组自己的问题（#293、#294）、写清局限（#296）；不做别的模组的适配，第 4 环也不做（#298、#299） |
| [release-1.7.2.md](release-1.7.2.md) | v1.7.2 发版准备的交接：测试结果、夜间队列、对外文档逐条核对 | 现行（发版后不再更新） |
| [issue-294-wonder-built.md](issue-294-wonder-built.md) | 奇观“已建成”按全世界数量上限和本方城市判断，不看地图上见没见过 | 现行 |
| [issue-307-wonders-hang.md](issue-307-wonders-hang.md) | 勾很多奇观时求解卡死：数摆法先做匹配、回溯有上限并分帧，自动奇观最多再整体求解 2 次；改前改后的帧和总时长 | 现行 |
| [issue-245-split-session.md](issue-245-split-session.md) | `SDP_Multi.NewSession` 拆成有名字的步骤（纯重构） | 现行 |
| [issue-327-test-infra.md](issue-327-test-infra.md) | 测试基础设施：面板放回默认（每个游戏内测试文件和截图前）、页面装不下写日志并让测试失败、最矮窗口选项；离线的一帧工作量看门狗（上限的来由、最大规模用例的最长一帧）；面板设置和求解输入的对账表、三个页签的“继续优化”逐帧走完；开发集加面板默认设置一档（`PANEL`） | 现行 |
| [issue-329-weekly-game-tests.md](issue-329-weekly-game-tests.md) | 每周一个规则集的整套游戏内测试：夜间队列里自己续排的一项，排哪一夜、规则集怎么轮、失败谁处理 | 现行 |
| [issue-331-frame-report.md](issue-331-frame-report.md) | 多城页全部奇观、全部区域必建时有几帧偏长：领土可达检查和集束搜索按实际循环步数向分帧报工作量；离线最长一帧和游戏内逐帧计时 | 现行 |

## 持续更新的记录

| 文件 | 主题 | 状态 |
|---|---|---|
| [codex-review-trial.md](codex-review-trial.md) | Codex 审查试用：每个请审的 PR 一行（`codex_review.py log --table` 写入） | 持续更新 |
| [planner-comparison.md](planner-comparison.md) | 与其他规划模组的离线对比结果 | 持续更新 |
| [rules-cleanup.md](rules-cleanup.md) | 记忆和规则文档的清理记录 | 持续更新 |
| [workflow-decisions.md](workflow-decisions.md) | 工作流的决定和原因：按日期，规则正文只留一句理由（#252） | 持续更新 |
