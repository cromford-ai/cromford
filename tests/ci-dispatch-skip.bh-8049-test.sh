#!/bin/bash
# tests/ci-dispatch-skip.bh-8049-test.sh — BH-8049: a lane that dispatches a
# PR's CI workflow on a PR head does not dispatch when a pull_request or
# merge_group run of that workflow on the same head is green or in progress.
#
#   bin/lib/ci-dispatch-skip.sh   cds_check: the decision (section D)
#   bin/lib/mc-stuck-timers.sh    mst_ci_nostart: the CI-never-started dispatch (M)
#   bin/lib/mc/block-ci.sh        mc_block_ci_step: the CI-only BLOCK dispatch (B)
#
# GitHub is a gh_rest FUNCTION answering from fixture files (no network), the
# shape tests/block-gate-ci-clear.bh-3929-test.sh uses. Every other helper is a
# stub over files in this run's own $T. Every time is a literal.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ci-dispatch-skip.bh-8049-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
export HARNESS="$H" MC_H="$H" ACTIONS=1
mkdir -p "$H/state" "$H/logs"

SLUG=Acme/mk; NUM=77; KEY="Acme/mk#77"
URL="https://github.com/$SLUG/pull/$NUM"
HEAD=aaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbb
OTHER=dddddddddddddddddddddddddddddddddddddddd
BR=ticket/TK-1; BR_Q=ticket%2Fmk-1
SHA12=${HEAD:0:12}

# ── the libraries under test ────────────────────────────────────────────────
[ -f "$DIR/bin/lib/ci-dispatch-skip.sh" ] || bad "setup: bin/lib/ci-dispatch-skip.sh is missing"
# shellcheck source=bin/lib/ci-dispatch-skip.sh
. "$DIR/bin/lib/ci-dispatch-skip.sh" 2>/dev/null
# shellcheck source=bin/lib/mc-stuck-timers.sh
. "$DIR/bin/lib/mc-stuck-timers.sh" || { echo "cannot source mc-stuck-timers.sh"; exit 1; }
# shellcheck source=bin/lib/mc/block-ci.sh
. "$DIR/bin/lib/mc/block-ci.sh" || { echo "cannot source mc/block-ci.sh"; exit 1; }

# ── fake GitHub: $T/gh/<METHOD>/<path, / as __>; <file>.status = that status ─
_fx() { printf '%s/gh/%s/%s' "$T" "$1" "$(printf '%s' "$2" | sed 's|/|__|g')"; }
fx()        { local f; f=$(_fx "$1" "$2"); mkdir -p "${f%/*}"; printf '%s\n' "$3" > "$f"; }
fx_status() { local f; f=$(_fx "$1" "$2"); mkdir -p "${f%/*}"; echo "$3" > "$f.status"; }
gh_rest() {
  local m="$1" p="$2" f; shift 2
  printf '%s %s%s\n' "$m" "$p" "${*:+ $*}" >> "$T/calls.log"
  f=$(_fx "$m" "$p"); GH_REST_STATUS=200
  if [ -f "$f.status" ]; then
    GH_REST_STATUS=$(cat "$f.status"); [ "$GH_REST_STATUS" = 404 ] && return 44; return 75
  fi
  [ -f "$f" ] && { cat "$f"; return 0; }
  [ "$m" = GET ] && { GH_REST_STATUS=404; return 44; }
  GH_REST_STATUS=204; return 0
}

# run <id> <event> <wf file> <status> <conclusion|null> [head]
run() {
  jq -nc --argjson i "$1" --arg e "$2" --arg p ".github/workflows/$3" --arg s "$4" --argjson c "$5" --arg h "${6:-$HEAD}" \
    '{id:$i, workflow_id:($p|length), event:$e, path:$p, status:$s, conclusion:$c, head_sha:$h}'
}
runs_json() { printf '{"total_count":%s,"workflow_runs":[%s]}' "$#" "$(IFS=,; printf '%s' "$*")"; }
RUNS_PATH="repos/$SLUG/actions/runs?head_sha=$HEAD&per_page=100"
runs_fx() { fx GET "$RUNS_PATH" "$(runs_json "$@")"; }
n_dispatch() { grep -c 'POST .*/dispatches' "$T/calls.log" 2>/dev/null; }

reset() {
  rm -rf "$T/gh" "$T/d1"
  : > "$T/calls.log"; : > "$T/mc.log"; : > "$T/alerts.log"; : > "$T/attempts.txt"
  export ACTIONS=1
}

