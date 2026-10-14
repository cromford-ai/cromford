#!/bin/bash
# tests/rebase-on-pool-reap.bh-986-test.sh — the RB- stand-down tells the truth.
#
# WHAT THIS IS ABOUT (BH-986). Both `RB-*` arms of bin/fly-pool.sh (the
# BUILD_DEFERRED arm and the dead-machine arm) close the queue row `failed` and
# then write an ALERTS line promising that `bin/merge-conductor.sh re-enqueues
# the rebase on its next tick`. It does not: the hub job file
# state/merge-conductor/rebase/<owner_repo>_<num>_<head>.json is left at
# `status: pool`, mc_rb_state reads a `pool` file as `running` until
# started_at + MC_REBASE_POOL_TIMEOUT_SECS (5400s), so the conductor holds the
# PR in REBASING for up to 90 minutes before it parks it in NEEDS_REBASE.
#
# The fix has two halves and this suite drives both:
#   1. mc_pool_rebase_fail marks the hub job file `failed` (rc 4), so the
#      conductor's failed/stale arm reaches the PR on its NEXT tick.
#   2. the two ALERTS texts name the real remaining recovery (the NEEDS_REBASE
#      TTL when the job file was failed, the pool timeout when it could not be),
#      and the deferred arm's queue-row reason drops the runner's RESULT text.
#
# WHY DRIVEN AND NOT GREPPED (D2/D3). Every claim is asserted on an OUTPUT the
# production entry point produced: the job file's JSON after a real
# bin/fly-pool.sh reap, the ALERTS.log text, and the queue PATCH body captured
# by the curl sink. §1 is the only unit section and it drives the real lib.
#
# MUTATIONS THAT MUST TURN THIS SUITE RED (checked 2026-09-19):
#   - drop the mc_pool_rebase_fail call from the deferred arm   -> §2 red
#   - drop it from the dead arm                                 -> §3 red
#   - put the old "next tick if the PR still needs one" text back in either arm
#                                                               -> §2/§3/§4 red
#   - restore the $DROW interpolation in the deferred row reason -> §2 red
#   - let mc_pool_rebase_fail rewrite a `done` job file          -> §1 red
#   - hardcode the NEEDS_REBASE TTL as "(30 min)" in either arm -> §2/§3/§4 red
#   - key the ledger row on head8 when head_sha is missing      -> §1 red
#
# Run from anywhere: bash tests/rebase-on-pool-reap.bh-986-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

RSHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RKEY=RB-21-aaaaaaaa
OLDCLAIM='next tick if the PR still needs one'

H="$T/h"
RBD="$H/state/merge-conductor/rebase"
JF="$RBD/o_r_21_$RSHA.json"

seed_job() { # seed_job <status>
  mkdir -p "$RBD"
  jq -nc --arg s "$1" --arg h "$RSHA" --arg o "$RBD/o_r_21_$RSHA.out" \
    '{status:$s,pid:0,started_at:1000,finished_at:0,rc:"-",head_sha:$h,new_head:"-",out_file:$o}' \
    > "$JF"
}

# ════════════════════════════════════════════════════════════════════════════
# §1  mc_pool_rebase_fail — the unit, against the REAL lib
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$H/logs"
( export HARNESS="$H"
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/merge-conductor-lib.sh" 2>/dev/null
  command -v mc_pool_rebase_fail >/dev/null 2>&1 || { echo "MISSING"; exit 9; }
  exit 0 ) > "$T/have.txt" 2>/dev/null
HAVE=$?
[ "$HAVE" = 0 ] && ok || bad "1.0 the real lib must define mc_pool_rebase_fail (rc $HAVE)"

unit() { # unit <key> [status-to-seed]; prints "<rc>"
  ( export HARNESS="$H"
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/merge-conductor-lib.sh" 2>/dev/null
    mc_pool_rebase_fail tproj "$1" "stand-down under test" >/dev/null 2>&1
    printf '%s' "$?" )
}

seed_job pool
RC=$(unit "$RKEY")
[ "$RC" = 0 ] && ok || bad "1.1 a seeded pool job file is failed, rc 0, got rc $RC"
[ "$(jq -r .status "$JF")" = failed ] \
  && ok || bad "1.1 the job file flips to failed, got $(cat "$JF")"
