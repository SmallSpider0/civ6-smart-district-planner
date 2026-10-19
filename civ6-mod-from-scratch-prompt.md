# 从零开发：文明6 区域规划 Mod — 完整提示词

> 用途：将本文整段投喂给 AI 模型，让它**从零开始**实现这个 mod。
> 需求与约束已由用户确认锁定；实现方案由你（接手模型）自行设计。
> 文末附有"前人踩坑清单"——这些是用真实游戏验证换来的教训，必须遵守。

---

## 一、你要做什么

为《文明6》（Sid Meier's Civilization VI，玩家使用含风云际会/GS 的完整版本）开发一个 **Lua UI Mod：智能区域规划器（Smart District Planner）**。

**用户痛点**：现有创意工坊 mod「Auto Map Tacks Planner r49」（Steam id=3771382002，本地 `steamapps/workshop/content/289070/3771382002`）能自动规划区域但有 bug——多城规划时方案与玩家预想不符、全局唯一区域（市政广场/外交区）乱放、结果有时不是最优。用户要一个**更正确、更透明、结果可复现**的新 mod。

**核心功能**：玩家在游戏内打开规划面板 → 选择城市、勾选想建的区域（如学院、圣地）、调节各产出类型的权重 → mod 穷举求解城市 3 环内所有合法摆放组合 → 给出相邻加成最大的方案 → 一键打成地图钉供玩家照着建造。

**当前目标范围（MVP）**：单城规划。多城联合、奇观求解是后续阶段，本期**不需要**实现，但架构上不要堵死。

---

## 二、需求约束（用户已确认，不可更改）

1. **纯 Lua UI Mod**，不碰 C++/DLL；
2. **相邻规则全部从游戏数据库动态读取**（GameInfo 表），禁止硬编码任何文明/区域规则——这样新文明和自定义 mod 自动兼容；
3. **目标函数 = 分类型加权收益**：科学/文化/信仰/金币/生产力分开计分，权重玩家可调（0–3，默认全 1）；
4. 政策卡翻倍（如自然哲学）**不计入**目标函数；
5. 区域占用需砍树/雨林/沼泽时默认允许（面板提供开关可禁止）；
6. **求解算法必须确定性**：无随机数、固定遍历顺序，同输入必同输出；
7. 已有地图钉 = 硬约束：求解器永不挪动玩家的图钉，只把它们当固定邻居参与计算；
8. 结果呈现为**带区域图标的规划图钉**；结果列表悬停显示**逐项加成来源明细**（如"山脉+1、相邻区域+0.5"），用于和游戏实际数值对照排错；
9. 兼容原版/R&F/GS 规则集（运行时检测，如运河/堤坝仅 GS 存在）；
10. 界面为中文（提供 en_US + zh_Hans_CN 双语文本）。

---

## 三、关键技术事实（你的方案必须建立在这些之上）

### 1. 复用 Detailed Map Tacks (DMT) 引擎

DMT（Steam id=2428969051，本地 `steamapps/workshop/content/289070/2428969051`）是"图钉数值显示"mod，内部有权威的**区域摆放合法性判定**和**相邻加成计算**（含文明特色 Modifier 解析）。你的 mod 必须复用它而不是重写这两块——重写必然遗漏规则（这正是原 mod 的老路），且无法与游戏内 DMT 图钉数值保持一致。

```lua
include("MapTacks");                  -- MapTacks.PlayerTraits / MapTacks.PlayerDistricts（区域列表）
include("dmt_mappinsubjectmanager");  -- 图钉 subject 缓存管理
include("dmt_yieldcalculator");       -- 收益计算 + 合法性判定
```

核心 API：
- `CanPlacePin(playerID, pinSubject)` → 合法性（地形/3环/已有区域/城中心距离等）；
- `GetBonusYields(playerID, pinSubject)` → `yields` 表（key 为 `YIELD_SCIENCE` 等）+ `tooltip` 明细文本；
- `GetMapPinSubject(playerID, x, y)` → 某格当前钉状态；**这是仿真叠加的挂钩点**；
- `UpdatePinYields(playerID, pinsToUpdate)` → 清特征缓存 + 重算 pins；**传空表 `{}` = 只清缓存**；
- subject 结构：`{ Key = "DISTRICT_CAMPUS", Type = "DISTRICT", X = x, Y = y }`；
- 引擎图钉 API：`PlayerConfigurations[pid]:GetMapPin(x,y)`（空格自动建钉）、`:GetMapPins()`、`:DeleteMapPin(pinID)`。

