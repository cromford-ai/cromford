#!/bin/bash
# tests/meter-skip.bh-9719-test.sh — BH-9719 (C2 of BH-9676): the subscription
# meters skip a project that pays for claude with its own API key, and say so
# once a day in their log (bin/lib/meter-skip.sh).
#
#   M1  meter_skip_api_key: row api-key                        -> skip
#   M2  row api-key, env also holds an OAuth token             -> skip
#   M3  no row                                                 -> meter
#   M4  row oauth                                              -> meter
#   M5  junk row API-KEY / apikey; M5b project a/b             -> meter
#   M6  no settings cache                                      -> meter
#   M7  meter_skip_log_once: one line a day, a new day adds one, a bad key
#       writes nothing
#   A1  account-capacity.sh claude p-key -> "unlimited (p-key pays ...", rc 0
#   A2  ... and reads no quota (stub quota-status.sh marker absent)
#   A3  oauth project, no project, a bad name, grok, codex: main's answers
#   A4  two runs on one day -> one log line; A5 a new day -> two
#   A6  concurrency-apply.sh --dry-run --json: pool cap 6, 1 account: the
#       api-key project proposes 6, the oauth project proposes 4
#   A6b an unlimited pool: the api-key project proposes nothing and says why
#   E1  extra-usage-track.sh on a fallback box whose projects are all api-key:
#       no CSV row, no oauth-refresh, no alert, one skip line; E1b a second run
#       adds no second line
#   E2  one project oauth; E3 no project on the box; E4 EXTRA_USAGE_LOGINS set;
#       E5 a catalog login for the box; E6 a junk row: each polls as before
# 0 network calls: JOBS_URL is empty, no credential exists, and the usage URL
# points at a closed local port.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
cache() { mkdir -p "$1/state"; jq -n --argjson fa "$(date -u +%s)" --argjson v "$2" '{fetched_at:$fa,values:$v,seeded:{}}' > "$1/state/settings-cache.json"; }
TOK="sk-ant-oat""01-bh9719-meter-fixture"

# --- M: the lib ----------------------------------------------------------------
M="$T/m"; mkdir -p "$M"
ms() { # ms <case> <want-rc> <project> [VAR=val ...]
  local c="$1" want="$2" p="$3"; shift 3
  env -u CLAUDE_CODE_OAUTH_TOKEN HARNESS="$M" JOBS_URL= "$@" bash -c '. "$1" || exit 99; meter_skip_api_key "$2"' _ "$DIR/bin/lib/meter-skip.sh" "$p" 2>/dev/null
  local rc=$?
  [ "$rc" = "$want" ] && ok || bad "$c: meter_skip_api_key $p rc=$rc (want $want)"
}
cache "$M" '{"claude_auth.p-key":"api-key","claude_auth.p-oauth":"oauth","claude_auth.p-up":"API-KEY","claude_auth.p-nodash":"apikey"}'
ms M1  0 p-key
ms M2  0 p-key CLAUDE_CODE_OAUTH_TOKEN="$TOK"
ms M3  1 p-none
ms M4  1 p-oauth
ms M5  1 p-up
ms M5a 1 p-nodash
ms M5b 1 a/b
ms M5c 1 ""
rm -f "$M/state/settings-cache.json"
ms M6  1 p-key

