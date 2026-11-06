#!/bin/bash
# tests/hosted-board-tracer.bh-8918-test.sh — BH-8918: the hosted Board API end
# to end, over real curl. A scratch project hbtrace gets the three rows
# docs/HOSTED-BOARD.md names (fleet.conf column 4 /api/hosted-board/hbtrace,
# HBTRACE_API_BASE and HBTRACE_INTERNAL_API_TOKEN in env/hbtrace.env, settings
# tracker_adapter.hbtrace=board) against the REAL jobs worker on node:sqlite
# (tests/lib/hosted-board-worker.bh-8918.mjs). Then the harness's own readers
# read the board:
#   V-1 `bin/jobs-client.sh hosted-board-token issue hbtrace HB` issues the
#       token: one "issued" line, the token once, the two env lines. A refused
#       issue (a bad key prefix, a wrong HARNESS_SECRET) prints no token.
#   T-1 a todo ticket, verdict ready, waitingOn team: `bin/triage-gate.sh
#       hbtrace --buildable <id>` prints OK, after a 200 read of that ticket
#       (the gate is fail-open, so OK alone proves nothing); --buildable-strict
#       too.
#   T-2 verdict needs_clarification, waitingOn client: BLOCKED waitingOn=client.
#   T-3 `bin/board-conformance.sh hbtrace` rc 0, no gaps, from real GETs.
#   T-4 no request to /api/hosted-board/ carried HARNESS_SECRET.
#   T-5 a revoked token: the gate's read is refused (BLOCKED unreadable under
#       --buildable-strict).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/hosted-board-tracer.bh-8918-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/board-conformance-fixture.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/hosted-board-worker.bh-8918.mjs"
VERB="$REPO/bin/jobs-client.d/bh-8918-hosted-board-token.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ -n "$2" ] && [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
# The worker imports these git-ignored renders; a fresh checkout has none.
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }

# The scratch harness: the board-conformance fixture (its stub curl removed, so
# every request below is real curl), plus the gate, the fetcher and the client.
bc_fixture_setup || { echo "FAIL: fixture setup"; exit 1; }
rm -f "$T/stub/curl"
H="$HARNESS"
for L in bin/triage-gate.sh bin/board-fetch.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null || bad "setup: could not install $L"
done
mkdir -p "$H/bin/jobs-client.d" && cp "$VERB" "$H/bin/jobs-client.d/" || bad "setup: could not install the verb"
chmod +x "$H/bin/"*.sh 2>/dev/null

