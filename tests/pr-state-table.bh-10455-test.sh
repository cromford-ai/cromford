#!/bin/bash
# tests/pr-state-table.bh-10455-test.sh — BH-10455 (BH-9555.5): a PR's
# open/closed/merged state is read from a fresh pr_records row first, and
# GitHub is read only on a miss or a row older than PR_RECORD_MAX_AGE_S.
#
#   L1-L6   prrd_pr_state_var / prrd_fresh_state (bin/lib/pr-record-readers.sh)
#   D1-D12  the serve decision table, one row each
#   K1-K2   the kill row PR_RECORD_READERS (lib.pr-record.pr_record_readers)
#   G1-G3   the REAL bin/triage-gate.sh queue-pending PR-state vector
#   S1-S4   _ts_fetch_refs through the _ts_pr_record_ref seam
#
# Doubles, all in this file: _jobs_req over a row store in $T/rows (one file
# per <lower-repo>#<n>, the jobs answer {"row":...,"age_s":N}), a counting
# gh_rest_pr_state_var / gh_rest double, and a counting `gh` fake on PATH for
# the real gate. No call leaves the box. Each case owns its repo slug.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-state-table.bh-10455-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset HARNESS H HARNESS_CHECKOUT PR_RECORD_READERS PR_RECORD_MAX_AGE_S
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2], want [$3]"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the whole suite (bin/test-determinism-lint.sh).
NOW=$(date +%s)

ROWS="$T/rows"; LH="$T/h"
mkdir -p "$ROWS" "$LH/logs"
export PRRD_ROWS="$ROWS" PRRD_JOBS_LOG="$T/jobs.log" PRRD_GH_LOG="$T/gh.log"

# put_row <repo> <n> <state-json> <age-json> — the jobs answer for one PR.
# <state-json> and <age-json> are raw JSON ("\"open\"", null, 900, -5 ...);
# the age "absent" leaves age_s out of the answer.
put_row() {
  local lr; lr=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  if [ "$4" = absent ]; then
    jq -nc --arg r "$lr" --argjson n "$2" --argjson s "$3" '{row:{repo:$r, number:$n, state:$s}}'
  else
    jq -nc --arg r "$lr" --argjson n "$2" --argjson s "$3" --argjson a "$4" '{row:{repo:$r, number:$n, state:$s}, age_s:$a}'
  fi > "$ROWS/${lr//\//_}#$2"
}

# The jobs client double: GET /api/pr-records?repo=<r>&number=<n>.
JOBS_DOUBLE='_jobs_req() {
  printf "%s %s\n" "$1" "$2" >> "$PRRD_JOBS_LOG"
  [ -e "$PRRD_ROWS/FAIL" ] && return 1
  local q="${2#*\?}" r n
  r=$(sed -E "s/.*repo=([^&]*).*/\1/" <<<"$q"); n=$(sed -E "s/.*number=([0-9]+).*/\1/" <<<"$q")
  if [ -f "$PRRD_ROWS/${r//\//_}#$n" ]; then cat "$PRRD_ROWS/${r//\//_}#$n"; else echo "{\"row\":null}"; fi
}'

