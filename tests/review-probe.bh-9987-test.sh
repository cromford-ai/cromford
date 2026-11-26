#!/bin/bash
# tests/review-probe.bh-9987-test.sh — BH-9987: a ticket reaches `review` only
# after a live probe of its primary screen.
#
#   A    bin/lib/review-probe.sh: the decision table of rp_probe/rp_passes, the
#        primary route of rp_primary_route, the knobs of rp_required and the
#        probe timeout. A fake curl answers the `-w` line of each row.
#   B1-B5 the real bin/board-closeout.sh against a stub board: PR_CREATED on an
#        in-app board moves to in_progress, never review; the knob at 0 gives
#        review back; PR_MERGED, the issues lane and a missing lib are as before.
#   C1-C11 the real bin/merged-ticket-advance.sh against a stub board: a
#        client-filed move to review that no signed-in QA pass covered needs the
#        probe to answer; a hold posts nothing and alerts once.
#   Z    every request went to the fakes (0 network).
#
# Each case seeds its own scratch state. No case reads another case's state.
# Run from anywhere: tests/review-probe.bh-9987-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
unset REVIEW_PROBE_REQUIRE REVIEW_PROBE_TIMEOUT_S REVIEW_PROBE_MAX_REDIRS 2>/dev/null || true
export JOBS_ALERT=0
ALLREQ="$T/ALLREQS.log"; : > "$ALLREQ"; export ALLREQ

