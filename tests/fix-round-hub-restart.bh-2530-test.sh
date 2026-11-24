#!/bin/bash
# tests/fix-round-hub-restart.bh-2530-test.sh — BH-2674 (BH-2530.3): the hub
# enqueues a fix round as a fix_round_jobs row for the owning box and adopts
# the row's result on a later tick. No ssh hop, and nothing the hub holds in
# memory, tmp/ or locks/ describes the round, so it survives a hub restart.
#
# Every tick is the REAL bin/blocked-resolver.sh on the blocked-resolver
# fixture (tests/lib/fixture-harness.sh) with the hub identity set
# (HUB_BOX_NAME=BOX_NAME=hubx; tproj is owned by box-tproj). The jobs worker is
# tests/lib/fake-fix-round-worker.bh-2530.py behind a `curl` shim: the fixture's
# jobs client gains the real transport (bin/lib/jobs/req.sh) and the real
# ledger verbs, and the lane sources the real bin/lib/fix-round-queue.sh. The
# box side of the round (claim, finish) is the same client lib driven here.
#
# Cases:
#   1-6  the restart walk: queue, restart, in flight, box finishes, adopt once
#   D1   a duplicate enqueue answer is logged as in flight, no second row
#   N1   a done row for ANOTHER cap key of the project is not adopted
#   N2   an adopted row is never re-acted
#   N3   a claimed row, hours stale, runs no rung and no second enqueue, and
#        pages ONCE as a stale claim (review F1: a dead box's claim is never
#        re-offered to another box, so without the page it waits forever)
#   N3b  a live claim, and a claim whose stamp does not parse, page nothing
#   L1   the queue lib missing on the hub pages once, keyed per project
#   N4   a done row whose record is another project's: hub record byte-identical
#   N5   a box-paused result is adopted with nothing spent, paged or closed
#   N6   the worker down at the gate: return 3, no enqueue, no rung
#   N7   the worker reads but refuses the write: NOT queued, nothing spent
#   A1   the adopt is not recorded (outage): no rung; the next tick takes it once
#   A2   the adopt answers 409 (another tick won it): no rung
#   C1   BR_FIX_SLOTS counts the remote open rows; the worker down fails open
#   U1   a row nobody claims past BR_FIX_LANE_TIMEOUT pages, keyed per park
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fix-round-hub-restart.bh-2530-test.sh
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
cp "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/heartbeat.sh" "$DIR/bin/lib/scheduler-conf.sh" "$H/bin/lib/" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1

# ---- the fake worker, the queue client, the real transport -------------------
FRW="$T/frw"; mkdir -p "$FRW" "$H/bin/lib/jobs" || exit 1
cp "$DIR/bin/lib/jobs/req.sh" "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/fix-round-queue.sh" "$H/bin/lib/" || exit 1
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

# ============================================================================
# 1-6. THE RESTART WALK
# ============================================================================
# ---- 1. tick 1: one queued row for the owning box, no ssh, no local round
RESET; PARK91
RUN
[ "$(NROWS)" = 1 ] && ok || bad "1: tick 1 must write exactly one row (rows: $(ROWS); log: $(tail -4 "$LOGF"))"
[ "$(ROWF '.[0].status')" = queued ] && ok || bad "1: the row is queued (got $(ROWF '.[0].status'))"
[ "$(ROWF '.[0].box')" = box-tproj ] && ok || bad "1: the row is addressed to the owning box (got $(ROWF '.[0].box'))"
[ "$(ROWF '.[0].cap_key')" = "$CK" ] && ok || bad "1: the row is keyed on the park's cap key (got $(ROWF '.[0].cap_key'))"
[ "$(ROWF '.[0].args | length')" = 6 ] && [ "$(ROWF '.[0].args[0]')" = tproj ] && [ "$(ROWF '.[0].args[5]')" = TK-91 ] && ok \
  || bad "1: the row carries the six --fix-here args (got $(ROWF '.[0].args'))"
