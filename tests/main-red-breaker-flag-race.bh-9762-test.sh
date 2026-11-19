#!/bin/bash
# tests/main-red-breaker-flag-race.bh-9762-test.sh — BH-9762: the main-red
# breaker must not file a hotfix ticket from a flag that cleared or changed
# between the loop's read and file_ticket's read.
#
# #9762 was filed as "main is red since  (workflow `unknown`, sha ``, reason ``)"
# with the marker `<slug>@`: the loop judged the flag (since + sha present),
# then pause ran its GitHub calls, and bin/main-red-detector.sh removed the
# flag (main went green). file_ticket and compose re-read the LIVE flag and got
# empty fields for every key.
#
# WHAT IS REAL: bin/main-red-breaker.sh and its closure, as in the 8706 suite.
# WHAT IS FAKED: tests/fixtures/main-red-breaker/fixture.sh (0 network), plus a
# per-case wrapper (written into the case dir) that changes the flag file on
# the lane's FIRST gh_rest call, which is inside pause, after the loop read.
#
# Cases: A flag deleted mid-tick, B flag rewritten with a new since, C flag
# unchanged, D empty flag file, E same since with a new sha, F the flag
# goes away before the loop copies it.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/main-red-breaker-flag-race.bh-9762-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FAKE="$DIR/tests/fixtures/main-red-breaker/fake_gh.py"
FIX="$DIR/tests/fixtures/main-red-breaker/fixture.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; return 1; fi; }

S=example-owner/example-repo
HR=example-owner/example-harness
RSHA=1111111111111111111111111111111111111111
RSHA2=3333333333333333333333333333333333333333
GSHA=2222222222222222222222222222222222222222
SINCE=2026-10-28T10:00:00Z
SINCE2=2026-10-28T12:00:00Z
FLAGNAME="main-red-$(echo "$S" | tr '/' '-')"

TPL="$T/tpl"; mkdir -p "$TPL/bin"
printf '#!/bin/bash\necho "$*" >> "$MRBK_F/alerts"\n' > "$TPL/bin/lane-alert.sh"; chmod +x "$TPL/bin/lane-alert.sh"
scratch_install_closure bin/main-red-breaker.sh "$TPL" >/dev/null || echo "FAIL: scratch_install_closure bin/main-red-breaker.sh"

