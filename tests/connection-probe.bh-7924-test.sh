#!/bin/bash
# tests/connection-probe.bh-7924-test.sh — BH-7924: bin/connection-probe.sh,
# the per-project tracker connection probe, and its two adapter reads
# (trk_linear_viewer in bin/lib/tracker/linear.sh, trk_jira_myself in
# bin/lib/tracker/jira.sh).
#
#   P1  linear: one `viewer` POST to the GraphQL URL; the status POST body has
#       adapter linear, ok true, the pinned checkedAt, LINEAR_API_KEY present;
#       the lane json defaults are 60 and 300 and the script reads them as
#       ${CONNECTION_PROBE_TIMEOUT_S:-60} / ${CONNECTION_PROBE_ERROR_MAX:-300}
#   P2  jira: one GET of /rest/api/3/myself; JIRA_BASE, JIRA_EMAIL,
#       JIRA_API_TOKEN present; ok true
#   P3  board and P4 github-issues: ok true after one open-ticket list
#   P5  LINEAR_API_KEY missing: ok false, the error and credentialVars name
#       LINEAR_API_KEY, and no token value is in any output, log or POST body
#   P6  a 401 that echoes the key: ok false, the adapter's 401 text, the key
#       and a stray token-shaped word scrubbed, cut to CONNECTION_PROBE_ERROR_MAX;
#       a key with no token prefix (lin2) is scrubbed by its value;
#       a rate limit (429) is ok false "rate limited"; no adapter is ok false
#   P7  the worker POST fails: rc 1, one log line, no ALERTS line; a probe
#       that runs past CONNECTION_PROBE_TIMEOUT_S is written as "timed out";
#       usage is rc 2 and writes nothing; --dry-run prints and writes nothing
#   P8  --box probes only the projects bin/box-for.sh maps to this box, and
#       one failed probe does not stop the next
#   P9  settings rows in the PUT shape give tracker_key_prefix = the key
#   P10 0 calls to a real host: the curl and gh stubs refuse any host the
#       suite does not play, and the run made no such call
#
# No network: `curl` and `gh` stubs play the jobs worker (https://jobs.example),
# Linear, the Jira gateway and one board from inline fixtures, and record
# every request. The clock is pinned through CONNECTION_PROBE_NOW.
#   HARNESS_TEST_SANDBOX=1 bash tests/connection-probe.bh-7924-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

PROBE="$DIR/bin/connection-probe.sh"
LKEY=lin_api_fixture_P5SENTINEL7924
JTOK=ATATT-fixture-jira-7924
BTOK=tok-fixture-brd-7924
STRAY=ghp_fixtureStray7924
CLOUD=00000000-0000-0000-0000-000000007924
NOW=1798372800   # 2026-12-27T12:00:00Z
NOW_ISO=2026-12-27T12:00:00Z

H="$T/h"; S="$T/s"
mkdir -p "$H/bin" "$H/env" "$H/logs" "$H/state" "$H/flags" "$H/catalog" "$S/set" "$T/stub"
# The closure of every script the probe runs or sources. The adapters, the
# jobs-client modules and the executed helpers are not on a static `.` line,
# so each is installed by name.
for f in bin/connection-probe.sh bin/lib/tracker.sh bin/lib/tracker/linear.sh bin/lib/tracker/jira.sh \
         bin/lib/tracker/board.sh bin/lib/tracker/github-issues.sh bin/jobs-client.sh bin/fleet-conf.sh \
         bin/box-for.sh bin/box-name.sh bin/internal-token-for.sh bin/lib/board-creds.sh bin/lib/lane-gate.sh; do
  [ -e "$DIR/$f" ] || continue
  ( cd "$DIR" && scratch_install_closure "$f" "$H" ) >/dev/null || { echo "setup: could not install $f"; exit 1; }
done
for m in $(sed -n 's/^JC_MODULES="\(.*\)"$/\1/p' "$DIR/bin/jobs-client.sh"); do
  ( cd "$DIR" && scratch_install_closure "bin/lib/jobs/$m.sh" "$H" ) >/dev/null || { echo "setup: could not install jobs module $m"; exit 1; }
