#!/bin/bash
# tests/pr-rows-contract.bh-1385-test.sh — BH-1385 (BH-1025.0): the CONTRACT
# half of the PR-state/attempt row work. Ten fail-open client verbs in
# bin/lib/jobs/jobs.sh and three attempt helpers in bin/lib/mc/locks.sh, with
# mc_attempted rewritten over them and mc_attempt_clear given its row half. No
# route exists yet (#1386), so everything here is pinned against a curl shim
# that records what was SENT.
#
# WHAT IT PINS, AND WHY EACH ONE IS HERE.
#
#   1. The wire. The routes child builds against the method, path and body this
#      suite records — a verb whose body shape drifts is a route that answers
#      the wrong table, and nothing else in the repo would notice until a row
#      went missing in production. So every verb's exact `METHOD PATH BODY` is
#      an assertion, not a comment.
#   2. The rc map, verb by verb: 200 -> 0, 404 -> 2 (a REAL miss), curl exit 7
#      -> 1 (an outage). This is job_ledger_get's contract verbatim and the
#      whole reason the conductor can read these rows at all: rc 1 must never
#      be read as "already attempted", because that silently drops a rebase.
#   3. The dark default. With no `pr-state-rows` flag the conductor's attempt
#      ledger is byte-identical to today — the file, nothing else. The only
#      request a dark lane still makes is flag_active's own reconcile, which is
#      how every DB-backed flag in the fleet works (the lt_on precedent in
#      bin/lib/ledger-twin.sh). So the flag-absent case asserts the request
#      sink holds exactly that one line and no /api/pr-* line at all.
#   4. mc_attempt_pr_key is a CLASSIFIER in front of a row write and in front of
#      a possible skip of a rebase, so its negatives are driven by name:
#      `identityalert hub word day`, `dvread proj sha`, a line with no sha, a
#      non-numeric PR number, an empty repo, a doubled `#`, a leading space.
#      Every one of them is file-only.
#   5. The FORGET reaches the row. mc_attempt_clear is the ledger's one eraser,
#      and mc_attempt_has answers a file miss from the row — so a clear that
#      stopped at the file would let the row warm the line back and strand the
#      PR on every tick after it. Case 12 drives the real tick sequence against
#      a shim that keeps real rows and proves the respawn.
#
# HOW IT MEASURES. Artifacts only: the request sink the curl shim writes, the
# rc of the call, and state/merge-conductor/attempts.txt. Never a grep over
# source text. mc_attempted is driven through the REAL bin/lib/mc/locks.sh
# loaded by the REAL bin/lib/merge-conductor-lib.sh, which is the production
# entry point bin/merge-conductor.sh calls eight times a tick.
#
# No clock, no network, no gh, no git: every `since`/`at` value is a literal
# ISO string and the shim answers from env vars. Nothing outside $T is written.
# determinism: ok-file clock-rolling-window the `since=` query is pinned TEXT
# ($SINCE, a literal), asserted against a literal — nothing here is compared to
# now, and there is no route behind it to roll a window at all.
#
# Run from anywhere: tests/pr-rows-contract.bh-1385-test.sh  (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/env" "$H/flags" "$H/logs" \
         "$H/state/merge-conductor" "$T/fakebin"
# The fixture shape bin/jobs-client.sh refuses to run without: the client AND
# bin/lib/jobs/*.sh beside it (BH-1194), plus the conductor shim and its six
# modules, which is what merge-conductor-lib.sh's own source loop needs.
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" || exit 1
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/" || exit 1

ATT="$H/state/merge-conductor/attempts.txt"
REQ="$T/req.log"
ERR="$T/err.log"

# ── the curl shim ───────────────────────────────────────────────────────────
# Records METHOD URL BODY, then answers a scripted status. /api/flags/* is
# always a 404 so flag_active falls to the FILE (its own documented contract),
# /api/ledger is answered from a TSV fixture so merge_ledger_has can be driven
# through the real job_ledger_get, and everything else answers $CURL_STATUS
# with $CURL_BODY. CURL_MODE=down is a transport failure (exit 7) — what a
# worker outage looks like to bin/lib/jobs/req.sh.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -sS|-S|-s|-L|-f) shift;;
    *) URL="$1"; shift;;
  esac
