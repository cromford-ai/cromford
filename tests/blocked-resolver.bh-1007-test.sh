#!/bin/bash
# tests/blocked-resolver.bh-1007-test.sh — BH-1007. A product-board ticket list
# that carries number but no key must still resolve to a ticket id; a board that
# ANSWERS WITH A TICKET LIST but cannot resolve the ticket must stop retrying
# after MAX_REBUILDS misses and abandon; a board that answers with an error
# (401/403/5xx) is NOT an answer and must stay on the free transient retry.
#
# Section A extracts br_ticket_id and drives it with stubbed board/curl fixtures.
# Section B runs the real bin/blocked-resolver.sh end to end against a scratch
# harness, with a fly-pool project and a stubbed jobs client, and asserts the
# board-miss cap abandons after three identical misses — over the rebuild-retry
# rung, with the conductor row CLOSED after the first tick the way the real
# closed-without-merging sweep leaves it — and that an enqueue that lands
# afterwards clears the miss counter.
# Section C runs bin/stale-owed-tickets.sh with a stubbed board and asserts the
# harness key is <board keyPrefix>-<number> when .key is absent — and falls back
# to #<number>, never to the fleet.conf URL path, when the board has no prefix.
# Section D confirms a body that is not a ticket list — empty, a 401 error
# object, a 500 error object — is treated as transient and never bumps
# board_misses or abandons.
# Run from anywhere: tests/blocked-resolver.bh-1007-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "blocked-resolver.bh-1007-test: SKIPPED — jq is required"; exit 0; }

H="$T/h"
mkdir -p "$T/fakebin" "$H/bin"
# Every section sets PATH from ORIG_PATH, never from the previous section's
# PATH: Section C used to prepend its own bin/ on top of Section B's and left
# it there, so Section D's rewritten curl was shadowed and Section D resolved
# the ticket through Section C's fixture — passing for the wrong reason.
ORIG_PATH="$PATH"

# mk_curl <dest> <fixture-dir> — a curl stub close enough to real curl for both
# callers in this test: br_ticket_id asks for the STATUS
# (-o <file> -w '%{http_code}'), bin/stale-owed-tickets.sh still takes the body
# on stdout. Bodies and status come from files in <fixture-dir> so a section can
# change the board's answer without rewriting the stub.
mk_curl() {
  cat > "$1" <<INNER
#!/bin/bash
OUT=""; WANTCODE=0; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) OUT="\$2"; shift 2 ;;
    -w) WANTCODE=1; shift 2 ;;
    -H|-m) shift 2 ;;
    -*) shift ;;
    *) URL="\$1"; shift ;;
  esac
done
CODE=200
case "\$URL" in
  *"/boards/"*"/tickets"*) BODY=\$(cat "$2/tickets.body" 2>/dev/null); CODE=\$(cat "$2/tickets.code" 2>/dev/null || echo 200) ;;
  *"/boards"*)             BODY=\$(cat "$2/boards.body" 2>/dev/null) ;;
  *)                       BODY="" ;;
esac
if [ -n "\$OUT" ]; then printf '%s' "\$BODY" > "\$OUT"; else printf '%s\n' "\$BODY"; fi
[ "\$WANTCODE" = 1 ] && printf '%s' "\$CODE"
exit 0
INNER
  chmod +x "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
# Section A — br_ticket_id in-process against a stubbed board API.
# ═══════════════════════════════════════════════════════════════════════════
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the record functions moved out of the driver into bin/lib/br/record.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
awk '/^br_rkey\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$T/br-corpus.sh" > "$T/brlib.sh"
awk '/^br_cap_key\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$T/br-corpus.sh" >> "$T/brlib.sh"
awk '/^br_ticket_id\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$DIR/bin/blocked-resolver.sh" >> "$T/brlib.sh"
grep -q '^br_ticket_id()' "$T/brlib.sh" && ok || bad "A0: could not extract br_ticket_id"

# Fake fleet-conf returns a REAL-SHAPED board prefix (fleet.conf column 4 is the
# board API URL PATH — /api/board, /api/accounting/requests-board — never a
# ticket-key prefix) and a prod base.
cat > "$H/bin/fleet-conf.sh" <<'INNER'
#!/bin/bash
case "$2" in
  board_prefix) echo "/api/board" ;;
  prod) echo "https://api.example.com" ;;
  *) echo "-" ;;
