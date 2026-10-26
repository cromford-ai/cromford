#!/bin/bash
# tests/lead-review-chain-doorbell.bh-4057-test.sh — BH-4092 (BH-4057.0): the
# lead-chain doorbell's lib.
#   L*  lcw_rerun and lcw_ring from "$DIR/bin/lib/lead-chain-wake.sh", sourced;
#       lcw_ring goes through the real bin/jobs-client.sh wake_lane_put.
# The stub worker answers "POST /api/wakes/lane" 200 {inserted:1} and logs
# every request as "<METHOD> <path> <body> lead=<0|1>".
# The worklist's doorbell (bin/lib/lead-gates.d/97-doorbell.sh) has its own
# suites: tests/lead-gates-doorbell.bh-5876-test.sh and
# tests/lead-gates-doorbell-ports.bh-8362-test.sh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-chain-doorbell.bh-4057-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$T/fakebin" "$T/log" "$T/tmp"
# The jobs client with the bin/lib files it sources (BH-4552).
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }

SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "POST /api/wakes/lane") out='{"inserted":1,"as_of":"2026-10-03T00:00:00Z"}' ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
chmod +x "$T/fakebin/curl"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1
unset BOX_NAME JOBS_BOX HUB_BOX_NAME

wlog() { cat "$T/log/worker" 2>/dev/null; }
lanes() { wlog | grep -c '^POST /api/wakes/lane ' ; }
lanebody() { wlog | sed -n 's#^POST /api/wakes/lane \(.*\) lead=.$#\1#p' | sed -n "${1:-1}p"; }

