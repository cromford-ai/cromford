#!/bin/bash
# tests/prr-ci-state.bh-9936-test.sh — BH-9936 (BH-9926.4): CI from the PR
# record. bin/lib/prr-ci-state.sh (prr_ci_state and its missed-event guard),
# the merge-conductor seam (bin/lib/prr-shadow.d/merge-conductor.sh) and the
# mc_ci_state wrapper (bin/lib/mc/classify.sh).
#
#   A1..A15  the decision table: the word prr_ci_state prints for a record, and
#            0 GitHub reads for every non-guard case
#   K1..K3   the knobs: a bad value is the fallback plus one log line
#   G1..G6   the guard: exact actions/runs reads, exact PUTs, the PUT body,
#            the word, one PRR_CI_GUARD line; the PUT body read back
#   S1..S7   mc_ci_state through prr_read: shadow mismatch / match, record red,
#            the 2-arg call, record hit, record miss, shadow guard off
#   D1       defaults: no knob env, no rows
#   R1       the knob fragments are in the built lanes registry
#
# Stubs, all in-test: _jobs_req (a fake jobs worker over $T/rec/, one line per
# request in $T/jobs.log) and gh_rest (one line per read in $T/gh.log, answers
# from $T/runs.json). No network. Each case seeds its own PR number.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prr-ci-state.bh-9936-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/prr-ci-state.sh"
SEAM="$DIR/bin/lib/prr-shadow.d/merge-conductor.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }

export HARNESS="$T/h"; mkdir -p "$HARNESS/logs" "$T/tmp" "$T/rec"
export TMPDIR="$T/tmp"
unset GH_SOURCE H PRR_CI_PENDING_MAX_S PRR_CI_IGNORE_RE PRR_CI_CHECKS_MAX PRR_CI_GUARD GH_TOKEN GITHUB_TOKEN
export MC_CI_ADVISORY_RED=0
NOW=1795000000                      # 2026-11-17T07:46:40Z, pinned (D60)
export PRR_CI_NOW=$NOW
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
SLUG=example-org/demo
HD=abcdef0123456789abcdef0123456789abcdef01
GD=1111111111111111111111111111111111111111
LOG="$HARNESS/logs/prr-shadow.log"

# ---- stubs -------------------------------------------------------------------------
# The fake jobs worker. GET /api/pr-records?repo=&number= -> {row, age_s};
# PUT /api/pr-records -> the checks field replaced, {row, applied, stale}.
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$T/jobs.log"
  [ -f "$T/jobs-down" ] && return 1
  local f n
  case "$1" in
    GET)
      n=$(sed -n 's/.*number=\([0-9]*\).*/\1/p' <<<"$2"); f="$T/rec/$n.json"
      if [ -f "$f" ]; then jq -c '{row: ., age_s: 5}' "$f"; else echo '{"row":null,"age_s":null}'; fi ;;
    PUT)
      n=$(jq -r '.number' <<<"$3"); f="$T/rec/$n.json"
      printf '%s\n' "$3" >> "$T/put-$n.json"
      [ -f "$f" ] || jq -nc --argjson n "$n" '{repo:"example-org/demo", number:$n, head_sha:null, checks:null}' > "$f"
      jq -c --argjson b "$3" '. + $b.fields' "$f" > "$f.n" && mv "$f.n" "$f"
      jq -c '{row: ., applied: ["checks"], stale: []}' "$f" ;;
    *) return 1 ;;
  esac
}
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$T/gh.log"
  if [ -f "$T/gh-down" ]; then GH_REST_STATUS=503; return 75; fi
  GH_REST_STATUS=200; cat "$T/runs.json"
}
# runs <status|conclusion> ... -> $T/runs.json, one workflow per argument (CI, CI2, ...)
runs() {
  local i=0 a s c out='[]'
  for a in "$@"; do
    i=$((i + 1)); s=${a%%|*}; c=${a#*|}
    out=$(jq -c --arg s "$s" --arg c "$c" --arg h "$HD" --argjson i "$i" \
      '. + [{id: (7000 + $i), name: (if $i == 1 then "CI" else "CI\($i)" end), head_sha: $h, status: $s,
             conclusion: (if $c == "" then null else $c end), run_started_at: "2026-11-17T07:00:00Z", run_attempt: 1}]' <<<"$out")
  done
  jq -c '{total_count: length, workflow_runs: .}' <<<"$out" > "$T/runs.json"
}

