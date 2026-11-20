#!/bin/bash
# tests/merged-ticket-advance.bh-9865-test.sh — BH-9865: bin/merged-ticket-advance.sh
# holds a multi-slice master ticket. bin/board-closeout.sh (BH-8333) keeps a
# slice ticket in `in_progress` and bin/decompose-parent-close.sh closes it when
# every child is done. This lane used to move the master to `review` (or `done`)
# after slice 1. Now a ticket whose newest build dir plan.md (local path) or
# merged PR body (peer path) carries a SLICE line for THIS ticket is held: no
# comment, no move, no turn, and `slice-plan=N` counts it.
#
# The REAL lane against a stubbed board (fake curl) and a fake gh, fixtures
# copied from tests/merged-ticket-advance.peer-built-test.sh. 0 network: Z
# asserts every request went to the fakes. Each case calls reset and seeds its
# own build dirs; no case reads another case's state.
#
# Run from anywhere: tests/merged-ticket-advance.bh-9865-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "merged-ticket-advance peer: jq is required"; exit 1; }

H="$T/h"
B="$T/board"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/flags" "$T/fakebin" "$B"
ln -s "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
# bin/jobs-client.sh: the flag store that keeps the invisible-repo alert to one
# a day (P10e), as tests/blind-ticks-alert.bh-847-test.sh installs it.
for s in bin/merged-ticket-advance.sh bin/internal-token-for.sh bin/alert-line.sh bin/prod-url.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
chmod +x "$H/bin/"*.sh

cat > "$H/fleet.conf" <<'CONF'
x-os    example-org/x-os    https://x.test  /api/board  3  local
ghproj  example-org/ghproj  -               -           5  local
CONF
: > "$H/env/global.env"
printf 'X_API_BASE=https://x.test\nX_INTERNAL_API_TOKEN=tok-fixture-never-logged\n' > "$T/x-os.env.src"

# JOBS_ALERT=0: this scratch has no worker, so the jobs client's own
# "unreachable" line stays out of the ALERTS.log P10e counts.
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBDIR="$B" ALLREQ="$T/ALLREQS.log" JOBS_ALERT=0
export PATH="$T/fakebin:$PATH"
# Nothing from the box reaches the lane (D60).
unset GH_TOKEN GITHUB_TOKEN GH_ISSUES_REPO VERSION_URL VERSION_AUTH MERGED_ADVANCE_MAX \
      MERGED_ADVANCE_COOLDOWN_S MERGED_ADVANCE_DEPLOY_GRACE_S 2>/dev/null || true
: > "$ALLREQ"

# ── the board, as a stateful file-backed API ─────────────────────────────────
# As in the bh-3921 suite, plus: POST */turn sets waitingOn (TURN_CODE answers
# it with that code), and GET https://x.test/api/internal/version answers
# $B/VERSION with $B/VERSION_CODE (default 200).
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
OUT=""; METHOD=GET; DATA=""; IDEM=""; AUTH=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift ;;
    -X) METHOD="$2"; shift ;;
    --data-binary) DATA="${2#@}"; shift ;;
    -H) case "$2" in
          Idempotency-Key:*) IDEM="${2#Idempotency-Key: }" ;;
          Authorization:*)   AUTH=1 ;;
        esac; shift ;;
    http*) URL="$1" ;;
    *) ;;
  esac
  shift
