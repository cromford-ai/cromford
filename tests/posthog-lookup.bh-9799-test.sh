#!/bin/bash
# tests/posthog-lookup.bh-9799-test.sh — BH-9799 T3/T7: bin/posthog-lookup.sh
# <project> "<hogql>" | --report api-failures|web-vitals runs ONE HogQL query
# with the project's PostHog key (catalog/signal-sources.d/<project>.json,
# bin/lib/signal-source.sh) and prints tab-separated rows. A missing key, a
# refused query and any API failure print ONE line and exit 0.
#
# A fake `curl` first on PATH logs the URL, the method, the body, the
# Authorization header from the --config fd and its own argv, and answers
# $FX/answer.json with the code in $FX/code (or exits $FX/curl.rc). 0 real
# network calls.
#
#   P1  2 rows: header plus 2 tab rows; POST .../api/projects/598179/query/, HogQLQuery body
#   P2  HTTP 401   P3 curl rc 28   P4 key unset   P5 no row (project-5)
#   P6  --report api-failures HogQL   P7 --report web-vitals HogQL
#   P8  an invalid posthog block      P9 knobs (48 h, 3 rows; 0 days is out of range: 7)
#   P10 the triage and medic prompts name both reports
#   P11 person-field queries refused, 0 calls; ordinary queries allowed
#   P12 the key is on no argv and in no output
#   P13 an email in a cell is masked; 5 rows under a cap of 3: "2 more rows"
#   P14 bad usage: rc 2; not JSON: one line
#   R   the registry knob defaults
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/posthog-lookup.bh-9799-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "posthog-lookup: jq is required"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

for f in "$DIR/bin/posthog-lookup.sh" "$DIR/bin/lib/signal-source.sh" "$DIR/catalog/lanes.d/_lib.posthog-lookup.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

H="$T/h"; export FX="$T/fx"
mkdir -p "$H/env" "$H/catalog" "$T/fakebin" "$FX"
scratch_install_closure bin/posthog-lookup.sh "$H" >/dev/null || bad "closure install failed"
cp -r "$DIR/catalog/signal-sources.d" "$H/catalog/" 2>/dev/null

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
out=""; prev=""; m=GET; body=""; auth=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;;
    -X) m="$a" ;;
    --data-binary) case "$a" in @*) body=$(cat "${a#@}") ;; *) body="$a" ;; esac ;;
    --config) auth=$(sed -n 's/^header = "\(Authorization: .*\)"$/\1/p' "$a") ;;
  esac
  prev="$a"
