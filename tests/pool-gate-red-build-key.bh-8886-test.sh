#!/bin/bash
# tests/pool-gate-red-build-key.bh-8886-test.sh — a build key's GATE_RED is a
# build result, and a refused RB- apply closes its queue row.
#
# WHAT THIS IS ABOUT (BH-8886). The pool reap arm `# >>> pool rebase reap` in
# config/fly-pool.d/3400-pool-listing-and-reap.sh matched REBASED / CONFLICT /
# GATE_RED / REBASE_* for ANY key. Since BH-8062 a normal build writes
# `GATE_RED <n> red: <suites>; see <build>/gate.txt`, so a build key (BH-8817,
# BH-8883) reached mc_pool_rebase_apply, which answered 1. The refused branch
# then left the row CLAIMED, BH-7382's orphan-row release freed it, and
# fly-dispatch spawned the same ticket again (five machines for BH-8817).
#
# DRIVEN, NOT GREPPED (D2/D3). Every case runs the real bin/fly-pool.sh as a
# process against a scratch harness (the bh-7428 fixture). The queue PATCH
# sink, the apply and fail sinks, state/remote-results and ALERTS.log are the
# assertions.
#
# MUTATIONS THAT MUST TURN THIS SUITE RED (checked 2026-11-03):
#   - drop the RB-* key guard on the rebase arm          -> A1, A4, A5 red
#   - leave the row CLAIMED on a refused apply again     -> A2, A3 red
#   - drop the mc_pool_rebase_fail call on a refusal     -> A2 red
#
# Run from anywhere: bash tests/pool-gate-red-build-key.bh-8886-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/fly" "$H/state/fly-pool/tproj" "$H/state/remote-results/tproj" \
         "$H/state/build-queue/tproj" "$T/fakebin"
for S in bin/fly-pool.sh bin/jobs-client.sh bin/fleet-conf.sh bin/result-prefix-ok.sh bin/alert-line.sh; do
  scratch_install_closure "$S" "$H" >/dev/null || { echo "closure install of $S failed"; exit 1; }
done
cp "$DIR/fleet.conf" "$H/fleet.conf"
printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
printf '3\n'           > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n'  > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh"

printf '#!/bin/bash\nexit 0\n'            > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n'  > "$T/fakebin/timeout"
printf '#!/bin/bash\necho "ssh $*" >> "$SSH_SINK"\nexit 0\n' > "$T/fakebin/ssh"
printf '#!/bin/bash\necho "scp $*" >> "$SSH_SINK"\nexit 0\n' > "$T/fakebin/scp"
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
echo "fly $*" >> "$FLY_SINK"
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *base64*RESULT*)    [ -s "${RESULT_FIXTURE:-/dev/null}" ] && base64 -w0 "$RESULT_FIXTURE" ;;
  *base64*)           : ;;
  *head*RESULT*)      head -1 "${RESULT_FIXTURE:-/dev/null}" 2>/dev/null ;;
  *ls*builds*)        echo "/data/harness/builds/tproj-x-1" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
STUB
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$GH_SINK"
case " $* " in
  *" -i "*) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged":false}\n' ;;
  *)        printf '{"state":"open","merged":false}\n' ;;
esac
exit 0
STUB
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/queue/claim)
    KEY=$(printf '%s' "$BODY" | jq -r '.key // ""' 2>/dev/null)
    printf '{"queued":{"project":"tproj","ticket_key":"%s","ticket_id":"x","target":"fly","attempt":0,"status":"claimed"},"claimed":true}\n200\n' "$KEY" ;;
  */api/queue\?*) printf '{"queue":[]}\n200\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin"/*

# The merge-conductor lib, replaced: the apply answers $APPLY_RC and both
# functions record their argv.
fixture_lib() {
  cat > "$H/bin/lib/merge-conductor-lib.sh" <<'LIB'
mc_pool_rebase_apply() { printf '%s\n' "$*" >> "$APPLY_SINK"; return "${APPLY_RC:-0}"; }
mc_pool_rebase_fail()  { printf '%s\n' "$*" >> "$FAIL_SINK"; return 0; }
LIB
}
no_lib() { rm -f "$H/bin/lib/merge-conductor-lib.sh"; }