# shellcheck source=bin/lib/prr-ci-state.sh
. "$LIB" || { echo "FAIL: $LIB did not source"; exit 1; }
command -v prr_ci_state >/dev/null 2>&1 || { echo "FAIL: prr_ci_state is not defined"; exit 1; }

# ent <status> <conclusion|''> <sha> <age_s> -> one checks entry
ent() { jq -nc --arg s "$1" --arg c "$2" --arg h "$3" --arg at "$(iso $((NOW - $4)))" \
  '{status:$s, conclusion:(if $c == "" then null else $c end), sha:$h, at:$at}'; }
# seed <n> <head_sha|null> <checks-json|null>
seed() {
  rm -f "$T/rec/$1.json" "$T/put-$1.json"
  jq -nc --argjson n "$1" --arg h "$2" --argjson c "$3" \
    '{repo:"example-org/demo", number:$n, state:"open", head_sha:(if $h == "null" then null else $h end), checks:$c}' > "$T/rec/$1.json"
}
reset_logs() { : > "$T/gh.log"; : > "$T/jobs.log"; : > "$LOG"; rm -f "$T/gh-down" "$T/jobs-down"; }
ghn()  { grep -c 'actions/runs' "$T/gh.log" 2>/dev/null || true; }
putn() { grep -c '^PUT /api/pr-records' "$T/jobs.log" 2>/dev/null || true; }
# acase <id> <n> <want> [head]
acase() {
  reset_logs
  local got; got=$(prr_ci_state "$SLUG" "$2" "${4:-$HD}")
  [ "$got" = "$3" ] && ok || bad "$1: want '$3' got '$got' (record $(cat "$T/rec/$2.json" 2>/dev/null | head -c 300))"
  [ "$(ghn)" = 0 ] && ok || bad "$1: a non-guard case makes 0 GitHub reads, got $(ghn)"
  [ "$(putn)" = 0 ] && ok || bad "$1: a non-guard case writes nothing, got $(putn) PUT(s)"
}

