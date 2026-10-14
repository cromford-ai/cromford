#!/bin/bash
# tests/jobs-client-ledger-verbs-test.sh — BH-397.2 ledger verbs in jobs-client.sh.
#
# Driven against the real bin/jobs-client.sh with a stubbed curl. Every claim is
# about a request that was made, a file that was written, or a return code.
#
# THE FIXTURES ARE THE WORKER'S REAL ANSWERS. Every canned payload below is the
# shape worker/jobs/src/index.js actually serves on main (appendLines/listLines
# at 671/710, the routes at 3116-3232) — `{rows,truncated,as_of}` for the two
# append logs, `{repo,pr_owners,as_of}` for pr-owners, `{topics,as_of}` for the
# topic map. A fixture the production pipeline cannot generate proves nothing.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/state" "$T/state/pr-owners" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# curl shim: records METHOD URL BODY, then returns $CURL_RESP body + status.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -sS|-S|-s) shift;;
    *) URL="$1"; shift;;
  esac
done
[ -n "${REQ_LOG:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
[ "${CURL_MODE:-ok}" = down ] && exit 7
[ "$METHOD" = PUT ] && [ -n "${CURL_PUT_RESP:-}" ] && [ -r "$CURL_PUT_RESP" ] && { cat "$CURL_PUT_RESP"; exit 0; }
[ -n "${CURL_RESP:-}" ] && [ -r "$CURL_RESP" ] && { cat "$CURL_RESP"; exit 0; }
printf '{"ok":true}\n200\n'
SH
chmod +x "$T/fakebin/curl"

client() { # client <verb> [args...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.test JOBS_BOX=testbox REQ_LOG="$T/req.log" \
           CURL_RESP="${CURL_RESP:-}" CURL_PUT_RESP="${CURL_PUT_RESP:-}" CURL_MODE="${CURL_MODE:-ok}"
    bash "$T/bin/jobs-client.sh" "$@" )
}
lastreq() { tail -1 "$T/req.log" 2>/dev/null; }
clearlog() { : > "$T/req.log"; }

printf '{"error":"boom"}\n500\n' > "$T/err500.json"
printf '{"ok":true}\n200\n' > "$T/ok.json"

