# 和热门模组的兼容：调研记录

2026-11-05 调研（维护者要求；起因是创意工坊 LotusEater 11-04 的评论：武则天“圣母神皇”的“区域挨奇观 +2”和“所有区域之间加标准相邻”的模组算不进方案）。只读源码和网页，没开游戏，没改 mod 代码。结论和待定问题在 Issue #295；这里是数字出处和交接。“和而不同”本体的兼容已在 #277 查过（[issue-277-hebutong.md](issue-277-hebutong.md)），这里不重复。

## 1. 对象和方法

- 热门榜：创意工坊浏览页按“不重复订阅者总计”取前 7 页（213 个物品），再用 Steam Web API `ISteamRemoteStorage/GetPublishedFileDetails` 取当前订阅数（2026-11-05）。本模组当日 2,544。
- 代码：本机已订阅的约 130 个在 Steam 的创意工坊目录；另用 SteamCMD（缓存登录，`+@NoPromptForPassword 1`，没输密码、没订阅）下载 37 个到 `~/steamcmd-home/.../workshop/content/289070/`。macOS 上一条命令带多个 `+workshop_download_item` 只下第一个，要一个一个下。只读、grep，没运行其中任何脚本，文件不进仓库。
- 分工：界面模组、规划类模组、规则类模组各派一个子 agent 读代码（Opus，medium），玩家需求派一个子 agent 读网页；武则天那条和“模块化相邻加成”由本会话自己查。子 agent 的结论里关于本模组的说法逐条回到代码核对过（第 4 节标“已核对”的）。

### 订阅数（节选，2026-11-05）

| 类别 | 模组（物品 ID） | 订阅 |
|---|---|---|
| 地图钉/规划 | Detailed Map Tacks（2428969051） | 2,509,712 |
| | Detailed Wonder Reminder Enhanced（2794603014） | 454,762 |
| | Removable Districts（970184582） | 350,011 |
| | Movable Districts（2683624437） | 185,142 |
| | Auto Map Tacks Planner（3771382002） | 约 2.3 万（#277 时 23,296） |
| 界面 | Quick Deals（2460661464） | 2,347,670 |
| | Extended Policy Cards（2266952591） | 2,223,891 |
| | Better Report Screen（1312585482） | 1,886,310 |
| | Better Trade Screen（873246701） | 1,218,234 |
| | More Lenses（871712879） | 562,378 |
| | Unique District Icons（882664162） | 541,210 |
| | CQUI（2115302648） | 146,244 |
| 大型规则 | 和而不同 v2.2（2465378070） | 231,131 |
| | Better Balanced Game 7.5.1（2865001760） | 216,804 |
| | JNR District Expansion 系列（Commerce 2056401784 等 11 个） | 各约 8.9–17.2 万 |
| | GoldenAge - Brave New World（2209309479） | 165,902 |
| | Civilizations Expanded（2036753727） | 100,129 |
| | 和而不同附属：行业与公司 / 区域扩展适配 / 城邦多样化 / 文明之春（2616754773 / 2701747165 / 2652224074 / 2860503037） | 99,171 / 94,802 / 94,482 / 73,499 |
| 相邻加成 | 模块化相邻加成：核心（3429735059） | 61,338 |
| | 模块化相邻加成：区域相邻加成（示例，3429105930） | 8,062 |
| | Enhanced Districts Adjacencies（3009762236） | 7,142 |
| | 奇观相邻加成补贴（3377648600） | 5,939 |
| | 奇观为区域提供标准相邻加成（3413489493） | 2,735 |
| 范围 | Workable 4th Ring（3220078106） | 58,576 |

前 213 个里约一半是纯外观、地图、单个奇观或单个文明；能影响方案的见第 4 节。

## 2. 武则天那条 +2 为什么没算进去

