#!/bin/bash
# tests/lead-gates-prev-note.bh-8524-test.sh — gate 50's re-review note
# (lg_field_prev_note in bin/lib/lead-gates.d/50-replay-delta.sh, written by
# lpv_note in bin/lib/lead-prev.sh) on the worklist. bin/lead-review.sh tick
# runs WHOLE over tests/lib/lead-worklist-fixture.bh-4956.sh, and its repo is a
# clone of a real git fixture:
#   base f.txt (20 lines), p.txt (10 lines), o.txt, CLAUDE.md. G (the PR)
#   appends to f.txt and edits p.txt line 5; main then changes f.txt line 1 and
#   o.txt. HM = G + a merge of main. HO = HM + one own commit on p.txt line 3.
# PR #41 is on HO with a builder APPROVE bound to HO; the lead row is on G.
#   PV0  no lead row: one job, no lead-prev: in its notes, no re-review line.
#   PV1  lead MERGE on G: the notes carry `lead-prev:<G> word:MERGE
#        report:state/lead-reviews/lr-41-<G12>.md own-commits:1 own-files:p.txt
#        main-files:f.txt`, and the log has `re-review of <G12> (MERGE):
#        own-commits:1`.
#   PV2  LEAD_DELTA_REVIEW_MAX_LINES=0: no lead-delta:, the same group.
#   PV3  a newer lead row on HM with a lead-replay: note: the group names G,
#        never HM.
#   PV4  lead BLOCK on G: `lead-prev:<G> word:BLOCK report:`.
#   M2   the earlier-review pick in the scratch copy of gate 50 keeps
#        lead-replay: rows (its `contains("lead-replay:")) | not` filter made
#        `true`): PV3 names HM (so PV3 can fail).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-prev-note.bh-8524-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/lead-gates.d/50-replay-delta.sh bin/lib/lead-prev.sh; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_DELTA_PROTECTED_MAX_LINES AGENT_CALL_FP AGENT_CALL_GUARD_STAGE

# ───────────────────────────── the fixture repo ─────────────────────────────
OR="$T/pv/origin.git"; WK="$T/pv/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"; seq 1 10 | sed 's/^/p line /' > "$WK/p.txt"; printf 'other\n' > "$WK/o.txt"
printf '# demo\n\nNo contract here.\n' > "$WK/CLAUDE.md"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr
echo 'pr line' >> "$WK/f.txt"; sed -i 's/^p line 5$/p line 5 by the pr/' "$WK/p.txt"; git -C "$WK" commit -qam "the pr"
G=$(git -C "$WK" rev-parse HEAD); G12=${G:0:12}
git -C "$WK" checkout -q main; sed -i 's/^base line 1$/main line 1/' "$WK/f.txt"; echo 'main moved' >> "$WK/o.txt"; git -C "$WK" commit -qam "main moves"
git -C "$WK" checkout -q pr; git -C "$WK" merge -q --no-edit main >/dev/null || { echo "FAIL: the fixture merge conflicted"; exit 1; }
HM=$(git -C "$WK" rev-parse HEAD)
sed -i 's/^p line 3$/p line 3 fixed/' "$WK/p.txt"; git -C "$WK" commit -qam "fix p three"; HO=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr "$G:refs/heads/g" "$HM:refs/heads/hm" "$HO:refs/heads/ho" "$HO:refs/pull/41/head"

# ─────────────────────── the worklist over that repo ───────────────────────
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
scratch_rm "$T/repos/demo-os"; git clone -q "$OR" "$T/repos/demo-os"
GATE="$H/bin/lib/lead-gates.d/50-replay-delta.sh"
[ -r "$GATE" ] || { echo "FAIL: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/50-replay-delta.sh"; exit 1; }
PREVG="lead-prev:$G word:MERGE report:state/lead-reviews/lr-41-$G12.md"

