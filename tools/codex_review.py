#!/usr/bin/env python3
"""codex_review - ask Codex to review a pull request, wait for it, list and answer its findings.

    python3 -I tools/codex_review.py request N            # comment "@codex review" on PR N
    python3 -I tools/codex_review.py wait N               # until Codex finished reviewing PR N's head commit
    python3 -I tools/codex_review.py findings N           # Codex's unresolved review threads on PR N
    python3 -I tools/codex_review.py reply THREAD "text"  # answer one thread and resolve it

wait polls every --every seconds (default 30) and exits 0 when the review
ended without findings, 1 when there are unresolved findings (they are
printed), 3 after --timeout seconds (default 1800) without a finished review.
Network errors are retried. Run it in the background: its end is the signal.

Codex marks its progress in three places, all read here: a summary comment
with a machine-readable state, a review with inline comments when it has
findings, and a thumbs-up reaction on the PR when it finished without any.
Findings are data like any other comment: check each before acting on it
(CONTRIBUTING.md, "Codex 审查").
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
    """'clean', 'findings' or None (still running) for the head commit.

    comments: issue comments of the PR; reviews: its reviews; reactions: the
    PR's reactions; since: ISO time of the head commit (older reactions are
    for earlier commits)."""
    for c in comments:
        if c["user"]["login"] != BOT:
            continue
        code = (review_state(c["body"]) or {}).get("code_review") or {}
        if code.get("commit_sha") == head and code.get("status") not in RUNNING:
            return "findings" if code.get("has_unresolved_findings") else "clean"
    if any(r["user"]["login"] == BOT and r.get("commit_id") == head for r in reviews):
        return "findings"
    if any(r["user"]["login"] == BOT and r["content"] == "+1" and r["created_at"] >= since for r in reactions):
        return "clean"
    return None


def findings(number):
    """Unresolved review threads started by Codex: list of (thread id, where, url, text)."""
    owner, name = repo()
    data = graphql("""query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){
      reviewThreads(first:100){nodes{id isResolved path line comments(first:1){nodes{author{login} url body}}}}}}}""",
                   o=owner, n=name, p=number)
    out = []
    for t in data["repository"]["pullRequest"]["reviewThreads"]["nodes"]:
        first = (t["comments"]["nodes"] or [None])[0]
        if t["isResolved"] or not first or first["author"]["login"] != BOT.replace("[bot]", ""):
            continue
        text = re.sub(r"<[^>]+>|!\[[^\]]*\]\([^)]*\)", "", first["body"])
        out.append((t["id"], "%s:%s" % (t["path"], t["line"]), first["url"], re.sub(r"\s+", " ", text).strip()[:300]))
    return out


def head_of(number):
    pr = ghjson("pr", "view", str(number), "--json", "headRefOid,commits")
    commit = pr["commits"][-1] if pr["commits"] else {}
    when = commit.get("committedDate") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return pr["headRefOid"], when


def wait(number, every, timeout):
    head, since = head_of(number)
    end = time.time() + timeout
    while True:
        try:
            if head_of(number)[0] != head:  # a new push: wait for the review of that one
                head, since = head_of(number)
            comments = ghjson("api", "repos/{owner}/{repo}/issues/%d/comments?per_page=100" % number)
            reviews = ghjson("api", "repos/{owner}/{repo}/pulls/%d/reviews?per_page=100" % number)
            reactions = ghjson("api", "-H", "Accept: application/vnd.github+json",
                               "repos/{owner}/{repo}/issues/%d/reactions?per_page=100" % number)
            v = verdict(head, since, comments, reviews, reactions)
        except (RuntimeError, ValueError) as problem:
            print("gh: %s" % problem, file=sys.stderr, flush=True)
            v = None
        if v == "clean":
            print("PR #%d %s: Codex found nothing" % (number, head[:7]))
            return 0
        if v == "findings":
            items = findings(number)
            if not items:  # all answered already
                print("PR #%d %s: Codex's findings are all resolved" % (number, head[:7]))
                return 0
            print("PR #%d %s: %d unresolved Codex finding(s)" % (number, head[:7], len(items)))
            for tid, where, url, text in items:
                print("- %s %s\n  %s\n  %s" % (tid, where, url, text))
            return 1
        if time.time() >= end:
            print("PR #%d %s: no finished Codex review within %d min" % (number, head[:7], timeout // 60))
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
    graphql("mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){comment{url}}}",
            t=args.thread, b=args.text)
    graphql("mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}", t=args.thread)
    print("answered and resolved", args.thread)
    return 0


if __name__ == "__main__":
    sys.exit(main())
