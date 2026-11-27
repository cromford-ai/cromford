#!/bin/bash
# tests/prr-shadow.bh-9933-test.sh — BH-9933 (BH-9926.1): bin/lib/prr-shadow.sh,
# the shared "record first, compare with GitHub, log PRR_SHADOW" helper, and
# the seam files of the lanes waves 5 and 6 move.
#
# What is pinned:
#   step     prr_step reads GH_SOURCE (the settings row lane.<id>.gh_source as
#            lane_env_apply exports it), then setting_get, then `shadow`; any
#            other value is shadow plus one PRR_STEP line.
#   read     with stub record/github functions that log each call:
#            off = github only; shadow = both, 0 PRR_SHADOW lines on a match and
#            exactly 1 on a mismatch, the out file holds the GitHub value;
#            record = 0 github calls on a hit; a record miss reads GitHub and
#            logs PRR_MISS fallback=github.
#   neg      shadow + a record miss: PRR_MISS fallback=none, no PRR_SHADOW;
#            shadow + a GitHub failure: no PRR_SHADOW, rc = GitHub's rc.
#   compare  the real tsp_open_norm: order, `up` and `url` do not count; a PR
#            only on one side, a changed head ref or title does.
#   seams    each seam file a wave has not filled yet exists, parses, defines
#            no function, and prr_seam_load loads it; a filled seam defines its
#            functions; an unknown lane is rc 1.
#   registry the built lanes registry carries GH_SOURCE on tickets-snapshot-push
#            with default `shadow`, read in bin/lib/prr-shadow.sh.
# Run from anywhere: bash tests/prr-shadow.bh-9933-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/prr-shadow.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }

export HARNESS="$T/h"; mkdir -p "$HARNESS/logs" "$T/tmp"
export TMPDIR="$T/tmp"
unset GH_SOURCE H
# shellcheck source=bin/lib/prr-shadow.sh
. "$LIB" || { echo "FAIL: $LIB did not source"; exit 1; }
LOG="$HARNESS/logs/prr-shadow.log"
nlines() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }

# ---- step ----------------------------------------------------------------------
step_case() { # step_case <value|UNSET> <want> <want PRR_STEP lines>
  : > "$LOG"
  local got
  if [ "$1" = UNSET ]; then got=$(unset GH_SOURCE; prr_step lane-a)
  else got=$(GH_SOURCE="$1" prr_step lane-a); fi
  [ "$got" = "$2" ] && ok || bad "step: GH_SOURCE='$1' want $2 got '$got'"
  [ "$(nlines 'PRR_STEP lane=lane-a')" = "$3" ] && ok || bad "step: GH_SOURCE='$1' want $3 PRR_STEP line(s): $(cat "$LOG")"
}
step_case off off 0
step_case shadow shadow 0
step_case record record 0
step_case UNSET shadow 0
step_case '' shadow 0
step_case Record shadow 1
step_case 'record ' shadow 1
step_case on shadow 1
step_case 0 shadow 1
# setting_get is the second source, keyed lane.<id>.gh_source.
setting_get() { printf '%s\n' "$1" >> "$T/sg.txt"; [ "$1" = lane.lane-b.gh_source ] && { printf record; return 0; }; return 2; }
got=$(unset GH_SOURCE; prr_step lane-b)
[ "$got" = record ] && ok || bad "step: setting_get row lane.lane-b.gh_source=record must give record, got '$got'"
grep -qx 'lane.lane-b.gh_source' "$T/sg.txt" && ok || bad "step: setting_get must be asked for lane.lane-b.gh_source: $(cat "$T/sg.txt" 2>/dev/null)"
got=$(GH_SOURCE=off prr_step lane-b)
[ "$got" = off ] && ok || bad "step: GH_SOURCE wins over setting_get, got '$got'"
got=$(unset GH_SOURCE; prr_step lane-c)
[ "$got" = shadow ] && ok || bad "step: no row (rc 2) gives the shadow fallback, got '$got'"
unset -f setting_get

