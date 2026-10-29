#!/bin/bash
# tests/merged-ticket-advance.peer-built-test.sh — BH-8786: the peer path of
# bin/merged-ticket-advance.sh. A ticket that a peer fleet built has no build
# dir on this box. The lane used to drop it with a silent `continue`; now it
# reads the build fact from the thread (the newest comment with a PR URL on the
# project repo), the merge fact from GitHub REST (pulls/<n>), and the deploy
# fact from the prod version route (or a grace window when that route is 404).
#
# WHAT THIS PINS. The REAL bin/merged-ticket-advance.sh, argv and all, against a
# stubbed board API (copied from tests/merged-ticket-advance.bh-3921-test.sh,
# plus /turn and the version route) and a fake `gh` that answers `gh api -i`
# the way gh_rest (bin/lib/gh-rest.sh) parses it. Assertions read only what
# came out: the board's POST log, the request log, the gh call log, stdout,
# stderr and logs/<p>.log. Every case asserts the full MERGED_ADVANCE line.
#
# No network: the fake curl and the fake gh are the only clients, and P11
# asserts every request went to them.
#
# Run from anywhere: tests/merged-ticket-advance.peer-built-test.sh  (exit 0 = all pass)
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
FIELDS="moved comment-only no-audit audit-fail newer-build client-spoke client-review moved-back move-gave-up no-local-build no-pr-in-thread pr-open deploy-behind peer-unread pr-ambiguous"
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
C1="$API/tickets/501/comments advance-x-os-501-pr-77-abcdef12-comment"
M1="$API/tickets/501/move advance-x-os-501-pr-77-abcdef12-move"
U1="$API/tickets/501/turn advance-x-os-501-pr-77-abcdef12-turn"
BODY_V="<p>This is merged and production is serving it (commit abcdef12, <a href=\"$PRU/77\">$PRU/77</a>). Nobody has clicked through it in production yet.</p>"
BODY_G="<p>This is merged and in main (commit abcdef12, <a href=\"$PRU/77\">$PRU/77</a>). Status: merged, deploy not confirmed from here.</p>"
REVIEW="<p>Moving it to review so you can check it.</p>"

# ---------------------------------------------------------------------------
# P1 (ticket test 1): client-filed, no build dir, PR merged, prod ahead of the
# merge -> one comment, a move to review, the turn to the client, moved=1
# ---------------------------------------------------------------------------
reset
peer 501 TK-501 in_progress u_7
OUT=$(run x-os); RC=$?
[ "$RC" = 0 ] && ok || bad "P1: rc 0 (got $RC)"
[ "$(calls)" = "$C1|$M1|$U1|" ] && ok || bad "P1: POSTs comment, move, turn (got $(calls))"
[ "$(post_f body 1 | jq -r .body)" = "$BODY_V$REVIEW" ] && ok || bad "P1: comment body (got $(post_f body 1))"
[ "$(post_f body 2)" = '{"toStatus":"review","sortOrder":999999}' ] && ok || bad "P1: move body (got $(post_f body 2))"
[ "$(post_f body 3)" = '{"to":"client"}' ] && ok || bad "P1: turn body (got $(post_f body 3))"
grep -q '—' "$B/POSTS.jsonl" && bad "P1: no em dash in a client comment" || ok
[ "$OUT" = TK-501 ] && ok || bad "P1: stdout is the key (got '$OUT')"
line_is P1 moved=1 no-local-build=1
[ "$(field_of 501 status)" = review ] && [ "$(field_of 501 waitingOn)" = client ] && ok \
  || bad "P1: board shows review/client (got $(field_of 501 status)/$(field_of 501 waitingOn))"
