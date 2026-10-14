#!/bin/bash
# tests/conductor-held-rows-first.bh-2361-test.sh — BH-2361 (BH-2311.4): the
# conductor's "already held for (repo, number, state, head, kind)" check asks
# GET /api/conductor/held FIRST (whole-or-nothing, once per tick, cached in
# MC_TICK_DIR), then the local tick cache. Outage -> the local cache decides.
# Flag down -> no new GET, today's path.
#
# THE DEFECT (the REPRO, case H1). mc_hold_cached read ONLY the tick's local
# cache. A pager on a path that never loaded it (a rebuilt box, a subshell with
# no tick_begin) paged a row the worker already holds.
#
# WHAT IT DRIVES. held_pages_whole (W1-W4) and the real mc_stuck_check /
# mc_budget_check / mc_hold_tick_begin (H1-H7), through the real
# bin/jobs-client.sh with _jobs_req replaced by a stub that records every
# request and answers from $T/held.json. Assertions are on the lane-alert
# stub's calls, the request log, $MC_STUCK_DIR and $MC_LOG (D3).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/conductor-held-rows-first.bh-2361-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$DIR/bin/lib/jobs/conductor.sh" ] || exit 1   # impact: drives held_pages_whole
[ -f "$DIR/bin/lib/mc/log.sh" ] || exit 1           # impact: and mc_hold_cached through the pagers
[ -f "$DIR/bin/lib/merge-conductor-lib.sh" ] || exit 1   # impact: fx_mc_harness copies it; sourced below
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1

NOW=$(date -u '+%s')
S=$((NOW-5400))

export HARNESS="$T/h"
fx_mc_harness "$DIR" "$T" || exit 1
mkdir -p "$T/h/bin/lib/jobs" "$T/h/env" "$T/h/state" "$T/h/flags" || exit 1
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
echo 'HARNESS_SECRET=test-secret' > "$T/h/env/global.env"
export HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 JOBS_ALERT=0

CALLS="$T/lane-alert.calls"
cat > "$T/h/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$T/h/bin/lane-alert.sh"

# shellcheck source=/dev/null
. "$T/h/bin/jobs-client.sh" || exit 1
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
mc_now() { echo "$NOW"; }

# THE STUB CLIENT. HELD_RC=1|2 answers the held GET with that rc; otherwise it
# prints $T/held.json. Every request is one "METHOD PATH" line in $REQ.
REQ="$T/req.log"
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$REQ"
  case "$1 $2" in
    "GET /api/conductor/held"*)
      case "${HELD_RC:-0}" in 0) cat "$T/held.json"; return 0 ;; *) return "$HELD_RC" ;; esac ;;
    "PUT /api/conductor/held") return 0 ;;
    "POST /api/conductor/held/release") printf '{"released":1}'; return 0 ;;
    *) return 2 ;;
  esac
}

HEAD=aaaaaaaa1111bbbb
U7=https://github.com/example-org/a/pull/7
flag_up()   { touch "$T/h/flags/pr-state-rows"; _PR_ROWS_ON=""; _PR_ROWS_DOWN=0; }
flag_down() { rm -f "$T/h/flags/pr-state-rows"; _PR_ROWS_ON=""; _PR_ROWS_DOWN=0; }
reset_io()  { : > "$REQ"; : > "$CALLS"; unset HELD_RC; }
nreq()      { grep -c "$1" "$REQ" 2>/dev/null || true; }
ncalls()    { wc -l < "$CALLS" | tr -d ' '; }
nstuck()    { find "$MC_STUCK_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }
# BH-2358 made a stuck page a ledger line as well as a marker, so a clean slate
# wipes both: a wiped dir alone no longer re-pages the triple.
fresh_stuck() {
  scratch_rm "$MC_STUCK_DIR"; mkdir -p "$MC_STUCK_DIR"
  [ -f "$MC_ATTEMPTS" ] || return 0
  grep -v '^stuck ' "$MC_ATTEMPTS" > "$T/attempts.tmp"; mv -f "$T/attempts.tmp" "$MC_ATTEMPTS"
}
new_tick()  { export MC_TICK_ID="$1"; rm -f "$MC_TICK_DIR/$1".* 2>/dev/null; mkdir -p "$MC_TICK_DIR"; }
hrow() { # hrow <repo> <num> <state> <head> <kind>
  jq -nc --arg r "$1" --arg n "$2" --arg s "$3" --arg h "$4" --arg k "$5" \
    '{repo:$r,number:($n|tonumber),state:$s,head:$h,kind:$k,text:"t",mark:"m",mode:"kill-switch",
      first_held_at:"2026-09-26T00:00:00Z",last_seen_at:"2026-09-26T00:00:00Z"}'
}
set_held()  { jq -sc '{rows:.,n_total:(.|length)}' > "$T/held.json"; }
nunread()   { grep -c 'held rows unreadable' "$MC_LOG" 2>/dev/null || true; }
stuck7()    { mc_stuck_check "example-org/a#7" WAIT_CI "$S" "$HEAD" "$U7" "-" "checks pending"; }
# the local tick cache row (the shape mc_hold_page appends)
local_cache() { printf 'example-org/a\t7\tWAIT_CI\t%s\t%s\tt\tm\tkill-switch\t-\t-\n' "$HEAD" "$1" >> "$(mc_hold_cache_file)"; }