# --- 1. pr_owners_put --------------------------------------------------------
STATEF="$T/state/pr-owners/example-org_testproj.json"
cat > "$STATEF" <<'J'
{"generated_at":"2026-09-10T00:00:00Z","prs":{"101":{"state":"OWNED","owner":"box1"},"102":{"state":"EXTERNAL","owner":"box2"}}}
J
printf '{"pr_owners":2,"tombstoned":0,"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/put-ok.json"
clearlog
OUT=$(CURL_RESP="$T/put-ok.json" client pr-owners-put example-org/testproj testproj "$STATEF"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "pr_owners_put rc=$RC"
REQ=$(lastreq)
grep -q 'PUT https://jobs.test/api/pr-owners' <<<"$REQ" && ok || bad "pr_owners_put did not PUT /api/pr-owners: $REQ"
BODY=$(echo "$REQ" | cut -d' ' -f3-)
printf '%s' "$BODY" | jq -e '.complete == true' >/dev/null 2>&1 && ok || bad "pr_owners_put body missing complete=true"
printf '%s' "$BODY" | jq -e '.repo == "example-org/testproj"' >/dev/null 2>&1 && ok || bad "pr_owners_put body missing repo"
printf '%s' "$BODY" | jq -e '.project == "testproj"' >/dev/null 2>&1 && ok || bad "pr_owners_put body missing project"
printf '%s' "$BODY" | jq -e '.rows | length == 2' >/dev/null 2>&1 && ok || bad "pr_owners_put rows length"
printf '%s' "$BODY" | jq -e '.rows | map(.number | type) | all(. == "number")' >/dev/null 2>&1 \
  && ok || bad "pr_owners_put .number is not a JSON number: $BODY"
printf '%s' "$BODY" | jq -e '.rows[] | select(.number == 101) | .state == "OWNED"' >/dev/null 2>&1 && ok || bad "pr_owners_put row 101 fields"
printf '%s' "$BODY" | jq -e '.rows[] | select(.number == 102) | .owner == "box2"' >/dev/null 2>&1 && ok || bad "pr_owners_put row 102 fields"

# missing state file -> rc 1 and NO request. An absent file must never become a
# complete:true wipe of D1.
clearlog
client pr-owners-put example-org/testproj testproj "$T/state/pr-owners/nope.json" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok || bad "pr_owners_put missing file rc=$RC (want 1)"
[ ! -s "$T/req.log" ] && ok || bad "pr_owners_put missing file made a request"

# shim answering 500 -> rc 1, nothing printed (a 500 is never "written")
clearlog
OUT=$(CURL_RESP="$T/err500.json" client pr-owners-put example-org/testproj testproj "$STATEF" 2>/dev/null); RC=$?
[ "$RC" -eq 1 ] && ok || bad "pr_owners_put 500 rc=$RC (want 1)"
[ -z "$OUT" ] && ok || bad "pr_owners_put 500 printed: $OUT"

# an EMPTY .prs map still PUTs, with complete:true and rows:[] — that is how D1
# learns the set is empty. rc 2 with no request would leave stale OWNED rows.
EMPTYF="$T/state/pr-owners/example-org_emptyproj.json"
printf '%s' '{"generated_at":"2026-09-10T00:00:00Z","prs":{}}' > "$EMPTYF"
clearlog
OUT=$(CURL_RESP="$T/put-ok.json" client pr-owners-put example-org/emptyproj emptyproj "$EMPTYF"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "pr_owners_put empty map rc=$RC (want 0)"
REQ=$(lastreq)
grep -q 'PUT https://jobs.test/api/pr-owners' <<<"$REQ" && ok || bad "pr_owners_put empty map sent no request: $REQ"
BODY=$(echo "$REQ" | cut -d' ' -f3-)
printf '%s' "$BODY" | jq -e '.complete == true and (.rows | type == "array" and length == 0)' >/dev/null 2>&1 \
  && ok || bad "pr_owners_put empty map body: $BODY"

# --- 2. pr_owners_list --------------------------------------------------------
# The worker's real GET answer: {repo, pr_owners:[rows], as_of}.
printf '{"repo":"example-org/testproj","pr_owners":[{"number":101,"state":"OWNED","since":"2026-09-10T00:00:00Z","updated_at":"2026-09-10T00:00:00Z"},{"number":102,"state":"PARKED","since":"2026-09-10T00:00:01Z","updated_at":"2026-09-10T00:00:01Z"}],"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/two.json"
clearlog
OUT=$(CURL_RESP="$T/two.json" client pr-owners-list example-org/testproj); RC=$?
[ "$RC" -eq 0 ] && ok || bad "pr_owners_list two rows rc=$RC"
printf '%s' "$OUT" | jq -e '.prs["101"].updated_at == "2026-09-10T00:00:00Z"' >/dev/null 2>&1 && ok || bad "pr_owners_list .prs[101].updated_at missing: $OUT"
printf '%s' "$OUT" | jq -e '.prs["102"].state == "PARKED"' >/dev/null 2>&1 && ok || bad "pr_owners_list row 102 state"
# generated_at is the ROUTE's as_of, not this box's clock: the overlay rule
# ("row wins when updated_at >= file.generated_at") compares D1 stamps, and a
# local clock makes that comparison meaningless across boxes.
printf '%s' "$OUT" | jq -e '.generated_at == "2026-09-16T12:00:00Z"' >/dev/null 2>&1 \
  && ok || bad "pr_owners_list generated_at is not the route's as_of: $OUT"
REQ=$(lastreq)
[ "$REQ" = "GET https://jobs.test/api/pr-owners?repo=example-org%2Ftestproj " ] \
  && ok || bad "pr_owners_list GET path is not the bare repo query: [$REQ]"

# a payload with no as_of falls back to the local clock rather than printing null
printf '{"pr_owners":[{"number":101,"state":"OWNED","updated_at":"2026-09-10T00:00:00Z"}]}\n200\n' > "$T/no-asof.json"
OUT=$(CURL_RESP="$T/no-asof.json" client pr-owners-list example-org/testproj); RC=$?
[ "$RC" -eq 0 ] && ok || bad "pr_owners_list no-as_of rc=$RC"
printf '%s' "$OUT" | jq -e '.generated_at | type == "string" and test("^20[0-9][0-9]-")' >/dev/null 2>&1 \
  && ok || bad "pr_owners_list no-as_of generated_at: $OUT"

OUT=$(CURL_RESP="$T/ok.json" client pr-owners-list example-org/testproj 2>/dev/null); RC=$?
[ "$RC" -eq 2 ] && ok || bad "pr_owners_list {ok:true} rc=$RC"
[ -z "$(printf '%s' "$OUT" | tr -d '\n')" ] && ok || bad "pr_owners_list printed on a miss: $OUT"

printf '{"repo":"example-org/testproj","pr_owners":[],"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/empty.json"
OUT=$(CURL_RESP="$T/empty.json" client pr-owners-list example-org/testproj 2>/dev/null); RC=$?
[ "$RC" -eq 2 ] && ok || bad "pr_owners_list empty array rc=$RC"

OUT=$(CURL_MODE=down CURL_RESP="" client pr-owners-list example-org/testproj 2>/dev/null); RC=$?
[ "$RC" -eq 1 ] && ok || bad "pr_owners_list curl down rc=$RC"

# --- 3. batch decisions / findings put + log_rehydrate -----------------------
ROWS="$T/rows.json"
printf '[{"stamp":"2026-09-10 00:00:00Z","project":"testproj","gate":"scope","ticket":"TK-1","line":"[testproj] gate=scope :: TK-1 :: route :: reason1"}]\n' > "$ROWS"
printf '{"inserted":1,"ignored":0,"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/batch-ok.json"

clearlog
OUT=$(CURL_RESP="$T/batch-ok.json" client decisions-put testproj "$ROWS"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "decisions_put rc=$RC"
[ "$(grep -c 'POST https://jobs.test/api/decisions' "$T/req.log")" -eq 1 ] \
  && ok || bad "decisions_put did not POST /api/decisions exactly once: $(cat "$T/req.log")"
BODY=$(lastreq | cut -d' ' -f3-)
printf '%s' "$BODY" | jq -e '.rows | length == 1' >/dev/null 2>&1 && ok || bad "decisions_put rows missing"
printf '%s' "$BODY" | jq -e '.project == "testproj"' >/dev/null 2>&1 && ok || bad "decisions_put project missing: $BODY"
printf '%s' "$BODY" | jq -e '.actor == "testbox"' >/dev/null 2>&1 && ok || bad "decisions_put actor missing: $BODY"

clearlog
OUT=$(CURL_RESP="$T/batch-ok.json" client findings-put testproj "$ROWS"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "findings_put rc=$RC"
[ "$(grep -c 'POST https://jobs.test/api/findings' "$T/req.log")" -eq 1 ] \
  && ok || bad "findings_put did not POST /api/findings exactly once: $(cat "$T/req.log")"

# absent / zero-byte / [] are the SAME input — "no lines" — and get the same
# answer: rc 2 and no POST. A zero-byte file answering rc 1 would look like an
# outage to every caller.
clearlog
client decisions-put testproj "$T/nope.json" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "decisions_put absent file rc=$RC (want 2)"
[ ! -s "$T/req.log" ] && ok || bad "decisions_put absent file made a request"

: > "$T/zero.json"
clearlog
client decisions-put testproj "$T/zero.json" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "decisions_put zero-byte file rc=$RC (want 2)"
[ ! -s "$T/req.log" ] && ok || bad "decisions_put zero-byte file made a request"

printf '[]\n' > "$T/emptyrows.json"
clearlog
client decisions-put testproj "$T/emptyrows.json" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "decisions_put [] rc=$RC (want 2)"
[ ! -s "$T/req.log" ] && ok || bad "decisions_put [] made a request"

# a rows file that parses but is not an array is BAD INPUT, not "no rows"
printf '{"x":1}\n' > "$T/notarray.json"
clearlog
client decisions-put testproj "$T/notarray.json" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok || bad "decisions_put non-array rc=$RC (want 1)"
[ ! -s "$T/req.log" ] && ok || bad "decisions_put non-array made a request"

clearlog
OUT=$(CURL_RESP="$T/err500.json" client decisions-put testproj "$ROWS" 2>/dev/null); RC=$?
[ "$RC" -eq 1 ] && ok || bad "decisions_put 500 rc=$RC (want 1)"
[ -z "$OUT" ] && ok || bad "decisions_put 500 printed: $OUT"

# log_rehydrate decisions: absent file + two rows -> atomic write.
# The fixture is listLines' real answer: {rows:[{stamp,line,...}],truncated,as_of}.
rm -f "$T/logs/decisions.log"
printf '{"rows":[{"id":1,"stamp":"2026-09-10 00:00:00Z","project":"testproj","line":"[testproj] gate=scope :: TK-1 :: route :: reason1"},{"id":2,"stamp":"2026-09-10 00:00:01Z","project":"testproj","line":"[testproj] gate=scope :: TK-2 :: park :: reason2"}],"truncated":false,"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/rehydrate-two.json"
clearlog
: > "$T/logs/jobs-client.log"
CURL_RESP="$T/rehydrate-two.json" client log-rehydrate decisions "$T/logs/decisions.log"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "log_rehydrate rc=$RC"
[ -f "$T/logs/decisions.log" ] && ok || bad "log_rehydrate did not create file"
cat > "$T/expected.log" <<'EXP'
2026-09-10 00:00:00Z [testproj] gate=scope :: TK-1 :: route :: reason1
2026-09-10 00:00:01Z [testproj] gate=scope :: TK-2 :: park :: reason2
EXP
cmp -s "$T/expected.log" "$T/logs/decisions.log" && ok || bad "log_rehydrate bytes differ: $(cat "$T/logs/decisions.log")"
grep -q 'rehydrated 2 decisions rows (truncated=false)' "$T/logs/jobs-client.log" \
  && ok || bad "log_rehydrate summary line: $(cat "$T/logs/jobs-client.log")"
# the append-log ROUTE, not /api/ledger: the rows decisions_put writes live in
# their own table and /api/ledger can never serve them.
REQ=$(lastreq)
case "$REQ" in
  "GET https://jobs.test/api/decisions?"*) ok ;;
  *) bad "log_rehydrate did not GET the decisions route: $REQ" ;;
esac
grep -q 'limit=5000' <<<"$REQ" && ok || bad "log_rehydrate limit=5000 missing: $REQ"
grep -q 'since=20' <<<"$REQ" && ok || bad "log_rehydrate since cursor missing: $REQ"
# rehydrating findings hits the findings route (kind is the path segment)
rm -f "$T/logs/findings.log"; clearlog
CURL_RESP="$T/rehydrate-two.json" client log-rehydrate findings "$T/logs/findings.log"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "log_rehydrate findings rc=$RC"
case "$(lastreq)" in
  "GET https://jobs.test/api/findings?"*) ok ;;
  *) bad "log_rehydrate findings route: $(lastreq)" ;;
