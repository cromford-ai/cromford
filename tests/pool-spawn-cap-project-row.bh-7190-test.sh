#!/bin/bash
# tests/pool-spawn-cap-project-row.bh-7190-test.sh — a per-project settings row
# lane.fly-pool.<project>.pool_spawn_cap_per_key decides the per-key spawn cap
# for that project (BH-7190). Before this, only the fleet-wide row
# pool_spawn_cap_per_key was read, so a per-project value was inert.
#
# Order under test (most specific first):
#   1. lane.fly-pool.<project>.pool_spawn_cap_per_key   (this change)
#   2. pool_spawn_cap_per_key                           (fleet-wide row)
#   3. env POOL_SPAWN_CAP_PER_KEY
#   4. 2
# The function is cut out of bin/fly-pool.sh and run alone: the 4000-line tick
# needs Fly and GitHub, and the cap read needs neither.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"; mkdir -p "$H/bin"
# A jobs-client stand-in: setting-get answers from $H/rows.tsv (key<TAB>value),
# rc 2 for a key with no row, as the real client does.
cat > "$H/bin/jobs-client.sh" <<'JC'
#!/bin/bash
[ "${1:-}" = setting-get ] || exit 1
v=$(awk -F'\t' -v k="$2" '$1==k{print $2; f=1} END{exit !f}' "$HARNESS/rows.tsv" 2>/dev/null) || exit 2
printf '%s\n' "$v"
JC
chmod +x "$H/bin/jobs-client.sh"

# Cut pool_spawn_cap_load (and the per-project reader, if present) out of the tick.
FN="$T/fn.sh"
awk '/^pool_spawn_cap_project_row\(\) \{/,/^}/{print} /^pool_spawn_cap_load\(\) \{/,/^}/{print}' \
  "$DIR/bin/fly-pool.sh" > "$FN"
grep -q '^pool_spawn_cap_load()' "$FN" || { echo "FAIL: pool_spawn_cap_load not found in bin/fly-pool.sh"; exit 1; }

cap_for() { # cap_for <project> <rows> [ENV=VAL...] -> "<cap> <window>"
  local p="$1" rows="$2"; shift 2
  printf '%b' "$rows" > "$H/rows.tsv"
  ( export HARNESS="$H" P="$p"; for kv in "$@"; do export "$kv"; done
    unset POOL_SPAWN_CAP POOL_SPAWN_CAP_WINDOW
    . "$FN"; pool_spawn_cap_load; echo "$POOL_SPAWN_CAP $POOL_SPAWN_CAP_WINDOW" )
}
want() { # want <name> <project> <rows> <expected> [ENV=VAL...]
  local got; got=$(cap_for "$2" "$3" "${@:5}")
  if [ "$got" = "$4" ]; then ok; else bad "$1: got '$got' want '$4'"; fi
}

G='pool_spawn_cap_per_key\t12\n'
PM='lane.fly-pool.project-6-os.pool_spawn_cap_per_key\t50\n'
want "a: project row beats the fleet row"   project-6-os "$PM$G" "50 86400"
want "b: other project keeps the fleet row" project-5    "$PM$G" "12 86400"
want "c: no project row -> fleet row"       project-6-os "$G"    "12 86400"
want "d: no rows -> env"                    project-6-os ""      "7 86400" POOL_SPAWN_CAP_PER_KEY=7
want "e: nothing -> 2"                      project-6-os ""      "2 86400"
want "f: junk project row -> fleet row"    project-6-os 'lane.fly-pool.project-6-os.pool_spawn_cap_per_key\tmany\n'"$G" "12 86400"
want "g: project name that is no legal key" 'Bad Name'   "$PM$G" "12 86400"
want "h: window still read"                 project-6-os "${PM}pool_spawn_cap_window_s\t600\n" "50 600"

echo "pool-spawn-cap-project-row: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
