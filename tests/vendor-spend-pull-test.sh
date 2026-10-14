#!/bin/bash
# tests/vendor-spend-pull-test.sh — bin/vendor-spend-pull.sh against a stubbed
# curl, one fixture per vendor shape.
#
# THE HOLE THIS CLOSES (cost fix 5, 2026-09-14). Anthropic spend is instrumented
# to the call. Everything else we pay for — the xAI wallet that runs fleet
# triage, the OpenRouter survival lane, codex, and the Fly pool that IS the
# compute bill — lived in four dashboards nobody opened, while cost.csv carried
# model-priced ESTIMATES for two of them that had never been compared to an
# invoice.
#
# What is proved here, in the order a reader cares about it:
#   1. a vendor that answers with a real figure is recorded as kind=metered, and
#      its CUMULATIVE total is differenced — the first reading is a baseline
#      with an empty usd, not a one-hour spike of everything ever spent;
#   2. a vendor with no billing API records status=no-spend-endpoint and falls
#      back to our own cost rows, clearly labelled kind=computed;
#   3. AN UNMEASURED VENDOR IS NEVER $0. This is the whole point: "we could not
#      read it" and "it cost nothing" look identical once one is spelled 0.00,
#      and it is always the first that hides a bill;
#   4. 401 is auth-failed, a timeout is error, and neither alerts until the
#      THIRD consecutive failure — then exactly once, and again only after a
#      recovery (the alarm that rings every hour is the alarm nobody reads);
#   5. a readable balance under the floor alerts, once a day;
#   6. Fly is computed from machine-seconds x catalog/fly-prices.json, and a
#      stopped machine bills nothing;
#   7. no key value and no key-shaped string from a vendor payload reaches the
#      CSV, the log, the alert or the DB push;
#   8. every kill switch actually kills.
# Run from anywhere: tests/vendor-spend-pull-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_OPENROUTER=https://openrouter.ai ENDPOINT_OPENAI=https://api.openai.com ENDPOINT_FLY_MACHINES=https://api.machines.dev
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
mkdir -p "$T/bin" "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/catalog" "$T/fakebin" "$T/fx"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cp "$DIR/bin/vendor-spend-pull.sh" "$T/bin/"; chmod +x "$T/bin/vendor-spend-pull.sh"
mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/bin/lib/"   # BH-1941: the vendor base URL resolver
cp "$DIR/catalog/fly-prices.json" "$T/catalog/"

# The one real secret-shaped value in this file is invented here and never
# leaves $T. Nothing in this repo or its output is a credential.
OR_KEY="sk-or-v1-FIXTUREKEYNOTREAL0001"
cat > "$T/env/global.env" <<ENVF
OPENROUTER_API_KEY=$OR_KEY
XAI_API_KEY=xai-FIXTUREKEYNOTREAL0002
FIREWORKS_API_KEY=fw_FIXTUREKEYNOTREAL0003
FLY_API_TOKEN=FlyV1FIXTUREKEYNOTREAL0004
FLY_ORG=board-builders
ENVF

# --- the curl stub -----------------------------------------------------------
# Answers from $T/fx/<slug>.{code,body}, logs every URL it was asked for, and
# defaults to 404+empty so a route the script starts calling without a fixture
# is loud rather than quietly "fine".
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; OUT=""; AUTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) AUTH="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    -w|-m|--connect-timeout) shift 2 ;;
    -sS|-s|-S) shift ;;
    *) URL="$1"; shift ;;
  esac
done
printf '%s :: %s\n' "$URL" "$AUTH" >> "$CURL_LOG"
SLUG=$(printf '%s' "$URL" | tr -c 'A-Za-z0-9' '_')
CODE=$(cat "$FX/$SLUG.code" 2>/dev/null || echo 404)
[ -n "$OUT" ] && { cat "$FX/$SLUG.body" 2>/dev/null > "$OUT" || : > "$OUT"; }
printf '%s' "$CODE"
[ "$CODE" = 000 ] && exit 7
exit 0
SH
chmod +x "$T/fakebin/curl"
fx() { # fx <url> <code> <body>
  local slug; slug=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')
  printf '%s' "$2" > "$T/fx/$slug.code"; printf '%s' "$3" > "$T/fx/$slug.body"
}