esac
INNER
chmod +x "$H/bin/fleet-conf.sh"

printf '#!/bin/bash\necho token123\n' > "$H/bin/internal-token-for.sh"; chmod +x "$H/bin/internal-token-for.sh"

mkdir -p "$T/fa"
FA="$T/fa"
TID_TICKETS="$FA/tickets.body"
printf '[{"id":"b1"}]' > "$FA/boards.body"
printf '200' > "$FA/tickets.code"
mk_curl "$T/fakebin/curl" "$FA"
export PATH="$T/fakebin:$ORIG_PATH"

BR_TICKET_ID() { H="$H" bash -c '. "$0"; br_ticket_id "$@"' "$T/brlib.sh" "$@"; }

# A1: number-only payload resolves TK-1838 -> abc.
printf '%s' '[{"id":"abc","number":1838}]' > "$TID_TICKETS"
GOT=$(BR_TICKET_ID aproj TK-1838 -); RC=$?
[ "$GOT" = "abc" ] && ok || bad "A1: number-only list resolved to '$GOT' (rc=$RC)"

# A2: key-only payload still resolves TK-1838 -> def.
printf '%s' '[{"id":"def","key":"TK-1838"}]' > "$TID_TICKETS"
GOT=$(BR_TICKET_ID aproj TK-1838 -); RC=$?
[ "$GOT" = "def" ] && ok || bad "A2: key-only list resolved to '$GOT' (rc=$RC)"

# A3: mixed payload (both .key and .number) resolves by key first.
printf '%s' '[{"id":"ghi","key":"TK-1838","number":9999}]' > "$TID_TICKETS"
GOT=$(BR_TICKET_ID aproj TK-1838 -); RC=$?
[ "$GOT" = "ghi" ] && ok || bad "A3: mixed list resolved to '$GOT' (rc=$RC)"

# A4: number-only payload with wrong number returns empty and rc 2 (board answered, no match).
printf '%s' '[{"id":"jkl","number":9999}]' > "$TID_TICKETS"
GOT=$(BR_TICKET_ID aproj TK-1838 -); RC=$?
[ -z "$GOT" ] && [ "$RC" = 2 ] && ok || bad "A4: no-match list should return empty rc=2, got '$GOT' rc=$RC"

# A5: shape-tolerant {tickets:[...]} wrapper with number-only resolves.
printf '%s' '{"tickets":[{"id":"mno","number":1838}]}' > "$TID_TICKETS"
GOT=$(BR_TICKET_ID aproj TK-1838 -); RC=$?
[ "$GOT" = "mno" ] && ok || bad "A5: wrapped number-only list resolved to '$GOT' (rc=$RC)"

# A6: shape-tolerant wrapper, no match, rc 2.
printf '%s' '{"tickets":[{"id":"pqr","number":9999}]}' > "$TID_TICKETS"
GOT=$(BR_TICKET_ID aproj TK-1838 -); RC=$?
[ -z "$GOT" ] && [ "$RC" = 2 ] && ok || bad "A6: wrapped no-match list should return empty rc=2, got '$GOT' rc=$RC"

# A7: a 401 error OBJECT is valid JSON but is not the board answering. A rotated
# internal token must stay on the free transient retry (rc 1), never become the
# deterministic rc 2 that caps the ladder and abandons the park.
printf '%s' '{"error":"Unauthorized"}' > "$TID_TICKETS"; printf '401' > "$FA/tickets.code"
GOT=$(BR_TICKET_ID aproj TK-1838 -); RC=$?
[ -z "$GOT" ] && [ "$RC" = 1 ] && ok || bad "A7: 401 body should be transient rc=1, got '$GOT' rc=$RC"

# A8: a 500 that renders JSON is the same class.
printf '%s' '{"error":"Internal Server Error"}' > "$TID_TICKETS"; printf '500' > "$FA/tickets.code"
GOT=$(BR_TICKET_ID aproj TK-1838 -); RC=$?
[ -z "$GOT" ] && [ "$RC" = 1 ] && ok || bad "A8: 500 body should be transient rc=1, got '$GOT' rc=$RC"

