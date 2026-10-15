#!/bin/bash
# tests/doorbell-ringing.bh-1034-test.sh — a repo that has RUNG is armed by
# EVIDENCE, and an outage is never read as silence (BH-1034.4, audit #35).
#
# WHY THIS EXISTS. bin/doorbell-coverage-check.sh decides "is this repo's
# doorbell armed" by listing its webhooks, and our PAT cannot list hooks on
# several fleet repos — so the daily run alerts UNREADABLE for repos whose
# doorbell is demonstrably working, and the one alert that would matter sits in
# a pile of ones that do not. Rows in `wakes` can only come from a live hook, so
# the wakes table answers the same question with better evidence than the hooks
# API does, and it answers it without spending a GitHub call.
#
# The three states are the whole contract, and collapsing any two is the bug:
#   ringing  the summary named this repo -> armed, no alert, no hooks read
#   silent   the summary ANSWERED and did not name it -> today's path, verbatim
#   unknown  the worker could not answer -> today's path, verbatim
# An outage that suppressed an alert would be the same silence the doorbell
# check was written to kill, one layer up.
#
# Run from anywhere: tests/doorbell-ringing.bh-1034-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUT="$DIR/bin/doorbell-coverage-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$SUT" ] || { echo "FAIL: bin/doorbell-coverage-check.sh missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

RECEIVER="https://jobs.test/webhooks/github"
export JOBS_URL="https://jobs.test"
export HARNESS_SECRET=s
export JOBS_RETRIES=0
export HARNESS="$T/harness"
export HARNESS_ALERTS="$T/harness/logs/ALERTS.log"
mkdir -p "$HARNESS/logs" "$HARNESS/flags" "$HARNESS/env" "$T/calls"
# An EMPTY env file, deliberately: bin/lib/env-path.sh falls back to
# /etc/harness/env when $HARNESS/env is absent, and a test that picked up the
# live secret would make real requests and prove nothing about the no-secret
# case below.
: > "$HARNESS/env/global.env"
export CALLS="$T/calls" SUMMARY_JSON="$T/summary.json" SUMMARY_DOWN="$T/summary.down"

export FLEET_CONF="$T/fleet.conf"
cat > "$FLEET_CONF" <<EOF
# <project> <repo> <prod> <board-prefix> <offset> <box> <ip>
armed-proj    Test/armed      -  -  1  box-test 100.0.0.1
unreadable    Test/unreadable -  -  5  box-test 100.0.0.1
nohook-proj   Test/nohook     -  -  2  box-test 100.0.0.1
EOF