done
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> <box>
lin1  o/lin1  -  -       1  box-a
jir1  o/jir1  -  -       2  box-a
brd1  o/brd1  -  /api/b  3  box-a
ghi1  o/ghi1  -  -       4  box-a
nolk  o/nolk  -  -       5  box-a
far1  o/far1  -  -       6  box-b
CONF
printf 'LINEAR_API_KEY=%s\n' "$LKEY" > "$H/env/lin1.env"
printf 'LINEAR_TEAM=CRO\n' > "$H/env/nolk.env"
printf 'JIRA_BASE=https://api.atlassian.com/ex/jira/%s\nJIRA_EMAIL=bot-fixture@example.com\nJIRA_API_TOKEN=%s\n' "$CLOUD" "$JTOK" > "$H/env/jir1.env"
printf 'BRD1_API_BASE=https://brd.example\nBRD1_INTERNAL_API_TOKEN=%s\n' "$BTOK" > "$H/env/brd1.env"
: > "$H/env/ghi1.env"; : > "$H/env/far1.env"
printf 'HARNESS_SECRET=fixture-secret-7924\nJOBS_URL=https://jobs.example\n' > "$H/env/global.env"
setrow() { printf '%s' "$2" > "$S/set/$1"; }
setrow tracker_adapter.lin1 linear
setrow tracker_linear.lin1.team CRO
setrow tracker_adapter.nolk linear
setrow tracker_adapter.jir1 jira
setrow tracker_jira.jir1.write_projects SCRUM
setrow tracker_jira.jir1.read_projects SCRUM
setrow tracker_jira.jir1.comment_projects SCRUM
setrow tracker_adapter.far1 linear

# ---- the curl stub: the jobs worker, Linear, the Jira gateway, one board ----
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$CP_STATE"; m=GET; url=""; data=""; out=""; fmt=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary|-d) data="$2"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -m|--max-time|--connect-timeout) shift ;;
    -H) case "$2" in Authorization:*|authorization:*) auth="${2#*: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
[ "$m" = GET ] && [ -n "$data" ] && m=POST
reply() { # reply <code> <body>
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  exit 0
}
printf '%s %s\n' "$m" "$url" >> "$S/reqs"
arm() { cat "$S/arm-$1" 2>/dev/null; }
case "$url" in
  https://jobs.example/api/settings/*)
    k="${url##*/}"
    [ -r "$S/set/$k" ] && reply 200 "$(jq -nc --arg k "$k" --rawfile v "$S/set/$k" '{setting:{key:$k,value:$v}}')"
    reply 404 '{"error":"no such setting"}' ;;
  https://jobs.example/api/connections/*/status)
    p="${url#https://jobs.example/api/connections/}"; p="${p%/status}"
    printf '%s' "$data" > "$S/post-$p.json"
    echo "$p" >> "$S/posts"
    [ -e "$S/post-fail" ] && reply 503 '{"error":"fixture worker down"}'
    reply 200 '{"ok":true}' ;;
  https://jobs.example/*) reply 404 '{"error":"no route"}' ;;
  https://api.linear.app/graphql)
    jq -r '.query' "${data#@}" >> "$S/linear-q"
    case "$(arm linear)" in
      401) reply 401 "{\"errors\":[{\"message\":\"Authentication failed for key $auth; also see $CP_STRAY and the long tail of this vendor message that runs on and on past any sane cap\"}]}" ;;
      401f) reply 401 "$(cat "$S/linear-body")" ;;
      429) reply 429 '{"error":"too many requests"}' ;;
      slow) sleep 8; reply 200 '{"data":{"viewer":{"id":"u-fixture"}}}' ;;   # determinism: ok a vendor stub that answers late on purpose; P7 asserts the probe's timeout (5 s) fires first
    esac
    [ "$auth" = "$CP_LKEY" ] || reply 401 '{"errors":[{"message":"bad key"}]}'
    reply 200 '{"data":{"viewer":{"id":"u-fixture"}}}' ;;
  https://api.atlassian.com/ex/jira/*/rest/api/3/myself)
    [ "$(arm jira)" = 401 ] && reply 401 '{"message":"Client must be authenticated"}'
    reply 200 '{"accountId":"acct-fixture"}' ;;
  https://brd.example/api/b/boards) reply 200 '[{"id":"b1"}]' ;;
  https://brd.example/api/b/boards/b1/tickets) reply 200 '[]' ;;
