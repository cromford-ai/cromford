#!/bin/bash
# tests/landing-replay.bh-6748-test.sh — bin/landing-replay.sh and the source
# fetcher it shares with the digest's landing block (BH-6748, wave 5 of #6541).
#
# S1-S6 source bin/lib/landing-sources.sh and call ls_fetch with a stub
# _jobs_req (the harness-jobs worker) and a stub gh_rest (GitHub REST): the
# decisions pager and its before_id cursor, the page-cap knob, an old worker
# that ignores the cursor, the pulls pager, the no-activity skip.
# R1-R8 drive the production entry point bin/landing-replay.sh with the same
# stubs in a scratch HARNESS: the would-have-landed-directly count, the
# later-reverted and ejected counts, the CI minutes saved, the refusals and
# the exit codes. 0 real vendor calls. Every expected number is counted by
# hand off the fixture rows.
# Run from anywhere: tests/landing-replay.bh-6748-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

command -v jq >/dev/null 2>&1 || { echo "landing-replay: jq required, skipping"; exit 0; }
for F in "$DIR/bin/landing-replay.sh" "$DIR/bin/lib/landing-sources.sh" "$DIR/bin/dora_landing.py"; do
  [ -r "$F" ] || { echo "FAIL: $F is missing"; exit 1; }
done

cat > "$T/fleet.conf" <<'CONF'
p1  o/r  https://p1.test  -  1 box-a 192.0.2.1
CONF
export FLEET_CONF="$T/fleet.conf"
unset LANDING_REPORT_DECISION_PAGES LANDING_REPORT_LEDGER_PAGES LANDING_REPORT_GH_PAGES LANDING_REPLAY_DAYS

# tree <name> — a scratch HARNESS with the two stubs.
#   bin/jobs-client.sh  _jobs_req: /api/settings answers no rows; the
#     decisions route answers fx/ld-<before_id>.json (fx/ld-.json with no
#     cursor; STUB_OLD_WORKER=1 ignores the cursor; STUB_FAIL_DECISIONS=1 is
#     rc 1); the ledger fx/ledger.json; ci-batches fx/ci.json. setting_get
#     answers rows/<key> when that file exists, else rc 2 (no row).
#   bin/lib/gh-rest.sh  gh_rest: the pulls list from fx/pulls-<page>.json.
tree() {
  local h="$T/$1"
  mkdir -p "$h/bin/lib" "$h/fx" "$h/rows" "$h/logs"
  cat > "$h/bin/jobs-client.sh" <<'SH'
_fx() { local f="$HARNESS/fx/$1"; if [ -f "$f" ]; then cat "$f"; else printf '%s' "$2"; fi; }
_jobs_req() {
  [ "$2" = /api/settings ] && { printf '{"settings":[]}'; return 0; }
  echo "$*" >> "$HARNESS/calls"
  local b=""
  case "$2" in
    /api/landing-decisions\?*)
      [ "${STUB_FAIL_DECISIONS:-0}" = 1 ] && return 1
      case "$2" in *before_id=*) b="${2##*before_id=}"; b="${b%%&*}" ;; esac
      [ "${STUB_OLD_WORKER:-0}" = 1 ] && b=""
      _fx "ld-$b.json" '{"rows":[],"truncated":false}' ;;
    /api/ledger\?kind=merge*) _fx ledger.json '{"ledgers":[]}' ;;
    /api/ci-batches\?*) _fx ci.json '{"rows":[],"truncated":false}' ;;
    *) return 1 ;;
  esac
}
setting_get() { [ -f "$HARNESS/rows/$1" ] || return 2; cat "$HARNESS/rows/$1"; }
SH
  cat > "$h/bin/lib/gh-rest.sh" <<'SH'
gh_rest() {
  echo "$* optional=${GH_REST_OPTIONAL:-0}" >> "$HARNESS/gh-calls"
  case "$2" in
    repos/o/r/pulls\?*) local n="${2##*page=}"
      if [ -f "$HARNESS/fx/pulls-$n.json" ]; then cat "$HARNESS/fx/pulls-$n.json"; else printf '[]'; fi
      GH_REST_STATUS=200; return 0 ;;
  esac
  GH_REST_STATUS=404; return 44
}
SH
  printf '%s' "$h"
}
ghn() { if [ -f "$1/gh-calls" ]; then wc -l < "$1/gh-calls" | tr -d ' '; else echo 0; fi; }
iso_ago() { date -u -d "$1 ago" '+%Y-%m-%dT%H:%M:%SZ'; }

