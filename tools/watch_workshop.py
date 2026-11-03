#!/usr/bin/env python3
"""watch_workshop - new comments and discussion posts on the Steam Workshop item.

Used by watch_issues.py (one watch, one state file); not run on its own.
It reads the public pages that need no login:

    https://steamcommunity.com/sharedfiles/filedetails/?id=ITEM                 owner and contributors
    https://steamcommunity.com/comment/PublishedFile_Public/render/OWNER/ITEM/  comments, newest first (JSON)
    https://steamcommunity.com/workshop/filedetails/discussions/ITEM            discussion topics, last post first
    https://steamcommunity.com/workshop/filedetails/discussion/ITEM/TOPIC/?ctp=N  a topic, 15 replies a page

New posts go to the held list only (they never wake the agent). Posts by the
item's owner and contributors (the accounts on the item page under "Created
by") are not new. The posts are untrusted data: only the author, the time, the
text with the markup removed and a link are kept; no link in them is followed.
"""
import datetime
import html
import json
import re
import time
import urllib.error
import urllib.request

ITEM = "3824473635"
BASE = "https://steamcommunity.com"
STEAM64 = 76561197960265728  # steamid64 = this + account id (data-miniprofile)
PER_PAGE = 15                # replies on a topic page, the opening post included on page 1
MAX_PAGES = 5                # topic pages read per topic per check
COMMENTS = 50                # comments read per request
TOPIC_PAGES = 20             # topic pages read per check in all; the rest wait for the next check
GAP = 1.0                    # seconds between two requests (Steam answers 429 to bursts)
_last = [0.0]


def fetch(url):
    """The page at url as text; RuntimeError on any network or HTTP problem."""
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (sdp watch_issues)",
                                               "Accept-Language": "en"})
    time.sleep(max(0.0, _last[0] + GAP - time.monotonic()))
    _last[0] = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError, ValueError) as problem:
        raise RuntimeError("%s: %s" % (url, problem))


