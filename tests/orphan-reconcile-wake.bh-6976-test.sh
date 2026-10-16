#!/bin/bash
# tests/orphan-reconcile-wake.bh-6976-test.sh — BH-6976 lane A: orphan-reconcile
# reuses a per-issue thread or blocker read until a wake (or the backstop, or a
# moved updatedAt) says it changed. The REAL bin/orphan-reconcile.sh runs on a
# fixture board: one ownerless issue #7 with 2 comments and `Blocked-by: #3`,
# where #3 is not on the ai-build list (so pass 1 asks for both reads). gh and
# curl are PATH shims; prs_wake_seen is an exported table double (lines
# `kind key rc`, `*` matches anything, first match wins, no match rc 1), except
# in O8, which runs the real wake feed served by the curl shim.
#
#   O1  run 1 reads issues/7/comments and issues/3 once each; a wake `issue 7`
#       -> run 2 re-reads the thread and not the blocker
#   O2  run 2 at +600 s, no wake -> zero reads, same verdict, cache=2/0
#   O3  no wake, a new HOLD comment moved updatedAt -> thread re-read, OWNED hold
#   O3b an edited comment (same count) moved updatedAt -> re-read, OWNED hold
#   O4  run 2 at the backstop (+1800 s from the write) -> both re-read; +1799 hits
#   O5  the feed cannot tell (rc 2) -> both re-read
#   O6  run 1's blocker read answers 500 (rc 75) -> no blocker cache, run 2 reads it
#   O7  WAKE_BACKSTOP=0 / ORPHAN_WAKE_BACKSTOP_S=0 -> both re-read
#   O8  the real feed (no double): quiet -> hit; a wake row for #7 -> re-read
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/orphan-reconcile-wake.bh-6976-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
for L in bin/orphan-reconcile.sh bin/jobs-client.sh bin/lib/preplan-lib.sh bin/lib/gh-budget.sh bin/lib/hold.sh \
         bin/lib/closeout-overdue.sh bin/lib/gh-rest.sh bin/lib/gh-rest-var.sh bin/lib/gh-rest-list.sh \
         bin/lib/wake-backstop.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/launches.log"' > "$H/bin/run-build.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$H/bin/lane-alert.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$H/bin/pr-owner-sweep.sh"
chmod +x "$H/bin/"*.sh

# gh: the open board, the all-states list (the open board only, so #3 is not
# on it), the PR list, #7's thread and #3 by number. $HARNESS/st-issue holds a
# status for the by-number read.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
ARGS="$*"
printf '%s\n' "$ARGS" >> "$HARNESS/gh-calls.log"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$ARGS" in
  "api repos/example-org/project-5 -q .id") echo 1; exit 0 ;;
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    SEND 200 "$(jq -c --argjson n "$n" '[ .[] | select(.number==$n) | (.comments // [])[] ]' "$HARNESS/fixture/open.json")" ;;
  *"/pulls"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 '[]' ;;
  *"/issues/"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    s=$(cat "$HARNESS/st-issue" 2>/dev/null || echo 200)
    case "$s" in 2*) ;; *) SEND "$s" '{"message":"no"}' ;; esac
    [ -f "$HARNESS/fixture/issue-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(jq -c '{number, state:(.state|ascii_downcase), closed_at:.closedAt}' "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues"*"state=all"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, title, body, comments:((.comments // [])|length), updated_at:.updatedAt} ]' "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
# curl: the jobs ledger (empty), the queue (empty) and, for O8, the wake feed
# from $HARNESS/fixture/wakes.json and wakes-summary.json.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
printf '%s\n' "$URL" >> "$HARNESS/curl-calls.log"
case "$URL" in
  */api/wakes/summary*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/wakes-summary.json" 2>/dev/null || echo '{"repos":[]}')" ;;
  */api/wakes\?*)       printf '%s\n200\n' "$(cat "$HARNESS/fixture/wakes.json" 2>/dev/null || echo '{"wakes":[]}')" ;;
  */api/queue*)         printf '{"queue":[]}\n200\n' ;;
  */api/jobs*)          printf '{"jobs":[]}\n200\n' ;;
  *)                    printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