# fixture <root> — the 7-day replay fixture (R1). Decisions for o/r:
#   would=direct: PR 1 (heads a1.. then b1.., newest b1), 2, 3, 4, 5, 6
#   would=queue:  PR 7 tier-high, PR 8 tier-high, PR 9 schema
#   one 10-day-old row (PR 99), before the window.
# Merges (ledger): 1, 2, 3, 4, 7 queued; 5 direct; an 8-day-old merge.
# Pulls: revert #90 of #2 (merged, labelled), revert #91 of #4 (not merged).
# Attempts: ejected #3 at its decided head; ejected #1 at its OLD head;
#   ejectrebase #4 at its head.
# Batches: 40 + 60 billed min in the window -> 100 / 5 queued = 20 per merge.
# Hand count: would_direct 6, merged 5, reverted 1 (#2), ejected 1 (#3),
#   pending 1 (#6), ci_min_saved = 4 (#1-#4 merged queued) x 20 = 80.0.
fixture() {
  python3 - "$1" <<'PY'
import json, sys, datetime as d
h = sys.argv[1]
now = d.datetime.now(d.timezone.utc).replace(microsecond=0)
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
ago = lambda **k: iso(now - d.timedelta(**k))
def w(name, obj):
    json.dump(obj, open("%s/fx/%s" % (h, name), "w"))
def hd(n, c="c"):
    return ("%s%x" % (c, n)) * 20
def dec(i, n, would="direct", head=None, reason=None, at=None):
    return dict(id=i, repo="o/r", number=n, head=head or hd(n), mode="shadow", would=would,
                reason=reason or ("ok" if would == "direct" else "tier-high"), at=at or ago(days=2),
                outcome=None, outcome_at=None)
rows = [dec(11, 6), dec(10, 9, "queue", reason="schema"), dec(9, 8, "queue"), dec(8, 7, "queue"),
        dec(7, 5), dec(6, 4), dec(5, 3), dec(4, 2), dec(3, 1, head=hd(1, "b")), dec(2, 1, head=hd(1, "a")),
        dec(1, 99, at=ago(days=10))]
w("ld-.json", {"rows": rows, "truncated": False})
def led(n, detail="merge-conductor", at=None):
    return dict(kind="merge", key="https://github.com/o/r/pull/%d" % n, status="merged",
                detail=detail, updated_at=at or ago(days=1))
w("ledger.json", {"ledgers": [led(1), led(2), led(3), led(4), led(7), led(5, "merge-conductor path=direct"),
                              led(98, at=ago(days=8))]})
w("ci.json", {"rows": [dict(repo="o/r", billed_min=40, completed_at=ago(days=1)),
                       dict(repo="o/r", billed_min=60, completed_at=ago(days=1))], "truncated": False})
def pr(n, title="t", merged=None, labels=()):
    return dict(number=n, title=title, created_at=ago(days=3), merged_at=merged,
                updated_at=merged or ago(days=1), head={"ref": "ticket/x"}, body="",
                labels=[{"name": l} for l in labels])
w("pulls-1.json", [pr(90, "revert: #2 — boom", ago(minutes=10), ["fix-main-red"]),
                   pr(91, "revert: #4 — boom", None, ["fix-main-red"])]
                  + [pr(n, merged=ago(days=1)) for n in (1, 2, 3, 4, 5, 7)])
open("%s/attempts.txt" % h, "w").write("ejected o/r#3 %s\nejected o/r#1 %s\nejectrebase o/r#4 %s\n"
                                       % (hd(3), hd(1, "a"), hd(4)))
PY
}
replay() {
  local h="$1"; shift
  HARNESS="$h" LANDING_ATTEMPTS="$h/attempts.txt" "$DIR/bin/landing-replay.sh" "$@" > "$h/out" 2> "$h/err"
}
line() { grep "^LANDING_REPLAY $2" "$1/out"; }

# ── S: ls_fetch ─────────────────────────────────────────────────────────────
# fetch <root> <since> — ls_fetch into <root>/src with the root's stubs.
fetch() {
  ( export HARNESS="$1"
    . "$1/bin/jobs-client.sh"; . "$1/bin/lib/gh-rest.sh"
    # shellcheck source=../bin/lib/landing-sources.sh
    . "$DIR/bin/lib/landing-sources.sh" || exit 9
    printf 'p1\to/r\n' > "$1/repos.tsv"
    LANDING_ATTEMPTS="$1/attempts.txt" ls_fetch "$1/src" "$2" "$1/repos.tsv" )
}
SRCJ() { jq -r "$2" "$1/src/sources.json"; }

