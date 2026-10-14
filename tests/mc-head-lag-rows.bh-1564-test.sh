#!/bin/bash
# tests/mc-head-lag-rows.bh-1564-test.sh — the head-lag record (BH-1529) is
# `headlag` rows in pr_attempts, with the state file only a read-through cache,
# so a wiped state dir cannot buy a tip a second close/reopen or a second page;
# and a HELD verdict is cached per tip (BH-1564).
#
# THE DEFECT THIS PINS. state/merge-conductor/head-lag/<pr> lived on one box. A
# wiped state dir, a hub move or the 3-day GC lost it, and a PR still lagging on
# the same tip then got a fresh clock, a SECOND close/reopen and a SECOND ALERTS
# page. And a held PR that kept lagging re-read both holds on every tick.
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh, with gh stubbed and the jobs
# worker a curl shim that keeps a real pr_attempts store (PUT inserts once per
# (repo, number, kind, sha), GET with a sha is 200/404, GET without one lists
# the rows, `worker-down` makes every pr-attempts call a 503). PR #91's list
# head is OLD91; its branch tip is whatever $T/tip91 says. Sections:
#   A. the first sighting of a lag writes a `seen` row;
#   B. past the window: one close/reopen, and its `try` row is written BEFORE
#      the close goes out;
#   C. the whole conductor state dir is wiped: the record comes back from the
#      rows and the tip is NOT closed and reopened again;
#   D. the one page survives a second wipe: it is not written twice;
#   E. the 3-day GC dropping only the head-lag file re-arms nothing;
#   F. a HELD verdict is asked once per tip per MC_HEAD_LAG_HELD_RECHECK_MINS,
#      even across a wipe, and a lifted hold still gets its kick;
#   G. the worker down after a real kick, with the state file wiped: the tick
#      writes NO file, NO row and makes NO kick decision (BH-1891 — an outage
#      used to read as "never kicked" and bought the tip a second reopen), the
#      rows latch off after ONE failed request, and once the worker answers the
#      rows restore the record with no second close/reopen;
#   H. the flag down: not one pr-attempts request, and the file alone still
#      kicks exactly once — BH-1529's behaviour;
#   I. pr_attempt_list, the one new client verb: rc 0 lines / rc 2 none /
#      rc 1 outage with nothing printed;
#   J. mc_attempt_rows' rc contract (BH-1891): rc 1 rows not in use (flag
#      down) | rc 2 measured none | rc 0 rows | rc 3 the worker could not
#      answer — this call, this process's earlier trip, or this tick's latch.
#
# Run from anywhere: tests/mc-head-lag-rows.bh-1564-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The open-PR list is REST (BH-1585); this bridge answers those reads from the
# GraphQL-shaped list the gh stub below prints.
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/fakebin" "$T/repos/demo-os/.git"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

# FIXTURE shas: short, fake, and never a real commit.
OLD91=aaaa0091aaaa; NEW91=bbbb0091bbbb
SEQ="$T/seq.log"      # rows and closes, in the order they happened
STORE="$T/rows.tsv"   # the fake pr_attempts table: repo number kind sha
REQ="$T/req.log"      # every jobs-worker request: METHOD URL
: > "$SEQ"; : > "$STORE"; : > "$REQ"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
ARGS="\$*"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/"*" -f state=closed"*)
    printf 'GH %s\n' "\$*" >> "$SEQ"; printf '%s\n' "\$*" >> "$T/kicks.txt"; exit 0 ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/"*" -f state="*)
    printf 'GH %s\n' "\$*" >> "$SEQ"; printf '%s\n' "\$*" >> "$T/kicks.txt"; exit 0 ;;
  *"api -i -X PATCH"*|*"api -i -X POST"*|*"pr merge"*|*"pr edit"*|*"pr close"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -i -X GET repos/example-org/demo-os/branches/ticket/TK-91"|*"api -i -X GET repos/example-org/demo-os/branches/ticket/TK-91 "*)
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/tip91")" '{name:"ticket/TK-91",commit:{sha:\$s}}' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/"*) restpr OPEN x ticket/pb-9x main ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<J
[{"number":91,"url":"https://github.com/example-org/demo-os/pull/91","headRefOid":"$OLD91","headRefName":"ticket/TK-91","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main","isCrossRepository":false}]
J
    ;;
  *"api repos/example-org/demo-os/pulls/91") restpr OPEN x ticket/TK-91 main | tail -1 ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) printf 'in_progress|\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '%s' "$NEW91" > "$T/tip91"

