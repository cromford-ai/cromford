#!/bin/bash
# tests/br-review-replan.bh-9437-test.sh — at the review fix cap, an
# ALWAYS-BLOCK finding sends the ticket to ONE re-plan before the abandon
# (BH-9437 item 2). br_fix_terminal's review arm runs br_cap_notes; when a
# floor finding stands (BR_CAPN_FLOOR=1) bin/blocked-resolver.d/
# bh-9437-review-replan.sh (brlad_review_replan) writes a `KIND: review-replan`
# build note with the finding and the fix-round history, and rebuilds fresh.
# The counter moves only when a job was bought; a second cap abandons.
#   §P1 floor finding at the cap -> the note (KIND, the finding, 2 fix-round
#       lines), one rebuild, review_replans=1, not ABANDONED
#   §P2 the second cap -> ABANDONED; a relayed review-replan note with the
#       counter wiped -> ABANDONED (the floor is wipe-resistant)
#   §P3 a person's review -> ABANDONED, no note; notes only -> CAP_NOTES
#   §P4 a deferred rebuild (no new job) -> the counter does not move, the note stays
#   §P5 plan.sh frames the note as a re-plan after a review block
#   §K  BR_REVIEW_REPLAN_MAX=0 -> ABANDONED; observe mode -> WOULD, nothing written
#   §Z  0 vendor calls
# Run: bash tests/br-review-replan.bh-9437-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: br-review-replan.bh-9437: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
. "$DIR/tests/lib/br-9437.sh" || exit 1
FRAG="$DIR/bin/blocked-resolver.d/bh-9437-review-replan.sh"
[ -r "$FRAG" ] && ok || bad "P0 $FRAG is missing"
[ -r "$DIR/bin/lib/br/cap.sh" ] && ok || bad "P0 bin/lib/br/cap.sh is missing"
[ -r "$DIR/catalog/lanes.d/blocked-resolver.knobs.d/BR_REVIEW_REPLAN_MAX.json" ] && ok || bad "P0 the BR_REVIEW_REPLAN_MAX knob row is missing"

bl9_extract "$DIR" "$T" br_fix_terminal br_cap_notes br_floor_stands br_cap_key br_rkey br_file br_load br_save \
  br_record br_set_outcome br_set_field br_num br_json_edit br_slug_of_url || exit 1
bl9_tripwire "$T" || exit 1
H="$T/h"; mkdir -p "$H/bin" "$H/state/blocked-resolver" "$H/state/build-notes"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lead-verdict.txt"\nexit 0\n' "$T" > "$H/bin/lead-verdict.sh"
chmod +x "$H/bin/"*.sh
HEAD=$(printf 'c%.0s' {1..40})
URL=https://github.com/o/r/pull/9
cat > "$T/drv.sh" <<EOF
set -u
PATH="$T/fakebin:\$PATH"
H="$H"; ST="$H/state/blocked-resolver"; NOTES="$H/state/build-notes"; LOG="$T/say.txt"; OBSERVE="\${OBSERVE:-0}"
export HARNESS="$DIR"
STAMP() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok a record stamp; no assertion reads it
say() { printf '%s\n' "\$*" >> "\$LOG"; }
mc_slug_of_url() { printf '%s' "\${1#https://github.com/}" | sed 's#/pull/.*##'; }
mc_num_of_url() { grep -oE '[0-9]+\$' <<<"\$1"; }
br_pr_field() { printf '%s' "$HEAD"; }
br_review_rows() { cat "$T/rows.json"; }
br_review_cleared() { return 1; }
br_is_external() { return 1; }
br_quiet() { :; }
harness_verdict_author_match() { case "\$1" in 'cromford[bot]') return 0 ;; *) return 1 ;; esac; }
gh_rest() { printf 'gh_rest %s\n' "\$*" >> "$T/gh.txt"; return 0; }
_jobs_req() { return 0; }
job_ledger_put() { return 0; }
setting_get() { return 2; }
bn_put() { printf '%s\n' "\$*" >> "$T/bn.txt"; return 0; }
bn_used() { printf none; }
br_jobs_count() { printf '%s' "\${1:-}" | jq -r '(.rebuild_jobs // null) | if . == null then "null" else (length|tostring) end' 2>/dev/null; }
br_abandon() { printf '%s\n' "\$*" >> "$T/abandon.txt"; br_set_outcome "\$1" "\$2" ABANDONED; }
# The rebuild rung: a job is bought unless \$T/defer exists.
br_rebuild_fresh() { printf '%s\n' "\$*" >> "$T/rebuild.txt"; [ -e "$T/defer" ] && return 0
  br_json_edit "\$1" "\$(br_cap_key "\$1" "\$2" "\$6")" '.rebuild_jobs = ((.rebuild_jobs // []) + [{id:("job-" + ((.rebuild_jobs // []) | length | tostring))}]) | .rebuilds = ((.rebuilds // 0) + 1)'; }