lo() { HARNESS="$M" METER_SKIP_DAY="$1" bash -c '. "$1" || exit 99; meter_skip_log_once "$2" "$3" "$4" "$5"' _ "$DIR/bin/lib/meter-skip.sh" "${@:2}"; }
lo 20261115 t1 p-key "$M/logs/t.log" "line one"
lo 20261115 t1 p-key "$M/logs/t.log" "line one"
[ "$(grep -c 'line one' "$M/logs/t.log" 2>/dev/null)" = 1 ] && ok || bad "M7a two calls on one day wrote $(grep -c . "$M/logs/t.log" 2>/dev/null) lines (want 1)"
lo 20261116 t1 p-key "$M/logs/t.log" "line one"
[ "$(grep -c 'line one' "$M/logs/t.log" 2>/dev/null)" = 2 ] && ok || bad "M7b a new day must add a line"
lo 20261116 t1 p-other "$M/logs/t.log" "line two"
[ "$(grep -c 'line two' "$M/logs/t.log" 2>/dev/null)" = 1 ] && ok || bad "M7c a second key is its own line"
rc=0; lo 20261116 t1 "../x" "$M/logs/t.log" "line bad" || rc=$?
[ "$rc" = 1 ] && ! grep -q 'line bad' "$M/logs/t.log" && [ ! -e "$M/state/x.day" ] && ok || bad "M7d a bad key must write nothing, rc 1 (rc=$rc)"
[ "$(cat "$M/state/meter-skip/t1-p-key.day" 2>/dev/null)" = 20261116 ] && ok || bad "M7e state file holds the day"

# --- A: account-capacity --------------------------------------------------------
A="$T/a"; mkdir -p "$A/bin" "$A/logs" "$A/fly" "$A/state/quota"
scratch_install_closure bin/account-capacity.sh "$A" >/dev/null || bad "A closure copy"
scratch_install_closure bin/concurrency-apply.sh "$A" >/dev/null || bad "A6 closure copy"
# A quota dir and a quota-status stub that leaves a marker: a skipped project
# must never reach it.
cat > "$A/bin/quota-status.sh" <<'EOF'
#!/bin/bash
echo read >> "$QUOTA_MARK"
echo '[{"account":"default","vendor":"claude","enabled":true,"status":"ok","cooldown_until":null,"five_hour":{"pct":10}}]'
EOF
chmod +x "$A/bin/quota-status.sh"
cache "$A" '{"claude_auth.p-key":"api-key","claude_auth.p-oauth":"oauth"}'
ac() { env -u CLAUDE_CODE_OAUTH_TOKEN HARNESS="$A" JOBS_URL= QUOTA_MARK="$A/quota.mark" METER_SKIP_DAY="${DAY:-20261115}" bash "${SCRIPT:-$A/bin/account-capacity.sh}" "$@" 2>/dev/null; }
OUT=$(ac claude p-key); RC=$?
case "$OUT" in "unlimited (p-key pays for claude with its own API key"*) [ "$RC" = 0 ] && ok || bad "A1 rc=$RC" ;; *) bad "A1 got '$OUT'" ;; esac
[ ! -e "$A/quota.mark" ] && ok || bad "A2 a skipped project read the quota"
[ "$(grep -c 'account-capacity: skipped p-key' "$A/logs/account-capacity.log" 2>/dev/null)" = 1 ] && ok || bad "A4a first run must log one line"
ac claude p-key >/dev/null
[ "$(grep -c 'account-capacity: skipped p-key' "$A/logs/account-capacity.log" 2>/dev/null)" = 1 ] && ok || bad "A4 two runs on one day must log one line"
DAY=20261116 ac claude p-key >/dev/null
[ "$(grep -c 'account-capacity: skipped p-key' "$A/logs/account-capacity.log" 2>/dev/null)" = 2 ] && ok || bad "A5 a new day must log a second line"
# A3: with no skip the answer is the count main prints for this tree: one
# polled account with headroom, the documented default of 4 per account.
WANT_CLAUDE="4 (1 polled claude account(s) with headroom x 4 heavy session(s) each, per the docs/LESSONS.md#6 default)"
for args in "claude p-oauth" "claude" "claude p-none" "claude a/b"; do
  # shellcheck disable=SC2086 # the args split on purpose
  NEW=$(ac $args)
  [ "$NEW" = "$WANT_CLAUDE" ] && ok || bad "A3 '$args': '$NEW' (want '$WANT_CLAUDE')"
