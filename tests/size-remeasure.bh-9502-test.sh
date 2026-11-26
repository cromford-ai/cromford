#!/bin/bash
# tests/size-remeasure.bh-9502-test.sh — bin/size-remeasure.sh, the 14-day size
# re-measure one-shot on #6025 (BH-9502, slice C5 of #9441).
#
# S1  classification of build dirs (a)-(m) of the plan's decision table: the
#     abandoned and closed-unmerged counts per bucket; (f)-(k) not counted.
# S2  dedup: two dirs with one PR URL count once (newest wins), two dirs with
#     no URL count twice; the stderr summary says deduped=1.
# S3  size buckets: 0 599 | 600 1200 | 1201 3000 | 3001, two SIZE lines (the
#     last wins), and four unmeasured cases (no SIZE line, "could not be
#     measured", "1,412", no pipeline.log).
# S4  per repo: two PR repos and one job.json project -> three repo rows.
# S5  an empty builds dir -> the header, zero totals, the "No ..." line, rc 0.
# S6  edges not ascending -> the 600/1200/3000 fallback and one line naming it.
# K1  no knob env -> the four default column titles.
# G1-G10  the gate, the thread check, the post, the alert dedup, the report argv.
# D1-D2  --dry-run posts nothing, writes no state, prints the tables.
# C1  the comment body. C2  the script writes no limit.
# L1  flags/all-off -> exit 0 and the lane-gate SKIPPED line.
#
# No network: gh is a stub on PATH that answers from files and logs every call,
# split-chain-report.sh is a stub through SIZE_REMEASURE_SPLIT_CHAIN, and the
# clock is pinned through SIZE_REMEASURE_NOW. Every case has its own dirs.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCR="$DIR/bin/size-remeasure.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: no [$3] in output:"; sed -n '1,40s/^/    /p' <<<"$2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected [$3]"; else ok; fi; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
[ -x "$SCR" ] || { echo "FAIL: $SCR missing or not executable"; echo "size-remeasure: 0 passed, 1 failed"; exit 1; }

# Pinned clock: 2027-01-15T08:00:00Z.
NOW=1800000000
DAY=86400
URLB="https://github.com/example-org/cromford/pull"
URLM="https://github.com/example-org/project-6/pull"

# Every case runs with a clean knob env.
unset SIZE_REMEASURE_DELAY_DAYS SIZE_REMEASURE_WINDOW_DAYS SIZE_REMEASURE_EDGE_LOW \
  SIZE_REMEASURE_EDGE_MID SIZE_REMEASURE_EDGE_HIGH SIZE_REMEASURE_GATE_ISSUES \
  SIZE_REMEASURE_TARGET_ISSUE SIZE_REMEASURE_MAX_PAGES SIZE_REMEASURE_SPLIT_CHAIN 2>/dev/null
export SIZE_REMEASURE_NOW="$NOW"
export HARNESS_REPO=example-org/cromford
unset JOBS_URL HARNESS_SECRET GH_TOKEN LANE_RUN_ID 2>/dev/null
# The lane loads <env dir>/global.env; never the box's /etc/harness/env here.
mkdir -p "$T/env"; export HARNESS_ENV_DIR="$T/env"