done
url="${!#}"
printf 'URL %s\nMETHOD %s\nAUTH %s\nBODY %s\nARGV %s\n' "$url" "$m" "$auth" "$body" "$*" >> "$FX/curl.log"
rc=$(cat "$FX/curl.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || { printf '000'; exit "$rc"; }
if [ -n "$out" ]; then cat "$FX/answer.json" > "$out"; else cat "$FX/answer.json"; fi
printf '%s' "$(cat "$FX/code" 2>/dev/null || echo 200)"
exit 0
SH
chmod +x "$T/fakebin/curl"

KEY="ph-fixture-personal-key-1"
reset() { rm -f "$FX/curl.log" "$FX/curl.rc" "$FX/code"; jq -nc '{columns: ["event", "n"], results: [["$pageview", 12], ["signup", 3]]}' > "$FX/answer.json"; }
run() { # run <env...> -- <args...>
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  env -u POSTHOG_MK_PERSONAL_API_KEY -u HARNESS_ENV_DIR -u POSTHOG_LOOKUP_TIMEOUT_S -u POSTHOG_LOOKUP_MAX_ROWS \
    -u POSTHOG_REPORT_API_FAILURES_H -u POSTHOG_REPORT_WEB_VITALS_D -u POSTHOG_REPORT_API_FAILURE_EVENT \
    HARNESS="$H" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 JOBS_URL= "${e[@]}" \
    bash "$H/bin/posthog-lookup.sh" "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
calls() { if [ -f "$FX/curl.log" ]; then grep -c '^URL ' "$FX/curl.log"; else echo 0; fi; }
field() { sed -n "s/^$1 //p" "$FX/curl.log" 2>/dev/null | head -1; }
sentq() { field BODY | jq -r '.query.query' 2>/dev/null; }
lines() { wc -l < "$T/out"; }

# ── P1: rows ─────────────────────────────────────────────────────────────────
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "select event, count() as n from events group by event"
check "P1 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "P1 header + 2 rows [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "$(printf "event\tn\n\$pageview\t12\nsignup\t3")" ]'
check "P1 POST to the project query url [$(field URL)]" '[ "$(field URL)" = "https://us.posthog.com/api/projects/598179/query/" ] && [ "$(field METHOD)" = POST ]'
check "P1 body kind HogQLQuery, the exact query" '[ "$(field BODY | jq -r .query.kind)" = HogQLQuery ] && [ "$(sentq)" = "select event, count() as n from events group by event" ]'
check "P1 the key rides in the config [$(field AUTH | cut -c1-30)]" '[ "$(field AUTH)" = "Authorization: Bearer $KEY" ]'

# ── P2-P5: one line, rc 0 ────────────────────────────────────────────────────
reset; echo 401 > "$FX/code"; echo '{"detail":"fixture denied select secret"}' > "$FX/answer.json"
run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "select 1"
check "P2 401 [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(posthog lookup failed: HTTP 401)" ] && [ "$(cat "$T/rc")" = 0 ]'
reset; echo 28 > "$FX/curl.rc"
run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "select 1"
check "P3 timeout [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(posthog lookup failed: timeout)" ] && [ "$(cat "$T/rc")" = 0 ]'
reset; echo 7 > "$FX/curl.rc"
run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "select 1"
check "P3 other curl error [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(posthog lookup failed: curl error 7)" ]'
reset; run -- project-6-os "select 1"
check "P4 key unset [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(posthog lookup unavailable — POSTHOG_MK_PERSONAL_API_KEY unset for project-6-os)" ] && [ "$(cat "$T/rc")" = 0 ] && [ "$(calls)" = 0 ]'
printf 'export POSTHOG_MK_PERSONAL_API_KEY="%s"\n' "$KEY-env" > "$H/env/project-6-os.env"
reset; run -- project-6-os "select 1"
check "P4 the key from env/project-6-os.env" '[ "$(field AUTH)" = "Authorization: Bearer $KEY-env" ]'
rm -f "$H/env/project-6-os.env"
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-5 "select 1"
check "P5 no source [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(posthog lookup unavailable — no PostHog source for project-5)" ] && [ "$(cat "$T/rc")" = 0 ] && [ "$(calls)" = 0 ]'

# ── P6-P7: the canned reports ────────────────────────────────────────────────
F="AND properties.app = 'project-6'"
EXP6="SELECT properties.endpoint AS endpoint, properties.status AS status, count() AS failures FROM events WHERE event = 'api_error' AND timestamp > now() - INTERVAL 24 HOUR $F GROUP BY endpoint, status ORDER BY failures DESC LIMIT 50"
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os --report api-failures
check "P6 api-failures HogQL [$(sentq)]" '[ "$(sentq)" = "$EXP6" ]'
check "P6 rc 0, rows printed" '[ "$(cat "$T/rc")" = 0 ] && [ "$(lines)" = 3 ]'
EXP7="SELECT properties.\$pathname AS route, quantile(0.75)(properties.\$web_vitals_LCP_value) AS p75_lcp_ms, quantile(0.75)(properties.\$web_vitals_CLS_value) AS p75_cls, quantile(0.75)(properties.\$web_vitals_INP_value) AS p75_inp_ms, count() AS samples FROM events WHERE event = '\$web_vitals' AND timestamp > now() - INTERVAL 7 DAY $F GROUP BY route ORDER BY samples DESC LIMIT 50"
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os --report web-vitals
check "P7 web-vitals HogQL [$(sentq)]" '[ "$(sentq)" = "$EXP7" ]'
reset; jq -nc '{columns: ["route"], results: []}' > "$FX/answer.json"
run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os --report web-vitals
check "P7 zero rows [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(posthog: no rows)" ]'

