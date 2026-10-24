# 更新记录

只列要点，细节在链接的设计文档章节里。括号里是这一段的提交。

## 未发布

仓库与流程：

- 手写参照布局：`tools/refscene.py` 把社区公认的布局（文本写的六边形地图、河流、城市和布局里的区域）转成离线对比的场景（`REF` 组，没有默认运行），`check` 画回文字或 SVG 图与原图对照；`compare.mjs --refscore` 对每组权重给参照布局和最优解（只算相邻时是 `sdp:ORACLE` 的真最优）打分。第一个场景是苏秦的两城水渠工业区加堤坝，参照布局正是最优（#53）。
- 离线对比的裁判另报潜力产出 `outputP`：地块按修上改良后的产出算（裁判自己从规则表推导，含文明特色改良和需河流的改良），人口取建齐请求的区域所需的，一次性产出单独记为 `oneTime`；`probe_land.lua` 核对裁判调成本模组的口径时与本模组逐格相同。`summarize.py` 报计入地块与只算相邻在 `outputP` 上的比较（#48）。
- 本模组的离线变体可加地块系数 λ（`STANDARD_LAND050` 等，只在离线对比里注入，模组不变）（#53）。
- 计入地块时的真最优 `sdp:ORACLE_LAND`：对本模组的整个目标（相邻 + λ × 地块 + 住房）做分支定界，地块部分逐个区域扣精确的边际损失，住房加常数余量；`summarize.py` 报各档占它的比例；先在开发集的 11 个单城场景上试算，结果入库（#48，multicity-design.md 第 28 节）。
- 默认权重的稳健性检查：`compare.mjs` 的普通运行和 `--rejudge` 也接受 `--weights`（每组权重各跑一遍）；`tests/compare/weights/w53.jsonl` 列出候选权重组（全 1、金币减半、信仰减半、科文加减、AMT、Empire Planner 的权重和三组 ×3 的权重）；`tests/compare/robust53.py` 用 144 个单城场景上每组权重的真最优，算“按 A 规划、实际按 B 评”的损失，结果入库（#53，multicity-design.md 第 29 节）。
- `compare.mjs --refscore` 计入地块时改用本模组整个目标的真最优 `sdp:ORACLE_LAND<nnn>`（权重组里 `"lambda"` 设地块系数），参照布局由同一个搜索按同一个目标估值；`tests/compare/refgrid53.py` 汇总参照布局在“权重 × λ”网格上的差距，按作者分开发组和复核组套用先定好的选择规则。17 个存档参照场景、3 组权重 × 5 个 λ 的结果入库：按规则选出的全 1、λ = 0.5 在复核组上不如现行默认，默认不改；金币、信仰减半在每个 λ 上都离参照布局更远（#53，multicity-design.md 第 30 节）。
- 真最优 `sdp:ORACLE`（以及 `ORACLE_LAND`）的界补上漏掉的一项：节点给子节点估界时没算正在放的区域与后面区域的配对，少数场景会剪掉更好的布局（开发集 12 组权重 864 次里 1 次）；权重是 1/k 的整数倍时界取整到 1/k，小数权重和整数权重一样快。此前入库的真最优结果要重算或复核（#53）。

## v1.3.0（2026-10-24）

- 计入占地时，地块按修上最好的改良后的产出算（丘陵按矿山、平地按农场等，从规则表读），砍伐、收获按先收再建计，不再算作区域的损失。盖丘陵的代价变大，盖树林、沼泽变小。结果行提示先砍伐或收获，以及收获资源需要的科技（#52）。
- 单城、多城页加开关“从本方其他城换格”（默认关闭）：能在“市民管理”里用“切换”改归本城的格也用来放区域，结果写“需从某城换格”，耕作损失记在原来那座城。真实后期存档上（标准档，只算相邻）单城相邻加成平均高 13%、多城高 20%，代价是约三成区域要手动切换、多城求解约慢一倍。单城页签里离另一座城更近的无主格，耕作分归那座城（#54）。
- 住房按城市的缺口计：到建齐计划区域所需人口为止每点算 1，之后每多一点减半（#55）。
- 选城址页加“住房”权重，水源的住房不再按食物权重计；计划里有港口时，灯塔、海港的住房计入城址（#55、#56）。
- 日本这类“每挨一个区域加成更多”的文明特性计入求解器的估计：快速档在日本场景上更常找到最好的摆法（#36）。
- 结果行的说明太长时换行，英文界面里“clear or harvest the tile first”这类说明不再超出面板。
- “介绍与评测”页的英文版加上附录 A、B（技术说明、评估方法与完整数据），图和图表都是英文；附录 B 的局限按“已核对 / 规划中 / 暂不做”重写。

