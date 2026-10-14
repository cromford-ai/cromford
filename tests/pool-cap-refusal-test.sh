#!/bin/bash
# tests/pool-cap-refusal-test.sh — the pool-cap refusal class (2026-09-11).
#
# WHAT WENT WRONG. Every Fly pool machine booted as box `pool-<project>`, so the
# ledger's `box * build 1` rule counted the whole pool as ONE box: while one
# machine built, every other machine's claim came back "REFUSED box :: box max 1
# already running". bin/run-build.sh turns that into BUILD_DEFERRED + exit 3,
# which is correct — on a normal box the queue re-offers the ticket next tick.
# But bin/fly-pool.sh filed ANY reaped RESULT as `done`, so the deferral was
# recorded as a finished build and the ticket was never offered again
# (project-5 TK-268/TK-270 x3 each, project-4 TK-1515/1566/1571/1576).
#
# Three claims are driven here, because all three fail SILENTLY in production:
#   1. a reaped BUILD_DEFERRED requeues and never closes the row `done`
#   2. a pool machine's box name is per MACHINE, and it is the name the ledger
#      actually receives (jobs-client falls through to `hostname` there)
#   3. run-build.sh pushes the branch BEFORE every review, so a machine reaped
#      mid-pipeline cannot take the built tree with it (TK-269 lost one today)
# Run from anywhere: tests/pool-cap-refusal-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ══ 1. THE REAP: a deferral is requeued, never filed as a finished build ════
mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/env" \
         "$T/h/state/fly" "$T/h/state/fly-pool/project-5" "$T/h/state/build-queue/project-5" \
         "$T/h/state/remote-results/project-5" "$T/h/builds" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/result-prefix-ok.sh" "$T/h/bin/"
cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/fleet.conf" "$T/h/fleet.conf"
printf 'HARNESS_SECRET=test-secret\n' > "$T/h/env/global.env"
: > "$T/h/env/fly.env"
printf '3\n' > "$T/h/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$T/h/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$T/h/state/fly/project-5.json"
# The beat is an assertion too: a deferral that beats `pool_result` puts a build
# that never ran on the console as one that finished.
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\necho OPEN\n' > "$T/fakebin/gh"
# Any ssh at all is a failure here: there is no result to relay.
printf '#!/bin/bash\necho "ssh $*" >> "$SSH_SINK"\nexit 0\n' > "$T/fakebin/ssh"

# base64 dialect shim, same reasoning as tests/pool-relay-rowfirst-test.sh: GNU
# takes -d/-w0, BSD takes -D/-b 0, and the scripts speak GNU.
cat > "$T/fakebin/base64" <<'STUB'
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
STUB

# flyctl: one live machine whose canonical RESULT is the refusal run-build wrote.
# Loose patterns on single tokens — mexec wraps its command through printf %q.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
DEFER='BUILD_DEFERRED REFUSED box :: box max 1 already running'
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *base64*RESULT*)    printf '%s\n' "$DEFER" | /usr/bin/base64 -w0 ;;
  *base64*)           : ;;
  *head*RESULT*)      echo "$DEFER" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
STUB

# The worker: every call is recorded, and that log IS the assertion.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/artifacts\?*) printf '{"artifacts":[]}\n200\n' ;;
  */api/queue)        printf '{"queued":{"ticket_key":"TK-268","status":"queued"}}\n201\n' ;;
  *)                  printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/h/bin/beat.sh" "$T/h/bin/result-prefix-ok.sh" "$T/fakebin"/*