esac
# an unknown kind is refused before it becomes a path segment
clearlog
client log-rehydrate bogus "$T/logs/bogus.log" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok || bad "log_rehydrate bogus kind rc=$RC (want 1)"
[ ! -s "$T/req.log" ] && ok || bad "log_rehydrate bogus kind made a request"
[ ! -f "$T/logs/bogus.log" ] && ok || bad "log_rehydrate bogus kind wrote a file"

# a row with no stamp is dropped, and the summary line says how many LANDED
rm -f "$T/logs/decisions.log"; : > "$T/logs/jobs-client.log"
printf '{"rows":[{"stamp":"2026-09-10 00:00:00Z","line":"one"},{"line":"no stamp"},{"stamp":"2026-09-10 00:00:02Z","line":"three"}],"truncated":false,"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/rehydrate-gap.json"
CURL_RESP="$T/rehydrate-gap.json" client log-rehydrate decisions "$T/logs/decisions.log"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "log_rehydrate stamp-gap rc=$RC"
[ "$(wc -l < "$T/logs/decisions.log")" -eq 2 ] && ok || bad "log_rehydrate stamp-gap wrote $(wc -l < "$T/logs/decisions.log") lines"
grep -q 'rehydrated 2 decisions rows' "$T/logs/jobs-client.log" \
  && ok || bad "log_rehydrate logged the served count, not the written count: $(cat "$T/logs/jobs-client.log")"