- “圣母神皇”武则天（`TRAIT_WU_ZETIAN_ALT`）不是游戏本体的（本体的武则天在 `DLC/RulersOfChina`，没有这条），来自“和而不同：文明之春”2860503037 的 `UpdateDatabase/China_Expansion/WuZeTian.sql`：已建成奇观的格子用 `MODIFIER_PLAYER_DISTRICTS_ATTACH_MODIFIER`（条件 `PLOT_HAS_COMPLETE_WONDER`）给相邻区域挂一条 `MODIFIER_PLAYER_DISTRICTS_ADJUST_BASE_YIELD_CHANGE`（+2，按区域对应的产出）。
- 同时开了“模块化相邻加成”核心时，和而不同的 `ModSupport/ModularAdjacencyBonus/Database.sql`（criteria `Modular_Adjacency_Bonus_Expansion2` = GS 规则集 + `ModInUse eaffc7c2-…`）删掉这条修正，改成往 `Ruivo_New_Adjacency` 表写一行（`AdjacencyType = FROM_ADJACENT_WONDERS`，`YieldChange = 2`）。
- “模块化相邻加成”的做法：游戏脚本（`NEW_ADJACENCY_BONUS_BY_RUIVO_GP.lua`）每回合给**已建成**的区域数相邻对象（`RUIVO_STAT_MODULE_GP.lua` 里 133 种计数函数，如 `FROM_ADJACENT_WONDERS` 读 `Plot:GetWonderType()` 和 `IsWonderComplete()`，`FROM_ADJACENT_DISTRICT` 读 `Plot:GetDistrictType()`），把数目按二进制拆开写进格子属性；修正 `RUIVO_MODIFIER_PLAYER_DISTRICTS_ADJUST_BASE_YIELD_CHANGE`（效果 `EFFECT_ADJUST_DISTRICT_BASE_YIELD_CHANGE`）用 `REQUIREMENT_PLOT_PROPERTY_MATCHES` 读属性给产出。
- DMT 只认 `EFFECT_DISTRICT/FEATURE/IMPROVEMENT/TERRAIN/RIVER_ADJACENCY`、`EFFECT_ADJUST_DISTRICT_YIELD_BASED_ON_ADJACENCY_BONUS` 等 10 种效果（`reference/dmt/ui/dmt_modifiercalculator.lua:50-62`），`EFFECT_ATTACH_MODIFIER` 被注释掉；条件只认 5 种（`dmt_modifierrequirementchecker.lua:110-130`），不认的当不满足。所以两种写法 DMT 都在过滤那一步丢掉。属性写法原理上也算不了：属性只写在已建区域上，规划的钉上没有。
- 本模组：`SDP_Overlay.RefreshModifiers` 只是替 DMT 建它的修正缓存（坑 25），读得到也会被 DMT 丢掉；`SDP_Rules.AdjacencyTable` 只读规则表。结论：**不是本模组漏读，是 DMT 不认这两种写法**，原版游戏也有同类（挂载修正写的能力），只是少。
- 和而不同本体里同类写法的规模（grep 计数）：`MODIFIER_PLAYER_DISTRICTS_ATTACH_MODIFIER` 19 个文件 76 处（多数不是相邻加成），按规则表写的区域相邻是主体（#277 第 2 条）。
- “所有区域之间加标准相邻”：评论没说是哪个。搜到的几个小模组里，奇观为区域提供标准相邻加成（3413489493）、奇观相邻加成补贴（3377648600）、更好的区域相邻（3731321286）、Enhanced Districts Adjacencies（3009762236，相邻部分）都写成规则表（`District_Adjacencies` + `Adjacency_YieldChanges`，`AdjacentWonder` / `OtherDistrictAdjacent`），本模组排序和 DMT 精算都读得到；只有“模块化相邻加成：区域相邻加成”示例（3429105930，116 行 `Ruivo_New_Adjacency`，含 `MODIFIER_SCIENCE_FROM_ADJACENT_DISTRICT` 等）读不到。所以评论者用的很可能是“模块化相邻加成”一系，要问一句。

## 3. 别的模组怎么做兼容

### 界面模组（子 agent 读 15 个）

