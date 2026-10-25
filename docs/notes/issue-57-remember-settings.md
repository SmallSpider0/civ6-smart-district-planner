# #57 按存档记住设置（2026-10-25）

调研、跨对局保存的游戏内探针和决定都在 #57 的评论里。决定：按存档记开关、权重、档位，以及预设名加改过的项；单城页、多城页分开记；写入时不广播；区域的必建、候选、不建状态先不记。

## 存在哪、存什么

- 位置：本地玩家的 `PlayerConfiguration:SetValue`（本模组记钉的批次也存在这里，“撤销跨存档有效”已在游戏里验证过它随存档保存）。每个页签一个键：`SDP_Settings_SINGLE`、`SDP_Settings_SITES`、`SDP_Settings_MULTI`。选城址页也记（它有自己的预设、权重和档位），三个页签互不影响。
- 内容：版本、预设名，加上和预设不同的项，如 `v1;preset=BALANCED;LAND=0;TIER=FINE;YIELD_GOLD=2`。只记改动：以后某个版本调了预设或默认值，玩家没动过的项跟着新值走，动过的保留。
- 项：
  - 单城页：权重行 8 列（`YIELD_*`、`DISTANCE`、`HOUSING`、`COVERAGE`），开关 `ALLOW_REMOVAL`、`LAND`、`SWAP`、`REPLACE`、`REMIND`、`APART`，`TIER`；
  - 多城页：同样的权重列，开关少 `ALLOW_REMOVAL`（多城页没有这个开关），`TIER`；
  - 选城址页：12 个权重，`TIER`，预设名用它自己的三个（均衡、成长优先、区域优先）。
- 不广播：只调 `SetValue`，不调 `Network.BroadcastPlayerInfo`。别的玩家用不到规划器的设置（Empire Planner 也这样做）；知乎有人提醒频繁广播会拖慢多人同步。热座各玩家各记各的：按 `Game.GetLocalPlayer()` 读写。

## 读回

- 读档后，加载界面关闭时（`Events.LoadScreenClose`）读一次；面板第一次刷新时再检查一次（热座换了玩家时读那位玩家的）。读之前的改动不写，免得盖掉存档里的值。
- 逐项校验（参照 Empire Planner 的 `LoadSettings`）：不认识的预设名用默认预设；不认识的项、超出 0–3 的权重、不是 0/1 的开关、不存在的档位都丢掉，用默认值；版本不是 `v1` 时整段不用。读不到就是默认。
- 写入：每次改动后立刻写（值与上次写的相同时不写）。

## 代码

| 位置 | 内容 |
|---|---|
| `Scripts/SDP_Settings.lua` | `Encode`、`Decode`、`Load`、`Save`、`Changed`（预设是否被改过，给 #49 的“（已改）”用）、`Keeper`；`PRESETS`、`PRESET_ORDER`（#49 填） |
| `SDP_UI.SettingFields`、`SDP_UI.Keeper`（`SDP_Panel.lua`） | 按页签的权重列、开关和档位生成要记的项 |
| 三个页签 | 每个改设置的函数改动后调 `Remember()`；`Refresh` 和加载界面关闭时 `Restore()` |

## 测试

- 离线：`spec_settings.lua`。编码只写改动；解码校验坏值；模拟读档（面板脚本运行前在配置里放好三个页签的值）后各页签的值和控件显示；经控件回调改动后立刻写入、回到默认的项不写、页签各写各的键、没有广播。
- 游戏内：`test_settings.lua` 在游戏的 `PlayerConfiguration` 上写入、读回。