done
DB="$STUBDIR/db.json"
w() { if [ -n "$OUT" ]; then printf '%s' "$1" > "$OUT"; else printf '%s' "$1"; fi; }
echo "$METHOD $URL" >> "$STUBDIR/REQS.log"
echo "$METHOD $URL" >> "$ALLREQ"
CODE=200
if [ "$METHOD" = POST ]; then
  BODY=$(cat "$DATA" 2>/dev/null)
  jq -cn --arg u "$URL" --arg i "$IDEM" --argjson a "$AUTH" --arg b "$BODY" \
         '{url:$u, idem:$i, auth:$a, body:$b}' >> "$STUBDIR/POSTS.jsonl"
  id=$(printf '%s' "$URL" | sed -E 's@.*/tickets/([^/]+)/.*@\1@')
  case "$URL" in
    */move)
      if [ -e "$STUBDIR/MOVE_FAIL_ONCE" ]; then
        rm -f "$STUBDIR/MOVE_FAIL_ONCE"; w '{"error":"boom"}'; printf 500; exit 0
      fi
      to=$(printf '%s' "$BODY" | jq -r '.toStatus')
      jq --arg id "$id" --arg to "$to" 'map(if (.id|tostring) == $id then .status = $to else . end)' \
         "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
      w "$(jq -cn --arg id "$id" --arg to "$to" '{id:$id, status:$to}')" ;;
    */turn)
      if [ -r "$STUBDIR/TURN_CODE" ]; then
        CODE=$(cat "$STUBDIR/TURN_CODE"); w '{}'; printf '%s' "$CODE"; exit 0
      fi
      side=$(printf '%s' "$BODY" | jq -r '.to')
      jq --arg id "$id" --arg s "$side" 'map(if (.id|tostring) == $id then .waitingOn = $s else . end)' \
         "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
      w "$(jq -cn --arg s "$side" '{waitingOn:$s}')" ;;
    */comments)
      now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
      jq --arg id "$id" --arg now "$now" --arg b "$(printf '%s' "$BODY" | jq -r '.body')" \
         'map(if (.id|tostring) == $id
              then .comments += [{author:{userId:"u-h", name:"System Harness"}, createdAt:$now, body:$b}] else . end)' \
         "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
      w '{"id":1}' ;;
    *) CODE=404; w '{}' ;;
  esac
  printf '%s' "$CODE"; exit 0
fi
case "$URL" in
  https://x.test/api/internal/version)
    [ "$AUTH" = 1 ] || { w '{}'; printf 404; exit 0; }
    [ -r "$STUBDIR/VERSION_CODE" ] && CODE=$(cat "$STUBDIR/VERSION_CODE")
    w "$(cat "$STUBDIR/VERSION" 2>/dev/null)" ;;
  */boards) w '{"boards":[{"id":"b1","name":"Main"}]}' ;;
  */boards/*/tickets) w "$(jq -c '{tickets: map(del(.comments))}' "$DB")" ;;
  */tickets/*)
    id="${URL##*/}"
    [ -r "$STUBDIR/rec-$id.code" ] && CODE=$(cat "$STUBDIR/rec-$id.code")
    w "$(jq -c --arg id "$id" '[.[] | select((.id|tostring) == $id)][0] // {}' "$DB")" ;;
  *) CODE=404; w '{}' ;;
esac
printf '%s' "$CODE"
SH
# The fake gh. `gh api -i -X GET <path>` answers an HTTP/2.0 status block and
# the body of $STUBDIR/gh/<path, / as _>.json (status from <same>.code, 404 when
# there is no file). `gh api repos/<slug> -q .id` is the visibility probe of
# bin/lib/gh-repo-token.sh: it passes unless $STUBDIR/GH_PROBE_FAIL exists.
# Everything else fails. Every call lands in GH.log.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$STUBDIR/GH.log"
if [ "${1:-}" = api ] && [ "${2:-}" = -i ]; then
  p="${5:-}"; f="$STUBDIR/gh/$(printf '%s' "$p" | tr '/' '_').json"
  code=404; body='{"message":"Not Found"}'
  if [ -r "$f" ]; then code=200; body=$(cat "$f"); fi
  [ -r "$f.code" ] && code=$(cat "$f.code")
  printf 'HTTP/2.0 %s X\r\nContent-Type: application/json\r\n\r\n%s\n' "$code" "$body"
  case "$code" in 2*) exit 0 ;; *) exit 1 ;; esac
fi
if [ "${1:-}" = api ] && [ "${3:-}" = -q ]; then
  [ -e "$STUBDIR/GH_PROBE_FAIL" ] && exit 1
  echo 1; exit 0
fi
exit 1
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

