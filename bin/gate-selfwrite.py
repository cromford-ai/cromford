#!/usr/bin/env python3
"""Self-write absorption for the triage gate (cost lever 2, the operator 2026-08-07).

Called by triage-gate.sh when the board fingerprint changed. Decides whether
EVERY change is one of our own writes (system-actor comments bumping
commentCount/lastActivityAt) — those re-triggered a full triage session per
tick and were the single biggest cost on the hub (~60 no-op sessions/day).

Prints exactly one token: ABSORB (all deltas are self-authored comment churn)
or RUN (anything else, including any doubt). FAIL-OPEN: every unexpected shape
or error prints RUN — a wrong ABSORB misses a client, a wrong RUN costs cents.

Env in: GATE_OLD, GATE_NEW (fingerprint JSON files: {boardId: [ticket,...]}),
BASE, BP, TOKEN (board API), SELF_ACTORS (comma-separated author names).

GATE_SELFWRITE_MODE=ids (Jira and Linear, BH-8449; bin/lib/gate-trk-selfwrite.sh)
runs the same diff with no fetch: BASE, BP, TOKEN and SELF_ACTORS are not read,
the fields that may move are commentCount and updatedAt, and every changed row
must carry an integer commentCount on both sides with new > old. It prints one
`ID <id> <old> <new>` line per changed row, or the single line RUN. The caller
reads each thread and decides who wrote the new comments.
"""
import json
import os
import subprocess
import sys

ABSORB_FIELDS = {"commentCount", "lastActivityAt"}
IDS_FIELDS = {"commentCount", "updatedAt"}
MAX_CHANGED = 5  # more than this in one tick is real activity — just run


def run(reason=""):
    print("RUN")
    sys.exit(0)


def newest_comment_author(ticket_detail):
    t = ticket_detail.get("ticket", ticket_detail)
    comments = t.get("comments") or []
    # project-9 returns ticket metadata under .ticket but keeps the thread in the
    # sibling top-level .comments array. Prefer nested comments for the board
    # shapes that use them, then fall back to the sibling array.
    if not comments:
        comments = ticket_detail.get("comments") or []
    if not comments:
        return None
    def created(c):
        return c.get("createdAt") or ""
    c = max(comments, key=created)
    a = c.get("author")
    if isinstance(a, dict):
        return a.get("name") or a.get("displayName")
    return a or c.get("authorName")


def is_count(v):
    return isinstance(v, int) and not isinstance(v, bool)


def main():
    ids_mode = os.environ.get("GATE_SELFWRITE_MODE", "") == "ids"
    fields = IDS_FIELDS if ids_mode else ABSORB_FIELDS
    try:
        old = json.load(open(os.environ["GATE_OLD"]))
        new = json.load(open(os.environ["GATE_NEW"]))
        if not (isinstance(old, dict) and isinstance(new, dict)):
            run()
        if not ids_mode:
            base, bp, token = os.environ["BASE"], os.environ["BP"], os.environ["TOKEN"]
            self_actors = {s.strip() for s in os.environ.get("SELF_ACTORS", "").split(",") if s.strip()}
            if not self_actors:
                run()
    except Exception:
        run()

    changed_ids = []
    try:
        if set(old) != set(new):
            run()  # board added/removed
        for bid in new:
            o = {t["id"]: t for t in old[bid]}
            n = {t["id"]: t for t in new[bid]}
            if set(o) != set(n):
                run()  # ticket created or archived — always a session
            for tid, nt in n.items():
                ot = o[tid]
                if ot == nt:
                    continue
                diff_fields = {k for k in nt if nt.get(k) != ot.get(k)}
                if not diff_fields <= fields:
                    run()  # status/turn/verdict/title moved — real work
                if ids_mode:
                    oc, nc = ot.get("commentCount"), nt.get("commentCount")
                    if not (is_count(oc) and is_count(nc) and nc > oc):
                        run()  # no new comment we can count — not ours to absorb
                    changed_ids.append((tid, oc, nc))
                else:
                    changed_ids.append(tid)
    except Exception:
        run()

    if not changed_ids or len(changed_ids) > MAX_CHANGED:
        run()

    if ids_mode:
        print("\n".join("ID %s %d %d" % c for c in changed_ids))
        sys.exit(0)

    for tid in changed_ids:
        try:
            out = subprocess.run(
                ["curl", "-sf", "-m", "20",
                 "-H", f"Authorization: Bearer {token}",
                 "-H", "User-Agent: curl/8",
                 f"{base}{bp}/tickets/{tid}"],
                capture_output=True, timeout=25, check=True)
            author = newest_comment_author(json.loads(out.stdout))
        except Exception:
            run()
        if author not in self_actors:
            run()

    print("ABSORB")


if __name__ == "__main__":
    main()
