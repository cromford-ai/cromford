#!/bin/bash
# tests/jobs-client-rehydrate-boundary.bh-1042-test.sh — log_rehydrate's cursor
# and the stamps it is compared against are ONE format (BH-1042, audit fact #29).
#
# WHY THIS EXISTS. `bin/decision-log.sh` and `bin/findings-log.sh` stamp their
# lines `date -u '+%Y-%m-%d %H:%M:%SZ'` — a SPACE between the date and the time.
# `log_rehydrate` asked for its window with `+%Y-%m-%dT%H:%M:%SZ` — a `T`. The
# worker does not parse either one: `listLines` (worker/jobs/src/index.js) binds
# the cursor straight into `stamp >= ?`, a SQLite STRING compare. A space (0x20)
# sorts before a `T` (0x54), so every row stamped on the boundary day itself
# fell outside the window. One day at the far edge of every rehydrate, silently,
# on a verb whose whole job is "recreate the log the hub wipe took with it".
# bin/repeat-family.sh reads that log and answered NOT MEASURED while the rows
# existed.
#
# THE RULE UNDER TEST: the cursor `log_rehydrate` sends, once URL-decoded, is
# byte-compatible with the stamps those two writers produce, and a row stamped
# on the boundary day AFTER the cursor's own time-of-day comes back.
#
# WHY DRIVEN AND NOT GREPPED. A regex over the `date` format string in
# bin/jobs-client.sh would pass on a client that sends the right cursor and then
# writes the rows somewhere else, and it would say nothing about whether the
# WORKER's comparison keeps the row. So the shim here IS the worker's rule:
# `stamp >= since` as strings, on rows the real writers could have produced, and
# every claim below is about the file log_rehydrate wrote or the line it logged.
#
# Run from anywhere: tests/jobs-client-rehydrate-boundary.bh-1042-test.sh
# (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

# The clock is read ONCE and every fixture stamp derives from it
# (bin/test-determinism-lint.sh's pin). Nothing here compares against a literal
# date: the window is relative by construction, because the verb's argument is.
NOW=$(date -u +%s)
DAYS=14
AS_OF=2026-09-17T00:00:00Z      # the worker's own answer stamp, absolute

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/state" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"

ROWS="$T/rows.json"          # what the fixture table holds
SINCE_SINK="$T/since.txt"    # the DECODED cursor of every request
REQ_LOG="$T/req.log"         # METHOD + raw URL

# The worker's half of the contract, in the shape worker/jobs/src/index.js
# really serves: `{rows, truncated, as_of}`, rows selected by the SAME string
# comparison listLines binds (`stamp >= since`), ordered by stamp, capped at
# `limit` with `truncated` MEASURED rather than guessed.
cat > "$T/shim.py" <<'PY'
import json, sys, urllib.parse
url, rowsf, sink, as_of = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query, keep_blank_values=True)
since = q.get("since", [""])[0]
with open(sink, "a") as f:
    f.write(since + "\n")
try:
    lim = int(q.get("limit", ["200"])[0])
except ValueError:
    lim = 200
rows = json.load(open(rowsf))
sel = sorted([r for r in rows if str(r.get("stamp", "")) >= since],
             key=lambda r: str(r.get("stamp", "")))
print(json.dumps({"rows": sel[:lim], "truncated": len(sel) > lim, "as_of": as_of}))
print(200)
PY

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) shift 2 ;;
    -H|-m|--connect-timeout|-w) shift 2 ;;
    -sS|-S|-s) shift ;;
    *) URL="$1"; shift ;;
  esac
done
printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_LOG"
python3 "$SHIM_PY" "$URL" "$ROWS_JSON" "$SINCE_SINK" "$AS_OF_STAMP"
SH
chmod +x "$T/fakebin/curl"

client() { # client <verb> [args...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.test JOBS_BOX=testbox \
           REQ_LOG="$REQ_LOG" SHIM_PY="$T/shim.py" ROWS_JSON="$ROWS" \
           SINCE_SINK="$SINCE_SINK" AS_OF_STAMP="$AS_OF"
    bash "$T/bin/jobs-client.sh" "$@" )
}
cursor()  { tail -1 "$SINCE_SINK" 2>/dev/null; }
lastreq() { tail -1 "$REQ_LOG" 2>/dev/null; }

# ── the fixture rows, in the writers' own format ─────────────────────────────
# STAMP renders exactly what bin/decision-log.sh:21 and bin/findings-log.sh:84
# write: `date -u '+%Y-%m-%d %H:%M:%SZ'`.
STAMP() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
DAYSEC=86400
BASE=$((NOW - DAYS * DAYSEC))     # the moment the cursor names

