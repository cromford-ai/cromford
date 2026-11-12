#!/bin/bash
# tests/mc-park-ci-recheck.bh-9368-test.sh — BH-9368 (comment 6754703346): a
# red-twice or WAIT_MIGRATION park whose CI is green again on a fresh read is
# released, and a `(report only)` check is not red when the required set
# cannot be read.
#
# Incident (project-6 #3700, #3728): the PR stayed RED_TWICE after its CI went
# green. The tick read the CI word from the 15-minute read memo, which still
# said `red`, and nothing on the row changed to make the memo stale.
#
# Part A (unit):
#   PR2b-PR2h, PR4, PR5  mc_park_ci_recheck with its seams stubbed: which rows,
#                        which reads release, the throttle per (PR, head)
#   PR3, PR3b-PR3f       mca_split with no readable required set: the report-only rule
# Part B (whole tick, tests/lib/mc-gate-tick.sh):
#   PR1   a RED_TWICE row on head H; gate is green now, only `perf-budgets
#         (report only)` is red: PARK_RELEASED_CI_GREEN, READY/QUEUED, the
#         handoff-rel record, 0 model calls
#   PR1R  the same tick with the fragment absent stays RED_TWICE (the memo)
#   PR2   gate still red: stays RED_TWICE
#   PR3W  the real mc_ci_state, .mergify.yml with no check-success name: green
#   V1    every curl went to a .test host
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-park-ci-recheck.bh-9368-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-park-ci-recheck.bh-9368: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset MC_STICKY_CI_RECHECK_SECS MC_CI_REPORT_ONLY_SUFFIX MC_CI_ADVISORY_RED MC_CI_JOBS_PAGES_MAX
FRAG="$DIR/bin/merge-conductor.d/bh-9368-park-ci-recheck.sh"
H1=$(printf 'a%.0s' $(seq 40)); H2=$(printf 'b%.0s' $(seq 40))