- **替换上下文脚本，先 include 原文件再包住旧函数**（CQUI 28 个界面、DMT、Quick Deals、Sukritact）：先存 `BASE_*` 再覆盖。同一界面只有 LoadOrder 最高的那份生效。
- **按顺序试 include，载到一个就停**：DMT `mappinmanager_dmt.lua:4-14` 先试 CQUI 的 `mappinmanager_cqui.lua`；Quick Deals 按资料片 2 → 1 → 原版；Sukritact 先 CQUI 再原文件。
- **`ImportFiles` 覆盖同名文件**（BTS、Extended Policy Cards、More Lenses）：别人的替换脚本 include 时读到它，于是叠在一起（Extended Policy Cards + CQUI）。
- **modinfo 条件**：`ModInUse`、`inverse="1"`、`RuleSetInUse`、`LeaderPlayable`（CQUI `CQUI.modinfo:66-71`，Sukritact 分 CQUI 在/不在两条路）。
- **运行时判断**：`Modding.IsModActive`（CQUI `citypanel.lua:99`，BRS 的修正分析接口在时才用）。
- **收编并屏蔽**：CQUI 把 More Lenses、BTS 等 8 个的代码收进 `Integrations/`，modinfo 里 `<Blocks>` 原模组（`CQUI.modinfo:15-26`）。
- **开放接口**：CQUI `LuaEvents.LaunchBar_AddIcon`；BRS 的报告列表加载器（别的模组往 `RLLReports` 表插一行）和 `ExposedMembers.RMA`；More Lenses 的 `ModLens_*` 插件和 `g_ModLenses`。
- **专门的兼容补丁模组**：Diplomacy Compatibility Patch（2471091953）补十几个外交、领袖图标类模组之间的冲突，每个对象一条 `ModInUse` + 一段 `ImportFiles`，用极高的 LoadOrder 压住别人。

### 规则类模组（子 agent 读约 35 个）

- **本体里按条件加载**：和而不同给约 20 个模组做兼容（`ModSupport/` 下 JNR、Removable Districts、Resourceful2、SukWonders、WetLands、BRS、模块化相邻加成等），每个是 `Criteria` = `RuleSetInUse` + `ModInUse 对方 ID`，`LoadOrder` 排到对方后面（Removable Districts 那段到 10000000）；`inverse` 用来让出自己的重复内容（自带的金矿资源只在 Sukritact's Resources 不在时加载）。
- **SQL 里判断行在不在**：`where exists (select … from Features/Traits …)`、`insert or ignore`、`CREATE TABLE IF NOT EXISTS`（Terra Mirabilis 先替别人建表）。不用 GUID，对方不在时语句什么都不做，但依赖 LoadOrder。
- **另出附属模组**：只在要硬依赖时（`Dependencies` 会强制玩家开对方）。2701747165 依赖和而不同本体，按和而不同的科技树重写 JNR 的建筑；2616754773 依赖本体 + Monopoly++，2652224074 依赖 CIVITAS + 本体。
- **让出数据**：JNR 每个模组一个 `UC` 条件，带两条 `inverse`（Golden Age、和而不同附属），遇到它们就不加载自己的数据，由对方的补丁接管。
- **`LeaderPlayable`**：BBG、Civilizations Expanded 判断 DLC 在不在，不管 DLC 怎么挂都认。
- **`ConfigurationValueMatches`**：Golden Age 功能分块当开关；BBG 的设置项。
- **`References`**（只排加载顺序、不强制开启）：More Maritime、Empire Planner。

### 规划类模组（子 agent 读 DMT、AMT、EP、DWP 和 8 个小模组）

- DMT：`ReplaceUIScript` 换 `MapPinManager`、`MapPinPopup`（LoadOrder 12345）；`ImportFiles` 导出 9 个文件给别人 include；对别的模组只有一处判断（先试 CQUI 的 MapPinManager）；没有 `Modding.`、`ExposedMembers`、Criteria。别的模组加的区域、相邻、放置规则都从 GameInfo 读，新区域只要有 `ICON_<类型>` 图标并写进那些表就能算。
- AMT：modinfo 硬依赖 DMT；include DMT 后**不移除** DMT 订阅的事件（每次加钉删钉它那份也重算、广播一次）；仿真层的写法和本模组相同；不检测别的规划器。
- Empire Planner：`References` + 运行时 `pcall(include, "dmt_yieldcalculator")`，DMT 不在就退回自己的规则；移除 DMT 的订阅；**打钉、清钉都不通知 DMT**，按格子（玩家配置 `EP_PINS`）认自己的钉，“清除”会删掉那些格上不论谁打的钉（`ep_panel.lua:177-181`）。
- DWP：硬依赖 DMT，不移除订阅；自己的钉按 ID 记，删前发 `DMT_MapPinRemoved`。
- 小模组用 `<Blocks>` 屏蔽冲突的版本（Detailed Wonder Reminder、Radial Measuring Tool、3755368190 屏蔽 CQUI）；游戏本体 `FrontEnd/Mods.lua` 读 blocks。
- 规划器之间都不互相检测。

