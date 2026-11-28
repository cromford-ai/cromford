#!/bin/bash
# tests/merged-ticket-advance.todo.bh-10236-test.sh — BH-10236 (ticket rows):
# a `todo` ticket whose own PR merged leaves `todo`, and an open ticket with no
# PR address in its thread is found by its key.
#
# project-3, 2026-11-26: TK-837, TK-834 and TK-852 showed `todo` while their
# work had been on main since 2026-11-24 (#1411, #1414, #1371, each titled
# `TK-<n>: ...`, none built on a fleet box). bin/merged-ticket-advance.sh read
# only `in_progress` and `review` tickets, and it found a peer-built ticket's
# PR only in the thread (that day: no-pr-in-thread=8).
#
# THE KEY PR. One read of the repo's closed PR list per run (newest update
# first, MERGED_ADVANCE_KEY_PR_PAGES pages of 100). A merged PR whose title
# starts with the ticket key and `:` is that ticket's PR. A title that says
# slice or part is one slice of the ticket, never the whole of it.
#   todo ticket + key PR      -> the peer path with that PR: comment, then
#                                review (client-filed) or done (system-filed).
#                                On a staging project whose production does
#                                not serve the merge: the staging comment and
#                                a move to in_progress, no turn.
#   todo ticket, no key PR    -> not a candidate: 0 requests, no count
#   in_progress/review, no PR
#   address in the thread     -> the key PR, when there is one
#
# The REAL lane against a stubbed board (fake curl) and a fake gh; the fixture
# is copied from tests/merged-ticket-advance.staging.bh-9876-test.sh.
#   T1  todo, client-filed, key PR merged, production serves it: comment,
#       review, the turn to the client
#   T2  todo, system-filed: done
#   T3  todo with no key PR: 0 requests for the ticket, 0 POSTs
#   T4  only a slice PR carries the key: not a candidate
#   T5  a slice PR and a whole PR: the whole PR is used
#   T6  the thread names another merged PR (a reference): not advanced
#   T7  a key that is a prefix of another key (TK-83 vs TK-837): no match
#   T8  staging, production behind: the staging comment, a move to in_progress,
#       no turn; the second run posts nothing
#   T9  in_progress with no PR address in the thread: advanced by its key PR
#   T10 MERGED_ADVANCE_KEY_PR=0: no closed-list read, the lane as before
#   T11 the closed list does not answer: the lane as before
#   T12 the client spoke after the merge: held
#   T13 the key PR is a pure function: mka_key_prs over one page
#   Z   0 requests left the fakes; the 2 knobs are registered
#
# MUTATIONS this suite must catch (each makes at least one case red):
#   M1 advance a todo ticket from a PR address in its thread  -> T6
#   M2 read a slice PR as the whole ticket                    -> T4, T13
#   M3 match a key by prefix                                  -> T7, T13
#   M4 read each todo ticket of the board                     -> T3
#   M5 leave a staging todo ticket in todo                    -> T8
#   M6 give the turn to the client on a staging hold          -> T8
#   M7 ignore the knob                                        -> T10
# Run from anywhere: tests/merged-ticket-advance.todo.bh-10236-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

command -v jq >/dev/null 2>&1 || { echo "merged-ticket-advance todo: jq is required"; exit 1; }
unset MERGED_ADVANCE_KEY_PR MERGED_ADVANCE_KEY_PR_PAGES 2>/dev/null || true

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
# BH-9987: a client-filed move to review with no PASS audit now needs a live
# probe of the primary screen, and this suite's fake curl answers 404 to it.
# The gate has its own suite (tests/review-probe.bh-9987-test.sh); here it is
# off, so every case below runs on the premise it was written for.
export REVIEW_PROBE_REQUIRE=0
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
     '. + [ {id:$id, key:$k, title:("Ticket " + $k), status:$s, waitingOn:"team", comments:[], activities:[]}
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
FIELDS="moved comment-only no-audit audit-fail newer-build client-spoke client-review moved-back move-gave-up no-local-build no-pr-in-thread pr-open deploy-behind peer-unread pr-ambiguous no-live-probe slice-plan slice-settle"
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