command -v flock >/dev/null || { printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

# The jobs worker. Only /api/pr-attempts is real; everything else is a 404,
# which is what the BH-1529 suite answers too (a flag read that 404s leaves
# the flag FILE standing).
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL=""; METHOD=GET; BODY=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) METHOD="\$2"; shift 2 ;;
    --data-binary) BODY="\$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w) shift 2 ;;
    -*) shift ;;
    *) URL="\$1"; shift ;;
  esac
done
case "\$URL" in */api/pr-attempts*) : ;; *) printf '{"error":"not found"}\n404\n'; exit 0 ;; esac
printf '%s %s\n' "\$METHOD" "\$URL" >> "$REQ"
[ -f "$T/worker-down" ] && { printf '{"error":"down"}\n503\n'; exit 0; }
qv() { local v; v=\$(printf '%s' "\$URL" | sed -n "s/.*[?&]\$1=\\([^&]*\\).*/\\1/p"); printf '%b' "\${v//%/\\\\x}"; }
if [ "\$METHOD" = PUT ]; then
  row=\$(printf '%s' "\$BODY" | jq -r '[.repo, (.number|tostring), .kind, .sha] | @tsv')
  [ "\$(printf '%s' "\$BODY" | jq -r .kind)" = headlag ] && printf 'ROW %s\n' "\$(printf '%s' "\$BODY" | jq -r .sha)" >> "$SEQ"
  if grep -qxF "\$row" "$STORE"; then printf '{"duplicate":true}\n200\n'; else printf '%s\n' "\$row" >> "$STORE"; printf '{"recorded":true}\n201\n'; fi
  exit 0
fi
R=\$(qv repo); N=\$(qv number); K=\$(qv kind); S=\$(qv sha)
if [ "\$METHOD" = GET ] && [ -z "\$S" ]; then
  awk -F'\t' -v r="\$R" -v n="\$N" -v k="\$K" '\$1==r && \$2==n && (k=="" || \$3==k) {print \$4}' "$STORE" \
    | jq -Rn '[inputs | {sha: .}] | {attempts: ., count: length}'
  printf '200\n'; exit 0
fi
if grep -qxF "\$(printf '%s\t%s\t%s\t%s' "\$R" "\$N" "\$K" "\$S")" "$STORE"; then
  printf '{"attempt":{}}\n200\n'
else
  printf '{"error":"not found"}\n404\n'
fi
exit 0
EOF
chmod +x "$T/fakebin/curl"

printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/pr-state-rows"

run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
  MC_REPOS="$T/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 \
  MC_PR_PARALLEL=1 MC_HEAD_LAG_MINS=10 MC_HEAD_LAG_HELD_RECHECK_MINS=60 \
  env "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
  || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
LOG="$T/h/logs/merge-conductor.log"
ALERTS="$T/h/logs/ALERTS.log"
MCSTATE="$T/h/state/merge-conductor"
LAGF="$MCSTATE/head-lag/example-org_demo-os_91"