# a line carrying an embedded newline would break one-row-per-line, so it is
# dropped and NOT counted
rm -f "$T/logs/decisions.log"; : > "$T/logs/jobs-client.log"
printf '{"rows":[{"stamp":"2026-09-10 00:00:00Z","line":"one"},{"stamp":"2026-09-10 00:00:01Z","line":"two\\nlines"}],"truncated":false}\n200\n' > "$T/rehydrate-nl.json"
CURL_RESP="$T/rehydrate-nl.json" client log-rehydrate decisions "$T/logs/decisions.log"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "log_rehydrate newline-row rc=$RC"
[ "$(wc -l < "$T/logs/decisions.log")" -eq 1 ] && ok || bad "log_rehydrate newline-row line count: $(cat "$T/logs/decisions.log")"
grep -q 'rehydrated 1 decisions rows' "$T/logs/jobs-client.log" \
  && ok || bad "log_rehydrate counted a dropped newline row: $(cat "$T/logs/jobs-client.log")"

# truncated is the WORKER's measurement, reported as it came
rm -f "$T/logs/decisions.log"; : > "$T/logs/jobs-client.log"
printf '{"rows":[{"stamp":"2026-09-10 00:00:00Z","line":"one"}],"truncated":true,"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/rehydrate-trunc.json"
CURL_RESP="$T/rehydrate-trunc.json" client log-rehydrate decisions "$T/logs/decisions.log"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "log_rehydrate truncated rc=$RC"
grep -q 'truncated=true' "$T/logs/jobs-client.log" \
  && ok || bad "log_rehydrate did not report the worker's truncated flag: $(cat "$T/logs/jobs-client.log")"