# fresh <name> — a new case: H (harness), F (fixture dir), W (the race wrapper).
fresh() {
  C="$T/c-$1"; H="$C/h"; F="$C/f"; W="$C/race-fixture.sh"
  mkdir -p "$C" "$F"; cp -a "$TPL" "$H"; mkdir -p "$H/flags" "$H/logs" "$H/state"
  { echo "# project repo prod board offset box ip"
    echo "exrepo  $S  -  -  1 box-fixture 192.0.2.1"; } > "$H/fleet.conf"
  : > "$F/calls"; : > "$F/ledger.calls"; : > "$F/alerts"
  # The wrapper: the real fixture, then a gh_rest that runs $MRBK_RACE once
  # (on the first call) before it answers through the real fake.
  cat > "$W" <<EOF
. "$FIX"
eval "__race_real_gh_rest() \$(declare -f gh_rest | tail -n +2)"
gh_rest() {
  if [ -n "\${MRBK_RACE:-}" ] && [ ! -e "\$MRBK_F/raced" ]; then
    : > "\$MRBK_F/raced"
    eval "\$MRBK_RACE"
  fi
  __race_real_gh_rest "\$@"
}
# MRBK_RACE_AUTH runs once in the identity check, which the loop calls after
# its [ -f flag ] test and before it copies the flag.
eval "__race_real_auth() \$(declare -f gh_default_auth_for_slug | tail -n +2)"
gh_default_auth_for_slug() {
  if [ -n "\${MRBK_RACE_AUTH:-}" ] && [ ! -e "\$MRBK_F/raced-auth" ]; then
    : > "\$MRBK_F/raced-auth"
    eval "\$MRBK_RACE_AUTH"
  fi
  __race_real_auth "\$@"
}
EOF
}
fx() { python3 -I "$FAKE" "$F" "$@"; }
# flag [sha] [since] — the detector's flag format (bin/main-red-detector.sh).
flag() {
  local sha="${1-$RSHA}" since="${2:-$SINCE}"
  { echo "sha=$sha"; echo "workflow=CI"; echo "path=.github/workflows/ci.yml"; echo "job=unit"
    echo "since=$since"; echo "streak=2"; echo "run=https://github.com/$S/actions/runs/9001"
    echo "detected=$since"; echo "reason=streak"; } > "$H/flags/$FLAGNAME"
}
run() {
  env HARNESS="$H" HARNESS_TEST_SANDBOX=1 MAIN_RED_BREAKER_FIXTURE="$W" MRBK_F="$F" MRBK_FAKE="$FAKE" \
      JOBS_URL= HARNESS_SECRET= HARNESS_REPO="$HR" GH_TOKEN= TMPDIR="$C" "$@" bash "$H/bin/main-red-breaker.sh" "$S" 2>>"$C/stderr"
}
calls()  { grep -c -- "$1" "$F/calls"; }
lput()   { grep -c -- "^put $1" "$F/ledger.calls"; }
logged() { grep -c -- "$1" "$H/logs/main-red-breaker.log" 2>/dev/null; }
noun()   { ! grep -q UNFAKED "$F/calls"; }
noalert() { [ ! -s "$F/alerts" ]; }
seed_ticket() { # the jobs, annotations, last green and compare of run 9001
  fx set "jobs:9001" '{"jobs":[{"id":501,"name":"unit","conclusion":"failure","html_url":"https://github.com/'"$S"'/actions/runs/9001/job/501","steps":[{"name":"Run tests","conclusion":"failure"}]}]}'
  fx set "ann:501" '[]'
  fx set "green:ci.yml" "\"$GSHA\""
  fx set "compare:$GSHA...$RSHA" '{"commits":[{"sha":"aaaaaaaaaaaaaaaa","commit":{"message":"Merge pull request #41 from example-owner/ticket/a"}}]}'
  fx set "compare:$GSHA...$RSHA2" '{"commits":[{"sha":"aaaaaaaaaaaaaaaa","commit":{"message":"Merge pull request #41 from example-owner/ticket/a"}}]}'
}
FL='$HARNESS/flags/'"$FLAGNAME"

# ── A: the detector removes the flag mid-tick (main went green) ──────────────
fresh a; flag; seed_ticket; fx add "$S" 1 merge-queue
run MRBK_RACE="rm -f \"$FL\""
check "A the race fired" '[ -e "$F/raced" ] && [ ! -e "$H/flags/$FLAGNAME" ]'
check "A no issue POST" '[ "$(calls "POST repos/$S/issues$")" = 0 ]' \
  || { echo "--- A filed this body (the #9762 shape):"; fx created | jq -r '.[0].body' | grep -E "is red since|<!-- main-red-breaker"; }
check "A no main_red_hotfix put" '[ "$(lput main_red_hotfix)" = 0 ]'
check "A the log says nothing filed" '[ "$(logged "nothing filed")" -ge 1 ]'
check "A no alert" noalert
check "A no UNFAKED path" noun

# ── B: the detector rewrites the flag with a new since mid-tick ──────────────
fresh b; flag; seed_ticket; fx add "$S" 1 merge-queue
run MRBK_RACE="sed -i 's/^since=.*/since=$SINCE2/' \"$FL\""
check "B the race fired" '[ -e "$F/raced" ] && grep -qx "since=$SINCE2" "$H/flags/$FLAGNAME"'
check "B tick 1: no issue POST" '[ "$(calls "POST repos/$S/issues$")" = 0 ]'
check "B tick 1: no main_red_hotfix put" '[ "$(lput main_red_hotfix)" = 0 ]'
check "B tick 1: the log says the flag changed" '[ "$(logged "the flag cleared or changed mid-tick — nothing filed")" = 1 ]'
check "B tick 1: no alert" noalert
run
fx created > "$C/created.json"
check "B tick 2: one issue POST" '[ "$(calls "POST repos/$S/issues$")" = 1 ]'
check "B tick 2: the marker carries the new since" '[ "$(jq -r ".[0].body" "$C/created.json" | grep -cxF "<!-- main-red-breaker: $S@$SINCE2 -->")" = 1 ]'
check "B no UNFAKED path" noun

