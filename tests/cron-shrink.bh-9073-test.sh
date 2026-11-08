#!/bin/bash
# tests/cron-shrink.bh-9073-test.sh — BH-9073 (BH-9067.1): no model lane runs
# unconditionally from the rendered crontab. A census model lane
# (catalog/llm-sites.d, non-null lane) on an active cron line must be behind
# the wake gate (catalog/lane-wakes.d/<lane>.json), behind
# bin/lib/cadence-backstop.sh on that line, or named with its reason in
# catalog/lane-wakes.d/_exempt.tsv.
#
#   C1  bin/render-cron.sh hub and every other box: 0 ungated model-lane lines
#   C2  the counter bites: a copy with alert-triage.json removed reports 1 on hub
#   C3  prints `hub active lines: <n>; ungated model-lane lines: <m>; exempt
#       model-lane lines: <e>` for the PR body (run it on a main worktree with
#       CRON_SHRINK_ROOT=<dir> for the before number)
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/cron-shrink.bh-9073-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
ROOT="${CRON_SHRINK_ROOT:-$DIR}"
command -v jq >/dev/null 2>&1 || { echo "cron-shrink: jq is required"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# count <root> <box> — prints "<active> <ungated> <exempt>" and one
# `ungated <lane>: <line>` per ungated line on stderr.
count() {
  local r="$1" box="$2" map census
  map=$(jq -r '.lanes[]? // empty | select(.script != null) | "\(.script)\t\(.id)"' "$r/catalog/lanes.json" 2>/dev/null)
  [ -n "$map" ] || map=$(for f in "$r"/catalog/lanes.d/*.json; do jq -r 'select(.script != null) | "\(.script)\t\(.id)"' "$f" 2>/dev/null; done)
  census=" $(jq -r '.[]? | .lane // empty' "$r"/catalog/llm-sites.d/*.json 2>/dev/null | sort -u | tr '\n' ' ') "
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" --root "$r" "$box" 2>/dev/null | awk -v census="$census" -v ex="$r/catalog/lane-wakes.d/_exempt.tsv" \
      -v wakes="$r/catalog/lane-wakes.d" -v map="$map" '
    BEGIN {
      n = split(map, m, "\n"); for (i = 1; i <= n; i++) { split(m[i], kv, "\t"); lane[kv[1]] = kv[2] }
      while ((getline l < ex) > 0) { if (l ~ /^#/ || l == "") continue; split(l, f, "\t"); exempt[f[1]] = 1 }
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ || /^[A-Za-z_][A-Za-z_0-9]*=/ { next }
    {
      active++
      s = $0; seen = ""
      while (match(s, /\/root\/harness\/bin\/[a-z0-9._-]+\.sh/)) {
        p = substr(s, RSTART + 14, RLENGTH - 14); s = substr(s, RSTART + RLENGTH)
        id = lane[p]; if (id == "" || index(census, " " id " ") == 0 || index(seen, " " id " ")) continue
        seen = seen " " id " "
        if ((getline tmp < (wakes "/" id ".json")) > 0) { close(wakes "/" id ".json"); continue }
        close(wakes "/" id ".json")
        if ($0 ~ /cadence-backstop\.sh/) continue
        if (id in exempt) { exm++; continue }
        ung++; print "ungated " id ": " $0 > "/dev/stderr"
      }
    }
    END { printf "%d %d %d\n", active, ung, exm }'
}

# ═════ C1: every box, 0 ungated model-lane lines ═════════════════════════════
BOXES="hub $(cd "$ROOT/cron/boxes" && ls -d -- *.d | sed 's/\.d$//' | grep -v -e '^_' -e '^hub$' | tr '\n' ' ')"
for b in $BOXES; do
  read -r act ung exm < <(count "$ROOT" "$b" 2>"$T/ungated.$b")
  [ "${act:-0}" -gt 0 ] 2>/dev/null && ok || bad "C1 $b renders active lines (got '${act:-}')"
  eq "C1 $b ungated model-lane lines ($(head -3 "$T/ungated.$b"))" "${ung:-x}" 0
  [ "$b" = hub ] && { HUB="$act $ung $exm"; }
done

# ═════ C2: the counter bites ═════════════════════════════════════════════════
C="$T/copy"; mkdir -p "$C/catalog" "$C/cron"
cp -r "$ROOT/cron/." "$C/cron/"; cp "$ROOT/fleet.conf" "$C/fleet.conf"
cp -r "$ROOT/catalog/lanes.d" "$ROOT/catalog/llm-sites.d" "$ROOT/catalog/lane-wakes.d" "$C/catalog/"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$C" --write >/dev/null 2>&1 || bad "C2 lanes-build on the copy"
rm -f "$C/catalog/lane-wakes.d/alert-triage.json"
read -r _ ung2 _ < <(count "$C" hub 2>"$T/ungated.copy")
eq "C2 alert-triage.json removed: 1 ungated line" "${ung2:-x}" 1
eq "C2 it is alert-triage" "$(cut -d: -f1 "$T/ungated.copy")" "ungated alert-triage"

# ═════ C3: the counts for the PR body ════════════════════════════════════════
read -r a u e <<<"${HUB:-0 0 0}"
echo "hub active lines: $a; ungated model-lane lines: $u; exempt model-lane lines: $e"
echo "cron-shrink: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
