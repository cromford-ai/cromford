#!/bin/bash
# tests/lane-run-dedicated-machine.bh-7716-test.sh — BH-7716 T3: a worker loop
# of the dedicated lane machine claims as box `fly-dedicated` under its own
# machine id `<FLY_MACHINE_ID>-w<i>`, and a TERM mid-run hands its row back.
#
# Driven through the REAL bin/lane-run-worker.sh and bin/project-lane-run.sh
# over real curl against a stub jobs worker ($T/stub.mjs, 127.0.0.1). The stub
# records every request body, answers one queued row per file in $T/q/ (and
# echoes the claim's `box` unless the row file asks not to), answers 200 to
# heartbeat, release and report, and 404 to every other path (so every
# settings read takes its code fallback).
#
#   D1  --box fly-dedicated --machine m1-w2: the claim body has box
#       "fly-dedicated" and machine "m1-w2"; TERM mid-run: one release POST for
#       that row id with machine m1-w2, no report, exit 0
#   D2  LANE_RUN_BOX=fly-dedicated (env) --machine m1-w3: the same claim body;
#       the run is reported rc 0 as m1-w3
#   D3  --box beats LANE_RUN_BOX
#   D4  --box with no --machine: the machine id is the box name (#7662)
#   D5  an answer without `box`: released, not run, exit 1 (#7662), with
#       distinct --box and --machine ids
#   D6  a bad LANE_RUN_BOX exits 2 and sends no claim
#   D7  N loops and the code sync: while a run is in flight the loop holds
#       locks/lane-run-code.lock shared (an exclusive flock -n fails); a
#       HARNESS_COMMIT changed during the run makes the loop re-exec before
#       its next claim; after the run the lock is free
#   D8  LANE_RUN_CODE_SYNC=1 with the code lock held shared by another loop:
#       `code sync skipped`, no fetch; with the lock free the sync runs (and
#       fails here on a missing URL, as designed)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-run-dedicated-machine.bh-7716-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or setsid missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/q"
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
scratch_rm "$H/catalog/lane-run-inputs.d"
chmod +x "$H/bin/"*.sh 2>/dev/null
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
# The lane: marks its start, then blocks while $T/block exists.
cat > "$H/bin/slow-lane.sh" <<EOF
#!/bin/bash
trap 'echo "term \$LANE_RUN_ID" >> "$T/term.txt"; exit 143' TERM
echo "start \$LANE_RUN_ID" >> "$T/start.txt"
i=0; while [ -e "$T/block" ] && [ "\$i" -lt 300 ]; do sleep 0.1; i=\$((i+1)); done
echo "PROF slow"
exit 0
EOF
chmod +x "$H/bin/slow-lane.sh"

