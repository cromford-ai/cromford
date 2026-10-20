#!/bin/bash
# tests/hub-load-shed-knobs.bh-7659-test.sh — BH-7659: the hub load shed knobs
# are settings rows (DB first, env, then the code value), the shed lane list
# travels in the verdict file, and POOL_TICK_MAX_PARALLEL 0 = no cap.
#
#   K1  the seed fragment: 3 rows, an operator's row survives a re-apply
#   K2  hub_load.verdict_max_age_s: row -> env -> 1800
#   K3  hub_load.shed: row -> env -> on
#   K4  hub_load.shed_lanes: row (comma or space) -> env; bad rows skipped
#   K5  the catalog rung: every `sheds: true` lane of the registry
#   K6  the default rung: HLS_SPAWN_LANES, no registry
#   K7  hls_write / hls_over round trip of lanes= and lanes_src=
#   K8  hls_lane_sheds precedence
#   K9  bin/project-lane-run.sh sheds the verdict's list, not the constant
#   K10 bin/fly-pool-tick.sh: 0 = no cap, unset = nproc; the registry agrees
#   K11 the composed registry carries the three hub-load-sample knobs
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hub-load-shed-knobs.bh-7659-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }

NOW=1791000300          # 2026-10-03T04:05:00Z
export HUB_LOAD_SHED_NOW=$NOW
unset LANE_REGISTRY HUB_LOAD_SHED_LANES HUB_LOAD_SHED HUB_LOAD_VERDICT_MAX_AGE_S
LIB="$REPO/bin/lib/hub-load-shed.sh"
SEED="$REPO/worker/jobs/schema.d/202610201115-bh-7659-hub-load-shed-knobs.sql"
ALL7="alert-triage,alerts-medic,blocked-resolver,review-autopilot,review-rescue,stranded-watch,watchdog-responder"

# ══ K1: the seed fragment ═══════════════════════════════════════════════════
echo "K1 seed"
if [ ! -s "$SEED" ]; then
  bad "K1 missing $SEED"
elif ! python3 -I -c 'import sqlite3' 2>/dev/null; then
  echo "K1 skipped: python3 sqlite3 missing"
else
  HARNESS_TEST_SANDBOX=1 bash "$REPO/bin/schema-build.sh" --root "$REPO" --worker jobs --to "$T/schema.sql" >/dev/null 2>&1 \
    || bad "K1 bin/schema-build.sh --to failed"
  grep -qF "hub_load.shed_lanes" "$T/schema.sql" 2>/dev/null && ok "K1 the composed schema carries the fragment" \
    || bad "K1 the composed schema lacks the fragment"
  GOT=$(python3 -I - "$T/schema.sql" "$SEED" <<'PY' 2>&1
import sqlite3, sys
db = sqlite3.connect(":memory:")
db.executescript(open(sys.argv[1]).read())
q = "SELECT key, value FROM settings WHERE key IN ('hub_load.verdict_max_age_s','hub_load.shed','hub_load.shed_lanes') ORDER BY key"
a = " ".join(k + "=" + v for k, v in db.execute(q))
db.execute("UPDATE settings SET value='off' WHERE key='hub_load.shed'")
db.executescript(open(sys.argv[2]).read())
b = " ".join(k + "=" + v for k, v in db.execute(q))
print(a + " | " + b)
PY
)
  check "K1 three seed rows, then hub_load.shed=off survives a re-apply ($GOT)" \
    '[ "$GOT" = "hub_load.shed=on hub_load.shed_lanes=catalog hub_load.verdict_max_age_s=1800 | hub_load.shed=off hub_load.shed_lanes=catalog hub_load.verdict_max_age_s=1800" ]'
  grep -qiE '^[[:space:]]*(drop|alter|delete|update|create)[[:space:]]' "$SEED" \
    && bad "K1 the seed fragment holds DDL or a destructive statement" || ok "K1 the seed fragment is INSERT OR IGNORE only"
fi