mc_init

echo "== W: held_pages_whole is whole-or-nothing =="
reset_io
{ hrow example-org/a 7 WAIT_CI "$HEAD" STUCK; hrow example-org/b 8 READY "$HEAD" BUDGET; } | set_held
OUT=$(held_pages_whole 500); RC=$?
[ "$RC" = 0 ] && ok || bad "W1 whole read rc=$RC, wanted 0"
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] && ok || bad "W1 wanted 2 lines: $OUT"
[ "$(head -1 <<<"$OUT" | awk -F'\t' '{print NF}')" = 10 ] && ok || bad "W1 wanted 10 columns: $OUT"
[ "$(head -1 <<<"$OUT" | cut -f1-5 | tr '\t' ' ')" = "example-org/a 7 WAIT_CI $HEAD STUCK" ] && ok || bad "W1 first row: $OUT"
grep -q '^GET /api/conductor/held?limit=500$' "$REQ" && ok || bad "W1 request: $(cat "$REQ")"
printf '%s' '{"rows":[],"n_total":0}' > "$T/held.json"
OUT=$(held_pages_whole 500); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "W1b nothing held: rc=$RC out='$OUT', wanted rc 0 and no output"
hrow example-org/a 7 WAIT_CI "$HEAD" STUCK | jq -sc '{rows:.,n_total:600}' > "$T/held.json"
OUT=$(held_pages_whole 500); RC=$?
[ "$RC" = 3 ] && ok || bad "W2 truncated list rc=$RC, wanted 3"
[ -z "$OUT" ] && ok || bad "W2 a truncated list printed rows: $OUT"
printf '<html>oops</html>' > "$T/held.json"
held_pages_whole 500 >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "W3 garbage 200 rc=$RC, wanted 1"
hrow example-org/a 7 WAIT_CI "$HEAD" STUCK | jq -sc '{rows:.}' > "$T/held.json"
held_pages_whole 500 >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "W3b no n_total rc=$RC, wanted 1"
HELD_RC=1 held_pages_whole 500 >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "W4 outage rc=$RC, wanted 1"
HELD_RC=2 held_pages_whole 500 >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "W4b 404 rc=$RC, wanted 2"

export MC_MODE=merge

echo "== H1: the worker holds the STUCK row, local mark wiped -> not paged =="
flag_up; reset_io; new_tick h1; fresh_stuck
hrow example-org/a 7 WAIT_CI "$HEAD" STUCK | set_held
stuck7; RC=$?
[ "$RC" = 1 ] && ok || bad "H1 mc_stuck_check rc=$RC, wanted 1"
[ "$(ncalls)" = 0 ] && ok || bad "H1 paged $(ncalls) times for a row the worker holds: $(cat "$CALLS")"
[ "$(nstuck)" = 0 ] && ok || bad "H1 a STUCK marker was written for a held row"
[ "$(nreq '^GET /api/conductor/held')" = 1 ] && ok || bad "H1 wanted 1 held GET, got $(nreq '^GET /api/conductor/held')"

echo "== H2: the worker holds the BUDGET row -> not paged, not re-held =="
flag_up; reset_io; new_tick h2
printf 'example-org/a#7\tWAIT_CI\t%s\t%s\t%s\t-\t-\t%s\n' "$S" "$HEAD" "$HEAD" "$U7" > "$MC_ROWS"
hrow example-org/a 7 WAIT_CI "$HEAD" BUDGET | set_held
mc_budget_check "example-org/a#7" WAIT_CI "$S" "$U7" "checks pending"
[ "$(ncalls)" = 0 ] && ok || bad "H2 paged $(ncalls) times for a held BUDGET row: $(cat "$CALLS")"
[ "$(nreq '^PUT /api/conductor/held')" = 0 ] && ok || bad "H2 the held row was PUT again"
[ "$(cut -f6 "$MC_ROWS")" = - ] && ok || bad "H2 alerted was spent by a page never sent: $(cat "$MC_ROWS")"
MC_MODE=kill-switch mc_budget_check "example-org/a#7" WAIT_CI "$S" "$U7" "checks pending"
[ "$(nreq '^PUT /api/conductor/held')" = 0 ] && ok || bad "H2b kill-switch re-PUT a row the worker already holds"

