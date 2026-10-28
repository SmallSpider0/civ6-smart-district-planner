#!/usr/bin/env python3
"""Data for the status page: the machines' slots, the work in progress on git and
GitHub, and a few hand-written notes, bundled into one status.json.

Machines (OUT/machines/<id>.json), from the schedulers' own records, so the page
shows what really runs:
  - this machine: tools/sdplock.py's shared folder (heavy jobs, game lock) and
    compare.mjs processes nobody registered;
  - the second machine (tools/remote.py's host): its jobs/*.json, the last
    progress line of each log, and compare.mjs processes started outside the queue.
Work (OUT/work/*.json), from git, gh and the shared night queue:
  - branches: every branch other than main that has a worktree or an open PR,
    the issues its commits name, its last commit, the PR's checks and
    auto-merge, the night-queue items queued for it, and the left-over
    branches from tools/worktree.py stale;
  - milestones: GitHub's milestones with each issue's state;
  - issues: every open issue for the review table (group, labels, who added
    `auto`, branch and PR, who has to answer);
  - night: the shared night queue;
  - releases: GitHub's last releases, each summarised from its notes.
Hand-written (MANUAL, collections decisions/*, milestones/*, jobs/*): only the
fields in FIELDS; releases are never written by hand. The page (page.html next
to this script) builds its overview from all of it; nothing there is written
by hand.

With --push the snapshot is bundled into OUT/status.json, checked for private
strings (paths, IPs, mail addresses, and this machine's own words from the
local config: nothing is pushed if one shows up) and sent with `ssh HOST NAME`
(the receiving key may only write status.json or index.html) when it changed
or PUSH_EVERY passed. Without a push host in the local config the bundle is
written and checked, and nothing is sent.

    python3 -I tools/status/sync.py [OUT_DIR] [--quick] [--push]
    python3 -I tools/status/sync.py set decisions/issue-120 '{"title": "...", "status": "open"}'
    python3 -I tools/status/sync.py update decisions/issue-120 '{"status": "done", "doneAt": "2026-10-27"}'
    python3 -I tools/status/sync.py delete jobs/old-job
    python3 -I tools/status/sync.py get [jobs]

set/update/delete edit MANUAL (stamping meta/page.updated) and push at once;
tools/status/watch.py runs the snapshot and push every minute.

Machine-specific values come from the "status" object of the local config
(tools/sdplock.py: $SDP_LOCAL_CONFIG, else ~/.config/sdp/local.json), all optional:

    "status": {"push_host": "status-push",        # ssh host that receives the files; none: no push
               "page_host": "status.example.org", # where the page is served (watch.py checks its certificate)
               "private_words": ["alice", "build-box"],  # never on the page: account and host names
               "local_name": "This machine",      # machine card titles
               "remote_name": "Second machine"}
"""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time

try:
    import fcntl
except ImportError:  # Windows: the tests and a collaborator's bundle run there too
    fcntl = None
    import msvcrt

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
REPO = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
import sdplock  # noqa: E402
from remote import BASE as RUNS  # noqa: E402  the second machine's run folder, under its home

SHARED = sdplock.shared_dir()
OUT = os.path.join(SHARED, "status", "out")
MANUAL = os.path.join(SHARED, "status", "manual.json")
PAGE = os.path.join(HERE, "page.html")
PUSH_EVERY = 600  # push at least this often so the page's time stays fresh
COLLECTIONS = ("meta", "decisions", "milestones", "jobs")
# The fields the page reads per hand-written collection. A write with any other field is refused:
# a field the page does not read shows nothing (2026-10-27 a decision written with state/note stayed
# open; 2026-10-28 the v1.5.4 and v1.6.0 notes written with what/next blanked the releases' content).
FIELDS = {
    "decisions": {"title", "recommendation", "options", "detail", "link", "milestone", "order", "status",
                  "doneAt", "kind", "collaborator"},
    "milestones": {"ms", "name", "link", "goal", "eta", "blocker", "next", "order", "state", "doneAt",
                   "issues", "progress"},
    "jobs": {"what", "where", "started", "eta", "state", "run", "branch", "agent", "order", "doneAt",
             "session", "slots", "owner", "link"},
}
REQUIRED = {"decisions": {"title"}, "jobs": {"what"}}
# Never on the page: local and server paths, ssh keys, IPs, mail addresses. This machine's own
# words (account and host names) come from the local config's status.private_words.
PRIVATE = (r"/Users/|/home/|/private/|/var/|/etc/|\.ssh\b|"
           r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])|[\w.+-]+@[\w-]+\.[a-z]{2,}")
# owner branch or tree -> the session shown on the page (first match wins)
SESSIONS = [("grid53", "评测基线"), ("baseline", "评测基线"), ("landv150", "评测基线"),
            ("v150", "v1.5.0"), ("w49", "v1.5.0"), ("sitesold", "v1.5.0")]

