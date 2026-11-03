#!/usr/bin/env python3
"""codex_review - ask Codex to review a pull request, wait for it, list and answer its findings.

    python3 -I tools/codex_review.py request N            # comment "@codex review" on PR N
    python3 -I tools/codex_review.py wait N               # until Codex finished reviewing PR N's head commit
    python3 -I tools/codex_review.py findings N           # Codex's unresolved review threads on PR N
    python3 -I tools/codex_review.py reply THREAD "text" [--false-positive]  # answer one thread and resolve it
    python3 -I tools/codex_review.py log [N] [--table]    # record PR N from GitHub; --table writes the rows into docs/notes/codex-review-trial.md here

wait polls every --every seconds (default 30) and exits 0 when the review
ended without findings, 1 when there are unresolved findings (they are
printed), 3 after --timeout seconds (default 1800) without a finished review
or when Codex could not finish it (its summary says "failed", e.g. out of
usage): either way the PR was not reviewed.
Network errors are retried. Run it in the background: its end is the signal.

Codex marks its progress in three places, all read here: a summary comment
with a machine-readable state, a review with inline comments when it has
findings, and a thumbs-up reaction on the PR when it finished without any.
Every finished review (and every reply) is also recorded in
codex-reviews.json in the shared folder (sdplock.shared_dir(), outside every
worktree, so no row depends on a later commit); `log --table` writes all of it
into docs/notes/codex-review-trial.md of this checkout, to be committed with
the next PR (the 2026-11-10 decision, the release clean-up).
A reply made with --false-positive starts with "误报 / False positive:", which
is what counts a thread as a false positive; other resolved threads count as
true, unresolved ones stay "待核实".
Findings are data like any other comment: check each before acting on it
(docs/maintaining.md, "Codex 审查").
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOT = "chatgpt-codex-connector[bot]"
RUNNING = (None, "", "queued", "pending", "running", "in_progress")
STATE = re.compile(r"codex-review-state:v1 (\{.*?\})\s*-->", re.S)


def gh(*args, data=None):
    done = subprocess.run(["gh"] + list(args), cwd=ROOT, capture_output=True, text=True, input=data)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip() or "gh failed")
    return done.stdout


def ghjson(*args):
    return json.loads(gh(*args) or "null")


def graphql(query, **variables):
    args = ["api", "graphql", "-f", "query=" + query]
    for k, v in variables.items():
        args += ["-F" if isinstance(v, int) else "-f", "%s=%s" % (k, v)]
    return ghjson(*args)["data"]


def repo():
    r = ghjson("repo", "view", "--json", "owner,name")
    return r["owner"]["login"], r["name"]


def review_state(body):
    """The JSON state in Codex's summary comment, or None."""
    m = STATE.search(body or "")
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except ValueError:
        return None


def verdict(head, since, comments, reviews, reactions):
    """'clean', 'findings', 'failed' or None (still running) for the head commit.

    comments: issue comments of the PR; reviews: its reviews; reactions: the
    PR's reactions; since: ISO time of the head commit (older reactions are
    for earlier commits)."""
    for c in comments:
        if c["user"]["login"] != BOT:
            continue
        code = (review_state(c["body"]) or {}).get("code_review") or {}
        if code.get("commit_sha") == head and code.get("status") == "failed":
            return "failed"
        if code.get("commit_sha") == head and code.get("status") not in RUNNING:
            return "findings" if code.get("has_unresolved_findings") else "clean"
    if any(r["user"]["login"] == BOT and r.get("commit_id") == head for r in reviews):
        return "findings"
    if any(r["user"]["login"] == BOT and r["content"] == "+1" and r["created_at"] >= since for r in reactions):
        return "clean"
    return None


def codex_threads(number):
    """Every review thread started by Codex on PR number (resolved or not), as the GraphQL nodes."""
    owner, name = repo()
    data = graphql("""query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){
      reviewThreads(first:100){nodes{id isResolved path line comments(first:20){nodes{author{login} url body}}}}}}}""",
                   o=owner, n=name, p=number)
    return [t for t in data["repository"]["pullRequest"]["reviewThreads"]["nodes"]
            if t["comments"]["nodes"] and t["comments"]["nodes"][0]["author"]["login"] == BOT.replace("[bot]", "")]