jobs41() { lwf_cnt '^POST /api/jobs .*"ticket_id":"lr-41-' "$T/log/worker"; }
# pnotes — the scope notes of the last lead review start for #41
pnotes() {
  grep '^POST /api/lead-reviews/start ' "$T/log/worker" 2>/dev/null | sed 's#^POST /api/lead-reviews/start ##' \
    | jq -r 'select(.pr == 41) | .scope_notes // ""' 2>/dev/null | tail -n 1
}
# pset <lead word on G, or ""> — #41 on HO, builder APPROVE bound to HO, one lead row on G
pset() {
  lwf_reset; scratch_rm "$H/state/lead-review-enqueue"
  lwf_needs_at example-org/demo-os "$HO" 41; echo "$HO" > "$FX/head.41"
  lwf_bv 41 APPROVE "$HO"
  jq -nc --arg g "$G" --arg w "$1" '{rows:(if $w == "" then [] else [{id:5, source:"lead", repo:"example-org/demo-os", pr:41,
    head_sha:$g, verdict:$w, note:"lead-review:lr-3"}] end), truncated:false}' > "$FX/verdicts.json"
}
# addreplay — a newer lead row on HM that only replayed an earlier word
addreplay() {
  jq --arg h "$HM" '.rows += [{id:6, source:"lead", repo:"example-org/demo-os", pr:41, head_sha:$h, verdict:"MERGE",
    note:"lead-replay:aaaaaaaaaaaa how:main-merge"}]' "$FX/verdicts.json" > "$FX/v.tmp" && mv "$FX/v.tmp" "$FX/verdicts.json"
}

# ── PV0: no lead row: no group ──
pset ""; lwf_tick
[ "$(jobs41)" = 1 ] && ok || bad "PV0 jobs for 41=$(jobs41) (want 1): $(cat "$L")"
case "$(pnotes)" in *lead-prev:*) bad "PV0 a lead-prev group with no lead row: '$(pnotes)'" ;; "") bad "PV0 no review start: $(cat "$L")" ;; *) ok ;; esac
grep -q "example-org/demo-os#41 @${HO:0:12}: re-review of" "$L" && bad "PV0 a re-review line: $(grep re-review "$L")" || ok

# ── PV1: lead MERGE on G ──
pset MERGE; lwf_tick
[ "$(jobs41)" = 1 ] && ok || bad "PV1 jobs for 41=$(jobs41) (want 1): $(cat "$L")"
case "$(pnotes)" in *"$PREVG own-commits:1 own-files:p.txt main-files:f.txt"*) ok ;; *) bad "PV1 notes: '$(pnotes)'" ;; esac
grep -q "example-org/demo-os#41 @${HO:0:12}: re-review of $G12 (MERGE): own-commits:1" "$L" && ok || bad "PV1 no re-review line: $(cat "$L")"

# ── PV2: delta mode off: no lead-delta:, the group stays ──
pset MERGE; LEAD_DELTA_REVIEW_MAX_LINES=0 lwf_tick
N=$(pnotes)
case "$N" in *lead-delta:*) bad "PV2 a delta note with the knob off: '$N'" ;; "") bad "PV2 no review start: $(cat "$L")" ;; *) ok ;; esac
case "$N" in *"$PREVG own-commits:1 own-files:p.txt main-files:f.txt"*) ok ;; *) bad "PV2 notes: '$N'" ;; esac

# ── PV3: a newer replay row on HM is not the earlier review ──
pv3() { pset MERGE; addreplay; lwf_tick; }
pv3
N=$(pnotes)
case "$N" in *"$PREVG "*) ok ;; *) bad "PV3 lead-prev does not name G: '$N' $(cat "$L")" ;; esac
case "$N" in *"lead-prev:$HM"*) bad "PV3 lead-prev names the replay head: '$N'" ;; *) ok ;; esac

# ── PV4: lead BLOCK on G ──
pset BLOCK; lwf_tick
case "$(pnotes)" in *"lead-prev:$G word:BLOCK report:"*) ok ;; *) bad "PV4 notes: '$(pnotes)' $(cat "$L")" ;; esac

# ── M2: the pick keeps replay rows: PV3 names HM ──
cp "$GATE" "$T/gate.orig"
sed -i 's/and (((.note \/\/ "") | contains("lead-replay:")) | not))\]/and true)]/' "$GATE"
cmp -s "$GATE" "$T/gate.orig" && bad "M2 the mutation did not apply"
pv3
case "$(pnotes)" in *"lead-prev:$HM word:MERGE"*) ok ;; *) bad "M2 the mutated pick did not name HM: '$(pnotes)' $(cat "$L")" ;; esac
cp "$T/gate.orig" "$GATE"
cmp -s "$GATE" "$SRC/bin/lib/lead-gates.d/50-replay-delta.sh" && ok || bad "M2 the gate was not restored"

echo "lead-gates-prev-note.bh-8524: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