## 4. 对本模组的影响

### 读代码确定没问题

- **界面**：CQUI 开着时 `/InGame/LaunchBar/ButtonStack` 还在（CQUI `Assets/UI/launchbar.xml:14`，外面多一层没 ID 的 Stack，本模组按 ID 查，不影响；`LaunchBacking` 等也在；CQUI 重算宽度用的是游戏原来的 `RealizeBacking`）。BRS 不碰启动栏。Quick Deals、Global Relations 也往同一个栈里注入按钮，写法相同。没有界面模组碰 `GetMapPinSubject`、`UpdateMapPinSubject`、`DMT_*`。CQUI 的 MapPinManager 被 DMT 的压过，DMT 先 include 它，功能都在。More Lenses 和 CQUI 处理政体图层的方式和原版一样（本模组借它分色，坑 29）。Unique District Icons 只换钉上的图标美术。
- **规则**：和而不同（#277）、BBG、JNR 系列（只加建筑，不加区域；奢侈资源相邻 DMT 认）、Civilizations Expanded、Golden Age 的国家区域（`MaxPerPlayer`、互斥表本模组都读）、Better Coastal Cities、Seaside Sectors、Removable Districts（删掉后格子恢复）、City Canal Rework、新奇观（三峡大坝、新天鹅堡、Wonder Tweaks 的放置条件都在 DMT 查的表里）、Resourceful 2 和 Sukritact's Resources（新资源都有 `Resource_Harvests`）、Wetlands（可移除地貌）。
- **规划器之间**：AMT、DWP、EP 替换的全局函数都在它们自己的 Lua 状态里，碰不到本模组的仿真层（EP `ep_rules.lua:1835-1836` 的注释写明 LuaEvents 跨上下文、它那份副本不影响 DMT 的上下文）。几个规划器真正共用的是 DMT 存在玩家配置里的钉数据、真实的地图钉和 `LuaEvents.DMT_*`。坑 20 的结论（一局只开一个）仍然成立，但原因写的是“都 hook `GetMapPinSubject`”，按代码看不准，要实测后改写。

### 方案可能差一点、不会违规

- **DMT 不认的加成写法**：挂载修正（`EFFECT_ATTACH_MODIFIER`）、属性条件、`COLLECTION_OWNER_CITY` 集合（JNR Worship、Aqueduct 的建筑相邻）、取反条件。例：武则天 +2、模块化相邻加成一系。少算，不会违规。
- **排序模型只读规则表**：修正式的区域间相邻（Civilizations Expanded、BBG 的狄奥多拉、海克斯大乱斗的遗物）只在精算时算到，排序阶段看不见，靠局部搜索兜底（#277 第 2 条同理）。
- **不砍树的区域（已核对）**：Green Cities（1827359088，8.8 万）给所有文明一条特性，区域建在树林上不砍树；原版越南的特色区域也必须建在地貌上、不移除。DMT 认（`WillDistrictRemoveFeature`，`dmt_yieldcalculator.lua:970-976`），但本模组关掉“允许砍树”时，`SDP_City.lua:319-321` 把所有 `Removable` 地貌的格直接排除，这些格被白白排除。越南是官方 DLC，这一条不开模组也会碰到（玩越南并关掉砍树时，特色区域几乎没有格可放）：按 bug 另开 #293。
- **每个玩家各一座的奇观（已核对）**：National Wonders（2503076363，11.4 万）及 Golden Age、和而不同自带的“国家奇观”（`MaxPlayerInstances = 1`，每个玩家都能建一座）。`SDP_Wonders.Built`（`SDP_Wonders.lua:9-27`）把在别人领土里看到的同名奇观也记成“已建”，本方就不再规划。原版奇观都是全球唯一，不受影响。另开 #294。

### 可能漏格（不会违规）

