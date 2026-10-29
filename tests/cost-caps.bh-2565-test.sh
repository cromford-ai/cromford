#!/bin/bash
# tests/cost-caps.bh-2565-test.sh — BH-2565 (BH-2511.2): bin/cost-caps-seed.sh,
# and the proof that a lowered cap held as an OPERATOR row halts a project (and,
# since BH-4155, so does the same value as a registry-seed row).
#
#   S1  --dry-run over the real catalog files: every row the files hold, keys
#       and values computed here from the files with awk, nothing sent
#   S2  a stub worker receives the identical body at POST /api/cost-caps/seed;
#       the script prints the changed keys, rc 0
#   S3  an empty file, a missing lane file, only unknown directives: rc 1, no
#       request
#   S4  unreachable worker, a 501, a 2xx with no changed_keys: rc 1, exactly one
#       stderr line
#   S5  the parser negatives: inline comment, whole-line comment, bad name, no
#       value, the legacy grammar, a duplicate key (last line wins, printed)
#   H1-H4 the real `cost budget` block of bin/pipeline-health.sh, the real
#       cost-budget/conf-row/lane-gate libs, and the real bin/launch-fastpath.sh:
#       no row -> not held; a seed row -> held (BH-4155: seed rows bind
#       above the catalog file); an operator row with the same value ->
#       spend-hold-acme with the autohalt reason and a costhalt page; the
#       fastpath's paused gate does NOT read that hold (BH-5526: the hold is
#       read at the build launch gate only, see
#       tests/autohalt-boundary.bh-5526-test.sh A5).
#
# Run from anywhere: tests/cost-caps.bh-2565-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/rendered.sh
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null && command -v awk >/dev/null || { echo "jq/awk missing — skipping"; exit 0; }

SEED="$DIR/bin/cost-caps-seed.sh"

# ── the S tree: a harness with the real catalog files and the real client ────
S="$T/s"
mkdir -p "$S/catalog" "$S/bin/lib/jobs" "$S/stub"
cp "$DIR/bin/jobs-client.sh" "$S/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$S/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$S/bin/lib/" 2>/dev/null || true
real_catalog() { cp "$DIR/catalog/cost-caps.conf" "$DIR/catalog/lane-caps.conf" "$S/catalog/"; }

# The stub worker: curl on PATH. Records the method, the URL and the body, and
# answers "$STUB_BODY\n$STUB_CODE" the way `-w '\n%{http_code}'` does.
cat > "$S/stub/curl" <<'SH'
#!/bin/bash
m="" b="" u=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary) b="$2"; shift ;;
    -m|--connect-timeout|-w|-H) shift ;;
    -*) ;;
    *) u="$1" ;;
  esac
  shift
done
case "$b" in @*) b=$(cat "${b#@}") ;; esac
echo "$m $u" >> "$STUB_DIR/req.log"
printf '%s' "$b" > "$STUB_DIR/body.json"
printf '%s\n%s' "$STUB_BODY" "$STUB_CODE"
SH
chmod +x "$S/stub/curl"

# seed [args...] — the real script, HARNESS=$S. stdout/stderr/rc land in files.
seed() {
  rm -f "$S/req.log" "$S/body.json"
  env HARNESS="$S" HARNESS_SECRET=x JOBS_URL="${URL-http://stub}" JOBS_RETRIES=0 JOBS_TIMEOUT=3 \
      STUB_DIR="$S" STUB_BODY="${STUB_BODY:-}" STUB_CODE="${STUB_CODE:-200}" \
      PATH="${SPATH:-$S/stub:$PATH}" "$SEED" "$@" >"$S/out" 2>"$S/err"
  RC=$?
}

