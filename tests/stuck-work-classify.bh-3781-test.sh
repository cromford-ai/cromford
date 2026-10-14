#!/bin/bash
# tests/stuck-work-classify.bh-3781-test.sh — BH-3790 (BH-3781.1): the pure
# stuck-work classifier in bin/lib/stuck-work/classify.sh, its SLA knobs and the
# page-once decision. One pinned NOW, no I/O, a clean environment.
#
#   C*  one fixture per case in tests/fixtures/stuck-work/classify-*.txt: the
#       sw_state cut (state<TAB>owner) equals `# want:`, and each `# decide:
#       <ledger> <expect> [now]` runs sw_state -> sw_sla_s -> sw_age_s -> sw_decide
#   S5  the REAL worker/jobs/schema.sql, applied twice, seeds 8 lane.stuck-work.*
#       rows equal to the registry defaults
#   K1-K6 sw_sla_s, sw_age_s and the knob accessors
#   D1-D11 the sw_decide table (D10: SLA 0 pages once)
#   P1-P2 sw_page_text and sw_key
#   M*  mutants of classify.sh: each must turn this suite red
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuck-work-classify.bh-3781-test.sh
# SW_CLASSIFY_SRC=<file> runs the suite against another copy (the mutants do).
set -uo pipefail
# No STUCK_WORK_* from the caller's shell reaches the cases: re-run under env -i.
if [ "${SW_CLEAN_ENV:-}" != 1 ]; then
  exec env -i PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" SW_CLEAN_ENV=1 \
    HARNESS_TEST_SANDBOX="${HARNESS_TEST_SANDBOX:-}" SW_CLASSIFY_SRC="${SW_CLASSIFY_SRC:-}" \
    SW_NO_MUTANTS="${SW_NO_MUTANTS:-}" bash "$0"
fi
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SW_CLASSIFY_SRC:-$DIR/bin/lib/stuck-work/classify.sh}
FIX="$DIR/tests/fixtures/stuck-work"
REGFILE="$DIR/catalog/lanes.d/stuck-work.json"
NOW=1800000000
TAB=$'\t'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }

# shellcheck disable=SC1090
. "$SRC" || { echo "FAIL: cannot source $SRC"; echo "stuck-work-classify: 0 passed, 1 failed"; exit 1; }
for f in sw_state sw_sla_s sw_decide sw_key sw_page_text sw_age_s sw_repage_factor sw_max_items sw_repo; do
  [ "$(type -t "$f")" = function ] && ok || bad "$f is not a function"
done

# chain <facts> <now> <ledger> — the production order the lane runs per item.
chain() {
  local out st ow en ac sla age
  out=$(sw_state "$1") || { echo "sw_state-rc"; return; }
  IFS="$TAB" read -r st ow en ac <<< "$out"
  sla=$(sw_sla_s "$st") || sla=-
  [ "$ac" = - ] && ac=
  # shellcheck disable=SC2086
  age=$(sw_age_s "$2" "$en" $ac)
  sw_decide "$sla" "$age" "$3" "$(sw_repage_factor)" "$st"
}