# ── C: the flag does not change: one ticket from the one read ────────────────
fresh c; flag; seed_ticket; fx add "$S" 1 merge-queue
run
fx created > "$C/created.json"
B=$(jq -r '.[0].body' "$C/created.json")
check "C one issue POST" '[ "$(calls "POST repos/$S/issues$")" = 1 ]'
check "C the title" '[ "$(jq -r ".[0].title" "$C/created.json")" = "HOTFIX: $S main is red — CI / unit" ]'
check "C the body carries since, sha and workflow" 'grep -qF "is red since $SINCE (workflow \`CI\`, sha \`111111111111\`, reason \`streak\`)" <<<"$B"'
check "C the marker" 'grep -qxF "<!-- main-red-breaker: $S@$SINCE -->" <<<"$B"'
check "C the log says filed" '[ "$(logged "ticket: filed https://github.com/$S/issues/")" = 1 ]'
check "C no UNFAKED path" noun

# ── D: the flag file is empty at the start (a truncated, non-atomic write) ───
fresh d; : > "$H/flags/$FLAGNAME"; seed_ticket; fx add "$S" 1 merge-queue
run
check "D no issue POST" '[ "$(calls "POST repos/$S/issues$")" = 0 ]'
check "D no main_red_hotfix row read or put" '[ "$(grep -c "main_red_hotfix" "$F/ledger.calls")" = 0 ]'
check "D no alert" noalert
check "D no UNFAKED path" noun

# ── E: same since, new sha (the detector keeps since on a new red sha) ───────
fresh e; flag; seed_ticket; fx add "$S" 1 merge-queue
run MRBK_RACE="sed -i 's/^sha=.*/sha=$RSHA2/' \"$FL\""
fx created > "$C/created.json"
B=$(jq -r '.[0].body' "$C/created.json")
check "E the race fired" '[ -e "$F/raced" ] && grep -qx "sha=$RSHA2" "$H/flags/$FLAGNAME"'
check "E one issue POST" '[ "$(calls "POST repos/$S/issues$")" = 1 ]'
check "E the body carries the snapshot sha" 'grep -qF "sha \`111111111111\`" <<<"$B" && ! grep -qF "333333333333" <<<"$B"'
check "E the marker" 'grep -qxF "<!-- main-red-breaker: $S@$SINCE -->" <<<"$B"'
check "E no UNFAKED path" noun

# ── F: the flag goes away between the loop's -f test and its copy ───────────
fresh f; flag; seed_ticket; fx add "$S" 1 merge-queue
run MRBK_RACE_AUTH="rm -f \"$FL\""
check "F the race fired" '[ -e "$F/raced-auth" ] && [ ! -e "$H/flags/$FLAGNAME" ]'
check "F the log says skipped" '[ "$(logged "the flag went away before it was read — skipped")" = 1 ]'
check "F no pause, no issue POST" '[ "$(calls "POST repos/$S/issues")" = 0 ] && [ "$(lput main_red_breaker)" = 0 ]'
check "F no main_red_hotfix row read or put" '[ "$(grep -c "main_red_hotfix" "$F/ledger.calls")" = 0 ]'
check "F no alert" noalert
check "F no UNFAKED path" noun

for c in a b c d e f; do
  check "no stderr in case $c" '[ ! -s "$T/c-$c/stderr" ]'
done
[ "$FAIL" = 0 ] || { echo "--- stderr of a:"; head -20 "$T/c-a/stderr" 2>/dev/null; }
echo "main-red-breaker-flag-race.bh-9762: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
