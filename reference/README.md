# reference/

本地参考源码的链接（已 gitignore，不随 mod 发布，也不进仓库）。在新机器上运行：

```bash
python3 -I tools/setup_reference.py    # Windows: py -3 -I tools\setup_reference.py
```

macOS 上建符号链接，Windows 上建目录联接。位置由 `tools/paths.py` 找，找不到时见 [tools/README.md](../tools/README.md)。

| 链接 | 内容 | 谁用 |
|------|------|------|
| `dmt/` | Detailed Map Tacks（2428969051）——必须复用的引擎 | 写代码时查先例；`compare.mjs` |
| `amt/` | Auto Map Tacks Planner r49（3771382002）——被改进对象，仅作参考 | `compare.mjs` |
| `ep/` | Empire Planner（3793348626） | `compare.mjs` |
| `base-ui/` | 游戏本体 UI（`MapTacks.lua`、`InstanceManager.lua`、`Icons/` 等） | `validate.py`（UI 先例）、`compare.mjs` |
| `dlc/` | 资料片与 DLC（`Expansion1`=R&F，`Expansion2`=GS） | `validate.py` |

代理编写 UI/引擎调用前应先在此查找先例。
