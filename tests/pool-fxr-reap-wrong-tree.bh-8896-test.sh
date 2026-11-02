#!/bin/bash
# tests/pool-fxr-reap-wrong-tree.bh-8896-test.sh — the hub reap refuses a fix
# round's record that carries another job's build (BH-8896).
#
# project-6-os FXR-1465 (2026-11-01): the record of a fix round for PR #3511
# held reviewed-sha 708294bb, the head of PR #3512 that the machine built
# before it was reused, and the reap closed the row done and logged
# "finish=ok". A fix round has no build dir, so it writes no reviewed-sha: any
# sha in its record is another job's.
#   X1  FXR key, FIX_ROUND_FINISHED, a relayed reviewed-sha -> row failed
#       `wrong-tree:`, 1 alert, the foreign files in $LOCAL/wrong-tree/, no
#       `finish=ok` on the key's reap line
#   X2  FXR key, FIX_ROUND_FINISHED, no build dir on the machine -> row done
#   X3  FXR key, FIX_ROUND_WRONG_TREE -> row failed
#   X4  FXR key, a 0-byte reviewed-sha -> row done
#   X5  FXR key, FIX_ROUND_SKIPPED + a reviewed-sha -> row failed, wrong-tree
# Drives the REAL bin/fly-pool.sh with a fly stub (the harness of the R-series
# in tests/fix-round-fly-placement.bh-8065-test.sh). 0 network calls.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pool-fxr-reap-wrong-tree.bh-8896-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq base64; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

FX1="FXR-1465-f6f76243"
SHA=708294bb3c1d2e4f5a6b7c8d9e0f1a2b3c4d5e6f
PH="$T/p"
mkdir -p "$PH/bin/lib" "$PH/logs" "$PH/flags" "$PH/locks" "$PH/env" "$PH/builds" "$PH/state/fly" \
         "$PH/state/fly-pool/tproj" "$PH/state/remote-results/tproj" "$PH/state/build-queue/tproj" "$T/pbin" "$T/relay"
cat > "$PH/bin/jobs-client.sh" <<EOF
queue_done() { printf 'done %s\n' "\$*" >> "$T/psink"; return 0; }
queue_put() { printf 'put %s\n' "\$*" >> "$T/psink"; echo queued; return 0; }
queue_status() { echo claimed; return 0; }
_jobs_req() { printf 'req %s\n' "\$*" >> "$T/psink"; cat "$T/prow.json" 2>/dev/null; }
EOF
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$PH/bin/"
scratch_install_closure bin/fly-pool.sh "$PH" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$PH" >/dev/null || { echo "closure install of bin/alert-line.sh failed"; exit 1; }
printf 'HARNESS_SECRET=fixture-secret\n' > "$PH/env/global.env"
printf 'FLY_API_TOKEN_TPROJ=tok-fixture-1\n' > "$PH/env/fly.env"
printf 'tproj example-org/mk - - 0 local\n' > "$PH/fleet.conf"
printf '3\n' > "$PH/flags/fly-pool-tproj"; printf 'pool-tproj\n' > "$PH/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$PH/state/fly/tproj.json"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/pbeat"\nexit 0\n' "$T" > "$PH/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/pbin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/pbin/flock"; printf '#!/bin/bash\nexit 0\n' > "$T/pbin/sleep"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/pgh"\nexit 1\n' "$T" > "$T/pbin/gh"
# The machine: $T/relay/RESULT is /run/harness/RESULT; $T/relay/bdir names the
# newest build dir (`ls -dt`) and $T/relay/reviewed-sha is that dir's file.
cat > "$T/pbin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/pfly"
case "\$*" in
  *"machine status"*) echo "State: \$(cat "$T/pmstate" 2>/dev/null || echo started)"; exit 0 ;;
  *"ssh console"*"ls"*"-dt"*"builds"*) cat "$T/relay/bdir" 2>/dev/null; exit 0 ;;
  *"ssh console"*"base64"*"reviewed-sha"*) [ -s "$T/relay/reviewed-sha" ] && base64 -w0 "$T/relay/reviewed-sha"; exit 0 ;;
  *"ssh console"*"base64"*"pipeline.log"*) [ -s "$T/relay/pipeline.log" ] && base64 -w0 "$T/relay/pipeline.log"; exit 0 ;;
  *"ssh console"*"head"*"RESULT"*) head -1 "$T/relay/RESULT" 2>/dev/null; exit 0 ;;
  *"ssh console"*"base64"*"RESULT"*) [ -s "$T/relay/RESULT" ] && base64 -w0 "$T/relay/RESULT"; exit 0 ;;
  *"ssh console"*) exit 0 ;;
  *"machines list"*) echo '[]' ;;