# mk <builds> <name> <RESULT line> <marker: none|abandoned|superseded|both>
#    <size: N|none|nolog|unmeasured|comma|two:A:B> <age s> [project]
# The age is applied to the file that decides the class (and to RESULT).
mk() {
  local b="$1" n="$2" res="$3" mark="$4" size="$5" age="$6" proj="${7:-cromford}" d t
  d="$b/$n"; mkdir -p "$d"
  printf '%s\n' "$res" > "$d/RESULT"
  printf '{"project":"%s","key":"X-1"}\n' "$proj" > "$d/job.json"
  case "$size" in
    nolog) ;;
    none) echo "2027-01-01 00:00:00Z [$proj/X-1] BUILD: ok" > "$d/pipeline.log" ;;
    unmeasured) echo "2027-01-01 00:00:00Z [$proj/X-1] SIZE: the shipped diff could not be measured against main — no size note on this PR" > "$d/pipeline.log" ;;
    comma) echo "2027-01-01 00:00:00Z [$proj/X-1] SIZE: shipped 1,412 product lines in 3 file(s) (bound 1200)" > "$d/pipeline.log" ;;
    two:*) IFS=: read -r _ x y <<<"$size"
           { echo "2027-01-01 00:00:00Z [$proj/X-1] SIZE: shipped $x product lines in 3 file(s) (bound 1200)"
             echo "2027-01-01 01:00:00Z [$proj/X-1] SIZE: shipped $y product lines in 2 file(s) (bound 1200)"; } > "$d/pipeline.log" ;;
    *) echo "2027-01-01 00:00:00Z [$proj/X-1] SIZE: shipped $size product lines in 3 file(s) (bound 1200)" > "$d/pipeline.log" ;;
  esac
  t=$((${FIXNOW:-$NOW} - age))
  case "$mark" in
    abandoned) : > "$d/.blocked-resolver-abandoned" ;;
    superseded) : > "$d/.blocked-resolver-superseded" ;;
    both) : > "$d/.blocked-resolver-abandoned"; : > "$d/.blocked-resolver-superseded" ;;
  esac
  touch -d "@$t" "$d/RESULT" "$d"/.blocked-resolver-* 2>/dev/null
}

# The S1 fixture: the plan's cases (a)-(k), one dir each.
s1_fixture() {
  local b="$1"; mkdir -p "$b"
  mk "$b" a-timeout   "ABANDONED_TIMEOUT lane ran past its deadline" none 100  3600 project-3
  mk "$b" b-abandoned "PR_CREATED $URLB/101" abandoned 700  7200
  mk "$b" c-both      "PR_CREATED $URLB/102" both      2000 7200
  mk "$b" d-closed    "PR_CLOSED $URLB/103"  none      5000 7200
  mk "$b" e-superseded "PR_CREATED $URLB/104" superseded 100 7200
  mk "$b" f-merged    "PR_MERGED $URLB/105"  none      100  7200
  mk "$b" g-open      "PR_CREATED $URLB/106" none      100  7200
  mk "$b" h-word      "REVIEW_BLOCKED findings ABANDONED by nobody" none 100 7200
  mk "$b" i-lower     "abandoned by hand" none 100 7200
  mk "$b" j-old       "PR_CREATED $URLB/107" abandoned 100  $((15 * DAY))
  mk "$b" k-future    "PR_CREATED $URLB/108" abandoned 100  -3600
}
row() { grep -F "| $2 | $3 |" <<<"$1" | head -1 | tr -s ' '; }

# ---------------------------------------------------------------------------
# S1 — classification
# ---------------------------------------------------------------------------
B1="$T/s1/builds"; s1_fixture "$B1"
OUT=$("$SCR" buckets --builds "$B1" --days 14 2>"$T/s1.err"); RC=$?
eq "S1 rc" "$RC" 0
eq "S1 abandoned totals" "$(row "$OUT" 'all repos' abandoned)" "| all repos | abandoned | 1 | 1 | 1 | 0 | 0 |"
eq "S1 closed totals" "$(row "$OUT" 'all repos' closed-unmerged)" "| all repos | closed-unmerged | 1 | 0 | 0 | 1 | 0 |"
eq "S1 cromford abandoned" "$(row "$OUT" example-org/cromford abandoned)" "| example-org/cromford | abandoned | 0 | 1 | 1 | 0 | 0 |"
eq "S1 project-3 abandoned (job.json project)" "$(row "$OUT" project-3 abandoned)" "| project-3 | abandoned | 1 | 0 | 0 | 0 | 0 |"
has "S1 summary" "$(cat "$T/s1.err")" "size-remeasure buckets: scanned=11 counted=5 deduped=0 unmeasured=0"