# S1 round trip: the dir ls_fetch writes, read by both readers.
S1=$(tree s1); fixture "$S1"
SINCE=$(iso_ago "7 days"); NOW=$(iso_ago "0 seconds")
fetch "$S1" "$SINCE"
eq "S1 ls_fetch rc" "$?" "0"
for f in decisions.jsonl merges.jsonl ci-batches.jsonl pulls.jsonl ejected.txt sources.json; do
  [ -f "$S1/src/$f" ] && ok || bad "S1 $f written"
done
eq "S1 decisions in the window" "$(wc -l < "$S1/src/decisions.jsonl" | tr -d ' ')" "10"
eq "S1 merged ledger rows in the window" "$(wc -l < "$S1/src/merges.jsonl" | tr -d ' ')" "6"
eq "S1 ejected lines" "$(wc -l < "$S1/src/ejected.txt" | tr -d ' ')" "2"
RJ=$(python3 "$DIR/bin/dora_landing.py" replay "$S1/src" "$SINCE" "$NOW" --json)
eq "S1 replay would_direct" "$(jq -r '.total.would_direct' <<<"$RJ")" "6"
eq "S1 replay ci_min_saved" "$(jq -r '.total.ci_min_saved == 80' <<<"$RJ")" "true"
BJ=$(python3 - "$DIR/bin" "$S1/src" "$SINCE" "$NOW" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import dora_landing as dl
b = dl.block(dl.load(sys.argv[2]), sys.argv[3], sys.argv[4], {"o/r": "p1"})
print(json.dumps(b))
PY
)
eq "S1 block p1 merges" "$(jq -r '.projects.p1.merges | "\(.direct) \(.queued)"' <<<"$BJ")" "1 5"
eq "S1 block p1 direct reverted (PR 5 not reverted)" "$(jq -r '.projects.p1.direct_reverted | "\(.reverted) of \(.of)"' <<<"$BJ")" "0 of 1"

# S2 the decisions pager: 3 pages by before_id, stops at the first row before since.
S2=$(tree s2)
python3 - "$S2" "$(iso_ago "7 days")" <<'PY'
import json, sys, datetime as d
h, since = sys.argv[1], sys.argv[2]
now = d.datetime.now(d.timezone.utc).replace(microsecond=0)
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
def row(i):
    at = iso(now - d.timedelta(days=10)) if i <= 5 else iso(now - d.timedelta(hours=i))
    return dict(id=i, repo="o/r", number=i, head="a" * 40, mode="shadow", would="queue", reason="solo", at=at)
for name, ids, tr in (("ld-.json", range(30, 20, -1), True), ("ld-21.json", range(20, 10, -1), True),
                      ("ld-11.json", range(10, 0, -1), False)):
    json.dump({"rows": [row(i) for i in ids], "truncated": tr}, open("%s/fx/%s" % (h, name), "w"))
PY
fetch "$S2" "$(iso_ago "7 days")"
eq "S2 the exact decisions requests" "$(grep landing-decisions "$S2/calls")" "GET /api/landing-decisions?repo=o/r&limit=200
GET /api/landing-decisions?repo=o/r&limit=200&before_id=21
GET /api/landing-decisions?repo=o/r&limit=200&before_id=11"
eq "S2 rows kept: ids 30..6" "$(jq -s -r 'map(.id) | "\(length) \(max) \(min)"' "$S2/src/decisions.jsonl")" "25 30 6"
eq "S2 pages, not capped" "$(SRCJ "$S2" '.decisions | "\(.status) \(.pages) \(.capped)"')" "ok 3 false"

# S3 the settings row landing.report.decision_pages=1 caps after one page.
S3=$(tree s3); cp "$S2"/fx/ld-*.json "$S3/fx/"; echo 1 > "$S3/rows/landing.report.decision_pages"
fetch "$S3" "$(iso_ago "7 days")"
eq "S3 one decisions request" "$(grep -c landing-decisions "$S3/calls")" "1"
eq "S3 capped" "$(SRCJ "$S3" '.decisions | "\(.status) \(.capped)"')" "ok true"
eq "S3 the row is the knob's source" "$(SRCJ "$S3" '.knobs.decision_pages')" "1"

