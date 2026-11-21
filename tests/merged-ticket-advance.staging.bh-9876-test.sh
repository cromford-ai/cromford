#!/bin/bash
# tests/merged-ticket-advance.staging.bh-9876-test.sh — BH-9876: for a staging
# project (catalog/release-model.tsv) bin/merged-ticket-advance.sh asks what
# PRODUCTION serves before it writes.
#   production serves the merge  -> the production comment, the normal move
#   production does not serve it -> "on staging, not live on production yet",
#                                   NO move and NO turn (the app audit moves the
#                                   ticket after the release), once
#   production unreadable        -> nothing this run
# TK-787 (2026-11-21): a system-filed ticket went to done on a comment that
# said "not live", 51 minutes after production served the commit.
#
# The REAL lane against a stubbed board (fake curl) and a fake gh, fixtures
# copied from tests/merged-ticket-advance.bh-9865-test.sh. 0 network: Z asserts
# every request went to the fakes. Each case calls reset and seeds its own
# build dirs; no case reads another case's state.
#
# Run from anywhere: tests/merged-ticket-advance.staging.bh-9876-test.sh  (exit 0 = all pass)
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
      if [ -e "$STUBDIR/COMMENT_FAIL_ONCE" ]; then
        rm -f "$STUBDIR/COMMENT_FAIL_ONCE"; w '{"error":"boom"}'; printf 500; exit 0
      fi
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
  https://stg.x.test/api/internal/version)
    # the staging site: no production bearer may reach it
    [ "$AUTH" = 0 ] || echo "AUTH-TO-STAGING $URL" >> "$STUBDIR/LEAK.log"
    w "$(cat "$STUBDIR/SVERSION" 2>/dev/null)" ;;
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
  echo '[]' > "$B/db.json"; : > "$B/REQS.log"; : > "$B/POSTS.jsonl"; : > "$B/GH.log"; : > "$B/LEAK.log"
  mkdir -p "$H/catalog"
  printf 'x-os\tstaging\thttps://stg.x.test\thttps://stg.x.test/api/internal/version\n' > "$H/catalog/release-model.tsv"
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
  audit "$bn" abc12345 "${5:-PASS}" 10
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
# ── staging fixtures ─────────────────────────────────────────────────────────
NOQA=NOT_COVERED_NO_QA_ENV
sversion() { printf '{"sha":"%s"}' "$1" > "$B/SVERSION"; }
# stg_local <id> <key> <reporter> — an in_progress ticket whose newest build
# opened PR <id>, merged 40 min ago as $MSHA, audit NOT_COVERED_NO_QA_ENV.
stg_local() {
  local_case "$1" "$2" "$3" - "$NOQA"
  pr_merged "$1" 40
}
prod_behind() { version "$LIVE"; compare behind; }   # production has an older release
prod_ahead()  { version "$LIVE"; compare ahead; }    # production has a newer release
prod_same()   { version "$MSHA"; }                   # production serves the merge commit
body1() { post_f body 1; }
nopost() { # nopost <case> <id> — nothing written, status unchanged
  [ "$(posts)" = 0 ] && ok || bad "$1: 0 POSTs (got $(calls))"
  [ "$(field_of "$2" status)" = in_progress ] && ok || bad "$1: status stays in_progress (got $(field_of "$2" status))"
  [ -z "$OUT" ] && ok || bad "$1: no stdout (got '$OUT')"
}
# held <case> <id> — the comment-only outcome
held() {
  [ "$(cposts)/$(mposts)/$(tposts)" = 1/0/0 ] && ok || bad "$1: one comment, no move, no turn (got $(calls))"
  [ "$(field_of "$2" status)" = in_progress ] && ok || bad "$1: status stays in_progress (got $(field_of "$2" status))"
  [ "$(field_of "$2" waitingOn)" = team ] && ok || bad "$1: waitingOn stays team (got $(field_of "$2" waitingOn))"
  B1=$(body1)
  case "$B1" in *"This is merged and on staging"*"not live on production yet"*"stays in progress until the release is live"*) ok ;;
    *) bad "$1: the comment says on staging, not live, stays in progress (got '$B1')" ;; esac
  case "$B1" in *"Moving it to"*|*"production is serving"*) bad "$1: the comment names no move and no production claim (got '$B1')" ;; *) ok ;; esac
  case "$B1" in *"https://stg.x.test"*) ok ;; *) bad "$1: the comment links staging (got '$B1')" ;; esac
  [ -z "$OUT" ] && ok || bad "$1: no stdout, nothing moved (got '$OUT')"
}