# ═══ D. cds_check, the decision table ═══════════════════════════════════════
# dcase <name> <expect rc> <expect stdout ('' = none)> <runs-json>
dcase() {
  local out rc=0
  out=$(cds_check "$SLUG" "$HEAD" ci.yml "$4" 2>/dev/null) || rc=$?
  [ "$rc" = "$2" ] && [ "$out" = "$3" ] && ok || bad "$1: want rc $2 '$3', got rc $rc '$out'"
}
declare -F cds_check >/dev/null || { cds_check() { return 99; }; bad "D: cds_check is not defined"; }
SKIPG="ci-dispatch: skip $SHA12: ci.yml run 9101 is green"
dcase D1  0 "$SKIPG" "$(runs_json "$(run 9101 pull_request ci.yml completed '"success"')")"
dcase D2  0 "ci-dispatch: skip $SHA12: ci.yml run 9102 is in_progress" "$(runs_json "$(run 9102 pull_request ci.yml in_progress null)")"
dcase D3  0 "ci-dispatch: skip $SHA12: ci.yml run 9103 is queued" "$(runs_json "$(run 9103 pull_request ci.yml queued null)")"
dcase D4  0 "ci-dispatch: skip $SHA12: ci.yml run 9104 is green" "$(runs_json "$(run 9104 merge_group ci.yml completed '"success"')")"
dcase D5  1 "" '{"total_count":0,"workflow_runs":[]}'
dcase D6  1 "" "$(runs_json "$(run 9106 pull_request ci.yml completed '"failure"')")"
dcase D7  1 "" "$(runs_json "$(run 9107 pull_request ci.yml completed '"cancelled"')")"
dcase D8  1 "" "$(runs_json "$(run 9108 workflow_dispatch ci.yml completed '"success"')")"
dcase D9  1 "" "$(runs_json "$(run 9109 pull_request e2e.yml completed '"success"')")"
dcase D10 1 "" "$(runs_json "$(run 9110 pull_request ci.yml completed '"success"' "$OTHER")")"
dcase D11 1 "" "$(runs_json "$(run 9111 pull_request xci.yml completed '"success"')")"
dcase D12 0 "ci-dispatch: skip $SHA12: ci.yml run 9112 is green" \
  "$(runs_json "$(run 9100 pull_request ci.yml completed '"failure"')" "$(run 9112 pull_request ci.yml completed '"success"')")"
dcase D14 1 "" "$(runs_json "$(run 9114 push ci.yml completed '"success"')")"
# a green run beats a newer in-flight one; among in-flight runs the newest wins
dcase D15 0 "ci-dispatch: skip $SHA12: ci.yml run 9115 is green" \
  "$(runs_json "$(run 9115 pull_request ci.yml completed '"success"')" "$(run 9116 pull_request ci.yml in_progress null)")"
dcase D16 0 "ci-dispatch: skip $SHA12: ci.yml run 9118 is queued" \
  "$(runs_json "$(run 9117 pull_request ci.yml in_progress null)" "$(run 9118 pull_request ci.yml queued null)")"
# GitHub may suffix a run's path with @<ref>
dcase D17 0 "ci-dispatch: skip $SHA12: ci.yml run 9119 is green" \
  "$(runs_json "$(jq -c '.path += "@refs/heads/main"' <<<"$(run 9119 pull_request ci.yml completed '"success"')")")"
