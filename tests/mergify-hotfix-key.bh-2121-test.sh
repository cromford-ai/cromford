#!/bin/bash
# tests/mergify-hotfix-key.bh-2121-test.sh — Mergify's hotfix lane is keyed on
# `fix-main-red`, not on `hotfix` (BH-2121).
#
# WHY. On 2026-09-24 at 17:04Z a PR carrying the pool's `hotfix` label (a
# BUILD-priority signal) jumped the queue through `priority_rules`
# `allow_checks_interruption: true`: a green 8-PR batch was thrown away and
# three batches restarted (#2104). The rule since: the hotfix lane exists for
# `fix-main-red` only, and a `hotfix`-only PR queues in `default` like any
# other.
#
# IT EVALUATES, IT DOES NOT GREP. Each config is parsed (python3 + PyYAML ->
# json) and a small jq evaluator decides, for a set of PR labels, which
# pull_request_rules match, which queue they route to, whether that queue's
# queue_conditions admit the PR, and whether a priority_rules entry (the part
# that interrupts running batches) fires. Checks are taken as green and `base=`
# as satisfied; every other condition shape is an unknown and fails the case.
# TEST-CHANGE (BH-9039): green also covers the status_check_any shapes, the
# regex `check-success~=` (some name is success) and the `-check-failure=` veto
# (no name failed); tests/verdict-builder-context.bh-9039-test.sh owns them.
#
# The four configs:
#   committed   .mergify.yml (MERGIFY_BH2121_YAML=<file> parses that instead —
#               the red-on-main proof passes main's copy)
#   render-bh   bin/mergify-template.sh render config/mergify/repos/cromford.conf
#   render-ts   bin/mergify-template.sh render config/mergify/repos/project-5.conf
#   doc         the first fenced yaml block with queue_rules: in docs/MERGIFY.md
#
# Run from anywhere: tests/mergify-hotfix-key.bh-2121-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BIN="$DIR/bin/mergify-template.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
# The PyYAML skip/CI-fail pattern of tests/hotfix-mergify-template-test.sh (BH-1741).
if ! python3 -c 'import yaml' 2>/dev/null; then
  if [ "${CI:-}" = true ]; then
    echo "FAIL: PyYAML missing under CI=true — the YAML sections may not skip in CI (BH-1741)"
    exit 1
  fi
  echo "python3 PyYAML missing — skipping"; exit 0
fi

tojson() { # tojson <yaml-file> -> json on stdout, rc 1 when it will not parse
  python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1" 2>"$T/yamlerr"
}
extract() { # extract <markdown> -> the template yaml on stdout
  awk '
    /^```yaml/ { inb=1; buf=""; next }
    inb && /^```/ { if (buf ~ /queue_rules:/) { printf "%s", buf; exit } inb=0; buf=""; next }
    inb { buf = buf $0 "\n" }
  ' "$1"
}

# The evaluator. $labels is the PR's label set; the output is one object:
#   rules    names of matching pull_request_rules
#   queues   the queue names those rules route to
#   admitted for each routed queue, whether its queue_conditions admit the PR
#   prio     names of matching priority_rules
#   unknown  any condition the evaluator cannot decide (must stay empty)
# $crs is the fixture PR's count of standing changes-requested reviews (0 unless
# a case says otherwise): BH-2275 put `#changes-requested-reviews-by=0` in every
# queue rule's queue_conditions and merge_conditions.
DEFS='
def norm: gsub("^\\s+|\\s+$";"") | gsub("\\s*=\\s*";"=") | gsub("\"";"");
def holds($l):
  norm as $c
  | if   ($c|startswith("-label=")) then (($l|index($c[7:])) == null)
    elif ($c|startswith("label="))  then (($l|index($c[6:])) != null)
    elif ($c|startswith("base="))   then true
    elif ($c|startswith("check-success=")) then true
    elif ($c|startswith("check-success~=")) then true
    elif ($c|startswith("-check-failure=")) then true
    elif ($c|startswith("#changes-requested-reviews-by=")) then ($crs == ($c[30:]|tonumber))
    else null end;
