# #197 城邦宗主加成让覆盖范围变大

DracoYus 提：有城邦让工业区、娱乐中心的覆盖范围 +3，规划器要不要算。

## 规则（DebugGameplay.sqlite，2026-11-02 查）

- 多伦多（`MINOR_CIV_TORONTO_TRAIT`）：`MINOR_CIV_TORONTO_UNIQUE_INFLUENCE_BONUS`（`MODIFIER_ALL_PLAYERS_ATTACH_MODIFIER`，主体要求 `PLAYER_IS_SUZERAIN`）给宗主国挂上 `MINOR_CIV_TORONTO_REGIONAL_RANGE_BONUS`：`MODIFIER_PLAYER_DISTRICTS_ADJUST_EXTRA_REGIONAL_RANGE`（效果 `EFFECT_ADJUST_DISTRICT_EXTRA_REGIONAL_RANGE`，集合 `COLLECTION_PLAYER_DISTRICTS`），`Amount` 3，主体要求“区域类型是工业区或娱乐中心”（`REQUIREMENTSET_TEST_ANY`，`REQUIREMENT_DISTRICT_TYPE_MATCHES`）。定义在 Base `Modifiers.xml`，三种规则集都有。缓存库里有一次是带水上乐园的集合 `…_OR_WATER_PARK`，但风云变幻对局里实际读到的是 `DISTRICT_IS_INDUSTRIAL_ZONE_OR_ENTERTAINMENT_COMPLEX`（不含水上乐园，2026-11-02 游戏内查）；代码按对局里的规则表读，哪种都对。
- 同一效果的另一种用法：伟人尼古拉·特斯拉、约瑟夫·帕克斯顿的 `GREATPERSON_EXTRA_REGIONAL_BUILDING_RANGE`（`MODIFIER_PLAYER_DISTRICT_ADJUST_EXTRA_REGIONAL_RANGE`，集合 `COLLECTION_OWNER`）只挂在用了伟人的那一个区域上。
- 没有别的原版效果改范围；`VERTICAL_INTEGRATION_*` 改的是叠加，不是范围。

## 做法（已定）

`SDP_Coverage.ExtraRanges(playerID)`：遍历 `GameEffects.GetModifiers()`，取生效、属于本玩家、拥有者要求满足的修正（同 DMT `CacheEffectiveModifiers` 的判断），其类型在 `DynamicModifiers` 里效果是 `EFFECT_ADJUST_DISTRICT_EXTRA_REGIONAL_RANGE`、集合是 `COLLECTION_PLAYER_DISTRICTS` 的，按主体要求集算出适用的区域类型（只认“区域类型是 X”，命名基础区域时也认替代它的特色区域；有别的要求时整条不算），把 `Amount` 加上。`Reaches` 的区域范围 = 建筑最大 `RegionalRange` + 这个数，另记 `Extra`；结果汇总悬停里有加成的组用 `LOC_SDP_COVERAGE_GROUP_EXTRA` 写出范围和其中加成的格数。

- 只看现在：没当上宗主国不算，不猜以后。失去宗主国后修正应不再生效（附加修正随宗主要求解除），游戏内没验证。
- 不写死多伦多：任何给玩家全部某类区域加范围的修正（含其他模组的）都按规则表读。
- 伟人加给单个区域的不算（`COLLECTION_OWNER`）：只影响那一个已建区域已经覆盖了哪些城，要从 `GameEffects` 的对象字符串反查区域位置，没做。后果是偏保守：可能少算这个区域已经覆盖的城，建议多放一个工业区去覆盖。

## 测试

- 离线：`spec_coverage.lua` 两条（加成算入、其他玩家/失效/拥有者要求不满足/读不懂的要求/单区域的都不算、两条叠加；按 9 格计数和汇总），`spec_panel.lua` 单城页覆盖一条里加了悬停写范围。`world.lua` 的 `spec.effects` 模拟 `GameEffects`。前两条在旧代码上失败。
- 游戏内：`tests/bench/probe_regional_range.lua`（不是常规测试：设置 `tests/fixtures/suzerain_toronto.lua` 让玩家当上多伦多的宗主国，对局里没有多伦多时直接把加成的修正挂给玩家，一直有效，只在一次性对局里跑）。结果见下。

### 游戏内结果（2026-11-02，macOS，风云变幻，固定测试对局）

`run_tests.py -v tests/bench/probe_regional_range.lua`：对局里没有多伦多，设置把加成直接挂给玩家，并让玩家当上格拉纳达的宗主国。
- 多伦多加成的修正：生效，拥有者是玩家 0（`LOC_MODIFIER_OBJECT_PLAYER`）。
- 格拉纳达宗主加成附加给宗主国的 `MINOR_CIV_GRANADA_UNLOCK_ALCAZAR_BONUS`：同样生效、拥有者是玩家 0。所以真当上多伦多宗主国时，挂上的修正和测试里直接挂的是同一种形态。
- `ExtraRanges`：工业区、娱乐中心、商业同业工会、街头狂欢各 +3；工业区范围 9。水上乐园不在风云变幻的要求集里（见上），不加。
- 同一对局（加成在、范围 9）里跑 `tests/test_features.lua -k cover`：单城页那条通过；多城页那条没过：测试把城址钉放在离首都“范围到范围 +2”格（这里放到了 10 格），能同时挨着首都 3 环内、又在城址 9 格内的格只剩几个丘陵，权重 3 不足以让工业区挪过去。这是测试的几何前提在范围 9 时不成立，不是代码问题；常规测试对局里没有这个加成，不受影响。
