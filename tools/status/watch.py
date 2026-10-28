#!/usr/bin/env python3
"""The status page's one background loop: keep the page current without involving the agent.

Every TICK seconds it runs sync.py --quick --push (machines only, plus the hand-written part),
and every INTERVAL seconds the full sync with git and GitHub; sync.py pushes status.json
when its content changed or 10 minutes passed. It exits (waking the session that started it in the
background) only on trouble, each trouble once:
  - a push failed 3 times in a row (server down, key refused, network);
  - status.json held a private string (path, user or host name, IP, mail address): nothing was pushed;
  - a machine runs more slots than its cap;
  - the game lock was held for more than 2 hours;
  - the page's certificate (status.page_host in the local config) fails to verify or has less
    than 2 days left: its renewal on the server is broken (checked hourly; skipped without page_host).
The session reports the trouble to the main session and starts the loop again.

    python3 -I tools/status/watch.py [OUT_DIR] [--interval 300] [--tick 60]
"""
import argparse
import json
import os
import socket
import ssl
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import sdplock  # noqa: E402

SHARED = sdplock.shared_dir()
OUT = os.path.join(SHARED, "status", "out")
GAME_MAX = 2 * 3600
CERT_MIN = 2 * 86400
_cert = {"at": 0, "trouble": None}


def page_host():
    st = sdplock.local_config().get("status")
    return st.get("page_host") if isinstance(st, dict) else None


def cert_trouble():
    """None, or why the page's certificate needs a look. Checked at most once an hour."""
    host = page_host()
    if not host or time.time() - _cert["at"] < 3600:
        return _cert["trouble"] if host else None
    _cert["at"], trouble = time.time(), None
    try:
        with socket.create_connection((host, 443), timeout=15) as raw:
            with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as tls:
                left = ssl.cert_time_to_seconds(tls.getpeercert()["notAfter"]) - time.time()
        if left < CERT_MIN:
            trouble = "page certificate expires in %.1f days: check its renewal on the page's server" % (left / 86400)
    except ssl.SSLError as e:
        trouble = "page certificate does not verify (%s): check its renewal on the page's server" % e
    except OSError:
        pass  # server unreachable: the push failures report that
    _cert["trouble"] = trouble
    return trouble


def sync(out, quick):
    return subprocess.run([sys.executable, "-I", os.path.join(HERE, "sync.py"), out, "--push"]
                          + (["--quick"] if quick else []), capture_output=True, text=True, timeout=180)


def troubles(out):
    found = []
    for key in ("macbook", "macmini"):
        try:
            d = json.load(open(os.path.join(out, "machines", key + ".json")))
        except Exception:
            continue
        used = sum(r.get("slots") or 0 for r in d["running"] if not r.get("paused"))
        if used > d.get("cap", 0):
            found.append("%s: %d slots used, cap %d" % (d.get("name", key), used, d.get("cap", 0)))
    try:
        h = json.load(open(os.path.join(SHARED, "game.json"))).get("holder")
        if h and time.time() - h.get("since", time.time()) > GAME_MAX:
            found.append("game held by %s since %s" % (h.get("branch") or h.get("owner"),
                                                       time.strftime("%H:%M", time.localtime(h["since"]))))
    except Exception:
        pass
    c = cert_trouble()
    if c:
        found.append(c)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=OUT)
    ap.add_argument("--interval", type=int, default=300)  # full sync: git, GitHub, queue, machines
    ap.add_argument("--tick", type=int, default=60)  # machines and the hand-written part
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    seen_file = os.path.join(a.out, "troubles.json")
    try:
        seen = set(json.load(open(seen_file)))
    except Exception:
        seen = set()
    last_full, fails = 0, 0
    while True:
        full = time.time() - last_full >= a.interval
        try:
            r = sync(a.out, quick=not full)
            code, err = r.returncode, (r.stderr or "").strip()
        except Exception as e:
            code, err = 3, str(e)
        if full and code in (0, 3):
            last_full = time.time()
        if code == 4:
            print("trouble: %s" % err)
            return 1
        fails = fails + 1 if code else 0
        if fails >= 3:
            print("trouble: push failed 3 times in a row: %s" % err[-500:])
            return 1
        now = troubles(a.out)
        new = [t for t in now if t not in seen]
        seen = set(now)  # a trouble that cleared may report again later
        with open(seen_file, "w") as fh:
            json.dump(sorted(seen), fh)
        if new:
            print("trouble: %s" % "; ".join(new))
            return 1
        time.sleep(a.tick)


if __name__ == "__main__":
    sys.exit(main())
