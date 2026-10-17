#!/bin/bash
# tests/lead-gates-notes.bh-5878-test.sh — BH-5878: a worklist start carries
# the gates' notes. review_one composes them from the gate fields
# (lg_scope_notes, bin/lib/lead-gates.sh) in the enqueue's order and sends them
# as scope_notes on POST /api/lead-reviews/start (lr_start's 6th argument), so
# the delta, re-review, intent, silence, self-check, traced and step-done
# readers in bin/lead-review.sh see them with no enqueue request row. Every
# case drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh + the 5875, 5876 and 5878 layers).
#   N1  a real head with a delta class, a prior lead MERGE, a dup note,
#       self-check notes and a traced note, tier medium: the /start notes are
#       the groups in order, a `review-tier:` word inside a group is rewritten
#       to `review-tier=`, the tokens are last, and review_one enters delta
#       mode on them (`delta review from <G12>`).
#   N2  no gate fields: the notes are `auto: builder APPROVE on <sha12>`.
#   N3  /start answers 500: the job is failed, no agent call, and the request
#       body still carried the notes.
#   N4  a re-review whose own-files list is over 4000 chars: lpv_fit turns the
#       list into its count (`own-files:+<n>`), the notes fit, tokens last.
#   M1  a mutation: lr_start without its 6th argument sends no scope_notes.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-notes.bh-5878-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5878.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
lg6_setup
lg8_setup

