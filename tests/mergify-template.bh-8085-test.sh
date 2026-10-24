#!/bin/bash
# tests/mergify-template.bh-8085-test.sh — this repo's Mergify queue checks 1
# batch at a time (the operator, 2026-10-22, BH-8085, CI cost hotfix), and a committed
# .mergify.yml at any other value is drift.
#
# Every render and compare goes through a scratch copy of the real CLI, conf
# and root .mergify.yml, so `--check` reads the scratch tree and never the
# checkout. Values are read from the PARSED YAML (python3 + PyYAML -> json ->
# jq), never grepped from the text. Without jq or PyYAML the suite skips when
# CI is not "true" and fails when it is.
#
# Run from anywhere: tests/mergify-template.bh-8085-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
T=$SCRATCH
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if ! command -v jq >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
  if [ "${CI:-}" = true ]; then echo "FAIL: jq or PyYAML missing in CI"; exit 1; fi
  echo "SKIP: jq or PyYAML missing"; exit 0
fi

# The scratch repo: the CLI, the whole config/mergify tree and the root yaml.
R="$T/repo"
mkdir -p "$R/bin" "$R/config"
cp "$DIR/bin/mergify-template.sh" "$R/bin/"
cp -R "$DIR/config/mergify" "$R/config/"
cp "$DIR/.mergify.yml" "$R/.mergify.yml"
BIN="$R/bin/mergify-template.sh"
CONF="$R/config/mergify/repos/cromford.conf"
YML="$R/.mergify.yml"

tojson() { # tojson <yaml-file> -> json on stdout, rc 1 when it will not parse
  python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1" 2>/dev/null
}
# render_json <conf> <out.json> — the CLI's render, parsed
render_json() {
  "$BIN" render "$1" > "$T/r.yml" 2>"$T/r.err" || { echo "render rc!=0: $(head -c 300 "$T/r.err")" >&2; return 1; }
  tojson "$T/r.yml" > "$2"
}
# one_parallel <json> — the P1/P2 assert
one_parallel() { jq -e '.merge_queue.max_parallel_checks == 1' "$1" >/dev/null; }

# P1: the render of the conf checks 1 batch at a time.
if render_json "$CONF" "$T/now.json" && one_parallel "$T/now.json"; then ok
else bad "P1 render max_parallel_checks (got $(jq -c '.merge_queue' "$T/now.json" 2>/dev/null))"; fi

# P2: the committed .mergify.yml (what Mergify reads) says 1.
if tojson "$YML" > "$T/yml.json" && one_parallel "$T/yml.json"; then ok
else bad "P2 .mergify.yml max_parallel_checks (got $(jq -c '.merge_queue' "$T/yml.json" 2>/dev/null))"; fi

# P3: --check over the scratch tree is green (the render matches .mergify.yml).
"$BIN" --check > "$T/check.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "P3 --check rc $rc (want 0): $(head -c 400 "$T/check.out")"

# P4: near misses. The yaml at the old value 3, at 2 and at the ceiling 8 each
# drift from the conf (compare rc 1).
for v in 3 2 8; do
  sed "s/^  max_parallel_checks: .*/  max_parallel_checks: $v/" "$YML" > "$T/near$v.yml"
  if ! tojson "$T/near$v.yml" | jq -e --argjson v "$v" '.merge_queue.max_parallel_checks == $v' >/dev/null; then
    bad "P4 the near-miss yaml at $v did not take the value"; continue
  fi
  "$BIN" compare "$CONF" "$T/near$v.yml" > "$T/near$v.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && ok || bad "P4 compare of a yaml at $v: rc $rc (want 1, drift)"
done

# P5: non-vacuity. A conf at 3 renders a file that fails the P1 assert.
sed 's/^max_parallel_checks=.*/max_parallel_checks=3/' "$CONF" > "$T/at3.conf"
if render_json "$T/at3.conf" "$T/at3.json" \
   && jq -e '.merge_queue.max_parallel_checks == 3' "$T/at3.json" >/dev/null \
   && ! one_parallel "$T/at3.json"; then ok
else bad "P5 a conf at 3 did not fail the P1 assert (got $(jq -c '.merge_queue' "$T/at3.json" 2>/dev/null))"; fi

# P6: one max_parallel_checks line (no duplicate key hides the value), and
# scope_default_capacity is not above it.
n=$(grep -c '^max_parallel_checks=' "$CONF")
mpc=$(sed -n 's/^max_parallel_checks=//p' "$CONF" | head -1)
cap=$(sed -n 's/^scope_default_capacity=//p' "$CONF" | head -1)
if [ "$n" = 1 ] && [ -n "$cap" ] && [ "$cap" -le "$mpc" ]; then ok
else bad "P6 max_parallel_checks lines: $n (want 1); scope_default_capacity ${cap:-unset} vs $mpc"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
