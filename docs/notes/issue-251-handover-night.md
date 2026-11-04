# #251 夜间测试交接（2026-11-05）

- 游戏内全部测试：138 通过、1 失败、5 跳过；真实点击 realclick suite：71 通过、0 失败；第二台机器 i251-check：268 行，方案全部不变（changed 0，新违规 0）。
- 失败的一项：`tests/test_feedback.lua:106`，用例“the panel: count above the required districts runs as a task, shows three solutions and previews them”。`SDP_Panel.PlacePins()` 返回 6，而 `#third.Plan + #third.Remind` 是 5（多放了一个钉）。
- 还没查：是 #251 搬动单城页后 PlacePins 多算了一个（疑似重复打钉或多了城市中心钉），还是该用例本来就不稳。办法：在 main 上同一新开局（`game.py newgame --capital --reveal`）单跑这个文件对比。
- 没有改代码。日志：/tmp/sdp251_tests.log（本机，可能已清）。
