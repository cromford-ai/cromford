#!/bin/bash
# tests/hotfix-mergify-template-test.sh — the `.mergify.yml` TEMPLATE carries a
# hotfix queue that is first in line, alone in its batch (BH-369, hotfix lane
# 2/3).
#
# WHY THE TEMPLATE IS THE THING UNDER TEST. Nothing in this repo executes
# `.mergify.yml` — Mergify does, from the default branch of the repo that
# carries it — so the artifact the harness actually ships for this half of the
# lane is the block in docs/MERGIFY.md that an operator copies, plus the copy
# committed to the first repo to carry it (tests/fixtures/mergify/). If that
# block says `batch_size: 2` for the hotfix queue, or puts `hotfix` after
# `default`, the emergency shares a batch with whatever was already in flight
# and one red sibling ejects it. That is the failure this file exists to catch,
# and it is invisible to every other suite here.
#
# IT PARSES, IT DOES NOT GREP. Every assertion below reads a VALUE out of the
# parsed YAML (queue order, batch_size, the condition lists, the routing rule's
# own `queue.name`), because a grep for "hotfix" in a markdown file passes on a
# sentence about hotfixes. python3 + PyYAML does the parsing and jq does the
# asserting, the same division the rest of tests/ uses.
#
#   MERGIFY_DOC=<file>      parse this instead of docs/MERGIFY.md (the red-on-main
#                           proof runs `git show main:docs/MERGIFY.md > tmp`)
#   MERGIFY_FIXTURE=<file>  ALSO assert the whole list against a real .mergify.yml
#
# Run from anywhere: tests/hotfix-mergify-template-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# A dev laptop without PyYAML skips; CI may not (BH-1741). The skip read green
# in CI while every YAML assertion below went unrun.
if ! python3 -c 'import yaml' 2>/dev/null; then
  if [ "${CI:-}" = true ]; then
    echo "FAIL: PyYAML missing under CI=true — the YAML sections may not skip in CI (BH-1741)"
    exit 1
  fi
  echo "python3 PyYAML missing — skipping"; exit 0
fi

DOC="${MERGIFY_DOC:-$DIR/docs/MERGIFY.md}"
[ -r "$DOC" ] || { echo "FAIL: no doc to parse at $DOC"; exit 1; }

# The first fenced yaml block that declares queue_rules: — the template. A doc
# whose later blocks are ops snippets is normal; the config is the one that
# configures queues.
extract() { # extract <markdown> -> the template yaml on stdout
  awk '
    /^```yaml/ { inb=1; buf=""; next }
    inb && /^```/ { if (buf ~ /queue_rules:/) { printf "%s", buf; exit } inb=0; buf=""; next }
    inb { buf = buf $0 "\n" }
  ' "$1"
}
tojson() { # tojson <yaml-file> -> json on stdout, rc 1 when it will not parse
  python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1" 2>"$T/yamlerr"
}