# ── fixture helpers ──────────────────────────────────────────────────────────
PRU="https://github.com/example-org/x-os/pull"
API="https://x.test/api/board"
MSHA="abcdef12""34567890abcdef12""34567890abcdef12"
LIVE="99999999""8888888877777777""6666666655555555"
reset() {
  scratch_rm "$B"; mkdir -p "$B/gh"
  echo '[]' > "$B/db.json"; : > "$B/REQS.log"; : > "$B/POSTS.jsonl"; : > "$B/GH.log"
  scratch_rm "$H/logs"; scratch_rm "$H/builds"; scratch_rm "$H/state"; scratch_rm "$H/flags"
  mkdir -p "$H/logs" "$H/builds" "$H/state" "$H/flags"
  cp "$T/x-os.env.src" "$H/env/x-os.env"
  unset MERGED_ADVANCE_MAX MERGED_ADVANCE_DEPLOY_GRACE_S 2>/dev/null || true
}
isoago() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ; }
stago()  { date -u -d "-$1 min" '+%Y-%m-%d %H:%M:%SZ'; }
tsago()  { date -u -d "-$1 min" +%Y%m%d%H%M; }
# tk <id> <key> <status> <reporterUserId|-> — add a ticket
tk() {
  jq --argjson id "$1" --arg k "$2" --arg s "$3" --arg r "$4" \
     '. + [ {id:$id, key:$k, title:("Ticket " + $k), status:$s, waitingOn:"team", comments:[]}
            + (if $r == "-" then {} else {reporter:{userId:$r, name:"R"}} end) ]' \
     "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
}
# comment <id> <userId> <minutes-ago> <body> [author name]
comment() {
  jq --argjson id "$1" --arg u "$2" --arg t "$(isoago "$3")" --arg b "$4" --arg n "${5:-}" \
     'map(if .id == $id then .comments += [{author:({userId:$u} + (if $n == "" then {} else {name:$n} end)),
                                             createdAt:$t, body:$b}] else . end)' \
     "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
}
cyg() { # cyg <id> <minutes-ago> <url...> — the peer fleet's "ready for review" comment
  local id="$1" m="$2" b="The work for this ticket is ready for review in a pull request" u; shift 2
  for u in "$@"; do b="$b <a href=\"$u\">$u</a>"; done
  comment "$id" cyg "$m" "$b" partner
}
ghf() { printf '%s' "$2" > "$B/gh/$(printf '%s' "$1" | tr '/' '_').json"; }        # ghf <path> <json>
ghcode() { printf '%s' "$2" > "$B/gh/$(printf '%s' "$1" | tr '/' '_').json.code"; } # ghcode <path> <code>
pr_merged() { # pr_merged <n> <minutes-ago> [merge sha]
  ghf "repos/example-org/x-os/pulls/$1" "$(jq -cn --arg m "$(isoago "$2")" --arg s "${3:-$MSHA}" \
      '{number:1, state:"closed", merged_at:$m, merge_commit_sha:$s}')"
}
pr_open() { ghf "repos/example-org/x-os/pulls/$1" '{"number":1,"state":"open","merged_at":null,"merge_commit_sha":null}'; }
version() { printf '{"sha":"%s"}' "$1" > "$B/VERSION"; }
compare() { ghf "repos/example-org/x-os/compare/$MSHA...$LIVE" "{\"status\":\"$1\"}"; }
# peer <id> <key> <status> <reporter> — the ticket test 1 state: no build dir,
# partner's PR comment 60 min ago, PR 77 merged 40 min ago, prod ahead of it.
peer() {
  tk "$1" "$2" "$3" "$4"
  cyg "$1" 60 "$PRU/77"
  pr_merged 77 40
  version "$LIVE"; compare ahead
}