# rd <repo> <n> [env assignments...] — run prrd_pr_state_var in a subshell
# with the doubles; prints "<rc> <word> gh=<calls> jobs=<GETs>". The GitHub
# double answers $GHST (default open) with rc $GHRC (default 0).
rd() {
  local repo="$1" n="$2"; shift 2
  : > "$PRRD_GH_LOG"; : > "$PRRD_JOBS_LOG"
  local out
  out=$(env "$@" HARNESS="$LH" bash -c '
    . "$1/bin/lib/pr-record-readers.sh" || exit 98
    eval "$2"
    gh_rest_pr_state_var() { echo "pr_state $2 $3" >> "$PRRD_GH_LOG"; printf -v "$1" "%s" "${GHST-open}"; return "${GHRC:-0}"; }
    V=""; prrd_pr_state_var V "$3" "$4"; printf "%s %s" "$?" "$V"
  ' _ "$DIR" "$JOBS_DOUBLE" "$repo" "$n")
  printf '%s gh=%s jobs=%s' "$out" "$(grep -c . "$PRRD_GH_LOG")" "$(grep -c . "$PRRD_JOBS_LOG")"
}

# fs <repo> <n> [env...] — prrd_fresh_state alone: "<rc> [<stdout>]"
fs() {
  local repo="$1" n="$2"; shift 2
  : > "$PRRD_JOBS_LOG"
  env "$@" HARNESS="$LH" bash -c '
    . "$1/bin/lib/pr-record-readers.sh" || exit 98
    eval "$2"
    o=$(prrd_fresh_state "$3" "$4"); printf "%s [%s]" "$?" "$o"
  ' _ "$DIR" "$JOBS_DOUBLE" "$repo" "$n"
}

# ── L: the reader ───────────────────────────────────────────────────────────
put_row o/bh10455-l1 7 '"open"' 0
check "L1 fresh open row: served, 0 GitHub calls" "$(rd o/bh10455-l1 7)" "0 open gh=0 jobs=1"
put_row o/bh10455-l2 7 '"open"' 901
check "L2 row age = max+1: exactly 1 GitHub call" "$(rd o/bh10455-l2 7 GHST=merged)" "0 merged gh=1 jobs=1"
check "L3 no row: exactly 1 GitHub call" "$(rd o/bh10455-l3 7 GHST=closed)" "0 closed gh=1 jobs=1"
put_row o/bh10455-l4 7 '"open"' 0
touch "$ROWS/FAIL"
check "L4 jobs read fails: 1 GitHub call, the double's rc" "$(rd o/bh10455-l4 7 GHST=merged)" "0 merged gh=1 jobs=1"
check "L5 GitHub fails after a miss: its rc, 1 call (never 2)" "$(rd o/bh10455-l4 7 GHST= GHRC=75)" "75  gh=1 jobs=1"
rm -f "$ROWS/FAIL"
check "L6 prrd_fresh_state prints nothing on a miss" "$(fs o/bh10455-l3 7)" "1 []"

# ── D: the decision table (Failure modes in the plan) ───────────────────────
put_row o/bh10455-d1 7 '"open"' 0;     check "D1 open age 0"        "$(rd o/bh10455-d1 7 GHST=x)" "0 open gh=0 jobs=1"
put_row o/bh10455-d2 7 '"merged"' 900; check "D2 merged age = max"  "$(rd o/bh10455-d2 7 GHST=x)" "0 merged gh=0 jobs=1"
put_row o/bh10455-d3 7 '"closed"' 10;  check "D3 closed age 10"     "$(rd o/bh10455-d3 7 GHST=x)" "0 closed gh=0 jobs=1"
put_row o/bh10455-d4 7 '"open"' 901;   check "D4 age max+1"         "$(rd o/bh10455-d4 7 GHST=open)" "0 open gh=1 jobs=1"
put_row o/bh10455-d5 7 '"open"' -5;    check "D5 age -5 (clock skew)" "$(rd o/bh10455-d5 7 GHST=open)" "0 open gh=1 jobs=1"
put_row o/bh10455-d6 7 '"open"' absent; check "D6 age_s missing"    "$(rd o/bh10455-d6 7 GHST=open)" "0 open gh=1 jobs=1"
put_row o/bh10455-d6b 7 '"open"' '"12"'; check "D6b age_s a string" "$(rd o/bh10455-d6b 7 GHST=open)" "0 open gh=1 jobs=1"
put_row o/bh10455-d6c 7 '"open"' 1.5;  check "D6c age_s not an integer" "$(rd o/bh10455-d6c 7 GHST=open)" "0 open gh=1 jobs=1"
put_row o/bh10455-d7 7 null 0;         check "D7 state null"        "$(rd o/bh10455-d7 7 GHST=open)" "0 open gh=1 jobs=1"
put_row o/bh10455-d8 7 '"OPEN"' 0;     check "D8 state upper-case"  "$(rd o/bh10455-d8 7 GHST=open)" "0 open gh=1 jobs=1"
put_row o/bh10455-d8b 7 '"draft"' 0;   check "D8b state draft"      "$(rd o/bh10455-d8b 7 GHST=open)" "0 open gh=1 jobs=1"
check "D9 no row (an issue number)" "$(rd o/bh10455-d9 7 GHST=closed)" "0 closed gh=1 jobs=1"
put_row o/bh10455-d10 7 '"open"' 0; touch "$ROWS/FAIL"
check "D10 jobs read fails" "$(rd o/bh10455-d10 7 GHST=open)" "0 open gh=1 jobs=1"
rm -f "$ROWS/FAIL"
put_row o/bh10455-d11 7 '"merged"' 0
check "D11 knob 0: no jobs GET at all" "$(rd o/bh10455-d11 7 PR_RECORD_READERS=0 GHST=open)" "0 open gh=1 jobs=0"
put_row o/bh10455-d12 7 '"merged"' 0
check "D12 PR_RECORD_MAX_AGE_S=0" "$(rd o/bh10455-d12 7 PR_RECORD_MAX_AGE_S=0 GHST=open)" "0 open gh=1 jobs=1"
put_row o/bh10455-mixed 7 '"closed"' 3
check "D13 mixed-case slug finds the lower-case row" "$(rd O/BH10455-Mixed 7 GHST=open)" "0 closed gh=0 jobs=1"
put_row o/bh10455-d14 7 '"open"' 60
check "D14 PR_RECORD_MAX_AGE_S=30 makes age 60 stale" "$(rd o/bh10455-d14 7 PR_RECORD_MAX_AGE_S=30 GHST=merged)" "0 merged gh=1 jobs=1"

# ── K: the kill row ─────────────────────────────────────────────────────────
put_row o/bh10455-k 7 '"merged"' 0
check "K1 knob unset: served"            "$(rd o/bh10455-k 7 GHST=open)" "0 merged gh=0 jobs=1"
check "K1b knob 1: served"               "$(rd o/bh10455-k 7 PR_RECORD_READERS=1 GHST=open)" "0 merged gh=0 jobs=1"
check "K2 knob 0: GitHub, 0 jobs GETs"   "$(rd o/bh10455-k 7 PR_RECORD_READERS=0 GHST=open)" "0 open gh=1 jobs=0"
K3=$(jq -r '[.env, .read_in, .default, .min, .max] | map(tostring) | join(" ")' \
  "$DIR/catalog/lanes.d/_lib.pr-record.knobs.d/PR_RECORD_READERS.json" 2>/dev/null)
check "K3 the knob fragment" "$K3" "PR_RECORD_READERS bin/lib/pr-record-readers.sh 1 0 1"

# ── G: the REAL bin/triage-gate.sh ──────────────────────────────────────────
G="$T/g"; P=cromford; GSLUG=o/bh10455-g
mkdir -p "$G/bin/lib" "$G/logs" "$G/state" "$G/plans" "$G/flags" "$G/env" \
         "$G/builds" "$G/locks" "$G/prompts" "$T/fakebin" "$T/ctl"
# The jobs client double goes in FIRST: the closure install skips a file that exists.
printf '%s\n' "$JOBS_DOUBLE" > "$G/bin/jobs-client.sh"
scratch_install_closure bin/triage-gate.sh "$G" >/dev/null || bad "setup: cannot install the gate closure"
[ -r "$G/bin/lib/pr-record-readers.sh" ] || bad "setup: the gate closure has no bin/lib/pr-record-readers.sh"
for f in fleet-conf.sh project-of.sh; do cp "$DIR/bin/$f" "$G/bin/"; done
export FLEET_CONF="$G/fleet.conf"
printf 'cromford %s - - 3 small 1.1.1.1\n' "$GSLUG" > "$FLEET_CONF"
echo 'setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> > x' > "$G/prompts/$P.md"
export GH_CTL="$T/ctl" GH_ARGV="$T/gh-argv"
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_ARGV"
[ "${1:-}" = api ] || exit 1
shift; inc=0; path=""
while [ $# -gt 0 ]; do
  case "$1" in -i) inc=1; shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) path="$1"; break ;; esac
