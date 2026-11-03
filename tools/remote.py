#!/usr/bin/env python3
"""remote - run heavy offline jobs (compare.mjs, the oracle) on a second machine over ssh, or here.

    python3 -I tools/remote.py sync                       # copy this worktree there (run does it too)
    python3 -I tools/remote.py run NAME [--slots N | --exclusive | --remote-only] -- node tools/compare.mjs ... --out logs/remote/NAME.jsonl
    python3 -I tools/remote.py direct -- node tools/offline_tests.mjs ...   # what tools/place.mjs calls

Placement (#249): `run` starts the job there when it can start there now; else, when this machine's heavy
slot is free and the game lock is not held, here in a snapshot of the worktree (the shared folder's
runs/snap/NAME/) through sdplock.py heavy; else it queues there. --exclusive and --remote-only jobs always
go there. status, wait and fetch --job work the same for a job placed here. `direct` runs short
offline_tests.mjs / compare.mjs runs here, registered, and places long ones the same way, waiting for them.
    python3 -I tools/remote.py status [NAME]              # every session's jobs, free slots / one job
    python3 -I tools/remote.py wait NAME [--fetch PATH ...] [--every 60]
    python3 -I tools/remote.py fetch [--job NAME] PATH ...  # copy files back (paths relative to the worktree)
    python3 -I tools/remote.py clean [--dry-run] [--keep-days N]  # delete what old and gone worktrees left there

The host is $SDP_REMOTE, else "remote" in the local config (tools/sdplock.py:
~/.config/sdp/local.json, outside the repository): an ssh host name from
~/.ssh/config that logs in without prompts, e.g. a key of its own with BatchMode. No game is needed
there: `sync` copies the worktree's files (tracked and new, not ignored), tools/node_modules and
tests/compare/.cache (following links) and the Lua sources under reference/
(only *.lua of base-ui; dmt, amt, ep, dwp whole) to ~/sdp-runs/<worktree
name>/ and ~/sdp-runs/ref/. Results there match this machine's except for
timing fields, so keep runs whose seconds get reported on one machine.

`run` syncs first, then clones the copy (APFS clone: instant, no extra space) to
~/sdp-runs/snap/NAME/, so a later `sync` does not change files under a
running job, and starts the command there under nohup (it keeps running when
ssh drops) through tools/sdpsched.py, the machine's one queue for all
sessions: its cores minus two slots ("remote_slots" in the local config to
change), a job takes --slots N (default: the command's -j, else all slots;
a larger -j is lowered to N) and starts when N slots are free after the jobs
ahead of it have taken theirs; a later job that fits may start ahead of one
that does not, at most three times per waiting job (see sdpsched.py);
--exclusive waits for an empty machine and keeps it (runs whose seconds get
reported). A name already queued or running is refused. Output
goes to ~/sdp-runs/NAME.log and the exit code to ~/sdp-runs/NAME.exit when it
ends. `status` lists every session's jobs and the slots in use; look before
starting a heavy job anywhere. `wait` and `fetch --job` copy results back
from the job's snapshot. `wait` checks every --every seconds until
that file exists (no process matching), then fetches the given paths and
exits with the job's exit code: start it in the background and its end is
the signal to carry on. `clean` removes there (tools/sdpsched.py prune): jobs that ended over --keep-days (default 7) ago with their
snapshot, log, exit file and record; copies of worktrees that no longer exist (`git worktree list` here)
and the jobs started from them after a day; copies nobody synced for --keep-days. A queued or running job's
files stay. `--dry-run` lists what would go. `tools/worktree.py prune --remote` runs it too, after it has
removed the merged worktrees, and `run` runs the age rule before it starts a job.
Node and python3 there: $SDP_REMOTE_PATH (or
"remote_path" in the local config) is put in front of PATH (default
/opt/homebrew/bin:/usr/local/bin).
"""
import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import sdplock  # noqa: E402
import sdpsched  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = os.path.basename(ROOT)
BASE = "sdp-runs"
TREE = BASE + "/" + NAME


