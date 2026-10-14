#!/bin/bash
# tests/caps-seed-rows.bh-4155-test.sh — BH-4155 (BH-4141.3, slice C0): the two
# cap catalogs, catalog/cost-caps.conf and catalog/lane-caps.conf, are seeded as
# `registry-seed` settings rows by worker/jobs/schema.sql, and both readers read
# those rows ABOVE the committed file and BELOW a box-local flags file and an
# operator row.
#
#   S1  parity: the registry-seed cap statements in worker/jobs/schema.sql are
#       exactly the rows bin/cost-caps-seed.sh --dry-run derives from the files
#   S2  conf_rows_seeded (bin/lib/conf-row.sh): seeded rows only, never values;
#       LANE_GATE_DISABLE=1; a tab value dropped and logged; a stale cache with
#       no jobs client still answers
#   S3  bin/lib/cost-budget.sh layering: seed over catalog, per line; operator
#       and flags over seed; built-in defaults; refused seed rows; fixture path
#   S4  bin/lib/lane-caps.sh layering, the same shape
#   S5  the real `# >>> cost budget` block of bin/pipeline-health.sh, two ticks:
#       one `cost budget:` log line per tick, and an operator row moving the
#       brake decision with no file change
#   S6  every seed statement is INSERT OR IGNORE (a re-apply moves no row)
#   S7  bin/cost-caps-seed-sync.sh, which bin/harness-sync.sh runs on the hub:
#       a reviewed catalog edit moves the registry-seed row, so the running cap
#       follows the file (the INSERT OR IGNORE seed alone never would); an
#       unchanged catalog sends nothing; a failed seed stamps nothing, alerts
#       once per catalog content and retries
#
# Run from anywhere: tests/caps-seed-rows.bh-4155-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/rendered.sh
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null && command -v awk >/dev/null || { echo "jq/awk missing — skipping"; exit 0; }

SCHEMA="$DIR/worker/jobs/schema.sql"
NOW=$(date +%s)

# ── S1 / S6: the shipped seed statements ────────────────────────────────────
# Every `;`-terminated statement of schema.sql, one per line, comments cut.
stmts() {
  sed 's/--.*$//' "$SCHEMA" | tr '\n' ' ' | awk 'BEGIN{ RS=";" } { gsub(/^ +| +$/, ""); gsub(/ +/, " "); if ($0 != "") print }'
}
CAPST=$(stmts | grep -E "VALUES \('conf\.(cost|lane)-caps\." | grep -F "'registry-seed'")
NCAP=$(printf '%s\n' "$CAPST" | grep -c .)
[ "$NCAP" -ge 16 ] && ok || bad "S1 worker/jobs/schema.sql must seed >= 16 registry-seed cap rows, found $NCAP"
SCHEMA_ROWS=$(printf '%s\n' "$CAPST" | sed -n "s/.*VALUES ('\([^']*\)','\([^']*\)'.*/\1\t\2/p" | LC_ALL=C sort)
DRY_ROWS=$(HARNESS="$DIR" "$DIR/bin/cost-caps-seed.sh" --dry-run | jq -r '.rows[] | "\(.key)\t\(.value)"' | LC_ALL=C sort)
[ -n "$DRY_ROWS" ] && ok || bad "S1 bin/cost-caps-seed.sh --dry-run printed no rows"
eq "S1 schema.sql seed rows equal the rows cost-caps-seed.sh derives from the files (a catalog edit needs the schema.sql line too; that line only seeds a D1 with no row, and an EXISTING row follows the file through bin/cost-caps-seed-sync.sh on the hub's next deploy, S7)" "$SCHEMA_ROWS" "$DRY_ROWS"
eq "S6 every cap seed is INSERT OR IGNORE INTO settings" \
  "$(printf '%s\n' "$CAPST" | grep -c '^INSERT OR IGNORE INTO settings ')" "$NCAP"