run() { "$H/bin/merged-ticket-advance.sh" "$@" 2>"$T/err.txt"; }
posts()   { awk 'END{print NR}' "$B/POSTS.jsonl"; }
reqs()    { awk 'END{print NR}' "$B/REQS.log"; }
ghcalls() { awk 'END{print NR}' "$B/GH.log"; }
post_f()  { sed -n "$2p" "$B/POSTS.jsonl" | jq -r ".$1" 2>/dev/null; }
calls()   { jq -r '.url + " " + .idem' "$B/POSTS.jsonl" | tr '\n' '|'; }
plog()    { cat "$H/logs/x-os.log" 2>/dev/null; }
advlog()  { grep 'MERGED_ADVANCE moved=' "$H/logs/x-os.log" 2>/dev/null | tail -1 | sed 's/^.*\] MERGED_ADVANCE /MERGED_ADVANCE /'; }
field_of() { jq -r --argjson id "$1" --arg f "$2" '.[] | select(.id == $id) | .[$f]' "$B/db.json"; }
FIELDS="moved comment-only no-audit audit-fail newer-build client-spoke client-review moved-back move-gave-up no-local-build no-pr-in-thread pr-open deploy-behind peer-unread pr-ambiguous slice-plan"
want() { # want [field=N ...] -> the full MERGED_ADVANCE line, every other field 0
  local -A v=(); local f a s="MERGED_ADVANCE"
  for a in "$@"; do v[${a%%=*}]="${a#*=}"; done
  for f in $FIELDS; do
    [ "$f" = no-audit ] && s="$s skipped:"
    s="$s $f=${v[$f]:-0}"
  done
  printf '%s' "$s"
}
line_is() { # line_is <case> [field=N ...]
  local c="$1"; shift
  [ "$(advlog)" = "$(want "$@")" ] && ok || bad "$c: log line
   want '$(want "$@")'
   got  '$(advlog)'"
}

# ── local-path fixtures (as tests/merged-ticket-advance.bh-3921-test.sh) ─────
DONE="$H/state/postmerge-qa-done.txt"
# build <key> <minutes-ago> [RESULT first line] -> prints the basename
build() {
  local bn="x-os-$1-$(tsago "$2")"
  mkdir -p "$H/builds/$bn"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$H/builds/$bn/RESULT"
  printf '%s' "$bn"
}
# audit <basename> <sha8> <verdict> <minutes-ago>
audit() { printf '%s %s %s %s\n' "$(stago "$4")" "$1" "$2" "$3" >> "$DONE"; }
# local <id> <key> <reporter> <plan text|-> — an in_progress ticket whose newest
# build opened PR <id> and passed the deploy audit. `-` writes no plan.md.
local_case() {
  local bn
  tk "$1" "$2" in_progress "$3"
  bn=$(build "$2" 30 "PR_CREATED $PRU/$1 | QUEUED: tier 2")
  [ "$4" = - ] || printf '%s\n' "$4" > "$H/builds/$bn/plan.md"
  audit "$bn" abc12345 PASS 10
}
cposts() { grep -c '/comments"' "$B/POSTS.jsonl"; }
mposts() { grep -c '/move"' "$B/POSTS.jsonl"; }
tposts() { grep -c '/turn"' "$B/POSTS.jsonl"; }
PLAN_HEAD="# TK-501 — a slice build

KIND: feature
"
PLAN_NOSLICE="${PLAN_HEAD}
## Size
FILES: 3
SIZE: M"
# held <case> <id> <status> — the hold: 0 POSTs, status unchanged, no stdout,
# no ticket GET (local path), the full line with slice-plan=1.
held_local() {
  [ "$(posts)" = 0 ] && ok || bad "$1: 0 POSTs (got $(calls))"
  [ "$(field_of "$2" status)" = "$3" ] && ok || bad "$1: status stays $3 (got $(field_of "$2" status))"
  [ -z "$OUT" ] && ok || bad "$1: no stdout (got '$OUT')"
  grep -q "^GET $API/tickets/$2\$" "$B/REQS.log" && bad "$1: no ticket GET for a held slice (REQS: $(tr '\n' '|' < "$B/REQS.log"))" || ok
  line_is "$1" slice-plan=1
}
# advanced <case> <key> — moved to review as today
advanced() {
  [ "$OUT" = "$2" ] && ok || bad "$1: stdout is the key (got '$OUT', log '$(advlog)')"
  [ "$(cposts)/$(mposts)/$(tposts)" = 1/1/1 ] && ok || bad "$1: one comment, one move, one turn (got $(calls))"
  [ "$(field_of 501 status)" = review ] && ok || bad "$1: status review (got $(field_of 501 status))"
  line_is "$1" moved=1
}