# rows_of <tip> — the facts the store holds for that tip, "fact [n…]" per line.
rows_of() { awk -F'\t' -v t="$1" '$2=="91" && $3=="headlag" { split($4, a, " "); if (a[1]==t) { sub(/^[^ ]+ /, "", $4); print $4 } }' "$STORE"; }
# backdate <secs> [col…] — move the clock back: every epoch in the head-lag
#   rows, and the named columns of the state file (default: since, spent, held).
backdate() {
  local s="$1"; shift
  awk -F'\t' -v OFS='\t' -v s="$s" '$3=="headlag" { n=split($4, a, " ")
      if (a[2]=="seen" || a[2]=="held" || a[2]=="gaveup") a[2+1]-=s
      if (a[2]=="try") a[4]-=s
      $4=a[1]; for (i=2; i<=n; i++) $4=$4" "a[i] } { print }' "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE"
  [ -f "$LAGF" ] || return 0
  awk -F'\t' -v OFS='\t' -v s="$s" -v cols="${*:-3 4 8}" 'BEGIN { split(cols, c, " ") }
      { for (i in c) if ($c[i] > 0) $c[i]-=s; print }' "$LAGF" > "$LAGF.t" && mv "$LAGF.t" "$LAGF"
}
kicks_of() { grep -c "pulls/91 -f state=$1" "$T/kicks.txt" 2>/dev/null || true; }
alerts_91() { grep -c 'demo-os#91 .*HEAD_LAG' "$ALERTS" 2>/dev/null || true; }
wipe() { scratch_rm "$MCSTATE"; }
: > "$T/kicks.txt"; : > "$T/gh-writes.txt"

# ============================================================================
# A. THE FIRST SIGHTING IS A ROW: `seen <epoch>` for this tip.
# ============================================================================
run_tick
rows_of "$NEW91" | grep -qE '^seen [0-9]+$' \
  && ok || bad "A: the first sighting of a lag must write a 'seen' row (rows: $(rows_of "$NEW91" | tr '\n' ','))"
[ -f "$LAGF" ] && [ "$(cut -f2 "$LAGF")" = "$NEW91" ] \
  && ok || bad "A: the state file must still be written, as the cache (got: $(cat "$LAGF" 2>/dev/null))"

# ============================================================================
# B. PAST THE WINDOW: one close/reopen; the `try` row goes out BEFORE the close.
# ============================================================================
backdate 700
run_tick
[ "$(kicks_of closed)" = 1 ] && [ "$(kicks_of open)" = 1 ] \
  && ok || bad "B: the lagging PR must be closed and reopened exactly once (kicks: $(cat "$T/kicks.txt"))"
rows_of "$NEW91" | grep -qE '^try 1 [0-9]+$' && rows_of "$NEW91" | grep -qx reopened \
  && ok || bad "B: the kick must leave a 'try 1' and a 'reopened' row (rows: $(rows_of "$NEW91" | tr '\n' ','))"
TRYL=$(grep -n "^ROW $NEW91 try 1 " "$SEQ" | head -1 | cut -d: -f1)
CLOSEL=$(grep -n '^GH .*pulls/91 -f state=closed' "$SEQ" | head -1 | cut -d: -f1)
[ -n "$TRYL" ] && [ -n "$CLOSEL" ] && [ "$TRYL" -lt "$CLOSEL" ] \
  && ok || bad "B: the 'try' row must be written BEFORE the close (try line ${TRYL:-none}, close line ${CLOSEL:-none}): $(cat "$SEQ")"

# ============================================================================
# C. THE WHOLE CONDUCTOR STATE DIR IS WIPED (a hub restart onto a fresh disk):
#    the record comes back from the rows and the tip is not reopened again —
#    not on the next tick, and not after another full window either.
# ============================================================================
wipe
run_tick
grep -q "demo-os#91 head-lag record for ${NEW91:0:8} read back from its rows (kick outcome: reopened)" "$LOG" \
  && ok || bad "C: after a wipe the record must be read back from the rows (log: $(grep 'demo-os#91' "$LOG" | tail -2))"
[ "$(cut -f6 "$LAGF" 2>/dev/null)" = reopened ] && [ "$(cut -f4 "$LAGF" 2>/dev/null)" != 0 ] \
  && ok || bad "C: the rows must warm the file back as spent/reopened (file: $(cat "$LAGF" 2>/dev/null))"
