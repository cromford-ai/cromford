#!/bin/bash
# tests/mergify-flake-fix-queue.bh-7279-test.sh — BH-7279: a conf's
# flake_fix_label= renders a size-1 `flake-fix` queue between hotfix and
# solo/default, a rule that routes merge-queue + that label to it, and the
# exclusions that keep every PR in exactly one rule.
#
#   G1  the flake-fix queue: batch_size 1, 0 s, 0 retries, default's
#       queue_conditions plus the label, merge_conditions equal to default's
#   G2  no priority rule names the label (nothing interrupts running checks)
#   G3  a label-set table over the rendered pull_request_rules
#   G4  queue order hotfix < flake-fix < solo < default, render and committed
#   G5  bin/mergify-template.sh --check is green on the committed tree
#   G6  the order lint: flake-fix below default fails, naming the order
#   G7  bad values are refused naming the key; a conf without the key renders
#       byte-identically to the merge base's renderer
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mergify-flake-fix-queue.bh-7279-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/mergify-pause-filter.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ "${CI:-}" = true ] && { echo "FAIL: PyYAML missing under CI=true"; exit 1; }
  echo "python3 PyYAML missing — skipping"; exit 0
fi
MT="$DIR/bin/mergify-template.sh"
BH="$DIR/config/mergify/repos/cromford.conf"
tojson() { python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1"; }
NORM='def norm: map(gsub("^\\s+|\\s+$";"") | gsub("\\s*=\\s*";"=") | gsub("\"";""));'

grep -qx 'flake_fix_label=queue-flake-fix' "$BH" && ok || bad "the cromford conf carries flake_fix_label=queue-flake-fix"

bash "$MT" render "$BH" > "$T/bh.yml" 2>"$T/err"; RC=$?
tojson "$T/bh.yml" > "$T/bh.json" 2>/dev/null || : > "$T/bh.json"
[ "$RC" = 0 ] && [ -s "$T/bh.json" ] && ok || bad "G1 the cromford conf renders (rc $RC): $(cat "$T/err")"
tojson "$DIR/.mergify.yml" > "$T/committed.json" 2>/dev/null || : > "$T/committed.json"

# ── G1: the flake-fix queue ─────────────────────────────────────────────────
for J in "$T/bh.json" "$T/committed.json"; do
  L=$(basename "$J" .json)
  jq -e '(.queue_rules[] | select(.name == "flake-fix")) as $s
         | $s.batch_size == 1 and $s.batch_max_wait_time == "0 s" and $s.max_checks_retries == 0' "$J" >/dev/null 2>&1 \
    && ok || bad "G1 $L: a flake-fix queue with batch_size 1, 0 s, 0 retries: $(jq -c '[.queue_rules[]? | {name, batch_size, batch_max_wait_time, max_checks_retries}]' "$J" 2>/dev/null)"
  jq -e "$NORM"'((.queue_rules[] | select(.name == "flake-fix") | .queue_conditions | norm) - ["label=queue-flake-fix"])
         == (.queue_rules[] | select(.name == "default") | .queue_conditions | norm)
         and ((.queue_rules[] | select(.name == "flake-fix") | .queue_conditions | norm) | index("label=queue-flake-fix") != null)' "$J" >/dev/null 2>&1 \
    && ok || bad "G1 $L: flake-fix's queue_conditions are default's plus label=queue-flake-fix, nothing loosened"
  jq -e "$NORM"'(.queue_rules[] | select(.name == "flake-fix") | .merge_conditions | norm) == (.queue_rules[] | select(.name == "default") | .merge_conditions | norm)' "$J" >/dev/null 2>&1 \
    && ok || bad "G1 $L: flake-fix's merge_conditions equal default's"
  jq -e '(.queue_rules[] | select(.name == "flake-fix")) as $f | (.queue_rules[] | select(.name == "default")) as $d
         | $f.checks_timeout == $d.checks_timeout and $f.merge_method == $d.merge_method
         and ($f | has("batch_max_failure_resolution_attempts") | not)' "$J" >/dev/null 2>&1 \
    && ok || bad "G1 $L: flake-fix takes the conf's checks_timeout and merge_method, and no bisect key"
  # ── G2: no priority rule for it ───────────────────────────────────────────
  jq -e '([.priority_rules[]? | select(([.conditions[]? | tostring] | join(" ")) | test("queue-flake-fix"))] | length == 0)
         and ([.priority_rules[]?.name] == ["hotfix first"])' "$J" >/dev/null 2>&1 \
    && ok || bad "G2 $L: no priority rule names queue-flake-fix, and hotfix first is still the only one"
  # ── G4: the order ─────────────────────────────────────────────────────────
  jq -e '[.queue_rules[].name] as $n | ($n | index("hotfix")) < ($n | index("flake-fix"))
         and ($n | index("flake-fix")) < ($n | index("solo")) and ($n | index("solo")) < ($n | index("default"))' "$J" >/dev/null 2>&1 \
    && ok || bad "G4 $L: queue_rules list hotfix, flake-fix, solo, default (got $(jq -c '[.queue_rules[]?.name]' "$J" 2>/dev/null))"
done

# ── G3: each label set matches exactly the expected rule ────────────────────
for J in "$T/bh.json" "$T/committed.json"; do
python3 - "$J" > "$T/g3.out" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1]))
def norm(c): return re.sub(r"\s*=\s*", "=", c.strip()).replace('"', "")
MQ, FF, SOLO, FMR = "merge-queue", "queue-flake-fix", "queue-solo", "fix-main-red"
table = [({MQ}, ["default"]), ({MQ, FF}, ["flake-fix"]), ({MQ, SOLO}, ["solo"]),
         ({MQ, SOLO, FF}, ["flake-fix"]), ({MQ, FMR, FF}, ["hotfix"]), ({MQ, FMR, SOLO, FF}, ["hotfix"]),
         ({MQ, "hotfix", FF}, ["flake-fix"]), ({MQ, "hotfix"}, ["default"]), ({FF}, []), ({FF, SOLO}, [])]