# ══ A — the library ═══════════════════════════════════════════════════════
AB="$T/a/fakebin"; mkdir -p "$AB"
cat > "$AB/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$RP_ARGS"
printf 'GET %s\n' "${!#}" >> "$ALLREQ"
printf '%s' "${RP_FAKE_OUT:-}"
STUB
chmod +x "$AB/curl"
RP_ARGS="$T/a/args"; export RP_ARGS
# probe_row <curl -w answer> <want outcome> <want passes 0|1>
probe_row() {
  local got
  got=$(env PATH="$AB:$PATH" RP_FAKE_OUT="$1" bash -c '
    . "$0/bin/lib/review-probe.sh" || exit 9
    line=$(rp_probe https://app.t /clients)
    rp_probe https://app.t /clients >/dev/null
    o=$(printf "%s" "$line" | cut -f1)
    [ "$o" = "$RP_OUTCOME" ] || { echo "line/var differ: $line / $RP_OUTCOME"; exit 0; }
    p=0; rp_passes "$RP_OUTCOME" && p=1
    printf "%s %s" "$RP_OUTCOME" "$p"' "$DIR" 2>&1)
  [ "$got" = "$2 $3" ] && ok || bad "A probe '$1' must be '$2 $3' (got '$got')"
}
probe_row '200 https://app.t/clients'                          served 1
probe_row '200 https://app.t/clients/'                         served 1
probe_row '200 https://app.t/clients?tab=1'                    served 1
probe_row '200 https://APP.t/clients#top'                      served 1
probe_row '200 https://app.t/sign-in?redirect_url=%2Fclients'  signin 1
probe_row '200 https://accounts.app.t/sign-in'                 signin 1
probe_row '200 https://app.t/login'                            signin 1
probe_row '200 https://app.t/'                                 elsewhere 0
probe_row '200 https://app.t/clients-old'                      elsewhere 0
probe_row '200 https://app.t/sign-in-help'                     elsewhere 0
probe_row '200 https://other.t/clients'                        elsewhere 0
probe_row '404 https://app.t/clients'                          error 0
probe_row '500 https://app.t/clients'                          error 0
probe_row '302 https://app.t/x'                                error 0
probe_row '000 '                                               error 0
probe_row ''                                                   error 0
probe_row 'garbage'                                            error 0
probe_row '200 not-a-url'                                      error 0

# The probed URL, the timeout knob, no auth header, one GET.
: > "$RP_ARGS"
env PATH="$AB:$PATH" RP_FAKE_OUT='200 https://app.t/clients' bash -c '. "$0/bin/lib/review-probe.sh"; rp_probe https://app.t /clients >/dev/null' "$DIR"
A1=$(cat "$RP_ARGS")
case "$A1" in *"--max-time 20 "*) ok ;; *) bad "A the probe must carry --max-time 20 with no knob (got '$A1')" ;; esac
case "$A1" in *" https://app.t/clients") ok ;; *) bad "A the probe must GET <base><route> (got '$A1')" ;; esac
case "$A1" in *Authorization*|*-X\ POST*) bad "A the probe must send no auth and no POST (got '$A1')" ;; *) ok ;; esac
[ "$(grep -c . "$RP_ARGS")" = 1 ] && ok || bad "A one probe is one curl call (got $(grep -c . "$RP_ARGS"))"
: > "$RP_ARGS"
env PATH="$AB:$PATH" REVIEW_PROBE_TIMEOUT_S=5 RP_FAKE_OUT='200 https://app.t/clients' bash -c '. "$0/bin/lib/review-probe.sh"; rp_probe https://app.t/ /clients >/dev/null' "$DIR"
case "$(cat "$RP_ARGS")" in *"--max-time 5 "*" https://app.t/clients") ok ;; *) bad "A REVIEW_PROBE_TIMEOUT_S=5 must reach curl, and a base slash must not double (got '$(cat "$RP_ARGS")')" ;; esac
: > "$RP_ARGS"
env PATH="$AB:$PATH" REVIEW_PROBE_TIMEOUT_S=abc RP_FAKE_OUT='200 https://app.t/clients' bash -c '. "$0/bin/lib/review-probe.sh"; rp_probe https://app.t /clients >/dev/null' "$DIR"
case "$(cat "$RP_ARGS")" in *"--max-time 20 "*) ok ;; *) bad "A a non-number timeout must read 20 (got '$(cat "$RP_ARGS")')" ;; esac
# The redirect cap is the knob REVIEW_PROBE_MAX_REDIRS; 5 is only its fallback.
case "$A1" in *"--max-redirs 5 "*) ok ;; *) bad "A the probe must carry --max-redirs 5 with no knob (got '$A1')" ;; esac
: > "$RP_ARGS"
env PATH="$AB:$PATH" REVIEW_PROBE_MAX_REDIRS=9 RP_FAKE_OUT='200 https://app.t/clients' bash -c '. "$0/bin/lib/review-probe.sh"; rp_probe https://app.t /clients >/dev/null' "$DIR"
case "$(cat "$RP_ARGS")" in *"--max-redirs 9 "*) ok ;; *) bad "A REVIEW_PROBE_MAX_REDIRS=9 must reach curl (got '$(cat "$RP_ARGS")')" ;; esac
: > "$RP_ARGS"
env PATH="$AB:$PATH" REVIEW_PROBE_MAX_REDIRS=x RP_FAKE_OUT='200 https://app.t/clients' bash -c '. "$0/bin/lib/review-probe.sh"; rp_probe https://app.t /clients >/dev/null' "$DIR"
case "$(cat "$RP_ARGS")" in *"--max-redirs 5 "*) ok ;; *) bad "A a non-number redirect cap must read 5 (got '$(cat "$RP_ARGS")')" ;; esac
OUT=$(env PATH="$AB:$PATH" bash -c '. "$0/bin/lib/review-probe.sh"; rp_probe "" /clients; echo "rc=$? $RP_OUTCOME"' "$DIR")
case "$OUT" in *"rc=0 error") ok ;; *) bad "A an empty base must be error with no request (got '$OUT')" ;; esac

# rp_required
req() { env "$@" bash -c '. "$0/bin/lib/review-probe.sh"; rp_required x-os' "$DIR"; }
[ "$(req LANE_GATE_DISABLE=1)" = 1 ] && ok || bad "A rp_required defaults to 1"
[ "$(req LANE_GATE_DISABLE=1 REVIEW_PROBE_REQUIRE=0)" = 0 ] && ok || bad "A REVIEW_PROBE_REQUIRE=0 reads 0"
[ "$(req LANE_GATE_DISABLE=1 REVIEW_PROBE_REQUIRE=yes)" = 1 ] && ok || bad "A anything but 0 reads 1"

