#!/bin/bash
# tests/prequeue-main-runs.bh-8152-test.sh — BH-8152: the pre-queue gate finds
# its run by the main sha and never pays twice for one run title. The merge
# conductor read only the 30 newest prequeue-gate.yml runs, so a run past them
# was dispatched again (8 duplicate titles in 24 h) and a pending run past them
# was not read until MC_PREQUEUE_DEADLINE_S. bin/lib/mc-prequeue.d/main-runs.sh
# reads the runs of one main (`head_sha=<main>`), once per tick and main, and
# pq_find_run (adopt), pq_read_run (settle) and pq_dispatch (the spend) ask it.
#
#   M1  5 asks for one (pr, head, main A) from 5 fresh state dirs, 40 other
#       runs between each ask: 1 dispatch; main B: 1 more (2). This is 5
#       asks for ONE READY PR, not 5 READY PRs (plan A1); M14 pins the 5-PR case
#   M2  5 READY PRs settle pending entries on main A in one tick: 1 head_sha=A
#       read
#   M3  adopt: the title is the 45th newest run, on head_sha=A: adopted, no
#       dispatch
#   M4  settle: a pending run completed green, past the 30 newest: proceed
#       with green in this tick
#   M5  no cache entry, a completed green run past the 30 newest: no dispatch,
#       green read
#   M6  the dedup branch (adopt off): rc 3, `pending <created> <id>`, one
#       `PREQUEUE dedup ... -> no-dispatch` line, 0 dispatches; the run then
#       completes green and the next pq_gate reads green
#   M7  matcher: newest of two wins; one hex char off; empty list; no
#       workflow_runs (rc 75)
#   M8  MC_PREQUEUE_MAIN_RUNS=0: no head_sha read, 1 dispatch on a miss;
#       MC_PREQUEUE_MAIN_RUNS_PAGE=500 asks per_page=100
#   M9  near misses (pr=42, head H', main B, title + suffix): 1 dispatch
#   M10 a named-suites dispatch is never deduped: 1 dispatch
#   M11 a dedup hit on a failed run: could-not-run, 1 alert; next tick 0 more
#   M12 an unwritable cache: rc 4, 0 dispatches, no dedup line; a failed
#       index read: 1 dispatch and one `read-failed, dispatched` line
#   M13 a tree without main-runs.sh settles and dispatches as before
#   M14 5 READY PRs (5 distinct heads) on one main, no run yet: 5 dispatches,
#       one per head (plan A1: the gate checks each head merged with main;
#       one run for a group of heads is a product decision, not this build),
#       then 5 more asks from fresh state dirs: 0 more dispatches
#
# Driven through pq_gate (bin/lib/mc-prequeue.sh) with every real hook in
# bin/lib/mc-prequeue.d/ sourced. GitHub is a stub over one JSON run list per
# case: no network call. Each case has its own dir under $T.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-main-runs.bh-8152-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc-prequeue.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.d/adopt.sh" ] || exit 1   # impact: bin/lib/mc-prequeue.d/main-runs.sh bin/lib/mc-prequeue.d/adopt.sh bin/lib/mc-prequeue.d/dispatch.sh bin/lib/mc-prequeue.sh

[ -f "$DIR/bin/lib/mc-prequeue.d/main-runs.sh" ] && ok || bad "setup: bin/lib/mc-prequeue.d/main-runs.sh is missing"
SLUG=example-org/demo
NOW=$(date +%s)
hx() { printf '%s%038d' "$1" "${2:-0}"; }
H=$(hx aa); H2=$(hx ab); A=$(hx ca); B=$(hx cb); Z=$(hx cf)
TTL() { printf 'prequeue pr=%s head=%s main=%s' "$1" "$2" "$3"; }