# ============================================================================
# Part A1 — mc_park_ci_recheck, seams stubbed.
# ============================================================================
(
  F=0; no() { F=$((F+1)); echo "FAIL: mc-park-ci-recheck.bh-9368: $1"; }
  [ -r "$FRAG" ] || { no "PR0 the fragment $FRAG is missing"; exit 1; }
  FXD="$T/ua"; mkdir -p "$FXD"; export MC_STATE_DIR="$T/ua-state"; mkdir -p "$MC_STATE_DIR"
  H="$DIR"
  # shellcheck source=bin/merge-conductor.d/bh-9368-park-ci-recheck.sh
  . "$FRAG" || exit 90
  CLK=1794364000
  mc_now() { echo "$CLK"; }
  mc_log() { printf '%s\n' "$*" >> "$FXD/log"; }
  mc_row_get() { cat "$FXD/row" 2>/dev/null; }
  mc_handoff_id() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
  mc_handoff_release() { printf '%s %s\n' "$1" "$2" >> "$FXD/released"; }
  mc_attempt_put() { echo "$1" >> "$FXD/attempts"; }
  mc_ci_state() { echo "$1 $2" >> "$FXD/reads"; cat "$FXD/word"; }
  mcr_ci_override() { echo "$*" >> "$FXD/overrides"; [ -e "$FXD/override-green" ] || { MCR_WHY="required 'gate' is completed/failure"; return 1; }
    MCR_WHY="required ci e2e-ratchet gate green; $3 is non-required"; echo green; }
  n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
  reset() { scratch_rm "$FXD"; mkdir -p "$FXD"; scratch_rm "$MC_STATE_DIR/park-ci-recheck"; CLK=1794364000; }
  row() { printf 'O/r#1\t%s\t1794360000\t%s\t%s\tAPPROVE\t%s\thttps://github.com/O/r/pull/1\n' "$1" "${3:-$H1}" "${3:-$H1}" "$2" > "$FXD/row"; }
  rc_of() { KEY="O/r#1"; HEAD="${1:-$H1}"; SLUG=O/r; PROVIDER=mergify; URL=https://github.com/O/r/pull/1; mc_park_ci_recheck; }
  want() { # want <label> <rc> <reads> <released>
    rc_of; local rc=$?
    [ "$rc" = "$2" ] && [ "$(n "$FXD/reads")" = "$3" ] && [ "$(n "$FXD/released")" = "$4" ] \
      || no "$1: want rc $2, $3 read(s), $4 release(s); got rc $rc, $(n "$FXD/reads") read(s), $(n "$FXD/released") release(s) (log: $(cat "$FXD/log" 2>/dev/null))"
  }
  # release on a raw green read
  reset; row RED_TWICE 'red-twice: still red on aaaaaaaa'; echo green > "$FXD/word"
  want "PR1u RED_TWICE, a fresh green read" 0 1 1
  grep -qx "parkcigreen O/r#1 $H1" "$FXD/attempts" && grep -q "O/r#1 PARK_RELEASED_CI_GREEN on ${H1:0:8}" "$FXD/log" && grep -qx 'O/r#1 ci-green-recheck' "$FXD/released" \
    || no "PR1u the attempts line, the log line and the release record ($(cat "$FXD/attempts" "$FXD/log" "$FXD/released" 2>/dev/null))"
  # release on red + override green (a report-only check is red)
  reset; row RED_TWICE 'red-twice: x'; echo red > "$FXD/word"; : > "$FXD/override-green"
  want "PR1v RED_TWICE, red word + override green" 0 1 1
  grep -q "PARK_RELEASED_CI_GREEN on ${H1:0:8}: required ci e2e-ratchet gate green" "$FXD/log" || no "PR1v the log line carries MCR_WHY ($(cat "$FXD/log"))"
  reset; row WAIT_MIGRATION 'migration-gate: gate red; PR adds 0001_a'; echo green > "$FXD/word"
  want "PR1w WAIT_MIGRATION, a fresh green read" 0 1 1
  reset; row BLOCKED_HUMAN 'red-twice: still red'; echo green > "$FXD/word"
  want "PR1x BLOCKED_HUMAN red-twice, a fresh green read" 0 1 1
  # no release
  reset; row RED_TWICE 'red-twice: x'; echo red > "$FXD/word"
  want "PR2 gate still red, override refuses" 1 1 0
  [ "$(n "$FXD/attempts")" = 0 ] || no "PR2 no attempts line without a release"
  reset; row RED_TWICE 'red-twice: x' "$H2"; echo green > "$FXD/word"
  want "PR2b a row on another head" 1 0 0
  reset; row BLOCKED_HUMAN 'conflict-unresolvable: x'; echo green > "$FXD/word"
  want "PR2c a conflict-unresolvable park" 1 0 0
  reset; row WAIT_CI 'checks red once'; echo green > "$FXD/word"
  want "PR2c2 a WAIT_CI row" 1 0 0
  reset; : > "$FXD/row"; echo green > "$FXD/word"
  want "PR2c3 no stored row" 1 0 0
  reset; row RED_TWICE 'red-twice: x'; echo unavailable > "$FXD/word"
  want "PR2d an unavailable read" 1 1 0
  [ "$(n "$FXD/overrides")" = 0 ] || no "PR2d no override on an unavailable read"
  reset; row RED_TWICE 'red-twice: x'; echo pending > "$FXD/word"
  want "PR2e pending, override refuses (page incomplete)" 1 1 0
  reset; row RED_TWICE 'red-twice: x'; echo none > "$FXD/word"
  want "PR2f none" 1 1 0
  # PR4 — the knob at 0: no read at all.
  reset; row RED_TWICE 'red-twice: x'; echo green > "$FXD/word"
  MC_STICKY_CI_RECHECK_SECS=0 want "PR4 MC_STICKY_CI_RECHECK_SECS=0" 1 0 0
  # PR5 — 3 calls inside 600 s: 1 read; past 600 s: 2.
  reset; row RED_TWICE 'red-twice: x'; echo red > "$FXD/word"
  rc_of; CLK=$((CLK + 100)); rc_of; CLK=$((CLK + 100)); rc_of
  [ "$(n "$FXD/reads")" = 1 ] || no "PR5 3 calls inside 600 s: 1 read (got $(n "$FXD/reads"))"
  CLK=$((1794364000 + 601)); rc_of
  [ "$(n "$FXD/reads")" = 2 ] || no "PR5 a call at +601 s reads again (got $(n "$FXD/reads"))"
  # PR5b — the throttle is per (PR, head): a new head reads at once.
  row RED_TWICE 'red-twice: x' "$H2"; rc_of "$H2"
  [ "$(n "$FXD/reads")" = 3 ] || no "PR5b a new head is not throttled by the old head's mark (got $(n "$FXD/reads"))"
  # PR5c — retention: a throttle file older than 7 days is pruned on the next write.
  touch -d '10 days ago' "$MC_STATE_DIR/park-ci-recheck/old.mark"; CLK=$((CLK + 10000)); rc_of "$H2"
  [ ! -e "$MC_STATE_DIR/park-ci-recheck/old.mark" ] || no "PR5c a throttle file older than 7 days is pruned"
  echo "part A1: $F failed"; exit "$F"
)
FAIL=$((FAIL + $?))

# ============================================================================
# Part A2 — mca_split with no readable required set (the report-only rule).
# ============================================================================
(
  F=0; no() { F=$((F+1)); echo "FAIL: mc-park-ci-recheck.bh-9368: $1"; }
  FXD="$T/ub"; mkdir -p "$FXD"; export MC_STATE_DIR="$T/ub-state"; mkdir -p "$MC_STATE_DIR"
  # mc_rest_var <var> <cmd...> — the conductor's reader shape (bin/lib/mc/queue.sh).
  mc_rest_var() { local _v="$1" _o _rc=0; shift; _o=$("$@") || _rc=$?; printf -v "$_v" '%s' "$_o"; return "$_rc"; }
  # shellcheck source=bin/lib/mc-ci-advisory.sh
  . "$DIR/bin/lib/mc-ci-advisory.sh" || exit 91
  mc_log() { printf '%s\n' "$*" >> "$FXD/log"; }
  mc_queue_provider() { echo mergify; }
  mc_mergify_required_checks() { [ -e "$FXD/req-fail" ] && return 75; cat "$FXD/req" 2>/dev/null; return 0; }
  gh_rest() { local id; id=${2#*/actions/runs/}; id=${id%%/*}
    # One page per run: a read past page 1 fails, so a cut list stays cut.
    case "$2" in *"page=1") ;; *) GH_REST_STATUS=502; return 75 ;; esac
    [ -r "$FXD/jobs-$id.json" ] || { GH_REST_STATUS=502; return 75; }
    GH_REST_STATUS=200; cat "$FXD/jobs-$id.json"; }
  jobs() { local id="$1" tot="$2" x; shift 2; for x in "$@"; do printf '%s\n' "$x"; done | jq -Rnc --argjson t "$tot" '[inputs | select(length > 0) | split("|")
    | {name: .[0], status: "completed", conclusion: .[1]}] | {total_count: $t, jobs: .}' > "$FXD/jobs-$id.json"; }
  sp() { # sp <label> <want keep|advisory>
    mca_split O/r "$(printf 'a%.0s' $(seq 40))" 'completed|failure|104|perf'
    if [ "$2" = advisory ]; then
      [ -z "$MCA_KEEP" ] && [ "$MC_CI_ADVISORY" = perf ] || no "$1: want advisory (keep '$MCA_KEEP', advisory '$MC_CI_ADVISORY', why '$MCA_WHY')"
    else
      [ "$MCA_KEEP" = 'completed|failure|104|perf' ] && [ -z "$MC_CI_ADVISORY" ] || no "$1: want red (keep '$MCA_KEEP', advisory '$MC_CI_ADVISORY', why '$MCA_WHY')"
    fi
  }
  reset() { scratch_rm "$FXD"; mkdir -p "$FXD"; : > "$FXD/req-fail"; rm -f "$MC_STATE_DIR/ci-advisory-red.tsv"; unset MC_CI_REPORT_ONLY_SUFFIX; }
  reset; jobs 104 2 'ci|success' 'perf-budgets (report only)|failure'; sp "PR3 required set unread, only a (report only) job failed" advisory
  grep -q 'advisory-red: perf on O/r' "$FXD/log" || no "PR3 one advisory-red line ($(cat "$FXD/log" 2>/dev/null))"
  [ "${MC_CI_REQ_APPLIED:-}" = 0 ] || no "PR3 the required set rule did not run (MC_CI_REQ_APPLIED=${MC_CI_REQ_APPLIED:-})"
  reset; rm -f "$FXD/req-fail"; : > "$FXD/req"; jobs 104 2 'ci|success' 'perf-budgets (report only)|failure'; sp "PR3a no check-success name (required-none)" advisory
  reset; jobs 104 3 'ci|success' 'perf-budgets (report only)|failure' 'lint|skipped'; sp "PR3a2 a skipped job beside it" advisory
  reset; jobs 104 2 'unit|failure' 'perf-budgets (report only)|failure'; sp "PR3b a unit job failed too" keep
  reset; jobs 104 1 'perf(report only)|failure'; sp "PR3c the suffix without its leading space" keep
  reset; jobs 104 1 'perf (report only) budgets|failure'; sp "PR3d 'report only' inside the name" keep
  reset; jobs 104 3 'ci|success' 'perf-budgets (report only)|failure'; sp "PR3e a cut jobs read (total 3, 2 listed)" keep
  reset; sp "PR3e2 the jobs read fails" keep
  reset; jobs 104 1 'perf-budgets (report only)|cancelled'; sp "PR3f a cancelled (report only) job is report-only too" advisory
  reset; jobs 104 2 'ci|success' 'perf-budgets (report only)|failure'; MC_CI_REPORT_ONLY_SUFFIX='' sp "PR3g the suffix knob empty: off" keep
  echo "part A2: $F failed"; exit "$F"
)
FAIL=$((FAIL + $?))

