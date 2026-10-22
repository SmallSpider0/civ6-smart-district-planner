# 上传到 Steam 创意工坊（{{VERSION}}）

<!-- 提交包里的 UPLOAD.md 由本文件生成（tools/workshop.py pack），花括号里的字段会被填上。 -->

这一包：{{UPLOAD}}。模组版本 {{VERSION}}，modinfo 的 version 是 {{MOD_VERSION}}。中文标题和简介：{{ZH}}。物品页图片：{{IMAGES}}。

上传用上传者自己的 Steam 账号，在 Windows 或 Mac 上都行。工坊物品属于第一次上传它的那个账号，物品主人可以在物品页添加贡献者。贡献者在物品页上能改标题与描述、图片与视频、链接、所需的 DLC、必需物品和内容描述词，不能删除物品、改可见性或管理贡献者（2026-10-22 用贡献者账号看物品页得出）。贡献者用 SteamCMD 能更新内容、英文标题与简介和更新说明，不能换预览图：带预览图上传会被拒绝（Access Denied，2026-10-23 在 Mac 上试过），所以更新用的配置不带预览图，要换预览图由物品主人做。

## 包里有什么

| 文件 | 用途 |
|------|------|
| `content/` | 模组文件，`.modinfo` 在根目录。从发布的 tag 导出，和 GitHub Release 的压缩包内容相同 |
| `preview.jpg` | 预览图，1024×1024，小于 1 MB |
| `images/` | 物品页上的其他图片，按文件名顺序上传 |
| `title.txt`、`description.txt`、`changenote.txt` | 英文标题、英文简介（Steam BBCode）、这次的更新说明（英文在前、中文在后），随包上传 |
| `title_zh.txt`、`description_zh.txt` | 简体中文的标题和简介，在物品页上手动填（见“简体中文版本”） |
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

   Mac 上 SteamCMD 在 `~/steamcmd/steamcmd.sh`，命令相同：`~/steamcmd/steamcmd.sh +login 你的Steam账号 +workshop_build_item <解压的文件夹>/item.vdf +quit`。要核对上传的内容，可以用 `+workshop_download_item 289070 <物品编号>` 下载回来比对；Mac 上它和 Steam 客户端共用目录，会下载到游戏扫描的创意工坊文件夹，开发机上比对完要移走，否则游戏里会有两份（AGENTS.md 坑 38）。
5. **只在第一次上传时**：SteamCMD 会把新物品的编号写回 `item.vdf` 里的 `publishedfileid`。把这个编号填进仓库的 `workshop/item.json`，提一个 PR。以后打的包会直接更新这个物品，不会再新建。

## 方式二：Civ6 Development Tools 里的官方上传工具

内容文件夹选 `content/`，预览图选 `preview.jpg`，标题、简介、更新说明分别从 `title.txt`、`description.txt`、`changenote.txt` 复制，中文版本照下一节在物品页上填。直接上传 `content/` 里现成的文件，不要用 ModBuddy 重新生成 modinfo：有人报告过 ModBuddy 会改掉 modinfo 里的加载顺序。

## 简体中文版本

物品页的标题和简介按语言分开保存，玩家看到的是自己 Steam 语言的那一份。SteamCMD 的配置里没有分语言的字段，上传写的是默认的英文版本，中文版本要在网页上填：物品页上点“编辑标题与描述”，语言选“简体中文”，粘贴 `title_zh.txt` 和 `description_zh.txt` 的内容，保存。以后上传不会改动中文版本，所以只在中文文字改过时再填一次，本页开头写明了这次要不要。

## 第一次上传之后，在物品网页上

1. 物品现在是**私密**的。先在 Steam 里订阅它，启动游戏，确认“额外内容”里有“智能区域规划器”、能启用，进入对局后能打开面板，悬停启动栏按钮显示的是这一版的版本号。Mods 文件夹里如果还有 `SmartDistrictPlanner`，先移走：两份都在时游戏只加载其中一份，不一定是创意工坊这份。
2. 点“添加/移除必需物品”，加上 Detailed Map Tacks（2428969051）。玩家订阅时 Steam 会提示一起订阅。
3. 点“添加/编辑图片与视频”，按 `images/` 的文件名顺序上传。
4. 如果页面顶部提示要接受创意工坊法律协议，接受后物品才能公开。
5. 把可见性改成“公开”。
6. 照上一节添加简体中文版本。
7. 可选：点“添加贡献者”，加上另一位维护者。

## 以后的更新

- 每次在 GitHub 发布 Release，Release 页上会附带新的 `SmartDistrictPlanner-<版本>-workshop.zip`。等 `workshop/item.json` 填好物品编号后，包里的配置会直接更新已有物品，可见性不再改动。照方式一第 2–4 步上传即可。
- 标题和简介以仓库里的 `workshop/` 为准。英文版本每次上传都会被包里的文字覆盖；中文版本不随上传变化，中文改过时照“简体中文版本”一节在网页上更新。要改文字先改仓库，不要只在网页上改。
- 图片：本页开头写明这次要上传、删除哪几张（和上一个 tag 的图片清单比）。在“添加/编辑图片与视频”里上传新的、删掉旧的，然后点“图像排序依据：文件名”，看到图片按文件名排好（点一次有时不生效，再点一次）再点“保存并继续”。物品页上的文件名应与 `images/` 里的完全相同。
- 图片不能同名替换：Steam 记得删掉的图片的文件名，同名上传报错 29；同名上传替换旧图时图片丢了（2026-10-23）。所以图片内容变了文件名就要变：截图重拍时换名字（`v<轮次>-…`），渲染的示意图由 `workshop.py pack` 在文件名里加内容摘要（如 `01-flow-54680e.jpg`）。