# ---------------------------------------------------------------------------
# S2 — dedup
# ---------------------------------------------------------------------------
B2="$T/s2/builds"; mkdir -p "$B2"
mk "$B2" l-old  "PR_CLOSED $URLB/201" none 100 $((3 * DAY))
mk "$B2" l-new  "PR_CLOSED $URLB/201" none 700 "$DAY"
mk "$B2" m-one  "ABANDONED_TIMEOUT x" none 100 3600 project-3
mk "$B2" m-two  "ABANDONED_TIMEOUT y" none 100 3600 project-3
OUT=$("$SCR" buckets --builds "$B2" --days 14 2>"$T/s2.err")
eq "S2 same URL counts once, newest size wins" "$(row "$OUT" 'all repos' closed-unmerged)" "| all repos | closed-unmerged | 0 | 1 | 0 | 0 | 0 |"
eq "S2 no URL counts per dir" "$(row "$OUT" 'all repos' abandoned)" "| all repos | abandoned | 2 | 0 | 0 | 0 | 0 |"
has "S2 summary deduped=1" "$(cat "$T/s2.err")" "deduped=1"

# ---------------------------------------------------------------------------
# S3 — the size buckets
# ---------------------------------------------------------------------------
B3="$T/s3/builds"; mkdir -p "$B3"; i=300
for s in 0 599 600 1200 1201 3000 3001 two:5000:100 none unmeasured comma nolog; do
  i=$((i + 1)); mk "$B3" "sz-$i" "PR_CLOSED $URLB/$i" none "$s" 3600
done
OUT=$("$SCR" buckets --builds "$B3" --days 14 2>"$T/s3.err")
eq "S3 bucket edges" "$(row "$OUT" 'all repos' closed-unmerged)" "| all repos | closed-unmerged | 3 | 2 | 2 | 1 | 4 |"
has "S3 summary unmeasured=4" "$(cat "$T/s3.err")" "unmeasured=4"

# ---------------------------------------------------------------------------
# S4 — per repo
# ---------------------------------------------------------------------------
B4="$T/s4/builds"; mkdir -p "$B4"
mk "$B4" r1 "PR_CLOSED $URLB/401" none 100 3600
mk "$B4" r2 "PR_CLOSED $URLM/402" none 900 3600 project-6
mk "$B4" r3 "ABANDONED_TIMEOUT z" none 4000 3600 project-3
OUT=$("$SCR" buckets --builds "$B4" --days 14 2>/dev/null)
eq "S4 cromford" "$(row "$OUT" example-org/cromford closed-unmerged)" "| example-org/cromford | closed-unmerged | 1 | 0 | 0 | 0 | 0 |"
eq "S4 project-6" "$(row "$OUT" example-org/project-6 closed-unmerged)" "| example-org/project-6 | closed-unmerged | 0 | 1 | 0 | 0 | 0 |"
eq "S4 project-3" "$(row "$OUT" project-3 abandoned)" "| project-3 | abandoned | 0 | 0 | 0 | 1 | 0 |"
eq "S4 repo rows" "$(grep -c '^| example-org/\|^| project-3' <<<"$OUT")" 3

# ---------------------------------------------------------------------------
# S5 — empty builds dir
# ---------------------------------------------------------------------------
mkdir -p "$T/s5/builds"
OUT=$("$SCR" buckets --builds "$T/s5/builds" --days 14 2>/dev/null); RC=$?
eq "S5 rc" "$RC" 0
has "S5 header" "$OUT" "| repo | outcome | under 600 | 600 to 1200 | 1200 to 3000 | over 3000 | unmeasured |"
eq "S5 zero abandoned" "$(row "$OUT" 'all repos' abandoned)" "| all repos | abandoned | 0 | 0 | 0 | 0 | 0 |"
eq "S5 zero closed" "$(row "$OUT" 'all repos' closed-unmerged)" "| all repos | closed-unmerged | 0 | 0 | 0 | 0 | 0 |"
has "S5 empty line" "$OUT" "No ABANDONED or closed-unmerged PR in the window."