# The expected rows, computed from the files themselves — an independent
# reading of the two grammars, not the script's.
expected() {
  { awk '{ sub(/#.*/, "") } $1 == "budget" && NF >= 3 { k = "conf.cost-caps.budget." $2; $1 = ""; $2 = ""; }
         $1 == "default" && NF >= 2 { k = "conf.cost-caps.default"; $1 = "" }
         $1 == "ceiling" && NF >= 2 { k = "conf.cost-caps.ceiling"; $1 = "" }
         $1 == "daily" && NF >= 3 { k = "conf.cost-caps." $2 ".daily_usd"; $1 = ""; $2 = ""; }
         k != "" { v = $0; gsub(/^ +| +$/, "", v); gsub(/ +/, " ", v); print k "\t" v; k = "" }' "$S/catalog/cost-caps.conf"
    awk '{ sub(/#.*/, "") } ($1 == "lane" || $1 == "noise") && NF >= 3 { k = "conf.lane-caps." $1 "." $2; $1 = ""; $2 = ""; }
         $1 == "default" && NF >= 2 { k = "conf.lane-caps.default"; $1 = "" }
         k != "" { v = $0; gsub(/^ +| +$/, "", v); gsub(/ +/, " ", v); print k "\t" v; k = "" }' "$S/catalog/lane-caps.conf"
  } | LC_ALL=C sort
}
rows_of() { jq -r '.rows[] | "\(.key)\t\(.value)"' "$1" | LC_ALL=C sort; }

# ── S1 dry run over the real catalog ─────────────────────────────────────────
real_catalog; seed --dry-run
eq "S1 dry run rc" "$RC" 0
cp "$S/out" "$S/dry.json"
EXP=$(expected)
[ "$(printf '%s\n' "$EXP" | grep -c .)" -ge 10 ] && ok || bad "S1 setup: the real catalog must hold rows ($EXP)"
eq "S1 dry-run rows equal the rows the files hold" "$(rows_of "$S/dry.json")" "$EXP"
for fam in conf.cost-caps.budget. conf.cost-caps.default conf.cost-caps.ceiling \
           conf.lane-caps.lane. conf.lane-caps.noise. conf.lane-caps.default; do
  jq -e --arg f "$fam" '[.rows[] | select(.key | startswith($f))] | length > 0' "$S/dry.json" >/dev/null \
    && ok || bad "S1 the family $fam must be present"
done
# BH-7876: a `daily <project> <usd>` line seeds the project-first key.
eq "S1 the project-6-os daily ceiling row (BH-7876)" \
  "$(jq -r '.rows[] | select(.key == "conf.cost-caps.project-6-os.daily_usd") | .value' "$S/dry.json")" \
  "$(awk '$1 == "daily" && $2 == "project-6-os" { print $3 }' "$DIR/catalog/cost-caps.conf")"
eq "S1 project-5 budget value" "$(jq -r '.rows[] | select(.key == "conf.cost-caps.budget.project-5") | .value' "$S/dry.json")" \
  "$(awk '$1 == "budget" && $2 == "project-5" { print $3 " " $4 }' "$DIR/catalog/cost-caps.conf")"
eq "S1 the lane default is not a cost default" \
  "$(jq -r '.rows[] | select(.key == "conf.lane-caps.default") | .value' "$S/dry.json")" \
  "$(awk '$1 == "default" { print $2 " " $3 }' "$DIR/catalog/lane-caps.conf")"
[ ! -e "$S/req.log" ] && ok || bad "S1 a dry run must send nothing: $(cat "$S/req.log")"
jq -e '.rows | (map(.key) == (map(.key) | sort))' "$S/dry.json" >/dev/null && ok || bad "S1 rows sorted by key"

# ── S2 the stub worker gets the same body ────────────────────────────────────
STUB_BODY='{"rows":17,"changed_keys":["conf.cost-caps.ceiling"],"pruned_keys":[]}' STUB_CODE=200 seed
eq "S2 rc" "$RC" 0
[ -s "$S/body.json" ] && eq "S2 the posted body equals the dry-run body" \
  "$(jq -S . "$S/body.json")" "$(jq -S . "$S/dry.json")" || bad "S2 nothing posted ($(cat "$S/err"))"
