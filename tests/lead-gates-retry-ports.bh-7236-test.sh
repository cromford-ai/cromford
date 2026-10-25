#!/bin/bash
# tests/lead-gates-retry-ports.bh-7236-test.sh — the bounded retry of a failed
# lead review on the worklist (bin/lib/lead-gates.d/95-retry-reclaim.sh, with
# 90-caps.sh in front of it). bin/lead-review.sh tick runs WHOLE over
# tests/lib/lead-worklist-fixture.bh-4956.sh, lead-gates-fixture.bh-5875.sh and
# lead-gates-fixture.bh-5876.sh.
#   F2  one `reset` row already in failed-retry.tsv and the row failed again:
#       one reset POST, two `reset` rows, a `reset 2/2` line, one job.
#   F6  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 and two failed heads: one reset (the
#       first head), one `[skip deferred]` line, no reset for the second head.
#   F9  LEAD_REVIEW_FAILED_RETRY_MAX=0: no reset, no job, one lead-failed alert
#       that says `failed 1 times`, one `[skip failed-exhausted]` line.
#   F10 a failed detail with a URL credential and a GitHub token: the reset line
#       and the alert carry `://***@` and neither the credential nor the token.
#   M1  a gate copy whose _lgr_redact masks nothing: F10 goes red (D1).
#   M2  a gate copy that counts no `reset` row: F2 goes red (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-retry-ports.bh-7236-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
lg6_setup
GATE="$H/bin/lib/lead-gates.d/95-retry-reclaim.sh"
[ -r "$GATE" ] && [ -r "$H/bin/lib/lead-gates.d/90-caps.sh" ] && ok || bad "setup: 90-caps.sh or 95-retry-reclaim.sh not installed"
cp "$GATE" "$T/95.orig"
BHR=example-org/cromford
H1=$(printf '%040d' 101); H12=${H1:0:12}
H2=$(printf '%040d' 102)
FR="$H/state/lead-review-enqueue/failed-retry.tsv"
ALID="lead-failed-example-org_cromford-101-$H12"
CRED=fixturepass; TOK=ghs_FIXTUREfixture0123456789ab
LEAK="clone https://bot:$CRED@github.com/example-org/cromford.git failed; token $TOK"
# failed <pr>:<head>:<detail>... — one failed lead review row r-f<pr> per head
failed() {
  local a pr h dt out='[]'
  for a in "$@"; do
    pr="${a%%:*}"; a="${a#*:}"; h="${a%%:*}"; dt="${a#*:}"
    out=$(jq -c --argjson n "$pr" --arg h "$h" --arg d "$dt" '. + [{id:("r-f" + ($n|tostring)), repo:"example-org/cromford",
      pr:$n, head_sha:$h, status:"failed", detail:$d, created_at:"2026-10-10 03:00:00"}]' <<<"$out")
  done
  printf '%s\n' "$out" > "$FX/failed.json"
}
rows() { awk -F'\t' -v k="$1" '$6 == k' "$FR" 2>/dev/null | wc -l | tr -d ' '; }
alerts() { grep -- "--id $ALID " "$T/log/lane-alert" 2>/dev/null; }