# ---- read ------------------------------------------------------------------------
# Stubs: each logs its name; REC_OUT / GH_OUT are the JSON they write, REC_RC /
# GH_RC their rc. A record miss prints its miss word.
CALLS="$T/calls.txt"
rec_fn() { echo "record ${2:-}" >> "$CALLS"; [ "${REC_RC:-0}" = 0 ] || { echo "${REC_WHY:-stale}"; return "$REC_RC"; }; printf '%s' "$REC_OUT" > "$1"; }
gh_fn()  { echo "github ${2:-}" >> "$CALLS"; printf '%s' "$GH_OUT" > "$1"; return "${GH_RC:-0}"; }
norm_fn() { jq -c '[.[] | {n, t}] | sort_by(.n)' "$1"; }
calls() { grep -c "^$1 " "$CALLS" 2>/dev/null || true; }
read_case() { # read_case <step> -> RC, OUTV
  : > "$CALLS"; : > "$LOG"; rm -f "$T/out.json"
  GH_SOURCE="$1" prr_read lane-a 'A/x#open' "$T/out.json" rec_fn gh_fn norm_fn arg1 >/dev/null; RC=$?
  OUTV=$(cat "$T/out.json" 2>/dev/null)
}
A1='[{"n":1,"t":"one"},{"n":2,"t":"two"}]'
A2='[{"n":2,"t":"two"},{"n":1,"t":"one"}]'
B1='[{"n":1,"t":"one"}]'

REC_OUT="$A1"; GH_OUT="$A1"; REC_RC=0; GH_RC=0
read_case off
[ "$RC" = 0 ] && [ "$(calls github)" = 1 ] && [ "$(calls record)" = 0 ] && ok || bad "read off: rc $RC github $(calls github) record $(calls record)"
[ "$OUTV" = "$A1" ] && ok || bad "read off: out file must hold the GitHub value, got '$OUTV'"
grep -q 'github arg1' "$CALLS" && ok || bad "read: the extra args reach the fn: $(cat "$CALLS")"

REC_OUT="$A2"; GH_OUT="$A1"
read_case shadow
[ "$RC" = 0 ] && [ "$(calls github)" = 1 ] && [ "$(calls record)" = 1 ] && ok || bad "read shadow match: rc $RC github $(calls github) record $(calls record)"
[ "$(nlines PRR_SHADOW)" = 0 ] && ok || bad "read shadow match (order only): 0 PRR_SHADOW lines, got: $(cat "$LOG")"

REC_OUT="$B1"; GH_OUT="$A1"
read_case shadow
[ "$(calls github)" = 1 ] && [ "$(calls record)" = 1 ] && ok || bad "read shadow mismatch: github $(calls github) record $(calls record)"
[ "$(nlines 'PRR_SHADOW lane=lane-a key=A/x#open')" = 1 ] && [ "$(wc -l < "$LOG" | tr -d ' ')" = 1 ] && ok \
  || bad "read shadow mismatch: exactly 1 PRR_SHADOW line naming lane and key: $(cat "$LOG")"
grep -q 'record=1 github=2 only_record=0 only_github=1 changed=0' "$LOG" && ok || bad "read shadow mismatch: counts: $(cat "$LOG")"
[ "$OUTV" = "$A1" ] && ok || bad "read shadow: the lane acts on the GitHub value, got '$OUTV'"

REC_OUT='[{"n":1,"t":"ONE"},{"n":2,"t":"two"}]'; GH_OUT="$A1"
read_case shadow
grep -q 'only_record=0 only_github=0 changed=1' "$LOG" && ok || bad "read shadow changed title: $(cat "$LOG")"

REC_OUT="$B1"; GH_OUT="$A1"
read_case record
[ "$RC" = 0 ] && [ "$(calls github)" = 0 ] && [ "$(calls record)" = 1 ] && ok || bad "read record hit: rc $RC github $(calls github) record $(calls record)"
[ "$OUTV" = "$B1" ] && ok || bad "read record hit: out file holds the record value, got '$OUTV'"
[ ! -s "$LOG" ] && ok || bad "read record hit: no log line, got: $(cat "$LOG")"
PS=$(GH_SOURCE=record; prr_read lane-a k "$T/o2.json" rec_fn gh_fn norm_fn >/dev/null; echo "$PRR_SOURCE")
[ "$PS" = record ] && ok || bad "read record hit: PRR_SOURCE=record, got '$PS'"

REC_RC=1; REC_WHY=stale
read_case record
[ "$RC" = 0 ] && [ "$(calls github)" = 1 ] && ok || bad "read record miss: falls back to GitHub (rc $RC github $(calls github))"
[ "$(nlines 'PRR_MISS lane=lane-a key=A/x#open why=stale fallback=github')" = 1 ] && ok || bad "read record miss: PRR_MISS fallback=github: $(cat "$LOG")"
[ "$OUTV" = "$A1" ] && ok || bad "read record miss: out file holds the GitHub value, got '$OUTV'"

