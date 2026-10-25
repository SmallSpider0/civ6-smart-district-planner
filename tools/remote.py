#!/usr/bin/env python3
"""remote - run heavy offline jobs (compare.mjs, the oracle) on a second machine over ssh.

    python3 -I tools/remote.py sync                       # copy this worktree there
    python3 -I tools/remote.py run NAME -- node tools/compare.mjs ... --out logs/remote/NAME.jsonl
    python3 -I tools/remote.py status [NAME]              # running / exit code, last log line
    python3 -I tools/remote.py wait NAME [--fetch PATH ...] [--every 60]
    python3 -I tools/remote.py fetch PATH ...             # copy files back (paths relative to the worktree)

The host is $SDP_REMOTE (an ssh host name from ~/.ssh/config that logs in
without prompts, e.g. a key of its own with BatchMode). No game is needed
there: `sync` copies the worktree's files (tracked and new, not ignored), tools/node_modules and
tests/compare/.cache (following links) and the Lua sources under reference/
(only *.lua of base-ui; dmt, amt, ep, dwp whole) to ~/sdp-runs/<worktree
name>/ and ~/sdp-runs/ref/. Results there match this machine's except for
timing fields, so keep runs whose seconds get reported on one machine.

`run` starts the command under nohup in the copy (it keeps running when ssh
drops), with output in ~/sdp-runs/NAME.log and the exit code written to
~/sdp-runs/NAME.exit when it ends. `wait` checks every --every seconds until
that file exists (no process matching), then fetches the given paths and
exits with the job's exit code: start it in the background and its end is
the signal to carry on. Node there: $SDP_REMOTE_PATH is put in front of PATH
(default /opt/homebrew/bin:/usr/local/bin).
"""
import argparse
import os
import shlex
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = os.path.basename(ROOT)
BASE = "sdp-runs"
TREE = BASE + "/" + NAME


def host():
    h = os.environ.get("SDP_REMOTE")
    if not h:
        raise SystemExit("set SDP_REMOTE to the ssh host to use")
    return h


def ssh(command, check=True, capture=True):
    done = subprocess.run(["ssh", host(), command], capture_output=capture, text=True)
    if check and done.returncode != 0:
        raise SystemExit("ssh %s: %s" % (host(), (done.stderr or "").strip()))
    return done.stdout if capture else ""


def rsync(args):
    subprocess.run(["rsync", "-a", "-e", "ssh"] + args, check=True)


def env_path():
    return os.environ.get("SDP_REMOTE_PATH", "/opt/homebrew/bin:/usr/local/bin")


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
    print("synced %s to %s:~/%s" % (ROOT, h, TREE))
    return 0


def run(args):
    if not args.command:
        raise SystemExit("give the command after --")
    cmd = " ".join(shlex.quote(c) for c in args.command)
    log, code = "~/%s/%s.log" % (BASE, args.name), "~/%s/%s.exit" % (BASE, args.name)
    inner = "cd ~/%s && export PATH=%s:$PATH && %s; echo $? > %s" % (TREE, env_path(), cmd, code)
    ssh("rm -f %s; nohup sh -c %s > %s 2>&1 < /dev/null & echo started $!" % (code, shlex.quote(inner), log),
        capture=False)
    print("started %s on %s: %s (log %s)" % (args.name, host(), cmd, log))
    return 0


def state(name):
    out = ssh("cat ~/%s/%s.exit 2>/dev/null; echo ---; tail -1 ~/%s/%s.log 2>/dev/null" % (BASE, name, BASE, name),
              check=False)
    code, _, last = out.partition("---\n")
    return (int(code.strip()) if code.strip().lstrip("-").isdigit() else None), last.strip()


def status(args):
    names = [args.name] if args.name else [l[:-4] for l in ssh("cd ~/%s && ls *.log 2>/dev/null" % BASE,
                                                                   check=False).split() if l.endswith(".log")]
    for n in names:
        code, last = state(n)
        print("%-30s %-10s %s" % (n, "running" if code is None else "exit %d" % code, last[:120]))
    return 0


def fetch_paths(paths):
    h = host()
    for rel in paths:
        dest = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        rsync(["%s:%s/%s" % (h, TREE, rel), dest])
        print("fetched", rel)


def fetch(args):
    fetch_paths(args.paths)
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
        fetch_paths(args.fetch)
    print("%s %s ended with exit %d: %s" % (time.strftime("%H:%M"), args.name, code, last[:160]))
    return code


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sync")
    r = sub.add_parser("run")
    r.add_argument("name")
    r.add_argument("command", nargs=argparse.REMAINDER)
    s = sub.add_parser("status")
    s.add_argument("name", nargs="?")
    w = sub.add_parser("wait")
    w.add_argument("name")
    w.add_argument("--fetch", nargs="*", default=[])
    w.add_argument("--every", type=float, default=60)
    f = sub.add_parser("fetch")
    f.add_argument("paths", nargs="+")
    args = ap.parse_args()
    if args.cmd == "run" and args.command[:1] == ["--"]:
        args.command = args.command[1:]
    return {"sync": sync, "run": run, "status": status, "wait": wait, "fetch": fetch}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