# rp_primary_route
PR_DIR="$T/a/plans"; mkdir -p "$PR_DIR"
route_case() { # route_case <name> <plan text|-> <want>
  local f="$PR_DIR/$1.md" got
  if [ "$2" = - ]; then f="$PR_DIR/absent.md"; else printf '%s\n' "$2" > "$f"; fi
  got=$(bash -c '. "$0/bin/lib/review-probe.sh"; rp_primary_route "$1"' "$DIR" "$f")
  [ "$got" = "$3" ] && ok || bad "A route $1 must be '$3' (got '$got')"
}
route_case first   $'# p\n## QA screens\n- /clients — the list\n- /settings\n## Size\n- /other' /clients
route_case dynamic $'## QA screens\n- /clients/[id] — a client\n- /clients — the list\n' /clients
route_case system  $'## QA screens\nRun /tmp/x then open /reports.\n' /reports
route_case query   $'## QA screens\n- `/reports?tab=2#top`\n' /reports
route_case after   $'## QA screens\nNone here.\n## Size\n- /clients\n' /
route_case nosect  $'# p\n- /clients\n' /
route_case nofile  - /
route_case andor   $'## QA screens\nCheck and/or open the page at /billing.\n' /billing

# ══ the stub board for B ══════════════════════════════════════════════════
FB="$T/b/fakebin"; mkdir -p "$FB"
cat > "$FB/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""
for a in "$@"; do [ "${prev:-}" = -d ] && BODY="$a"; prev="$a"; done
printf '%s\n' "$URL" >> "$CURL_LOG"
printf 'POST %s\n' "$URL" >> "$ALLREQ"
case "$URL" in
  https://app.example.test/*/comments) printf '%s\n' "$BODY" >> "$CURL_LOG.bodies"; echo '{"comment":{"id":"c1"}}' ;;
  https://app.example.test/*/move)     printf '%s\n' "$BODY" >> "$CURL_LOG.moves"
                                       printf '{"ticket":{"status":"%s"}}\n' "$(printf '%s' "$BODY" | jq -r .toStatus)" ;;
  *) exit 7 ;;
esac
STUB
cat > "$FB/gh" <<'STUB'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$CURL_LOG"
printf 'POST gh\n' >> "$ALLREQ"
case "$*" in *" -i "*) printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n' ;; esac
exit 0
STUB
chmod +x "$FB/curl" "$FB/gh"

# ══ B — the real bin/board-closeout.sh ════════════════════════════════════
CH="$T/b/h"; mkdir -p "$CH/state" "$CH/flags" "$CH/env" "$CH/catalog" "$CH/logs" "$CH/builds/b1"
scratch_install_closure bin/board-closeout.sh "$CH" >/dev/null || bad "B setup: cannot install the close-out closure"
[ -f "$CH/bin/lib/review-probe.sh" ] && ok || bad "B setup: bin/board-closeout.sh must source bin/lib/review-probe.sh"
cat > "$CH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1:$2" in
  gi:board_prefix) echo "-" ;;
  gi:repo) echo "o/r" ;;
  *:prod) echo "https://app.example.test" ;;
  *:board_prefix) echo "/api/board" ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/bash\necho tok-fixture-board\n' > "$CH/bin/internal-token-for.sh"
