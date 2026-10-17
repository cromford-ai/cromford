#!/bin/bash
# tests/mergify-config.bh-6337-test.sh — this repo's Mergify queue builds 3
# speculative batches at once, and nothing else in the queue changed with it.
#
# Every render goes through the real CLI ($DIR/bin/mergify-template.sh). Values
# are read from the PARSED YAML (python3 + PyYAML -> json -> jq), never grepped
# from the text. Every case needs YAML: without PyYAML each case prints
# `SKIP (no PyYAML)` and the suite fails.
#
# Run from anywhere: tests/mergify-config.bh-6337-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BIN="$DIR/bin/mergify-template.sh"
CONF="$DIR/config/mergify/repos/cromford.conf"
YML="$DIR/.mergify.yml"
T=$SCRATCH
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

tojson() { # tojson <yaml-file> -> json on stdout, rc 1 when it will not parse
  python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1" 2>/dev/null
}
# render_json <conf> <out.json> — the real CLI's render, parsed
render_json() {
  "$BIN" render "$1" > "$T/r.yml" 2>"$T/r.err" || { echo "render rc!=0: $(head -c 300 "$T/r.err")" >&2; return 1; }
  tojson "$T/r.yml" > "$2"
}
# three_parallel <json> — the C1/C2 assert
three_parallel() { jq -e '.merge_queue.max_parallel_checks == 3' "$1" >/dev/null; }

if ! python3 -c 'import yaml' 2>/dev/null; then
  for c in C1 C2 C3 C4 C5 C6 C7; do echo "SKIP (no PyYAML): $c"; done
  echo "PASS=0 FAIL=7"; exit 1
fi

# C1: the render of the conf builds 3 batches at once.
if render_json "$CONF" "$T/now.json" && three_parallel "$T/now.json"; then ok
else bad "C1 render max_parallel_checks (got $(jq -c '.merge_queue' "$T/now.json" 2>/dev/null))"; fi

# C2: the committed .mergify.yml (what Mergify reads) says 3.
if tojson "$YML" > "$T/yml.json" && three_parallel "$T/yml.json"; then ok
else bad "C2 .mergify.yml max_parallel_checks (got $(jq -c '.merge_queue' "$T/yml.json" 2>/dev/null))"; fi

# C3: the conf and the committed file agree.
"$BIN" compare "$CONF" "$YML" > "$T/cmp.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "C3 compare rc $rc (want 0): $(head -c 400 "$T/cmp.out")"

# C4: the queue rule names did not change (BH-7279 added flake-fix after hotfix).
jq -e '[.queue_rules[].name] == ["hotfix","flake-fix","solo","default"]' "$T/yml.json" >/dev/null \
  && ok || bad "C4 queue rule names (got $(jq -c '[.queue_rules[].name]' "$T/yml.json" 2>/dev/null))"

# C5: the conf at the old value (8) and the real conf render the same rules, and
# the two renders differ only in merge_queue.max_parallel_checks.
sed 's/^max_parallel_checks=3$/max_parallel_checks=8/' "$CONF" > "$T/at8.conf"
if render_json "$T/at8.conf" "$T/at8.json" \
   && jq -e --slurpfile a "$T/at8.json" --slurpfile b "$T/now.json" -n '
        ($a[0] | {queue_rules, pull_request_rules, priority_rules}) == ($b[0] | {queue_rules, pull_request_rules, priority_rules})
        and ($a[0] | del(.merge_queue.max_parallel_checks)) == ($b[0] | del(.merge_queue.max_parallel_checks))' >/dev/null; then ok
else bad "C5 renders at 8 and at the conf value differ outside max_parallel_checks"; fi

# C6: non-vacuity — the conf at 8 must fail the C1 assert.
if [ -s "$T/at8.json" ] && jq -e '.merge_queue.max_parallel_checks == 8' "$T/at8.json" >/dev/null \
   && ! three_parallel "$T/at8.json"; then ok
else bad "C6 a conf at 8 did not fail the C1 assert (got $(jq -c '.merge_queue' "$T/at8.json" 2>/dev/null))"; fi

# C7: one max_parallel_checks line, so no duplicate key hides the value.
n=$(grep -c '^max_parallel_checks=' "$CONF")
[ "$n" = 1 ] && ok || bad "C7 max_parallel_checks lines in the conf: $n (want 1)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