# S1: client ticket, plan `SLICE: C0 of #501` -> held
reset
local_case 501 TK-501 u_7 "${PLAN_HEAD}
SLICE: C0 of #501
SLICE-REASON: ordering: C1 reads C0's table

## Slices
- C1: the rest (after C0)"
OUT=$(run x-os); RC=$?
[ "$RC" = 0 ] && ok || bad "S1: rc 0 (got $RC)"
held_local S1 501 in_progress
grep -q 'Moving it to review' "$B/POSTS.jsonl" && bad "S1: no 'Moving it to review' comment" || ok

# S2: `SLICE: C1 of #TK-501` (the KEY) -> held
reset
local_case 501 TK-501 u_7 "${PLAN_HEAD}
SLICE: C1 of #TK-501"
OUT=$(run x-os)
held_local S2 501 in_progress

# S3: a `system` ticket with a slice plan -> held, not done
reset
local_case 501 TK-501 system "${PLAN_HEAD}
SLICE: C0 of #501"
OUT=$(run x-os)
held_local S3 501 in_progress

# S4: `The build for THIS ticket is C0` -> held
reset
local_case 501 TK-501 u_7 "${PLAN_HEAD}
The build for THIS ticket is C0, the rest are filed after it merges."
OUT=$(run x-os)
held_local S4 501 in_progress

# S4b: markdown bold, lower-case KEY -> held
reset
local_case 501 TK-501 u_7 "${PLAN_HEAD}
**SLICE:** C2 of #TK-501"
OUT=$(run x-os)
held_local S4b 501 in_progress

# S5: no SLICE line -> moves as today
reset
local_case 501 TK-501 u_7 "$PLAN_NOSLICE"
OUT=$(run x-os)
advanced S5 TK-501
[ "$(field_of 501 waitingOn)" = client ] && ok || bad "S5: turn to client (got $(field_of 501 waitingOn))"

# S6: a SLICE line for another ticket (rc 2) -> advances
reset
local_case 501 TK-501 u_7 "${PLAN_HEAD}
SLICE: C0 of #999"
OUT=$(run x-os)
advanced S6 TK-501

# S7: an id that only starts with this ticket's id -> advances
reset
local_case 501 TK-501 u_7 "${PLAN_HEAD}
SLICE: C0 of #5010"
OUT=$(run x-os)
advanced S7 TK-501

# S8: no plan.md -> advances
reset
local_case 501 TK-501 u_7 -
OUT=$(run x-os)
advanced S8 TK-501

# S9: only a SLICE-REASON line -> advances
reset
local_case 501 TK-501 u_7 "${PLAN_HEAD}
SLICE-REASON: ordering: x"
OUT=$(run x-os)
advanced S9 TK-501

# S10: an older slice build behind a newer non-slice PR build -> advances
reset
tk 501 TK-501 in_progress u_7
obn=$(build TK-501 120 "PR_CREATED $PRU/400 | QUEUED: tier 2")
printf '%s\nSLICE: C0 of #501\n' "$PLAN_HEAD" > "$H/builds/$obn/plan.md"
audit "$obn" 0ld00000 PASS 100
nbn=$(build TK-501 30 "PR_CREATED $PRU/501 | QUEUED: tier 2")
printf '%s\n' "$PLAN_NOSLICE" > "$H/builds/$nbn/plan.md"
audit "$nbn" abc12345 PASS 10
OUT=$(run x-os)
advanced S10 TK-501

