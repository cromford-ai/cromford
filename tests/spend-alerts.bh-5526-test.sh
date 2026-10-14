#!/bin/bash
# tests/spend-alerts.bh-5526-test.sh — BH-5526 slice C2: spend ALERTS that
# refuse nothing.
#
# WHAT IT PINS:
#   S1-S5  bin/spend-alerts.sh baseline: per (axis, key) nearest-rank p99 of
#          the UTC-day totals over [until - days, until), the
#          bin/budget-defaults.sh rule (dedup identical lines, drop refused and
#          settled rows); a key with fewer than --min-days days prints nothing;
#          a row with an empty lane_id is a `stage` lane; a csv that is not a
#          cost.csv exits 1 and prints nothing.
#   S6-S9  bin/spend-alerts.sh perpr: cost per merged PR against the fleet
#          median, held for --hold-s before it prints; thin, null, `other` and
#          `fleet` projects never count; fewer than 3 eligible projects is
#          `noeval` and leaves the hold state alone.
#   P1-P9  the `# >>> spend alerts` block of bin/pipeline-health.sh, extracted
#          VERBATIM by its markers and driven against a scratch tree with a
#          stubbed alert / cost_rows_fetch / lane_knob, and recorders for every
#          verb that could refuse work (flag_set, cb_halt, page_critical,
#          setting_set). P4 runs the REAL alert() for the once-a-day dedup.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/spend-alerts.bh-5526-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v awk >/dev/null || { echo "jq/awk missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/state/cost" "$H/logs" "$H/flags"
scratch_install_closure bin/spend-alerts.sh "$H" >/dev/null || bad "could not install the bin/spend-alerts.sh closure"
SA="$H/bin/spend-alerts.sh"
[ -x "$SA" ] && ok || bad "bin/spend-alerts.sh is missing or not executable ($DIR/bin/spend-alerts.sh)"

# A fixed clock: 2026-10-08 15:00:00Z. Today (UTC) is 2026-10-08; the 14-day
# baseline window is [2026-09-24, 2026-10-08).
FIXNOW=$(date -u -d '2026-10-08T15:00:00Z' +%s)
HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
row() { # row <ts> <project> <stage> <lane_id> <cost_usd> [row_source]
  printf '%s,box-a,%s,%s,claude,m,0,1,0,0,0,0,%s,api,,,,%s,,,,,,,%s,\n' "$1" "$2" "$3" "$5" "${6:-}" "$4"
}
day() { date -u -d "2026-10-08 -$1 days" +%F; }   # day <n> — n UTC days before today

# --- the 14-day history every block case reads ---------------------------------
#   fly-pool (project busy): 14 days, $40..$120, p99 $120
#   short6   (project quiet): 6 days of $10 — under --min-days, no line
#   seven    (project sev):   7 days of $5 — exactly --min-days, one line
{
  echo "$HDR"
  i=0
  for c in 120 100 95 90 85 80 75 70 65 60 55 50 45 40; do
    i=$((i+1)); row "$(day "$i")T10:00:00Z" busy execute fly-pool "$c"
  done
  for i in 1 2 3 4 5 6; do row "$(day "$i")T09:00:00Z" quiet execute short6 10; done
  for i in 1 2 3 4 5 6 7; do row "$(day "$i")T08:00:00Z" sev execute seven 5; done
} > "$T/hist.csv"

# --- S1 / S3: baseline over the history ----------------------------------------
OUT=$("$SA" baseline --rows "$T/hist.csv" --until 2026-10-08 --days 14 --min-days 7 2>/dev/null); rc=$?
[ "$rc" = 0 ] && ok || bad "S1 baseline exited $rc on a good csv"
grep -qxF "$(printf 'lane\tfly-pool\t120.00\t14')" <<<"$OUT" && ok \
  || bad "S1 lane fly-pool p99 is not 120.00 over 14 days: [$OUT]"
grep -qxF "$(printf 'project\tbusy\t120.00\t14')" <<<"$OUT" && ok \
  || bad "S1 project busy has no row of its own: [$OUT]"
grep -q "short6\|quiet" <<<"$OUT" && bad "S3 a key with 6 days printed a line: [$OUT]" || ok
[ "$(printf '%s\n' "$OUT" | grep -cxF "$(printf 'lane\tseven\t5.00\t7')")" = 1 ] && ok \
  || bad "S3 a lane with exactly 7 days did not print one line: [$OUT]"