# ── P8: an invalid posthog block ─────────────────────────────────────────────
mkdir -p "$T/src"
jq -nc '{project: "alpha", posthog: {host: "http://posthog.example.com", project_id: "1", key_env: "POSTHOG_ALPHA_KEY", filter: ""}}' > "$T/src/alpha.json"
jq -nc '{project: "beta", posthog: {host: "https://posthog.example.com", project_id: "2", key_env: "POSTHOG_BETA_KEY", filter: "properties.app = '"'"'x'"'"'; drop"}}' > "$T/src/beta.json"
jq -nc '{project: "gamma", sentry: {org: "example-org", project: "gamma", token_env: "SENTRY_GAMMA_TOKEN"}}' > "$T/src/gamma.json"
reset; run SIGNAL_SOURCES_DIR="$T/src" POSTHOG_ALPHA_KEY=alpha-fixture -- alpha "select 1"
check "P8 an http:// host: one notice, no call [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(posthog lookup unavailable — bad signal source row for alpha)" ] && [ "$(calls)" = 0 ] && [ "$(cat "$T/rc")" = 0 ]'
reset; run SIGNAL_SOURCES_DIR="$T/src" POSTHOG_BETA_KEY=beta-fixture -- beta "select 1"
check "P8 a filter with ;: one notice, no call" '[ "$(cat "$T/out")" = "(posthog lookup unavailable — bad signal source row for beta)" ] && [ "$(calls)" = 0 ]'
reset; run SIGNAL_SOURCES_DIR="$T/src" -- gamma "select 1"
check "P8 a row with no posthog block: no source" '[ "$(cat "$T/out")" = "(posthog lookup unavailable — no PostHog source for gamma)" ] && [ "$(calls)" = 0 ]'

# ── P9: knobs ────────────────────────────────────────────────────────────────
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" POSTHOG_REPORT_API_FAILURES_H=48 POSTHOG_LOOKUP_MAX_ROWS=3 -- project-6-os --report api-failures
check "P9 48 h and LIMIT 3 [$(sentq)]" '[[ "$(sentq)" == *"INTERVAL 48 HOUR"*"LIMIT 3" ]]'
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" POSTHOG_REPORT_WEB_VITALS_D=0 -- project-6-os --report web-vitals
check "P9 0 days is out of range: 7 kept [$(sentq)]" '[[ "$(sentq)" == *"INTERVAL 7 DAY"* ]]'
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" POSTHOG_REPORT_API_FAILURE_EVENT="x' OR 1=1 --" -- project-6-os --report api-failures
check "P9 a bad event name: api_error kept" '[[ "$(sentq)" == *"event = '"'"'api_error'"'"'"* ]]'
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" POSTHOG_REPORT_API_FAILURE_EVENT=fetch_failed POSTHOG_LOOKUP_TIMEOUT_S=9 -- project-6-os --report api-failures
check "P9 event knob and timeout knob" '[[ "$(sentq)" == *"event = '"'"'fetch_failed'"'"'"* ]] && [[ " $(field ARGV) " == *" -m 9 "* ]]'
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "select 1"
check "P9 default timeout 25" '[[ " $(field ARGV) " == *" -m 25 "* ]]'

# ── P10: the triage and medic prompts name both reports ──────────────────────
for f in bin/alert-triage.sh bin/alerts-medic.sh; do
  n=$(grep -c 'posthog-lookup.sh <project> --report api-failures' "$DIR/$f" 2>/dev/null); n=${n:-0}
  check "P10 $f names --report api-failures ($n)" '[ "$n" -ge 1 ]'
  check "P10 $f names --report web-vitals" 'grep -q -- "--report web-vitals" "$DIR/$f"'
  check "P10 $f passes the project to sentry-lookup" 'grep -qF "sentry-lookup.sh '"'"'<route or error text>'"'"' <project>" "$DIR/$f"'
done

# ── P11: privacy refusal ─────────────────────────────────────────────────────
for q in "select person.properties.email from events" "SELECT name FROM persons" \
         "select properties.\$ip from events" "select EMAIL from events"; do
  reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "$q"
  check "P11 refused: $q [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(posthog lookup refused: the query reads person fields)" ] && [ "$(calls)" = 0 ] && [ "$(cat "$T/rc")" = 0 ]'
done
for q in "select event, count() from events group by event" "select properties.username_hash from events" \
         "select properties.\$pathname from events"; do
  reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "$q"
  check "P11 allowed: $q" '[ "$(calls)" = 1 ]'