done
[ -n "${REQ_LOG:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
[ "${CURL_MODE:-ok}" = down ] && exit 7
ud() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
qp() { printf '%s' "${URL#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
DEFBODY='{"ok":true}'
case "$URL" in
  */api/pr-attempts*)
    # CURL_STATE turns /api/pr-attempts into a REAL little table: PUT stores the
    # key, DELETE removes it, GET answers 200 or 404 from what is there. That is
    # what a tick sequence needs — a scripted status cannot tell "the row is
    # gone" from "the route always says 404".
    # Unset, and this arm does nothing: the scripted $CURL_STATUS below answers,
    # exactly as it did for every case written before the store existed.
    if [ -n "${CURL_STATE:-}" ]; then
      if [ "$METHOD" = PUT ]; then
        K=$(printf '%s' "$BODY" | jq -r '[.repo,(.number|tostring),.kind,.sha]|join("|")' 2>/dev/null)
      else
        K=$(printf '%s|%s|%s|%s' "$(ud "$(qp repo)")" "$(qp number)" "$(ud "$(qp kind)")" "$(ud "$(qp sha)")")
      fi
      F="$CURL_STATE/$(printf '%s' "$K" | tr -c 'A-Za-z0-9' '_')"
      case "$METHOD" in
        PUT)    : > "$F"; printf '{"ok":true}\n200\n' ;;
        DELETE) if [ -e "$F" ]; then rm -f "$F"; printf '{"ok":true}\n200\n'
                else printf '{"error":"no row"}\n404\n'; fi ;;
        *)      if [ -e "$F" ]; then printf '{"ok":true}\n200\n'
                else printf '{"error":"no row"}\n404\n'; fi ;;
      esac
      exit 0
    fi ;;
  */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;;
  */api/ledger\?*)
    K=$(ud "$(qp kind)"); V=$(ud "$(qp key)")
    if [ -n "${LEDGER_DOWN_KIND:-}" ] && [ "$K" = "${LEDGER_DOWN_KIND}" ]; then exit 7; fi
    LINE=$(awk -F'\t' -v k="$K" -v v="$V" '$1==k && $2==v {print; exit}' "${LEDGER_ROWS:-/dev/null}" 2>/dev/null)
    if [ -n "$LINE" ]; then
      jq -nc --arg s "$(printf '%s' "$LINE" | cut -f3)" '{ledger:{status:$s}}'
      printf '\n200\n'
    else
      printf '{"error":"not found"}\n404\n'
    fi
    exit 0 ;;
esac
printf '%s\n%s\n' "${CURL_BODY:-$DEFBODY}" "${CURL_STATUS:-200}"
CURL
chmod +x "$T/fakebin/curl"