eq "S2 method and path" "$(cat "$S/req.log" 2>/dev/null)" "POST http://stub/api/cost-caps/seed"
grep -qx 'changed_keys: 1' "$S/out" && grep -q 'conf.cost-caps.ceiling' "$S/out" && grep -qx 'pruned_keys: 0' "$S/out" \
  && ok || bad "S2 prints the changed and pruned keys: $(cat "$S/out")"
STUB_BODY='{"changed_keys":[],"pruned_keys":["conf.cost-caps.budget.gone"]}' STUB_CODE=200 seed
[ "$RC" = 0 ] && grep -qx 'pruned_keys: 1' "$S/out" && grep -q 'conf.cost-caps.budget.gone' "$S/out" \
  && ok || bad "S2 prints the pruned keys too: rc=$RC $(cat "$S/out")"

# ── S3 refused before any request ────────────────────────────────────────────
printf '# only a comment\n\n' > "$S/catalog/cost-caps.conf"; : > "$S/catalog/lane-caps.conf"
STUB_BODY='{"changed_keys":[]}' seed
[ "$RC" = 1 ] && [ ! -e "$S/req.log" ] && [ -s "$S/err" ] && ok || bad "S3a empty files: rc 1, nothing sent (rc=$RC)"
real_catalog; rm -f "$S/catalog/lane-caps.conf"
STUB_BODY='{"changed_keys":[]}' seed
[ "$RC" = 1 ] && [ ! -e "$S/req.log" ] && grep -q 'lane-caps.conf' "$S/err" && ok \
  || bad "S3b a missing lane file refuses the whole seed, even with cost rows (rc=$RC $(cat "$S/err"))"
printf 'bogus x y\nbogus z 1\n' > "$S/catalog/cost-caps.conf"; printf 'bogus a b\n' > "$S/catalog/lane-caps.conf"
STUB_BODY='{"changed_keys":[]}' seed
[ "$RC" = 1 ] && [ ! -e "$S/req.log" ] && grep -q "^skipped: .*unknown directive 'bogus'" "$S/out" && ok \
  || bad "S3c only unknown directives: rc 1, skipped printed, nothing sent (rc=$RC $(cat "$S/out"))"

# ── S4 the POST fails ────────────────────────────────────────────────────────
real_catalog
URL=http://127.0.0.1:9 SPATH="$PATH" seed
[ "$RC" = 1 ] && [ "$(grep -c . "$S/err")" = 1 ] && grep -q 'failed' "$S/err" && ok \
  || bad "S4 unreachable worker: rc 1, one stderr line (rc=$RC $(cat "$S/err"))"
STUB_BODY='{"error":"not implemented"}' STUB_CODE=501 seed
[ "$RC" = 1 ] && [ "$(grep -c . "$S/err")" = 1 ] && grep -q 'http=501' "$S/err" && ! grep -q changed_keys "$S/out" && ok \
  || bad "S4b a 501: rc 1, one stderr line naming http=501, no success line (rc=$RC $(cat "$S/err" "$S/out"))"
STUB_BODY='{}' STUB_CODE=200 seed
[ "$RC" = 1 ] && [ "$(grep -c . "$S/err")" = 1 ] && ! grep -q '^changed_keys' "$S/out" && ok \
  || bad "S4c a 2xx without changed_keys is not a success (rc=$RC $(cat "$S/err" "$S/out"))"
seed --bogus
eq "S4d an unknown argument is usage, rc 2" "$RC" 2