def host():
    h = sdplock.remote_host()
    if not h:
        raise SystemExit("set SDP_REMOTE (or \"remote\" in %s) to the ssh host to use" % sdplock.config_path())
    return h


def ssh(command, check=True, capture=True, input_text=None):
    done = subprocess.run(["ssh", "-o", "ConnectTimeout=15", host(), command], capture_output=capture, text=True,
                          input=input_text)
    if check and done.returncode != 0:
        why = (done.stderr or "").strip() if capture else "the output above"
        raise SystemExit("ssh %s: exit %d: %s" % (host(), done.returncode, why or "no message"))
    return done.stdout if capture else ""


def rsync(args):
    subprocess.run(["rsync", "-a", "-e", "ssh"] + args, check=True)


def env_path():
    return (os.environ.get("SDP_REMOTE_PATH") or sdplock.local_config().get("remote_path")
            or "/opt/homebrew/bin:/usr/local/bin")


def remote_env():
    slots = sdplock.local_config().get("remote_slots")
    return "export PATH=%s:$PATH %s=1%s" % (env_path(), sdplock.PLACED, " SDP_SLOTS=%d" % int(slots) if slots else "")


def install_sched():
    """The queue's script, the same for every worktree's jobs."""
    ssh("mkdir -p %s/bin %s/snap" % (BASE, BASE))
    rsync([os.path.join(ROOT, "tools", "sdpsched.py"), "%s:%s/bin/sdpsched.py" % (host(), BASE)])


def sched(args, check=True, capture=True):
    return ssh("%s && python3 ~/%s/bin/sdpsched.py %s" % (remote_env(), BASE, args), check=check, capture=capture)


def sync(_args):
    h = host()
    ssh("mkdir -p %s/ref %s/reference %s/logs/remote" % (BASE, TREE, TREE))
    files = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT, capture_output=True, check=True).stdout
    subprocess.run(["rsync", "-a", "--from0", "--files-from=-", "-e", "ssh", "./", "%s:%s/" % (h, TREE)],
                   cwd=ROOT, input=files, check=True)
    for rel in ("tools/node_modules", "tests/compare/.cache"):
        src = os.path.join(ROOT, rel)
        if os.path.exists(src):
            ssh("rm -f %s/%s" % (TREE, rel), check=False)  # an old link would be followed
            rsync(["-L", src.rstrip("/"), "%s:%s/%s/" % (h, TREE, os.path.dirname(rel))])
    ref = os.path.join(ROOT, "reference")
    for name in ("base-ui", "dmt", "amt", "ep", "dwp"):
        src = os.path.join(ref, name)
        if not os.path.isdir(src):
            continue
        only_lua = ["--include=*/", "--include=*.lua", "--exclude=*", "--prune-empty-dirs"] if name == "base-ui" else []
        rsync(["-L"] + only_lua + [src + "/", "%s:%s/ref/%s/" % (h, BASE, name)])
        ssh("ln -sfn ~/%s/ref/%s %s/reference/%s" % (BASE, name, TREE, name))
    ssh("touch %s/%s" % (TREE, sdpsched.SYNCED))  # tells sdpsched.py prune the copy is in use
    install_sched()
    print("synced %s to %s:~/%s" % (ROOT, h, TREE))
    return 0


# -- jobs placed on this machine (#249) ------------------------------------------
def runs_dir(*parts):
    """This machine's remote.py jobs: NAME.json (record), NAME.log, NAME.exit, snap/NAME/ (the snapshot)."""
    return sdplock._path("runs", *parts)


def local_record(name):
    return sdplock._read(runs_dir(name + ".json"), None) if name else None


def read_exit(path):
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read().strip()
        return int(text) if text.lstrip("-").isdigit() else None
    except OSError:
        return None


def last_log_line(path):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 4096))
            lines = fh.read().decode("utf-8", "replace").strip().splitlines()
        return lines[-1] if lines else ""
    except OSError:
        return ""