# A9: HTTP 200 carrying an error object (not a ticket list) is still not an answer.
printf '%s' '{"error":"Forbidden"}' > "$TID_TICKETS"; printf '200' > "$FA/tickets.code"
GOT=$(BR_TICKET_ID aproj TK-1838 -); RC=$?
[ -z "$GOT" ] && [ "$RC" = 1 ] && ok || bad "A9: 200 non-list body should be transient rc=1, got '$GOT' rc=$RC"
printf '200' > "$FA/tickets.code"

# ═══════════════════════════════════════════════════════════════════════════
# Section B — end-to-end rebuild-fresh board-miss cap.
# ═══════════════════════════════════════════════════════════════════════════
RH="$T/rh"
RST="$RH/state/blocked-resolver"
RLOG="$RH/logs/blocked-resolver.log"
mkdir -p "$RH/bin/lib" "$RH/logs" "$RH/state" "$RH/flags" "$RH/locks" "$RH/env" \
         "$RH/builds" "$RH/state/merge-conductor" "$RH/state/build-queue/tproj" \
         "$T/rbin" "$T/rrepos" "$T/fb"
FB="$T/fb"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$RH/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy — without them the tick exits 1
# before writing any state and every assertion below reads as "no state" rather
# than as the behaviour it is asserting on. One helper, one edit when the split
# moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$RH" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$RH/bin/lib/"
# BH-783 (#1157): bin/blocked-resolver.sh now REQUIRES the REST contract — without
# bin/lib/gh-rest.sh the lane refuses to start rather than deciding on undefined
# reads, so the fixture must carry it or every assertion below reads as "no state".
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$RH/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh
# and hard-exits when a module is missing, so a fixture that copies only the
# shim gets a resolver that dies before it writes any state.
mkdir -p "$RH/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$RH/bin/lib/mc/"
chmod +x "$RH/bin/"*.sh
printf '#!/bin/bash\necho token123\n' > "$RH/bin/internal-token-for.sh"; chmod +x "$RH/bin/internal-token-for.sh"

# Product-board project, fly-pool (so br_ticket_id is exercised). Column 4 is the
# board API URL PATH, as on the real fleet.
printf 'tproj o/tproj https://api.example.com /api/board 2 box-tproj 100.0.0.9\n' > "$RH/fleet.conf"
: > "$RH/env/global.env"
: > "$RH/flags/fly-pool-tproj"

for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$RH/bin/$f"; chmod +x "$RH/bin/$f"
done

printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$RH/bin/lane-alert.sh"
chmod +x "$RH/bin/lane-alert.sh"

# jobs client records queue_put but always "succeeds"; the resolver should never
# reach queue_put for a board-miss ticket because br_enqueue_fresh refuses first.
cat > "$RH/bin/jobs-client.sh" <<INNER
queue_put() { printf 'queue_put %s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { cat "$T/queue-list.txt" 2>/dev/null; }
INNER
: > "$T/queue.txt"; : > "$T/queue-list.txt"

# gh answers OPEN for the PR; the branch carries the ticket key TK-1838.
# BH-783 (#1157): the decision reads, the comment and the close all travel as
# `gh api -i`, whose status-line envelope is answered once in
# tests/lib/gh-rest-stub.sh — a hand-rolled copy of it drifts and a drifted copy
# goes green by deferring. The non-REST arms stay for the reads that are still
# plain `gh`.
cat > "$T/rbin/gh" <<INNER
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"--json headRefName"*) cat "$T/prbranch" ;;
  *"--json title"*) cat "$T/prtitle" ;;
  *"--json state"*) cat "$T/prstate" ;;
  *"pr list"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
INNER
chmod +x "$T/rbin/gh"
# The fixtures tests/lib/gh-rest-stub.sh reads: an OPEN PR on ticket/TK-1838 whose
# head is the sha the conductor row carries, and no merged-PR search hits.
printf 'ticket/TK-1838' > "$T/prbranch"
printf 'TK-1838 fix the thing' > "$T/prtitle"
printf 'OPEN\n' > "$T/prstate"
printf 'abc123' > "$T/prhead"
: > "$T/mergedprs"