# A1: system-filed, production does not serve the merge -> comment only.
# Before BH-9876: moved to done.
reset
stg_local 501 TK-501 system; prod_behind
OUT=$(run x-os); RC=$?
[ "$RC" = 0 ] && ok || bad "A1: rc 0 (got $RC)"
held A1 501
line_is A1 comment-only=1
# A1b: the second run writes nothing
OUT=$(run x-os)
[ "$(posts)" = 1 ] && ok || bad "A1b: the second run posts nothing (got $(calls))"
[ "$(field_of 501 status)" = in_progress ] && ok || bad "A1b: status stays in_progress"
line_is A1b moved-back=1

# A2: client-filed, production does not serve the merge -> comment only.
# Before BH-9876: moved to review with the turn to the client.
reset
stg_local 501 TK-501 u_7; prod_behind
OUT=$(run x-os)
held A2 501
line_is A2 comment-only=1

# A3: production on a diverged commit is "does not serve" too
reset
stg_local 501 TK-501 u_7; version "$LIVE"; compare diverged
OUT=$(run x-os)
held A3 501

# A4: --dry-run prints the comment and no move line
reset
stg_local 501 TK-501 system; prod_behind
OUT=$(run x-os --dry-run)
grep -q "DRYRUN POST $API/tickets/501/comments" "$T/err.txt" && ok || bad "A4: the dry run prints the comment ($(cat "$T/err.txt"))"
grep -q '/move' "$T/err.txt" && bad "A4: the dry run prints no move line ($(cat "$T/err.txt"))" || ok
[ "$(posts)" = 0 ] && ok || bad "A4: 0 POSTs (got $(calls))"

# A5: a system-filed ticket already in review, production does not serve -> left alone
reset
tk 501 TK-501 review system
bn=$(build TK-501 30 "PR_CREATED $PRU/501 | QUEUED: tier 2"); audit "$bn" abc12345 "$NOQA" 10
pr_merged 501 40; prod_behind
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "A5: 0 POSTs (got $(calls))"
[ "$(field_of 501 status)" = review ] && ok || bad "A5: status stays review (got $(field_of 501 status))"
line_is A5 client-review=1

# B1: system-filed, production serves the merge commit -> the production
# comment and done, no "not live".
reset
stg_local 501 TK-501 system; prod_same
OUT=$(run x-os)
[ "$OUT" = TK-501 ] && ok || bad "B1: stdout is the key (got '$OUT', log '$(advlog)')"
[ "$(cposts)/$(mposts)/$(tposts)" = 1/1/0 ] && ok || bad "B1: one comment, one move, no turn (got $(calls))"
[ "$(field_of 501 status)" = done ] && ok || bad "B1: status done (got $(field_of 501 status))"
B1=$(body1)
case "$B1" in *"This is merged and production is serving it"*"Moving it to done"*) ok ;; *) bad "B1: the production comment (got '$B1')" ;; esac
case "$B1" in *"not live"*|*"on staging"*) bad "B1: no staging words when production serves it (got '$B1')" ;; *) ok ;; esac
line_is B1 moved=1

# B2: client-filed, production is AHEAD of the merge (compare API) -> review
# and the turn to the client.
reset
stg_local 501 TK-501 u_7; prod_ahead
OUT=$(run x-os)
[ "$OUT" = TK-501 ] && ok || bad "B2: stdout is the key (got '$OUT', log '$(advlog)')"
[ "$(cposts)/$(mposts)/$(tposts)" = 1/1/1 ] && ok || bad "B2: one comment, one move, one turn (got $(calls))"
[ "$(field_of 501 status)" = review ] && ok || bad "B2: status review (got $(field_of 501 status))"
[ "$(field_of 501 waitingOn)" = client ] && ok || bad "B2: turn to client (got $(field_of 501 waitingOn))"
B1=$(body1)
case "$B1" in *"This is merged and production is serving it"*"Moving it to review so you can check it."*) ok ;; *) bad "B2: the production comment (got '$B1')" ;; esac
case "$B1" in *"not live"*|*"on staging"*) bad "B2: no staging words when production serves it (got '$B1')" ;; *) ok ;; esac