esac
echo "UNEXPECTED $m $url" >> "$S/unexpected"
exit 7
SH
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$CP_STATE/reqs"
case "$*" in
  *"repos/o/ghi1/issues"*) printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n[]\n'; exit 0 ;;
esac
echo "UNEXPECTED gh $*" >> "$CP_STATE/unexpected"
exit 7
SH
chmod +x "$T/stub/curl" "$T/stub/gh"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" PATH="$T/stub:$PATH" GH_ETAG=0 BOX_NAME=box-a
export CP_STATE="$S" CP_LKEY="$LKEY" CP_STRAY="$STRAY" CONNECTION_PROBE_NOW="$NOW"
export JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_SETTINGS_CACHE_S=0
unset HARNESS_SECRET JOBS_URL REGISTRY_SOURCE

reset() { rm -f "$S"/reqs "$S"/posts "$S"/post-*.json "$S"/linear-q "$S"/arm-* "$S"/linear-body "$S"/post-fail "$S"/unexpected; }
run() { # run <out> <args...> — the installed probe; rc in RC
  local o="$1"; shift
  RC=0; bash "$H/bin/connection-probe.sh" "$@" > "$T/$o.out" 2> "$T/$o.err" || RC=$?
}
post() { cat "$S/post-$1.json" 2>/dev/null; }
pf() { post "$1" | jq -r "$2" 2>/dev/null; }

# ---- P1 linear ---------------------------------------------------------------
reset; run p1 lin1
eq "P1 rc" "$RC" 0
eq "P1 adapter" "$(pf lin1 .adapter)" linear
eq "P1 ok" "$(pf lin1 .ok)" true
eq "P1 checkedAt is the pinned clock" "$(pf lin1 .checkedAt)" "$NOW_ISO"
eq "P1 LINEAR_API_KEY" "$(pf lin1 .credentialVars.LINEAR_API_KEY)" present
eq "P1 error" "$(pf lin1 '.error // "null"')" null
eq "P1 one Linear call" "$(grep -c 'https://api.linear.app/graphql' "$S/reqs" 2>/dev/null)" 1
grep -q 'viewer' "$S/linear-q" 2>/dev/null && ok || bad "P1 the Linear call is not a viewer query: $(cat "$S/linear-q" 2>/dev/null)"
eq "P1 one status POST" "$(grep -c '^POST https://jobs.example/api/connections/lin1/status$' "$S/reqs" 2>/dev/null)" 1
eq "P1 body keys" "$(post lin1 | jq -c 'keys' 2>/dev/null)" '["adapter","checkedAt","credentialVars","error","ok"]'
eq "P1 one log line" "$(grep -c ' lin1 ' "$H/logs/connection-probe.log" 2>/dev/null)" 1
eq "P1 lane default timeout" "$(jq -r '.knobs[] | select(.env == "CONNECTION_PROBE_TIMEOUT_S") | .default' "$DIR/catalog/lanes.d/connection-probe.json" 2>/dev/null)" 60
eq "P1 lane default error cap" "$(jq -r '.knobs[] | select(.env == "CONNECTION_PROBE_ERROR_MAX") | .default' "$DIR/catalog/lanes.d/connection-probe.json" 2>/dev/null)" 300
grep -qF '${CONNECTION_PROBE_TIMEOUT_S:-60}' "$PROBE" 2>/dev/null && ok || bad "P1 the script does not read \${CONNECTION_PROBE_TIMEOUT_S:-60}"
grep -qF '${CONNECTION_PROBE_ERROR_MAX:-300}' "$PROBE" 2>/dev/null && ok || bad "P1 the script does not read \${CONNECTION_PROBE_ERROR_MAX:-300}"