# ── L: the lib, sourced into a clean shell ──
LIB="$DIR/bin/lib/lead-chain-wake.sh"
SD="$T/lst"; STUB="$T/rerun-stub.sh"
cat > "$STUB" <<EOF
#!/bin/bash
echo "\${LEAD_CHAIN_RERUN_DEPTH:-unset} \$*" >> "$T/rerun.log"
for f in /proc/\$\$/fd/*; do readlink "\$f"; done >> "$T/rerun.fds"
sleep "\${STUB_SLEEP:-0}"
EOF
chmod +x "$STUB"
lreset() { scratch_rm "$SD"; rm -f "$T/rerun.log" "$T/rerun.fds"; mkdir -p "$SD"; }
waitlog() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$T/rerun.log" ] && return 0; sleep 0.1; done; return 1; }
rlines() { [ -f "$T/rerun.log" ] && wc -l < "$T/rerun.log" | tr -d ' ' || echo 0; }

# L1: a marker, depth 0, knob 3 -> one launch at depth 1, marker gone, one line
lreset; : > "$SD/rerun-owed"
OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 0 tick); LRC=$?
waitlog; sleep 0.3
[ "$LRC" = 0 ] && ok || bad "L1 rc=$LRC out=$OUT"
[ "$OUT" = "rerun owed (depth 1/3)" ] && ok || bad "L1 printed: '$OUT'"
[ "$(rlines)" = 1 ] && [ "$(cat "$T/rerun.log")" = "1 tick" ] && ok || bad "L1 the stub ran: '$(cat "$T/rerun.log" 2>/dev/null)'"
[ ! -e "$SD/rerun-owed" ] && ok || bad "L1 the marker survived"
# force=1 with no marker launches too; no marker and no force is silent
lreset; OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 1 tick); LRC=$?; waitlog
[ "$LRC" = 0 ] && [ "$(rlines)" = 1 ] && ok || bad "L1 force=1 rc=$LRC runs=$(rlines)"
lreset; OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 0 tick); LRC=$?; sleep 0.5
[ "$LRC" = 1 ] && [ -z "$OUT" ] && [ "$(rlines)" = 0 ] && ok || bad "L1 no trigger: rc=$LRC out='$OUT' runs=$(rlines)"
# with no force argument the extra args start at position 4
lreset; : > "$SD/rerun-owed"; OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 tick x); waitlog
[ "$(cat "$T/rerun.log" 2>/dev/null)" = "1 tick x" ] && ok || bad "L1 no-force args: '$(cat "$T/rerun.log" 2>/dev/null)'"

# L2: depth reached -> no launch, rc 1, the marker cleared
lreset; : > "$SD/rerun-owed"
OUT=$(export LEAD_CHAIN_RERUN_DEPTH=3; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 0 tick); LRC=$?; sleep 0.5
[ "$LRC" = 1 ] && [ "$(rlines)" = 0 ] && ok || bad "L2 rc=$LRC runs=$(rlines)"
[ "$OUT" = "rerun owed but depth 3/3 reached; cron covers it" ] && ok || bad "L2 printed: '$OUT'"
[ ! -e "$SD/rerun-owed" ] && ok || bad "L2 the marker survived the depth bound"

# L3: an off knob (0, empty, abc) -> no launch, an off line, the marker kept
for k in 0 '' abc; do
  lreset; : > "$SD/rerun-owed"
  OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" "$k" 0 tick); LRC=$?; sleep 0.3
  [ "$LRC" = 1 ] && [ "$(rlines)" = 0 ] && ok || bad "L3 knob '$k' rc=$LRC runs=$(rlines)"
  [ "$OUT" = "rerun owed but off (max='$k')" ] && ok || bad "L3 knob '$k' printed: '$OUT'"
  [ -e "$SD/rerun-owed" ] && ok || bad "L3 knob '$k' dropped the marker"
done

# L4: the caller's fd 9 lock is never inherited by the rerun
lreset; : > "$SD/rerun-owed"
( exec 9>"$T/held.lock"; flock -n 9 || exit 9
  unset LEAD_CHAIN_RERUN_DEPTH; export STUB_SLEEP=3
  . "$LIB" && lcw_rerun "$STUB" "$SD" 3 0 tick >/dev/null )
waitlog
if flock -n "$T/held.lock" true; then ok; else bad "L4 the rerun child holds the caller's fd 9 lock"; fi
! grep -q 'held.lock' "$T/rerun.fds" 2>/dev/null && ok || bad "L4 fds: $(cat "$T/rerun.fds")"

# L5: lcw_ring refuses bad input before any call (rc 1, no lane POST)
rm -f "$T/log/worker"
ring() { ( . "$H/bin/jobs-client.sh" && . "$LIB" && lcw_ring "$@" ) >/dev/null 2>&1; }
ring lead-review example-org/demo-os 41 "${SHA:0:39}"; [ "$?" = 1 ] && ok || bad "L5 a 39-hex head was not rc 1"
ring lead-review example-org/demo-os 12a "$SHA";      [ "$?" = 1 ] && ok || bad "L5 a 12a pr was not rc 1"
ring lead-review noslash 41 "$SHA";                 [ "$?" = 1 ] && ok || bad "L5 a noslash slug was not rc 1"
ring '' example-org/demo-os 41 "$SHA";                [ "$?" = 1 ] && ok || bad "L5 an empty kind was not rc 1"
[ "$(lanes)" = 0 ] && ok || bad "L5 a refused ring still POSTed: $(wlog)"
# an upper-case head is lowercased; no wake_lane_put in the shell is rc 2
ring lead-land example-org/demo-os 41 "$(tr a-f A-F <<<"$SHA")"; [ "$?" = 0 ] && ok || bad "L5 an upper-case head was refused"
[ "$(jq -r .dedupe <<<"$(lanebody)" 2>/dev/null)" = "lead-land:41@$SHA12" ] && ok || bad "L5 dedupe: $(lanebody)"
( . "$LIB" && lcw_ring lead-review example-org/demo-os 41 "$SHA" ) >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "L5 no wake_lane_put was not rc 2"

echo "lead-review-chain-doorbell.bh-4057: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
