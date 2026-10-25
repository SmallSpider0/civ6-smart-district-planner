#!/usr/bin/env python3
"""sdpsched - one queue for heavy jobs from all sessions on the second machine.

tools/remote.py copies this file to ~/sdp-runs/bin/ there and starts jobs
through it; it is not run on this machine.

    python3 sdpsched.py run NAME --slots N [--exclusive] [--owner WHO] [--tree T] -- CMD ...
    python3 sdpsched.py status            # every job: who, slots, queued / running / exit, last log line
    python3 sdpsched.py check NAME        # exit 1 when a job of that name is queued or running
    python3 sdpsched.py prune             # drop snapshots of jobs that ended over a week ago

The machine has SDP_SLOTS slots (default: its cores minus two, left for the
system). A job asks for N slots (its compare.mjs workers; 0 = all) and starts
when it is first in line and N slots are free; an exclusive job (timings that
get reported) waits for an empty machine and keeps it empty. compare.mjs
processes started some other way count with their -j (all slots without one).
`run` keeps going until the job ends: start it under nohup with its output in
~/sdp-runs/NAME.log; it writes the exit code to ~/sdp-runs/NAME.exit, as
tools/remote.py wait expects. The child gets SDP_JOBS=N.

Jobs are recorded in ~/sdp-runs/jobs/NAME.json ($SDP_RUNS for another base).
"""
import argparse
import contextlib
import json
import os
import re
import signal
import subprocess
import sys
import time

BASE = os.environ.get("SDP_RUNS") or os.path.expanduser("~/sdp-runs")
SLOTS = int(os.environ.get("SDP_SLOTS") or max(1, (os.cpu_count() or 4) - 2))
POLL = 15
LEGACY_FRESH = 2 * 3600  # a log without a job record or exit file, written this recently, is a running job
KEEP = 7 * 86400


def jobs_dir():
    return os.path.join(BASE, "jobs")


def job_path(name):
    return os.path.join(jobs_dir(), name + ".json")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False)
    os.replace(tmp, path)


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


@contextlib.contextmanager
def locked():
    import fcntl
    os.makedirs(jobs_dir(), exist_ok=True)
    with open(os.path.join(jobs_dir(), ".lock"), "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def load_jobs():
    out = []
    folder = jobs_dir()
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if name.endswith(".json"):
            job = read_json(os.path.join(folder, name))
            if job:
                out.append(job)
    return out


def live(job, alive=pid_alive):
    """Queued or running, with its scheduler still there."""
    if job.get("state") == "queued":
        return alive(job.get("sched_pid"))
    if job.get("state") == "running":
        return alive(job.get("pid")) or alive(job.get("sched_pid"))
    return False


def workers_of(command):
    """The -j of a command line, else None."""
    m = re.search(r"(?:^|\s)(?:-j|--jobs)\s+(\d+)", command)
    return int(m.group(1)) if m else None


def unregistered(ps_lines, known_groups):
    """Slots used by compare.mjs processes no job here started: {pgid: workers}."""
    groups = {}
    for line in ps_lines:
        parts = line.split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit() or "compare.mjs" not in parts[1] or "sdpsched" in parts[1]:
            continue
        pgid = int(parts[0])
        if pgid in known_groups:
            continue
        groups[pgid] = max(groups.get(pgid, 0), workers_of(parts[1]) or SLOTS)
    return groups


def ps_lines():
    done = subprocess.run(["ps", "-Ao", "pgid=,command="], capture_output=True, text=True)
    return done.stdout.splitlines()


def decide(jobs, other_slots=0, capacity=SLOTS, alive=pid_alive):
    """The queued job that may start now (first in line, if it fits), else None."""
    active = [j for j in jobs if live(j, alive)]
    running = [j for j in active if j["state"] == "running"]
    queued = sorted((j for j in active if j["state"] == "queued"), key=lambda j: (j["queued_at"], j["name"]))
    if not queued or any(j.get("exclusive") for j in running):
        return None
    used = sum(j["slots"] for j in running) + other_slots
    first = queued[0]
    if first.get("exclusive"):
        return first["name"] if used == 0 else None
    return first["name"] if used + min(first["slots"], capacity) <= capacity else None


def usage(jobs):
    """(slots used by jobs here, slots used by other compare.mjs processes)."""
    active = [j for j in jobs if live(j) and j["state"] == "running"]
    groups = unregistered(ps_lines(), {j.get("pid") for j in active})
    return sum(j["slots"] for j in active), sum(groups.values())


def cmd_run(args):
    name = args.name
    slots = SLOTS if args.exclusive or args.slots <= 0 else min(args.slots, SLOTS)
    exit_file = os.path.join(BASE, name + ".exit")
    with locked():
        old = read_json(job_path(name))
        if old and live(old):
            print("a job named %s is already %s" % (name, old["state"]), flush=True)
            return 1
        job = {"name": name, "owner": args.owner, "tree": args.tree, "slots": slots, "exclusive": args.exclusive,
               "cmd": args.command, "cwd": os.getcwd(), "state": "queued", "queued_at": time.time(),
               "sched_pid": os.getpid()}
        write_json(job_path(name), job)
    shown = None
    child = None
    code = 143  # stopped before the job ended

    def stop(_sig, _frame):
        if child is None:
            raise SystemExit(143)
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGTERM)
    signal.signal(signal.SIGTERM, stop)
    try:
        while child is None:
            with locked():
                jobs = load_jobs()
                mine, other = usage(jobs)
                if decide(jobs, other) == name:
                    child = subprocess.Popen(args.command, start_new_session=True,
                                             env=dict(os.environ, SDP_JOBS=str(slots)))
                    job.update(state="running", pid=child.pid, started_at=time.time())
                    write_json(job_path(name), job)
                    print("%s started (%d slot(s)%s): %s" % (time.strftime("%H:%M"), slots,
                                                           ", exclusive" if args.exclusive else "",
                                                           " ".join(args.command)), flush=True)
                    break
            line = "queued: %d of %d slots in use%s" % (mine + other, SLOTS, " (%d by jobs not started here)"
                                                         % other if other else "")
            if line != shown:
                print("%s %s" % (time.strftime("%H:%M"), line), flush=True)
                shown = line
            time.sleep(POLL)
        code = child.wait()
    finally:
        with locked():
            job.update(state="done", exit=code, ended_at=time.time())
            write_json(job_path(name), job)
        with open(exit_file, "w") as fh:
            fh.write("%d\n" % code)
    return code