# ---- P2 jira -----------------------------------------------------------------
reset; run p2 jir1
eq "P2 rc" "$RC" 0
eq "P2 adapter" "$(pf jir1 .adapter)" jira
eq "P2 ok" "$(pf jir1 .ok)" true
eq "P2 vars" "$(post jir1 | jq -c '.credentialVars | [.JIRA_BASE, .JIRA_EMAIL, .JIRA_API_TOKEN]' 2>/dev/null)" '["present","present","present"]'
eq "P2 one GET /myself" "$(grep -c "^GET https://api.atlassian.com/ex/jira/$CLOUD/rest/api/3/myself$" "$S/reqs" 2>/dev/null)" 1
eq "P2 no other Jira call" "$(grep -c 'api.atlassian.com' "$S/reqs" 2>/dev/null)" 1

# ---- P3 board, P4 github-issues ------------------------------------------------
reset; run p3 brd1
eq "P3 rc" "$RC" 0
eq "P3 adapter" "$(pf brd1 .adapter)" board
eq "P3 ok" "$(pf brd1 .ok)" true
eq "P3 vars" "$(post brd1 | jq -c '.credentialVars' 2>/dev/null)" '{"BRD1_API_BASE":"present","BRD1_INTERNAL_API_TOKEN":"present"}'
eq "P3 one ticket list" "$(grep -c '^GET https://brd.example/api/b/boards/b1/tickets$' "$S/reqs" 2>/dev/null)" 1
reset; run p4 ghi1
eq "P4 rc" "$RC" 0
eq "P4 adapter" "$(pf ghi1 .adapter)" github-issues
eq "P4 ok" "$(pf ghi1 .ok)" true
eq "P4 no credential vars" "$(post ghi1 | jq -c '.credentialVars' 2>/dev/null)" '{}'
eq "P4 one issue list" "$(grep -c '^gh .*repos/o/ghi1/issues' "$S/reqs" 2>/dev/null)" 1

# ---- P5 missing key ------------------------------------------------------------
reset; run p5 nolk
eq "P5 rc (the status was written)" "$RC" 0
eq "P5 ok" "$(pf nolk .ok)" false
eq "P5 var missing" "$(pf nolk .credentialVars.LINEAR_API_KEY)" missing
pf nolk .error | grep -q 'LINEAR_API_KEY' && ok || bad "P5 the error does not name LINEAR_API_KEY: $(pf nolk .error)"
eq "P5 no Linear call" "$(grep -c 'api.linear.app' "$S/reqs" 2>/dev/null)" 0

