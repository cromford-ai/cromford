#!/bin/bash
# tests/mc-locks-lease.bh-6887-test.sh — BH-6887 (BH-6881.3): the merge lock
# takes the D1 project lease (lane merge-conductor), and each landing writer
# checks the held fence before its GitHub call. The conductor lib (the real
# bin/lib/merge-conductor-lib.sh, bin/jobs-client.sh and
# bin/lib/project-lease.sh) is driven against the REAL jobs worker on
# node:sqlite (tests/lib/mc-budget.bh-6887.mjs); gh is a shim that logs every
# call and fails every write.
#
#   L1  machine, lease held by `other`: mc_merge and mc_enqueue answer 99 with
#       no gh write and their deferred words; another call answers 99 and
#       does not run
#   L2  machine, a stale outer fence (another holder took the lease after it
#       expired): mc_merge answers 99, no merge call, `project lease lost`
#   L3  hub, lease free: the call runs with the fence exported, its rc and
#       stdout pass through, the lease is released after (holder hub-*,
#       lease_until <= now), the flock is free and nothing leaks
#   L4  hub, lease held by `other`: 99, the call does not run, the log says
#       `merge lease held by another holder`, the flock is free
#   L5  hub, no worker (JOBS_URL empty) or a 503 worker: the call runs under
#       the flock and its rc passes through
#   L6  machine, lease free: the call runs and the lease is released (holder
#       m1); a 503 worker: 99, the call does not run; mc_merge with no outer
#       lease owner: 99 with its word and no gh call; mc_merge under a live
#       outer fence reaches gh and the outer lease is not released
#   L7  hub, lease free: mc_merge reaches gh (1 merge line) — the guard is not
#       a blanket block
#   L8  a stale fence: conductor_settle writes no MERGED row, logs `lease was
#       lost`, rc 0; mc_close_shipped prints close-failed with no gh write;
#       mc_enqueue answers 99 with no gh call; a valid fence of another
#       project is lost too; with no fence the guard does nothing
#   L10 a renew not answered (503, or a 409 that is not `lost`): 99 on a
#       machine, 0 on the hub, one log line each
#   L9  mutation: a scratch queue.sh with mc_merge's fence line removed lets
#       L2's merge reach gh — the suite sees the guard
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-locks-lease.bh-6887-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/mc-budget.bh-6887.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/locks" "$T/fakebin"
for L in bin/lib/merge-conductor-lib.sh bin/jobs-client.sh bin/lib/project-lease.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
: > "$H/env/global.env"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in
  *"pr merge"*|*"issue close"*|*"issue comment"*|*"pr comment"*|*"-X PUT"*|*"-X POST"*|*"-X PATCH"*|*label*) exit 1 ;;
esac
echo ""
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=fixture-harness-secret PR_MERGE_REST=0
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 MC_MERGE_LOCK_WAIT=5

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
URL0="$JOBS_URL"
trap 'kill "$SPID" 2>/dev/null' EXIT

P=demo-os
PRURL=https://github.com/example-org/demo-os/pull/41
HEAD41=4141414141414141414141414141414141414141
lease() { curl -sS "$URL0/__lease?lane=merge-conductor&project=$1"; }
setlease() { curl -sS -X POST -d "$(jq -nc --arg p "$1" --arg h "$2" --argjson f "$3" --arg u "$4" \
  '{lane:"merge-conductor",project:$p,holder:$h,fence:$f,lease_until:$u}')" "$URL0/__lease" > /dev/null; }
answer() { curl -sS -X PUT -d "$1" "$URL0/__answer" > /dev/null; }
acquire() { curl -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
  -d "$(jq -nc --arg p "$1" --arg h "$2" '{lane:"merge-conductor",project:$p,holder:$h}')" "$URL0/api/project-leases/acquire"; }
