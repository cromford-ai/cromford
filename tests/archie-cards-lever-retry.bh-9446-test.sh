#!/bin/bash
# tests/archie-cards-lever-retry.bh-9446-test.sh — BH-9446 (scope 4): in the
# SHIPPED bin/archie-cards.sh, a lever outcome `failed` (a read or a write that
# did not answer) is pulled again on later ticks, at most
# ARCHIE_CARDS_LEVER_RETRY_MAX times (default 3), one log line per retry, no
# model call. needs-operator goes out when the retries are used up. refused, would,
# rc 1 and a lever that does not fit go out at once.
#
#   R1  failed head-unreadable, failed head-unreadable, done over 3 ticks: 0
#       needs-operator, 1 acted, 2 `retry n of 3` lines, the retry file deleted,
#       the lane line has retried=1 on ticks 2 and 3.
#   R2  failed 4 times: exactly 1 needs-operator, on tick 4, "4 times: failed".
#   R3  refused no-opt-in: 1 needs-operator on tick 1, no retry file; would and rc
#       1 the same.
#   R4  no env = max 3 (R2); ARCHIE_CARDS_LEVER_RETRY_MAX=0: failed is
#       needs-operator at once; a bad value is the fallback 3 and one warn line.
#   R5  the retry ticks make 0 agent-call calls and 0 archie-claim POSTs.
#   R6  the card is routed by the timeout between ticks: the file is dropped,
#       0 replies, 0 writer calls; unread open rows keep the file.
#   R7  a refused outcome on a retry tick: needs-operator "(try 2)" at once.
#   B   0 gh, curl or model CLI calls.
#
# STUBS (ARCHIE_CARDS_FIXTURE): the open rows are $FXT/rows.jsonl; the
# archie-claim POST stamps archie_claimed_at there; ub_act answers the next
# line of $FXT/outcomes (`<outcome> <detail>` or rc1). unblock-reply.sh and
# agent-call.sh are logging stubs in the scratch tree; needs-operator routes the
# row (routed_to operator) and acted closes it, as the real reply verb does.
#
# MUTATIONS (D1), each tried once by hand: send needs-operator on the first
# failed -> R1, R2 red; no bound on the retries -> R2 red; retry a refused ->
# R3 red; ignore the knob -> R4 red; keep the file of a routed card -> R6 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-cards-lever-retry.bh-9446-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

R=example-org/cromford
HEAD=9345cccc9345cccc9345cccc9345cccc9345cccc
NOW=$(date -u -d '2026-11-10T12:00:00Z' +%s)
mkdir -p "$T/pathbin"
for s in gh curl claude flyctl; do printf '#!/bin/bash\necho "%s $*" >> "%s/vendor.log"\nexit 7\n' "$s" "$T" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*
: > "$T/vendor.log"

mkarchie() {
  local A="$T/$1"
  mkdir -p "$A/h/env" "$A/h/state" "$A/h/logs" "$A/fx"
  ( cd "$SRC" && scratch_install_closure bin/archie-cards.sh "$A/h" ) >/dev/null || { echo "setup: closure archie-cards" >&2; return 1; }
  : > "$A/h/env/global.env"
  rm -f "$A/h/bin/unblock-reply.sh" "$A/h/bin/agent-call.sh"
  cat > "$A/h/bin/unblock-reply.sh" <<'SH'
#!/bin/bash
echo "REPLY $*" >> "$FXT/seq.log"
case "$3" in
  acted) jq -c --arg c "$2" 'select(.card.id != $c)' "$FXT/rows.jsonl" > "$FXT/rows.tmp"; mv "$FXT/rows.tmp" "$FXT/rows.jsonl"; echo ARCHIE_ANSWERED ;;
  needs-operator) jq -c --arg c "$2" 'if .card.id == $c then .routed_to = "operator" else . end' "$FXT/rows.jsonl" > "$FXT/rows.tmp"
    mv "$FXT/rows.tmp" "$FXT/rows.jsonl"; echo ARCHIE_ROUTED ;;
  *) echo ARCHIE_ANSWERED ;;