# ══ K2-K6: the sampler resolves the three values ════════════════════════════
echo "K2-K6 sampler"
SH="$T/s"
mkdir -p "$SH/bin" "$SH/logs" "$SH/locks" "$SH/state" "$SH/env" "$SH/flags"
for L in bin/hub-load-sample.sh bin/jobs-client.sh bin/lane-alert.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$SH" ) >/dev/null 2>&1 || bad "K setup: could not install $L"
done
chmod +x "$SH/bin/"*.sh 2>/dev/null
# setting_get answers from $SH/rows (key<TAB>value); a key with value RC1 is a
# failed read. No network: the stub replaces the real client.
cat > "$SH/bin/jobs-client.sh" <<EOF
_jobs_box_name() { printf hub; }
setting_get() {
  local v; v=\$(awk -F '\t' -v k="\$1" '\$1 == k { print \$2; f = 1; exit } END { exit !f }' "$SH/rows" 2>/dev/null) || return 2
  [ "\$v" = RC1 ] && return 1
  printf '%s\n' "\$v"
}
job_ledger_put() { return 0; }
EOF
STUB="$T/stub"; mkdir -p "$STUB"
printf '#!/bin/bash\ncat "%s/tests/fixtures/hub-load/ps-dump.txt"\n' "$REPO" > "$STUB/ps"
printf '#!/bin/bash\ncat "%s/tests/fixtures/hub-load/vmstat.txt"\n' "$REPO" > "$STUB/vmstat"
printf '#!/bin/bash\nexit 0\n' > "$STUB/sleep"
chmod +x "$STUB/"*
SLOG="$SH/logs/hub-load-sample.log"; SV="$SH/state/hub-load/verdict"
TSV="$SH/state/hub-load/2026-10-03.tsv"
# rows <key=value>... — the settings the stub answers this run
rows() { local kv; : > "$SH/rows"; for kv in "$@"; do printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$SH/rows"; done; }
# srun [VAR=value]... — one sampler run with an over history (p90 20 > 8)
srun() {
  scratch_rm "$SH/state/hub-load"; mkdir -p "$SH/state/hub-load"; : > "$SLOG"
  local i; for i in 1 2 3 4 5; do
    printf '2026-10-03T03:%02d:00Z\trunnable=20\tsteal=10\tforks_s=50.0\tcpu=us:1\tsamples=30/30\tx.sh=100.0\n' "$i" >> "$TSV"
  done
  env -u LANE_REGISTRY -u HUB_LOAD_SHED_LANES -u HUB_LOAD_SHED -u HUB_LOAD_VERDICT_MAX_AGE_S \
    PATH="$STUB:$PATH" HARNESS="$SH" HUB_LOAD_NOW="$NOW" HUB_LOAD_SAMPLES=1 HUB_LOAD_INTERVAL_S=0 \
    HUB_LOAD_FORK_WINDOW_S=0 BOX_NAME=hub "$@" "$SH/bin/hub-load-sample.sh" > "$T/srun.out" 2>&1
}
vfield() { tr '\t' '\n' 2>/dev/null < "$SV" | awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'; }
last() { tail -1 "$SLOG"; }

# K2 max age
rows hub_load.verdict_max_age_s=900; srun
check "K2 row 900: verdict max_age_s=900, summary max_age_s=900(row) ($(last))" \
  '[ "$(vfield max_age_s)" = 900 ] && [[ "$(last)" == *" max_age_s=900(row) "* ]]'
rows hub_load.verdict_max_age_s=abc; srun HUB_LOAD_VERDICT_MAX_AGE_S=1200
check "K2 row abc, env 1200: 1200(env)" '[ "$(vfield max_age_s)" = 1200 ] && [[ "$(last)" == *" max_age_s=1200(env) "* ]]'
rows; srun HUB_LOAD_VERDICT_MAX_AGE_S=0
check "K2 no row, env 0 (not positive): 1800(default)" '[ "$(vfield max_age_s)" = 1800 ] && [[ "$(last)" == *" max_age_s=1800(default) "* ]]'
rows; srun
check "K2 no row, no env: 1800(default) ($(last))" '[ "$(vfield max_age_s)" = 1800 ] && [[ "$(last)" == *" max_age_s=1800(default) "* ]]'

# K3 shed switch
rows hub_load.shed=on; srun HUB_LOAD_SHED=off
check "K3 row on beats env off: shed=1" '[ "$(vfield shed)" = 1 ] && [[ "$(last)" == *" shed=over(verdict=written)" ]]'
rows hub_load.shed=FALSE; srun
check "K3 row FALSE: shed=0, summary ends shed=off(verdict=written)" '[ "$(vfield shed)" = 0 ] && [[ "$(last)" == *" shed=off(verdict=written)" ]]'
rows; srun HUB_LOAD_SHED=false
check "K3 no row, env false: shed=0 ($(last))" '[ "$(vfield shed)" = 0 ] && [[ "$(last)" == *" shed=off(verdict=written)" ]]'
rows hub_load.shed=RC1; srun HUB_LOAD_SHED=0
check "K3 row read fails (rc 1), env 0: shed=0" '[ "$(vfield shed)" = 0 ]'
rows; srun
check "K3 no row, no env: shed=1" '[ "$(vfield shed)" = 1 ] && [[ "$(last)" == *" shed=over(verdict=written)" ]]'

# K4 shed lanes from the row or the env
rows hub_load.shed_lanes=alert-triage,review-rescue; srun HUB_LOAD_SHED_LANES=x
check "K4 row: lanes=alert-triage,review-rescue lanes_src=row ($(cat "$SV"))" \
  '[ "$(vfield lanes)" = alert-triage,review-rescue ] && [ "$(vfield lanes_src)" = row ] && [[ "$(last)" == *" shed_lanes=2(row) shed="* ]]'
rows "hub_load.shed_lanes=alert-triage  review-rescue"; srun
check "K4 row with spaces: lanes=alert-triage,review-rescue (row)" '[ "$(vfield lanes)" = alert-triage,review-rescue ] && [ "$(vfield lanes_src)" = row ]'
rows hub_load.shed_lanes=catalog; srun "HUB_LOAD_SHED_LANES=x y"
check "K4 row catalog, env 'x y': lanes=x,y lanes_src=env" '[ "$(vfield lanes)" = x,y ] && [ "$(vfield lanes_src)" = env ] && [[ "$(last)" == *" shed_lanes=2(env) "* ]]'
rows "hub_load.shed_lanes= CATALOG "; srun HUB_LOAD_SHED_LANES=x
check "K4 row ' CATALOG ': next rung (env)" '[ "$(vfield lanes)" = x ] && [ "$(vfield lanes_src)" = env ]'
rows "hub_load.shed_lanes=bad id!"; srun HUB_LOAD_SHED_LANES=x
check "K4 row 'bad id!': not the row, env answers" '[ "$(vfield lanes)" = x ] && [ "$(vfield lanes_src)" = env ]'
rows "hub_load.shed_lanes=a;b"; srun HUB_LOAD_SHED_LANES=x
check "K4 row 'a;b': not the row, never part of it" '[ "$(vfield lanes)" = x ] && [ "$(vfield lanes_src)" = env ]'
rows "hub_load.shed_lanes=$(seq -s, -f 'l%g' 1 65)"; srun HUB_LOAD_SHED_LANES=x
check "K4 row with 65 ids: not the row" '[ "$(vfield lanes)" = x ] && [ "$(vfield lanes_src)" = env ]'
rows hub_load.shed_lanes=RC1; srun HUB_LOAD_SHED_LANES=x
check "K4 row read fails (rc 1): env answers" '[ "$(vfield lanes)" = x ] && [ "$(vfield lanes_src)" = env ]'
rows "hub_load.shed_lanes=$(seq -s, -f 'l%g' 1 64)"; srun
check "K4 row with 64 ids: the row" '[ "$(vfield lanes_src)" = row ] && [[ "$(last)" == *" shed_lanes=64(row) "* ]]'

# K5 the catalog rung
REG="$T/reg.json"
jq -n '{lanes: [{id: "a-lane", sheds: true}, {id: "c-lane", sheds: false, sheds_why: "x"},
                {id: "b-lane"}, {id: "new-lane", sheds: true}, {id: "s-lane", sheds: "true"}]}' > "$REG"