NOW=$(date -u +%s)  # determinism: ok the single anchor; the worker clock is pinned to it
SECRET=fixture-harness-secret
: > "$T/w.log"
node "$SRV" "$T/w.log" "$NOW" > "$T/w.port" 2> "$T/w.err" &
WPID=$!
trap 'kill $WPID 2>/dev/null; __scratch_exit_trap' EXIT
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port" 2>/dev/null)
if [ -z "$PORT" ]; then
  wait "$WPID"; rc=$?
  [ "$rc" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/w.err")"; exit 1
fi
BASE="http://127.0.0.1:$PORT"
export JOBS_URL="$BASE" BOX_NAME=fixture-hub JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
sql() { curl -sS -X POST "$BASE/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
client() { HARNESS_SECRET="${CLIENT_SECRET:-$SECRET}" bash "$H/bin/jobs-client.sh" "$@"; }

# ── V-1 the token verb ─────────────────────────────────────────────────────
OUT=$(client hosted-board-token issue hbtrace HB 2>"$T/v.err"); RC=$?
eq "V-1 issue rc 0 ($(cat "$T/v.err"))" "$RC" 0
TOKEN=$(sed -n 's/^HBTRACE_INTERNAL_API_TOKEN=//p' <<<"$OUT")
eq "V-1 the token line is printed once" "$(grep -c '^HBTRACE_INTERNAL_API_TOKEN=' <<<"$OUT")" 1
eq "V-1 the base line is the jobs worker" "$(sed -n 's/^HBTRACE_API_BASE=//p' <<<"$OUT")" "$BASE"
[[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] && ok "V-1 the token is 64 hex" || bad "V-1 the token is not 64 hex: [$TOKEN]"
TID=$(sed -n 's/^hosted-board-token: issued \([0-9a-f]*\) for hbtrace (system)$/\1/p' <<<"$OUT")
eq "V-1 the issued line names the token id (first 12 hex of the hash)" "$TID" "$(printf '%s' "$TOKEN" | sha256sum | cut -c1-12)"
ROW=$(sql "SELECT token_hash, project, role, actor_name FROM hosted_board_tokens WHERE token_id=?" "$TID")
eq "V-1 the worker holds the hash, never the token" "$(jq -r '.rows[0].token_hash' <<<"$ROW")" "$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)"
grep -qF "$TOKEN" "$T/w.log" "$H"/logs/* 2>/dev/null && bad "V-1 the token reached a log" || ok "V-1 the token is in no log"
eq "V-1 the board was created" "$(sql "SELECT key_prefix FROM hosted_board_boards WHERE project='hbtrace'" | jq -r '.rows[0].key_prefix')" HB
OUT=$(client hosted-board-token issue hbtrace hb 2>"$T/v.err"); RC=$?
[ "$RC" -ne 0 ] && ok "V-1 a bad key prefix is refused (rc $RC)" || bad "V-1 a bad key prefix answered rc 0"
grep -qE '^[A-Z_]+_INTERNAL_API_TOKEN=|issued' <<<"$OUT" && bad "V-1 a refused issue printed a token: $OUT" || ok "V-1 a refused issue prints no token"
OUT=$(CLIENT_SECRET=fixture-wrong-secret client hosted-board-token issue hbother HO 2>"$T/v.err"); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok "V-1 a wrong HARNESS_SECRET prints nothing (rc $RC)" || bad "V-1 wrong secret: rc $RC, out [$OUT]"

# The three rows.
printf 'hbtrace org/hbtrace - /api/hosted-board/hbtrace 0 hub\n' >> "$H/fleet.conf"
printf 'HBTRACE_API_BASE=%s\nHBTRACE_INTERNAL_API_TOKEN=%s\n' "$BASE" "$TOKEN" > "$H/env/hbtrace.env"
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('tracker_adapter.hbtrace','board','fixture','fixture','2026-11-02T00:00:00Z')" >/dev/null

# Two tickets, created through the API with the issued token.
mk() { curl -sS -X POST "$BASE/api/hosted-board/hbtrace/boards/product-board/tickets" \
  -H "Authorization: Bearer $TOKEN" -H 'User-Agent: curl/8' -d "$(jq -nc --arg t "$1" '{title:$t, type:"feature", labels:[]}')"; }
READY=$(mk "Ready ticket" | jq -r '.id')
CLAR=$(mk "Unclear ticket" | jq -r '.id')
[ -n "$READY" ] && [ "$READY" != null ] && [ -n "$CLAR" ] && [ "$CLAR" != null ] && ok "two tickets created" || bad "create failed: [$READY] [$CLAR]"
# No triage writer in this wave (plan A9): the verdicts are seeded in the DB.
sql "UPDATE hosted_board_tickets SET triage_verdict='ready' WHERE id=?" "$READY" >/dev/null
sql "UPDATE hosted_board_tickets SET triage_verdict='needs_clarification' WHERE id=?" "$CLAR" >/dev/null
TURN=$(curl -sS -X POST "$BASE/api/hosted-board/hbtrace/tickets/$CLAR/turn" -H "Authorization: Bearer $TOKEN" -d '{"to":"client"}' | jq -r '.waitingOn')
eq "T-2 setup: the turn route set waitingOn client" "$TURN" client

gate() { bash "$H/bin/triage-gate.sh" hbtrace "$@" 2>/dev/null; }

# ── T-1 ────────────────────────────────────────────────────────────────────
: > "$T/w.log"
eq "T-1 --buildable on a ready + team ticket" "$(gate --buildable "$READY")" OK
grep -qx "GET /api/hosted-board/hbtrace/tickets/$READY 200 secret=0" "$T/w.log" \
  && ok "T-1 the gate read the ticket from the worker (200)" || bad "T-1 no 200 read of the ticket: $(tr '\n' ';' < "$T/w.log")"
eq "T-1 --buildable-strict on the same ticket" "$(gate --buildable-strict "$READY")" OK

# ── T-2 ────────────────────────────────────────────────────────────────────
eq "T-2 --buildable on needs_clarification + client" "$(gate --buildable "$CLAR")" "BLOCKED waitingOn=client"
sql "UPDATE hosted_board_tickets SET waiting_on='team' WHERE id=?" "$CLAR" >/dev/null
eq "T-2 the verdict alone still blocks" "$(gate --buildable "$CLAR")" "BLOCKED triageVerdict=needs_clarification"

# ── T-3 ────────────────────────────────────────────────────────────────────
OUT=$(bash "$H/bin/board-conformance.sh" hbtrace 2>"$T/c.err"); RC=$?
eq "T-3 board-conformance rc ($(cat "$T/c.err"))" "$RC" 0
case "$OUT" in "hbtrace ok="*" missing=0 malformed=0 "*"gaps: ") ok "T-3 no gaps: $OUT" ;; *) bad "T-3 summary: [$OUT]" ;; esac
ST="$H/state/board-conformance/hbtrace.json"
eq "T-3 probe ok" "$(jq -r '.probe' "$ST" 2>/dev/null)" ok
eq "T-3 the dependencies capability is ok" "$(jq -r '.items["boards.capability.dependencies"].status' "$ST" 2>/dev/null)" ok
eq "T-3 ticket.dependencies is ok" "$(jq -r '.items["ticket.dependencies"].status' "$ST" 2>/dev/null)" ok
eq "T-3 ticket.reporter.userId is ok" "$(jq -r '.items["ticket.reporter.userId"].status' "$ST" 2>/dev/null)" ok
eq "T-3 internal.version is unverified, not a gap" "$(jq -r '.items["internal.version"].status' "$ST" 2>/dev/null)" unverified

# ── T-4 ────────────────────────────────────────────────────────────────────
: > "$T/all.log"; cat "$T/w.log" >> "$T/all.log"
N_SECRET=$(awk '$2 ~ /^\/api\/hosted-board\// && $4 == "secret=1"' "$T/all.log" | wc -l)
N_READS=$(awk '$2 ~ /^\/api\/hosted-board\// && $3 == "200" && $4 == "secret=0"' "$T/all.log" | wc -l)
eq "T-4 requests to /api/hosted-board/ with HARNESS_SECRET" "$N_SECRET" 0
[ "$N_READS" -ge 4 ] && ok "T-4 $N_READS token-authenticated 200 reads" || bad "T-4 only $N_READS token reads"

# ── T-5 ────────────────────────────────────────────────────────────────────
OUT=$(client hosted-board-token revoke hbtrace "$TID" 2>"$T/v.err"); RC=$?
eq "T-5 revoke rc ($(cat "$T/v.err"))" "$RC" 0
eq "T-5 --buildable-strict with a revoked token" "$(gate --buildable-strict "$READY")" "BLOCKED unreadable"

echo "hosted-board-tracer.bh-8918: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo FAIL; exit 1; }
echo PASS