# --- S2: nearest-rank p99 — 101 samples gives the 100th, not the max ------------
{
  echo "$HDR"
  for i in $(seq 1 101); do row "$(day "$i")T10:00:00Z" big execute big "$i"; done
} > "$T/s2.csv"
OUT=$("$SA" baseline --rows "$T/s2.csv" --until 2026-10-08 --days 120 --min-days 7 2>/dev/null)
grep -qxF "$(printf 'lane\tbig\t100.00\t101')" <<<"$OUT" && ok \
  || bad "S2 nearest-rank p99 of 1..101 is not 100.00 (ceil(0.99n)-1): [$OUT]"
OUT=$("$SA" baseline --rows "$T/hist.csv" --until 2026-10-08 --days 14 --min-days 1 2>/dev/null)
grep -qxF "$(printf 'lane\tshort6\t10.00\t6')" <<<"$OUT" && ok \
  || bad "S3 --min-days 1 did not admit the 6-day lane: [$OUT]"

# --- S4: refused / settled / duplicate / stage fallback / window edges ---------
{
  echo "$HDR"
  for i in 1 2 3 4 5 6 7; do row "$(day "$i")T10:00:00Z" p4 triage "" 10; done
  row "$(day 1)T10:00:00Z" p4 triage "" 10                    # an identical duplicate line
  row "$(day 2)T11:00:00Z" p4 triage "" 500 refused
  row "$(day 3)T11:00:00Z" p4 triage "" 500 settled
  row "2026-10-08T01:00:00Z" p4 triage "" 999                 # today: not in the baseline
  row "$(day 15)T10:00:00Z" p4 triage "" 999                  # 15 days ago: outside 14
} > "$T/s4.csv"
OUT=$("$SA" baseline --rows "$T/s4.csv" --until 2026-10-08 --days 14 --min-days 7 2>/dev/null)
grep -qxF "$(printf 'lane\ttriage\t10.00\t7')" <<<"$OUT" && ok \
  || bad "S4 empty lane_id did not group under stage, or a refused/settled/duplicate/out-of-window row counted: [$OUT]"
grep -qxF "$(printf 'project\tp4\t10.00\t7')" <<<"$OUT" && ok \
  || bad "S4 project p4 total is not 10.00 a day: [$OUT]"