. "$DIR/bin/lib/review-level.sh"
. "$T/fns.sh"
for f in "$DIR"/bin/blocked-resolver.d/bh-9437-*.sh; do [ -r "\$f" ] && . "\$f"; done
EOF
mkrows() { local out='[]'; while [ $# -ge 4 ]; do out=$(jq -c --arg s "$1" --arg l "$2" --arg t "$3" --arg b "$4" --argjson id "$(( $(jq length <<<"$out") + 101 ))" \
  '. + [{id:$id, l:$l, t:$t, a:"MEMBER", c:"'"$HEAD"'", s:$s, b:$b}]' <<<"$out"); shift 4; done; printf '%s' "$out" > "$T/rows.json"; }
LEAD_FLOOR='<!-- lead-review:abd -->
Lead review of cccccccccccc

- [BLOCK tenant-leak] src/lib/clients.ts:88: listClients() has no companyId filter
- [NOTE] card.tsx:12: padding

VERDICT: BLOCK'
LEAD_NOTES='<!-- lead-review:abc -->
Lead review of cccccccccccc

- [BLOCK] card.tsx:12: card padding is 14 px, the prototype has 16 px

VERDICT: BLOCK'
RECF="$H/state/blocked-resolver/tproj/tproj-TP-9.json"
NOTE="$H/state/build-notes/tproj/TP-9.md"
REC() { cat "$RECF" 2>/dev/null; }
n() { cat "$T/$1.txt" 2>/dev/null | grep -c .; }
RESET() { local f; for f in "$H/state/blocked-resolver/tproj" "$H/state/build-notes/tproj" "$T"/{say,alerts,abandon,rebuild,gh,bn,lead-verdict}.txt "$T/defer"; do scratch_rm "$f" 2>/dev/null; done
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --arg u "$URL" '{project:"tproj",rkey:"tproj-TP-9",fixrounds:2,rebuilds:0,outcome:"",attempts:[
    {at:"2026-11-10T01:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"pushed aaaa111 to ticket/tp-9, typecheck+unit green",url:$u},
    {at:"2026-11-10T02:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"agent rc=0, verify rc=1 — no verified commit",url:$u},
    {at:"2026-11-10T03:00:00Z",action:"mechanical",reason:"red-twice",detail:"not a review round"}]}' > "$RECF"; }
TERM() { ( . "$T/drv.sh"; br_fix_terminal tproj 9 review-changes-requested "$URL" - TP-9 ); }
OUTCOME() { REC | jq -r '.outcome // ""'; }

# ── §P1: the first floor cap re-plans ─────────────────────────────────────
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_FLOOR"
TERM; RC=$?
[ "$RC" = 0 ] && ok || bad "P1 rc $RC"
[ "$(n abandon)" = 0 ] && [ "$(OUTCOME)" != ABANDONED ] && ok || bad "P1 the first floor cap is not ABANDONED (abandon $(n abandon), outcome $(OUTCOME))"
[ "$(head -1 "$NOTE" 2>/dev/null)" = "KIND: review-replan" ] && ok || bad "P1 the note starts KIND: review-replan: $(head -3 "$NOTE" 2>/dev/null)"
grep -q 'BLOCK tenant-leak.*listClients' "$NOTE" 2>/dev/null && ok || bad "P1 the note carries the ALWAYS-BLOCK finding"
grep -q 'card.tsx' "$NOTE" 2>/dev/null && bad "P1 the note carries only the floor findings, not the NOTE lines" || ok
[ "$(grep -c '^- .* fix-round: ' "$NOTE" 2>/dev/null)" = 2 ] && ok || bad "P1 the note carries the 2 fix-round rows of this reason: $(cat "$NOTE" 2>/dev/null)"
grep -q "$URL" "$NOTE" 2>/dev/null && ok || bad "P1 the note names the prior PR"
[ "$(n rebuild)" = 1 ] && ok || bad "P1 one rebuild, got $(n rebuild)"
[ "$(REC | jq -r '.review_replans')" = 1 ] && ok || bad "P1 review_replans=1: $(REC | jq -c '{review_replans}')"
[ "$(REC | jq '[.attempts[] | select(.action == "review-replan")] | length')" = 1 ] && ok || bad "P1 one review-replan attempt row"
[ "$(n bn)" = 1 ] && ok || bad "P1 the note goes to the build-note ledger (bn_put), got $(n bn)"
grep -q 're-plan' "$T/say.txt" && ok || bad "P1 the log says re-plan"

# ── §P2: the second cap abandons ──────────────────────────────────────────
TERM
[ "$(n abandon)" = 1 ] && [ "$(n rebuild)" = 1 ] && ok || bad "P2 the second cap abandons, no second rebuild (abandon $(n abandon), rebuild $(n rebuild))"
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_FLOOR"
mkdir -p "$H/state/build-notes/tproj"; printf 'KIND: review-replan\nPRIOR PR: x\n' > "$NOTE.relayed-1794000000"
TERM
[ "$(n abandon)" = 1 ] && [ "$(n rebuild)" = 0 ] && ok || bad "P2 a relayed review-replan note is a floor under a wiped counter (abandon $(n abandon), rebuild $(n rebuild))"
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_FLOOR"
mkdir -p "$H/builds/pool-tproj-TP-9-202611100000"; printf 'KIND: review-replan\n' > "$H/builds/pool-tproj-TP-9-202611100000/carried-note.md"
TERM
[ "$(n abandon)" = 1 ] && [ "$(n rebuild)" = 0 ] && ok || bad "P2 a consumed carried note counts too (abandon $(n abandon), rebuild $(n rebuild))"
scratch_rm "$H/builds/pool-tproj-TP-9-202611100000"

# ── §P3: not a floor finding ──────────────────────────────────────────────
RESET; mkrows CHANGES_REQUESTED operator User "$LEAD_FLOOR"
TERM
[ "$(n abandon)" = 1 ] && [ ! -e "$NOTE" ] && [ "$(n rebuild)" = 0 ] && ok || bad "P3 a person's CHANGES_REQUESTED abandons as today, no note (abandon $(n abandon), rebuild $(n rebuild))"
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES"
TERM
[ "$(OUTCOME)" = CAP_NOTES ] && [ ! -e "$NOTE" ] && [ "$(n rebuild)" = 0 ] && ok || bad "P3 notes only: CAP_NOTES as today (outcome $(OUTCOME))"

# ── §P4: a deferred rebuild ───────────────────────────────────────────────
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_FLOOR"; touch "$T/defer"
TERM; RC=$?
[ "$RC" = 0 ] && [ "$(n abandon)" = 0 ] && ok || bad "P4 a deferred rebuild is handled this tick, not abandoned (rc $RC, abandon $(n abandon))"
[ "$(REC | jq -r '.review_replans // 0')" = 0 ] && ok || bad "P4 no job bought: the counter does not move"
[ -s "$NOTE" ] && ok || bad "P4 the note stays for the next tick"
rm -f "$T/defer"; TERM
[ "$(REC | jq -r '.review_replans // 0')" = 1 ] && [ "$(n rebuild)" = 2 ] && ok || bad "P4 the next tick comes back through the cap and buys it (replans $(REC | jq -r '.review_replans // 0'), rebuild $(n rebuild))"

# ── §P5: the plan stage frames it ─────────────────────────────────────────
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
grep -q 'KIND: review-replan' "$DIR/bin/lib/rb/plan.sh" && ok || bad "P5 bin/lib/rb/plan.sh names KIND: review-replan"
awk '/^# >>> carried note/{f=1;next} /^# <<< carried note/{exit} f' "$RB_ALL" > "$T/cn.sh"
mkdir -p "$T/cnb" "$T/cnh/state/build-notes/tproj"
printf 'KIND: review-replan\nPRIOR PR: %s\nALWAYS-BLOCK FINDINGS:\n- [BLOCK tenant-leak] src/lib/clients.ts:88\n' "$URL" > "$T/cnh/state/build-notes/tproj/TP-9.md"
CNL=$( HARNESS="$T/cnh" BUILD="$T/cnb" PROJECT=tproj KEY=TP-9; STAMP() { echo T; }; . "$T/cn.sh"; printf '%s' "$CARRIED_NOTE_LINE" )
case "$CNL" in " THIS BUILD IS AN AUTOMATIC RE-PLAN AFTER A REVIEW BLOCK"*tenant-leak*) ok ;; *) bad "P5 CARRIED_NOTE_LINE frames a review re-plan with its evidence: $(printf '%.300s' "$CNL")" ;; esac
case "$CNL" in *ADJUDICATED*) bad "P5 a review re-plan is not a ruling" ;; *) ok ;; esac

# ── §K: the knob, observe mode ────────────────────────────────────────────
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_FLOOR"
( export BR_REVIEW_REPLAN_MAX=0; TERM )
[ "$(n abandon)" = 1 ] && [ "$(n rebuild)" = 0 ] && [ ! -e "$NOTE" ] && ok || bad "K BR_REVIEW_REPLAN_MAX=0 abandons at the cap as before (abandon $(n abandon))"
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_FLOOR"
( export OBSERVE=1; TERM )
[ "$(n rebuild)" = 0 ] && [ ! -e "$NOTE" ] && grep -q 'WOULD re-plan' "$T/say.txt" && ok || bad "K observe mode: a WOULD line, no note, no rebuild"

# ── §Z: no vendor ─────────────────────────────────────────────────────────
[ "$(bl9_vendor_calls "$T")" = 0 ] && ok || bad "Z vendor calls: $(cat "$T/vendor.txt")"

echo "br-review-replan.bh-9437: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