# ── this suite's own fixtures ────────────────────────────────────────────────
LISTP='repos/example-org/x-os/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1'
nostaging() { : > "$H/catalog/release-model.tsv"; }
# closed <n:title[:open]>... — page 1 of the closed PR list; `:open` = closed, never merged
closed() {
  local a n t rows='[]' m
  for a in "$@"; do
    n="${a%%:*}"; t="${a#*:}"; m=$(isoago 40)
    case "$t" in *:open) t="${t%:open}"; m="" ;; esac
    rows=$(jq -c --argjson n "$n" --arg t "$t" --arg m "$m" \
      '. + [{number: $n, title: $t, state: "closed", merged_at: (if $m == "" then null else $m end), head: {ref: ("ticket/x-" + ($n | tostring))}}]' <<<"$rows")
  done
  ghf "$LISTP" "$rows"
}
tget() { grep -c "GET $API/tickets/$1\$" "$B/REQS.log" || true; }
todolog() { grep 'MERGED_ADVANCE_TODO' "$H/logs/x-os.log" 2>/dev/null | sed 's/^.*\] //' | paste -sd'|' -; }
CT="$API/tickets/837/comments advance-x-os-837-pr-1411-abcdef12-comment"
MT="$API/tickets/837/move advance-x-os-837-pr-1411-abcdef12-move"
UT="$API/tickets/837/turn advance-x-os-837-pr-1411-abcdef12-turn"

# T13 — the pure function, over one page
PAGE=$(jq -cn '[
  {number: 1411, title: "TK-837: member Settings tabs", merged_at: "2026-11-25T01:06:33Z"},
  {number: 1500, title: "TK-837: a later fix", merged_at: "2026-11-26T01:00:00Z"},
  {number: 1757, title: "TK-848 (slice A): each AI task gets an owner", merged_at: "2026-11-26T02:00:00Z"},
  {number: 1766, title: "TK-799: the after-call text (slice 2 of 3)", merged_at: "2026-11-26T03:00:00Z"},
  {number: 1767, title: "TK-863: lower case key, part 2", merged_at: "2026-11-26T03:00:00Z"},
  {number: 1768, title: "TK-83: another ticket", merged_at: "2026-11-26T03:00:00Z"},
  {number: 1769, title: "TK-900: closed and never merged", merged_at: null},
  {number: 1770, title: "Merge queue: test up to 6 batches", merged_at: "2026-11-26T03:00:00Z"},
  {number: 1771, title: "TK-918: TK-905.3: likely member", merged_at: "2026-11-26T03:00:00Z"}]')
GOT=$( . "$DIR/bin/lib/merged-advance-key-pr.sh" 2>/dev/null && printf '%s' "$PAGE" | mka_key_prs | sort | paste -sd'|' - )
eq "T13 one row per merged PR whose title starts with a key" "$GOT" \
  "TK-799	1766	2026-11-26T03:00:00Z	1|TK-83	1768	2026-11-26T03:00:00Z	0|TK-837	1411	2026-11-25T01:06:33Z	0|TK-837	1500	2026-11-26T01:00:00Z	0|TK-848	1757	2026-11-26T02:00:00Z	1|TK-863	1767	2026-11-26T03:00:00Z	1|TK-918	1771	2026-11-26T03:00:00Z	0"
GOT=$( . "$DIR/bin/lib/merged-advance-key-pr.sh" 2>/dev/null && printf '%s' "$PAGE" | mka_key_prs | mka_key_pick TK-837 )
eq "T13 the newest whole PR of the key" "$GOT" 1500
GOT=$( . "$DIR/bin/lib/merged-advance-key-pr.sh" 2>/dev/null && printf '%s' "$PAGE" | mka_key_prs | mka_key_pick TK-848 )
eq "T13 a key with only a slice PR has no key PR" "$GOT" ""
GOT=$( . "$DIR/bin/lib/merged-advance-key-pr.sh" 2>/dev/null && printf '%s' "$PAGE" | mka_key_prs | mka_key_pick TK-8 )
eq "T13 a key is matched whole, never by prefix" "$GOT" ""

# T1 — todo, client-filed, key PR merged, production serves the merge
reset; nostaging
tk 837 TK-837 todo u_7; closed "1411:TK-837: member Settings tabs"; pr_merged 1411 40; version "$LIVE"; compare ahead
OUT=$(run x-os); RC=$?
eq "T1 rc 0" "$RC" 0
eq "T1 POSTs comment, move, turn" "$(calls)" "$CT|$MT|$UT|"
eq "T1 the move goes to review" "$(post_f body 2)" '{"toStatus":"review","sortOrder":999999}'
eq "T1 the board shows review and the client's turn" "$(field_of 837 status)/$(field_of 837 waitingOn)" review/client
eq "T1 stdout is the key" "$OUT" TK-837
case "$(post_f body 1 | jq -r .body)" in *"This is merged and production is serving it (commit abcdef12, <a href=\"$PRU/1411\">"*"Moving it to review so you can check it."*) ok ;;
  *) bad "T1 the comment names the PR and the move (got $(post_f body 1))" ;; esac
