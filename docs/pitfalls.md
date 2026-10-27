# Civ6 Modding 的坑

> The development documents of this project are in Chinese.

本模组开发中踩过、违反必出错的坑，编号固定（代码、提交和文档里写“坑 N”“pitfall N”）。[AGENTS.md](../AGENTS.md) 第 5 节每条一句要点；这里是完整说明：何时、怎么发现的，游戏和 DMT 的实际行为，本模组的做法。新坑加在表尾，编号接着排，AGENTS.md 同时加一行。


| # | 说明 |
|---|------|
| 1 | mod 名称/描述的文本在 **FrontEndActions → UpdateText** 加载，否则模组列表显示 `LOC_` 原始键 |
| 2 | 外部文本 XML 只能用 `<LocalizedText><Replace Tag="…" Language="zh_Hans_CN"><Text>…</Text></Replace>`；`<Text id><en_US>` 格式只能内嵌在 modinfo，放外部文件会连累整阶段加载失败 |
| 3 | UI 用 `InGameActions → AddUserInterfaces`（`<Context>InGame</Context>` + LoadOrder）；DMT 依赖写在 `<Dependencies>` |
| 4–5 | 日志：Windows `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log`，需 Steam 启动项 `-log`；跨启动追加；先搜 `Runtime Error` |
| 6 | `include("InstanceManager")`，`InstanceManager:new("模板", "Root", 父)`（冒号），模板根控件 `ID="Root"` |
| 7 | include `dmt_yieldcalculator` 后立即 Remove 其 `DMT_Initialize()` 订阅的事件（需求文档写 3 LuaEvents + 10 Events；本机 DMT 实为 3 + 11，以源码为准，见 `Scripts/SDP_Overlay.lua`） |
| 8 | XML 非法属性 = 控件**静默**构建失败、无日志。Stack 用 `StackPadding`；`AutoSizePadding="w,h"`；一律先在 `Base/Assets/UI/` 找先例 |
| 9 | 带 String 的 GridButton 自适应撑宽；小步进按钮用 `Controls_ArrowButtonLeft/Right` 纹理 |
| 10 | 关闭钮 `<Button Style="CloseButtonSmall"/>` |
| 11 | 打开面板：`UIManager:QueuePopup(ContextPtr, PopupPriority.Low)`；关闭 `DequeuePopup`；先查 `IsInPopupQueue` |
| 12 | 跨上下文 `ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")`；注入时机 `Events.LoadScreenClose` |
| 13–15 | yield 图标只有 `ICON_YIELD_{FOOD,GOLD,PRODUCTION,SCIENCE}_1..5`；文化用 `ICON_VICTORY_CULTURE`、信仰用 `ICON_RELIGION`；`SetIcon(name)` 不带尺寸，区域图标 `SetIcon("ICON_"..dt, 32)`；结果明细用纯文本（"科+2 文+1"），悬停用 DMT tooltip |
| 16 | `TilesRequired` = 每凑满 N 个邻居给一份；线性近似会轻微高估，仅用于排序 |
| 17 | 已建区域由 DMT 从 plot 读，无需特殊处理 |
| 18 | 特色区域名额（GS）：`1 + floor((人口-1)/3)` |
| 19 | 删钉：`LuaEvents.DMT_MapPinRemoved(pin); cfg:DeleteMapPin(pin:GetID()); Network.BroadcastPlayerInfo(); UI.PlaySound("Map_Pin_Remove")` |
| 20 | 与 AMT 等规划 mod 同开会互相污染（都 hook `GetMapPinSubject`）——文档必须注明一局只开一个规划器 |
| 21 | （2026-10-19 实测）新建地图钉后，之前拿到的钉对象可能失效，再调用其方法会让游戏直接崩溃（SIGSEGV）。只保存钉 ID，每次用 `cfg:GetMapPinID(id)` 重新取（DMT 弹窗的 `GetEditPinConfig` 也是这样做的） |
| 22 | `PlayerConfiguration:GetMapPin(x, y)` 在没有钉的格子上会**新建**一个钉；只想查找时遍历 `GetMapPins()` |
| 23 | （2026-10-20 实测）上下文隐藏后 `ContextPtr:SetUpdate` **不再被调用**。弹窗出队（`DequeuePopup`）会隐藏上下文，所以关闭面板后分帧计算会停住。做法：计算进行中关闭面板时，保持上下文显示、只隐藏窗口控件（`SDP_Panel.lua` 的 `KeepRunningHidden`），算完再隐藏上下文 |
| 24 | （2026-10-20 实测）自然奇观、历史时刻等弹窗打开时会**占住游戏的事件队列**（`PopupManager:Lock` → `UI.ReferenceCurrentEvent`），UI 状态里的游戏数据（如 `PlayersVisibility`）停止更新，直到弹窗自己的 `Close` 调用 `Unlock` 释放。只 `DequeuePopup` 不会释放。测试工具关弹窗要调用该弹窗自己的 `OnClose`/`Close`（`tools/game.py popups --close` 已这样做） |
| 25 | （2026-10-20 离线对比发现）DMT 的**修正缓存**（文明/领袖特性、信仰里的相邻规则与放置规则：日本区域互邻、巴西雨林、荷兰河流、高卢"特色区域不挨市中心"、越南"特色区域只建在地貌上"）只由它的 `LoadGameViewStateDone` / `LocalPlayerTurnBegin` 处理函数建立（`InitializeModifierCalculator` + `CacheEffectiveModifiers`）。按坑 7 移除这两个处理函数的上下文必须自己建：`SDP_Overlay.RefreshModifiers`（`InitializeModifierCalculator` 只能调一次，它往表里追加） |
| 26 | （2026-10-20 离线对比发现）DMT 的 `CanPlacePin` 对区域钉**不拦奢侈、战略资源**：`GetRealizedPlotFeatures` 在评估区域钉时先把格上的资源去掉，"不能采收的资源"检查永远不触发。游戏不允许区域压在不能移除的资源上，所以候选格要自己排除（`SDP_City` 的 `RESOURCE`：可见、且 `Resource_Harvests` 里没有的资源） |
| 27 | （2026-10-20 游戏内引擎复核发现）DMT 的 `CanPlacePin` **不检查运河是否连通水域**：首都旁 13 格 DMT 判运河可放，游戏引擎（`CityManager.GetOperationTargets`）不允许。运河的合法性在引擎 C++ 里，GameInfo 读不到。已加引擎复核（`SDP_City.EngineRefused`，经 `SDP_Overlay.CanPlace` 生效），城市已拥有的格子上以引擎为准；离线对比框架的模拟引擎不给可建格，复核在那里不生效。其余区域在罗马、日本、高卢三局复核中与引擎完全一致（`tests/bench/probe_engine.lua`）。引擎只对已解锁的区域、城市已拥有的格给出可建格 |
| 28 | （2026-10-20 游戏内裁判校准发现）DMT 把水面上**任何**可见资源都算作海洋资源（`AdjacentSeaResource`），沉船（`RESOURCECLASS_ARTIFACT`）也算，引擎不算：港口挨着沉船时 DMT 比引擎多 1 金币。相邻加成按约定用 DMT，未修，列为已知问题；`tests/bench/calibrate_judge.lua` 把这种差异单独列出。另：引擎对特色区域的可建格受人口名额限制（坑 18），校准前置因此把首都人口设为 25 |
| 29 | （2026-10-20 截图时发现）透镜图层 `Hex_Coloring_Placement`（游戏放置区域时用的那层）**不管传什么颜色都画成同一种绿**，`SetLayerHexesColoredArea` 的颜色参数无效。要分色得借用别的透镜的图层；打开它会触发 `Events.LensLayerOn`，小地图（`MinimapPanel.lua` 的 `OnLensLayerOn` → `SetAppealHexes`、`SetGovernmentHexes` 等）随后往同一层填满它自己的颜色，所以收到该事件时要清掉重画自己的格（`SDP_Preview`）。（2026-10-23 合作者发现）魅力透镜的图层 `Hex_Coloring_Appeal_Level` 打开后游戏还会在每格上画出魅力数字，不是 Lua 画的、关不掉；改用政体透镜的图层 `Hex_Coloring_Government` |
| 30 | （2026-10-20 游戏内测试发现）脚本里写错或已删掉的 `Controls.<ID>` 在游戏里是 nil，**只有运行到那一行才报错**，离线的控件替身按需造控件，发现不了。`validate.py` 现在检查每个 `Controls.<ID>` 都是 UI XML 里的 ID |
| 31 | （2026-10-21 合作者实测发现）按钮里盖一层 `Size="parent,parent"` 的 GridButton（游戏页签的选中样式 `TabButtonSelected`，带 `ConsumeMouseOver="1"`），显示时会**接住鼠标**，下面的按钮点不到。游戏页签没事是因为选中的页签不用再点；需要反复点的格子用 Grid 画选中样式（`Texture="Controls_Tab" SliceStart="0,136" SliceCorner="21,16"`，即 `TabButtonSelectedGrid`）。`validate.py` 检查实例里可点击的根控件上没有这样的按钮。合成点击进不了游戏窗口，这类问题只有真人点击能发现 |
| 32 | （2026-10-21 离线对比发现）规则表的列名以 `Cache/DebugGameplay.sqlite` 为准（`sqlite3 … "pragma table_info(表名)"`），不要照印象写：`AppealHousingChanges` 的列是 `AppealChange`，不是 `AppealHousingChange`。读到 nil 只在用到那一行时才报错；离线假世界的表是照着代码写的，测不出列名错，只有用真实规则的对比框架（`tools/compare.mjs`）和游戏内会暴露 |
| 33 | （2026-10-21 压力测试发现）`AutoplayManager` 以玩家 0 身份观察（`SetObserveAsPlayer(0)`）时，AI 的外交会话（初次见面、交易）发到本地的外交界面等回答，回合停住。以观察者身份观察（`SetObserveAsPlayer(PlayerTypes.OBSERVER)`，`SetReturnAsPlayer(0)`），与游戏自带的自动化测试相同。强行关外交界面（`OnForceClose`）后游戏崩溃过一次（崩在游戏自己的网络线程，原因不明），不要这样关 |
| 34 | （2026-10-21 压力测试发现）`GameCore_Tuner` 状态里的 `Plot:GetYield` 不含建筑给别的地块的产出，连刚放的农场也不反映；界面状态（`InGame`、`SDP_Panel`）读到的才是玩家看到的产出，且要等一帧。读地块产出一律在界面状态里读。保护区古树林、避难所给周边地块的产出（`Adjacent_AppealYieldChanges`）因此曾被误判为“游戏不给”（`tests/bench/probe_preserve.py`） |
| 35 | （2026-10-21 压力测试发现）读档后加载界面停在“继续游戏”按钮，等玩家点。读档前在主菜单状态执行 `Automation.SetAutoStartEnabled(true)`，加载界面会自己按（`LoadScreen.lua` 的 `OnLoadGameViewStateDone`），与开新局相同 |
| 36 | （2026-10-21 压力测试发现）测试里用建造队列的 `CreateDistrict` 直接建出的区域，清不清格上的地貌和玩家正常放置不一样（群岛存档：玩家有采矿，直接建在树林上的商业中心，树林留在区域下面），还绕过人口名额和前置科技。校准“建区域会改变什么”要走正常流程：界面状态里 `CityManager.RequestOperation(city, CityOperationTypes.BUILD, {X, Y, DISTRICT_TYPE})` 下令，再在核心状态 `city:GetBuildQueue():FinishProgress()` 建完（`tools/stress.py check`、`tests/bench/probe_ownplot.py`）；区域不能用金币购买。界面状态里的魅力、住房读数也会滞后，一律在 `GameCore_Tuner` 里读魅力和住房，在界面状态里读地块产出（坑 34） |
| 37 | （2026-10-22 英文界面检查发现）游戏载入文本时去掉 `<Text>` 首尾的空格：英文分隔符 `"; "` 读出来是 `";"`，`" / "` 是 `"/"`。中文全角标点不受影响，所以中文界面看不出来。分隔符写进格式串（`LOC_SDP_LIST_JOIN` = `{1_A}; {2_B}`，`SDP_UI.Join`）；需要前后空格的短文本同样整句写成格式串（如 `LOC_SDP_SITES_NEW_KIND` = `{1_Name} {2_Count} (new)`） |
| 38 | （2026-10-22 实测）同一个模组 ID 装了两份（Mods 文件夹和创意工坊）时，“额外内容”里两份都列出、可以分别启用，但对局的启用列表（`GameConfiguration.GetEnabledMods()`）只记模组 ID，开局时游戏加载 `Mods.sqlite` 里先登记的那份（`ModRowId` 小），与启用的是哪一份无关：Mods 那份启用、创意工坊那份停用，对局里 `Modding.GetActiveMods()` 给出的仍是创意工坊那份（带 `SubscriptionId`）。哪份先登记取决于安装经过（`deploy.py` 改了文件后，本地那份会重新登记、排到后面），不一定是新的那份。所以只留一份；开发机上测试前确认加载的是 deploy 的那份 |
| 39 | （2026-10-22 英文界面截图时发现）游戏的 Lua 里带 `^` 锚点的 `string.gsub` 不止替换一次：`("at most"):gsub("^%l", string.upper)` 得到 `"AT most"`，次数 2。标准 Lua（离线测试的 fengari）只替换一次，所以离线测不出。要只改开头，用 `s:sub(1, 1):upper() .. s:sub(2)` 或 `find` 加 `sub` |
| 40 | （2026-10-23 合作者实测发现）城市只能扩张或购买**挨着自己领土**的格子，三环内被别的城（现有的、城址的一环，或方案里别的城的区域）隔开的格子永远拿不到。DMT 和引擎的可建格都不查这一条（引擎只对已拥有的格给结果）。候选格按“从领土能连到”筛（`SDP_City.Reach`），多城评估布局时再按其他城的区域挡路复查（`SDP_Search.Reachable`） |
| 41 | （2026-10-23 引擎审计发现，#44）风云变幻里被海平面上升**淹没的沿海低地**（`TerrainManager.GetCoastalLowlandType(plot) ~= -1` 且 `TerrainManager.IsFlooded(plot)`）不能放任何区域，引擎不给原因；DMT 的 `CanPlacePin` 不查。已拥有的格有引擎复核兜着，未拥有的格和城址的格只看 DMT，会被当成候选。v1.2.0 起 `SDP_City` 把它们排除（`FLOODED`）。城市修了防洪堤后 `IsFlooded` 立即变为假，引擎恢复可建，排除也随之取消（2026-10-23 实测） |
| 42 | （2026-10-23 引擎审计发现，#45）“需相邻某区域”的奇观（`Buildings.AdjacentDistrict`）要求那个区域**属于建奇观的城**：旁边只有别的本方城市的区域时引擎不给可建格，DMT 判可放。v1.2.0 起 `SDP_Search` 只认能拥有奇观所在格的城的区域（`Owners`），离线对比的裁判也查（`wonder_other_city`） |
| 43 | （2026-10-24 引擎探针，#51）“需相邻某改良设施”的奇观（`Buildings.AdjacentImprovement`，只有阿耳忒弥斯神庙：营地）：DMT 只看邻格有没有这种改良（已建的或改良钉），不查改良本身能不能建在那格（`CanPlacePin` 对改良是 TODO）。引擎认**别的本方城市**的营地（与坑 42 的区域不同），不认无主格上的营地。`SDP_Wonders.Support` 按规则表（`Improvement_ValidResources/Features/Terrains`，有自己改良的可见资源只认那些）找营地格，限玩家的格或参与城市能扩张到的无主格；全图与引擎 `ImprovementBuilder.CanHaveImprovement` 逐格一致（界面状态里没有这个接口，只在核心状态可用）。探针 `tests/bench/probe_camp.py` |
| 44 | （2026-10-25 游戏内实测，#58）魅力有两条规则表读不到、只在引擎里的：被**掠夺**的改良设施（`Plot:IsImprovementPillaged()`）让所在格和四周的陆地格魅力各 −1（百科“每个相邻的被掠夺单元格 -1”），区域建上去拆掉它就恢复，被掠夺的改良设施也不给住房；学了地貌的 `Features.AddCivic`（树林：自然保护）后，本方领土里从没被砍过的原生树林（`Plot:HasFeatureBeenAdded()` 为假）所在格自己 +1，清掉就没了，种下的树林没有。引擎在授予市政后不马上重算魅力，读数会陈旧（坑 34–36 同理）。`SDP_Appeal` 已计入，掠夺的 −1 是代码里的常量 `PILLAGED_APPEAL` |
| 45 | （2026-10-27 发现）部署了 modinfo `version` **比游戏里那份低**的分支（v1.5.3 发版时游戏里是 13，又部署了还停在 12 的 #125 分支）后，游戏重新登记这个模组时把它在“额外内容”里记成**停用**：`Modding.GetInstalledMods()` 里只有一条、`Enabled = false`，之后开局和读档都不加载本模组，`newgame` 等 `SDP_Panel` 状态 300 秒超时；再部署回 13 也不会自己勾回来。`Mods.sqlite` 里本模组的 `ModRowId` 是 201，别的模组都在 169 以下：每次部署改了 modinfo，游戏都把它当新条目重新登记（坑 38），版本号不降时勾选状态会跟过去（当天 12→13 的部署后测试照常），降了就没跟过去。只有一次观察，游戏的日志每次启动清空，没留下登记时的记录。做法：`deploy.py` 拒绝部署版本号更低的 modinfo（退出码 5，`--allow-downgrade` 才放行）；`game.py newgame`、`load`，`stress.py prepare`、`load`，`covscene.py` 在主菜单先查本模组是否勾上，没勾上立刻停下（退出码 3）并给出 `Modding.EnableMod(句柄, true)`，重新勾上会写 `Mods.sqlite`，要先问维护者。测一个分支前先把 `main` 并进去，版本号与 `main` 相同 |