# assert_config <json-file> <label> — A1-A9, the ticket's own list.
assert_config() {
  local J="$1" L="$2" q
  # A1/A2: the hotfix queue exists and is FIRST. Mergify picks queues in
  # queue_rules order, so position is not cosmetic.
  jq -e '[.queue_rules[].name] | index("hotfix") != null' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: queue named hotfix — queue_rules has $(jq -c '[.queue_rules[].name]' "$J" 2>/dev/null)"
  jq -e '[.queue_rules[].name] as $n | ($n|index("hotfix")) != null and ($n|index("default")) != null and ($n|index("hotfix")) < ($n|index("default"))' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: the hotfix queue must come BEFORE default in queue_rules (got $(jq -c '[.queue_rules[].name]' "$J" 2>/dev/null))"
  # A3: batch of one. A hotfix that shares a batch is ejected by a red sibling.
  jq -e '.queue_rules[] | select(.name=="hotfix") | .batch_size == 1' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: hotfix.batch_size must be 1 (got $(jq -c '.queue_rules[]|select(.name=="hotfix")|.batch_size' "$J" 2>/dev/null))"
  # A6b: and it never waits to fill that batch.
  jq -e '.queue_rules[] | select(.name=="hotfix") | (.batch_max_wait_time|tostring) | test("^0( *(s|sec|secs|second|seconds))?$")' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: hotfix.batch_max_wait_time must parse to zero (got $(jq -c '.queue_rules[]|select(.name=="hotfix")|.batch_max_wait_time' "$J" 2>/dev/null))"
  # A4: the hotfix queue is the default queue's conditions PLUS label=fix-main-red
  # (BH-2121: the lane is for main-red fixes only; `hotfix` is a build label) —
  # never a loosened gate. Whitespace round `=` is Mergify's to ignore, so the
  # comparison normalises it and nothing else.
  q='def norm: map(gsub("^\\s+|\\s+$";"") | gsub("\\s*=\\s*";"="));'
  jq -e "$q"'(.queue_rules[]|select(.name=="hotfix")|.queue_conditions|norm) | index("label=fix-main-red") != null' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: hotfix.queue_conditions must carry label=fix-main-red (got $(jq -c '.queue_rules[]|select(.name=="hotfix")|.queue_conditions' "$J" 2>/dev/null))"
  # TEST-CHANGE (BH-8706): ONE exemption, the main-red breaker's pause
  # exclusion `-label=merge-queue-paused`. It is not a gate: it takes a PR out
  # of the queue while main is red, and the hotfix queue is the one queue that
  # must stay open then. The next check pins that hotfix does NOT carry it.
  jq -e "$q"'((.queue_rules[]|select(.name=="hotfix")|.queue_conditions|norm)) as $h | ((.queue_rules[]|select(.name=="default")|.queue_conditions|norm)) as $d | ($d - $h - ["-label=merge-queue-paused"]) == []' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: hotfix.queue_conditions must contain every condition the default queue requires — missing $(jq -c "$q"'((.queue_rules[]|select(.name=="default")|.queue_conditions|norm)) - ((.queue_rules[]|select(.name=="hotfix")|.queue_conditions|norm)) - ["-label=merge-queue-paused"]' "$J" 2>/dev/null)"
  jq -e "$q"'(.queue_rules[]|select(.name=="hotfix")|(.queue_conditions + .merge_conditions)|norm) | index("-label=merge-queue-paused") == null' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: the hotfix queue must not exclude the main-red breaker's pause label (BH-8706)"
  # A5: the SAME required check. A hotfix queue keyed on a check name that does
  # not exist merges nothing and pages when its budget runs out.
  jq -e "$q"'[.queue_rules[] | select(.name=="hotfix" or .name=="default") | (.queue_conditions|norm) | map(select(startswith("check-success=")))] | length == 2 and (.[0] == .[1])' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: both queues must require the same check-success name (got $(jq -c '[.queue_rules[]|select(.name=="hotfix" or .name=="default")|.queue_conditions|map(select(startswith("check-success")))]' "$J" 2>/dev/null))"
  # A6: and merge on the same terms.
  jq -e "$q"'((.queue_rules[]|select(.name=="hotfix")|.merge_conditions|norm|sort)) == ((.queue_rules[]|select(.name=="default")|.merge_conditions|norm|sort))' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: hotfix.merge_conditions must equal default's (got $(jq -c '[.queue_rules[]|select(.name=="hotfix" or .name=="default")|.merge_conditions]' "$J" 2>/dev/null))"
  # A7: routing. merge-queue AND fix-main-red -> the hotfix queue.
  jq -e "$q"'[.pull_request_rules[] | select((.conditions|norm|index("label=merge-queue")) != null and (.conditions|norm|index("label=fix-main-red")) != null) | .actions.queue.name] | index("hotfix") != null' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: a pull_request_rules entry conditioned on BOTH labels must queue on 'hotfix' (got $(jq -c '[.pull_request_rules[]|{c:.conditions,q:.actions.queue.name}]' "$J" 2>/dev/null))"
  # A8: and the everything-else rule EXCLUDES fix-main-red, so one PR never
  # matches two queue actions.
  jq -e "$q"'[.pull_request_rules[] | select(.actions.queue.name == "default") | (.conditions|norm)] | length > 0 and (all(.[]; index("-label=fix-main-red") != null))' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: the rule that queues on 'default' must carry -label=fix-main-red (got $(jq -c '[.pull_request_rules[]|select(.actions.queue.name=="default")|.conditions]' "$J" 2>/dev/null))"
  # A9: PREEMPTION. Mergify interrupts a running batch's checks only for a
  # priority rule that says so — queue order alone inserts behind them.
  jq -e "$q"'[.priority_rules[]? | select((.conditions|norm|index("label=fix-main-red")) != null)] | length > 0 and (.[0].priority == "high") and (.[0].allow_checks_interruption == true)' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: a top-level priority_rules entry on label=fix-main-red with priority: high and allow_checks_interruption: true is what preempts a running batch (got $(jq -c '.priority_rules' "$J" 2>/dev/null))"
}

# ---------------------------------------------------------------------------
# The template in docs/MERGIFY.md
# ---------------------------------------------------------------------------
extract "$DOC" > "$T/tpl.yaml"
if [ ! -s "$T/tpl.yaml" ]; then
  bad "no fenced yaml block declaring queue_rules: in $DOC"
else
  if tojson "$T/tpl.yaml" > "$T/tpl.json"; then
    ok
    assert_config "$T/tpl.json" "template"
  else
    bad "the template block in $DOC does not parse as YAML: $(head -2 "$T/yamlerr" | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------------------
# The real file a repo carries, when one is named
# ---------------------------------------------------------------------------
if [ -n "${MERGIFY_FIXTURE:-}" ]; then
  if [ ! -r "$MERGIFY_FIXTURE" ]; then
    bad "MERGIFY_FIXTURE=$MERGIFY_FIXTURE is not readable"
  elif tojson "$MERGIFY_FIXTURE" > "$T/fix.json"; then
    echo "fixture: parsed"
    assert_config "$T/fix.json" "fixture"
  else
    bad "MERGIFY_FIXTURE does not parse as YAML: $(head -2 "$T/yamlerr" | tr '\n' ' ')"
  fi
fi

echo "hotfix-mergify-template-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
