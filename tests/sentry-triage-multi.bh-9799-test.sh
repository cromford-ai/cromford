#!/bin/bash
# tests/sentry-triage-multi.bh-9799-test.sh — BH-9799 T4/T5: the sentry-triage
# lane runs one pass per Sentry source: the default source (SENTRY_TRIAGE_PROJECT
# with SENTRY_API_TOKEN) and every project with a `sentry` block in
# catalog/signal-sources.d/. Drives the REAL bin/sentry-triage.sh in a scratch
# harness (the BH-5620 pattern: scratch_install_closure, a fake curl on PATH,
# SENTRY_TRIAGE_FIXTURE for the ledger and gh, stub agent-call and lane-alert).
#
# Sources: SIGNAL_SOURCES_DIR (sandbox seam) holds alpha (org example-org-a)
# and beta (org example-org-b); FLEET_CONF maps them to example-org/fixture-alpha
# and example-org/fixture-beta.
#
#   S1  one new issue per project: rows alpha:111 and beta:222, one create in
#       each repo, two summary lines project=alpha / project=beta with filed=1
#   S2  the next tick: 0 model calls, still 2 creates
#   S3  MAX_TICKETS_DAY=1, two issues per project: one create per project; day
#       rows alpha:<day> and beta:<day> each list one id
#   S3b MAX_CALLS_DAY=1, two issues per project: one call per project
#   S4  ledger unreadable: 0 calls, 0 creates, exactly one sentry-triage-ledger alert
#   S5  beta has no token: alpha files, one log line, no beta call, no alert
#   S6  the same Sentry id 333 in both orgs: two rows, two creates
#   S7  beta's token only in $H/env/beta.env: the beta list call carries it
#   S8  a model answer with a fixture posthog key: masked in the body and the log
#   S9  the default source with alpha: bare keys, summary line without project=
#   S10 alpha's list answers 500: one alert sentry-triage-list-alpha, beta files
#   S11 the prompt names the source; open-list failure stops only that source
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/sentry-triage-multi.bh-9799-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "sentry-triage-multi: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

for f in "$DIR/bin/sentry-triage.sh" "$DIR/bin/lib/sentry-triage.sh" "$DIR/bin/lib/signal-source.sh"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

H="$T/h"
export FXT="$T/fx"
mkdir -p "$H/env" "$H/catalog/prompts" "$T/fakebin" "$T/src"
scratch_install_closure bin/sentry-triage.sh "$H" >/dev/null || bad "closure install failed"
cp "$DIR/catalog/prompts/sentry-triage.md" "$H/catalog/prompts/" 2>/dev/null
: > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf 'call %s\n' "$AGENT_CALL_FP" >> "$FXT/ac.log"
case "$6" in @*) cp "${6#@}" "$FXT/prompt.last" 2>/dev/null ;; esac
cat "$FXT/answer.txt" > "$5" 2>/dev/null
exit 0
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"

# Sentry: /projects/<org>/<slug>/issues/ answers $FXT/issues-<slug>.json with
# the code in $FXT/list-<slug>.code. Every call logs method, url and the token.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
out=""; prev=""; m=GET; auth=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -X) m="$a" ;; -H) case "$a" in Authorization:*) auth="${a#Authorization: Bearer }" ;; esac ;; esac
  prev="$a"