REMOTE_SCRIPT = r'''
import glob, json, os, re, subprocess
base = os.path.expanduser("~/%s")
jobs = []
for p in sorted(glob.glob(os.path.join(base, "jobs", "*.json"))):
    try:
        j = json.load(open(p, encoding="utf-8"))
    except Exception:
        continue
    log = os.path.join(base, j.get("name", "") + ".log")
    last = ""
    try:
        with open(log, "rb") as fh:
            fh.seek(0, 2); size = fh.tell(); fh.seek(max(0, size - 4000))
            lines = [l for l in fh.read().decode("utf8", "replace").splitlines() if l.strip()]
            last = lines[-1] if lines else ""
    except Exception:
        pass
    j["last"] = last
    j.pop("cmd", None)
    jobs.append(j)
ps = subprocess.run(["ps", "-Ao", "pid=,pgid=,command="], capture_output=True, text=True).stdout
print(json.dumps({"jobs": jobs, "ps": ps, "now": __import__("time").time()}))
''' % RUNS


def session_of(*keys):
    text = " ".join(str(k or "") for k in keys)
    for pat, name in SESSIONS:
        if pat in text:
            return name
    return "主会话等"


def hm(t):
    return time.strftime("%m-%d %H:%M", time.localtime(t)) if t else ""


def progress(line):
    m = re.search(r"\[(\d+)/(\d+)\]", line or "")
    return "%s/%s" % (m.group(1), m.group(2)) if m else ""


def workers(cmd):
    m = re.search(r"(?:^|\s)(?:-j|--jobs)\s+(\d+)", cmd)
    return int(m.group(1)) if m else None


def out_name(cmd):
    m = re.search(r"--out\s+\S*?([^/\s]+)\.jsonl", cmd)
    return m.group(1) if m else "compare"


# Processes that do heavy work without going through sdplock.py heavy or remote.py:
# (marker in the command line, label, how to name what it runs).
KINDS = (("compare.mjs", None), ("offline_tests.mjs", "离线测试"), ("run_tests.py", "游戏内测试"))
WRAPPERS = ("sdpsched", "sdplock", "remote.py")
SHELL = re.compile(r"\S*/?(?:z|ba)?sh\s")  # the shell that started a command repeats its text


def job_name(cmd, label):
    if label is None:
        return out_name(cmd)
    files = re.findall(r"(?:^|\s|/)([\w-]+)\.lua(?=\s|$)", cmd)
    files = sorted(set(files), key=files.index)
    return label + " " + (", ".join(files) if files else "整套")


def unregistered(ps_text, known_pids, default):
    """Heavy process groups no record covers (compare.mjs, offline tests, in-game tests):
    [{name, slots, pids}]."""
    groups = {}
    for line in ps_text.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3 or any(w in parts[2] for w in WRAPPERS) or SHELL.match(parts[2]):
            continue
        kind = next((k for k in KINDS if k[0] in parts[2]), None)
        if not kind:
            continue
        pid, pgid, cmd = int(parts[0]), int(parts[1]), parts[2]
        if pid in known_pids or pgid in known_pids:
            continue
        g = groups.setdefault(pgid, {"name": job_name(cmd, kind[1]), "slots": 0, "pids": []})
        g["slots"] = max(g["slots"], workers(cmd) or (default if kind[1] is None else 1))
        g["pids"].append(pid)
    return list(groups.values())