# ============================================================================
# Part B — the whole tick.
# ============================================================================
# shellcheck source=tests/lib/mc-gate-tick.sh
. "$(dirname "$0")/lib/mc-gate-tick.sh" || exit 1
mgt_setup bin/merge-conductor.d/bh-7785-migration-hold.sh bin/merge-conductor.d/bh-9368-migration-gate.sh \
  bin/merge-conductor.d/bh-9368-ledger-gate-rerun.sh || exit 1
K="$MGT_SLUG#31"
st() { mgt_row | cut -d'|' -f1; }
# park — two ticks with gate red and no knob (the rerun settle is 0): RED_TWICE
# on H1. Tick 1 writes attempts after its CI read; from tick 2 on nothing does,
# so the read memo holds `red` for this head (the project-6 shape).
park() { mgt_fresh; mgt_gate_red; mgt_tick; mgt_tick; }
# age — move every park recheck mark 20 minutes back, past the 600 s window
# (tick 2 of park() already used the window on the red head).
age() { local f; for f in "$CH"/state/merge-conductor/park-ci-recheck/*; do [ -f "$f" ] && echo "$(( $(date -u +%s) - 1200 ))" > "$f"; done; }

# PR1R — the fragment absent: the park stays RED_TWICE after gate turns green.
park; S0=$(st); mgt_gate_green; mgt_tick
[ "$S0" = RED_TWICE ] && [ "$(st)" = RED_TWICE ] && ok || bad "PR1R without the fragment the green head stays RED_TWICE ($S0 -> $(st); log: $(mgt_log 3))"
# PR1 — with the fragment: released and READY/QUEUED in the same tick.
[ -r "$DIR/bin/merge-conductor.d/bh-9368-park-ci-recheck.sh" ] && ( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-9368-park-ci-recheck.sh "$CH" >/dev/null )
park; S0=$(st); mgt_gate_green; age; mgt_tick; S1=$(st)
[ "$S0" = RED_TWICE ] && { [ "$S1" = READY ] || [ "$S1" = QUEUED ]; } && ok || bad "PR1 RED_TWICE -> READY/QUEUED on a fresh green read ($S0 -> $S1; log: $(mgt_log))"
grep -q "$K PARK_RELEASED_CI_GREEN on ${MGT_H1:0:8}" "$CLOG" && ok || bad "PR1 the PARK_RELEASED_CI_GREEN line ($(mgt_log 3))"
[ -e "$CH/state/merge-conductor/handoff-released/example-org_mkey-os_31" ] && ok || bad "PR1 the handoff-rel record"
[ "$(mgt_n "$BX/model-calls.txt")" = 0 ] && ok || bad "PR1 0 model calls"
# PR2 — gate still red: the park stays.
park; age; mgt_tick; mgt_tick
[ "$(st)" = RED_TWICE ] && ! grep -q PARK_RELEASED_CI_GREEN "$CLOG" && ok || bad "PR2 gate still red: stays RED_TWICE ($(mgt_row))"

# PR3W — the real mc_ci_state on a head whose .mergify.yml names no check-success.
# The closure install names the repo's conductor and its lib here, so the
# test-impact map selects this suite when bin/lib/merge-conductor-lib.sh changes.
( cd "$DIR" && scratch_install_closure bin/merge-conductor.sh "$CH" >/dev/null ) || bad "PR3W closure install of bin/merge-conductor.sh"
mgt_fresh; : > "$BX/mergify-nochecks"
mgt_runs '101|CI|success' '104|perf|failure'; mgt_jobs 101 'ci|success'; mgt_jobs 104 'ci|success' 'perf-budgets (report only)|failure'
W=$( export PATH="$C/fakebin:$PATH" HARNESS="$CH" GH_TOKEN=pat-fixture JOBS_URL=http://worker.test
  # shellcheck source=/dev/null
  . "$CH/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
  mc_ci_state "$MGT_SLUG" "$MGT_H1" 2>/dev/null )
[ "$W" = green ] && ok || bad "PR3W no required set, a (report only) failure only: mc_ci_state answers green (got '$W')"

[ -z "$(mgt_offhost)" ] && ok || bad "V1 a curl left the fixture hosts: $(mgt_offhost)"
echo "mc-park-ci-recheck.bh-9368: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