esac
exit 0
SH
  printf '#!/bin/bash\necho "AGENTCALL $1" >> "$FXT/seq.log"\ncat "$FXT/answer" > "$5"\nexit 0\n' > "$A/h/bin/agent-call.sh"
  chmod +x "$A/h/bin/unblock-reply.sh" "$A/h/bin/agent-call.sh"
  cat > "$A/fx.sh" <<'SH'
flag_active() { return 1; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { printf 'model-fixture\n'; }
unb_scope_projects() { printf 'cromford\tact\n'; }
unblock_card_open_rows() { [ -f "$FXT/rows.fail" ] && return 1; cat "$FXT/rows.jsonl"; }
_jobs_req() {
  printf 'JOBS %s %s\n' "$1" "$2" >> "$FXT/seq.log"
  case "$1 $2" in
    "POST /api/unblock/decisions/"*/archie-claim)
      jq -c '.archie_claimed_at = "2026-11-10T12:00:00Z"' "$FXT/rows.jsonl" > "$FXT/rows.tmp"; mv "$FXT/rows.tmp" "$FXT/rows.jsonl"; return 0 ;;
  esac
  return 1
}
ub_act() {
  local n line
  printf 'UBACT %s\n' "$1" >> "$FXT/seq.log"
  n=$(( $(cat "$FXT/ub.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/ub.n"
  line=$(sed -n "${n}p" "$FXT/outcomes")
  [ "$line" = rc1 ] && { UB_ACT_OUTCOME="" UB_ACT_DETAIL=""; return 1; }
  UB_ACT_OUTCOME=${line%% *} UB_ACT_DETAIL=${line#* }
  printf '%s\t%s\n' "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL"; return 0
}
SH
  jq -nc --arg r "$R" --arg h "$HEAD" '{id: 52, decision_key: "k9345", project: "cromford", repo: $r, subject_kind: "pr",
    subject: ($r + "#9345"), head: $h, stall_class: "pr-verdict-old-head", evidence: {pr: 9345}, outcome: "escalated",
    routed_to: null, archie_claimed_at: null, created_at: "2026-11-10T11:50:00Z",
    card: {id: "u-aec749", key: "k9345", route: "archie", class: "review-rerequest", subject: ($r + "#9345")}}' > "$A/fx/rows.jsonl"
  echo '{"pick":"act","lever":"re_review","reason":"the verdict is on an older head"}' > "$A/fx/answer"
  printf '%s' "$A"
}
atick() {
  local A="$1"; shift
  ( env HARNESS="$A/h" FXT="$A/fx" ARCHIE_CARDS_FIXTURE="$A/fx.sh" HARNESS_TEST_SANDBOX=1 ARCHIE_CARDS_TIMED=1 \
      ARCHIE_CARDS_NOW="$NOW" LANE_GATE_DISABLE=1 PATH="$T/pathbin:$PATH" TMPDIR="$A" HARNESS_REPO="$R" "$@" \
      bash "$A/h/bin/archie-cards.sh" tick ) > "$A/atick.out" 2>&1
}
outcomes() { printf '%s\n' "${@:2}" > "$1/fx/outcomes"; }
operator() { cnt '^REPLY archie u-aec749 needs-operator ' "$1/fx/seq.log"; }
acted() { cnt '^REPLY archie u-aec749 acted ' "$1/fx/seq.log"; }
RF=state/archie-cards-retry/u-aec749.json
ALOG=logs/archie-cards.log

# ═════ R1: failed, failed, done ══════════════════════════════════════════════
A=$(mkarchie r1) || { echo "FAIL: setup"; exit 1; }
outcomes "$A" "failed head-unreadable" "failed head-unreadable" "done lead re-requested"
atick "$A"
check "R1 tick 1: 1 writer call, 0 replies, the retry file has attempts 1" \
  "$(cnt '^UBACT' "$A/fx/seq.log") $(cnt '^REPLY' "$A/fx/seq.log") $(jq -r .attempts "$A/h/$RF" 2>/dev/null)" "1 0 1"
check "R1 the retry file: the row, the lever, the detail" \
  "$(jq -c '[.row_id, .project, .lever, .last_detail]' "$A/h/$RF" 2>/dev/null)" '[52,"cromford","re_review","head-unreadable"]'
atick "$A"
check "R1 tick 2: 2 writer calls, 0 replies, attempts 2" \
  "$(cnt '^UBACT' "$A/fx/seq.log") $(cnt '^REPLY' "$A/fx/seq.log") $(jq -r .attempts "$A/h/$RF" 2>/dev/null)" "2 0 2"
atick "$A"
check "R1 tick 3: done: 0 needs-operator, 1 acted with the lever" "$(operator "$A") $(acted "$A") $(grep -c 'acted lever re_review done: lead re-requested.* re_review$' "$A/fx/seq.log")" "0 1 1"
check "R1 2 retry log lines" "$(grep -c 'retry [0-9] of 3' "$A/h/$ALOG")" 2
check "R1 the retry file is deleted" "$( [ -e "$A/h/$RF" ] && echo kept || echo gone)" gone
check "R1 the lane line counts the retries (ticks 1-3)" "$(grep -o 'retried=[0-9]*' "$A/h/$ALOG" | tr '\n' ' ')" "retried=0 retried=1 retried=1 "
check "R5 3 ticks: 1 agent-call, 1 archie-claim POST" \
  "$(cnt '^AGENTCALL' "$A/fx/seq.log") $(cnt 'archie-claim$' "$A/fx/seq.log")" "1 1"
check "R1 every retry pulls the same lever from the row (lead_rerequest, pr 9345, the head)" \
  "$(grep '^UBACT ' "$A/fx/seq.log" | sed 's/^UBACT //' | jq -c '[.action.name, .pr, .head]' | sort -u)" "[\"lead_rerequest\",9345,\"$HEAD\"]"

# ═════ R2: failed 4 times ════════════════════════════════════════════════════
A=$(mkarchie r2) || { echo "FAIL: setup"; exit 1; }
outcomes "$A" "failed head-unreadable" "failed head-unreadable" "failed head-unreadable" "failed head-unreadable"
atick "$A"; atick "$A"; atick "$A"
check "R2 ticks 1-3: 3 writer calls, 0 needs-operator" "$(cnt '^UBACT' "$A/fx/seq.log") $(operator "$A")" "3 0"
atick "$A"
check "R2 tick 4: exactly 1 needs-operator" "$(operator "$A")" 1
check "R2 the reason says 4 times: failed" "$(grep -c 'needs-operator Archie pulled lever re_review 4 times: failed head-unreadable. the verdict is on an older head' "$A/fx/seq.log")" 1
check "R2 the file is deleted; a 5th tick makes no call" "$( [ -e "$A/h/$RF" ] && echo kept || echo gone)" gone
atick "$A"
check "R2 tick 5: still 4 writer calls and 1 needs-operator" "$(cnt '^UBACT' "$A/fx/seq.log") $(operator "$A")" "4 1"
check "R5 5 ticks: 1 agent-call, 1 archie-claim POST" "$(cnt '^AGENTCALL' "$A/fx/seq.log") $(cnt 'archie-claim$' "$A/fx/seq.log")" "1 1"

# ═════ R3: refused, would, rc 1: needs-operator at once ══════════════════════════
for O in "refused no-opt-in" "would WOULD_LEAD_REREQUEST" rc1; do
  A=$(mkarchie "r3-${O%% *}") || { echo "FAIL: setup"; exit 1; }
  outcomes "$A" "$O"; atick "$A"
  check "R3 [$O]: 1 needs-operator on tick 1, no retry file" "$(operator "$A") $( [ -e "$A/h/$RF" ] && echo kept || echo none)" "1 none"
done
check "R3 the refused reason names the outcome" "$(grep -c 'needs-operator Archie pulled lever re_review: refused no-opt-in' "$T/r3-refused/fx/seq.log")" 1

# ═════ R4: the knob ══════════════════════════════════════════════════════════
A=$(mkarchie r4) || { echo "FAIL: setup"; exit 1; }
outcomes "$A" "failed head-unreadable"; atick "$A" ARCHIE_CARDS_LEVER_RETRY_MAX=0
check "R4 ARCHIE_CARDS_LEVER_RETRY_MAX=0: failed is needs-operator at once, no file" \
  "$(operator "$A") $( [ -e "$A/h/$RF" ] && echo kept || echo none)" "1 none"
A=$(mkarchie r4b) || { echo "FAIL: setup"; exit 1; }
outcomes "$A" "failed x" "failed x" "failed x" "failed x"
atick "$A" ARCHIE_CARDS_LEVER_RETRY_MAX=99; atick "$A" ARCHIE_CARDS_LEVER_RETRY_MAX=99; atick "$A" ARCHIE_CARDS_LEVER_RETRY_MAX=99
check "R4 a bad value (99): the fallback 3, one warn line per tick, 0 needs-operator after 3 ticks" \
  "$(operator "$A") $(grep -c "warn: ARCHIE_CARDS_LEVER_RETRY_MAX='99' is not 0..10; 3 used" "$A/h/$ALOG")" "0 3"
atick "$A" ARCHIE_CARDS_LEVER_RETRY_MAX=99
check "R4 the fallback 3: needs-operator on tick 4" "$(operator "$A")" 1
A=$(mkarchie r4c) || { echo "FAIL: setup"; exit 1; }
outcomes "$A" "failed x" "failed x"; atick "$A" ARCHIE_CARDS_LEVER_RETRY_MAX=1; atick "$A" ARCHIE_CARDS_LEVER_RETRY_MAX=1
check "R4 ARCHIE_CARDS_LEVER_RETRY_MAX=1: needs-operator on tick 2, 2 times" \
  "$(operator "$A") $(grep -c 're_review 2 times: failed x' "$A/fx/seq.log")" "1 1"

# ═════ R6: routed between ticks; unread rows ═════════════════════════════════
A=$(mkarchie r6) || { echo "FAIL: setup"; exit 1; }
outcomes "$A" "failed head-unreadable" "done x"; atick "$A"
touch "$A/fx/rows.fail"; atick "$A"
check "R6 open rows unreadable: the file is kept, 0 writer calls on that tick" \
  "$( [ -e "$A/h/$RF" ] && echo kept || echo gone) $(cnt '^UBACT' "$A/fx/seq.log")" "kept 1"
rm -f "$A/fx/rows.fail"
jq -c '.routed_to = "operator"' "$A/fx/rows.jsonl" > "$A/fx/rows.tmp" && mv "$A/fx/rows.tmp" "$A/fx/rows.jsonl"
atick "$A"
check "R6 the card was routed: the file is dropped, 0 replies, still 1 writer call" \
  "$( [ -e "$A/h/$RF" ] && echo kept || echo gone) $(cnt '^REPLY' "$A/fx/seq.log") $(cnt '^UBACT' "$A/fx/seq.log")" "gone 0 1"
check "R6 one log line says why" "$(grep -c 'u-aec749: retry dropped: card closed or routed' "$A/h/$ALOG")" 1

# ═════ R7: refused on a retry ════════════════════════════════════════════════
A=$(mkarchie r7) || { echo "FAIL: setup"; exit 1; }
outcomes "$A" "failed head-unreadable" "refused head-moved"; atick "$A"; atick "$A"
check "R7 refused on the retry: 1 needs-operator, (try 2), the file deleted" \
  "$(operator "$A") $(grep -c 'needs-operator Archie pulled lever re_review (try 2): refused head-moved' "$A/fx/seq.log") $( [ -e "$A/h/$RF" ] && echo kept || echo gone)" "1 1 gone"

check "B 0 gh, curl or model CLI calls" "$(grep -c . "$T/vendor.log")" 0
echo "archie-cards-lever-retry.bh-9446: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