- **Workable 4th Ring（已核对）**：改 `CITY_MAX_BUY_PLOT_RANGE` 为 4，并换掉 GameCore DLL（`Workable4thRing_Config.sql`，只有 `Binaries/Win64`，Mac 上用不了）。本模组写死 3 环（`SDP_City.RADIUS = 3`），不会放到第 4 环，所以不违规；要是引擎允许第 4 环放区域，就是漏格。引擎怎么限定区域范围在 DLL 里，Lua 看不出，只能在 Windows 上实测。

### 需实测

- CQUI 开着时本模组按钮的位置和背板宽度（和 Quick Deals、Global Relations 都注入时）；CQUI 改了左键和地图钉放置（`worldinput_CQUI.lua:248`），打钉后进出界面模式是否正常。
- More Lenses 或 CQUI 的透镜和本模组的预览着色同时显示时会不会互相清掉。
- EP 打的钉 DMT 不知道、EP 删掉的钉还留在 DMT 的记录里：本模组以 DMT 的记录为底（`SDP_Overlay.lua:127`），会不会看不见 EP 的钉对邻格的加成、把删掉的钉当邻居。锁定钉另由 `GetMapPins` 加入（`SDP_Overlay.lua:368-373`），所以不会把区域放在 EP 的钉上。
- AMT、DWP 同开时本模组打 N 个钉，每个钉在它们的 DMT 副本里各重算一次，卡多少。
- `<Blocks>` 能不能挡住同开、提示什么样。
- 挂载修正挂出的子修正 DMT 从 `GameEffects.GetModifiers()` 读，理论上能看到（CIVITAS 宗主奖励、Terra Mirabilis 部分自然奇观相邻），没实测。

## 5. 玩家需求

子 agent 读网页（只读，不登录）。全部来自 Steam 创意工坊：Reddit 不让抓、B 站被验证码挡住、贴吧和 NGA 没搜到相关帖、CivFanatics 只有 Civ7 版 DMT 的帖。Steam 评论接口后来限流（HTTP 429），和而不同只取到最新 200 条（共 1385 条）。

| 来源 | 取到 | 和“规划/地图钉模组兼容别的模组”有关的 |
|---|---|---|
| 本模组评论 | 20 条 | 2 人 4 条，都是和而不同（11-01 一人问能否兼容；LotusEater 11-02 问、11-04 指出武则天 +2 和“所有区域之间加标准相邻”的模组算不进去） |
| DMT 评论 + “Bugs & Mod Compatibility”帖 | 792 条 + 前约 45 帖 | 约 30 条、约 28 人，2021-03 至 2026-11：和别的地图钉、界面模组冲突约 9 条（Map Tacks、Map Tacks+、City Lights、Production Queue 等，多在 2021–2024）；问 CQUI 能不能用约 5 条，都答能用，没找到真坏的；大型规则模组下加成不对约 6 条（Golden Age 3 条，Civilizations Expanded 1 条，和而不同“国家奇观显示两份”1 条，BBG 1 条提问）；模组文明、奇观的特殊规则没算约 6 条（Sukritact 西藏的万神殿相邻、Albro 的奇观、CIVITAS、JNR 的罗马堡垒相邻等） |
| AMT 评论 | 72 条 | 1 条问模组文明、模组万神殿能不能处理（作者答：走标准规则表的一般行，自定义 Lua 的不一定）；作者 2026-08-13 注明支持 BBG |
| Empire Planner 评论 | 7 条 | 1 条：模组加的苏伊士运河类奇观被乱放 |
| District & Wonder Planner 评论 | 11 条 | 0 |
| 模块化相邻加成核心评论 | 79 条 | 作者自述用 SQL + Lua 实现“伪相邻加成”（2025-02-18）；兼容问题都是和别的模组同开闪退、进不了游戏，没有规划器 |
| 和而不同评论（最新 200 条）和“兼容性”帖 | 200 条 | 0 条提地图钉或规划器；界面冲突说的是 Concise UI 让建造界面打不开 |
| 和而不同的推荐合集 | 2399536104（104 项）、2640679476（27 项） | 前一个的“实用界面”里收了 DMT；后一个“已知兼容”里没有地图钉、规划类 |

归纳：