reap() { # reap <attempt-on-the-machine> [deferrals-on-the-machine]
  rm -rf "$T/h/builds"/*; rm -f "$T/h/state/build-queue/project-5"/*.json
  : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/beat.txt"; : > "$T/h/logs/ALERTS.log"
  : > "$T/h/logs/fly-pool.log"
  jq -nc --argjson a "$1" --argjson d "${2:-0}" \
    '{machine:"m1",key:"TK-268",ticket_id:"268",attempt:$a,deferrals:$d}' \
    > "$T/h/state/fly-pool/project-5/m1.json"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           FLEET_CONF="$T/h/fleet.conf" REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" \
           BEAT_SINK="$T/beat.txt" FLY_API_TOKEN_project-5=tok \
           FLY_BIN_DIR="$T/fakebin"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

reap 0
# THE HEADLINE: the row must never be closed `done` for a build that never ran.
grep -q 'PATCH .*"status":"done"' "$T/req.txt" \
  && bad "a deferral was filed as a finished build: $(grep PATCH "$T/req.txt")" || ok
# ...it is requeued instead, by close-then-enqueue, carrying attempt 1.
grep -q 'PATCH .*"status":"failed"' "$T/req.txt" \
  && ok || bad "the dead attempt was never closed before the re-enqueue: $(cat "$T/req.txt")"
QPOST=$(grep 'POST .*/api/queue ' "$T/req.txt" | head -1 | cut -d' ' -f3-)
[ "$(jq -r '.attempt' <<<"$QPOST" 2>/dev/null)" = 0 ] \
  && ok || bad "a stand-down spent a DEATH attempt (fly-pool parks at 2 deaths): $QPOST"
[ "$(jq -r '.meta' <<<"$QPOST" 2>/dev/null | jq -r '.deferrals')" = 1 ] \
  && ok || bad "the re-enqueue does not carry deferrals=1 in the row meta: $QPOST"
grep -q '"target":"fly"' "$T/req.txt" \
  && ok || bad "a pool build must be re-queued to the fly lane, not to local"
# The file queue is the fallback and must be re-offered too.
[ -f "$T/h/state/build-queue/project-5/TK-268.json" ] \
  && ok || bad "the queue file was not rewritten for the next tick"
[ "$(jq -r .attempt "$T/h/state/build-queue/project-5/TK-268.json" 2>/dev/null)" = 0 ] \
  && ok || bad "the requeued file moved the death counter"
[ "$(jq -r .deferrals "$T/h/state/build-queue/project-5/TK-268.json" 2>/dev/null)" = 1 ] \
  && ok || bad "the requeued file does not carry deferrals 1"
# ONE hub-side ALERTS line, because run-build's own line died with the machine.
grep -q 'pool build DEFERRED' "$T/h/logs/ALERTS.log" \
  && ok || bad "the hub was never told: $(cat "$T/h/logs/ALERTS.log")"
grep -q 'requeued attempt 1' "$T/h/logs/ALERTS.log" \
  && ok || bad "the alert does not say what happened next: $(cat "$T/h/logs/ALERTS.log")"
grep -q 'REFUSED box' "$T/h/logs/ALERTS.log" \
  && ok || bad "the alert drops the reason, which is the thing an operator acts on"
# The beat says deferred, not result.
grep -q 'pool_deferred' "$T/beat.txt" \
  && ok || bad "the beat did not say deferred: $(cat "$T/beat.txt")"
grep -q 'pool_result' "$T/beat.txt" \
  && bad "a deferral beat as a finished result" || ok
# Nothing is relayed: there is no result to hand anyone, and a staged build dir
# would put a close-out through a sweep that has nothing to close.
[ ! -s "$T/ssh.txt" ] && ok || bad "a deferral was relayed over ssh: $(cat "$T/ssh.txt")"
[ ! -f "$T/h/state/remote-results/project-5/TK-268.json" ] \
  && ok || bad "a deferral was queued for the owning box as a result"
# ...but the build dir survives for audit.
ls -d "$T/h/builds/pool-project-5-TK-268-"*/RESULT >/dev/null 2>&1 \
  && ok || bad "the reaped RESULT was not kept for audit"
# ...carrying the sentinel that keeps bin/pipeline-health.sh from paging for a
# close-out this dir will never owe.
ls -d "$T/h/builds/pool-project-5-TK-268-"*/DEFERRED >/dev/null 2>&1 \
  && ok || bad "the kept deferral dir has no DEFERRED sentinel, so pipeline-health will page for it hourly"

# ══ 2. THE CAP: six stand-downs is a human's problem, not a loop ════════════
# Counted on STAND-DOWNS, never on deaths: a machine that has died twice but
# stood down none is still allowed to try.
reap 5 0
grep -q 'POST .*/api/queue' "$T/req.txt" \
  && ok || bad "a death count was read as a stand-down and the ticket was parked: $(cat "$T/req.txt")"
reap 0 5
grep -q 'POST .*/api/queue' "$T/req.txt" \
  && bad "the 6th deferral was requeued instead of parked: $(grep POST "$T/req.txt")" || ok
grep -q 'PATCH .*"status":"failed"' "$T/req.txt" \
  && ok || bad "the capped row was not marked failed: $(cat "$T/req.txt")"
grep -q 'parked for the blocked-resolver\|blocked-resolver.sh picks the row up' "$T/h/logs/ALERTS.log" \
  && ok || bad "the cap did not page: $(cat "$T/h/logs/ALERTS.log")"

# ══ 3. THE BOX NAME IS PER MACHINE ═════════════════════════════════════════
# The line is evaluated as fly/entrypoint.sh really ships it, not re-typed here.
HOSTLINE=$(grep -n 'POOL_MODE' "$DIR/fly/entrypoint.sh" | grep 'HOST=' | head -1 | cut -d: -f2-)
[ -n "$HOSTLINE" ] && ok || bad "the entrypoint no longer has a HOST= line to test"
hostof() { # hostof <POOL_MODE> <FLY_MACHINE_ID> [hostname-fallback]
  ( export PROJECT=project-5 POOL_MODE="$1"
    [ -n "$2" ] && export FLY_MACHINE_ID="$2"
    hostname() { echo "${3:-fallbackhost}"; }
    eval "$HOSTLINE"; printf '%s' "$HOST" )
}
[ "$(hostof 1 3d8d1e2f1a2b33)" = "pool-project-5-3d8d1e2f1a2b33" ] \
  && ok || bad "pool host is not pool-<project>-<machine>: $(hostof 1 3d8d1e2f1a2b33)"
# THE POINT: two machines of one pool are two boxes. While they shared a name,
# `box * build 1` refused every claim after the first.
[ "$(hostof 1 aaaaaaaaaaaaaa)" != "$(hostof 1 bbbbbbbbbbbbbb)" ] \
  && ok || bad "two pool machines still answer to one box name"
# The prefix survives, so anything matching pool-<project> as a PREFIX still does.
case "$(hostof 1 3d8d1e2f1a2b33)" in pool-project-5-*) ok ;; *) bad "the pool- prefix was lost" ;; esac
# No FLY_MACHINE_ID (a hand-run): still per machine, via the hostname tail.
H=$(hostof 1 "" abcdef1234567); case "$H" in pool-project-5-?*) ok ;; *) bad "no machine id left an empty suffix: '$H'" ;; esac
# A persistent builder is untouched.
[ "$(hostof '' '')" = "builder-project-5" ] \
  && ok || bad "the non-pool builder name changed: $(hostof '' '')"