# every row unstamped -> nothing usable, same answer as an empty array
rm -f "$T/logs/decisions.log"
printf '{"rows":[{"line":"no stamp"}],"truncated":false}\n200\n' > "$T/rehydrate-nostamp.json"
CURL_RESP="$T/rehydrate-nostamp.json" client log-rehydrate decisions "$T/logs/decisions.log"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "log_rehydrate all-unstamped rc=$RC (want 2)"
[ ! -f "$T/logs/decisions.log" ] && ok || bad "log_rehydrate all-unstamped created a file"

# restore the two-row file for the no-network check
CURL_RESP="$T/rehydrate-two.json" client log-rehydrate decisions "$T/logs/decisions.log" >/dev/null 2>&1
clearlog

# second run with file present -> no network
BEFORE=$(wc -l < "$T/req.log" | tr -d ' ')
CURL_RESP="$T/rehydrate-two.json" client log-rehydrate decisions "$T/logs/decisions.log"; RC=$?
AFTER=$(wc -l < "$T/req.log" | tr -d ' ')
[ "$RC" -eq 0 ] && ok || bad "log_rehydrate second run rc=$RC"
[ "$BEFORE" -eq "$AFTER" ] && ok || bad "log_rehydrate made a network call with non-empty file"

# empty rows -> rc 2 and no file
rm -f "$T/logs/decisions.log"
printf '{"rows":[],"truncated":false,"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/empty-rehydrate.json"
CURL_RESP="$T/empty-rehydrate.json" client log-rehydrate decisions "$T/logs/decisions.log"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "log_rehydrate empty rows rc=$RC"
[ ! -f "$T/logs/decisions.log" ] && ok || bad "log_rehydrate empty rows created file"

# curl down -> rc 1 and no file
rm -f "$T/logs/decisions.log"
CURL_MODE=down CURL_RESP="" client log-rehydrate decisions "$T/logs/decisions.log"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "log_rehydrate curl down rc=$RC"
[ ! -f "$T/logs/decisions.log" ] && ok || bad "log_rehydrate curl down created file"