grep -qx "api -i -X GET repos/example-org/x-os/pulls/77" "$B/GH.log" && ok || bad "P1: the PR is read through REST (GH.log: $(cat "$B/GH.log"))"
grep -qx "api -i -X GET repos/example-org/x-os/compare/$MSHA...$LIVE" "$B/GH.log" && ok || bad "P1: the deploy is checked with compare (GH.log: $(cat "$B/GH.log"))"
grep -Eq 'graphql|^pr |^issue ' "$B/GH.log" && bad "P1: no GraphQL call (GH.log: $(cat "$B/GH.log"))" || ok
[ "$(grep -c '^GET https://x.test/api/internal/version$' "$B/REQS.log")" = 1 ] && ok || bad "P1: one version read (REQS: $(cat "$B/REQS.log"))"
[ "$(grep -c '^GET https://x.test/api/board/tickets/501$' "$B/REQS.log")" = 1 ] && ok || bad "P1: one ticket GET"
grep -rq 'tok-fixture-never-logged' "$H/logs" && bad "P1: token in a log" || ok
# P1b: prod serves the merge sha itself -> no compare call
reset
peer 501 TK-501 in_progress u_7
version "$MSHA"
OUT=$(run x-os)
[ "$OUT" = TK-501 ] && ok || bad "P1b: version == merge sha moves (got '$OUT', log '$(advlog)')"
grep -q compare "$B/GH.log" && bad "P1b: no compare call when the sha is the merge (GH.log: $(cat "$B/GH.log"))" || ok
line_is P1b moved=1 no-local-build=1
# P1c: compare says identical
reset
peer 501 TK-501 in_progress u_7
compare identical
OUT=$(run x-os)
[ "$OUT" = TK-501 ] && [ "$(calls)" = "$C1|$M1|$U1|" ] && ok || bad "P1c: identical moves (got '$OUT', $(calls))"
line_is P1c moved=1 no-local-build=1

# ---------------------------------------------------------------------------
# P2 (ticket test 2): merged_at null -> pr-open, open or closed unmerged
# ---------------------------------------------------------------------------
reset
peer 501 TK-501 in_progress u_7
pr_open 77
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P2: no POST (got $(calls))"
line_is P2 no-local-build=1 pr-open=1
grep -q 'internal/version' "$B/REQS.log" && bad "P2: no version read for an open PR" || ok
reset
peer 501 TK-501 in_progress u_7
ghf repos/example-org/x-os/pulls/77 '{"number":77,"state":"closed","merged_at":null,"merge_commit_sha":"'"$MSHA"'"}'
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P2b: no POST (got $(calls))"
line_is P2b no-local-build=1 pr-open=1

# ---------------------------------------------------------------------------
# P3 (ticket test 3): prod is behind the merge, or diverged -> deploy-behind
# ---------------------------------------------------------------------------
for st in behind diverged; do
  reset
  peer 501 TK-501 in_progress u_7
  compare "$st"
  OUT=$(run x-os)
  [ "$(posts)" = 0 ] && ok || bad "P3 $st: no POST (got $(calls))"
  line_is "P3 $st" no-local-build=1 deploy-behind=1
done

# ---------------------------------------------------------------------------
# P4 (ticket test 4): no PR URL in the thread -> no-pr-in-thread, no gh call
# ---------------------------------------------------------------------------
reset
tk 501 TK-501 in_progress u_7
comment 501 cyg 60 "Working on it" partner
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P4: no POST (got $(calls))"
[ "$(ghcalls)" = 0 ] && ok || bad "P4: no gh call (GH.log: $(cat "$B/GH.log"))"
line_is P4 no-local-build=1 no-pr-in-thread=1

