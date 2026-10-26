#!/usr/bin/env python3
"""sdplock - share the game, this machine's CPU and the night queue between sessions.

    python3 -I tools/sdplock.py status [--local]      # the game lock, local heavy jobs, night queue, the second machine
    python3 -I tools/sdplock.py take [--purpose TEXT] [--next | --stale | --force]
    python3 -I tools/sdplock.py release [--force]
    python3 -I tools/sdplock.py wait [--take] [--purpose TEXT] [--every 20]
    python3 -I tools/sdplock.py heavy NAME -- CMD ...  # one heavy local job, paused while the game is held
    python3 -I tools/sdplock.py queue add --what TEXT --why TEXT [--cmd CMD ...]
    python3 -I tools/sdplock.py queue list [--all]
    python3 -I tools/sdplock.py queue done ID [--failed] [--result TEXT]

Several sessions work at once, each in its own worktree, but there is one
game, one Tuner connection and one Mods folder. The game lock says which
worktree uses them. deploy.py, game.py, run_tests.py, realclick.py, shots.py,
stress.py and civ6tuner.py (serve, exec) take it by themselves and renew it
while they run; another worktree's call is refused with the holder's name
(exit code 4). `civ6tuner.py states` stays free for anyone, to look.
`game.py quit` releases the lock and stops the holder's Tuner daemon.

A lock not renewed for 30 minutes, while the game is closed or the holder's
Tuner daemon is gone, is stale: `take --stale` takes it over (quit the game
and start a new one; its state is unknown). `take --next` books the game for
the next turn (release tests go first): after the holder releases it, only
the booking worktree can take it for 15 minutes. `--force` overrides
everything; use it only when you know the holder is gone.

Heavy local jobs (compare.mjs, refresh_results.py) start through `heavy`:
one at a time on this machine, with at most the configured workers (`-j` is
lowered, or added, to fit), paused (SIGSTOP to the job's process group)
while the game lock is held and resumed when it is released. A job that was
paused reports it at the end: its timing fields are not usable.

The night queue lists the steps that take the screen (real clicks,
screenshots, the stress test, all rulesets) for a time when nobody uses the
machine; one session runs it.

Machine-specific settings come from a JSON file outside the repository,
$SDP_LOCAL_CONFIG, else ~/.config/sdp/local.json; all keys are optional:

    {"workers_day": 4,            # heavy local job workers (default 4)
     "workers_night": 6,          # in the night window (default: workers_day)
     "night": "00:00-08:00",      # the night window (default: none)
     "weekend_is_night": true,    # Saturday and Sunday count as night (default false)
     "remote": "build-box",       # tools/remote.py's host when $SDP_REMOTE is not set
     "remote_slots": 8,           # the second machine's slots (default: its cores - 2)
     "remote_path": "/opt/homebrew/bin:/usr/local/bin"}   # PATH there for node and python3

Everything lives in a folder shared by the worktrees and outside iCloud:
$SDP_SHARED, else ~/Library/Application Support/SDP (macOS),
%LOCALAPPDATA%\\SDP (Windows), ~/.local/share/sdp. The owner shown is
$SDP_OWNER, else the worktree's branch.
"""
import argparse
import contextlib
import json
import os
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STALE = 30 * 60      # seconds without renewal before a lock may be stale
RENEW = 60           # renew at most this often
BOOKING = 15 * 60    # how long a --next booking holds after the release
MUTEX_STALE = 30     # a mutex file older than this was left by a killed process
BUSY_EXIT = 4


class Busy(Exception):
    """Someone else holds what was asked for."""


# -- this machine's settings ------------------------------------------------
def config_path():
    return os.environ.get("SDP_LOCAL_CONFIG") or os.path.expanduser(os.path.join("~", ".config", "sdp", "local.json"))


def local_config():
    try:
        with open(config_path(), encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def remote_host():
    return os.environ.get("SDP_REMOTE") or local_config().get("remote") or None


# -- probes (replaced in tests) --------------------------------------------
def now():
    return time.time()


def localtime(t):
    return time.localtime(t)


def pid_alive(pid):
    if not pid:
        return False
    if sys.platform == "win32":
        import ctypes
        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))  # QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        code = ctypes.c_ulong()
        ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(handle)
        return code.value == 259  # STILL_ACTIVE
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def game_running():
    if sys.platform == "win32":  # CivilizationVI.exe or CivilizationVI_DX12.exe
        listed = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True, errors="replace")
        return "civilizationvi" in listed.stdout.lower()
    return subprocess.run(["pgrep", "-f", "Civ6_Exe"], capture_output=True).returncode == 0