**仿真叠加**（评估假想摆放的核心技术，AMT 同款）：临时替换全局 `GetMapPinSubject`，让假想 subject 对 DMT 引擎可见；评估完恢复。

### 2. 两个致命机制（不懂必翻车）

- **DMT 按坐标缓存邻格特征**。模拟叠加安装后、恢复后、以及同一叠加内每次改动布局后，都必须执行 `pcall(UpdatePinYields, playerID, {})` 清空特征缓存——否则所有模拟评估读到陈旧的真实地图状态，分数系统性失真，求解器给出次优解。同时要把 `UpdateMapPinSubject` 一并重定向进 overlay（写入用 `subject or false` 占位、读取时 `false` 转 `nil`），防止 DMT 内部写穿透污染真实状态。
- **联合评估必须包含锁定图钉**。新钉会给旧钉提供互惠相邻加成；总分若只算新钉，与基线相减会出现"-37"之类的荒谬值。正确公式：联合总分 = Σ(overlay 中全部 subject 的分)，提升 = 联合总分 − 锁定钉基线分。

### 3. 性能边界

3 环内最多 19 格；2 区域全组合 19²=361、3 区域 14³≈2700、4 区域 9⁴≈6561。**每个组合都做一次 DMT 全量评估（每次清缓存全量重算）会卡死游戏主线程**。可行方案（已验证）：先用线性查表模型（区域互惠加成从 `District_Adjacencies` → `Adjacency_YieldChanges` 表预计算，组合分 = Σ独立分 + Σ相邻对互惠 + Σ锁定钉增量）给全部组合**毫秒级排序**，再只对 top~100 做 DMT 精确评估；最后用"逐区域尝试全部合法格、其他固定、迭代到无改进"的局部搜索兜底短名单截断问题。也可自行设计等效方案，但必须保证不假死且结果不劣于该方案。

---

## 四、Civ6 Modding 硬坑清单（前人真实踩过，违反必出错）

### 打包与文本
1. mod 的名称/描述必须在 **FrontEndActions → UpdateText** 加载，否则模组列表显示 `LOC_XXX` 原始键；
2. 外部文本文件只能用数据库格式 `<LocalizedText><Replace Tag="LOC_X" Language="zh_Hans_CN"><Text>…</Text></Replace>`；`<Text id="…"><en_US>…` 是 modinfo 内嵌专用格式，放外部文件会导致整个文件解析失败并**连累同阶段所有加载**；语言标签大小写敏感（`<en_US>`）；`zh_Hans_CN` 简中、`en_US` 英文；
3. modinfo 用 `InGameActions → AddUserInterfaces`（`<Context>InGame</Context>` + LoadOrder）注册 UI 上下文；DMT 依赖写 `<Dependencies><Mod id="4ecfcc62-5471-4435-b295-590df213e8d8" /></Dependencies>`。

### 日志与调试
4. **日志不在 Documents**，在 `C:\Users\<用户>\AppData\Local\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log`；需 Steam 启动项 `-log` 才生成；日志跨启动追加；
5. 显示异常先查 Lua.log 的 `Runtime Error`（带文件+行号）；XML 控件构建失败**不写日志**（见第 8 条）。

### Lua 运行时
6. `InstanceManager` 是普通 Lua 库（`Base/Assets/UI/InstanceManager.lua`）非引擎内置：必须 `include("InstanceManager")`、**冒号调用** `InstanceManager:new("模板名", "Root", 父容器)`，实例模板根控件必须 `ID="Root"`；
7. `include("dmt_yieldcalculator")` 会在本上下文执行其尾部 `DMT_Initialize()`，自动订阅 13 个图钉更新事件（3 个 LuaEvents + 10 个引擎 Events）——纯计算用途的上下文应在 include 后立即 Remove 这些重复订阅，否则每次钉变化全链路双执行，且与其他规划 mod 同开时互相污染。