backdate 700 3
run_tick
[ "$(kicks_of closed)" = 1 ] && [ "$(kicks_of open)" = 1 ] \
  && ok || bad "C: a wiped state dir must not buy the tip a SECOND close/reopen (kicks: $(cat "$T/kicks.txt"))"

# ============================================================================
# D. THE ONE PAGE SURVIVES A WIPE.
# ============================================================================
backdate 700
run_tick
[ "$(alerts_91)" = 1 ] && ok || bad "D: a lag that outlives the reopen must page once (ALERTS: $(cat "$ALERTS" 2>/dev/null))"
rows_of "$NEW91" | grep -qx alerted && ok || bad "D: the page must leave an 'alerted' row (rows: $(rows_of "$NEW91" | tr '\n' ','))"
wipe
run_tick; backdate 700; run_tick
[ "$(alerts_91)" = 1 ] && ok || bad "D: a wiped state dir must not page the same tip twice (ALERTS: $(cat "$ALERTS" 2>/dev/null))"
[ "$(kicks_of closed)" = 1 ] && ok || bad "D: nor reopen it (kicks: $(cat "$T/kicks.txt"))"

# ============================================================================
# E. THE 3-DAY GC DROPS ONLY THE FILE (F4 of the #1562 review): nothing re-arms.
# ============================================================================
rm -f "$LAGF"
run_tick; backdate 700; run_tick
[ "$(kicks_of closed)" = 1 ] && [ "$(alerts_91)" = 1 ] \
  && ok || bad "E: a GC'd state file must not re-arm the kick or the page (kicks: $(kicks_of closed), alerts: $(alerts_91))"

# ============================================================================
# F. THE HELD VERDICT IS CACHED PER TIP. A new push (tip C91) lags past the
#    window while its ticket is held. The hold is asked once, not every tick,
#    and not again after a wipe; it is asked again once the recheck window has
#    passed; and a lifted hold gets its kick.
# ============================================================================
C91=cafe0091cafe
printf '%s' "$C91" > "$T/tip91"
run_tick
backdate 700
printf 'to_lane_hold() { [ "$3" = 91 ] && { echo "$2#$3 held" >> "%s/holds.txt"; return 0; }; return 1; }\n' "$T" \
  > "$T/h/bin/lib/ticket-ownership.sh"
: > "$T/holds.txt"
run_tick; run_tick; run_tick
[ "$(wc -l < "$T/holds.txt" | tr -d ' ')" = 1 ] \
  && ok || bad "F: a held tip must be asked about its hold once, not every tick (asked $(wc -l < "$T/holds.txt") times)"
[ "$(kicks_of closed)" = 1 ] && ok || bad "F: a held PR must not be closed (kicks: $(cat "$T/kicks.txt"))"
rows_of "$C91" | grep -qE '^held [0-9]+$' && ok || bad "F: the held verdict must be a row (rows: $(rows_of "$C91" | tr '\n' ','))"
wipe
run_tick; run_tick
[ "$(wc -l < "$T/holds.txt" | tr -d ' ')" = 1 ] \
  && ok || bad "F: the cached verdict must survive a wipe (asked $(wc -l < "$T/holds.txt") times)"
backdate 3700 8
run_tick
[ "$(wc -l < "$T/holds.txt" | tr -d ' ')" = 2 ] \
  && ok || bad "F: past MC_HEAD_LAG_HELD_RECHECK_MINS the hold must be asked again, once (asked $(wc -l < "$T/holds.txt") times)"
printf 'to_lane_hold() { return 1; }\n' > "$T/h/bin/lib/ticket-ownership.sh"
backdate 3700 8
run_tick
[ "$(kicks_of closed)" = 2 ] && rows_of "$C91" | grep -qE '^try 1 [0-9]+$' \
  && ok || bad "F: a lifted hold must get its kick (kicks: $(kicks_of closed), rows: $(rows_of "$C91" | tr '\n' ','))"

