#!/bin/bash
# tests/pool-markers-rows.bh-7431-test.sh — BH-7431 (BH-6896 S4): the pool's
# spawn-gate markers (.terminal-noted, .terminal-alerted, .after-since,
# .after-released, .after-loop, .defer-to-human) as pool_markers rows behind
# pool_state_rows, with the state/pool/<p>/ files kept as the fail-open copy.
#
# S1-S6 drive bin/lib/pool-state-rows.sh with a stub _jobs_req that answers
# GET with a body the REAL worker produced (captured below) and logs requests:
#   S1. knob off: put, clear, has and read send 0 requests.
#   S2. knob on, row present, file absent: has rc 0, read prints the row value.
#   S3. knob on, no row, file present: has rc 0, read prints the file.
#   S4. a snapshot without `markers` (an older worker): the file only.
#   S5. clear with no row sends 0 requests; with a row, one PATCH; a marker put
#       in this shell is cleared too, and then reads as gone. A failed GET, an
#       older worker or a cut markers list cannot prove no row: one PATCH each.
#   S6. two refused puts print ONE POOL_STATE_WRITE_FAILED line.
#   plus the near misses: a row of another key or another marker is absent.
# F1-F4 run the REAL bin/fly-pool.sh, the REAL bin/jobs-client.sh and the REAL
# worker (worker/jobs/src/index.js) over one file-backed node:sqlite DB, the
# shape of tests/pool-state-db.bh-5001-test.sh:
#   F1. a capped key with a cap-wait row and NO .defer-to-human file: the skip
#       is logged and no POOL_SPAWN_CAP_WAIT line reaches ALERTS.log.
#   F2. the same with the knob off pages, as today, and with the knob on and no
#       row it pages and writes the row; under the cap again the row goes.
#   F3. a terminal key with terminal-noted and terminal-alerted rows and no
#       files posts no comment and pages nothing; knob off posts one.
#   F4. an after-since row older than POOL_AFTER_MAX_MIN, with no .after-since
#       file, releases the key; with no row the key waits. The release clears
#       the after-since row and writes the after-released row.
# No network, gh or LLM call leaves the machine.
# Run from anywhere: tests/pool-markers-rows.bh-7431-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "pool-markers-rows.bh-7431: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
NOW=$(date +%s)
LIB="$DIR/bin/lib/pool-state-rows.sh"
grep -q '^psr_marker_put()' "$LIB" && ok || bad "bin/lib/pool-state-rows.sh has no psr_marker_put"

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "pool-markers-rows: SKIPPED, this node has no node:sqlite (CI's worker/jobs job runs the route suite)"
  done_
fi
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"