# AND IT IS THE NAME THE LEDGER RECEIVES. bin/jobs-client.sh takes the box from
# $BOX_NAME, then state/box-name, then `hostname` — a pool machine has neither
# of the first two, which is why setting the hostname is what fixes the rule.
mkdir -p "$T/nobox"
BOXN=$( unset BOX_NAME JOBS_BOX
        HARNESS="$T/nobox" bash -c '. "'"$DIR"'/bin/jobs-client.sh" >/dev/null 2>&1; printf "%s" "$JOBS_BOX"' )
[ "$BOXN" = "$(hostname)" ] \
  && ok || bad "with no BOX_NAME and no state/box-name the box is not the hostname ('$BOXN')"

# ══ 4. THE TREE IS ON ORIGIN BEFORE ANY REVIEW ═════════════════════════════
# TK-269 lost a finished tree when its machine was reaped before the PR push.
# Order is the whole claim, so it is read off the script itself.
RB="$RB_ALL"
grep -q 'PUSH_BRANCH() {' "$RB" && ok || bad "run-build.sh has no PUSH_BRANCH helper"
# BH-2504: every run-build push is RB_PUSH, which pushes through
# bin/lib/hold-push.sh; the lease rule below is pinned on both halves.
grep -q 'if RB_PUSH -u "\$1" 2>>"\$BUILD/pipeline.log"; then' "$RB" \
  && ok || bad "the pre-review push is not RB_PUSH (a --force-with-lease push)"
# The lease must be EXPLICIT (<branch>:<sha>): a bare --force-with-lease resolves
# through the fetch refspec, which single-branch pool clones do not have, so every
# push after the first is rejected "stale info" (project-4 TK-1587, 2026-09-12).
grep -q 'l=\$(git rev-parse -q --verify "refs/remotes/origin/\$BRANCH"' "$RB" \
  && grep -q 'hold_push .*"\$BRANCH" "\$BRANCH" "\${l:-new}"' "$RB" \
  && grep -q -- '--force-with-lease=\$br:\$lease' "$DIR/bin/lib/hold-push.sh" \
  && ok || bad "RB_PUSH must produce an explicit --force-with-lease=<branch>:<sha>"
