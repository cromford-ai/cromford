#!/bin/bash
# tests/gh-rest-quota-test.sh — BH-1484: the GitHub quota ledger and the reserve.
#
# WHAT IS BEING PINNED (measured 2026-09-22 17:00Z). The hub and the pool boxes
# run every lane under ONE GitHub App installation, so every repo's token draws
# on the SAME primary bucket: 6,600 an hour, burning ~5,700. The bucket empties
# in the last five minutes of every window and the only symptom is a burst of
# "UNVERIFIABLE (HTTP 000)" lines in merge-conductor.log — decision paths
# skipping a tick. Nobody read `X-RateLimit-*`, nothing ledgered a call, so the
# quota was invisible until it was gone and no lane could be blamed.
#
# Three things are asserted here and each one is a separate failure mode:
#   1. the headers reach the caller's shell (the same scope rule as
#      GH_REST_STATUS: gh_rest is run as a plain command, never inside `$( )`);
#   2. every call leaves ONE append-only ledger line, a 304 marked counted=0,
#      and a ledger that cannot be written NEVER fails the caller;
#   3. below the reserve an OPTIONAL read is refused BEFORE the request is
#      issued — the assertion that matters is that `gh` was not invoked at all,
#      because a gate that runs after the response has already spent the call.
#
# Nothing here touches the network or the wall clock. `gh` is a stub on PATH
# that replays queued fixture responses and records its own argv (the same stub
# shape tests/gh-rest-lib-test.sh uses), the ledger is found by GLOB rather than
# by computing an hour name, and every age fixture is derived from one captured
# NOW.
#
# Run from anywhere: bash tests/gh-rest-quota-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/gh-rest.sh"
REPORT="$DIR/bin/gh-quota-report.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/tmp" "$T/bin" "$T/fx"
export TMPDIR="$T/tmp"
export PATH="$T/bin:$PATH"
export GH_STUB_DIR="$T"
# The ETag cache is a second, independent feature; every row below is about the
# quota, so conditional requests are switched off and a 304 is produced on
# purpose by a fixture rather than by cache state.
export GH_ETAG=0

# ── the stub `gh` ────────────────────────────────────────────────────────────
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
D="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$D/gh-calls.txt"
f=$(find "$D/fx" -maxdepth 1 -type f -name '[0-9][0-9]' 2>/dev/null | sort | head -1)
[ -n "$f" ] || exit 1
rc=0
[ -f "$f.rc" ] && rc=$(cat "$f.rc")
cat "$f"
rm -f "$f" "$f.rc"
exit "$rc"
STUB
chmod +x "$T/bin/gh"