# ── S5 parser negatives ──────────────────────────────────────────────────────
cat > "$S/catalog/cost-caps.conf" <<'CONF'
# budget ghost 1 1
budget Acme.x 5 1
budget acme
project-5 300
budget acme 5 1
budget   acme    7   2   # later wins
CONF
cat > "$S/catalog/lane-caps.conf" <<'CONF'
lane medic 90 40000 # why
CONF
seed --dry-run
eq "S5 rc" "$RC" 0
sed -n '/^{/,$p' "$S/out" > "$S/s5.json"
eq "S5 rows" "$(rows_of "$S/s5.json")" "$(printf 'conf.cost-caps.budget.acme\t7 2\nconf.lane-caps.lane.medic\t90 40000')"
grep -q "skipped: .*:2: bad name 'Acme.x'" "$S/out" && ok || bad "S5 a dotted/upper-case name is skipped: $(cat "$S/out")"
grep -q "skipped: .*:3: no value" "$S/out" && ok || bad "S5 budget with no value is skipped"
grep -q "skipped: .*:4: unknown directive 'project-5'" "$S/out" && ok || bad "S5 the legacy grammar is skipped"
grep -q "duplicate: conf.cost-caps.budget.acme (line 6 wins)" "$S/out" && ok || bad "S5 the duplicate is printed"
grep -q ghost "$S/out" && bad "S5 a commented line is no row" || ok

# ── H: the lowered cap, operator row vs seed row ────────────────────────────
NOW=$(date +%s)
REG=$(rendered_registry)
C="$T/h"
mkdir -p "$C/lib" "$C/bin" "$C/logs" "$C/state/cost" "$C/flags" "$C/stub" "$C/catalog"
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$DIR/bin/pipeline-health.sh" > "$C/blk.sh"
[ -s "$C/blk.sh" ] && ok || bad "H could not extract the cost budget block — markers missing?"
cp "$DIR/bin/lib/cost-budget.sh" "$DIR/bin/lib/conf-row.sh" "$DIR/bin/lib/lane-gate.sh" "$C/lib/"
printf 'budget acme 100 3\n' > "$C/catalog/cost-caps.conf"
printf 'acme Acme/acme - - 1 box-a 10.0.0.1\n' > "$C/fleet.conf"
cat > "$C/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
exit 1
SH
printf '#!/bin/bash\nexit 0\n' > "$C/stub/ssh"
chmod +x "$C/bin/fleet-conf.sh" "$C/stub/ssh"
# acme: $600 over 10 merged PRs in 24h = $60/PR.
cat > "$C/state/cost/summary.json" <<'JSON'
{ "projects": { "acme": {"delivery_cost_24h": 600, "merged_prs_24h": 10, "cost_7d": 600, "product_7d": 0,
                         "merged_prs_7d": 40, "merged_prs_status": "ok", "stages_24h": {"execute": 600}} } }
JSON
printf '{ "per_token": { "known": {"prompt": 0.001, "completion": 0.002, "cache_read": 0.0001, "cache_write": 0.0005} } }\n' > "$C/prices.json"
printf '%s\n' "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note" > "$C/logs/cost.csv"