FUTURE=2099-01-01T00:00:00Z
PAST=2000-01-01T00:00:00Z
writes() { grep -cE 'pr merge|api .*(merges|/merge)|issue (close|comment)|pr comment|label' "$T/gh.log" 2>/dev/null; }
merges() { grep -cE 'pr merge|api .*/merge' "$T/gh.log" 2>/dev/null; }
reset() { : > "$T/gh.log"; : > "$T/def.txt"; : > "$H/logs/merge-conductor.log"; }
flock_free() { ( flock -n 9 ) 9>>"$H/locks/merge-conductor-$1-merge.lock"; }
# lib [env...] -- <shell code> — run the code in a fresh shell with the conductor lib loaded.
QUEUE_SRC=""
lib() {
  ( export MC_PR_DEFERRED_FILE="$T/def.txt"
    # shellcheck source=/dev/null
    . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
    # shellcheck source=/dev/null
    [ -z "$QUEUE_SRC" ] || . "$QUEUE_SRC"
    eval "$1" )
}

# ============================================================================
echo "L1: a lane-run machine, the lease held by another holder"
reset; acquire $P other > /dev/null
R=$(MC_ON_MACHINE=1 FLY_MACHINE_ID=m1 lib 'mc_merge_locked demo-os mc_merge "'$PRURL'" "'$HEAD41'" >/dev/null; echo "mg=$?"
  mc_merge_locked demo-os mc_enqueue "'$PRURL'" "'$HEAD41'" >/dev/null; echo "lq=$?"
  mc_merge_locked demo-os echo ran; echo "ot=$?"' | tr '\n' ' ')
[ "$R" = "mg=99 lq=99 ot=99 " ] && ok "L1 merge, enqueue and another call answer 99, the call does not run" || bad "L1 rcs: $R"
[ "$(writes)" = 0 ] && ok "L1 gh records 0 write calls" || bad "L1 gh: $(cat "$T/gh.log")"
[ "$(sort "$T/def.txt" | tr '\n' ' ')" = "enqueue merge " ] && ok "L1 the deferred words are merge and enqueue" || bad "L1 words: $(cat "$T/def.txt")"
grep -q 'demo-os merge lease held by another holder' "$H/logs/merge-conductor.log" && ok "L1 the log says the lease is held" \
  || bad "L1 log: $(cat "$H/logs/merge-conductor.log")"
[ "$(lease $P | jq -r .holder)" = other ] && ok "L1 the lease stays with other" || bad "L1 lease: $(lease $P)"
setlease $P other 1 "$PAST"

# ============================================================================
echo "L2: a stale outer fence on a machine stops the merge before gh"
setlease p2 x 1 "$PAST"
F=$(acquire p2 m1 | jq -r .fence)
setlease p2 m1 "$F" "$PAST"
F2=$(acquire p2 other | jq -r .fence)
[ "$F2" = $((F + 1)) ] && ok "L2 setup: other took the lease at fence $F2" || bad "L2 setup: fence $F then $F2"
l2() {
  reset
  R=$(MC_ON_MACHINE=1 FLY_MACHINE_ID=m1 MC_LEASE_FENCE="$F" MC_LEASE_HOLDER=m1 \
      lib 'mc_merge_locked p2 mc_merge "'$PRURL'" "'$HEAD41'" >/dev/null; echo "rc=$?"')
}
l2
[ "$R" = rc=99 ] && ok "L2 mc_merge answers 99" || bad "L2 rc: $R"
[ "$(merges)" = 0 ] && ok "L2 gh records 0 merge calls" || bad "L2 gh: $(cat "$T/gh.log")"
grep -q "p2 project lease lost (fence $F)" "$H/logs/merge-conductor.log" && ok "L2 the log says the lease was lost" \
  || bad "L2 log: $(cat "$H/logs/merge-conductor.log")"
[ "$(lease p2 | jq -r '.holder + " " + (.fence|tostring)')" = "other $F2" ] && ok "L2 the outer fence released nothing" || bad "L2 lease: $(lease p2)"

# ============================================================================
echo "L3: the hub, lease free"
reset
OUT=$(lib 'mc_merge_locked demo-os bash -c '"'"'echo "ran $MC_LEASE_FENCE $MC_LEASE_PROJECT $MC_LEASE_HOLDER"; exit 7'"'"'; echo "rc=$?"; echo "after=${MC_LEASE_FENCE:-none}"')
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
L=$(lease $P)
FN=$(jq -r .fence <<<"$L")
grep -qx "ran $FN demo-os hub-.*" <<<"$OUT" && ok "L3 the call ran with fence $FN, the project and a hub holder exported" || bad "L3 out: $OUT (lease $L)"
grep -qx 'rc=7' <<<"$OUT" && ok "L3 the call's rc 7 passes through" || bad "L3 rc: $OUT"
grep -qx 'after=none' <<<"$OUT" && ok "L3 the fence does not leak past the call" || bad "L3 leak: $OUT"
[[ "$(jq -r .holder <<<"$L")" == hub-* ]] && [[ ! "$(jq -r .lease_until <<<"$L")" > "$NOW" ]] \
  && ok "L3 the lease is released (holder hub-*, lease_until <= now)" || bad "L3 lease: $L now $NOW"
flock_free $P && ok "L3 the flock is free after the call" || bad "L3 the flock is still held"
grep -q 'merge lease' "$H/logs/merge-conductor.log" && bad "L3 a lease line on a free lease: $(cat "$H/logs/merge-conductor.log")" || ok "L3 no lease log line"
FB=$(lease $P | jq -r .fence)
lib 'mc_merge_locked demo-os true' >/dev/null
[ "$(lease $P | jq -r .fence)" = $((FB + 1)) ] && ok "L3 the next call takes the released lease (fence + 1)" || bad "L3 next: $(lease $P)"

# ============================================================================
echo "L4: the hub, lease held by another holder"
reset; setlease $P other 9 "$FUTURE"
OUT=$(lib 'mc_merge_locked demo-os echo ran; echo "rc=$?"' | tr '\n' ' ')
[ "$OUT" = "rc=99 " ] && ok "L4 rc 99 and the call does not run" || bad "L4: $OUT"
grep -q 'demo-os merge lease held by another holder — next tick' "$H/logs/merge-conductor.log" && ok "L4 the log says the lease is held" \
  || bad "L4 log: $(cat "$H/logs/merge-conductor.log")"
flock_free $P && ok "L4 the flock is free" || bad "L4 the flock is still held"
setlease $P other 9 "$PAST"
OUT=$(lib 'mc_merge_locked demo-os echo ran; echo "rc=$?"' | tr '\n' ' ')
[ "$OUT" = "ran rc=0 " ] && ok "L4 after the lease expires the next call runs" || bad "L4 after: $OUT"

# ============================================================================
echo "L5: the hub with no worker, or a worker that answers 503"
reset
OUT=$(JOBS_URL="" lib 'mc_merge_locked demo-os bash -c "echo ran; exit 5"; echo "rc=$?"' | tr '\n' ' ')
[ "$OUT" = "ran rc=5 " ] && ok "L5 JOBS_URL empty: the call runs, rc 5 passes through" || bad "L5 empty: $OUT"
grep -q 'merge lease' "$H/logs/merge-conductor.log" && bad "L5 a lease line with no worker: $(cat "$H/logs/merge-conductor.log")" || ok "L5 no lease line with no worker"
answer '{"path_prefix":"/api/project-leases/","status":503,"body":"{\"error\":\"project_leases unavailable\"}"}'
OUT=$(lib 'mc_merge_locked demo-os bash -c "echo ran; exit 6"; echo "rc=$?"' | tr '\n' ' ')
[ "$OUT" = "ran rc=6 " ] && ok "L5 a 503 worker: the call runs under the flock, rc 6" || bad "L5 503: $OUT"
grep -q 'demo-os merge lease unavailable — hub flock only' "$H/logs/merge-conductor.log" && ok "L5 one line says hub flock only" \
  || bad "L5 log: $(cat "$H/logs/merge-conductor.log")"
answer '{}'

# ============================================================================
echo "L6: a lane-run machine, lease free"
reset; setlease p6 x 1 "$PAST"
OUT=$(MC_ON_MACHINE=1 FLY_MACHINE_ID=m1 lib 'mc_merge_locked p6 bash -c '"'"'echo "ran $MC_LEASE_HOLDER"'"'"'; echo "rc=$?"' | tr '\n' ' ')
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
L=$(lease p6)
[ "$OUT" = "ran m1 rc=0 " ] && ok "L6 the call runs with holder m1" || bad "L6: $OUT"
[ "$(jq -r .holder <<<"$L")" = m1 ] && [ "$(jq -r .fence <<<"$L")" = 2 ] && [[ ! "$(jq -r .lease_until <<<"$L")" > "$NOW" ]] \
  && ok "L6 m1 took the lease at fence 2 and released it" || bad "L6 lease: $L"
reset
answer '{"path_prefix":"/api/project-leases/","status":503,"body":"{}"}'
OUT=$(MC_ON_MACHINE=1 FLY_MACHINE_ID=m1 lib 'mc_merge_locked p6 echo ran; echo "ot=$?"' | tr '\n' ' ')
answer '{}'
[ "$OUT" = "ot=99 " ] && ok "L6 a 503 worker: 99 and the call does not run" || bad "L6 503: $OUT"
grep -q 'p6 merge lease unavailable on a lane-run machine' "$H/logs/merge-conductor.log" && ok "L6 the log says the lease was not answered" \
  || bad "L6 log: $(cat "$H/logs/merge-conductor.log")"
reset; : > "$T/srv.log"
OUT=$(MC_ON_MACHINE=1 FLY_MACHINE_ID=m1 lib 'mc_merge_locked p6 mc_merge "'$PRURL'" "'$HEAD41'"; echo "mg=$?"' 2>/dev/null | tr '\n' ' ')
[ "$OUT" = "mg=99 " ] && [ "$(cat "$T/def.txt")" = merge ] && [ ! -s "$T/gh.log" ] && ! grep -q '/api/project-leases/' "$T/srv.log" \
  && ok "L6 a merge with no outer lease owner: 99, its word, no stdout, no gh call" || bad "L6 no owner: $OUT words $(cat "$T/def.txt") gh $(cat "$T/gh.log")"
reset; setlease p6 x 1 "$PAST"; F6=$(acquire p6 m1 | jq -r .fence)
MC_ON_MACHINE=1 FLY_MACHINE_ID=m1 MC_LEASE_FENCE="$F6" MC_LEASE_HOLDER=m1 lib 'mc_merge_locked p6 mc_merge "'$PRURL'" "'$HEAD41'"' >/dev/null 2>&1
[ "$(grep -c 'pr merge' "$T/gh.log")" = 1 ] && [ ! -s "$T/def.txt" ] && ok "L6 a merge under a live outer fence reaches gh (1 merge call)" \
  || bad "L6 outer fence: words $(cat "$T/def.txt") gh $(cat "$T/gh.log")"
[ "$(lease p6 | jq -r '.holder + " " + (.fence|tostring)')" = "m1 $F6" ] && ok "L6 the outer owner's lease is not released" || bad "L6 outer lease: $(lease p6)"

# ============================================================================
echo "L7: the hub, lease free: mc_merge reaches gh"
reset; setlease p7 x 1 "$PAST"
lib 'mc_merge_locked p7 mc_merge "'$PRURL'" "'$HEAD41'"' >/dev/null 2>&1
[ "$(grep -c 'pr merge' "$T/gh.log")" = 1 ] && ok "L7 gh records 1 merge call" || bad "L7 gh: $(cat "$T/gh.log")"
grep -q 'project lease lost' "$H/logs/merge-conductor.log" && bad "L7 a lost line on a live lease" || ok "L7 no lost line"

# ============================================================================
echo "L8: a stale fence at the settle, the issue close and the enqueue"
reset
OUT=$(MC_LEASE_FENCE="$F" MC_LEASE_PROJECT=p2 MC_LEASE_HOLDER=m1 lib 'conductor_settle example-org/demo-os#41 "'$PRURL'" demo-os example-org/demo-os ticket/TK-41 "" - "'$HEAD41'" "'$HEAD41'" APPROVE CLEAN by:fixture; echo "st=$?"
  mc_close_shipped example-org/demo-os 41 "shipped" "" ""; echo "cl=$?"
  mc_enqueue "'$PRURL'" "'$HEAD41'" >/dev/null; echo "eq=$?"' 2>/dev/null | tr '\n' ' ')
[ "$OUT" = "st=0 close-failed cl=1 eq=99 " ] && ok "L8 settle rc 0, close-failed rc 1, enqueue 99" || bad "L8: $OUT"
grep -q 'example-org/demo-os#41 MERGED but the project lease was lost' "$H/logs/merge-conductor.log" && ok "L8 the settle logs lease was lost" \
  || bad "L8 log: $(cat "$H/logs/merge-conductor.log")"
grep -qs 'MERGED' "$H/state/merge-conductor/pr-state.tsv" && bad "L8 a MERGED row: $(cat "$H/state/merge-conductor/pr-state.tsv")" || ok "L8 no MERGED row"
[ "$(cat "$T/def.txt")" = settle ] && ok "L8 the settle wrote its deferred word" || bad "L8 words: $(cat "$T/def.txt")"
[ ! -s "$T/gh.log" ] && ok "L8 gh records 0 calls" || bad "L8 gh: $(cat "$T/gh.log")"
reset
setlease p8 x 1 "$PAST"; F8=$(acquire p8 m1 | jq -r .fence)
OUT=$(MC_LEASE_FENCE="$F8" MC_LEASE_PROJECT=other-os MC_LEASE_HOLDER=m1 lib 'mc_lease_fence_ok; echo "x=$?"
  MC_LEASE_PROJECT=p8 mc_lease_fence_ok; echo "y=$?"
  MC_LEASE_FENCE="" mc_lease_fence_ok; echo "z=$?"' | tr '\n' ' ')
[ "$OUT" = "x=99 y=0 z=0 " ] && ok "L8 a valid fence for another project is lost; the right project renews; no fence is no check" || bad "L8 fence: $OUT"

# ============================================================================
echo "L10: a renew that is not answered"
reset
answer '{"path_prefix":"/api/project-leases/","status":503,"body":"{}"}'
OUT=$(MC_LEASE_FENCE="$F8" MC_LEASE_PROJECT=p8 MC_LEASE_HOLDER=m1 lib 'MC_ON_MACHINE=1 mc_lease_fence_ok; echo "m=$?"; mc_lease_fence_ok; echo "h=$?"' | tr '\n' ' ')
[ "$OUT" = "m=99 h=0 " ] && ok "L10 a 503 renew: 99 on a machine, 0 on the hub" || bad "L10 503: $OUT"
grep -q 'p8 project lease renew unavailable on a lane-run machine — write stopped' "$H/logs/merge-conductor.log" \
  && grep -q 'p8 project lease renew unavailable — hub flock only' "$H/logs/merge-conductor.log" \
  && ok "L10 one line each says what the writer did" || bad "L10 log: $(cat "$H/logs/merge-conductor.log")"
answer '{"path_prefix":"/api/project-leases/","status":409,"body":"{\"error\":\"held\"}"}'
OUT=$(MC_LEASE_FENCE="$F8" MC_LEASE_PROJECT=p8 MC_LEASE_HOLDER=m1 lib 'MC_ON_MACHINE=1 mc_lease_fence_ok; echo "m=$?"' | tr '\n' ' ')
[ "$OUT" = "m=99 " ] && ok "L10 a 409 held on renew (not lost): still 99 on a machine" || bad "L10 409 held: $OUT"
answer '{}'

# ============================================================================
echo "L9: mutation — mc_merge without its fence line"
sed '/mc_lease_fence_ok || { printf .project lease lost — nothing merged/d' "$DIR/bin/lib/mc/queue.sh" > "$T/queue-mut.sh"
if cmp -s "$DIR/bin/lib/mc/queue.sh" "$T/queue-mut.sh"; then
  bad "L9 setup: the fence line is not in mc_merge"
else
  QUEUE_SRC="$T/queue-mut.sh"; l2; QUEUE_SRC=""
  [ "$(merges)" -ge 1 ] && ok "L9 without the line the stale-fence merge reaches gh (the suite sees the guard)" || bad "L9 mutant: rc $R gh: $(cat "$T/gh.log")"
fi

echo "mc-locks-lease: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
