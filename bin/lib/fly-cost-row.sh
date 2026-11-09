#!/bin/bash
# bin/lib/fly-cost-row.sh — the per-second Fly machine price (BH-4018, split
# child 1 of #3989). Sourced, never executed.
#
# CONTRACT (frozen; the #3989 siblings source it):
#   fly_price_per_s <prices.json> <cpu_kind> <cpus> <memory_mb>
#     -> prints '<usd_per_second> <catalog|fallback>', rc 1 on unknown size
#
# The formula and the fallback table are a deliberate duplicate of poll_fly in
# bin/vendor-spend-pull.sh (its FALLBACK .. MEM_RATE block and the per-machine
# usd line). tests/fly-price.bh-3989-test.sh runs that file's own python against
# this function, so the two cannot drift apart unnoticed.

_FCR_DIR="$(dirname "${BASH_SOURCE[0]}")"
# COST_ROW_HDR / cost_csv_field for the cost-row writer that lands here next.
# Fail-open: pricing does not need them.
# shellcheck source=bin/lib/cost-row.sh
[ -n "${COST_ROW_HDR:-}" ] || . "$_FCR_DIR/cost-row.sh" 2>/dev/null || true

# Harness root, from the caller only. Empty means "no root"; nothing here builds
# a path from it (D43).
_fcr_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# fly_price_per_s <prices.json> <cpu_kind> <cpus> <memory_mb>
# cpus and memory_mb must be numbers > 0: an empty, non-numeric or zero size is
# unknown, so it returns 1 with nothing on stdout and is never priced as $0.
# A missing, unparseable or incomplete catalog prices from the fallback and says
# so in the second field. An empty or unknown cpu_kind takes the shared rate.
fly_price_per_s() {
  local prices="${1:-}" kind="${2:-}" cpus="${3:-}" mem="${4:-}" v out
  for v in "$cpus" "$mem"; do
    [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk "BEGIN{exit !($v>0)}" || return 1
  done
  out=$(python3 - "$prices" "$kind" "$cpus" "$mem" <<'PY' 2>/dev/null
import json, sys
prices_path, kind = sys.argv[1], (sys.argv[2] or "shared").lower()
cpus, mem = float(sys.argv[3]), float(sys.argv[4])
FALLBACK = {"seconds_per_month": 2628000,
            "cpu_usd_per_core_month": {"shared": 2.0, "performance": 31.0},
            "memory_usd_per_gb_month": 5.0, "volume_usd_per_gb_month": 0.15}
src = "catalog"
try:
    P = json.load(open(prices_path))
    for k in FALLBACK:
        if k not in P:
            raise KeyError(k)
except Exception:
    P, src = FALLBACK, "fallback"
SPM = float(P["seconds_per_month"])
def cpu_rate(kind):
    tbl = P["cpu_usd_per_core_month"]
    return float(tbl.get(kind, tbl.get("shared", 2.0))) / SPM
MEM_RATE = float(P["memory_usd_per_gb_month"]) / SPM
usd_s = cpus * cpu_rate(kind) + (mem / 1024.0) * MEM_RATE
print(f"{usd_s:.12f} {src}")
PY
) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fly_size_split <vm-size> -> prints '<cpu_kind> <cpus>' for a Fly size name
# (performance-8x -> 'performance 8', shared-cpu-2x -> 'shared 2'); rc 1 and
# nothing on stdout for any other name (BH-9065).
fly_size_split() {
  case "${1:-}" in
    performance-[0-9]*x) local n="${1#performance-}"; n="${n%x}" ;;
    shared-cpu-[0-9]*x)  local n="${1#shared-cpu-}";  n="${n%x}" ;;
    *) return 1 ;;
  esac
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  case "$1" in performance-*) echo "performance $n" ;; *) echo "shared $n" ;; esac
}