bad = []
for labels, want in table:
    hits = []
    for r in cfg["pull_request_rules"]:
        okr = True
        for c in map(norm, r["conditions"]):
            if c.startswith("-label="): okr &= c[7:] not in labels
            elif c.startswith("label="): okr &= c[6:] in labels
        if okr: hits.append(r["actions"]["queue"]["name"])
    if hits != want: bad.append("%s -> %s (want %s)" % (sorted(labels), hits, want))
    # the queue a set routes to must admit it on its labels
    for q in hits:
        qc = [norm(c) for r in cfg["queue_rules"] if r["name"] == q for c in r["queue_conditions"]]
        need = [c[6:] for c in qc if c.startswith("label=")]
        if any(n not in labels for n in need): bad.append("%s: queue %s refuses it on labels %s" % (sorted(labels), q, need))
print("\n".join(bad))
PY
! grep -q . "$T/g3.out" && ok || bad "G3 $(basename "$J"): each label set routes to exactly one expected queue: $(cat "$T/g3.out")"
done

# ── G5: --check on the committed tree ───────────────────────────────────────
bash "$MT" --check > "$T/g5.out" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q 'ok: cromford.conf renders and matches .mergify.yml' "$T/g5.out" && ok \
  || bad "G5 --check is green and .mergify.yml matches the render (rc $RC): $(cat "$T/g5.out")"

# ── G6: the order lint ──────────────────────────────────────────────────────
LR="$T/lint"; mkdir -p "$LR/bin" "$LR/config/mergify/repos"
cp "$MT" "$LR/bin/mergify-template.sh"; cp "$BH" "$LR/config/mergify/repos/cromford.conf"
cp "$DIR/config/mergify/template.yml" "$LR/config/mergify/template.yml"
bash "$LR/bin/mergify-template.sh" --check > "$T/g6a.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "G6 the committed template's order passes the lint (rc $RC): $(cat "$T/g6a.out")"
# move the flake-fix placeholder below default (to the end of queue_rules)
python3 - "$LR/config/mergify/template.yml" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("  @@FLAKE_QUEUE_BLOCK@@\n", "", 1)
t = t.replace("    @@BATCH_FAILURE_BLOCK@@\n", "    @@BATCH_FAILURE_BLOCK@@\n  @@FLAKE_QUEUE_BLOCK@@\n", 1)
open(p, "w").write(t)
PY
bash "$LR/bin/mergify-template.sh" --check > "$T/g6b.out" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q 'FAIL: cromford.conf: queue_rules must list hotfix, flake-fix, then solo/default' "$T/g6b.out" && ok \
  || bad "G6 flake-fix below default fails the lint naming the order (rc $RC): $(cat "$T/g6b.out")"