done
url="${!#}"
printf '%s %s %s\n' "$m" "$url" "$auth" >> "$FXT/curl.log"
code=200; body='{}'
case "$url" in
  */projects/*/issues/*) slug=$(printf '%s' "$url" | sed -n 's#.*/projects/[^/]*/\([^/]*\)/issues/.*#\1#p')
                         body=$(cat "$FXT/issues-$slug.json" 2>/dev/null || echo '[]'); code=$(cat "$FXT/list-$slug.code" 2>/dev/null || echo 200) ;;
  */events/latest/*) body='{"message":"fixture message","title":"Example error","dateCreated":"2026-10-11T00:00:00Z","tags":[{"key":"reason","value":"example-reason-fixture"}]}' ;;
  */comments/*) code=201; body='{"detail":"fixture"}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
printf '%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

cat > "$T/fixture.sh" <<'SH'
job_ledger_row() {
  [ "$(cat "$FXT/ledger.rc" 2>/dev/null)" = 1 ] && return 1
  [ -f "$FXT/ledger/$1.$2" ] || return 2
  cat "$FXT/ledger/$1.$2"
}
job_ledger_put() {
  [ "$(cat "$FXT/ledger.rc" 2>/dev/null)" = 1 ] && return 1
  jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s, detail:$d[0:4000]}' > "$FXT/ledger/$1.$2"
}
lane_role_model() { echo stub-model; }
lane_model_ladder() { printf '0\tstub-model\tclaude\n'; }
GH_N=9000
gh_rest() {
  local m=$1 p=$2 f=""; shift 2
  [ "${1:-}" = --input ] && f=$2
  if [ -n "$f" ]; then printf '%s %s %s\n' "$m" "$p" "$(jq -c . "$f")" >> "$FXT/gh.log"
  else printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"; fi
  case "$m $p" in
    "GET "*/comments) GH_REST_STATUS=200; echo '[]'; return 0 ;;
  esac
  GH_N=$((GH_N + 1)); GH_REST_STATUS=201
  printf '{"number":%s,"html_url":"https://github.com/example-org/example-repo/issues/%s"}' "$GH_N" "$GH_N"
}
gh_rest_comment() { printf 'COMMENT %s %s\n' "$1" "$2" >> "$FXT/gh.log"; GH_REST_STATUS=201; }
gh_rest_issue_list() {
  printf 'LIST %s\n' "$1" >> "$FXT/gh.log"
  if [ -f "$FXT/open-fail-$(basename "$1")" ]; then GH_REST_STATUS=502; return 75; fi
  GH_REST_STATUS=200; echo '[]'
}
SH

jq -nc '{project: "alpha", sentry: {org: "example-org-a", project: "alpha-app", token_env: "SENTRY_ALPHA_TOKEN"}}' > "$T/src/alpha.json"
jq -nc '{project: "beta", sentry: {org: "example-org-b", project: "beta-app", token_env: "SENTRY_BETA_TOKEN"}}' > "$T/src/beta.json"
# A row with only a posthog block is not a Sentry source.
jq -nc '{project: "gamma", posthog: {host: "https://posthog.example.com", project_id: "1", key_env: "POSTHOG_GAMMA_KEY", filter: ""}}' > "$T/src/gamma.json"
printf '%s\n' "# fixture fleet" "alpha  example-org/fixture-alpha  https://alpha.example.com  -  1  box-fixture 192.0.2.1" \
  "beta   example-org/fixture-beta   https://beta.example.com   -  1  box-fixture 192.0.2.1" \
  "gamma  example-org/fixture-gamma  https://gamma.example.com  -  1  box-fixture 192.0.2.1" > "$T/fleet.conf"

NOW=1791676800
DAY=$(date -u -d "@$NOW" +%F)
LOG="$H/logs/sentry-triage.log"