# --- the alert stub ----------------------------------------------------------
cat > "$T/bin/lane-alert.sh" <<'SH'
#!/bin/bash
shift  # the lane name
echo "$*" >> "$H_ALERTS"
SH
chmod +x "$T/bin/lane-alert.sh"

# --- the jobs-client stub ----------------------------------------------------
# Real jobs-client is fail-open and needs a worker; what this suite has to prove
# is that the PUSH HAPPENS and carries the same fields the CSV does, raw
# included. One line per call, tab separated.
cat > "$T/bin/jobs-client.sh" <<'SH'
metric_vendor_spend() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}" "${11:-}" \
    >> "$PUSH_LOG"
}
SH

export PATH="$T/fakebin:$PATH"
export CURL_LOG="$T/curl.log" FX="$T/fx" H_ALERTS="$T/logs/ALERTS.log" PUSH_LOG="$T/push.log"
run() { HARNESS="$T" "$T/bin/vendor-spend-pull.sh" "$@" >/dev/null 2>&1; }
csvrow() { awk -F, -v v="$1" 'NR>1 && $2==v {r=$0} END{print r}' "$T/logs/vendor-spend.csv" 2>/dev/null; }
field()  { printf '%s' "$1" | cut -d, -f"$2"; }
reset_state() { rm -rf "$T/state/vendor-spend" "$T/logs/vendor-spend.csv" "$T/logs/ALERTS.log" "$T/push.log"; }

CREDITS=https://openrouter.ai/api/v1/credits
KEYS='https://openrouter.ai/api/v1/keys?limit=100'
XPROBE=https://api.x.ai/v1/api-key
FWPROBE=https://api.fireworks.ai/v1/accounts
FLYAPPS='https://api.machines.dev/v1/apps?org_slug=board-builders'

# ═══════════════════════════════════════════════════════════════════════════
# 1. openrouter: metered, and the cumulative is DIFFERENCED
# ═══════════════════════════════════════════════════════════════════════════
fx "$CREDITS" 200 '{"data":{"total_credits":7150,"total_usage":6800.50,"note":"sk-or-v1-LEAKYPAYLOAD9999"}}'
fx "$KEYS" 200 '{"data":[{"name":"box-project-1","label":"sk-or-v1-LEAKYLABEL9999","usage":48.44,"limit":400,"limit_remaining":351.55,"disabled":false}]}'
run --vendor openrouter
ROW=$(csvrow openrouter)
[ "$(field "$ROW" 6)" = metered ] && [ "$(field "$ROW" 7)" = ok ] && ok || bad "openrouter is not metered/ok: $ROW"
# The FIRST reading has no prior cumulative, so it is a baseline with an empty
# usd. Publishing 6800.50 here would report the account's whole lifetime as one
# hour's spend, and the number would look plausible.
[ -z "$(field "$ROW" 5)" ] && ok || bad "the first openrouter reading published usd='$(field "$ROW" 5)' instead of a baseline"
[ "$(field "$ROW" 9)" = 6800.500000 ] && ok || bad "cumulative not recorded: $(field "$ROW" 9)"
[ "$(field "$ROW" 8)" = 349.500000 ] && ok || bad "balance not derived (7150-6800.50): $(field "$ROW" 8)"

fx "$CREDITS" 200 '{"data":{"total_credits":7150,"total_usage":6812.75}}'
run --vendor openrouter
ROW=$(csvrow openrouter)
[ "$(field "$ROW" 5)" = 12.2500 ] && ok || bad "the second reading did not difference (want 12.2500, got $(field "$ROW" 5))"
# The window opens where the last one closed, so no hour is billed twice and
# none is skipped.
PREV=$(awk -F, 'NR>1 && $2=="openrouter"' "$T/logs/vendor-spend.csv" | head -1 | cut -d, -f4)
[ "$(field "$ROW" 3)" = "$PREV" ] && ok || bad "window_start '$(field "$ROW" 3)' does not continue the last window_end '$PREV'"

