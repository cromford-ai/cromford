#!/usr/bin/env python3
"""Close-the-loop pass for the console Alerts screen.

Two failure shapes made 66 rows out of ~20 problems (2026-08-26):
  1. Re-verification files a NEW row. medic/triage akeys carry a per-hour
     suffix and hash the whole line, so "same problem, checked again an hour
     later" is a different akey every time and nothing ever supersedes.
  2. An escalation to a human has no closing edge at all. If nobody proves it
     settled, the row is open forever even after the thing is fixed.

So: collapse by SUBJECT (keep the newest row of each subject, resolve the
older ones as superseded), then TTL anything older than MAX_AGE_H. The TTL is
safe because every producing lane re-verifies on its own cron: a condition that
is still real re-fires within the hour, a condition that is not stays closed.
Never resolves the newest row of a subject.
"""
import json, os, re, subprocess, sys, urllib.request
from datetime import datetime, timezone

# The legacy-auto-key pass (BH-4053) needs the condition shape, which lives in
# the sibling module every alert lane imports. Without it that one pass is
# skipped and said so; the groom's other passes still run.
# The ph-absent pass (BH-4056) needs bin/ph_active.py the same way. Every
# skipped pass is named on ONE stderr line, so the groom log says it once.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_skipped = []
try:
    from alert_family import shape
except Exception as e:
    shape = None
    _skipped.append(f"alert_family unavailable ({type(e).__name__}) — legacy auto-key pass skipped")
try:
    import ph_active
except Exception as e:
    ph_active = None
    _skipped.append(f"ph_active unavailable ({type(e).__name__}) — ph-absent pass skipped")
if _skipped:
    print("alerts-supersede: " + "; ".join(_skipped) + " this run", file=sys.stderr)

MAX_AGE_H = int(os.environ.get("ALERT_TTL_HOURS", "72"))
CONSOLE = os.environ["CONSOLE_URL"].rstrip("/")
SECRET = os.environ["HARNESS_SECRET"]
# HUB_MOVE_NOWRITE=1 is the no-write tick of bin/hub-move.sh (BH-7715): this
# script POSTs with urllib, which the PATH shim cannot see.
DRY = "--dry" in sys.argv or os.environ.get("HUB_MOVE_NOWRITE") == "1"