# fly_mid_billed <ledger> <mid> -> rc 0 when the ledger already holds a row for
# <mid> under any key (BH-9065: the orphan sweep must not bill a machine twice).
fly_mid_billed() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -s "$1" ] || return 1
  awk -F'\t' -v m="$2" '$1==m{f=1; exit} END{exit !f}' "$1" 2>/dev/null
}

# fly_cost_row_once <csv> <ledger> <project> <box> <mid> <key> <job_id> <run_id>
#                   <start_ts> <end_epoch> <cpu_kind> <cpus> <mem_mb> <prices>
#                   [estimated]
# A 15th argument `estimated` (BH-9065) marks a row whose size came from the
# pool's own spawn record, or whose interval came from Fly's timestamps rather
# than a tracked job: a priced row's note is then `fly:<mid>:state=estimated`.
# Appends ONE 26-column infra row for a pool machine's job to <csv> (BH-4019,
# split child 2 of #3989), at most once per (mid, key, start_ts): that triple is
# the <ledger> line, matched whole under flock on <ledger>.lock. Row first, then
# ledger. An unknown size writes an empty cost_usd and an UNPRICED note, never $0.
# rc 0 written (stdout '<secs> <cost|unpriced>'), 2 bad input or interval,
# 3 already recorded, 4 lock timeout, 5 no COST_ROW_HDR. Nothing is written on
# any non-zero rc. Every path comes from the caller (D43).
fly_cost_row_once() {
  local csv="${1:-}" ledger="${2:-}" proj="${3:-}" box="${4:-}" mid="${5:-}" key="${6:-}"
  local job="${7:-}" run="${8:-}" start="${9:-}" end="${10:-}" kind="${11:-}" cpus="${12:-}"
  local mem="${13:-}" prices="${14:-}" est="${15:-}" s0 secs
  [ -n "$csv" ] && [ -n "$ledger" ] && [ -n "$mid" ] && [ -n "$key" ] && [ -n "$start" ] || return 2
  [[ "$end" =~ ^[0-9]+$ ]] || return 2
  s0=$(date -u -d "$start" +%s 2>/dev/null) || return 2
  secs=$(( end - s0 ))
  [ "$secs" -gt 0 ] || return 2
  [ -n "${COST_ROW_HDR:-}" ] || return 5
  mkdir -p "$(dirname "$ledger")" "$(dirname "$csv")" || return 2
  (
    flock -w 10 9 || exit 4
    grep -Fqx "$mid"$'\t'"$key"$'\t'"$start" "$ledger" 2>/dev/null && exit 3
    local rate src cost note ts
    if read -r rate src < <(fly_price_per_s "$prices" "$kind" "$cpus" "$mem") && [ -n "$rate" ]; then
      cost=$(awk -v s="$secs" -v r="$rate" 'BEGIN{printf "%.6f", s*r}')
      note="fly:$mid:prices=$src"
      [ "$est" = estimated ] && note="fly:$mid:state=estimated"
    else
      cost=""; note="UNPRICED:fly-size-unknown:$mid"
    fi
    ts=$(date -u -d "@$end" +%Y-%m-%dT%H:%M:%SZ)
    [ -s "$csv" ] || printf '%s\n' "$COST_ROW_HDR" > "$csv"
    local f out="" i=0
    for f in "$ts" "$box" "$proj" infra fly "$kind-${cpus}x-${mem}mb" 0 "$secs" 0 0 0 0 \
             "$cost" metered "" "" "" fly-machine "" "$key" "$job" "" "$run" "$note" "" ""; do
      [ "$i" = 0 ] || out+=","
      out+=$(cost_csv_field "$f"); i=$((i+1))
    done
    printf '%s\n' "$out" >> "$csv" || exit 2
    printf '%s\t%s\t%s\n' "$mid" "$key" "$start" >> "$ledger"
    printf '%s %s\n' "$secs" "${cost:-unpriced}"
  ) 9>"$ledger.lock"
}
