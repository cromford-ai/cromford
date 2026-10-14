#!/bin/bash
# tests/lead-gates-body-lint.bh-5876-test.sh — BH-5876 (BH-5870.3): gate 8 of
# the enqueue, the PR-body section lint (BH-5790, the body-* rules of
# catalog/pr-self-check.tsv), as the worklist gate
# bin/lib/lead-gates.d/78-body-lint.sh. Every case drives bin/lead-review.sh
# tick WHOLE over the worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh,
# lead-gates-fixture.bh-5875.sh, lead-gates-fixture.bh-5876.sh) on a real head.
#   B1  no `## Why`: held, ONE comment naming body-why, no job.
#   B2  a complete body: a job.
#   B3  a note rule fires (body-mutation: the head adds a test suite and the
#       body shows no mutation evidence): a job whose meta self_check_notes is
#       `self-check notes: body-mutation: ...`; the next job of the head
#       carries byte-identical meta.
#   B4  the linked issue's Done when names a probe and the body shows none:
#       held, naming body-live-probe; the issue is read once a tick.
#   M1  78-body-lint.sh removed: B1 gets a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-body-lint.bh-5876-test.sh
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
for f in bin/lib/lead-gates.d/78-body-lint.sh bin/lib/lead-gates-knobs.sh; do
  [ -r "$SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not installed"
done
HB=$(lg6_head 104 b/new.txt "a new file") || bad "setup: head"
HT=$(lg6_head 105 tests/b3.bh-5876-test.sh "echo b3") || bad "setup: the test head"
NOWHY=$'## Acceptance tests\nEvery case drives the tick whole and reads the log.\n'
summ() { lwf_summary; }
# one <pr> <head> <body> — the worklist head with <body>, the catalog in
one() { lg6_reset; lgf_needs "$1:$2"; printf '%s' "$3" > "$FX/body.$1"; lg6_catalog; }

# ── B1: no Why: held, one comment ──
one 104 "$HB" "$NOWHY"
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "B1 a job with no Why: $(cat "$L")"
[ "$(lg6_comments 104)" = 1 ] && ok || bad "B1 comments=$(lg6_comments 104)"
grep -q '^- body-why: ' "$T/log/comments.104" && ok || bad "B1 the comment: $(cat "$T/log/comments.104" 2>/dev/null)"
[ "$(lg6_skips selfcheck)" = 1 ] && ok || bad "B1 selfcheck lines=$(lg6_skips selfcheck)"
[[ "$(summ)" == *" held=1 "* ]] && ok || bad "B1 summary: $(summ)"

# ── B2: a complete body: a job ──
one 104 "$HB" "$LG6_BODY"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "B2 no job on a complete body: $(cat "$L")"

# ── B3: a note rule: the note rides in the job meta, the same on every job ──
one 105 "$HT" "$LG6_BODY"
lwf_tick
[ "$(lgf_jobs 105)" = 1 ] && ok || bad "B3 no job: $(cat "$L")"
M1V=$(lg6_meta 105 self_check_notes)
[[ "$M1V" == "self-check notes: body-mutation: "* ]] && ok || bad "B3 self_check_notes='$M1V'"
[ "$(lg6_comments 105)" = 0 ] && ok || bad "B3 a comment for a note rule"
lwf_tick
[ "$(lgf_jobs 105)" = 2 ] && ok || bad "B3 no second job: jobs=$(lgf_jobs 105)"
M2V=$(grep "^POST /api/jobs .*\"ticket_id\":\"lr-105-" "$T/log/worker" | head -1 | sed 's#^POST /api/jobs ##' | jq -r '.meta')
M3V=$(grep "^POST /api/jobs .*\"ticket_id\":\"lr-105-" "$T/log/worker" | tail -1 | sed 's#^POST /api/jobs ##' | jq -r '.meta')
[ -n "$M2V" ] && [ "$M2V" = "$M3V" ] && ok || bad "B3 the two jobs' meta differ: '$M2V' vs '$M3V'"

# ── B4: the ticket names a probe, the body shows none ──
one 104 "$HB" "Refs #9

$LG6_BODY"
printf '## Done when\nThe live probe answers rc=0 on prod.\n' > "$FX/issue.9"
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "B4 a job with no probe: $(cat "$L")"
grep -q '^- body-live-probe: ' "$T/log/comments.104" && ok || bad "B4 the comment: $(cat "$T/log/comments.104" 2>/dev/null)"
[ "$(lwf_cnt 'GET repos/example-org/cromford/issues/9' "$T/log/gh")" = 1 ] && ok || bad "B4 issue reads=$(lwf_cnt 'issues/9' "$T/log/gh")"

# ── M1: no body-lint gate: B1 gets a job ──
mv "$GD/78-body-lint.sh" "$T/78.off"
one 104 "$HB" "$NOWHY"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "M1 no job with 78-body-lint.sh gone: $(cat "$L")"
mv "$T/78.off" "$GD/78-body-lint.sh"

echo "lead-gates-body-lint.bh-5876: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