# D13: an unreadable answer is rc 75 and one line; the caller dispatches.
UNREAD="ci-dispatch: runs unreadable for $SHA12; dispatching as before"
dcase D13a 75 "$UNREAD" 'not json'
dcase D13b 75 "$UNREAD" '[1,2]'
# Without runs-json: exactly ONE read, by head_sha.
reset; runs_fx "$(run 9101 pull_request ci.yml completed '"success"')"
OUT=$(cds_check "$SLUG" "$HEAD" ci.yml 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$SKIPG" ] && [ "$(grep -c '' "$T/calls.log")" = 1 ] && grep -qxF "GET $RUNS_PATH" "$T/calls.log" \
  && ok || bad "D-read: one GET of the head's runs and a skip (rc $RC '$OUT'): $(cat "$T/calls.log")"
reset; fx_status GET "$RUNS_PATH" 500
OUT=$(cds_check "$SLUG" "$HEAD" ci.yml 2>/dev/null); RC=$?
[ "$RC" = 75 ] && [ "$OUT" = "$UNREAD" ] && ok || bad "D13c: a failed read is rc 75 + the unreadable line (rc $RC '$OUT')"
# sourced lib: nothing printed at source time
SRC=$(bash -c ". '$DIR/bin/lib/ci-dispatch-skip.sh'" 2>&1); [ -z "$SRC" ] && ok || bad "D: sourcing prints nothing: $SRC"

# ═══ M. mst_ci_nostart (the CI-never-started dispatch) ══════════════════════
export MC_ATTEMPTS="$T/attempts.txt" MST_NOSTART_MIN=15
NOWE=2000000000
mc_now() { echo "$NOWE"; }
mc_attempt_put() { printf '%s\n' "$1" >> "$MC_ATTEMPTS"; }
mc_attempt_has() { return 1; }
mc_identity_blocked() { return 1; }
mc_hold_keeps_pr() { return 1; }
mc_tick_budget_take() { return 0; }
mc_tick_budget_give() { :; }
mc_head_still() { return 0; }
mc_log()   { printf '%s\n' "$*" >> "$T/mc.log"; }
mc_alert() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$T/alerts.log"; }
CI_YML='on:
  pull_request:
  workflow_dispatch:
jobs: {}'
mreset() {
  reset
  echo "cinone $KEY $HEAD $((NOWE - 1200))" >> "$MC_ATTEMPTS"
  fx GET "repos/$SLUG/actions/workflows?per_page=100" '{"workflows":[{"path":".github/workflows/ci.yml","state":"active"}]}'
  fx GET "repos/$SLUG/contents/.github/workflows/ci.yml?ref=$BR_Q" "$(jq -nc --arg c "$(printf '%s' "$CI_YML" | base64 -w0)" '{content:$c}')"
}
mdrive() { mst_ci_nostart demo "$KEY" "$SLUG" "$NUM" "$URL" "$HEAD" none "" CLEAN MERGEABLE main main "" "$BR" >/dev/null 2>&1; }

# M1: a green pull_request run of ci.yml on the head → no dispatch, the skip line, no alert, no cikick
mreset; runs_fx "$(run 9101 pull_request ci.yml completed '"success"')"
mdrive
[ "$(n_dispatch)" = 0 ] && ok || bad "M1: a green PR run on the head must stop the dispatch: $(cat "$T/calls.log")"
grep -qF "$KEY $SKIPG" "$T/mc.log" && ok || bad "M1: mc.log must carry '$KEY $SKIPG': $(cat "$T/mc.log")"
[ ! -s "$T/alerts.log" ] && ok || bad "M1: a run exists, so no CI_NEVER_STARTED alert: $(cat "$T/alerts.log")"
grep -q '^cikick ' "$MC_ATTEMPTS" && bad "M1: no cikick mark on a skip" || ok
grep -qxF "cinostart $KEY $HEAD" "$MC_ATTEMPTS" && ok || bad "M1: the cinostart mark is still written (the head is not checked again)"

# M2: no run on the head → exactly one dispatch of ci.yml on the branch, alerted as before
mreset; runs_fx
mdrive
[ "$(n_dispatch)" = 1 ] && grep -qxF "POST repos/$SLUG/actions/workflows/ci.yml/dispatches -f ref=$BR" "$T/calls.log" \
  && ok || bad "M2: a head with no run gets ONE dispatch: $(cat "$T/calls.log")"
grep -q "CI_NEVER_STARTED" "$T/alerts.log" && ok || bad "M2: the CI_NEVER_STARTED alert stays"
grep -q 'ci-dispatch: skip' "$T/mc.log" && bad "M2: no skip line when nothing ran" || ok

# M3: an in-progress run → no dispatch, the line says in_progress
mreset; runs_fx "$(run 9102 pull_request ci.yml in_progress null)"
mdrive
[ "$(n_dispatch)" = 0 ] && grep -qF "ci-dispatch: skip $SHA12: ci.yml run 9102 is in_progress" "$T/mc.log" \
  && ok || bad "M3: an in-progress PR run stops the dispatch: calls=$(cat "$T/calls.log") log=$(cat "$T/mc.log")"

# M4: the runs read fails → dispatch as before, with the unreadable line
mreset; fx_status GET "$RUNS_PATH" 500
mdrive
[ "$(n_dispatch)" = 1 ] && grep -qF "$UNREAD" "$T/mc.log" && ok \
  || bad "M4: an unreadable run list dispatches as before and says so: calls=$(cat "$T/calls.log") log=$(cat "$T/mc.log")"

# M5: a cancelled-only PR run (seen as none by a stale memo) → dispatch
mreset; runs_fx "$(run 9107 pull_request ci.yml completed '"cancelled"')"
mdrive
[ "$(n_dispatch)" = 1 ] && ok || bad "M5: a cancelled PR run does not stop the dispatch"

# ═══ B. mc_block_ci_step (the CI-only BLOCK dispatch) ═══════════════════════
CI_BODY='Automated harness review (r1)

- [BLOCK] CI did not run on this head

VERDICT: BLOCK'
_d1() { printf '%s/d1/%s' "$T" "$(printf '%s' "$*" | tr '/# @' '____')"; }
pr_attempt_has() { [ -f "$(_d1 att "$@")" ] && return 0; return 2; }
pr_attempt_put() { printf 'PUT pr-attempts %s\n' "$*" >> "$T/calls.log"; mkdir -p "$T/d1"; touch "$(_d1 att "$@")"; }
job_ledger_row() { local f; f=$(_d1 ledger "$1" "$2"); [ -f "$f" ] || return 2; cat "$f"; }
job_ledger_put() {
  printf 'PUT ledger %s\n' "$*" >> "$T/calls.log"
  mkdir -p "$T/d1"; jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s,detail:$d}' > "$(_d1 ledger "$1" "$2")"
}
breset() {
  reset
  fx GET "repos/$SLUG/pulls/$NUM" "{\"number\":$NUM,\"head\":{\"sha\":\"$HEAD\",\"ref\":\"$BR\"}}"
  fx GET "repos/$SLUG/actions/workflows" '{"workflows":[{"path":".github/workflows/harness-ci.yml","state":"active"}]}'
}
bstep() { RC=0; mc_block_ci_step "$SLUG" "$NUM" "$HEAD" "$URL" 9001 "$CI_BODY" >/dev/null 2>&1 || RC=$?; }

