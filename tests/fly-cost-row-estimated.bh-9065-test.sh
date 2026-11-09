#!/bin/bash
# tests/fly-cost-row-estimated.bh-9065-test.sh — BH-9065: every pool machine
# writes a Fly cost row at reap. A machine the listing no longer has is priced
# from the size the spawn wrote on its machine json (note state=estimated); a
# machine the sweep destroys with no tracking file gets one estimated row from
# Fly's created_at/updated_at.
#
# PINNED:
#   L1-L4  bin/lib/fly-cost-row.sh: fly_size_split, fly_mid_billed, the
#          `estimated` 15th argument of fly_cost_row_once.
#   E1-E5  pool_fly_cost_row (extracted from the real bin/fly-pool.sh).
#   O1-O4  pool_fly_orphan_cost_row (extracted the same way).
#   D1-D2  DRIVEN (`bash bin/fly-pool.sh project-5`, fake fly): the sweep bills
#          a stopped orphan before it destroys it, once.
# Run from anywhere: bash tests/fly-cost-row-estimated.bh-9065-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$DIR/bin/lib/fly-cost-row.sh"
POOLSH="$DIR/bin/fly-pool.sh"
. "$DIR/bin/lib/cost-row.sh" || exit 1
. "$LIB" || exit 1
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
nrows() { python3 - "$1" <<'PY'
import csv, sys, os
p = sys.argv[1]
if not os.path.exists(p): print(0); sys.exit()
print(sum(1 for x in csv.DictReader(open(p)) if x.get("row_source") == "fly-machine"))
PY
}
col() { python3 - "$1" "$2" <<'PY'
import csv, sys
r = [x for x in csv.DictReader(open(sys.argv[1])) if x.get("row_source") == "fly-machine"]
print(r[-1].get(sys.argv[2], "<nocol>") if r else "<norow>")
PY
}
cat > "$T/prices.json" <<'JSON'
{"seconds_per_month": 2628000,
 "cpu_usd_per_core_month": {"shared": 2.0, "performance": 31.0},
 "memory_usd_per_gb_month": 5.0, "volume_usd_per_gb_month": 0.15}
JSON
PR="$T/prices.json"

# ══ L: the lib ══════════════════════════════════════════════════════════════
eq L1a "performance 8" "$(fly_size_split performance-8x)"
eq L1b "shared 2" "$(fly_size_split shared-cpu-2x)"
fly_size_split gpu-a100 >/dev/null && bad "L1c: an unknown size must be rc 1" || ok
fly_size_split performance-x >/dev/null && bad "L1d: a size with no count must be rc 1" || ok
printf 'm1\tBH-1\t2026-10-03 10:00:00Z\n' > "$T/led.tsv"
fly_mid_billed "$T/led.tsv" m1 && ok || bad "L2a: m1 is in the ledger"
fly_mid_billed "$T/led.tsv" m12 && bad "L2b: m12 must not match m1's line" || ok
S0="2026-10-03 10:00:00Z"; E0=$(( $(date -u -d "$S0" +%s) + 3600 ))
fly_cost_row_once "$T/l3.csv" "$T/l3.tsv" proj pool-proj-m3 m3 BH-3 "" r "$S0" "$E0" performance 8 16384 "$PR" estimated >/dev/null
eq L3 "fly:m3:state=estimated" "$(col "$T/l3.csv" note)"
fly_cost_row_once "$T/l4.csv" "$T/l4.tsv" proj pool-proj-m4 m4 BH-4 "" r "$S0" "$E0" performance 8 16384 "$PR" >/dev/null
eq L4 "fly:m4:prices=catalog" "$(col "$T/l4.csv" note)"

