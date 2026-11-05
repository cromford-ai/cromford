#!/bin/bash
# tests/relay-identity.bh-1957-test.sh — two relay claims from BH-232, driven.
#
# §1 (item 8). In touch mode — the result travels by row and only the tier-1
# APPROVE's merge enqueue failed — bin/fly-pool.sh hands the APPROVE to the box
# with an ssh `touch` on its merge queue. That touch was `2>/dev/null || true`:
# an unreachable box swallowed it, the log said "sent", and the APPROVE sat
# queued nowhere. It now retries once and a failure pages with its rc.
#
# §2/§3 (item 9, ALREADY DONE on main — this pins it). Two builds of ONE ticket
# whose RESULT first lines are byte-identical must post two close-outs, on the
# relay path and on the ledger path. The first-line compare that could merge
# them was retired for exact identity (BUILD_DIR/BUILT_AS, JOB_ID); these cases
# fail the day anyone puts a line compare back.
# Run from anywhere: tests/relay-identity.bh-1957-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ══ §1 fixture: copied from tests/pool-relay-rowfirst-test.sh ═══════════════
P="$T/p"
mkdir -p "$P/h/bin/lib/jobs" "$P/h/logs" "$P/h/flags" "$P/h/locks" "$P/h/env" \
         "$P/h/state/fly" "$P/h/state/fly-pool/project-3" "$P/h/state/remote-results/project-3" \
         "$P/h/builds" "$P/fakebin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" \
   "$DIR/bin/result-prefix-ok.sh" "$P/h/bin/"
cp "$DIR/bin/alert-line.sh" "$P/h/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$P/h/bin/lib/jobs/"
cp "$DIR/bin/lib/builder-direct.sh" "$P/h/bin/lib/"
cp "$DIR/fleet.conf" "$P/h/fleet.conf"
printf 'HARNESS_SECRET=test-secret\n' > "$P/h/env/global.env"
: > "$P/h/env/fly.env"
printf '3\n' > "$P/h/flags/fly-pool-project-3"
printf 'pool-project-3\n' > "$P/h/flags/fly-pool-app-project-3"
printf '{"app":"pool-project-3"}\n' > "$P/h/state/fly/project-3.json"
printf '#!/bin/bash\nexit 0\n' > "$P/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$P/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$P/fakebin/timeout"
printf '#!/bin/bash\necho OPEN\n' > "$P/fakebin/gh"
cat > "$P/fakebin/base64" <<'STUB'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in -d|-D) DEC=1 ;; -w0|-w) W0=1 ;; 0) ;; -*) ;; *) FILE="$a" ;; esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0); fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
STUB
# THE ssh STUB IS THE UNREACHABLE BOX: every call is recorded, and it exits
# ${SSH_RC:-0} — 255 is what ssh itself returns when it cannot connect.
cat > "$P/fakebin/ssh" <<'STUB'
#!/bin/bash
echo "ssh $*" >> "$SSH_SINK"
exit "${SSH_RC:-0}"
STUB
cat > "$P/fakebin/fly" <<'STUB'
#!/bin/bash
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *base64*RESULT*)    printf 'UFJfQ1JFQVRFRCBodHRwczovL2dpdGh1Yi5jb20vby9yL3B1bGwvNTUKVElFUjogMQo=\n' ;;
  *base64*review*)    printf 'VkVSRElDVDogQVBQUk9WRQo=\n' ;;
  *base64*)           : ;;
  *head*RESULT*)      echo "PR_CREATED https://github.com/o/r/pull/55" ;;
  *ls*builds*)        echo "/data/harness/builds/project-3-TK-9-1" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
STUB
# The ledger carries the result (so the row path takes it) and the merge-queue
# ROW fails: that is touch mode.
cat > "$P/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/artifacts\?*)
    printf '%s\n200\n' '{"artifacts":[{"job_id":"j1","artifact_kind":"result","artifact_ref":"PR_CREATED https://github.com/o/r/pull/55","box":"pool-machine-1","ticket_id":"9","updated_at":"2026-09-11T01:00:00Z","detail":"{\"build_dir\":\"project-3-TK-9-1\",\"key\":\"TK-9\",\"job_status\":\"done\"}"}]}' ;;
  */api/merge-queue) printf 'boom\n500\n' ;;
  *)                 printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$P/h/bin/beat.sh" "$P/fakebin"/* "$P/h/bin/result-prefix-ok.sh"

