# #107 原版规则集里的港口、商业中心分城（2026-10-26）

原版规则集里面板上不出现“港口、商业中心分城”开关，规划器可能在同一座城挑港口和商业中心。#106 调研时发现（调研记录 `docs/notes/issue-106-harbor-commercial-hub.md` 第 8 节，在分支 `mac/harbor-research` 上）。

## 原因

`SDP_Rules.Apart` 只在 `BuildingModifiers` 里找“本城没有某物时才加贸易路线”的修正。三种规则集的写法不同：

| 规则集 | 规则在哪 | 内容 |
|---|---|---|
| 原版 | `Base/Assets/Gameplay/Data/Districts.xml` 的 `DistrictModifiers` | 商业中心 +1（无条件）；港口 +1，要求本城没有商业中心（`REQUIRES_NO_COMMERCIAL_HUB`：取反的 `REQUIREMENT_CITY_HAS_DISTRICT`，参数 `DistrictType` = `DISTRICT_COMMERCIAL_HUB`）；皇家海军船坞 +1（无条件） |
| 迭起兴衰 | `DLC/Expansion1/Data/Expansion1_Buildings.xml` 的 `BuildingModifiers` | 市场 +1（无条件）；灯塔 +1，要求本城没有市场（`REQUIRES_NO_MARKET`）。`Expansion1_RemoveData.xml` 删掉原版那三条区域修正 |
| 风云变幻 | 同迭起兴衰（`DLC/Expansion2/Data/Expansion1_Buildings.xml`，`Expansion2_RemoveData.xml` 同样删掉区域修正） | 本机 `Cache/DebugGameplay.sqlite`（风云变幻）查得：区域上没有贸易路线容量修正；建筑上只有市场、纺织会馆（波兰，替代市场）、灯塔（要求没有市场）和两座奇观 |

原版里特色港口只有英国皇家海军船坞（U型港、曼丁哥市场随风云变幻才有）。它的贸易路线是自己那条无条件的修正，不是港口那条：特色区域看来不继承所替代区域的 `DistrictModifiers`（罗马的浴场有自己的 `BATH_ADDAMENITIES`，与水渠的 `AQUEDUCT_ADDAMENITIES` 并列，可见要逐个写）。所以原版的英国同城建船坞和商业中心照样多 2 条，不该分城。本机规则库里没有其他 DLC 给港口或商业中心的特色区域加贸易路线修正（`grep TRADE_ROUTE_CAPACITY` 遍历 `DLC/*/Data`）。

## 改动

- `SDP_Rules.Apart` 同时读 `BuildingModifiers` 和 `DistrictModifiers`，条件认取反的 `REQUIREMENT_CITY_HAS_BUILDING` 和 `REQUIREMENT_CITY_HAS_DISTRICT`（参数 `BuildingType` 或 `DistrictType`）。不写区域名。
- 每一对多带 `Types`：规则对哪些区域类型成立。建筑上的规则对它所在区域的全部类型（特色港口里也有灯塔），区域上的规则只对写着它的那个类型。`Partners` 和 `Together` 只认 `Types` 里的类型，所以原版的皇家海军船坞不和商业中心配对。
- 原版这一对的 `Building`、`Other` 是区域（`DISTRICT_HARBOR`、`DISTRICT_COMMERCIAL_HUB`），提示读作“港口只在本城没有商业中心时加贸易路线”，结果行读作“港口不增加贸易路线”。
- `SDP_Rules.ApartFor(玩家)`：只留玩家能建的区域受影响的那几对。开关按它显示，原版的英国（建不了普通港口）不显示开关。

## 测试

- 离线：假世界加 `baseTradeRoutes`（原版的区域修正形状，U型港代替皇家海军船坞带一条无条件的路线）；`spec_apart.lua` 加 2 项（读出这一对、特色港口不配对、`ApartFor`；单城开关开时不同城挑、特色港口不受限）。改代码前这 2 项失败（读出 0 对），改后通过。
- 游戏内：`tests/test_feedback2.lua` 原来断言原版“没有这一对”，改为原版有港口（区域）对商业中心（区域）一对、皇家海军船坞不配对；开关测试按 `ApartFor` 判断。原版对局里的核对排在夜间队列。