done
key=other
case "$path" in
  repos/*/pulls/[0-9]*) key="pull-${path##*/}" ;;
  repos/*/pulls*) key=pulls ;;
  repos/*/issues*) key=issues ;;
esac
body=""; [ -f "$GH_CTL/$key.body" ] && body=$(cat "$GH_CTL/$key.body")
[ "$inc" = 1 ] && printf 'HTTP/2.0 200\r\ncontent-type: application/json\r\n\r\n'
[ -n "$body" ] && printf '%s\n' "$body"
exit 0
GH
chmod +x "$T/fakebin/gh"
printf '%s' '[{"number":7,"state":"open","title":"t","body":"b","comments":1,"updated_at":"2026-09-19T10:00:00Z","labels":[]}]' > "$T/ctl/issues.body"
printf '%s' '[]' > "$T/ctl/pulls.body"
printf '%s' '{"number":11,"state":"open","merged_at":null}' > "$T/ctl/pull-11.body"
printf '%s' '{"number":12,"state":"closed","merged_at":"2026-11-01T00:00:00Z"}' > "$T/ctl/pull-12.body"

gate() { OUT=$(HARNESS="$G" PATH="$T/fakebin:$PATH" env "$@" "$G/bin/triage-gate.sh" "$P" 2>/dev/null); }
age_back() { # the queuefp stamp 3000 s back: inside the PR-gate window, past the 45 m brake
  local f="$G/state/$P.queuefp"
  awk -v s="$((NOW - 3000))" 'NR==2{print s; next}{print}' "$f" > "$f.n" && mv -f "$f.n" "$f"
}
# g_run [env...] — tick 1 (stores the queue fp), then tick 2 in the PR-gate
# window (stores the vector). Sets PRCALLS (pulls/<n> GETs on tick 2) and L3.
g_run() {
  local x
  for x in "$G/state/$P".*; do [ -e "$x" ] && { scratch_rm "$x" || return 1; }; done
  printf '%s\n' "$NOW" > "$G/state/$P.gate-meta"
  printf 'BH-5 5 — waiting on PR #11 project=cromford\nBH-6 6 — waiting on PR #12 project=cromford\n' > "$G/logs/READY-QUEUE.log"
  gate "$@"; G_O1=$OUT
  age_back
  : > "$GH_ARGV"; : > "$PRRD_JOBS_LOG"
  gate "$@"; G_O2=$OUT
  PRCALLS=$(grep -cE 'repos/[^ ]*/pulls/[0-9]+' "$GH_ARGV")
  PR12CALLS=$(grep -cE 'repos/[^ ]*/pulls/12' "$GH_ARGV")
  L3=$(sed -n 3p "$G/state/$P.queuefp" 2>/dev/null)
}