# ---------------------------------------------------------------------------
# P5 (ticket test 5): a second run after the move posts nothing; P5b a move that
# failed once is retried alone with the same pr-<n>-<sha8> key
# ---------------------------------------------------------------------------
reset
peer 501 TK-501 in_progress u_7
OUT=$(run x-os)
: > "$B/POSTS.jsonl"; : > "$B/REQS.log"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P5: a second run posts nothing (got $(calls))"
[ -z "$OUT" ] && ok || bad "P5: nothing on stdout (got '$OUT')"
grep -q '/tickets/501$' "$B/REQS.log" && bad "P5: no ticket GET for a client review ticket" || ok
line_is P5 client-review=1 no-local-build=1
# the same ticket dragged back to in_progress: the moved marker wins
jq 'map(.status = "in_progress")' "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P5: a person's move back wins (got $(calls))"
line_is "P5 moved back" moved-back=1 no-local-build=1
reset
peer 501 TK-501 in_progress u_7
: > "$B/MOVE_FAIL_ONCE"
OUT=$(run x-os)
line_is "P5b run 1" comment-only=1 no-local-build=1
: > "$B/POSTS.jsonl"
OUT=$(run x-os)
[ "$(calls)" = "$M1|$U1|" ] && ok || bad "P5b: run 2 posts only the move and the turn (got $(calls))"
line_is "P5b run 2" moved=1 no-local-build=1

# ---------------------------------------------------------------------------
# P6 (ticket test 6): system-filed -> done, no turn
# ---------------------------------------------------------------------------
reset
peer 501 TK-501 in_progress system
OUT=$(run x-os)
[ "$(calls)" = "$C1|$M1|" ] && ok || bad "P6: comment and move, no turn (got $(calls))"
[ "$(post_f body 2)" = '{"toStatus":"done","sortOrder":999999}' ] && ok || bad "P6: move body (got $(post_f body 2))"
[ "$(post_f body 1 | jq -r .body)" = "$BODY_V<p>Moving it to done.</p>" ] && ok || bad "P6: body (got $(post_f body 1))"
line_is P6 moved=1 no-local-build=1

# ---------------------------------------------------------------------------
# P7 (ticket test 7): a client comment after the merge holds it; P7b the cap
# counts the peer GET and leaves .next for the next run
# ---------------------------------------------------------------------------
reset
peer 501 TK-501 in_progress u_7
comment 501 u_7 10 "One more thing" Dana
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P7: no POST (got $(calls))"
line_is P7 client-spoke=1 no-local-build=1
reset
peer 501 TK-501 in_progress u_7
tk 502 TK-502 in_progress u_7; cyg 502 60 "$PRU/77"
export MERGED_ADVANCE_MAX=1
OUT=$(run x-os)
[ "$(grep -c '/tickets/50[12]$' "$B/REQS.log")" = 1 ] && ok || bad "P7b: one ticket GET under MAX=1 (REQS: $(cat "$B/REQS.log"))"
grep -q 'MERGED_ADVANCE_CAPPED 1' <<<"$(plog)" && ok || bad "P7b: capped remainder named: $(plog)"
[ "$(cat "$H/state/merged-advance-x-os.next" 2>/dev/null)" = 502 ] && ok || bad "P7b: the next run starts at 502"
unset MERGED_ADVANCE_MAX

# ---------------------------------------------------------------------------
# P8: no version route (404) -> the grace window after merged_at
# ---------------------------------------------------------------------------
reset
peer 501 TK-501 in_progress u_7
echo 404 > "$B/VERSION_CODE"
OUT=$(run x-os)
[ "$(calls)" = "$C1|$M1|$U1|" ] && ok || bad "P8a: grace passed moves (got $(calls))"
[ "$(post_f body 1 | jq -r .body)" = "$BODY_G$REVIEW" ] && ok || bad "P8a: grace wording (got $(post_f body 1))"
grep -q compare "$B/GH.log" && bad "P8a: no compare without a live sha" || ok
line_is P8a moved=1 no-local-build=1
reset
peer 501 TK-501 in_progress u_7
pr_merged 77 5
echo 404 > "$B/VERSION_CODE"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P8b: inside the grace window, no POST (got $(calls))"
line_is P8b no-local-build=1 deploy-behind=1
reset
peer 501 TK-501 in_progress u_7
pr_merged 77 5
echo 404 > "$B/VERSION_CODE"
OUT=$(MERGED_ADVANCE_DEPLOY_GRACE_S=60 run x-os)
[ "$OUT" = TK-501 ] && ok || bad "P8c: GRACE=60 moves a 5 min old merge (got '$OUT', log '$(advlog)')"
line_is P8c moved=1 no-local-build=1