# --- S5: not a cost.csv ----------------------------------------------------------
printf 'ts,project,stage\n2026-10-07T10:00:00Z,p,x\n' > "$T/s5.csv"
OUT=$("$SA" baseline --rows "$T/s5.csv" --until 2026-10-08 --days 14 --min-days 7 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$OUT" ] && ok || bad "S5 a csv with no cost_usd header: rc=$rc out=[$OUT] (want rc 1, nothing printed)"

# --- the summary.json every per-PR case reads --------------------------------------
# Eligible: cromford 20, project-5 18, project-4 25, project-1 15, project-9
# 154.80 → median 20.00, project-9 7.74x. Never eligible: tiny (2 PRs), nullp
# (null rate), other and fleet (ledger buckets).
summary() { # summary <project-9 rate>
  cat > "$1" <<JSON
{ "projects": {
  "cromford": {"cost_per_merged_pr_7d": 20,    "merged_prs_7d": 258},
  "project-5":     {"cost_per_merged_pr_7d": 18,    "merged_prs_7d": 40},
  "project-4":       {"cost_per_merged_pr_7d": 25,    "merged_prs_7d": 30},
  "project-1":      {"cost_per_merged_pr_7d": 15,    "merged_prs_7d": 12},
  "project-9":    {"cost_per_merged_pr_7d": $2, "merged_prs_7d": 5},
  "tiny":          {"cost_per_merged_pr_7d": 200,   "merged_prs_7d": 2},
  "nullp":         {"cost_per_merged_pr_7d": null,  "merged_prs_7d": 10},
  "other":         {"cost_per_merged_pr_7d": 500,   "merged_prs_7d": 50},
  "fleet":         {"cost_per_merged_pr_7d": 900,   "merged_prs_7d": 50}
} }
JSON
}
perpr() { "$SA" perpr --summary "$T/sum.json" --state "$T/perpr.tsv" --now "$FIXNOW" --mult 3 --min-prs 3 --hold-s 172800 2>/dev/null; }

# --- S6: first sight writes the hold start and prints nothing ------------------------
summary "$T/sum.json" 154.80; rm -f "$T/perpr.tsv"
OUT=$(perpr); rc=$?
[ "$rc" = 0 ] && [ -z "$OUT" ] && ok || bad "S6 first sight printed or failed: rc=$rc out=[$OUT]"
[ "$(cat "$T/perpr.tsv" 2>/dev/null)" = "$(printf 'project-9\t%s' "$FIXNOW")" ] && ok \
  || bad "S6 state is not project-9<TAB>now: [$(cat "$T/perpr.tsv" 2>/dev/null)]"

# --- S7: 49h held prints; 47h does not ------------------------------------------------
printf 'project-9\t%s\n' $(( FIXNOW - 49*3600 )) > "$T/perpr.tsv"
OUT=$(perpr)
[ "$OUT" = "$(printf 'project-9\t154.80\t20.00\t7.74\t%s' $(( FIXNOW - 49*3600 )))" ] && ok \
  || bad "S7 a 49h outlier did not print project-9 154.80 20.00 7.74: [$OUT]"
[ "$(cut -f2 "$T/perpr.tsv")" = "$(( FIXNOW - 49*3600 ))" ] && ok || bad "S7 the earliest first_over was not kept"
printf 'project-9\t%s\n' $(( FIXNOW - 47*3600 )) > "$T/perpr.tsv"
OUT=$(perpr)
[ -z "$OUT" ] && ok || bad "S7 a 47h outlier printed: [$OUT]"

# --- S8: never-eligible projects; 2 eligible is noeval, state untouched ---------------
printf 'project-9\t%s\n' $(( FIXNOW - 49*3600 )) > "$T/perpr.tsv"
OUT=$(perpr)
grep -qE '^(tiny|nullp|other|fleet)	' <<<"$OUT" && bad "S8 an ineligible project printed: [$OUT]" || ok
grep -qE '^(tiny|nullp|other|fleet)	' "$T/perpr.tsv" && bad "S8 an ineligible project entered the state" || ok
cat > "$T/sum2.json" <<'JSON'
{ "projects": { "a": {"cost_per_merged_pr_7d": 10, "merged_prs_7d": 9},
                "b": {"cost_per_merged_pr_7d": 90, "merged_prs_7d": 9},
                "c": {"cost_per_merged_pr_7d": 999, "merged_prs_7d": 1} } }
JSON
cp "$T/perpr.tsv" "$T/perpr.before"
OUT=$("$SA" perpr --summary "$T/sum2.json" --state "$T/perpr.tsv" --now "$FIXNOW" --mult 3 --min-prs 3 --hold-s 172800 2>/dev/null)
[ "$(printf '%s\n' "$OUT" | cut -f1,2)" = "$(printf 'noeval\t2')" ] && ok || bad "S8 two eligible projects did not print noeval 2: [$OUT]"
cmp -s "$T/perpr.tsv" "$T/perpr.before" && ok || bad "S8 a noeval run changed the hold state"

# --- S9: back under the line drops the hold ------------------------------------------------
summary "$T/sum.json" 50
printf 'project-9\t%s\n' $(( FIXNOW - 49*3600 )) > "$T/perpr.tsv"
OUT=$(perpr)
[ -z "$OUT" ] && ok || bad "S9 a project under 3x printed: [$OUT]"
grep -q project-9 "$T/perpr.tsv" 2>/dev/null && bad "S9 a project back under 3x kept its hold line" || ok

# ================= the production block in bin/pipeline-health.sh =================
awk '/^# >>> spend alerts/{f=1;next} /^# <<< spend alerts/{exit} f' "$DIR/bin/pipeline-health.sh" > "$H/blk.sh"
[ -s "$H/blk.sh" ] && ok || bad "could not extract the spend alerts block from bin/pipeline-health.sh — markers missing?"
awk '/^alert\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/pipeline-health.sh" > "$H/alert-fn.sh"
[ -s "$H/alert-fn.sh" ] && ok || bad "could not extract alert() from bin/pipeline-health.sh"

cat > "$H/stubs.sh" <<'SH'
alert() { printf '%s\t%s\n' "$2" "$3" >> "$H/alerts.rec"; }
cost_rows_db_enabled() { return 0; }
cost_rows_fetch() { # <out> <since> [until]
  echo "$2 ${3:-}" >> "$H/fetch.rec"
  [ -f "$H/fetch-fail" ] && { : > "$1"; return 1; }
  case "$2" in *T00:00:00Z) [ "$2" = "$(date -u -d "@$NOW" +%F)T00:00:00Z" ] && { cp "$H/today.csv" "$1"; return 0; } ;; esac
  cp "$H/hist.csv" "$1"
}
lane_knob() { [ "$1" = pipeline-health ] || return 0; awk -F= -v k="$2" '$1==k{print $2}' "$H/knobs" 2>/dev/null; }
flag_set()      { echo "flag_set $*" >> "$H/forbidden.rec"; }
cb_halt()       { echo "cb_halt $*" >> "$H/forbidden.rec"; }
page_critical() { echo "page_critical $*" >> "$H/forbidden.rec"; }
setting_set()   { echo "setting_set $*" >> "$H/forbidden.rec"; }
SH
cat > "$H/bin/ph-driver.sh" <<'SH'
#!/bin/bash
set -uo pipefail
H="$HARNESS"; NOW="$FIXNOW"
DEDUP="$H/state/health-alerted.json"; FIRED="$H/state/fired"
[ -s "$DEDUP" ] || echo '{}' > "$DEDUP"
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
. "$H/stubs.sh"
if [ "${REAL_ALERT:-0}" = 1 ]; then
  . "$H/alert-fn.sh"
  alert_emit() { printf '%s\t%s\n' "${2:-}" "$1" >> "$H/emit.rec"; }
