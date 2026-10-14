#!/bin/bash
# tests/pool-state-db.bh-5001-test.sh — BH-5001 (BH-4951.2): the Fly pool's
# money-deciding state as pool_* rows, read DB-first with the hub's
# state/pool/<p>/ files as the fail-open fallback.
#
# The REAL bin/fly-pool.sh, the REAL bin/jobs-client.sh (its real _jobs_req,
# setting_get, _flag_on_row, queue_claim and build_queue_active_key) and the
# REAL worker (worker/jobs/src/index.js) over ONE file-backed node:sqlite DB: a
# fake `curl` on PATH hands each request to worker.fetch under flock on the DB
# file, the way D1 is one writer. Two scratch hubs, $A and $B, share that DB and
# nothing else.
#   A1. a terminal verdict written on A stops a respawn decided on B; knob off
#       spawns (mutation); a moved head on B re-arms and clears the row.
#   A2. the spawn cap survives deleting state/pool/; knob off spawns
#       (mutation); max(db, file) caps when the DB is short.
#   A3. two dispatchers racing on one key buy one machine, and the claimed row
#       names it; pool_key_live reads the claim.
#   A4. bin/pool-state.sh backfill is idempotent and --dry-run writes nothing.
#   B1. an outage falls back to the files with ONE POOL_STATE_FALLBACK line.
#   B2. knob off: no /api/pool-state request, no POOL_STATE_ log line.
#   B3. a non-contract 200 falls back with one line.
#   B4. fleet-status-push's held count comes from the row, and from the file
#       glob through an outage; progress-push's too.
#   B5. a lane-failure spawn hold set on A holds B; lift-hold lifts both.
# NOW is pinned once; no network, gh or LLM call leaves the machine.
# Run from anywhere: tests/pool-state-db.bh-5001-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
NOW=$(date +%s)

LIB="$DIR/bin/lib/pool-state-rows.sh"
CLI="$DIR/bin/pool-state.sh"
ROUTE="$DIR/worker/jobs/src/routes/pool-state.js"
for f in "$LIB" "$CLI" "$ROUTE"; do [ -f "$f" ] && ok || bad "missing $f"; done

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "pool-state-db: SKIPPED, this node has no node:sqlite (CI's worker/jobs job runs the route suite)"
  echo "pool-state-db.bh-5001: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
[ -f "$LIB" ] && [ -f "$CLI" ] && [ -f "$ROUTE" ] || { echo "pool-state-db.bh-5001: $PASS passed, $FAIL failed"; exit 1; }
# core.js imports the GENERATED, git-ignored catalog/lanes.json statically.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"

REALFLOCK=$(command -v flock || true)
REALSLEEP=$(command -v sleep)
export PS_T="$T" PS_DB="$T/d1.sqlite" PS_FLOCK="$REALFLOCK" PS_SLEEP="$REALSLEEP" NODE_OPTIONS=--no-warnings