# ---------------------------------------------------------------------------
# P9: which thread comment is the build fact
# ---------------------------------------------------------------------------
reset
tk 501 TK-501 in_progress u_7
cyg 501 60 "https://GitHub.com/example-org/X-OS/pull/77"
pr_merged 77 40; version "$LIVE"; compare ahead
OUT=$(run x-os)
[ "$(calls)" = "$C1|$M1|$U1|" ] && ok || bad "P9a: the slug matches case-insensitively (got $(calls), log '$(advlog)')"
reset
tk 501 TK-501 in_progress u_7
cyg 501 90 "$PRU/70"
cyg 501 60 "$PRU/77"
pr_open 70; pr_merged 77 40; version "$LIVE"; compare ahead
OUT=$(run x-os)
[ "$(calls)" = "$C1|$M1|$U1|" ] && ok || bad "P9b: the newest PR comment wins (got $(calls), log '$(advlog)')"
grep -q 'pulls/70' "$B/GH.log" && bad "P9b: the older PR is not read" || ok
reset
tk 501 TK-501 in_progress u_7
cyg 501 60 "https://github.com/example-org/x-os-web/pull/77"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && [ "$(ghcalls)" = 0 ] && ok || bad "P9c: another repo is not the build fact (posts $(posts), gh $(ghcalls))"
line_is P9c no-local-build=1 no-pr-in-thread=1
reset
tk 501 TK-501 in_progress u_7
cyg 501 60 "https://github.com/example-org/x-os/issues/77"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && [ "$(ghcalls)" = 0 ] && ok || bad "P9d: an issue URL is not a PR"
line_is P9d no-local-build=1 no-pr-in-thread=1
reset
tk 501 TK-501 in_progress u_7
cyg 501 60 "$PRU/77" "$PRU/78"
pr_merged 77 40
OUT=$(run x-os)
[ "$(posts)" = 0 ] && [ "$(ghcalls)" = 0 ] && ok || bad "P9e: two PRs in one comment is not a guess (posts $(posts), gh $(ghcalls))"
line_is P9e no-local-build=1 pr-ambiguous=1
reset
tk 501 TK-501 in_progress u_7
cyg 501 60 "$PRU/77"
cyg 501 30 "$PRU/78"
pr_merged 77 40; pr_open 78; version "$LIVE"; compare ahead
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P9f: a newer open PR holds it (got $(calls))"
line_is P9f no-local-build=1 pr-open=1

# ---------------------------------------------------------------------------
# P10: unknown is never yes (D11) -> peer-unread, nothing posted
# ---------------------------------------------------------------------------
reset
peer 501 TK-501 in_progress u_7
ghf repos/example-org/x-os/pulls/77 "{\"state\":\"closed\",\"merged_at\":\"$(isoago 40)\",\"merge_commit_sha\":null}"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P10a: no merge sha, no POST (got $(calls))"
line_is P10a no-local-build=1 peer-unread=1
for code in 404 500; do
  reset
  peer 501 TK-501 in_progress u_7
  ghcode repos/example-org/x-os/pulls/77 "$code"
  OUT=$(run x-os)
  [ "$(posts)" = 0 ] && ok || bad "P10b $code: no POST (got $(calls))"
  line_is "P10b $code" no-local-build=1 peer-unread=1
