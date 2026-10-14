#!/bin/bash
# tests/split-watchdog-act.bh-1809-test.sh — BH-1809 (BH-1793.4): sw_act, the
# split-watchdog act lib bin/lib/split-watchdog-act.sh. The REAL
# bin/jobs-client.sh supplies queue_put / queue_ready_put; only _jobs_req (a
# file-backed stub worker that persists queue rows) and the four sw_* ledger
# verbs (file-backed fakes of the contract semantics — the real client verbs
# are still the BH-1805 rc 1 stubs until BH-1806 lands) are replaced.
#   FP      children fingerprint stable; changes when a queue_status changes.
#   AT-1    pool enqueue: one POST /api/queue (fly, ticket_id, meta); acted.
#           Second call: worker answers duplicate -> skip-duplicate, skipped.
#   AT-3    reenqueue: one queue call; same reason -> no call, row stays acted,
#           repeats counted; repeat K -> one stalled alert, prints stalled;
#           next call -> skipped, no queue call, no new alert.
#   AT-4    owed-completion: one owed alert (pr_url + head_sha) on the first
#           call, none on the second, none even when dedupe misses the row.
#   AT-5    close-parent: decompose-parent-close.sh <p> --cooled once; acted.
#   AT-5b   close-parent whose stdout names another parent -> skipped, declined.
#   AT-6    handoff-rebase: one skipped row "dirty @<sha>; owner rebase-train".
#   AT-12   family day cap 1: second due step -> skip-cap-family with today's
#           date, no queue call, skipped.
#   BOX     box route, rq_on false -> skip-no-fleet-path, no /api/queue call.
#   BOX-ON  box route, rq_on true -> one ready POST, ready_line shape, acted.
#   FAILED  POST rc 1 -> failed row, prints failed, never acted.
#   NOTID   child with no ticket id -> failed, no queue call.
#   OUTAGE  ledger rc 1 (every verb, the stall-gate read alone, or a
#           non-numeric day count) -> sw_act rc 1, no stdout, no queue call.
#   CRASH   record fails after a queued write -> rc 1; next call duplicate.
#   NOFLOCK no flock in the lib's non-comment lines.
# Every case: git / gh / claude stubs on PATH poison the run if invoked, and a
# `pending` outcome poisons it too.
# Run from anywhere: tests/split-watchdog-act.bh-1809-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

mkdir -p "$T/h/bin/lib/jobs" "$T/h/logs" "$T/stubs"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
for c in git gh claude; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/POISON"\nexit 1\n' "$c" "$T" > "$T/stubs/$c"
done
cat > "$T/h/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf 'lane-alert' >> "$T/calls"; printf ' [%s]' "\$@" >> "$T/calls"; echo >> "$T/calls"
EOF
cat > "$T/h/bin/decompose-parent-close.sh" <<EOF
#!/bin/bash
printf 'dpc' >> "$T/calls"; printf ' [%s]' "\$@" >> "$T/calls"; echo >> "$T/calls"
printf '%s\n' "\${DPC_OUT:-}"
EOF
chmod +x "$T/stubs/"* "$T/h/bin/lane-alert.sh" "$T/h/bin/decompose-parent-close.sh"
export PATH="$T/stubs:$PATH" SW_HARNESS="$T/h"

# The production client, then the production lib under test.
( cd "$T/h" && HARNESS="$T/h" . bin/jobs-client.sh ) >/dev/null 2>&1 || bad "setup: jobs-client does not source"
HARNESS="$T/h" . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1
. "$DIR/bin/lib/split-watchdog-act.sh"
declare -F queue_put queue_ready_put >/dev/null || bad "setup: real queue_put/queue_ready_put not loaded"