# ---- A: the decision table -------------------------------------------------------
seed 101 "$HD" "{\"CI / build\":$(ent completed success "$HD" 300),\"lint\":$(ent completed success "$HD" 290)}"
acase A1 101 green
seed 102 "$HD" "{\"build\":$(ent completed success "$HD" 300),\"e2e\":$(ent completed skipped "$HD" 300),\"x\":$(ent completed neutral "$HD" 300),\"y\":$(ent completed cancelled "$HD" 300),\"z\":$(ent completed timed_out "$HD" 300)}"
acase A2 102 green
seed 103 "$HD" "{\"build\":$(ent in_progress '' "$HD" 60),\"lint\":$(ent completed success "$HD" 60)}"
acase A3 103 pending
seed 104 "$HD" "{\"build\":$(ent completed failure "$HD" 60),\"lint\":$(ent completed success "$HD" 60)}"
acase A4 104 red
seed 105 "$HD" "{\"build\":$(ent completed success "$GD" 60),\"lint\":$(ent completed success "$GD" 60)}"
acase A5 105 unknown
seed 106 "$GD" "{\"build\":$(ent completed success "$HD" 60)}"
acase A6 106 unknown
rm -f "$T/rec/107.json"
acase A7a 107 unknown
seed 108 "$HD" null
acase A7b 108 unknown
seed 109 "$HD" '{}'
acase A7c 109 unknown
seed 110 "$HD" "{\"Mergify Merge Queue\":$(ent in_progress '' "$HD" 5000),\"Summary\":$(ent completed success "$HD" 60)}"
acase A8 110 unknown
seed 111 "$HD" "{\"build\":$(ent completed success "$HD" 60),\"Mergify Merge Queue\":$(ent in_progress '' "$HD" 5000),\"Rule: default (queue)\":$(ent queued '' "$HD" 5000),\"suite:mergify\":$(ent queued '' "$HD" 5000)}"
acase A9 111 green
seed 112 "$HD" "{\"a\":$(ent completed cancelled "$HD" 60),\"b\":$(ent completed skipped "$HD" 60)}"
acase A10 112 unknown
C100=$(jq -nc --argjson e "$(ent completed success "$HD" 60)" '[range(0;100) | {key: "check-\(.)", value: $e}] | from_entries')
C99=$(jq -nc --argjson e "$(ent completed success "$HD" 60)" '[range(0;99) | {key: "check-\(.)", value: $e}] | from_entries')
seed 113 "$HD" "$C100"
acase A11 113 unknown
seed 114 "$HD" "$C99"
acase A12 114 green
seed 115 "$HD" "{\"build\":$(ent completed failure "$HD" 60),\"lint\":$(ent in_progress '' "$HD" 60)}"
acase A13 115 pending
seed 116 "$HD" "{\"Summary\":$(ent completed failure "$HD" 60)}"
acase A14a 116 unknown
PRR_CI_IGNORE_RE='' acase A14 116 red
# A21: the ignore regex matches the WHOLE name (the code adds ^(?:...)$), so a
# check whose name only starts with an ignored name still counts.
seed 121 "$HD" "{\"Summary of tests\":$(ent completed failure "$HD" 60)}"
acase A21 121 red
UPH=$(tr 'a-f' 'A-F' <<<"$HD")
acase A15 101 green "$UPH"
seed 117 "$(tr 'a-f' 'A-F' <<<"$HD")" "{\"build\":$(jq -c --arg h "$UPH" '.sha = $h' <<<"$(ent completed success "$HD" 60)")}"
acase A15b 117 green
seed 118 "$HD" "{\"build\":$(ent completed startup_failure "$HD" 60)}"
acase A16 118 red
seed 119 "$HD" "{\"build\":$(ent completed action_required "$HD" 60)}"
acase A17 119 red
reset_logs; touch "$T/jobs-down"
got=$(prr_ci_state "$SLUG" 101 "$HD")
[ "$got" = unknown ] && [ "$(ghn)" = 0 ] && ok || bad "A18 the jobs worker down: unknown and 0 GitHub reads, got '$got' gh=$(ghn)"
got=$(prr_ci_state "not a slug" 101 "$HD"); [ "$got" = unknown ] && ok || bad "A19 a bad repo arg is unknown, got '$got'"
got=$(prr_ci_state "$SLUG" 101 ""); [ "$got" = unknown ] && ok || bad "A20 an empty head is unknown, got '$got'"

# ---- K: knobs ------------------------------------------------------------------------
reset_logs
PRR_CI_IGNORE_RE='(' acase K1 110 unknown
grep -q "PRR_CI_KNOB PRR_CI_IGNORE_RE=.(. is not a regex" "$LOG" && ok || bad "K1 a regex jq refuses is the default plus one log line: $(cat "$LOG")"
seed 120 "$HD" "{\"build\":$(ent in_progress '' "$HD" 600)}"
PRR_CI_PENDING_MAX_S=abc acase K2 120 pending
grep -q "PRR_CI_KNOB PRR_CI_PENDING_MAX_S='abc' is not an integer in 0..86400: using 900" "$LOG" && ok || bad "K2 a bad int knob is the fallback plus one log line: $(cat "$LOG")"
PRR_CI_CHECKS_MAX=99 acase K3 114 unknown

# ---- G: the guard ---------------------------------------------------------------------
# G1 — pending past the knob, GitHub completed/success: 1 read, 1 PUT, green.
seed 201 "$HD" "{\"build\":$(ent in_progress '' "$HD" 960),\"old\":$(ent completed failure "$GD" 5000)}"
reset_logs; runs 'completed|success'
got=$(prr_ci_state "$SLUG" 201 "$HD")
[ "$got" = green ] && ok || bad "G1 want green got '$got'"
[ "$(ghn)" = 1 ] && ok || bad "G1 exactly 1 actions/runs read, got $(ghn): $(cat "$T/gh.log")"
grep -qx "GET repos/$SLUG/actions/runs?head_sha=$HD&per_page=50" "$T/gh.log" && ok || bad "G1 the read is mc_ci_state's URL: $(cat "$T/gh.log")"
[ "$(putn)" = 1 ] && ok || bad "G1 exactly 1 PUT, got $(putn): $(cat "$T/jobs.log")"
B=$(tail -1 "$T/put-201.json" 2>/dev/null)
[ "$(jq -r '.source' <<<"$B")" = github ] && ok || bad "G1 the PUT source is github: $B"
[ "$(jq -c '.fields.checks | keys' <<<"$B")" = '["workflow:CI"]' ] && ok || bad "G1 the PUT replaces checks with the head's workflow entries: $B"
[ "$(jq -r '.fields.checks["workflow:CI"] | "\(.status)|\(.conclusion)|\(.sha)|\(.at)"' <<<"$B")" = "completed|success|$HD|$(iso $NOW)" ] && ok \
  || bad "G1 the entry: status, conclusion, sha = head, at = the read start: $B"