# ══ E: pool_fly_cost_row, the reap's call ═══════════════════════════════════
FN=$(sed -n '/^pool_fly_cost_row()/,/^}/p' "$POOLSH")
FO=$(sed -n '/^pool_fly_orphan_cost_row()/,/^}/p' "$POOLSH")
[ -n "$FN" ] && ok || bad "E0: pool_fly_cost_row() not found in $POOLSH"
[ -n "$FO" ] && ok || bad "O0: pool_fly_orphan_cost_row() not found in $POOLSH"
eval "$FN"; eval "$FO"
export HARNESS="$T/h"; mkdir -p "$HARNESS/catalog" "$HARNESS/pool"
cp "$PR" "$HARNESS/catalog/fly-prices.json"
LOG="$T/pool.log"; : > "$LOG"
say() { echo "$*" >> "$LOG"; }
P=proj
LISTING="$T/listing.json"; LIST_OK=1
echo '[{"id":"mlive","config":{"guest":{"cpu_kind":"performance","cpus":8,"memory_mb":16384}}}]' > "$LISTING"
SPAT=$(date -u -d '30 minutes ago' '+%Y-%m-%d %H:%M:%SZ')
ecase() { # ecase <mid> <key> <machine-json> -> sets LOCAL and MF, runs the reap's call
  MID="$1"; KEY="$2"; MF="$HARNESS/pool/$1.json"; printf '%s\n' "$3" > "$MF"
  LOCAL="$T/builds/pool-proj-$2-1"; mkdir -p "$LOCAL"
  pool_fly_cost_row
}
# E1: gone from the listing, the spawn's size on the machine json -> priced, estimated.
ecase m7gone BH-7 '{"machine":"m7gone","vm_class":"compute","vm_size":"performance-8x","vm_mem":"16384"}'
eq "E1 rows" 1 "$(nrows "$LOCAL/cost.csv")"
c=$(col "$LOCAL/cost.csv" cost_usd)
[ -n "$c" ] && awk -v c="$c" 'BEGIN{exit !(c>0)}' && ok || bad "E1 cost must be non-empty and > 0: [$c]"
eq "E1 note" "fly:m7gone:state=estimated" "$(col "$LOCAL/cost.csv" note)"
eq "E1 model" "performance-8x-16384mb" "$(col "$LOCAL/cost.csv" model)"
grep -q 'fly cost row: written m7gone BH-7 .* estimated$' "$LOG" && ok || bad "E1 log: $(cat "$LOG")"
# E2: the next reap of the same job writes no second row.
pool_fly_cost_row
eq "E2 rows" 1 "$(nrows "$LOCAL/cost.csv")"
grep -q 'fly cost row: already m7gone BH-7$' "$LOG" && ok || bad "E2 log: $(tail -1 "$LOG")"
# E3: no size anywhere -> UNPRICED, as before.
ecase m8gone BH-8 '{"machine":"m8gone"}'
eq "E3 cost" "" "$(col "$LOCAL/cost.csv" cost_usd)"
eq "E3 note" "UNPRICED:fly-size-unknown:m8gone" "$(col "$LOCAL/cost.csv" note)"
# E4: the listing has the size -> priced from it, not estimated.
ecase mlive BH-9 '{"machine":"mlive","vm_size":"shared-cpu-1x","vm_mem":"256"}'
eq "E4 note" "fly:mlive:prices=catalog" "$(col "$LOCAL/cost.csv" note)"
eq "E4 model" "performance-8x-16384mb" "$(col "$LOCAL/cost.csv" model)"
# E5: a shared-cpu spawn is priced at the shared rate.
ecase m10gone BH-10 '{"machine":"m10gone","vm_size":"shared-cpu-2x","vm_mem":"4096"}'
eq "E5 model" "shared-2x-4096mb" "$(col "$LOCAL/cost.csv" model)"
eq "E5 note" "fly:m10gone:state=estimated" "$(col "$LOCAL/cost.csv" note)"

# ══ O: pool_fly_orphan_cost_row, the sweep's call ═══════════════════════════
pushed=0; push_pool_cost_rows() { pushed=$((pushed+1)); cp "$1/cost.csv" "$T/orphan-$pushed.csv"; }
CA=$(date -u -d '50 minutes ago' '+%Y-%m-%dT%H:%M:%SZ'); UA=$(date -u -d '20 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')
jq -nc --arg c "$CA" --arg u "$UA" '[{id:"morph1",state:"stopped",created_at:$c,updated_at:$u,config:{guest:{cpu_kind:"performance",cpus:8,memory_mb:16384}}},
  {id:"m7gone",state:"stopped",created_at:$c,updated_at:$u,config:{guest:{cpu_kind:"performance",cpus:8,memory_mb:16384}}}]' > "$LISTING"