- 会同时开：和而不同作者自己的推荐合集里就有 DMT（直接证据）；DMT 订阅是和而不同的 10 倍以上（推断：和而不同玩家大多开着 DMT）。
- 抱怨的是“特殊规则算不对”，不是“开不起来”：DMT 评论区的规则模组问题都是加成不显示或不对；本模组评论区的那条也是。“和别的地图钉、界面模组冲突”是 DMT 早年最多的，本模组还没人报。
- 确实是少数人在问：DMT 792 条里不到 4%；本模组 20 条里 4 条（2 人），比例高，和本模组以中文玩家为主、和而不同主力也是中文玩家一致。
- 对顺序的影响：和而不同一系（含它的附属“文明之春”、配套的模块化相邻加成）排第一；“国家奇观”在和而不同、Golden Age 里都有，DMT 那边也有人报，本模组的那处小问题值得先修；CQUI、BBG、规划器同开只有提问、没有故障报告，不需要先做。

出处链接：[本模组评论](https://steamcommunity.com/sharedfiles/filedetails/comments/3824473635)、[DMT 评论](https://steamcommunity.com/sharedfiles/filedetails/comments/2428969051)、[DMT Bugs 帖](https://steamcommunity.com/workshop/filedetails/discussion/2428969051/3094509155618934920/)、[AMT 评论](https://steamcommunity.com/sharedfiles/filedetails/comments/3771382002)、[Empire Planner 评论](https://steamcommunity.com/sharedfiles/filedetails/comments/3793348626)、[DWP 评论](https://steamcommunity.com/sharedfiles/filedetails/comments/3780936549)、[模块化相邻加成核心评论](https://steamcommunity.com/sharedfiles/filedetails/comments/3429735059)、[和而不同评论](https://steamcommunity.com/sharedfiles/filedetails/comments/2465378070)、[和而不同全集](https://steamcommunity.com/sharedfiles/filedetails/?id=2399536104)、[和而不同已知兼容](https://steamcommunity.com/sharedfiles/filedetails/?id=2640679476)。条数是子 agent 按关键词（compatib、兼容、Harmony、和而不同、BBG、CQUI、mod、adjacency、相邻）筛后人工归类的，误差几条。

## 6. 能怎么补（给 Issue 的方案用）

| 项 | 做法 | 不开那个模组时 | 工作量 / 风险 |
|---|---|---|---|
| 不砍树的区域 | 排除可移除地貌前问 DMT 的 `WillDistrictRemoveFeature(区域, 地貌)`，不会被移除的不排除 | 结果相同（越南除外，那是修 bug） | 小 / 低；第三位版本 |
| 每个玩家各一座的奇观 | `MaxPlayerInstances > 0` 且不是全球唯一的奇观，只按本方城市判“已建” | 原版奇观全是全球唯一，不变 | 小 / 低 |
| 第 4 环 | 半径读 `GlobalParameters.CITY_MAX_BUY_PLOT_RANGE`（原版 3）；或以引擎可建格（`SDP_City.EngineRefused` 用的那份）为准 | 3，不变 | 小 / 中：要 Windows 实测引擎是否允许；4 环候选格多约 70%，求解变慢 |
| DMT 不认的挂载修正相邻（武则天这类） | 本模组自己认一种常见形状：奇观或区域格挂给相邻区域的 `ADJUST_BASE_YIELD_CHANGE`；或请 DMT 作者支持 `EFFECT_ATTACH_MODIFIER` | 原版几乎没有这种写法，不变 | 中 / 中：等于在 DMT 之外自己算一部分加成，和需求文档“加成复用 DMT”有出入，悬停明细要另起一行 |
| 模块化相邻加成 | 有 `GameInfo.Ruivo_New_Adjacency` 时读它的行：常见几种计数（相邻区域、奇观、地形、资源）在本模组的仿真棋盘上数；或 include 它的 `AdjacencyBonusSupport` 调它的计数函数（只看真实地图，看不到规划中的区域） | 表不存在，整段不跑 | 大 / 高：133 种计数、对方改版就要跟；同上和“复用 DMT”有出入 |
| “覆盖”认和而不同的范围 | #277 已定不做 | — | — |

## 7. 文件位置

- 订阅数原始数据：会话临时目录 `scratchpad/ws/{rank.txt,details.json}`（会话结束失效）。
- 下载的模组：`~/steamcmd-home/Library/Application Support/Steam/steamapps/workshop/content/289070/`（只读，不进仓库）。
