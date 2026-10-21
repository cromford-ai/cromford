#!/bin/bash
# tests/fly-pool-decide-all.bh-7706-test.sh — one pool tick decides every queued
# row, and the eligible rows decide and spawn in parallel (BH-7706). On the hub a
# project-6-os tick decided 26 of 126 rows before POOL_TICK_BUDGET_S stopped the
# walk: each row's hold-thread read ran in series, and the shared reads (file
# claims, the jobs queue) ran once per row.
#
#   A1  120 rows (60 clear, 20 `.after` a claimed key, 20 sibling parts behind a
#       claimed sibling, 20 held), a 0.5 s hold-thread read, a 30 s budget: every
#       row has its decision line, no budget line, and the shared reads are made
#       once: 1 PR listing, 1 hold listing, 1 file-claims read, at most 2 queue
#       listings, 0 per-key queue reads, 0 per-key PR reads
#   A2  20 clear rows with a 2 s hold-thread read: the reads add less than 3
#       serial reads (6 s) at the default parallel; the hold-cache line is exact
#   A3  pool cap 3, 10 clear rows: 3 spawn, rows 4-10 are never decided
#   A4  per-key cap 12: K1 (11 in window, two queue files) spawns once and its
#       .spawns holds 12; K2 (12) logs the cap line and does not spawn; every
#       spawn gets its own env bundle dir
#   A5  hotfix: budget 0 + one hotfix -> the hotfix spawns past the cap and no
#       plain row is decided; budget 1 -> the hotfix takes the plain slot
#   A6  the skip reasons stay; the queue map answers queued / claimed / absent,
#       and a truncated or failed listing falls back to the per-key read
#   A7  a 3 s budget with 2 s reads: dispatch stops, the budget line is said
#       once, every started row spawns, the rest stay queued
#   A8  a decision worker that dies with no verdict: one line, its row stays
#       queued, the other rows spawn
#   A9  POOL_DECIDE_PARALLEL=1: rows are decided one at a time in queue order;
#       no temp dir is left after any case
#   A10 no repo slug: the spawn-gates-inactive line is said once, not per worker
#
# Driven through the real bin/fly-pool.sh against a scratch HARNESS, a fake
# flyctl, a fake gh (REST) and a fake curl that plays the jobs worker. No real
# vendor is called.
# determinism: ok-file the A2/A7 timings are the thing under test (a stub read that sleeps against a wall-clock bound); every other value is fixed.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# ONE clock read for the file: the per-key cap counts spawns against the wall clock.
NOW=$(date -u +%s)

H="$T/h"
QD="$H/state/build-queue/project-5"; MD="$H/state/fly-pool/project-5"; PD="$H/state/pool/project-5"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$H/plans" \
         "$H/state/fly" "$MD" "$QD" "$PD" "$H/state/remote-results/project-5" \
         "$H/builds" "$T/fakebin" "$T/tmp"
printf 'FLY_API_TOKEN_project-5=tok-fixture-fly\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