# ── 7. no secret, from either direction, reaches anything we keep ────────────
grep -rqF "$OR_KEY" "$T/logs" "$T/push.log" 2>/dev/null && bad "the API key reached a log or the DB push" || ok
grep -qF 'LEAKYPAYLOAD9999' "$T/push.log" 2>/dev/null && bad "a key-shaped string in the vendor payload survived the scrub into raw" || ok
grep -q '<redacted>' "$T/push.log" && ok || bad "the scrub never fired on a payload that contained a key-shaped string"
# ...and the push carries the row, raw included.
PLINE=$(grep -c . "$T/push.log"); [ "$PLINE" -ge 2 ] && ok || bad "expected a metric_vendor_spend push per run, got $PLINE"
awk -F'\t' '$1=="openrouter" && $6=="metered" && $7=="ok"' "$T/push.log" | grep -q . && ok || bad "the push did not carry vendor/kind/status"

# ═══════════════════════════════════════════════════════════════════════════
# 2 + 3. xai: no spend endpoint, computed from our own cost rows, never $0
# ═══════════════════════════════════════════════════════════════════════════
reset_state
fx "$XPROBE" 200 '{"redacted_api_key":"xai-...k72l","team_blocked":false}'
NOWTS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
INWIN=$(date -u -d '-10 minutes' '+%Y-%m-%dT%H:%M:%SZ')
OLD=$(date -u -d '-3 days' '+%Y-%m-%dT%H:%M:%SZ')
{ echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd"
  echo "$INWIN,hub,project-3,triage,grok,grok-4,0,10,100,50,0,0,1.25"
  echo "$INWIN,hub,project-4,triage,grok,grok-4,0,10,100,50,0,0,2.75"
  echo "$OLD,hub,project-4,triage,grok,grok-4,0,10,100,50,0,0,999.00"
  echo "$INWIN,hub,project-4,triage,claude,x,0,10,1,1,0,0,500.00"; } > "$T/logs/cost.csv"
run --vendor xai
ROW=$(csvrow xai)
[ "$(field "$ROW" 6)" = computed ] && [ "$(field "$ROW" 7)" = no-spend-endpoint ] && ok \
  || bad "xai should be computed/no-spend-endpoint: $ROW"
[ "$(field "$ROW" 5)" = 4.0000 ] && ok || bad "xai estimate should sum only in-window grok rows (want 4.0000, got $(field "$ROW" 5))"
grep -q 'ESTIMATE' <<<"$ROW" && ok || bad "the xai row does not say its number is an estimate: $ROW"

# 3. THE ONE THAT MATTERS: no cost rows at all is an EMPTY usd, not $0.00.
reset_state
: > "$T/logs/cost.csv"
run --vendor xai
ROW=$(csvrow xai)
[ "$(field "$ROW" 5)" = "0.0000" ] && ok || bad "a real zero from an empty ledger should still be 0.0000, got '$(field "$ROW" 5)'"
# ...and a vendor with NO KEY writes an empty usd with a reason, never a zero.
reset_state
sed -i '/^XAI_API_KEY=/d' "$T/env/global.env"
run --vendor xai
ROW=$(csvrow xai)
[ -z "$(field "$ROW" 5)" ] && ok || bad "a keyless vendor published usd='$(field "$ROW" 5)' instead of nothing"
grep -q 'XAI_API_KEY' <<<"$ROW" && ok || bad "the keyless row does not name the missing env var: $ROW"
echo "XAI_API_KEY=xai-FIXTUREKEYNOTREAL0002" >> "$T/env/global.env"

# codex has no admin key anywhere in this fleet, so it must say so and price nothing.
reset_state
run --vendor codex
ROW=$(csvrow codex)
[ "$(field "$ROW" 7)" = no-spend-endpoint ] && [ -z "$(field "$ROW" 5)" ] && ok \
  || bad "codex should be no-spend-endpoint with no usd: $ROW"
grep -q 'OPENAI_ADMIN_KEY' <<<"$ROW" && ok || bad "the codex row does not name what would arm it: $ROW"