def _fleet_stems():
    r"""Project name stems from fleet.conf, longest first.

    The alternation these feed used to be the literal four. An alert naming a PR
    on any project enrolled since fell through to the bare `pull/(\d+)` rule, so
    #128 on two different repos collapsed into ONE console row and one of the
    two problems vanished. Returns [] if the registry cannot be read — the
    extractor is then dropped and said so on stderr (alerts-groom.sh tees this
    to its log), rather than silently reinstating a four-name list.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        r = subprocess.run([os.path.join(here, "fleet-conf.sh"), "--projects"],
                           capture_output=True, text=True, timeout=15)
        names = r.stdout.split()
    except Exception:
        names = []
    stems = {n[:-3] if n.endswith("-os") else n for n in names if n}
    # Escaped: these go straight into a regex alternation, and the registry is a
    # file anyone can edit. Today every project name is [a-z0-9-], so this is a
    # no-op — which is exactly when it is cheap to add.
    return [re.escape(s) for s in sorted(stems, key=len, reverse=True)]

_STEMS = _fleet_stems()
if not _STEMS:
    print("alerts-supersede: fleet.conf unreadable — PR-subject collapsing is DISABLED "
          "this run; PRs on different repos with the same number will not be told apart",
          file=sys.stderr)

# Subject extractors, most specific first. First hit wins and becomes the
# collapse key; an alert with no hit is left alone by the collapse pass.
SUBJECT = [
    (r"\b(TK)-(\d+)\b",            lambda m: f"ticket:{m.group(1)}-{m.group(2)}"),
] + ([
    (r"\b(%s)[a-z-]*[ /-]*(?:os)?[^\n]{0,40}?#(\d{2,5})\b" % "|".join(_STEMS),
                                            lambda m: f"pr:{m.group(1)}#{m.group(2)}"),
] if _STEMS else []) + [
    (r"pull/(\d+)",                          lambda m: f"pr:#{m.group(1)}"),
    (r"max-budget-usd|BUDGET FLAG INERT|per-turn cap",
                                            lambda m: "subj:orchestrator-cap"),
    (r"UNBUDGETED LANE|_unbudgeted_stages",  lambda m: "subj:unbudgeted-lane"),
    (r"cache-hit",                           lambda m: "subj:cache-hit"),
    (r"project-8",                 lambda m: "subj:project-8"),
    (r"project-5",                           lambda m: "subj:project-5-pat"),
    (r"project-10",                      lambda m: "subj:project-10"),
    (r"orchestrator-burn",                   lambda m: "subj:orchestrator-burn"),
    (r"pool machine|Fly pool|pool-halt|builder-[a-z]+-os",
                                            lambda m: "subj:fly-pool"),
]

def subject(line):
    for pat, fn in SUBJECT:
        m = re.search(pat, line, re.I)
        if m:
            return fn(m)
    return None

def klass(a):
    """Client-facing triage escalations never collapse into machine pings: they
    can name the same ticket and mean different things (TK-791 the client
    question vs TK-791 the orphaned build dir). Machine lanes collapse freely
    with each other, because a re-verified condition is one problem however
    many crons noticed it."""
    return "triage" if (a.get("akey") or "").startswith("triage") else "machine"

def api(path, data=None):
    req = urllib.request.Request(
        f"{CONSOLE}/api/alerts/{path}",
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Authorization": f"Bearer {SECRET}", "Content-Type": "application/json",
                 "User-Agent": "harness-alerts-supersede/1.0"},
    )
    return json.load(urllib.request.urlopen(req, timeout=30))

def age_h(ts, now):
    try:
        return (now - datetime.fromisoformat(ts.replace("Z", "+00:00"))).total_seconds() / 3600
    except Exception:
        return 0.0

def main():
    d = api("open")
    al = d["alerts"] if isinstance(d, dict) else d
    now = datetime.now(timezone.utc)
    for a in al:
        sub = subject(a.get("line") or "")
        a["_s"] = f"{klass(a)}|{sub}" if sub else None
    al.sort(key=lambda x: x["createdAt"])

    INFO_CLOSED = re.compile(
        r"\bRESOLVED\b|finished rc=0|\brc=0\b.*see logs/|audit done:|LEFT IN PLACE|"
        r"\bNOTE\b .*is WRONG|RECOVERED\b", re.I)

    # Legacy auto keys (BH-4053). A condition that now declares its own id has
    # ONE row, alert:<id>; rows opened before that under alert:auto-<row_key>
    # (one per PR set, for a PR-listing alert) are the same condition and would
    # otherwise sit open until the TTL. Resolved when an explicit row of the
    # same shape is open; the explicit row is never resolved by this, and a
    # legacy row is kept out of the subject newest-pick below so it can never
    # supersede the explicit row it is being retired in favour of.
    legacy = {}
    if shape is not None:
        explicit = {}
        for a in al:
            k, line = a.get("akey") or "", a.get("line") or ""
            if k.startswith("alert:") and not k.startswith("alert:auto-") and line:
                explicit[shape(line)] = k
        for a in al:
            k, line = a.get("akey") or "", a.get("line") or ""
            if k.startswith("alert:auto-") and line and shape(line) in explicit:
                legacy[a["id"]] = explicit[shape(line)]

    # Absent conditions (BH-4056). An open alert:ph-<key> row whose key the
    # last complete pipeline-health pass no longer found has cleared; the
    # lane's own epilogue retracts it in the log, and this closes the row.
    # Only namespaces in the pass's RETRACT_NS (from its stamp): a throttled
    # check is absent on every tick it skips, and those rows keep the TTL.
    # Any doubt about the pass (stale, partial, no stamp) holds the whole pass.
    absent = {}
    if ph_active is not None:
        harness = os.environ.get("HARNESS") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        act, held = ph_active.load_active(harness)
        if held:
            print(f"ph-absent pass held: {held}")
        else:
            for a in al:
                k = a.get("akey") or ""
                if not k.startswith("alert:ph-"):
                    continue
                pid = k[len("alert:"):]
                if ph_active.ns_of(pid) in act["retract_ns"] and pid not in act["ids"]:
                    absent[a["id"]] = act["age_m"]

    resolve, why = [], {}
    newest = {}
    for a in al:
        if a["_s"] and a["id"] not in legacy:
            newest[a["_s"]] = a["id"]
    for a in al:
        s = a["_s"]
        line = a.get("line") or ""
        if INFO_CLOSED.search(line):
            resolve.append(a["id"]); why[a["id"]] = "informational / already declared settled"
        elif a["id"] in legacy:
            resolve.append(a["id"]); why[a["id"]] = f"superseded by {legacy[a['id']]} (legacy auto key, BH-4053)"
        elif a["id"] in absent:
            resolve.append(a["id"]); why[a["id"]] = (
                f"condition absent from health-active.txt (complete pass {absent[a['id']]}m ago, BH-4056)")
        elif s and newest[s] != a["id"]:
            resolve.append(a["id"]); why[a["id"]] = f"superseded by {newest[s]} ({s})"
        elif age_h(a["createdAt"], now) > MAX_AGE_H:
            resolve.append(a["id"]); why[a["id"]] = f"ttl>{MAX_AGE_H}h (re-fires if still real)"

    for i in resolve:
        print(f"resolve {i}: {why[i]}")
    if ph_active is not None:
        print(f"ph-absent resolve={sum(1 for i in resolve if why[i].startswith('condition absent'))}")
    print(f"open={len(al)} resolve={len(resolve)} remaining={len(al)-len(resolve)}")
    if resolve and not DRY:
        api("resolve", {"ids": [str(i) for i in resolve]})
        print("posted")

main()