[ "$(ROWF '.[0].record_in | fromjson | .project')" = tproj ] && ok || bad "1: record_in is the hub's record (got $(ROWF '.[0].record_in' | head -c 200))"
[ -s "$T/ssh.txt" ] && bad "1: the hub must not ssh anywhere ($(cat "$T/ssh.txt"))" || ok
[ -s "$T/agent.txt" ] && bad "1: nothing runs on the hub ($(cat "$T/agent.txt"))" || ok
pgrep -f "$H/bin/blocked-resolver.sh" >/dev/null && bad "1: no resolver process may outlive the tick ($(pgrep -af "$H/bin/blocked-resolver.sh"))" || ok
[ -n "$(ls -A "$H/state/blocked-resolver/rounds" 2>/dev/null)" ] && bad "1: the hub holds no local round row ($(ls "$H/state/blocked-resolver/rounds"))" || ok
grep -q "EVENT resolver_rung tproj/$CK .*rung 2 fix-round queued for box-tproj" "$LOGF" && ok \
  || bad "1: the enqueue is one resolver_rung event (log: $(tail -4 "$LOGF"))"
ID=$(ROWF '.[0].id')
grep -q "row $ID" "$LOGF" && ok || bad "1: the log names the row id $ID (log: $(tail -4 "$LOGF"))"

# ---- 2. the hub restarts: every process gone, tmp/ and locks/ wiped
pkill -f "$H/bin/blocked-resolver.sh" 2>/dev/null
scratch_rm "$H/tmp"; rm -f "$H/locks/"*.lock
: > "$LOGF"; : > "$T/beat.txt"

# ---- 3. tick 1b: the round is in flight, not enqueued twice, no rung
RUN
grep -q "fix round in flight on box-tproj (queued since " "$LOGF" && ok \
  || bad "3: tick 1b must say the round is in flight (log: $(tail -4 "$LOGF"))"
[ "$(NROWS)" = 1 ] && ok || bad "3: still exactly one row after the restart (rows: $(ROWS))"
grep -q 'EVENT resolver_rung' "$LOGF" && bad "3: an in-flight park takes no rung ($(grep EVENT "$LOGF"))" || ok
[ -s "$T/closed.txt" ] && bad "3: nothing closed" || ok