# --- stub worker: persists queue rows in $T/queue, logs every request ---------
_jobs_req() {
  local m="${1:-}" path="${2:-}" body="${3:-}" k p
  printf '%s %s %s\n' "$m" "$path" "$body" >> "$T/req"
  [ -e "$T/outage" ] && return 1
  [ "$m" = POST ] && [ -e "$T/post_fail" ] && return 1
  if [ "$m" = POST ] && [ "$path" = /api/queue ]; then
    p=$(jq -r .project <<<"$body"); k=$(jq -r .key <<<"$body")
    if grep -qxF "$p/$k" "$T/queue" 2>/dev/null; then echo '{"ok":true,"duplicate":true}'
    else echo "$p/$k" >> "$T/queue"; echo '{"ok":true}'; fi
    return 0
  fi
  return 1
}
# --- ledger fakes: rows "family<TAB>child<TAB>step<TAB>reason<TAB>outcome<TAB>repeats" ---
sw_record() {
  local p="${1:-}" f="${2:-}" c="${3:-}" s="${4:-}" r="${5:-}" o="${6:-}" n
  [ -e "$T/sw_outage" ] && return 1
  [ -e "$T/record_fail" ] && { rm -f "$T/record_fail"; return 1; }
  [ "$o" = pending ] && echo "pending $c $s" >> "$T/POISON"
  touch "$T/ledger"
  n=$(awk -F'\t' -v c="$c" -v s="$s" -v r="$r" '$2==c&&$3==s&&$4==r{print $6}' "$T/ledger")
  if [ -z "$n" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t0\n' "$f" "$c" "$s" "$r" "$o" >> "$T/ledger"; echo first
  else
    n=$((n+1))
    awk -F'\t' -v OFS='\t' -v c="$c" -v s="$s" -v r="$r" -v o="$o" -v n="$n" \
      '$2==c&&$3==s&&$4==r{$5=o;$6=n}1' "$T/ledger" > "$T/ledger.new" && mv "$T/ledger.new" "$T/ledger"
    echo "repeat $n"
  fi
}
sw_seen() {
  [ -e "$T/sw_outage" ] && return 1
  [ "${3:-}" = stalled ] && [ -e "$T/seen_fail_stalled" ] && return 1
  [ -e "$T/seen_blind" ] && return 0
  awk -F'\t' -v c="${2:-}" -v s="${3:-}" -v r="${4:-}" '$2==c&&$3==s&&$4==r{print $5}' "$T/ledger" 2>/dev/null
}
sw_actions_today() {
  [ -e "$T/sw_outage" ] && return 1
  awk -F'\t' -v f="${2:-}" '$1==f&&$5=="acted"{n++}END{print n+0}' "$T/ledger" 2>/dev/null
}
sw_list() { [ -e "$T/sw_outage" ] && return 1; cat "$T/ledger" 2>/dev/null; }

reset() { rm -f "$T/queue" "$T/req" "$T/ledger" "$T/calls" "$T/outage" "$T/post_fail" "$T/sw_outage" "$T/record_fail" "$T/seen_fail_stalled" "$T/seen_blind"
  : > "$T/queue"; : > "$T/req"; : > "$T/ledger"; : > "$T/calls"; }
nreq()  { grep -c '^POST /api/queue' "$T/req" 2>/dev/null || true; }
nalert() { grep -c -- "${1:-lane-alert}" "$T/calls" 2>/dev/null || true; }
row()   { awk -F'\t' -v c="$1" -v s="$2" '$2==c&&$3==s' "$T/ledger" 2>/dev/null; }
# key ticket_id board_status woc pr_state pr_url merged_at mergeable head_sha lock queue_status qreason qfin deploy
line() { printf '%s\t%s\tin_progress\t0\t%s\t%s\t0\tclean\t%s\t0\t%s\t\t\tunknown\n' "$@"; }
FAM=$(line BH-1 101 merged https://gh/pr/1 abc111 done; line BH-2 102 none '' '' failed)
act() { OUT=$(printf '%s\n' "$FAM" | sw_act "$@" 2>/dev/null); RC=$?; }

# --- FP -------------------------------------------------------------------------
fp1=$(printf '%s\n' "$FAM" | _swa_fp); fp2=$(printf '%s\n' "$FAM" | _swa_fp)
FAM2=$(line BH-1 101 merged https://gh/pr/1 abc111 done; line BH-2 102 none '' '' queued)
fp3=$(printf '%s\n' "$FAM2" | _swa_fp)
[[ "$fp1" =~ ^fp:[0-9a-f]{12}$ ]] && [ "$fp1" = "$fp2" ] && ok || bad "FP not stable/shaped: [$fp1] [$fp2]"
[ "$fp1" != "$fp3" ] && ok || bad "FP did not change with queue_status: $fp1"

# --- AT-1 -----------------------------------------------------------------------
reset
act p 1000 pool enqueue BH-2 "no build yet"
[ "$RC" = 0 ] && [ "$OUT" = acted ] && ok || bad "AT-1 first rc=$RC out=[$OUT], want acted"
[ "$(nreq)" = 1 ] && ok || bad "AT-1 first made $(nreq) queue POSTs, want 1"
b=$(grep '^POST /api/queue' "$T/req" | head -1 | cut -d' ' -f3-)
[ "$(jq -r '.target+"|"+.ticket_id+"|"+.meta+"|"+.key' <<<"$b" 2>/dev/null)" = 'fly|102|{"split_watchdog":"1000"}|BH-2' ] \
  && ok || bad "AT-1 body wrong: $b"
act p 1000 pool enqueue BH-2 "still no build"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && ok || bad "AT-1 second rc=$RC out=[$OUT], want skipped"
[ -n "$(row BH-2 skip-duplicate | awk -F'\t' '$5=="skipped"')" ] && ok || bad "AT-1 no skip-duplicate/skipped row: $(cat "$T/ledger")"
[ "$(awk -F'\t' '$5=="acted"' "$T/ledger" | wc -l)" = 1 ] && ok || bad "AT-1 acted rows != 1: $(cat "$T/ledger")"
[ "$(wc -l < "$T/queue")" = 1 ] && ok || bad "AT-1 queue rows != 1"

# --- AT-3 -----------------------------------------------------------------------
reset
R="plan session produced no output"
act p 1000 pool reenqueue BH-2 "$R"
[ "$OUT" = acted ] && [ "$(nreq)" = 1 ] && ok || bad "AT-3 first out=[$OUT] posts=$(nreq)"
for i in 1 2; do
  act p 1000 pool reenqueue BH-2 "$R"
  [ "$RC" = 0 ] && [ "$OUT" = skipped ] && ok || bad "AT-3 repeat $i rc=$RC out=[$OUT], want skipped"
  [ "$(nreq)" = 1 ] && ok || bad "AT-3 repeat $i made a queue call ($(nreq))"
  [ "$(row BH-2 reenqueue | cut -f5,6)" = "acted	$i" ] && ok || bad "AT-3 repeat $i row [$(row BH-2 reenqueue)], want acted $i"
done
[ "$(nalert split-watchdog-stalled)" = 0 ] && ok || bad "AT-3 stalled alert before K"
act p 1000 pool reenqueue BH-2 "$R"
[ "$RC" = 0 ] && [ "$OUT" = stalled ] && ok || bad "AT-3 repeat 3 rc=$RC out=[$OUT], want stalled"
[ "$(nreq)" = 1 ] && ok || bad "AT-3 repeat 3 made a queue call"
[ "$(nalert '\[split-watchdog-stalled-p-1000\]')" = 1 ] && ok || bad "AT-3 stalled alerts: $(cat "$T/calls" 2>/dev/null)"
grep -q '\[--severity\] \[warn\] \[--id\] \[split-watchdog-stalled-p-1000\] \[split-watchdog\] \[1000: BH-2 reenqueue repeated 3x' "$T/calls" \
  && ok || bad "AT-3 stalled alert argv: $(cat "$T/calls")"
[ -n "$(awk -F'\t' '$2=="1000"&&$3=="stalled"&&$4 ~ /^fp:/&&$5=="stalled"' "$T/ledger")" ] && ok || bad "AT-3 no stalled fp row: $(cat "$T/ledger")"
act p 1000 pool reenqueue BH-2 "$R"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && ok || bad "AT-3 after stall rc=$RC out=[$OUT], want skipped"
[ "$(nreq)" = 1 ] && [ "$(nalert split-watchdog-stalled)" = 1 ] && ok || bad "AT-3 after stall posts=$(nreq) alerts=$(nalert split-watchdog-stalled)"
[ "$(row BH-2 reenqueue | cut -f6)" = 3 ] && ok || bad "AT-3 stall gate still touched the child row"
# A changed family (new fingerprint) is not gated by the old stall row.
FAM_SAVE=$FAM; FAM=$FAM2
act p 1000 pool reenqueue BH-2 "$R"
[ "$OUT" = stalled ] && [ "$(row BH-2 reenqueue | cut -f6)" = 4 ] && [ "$(nreq)" = 1 ] \
  && ok || bad "AT-3 new fp out=[$OUT] row=[$(row BH-2 reenqueue)], want stalled at repeat 4 and no queue call"
FAM=$FAM_SAVE

# --- AT-4 -----------------------------------------------------------------------
reset
act p 1000 pool owed-completion BH-1 "merged, deploy serves, still in_progress"
[ "$RC" = 0 ] && [ "$OUT" = acted ] && ok || bad "AT-4 first rc=$RC out=[$OUT], want acted"
[ "$(nalert '\[split-watchdog-owed-p-BH-1\]')" = 1 ] && ok || bad "AT-4 owed alerts: $(cat "$T/calls" 2>/dev/null)"
grep -q '\[--severity\] \[warn\] \[--id\] \[split-watchdog-owed-p-BH-1\] \[split-watchdog\] \[BH-1 PR merged https://gh/pr/1, deploy serves abc111, ticket still in_progress. What-shipped comment owed.\]' "$T/calls" \
  && ok || bad "AT-4 alert argv: $(cat "$T/calls")"
act p 1000 pool owed-completion BH-1 "merged, deploy serves, still in_progress"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && ok || bad "AT-4 second rc=$RC out=[$OUT]"
[ "$(nalert split-watchdog-owed)" = 1 ] && ok || bad "AT-4 second call alerted again"
[ "$(nreq)" = 0 ] && ok || bad "AT-4 made a queue call"
# The owed branch itself (not only dedupe) holds the alert to the row's first record.
touch "$T/seen_blind"
act p 1000 pool owed-completion BH-1 "merged, deploy serves, still in_progress"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && [ "$(nalert split-watchdog-owed)" = 1 ] \
  && ok || bad "AT-4 repeat past dedupe out=[$OUT] alerts=$(nalert split-watchdog-owed), want skipped and still 1"
rm -f "$T/seen_blind"

# --- AT-5 / AT-5b -----------------------------------------------------------------
reset
DPC_OUT=1000 act p 1000 pool close-parent 1000 "every child closed"
[ "$RC" = 0 ] && [ "$OUT" = acted ] && ok || bad "AT-5 rc=$RC out=[$OUT], want acted"
[ "$(grep -c '^dpc' "$T/calls")" = 1 ] && grep -qx 'dpc \[p\] \[--cooled\]' "$T/calls" && ok || bad "AT-5 dpc argv: $(cat "$T/calls")"
[ "$(row 1000 close-parent | cut -f5)" = acted ] && ok || bad "AT-5 row: $(cat "$T/ledger")"
reset
DPC_OUT=10000 act p 1000 pool close-parent 1000 "every child closed"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && ok || bad "AT-5b rc=$RC out=[$OUT], want skipped"
[ "$(row 1000 close-parent | cut -f4,5)" = "decompose-parent-close declined	skipped" ] && ok || bad "AT-5b row: $(cat "$T/ledger")"

# --- AT-6 -----------------------------------------------------------------------
reset
act p 1000 pool handoff-rebase BH-1 "dirty"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && ok || bad "AT-6 rc=$RC out=[$OUT]"
[ "$(wc -l < "$T/ledger")" = 1 ] && [ "$(row BH-1 handoff-rebase | cut -f4,5)" = "dirty @abc111; owner rebase-train	skipped" ] \
  && ok || bad "AT-6 ledger: $(cat "$T/ledger")"
[ ! -s "$T/req" ] && [ ! -s "$T/calls" ] && ok || bad "AT-6 made a call"

# --- AT-12 ----------------------------------------------------------------------
reset
SPLIT_WATCHDOG_FAMILY_DAY_CAP=1 act p 1000 pool enqueue BH-1 "no build"
[ "$OUT" = acted ] && ok || bad "AT-12 first out=[$OUT]"
SPLIT_WATCHDOG_FAMILY_DAY_CAP=1 act p 1000 pool enqueue BH-2 "no build"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && ok || bad "AT-12 second rc=$RC out=[$OUT], want skipped"
[ "$(nreq)" = 1 ] && ok || bad "AT-12 second made a queue call"
cr=$(row BH-2 skip-cap-family)
[ -n "$cr" ] && grep -q "day $(date -u +%F): 1 acted, cap 1" <<<"$cr" && [ "$(cut -f5 <<<"$cr")" = skipped ] \
  && ok || bad "AT-12 cap row: [$cr]"

# --- BOX / BOX-ON -----------------------------------------------------------------
reset
rq_on() { return 1; }
act p 1000 box enqueue BH-2 "no build"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && ok || bad "BOX rc=$RC out=[$OUT]"
[ ! -s "$T/req" ] && ok || bad "BOX made a request: $(cat "$T/req")"
[ "$(row BH-2 skip-no-fleet-path | cut -f5)" = skipped ] && ok || bad "BOX row: $(cat "$T/ledger")"
reset
rq_on() { return 0; }
act p 1000 box enqueue BH-2 "no build"
[ "$RC" = 0 ] && [ "$OUT" = acted ] && ok || bad "BOX-ON rc=$RC out=[$OUT]"
b=$(grep '^POST /api/queue' "$T/req" | cut -d' ' -f3-)
[ "$(nreq)" = 1 ] && [ "$(jq -r .status <<<"$b")" = ready ] && [ "$(jq -r .ticket_id <<<"$b")" = 102 ] \
  && [[ "$(jq -r '.meta|fromjson|.ready_line' <<<"$b")" == "BH-2 SPLIT-WATCHDOG enqueue [family #1000] no build" ]] \
  && ok || bad "BOX-ON body: $b"
act p 1000 box enqueue BH-2 "other"
[ "$OUT" = skipped ] && [ "$(row BH-2 skip-duplicate | cut -f5)" = skipped ] && ok || bad "BOX-ON duplicate out=[$OUT]"
unset -f rq_on

# --- FAILED / NOTID -----------------------------------------------------------------
reset; touch "$T/post_fail"
act p 1000 pool enqueue BH-2 "no build"
[ "$RC" = 0 ] && [ "$OUT" = failed ] && ok || bad "FAILED rc=$RC out=[$OUT], want failed"
[ "$(row BH-2 enqueue | cut -f5)" = failed ] && ok || bad "FAILED row: $(cat "$T/ledger")"
rm -f "$T/post_fail"
act p 1000 pool enqueue BH-2 "no build"
[ "$OUT" = acted ] && ok || bad "FAILED retry after a failed row out=[$OUT], want acted"
reset
act p 1000 pool enqueue BH-9 "no build"
[ "$OUT" = failed ] && [ "$(nreq)" = 0 ] && [ "$(row BH-9 enqueue | cut -f4,5)" = "no build (no ticket id)	failed" ] \
  && ok || bad "NOTID out=[$OUT] posts=$(nreq) ledger=$(cat "$T/ledger" 2>/dev/null)"

# --- OUTAGE ---------------------------------------------------------------------
for step in enqueue owed-completion close-parent handoff-rebase; do
  reset; touch "$T/sw_outage"
  DPC_OUT=1000 act p 1000 pool "$step" BH-2 "no build"
  [ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "OUTAGE $step rc=$RC out=[$OUT], want rc 1 and nothing"
  [ ! -s "$T/req" ] && [ ! -s "$T/calls" ] && ok || bad "OUTAGE $step made a call"
done
reset
sw_actions_today() { echo abc; }
act p 1000 pool enqueue BH-2 "no build"
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ ! -s "$T/req" ] && ok || bad "OUTAGE non-numeric day count rc=$RC out=[$OUT]"
sw_actions_today() { [ -e "$T/sw_outage" ] && return 1; awk -F'\t' -v f="${2:-}" '$1==f&&$5=="acted"{n++}END{print n+0}' "$T/ledger" 2>/dev/null; }

reset; touch "$T/seen_fail_stalled"
act p 1000 pool enqueue BH-2 "no build"
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ ! -s "$T/req" ] && [ ! -s "$T/ledger" ] && ok || bad "OUTAGE stall-gate read rc=$RC out=[$OUT]"

# --- CRASH ----------------------------------------------------------------------
reset; touch "$T/record_fail"
act p 1000 pool enqueue BH-2 "no build"
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(nreq)" = 1 ] && ok || bad "CRASH rc=$RC out=[$OUT] posts=$(nreq)"
act p 1000 pool enqueue BH-2 "no build"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && [ "$(wc -l < "$T/queue")" = 1 ] && ok || bad "CRASH next rc=$RC out=[$OUT]"
[ -z "$(awk -F'\t' '$5=="acted"' "$T/ledger")" ] && ok || bad "CRASH recorded acted for a duplicate"

# --- unknown step / route ---------------------------------------------------------
reset
act p 1000 pool frobnicate BH-2 "x"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && [ ! -s "$T/ledger" ] && [ ! -s "$T/req" ] && ok || bad "UNKNOWN step rc=$RC out=[$OUT]"
act p 1000 moon enqueue BH-2 "x"
[ "$RC" = 0 ] && [ "$OUT" = skipped ] && [ ! -s "$T/ledger" ] && [ ! -s "$T/req" ] && ok || bad "UNKNOWN route rc=$RC out=[$OUT]"

# --- NOFLOCK ----------------------------------------------------------------------
[ -z "$(grep -v '^[[:space:]]*#' "$DIR/bin/lib/split-watchdog-act.sh" | grep -w flock)" ] && ok || bad "NOFLOCK: lib uses flock"

[ ! -e "$T/POISON" ] && ok || bad "POISON: $(cat "$T/POISON")"
echo "split-watchdog-act.bh-1809: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