eq "S6 one row per statement" "$(printf '%s\n' "$CAPST" | grep -c "'registry-seed'.*'registry-seed'")" "0"

# ── the lib tree: the libs' closure, so the sibling ../../catalog is $T/x/catalog (absent) ──
X="$T/x/bin"; H="$T/h"
mkdir -p "$H/state" "$H/logs" "$H/flags" "$H/catalog"
for s in bin/lib/cost-budget.sh bin/lib/lane-caps.sh; do
  scratch_install_closure "$s" "$T/x" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done

# cache <values-json> <seeded-json> [fetched_at] — the shape _lg_settings_refresh writes.
cache() {
  jq -n --argjson v "$1" --argjson s "$2" --argjson t "${3:-$NOW}" '{fetched_at: $t, values: $v, seeded: $s}' \
    > "$H/state/settings-cache.json"
}
reset() {
  rm -f "$H/state/settings-cache.json" "$H/logs/"* "$H/flags/"* "$H/catalog/"*
  scratch_rm "$H/state/lane-gate"
}
XENV=()
# lib <snippet> — a cold shell, HARNESS=$H, the copied libs.
lib() {
  env HARNESS="$H" LANE_GATE_NOW="$NOW" "${XENV[@]}" \
    bash -c 'set -uo pipefail; X=$1; shift; . "$X/lib/conf-row.sh" || exit 9; . "$X/lib/cost-budget.sh" || exit 9; . "$X/lib/lane-caps.sh" || exit 9; eval "$1"' \
    _ "$X" "$1" 2>/dev/null
}

# ── S2 conf_rows_seeded ─────────────────────────────────────────────────────
reset; cache '{"conf.cost-caps.budget.beta":"30 3","conf.scheduler.x":"1"}' \
             '{"conf.cost-caps.budget.acme":"20 3","conf.scheduler.overlap_threshold":"4"}'
eq "S2a seeded rows only, prefix stripped" "$(lib 'conf_rows_seeded cost-caps')" "$(printf 'budget.acme\t20 3')"
eq "S2a conf_rows still ignores seeded rows" "$(lib 'conf_rows cost-caps')" "$(printf 'budget.beta\t30 3')"
XENV=(LANE_GATE_DISABLE=1)
eq "S2b LANE_GATE_DISABLE=1 prints nothing" "$(lib 'conf_rows_seeded cost-caps; echo "rc=$?"')" "rc=0"
XENV=()
eq "S2b no harness root prints nothing, rc 0" \
  "$(env -u HARNESS -u H bash -c '. "$1/lib/conf-row.sh"; conf_rows_seeded cost-caps; echo "rc=$?"' _ "$X" 2>/dev/null)" "rc=0"
reset; cache '{}' "$(jq -n '{"conf.cost-caps.budget.acme":"20\t3","conf.cost-caps.budget.beta":"40 3"}')"
eq "S2c a tab value is dropped" "$(lib 'conf_rows_seeded cost-caps')" "$(printf 'budget.beta\t40 3')"
grep -q 'conf.cost-caps.budget.acme holds a newline or tab' "$H/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "S2c the dropped row is named in logs/lane-gate.log: $(cat "$H/logs/lane-gate.log" 2>/dev/null)"
reset; cache '{}' '{"conf.cost-caps.budget.acme":"20 3"}' $((NOW - 2*86400))
eq "S2d a 2-day-old cache with no jobs client still answers" "$(lib 'conf_rows_seeded cost-caps')" "$(printf 'budget.acme\t20 3')"

