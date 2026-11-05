# Smart District Planner 智能区域规划器

**[English](#english)** · **[中文](#中文)**

<p>
<img src="workshop/images/01-multi.jpg" width="49%" alt="Several cities planned together: +19 one city at a time, +29 together / 几座城一起规划"> <img src="workshop/images/02-plan.jpg" width="49%" alt="One city: the plan previewed on the map / 单城方案在地图上预览">
<img src="workshop/images/03-wonders.jpg" width="49%" alt="Wonders planned with districts, a drawn diagram / 奇观和区域一起规划（示意图）"> <img src="workshop/images/04-sites.jpg" width="49%" alt="City sites and their tooltip / 选城址与悬停提示">
<img src="workshop/images/05-reminders.jpg" width="49%" alt="Reminder tacks for woods to keep / 勿砍提醒钉"> <img src="workshop/images/06-panel.jpg" width="49%" alt="The panel's three tabs in English and Chinese / 面板三个页签，中英文界面">
</p>

## English

Smart District Planner is a Civilization VI mod. Pick a city and the districts you want, and within a few seconds it finds the layout with the highest adjacency bonus in the city's 3 rings and places it as map tacks with district icons. It can also choose sites for new cities and plan several cities together.

It needs [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051) (DMT), which decides where a district fits and what it gets, so the numbers in a plan match the numbers on the tacks.

**[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3824473635)** · **[Download](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/latest)** · **[Overview](https://smallspider0.github.io/civ6-smart-district-planner/en/)** · **[Install and use](docs/install-en.md)**

### Why use it

- It follows your civilization's rules with no setup: adjacency and placement rules from your civilization, leader, pantheon and beliefs are counted, and your unique districts are used. For example, Japan's districts get +1 from each other, and Vietnam's specialty districts go only on Woods, Rainforest or Marsh.
- With few districts it tries every layout, so the plan is the best one. With more, it says at most how far from the best the plan may be, and **Improve** keeps searching. Of 17 city layouts that strong players shared with their saves on CivFanatics, it finds the best possible one in 16, counting adjacency only ([each scene](docs/reference-scenes.md), in Chinese).
- It never plans a district where you cannot build it, and never moves what you have. Luxury and strategic resources stay uncovered, empire limits and city borders are checked, and on tiles a city owns the game's own list of valid tiles is checked too. Built districts and your own tacks stay where they are and count as neighbors.

The panel has three tabs:

- **One city**: set the districts you must have to Must, leave the rest in the Pool, and say how many districts the city should end up with. **Solve** gives three plans with different districts; click one to preview it on the map, then **Place tacks**. **Undo tacks** works too, also after loading a save.
- **City sites**: chooses spots for new cities on the explored map. Each site is scored on district potential, tiles, resources and Housing; hover a score for the yields behind it. **Dense packing** puts new cities as close together as allowed. Each site has a tick box, and only the ticked sites get a tack.
- **Several cities**: plans the city selected on the map with the nearest cities and site tacks (4 by default); **All cities** selects every city and site tack, and above 8 they are planned in groups of up to 4 neighbouring cities, taken in turns. Districts share adjacency across cities, and a district limited to one per empire, like the Government Plaza, goes to the city where it does the most. Each city can have its own district list; **Apply a template** fills one for Science, Production or another yield from your civilization's rules.

Also:

- Wonders are planned with the districts: the Colosseum gets an Entertainment Complex next to it when the city has none, and the Temple of Artemis comes with its Camp.
- Tiles you can swap from your other cities are used too (on by default, can be turned off), which gives more adjacency; such a district needs a Swap in Manage Citizens, and the result marks it.
- Lean toward a yield with the Science, Culture or Religion preset, or set each weight yourself.
- Districts stay off tiles that would make good farms or mines unless the bonus is worth it.
- Improvements that give districts adjacency (such as Mines and Quarries next to an Industrial Zone, and those your civilization's abilities count) are planned with the districts and tacked with them; districts go where those can be built (on by default). With "Worked tiles" on, the tiles the city will work also get improvement tacks.
- Neighborhoods go where Appeal gives the most Housing. An Aqueduct is added when a city lacks fresh water, a Dam when it has enough Floodplains.
- When a plan relies on nearby Woods or Rainforest, a "Don't chop" tack on those tiles says what chopping would cost.
- **Good places**: pick a district and the map colors every tile it can go on by its bonus.
- To plan again, turn on "Replace this mod's earlier tacks": the old tacks are replaced, and Undo tacks puts them back.
- Long searches run over several frames, so you can keep playing or close the panel. <kbd>Shift</kbd>+<kbd>L</kbd> opens the panel. Settings are kept in the save.
- Base game, Rise and Fall, and Gathering Storm; the panel is in English and Chinese and follows the game's language.

How close its plans come to the best, its speed and known limitations: see the [overview](https://smallspider0.github.io/civ6-smart-district-planner/en/).

Use one planner per game; how it works with other mods: [Using it with other mods](#using-it-with-other-mods).

### Install

1. Subscribe to [Smart District Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3824473635) and [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051) on the Steam Workshop.
2. In the main menu's Additional Content, enable Detailed Map Tacks and Smart District Planner, then restart the game.

Without the Workshop, download the zip from the [releases page](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/latest) and put the `SmartDistrictPlanner` folder in it into the game's Mods folder (DMT is still needed):
- Windows: `Documents\My Games\Sid Meier's Civilization VI\Mods\`
- macOS: `~/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/`

Keep only one copy: with one in Mods and one from the Workshop, the game loads only one of them, not necessarily the newer one or the one you enabled. When you switch to the Workshop, delete that folder from Mods.

How to use each tab, known limitations and troubleshooting: [install and use](docs/install-en.md). Report problems on [Issues](https://github.com/SmallSpider0/civ6-smart-district-planner/issues), in English or Chinese. Each [release](https://github.com/SmallSpider0/civ6-smart-district-planner/releases) lists its changes in English and Chinese; the [CHANGELOG](CHANGELOG.md) is in Chinese.

### Using it with other mods

Checked on 2026-11-05.

Most mods that add civilizations, districts or wonders, or change adjacency bonuses, work with it: plans follow their rules. Interface mods (CQUI, Better Report Screen, More Lenses and others) usually don't conflict either. Tested in the game: Civ6 Plus: Harmony in Diversity v2.2.

Good to know:

- **Modular Adjacency Bonuses (and mods built on it)**: the adjacency bonuses it adds are not counted in plans, now or later, so the built districts yield more than the panel shows. That mod works out these bonuses only after a district is built, at the next turn, while this mod takes every bonus from Detailed Map Tacks (the same numbers the map tacks show), which can't see them.
- **A few special leader and wonder bonuses in Harmony in Diversity** (such as Wu Zetian's "+2 for districts next to a wonder"): not counted either, now or later. Detailed Map Tacks doesn't read these bonuses, and this mod doesn't add a calculation of its own, so the panel and the map tacks always show the same numbers.
- **Reach with Harmony in Diversity**: it computes the regional effects of buildings itself; Reach still uses the ranges in the game's rules, so the regional effects it adds to buildings are not counted.
- **Workable 4th Ring**: this mod plans only within three rings of a city; place 4th-ring districts yourself.

Don't use together:

- **Auto Map Tacks Planner, Empire Planner, District & Wonder Planner**: planners change or delete each other's map tacks. Use one per game.

If a mod not listed here gives wrong numbers, please open an [issue](https://github.com/SmallSpider0/civ6-smart-district-planner/issues) or leave a comment on the Workshop page.

### Similar mods

| | [Auto Map Tacks Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3771382002) | [Empire Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3793348626) | [District & Wonder Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3780936549) | This mod |
|---|---|---|---|---|
| Districts | ✓ | ✓ | ✓ up to 3 kinds at a time (plus Aqueduct and Government Plaza) | ✓ |
| Wonders | ✓ | ✓ | ✓ up to 5 | ✓ |
| Improvements | ✓ unique improvements included | ✓ | ◐ only the one a wonder needs | ◐ those that give districts adjacency, the Camp a wonder needs, optionally the tiles the city will work; no unique improvements |
| New city sites | — future cities from your City Center tacks | ✓ 0–6 | — future cities from your City Center tacks | ✓ 1–6, up to 12 with dense packing |
| Cities planned together | ✓ up to 4 | ✓ every existing city and the new sites, in one go | ✓ all cities, with a tick | ✓ every city and site tack, in groups taken in turns above 8 |
| Places map tacks | ✓ | ✓ | ✓ | ✓ |
| Needs DMT | ✓ | — the author advises turning DMT off | ✓ | ✓ |
| Bonuses computed by | DMT | its own rules | DMT | DMT |
| Rulesets | not stated | Rise and Fall, Gathering Storm (the author says the base game is untested) | not stated | Base game, Rise and Fall, Gathering Storm |
| Interface languages | English, Simplified Chinese, Traditional Chinese | English | English, Simplified Chinese | English, Simplified Chinese |
| Not to be enabled with (as the author states) | not stated | DMT | not stated | other district planners |
| Updated on the Workshop | 2026-09-19 (r49) | 2026-09-10 | 2026-08-29 (v1.1) | 2026-10-25 |

✓ yes · ◐ partly · — no

Checked on 2026-10-26 against each mod's Workshop page and files; "not stated" means neither says. The Workshop titles are Fully Automatic Map Tacks Planner【Four-City Linked】, Empire Planner + (Auto Map Tacks) Advanced and District & Wonder Planner v1.1; they are updated over time, so their own pages are the reference.

Features not in the table:

- **Auto Map Tacks Planner**: takes your "Remove Feature / Harvest Resource / Plant Woods" tacks as instructions; two modes, "only what is unlocked" and "long-term blueprint".
- **Empire Planner**: limits the plan to an era; keeps 3 layouts in the save.
- **District & Wonder Planner**: weights districts by their order.
- **This mod**: tells you when a plan is the best possible, or at most how far from it it may be.

Detailed Map Tacks is not a planner: it shows on a map tack the yields and adjacency a district or wonder would get there.

### Development

The development documents are in Chinese; issues and pull requests in English are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), in English and Chinese: the hard constraints, setup, the checks you can run with and without the game, code conventions and how to submit a pull request. [AGENTS.md](AGENTS.md) has the requirements, design constraints, modding pitfalls and workflow.

| Document | Contents |
|------|------|
| [docs/dev-macos.md](docs/dev-macos.md), [docs/dev-windows.md](docs/dev-windows.md) | The development setup on each platform |
| [tools/README.md](tools/README.md) | Tools: validation, deployment, in-game tests, the offline comparison |
| [docs/workflow.html](docs/workflow.html) | Development workflow overview (in Chinese), also published with each release: [web page](https://smallspider0.github.io/civ6-smart-district-planner/workflow/) |
| [docs/workshop-upload.md](docs/workshop-upload.md) | Uploading the package to the Steam Workshop (Windows) |
| [docs/design.md](docs/design.md) | The solver, the objective, the seam with DMT, the modules |
| [docs/multicity-design.md](docs/multicity-design.md) | City sites, several cities, wonders, effort levels, offline benchmarks, and the changes made after each round of hands-on testing |
| [docs/self-test-report.md](docs/self-test-report.md) | Self-test report: evidence for each acceptance item, test results, screenshots |
| [civ6-mod-from-scratch-prompt.md](civ6-mod-from-scratch-prompt.md) | The requirements |

### Acknowledgements

- [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051) (D, wltk): every placement check and adjacency bonus in this mod is computed by it, and it shows the numbers on the map tacks.
- [Auto Map Tacks Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3771382002): these ideas come from it: the wonder dropdown sorted by era, then by cost; the "Good places" coloring; per-city lists and templates by yield on the Several cities tab; an empire-limited district going only to the cities whose list has it; coverage; undo records kept with the save; replacing this mod's earlier tacks; the Shift+L hotkey.
- [Empire Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3793348626): checking plans on the tiles a city owns against the tiles the game engine allows comes from it.

### License

[MIT](LICENSE). This repository contains no code or data of Detailed Map Tacks, other mods or the game; players subscribe to DMT themselves.

---

## 中文

智能区域规划器是《文明6》的模组。选一座城和想建的区域，几秒内在城市三环内找出相邻加成最高的摆法，打成带区域图标的地图钉。也能给新城选址，让几座城一起规划。

需要同时订阅 [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051)（DMT）。区域能不能放、加成多少都由它算，所以规划里的数和钉上显示的一样。

**[创意工坊](https://steamcommunity.com/sharedfiles/filedetails/?id=3824473635)** · **[下载](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/latest)** · **[介绍页](https://smallspider0.github.io/civ6-smart-district-planner/)** · **[安装与使用](docs/install-and-test.md)**

### 为什么用它

- 你的文明、领袖、万神殿和宗教信条带来的相邻加成和放置限制都会算进去，特色区域也会自动换上，不用设置。比如日本的区域互相挨着各 +1，越南的特色区域只能建在森林、雨林、沼泽上。
- 区域少时它把所有摆法都试一遍，给出的就是最优；区域多时，结果写明离最优最多还差百分之几，可以点“继续优化”接着算。CivFanatics 上高手附存档分享的 17 个城市布局里，16 个它摆得和最优一样（只算相邻加成，[逐个场景的图](docs/reference-scenes.md)）。
- 不给你建不了的位置，也不动你已有的：不压奢侈和战略资源，查帝国上限和城市范围，城市已有的格再用游戏自己的可建格核对一遍；已建的区域和你自己打的钉留在原处，当作邻居算加成。

面板有三个页签：

- **单城**：把想要的区域点成“必建”，其余留作“候选”，说这座城一共要几个区域。点“求解”得到三套组合不同的方案，点一套在地图上预览，满意就“打钉”；可以“撤销”，读档后也能撤销。
- **选城址**：在已探索的地图上给新城选位置。每个城址按区域潜力、地块、资源、住房打分，悬停看每项背后是多少产出；打开“密铺”让新城尽量挨着放。每个城址有勾选框，只给勾选的打钉。
- **多城**：以地图上选中的城为中心，和离它最近的城市、城址钉（默认 4 座）一起规划；“全部城市”把全部城市和城址钉都选上，超过 8 座时按位置分成每组至多 4 座相邻的城轮流规划。区域可以跨城互相给加成，市政广场这类全帝国只有一个的区域会放到最合适的那座城。每座城可以有自己的区域清单；“套用模板”按你文明的规则，为科技、生产力等产出一键生成区域清单。

还能做什么：

- 选上想建的奇观，它连同区域一起规划：罗马斗兽场要挨着娱乐中心，城里没有就补一个；阿耳忒弥斯神庙会带上它要的营地。
- 本方其他城能换过来的格也会用上（默认打开，可关），相邻加成更高；这些区域要在“市民管理”里点“切换”把格换过来，结果里会标出来。
- 偏向某种产出：选“科技”“文化”“宗教”预设，或自己调各项权重。
- 不乱占好地：区域尽量不压能修出好改良的格。
- 能给区域相邻加成的改良设施（如工业区旁的矿山、采石场，以及文明特性认的改良）和区域一起规划、一起打钉，区域会挑能建这些改良的位置（默认打开）；打开“耕作格改良”时，城市要耕作的地块也打改良钉。
- 社区放在魅力高的地方，多给住房；缺淡水时自动加水渠，泛滥平原多时自动加堤坝。
- 方案靠旁边的森林、雨林拿加成时，在那些格上打“勿砍”提醒钉，写明砍掉会少多少。
- “好位置”：选一个区域，地图上给它能放的格按加成高低上色。
- 想重新规划：打开“替换本模组之前打的钉”，旧钉换成新的，撤销时放回。
- 算得久时分几帧算，游戏照常操作，关掉面板也会算完。<kbd>Shift</kbd>+<kbd>L</kbd> 打开面板。设置随存档保存。
- 原版、迭起兴衰、风云变幻都能用；界面中英双语，跟随游戏语言。

方案离最优多远、速度和已知限制，见[介绍页](https://smallspider0.github.io/civ6-smart-district-planner/)。

一局只开一个规划器；和其他模组一起用的情况见[和其他模组一起用](#和其他模组一起用)。

### 安装

1. 在创意工坊订阅[智能区域规划器](https://steamcommunity.com/sharedfiles/filedetails/?id=3824473635)和 [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051)。
2. 主菜单“额外内容”里勾上 Detailed Map Tacks 和“智能区域规划器”，重启游戏。

不用创意工坊的话，从[发布页](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/latest)下载压缩包，把里面的 `SmartDistrictPlanner` 文件夹放进游戏的 Mods 文件夹（DMT 仍要订阅）：
- Windows：`文档\My Games\Sid Meier's Civilization VI\Mods\`
- macOS：`~/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/`

只留一份：Mods 里和创意工坊各有一份时，游戏只加载其中一份，不一定是新的，也不一定是你启用的那份。改用创意工坊版时，把 Mods 里的这个文件夹删掉。

各页签的用法、已知限制和排错见[安装与使用](docs/install-and-test.md)。问题请在 [Issues](https://github.com/SmallSpider0/civ6-smart-district-planner/issues) 反馈，更新内容见 [CHANGELOG](CHANGELOG.md)。

### 和其他模组一起用

2026-11-05 核对。

大多数加新文明、新区域、新奇观、改相邻加成的模组都能一起用，规划会跟着它们的规则走。界面模组（CQUI、Better Report Screen、More Lenses 等）一般也不冲突。已在游戏里实测过：和而不同（Civ6 Plus: Harmony in Diversity）v2.2。

一起用时要知道的：

- **模块化相邻加成（及依赖它的模组）**：它加的相邻加成不会算进方案，以后也不会，实际建成后会比面板显示的多。原因：这些加成要等区域建成、到下一回合才由那个模组算出来，而本模组的加成都取自 Detailed Map Tacks（和地图钉上显示的是同一份数），它看不到这些加成。
- **和而不同里少数领袖、奇观的特殊加成**（如武则天“区域挨着奇观 +2”）：同样不会算进方案，以后也不会。原因：Detailed Map Tacks 不认这类加成，本模组也不另算，面板和地图钉上的数才总是一样。
- **和而不同的“覆盖”**：它把建筑的范围效果改由自己计算，“覆盖”一项仍按游戏规则里的范围算，不计它给建筑新加的范围效果。
- **Workable 4th Ring**：本模组只规划城市三环内的格，第 4 环的区域要自己放。

不要一起开：

- **Auto Map Tacks Planner、Empire Planner、District & Wonder Planner**：几个规划模组会互相改掉或删掉对方的地图钉。一局只开一个。

列表里没有的模组，发现算得不对，欢迎在 GitHub 提 [Issue](https://github.com/SmallSpider0/civ6-smart-district-planner/issues) 或在创意工坊留言。

### 同类模组

| | [Auto Map Tacks Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3771382002) | [Empire Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3793348626) | [District & Wonder Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3780936549) | 本模组 |
|---|---|---|---|---|
| 区域 | ✓ | ✓ | ✓ 一次最多 3 种（另加水渠、市政广场） | ✓ |
| 奇观 | ✓ | ✓ | ✓ 最多 5 座 | ✓ |
| 改良设施 | ✓ 含特色改良设施 | ✓ | ◐ 只规划奇观需要的那一种 | ◐ 给区域相邻加成的改良、奇观需要的营地，可选城市要耕作的地块；不含特色改良设施 |
| 选新城址 | — 未来的城用你打的城市中心钉 | ✓ 0–6 处 | — 未来的城用你打的城市中心钉 | ✓ 1–6 处，密铺最多 12 处 |
| 几座城一起规划 | ✓ 最多 4 座 | ✓ 全部现有城市和新城址一次规划 | ✓ 可勾选全部城市 | ✓ 全部城市和城址钉，超过 8 座时分组轮流规划 |
| 打地图钉 | ✓ | ✓ | ✓ | ✓ |
| 需要 DMT | ✓ | — 作者建议关掉 DMT | ✓ | ✓ |
| 加成由谁计算 | DMT | 自己的规则 | DMT | DMT |
| 规则集 | 未写明 | 迭起兴衰、风云变幻（作者说原版没测过） | 未写明 | 原版、迭起兴衰、风云变幻 |
| 界面语言 | 英文、简体中文、繁体中文 | 英文 | 英文、简体中文 | 英文、简体中文 |
| 作者写明的同开限制 | 未写 | DMT | 未写 | 其他区域规划器 |
| 创意工坊页面的更新日期 | 2026-09-19（r49） | 2026-09-10 | 2026-08-29（v1.1） | 2026-10-25 |

✓ 是 · ◐ 部分 · — 否

2026-10-26 按各模组的创意工坊页面和模组文件核对；页面和文件都没写的标“未写明”。创意工坊上的标题分别是 Fully Automatic Map Tacks Planner【Four-City Linked】、Empire Planner + (Auto Map Tacks) Advanced、District & Wonder Planner v1.1；它们会更新，以各自页面为准。

表里没列的功能：

- **Auto Map Tacks Planner**：把你打的“移除地貌 / 采收 / 种树”钉当作规划指令；“只用已解锁的内容”和“长期蓝图”两种模式。
- **Empire Planner**：按时代限定规划范围；存档里保存 3 套布局。
- **District & Wonder Planner**：按区域的先后顺序给权重。
- **本模组**：结果写明这已经是最好的摆法，或者最多还差百分之几。

Detailed Map Tacks 不是规划器：它在地图钉上显示区域、奇观放在这一格时的产出和相邻加成。

### 参与开发

先读 [CONTRIBUTING.md](CONTRIBUTING.md)（中英文：硬约束、环境、开不开游戏都能跑的检查、代码约定、怎么提交 PR）和 [AGENTS.md](AGENTS.md)（需求约束、技术方案、模组开发的坑、工作流程）。维护者的流程、分工和发版写在 [docs/maintaining.md](docs/maintaining.md)。

| 文档 | 内容 |
|------|------|
| [docs/dev-macos.md](docs/dev-macos.md)、[docs/dev-windows.md](docs/dev-windows.md) | 两个平台的开发环境 |
| [tools/README.md](tools/README.md) | 校验、部署、游戏内测试、离线对比等工具 |
| [docs/workflow.html](docs/workflow.html) | 开发流程一览，发版时也发布到[网页](https://smallspider0.github.io/civ6-smart-district-planner/workflow/) |
| [docs/workshop-upload.md](docs/workshop-upload.md) | 把提交包上传到 Steam 创意工坊（Windows） |
| [docs/design.md](docs/design.md) | 求解算法、目标函数、与 DMT 的接缝、模块结构 |
| [docs/multicity-design.md](docs/multicity-design.md) | 选城址、多城、奇观、求解档位、离线基准，以及历次实测反馈的改进 |
| [docs/self-test-report.md](docs/self-test-report.md) | 自测报告：验收清单逐项证据、测试结果、截图 |
| [civ6-mod-from-scratch-prompt.md](civ6-mod-from-scratch-prompt.md) | 需求文档 |

```
SmartDistrictPlanner/        模组本体：复制到游戏 Mods 目录即可运行
  SmartDistrictPlanner.modinfo
  Text/                      中英文本
  UI/SDP_Panel.xml/.lua      启动栏按钮与规划面板
  Scripts/                   规则、城市扫描、假想钉层、增量评估（SDP_Board）、搜索引擎（SDP_Search）、
                             单城/多城/城址求解器、档位、分帧任务、预览、打钉、提醒钉
tests/                       游戏内测试（经 FireTuner 执行）；tests/offline 为离线测试与基准，tests/compare 为离线评估
tools/                       校验、部署、测试运行器、游戏控制、打包、路径（paths.py）
report/                      介绍页的生成脚本与模板（发布时由 GitHub Actions 生成并发布）
docs/                        设计、安装说明、自测报告、开发环境、截图
```

### 致谢

- [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051)（D、wltk）：本模组的合法性判断和相邻加成全部由它计算，地图钉上的数也由它显示。
- [Auto Map Tacks Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3771382002)：这些做法学自它：奇观下拉框按时代、再按造价排列；“好位置”着色；多城页签的逐城清单和按产出生成的模板；全帝国限量的区域只放进写了它的城；覆盖范围；撤销记录随存档保存；替换本模组之前打的钉；Shift+L 快捷键。
- [Empire Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3793348626)：在城市已拥有的格上，用游戏引擎给出的可建格复核方案，学自它。

### 许可证

[MIT](LICENSE)。本仓库不含 Detailed Map Tacks 及其他模组、游戏本体的代码或数据；玩家需自行订阅 DMT。