done

# ── P12: the key on no argv and in no output ─────────────────────────────────
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "select 1"
check "P12 not on the curl argv" '! grep -qF "$KEY" <<<"$(field ARGV)"'
check "P12 not in the output" '! grep -qF "$KEY" <<<"$(cat "$T/out" "$T/err")"'
PK="p""hx_fixture$(printf 'k%.0s' $(seq 1 40))"
jq -nc --arg v "leak $PK" '{columns: ["v"], results: [[$v]]}' > "$FX/answer.json"
run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "select 1"
check "P12 a key-shaped cell is masked [$(tail -1 "$T/out")]" '[ "$(tail -1 "$T/out")" = "leak <redacted:posthog-key>" ]'

# ── P13: email masking and the row cap ──────────────────────────────────────
reset; jq -nc '{columns: ["who", "n"], results: [["a.person@example.com", 1], ["line\tone\ntwo", 2], [null, 3], [{"k": 1}, 4], ["x", 5]]}' > "$FX/answer.json"
run POSTHOG_MK_PERSONAL_API_KEY="$KEY" POSTHOG_LOOKUP_MAX_ROWS=3 -- project-6-os "select 1"
check "P13 the email is masked" '[ "$(sed -n 2p "$T/out")" = "$(printf "<redacted:email>\t1")" ] && ! grep -q example.com "$T/out"'
check "P13 tabs and newlines in a cell become spaces" '[ "$(sed -n 3p "$T/out")" = "$(printf "line one two\t2")" ]'
check "P13 3 rows, then the cap line [$(tail -1 "$T/out")]" '[ "$(lines)" = 5 ] && [ "$(tail -1 "$T/out")" = "(posthog: 2 more rows not shown)" ]'

# ── P14: usage and unparseable ──────────────────────────────────────────────
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os
check "P14 no query: rc 2, usage on stderr" '[ "$(cat "$T/rc")" = 2 ] && grep -q usage "$T/err" && [ "$(calls)" = 0 ]'
reset; run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os --report other
check "P14 an unknown report: rc 2" '[ "$(cat "$T/rc")" = 2 ] && [ "$(calls)" = 0 ]'
reset; echo 'not json' > "$FX/answer.json"
run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "select 1"
check "P14 not JSON [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(posthog lookup: unparseable response)" ] && [ "$(cat "$T/rc")" = 0 ]'
reset; echo '{"columns":[]}' > "$FX/answer.json"
run POSTHOG_MK_PERSONAL_API_KEY="$KEY" -- project-6-os "select 1"
check "P14 no results array" '[ "$(cat "$T/out")" = "(posthog lookup: unparseable response)" ]'

# ── network: no host but the fixture's ──────────────────────────────────────
HOSTS=$(sed -n 's#^URL https://\([^/]*\)/.*#\1#p' "$FX/curl.log" 2>/dev/null | sort -u)
check "the fake curl saw only us.posthog.com [$HOSTS]" '[ -z "$HOSTS" ] || [ "$HOSTS" = us.posthog.com ]'

# ── R: registry defaults ────────────────────────────────────────────────────
DEF=$(jq -c '[.libs[0].knobs[] | {(.env): .default}] | add' "$DIR/catalog/lanes.d/_lib.posthog-lookup.json" 2>/dev/null)
check "R posthog-lookup defaults [$DEF]" '[ "$(jq -c "[.POSTHOG_LOOKUP_TIMEOUT_S, .POSTHOG_LOOKUP_MAX_ROWS, .POSTHOG_REPORT_API_FAILURES_H, .POSTHOG_REPORT_WEB_VITALS_D, .POSTHOG_REPORT_API_FAILURE_EVENT]" <<<"$DEF" 2>/dev/null)" = "[25,50,24,7,\"api_error\"]" ]'
check "R signal-env-install lock wait default 30" '[ "$(jq -r ".libs[0].knobs[] | select(.env == \"SIGNAL_ENV_INSTALL_LOCK_WAIT_S\") | .default" "$DIR/catalog/lanes.d/_lib.signal-env-install.json" 2>/dev/null)" = 30 ]'

echo "posthog-lookup: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
