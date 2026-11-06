#!/bin/bash
# tests/pool-release-attempt-cap.bh-8734-test.sh — one decider for a relaunch
# (BH-8734, slice C0): a refused re-review apply ends the row failed, and every
# orphan or stale-claim release counts on build_queue.attempt up to
# queue.release_attempt_max.
#
# THE CASE (BH-8841, 2026-11-03). The pool reap matched the BUILD result
# `GATE_RED 4 red: ...` against the rebase arm. mc_pool_rebase_apply refused
# (no RB job file), the row was left claimed, an orphan release put it back to
# `queued` about 30 s later, and the pool spawned it again. 17 runs, $15.73,
# and build_queue.attempt stayed at 2.
#
# WHAT MAIN ALREADY HAS (BH-8886, 807f2e401): the rebase arm runs only for an
# RB- key, and a refused rebase apply closes its row failed (APPLY_FAILED).
# tests/pool-gate-red-build-key.bh-8886-test.sh pins both, so this suite does
# not. What was left: the re-review arm still left a refused row CLAIMED, and
# no release counted anything.
#
#   Part A  bin/fly-pool.sh's reap, whole, with the machine, gh and the jobs
#           API stubbed (the bh-542 rig): F1-F3 a refused re-review apply ends
#           the row failed with one alert.
#   Part W  the REAL jobs worker on node:sqlite (tests/lib/release-cap-worker
#           .bh-8734.mjs) behind real curl: C1-C5 queue_release_counted and
#           pool_orphan_rows_step, L1-L2 the relaunch loop, J1-J3 the whole
#           bin/jobs-watchdog.sh stale-claim release.
#
# No vendor is called: fly, gh, ssh and the jobs API are stubs or the local
# worker. Each case uses its own keys.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pool-release-attempt-cap.bh-8734-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

RRKEY=RR-12-abcdef01

# ════════════════════════════════════════════════════════════════════════════
# Part A  bin/fly-pool.sh — the reap
# ════════════════════════════════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/fly" "$H/state/fly-pool/tproj" "$H/state/remote-results/tproj" \
         "$H/state/build-queue/tproj" "$T/fakebin"
cp "$DIR/fleet.conf" "$H/fleet.conf"
printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
printf '3\n'           > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n'  > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
# The fixtures go in FIRST: scratch_install_closure never overwrites a file.
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"
# The hub's two apply functions: each records its argv and answers $APPLY_RC.
cat > "$H/bin/lib/merge-conductor-lib.sh" <<'LIB'
mc_pool_rebase_apply()   { printf 'rebase %s\n' "$*"   >> "$APPLY_SINK"; return "${APPLY_RC:-0}"; }
mc_pool_rereview_apply() { printf 'rereview %s\n' "$*" >> "$APPLY_SINK"; return "${APPLY_RC:-0}"; }
LIB
for L in bin/fly-pool.sh bin/alert-line.sh bin/jobs-client.sh bin/fleet-conf.sh bin/result-prefix-ok.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done

printf '#!/bin/bash\nexit 0\n'            > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n'  > "$T/fakebin/timeout"
printf '#!/bin/bash\necho "ssh $*" >> "$SSH_SINK"\nexit 0\n' > "$T/fakebin/ssh"
printf '#!/bin/bash\necho "scp $*" >> "$SSH_SINK"\nexit 0\n' > "$T/fakebin/scp"
# curl: every request is recorded; the queue PATCH is the assertion.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/queue\?*) printf '{"queue":[]}\n200\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
STUB
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
  *" -i "*) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged_at":null}\n' ;;
  *)        printf '{"state":"open","merged_at":null}\n' ;;