# S4 an old worker that ignores before_id: stop after page 2, capped, cursor ignored.
S4=$(tree s4); cp "$S2"/fx/ld-*.json "$S4/fx/"
STUB_OLD_WORKER=1 fetch "$S4" "$(iso_ago "7 days")"
eq "S4 two decisions requests" "$(grep -c landing-decisions "$S4/calls")" "2"
eq "S4 capped, why" "$(SRCJ "$S4" '.decisions | "\(.capped) \(.why)"')" "true o/r: cursor ignored"
eq "S4 page 1's rows once" "$(wc -l < "$S4/src/decisions.jsonl" | tr -d ' ')" "10"

# S5 the pulls pager: the revert is on page 2; stop at the first row before since.
S5=$(tree s5)
python3 - "$S5" <<'PY'
import json, sys, datetime as d
h = sys.argv[1]
now = d.datetime.now(d.timezone.utc).replace(microsecond=0)
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
ago = lambda **k: iso(now - d.timedelta(**k))
json.dump({"rows": [dict(id=1, repo="o/r", number=5, head="a" * 40, mode="shadow", would="direct",
                         reason="ok", at=ago(days=1))], "truncated": False}, open(h + "/fx/ld-.json", "w"))
json.dump({"ledgers": [dict(key="https://github.com/o/r/pull/5", status="merged",
                            detail="merge-conductor path=direct", updated_at=ago(hours=20))]},
          open(h + "/fx/ledger.json", "w"))
def pr(n, upd, title="t", labels=(), merged=None):
    return dict(number=n, title=title, created_at=upd, merged_at=merged, updated_at=upd,
                head={"ref": "x"}, body="", labels=[{"name": l} for l in labels])
json.dump([pr(100 + i, ago(hours=1)) for i in range(100)], open(h + "/fx/pulls-1.json", "w"))
json.dump([pr(300, ago(hours=2), "revert: #5 — x", ["fix-main-red"], ago(hours=2)), pr(301, ago(days=9))],
          open(h + "/fx/pulls-2.json", "w"))
json.dump([pr(400, ago(hours=3), "revert: #5 — y", ["fix-main-red"], ago(hours=3))], open(h + "/fx/pulls-3.json", "w"))
PY
fetch "$S5" "$(iso_ago "7 days")"
eq "S5 two pulls pages" "$(ghn "$S5")" "2"
eq "S5 pulls rows kept (page 1 + the revert)" "$(wc -l < "$S5/src/pulls.jsonl" | tr -d ' ')" "101"
eq "S5 the revert is found" "$(python3 - "$DIR/bin" "$S5/src" "$(iso_ago "7 days")" "$(iso_ago "0 seconds")" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import dora_landing as dl
b = dl.block(dl.load(sys.argv[2]), sys.argv[3], sys.argv[4], {"o/r": "p1"})
print(b["projects"]["p1"]["direct_reverted"])
PY
)" "{'reverted': 1, 'of': 1}"
eq "S5 GitHub reads marked optional" "$(grep -c 'optional=1$' "$S5/gh-calls")" "2"

# S6 no landing activity: 0 GitHub calls, ci-batches not read.
S6=$(tree s6)
echo '{"ledgers":[{"key":"https://github.com/o/r/pull/1","status":"merged","detail":"merge-conductor","updated_at":"'"$(iso_ago "1 day")"'"}]}' > "$S6/fx/ledger.json"
fetch "$S6" "$(iso_ago "7 days")"
eq "S6 0 GitHub calls" "$(ghn "$S6")" "0"
eq "S6 ci-batches not read" "$(grep -c ci-batches "$S6/calls")" "0"
eq "S6 pulls off" "$(SRCJ "$S6" '.pulls | "\(.status) \(.why)"')" "off no landing activity"
eq "S6 ci_batches off" "$(SRCJ "$S6" '.ci_batches.status')" "off"