# ---- neg -------------------------------------------------------------------------
REC_RC=1; REC_WHY=no-sync
read_case shadow
[ "$(nlines PRR_SHADOW)" = 0 ] && ok || bad "neg: a record miss must not log PRR_SHADOW: $(cat "$LOG")"
[ "$(nlines 'PRR_MISS lane=lane-a key=A/x#open why=no-sync fallback=none')" = 1 ] && ok || bad "neg: shadow miss logs PRR_MISS fallback=none: $(cat "$LOG")"
[ "$RC" = 0 ] && [ "$OUTV" = "$A1" ] && ok || bad "neg: shadow miss still serves GitHub (rc $RC, '$OUTV')"
REC_RC=0; REC_OUT="$B1"; GH_RC=75
read_case shadow
[ "$RC" = 75 ] && ok || bad "neg: shadow + GitHub failure returns GitHub's rc 75, got $RC"
[ "$(nlines PRR_SHADOW)" = 0 ] && ok || bad "neg: a GitHub failure must not log PRR_SHADOW: $(cat "$LOG")"
GH_RC=75; read_case off
[ "$RC" = 75 ] && ok || bad "neg: off returns GitHub's rc, got $RC"
GH_RC=0
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "neg: prr_read left temp files: $(ls -A "$T/tmp")"

# ---- compare (the real tsp_open_norm) ------------------------------------------
prr_seam_load tickets-snapshot-push && ok || bad "compare: prr_seam_load tickets-snapshot-push must succeed"
if command -v tsp_open_norm >/dev/null 2>&1; then
  BASEP='[{"n":1,"br":"ticket/a-1","by":"u1","up":"2026-11-01T00:00:00Z","url":"https://github.com/A/x/pull/1","t":"one"},{"n":2,"br":"ticket/a-2","by":"u2","up":"2026-11-02T00:00:00Z","url":"https://github.com/A/x/pull/2","t":"two"}]'
  printf '%s' "$BASEP" > "$T/base.json"
  cmp_case() { # cmp_case <name> <jq on base> <equal|differ>
    jq -c "$2" "$T/base.json" > "$T/other.json"
    local a b; a=$(tsp_open_norm "$T/base.json"); b=$(tsp_open_norm "$T/other.json")
    if [ "$3" = equal ]; then [ "$a" = "$b" ] && ok || bad "compare $1: must be equal ($a vs $b)"
    else [ -n "$a" ] && [ "$a" != "$b" ] && ok || bad "compare $1: must differ ($a vs $b)"; fi
  }
  cmp_case order 'reverse' equal
  cmp_case up '.[0].up = "2026-11-09T00:00:00Z"' equal
  cmp_case url '.[0].url = "https://example.invalid/1"' equal
  cmp_case only-github '[.[0]]' differ
  cmp_case only-record '. + [{"n":3,"br":"b","by":"u","up":"","url":"","t":"three"}]' differ
  cmp_case branch '.[0].br = "ticket/other"' differ
  cmp_case title '.[0].t = "renamed"' differ
  cmp_case empty '[]' differ
else
  bad "compare: tsp_open_norm is not defined after prr_seam_load"
fi

# ---- seams -------------------------------------------------------------------------
# merge-conductor left this list in BH-9936 (wave 4): its seam now defines the
# CI read's three functions, pinned below and in tests/prr-ci-state.bh-9936-test.sh.
# pr-state-reconcile and main-red-pr-pair left it in BH-9937 (wave 5): their
# seams now define the record and norm functions, pinned below and in
# tests/pr-state-reconcile-record.bh-9937-test.sh and
# tests/main-red-pr-pair-record.bh-9937-test.sh.
# unblock left it in BH-10158 (wave 5, slice C2): its seam now defines the
# record and norm functions, pinned below and in
# tests/unblock-prr-seam.bh-10158-test.sh.
# pipeline-health, dequeue-watch and wake-loop left it in BH-9938 (wave 6):
# their seams define the functions pinned in the BH-9938 loop below.
# blocked-resolver left it in BH-10157 (BH-9937 C1): its seam defines the brs_*
# functions, pinned below and in tests/br-record-discovery.bh-10157-test.sh.
# No lane is left with an empty seam, so the empty-seam loop is gone.
f="$DIR/bin/lib/prr-shadow.d/merge-conductor.sh"
bash -n "$f" && ok || bad "seams: $f does not parse"
grep -q "^# .*merge-conductor" "$f" && ok || bad "seams: $f header must name the lane merge-conductor"
prr_seam_load merge-conductor && ok || bad "seams: prr_seam_load merge-conductor must return 0"
# BH-9938 C1 (wave 6, slice C1): the open-list, external-list and flake reads.
for fn in mc_ci_record mc_ci_github mc_ci_norm mc_open_record mc_open_github mc_open_norm \
          mc_xe_record mc_xe_github mc_flake_record mc_flake_github mc_flake_norm; do
  command -v "$fn" >/dev/null 2>&1 && ok || bad "seams: loading merge-conductor must define $fn"
