#!/bin/bash
# tests/queue-phase-refusal.bh-9160-test.sh — BH-9160 (the rest of BH-8734):
# one decider for a relaunch. The worker refuses a build enqueue of a
# plan_blocked or abandoned ticket (worker/jobs/test/queue-phase-refusal
# .bh-9160.test.js); the shell client and run-build's fly enqueue read that
# refusal as an answer, not as an outage.
#
# Driven over REAL curl against the REAL jobs worker on node:sqlite
# (tests/lib/phase-refusal-worker.bh-9160.mjs). No vendor, no network.
#
#   Q1-Q5  bin/lib/jobs/queue.sh queue_put: rc 3 + `refused <phase>` on the
#          phase 409 with the row unchanged; JOBS_QUEUE_ACTOR=lifecycle
#          re-enters; a NULL phase is queued; a 503 is rc 1
#   G1-G4  the verbatim bin/lib/rb/gates.sh `# >>> fly queue enqueue` block
#          with the real client: a refusal writes no file job and no ALERT on a
#          watcher or on the hub; a 503 keeps the outage fallback; rc 0 on a
#          watcher writes the row only
#
# Each case uses its own key. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/queue-phase-refusal.bh-9160-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "queue-phase-refusal (BH-9160): SKIPPED: node or curl missing"; exit 0; }
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1

C="$T/client"
mkdir -p "$C/env" || exit 1
: > "$C/env/global.env"
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$C" ) >/dev/null 2>&1 || { echo "setup: could not install bin/jobs-client.sh"; exit 1; }

: > "$T/srv.log"; : > "$T/srv.port"
mkdir -p "$T/nodetmp" || exit 1
TMPDIR="$T/nodetmp" node "$DIR/tests/lib/phase-refusal-worker.bh-9160.mjs" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "queue-phase-refusal (BH-9160): SKIPPED: node:sqlite unavailable"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
trap 'kill "$SPID" 2>/dev/null' EXIT
WURL="http://127.0.0.1:$PORT"
REALCURL=$(command -v curl)
put() { # put <key> [phase]  — a finished row; phase "" is NULL
  "$REALCURL" -sS -X POST -d "$(jq -nc --arg k "$1" --arg ph "${2:-}" \
    '{project:"project-5",key:$k,status:"done",attempt:1} + (if $ph == "" then {} else {phase:$ph} end)')" "$WURL/__put" >/dev/null
}
row() { "$REALCURL" -sS "$WURL/__row?project=project-5&key=$1"; }
down() { "$REALCURL" -sS -X POST -d "{\"down\":$1}" "$WURL/__down" >/dev/null; }
CLIENT_ENV=(HARNESS_ENV_DIR="$C/env" HARNESS_SECRET=fixture-harness-secret JOBS_URL="$WURL"
            JOBS_BOX=watcher JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10 JOBS_ALERT=0)