# ============================================================================
# G. THE WORKER DOWN AFTER A REAL KICK (BH-1891). A fresh tip D91 is closed and
#    reopened once with the worker up. Then the state dir is wiped and the
#    worker goes down: the outage must not read as "never kicked". The down
#    ticks write no file and no row and make no kick decision, even past the
#    window; once the worker answers, the rows put the record back and the tip
#    is not closed and reopened a second time.
# ============================================================================
D91=dead0091dead
printf '%s' "$D91" > "$T/tip91"
K0=$(kicks_of closed)
run_tick; backdate 700; run_tick
[ "$(kicks_of closed)" = "$((K0 + 1))" ] && rows_of "$D91" | grep -qE '^try 1 [0-9]+$' && rows_of "$D91" | grep -qx reopened \
  && ok || bad "G: setup — D91 must be kicked once with the worker up (kicks: $(kicks_of closed), was $K0; rows: $(rows_of "$D91" | tr '\n' ','))"
K1=$(kicks_of closed)
wipe; touch "$T/worker-down"; : > "$REQ"
run_tick
[ "$(grep -c 'pr-attempts' "$REQ" || true)" = 1 ] \
  && ok || bad "G: after one failed request the rows are latched off for the tick (requests: $(cat "$REQ"))"
backdate 700
run_tick
[ ! -e "$LAGF" ] && ok || bad "G: with the worker down no head-lag file may be written (file: $(cat "$LAGF" 2>/dev/null))"
[ "$(kicks_of closed)" = "$K1" ] && ok || bad "G: with the worker down no kick may be made (kicks: $(kicks_of closed), was $K1)"
grep -q "demo-os#91 head-lag record for ${D91:0:8} not read: pr-state-rows unreachable" "$LOG" \
  && ok || bad "G: an unreadable record must be logged as such (log: $(grep 'demo-os#91' "$LOG" | tail -2))"
[ "$(rows_of "$D91" | grep -c '^seen' || true)" = 1 ] \
  && ok || bad "G: no second 'seen' row for the tip (rows: $(rows_of "$D91" | tr '\n' ','))"
rm -f "$T/worker-down"
run_tick
grep -q "demo-os#91 head-lag record for ${D91:0:8} read back from its rows (kick outcome: reopened)" "$LOG" \
  && ok || bad "G: once the worker answers the record must be read back from the rows (log: $(grep 'demo-os#91' "$LOG" | tail -2))"
[ "$(cut -f2 "$LAGF" 2>/dev/null)" = "$D91" ] && [ "$(cut -f6 "$LAGF" 2>/dev/null)" = reopened ] \
  && ok || bad "G: the rows must restore the file as $D91/reopened (file: $(cat "$LAGF" 2>/dev/null))"
backdate 700; run_tick
[ "$(kicks_of closed)" = "$K1" ] && ok || bad "G: the outage must not buy the tip a SECOND close/reopen (kicks: $(kicks_of closed), was $K1)"

# ============================================================================
# H. THE FLAG DOWN: no pr-attempts request at all, and the file alone still
#    closes and reopens the tip exactly once (BH-1529 unchanged).
# ============================================================================
rm -f "$T/h/flags/pr-state-rows"
F91=f1a90091f1a9
printf '%s' "$F91" > "$T/tip91"
wipe; : > "$REQ"
K0=$(kicks_of closed)
run_tick; backdate 700; run_tick; run_tick
[ -s "$REQ" ] && bad "H: with pr-state-rows down no pr-attempts request may be made: $(cat "$REQ")" || ok
[ "$(kicks_of closed)" = "$((K0 + 1))" ] \
  && ok || bad "H: with the flag down the file alone must kick exactly once (kicks: $(kicks_of closed), was $K0)"
touch "$T/h/flags/pr-state-rows"