# ---- P6 401 / rate limit / no adapter --------------------------------------------
reset; echo 401 > "$S/arm-linear"
CONNECTION_PROBE_ERROR_MAX=60 run p6 lin1
eq "P6 rc" "$RC" 0
eq "P6 ok" "$(pf lin1 .ok)" false
E6=$(pf lin1 .error)
case "$E6" in *"linear answered HTTP 401"*) ok ;; *) bad "P6 the error is not the adapter's 401 text: $E6" ;; esac
[ "${#E6}" -le 60 ] && ok || bad "P6 the error is ${#E6} chars, over CONNECTION_PROBE_ERROR_MAX=60"
reset; echo 401 > "$S/arm-linear"
run p6b lin1
E6B=$(pf lin1 .error)
case "$E6B" in *"for key <redacted>;"*) ok ;; *) bad "P6 the echoed key was not replaced by <redacted>: $E6B" ;; esac
case "$E6B" in *"$STRAY"*|*ghp_*) bad "P6 a token-shaped word was not scrubbed: $E6B" ;; *) ok ;; esac
case "$E6B" in *"$LKEY"*) bad "P6 the key value is in the error: $E6B" ;; *) ok ;; esac
[ "${#E6B}" -le 300 ] && [ "${#E6B}" -gt 60 ] && ok || bad "P6 the default cut is 300 (got ${#E6B} chars)"
# The cut is in JSON bytes, not characters: quotes and backslashes double when
# encoded and é is 2 bytes, so a 1500-character cut alone passes 2048 bytes.
# Both locales: under C, bash cuts bytes; under C.UTF-8, characters.
for loc in C C.utf8; do
  reset; echo 401f > "$S/arm-linear"
  jq -nc --arg m "$(for i in $(seq 900); do printf '"\\é'; done)" '{errors: [{message: $m}]}' > "$S/linear-body"
  LC_ALL=$loc CONNECTION_PROBE_ERROR_MAX=1500 run p6j lin1
  eq "P6 $loc rc" "$RC" 0
  EB=$(post lin1 | jq '.error | tojson | utf8bytelength - 2' 2>/dev/null)
  [ -n "$EB" ] && [ "$EB" -le 1500 ] && [ "$EB" -gt 1400 ] && ok || bad "P6 $loc the error is $EB JSON bytes, not in 1401..1500"
  BB=$(post lin1 | LC_ALL=C wc -c | tr -d ' ')
  [ "$BB" -le 1900 ] && ok || bad "P6 $loc the body is $BB bytes; with the worker's fields it can pass 2048"
  pf lin1 .error | grep -q 'linear answered HTTP 401' && ok || bad "P6 $loc the cut lost the 401 text: $(pf lin1 .error | head -c 80)"
done
# A key with no token prefix: only the step-5 value scrub can hide it.
PKEY=key-fixture-plain-7924
printf 'lin2  o/lin2  -  -  7  box-b\n' >> "$H/fleet.conf"
printf 'LINEAR_API_KEY=%s\n' "$PKEY" > "$H/env/lin2.env"
setrow tracker_adapter.lin2 linear; setrow tracker_linear.lin2.team CRO
reset; echo 401 > "$S/arm-linear"
run p6v lin2
E6V=$(pf lin2 .error)
case "$E6V" in *"for key <redacted>;"*) ok ;; *) bad "P6 the plain key value was not replaced by <redacted>: $E6V" ;; esac
case "$E6V" in *"$PKEY"*) bad "P6 the plain key value is in the error: $E6V" ;; *) ok ;; esac
grep -rqF "$PKEY" "$T"/p6v.out "$T"/p6v.err "$H/logs" "$S"/post-lin2.json 2>/dev/null && bad "P6 the plain key value is in an output, log or POST body" || ok
sed -i '/^lin2 /d' "$H/fleet.conf"
reset; echo 429 > "$S/arm-linear"
run p6c lin1
eq "P6 rate limit ok" "$(pf lin1 .ok)" false
pf lin1 .error | grep -q 'rate limited' && ok || bad "P6 rc 75 must say rate limited: $(pf lin1 .error)"
reset; setrow tracker_adapter.junk trello; printf 'junk o/junk - - 7 box-a\n' >> "$H/fleet.conf"
run p6d junk
eq "P6 no adapter rc" "$RC" 0
eq "P6 no adapter ok" "$(pf junk .ok)" false
eq "P6 no adapter adapter" "$(pf junk .adapter)" null
pf junk .error | grep -q 'no tracker adapter for junk' && ok || bad "P6 no adapter error: $(pf junk .error)"
sed -i '/^junk /d' "$H/fleet.conf"; rm -f "$S/set/tracker_adapter.junk"