rows hub_load.shed_lanes=catalog; srun LANE_REGISTRY="$REG"
check "K5 catalog: lanes=a-lane,new-lane lanes_src=catalog ($(cat "$SV"))" \
  '[ "$(vfield lanes)" = a-lane,new-lane ] && [ "$(vfield lanes_src)" = catalog ] && [[ "$(last)" == *" shed_lanes=2(catalog) "* ]]'
rows; srun LANE_REGISTRY="$REG" HUB_LOAD_SHED_LANES=
check "K5 no row, empty env: catalog" '[ "$(vfield lanes_src)" = catalog ]'
jq -n '{lanes: [{id: "a-lane"}]}' > "$T/reg0.json"
rows; srun LANE_REGISTRY="$T/reg0.json"
check "K5 a registry with no sheds lane: default" '[ "$(vfield lanes_src)" = default ] && [ "$(vfield lanes)" = "$ALL7" ]'

# K6 the default rung: the scratch tree has no catalog/ and no LANE_REGISTRY
rows; srun
check "K6 no row, no env, no registry: lanes=HLS_SPAWN_LANES lanes_src=default ($(cat "$SV"))" \
  '[ "$(vfield lanes)" = "$ALL7" ] && [ "$(vfield lanes_src)" = default ] && [[ "$(last)" == *" shed_lanes=7(default) shed=over(verdict=written)" ]]'