printf '#!/bin/bash\necho OK\n' > "$CH/bin/triage-gate.sh"
chmod +x "$CH/bin/fleet-conf.sh" "$CH/bin/internal-token-for.sh" "$CH/bin/triage-gate.sh"
BB="$CH/builds/b1"
printf '## QA screens\n- /clients — the list\n\n## Size\n' > "$BB/plan.md"
closeout() { # closeout <project> <RESULT line> [env ...]
  local p="$1" r="$2"; shift 2
  : > "$T/c.curl"; : > "$T/c.curl.bodies"; : > "$T/c.curl.moves"; echo "$r" > "$BB/RESULT"
  OUT=$(env PATH="$FB:$PATH" HARNESS="$CH" CURL_LOG="$T/c.curl" BUILDER_DIRECT=1 "$@" \
          "$CH/bin/board-closeout.sh" "$p" T1 CX-9 "$BB" 2>"$T/c.err"); RC=$?
}
moved_to() { jq -r .toStatus "$T/c.curl.moves" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

closeout ctl "PR_CREATED https://github.com/o/r/pull/9"
[ "$RC" = 0 ] && [ "$OUT" = "POSTED ctl/CX-9 -> in_progress" ] && ok \
  || bad "B1 PR_CREATED in-app: rc 0 and stdout '-> in_progress' (rc $RC, got '$OUT'; $(tail -2 "$T/c.err"))"
[ "$(grep -c 'tickets/T1/comments' "$T/c.curl")" = 1 ] && [ "$(moved_to)" = in_progress ] && ok \
  || bad "B1 one comment and one move to in_progress (moves: $(moved_to))"
grep -q '"toStatus":"review"' "$T/c.curl.moves" && bad "B1 no move to review at PR open" || ok
grep -q 'It moves to review after it merges' "$T/c.curl.bodies" && grep -q 'after this merges' "$T/c.curl.bodies" \
  && grep -q 'app.example.test/clients' "$T/c.curl.bodies" && ok \
  || bad "B1 the comment says when it moves to review and links production after the merge ($(cat "$T/c.curl.bodies"))"
grep -q 'open for review' "$T/c.curl.bodies" && bad "B1 the comment must not say open for review" || ok
[ -s "$CH/logs/ALERTS.log" ] && bad "B1 board-closeout writes no ALERTS line ($(cat "$CH/logs/ALERTS.log"))" || ok

closeout ctl "PR_CREATED https://github.com/o/r/pull/9" REVIEW_PROBE_REQUIRE=0
[ "$RC" = 0 ] && [ "$(moved_to)" = review ] && [ "$OUT" = "POSTED ctl/CX-9 -> review" ] && grep -q 'open for review' "$T/c.curl.bodies" && ok \
  || bad "B2 REVIEW_PROBE_REQUIRE=0 gives today's review back (rc $RC, out '$OUT', moves $(moved_to))"

closeout ctl "PR_MERGED https://github.com/o/r/pull/9"
[ "$RC" = 0 ] && [ "$(moved_to)" = done ] && grep -q 'on its way to production' "$T/c.curl.bodies" && ok \
  || bad "B3 PR_MERGED is unchanged: done (rc $RC, moves $(moved_to); $(tail -2 "$T/c.err"))"

closeout gi "PR_CREATED https://github.com/o/r/pull/9"
[ "$RC" = 0 ] && [ ! -s "$T/c.curl.moves" ] && grep -q '^gh ' "$T/c.curl" && ok \
  || bad "B4 the issues lane comments and moves nothing (rc $RC, out '$OUT', moves $(moved_to); $(tail -2 "$T/c.err"))"

# B5 (last in B: it removes the lib)
mv "$CH/bin/lib/review-probe.sh" "$T/rp.saved"
closeout ctl "PR_CREATED https://github.com/o/r/pull/9"
[ "$RC" = 0 ] && [ "$(moved_to)" = review ] && grep -q 'review-probe.sh' "$T/c.err" && ok \
  || bad "B5 no lib keeps today's review and says why on stderr (rc $RC, moves $(moved_to); err $(tail -2 "$T/c.err"))"
mv "$T/rp.saved" "$CH/bin/lib/review-probe.sh"

# ══ C — the real bin/merged-ticket-advance.sh ═════════════════════════════
H="$T/c/h"; S="$T/c/board"; CB="$T/c/fakebin"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/flags" "$CB" "$S"
ln -s "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
for s in bin/merged-ticket-advance.sh bin/internal-token-for.sh bin/alert-line.sh bin/prod-url.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
chmod +x "$H/bin/"*.sh
[ -f "$H/bin/lib/review-probe.sh" ] && ok || bad "C setup: bin/merged-ticket-advance.sh must source bin/lib/review-probe.sh"
cat > "$H/fleet.conf" <<'CONF'
x-os    example-org/x-os    https://x.test  /api/board  3  local
CONF
: > "$H/env/global.env"
printf 'X_API_BASE=https://x.test\nX_INTERNAL_API_TOKEN=tok-fixture-never-logged\n' > "$T/x-os.env.src"

# The board, as a stateful file-backed API (from tests/merged-ticket-advance.bh-9865-test.sh),
# plus the probe: a GET with the agent cromford-review-probe answers the
# `-w` line in $S/PROBE (empty: 000) and is logged `PROBE <url>`.
cat > "$CB/curl" <<'SH'
#!/bin/bash
OUT=""; METHOD=GET; DATA=""; IDEM=""; AUTH=0; URL=""; AGENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift ;;
    -X) METHOD="$2"; shift ;;
    -A) AGENT="$2"; shift ;;
    -w) shift ;;
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
echo "$METHOD $URL" >> "$ALLREQ"
if [ "$AGENT" = cromford-review-probe ]; then
  echo "PROBE $URL auth=$AUTH" >> "$STUBDIR/REQS.log"
  printf '%s' "$(cat "$STUBDIR/PROBE" 2>/dev/null || echo '000 ')"
  exit 0