eq "T1 one TODO log line" "$(todolog)" "MERGED_ADVANCE_TODO TK-837 was todo; its PR #1411 is merged"
line_is T1 moved=1 no-local-build=1
OUT=$(run x-os)
eq "T1b the second run posts nothing" "$(posts)" 3

# T2 — system-filed: done
reset; nostaging
tk 837 TK-837 todo system; closed "1411:TK-837: member Settings tabs"; pr_merged 1411 40; version "$LIVE"; compare ahead
OUT=$(run x-os)
eq "T2 a system-filed todo ticket goes to done, no turn" "$(field_of 837 status) $(tposts)" "done 0"

# T3 — todo with no key PR: not a candidate
reset; nostaging
tk 837 TK-837 todo u_7; tk 838 TK-838 todo u_7; tk 839 TK-839 todo system; closed "1411:TK-999: another ticket"
OUT=$(run x-os)
eq "T3 0 ticket reads and 0 POSTs for 3 todo tickets" "$(tget 837)$(tget 838)$(tget 839) $(posts)" "000 0"
line_is T3

# T4 — only a slice PR carries the key
reset; nostaging
tk 848 TK-848 todo u_7; closed "1757:TK-848 (slice A): each AI task gets an owner"; pr_merged 1757 40; version "$LIVE"; compare ahead
OUT=$(run x-os)
eq "T4 a slice PR does not advance the ticket" "$(posts) $(field_of 848 status) $(tget 848)" "0 todo 0"

# T5 — a slice PR and a whole PR
reset; nostaging
tk 837 TK-837 todo u_7; closed "1757:TK-837 (slice A): first part" "1411:TK-837: member Settings tabs"
pr_merged 1411 40; pr_merged 1757 40; version "$LIVE"; compare ahead
OUT=$(run x-os)
eq "T5 the whole PR is the key PR" "$(calls)" "$CT|$MT|$UT|"

# T6 — the thread names another merged PR; there is no key PR
reset; nostaging
tk 837 TK-837 todo u_7; comment 837 u_9 90 "Blocked by <a href=\"$PRU/77\">$PRU/77</a>" Lacey
pr_merged 77 40; version "$LIVE"; compare ahead; closed "77:TK-700: the other ticket"
OUT=$(run x-os)
eq "T6 a PR address in a todo ticket's thread is a reference: 0 POSTs, still todo" "$(posts) $(field_of 837 status)" "0 todo"

# T7 — TK-83's PR is not TK-837's
reset; nostaging
tk 837 TK-837 todo u_7; closed "1768:TK-83: another ticket"; pr_merged 1768 40; version "$LIVE"; compare ahead
OUT=$(run x-os)
eq "T7 no prefix match" "$(posts) $(field_of 837 status)" "0 todo"

# T8 — a staging project, production does not serve the merge
reset
tk 837 TK-837 todo u_7; closed "1411:TK-837: member Settings tabs"; pr_merged 1411 40; sversion "$MSHA"; prod_behind
OUT=$(run x-os)
eq "T8 one comment, one move, no turn" "$(cposts)/$(mposts)/$(tposts)" 1/1/0
eq "T8 the move goes to in_progress" "$(post_f body 2)" '{"toStatus":"in_progress","sortOrder":999999}'
eq "T8 the board shows in_progress, the team's turn" "$(field_of 837 status)/$(field_of 837 waitingOn)" in_progress/team
B1=$(post_f body 1 | jq -r .body)
case "$B1" in *"This is merged and on staging"*"not live on production yet"*"Moving it to in progress. It stays there until the release is live."*) ok ;;
  *) bad "T8 the comment says on staging, not live, moved to in progress (got '$B1')" ;; esac
case "$B1" in *"so you can check it"*|*"production is serving"*) bad "T8 the comment asks for no review and claims no production (got '$B1')" ;; *) ok ;; esac
OUT=$(run x-os)
eq "T8b the second run posts nothing" "$(posts)" 2
eq "T8b the ticket stays in_progress" "$(field_of 837 status)" in_progress