# ============================================================================
# I. pr_attempt_list — rc 0 and the shas | rc 2 none | rc 1 an outage, silent.
# ============================================================================
drv() { PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
  bash -c '. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90; pr_attempt_list "$@"' _ "$@"; }
OUT=$(drv example-org/demo-os 91 headlag); RC=$?
[ "$RC" = 0 ] && grep -qx "$NEW91 reopened" <<<"$OUT" \
  && ok || bad "I: pr_attempt_list must print every sha of the kind at rc 0 (rc=$RC out=$OUT)"
OUT=$(drv example-org/demo-os 91 no-such-kind); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "I: no rows must be rc 2 and silent (rc=$RC out=$OUT)"
touch "$T/worker-down"
OUT=$(drv example-org/demo-os 91 headlag); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "I: an outage must be rc 1 and print nothing (rc=$RC out=$OUT)"
rm -f "$T/worker-down"
OUT=$(drv example-org/demo-os x headlag); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "I: a non-numeric PR number must be refused (rc=$RC out=$OUT)"

# ============================================================================
# J. mc_attempt_rows' rc contract (BH-1891): the worker being unreachable is
#    rc 3, never the flag-down rc 1, so the caller cannot read it as "no row".
# ============================================================================
jdrv() { env -u MC_TICK_ID PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.invalid \
  JOBS_RETRIES=0 MC_H="$T/h" MC_STATE_DIR="$T/jstate" MC_LOG="$T/j.log" "$@" \
  bash -c '. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
    . "$HARNESS/bin/lib/mc/locks.sh" >/dev/null 2>&1 || exit 91
    type mc_log >/dev/null 2>&1 || mc_log() { :; }
    eval "$J"'; }
JO="$T/j.out"
J='mc_attempt_rows headlag example-org/demo-os#91 "$JO"; echo "rc=$?"'
rm -f "$T/h/flags/pr-state-rows"
R=$(jdrv J="$J" JO="$JO"); [ "$R" = rc=1 ] && ok || bad "J: the flag down must be rc 1 ($R)"
touch "$T/h/flags/pr-state-rows" "$T/worker-down"
R=$(jdrv J="$J" JO="$JO"); [ "$R" = rc=3 ] && [ ! -s "$JO" ] \
  && ok || bad "J: the worker down must be rc 3 with an empty out-file ($R, out: $(cat "$JO"))"
rm -f "$T/worker-down"
R=$(jdrv J='mc_attempt_rows no-such-kind example-org/demo-os#91 "$JO"; echo "rc=$?"' JO="$JO")
[ "$R" = rc=2 ] && ok || bad "J: no rows must be rc 2 ($R)"
R=$(jdrv J="$J" JO="$JO"); [ "$R" = rc=0 ] && grep -q "^$NEW91 " "$JO" \
  && ok || bad "J: rows must be rc 0 with the shas in the out-file ($R, out: $(cat "$JO"))"
R=$(touch "$T/worker-down"; jdrv J='mc_attempt_rows headlag example-org/demo-os#91 "$JO"; a=$?; rm -f "$WD"
  mc_attempt_rows headlag example-org/demo-os#91 "$JO"; echo "rc=$a,$?"' JO="$JO" WD="$T/worker-down")
[ "$R" = rc=3,3 ] && ok || bad "J: a process that already tripped must answer rc 3, not rc 1 ($R)"
rm -f "$T/worker-down"
mkdir -p "$T/jstate/tick" && : > "$T/jstate/tick/t1.pr-rows-down"; : > "$REQ"
R=$(jdrv J="$J" JO="$JO" MC_TICK_ID=t1); [ "$R" = rc=3 ] && [ ! -s "$REQ" ] \
  && ok || bad "J: a tick already latched down must be rc 3 with no request ($R, requests: $(cat "$REQ"))"

[ -s "$T/gh-writes.txt" ] && bad "nothing else may be written: $(cat "$T/gh-writes.txt")" || ok

echo "mc-head-lag-rows.bh-1564-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
