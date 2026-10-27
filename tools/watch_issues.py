#!/usr/bin/env python3
"""watch_issues - new issues and comments on the repository, for the agent to pick up.

    python3 -I tools/watch_issues.py                 # wait until something new, print it, exit 0
    python3 -I tools/watch_issues.py --once          # print what is new now (exit 0 even if nothing)
    python3 -I tools/watch_issues.py --mine URL ...  # comment or issue URLs the agent posted: never reported
    python3 -I tools/watch_issues.py --reset         # start from now (forget the old state)

Only the accounts in $SDP_WATCH_USERS (comma separated; default the
repository's collaborators, read once with gh) are reported; anything else
goes to logs/watch/others.log and is not acted on. The maintainer and the
agent share one GitHub account, so the agent records the comments it posts
(--mine, with the URL gh prints) or they would come back as new.
Without --once it polls every --every seconds (default 120) and exits with
the first new items: run it in the background; its end is the signal. A
failed poll (network) is retried after --retry seconds (default 30). It
does not handle anything itself (.claude/skills/sdp-watch says how).
State: logs/watch/state.json.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, "logs", "watch")
STATE = os.path.join(DIR, "state.json")
OTHERS = os.path.join(DIR, "others.log")


def gh(path):
    done = subprocess.run(["gh", "api", path], cwd=ROOT, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip())
    return json.loads(done.stdout or "[]")


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load():
    if os.path.exists(STATE):
        return json.load(open(STATE, encoding="utf-8"))
    return {"since": now(), "seen": [], "mine": []}


def save(state):
    os.makedirs(DIR, exist_ok=True)
    state["seen"] = state["seen"][-2000:]
    json.dump(state, open(STATE, "w", encoding="utf-8"), indent=1)


def users(state):
    if os.environ.get("SDP_WATCH_USERS"):
        return set(u.strip() for u in os.environ["SDP_WATCH_USERS"].split(",") if u.strip())
    if not state.get("users"):
        state["users"] = sorted(u["login"] for u in gh("repos/{owner}/{repo}/collaborators"))
    return set(state["users"])


def poll(state):
    """New items from the watched accounts since the last poll: list of lines."""
    who, since, stamp = users(state), state["since"], now()
    seen, mine, out = set(state["seen"]), set(state["mine"]), []
    for issue in gh("repos/{owner}/{repo}/issues?state=all&sort=created&direction=asc&per_page=50&since=" + since):
        key = "issue-%d" % issue["number"]
        if "pull_request" in issue or issue["created_at"] < since or key in seen or key in mine:
            continue
        seen.add(key)
        line = "NEW ISSUE #%d by %s: %s %s" % (issue["number"], issue["user"]["login"], issue["title"], issue["html_url"])
        if issue["user"]["login"] in who:
            out.append(line)
        else:
            open(OTHERS, "a", encoding="utf-8").write(stamp + " " + line + "\n")
    for c in gh("repos/{owner}/{repo}/issues/comments?per_page=100&since=" + since):
        key = "comment-%d" % c["id"]
        if key in seen or str(c["id"]) in mine or c["created_at"] < since:
            continue
        seen.add(key)
        num = c["issue_url"].rsplit("/", 1)[1]
        body = re.sub(r"\s+", " ", c["body"])[:160]
        line = "NEW COMMENT on #%s by %s: %s %s" % (num, c["user"]["login"], body, c["html_url"])
        if c["user"]["login"] in who:
            out.append(line)
        else:
            open(OTHERS, "a", encoding="utf-8").write(stamp + " " + line + "\n")
    state["since"], state["seen"] = stamp, sorted(seen)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--every", type=float, default=120)
    ap.add_argument("--retry", type=float, default=30)
    ap.add_argument("--mine", nargs="+", metavar="URL")
    ap.add_argument("--reset", action="store_true")
    args = ap.parse_args()
    os.makedirs(DIR, exist_ok=True)
    if args.reset:
        save({"since": now(), "seen": [], "mine": []})
        print("watching from", now())
        return 0
    state = load()
    if args.mine:
        for url in args.mine:
            m = re.search(r"issuecomment-(\d+)", url) or re.search(r"/issues/(\d+)$", url)
            if not m:
                print("not a comment or issue URL:", url, file=sys.stderr)
                return 2
            state["mine"].append(m.group(1) if "issuecomment" in url else "issue-" + m.group(1))
        save(state)
        return 0
    while True:
        # --mine may have been run while this waited: take its records
        state["mine"] = sorted(set(state["mine"]) | set(load()["mine"]))
        wait = args.every
        try:
            new = poll(state)
        except RuntimeError as problem:  # network: try again soon, not a whole round later
            new, wait = [], args.retry
            print("%s gh: %s" % (now(), problem), file=sys.stderr, flush=True)
        save(state)
        if new or args.once:
            print("\n".join(new) if new else "nothing new")
            return 0
        time.sleep(wait)


if __name__ == "__main__":
    sys.exit(main())