fi
DB="$STUBDIR/db.json"
w() { if [ -n "$OUT" ]; then printf '%s' "$1" > "$OUT"; else printf '%s' "$1"; fi; }
echo "$METHOD $URL" >> "$STUBDIR/REQS.log"
CODE=200
if [ "$METHOD" = POST ]; then
  BODY=$(cat "$DATA" 2>/dev/null)
  jq -cn --arg u "$URL" --arg i "$IDEM" --arg b "$BODY" '{url:$u, idem:$i, body:$b}' >> "$STUBDIR/POSTS.jsonl"
  id=$(printf '%s' "$URL" | sed -E 's@.*/tickets/([^/]+)/.*@\1@')
  case "$URL" in
    */move)
      to=$(printf '%s' "$BODY" | jq -r '.toStatus')
      jq --arg id "$id" --arg to "$to" 'map(if (.id|tostring) == $id then .status = $to else . end)' \
         "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
      w "$(jq -cn --arg id "$id" --arg to "$to" '{id:$id, status:$to}')" ;;
    */turn) w '{"waitingOn":"client"}' ;;
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
    w "$(cat "$STUBDIR/VERSION" 2>/dev/null)" ;;
  */boards) w '{"boards":[{"id":"b1","name":"Main"}]}' ;;
  */boards/*/tickets) w "$(jq -c '{tickets: map(del(.comments))}' "$DB")" ;;
  */tickets/*)
    id="${URL##*/}"
    w "$(jq -c --arg id "$id" '[.[] | select((.id|tostring) == $id)][0] // {}' "$DB")" ;;
  *) CODE=404; w '{}' ;;
esac
printf '%s' "$CODE"
SH
# The fake gh (from the bh-9865 suite): REST reads answer $STUBDIR/gh/<path>.json.
cat > "$CB/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$STUBDIR/GH.log"
echo "GET gh" >> "$ALLREQ"
if [ "${1:-}" = api ] && [ "${2:-}" = -i ]; then
  p="${5:-}"; f="$STUBDIR/gh/$(printf '%s' "$p" | tr '/' '_').json"
  code=404; body='{"message":"Not Found"}'
  if [ -r "$f" ]; then code=200; body=$(cat "$f"); fi
  printf 'HTTP/2.0 %s X\r\nContent-Type: application/json\r\n\r\n%s\n' "$code" "$body"
  case "$code" in 2*) exit 0 ;; *) exit 1 ;; esac
fi
if [ "${1:-}" = api ] && [ "${3:-}" = -q ]; then echo 1; exit 0; fi
exit 1
SH
chmod +x "$CB/curl" "$CB/gh"