### UI XML（非法属性 = 控件静默构建失败，无日志）
8. 属性必须对照游戏本体写法（`Base/Assets/UI/`）：Stack 用 `StackPadding`（不是 `Padding`/`InternalPadding`）；`AutoSizePadding` 要 "宽,高" 双值；
9. **带 String 的 GridButton 会自适应撑宽**（固定 Size 不生效）；带 Image 子控件的按钮按 Size 渲染。小步进按钮用箭头纹理 `Controls_ArrowButtonLeft/Right`；
10. 标准窗口关闭钮：`<Button Style="CloseButtonSmall"/>`；
11. **AddUserInterfaces 的上下文默认压在渲染栈底部**，仅 `SetHide(false)` 不可见——打开面板必须 `UIManager:QueuePopup(ContextPtr, PopupPriority.Low)`，关闭 `DequeuePopup`（先查 `IsInPopupQueue` 防重复）；
12. 跨上下文取控件：`ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")`；启动栏注入时机用 `Events.LoadScreenClose`。

### 图标
13. **yield 图标的无后缀名不存在**：只有 `ICON_YIELD_{FOOD,GOLD,PRODUCTION,SCIENCE}_1.._5`（Base `UI/Icons/Icons_Yields.xml`）；**文化和信仰没有任何 yield 图标**。未注册名 `SetIcon` → 空白；未注册名 BB code `[ICON_X]` → 显示原文；
14. 可靠做法：`inst.Icon:SetIcon(iconName)`（**不带尺寸参数**）；区域图标 `SetIcon("ICON_"..dt, 32)` 正常；文化可用 `ICON_VICTORY_CULTURE`、信仰可用 `ICON_RELIGION` 替代；
15. 文本中的 yield 图标 BB code 路线**不可靠**——结果明细用纯文本（如"科+2 文+1"），悬停明细直接用 DMT 返回的 tooltip。

### 数据
16. 区域互惠加成表：`District_Adjacencies(DistrictType, YieldChangeId)` → `Adjacency_YieldChanges(ID, YieldType, YieldChange, OtherDistrictAdjacent, TilesRequired,…)`；注意 `TilesRequired` 语义（每凑满 N 个邻居给一份），线性近似会有轻微高估，排序用途可接受、精评兜底；
17. 已建区域自动计入邻居特征（DMT 直接从 plot 读），无需特殊处理；
18. 特色区域名额上限公式（GS）：`1 + floor((人口-1)/3)`；
19. 撤销/删除图钉（DMT 右键删除同款）：`LuaEvents.DMT_MapPinRemoved(pin); cfg:DeleteMapPin(pin:GetID()); Network.BroadcastPlayerInfo(); UI.PlaySound("Map_Pin_Remove")`；
20. **与其他规划 mod（如 AMT）同开会互相污染**（都 hook `GetMapPinSubject` 做模拟）——文档中注明一局只开一个规划器。

---

## 五、验收标准（交付前自测清单）

1. 模组列表正确显示中文名与描述；
2. 进对局后启动栏出现图标按钮，点击弹出规划面板；
3. 勾选 2 个区域（如学院+圣地）求解：**秒级出结果**；当存在"两区域相邻互惠更优"的摆放时，求解结果必须是该更优解（这是对原 mod 的核心改进点）；
4. 结果行显示坐标与加成明细，悬停有逐项来源，数值与 DMT 图钉一致（同一套引擎，天然一致）；
5. 打图钉后在地图上生成带区域图标的钉；撤销后新钉被真删除（不是变成默认钉）；
6. 已建区域在列表中置灰且不可勾选；
7. 全程确定性：同一状态求解两次结果一致；
8. 勾 3–4 个区域求解不卡死游戏（主线程停顿 ≤2 秒左右）。

---

## 六、交付物

1. 完整 mod 目录（modinfo + 文本 XML + UI XML + Lua），可直接复制到 `文档\My Games\Sid Meier's Civilization VI\Mods\` 运行；
2. 安装与测试说明（含"与 AMT 不可同开"的警告）；
3. 简短的设计说明：求解算法结构、目标函数定义、与 DMT 的接缝。

## 工作方式提示

- 所有 UI/引擎写法先在游戏本体 `Base/Assets/UI/` 找先例再写；DMT（2428969051）与 AMT（3771382002）的源码在本机可读，是高级用法参考；
- 每轮改动：校验 XML（任一 XML 解析器）与 Lua 语法（luaparse，luaVersion 5.3）→ 复制到游戏 Mods 目录 → 回主菜单重读档（UI 上下文进局时重载；改 modinfo/文本需重启游戏）→ 用 Lua.log 定位报错；
- 需求约束（第二节）优先于一切；本文第四节坑清单与第三节机制约束是硬性的，其余实现细节（面板布局、算法细节、求解策略）由你自行设计。