# ── S3 cost-budget layering ─────────────────────────────────────────────────
CAT="$H/catalog/cost-caps.conf"
reset; printf 'budget acme 100 3\nbudget beta 50 4\n' > "$CAT"; cache '{}' '{"conf.cost-caps.budget.acme":"20 3"}'
eq "S3a the seed row beats the catalog line" "$(lib 'cost_budget_for acme')" "20 3"
eq "S3a source" "$(lib 'cost_budget_source')" "$CAT + settings seed conf.cost-caps.*"
eq "S3b the seed beats only its own line" "$(lib 'cost_budget_for beta')" "50 4"
reset; printf 'budget acme 100 3\n' > "$CAT"
cache '{"conf.cost-caps.budget.acme":"30 3"}' '{"conf.cost-caps.budget.acme":"20 3"}'
eq "S3c an operator row beats the seed" "$(lib 'cost_budget_for acme')" "30 3"
eq "S3c source" "$(lib 'cost_budget_source')" "$CAT + settings seed conf.cost-caps.* + settings conf.cost-caps.*"
reset; printf 'budget acme 100 3\n' > "$CAT"; printf 'budget acme 40 3\n' > "$H/flags/cost-caps.conf"
cache '{}' '{"conf.cost-caps.budget.acme":"20 3"}'
eq "S3d flags/cost-caps.conf beats the seed" "$(lib 'cost_budget_for acme')" "40 3"
eq "S3d source" "$(lib 'cost_budget_source')" "settings seed conf.cost-caps.* + $H/flags/cost-caps.conf"
cache '{"conf.cost-caps.budget.acme":"30 3"}' '{"conf.cost-caps.budget.acme":"20 3"}'
eq "S3d and loses to the operator row" "$(lib 'cost_budget_for acme')" "30 3"
reset
eq "S3e no file, no rows: built-in" "$(lib 'echo "$(cost_budget_for acme)|$(cost_budget_ceiling)|$(cost_budget_source)"')" "100 5|4000|built-in defaults"
reset; printf 'budget acme 100 3\nceiling 900\ndefault 70 4\n' > "$CAT"
cache '{}' '{"conf.cost-caps.budget.acme":"abc","conf.cost-caps.ceiling":"0","conf.cost-caps.default":"100 5 x"}'
eq "S3f refused seeds bind nothing" "$(lib 'echo "$(cost_budget_for acme)|$(cost_budget_ceiling)|$(cost_budget_for zz)"')" "100 3|900|70 4"
eq "S3f refused seeds are named" "$(lib 'cost_budget_legacy_rows')" "seed:budget.acme seed:ceiling seed:default"
reset; printf 'budget acme 100 3\n' > "$CAT"
cache '{"conf.cost-caps.budget.acme":"30 3"}' '{"conf.cost-caps.budget.acme":"20 3"}'
XENV=(COST_CAPS_CONF="$CAT")
eq "S3g COST_CAPS_CONF: no row of either kind applies" "$(lib 'echo "$(cost_budget_for acme)|$(cost_budget_source)"')" "100 3|$CAT"
XENV=()
reset; printf 'budget acme 100 3\n' > "$CAT"; cache '{}' '{"conf.cost-caps.budget.acme.otherbox":"20 3"}'
eq "S3h another box's seed key is dropped" "$(lib 'cost_budget_for acme')" "100 3"
XENV=(LANE_GATE_DISABLE=1); cache '{}' '{"conf.cost-caps.budget.acme":"20 3"}'
eq "S3i LANE_GATE_DISABLE=1: no seed row applies" "$(lib 'cost_budget_for acme')" "100 3"
XENV=()