[ "$(jq -r '.at' <<<"$B")" = "$(iso $NOW)" ] && ok || bad "G1 the PUT at is the read start: $B"
[ "$(grep -c "PRR_CI_GUARD repo=$SLUG n=201 head=${HD:0:8} age_s=960 gh_rc=0 put=ok word=green" "$LOG")" = 1 ] && ok \
  || bad "G1 one PRR_CI_GUARD line, put=ok word=green: $(cat "$LOG")"
# the round trip: the stored body feeds the next call; 0 reads.
reset_logs
got=$(prr_ci_state "$SLUG" 201 "$HD")
[ "$got" = green ] && [ "$(ghn)" = 0 ] && [ "$(putn)" = 0 ] && ok || bad "G1 round trip: green with 0 reads, got '$got' gh=$(ghn) put=$(putn)"

# G2 — under the knob: 0 reads.
seed 202 "$HD" "{\"build\":$(ent in_progress '' "$HD" 840)}"
reset_logs; runs 'completed|success'
got=$(prr_ci_state "$SLUG" 202 "$HD")
[ "$got" = pending ] && [ "$(ghn)" = 0 ] && [ "$(putn)" = 0 ] && ok || bad "G2 under the knob: pending, 0, 0; got '$got' gh=$(ghn) put=$(putn)"
[ ! -s "$LOG" ] && ok || bad "G2 no guard line: $(cat "$LOG")"

# G3 — GitHub read fails: unknown, no PUT.
seed 203 "$HD" "{\"build\":$(ent in_progress '' "$HD" 960)}"
reset_logs; touch "$T/gh-down"
got=$(prr_ci_state "$SLUG" 203 "$HD")
[ "$got" = unknown ] && [ "$(ghn)" = 1 ] && [ "$(putn)" = 0 ] && ok || bad "G3 a failed read: unknown, 1, 0; got '$got' gh=$(ghn) put=$(putn)"
grep -q "PRR_CI_GUARD repo=$SLUG n=203 head=${HD:0:8} age_s=960 gh_rc=75 put=skipped word=unknown" "$LOG" && ok || bad "G3 guard line put=skipped: $(cat "$LOG")"
[ "$(jq -c '.checks.build.status' "$T/rec/203.json")" = '"in_progress"' ] && ok || bad "G3 the record is unchanged"

# G4 — PRR_CI_GUARD=0: pending, 0 reads.
seed 204 "$HD" "{\"build\":$(ent in_progress '' "$HD" 960)}"
reset_logs; runs 'completed|success'
got=$(PRR_CI_GUARD=0 prr_ci_state "$SLUG" 204 "$HD")
[ "$got" = pending ] && [ "$(ghn)" = 0 ] && [ "$(putn)" = 0 ] && ok || bad "G4 guard off: pending, 0, 0; got '$got' gh=$(ghn) put=$(putn)"

# G5 — GitHub still in progress: 1 read, 1 PUT, pending; a second call at once: 0 reads.
seed 205 "$HD" "{\"build\":$(ent in_progress '' "$HD" 960)}"
reset_logs; runs 'in_progress|'
got=$(prr_ci_state "$SLUG" 205 "$HD")
[ "$got" = pending ] && [ "$(ghn)" = 1 ] && [ "$(putn)" = 1 ] && ok || bad "G5 still running: pending, 1, 1; got '$got' gh=$(ghn) put=$(putn)"
grep -q 'put=ok word=pending' "$LOG" && ok || bad "G5 guard line word=pending: $(cat "$LOG")"
reset_logs
got=$(prr_ci_state "$SLUG" 205 "$HD")
[ "$got" = pending ] && [ "$(ghn)" = 0 ] && [ "$(putn)" = 0 ] && ok || bad "G5 second call: pending, 0, 0; got '$got' gh=$(ghn) put=$(putn)"

