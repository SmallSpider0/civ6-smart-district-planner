# #198 第二台机器上的实验目录自动清理

2026-11-02。`~/sdp-runs/` 在第二台机器上 3.5 GB、360 个条目（42 个快照、148 个任务记录）。原来的 `sdpsched.py prune` 只在 `remote.py run` 启动任务前跑，只删结束超过 7 天的快照和 7 天没人用的工作树副本；日志、退出码文件、任务记录从不删，本机删了工作树后副本也要等一周。

做法（`tools/sdpsched.py`、`tools/remote.py`、`tools/worktree.py`）：

- `sdpsched.py prune [--known 工作树名...] [--keep-days N] [--dry-run]`，先算出要删什么（`plan_prune`）再删：
  - 已结束或丢失（进程没了）的任务：超过天数后，快照、`NAME.log`、`NAME.exit`、`jobs/NAME.json` 一起删；
  - 没有任务记录的快照、日志、退出码文件：同样按天数；日志 2 小时内写过又没有退出码文件的当作旧式任务在跑，不动；
  - 工作树副本：照旧；
  - 给了 `--known`（本机现存的工作树名）时，不在名单里的工作树的副本和从它启动的任务，满 1 天就删（`GONE_KEEP`；1 天是留给别处刚建的工作树或刚取回结果的余量）。
  - 在排队、在跑的任务（`live()`）的文件和副本从不删。
- `remote.py clean [--dry-run] [--keep-days N]`：先装最新的 `sdpsched.py`，再带着 `git worktree list` 的名字调它。
- `worktree.py prune --remote` 删完工作树后调 `remote.clean`；没配第二台机器时跳过，连不上只打印一句，不让 prune 失败。
- 测试：`tests/tools/test_sdpsched.py`、`test_remote.py`、`test_worktree.py`，ssh 用替身，没有真连。

当晚没有在第二台机器上跑（它在忙），只做了只读的 `du`。第一次真正的清理建议先 `remote.py clean --dry-run` 看清单。

Codex 审查（PR #200）指出：删任务记录前没拿调度锁、没重读，和同名任务新提交竞争会误删。属实，改成：删每一项前在调度锁里重新算一遍清单，这一项还在才删；并且任务的快照、日志、退出码文件里有比天数新的，就不当老任务（`remote.py run` 在 `sdpsched.py` 写下排队记录之前就已经重建快照、重开日志，那时记录还是旧的 done）。两条各有一个在旧代码上失败的测试。