echo "== H3: held read outage -> the local cache decides =="
flag_up; reset_io; new_tick h3; fresh_stuck
local_cache STUCK
HELD_RC=1; stuck7
[ "$(ncalls)" = 0 ] && ok || bad "H3a outage + local cache row: paged $(ncalls) times, wanted 0"
reset_io; new_tick h3b; fresh_stuck; U0=$(nunread)
HELD_RC=1; stuck7; fresh_stuck; stuck7
[ "$(ncalls)" = 2 ] && ok || bad "H3b outage, no local cache: $(ncalls) pages over two checks, wanted 2 (today's behaviour)"
[ "$(( $(nunread) - U0 ))" = 1 ] && ok || bad "H3b wanted exactly one 'held rows unreadable' line, got $(( $(nunread) - U0 ))"
[ "$(nreq '^GET /api/conductor/held')" = 1 ] && ok || bad "H3b the outage was not latched: $(nreq '^GET /api/conductor/held') GETs"

echo "== H4: a truncated list (n_total > rows) is an outage, never a partial answer =="
flag_up; reset_io; new_tick h4; fresh_stuck
hrow example-org/a 7 WAIT_CI "$HEAD" STUCK | jq -sc '{rows:.,n_total:600}' > "$T/held.json"
stuck7
[ "$(ncalls)" = 1 ] && ok || bad "H4 a truncated list suppressed the page ($(ncalls) pages, wanted 1)"
grep -q 'held rows unreadable (rc=3)' "$MC_LOG" && ok || bad "H4 no rc=3 log line"
reset_io; new_tick h4b; fresh_stuck; local_cache STUCK
stuck7
[ "$(ncalls)" = 0 ] && ok || bad "H4b truncated + local cache row: paged $(ncalls) times, wanted 0"

echo "== H5: once per tick =="
flag_up; reset_io; new_tick h5
hrow example-org/z 1 READY "$HEAD" STUCK | set_held
mc_hold_cached "example-org/a#7" WAIT_CI "$HEAD" STUCK; mc_hold_cached "example-org/a#7" WAIT_CI "$HEAD" BUDGET
[ "$(nreq '^GET /api/conductor/held')" = 1 ] && ok || bad "H5a two checks made $(nreq '^GET /api/conductor/held') GETs, wanted 1"
reset_io; new_tick h5b; fresh_stuck
hrow example-org/a 7 WAIT_CI "$HEAD" STUCK | set_held
mc_hold_tick_begin --load-only
G0=$(nreq '^GET /api/conductor/held')
[ -f "$MC_TICK_DIR/h5b.held-rows.tsv" ] && ok || bad "H5b tick_begin did not load the rows file"
( stuck7 )   # a pr_worker subshell
[ "$(nreq '^GET /api/conductor/held')" = "$G0" ] && ok || bad "H5b the pager made a new GET after tick_begin"
[ "$(ncalls)" = 0 ] && ok || bad "H5b the subshell pager paged a held row"

echo "== H6: flag down -> no held GET from the pagers, today's page =="
flag_down; reset_io; new_tick h6; fresh_stuck
hrow example-org/a 7 WAIT_CI "$HEAD" STUCK | set_held
stuck7
[ "$(nreq '^GET /api/conductor/held')" = 0 ] && ok || bad "H6 flag down made $(nreq '^GET /api/conductor/held') held GETs"
[ "$(ncalls)" = 1 ] && ok || bad "H6 flag down: $(ncalls) pages, wanted 1 (today's path)"
reset_io; new_tick h6b
mc_hold_tick_begin --load-only
[ "$(nreq '^GET /api/conductor/held')" = 1 ] && ok || bad "H6b flag down tick_begin made $(nreq '^GET /api/conductor/held') GETs, wanted 1 (the list it always read)"
[ -e "$MC_TICK_DIR/h6b.held-rows.tsv" ] && bad "H6b flag down wrote a rows file" || ok

echo "== H7: only the exact row suppresses =="
flag_up
h7() { # h7 <label> <want-pages> <held repo> <num> <state> <head> <kind>
  reset_io; new_tick "h7-$1"; fresh_stuck
  hrow "$3" "$4" "$5" "$6" "$7" | set_held
  stuck7
  [ "$(ncalls)" = "$2" ] && ok || bad "H7 $1: $(ncalls) pages, wanted $2"
}
h7 state 1 example-org/a 7 WAIT_REVIEW "$HEAD" STUCK
h7 head  1 example-org/a 7 WAIT_CI     "${HEAD%?}c" STUCK
h7 kind  1 example-org/a 7 WAIT_CI     "$HEAD" BUDGET
h7 num   1 example-org/a 70 WAIT_CI    "$HEAD" STUCK
h7 repo  1 example-org/ab 7 WAIT_CI    "$HEAD" STUCK
h7 case  0 example-org/A 7 WAIT_CI     "$HEAD" STUCK

echo "conductor-held-rows-first.bh-2361: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
