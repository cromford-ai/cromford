#!/bin/bash
# tests/lead-gates-traced-hold.bh-5876-test.sh — BH-5876 (BH-5870.3): gate 10a
# of the enqueue, the traced hold (BH-5795), as the worklist gate
# bin/lib/lead-gates.d/57-traced-hold.sh. Every case drives bin/lead-review.sh
# tick WHOLE over the worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh,
# lead-gates-fixture.bh-5875.sh, lead-gates-fixture.bh-5876.sh).
#   T1  base feat-x (not the default) and no traced runs: held, one dispatch
#       POST (scope=impact on the head ref), the enqueue's marker written.
#   T2  a second tick: no second dispatch, no second `[skip traced]` line.
#   T3  a marker older than LEAD_REVIEW_TRACED_MAX_WAIT_MIN: a job whose meta
#       traced_note is `tests did not run: ...`; a later job carries the same bytes.
#   T4  the check runs answer 500: held.
#   T5  base main: a job, no dispatch.
#   T6  a completed, non-skipped `Tests, traced` run on the head: a job.
#   T7  LEAD_REVIEW_TRACED_WAIT=0: a job.
#   T8  a fork's head: no dispatch, the marker says why.
#   T9  traced notes older than 14 days are deleted; newer ones stay.
#   T10 a low-tier head under rt_mode enforce, base feat-x, no traced runs:
#       held BEFORE 60-risk.sh can sign it off (the enqueue's order: traced
#       hold, then risk tier): no lead-verdict post, one dispatch, one
#       `[skip traced]` line, no job. Red with the gate numbered after 60.
#   M1  57-traced-hold.sh removed: T1 starts a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-traced-hold.bh-5876-test.sh
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
GD="$H/bin/lib/lead-gates.d"
SRC="$LWF_SRC"
for f in bin/lib/lead-gates.d/57-traced-hold.sh bin/lib/lead-gates-knobs.sh; do
  [ -r "$SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not installed"
done
H1=$(printf '%040d' 104); H12=${H1:0:12}
TF="$H/state/lead-review-enqueue/traced-example-org_cromford-104-$H12"
summ() { lwf_summary; }
stacked() { lg6_reset; lgf_needs "104:$H1"; echo feat-x > "$FX/base.104"; echo ticket/bh-104 > "$FX/ref.104"; }

# ── T1: a stacked base with no traced run: held, one dispatch ──
stacked
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "T1 a job on a stacked base with no traced run: $(cat "$L")"
[ "$(lg6_dispatches)" = 1 ] && ok || bad "T1 dispatches=$(lg6_dispatches)"
grep -q 'api -i -X POST repos/example-org/cromford/actions/workflows/harness-ci.yml/dispatches -f ref=ticket/bh-104 -f inputs\[scope\]=impact' "$T/log/gh" \
  && ok || bad "T1 dispatch argv: $(grep dispatches "$T/log/gh")"
[[ "$(head -1 "$TF" 2>/dev/null)" =~ ^[0-9]+$ ]] && ok || bad "T1 marker: $(cat "$TF" 2>/dev/null)"
grep -qx 'dispatch ok harness-ci.yml ticket/bh-104' "$TF" && ok || bad "T1 marker dispatch line: $(cat "$TF")"
grep -qF "[skip traced] example-org/cromford#104 @$H12 not requested: base feat-x is not main and no 'Tests, traced' job ran on this head; waiting for a CI run that tests it (held " "$L" \
  && ok || bad "T1 line: $(grep skip "$L")"
[[ "$(summ)" == *" held=1 "* ]] && ok || bad "T1 summary: $(summ)"

# ── T2: a second tick: no second dispatch, no second line ──
lwf_tick
[ "$(lg6_dispatches)" = 1 ] && ok || bad "T2 dispatches=$(lg6_dispatches)"
[ "$(lg6_skips traced)" = 1 ] && ok || bad "T2 traced lines=$(lg6_skips traced)"

# ── T3: the bound reached: a job with traced_note, the same bytes next time ──
stacked
mkdir -p "${TF%/*}"; printf '%s\ndispatch ok harness-ci.yml ticket/bh-104\n' "$(( $(date +%s) - 3600 ))" > "$TF"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "T3 no job past the bound: $(cat "$L")"
N1=$(lg6_meta 104 traced_note)
[[ "$N1" == "tests did not run: base feat-x is not main and no 'Tests, traced' job ran on this head; waiting for a CI run that tests it (held "*"s, LEAD_REVIEW_TRACED_MAX_WAIT_MIN=30)" ]] \
  && ok || bad "T3 traced_note='$N1'"
[ "$(lg6_dispatches)" = 0 ] && ok || bad "T3 dispatched past the bound"
lwf_tick
[ "$(lgf_jobs 104)" = 2 ] && ok || bad "T3 no second job: jobs=$(lgf_jobs 104)"
[ "$(lg6_meta 104 traced_note)" = "$N1" ] && ok || bad "T3 the second job's note differs: '$(lg6_meta 104 traced_note)'"

# ── T4: the check runs unreadable: held ──
stacked
jq -nc --arg s "$H1" '{verdict:"APPROVE", reviewed_sha:$s, job_id:"job-fixture-1"}' > "$FX/jv.json"
echo on > "$FX/checksfail.$H1"
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "T4 a job on unreadable check runs: $(cat "$L")"
grep -qF "[skip traced] example-org/cromford#104 @$H12 not requested: base feat-x is not main and the check runs are unreadable (check runs unreadable (HTTP 500))" "$L" \
  && ok || bad "T4 line: $(grep skip "$L")"

# ── T5: base main: a job ──
lg6_reset; lgf_needs "104:$H1"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "T5 no job on base main"
[ "$(lg6_dispatches)" = 0 ] && ok || bad "T5 a dispatch on base main"

# ── T6: a traced run completed: a job ──
stacked
jq -nc --arg s "$H1" '{total_count:2, check_runs:[
  {name:"Tests", head_sha:$s, status:"completed", conclusion:"success", app:{slug:"github-actions"}},
  {name:"Tests, traced (shard 1)", head_sha:$s, status:"completed", conclusion:"success", app:{slug:"github-actions"}}]}' > "$FX/checks.$H1"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "T6 no job with a traced run done: $(cat "$L")"
