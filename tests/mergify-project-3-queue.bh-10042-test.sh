#!/bin/bash
# tests/mergify-project-3-queue.bh-10042-test.sh — example-org/project-3's Mergify
# queue tests 4 PRs per batch and runs 3 batches in parallel (BH-10042,
# 2026-11-25: 11 PRs waited, 8 PRs needed 75 min at 2 and 2 on 2026-11-24).
# The conf keeps retries 1, timeout and wait 3 min explicit, because the
# template defaults for those differ. BH-10079 (2026-11-25): the three E2E
# shards are merge conditions (the batch draft) and not admission conditions,
# and the timeout is 45 min (real drafts took 17.7 and 17.8 min of E2E).
#
# Every render goes through a scratch copy of the real CLI and config/mergify
# tree. Values are read from the PARSED YAML (python3 + PyYAML -> json -> jq),
# never grepped from the text. Without jq or PyYAML the suite skips when CI is
# not "true" and fails when it is.
#
# Run from anywhere: tests/mergify-project-3-queue.bh-10042-test.sh   (exit 0 = all pass)
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

R="$T/repo"
mkdir -p "$R/bin" "$R/config"
cp "$DIR/bin/mergify-template.sh" "$R/bin/"
cp -R "$DIR/config/mergify" "$R/config/"
[ -f "$DIR/.mergify.yml" ] && cp "$DIR/.mergify.yml" "$R/.mergify.yml"
BIN="$R/bin/mergify-template.sh"
CONF="$R/config/mergify/repos/project-3.conf"

tojson() { python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1" 2>/dev/null; }

"$BIN" render "$CONF" > "$T/r.yml" 2>"$T/r.err"; rc=$?
if [ "$rc" != 0 ] || ! tojson "$T/r.yml" > "$T/r.json"; then
  echo "FAIL: render of project-3.conf rc $rc: $(head -c 300 "$T/r.err")"; exit 1
fi
J="$T/r.json"
q() { jq -e "$1" "$J" >/dev/null; }
dq() { jq -e --arg n "$1" ".queue_rules[] | select(.name == \$n) | $2" "$J" >/dev/null; }

# A1: 3 batches checked in parallel.
q '.merge_queue.max_parallel_checks == 3' && ok \
  || bad "A1 max_parallel_checks (got $(jq -c '.merge_queue' "$J"))"

# A2: the default queue batches 4 and keeps wait, retries and timeout.
dq default '.batch_size == 4' && ok || bad "A2 default batch_size != 4 ($(jq -c '.queue_rules' "$J" | head -c 400))"
dq default '.batch_max_wait_time == "3 min"' && ok || bad "A2 default batch_max_wait_time != 3 min"
dq default '.max_checks_retries == 1' && ok || bad "A2 default max_checks_retries != 1"
dq default '.checks_timeout == "45 min"' && ok || bad "A2 default checks_timeout != 45 min"

# A6 (BH-10079): in both queues the three E2E shards are merge conditions,
# never admission conditions (an ordinary PR head may skip E2E by path), and
# the four CI checks stay in both lists.
for qn in default hotfix; do
  for n in 1 2 3; do
    e="check-success=E2E Tests (Shard $n/3)"
    dq "$qn" "(.merge_conditions | index(\"$e\")) != null" && ok || bad "A6 $qn merge_conditions lack $e"
    dq "$qn" "(.queue_conditions | index(\"$e\")) == null" && ok || bad "A6 $qn queue_conditions hold $e"
  done
  for c in "Unit Tests" "Type Check" "Test Coverage Gate" "Schema Drift Check"; do
    dq "$qn" "(.queue_conditions | index(\"check-success=$c\")) != null and (.merge_conditions | index(\"check-success=$c\")) != null" \
      && ok || bad "A6 $qn lost $c in queue or merge conditions"
  done
done

# A3: hotfix still batches 1.
dq hotfix '.batch_size == 1' && ok || bad "A3 hotfix batch_size != 1"

# A4: --check over the scratch tree is green.
"$BIN" --check > "$T/check.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q 'project-3.conf' "$T/check.out"; then ok
else bad "A4 --check rc $rc (want 0, project-3.conf named): $(head -c 400 "$T/check.out")"; fi

# A5: the ceiling of 8 still guards this conf: 9 makes render exit rc 2.
sed 's/^max_parallel_checks=.*/max_parallel_checks=9/' "$CONF" > "$T/at9.conf"
grep -q '^max_parallel_checks=9$' "$T/at9.conf" || bad "A5 the scratch conf did not take 9"
"$BIN" render "$T/at9.conf" > /dev/null 2>"$T/at9.err"; rc=$?
[ "$rc" = 2 ] && ok || bad "A5 render at max_parallel_checks=9: rc $rc (want 2)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