REALFLOCK=$(command -v flock || true)
export PS_T="$T" PS_DB="$T/d1.sqlite" PS_FLOCK="$REALFLOCK" PS_SLEEP="$(command -v sleep)" NODE_OPTIONS=--no-warnings

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
knob() { sql "UPDATE settings SET value='$2' WHERE key='$1'" >/dev/null
         local f; for f in "$T"/*/state/settings-cache.json; do
           [ -f "$f" ] && jq -c '.fetched_at = 0' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done; }
api() { node "$T/drv.mjs" "$1" "https://jobs.test$2" "${3:-}"; }

# ── a GET body the real router produced ──────────────────────────────────────
api PUT /api/pool-state/markers '{"project":"demo","key":"BH-9","marker":"after-since","value":"BH-8\t1790000000","box":"hub-a"}' >"$T/put.out"
[ "$(tail -n1 "$T/put.out")" = 200 ] && ok || bad "the real PUT /api/pool-state/markers did not answer 200: $(cat "$T/put.out")"
api GET "/api/pool-state?project=demo&since=0" > "$T/get.out"  # determinism: ok since=0 is no window, every row
REAL_GET=$(sed '$d' "$T/get.out")
[ "$(printf '%s' "$REAL_GET" | jq -r '.markers[0].value' 2>/dev/null)" = $'BH-8\t1790000000' ] && ok \
  || bad "the real GET does not list the marker row: $REAL_GET"
NOMK_GET=$(printf '%s' "$REAL_GET" | jq -c 'del(.markers) | del(.truncated.markers)')
sql "DELETE FROM pool_markers" >/dev/null

# ── S: the lib over a stub _jobs_req ─────────────────────────────────────────
# lib <knob 0|1> <get-body or -> <code>: a fresh shell with the lib, the stub
# client, LOG, and the snapshot loaded as fly-pool.sh loads it (knob on only).
# The stub logs "<METHOD> <path> <body>" to $T/s-req.log; $T/refuse refuses writes.
lib() {
  ( export S_KNOB="$1" S_GET="$2" T
    _flag_on_row() { [ "$S_KNOB" = 1 ]; }
    _jobs_req() {
      printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$T/s-req.log"
      if [ "$1" = GET ]; then [ "$S_GET" = - ] && return 7; printf '%s' "$S_GET"; return 0; fi
      [ -e "$T/refuse" ] && return 22
      return 0
    }
    LOG="$T/s.log"; P=demo; PD="$T/s-pool"; mkdir -p "$PD"
    # shellcheck source=/dev/null
    . "$LIB" || exit 3
    if psr_on; then psr_load demo 0 || psr_fallback_note demo "pool-state read"; fi
    eval "$3" )
}
sreset() { rm -rf "$T/s-pool" "$T/s-req.log" "$T/s.log" "$T/refuse"; : > "$T/s-req.log"; }
nreq() { grep -c "$1" "$T/s-req.log" 2>/dev/null; }
ROW_GET=$(printf '%s' "$REAL_GET" | jq -c '.markers = [{key:"BH-9",marker:"cap-wait",value:""},{key:"BH-9",marker:"after-since",value:"BH-8\t1790000000"}]')

# S1 knob off: nothing goes out, the files answer.
sreset
lib 0 "$ROW_GET" 'psr_marker_put demo BH-9 cap-wait ""; psr_marker_clear demo BH-9 cap-wait after-since
  psr_marker_has BH-9 cap-wait "$PD/BH-9.defer-to-human" && echo HAS; psr_marker_read BH-9 after-since "$PD/BH-9.after-since"; echo "rc=$?"' > "$T/s1.out"
[ "$(nreq .)" = 0 ] && ok || bad "S1 knob off sent requests: $(cat "$T/s-req.log")"
grep -q HAS "$T/s1.out" && bad "S1 knob off read a row as present" || ok
grep -q '^rc=1$' "$T/s1.out" && ok || bad "S1 knob off read: $(cat "$T/s1.out")"

# S2 knob on, row present, file absent.
sreset
lib 1 "$ROW_GET" 'psr_marker_has BH-9 cap-wait "$PD/BH-9.defer-to-human" && echo HAS
  psr_marker_read BH-9 after-since "$PD/BH-9.after-since" | od -c | head -1' > "$T/s2.out"
grep -q '^HAS$' "$T/s2.out" && ok || bad "S2 a cap-wait row did not read present: $(cat "$T/s2.out")"
grep -q 'B   H   -   8  \\t   1   7   9' "$T/s2.out" && ok || bad "S2 read did not print the row value with its tab: $(cat "$T/s2.out")"
[ "$(nreq '^GET ')" = 1 ] && [ "$(nreq .)" = 1 ] && ok || bad "S2 a read cost more than the one GET: $(cat "$T/s-req.log")"

# S3 knob on, no row, file present; and the near misses.
sreset; mkdir -p "$T/s-pool"; printf 'BH-7\t1790000100\n' > "$T/s-pool/BH-9.after-since"; : > "$T/s-pool/BH-9.terminal-noted"
lib 1 "$REAL_GET" 'psr_marker_has BH-9 terminal-noted "$PD/BH-9.terminal-noted" && echo HAS
  psr_marker_read BH-9 after-since "$PD/BH-9.after-since"' > "$T/s3.out"
grep -q '^HAS$' "$T/s3.out" && ok || bad "S3 a file alone did not read present"
grep -q $'^BH-7\t1790000100$' "$T/s3.out" && ok || bad "S3 read did not print the file: $(cat "$T/s3.out")"
sreset
lib 1 "$ROW_GET" 'psr_marker_has BH-10 cap-wait "$PD/BH-10.defer-to-human" && echo OTHERKEY
  psr_marker_has BH-9 terminal-noted "$PD/BH-9.terminal-noted" && echo OTHERMARKER; psr_marker BH-9 after-loop; echo "rc=$?"' > "$T/s3b.out"
grep -q 'OTHERKEY\|OTHERMARKER' "$T/s3b.out" && bad "S3 a near-miss row read present: $(cat "$T/s3b.out")" || ok
grep -q '^rc=1$' "$T/s3b.out" && ok || bad "S3 psr_marker of no row is not rc 1: $(cat "$T/s3b.out")"

# S4 an older worker (no `markers`) and an outage: the files only.
sreset
# A `markers` that is not an array (an object keyed by ticket) is not read.
lib 1 "$(printf '%s' "$NOMK_GET" | jq -c '.markers = {"BH-9":{key:"BH-9",marker:"cap-wait",value:""}}')" \
  'psr_marker_has BH-9 cap-wait "$PD/BH-9.defer-to-human" && echo HAS; psr_marker BH-9 cap-wait; echo "rc=$?"' > "$T/s4.out"
grep -q HAS "$T/s4.out" && bad "S4 an old worker's answer read a row" || ok
grep -q '^rc=2$' "$T/s4.out" && ok || bad "S4 psr_marker on an old worker is not rc 2: $(cat "$T/s4.out")"
sreset
lib 1 - 'psr_marker_has BH-9 cap-wait "$PD/BH-9.defer-to-human" && echo HAS; psr_marker BH-9 cap-wait; echo "rc=$?"' > "$T/s4b.out"
grep -q HAS "$T/s4b.out" && bad "S4 an outage read a row" || ok
grep -q '^rc=2$' "$T/s4b.out" && ok || bad "S4 psr_marker through an outage is not rc 2: $(cat "$T/s4b.out")"

# S5 clear: no row = no request; a row = one PATCH naming only the rows there.
sreset
lib 1 "$REAL_GET" 'psr_marker_clear demo BH-9 cap-wait after-loop'
[ "$(nreq '^PATCH ')" = 0 ] && ok || bad "S5 a clear with no row sent: $(cat "$T/s-req.log")"
sreset
lib 1 "$ROW_GET" 'psr_marker_clear demo BH-9 cap-wait after-loop; psr_marker_has BH-9 cap-wait "$PD/x" && echo STILL'> "$T/s5.out"
[ "$(nreq '^PATCH /api/pool-state/markers ')" = 1 ] && ok || bad "S5 a clear of a row sent: $(cat "$T/s-req.log")"
B=$(grep '^PATCH ' "$T/s-req.log" | cut -d' ' -f3-)
[ "$(printf '%s' "$B" | jq -c '[.project,.key,.markers,.clear]')" = '["demo","BH-9",["cap-wait"],true]' ] && ok \
  || bad "S5 the PATCH body: $B"
grep -q STILL "$T/s5.out" && bad "S5 a cleared row still read present in the same shell" || ok
sreset
lib 1 "$REAL_GET" 'psr_marker_put demo BH-5 after-since "BH-4	1790000000"; psr_marker BH-5 after-since; psr_marker_clear demo BH-5 after-since; psr_marker BH-5 after-since; echo "rc=$?"' > "$T/s5b.out"
[ "$(nreq '^PUT /api/pool-state/markers ')" = 1 ] && [ "$(nreq '^PATCH /api/pool-state/markers ')" = 1 ] && ok \
  || bad "S5 a put then clear in one shell: $(cat "$T/s-req.log")"
[ "$(head -1 "$T/s5b.out")" = $'BH-4\t1790000000' ] && grep -q '^rc=1$' "$T/s5b.out" && ok \
  || bad "S5 the shell's own put/clear did not read through: $(cat "$T/s5b.out")"
B=$(grep '^PUT ' "$T/s-req.log" | cut -d' ' -f3-)
[ "$(printf '%s' "$B" | jq -c '[.project,.key,.marker,.value]')" = '["demo","BH-5","after-since","BH-4\t1790000000"]' ] && ok \
  || bad "S5 the PUT body: $B"
# The snapshot did not answer, the writes do: a marker put in this shell is
# still cleared when it is removed.
sreset
lib 1 - 'psr_marker_put demo BH-5 cap-wait ""; psr_marker_clear demo BH-5 cap-wait'
[ "$(nreq '^PATCH /api/pool-state/markers ')" = 1 ] && ok || bad "S5 a put then clear through a read outage sent no PATCH: $(cat "$T/s-req.log")"
# A row from an earlier tick, a failed GET this tick: the clear cannot prove
# the row is gone, so it sends the PATCH (the refute repro: a skipped PATCH
# left an after-since row that the next tick read as live).
sreset
lib 1 - 'psr_marker_clear demo BH-9 after-since; echo "rc=$?"' > "$T/s5c.out"
[ "$(nreq '^PATCH /api/pool-state/markers ')" = 1 ] && ok || bad "S5 a clear through a failed GET sent no PATCH: $(cat "$T/s-req.log")"
B=$(grep '^PATCH ' "$T/s-req.log" | cut -d' ' -f3-)
[ "$(printf '%s' "$B" | jq -c '[.key,.markers,.clear]')" = '["BH-9",["after-since"],true]' ] && ok \
  || bad "S5 the PATCH body through a failed GET: $B"
grep -q '^rc=0$' "$T/s5c.out" && ok || bad "S5 a clear through a failed GET: $(cat "$T/s5c.out")"
# An older worker (no markers list) and a cut markers list also cannot prove
# the row is gone: each sends the PATCH.
sreset
lib 1 "$NOMK_GET" 'psr_marker_clear demo BH-9 cap-wait'
[ "$(nreq '^PATCH /api/pool-state/markers ')" = 1 ] && ok || bad "S5 a clear with no markers list sent no PATCH: $(cat "$T/s-req.log")"
CUT_GET=$(printf '%s' "$REAL_GET" | jq -c '.markers = [] | .truncated.markers = true')
sreset
lib 1 "$CUT_GET" 'psr_marker_clear demo BH-9 cap-wait'
[ "$(nreq '^PATCH /api/pool-state/markers ')" = 1 ] && ok || bad "S5 a clear with a cut markers list sent no PATCH: $(cat "$T/s-req.log")"

# S6 refused writes: one line per shell, rc 3.
sreset; : > "$T/refuse"
lib 1 "$REAL_GET" 'psr_marker_put demo BH-9 cap-wait ""; echo "rc=$?"; psr_marker_put demo BH-9 terminal-noted ""; echo "rc=$?"' > "$T/s6.out"
[ "$(grep -c '^rc=3$' "$T/s6.out")" = 2 ] && ok || bad "S6 a refused put is not rc 3: $(cat "$T/s6.out")"
[ "$(grep -c POOL_STATE_WRITE_FAILED "$T/s.log" 2>/dev/null)" = 1 ] && ok || bad "S6 want one POOL_STATE_WRITE_FAILED line: $(cat "$T/s.log" 2>/dev/null)"
sreset
lib 1 "$REAL_GET" 'psr_marker_put demo BH-9 bogus ""; echo "rc=$?"' > "$T/s6b.out"
grep -q '^rc=3$' "$T/s6b.out" && [ "$(nreq '^PUT ')" = 0 ] && ok || bad "S6 an unknown marker went out: $(cat "$T/s6b.out" "$T/s-req.log")"

# ── F: the real tick ─────────────────────────────────────────────────────────
# The fakes are tests/pool-state-db.bh-5001-test.sh's, and gh logs each comment POST.
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
if [[ "$A" == *"issues/"*"/comments"* ]] && [[ "$A" == *"body=@"* ]]; then echo "$A" >> "$PS_T/comments.log"; echo '{"id":1}'; exit 0; fi
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

A="$T/hub-a"; PA="$A/state/pool/project-5"
mkdir -p "$A/bin" "$A/logs" "$A/flags" "$A/locks" "$A/env" "$A/state/fly" "$A/state/fly-pool/project-5" \
         "$A/state/build-queue/project-5" "$A/state/remote-results/project-5" "$PA" "$A/builds"
printf 'FLY_API_TOKEN_project-5=tok\n' > "$A/env/fly.env"; : > "$A/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$A/fleet.conf"
printf '3\n' > "$A/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$A/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$A/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$A/state/fly/project-5.image"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/alert-line.sh" "$A/bin/"
for c in bin/jobs-client.sh bin/lib/pool-state-rows.sh bin/lib/hold.sh bin/lib/queue-row-job.sh; do
  scratch_install_closure "$c" "$A" >/dev/null || bad "closure: $c"
done
printf '#!/bin/bash\nexit 0\n' > "$A/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$A/bin/fly-envbundle.sh"
chmod +x "$A/bin/beat.sh" "$A/bin/fly-envbundle.sh"
JENV=(HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_TIMEOUT=30 JOBS_ALERT=0)
tick() {
  : > "$A/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$A" JOBS_HARNESS="$A" FLEET_CONF="$A/fleet.conf" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" JOBS_BOX=hub-a "${JENV[@]}" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
runs() { [ -f "$T/runs.log" ] && wc -l < "$T/runs.log" | tr -d ' ' || echo 0; }
alerts() { local n; n=$(grep -c "$1" "$A/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
comments() { [ -f "$T/comments.log" ] && wc -l < "$T/comments.log" | tr -d ' ' || echo 0; }
mk() { sql "SELECT count(*) FROM pool_markers WHERE project='project-5' AND ticket_key='$1' AND marker='$2'"; }
reset_hub() {
  local p
  for p in "$A/state/build-queue/project-5"/* "$A/state/fly-pool/project-5"/* "$PA"/* "$A/builds"/* \
           "$A/logs/ALERTS.log" "$T/runs.log" "$T/req.log" "$T/comments.log" "$T/heads"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  for p in pool_spawns pool_terminals pool_holds pool_markers build_queue; do sql "DELETE FROM $p" >/dev/null; done
  knob pool_state_rows 1; knob build_queue_rows_only 0
  return 0
}
queue_file() { # <key> <ticket-id> [after]
  jq -nc --arg k "$1" --arg t "$2" --arg a "${3:-}" '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-07T00:00:00Z"} + (if $a == "" then {} else {after:$a} end)' \
    > "$A/state/build-queue/project-5/$1.json"
}
putmk() { sql "INSERT INTO pool_markers (project,ticket_key,marker,value,box,updated_at) VALUES ('project-5','$1','$2','$3','hub-b','2026-10-19T00:00:00Z')" >/dev/null; }
capped() { printf '%s\n%s\n' "$((NOW-100))" "$((NOW-50))" > "$PA/$1.spawns"; }

# F1: the cap-wait row is the page sentinel.
reset_hub; capped BH-C1; putmk BH-C1 cap-wait ""; queue_file BH-C1 1601
tick
[ "$(runs)" = 0 ] && ok || bad "F1 a capped key spawned $(runs)"
grep -q 'skipping BH-C1: spawn cap reached' "$A/logs/fly-pool.log" && ok || bad "F1 no cap skip logged: $(tail -5 "$A/logs/fly-pool.log")"
[ "$(alerts 'BH-C1: POOL_SPAWN_CAP_WAIT')" = 0 ] && ok || bad "F1 a cap-wait row did not stop the page: $(cat "$A/logs/ALERTS.log" 2>/dev/null)"
[ ! -e "$PA/BH-C1.defer-to-human" ] && ok || bad "F1 the tick wrote a sentinel file it did not page for"
# F2: knob off pages as today; knob on with no row pages and writes the row.
reset_hub; capped BH-C1; putmk BH-C1 cap-wait ""; queue_file BH-C1 1601; knob pool_state_rows 0
tick
[ "$(alerts 'BH-C1: POOL_SPAWN_CAP_WAIT')" = 1 ] && ok || bad "F2 knob off did not page"
grep -q 'GET /api/pool-state' "$T/req.log" 2>/dev/null && bad "F2 knob off read pool-state" || ok
grep -q '/api/pool-state/markers' "$T/req.log" 2>/dev/null && bad "F2 knob off wrote a marker" || ok
reset_hub; capped BH-C1; queue_file BH-C1 1601
tick
[ "$(alerts 'BH-C1: POOL_SPAWN_CAP_WAIT')" = 1 ] && [ -e "$PA/BH-C1.defer-to-human" ] && ok || bad "F2 knob on, no row: no page or no file"
[ "$(mk BH-C1 cap-wait)" = 1 ] && ok || bad "F2 the page wrote no cap-wait row: [$(sql 'SELECT * FROM pool_markers')]"
scratch_rm "$PA/BH-C1.spawns"; queue_file BH-C1 1601
tick
[ "$(runs)" = 1 ] && ok || bad "F2 under the cap again the key did not spawn: $(runs)"
[ "$(mk BH-C1 cap-wait)" = 0 ] && [ ! -e "$PA/BH-C1.defer-to-human" ] && ok \
  || bad "F2 under the cap the sentinel stayed: [$(sql 'SELECT * FROM pool_markers')] $(ls "$PA")"
[ "$(grep -c 'PATCH /api/pool-state/markers' "$T/req.log")" = 1 ] && ok || bad "F2 want ONE marker PATCH: $(grep markers "$T/req.log")"

# F3: terminal-noted / terminal-alerted rows stop the comment and the page.
f3() {
  reset_hub
  jq -nc '{branch:"ticket/bh-t3",head_sha:"aaaaaaa",reason:"BUILD_DEFERRED push rejected",created_at:"2026-10-18 10:00:00Z"}' > "$PA/BH-T3.terminal"
  printf 'aaaaaaa' > "$T/heads/bh-t3"
  putmk BH-T3 terminal-noted ""; putmk BH-T3 terminal-alerted ""
  queue_file BH-T3 1603
}
f3; tick
[ "$(runs)" = 0 ] && ok || bad "F3 a terminal key spawned"
grep -q 'skipping BH-T3: terminal head unchanged' "$A/logs/fly-pool.log" && ok || bad "F3 no terminal skip: $(tail -5 "$A/logs/fly-pool.log")"
[ "$(comments)" = 0 ] && ok || bad "F3 a terminal-noted row did not stop the comment: $(cat "$T/comments.log")"
[ "$(alerts 'BH-T3: queued but never spawned')" = 0 ] && ok || bad "F3 a terminal-alerted row did not stop the page: $(cat "$A/logs/ALERTS.log" 2>/dev/null)"
f3; knob pool_state_rows 0; tick
[ "$(comments)" = 1 ] && ok || bad "F3 knob off: want one comment POST, got $(comments)"
[ "$(alerts 'BH-T3: queued but never spawned')" = 1 ] && ok || bad "F3 knob off: want one page"
# A re-arm clears both rows.
f3; printf 'bbbbbbb' > "$T/heads/bh-t3"; tick
[ "$(mk BH-T3 terminal-noted)$(mk BH-T3 terminal-alerted)" = 00 ] && ok || bad "F3 a re-arm left marker rows: [$(sql 'SELECT * FROM pool_markers')]"

# F4: the after-since row is the wait's clock. BH-Z9, the blocker, is queued
# too (in flight); BH-A1 sorts first, so its gate runs while BH-Z9's file is there.
f4() { reset_hub; queue_file BH-A1 1604 BH-Z9; queue_file BH-Z9 1605; }
f4; putmk BH-A1 after-since "BH-Z9	$((NOW - 7200))"
tick POOL_AFTER_MAX_MIN=60
grep -q 'RELEASED BH-A1: ceiling: held 1[0-9][0-9] min for BH-Z9' "$A/logs/fly-pool.log" && ok \
  || bad "F4 an old after-since row did not release BH-A1: $(grep BH-A1 "$A/logs/fly-pool.log" | tail -3)"
[ "$(mk BH-A1 after-since)" = 0 ] && ok || bad "F4 the release left the after-since row"
[ "$(sql "SELECT value FROM pool_markers WHERE ticket_key='BH-A1' AND marker='after-released'" | cut -f1,2)" = $'BH-Z9\t1' ] && ok \
  || bad "F4 the release wrote no after-released row: [$(sql 'SELECT * FROM pool_markers')]"
f4; tick POOL_AFTER_MAX_MIN=60
grep -q 'skipping BH-A1: waits for BH-Z9' "$A/logs/fly-pool.log" && ok \
  || bad "F4 with no row BH-A1 did not wait: $(grep BH-A1 "$A/logs/fly-pool.log" | tail -3)"
[ "$(sql "SELECT value FROM pool_markers WHERE ticket_key='BH-A1' AND marker='after-since'" | cut -f1)" = BH-Z9 ] && ok \
  || bad "F4 the wait's clock wrote no after-since row: [$(sql 'SELECT * FROM pool_markers')]"

done_