[ "$(lg6_dispatches)" = 0 ] && ok || bad "T6 a dispatch with a traced run done"

# ── T7: the hold off ──
stacked
LEAD_REVIEW_TRACED_WAIT=0 lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "T7 no job with LEAD_REVIEW_TRACED_WAIT=0"

# ── T8: a fork's head: held, no dispatch ──
stacked; echo someone/fork > "$FX/hrepo.104"
lwf_tick
[ "$(lg6_dispatches)" = 0 ] && ok || bad "T8 a dispatch for a fork's head"
grep -qx 'dispatch none: the head lives in someone/fork' "$TF" && ok || bad "T8 marker: $(cat "$TF" 2>/dev/null)"
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "T8 a job"

# ── T9: traced notes older than 14 days are deleted once a tick; newer ones stay ──
lg6_reset; lgf_needs "104:$H1"
G="$H/state/lead-review-gates"; mkdir -p "$G"
echo old > "$G/traced-note-example-org_cromford-7-aaaaaaaaaaaa"; touch -d '2020-01-01 00:00:00' "$G/traced-note-example-org_cromford-7-aaaaaaaaaaaa"
echo new > "$G/traced-note-example-org_cromford-8-bbbbbbbbbbbb"
lwf_tick
[ -e "$G/traced-note-example-org_cromford-7-aaaaaaaaaaaa" ] && bad "T9 an old traced note kept" || ok
[ -e "$G/traced-note-example-org_cromford-8-bbbbbbbbbbbb" ] && ok || bad "T9 a new traced note deleted"

# ── T10: a low-tier head under enforce on a stacked base: held, never signed off ──
LOWF='[["tests/x.bh-1-test.sh","added",3,0,"@@ -0,0 +1,3 @@\n+#!/bin/bash\n+echo ok\n+exit 0"]]'
lg6_reset enforce; lgf_needs "104:$H1"; echo feat-x > "$FX/base.104"; echo ticket/bh-104 > "$FX/ref.104"
lgf_cmp "$H1" "$LOWF"
lwf_tick
[ "$(lgf_signed 104)" = 0 ] && ok || bad "T10 a risk-tier sign-off on an untested stacked head: $(cat "$T/log/lv" 2>/dev/null) :: $(cat "$L")"
[ "$(lg6_dispatches)" = 1 ] && ok || bad "T10 dispatches=$(lg6_dispatches)"
[ "$(lg6_skips traced)" = 1 ] && ok || bad "T10 traced lines=$(lg6_skips traced)"
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "T10 a job on an untested stacked head"
# The control: the same head on base main is signed off by the risk tier.
lg6_reset enforce; lgf_needs "104:$H1"; lgf_cmp "$H1" "$LOWF"
lwf_tick
[ "$(lgf_signed 104)" = 1 ] && ok || bad "T10 control: no risk-tier sign-off on base main: $(cat "$L")"

# ── M1: no traced gate: T1 starts ──
mv "$GD/57-traced-hold.sh" "$T/57.off"
stacked
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "M1 no job with 57-traced-hold.sh gone: $(cat "$L")"
mv "$T/57.off" "$GD/57-traced-hold.sh"

echo "lead-gates-traced-hold.bh-5876: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