# G6 — knob 0, pending 1 s old: 1 read, 1 PUT.
seed 206 "$HD" "{\"build\":$(ent in_progress '' "$HD" 1)}"
reset_logs; runs 'completed|success'
got=$(PRR_CI_PENDING_MAX_S=0 prr_ci_state "$SLUG" 206 "$HD")
[ "$got" = green ] && [ "$(ghn)" = 1 ] && [ "$(putn)" = 1 ] && ok || bad "G6 knob 0: green, 1, 1; got '$got' gh=$(ghn) put=$(putn)"

# G7 — GitHub has no run for the head: the PUT writes {}, the word is unknown.
seed 207 "$HD" "{\"build\":$(ent in_progress '' "$HD" 960)}"
reset_logs; runs
got=$(prr_ci_state "$SLUG" 207 "$HD")
[ "$got" = unknown ] && [ "$(putn)" = 1 ] && [ "$(jq -c '.fields.checks' <<<"$(tail -1 "$T/put-207.json")")" = '{}' ] && ok \
  || bad "G7 no runs: unknown and a PUT of {}; got '$got' put=$(putn)"

# G8 — the jobs worker refuses the PUT: put=failed, the word still comes from the read.
seed 208 "$HD" "{\"build\":$(ent in_progress '' "$HD" 960)}"
reset_logs; runs 'completed|failure'
_jobs_req_real=$(declare -f _jobs_req)
_jobs_req() { printf '%s %s\n' "$1" "$2" >> "$T/jobs.log"; [ "$1" = PUT ] && return 1; jq -c '{row: ., age_s: 5}' "$T/rec/208.json"; }
got=$(prr_ci_state "$SLUG" 208 "$HD")
eval "$_jobs_req_real"
[ "$got" = red ] && ok || bad "G8 a refused PUT: the word comes from the GitHub read (red), got '$got'"
grep -q 'gh_rc=0 put=failed word=red' "$LOG" && ok || bad "G8 guard line put=failed: $(cat "$LOG")"

# ---- D: defaults ------------------------------------------------------------------------
seed 301 "$HD" "{\"build\":$(ent in_progress '' "$HD" 899)}"
reset_logs; runs 'completed|success'
got=$(prr_ci_state "$SLUG" 301 "$HD")
[ "$got" = pending ] && [ "$(ghn)" = 0 ] && ok || bad "D1 default 900: 899 s is pending with 0 reads, got '$got' gh=$(ghn)"
seed 302 "$HD" "{\"build\":$(ent in_progress '' "$HD" 901)}"
reset_logs
got=$(prr_ci_state "$SLUG" 302 "$HD")
[ "$got" = green ] && [ "$(ghn)" = 1 ] && ok || bad "D1 default 900: 901 s reads GitHub once, got '$got' gh=$(ghn)"