PRU="https://github.com/example-org/x-os/pull"
API="https://x.test/api/board"
MSHA="abcdef12""34567890abcdef12""34567890abcdef12"
LIVE="99999999""8888888877777777""6666666655555555"
DONE="$H/state/postmerge-qa-done.txt"
reset() {
  scratch_rm "$S"; mkdir -p "$S/gh"
  echo '[]' > "$S/db.json"; : > "$S/REQS.log"; : > "$S/POSTS.jsonl"; : > "$S/GH.log"
  scratch_rm "$H/logs"; scratch_rm "$H/builds"; scratch_rm "$H/state"; scratch_rm "$H/flags"; scratch_rm "$H/catalog"
  mkdir -p "$H/logs" "$H/builds" "$H/state" "$H/flags"
  cp "$T/x-os.env.src" "$H/env/x-os.env"
}
isoago() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ; }
stago()  { date -u -d "-$1 min" '+%Y-%m-%d %H:%M:%SZ'; }
tsago()  { date -u -d "-$1 min" +%Y%m%d%H%M; }
tk() { # tk <id> <key> <status> <reporterUserId>
  jq --argjson id "$1" --arg k "$2" --arg s "$3" --arg r "$4" \
     '. + [ {id:$id, key:$k, title:("Ticket " + $k), status:$s, waitingOn:"team", comments:[],
             reporter:{userId:$r, name:"R"}} ]' "$S/db.json" > "$S/db.tmp" && mv "$S/db.tmp" "$S/db.json"
}
comment() { # comment <id> <userId> <minutes-ago> <body> [author name]
  jq --argjson id "$1" --arg u "$2" --arg t "$(isoago "$3")" --arg b "$4" --arg n "${5:-}" \
     'map(if .id == $id then .comments += [{author:({userId:$u} + (if $n == "" then {} else {name:$n} end)),
                                             createdAt:$t, body:$b}] else . end)' \
     "$S/db.json" > "$S/db.tmp" && mv "$S/db.tmp" "$S/db.json"
}
ghf() { printf '%s' "$2" > "$S/gh/$(printf '%s' "$1" | tr '/' '_').json"; }
PLAN_QA="# CX-501
## QA screens
- /clients/[id] — one client
- /clients — the list

## Size
SIZE: S"
# local_case <id> <key> <reporter> <verdict> — an in_progress ticket whose newest
# build opened PR <id> and has an audit line with <verdict>.
local_case() {
  local bn="x-os-$2-$(tsago 30)"
  tk "$1" "$2" in_progress "$3"
  mkdir -p "$H/builds/$bn"
  printf 'PR_CREATED %s/%s | QUEUED: tier 2\n' "$PRU" "$1" > "$H/builds/$bn/RESULT"
  printf '%s\n' "$PLAN_QA" > "$H/builds/$bn/plan.md"
  printf '%s %s %s %s\n' "$(stago 10)" "$bn" abc12345 "$4" >> "$DONE"
}
probe_answer() { printf '%s' "$1" > "$S/PROBE"; }
run() { env PATH="$CB:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBDIR="$S" "$@" \
          "$H/bin/merged-ticket-advance.sh" x-os 2>"$T/err.txt"; }
posts() { awk 'END{print NR}' "$S/POSTS.jsonl"; }
cposts() { grep -c '/comments"' "$S/POSTS.jsonl"; }
mposts() { grep -c '/move"' "$S/POSTS.jsonl"; }
probes() { grep '^PROBE ' "$S/REQS.log" | tr '\n' '|'; }
status_of() { jq -r --argjson id "$1" '.[] | select(.id == $id) | .status' "$S/db.json"; }
cbody() { jq -r 'select(.url | endswith("/comments")) | .body | fromjson | .body' "$S/POSTS.jsonl" 2>/dev/null; }
advlog() { grep 'MERGED_ADVANCE moved=' "$H/logs/x-os.log" 2>/dev/null | tail -1; }
alerts() { grep -c 'CX-501 held' "$H/logs/ALERTS.log" 2>/dev/null || true; }

# C1: served -> GET <prod>/clients (the first static QA screen), one comment
# naming that URL, one move to review.
reset; local_case 501 CX-501 u_7 NOT_COVERED_NO_QA_ENV; probe_answer '200 https://x.test/clients'
OUT=$(run)
[ "$(probes)" = "PROBE https://x.test/clients auth=0|" ] && ok || bad "C1 one unauthenticated probe of https://x.test/clients (got '$(probes)')"
[ "$OUT" = CX-501 ] && [ "$(status_of 501)" = review ] && [ "$(cposts)/$(mposts)" = 1/1 ] && ok \
  || bad "C1 one comment, one move to review (out '$OUT', status $(status_of 501), $(cposts)/$(mposts); $(advlog))"
cbody | grep -q 'We opened its main screen in production (https://x.test/clients) and it answered' && ok \
  || bad "C1 the comment names the probed URL ($(cbody))"
grep -qi live <<<"$(cbody)" && bad "C1 the comment never says live ($(cbody))" || ok
cbody | grep -q '^<p>This is merged and production is serving it (commit abc12345' && ok || bad "C1 the lead sentence and witness are unchanged ($(cbody))"
case "$(advlog)" in *"moved=1 "*"no-live-probe=0"*) ok ;; *) bad "C1 the summary line has moved=1 and no-live-probe=0 ($(advlog))" ;; esac