仓库与流程：

- 精确参照求解器 `sdp:ORACLE`（分支定界，打分用裁判的 DMT）：开发集、留出集 144 个单城场景和 16 个小多城场景有了证明过的真最优；另加封存集、随机权重组、与 District & Wonder Planner 在三区域场景上的对比；`summarize.py` 报各规划器占真最优的比例（#36、#48）。
- 存档里本模组的对比结果全部用这一版重跑、重新评分；`compare.mjs --rejudge` 不再丢掉“没给出方案”的运行（它们按 0% 计）。
- 发版的版本号按“方案会不会变”分第二位、第三位，一版攒几项改动再发（CONTRIBUTING）；功能类 Issue 先调研、确认后再开发。

- 离线对比的裁判按游戏的换格条件认可换来的格，记下换了几格（#54）。
- 两种区域相邻时的配对值用 DMT 实测（取几处无地貌相邻格的最小值，不低于查表值），估计上界在开发集上不再被突破（原来日本 6 次）；离线假世界加了类似日本的特性和对应测试（#36）。

## v1.2.0（2026-10-23）

修正：

- 风云变幻：被海平面淹没的沿海低地不再作为区域的候选格，游戏不允许在那里放区域。城市修了防洪堤后这些格恢复可用（#44）。
- 需相邻某区域的奇观（大剧院、百老汇、大竞技场、鲁尔山谷等）只放在本城的那种区域旁边：游戏不认别的城市的区域（#45）。

其他：

- 创意工坊换了一组图：每张讲一件事，第一张是多城一起规划（同样三座城，逐城 +19，一起 +29）。

仓库与流程：

- 离线对比的裁判检查上面两条（`flooded`、`wonder_other_city`）；场景导出带上沿海低地的状态，大陆存档的场景重新导出（multicity-design.md 第 26 节）。

- 离线对比加了真实集：`tools/snapshot.py` 经 Tuner 把运行中对局的一个窗口（地形、河流、归属、已建区域与奇观、科技、地图钉）导出成场景文件（`tests/compare/scenes/`，编号 `RS`/`RM`），并带上游戏里 DMT 对每个候选格的判定，`snapshot.py check` 用它核对离线世界；三张压力存档导出了 24 个场景，风云变幻的 19 个与游戏逐格一致。`summarize.py` 把它们列为 `real` 组；`compare.mjs --ruleset` 只取规则库对应的场景（multicity-design.md 第 25 节）。
- 引擎审计 `tests/bench/audit_engine.lua`：存档里每座城、每种区域，引擎可建格与“本模组候选 + DMT”逐格比较，另查需相邻区域的奇观认不认别城的区域。发现两条引擎有、DMT 没有的规则：淹没的沿海低地不能放区域（#44）、奇观只认本城的相邻区域（#45），都排到 v1.2.0；AGENTS 坑 41、42。
- 对比结果记下求解器自报的质量（穷举、距估计上界的差距、截断、未收敛），`summarize.py` 汇总，并统计估计上界被已知最好解突破的次数：开发集单城 72 个场景里突破 6 次，估计上界不是真上界（#36）。
- `validate.py` 顺带检查创意工坊的文字（`tools/workshop.py` 打包会拒绝的内容，如更新说明里的英文直引号），发版工作流不再因此失败。

## v1.1.2（2026-10-23）