def allhold($l): [.[] | holds($l)] | all(. == true);
'
EVAL="$DEFS"'
. as $cfg
| {
    rules:  [ ($cfg.pull_request_rules // [])[] | select(.conditions | allhold($labels)) | .name ],
    queues: [ ($cfg.pull_request_rules // [])[] | select(.conditions | allhold($labels)) | .actions.queue.name? // empty ],
    prio:   [ ($cfg.priority_rules // [])[] | select(.conditions | allhold($labels)) | .name ],
    unknown: [ (($cfg.pull_request_rules // [])[].conditions[]), (($cfg.priority_rules // [])[].conditions[]),
               (($cfg.queue_rules // [])[].queue_conditions[]) | select(holds($labels) == null) ]
  }
| .admitted = [ .queues[] as $q | $cfg.queue_rules[] | select(.name == $q) | (.queue_conditions | allhold($labels)) ]
'
route() { # route <json> <labels-json-array> [change-request count] -> the evaluator object
  jq -c --argjson labels "$2" --argjson crs "${3:-0}" "$EVAL" "$1"
}

# expect <json> <cfg-label> <labels> <queue|none> <prio: yes|no>
expect() {
  local J=$1 L=$2 labels=$3 want_q=$4 want_p=$5 r
  if ! r=$(route "$J" "$labels"); then bad "$L $labels: the evaluator did not run"; return; fi
  if [ "$(jq -c '.unknown' <<<"$r")" != "[]" ]; then
    bad "$L $labels: conditions the evaluator cannot decide: $(jq -c '.unknown' <<<"$r")"; return
  fi
  if [ "$want_q" = none ]; then
    [ "$(jq -c '.queues' <<<"$r")" = "[]" ] && ok || bad "$L $labels: must queue nowhere (got $r)"
  else
    [ "$(jq -c '.queues' <<<"$r")" = "[\"$want_q\"]" ] && ok \
      || bad "$L $labels: must match exactly one queue rule, routing to '$want_q' (got $r)"
    [ "$(jq -c '.admitted' <<<"$r")" = "[true]" ] && ok \
      || bad "$L $labels: the '$want_q' queue's queue_conditions must admit the PR it is routed (got $r)"
  fi
  if [ "$want_p" = yes ]; then
    [ "$(jq -c '.prio' <<<"$r")" = '["hotfix first"]' ] && ok || bad "$L $labels: 'hotfix first' priority must fire (got $r)"
  else
    [ "$(jq -c '.prio' <<<"$r")" = "[]" ] && ok || bad "$L $labels: NO priority rule may fire — it interrupts running batches (got $r)"
  fi
}
# hotfix_queue_refuses <json> <cfg-label> <labels>: the hotfix queue itself will not take the PR
hotfix_queue_refuses() {
  jq -e --argjson labels "$3" --argjson crs 0 "$DEFS"'.queue_rules[] | select(.name=="hotfix") | (.queue_conditions | allhold($labels)) | not' "$1" >/dev/null 2>&1 \
    && ok || bad "$2 $3: the hotfix queue's queue_conditions must refuse this PR"
}

assert_config() { # assert_config <json> <label>
  local J=$1 L=$2
  expect "$J" "$L" '["merge-queue","fix-main-red"]'          hotfix  yes
  expect "$J" "$L" '["merge-queue","hotfix"]'                default no   # the #2104 case
  expect "$J" "$L" '["merge-queue","hotfix","fix-main-red"]' hotfix  yes
  expect "$J" "$L" '["merge-queue"]'                         default no
  expect "$J" "$L" '["fix-main-red"]'                        none    yes
  expect "$J" "$L" '["merge-queue","hotfix-candidate"]'      default no
  expect "$J" "$L" '["merge-queue","not-fix-main-red"]'      default no
  expect "$J" "$L" '["merge-queue","Hotfix"]'                default no
  hotfix_queue_refuses "$J" "$L" '["merge-queue","hotfix"]'
  hotfix_queue_refuses "$J" "$L" '["merge-queue"]'
  # BH-2275: a standing change request keeps a routed PR OUT of its queue — the
  # label still routes it, the queue's own conditions refuse it.
  for lb in '["merge-queue"]' '["merge-queue","fix-main-red"]'; do
    r=$(route "$J" "$lb" 1) || { bad "$L $lb +CR: the evaluator did not run"; continue; }
    [ "$(jq -c '.unknown' <<<"$r")" = "[]" ] && [ "$(jq -c '.admitted' <<<"$r")" = "[false]" ] && ok \
      || bad "$L $lb with a standing change request: its queue must refuse it (got $r)"
  done
  # No condition anywhere keys on the pool's build-priority label.
  jq -e '[.. | strings | gsub("\\s*=\\s*";"=") | gsub("^\\s+|\\s+$";"") | select(. == "label=hotfix" or . == "-label=hotfix")] == []' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: a condition still reads label=hotfix / -label=hotfix"
  # The lane itself is intact: hotfix is the first queue and rides alone.
  jq -e '.queue_rules[0].name == "hotfix" and .queue_rules[0].batch_size == 1' "$J" >/dev/null 2>&1 \
    && ok || bad "$L: the hotfix queue must be first with batch_size 1 (got $(jq -c '[.queue_rules[]|{name,batch_size}]' "$J" 2>/dev/null))"
}

check_yaml() { # check_yaml <yaml-file> <label>
  if [ ! -s "$1" ]; then bad "$2: nothing to parse"; return; fi
  if tojson "$1" > "$T/$2.json"; then assert_config "$T/$2.json" "$2"
  else bad "$2: does not parse as YAML: $(head -2 "$T/yamlerr" | tr '\n' ' ')"; fi
}

check_yaml "${MERGIFY_BH2121_YAML:-$DIR/.mergify.yml}" committed
"$BIN" render "$DIR/config/mergify/repos/cromford.conf" > "$T/render-bh.yml" || bad "render cromford.conf: rc $?"
check_yaml "$T/render-bh.yml" render-bh
"$BIN" render "$DIR/config/mergify/repos/project-5.conf" > "$T/render-ts.yml" || bad "render project-5.conf: rc $?"
check_yaml "$T/render-ts.yml" render-ts
extract "$DIR/docs/MERGIFY.md" > "$T/doc.yml"
check_yaml "$T/doc.yml" doc

echo "mergify-hotfix-key.bh-2121-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
