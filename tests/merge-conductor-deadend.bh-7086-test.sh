#!/bin/bash
# tests/merge-conductor-deadend.bh-7086-test.sh — BH-7086: the deadend suite
# must stay green when its detached re-review jobs are slow.
#
# THE RACE. Section 2 of tests/merge-conductor-deadend-test.sh spawns two
# detached re-review jobs (mc_rereview_spawn). Each job rewrites its job file
# when it ends, and mc_rr_write recreates a missing file. reset12 deleted the
# job files without waiting for the jobs, so a job that ended after reset12
# brought its file back and section 3 counted one job file where it wants none
# (FAIL "must buy no review", twice). It showed only on a loaded runner.
#
# THE PROOF. MC_DEADEND_RR_DELAY_S=<n> makes the deadend suite insert
# `sleep <n>` as the first line of mc_rereview_run in its SCRATCH copy, never in
# the repo. Without the drain in reset12, 1 s already fails both checks. This
# suite runs the deadend suite with that delay (BH7086_DELAYS, default 3) and
# asserts rc 0, a `, 0 failed` summary, and no scratch mc_*_run job left alive.
#
# Run from anywhere: bash tests/merge-conductor-deadend.bh-7086-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SUITE="$(cd "$(dirname "$0")" && pwd)/merge-conductor-deadend-test.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The inner suite makes its scratch tree under TMPDIR, so every job it spawns
# carries "$T/tmp/" in its cmdline: that is how the orphan check knows ours.
mkdir -p "$T/tmp"
for d in ${BH7086_DELAYS:-3}; do
  out=$(TMPDIR="$T/tmp" MC_DEADEND_RR_DELAY_S="$d" bash "$SUITE" 2>&1); rc=$?
  [ "$rc" = 0 ] && ok || bad "delay ${d}s: the deadend suite must exit 0 (rc=$rc): $(printf '%s\n' "$out" | grep -E '^FAIL|passed' | tr '\n' '|')"
  grep -qE '^merge-conductor-deadend-test: [0-9]+ passed, 0 failed$' <<<"$out" \
    && ok || bad "delay ${d}s: the summary must say 0 failed (got: $(printf '%s\n' "$out" | tail -1))"
done

if command -v pgrep >/dev/null; then
  left=
  for p in $(pgrep -f 'mc_(rereview|rebase|dv)_run'); do
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    grep -qF "$T/tmp/" <<<"$c" && left="$left $p"
  done
  [ -z "$left" ] && ok || bad "no scratch mc_*_run job may outlive the suite (pids:$left)"
fi

echo "merge-conductor-deadend.bh-7086-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