done
for l in pr-state-reconcile main-red-pr-pair unblock blocked-resolver; do
  f="$DIR/bin/lib/prr-shadow.d/$l.sh"
  bash -n "$f" && ok || bad "seams: $f does not parse"
  grep -q "^# .*$l" "$f" && ok || bad "seams: $f header must name the lane $l"
  prr_seam_load "$l" && ok || bad "seams: prr_seam_load $l must return 0"
done
for fn in psr_list_record psr_list_norm psr_state_record psr_state_norm mrp_list_record mrp_list_norm \
          ub_open_record ub_open_norm ub_pull_record ub_pull_norm ub_branch_record ub_branch_norm \
          ub_cr_record ub_cr_norm ub_ci_record ub_ci_norm \
          brs_open_record brs_open_norm brs_state_record brs_state_norm; do
  command -v "$fn" >/dev/null 2>&1 && ok || bad "seams: the wave 5 seams must define $fn"
done
# BH-9938 (wave 6): three more seams load and define their record, github and
# norm functions (the lanes' suites: dequeue-watch-record, pipeline-health-record
# and wake-pr-lead-record .bh-9938).
for spec in "dequeue-watch:dqw_labels_record dqw_labels_github dqw_labels_norm dqw_payload_record dqw_payload_github dqw_payload_norm dqw_status_record dqw_status_github dqw_status_norm" \
            "pipeline-health:ph_open_record ph_open_github ph_open_norm ph_sdl_record ph_sdl_github ph_sdl_norm ph_payload_record ph_payload_github ph_payload_norm ph_hct_record ph_hct_github ph_hct_norm ph_status_record ph_status_github ph_status_norm" \
            "wake-loop:wl_pr_record wl_pr_github wl_pr_norm"; do
  # sl, not l: an assignment to l would unbind the literal loops above for
  # bin/test-impact.sh (bin/lib/test-impact-dir-rows.sh, BOUND), and the seams
  # they name would read as orphans.
  sl=${spec%%:*}
  f="$DIR/bin/lib/prr-shadow.d/$sl.sh"
  bash -n "$f" && ok || bad "seams: $f does not parse"
  grep -q "^# .*$sl" "$f" && ok || bad "seams: $f header must name the lane $sl"
  grep -q 'Empty until' "$f" && bad "seams: $f header still says it is empty" || ok
  prr_seam_load "$sl" && ok || bad "seams: prr_seam_load $sl must return 0"
  for fn in ${spec#*:}; do
    declare -F "$fn" >/dev/null && ok || bad "seams: loading $sl must define $fn"
  done
done
prr_seam_load no-such-lane && bad "seams: an unknown lane must return 1" || ok

# ---- registry ------------------------------------------------------------------------
REG="$T/lanes.json"
if "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1; then
  K=$(jq -c '.lanes[] | select(.id=="tickets-snapshot-push") | .knobs[] | select(.env=="GH_SOURCE") | {default, read_in}' "$REG" 2>/dev/null)
  [ "$K" = '{"default":"shadow","read_in":"bin/lib/prr-shadow.sh"}' ] && ok || bad "registry: GH_SOURCE on tickets-snapshot-push, default shadow (got '$K')"
  for l in dequeue-watch pipeline-health wake-loop; do
    K=$(jq -c --arg l "$l" '.lanes[] | select(.id==$l) | .knobs[] | select(.env=="GH_SOURCE") | {default, read_in}' "$REG" 2>/dev/null)
    [ "$K" = '{"default":"shadow","read_in":"bin/lib/prr-shadow.sh"}' ] && ok || bad "registry: GH_SOURCE on $l, default shadow (got '$K')"
  done
  K2=$(jq -c '.lanes[] | select(.id=="tickets-snapshot-push") | .knobs[] | select(.env=="TICKETS_SNAPSHOT_OPEN_PR_LIMIT") | {default, max}' "$REG" 2>/dev/null)
  [ "$K2" = '{"default":100,"max":100}' ] && ok || bad "registry: TICKETS_SNAPSHOT_OPEN_PR_LIMIT default 100 max 100 (got '$K2')"
else
  bad "registry: lanes-build.sh did not render"
fi

echo "prr-shadow.bh-9933: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