# The alert stub is written BEFORE the closure installs, which never clobber it.
printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
for L in bin/pool-cap.sh bin/jobs-client.sh bin/lib/flags.sh bin/lib/hold.sh bin/lib/pool-hold-cache.sh bin/sibling-serial.sh; do
  scratch_install_closure "$L" "$H" >/dev/null || { echo "closure install of $L failed"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
# Each spawn's env bundle dir is recorded: parallel spawns must never share one.
printf '#!/bin/bash\necho "$2" >> "%s/bundles"\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' "$T" > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
# flyctl: `machine run` answers an id unique to the call (its own pid), so two
# parallel spawns never share a pool json.
cat > "$T/fakebin/fly" <<'FLY'
#!/bin/bash
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 41%012d\n' "$$" ;;
esac
exit 0
FLY

# The jobs worker. Every request URL goes to $T/jobs-calls.
#   /api/queue?...&key=<K>...   the per-key read (queue_status): $T/qstate
#   /api/queue?...status=<S>... a listing: every $T/qstate row with status S;
#                               QMODE=fail answers 500, QMODE=full 500 rows
#   /api/file-claims?...        the claims in $T/claims.json, else none
#   anything else               404 (no row, no setting): every reader falls back
cat > "$T/fakebin/curl" <<CURL
#!/bin/bash
T=$(printf '%q' "$T")
CURL
cat >> "$T/fakebin/curl" <<'CURL'
URL="${!#}"
echo "$URL" >> "$T/jobs-calls"
qrows() { # qrows <status|-> -> the queue array from $T/qstate ("<key> <status>" lines)
  awk -v s="$1" '$1 != "" && (s == "-" || $2 == s) {printf "%s%s\t%s", (n++ ? "\n" : ""), $1, $2}' "$T/qstate" 2>/dev/null \
    | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {project:"project-5", ticket_key:.[0], ticket_id:"1", status:.[1], target:"fly", attempt:0})'
}
case "$URL" in
  */api/queue\?*key=*)
    k=$(printf '%s' "$URL" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')
    st=$(awk -v k="$k" '$1 == k {print $2; exit}' "$T/qstate" 2>/dev/null)
    if [ -n "$st" ]; then jq -nc --arg k "$k" --arg s "$st" '{queue:[{project:"project-5",ticket_key:$k,status:$s,target:"fly"}]}'
    else echo '{"queue":[]}'; fi
    printf '\n200' ;;
  */api/queue\?*status=*)
    case "${QMODE:-ok}" in
      fail) printf '{"error":"fixture outage"}\n500'; exit 0 ;;
      full) jq -nc '{queue:[range(0;500) | {project:"project-5", ticket_key:("ZZ-\(.)"), status:"queued", target:"fly"}]}'; printf '\n200'; exit 0 ;;
    esac
    s=$(printf '%s' "$URL" | sed -n 's/.*[?&]status=\([^&]*\).*/\1/p')
    jq -nc --argjson q "$(qrows "$s")" '{queue:$q}'; printf '\n200' ;;
  */api/file-claims\?*)
    if [ -s "$T/claims.json" ]; then cat "$T/claims.json"; else echo '{"claims":[]}'; fi
    printf '\n200' ;;
  *) printf '{"error":"not found"}\n404' ;;
esac
exit 0
CURL

# gh (REST). The repo probe answers 200. Logs: $T/bulk-reads (the open-PR
# listing), $T/pr-reads (a per-key PR read), $T/hold-list (the ai-build issue
# listing), $T/thread-reads (one line per hold-thread read, the ticket number).
#   $T/hold-s      seconds one hold-thread read takes (default 0)
#   $T/held        ticket numbers whose issue carries the `hold` label
#   $T/special.json  PRs on page 1 of the open-PR listing
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
T=$(printf '%q' "$T")
GH
cat >> "$T/fakebin/gh" <<'GH'
if [[ "$*" == *"pulls?state=open&per_page=100"* ]]; then
  echo "$*" >> "$T/bulk-reads"
  sp='[]'; [ -f "$T/special.json" ] && sp=$(cat "$T/special.json")
  printf 'HTTP/1.1 200 OK\n\n%s\n' "$sp"; exit 0
fi
if [[ "$*" == *"pulls?state=open"*"head="* ]]; then
  echo "$*" >> "$T/pr-reads"; printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0
fi
if [[ "$*" == *"issues?state=open&labels=ai-build"* ]]; then
  echo "$*" >> "$T/hold-list"; printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0
fi
if [[ "$*" == *"--paginate"*"issues/"*"/comments"* ]]; then
  n=$(printf '%s' "$*" | sed -n 's/.*issues\/\([0-9]*\)\/comments.*/\1/p')
  echo "$n" >> "$T/thread-reads"
  s=$(cat "$T/hold-s" 2>/dev/null); [ -n "$s" ] && /bin/sleep "$s"
  echo '[]'; exit 0