# ── C: fixtures ─────────────────────────────────────────────────────────────
n=0
for f in "$FIX"/classify-*.txt; do
  [ -f "$f" ] || continue
  n=$((n+1)); c=$(basename "$f" .txt); c=${c#classify-}
  want=$(sed -n 's/^# want: //p' "$f")
  facts=$(grep -v '^#' "$f" | head -n 1)
  out=$(sw_state "$facts"); rc=$?
  eq "$c sw_state rc" "$rc" 0
  eq "$c state/owner" "$(printf '%s\n' "$out" | awk -F'\t' '{print $1"\t"$2}')" "$want"
  eq "$c output fields" "$(printf '%s\n' "$out" | awk -F'\t' '{print NF}')" 4
  while read -r led exp at; do
    eq "$c decide ledger=$led now=${at:-$NOW}" "$(chain "$facts" "${at:-$NOW}" "$led")" "$exp"
  done < <(sed -n 's/^# decide: //p' "$f")
done
[ "$n" -ge 30 ] && ok || bad "only $n classify fixtures found under $FIX"

# entered/action anchors on the fixtures the decision depends on
fx() { grep -v '^#' "$FIX/classify-$1.txt" | head -n 1; }
eq "C2 entered=max(verdict_at,lead_status_at)" "$(sw_state "$(fx C2)" | cut -f3,4)" "$((NOW-1100))${TAB}-"
eq "C3 entered=cond_since" "$(sw_state "$(fx C3)" | cut -f3)" "$((NOW-3600))"
eq "C4 action=dqw_action_at" "$(sw_state "$(fx C4)" | cut -f3,4)" "$((NOW-9999))${TAB}$((NOW-1900))"
eq "C13 entered=verdict_at action=resolver_at" "$(sw_state "$(fx C13)" | cut -f3,4)" "$((NOW-18000))${TAB}$((NOW-1200))"
eq "C7 entered=job_stage_seen" "$(sw_state "$(fx C7)" | cut -f3)" "$((NOW-600))"
eq "C9 unclassified entered=0" "$(sw_state "$(fx C9)" | cut -f3,4)" "0${TAB}-"
eq "C13 age is from the resolver action" "$(sw_age_s "$NOW" "$((NOW-18000))" "$((NOW-1200))")" 1200
sw_state > /dev/null 2>&1; eq "sw_state with no argument rc" "$?" 1
eq "unknown kind" "$(sw_state "$(fx C1 | sed 's/^pr/mr/')" | cut -f1,2)" "unclassified${TAB}stuck-work"
eq "empty field" "$(sw_state "$(fx C1 | sed 's/\tai-build\t/\t\t/')" | cut -f1)" unclassified

# ── S5: the seeds, from the real schema.sql ─────────────────────────────────
if ! command -v node > /dev/null; then bad "S5 node is missing"
else
  rows=$(node -e '
    let D; try { ({ DatabaseSync: D } = require("node:sqlite")); } catch { console.log("NO-SQLITE"); process.exit(0); }
    const s = require("fs").readFileSync(process.argv[1], "utf8"), db = new D(":memory:");
    db.exec(s); db.exec(s);
    for (const r of db.prepare("SELECT key,value FROM settings WHERE key LIKE ? ORDER BY key").all("lane.stuck-work.%"))
      console.log(r.key + "=" + r.value);' "$DIR/worker/jobs/schema.sql" 2> "$T/s5.err"); rc=$?
  eq "S5 schema.sql applies twice" "$rc" 0
  [ "$rows" = NO-SQLITE ] && bad "S5 node:sqlite is unavailable"
  want=$(jq -r '.knobs[]|select(.env|test("^STUCK_WORK_SLA_"))|"lane.stuck-work.\(.env|ascii_downcase)=\(.default)"' "$REGFILE" | sort)
  eq "S5 seed rows equal the registry defaults" "$rows" "$want"
  eq "S5 seed row count" "$(printf '%s\n' "$rows" | grep -c '^lane.stuck-work.')" 8
fi

# ── K: SLAs, ages, accessors ────────────────────────────────────────────────
for p in awaiting-lead-review:3600 ready:900 queued:5400 dequeued:1800 blocked:3600 \
         waiting-on-human:86400 unlaunched:3600 unclassified:0 building:plan:2700; do
  eq "K1 sw_sla_s ${p%:*}" "$(sw_sla_s "${p%:*}")" "${p##*:}"
done
eq "K1 building + stage arg" "$(sw_sla_s building fix)" 3600
sw_sla_s excluded > "$T/k1"; rc=$?; eq "K1 excluded rc/out" "$rc:$(cat "$T/k1")" "1:"
sw_sla_s nonsense > "$T/k1"; rc=$?; eq "K1 unknown state rc/out" "$rc:$(cat "$T/k1")" "1:"
eq "K2 READY_MIN=20" "$(STUCK_WORK_SLA_READY_MIN=20 sw_sla_s ready)" 1200
eq "K2 HUMAN_MIN=60" "$(STUCK_WORK_SLA_HUMAN_MIN=60 sw_sla_s waiting-on-human)" 3600
eq "K2 QUEUED_MIN=010 is decimal" "$(STUCK_WORK_SLA_QUEUED_MIN=010 sw_sla_s queued)" 600
eq "K3 READY_MIN=abc" "$(STUCK_WORK_SLA_READY_MIN=abc sw_sla_s ready)" 900
eq "K3 READY_MIN=0" "$(STUCK_WORK_SLA_READY_MIN=0 sw_sla_s ready)" 900
eq "K3 READY_MIN=' 20'" "$(STUCK_WORK_SLA_READY_MIN=' 20' sw_sla_s ready)" 900
eq "K4 building:execute" "$(sw_sla_s building:execute)" 7200
eq "K4 building:weird uses default=" "$(sw_sla_s building:weird)" 5400
eq "K4 custom plan=5" "$(STUCK_WORK_SLA_BUILD_STAGES=plan=5 sw_sla_s building:plan)" 300
eq "K4 custom, no entry, no default=" "$(STUCK_WORK_SLA_BUILD_STAGES=plan=5 sw_sla_s building:execute)" 5400
eq "K4 unparseable string uses the registry default" "$(STUCK_WORK_SLA_BUILD_STAGES='plan=;;' sw_sla_s building:execute)" 7200
eq "K5 future anchor" "$(sw_age_s "$NOW" "$((NOW+60))")" 0
eq "K5 future action" "$(sw_age_s "$NOW" "$((NOW-6000))" "$((NOW+60))")" 0
eq "K5 ? anchor" "$(sw_age_s "$NOW" '?')" 0
eq "K5 - anchor" "$(sw_age_s "$NOW" -)" 0
eq "K5 ? now" "$(sw_age_s '?' "$((NOW-60))")" 0
eq "K5 plain" "$(sw_age_s "$NOW" "$((NOW-60))")" 60
eq "K5 max(entered, action)" "$(sw_age_s "$NOW" "$((NOW-6000))" "$((NOW-60))")" 60
eq "K5 action older than entered" "$(sw_age_s "$NOW" "$((NOW-60))" "$((NOW-6000))")" 60
eq "K5 unreadable action ignored" "$(sw_age_s "$NOW" "$((NOW-60))" '?')" 60
eq "K6 factor default" "$(sw_repage_factor)" 4
eq "K6 factor 1 -> 2" "$(STUCK_WORK_REPAGE_FACTOR=1 sw_repage_factor)" 2
eq "K6 factor abc -> 4" "$(STUCK_WORK_REPAGE_FACTOR=abc sw_repage_factor)" 4
eq "K6 factor 7" "$(STUCK_WORK_REPAGE_FACTOR=7 sw_repage_factor)" 7
eq "K6 max items default" "$(sw_max_items)" 300
eq "K6 max items 0 -> 300" "$(STUCK_WORK_MAX_ITEMS=0 sw_max_items)" 300
eq "K6 max items 50" "$(STUCK_WORK_MAX_ITEMS=50 sw_max_items)" 50
eq "K6 repo default" "$(sw_repo)" example-org/cromford
eq "K6 repo set" "$(STUCK_WORK_REPO=o/r sw_repo)" o/r
eq "K6 repo malformed -> default" "$(STUCK_WORK_REPO='o r; x' sw_repo)" example-org/cromford
# The code fallbacks equal the registry defaults.
for e in $(jq -r '.knobs[]|select(.env|test("^STUCK_WORK_(SLA_|REPAGE|MAX_ITEMS|REPO)"))|.env' "$REGFILE"); do
  d=$(jq -r --arg e "$e" '.knobs[]|select(.env==$e)|.default' "$REGFILE")
  # BH-4080: the repo's fallback is HARNESS_REPO, whose one default lives in
  # bin/lib/deployment.sh; that default must still be the registry's.
  if [ "$e" = STUCK_WORK_REPO ]; then
    grep -q '${STUCK_WORK_REPO:-$HARNESS_REPO}' "$SRC" \
      && [ "$(env -i PATH="$PATH" bash -c '. "$1" && printf %s "$HARNESS_REPO"' _ "$DIR/bin/lib/deployment.sh")" = "$d" ] && ok \
      || bad "K7 $SRC does not read \${$e:-\$HARNESS_REPO} with HARNESS_REPO defaulting to the registry's $d"
    continue
  fi
  grep -q "\${$e:-$d}" "$SRC" && ok \
    || bad "K7 $SRC does not read \${$e:-<registry default>}"
done

# ── D: the decision table ───────────────────────────────────────────────────
eq "D1 below SLA"        "$(sw_decide 900 899 - 4)" quiet
eq "D2 at SLA"           "$(sw_decide 900 900 - 4)" page
eq "D3 paged at 3.9x"    "$(sw_decide 900 3510 paged 4)" quiet
eq "D4 paged at 4x"      "$(sw_decide 900 3600 paged 4)" repage
eq "D5 repaged at 100x"  "$(sw_decide 900 90000 repaged 4)" quiet
eq "D6 unreadable ledger" "$(sw_decide 900 90000 '?' 4)" quiet
eq "D7 waiting-on-human 30h" "$(sw_decide 86400 108000 - 4 waiting-on-human)" quiet
eq "D7 excluded"         "$(sw_decide 900 90000 - 4 excluded)" quiet
eq "D8 non-digit age"    "$(sw_decide 900 x - 4)" quiet
eq "D8 non-digit sla"    "$(sw_decide - 900 - 4)" quiet
eq "D8 factor 1 reads as 2" "$(sw_decide 900 1800 paged 1)" repage
eq "D8 sla 0 pages at once" "$(sw_decide 0 0 - 4)" page
eq "D10 sla 0 paged stays quiet" "$(sw_decide 0 300 paged 4)" quiet
eq "D10 sla 0 paged a day on" "$(sw_decide 0 86400 paged 4)" quiet
eq "D10 sla 0 repaged"     "$(sw_decide 0 600 repaged 4)" quiet
eq "D11 leading-zero factor" "$(sw_decide 900 7200 paged 08)" repage
eq "D11 leading-zero age"  "$(sw_decide 900 0900 - 4)" page
eq "D11 20-digit age"      "$(sw_decide 900 12345678901234567890 paged 4 2>&1)" quiet
sw_decide 900 900 > /dev/null 2>&1; eq "D9 too few args rc" "$?" 1

# ── P: page text and key ────────────────────────────────────────────────────
eq "P1 page text" "$(sw_page_text 'o/r#12' ready conductor 1200 900 https://github.com/o/r/pull/12)" \
  "STUCK-WORK o/r#12 ready owner=conductor age=20m sla=15m — https://github.com/o/r/pull/12"
eq "P1 owner with spaces" "$(sw_page_text 'o/r#40' unlaunched 'triage / dispatch' 3600 3600 u)" \
  "STUCK-WORK o/r#40 unlaunched owner=triage / dispatch age=60m sla=60m — u"
eq "P2 key" "$(sw_key 'o/r#12' ready 1700000100)" 'o/r#12|ready|1700000100'
eq "P2 key, ? entered" "$(sw_key 'o/r#12' ready '?')" 'o/r#12|ready|0'
sw_key '' ready 1 > /dev/null; eq "P2 empty item rc" "$?" 1
sw_key 'o/r#12' '' 1 > /dev/null; eq "P2 empty state rc" "$?" 1

# ── M: mutants of the shipped file must turn this suite red ─────────────────
# mutant <name> <sed expr> <a FAIL line it must produce>
mutant() {
  local m="$T/mutant-$1.sh"
  sed -e "$2" "$SRC" > "$m"
  if cmp -s "$SRC" "$m"; then bad "$1 the sed did not change classify.sh (vacuous mutant)"; return; fi
  SW_CLASSIFY_SRC="$m" SW_NO_MUTANTS=1 SW_CLEAN_ENV= bash "$DIR/tests/stuck-work-classify.bh-3781-test.sh" > "$T/$1.out" 2>&1
  local rc=$?
  [ "$rc" != 0 ] && ok || bad "$1 the suite stayed green against the mutant"
  grep -q "^FAIL: $3" "$T/$1.out" && ok || bad "$1 no 'FAIL: $3' line against the mutant"
}
if [ -z "${SW_NO_MUTANTS:-}" ] && [ -z "${SW_CLASSIFY_SRC:-}" ]; then
  mutant M1a '/f \* sla/s/-ge/-gt/' 'D4 paged at 4x'
  mutant M1b '/age" -lt "\$sla/s/-lt/-le/' 'D2 at SLA'
  mutant M2 '/^ *repaged) /d' 'D5 repaged at 100x'
  mutant M3 '/waiting-on-human|excluded) echo quiet/d' 'D7 waiting-on-human'
  mutant M4 's/"\$verdict_sha" = "\$head"/1 = 1/' 'C19 state/owner'
  mutant M5 '/-gt "\$now"/s/-gt "\$now"/-gt 9999999999999/' 'K5 future anchor'
  mutant M6 '/ai-build/s/excluded/unlaunched/' 'C20 state/owner'
  mutant M7 's/\[ "\$sla" = 0 \] \&\& { echo quiet/[ 1 = 0 ] \&\& { echo quiet/' 'D10 sla 0 paged stays quiet'
fi

echo "stuck-work-classify: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