def last_line(name):
    try:
        with open(os.path.join(BASE, name + ".log"), "rb") as fh:
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 4096))
            lines = fh.read().decode("utf-8", "replace").strip().splitlines()
        return lines[-1] if lines else ""
    except OSError:
        return ""


def legacy_running(name, t):
    log = os.path.join(BASE, name + ".log")
    return (os.path.exists(log) and not os.path.exists(os.path.join(BASE, name + ".exit"))
            and t - os.path.getmtime(log) < LEGACY_FRESH)


def cmd_check(args):
    job = read_json(job_path(args.name))
    if (job and live(job)) or (not job and legacy_running(args.name, time.time())):
        print("%s is %s" % (args.name, job["state"] if job else "running (no job record)"))
        return 1
    return 0


def cmd_status(_args):
    t = time.time()
    jobs = load_jobs()
    known = {j["name"] for j in jobs}
    mine, other = usage(jobs)
    print("slots in use: %d of %d%s" % (mine + other, SLOTS, " (%d by compare.mjs not started here)" % other
                                         if other else ""))
    rows = []
    for j in sorted(jobs, key=lambda j: (j["state"] != "running", j["state"] != "queued", -j.get("queued_at", 0))):
        if j["state"] == "done" and t - j.get("ended_at", t) > 86400:
            continue
        state = j["state"] if live(j) else ("exit %s" % j.get("exit") if j["state"] == "done" else "lost")
        since = j.get("started_at") or j.get("queued_at") or t
        rows.append((j["name"], state, j.get("owner") or "?", "%d%s" % (j["slots"], "x" if j.get("exclusive") else ""),
                     "%dmin" % ((t - since) // 60), last_line(j["name"])))
    for log in sorted(os.listdir(BASE)) if os.path.isdir(BASE) else []:
        name = log[:-4]
        if log.endswith(".log") and name not in known and t - os.path.getmtime(os.path.join(BASE, log)) < 86400:
            exit_path = os.path.join(BASE, name + ".exit")
            if os.path.exists(exit_path):
                state = "exit " + open(exit_path).read().strip()
            else:
                state = "running?" if legacy_running(name, t) else "no exit"
            rows.append((name, state, "-", "-", "-", last_line(name)))
    for row in rows:
        print("%-24s %-9s %-22s %-4s %-7s %s" % (row[0], row[1], row[2][:22], row[3], row[4], row[5][:90]))
    return 0


def cmd_prune(_args):
    t = time.time()
    snaps = os.path.join(BASE, "snap")
    for name in sorted(os.listdir(snaps)) if os.path.isdir(snaps) else []:
        job = read_json(job_path(name))
        if job and job["state"] == "done" and t - job.get("ended_at", t) > KEEP:
            subprocess.run(["rm", "-rf", os.path.join(snaps, name)])
            print("removed snapshot", name)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("name")
    r.add_argument("--slots", type=int, default=0, help="0: all slots")
    r.add_argument("--exclusive", action="store_true")
    r.add_argument("--owner", default="")
    r.add_argument("--tree", default="")
    c = sub.add_parser("check")
    c.add_argument("name")
    sub.add_parser("status")
    sub.add_parser("prune")
    argv = list(sys.argv[1:] if argv is None else argv)
    command = argv[argv.index("--") + 1:] if "--" in argv else []
    args = ap.parse_args(argv[:argv.index("--")] if "--" in argv else argv)
    args.command = command
    if args.cmd == "run" and not command:
        raise SystemExit("give the command after --")
    return {"run": cmd_run, "check": cmd_check, "status": cmd_status, "prune": cmd_prune}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