printf '#!/bin/bash\nexit 0\n' > "$T/rbin/flock"; chmod +x "$T/rbin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/rbin/br-ssh"
chmod +x "$T/rbin/br-ssh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"; : > "$T/ssh.txt"
export PATH="$T/rbin:$ORIG_PATH"
export GH_TOKEN=""

# Board API returns a number-only list that does NOT contain 1838.
printf '[{"id":"b1"}]' > "$FB/boards.body"
printf '200' > "$FB/tickets.code"
printf '%s' '[{"id":"other","number":9999,"title":"other ticket","status":"review","waitingOn":"team"}]' > "$FB/tickets.body"
mk_curl "$T/rbin/curl" "$FB"

RUN() { ( HARNESS="$RH" FLEET_CONF="$RH/fleet.conf" REPOS_ROOT="$T/rrepos" \
           BR_SSH="$T/rbin/br-ssh" \
           bash "$RH/bin/blocked-resolver.sh" tproj >>"$T/run.log" 2>>"$T/run.err" ) ; }

reset_b() {
  scratch_rm "$RST"
  scratch_rm "$RH/builds"; mkdir -p "$RH/builds"
  : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"; : > "$T/ssh.txt"; : > "$T/queue.txt"
  : > "$RLOG"
  # One parked PR in the conductor's own row shape. The reason maps to rebuild-fresh.
  printf 'o/tproj#9\tBLOCKED_HUMAN\t1758240000\tabc123\tabc123\t-\tmerge-failed-twice: gh pr merge refused\thttps://github.com/o/tproj/pull/9\n' \
    > "$RH/state/merge-conductor/pr-state.tsv"
}

reset_b
# THE CONDUCTOR'S CLOSED SWEEP IS PART OF THE SCENARIO (BH-1007, drain round 2).
# Rung 3 closes the PR and releases the hand-off BEFORE the enqueue, and
# bin/merge-conductor.sh's closed-without-merging sweep then moves the row to
# CLOSED on its next tick. From that moment br_from_conductor never offers the
# park again (it reads BLOCKED_HUMAN/RED_TWICE only), the queue has no row and
# the build record is superseded — the ONLY source left is br_from_rebuilds
# reading this state file, and the only rung it can offer is rebuild-retry.
#
# So the cap MUST be reached over that rung. Re-parking the row between ticks —
# what this section used to do — left the row BLOCKED_HUMAN, re-entered rung 3
# on every tick, and proved the cap over a re-park the real conductor never
# produces; the production re-offer path was never executed and a
# `rebuild-fresh-board-miss` that br_from_rebuilds refuses to re-offer passed
# the section green while the park was a silent orphan in production.
close_row() {
  printf 'o/tproj#9\tCLOSED\t1758240000\tabc123\tabc123\t-\tmerge-failed-twice: gh pr merge refused\thttps://github.com/o/tproj/pull/9\n' \
    > "$RH/state/merge-conductor/pr-state.tsv"
}
RUN; close_row; RUN; RUN

STJ=$(cat "$RST/tproj/tproj-TK-1838.json" 2>/dev/null)
[ -n "$STJ" ] && ok || bad "B1: resolver state file should exist"
[ "$(printf '%s' "$STJ" | jq -r '.outcome // ""')" = "ABANDONED" ] && ok \
  || bad "B2: outcome should be ABANDONED after cap, got '$(printf '%s' "$STJ" | jq -r '.outcome // ""')'"
[ "$(printf '%s' "$STJ" | jq -r '.board_misses // 0')" = "3" ] && ok \
  || bad "B3: board_misses should be 3, got '$(printf '%s' "$STJ" | jq -r '.board_misses // 0')'"
[ "$(grep -c 'board-miss' "$T/lane-alert.txt" 2>/dev/null || echo 0)" = "1" ] && ok \
  || bad "B4: lane-alert should contain exactly one board-miss line, got $(grep -c 'board-miss' "$T/lane-alert.txt" 2>/dev/null || echo 0)"