# pool <key> <ticket-id> <result-text> [apply-rc]: one machine, one real tick.
pool() {
  for D in builds state/remote-results/tproj state/build-queue/tproj state/fly-pool/tproj; do
    scratch_rm "$H/$D"; mkdir -p "$H/$D"
  done
  rm -f "$H/logs/ALERTS.log" "$H/logs/fly-pool.log"
  : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/fly.txt"; : > "$T/apply.txt"
  : > "$T/fail.txt"; : > "$T/beat.txt"; : > "$T/gh.txt"
  printf '%s' "$3" > "$T/result.txt"
  jq -nc --arg k "$1" --arg t "$2" '{machine:"m1",key:$k,ticket_id:$t,attempt:0}' \
    > "$H/state/fly-pool/tproj/m1.json"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok-fixture POOL_PR_VERIFY_SLEEP=0 \
           REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" FLY_SINK="$T/fly.txt" \
           APPLY_SINK="$T/apply.txt" FAIL_SINK="$T/fail.txt" BEAT_SINK="$T/beat.txt" \
           GH_SINK="$T/gh.txt" RESULT_FIXTURE="$T/result.txt" APPLY_RC="${4:-0}"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  LOCALDIR=$(ls -d "$H/builds/pool-tproj-$1-"* 2>/dev/null | head -1)
}
ALERTS() { cat "$H/logs/ALERTS.log" 2>/dev/null; }
# patch <key> <status>: the queue PATCH line that closed <key> with <status>.
patch() { grep "PATCH https://jobs.invalid/api/queue .*\"key\":\"$1\".*\"status\":\"$2\"" "$T/req.txt"; }
reason_of() { patch "$1" "$2" | head -1 | sed 's/^PATCH [^ ]* //' | jq -r '.reason // ""' 2>/dev/null; }
acount() { local n; n=$(grep -c -- "$1" "$H/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }

# A build key's GATE_RED: what bin/lib/selection-gate.sh writes (A1) and what
# the BH-7365 migration renumber writes (A5). Both take the build path.
build_gate_red() { # build_gate_red <case> <key> <id> <result>
  local c="$1" k="$2"
  pool "$k" "$3" "$4" 1
  [ -n "$LOCALDIR" ] && ok || bad "$c the machine is reaped into a local dir"
  [ -s "$T/apply.txt" ] && bad "$c THE POINT: a build key never reaches mc_pool_rebase_apply: $(cat "$T/apply.txt")" || ok
  [ -n "$(patch "$k" done)" ] && ok || bad "$c the queue row is closed done: $(cat "$T/req.txt")"
  case "$(reason_of "$k" done)" in
    GATE_RED*) ok ;;
    *) bad "$c the done row's reason is the RESULT, starting GATE_RED: '$(reason_of "$k" done)'" ;;
  esac
  [ "$(jq -r '.result // ""' "$H/state/remote-results/tproj/$k.json" 2>/dev/null | head -c 8)" = GATE_RED ] \
    && ok || bad "$c the build record reaches state/remote-results with .result GATE_RED: $(ls "$H/state/remote-results/tproj")"
  grep -q 'mc_pool_rebase_apply answered' "$H/logs/ALERTS.log" 2>/dev/null \
    && bad "$c a build GATE_RED writes no refused-apply ALERTS line: $(ALERTS)" || ok
  [ -n "$LOCALDIR" ] && [ -f "$LOCALDIR/REBASE" ] && bad "$c no REBASE sentinel on a build" || ok
  grep -q '"status":"queued"' "$T/req.txt" && bad "$c THE POINT: the row is never released to queued" || ok
  grep -q "reaped $k from m1: GATE_RED" "$H/logs/fly-pool.log" 2>/dev/null \
    && ok || bad "$c fly-pool.log names the build reap: $(cat "$H/logs/fly-pool.log" 2>/dev/null)"
}