# ── the same fake `gh` the coverage suite uses, plus a call recorder ─────────
# The recorder is how "a ringing repo's hooks are not read at all" becomes an
# assertion: the saved GitHub call is half the point of reading `wakes` first.
export FIXTURES="$T/fixtures"; mkdir -p "$FIXTURES"
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'GH_EOF'
#!/bin/bash
echo "$*" >> "$CALLS/gh"
[ "${1:-}" = api ] || exit 1
shift
EP="${1:-}"; shift
JQ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q) JQ="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$EP" in
  */hooks)
    SLUG="${EP#/}"; SLUG="${SLUG#repos/}"; SLUG="${SLUG%/hooks}"
    F="$FIXTURES/${SLUG//\//_}.json"
    [ -f "$F" ] || exit 1
    if [ -n "$JQ" ]; then jq -r "$JQ" < "$F"; else cat "$F"; fi
    ;;
  repos/*|/repos/*) echo 12345 ;;
  *) exit 1 ;;
esac
GH_EOF
chmod +x "$T/fakebin/gh"

# ── curl: the summary route serves a fixture; everything else is {} 200 ──────
# `summary.down` is the outage: curl exits 7 with nothing on stdout, which is
# exactly what a dead worker looks like to bin/jobs-client.sh.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
case "$*" in
  *"/api/wakes/summary"*)
    echo "${!#}" >> "$CALLS/curl"
    [ -f "$SUMMARY_DOWN" ] && exit 7
    printf '%s\n200' "$(cat "$SUMMARY_JSON" 2>/dev/null || echo '{"repos":[]}')"
    exit 0 ;;
esac
printf '{}\n200'
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

hook() { printf '{"active":%s,"config":{"url":"%s"}}' "$1" "$2"; }
printf '[%s]\n' "$(hook true "$RECEIVER")" > "$FIXTURES/Test_armed.json"
printf '[]\n'                              > "$FIXTURES/Test_nohook.json"
# Test/unreadable gets NO fixture on purpose -> the fake gh exits 1.

summary() { printf '{"repos":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/summary.json"; }
R() { # R <repo> <n> <last_at> <kinds>
  printf '{"repo":"%s","n":%s,"last_at":"%s","kinds":"%s"}' "$1" "$2" "$3" "$4"
}
run() { OUT=$("$SUT" "$@" 2>&1); RC=$?; }
reset() {
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  : > "$HARNESS_ALERTS"; rm -f "$HARNESS"/flags/alerted-doorbell-* "$HARNESS"/flags/alerted-jobs-client-*
  rm -f "$T/summary.json" "$T/summary.down" "$HARNESS/logs/doorbell-coverage-check.log"
}
# The jobs-client writes its OWN outage line into the same ALERTS.log, so the
# doorbell's alerts are counted by their lane tag, never by line count.
doorbell_alerts() { grep -c '\[doorbell\]' "$HARNESS_ALERTS" 2>/dev/null; return 0; }
logline() { grep " $1 doorbell=" "$HARNESS/logs/doorbell-coverage-check.log" 2>/dev/null | tail -1; }

LAST="2026-09-19T21:00:00Z"   # determinism: ok a literal echoed back by the stub; nothing here reads a clock

# ───────────────────────────────────────────────────────────────────────────
# a. the CLI verb prints the TSV the doorbell reads
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R example-org/project-3 3 "$LAST" 'pr,push')"
OUT=$("$DIR/bin/jobs-client.sh" wakes-summary 24 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "wakes-summary rc=$RC, expected 0"
# BH-6799: a 5th column, last_id; a worker that sent none prints `-`.
EXPECT=$(printf 'example-org/project-3\t3\t%s\tpr,push\t-' "$LAST")
[ "$OUT" = "$EXPECT" ] && ok || bad "wakes-summary TSV wrong: $(printf '%q' "$OUT")"
# BH-6799: the worker's new answer has last_id and no n: n prints `-`.
reset; printf '{"repos":[{"repo":"example-org/project-3","last_id":4242,"last_at":"%s","kinds":"pr,push"}]}' "$LAST" > "$T/summary.json"
OUT=$("$DIR/bin/jobs-client.sh" wakes-summary 24 2>/dev/null); RC=$?
EXPECT=$(printf 'example-org/project-3\t-\t%s\tpr,push\t4242' "$LAST")
[ "$RC" = 0 ] && [ "$OUT" = "$EXPECT" ] && ok || bad "wakes-summary TSV of a last_id answer wrong: rc=$RC $(printf '%q' "$OUT")"
grep -q '/api/wakes/summary?hours=24' "$T/calls/curl" && ok \
  || bad "the hours argument did not reach the route: $(cat "$T/calls/curl" 2>/dev/null)"

# ───────────────────────────────────────────────────────────────────────────
# b. an outage is rc 1 and EMPTY stdout — never a row, never a partial line
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R example-org/project-3 3 "$LAST" pr)"; : > "$T/summary.down"
OUT=$("$DIR/bin/jobs-client.sh" wakes-summary 24 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "wakes-summary on an outage: rc=$RC, expected 1"
[ -z "$OUT" ] && ok || bad "wakes-summary printed on an outage: $OUT"

# ───────────────────────────────────────────────────────────────────────────
# c. UNREADABLE hooks + a ringing repo = armed, no alert, no GitHub call
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R Test/unreadable 3 "$LAST" 'pr,push')"
run --repo Test/unreadable --strict
[ "$RC" = 0 ] && ok || bad "ringing repo --strict: rc=$RC, expected 0"
case "$OUT" in
  *"Test/unreadable: doorbell armed (ringing, 3 wakes/24h, last $LAST)"*) ok ;;
  *) bad "ringing repo not reported armed with its evidence — $OUT" ;;
esac
case "$OUT" in *UNREADABLE*) bad "a ringing repo was still called UNREADABLE — $OUT" ;; *) ok ;; esac
[ "$(doorbell_alerts)" = 0 ] && ok || bad "a ringing repo alerted: $(cat "$HARNESS_ALERTS")"
grep -q 'Test/unreadable/hooks' "$T/calls/gh" 2>/dev/null \
  && bad "a ringing repo's hooks were read anyway: $(cat "$T/calls/gh")" || ok
case "$(logline Test/unreadable)" in
  *"doorbell=armed ring=ringing n=3 last=$LAST"*) ok ;;
  *) bad "ringing log line wrong: $(logline Test/unreadable)" ;;
esac
# BH-6799: the new answer has no count, so the line names none.
reset; printf '{"repos":[{"repo":"Test/unreadable","last_id":9,"last_at":"%s","kinds":"pr"}]}' "$LAST" > "$T/summary.json"
run --repo Test/unreadable --strict
case "$OUT" in
  *"Test/unreadable: doorbell armed (ringing, last $LAST)"*) ok ;;
  *) bad "a ringing repo with no count was not reported armed without one — $OUT" ;;
esac

# ───────────────────────────────────────────────────────────────────────────
# d. the summary ANSWERED and did not name it -> silent -> today's path
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R example-org/project-3 3 "$LAST" pr)"
run --repo Test/unreadable --strict
[ "$RC" = 0 ] && ok || bad "silent unreadable --strict: rc=$RC, expected 0"
case "$OUT" in *"Test/unreadable: doorbell UNREADABLE"*) ok ;; *) bad "silent repo lost today's verdict — $OUT" ;; esac
case "$OUT" in *"checked=1 missing=0 unreadable=1 ringing=0"*) ok ;; *) bad "silent summary line wrong — $OUT" ;; esac
[ "$(doorbell_alerts)" = 1 ] && ok || bad "silent unreadable repo: expected exactly 1 doorbell alert, got $(doorbell_alerts)"
# TEST-CHANGE (pool doctor, 2026-09-24): the remedy is the GitHub App now, not "a
# PAT with admin:repo_hook" (tests/doorbell-app-hook.pool-doctor-test.sh). The
# property pinned is unchanged: the unreadable alert names what to fix.
case "$(cat "$HARNESS_ALERTS")" in *"GitHub App"*"Webhooks: read"*) ok ;; *) bad "the unreadable alert lost its remedy: $(cat "$HARNESS_ALERTS")" ;; esac
case "$(logline Test/unreadable)" in *"doorbell=unreadable ring=silent"*) ok ;; *) bad "silent log line wrong: $(logline Test/unreadable)" ;; esac

# ───────────────────────────────────────────────────────────────────────────
# e. the worker is DOWN -> unknown -> today's path, alert included
# ───────────────────────────────────────────────────────────────────────────
# The fail-open direction that matters: an outage must never be able to SILENCE
# an alert, because then a dead worker hides a dead doorbell.
reset; : > "$T/summary.down"
run --repo Test/unreadable
[ "$(doorbell_alerts)" = 1 ] && ok || bad "an outage suppressed the unreadable alert (got $(doorbell_alerts))"
case "$(logline Test/unreadable)" in *"doorbell=unreadable ring=unknown"*) ok ;; *) bad "outage log line wrong: $(logline Test/unreadable)" ;; esac
# …and the ring read does not put a SECOND lane's alert into a detector whose
# contract is one actionable line per repo per day. The evidence is not lost:
# the jobs-client log still carries the failed call.
grep -q '\[jobs-client\]' "$HARNESS_ALERTS" \
  && bad "the optional ring read alerted: $(cat "$HARNESS_ALERTS")" || ok
grep -q 'api/wakes/summary' "$HARNESS/logs/jobs-client.log" && ok \
  || bad "the failed ring read left no trace in logs/jobs-client.log"

# ───────────────────────────────────────────────────────────────────────────
# f. the registry walk counts ringing, and every line carries its ring state
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R Test/unreadable 3 "$LAST" pr)"
run
case "$OUT" in *"checked=3 missing=1 unreadable=0 ringing=1"*) ok ;; *) bad "registry walk summary wrong — $OUT" ;; esac
grep -q 'Test/unreadable doorbell=armed ring=ringing' "$HARNESS/logs/doorbell-coverage-check.log" && ok \
  || bad "the ringing repo left no ring=ringing line"
grep -q 'Test/armed doorbell=armed ring=silent' "$HARNESS/logs/doorbell-coverage-check.log" && ok \
  || bad "a silent repo's line lost ring=silent"
[ "$RC" = 0 ] && ok || bad "registry walk rc=$RC, expected 0"
# ONE summary call for the whole registry, not one per repo.
[ "$(wc -l < "$T/calls/curl" | tr -d ' ')" = 1 ] && ok \
  || bad "expected 1 summary request for the whole walk, got $(wc -l < "$T/calls/curl")"

# ───────────────────────────────────────────────────────────────────────────
# g. DOORBELL_RING_H moves the window, and the copy says the window it used
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R Test/unreadable 2 "$LAST" pr)"
OUT=$(DOORBELL_RING_H=6 "$SUT" --repo Test/unreadable 2>&1); RC=$?
grep -q 'hours=6' "$T/calls/curl" && ok || bad "DOORBELL_RING_H did not reach the route: $(cat "$T/calls/curl")"
case "$OUT" in *"2 wakes/6h"*) ok ;; *) bad "the report claims a window it did not ask for — $OUT" ;; esac

# ───────────────────────────────────────────────────────────────────────────
# h. the matcher: case-insensitive on the WHOLE slug, and nothing else
# ───────────────────────────────────────────────────────────────────────────
# This matcher suppresses an alert, so a loose match is a doorbell nobody is
# watching. Inverse case must ring; a prefix or a longer sibling must not.
reset; summary "$(R example-org/UNREADABLE 1 "$LAST" pr)"
run --repo Test/unreadable
case "$OUT" in *"doorbell armed (ringing"*) bad "case matched the wrong repo (Test/unreadable vs example-org/UNREADABLE) — $OUT" ;; *) ok ;; esac

reset; summary "$(R test/UNREADABLE 1 "$LAST" pr)"
run --repo Test/unreadable
case "$OUT" in *"doorbell armed (ringing"*) ok ;; *) bad "an inverse-case slug did not ring — $OUT" ;; esac

reset; summary "$(R Test/unreadabl 9 "$LAST" pr)" "$(R Test/unreadable-2 9 "$LAST" pr)"
run --repo Test/unreadable
case "$OUT" in *"doorbell armed (ringing"*) bad "a prefix/sibling slug rang the wrong repo — $OUT" ;; *) ok ;; esac
case "$OUT" in *UNREADABLE*) ok ;; *) bad "the neighbour match ate today's verdict — $OUT" ;; esac

reset; printf '{"repos":[]}' > "$T/summary.json"
run --repo Test/unreadable
case "$(logline Test/unreadable)" in *ring=silent*) ok ;; *) bad "an empty repos list is silence, not unknown: $(logline Test/unreadable)" ;; esac

# HARNESS_SECRET unset is what keeps tests/doorbell-coverage-test.sh green: no
# secret, no request, `unknown`, and the script behaves exactly as it did.
reset; summary "$(R Test/unreadable 3 "$LAST" pr)"
OUT=$(env -u HARNESS_SECRET "$SUT" --repo Test/unreadable 2>&1); RC=$?
case "$(logline Test/unreadable)" in *ring=unknown*) ok ;; *) bad "no secret must be unknown: $(logline Test/unreadable)" ;; esac
case "$OUT" in *UNREADABLE*) ok ;; *) bad "no secret must fall through to today's path — $OUT" ;; esac

echo "doorbell-ringing-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
