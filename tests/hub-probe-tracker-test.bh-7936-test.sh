#!/bin/bash
# tests/hub-probe-tracker-test.bh-7936-test.sh — BH-7936: the hub probe
# `tracker-test` (bin/lib/hub-probes/tracker-test.sh), the Jira context from
# sheet fields (trk_jira_context_fields / trk_jira_cloud_id in
# bin/lib/tracker/jira.sh) and the hub-probe lane's no-comment rule for it
# (bin/hub-probe.sh).
#
#   V1-V12 hp_validate tracker-test: the kind and nonce table
#   P1-P3  linear / jira / board pass: `ok list=<n> dry-write=ok`, 0 vendor writes
#   P4     the secret never reaches the output, even when the vendor echoes it
#   P5     a failed list is FAIL with the adapter's error   P6 take 404 is `credential expired`
#   P7     an empty list is `dry-write=skipped`              P8 a kind that differs from the taken row
#   P9     the take route down is FAIL, not expired
#   J1-J4  trk_jira_context_fields: base from tenant_info, bad status_map, 429, bad site
#   S1     the REAL lane: 3 tracker-test rows on a GitHub-Issues project post 0
#          comments, raise 0 alerts and log silent=3
#
# No network. A front `curl` stub on PATH answers the jobs worker's take route,
# api.linear.app, the board base and <site>/_edge/tenant_info, and hands every
# other URL to the Jira gateway stub (tests/lib/tracker-jira-stub.sh). Every
# vendor request is logged to $T/stub/vendor.log, never a header.
#   HARNESS_TEST_SANDBOX=1 bash tests/hub-probe-tracker-test.bh-7936-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/tracker-jira-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "hub-probe-tracker-test: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

HPD="$DIR/bin/lib/hub-probes"
[ -f "$HPD/tracker-test.sh" ] || bad "bin/lib/hub-probes/tracker-test.sh is missing"

jira_stub_setup "$T/j" || { echo "jira stub setup failed"; exit 1; }
STUB="$T/stub"
mkdir -p "$STUB/take"
export TT_STUB="$STUB" TT_JSTUB="$T/j/jstub/curl" PATH="$STUB:$PATH"

LIN_KEY=lin-api-fixture-SENTINEL-7936
BOARD_TOK=board-fixture-SENTINEL-7936
export TT_LIN_KEY="$LIN_KEY" TT_BOARD_TOK="$BOARD_TOK" TT_LFIX="$DIR/tests/fixtures/tracker-linear"

cat > "$STUB/curl" <<'SH'
#!/bin/bash
S="$TT_STUB"; m=GET; url=""; data=""; out=""; fmt=""; auth=""; fail=0
args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary|-d) data="$2"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -f) fail=1 ;;
    -m|--max-time|--connect-timeout) shift ;;
    -H) case "$2" in [Aa]uthorization:*) auth="${2#*: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