fi
if [[ "$*" == *"/comments"* ]]; then exit 0; fi
if [[ "$*" == *"issues/"* ]] && [[ "$*" != *" -i "* ]]; then
  n=$(printf '%s' "$*" | sed -n 's/.*issues\/\([0-9]*\).*/\1/p')
  if grep -qx "$n" "$T/held" 2>/dev/null; then
    echo '{"state":"open","labels":[{"name":"ai-build"},{"name":"hold"}],"title":"t","body":""}'
  else
    echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"t","body":""}'
  fi
  exit 0
fi
if [[ "$*" == *" -i "* ]]; then
  if [[ "$*" == *"repos/example-org/project-5" ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
exit 0
GH
chmod +x "$H/bin/"*.sh "$T/fakebin"/*

ROWS=0
reset_state() {
  local p
  for p in "$QD"/* "$MD"/* "$PD"/* "$H/plans"/* "$H/state/sibling-serial" "$H"/flags/alerted-* \
           "$H/bin/lib/pool-actor-gate.sh" "$T/tmp"/* \
           "$T/jobs-calls" "$T/bulk-reads" "$T/pr-reads" "$T/hold-list" "$T/thread-reads" \
           "$T/hold-s" "$T/held" "$T/special.json" "$T/qstate" "$T/claims.json" "$T/bundles" "$T/alert-calls"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  printf '0\n' > "$H/flags/fly-pool-project-5"
  ROWS=0
  return 0
}
# q <key> <ticket> [extra-json] — one queue file; each one a second newer than the
# last, so `ls -tr` (the walk order) is the order the case wrote them in.
q() {
  local f="$QD/$1.json"
  jq -nc --arg k "$1" --arg t "$2" --argjson x "${3:-{\}}" \
    '{ticket_id:$t,key:$k,attempt:0,deferrals:0,deaths:0,enqueued_at:"2026-10-20T14:00:00Z"} + $x' > "$f"
  ROWS=$((ROWS + 1))
  touch -d "@$((1791000000 + ROWS))" "$f"
}
run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" \
           FLY_API_TOKEN_project-5=tok-fixture-fly FLY_BIN_DIR="$T/fakebin" \
           JOBS_URL=http://jobs.fixture.test HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
LOGF="$H/logs/fly-pool.log"
count() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
spawned_n() { count '\] spawned .* for ' "$LOGF"; }
spawned_key() { grep -q "\] spawned [^ ]* for $1 (" "$LOGF"; }
leftover_tmp() { find "$T/tmp" -mindepth 1 -maxdepth 1 \( -name 'pool-decide.*' -o -name 'sibling-tick.*' \) 2>/dev/null | wc -l | tr -d ' '; }
ms_now() { date +%s%N | cut -c1-13; }

# ── A1: 120 rows, every one decided inside a 30 s budget, shared reads once ──
reset_state
for n in $(seq 1001 1060); do q "BH-$n" "$n"; done
printf 'BH-900 claimed\n' > "$T/qstate"
for n in $(seq 2001 2020); do q "BH-$n" "$n" '{"after":"BH-900"}'; done
jq -nc '{claims:[{ticket_id:"BH-500.0", files_claimed_at:"2026-10-20T13:00:00Z", planned_files:"src/x.ts"}]}' > "$T/claims.json"
for n in $(seq 1 20); do
  mkdir -p "$H/plans/project-5-BH-500.$n"; printf 'src/x.ts\n' > "$H/plans/project-5-BH-500.$n/planned-files.txt"
  q "BH-500.$n" "$((5000 + n))"
done
for n in $(seq 3001 3020); do q "BH-$n" "$n"; echo "$n" >> "$T/held"; done
printf '0.5\n' > "$T/hold-s"
run_pool POOL_TICK_BUDGET_S=30
UND=""
for n in $(seq 1001 1060); do spawned_key "BH-$n" || UND="$UND BH-$n"; done
for n in $(seq 2001 2020); do grep -q "skipping BH-$n: waits for BH-900 (still in flight or its PR is open)" "$LOGF" || UND="$UND BH-$n"; done
for n in $(seq 1 20); do grep -q "SIBLING_SERIAL BH-500.$n waits for BH-500.0 on src/x.ts" "$LOGF" || UND="$UND BH-500.$n"; done
for n in $(seq 3001 3020); do grep -q "skipping BH-$n: HOLD" "$LOGF" || UND="$UND BH-$n"; done
[ -z "$UND" ] && ok || bad "A1: every queued row must have its decision line; missing for$(printf '%s' "$UND" | cut -c1-300)"
grep -q 'tick budget of 30s spent' "$LOGF" && bad "A1: 120 rows must be decided inside the 30 s budget: $(grep 'tick budget' "$LOGF")" || ok
[ "$(count . "$T/bulk-reads")" = 1 ] && ok || bad "A1: expected 1 open-PR listing, got $(count . "$T/bulk-reads")"
[ "$(count . "$T/hold-list")" = 1 ] && ok || bad "A1: expected 1 hold listing, got $(count . "$T/hold-list")"
[ "$(count '/api/file-claims' "$T/jobs-calls")" = 1 ] && ok || bad "A1: expected 1 file-claims read, got $(count '/api/file-claims' "$T/jobs-calls")"
# The decide prime's listings; `stale_min=` is the reap's own claimed-row read.
QL=$(grep '/api/queue?' "$T/jobs-calls" 2>/dev/null | grep -v 'key=' | grep -v 'stale_min=' | grep -c 'status=.*limit=500')
[ "${QL:-0}" -le 2 ] && ok || bad "A1: expected at most 2 queue listings, got $QL"
[ "$(count '/api/queue?.*key=' "$T/jobs-calls")" = 0 ] && ok || bad "A1: expected 0 per-key queue reads, got $(count '/api/queue?.*key=' "$T/jobs-calls")"
[ "$(count . "$T/pr-reads")" = 0 ] && ok || bad "A1: expected 0 per-key PR reads, got $(count . "$T/pr-reads")"
grep -q 'decide prime: queue=120 rows, after-blockers=1, queue-list=ok' "$LOGF" && ok || bad "A1: the prime line is missing or wrong: $(grep 'decide prime' "$LOGF")"
grep -q 'decided 120 of 120 queued rows in [0-9]*s (parallel [0-9]*); spawn started 60; not reached 0' "$LOGF" && ok \
  || bad "A1: the end-of-walk line must count 120 decided and 60 spawns: $(grep 'queued rows in' "$LOGF")"
grep -q 'hold cache: hits=0 misses=80 ' "$LOGF" && ok || bad "A1: the hold-cache line must count all 80 reads: $(grep 'hold cache' "$LOGF")"
[ "$(leftover_tmp)" = 0 ] && ok || bad "A1: the tick left $(leftover_tmp) temp dir(s)"
echo "A1 numbers: $(grep -o 'decided [0-9]* of [0-9]* queued rows.*' "$LOGF" | head -1); PR listings $(count . "$T/bulk-reads"), hold listings $(count . "$T/hold-list"), file-claims reads $(count '/api/file-claims' "$T/jobs-calls"), per-key queue reads $(count '/api/queue?.*key=' "$T/jobs-calls")"

# ── A2: 20 clear rows with a 2 s read: less than 3 serial reads of wall time ─
# The same tick with an instant read first: what the 20 reads ADD is the
# measure, so the box's own tick overhead does not count against it. In series
# they add 40 s.
reset_state
for n in $(seq 1001 1020); do q "BH-$n" "$n"; done
T0=$(ms_now); run_pool POOL_TICK_BUDGET_S=600; BASE=$(( $(ms_now) - T0 ))
reset_state
for n in $(seq 1001 1020); do q "BH-$n" "$n"; done
printf '2\n' > "$T/hold-s"
T0=$(ms_now)
run_pool POOL_TICK_BUDGET_S=600
WALL=$(( $(ms_now) - T0 ))
echo "A2 numbers: 20 rows with a 2 s read added $((WALL - BASE)) ms (tick ${WALL} ms, ${BASE} ms with an instant read)"
[ $((WALL - BASE)) -lt 6000 ] && ok || bad "A2: 20 eligible rows with a 2 s read added $((WALL - BASE)) ms (tick ${WALL} ms, ${BASE} ms with an instant read); 3 serial reads is 6000 ms"
[ "$(spawned_n)" = 20 ] && ok || bad "A2: expected 20 spawned lines, got $(spawned_n)"
grep -q 'hold cache: hits=0 misses=20 bad=0 ' "$LOGF" && ok || bad "A2: the folded hold-cache line must be exact: $(grep 'hold cache' "$LOGF")"
[ "$(count . "$T/thread-reads")" = 20 ] && ok || bad "A2: expected 20 thread reads, got $(count . "$T/thread-reads")"

# ── A3: pool cap 3, 10 clear rows: 3 spawn, rows 4-10 never decided ─────────
reset_state
printf '3\n' > "$H/flags/fly-pool-project-5"
for n in $(seq 1001 1010); do q "BH-$n" "$n"; done
run_pool
[ "$(spawned_n)" = 3 ] && ok || bad "A3: the pool cap of 3 holds, got $(spawned_n) spawns"
for n in 1001 1002 1003; do spawned_key "BH-$n" || bad "A3: BH-$n (row $((n - 1000))) must spawn"; done
[ "$(sort -n "$T/thread-reads" 2>/dev/null | tr '\n' ' ')" = "1001 1002 1003 " ] && ok \
  || bad "A3: only rows 1-3 may be decided, read: $(tr '\n' ' ' < "$T/thread-reads" 2>/dev/null)"

# ── A4: the per-key cap of 12 holds under parallel spawns ────────────────────
reset_state
for i in $(seq 1 11); do echo "$((NOW - 100 - i))"; done > "$PD/BH-41.spawns"
for i in $(seq 1 12); do echo "$((NOW - 100 - i))"; done > "$PD/BH-42.spawns"
q BH-41 41; q BH-42 42
jq -nc '{ticket_id:"41",key:"BH-41",attempt:0,deferrals:0,deaths:0}' > "$QD/BH-41-again.json"; touch -d "@1791000100" "$QD/BH-41-again.json"
for n in $(seq 1001 1006); do q "BH-$n" "$n"; done
run_pool POOL_SPAWN_CAP_PER_KEY=12
[ "$(count '\] spawned [^ ]* for BH-41 (' "$LOGF")" = 1 ] && ok || bad "A4: BH-41 has one slot under its cap: $(count '\] spawned [^ ]* for BH-41 (' "$LOGF") spawns"
[ "$(grep -c . "$PD/BH-41.spawns")" = 12 ] && ok || bad "A4: BH-41's .spawns must hold 12, holds $(grep -c . "$PD/BH-41.spawns")"
grep -q 'skipping BH-42: spawn cap reached (12 of 12 in 86400s)' "$LOGF" && ok || bad "A4: BH-42 must log the cap line: $(grep 'BH-42' "$LOGF" | head -3)"
spawned_key BH-42 && bad "A4: BH-42 is at its cap and must not spawn" || ok
[ "$(spawned_n)" = 7 ] && ok || bad "A4: BH-41 and the 6 plain rows spawn, got $(spawned_n)"
[ "$(sort -u "$T/bundles" | grep -c .)" = "$(grep -c . "$T/bundles")" ] && [ "$(grep -c . "$T/bundles")" = 7 ] && ok \
  || bad "A4: each of the 7 spawns needs its own env bundle dir: $(sort "$T/bundles" | uniq -c | tr '\n' ' ')"

# ── A5: the hotfix exemption under parallel decisions ────────────────────────
reset_state
printf '1\n' > "$H/flags/fly-pool-project-5"
jq -nc '{machine:"m0",key:"LV-0",ticket_id:"10",attempt:0,deferrals:0,deaths:0}' > "$MD/m0.json"
for n in 1001 1002 1003 1004; do q "BH-$n" "$n"; done
q BH-1099 1099 '{"hotfix":true}'
run_pool
spawned_key BH-1099 && ok || bad "A5a: the hotfix must spawn past the cap"
grep -q 'hotfix BH-1099: pool at cap 1 (budget spent) — exceeding it by one machine' "$LOGF" && ok || bad "A5a: the exceeded line is missing"
# Ticket 10 is the live machine's own row: the reap reads its thread (BH-7107).
[ "$(grep -vx 10 "$T/thread-reads" 2>/dev/null | sort -n | tr '\n' ' ')" = "1099 " ] && ok \
  || bad "A5a: no plain row may be decided with the budget at 0, read: $(tr '\n' ' ' < "$T/thread-reads" 2>/dev/null)"
reset_state
printf '1\n' > "$H/flags/fly-pool-project-5"
for n in 1001 1002 1003; do q "BH-$n" "$n"; done
q BH-1099 1099 '{"hotfix":true}'
run_pool
spawned_key BH-1099 && ok || bad "A5b: the hotfix takes the one plain slot"
[ "$(spawned_n)" = 1 ] && ok || bad "A5b: the cap of 1 holds, got $(spawned_n)"
grep -q 'exceeding it by one machine' "$LOGF" && bad "A5b: the budget had room, the exemption must not be spent" || ok

# ── A6: skip reasons, and the queue map ──────────────────────────────────────
reset_state
printf '%s' '[{"number":77,"html_url":"https://github.com/example-org/project-5/pull/77","head":{"ref":"ticket/bh-1005","repo":{"owner":{"login":"example-org"}}},"title":"x"}]' > "$T/special.json"
printf 'BH-901 queued\nBH-902 claimed\nBH-903 done\n' > "$T/qstate"
jq -nc '{claims:[{ticket_id:"BH-500.0", planned_files:"src/x.ts"}]}' > "$T/claims.json"
mkdir -p "$H/plans/project-5-BH-500.1"; printf 'src/x.ts\n' > "$H/plans/project-5-BH-500.1/planned-files.txt"
q BH-2001 2001 '{"after":"BH-901"}'; q BH-2002 2002 '{"after":"BH-902"}'; q BH-2003 2003 '{"after":"BH-903"}'
q BH-500.1 5001; q BH-3001 3001; echo 3001 > "$T/held"; q BH-1005 1005
run_pool
grep -q 'skipping BH-2001: waits for BH-901 (still in flight or its PR is open)' "$LOGF" && ok || bad "A6: a queued blocker holds BH-2001"
grep -q 'skipping BH-2002: waits for BH-902 (still in flight or its PR is open)' "$LOGF" && ok || bad "A6: a claimed blocker holds BH-2002"
grep -q 'RELEASED BH-2003: BH-903 is done' "$LOGF" && ok || bad "A6: a blocker absent from a complete listing is done: $(grep 'BH-2003' "$LOGF" | head -2)"
[ "$(count '/api/queue?.*key=' "$T/jobs-calls")" = 0 ] && ok || bad "A6: a complete listing needs no per-key read, got $(count '/api/queue?.*key=' "$T/jobs-calls")"
[ "$(count . "$T/pr-reads")" = 0 ] && ok || bad "A6: the PR bulk read covers each \`after\` blocker, got $(count . "$T/pr-reads") per-key PR reads"
grep -q 'SIBLING_SERIAL BH-500.1 waits for BH-500.0 on src/x.ts' "$LOGF" && ok || bad "A6: the sibling wait line is missing"
grep -q 'skipping BH-3001: HOLD' "$LOGF" && ok || bad "A6: the HOLD line is missing"
grep -q 'skipping BH-1005: open PR exists' "$LOGF" && ok || bad "A6: the open-PR line is missing"
for MODE in full fail; do
  reset_state
  printf 'BH-901 queued\n' > "$T/qstate"
  q BH-2001 2001 '{"after":"BH-901"}'; q BH-1001 1001
  run_pool QMODE=$MODE
  grep -q 'skipping BH-2001: waits for BH-901 (still in flight or its PR is open)' "$LOGF" && ok || bad "A6 $MODE: the per-key read must still hold BH-2001"
  [ "$(count '/api/queue?.*key=BH-901' "$T/jobs-calls")" = 1 ] && ok || bad "A6 $MODE: a $MODE listing proves nothing, expected 1 per-key read, got $(count '/api/queue?.*key=BH-901' "$T/jobs-calls")"
done

# ── A7: the budget spent mid-walk ────────────────────────────────────────────
reset_state
for n in $(seq 1001 1030); do q "BH-$n" "$n"; done
printf '2\n' > "$T/hold-s"
run_pool POOL_TICK_BUDGET_S=3
[ "$(count 'tick budget of 3s spent' "$LOGF")" = 1 ] && ok || bad "A7: the budget line must be said once, got $(count 'tick budget of 3s spent' "$LOGF")"
RD=$(count . "$T/thread-reads")
[ "$RD" -lt 30 ] && [ "$RD" -ge 1 ] && ok || bad "A7: dispatch must stop at the budget, $RD of 30 rows were read"
[ "$(spawned_n)" = "$RD" ] && ok || bad "A7: every started row must spawn: $RD read, $(spawned_n) spawned"
[ "$(ls "$QD"/*.json 2>/dev/null | wc -l | tr -d ' ')" = $((30 - RD)) ] && ok || bad "A7: the rows not decided must stay queued"
grep -q "not reached $((30 - RD)) (budget)" "$LOGF" && ok || bad "A7: the end-of-walk line must name the budget: $(grep 'queued rows in' "$LOGF")"

# ── A8: a decision worker that writes no verdict ─────────────────────────────
reset_state
# The actor gate is the last gate of the decision; this stub kills the worker
# for one key the way a crash would, with no verdict written.
cat > "$H/bin/lib/pool-actor-gate.sh" <<'PAG'
pool_actor_gate() { [ "${2:-}" = BH-1003 ] && exit 9; return 0; }
PAG
for n in 1001 1002 1003 1004; do q "BH-$n" "$n"; done
run_pool
[ "$(count 'decide worker for BH-1003 wrote no verdict' "$LOGF")" = 1 ] && ok || bad "A8: one no-verdict line for BH-1003, got: $(grep 'BH-1003' "$LOGF" | head -3)"
[ -f "$QD/BH-1003.json" ] && ok || bad "A8: BH-1003 must stay queued"
spawned_key BH-1003 && bad "A8: a row with no verdict must not spawn" || ok
[ "$(spawned_n)" = 3 ] && ok || bad "A8: the other 3 rows spawn, got $(spawned_n)"

# ── A9: POOL_DECIDE_PARALLEL=1 is the serial walk ────────────────────────────
reset_state
for n in 1006 1001 1005 1002 1004 1003; do q "BH-$n" "$n"; done
printf '1003\n1005\n' > "$T/held"
run_pool POOL_DECIDE_PARALLEL=1
[ "$(tr '\n' ' ' < "$T/thread-reads" 2>/dev/null)" = "1006 1001 1005 1002 1004 1003 " ] && ok \
  || bad "A9: rows must be decided in queue order, read: $(tr '\n' ' ' < "$T/thread-reads" 2>/dev/null)"
[ "$(spawned_n)" = 4 ] && ok || bad "A9: the 4 clear rows spawn, got $(spawned_n)"
grep -q 'skipping BH-1005: HOLD' "$LOGF" && grep -q 'skipping BH-1003: HOLD' "$LOGF" && ok || bad "A9: the held rows log HOLD"
grep -q 'decide prime: .*parallel=1' "$LOGF" && ok || bad "A9: the prime line must say parallel=1: $(grep 'decide prime' "$LOGF")"
[ "$(leftover_tmp)" = 0 ] && ok || bad "A9: the tick left $(leftover_tmp) temp dir(s)"

# ── A10: spawn gates inactive: the line is said once for all the workers ────
reset_state
printf 'project-5 - - - 0 local\n' > "$H/fleet.conf"
for n in 1001 1002 1003; do q "BH-$n" "$n"; done
run_pool
[ "$(count 'spawn gates inactive' "$LOGF")" = 1 ] && ok || bad "A10: the gates-inactive line must be said once, got $(count 'spawn gates inactive' "$LOGF")"
[ "$(spawned_n)" = 3 ] && ok || bad "A10: ungated rows spawn, got $(spawned_n)"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