# T9 — in_progress, no PR address in the thread, a key PR
reset; nostaging
tk 501 TK-501 in_progress u_7; closed "1411:TK-501: the work"; pr_merged 1411 40; version "$LIVE"; compare ahead
OUT=$(run x-os)
eq "T9 advanced to review by the key PR" "$(field_of 501 status) $OUT" "review TK-501"
line_is T9 moved=1 no-local-build=1

# T10 — the knob off
reset; nostaging
tk 837 TK-837 todo u_7; tk 501 TK-501 in_progress u_7; closed "1411:TK-837: member Settings tabs" "1412:TK-501: the work"
pr_merged 1411 40; pr_merged 1412 40; version "$LIVE"; compare ahead
OUT=$(MERGED_ADVANCE_KEY_PR=0 run x-os)
eq "T10 MERGED_ADVANCE_KEY_PR=0: 0 POSTs, 0 closed-list reads" "$(posts) $(grep -c 'pulls?state=closed' "$B/GH.log" || true)" "0 0"
line_is T10 no-local-build=1 no-pr-in-thread=1

# T11 — the closed list does not answer
reset; nostaging
tk 837 TK-837 todo u_7; tk 501 TK-501 in_progress u_7; ghf "$LISTP" '{"message":"boom"}'; ghcode "$LISTP" 500
OUT=$(run x-os)
eq "T11 an unread list: 0 POSTs, the todo ticket is not read" "$(posts) $(tget 837)" "0 0"
line_is T11 no-local-build=1 no-pr-in-thread=1

# T12 — the client spoke after the merge
reset; nostaging
tk 837 TK-837 todo u_7; closed "1411:TK-837: member Settings tabs"; pr_merged 1411 40; version "$LIVE"; compare ahead
comment 837 u_7 10 "One more thing: the Documents tab needs a download button." Client
OUT=$(run x-os)
eq "T12 a client comment after the merge holds the ticket" "$(posts) $(field_of 837 status)" "0 todo"
line_is T12 client-spoke=1 no-local-build=1

# T14 — more slice words (lead, 2026-11-26): part <letter>, phase <n>, step <n>
PAGE=$(jq -cn '[
  {number: 1, title: "TK-1: member page, part B", merged_at: "2026-11-26T03:00:00Z"},
  {number: 2, title: "TK-2: Phase 2 of the import", merged_at: "2026-11-26T03:00:00Z"},
  {number: 3, title: "TK-3: step 3: the email", merged_at: "2026-11-26T03:00:00Z"},
  {number: 4, title: "TK-4: show part of the list", merged_at: "2026-11-26T03:00:00Z"},
  {number: 5, title: "TK-5: a stepwise form for phases", merged_at: "2026-11-26T03:00:00Z"}]')
GOT=$( . "$DIR/bin/lib/merged-advance-key-pr.sh" 2>/dev/null && printf '%s' "$PAGE" | mka_key_prs | cut -f1,4 | tr '\t' '=' | paste -sd' ' - )
eq "T14 part <letter>, phase <n> and step <n> are slices; 'part of' and 'stepwise' are not" "$GOT" "TK-1=1 TK-2=1 TK-3=1 TK-4=0 TK-5=0"
for t in "TK-848: tasks, part B" "TK-848: phase 2" "TK-848: step 3"; do
  reset; nostaging
  tk 848 TK-848 todo u_7; closed "1757:$t"; pr_merged 1757 40; version "$LIVE"; compare ahead
  OUT=$(run x-os)
  eq "T14 '$t' does not advance the ticket" "$(posts) $(field_of 848 status)" "0 todo"
done