# ── S4 lane-caps layering ───────────────────────────────────────────────────
reset; cache '{}' '{"conf.lane-caps.lane.responder":"150 60000"}'
eq "S4a a seed row binds with no catalog" "$(lib 'echo "$(lane_cap_usd responder) $(lane_cap_bytes responder)"')" "150 60000"
eq "S4a source" "$(lib 'lane_caps_source')" "settings seed conf.lane-caps.*"
cache '{"conf.lane-caps.lane.responder":"20"}' '{"conf.lane-caps.lane.responder":"150 60000"}'
eq "S4b an operator row beats it" "$(lib 'lane_cap_usd responder')" "20"
printf 'lane responder 99 1000\n' > "$H/catalog/lane-caps.conf"; cache '{}' '{"conf.lane-caps.lane.responder":"150 60000"}'
eq "S4b the seed beats the catalog line" "$(lib 'lane_cap_usd responder')" "150"
reset; cache '{}' '{"conf.lane-caps.noise.default":"7"}'
eq "S4c seeded noise default" "$(lib 'lane_noise_cap some-lane')" "7"
reset
eq "S4d no file, no rows: built-in" "$(lib 'echo "$(lane_cap_usd x)|$(lane_caps_source)"')" "50|built-in defaults"
reset; printf 'lane medic 90 40000\n' > "$H/catalog/lane-caps.conf"; cache '{}' '{"conf.lane-caps.lane.medic":"banana"}'
eq "S4e a refused seed binds nothing" "$(lib 'lane_cap_usd medic')" "90"
eq "S4e and is named" "$(lib 'lane_caps_legacy_rows')" "seed:lane.medic"

# ── S5 the real cost budget block, two ticks ────────────────────────────────
REG=$(rendered_registry)
C="$T/c"
mkdir -p "$C/bin" "$C/logs" "$C/state/cost" "$C/flags" "$C/stub" "$C/catalog"
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$DIR/bin/pipeline-health.sh" > "$C/blk.sh"
[ -s "$C/blk.sh" ] && ok || bad "S5 could not extract the cost budget block of bin/pipeline-health.sh"
# The lib's closure in its own root: the sibling ../../catalog ($T/cr/catalog) stays absent.
scratch_install_closure bin/lib/cost-budget.sh "$T/cr" >/dev/null || { echo "closure install of cost-budget.sh failed"; exit 1; }
printf 'budget acme 100 3\n' > "$C/catalog/cost-caps.conf"
CATSUM=$(cksum < "$C/catalog/cost-caps.conf")
printf 'acme Acme/acme - - 1 box-a 192.0.2.1\n' > "$C/fleet.conf"
printf '#!/bin/bash\nexit 1\n' > "$C/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 0\n' > "$C/stub/ssh"
chmod +x "$C/bin/fleet-conf.sh" "$C/stub/ssh"
cat > "$C/state/cost/summary.json" <<'JSON'
{ "projects": { "acme": {"delivery_cost_24h": 600, "merged_prs_24h": 10, "cost_7d": 600, "product_7d": 0,
                         "merged_prs_7d": 40, "merged_prs_status": "ok", "stages_24h": {"execute": 600}} } }