done
reset
peer 501 TK-501 in_progress u_7
echo 500 > "$B/VERSION_CODE"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P10c: version 500, no POST (got $(calls))"
line_is P10c no-local-build=1 peer-unread=1
reset
peer 501 TK-501 in_progress u_7
echo '{}' > "$B/VERSION"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P10d: version without a sha, no POST (got $(calls))"
line_is P10d no-local-build=1 peer-unread=1
reset
peer 501 TK-501 in_progress u_7
ghcode "repos/example-org/x-os/compare/$MSHA...$LIVE" 500
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P10d2: compare unread, no POST (got $(calls))"
line_is P10d2 no-local-build=1 peer-unread=1
reset
peer 501 TK-501 in_progress u_7
: > "$B/GH_PROBE_FAIL"
OUT=$(run x-os); OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "P10e: invisible repo, no POST (got $(calls))"
line_is P10e no-local-build=1 peer-unread=1
[ "$(grep -c 'merged-advance.*example-org/x-os' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "P10e: one ALERTS line over two runs (ALERTS: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
grep -q 'pulls/77' "$B/GH.log" && bad "P10e: no PR read without a credential" || ok
reset
peer 501 TK-501 in_progress u_7
echo 500 > "$B/rec-501.code"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && [ "$(ghcalls)" = 0 ] && ok || bad "P10g: an unread ticket record, nothing more"
line_is P10g no-local-build=1 peer-unread=1
reset
OUT=$(run ghproj); RC=$?
[ "$RC" = 0 ] && [ "$(reqs)" = 0 ] && [ "$(ghcalls)" = 0 ] && ok \
  || bad "P10f: a - board makes no request (rc=$RC reqs=$(reqs) gh=$(ghcalls))"

# ---------------------------------------------------------------------------
# P12: dry run reads, writes nothing, and names the turn
# ---------------------------------------------------------------------------
reset
peer 501 TK-501 in_progress u_7
OUT=$(run x-os --dry-run)
[ "$(posts)" = 0 ] && ok || bad "P12: dry run posts nothing (got $(calls))"
grep -qxF "DRYRUN POST $API/tickets/501/turn {\"to\":\"client\"}" "$T/err.txt" && ok || bad "P12: names the turn: $(cat "$T/err.txt")"
[ "$(grep -c '^DRYRUN POST' "$T/err.txt")" = 3 ] && ok || bad "P12: three DRYRUN calls: $(cat "$T/err.txt")"
ls "$H/state"/merged-advance-x-os-501-* >/dev/null 2>&1 && bad "P12: dry run writes no marker" || ok

# ---------------------------------------------------------------------------
# P13: the turn on the local path too (a build dir and a PASS audit); P14 a
# failed turn is a log line, the move still counts
# ---------------------------------------------------------------------------
reset
tk 601 TK-601 in_progress u_7
bn="x-os-TK-601-$(tsago 30)"; mkdir -p "$H/builds/$bn"; echo "PR_CREATED $PRU/601" > "$H/builds/$bn/RESULT"
printf '%s %s abc12345 PASS\n' "$(stago 10)" "$bn" > "$H/state/postmerge-qa-done.txt"
OUT=$(run x-os)
[ "$(calls)" = "$API/tickets/601/comments advance-x-os-601-abc12345-comment|$API/tickets/601/move advance-x-os-601-abc12345-move|$API/tickets/601/turn advance-x-os-601-abc12345-turn|" ] \
  && ok || bad "P13: local path gives the turn too (got $(calls))"
line_is P13 moved=1
reset
peer 501 TK-501 in_progress u_7
echo 500 > "$B/TURN_CODE"
OUT=$(run x-os)
[ "$OUT" = TK-501 ] && ok || bad "P14: the move stands (got '$OUT')"
line_is P14 moved=1 no-local-build=1
grep -qF 'MERGED_ADVANCE_TURN_FAILED TK-501 HTTP 500' <<<"$(plog)" && ok || bad "P14: turn failure logged: $(plog)"

# ---------------------------------------------------------------------------
# P11 (budget): every request of the whole suite went to the fakes
# ---------------------------------------------------------------------------
[ -s "$ALLREQ" ] && ! grep -vE '^(GET|POST) https://x\.test/' "$ALLREQ" >/dev/null && ok \
  || bad "P11: every request went to the fake board ($(grep -vE '^(GET|POST) https://x\.test/' "$ALLREQ" | head -3))"
[ "$(command -v gh)" = "$T/fakebin/gh" ] && [ "$(command -v curl)" = "$T/fakebin/curl" ] && ok || bad "P11: the fakes are the clients"

echo "merged-ticket-advance peer-built: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