# ---- 4. the box claims and finishes: terminal, one attempt more
N0=$(NATTEMPTS)
BOXOUT=$(jq -c '.fixrounds = ((.fixrounds // 0) + 1) | .from_box = "box-tproj"
  | .attempts = ((.attempts // []) + [{at:"y",action:"fix-round",reason:"head-not-reapproved",detail:"agent rc=1, verify rc=0 — no verified commit"}])' \
  <<<"$(ROWF '.[0].record_in')")
CLAIMED=$(BOXCLIENT fix_round_claim box-tproj)
[ "$(jq -r .id <<<"$CLAIMED" 2>/dev/null)" = "$ID" ] && ok || bad "4: the box claims row $ID (got $CLAIMED)"
BOXCLIENT fix_round_finish "$ID" box-tproj terminal "$BOXOUT" && ok || bad "4: the box's finish is taken"
[ "$(ROWF '.[0].status')" = done ] && ok || bad "4: the row is done (got $(ROWF '.[0].status'))"

# ---- 5. tick 2 adopts it: the record grows, the terminal runs once
RUN
# The box's fix-round attempt is in (the terminal then appends its own rebuild).
[ "$(jq '[.attempts[] | select(.action == "fix-round")] | length' "$RECP" 2>/dev/null)" = 1 ] \
  && [ "$(jq '.fixrounds' "$RECP" 2>/dev/null)" = 1 ] && [ "$(NATTEMPTS)" -gt "$N0" ] && ok \
  || bad "5: the hub record gains the box's attempt ($N0 -> $(NATTEMPTS): $(jq -c '.attempts' "$RECP" 2>/dev/null); log: $(tail -5 "$LOGF"))"
[ "$(jq -r .from_box "$RECP" 2>/dev/null)" = box-tproj ] && ok || bad "5: the hub adopted the box's record"
[ "$(grep -c . "$T/closed.txt")" = 1 ] && ok || bad "5: the terminal closes the PR once (closed: $(cat "$T/closed.txt"))"
grep -q 'TK-91' "$T/queue.txt" && ok || bad "5: the terminal enqueues the rebuild (queue: $(cat "$T/queue.txt"))"
[ "$(ROWF '.[0].status')" = adopted ] && ok || bad "5: the row is adopted (got $(ROWF '.[0].status'))"
[ -s "$T/ssh.txt" ] && bad "5: still no ssh ($(cat "$T/ssh.txt"))" || ok

# ---- 6. tick 3: nothing is taken twice
RUN
[ "$(grep -c . "$T/closed.txt")" = 1 ] && ok || bad "6: the close is not repeated (closed: $(cat "$T/closed.txt"))"
[ "$(NROWS)" = 1 ] && ok || bad "6: no new row after the adopted one (rows: $(ROWS | jq -c 'map({id,status,cap_key})'))"

# ============================================================================
# D1. A DUPLICATE ANSWER: a row the gate did not see (two overlapping ticks)
# ============================================================================
RESET; PARK91
# br_fix_remote driven on its own against a row that already exists: the gate
# in br_one would have seen it, and this is the window where it did not.
SEEDROW queued "$CK"
( HARNESS="$H" FLEET_CONF="$H/fleet.conf"; export PATH="$T/fakebin:$PATH" "${HUBENV[@]}"
  LOG="$LOGF"; ST="$H/state/blocked-resolver"
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }; say() { echo "$(STAMP) $*" >> "$LOG"; }
  br_event() { say "EVENT $*"; }; br_load() { echo '{"project":"tproj","attempts":[]}'; }
  br_setup_blocked() { say "SETUP_BLOCKED $6"; }
  . "$H/bin/lib/hub-box.sh"; . "$H/bin/jobs-client.sh"; . "$H/bin/lib/fix-round-queue.sh"
  eval "$(awk '/^br_fix_remote\(\) \{/,/^}/' "$H/bin/blocked-resolver.sh")"
  br_fix_remote tproj o-tproj-91 head-not-reapproved "$PR91" - TK-91 "$CK" 0 ) 2>>"$T/run.log"
[ "$(NROWS)" = 1 ] && ok || bad "D1: a duplicate answer writes no second row (rows: $(ROWS))"
grep -q "already in flight on box-tproj" "$LOGF" && ok || bad "D1: the duplicate is logged as in flight (log: $(tail -3 "$LOGF"))"
grep -q 'EVENT resolver_rung' "$LOGF" && bad "D1: a duplicate is no rung ($(grep EVENT "$LOGF"))" || ok

# ============================================================================
# N1-N7. ADVERSARIAL NEGATIVES
# ============================================================================
# ---- N1. a done row for ANOTHER cap key of the same project is not adopted
RESET; PARK91; SEEDREC
SEEDROW done tproj-TK-92 terminal "$(jq -nc '{project:"tproj",rkey:"tproj-TK-92",fixrounds:1,attempts:[1,2,3]}')"
RUN
[ "$(ROWF '.[] | select(.cap_key == "tproj-TK-92") | .status')" = done ] && ok || bad "N1: TK-92's done row must not be adopted by TK-91's tick ($(ROWS))"
[ -s "$T/closed.txt" ] && bad "N1: another park's terminal must not close this PR ($(cat "$T/closed.txt"))" || ok
[ "$(NATTEMPTS)" = 1 ] && ok || bad "N1: this park's record is untouched ($(cat "$RECP"))"
[ "$(ROWF "[.[] | select(.cap_key == \"$CK\")] | length")" = 1 ] && ok || bad "N1: TK-91 gets its own queued row ($(ROWS))"

# ---- N2. an adopted row is never re-acted
RESET; PARK91; SEEDREC
SEEDROW adopted "$CK" terminal "$(jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:1,attempts:[1,2,3]}')"
RUN
[ -s "$T/closed.txt" ] && bad "N2: an adopted terminal must not run again ($(cat "$T/closed.txt"))" || ok
[ "$(NATTEMPTS)" = 1 ] && ok || bad "N2: an adopted record is not re-saved ($(cat "$RECP"))"
[ "$(ROWF '.[0].status')" = adopted ] && ok || bad "N2: the adopted row stays adopted"
[ "$(ROWF '[.[] | select(.status == "queued")] | length')" = 1 ] && ok || bad "N2: the park is offered a new round ($(ROWS))"

# ---- N3. a claimed row hours old: in flight, no rung, no second enqueue
RESET; PARK91; SEEDREC
SEEDROW claimed "$CK" "" "" "$(date -u -d '-5 hours' '+%Y-%m-%dT%H:%M:%SZ')"
RUN
grep -q 'fix round in flight on box-tproj (claimed since ' "$LOGF" && ok || bad "N3: a stale claim is still in flight on the hub (log: $(tail -3 "$LOGF"))"
[ "$(NROWS)" = 1 ] && ok || bad "N3: no second row ($(ROWS))"
grep -q 'EVENT resolver_rung' "$LOGF" && bad "N3: no rung" || ok
[ -s "$T/closed.txt" ] && bad "N3: nothing closed" || ok
# TEST CHANGE (review F1 at 0477c3a0): this used to assert NO page. The claim
# route re-offers a stale claimed row only to the box that holds it, so a dead
# or replaced box held the park forever, silently. Past BR_FIX_LANE_TIMEOUT +
# BR_FIX_HOP_MARGIN the claim now pages once; it is still not an UNCLAIMED page.
[ "$(grep -c -- "--id fix-round-stale-claim-tproj-$CK blocked-resolver" "$T/lane-alert.txt")" = 1 ] && ok \
  || bad "N3: a claim older than BR_FIX_LANE_TIMEOUT + BR_FIX_HOP_MARGIN pages once through lane-alert --id (alerts: $(cat "$T/lane-alert.txt"))"
# TEST-CHANGE (BH-9906): the bound is the box's round bound, BR_FIX_AGENT_TIMEOUT
# + BR_FIX_VERIFY_TIMEOUT + BR_FIX_HOP_MARGIN (3600 + 2700 + 300 = 6600 s);
# BR_FIX_LANE_TIMEOUT + BR_FIX_HOP_MARGIN is its fallback (the cases below).
grep -q 'claimed by box-tproj since .* (over 6600s' "$T/lane-alert.txt" && ok || bad "N3: the page names the box, the stamp and the bound ($(cat "$T/lane-alert.txt"))"
grep -q -- '--id fix-round-unclaimed-' "$T/lane-alert.txt" && bad "N3: a claimed row is never an unclaimed page ($(cat "$T/lane-alert.txt"))" || ok
# the bound is A + V + M, all three knobs; the fallback LANE + M when A is not a number
RESET; PARK91; SEEDREC; BRENV=(BR_FIX_AGENT_TIMEOUT=300 BR_FIX_VERIFY_TIMEOUT=300 BR_FIX_HOP_MARGIN=300)
SEEDROW claimed "$CK" "" "" "$(date -u -d '-20 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
RUN
grep -q -- "--id fix-round-stale-claim-tproj-$CK " "$T/lane-alert.txt" && ok || bad "N3: 1200s > 300+300+300 pages (alerts: $(cat "$T/lane-alert.txt"))"
RESET; PARK91; SEEDREC; BRENV=(BR_FIX_AGENT_TIMEOUT=300 BR_FIX_VERIFY_TIMEOUT=600 BR_FIX_HOP_MARGIN=600)
SEEDROW claimed "$CK" "" "" "$(date -u -d '-20 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
RUN
[ -s "$T/lane-alert.txt" ] && bad "N3: 1200s < 300+600+600 does not page yet ($(cat "$T/lane-alert.txt"))" || ok
RESET; PARK91; SEEDREC; BRENV=(BR_FIX_AGENT_TIMEOUT=junk BR_FIX_LANE_TIMEOUT=600 BR_FIX_HOP_MARGIN=300)
SEEDROW claimed "$CK" "" "" "$(date -u -d '-20 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
RUN
grep -q -- "--id fix-round-stale-claim-tproj-$CK " "$T/lane-alert.txt" && ok || bad "N3: 1200s > 600+300 pages (alerts: $(cat "$T/lane-alert.txt"))"
RESET; PARK91; SEEDREC; BRENV=(BR_FIX_AGENT_TIMEOUT=junk BR_FIX_LANE_TIMEOUT=600 BR_FIX_HOP_MARGIN=900)
SEEDROW claimed "$CK" "" "" "$(date -u -d '-20 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
RUN
[ -s "$T/lane-alert.txt" ] && bad "N3: 1200s < 600+900 does not page yet ($(cat "$T/lane-alert.txt"))" || ok

# ---- N3b. a live claim, and a claim stamp that does not parse, page nothing
RESET; PARK91; SEEDREC
SEEDROW claimed "$CK"
RUN
grep -q 'fix round in flight on box-tproj (claimed since ' "$LOGF" && ok || bad "N3b: a live claim is in flight (log: $(tail -3 "$LOGF"))"
[ -s "$T/lane-alert.txt" ] && bad "N3b: a live claim pages nothing ($(cat "$T/lane-alert.txt"))" || ok
RESET; PARK91; SEEDREC
SEEDROW claimed "$CK" "" "" "not-a-time"
RUN
[ -s "$T/lane-alert.txt" ] && bad "N3b: an unparseable claim stamp is never age 0 and never a page ($(cat "$T/lane-alert.txt"))" || ok
grep -q "updated_at 'not-a-time' does not parse" "$LOGF" && ok || bad "N3b: an unparseable claim stamp is said (log: $(tail -3 "$LOGF"))"
grep -q 'EVENT resolver_rung' "$LOGF" && bad "N3b: no rung" || ok

# ---- N4. a done row carrying ANOTHER project's record
RESET; PARK91; SEEDREC
BEFORE=$(cat "$RECP")
SEEDROW done "$CK" done "$(jq -nc '{project:"otherproj",rkey:"tproj-TK-91",fixrounds:5,attempts:[1,2,3,4]}')"
RUN
[ "$(cat "$RECP")" = "$BEFORE" ] && ok || bad "N4: the hub record must stay byte-identical ($(cat "$RECP"))"
grep -q 'not a record for tproj' "$LOGF" && ok || bad "N4: the refusal is logged (log: $(tail -3 "$LOGF"))"
[ -s "$T/closed.txt" ] && bad "N4: no terminal ($(cat "$T/closed.txt"))" || ok
[ "$(ROWF '.[0].status')" = adopted ] && ok || bad "N4: the row is still adopted, so the park is not stuck (got $(ROWF '.[0].status'))"

# ---- N5. a box-paused result: adopted, nothing spent, paged or closed
RESET; PARK91; SEEDREC
SEEDROW done "$CK" "box-paused $(b64 'all-off on box-tproj')"
RUN
[ "$(ROWF '.[0].status')" = adopted ] && ok || bad "N5: the row is adopted (got $(ROWF '.[0].status'))"
grep -q 'box-tproj is paused (all-off on box-tproj)' "$LOGF" && ok || bad "N5: the pause is said (log: $(tail -3 "$LOGF"))"
[ "$(NATTEMPTS)" = 1 ] && [ "$(jq -r '.fixrounds' "$RECP")" = 0 ] && ok || bad "N5: nothing spent ($(cat "$RECP"))"
[ -s "$T/lane-alert.txt" ] && bad "N5: nothing paged ($(cat "$T/lane-alert.txt"))" || ok
[ -s "$T/closed.txt" ] && bad "N5: nothing closed" || ok

# ---- N6. the worker down at the gate
RESET; PARK91; SEEDREC
touch "$FRW/down"
RUN
rm -f "$FRW/down"
grep -q 'fix-round queue unreadable, park held this tick' "$LOGF" && ok || bad "N6: the gate says it held (log: $(tail -3 "$LOGF"))"
[ "$(NROWS)" = 0 ] && ok || bad "N6: no row ($(ROWS))"
grep -q 'EVENT resolver_rung' "$LOGF" && bad "N6: no rung" || ok
[ "$(NATTEMPTS)" = 1 ] && ok || bad "N6: nothing spent"
[ -s "$T/ssh.txt" ] && bad "N6: no ssh fallback ($(cat "$T/ssh.txt"))" || ok

# ---- N7. the reads answer, the write does not: NOT queued, nothing spent
RESET; PARK91; SEEDREC
touch "$FRW/down.POST"
RUN
rm -f "$FRW/down.POST"
grep -q 'fix round NOT queued — jobs DB unreachable, re-offered next tick' "$LOGF" && ok || bad "N7: the failed enqueue is said (log: $(tail -3 "$LOGF"))"
[ "$(NROWS)" = 0 ] && ok || bad "N7: no row"
grep -q 'EVENT resolver_rung' "$LOGF" && bad "N7: a failed enqueue is no rung" || ok
[ "$(NATTEMPTS)" = 1 ] && [ "$(jq -r '.fixrounds' "$RECP")" = 0 ] && ok || bad "N7: nothing spent ($(cat "$RECP"))"
[ -s "$T/ssh.txt" ] && bad "N7: no ssh fallback" || ok

# ============================================================================
# A1-A2. NO RUNG WITHOUT THE ADOPT CAS
# ============================================================================
TERMREC=$(jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:1,rebuilds:0,mechanicals:0,outcome:"",
  attempts:[{at:"x",action:"mechanical",reason:"head-not-reapproved",detail:"seeded"},{at:"y",action:"fix-round",reason:"head-not-reapproved",detail:"no verified commit"}]}')
# ---- A1. the adopt write fails: the row stays done, nothing is closed
RESET; PARK91; SEEDREC
SEEDROW done "$CK" terminal "$TERMREC"
touch "$FRW/down.POST"
RUN
rm -f "$FRW/down.POST"
[ -s "$T/closed.txt" ] && bad "A1: an adopt that was not recorded takes no rung ($(cat "$T/closed.txt"))" || ok
[ "$(ROWF '.[0].status')" = done ] && ok || bad "A1: the row stays done (got $(ROWF '.[0].status'))"
grep -q "the adopt was not recorded — retried next tick, no rung taken" "$LOGF" && ok || bad "A1: the miss is said (log: $(tail -3 "$LOGF"))"
RUN
[ "$(grep -c . "$T/closed.txt")" = 1 ] && ok || bad "A1: the next tick adopts and takes the terminal once (closed: $(cat "$T/closed.txt"); log: $(tail -3 "$LOGF"))"
[ "$(jq '[.attempts[] | select(.action == "fix-round")] | length' "$RECP")" = 1 ] && ok \
  || bad "A1: the record re-save is idempotent, one fix-round attempt ($(jq -c .attempts "$RECP"))"
[ "$(ROWF '.[0].status')" = adopted ] && ok || bad "A1: adopted on the retry"

# ---- A2. the adopt answers 409: another tick already took the rung
RESET; PARK91; SEEDREC
SEEDROW done "$CK" terminal "$TERMREC"
touch "$FRW/adopt409"
RUN
rm -f "$FRW/adopt409"
[ -s "$T/closed.txt" ] && bad "A2: a lost adopt takes no rung ($(cat "$T/closed.txt"))" || ok
grep -q "was already adopted by another tick — nothing taken again" "$LOGF" && ok || bad "A2: the lost race is said (log: $(tail -3 "$LOGF"))"

# ============================================================================
# C1. THE SLOT CAP COUNTS THE FLEET'S OPEN ROWS
# ============================================================================
RESET; PARK91; SEEDREC; BRENV=(BR_FIX_SLOTS=2)
SEEDROW queued tproj-TK-7; SEEDROW claimed tproj-TK-8
RUN
grep -q "deferred: 2 of 2 slots busy" "$LOGF" && ok || bad "C1: two open remote rows fill two slots (log: $(tail -3 "$LOGF"))"
[ "$(ROWF "[.[] | select(.cap_key == \"$CK\")] | length")" = 0 ] && ok || bad "C1: a deferred park enqueues nothing ($(ROWS))"
RESET; PARK91; SEEDREC; BRENV=(BR_FIX_SLOTS=2)
touch "$FRW/down"
RUN
rm -f "$FRW/down"
grep -q 'open fix rounds unreadable — slot cap fails open this tick' "$LOGF" && ok || bad "C1: the outage is said once (log: $(tail -3 "$LOGF"))"
[ "$(NROWS)" = 0 ] && ok || bad "C1: the worker down enqueues nothing"

# ============================================================================
# U1. NOBODY CLAIMS IT: one page, keyed per park
# ============================================================================
RESET; PARK91; SEEDREC; BRENV=(BR_FIX_LANE_TIMEOUT=600)
SEEDROW queued "$CK" "" "" "$(date -u -d '-2 hours' '+%Y-%m-%dT%H:%M:%SZ')"
RUN; RUN
[ "$(grep -c -- "--id fix-round-unclaimed-tproj-$CK blocked-resolver" "$T/lane-alert.txt")" -ge 1 ] && ok \
  || bad "U1: an unclaimed row pages through lane-alert --id (alerts: $(cat "$T/lane-alert.txt"))"
[ "$(grep -v -c -- "--id fix-round-unclaimed-tproj-$CK " "$T/lane-alert.txt")" = 0 ] && ok \
  || bad "U1: every page carries the same id, so alert-state sends it once ($(cat "$T/lane-alert.txt"))"
grep -q 'bin/fix-round-claim.sh on box-tproj has not claimed it' "$T/lane-alert.txt" && ok || bad "U1: the page names the claimer and the box"
[ "$(NROWS)" = 1 ] && ok || bad "U1: still one row"
# not yet overdue: no page
RESET; PARK91; SEEDREC; BRENV=(BR_FIX_LANE_TIMEOUT=600)
SEEDROW queued "$CK"
RUN
[ -s "$T/lane-alert.txt" ] && bad "U1: a fresh queued row does not page ($(cat "$T/lane-alert.txt"))" || ok
# an enqueued_at that does not parse is never age 0 and never a page
RESET; PARK91; SEEDREC; BRENV=(BR_FIX_LANE_TIMEOUT=600)
SEEDROW queued "$CK" "" "" "not-a-time"
RUN
[ -s "$T/lane-alert.txt" ] && bad "U1: an unparseable stamp does not page" || ok
grep -q "enqueued_at 'not-a-time' does not parse" "$LOGF" && ok || bad "U1: an unparseable stamp is said (log: $(tail -3 "$LOGF"))"

# ============================================================================
# L1. THE QUEUE LIB IS NOT ON THE HUB: said every tick, paged once per project
# ============================================================================
RESET; PARK91; SEEDREC
mv "$H/bin/lib/fix-round-queue.sh" "$T/frq.off"
RUN; RUN
mv "$T/frq.off" "$H/bin/lib/fix-round-queue.sh"
grep -q 'fix round NOT queued — bin/lib/fix-round-queue.sh is not on this box' "$LOGF" && ok || bad "L1: the missing lib is said (log: $(tail -3 "$LOGF"))"
[ "$(grep -c -- "--id fix-round-queue-missing-tproj blocked-resolver" "$T/lane-alert.txt")" -ge 1 ] && ok \
  || bad "L1: the missing lib pages through lane-alert --id (alerts: $(cat "$T/lane-alert.txt"))"
[ "$(grep -v -c -- "--id fix-round-queue-missing-tproj " "$T/lane-alert.txt")" = 0 ] && ok \
  || bad "L1: every page carries the same id, so alert-state sends it once ($(cat "$T/lane-alert.txt"))"
[ "$(NROWS)" = 0 ] && ok || bad "L1: no row"
grep -q 'EVENT resolver_rung' "$LOGF" && bad "L1: no rung" || ok
[ "$(NATTEMPTS)" = 1 ] && ok || bad "L1: nothing spent ($(cat "$RECP"))"

echo "fix-round-hub-restart.bh-2530: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