# --- 4. telegram topics sync -------------------------------------------------
# The verb's contract is `topics-sync <file> [max_age_secs=600]`. Drive it at a
# NON-default path, so a reversion to the old hardcoded
# $HARNESS/state/telegram-topics.json fails right here.
TOPICS="$T/state/poll-topics.json"
DEFAULT_TOPICS="$T/state/telegram-topics.json"
rm -f "$TOPICS" "$DEFAULT_TOPICS"
# The worker envelope carries as_of too; the FILE must carry only .topics.
printf '{"topics":{"project-3":6},"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/topics-resp.json"
printf '%s' '{"topics":{"project-3":6}}' > "$T/topics-expected.json"
clearlog
CURL_RESP="$T/topics-resp.json" client topics-sync "$TOPICS"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "topics-sync no file rc=$RC"
[ -f "$TOPICS" ] && ok || bad "topics-sync did not create the file it was given"
[ ! -e "$DEFAULT_TOPICS" ] && ok || bad "topics-sync wrote the default path instead of its argument"
cmp -s "$T/topics-expected.json" "$TOPICS" && ok || bad "topics-sync file bytes differ: $(cat "$TOPICS")"

# no file argument at all -> rc 1, no request (the path is not optional)
clearlog
CURL_RESP="$T/topics-resp.json" client topics-sync >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok || bad "topics-sync with no file rc=$RC (want 1)"
[ ! -s "$T/req.log" ] && ok || bad "topics-sync with no file made a request"

# fresh file -> no request
clearlog
CURL_RESP="$T/topics-resp.json" client topics-sync "$TOPICS"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "topics-sync fresh rc=$RC"
[ ! -s "$T/req.log" ] && ok || bad "topics-sync fresh made a request"

# 20 minutes old, default window is 600s -> STALE, it must fetch.
# This is the assertion that would have caught `find -mmin -60` (3600s).
touch -d '-20 minutes' "$TOPICS"
clearlog
CURL_RESP="$T/topics-resp.json" client topics-sync "$TOPICS"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "topics-sync stale-by-default rc=$RC"
[ "$(grep -c 'GET https://jobs.test/api/telegram-topics' "$T/req.log")" -eq 1 ] \
  && ok || bad "topics-sync called a 20-minute-old file fresh under the 600s default"

# the same age with an explicit 3600s window -> fresh, no request
touch -d '-20 minutes' "$TOPICS"
clearlog
CURL_RESP="$T/topics-resp.json" client topics-sync "$TOPICS" 3600; RC=$?
[ "$RC" -eq 0 ] && ok || bad "topics-sync max_age=3600 rc=$RC"
[ ! -s "$T/req.log" ] && ok || bad "topics-sync ignored its max_age_secs argument"

printf '{"topics":{}}\n200\n' > "$T/topics-empty.json"

# --- seed, shape A: a ROOT-MAP file (the shape poll-commands.sh wrote) --------
ROOTF="$T/state/topics-root.json"
printf '%s' '{"project-3":6,"project-2":7}' > "$ROOTF"
touch -d '2026-09-10T00:00:00Z' "$ROOTF"
cp "$ROOTF" "$T/root-old.json"
clearlog
CURL_RESP="$T/topics-empty.json" client topics-sync "$ROOTF"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "topics-sync seed root-map rc=$RC"
[ "$(grep -c 'PUT https://jobs.test/api/telegram-topics' "$T/req.log")" -eq 2 ] \
  && ok || bad "topics-sync root-map PUT count: $(cat "$T/req.log")"
grep 'PUT https://jobs.test/api/telegram-topics ' "$T/req.log" | cut -d' ' -f3- \
  | jq -se 'map(select(.project == "project-3")) | length == 1 and (.[0].thread_id == 6) and (.[0].thread_id | type) == "number"' >/dev/null 2>&1 \
  && ok || bad "topics-sync root-map project-3 thread_id is not the integer 6: $(cat "$T/req.log")"
grep 'PUT https://jobs.test/api/telegram-topics ' "$T/req.log" | cut -d' ' -f3- \
  | jq -se 'map(select(.project == "project-2")) | length == 1 and (.[0].thread_id == 7) and (.[0].thread_id | type) == "number"' >/dev/null 2>&1 \
  && ok || bad "topics-sync root-map project-2 thread_id is not the integer 7: $(cat "$T/req.log")"
cmp -s "$T/root-old.json" "$ROOTF" && ok || bad "topics-sync seed overwrote the root-map file"