# ═══════════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════════
# 3b. THE TWO WAYS A REAL BILL WENT UNMEASURED (both found by probing prod,
#     2026-09-14, both regressions waiting to happen again)
# ═══════════════════════════════════════════════════════════════════════════
# (a) UNPRICED cost rows are not a zero. cost.csv leaves cost_usd EMPTY for any
# model with no catalog price, and every fireworks row on the hub is one today.
# `float(cell or 0)` turned 7 real calls into a published $0.0000 — a vendor
# reported as free, forever, because $0 is also what "nothing happened" looks
# like and so nobody ever goes back to check it.
reset_state
INWIN=$(date -u -d '-10 minutes' '+%Y-%m-%dT%H:%M:%SZ')
fx "$FWPROBE" 200 '{"accounts":[{"name":"accounts/board"}]}'
{ echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd"
  echo "$INWIN,hub,project-3,triage,fireworks,deepseek-v4-flash,0,10,100,50,0,0,"
  echo "$INWIN,hub,project-4,triage,fireworks,deepseek-v4-flash,0,10,100,50,0,0,"; } > "$T/logs/cost.csv"
run --vendor fireworks
ROW=$(csvrow fireworks)
[ -z "$(field "$ROW" 5)" ] && ok \
  || bad "2 UNPRICED rows published usd='$(field "$ROW" 5)' instead of nothing"
grep -q 'UNPRICED' <<<"$ROW" && ok || bad "the row does not say the rows were unpriced: $ROW"
grep -q 'NOT \$0' <<<"$ROW" && ok || bad "the row does not distinguish itself from a real zero: $ROW"

# (b) A partly priced window is a FLOOR and says so, rather than quietly
# reporting the priced half as the whole bill.
reset_state
{ echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd"
  echo "$INWIN,hub,project-3,triage,fireworks,priced-model,0,10,100,50,0,0,3.50"
  echo "$INWIN,hub,project-4,triage,fireworks,deepseek-v4-flash,0,10,100,50,0,0,"; } > "$T/logs/cost.csv"
run --vendor fireworks
ROW=$(csvrow fireworks)
[ "$(field "$ROW" 5)" = 3.5000 ] && ok || bad "the priced rows did not sum (want 3.5000, got $(field "$ROW" 5))"
grep -q 'FLOOR' <<<"$ROW" && ok || bad "a partly-unpriced window is not flagged as a floor: $ROW"

# (c) THE CREDENTIAL READER MUST NOT SQUEEZE INTERNAL WHITESPACE. A Fly token is
# literally "FlyV1 fm2_..." with a space in the middle. Deleting it yields a 401
# indistinguishable from a revoked key, which is exactly how the fly row read
# auth-failed against a token that was in fact fine (probed against prod:
# identical token, space preserved, HTTP 200 and 20 apps).
reset_state
sed -i '/^FLY_API_TOKEN=/d' "$T/env/global.env"
echo 'FLY_API_TOKEN=FlyV1 fm2_FIXTURETOKENWITHASPACE0005' >> "$T/env/global.env"
fx "$FLYAPPS" 200 '{"total_apps":0,"apps":[]}'
run --vendor fly
grep -qF 'Bearer FlyV1 fm2_FIXTURETOKENWITHASPACE0005' "$T/curl.log" && ok \
  || bad "the space inside the Fly token did not survive env_get into the Authorization header"
# ...and the trimming it IS supposed to do still happens.
reset_state
sed -i '/^FLY_API_TOKEN=/d' "$T/env/global.env"
printf 'FLY_API_TOKEN=  FlyV1 fm2_TRIMME0006  \n' >> "$T/env/global.env"
run --vendor fly
grep -qF 'Bearer FlyV1 fm2_TRIMME0006' "$T/curl.log" && ok \
  || bad "surrounding whitespace was not trimmed off the Fly token"
sed -i '/^FLY_API_TOKEN=/d' "$T/env/global.env"
echo 'FLY_API_TOKEN=FlyV1FIXTUREKEYNOTREAL0004' >> "$T/env/global.env"

# (e) GET /api/v1/credits requires a MANAGEMENT key. After the 2026-09-15
# key split, OPENROUTER_API_KEY is the scoped inference key and OpenRouter
# answers 403 "Only management keys can fetch credits for an account". The
# poller must send OPENROUTER_PROVISIONING_KEY to /credits (probed 2026-09-16
# on the hub: inference key 403, provisioning key 200 with total_usage).
reset_state
OR_PK="sk-or-v1-FIXTUREPROVISIONINGKEY0008"
echo "OPENROUTER_PROVISIONING_KEY=$OR_PK" > "$T/env/openrouter.env"
fx "$CREDITS" 200 '{"data":{"total_credits":7150,"total_usage":6800.50}}'
fx "$KEYS" 200 '{"data":[]}'
: > "$T/curl.log"
run --vendor openrouter
grep -qF "$CREDITS :: Authorization: Bearer $OR_PK" "$T/curl.log" && ok \
  || bad "credits was not fetched with the provisioning key: $(cat "$T/curl.log")"