# B5: the misses after the first were counted by the RETRY rung, not by a
# re-entry of rung 3 — the attempt detail carries the retry label that only
# br_rebuild_retry writes. Without it the park is re-parked, not re-offered.
RTRY=$(printf '%s' "$STJ" | jq -r '[.attempts[]? | select(((.detail // "") | contains("enqueue retry")) and (.action // "") == "rebuild-fresh-board-miss")] | length' 2>/dev/null)
[ "${RTRY:-0}" -ge 1 ] && ok \
  || bad "B5: at least one board miss should come from the rebuild-retry rung (enqueue retry label), got ${RTRY:-0} — br_from_rebuilds is not re-offering a rebuild-fresh-board-miss park"

# B6/B7: a miss, then a board that CAN name the ticket. The retry rung must
# reach the enqueue and land a queue row, and an enqueue that landed spends both
# non-terminal counters — board_misses included. Carrying misses past a
# successful enqueue would abandon the next park on this cap key after a single
# miss, for a board that answered in between.
reset_b
printf '%s' '[{"id":"other","number":9999,"title":"other ticket","status":"review","waitingOn":"team"}]' > "$FB/tickets.body"
RUN
close_row
printf '%s' '[{"id":"tid1838","number":1838,"title":"the ticket","status":"review","waitingOn":"team"}]' > "$FB/tickets.body"
RUN
STJ=$(cat "$RST/tproj/tproj-TK-1838.json" 2>/dev/null)
QP=$(grep -c queue_put "$T/queue.txt" 2>/dev/null); QP=${QP:-0}
[ "$QP" -ge 1 ] && ok \
  || bad "B6: the retry rung should have enqueued once the board could name the ticket, got $QP queue_put lines"
[ "$(printf '%s' "$STJ" | jq -r '.board_misses // 0')" = "0" ] && ok \
  || bad "B7: an enqueue that landed should clear board_misses, got '$(printf '%s' "$STJ" | jq -r '.board_misses // 0')'"

# ═══════════════════════════════════════════════════════════════════════════
# Section C — stale-owed-tickets.sh derives the harness key from the BOARD's
# keyPrefix, never from fleet.conf's board API URL path.
# ═══════════════════════════════════════════════════════════════════════════
SH="$T/sh"
mkdir -p "$SH/bin" "$SH/logs" "$SH/state" "$SH/env" "$SH/flags" "$T/fc"
FC="$T/fc"
printf 'tproj o/tproj https://api.example.com /api/board 2 box-tproj 100.0.0.9\n' > "$SH/fleet.conf"

# Fake the project enumeration.
printf '#!/bin/bash\necho tproj\n' > "$SH/bin/fleet-projects-or-alert.sh"; chmod +x "$SH/bin/fleet-projects-or-alert.sh"
# board_prefix is the board API URL PATH on every real fleet.conf row
# (/api/board, /api/feature-board, /api/accounting/requests-board). The stub
# says so, so a key derived from it would be visibly wrong here.
cat > "$SH/bin/fleet-conf.sh" <<'INNER'
#!/bin/bash
case "$2" in
  board_prefix) echo "/api/board" ;;
  prod) echo "https://api.example.com" ;;
  *) echo "-" ;;
esac
INNER
chmod +x "$SH/bin/fleet-conf.sh"
printf '#!/bin/bash\necho token123\n' > "$SH/bin/internal-token-for.sh"; chmod +x "$SH/bin/internal-token-for.sh"

# Ticket is stale (4+ hours), review, waitingOn team, number 1838, no key —
# exactly the project-4 shape (its CARD_SELECT never selects `key`).
printf '%s' '[{"id":"abc","number":1838,"title":"stale ticket","status":"review","waitingOn":"team","lastActivityAt":"2026-01-01T00:00:00Z"}]' > "$FC/tickets.body"
printf '200' > "$FC/tickets.code"
# The board carries its own keyPrefix (project-4 Board.keyPrefix, default "AR").
printf '[{"id":"b1","keyPrefix":"TK"}]' > "$FC/boards.body"
mk_curl "$SH/bin/curl" "$FC"
export PATH="$SH/bin:$ORIG_PATH"

( HARNESS="$SH" FLEET_CONF="$SH/fleet.conf" bash "$DIR/bin/stale-owed-tickets.sh" >>"$T/stale.log" 2>&1 ) || true
GOT=$(jq -r '.tproj.tickets[0].key // ""' "$SH/state/stale-owed.json" 2>/dev/null)
[ "$GOT" = "TK-1838" ] && ok || bad "C1: stale key should be TK-1838, got '$GOT'"