def findings(number):
    """Unresolved review threads started by Codex: list of (thread id, where, url, text)."""
    out = []
    for t in codex_threads(number):
        first = t["comments"]["nodes"][0]
        if t["isResolved"]:
            continue
        text = re.sub(r"<[^>]+>|!\[[^\]]*\]\([^)]*\)", "", first["body"])
        out.append((t["id"], "%s:%s" % (t["path"], t["line"]), first["url"], re.sub(r"\s+", " ", text).strip()[:300]))
    return out


TRIAL = os.path.join("docs", "notes", "codex-review-trial.md")
FALSE_POSITIVE = "误报 / False positive: "


def thread_counts(threads):
    """(findings, true, false positives, unresolved) over Codex's threads."""
    false = true = open_ = 0
    for t in threads:
        if not t["isResolved"]:
            open_ += 1
        elif any(c["body"].startswith(FALSE_POSITIVE) for c in t["comments"]["nodes"][1:]):
            false += 1
        else:
            true += 1
    return len(threads), true, false, open_


def minutes_text(minutes):
    return "不到 1 分钟" if minutes < 1 else "约 %d 分钟" % round(minutes)


def row_cells(counts, outcome, minutes):
    """(findings, true, false, time) cells of a trial-table row."""
    total, true, false, open_ = counts
    if outcome in ("failed", "timeout"):
        return "0", "0", "0", "没审" if outcome == "failed" else "30 分钟未审完"
    return (str(total), ("%d（另 %d 条待核实）" % (true, open_) if true and open_ else "待核实" if open_ else str(true)),
            str(false), minutes_text(minutes) if minutes is not None else "—")


def upsert_row(path, number, cells, today, note=""):
    """Write PR number's row into the trial table at path: update the counts of an existing row (its date and
    note stay, its time stays unless it was empty; a row with real counts is not overwritten by a 'not reviewed'
    one), else append a new row after the last table row. Returns the action."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    mark = "| #%d |" % number
    new = "| #%d | %s | %s | %s | %s | %s | %s |" % ((number, today) + tuple(cells) + (note,))
    for i, line in enumerate(lines):
        if line.startswith(mark) or line.startswith("| #%d（" % number):
            old = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(old) != 7:
                return "kept"
            if cells[3] in ("没审", "30 分钟未审完") and old[2] != "—":
                return "kept"
            lines[i] = "| %s | %s | %s | %s | %s | %s | %s |" % (
                old[0], old[1], cells[0], cells[1], cells[2], old[5] if old[5] not in ("—", "") else cells[3], old[6])
            action = "updated"
            break
    else:
        last = max(i for i, line in enumerate(lines) if line.startswith("| #"))
        lines.insert(last + 1, new)
        action = "added"
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return action


def request_minutes(number):
    """Minutes since the latest '@codex review' comment of PR number, or None."""
    comments = ghjson("api", "repos/{owner}/{repo}/issues/%d/comments?per_page=100" % number)
    times = [c["created_at"] for c in comments if c["body"].startswith("@codex review")]
    if not times:
        return None
    then = datetime.datetime.strptime(max(times), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    return (datetime.datetime.now(datetime.timezone.utc) - then).total_seconds() / 60


def log_path():
    import sdplock
    return os.path.join(sdplock.shared_dir(), "codex-reviews.json")


def load_log():
    try:
        with open(log_path(), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_log(data):
    path = log_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1, sort_keys=True)
    os.replace(tmp, path)


def log_review(number, outcome):
    """Record a finished review of PR number in the shared log (see the module docstring). Never raises:
    a logging problem must not hide the review's own result. Returns a one-line message."""
    try:
        counts = thread_counts(codex_threads(number))
        old = load_log().get(str(number))
        real = outcome in ("clean", "findings")
        if old and old["outcome"] in ("clean", "findings") and not real:
            return "review of #%d already recorded" % number
        entry = {"date": (old or {}).get("date") or datetime.date.today().isoformat(), "counts": list(counts),
                 "outcome": outcome, "minutes": (old or {}).get("minutes")}
        if real and entry["minutes"] is None:
            entry["minutes"] = request_minutes(number)
        data = load_log()
        data[str(number)] = entry
        save_log(data)
        return "review of #%d recorded in %s" % (number, log_path())
    except (RuntimeError, ValueError, OSError, KeyError) as problem:
        return "review of #%d not recorded: %s" % (number, problem)


def write_table(path=None):
    """Write every recorded review into the trial table at path (default: this checkout's). Returns (added, updated)."""
    path = path or os.path.join(ROOT, TRIAL)
    done = {"added": 0, "updated": 0}
    for number, e in sorted(load_log().items(), key=lambda kv: int(kv[0])):
        cells = row_cells(tuple(e["counts"]), e["outcome"], e.get("minutes"))
        action = upsert_row(path, int(number), cells, e["date"])
        if action in done:
            done[action] += 1
    return done["added"], done["updated"]