grep -qF "$CREDITS :: Authorization: Bearer $OR_KEY" "$T/curl.log" && \
  bad "credits was fetched with the inference key when a provisioning key was present" || ok
[ "$(field "$(csvrow openrouter)" 7)" = ok ] && ok || bad "provisioning-key credits poll was not ok: $(csvrow openrouter)"
grep -rqF "$OR_PK" "$T/logs" "$T/push.log" 2>/dev/null && bad "the provisioning key reached a log or the DB push" || ok
rm -f "$T/env/openrouter.env"

# (d) --dry-run PRINTS, it does not write. Both the failure streak and the
# balance-floor marker are SUPPRESSORS: a human dry-running the poller must not
# be able to silence the hourly job's real alert for the rest of the day.
reset_state
fx "$CREDITS" 401 '{"error":"no auth"}'
for _ in 1 2 3 4; do HARNESS="$T" "$T/bin/vendor-spend-pull.sh" --vendor openrouter --dry-run >/dev/null 2>&1; done
[ -s "$T/logs/ALERTS.log" ] && bad "--dry-run alerted on a failure streak" || ok
[ -e "$T/state/vendor-spend/fail-openrouter" ] && bad "--dry-run advanced the failure streak counter" || ok
reset_state
fx "$CREDITS" 200 '{"data":{"total_credits":12,"total_usage":7}}'
HARNESS="$T" "$T/bin/vendor-spend-pull.sh" --vendor openrouter --dry-run >/dev/null 2>&1
[ -s "$T/logs/ALERTS.log" ] && bad "--dry-run fired a balance-floor alert" || ok
ls "$T/state/vendor-spend"/floor-* >/dev/null 2>&1 && bad "--dry-run set the once-a-day floor marker" || ok
# Not even the empty mirror: creating the CSV is a write, and a dry run that
# leaves a file behind is a dry run whose promise a reader stops believing.
[ -e "$T/logs/vendor-spend.csv" ] && bad "--dry-run created the CSV mirror" || ok

