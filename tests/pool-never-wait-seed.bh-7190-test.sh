#!/bin/bash
# tests/pool-never-wait-seed.bh-7190-test.sh — the "never wait" settings rows for
# the project-6-os and cromford pools, and the docs page that lists every
# knob that can hold a build (BH-7190).
#
# 1. bin/pool-never-wait-seed.sh is a dry run by default, writes exactly the
#    rows it prints with --apply, and writes nothing the second time.
# 2. Every row is a legal settings key and sits inside the knob registry bounds,
#    so the lane never clamps what the seed wrote.
# 3. docs/FLY-POOL.md names every knob in the audit list and every seeded row.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin"
scratch_install_closure bin/pool-never-wait-seed.sh "$H" >/dev/null
: > "$H/rows.tsv"
cat > "$H/bin/jobs-client.sh" <<'JC'
#!/bin/bash
case "${1:-}" in
  setting-get) v=$(awk -F'\t' -v k="$2" '$1==k{print $2; f=1} END{exit !f}' "$HARNESS/rows.tsv") || exit 2; printf '%s\n' "$v" ;;
  setting-set) [ -f "$HARNESS/FAILSET" ] && exit 1
               grep -v -P "^\Q$2\E\t" "$HARNESS/rows.tsv" > "$HARNESS/rows.new" 2>/dev/null; printf '%s\t%s\n' "$2" "$3" >> "$HARNESS/rows.new"; mv "$HARNESS/rows.new" "$HARNESS/rows.tsv" ;;
  *) exit 1 ;;
esac
JC
chmod +x "$H/bin/jobs-client.sh"
seed() { ( export HARNESS="$H"; bash "$H/bin/pool-never-wait-seed.sh" "$@" 2>&1 ); }

# ── 1: dry run, apply, re-apply ─────────────────────────────────────────────
out=$(seed)
[ "$(grep -c '^PLAN ' <<<"$out")" = 9 ] && ok || bad "1a: want 9 PLAN lines, got: $out"
[ ! -s "$H/rows.tsv" ] && ok || bad "1b: the dry run wrote rows"
out=$(seed --apply)
[ "$(grep -c '^SET ' <<<"$out")" = 9 ] && ok || bad "1c: want 9 SET lines, got: $out"
[ "$(wc -l < "$H/rows.tsv" | tr -d ' ')" = 9 ] && ok || bad "1d: want 9 rows, got $(wc -l < "$H/rows.tsv")"
out=$(seed --apply)
[ "$(grep -c '^SAME ' <<<"$out")" = 9 ] && [ "$(grep -c '^SET ' <<<"$out")" = 0 ] && ok || bad "1e: re-apply must change nothing: $out"
get() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$H/rows.tsv"; }
for p in project-6-os cromford; do
  [ "$(get lane.fly-pool.$p.pool_cap)" = 0 ] && ok || bad "1f: $p pool_cap row is not 0"
  [ "$(get lane.fly-pool.$p.pool_spawn_cap_per_key)" -ge 12 ] 2>/dev/null && ok || bad "1g: $p spawn cap row missing or below the fleet value 12"
  [ "$(get lane.fly-pool.$p.pool_machine_hours_daily)" -gt 0 ] 2>/dev/null && ok || bad "1h: $p has no machine-hour budget row"
done
: > "$H/rows.tsv"; : > "$H/FAILSET"
out=$(seed --apply); rc=$?
[ "$rc" = 1 ] && grep -q '^FAILED ' <<<"$out" && ok || bad "1i: a failed write must say FAILED and exit 1 (rc=$rc): $out"
scratch_rm "$H/FAILSET"
out=$(seed --bogus); rc=$?
[ "$rc" = 2 ] && ok || bad "1j: unknown flag must exit 2, got $rc"

# ── 2: legal keys, inside the registry bounds ───────────────────────────────
knob_json() { # knob_json <ENV> -> the knob object from the fly-pool or jobs-watchdog registry
  local env="$1" f
  f="$DIR/catalog/lanes.d/fly-pool.knobs.d/$env.json"
  [ -f "$f" ] && { cat "$f"; return; }
  jq -c --arg e "$env" '.knobs[]? | select(.env==$e)' "$DIR/catalog/lanes.d/fly-pool.json" "$DIR/catalog/lanes.d/jobs-watchdog.json" | head -1
}
seed --apply >/dev/null
while IFS=$'\t' read -r key val; do
  [[ "$key" =~ ^[a-z0-9_.-]{1,64}$ ]] && ok || bad "2a: illegal settings key '$key'"
  env=$(printf '%s' "${key##*.}" | tr '[:lower:]' '[:upper:]')
  kj=$(knob_json "$env")
  [ -n "$kj" ] && ok || { bad "2b: no knob $env registered for row $key"; continue; }
  mn=$(jq -r '.min // empty' <<<"$kj"); mx=$(jq -r '.max // empty' <<<"$kj")
  if [ -n "$mn" ] && awk -v v="$val" -v m="$mn" 'BEGIN{exit !(v<m)}'; then bad "2c: $key=$val is below the registry min $mn"; else ok; fi
  if [ -n "$mx" ] && awk -v v="$val" -v m="$mx" 'BEGIN{exit !(v>m)}'; then bad "2d: $key=$val is above the registry max $mx"; else ok; fi
done < "$H/rows.tsv"

# ── 3: the docs page lists every knob and every seeded row ──────────────────
DOC="$DIR/docs/FLY-POOL.md"
[ -f "$DOC" ] && ok || bad "3a: docs/FLY-POOL.md is missing"
for k in POOL_CAP POOL_CAP_MAX POOL_SPAWN_CAP_PER_KEY POOL_SPAWN_CAP_WINDOW_S JOBS_QUEUE_DEFER_MAX \
         POOL_LANE_FAIL_HOLD_S POOL_AFTER_MAX_MIN POOL_MACHINE_HOURS_DAILY POOL_BUDGET_ALERT_PCT \
         POOL_STALL_ALERT_S POOL_AUTOSCALE POOL_SPAWN BUILD_SLOTS FLY_DISPATCH_WIP \
         concurrency_rules fly/pool-caps.conf flags/fly-pool- flags/wip-limit- fleet.conf; do
  grep -qF -- "$k" "$DOC" 2>/dev/null && ok || bad "3b: docs/FLY-POOL.md does not name $k"
done
while IFS=$'\t' read -r key val; do
  grep -qF -- "$key" "$DOC" 2>/dev/null && ok || bad "3c: docs/FLY-POOL.md does not list the row $key"
done < "$H/rows.tsv"
grep -qE 'per machine-hour|/machine-hour|per hour' "$DOC" 2>/dev/null && ok || bad "3d: the page states no cost per machine-hour"
# Every ENV knob the page puts in backticks with POOL_/JOBS_ must exist in the registry.
for k in $(grep -oE '`(POOL|JOBS)_[A-Z0-9_]+`' "$DOC" 2>/dev/null | tr -d '`' | sort -u); do
  if [ -n "$(knob_json "$k")" ] || grep -rqF "\"$k\"" "$DIR/catalog/lanes.d" 2>/dev/null; then ok; else bad "3e: $k is named in the docs but is in no registry"; fi
done

echo "pool-never-wait-seed: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