# ---- S: mc_ci_state through prr_read ----------------------------------------------------
# The conductor's own modules: mc_rest_var (queue.sh) and mc_ci_state (classify.sh).
# They are written for the conductor's shell, which does not run under nounset.
set +u
# shellcheck source=bin/lib/mc/queue.sh
. "$DIR/bin/lib/mc/queue.sh" || { echo "FAIL: queue.sh did not source"; exit 1; }
# shellcheck source=bin/lib/mc/classify.sh
. "$DIR/bin/lib/mc/classify.sh" || { echo "FAIL: classify.sh did not source"; exit 1; }
set -u
# the mc libs may define gh_rest helpers; the in-test stub stays the one in use
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$T/gh.log"
  if [ -f "$T/gh-down" ]; then GH_REST_STATUS=503; return 75; fi
  GH_REST_STATUS=200; cat "$T/runs.json"
}
command -v _mc_ci_state_github >/dev/null 2>&1 && ok || bad "S0 _mc_ci_state_github is defined"
key() { printf '%s#%s@%s' "$SLUG" "$1" "${HD:0:12}"; }
# scase <id> <n> <GH_SOURCE|UNSET> -> W (the word), via a plain command into a file
scase() {
  reset_logs
  if [ "$3" = UNSET ]; then ( unset GH_SOURCE; mc_ci_state "$SLUG" "$HD" "$2" > "$T/w" )
  else ( export GH_SOURCE="$3"; mc_ci_state "$SLUG" "$HD" "$2" > "$T/w" ); fi
  W=$(cat "$T/w")
}
ngets() { grep -c '^GET /api/pr-records' "$T/jobs.log" 2>/dev/null || true; }
# S1 — shadow, record green, GitHub red: red, 1 PRR_SHADOW changed=1.
seed 401 "$HD" "{\"build\":$(ent completed success "$HD" 60)}"
runs 'completed|failure'
scase S1 401 shadow
[ "$W" = red ] && ok || bad "S1 shadow acts on GitHub: want red got '$W'"
[ "$(grep -c "PRR_SHADOW lane=merge-conductor key=$(key 401) .*changed=1" "$LOG")" = 1 ] && ok || bad "S1 one PRR_SHADOW line, changed=1: $(cat "$LOG")"
[ "$(ghn)" = 1 ] && [ "$(ngets)" = 1 ] && ok || bad "S1 shadow: 1 GitHub read and 1 jobs GET, got gh=$(ghn) jobs=$(ngets)"
# S2 — shadow, both green: 0 lines.
seed 402 "$HD" "{\"build\":$(ent completed success "$HD" 60)}"
runs 'completed|success'
scase S2 402 shadow
[ "$W" = green ] && [ "$(grep -c PRR_ "$LOG")" = 0 ] && ok || bad "S2 shadow match: green and no log line, got '$W': $(cat "$LOG")"
# S3 — record, record red: GitHub read, PRR_MISS why=ci:red.
seed 403 "$HD" "{\"build\":$(ent completed failure "$HD" 60)}"
runs 'completed|failure'
scase S3 403 record
[ "$W" = red ] && [ "$(ghn)" = 1 ] && ok || bad "S3 record red is never served: GitHub read, got '$W' gh=$(ghn)"
grep -q "PRR_MISS lane=merge-conductor key=$(key 403) why=ci:red fallback=github" "$LOG" && ok || bad "S3 PRR_MISS why=ci:red: $(cat "$LOG")"
# S4 — 2 args: GitHub only.
runs 'completed|success'
reset_logs
( export GH_SOURCE=record; mc_ci_state "$SLUG" "$HD" > "$T/w" ); W=$(cat "$T/w")
[ "$W" = green ] && [ "$(ghn)" = 1 ] && [ ! -s "$T/jobs.log" ] && ok || bad "S4 2-arg call: GitHub only, got '$W' gh=$(ghn) jobs=$(wc -l < "$T/jobs.log")"
( export GH_SOURCE=record; mc_ci_state "$SLUG" "$HD" abc > "$T/w" ); W=$(cat "$T/w")
[ ! -s "$T/jobs.log" ] && ok || bad "S4b a non-number 3rd arg keeps the GitHub read"
# S5 — record, record green: 0 GitHub reads, globals reset.
seed 405 "$HD" "{\"build\":$(ent completed success "$HD" 60)}"
runs 'completed|failure'
reset_logs
MC_CI_RUNS=stale; MC_CI_RED_RUN_IDS=stale
GH_SOURCE=record; export GH_SOURCE
mc_ci_state "$SLUG" "$HD" 405 > "$T/w"; W=$(cat "$T/w")
unset GH_SOURCE
[ "$W" = green ] && [ "$(ghn)" = 0 ] && ok || bad "S5 record green: 0 GitHub reads, got '$W' gh=$(ghn)"
[ -z "$MC_CI_RUNS" ] && [ -z "$MC_CI_RED_RUN_IDS" ] && [ "$MC_CI_READ_HELD" = 0 ] && ok || bad "S5 the globals are reset in the caller's shell (RUNS='$MC_CI_RUNS' RED='$MC_CI_RED_RUN_IDS')"
[ "$PRR_SOURCE" = record ] && ok || bad "S5 PRR_SOURCE=record, got '${PRR_SOURCE:-}'"
# S6 — record, no row: GitHub read, PRR_MISS why=ci:unknown.
rm -f "$T/rec/406.json"; runs 'completed|success'
scase S6 406 record
[ "$W" = green ] && [ "$(ghn)" = 1 ] && grep -q "PRR_MISS lane=merge-conductor key=$(key 406) why=ci:unknown fallback=github" "$LOG" && ok \
  || bad "S6 unknown always reads GitHub: got '$W' gh=$(ghn): $(cat "$LOG")"
