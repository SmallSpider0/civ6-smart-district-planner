# 上传到 Steam 创意工坊（{{VERSION}}）

<!-- 提交包里的 UPLOAD.md 由本文件生成（tools/workshop.py pack），花括号里的字段会被填上。 -->

这一包：{{UPLOAD}}。模组版本 {{VERSION}}，modinfo 的 version 是 {{MOD_VERSION}}。

上传在 Windows 上手动做，用上传者自己的 Steam 账号。工坊物品属于第一次上传它的那个账号；之后可以在物品页“添加贡献者”，让另一位维护者也能更新。

## 包里有什么

| 文件 | 用途 |
|------|------|
| `content/` | 模组文件，`.modinfo` 在根目录。从发布的 tag 导出，和 GitHub Release 的压缩包内容相同 |
| `preview.jpg` | 预览图，1024×1024，小于 1 MB |
| `images/` | 物品页上的其他图片，按文件名顺序上传 |
| `title.txt`、`description.txt`、`changenote.txt` | 标题、简介（Steam BBCode，英文在前）、这次的更新说明 |
| `item.vdf.template` | SteamCMD 用的配置，两处 `__DIR__` 待填成本机路径 |

## 方式一：SteamCMD（推荐）

1. 下载 [SteamCMD for Windows](https://developer.valvesoftware.com/wiki/SteamCMD)，解压到一个文件夹，比如 `C:\steamcmd`。
2. 把这个包解压到一个只有英文字母、没有空格的路径，比如 `D:\sdp-workshop\`。
3. 生成 `item.vdf`，二选一：
   - 在仓库目录里运行：`py -3 -I tools\workshop.py vdf D:\sdp-workshop\SmartDistrictPlanner-{{VERSION}}-workshop`
   - 或者用记事本打开 `item.vdf.template`，把两处 `__DIR__` 换成解压后的文件夹，用 `/` 分隔（如 `D:/sdp-workshop/SmartDistrictPlanner-{{VERSION}}-workshop`），另存为 `item.vdf`，编码选 UTF-8。
4. 上传：

   ```bat
   C:\steamcmd\steamcmd.exe +login 你的Steam账号 +workshop_build_item D:\sdp-workshop\SmartDistrictPlanner-{{VERSION}}-workshop\item.vdf +quit
   ```

   第一次会要求输入密码和 Steam Guard 验证码。看到成功的提示后再进行下一步。
5. **只在第一次上传时**：SteamCMD 会把新物品的编号写回 `item.vdf` 里的 `publishedfileid`。把这个编号填进仓库的 `workshop/item.json`，提一个 PR。以后打的包会直接更新这个物品，不会再新建。

## 方式二：Civ6 Development Tools 里的官方上传工具

内容文件夹选 `content/`，预览图选 `preview.jpg`，标题、简介、更新说明分别从 `title.txt`、`description.txt`、`changenote.txt` 复制。直接上传 `content/` 里现成的文件，不要用 ModBuddy 重新生成 modinfo：有人报告过 ModBuddy 会改掉 modinfo 里的加载顺序。

## 第一次上传之后，在物品网页上

1. 物品现在是**私密**的。先在 Steam 里订阅它，启动游戏，确认“额外内容”里有“智能区域规划器”、能启用，进入对局后能打开面板。
2. 点“添加/删除必需物品”，加上 Detailed Map Tacks（2428969051）。玩家订阅时 Steam 会提示一起订阅。
3. 点“添加/编辑图片和视频”，按 `images/` 的文件名顺序上传。
4. 如果页面顶部提示要接受创意工坊法律协议，接受后物品才能公开。
5. 把可见性改成“公开”。
6. 可选：点“添加贡献者”，加上另一位维护者。

## 以后的更新

- 每次在 GitHub 发布 Release，Release 页上会附带新的 `SmartDistrictPlanner-<版本>-workshop.zip`。等 `workshop/item.json` 填好物品编号后，包里的配置会直接更新已有物品，可见性不再改动。照方式一第 2–4 步上传即可。
- 标题和简介以仓库里的 `workshop/` 为准，每次上传都会覆盖网页上的文字。要改文字请改仓库，不要只在网页上改。
- 图片只需要第一次上传；以后图片变了，再到网页上替换。