# S7 the error arms, one ls_fetch each, with stubs defined here.
S7=$(tree s7); SINCE7=$(iso_ago "7 days")
printf 'p1\to/r\np2\to/q\n' > "$S7/repos.tsv"
s7() { # s7 <case> <body>: ls_fetch into $S7/<case> in a subshell where <body> defines the stubs
  ( unset HARNESS H LANDING_ATTEMPTS
    . "$DIR/bin/lib/landing-sources.sh" || exit 9
    eval "$2"
    ls_fetch "$S7/$1" "$SINCE7" "$S7/repos.tsv" )
}
s7 noclient ':'
eq "S7 no worker client: decisions error" "$(jq -r '.decisions | "\(.status) \(.why)"' "$S7/noclient/sources.json")" \
  "error no worker client (bin/jobs-client.sh)"
eq "S7 no harness root: ejected absent" "$(jq -r '.ejected | "\(.status) \(.why)"' "$S7/noclient/sources.json")" \
  "absent no harness root (HARNESS unset)"
# shellcheck disable=SC2034  # LD is read inside the s7 eval bodies below
LD='{"rows":[{"id":1,"repo":"o/r","number":5,"head":"'"$(printf 'a%.0s' $(seq 40))"'","mode":"shadow","would":"direct","reason":"ok","at":"'"$(iso_ago "1 day")"'"}],"truncated":false}'
s7 nogh '_jobs_req() { case "$2" in
    /api/landing-decisions\?repo=o/r*) printf "%s" "$LD" ;;
    /api/landing-decisions*) return 1 ;;
    /api/ledger*) printf "{\"ledgers\":[]}" ;;
    *) return 1 ;; esac; }'
eq "S7 one repo of two failed: decisions partial" "$(jq -r '.decisions | "\(.status) \(.failed | join(","))"' "$S7/nogh/sources.json")" "partial o/q"
eq "S7 ci-batches read failed: error" "$(jq -r '.ci_batches.status' "$S7/nogh/sources.json")" "error"
eq "S7 no gh_rest: pulls error" "$(jq -r '.pulls | "\(.status) \(.why)"' "$S7/nogh/sources.json")" \
  "error gh_rest is not loaded (bin/lib/gh-rest.sh)"
s7 gh75 '_jobs_req() { case "$2" in
    /api/landing-decisions*) printf "%s" "$LD" ;;
    /api/ledger*) return 1 ;;
    /api/ci-batches*) printf "{\"rows\":[],\"truncated\":false}" ;;
    *) return 1 ;; esac; }
  gh_rest() { GH_REST_STATUS=403; GH_REST_REASON=rate-limit; return 75; }'
eq "S7 ledger read failed: merges error" "$(jq -r '.merges.status' "$S7/gh75/sources.json")" "error"
jq -r '.pulls.why' "$S7/gh75/sources.json" | grep -q 'rc 75 (rate-limit)' && ok \
  || bad "S7 gh rc 75: $(jq -r '.pulls | "\(.status) \(.why)"' "$S7/gh75/sources.json")"
eq "S7 gh rc 75: pulls error" "$(jq -r '.pulls.status' "$S7/gh75/sources.json")" "error"

# ── R: bin/landing-replay.sh ───────────────────────────────────────────────
R1=$(tree r1); fixture "$R1"
replay "$R1" --days 7
eq "R1 rc 0" "$?" "0"
eq "R1 the repo line" "$(line "$R1" repo=o/r)" \
  "LANDING_REPLAY repo=o/r days=7 would_direct=6 merged=5 reverted=1 ejected=1 ci_min_saved=80.0 pending=1"
eq "R1 the total line" "$(line "$R1" total)" \
  "LANDING_REPLAY total days=7 would_direct=6 merged=5 reverted=1 ejected=1 ci_min_saved=80.0 pending=1"
eq "R1 the evidence rows are the last lines" "$(tail -2 "$R1/out" | cut -d' ' -f1 | sort -u)" "LANDING_REPLAY"
eq "R1 top queue reasons" "$(grep '^top queue reasons:' "$R1/out")" "top queue reasons: tier-high=2 schema=1"
eq "R1 a source line per source" "$(grep -c '^source ' "$R1/out")" "5"
grep -q '^source decisions: ok$' "$R1/out" && ok || bad "R1 source decisions line: $(grep '^source' "$R1/out")"
# A person pastes these lines; awk reads them back.
eq "R1 awk reads the line back" "$(line "$R1" repo=o/r | awk '{for(i=2;i<=NF;i++){split($i,a,"=");if(a[1]=="would_direct")print a[2]}}')" "6"

