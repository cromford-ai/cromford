#!/bin/bash
# tests/mergify-scopes-cost-shape.bh-4979-test.sh — BH-4979's cost-shape pin
# for the parallel-lanes render. "It must still be one run per tree": turning
# cromford.conf to queue_mode=parallel may add the lane machinery
# (merge_queue.mode, manual scopes) and nothing else — the same queue and merge
# conditions (three fast checks to enter, seven on the draft, so every tree is
# a draft and runs the corpus once), the same max_parallel_checks ceiling, no
# file-pattern scopes, and the hotfix queue still one PR per batch.
# It also pins that the COMMITTED conf is serial: the lanes ship dark until the
# MERGIFY_CI_KEY PUT probe rides the flip PR (docs/MERGIFY.md).
#
# tests/harness-ci-cost-shape-test.sh is deliberately not edited here: it only
# reads queue_rules, which this render does not change (BH-4979 plan, A7).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mergify-scopes-cost-shape.bh-4979-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
python3 -c 'import yaml' 2>/dev/null || { echo "PyYAML missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

CONF="$DIR/config/mergify/repos/cromford.conf"
MT="$DIR/bin/mergify-template.sh"
tojson() { python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1])), sort_keys=True))' "$1"; }

# C0: the committed conf is serial — the live queue does not change in this PR.
[ "$(grep -c '^queue_mode=serial$' "$CONF")" = 1 ] && ! grep -q '^queue_mode=parallel' "$CONF" && ok \
  || bad "C0 the committed cromford.conf is queue_mode=serial: $(grep '^queue_mode' "$CONF")"

bash "$MT" render "$CONF" > "$T/serial.yml" || bad "C0 the committed conf renders"
sed 's/^queue_mode=.*/queue_mode=parallel/' "$CONF" > "$T/par.conf"
bash "$MT" render "$T/par.conf" > "$T/par.yml" || bad "C0 the parallel conf renders"
# MC_COST_MUTATE (manual mutation check only): add a check to the parallel
# render's queue_conditions; C1 must go red.
if [ -n "${MC_COST_MUTATE:-}" ]; then
  python3 - "$T/par.yml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p))
d["queue_rules"][1]["queue_conditions"].append("check-success=" + "extra")
yaml.safe_dump(d, open(p, "w"))
PY
fi
S=$(tojson "$T/serial.yml"); P=$(tojson "$T/par.yml")

# C1: queue_rules identical, so the entry and draft checks are what they were.
[ "$(jq -c .queue_rules <<<"$S")" = "$(jq -c .queue_rules <<<"$P")" ] && ok \
  || bad "C1 queue_rules must be identical between the serial and parallel renders"
QC=$(jq -r '.queue_rules[] | select(.name == "default") | [.queue_conditions[] | select(startswith("check-success="))] | length' <<<"$P")
MC=$(jq -r '.queue_rules[] | select(.name == "default") | [.merge_conditions[] | select(startswith("check-success="))] | length' <<<"$P")
# TEST-CHANGE (BH-9039): the verdict status is now the status_check_any regex
# `check-success~=^(lead-verdict|harness-verdict)$`, not a `check-success=` line.
# 3 fast checks + that one regex to enter; 7 on the draft.
RX=$(jq -r '.queue_rules[] | select(.name == "default") | [.queue_conditions[] | select(startswith("check-success~="))] | length' <<<"$P")
[ "$QC" = 3 ] && [ "$RX" = 1 ] && [ "$MC" = 7 ] && ok || bad "C1 default enters on 3 checks + the verdict regex and merges on 7 (got $QC + $RX / $MC)"

# C2: the speculative-check ceiling is unchanged.
[ "$(jq -r .merge_queue.max_parallel_checks <<<"$S")" = "$(jq -r .merge_queue.max_parallel_checks <<<"$P")" ] \
  && [ "$(jq -r .merge_queue.max_parallel_checks <<<"$P")" = "$(sed -n 's/^max_parallel_checks=//p' "$CONF")" ] && ok \
  || bad "C2 max_parallel_checks is unchanged by parallel mode"

# C3: the scopes are manual only — no file-pattern scopes in the config.
[ "$(jq -c '.scopes.source' <<<"$P")" = '{"manual":{}}' ] && ok || bad "C3 scopes.source is manual only: $(jq -c .scopes <<<"$P")"
[ "$(jq -r .merge_queue.mode <<<"$P")" = parallel ] && ok || bad "C3 the parallel render sets merge_queue.mode"
# ... and the serial render has neither.
[ "$(jq -c '[.scopes, .merge_queue.mode]' <<<"$S")" = '[null,null]' ] && ok || bad "C3 the serial render carries no mode and no scopes"

# C4: the hotfix queue keeps one PR per batch.
[ "$(jq -r '.queue_rules[] | select(.name == "hotfix") | .batch_size' <<<"$P")" = 1 ] && ok || bad "C4 hotfix batch_size stays 1"

# C5: only merge_queue.mode and scopes differ between the two renders.
D=$(jq -n --argjson s "$S" --argjson p "$P" '($p | del(.scopes) | .merge_queue |= del(.mode)) == $s')
[ "$D" = true ] && ok || bad "C5 parallel adds merge_queue.mode and scopes and changes nothing else"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
