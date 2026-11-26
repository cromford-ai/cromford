#!/usr/bin/env python3
# tests/lib/fake-verdict-blocks-worker.bh-9905.py — BH-9905: a file-backed
# stand-in for the jobs worker's verdict reads, invoked AS `curl`.
#
# A suite puts a two-line shim named `curl` first on PATH:
#   #!/bin/bash
#   VBW_STATE=<dir> exec python3 <this file> "$@"
# and every request bin/lib/jobs/req.sh (_jobs_req) makes lands here. The
# argv shape is the one curl call req.sh makes (-X, -H, --data-binary, -m,
# --connect-timeout, -w, -sS, then the URL); the answer is printed the way
# `-w '\n%{http_code}'` prints it: body, newline, status.
#
# State in $VBW_STATE:
#   verdicts.json   a list of rows {id, repo, pr, head_sha, verdict, source,
#                   created_at, note, report_url, retracted}
#   requests.log    one "<METHOD> <path>?<query>" line per request
#   missing.<name>  the worker's OWN unknown-endpoint 404 for that route
#                   (verdict-blocks | verdicts): a worker that has not shipped it
#   fail.<name>     a 500 for that route
#
# The two GET routes keep the semantics the hub reader depends on:
#   GET /api/verdict-blocks  worker/jobs/src/routes/verdict-blocks.js: BLOCK
#     rows of the repo at or after `since`, retracted rows dropped, newest
#     first, `limit` rows, truncated when the page is full.
#   GET /api/verdicts        worker/jobs/src/routes/verdicts.js: the PR's
#     history (id DESC) and, with &head=, `standing`: the newest lead / human /
#     risk-tier row on that head that is not retracted, a human row first.
# Every other request is a plain 404, which the jobs client reads as "none".
import json, os, sys
from urllib.parse import urlsplit, parse_qs

S = os.environ["VBW_STATE"]
STANDING = ("lead", "human", "risk-tier")


def out(code, obj):
    sys.stdout.write(json.dumps(obj) + "\n" + str(code))
    sys.exit(0)


method, url = "GET", ""
a = sys.argv[1:]
i = 0
while i < len(a):
    x = a[i]
    if x == "-X":
        method = a[i + 1]; i += 2
    elif x in ("--data-binary", "-H", "-m", "--connect-timeout", "-w"):
        i += 2
    elif x.startswith("-"):
        i += 1
    else:
        url = x; i += 1

os.makedirs(S, exist_ok=True)
u = urlsplit(url)
path, q = u.path, {k: v[0] for k, v in parse_qs(u.query).items()}
with open(os.path.join(S, "requests.log"), "a") as f:
    f.write(f"{method} {path}{'?' + u.query if u.query else ''}\n")

p = os.path.join(S, "verdicts.json")
rows = json.load(open(p)) if os.path.exists(p) else []


def gate(name):
    if os.path.exists(os.path.join(S, "missing." + name)):
        out(404, {"error": "unknown endpoint", "worker": "harness-jobs"})
    if os.path.exists(os.path.join(S, "fail." + name)):
        out(500, {"error": "fixture 500"})


def pub(r):
    return {k: r.get(k) for k in ("id", "repo", "pr", "head_sha", "verdict", "source",
                                  "created_at", "note", "report_url")}


if method == "GET" and path == "/api/verdict-blocks":
    gate("verdict-blocks")
    repo, since = q.get("repo", ""), q.get("since", "")
    if not repo or not since:
        out(400, {"error": "repo and since are required"})
    lim = int(q.get("limit", "1000"))
    sel = [r for r in rows if r["repo"] == repo and r["verdict"] == "BLOCK"
           and r["created_at"] >= since and not r.get("retracted")]
    sel.sort(key=lambda r: r["created_at"], reverse=True)
    sel = sel[:lim]
    out(200, {"repo": repo, "since": since, "limit": lim,
              "rows": [{k: r[k] for k in ("id", "pr", "head_sha", "source", "created_at")} for r in sel],
              "truncated": len(sel) >= lim, "as_of": "2026-11-25T00:00:00Z"})

if method == "GET" and path == "/api/verdicts":
    gate("verdicts")
    repo, pr, head = q.get("repo", ""), int(q.get("pr", "0")), q.get("head", "").lower()
    mine = sorted([r for r in rows if r["repo"] == repo and r["pr"] == pr], key=lambda r: r["id"], reverse=True)
    standing = None
    if head:
        cand = [r for r in mine if r["head_sha"].lower() == head and r["source"] in STANDING and not r.get("retracted")]
        cand.sort(key=lambda r: (r["source"] == "human", r["id"]), reverse=True)
        standing = pub(cand[0]) if cand else None
    hist = [] if q.get("standing_only") == "1" else [pub(r) for r in mine[:100]]
    out(200, {"repo": repo, "pr": pr, "head": head or None, "standing": standing,
              "rows": hist, "truncated": len(hist) >= 100, "as_of": "2026-11-25T00:00:00Z"})

out(404, {"error": "not found"})