# B1: a green pull_request run of harness-ci.yml on the head → no dispatch, the
# skip line, no attempt row; the green check then clears the block.
breset
runs_fx "$(run 9201 pull_request harness-ci.yml completed '"success"')"
fx GET "repos/$SLUG/actions/runs/9201/jobs?filter=latest&per_page=100" '{"total_count":1,"jobs":[{"name":"t","conclusion":"success"}]}'
bstep
[ "$(n_dispatch)" = 0 ] && ok || bad "B1: a green PR run on the head must stop the dispatch: $(cat "$T/calls.log")"
grep -qxF "ci-dispatch: skip $SHA12: harness-ci.yml run 9201 is green" "$T/mc.log" && ok || bad "B1: the skip line: $(cat "$T/mc.log")"
grep -q 'PUT pr-attempts' "$T/calls.log" && bad "B1: a skip writes no blockci attempt row" || ok
[ "$RC" = 0 ] && grep -q "block-cleared-by-ci $KEY $HEAD 9201" "$T/mc.log" && ok || bad "B1: the green check clears the block (rc $RC): $(cat "$T/mc.log")"

# B2: no run → one dispatch, as before
breset; runs_fx
bstep
[ "$(n_dispatch)" = 1 ] && grep -qxF "POST repos/$SLUG/actions/workflows/harness-ci.yml/dispatches -f ref=$BR" "$T/calls.log" \
  && grep -q 'PUT pr-attempts' "$T/calls.log" && [ "$RC" = 1 ] && ok \
  || bad "B2: no run on the head → one dispatch after the attempt row (rc $RC): $(cat "$T/calls.log")"

# B3: an in-progress run → no dispatch, no row, not green yet (rc 1)
breset; runs_fx "$(run 9203 pull_request harness-ci.yml in_progress null)"
bstep
[ "$(n_dispatch)" = 0 ] && ! grep -q 'PUT pr-attempts' "$T/calls.log" && [ "$RC" = 1 ] \
  && grep -qxF "ci-dispatch: skip $SHA12: harness-ci.yml run 9203 is in_progress" "$T/mc.log" && ok \
  || bad "B3: an in-progress PR run stops the dispatch (rc $RC): calls=$(cat "$T/calls.log") log=$(cat "$T/mc.log")"

# B4: a red PR run → dispatch as before
breset; runs_fx "$(run 9204 pull_request harness-ci.yml completed '"failure"')"
bstep
[ "$(n_dispatch)" = 1 ] && ok || bad "B4: a red PR run does not stop the dispatch: $(cat "$T/calls.log")"

echo "ci-dispatch-skip.bh-8049: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