check "K6 summary keeps keep_days and max_runnable" '[[ "$(last)" == *" keep_days=14(default) max_runnable=8(default) max_age_s="* ]]'
( . "$LIB"; hls_over "$SH" && [ "$HLS_LANES" = "${ALL7//,/ }" ] && [ "$HLS_LANES_SRC" = default ] ) \
  && ok "K6 hls_over reads the sampler's own file" || bad "K6 hls_over on the sampler's file"

# ══ K7: round trip ══════════════════════════════════════════════════════════
echo "K7 round trip"
LH="$T/l"; VF="$LH/state/hub-load/verdict"; mkdir -p "$LH/state/hub-load"
(
  . "$LIB" || exit 1
  hls_write "$VF" "$NOW" 9 9 8 over 1800 1 a-lane,new-lane catalog || { echo "FAIL write"; exit 1; }
  [ "$(cat "$VF")" = "$(printf 'v=1\tat=%s\trunnable=9\tp90=9\tmax=8\tstate=over\tmax_age_s=1800\tshed=1\tlanes=a-lane,new-lane\tlanes_src=catalog' "$NOW")" ] \
    || { echo "FAIL line: $(cat "$VF")"; exit 1; }
  hls_over "$LH" && [ "$HLS_LANES" = "a-lane new-lane" ] && [ "$HLS_LANES_SRC" = catalog ] || { echo "FAIL read $HLS_WHY '$HLS_LANES'"; exit 1; }
) > "$T/k7a" 2>&1 && ok "K7 10-arg write, read back HLS_LANES and HLS_LANES_SRC" || bad "K7 round trip: $(cat "$T/k7a")"
(
  . "$LIB" || exit 1
  rm -f "$VF"
  hls_write "$VF" "$NOW" 9 9 8 over 1800 1 'a;b' row && exit 1
  [ ! -e "$VF" ] || exit 1
  hls_write "$VF" "$NOW" 9 9 8 over 1800 1 a-lane bogus && exit 1
  [ ! -e "$VF" ] || exit 1
  hls_write "$VF" "$NOW" 9 9 8 over 1800 1 a-lane && exit 1
  [ ! -e "$VF" ]
) && ok "K7 a bad lanes arg, a bad src, a lone 9th arg: rc 1, no file" || bad "K7 hls_write accepted a bad pair"
(
  . "$LIB" || exit 1
  printf 'v=1\tat=%s\trunnable=9\tp90=9\tmax=8\tstate=over\tmax_age_s=1800\tshed=1\n' "$NOW" > "$VF"
  hls_over "$LH" && [ -z "$HLS_LANES" ] && [ -z "$HLS_LANES_SRC" ] && [ "$HLS_LINE" = "load-shed p90=9 max=8" ] || exit 1
  printf 'v=1\tat=%s\trunnable=9\tp90=9\tmax=8\tstate=under\tmax_age_s=1800\tshed=1\n' "$NOW" > "$VF"
  ! hls_over "$LH" && [ "$HLS_WHY" = under ] && [ -z "$HLS_LANES" ]
) && ok "K7 a BH-7509 8-field line: rc and HLS_WHY as before, HLS_LANES empty" || bad "K7 old line"
(
  . "$LIB" || exit 1
  printf 'v=1\tat=%s\trunnable=9\tp90=9\tmax=8\tstate=over\tmax_age_s=1800\tshed=1\tlanes=bad;id\tlanes_src=row\n' "$NOW" > "$VF"
  hls_over "$LH" && [ -z "$HLS_LANES" ] && [ -z "$HLS_LANES_SRC" ]
) && ok "K7 lanes=bad;id: still over, the field ignored" || bad "K7 a bad lanes field changed the decision or leaked"
(
  . "$LIB" || exit 1
  hls_write "$VF" "$NOW" 9 9 8 over 1800 1 a-lane row
  hls_over "$LH" && [ "$HLS_LANES" = a-lane ]
  printf 'v=1\tat=%s\trunnable=9\tp90=9\tmax=8\tstate=over\tmax_age_s=1800\tshed=1\n' "$NOW" > "$VF"
  hls_over "$LH" && [ -z "$HLS_LANES" ]
) && ok "K7 a second read clears the last file's HLS_LANES" || bad "K7 HLS_LANES leaked from the last read"

