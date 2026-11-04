# Issue 277：与“和而不同”（Harmony in Diversity）的兼容性

2026-11-04 调研：先只读源码和离线验证（第一条评论），维护者随后同意开游戏实测（第二条评论，@DracoYus）。这里是交接和数字出处。

## 对象

- 创意工坊物品（Steam Web API `GetPublishedFileDetails` 查得，2026-11-04）：
  - 2465378070 “Civ6 Plus: Harmony in Diversity v2.2”（本体，mod id `521b8777-0977-4859-a5ee-3e411a732e5c`，约 506 MB，绝大部分是图片和音频）
  - 2701747165 “District Expansion (Harmony in Diversity Edition)”（给 JNR 区域扩展系列的适配，依赖本体，3.9 MB）
  - 其他附属（没下载）：2652224074 City-States Diversity，2616754773 Industries and Corporations，2860503037 Spring of Civilizations；合集 2399536104（完整推荐合集，里面有 DMT 2428969051）、2640679476（已知兼容）。
- 源码另有 GitHub：XHH-Coco/Civ6HarmonyInDiversity（没用）。
- 下载：SteamCMD 匿名登录下载失败（`No Connection`），用已缓存登录的账号（`+@NoPromptForPassword 1`，没输密码）成功。没订阅，没碰 Steam 客户端、游戏和 `Mods.sqlite`。文件在 SteamCMD 自己的家目录（不是游戏的创意工坊目录），另复制一份到会话临时目录，只用 grep 和读文件。文件不进仓库。

## 结论与出处（文件均指本体 2465378070 里的路径）

1. **不占人口的区域**：`UpdateDataBase/DL_Districts.sql` 的 “[Require pop]” 一段把航空港、保护区、娱乐中心、水上乐园（及替代它们的特色区域）设为 `RequiresPopulation = 0`，并删掉娱乐中心与水上乐园的 `MutuallyExclusiveDistricts`。名额公式参数 `DISTRICT_POPULATION_REQUIRED_PER` 被设为 3（`DL_GlobalParameters.sql:124`），与原版相同（Base `GlobalParameters.xml:264`）。
   本模组的名额（`SDP_City.SpecialtyCapacity`、`SpecialtyHave`、`SDP_Rules.PlannableDistricts` 的 `Specialty`）和互斥（`SDP_Rules.Exclusive`）都读 GameInfo。离线验证：会话临时目录里的 `spec_hd_rules.lua`（假世界 + 上述改动），4 项全过：已建娱乐中心不计名额、同城可同时规划娱乐中心和水上乐园、单城四个区域都放下、多城页计数 2 + 必选娱乐中心时占人口的正好 2 个。
   副作用：城址页默认状态 `SDP_Sites.DefaultState` 对不占人口的区域给 OFF，所以娱乐中心、水上乐园在和而不同里只能“必选”，不进候选。
2. **相邻加成**：`UpdateDataBase/Classifications/HD_Classification_Adjacency.sql` 先删原版行（如学院的 `Mountains_Science1..5`），再按地形、区域、改良分类批量生成普通的 `Adjacency_YieldChanges` + `District_Adjacencies` 行（文件末尾“批量生成”“批量插入”）。`DL_DistrictAdjacency.sql` 也只改规则表（用到 `AdjacentResourceClass`、`Self`、`OtherDistrictAdjacent`、Prereq/Obsolete 科技市政）。
   修正式相邻（`EFFECT_*_ADJACENCY`）只在信仰（`DL_Beliefs.sql`）、文明能力（`DL_Civilizations.sql`、`DLCSupport/`）、伟人（`DL_GreatPeople.sql`，如富格尔、阿斯特）、城邦、奇观（`DL_Wonders.sql`）上。排序模型 `SDP_Rules.AdjacencyTable` 只读规则表里区域挨区域的行；修正式的交给 DMT 精评。DMT 的条件检查（`reference/dmt/ui/dmt_modifierrequirementchecker.lua`）只认 5 种条件类型，其余一律当不满足。