reply() { # reply <code> <body>
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  [ -n "$fmt" ] && printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  if [ "$fail" = 1 ] && [ "$1" -ge 400 ]; then echo "curl: (22) The requested URL returned error: $1" >&2; exit 22; fi
  exit 0
}
body() { case "$data" in @*) cat "${data#@}" ;; *) printf '%s' "$data" ;; esac; }
arm() { cat "$S/arm-$1" 2>/dev/null; }
case "$url" in
  https://jobs.example/api/onboarding/tracker-secret/take)
    echo "take" >> "$S/jobs.log"
    [ "$(arm take)" = down ] && reply 500 '{"error":"boom"}'
    n=$(body | jq -r '.nonce // empty')
    f="$S/take/$n.json"
    if [ -n "$n" ] && [ -r "$f" ]; then j=$(cat "$f"); rm -f "$f"; reply 200 "$j"; fi
    reply 404 '{"error":"no onboarding credential for that nonce (expired or already taken)"}' ;;
  https://*.atlassian.net/_edge/tenant_info)
    echo "tenant ${url#https://}" >> "$S/vendor.log"
    [ "$(arm tenant)" = 429 ] && reply 429 '{"message":"slow down"}'
    reply 200 '{"cloudId":"33333333-3333-3333-3333-333333333333"}' ;;
  https://api.linear.app/graphql)
    op=$(body | jq -r '.query // ""' | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
    echo "linear $op" >> "$S/vendor.log"
    case "$op" in TrkComment|TrkUpdate|TrkAddLabel|TrkRemoveLabel|TrkAttach) echo "WRITE linear $op" >> "$S/vendor.log" ;; esac
    if [ "$auth" != "$TT_LIN_KEY" ] || [ "$(arm linear)" = echo401 ]; then
      reply 401 "$(jq -nc --arg k "$auth" '{errors:[{message:("Authentication required, key " + $k + " is not valid")}]}')"
    fi
    case "$op" in
      TrkIssues)
        [ "$(arm linear)" = empty ] && reply 200 '{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
        after=$(body | jq -r '.variables.after // empty')
        [ -z "$after" ] && reply 200 "$(cat "$TT_LFIX/issues-page1.json")"
        reply 200 "$(cat "$TT_LFIX/issues-page2.json")" ;;
      TrkIssueMeta|TrkIssue)
        id=$(body | jq -r '.variables.id')
        [ -r "$TT_LFIX/issue-$id.json" ] && reply 200 "$(cat "$TT_LFIX/issue-$id.json")"
        reply 200 "$(cat "$TT_LFIX/not-found.json")" ;;
    esac
    reply 400 '{"errors":[{"message":"unknown operation"}]}' ;;
  https://board.example.com/api/board/*)
    p="${url#https://board.example.com/api/board}"
    echo "board $m $p" >> "$S/vendor.log"
    [ "$m" = POST ] && echo "WRITE board $p" >> "$S/vendor.log"
    [ "$auth" = "Bearer $TT_BOARD_TOK" ] || reply 401 '{"error":"bad token"}'
    case "$p" in
      /boards) reply 200 '{"boards":[{"id":"b1"}]}' ;;
      /boards/b1/tickets)
        [ "$(arm board)" = empty ] && reply 200 '{"tickets":[]}'
        reply 200 '{"tickets":[{"id":"t1","title":"One","status":"todo"},{"id":"t2","title":"Two","status":"todo"},{"id":"t3","title":"Three","status":"review"}]}' ;;
    esac
    reply 404 '{"error":"no route"}' ;;
  https://api.atlassian.com/*|https://jobs.example/*)
    case "$url" in https://api.atlassian.com/*) echo "jira $m ${url#https://api.atlassian.com}" >> "$S/vendor.log" ;; esac
    exec "$TT_JSTUB" "${args[@]}" ;;
esac
echo "OFFBASE $m $url" >> "$S/vendor.log"
[ -n "$fmt" ] && printf '000'
exit 7
SH
chmod +x "$STUB/curl"

echo 0 > "$T/nonce-seq"
# take_row <kind> <fields json> — a KV row the take route answers once; prints
# its nonce. The counter is a file: take_row runs inside $( ).
take_row() {
  local q n; q=$(( $(cat "$T/nonce-seq") + 1 )); echo "$q" > "$T/nonce-seq"
  n=$(printf '%032x' "$q")
  jq -nc --arg k "$1" --argjson f "$2" '{kind:$k, project:"newproj", fields:$f}' > "$STUB/take/$n.json"
  printf '%s' "$n"
}
LIN_FIELDS=$(jq -nc --arg k "$LIN_KEY" '{api_key:$k, team:"CRO", label:"ai-build"}')
JIRA_FIELDS=$(jq -nc --arg e "$JIRA_EMAIL_FX" --arg t "$JIRA_TOKEN_FX" \
  '{site:"sandbox-example.atlassian.net", email:$e, api_token:$t, project_key:"CROM", status_map:"todo=To Do;in_progress=In Progress;review=In Review;closed=Done"}')
BOARD_FIELDS=$(jq -nc --arg t "$BOARD_TOK" '{api_base:"https://board.example.com/api/board", token:$t}')