# ── A1 a build key's selection-gate GATE_RED, apply would answer rc 1 ──────
fixture_lib
build_gate_red A1 BH-21 21 "GATE_RED 7 red: tests/a.sh,tests/b.sh; see /x/gate.txt"

# ── A5 a build key's migration-number GATE_RED ─────────────────────────────
build_gate_red A5 TK-26 26 "GATE_RED migration-number: 0235 is taken on main by 0235_a.sql;"

# ── A2 an RB- apply that answers rc 1 closes the row FAILED ────────────────
RBRES="REBASED bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PR: https://github.com/o/r/pull/21"
fixture_lib
pool RB-21-aaaaaaaa 21 "$RBRES" 1
[ "$(wc -l < "$T/apply.txt" | tr -d ' ')" = 1 ] && ok || bad "A2 the apply runs once: $(cat "$T/apply.txt")"
R=$(reason_of RB-21-aaaaaaaa failed)
case "$R" in
  "APPLY_FAILED rc=1: REBASED"*) ok ;;
  *) bad "A2 THE POINT: the row is closed failed with APPLY_FAILED rc=1: got '$R' in $(cat "$T/req.txt")" ;;
esac
A2_REASON="$R"
[ -n "$(patch RB-21-aaaaaaaa done)" ] && bad "A2 a refused apply never closes the row done" || ok
grep -q '"status":"queued"' "$T/req.txt" && bad "A2 the row is never released to queued" || ok
[ "$(wc -l < "$T/fail.txt" | tr -d ' ')" = 1 ] && grep -q '^tproj RB-21-aaaaaaaa ' "$T/fail.txt" \
  && ok || bad "A2 THE POINT: mc_pool_rebase_fail marks the hub job file, once: $(cat "$T/fail.txt")"
[ "$(acount "$LOCALDIR/RESULT")" = 1 ] && ok || bad "A2 exactly one ALERTS line names the RESULT: $(ALERTS)"
grep -q 'rc=1 ' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "A2 the ALERTS line says rc=1: $(ALERTS)"
grep -q 'nothing retries this on its own' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "A2 the old CLAIMED text is gone: $(ALERTS)" || ok
grep -q 'machine destroy' "$T/fly.txt" && ok || bad "A2 the machine is still destroyed"
[ -f "$LOCALDIR/REBASE" ] && bad "A2 no REBASE sentinel when the apply refused" || ok
[ -f "$LOCALDIR/COMMENTED" ] && ok || bad "A2 the dir owes no board close-out"
grep -q "rebase RB-21-aaaaaaaa: apply refused rc=1 .*FAILED" "$H/logs/fly-pool.log" 2>/dev/null \
  && ok || bad "A2 fly-pool.log says the row closed FAILED: $(cat "$H/logs/fly-pool.log" 2>/dev/null)"

# ── A3 no lib at all: the seeded rc 127 also closes the row FAILED ─────────
no_lib
pool RB-22-bbbbbbbb 22 "$RBRES" 0
R=$(reason_of RB-22-bbbbbbbb failed)
case "$R" in
  "APPLY_FAILED rc=127: "*) ok ;;
  *) bad "A3 THE POINT: a missing apply closes the row failed with APPLY_FAILED rc=127: got '$R' in $(cat "$T/req.txt")" ;;
esac
[ "$(acount 'rc=127')" = 1 ] && ok || bad "A3 one ALERTS line with rc=127: $(ALERTS)"
[ -n "$(patch RB-22-bbbbbbbb done)" ] && bad "A3 never done" || ok
[ -s "$T/fail.txt" ] && bad "A3 no fail function to call without the lib" || ok
fixture_lib