3. **放置条件**：除书院地形（`DL_Civilizations.sql:2514` 删 `District_ValidTerrains`）和上面的互斥外，没改 `District_ValidTerrains`、`District_RequiredFeatures`、`NoAdjacentCity` 等；`Gameplay/*.lua` 没有限制放置的钩子（只在建成后触发）。没改 `Resource_Harvests`。
4. **住房、魅力**：社区 `Housing = 3`（`DL_Districts.sql`），本模组 `SDP_Appeal.Rules` 读 `Districts.Housing` + `AppealHousingChanges`；城市基础住房、增长参数读 GlobalParameters（和而不同改了增长公式和每人口食物 3，本模组不用后者）。
5. **Lua 冲突**：全库 grep `GetMapPinSubject`、`UpdateMapPinSubject`、`dmt_`、`MapTacks`、`CanPlacePin` 无结果；`DL.modinfo` 替换的界面是城邦、宗教、生产、城市面板等，没有启动栏、地图钉。坑 20 不适用。
6. **覆盖（真差异）**：`UpdateDataBase/HD_Regional_Yields.sql`（在 `DL_Main_Late2` 里加载，晚于改建筑的 `DL_Buildings.sql`、`DL_Wonders.sql`）把所有 `RegionalRange > 0` 的建筑记进自己的 `HD_BuildingRegionalRange`，再把 `Buildings.RegionalRange` 设为 0（发电厂类 `ResourceTypeConvertedToPower` 非空的除外）；产出由 `Gameplay/RegionalYields.lua` 算，接收方是市中心和已建成未掠夺的社区（`GetPlotDistance <= 范围`）。新增的范围建筑与范围见 `DL_Buildings.sql` 的 “Regional Range” 一段（古罗马剧场、竞技场 4，大学、研究实验室、博物馆、银行、证券交易所等 6，艾尔米塔什博物馆、马拉卡纳体育场 9）。
   本模组 `SDP_Coverage.Reaches` 读 `Buildings.RegionalRange`：在和而不同里只剩发电厂（工业区，6 格）；娱乐中心、奇观、和而不同新增的范围建筑都不计。离线 spec 第 4 项确认范围为 0 时没有覆盖组。覆盖权重默认 0。

## 游戏内实测（2026-11-04 08:03–08:20，macOS）

做法：和而不同本体 2465378070 原样复制进游戏 Mods 目录（文件夹 `SDP277_HD_2465378070`，没订阅）；主菜单经 Tuner 用 `Modding.CreateModGroup("SDP277 HD test", 当前组)` 复制原来的模组组“SDP 测试”（句柄 2）成新组（句柄 3），`Modding.EnableMod(212, true)` 启用和而不同；新组里启用的是原组的官方内容、DMT、本模组，加和而不同。`game.py newgame --state SDP_Panel --capital --reveal --ruleset RULESET_EXPANSION_2`（罗马、固定地图，首都 18,30，内陆），约 55 秒进图。

确认和而不同生效：活动模组里有它的 id；娱乐中心、水上乐园、航空港 `RequiresPopulation = false`；`MutuallyExclusiveDistricts` 0 行；`GameInfo.HD_BuildingRegionalRange` 存在；工厂、体育场、大学、银行的 `Buildings.RegionalRange` = 0，燃煤发电厂 = 6；`DISTRICT_POPULATION_REQUIRED_PER` = 3。（保护区在本账号的规则库里不存在，没测。）

测试文件（没提交）：会话临时目录 `scratchpad/specs/hd_game.lua`（前置 `tests/fixtures/unlock_all.lua` 加首都人口设为 4），`run_tests.py` 4 项全过；输出 `scratchpad/hd_game_run1.txt`。