mkissue() { # mkissue <id> <count>
  jq -nc --arg id "$1" --arg c "$2" '{id: $id, shortId: ("APP-" + $id), title: ("Example error " + $id),
    permalink: ("https://sentry.example.com/issues/" + $id + "/"), count: $c, status: "unresolved", substatus: "ongoing",
    stats: {"24h": [[1791673200, 1], [1791676800, 1]]}}'
}
answer_ticket() {
  printf '%s\n' '{"verdict":"ticket","title":"Example lane fails","cause":"The lane reads a missing file.","proposed_fix":"Create the file first.","acceptance_tests":["T1: the lane runs with the file absent."]}' > "$FXT/answer.txt"
}
reset() {
  scratch_rm "$FXT"; mkdir -p "$FXT/ledger"
  rm -f "$LOG" "$H/env/beta.env"
  answer_ticket
}
run() {
  env -u SENTRY_API_TOKEN -u SENTRY_ALPHA_TOKEN -u SENTRY_BETA_TOKEN -u HARNESS_ENV_DIR \
    HARNESS="$H" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 SENTRY_TRIAGE_NOW="$NOW" \
    SENTRY_TRIAGE_FIXTURE="$T/fixture.sh" SIGNAL_SOURCES_DIR="$T/src" FLEET_CONF="$T/fleet.conf" \
    SENTRY_ALPHA_TOKEN=alpha-tok-fixture SENTRY_BETA_TOKEN=beta-tok-fixture HARNESS_REPO=example-org/harness-fixture \
    JOBS_URL= JOBS_BOX=box-fixture "$@" bash "$H/bin/sentry-triage.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
calls()   { if [ -f "$FXT/ac.log" ]; then wc -l < "$FXT/ac.log"; else echo 0; fi; }
creates() { if [ -f "$FXT/gh.log" ]; then grep -c "^POST repos/${1:-.*}/issues " "$FXT/gh.log"; else echo 0; fi; }
lstat()   { jq -r .status "$FXT/ledger/sentry-triage.$1" 2>/dev/null; }
alerts()  { if [ -f "$FXT/alerts.log" ]; then wc -l < "$FXT/alerts.log"; else echo 0; fi; }
sumline() { grep " sentry-triage $1" "$LOG" 2>/dev/null | tail -1; }

# ── S1: one new issue per project ────────────────────────────────────────────
reset
mkissue 111 5 | jq -s . > "$FXT/issues-alpha-app.json"
mkissue 222 5 | jq -s . > "$FXT/issues-beta-app.json"
run
check "S1 rc 0 [$(head -c 300 "$T/out")]" '[ "$(cat "$T/rc")" = 0 ]'
check "S1 two model calls ($(calls))" '[ "$(calls)" = 2 ]'
check "S1 rows alpha:111 and beta:222 ticketed" '[ "$(lstat alpha:111)" = ticketed ] && [ "$(lstat beta:222)" = ticketed ]'
check "S1 no bare row" '[ ! -e "$FXT/ledger/sentry-triage.111" ] && [ ! -e "$FXT/ledger/sentry-triage.222" ]'
check "S1 one create in each repo" '[ "$(creates example-org/fixture-alpha)" = 1 ] && [ "$(creates example-org/fixture-beta)" = 1 ] && [ "$(creates)" = 2 ]'
check "S1 summary project=alpha filed=1 [$(sumline project=alpha)]" '[[ "$(sumline project=alpha)" == *" sentry-triage project=alpha issues=1 "*" filed=1 "* ]]'
check "S1 summary project=beta filed=1" '[[ "$(sumline project=beta)" == *" sentry-triage project=beta issues=1 "*" filed=1 "* ]]'
check "S1 alpha listed in its own org with its own token" 'grep -q "^GET https://sentry.io/api/0/projects/example-org-a/alpha-app/issues/.* alpha-tok-fixture$" "$FXT/curl.log"'
check "S1 beta listed in its own org with its own token" 'grep -q "^GET https://sentry.io/api/0/projects/example-org-b/beta-app/issues/.* beta-tok-fixture$" "$FXT/curl.log"'
check "S1 the beta event read carries the beta token" 'grep -q "/issues/222/events/latest/ beta-tok-fixture$" "$FXT/curl.log"'
BODY=$(grep '^POST repos/example-org/fixture-alpha/issues ' "$FXT/gh.log" | cut -d' ' -f3- | jq -r .body 2>/dev/null)
check "S1 the alpha body marker holds the prefixed key" 'grep -qF "<!-- sentry-issue: alpha:111 -->" <<<"$BODY"'
check "S1 the open list read per repo" 'grep -q "^LIST example-org/fixture-alpha$" "$FXT/gh.log" && grep -q "^LIST example-org/fixture-beta$" "$FXT/gh.log"'
check "S1 the default source: no token, one log line" 'grep -q "sentry token unset; nothing read" "$LOG"'
check "S1 a posthog-only row is not a Sentry source" '! grep -q "project=gamma" "$LOG" && ! grep -q "fixture-gamma" "$FXT/gh.log"'
check "S1 no token in the log" '! grep -q "tok-fixture" "$LOG"'
check "S1 the prompt names the source" 'grep -q "^## Sentry source" "$FXT/prompt.last" && grep -q "example-org-b/beta-app" "$FXT/prompt.last"'

# ── S2: the next tick makes no call ─────────────────────────────────────────
run
check "S2 still 2 calls ($(calls))" '[ "$(calls)" = 2 ]'
check "S2 still 2 creates" '[ "$(creates)" = 2 ]'
check "S2 summary terminal=1 for alpha" '[[ "$(sumline project=alpha)" == *" terminal=1 called=0 "* ]]'

# ── S3: the day ticket cap counts per project ───────────────────────────────
reset
{ mkissue 111 9; mkissue 112 7; } | jq -s . > "$FXT/issues-alpha-app.json"
{ mkissue 221 9; mkissue 222 7; } | jq -s . > "$FXT/issues-beta-app.json"
run SENTRY_TRIAGE_MAX_TICKETS_DAY=1
check "S3 one create per project" '[ "$(creates example-org/fixture-alpha)" = 1 ] && [ "$(creates example-org/fixture-beta)" = 1 ]'
check "S3 day row alpha:$DAY lists 111" '[ "$(jq -c ".detail | fromjson | .filed" "$FXT/ledger/sentry-triage-day.alpha:$DAY" 2>/dev/null)" = "[\"111\"]" ]'
check "S3 day row beta:$DAY lists 221" '[ "$(jq -c ".detail | fromjson | .filed" "$FXT/ledger/sentry-triage-day.beta:$DAY" 2>/dev/null)" = "[\"221\"]" ]'
check "S3 no bare day row" '[ ! -e "$FXT/ledger/sentry-triage-day.$DAY" ]'
check "S3 capped=1 in each summary" '[[ "$(sumline project=alpha)" == *" capped=1"* ]] && [[ "$(sumline project=beta)" == *" capped=1"* ]]'
reset
{ mkissue 111 9; mkissue 112 7; } | jq -s . > "$FXT/issues-alpha-app.json"
{ mkissue 221 9; mkissue 222 7; } | jq -s . > "$FXT/issues-beta-app.json"
run SENTRY_TRIAGE_MAX_CALLS_DAY=1
check "S3b one call per project ($(calls))" '[ "$(calls)" = 2 ]'
check "S3b each day row counts 1 call" '[ "$(jq -r ".detail | fromjson | .calls" "$FXT/ledger/sentry-triage-day.alpha:$DAY")" = 1 ] && [ "$(jq -r ".detail | fromjson | .calls" "$FXT/ledger/sentry-triage-day.beta:$DAY")" = 1 ]'

# ── S4: an unreadable ledger stops the whole tick ───────────────────────────
reset; echo 1 > "$FXT/ledger.rc"
mkissue 111 5 | jq -s . > "$FXT/issues-alpha-app.json"
mkissue 222 5 | jq -s . > "$FXT/issues-beta-app.json"
run
check "S4 no call ($(calls))" '[ "$(calls)" = 0 ]'
check "S4 no create" '[ "$(creates)" = 0 ]'
check "S4 exactly one alert, sentry-triage-ledger ($(alerts))" '[ "$(alerts)" = 1 ] && grep -q "sentry-triage-ledger" "$FXT/alerts.log"'
check "S4 beta is not read after the outage" '! grep -q "example-org-b" "$FXT/curl.log"'

# ── S5: beta has no token ───────────────────────────────────────────────────
reset
mkissue 111 5 | jq -s . > "$FXT/issues-alpha-app.json"
mkissue 222 5 | jq -s . > "$FXT/issues-beta-app.json"
run SENTRY_BETA_TOKEN=
check "S5 alpha files" '[ "$(creates example-org/fixture-alpha)" = 1 ]'
check "S5 one beta log line" '[ "$(grep -c "project=beta: SENTRY_BETA_TOKEN unset; nothing read" "$LOG")" = 1 ]'
check "S5 no beta call" '! grep -q "example-org-b" "$FXT/curl.log" && [ "$(creates example-org/fixture-beta)" = 0 ]'
check "S5 no alert" '[ "$(alerts)" = 0 ]'

# ── S6: the same Sentry id in two orgs ──────────────────────────────────────
reset
mkissue 333 5 | jq -s . > "$FXT/issues-alpha-app.json"
mkissue 333 5 | jq -s . > "$FXT/issues-beta-app.json"
run
check "S6 two rows alpha:333 and beta:333" '[ "$(lstat alpha:333)" = ticketed ] && [ "$(lstat beta:333)" = ticketed ]'
check "S6 two creates" '[ "$(creates)" = 2 ] && [ "$(calls)" = 2 ]'

# ── S7: beta's token only in $H/env/beta.env ───────────────────────────────
reset
mkissue 222 5 | jq -s . > "$FXT/issues-beta-app.json"
printf 'export SENTRY_BETA_TOKEN="%s"\n' "beta-file-tok-fixture" > "$H/env/beta.env"
run SENTRY_BETA_TOKEN=
check "S7 the beta list call carries the file token" 'grep -q "^GET .*/projects/example-org-b/beta-app/issues/.* beta-file-tok-fixture$" "$FXT/curl.log"'
check "S7 beta files" '[ "$(lstat beta:222)" = ticketed ]'

# ── S8: a token in the model answer is masked in the body and the log ──────
PK="p""hx_fixture$(printf 'k%.0s' $(seq 1 40))"
reset
mkissue 111 5 | jq -s . > "$FXT/issues-alpha-app.json"
jq -nc --arg k "$PK" '{verdict: "ticket", title: ("Key " + $k + " leaked"), cause: ("The answer holds " + $k + " now."), proposed_fix: "Rotate it.", acceptance_tests: ["T1: masked."]}' > "$FXT/answer.txt"
run
PAY=$(grep '^POST repos/example-org/fixture-alpha/issues ' "$FXT/gh.log" | cut -d' ' -f3-)
check "S8 the body is masked" '[ -n "$PAY" ] && jq -r .body <<<"$PAY" | grep -qF "The answer holds <redacted:posthog-key> now." && ! grep -qF "$PK" <<<"$PAY"'
check "S8 the title is masked" 'jq -r .title <<<"$PAY" | grep -qF "<redacted:posthog-key>"'
reset
mkissue 112 5 | jq -s . > "$FXT/issues-alpha-app.json"
jq -nc --arg k "$PK" '{verdict: "noise", reason: ("A test sent " + $k)}' > "$FXT/answer.txt"
run
LOGTXT=$(cat "$LOG")
check "S8 the noise log line is masked" 'grep -qF "alpha:112 noise: A test sent <redacted:posthog-key>" <<<"$LOGTXT" && ! grep -qF "$PK" <<<"$LOGTXT"'

# ── S9: the default source keeps bare keys and its summary line ─────────────
reset
mkissue 101 5 | jq -s . > "$FXT/issues-cromford-harness.json"
mkissue 111 5 | jq -s . > "$FXT/issues-alpha-app.json"
run SENTRY_API_TOKEN=global-tok-fixture
check "S9 the default row is bare (101)" '[ "$(lstat 101)" = ticketed ]'
check "S9 alpha row is prefixed" '[ "$(lstat alpha:111)" = ticketed ]'
check "S9 the default list uses the global token" 'grep -q "^GET .*/projects/operator/cromford-harness/issues/.* global-tok-fixture$" "$FXT/curl.log"'
check "S9 the default files in HARNESS_REPO" '[ "$(creates example-org/harness-fixture)" = 1 ]'
DL=$(grep " sentry-triage issues=" "$LOG" | tail -1)
check "S9 default summary has no project= [$DL]" '[[ "$DL" == *" sentry-triage issues=1 "*" filed=1 "* ]]'
check "S9 bare day row for the default" '[ "$(jq -c ".detail | fromjson | .filed" "$FXT/ledger/sentry-triage-day.$DAY" 2>/dev/null)" = "[\"101\"]" ]'

# ── S10: one source's list failure is one alert; the next source runs ──────
reset
echo '{"detail":"fixture error"}' > "$FXT/issues-alpha-app.json"; echo 500 > "$FXT/list-alpha-app.code"
mkissue 222 5 | jq -s . > "$FXT/issues-beta-app.json"
run
check "S10 exactly one alert ($(alerts))" '[ "$(alerts)" = 1 ]'
check "S10 the alert id is sentry-triage-list-alpha" 'grep -q -- "--id sentry-triage-list-alpha " "$FXT/alerts.log"'
check "S10 beta files" '[ "$(creates example-org/fixture-beta)" = 1 ]'

# ── S11: an open-list failure stops only that source ───────────────────────
reset; touch "$FXT/open-fail-fixture-alpha"
mkissue 111 5 | jq -s . > "$FXT/issues-alpha-app.json"
mkissue 222 5 | jq -s . > "$FXT/issues-beta-app.json"
run
check "S11 alpha makes no call; beta files" '[ "$(calls)" = 1 ] && [ "$(creates example-org/fixture-alpha)" = 0 ] && [ "$(creates example-org/fixture-beta)" = 1 ]'
# A project with no fleet.conf repo reads nothing.
reset
jq -nc '{project: "delta", sentry: {org: "example-org-d", project: "delta-app", token_env: "SENTRY_DELTA_TOKEN"}}' > "$T/src/delta.json"
run SENTRY_DELTA_TOKEN=delta-tok-fixture
check "S11 no fleet.conf repo: one log line, no read" 'grep -q "project=delta: no fleet.conf repo; nothing read" "$LOG" && ! grep -q "example-org-d" "$FXT/curl.log"'
rm -f "$T/src/delta.json"

echo "sentry-triage-multi: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