def local_state(rec):
    """(exit code or None while it runs, last log line) of a job placed here."""
    name = rec["name"]
    code, last = read_exit(runs_dir(name + ".exit")), last_log_line(runs_dir(name + ".log"))
    if code is None and not sdplock.pid_alive(rec.get("pid")):
        return 1, "its runner is gone without an exit code: " + last
    return code, last


def local_live(name):
    rec = local_record(name)
    return bool(rec) and local_state(rec)[0] is None


def local_free():
    """This machine's heavy slot is free: no heavy job, nobody waiting for it, and the game lock not held."""
    return not sdplock.heavy_jobs() and not sdplock.heavy_waiting() and not sdplock.load_game().get("holder")


def remote_fits(name, slots):
    """'yes' when a job of that many slots (0 = all) would start there now, 'taken' when the name is queued or
    running there, else 'no' (also when ssh fails). The query runs this worktree's sdpsched.py from stdin,
    so it does not depend on the copy there."""
    with open(os.path.join(ROOT, "tools", "sdpsched.py"), encoding="utf-8") as fh:
        source = fh.read()
    try:
        out = ssh("%s && python3 - fits --slots %d --name %s" % (remote_env(), slots, shlex.quote(name)),
                  input_text=source)
    except SystemExit:
        return "no"
    out = out.strip()
    return out if out in ("yes", "taken") else "no"


def snapshot(src, dest):
    """Copy the worktree's files (tracked and new, not ignored) to dest, and link what sync copies
    (tools/node_modules, tests/compare/.cache, reference/*): later edits do not reach a running job."""
    if os.path.exists(dest):
        shutil.rmtree(dest)
    files = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=src,
                           capture_output=True, check=True).stdout.decode("utf-8").split("\0")
    for rel in filter(None, files):
        path = os.path.join(src, rel)
        if os.path.isfile(path):
            os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
            shutil.copy2(path, os.path.join(dest, rel))
    links = ["tools/node_modules", "tests/compare/.cache"]
    if os.path.isdir(os.path.join(src, "reference")):
        links += ["reference/" + n for n in sorted(os.listdir(os.path.join(src, "reference")))]
    for rel in links:
        path = os.path.join(src, rel)
        if os.path.isdir(path) and not os.path.lexists(os.path.join(dest, rel)):
            os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
            link(os.path.realpath(path), os.path.join(dest, rel))
    os.makedirs(os.path.join(dest, "logs", "remote"), exist_ok=True)


def link(target, path):
    try:
        os.symlink(target, path, target_is_directory=os.path.isdir(target))
    except OSError:
        if sys.platform != "win32":
            raise
        subprocess.run(["cmd", "/c", "mklink", "/J", path, target], check=True, capture_output=True)


def prune_local(keep_days=7.0, dry_run=False):
    """Remove jobs placed here that ended over keep_days ago, with their snapshot, log and exit file."""
    t = sdplock.now()
    out = []
    folder = runs_dir()
    for entry in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if not entry.endswith(".json"):
            continue
        name = entry[:-5]
        rec = local_record(name) or {"name": name}
        exit_path = runs_dir(name + ".exit")
        ended = os.path.getmtime(exit_path) if os.path.exists(exit_path) else None
        if local_state(rec)[0] is None or ended is None and sdplock.pid_alive(rec.get("pid")):
            continue
        if t - (ended or rec.get("started", 0)) < keep_days * 86400:
            continue
        out.append(name)
        if not dry_run:
            forget_local(name)
    return out


def forget_local(name):
    shutil.rmtree(runs_dir("snap", name), ignore_errors=True)
    for ext in (".json", ".log", ".exit"):
        if os.path.exists(runs_dir(name + ext)):
            os.remove(runs_dir(name + ext))


