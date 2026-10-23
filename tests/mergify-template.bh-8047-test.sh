#!/bin/bash
# tests/mergify-template.bh-8047-test.sh — BH-8047 (CI cost hotfix): the
# cromford `default` merge queue batches up to 6 PRs and waits up to
# 2 min to fill. The size-1 queues (hotfix, solo, flake-fix) do not change.
#
#   B1  the render of cromford.conf: default batch_size 6, wait "2 min"
#   B2  the render: hotfix batch_size 1, wait "0 s"
#   B3  the render: solo and flake-fix stay 1 / "0 s"
#   B4  the committed .mergify.yml carries the B1 and B2 values
#   B5  bin/mergify-template.sh --check is green on a scratch copy
#   B6  near misses drift: default wait 3 min, default size 4, hotfix size 6
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mergify-template.bh-8047-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if ! command -v jq >/dev/null; then
  [ "${CI:-}" = true ] && { echo "FAIL: jq missing under CI=true"; exit 1; }
  echo "jq missing — skipping"; exit 0
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ "${CI:-}" = true ] && { echo "FAIL: PyYAML missing under CI=true"; exit 1; }
  echo "python3 PyYAML missing — skipping"; exit 0
fi
tojson() { python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1"; }
q() { jq -c --arg n "$2" '.queue_rules[] | select(.name == $n) | [.batch_size, .batch_max_wait_time]' "$1" 2>/dev/null; }

# A scratch copy of the CLI, its config and the root yaml (the bh-1673 mkrepo shape).
R="$T/r"; mkdir -p "$R/bin" "$R/config"
cp "$DIR/bin/mergify-template.sh" "$R/bin/"; cp -r "$DIR/config/mergify" "$R/config/"; cp "$DIR/.mergify.yml" "$R/"
MT="$R/bin/mergify-template.sh"
BH="$R/config/mergify/repos/cromford.conf"

# ── B1-B3: the render ───────────────────────────────────────────────────────
bash "$MT" render "$BH" > "$T/bh.yml" 2>"$T/err"; RC=$?
tojson "$T/bh.yml" > "$T/bh.json" 2>/dev/null || : > "$T/bh.json"
[ "$RC" = 0 ] && [ -s "$T/bh.json" ] && ok || bad "the cromford conf renders (rc $RC): $(cat "$T/err")"
[ "$(q "$T/bh.json" default)" = '[6,"2 min"]' ] && ok || bad "B1 render default batch_size 6, wait 2 min (got $(q "$T/bh.json" default))"
[ "$(q "$T/bh.json" hotfix)" = '[1,"0 s"]' ] && ok || bad "B2 render hotfix batch_size 1, wait 0 s (got $(q "$T/bh.json" hotfix))"
for n in solo flake-fix; do
  [ "$(q "$T/bh.json" "$n")" = '[1,"0 s"]' ] && ok || bad "B3 render $n batch_size 1, wait 0 s (got $(q "$T/bh.json" "$n"))"
done

# ── B4: the committed .mergify.yml ──────────────────────────────────────────
tojson "$DIR/.mergify.yml" > "$T/committed.json" 2>/dev/null || : > "$T/committed.json"
[ "$(q "$T/committed.json" default)" = '[6,"2 min"]' ] && ok || bad "B4 .mergify.yml default 6 / 2 min (got $(q "$T/committed.json" default))"
[ "$(q "$T/committed.json" hotfix)" = '[1,"0 s"]' ] && ok || bad "B4 .mergify.yml hotfix 1 / 0 s (got $(q "$T/committed.json" hotfix))"

# ── B5: --check on the scratch copy ─────────────────────────────────────────
bash "$MT" --check > "$T/b5.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "B5 --check is green on the scratch copy (rc $RC): $(cat "$T/b5.out")"

# ── B6: near misses, each edited only inside its own queue block ────────────
edit() { # edit <queue> <key> <value> <out> — change one key inside one queue block
  awk -v q="$1" -v k="$2" -v v="$3" '
    /^  - name: / { inq = ($0 == "  - name: " q) }
    inq && $1 == k":" { sub(/:.*/, ": " v) }
    { print }' "$R/.mergify.yml" > "$4"
}
for c in "default batch_max_wait_time 3 min" "default batch_size 4" "hotfix batch_size 6"; do
  read -r qn key val <<<"$c"
  edit "$qn" "$key" "$val" "$T/b6.yml"
  cmp -s "$R/.mergify.yml" "$T/b6.yml" && { bad "B6 the edit '$c' changed nothing"; continue; }
  bash "$MT" compare "$BH" "$T/b6.yml" >/dev/null 2>&1; RC=$?
  [ "$RC" = 1 ] && ok || bad "B6 $qn $key $val drifts from the render (compare rc $RC, want 1)"
done

echo "mergify-template.bh-8047-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