# ── A4 a rebase word on a key that is not RB-: row FAILED, no apply ────────
for KR in "BH-23|23|CONFLICT a.txt b.txt" "BH-24|24|REBASE_SETUP_FAILED no repo" "RR-25-aaaaaaaa|25|GATE_RED unit"; do
  K=${KR%%|*}; REST=${KR#*|}; ID=${REST%%|*}; W=${REST#*|}
  pool "$K" "$ID" "$W" 0
  [ -s "$T/apply.txt" ] && bad "A4 $K '$W' never reaches the apply: $(cat "$T/apply.txt")" || ok
  [ -n "$(patch "$K" failed)" ] && ok || bad "A4 THE POINT: $K '$W' closes the row failed: $(cat "$T/req.txt")"
  [ -n "$(patch "$K" done)" ] && bad "A4 $K is never closed done" || ok
  grep -q '"status":"queued"' "$T/req.txt" && bad "A4 $K is never released to queued" || ok
  [ -f "$H/state/remote-results/tproj/$K.json" ] && bad "A4 $K writes no remote result" || ok
  [ -n "$LOCALDIR" ] && [ -f "$LOCALDIR/COMMENTED" ] && ok || bad "A4 $K stamps COMMENTED"
  [ "$(acount "$K")" = 1 ] && ok || bad "A4 $K exactly one ALERTS line: $(ALERTS)"
  case "$K" in
    BH-*) case "$(reason_of "$K" failed)" in
            "rebase word on a non-rebase key"*) ok ;;
            *) bad "A4 $K the mismatch reason says what it is: '$(reason_of "$K" failed)'" ;;
          esac ;;
  esac
done

# ── A6 an RB- key keeps its rebase arm for all five words ──────────────────
for W in "REBASED bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "CONFLICT a.txt" "GATE_RED unit" \
         "REBASE_SETUP_FAILED no repo" "REBASE_LEASE_REJECTED moved"; do
  pool RB-27-aaaaaaaa 27 "$W
PR: https://github.com/o/r/pull/27" 0
  [ "$(wc -l < "$T/apply.txt" | tr -d ' ')" = 1 ] && ok || bad "A6 '$W' reaches the apply once: $(cat "$T/apply.txt")"
  [ -n "$(patch RB-27-aaaaaaaa done)" ] && ok || bad "A6 '$W' rc 0 closes the row done"
  [ -f "$LOCALDIR/REBASE" ] && ok || bad "A6 '$W' rc 0 stamps REBASE"
  [ -f "$H/state/remote-results/tproj/RB-27-aaaaaaaa.json" ] && bad "A6 '$W' is never a remote result" || ok
done
# A leading space is not a first-column word: the build path, untouched.
pool BH-28 28 " GATE_RED x" 1
[ -s "$T/apply.txt" ] && bad "A6 ' GATE_RED x' never reaches the apply" || ok
[ -n "$(patch BH-28 failed)" ] && bad "A6 ' GATE_RED x' is not a mismatch" || ok
# The orphan-row release (BH-7382) acts on a claimed row only, so neither a
# done nor a failed close is ever released.
( . "$DIR/bin/lib/pool-orphan-rows.sh" || exit 9
  for S in done failed; do
    pool_orphan_row_verdict "$S" fly hub hub BH-21 99999 60 0 0 0 absent
  done ) > "$T/verdict.txt" 2>&1
[ "$(grep -c "^keep$(printf '\t')not-claimed" "$T/verdict.txt")" = 2 ] \
  && ok || bad "A6 the orphan-row release keeps done and failed rows: $(cat "$T/verdict.txt")"

# ── A7 the APPLY_FAILED reason never reads as a resolver rebuild trigger ───
[ -n "$A2_REASON" ] && ok || bad "A7 A2 captured a reason"
[[ "$A2_REASON" =~ (died|deferred)\ [0-9]+\ times ]] \
  && bad "A7 APPLY_FAILED must not match the resolver's row triggers: $A2_REASON" || ok

echo "pool-gate-red-build-key.bh-8886-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
