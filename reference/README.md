# reference/

本地参考源码的符号链接（已 gitignore，不随 mod 发布）。在新机器上可用以下命令重建（macOS）：

```bash
ST="$HOME/Library/Application Support/Steam/steamapps"
ln -sfn "$ST/workshop/content/289070/2428969051" reference/dmt
ln -sfn "$ST/workshop/content/289070/3771382002" reference/amt
ln -sfn "$ST/common/Sid Meier's Civilization VI/Civ6.app/Contents/Assets/Base/Assets/UI" reference/base-ui
ln -sfn "$ST/common/Sid Meier's Civilization VI/Civ6.app/Contents/Assets/DLC" reference/dlc
```

| 链接 | 内容 |
|------|------|
| `dmt/` | Detailed Map Tacks（2428969051）——必须复用的引擎 |
| `amt/` | Auto Map Tacks Planner r49（3771382002）——被改进对象，仅作参考 |
| `base-ui/` | 游戏本体 UI（`MapTacks.lua`、`InstanceManager.lua`、`Icons/` 等） |
| `dlc/` | 资料片与 DLC（`Expansion1`=R&F，`Expansion2`=GS） |

代理编写 UI/引擎调用前应先在此查找先例。