def run_here(args, command):
    """Start the job on this machine, detached, in a snapshot of this worktree, through sdplock.py heavy."""
    prune_local()
    forget_local(args.name)
    snap = runs_dir("snap", args.name)
    snapshot(ROOT, snap)
    me = sdplock.identity(ROOT)
    log = runs_dir(args.name + ".log")
    os.makedirs(runs_dir(), exist_ok=True)
    with open(log, "w") as out:
        child = sdplock.spawn([sys.executable, "-I", os.path.join(snap, "tools", "remote.py"), "local-run", args.name,
                               "--owner", me["owner"], "--tree", me["tree"], "--"] + command,
                              cwd=snap, stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                              start_new_session=True, env=dict(os.environ, **{sdplock.PLACED: "1"}))
    sdplock._write(runs_dir(args.name + ".json"), {
        "name": args.name, "pid": child.pid, "owner": me["owner"], "tree": me["tree"], "session": sdplock.session(),
        "cmd": command, "snap": snap, "started": sdplock.now()})
    print("started %s on this machine (the second machine cannot start it now and the heavy slot here is free; "
          "snapshot %s, log %s): %s" % (args.name, snap, log, " ".join(command)))
    return 0


def local_run(args):
    """In the snapshot: the job through sdplock.py heavy, then its exit code for wait."""
    code = 143
    try:
        me = {"owner": args.owner, "tree": args.tree}
        code = sdplock.run_heavy(ROOT, args.name, args.command, me=me)
    finally:
        os.makedirs(runs_dir(), exist_ok=True)
        with open(runs_dir(args.name + ".exit"), "w") as fh:
            fh.write("%d\n" % code)
    return code


def run(args):
    if not args.command:
        raise SystemExit("give the command after --")
    if local_live(args.name):
        raise SystemExit("a job named %s runs on this machine; pick another name (tools/remote.py status)" % args.name)
    args.command = relative_args(args.command)  # run in a snapshot: absolute worktree paths would miss it
    slots = 0 if args.exclusive else (args.slots or sdpsched.workers_of(" ".join(args.command)) or 0)
    if not args.exclusive and not getattr(args, "remote_only", False) and local_free():
        where = remote_fits(args.name, slots)
        if where == "taken":
            raise SystemExit("a job named %s is queued or running there; pick another name "
                             "(tools/remote.py status)" % args.name)
        if where == "no":
            return run_here(args, list(args.command))
    forget_local(args.name)  # an old job of this name here would shadow the new one in wait and fetch
    # the job runs on a clone of this worktree's copy there: copy the files first, or a worktree that was
    # never synced has no copy (cp fails, #210) and one synced earlier runs old code
    sync(args)
    if sched("check %s" % shlex.quote(args.name), check=False).strip():
        raise SystemExit("a job named %s is queued or running there; pick another name "
                         "(tools/remote.py status)" % args.name)
    command = sdplock.fit_workers(args.command, slots) if slots else list(args.command)
    cmd = " ".join(shlex.quote(c) for c in command)
    me = sdplock.identity(ROOT)
    snap = "~/%s/snap/%s" % (BASE, args.name)
    log, code = "~/%s/%s.log" % (BASE, args.name), "~/%s/%s.exit" % (BASE, args.name)
    queue = "python3 ~/%s/bin/sdpsched.py run %s --slots %d %s--owner %s --tree %s -- sh -c %s" % (
        BASE, shlex.quote(args.name), slots, "--exclusive " if args.exclusive else "", shlex.quote(me["owner"]),
        shlex.quote(NAME), shlex.quote(cmd))
    # remote_env first: without its PATH, python3 there may be a stub that fails (macOS asks for the Xcode license).
    ssh("%s && (python3 ~/%s/bin/sdpsched.py prune >/dev/null 2>&1; true) && rm -rf %s %s && (cp -c -R ~/%s %s || cp -R ~/%s %s) "
        "&& cd %s && (nohup %s > %s 2>&1 < /dev/null &) && echo queued" % (
            remote_env(), BASE, snap, code, TREE, snap, TREE, snap, snap, queue, log), capture=False)
    print("queued %s on %s (%s%s; snapshot %s): %s (log %s)"
          % (args.name, host(), "%d slot(s)" % slots if slots else "all slots", ", exclusive" if args.exclusive else "",
             snap, cmd, log))
    return 0