reset_stub() { rm -f "$STUB"/vendor.log "$STUB"/arm-* "$STUB"/jobs.log "$JIRA_STUB_STATE/writes" "$JIRA_STUB_STATE/requests"; }
# probe <kind> <nonce> — hp_run in a child shell, as the lane runs it. Out in $T/out, rc in $T/rc.
probe() {
  bash -c '. "$1/common.sh" || exit 99; hp_run tracker-test "$2" "$3"' _ "$HPD" "$1" "$2" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
vrc() { cat "$T/rc"; }
writes() { local n; n=$( { grep -c '^WRITE' "$STUB/vendor.log" 2>/dev/null; cat "$JIRA_STUB_STATE/writes" 2>/dev/null; } | grep -vc '^0$'); printf '%s' "$n"; }

# ── V1-V12: hp_validate ─────────────────────────────────────────────────────
val() { bash -c '. "$1/common.sh" || exit 99; shift; hp_validate "$@"' _ "$HPD" "$@"; echo $?; }
N32=$(printf '%s' 0123456789abcdef 0123456789abcdef)  # 32 hex, built at run time (share-mirror leakcheck)
check "V1 linear + 32 hex validates" '[ "$(val tracker-test linear $N32)" = 0 ]'
check "V2 jira validates" '[ "$(val tracker-test jira $N32)" = 0 ]'
check "V3 board validates" '[ "$(val tracker-test board $N32)" = 0 ]'
check "V4 Linear (case) refused" '[ "$(val tracker-test Linear $N32)" = 2 ]'
check "V5 github-issues refused" '[ "$(val tracker-test github-issues $N32)" = 2 ]'
check "V6 trailing space refused" '[ "$(val tracker-test "jira " $N32)" = 2 ]'
check "V7 31 hex refused" '[ "$(val tracker-test jira ${N32:1})" = 2 ]'
check "V8 33 hex refused" '[ "$(val tracker-test jira ${N32}0)" = 2 ]'
check "V9 upper-case hex refused" '[ "$(val tracker-test jira "$(printf '%s' 0123456789ABCDEF 0123456789abcdef)")" = 2 ]'
check "V10 ../x refused" '[ "$(val tracker-test jira ../x)" = 2 ]'
check "V11 an extra arg refused" '[ "$(val tracker-test jira $N32 x)" = 2 ]'
check "V12 no args refused" '[ "$(val tracker-test)" = 2 ]'
check "V13 HP_PROBES (the comment allowlist) does not carry tracker-test" \
  '! bash -c ". \"\$1/common.sh\"; case \" \$HP_PROBES \" in *\" tracker-test \"*) exit 0 ;; esac; exit 1" _ "$HPD"'

# ── P1: linear ──────────────────────────────────────────────────────────────
reset_stub; probe linear "$(take_row linear "$LIN_FIELDS")"
check "P1 linear rc 0 ($(cat "$T/out"))" '[ "$(vrc)" = 0 ]'
check "P1 linear prints ok list=2 dry-write=ok" 'grep -qx "ok list=2 dry-write=ok" "$T/out"'
check "P1 linear read the list and the first issue" 'grep -q "^linear TrkIssues" "$STUB/vendor.log" && grep -q "^linear TrkIssueMeta" "$STUB/vendor.log"'
check "P1 linear sent no write" '[ "$(writes)" = 0 ]'
check "P1 the KV row was taken (one take)" '[ "$(grep -c take "$STUB/jobs.log")" = 1 ]'

# ── P2: jira ────────────────────────────────────────────────────────────────
reset_stub; probe jira "$(take_row jira "$JIRA_FIELDS")"
check "P2 jira rc 0 ($(cat "$T/out"))" '[ "$(vrc)" = 0 ]'
check "P2 jira prints ok list=2 dry-write=ok" 'grep -qx "ok list=2 dry-write=ok" "$T/out"'
check "P2 jira asked tenant_info for the site" 'grep -qx "tenant sandbox-example.atlassian.net/_edge/tenant_info" "$STUB/vendor.log"'
check "P2 jira searched and read CROM-1 through the gateway" 'grep -q "^jira POST /ex/jira/33333333-3333-3333-3333-333333333333/rest/api/3/search/jql" "$STUB/vendor.log" && grep -q "^jira GET .*/issue/CROM-1" "$STUB/vendor.log"'
check "P2 jira sent no write" '[ "$(writes)" = 0 ] && [ ! -s "$JIRA_STUB_STATE/writes" ]'
check "P2 jira auth was the taken credential" '[ ! -s "$JIRA_STUB_STATE/authbad" ]'

# ── P3: board ───────────────────────────────────────────────────────────────
reset_stub; probe board "$(take_row board "$BOARD_FIELDS")"
check "P3 board rc 0 ($(cat "$T/out"))" '[ "$(vrc)" = 0 ]'
check "P3 board prints ok list=3 dry-write=ok" 'grep -qx "ok list=3 dry-write=ok" "$T/out"'
check "P3 board sent no write" '[ "$(writes)" = 0 ]'

# ── P4/P5: a vendor that echoes the key in its error ────────────────────────
reset_stub; echo echo401 > "$STUB/arm-linear"; probe linear "$(take_row linear "$LIN_FIELDS")"
check "P5 a failed list is rc 1" '[ "$(vrc)" = 1 ]'
check "P5 the first line says the list failed" 'head -1 "$T/out" | grep -q "^FAIL tracker list failed"'
check "P5 the adapter error is shown" 'grep -q "linear answered HTTP 401: Authentication required" "$T/out"'
check "P4 the key is not in the output" '! grep -q "$LIN_KEY" "$T/out"'
check "P4 the key is shown redacted" 'grep -q "\[redacted\]" "$T/out"'
for f in "$T/out" "$STUB/vendor.log" "$STUB/jobs.log"; do
  check "P4 no SENTINEL in $(basename "$f")" '! grep -q "SENTINEL-7936" "$f"'
done
reset_stub; echo x > "$STUB/arm-none"; JF=$(jq -c '.api_token = "tok-fixture-wrong-SENTINEL-7936"' <<<"$JIRA_FIELDS")
probe jira "$(take_row jira "$JF")"
check "P5 jira bad token is FAIL rc 1" '[ "$(vrc)" = 1 ] && head -1 "$T/out" | grep -q "^FAIL tracker list failed"'
check "P5 jira says check the token" 'grep -q "answered 401" "$T/out"'
check "P4 jira token not in the output" '! grep -q "SENTINEL-7936" "$T/out"'

# ── P6: take 404 ────────────────────────────────────────────────────────────
reset_stub; probe linear "$(printf '%032x' 999)"
check "P6 rc 1" '[ "$(vrc)" = 1 ]'
check "P6 credential expired" 'grep -qx "FAIL credential expired, test again" "$T/out"'
check "P6 no vendor call" '[ ! -s "$STUB/vendor.log" ]'

# ── P7: empty list ──────────────────────────────────────────────────────────
reset_stub; echo empty > "$STUB/arm-linear"; probe linear "$(take_row linear "$LIN_FIELDS")"
check "P7 linear empty list rc 0" '[ "$(vrc)" = 0 ] && grep -qx "ok list=0 dry-write=skipped" "$T/out"'
check "P7 says why the write was skipped" 'grep -q "no open ticket with the build label; dry write skipped" "$T/out"'
reset_stub; echo empty > "$STUB/arm-board"; probe board "$(take_row board "$BOARD_FIELDS")"
check "P7 board empty list rc 0" '[ "$(vrc)" = 0 ] && grep -qx "ok list=0 dry-write=skipped" "$T/out"'

# ── P8: kind mismatch; P9: take route down ──────────────────────────────────
reset_stub; probe jira "$(take_row linear "$LIN_FIELDS")"
check "P8 a jira probe over a linear row is FAIL" '[ "$(vrc)" = 1 ] && grep -q "^FAIL credential is for linear, not jira" "$T/out" && [ ! -s "$STUB/vendor.log" ]'
reset_stub; echo down > "$STUB/arm-take"; probe board "$(take_row board "$BOARD_FIELDS")"
check "P9 take down is FAIL, not expired" '[ "$(vrc)" = 1 ] && grep -q "^FAIL credential store unreachable" "$T/out"'

# ── J1-J4: trk_jira_context_fields ──────────────────────────────────────────
jctx() { # jctx <site> <status_map> — prints rc|TRK_JIRA_BASE|write|site
  bash -c '. "$1/bin/lib/tracker.sh"; tracker_load jira || exit 98
    trk_jira_context_fields "$2" harness@example.com tok-fixture-x CROM "$3"; r=$?
    printf "%s|%s|%s|%s" "$r" "$TRK_JIRA_BASE" "$TRK_JIRA_WRITE_PROJECTS" "$TRK_JIRA_SITE"' _ "$DIR" "$1" "$2" 2>/dev/null
}
SM='todo=To Do;in_progress=In Progress;review=In Review;closed=Done'
reset_stub
check "J1 base from tenant_info, write list = the key, site as https" \
  '[ "$(jctx sandbox-example.atlassian.net "$SM")" = "0|https://api.atlassian.com/ex/jira/33333333-3333-3333-3333-333333333333|CROM|https://sandbox-example.atlassian.net" ]'
check "J2 a bad status_map is rc 1 with a blank context" '[ "$(jctx sandbox-example.atlassian.net "todo=To Do;oops")" = "1|||" ]'
echo 429 > "$STUB/arm-tenant"
check "J3 tenant_info 429 is rc 75" '[ "$(jctx sandbox-example.atlassian.net "$SM" | cut -d"|" -f1)" = 75 ]'
reset_stub
check "J4 a site that is not <x>.atlassian.net is rc 1 and sends nothing" \
  '[ "$(jctx evil.example "$SM" | cut -d"|" -f1)" = 1 ] && [ ! -s "$STUB/vendor.log" ]'

# ── S1: the REAL lane over 3 tracker-test rows ──────────────────────────────
H="$T/lane"
mkdir -p "$H"
cp -rs "$DIR/bin" "$H/bin"
rm -f "$H/bin/alert-line.sh"
printf '#!/bin/bash\necho "alert-line $*" >> "%s/alerts"\n' "$T" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/alert-line.sh"
cat > "$H/fleet.conf" <<'CONF'
bp   o/r        -                 -           5  local
CONF
cat > "$T/fx.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_switch() { return 1; }
# The worker: claim answers $FXT/claim, the take route answers the KV rows in
# $TT_STUB/take once, every other call is {"ok":true}. Bodies are kept.
_jobs_req() {
  echo "_jobs_req $1 $2" >> "$FXT/calls.log"
  case "$2" in
    /api/hub-probe/claim) cat "$FXT/claim"; return 0 ;;
    /api/hub-probe/count-today*) echo '{"count":0}'; return 0 ;;
    /api/hub-probe/result) printf '%s\n' "$3" >> "$FXT/results"; echo '{"ok":true}'; return 0 ;;
    /api/onboarding/tracker-secret/take)
      local n f; n=$(jq -r .nonce <<<"$3"); f="$TT_STUB/take/$n.json"
      [ -r "$f" ] || return 2
      cat "$f"; rm -f "$f"; return 0 ;;
  esac
  echo '{"ok":true}'
}
gh_rest() { echo "gh_rest $*" >> "$FXT/calls.log"; return 0; }
gh_rest_issue_comments() { echo "gh_rest_issue_comments $*" >> "$FXT/calls.log"; echo '[]'; }
SH
reset_stub
NB=$(take_row board "$BOARD_FIELDS"); NL=$(take_row linear "$LIN_FIELDS"); NX=$(printf '%032x' 4242)
jq -nc --arg b "$NB" --arg l "$NL" --arg x "$NX" '{rows:[
  {id:11, project:"bp", ticket_key:("onb-"+$b), probe:"tracker-test", args:["board",$b]},
  {id:12, project:"bp", ticket_key:("onb-"+$l), probe:"tracker-test", args:["linear",$l]},
  {id:13, project:"bp", ticket_key:("onb-"+$x), probe:"tracker-test", args:["jira",$x]}]}' > "$T/claim"
( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" FXT="$T" HUB_PROBE_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1
  unset HUB_PROBE_TICK_CAP HUB_PROBE_DAILY_CAP; bash "$H/bin/hub-probe.sh" ); echo $? > "$T/lane.rc"
SUM=$(tail -1 "$H/logs/hub-probe.log" 2>/dev/null)
check "S1 lane rc 0" '[ "$(cat "$T/lane.rc")" = 0 ]'
check "S1 summary: ran 3, pass 2, fail 1, silent=3 ($SUM)" 'grep -q "claimed=3 ran=3 pass=2 fail=1 " <<<"$SUM" && grep -q " silent=3" <<<"$SUM"'
check "S1 no GitHub call at all" '! grep -q "gh_rest" "$T/calls.log"'
check "S1 no alert line" '[ ! -s "$T/alerts" ]'
check "S1 no bad-key" '! grep -q "bad-key" <<<"$SUM"'
check "S1 nothing left in the spool" '[ -z "$(ls -A "$H/state/hub-probe/owed" 2>/dev/null)" ]'
check "S1 three results stored" '[ "$(wc -l < "$T/results")" = 3 ]'
check "S1 board pass stored with its output" 'jq -e "select(.id == 11) | .result == \"pass\" and (.output | test(\"ok list=3 dry-write=ok\"))" "$T/results" >/dev/null'
check "S1 the expired row stored as fail with the reason" 'jq -e "select(.id == 13) | .result == \"fail\" and (.output | test(\"credential expired\"))" "$T/results" >/dev/null'
check "S1 no secret in any stored output" '! grep -q "SENTINEL-7936" "$T/results"'

echo "hub-probe-tracker-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
