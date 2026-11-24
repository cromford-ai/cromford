#!/bin/bash
# tests/fix-round-hub-requeue.bh-9906-test.sh — BH-9906 H4: the hub's in-flight
# gate holds a fix_round_jobs row that the box re-offered after a timeout.
#
# A re-offer is POST /api/fix-rounds/requeue (worker/jobs/src/routes/fix-round-requeue.js):
# the SAME row goes back to `queued`, claimed_by cleared, attempt kept, a fresh
# enqueued_at, and record_in carries .timeout_requeues. To the hub it must read
# as one round in flight: no second row, no rung, no page, nothing spent.
#
# The tick is the REAL bin/blocked-resolver.sh on the blocked-resolver fixture
# with the hub identity set, against tests/lib/fake-fix-round-worker.bh-2530.py
# behind a `curl` shim (the set-up of tests/fix-round-hub-restart.bh-2530-test.sh).
#
# Cases:
#   H4   a re-offered row (attempt 1, .timeout_requeues) is held in flight
#   H4b  the same row, re-offered twice (attempt 2): still held, no page
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fix-round-hub-requeue.bh-9906-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq python3 pgrep; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh bin/lib/scheduler-conf.sh bin/lib/jobs/req.sh bin/lib/fix-round-queue.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || { echo "FAIL: closure of $lib"; exit 1; }
done
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1

# ---- the fake worker, the queue client, the real transport -------------------
FRW="$T/frw"; mkdir -p "$FRW" "$H/bin/lib/jobs" || exit 1
printf '#!/bin/bash\nFRW_STATE=%q exec python3 %q "$@"\n' "$FRW" "$DIR/tests/lib/fake-fix-round-worker.bh-2530.py" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl" || exit 1
{ printf 'JOBS_HARNESS=%q; HARNESS_SECRET=test-secret; JOBS_URL=https://jobs.invalid; JOBS_RETRIES=0\n' "$H"
  printf '. %q\n' "$H/bin/lib/jobs/req.sh"
  sed -n '/^job_ledger_row() {/,/^}/p;/^job_ledger_put() {/,/^}/p' "$DIR/bin/lib/jobs/jobs.sh"
} >> "$H/bin/jobs-client.sh" || exit 1
grep -q '^job_ledger_put() {' "$H/bin/jobs-client.sh" || { echo "FAIL: the ledger verbs did not install"; exit 1; }

# ---- stubs this suite owns ---------------------------------------------------
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent.txt"\nexit 0\n' "$T" > "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beat.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"
cat > "$T/fakebin/fake-ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/ssh.txt"
exit 255
EOF
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$T/fakebin/fake-ssh"
HUBENV=(HUB_BOX_NAME=hubx BOX_NAME=hubx)
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/fake-ssh" env "${HUBENV[@]}" ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
LOGF="$H/logs/blocked-resolver.log"
PR91="https://github.com/o/tproj/pull/91"
H91=$(osha ticket/TK-91)
CK=tproj-TK-91
RECP="$H/state/blocked-resolver/tproj/$CK.json"