# load <case> — the real libs and the shared stubs, in the caller's subshell.
# $C/runs.json is the workflow's run list (newest last); gh_rest serves it the
# way GitHub does and logs every path in $C/reads; `gh workflow run` appends
# to $C/dispatch and adds an in_progress run on head_sha=<main>.
load() {
  C="$T/$1"; PASS=0; FAIL=0; mkdir -p "$C/tmp" "$C/hh/bin" "$C/hh/locks"
  [ -s "$C/runs.json" ] || echo '[]' > "$C/runs.json"
  [ -e "$C/seq" ] || echo 0 > "$C/seq"
  : >> "$C/reads"; : >> "$C/dispatch"; : >> "$C/log"; : >> "$C/alerts"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$C" > "$C/hh/bin/lane-alert.sh"; chmod +x "$C/hh/bin/lane-alert.sh"
  MC_H="$C/hh" HARNESS="$C/hh" TMPDIR="$C/tmp"
  . "$DIR/bin/lib/mc/queue.sh"; . "$DIR/bin/lib/mc-prequeue.sh"
  ws 1
  mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
  mc_log() { printf '%s\n' "$*" >> "$C/log"; }
  mc_use_token() { :; }
  pq_status_gate() { :; }
  pq_restamp() { :; }
  pq_mignum_wanted() { return 1; }
  pq_impact_reuse() { _pq_ir=none; }
  gh_rest() {
    local p="$2" n m id
    printf '%s\n' "$p" >> "$C/reads"
    case "$p" in
      */commits/main) printf '{"sha":"%s"}' "$(cat "$C/main")" ;;
      */actions/workflows/prequeue-gate.yml) printf '{}' ;;
      */actions/workflows/prequeue-gate.yml/runs\?*head_sha=*)
        [ -e "$C/index.fail" ] && return 75
        [ -e "$C/index.bad" ] && { printf '{"message":"x"}'; return 0; }
        m="${p#*head_sha=}"; m="${m%%&*}"; n="${p##*per_page=}"; n="${n%%&*}"
        jq -c --arg m "$m" --argjson n "$n" '{workflow_runs: ([.[] | select(.head_sha == $m)] | reverse | .[:$n])}' "$C/runs.json" ;;
      */actions/workflows/prequeue-gate.yml/runs\?*)
        n="${p##*per_page=}"; n="${n%%&*}"
        jq -c --argjson n "$n" '{workflow_runs: (reverse | .[:$n])}' "$C/runs.json" ;;
      */actions/runs/*/jobs) id="${p#*/actions/runs/}"; id="${id%%/*}"; printf '{"jobs":[{"id":%s}]}' "$id" ;;
      */check-runs/*/annotations) id="${p#*/check-runs/}"; id="${id%%/*}"
        if [ -r "$C/ann.$id" ]; then cat "$C/ann.$id"; else printf '[]'; fi ;;
      *) return 44 ;;
    esac
  }
  gh() {
    local pr="" hd="" mn="" a
    case "$*" in "workflow run prequeue-gate.yml"*) ;; *) return 1 ;; esac
    printf '%s\n' "$*" >> "$C/dispatch"
    for a in "$@"; do case "$a" in pr=*) pr="${a#pr=}" ;; head=*) hd="${a#head=}" ;; main=*) mn="${a#main=}" ;; esac; done
    addrun "$(TTL "$pr" "$hd" "$mn")" "$mn" in_progress
  }
}
# ws <n> — worker n: its own state dir and tick (no shared cache, no memo).
ws() { MC_STATE_DIR="$C/state$1" MC_TICK_ID="t8152-$1" MC_TICK_DIR="$C/tick$1"; }
# addrun <title> <head_sha> <status> [conclusion] — one run, newest; prints its id.
addrun() {
  local s; s=$(( $(cat "$C/seq") + 1 )); echo "$s" > "$C/seq"
  jq -c --arg t "$1" --arg h "$2" --arg st "$3" --arg c "${4:-}" --argjson id "$((1000 + s))" \
     --arg at "$(date -u -d "@$((NOW - 1500 + s))" +%Y-%m-%dT%H:%M:%SZ)" \
     '. + [{id: $id, display_title: $t, head_sha: $h, status: $st, conclusion: (if $c == "" then null else $c end), created_at: $at}]' \
     "$C/runs.json" > "$C/runs.tmp" && mv "$C/runs.tmp" "$C/runs.json"
  echo "$((1000 + s))"
}
# fill <n> <main> — n runs of other PRs, newest.
fill() { local i; for i in $(seq "$1"); do addrun "$(TTL "$((900 + i))" "$(hx ee "$i")" "$2")" "$2" completed success >/dev/null; done; }
# finish <id> <conclusion> [verdict-word] — the run completes; a verdict word adds its one annotation.
finish() {
  jq -c --argjson id "$1" --arg c "$2" 'map(if .id == $id then .status = "completed" | .conclusion = $c else . end)' "$C/runs.json" > "$C/runs.tmp" && mv "$C/runs.tmp" "$C/runs.json"
  [ -n "${3:-}" ] || return 0
  local t; t=$(jq -r --argjson id "$1" '.[] | select(.id == $id) | .display_title' "$C/runs.json")
  local h="${t#* head=}"; h="${h%% *}"; local m="${t##* main=}"
  jq -nc --arg msg "$3 main=$m head=$h suites=" '[{title: "prequeue-verdict", message: $msg}]' > "$C/ann.$1"
}
# tally <case> — add a case's counts; a case that died before its end is a failure.
tally() { local FAILS PASSES; if [ -r "$T/$1/out" ]; then . "$T/$1/out"; FAIL=$((FAIL + FAILS)); PASS=$((PASS + PASSES)); else bad "$1: the case did not finish"; fi; }
ndisp() { grep -c . "$C/dispatch"; }
nidx()  { grep -c "head_sha=$1" "$C/reads"; }
gate()  { pq_gate "$SLUG" "$1" "https://github.com/$SLUG/pull/$1" "$2" main >/dev/null; }

# ============================================================================
# M1 — 5 asks, one key, one dispatch; a new main, one more.
# ============================================================================
mkdir -p "$T/m1"; echo "$A" > "$T/m1/main"
( load m1
  for w in 1 2 3 4 5; do ws "$w"; gate 41 "$H"; fill 40 "$Z"; done
  [ "$(ndisp)" = 1 ] && ok || bad "M1: 5 asks for one (pr, head, main) dispatch once (got $(ndisp)); log: $(grep PREQUEUE "$C/log" | tail -3)"
  echo "$B" > "$C/main"; ws 6; gate 41 "$H"
  [ "$(ndisp)" = 2 ] && ok || bad "M1: a new main dispatches once more (total $(ndisp), want 2)"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m1

# ============================================================================
# M2 — 5 READY PRs on main A share one run-list read in one tick.
# ============================================================================
mkdir -p "$T/m2"; echo "$A" > "$T/m2/main"
( load m2
  for n in 41 42 43 44 45; do
    id=$(addrun "$(TTL "$n" "$(hx a$((n - 40)))" "$A")" "$A" in_progress)
    pq_cache_put "$(pq_key "$SLUG" "$n" "$(hx a$((n - 40)))" "$A")" pending "$((NOW - 60))" "$id" ""
  done
  : > "$C/reads"
  for n in 41 42 43 44 45; do gate "$n" "$(hx a$((n - 40)))"; done
  [ "$(nidx "$A")" = 1 ] && ok || bad "M2: 5 settles on one main read head_sha=$A once (got $(nidx "$A"))"
  [ "$(ndisp)" = 0 ] && ok || bad "M2: no dispatch for pending entries (got $(ndisp))"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m2

# ============================================================================
# M3 — adopt a run that is the 45th newest.
# ============================================================================
mkdir -p "$T/m3"; echo "$A" > "$T/m3/main"
( load m3
  id=$(addrun "$(TTL 41 "$H" "$A")" "$A" in_progress); fill 44 "$Z"
  gate 41 "$H"
  [ "$(ndisp)" = 0 ] && ok || bad "M3: a run past the 30 newest is adopted, not dispatched again (got $(ndisp))"
  # The adopt path found it, not the dispatch's own check behind it.
  [ "$(grep -c "PREQUEUE adopt #41 head=${H:0:12} main=${A:0:12} run=$id -> hold" "$C/log")" = 1 ] && ok \
    || bad "M3: one PREQUEUE adopt line names run $id (log: $(grep -E 'PREQUEUE (adopt|dedup)' "$C/log"))"
  read -r st _ rid _ <<<"$(pq_cache_get "$(pq_key "$SLUG" 41 "$H" "$A")")"
  [ "$st $rid" = "pending $id" ] && ok || bad "M3: the cache holds pending with run $id (got '$st $rid')"
  [ "$PQ_VERDICT" = hold ] && ok || bad "M3: a running adopted run holds (got $PQ_VERDICT)"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m3

# ============================================================================
# M4 — settle a pending run past the 30 newest in this tick.
# ============================================================================
mkdir -p "$T/m4"; echo "$A" > "$T/m4/main"
( load m4
  id=$(addrun "$(TTL 41 "$H" "$A")" "$A" in_progress); fill 35 "$Z"; finish "$id" success green
  P41=$(pq_key "$SLUG" 41 "$H" "$A"); pq_cache_put "$P41" pending "$((NOW - 300))" "$id" ""
  gate 41 "$H"
  [ "$PQ_VERDICT" = proceed ] && ok || bad "M4: a completed green run is read this tick (got $PQ_VERDICT)"
  read -r st _ <<<"$(pq_cache_get "$P41")"
  [ "$st" = green ] && ok || bad "M4: the cache holds green (got '$st')"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m4

# ============================================================================
# M5 — a fresh state dir finds a completed run by the main sha.
# ============================================================================
mkdir -p "$T/m5"; echo "$A" > "$T/m5/main"
( load m5
  id=$(addrun "$(TTL 41 "$H" "$A")" "$A" in_progress); finish "$id" success green; fill 31 "$A"
  gate 41 "$H"
  [ "$(ndisp)" = 0 ] && ok || bad "M5: no dispatch for a key with a completed run (got $(ndisp))"
  read -r st _ <<<"$(pq_cache_get "$(pq_key "$SLUG" 41 "$H" "$A")")"
  [ "$st" = green ] && [ "$PQ_VERDICT" = proceed ] && ok || bad "M5: its green is read (cache '$st', verdict $PQ_VERDICT)"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m5

# ============================================================================
# M6 — the dedup before the spend, and the round trip to a verdict.
# ============================================================================
mkdir -p "$T/m6"; echo "$A" > "$T/m6/main"
( load m6
  unset -f pq_adopt_run
  id=$(addrun "$(TTL 41 "$H" "$A")" "$A" in_progress)
  P41=$(pq_key "$SLUG" 41 "$H" "$A")
  pq_dispatch "$SLUG" 41 "$H" "$A"; rc=$?
  [ "$rc" = 3 ] && ok || bad "M6: a run with the title answers rc 3 (got $rc)"
  read -r st at rid _ <<<"$(pq_cache_get "$P41")"
  [ "$st $rid" = "pending $id" ] && [ "$at" -gt 0 ] 2>/dev/null && ok || bad "M6: the entry is pending <created> $id (got '$st $at $rid')"
  [ "$(grep -c "PREQUEUE dedup #41 head=${H:0:12} main=${A:0:12} run=$id status=in_progress -> no-dispatch" "$C/log")" = 1 ] && ok \
    || bad "M6: one dedup line (log: $(grep dedup "$C/log"))"
  [ "$(ndisp)" = 0 ] && ok || bad "M6: 0 dispatches (got $(ndisp))"
  finish "$id" success green; ws 2; MC_STATE_DIR="$C/state1"
  gate 41 "$H"
  read -r st _ <<<"$(pq_cache_get "$P41")"
  [ "$PQ_VERDICT $st" = "proceed green" ] && ok || bad "M6: the next gate reads the green (got '$PQ_VERDICT $st')"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m6

# ============================================================================
# M7 — the matcher.
# ============================================================================
mkdir -p "$T/m7"; echo "$A" > "$T/m7/main"
( load m7
  declare -F pq_main_run_find >/dev/null && ok || bad "M7: pq_main_run_find is defined"
  i1=$(addrun "$(TTL 41 "$H" "$A")" "$A" completed failure); i2=$(addrun "$(TTL 41 "$H" "$A")" "$A" in_progress)
  r=$(pq_main_run_find "$SLUG" "$(TTL 41 "$H" "$A")"); rc=$?
  read -r id st cc at <<<"$r"
  [ "$rc $id $st $cc" = "0 $i2 in_progress -" ] && [ "$at" -gt 0 ] 2>/dev/null && ok || bad "M7: the newest of two wins (got rc $rc '$r', want $i2)"
  r=$(pq_main_run_find "$SLUG" "$(TTL 41 "${H:0:39}b" "$A")"); rc=$?
  [ "$rc" = 0 ] && [ -z "$r" ] && ok || bad "M7: one hex char off matches nothing (rc $rc '$r')"
  r=$(pq_main_run_find "$SLUG" "$(TTL 41 "$H" "$Z")" fresh); rc=$?
  [ "$rc" = 0 ] && [ -z "$r" ] && ok || bad "M7: an empty list prints nothing (rc $rc '$r')"
  r=$(pq_main_run_find "$SLUG" "prequeue pr=41 head=$H main=cafe"); rc=$?
  [ "$rc" = 1 ] && [ -z "$r" ] && ok || bad "M7: a main that is not 40 hex reads nothing, rc 1 (rc $rc '$r')"
  grep -q 'head_sha=cafe' "$C/reads" && bad "M7: no read for a main that is not 40 hex" || ok
  touch "$C/index.bad"; r=$(pq_main_run_find "$SLUG" "$(TTL 41 "$H" "$B")" fresh); rc=$?
  [ "$rc" = 75 ] && [ -z "$r" ] && ok || bad "M7: a body without workflow_runs is rc 75 (rc $rc '$r')"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m7

# ============================================================================
# M8 — the knobs.
# ============================================================================
mkdir -p "$T/m8"; echo "$A" > "$T/m8/main"
( load m8
  MC_PREQUEUE_MAIN_RUNS=0; gate 41 "$H"
  [ "$(grep -c head_sha= "$C/reads")" = 0 ] && ok || bad "M8: knob 0 reads no head_sha list ($(grep head_sha= "$C/reads" | head -1))"
  [ "$(ndisp)" = 1 ] && ok || bad "M8: knob 0 dispatches once on a miss (got $(ndisp))"
  grep -q 'runs?event=workflow_dispatch&per_page=30' "$C/reads" && ok || bad "M8: knob 0 reads the 30-run list as before"
  unset MC_PREQUEUE_MAIN_RUNS; MC_PREQUEUE_MAIN_RUNS_PAGE=500; ws 2
  pq_main_runs "$SLUG" "$A"
  grep -q "head_sha=$A&per_page=100\$" "$C/reads" && ok || bad "M8: page 500 asks per_page=100 ($(grep head_sha= "$C/reads" | tail -1))"
  MC_PREQUEUE_MAIN_RUNS_PAGE=7; pq_main_runs "$SLUG" "$A" fresh
  grep -q "head_sha=$A&per_page=7\$" "$C/reads" && ok || bad "M8: page 7 asks per_page=7"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m8

# ============================================================================
# M9 — near misses dispatch.
# ============================================================================
mkdir -p "$T/m9"; echo "$A" > "$T/m9/main"
( load m9
  addrun "$(TTL 42 "$H" "$A")" "$A" in_progress >/dev/null
  addrun "$(TTL 41 "$H2" "$A")" "$A" in_progress >/dev/null
  addrun "$(TTL 41 "$H" "$B")" "$A" in_progress >/dev/null
  addrun "$(TTL 41 "$H" "$A") extra" "$A" in_progress >/dev/null
  gate 41 "$H"
  [ "$(ndisp)" = 1 ] && ok || bad "M9: no near miss counts as the run (got $(ndisp) dispatches)"
  grep -q 'PREQUEUE dedup' "$C/log" && bad "M9: no dedup line on a near miss" || ok
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m9

# ============================================================================
# M10 — a named-suites run is never deduped.
# ============================================================================
mkdir -p "$T/m10"; echo "$A" > "$T/m10/main"
( load m10
  addrun "$(TTL 41 "$H" "$A")" "$A" completed success >/dev/null
  pq_dispatch "$SLUG" 41 "$H" "$A" tests/a.sh fp8152; rc=$?
  [ "$rc" = 0 ] && [ "$(ndisp)" = 1 ] && ok || bad "M10: a named-suites dispatch goes out (rc $rc, $(ndisp) dispatches)"
  grep -q 'suites=tests/a.sh' "$C/dispatch" && ok || bad "M10: it carries its suites"
  [ "$(grep -c head_sha= "$C/reads")" = 0 ] && ok || bad "M10: it reads no head_sha list"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m10

# ============================================================================
# M11 — a dedup hit on a failed run alerts once.
# ============================================================================
mkdir -p "$T/m11"; echo "$A" > "$T/m11/main"
( load m11
  unset -f pq_adopt_run
  id=$(addrun "$(TTL 41 "$H" "$A")" "$A" completed failure)
  gate 41 "$H"
  [ "$(ndisp)" = 0 ] && ok || bad "M11: a failed run with the title is not dispatched again (got $(ndisp))"
  ws 2; MC_STATE_DIR="$C/state1"; gate 41 "$H"
  read -r st _ <<<"$(pq_cache_get "$(pq_key "$SLUG" 41 "$H" "$A")")"
  [ "$st" = could-not-run ] && ok || bad "M11: the next settle writes could-not-run (got '$st')"
  [ "$(grep -c . "$C/alerts")" = 1 ] && ok || bad "M11: one alert (got $(grep -c . "$C/alerts"))"
  ws 3; MC_STATE_DIR="$C/state1"; gate 41 "$H"
  [ "$(grep -c . "$C/alerts")" = 1 ] && [ "$(ndisp)" = 0 ] && ok || bad "M11: a later tick adds no alert and no dispatch ($(grep -c . "$C/alerts") alerts, $(ndisp) dispatches)"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m11

# ============================================================================
# M12 — an unwritable cache, and a failed index read.
# ============================================================================
mkdir -p "$T/m12"; echo "$A" > "$T/m12/main"
( load m12
  addrun "$(TTL 41 "$H" "$A")" "$A" in_progress >/dev/null
  mkdir -p "$MC_STATE_DIR"; : > "$MC_STATE_DIR/prequeue"
  pq_dispatch "$SLUG" 41 "$H" "$A"; rc=$?
  [ "$rc" = 4 ] && [ "$(ndisp)" = 0 ] && ok || bad "M12: an unwritable cache is rc 4 with no dispatch (rc $rc, $(ndisp))"
  grep -q 'PREQUEUE dedup' "$C/log" && bad "M12: no dedup line when the entry was not written" || ok
  ws 2; touch "$C/index.fail"
  pq_dispatch "$SLUG" 42 "$H" "$A"; rc=$?
  [ "$rc" = 0 ] && [ "$(ndisp)" = 1 ] && ok || bad "M12: a failed index read dispatches as before (rc $rc, $(ndisp))"
  [ "$(grep -c "PREQUEUE dedup #42 head=${H:0:12} main=${A:0:12} -> read-failed, dispatched" "$C/log")" = 1 ] && ok \
    || bad "M12: one read-failed line (log: $(grep dedup "$C/log"))"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m12

# ============================================================================
# M13 — a tree without main-runs.sh (a scratch tree that copies only
# dispatch.sh and adopt.sh) settles and dispatches as before, under set -u.
# ============================================================================
mkdir -p "$T/m13"; echo "$A" > "$T/m13/main"
( load m13
  unset -f pq_main_runs pq_main_run_find
  id=$(addrun "$(TTL 41 "$H" "$A")" "$A" in_progress); finish "$id" success green
  P41=$(pq_key "$SLUG" 41 "$H" "$A"); pq_cache_put "$P41" pending "$((NOW - 300))" "$id" ""
  gate 41 "$H"
  read -r st _ <<<"$(pq_cache_get "$P41")"
  [ "$PQ_VERDICT $st" = "proceed green" ] && ok || bad "M13: settle without the hook reads the green (got '$PQ_VERDICT $st')"
  gate 42 "$H"
  [ "$(ndisp)" = 1 ] && [ "$(grep -c head_sha= "$C/reads")" = 0 ] && ok || bad "M13: a miss without the hook dispatches once, no head_sha read ($(ndisp))"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m13

# ============================================================================
# M14 — 5 READY PRs on one main: one run per head, never one run for all.
# ============================================================================
mkdir -p "$T/m14"; echo "$A" > "$T/m14/main"
( load m14
  for n in 41 42 43 44 45; do ws "$n"; gate "$n" "$(hx a$((n - 40)))"; done
  [ "$(ndisp)" = 5 ] && ok || bad "M14: 5 READY PRs on one main dispatch once per head (got $(ndisp), want 5)"
  for n in 41 42 43 44 45; do
    [ "$(grep -c -- "-f pr=$n -f head=$(hx a$((n - 40))) -f main=$A" "$C/dispatch")" = 1 ] && ok || bad "M14: PR $n has exactly one dispatch on main A"
  done
  for n in 41 42 43 44 45; do ws "$((n + 10))"; gate "$n" "$(hx a$((n - 40)))"; done
  [ "$(ndisp)" = 5 ] && ok || bad "M14: 5 more asks from fresh state dirs add no dispatch (total $(ndisp), want 5)"
  echo "FAILS=$FAIL" > "$C/out"; echo "PASSES=$PASS" >> "$C/out" )
tally m14

echo "prequeue-main-runs.bh-8152: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