1. 面板：`SDP_Panel.Open()` 后 `IsOpen()` 为真，启动栏按钮在。本次会话的 Tuner 日志（`logs/tuner-lua.log` 第 206637 行起，副本 `scratchpad/hd-session.log`，715 行）没有 `Runtime Error`；唯一一处 traceback 是我自己的一条查询（查不存在的保护区）。
2. 单城（面板的求解入口）：学院、圣地、娱乐中心、水上乐园。首都 4 人口、2 个名额，已建 0。方案：学院 19,30（科技 6）、娱乐中心 18,29、圣地 20,28（信仰 5），水上乐园报“没有合法格”（首都不靠海，引擎也列不出它的格，见第 4 条）；没有“与已有区域互斥”的报告。引擎可建：0 处拒绝。DMT：给每项打真地图钉后读 DMT 存的悬停明细，3 项与方案完全相同。
3. 多城（`SDP_Multi.Solve`，FAST，首都 + 距 5 格的城址钉 16,25）：必选娱乐中心、水上乐园，候选学院、圣地、剧院广场、商业中心、工业区，每城占人口的区域 2 个（`Target`）。城址：娱乐中心 + 水上乐园 + 学院 + 商业中心（同城两个都规划了，占人口的 2 个）；首都：娱乐中心 + 学院 + 商业中心（占人口的 2 个），水上乐园没有合法格。增量与全量评估一致；首都的方案引擎 0 处拒绝；7 项打钉后与 DMT 悬停明细全部相同。
4. 引擎可建格探针 `tests/bench/probe_engine.lua`：12 种区域 × 36 个首都的格 = 432 组，本模组 + DMT 与引擎全部一致，本模组允许而引擎拒绝 0；运河、堤坝、港口、水上乐园引擎没有可建格（内陆）。输出 `scratchpad/probe_engine_hd.txt`。
5. 覆盖：本模组 `SDP_Coverage.Reaches` 只有工业区（和德国的商业同业工会）6 格。和而不同自己的范围表有 26 个建筑：学院（大学、伊斯兰学校、研究实验室 6）、商业中心（银行、大巴扎、证券交易所 6）、剧院广场（古罗马剧场 4，博物馆、电影制片厂、广播中心 6）、娱乐中心（竞技场 4、蹴球场 5、体育场等 6）、水上乐园（摩天轮 6、水上运动中心 9）、工业区（工厂、各发电厂 6）、奇观（罗马斗兽场、桑科雷大学 6，艾尔米塔什博物馆、马拉卡纳体育场 9）。与读源码的结论一致。

收尾：`game.py menu` 回主菜单，`Modding.DisableMod(212)`，`Modding.SetCurrentModGroup(2)`，`Modding.DeleteModGroup(3)`；`game.py quit`；删 Mods 目录里的 `SDP277_HD_2465378070`。`Mods.sqlite` 测前备份（`scratchpad/backup/Mods.sqlite.before`）。退出后它还留着和而不同的扫描记录，默认组（句柄 1）也多了一行和而不同（游戏把新装的模组加进默认组）；重开游戏到主菜单后游戏扫描发现文件没了，自动清掉：当前组是“SDP 测试”，启用列表与测前相同，没有和而不同。最终 `Mods.sqlite` 与测前相比只有 `sqlite_sequence` 的自增计数不同（`scratchpad/backup/dump.before.sql`、`dump.final.sql`）。

## 没做的

- DMT 对和而不同修正式相邻（信仰、伟人等）的实际显示，没逐条核对。
- 沿海首都（水上乐园、港口能放下的）的单城情形没测；多城里城址那座城已经同时放下了娱乐中心和水上乐园。
- 截图没拍（证据是日志和测试输出）。

## 文件位置

- 下载原件：`~/steamcmd-home/Library/Application Support/Steam/steamapps/workshop/content/289070/{2465378070,2701747165}`
- 只读副本、离线探针、游戏内测试与输出：会话临时目录 `scratchpad/hd-files/`、`scratchpad/specs/{spec_hd_rules.lua,hd_game.lua,hd_pop.lua}`、`scratchpad/{hd_game_run1.txt,probe_engine_hd.txt,hd-session.log}`、`scratchpad/backup/`（会话结束即失效；要留的话改写进 `tests/`）。