fi
. "$H/blk.sh"
SH
chmod +x "$H/bin/ph-driver.sh" "$H/stubs.sh"
cp "$T/hist.csv" "$H/hist.csv"

fresh() { # a clean lane state; the installed bin/ stays
  scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$H/flags"
  rm -f "$H/alerts.rec" "$H/fetch.rec" "$H/forbidden.rec" "$H/emit.rec" "$H/knobs" "$H/fetch-fail"
  mkdir -p "$H/state/cost" "$H/logs" "$H/flags"
  : > "$H/knobs"
}
today() { # today <fly-pool usd today, as three rows>
  local each; each=$(awk -v t="$1" 'BEGIN{printf "%.2f", t/3}')
  { echo "$HDR"
    row 2026-10-08T01:00:00Z busy execute fly-pool "$each"
    row 2026-10-08T05:00:00Z busy execute fly-pool "$each"
    row 2026-10-08T09:00:00Z busy execute fly-pool "$each"
    row 2026-10-07T23:00:00Z busy execute fly-pool 500     # yesterday: not today's spend
  } > "$H/today.csv"
}
drive() { HARNESS="$H" FIXNOW="$FIXNOW" bash "$H/bin/ph-driver.sh" 2>"$H/drive.err"; }
nkey() { [ -f "$H/alerts.rec" ] && grep -c "^$1	" "$H/alerts.rec" || echo 0; }

# --- P1: fly-pool at $300 against p99 $120 (line $180): one alert, nothing refused --
fresh; today 300
drive
[ "$(nkey 'spendp99:lane:fly-pool')" = 1 ] && ok \
  || bad "P1 want exactly one spendp99:lane:fly-pool alert, got $(nkey 'spendp99:lane:fly-pool') [$(cat "$H/alerts.rec" 2>/dev/null)] err=[$(cat "$H/drive.err")]"
grep "^spendp99:lane:fly-pool	" "$H/alerts.rec" 2>/dev/null | grep -q 'nothing is refused or held' && ok \
  || bad "P1 the alert line does not say nothing is refused or held"
grep "^spendp99:lane:fly-pool	" "$H/alerts.rec" 2>/dev/null | grep -qF '$300.00' && ok \
  || bad "P1 the alert line does not carry today's \$300.00"
P1FORBID=$(cat "$H/forbidden.rec" 2>/dev/null)

# --- P2: $179 is under the $180 line ------------------------------------------------------
fresh; today 179
drive
[ "$(nkey 'spendp99:lane:fly-pool')" = 0 ] && ok || bad "P2 \$179 against a \$180 line alerted"

# --- P5 / P6: the per-PR outlier through the block ---------------------------------------
fresh; today 10; summary "$H/state/cost/summary.json" 154.80
mkdir -p "$H/state/spend-alerts"
printf 'project-9\t%s\n' $(( FIXNOW - 49*3600 )) > "$H/state/spend-alerts/perpr-over.tsv"
drive
[ "$(nkey 'spendperpr:project-9')" = 1 ] && ok \
  || bad "P5 want one spendperpr:project-9 alert, got $(nkey 'spendperpr:project-9') [$(cat "$H/alerts.rec" 2>/dev/null)] err=[$(cat "$H/drive.err")]"
grep "^spendperpr:project-9	" "$H/alerts.rec" 2>/dev/null | grep -q 'nothing is refused or held' && ok \
  || bad "P5 the per-PR alert line does not say nothing is refused or held"