# ── the worker over one file DB ──────────────────────────────────────────────
cat >"$T/init.mjs" <<EOF
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.env.PS_DB);
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
EOF
cat >"$T/drv.mjs" <<EOF
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync(process.env.PS_DB);
const [method, url, body] = process.argv.slice(2);
const res = await worker.fetch(new Request(url, {
  method, headers: { authorization: 'Bearer s', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: 's' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
node "$T/init.mjs" || { echo "FAIL: schema.sql did not apply"; exit 1; }
sql() { node -e '
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.env.PS_DB);
  const r = db.prepare(process.argv[1]).all();
  for (const row of r) console.log(Object.values(row).map((v) => v === null ? "NULL" : v).join("\t"));' "$1"; }
# BH-5781: setting_get answers from a box's fresh state/settings-cache.json, so
# a row written straight to D1 reaches a box when that cache expires. A knob
# flip here expires every scratch box's cache, as 60 s passing would.
knob() { sql "UPDATE settings SET value='$2' WHERE key='$1'" >/dev/null
         local f; for f in "$T"/*/state/settings-cache.json; do
           [ -f "$f" ] && jq -c '.fetched_at = 0' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done; }
knob pool_state_rows 1

mkdir -p "$T/fakebin" "$T/heads"
# The fake curl: `-X M`, `--data-binary B` (or @file / @-), the http(s) argument the URL.
#   jobs.test     -> the real worker, one request at a time (flock on the DB)
#   watchdog      -> the fleet-status push lands in $PS_T/PUSH.json
#   $PS_T/outage  -> every jobs request is a transport failure (rc 7)
#   $PS_T/garbage -> GET /api/pool-state answers a 200 that is not the contract
cat >"$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL=""; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; http*://*) URL="$1"; shift ;; *) shift ;; esac
done
case "$URL" in
  https://jobs.test*) ;;
  *watchdog.invalid/api/status*) cat > "$PS_T/PUSH.json"; exit 0 ;;
  *) exit 22 ;;
esac
case "$BODY" in @-) BODY=$(cat) ;; @*) BODY=$(cat "${BODY#@}") ;; esac
printf '%s %s\n' "$M" "${URL#https://jobs.test}" >> "$PS_T/req.log"
[ -e "$PS_T/outage" ] && exit 7
if [ -e "$PS_T/garbage" ] && [ "$M" = GET ] && [[ "$URL" == *"/api/pool-state?"* ]]; then
  printf '{"queue":[]}\n200'; exit 0
fi
if [ -n "$PS_FLOCK" ]; then exec "$PS_FLOCK" "$PS_DB.lock" node "$PS_T/drv.mjs" "$M" "$URL" "$BODY"; fi
exec node "$PS_T/drv.mjs" "$M" "$URL" "$BODY"
STUB
# Fly: every `machine run` is a NEW 14-hex id, logged to the ONE shared runs.log.
cat >"$T/fakebin/fly" <<'FLY'
#!/bin/bash
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*)
    id=$(od -An -tx1 -N7 /dev/urandom | tr -d ' \n')
    echo "machine run $id ${JOBS_BOX:-}" >> "$PS_T/runs.log"
    printf 'Machine ID: %s\n' "$id" ;;
esac
exit 0
FLY
# gh: every ticket open and labelled, no comments, no open PR; a branch head is
# $PS_T/heads/<branch-suffix> or none. With $PS_T/barrier the PR-list read waits
# until both hubs reached it, so the A3 race is a real one.
cat >"$T/fakebin/gh" <<'GH'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
A="$*"
if [[ "$A" == *"issues/"*"/comments"* ]] && [[ "$A" == *"body=@"* ]]; then echo '{"id":1}'; exit 0; fi
if [[ "$A" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$A" == *"-i"* ]]; then
  if [[ "$A" == *"git/ref/heads/ticket/"* ]]; then
    k=${A##*git/ref/heads/ticket/}; k=${k%% *}
    printf 'HTTP/1.1 200 OK\n\n'
    if [ -f "$PS_T/heads/$k" ]; then printf '{"object":{"sha":"%s"}}\n' "$(cat "$PS_T/heads/$k")"; else echo '{}'; fi
    exit 0
  fi
  if [[ "$A" == *"pulls?state=open"* ]]; then
    if [ -e "$PS_T/barrier" ]; then
      : > "$PS_T/barrier.${JOBS_BOX:-x}"; n=0
      while [ "$(ls "$PS_T"/barrier.* 2>/dev/null | wc -l)" -lt 2 ] && [ "$n" -lt 300 ]; do "$PS_SLEEP" 0.1; n=$((n+1)); done
    fi
    printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0
  fi
  if [[ "$A" == *"repos/example-org/project-5"* ]]; then printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
if [[ "$A" == *"repos/example-org/project-5/issues/"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"a ticket","body":""}'; exit 0
fi
exit 0
GH
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/base64" <<'B64'
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
B64
chmod +x "$T/fakebin"/*

# ── two hubs ─────────────────────────────────────────────────────────────────
make_hub() { # <dir>
  local h="$1"
  mkdir -p "$h/bin" "$h/logs" "$h/flags" "$h/locks" "$h/env" "$h/state/fly" \
           "$h/state/fly-pool/project-5" "$h/state/build-queue/project-5" \
           "$h/state/remote-results/project-5" "$h/state/pool/project-5" "$h/builds"
  printf 'FLY_API_TOKEN_project-5=tok\n' > "$h/env/fly.env"
  : > "$h/env/global.env"
  printf 'project-5 example-org/project-5 - - 0 local\n' > "$h/fleet.conf"
  printf '3\n' > "$h/flags/fly-pool-project-5"
  printf 'pool-project-5\n' > "$h/flags/fly-pool-app-project-5"
  printf '{"app":"pool-project-5"}\n' > "$h/state/fly/project-5.json"
  printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$h/state/fly/project-5.image"
  cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/alert-line.sh" "$h/bin/"
  scratch_install_closure bin/jobs-client.sh "$h" >/dev/null || bad "closure: jobs-client.sh"
  scratch_install_closure bin/lib/pool-state-rows.sh "$h" >/dev/null || bad "closure: pool-state-rows.sh"
  scratch_install_closure bin/lib/hold.sh "$h" >/dev/null || bad "closure: hold.sh"
  scratch_install_closure bin/lib/queue-row-job.sh "$h" >/dev/null || bad "closure: queue-row-job.sh"
  printf '#!/bin/bash\nexit 0\n' > "$h/bin/beat.sh"
  printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$h/bin/fly-envbundle.sh"
  chmod +x "$h/bin/beat.sh" "$h/bin/fly-envbundle.sh"
}
A="$T/hub-a"; B="$T/hub-b"
make_hub "$A"; make_hub "$B"
box_of() { case "$1" in "$A") echo hub-a ;; "$B") echo hub-b ;; esac; }

JENV=(HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_TIMEOUT=30 JOBS_ALERT=0)
# tick <hub> [VAR=val ...] — one real fly-pool tick on that hub, its log fresh.
tick() {
  local h="$1"; shift
  : > "$h/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$h" JOBS_HARNESS="$h" FLEET_CONF="$h/fleet.conf" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" JOBS_BOX="$(box_of "$h")" "${JENV[@]}" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
# fx <name> — one function's text out of the real bin/fly-pool.sh.
fx() {
  awk -v n="$1" '
    !on && index($0, n "() {") == 1 { print; if ($0 ~ /; }[[:space:]]*$/) exit; on = 1; next }
    on { print; if ($0 ~ /^}/) exit }' "$DIR/bin/fly-pool.sh"
}
FUNCS=""
for f in pool_terminal_path pool_terminal_write pool_spawn_cap_record pool_spawn_cap_check \
         pool_spawn_hold_path pool_spawn_held pool_spawn_hold_set pool_key_live; do
  body=$(fx "$f")
  [ -n "$body" ] && ok || bad "bin/fly-pool.sh has no $f()"
  FUNCS+="$body"$'\n'
done
# on_hub <hub> <code> — extracted fly-pool functions in that hub's context.
on_hub() {
  local h="$1"; shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$h" JOBS_HARNESS="$h" JOBS_BOX="$(box_of "$h")" "${JENV[@]}"
    P=project-5; PDIR="$h/state/pool/project-5"; POOL="$h/state/fly-pool/project-5"; LOG="$h/logs/fly-pool.log"
    POOL_LANE_FAIL_HOLD_S=1800
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
    say() { echo "$(STAMP) [pool/$P] $*" >> "$LOG"; }
    # shellcheck source=/dev/null
    . "$h/bin/jobs-client.sh" || exit 3
    # shellcheck source=/dev/null
    . "$h/bin/lib/pool-state-rows.sh" || exit 3
    eval "$FUNCS"
    psr_on && psr_load "$P" 0
    eval "$1" )
}
runs() { [ -f "$T/runs.log" ] && wc -l < "$T/runs.log" | tr -d ' ' || echo 0; }
reset_hubs() {
  local p h
  for h in "$A" "$B"; do
    for p in "$h/state/build-queue/project-5"/* "$h/state/fly-pool/project-5"/* "$h/state/pool/project-5"/* \
             "$h/builds"/* "$h/state/remote-results/project-5"/*; do
      [ -e "$p" ] && scratch_rm "$p"
    done
  done
  for p in "$T/runs.log" "$T/req.log" "$T/outage" "$T/garbage" "$T/barrier" "$T"/barrier.* "$T/heads"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  sql "DELETE FROM pool_spawns" >/dev/null; sql "DELETE FROM pool_terminals" >/dev/null
  sql "DELETE FROM pool_holds" >/dev/null; sql "DELETE FROM build_queue" >/dev/null
  knob pool_state_rows 1; knob build_queue_rows_only 0
  return 0
}
queue_file() { # <hub> <key> <ticket-id>
  jq -nc --arg k "$2" --arg t "$3" '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-07T00:00:00Z"}' \
    > "$1/state/build-queue/project-5/$2.json"
}

# ── A1: a terminal written on A stops a respawn decided on B ─────────────────
reset_hubs
on_hub "$A" 'pool_terminal_write BH-T1 ticket/bh-t1 aaaaaaa "BUILD_DEFERRED push of ticket/bh-t1 rejected"'
[ -f "$A/state/pool/project-5/BH-T1.terminal" ] && ok || bad "A1 pool_terminal_write wrote no file on A"
[ "$(sql "SELECT head_sha||'|'||ifnull(cleared_at,'-')||'|'||box FROM pool_terminals WHERE ticket_key='BH-T1'")" = "aaaaaaa|-|hub-a" ] \
  && ok || bad "A1 the terminal row is not A's: [$(sql "SELECT * FROM pool_terminals")]"
printf 'aaaaaaa' > "$T/heads/bh-t1"
queue_file "$B" BH-T1 1501
grep -q . <<<"$(ls "$B/state/pool/project-5/")" && bad "A1 B is supposed to have no state/pool files" || ok
tick "$B"
[ "$(runs)" = 0 ] && ok || bad "A1 B spawned $(runs) machine(s) for a key A recorded terminal"
grep -q 'skipping BH-T1: terminal head unchanged' "$B/logs/fly-pool.log" && ok \
  || bad "A1 B's log has no terminal skip: $(tail -5 "$B/logs/fly-pool.log")"
# mutation: the same tick with the knob off spawns — the ROW is what stopped it.
knob pool_state_rows 0
tick "$B"
[ "$(runs)" = 1 ] && ok || bad "A1 mutation: knob off should spawn one machine on B, got $(runs)"
knob pool_state_rows 1
# re-arm: the head moves; B's tick re-arms and the row records the clear.
for p in "$B/state/fly-pool/project-5"/* "$B/state/pool/project-5"/* "$T/runs.log"; do [ -e "$p" ] && scratch_rm "$p"; done
queue_file "$B" BH-T1 1501
printf 'bbbbbbb' > "$T/heads/bh-t1"
tick "$B"
[ "$(runs)" = 1 ] && ok || bad "A1 re-arm: a moved head should spawn one machine on B, got $(runs)"
grep -q 'terminal BH-T1: remote head changed' "$B/logs/fly-pool.log" && ok || bad "A1 re-arm not logged on B"
[ "$(sql "SELECT cleared_at IS NOT NULL FROM pool_terminals WHERE ticket_key='BH-T1'")" = 1 ] && ok \
  || bad "A1 re-arm did not clear the row: [$(sql "SELECT * FROM pool_terminals")]"
# ...and A's stale file loses to B's clear: A spawns and deletes its file.
for p in "$T/runs.log"; do [ -e "$p" ] && scratch_rm "$p"; done
queue_file "$A" BH-T1 1501
tick "$A"
[ "$(runs)" = 1 ] && ok || bad "A1 A's older file beat B's clear: A spawned $(runs)"
[ ! -f "$A/state/pool/project-5/BH-T1.terminal" ] && ok || bad "A1 A kept its stale terminal file"

# ── A2: the spawn cap survives deleting state/pool/ ──────────────────────────
reset_hubs
on_hub "$A" 'pool_spawn_cap_record BH-C1 >/dev/null; pool_spawn_cap_record BH-C1 >/dev/null'
[ "$(grep -c . "$A/state/pool/project-5/BH-C1.spawns")" = 2 ] && ok || bad "A2 the file has no two lines"
# Two records in one second collapse to one row (the PK) — only on a fast box.
NROWS=$(sql "SELECT count(*) FROM pool_spawns WHERE ticket_key='BH-C1'")
[ "$NROWS" -ge 1 ] && ok || bad "A2 no pool_spawns row was written"
sql "DELETE FROM pool_spawns" >/dev/null
sql "INSERT INTO pool_spawns VALUES ('project-5','BH-C1',$((NOW-60)),'hub-a',NULL,'x'),('project-5','BH-C1',$((NOW-30)),'hub-a',NULL,'x')" >/dev/null
scratch_rm "$A/state/pool"
queue_file "$A" BH-C1 1502
tick "$A"
[ "$(runs)" = 0 ] && ok || bad "A2 a rebuilt hub (no state/pool) spawned $(runs) for a capped key"
grep -q 'skipping BH-C1: spawn cap reached' "$A/logs/fly-pool.log" && ok || bad "A2 cap skip not logged"
# mutation: knob off, the deleted file is all there is, and it spawns.
knob pool_state_rows 0
for p in "$A/state/pool/project-5"/*; do [ -e "$p" ] && scratch_rm "$p"; done
queue_file "$A" BH-C1 1502
tick "$A"
[ "$(runs)" = 1 ] && ok || bad "A2 mutation: knob off should spawn one machine, got $(runs)"
# max rule: the DB short (1 row), the file holding 2 lines — capped.
reset_hubs
sql "INSERT INTO pool_spawns VALUES ('project-5','BH-C2',$((NOW-60)),'hub-a',NULL,'x')" >/dev/null
printf '%s\n%s\n' "$((NOW-100))" "$((NOW-50))" > "$A/state/pool/project-5/BH-C2.spawns"
queue_file "$A" BH-C2 1503
tick "$A"
[ "$(runs)" = 0 ] && ok || bad "A2 max: a DB undercount let $(runs) spawn(s) through"
grep -q 'skipping BH-C2: spawn cap reached' "$A/logs/fly-pool.log" && ok || bad "A2 max: cap skip not logged"
# ...and the other way: DB 2 rows, file 1 line.
reset_hubs
sql "INSERT INTO pool_spawns VALUES ('project-5','BH-C3',$((NOW-60)),'hub-b',NULL,'x'),('project-5','BH-C3',$((NOW-30)),'hub-b',NULL,'x')" >/dev/null
printf '%s\n' "$((NOW-100))" > "$A/state/pool/project-5/BH-C3.spawns"
queue_file "$A" BH-C3 1504
tick "$A"
[ "$(runs)" = 0 ] && ok || bad "A2 max: a file undercount let $(runs) spawn(s) through"
# A row outside the window does not count.
reset_hubs
sql "INSERT INTO pool_spawns VALUES ('project-5','BH-C4',$((NOW-90000)),'hub-b',NULL,'x'),('project-5','BH-C4',$((NOW-30)),'hub-b',NULL,'x')" >/dev/null
queue_file "$A" BH-C4 1505
tick "$A"
[ "$(runs)" = 1 ] && ok || bad "A2 window: a row older than the window counted ($(runs) spawns, want 1)"
[ "$(sql "SELECT count(*) FROM pool_spawns WHERE ticket_key='BH-C4' AND box='hub-a'")" = 1 ] && ok \
  || bad "A2 the spawn did not record its pool_spawns row: [$(sql "SELECT * FROM pool_spawns")]"

# ── A3: two dispatchers race on one key, one machine ─────────────────────────
reset_hubs
knob build_queue_rows_only 1
sql "INSERT INTO build_queue (project,ticket_key,ticket_id,status,target,attempt,enqueued_at,updated_at)
     VALUES ('project-5','BH-R1','1506','queued','fly',0,'2026-10-07T00:00:00Z','2026-10-07T00:00:00Z')" >/dev/null
: > "$T/barrier"
tick "$A" & PA=$!
tick "$B" & PB=$!
wait "$PA"; wait "$PB"
[ "$(runs)" = 1 ] && ok || bad "A3 two racing hubs bought $(runs) machines for one key: $(cat "$T/runs.log" 2>/dev/null)"
MID=$(awk '{print $3}' "$T/runs.log" 2>/dev/null | head -1)
[ "$(sql "SELECT status||'|'||ifnull(machine,'-') FROM build_queue WHERE ticket_key='BH-R1'")" = "claimed|$MID" ] && ok \
  || bad "A3 the claimed row does not name the machine $MID: [$(sql "SELECT status,machine FROM build_queue")]"
cat "$A/logs/fly-pool.log" "$B/logs/fly-pool.log" | grep -q 'BH-R1: the queue row refused this claim' && ok \
  || bad "A3 neither hub logged the refused claim"
scratch_rm "$T/barrier"
# The winner's machine json goes: the fake fly lists no machines, and a reap of a
# vanished machine is not what this tick is about.
for p in "$A/state/fly-pool/project-5"/*.json "$B/state/fly-pool/project-5"/*.json; do [ -e "$p" ] && scratch_rm "$p"; done
tick "$B"
[ "$(runs)" = 1 ] && ok || bad "A3 a second B tick spawned again: $(runs)"
# pool_key_live: the claimed row says live with no state/fly-pool json on B.
ls "$B/state/fly-pool/project-5/"*.json >/dev/null 2>&1 && scratch_rm "$B/state/fly-pool/project-5"/*.json
on_hub "$B" 'ROWS_ONLY=1; pool_key_live BH-R1' && ok || bad "A3 pool_key_live missed the claimed row"
on_hub "$B" 'ROWS_ONLY=0; pool_key_live BH-R1' && bad "A3 pool_key_live read the row with ROWS_ONLY off" || ok
on_hub "$B" 'ROWS_ONLY=1; pool_key_live BH-NONE' && bad "A3 pool_key_live called an unclaimed key live" || ok
printf '{"machine":"m1","key":"BH-F1"}\n' > "$B/state/fly-pool/project-5/m1.json"
on_hub "$B" 'ROWS_ONLY=0; pool_key_live BH-F1' && ok || bad "A3 pool_key_live lost the file match"

# ── A4: backfill is idempotent ───────────────────────────────────────────────
reset_hubs
mkdir -p "$A/state/pool/p1" "$A/state/pool/p2"
on_hub "$A" 'P=p1; PDIR="$HARNESS/state/pool/p1"; pool_spawn_cap_record BH-5 >/dev/null'
printf '%s\n%s\n%s\n' "$((NOW-100))" "$((NOW-100))" "$((NOW-200))" > "$A/state/pool/p1/BH-1.spawns"
jq -nc '{branch:"ticket/bh-1",head_sha:"abc",reason:"push rejected",created_at:"2026-10-06 10:00:00Z"}' > "$A/state/pool/p1/BH-1.terminal"
jq -nc '{key:"BH-2",ticket_id:"22",why:"hold:body HOLD",first_seen:"2026-10-06 09:00:00Z",last_seen:"2026-10-06 11:00:00Z"}' > "$A/state/pool/p1/BH-2.held"
printf '%s %s\n' "$((NOW+3600))" "BH-1: RUNNER_EXHAUSTED" > "$A/state/pool/p1/_spawn-hold"
printf '%s\n' "$((NOW-50))" > "$A/state/pool/p2/BH-3.spawns"
printf '%s %s\n' "$((NOW-60))" "expired" > "$A/state/pool/p2/_spawn-hold"
bf() { ( export PATH="$T/fakebin:$PATH" HARNESS="$A" JOBS_HARNESS="$A" JOBS_BOX=hub-a "${JENV[@]}"
         bash "$CLI" "$@" ); }
counts() { echo "$(sql "SELECT count(*) FROM pool_spawns") $(sql "SELECT count(*) FROM pool_terminals") $(sql "SELECT count(*) FROM pool_holds")"; }
[ "$(counts)" = "1 0 0" ] && ok || bad "A4 before the backfill only the live record is a row: $(counts)"
bf backfill --dry-run > "$T/bf0.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "A4 --dry-run rc=$rc: $(cat "$T/bf0.out")"
[ "$(counts)" = "1 0 0" ] && ok || bad "A4 --dry-run wrote rows: $(counts)"
bf backfill > "$T/bf1.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "A4 first backfill rc=$rc: $(cat "$T/bf1.out")"
bf backfill > "$T/bf2.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "A4 second backfill rc=$rc: $(cat "$T/bf2.out")"
[ "$(counts)" = "5 1 2" ] && ok || bad "A4 rows after two backfills: $(counts), want spawns 5 terminals 1 holds 2"
T1=$(grep '^TOTAL ' "$T/bf1.out"); T2=$(grep '^TOTAL ' "$T/bf2.out")
[ "$T1" = "TOTAL spawns=5 terminals=1 holds=2" ] && [ "$T1" = "$T2" ] && ok \
  || bad "A4 TOTAL lines differ or are wrong: [$T1] [$T2]"
grep -q '^p1 spawns files=2 sent=4 inserted=3$' "$T/bf1.out" && ok || bad "A4 p1 spawns line: $(grep '^p1 spawns' "$T/bf1.out")"
grep -q '^p1 holds files=2 sent=2 inserted=2$' "$T/bf1.out" && ok || bad "A4 p1 holds line: $(grep '^p1 holds' "$T/bf1.out")"
grep -q '^p2 holds files=1 sent=0 inserted=0$' "$T/bf1.out" && ok || bad "A4 an expired spawn hold was sent: $(grep '^p2 holds' "$T/bf1.out")"
grep -vq 'inserted=0$' <<<"$(grep -E '^p[12] ' "$T/bf2.out")" && bad "A4 the second run inserted: $(cat "$T/bf2.out")" || ok
[ "$(grep -cE '^p[12] ' "$T/bf2.out")" = 6 ] && ok || bad "A4 want one line per project and kind: $(cat "$T/bf2.out")"
[ "$(sql "SELECT count(*) FROM pool_spawns WHERE project='p1' AND ticket_key='BH-1' AND box='hub-a#2'")" = 1 ] && ok \
  || bad "A4 the repeated ts was not kept as its own row"
bf show p1 > "$T/show.out" 2>&1 && grep -q $'^terminal\tBH-1\t' "$T/show.out" && ok || bad "A4 show p1: $(cat "$T/show.out")"
touch "$T/outage"
bf backfill p1 > "$T/bf3.out" 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "A4 an unreachable worker should be rc 1, got $rc: $(cat "$T/bf3.out")"
scratch_rm "$T/outage"
# lift-hold removes the file and the row.
bf lift-hold p1 > "$T/lift.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$A/state/pool/p1/_spawn-hold" ] \
  && [ "$(sql "SELECT count(*) FROM pool_holds WHERE project='p1' AND kind='spawn'")" = 0 ] && ok \
  || bad "A4 lift-hold rc=$rc left [$(ls "$A/state/pool/p1/")] [$(sql "SELECT * FROM pool_holds")]"

# ── B1: an outage falls back to the files, ONE line per tick ─────────────────
reset_hubs
for k in BH-O1 BH-O2 BH-O3; do
  queue_file "$A" "$k" 1510
  printf '%s\n%s\n' "$((NOW-100))" "$((NOW-50))" > "$A/state/pool/project-5/$k.spawns"
done
touch "$T/outage"
tick "$A" POOL_STATE_ROWS=1
[ "$(runs)" = 0 ] && ok || bad "B1 an outage read as no cap: $(runs) spawn(s)"
[ "$(grep -c 'skipping BH-O.: spawn cap reached' "$A/logs/fly-pool.log")" = 3 ] && ok || bad "B1 not every key capped"
[ "$(grep -c 'POOL_STATE_FALLBACK' "$A/logs/fly-pool.log")" = 1 ] && ok \
  || bad "B1 want ONE POOL_STATE_FALLBACK line, got $(grep -c POOL_STATE_FALLBACK "$A/logs/fly-pool.log")"

# ── B2: knob off is silent ───────────────────────────────────────────────────
reset_hubs
knob pool_state_rows 0
queue_file "$A" BH-S1 1511
queue_file "$A" BH-S2 1511
printf 'xxxxxxx' > "$T/heads/bh-s2"
on_hub "$A" 'pool_terminal_write BH-S2 ticket/bh-s2 xxxxxxx y; pool_spawn_cap_record BH-S1 >/dev/null' >/dev/null
tick "$A"
[ "$(runs)" = 1 ] && ok || bad "B2 knob off should spawn BH-S1 once, got $(runs)"
grep -q 'skipping BH-S2: terminal head unchanged' "$A/logs/fly-pool.log" && ok || bad "B2 knob off lost the file terminal"
grep -q '/api/pool-state' "$T/req.log" && bad "B2 knob off made pool-state requests: $(grep pool-state "$T/req.log")" || ok
grep -q 'POOL_STATE_' "$A/logs/fly-pool.log" && bad "B2 knob off logged a POOL_STATE_ line" || ok
[ "$(counts)" = "0 0 0" ] && ok || bad "B2 knob off wrote rows: $(counts)"

# ── B3: a non-contract 200 falls back with one line ──────────────────────────
reset_hubs
for k in BH-G1 BH-G2; do
  queue_file "$A" "$k" 1512
  printf '%s\n%s\n' "$((NOW-100))" "$((NOW-50))" > "$A/state/pool/project-5/$k.spawns"
done
touch "$T/garbage"
tick "$A"
[ "$(runs)" = 0 ] && ok || bad "B3 a non-contract 200 read as no cap: $(runs) spawn(s)"
[ "$(grep -c 'POOL_STATE_FALLBACK' "$A/logs/fly-pool.log")" = 1 ] && ok || bad "B3 want ONE POOL_STATE_FALLBACK line"

# ── B4: held counts DB-first ─────────────────────────────────────────────────
reset_hubs
F="$T/fsp"
mkdir -p "$F/bin" "$F/logs" "$F/state/build-queue/project-5" "$F/state/pool/project-5" "$F/flags" "$F/env" "$F/builds"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$DIR/bin/alert_family.py" "$F/bin/"
scratch_install_closure bin/fleet-status-push.sh "$F" >/dev/null || bad "closure: fleet-status-push.sh"
scratch_install_closure bin/jobs-client.sh "$F" >/dev/null || bad "closure: jobs-client.sh (fsp)"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\nWATCHDOG_URL=http://watchdog.invalid\n' > "$F/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$F/bin/beat.sh"; chmod +x "$F/bin/beat.sh"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$F/fleet.conf"
for k in BH-H1 BH-H2 BH-H3; do queue_file "$F" "$k" 1520; done
# The rows: BH-H1 (queued) and BH-GONE (no queue file). The files: BH-H2 and
# BH-H3 (queued) and BH-H4 (no queue file). Each answer is a different number.
on_hub "$A" 'psr_hold_put project-5 ticket BH-H1 1520 "" "hold:body HOLD" "2026-10-07 00:00:00Z"'
on_hub "$A" 'psr_hold_put project-5 ticket BH-GONE 1529 "" "hold:body HOLD" "2026-10-07 00:00:00Z"'
fsp() { for p in "$T/PUSH.json"; do [ -e "$p" ] && scratch_rm "$p"; done
        ( export PATH="$T/fakebin:$PATH" HARNESS="$F" JOBS_HARNESS="$F" FLEET_CONF="$F/fleet.conf" JOBS_BOX=hub-a JOBS_RETRIES=0 JOBS_ALERT=0
          bash "$DIR/bin/fleet-status-push.sh" >/dev/null 2>&1 ); jq -r '.projects.project-5.held' "$T/PUSH.json" 2>/dev/null; }
[ "$(fsp)" = 1 ] && ok || bad "B4 fleet-status-push held from the row: want 1 (BH-GONE has no queue file), got [$(fsp)]"
for k in BH-H2 BH-H3 BH-H4; do printf '{}' > "$F/state/pool/project-5/$k.held"; done
[ "$(fsp)" = 1 ] && ok || bad "B4 knob on: the row set answers, not the files: want 1, got [$(fsp)]"
touch "$T/outage"
[ "$(fsp)" = 2 ] && ok || bad "B4 outage reads the file glob: want 2 (BH-H4 has no queue file), got [$(fsp)]"
scratch_rm "$T/outage"
knob pool_state_rows 0
[ "$(fsp)" = 2 ] && ok || bad "B4 knob off reads the file glob only: want 2, got [$(fsp)]"
knob pool_state_rows 1
# progress-push counts every held key, queue file or not: rows 2, files 3.
pph() { ( export PATH="$T/fakebin:$PATH" HARNESS="$F" JOBS_HARNESS="$F" JOBS_BOX=hub-a "${JENV[@]}"
          . "$F/bin/jobs-client.sh"; . "$F/bin/lib/pool-state-rows.sh"
          H="$F"; P=project-5
          eval "$(sed -n '/^  # >>> held count (BH-5001)/,/^  # <<< held count (BH-5001)/p' "$DIR/bin/progress-push.sh")"
          echo "$HELD" ); }
[ "$(pph)" = 2 ] && ok || bad "B4 progress-push held from the rows: want 2, got [$(pph)]"
touch "$T/outage"
[ "$(pph)" = 3 ] && ok || bad "B4 progress-push through an outage reads the files: want 3, got [$(pph)]"
scratch_rm "$T/outage"

# ── B5: a spawn hold set on A holds B; lift-hold lifts it ────────────────────
reset_hubs
on_hub "$A" 'pool_spawn_hold_set "BH-L1: RUNNER_EXHAUSTED"' || bad "B5 pool_spawn_hold_set refused"
queue_file "$B" BH-L2 1530
tick "$B"
[ "$(runs)" = 0 ] && ok || bad "B5 B spawned $(runs) under A's spawn hold"
grep -q 'spawn hold: the runner lane failed' "$B/logs/fly-pool.log" && ok || bad "B5 B did not log the hold"
( export PATH="$T/fakebin:$PATH" HARNESS="$A" JOBS_HARNESS="$A" JOBS_BOX=hub-a "${JENV[@]}"; bash "$CLI" lift-hold project-5 ) >/dev/null 2>&1
[ ! -e "$A/state/pool/project-5/_spawn-hold" ] && [ "$(sql "SELECT count(*) FROM pool_holds")" = 0 ] && ok \
  || bad "B5 lift-hold left a hold behind"
tick "$B"
[ "$(runs)" = 1 ] && ok || bad "B5 after lift-hold B should spawn once, got $(runs)"
grep -q 'bin/pool-state.sh lift-hold' "$DIR/bin/fly-pool.sh" && ok || bad "B5 the lane-failure alert does not name lift-hold"

echo "pool-state-db.bh-5001: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