# 4. failures: classified, and quiet until the third in a row
# ═══════════════════════════════════════════════════════════════════════════
reset_state
fx "$CREDITS" 401 '{"error":"no auth"}'
run --vendor openrouter
[ "$(field "$(csvrow openrouter)" 7)" = auth-failed ] && ok || bad "401 was not classified auth-failed"
[ -s "$T/logs/ALERTS.log" ] && bad "one failed poll alerted" || ok
run --vendor openrouter
[ -s "$T/logs/ALERTS.log" ] && bad "two failed polls alerted" || ok
run --vendor openrouter
[ "$(grep -c 'VENDOR SPEND' "$T/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "three failures did not alert exactly once"
run --vendor openrouter
[ "$(grep -c 'VENDOR SPEND' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "the fourth failure alerted again (no dedupe)"
# A failure must NOT advance the window, or whatever was spent while the vendor
# was down falls into a window no row ever covers.
fx "$CREDITS" 200 '{"data":{"total_credits":100,"total_usage":50}}'
run --vendor openrouter
[ -z "$(csvrow openrouter | cut -d, -f5)" ] && ok || bad "the recovery row should be a baseline; no good reading preceded it"
# Recovery clears the latch, so a later outage can still be heard.
fx "$CREDITS" 401 '{"error":"no auth"}'
run --vendor openrouter; run --vendor openrouter; run --vendor openrouter
[ "$(grep -c 'VENDOR SPEND' "$T/logs/ALERTS.log")" = 2 ] && ok || bad "a second outage after a recovery did not alert"
# A transport failure is `error`, not auth-failed: a timeout and a revoked key
# are different facts and the fix for each is different.
fx "$CREDITS" 000 ''
reset_state
run --vendor openrouter
[ "$(field "$(csvrow openrouter)" 7)" = error ] && ok || bad "a transport failure was not classified error"

# ═══════════════════════════════════════════════════════════════════════════
# 5. the balance floor
# ═══════════════════════════════════════════════════════════════════════════
reset_state
fx "$CREDITS" 200 '{"data":{"total_credits":7000,"total_usage":6990}}'
run --vendor openrouter
grep -q 'VENDOR BALANCE LOW' "$T/logs/ALERTS.log" && ok || bad "a \$10 balance under the \$20 floor did not alert"
run --vendor openrouter
[ "$(grep -c 'VENDOR BALANCE LOW' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "the balance alert repeats within a day"
# The floor is a KNOB, not a constant: raising it past the balance silences it,
# lowering it below fires it. A threshold nobody can move is a threshold that
# gets ignored instead of tuned.
reset_state
VENDOR_BALANCE_FLOOR_USD=5 HARNESS="$T" "$T/bin/vendor-spend-pull.sh" --vendor openrouter >/dev/null 2>&1
[ -s "$T/logs/ALERTS.log" ] && bad "floor=5 alerted on a \$10 balance" || ok
reset_state
VENDOR_BALANCE_FLOOR_USD=50 HARNESS="$T" "$T/bin/vendor-spend-pull.sh" --vendor openrouter >/dev/null 2>&1
grep -q 'VENDOR BALANCE LOW' "$T/logs/ALERTS.log" && ok || bad "floor=50 did not alert on a \$10 balance"

# ═══════════════════════════════════════════════════════════════════════════
# 6. fly: machine-seconds x the price catalog
# ═══════════════════════════════════════════════════════════════════════════
reset_state
fx "$FLYAPPS" 200 '{"apps":[{"name":"pool-a","volume_count":0},{"name":"builder-b","volume_count":1}]}'
# pool-a: one 8-core performance machine, started, no events -> the whole window.
# builder-b: one machine STOPPED for the whole window -> compute bills nothing,
#            and only its provisioned volume does.
fx "https://api.machines.dev/v1/apps/pool-a/machines" 200 \
  '[{"id":"m1","state":"started","config":{"guest":{"cpu_kind":"performance","cpus":8,"memory_mb":16384}},"events":[]}]'
fx "https://api.machines.dev/v1/apps/builder-b/machines" 200 \
  '[{"id":"m2","state":"stopped","config":{"guest":{"cpu_kind":"shared","cpus":1,"memory_mb":2048}},"events":[]}]'
fx "https://api.machines.dev/v1/apps/builder-b/volumes" 200 '[{"id":"v1","size_gb":40}]'
run --vendor fly
ROW=$(csvrow fly)
[ "$(field "$ROW" 6)" = computed ] && [ "$(field "$ROW" 7)" = ok ] && ok || bad "fly should be computed/ok: $ROW"
# 3600s x (8 cores x $31/mo + 16GB x $5/mo) / 2628000 s-per-month = $0.4493
#      + 40GB x $0.15/mo x 3600 / 2628000                        = $0.0082
USD=$(field "$ROW" 5)
python3 -c "import sys;v=float(sys.argv[1]);sys.exit(0 if abs(v-0.4575)<0.002 else 1)" "$USD" 2>/dev/null \
  && ok || bad "fly priced \$$USD, expected ~\$0.4575 (1h of one 8x performance/16GB machine + a 40GB volume)"
grep -q 'fly-prices.json\|catalog' <<<"$ROW" && ok || bad "the fly row does not name where its prices came from: $ROW"
grep -q 'pool-a' "$T/push.log" && ok || bad "the per-app breakdown did not reach raw"
# A stopped machine must contribute no compute. Same fixtures, volume removed.
reset_state
fx "$FLYAPPS" 200 '{"apps":[{"name":"builder-b","volume_count":0}]}'
run --vendor fly
[ "$(field "$(csvrow fly)" 5)" = 0.0 ] && ok || bad "a stopped machine billed \$$(field "$(csvrow fly)" 5)"
# An unreachable Fly API is an error row, not a silent zero.
reset_state
fx "$FLYAPPS" 403 '{"error":"unauthorized"}'
run --vendor fly
ROW=$(csvrow fly)
[ "$(field "$ROW" 7)" = auth-failed ] && [ -z "$(field "$ROW" 5)" ] && ok \
  || bad "a 403 from Fly should be auth-failed with no usd: $ROW"

# fireworks answers its probe and still has nothing to bill from
reset_state
fx "$FWPROBE" 200 '{"accounts":[{"name":"accounts/x"}]}'
: > "$T/logs/cost.csv"
run --vendor fireworks
[ "$(field "$(csvrow fireworks)" 7)" = no-spend-endpoint ] && ok || bad "fireworks should be no-spend-endpoint"

# ═══════════════════════════════════════════════════════════════════════════
# 8. every kill switch kills
# ═══════════════════════════════════════════════════════════════════════════
reset_state
fx "$CREDITS" 200 '{"data":{"total_credits":7150,"total_usage":1}}'
touch "$T/flags/vendor-spend-off"
run --vendor openrouter
[ -f "$T/logs/vendor-spend.csv" ] && bad "flags/vendor-spend-off did not stop the run" || ok
rm -f "$T/flags/vendor-spend-off"

reset_state
echo 'VENDOR_SPEND=0' >> "$T/env/global.env"
run --vendor openrouter
[ -f "$T/logs/vendor-spend.csv" ] && bad "VENDOR_SPEND=0 did not stop the run" || ok
sed -i '/^VENDOR_SPEND=0/d' "$T/env/global.env"

reset_state
echo "VENDOR_SKIP=openrouter,fly" >> "$T/env/global.env"
run
[ -n "$(csvrow openrouter)" ] && bad "VENDOR_SKIP did not skip openrouter" || ok
[ -n "$(csvrow fly)" ] && bad "VENDOR_SKIP did not skip fly" || ok
[ -n "$(csvrow codex)" ] && ok || bad "VENDOR_SKIP skipped a vendor it was not given"
sed -i '/^VENDOR_SKIP=/d' "$T/env/global.env"

# --dry-run writes nothing anywhere
reset_state
OUT=$(HARNESS="$T" "$T/bin/vendor-spend-pull.sh" --vendor openrouter --dry-run 2>/dev/null)
grep -q '^[0-9-]*T.*,openrouter,' <<<"$OUT" && ok || bad "--dry-run printed no row: $OUT"
[ -s "$T/push.log" ] && bad "--dry-run pushed to the DB" || ok
grep -q ',openrouter,' "$T/logs/vendor-spend.csv" 2>/dev/null && bad "--dry-run appended to the CSV" || ok

# ═══════════════════════════════════════════════════════════════════════════
# 9. the wiring around the script
# ═══════════════════════════════════════════════════════════════════════════
grep -q 'vendor-spend-pull.sh' "$(rendered_cron hub)" && ok || bad "no hub cron line runs the puller"
# BH-1194: the verb lives in bin/lib/jobs/cost.sh behind the shim; same assertion.
grep -rq 'metric_vendor_spend()' "$DIR/bin/jobs-client.sh" "$DIR/bin/lib/jobs" && ok || bad "jobs-client has no metric_vendor_spend"
grep -q 'CREATE TABLE IF NOT EXISTS vendor_spend' "$DIR/worker/jobs/schema.sql" && ok \
  || bad "schema.sql has no vendor_spend table"
# The route moved to worker/jobs/src/routes/cost.js in BH-1195; the tree is what
# the question is about, not the file it happened to live in.
grep -rq '/api/metrics/vendor-spend' "$DIR/worker/jobs/src" && ok || bad "the worker has no vendor-spend route"
# Every knob the script reads is documented where an operator will look for it.
for K in VENDOR_SPEND VENDOR_SKIP VENDOR_BALANCE_FLOOR_USD VENDOR_SPEND_FAIL_STREAK \
         VENDOR_WINDOW_MAX_SECS VENDOR_WINDOW_DEFAULT_SECS VENDOR_HTTP_TIMEOUT flags/vendor-spend-off; do
  grep -q -- "$K" "$DIR/COST.md" && ok || bad "$K is not documented in COST.md"
done
# The price table is data, not a constant buried in code (DB-driven assumptions).
python3 -c "import json;d=json.load(open('$DIR/catalog/fly-prices.json'));assert d['cpu_usd_per_core_month']['performance']>0;assert d['seconds_per_month']>0" \
  2>/dev/null && ok || bad "catalog/fly-prices.json is missing or malformed"

echo "vendor-spend-pull: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
