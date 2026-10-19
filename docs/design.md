# 设计说明（待编写）

交付物 3。开发时补全以下章节：

## 求解算法结构
<!-- 线性查表排序 → top-N DMT 精评 → 局部搜索兜底；确定性保证 -->

## 目标函数定义
<!-- 分类型加权和、联合总分与锁定钉基线 -->

## 与 DMT 的接缝
<!-- include 列表、overlay 安装/恢复、缓存清理、事件订阅移除 -->

## 界面骨架（阶段 1）

- 一个 InGame 上下文 `UI/SDP_Panel.xml/.lua`（AddUserInterfaces，LoadOrder 14000，依赖 DMT）同时负责启动栏按钮和面板。
- **启动栏按钮**：`Events.LoadScreenClose` 时向 `/InGame/LaunchBar/ButtonStack` 注入 `SDP_LaunchBarItem`（与游戏 `LaunchBarItem` 同形，图标 `ICON_MAP_PIN_DISTRICT`）和一个分隔点，并按游戏 `RealizeBacking()` 的做法调整启动栏底板宽度。热重载（`isReload`）时立即注入；上下文关闭时把这两个控件从启动栏删掉，避免留下失效的重复按钮。
- **面板**：`UIManager:QueuePopup(ContextPtr, PopupPriority.Low)` 打开、`DequeuePopup` 关闭，先查 `IsInPopupQueue`（坑 11）。外框沿用游戏弹窗写法（`DropShadow2` 包 `WindowFrameTitle`，标题 `WindowHeader`，右上角 `CloseButtonSmall`）。Esc 在面板打开时关闭面板，关闭时不拦截。
- **对外接口**：`LuaEvents.SDP_OpenPanel()` / `LuaEvents.SDP_ClosePanel()`。
- **测试钩子**：面板上下文里的全局表 `SDP_Panel`（`Open`/`Close`/`IsOpen`/`HandleInput`/`LaunchButton`），供 `tests/test_panel.lua` 在 `SDP_Panel` Lua 状态里调用。
- **mod 列表文本**：名称、简介、描述同时写在 modinfo `<LocalizedText>`（未启用时也能显示）和 `Text/*.xml`（FrontEndActions，坑 1）。

## 后续扩展预留
<!-- 多城联合、奇观求解 -->