cat > "$T/stub.mjs" <<'EOF'
// The stub jobs worker of this suite. argv: <log> <queue dir>.
import { createServer } from 'node:http';
import { appendFileSync, readdirSync, readFileSync, unlinkSync } from 'node:fs';
const [, , log, qdir] = process.argv;
const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    const path = req.url.split('?')[0];
    let code = 404; let out = '{"error":"not found"}';
    if (req.method === 'POST' && path === '/api/lane-runs/claim') {
      const f = readdirSync(qdir).sort()[0];
      if (!f) { code = 204; out = ''; } else {
        const row = JSON.parse(readFileSync(`${qdir}/${f}`, 'utf8'));
        unlinkSync(`${qdir}/${f}`);
        const b = JSON.parse(body || '{}');
        const nobox = row.nobox; delete row.nobox;
        if (b.box && !nobox) row.box = b.box;
        code = 200; out = JSON.stringify(row);
      }
    } else if (req.method === 'POST' && /^\/api\/lane-runs\/\d+\/(heartbeat|release|report)$/.test(path)) {
      code = 200; out = '{"ok":true}';
    }
    appendFileSync(log, `${req.method} ${path} ${code} ${body.replace(/\n/g, ' ')}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(code === 204 ? undefined : out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 180000).unref();
EOF
: > "$T/s.log"; : > "$T/s.port"
node "$T/stub.mjs" "$T/s.log" "$T/q" > "$T/s.port" 2> "$T/s.err" &
SPID=$!
trap 'kill "$SPID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/s.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/s.port")
[ -n "$PORT" ] || { echo "setup: stub did not start: $(cat "$T/s.err")"; exit 1; }

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" JOBS_URL="http://127.0.0.1:$PORT"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box
unset LANE_RUN_BOX
WLOG="$H/logs/lane-run-worker.log"
WAITFOR() { local i; for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
# row <id> [nobox] — queue one claim answer.
row() { jq -nc --argjson id "$1" --arg nb "${2:-}" \
  '{id:$id, lane:"blocked-resolver", project:"p1", args:["bin/slow-lane.sh"], attempts:1} + (if $nb == "" then {} else {nobox:true} end)' > "$T/q/$1.json"; }
claims() { grep '^POST /api/lane-runs/claim ' "$T/s.log" | sed 's/^POST \/api\/lane-runs\/claim [0-9]* //'; }
lastclaim() { claims | tail -1; }
mark() { S0=$(wc -l < "$T/s.log"); }
newreq() { tail -n +"$((S0 + 1))" "$T/s.log"; }

# ============================================================================
echo "D1: --box fly-dedicated --machine m1-w2; TERM mid-run"
: > "$T/start.txt"; : > "$T/term.txt"; : > "$T/block"; mark
row 101
"$H/bin/lane-run-worker.sh" --box fly-dedicated --machine m1-w2 > "$T/d1.out" 2>&1 & W=$!
WAITFOR '[ -s "$T/start.txt" ]' || bad "D1 setup: the run never started: $(cat "$T/d1.out" "$WLOG" 2>/dev/null)"
C=$(newreq | grep '^POST /api/lane-runs/claim ' | head -1 | sed 's/^POST \/api\/lane-runs\/claim [0-9]* //')
[ "$(jq -r .box <<<"$C" 2>/dev/null)" = fly-dedicated ] && [ "$(jq -r .machine <<<"$C" 2>/dev/null)" = m1-w2 ] \
  && ok "D1 the claim body has box fly-dedicated and machine m1-w2" || bad "D1 claim body: $C; out $(cat "$T/d1.out")"
kill -TERM "$W"; wait "$W"; rc=$?
[ "$rc" = 0 ] && ok "D1 the worker exits 0" || bad "D1 rc=$rc $(cat "$T/d1.out")"
[ "$(newreq | grep -c '^POST /api/lane-runs/101/release 200 ')" = 1 ] && ok "D1 one release POST for row 101" || bad "D1 requests: $(newreq)"
[ "$(newreq | grep '^POST /api/lane-runs/101/release ' | sed 's/^POST [^ ]* 200 //' | jq -r .machine)" = m1-w2 ] \
  && ok "D1 the release names machine m1-w2" || bad "D1 release body: $(newreq | grep release)"
! grep -q '/report ' <<<"$(newreq)" && ok "D1 no report" || bad "D1 a report was posted: $(newreq | grep report)"
grep -q '^term 101$' "$T/term.txt" && ok "D1 the run got TERM" || bad "D1 term: $(cat "$T/term.txt")"
rm -f "$T/block"

# ============================================================================
echo "D2: LANE_RUN_BOX=fly-dedicated --machine m1-w3"
mark; row 102
LANE_RUN_BOX=fly-dedicated "$H/bin/lane-run-worker.sh" --once --machine m1-w3 > "$T/d2.out" 2>&1; rc=$?
C=$(newreq | grep '^POST /api/lane-runs/claim ' | head -1 | sed 's/^POST \/api\/lane-runs\/claim [0-9]* //')
[ "$rc" = 0 ] && ok "D2 the worker exits 0" || bad "D2 rc=$rc $(cat "$T/d2.out")"
[ "$(jq -r .box <<<"$C" 2>/dev/null)" = fly-dedicated ] && [ "$(jq -r .machine <<<"$C" 2>/dev/null)" = m1-w3 ] \
  && ok "D2 the claim body has box fly-dedicated and machine m1-w3" || bad "D2 claim body: $C"
R=$(newreq | grep '^POST /api/lane-runs/102/report ' | sed 's/^POST [^ ]* 200 //')
[ "$(jq -r .rc <<<"$R" 2>/dev/null)" = 0 ] && [ "$(jq -r .machine <<<"$R" 2>/dev/null)" = m1-w3 ] \
  && ok "D2 row 102 reported rc 0 as m1-w3" || bad "D2 report: $R; $(newreq)"

# ============================================================================
echo "D3: --box beats LANE_RUN_BOX"
mark
LANE_RUN_BOX=other-box "$H/bin/lane-run-worker.sh" --once --box fly-dedicated --machine m1-w4 > "$T/d3.out" 2>&1; rc=$?
C=$(newreq | grep '^POST /api/lane-runs/claim ' | head -1 | sed 's/^POST \/api\/lane-runs\/claim [0-9]* //')
[ "$rc" = 0 ] && [ "$(jq -r .box <<<"$C" 2>/dev/null)" = fly-dedicated ] && ok "D3 the flag wins" || bad "D3 rc $rc claim $C"

# ============================================================================
echo "D4: --box alone: the machine id is the box name"
mark
"$H/bin/lane-run-worker.sh" --once --box fly-dedicated > "$T/d4.out" 2>&1; rc=$?
C=$(newreq | grep '^POST /api/lane-runs/claim ' | head -1 | sed 's/^POST \/api\/lane-runs\/claim [0-9]* //')
[ "$rc" = 0 ] && [ "$(jq -r .machine <<<"$C" 2>/dev/null)" = fly-dedicated ] && ok "D4 machine = fly-dedicated" || bad "D4 rc $rc claim $C"

# ============================================================================
echo "D5: an answer without box is released, the worker exits 1"
: > "$T/start.txt"; mark; row 103 nobox
"$H/bin/lane-run-worker.sh" --once --box fly-dedicated --machine m1-w2 > "$T/d5.out" 2>&1; rc=$?
[ "$rc" = 1 ] && ok "D5 exit 1" || bad "D5 rc=$rc $(cat "$T/d5.out")"
[ "$(newreq | grep -c '^POST /api/lane-runs/103/release 200 ')" = 1 ] && ok "D5 one release POST for row 103" || bad "D5 requests: $(newreq)"
[ ! -s "$T/start.txt" ] && ! grep -q '/report ' <<<"$(newreq)" && ok "D5 not run, not reported" || bad "D5 ran: $(cat "$T/start.txt")"
grep -q 'm1-w2: claim answer for --box fly-dedicated does not name the box' "$WLOG" && ok "D5 the log names the box rule" || bad "D5 log: $(tail -2 "$WLOG")"

# ============================================================================
echo "D6: a bad LANE_RUN_BOX"
mark
LANE_RUN_BOX='Bad/Name' "$H/bin/lane-run-worker.sh" --once --machine m1-w2 > "$T/d6.out" 2>&1; rc=$?
[ "$rc" = 2 ] && [ -z "$(newreq | grep claim)" ] && ok "D6 exit 2, no claim" || bad "D6 rc $rc: $(cat "$T/d6.out")"

# ============================================================================
echo "D7: the shared code lock during a run, and the re-exec on a new commit"
LOCKF="$H/locks/lane-run-code.lock"
: > "$T/start.txt"; : > "$T/block"; printf 'aaaaaaaaaaaa\n' > "$H/HARNESS_COMMIT"; : > "$WLOG"; mark
row 104
"$H/bin/lane-run-worker.sh" --box fly-dedicated --machine m1-w5 > "$T/d7.out" 2>&1 & W=$!
WAITFOR '[ -s "$T/start.txt" ]' || bad "D7 setup: the run never started: $(cat "$T/d7.out")"
flock -n -x "$LOCKF" true; frc=$?
[ "$frc" = 1 ] && ok "D7 during the run an exclusive flock -n on the code lock fails" || bad "D7 flock rc=$frc"
printf 'bbbbbbbbbbbb\n' > "$H/HARNESS_COMMIT"
rm -f "$T/block"
WAITFOR 'grep -q "HARNESS_COMMIT changed under this loop; re-exec" "$WLOG"' || bad "D7 no re-exec line: $(cat "$WLOG")"
grep -q 'run 104 blocked-resolver/p1 rc 0: reported' "$WLOG" && ok "D7 the run was reported before the re-exec" || bad "D7 log: $(cat "$WLOG")"
[ "$(grep -n 'reported\|re-exec' "$WLOG" | cut -d: -f1 | tr '\n' ' ')" = "$(grep -n 'reported' "$WLOG" | cut -d: -f1) $(grep -n 're-exec' "$WLOG" | cut -d: -f1) " ] \
  && ok "D7 the re-exec comes after the report" || bad "D7 order: $(cat "$WLOG")"
kill -0 "$W" 2>/dev/null && ok "D7 the loop lives on as the same pid (exec)" || bad "D7 the loop is gone"
# The new process is up once it sends its first claim (the queue is empty: 204).
WAITFOR '[ "$(newreq | grep -c "^POST /api/lane-runs/claim 204 ")" -ge 1 ]' || bad "D7 the re-exec'd loop sent no claim"
WAITFOR 'flock -n -x "$LOCKF" true' 30 && ok "D7 after the run the code lock is free" || bad "D7 the lock is still held"
[ "$(grep -c 're-exec' "$WLOG")" = 1 ] && ok "D7 one re-exec (the new process reads the new commit)" || bad "D7 re-execs: $(grep -c 're-exec' "$WLOG")"
kill -TERM "$W"; wait "$W"; rc=$?
[ "$rc" = 0 ] && ok "D7 TERM on the idle loop exits 0" || bad "D7 rc=$rc"
rm -f "$H/HARNESS_COMMIT"

# ============================================================================
echo "D8: the code sync is skipped while another loop holds the lock"
: > "$WLOG"; scratch_rm "$H/state/lane-run-code"
# "Another loop": this shell holds the lock shared on fd 7.
exec 7>>"$LOCKF"; flock -s 7
flock -n -x "$LOCKF" true && bad "D8 setup: the hold did not take the lock"
LANE_RUN_CODE_SYNC=1 LANE_RUN_CODE_URL="file://$T/no-such-repo" "$H/bin/lane-run-worker.sh" --once --box fly-dedicated --machine m1-w6 > "$T/d8.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "D8 the loop exits 0" || bad "D8 rc=$rc $(cat "$T/d8.out")"
grep -q 'm1-w6: code sync skipped: a run is in flight on another loop' "$WLOG" && ok "D8 one 'code sync skipped' line" || bad "D8 log: $(cat "$WLOG")"
! grep -q 'code sync failed' "$WLOG" && [ ! -e "$H/state/lane-run-code/checked.at" ] && ok "D8 no sync was tried" || bad "D8 a sync ran: $(cat "$WLOG")"
flock -u 7; exec 7>&-
: > "$WLOG"
LANE_RUN_CODE_SYNC=1 LANE_RUN_CODE_URL="file://$T/no-such-repo" "$H/bin/lane-run-worker.sh" --once --box fly-dedicated --machine m1-w6 > "$T/d8b.out" 2>&1
grep -q 'code sync failed: git fetch of main failed' "$WLOG" && ! grep -q 'code sync skipped' "$WLOG" \
  && ok "D8 with the lock free the sync runs" || bad "D8 free: $(cat "$WLOG")"
flock -n -x "$LOCKF" true && ok "D8 the sync let go of the lock" || bad "D8 the lock is still held after the sync"

echo
echo "lane-run-dedicated-machine.bh-7716: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