# ══ Q: queue_put ════════════════════════════════════════════════════════════
# qp <key> [env...] -> "rc|stdout" of the real queue_put over the real worker.
qp() {
  local k="$1"; shift
  ( env "${CLIENT_ENV[@]}" HARNESS="$C" "$@" bash -c '. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1
      o=$(queue_put project-5 "$0" 1 fly); printf "%s|%s" "$?" "$o"' "$k" 2>/dev/null )
}
body_of() { grep "^POST /api/queue " "$T/srv.log" | grep "\"key\":\"$1\"" | tail -1 | cut -d' ' -f4-; }

put Q-1 plan_blocked; B=$(row Q-1)
R=$(qp Q-1)
[ "$R" = "3|refused plan_blocked" ] && ok || bad "Q1: a plan_blocked row -> 'refused plan_blocked' rc 3 (got $R)"
[ "$(row Q-1)" = "$B" ] && ok || bad "Q1: the row is unchanged: $(row Q-1)"
[ "$(body_of Q-1 | jq -r 'has("actor")' 2>/dev/null)" = false ] && ok || bad "Q1: no JOBS_QUEUE_ACTOR posts no actor: $(body_of Q-1)"

put Q-2 abandoned; B=$(row Q-2)
R=$(qp Q-2)
[ "$R" = "3|refused abandoned" ] && ok || bad "Q2: an abandoned row -> 'refused abandoned' rc 3 (got $R)"
[ "$(row Q-2)" = "$B" ] && ok || bad "Q2: the row is unchanged: $(row Q-2)"

put Q-3 plan_blocked
R=$(qp Q-3 JOBS_QUEUE_ACTOR=lifecycle)
[ "$R" = "0|queued" ] && ok || bad "Q3: JOBS_QUEUE_ACTOR=lifecycle re-enters (got $R)"
[ "$(row Q-3 | jq -r '.status, .attempt' | tr '\n' ' ')" = "queued 2 " ] && ok || bad "Q3: the row is queued (attempt continues): $(row Q-3)"
[ "$(body_of Q-3 | jq -r '.actor // "none"' 2>/dev/null)" = lifecycle ] && ok || bad "Q3: the body carries actor lifecycle: $(body_of Q-3)"
R=$(qp Q-1 JOBS_QUEUE_ACTOR=triage)
[ "$R" = "3|refused plan_blocked" ] && ok || bad "Q3: another actor is still refused (got $R)"

put Q-4
R=$(qp Q-4)
[ "$R" = "0|queued" ] && ok || bad "Q4: a NULL phase is queued (got $R)"
[ "$(row Q-4 | jq -r .status)" = queued ] && ok || bad "Q4: the row is queued: $(row Q-4)"

put Q-5 plan_blocked; down true
R=$(qp Q-5)
down false
[ "${R%%|*}" = 1 ] && ok || bad "Q5: a 503 is rc 1, not a refusal (got $R)"

# ══ G: the gates.sh fly enqueue block, verbatim ═════════════════════════════
GB="$T/fly-enqueue.sh"
awk '/^  # >>> fly queue enqueue/{f=1;next} /^  # <<< fly queue enqueue/{exit} f' "$DIR/bin/lib/rb/gates.sh" > "$GB"
if [ -s "$GB" ] && grep -q 'queue_put "\$PROJECT"' "$GB"; then ok
else bad "G: could not extract the fly enqueue block — # >>> fly queue enqueue markers missing in bin/lib/rb/gates.sh"; fi
# genq <key> <hub 0|1> -> runs the block with the real client; RESULT in $G/result
genq() {
  G="$T/g-$1"; scratch_rm "$G"; mkdir -p "$G/h/logs" "$G/henv"
  ln -s "$C/bin" "$G/h/bin"
  [ "$2" = 1 ] && : > "$G/henv/fly.env"
  ( env "${CLIENT_ENV[@]}" HARNESS="$G/h" HENV="$G/henv" ALERTS="$G/h/logs/ALERTS.log" PROJECT=project-5 KEY="$1" TICKET=1 \
    ATTEMPT=0 QMETA="" QDIR="state/build-queue/project-5" JOB_JSON="{\"key\":\"$1\"}" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { printf "%s\n" "$*" > "$HARNESS/../result"; }
             . "$0"' "$GB" >/dev/null 2>&1 )
}
put G-1 plan_blocked; B=$(row G-1)
genq G-1 0
[ "$(cat "$G/result" 2>/dev/null)" = "QUEUED_FLY G-1 (refused: ticket phase plan_blocked; not queued)" ] && ok \
  || bad "G1: a watcher refusal RESULT: $(cat "$G/result" 2>/dev/null)"
[ ! -e "$G/h/state/build-queue/project-5/G-1.json" ] && ok || bad "G1: no file job on a watcher"
[ ! -s "$G/h/logs/ALERTS.log" ] && ok || bad "G1: no ALERT: $(cat "$G/h/logs/ALERTS.log" 2>/dev/null)"
grep -q 'queue refused: ticket phase plan_blocked; not queued, no file written' "$G/h/logs/project-5.log" 2>/dev/null && ok \
  || bad "G1: one project-log line: $(cat "$G/h/logs/project-5.log" 2>/dev/null)"
[ "$(row G-1)" = "$B" ] && ok || bad "G1: the row is unchanged: $(row G-1)"

put G-2 abandoned
genq G-2 1
[ ! -e "$G/h/state/build-queue/project-5/G-2.json" ] && ok || bad "G2: no file job on the hub"
[ "$(cat "$G/result" 2>/dev/null)" = "QUEUED_FLY G-2 (refused: ticket phase abandoned; not queued)" ] && ok \
  || bad "G2: the hub RESULT: $(cat "$G/result" 2>/dev/null)"

put G-3 plan_blocked; down true
genq G-3 0
down false
[ -s "$G/h/state/build-queue/project-5/G-3.json" ] && ok || bad "G3: a 503 on a watcher still writes the file job (outage fallback)"
grep -q 'QUEUE ROW REFUSED OR UNREACHABLE' "$G/h/logs/ALERTS.log" 2>/dev/null && ok || bad "G3: a 503 still pages the outage"
[ "$(cat "$G/result" 2>/dev/null)" = "QUEUED_FLY G-3" ] && ok || bad "G3: a 503 RESULT is plain QUEUED_FLY: $(cat "$G/result" 2>/dev/null)"

put G-4
genq G-4 0
[ ! -e "$G/h/state/build-queue/project-5/G-4.json" ] && [ "$(cat "$G/result" 2>/dev/null)" = "QUEUED_FLY G-4" ] && ok \
  || bad "G4: rc 0 on a watcher writes the row only: $(cat "$G/result" 2>/dev/null)"
[ "$(row G-4 | jq -r .status)" = queued ] && ok || bad "G4: the row is queued: $(row G-4)"

echo "queue-phase-refusal (BH-9160): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