EXEC_PUSH=$(grep -n '^PUSH_BRANCH execute' "$RB" | cut -d: -f1 | head -1)
FIRST_REVIEW=$(grep -n 'CC review "\$REVIEW_MODEL"' "$RB" | cut -d: -f1 | head -1)
[ -n "$EXEC_PUSH" ] && [ -n "$FIRST_REVIEW" ] && [ "$EXEC_PUSH" -lt "$FIRST_REVIEW" ] \
  && ok || bad "the execute push does not precede the first review (push=$EXEC_PUSH review=$FIRST_REVIEW)"
# Every fix round pushes before the re-review that reads it, and the general fix
# round is the one that matters most: it is where the longest unpushed window
# used to be. Since 2026-09-12 there are two flow paths and each has to satisfy
# that, so it is checked as an ORDER inside each rather than as three greps for
# three literal push labels (the sequential path now names its push through the
# per-lens table, so the labels live in an assignment rather than at the call).
grep -qF 'PUSH_BRANCH "the merged fix round"' "$RB" \
  && ok || bad "the merged (parallel) fix round does not push"
MFIX=$(grep -n 'CC fix "\$FIX_MODEL" 4800 "\$BUILD/fix-run.txt"' "$RB" | cut -d: -f1 | head -1)
MPUSH=$(grep -n 'PUSH_BRANCH "the merged fix round"' "$RB" | cut -d: -f1 | head -1)
MRE=$(grep -n 'CC review "\$REVIEW_MODEL" 1200 "\$BUILD/review2-run.txt"' "$RB" | cut -d: -f1 | head -1)
{ [ -n "$MFIX" ] && [ -n "$MPUSH" ] && [ -n "$MRE" ] && [ "$MFIX" -lt "$MPUSH" ] && [ "$MPUSH" -lt "$MRE" ]; } \
  && ok || bad "the merged fix round does not push between the fix and its re-review (fix=$MFIX push=$MPUSH re=$MRE)"
# The sequential rollback path: every lens still carries its own push label, and
# the loop pushes between the fix call and the re-review call.
for R in "the fix round" "the security fix round" "the refuter fix round"; do
  grep -qF "L_PUSH=\"$R\"" "$RB" && ok || bad "no push label for $R"
done
awk '/# --- Rollback path/{f=1} f&&/# --- Parallel path/{exit} f' "$RB" > "$T/seq-path.txt"
SFIX=$(grep -n 'CC fix "\$FIX_MODEL" 4800 "\$BUILD/\$L_FIXRUN"' "$T/seq-path.txt" | cut -d: -f1 | head -1)
SPUSH=$(grep -n 'PUSH_BRANCH "\$L_PUSH"' "$T/seq-path.txt" | cut -d: -f1 | head -1)
SRE=$(grep -n 'CC review "\$REVIEW_MODEL" 1200 "\$BUILD/\$L_RUN2"' "$T/seq-path.txt" | cut -d: -f1 | head -1)
{ [ -n "$SFIX" ] && [ -n "$SPUSH" ] && [ -n "$SRE" ] && [ "$SFIX" -lt "$SPUSH" ] && [ "$SPUSH" -lt "$SRE" ]; } \
  && ok || bad "the sequential fix round does not push between the fix and its re-review (fix=$SFIX push=$SPUSH re=$SRE)"
# A push must never be the thing that fails a build here — the pre-PR push stays
# the authoritative one, and it is the only one allowed to defer.
grep -q EXIT <<<"$(awk '/^PUSH_BRANCH\(\) \{/{f=1} f&&/^\}/{exit} f&&/exit [0-9]/{print "EXIT"}' "$RB")" \
  && bad "PUSH_BRANCH can exit the pipeline; a backup push must never be fatal" || ok
# ...and no PR is created any earlier than it was. Counted as INVOCATIONS —
# `$(gh pr create` or a `gh pr create` in command position — and not as textual
# mentions: #574 put the command into an alert's recovery text ("open it by hand
# with: gh pr create …") and into two comments, none of which opens a PR, while
# the old `grep -c 'gh pr create' <= 2` (one call plus one comment at the time)
# counted all five. This form is the stricter reading of the same rule: a SECOND
# real call site fails it even if the mentions stay at two.
[ "$(grep -cE '(^|[;&|(]|\$\()[[:space:]]*gh pr create' "$RB")" -le 1 ] \
  && ok || bad "the PR creation call count changed — this fix must not open PRs earlier"

echo "pool-cap-refusal-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