# C2: the app asks for sign-in on a hosted sign-in page -> review, the comment says so.
reset; local_case 501 CX-501 u_7 NOT_COVERED_NO_QA_ENV; probe_answer '200 https://accounts.x.test/sign-in?redirect_url=x'
OUT=$(run)
[ "$(status_of 501)" = review ] && cbody | grep -q 'It asks for sign-in, so nobody has checked it signed in yet' && ok \
  || bad "C2 sign-in passes and the comment says so (status $(status_of 501); $(cbody))"

# C3: 500 -> hold: no POST, no marker, no tries, a hold line, no-live-probe=1.
reset; local_case 501 CX-501 u_7 NOT_COVERED_NO_QA_ENV; probe_answer '500 https://x.test/clients'
OUT=$(run)
[ "$(posts)" = 0 ] && [ -z "$OUT" ] && [ "$(status_of 501)" = in_progress ] && ok \
  || bad "C3 a failed probe posts nothing and moves nothing (posts $(posts), out '$OUT', status $(status_of 501))"
ls "$H/state"/merged-advance-x-os-501-*.mark "$H/state"/merged-advance-x-os-501-*.tries >/dev/null 2>&1 \
  && bad "C3 no .mark and no .tries for a hold ($(ls "$H/state"))" || ok
grep -q 'MERGED_ADVANCE_PROBE_HOLD CX-501 https://x.test/clients error HTTP 500' "$H/logs/x-os.log" && ok \
  || bad "C3 the hold line names the key, URL, outcome and code ($(cat "$H/logs/x-os.log"))"
case "$(advlog)" in *"moved=0 comment-only=0 "*"no-live-probe=1"*) ok ;; *) bad "C3 the summary line has moved=0 and no-live-probe=1 ($(advlog))" ;; esac

# C4: the same hold over two runs -> exactly one ALERTS line for the ticket.
reset; local_case 501 CX-501 u_7 NOT_COVERED_NO_QA_ENV; probe_answer '200 https://x.test/'
run >/dev/null; run >/dev/null
[ "$(alerts)" = 1 ] && ok || bad "C4 one alert over two held runs (got $(alerts): $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
[ "$(grep -c '^PROBE ' "$S/REQS.log")" = 2 ] && [ "$(posts)" = 0 ] && ok || bad "C4 each run probes again and posts nothing ($(probes); posts $(posts))"
grep -q 'elsewhere HTTP 200' "$H/logs/ALERTS.log" && ok || bad "C4 the alert names the outcome ($(cat "$H/logs/ALERTS.log"))"

# C5: a signed-in PASS drive is the probe -> no extra GET, review.
reset; local_case 501 CX-501 u_7 PASS; probe_answer '500 https://x.test/clients'
OUT=$(run)
[ -z "$(probes)" ] && [ "$(status_of 501)" = review ] && ok || bad "C5 PASS: no probe, review (probes '$(probes)', status $(status_of 501))"

# C6: system-filed -> done, no probe.
reset; local_case 501 CX-501 system NOT_COVERED_NO_QA_ENV; probe_answer '500 https://x.test/clients'
OUT=$(run)
[ -z "$(probes)" ] && [ "$(status_of 501)" = done ] && ok || bad "C6 system-filed: no probe, done (probes '$(probes)', status $(status_of 501))"