esac
exit 0
STUB
chmod +x "$T/fakebin"/*

pool() { # pool <key> <ticket-id> <result-text> [apply-rc]
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
           RESULT_FIXTURE="$T/result.txt" APPLY_RC="${4:-0}"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  LOCALDIR=$(ls -d "$H/builds/pool-tproj-$1-"* 2>/dev/null | head -1)
}
# patches <key> — the queue PATCH bodies the reap sent for the key, one per line.
patches() { sed -n "s|^PATCH https://jobs.invalid/api/queue ||p" "$T/req.txt" | jq -c --arg k "$1" 'select(.key == $k)' 2>/dev/null; }

# ── F1-F2 (repro) a refused re-review apply ends the row FAILED, one alert ─
for RC in 1 127; do
  pool "$RRKEY" 12 "REREVIEWED APPROVE" "$RC"
  P2=$(patches "$RRKEY")
  [ "$(jq -sr 'length' <<<"$P2")" = 1 ] && [ "$(jq -r .status <<<"$P2")" = failed ] \
    && ok || bad "F1 THE POINT: a refused re-review apply (rc $RC) sends exactly one PATCH, status failed: $P2"
  RRWHY=$(jq -r .reason <<<"$P2")
  [ "$RRWHY" = "re-review apply failed rc=$RC; RESULT at $LOCALDIR/RESULT" ] \
    && ok || bad "F1 the re-review reason names rc $RC and the RESULT path: $RRWHY"
  N=$(grep -c "$LOCALDIR/RESULT" "$H/logs/ALERTS.log" 2>/dev/null | head -1)
  [ "$N" = 1 ] && grep -q "$RRKEY" "$H/logs/ALERTS.log" \
    && ok || bad "F2 exactly one ALERTS line naming the key and the RESULT path (rc $RC), got $N: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
  grep -q "FAILED" "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "F2 the alert says the row is FAILED (rc $RC)"
  grep -q "stays CLAIMED" "$H/logs/ALERTS.log" 2>/dev/null && bad "F2 the alert no longer says the row stays claimed (rc $RC)" || ok
  grep -q 'machine destroy' "$T/fly.txt" && ok || bad "F2 the machine is still destroyed (rc $RC)"
done

# F3 neither reason reads as a deferral or a refusal to the watchdog's
# reason_deferred sweep (reason LIKE '%REFUSED%', case-insensitive in SQLite).
for W in "$RRWHY"; do
  grep -qiE 'refused|BUILD_DEFERRED' <<<"$W" && bad "F3 '$W' would be re-queued by the watchdog" || ok
done

# ════════════════════════════════════════════════════════════════════════════
# Part W  the real worker
# ════════════════════════════════════════════════════════════════════════════
command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "pool-release-attempt-cap.bh-8734-test: $PASS pass, $FAIL fail (Part W SKIPPED: node or curl missing)"; [ "$FAIL" -eq 0 ]; exit; }
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
W="$T/w"
mkdir -p "$W/bin" "$W/logs" "$W/state/fly-pool/tproj" "$W/state/build-queue/tproj" "$W/state/fly" "$W/env" "$W/locks"
: > "$W/env/global.env"
for L in bin/jobs-client.sh bin/jobs-watchdog.sh bin/alert-line.sh bin/lib/pool-orphan-rows.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$W" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done

: > "$T/srv.log"; : > "$T/srv.port"
# The worker test lib writes a jobs-schema-* dir under os.tmpdir() once a
# process and never removes it, so the server gets a TMPDIR in the scratch tree.
mkdir -p "$T/nodetmp" || exit 1
TMPDIR="$T/nodetmp" node "$DIR/tests/lib/release-cap-worker.bh-8734.mjs" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "pool-release-attempt-cap.bh-8734-test: $PASS pass, $FAIL fail (Part W SKIPPED: node:sqlite unavailable)"; [ "$FAIL" -eq 0 ]; exit; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
trap 'kill "$SPID" 2>/dev/null' EXIT
WURL="http://127.0.0.1:$PORT"
REALCURL=$(command -v curl)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
OLD=$(iso $(( $(date -u +%s) - 3600 )))       # past POOL_ORPHAN_ROW_RELEASE_S (900 s)
STALE=$(iso $(( $(date -u +%s) - 7 * 3600 )))  # past JOBS_QUEUE_CLAIM_MIN (360 min)
put() { # put <key> <status> <attempt> [claimed_at] [claimed_by]
  "$REALCURL" -sS -X POST -d "$(jq -nc --arg k "$1" --arg s "$2" --argjson a "$3" --arg c "${4:-$OLD}" --arg b "${5:-hub}" \
    '{project:"tproj",key:$k,status:$s,attempt:$a,claimed_by:(if $s == "claimed" then $b else null end),claimed_at:(if $s == "claimed" then $c else null end)}')" \
    "$WURL/__put" > /dev/null
}
row() { "$REALCURL" -sS "$WURL/__row?project=tproj&key=$1"; }
retire() { local k; for k in "$@"; do put "$k" done 0; done; }   # out of every later case's GET
setting() { "$REALCURL" -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$WURL/__setting" > /dev/null; }
# lib <shell code> — the real jobs client and pool-orphan-rows lib, as box hub.
lib() {
  ( export HARNESS="$W" HARNESS_ENV_DIR="$W/env" HARNESS_SECRET=fixture-harness-secret JOBS_URL="$WURL" \
           JOBS_BOX=hub JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10 JOBS_SETTINGS_CACHE_S=0 \
           P=tproj POOL="$W/state/fly-pool/tproj" LISTING="$T/listing.json" LIST_OK=1 SAYLOG="$T/say.log"
    bash -c ". '$W/bin/jobs-client.sh' && . '$W/bin/lib/pool-orphan-rows.sh' && say() { echo \"\$*\" >> \"\$SAYLOG\"; } && $1" ) > "$T/out" 2> "$T/err"
}
printf '[]\n' > "$T/listing.json"
nalerts() { grep -c "$1" "$W/logs/ALERTS.log" 2>/dev/null | head -1; }
reset_logs() { rm -f "$W/logs/ALERTS.log" "$T/say.log"; }

# ── C1 the real queue_release_counted, four counted releases, N 3 ───────────
put C-1 claimed 0
OUTS=""
for i in 1 2 3 4; do
  [ "$i" -gt 1 ] && put C-1 claimed "$(row C-1 | jq -r .attempt)"
  lib 'queue_release_counted tproj C-1 "orphan release: test"'; RC=$?
  OUTS="$OUTS$(cat "$T/out")|rc$RC;"
done
[ "$OUTS" = "queued 1|rc0;queued 2|rc0;queued 3|rc0;failed 4 3|rc0;" ] \
  && ok || bad "C1 THE POINT: queued 1, 2, 3, then failed 4 3: $OUTS err=$(cat "$T/err")"
R=$(row C-1)
[ "$(jq -r .status <<<"$R")" = failed ] && [ "$(jq -r .attempt <<<"$R")" = 4 ] \
  && ok || bad "C1 the row is failed at attempt 4: $R"
jq -r .reason <<<"$R" | grep -q '^release cap: attempt 4 of 3 (queue.release_attempt_max); orphan release: test$' \
  && ok || bad "C1 the capped reason: $(jq -r .reason <<<"$R")"

retire C-1

# ── C3 an API answer that is not usable -> rc 1 ─────────────────────────────
lib 'queue_release_counted tproj NO-SUCH-ROW "x"'; RC=$?
[ "$RC" = 1 ] && ok || bad "C3 a 404 is rc 1: rc=$RC out=$(cat "$T/out")"
lib '_jobs_req() { printf "{\"error\":\"stale\",\"current\":\"done\"}"; return 9; }; queue_release_counted tproj S-1 "x"'; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$T/out")" = "stale done" ] && ok || bad "C3 a 409 stale is rc 1 and prints stale: rc=$RC out=$(cat "$T/out")"

# C3b the pool step on a stale answer: one say line, no release, no alert.
put S-2 claimed 1
reset_logs
lib 'queue_release_counted() { echo "stale failed"; return 1; }; pool_orphan_rows_step'
grep -q '^orphan-row-release S-2: not released — the row is failed now, nothing written$' "$T/say.log" 2>/dev/null \
  && ok || bad "C3b one say line for a stale answer: $(cat "$T/say.log" 2>/dev/null)"
[ -s "$W/logs/ALERTS.log" ] && bad "C3b a stale answer writes no alert: $(cat "$W/logs/ALERTS.log")" || ok
retire S-2

# C3c a 2xx answer with no status reads as a release, as queue_release does.
lib '_jobs_req() { printf "{\"ok\":true}"; return 0; }; queue_release_counted tproj S-3 "x"'; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "queued ?" ] && ok || bad "C3c a bare 2xx is queued: rc=$RC out=$(cat "$T/out")"

# ── L2 (repro) the orphan release loop: 3 relaunches, then failed, one alert
setting queue.release_attempt_max 3
put L-2 claimed 0
reset_logs; REL=0
for tick in 1 2 3 4 5; do
  lib 'pool_orphan_rows_step'
  [ "$(row L-2 | jq -r .status)" = queued ] && { REL=$((REL + 1)); put L-2 claimed "$(row L-2 | jq -r .attempt)"; }
done
[ "$REL" = 3 ] && ok || bad "L2 THE POINT: at most 3 relaunches, got $REL: $(row L-2)"
[ "$(row L-2 | jq -r .status)" = failed ] && ok || bad "L2 the row ends failed: $(row L-2)"
[ "$(nalerts 'release cap')" = 1 ] && grep 'release cap' "$W/logs/ALERTS.log" | grep -q 'L-2 (attempt 4 of 3)' \
  && ok || bad "L2 exactly one cap alert naming L-2: $(cat "$W/logs/ALERTS.log" 2>/dev/null)"
grep -q 'queue.release_attempt_max' "$W/logs/ALERTS.log" && ok || bad "L2 the alert names the settings row"
grep -q '^orphan-row-release L-2: release cap reached (attempt 4 of 3, queue.release_attempt_max) — row failed, not requeued$' "$T/say.log" \
  && ok || bad "L2 one say line for the cap: $(cat "$T/say.log")"
[ "$(nalerts 'released 1 claimed row')" = 3 ] && ok || bad "C5 the released alert is unchanged for each queued answer: $(cat "$W/logs/ALERTS.log")"

retire L-2

# ── C2 two capped rows in one tick -> ONE alert naming both ─────────────────
put C2-A claimed 3; put C2-B claimed 5
reset_logs
lib 'pool_orphan_rows_step'
[ "$(nalerts 'release cap')" = 1 ] && grep 'release cap' "$W/logs/ALERTS.log" | grep -q 'C2-A (attempt 4 of 3), C2-B (attempt 6 of 3)\|C2-B (attempt 6 of 3), C2-A (attempt 4 of 3)' \
  && ok || bad "C2 one ALERTS line for two capped rows: $(cat "$W/logs/ALERTS.log" 2>/dev/null)"
grep -q '\] released [0-9]* claimed row' "$W/logs/ALERTS.log" 2>/dev/null && bad "C2 no released alert when nothing was requeued" || ok

retire C2-A C2-B

# ── C4 no queue_release_counted (a half-synced box) -> today's queue_release
put C-4 claimed 3
reset_logs; : > "$T/srv.log"
lib 'unset -f queue_release_counted; pool_orphan_rows_step'
[ "$(row C-4 | jq -r .status)" = queued ] && [ "$(row C-4 | jq -r .attempt)" = 3 ] \
  && ok || bad "C4 the fallback release is today's (queued, attempt unchanged): $(row C-4)"
grep -q count_attempt <<<"$(grep '^PATCH /api/queue' "$T/srv.log")" && bad "C4 the fallback sends no count_attempt: $(grep PATCH "$T/srv.log")" || ok

retire C-4

# ── J1-J3 bin/jobs-watchdog.sh's stale-claim release, the whole script ──────
wd() { # wd [tree] — one real watchdog run against the worker
  local WH="${1:-$W}"
  ( export HARNESS="$WH" HARNESS_ENV_DIR="$WH/env" HARNESS_SECRET=fixture-harness-secret JOBS_URL="$WURL" \
           JOBS_BOX=hub-fixture JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10 JOBS_SETTINGS_CACHE_S=0
    bash "$WH/bin/jobs-watchdog.sh" ) > "$T/wd.out" 2>&1
}
put J-1 claimed 0 "$STALE" gone-box
reset_logs
wd
[ "$(row J-1 | jq -r .status)" = queued ] && [ "$(row J-1 | jq -r .attempt)" = 1 ] \
  && ok || bad "J1 a stale claim is released and counted: $(row J-1)"
[ "$(nalerts 'QUEUE CLAIM RELEASED: tproj/J-1')" = 1 ] && ok || bad "J1 today's RELEASED line: $(cat "$W/logs/ALERTS.log" 2>/dev/null)"
retire J-1

put J-2 claimed 3 "$STALE" gone-box
reset_logs
wd
[ "$(row J-2 | jq -r .status)" = failed ] && [ "$(row J-2 | jq -r .attempt)" = 4 ] \
  && ok || bad "J2 THE POINT: the release past the cap ends the row failed: $(row J-2)"
[ "$(nalerts 'QUEUE CLAIM RELEASE CAP: tproj/J-2')" = 1 ] && ok || bad "J2 one RELEASE CAP line: $(cat "$W/logs/ALERTS.log" 2>/dev/null)"
grep -q 'QUEUE CLAIM RELEASED: tproj/J-2' "$W/logs/ALERTS.log" 2>/dev/null && bad "J2 a capped row is not 'released'" || ok
grep 'RELEASE CAP: tproj/J-2' "$W/logs/ALERTS.log" | grep -q 'attempt 4 of 3 (queue.release_attempt_max)' \
  && ok || bad "J2 the line names the attempt and the settings row: $(grep 'J-2' "$W/logs/ALERTS.log")"

# ── L1 (repro) a re-review key whose apply refuses is never relaunched ────
# Tick 1 is the reap (Part A rig). The status its PATCH wrote is the row's
# status on the real worker; a reap that wrote nothing leaves the row claimed.
# Ticks 2-5 are bin/jobs-watchdog.sh runs at stale-claim age, the release
# that has no key filter (the orphan release keeps RR- rows).
LKEY=RR-31-feedf00d
pool "$LKEY" 31 "REREVIEWED APPROVE" 1
ST=$(patches "$LKEY" | jq -r .status | tail -1); [ -n "$ST" ] || ST=claimed
put "$LKEY" "$ST" 0 "$STALE" gone-box
reset_logs; REL=0
for tick in 2 3 4 5; do
  wd
  [ "$(row "$LKEY" | jq -r .status)" = queued ] && { REL=$((REL + 1)); put "$LKEY" claimed "$(row "$LKEY" | jq -r .attempt)" "$STALE" gone-box; }
done
[ "$REL" = 0 ] && ok || bad "L1 THE POINT: the refused re-review row is never relaunched, got $REL relaunches (reap left it $ST)"
[ "$(row "$LKEY" | jq -r .status)" != queued ] && ok || bad "L1 the row does not end queued: $(row "$LKEY")"

retire "$LKEY"

# J3 no queue_release_counted on the box (a half-synced one, its own tree):
# today's call, attempt unchanged.
W3="$T/w3"; mkdir -p "$W3/logs" "$W3/state" "$W3/env" "$W3/locks"; : > "$W3/env/global.env"
for L in bin/jobs-client.sh bin/jobs-watchdog.sh bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$W3" ) >/dev/null 2>&1 || bad "setup: could not install $L in w3"
done
sed -i 's/^queue_release_counted() {/_qrc_removed() {/' "$W3/bin/lib/jobs/queue.sh"
put J-3 claimed 2 "$STALE" gone-box
rm -f "$W3/logs/ALERTS.log"
wd "$W3"
[ "$(row J-3 | jq -r .status)" = queued ] && [ "$(row J-3 | jq -r .attempt)" = 2 ] \
  && ok || bad "J3 without the counted release the watchdog releases as today: $(row J-3)"
[ "$(grep -c 'QUEUE CLAIM RELEASED: tproj/J-3' "$W3/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "J3 today's RELEASED line"
retire J-2 J-3

echo "pool-release-attempt-cap.bh-8734-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
