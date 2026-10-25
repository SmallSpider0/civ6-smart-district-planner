#!/usr/bin/env python3
"""remote - run heavy offline jobs (compare.mjs, the oracle) on a second machine over ssh.

    python3 -I tools/remote.py sync                       # copy this worktree there
    python3 -I tools/remote.py run NAME [--slots N | --exclusive] -- node tools/compare.mjs ... --out logs/remote/NAME.jsonl
    python3 -I tools/remote.py status [NAME]              # every session's jobs, free slots / one job
    python3 -I tools/remote.py wait NAME [--fetch PATH ...] [--every 60]
    python3 -I tools/remote.py fetch [--job NAME] PATH ...  # copy files back (paths relative to the worktree)

The host is $SDP_REMOTE, else "remote" in the local config (tools/sdplock.py:
~/.config/sdp/local.json, outside the repository): an ssh host name from
~/.ssh/config that logs in without prompts, e.g. a key of its own with BatchMode. No game is needed
there: `sync` copies the worktree's files (tracked and new, not ignored), tools/node_modules and
tests/compare/.cache (following links) and the Lua sources under reference/
(only *.lua of base-ui; dmt, amt, ep, dwp whole) to ~/sdp-runs/<worktree
name>/ and ~/sdp-runs/ref/. Results there match this machine's except for
timing fields, so keep runs whose seconds get reported on one machine.

`run` clones the copy (APFS clone: instant, no extra space) to
~/sdp-runs/snap/NAME/, so a later `sync` does not change files under a
running job, and starts the command there under nohup (it keeps running when
ssh drops) through tools/sdpsched.py, the machine's one queue for all
sessions: its cores minus two slots ("remote_slots" in the local config to
change), a job takes --slots N (default: the command's -j, else all slots;
a larger -j is lowered to N) and starts when it is first in line and N slots
are free; --exclusive waits for an empty machine and keeps it (runs whose
seconds get reported). A name already queued or running is refused. Output
goes to ~/sdp-runs/NAME.log and the exit code to ~/sdp-runs/NAME.exit when it
ends. `status` lists every session's jobs and the slots in use; look before
starting a heavy job anywhere. `wait` and `fetch --job` copy results back
from the job's snapshot. `wait` checks every --every seconds until
that file exists (no process matching), then fetches the given paths and
exits with the job's exit code: start it in the background and its end is
the signal to carry on. Node and python3 there: $SDP_REMOTE_PATH (or
"remote_path" in the local config) is put in front of PATH (default
/opt/homebrew/bin:/usr/local/bin).
"""
import argparse
import os
import shlex
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


def ssh(command, check=True, capture=True):
    done = subprocess.run(["ssh", host(), command], capture_output=capture, text=True)
    if check and done.returncode != 0:
        raise SystemExit("ssh %s: %s" % (host(), (done.stderr or "").strip()))
    return done.stdout if capture else ""


def rsync(args):
    subprocess.run(["rsync", "-a", "-e", "ssh"] + args, check=True)


def env_path():
    return (os.environ.get("SDP_REMOTE_PATH") or sdplock.local_config().get("remote_path")
            or "/opt/homebrew/bin:/usr/local/bin")


def remote_env():
    slots = sdplock.local_config().get("remote_slots")
    return "export PATH=%s:$PATH%s" % (env_path(), " SDP_SLOTS=%d" % int(slots) if slots else "")


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
    install_sched()
    print("synced %s to %s:~/%s" % (ROOT, h, TREE))
    return 0


def run(args):
    if not args.command:
        raise SystemExit("give the command after --")
    install_sched()
    if sched("check %s" % shlex.quote(args.name), check=False).strip():
        raise SystemExit("a job named %s is queued or running there; pick another name "
                         "(tools/remote.py status)" % args.name)
    slots = 0 if args.exclusive else (args.slots or sdpsched.workers_of(" ".join(args.command)) or 0)
    command = sdplock.fit_workers(args.command, slots) if slots else list(args.command)
    cmd = " ".join(shlex.quote(c) for c in command)
    me = sdplock.identity(ROOT)
    snap = "~/%s/snap/%s" % (BASE, args.name)
    log, code = "~/%s/%s.log" % (BASE, args.name), "~/%s/%s.exit" % (BASE, args.name)
    queue = "python3 ~/%s/bin/sdpsched.py run %s --slots %d %s--owner %s --tree %s -- sh -c %s" % (
        BASE, shlex.quote(args.name), slots, "--exclusive " if args.exclusive else "", shlex.quote(me["owner"]),
        shlex.quote(NAME), shlex.quote(cmd))
    ssh("python3 ~/%s/bin/sdpsched.py prune >/dev/null 2>&1; rm -rf %s %s && (cp -c -R ~/%s %s || cp -R ~/%s %s) && cd %s && %s && "
        "(nohup %s > %s 2>&1 < /dev/null &) && echo queued" % (
            BASE, snap, code, TREE, snap, TREE, snap, snap, remote_env(), queue, log), capture=False)
    print("queued %s on %s (%s%s; snapshot %s): %s (log %s)"
          % (args.name, host(), "%d slot(s)" % slots if slots else "all slots", ", exclusive" if args.exclusive else "",
             snap, cmd, log))
    return 0


def state(name):
    out = ssh("cat ~/%s/%s.exit 2>/dev/null; echo ---; tail -1 ~/%s/%s.log 2>/dev/null" % (BASE, name, BASE, name),
              check=False)
    code, _, last = out.partition("---\n")
    return (int(code.strip()) if code.strip().lstrip("-").isdigit() else None), last.strip()


def status(args):
    if args.name:
        code, last = state(args.name)
        print("%-30s %-10s %s" % (args.name, "running" if code is None else "exit %d" % code, last[:120]))
        return 0
    install_sched()
    sys.stdout.write(sched("status", check=False))
    return 0


def fetch_paths(paths, job=None):
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sync")
    r = sub.add_parser("run")
    r.add_argument("name")
    group = r.add_mutually_exclusive_group()
    group.add_argument("--slots", type=int, help="slots (workers) for the job; default the command's -j, else 8")
    group.add_argument("--exclusive", action="store_true", help="wait for an empty machine and keep it")
    s = sub.add_parser("status")
    s.add_argument("name", nargs="?")
    w = sub.add_parser("wait")
    w.add_argument("name")
    w.add_argument("--fetch", nargs="*", default=[])
    w.add_argument("--every", type=float, default=60)
    f = sub.add_parser("fetch")
    f.add_argument("--job", help="take the files from this job's snapshot")
    f.add_argument("paths", nargs="+")
    argv = sys.argv[1:]
    split = argv.index("--") if "--" in argv else len(argv)
    args = ap.parse_args(argv[:split])
    args.command = argv[split + 1:]
    return {"sync": sync, "run": run, "status": status, "wait": wait, "fetch": fetch}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