# ---------------------------------------------------------------------------
# S6 / K1 — the edges knobs
# ---------------------------------------------------------------------------
OUT=$(SIZE_REMEASURE_EDGE_LOW=1200 SIZE_REMEASURE_EDGE_MID=600 SIZE_REMEASURE_EDGE_HIGH=3000 \
  "$SCR" buckets --builds "$B3" --days 14 2>"$T/s6.err")
has "S6 fallback titles" "$OUT" "| under 600 | 600 to 1200 | 1200 to 3000 | over 3000 |"
eq "S6 fallback counts" "$(row "$OUT" 'all repos' closed-unmerged)" "| all repos | closed-unmerged | 3 | 2 | 2 | 1 | 4 |"
eq "S6 one line names the bad value" "$(grep -c 'bad bucket edges 1200/600/3000' "$T/s6.err")" 1
OUT=$(SIZE_REMEASURE_EDGE_LOW=500 SIZE_REMEASURE_EDGE_MID=1000 SIZE_REMEASURE_EDGE_HIGH=2000 \
  "$SCR" buckets --builds "$T/s5/builds" --days 14 2>/dev/null)
has "S6 a valid knob renders its titles" "$OUT" "| under 500 | 500 to 1000 | 1000 to 2000 | over 2000 |"
OUT=$("$SCR" buckets --builds "$T/s5/builds" 2>/dev/null)
has "K1 default titles" "$OUT" "| under 600 | 600 to 1200 | 1200 to 3000 | over 3000 |"

# ---------------------------------------------------------------------------
# The lane: a scratch HARNESS, a gh stub, a split-chain stub.
# ---------------------------------------------------------------------------
# GHS is the stub's answer dir for the current case; it logs to $GHS/log.
mkdir -p "$T/stubbin"
# BH-10143: the lane reaches GitHub through the tracker seam, so through
# bin/lib/gh-rest.sh, which calls `gh api -i -X <M> <path> ...` and reads an
# HTTP status line, a blank line and the body. The stub answers in that shape
# from the same fixture files. A `<x>.rc` file is a failed call: 44 answers
# 404 (gh_rest rc 44), any other value answers 503 (gh_rest rc 75). A missing
# issue file answers 404. The POST body comes as `-F body=@<file>`; the stub
# writes it to posted.json as {body: ...}, the same file the old --input wrote.
cat > "$T/stubbin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GHS/log"
[ "${1:-}" = api ] && [ "${2:-}" = -i ] && [ "${3:-}" = -X ] || exit 1
m="$4"; path="$5"; shift 5
send() { printf 'HTTP/2.0 %s X\r\n\r\n' "$1"; [ -n "${2:-}" ] && cat "$2"; exit 0; }
fail() { if [ "$(cat "$1")" = 44 ]; then send 404; else send 503; fi; }
if [ "$m" = POST ]; then
  bf=""
  while [ $# -gt 0 ]; do case "$1" in body=@*) bf="${1#body=@}" ;; esac; shift; done
  [ -n "$bf" ] && jq -n --rawfile b "$bf" '{body: $b}' > "$GHS/posted.json"
  [ -f "$GHS/post.rc" ] && fail "$GHS/post.rc"
  if [ -f "$GHS/post-answer.json" ]; then send 201 "$GHS/post-answer.json"; fi
  echo '{"html_url":"https://github.com/example-org/cromford/issues/6025#issuecomment-900"}' > "$GHS/post-default.json"
  send 201 "$GHS/post-default.json"
fi
[ "$m" = GET ] || exit 1
case "$path" in
  repos/*/issues/*/comments*)
    p=$(sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p' <<<"$path")
    [ -f "$GHS/comments.rc" ] && fail "$GHS/comments.rc"
    if [ -f "$GHS/comments-$p.json" ]; then send 200 "$GHS/comments-$p.json"; fi
    echo '[]' > "$GHS/comments-empty.json"; send 200 "$GHS/comments-empty.json" ;;
  repos/*/issues/*)
    n="${path##*/}"
    [ -f "$GHS/issue-$n.rc" ] && fail "$GHS/issue-$n.rc"
    [ -f "$GHS/issue-$n.json" ] || send 404
    send 200 "$GHS/issue-$n.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/stubbin/gh"