ISO() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
COMMENTS='[{"id":1,"body":"Looks good.","user":{"login":"operator","type":"User"},"created_at":"'"$(ISO 90000)"'"},{"id":2,"body":"Scoped.","user":{"login":"operator","type":"User"},"created_at":"'"$(ISO 86400)"'"}]'
board() { # board <updatedAt-age-s> [comments-json]
  jq -n --arg u "$(ISO "$1")" --argjson c "${2:-$COMMENTS}" \
    '[{number:7, title:"TK-7 the orphan", body:"## Scope\nBlocked-by: #3", comments:$c, updatedAt:$u}]' > "$H/fixture/open.json"
  printf '{"number":3,"state":"CLOSED","closedAt":"%s"}\n' "$(ISO 86400)" > "$H/fixture/issue-3.json"
}
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/logs"
  mkdir -p "$H/state" "$H/logs"
  rm -f "$H/launches.log" "$H/gh-calls.log" "$H/curl-calls.log" "$H/st-issue" "$H/wake" "$H/fixture/wakes.json" "$H/fixture/wakes-summary.json"
  board 86400
  printf '* * 1\n' > "$H/wake"
}
# The double, exported so the lane's own shell inherits it.
prs_wake_seen() {
  local r
  printf 'WAKE %s %s %s %s\n' "$@" >> "$HARNESS/wake.calls"
  [ -f "$HARNESS/wake" ] || return 2
  r=$(awk -v k="$2" -v key="$3" '($1 == k || $1 == "*") && ($2 == key || $2 == "*") { print $3; exit }' "$HARNESS/wake")
  return "${r:-1}"
}
export -f prs_wake_seen
# run [VAR=val...] — one pass; the grace marker of the last launch is dropped
# first, so every run sees #7 as the same ownerless ticket. The lane gets
# HARNESS_TEST_SANDBOX=1 itself: bin/lib/wake-backstop.sh honours
# WAKE_BACKSTOP_NOW only under it, and the CI shards and the Mac gate run
# suites without it (harness-ci.yml, #388). Per run, not exported, so the
# root guard in tests/lib/scratch.sh stays live.
run() {
  rm -f "$H/state/orphan-reconcile/$P"/*.enqueued "$H/gh-calls.log"
  OUT=$(env HARNESS_TEST_SANDBOX=1 "$@" "$H/bin/orphan-reconcile.sh" "$P" --explain 2>/dev/null)
}
reads() { grep -c -- "$1" "$H/gh-calls.log" 2>/dev/null; }
th()  { reads 'repos/example-org/project-5/issues/7/comments'; }
bl()  { reads 'repos/example-org/project-5/issues/3'; }
summary() { grep -o 'reconcile: open=.*' "$H/logs/$P.log" | tail -1; }
verdict() { awk -F'\t' '$1=="TK-7" {print $3"\t"$4}' <<<"$OUT"; }
CD="$H/state/orphan-reconcile/example-org_project-5"

# ── O1 ─────────────────────────────────────────────────────────────────────
reset
run
[ "$(th)" = 1 ] && [ "$(bl)" = 1 ] && ok || bad "O1 run 1 wanted 1 thread + 1 blocker read, got $(th) / $(bl): $(cat "$H/gh-calls.log")"
V1=$(verdict)
[ "${V1%%$'\t'*}" = ORPHAN ] && ok || bad "O1 run 1 verdict '$V1', wanted ORPHAN"
[ -s "$CD/thread-7.json" ] && [ -s "$CD/blocker-3.json" ] && ok || bad "O1 run 1 wrote no cache: $(ls "$CD" 2>&1)"
summary | grep -q ' cache=0/2 ' && ok || bad "O1 run 1 summary '$(summary)', wanted cache=0/2"
printf 'issue 7 0\n* * 1\n' > "$H/wake"
run WAKE_BACKSTOP_NOW=$((NOW + 600))
[ "$(th)" = 1 ] && [ "$(bl)" = 0 ] && ok || bad "O1 a wake on #7 wanted 1 thread + 0 blocker reads, got $(th) / $(bl)"
summary | grep -q ' cache=1/1 ' && ok || bad "O1 run 2 summary '$(summary)', wanted cache=1/1"

# ── O2 ─────────────────────────────────────────────────────────────────────
reset
run
run WAKE_BACKSTOP_NOW=$((NOW + 600))
[ "$(th)" = 0 ] && [ "$(bl)" = 0 ] && ok || bad "O2 no wake wanted 0 reads, got $(th) / $(bl): $(cat "$H/gh-calls.log")"
[ "$(verdict)" = "$V1" ] && ok || bad "O2 verdict '$(verdict)' != run 1 '$V1'"
summary | grep -q ' cache=2/0 ' && ok || bad "O2 summary '$(summary)', wanted cache=2/0"
grep -q "^WAKE example-org/project-5 issue 7 " "$H/wake.calls" && grep -q "^WAKE example-org/project-5 pr 3 " "$H/wake.calls" && ok \
  || bad "O2 the feed was not asked about issue/pr wakes on #7 and #3: $(cat "$H/wake.calls" 2>/dev/null)"
grep -q '/issues/7/comments' "$H/launches.log" 2>/dev/null && bad "O2 junk in launches" || ok
[ "$(grep -c 'TK-7' "$H/launches.log" 2>/dev/null)" = 2 ] && ok || bad "O2 both runs should launch TK-7: $(cat "$H/launches.log" 2>/dev/null)"

# ── O3 / O3b ───────────────────────────────────────────────────────────────
reset
run
board 60 "$(jq -c '. + [{"id":3,"body":"HOLD — waiting on the vendor.","user":{"login":"operator","type":"User"},"created_at":"2026-10-16T00:00:00Z"}]' <<<"$COMMENTS")"
run WAKE_BACKSTOP_NOW=$((NOW + 600))
[ "$(th)" = 1 ] && [ "$(bl)" = 0 ] && ok || bad "O3 a moved updatedAt wanted 1 thread read, got $(th) / $(bl)"
verdict | grep -q $'^OWNED\thold' && ok || bad "O3 a new HOLD comment gave '$(verdict)', wanted OWNED hold"
reset
run
board 60 "$(jq -c '.[1].body = "HOLD — not yet."' <<<"$COMMENTS")"
run WAKE_BACKSTOP_NOW=$((NOW + 600))
[ "$(th)" = 1 ] && ok || bad "O3b an edited comment wanted 1 thread read, got $(th)"
verdict | grep -q $'^OWNED\thold' && ok || bad "O3b an edited HOLD gave '$(verdict)', wanted OWNED hold"

# ── O4 ─────────────────────────────────────────────────────────────────────
reset
run
# One epoch for both cache files: the two reads can fall in different seconds.
E=$((NOW - 100))
for m in "$CD"/*.meta; do printf '%s\t%s\n' "$(cut -f1 "$m")" "$E" > "$m"; done
run WAKE_BACKSTOP_NOW=$((E + 1799))
[ "$(th)" = 0 ] && [ "$(bl)" = 0 ] && ok || bad "O4 1799 s after the write wanted 0 reads, got $(th) / $(bl)"
run WAKE_BACKSTOP_NOW=$((E + 1800))
[ "$(th)" = 1 ] && [ "$(bl)" = 1 ] && ok || bad "O4 at the backstop wanted both reads, got $(th) / $(bl)"

# ── O5 ─────────────────────────────────────────────────────────────────────
reset
run
printf '* * 2\n' > "$H/wake"
run WAKE_BACKSTOP_NOW=$((NOW + 600))
[ "$(th)" = 1 ] && [ "$(bl)" = 1 ] && ok || bad "O5 a feed that cannot tell wanted both reads, got $(th) / $(bl)"

# ── O6 ─────────────────────────────────────────────────────────────────────
reset
echo 500 > "$H/st-issue"
run
[ -e "$CD/blocker-3.json" ] && bad "O6 a failed blocker read was cached" || ok
[ -s "$CD/thread-7.json" ] && ok || bad "O6 the good thread read was not cached"
summary | grep -q ' cache=0/2 ' && ok || bad "O6 run 1 summary '$(summary)', wanted cache=0/2"
rm -f "$H/st-issue"
run WAKE_BACKSTOP_NOW=$((NOW + 600))
[ "$(th)" = 0 ] && [ "$(bl)" = 1 ] && ok || bad "O6 run 2 wanted 0 thread + 1 blocker read, got $(th) / $(bl)"

# ── O7 ─────────────────────────────────────────────────────────────────────
reset
run
run WAKE_BACKSTOP=0 WAKE_BACKSTOP_NOW=$((NOW + 600))
[ "$(th)" = 1 ] && [ "$(bl)" = 1 ] && ok || bad "O7 WAKE_BACKSTOP=0 wanted both reads, got $(th) / $(bl)"
run ORPHAN_WAKE_BACKSTOP_S=0 WAKE_BACKSTOP_NOW=$((NOW + 600))
[ "$(th)" = 1 ] && [ "$(bl)" = 1 ] && ok || bad "O7b ORPHAN_WAKE_BACKSTOP_S=0 wanted both reads, got $(th) / $(bl)"

# ── O8 — the real feed: GET /api/wakes/summary and /api/wakes through the
# jobs client. Run 1 writes the cache, run 2 starts the mirror's coverage (a
# cache older than it cannot be trusted, so it reads again), run 3 hits.
reset
export -n prs_wake_seen
unset -f prs_wake_seen
FEED=(PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 PR_SNAPSHOT_FEED_STALE_S=900)
printf '{"repos":[{"repo":"example-org/project-5","n":1,"last_at":"%s","kinds":"issue","last_id":5}]}\n' "$(ISO 0)" > "$H/fixture/wakes-summary.json"
echo '{"wakes":[{"id":5,"kind":"issue","key":"99","at":"'"$(ISO 7200)"'"}]}' > "$H/fixture/wakes.json"
run "${FEED[@]}"
# Written two minutes before the coverage starts, whatever the clock does.
for m in "$CD"/*.meta; do printf '%s\t%s\n' "$(cut -f1 "$m")" "$((NOW - 120))" > "$m"; done
run "${FEED[@]}"
[ "$(th)" = 1 ] && [ "$(bl)" = 1 ] && ok || bad "O8 run 2 (coverage starts) wanted both reads, got $(th) / $(bl)"
grep -q '/api/wakes?since=' "$H/curl-calls.log" && ok || bad "O8 the wake feed was never paged: $(cat "$H/curl-calls.log")"
run "${FEED[@]}"
[ "$(th)" = 0 ] && [ "$(bl)" = 0 ] && ok || bad "O8 run 3 on a quiet real feed wanted 0 reads, got $(th) / $(bl)"
summary | grep -q ' cache=2/0 ' && ok || bad "O8 run 3 summary '$(summary)'"
# A comment on #7 rings the doorbell; the mirror is past its TTL.
printf '{"repos":[{"repo":"example-org/project-5","n":2,"last_at":"%s","kinds":"issue","last_id":6}]}\n' "$(ISO 0)" > "$H/fixture/wakes-summary.json"
# Stamped 10 minutes ahead, so its minute bucket is after every cache write.
echo '{"wakes":[{"id":6,"kind":"issue","key":"7","at":"'"$(ISO -600)"'"}]}' > "$H/fixture/wakes.json"
SD="$H/state/pr-snapshot/example-org_project-5"
c=1; f=1; v=0
[ -r "$SD/wakes.state" ] && IFS=$'\t' read -r _ c f v < "$SD/wakes.state"
printf '%s\t%s\t%s\t%s\n' "$((NOW - 1000))" "$c" "$f" "$v" > "$SD/wakes.state"
run "${FEED[@]}"
[ "$(th)" = 1 ] && [ "$(bl)" = 0 ] && ok || bad "O8 a real issue wake on #7 wanted 1 thread + 0 blocker reads, got $(th) / $(bl)"

echo "orphan-reconcile-wake: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