# C1: the production version route answers 500 -> nothing this run
reset
stg_local 501 TK-501 system; prod_behind; echo 500 > "$B/VERSION_CODE"
OUT=$(run x-os)
nopost C1 501
line_is C1 peer-unread=1

# C2: production on another commit and the compare read fails -> nothing
reset
stg_local 501 TK-501 system; version "$LIVE"
OUT=$(run x-os)
nopost C2 501
line_is C2 peer-unread=1

# C3: the PR read fails (no merge commit known) -> nothing
reset
local_case 501 TK-501 system - "$NOQA"; prod_same
OUT=$(run x-os)
nopost C3 501
line_is C3 peer-unread=1

# C4: no credential sees the repo -> nothing
reset
stg_local 501 TK-501 system; prod_same; : > "$B/GH_PROBE_FAIL"
OUT=$(run x-os)
nopost C4 501

# C5: a merge commit left by an EARLIER ticket is never reused: ticket 500's
# PR is merged and served, ticket 501's PR read fails.
reset
stg_local 500 TK-500 system
local_case 501 TK-501 system - "$NOQA"
prod_same
OUT=$(run x-os)
[ "$(field_of 500 status)" = done ] && ok || bad "C5: ticket 500 is moved (got $(field_of 500 status))"
[ "$(field_of 501 status)" = in_progress ] && ok || bad "C5: ticket 501 is not moved on ticket 500's commit (got $(field_of 501 status))"
[ "$(cposts)" = 1 ] && ok || bad "C5: one comment, for ticket 500 only (got $(calls))"

# P1: the peer path (no build dir): staging serves the merge, production does
# not -> comment only.
reset
peer 501 TK-501 in_progress u_7
sversion "$MSHA"; prod_behind
OUT=$(run x-os)
held P1 501
line_is P1 comment-only=1 no-local-build=1

# P2: the peer path, production serves the merge -> review and the turn
reset
peer 501 TK-501 in_progress u_7
sversion "$MSHA"; prod_same
OUT=$(run x-os)
[ "$OUT" = TK-501 ] && ok || bad "P2: stdout is the key (got '$OUT', log '$(advlog)')"
[ "$(field_of 501 status)" = review ] && ok || bad "P2: status review (got $(field_of 501 status))"
case "$(body1)" in *"production is serving it"*) ok ;; *) bad "P2: the production comment (got '$(body1)')" ;; esac

ncomments() { jq -r --argjson id "$1" '.[] | select(.id == $id) | .comments | length' "$B/db.json"; }
CLOSEOUT_NOTLIVE="This is merged and on its way to staging. It is not live on production yet. It goes live with the next release. Code: <a href=\"$PRU/501\">$PRU/501</a>"

# E1: the thread holds ONLY the close-out's "on its way to staging ... not
# live" comment, the audit row has no sha (the witness is the PR address), and
# production serves the merge -> the production comment IS posted, then the
# move. Without it the last word on a done ticket is "not live" (TK-787).
reset
tk 501 TK-501 in_progress system
bn=$(build TK-501 30 "PR_CREATED $PRU/501 | QUEUED: tier 2"); audit "$bn" - "$NOQA" 10
comment 501 u-h 20 "$CLOSEOUT_NOTLIVE" "System Harness"
pr_merged 501 40; prod_same
OUT=$(run x-os)
[ "$(cposts)/$(mposts)" = 1/1 ] && ok || bad "E1: the production comment is posted, then the move (got $(calls))"
case "$(body1)" in *"This is merged and production is serving it"*) ok ;; *) bad "E1: the posted comment is the production one (got '$(body1)')" ;; esac
[ "$(field_of 501 status)" = done ] && ok || bad "E1: status done (got $(field_of 501 status))"
[ "$(post_f idem 1)" = "advance-x-os-501-$(tsago 30)-live-comment" ] && ok || bad "E1: the production comment has its own idempotency key (got $(post_f idem 1))"
# E1b: a second run adds no second production comment
OUT=$(run x-os)
[ "$(ncomments 501)" = 2 ] && ok || bad "E1b: two comments in the thread, no third (got $(ncomments 501))"

