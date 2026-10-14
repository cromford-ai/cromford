#!/bin/bash
# tests/triage-state-system-comment.bh-3825-test.sh — BH-3830 (BH-3825.3): a
# comment our system actor posts stays IN the signal digest when its FIRST
# non-blank line carries the whole word `Unblocked` (any case) or `RESUME`
# (exact upper case), so an operator's "Unblocked: ..." nudge moves the
# triage-state input hash and the next tick re-triages the ticket.
#
#   S1 our `Unblocked: TK-2185 merged, go ahead` moves the digest and input_hash
#   S2 our `RESUME build` moves both
#   S3 our unmarked / line-3 / lower-case / RESUMED / not-whole-word comments
#      move neither
#   S4 a human comment moves both; S4b our `[human] ...` still moves both
#   S5 enforce ts_precheck over a scratch in-app board: `skip` before the
#      Unblocked comment, `llm changed` after it
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-state-system-comment.bh-3825-test.sh
# BH-6578: triaged_at is one hour before the run, never a fixed date. A
# client-turn verdict comes back after triaged_at + the nudge (14 days), so a
# fixed date made this fixture go red on the day the nudge ran out.
TRIAGED_AT=$(date -u -d "@$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -r "$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ')
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
unset SELF_IDENTITIES TRIAGE_SIGNAL_SELF_IDENTITIES HARNESS_SECRET JOBS_URL
NOW="2026-10-02T19:00:00Z"
HEX16='^[0-9a-f]{16}$'
HEX='^[0-9a-f]{16,64}$'
SIGPY="$DIR/bin/triage-signal.py"
STPY="$DIR/bin/triage-state.py"
SELF="project-1 Team Harness"

# ── fixtures: the board-fetch --full ticket, its world row, its thread wrapper ─
A="$T/a"; mkdir -p "$A"
jq -n --arg now "$NOW" '{ticket:{id:"c1a",key:"TK-2190",title:"Fee toggle",description:"Remove the discount toggle",status:"open",
  waitingOn:"us",comments:[
   {id:"c1",author:{userId:"u-carol",name:"Carol Client"},body:"please remove it",createdAt:$now},
   {id:"c2",author:{userId:"u-h",name:"project-1 Team Harness"},body:"on it",createdAt:$now}]}}' > "$A/in.json"
jq -n --arg now "$NOW" '{b1:[{id:"c1a",key:"TK-2190",title:"Fee toggle",status:"open",commentCount:2,lastActivityAt:$now}]}' > "$A/world.json"
dig()  { SELF_ACTORS="$SELF" python3 "$SIGPY" --kind inapp < "$1"; }
# ih <ticket-file> — the triage-state input_hash of that thread, as the pre-check wraps it
ih()   { jq -c --arg sa "$SELF" '{kind:"inapp",self_actors:$sa,self_identities:"",self_apps:[],doc:.}' "$1" \
           | python3 "$STPY" hash --world "$A/world.json" --key c1a --prefix AR | jq -r .input_hash; }
withc() { jq -c --argjson c "$1" '.ticket.comments += [$c]' "$A/in.json" > "$A/v.json"; }
ours()  { jq -cn --arg b "$1" --arg now "$NOW" '{id:"c3",author:{userId:"u-h",name:"project-1 Team Harness"},body:$b,createdAt:$now}'; }
human() { jq -cn --arg b "$1" --arg now "$NOW" '{id:"c3",author:{userId:"u-carol",name:"Carol Client"},body:$b,createdAt:$now}'; }
BD=$(dig "$A/in.json"); BH=$(ih "$A/in.json")
grep -qE "$HEX16" <<<"$BD" && ok || bad "fixture: base digest is 16 hex: [$BD]"
grep -qE "$HEX" <<<"$BH" && ok || bad "fixture: base input_hash is hex: [$BH]"
# moves <label> <comment-json> / same <label> <comment-json>
moves() { local d h; withc "$2"; d=$(dig "$A/v.json"); h=$(ih "$A/v.json")
  grep -qE "$HEX16" <<<"$d" && [ "$d" != "$BD" ] && ok || bad "$1 MUST move the digest ($d vs $BD)"
  grep -qE "$HEX" <<<"$h" && [ "$h" != "$BH" ] && ok || bad "$1 MUST move the input_hash ($h vs $BH)"; }
same()  { local d h; withc "$2"; d=$(dig "$A/v.json"); h=$(ih "$A/v.json")
  [ "$d" = "$BD" ] && ok || bad "$1 must NOT move the digest ($d vs $BD)"
  [ "$h" = "$BH" ] && ok || bad "$1 must NOT move the input_hash ($h vs $BH)"; }