# P5 (all outputs): no token value anywhere the probe wrote
LEAK=$(grep -rlF -e "$LKEY" -e "$JTOK" -e "$BTOK" -e "$STRAY" "$T"/*.out "$T"/*.err "$H/logs" "$S"/post-*.json 2>/dev/null)
eq "P5 no token value in any output, log or POST body" "$LEAK" ""
eq "P5/P6 no ALERTS line" "$(cat "$H/logs/ALERTS.log" 2>/dev/null)" ""

# ---- P7 exit paths -----------------------------------------------------------------
reset; touch "$S/post-fail"; L0=$(grep -c . "$H/logs/connection-probe.log" 2>/dev/null)
run p7 lin1
eq "P7 a failed POST is rc 1" "$RC" 1
eq "P7 one log line" "$(( $(grep -c . "$H/logs/connection-probe.log" 2>/dev/null) - L0 ))" 1
tail -1 "$H/logs/connection-probe.log" 2>/dev/null | grep -q 'write=failed' && ok || bad "P7 the log line does not say write=failed: $(tail -1 "$H/logs/connection-probe.log" 2>/dev/null)"
eq "P7 one POST, no retry" "$(grep -c 'api/connections/lin1/status' "$S/reqs" 2>/dev/null)" 1
eq "P7 no ALERTS line" "$(cat "$H/logs/ALERTS.log" 2>/dev/null)" ""
reset; echo slow > "$S/arm-linear"
CONNECTION_PROBE_TIMEOUT_S=5 run p7t lin1
eq "P7 timeout rc (written)" "$RC" 0
eq "P7 timeout ok" "$(pf lin1 .ok)" false
eq "P7 timeout error" "$(pf lin1 .error)" "timed out after 5s"
eq "P7 timeout adapter" "$(pf lin1 .adapter)" linear
reset; run p7u
eq "P7 no argument is rc 2" "$RC" 2
run p7v --box extra
eq "P7 --box with an argument is rc 2" "$RC" 2
run p7w 'Bad Name'
eq "P7 a bad project name is rc 2" "$RC" 2
CONNECTION_PROBE_TIMEOUT_S=9999 run p7k lin1
eq "P7 a knob out of range is rc 2" "$RC" 2
eq "P7 usage wrote nothing" "$(cat "$S/posts" 2>/dev/null)" ""
run p7d --dry-run lin1
eq "P7 dry-run rc" "$RC" 0
eq "P7 dry-run prints the body" "$(jq -r '.adapter + " " + (.ok|tostring)' "$T/p7d.out" 2>/dev/null)" "linear true"
eq "P7 dry-run writes nothing" "$(cat "$S/posts" 2>/dev/null)" ""

# ---- P8 --box ---------------------------------------------------------------------
reset; echo 401 > "$S/arm-jira"
run p8 --box
eq "P8 rc (every status written)" "$RC" 0
eq "P8 the projects of box-a, in order" "$(tr '\n' ' ' < "$S/posts" 2>/dev/null)" "lin1 jir1 brd1 ghi1 nolk "
eq "P8 jira failed and the next ones still ran" "$(pf jir1 .ok) $(pf brd1 .ok)" "false true"
pf jir1 .error | grep -q 'answered 401' && ok || bad "P8 the jira 401 text: $(pf jir1 .error)"
[ -e "$S/post-far1.json" ] && bad "P8 far1 (box-b) was probed" || ok

# ---- P9 key prefix from the PUT-shaped rows ------------------------------------------
P9=$( . "$H/bin/lib/tracker.sh" && tracker_key_prefix lin1 ); eq "P9 linear prefix" "$P9" CRO
P9=$( . "$H/bin/lib/tracker.sh" && tracker_key_prefix jir1 ); eq "P9 jira prefix" "$P9" SCRUM

# ---- P10 no real host -------------------------------------------------------------------
eq "P10 no call to an unplayed host" "$(cat "$S/unexpected" 2>/dev/null)" ""
reset; ( . "$H/bin/lib/tracker.sh" && tracker_load linear && TRK_LINEAR_TOKEN=x TRK_LINEAR_API=https://real-host.invalid/graphql trk_linear_viewer ) >/dev/null 2>&1
grep -q 'UNEXPECTED' "$S/unexpected" 2>/dev/null && ok || bad "P10 the curl stub must refuse an unplayed host"

echo "connection-probe.bh-7924-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