# C7: a staging project whose production does not serve the merge -> the
# staging comment, no move, no probe.
reset; mkdir -p "$H/catalog"
printf 'x-os\tstaging\thttps://stg.x.test\thttps://stg.x.test/api/internal/version\n' > "$H/catalog/release-model.tsv"
local_case 501 CX-501 u_7 NOT_COVERED_NO_QA_ENV; probe_answer '500 https://x.test/clients'
ghf "repos/example-org/x-os/pulls/501" "$(jq -cn --arg m "$(isoago 40)" --arg s "$MSHA" '{number:501, state:"closed", merged_at:$m, merge_commit_sha:$s}')"
printf '{"sha":"%s"}' "$LIVE" > "$S/VERSION"
ghf "repos/example-org/x-os/compare/$MSHA...$LIVE" '{"status":"behind"}'
OUT=$(run)
[ -z "$(probes)" ] && [ "$(cposts)/$(mposts)" = 1/0 ] && [ "$(status_of 501)" = in_progress ] && ok \
  || bad "C7 staging hold: no probe, one comment, no move (probes '$(probes)', $(cposts)/$(mposts), status $(status_of 501); $(advlog))"

# C8: our comment is already on the thread (a move retry) -> no probe, review.
reset; local_case 501 CX-501 u_7 NOT_COVERED_NO_QA_ENV; probe_answer '500 https://x.test/clients'
comment 501 u-h 5 '<p>This is merged and production is serving it (commit abc12345, x).</p>' 'System Harness'
OUT=$(run)
[ -z "$(probes)" ] && [ "$(status_of 501)" = review ] && [ "$(cposts)" = 0 ] && ok \
  || bad "C8 move retry: no probe, no comment, review (probes '$(probes)', comments $(cposts), status $(status_of 501))"

# C9: REVIEW_PROBE_REQUIRE=0 -> today's behavior: no probe, review.
reset; local_case 501 CX-501 u_7 NOT_COVERED_NO_QA_ENV; probe_answer '500 https://x.test/clients'
OUT=$(run REVIEW_PROBE_REQUIRE=0)
[ -z "$(probes)" ] && [ "$(status_of 501)" = review ] && ok || bad "C9 knob 0: no probe, review (probes '$(probes)', status $(status_of 501))"
grep -q "We opened" <<<"$(cbody)" && bad "C9 knob 0: no probe paragraph" || ok

# C10: the peer path (no build dir here) probes / and moves to review.
reset
tk 501 CX-501 in_progress u_7
comment 501 cyg 60 "Ready for review in <a href=\"$PRU/77\">$PRU/77</a>" partner
ghf "repos/example-org/x-os/pulls/77" "$(jq -cn --arg m "$(isoago 40)" --arg s "$MSHA" '{number:77, state:"closed", merged_at:$m, merge_commit_sha:$s}')"
printf '{"sha":"%s"}' "$LIVE" > "$S/VERSION"
ghf "repos/example-org/x-os/compare/$MSHA...$LIVE" '{"status":"ahead"}'
probe_answer '200 https://x.test/'
OUT=$(run)
[ "$(probes)" = "PROBE https://x.test/ auth=0|" ] && [ "$(status_of 501)" = review ] && ok \
  || bad "C10 peer: probe of https://x.test/, review (probes '$(probes)', status $(status_of 501); $(advlog))"

# C11: --dry-run on a hold -> DRYRUN PROBE line, no POST lines, nothing written.
reset; local_case 501 CX-501 u_7 NOT_COVERED_NO_QA_ENV; probe_answer '404 https://x.test/clients'
OUT=$(env PATH="$CB:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBDIR="$S" "$H/bin/merged-ticket-advance.sh" x-os --dry-run 2>"$T/err.txt")
grep -q '^DRYRUN PROBE https://x.test/clients error 404$' "$T/err.txt" && ok || bad "C11 dry run prints the probe ($(cat "$T/err.txt"))"
grep -q 'DRYRUN POST' "$T/err.txt" && bad "C11 a held dry run prints no POST line" || ok
[ "$(posts)" = 0 ] && [ ! -s "$H/logs/ALERTS.log" ] && ok || bad "C11 a dry run posts nothing and alerts nothing"

# ══ Z — 0 network ═════════════════════════════════════════════════════════
[ -s "$ALLREQ" ] && ! grep -vE '^(GET|POST) (https://(x\.test|app\.t|app\.example\.test)(/|$)|gh$)' "$ALLREQ" >/dev/null && ok \
  || bad "Z every request went to a fake ($(grep -vE '^(GET|POST) (https://(x\.test|app\.t|app\.example\.test)(/|$)|gh$)' "$ALLREQ" | head -3))"

echo "review-probe bh-9987: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