def signal_group(pgid, sig):
    """Send sig to a job's process group; False where that cannot be done."""
    if not hasattr(os, "killpg"):
        return False
    try:
        os.killpg(int(pgid), sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def signal_pid(pid, sig):
    try:
        os.kill(int(pid), sig)
        return True
    except (ProcessLookupError, PermissionError, OSError):
        return False


# -- the shared folder -------------------------------------------------------
def shared_dir():
    if os.environ.get("SDP_SHARED"):
        return os.environ["SDP_SHARED"]
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/SDP")
    if sys.platform == "win32":
        return os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "SDP")
    return os.path.expanduser("~/.local/share/sdp")


def _path(*parts):
    return os.path.join(shared_dir(), *parts)


def _read(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def _write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


@contextlib.contextmanager
def _mutex(name="state", wait=10.0):
    """One writer at a time across processes: an exclusively created file."""
    os.makedirs(shared_dir(), exist_ok=True)
    path = _path("." + name + ".mutex")
    deadline = time.monotonic() + wait
    while True:
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(path) > MUTEX_STALE:
                    os.remove(path)
                    continue
            except OSError:
                continue
            if time.monotonic() > deadline:
                raise Busy("the lock files in %s are busy; try again" % shared_dir())
            time.sleep(0.05)
    try:
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
        yield
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


# -- who am I ---------------------------------------------------------------
def tree_of(root):
    return os.path.normcase(os.path.realpath(root))


def _git(root, *args):
    try:
        done = subprocess.run(["git"] + list(args), cwd=root, capture_output=True, text=True, timeout=10)
        return done.stdout.strip() if done.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def identity(root):
    branch = _git(root, "rev-parse", "--abbrev-ref", "HEAD")
    return {"tree": tree_of(root), "branch": branch, "commit": _git(root, "rev-parse", "--short", "HEAD"),
            "owner": os.environ.get("SDP_OWNER") or branch or os.path.basename(tree_of(root))}


# -- the game lock ------------------------------------------------------------
def game_path():
    return _path("game.json")


def load_game():
    return _read(game_path(), {"holder": None, "next": None, "released": None})


def is_stale(holder, t=None):
    t = now() if t is None else t
    if t - holder.get("renewed", 0) <= STALE:
        return False
    return not game_running() or (holder.get("serve_pid") and not pid_alive(holder["serve_pid"]))


def booking(state, t):
    """The --next booking still in force, else None."""
    nxt = state.get("next")
    if not nxt:
        return None
    if state.get("holder") or (state.get("released") and t - state["released"] < BOOKING):
        return nxt
    return None


def describe(holder, t=None):
    t = now() if t is None else t
    return "%s (%s, branch %s%s) since %s, last used %d min ago" % (
        holder.get("owner"), holder.get("purpose") or "no purpose given", holder.get("branch") or "?",
        ", " + holder["commit"] if holder.get("commit") else "",
        time.strftime("%H:%M", localtime(holder.get("since", t))), (t - holder.get("renewed", t)) // 60)


def _refusal(state, tree, t):
    """Why `tree` cannot use the game now, or None."""
    holder = state.get("holder")
    if holder and holder["tree"] != tree:
        msg = "the game is held by %s; tree %s" % (describe(holder, t), holder["tree"])
        if is_stale(holder, t):
            msg += ("\nthe lock is stale: `python3 -I tools/sdplock.py take --stale`, then quit the game "
                    "and start a new one")
        else:
            msg += "\nwait for it in the background: `python3 -I tools/sdplock.py wait --take --purpose ...`"
        return msg
    nxt = booking(state, t)
    if not holder and nxt and nxt["tree"] != tree:
        return "the game is booked for %s (%s) until %s" % (
            nxt.get("owner"), nxt.get("purpose") or "", time.strftime("%H:%M", localtime(state["released"] + BOOKING)))
    return None


def _become(state, root, purpose, t):
    me = identity(root)
    me.update({"purpose": purpose, "since": t, "renewed": t, "serve_pid": None})
    state["holder"] = me
    if state.get("next") and state["next"]["tree"] == me["tree"]:
        state["next"] = None
    _write(game_path(), state)
    pause_heavy()
    return me


def claim(root, purpose=None):
    """Use the game from `root`: take the lock when free, renew it when ours.
    Raises Busy when another worktree holds or booked it."""
    tree, t = tree_of(root), now()
    state = load_game()
    holder = state.get("holder")
    if holder and holder["tree"] == tree and t - holder.get("renewed", 0) < RENEW \
            and (purpose is None or purpose == holder.get("purpose")):
        return holder
    with _mutex():
        state, t = load_game(), now()
        refusal = _refusal(state, tree, t)
        if refusal:
            raise Busy(refusal)
        holder = state.get("holder")
        if holder:
            holder["renewed"] = t
            if purpose:
                holder["purpose"] = purpose
            _write(game_path(), state)
            return holder
        return _become(state, root, purpose, t)


def claim_or_exit(root, purpose=None):
    try:
        return claim(root, purpose)
    except Busy as problem:
        print("sdplock: %s" % problem, file=sys.stderr, flush=True)
        raise SystemExit(BUSY_EXIT)


def take(root, purpose=None, book=False, stale=False, force=False):
    """Explicit take. Returns a line saying what happened; raises Busy."""
    tree = tree_of(root)
    with _mutex():
        state, t = load_game(), now()
        holder = state.get("holder")
        if holder and holder["tree"] != tree:
            if book:
                nxt = booking(state, t)
                if nxt and nxt["tree"] != tree:
                    raise Busy("the next turn is already booked by %s (%s)" % (nxt.get("owner"), nxt.get("purpose")))
                me = identity(root)
                me.update({"purpose": purpose, "at": t})
                state["next"] = me
                _write(game_path(), state)
                return "booked the next turn after %s" % describe(holder, t)
            if not (force or (stale and is_stale(holder, t))):
                raise Busy(_refusal(state, tree, t))
            if holder.get("serve_pid") and pid_alive(holder["serve_pid"]):
                signal_pid(holder["serve_pid"], signal.SIGTERM)
            state["holder"] = None
            _become(state, root, purpose, t)
            return "took the game over from %s; quit the game and start a new one" % describe(holder, t)
        refusal = None if force else _refusal(state, tree, t)
        if refusal:
            raise Busy(refusal)
        if holder:
            holder["renewed"] = t
            if purpose:
                holder["purpose"] = purpose
            _write(game_path(), state)
            return "already held here; renewed"
        _become(state, root, purpose, t)
        return "game taken"


def release(root, force=False):
    tree = tree_of(root)
    with _mutex():
        state, t = load_game(), now()
        holder = state.get("holder")
        if not holder:
            return "the game was not held"
        if holder["tree"] != tree and not force:
            raise Busy("not released: held by %s" % describe(holder, t))
        if holder.get("serve_pid") and holder["serve_pid"] != os.getpid() and pid_alive(holder["serve_pid"]):
            signal_pid(holder["serve_pid"], signal.SIGTERM)
        state["holder"] = None
        state["released"] = t
        _write(game_path(), state)
    resume_heavy()
    return "game released"


def set_serve(root, pid):
    """Record the holder's Tuner daemon (stopped on release)."""
    claim(root, None)
    with _mutex():
        state = load_game()
        if state.get("holder") and state["holder"]["tree"] == tree_of(root):
            state["holder"]["serve_pid"] = pid
            _write(game_path(), state)


def can_use(root):
    state = load_game()
    return _refusal(state, tree_of(root), now()) is None


# -- heavy local jobs ---------------------------------------------------------
def jobs_dir():
    return _path("jobs")


def _minutes(text):
    hours, _, minutes = text.strip().partition(":")
    return int(hours) * 60 + int(minutes or 0)


def is_night(t=None, cfg=None):
    """Inside the configured night window (or a weekend, when configured so)."""
    cfg = local_config() if cfg is None else cfg
    lt = localtime(now() if t is None else t)
    if cfg.get("weekend_is_night") and lt.tm_wday >= 5:
        return True
    window = cfg.get("night")
    if not window or "-" not in window:
        return False
    start, end = (_minutes(x) for x in window.split("-", 1))
    m = lt.tm_hour * 60 + lt.tm_min
    return start <= m < end if start <= end else (m >= start or m < end)


def local_cap(t=None):
    """Workers a heavy local job may use now (local config; 4 without one)."""
    cfg = local_config()
    day = int(cfg.get("workers_day") or 4)
    return int(cfg.get("workers_night") or day) if is_night(t, cfg) else day


def heavy_jobs():
    """Registered jobs still alive (entries of dead ones are removed)."""
    out = []
    folder = jobs_dir()
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if not name.endswith(".json"):
            continue
        job = _read(os.path.join(folder, name), None)
        if job and pid_alive(job.get("pid")):
            out.append(job)
        else:
            with contextlib.suppress(OSError):
                os.remove(os.path.join(folder, name))
    return out


def _signal_jobs(paused):
    if not hasattr(signal, "SIGSTOP"):
        return []
    done = []
    for job in heavy_jobs():
        if bool(job.get("paused")) == paused:
            continue
        if signal_group(job["pid"], signal.SIGSTOP if paused else signal.SIGCONT):
            job["paused"] = paused
            if paused:
                job["pauses"] = job.get("pauses", 0) + 1
            _write(os.path.join(jobs_dir(), job["name"] + ".json"), job)
            done.append(job["name"])
    return done


def pause_heavy():
    names = _signal_jobs(True)
    if names:
        print("sdplock: paused heavy local job(s) while the game is held: %s" % ", ".join(names), flush=True)
    return names


def resume_heavy():
    names = _signal_jobs(False)
    if names:
        print("sdplock: resumed heavy local job(s): %s" % ", ".join(names), flush=True)
    return names


WORKER_TOOLS = ("compare.mjs", "refresh_results.py")


def fit_workers(cmd, cap):
    """The command with its -j lowered to cap (or added, for the tools that take one)."""
    cmd = list(cmd)
    for i, arg in enumerate(cmd[:-1]):
        if arg in ("-j", "--jobs"):
            try:
                if int(cmd[i + 1]) > cap:
                    cmd[i + 1] = str(cap)
            except ValueError:
                pass
            return cmd
    if any(os.path.basename(a) in WORKER_TOOLS for a in cmd):
        cmd += ["-j", str(cap)]
    return cmd


def run_heavy(root, name, cmd):
    """Run one heavy job here; returns its exit code."""
    cap = local_cap()
    fitted = fit_workers(cmd, cap)
    if fitted != list(cmd):
        print("sdplock: workers capped at %d: %s" % (cap, " ".join(fitted)), flush=True)
    path = os.path.join(jobs_dir(), name + ".json")
    with _mutex():
        others = heavy_jobs()
        if others:
            raise Busy("heavy local job %s of %s is running (one at a time here); use the second machine "
                       "(tools/remote.py) or wait for it" % (others[0]["name"], others[0].get("owner")))
        env = dict(os.environ, SDP_JOBS=str(cap))
        child = subprocess.Popen(fitted, cwd=root, env=env, start_new_session=True)
        me = identity(root)
        job = {"name": name, "pid": child.pid, "cmd": fitted, "owner": me["owner"], "tree": me["tree"],
               "started": now(), "workers": cap, "paused": False, "pauses": 0}
        _write(path, job)
    if load_game().get("holder"):
        pause_heavy()
        print("sdplock: the game is held, so %s waits until it is released" % name, flush=True)
    try:
        code = child.wait()
    except KeyboardInterrupt:
        signal_group(child.pid, signal.SIGTERM)
        code = child.wait()
    job = _read(path, job)
    with contextlib.suppress(OSError):
        os.remove(path)
    if job.get("pauses"):
        print("sdplock: %s was paused %d time(s) for the game: its timing fields are not usable"
              % (name, job["pauses"]), flush=True)
    return code


# -- the night queue ----------------------------------------------------------
def queue_path():
    return _path("night-queue.json")


def queue_add(root, what, why, cmds=()):
    with _mutex("queue"):
        items = _read(queue_path(), [])
        me = identity(root)
        item = {"id": max([i["id"] for i in items] or [0]) + 1, "added": now(), "owner": me["owner"],
                "tree": me["tree"], "branch": me["branch"], "what": what, "why": why, "cmds": list(cmds),
                "state": "queued", "result": None}
        items.append(item)
        _write(queue_path(), items)
    return item


def queue_done(item_id, failed=False, result=None):
    with _mutex("queue"):
        items = _read(queue_path(), [])
        for item in items:
            if item["id"] == item_id:
                item["state"] = "failed" if failed else "done"
                item["result"] = result
                item["finished"] = now()
                _write(queue_path(), items)
                return item
    raise Busy("no queue item %d" % item_id)


def queue_items(everything=False):
    items = _read(queue_path(), [])
    return items if everything else [i for i in items if i["state"] == "queued"]


# -- command line ---------------------------------------------------------------
def print_status(local_only):
    t = now()
    state = load_game()
    holder = state.get("holder")
    print("shared folder: %s" % shared_dir())
    if holder:
        print("game: held by %s%s" % (describe(holder, t), " -- STALE" if is_stale(holder, t) else ""))
        print("      tree %s%s" % (holder["tree"], ", Tuner daemon pid %s" % holder["serve_pid"]
                                    if holder.get("serve_pid") else ""))
    else:
        print("game: free" + (" (game running without a holder)" if game_running() else ""))
    nxt = booking(state, t)
    if nxt:
        print("      next turn booked by %s (%s)" % (nxt.get("owner"), nxt.get("purpose") or ""))
    jobs = heavy_jobs()
    print("heavy local jobs (cap now %d workers, one job): %s" % (local_cap(t), "none" if not jobs else ""))
    for job in jobs:
        print("  %-24s %-8s %s, started %s, %s" % (job["name"], "PAUSED" if job.get("paused") else "running",
                                                 job.get("owner"), time.strftime("%H:%M", localtime(job["started"])),
                                                 " ".join(job["cmd"])[:100]))
    items = queue_items()
    print("night queue: %d item(s)" % len(items))
    for item in items:
        print("  #%d %s (%s, %s): %s" % (item["id"], item["what"], item["owner"], item["branch"], item["why"]))
    if not local_only and remote_host():
        print("second machine (%s):" % remote_host())
        try:
            done = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tools", "remote.py"), "status"],
                                  capture_output=True, text=True, timeout=30)
            sys.stdout.write(done.stdout or done.stderr)
        except subprocess.TimeoutExpired:
            print("  no answer in 30 s")


def wait_free(root, every, take_it, purpose):
    shown = None
    while True:
        try:
            if take_it:
                print(take(root, purpose))
                return 0
            if can_use(root):
                print("game free")
                return 0
        except Busy as problem:
            line = str(problem).splitlines()[0]
            if line != shown:
                print("%s waiting: %s" % (time.strftime("%H:%M"), line), flush=True)
                shown = line
        time.sleep(every)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("status")
    s.add_argument("--local", action="store_true", help="skip the second machine")
    t = sub.add_parser("take")
    t.add_argument("--purpose")
    group = t.add_mutually_exclusive_group()
    group.add_argument("--next", action="store_true", help="book the next turn (release tests)")
    group.add_argument("--stale", action="store_true", help="take over a stale lock")
    group.add_argument("--force", action="store_true", help="take it whatever its state")
    r = sub.add_parser("release")
    r.add_argument("--force", action="store_true")
    w = sub.add_parser("wait")
    w.add_argument("--take", action="store_true", help="take the game as soon as it is free")
    w.add_argument("--purpose")
    w.add_argument("--every", type=float, default=20)
    h = sub.add_parser("heavy")
    h.add_argument("name")
    h.add_argument("command", nargs=argparse.REMAINDER)
    q = sub.add_parser("queue")
    qs = q.add_subparsers(dest="qcmd", required=True)
    qa = qs.add_parser("add")
    qa.add_argument("--what", required=True)
    qa.add_argument("--why", required=True)
    qa.add_argument("--cmd", action="append", default=[])
    ql = qs.add_parser("list")
    ql.add_argument("--all", action="store_true")
    qd = qs.add_parser("done")
    qd.add_argument("id", type=int)
    qd.add_argument("--failed", action="store_true")
    qd.add_argument("--result")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "status":
            print_status(args.local)
        elif args.cmd == "take":
            print(take(ROOT, args.purpose, book=args.next, stale=args.stale, force=args.force))
        elif args.cmd == "release":
            print(release(ROOT, args.force))
        elif args.cmd == "wait":
            return wait_free(ROOT, args.every, args.take, args.purpose)
        elif args.cmd == "heavy":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            if not command:
                raise SystemExit("give the command after --")
            return run_heavy(ROOT, args.name, command)
        elif args.qcmd == "add":
            item = queue_add(ROOT, args.what, args.why, args.cmd)
            print("queued #%d" % item["id"])
        elif args.qcmd == "list":
            for item in queue_items(args.all):
                print("#%d %-7s %s | %s | %s | %s\n    %s" % (
                    item["id"], item["state"], item["owner"], item["branch"], item["what"], item["why"],
                    "\n    ".join(item["cmds"]) or "(no commands)"))
                if item.get("result"):
                    print("    result: %s" % item["result"])
        elif args.qcmd == "done":
            queue_done(args.id, args.failed, args.result)
            print("#%d marked %s" % (args.id, "failed" if args.failed else "done"))
    except Busy as problem:
        print("sdplock: %s" % problem, file=sys.stderr)
        return BUSY_EXIT
    return 0


if __name__ == "__main__":
    sys.exit(main())
