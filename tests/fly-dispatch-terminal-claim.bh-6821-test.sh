#!/bin/bash
# tests/fly-dispatch-terminal-claim.bh-6821-test.sh — fly-dispatch never claims
# a push-rejected terminal key (BH-6821).
#
# BH-5566 went terminal on the pool, and fly-dispatch then took the key again
# "from the coordination DB": the row stayed `claimed` for 3.5 h with nothing
# building it. The claim now asks bin/lib/pool-claim-guard.sh first.
#
#   F1  flag-off rows loop, queued row + state/pool/<p>/<KEY>.terminal -> no
#       queue_claim, one "refused claim" line, the hub job file is written
#       WITHOUT a claim (fly-pool's terminal gate owns the re-arm)
#   F1b the same with a refused meta (queue_row_job_file rc 3) -> one "not
#       written (rc 3)" line, no job file
#   F2  queue_claim answers 9 and the row is `failed` -> the log names the row
#       status, no job file
#   F3  dispatch_project's rows-only claim with a terminal file -> no claim,
#       nothing pushed, the picked job removed
#   F4  control: no terminal file (a .terminal-noted sentinel alone) -> claimed
#       and materialised as before
#   G1  pool_claim_guard itself: rc 3 + reason on a terminal, rc 0 without one,
#       rc 0 (nothing read) with no harness root
#
# Drives the REAL bin/fly-dispatch.sh against a scratch harness with a jobs
# client that records every call (the bh-1367 harness, without the curl worker).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state/fly" \
         "$H/state/build-queue/tpool" "$H/state/pool/tpool" "$H/state/fly-pool/tpool" \
         "$H/state/build-queue/tone" "$H/state/pool/tone" "$T/fakebin"
{ printf 'tpool o/tpool - - 0 local\n'; printf 'tone o/tone - - 0 local\n'; } > "$H/fleet.conf"
printf 'FLY_API_TOKEN_TONE=tok-fixture-1\n' > "$H/env/fly.env"
: > "$H/env/global.env"
touch "$H/flags/builder-fly-tpool" "$H/flags/builder-fly-tone"
printf '3\n' > "$H/flags/fly-pool-tpool"
printf '{"app":"builder-tone","machine_id":"aa11bb22cc33dd"}\n' > "$H/state/fly/tone.json"