JSON
printf '{ "per_token": { "known": {"prompt": 0.001, "completion": 0.002, "cache_read": 0.0001, "cache_write": 0.0005} } }\n' > "$C/prices.json"
printf '%s\n' "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note" > "$C/logs/cost.csv"
ccache() {
  jq -n --argjson v "$1" --argjson s "$2" --argjson t "$NOW" '{fetched_at: $t, values: $v, seeded: $s}' \
    > "$C/state/settings-cache.json"
}
drive() {
  : > "$C/pages.txt"; : > "$C/alerts.txt"
  echo 0 > "$C/state/costbreaker.stamp"
  ( export C NOW DIR T
    export HARNESS="$C" MODEL_PRICES="$C/prices.json" PATH="$C/stub:$PATH" FLEET_CONF="$C/fleet.conf" \
           LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" JOBS_URL='' HARNESS_JOBS_URL=''
    unset COST_CAPS_CONF
    bash -c '
      set -uo pipefail
      H="$C"
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$C/alerts.txt"; }
      page_critical() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$C/pages.txt"; }
      flag_set() { [ "$2" = on ] && printf "%s\n" "$3" > "$C/flags/$1"; return 0; }
      . "$DIR/bin/lib/lane-gate.sh" || exit 1
      . "$T/cr/bin/lib/cost-budget.sh" || exit 1
      . "$0"' "$C/blk.sh" >"$C/out.txt" 2>"$C/err.txt" )
}
budget_lines() { local n; n=$(grep -c ' cost budget: source ' "$C/logs/pipeline-health.log" 2>/dev/null); echo "${n:-0}"; }

ccache '{}' '{"conf.cost-caps.budget.acme":"100 3"}'; drive
eq "S5 tick 1 writes exactly one cost budget line" "$(budget_lines)" "1"
L1=$(grep ' cost budget: source ' "$C/logs/pipeline-health.log" 2>/dev/null | tail -1)
grep -qF 'acme $60.00/PR 24h vs $100/PR ok' <<<"$L1" && ok || bad "S5 tick 1 line names acme's rate and budget: $L1"
grep -qF 'settings seed conf.cost-caps.*' <<<"$L1" && ok || bad "S5 tick 1 source names the seed rows: $L1"
grep -qF 'ceiling $4000' <<<"$L1" && ok || bad "S5 tick 1 names the ceiling: $L1"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z cost budget: ' <<<"$L1" && ok || bad "S5 the line is stamped: $L1"
[ ! -e "$C/flags/spend-hold-acme" ] && ok || bad "S5 tick 1 must not hold acme ($(cat "$C/pages.txt" "$C/err.txt"))"
grep -qF 'halt=' <<<"$L1" && bad "S5 tick 1 names no halt: $L1" || ok

# Tick 1b: an operator row 40 3. $60 >= $40 is a TRIP (the costrate alert), but
# under the 2x autohalt multiple, so the line must not read as a pause.
ccache '{"conf.cost-caps.budget.acme":"40 3"}' '{"conf.cost-caps.budget.acme":"100 3"}'; drive
eq "S5 tick 1b adds exactly one more line" "$(budget_lines)" "2"
L1B=$(grep ' cost budget: source ' "$C/logs/pipeline-health.log" 2>/dev/null | tail -1)
grep -qF 'acme $60.00/PR 24h vs $40/PR TRIP' <<<"$L1B" && ok || bad "S5 tick 1b line names the TRIP: $L1B"
grep -qF 'halt=' <<<"$L1B" && bad "S5 tick 1b is an alert, not a halt, and its line must say so: $L1B" || ok
[ ! -e "$C/flags/spend-hold-acme" ] && ok || bad "S5 tick 1b must not hold acme below 2x"

ccache '{"conf.cost-caps.budget.acme":"20 3"}' '{"conf.cost-caps.budget.acme":"100 3"}'; drive
eq "S5 tick 2 adds exactly one more line" "$(budget_lines)" "3"
L2=$(grep ' cost budget: source ' "$C/logs/pipeline-health.log" 2>/dev/null | tail -1)
grep -qF 'acme $60.00/PR 24h vs $20/PR TRIP halt=done' <<<"$L2" && ok || bad "S5 tick 2 line names the TRIP and the halt it took: $L2"
grep -qF '+ settings conf.cost-caps.*' <<<"$L2" && ok || bad "S5 tick 2 source names the operator row: $L2"
# TEST-CHANGE (main merge, BH-5526): the cost autohalt writes
# flags/spend-hold-<p>, not paused-<p>; every flag check in S5 reads that
# name, so the "must not hold" checks above still bite.
[ -e "$C/flags/spend-hold-acme" ] && grep -q 'cost autohalt' "$C/flags/spend-hold-acme" && ok \
  || bad "S5 tick 2 holds acme with the autohalt reason ($(cat "$C/flags/spend-hold-acme" "$C/err.txt" 2>/dev/null))"
eq "S5 the catalog file bytes did not change (no deploy)" "$(cksum < "$C/catalog/cost-caps.conf")" "$CATSUM"

# An empty summary: section A skips, so no line is written.
rm -f "$C/flags/spend-hold-acme"; : > "$C/state/cost/summary.json"; drive
eq "S5 no summary, no line" "$(budget_lines)" "3"

# ── S7 bin/cost-caps-seed-sync.sh: the catalog stays the lever ─────────────
# A scratch harness with the real bin/cost-caps-seed-sync.sh and
# bin/cost-caps-seed.sh. The jobs client is a stub of POST /api/cost-caps/seed's
# contract over a JSON "D1" (insert absent, follow a registry-seed row, never
# move an operator row; the route itself is pinned by
# worker/jobs/test/cost-caps.bh-2564.test.js). The box reader then sees the D1
# registry-seed rows as the cache's `seeded` map, as _lg_settings_refresh writes it.
S="$T/sync"
mkdir -p "$S/bin" "$S/catalog" "$S/state" "$S/logs"
cp "$DIR/bin/cost-caps-seed-sync.sh" "$DIR/bin/cost-caps-seed.sh" "$S/bin/"
cp "$DIR/catalog/cost-caps.conf" "$DIR/catalog/lane-caps.conf" "$S/catalog/"
echo '{}' > "$S/d1.json"; : > "$S/posts"; echo ok > "$S/mode"
cat > "$S/bin/jobs-client.sh" <<'STUB'
_jobs_req() {
  local S; S=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  printf '%s %s\n' "$1" "$2" >> "$S/posts"
  if [ "$(cat "$S/mode")" = fail ]; then JOBS_HTTP=503; JOBS_BODY='{"error":"d1 down"}'; return 1; fi
  JOBS_HTTP=200
  jq --argjson b "$3" '. as $d | reduce $b.rows[] as $r ($d;
      if (.[$r.key] // null) == null or .[$r.key].actor == "registry-seed"
      then .[$r.key] = {value: $r.value, actor: "registry-seed"} else . end)' "$S/d1.json" > "$S/d1.new" \
    && mv "$S/d1.new" "$S/d1.json"
  jq -n --argjson b "$3" '{changed_keys: [$b.rows[].key]}'
}
STUB
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${HARNESS}/logs/ALERTS.log"\n' > "$S/bin/alert-line.sh"
chmod +x "$S/bin/"*.sh
sync_run() { HARNESS="$S" bash "$S/bin/cost-caps-seed-sync.sh"; }
posts() { grep -c . "$S/posts"; }
# d1cache — what a box's settings cache holds after its next refresh.
d1cache() {
  cache "$(jq '[to_entries[] | select(.value.actor != "registry-seed") | {key, value: .value.value}] | from_entries' "$S/d1.json")" \
        "$(jq '[to_entries[] | select(.value.actor == "registry-seed") | {key, value: .value.value}] | from_entries' "$S/d1.json")"
}

sync_run; eq "S7a rc 0 on success" "$?" "0"
eq "S7a the first sync sends one seed" "$(posts)" "1"
grep -q '^POST /api/cost-caps/seed$' "$S/posts" && ok || bad "S7a it posts to the seed route: $(cat "$S/posts")"
[ -s "$S/state/cost-caps-seeded" ] && ok || bad "S7a a successful seed stamps state/cost-caps-seeded"
eq "S7a D1 holds the catalog's project-1 row" "$(jq -r '.["conf.cost-caps.budget.project-1"].value' "$S/d1.json")" "155 3"
grep -q 'changed_keys' "$S/logs/cost-caps-seed-sync.log" && ok || bad "S7a the seed's answer is logged (the audit of what moved)"
sync_run; eq "S7b an unchanged catalog sends nothing" "$(posts)" "1"

# The hazard the hook exists for: a reviewed commit tightens project-1 and the
# responder lane. The box reads the catalog file AND the old seed row.
reset; cp "$S/catalog/"*.conf "$H/catalog/"
sed -i 's/^\(budget[[:space:]]\+project-1[[:space:]]\+\)155\([[:space:]]\)/\1100\2/' "$S/catalog/cost-caps.conf" "$H/catalog/cost-caps.conf"
sed -i 's/^\(lane[[:space:]]\+responder[[:space:]]\+\)150\([[:space:]]\)/\150\2/' "$S/catalog/lane-caps.conf" "$H/catalog/lane-caps.conf"
grep -qE '^budget[[:space:]]+project-1[[:space:]]+100[[:space:]]' "$H/catalog/cost-caps.conf" && ok || bad "S7c fixture: project-1 edited in the catalog"
grep -qE '^lane[[:space:]]+responder[[:space:]]+50[[:space:]]' "$H/catalog/lane-caps.conf" && ok || bad "S7c fixture: responder edited in the catalog"
d1cache
eq "S7c before the sync the old seed row shadows the edited file" "$(lib 'cost_budget_for project-1')" "155 3"
sync_run
eq "S7c a catalog edit sends one more seed" "$(posts)" "2"
eq "S7c D1's registry-seed row follows the catalog" "$(jq -r '.["conf.cost-caps.budget.project-1"].value' "$S/d1.json")" "100 3"
d1cache
eq "S7c the running budget follows the reviewed catalog edit" "$(lib 'cost_budget_for project-1')" "100 3"
eq "S7c the running lane cap follows the reviewed catalog edit" "$(lib 'lane_cap_usd responder')" "50"

# A failed seed: no stamp, one ALERT per catalog content, retried every sync.
STAMP_BEFORE=$(cat "$S/state/cost-caps-seeded")
echo fail > "$S/mode"
sed -i 's/^\(budget[[:space:]]\+project-1[[:space:]]\+\)100\([[:space:]]\)/\190\2/' "$S/catalog/cost-caps.conf"
sync_run; eq "S7d rc 0 on a failed seed" "$?" "0"
eq "S7d a failed seed does not move the stamp" "$(cat "$S/state/cost-caps-seeded")" "$STAMP_BEFORE"
eq "S7d a failed seed writes one ALERT" "$(grep -c 'cost-caps seed did NOT land' "$S/logs/ALERTS.log" 2>/dev/null)" "1"
grep -q 'OLD registry-seed rows' "$S/logs/ALERTS.log" && ok || bad "S7d the ALERT says the running caps are stale: $(cat "$S/logs/ALERTS.log")"
sync_run
eq "S7d the next sync retries" "$(posts)" "4"
eq "S7d the retry does not alert again for the same catalog" "$(grep -c 'cost-caps seed did NOT land' "$S/logs/ALERTS.log")" "1"
echo ok > "$S/mode"; sync_run
eq "S7d the recovery lands the edit" "$(jq -r '.["conf.cost-caps.budget.project-1"].value' "$S/d1.json")" "90 3"
[ "$(cat "$S/state/cost-caps-seeded")" != "$STAMP_BEFORE" ] && ok || bad "S7d the recovery stamps the new catalog"
[ ! -e "$S/state/cost-caps-seed-alerted" ] && ok || bad "S7d the recovery clears the alert marker"

# No catalog (C1 deletes them): nothing to seed, silent.
mv "$S/catalog/lane-caps.conf" "$S/catalog/lane-caps.off"; : > "$S/posts"
sync_run; eq "S7e a missing catalog file sends nothing" "$(posts)" "0"

# The wiring: bin/harness-sync.sh runs the hook on the box that holds cloudflare.env.
HS_BLK=$(sed -n '/^# >>> cost caps seed on deploy/,/^# <<< cost caps seed on deploy/p' "$DIR/bin/harness-sync.sh")
grep -qF '[ -f "$CFENV" ] && [ -x "$HARNESS/bin/cost-caps-seed-sync.sh" ]' <<<"$HS_BLK" && ok \
  || bad "S7f bin/harness-sync.sh runs bin/cost-caps-seed-sync.sh where cloudflare.env is"
[ "$(grep -n '^stamp_state harness-sync-last-success' "$DIR/bin/harness-sync.sh" | cut -d: -f1)" -lt \
  "$(grep -n '^# >>> cost caps seed on deploy' "$DIR/bin/harness-sync.sh" | cut -d: -f1)" ] && ok \
  || bad "S7f the hook runs after the deploy stamp, so it can never veto a deploy"

echo "caps-seed-rows.bh-4155: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