esac
exit 0
FLY
chmod +x "$PH/bin/beat.sh" "$PH/bin/result-prefix-ok.sh" "$T/pbin"/*
jq -nc --arg k "$FX1" '{queue:[{project:"tproj",ticket_key:$k,ticket_id:"1465",status:"claimed",target:"fly",attempt:0,meta:"{}"}]}' > "$T/prow.json"
# preap <result line> [reviewed-sha content|-none-|-empty-] — one reap of machine m1 on $FX1
preap() {
  local p
  for p in "$PH/builds"/* "$PH/state/build-queue/tproj"/* "$PH/logs/ALERTS.log" \
           "$T/psink" "$T/pbeat" "$T/pgh" "$T/pfly" "$T/relay"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  printf '%s\n' "$1" > "$T/relay/RESULT"
  case "${2:--none-}" in
    -none-) ;;
    -empty-) echo /data/harness/builds/tproj-TK-3496-202611011020 > "$T/relay/bdir"; : > "$T/relay/reviewed-sha" ;;
    *) echo /data/harness/builds/tproj-TK-3496-202611011020 > "$T/relay/bdir"; printf '%s\n' "$2" > "$T/relay/reviewed-sha"
       printf 'TK-3496 stage line\n' > "$T/relay/pipeline.log" ;;
  esac
  : > "$PH/logs/fly-pool.log"
  jq -nc --arg k "$FX1" '{machine:"m1",key:$k,ticket_id:"1465",attempt:0}' > "$PH/state/fly-pool/tproj/m1.json"
  ( export PATH="$T/pbin:$PATH" HARNESS="$PH" FLEET_CONF="$PH/fleet.conf" FLY_API_TOKEN_TPROJ=tok-fixture-1 \
           FLY_BIN_DIR="$T/pbin" POOL_SPAWN=0 GH_TOKEN="" POOL_PR_VERIFY_SLEEP=0
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  LOCAL=$(ls -d "$PH/builds/pool-tproj-$FX1-"* 2>/dev/null | head -1)
}
alerts() { local n; n=$(grep -c "$1" "$PH/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
row() { grep "^done tproj $FX1 " "$T/psink" 2>/dev/null; }

# ── X1 THE POINT: a foreign reviewed-sha is wrong-tree, never ok ─────────────
preap "FIX_ROUND_FINISHED terminal finish=ok" "$SHA"
[ -n "$LOCAL" ] && ok || bad "X1 rig: no local record dir under $PH/builds: $(ls "$PH/builds")"
[[ "$(row)" == "done tproj $FX1 failed wrong-tree:"* ]] && ok || bad "X1 THE POINT: the row must close failed 'wrong-tree:', got '$(row)' (log: $(tail -3 "$PH/logs/fly-pool.log"))"
[[ "$(row)" == *"708294bb"* ]] && ok || bad "X1: the reason names the foreign sha: '$(row)'"
[ "$(alerts "$FX1")" = 1 ] && [ "$(alerts wrong-tree)" = 1 ] && ok || bad "X1: exactly one wrong-tree alert: $(cat "$PH/logs/ALERTS.log" 2>/dev/null)"
[ -s "$LOCAL/wrong-tree/reviewed-sha" ] && ok || bad "X1: the foreign reviewed-sha must be kept in \$LOCAL/wrong-tree/: $(ls -R "$LOCAL" 2>/dev/null)"
[ -e "$LOCAL/reviewed-sha" ] && bad "X1: \$LOCAL/reviewed-sha is still where a reader takes it as this round's" || ok
[ -s "$LOCAL/wrong-tree/pipeline.log" ] && [ ! -e "$LOCAL/pipeline.log" ] && ok || bad "X1: the foreign pipeline.log must move to wrong-tree/ too: $(ls -R "$LOCAL" 2>/dev/null)"
[ -s "$LOCAL/RESULT" ] && ok || bad "X1: the RESULT stays in \$LOCAL"
grep -q 'finish=ok' <<<"$(grep "$FX1" "$PH/logs/fly-pool.log")" && bad "X1 THE POINT: the reap still says finish=ok: $(grep "$FX1" "$PH/logs/fly-pool.log")" || ok
grep -q "pool fix round reaped for $FX1 from m1: wrong-tree" "$PH/logs/fly-pool.log" && ok || bad "X1: the reap line names wrong-tree: $(tail -3 "$PH/logs/fly-pool.log")"
grep -q "^put tproj $FX1" "$T/psink" 2>/dev/null && bad "X1: a wrong-tree row is never requeued" || ok

# ── X2 a fix round with no build dir: unchanged ─────────────────────────────
preap "FIX_ROUND_FINISHED done finish=ok"
[ "$(row)" = "done tproj $FX1 done FIX_ROUND_FINISHED done finish=ok" ] && ok || bad "X2: the row must close done as before, got '$(row)'"
[ "$(alerts "$FX1")" = 0 ] && ok || bad "X2: no alert"
grep -q "pool fix round reaped for $FX1 from m1: FIX_ROUND_FINISHED done finish=ok" "$PH/logs/fly-pool.log" && ok || bad "X2: the reap line is unchanged: $(tail -3 "$PH/logs/fly-pool.log")"
[ -e "$LOCAL/wrong-tree" ] && bad "X2: a wrong-tree dir for a clean record" || ok

# ── X3 the machine's own wrong-tree word ─────────────────────────────────────
preap "FIX_ROUND_WRONG_TREE FIX_ROUND_WRONG_TREE: /x is on brfix/other, not brfix/ck finish=ok"
[[ "$(row)" == "done tproj $FX1 failed FIX_ROUND_WRONG_TREE"* ]] && ok || bad "X3: FIX_ROUND_WRONG_TREE closes the row failed, got '$(row)'"
[ "$(alerts "$FX1")" = 0 ] && ok || bad "X3: the machine reported it, no alert: $(cat "$PH/logs/ALERTS.log" 2>/dev/null)"

# ── X4 a 0-byte reviewed-sha is no sha ───────────────────────────────────────
preap "FIX_ROUND_FINISHED done finish=ok" -empty-
[ "$(row)" = "done tproj $FX1 done FIX_ROUND_FINISHED done finish=ok" ] && ok || bad "X4: an empty reviewed-sha must not be wrong-tree, got '$(row)'"
[ "$(alerts wrong-tree)" = 0 ] && ok || bad "X4: no wrong-tree alert"

# ── X5 SKIPPED with a foreign reviewed-sha ───────────────────────────────────
preap "FIX_ROUND_SKIPPED row 1465 is not claimed by b1" "$SHA"
[[ "$(row)" == "done tproj $FX1 failed wrong-tree:"* ]] && ok || bad "X5: SKIPPED + reviewed-sha closes failed wrong-tree, got '$(row)'"
[ "$(alerts wrong-tree)" = 1 ] && ok || bad "X5: one wrong-tree alert: $(cat "$PH/logs/ALERTS.log" 2>/dev/null)"

echo "pool-fxr-reap-wrong-tree.bh-8896: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