修正版：[发布页](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/tag/v1.1.2)。修合作者第四轮实测报告的四个问题（multicity-design.md 第 24 节）。

玩家能看到的变化：

- 多城：一座城的区域只放在它的领土能连到的格子上。游戏里城市只能扩张或购买挨着自己领土的格子，所以被别的城（已有的或方案里的）隔开的格子现在不再使用；之前方案可能把一座城的区域放到另一座城的区域后面，建不出来（[#35](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/35)、[#38](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/38)）。单城页同样只用能连到的格子。
- 结果里每个区域标出城市还要先做的事：格子还没有归属时写“需先扩张或购买”，格上的地貌要科技才能清除时写“需先研究某科技”（[#38](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/38)）。只是提示，不改变方案。
- 地图预览里钉下的数字改为 DMT 的相邻加成（和游戏放置时看到的一样），不再是按权重算的分；“好位置”着色里的数字也一样。加权分仍在面板里（[#34](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/34)）。
- 预览方案时地图上不再出现每格的魅力数字：预览改用政体透镜的图层着色（[#33](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/33)）。
- 创意工坊的预览图改成画的：四座城和它们之间联动的区域，不再用游戏截图（[#41](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/41)）。

仓库与流程：

- 离线对比的裁判也检查领土连通（违规种类 `unreachable`）；`compare.mjs --probe` 在模拟引擎里跑一段 Lua，查某个场景里的细节。
- 开发流程：一批 Issue 在一个分支上分多个提交修好，只开一个 PR，发版准备也放进去；CI 只在 PR 上跑，合并后 `main` 上不再重跑，往 PR 上推新提交会取消没跑完的那一轮，只改文档的 PR 只跑 `validate.py`（CONTRIBUTING.md）。
- 创意工坊：在 Mac 上用 SteamCMD 更新物品可行（贡献者账号，不带预览图）；提交包里渲染图的文件名带内容摘要，UPLOAD.md 列出物品页上要上传、删除的图（docs/workshop-upload.md）。

## v1.1.1（2026-10-23）

修正版：[发布页](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/tag/v1.1.1)。修合作者第三轮实测报告的三个问题。

玩家能看到的变化：

- 多城：市政广场、外交区这类全帝国限建的区域在共用清单里设为必建时，放在城市列表里最靠前的那座城，其他城标“已达帝国上限”，从候选里补足每城数量（[#28](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/28)）。之前这些城会少规划一个区域。
- 城址钉一环内没有主人的格子留给这座新城，别的城不再在上面规划区域（建城时这些格子归新城）。多城页和单城页都是这样（[#26](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/26)）。
- 英文界面：结果下面那行质量说明，句首字母大写，中间各段小写，不再出现“press Improve; The search budget ran out”。
- 启动栏按钮的悬停提示显示版本号，问题反馈模板改为照这里填版本（[#27](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/27)）。

仓库与流程：

- 上架 Steam 创意工坊：[智能区域规划器](https://steamcommunity.com/sharedfiles/filedetails/?id=3824473635)，内容是 v1.1.0。README、中英安装说明和介绍与评测页把订阅列为第一种装法，并提醒 Mods 文件夹里和创意工坊只留一份：两份都在时游戏只加载其中一份，不一定是新的，也不一定是启用的那份。
- README 改成英文在前、中文在后的完整双语：能做什么、安装、参与开发、许可证都有英文。英文安装说明补上已知限制和已测平台。Release 的压缩包不再带给测试者的说明 `TEST_GUIDE.md`（本地给测试者打的包照旧带）。开发文档仍是中文，入口处加了英文说明。
- 两份都装时游戏加载哪一份：实测是先登记的那份，与启用哪份无关，之前文档写成“Mods 里那份”是错的，已更正；游戏内测试开测前检查加载的是不是 deploy 的那份。
- 中英界面的单城、选城址、多城页签和英文城址提示截图按当前界面重拍，README、中英介绍页、创意工坊图片清单和用法示意图改用新图。
- 压力测试的三张存档在维护者的账号（缺 16 个 DLC）上重新打过；离线对比的规则库仍是全 DLC 导出的那份，导出脚本会拒绝用文明更少的规则覆盖它。

## v1.1.0（2026-10-22）

第二个公开版本：[发布页](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/tag/v1.1.0)。从这一版起，介绍与评测页有英文版，Release 附带创意工坊提交包。

玩家能看到的变化：

- 选城址：悬停列出每个城址拿到的奢侈、战略资源和份数，标出算作新种类的；行上的奢侈分、战略分按整套方案归属后再算，重叠的资源不再两边都算，各城址的分加起来等于方案总分（[#8](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/8)）。
- 选城址：悬停分别写出离我方最近的城市或已打城址钉的距离、离本方案其他城址的距离（[#9](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/9)）。
- “添加奇观”下拉框按时代排列，同一时代按造价从低到高；悬停显示时代（[#7](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/7)）。
- 英文界面在游戏里逐页检查过：英文分隔符丢了空格（游戏去掉文本首尾的空格）、“奇观”“好位置”“区域清单”“档位”标签被下拉框挡住、按钮和开关文字溢出、过长的区域名和奇观名被截断，都已修好；“1 wonders”这类单复数按游戏的写法处理。补了英文界面截图，用在创意工坊、用法示意图和英文介绍页上（[#2](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/2)）。
- 英文界面改用游戏自己的叫法：tile（不再写 plot）、valid（不再写 legal）、map tack、Specialty districts、Woods / Rainforest / Marsh 等专有名词首字母大写；“Need population”分组改叫“Specialty districts”，“Tier”改叫“Effort”，提醒钉名改为“Don't chop: …”。中文界面和文档里的名称也按游戏中文改：政府广场 → 市政广场，林苑、圣所 → 古树林、避难所，水坝 → 堤坝，航天中心 → 宇航中心，科森 → U型港，苏库巴 → 曼丁哥市场，主菜单的“附加内容” → “额外内容”（[#2](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/2) 的文字部分）。
- “介绍与评测”页有了英文版（前 6 节，附录链接到中文页），与中文页随同一个 Release 发布，数字来自同一份数据；两页顶部互相链接，压缩包和 Release 附件里各有一份单文件版（[#5](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/5)）。
- README 顶部加了英文简介和下载、英文介绍页、英文安装说明三个链接；压缩包里多了英文安装与使用说明 `INSTALL_AND_USE_EN.md`（[#3](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/3)）。

仓库与流程：

- 准备上架 Steam 创意工坊：标题、中英简介、预览图和示意图放在 `workshop/`；每个 Release 附带创意工坊提交包，由合作者在 Windows 上上传。
- 问题反馈模板改为中英并列，新建 Issue 的页面链接介绍与评测页和安装说明；GitHub 发布说明以后英文在前、中文在后（[#4](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/4)、[#6](https://github.com/SmallSpider0/civ6-smart-district-planner/issues/6)）。
- 游戏内测试不再假定所有 DLC 和规则都在：没有保护区（越南和忽必烈包）时、原版规则没有“港口与商业中心分城”这条规则时，相关检查跳过。

## v1.0.0（2026-10-22）

第一个公开版本：[发布页](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/tag/v1.0.0)有压缩包和单文件的介绍与评测页，网页版在 <https://smallspider0.github.io/civ6-smart-district-planner/>。这一版相对上一段只改了仓库和文档，模组本身没有变化。

- 仓库整理，为上 GitHub 和与 Windows 合作开发做准备：
  - 加了 MIT 许可证、`.gitattributes`（统一 LF）、CI（validate 和离线测试，在 Ubuntu 和 Windows 上跑）、Issue 和 PR 模板。
  - 游戏和 Steam 的位置集中到 `tools/paths.py`，Windows 有了默认位置；`tools/setup_reference.py` 在两个平台上建 `reference/` 链接。
  - `game.py` 的退出、开局、关弹窗可以在 Windows 上用。
  - 文档分成共用约定（AGENTS.md、[CONTRIBUTING.md](CONTRIBUTING.md)）和平台环境（[macOS](docs/dev-macos.md)、[Windows](docs/dev-windows.md)）。
- 交付报告改写成面向玩家的“介绍与评测”页：前 6 节讲能做什么、安装与使用、和 AMT、Empire Planner 的对比（只写做法差异和实测结果）、速度、已知限制、反馈；技术说明和完整数据放进折叠的附录。验收表以自测报告为准，后续设计选择移到[多城设计第 18.2 节](docs/multicity-design.md#182-现状2026-10-22)，交付物清单删掉。
- 发布 Release 时自动打包、附上页面，并把页面发布到 GitHub Pages；README 顶部加了下载、介绍与评测、安装三个链接。

## 2026-10-22（c5e70cb）

- 保护区的林苑、圣所给周边地块的产出，只在保护区设为必建时计分；从候选里挑出时只计住房，周边产出照常显示，标"候选，不计分"。

## 2026-10-21 第二轮实测反馈与压力测试（08f6c36、2ffc379）

[多城设计第 22 节](docs/multicity-design.md#22-第二轮实测反馈点击问题港口与商业中心分城社区与保护区2026-10-21)

- 修好三个点击问题：区域格子点到必建后点不动、城址钉取消勾选无效、"替换旧钉"删掉选城址页打的钉。
- 港口与商业中心默认不放在同一座城。
- 社区按魅力计住房，保护区计魅力和周边产出（`SDP_Appeal`），魅力模型按游戏实测校准。
- 娱乐中心和水上乐园不放进同一座城；必建区域抢同一块地时，放下能放的，另一个写明原因。
- 区域占掉农场、牧场时，结果里单列少掉的改良设施住房（只提示，不计分）。
- 真实鼠标点击测试 `realclick.py`；三张后期存档上的压力测试 `stress.py`。

## 2026-10-21 多城标准档的宽束联合起点（98d0960、0096850）

[多城设计第 21 节](docs/multicity-design.md#21-多城标准档宽束联合起点2026-10-21)

## 2026-10-20 第一轮实测反馈，阶段 14–18（8eb7d42、41f9842、cb86697）

[多城设计第 20 节](docs/multicity-design.md#20-实测反馈的改进阶段-14182026-10-20)

- 区域可设为必建、候选或不建，规划器从候选里挑，并给出组合不同的三套方案。
- 距离成本；缺淡水时自动加水渠，泛滥平原多时自动加水坝；"勿砍"提醒钉；面板重新布局。
- 给合作者的测试包和交付报告（55eff74、40d699f）。

## 2026-10-20 游戏内验证与对比（99d2308 至 432d1a7）

[多城设计第 17–19 节](docs/multicity-design.md#17-游戏内验证与校准2026-10-20)

- 在游戏里验证阶段 8–12，修了后台计算、选城址和预览的问题，校准单价和预计耗时。
- 钉按城市编号；遵守文明特性里的相邻和放置规则。
- 用真实规则库和原样的 DMT、AMT、Empire Planner 代码做离线对比，含留出集、多组权重、奇观和选城址。
- 多城逐城清单与模板、游戏引擎可建格复核、撤销记录随存档保存、单城奇观、"好位置"热力图、Shift+L 快捷键。
- 工业区、娱乐中心、水上乐园的覆盖范围。

## 2026-10-19 阶段 0–12（ea554be 至 0db1024）

- 阶段 0：校验、部署、FireTuner 客户端、游戏内测试工具。
- 阶段 1–7：面板骨架、规则与城市扫描、DMT 假想钉层、确定性求解器、面板与打钉撤销、交付文档（[设计说明](docs/design.md)）。
- 阶段 8：求解档位、地块部分、更快的单城搜索（[多城设计第 15 节](docs/multicity-design.md#15-阶段-8-实现记录2026-10-19离线)）。
- 阶段 9–12：多城区域、多套方案与预览、奇观、选城址（[多城设计第 16 节](docs/multicity-design.md#16-阶段-912-实现记录2026-10-19离线)）。