FXN=0
fx() { # fx <status> <remaining> <limit> <reset> [body] [extra header line]
  FXN=$((FXN + 1))
  local f rc
  f="$T/fx/$(printf '%02d' "$FXN")"
  { printf 'HTTP/2.0 %s Status\r\n' "$1"
    [ "${2:-}" = - ] || printf 'x-ratelimit-remaining: %s\r\n' "$2"
    [ "${3:-}" = - ] || printf 'X-RateLimit-Limit: %s\r\n' "$3"
    [ "${4:-}" = - ] || printf 'x-ratelimit-reset: %s\r\n' "$4"
    [ -n "${6:-}" ] && printf '%s\r\n' "$6"
    printf '\r\n'
    printf '%s' "${5:-}"
  } > "$f"
  case "$1" in 2*|304) rc=0 ;; *) rc=1 ;; esac
  printf '%s' "$rc" > "$f.rc"
}
reset() { rm -rf "$T/fx"; mkdir -p "$T/fx"; FXN=0; rm -f "$T/gh-calls.txt" "$T/out"; }
ncalls() { if [ -f "$T/gh-calls.txt" ]; then wc -l < "$T/gh-calls.txt" | tr -d ' '; else echo 0; fi; }
LED="$T/h/state/gh-rest-ledger"
# The path is spelled out under $T on this one line so checks/tests-scratch-only
# can SEE that the recursive rm lives inside the scratch tree — the check reads
# the rm's own argument, and `$LED` is a name it cannot follow. Every call site
# below says `ledreset`, which removes nothing this file did not create.
ledreset() { rm -rf "$T/h/state/gh-rest-ledger"; mkdir -p "$T/h/state/gh-rest-ledger"; }
ledger() { cat "$LED"/*.tsv 2>/dev/null; }
nled() { ledger | grep -c . 2>/dev/null || echo 0; }
col() { ledger | sed -n "${1}p" | cut -f"$2"; }

. "$LIB" || { echo "could not source $LIB"; exit 1; }

# ══ 1. the headers reach the caller's shell ═════════════════════════════════
reset
fx 200 4210 6600 1790000000 '{"ok":true}'
gh_rest GET repos/o/r/pulls/12 > "$T/out"
rc=$?
[ "$rc" = 0 ] || bad "1a: a 200 must still be rc 0, got $rc"
[ "$rc" = 0 ] && ok
if [ "${GH_REST_QUOTA_REMAINING:-}" = 4210 ]; then ok
else bad "1b: X-RateLimit-Remaining must land in GH_REST_QUOTA_REMAINING, got '${GH_REST_QUOTA_REMAINING:-}'"; fi
if [ "${GH_REST_QUOTA_LIMIT:-}" = 6600 ]; then ok
else bad "1c: X-RateLimit-Limit must land in GH_REST_QUOTA_LIMIT, got '${GH_REST_QUOTA_LIMIT:-}'"; fi
if [ "${GH_REST_QUOTA_RESET:-}" = 1790000000 ]; then ok
else bad "1d: X-RateLimit-Reset must land in GH_REST_QUOTA_RESET, got '${GH_REST_QUOTA_RESET:-}'"; fi
# The body is untouched: the quota read must not change what the caller prints.
if [ "$(cat "$T/out")" = '{"ok":true}' ]; then ok
else bad "1e: the body must be printed byte for byte, got '$(cat "$T/out")'"; fi

# A 403 carrying Retry-After is the shape a secondary limit answers with.
reset
fx 403 0 6600 1790000000 '{"message":"API rate limit exceeded"}' 'Retry-After: 60'
gh_rest GET repos/o/r/pulls > "$T/out"; rc=$?
[ "$rc" = 75 ] && ok || bad "1f: a 403 must stay rc 75, got $rc"
if [ "${GH_REST_QUOTA_RETRY_AFTER:-}" = 60 ]; then ok
else bad "1g: Retry-After must land in GH_REST_QUOTA_RETRY_AFTER, got '${GH_REST_QUOTA_RETRY_AFTER:-}'"; fi
if [ "$GH_REST_REASON" = rate-limit ]; then ok
else bad "1h: the existing rate-limit classification must survive, got '$GH_REST_REASON'"; fi

# A response with NO quota headers leaves the vars EMPTY, never 0: zero
# remaining is the one thing an unknown must not read as.
reset
fx 200 - - - '{"ok":true}'
gh_rest GET repos/o/r/issues/7 > "$T/out"
if [ -z "${GH_REST_QUOTA_REMAINING:-}" ]; then ok
else bad "1i: no header must leave the var empty, not '${GH_REST_QUOTA_REMAINING:-}'"; fi

# ══ 2. one ledger line per call, and its shape ══════════════════════════════
ledreset; reset
fx 200 4000 6600 1790000000 '{"ok":true}'
HARNESS_LANE=merge-conductor HARNESS_LANE_PROJECT=project-4 \
  gh_rest GET repos/example-org/project-4/pulls/1284 > "$T/out"
if [ "$(nled)" = 1 ]; then ok; else bad "2a: exactly one ledger line per call, got $(nled)"; fi
# SPEC CHANGE (BH-1574): 10 -> 14. The line grew four columns at its END —
# resource (X-RateLimit-Resource: core|graphql), source (rest|gh), used, limit —
# so the fleet report can split the token's REST bucket from its GraphQL one.
# Columns 1-10 are unchanged and every assertion below still reads them.
if [ "$(ledger | awk -F'\t' '{print NF}')" = 14 ]; then ok
else bad "2b: the ledger line must carry 14 tab-separated columns, got $(ledger | awk -F'\t' '{print NF}')"; fi
# ts lane project method path-class status counted remaining reset bucket resource source used limit
if grep -qE '^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$' <<<"$(col 1 1)"; then ok
else bad "2c: column 1 must be a UTC ISO timestamp, got '$(col 1 1)'"; fi
[ "$(col 1 2)" = merge-conductor ] && ok || bad "2d: column 2 is the lane, got '$(col 1 2)'"
[ "$(col 1 3)" = project-4 ] && ok || bad "2e: column 3 is the project, got '$(col 1 3)'"
[ "$(col 1 4)" = GET ] && ok || bad "2f: column 4 is the method, got '$(col 1 4)'"
[ "$(col 1 5)" = "repos/example-org/project-4/pulls/N" ] && ok \
  || bad "2g: column 5 is the path CLASS, got '$(col 1 5)'"
[ "$(col 1 6)" = 200 ] && ok || bad "2h: column 6 is the status, got '$(col 1 6)'"
[ "$(col 1 7)" = 1 ] && ok || bad "2i: a fresh 200 is counted=1, got '$(col 1 7)'"
[ "$(col 1 8)" = 4000 ] && ok || bad "2j: column 8 is remaining, got '$(col 1 8)'"
[ "$(col 1 9)" = 1790000000 ] && ok || bad "2k: column 9 is reset, got '$(col 1 9)'"
# Column 10 is the BUCKET those two numbers belong to. Without it a file of
# bare remainings from a lane whose token ladder switched repos mid-tick is a
# burn-down of several different meters added together.
[ "$(col 1 10)" = pat-default ] && ok \
  || bad "2k2: column 10 is the bucket; with no GH_TOKEN that is pat-default, got '$(col 1 10)'"
reset
fx 200 3000 6600 1790000000 '{"ok":true}'
GH_TOKEN=ghs_exampleinstallationtoken gh_rest GET repos/o/r/pulls > "$T/out"
[ "$(col 2 10)" = app ] && ok \
  || bad "2k3: a ghs_ installation token spends from the shared app bucket, got '$(col 2 10)'"
# A PAT is named by a HASH of its value and never by the value: a ledger line is
# world-readable on the box and a token in it would be a leak.
reset
fx 200 4900 5000 1790000000 '{"ok":true}'
GH_TOKEN=ghp_notarealpatvalue gh_rest GET repos/o/r/pulls > "$T/out"
case "$(col 3 10)" in
  pat-*) ok ;;
  *) bad "2k4: a non-installation token is a pat-<hash> bucket, got '$(col 3 10)'" ;;
esac
if ! grep -q 'ghp_notarealpatvalue' <<<"$(ledger)"; then ok
else bad "2k5: a token value must never reach a ledger line"; fi
# The file is named for the UTC HOUR and is append-only.
if [ "$(find "$LED" -maxdepth 1 -name '*.tsv' | wc -l | tr -d ' ')" = 1 ]; then ok
else bad "2l: one hour file, got $(find "$LED" -maxdepth 1 -name '*.tsv' | wc -l | tr -d ' ')"; fi
if find "$LED" -maxdepth 1 -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9].tsv' | grep -q .; then ok
else bad "2m: the ledger file must be named <utc-hour>.tsv, got $(ls "$LED")"; fi
reset
fx 200 3999 6600 1790000000 '{"ok":true}'
gh_rest GET repos/o/r/pulls > "$T/out"
[ "$(nled)" = 4 ] && ok || bad "2n: the ledger appends, it never rewrites — got $(nled) line(s)"

# A lane that exports nothing still gets a name (the script), never a blank.
ledreset; reset
fx 200 3990 6600 1790000000 '{"ok":true}'
( unset HARNESS_LANE HARNESS_LANE_PROJECT; gh_rest GET repos/o/r/pulls > "$T/out" )
if [ -n "$(col 1 2)" ] && [ "$(col 1 2)" != '-' ]; then ok
else bad "2o: with no HARNESS_LANE the lane column falls back to \$0, got '$(col 1 2)'"; fi

# ══ 3. a 304 is counted=0 ═══════════════════════════════════════════════════
# GitHub does not charge a conditional request that answers 304, so a ledger
# that counted it would over-report every cached read and hide the real burn.
ledreset; reset
fx 304 3980 6600 1790000000 ''
GH_ETAG=0 gh_rest GET repos/o/r/pulls/9 > "$T/out"
[ "$(nled)" = 1 ] && ok || bad "3a: a 304 is still one ledger line, got $(nled)"
[ "$(col 1 6)" = 304 ] && ok || bad "3b: the status column says 304, got '$(col 1 6)'"
[ "$(col 1 7)" = 0 ] && ok || bad "3c: a 304 must be counted=0, got '$(col 1 7)'"

# ══ 4. the path class ═══════════════════════════════════════════════════════
if command -v gh_rest_path_class >/dev/null 2>&1; then ok
else bad "4a: gh_rest_path_class must be defined"; fi
pc() { gh_rest_path_class "$1" 2>/dev/null; }
[ "$(pc repos/o/r/pulls/1284)" = "repos/o/r/pulls/N" ] && ok \
  || bad "4b: a digit run collapses to one N, got '$(pc repos/o/r/pulls/1284)'"
[ "$(pc repos/o/r/issues/7/comments)" = "repos/o/r/issues/N/comments" ] && ok \
  || bad "4c: got '$(pc repos/o/r/issues/7/comments)'"
[ "$(pc repos/o/r/commits/0123456789abcdef0123456789abcdef01234567/status)" \
   = "repos/o/r/commits/SHA/status" ] && ok \
  || bad "4d: a 40-hex sha collapses to SHA, not to N: got '$(pc repos/o/r/commits/0123456789abcdef0123456789abcdef01234567/status)'"
[ "$(pc 'repos/o/r/pulls?state=open&per_page=100')" = "repos/o/r/pulls" ] && ok \
  || bad "4e: the query string is dropped, got '$(pc 'repos/o/r/pulls?state=open&per_page=100')'"
# A repo whose NAME contains digits must not become a second class per repo —
# the class is what makes "who burns it" answerable, and o/r2 vs o/r3 splitting
# into two rows is the same as not classing at all.
[ "$(pc repos/o/r2/pulls/5)" = "repos/o/rN/pulls/N" ] && ok \
  || bad "4f: digits anywhere collapse the same way, got '$(pc repos/o/r2/pulls/5)'"

# ══ 5. the reserve gate ═════════════════════════════════════════════════════
# The assertion that matters is ncalls: a gate that lets the request go and
# judges the answer has already spent the call it exists to save.
ledreset; reset
export GH_QUOTA_RESERVE=600
# Prime the persisted reading with a remaining BELOW the reserve, on a window
# that has not reset yet (derived from one captured NOW, never re-read).
fx 200 500 6600 "$((NOW + 1800))" '{"ok":true}'
gh_rest GET repos/o/r/pulls > "$T/out"
reset
GH_REST_OPTIONAL=1 gh_rest GET repos/o/r/pulls/22 > "$T/out"; rc=$?
[ "$rc" = 75 ] && ok || bad "5a: below the reserve an OPTIONAL read is rc 75, got $rc"
[ "$GH_REST_REASON" = quota-reserve ] && ok \
  || bad "5b: the reason must be quota-reserve, got '$GH_REST_REASON'"
[ "$(ncalls)" = 0 ] && ok \
  || bad "5c: the refused read must not reach gh at all — $(ncalls) call(s) were issued"
[ ! -s "$T/out" ] && ok || bad "5d: a refused read prints nothing, got '$(cat "$T/out")'"

# A CRITICAL read (no GH_REST_OPTIONAL) still goes, below the reserve or not:
# starving the decision paths is the failure this gate must not cause.
reset
fx 200 480 6600 "$((NOW + 1800))" '{"ok":true}'
gh_rest GET repos/o/r/pulls/22 > "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "5e: a critical read is never gated, got rc $rc"
[ "$(ncalls)" = 1 ] && ok || bad "5f: the critical read must be issued, got $(ncalls) call(s)"

# ABOVE the reserve an optional read goes too.
reset
fx 200 5000 6600 "$((NOW + 1800))" '{"ok":true}'
gh_rest GET repos/o/r/pulls > "$T/out"
reset
fx 200 4999 6600 "$((NOW + 1800))" '{"ok":true}'
GH_REST_OPTIONAL=1 gh_rest GET repos/o/r/pulls/23 > "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "5g: above the reserve an optional read goes, got rc $rc"
[ "$(ncalls)" = 1 ] && ok || bad "5h: got $(ncalls) call(s)"

# A reading from a window that has ALREADY reset is not evidence about this
# window: the bucket refilled, so an unknown must never gate.
reset
fx 200 10 6600 "$((NOW - 60))" '{"ok":true}'
gh_rest GET repos/o/r/pulls > "$T/out"
reset
fx 200 6000 6600 "$((NOW + 1800))" '{"ok":true}'
GH_REST_OPTIONAL=1 gh_rest GET repos/o/r/pulls/24 > "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "5i: a reading past its reset must not gate, got rc $rc"

# No reading at all is unknown, and unknown never gates.
rm -f "$LED/.quota"
reset
fx 200 6000 6600 "$((NOW + 1800))" '{"ok":true}'
GH_REST_OPTIONAL=1 gh_rest GET repos/o/r/pulls/25 > "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "5j: with no reading on file an optional read goes, got rc $rc"
unset GH_QUOTA_RESERVE

# ── the bucket the gate judges (review I-1) ─────────────────────────────────
# THE FAILURE THIS ROW EXISTS FOR. A lane loops repos in ONE process and its
# token ladder switches GH_TOKEN per repo (bin/merge-sweep.sh, bin/lib/
# gh-repo-token.sh). Every installation token of the App shares one 6,600/h
# bucket; each PAT has its own 5,000/h. Round 1 kept ONE reading per box, so a
# PAT read that landed after an App read handed the gate the PAT's headroom —
# an App read with 99 left sailed through on the PAT's 4,900.
ledreset; reset
export GH_QUOTA_RESERVE=600
fx 200 100 6600 "$((NOW + 1800))" '{"ok":true}'
GH_TOKEN=ghs_exampleinstallationtoken gh_rest GET repos/o/r/pulls > "$T/out"
fx 200 4900 5000 "$((NOW + 1800))" '{"ok":true}'
GH_TOKEN=ghp_notarealpatvalue gh_rest GET repos/o/r/pulls > "$T/out"
reset
GH_REST_OPTIONAL=1 GH_TOKEN=ghs_exampleinstallationtoken \
  gh_rest GET repos/o/r/pulls/31 > "$T/out"; rc=$?
[ "$rc" = 75 ] && ok \
  || bad "5m: an App read must be judged on the APP bucket (100 left), not on the PAT read that followed it — got rc $rc"
[ "$GH_REST_REASON" = quota-reserve ] && ok || bad "5m2: reason '$GH_REST_REASON'"
[ "$(ncalls)" = 0 ] && ok || bad "5m3: the refused App read must not reach gh, $(ncalls) call(s)"
# And the other way round: the PAT has headroom, so its own read goes even
# though the App bucket beside it is nearly empty.
reset
fx 200 4899 5000 "$((NOW + 1800))" '{"ok":true}'
GH_REST_OPTIONAL=1 GH_TOKEN=ghp_notarealpatvalue \
  gh_rest GET repos/o/r/pulls/32 > "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "5n: a PAT read with 4900 left is never gated on the App bucket, got rc $rc"
[ "$(ncalls)" = 1 ] && ok || bad "5n2: got $(ncalls) call(s)"
# The two readings live in their own files and do not overwrite each other.
[ -r "$LED/.quota-app" ] && ok || bad "5o: the app bucket keeps its own reading"
if [ "$(find "$LED" -maxdepth 1 -name '.quota-pat-*' | wc -l | tr -d ' ')" = 1 ]; then ok
else bad "5o2: the PAT keeps its own reading, separate from the app one"; fi
if ! grep -q '^\.quota$' <<<"$(ls "$LED")"; then ok
else bad "5o3: there must be no unkeyed .quota reading left — that is the conflated one"; fi
unset GH_QUOTA_RESERVE

# A reading with no reset header is an unknown for the gate (review S-4): we
# cannot tell a live reading from one whose window already refilled, and an
# unknown that gates for ever is worse than one that never gates.
ledreset; reset
export GH_QUOTA_RESERVE=600
fx 200 5 - - '{"ok":true}'
gh_rest GET repos/o/r/pulls > "$T/out"
reset
fx 200 5 - - '{"ok":true}'
GH_REST_OPTIONAL=1 gh_rest GET repos/o/r/pulls/33 > "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "5p: a reading with no reset must not gate, got rc $rc"
unset GH_QUOTA_RESERVE

# The default is the documented 600, not 0 — a reserve of 0 is a gate that
# never fires, which is indistinguishable from not having built it.
if [ "$(GH_QUOTA_RESERVE= _GH_QUOTA_RESERVE_MEMO= gh_quota_reserve 2>/dev/null)" = 600 ]; then ok
else bad "5k: the code fallback reserve must be 600, got '$(gh_quota_reserve 2>/dev/null)'"; fi
# A junk knob value falls back rather than clamping to something nobody chose.
if [ "$(GH_QUOTA_RESERVE=abc _GH_QUOTA_RESERVE_MEMO= gh_quota_reserve 2>/dev/null)" = 600 ]; then ok
else bad "5l: an unusable reserve falls back to 600"; fi

# ══ 6. the ledger can never fail a caller, and costs no API call ════════════
# REVIEW FIX (I-2). Round 1 created the directory and THEN ran `: > <dir>`,
# which fails with "Is a directory" and leaves the tree perfectly writable — so
# 6a/6b/6c passed against a working ledger and would have stayed green if
# _gh_led_write started returning 1. The directory is removed FIRST here, and a
# regular FILE put in its place: `mkdir -p` on an existing file fails for every
# user including root (ENOTDIR), so this needs no root skip and it is checked
# below rather than assumed.
ledreset; reset
rm -rf "$T/h/state/gh-rest-ledger"
: > "$T/h/state/gh-rest-ledger"   # a FILE where the directory must go
: > "$T/h/logs/gh-rate.log"
if [ -f "$T/h/state/gh-rest-ledger" ] && ! mkdir -p "$T/h/state/gh-rest-ledger" 2>/dev/null; then ok
else bad "6z: the fixture must make the ledger genuinely unwritable, or 6a-6c prove nothing"; fi
fx 200 4000 6600 1790000000 '{"ok":true}'
gh_rest GET repos/o/r/pulls > "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "6a: an unwritable ledger must not change the caller's rc, got $rc"
[ "$(cat "$T/out")" = '{"ok":true}' ] && ok || bad "6b: nor what it printed"
[ "$(ncalls)" = 1 ] && ok || bad "6a2: nor how many calls were issued, got $(ncalls)"
# ONE log line for the process, not one per call: a ledger that cannot be
# written usually cannot be written for the whole tick.
reset
fx 200 3990 6600 1790000000 '{"ok":true}'
gh_rest GET repos/o/r/pulls > "$T/out"
NLOG=$(grep -c '\[gh-ledger\]' "$T/h/logs/gh-rate.log" 2>/dev/null || echo 0)
[ "$NLOG" = 1 ] && ok || bad "6a3: exactly one [gh-ledger] line per process, got $NLOG"
# And the line says which file it could not write, so an operator is not left
# guessing which of the box's state dirs is wrong.
if grep -q 'gh-rest-ledger' "$T/h/logs/gh-rate.log"; then ok
else bad "6a4: the log line must name the ledger path it could not create"; fi
# Under errexit too, AND on the same unwritable fixture (BH-1509 I-4). Round 2
# ran this after `ledreset` had recreated the directory, so it proved errexit
# survival on a perfectly writable tree — the one tree the hooks cannot fail on.
# It runs HERE, while state/gh-rest-ledger is still the regular FILE, and 6c2
# asserts that before the subshell rather than trusting it: the hooks are the
# last statement of their `if`, so a non-zero return from either kills the lane.
cat > "$T/errexit.sh" <<EOS
set -euo pipefail
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/bin:\$PATH" GH_STUB_DIR="$T" GH_ETAG=0
. "$LIB"
gh_rest GET repos/o/r/pulls > /dev/null
echo SURVIVED
EOS
reset
fx 200 4000 6600 1790000000 '{"ok":true}'
[ -f "$T/h/state/gh-rest-ledger" ] && ok \
  || bad "6c2: the ledger fixture must still be an unwritable FILE when 6c runs"
if [ "$(bash "$T/errexit.sh" 2>/dev/null)" = SURVIVED ]; then ok
else bad "6c: a caller under set -e must survive the ledger hooks on an unwritable ledger"; fi
rm -f "$T/h/state/gh-rest-ledger"
# A second, unrelated fault still gets its OWN line: the once-per-process guard
# is per message CLASS, or the first failure silences every later one.
ledreset
_GH_LED_LOG_SEEN=
: > "$T/h/logs/gh-rate.log"
_gh_led_log mkdir 'first class'
_gh_led_log mkdir 'first class again'
_gh_led_log knob 'a different class'
NLOG=$(grep -c '\[gh-ledger\]' "$T/h/logs/gh-rate.log" 2>/dev/null || echo 0)
[ "$NLOG" = 2 ] && ok || bad "6a5: one line per message class, got $NLOG"
# The ledger itself never talks to GitHub — a meter that spends the thing it
# measures is worse than no meter. Comment lines are stripped first, the same
# way tests/gh-rest-lib-test.sh counts `gh api` command positions: this file's
# own header says the words, and saying them is not doing them.
if [ -r "$DIR/bin/lib/gh-rest-ledger.sh" ] \
   && [ "$(grep -v '^[[:space:]]*#' "$DIR/bin/lib/gh-rest-ledger.sh" | grep -c 'gh api')" = 0 ]; then ok
else bad "6d: the ledger library must not call the API it is metering"; fi

# ══ 7. the report ═══════════════════════════════════════════════════════════
ledreset
{
  printf '2026-09-22T17:00:01Z\tmerge-conductor\tproject-4\tGET\trepos/o/r/pulls/N\t200\t1\t4000\t1790000000\tapp\n'
  printf '2026-09-22T17:00:02Z\tmerge-conductor\tproject-4\tGET\trepos/o/r/pulls/N\t304\t0\t4000\t1790000000\tapp\n'
  printf '2026-09-22T17:00:03Z\tmerge-sweep\tproject-4\tGET\trepos/o/r/pulls\t200\t1\t4900\t1790000000\tpat-abc123def456\n'
} > "$LED/2026-09-22T17.tsv"
printf '2026-09-22T18:00:01Z\tmerge-sweep\tproject-3\tGET\trepos/o/r/issues/N\t200\t1\t3000\t1790003600\tapp\n' \
  > "$LED/2026-09-22T18.tsv"
[ -x "$REPORT" ] && ok || bad "7a: bin/gh-quota-report.sh must exist and be executable"
OUT=$(HARNESS="$T/h" bash "$REPORT" day 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "7b: the report exits 0 on a readable ledger, got $rc — $OUT"
if grep -qE '2026-09-22T17[[:space:]]+merge-conductor[[:space:]]+2' <<<"$OUT"; then ok
else bad "7c: the report must sum calls per lane per hour; got:
$OUT"; fi
if grep -qE '2026-09-22T17[[:space:]]+merge-sweep[[:space:]]+1' <<<"$OUT"; then ok
else bad "7d: each lane gets its own row per hour; got:
$OUT"; fi
# counted is reported beside calls: 4 calls, 3 of them charged. Asserted as the
# whole TOTAL line (review S-5): round 1 grepped for '4', which any digit 4
# anywhere in the report satisfied.
if grep -qE '^TOTAL[[:space:]]+calls=4[[:space:]]+counted=3$' <<<"$OUT"; then ok
else bad "7e: the TOTAL line must read calls=4 counted=3; got:
$OUT"; fi
# The buckets are SPLIT, never summed: 3 app calls and 1 PAT call are two
# meters, and adding their remainings together is not a burn-down of either.
if grep -qE '^app[[:space:]]+3[[:space:]]+2$' <<<"$OUT"; then ok
else bad "7e2: the bucket block must show app 3 calls / 2 counted; got:
$OUT"; fi
if grep -qE '^pat-abc123def456[[:space:]]+1[[:space:]]+1$' <<<"$OUT"; then ok
else bad "7e3: and the PAT bucket separately; got:
$OUT"; fi
# The report writes nothing and deletes nothing (review S-1): it is the command
# an operator runs while wondering what is happening, and a read that sweeps is
# a read that can destroy the evidence it was called to show.
: > "$LED/2026-09-01T00.tsv"
touch -t "$(date -u -r "$((NOW - 240 * 3600))" +%Y%m%d%H%M 2>/dev/null \
        || date -u -d "@$((NOW - 240 * 3600))" +%Y%m%d%H%M)" "$LED/2026-09-01T00.tsv"
rm -f "$LED/.swept"
HARNESS="$T/h" bash "$REPORT" day >/dev/null 2>&1
[ -f "$LED/2026-09-01T00.tsv" ] && ok \
  || bad "7e4: the report must not sweep — a 10-day-old file it was shown is gone"
[ ! -f "$LED/.swept" ] && ok || bad "7e5: nor stamp a sweep it did not do"
rm -f "$LED/2026-09-01T00.tsv"
if grep -q 'repos/o/r/pulls/N' <<<"$OUT"; then ok
else bad "7f: the top path classes must be named; got:
$OUT"; fi
# `hour` reads only the newest hour file, so the two hours cannot be confused.
OUT1=$(HARNESS="$T/h" bash "$REPORT" hour 2>&1)
if grep -q 'project-3\|2026-09-22T18' <<<"$OUT1"; then ok
else bad "7g: the default window is the newest hour; got:
$OUT1"; fi
if ! grep -q 'merge-conductor' <<<"$(printf '%s' "$OUT1")"; then ok
else bad "7h: the hour window must not fold in the previous hour; got:
$OUT1"; fi
# An empty ledger is a real answer and says so — it never prints a clean total
# that reads as "nothing burned it".
ledreset
OUT2=$(HARNESS="$T/h" bash "$REPORT" day 2>&1); rc=$?
if [ "$rc" = 0 ] && grep -qi 'no ledger\|no calls' <<<"$OUT2"; then ok
else bad "7i: an empty ledger says so in words (rc $rc); got:
$OUT2"; fi

# ══ 8. the 48h sweep ════════════════════════════════════════════════════════
ledreset
: > "$LED/2026-09-20T01.tsv"; : > "$LED/2026-09-22T17.tsv"
# Ages are set on the FILES, derived from the one captured NOW: the sweep reads
# mtimes, never the name, for the same reason the etag sweep does.
touch -t "$(date -u -r "$((NOW - 72 * 3600))" +%Y%m%d%H%M 2>/dev/null \
        || date -u -d "@$((NOW - 72 * 3600))" +%Y%m%d%H%M)" "$LED/2026-09-20T01.tsv"
rm -f "$LED/.swept"
gh_quota_ledger_sweep 2>/dev/null
[ ! -f "$LED/2026-09-20T01.tsv" ] && ok || bad "8a: an hour file older than 48h must be swept"
[ -f "$LED/2026-09-22T17.tsv" ] && ok || bad "8b: a fresh hour file must survive the sweep"

# ══ 9. gh_quota_line ════════════════════════════════════════════════════════
# The conductor prints this once a tick so the burst is predictable from the
# log rather than from the failures it causes.
ledreset; reset
export GH_QUOTA_RESERVE=600
fx 200 1234 6600 "$((NOW + 900))" '{"ok":true}'
GH_TOKEN=ghs_exampleinstallationtoken gh_rest GET repos/o/r/pulls > "$T/out"
LINE=$(gh_quota_line 2>/dev/null)
grep -q '^QUOTA ' <<<"$LINE" && ok || bad "9a: the line starts with QUOTA, got '$LINE'"
grep -q 'rem=1234' <<<"$LINE" && ok || bad "9b: it names remaining, got '$LINE'"
grep -q 'reserve=600' <<<"$LINE" && ok || bad "9c: it names the reserve, got '$LINE'"
# It NAMES ITS BUCKET and defaults to the shared app one (review I-1): before
# the fix this field was whichever token answered last, so a PAT's 4,900 and
# the App's 98 were printed identically.
grep -q 'bucket=app' <<<"$LINE" && ok || bad "9b2: it names the bucket, got '$LINE'"
# A PAT reading in the same box must not leak into the app line.
reset
fx 200 4900 5000 "$((NOW + 900))" '{"ok":true}'
GH_TOKEN=ghp_notarealpatvalue gh_rest GET repos/o/r/pulls > "$T/out"
LINE3=$(gh_quota_line 2>/dev/null)
grep -q 'rem=1234' <<<"$LINE3" && ok \
  || bad "9b3: the app line must still read the app bucket after a PAT call, got '$LINE3'"
# A reading whose window has ALREADY RESET is an unknown, not a small number
# (review I-3): the bucket refilled at that reset, and a paused fleet would
# otherwise wear a red QUOTA LOW for hours against headroom it has. The gate
# ignores such a reading, so the line must too, or the screen and the gate
# disagree — which is the one thing this pair exists to prevent.
ledreset; reset
fx 200 5 6600 "$((NOW - 3600))" '{"ok":true}'
GH_TOKEN=ghs_exampleinstallationtoken gh_rest GET repos/o/r/pulls > "$T/out"
LINE4=$(gh_quota_line 2>/dev/null)
grep -q 'stale=1' <<<"$LINE4" && ok || bad "9e: a past-reset reading says stale=1, got '$LINE4'"
grep -q 'rem=?' <<<"$LINE4" && ok \
  || bad "9e2: and drops the number, which is no longer a reading, got '$LINE4'"
# The gate agrees with it: that same stale reading refuses nothing.
reset
fx 200 5 6600 "$((NOW - 3600))" '{"ok":true}'
GH_REST_OPTIONAL=1 GH_TOKEN=ghs_exampleinstallationtoken \
  gh_rest GET repos/o/r/pulls/41 > "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "9e3: the gate must ignore a stale reading too, got rc $rc"
# With nothing on file it says unknown — never 0, which is the one thing an
# unread bucket must not look like.
ledreset
LINE2=$(gh_quota_line 2>/dev/null)
if grep -q 'rem=?' <<<"$LINE2"; then ok
else bad "9d: an unknown remaining renders as ?, never 0, got '$LINE2'"; fi
unset GH_QUOTA_RESERVE

# ══ 10. the shipped surfaces this feature owns ══════════════════════════════
# THE ORPHAN RATCHET (BH-1268) reads tests/*.sh and tests/mc/*.sh only, so a
# console-ui file covered solely by `node --test` counts as a script no suite
# names and bin/test-impact.sh orphans --check refuses the diff. That is a real
# CI gate and it caught round 1. These rows name the file AND assert the two
# things the shell side of this feature depends on it for, so they are coverage
# rather than a keyword to satisfy a linter.
GHQJS="$DIR/console-ui/src/lib/ghquota.js"
[ -r "$GHQJS" ] && ok || bad "10a: console-ui/src/lib/ghquota.js must exist"
grep -q 'export function ghQuotaBadge' "$GHQJS" && ok \
  || bad "10b: console-ui/src/lib/ghquota.js must export ghQuotaBadge"
# The console cannot reach the knob store, so its fallback must be the SAME
# number as the library's and the schema seed's, or the tile goes red at a
# threshold nothing is actually refusing reads at.
JSRES=$(grep -oE 'GH_QUOTA_RESERVE = [0-9]+' "$GHQJS" | grep -oE '[0-9]+')
SHRES=$(grep -oE '_GH_QUOTA_RESERVE_DEFAULT=[0-9]+' "$DIR/bin/lib/gh-rest-ledger.sh" | grep -oE '[0-9]+')
SQLRES=$(grep -oE "'gh\.quota\.reserve','[0-9]+'" "$DIR/worker/jobs/schema.sql" | grep -oE "'[0-9]+'" | tr -d "'")
if [ -n "$JSRES" ] && [ "$JSRES" = "$SHRES" ] && [ "$JSRES" = "$SQLRES" ]; then ok
else bad "10c: the reserve default must be one number in all three homes — js='$JSRES' sh='$SHRES' sql='$SQLRES'"; fi
# The tile reads the keys the push actually writes. A rename on either side is
# a silently blank field, which on this tile reads as a healthy box.
for K in gh_quota_remaining gh_quota_limit gh_quota_reset gh_quota_bucket; do
  if grep -q "$K" "$GHQJS" && grep -q "$K" "$DIR/bin/fleet-status-push.sh"; then ok
  else bad "10d: '$K' must be written by the push and read by the badge"; fi
done

echo "gh-rest-quota: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