G=$(printf 'd%.0s' {1..40}); G12=${G:0:12}
ST="$H/state/lead-review-enqueue"; GS="$H/state/lead-review-gates"
MEDF='[["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
LDMAX=$(cd "$T" && HARNESS="$H" bash -c '. "$HARNESS/bin/lib/lead-delta.sh"; ld_knob LEAD_DELTA_REVIEW_MAX_LINES') || LDMAX=""
[ -n "$LDMAX" ] && ok || bad "setup: LEAD_DELTA_REVIEW_MAX_LINES unresolved in the scratch harness"
safe=example-org_cromford
prior() { # prior <sha> — a lead MERGE on an earlier head of PR 101
  jq -nc --arg g "$1" '{rows:[{id:7, source:"lead", head_sha:$g, verdict:"MERGE", note:"", created_at:"2026-10-15T09:00:00Z"}], truncated:false}' > "$FX/verdicts.json"
}
cls() { mkdir -p "$ST"; printf '%s\texample-org/cromford\t101\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$LDMAX" "$3" >> "$ST/delta.tsv"; }

# ── N1: every group, in order, and delta mode ──
lg6_reset shadow
HR=$(lg6_head 101 lib/n1.txt "n1 head") || bad "N1 setup: no head"; R12=${HR:0:12}
lgf_needs "101:$HR"; lgf_cmp "$HR" "$MEDF"; lg8_bv 101 APPROVE "$HR" 2026-10-15T10:00:00Z
prior "$G"; cls "$G" "$HR" "delta 5 $LDMAX 1"
mkdir -p "$ST" "$GS"
printf 'self-check notes: body names review-tier:low' > "$ST/selfcheck-notes-$safe-101-$R12"
printf 'tests did not run: fixture reason' > "$GS/traced-note-$safe-101-$R12"
printf 'possible duplicate of 0123456789ab (lib/x.sh)' > "$GS/dup-$safe-101-$R12"
lwf_tick
N1=$(lg8_notes 101)
want="auto: builder APPROVE on $R12; lead-delta:$G lines:5/$LDMAX files:1; possible duplicate of 0123456789ab (lib/x.sh); lead-prev:$G word:MERGE report:state/lead-reviews/lr-101-$G12.md own-commits:? own-files:? main-files:?; self-check notes: body names review-tier=low; tests did not run: fixture reason; review-tier:medium review-mode:full"
[ "$N1" = "$want" ] && ok || bad "N1 notes:
 got  $N1
 want $want"
grep -q "lr-101-$R12: delta review from $G12" "$L" && ok || bad "N1 review_one did not read the delta note: $(grep -i delta "$L")"
[ "$(lg6_meta 101 delta_note)" = "lead-delta:$G lines:5/$LDMAX files:1" ] && ok || bad "N1 job meta delta_note=$(lg6_meta 101 delta_note)"

# ── N2: no fields: the auto line alone ──
lg6_reset
HA=$(printf '%040d' 101)
lgf_needs "101:$HA"; lg8_bv 101 APPROVE "$HA" 2026-10-15T10:00:00Z
lwf_tick
[ "$(lg8_notes 101)" = "auto: builder APPROVE on ${HA:0:12}" ] && ok || bad "N2 notes: $(lg8_notes 101)"

# ── N3: /start fails: the job fails, nothing is reviewed ──
lg6_reset
lgf_needs "101:$HA"; lg8_bv 101 APPROVE "$HA" 2026-10-15T10:00:00Z; : > "$FX/start.fail"
lwf_tick
[ "$(lg8_starts 101)" = 1 ] && ok || bad "N3 /start bodies=$(lg8_starts 101)"
[ "$(lg8_notes 101)" = "auto: builder APPROVE on ${HA:0:12}" ] && ok || bad "N3 the failed start carried notes: $(lg8_notes 101)"
[ "$(lwf_agents)" = 0 ] && ok || bad "N3 agent calls=$(lwf_agents)"
[ "$(lwf_cnt '^PATCH /api/jobs/job-lr-101-.*"status":"failed"' "$T/log/worker")" = 1 ] && ok || bad "N3 job not failed: $(grep PATCH "$T/log/worker")"

# ── N4: a long re-review list is cut to its count ──
lg6_reset shadow
HG=$(lg6_head 101 lib/n4-base.txt "n4 base") || bad "N4 setup: no base head"
gc=(git -C "$W" -c user.email=t@example.invalid -c user.name=t)
"${gc[@]}" checkout -q --detach "$HG"; mkdir -p "$W/own"
for i in $(seq 1 120); do printf '%s\n' "$i" > "$W/own/a-long-file-name-for-the-own-files-list-$i.txt"; done
"${gc[@]}" add -A; "${gc[@]}" commit -qm "n4 many files"
HN=$("${gc[@]}" rev-parse HEAD); git -C "$W" push -qf "$O" "$HN:refs/pull/101/head"
git -C "$T/repos/cromford" fetch -q origin "refs/pull/101/head" "$HG"
lgf_needs "101:$HN"; lgf_cmp "$HN" "$MEDF"; lg8_bv 101 APPROVE "$HN" 2026-10-15T10:00:00Z
prior "$HG"; cls "$HG" "$HN" "full binary"
lwf_tick
N4=$(lg8_notes 101)
[[ "$N4" == *" own-files:+120 "* ]] && ok || bad "N4 the own-files list was not cut to its count: ${N4:0:300}"
[ "${#N4}" -le 4000 ] && ok || bad "N4 notes length ${#N4}"
[[ "$N4" == *"; review-tier:medium review-mode:full" ]] && ok || bad "N4 tokens not last: ${N4: -60}"

# ── M1: a mutation: lr_start sends no notes ──
LRS="$H/bin/lib/lead-reviews.sh"
# The mutant keeps the original beside it (sed -i.orig) and is restored with mv.
sed -i.orig 's/--arg n "\${6:-}"/--arg n ""/' "$LRS"
if cmp -s "$LRS" "$LRS.orig"; then bad "M1 the mutation did not apply (lr_start has no 6th argument)"
else
  lg6_reset
  lgf_needs "101:$HA"; lg8_bv 101 APPROVE "$HA" 2026-10-15T10:00:00Z
  lwf_tick
  [ -z "$(lg8_notes 101)" ] && ok || bad "M1 the mutant still sent notes: $(lg8_notes 101)"
fi
mv "$LRS.orig" "$LRS"

echo "lead-gates-notes.bh-5878: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