# ── the driver ──────────────────────────────────────────────────────────────
# One fresh process per call, so the per-process caches (_PR_ROWS_ON) and the
# breaker (_PR_ROWS_DOWN) start empty — except where a case deliberately runs
# two calls in ONE process to prove the cache or the breaker.
cat > "$T/drive.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
if [ "${DRIVE_MC:-0}" = 1 ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 91
fi
if [ -n "${DRIVE_UNSET:-}" ]; then unset -f "$DRIVE_UNSET" 2>/dev/null; fi
eval "$DRIVE_CODE"
DRV

drv() { # drv <shell snippet> — prints its stdout; caller reads $?
  DRIVE_CODE="$1" \
  PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_BOX=testbox \
  JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test \
  REQ_LOG="$REQ" \
  CURL_MODE="${CURL_MODE:-ok}" CURL_STATUS="${CURL_STATUS:-}" CURL_BODY="${CURL_BODY:-}" \
  CURL_STATE="${CURL_STATE:-}" \
  LEDGER_ROWS="${LEDGER_ROWS:-}" LEDGER_DOWN_KIND="${LEDGER_DOWN_KIND:-}" \
  DRIVE_MC="${DRIVE_MC:-0}" DRIVE_UNSET="${DRIVE_UNSET:-}" \
  bash "$T/drive.sh" 2>>"$ERR"
}

reset()   { : > "$REQ"; : > "$ERR"; }
lastreq() { grep -v '/api/flags/' "$REQ" 2>/dev/null | tail -1; }
mu()      { printf '%s' "$1" | awk '{print $1" "$2}'; }          # method + url
rbody()   { printf '%s' "$1" | cut -d' ' -f3-; }
nreq()    { grep -c . "$REQ" 2>/dev/null || true; }
npr()     { grep -c '/api/pr-' "$REQ" 2>/dev/null || true; }
flag_on()  { : > "$H/flags/pr-state-rows"; }
flag_off() { rm -f "$H/flags/pr-state-rows"; }

REPO=example-org/x
EREPO=example-org%2Fx
SINCE=2026-09-22T10:00:00Z
ESINCE=2026-09-22T10%3A00%3A00Z

echo "== 1. every verb's method, path and body =="

reset
OUT=$(drv "pr_state_event_put '$REPO' 12 BLOCKED '$SINCE' headsha revsha 'ci red' https://github.com/example-org/x/pull/12 1"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "1a: pr_state_event_put rc=$RC (want 0) out='$OUT'"
L=$(lastreq)
[ "$(mu "$L")" = "POST http://jobs.test/api/pr-state-events" ] && ok \
  || bad "1a: wrong method/path: $(mu "$L")"
rbody "$L" | jq -e --arg r "$REPO" --arg s "$SINCE" '
  .repo == $r and .number == 12 and .state == "BLOCKED" and .since == $s
  and .head == "headsha" and .reviewed == "revsha" and .reason == "ci red"
  and .url == "https://github.com/example-org/x/pull/12"
  and .alerted == "1" and .actor == "testbox"' >/dev/null 2>&1 \
  && ok || bad "1a: body wrong: $(rbody "$L")"
[ -z "$OUT" ] && ok || bad "1a: pr_state_event_put must print nothing, got '$OUT'"

# An empty `alerted` is the DEFAULT, not a null: the dedupe index is a plain
# column list, and a NULL column in a UNIQUE index never collides in SQLite —
# every re-post would insert a new row and the alert would fire again.
reset
drv "pr_state_event_put '$REPO' 12 BLOCKED '$SINCE' '' '' '' '' ''" >/dev/null; RC=$?
[ "$RC" -eq 0 ] && ok || bad "1b: pr_state_event_put with empty tail rc=$RC"
rbody "$(lastreq)" | jq -e '.alerted == "-"' >/dev/null 2>&1 \
  && ok || bad "1b: empty alerted must be sent as '-': $(rbody "$(lastreq)")"

reset
OUT=$(drv "pr_state_page 5 42 '$REPO'"); RC=$?
[ "$(mu "$(lastreq)")" = "GET http://jobs.test/api/pr-state?limit=5&before=42&repo=$EREPO" ] && ok \
  || bad "1c: pr_state_page path wrong: $(mu "$(lastreq)")"

reset
OUT=$(drv "pr_state_events_page BLOCKED '$SINCE' 5"); RC=$?
[ "$(mu "$(lastreq)")" = "GET http://jobs.test/api/pr-state-events?state=BLOCKED&since=$ESINCE&limit=5" ] && ok \
  || bad "1d: pr_state_events_page path wrong: $(mu "$(lastreq)")"

reset
OUT=$(drv "pr_attempt_put '$REPO' 12 rebase abc"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "1e: pr_attempt_put rc=$RC (want 0)"
L=$(lastreq)
[ "$(mu "$L")" = "PUT http://jobs.test/api/pr-attempts" ] && ok \
  || bad "1e: pr_attempt_put method/path wrong: $(mu "$L")"
rbody "$L" | jq -e --arg r "$REPO" '.repo == $r and .number == 12 and .kind == "rebase" and .sha == "abc" and .actor == "testbox"' \
  >/dev/null 2>&1 && ok || bad "1e: pr_attempt_put body wrong: $(rbody "$L")"

reset
OUT=$(drv "pr_attempt_has '$REPO' 12 rebase abc"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "1f: pr_attempt_has rc=$RC (want 0)"
[ "$(mu "$(lastreq)")" = "GET http://jobs.test/api/pr-attempts?repo=$EREPO&number=12&kind=rebase&sha=abc" ] && ok \
  || bad "1f: pr_attempt_has path wrong: $(mu "$(lastreq)")"
[ -z "$OUT" ] && ok || bad "1f: pr_attempt_has must print nothing, got '$OUT'"

reset
OUT=$(drv "pr_attempt_del '$REPO' 12 rebase abc"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "1h: pr_attempt_del rc=$RC (want 0)"
[ "$(mu "$(lastreq)")" = "DELETE http://jobs.test/api/pr-attempts?repo=$EREPO&number=12&kind=rebase&sha=abc" ] && ok \
  || bad "1h: pr_attempt_del method/path wrong: $(mu "$(lastreq)")"
[ -z "$OUT" ] && ok || bad "1h: pr_attempt_del must print nothing, got '$OUT'"

reset
OUT=$(CURL_BODY='{"count":3}' drv "pr_attempt_count '$REPO' 12 rebase"); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = 3 ] && ok || bad "1g: pr_attempt_count rc=$RC out='$OUT' (want 0/3)"
[ "$(mu "$(lastreq)")" = "GET http://jobs.test/api/pr-attempts?repo=$EREPO&number=12&kind=rebase" ] && ok \
  || bad "1g: pr_attempt_count path wrong: $(mu "$(lastreq)")"

echo "== 2. the rc map: 200 -> 0, 404 -> 2, transport -> 1 =="

for V in "pr_state_event_put '$REPO' 12 BLOCKED '$SINCE' h r x u 1" \
         "pr_state_page 5" \
         "pr_state_events_page BLOCKED '$SINCE' 5" \
         "pr_attempt_put '$REPO' 12 rebase abc" \
         "pr_attempt_has '$REPO' 12 rebase abc" \
         "pr_attempt_del '$REPO' 12 rebase abc" \
         "pr_attempt_count '$REPO' 12 rebase"; do
  reset
  CURL_STATUS=404 drv "$V" >/dev/null; RC=$?
  [ "$RC" -eq 2 ] && ok || bad "2: 404 must be rc 2 for [$V], got $RC"
  reset
  CURL_MODE=down drv "$V" >/dev/null; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "2: an outage must be rc 1 for [$V], got $RC"
done

# D11: absent is not zero. A 404 is a measured "no rows" and prints 0; an
# OUTAGE prints nothing at all, so no caller can read a blink as a count.
reset
OUT=$(CURL_STATUS=404 drv "pr_attempt_count '$REPO' 12 rebase"); RC=$?
[ "$RC" -eq 2 ] && [ "$OUT" = 0 ] && ok || bad "2: 404 count must print 0 at rc 2, got rc=$RC out='$OUT'"
reset
OUT=$(CURL_MODE=down drv "pr_attempt_count '$REPO' 12 rebase"); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "2: an outage must print NO number, got rc=$RC out='$OUT'"

echo "== 3. the list shapes =="

reset
OUT=$(CURL_BODY='{"rows":[]}' drv "pr_state_page 5"); RC=$?
[ "$RC" -eq 2 ] && ok || bad "3a: pr_state_page with no rows must be rc 2, got $RC"
printf '%s' "$OUT" | jq -e '.rows | length == 0' >/dev/null 2>&1 && ok \
  || bad "3a: pr_state_page must still print the raw JSON, got '$OUT'"

reset
OUT=$(CURL_BODY='{"rows":[{"id":1,"repo":"example-org/x","number":12,"state":"BLOCKED"}]}' drv "pr_state_page 5"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "3b: pr_state_page with a row must be rc 0, got $RC"
printf '%s' "$OUT" | jq -e '.rows[0].number == 12' >/dev/null 2>&1 && ok \
  || bad "3b: pr_state_page must print the raw JSON, got '$OUT'"

# Newest first is decided CLIENT-side (sort_by(.id)|reverse), so the order does
# not depend on a route that does not exist yet. Row id 7 is sent second.
ROWS='{"rows":[{"id":2,"repo":"example-org/x","number":12,"state":"BLOCKED","since":"S2","head":"h2","reviewed":null,"reason":"","url":"u2","alerted":"-","at":"A2"},{"id":7,"repo":"example-org/y","number":34,"state":"BLOCKED","since":"S7","head":"h7","reviewed":"r7","reason":"why","url":"u7","alerted":"1","at":"A7"}]}'
reset
OUT=$(CURL_BODY="$ROWS" drv "pr_state_events_page BLOCKED '$SINCE' 5"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "3c: pr_state_events_page rc=$RC (want 0)"
FIRST=$(head -1 <<<"$OUT")
SECOND=$(printf '%s\n' "$OUT" | sed -n 2p)
[ "$(printf '%s' "$FIRST" | cut -f2)" = 34 ] && ok \
  || bad "3c: newest (id 7) must be the FIRST row, got '$FIRST'"
[ "$(printf '%s' "$FIRST" | awk -F'\t' '{print NF}')" = 10 ] && ok \
  || bad "3c: a row is 10 tab-separated fields, got $(printf '%s' "$FIRST" | awk -F'\t' '{print NF}')"
[ "$(printf '%s' "$SECOND" | cut -f6)" = "-" ] && [ "$(printf '%s' "$SECOND" | cut -f7)" = "-" ] && ok \
  || bad "3c: a null/empty field must render as '-', got '$SECOND'"
reset
OUT=$(CURL_BODY='{"rows":[]}' drv "pr_state_events_page BLOCKED '$SINCE' 5"); RC=$?
[ "$RC" -eq 2 ] && ok || bad "3d: pr_state_events_page with no rows must be rc 2, got $RC"

echo "== 4. merge_ledger_has: the OR of two kinds, and never a blink =="

printf 'merge\thttps://github.com/o/r/pull/1\tmerged\n'      >  "$T/ledger.tsv"
printf 'pr_merged\thttps://github.com/o/r/pull/2\tmerged\n'  >> "$T/ledger.tsv"
printf 'merge\thttps://github.com/o/r/pull/3\tclosed\n'      >> "$T/ledger.tsv"
export LEDGER_ROWS="$T/ledger.tsv"

reset; drv "merge_ledger_has https://github.com/o/r/pull/1" >/dev/null; RC=$?
[ "$RC" -eq 0 ] && ok || bad "4a: a merge row must be rc 0, got $RC"
reset; drv "merge_ledger_has https://github.com/o/r/pull/2" >/dev/null; RC=$?
[ "$RC" -eq 0 ] && ok || bad "4b: a pr_merged row must be rc 0, got $RC"
reset; drv "merge_ledger_has https://github.com/o/r/pull/9" >/dev/null; RC=$?
[ "$RC" -eq 2 ] && ok || bad "4c: two real misses must be rc 2, got $RC"
reset; LEDGER_DOWN_KIND=pr_merged drv "merge_ledger_has https://github.com/o/r/pull/9" >/dev/null; RC=$?
[ "$RC" -eq 1 ] && ok || bad "4d: an outage on EITHER read must be rc 1 (never 'not merged'), got $RC"
reset; drv "merge_ledger_has https://github.com/o/r/pull/3" >/dev/null; RC=$?
[ "$RC" -eq 2 ] && ok || bad "4e: a row whose status is not 'merged' is a real miss (rc 2), got $RC"
reset; drv "merge_ledger_has ''" >/dev/null; RC=$?
[ "$RC" -eq 1 ] && ok || bad "4f: an empty url must be rc 1, got $RC"
unset LEDGER_ROWS

echo "== 5. pr_rows_on: one resolution per process, and the breaker =="

reset; flag_on
drv 'pr_rows_on; echo "first=$?"; pr_rows_on; echo "second=$?"' > "$T/o5" 2>/dev/null
grep -qx 'first=0' "$T/o5" && grep -qx 'second=0' "$T/o5" && ok \
  || bad "5a: pr_rows_on must be rc 0 with the flag file present: $(cat "$T/o5")"
[ "$(grep -c '/api/flags/pr-state-rows' "$REQ")" = 1 ] && ok \
  || bad "5a: the flag must be resolved ONCE per process, got $(grep -c '/api/flags/pr-state-rows' "$REQ") requests"

reset; flag_off
drv 'pr_rows_on; echo "rc=$?"' > "$T/o5" 2>/dev/null
grep -qx 'rc=1' "$T/o5" && ok || bad "5b: pr_rows_on with no flag must be rc 1: $(cat "$T/o5")"
[ "$(nreq)" = 1 ] && ok || bad "5b: a dark lane makes exactly one request (the flag reconcile), got: $(cat "$REQ")"
[ "$(npr)" = 0 ] && ok || bad "5b: a dark lane must make no /api/pr-* request: $(cat "$REQ")"

reset; flag_on
drv 'pr_rows_on; echo "before=$?"; pr_rows_trip; pr_rows_on; echo "after=$?"' > "$T/o5" 2>/dev/null
grep -qx 'before=0' "$T/o5" && grep -qx 'after=1' "$T/o5" && ok \
  || bad "5c: pr_rows_trip must latch pr_rows_on off for the process: $(cat "$T/o5")"

echo "== 6. mc_attempt_pr_key: the PR-line classifier and its negatives =="

DRIVE_MC=1
reset
OUT=$(drv 'mc_attempt_pr_key "rebase example-org/x#12 abc"'); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'example-org/x\t12\trebase\tabc')" ] && ok \
  || bad "6a: rebase key wrong: rc=$RC out='$OUT'"
# `lanedown KEY HEAD EPOCH` — the sha column is the exact tail, so the file
# line round-trips byte-identical.
OUT=$(drv 'mc_attempt_pr_key "lanedown example-org/x#12 abc ep7"'); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'example-org/x\t12\tlanedown\tabc ep7')" ] && ok \
  || bad "6b: lanedown tail wrong: rc=$RC out='$OUT'"
while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  OUT=$(drv "mc_attempt_pr_key \"$LINE\""); RC=$?
  [ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok \
    || bad "6c: [$LINE] must be rc 1 with no key, got rc=$RC out='$OUT'"
done <<'NEG'
identityalert hub word day
dvread proj sha
mergetree example-org/x#1
rebase example-org/x#notnum abc
rebase #12 abc
rebase example-org/x#12#3 abc
 rebase example-org/x#12 abc
NEG

echo "== 7. mc_attempt_has: the file first, a row warms it, an outage never does =="

reset; flag_on; : > "$ATT"
drv 'mc_attempt_has "rebase example-org/x#12 abc"; echo "rc=$?"' > "$T/o7" 2>/dev/null
grep -qx 'rc=0' "$T/o7" && ok || bad "7a: a 200 row must answer rc 0: $(cat "$T/o7")"
grep -qxF 'rebase example-org/x#12 abc' "$ATT" && ok \
  || bad "7a: a row hit must WARM the file line: $(cat "$ATT")"

reset; flag_on; : > "$ATT"
CURL_MODE=down drv 'mc_attempt_has "rebase example-org/x#12 abc"; echo "one=$?"; mc_attempt_has "rebase example-org/x#13 def"; echo "two=$?"' > "$T/o7" 2>/dev/null
grep -qx 'one=1' "$T/o7" && grep -qx 'two=1' "$T/o7" && ok \
  || bad "7b: an outage must be rc 1, never 'already attempted': $(cat "$T/o7")"
[ "$(npr)" = 1 ] && ok \
  || bad "7b: the breaker must stop the SECOND read after an outage, got $(npr) /api/pr- requests: $(cat "$REQ")"
[ ! -s "$ATT" ] && ok || bad "7b: an outage must write no file line: $(cat "$ATT")"

reset; flag_on; : > "$ATT"
CURL_STATUS=404 drv 'mc_attempt_has "rebase example-org/x#12 abc"; echo "rc=$?"' > "$T/o7" 2>/dev/null
grep -qx 'rc=1' "$T/o7" && ok || bad "7c: a real miss must be rc 1: $(cat "$T/o7")"
[ ! -s "$ATT" ] && ok || bad "7c: a miss must write no file line: $(cat "$ATT")"

echo "== 8. mc_attempt_put: the file first, the row second, rc ignored =="

reset; flag_on
printf 'rrconsumed example-org/x#99 zzz\n' > "$ATT"
CURL_STATUS=500 drv 'mc_attempt_put "rebase example-org/x#12 abc"; echo "rc=$?"' > "$T/o8" 2>/dev/null
grep -qx 'rc=0' "$T/o8" && ok || bad "8a: mc_attempt_put must stay rc 0 through a 500: $(cat "$T/o8")"
grep -qxF 'rebase example-org/x#12 abc' "$ATT" && ok \
  || bad "8a: the file line must exist even when the PUT failed: $(cat "$ATT")"
# APPEND, never truncate: attempts.txt is the conductor's whole cross-tick
# memory and every other writer appends to it.
grep -qxF 'rrconsumed example-org/x#99 zzz' "$ATT" && ok \
  || bad "8a: mc_attempt_put must APPEND, not replace attempts.txt: $(cat "$ATT")"
grep -q 'PUT http://jobs.test/api/pr-attempts' "$REQ" && ok \
  || bad "8a: mc_attempt_put must still PUT the row: $(cat "$REQ")"

# A non-PR line is file-only: no classifier key, no row, no request.
reset; flag_on; : > "$ATT"
drv 'mc_attempt_put "identityalert hub word day"; echo "rc=$?"' > "$T/o8" 2>/dev/null
grep -qx 'rc=0' "$T/o8" && ok || bad "8b: mc_attempt_put rc=$(cat "$T/o8")"
grep -qxF 'identityalert hub word day' "$ATT" && ok || bad "8b: the file line must exist: $(cat "$ATT")"
[ "$(npr)" = 0 ] && ok || bad "8b: a non-PR line must write no row: $(cat "$REQ")"

echo "== 9. mc_attempted, the production entry point, on and off =="

# TEST-CHANGE (BH-2357 / BH-2311.1): the row is asked FIRST now, so the second
# call is a GET that finds the row the first call PUT — it no longer reads the
# file alone. The case drives the CURL_STATE store (a real little table) for
# that: a scripted 404 for every request would say "no row" right after a PUT
# the route accepted, which is a wire the worker never produces.
reset; flag_on; : > "$ATT"; mkdir -p "$T/rows9"
CURL_STATE="$T/rows9" drv 'mc_attempted rebase example-org/x#12 abc; echo "one=$?"; mc_attempted rebase example-org/x#12 abc; echo "two=$?"' > "$T/o9" 2>/dev/null
grep -qx 'one=1' "$T/o9" && grep -qx 'two=0' "$T/o9" && ok \
  || bad "9a: mc_attempted must be rc 1 then rc 0: $(cat "$T/o9")"
[ "$(grep -c 'PUT http://jobs.test/api/pr-attempts' "$REQ")" = 1 ] && ok \
  || bad "9a: exactly one PUT, got $(grep -c 'PUT http://jobs.test/api/pr-attempts' "$REQ"): $(cat "$REQ")"
[ "$(grep -c 'GET http://jobs.test/api/pr-attempts' "$REQ")" = 2 ] && ok \
  || bad "9a: each call must ask the row first (2 GETs): $(cat "$REQ")"
[ "$(grep -cxF 'rebase example-org/x#12 abc' "$ATT")" = 1 ] && ok \
  || bad "9a: the row hit must not duplicate the file line: $(cat "$ATT")"

# THE DARK DEFAULT. With no flag the conductor is byte-identical to today: the
# file answers, and the only request in the sink is flag_active's reconcile.
reset; flag_off; : > "$ATT"
drv 'mc_attempted rebase example-org/x#12 abc; echo "one=$?"; mc_attempted rebase example-org/x#12 abc; echo "two=$?"' > "$T/o9" 2>/dev/null
grep -qx 'one=1' "$T/o9" && grep -qx 'two=0' "$T/o9" && ok \
  || bad "9b: with the flag off mc_attempted must be rc 1 then rc 0: $(cat "$T/o9")"
[ "$(npr)" = 0 ] && ok || bad "9b: the flag being off must make no /api/pr-* request: $(cat "$REQ")"
grep -q '/api/ledger' "$REQ" && bad "9b: no ledger read belongs here: $(cat "$REQ")" || ok
[ "$(nreq)" = 1 ] && ok \
  || bad "9b: a dark lane makes exactly one request (the flag reconcile), got: $(cat "$REQ")"
grep -qxF 'rebase example-org/x#12 abc' "$ATT" && ok || bad "9b: the file line must exist: $(cat "$ATT")"

echo "== 10. fail-closed when the client is not there at all =="

# A tree with no bin/jobs-client.sh is today's tree. mc_attempt_has must then
# be grep-only — rc 1 on a miss, and not one request anywhere.
reset; flag_on; : > "$ATT"
DRIVE_UNSET=pr_rows_on drv 'mc_attempt_has "rebase example-org/x#12 abc"; echo "miss=$?"; echo "line" >> "$MC_ATTEMPTS"; mc_attempt_has "line"; echo "hit=$?"' > "$T/o10" 2>/dev/null
grep -qx 'miss=1' "$T/o10" && ok || bad "10: with no pr_rows_on a miss must be rc 1: $(cat "$T/o10")"
grep -qx 'hit=0' "$T/o10" && ok || bad "10: with no pr_rows_on the file must still answer: $(cat "$T/o10")"
[ "$(nreq)" = 0 ] && ok || bad "10: with no pr_rows_on nothing must be requested: $(cat "$REQ")"
echo "== 11. mc_attempt_clear: the forget has to reach the row =="

# THE ONE ERASER. The stuck detector clears a line so the next tick MAY spawn a
# fresh rebase. mc_attempt_has answers a file miss from the row, so a clear that
# only rewrites the file forgets nothing the moment the flag is up: the row
# warms the line straight back and the PR is skipped for ever (BH-523/BH-764,
# the failure the NEEDS_REBASE arm exists to fix).
CLR='rebase example-org/x#12 abc'
reset; flag_on
printf '%s\nrrconsumed example-org/x#99 zzz\n' "$CLR" > "$ATT"
drv 'mc_attempt_clear rebase example-org/x#12 abc; echo "rc=$?"' > "$T/o11" 2>/dev/null
grep -qx 'rc=0' "$T/o11" && ok || bad "11a: mc_attempt_clear rc=$(cat "$T/o11")"
grep -qxF "$CLR" "$ATT" && bad "11a: the file line must be gone: $(cat "$ATT")" || ok
grep -qxF 'rrconsumed example-org/x#99 zzz' "$ATT" && ok \
  || bad "11a: only the cleared line goes: $(cat "$ATT")"
[ "$(mu "$(lastreq)")" = "DELETE http://jobs.test/api/pr-attempts?repo=$EREPO&number=12&kind=rebase&sha=abc" ] \
  && [ "$(npr)" = 1 ] && ok \
  || bad "11a: exactly one DELETE with the row's key, got: $(cat "$REQ")"

# Dark is dark here too: no flag, no request.
reset; flag_off
printf '%s\n' "$CLR" > "$ATT"
drv 'mc_attempt_clear rebase example-org/x#12 abc' >/dev/null 2>&1
grep -qxF "$CLR" "$ATT" && bad "11b: the file line must still be cleared: $(cat "$ATT")" || ok
[ "$(npr)" = 0 ] && ok || bad "11b: the flag being off must make no /api/pr-* request: $(cat "$REQ")"

# A non-PR line has no row to delete.
reset; flag_on
printf 'identityalert hub word day\n' > "$ATT"
drv 'mc_attempt_clear identityalert hub word day' >/dev/null 2>&1
[ "$(npr)" = 0 ] && ok || bad "11c: a non-PR line must send no DELETE: $(cat "$REQ")"

# An EMPTY file is not an exit. The whole point of the twin is that the file can
# be lost (a hub wipe, a restore) while the rows stay, so a clear against an
# empty file still has a row to forget.
reset; flag_on; : > "$ATT"
drv 'mc_attempt_clear rebase example-org/x#12 abc' >/dev/null 2>&1
[ "$(grep -c '^DELETE http://jobs.test/api/pr-attempts' "$REQ")" = 1 ] && ok \
  || bad "11d: an empty attempts file must not skip the row delete: $(cat "$REQ")"

# A DELETE we could not make is NOT a forget. The file has forgotten and the row
# may not have, so the twin goes blind for the rest of the process rather than
# letting the row warm the line back on the very next read.
reset; flag_on
printf '%s\n' "$CLR" > "$ATT"
CURL_MODE=down drv 'mc_attempt_clear rebase example-org/x#12 abc; echo "rc=$?"; mc_attempt_has "rebase example-org/x#12 abc"; echo "has=$?"' > "$T/o11" 2>/dev/null
grep -qx 'rc=0' "$T/o11" && ok || bad "11e: a failed DELETE must not fail the clear: $(cat "$T/o11")"
grep -qx 'has=1' "$T/o11" && ok || bad "11e: the cleared line must read as not-attempted: $(cat "$T/o11")"
[ "$(npr)" = 1 ] && ok \
  || bad "11e: after a failed DELETE the twin must be latched off, got $(npr) /api/pr- requests: $(cat "$REQ")"

# ...but a 404 IS a forget (there was no row), so it must not latch anything.
reset; flag_on
printf '%s\n' "$CLR" > "$ATT"
CURL_STATUS=404 drv 'mc_attempt_clear rebase example-org/x#12 abc; mc_attempt_has "rebase example-org/x#12 abc"; echo "has=$?"' > "$T/o11" 2>/dev/null
grep -qx 'has=1' "$T/o11" && ok || bad "11f: a 404 miss must read as not-attempted: $(cat "$T/o11")"
[ "$(npr)" = 2 ] && ok \
  || bad "11f: a 404 DELETE must NOT trip the breaker (want DELETE+GET), got $(npr): $(cat "$REQ")"

echo "== 12. three ticks against a real little table: forget, then respawn =="

# The sequence the stuck detector actually runs, each tick its own process, with
# the shim keeping REAL state: PUT stores the row, DELETE removes it, GET answers
# from what is there. File-only clearing shows up here as tick 2 answering rc 0
# — "already attempted" — which is the PR stranded for good.
mkdir -p "$T/rows"; rm -f "$T/rows"/*
reset; flag_on; : > "$ATT"
export CURL_STATE="$T/rows"
drv 'mc_attempted rebase example-org/x#12 abc; echo "tick1=$?"' > "$T/o12" 2>/dev/null
grep -qx 'tick1=1' "$T/o12" && ok || bad "12: tick 1 must be rc 1 (spawn): $(cat "$T/o12")"
[ "$(find "$T/rows" -type f | wc -l)" = 1 ] && ok || bad "12: tick 1 must leave one row: $(ls "$T/rows")"
drv 'mc_attempt_clear rebase example-org/x#12 abc' >/dev/null 2>&1
[ "$(find "$T/rows" -type f | wc -l)" = 0 ] && ok \
  || bad "12: the clear must remove the row, not just the file line: $(ls "$T/rows")"
drv 'mc_attempted rebase example-org/x#12 abc; echo "tick2=$?"' > "$T/o12" 2>/dev/null
grep -qx 'tick2=1' "$T/o12" && ok \
  || bad "12: after a clear the next tick must RESPAWN (rc 1), not skip for ever: $(cat "$T/o12")"
# And the ledger still dedupes what was not cleared: a third tick is rc 0.
drv 'mc_attempted rebase example-org/x#12 abc; echo "tick3=$?"' > "$T/o12" 2>/dev/null
grep -qx 'tick3=0' "$T/o12" && ok \
  || bad "12: an uncleared attempt must still dedupe on the next tick: $(cat "$T/o12")"
unset CURL_STATE
DRIVE_MC=0

echo "pr-rows-contract.bh-1385-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