P5FORBID=$(cat "$H/forbidden.rec" 2>/dev/null)
fresh; today 10; summary "$H/state/cost/summary.json" 154.80
mkdir -p "$H/state/spend-alerts"
printf 'project-9\t%s\n' $(( FIXNOW - 47*3600 )) > "$H/state/spend-alerts/perpr-over.tsv"
drive
[ "$(nkey 'spendperpr:project-9')" = 0 ] && ok || bad "P6 a 47h outlier alerted"

# --- P3: nothing refuses ---------------------------------------------------------------------
[ -z "$P1FORBID$P5FORBID" ] && ok || bad "P3 the block called a refusing verb: [$P1FORBID$P5FORBID]"
fresh; today 300; summary "$H/state/cost/summary.json" 154.80
mkdir -p "$H/state/spend-alerts"
printf 'project-9\t%s\n' $(( FIXNOW - 49*3600 )) > "$H/state/spend-alerts/perpr-over.tsv"
drive
grep -qE '^(spend-hold-|paused-)' <<<"$(ls "$H/flags")" && bad "P3 a hold or pause flag was written" || ok
[ ! -s "$H/forbidden.rec" ] && ok || bad "P3 a refusing verb was called: [$(cat "$H/forbidden.rec")]"

# --- P4: the REAL alert() keeps it to one emit a day -----------------------------------------
fresh; today 300; mkdir -p "$H/bin"; printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
REAL_ALERT=1 HARNESS="$H" FIXNOW="$FIXNOW" bash "$H/bin/ph-driver.sh" 2>"$H/drive.err"
rm -f "$H/state/spend-alerts.stamp"
REAL_ALERT=1 HARNESS="$H" FIXNOW="$FIXNOW" bash "$H/bin/ph-driver.sh" 2>>"$H/drive.err"
n=$(grep -c '^ph-spendp99_lane_fly-pool	' "$H/emit.rec" 2>/dev/null); n=${n:-0}
[ "$n" = 1 ] && ok || bad "P4 want one alert_emit for spendp99:lane:fly-pool over two runs, got $n err=[$(cat "$H/drive.err")]"

# --- P7: a settings row moves the multiplier -------------------------------------------------
fresh; today 300; echo 'SPEND_ALERT_P99_MULT=3' > "$H/knobs"
drive
[ "$(nkey 'spendp99:lane:fly-pool')" = 0 ] && ok || bad "P7 SPEND_ALERT_P99_MULT=3 (line \$360) still alerted at \$300"

# --- P8: an unreadable cost_rows is noeval, never \$0 and never an alert per lane ------------
fresh; today 300; touch "$H/fetch-fail"
drive
[ "$(nkey 'spendalertnoeval:fleet')" = 1 ] && ok || bad "P8 want one spendalertnoeval:fleet alert, got $(nkey 'spendalertnoeval:fleet')"
grep -q '^spendp99:' "$H/alerts.rec" 2>/dev/null && bad "P8 a failed read raised a spendp99 alert" || ok
ls "$H/state/spend-alerts"/baseline-*.tsv >/dev/null 2>&1 && bad "P8 a failed read wrote a baseline file" || ok

# --- P9: one baseline fetch a UTC day; an older baseline is pruned ----------------------------
fresh; today 10; mkdir -p "$H/state/spend-alerts"; echo stale > "$H/state/spend-alerts/baseline-20261007.tsv"
drive
[ -f "$H/state/spend-alerts/baseline-20261008.tsv" ] && ok || bad "P9 no baseline-20261008.tsv after a run"
[ ! -e "$H/state/spend-alerts/baseline-20261007.tsv" ] && ok || bad "P9 yesterday's baseline was not pruned"
n1=$(wc -l < "$H/fetch.rec" 2>/dev/null | tr -d ' ')
rm -f "$H/state/spend-alerts.stamp"; drive
n2=$(wc -l < "$H/fetch.rec" 2>/dev/null | tr -d ' ')
[ "$n1" = 2 ] && [ "$n2" = 3 ] && ok || bad "P9 want 2 fetches then 1 more (today only); got $n1 then $n2 [$(cat "$H/fetch.rec" 2>/dev/null)]"

# --- the stamp: inside the interval the block does nothing -------------------------------------
fresh; today 300; mkdir -p "$H/state"; echo "$FIXNOW" > "$H/state/spend-alerts.stamp"
drive
[ ! -s "$H/fetch.rec" ] && ok || bad "a run inside SPEND_ALERT_INTERVAL_S fetched cost_rows"

echo "spend-alerts.bh-5526: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