# T15 — the status changed after the merge (a person or the app moved the
# ticket back): never moved again, with no comment at all in the thread
act() { # act <id> <minutes-ago> <from> <to> — a status_change row of the board
  jq --argjson id "$1" --arg t "$(isoago "$2")" --arg f "$3" --arg to "$4" \
     'map(if .id == $id then .activities = ((.activities // []) + [{type:"status_change", fromValue:$f, toValue:$to, createdAt:$t}]) else . end)' \
     "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
}
reset; nostaging
tk 837 TK-837 todo u_7; closed "1411:TK-837: member Settings tabs"; pr_merged 1411 40; version "$LIVE"; compare ahead
act 837 300 todo in_progress; act 837 10 review todo
OUT=$(run x-os)
eq "T15 moved back after the merge: 0 POSTs, still todo" "$(posts) $(field_of 837 status)" "0 todo"
line_is T15 moved-back=1 no-local-build=1
grep -q 'MERGED_ADVANCE_MOVED_BACK TK-837 status changed .* after PR #1411 merged' "$H/logs/x-os.log" && ok || bad "T15 the log names the ticket, the change and the PR"
# T16 — a status change BEFORE the merge does not hold
reset; nostaging
tk 837 TK-837 todo u_7; closed "1411:TK-837: member Settings tabs"; pr_merged 1411 40; version "$LIVE"; compare ahead
act 837 300 in_progress todo
OUT=$(run x-os)
eq "T16 a change before the merge: the ticket moves" "$(field_of 837 status)" review
# T17 — an activity row of another type after the merge does not hold
reset; nostaging
tk 837 TK-837 todo u_7; closed "1411:TK-837: member Settings tabs"; pr_merged 1411 40; version "$LIVE"; compare ahead
jq 'map(if .id == 837 then .activities = [{type:"assignee_change", fromValue:null, toValue:"u_1", createdAt:(now | todate)}] else . end)' "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
OUT=$(run x-os)
eq "T17 only a status change holds" "$(field_of 837 status)" review

# T18 — the guard cannot read: a ticket body with no `activities` list is
# UNKNOWN, not "none". The lane does nothing and counts peer-unread.
reset; nostaging
tk 837 TK-837 todo u_7; closed "1411:TK-837: member Settings tabs"; pr_merged 1411 40; version "$LIVE"; compare ahead
jq 'map(if .id == 837 then del(.activities) else . end)' "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
OUT=$(run x-os)
eq "T18 no activities list: 0 POSTs, still todo" "$(posts) $(field_of 837 status)" "0 todo"
line_is T18 peer-unread=1 no-local-build=1
grep -q 'MERGED_ADVANCE_MOVED_BACK_UNKNOWN TK-837 ' "$H/logs/x-os.log" && ok || bad "T18 the log says the status history was not read"
# T19 — the pure function: 0 = moved after, 1 = read and none, 2 = unknown
mva() { ( . "$DIR/bin/lib/merged-advance-key-pr.sh" 2>/dev/null; printf '%s' "$2" | mka_moved_after "$1" >/dev/null; echo $? ); }
eq "T19 a later status change: 0" "$(mva 2026-11-25T01:00:00Z '{"activities":[{"type":"status_change","createdAt":"2026-11-26T01:00:00.123Z"}]}')" 0
eq "T19 an empty list: 1" "$(mva 2026-11-25T01:00:00Z '{"activities":[]}')" 1
eq "T19 the list under .ticket: 1" "$(mva 2026-11-25T01:00:00Z '{"ticket":{"activities":[{"type":"status_change","createdAt":"2026-11-20T01:00:00Z"}]}}')" 1
eq "T19 the list under .activity (the other board shape): 0" "$(mva 2026-11-25T01:00:00Z '{"activity":[{"type":"status_change","createdAt":"2026-11-26T01:00:00Z"}]}')" 0
eq "T19 the list under .ticket.activity: 1" "$(mva 2026-11-25T01:00:00Z '{"ticket":{"activity":[]}}')" 1
eq "T19 no list: 2" "$(mva 2026-11-25T01:00:00Z '{"status":"todo"}')" 2
eq "T19 a list that is not an array: 2" "$(mva 2026-11-25T01:00:00Z '{"activities":"x"}')" 2
eq "T19 merged_at not a time: 2" "$(mva soon '{"activities":[]}')" 2
eq "T19 a status change with a time not read: 2" "$(mva 2026-11-25T01:00:00Z '{"activities":[{"type":"status_change","createdAt":"yesterday"}]}')" 2
eq "T19 a body that is not JSON: 2" "$(mva 2026-11-25T01:00:00Z 'oops')" 2

# Z
for k in MERGED_ADVANCE_KEY_PR MERGED_ADVANCE_KEY_PR_PAGES; do
  eq "Z knob $k is registered" "$(jq -r '.env' "$DIR/catalog/lanes.d/_lib.merged-advance.knobs.d/$k.json" 2>/dev/null)" "$k"
done
LEFT=$(grep -vE '^(GET|POST) https://(x\.test|stg\.x\.test)/' "$ALLREQ" | head -2)
eq "Z no request left the fakes" "$LEFT" ""

echo "merged-ticket-advance.todo.bh-10236: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