# flake-fix between solo and default fails too
cp "$DIR/config/mergify/template.yml" "$LR/config/mergify/template.yml"
python3 - "$LR/config/mergify/template.yml" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("  @@FLAKE_QUEUE_BLOCK@@\n", "", 1)
t = t.replace("  @@SOLO_QUEUE_BLOCK@@\n", "  @@SOLO_QUEUE_BLOCK@@\n  @@FLAKE_QUEUE_BLOCK@@\n", 1)
open(p, "w").write(t)
PY
bash "$LR/bin/mergify-template.sh" --check > "$T/g6c.out" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q 'queue_rules must list hotfix, flake-fix, then solo/default' "$T/g6c.out" && ok \
  || bad "G6 flake-fix below solo fails the lint (rc $RC): $(cat "$T/g6c.out")"

# ── G7: bad values are refused, naming the key ──────────────────────────────
for v in Queue-Flake merge-queue fix-main-red hotfix queue-solo '-lead' "$(printf 'x%.0s' {1..51})"; do
  { grep -v '^flake_fix_label=' "$BH"; echo "flake_fix_label=$v"; } > "$T/g7.conf"
  ERR=$(bash "$MT" render "$T/g7.conf" 2>&1 >/dev/null); RC=$?
  [ "$RC" = 2 ] && grep -q 'flake_fix_label' <<<"$ERR" && ok || bad "G7 flake_fix_label='$v' is refused naming the key (rc $RC): $ERR"
done
{ grep -v '^flake_fix_label=' "$BH"; echo 'flake_fix_label=queue-flake-fix'; echo 'flake_fix_label=queue-flake-fix'; } > "$T/g7d.conf"
bash "$MT" render "$T/g7d.conf" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "G7 a duplicate flake_fix_label= is refused (rc $RC)"
# without solo_label= the flake queue still renders, between hotfix and default
grep -v '^solo_label=' "$BH" > "$T/g7nosolo.conf"
bash "$MT" render "$T/g7nosolo.conf" > "$T/g7nosolo.yml" 2>/dev/null; RC=$?
tojson "$T/g7nosolo.yml" > "$T/g7nosolo.json" 2>/dev/null || : > "$T/g7nosolo.json"
[ "$RC" = 0 ] && [ "$(jq -c '[.queue_rules[].name]' "$T/g7nosolo.json")" = '["hotfix","flake-fix","default"]' ] && ok \
  || bad "G7 flake_fix_label without solo_label renders hotfix, flake-fix, default (rc $RC): $(jq -c '[.queue_rules[]?.name]' "$T/g7nosolo.json" 2>/dev/null)"
# a conf without the key renders byte-identically to the merge base's renderer.
# The base is passed in (BH7279_BASE) or is the merge base with origin/main;
# with neither, this half is skipped (D60).
BASE="${BH7279_BASE:-}"
[ -n "$BASE" ] || BASE=$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null)
if [ -n "$BASE" ] && git -C "$DIR" cat-file -e "$BASE:bin/mergify-template.sh" 2>/dev/null; then
  OLD="$T/old"; mkdir -p "$OLD/bin" "$OLD/config/mergify"
  git -C "$DIR" show "$BASE:bin/mergify-template.sh" > "$OLD/bin/mergify-template.sh"
  git -C "$DIR" show "$BASE:config/mergify/template.yml" > "$OLD/config/mergify/template.yml"
  grep -v '^flake_fix_label=' "$BH" > "$T/bh-noflake.conf"
  for c in "$DIR/config/mergify/repos/project-5.conf" "$T/bh-noflake.conf"; do
    bash "$OLD/bin/mergify-template.sh" render "$c" > "$T/g7-old.yml" 2>/dev/null
    bash "$MT" render "$c" > "$T/g7-new.yml"
    # TEST-CHANGE (BH-8706): drop the main-red breaker's pause lines from both
    # sides only while the base has none (tests/lib/mergify-pause-filter.sh).
    mergify_pause_filter "$T/g7-old.yml" "$T/g7-new.yml"
    [ -s "$T/g7-old.yml" ] && cmp -s "$T/g7-old.yml" "$T/g7-new.yml" && ok \
      || bad "G7 $(basename "$c") renders byte-identical to the merge base: $(diff "$T/g7-old.yml" "$T/g7-new.yml" | head -5 | tr '\n' ' ')"
  done
else
  echo "G7 no merge base — the byte-identity half is skipped"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