pool_fly_orphan_cost_row morph1
eq "O1 pushed" 1 "$pushed"
eq "O1 rows" 1 "$(nrows "$T/orphan-1.csv")"
eq "O1 note" "fly:morph1:state=estimated" "$(col "$T/orphan-1.csv" note)"
eq "O1 ticket" "orphan" "$(col "$T/orphan-1.csv" ticket)"
d=$(col "$T/orphan-1.csv" duration_s)
{ [ "$d" -ge 1795 ] 2>/dev/null && [ "$d" -le 1805 ]; } && ok || bad "O1 duration must be updated_at - created_at (1800 s): [$d]"
# O2: the next sweep tick: no second row.
pool_fly_orphan_cost_row morph1
eq "O2 pushed" 1 "$pushed"
# O3: a machine the reap already billed under its key is not billed again.
pool_fly_orphan_cost_row m7gone
eq "O3 pushed" 1 "$pushed"

# ══ D: driven — the sweep bills a stopped orphan before it destroys it ══════
H="$T/dh"; mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state/fly" "$H/state/fly-pool/project-5" \
  "$H/state/build-queue/project-5" "$H/state/pool/project-5" "$H/catalog" "$T/fakebin"
cp "$PR" "$H/catalog/fly-prices.json"
printf 'FLY_API_TOKEN_project-5=tok-fixture-fly\n' > "$H/env/fly.env"; : > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 boxa 192.0.2.9\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install of bin/jobs-client.sh failed"; exit 1; }
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
for s in flock sleep; do printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/$s"; done
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"
OCA=$(date -u -d '3 hours ago' '+%Y-%m-%dT%H:%M:%SZ'); OUA=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
jq -nc --arg c "$OCA" --arg u "$OUA" '[{id:"0rphan00000001",state:"stopped",created_at:$c,updated_at:$u,config:{guest:{cpu_kind:"performance",cpus:8,memory_mb:16384}}}]' > "$T/fly-list.json"
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "fly \$*" >> "$T/fly.txt"
case "\$*" in
  *"machines list"*|*"machine list"*) cat "$T/fly-list.json" ;;
  *"machine destroy"*) [ -f "$H/state/fly-cost/ledger.tsv" ] && echo "destroy-after-ledger" >> "$T/order.txt" || echo "destroy-before-ledger" >> "$T/order.txt" ;;
esac
exit 0
FLY
chmod +x "$H/bin"/*.sh "$T/fakebin"/*
run_pool() { ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" HARNESS_SECRET=fixture-secret \
    JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
    FLY_API_TOKEN_project-5=tok-fixture-fly FLY_BIN_DIR="$T/fakebin"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 ); }
: > "$T/fly.txt"; : > "$T/order.txt"
run_pool
grep -q 'machine destroy 0rphan00000001' "$T/fly.txt" && ok || bad "D1 precondition: the sweep must destroy the stopped orphan: $(cat "$T/fly.txt") / $(tail -5 "$H/logs/fly-pool.log" 2>/dev/null)"
eq "D1 billed before the destroy" destroy-after-ledger "$(head -1 "$T/order.txt")"
eq "D1 ledger rows" 1 "$(grep -c '^0rphan00000001	orphan	' "$H/state/fly-cost/ledger.tsv" 2>/dev/null)"
grep -q 'fly cost row: written 0rphan00000001 orphan .* estimated' "$H/logs/fly-pool.log" && ok || bad "D1 log: $(grep 'cost row' "$H/logs/fly-pool.log")"
run_pool
eq "D2 still one ledger row" 1 "$(grep -c '^0rphan00000001	' "$H/state/fly-cost/ledger.tsv" 2>/dev/null)"

echo "fly-cost-row-estimated (BH-9065): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