# --- seed, shape B: a .topics file, with two rows the worker would reject -----
NESTF="$T/state/topics-nested.json"
printf '%s' '{"topics":{"alerts":8,"Bad Name":5,"x":null,"nan":"abc"}}' > "$NESTF"
touch -d '2026-09-10T00:00:00Z' "$NESTF"
cp "$NESTF" "$T/nest-old.json"
: > "$T/logs/jobs-client.log"
rm -f "$T/logs/ALERTS.log"
clearlog
CURL_RESP="$T/topics-empty.json" client topics-sync "$NESTF"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "topics-sync seed .topics rc=$RC"
# only the one valid entry is PUT; a bad row is skipped, never an outage, and
# never a reason to abandon the rest of the map
[ "$(grep -c 'PUT https://jobs.test/api/telegram-topics' "$T/req.log")" -eq 1 ] \
  && ok || bad "topics-sync .topics PUT count: $(cat "$T/req.log")"
grep 'PUT https://jobs.test/api/telegram-topics ' "$T/req.log" | cut -d' ' -f3- \
  | jq -se 'map(select(.project == "alerts")) | length == 1 and (.[0].thread_id == 8)' >/dev/null 2>&1 \
  && ok || bad "topics-sync .topics alerts entry: $(cat "$T/req.log")"
grep -q '"project":"Bad Name"' "$T/req.log" && bad "topics-sync PUT an invalid project name" || ok
grep -q '"project":"x"' "$T/req.log" && bad "topics-sync PUT a null thread id" || ok
grep -q '"project":"nan"' "$T/req.log" && bad "topics-sync PUT a non-integer thread id" || ok
[ "$(grep -c 'topics-sync skipping' "$T/logs/jobs-client.log")" -ge 2 ] \
  && ok || bad "topics-sync did not log the skipped entries: $(cat "$T/logs/jobs-client.log")"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "topics-sync treated a bad row as an outage: $(cat "$T/logs/ALERTS.log")"
cmp -s "$T/nest-old.json" "$NESTF" && ok || bad "topics-sync seed overwrote the .topics file"

# an entry whose PUT fails for REAL is an outage: stop, do not keep hammering
GOODF="$T/state/topics-two.json"
printf '%s' '{"project-3":6,"project-2":7}' > "$GOODF"
touch -d '2026-09-10T00:00:00Z' "$GOODF"
clearlog
OUT=$(CURL_RESP="$T/topics-empty.json" CURL_PUT_RESP="$T/err500.json" client topics-sync "$GOODF" 2>/dev/null); RC=$?
[ "$RC" -eq 1 ] && ok || bad "topics-sync seed 500 rc=$RC (want 1)"
[ "$(grep -c 'PUT https://jobs.test/api/telegram-topics' "$T/req.log")" -eq 1 ] \
  && ok || bad "topics-sync kept PUTting through an outage: $(cat "$T/req.log")"
clearlog

# --- topic-set argument validation -------------------------------------------
clearlog
client topic-set project-3 abc >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok || bad "topic-set non-integer thread rc=$RC (want 1)"
[ ! -s "$T/req.log" ] && ok || bad "topic-set non-integer thread made a request"
clearlog
client topic-set 'Bad Name' 5 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok || bad "topic-set bad project rc=$RC (want 1)"
[ ! -s "$T/req.log" ] && ok || bad "topic-set bad project made a request"
clearlog
client topic-set project-3 0 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok || bad "topic-set thread_id=0 rc=$RC (want 1)"
[ ! -s "$T/req.log" ] && ok || bad "topic-set thread_id=0 made a request"
clearlog
printf '{"topic":{"project":"project-3","thread_id":6}}\n200\n' > "$T/topic-set-ok.json"
OUT=$(CURL_RESP="$T/topic-set-ok.json" client topic-set project-3 6); RC=$?
[ "$RC" -eq 0 ] && ok || bad "topic-set rc=$RC"
lastreq | cut -d' ' -f3- | jq -e '.project == "project-3" and .thread_id == 6 and (.thread_id | type) == "number" and .actor == "testbox"' >/dev/null 2>&1 \
  && ok || bad "topic-set body: $(lastreq)"