RESET() {
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/state/heartbeat"
  scratch_rm "$H/tmp"
  scratch_rm "$FRW"; mkdir -p "$FRW"
  rm -f "$H/flags/blocked-resolver-observe" "$H/locks/"*.lock
  : > "$LOGF"; : > "$H/logs/ALERTS.log"
  : > "$T/agent.txt"; : > "$T/beat.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"
  : > "$T/ssh.txt"; : > "$T/lane-alert.txt"
  printf 'ticket/TK-91\n' > "$T/prbranch"; printf '%s' "$H91" > "$T/prhead"
  echo OPEN > "$T/prstate"
  printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
  BRENV=()
}
PARK91() { ROW "o/tproj#91" "head-not-reapproved" "$PR91"; }
ROWS() { cat "$FRW/rows.json" 2>/dev/null || echo "[]"; }
NROWS() { ROWS | jq 'length'; }
ROWF() { ROWS | jq -r "$1"; }
SEEDROW() { # SEEDROW <status> <cap_key> [result] [record_out] [updated_at] — one row straight into the store
  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  ROWS | jq -c --arg st "$1" --arg ck "$2" --arg res "${3:-}" --arg ro "${4:-}" --arg up "${5:-$now}" '
    . + [{id: ((map(.id) | max // 0) + 1), project:"tproj", cap_key:$ck, box:"box-tproj",
          args:["tproj","o-tproj-91","head-not-reapproved","x","-","TK-91"], record_in:null, hotfix:0,
          status:$st, attempt:(if $st == "queued" then 0 else 1 end),
          claimed_by:(if $st == "queued" then null else "box-tproj" end),
          result:(if $res == "" then null else $res end), record_out:(if $ro == "" then null else $ro end),
          enqueued_at:$up, updated_at:$up}]' > "$FRW/rows.tmp" && mv "$FRW/rows.tmp" "$FRW/rows.json"
}
SEEDREC() { # a hub record with one prior attempt, so "unchanged" is a real comparison
  mkdir -p "$(dirname "$RECP")"
  jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",
           attempts:[{at:"x",action:"mechanical",reason:"head-not-reapproved",detail:"seeded"}]}' > "$RECP"; }
BOXCLIENT() { # BOXCLIENT <cmd...> — the box's half, through the same client lib
  ( HARNESS="$H"; export PATH="$T/fakebin:$PATH"
    . "$H/bin/jobs-client.sh" && . "$H/bin/lib/fix-round-queue.sh" && "$@" ) 2>>"$T/run.log"; }
NATTEMPTS() { jq '(.attempts // []) | length' "$RECP" 2>/dev/null || echo 0; }
b64() { printf '%s' "$1" | base64 -w0; }

# REQUEUED <attempt> — the row as the requeue route leaves it: queued, not
# claimed, attempt kept, a fresh enqueued_at, record_in with .timeout_requeues.
REQUEUED() {
  local ri; ri=$(jq -c --argjson n "$1" '. + {timeout_requeues: [range($n) | {head:"0123abcd", kind:"verify", rc:0, last:"UNIT_EXIT: 124"}]}' "$RECP")
  SEEDROW queued "$CK"
  ROWS | jq -c --arg ri "$ri" --argjson n "$1" 'map(.attempt = $n | .record_in = $ri)' > "$FRW/rows.tmp" \
    && mv "$FRW/rows.tmp" "$FRW/rows.json"
}
h4() { # h4 <name> <attempt>
  RESET; PARK91; SEEDREC; BRENV=(BR_FIX_LANE_TIMEOUT=600)
  REQUEUED "$2"
  RUN
  grep -q "fix round in flight on box-tproj (queued since " "$LOGF" && ok \
    || bad "$1: a re-offered row is in flight (log: $(tail -4 "$LOGF"))"
  [ "$(NROWS)" = 1 ] && ok || bad "$1: a re-offered row gets no second row (rows: $(ROWS))"
  [ "$(ROWF '.[0].attempt')" = "$2" ] && [ "$(ROWF '.[0].status')" = queued ] && ok || bad "$1: the row is untouched (rows: $(ROWS))"
  grep -q 'EVENT resolver_rung' "$LOGF" && bad "$1: a re-offered row takes no rung ($(grep EVENT "$LOGF"))" || ok
  [ -s "$T/lane-alert.txt" ] && bad "$1: a re-offered row pages nothing ($(cat "$T/lane-alert.txt"))" || ok
  [ "$(NATTEMPTS)" = 1 ] && ok || bad "$1: nothing spent ($(cat "$RECP"))"
  [ -s "$T/agent.txt" ] && bad "$1: nothing runs on the hub ($(cat "$T/agent.txt"))" || ok
}
h4 H4 1
h4 H4b 2

echo "fix-round-hub-requeue.bh-9906: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