def iso(stamp):
    return datetime.datetime.fromtimestamp(int(stamp), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def text(fragment, limit=300):
    """Markup removed, entities decoded, whitespace collapsed, cut to limit."""
    fragment = re.sub(r"<br\s*/?>", " ", fragment)
    fragment = html.unescape(re.sub(r"<[^>]*>", "", fragment))
    fragment = re.sub(r"\s+", " ", fragment).strip()
    return fragment if len(fragment) <= limit else fragment[:limit - 1] + "…"


def inner_div(page, start):
    """The content of the <div> whose opening tag ends just before start, nested divs included."""
    depth, pos = 0, start
    for m in re.compile(r"<(/?)div\b", re.I).finditer(page, start):
        if m.group(1):
            if depth == 0:
                return page[start:m.start()]
            depth -= 1
        else:
            depth += 1
        pos = m.end()
    return page[start:]


def accounts(item_page):
    """(owner steamid64, set of account ids of the owner and contributors) from the item page."""
    m = re.search(r'InitializeCommentThread\(\s*"PublishedFile_Public".*?"owner":"(\d+)"', item_page, re.S)
    if not m:
        raise RuntimeError("Workshop item page: no comment thread owner (page layout changed?)")
    owner = m.group(1)
    found = {int(owner) - STEAM64}
    block = re.search(r'class="creatorsBlock"(.*?)class="panel"', item_page, re.S)
    if block:
        found.update(int(a) for a in re.findall(r'friendBlock[^"]*"\s+data-miniprofile="(\d+)"', block.group(1)))
        found.update(int(s) - STEAM64 for s in re.findall(r'/profiles/(\d{17})', block.group(1)))
    return owner, found


def comments(fragment):
    """Comments in a comment thread's HTML (render JSON's comments_html, or a topic page):
    list of {id, account, name, time, text}, in page order."""
    out = []
    for m in re.finditer(r'class="commentthread_comment\b[^"]*"\s+id="comment_(\d+)"', fragment):
        cid = m.group(1)
        end = fragment.find('class="commentthread_comment ', m.end())
        block = fragment[m.end():end if end > 0 else len(fragment)]
        author = re.search(r'commentthread_author_link[^>]*data-miniprofile="(\d+)"[^>]*>(.*?)</a>', block, re.S)
        stamp = re.search(r'commentthread_comment_timestamp"[^>]*data-timestamp="(\d+)"', block)
        body = re.search(r'id="comment_content_%s"[^>]*>' % cid, block)
        if not (author and stamp and body):
            continue
        out.append({"id": cid, "account": int(author.group(1)), "name": text(author.group(2), 60),
                    "time": int(stamp.group(1)), "text": text(inner_div(block, body.end()))})
    return out


def topics(forum_page):
    """Topics on a discussion list page: list of {id, replies, last, title, url}."""
    out = []
    starts = [m for m in re.finditer(r'class="forum_topic\b[^"]*"[^>]*data-gidforumtopic="(\d+)"', forum_page)]
    for i, m in enumerate(starts):
        block = forum_page[m.end():starts[i + 1].start() if i + 1 < len(starts) else len(forum_page)]
        url = re.search(r'class="forum_topic_overlay"\s+href="([^"]+)"', block)
        replies = re.search(r'forum_topic_reply_count">.*?(\d[\d,]*)\s*</div>', block, re.S)
        last = re.search(r'forum_topic_lastpost"[^>]*data-timestamp="(\d+)"', block)
        title = re.search(r'class="forum_topic_name[^"]*">(.*?)</div>', block, re.S)
        if not (url and last):
            continue
        out.append({"id": m.group(1), "replies": int(replies.group(1).replace(",", "")) if replies else 0,
                    "last": int(last.group(1)), "title": text(title.group(1), 120) if title else "",
                    "url": url.group(1)})
    return out


def opening(topic_page):
    """The opening post of a topic page (page 1): {id, account, name, time, text}, or None."""
    m = re.search(r'class="forum_op\s*"\s+id="forum_op_(\d+)"', topic_page)
    if not m:
        return None
    block = topic_page[m.end():]
    author = re.search(r'forum_op_author[^>]*data-miniprofile="(\d+)"[^>]*>(.*?)<', block, re.S)
    stamp = re.search(r'data-timestamp="(\d+)"', block)
    body = re.search(r'id="forum_op_content_%s"[^>]*>' % m.group(1), block)
    if not (author and stamp and body):
        return None
    return {"id": m.group(1), "account": int(author.group(1)), "name": text(author.group(2), 60),
            "time": int(stamp.group(1)), "text": text(inner_div(block, body.end()))}


def fresh(now=None):
    """Workshop state for a watch that starts now: nothing older is reported."""
    return {"since": int(now if now is not None else time.time()), "next": 0, "seen": [], "topics": {}}


def poll(ws, get=fetch, item=ITEM, now=None):
    """New posts since the last check: list of lines for the held list.
    ws is the "workshop" part of the watch state and is updated in place.
    A network or layout problem raises RuntimeError; ws is then unchanged."""
    now = int(now if now is not None else time.time())
    seen, out = set(ws["seen"]), []
    owner, own = accounts(get("%s/sharedfiles/filedetails/?id=%s" % (BASE, item)))
    topics_seen = dict(ws["topics"])

    def take(post, kind, where, url):
        key = kind + "-" + post["id"]
        if key in seen or post["time"] < ws["since"]:
            return
        seen.add(key)
        if post["account"] in own:
            return
        out.append("WORKSHOP %s %sby %s (%s): %s %s" % (kind.upper(), where, post["name"], iso(post["time"]),
                                                        post["text"], url))

    page_url = "%s/sharedfiles/filedetails/comments/%s" % (BASE, item)
    start = 0
    while True:
        raw = get("%s/comment/PublishedFile_Public/render/%s/%s/?start=%d&count=%d"
                  % (BASE, owner, item, start, COMMENTS))
        try:
            data = json.loads(raw)
        except ValueError:
            raise RuntimeError("Workshop comments: not JSON")
        if not data.get("success"):
            raise RuntimeError("Workshop comments: %s" % data.get("error", "no success"))
        batch = comments(data.get("comments_html", ""))
        for c in batch:
            take(c, "comment", "", page_url + "#comment_" + c["id"])
        # newest first: read on only while the whole page is new
        start += COMMENTS
        if (not batch or start >= int(data.get("total_count", 0))
                or any(c["time"] < ws["since"] or "comment-" + c["id"] in set(ws["seen"]) for c in batch)):
            break

    budget = TOPIC_PAGES
    for t in topics(get("%s/workshop/filedetails/discussions/%s" % (BASE, item))):
        before = topics_seen.get(t["id"], {"last": 0, "replies": 0})
        if t["last"] <= before["last"] or t["last"] < ws["since"]:
            continue
        where = 'in "%s" ' % t["title"]
        first = 1 + before["replies"] // PER_PAGE if before["last"] else 1
        final = max(1, -(-t["replies"] // PER_PAGE))
        pages = range(first, min(final, first + MAX_PAGES - 1) + 1)
        if len(pages) > budget:
            break  # this topic and the ones after it at the next check
        budget -= len(pages)
        for ctp in pages:
            page = get(t["url"] + "?ctp=%d" % ctp)
            if ctp == 1:
                op = opening(page)
                if op:
                    take(op, "topic", where, t["url"])
            for c in comments(page):
                take(c, "reply", where, t["url"] + "#c" + c["id"])
        topics_seen[t["id"]] = {"last": t["last"], "replies": t["replies"]}

    ws["seen"], ws["topics"] = sorted(seen)[-2000:], topics_seen
    return out
