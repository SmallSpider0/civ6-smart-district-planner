# v1.7.2 发版准备（交接）

2026-11-04 维护者说“准备 v1.7.2”。这是准备，发不发等维护者说（docs/maintaining.md §2 第 6 步）。范围：里程碑“稳固”（23，11 个 Issue 都已关闭）和 v1.7.1 以来 `main` 上的全部改动。

- 分支 `mac/release-1.7.2`，工作树 `~/civ6mod-release-1.7.2`，基于 `main` 的 92d022a（#282）。
- 做到 sdp-release §1 第 6 步；第 7 步（开 PR）和 §2 没做。

## v1.7.1 以来进了什么

| PR | 内容 | 玩家看得到吗 |
|---|---|---|
| #266（#250） | 单城页两种求解的结果合成一条路：候选不够一行、每个方案自己的没放下、勾奇观时方案提示列出挑了哪些、自动加入的区域放不下写明 | 是（changelog.d/250.md 三条） |
| #274（#244） | 区域状态（已建、不能同城、帝国上限、已打钉）和奇观归城各只留一个入口；多城页别的城打了钉的限建区域置灰 | 是（changelog.d/244.md 一条） |
| （#277） | 与“和而不同”的兼容性：不改代码；安装说明中英“已知限制”、创意工坊简介中英“常见问题”各加一句，`changelog.d/277.md` 一行（DracoYus 在带 `auto` 的 #277 回复“都遵循建议”，评论 6619755259）。**发版 PR 正文写 `Closes #277`** | 是（文档和更新说明） |
| #282 | `SDP_Multi.NewSession` 拆成几个有名字的步骤 | 否（只重构，离线测试和 refresh 检查覆盖） |
| #270 #271 #272 #273 #276 #279 | 工具和工作流（worktree 同步、值守日志、pr_wait 夜间、状态页） | 否 |

## 测试结果（白天跑的，不开游戏）

（下面在离线结果出来后填写）

## 夜间队列

工作日白天不开游戏，下面四项按顺序排进夜间队列，都在分支 `mac/release-1.7.2`、工作树 `~/civ6mod-release-1.7.2` 跑：

| 编号 | 内容 | 要验证什么 |
|---|---|---|
| #45 | `deploy.py` 后 `run_tests.py --rulesets all` | 三种规则集 0 失败；跳过的按跳过报 |
| #46 | 风云变幻英文界面：`game.py quit` → `shots.py lang en` → launch → newgame → `run_tests.py` → quit → `shots.py lang restore` | 0 失败；restore 打印 identical |
| #47 | `realclick.py suite`（游戏要先开着、新对局） | 全部通过（上一轮 71 项） |
| #48 | 三张存档压力测试 load/run/check，`refresh_stress_md.py` | 失败、不一致、引擎不允许的格都为 0；提升和放下的区域数和 v1.7.1 那轮相同，变了要解释（求解器看到的东西 #244、#250、#282 都说没变，所以预期相同） |

## 截图：不拍

#250 改的只在少见的情形出现（候选不够、几个方案时后面的方案没放下的、勾奇观时方案按钮的悬停），#244 改的是多城页别的城已打钉时限建区域的格子；截图的四个场景（`tests/shots/single.lua` 等：学院必建、3 个区域、标准档，不勾奇观）里一样都不出现，布局和文本键也没改（`git diff v1.7.1..HEAD -- SmartDistrictPlanner/Text SmartDistrictPlanner/UI/*.xml` 为空）。所以沿用第 17 轮截图，文档里的图片不用换，`workshop.py render` 也不用跑。真实点击（#47）检查这些控件。

## 压力测试：要跑

`git diff v1.7.1..HEAD -- SmartDistrictPlanner/Scripts` 改了 `SDP_City.lua`、`SDP_Multi.lua`、`SDP_Rules.lua`、`SDP_Search.lua`、`SDP_Solver.lua`（不只是 `SDP_Page*.lua`、`SDP_Preview.lua`），按 sdp-release §1 第 2 步要跑（#48）。

## 夜里测完后还要补的