# ═══ S1 / S2 — the markers ═══════════════════════════════════════════════════
moves "(S1) our 'Unblocked: TK-2185 merged, go ahead'" "$(ours 'Unblocked: TK-2185 merged, go ahead')"
moves "(S1) our 'unblocked' in any case, mid-line ('TK-2185 merged, UNBLOCKED')" "$(ours 'TK-2185 merged, UNBLOCKED')"
moves "(S1) our 'Unblocked —' on the first non-blank line after blanks" "$(ours $'\n  \nUnblocked — go\nrest')"
moves "(S2) our 'RESUME build'" "$(ours 'RESUME build')"

# ═══ S3 — negatives: stays OUT ═══════════════════════════════════════════════
same "(S3) our 'on it' (no marker)" "$(ours 'on it again')"
same "(S3) marker on line 3 only" "$(ours $'Holding this\n\nfor now\nunblocked once TK-2185 merges')"
same "(S3) lower-case 'resume build'" "$(ours 'resume build')"
same "(S3) 'Resumed the lane'" "$(ours 'Resumed the lane')"
same "(S3) 'RESUMED'" "$(ours 'RESUMED')"
same "(S3) 'This is unblockedness'" "$(ours 'This is unblockedness')"

# ═══ S4 — controls ═══════════════════════════════════════════════════════════
moves "(S4) a human comment, no marker" "$(human 'any news?')"
moves "(S4b) our '[human] please go' (BH-2604 rule intact)" "$(ours '[human] please go')"

# ═══ S5 — enforce ts_precheck: skip, then llm changed ═══════════════════════
H="$T/h"; P=project-4
mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/builds" "$H/flags"
for s in triage-state.py triage-signal.py; do ln -s "$DIR/bin/$s" "$H/bin/$s"; done
for s in triage-state.sh triage-shards-lib.sh; do ln -s "$DIR/bin/lib/$s" "$H/bin/lib/$s"; done
D="$H/state/triage-state/$P"; mkdir -p "$D"
ROWS="$T/rows.json"; echo '[]' > "$ROWS"
triage_state_list() { cat "$ROWS"; }
triage_state_put() { :; }
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"
tick_env() { # tick_env <mode>
  export HARNESS="$H" TRIAGE_STATE_MODE="$1" TRIAGE_STATE_MAX_FETCH=0
  PROJECT=$P; STAMP="2026-10-02 19:00:00Z"; LOG="$H/logs/$P.log"
  GATE_REASON=board-changed; SCOPE_N=full
  TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; JOB_ID=""
  PROMPT_TEXT="SOP PROMPT"
}
LANE_TICK() { :; }
rt_gate_consume() { :; }
cp "$A/world.json" "$H/state/$P.gate.pending"
jq -S '[.b1[] | {(.id): .key, (.key): .id}] | add' "$H/state/$P.gate.pending" > "$H/state/$P.keymap.json"
jq -c --arg sa "$SELF" '{kind:"inapp",self_actors:$sa,self_identities:"",self_apps:[],doc:.ticket}' "$A/in.json" > "$D/c1a.raw"
python3 "$STPY" entries --world "$H/state/$P.gate.pending" > "$T/entries.tsv"
while IFS=$'\t' read -r k _ esha _; do printf '%s' "$esha" > "$D/$k.entry"; done < "$T/entries.tsv"
col() { awk -F'\t' -v k="$1" -v c="$2" '$1==k{print $c}' "$D/decisions.tsv"; }
# pass 1: the hash; then a row stamped with it
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
H5=$(col c1a 5)
grep -qE "$HEX" <<<"$H5" && ok || bad "(S5) fixture: the ticket hashed: $(cat "$D/decisions.tsv" 2>/dev/null)"
jq -n --arg ta "$TRIAGED_AT" --arg h "$H5" '[{ticket_key:"c1a", verdict:"triaged", waiting_on:"none", verdict_hash:$h, input_hash:$h,
  triaged_at:$ta, next_recheck_at:"2099-01-01T00:00:00Z", reason:"x"}]' > "$ROWS"
tick_env enforce; ( ts_precheck ) >/dev/null 2>&1
[ "$(col c1a 3) $(col c1a 4)" = "skip unchanged:triaged" ] && ok \
  || bad "(S5) before the nudge the settled ticket is skip unchanged: [$(cut -f1-5 "$D/decisions.tsv")]"
jq -c --argjson c "$(ours 'Unblocked: TK-2185 merged, go ahead')" '.doc.comments += [$c]' "$D/c1a.raw" > "$T/raw2" && mv "$T/raw2" "$D/c1a.raw"
tick_env enforce; ( ts_precheck ) >/dev/null 2>&1
[ "$(col c1a 3) $(col c1a 4)" = "llm changed" ] && ok \
  || bad "(S5) after our 'Unblocked:' comment the next pre-check sends it to the model: [$(cut -f1-5 "$D/decisions.tsv")]"

echo "triage-state-system-comment: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