# ══ K8: hls_lane_sheds precedence ═══════════════════════════════════════════
echo "K8 hls_lane_sheds"
(
  . "$LIB" || exit 1
  r() { if hls_lane_sheds "$1"; then echo 0; else echo 1; fi; }
  HLS_LANES="new-lane review-rescue"; HUB_LOAD_SHED_LANES="env-lane"
  [ "$(r new-lane)" = 0 ] || { echo "HLS_LANES lane"; exit 1; }
  [ "$(r env-lane)" = 1 ] || { echo "HLS_LANES must beat env"; exit 1; }
  [ "$(r review)" = 1 ] || { echo "prefix review"; exit 1; }
  [ "$(r alert-triage)" = 1 ] || { echo "constant must not apply"; exit 1; }
  [ "$(r '')" = 1 ] || { echo "empty lane"; exit 1; }
  HLS_LANES=""
  [ "$(r env-lane)" = 0 ] || { echo "env when HLS_LANES empty"; exit 1; }
  [ "$(r alert-triage)" = 1 ] || { echo "env replaces the constant"; exit 1; }
  HUB_LOAD_SHED_LANES=""
  [ "$(r alert-triage)" = 0 ] || { echo "constant"; exit 1; }
  [ "$(r new-lane)" = 1 ] || { echo "constant lacks new-lane"; exit 1; }
  unset HLS_LANES
  [ "$(r stranded-watch)" = 0 ] || { echo "unset HLS_LANES"; exit 1; }
) > "$T/k8" 2>&1 && ok "K8 HLS_LANES > HUB_LOAD_SHED_LANES > HLS_SPAWN_LANES, exact ids" || bad "K8 $(cat "$T/k8")"

# ══ K9: project-lane-run.sh uses the verdict's list ═════════════════════════
echo "K9 project-lane-run"
PH="$T/p"
mkdir -p "$PH/bin" "$PH/logs" "$PH/locks" "$PH/state/hub-load" "$PH/env" "$PH/flags"
for L in bin/project-lane-run.sh bin/lib/project-lanes.sh bin/fleet-conf.sh bin/lib/gh-app-auth.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$PH" ) >/dev/null 2>&1 || bad "K9 setup: could not install $L"
done
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$PH/fleet.conf"
printf '#!/bin/bash\necho "$1" >> "%s/p-runs"\n' "$T" > "$PH/bin/fake-lane.sh"
chmod +x "$PH/bin/"*.sh
printf 'v=1\tat=%s\trunnable=80\tp90=80\tmax=8\tstate=over\tmax_age_s=1800\tshed=1\tlanes=new-lane\tlanes_src=catalog\n' "$NOW" > "$PH/state/hub-load/verdict"
prun() { : > "$T/p-runs"; ( export HARNESS="$PH" FLEET_CONF="$PH/fleet.conf" GH_TOKEN=tok-fixture-1; unset HUB_LOAD_SHED_LANES
  bash "$PH/bin/project-lane-run.sh" "$1" p1 0 "$PH/bin/fake-lane.sh" > "$T/p.out" 2>&1 ); }
prun new-lane
check "K9 lanes=new-lane: new-lane starts no run, one load-shed line ($(cat "$T/p.out"))" \
  '[ "$(grep -c . "$T/p-runs")" = 0 ] && [ "$(cnt "new-lane: load-shed p90=80 max=8" "$T/p.out")" = 1 ]'
prun alert-triage
check "K9 lanes=new-lane: alert-triage (not in the list) runs once" '[ "$(grep -c . "$T/p-runs")" = 1 ] && [ "$(cnt load-shed "$T/p.out")" = 0 ]'