done
NEW=$(ac grok p-key)
[ "$NEW" = "unlimited (grok is billed per token with no session ceiling — its limit is a spend cap, not concurrency)" ] && ok || bad "A3 grok p-key: '$NEW'"
NEW=$(ac codex p-key)
case "$NEW" in "unlimited"*|*"p-key"*) bad "A3 codex p-key must not skip: '$NEW'" ;; *) ok ;; esac
grep -q 'skipped p-oauth' "$A/logs/account-capacity.log" 2>/dev/null && bad "A3 an oauth project must not log a skip" || ok

# A6: concurrency-apply with a stub plan: two pool projects, pool cap 6.
cat > "$A/bin/concurrency-plan.sh" <<'EOF'
#!/bin/bash
echo '[{"project":"p-key","route":"pool","db_rule":"2","pool_cap":"6"},{"project":"p-oauth","route":"pool","db_rule":"2","pool_cap":"6"}]'
EOF
chmod +x "$A/bin/concurrency-plan.sh"
scratch_rm "$A/state/quota"   # no quota: the implicit default account, 1 x 4
J=$(env -u CLAUDE_CODE_OAUTH_TOKEN HARNESS="$A" JOBS_URL= METER_SKIP_DAY=20261115 bash "$A/bin/concurrency-apply.sh" --dry-run --json 2>/dev/null)
[ "$(jq -r '.[]|select(.project=="p-key")|.proposed' <<<"$J" 2>/dev/null)" = 6 ] && ok || bad "A6 api-key project must propose the pool cap 6: $J"
[ "$(jq -r '.[]|select(.project=="p-oauth")|.proposed' <<<"$J" 2>/dev/null)" = 4 ] && ok || bad "A6 oauth project must propose the account count 4: $J"
grep -q 'no account ceiling — p-key pays for claude with its own API key' <<<"$(jq -r '.[]|select(.project=="p-key")|.why' <<<"$J" 2>/dev/null)" && ok || bad "A6 api-key row must say why: $J"
grep -q 'no account ceiling' <<<"$(jq -r '.[]|select(.project=="p-oauth")|.why' <<<"$J" 2>/dev/null)" && bad "A6 oauth row must keep main's why: $J" || ok
# A6b: an unlimited (autoscale) pool and an api-key project: no number to
# propose, and the reason says the account half is absent, not unknown.
cat > "$A/bin/concurrency-plan.sh" <<'EOF'
#!/bin/bash
echo '[{"project":"p-key","route":"pool","db_rule":"2","pool_cap":"unlimited"},{"project":"p-oauth","route":"pool","db_rule":"2","pool_cap":"unlimited"}]'
EOF
J=$(env -u CLAUDE_CODE_OAUTH_TOKEN HARNESS="$A" JOBS_URL= METER_SKIP_DAY=20261115 bash "$A/bin/concurrency-apply.sh" --dry-run --json 2>/dev/null)
[ "$(jq -r '.[]|select(.project=="p-key")|.proposed' <<<"$J" 2>/dev/null)" = null ] && ok || bad "A6b api-key project on an unlimited pool must propose nothing: $J"
grep -q 'p-key has no account ceiling' <<<"$(jq -r '.[]|select(.project=="p-key")|.why' <<<"$J" 2>/dev/null)" && ok || bad "A6b why: $J"
[ "$(jq -r '.[]|select(.project=="p-oauth")|.proposed' <<<"$J" 2>/dev/null)" = 4 ] && ok || bad "A6b oauth project on an unlimited pool proposes the account count: $J"