# R2 later-reverted: an unmerged revert (#91 of #4) does not count, a merged one (#90 of #2) does.
replay "$R1" --days 7 --json
eq "R2 reverted" "$(jq -r '.repos["o/r"].reverted' "$R1/out")" "1"
python3 - "$R1/fx/pulls-1.json" <<'PY'
import json, sys, datetime as d
p = json.load(open(sys.argv[1]))
for r in p:
    if r["number"] == 91:
        r["merged_at"] = d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(p, open(sys.argv[1], "w"))
PY
replay "$R1" --days 7
eq "R2 a revert merged just now counts" "$(line "$R1" repo=o/r | grep -o 'reverted=[^ ]*')" "reverted=2"

# R3 ejected counts only the decided head: drop #3's line, #1's old-head line stays.
R3=$(tree r3); fixture "$R3"
sed -i '/^ejected o\/r#3 /d' "$R3/attempts.txt"
replay "$R3" --days 7
eq "R3 old head and ejectrebase do not count" "$(line "$R3" repo=o/r | grep -o 'ejected=[^ ]*')" "ejected=0"
rm -f "$R3/attempts.txt"
replay "$R3" --days 7
eq "R3 no attempts file: n/a" "$(line "$R3" repo=o/r | grep -o 'ejected=[^ ]*')" "ejected=n/a"

# R4 ci_min_saved: the hand value above; n/a with no batch rows.
R4=$(tree r4); fixture "$R4"; echo '{"rows":[],"truncated":false}' > "$R4/fx/ci.json"
replay "$R4" --days 7
eq "R4 no batch rows: n/a" "$(line "$R4" repo=o/r | grep -o 'ci_min_saved=[^ ]*')" "ci_min_saved=n/a"

# R5 refusals: rc 2, nothing read.
R5=$(tree r5); fixture "$R5"
for a in "--days 0" "--days abc" "--days 91" "--bogus" "--last 0"; do
  # shellcheck disable=SC2086  # the arguments, split on purpose
  replay "$R5" $a
  eq "R5 '$a' rc 2" "$?" "2"
done
eq "R5 no worker read" "$([ -f "$R5/calls" ] && cat "$R5/calls")" ""
eq "R5 no GitHub read" "$(ghn "$R5")" "0"
echo 2 > "$R5/rows/landing.replay.days"
replay "$R5"
eq "R5 the settings row sets the default window" "$(line "$R5" total | grep -o 'days=[^ ]*')" "days=2"

# R6 every decisions read fails: rc 3, the lines print n/a.
R6=$(tree r6); fixture "$R6"
STUB_FAIL_DECISIONS=1 replay "$R6" --days 7
eq "R6 rc 3" "$?" "3"
eq "R6 repo line n/a" "$(line "$R6" repo=o/r)" \
  "LANDING_REPLAY repo=o/r days=7 would_direct=n/a merged=n/a reverted=n/a ejected=n/a ci_min_saved=n/a pending=n/a"
grep -q '^source decisions: error ' "$R6/out" && ok || bad "R6 source line: $(grep '^source decisions' "$R6/out")"
eq "R6 no GitHub read" "$(ghn "$R6")" "0"

# R7 --last 3: the 3 newest rows (ids 11, 10, 9): PR 6 direct, PRs 9 and 8 queue.
R7=$(tree r7); fixture "$R7"
replay "$R7" --days 7 --last 3
eq "R7 rc 0" "$?" "0"
eq "R7 the repo line" "$(line "$R7" repo=o/r)" \
  "LANDING_REPLAY repo=o/r days=7 would_direct=1 merged=0 reverted=0 ejected=0 ci_min_saved=0.0 pending=1"
eq "R7 reasons" "$(grep '^top queue reasons:' "$R7/out")" "top queue reasons: schema=1 tier-high=1"

# R8 --json: the same numbers as keys.
R8=$(tree r8); fixture "$R8"
replay "$R8" --days 7 --json
eq "R8 rc 0" "$?" "0"
eq "R8 json numbers" "$(jq -r '.repos["o/r"] | "\(.would_direct) \(.merged) \(.reverted) \(.ejected) \(.ci_min_saved == 80) \(.pending)"' "$R8/out")" "6 5 1 1 true 1"
eq "R8 json total" "$(jq -r '.total.would_direct' "$R8/out")" "6"
eq "R8 json fallbacks" "$(jq -r '.fallbacks.pending | "\(.n) \(.of)"' "$R8/out")" "1 6"
eq "R8 json days" "$(jq -r '.days' "$R8/out")" "7"

echo "landing-replay: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