reap() { # reap <SSH_RC>   (fly-pool.log and ALERTS accumulate across calls)
  for b in "$P/h/builds"/*; do [ -e "$b" ] && scratch_rm "$b"; done; : > "$P/ssh.txt"
  printf '{"machine":"m1","key":"TK-9","ticket_id":"9","attempt":0}\n' > "$P/h/state/fly-pool/project-3/m1.json"
  ( export PATH="$P/fakebin:$PATH" HARNESS="$P/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           FLEET_CONF="$P/h/fleet.conf" SSH_SINK="$P/ssh.txt" SSH_RC="$1" \
           FLY_API_TOKEN_PROJECT_3_OS=tok FLY_BIN_DIR="$P/fakebin"
    bash "$DIR/bin/fly-pool.sh" project-3 >/dev/null 2>&1 )
}
MQT='MERGE-QUEUE TOUCH FAILED'

# ══ 1. AN UNREACHABLE BOX IN TOUCH MODE SURFACES ITS rc ═════════════════════
: > "$P/h/logs/fly-pool.log"
reap 255
grep -q 'MERGE-QUEUE ROW FAILED' "$P/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "§1 precondition: this must be the touch-mode path (mergerow alert): $(cat "$P/h/logs/ALERTS.log" 2>/dev/null)"
grep "$MQT" "$P/h/logs/ALERTS.log" 2>/dev/null | grep -q 'rc=255' \
  && ok || bad "§1 THE POINT: a failed merge-queue touch must page with its rc: $(cat "$P/h/logs/ALERTS.log" 2>/dev/null)"
grep "$MQT" "$P/h/logs/ALERTS.log" 2>/dev/null | grep -q 'touch /root/harness/state/merge-queue/project-3/55' \
  && ok || bad "§1 the alert must carry the exact hand command"
N=$(grep -c 'merge-queue' "$P/ssh.txt" 2>/dev/null)
[ "${N:-0}" = 2 ] && ok || bad "§1 the touch must be tried exactly twice (one retry), got ${N:-0}: $(cat "$P/ssh.txt")"
grep -q 'FAILED rc=255' "$P/h/logs/fly-pool.log" \
  && ok || bad "§1 fly-pool.log must carry the rc: $(tail -5 "$P/h/logs/fly-pool.log")"
grep -q 'sent to' "$P/h/logs/fly-pool.log" \
  && bad "§1 a touch that failed must never be logged as sent (D13)" || ok
ls -d "$P/h/builds/pool-project-3-TK-9-"*/RELAYED >/dev/null 2>&1 \
  && ok || bad "§1 RELAYED is unchanged: the result's custody is the ledger row"

# A second failing reap the same day: the page is deduped, the detail is not.
reap 255
N=$(grep -c "$MQT" "$P/h/logs/ALERTS.log" 2>/dev/null)
[ "${N:-0}" = 1 ] && ok || bad "§1 one mergetouch page per project per day, got ${N:-0}"
N=$(grep -c 'rc=255' "$P/h/logs/fly-pool.log" 2>/dev/null)
[ "${N:-0}" -ge 2 ] && ok || bad "§1 every failure must still be in fly-pool.log with its rc, got ${N:-0}"
ls "$P/h/flags"/alerted-pool-relay-mergetouch-project-3-* >/dev/null 2>&1 \
  && ok || bad "§1 the page needs its own reason flag, so the day's mergerow flag cannot swallow it"

# A reachable box: one attempt, no mergetouch page, and the log says sent.
rm -f "$P/h/flags"/alerted-pool-relay-* "$P/h/logs/ALERTS.log"; : > "$P/h/logs/fly-pool.log"
reap 0
N=$(grep -c 'merge-queue' "$P/ssh.txt" 2>/dev/null)
[ "${N:-0}" = 1 ] && ok || bad "§1 a touch that worked must not be retried, got ${N:-0} attempts"
grep -q "$MQT" "$P/h/logs/ALERTS.log" 2>/dev/null \
  && bad "§1 a touch that worked must not page" || ok
grep -q 'sent to' "$P/h/logs/fly-pool.log" && ok || bad "§1 a touch that worked is logged as sent"

# ══ §2/§3 fixture: copied from tests/fly-lane-db-test.sh §4 ═════════════════
R="$T/r"
mkdir -p "$R/h/bin/lib/jobs" "$R/h/bin/lib/rt" "$R/h/logs" "$R/h/flags" "$R/h/locks" \
         "$R/h/builds" "$R/h/env" "$R/h/prompts" "$R/h/catalog/agent-contracts" "$R/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$R/h" project-3 || exit 1
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/triage-contract.sh" "$DIR/bin/fleet-conf.sh" "$R/h/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$R/h/bin/lib/jobs/"
cp "$DIR"/bin/lib/rt/*.sh "$R/h/bin/lib/rt/"
cp "$DIR/fleet.conf" "$R/h/fleet.conf"
cp "$DIR/catalog/agent-contracts/triage-system-append.txt" "$R/h/catalog/agent-contracts/"
: > "$R/h/env/global.env"
printf 'SOP BODY\n' > "$R/h/prompts/project-3.md"
printf '#!/bin/bash\n[ "${2:-}" = "--pending" ] && exit 0\necho "RUN results-sweep"\n' > "$R/h/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$R/h/bin/gate-diff.sh"
printf '#!/bin/bash\nexit 0\n' > "$R/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$R/h/bin/decision-log.sh"
printf '#!/bin/bash\nprintf "tickets=0\\n" > "${5:-/dev/null}"\nexit 0\n' > "$R/h/bin/agent-call.sh"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$R/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$R/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$R/fakebin/ssh"
printf '#!/bin/bash\nexit 1\n' > "$R/fakebin/tailscale"
cat > "$R/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
case "${CURL_MODE:-down}" in
  down) exit 7 ;;
  arts)
    case "$URL" in
      */api/artifacts\?*) printf '%s\n200\n' "$(jq -c . "$ARTS_FIXTURE")" ;;
      */api/queue\?*)     printf '{"queue":[]}\n200\n' ;;
      # TEST-CHANGE BH-4153: paused-*/automerge-disabled* are now harness_flags rows read DB-first; a 200 with no .flag row is UNREADABLE and fails closed (paused), so the flag GET must answer the worker's real no-row 404.
      */api/flags/*)      printf '{"error":"not found"}\n404\n' ;;
      *)                  printf '{"ok":true}\n200\n' ;;
    esac ;;
esac
STUB
chmod +x "$R/h/bin"/*.sh "$R/fakebin"/*

triage() { # triage <curl-mode>
  ( export PATH="$R/fakebin:$PATH" HARNESS="$R/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 \
           JOBS_BEAT_SECS=3600 CURL_MODE="$1" ARTS_FIXTURE="$R/arts.json"
    bash "$DIR/bin/run-triage.sh" project-3 >/dev/null 2>&1 )
}
ndirs() { ls -d "$R/h/builds/project-3-$1-remote"* 2>/dev/null | wc -l | tr -d ' '; }
# A PR_CREATED line on purpose: a fix round re-reports the SAME PR, so two
# builds of one ticket with a byte-identical first line is the ordinary case —
# and unlike a BUILD_DEFERRED (RR_NO_CLOSEOUT marks that COMMENTED at staging),
# each one owes the client a close-out.
LINE='PR_CREATED https://github.com/o/r/pull/3'
owed() { # owed <key>: staged dirs still waiting on a close-out
  local n=0 d
  for d in "$R/h/builds/project-3-$1-remote"*; do [ -d "$d" ] && [ ! -f "$d/COMMENTED" ] && n=$((n+1)); done
  echo "$n"
}

# ══ 2. RELAY PATH: SAME FIRST LINE, TWO BUILDS, TWO CLOSE-OUTS ═════════════
mkdir -p "$R/h/state/remote-results/project-3"
# TEST-CHANGE BH-4153: §2 runs with the ledger down (curl exit 7). paused-<p> is
# now a harness_flags row read DB-first, and with no cache an unreadable stop
# switch fails CLOSED, so the tick would stand down before staging anything.
# A live box mid-outage has the last good read cached; seed that (row absent =
# off) so §2 still exercises the relay path it pins, not the pause gate.
mkdir -p "$R/h/state/flags-cache/fleet"
printf '{"on":false,"value":null,"set_at":null,"cleared_at":null,"src":"db","stamp":%s}\n' "$(date +%s)" \
  > "$R/h/state/flags-cache/fleet/paused-project-3"
relay() { # relay <suffix>
  mkdir -p "$R/h/builds/pool-project-3-TK-91-$1"
  jq -nc --arg r "$LINE" --arg s "$1" \
    '{key:"TK-91",ticket_id:"91",result:$r,build_dir:("pool-project-3-TK-91-"+$s),machine_build_dir:("project-3-TK-91-"+$s)}' \
    > "$R/h/state/remote-results/project-3/TK-91.json"
}
relay a; triage down
[ "$(ndirs TK-91)" = 1 ] && ok || bad "§2 precondition: build a must be staged (dirs=$(ndirs TK-91))"
relay b; triage down
[ "$(ndirs TK-91)" = 2 ] \
  && ok || bad "§2 THE POINT: a second build whose RESULT first line is IDENTICAL must still be staged (dirs=$(ndirs TK-91)) — otherwise its close-out is dropped"
grep -lx 'BUILT_AS: project-3-TK-91-b' "$R/h/builds/project-3-TK-91-remote"*/RESULT >/dev/null 2>&1 \
  && ok || bad "§2 build b's staged RESULT must name its own machine build: $(cat "$R/h/builds/project-3-TK-91-remote"*/RESULT 2>/dev/null)"