# C2: a board with no keyPrefix keeps the short #<number> placeholder. It must
# NEVER become "/api/board-1838" — that lands in READY-QUEUE.log as a key triage
# cannot resolve, and changes the 24h cooldown key for every stale row at once.
printf '[{"id":"b1"}]' > "$FC/boards.body"
( HARNESS="$SH" FLEET_CONF="$SH/fleet.conf" bash "$DIR/bin/stale-owed-tickets.sh" >>"$T/stale.log" 2>&1 ) || true
GOT=$(jq -r '.tproj.tickets[0].key // ""' "$SH/state/stale-owed.json" 2>/dev/null)
[ "$GOT" = "#1838" ] && ok || bad "C2: keyPrefix-less board should fall back to #1838, got '$GOT'"

# ═══════════════════════════════════════════════════════════════════════════
# Section D — a body that is not a ticket list is transient: it must not bump
# board_misses and must not abandon. PATH goes back to $T/rbin so Section C's
# curl cannot answer for Section B's fixture.
# ═══════════════════════════════════════════════════════════════════════════
export PATH="$T/rbin:$ORIG_PATH"

# D1/D2: empty body, HTTP 200.
reset_b
printf '' > "$FB/tickets.body"; printf '200' > "$FB/tickets.code"
RUN
STJ=$(cat "$RST/tproj/tproj-TK-1838.json" 2>/dev/null)
[ "$(printf '%s' "$STJ" | jq -r '.board_misses // 0')" = "0" ] && ok \
  || bad "D1: empty curl body should leave board_misses at 0, got '$(printf '%s' "$STJ" | jq -r '.board_misses // 0')'"
[ "$(printf '%s' "$STJ" | jq -r '.outcome // ""')" != "ABANDONED" ] && ok \
  || bad "D2: empty curl body must not abandon"
# grep -c prints 0 and EXITS 1 on no match, so `|| echo 0` would make this "0\n0".
QP=$(grep -c queue_put "$T/queue.txt" 2>/dev/null); QP=${QP:-0}
[ "$QP" = "0" ] && ok \
  || bad "D3: transient miss must not enqueue a build (got $QP queue_put lines — Section C's curl is answering for Section B's fixture)"

# D4/D5: the /boards list still answers, the /tickets route 401s — the shape a
# rotated internal token (or a board-scoped 403) takes. Three ticks, the full
# MAX_REBUILDS window, the last two over the rebuild-retry rung: pre-fix this
# reached ABANDONED and paged.
reset_b
printf '%s' '{"error":"Unauthorized"}' > "$FB/tickets.body"; printf '401' > "$FB/tickets.code"
RUN; close_row; RUN; RUN
STJ=$(cat "$RST/tproj/tproj-TK-1838.json" 2>/dev/null)
[ "$(printf '%s' "$STJ" | jq -r '.board_misses // 0')" = "0" ] && ok \
  || bad "D4: a 401 body should leave board_misses at 0, got '$(printf '%s' "$STJ" | jq -r '.board_misses // 0')'"
[ "$(printf '%s' "$STJ" | jq -r '.outcome // ""')" != "ABANDONED" ] && ok \
  || bad "D5: a 401 body must not abandon the park"

# D6/D7: a 500 that renders JSON is the same class.
reset_b
printf '%s' '{"error":"Internal Server Error"}' > "$FB/tickets.body"; printf '500' > "$FB/tickets.code"
RUN; close_row; RUN; RUN
STJ=$(cat "$RST/tproj/tproj-TK-1838.json" 2>/dev/null)
[ "$(printf '%s' "$STJ" | jq -r '.board_misses // 0')" = "0" ] && ok \
  || bad "D6: a 500 body should leave board_misses at 0, got '$(printf '%s' "$STJ" | jq -r '.board_misses // 0')'"
[ "$(printf '%s' "$STJ" | jq -r '.outcome // ""')" != "ABANDONED" ] && ok \
  || bad "D7: a 500 body must not abandon the park"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi
echo "RESULT: $PASS passed, 0 failed"
exit 0