cat > "$T/scr-stub.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GHS/scr.args"
json=""
while [ $# -gt 0 ]; do [ "$1" = --json ] && json="$2"; shift; done
if [ -f "$GHS/scr.rc" ]; then echo "INCOMPLETE: pulls page 1 read failed (rc 75)"; exit "$(cat "$GHS/scr.rc")"; fi
mkdir -p "$(dirname "$json")"
cat > "$json" <<'J'
{"slug":"example-org/cromford","window":{"days":14,"start":"2027-01-01T08:00:00Z","end":"2027-01-15T08:00:00Z"},
 "split":{"n":3,"median_h":20.5,"p75_h":30},"unsplit":{"n":7,"median_h":12,"p75_h":18},
 "children":{"n":6,"unmeasured":1,"lines_p50":400,"lines_p75":900,"lines_p90":1500,"files_p75":8,"files_p90":14,"over_budget_n":2},
 "sources":{"prs_read":50,"issues_read":80,"capped":false},"decision":"no change: n<5 (split n=3)"}
J
echo "split-chain example-org/cromford 14d: stub summary | decision: no change: n<5 (split n=3)"
exit 0
STUB
chmod +x "$T/scr-stub.sh"
export PATH="$T/stubbin:$PATH"
export SIZE_REMEASURE_SPLIT_CHAIN="$T/scr-stub.sh"

C9441=$((NOW - 20 * DAY)); C9437=$((NOW - 15 * DAY))
DUE=$((C9437 + 14 * DAY))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
issue() { # issue <dir> <n> <state> <reason> <closed epoch>
  if [ "$3" = open ]; then printf '{"number":%s,"state":"open","state_reason":null,"closed_at":null}\n' "$2" > "$1/issue-$2.json"
  else printf '{"number":%s,"state":"closed","state_reason":"%s","closed_at":"%s"}\n' "$2" "$4" "$(iso "$5")" > "$1/issue-$2.json"; fi
}
# newcase <name> -> sets H (scratch harness) and GHS (stub dir); both gates closed completed.
newcase() {
  H="$T/case-$1/h"; GHS="$T/case-$1/gh"
  mkdir -p "$H/builds" "$H/logs" "$H/flags" "$GHS"; : > "$GHS/log"
  export HARNESS="$H" GHS
  issue "$GHS" 9441 closed completed "$C9441"
  issue "$GHS" 9437 closed completed "$C9437"
}
posts() { grep -c -- '-X POST' "$GHS/log"; }
calls() { grep -c . "$GHS/log"; }
lanelog() { cat "$H/logs/size-remeasure.log" 2>/dev/null; }

# G1 — #9437 open
newcase g1; issue "$GHS" 9437 open
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1; RC=$?
eq "G1 rc" "$RC" 0
has "G1 not due" "$(lanelog)" "not due: #9437 open"
eq "G1 0 POST" "$(posts)" 0

# G2 — #9441 closed not_planned
newcase g2; issue "$GHS" 9441 closed not_planned "$C9441"
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
has "G2 not due" "$(lanelog)" "not due: #9441"
eq "G2 0 POST" "$(posts)" 0

# G3 — one second before due
newcase g3
SIZE_REMEASURE_NOW=$((DUE - 1)) "$SCR" >/dev/null 2>&1
has "G3 not due until" "$(lanelog)" "not due until $(iso "$DUE")"
eq "G3 0 POST" "$(posts)" 0
[ ! -e "$H/state/size-remeasure/posted" ] && ok || bad "G3 wrote posted"

# G4 — exactly due -> posts once
newcase g4; FIXNOW="$DUE" s1_fixture "$H/builds"
SIZE_REMEASURE_NOW="$DUE" "$SCR" >/dev/null 2>&1; RC=$?
eq "G4 rc" "$RC" 0
eq "G4 1 POST" "$(posts)" 1
has "G4 POST target" "$(grep -- '-X POST' "$GHS/log")" "repos/example-org/cromford/issues/6025/comments"
has "G4 posted marker" "$(cat "$H/state/size-remeasure/posted" 2>/dev/null)" "https://github.com/example-org/cromford/issues/6025#issuecomment-900"
has "G4 log posted" "$(lanelog)" "posted https://github.com/example-org/cromford/issues/6025#issuecomment-900"
BODY=$(jq -r '.body' "$GHS/posted.json" 2>/dev/null)
has "G4 body carries the marker" "$BODY" "<!-- harness-status: size-remeasure-bh-9502 -->"
has "G4 body carries the S1 counts" "$BODY" "| all repos | abandoned | 1 | 1 | 1 | 0 | 0 |"

# G6 — a second run makes 0 gh calls
: > "$GHS/log"
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
eq "G6 second run 0 gh calls" "$(calls)" 0
has "G6 done line" "$(lanelog)" "done: posted"

# G5 — an issue read rc 75 -> not judged, no alert
newcase g5; echo 75 > "$GHS/issue-9441.rc"
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
has "G5 not judged" "$(lanelog)" "not judged: #9441 read failed (rc 75)"
eq "G5 0 POST" "$(posts)" 0
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "G5 wrote an alert"
# A non-JSON answer is not judged either.
newcase g5b; echo 'not json' > "$GHS/issue-9437.json"
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
has "G5 non-JSON not judged" "$(lanelog)" "not judged: #9437"
eq "G5 non-JSON 0 POST" "$(posts)" 0

# A closed issue with an empty closed_at is not judged (GNU date -d "" is today).
newcase g5c; printf '{"number":9437,"state":"closed","state_reason":"completed","closed_at":""}\n' > "$GHS/issue-9437.json"
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
has "G5 empty closed_at not judged" "$(lanelog)" "not judged: #9437 has no closed_at"
eq "G5 empty closed_at 0 POST" "$(posts)" 0

# G7 — the thread already carries the marker
newcase g7
cat > "$GHS/comments-1.json" <<'J'
[{"id":1,"html_url":"https://github.com/example-org/cromford/issues/6025#issuecomment-1","body":"baseline"},
 {"id":2,"html_url":"https://github.com/example-org/cromford/issues/6025#issuecomment-2","body":"<!-- harness-status: size-remeasure-bh-9502 -->\nold post"}]
J
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
eq "G7 0 POST" "$(posts)" 0
has "G7 posted holds that URL" "$(cat "$H/state/size-remeasure/posted" 2>/dev/null)" "issuecomment-2"
# A thread read failure posts nothing.
newcase g7b; echo 75 > "$GHS/comments.rc"
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
eq "G7 thread read failed 0 POST" "$(posts)" 0
[ ! -e "$H/state/size-remeasure/posted" ] && ok || bad "G7b wrote posted"

# G8 — split chain INCOMPLETE twice -> 0 POST, exactly 1 alert line
newcase g8; echo 2 > "$GHS/scr.rc"
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
SIZE_REMEASURE_NOW=$((DUE + DAY + 3600)) "$SCR" >/dev/null 2>&1
eq "G8 0 POST" "$(posts)" 0
eq "G8 exactly 1 alert line" "$(grep -c 'size-remeasure: due since' "$H/logs/ALERTS.log" 2>/dev/null)" 1
has "G8 alert reason" "$(cat "$H/logs/ALERTS.log" 2>/dev/null)" "INCOMPLETE"
# A later post clears the alert dedup.
rm -f "$GHS/scr.rc"
SIZE_REMEASURE_NOW=$((DUE + 2 * DAY)) "$SCR" >/dev/null 2>&1
eq "G8 later post" "$(posts)" 1
[ ! -e "$H/state/size-remeasure/alerted" ] && ok || bad "G8 alerted not cleared by the post"

# G9 — POST rc 0 with no html_url -> no posted file
newcase g9; echo '{"message":"odd"}' > "$GHS/post-answer.json"
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
eq "G9 POST tried" "$(posts)" 1
[ ! -e "$H/state/size-remeasure/posted" ] && ok || bad "G9 wrote posted with no html_url"
eq "G9 alert" "$(grep -c 'size-remeasure: due since' "$H/logs/ALERTS.log" 2>/dev/null)" 1

# G10 — the split-chain argv
newcase g10
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1
has "G10 --days 14" "$(cat "$GHS/scr.args" 2>/dev/null)" "--days 14"
has "G10 --slug" "$(cat "$GHS/scr.args" 2>/dev/null)" "--slug example-org/cromford"

# ---------------------------------------------------------------------------
# D1 / C1 — the ticket's acceptance test: --dry-run over fixture RESULT files
# ---------------------------------------------------------------------------
newcase d1; s1_fixture "$H/builds"
OUT=$(SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" --dry-run 2>/dev/null); RC=$?
eq "D1 rc" "$RC" 0
has "D1 four bucket titles" "$OUT" "| under 600 | 600 to 1200 | 1200 to 3000 | over 3000 |"
has "D1 abandoned counts" "$OUT" "| all repos | abandoned | 1 | 1 | 1 | 0 | 0 |"
has "D1 closed counts" "$OUT" "| all repos | closed-unmerged | 1 | 0 | 0 | 1 | 0 |"
has "D1 gate verdict" "$OUT" "gate: due since $(iso "$DUE")"
eq "D1 0 POST" "$(posts)" 0
[ ! -e "$H/state/size-remeasure/posted" ] && ok || bad "D1 wrote posted"
[ ! -e "$H/state/size-remeasure/alerted" ] && ok || bad "D1 wrote alerted"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "D1 wrote an alert"
# C1 — the body
has "C1 marker" "$OUT" "<!-- harness-status: size-remeasure-bh-9502 -->"
has "C1 baseline heading" "$OUT" "### Baseline (2026-10-27 to 2026-11-10)"
has "C1 split heading" "$OUT" "### Split chain (bin/split-chain-report.sh --days 14)"
has "C1 bucket heading" "$OUT" "### ABANDONED and closed-unmerged PRs by product-line size, per repo"
has "C1 baseline 36" "$OUT" "36 PRs"
has "C1 baseline 20" "$OUT" "20 with a large-diff note"
has "C1 baseline 2,900" "$OUT" "2,900"
has "C1 decision" "$OUT" "decision: no change: n<5 (split n=3)"
has "C1 split row" "$OUT" "| split | 3 | 20.5 | 30 |"
has "C1 capped false" "$OUT" "Pages capped: false."
has "C1 no limit" "$OUT" "This comment changes no limit."
hasnt "C1 no em dash" "$OUT" "—"

# D2 — --dry-run with the gate closed still prints the tables
newcase d2; issue "$GHS" 9437 open; s1_fixture "$H/builds"
OUT=$(SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" --dry-run 2>/dev/null); RC=$?
eq "D2 rc" "$RC" 0
has "D2 verdict" "$OUT" "gate: not due: #9437 open"
has "D2 tables print" "$OUT" "| all repos | abandoned | 1 | 1 | 1 | 0 | 0 |"
eq "D2 0 POST" "$(posts)" 0

# ---------------------------------------------------------------------------
# C2 — the script writes no limit
# ---------------------------------------------------------------------------
CODE=$(grep -v '^[[:space:]]*#' "$SCR")
hasnt "C2 no settings write" "$CODE" "setting_set"
hasnt "C2 no settings-put" "$CODE" "settings-put"
hasnt "C2 no size-threshold call" "$CODE" "size-threshold.sh"
hasnt "C2 no size_ row" "$CODE" "size_max"

# ---------------------------------------------------------------------------
# L1 — the lane gate
# ---------------------------------------------------------------------------
newcase l1; touch "$H/flags/all-off"
SIZE_REMEASURE_NOW=$((DUE + DAY)) "$SCR" >/dev/null 2>&1; RC=$?
eq "L1 rc" "$RC" 0
eq "L1 0 gh calls" "$(calls)" 0
has "L1 SKIPPED" "$(cat "$H/logs/lane-gate.log" 2>/dev/null)" "size-remeasure SKIPPED"

echo "size-remeasure: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