# f2 — one reset already spent on the head; the row failed again
f2() {
  lg6_reset; lgf_needs "101:$H1"; failed "101:$H1:review-failed: timeout"
  mkdir -p "${FR%/*}"
  printf '%s\t%s\t%s\t%s\t%s\treset\t%s\n' "$(( $(date +%s) - 600 ))" "$BHR" 101 "$H1" r-f101 "review-failed: timeout" > "$FR"
  lwf_tick
}
f2_ok() {
  [ "$(lg6_resets)" = 1 ] && [ "$(rows reset)" = 2 ] && [ "$(lgf_jobs 101)" = 1 ] \
    && [ "$(lwf_cnt "$BHR#101 @$H12: lead review r-f101 failed (review-failed: timeout); reset 2/2 for a new review" "$L")" = 1 ]
}
# f10 — the leaky detail, once under budget (a reset line), once at max 0 (an alert)
f10() {
  lg6_reset; lgf_needs "101:$H1"; failed "101:$H1:$LEAK"; lwf_tick
  cp "$L" "$T/f10.log"
  lg6_reset; lgf_needs "101:$H1"; failed "101:$H1:$LEAK"; LEAD_REVIEW_FAILED_RETRY_MAX=0 lwf_tick
  cat "$L" >> "$T/f10.log"
}
f10_ok() {
  local s
  for s in "$CRED" "$TOK" ghs_FIXTURE tok-fixture-lead; do
    grep -qF -- "$s" "$T/f10.log" && return 1
    alerts | grep -qF -- "$s" && return 1
  done
  grep -qF "reset 1/2 for a new review" "$T/f10.log" || return 1
  grep -qF '://***@' "$T/f10.log" && alerts | grep -qF '://***@'
}

# ── F2: the second reset of a head ──
f2
[ "$RC" = 0 ] && ok || bad "F2 rc=$RC: $(cat "$T/out")"
[ "$(lg6_resets)" = 1 ] && ok || bad "F2 resets=$(lg6_resets) (want 1)"
grep -q '^POST /api/lead-reviews/r-f101/reset ' "$T/log/worker" && ok || bad "F2 not the row's reset"
[ "$(rows reset)" = 2 ] && ok || bad "F2 reset rows=$(rows reset): $(cat "$FR")"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "F2 jobs=$(lgf_jobs 101) after the reset"
[ "$(lwf_cnt "$BHR#101 @$H12: lead review r-f101 failed (review-failed: timeout); reset 2/2 for a new review" "$L")" = 1 ] \
  && ok || bad "F2 no reset 2/2 line: $(cat "$L")"
[ "$(lg6_skips failed-exhausted)" = 0 ] && ok || bad "F2 a failed-exhausted line with one reset spent"
f2_ok && ok || bad "F2 f2_ok"

# ── F6: the per-tick cap runs before the retry ──
lg6_reset; lgf_needs "101:$H1" "102:$H2"
failed "101:$H1:review-failed: timeout" "102:$H2:review-failed: timeout"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 lwf_tick
[ "$(lg6_resets)" = 1 ] && ok || bad "F6 resets=$(lg6_resets) under cap 1: $(grep reset "$T/log/worker")"
grep -q '^POST /api/lead-reviews/r-f101/reset ' "$T/log/worker" && ok || bad "F6 the first head was not reset"
[ "$(lwf_cnt '^POST /api/lead-reviews/r-f102/reset ' "$T/log/worker")" = 0 ] && ok || bad "F6 the deferred head was reset"
[ "$(lg6_skips deferred)" = 1 ] && ok || bad "F6 deferred lines=$(lg6_skips deferred): $(cat "$L")"
[ "$(lwf_cnt "\\[skip deferred\\] $BHR#102 @${H2:0:12} " "$L")" = 1 ] && ok || bad "F6 the deferred line does not name #102: $(grep skip "$L")"
[ "$(rows reset)" = 1 ] && ok || bad "F6 reset rows=$(rows reset)"

# ── F9: max 0: the first failure alerts ──
lg6_reset; lgf_needs "101:$H1"; failed "101:$H1:review-failed: timeout"
LEAD_REVIEW_FAILED_RETRY_MAX=0 lwf_tick
[ "$(lg6_resets)" = 0 ] && ok || bad "F9 resets=$(lg6_resets) at max 0"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "F9 a job at max 0"
[ "$(alerts | wc -l | tr -d ' ')" = 1 ] && ok || bad "F9 alerts: $(cat "$T/log/lane-alert" 2>/dev/null)"
alerts | grep -q -- '--severity warn ' && ok || bad "F9 the alert is not warn: $(alerts)"
alerts | grep -qF 'failed 1 times on this head' && ok || bad "F9 the alert lacks 'failed 1 times': $(alerts)"
[ "$(lg6_skips failed-exhausted)" = 1 ] && ok || bad "F9 failed-exhausted lines=$(lg6_skips failed-exhausted)"
[ "$(rows alerted)" = 1 ] && [ "$(rows reset)" = 0 ] && ok || bad "F9 ledger: $(cat "$FR" 2>/dev/null)"

# ── F10: credentials and tokens are masked in the log and the alert ──
f10
[ "$(lwf_cnt "reset 1/2 for a new review" "$T/f10.log")" = 1 ] && ok || bad "F10 the reset did not run: $(cat "$T/f10.log")"
[ "$(alerts | wc -l | tr -d ' ')" = 1 ] && ok || bad "F10 no alert to check: $(cat "$T/log/lane-alert" 2>/dev/null)"
for s in "$CRED" "$TOK" ghs_FIXTURE tok-fixture-lead; do
  grep -qF -- "$s" "$T/f10.log" && bad "F10 $s reached the log: $(grep -F -- "$s" "$T/f10.log")" || ok
  grep -qF -- "$s" <<<"$(alerts)" && bad "F10 $s reached the alert: $(alerts)" || ok
done
grep -qF '://***@' "$T/f10.log" && ok || bad "F10 the URL credential is not masked in the log: $(cat "$T/f10.log")"
alerts | grep -qF '://***@' && ok || bad "F10 the URL credential is not masked in the alert: $(alerts)"
alerts | grep -qF 'gh*_***' && ok || bad "F10 the token is not masked in the alert: $(alerts)"

# mutate <sed expr> — the scratch gate from the original, then the mutation; rc 0 when it changed
mutate() {
  cp "$T/95.orig" "$GATE"
  sed -i "$1" "$GATE"
  ! cmp -s "$GATE" "$T/95.orig"
}

# ── M1: a redact that masks nothing: F10 goes red ──
if mutate 's/^_lgr_redact() { sed -E .*/_lgr_redact() { cat; }/'; then
  f10; f10_ok && bad "M1 F10 stayed green with no redact" || ok
else bad "M1 the mutation did not change the gate"; fi

# ── M2: no reset row counted: F2 goes red ──
if mutate 's/\$6 == "reset"/$6 == "fixture-none"/'; then
  f2; f2_ok && bad "M2 F2 stayed green with no reset counted" || ok
else bad "M2 the mutation did not change the gate"; fi
cp "$T/95.orig" "$GATE"

echo "lead-gates-retry-ports.bh-7236: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