# THE BOUNDARY ROW. It sits on the cursor's own day, two minutes AFTER the
# time-of-day the cursor will carry, so by the worker's own `stamp >= since`
# rule it is inside the window — whatever the wall clock says when this runs.
# (The one moment that moves it off that day is the last two minutes of a UTC
# day, which rolls it onto the NEXT date. That makes the case pass rather than
# fail: it never produces a red nobody chose.)
S_BOUNDARY=$(STAMP $((BASE + 120)))
S_INSIDE=$(STAMP $((BASE + DAYSEC)))        # a day further in — never in doubt
S_OUTSIDE=$(STAMP $((BASE - DAYSEC)))       # a day further back — never in window

jq -nc --arg b "$S_BOUNDARY" --arg i "$S_INSIDE" --arg o "$S_OUTSIDE" \
  '[{stamp:$o, line:"[x-os] review :: OUT-1 :: outside the window"},
    {stamp:$b, line:"[x-os] review :: BND-1 :: the boundary day"},
    {stamp:$i, line:"[x-os] review :: IN-1 :: well inside"}]' > "$ROWS"

# ── R1. the cursor is the writers' format ────────────────────────────────────
: > "$SINCE_SINK"; : > "$REQ_LOG"
rm -f "$T/logs/findings.log"
client log-rehydrate findings "$T/logs/findings.log" "$DAYS" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "log_rehydrate rc=$RC (want 0) — cursor $(cursor)"
CUR=$(cursor)
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$CUR"; then ok; else
  bad "the decoded cursor must be the stamp format bin/decision-log.sh writes (\`YYYY-MM-DD HH:MM:SSZ\`), got: [$CUR]"
fi
[ "${CUR:0:10}" = "$(date -u -d "@$BASE" '+%Y-%m-%d')" ] && ok \
  || bad "the cursor must name the day $DAYS days back, got [$CUR]"
# …and the space survives the wire. @uri encodes it %20; the worker's
# searchParams decodes it; str(...,32) keeps all 20 characters.
case "$(lastreq)" in
  *"since=$(date -u -d "@$BASE" '+%Y-%m-%d')%20"*) ok ;;
  *) bad "the raw query must carry the encoded space: $(lastreq)" ;;
esac

# ── R2. the boundary day rehydrates, the day before it does not ──────────────
: > "$SINCE_SINK"; : > "$REQ_LOG"
rm -f "$T/logs/findings.log" "$T/logs/jobs-client.log"
client log-rehydrate findings "$T/logs/findings.log" "$DAYS" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "log_rehydrate rc=$RC on the boundary fixture"
printf '%s [x-os] review :: BND-1 :: the boundary day\n%s [x-os] review :: IN-1 :: well inside\n' \
  "$S_BOUNDARY" "$S_INSIDE" > "$T/expected.log"
if cmp -s "$T/expected.log" "$T/logs/findings.log"; then ok; else
  bad "the boundary-day row must land. cursor=[$(cursor)]
 want: $(cat "$T/expected.log")
 got:  $(cat "$T/logs/findings.log" 2>/dev/null)"
fi
grep -q 'rehydrated 2 findings rows (truncated=false)' "$T/logs/jobs-client.log" 2>/dev/null \
  && ok || bad "the summary line must count both rows: $(cat "$T/logs/jobs-client.log" 2>/dev/null)"
# THE NEGATIVE: a row one day OUTSIDE the window must stay outside. A cursor
# that simply reached further back would satisfy R2 and be wrong.
grep -q 'OUT-1' "$T/logs/findings.log" 2>/dev/null \
  && bad "a row outside the $DAYS-day window was rehydrated: $(cat "$T/logs/findings.log")" || ok

# ── R3. the neighbours the cursor change must not move ───────────────────────
# An existing non-empty file is never refetched, and an unknown kind never
# becomes a path segment. Both are contract, both are one line from the cursor.
: > "$REQ_LOG"
printf 'already here\n' > "$T/logs/decisions.log"
client log-rehydrate decisions "$T/logs/decisions.log" "$DAYS" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "a present log must be left alone, rc=$RC"
[ ! -s "$REQ_LOG" ] && ok || bad "a present log must make no request: $(cat "$REQ_LOG")"
[ "$(cat "$T/logs/decisions.log")" = "already here" ] && ok \
  || bad "a present log must not be rewritten: $(cat "$T/logs/decisions.log")"

echo "jobs-client-rehydrate-boundary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