# curl down with a stale file -> rc 1, untouched, EXACTLY one alert line
touch -d '2026-09-10T00:00:00Z' "$ROOTF"
rm -f "$T/logs/ALERTS.log"
rm -rf "$T/flags"
clearlog
CURL_MODE=down CURL_RESP="" client topics-sync "$ROOTF"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "topics-sync curl down rc=$RC"
[ "$(grep -c 'harness-jobs unreachable' "$T/logs/ALERTS.log" 2>/dev/null)" -eq 1 ] \
  && ok || bad "topics-sync curl down alert lines: $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
cmp -s "$T/root-old.json" "$ROOTF" && ok || bad "topics-sync outage touched the file"

# --- 4b. telegram_topics_get -------------------------------------------------
# Prints the FILE shape, and prints NOTHING on a miss (like setting_get).
clearlog
OUT=$(CURL_RESP="$T/topics-resp.json" client topics 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok || bad "topics rc=$RC"
printf '%s' "$OUT" | jq -e '.topics["project-3"] == 6 and (has("as_of") | not)' >/dev/null 2>&1 \
  && ok || bad "topics printed the raw envelope: $OUT"

OUT=$(CURL_RESP="$T/ok.json" client topics 2>/dev/null); RC=$?
[ "$RC" -eq 2 ] && ok || bad "topics {ok:true} rc=$RC (want 2)"
[ -z "$(printf '%s' "$OUT" | tr -d '\n')" ] && ok || bad "topics printed on a miss: $OUT"

OUT=$(CURL_RESP="$T/topics-empty.json" client topics 2>/dev/null); RC=$?
[ "$RC" -eq 2 ] && ok || bad "topics empty map rc=$RC (want 2)"
[ -z "$(printf '%s' "$OUT" | tr -d '\n')" ] && ok || bad "topics printed on an empty map: $OUT"

# --- 5. ledger_page ----------------------------------------------------------
printf '{"ledgers":[{"kind":"pr_state","key":"example-org/testproj#1","status":"OWNED","updated_at":"2026-09-10T00:00:00Z"}],"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/ledgers.json"
clearlog
OUT=$(CURL_RESP="$T/ledgers.json" client ledger-page pr_state 1000 2026-09-01T00:00:00Z); RC=$?
[ "$RC" -eq 0 ] && ok || bad "ledger_page rc=$RC"
REQ=$(lastreq)
grep -q 'GET https://jobs.test/api/ledger' <<<"$REQ" && ok || bad "ledger_page GET path: $REQ"
grep -q 'before=2026-09-01T00%3A00%3A00Z' <<<"$REQ" && ok || bad "ledger_page before= param: $REQ"
grep -q 'kind=pr_state' <<<"$REQ" && ok || bad "ledger_page kind param"
grep -q 'limit=1000' <<<"$REQ" && ok || bad "ledger_page limit param"
printf '%s' "$OUT" | jq -e '.ledgers | length == 1' >/dev/null 2>&1 && ok || bad "ledger_page did not print the raw payload: $OUT"

# no third argument -> no before= in the query at all
clearlog
OUT=$(CURL_RESP="$T/ledgers.json" client ledger-page pr_state 1000); RC=$?
[ "$RC" -eq 0 ] && ok || bad "ledger_page no-before rc=$RC"
grep -q 'before=' <<<"$(lastreq)" && bad "ledger_page sent an empty before=: $(lastreq)" || ok

# --- 6. the CLI verb table ---------------------------------------------------
# Each verb is reachable as a WORD, and usage() names it. Every case above drove
# the real CLI, so this only pins the usage text the operator reads.
USAGE=$(client 2>&1)
for W in 'pr-owners-put <repo>' 'pr-owners-list <repo>' 'decisions-put <project>' \
         'findings-put <project>' 'log-rehydrate <decisions|findings>' 'topic-set <project>' \
         'topics-sync <file> [max_age_secs=600]' 'ledger-page <kind>'; do
  case "$USAGE" in *"$W"*) ok ;; *) bad "usage() does not name $W" ;; esac
done

echo "jobs-client-ledger-verbs-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