# G1 — fresh rows open + merged: 0 PR-state calls, the same upper-case vector.
put_row "$GSLUG" 11 '"open"' 0
put_row "$GSLUG" 12 '"merged"' 0
g_run
check "G1 tick 1 answer" "$G_O1" "RUN queue-pending"
check "G1 tick 2 answer" "$G_O2" "RUN queue-pending"
check "G1 PR-state GitHub calls" "$PRCALLS" 0
check "G1 jobs GETs" "$(grep -c 'pr-records' "$PRRD_JOBS_LOG")" 2
check "G1 queuefp line 3" "$L3" "11=OPEN;12=MERGED;"
G1L3=$L3
age_back; : > "$GH_ARGV"
gate
case "$OUT" in "SKIP queue-gates-unchanged"*) ok ;; *) bad "G1 tick 3 must SKIP queue-gates-unchanged, got [$OUT]" ;; esac
check "G1 tick 3 PR-state GitHub calls" "$(grep -cE 'repos/[^ ]*/pulls/[0-9]+' "$GH_ARGV")" 0

# G2 — the same states through GitHub (kill row 0): a byte-identical line 3.
g_run PR_RECORD_READERS=0
check "G2 PR-state GitHub calls with the knob at 0" "$PRCALLS" 2
check "G2 jobs GETs with the knob at 0" "$(grep -c 'pr-records' "$PRRD_JOBS_LOG")" 0
check "G2 line 3 the same as the record path" "$L3" "$G1L3"

# G3 — one row aged past PR_RECORD_MAX_AGE_S: exactly 1 PR-state call.
put_row "$GSLUG" 12 '"merged"' 901
g_run
check "G3 PR-state GitHub calls" "$PRCALLS" 1
check "G3 the call is for the stale PR" "$PR12CALLS" 1
check "G3 queuefp line 3" "$L3" "11=OPEN;12=MERGED;"

# ── S: _ts_fetch_refs through the seam ──────────────────────────────────────
# ts_fetch <case> <ref> [env...] — "<gh calls> <refs.json> nf=<n>"; the gh_rest
# double answers an issue body with state $GHBODY_ST (default open).
ts_fetch() {
  local c="$1" ref="$2"; shift 2
  local d="$T/s-$c"
  mkdir -p "$d"; echo '{}' > "$d/refs.json"; printf '%s\n' "$ref" > "$d/n"; : > "$d/gh.calls"
  env "$@" HARNESS="$LH" bash -c '
    d="$1"; refs="$d/refs.json"; max=30; slug="$3"; nf=0; fetched=0
    . "$2/bin/lib/triage-state.sh" 2>/dev/null
    eval "$4"
    gh_rest() { echo "$*" >> "$d/gh.calls"; printf "{\"state\":\"%s\"}\n" "${GHBODY_ST:-open}"; return 0; }
    _ts_fetch_refs "$d/n"
    printf "%s %s nf=%s" "$(grep -c . "$d/gh.calls")" "$(jq -c -S . "$refs")" "$nf"
  ' _ "$d" "$DIR" "o/bh10455-$c" "$JOBS_DOUBLE"
}
put_row o/bh10455-s1 21 '"closed"' 0
check "S1 fresh closed row: 0 gh_rest calls, CLOSED" "$(ts_fetch s1 21)" '0 {"21":"CLOSED"} nf=0'
put_row o/bh10455-s2 21 '"merged"' 5
check "S2 fresh merged row: MERGED" "$(ts_fetch s2 21)" '0 {"21":"MERGED"} nf=0'
put_row o/bh10455-s3 21 '"merged"' 901
check "S3 stale row: 1 issues read, nf +1" "$(ts_fetch s3 21 GHBODY_ST=closed)" '1 {"21":"CLOSED"} nf=1'
check "S3 the read is issues/21" "$(cat "$T/s-s3/gh.calls")" "GET repos/o/bh10455-s3/issues/21"
check "S4 no row (an issue): today's issues read" "$(ts_fetch s4 21 GHBODY_ST=open)" '1 {"21":"OPEN"} nf=1'
put_row o/bh10455-s5 21 '"merged"' 0
check "S5 knob 0: today's issues read" "$(ts_fetch s5 21 PR_RECORD_READERS=0 GHBODY_ST=open)" '1 {"21":"OPEN"} nf=1'

echo "pr-state-table.bh-10455: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