def worktree_names():
    """Names of the worktrees (and the main checkout) that exist here: the names of the copies there."""
    out = subprocess.run(["git", "worktree", "list", "--porcelain"], cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("git worktree list: %s" % out.stderr.strip())
    names = {NAME}
    for line in out.stdout.splitlines():
        if line.startswith("worktree "):
            names.add(os.path.basename(line[len("worktree "):].rstrip("/")))
    return sorted(names)


def clean(args):
    for name in prune_local(args.keep_days if args.keep_days is not None else 7.0, args.dry_run):
        print("%s job %s placed on this machine" % ("would remove" if args.dry_run else "removed", name))
    if not sdplock.remote_host():
        return 0
    install_sched()
    cmd = "prune --known %s%s%s" % (" ".join(shlex.quote(n) for n in worktree_names()),
                                    " --dry-run" if args.dry_run else "",
                                    " --keep-days %s" % args.keep_days if args.keep_days is not None else "")
    out = sched(cmd)
    sys.stdout.write(out)
    return 0


def state(name):
    rec = local_record(name)
    if rec:
        return local_state(rec)
    out = ssh("cat ~/%s/%s.exit 2>/dev/null; echo ---; tail -1 ~/%s/%s.log 2>/dev/null" % (BASE, name, BASE, name),
              check=False)
    code, _, last = out.partition("---\n")
    return (int(code.strip()) if code.strip().lstrip("-").isdigit() else None), last.strip()


def status(args):
    if args.name:
        code, last = state(args.name)
        print("%-30s %-10s %-12s %s" % (args.name, "running" if code is None else "exit %d" % code,
                                       "this machine" if local_record(args.name) else host(), last[:120]))
        return 0
    t = sdplock.now()
    rows = []
    for entry in sorted(os.listdir(runs_dir())) if os.path.isdir(runs_dir()) else []:
        rec = local_record(entry[:-5]) if entry.endswith(".json") else None
        if not rec:
            continue
        code, last = local_state(rec)
        if code is not None and t - rec.get("started", t) > 86400:
            continue
        rows.append("%-24s %-9s %-22s %-7s %s" % (rec["name"], "running" if code is None else "exit %d" % code,
                                                   (rec.get("owner") or "?")[:22],
                                                   "%dmin" % ((t - rec.get("started", t)) // 60), last[:90]))
    if rows:
        print("this machine (remote.py run placed them here):")
        print("\n".join(rows))
    if sdplock.remote_host():
        if rows:
            print("second machine (%s):" % host())
        install_sched()
        sys.stdout.write(sched("status", check=False))
    return 0


def fetch_paths(paths, job=None):
    rec = local_record(job)
    if rec:  # placed on this machine: copy from its snapshot
        for rel in paths:
            dest = os.path.join(ROOT, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(os.path.join(rec["snap"], rel), dest)
            print("fetched", rel)
        return
    h = host()
    where = "%s/snap/%s" % (BASE, job) if job else TREE
    if job and ssh("test -d %s && echo yes" % where, check=False).strip() != "yes":
        where = TREE  # a job started before snapshots
    for rel in paths:
        dest = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        rsync(["%s:%s/%s" % (h, where, rel), dest])
        print("fetched", rel)


def fetch(args):
    fetch_paths(args.paths, args.job)
    return 0


def wait(args):
    checks = 0
    while True:
        try:
            code, last = state(args.name)
        except SystemExit as problem:  # the network: keep waiting
            code, last = None, "ssh problem: %s" % problem
        if code is not None:
            break
        checks += 1
        if checks % 10 == 0:
            print("%s %s" % (time.strftime("%H:%M"), last[:120]), flush=True)
        time.sleep(args.every)
    if args.fetch:
        fetch_paths(args.fetch, args.name)
    print("%s %s ended with exit %d: %s" % (time.strftime("%H:%M"), args.name, code, last[:160]))
    return code

# -- direct runs of offline_tests.mjs and compare.mjs (#249) ---------------------------------
LONG = 60  # seconds: a run expected to take longer is placed like remote.py run
LONG_FILES = ("spec_multi",)  # known to take minutes, before a time of theirs is recorded
SHORT_COMPARE = ("--list", "--dump", "--snapshot", "--probe", "--reference-only")  # compare.mjs modes that take seconds


def durations_path():
    return sdplock._path("durations.json")


def durations():
    data = sdplock._read(durations_path(), {})
    return data if isinstance(data, dict) else {}


def record_duration(key, seconds):
    with sdplock._mutex("durations"):
        data = durations()
        data[key] = round(seconds, 1)
        sdplock._write(durations_path(), data)


def option(cmd, flag):
    return cmd[cmd.index(flag) + 1] if flag in cmd[:-1] else None


def estimate(cmd):
    """(key under which its time is recorded or None, expected seconds) of a direct run."""
    script = next((os.path.basename(a) for a in cmd if a.endswith(".mjs")), "")
    if script == "compare.mjs":
        return None, 0 if any(a in SHORT_COMPARE for a in cmd) else float("inf")
    files = [os.path.basename(a)[:-4] for a in cmd if a.endswith(".lua")]
    if not files:
        return None, float("inf")  # the whole suite
    known = durations()
    total = 0
    for f in files:
        if f in known:
            total += known[f]
        elif f in LONG_FILES or f.startswith("bench_"):
            return None, float("inf")
    one = files[0] if len(files) == 1 and "-k" not in cmd else None  # the time of exactly that file
    return one, total


def can_go_remote(cmd, cwd):
    """The second machine can run it from the copy there and give its results back: started from the
    worktree's root, no benchmark (they write files), every file it names inside the worktree and copied
    by sync (not ignored)."""
    if os.path.realpath(cwd) != os.path.realpath(ROOT) or not sdplock.remote_host():
        return False
    if any(os.path.basename(a).startswith("bench_") for a in cmd):
        return False
    out = option(cmd, "--out")
    for i, a in enumerate(cmd[1:], 1):
        if cmd[i - 1] == "--out" or a.startswith("-") or not (os.sep in a or "/" in a or os.path.exists(a)):
            continue
        path = os.path.realpath(os.path.join(cwd, a))
        if not path.startswith(os.path.realpath(ROOT) + os.sep):
            return False
        if os.path.exists(path) and subprocess.run(["git", "check-ignore", "-q", path], cwd=ROOT).returncode == 0:
            return False
    if out and not os.path.realpath(os.path.join(cwd, out)).startswith(os.path.realpath(ROOT) + os.sep):
        return False
    return True


def relative_args(cmd):
    """The command with every absolute path into this worktree made relative to its root: the job runs in a
    snapshot (here or on the second machine), where the worktree's absolute paths name the wrong files."""
    root = os.path.realpath(ROOT)
    result = list(cmd[:1])
    for a in cmd[1:]:
        if os.path.isabs(a):
            path = os.path.realpath(a)
            if path.startswith(root + os.sep):
                a = os.path.relpath(path, root)
        result.append(a)
    return result


def outputs(cmd):
    """Files a compare.mjs run writes, relative to the worktree (fetched back after a remote run)."""
    if not any(os.path.basename(a) == "compare.mjs" for a in cmd):
        return []
    out = option(cmd, "--out") or os.path.join("tests", "compare", "results", "latest.jsonl")
    return [os.path.relpath(os.path.realpath(os.path.join(ROOT, out)), os.path.realpath(ROOT))]


def direct_name(cmd):
    files = [os.path.basename(a)[:-4] for a in cmd if a.endswith(".lua")]
    script = next((os.path.basename(a)[:-4] for a in cmd if a.endswith(".mjs")), "run")
    base = re.sub(r"[^\w-]", "", "-".join([script] + files[:2]))[:40]
    return "%s-%s-%d" % (base, time.strftime("%H%M%S"), os.getpid())


def direct(args):
    """What tools/offline_tests.mjs and tools/compare.mjs do when started by hand: short runs (by the times
    recorded for each test file) run here, registered; long ones go where remote.py run would put them --
    the second machine when it can start them now, this machine's heavy slot when that is free, else the
    second machine's queue -- and this process waits for them, then prints their output."""
    cmd, cwd = list(args.command), os.getcwd()
    me = sdplock.identity(ROOT)
    name = direct_name(cmd)
    env = dict(os.environ, **{sdplock.PLACED: "1"})
    # this process and the node process that called it wait for the run: registered, not shown
    sdplock.light_register(name + "-caller", [os.getpid(), os.getppid()], ROOT, cmd, show=False, me=me)
    try:
        key, seconds = estimate(cmd)
        if seconds < LONG:
            return run_short(name, cmd, cwd, env, key, me)
        if can_go_remote(cmd, cwd) and not (local_free() and remote_fits(name, slots_of(cmd)) == "no"):
            try:
                return run_remote_and_wait(name, relative_args(cmd))
            except SystemExit as problem:
                print("remote.py: the second machine cannot take %s (%s); running it here" % (name, problem),
                      file=sys.stderr, flush=True)
        print("remote.py: %s runs on this machine through sdplock.py heavy" % name, file=sys.stderr, flush=True)
        return sdplock.run_heavy(cwd, name, cmd, me=me)
    finally:
        sdplock.light_forget(name + "-caller")


def slots_of(cmd):
    if any(os.path.basename(a) == "compare.mjs" for a in cmd):
        return sdpsched.workers_of(" ".join(cmd)) or 4  # compare.mjs's own default
    return 1  # offline_tests.mjs: one process


def run_short(name, cmd, cwd, env, key, me):
    start = time.time()
    child = sdplock.spawn(cmd, cwd=cwd, env=env)  # same process group: Ctrl-C reaches it
    sdplock.light_register(name, [child.pid], ROOT, cmd, me=me)
    try:
        code = child.wait()
    except KeyboardInterrupt:
        code = child.wait()
    finally:
        sdplock.light_forget(name)
    if key and code in (0, 1):  # a run that ended normally (1: a test failed)
        record_duration(key, time.time() - start)
    return code


def run_remote_and_wait(name, cmd):
    slots = slots_of(cmd)
    run(argparse.Namespace(name=name, slots=slots, exclusive=False, remote_only=True,
                           command=sdplock.fit_workers(cmd, slots)))
    print("remote.py: %s runs on %s; waiting (remote.py status %s)" % (name, host(), name), file=sys.stderr,
          flush=True)
    code = wait(argparse.Namespace(name=name, fetch=outputs(cmd), every=15))
    sys.stdout.write(ssh("cat ~/%s/%s.log" % (BASE, name), check=False))
    return code


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sync")
    r = sub.add_parser("run")
    r.add_argument("name")
    group = r.add_mutually_exclusive_group()
    group.add_argument("--slots", type=int, help="slots (workers) for the job; default the command's -j, else 8")
    group.add_argument("--exclusive", action="store_true", help="wait for an empty machine and keep it")
    r.add_argument("--remote-only", action="store_true",
                   help="queue there even when this machine's heavy slot is free")
    s = sub.add_parser("status")
    s.add_argument("name", nargs="?")
    w = sub.add_parser("wait")
    w.add_argument("name")
    w.add_argument("--fetch", nargs="*", default=[])
    w.add_argument("--every", type=float, default=60)
    c = sub.add_parser("clean")
    c.add_argument("--dry-run", action="store_true")
    c.add_argument("--keep-days", type=float, help="how old a finished job or an unused copy must be (default 7)")
    lr = sub.add_parser("local-run")  # started by run in the snapshot of a job placed here
    lr.add_argument("name")
    lr.add_argument("--owner", default="")
    lr.add_argument("--tree", default="")
    sub.add_parser("direct")  # tools/offline_tests.mjs and tools/compare.mjs, started by hand
    f = sub.add_parser("fetch")
    f.add_argument("--job", help="take the files from this job's snapshot")
    f.add_argument("paths", nargs="+")
    argv = sys.argv[1:]
    split = argv.index("--") if "--" in argv else len(argv)
    args = ap.parse_args(argv[:split])
    args.command = argv[split + 1:]
    return {"sync": sync, "run": run, "status": status, "wait": wait, "fetch": fetch, "clean": clean,
            "local-run": local_run, "direct": direct}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