# The jobs client, recorded. $T/rows-<p> is what queue_list answers (the
# 10-field TSV), $T/claim-rc the claim's rc, $T/status the status read.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_list() { cat "$T/rows-\$1" 2>/dev/null; return 0; }
queue_claim() { printf 'claim %s\n' "\$*" >> "$T/calls"; return \$(cat "$T/claim-rc" 2>/dev/null || echo 0); }
queue_status() { printf 'status %s\n' "\$*" >> "$T/calls"; cat "$T/status" 2>/dev/null || echo queued; }
queue_release() { printf 'release %s\n' "\$*" >> "$T/calls"; return 0; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/calls"; return 0; }
build_queue_rows_only_on() { [ -f "$T/rows-only" ]; }
build_queue_active_key() { return 0; }
EOF
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-dispatch.sh "$H" >/dev/null || { echo "closure install of bin/fly-dispatch.sh failed"; exit 1; }
for f in beat.sh fly-lock-guard.sh fly-sync-harness.sh fly-results-ingest.sh overlap-guard.sh project-of.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"
done
printf '#!/bin/bash\necho started\n' > "$H/bin/fly-api.sh"
printf '#!/bin/bash\necho OK\n' > "$H/bin/triage-gate.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
chmod +x "$H/bin"/*.sh
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/tailscale"
printf '#!/bin/bash\necho "ssh $*" >> "%s/pushes"\nexit 0\n' "$T" > "$T/fakebin/ssh"
cat > "$T/fakebin/fly" <<STUB
#!/bin/bash
echo "fly \$*" >> "$T/pushes"
case "\$*" in *RESULT*) echo no ;; *wc*) echo 42 ;; esac
exit 0
STUB
chmod +x "$T/fakebin"/*

[ -f "$H/bin/lib/pool-claim-guard.sh" ] && ok \
  || bad "closure: bin/lib/pool-claim-guard.sh is not sourced by bin/fly-dispatch.sh"

dispatch() {
  : > "$T/calls"; : > "$T/pushes"; : > "$H/logs/fly-dispatch.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1
    bash "$DIR/bin/fly-dispatch.sh" >/dev/null 2>&1 )
}
reset() {
  local p
  for p in "$H/state/build-queue/tpool"/* "$H/state/build-queue/tone"/* "$H/state/pool/tpool"/* \
           "$H/state/pool/tone"/* "$H/state/fly/tone-active.json" "$H/state/fly/.rowjob-tone" \
           "$T/rows-tpool" "$T/rows-tone" "$T/claim-rc" "$T/status" "$T/rows-only"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
row() { printf '%s\t%s\t%s\tqueued\tfly\t1\t-\t-\t-\t{}\n' "$1" "$2" "$3"; }
terminal_for() { # terminal_for <p> <KEY>
  jq -nc '{branch:"ticket/bh-77",head_sha:"f56eba45f0a1b2c3d4e5f60718293a4b5c6d7e8f",reason:"push rejected",created_at:"2026-10-14 23:07:10Z",ticket_id:"77"}' \
    > "$H/state/pool/$1/$2.terminal"
}
claims() { grep -c '^claim ' "$T/calls" 2>/dev/null || true; }

# ── F1: flag-off rows loop refuses a terminal key ─────────────────────────
reset
row tpool BH-77 77 > "$T/rows-tpool"
terminal_for tpool BH-77
dispatch
[ "$(claims)" = 0 ] && ok || bad "F1: a terminal key must not be claimed: $(cat "$T/calls")"
grep -q 'refused claim of BH-77: push-rejected terminal (state/pool/tpool/BH-77.terminal, head f56eba45f0a1b2c3d4e5f60718293a4b5c6d7e8f, since 2026-10-14 23:07:10Z)' \
  "$H/logs/fly-dispatch.log" && ok || bad "F1: the refusal must name the terminal: $(cat "$H/logs/fly-dispatch.log")"
[ "$(jq -r '.key' "$H/state/build-queue/tpool/BH-77.json" 2>/dev/null)" = BH-77 ] && ok \
  || bad "F1: the hub job file must be written (unclaimed) for fly-pool's terminal gate"
# A second tick: the file is there, nothing is claimed and nothing re-said.
dispatch
[ "$(claims)" = 0 ] && ok || bad "F1: a second tick must not claim either"

# ── F1b: a refused meta on the terminal path is said, not swallowed ───────
reset
printf 'tpool\tBH-77\t77\tqueued\tfly\t1\t-\t-\t-\t{"continue_branch":"ticket/x;rm"}\n' > "$T/rows-tpool"
terminal_for tpool BH-77
dispatch
[ "$(claims)" = 0 ] && ok || bad "F1b: a terminal key must not be claimed: $(cat "$T/calls")"
grep -q 'hub job file for BH-77 not written (rc 3)' "$H/logs/fly-dispatch.log" && ok \
  || bad "F1b: a refused meta must be said with its rc: $(cat "$H/logs/fly-dispatch.log")"
[ -f "$H/state/build-queue/tpool/BH-77.json" ] && bad "F1b: a refused meta wrote a job file" || ok

# ── F2: a refused claim says the row's status ─────────────────────────────
reset
row tpool BH-78 78 > "$T/rows-tpool"
echo 9 > "$T/claim-rc"; echo failed > "$T/status"
dispatch
[ "$(claims)" = 1 ] && ok || bad "F2: one claim attempt expected, got $(claims)"
grep -q 'claim of BH-78 refused (rc 9): row is failed' "$H/logs/fly-dispatch.log" && ok \
  || bad "F2: the refused claim must name the row status: $(cat "$H/logs/fly-dispatch.log")"
[ -f "$H/state/build-queue/tpool/BH-78.json" ] && bad "F2: a refused claim wrote a job file" || ok

# ── F3: dispatch_project's rows-only claim refuses a terminal key ─────────
reset
: > "$T/rows-only"
row tone TK-79 79 > "$T/rows-tone"
terminal_for tone TK-79
dispatch
[ "$(claims)" = 0 ] && ok || bad "F3: the rows-only claim must not run on a terminal key: $(cat "$T/calls")"
grep -q 'refused claim of TK-79: push-rejected terminal' "$H/logs/fly-dispatch.log" && ok \
  || bad "F3: the refusal line is missing: $(cat "$H/logs/fly-dispatch.log")"
grep -q 'job.json' "$T/pushes" && bad "F3: a job was pushed: $(cat "$T/pushes")" || ok
[ -e "$H/state/fly/.rowjob-tone/TK-79.json" ] && bad "F3: the picked job file must be removed" || ok
[ -f "$H/state/fly/tone-active.json" ] && bad "F3: an active job was written" || ok

# ── F4: control — no terminal file, the claim runs ────────────────────────
reset
row tpool BH-80 80 > "$T/rows-tpool"
: > "$H/state/pool/tpool/BH-80.terminal-noted"
dispatch
[ "$(claims)" = 1 ] && ok || bad "F4: a key with no terminal must be claimed, got $(claims)"
[ "$(jq -r '.key' "$H/state/build-queue/tpool/BH-80.json" 2>/dev/null)" = BH-80 ] && ok \
  || bad "F4: the claimed row must be materialised"
grep -q 'refused claim' "$H/logs/fly-dispatch.log" && bad "F4: a refusal was logged" || ok

# ── G1: the guard on its own ──────────────────────────────────────────────
reset
terminal_for tpool BH-81
OUT=$(HARNESS="$H" bash -c '. "$0"; pool_claim_guard tpool BH-81; echo "rc=$?"' "$H/bin/lib/pool-claim-guard.sh")
[ "$(tail -1 <<<"$OUT")" = rc=3 ] && ok || bad "G1: a terminal must answer rc 3, got: $OUT"
[ "$(head -1 <<<"$OUT")" = 'push-rejected terminal (state/pool/tpool/BH-81.terminal, head f56eba45f0a1b2c3d4e5f60718293a4b5c6d7e8f, since 2026-10-14 23:07:10Z)' ] \
  && ok || bad "G1: the reason must name the file, head and since, got: $OUT"
# An empty or unparsable terminal is still a terminal: rc 3, with ? for each field.
for body in '' 'not json' '{"head_sha":""}'; do
  printf '%s' "$body" > "$H/state/pool/tpool/BH-83.terminal"
  OUT=$(HARNESS="$H" bash -c '. "$0"; pool_claim_guard tpool BH-83; echo "rc=$?"' "$H/bin/lib/pool-claim-guard.sh")
  [ "$OUT" = $'push-rejected terminal (state/pool/tpool/BH-83.terminal, head ?, since ?)\nrc=3' ] && ok \
    || bad "G1: a terminal holding '$body' must answer the ? reason and rc 3, got: $OUT"
done
OUT=$(HARNESS="$H" bash -c '. "$0"; pool_claim_guard tpool BH-82; echo "rc=$?"' "$H/bin/lib/pool-claim-guard.sh")
[ "$OUT" = rc=0 ] && ok || bad "G1: no terminal must answer rc 0 and print nothing, got: $OUT"
OUT=$(env -u HARNESS -u H bash -c '. "$0"; pool_claim_guard tpool BH-81; echo "rc=$?"' "$H/bin/lib/pool-claim-guard.sh")
[ "$OUT" = rc=0 ] && ok || bad "G1: no harness root reads nothing and answers rc 0, got: $OUT"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