# S11: --dry-run with a slice plan -> no DRYRUN line, 0 POSTs
reset
local_case 501 TK-501 u_7 "${PLAN_HEAD}
SLICE: C0 of #501"
OUT=$(run x-os --dry-run)
grep -q DRYRUN "$T/err.txt" && bad "S11: no DRYRUN line for a held slice ($(cat "$T/err.txt"))" || ok
[ "$(posts)" = 0 ] && ok || bad "S11: 0 POSTs (got $(calls))"
line_is S11 slice-plan=1

# ── the peer path: the PR body carries the SLICE line ────────────────────────
pr_body() { # pr_body <n> <minutes-ago> <body json value>
  ghf "repos/example-org/x-os/pulls/$1" "$(jq -cn --arg m "$(isoago "$2")" --arg s "$MSHA" --argjson b "$3" \
      '{number:1, state:"closed", merged_at:$m, merge_commit_sha:$s, body:$b}')"
}
peer_body() { # peer_body <body json value> — ticket 501, partner's comment, PR 77 merged
  tk 501 TK-501 in_progress u_7
  cyg 501 60 "$PRU/77"
  pr_body 77 40 "$1"
  version "$LIVE"; compare ahead
}
held_peer() {
  [ "$(posts)" = 0 ] && ok || bad "$1: 0 POSTs (got $(calls))"
  [ "$(field_of 501 status)" = in_progress ] && ok || bad "$1: status stays in_progress (got $(field_of 501 status))"
  [ -z "$OUT" ] && ok || bad "$1: no stdout (got '$OUT')"
  grep -q '/api/internal/version' "$B/REQS.log" && bad "$1: no version read for a held slice" || ok
  line_is "$1" no-local-build=1 slice-plan=1
}

# P1: body "Why\r\n\r\nSLICE: C0 of #501\r\n" -> held
reset
peer_body '"Why\r\n\r\nSLICE: C0 of #501\r\n"'
OUT=$(run x-os)
held_peer P1

# P2: a quoted `> SLICE: C1 of #TK-501` -> held
reset
peer_body '"## Summary\n\n> SLICE: C1 of #TK-501\n"'
OUT=$(run x-os)
held_peer P2

# P3: `Part of #501` is no SLICE line -> advances
reset
peer_body '"Part of #501"'
OUT=$(run x-os)
[ "$OUT" = TK-501 ] && ok || bad "P3: advances (got '$OUT', log '$(advlog)')"
line_is P3 moved=1 no-local-build=1

# P4: body null -> advances
reset
peer_body 'null'
OUT=$(run x-os)
[ "$OUT" = TK-501 ] && ok || bad "P4: advances (got '$OUT', log '$(advlog)')"
line_is P4 moved=1 no-local-build=1

# S12 (last: it removes the lib): no slice-board.sh on the box -> the lane
# behaves as before, a slice plan does not hold (fail open, header).
reset
mv "$H/bin/lib/slice-board.sh" "$T/slice-board.sh.saved" 2>/dev/null
local_case 501 TK-501 u_7 "${PLAN_HEAD}
SLICE: C0 of #501"
OUT=$(run x-os); RC=$?
[ "$RC" = 0 ] && ok || bad "S12: rc 0 without the lib (got $RC)"
advanced S12 TK-501
[ -s "$T/err.txt" ] && bad "S12: no stderr ($(head -3 "$T/err.txt"))" || ok
mv "$T/slice-board.sh.saved" "$H/bin/lib/slice-board.sh" 2>/dev/null

# Z (budget): every request of the whole suite went to the fakes
[ -s "$ALLREQ" ] && ! grep -vE '^(GET|POST) https://x\.test/' "$ALLREQ" >/dev/null && ok \
  || bad "Z: every request went to the fake board ($(grep -vE '^(GET|POST) https://x\.test/' "$ALLREQ" | head -3))"
[ "$(command -v gh)" = "$T/fakebin/gh" ] && [ "$(command -v curl)" = "$T/fakebin/curl" ] && ok || bad "Z: the fakes are the clients"

echo "merged-ticket-advance bh-9865: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