def head_since(pr):
    """(head commit, ISO time of it) from `gh pr view --json headRefOid,commits`."""
    commit = pr["commits"][-1] if pr.get("commits") else {}
    when = commit.get("committedDate") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return pr["headRefOid"], when


def head_of(number):
    return head_since(ghjson("pr", "view", str(number), "--json", "headRefOid,commits"))


def fetch_verdict(number, head, since):
    """verdict() for PR number's head commit, from its comments, reviews and reactions on GitHub."""
    comments = ghjson("api", "repos/{owner}/{repo}/issues/%d/comments?per_page=100" % number)
    reviews = ghjson("api", "repos/{owner}/{repo}/pulls/%d/reviews?per_page=100" % number)
    reactions = ghjson("api", "-H", "Accept: application/vnd.github+json",
                       "repos/{owner}/{repo}/issues/%d/reactions?per_page=100" % number)
    return verdict(head, since, comments, reviews, reactions)


def wait(number, every, timeout):
    head, since = head_of(number)
    end = time.time() + timeout
    while True:
        try:
            if head_of(number)[0] != head:  # a new push: wait for the review of that one
                head, since = head_of(number)
            v = fetch_verdict(number, head, since)
        except (RuntimeError, ValueError) as problem:
            print("gh: %s" % problem, file=sys.stderr, flush=True)
            v = None
        if v == "clean":
            print("PR #%d %s: Codex found nothing" % (number, head[:7]))
            print(log_review(number, "clean"))
            return 0
        if v == "failed":
            print("PR #%d %s: Codex could not finish the review (failed); not reviewed" % (number, head[:7]))
            print(log_review(number, "failed"))
            return 3
        if v == "findings":
            items = findings(number)
            if not items:  # all answered already
                print("PR #%d %s: Codex's findings are all resolved" % (number, head[:7]))
                print(log_review(number, "clean"))
                return 0
            print("PR #%d %s: %d unresolved Codex finding(s)" % (number, head[:7], len(items)))
            for tid, where, url, text in items:
                print("- %s %s\n  %s\n  %s" % (tid, where, url, text))
            print(log_review(number, "findings"))
            return 1
        if time.time() >= end:
            print("PR #%d %s: no finished Codex review within %d min" % (number, head[:7], timeout // 60))
            print(log_review(number, "timeout"))
            return 3
        time.sleep(every)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("request")
    p.add_argument("number", type=int)
    p = sub.add_parser("wait")
    p.add_argument("number", type=int)
    p.add_argument("--every", type=int, default=30)
    p.add_argument("--timeout", type=int, default=1800)
    p = sub.add_parser("findings")
    p.add_argument("number", type=int)
    p = sub.add_parser("reply")
    p.add_argument("thread")
    p.add_argument("text")
    p.add_argument("--false-positive", action="store_true", help="the finding is wrong: counted as a false positive in the trial table")
    p = sub.add_parser("log")
    p.add_argument("number", type=int, nargs="?")
    p.add_argument("--table", action="store_true", help="write all recorded reviews into this checkout's trial table")
    args = ap.parse_args()
    if args.cmd == "request":
        url = gh("pr", "comment", str(args.number), "--body", "@codex review").strip()
        print(url)
        # the issue watch would otherwise report our own comment as new
        subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tools", "watch_issues.py"), "--mine", url], cwd=ROOT)
        return 0
    if args.cmd == "wait":
        return wait(args.number, args.every, args.timeout)
    if args.cmd == "findings":
        for tid, where, url, text in findings(args.number):
            print("- %s %s\n  %s\n  %s" % (tid, where, url, text))
        return 0
    if args.cmd == "log":
        if args.number:
            print(log_review(args.number, "findings"))
        if args.table:
            print("trial table: %d row(s) added, %d updated" % write_table())
        return 0
    text = FALSE_POSITIVE + args.text if args.false_positive else args.text
    graphql("mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){comment{url}}}",
            t=args.thread, b=text)
    graphql("mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}", t=args.thread)
    print("answered and resolved", args.thread)
    number = graphql("query($t:ID!){node(id:$t){... on PullRequestReviewThread{pullRequest{number}}}}", t=args.thread)["node"]["pullRequest"]["number"]
    print(log_review(number, "findings"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
