# >>> fleet slot clamp (BH-7877)
# bin/fly-pool-tick.sh writes state/fly-pool-alloc/$P once a tick when the row
# lane.fly-pool.fleet_slots is set (bin/lib/pool-alloc.sh pa_tick). pa_clamp
# lowers BUDGET to that grant's target minus LIVE; it never raises it. No file
# (the row is unset, the default) leaves BUDGET as 3500 set it. HOTFIX_EXTRA
# is not touched: a hotfix row still gets its machine past the share.
# shellcheck source=bin/lib/pool-alloc.sh
. "$HARNESS/bin/lib/pool-alloc.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-alloc.sh" 2>/dev/null || true
if command -v pa_clamp >/dev/null 2>&1; then
  pa_clamp "$P"
  [ "$BUDGET" -gt 0 ] || [ "$HOTFIX_EXTRA" -gt 0 ] || exit 0
fi
# <<< fleet slot clamp