# --- E: extra-usage-track --------------------------------------------------------
# One fresh tree per case: stubs for the poll's side effects, fleet-conf and
# the box name. The settings cache gives each case its own claude_auth rows.
etree() { # etree <dir> <projects-on-box> <settings-json>
  local E="$1"
  mkdir -p "$E/bin" "$E/env" "$E/logs" "$E/state" "$E/flags" "$E/catalog" "$E/cfg"
  cat > "$E/bin/oauth-refresh.sh" <<'EOF'
#!/bin/bash
echo "$1" >> "$HARNESS/refresh.mark"
EOF
  printf '#!/bin/bash\necho box1\n' > "$E/bin/box-name.sh"
  printf '#!/bin/bash\n[ "$1 $2" = "--projects-on-box box1" ] && printf "%%s\\n" %s\nexit 0\n' "$2" > "$E/bin/fleet-conf.sh"
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/alert.mark"\n' > "$E/bin/lane-alert.sh"
  chmod +x "$E/bin/"*.sh
  scratch_install_closure bin/extra-usage-track.sh "$E" >/dev/null || bad "E closure copy"
  cache "$E" "$3"
}
eu() { # eu <dir> [VAR=val ...]
  local E="$1"; shift
  env -u CLAUDE_CODE_OAUTH_TOKEN -u EXTRA_USAGE_LOGINS -u CLAUDE_CONFIG_DIR HARNESS="$E" HOME="$E" JOBS_URL= HARNESS_SECRET= \
      CLAUDE_CONFIG_DIR="$E/cfg" COST_ACCOUNTS_FILE="$E/catalog/cost-accounts.json" OAUTH_USAGE_URL=http://127.0.0.1:9/ \
      LANE_GATE_DISABLE=1 METER_SKIP_DAY=20261115 "$@" bash "$E/bin/extra-usage-track.sh" box1 >/dev/null 2>&1
}
E="$T/e1"; etree "$E" '"p1" "p2"' '{"claude_auth.p1":"api-key","claude_auth.p2":"api-key"}'
eu "$E"; R=$?
[ "$R" = 0 ] && ok || bad "E1 rc=$R"
[ ! -e "$E/logs/extra-usage.csv" ] && ok || bad "E1 a CSV row was written: $(cat "$E/logs/extra-usage.csv")"
[ ! -e "$E/refresh.mark" ] && ok || bad "E1 oauth-refresh ran"
[ ! -e "$E/alert.mark" ] && ! grep -q . "$E/logs/ALERTS.log" 2>/dev/null && ok || bad "E1 an alert fired"
[ "$(grep -c 'extra-usage-track\[box1\]: skipped: every project on this box (p1 p2)' "$E/logs/agent-rules.log" 2>/dev/null)" = 1 ] && ok \
  || bad "E1 skip line: $(grep skipped "$E/logs/agent-rules.log" 2>/dev/null)"
eu "$E"
[ "$(grep -c 'skipped: every project' "$E/logs/agent-rules.log" 2>/dev/null)" = 1 ] && ok || bad "E1b a second run on one day must not log again"
[ ! -e "$E/logs/extra-usage.csv" ] && [ ! -e "$E/refresh.mark" ] && ok || bad "E1b the second run polled"

polls() { # polls <case> <dir>
  [ -e "$2/refresh.mark" ] && [ -e "$2/logs/extra-usage.csv" ] && ok || bad "$1 must poll as before (refresh.mark/CSV missing)"
  grep -q 'skipped: every project' "$2/logs/agent-rules.log" 2>/dev/null && bad "$1 logged a skip" || ok
}
E="$T/e2"; etree "$E" '"p1" "p2"' '{"claude_auth.p1":"api-key"}'; eu "$E"; polls E2 "$E"
E="$T/e3"; etree "$E" '' '{"claude_auth.p1":"api-key"}'; eu "$E"; polls E3 "$E"
E="$T/e4"; etree "$E" '"p1"' '{"claude_auth.p1":"api-key"}'; eu "$E" EXTRA_USAGE_LOGINS="box1=$E/cfg"; polls E4 "$E"
E="$T/e5"; etree "$E" '"p1"' '{"claude_auth.p1":"api-key"}'
jq -n --arg d "$E/cfg" '{accounts:{acct1:{login:{box:"box1",config_dir:$d}}}}' > "$E/catalog/cost-accounts.json"
eu "$E"; polls E5 "$E"
E="$T/e6"; etree "$E" '"p1" "p2"' '{"claude_auth.p1":"api-key","claude_auth.p2":"API-KEY"}'; eu "$E"; polls E6 "$E"

echo "meter-skip.bh-9719: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