# ══ K10: POOL_TICK_MAX_PARALLEL ═════════════════════════════════════════════
echo "K10 fly-pool-tick"
TH="$T/t"
mkdir -p "$TH/bin" "$TH/flags" "$TH/logs" "$TH/locks" "$TH/env" "$TH/state/fly-pool" "$T/nproc2" "$T/nproc0"
for L in bin/fly-pool-tick.sh bin/pool-cap.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$TH" ) >/dev/null 2>&1 || bad "K10 setup: could not install $L"
done
printf '#!/bin/bash\nexit 0\n' > "$TH/bin/fly-lock-guard.sh"
printf '#!/bin/bash\nexit 0\n' > "$TH/bin/beat.sh"
: > "$TH/env/global.env"
printf '#!/bin/bash\necho "$1" >> "%s/ticked.txt"\nexit 0\n' "$TH" > "$TH/bin/fly-pool.sh"
printf '#!/bin/bash\necho 2\n' > "$T/nproc2/nproc"
printf '#!/bin/bash\nexit 1\n' > "$T/nproc0/nproc"
chmod +x "$TH/bin/"*.sh "$T/nproc2/nproc" "$T/nproc0/nproc"
for p in a b c; do : > "$TH/flags/fly-pool-$p"; done
TLOG="$TH/logs/fly-pool.log"
# trun <nproc dir> [VAR=value]... — one tick start, POOL_TICK_MAX_PARALLEL unset unless given
trun() { local np="$1"; shift; : > "$TH/ticked.txt"; : > "$TLOG"; scratch_rm "$TH/state/fly-pool-tick"
  ( unset POOL_TICK_MAX_PARALLEL; export HARNESS="$TH" POOL_TICK_WAIT_S=3 PATH="$np:$PATH" "$@"
    timeout 30 bash "$TH/bin/fly-pool-tick.sh" >> "$T/t.out" 2>&1 ); }
ticked() { grep -c . "$TH/ticked.txt"; }
trun "$T/nproc2" POOL_TICK_MAX_PARALLEL=0
check "K10 0 with nproc 2: 3 of 3 ticked, 0 max-ticks lines ($(ticked), $(cnt max-ticks "$TLOG"))" '[ "$(ticked)" = 3 ] && [ "$(cnt max-ticks "$TLOG")" = 0 ]'
trun "$T/nproc2"
check "K10 unset with nproc 2: 2 ticked, one max-ticks line" '[ "$(ticked)" = 2 ] && [ "$(cnt "of 2 running — c waits" "$TLOG")" = 1 ]'
trun "$T/nproc2" POOL_TICK_MAX_PARALLEL=
check "K10 empty with nproc 2: 2 ticked" '[ "$(ticked)" = 2 ]'
trun "$T/nproc2" POOL_TICK_MAX_PARALLEL=abc
check "K10 abc (no digits) with nproc 2: 2 ticked" '[ "$(ticked)" = 2 ]'
trun "$T/nproc2" POOL_TICK_MAX_PARALLEL=1
check "K10 1: 1 ticked" '[ "$(ticked)" = 1 ]'
trun "$T/nproc0"
check "K10 unset, nproc unreadable: no cap, 3 ticked" '[ "$(ticked)" = 3 ] && [ "$(cnt max-ticks "$TLOG")" = 0 ]'
PT="$REPO/catalog/lanes.d/fly-pool-tick.knobs.d/POOL_TICK_MAX_PARALLEL.json"
check "K10 POOL_TICK_MAX_PARALLEL.json: zero_means unlimited, default null" \
  'jq -e ".zero_means == \"unlimited\" and .default == null" "$PT" >/dev/null 2>&1'

# ══ K11: the registry knobs ═════════════════════════════════════════════════
echo "K11 registry"
REGP=$(cd "$REPO" && env -u LANE_REGISTRY bash -c '. bin/lib/lanes-registry.sh && lanes_json_path "$PWD"' 2>/dev/null)
for kv in HUB_LOAD_VERDICT_MAX_AGE_S:hub_load.verdict_max_age_s HUB_LOAD_SHED:hub_load.shed HUB_LOAD_SHED_LANES:hub_load.shed_lanes; do
  E=${kv%%:*}; K=${kv#*:}
  check "K11 hub-load-sample knob $E: not settable, read in the sampler, names $K" \
    'jq -e --arg e "$E" --arg k "$K" "[.lanes[] | select(.id == \"hub-load-sample\") | .knobs[] | select(.env == \$e)
       | select(.settable == false and .read_in == \"bin/hub-load-sample.sh\" and (.note | contains(\$k)))] | length == 1" "$REGP" >/dev/null 2>&1'
done

echo
echo "hub-load-shed-knobs: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