def local_facts(pid):
    """Branch of the worktree a local process runs in, and when it started."""
    branch, started = "", ""
    try:
        cwd = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], capture_output=True,
                             text=True, timeout=10).stdout.splitlines()[-1][1:]
        branch = subprocess.run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True,
                                text=True, timeout=10).stdout.strip()
    except Exception:
        pass
    try:
        et = subprocess.run(["ps", "-o", "etime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        d, _, hms = et.rpartition("-")
        secs = 0
        for part in hms.split(":"):
            secs = secs * 60 + int(part)
        secs += int(d or 0) * 86400
        started = hm(time.time() - secs)
    except Exception:
        pass
    return branch, started


def stopped(pid):
    r = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return r.startswith("T")


def config():
    return sdplock.local_config()


def settings(cfg=None):
    """The local config's "status" object (see the module docstring); {} when there is none."""
    st = (config() if cfg is None else cfg).get("status")
    return st if isinstance(st, dict) else {}


def macbook(now):
    cfg = config()
    lt = time.localtime(now)
    a, b = (cfg.get("night") or "00:00-08:00").split("-")
    cur = time.strftime("%H:%M", lt)
    night = (cur >= a or cur < b) if a > b else (a <= cur < b)
    weekend = cfg.get("weekend_is_night", True) and lt.tm_wday >= 5
    cap = cfg.get("workers_night", 6) if (night or weekend) else cfg.get("workers_day", 4)
    running, known = [], set()
    for p in sorted(glob.glob(os.path.join(SHARED, "jobs", "*.json"))):
        try:
            j = json.load(open(p, encoding="utf-8"))
        except Exception:
            continue
        pid = j.get("pid")
        if not pid or subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0:
            continue
        known.add(pid)
        running.append({"name": j.get("name"), "session": session_of(j.get("owner"), j.get("tree")),
                        "owner": j.get("owner") or "", "slots": workers(" ".join(j.get("cmd") or [])) or 1,
                        "started": hm(j.get("started")), "paused": bool(j.get("paused")) or stopped(pid)})
    ps = subprocess.run(["ps", "-Ao", "pid=,pgid=,command="], capture_output=True, text=True).stdout
    ext = []
    for g in unregistered(ps, known, 1):
        branch, started = local_facts(min(g["pids"]))
        ext.append({"name": g["name"] + ("（%s）" % branch if branch else ""), "slots": g["slots"],
                    "paused": all(stopped(p) for p in g["pids"]), "owner": branch, "started": started,
                    "session": "", "unregistered": True})
    game = None
    try:
        g = json.load(open(os.path.join(SHARED, "game.json"), encoding="utf-8"))
        if g.get("holder"):
            h = g["holder"]
            game = {"holder": h.get("branch") or h.get("owner") or "", "purpose": h.get("purpose") or ""}
    except Exception:
        pass
    return {"order": 1, "name": settings(cfg).get("local_name") or "这台机器", "cap": cap,
            "capNote": "白天 %s 个、夜里或周末 %s 个 worker；用游戏时重活暂停" % (cfg.get("workers_day", 4), cfg.get("workers_night", 6)),
            "game": game, "running": running + ext, "queued": [], "recent": []}


def macmini(now):
    cfg = config()
    host = sdplock.remote_host()
    if not host:
        raise RuntimeError("no second machine in the local config")
    py = "/opt/homebrew/bin/python3" if "/opt/homebrew/bin" in (cfg.get("remote_path") or "") else "python3"
    r = subprocess.run(["ssh", host, py, "-"], input=REMOTE_SCRIPT, capture_output=True, text=True, timeout=60)
    data = json.loads(r.stdout)
    jobs, running, queued, recent, known = data["jobs"], [], [], [], set()
    for j in jobs:
        for k in ("pid", "sched_pid"):
            if j.get(k):
                known.add(j[k])
    alive = {int(l.split(None, 1)[0]) for l in data["ps"].splitlines() if l.strip()}
    for j in sorted(jobs, key=lambda j: j.get("queued_at", 0)):
        row = {"name": j["name"], "session": session_of(j.get("owner"), j.get("tree")), "owner": j.get("owner") or "",
               "slots": j.get("slots", 1), "exclusive": bool(j.get("exclusive"))}
        if j.get("state") == "running" and (j.get("pid") in alive or j.get("sched_pid") in alive):
            row.update(started=hm(j.get("started_at")), progress=progress(j.get("last")))
            running.append(row)
        elif j.get("state") == "queued" and j.get("sched_pid") in alive:
            row.update(queuedAt=hm(j.get("queued_at")))
            queued.append(row)
        elif j.get("state") == "done" and now - j.get("ended_at", 0) < 12 * 3600:
            row.update(ended=hm(j.get("ended_at")), exit=j.get("exit"))
            recent.append(row)
    for g in unregistered(data["ps"], known, cfg.get("remote_slots", 8)):
        running.append({"name": g["name"], "slots": g["slots"], "session": "", "unregistered": True})
    recent.sort(key=lambda r: r["ended"], reverse=True)
    return {"order": 2, "name": settings(cfg).get("remote_name") or "第二台机器", "cap": cfg.get("remote_slots", 8),
            "capNote": "按格子排队；排头放不下时后面放得下的先跑", "game": None,
            "running": running, "queued": queued, "recent": recent[:6]}


def run(cmd, timeout=60):
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("%s: %s" % (" ".join(cmd[:3]), r.stderr.strip()[:200]))
    return r.stdout


def checks_state(rollup):
    states = [(c.get("conclusion") or c.get("status") or "").upper() for c in rollup or []]
    if not states:
        return "none"
    if any(s in ("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED") for s in states):
        return "fail"
    if all(s in ("SUCCESS", "SKIPPED", "NEUTRAL") for s in states):
        return "pass"
    return "pending"


def tip(ref):
    try:
        return run(["git", "rev-parse", ref]).strip()
    except Exception:
        return ref


def born(branch):
    """When the local branch was created (its first reflog entry); remote-only branches count as old."""
    try:
        lines = run(["git", "reflog", "show", "--date=unix", "--format=%gd", branch]).split()
        return int(re.search(r"\{(\d+)\}", lines[-1]).group(1))
    except Exception:
        return 0


def work(now):
    branches = {}
    for block in run(["git", "worktree", "list", "--porcelain"]).split("\n\n"):
        m = re.search(r"^branch refs/heads/(.+)$", block, re.M)
        if m and m.group(1) != "main":
            branches[m.group(1)] = {"branch": m.group(1), "worktree": True}
    prs = json.loads(run(["gh", "pr", "list", "--state", "open", "--json",
                          "number,title,url,headRefName,isDraft,autoMergeRequest,statusCheckRollup"]))
    for pr in prs:
        b = branches.setdefault(pr["headRefName"], {"branch": pr["headRefName"], "worktree": False})
        b["pr"] = {"n": pr["number"], "url": pr["url"], "title": pr["title"], "draft": pr["isDraft"],
                   "automerge": pr.get("autoMergeRequest") is not None, "checks": checks_state(pr.get("statusCheckRollup"))}
    try:
        queue = json.load(open(os.path.join(SHARED, "night-queue.json"), encoding="utf-8"))
    except Exception:
        queue = []
    titles = {}
    try:
        for i in json.loads(run(["gh", "issue", "list", "--state", "open", "--limit", "200", "--json", "number,title"])):
            titles[i["number"]] = i["title"]
    except Exception as e:
        print("issues: %s" % e, file=sys.stderr)
    run(["git", "fetch", "-q", "origin", "main"], timeout=90)
    items = []
    for name, b in sorted(branches.items()):
        ref = name if b["worktree"] else "origin/" + name
        if not b["worktree"]:
            try:
                run(["git", "fetch", "-q", "origin", name], timeout=90)
            except Exception:
                pass
        # A branch built on another listed branch (e.g. #89 on #84) shows only its own commits.
        # Two branches on the same commit (one just started on the other): the later one is on the earlier.
        base = []
        for other, ob in branches.items():
            oref = other if ob["worktree"] else "origin/" + other
            if other == name or subprocess.run(["git", "merge-base", "--is-ancestor", oref, ref], cwd=REPO,
                                               capture_output=True).returncode != 0:
                continue
            if tip(oref) == tip(ref) and born(other) >= born(name):
                continue
            base.append("^" + oref)
        seen = {}  # of several bases on one commit keep the oldest branch
        for b0 in base:
            t = tip(b0[1:])
            o = seen.get(t)
            if o is None or born(b0[1:].replace("origin/", "")) < born(o[1:].replace("origin/", "")):
                seen[t] = b0
        base = sorted(seen.values())
        try:
            log = run(["git", "log", "origin/main.." + ref] + base + ["--format=%ct%x09%s"]).splitlines()
        except Exception:
            log = []
        if base:
            b["on"] = [x[1:].replace("origin/", "") for x in base]
        nums = []
        for line in log + ([b["pr"]["title"]] if b.get("pr") else []):
            for n in re.findall(r"#(\d+)", line):
                if int(n) not in nums and (int(n) in titles or not titles):
                    nums.append(int(n))
        last = log[0].split("\t", 1) if log else None
        night = [{"id": q["id"], "what": q.get("what", "")} for q in queue
                 if q.get("branch") == name and q.get("state") not in ("done", "failed")]
        for q in night:  # a branch with no commits of its own yet is known by its queued tests
            for n in re.findall(r"#(\d+)", q["what"]):
                if int(n) not in nums and int(n) in titles:
                    nums.append(int(n))
        pr = b.get("pr")
        if pr and pr["checks"] == "fail":
            stage = "CI 没过"
        elif pr and pr["checks"] == "pending":
            stage = "PR 在跑 CI"
        elif pr and night:
            stage = "PR 等夜间测试"
        elif pr:
            stage = "PR 等合并" if pr["automerge"] else "PR 已开"
        elif night:
            stage = "等夜间测试"
        elif not log:
            stage = "刚开始"
        else:
            stage = "开发中"
        items.append({"branch": name, "stage": stage, "commits": len(log),
                      "issues": [{"n": n, "title": titles.get(n, "")} for n in nums],
                      "last": {"at": hm(int(last[0])), "subject": last[1]} if last else None,
                      "pr": pr, "night": night, "on": b.get("on", [])})
    # Left-over branches from the repository's own tool (worktree.py stale); no local paths on the page.
    stale = None
    try:
        rows = json.loads(run([sys.executable, "-I", os.path.join(REPO, "tools", "worktree.py"), "stale", "--json"],
                              timeout=180))
        stale = [{k: r.get(k) for k in ("branch", "where", "reason", "removable", "last", "subject")} for r in rows]
    except Exception as e:
        print("stale branches: %s" % e, file=sys.stderr)
    return {"items": items, "stale": stale}


# How far along an issue's branch is, most advanced first (stages from work()).
STAGE_RANK = ("PR 等合并", "PR 在跑 CI", "CI 没过", "PR 已开", "PR 等夜间测试", "等夜间测试", "开发中", "刚开始")


def ver_key(title):
    return [int(x) for x in re.findall(r"\d+", title)] or [9999]


def milestones(now, items):
    """Open milestones and those closed in the last 7 days, with each issue's state:
    done (closed), dropped (closed as not planned), doing (a branch or PR has it; stage says
    how far) or todo."""
    stage = {}
    for it in items:
        for i in it["issues"]:
            old = stage.get(i["n"])
            if old is None or STAGE_RANK.index(it["stage"]) < STAGE_RANK.index(old[0]):
                stage[i["n"]] = (it["stage"], it["branch"], (it.get("pr") or {}).get("n"))
    out = []
    for m in json.loads(run(["gh", "api", "repos/{owner}/{repo}/milestones?state=all&per_page=100"])):
        closed = m.get("closed_at")
        if closed:
            t = time.mktime(time.strptime(closed, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
            if now - t > 7 * 86400:
                continue
        issues = []
        for i in json.loads(run(["gh", "issue", "list", "--milestone", m["title"], "--state", "all", "--limit", "100",
                                 "--json", "number,title,state,stateReason"])):
            row = {"n": i["number"], "title": i["title"]}
            if i["state"] == "CLOSED":
                row["state"] = "dropped" if i.get("stateReason") == "NOT_PLANNED" else "done"
            elif i["number"] in stage:
                st, br, pr = stage[i["number"]]
                row.update(state="doing", stage=st, branch=br)
                if pr:
                    row["pr"] = pr
            else:
                row["state"] = "todo"
            issues.append(row)
        issues.sort(key=lambda r: r["n"])
        counted = [r for r in issues if r["state"] != "dropped"]
        done = sum(r["state"] == "done" for r in counted)
        out.append({"number": m["number"], "title": m["title"], "url": m["html_url"],
                    "description": m.get("description") or "", "open": m["state"] == "open",
                    "closedAt": time.strftime("%Y-%m-%d %H:%M", time.localtime(time.mktime(time.strptime(closed, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone)) if closed else "",
                    "done": done, "total": len(counted),
                    "progress": round(100 * done / len(counted)) if counted else 0, "issues": issues})
    out.sort(key=lambda m: ver_key(m["title"]))
    return {"items": out}


def local_time(iso):
    return time.strftime("%m-%d %H:%M", time.localtime(time.mktime(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone))


def asks(body):
    """Whether a comment of ours asks something: a question mark outside folded details and code."""
    text = re.sub(r"<details>.*?</details>|```.*?```|`[^`]*`|https?://\S+", "", body or "", flags=re.S)
    return "？" in text or re.search(r"\?\s*$", text, re.M) is not None


ISSUE_KINDS = (("bug", "bug"), ("enhancement", "功能"), ("question", "问题"), ("documentation", "文档"), ("release", "发版"))
AUTO = "auto"


def labeller(number, label=AUTO):
    """Who last added `label` to the issue, and when (local time), from its events; (None, "") if never."""
    who, at = None, ""
    page = 1
    while True:
        evs = json.loads(run(["gh", "api", "repos/{owner}/{repo}/issues/%d/events?per_page=100&page=%d" % (number, page)]))
        for e in evs:
            if e.get("event") == "labeled" and (e.get("label") or {}).get("name") == label:
                who, at = (e.get("actor") or {}).get("login"), local_time(e["created_at"])
        if len(evs) < 100:
            return who, at
        page += 1


def issue_talk(now, branches=None):
    """Every open issue, for the review table, and who has to answer on it, from its comments.
    The repository owner's account is ours (the maintainer and the agents share it); the other
    collaborators (DracoYus) and everyone else (players) are them. Names are shown as roles.
      kind replied - they wrote last (or opened it and nobody answered): we have to read and answer;
      kind waiting - we wrote last and asked something, and one of them took part: waiting for them
                     (not on issues labelled later).
      group review - neither auto nor later: the maintainer decides whether it is handled;
            auto   - labelled auto by the owner or a collaborator: the watch handles it;
            badauto - labelled auto by someone else: does not count (tools/watch_issues.py);
            later  - put off on purpose."""
    owner = json.loads(run(["gh", "repo", "view", "--json", "owner"]))["owner"]["login"]
    collab = {c["login"] for c in json.loads(run(["gh", "api", "repos/{owner}/{repo}/collaborators?per_page=100"]))}
    role = lambda login: "我们" if login == owner else ("合作者" if login in collab else "玩家")
    work = {}
    for b in (branches or {}).get("items") or []:
        for x in b.get("issues") or []:
            work.setdefault(x["n"], []).append({"branch": b["branch"], "stage": b.get("stage", ""),
                                                "pr": {"n": b["pr"]["n"], "url": b["pr"]["url"]} if b.get("pr") else None})
    items = []
    for i in json.loads(run(["gh", "issue", "list", "--state", "open", "--limit", "200", "--json",
                             "number,title,url,author,labels,milestone,createdAt,updatedAt,body,comments"])):
        labels = [l["name"] for l in i.get("labels") or []]
        posts = [{"who": i["author"]["login"], "at": i["createdAt"], "body": i.get("body") or ""}]
        posts += [{"who": (c.get("author") or {}).get("login") or "", "at": c["createdAt"], "body": c.get("body") or ""}
                  for c in i.get("comments") or []]
        posts = [p for p in posts if p["who"] and not p["who"].endswith("[bot]")]
        them = sorted({role(p["who"]) for p in posts if p["who"] != owner})
        row = {"n": i["number"], "title": i["title"], "url": i["url"],
               "milestone": (i.get("milestone") or {}).get("title") or "", "at": local_time(i["updatedAt"]),
               "opened": local_time(i["createdAt"]), "by": role(i["author"]["login"]),
               "type": [name for key, name in ISSUE_KINDS if key in labels],
               "labels": [l for l in labels if l not in (AUTO, "later") and l not in dict(ISSUE_KINDS)],
               "work": work.get(i["number"], [])}
        if AUTO in labels:
            who, at = labeller(i["number"])
            row["auto"] = {"by": role(who) if who else "不明", "at": at}
            row["group"] = "auto" if who == owner or who in collab else "badauto"
        else:
            row["group"] = "later" if "later" in labels else "review"
        if posts and them:
            last = posts[-1]
            if last["who"] != owner:
                row.update(kind="replied", who=[role(last["who"])], talkAt=local_time(last["at"]))
            elif asks(last["body"]) and "later" not in labels:
                row.update(kind="waiting", who=them, talkAt=local_time(last["at"]))
        items.append(row)
    return {"items": sorted(items, key=lambda r: r["n"])}


def night(now):
    """The shared night queue: items still to run, and those finished in the last 7 days."""
    try:
        queue = json.load(open(os.path.join(SHARED, "night-queue.json"), encoding="utf-8"))
    except Exception:
        queue = []
    items = []
    for q in queue:
        done = q.get("state") in ("done", "failed")
        if done and now - (q.get("finished") or 0) > 7 * 86400:
            continue
        items.append({"id": q["id"], "branch": q.get("branch") or "", "what": q.get("what") or "",
                      "why": q.get("why") or "", "state": q.get("state") or "queued",
                      "result": q.get("result") or "", "added": hm(q.get("added")),
                      "finished": hm(q.get("finished")) if done else ""})
    cfg = config()
    return {"window": cfg.get("night") or "00:00-08:00", "items": items}


def release_summary(body):
    """Short Chinese summary from a release body: the lead of each item under "自 … 以来的变化"."""
    part = re.search(r"^## 自 .*?以来的变化\s*$(.*?)(?=^## |\Z)", body or "", re.M | re.S)
    leads = []
    for line in (part.group(1) if part else "").splitlines():
        if not line.startswith("- "):
            continue
        text = line[2:].strip()
        m = re.match(r"\*\*(.+?)\*\*", text)
        # Up to the first full stop; a "选城址页：" prefix stays with what follows it (v1.5.4 read
        # "选城址页；单城页"). Long ones are cut at a comma, else at 30 characters.
        lead = (m.group(1) if m else re.split(r"[。；（]", text, 1)[0]).strip()
        if len(lead) > 30:
            cut = lead.rfind("，", 0, 30)
            lead = lead[:cut] if cut > 8 else lead[:30] + "…"
        leads.append(lead)
    return "；".join(leads[:6]) + ("……" if len(leads) > 6 else "")


def releases(now, out_dir):
    try:  # a release's text rarely changes: read each body once
        known = {r["version"]: r for r in json.load(open(os.path.join(out_dir, "work", "releases.json"), encoding="utf-8"))["items"]}
    except Exception:
        known = {}
    out = []
    for r in json.loads(run(["gh", "release", "list", "--limit", "6", "--json", "tagName,name,publishedAt,isPrerelease"])):
        if r["tagName"] in known and known[r["tagName"]].get("summary"):  # an empty one is read again
            out.append(known[r["tagName"]])
            continue
        body = json.loads(run(["gh", "release", "view", r["tagName"], "--json", "body,url"]))
        t = time.mktime(time.strptime(r["publishedAt"], "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
        out.append({"version": r["tagName"], "date": time.strftime("%Y-%m-%d %H:%M", time.localtime(t)),
                    "pre": r["isPrerelease"], "link": body["url"], "summary": release_summary(body["body"])})
    return {"items": out}


def local_recent(out, doc, now):
    """This machine keeps no job history: what ran at the last snapshot and is gone now ended
    in between. Kept 12 hours, newest 6."""
    try:
        old = json.load(open(os.path.join(out, "machines", "macbook.json"), encoding="utf-8"))
    except Exception:
        return []
    names = {r["name"] for r in doc["running"]}
    stamp = time.strftime("%m-%d %H:%M", time.localtime(now))
    ended = [{"name": r["name"], "session": r.get("session", ""), "owner": r.get("owner", ""),
              "slots": r.get("slots", 1), "ended": stamp, "exit": None}
             for r in old.get("running", []) if r["name"] not in names]
    keep = [r for r in old.get("recent", []) if r["name"] not in names
            and now - time.mktime(time.strptime(time.strftime("%Y-") + r["ended"], "%Y-%m-%d %H:%M")) < 12 * 3600]
    return sorted(ended + keep, key=lambda r: r["ended"], reverse=True)[:6]


def lock_file(fh):
    """Hold an exclusive lock on the open file until it is closed."""
    if fcntl:
        fcntl.flock(fh, fcntl.LOCK_EX)
    else:
        while True:
            try:
                msvcrt.locking(fh.fileno(), msvcrt.LK_LOCK, 1)
                return
            except OSError:  # LK_LOCK gives up after 10 seconds; keep waiting
                continue


def load_manual():
    try:
        with open(MANUAL, encoding="utf-8") as fh:
            d = json.load(fh)
    except FileNotFoundError:
        d = {}
    for c in COLLECTIONS:
        d.setdefault(c, {})
    return d


def edit_manual(op, path, data=None):
    """set / update / delete one hand-written doc ("decisions/issue-120"), under a lock."""
    coll, _, doc = path.partition("/")
    if coll == "releases":  # 2026-10-28: releases are generated from GitHub, never written by hand
        sys.exit("releases come from the GitHub releases' notes; edit the release on GitHub instead")
    if coll not in COLLECTIONS[1:] or not doc or "/" in doc:  # meta holds only the stamp below
        sys.exit("path must be one of %s/<id> (the overview is generated, not written)" % "|".join(COLLECTIONS[1:]))
    if data is not None:
        unknown = sorted(set(data) - FIELDS[coll])
        if unknown:
            sys.exit("%s: the page does not read %s; fields are %s" % (coll, unknown, sorted(FIELDS[coll])))
        missing = sorted(REQUIRED.get(coll, set()) - set(data)) if op == "set" else \
            sorted(k for k in REQUIRED.get(coll, set()) if k in data and not data[k])
        if missing:
            sys.exit("%s needs %s" % (coll, missing))
    os.makedirs(os.path.dirname(MANUAL), exist_ok=True)
    with open(MANUAL + ".lock", "w", encoding="utf-8") as lock:
        lock_file(lock)
        d = load_manual()
        if op == "delete":
            if d[coll].pop(doc, None) is None:
                print("no such doc: %s" % path, file=sys.stderr)
        elif op == "set":
            d[coll][doc] = data
        else:
            for k, v in data.items():
                if v is None:
                    d[coll].setdefault(doc, {}).pop(k, None)
                else:
                    d[coll].setdefault(doc, {})[k] = v
        d["meta"].setdefault("page", {})["updated"] = time.strftime("%Y-%m-%d %H:%M")
        tmp = MANUAL + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(d, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, MANUAL)


def bundle(out):
    """OUT_DIR/status.json: everything the page shows, in one file."""
    def read(*p):
        try:
            with open(os.path.join(out, *p), encoding="utf-8") as fh:
                return json.load(fh)
        except Exception:
            return None
    m = load_manual()
    docs = lambda c: [dict(v, id=k) for k, v in sorted(m[c].items())]
    b = {"generated": time.strftime("%Y-%m-%d %H:%M"), "meta": {"updated": m["meta"].get("page", {}).get("updated")},
         "decisions": docs("decisions"), "milestones": docs("milestones"), "jobs": docs("jobs"),
         "machines": [dict(d, id=k) for k in ("macbook", "macmini") for d in [read("machines", k + ".json")] if d],
         "work": {k: read("work", k + ".json") for k in ("branches", "milestones", "night", "releases", "issues")}}
    text = json.dumps(b, ensure_ascii=False, separators=(",", ":"))
    with open(os.path.join(out, "status.json"), "w", encoding="utf-8") as fh:
        fh.write(text)
    return text


def private_pattern(st):
    """PRIVATE plus this machine's own words: status.private_words and the push and page hosts."""
    words = [w for w in list(st.get("private_words") or []) + [st.get("push_host"), st.get("page_host")]
             if isinstance(w, str) and w.strip()]
    extra = "".join("|" + re.escape(w.strip()) for w in sorted(set(words), key=lambda w: (-len(w), w)))
    return re.compile(PRIVATE + extra, re.I)


def private_hits(text, st=None):
    pat = private_pattern(settings() if st is None else st)
    return sorted({text[max(0, x.start() - 30):x.end() + 10] for x in pat.finditer(text)})


def send(host, name, path):
    with open(path, "rb") as fh:
        r = subprocess.run(["ssh", host, name], stdin=fh, capture_output=True, text=True, timeout=90)
    if r.returncode != 0:
        raise RuntimeError("push %s: %s" % (name, (r.stderr or r.stdout).strip()[-300:]))


def push(out):
    """Send status.json when its content (not counting the time stamps) changed or PUSH_EVERY passed,
    and index.html when the page changed. Exit 3 on a failed push, 4 on private strings.
    Without status.push_host in the local config the bundle is written and checked, nothing is sent."""
    st = settings()
    text = bundle(out)
    hits = private_hits(text, st)
    if hits:
        print("not pushed, private strings: %s" % hits, file=sys.stderr)
        sys.exit(4)
    host = st.get("push_host")
    if not host:
        print("bundled %s; no status.push_host in the local config, nothing pushed" % os.path.join(out, "status.json"))
        return
    stable = re.sub(r'"(?:generated|synced|updated)":"[^"]*"', "", text)
    sig_file = os.path.join(out, "pushed.json")
    try:
        with open(sig_file, encoding="utf-8") as fh:
            sig = json.load(fh)
    except Exception:
        sig = {}
    with open(PAGE, "rb") as fh:
        page_hash = hashlib.sha1(fh.read()).hexdigest()
    data_hash = hashlib.sha1(stable.encode()).hexdigest()
    try:
        if sig.get("page") != page_hash:
            send(host, "index.html", PAGE)
            sig["page"] = page_hash
            print("pushed index.html")
        if sig.get("data") != data_hash or time.time() - sig.get("at", 0) >= PUSH_EVERY:
            send(host, "status.json", os.path.join(out, "status.json"))
            sig.update(data=data_hash, at=time.time())
            print("pushed status.json (%d bytes)" % len(text.encode()))
    except Exception as e:
        print(e, file=sys.stderr)
        sys.exit(3)
    finally:
        with open(sig_file, "w", encoding="utf-8") as fh:
            json.dump(sig, fh)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if args and args[0] in ("set", "update", "delete", "get"):
        op = args[0]
        if op == "get":
            m = load_manual()
            print(json.dumps(m[args[1]] if len(args) > 1 else m, ensure_ascii=False, indent=1))
            return
        if len(args) < 2 or (op != "delete" and len(args) < 3):
            sys.exit(__doc__)
        edit_manual(op, args[1], json.loads(args[2]) if op != "delete" else None)
        os.makedirs(OUT, exist_ok=True)
        push(OUT)
        return
    out = args[0] if args else OUT
    quick = "--quick" in sys.argv[1:]  # machines only: cheap enough to run every minute
    now = time.time()
    os.makedirs(os.path.join(out, "machines"), exist_ok=True)
    os.makedirs(os.path.join(out, "work"), exist_ok=True)
    stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(now))
    for key, fn in (("macbook", macbook), ("macmini", macmini)):
        try:
            doc = fn(now)
        except Exception as e:  # keep the other machine's snapshot
            print("%s: %s" % (key, e), file=sys.stderr)
            continue
        doc["synced"] = stamp
        if key == "macbook":
            doc["recent"] = local_recent(out, doc, now)
        with open(os.path.join(out, "machines", key + ".json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=1)
        print("%s: %d running, %d queued, %d/%d slots" % (key, len(doc["running"]), len(doc["queued"]),
                                                         sum(r["slots"] for r in doc["running"]), doc["cap"]))
    if not quick:
        full(out, now, stamp)
    if "--push" in sys.argv[1:]:
        push(out)


def full(out, now, stamp):
    try:
        doc = work(now)
        doc["synced"] = stamp
        with open(os.path.join(out, "work", "branches.json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=1)
        print("work: %d branch(es)" % len(doc["items"]))
    except Exception as e:
        doc = None
        print("work: %s" % e, file=sys.stderr)
    try:
        ms = milestones(now, doc["items"] if doc else [])
        ms["synced"] = stamp
        with open(os.path.join(out, "work", "milestones.json"), "w", encoding="utf-8") as fh:
            json.dump(ms, fh, ensure_ascii=False, indent=1)
        print("milestones: %d" % len(ms["items"]))
    except Exception as e:
        print("milestones: %s" % e, file=sys.stderr)
    for key, fn in (("night", night), ("releases", lambda t: releases(t, out)), ("issues", lambda t: issue_talk(t, doc))):
        try:
            d = fn(now)
            d["synced"] = stamp
            with open(os.path.join(out, "work", key + ".json"), "w", encoding="utf-8") as fh:
                json.dump(d, fh, ensure_ascii=False, indent=1)
            print("%s: %d" % (key, len(d["items"])))
        except Exception as e:
            print("%s: %s" % (key, e), file=sys.stderr)


if __name__ == "__main__":
    main()