# cache <values-json> <seeded-json> — a FRESH settings cache (operator rows in
# values, registry-seed rows in seeded), the shape lane-gate refreshes.
cache() {
  jq -n --argjson v "$1" --argjson s "$2" --argjson t "$NOW" '{fetched_at: $t, values: $v, seeded: $s}' \
    > "$C/state/settings-cache.json"
}
hreset() { rm -f "$C/flags/"* "$C/state/settings-cache.json" "$C/logs/lane-gate.log"; scratch_rm "$C/state/costhalt"; scratch_rm "$C/state/lane-gate"; }
# drive — the real block. COST_CAPS_CONF is NOT set: _cb_load reads no settings
# row when it is (bin/lib/cost-budget.sh), so HARNESS=$C answers the file.
drive() {
  : > "$C/pages.txt"; : > "$C/alerts.txt"
  echo 0 > "$C/state/costbreaker.stamp"
  ( export C NOW DIR
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
      . "$C/lib/cost-budget.sh" || exit 1
      cost_budget_for acme > "$C/budget.txt"; cost_budget_source > "$C/source.txt"
      . "$0"' "$C/blk.sh" >"$C/out.txt" 2>"$C/err.txt" )
}

hreset; drive
eq "H1 no row: the file budget binds" "$(cat "$C/budget.txt")" "100 3"
[ ! -e "$C/flags/spend-hold-acme" ] && ok || bad "H1 \$60/PR under a \$100 budget must not hold ($(cat "$C/pages.txt" "$C/err.txt"))"

# H2 — BH-4155: a registry-seed row is the DB copy of the catalog and binds
# above the file line (it bound nothing before BH-4155).
hreset; cache '{}' '{"conf.cost-caps.budget.acme":"20 3"}'; drive
eq "H2 a seed row binds above the file" "$(cat "$C/budget.txt")" "20 3"
[ -e "$C/flags/spend-hold-acme" ] && grep -q 'cost autohalt' "$C/flags/spend-hold-acme" && ok \
  || bad "H2 a registry-seed row of 20 3 must hold acme with the autohalt reason ($(cat "$C/flags/spend-hold-acme" "$C/pages.txt" "$C/err.txt" 2>/dev/null))"
grep -qF 'settings seed conf.cost-caps.*' "$C/source.txt" && ok || bad "H2 the source names the seed rows: $(cat "$C/source.txt")"

hreset; cache '{"conf.cost-caps.budget.acme":"20 3"}' '{}'; drive
eq "H3 the operator row binds" "$(cat "$C/budget.txt")" "20 3"
[ -e "$C/flags/spend-hold-acme" ] && grep -q 'cost autohalt' "$C/flags/spend-hold-acme" && ok \
  || bad "H3 an operator row with the same value must hold acme with the autohalt reason ($(cat "$C/flags/spend-hold-acme" "$C/pages.txt" "$C/err.txt" 2>/dev/null))"
L=$(grep '|costhalt:acme|' "$C/pages.txt" | head -1)
grep -q 'NEW BUILDS HELD' <<<"$L" && grep -q '\$60.00/PR' <<<"$L" && ok || bad "H3 the costhalt page names the rate: $L"
eq "H3 the catalog file did not change" "$(cat "$C/catalog/cost-caps.conf")" "budget acme 100 3"

# H4 — the real paused gate of the fastpath, with H3's hold in place. BH-5526:
# the hold is not the human pause, so the fastpath goes past its paused gate
# and declines on the fixture's next gate (the board has no key prefix). The
# build launch gate is what refuses a held project's new build.
[ -e "$C/flags/spend-hold-acme" ] || bad "H4 setup: H3 left no spend-hold-acme"
L4="$T/lf"
mkdir -p "$L4/bin/lib" "$L4/flags" "$L4/stub"
cp "$DIR/bin/launch-fastpath.sh" "$L4/bin/"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$L4/bin/lib/"
cp "$C/flags/spend-hold-acme" "$L4/flags/" 2>/dev/null
cat > "$L4/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) echo - ;; repo) echo Acme/acme ;; *) exit 1 ;; esac
SH
cat > "$L4/bin/run-build.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/launches.log"
SH
printf '#!/bin/bash\necho "$*" >> "$HARNESS/gh-calls.log"\nexit 1\n' > "$L4/stub/gh"
chmod +x "$L4/bin/fleet-conf.sh" "$L4/bin/run-build.sh" "$L4/stub/gh"
LOUT=$(env HARNESS="$L4" PATH="$L4/stub:$PATH" bash "$L4/bin/launch-fastpath.sh" acme 7 2>/dev/null); LRC=$?
eq "H4 exits 1" "$LRC" 1
eq "H4 declines the key" "$LOUT" "7"
grep -q 'FASTPATH-DECLINED 7 :: no key prefix' "$L4/logs/acme.log" 2>/dev/null \
  && ! grep -q 'project paused' "$L4/logs/acme.log" && ok \
  || bad "H4 the cost hold must not decline as 'project paused': $(cat "$L4/logs/acme.log" 2>/dev/null)"
[ ! -e "$L4/launches.log" ] && [ ! -e "$L4/gh-calls.log" ] && ok || bad "H4 nothing launched, no gh call"

echo "cost-caps.bh-2565: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