# S7 — shadow, record pending past the knob: the guard is off, 1 GitHub read (the lane's own), 0 PUTs.
seed 407 "$HD" "{\"build\":$(ent in_progress '' "$HD" 5000)}"
runs 'completed|success'
scase S7 407 shadow
[ "$(ghn)" = 1 ] && [ "$(putn)" = 0 ] && ok || bad "S7 shadow costs no guard read: gh=$(ghn) put=$(putn)"
[ "$(grep -c "PRR_SHADOW lane=merge-conductor key=$(key 407) .*changed=1" "$LOG")" = 1 ] && ok || bad "S7 pending vs green is a mismatch line: $(cat "$LOG")"
# S8 — record, pending past the knob: the guard reads once and writes back; the conductor's own read is not made.
seed 408 "$HD" "{\"build\":$(ent in_progress '' "$HD" 5000)}"
runs 'completed|success'
scase S8 408 record
[ "$W" = green ] && [ "$(ghn)" = 1 ] && [ "$(putn)" = 1 ] && ok || bad "S8 record + guard: green, 1 read, 1 PUT; got '$W' gh=$(ghn) put=$(putn)"
# D1 — no GH_SOURCE: shadow (both reads).
seed 409 "$HD" "{\"build\":$(ent completed success "$HD" 60)}"
scase D1b 409 UNSET
[ "$W" = green ] && [ "$(ghn)" = 1 ] && [ "$(ngets)" = 1 ] && ok || bad "D1 no GH_SOURCE is shadow: 1 GitHub read and 1 jobs GET, got '$W' gh=$(ghn) jobs=$(ngets)"
# S9 — the seam norm: none and unavailable are never compared.
printf 'none\n' > "$T/nw"; [ -z "$(mc_ci_norm "$T/nw")" ] && ok || bad "S9 norm of none is empty"
printf 'unavailable\n' > "$T/nw"; [ -z "$(mc_ci_norm "$T/nw")" ] && ok || bad "S9 norm of unavailable is empty"
printf 'pending\n' > "$T/nw"; [ "$(mc_ci_norm "$T/nw")" = '[{"n":"ci","v":"pending"}]' ] && ok || bad "S9 norm of pending"

# ---- R: registry ------------------------------------------------------------------------
REG="$T/lanes.json"
if HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1; then
  K=$(jq -c '.lanes[] | select(.id=="merge-conductor") | .knobs[] | select(.env=="GH_SOURCE") | {default, read_in}' "$REG" 2>/dev/null)
  [ "$K" = '{"default":"shadow","read_in":"bin/lib/prr-shadow.sh"}' ] && ok || bad "R1 GH_SOURCE on merge-conductor, default shadow (got '$K')"
  for kv in PRR_CI_PENDING_MAX_S:900 PRR_CI_CHECKS_MAX:100; do
    k=${kv%%:*}; v=${kv#*:}
    got=$(jq -r --arg k "$k" '[.libs[]? | select(.id=="pr-record") | .knobs[]? | select(.env==$k) | .default] | first // empty' "$REG" 2>/dev/null)
    [ "$got" = "$v" ] && ok || bad "R1 $k default $v in the pr-record lib knobs (got '$got')"
  done
  got=$(jq -r '[.libs[]? | select(.id=="pr-record") | .knobs[]? | select(.env=="PRR_CI_IGNORE_RE") | .default] | first // empty' "$REG" 2>/dev/null)
  [ "$got" = "$(_prr_ci_ignore_default)" ] && ok || bad "R1 PRR_CI_IGNORE_RE default matches the code fallback (got '$got')"
  # R2: lanes-registry 20a reads a default with a dollar sign as shell. Such a
  # default turned tests/lanes-registry-test.sh red on main, so the BH-8473
  # pre-queue fast lint called every red head preexisting and enqueued it.
  got=$(jq -r '[.libs[]? | select(.id=="pr-record") | .knobs[]? | select(.env|startswith("PRR_CI_")) | select((.default|tostring)|contains("$")) | .env] | join(" ")' "$REG" 2>/dev/null)
  [ -z "$got" ] && ok || bad "R2 PRR_CI_* knob defaults hold no dollar sign (lanes-registry 20a), got: $got"
else
  bad "R1 lanes-build.sh did not render"
fi

echo "prr-ci-state.bh-9936: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