[ "$(jq -r .rc "$JF")" = 4 ] \
  && ok || bad "1.1 the recorded rc is mc_rebase's 4 (setup failed), got $(jq -r .rc "$JF")"
[ "$(jq -r .head_sha "$JF")" = "$RSHA" ] \
  && ok || bad "1.1 head_sha is preserved, got $(jq -r .head_sha "$JF")"
[ "$(jq -r .started_at "$JF")" = 1000 ] \
  && ok || bad "1.1 started_at is preserved, got $(jq -r .started_at "$JF")"

# A `done` file is a late machine RESULT, which is a FACT — never rewritten.
seed_job done
B4=$(cat "$JF")
RC=$(unit "$RKEY")
[ "$RC" = 1 ] && ok || bad "1.2 a done job file is refused, rc 1, got rc $RC"
[ "$(cat "$JF")" = "$B4" ] && ok || bad "1.2 THE POINT: a done file is byte-identical after the call"

# An already-failed file is nothing left to do either.
seed_job failed
RC=$(unit "$RKEY")
[ "$RC" = 1 ] && ok || bad "1.3 an already-failed job file answers rc 1, got rc $RC"

# A non-rebase key never touches a rebase job file.
seed_job pool
RC=$(unit TK-9)
[ "$RC" = 1 ] && ok || bad "1.4 a key that is not RB-<num>-<head8> answers rc 1, got rc $RC"
[ "$(jq -r .status "$JF")" = pool ] \
  && ok || bad "1.4 THE POINT: TK-9 left the rebase job file alone, got $(cat "$JF")"