# E2: a production comment of this lane already in the thread (the move failed
# last run) -> no second comment, the move only.
reset
stg_local 501 TK-501 system; prod_same; : > "$B/MOVE_FAIL_ONCE"
OUT=$(run x-os)
[ "$(field_of 501 status)" = in_progress ] && ok || bad "E2: the first move fails (got $(field_of 501 status))"
OUT=$(run x-os)
[ "$(ncomments 501)" = 1 ] && ok || bad "E2: one comment after the retry (got $(ncomments 501))"
[ "$(field_of 501 status)" = done ] && ok || bad "E2: the retry moves it (got $(field_of 501 status))"

# E3: no, then the release. Run 1 with production behind: comment, no move.
# Then production serves the merge: run 2 writes nothing, because the hold
# marker ended this lane's work and the app audit owns the move.
reset
stg_local 501 TK-501 system; prod_behind
OUT=$(run x-os)
held E3 501
prod_same
OUT=$(run x-os)
[ "$(posts)" = 1 ] && ok || bad "E3: the run after the release posts nothing (got $(calls))"
[ "$(field_of 501 status)" = in_progress ] && ok || bad "E3: status stays in_progress for the app audit (got $(field_of 501 status))"
line_is E3 moved-back=1

# E4: the comment POST fails in the "no" case -> no hold marker, and the next
# run posts the comment once.
reset
stg_local 501 TK-501 system; prod_behind; : > "$B/COMMENT_FAIL_ONCE"
OUT=$(run x-os)
[ "$(ncomments 501)" = 0 ] && ok || bad "E4: the failed POST left no comment (got $(ncomments 501))"
[ "$(mposts)" = 0 ] && ok || bad "E4: no move after a failed comment (got $(calls))"
grep -q 'MERGED_ADVANCE_FAILED TK-501 comment HTTP 500' "$H/logs/x-os.log" && ok || bad "E4: the failure is logged ($(plog | tail -2))"
OUT=$(run x-os)
[ "$(ncomments 501)" = 1 ] && ok || bad "E4: the next run posts the comment once (got $(ncomments 501))"
line_is E4 comment-only=1
OUT=$(run x-os)
[ "$(ncomments 501)" = 1 ] && ok || bad "E4: a third run adds nothing (got $(ncomments 501))"

# L: the production bearer never reached the staging site, in any case above
[ -s "$B/LEAK.log" ] && bad "L: a bearer reached staging ($(head -2 "$B/LEAK.log"))" || ok

# D1 (no row): the lane is as before. No GitHub call, no production version
# read, the PASS comment, review and the turn.
reset
rm -f "$H/catalog/release-model.tsv"
local_case 501 TK-501 u_7 -
OUT=$(run x-os)
[ "$OUT" = TK-501 ] && ok || bad "D1: stdout is the key (got '$OUT', log '$(advlog)')"
[ "$(cposts)/$(mposts)/$(tposts)" = 1/1/1 ] && ok || bad "D1: one comment, one move, one turn (got $(calls))"
[ "$(field_of 501 status)" = review ] && ok || bad "D1: status review (got $(field_of 501 status))"
case "$(body1)" in *"This is merged and the post-merge check passed in production"*"Moving it to review so you can check it."*) ok ;; *) bad "D1: the comment is the one this lane always wrote (got '$(body1)')" ;; esac
[ "$(ghcalls)" = 0 ] && ok || bad "D1: no GitHub call for a project with no row (got $(cat "$B/GH.log"))"
VR=$(grep -c '/api/internal/version' "$B/REQS.log")
[ "$VR" = 0 ] && ok || bad "D1: no version read for a project with no row (got $VR)"
line_is D1 moved=1
# D2 (no row, system-filed): done, as before
reset
rm -f "$H/catalog/release-model.tsv"
local_case 501 TK-501 system -
OUT=$(run x-os)
[ "$(field_of 501 status)" = done ] && ok || bad "D2: status done (got $(field_of 501 status))"

# Z (budget): every request of the whole suite went to the fakes
BADREQ=$(grep -vE '^(GET|POST) https://(stg\.)?x\.test/' "$ALLREQ" | head -3)
[ -s "$ALLREQ" ] && [ -z "$BADREQ" ] && ok || bad "Z: every request went to the fake board ($BADREQ)"
[ "$(command -v gh)" = "$T/fakebin/gh" ] && [ "$(command -v curl)" = "$T/fakebin/curl" ] && ok || bad "Z: the fakes are the clients"

echo "merged-ticket-advance staging bh-9876: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