for D in "$R/h/builds/project-3-TK-91-remote"*; do
  [ "$(head -1 "$D/RESULT" 2>/dev/null)" = "$LINE" ] && ok || bad "§2 both staged RESULTs carry the identical first line: $(head -1 "$D/RESULT")"
done
[ "$(owed TK-91)" = 2 ] && ok || bad "§2 both staged builds must still owe their close-out (owed=$(owed TK-91))"
relay b; triage down                         # the SAME build again
[ "$(ndirs TK-91)" = 2 ] && ok || bad "§2 the same build re-dropped must not stage a third dir (dirs=$(ndirs TK-91))"

# ══ 3. LEDGER PATH: SAME artifact_ref, TWO JOBS, TWO CLOSE-OUTS ════════════
cat > "$R/arts.json" <<FIXTURE
{"artifacts":[
 {"job_id":"build-project-3-TK-92-1","artifact_kind":"result","artifact_ref":"$LINE","box":"pool-machine-1","ticket_id":"92","updated_at":"2026-09-10T02:00:00Z","detail":"{\"build_dir\":\"project-3-TK-92-2609100200\",\"key\":\"TK-92\",\"job_status\":\"done\"}"},
 {"job_id":"build-project-3-TK-92-2","artifact_kind":"result","artifact_ref":"$LINE","box":"pool-machine-2","ticket_id":"92","updated_at":"2026-09-10T02:01:00Z","detail":"{\"build_dir\":\"project-3-TK-92-2609100201\",\"key\":\"TK-92\",\"job_status\":\"done\"}"}
]}
FIXTURE
triage arts
[ "$(ndirs TK-92)" = 2 ] \
  && ok || bad "§3 THE POINT: two ledger rows with an identical artifact_ref and different jobs must stage two dirs (dirs=$(ndirs TK-92))"
grep -lx 'JOB_ID: build-project-3-TK-92-1' "$R/h/builds/project-3-TK-92-remote"*/RESULT >/dev/null 2>&1 \
  && ok || bad "§3 job 1 must be staged"
grep -lx 'JOB_ID: build-project-3-TK-92-2' "$R/h/builds/project-3-TK-92-remote"*/RESULT >/dev/null 2>&1 \
  && ok || bad "§3 job 2 must be staged"
[ "$(owed TK-92)" = 2 ] && ok || bad "§3 both staged jobs must still owe their close-out (owed=$(owed TK-92))"

echo "relay-identity.bh-1957-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