1. `docs/self-test-report.md` 第二十九轮表里“待夜间队列”的几行：游戏内（三种规则集、英文）、真实点击、压力测试（`refresh_stress_md.py` 会改下面的压力测试表；把表上方那句“最长一步”的话也对一下）。
2. 介绍页的测试项数：`report/template.html` 第 715 行、`template_en.html` 第 723 行的游戏内项数（现在 136）、第 720/728 行的真实点击项数（现在 71），按夜里的结果改。离线项数已经改了（见上）。
3. 截图不拍，`workshop.py render` 不用跑。
4. 然后 sdp-release §1 第 7 步：提交、推送、开 PR（标题如 “Prepare v1.7.2”，正文写 `Closes #277`，用下面的核对清单），等维护者说“发”。

## 对外文档逐条核对（PR 描述用）

搜过的文件：README.md（中英）、docs/install-and-test.md、docs/install-en.md、docs/tester-guide.md、workshop/description.bbcode、description_zh.bbcode、workshop/src/*.html、report/template.html、template_en.html、report/part_*.html、report/build.py、report/similar.py、docs/notes/planner-comparison.md、SmartDistrictPlanner/Text/*.xml。

- **#244 多城页：别的城已经给市政广场这类限建区域打了钉时，格子置灰、不能再勾**（搜了“置灰”“变灰”“灰色”“grey”“gray”“全帝国”“帝国上限”“empire limit”“one per empire”）：`docs/install-and-test.md`、`docs/install-en.md` 多城第 2 步只写了“任何一座城已经建了”时变灰，各加一句“别的城已经给它打了钉时（要被替换的本模组旧钉除外）也变灰、写‘已达帝国上限’”。README、创意工坊简介（“放到最合适的那座城”）、介绍页（“全帝国限量的区域……写进几座城就在其中自动选”“empire limits (counting placed tacks)”）、part_algo 仍然对，不改。
- **#244 单城页：勾了“替换本模组之前打的钉”时，要被替换的钉不再让格子置灰**（搜了“替换本模组”“替换旧钉”“旧钉”“Replace this mod”“earlier tacks”）：安装说明中英第 2、7 步本来就写“要重新规划本模组打过的钉，勾上替换……”“规划时当作不存在”，现在说的就是新行为；README、创意工坊简介、介绍页同样。不改。
- **#250 单城页“候选不够”一行**（搜了“候选不够”“少挑”“Pool short”“POOL”“fewer picked”）：介绍页“没放下的区域及原因：……候选不够”、创意工坊简介 FAQ“或候选不够 / not enough districts in the Pool”本来就这样写（以前勾奇观时不对，现在对了）。不改。
- **#250 每个方案列出自己没放下的区域**（搜了“没放下”“放不下”“unplaced”“not placed”“could not place”“fits nowhere”）：文档只写“放不下的区域会列出原因”，没说按第一个方案列。不改。
- **#250 勾奇观时方案按钮悬停列出挑了哪些；自动加入的区域放不下写明**（搜了“N 个区域”“方案按钮”“plan button”“悬停看各项和挑出的区域”“自动加入”“added by itself”“The added”）：安装说明中英第 9 步本来就写“悬停看各项和挑出的区域 / hover one for its items and the districts it picked”，介绍页英文 “each saying which it picked” 同，README 没写悬停；自动加入的标注已写。不改。
- **#277 已实测可和“和而不同”同开；“覆盖”不计它新加的范围效果**（新加的一条，不是改旧说法）：`docs/install-and-test.md`、`docs/install-en.md` 的“已知限制 / Known limitations”各加一条；`workshop/description.bbcode`、`description_zh.bbcode` 的“常见问题 / Questions”各加一问（物品页等维护者说发版时更新）。名称用它创意工坊页的写法 “Civ6 Plus: Harmony in Diversity”、中文“和而不同”；“覆盖”的英文用面板的 “Reach”。介绍页的已知限制、同类模组表（它不是规划器）没加。`docs/notes/issue-277-hebutong.md` 从主检出复制进来一起提交，索引加了一行。
  - `changelog.d/277.md` 是在 `release.py prep` 之前加的：先撤回第一次 prep，加上 277.md 再跑一次 prep，所以它已收进 CHANGELOG 的 v1.7.2 一节、文件随之删掉（未跟踪过，git 里看不到删除）。
- 面板悬停提示文本（`SmartDistrictPlanner/Text/*.xml`）：这一版没有改文本键，也没有哪条提示写着改了的数值。不改。
- 同类模组表（`report/similar.py`）、`planner-comparison.md`：这一版不涉及规划对象、规则集、语言、限制。不改。