# No job file at all: nothing found, nothing written.
rm -f "$JF"
RC=$(unit "$RKEY")
[ "$RC" = 1 ] && ok || bad "1.5 no job file on the box answers rc 1, got rc $RC"
ls "$RBD"/*.json >/dev/null 2>&1 && bad "1.5 and writes none" || ok

# The ledger row. mc_pool_rebase_enqueue wrote `<url>@<40-sha>`; a row keyed on
# the 8-hex head8 can never match it, so a job file that lost its head_sha gets
# NO row rather than an orphan one — the same "no honest key without both
# halves" rule mc_pool_rebase_apply already follows.
unit_ledger() { # unit_ledger <key>  -> prints rc; ledger calls land in $T/ledger.txt
  ( export HARNESS="$H"
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/merge-conductor-lib.sh" 2>/dev/null
    job_ledger_put() { printf '%s\n' "$*" >> "$T/ledger.txt"; return 0; }
    mc_pool_rebase_fail tproj "$1" "stand-down under test" >/dev/null 2>&1
    printf '%s' "$?" )
}

: > "$T/ledger.txt"
seed_job pool
RC=$(unit_ledger "$RKEY")
[ "$RC" = 0 ] && ok || bad "1.6 a pool job file with a real head_sha still fails, rc 0, got rc $RC"
grep -qF "rebase https://github.com/o/r/pull/21@$RSHA FAILED" "$T/ledger.txt" \
  && ok || bad "1.6 the ledger row is keyed on <url>@<40-sha>, got: $(cat "$T/ledger.txt")"

: > "$T/ledger.txt"
mkdir -p "$RBD"
jq -nc --arg o "$RBD/o_r_21_$RSHA.out" \
  '{status:"pool",pid:0,started_at:1000,finished_at:0,rc:"-",head_sha:"-",new_head:"-",out_file:$o}' \
  > "$JF"
RC=$(unit_ledger "$RKEY")
[ "$RC" = 0 ] && ok || bad "1.7 a job file with no head_sha is still marked failed, rc 0, got rc $RC"
[ "$(jq -r .status "$JF")" = failed ] \
  && ok || bad "1.7 and the file really flipped, got $(cat "$JF")"
grep -q '@aaaaaaaa ' "$T/ledger.txt" \
  && bad "1.7 THE POINT: no orphan 8-hex ledger key — got: $(cat "$T/ledger.txt")" || ok
[ ! -s "$T/ledger.txt" ] \
  && ok || bad "1.7 with no honest key the row is skipped entirely, got: $(cat "$T/ledger.txt")"

# ════════════════════════════════════════════════════════════════════════════
# The pool fixture — bin/fly-pool.sh driven whole (the bh-542 §7 pattern)
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/fly" "$H/state/fly-pool/tproj" "$H/state/remote-results/tproj" \
         "$H/state/build-queue/tproj" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
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
  *"machine status"*) echo "State: ${MSTATE_FIX:-started}" ;;
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

# The fixture lib §4 uses: an apply, and deliberately NO mc_pool_rebase_fail —
# the half-synced box, where the arms must still tell the truth.
fixture_lib() {
  cat > "$H/bin/lib/merge-conductor-lib.sh" <<'LIB'
mc_pool_rebase_apply() { printf '%s\n' "$*" >> "$APPLY_SINK"; return "${APPLY_RC:-0}"; }
LIB
}
# BH-680: merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# `exit 1`s when a module is missing, so the real lib only loads if the modules
# travel with it — without them fly-pool.sh dies at the source line and §2/§3/§5
# would assert on a run that never happened.
real_lib() {
  cp "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/merge-conductor-lib.sh"
  mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
}

QD="$H/state/build-queue/tproj"
pool() { # pool <key> <ticket-id> <result-text> [apply-rc] [machine-state]
  rm -rf "$T/h/builds"/* "$T/h/state/remote-results/tproj"/* \
         "$T/h/state/build-queue/tproj"/* "$T/h/state/fly-pool/tproj"/*
  rm -f "$H/logs/ALERTS.log" "$H/logs/fly-pool.log"
  : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/fly.txt"; : > "$T/apply.txt"
  : > "$T/beat.txt"; : > "$T/gh.txt"
  printf '%s' "$3" > "$T/result.txt"
  jq -nc --arg k "$1" --arg t "$2" '{machine:"m1",key:$k,ticket_id:$t,attempt:0}' \
    > "$H/state/fly-pool/tproj/m1.json"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok POOL_PR_VERIFY_SLEEP=0 \
           REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" FLY_SINK="$T/fly.txt" \
           APPLY_SINK="$T/apply.txt" BEAT_SINK="$T/beat.txt" GH_SINK="$T/gh.txt" \
           RESULT_FIXTURE="$T/result.txt" APPLY_RC="${4:-0}" MSTATE_FIX="${5:-started}"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  LOCALDIR=$(ls -d "$H/builds/pool-tproj-$1-"* 2>/dev/null | head -1)
}
ALERTS() { cat "$H/logs/ALERTS.log" 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
# §2  the BUILD_DEFERRED arm: job file failed, honest ALERTS, clean row reason
# ════════════════════════════════════════════════════════════════════════════
real_lib
seed_job pool
pool "$RKEY" 21 "BUILD_DEFERRED warm-up failed" 0
[ "$(jq -r .status "$JF")" = failed ] \
  && ok || bad "2.1 THE POINT: the deferred arm marks the hub job file failed, got $(cat "$JF" 2>/dev/null)"
[ "$(jq -r .rc "$JF")" = 4 ] && ok || bad "2.1 with rc 4, got $(jq -r .rc "$JF" 2>/dev/null)"
N=$(grep -c "$RKEY" "$H/logs/ALERTS.log" 2>/dev/null | head -1)
[ "$N" = 1 ] && ok || bad "2.2 exactly one ALERTS line naming the key, got $N: $(ALERTS)"
grep -q 'NEEDS_REBASE TTL' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "2.3 the ALERTS line names the real recovery (NEEDS_REBASE TTL): $(ALERTS)"
# mc_ttl reads MC_TTL_NEEDS_REBASE from the environment before its 1800s
# default (merge-conductor-lib.sh mc_ttl), so a frozen "(30 min)" in the text is
# wrong on any box that sets it — the same overstated-claim class this ticket
# exists to remove. The sibling sentence already names
# MC_REBASE_POOL_TIMEOUT_SECS; this one names its knob too.
grep -q 'MC_TTL_NEEDS_REBASE' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "2.3b the TTL sentence names the knob that sets it: $(ALERTS)"
grep -q '30 min' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "2.3c THE POINT: the TTL is not a hardcoded number: $(ALERTS)" || ok
grep -qF "$OLDCLAIM" "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "2.4 THE POINT: the overstated next-tick promise is gone: $(ALERTS)" || ok
grep -q 'warm-up failed' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "2.5 the ALERTS line still carries the runner's text: $(ALERTS)"
# The sentence is INTERPOLATED, not printed as a literal: a mis-typed
# `RBREC=RBREC="…"` assignment (caught in this build's own diff) still contains
# every keyword above and still reads as a pass without this line.
grep -q 'RBREC' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "2.5b the recovery sentence leaked its variable name into the line: $(ALERTS)" || ok
grep -q "PATCH https://jobs.invalid/api/queue .*\"key\":\"$RKEY\".*\"status\":\"failed\"" "$T/req.txt" \
  && ok || bad "2.6 the row is still closed failed: $(cat "$T/req.txt")"
REASON=$(grep -o "\"key\":\"$RKEY\"[^}]*" "$T/req.txt" | grep -o '"reason":"[^"]*"' | head -1)
case "$REASON" in
  *"warm-up failed"*) bad "2.7 THE POINT: the row reason must not carry the RESULT text: $REASON" ;;
  *"row FAILED, not requeued"*) ok ;;
  *) bad "2.7 the row reason is the constant stand-down sentence, got: $REASON" ;;
esac
grep -qE '"reason":"[^"]*(died|deferred) [0-9]+ times' "$T/req.txt" \
  && bad "2.8 the reason must not read as a resolver rebuild trigger: $(cat "$T/req.txt")" || ok
grep -q "POST https://jobs.invalid/api/queue .*\"key\":\"$RKEY\"" "$T/req.txt" \
  && bad "2.9 nothing may re-enqueue the row: $(cat "$T/req.txt")" || ok
ls "$QD"/RB-*.json >/dev/null 2>&1 && bad "2.10 no requeue file — $(ls "$QD")" || ok
ls "$QD"/RB-*.failed.json >/dev/null 2>&1 && bad "2.10 and no .failed.json either" || ok

# ════════════════════════════════════════════════════════════════════════════
# §3  the dead-machine arm
# ════════════════════════════════════════════════════════════════════════════
real_lib
seed_job pool
pool "$RKEY" 21 "" 0 stopped
[ "$(jq -r .status "$JF")" = failed ] \
  && ok || bad "3.1 THE POINT: the dead arm marks the hub job file failed, got $(cat "$JF" 2>/dev/null)"
[ "$(jq -r .rc "$JF")" = 4 ] && ok || bad "3.1 with rc 4, got $(jq -r .rc "$JF" 2>/dev/null)"
N=$(grep -c "$RKEY" "$H/logs/ALERTS.log" 2>/dev/null | head -1)
[ "$N" = 1 ] && ok || bad "3.2 exactly one ALERTS line naming the key, got $N: $(ALERTS)"
grep -q 'NEEDS_REBASE TTL' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "3.3 the ALERTS line names the real recovery: $(ALERTS)"
# mc_ttl reads MC_TTL_NEEDS_REBASE from the environment before its 1800s
# default (merge-conductor-lib.sh mc_ttl), so a frozen "(30 min)" in the text is
# wrong on any box that sets it — the same overstated-claim class this ticket
# exists to remove. The sibling sentence already names
# MC_REBASE_POOL_TIMEOUT_SECS; this one names its knob too.
grep -q 'MC_TTL_NEEDS_REBASE' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "3.3b the TTL sentence names the knob that sets it: $(ALERTS)"
grep -q '30 min' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "3.3c THE POINT: the TTL is not a hardcoded number: $(ALERTS)" || ok
grep -qF "$OLDCLAIM" "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "3.4 THE POINT: the overstated next-tick promise is gone: $(ALERTS)" || ok
grep -q "$RKEY.*died" "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "3.5 the ALERTS line still says the machine died: $(ALERTS)"
grep -q 'RBREC' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "3.5b the recovery sentence leaked its variable name into the line: $(ALERTS)" || ok
grep -q 'machine destroy' "$T/fly.txt" \
  && ok || bad "3.6 the dead machine is still destroyed: $(cat "$T/fly.txt")"
grep -q "PATCH https://jobs.invalid/api/queue .*\"key\":\"$RKEY\".*\"status\":\"failed\"" "$T/req.txt" \
  && ok || bad "3.7 the row is still closed failed: $(cat "$T/req.txt")"
ls "$QD"/RB-*.json >/dev/null 2>&1 && bad "3.8 no requeue file — $(ls "$QD")" || ok

# ════════════════════════════════════════════════════════════════════════════
# §4  a half-synced box: no mc_pool_rebase_fail, so the text names the timeout
# ════════════════════════════════════════════════════════════════════════════
for MS in started stopped; do
  fixture_lib
  seed_job pool
  if [ "$MS" = started ]; then pool "$RKEY" 21 "BUILD_DEFERRED warm-up failed" 0
  else pool "$RKEY" 21 "" 0 stopped; fi
  grep -q "PATCH https://jobs.invalid/api/queue .*\"key\":\"$RKEY\".*\"status\":\"failed\"" "$T/req.txt" \
    && ok || bad "4.$MS the row is still closed failed: $(cat "$T/req.txt")"
  grep -q 'MC_REBASE_POOL_TIMEOUT_SECS' "$H/logs/ALERTS.log" 2>/dev/null \
    && ok || bad "4.$MS with no mc_pool_rebase_fail the ALERTS line names the pool timeout: $(ALERTS)"
  grep -q '30 min' "$H/logs/ALERTS.log" 2>/dev/null \
    && bad "4.$MS the TTL in the timeout sentence is not hardcoded either: $(ALERTS)" || ok
  grep -qF "$OLDCLAIM" "$H/logs/ALERTS.log" 2>/dev/null \
    && bad "4.$MS THE POINT: never the next-tick promise: $(ALERTS)" || ok
  [ "$(jq -r .status "$JF")" = pool ] \
    && ok || bad "4.$MS nothing could mark the job file, so it is untouched: $(cat "$JF")"
  grep -q 'RBREC' "$H/logs/ALERTS.log" 2>/dev/null \
    && bad "4.$MS the recovery sentence leaked its variable name: $(ALERTS)" || ok
  N=$(grep -c "$RKEY" "$H/logs/ALERTS.log" 2>/dev/null | head -1)
  [ "$N" = 1 ] && ok || bad "4.$MS exactly one ALERTS line, got $N: $(ALERTS)"
done

# ════════════════════════════════════════════════════════════════════════════
# §5  an ordinary key is untouched (the fix is keyed on the RB- prefix only)
# ════════════════════════════════════════════════════════════════════════════
real_lib
seed_job pool
pool TK-9 9 "" 0 stopped
[ -f "$QD/TK-9.json" ] && ok || bad "5.1 an ordinary dead key is still requeued — $(ls "$QD")"
[ "$(jq -r .status "$JF")" = pool ] \
  && ok || bad "5.2 THE POINT: TK-9 never touches a rebase job file, got $(cat "$JF")"

# ════════════════════════════════════════════════════════════════════════════
# §6  the claim is gone from the source and the map too (documentation pins)
# ════════════════════════════════════════════════════════════════════════════
grep -qF "$OLDCLAIM" "$DIR/bin/fly-pool.sh" 2>/dev/null \
  && bad "6.1 bin/fly-pool.sh still states the next-tick claim in a comment or a string" || ok
grep -qF 'next tick if the PR still needs' "$DIR/docs/verification-map/rebase-on-pool.md" \
  && bad "6.2 the map still states the next-tick claim" || ok
# The transport's own closing section must no longer call the live enqueue/apply
# path a stub, and must state what each one returns. The BH-486.1
# contract/history lines above it (which say the stubs NOW HAVE BODIES) stay.
SEC=$(sed -n '/^\*\*What the enqueue and the apply do today/,/^### /p' "$DIR/docs/verification-map/rebase-on-pool.md")
[ -n "$SEC" ] && ok || bad "6.3 the enqueue/apply section of the map could not be read"
grep -q 'stub' <<<"$(printf '%s' "$SEC")" \
  && bad "6.3 that section still calls the enqueue/apply path a stub: $SEC" || ok
grep -q 'rc 6' <<<"$SEC" \
  && ok || bad "6.4 the map states the enqueue's real rc 6: $SEC"
grep -q 'mc_pool_rebase_fail' "$DIR/docs/verification-map/rebase-on-pool.md" \
  && ok || bad "6.5 the map names mc_pool_rebase_fail as the stand-down path"
grep -q 'NEEDS_REBASE. TTL' "$DIR/docs/verification-map/rebase-on-pool.md" \
  && ok || bad "6.6 and names the TTL that actually paces the next rebase"

echo "rebase-on-pool-reap.bh-986-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
