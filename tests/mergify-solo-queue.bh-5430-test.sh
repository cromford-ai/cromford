#!/bin/bash
# tests/mergify-solo-queue.bh-5430-test.sh — BH-5430: a conf's solo_label=
# renders a size-1 `solo` queue that a PR carrying merge-queue AND that label
# routes to, and the default rule excludes the label so no PR matches two rules.
#
#   M1  the solo queue: batch_size 1, wait 0 s, retries 0, label=<solo_label> in
#       queue_conditions, merge_conditions equal to default's
#   M2  the routing: default rule carries -label=queue-solo, a solo rule routes
#       merge-queue + queue-solo - fix-main-red to solo; hotfix unchanged
#   M3  a conf without solo_label= renders byte-identically to main's renderer
#   M4  bad solo_label values are refused, naming the key
#   M5  the order lint: hotfix, solo, default
#   M6  bin/mergify-template.sh --check is green on the committed tree
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mergify-solo-queue.bh-5430-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
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

# The committed cromford conf names the label.
grep -qx 'solo_label=queue-solo' "$BH" && ok || bad "the cromford conf carries solo_label=queue-solo"

# ── M1: the solo queue ──────────────────────────────────────────────────────
bash "$MT" render "$BH" > "$T/bh.yml" 2>"$T/err"; RC=$?
tojson "$T/bh.yml" > "$T/bh.json" 2>/dev/null || : > "$T/bh.json"
[ "$RC" = 0 ] && [ -s "$T/bh.json" ] && ok || bad "M1 the cromford conf renders (rc $RC): $(cat "$T/err")"
jq -e '(.queue_rules[] | select(.name == "solo")) as $s
       | $s.batch_size == 1 and $s.batch_max_wait_time == "0 s" and $s.max_checks_retries == 0' "$T/bh.json" >/dev/null 2>&1 \
  && ok || bad "M1 a solo queue with batch_size 1, 0 s, 0 retries: $(jq -c '[.queue_rules[]? | {name, batch_size, batch_max_wait_time, max_checks_retries}]' "$T/bh.json" 2>/dev/null)"
jq -e "$NORM"'(.queue_rules[] | select(.name == "solo") | .queue_conditions | norm) | index("label=queue-solo") != null' "$T/bh.json" >/dev/null 2>&1 \
  && ok || bad "M1 solo's queue_conditions carry label=queue-solo"
jq -e "$NORM"'((.queue_rules[] | select(.name == "solo") | .queue_conditions | norm) - ["label=queue-solo"])
       == (.queue_rules[] | select(.name == "default") | .queue_conditions | norm)' "$T/bh.json" >/dev/null 2>&1 \
  && ok || bad "M1 solo's queue_conditions are default's plus the label, nothing loosened"
jq -e "$NORM"'(.queue_rules[] | select(.name == "solo") | .merge_conditions | norm) == (.queue_rules[] | select(.name == "default") | .merge_conditions | norm)' "$T/bh.json" >/dev/null 2>&1 \
  && ok || bad "M1 solo's merge_conditions equal default's"
jq -e '(.queue_rules[] | select(.name == "solo") | .checks_timeout) == (.queue_rules[] | select(.name == "default") | .checks_timeout)
       and (.queue_rules[] | select(.name == "solo") | .merge_method) == (.queue_rules[] | select(.name == "default") | .merge_method)' "$T/bh.json" >/dev/null 2>&1 \
  && ok || bad "M1 solo takes the conf's checks_timeout and merge_method"
jq -e '[.priority_rules[]? | select(([.conditions[]? | tostring] | join(" ")) | test("queue-solo"))] | length == 0' "$T/bh.json" >/dev/null 2>&1 \
  && ok || bad "M1 no priority rule names queue-solo (nothing interrupts running checks for it)"

# ── M2: the routing ─────────────────────────────────────────────────────────
jq -e "$NORM"'[.pull_request_rules[] | select(.actions.queue.name == "default") | .conditions | norm] | length == 1 and (.[0] | index("-label=queue-solo") != null)' "$T/bh.json" >/dev/null 2>&1 \
  && ok || bad "M2 the default rule carries -label=queue-solo: $(jq -c '[.pull_request_rules[]? | select(.actions.queue.name == "default") | .conditions]' "$T/bh.json" 2>/dev/null)"
jq -e "$NORM"'[.pull_request_rules[] | select(.actions.queue.name == "solo") | .conditions | norm] | length == 1
       and (.[0] | index("label=merge-queue") != null and index("label=queue-solo") != null and index("-label=fix-main-red") != null)' "$T/bh.json" >/dev/null 2>&1 \
  && ok || bad "M2 one rule routes merge-queue + queue-solo - fix-main-red to solo: $(jq -c '[.pull_request_rules[]? | {c: .conditions, q: .actions.queue.name}]' "$T/bh.json" 2>/dev/null)"
# every label combination matches at most one queue rule
python3 - "$T/bh.json" > "$T/m2.out" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1]))
def norm(c): return re.sub(r"\s*=\s*", "=", c.strip()).replace('"', "")
bad = []
for labels in [set(), {"merge-queue"}, {"merge-queue", "queue-solo"}, {"merge-queue", "fix-main-red"},
               {"merge-queue", "queue-solo", "fix-main-red"}, {"queue-solo"}]:
    hits = []
    for r in cfg["pull_request_rules"]:
        okr = True
        for c in map(norm, r["conditions"]):
            if c.startswith("-label="): okr &= c[7:] not in labels
            elif c.startswith("label="): okr &= c[6:] in labels
        if okr: hits.append(r["actions"]["queue"]["name"])
    want = {frozenset(): [], frozenset({"merge-queue"}): ["default"], frozenset({"merge-queue", "queue-solo"}): ["solo"],
            frozenset({"merge-queue", "fix-main-red"}): ["hotfix"], frozenset({"merge-queue", "queue-solo", "fix-main-red"}): ["hotfix"],
            frozenset({"queue-solo"}): []}[frozenset(labels)]
    if hits != want: bad.append("%s -> %s (want %s)" % (sorted(labels), hits, want))
print("\n".join(bad))
PY
! grep -q . "$T/m2.out" && ok || bad "M2 each label set matches exactly the expected queue rule: $(cat "$T/m2.out")"
# hotfix queue and rule are unchanged from main's render
if git -C "$DIR" rev-parse --verify -q origin/main >/dev/null; then
  OLD="$T/old"; mkdir -p "$OLD/bin" "$OLD/config/mergify"
  git -C "$DIR" show origin/main:bin/mergify-template.sh > "$OLD/bin/mergify-template.sh"
  git -C "$DIR" show origin/main:config/mergify/template.yml > "$OLD/config/mergify/template.yml"
  # flake_fix_label= (BH-7279) is another queue's key; both sides leave it out.
  grep -v -e '^solo_label=' -e '^flake_fix_label=' "$BH" > "$T/bh-nosolo.conf"
  bash "$OLD/bin/mergify-template.sh" render "$T/bh-nosolo.conf" > "$T/old-bh.yml" 2>"$T/old.err"
  tojson "$T/old-bh.yml" > "$T/old-bh.json" 2>/dev/null || : > "$T/old-bh.json"
  for sel in '.queue_rules[] | select(.name == "hotfix")' '.pull_request_rules[] | select(.actions.queue.name == "hotfix")' '.priority_rules'; do
    [ -s "$T/old-bh.json" ] && [ "$(jq -cS "$sel" "$T/old-bh.json")" = "$(jq -cS "$sel" "$T/bh.json")" ] && ok \
      || bad "M2 '$sel' is unchanged from main's render: $(cat "$T/old.err")"
  done
  # ── M3: no solo_label= renders byte-identically to main ───────────────────
  for c in "$DIR/config/mergify/repos/project-5.conf" "$T/bh-nosolo.conf"; do
    bash "$OLD/bin/mergify-template.sh" render "$c" > "$T/m3-old.yml" 2>/dev/null
    bash "$MT" render "$c" > "$T/m3-new.yml"
    [ -s "$T/m3-old.yml" ] && cmp -s "$T/m3-old.yml" "$T/m3-new.yml" && ok \
      || bad "M3 $(basename "$c") renders byte-identical to main: $(diff "$T/m3-old.yml" "$T/m3-new.yml" | head -5 | tr '\n' ' ')"
  done
else
  echo "M2/M3 no origin/main ref — the byte-identity half is skipped"
fi

# ── M4: bad values are refused, naming the key ──────────────────────────────
for v in merge-queue 'Bad Label' fix-main-red '-lead' "$(printf 'x%.0s' {1..51})"; do
  { grep -v '^solo_label=' "$BH"; echo "solo_label=$v"; } > "$T/m4.conf"
  ERR=$(bash "$MT" render "$T/m4.conf" 2>&1 >/dev/null); RC=$?
  [ "$RC" = 2 ] && grep -q 'solo_label' <<<"$ERR" && ok || bad "M4 solo_label='$v' is refused naming the key (rc $RC): $ERR"
done
{ grep -v '^solo_label=' "$BH"; echo 'solo_label=queue-solo'; echo 'solo_label=queue-solo'; } > "$T/m4d.conf"
bash "$MT" render "$T/m4d.conf" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "M4 a duplicate solo_label= is refused (rc $RC)"
{ grep -v '^solo_label=' "$BH"; echo 'solo_label=risky-1'; } > "$T/m4ok.conf"
bash "$MT" render "$T/m4ok.conf" > "$T/m4ok.yml" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && grep -q 'label=risky-1' "$T/m4ok.yml" && ok || bad "M4 another valid label renders through (rc $RC)"

# ── M5: the order lint ──────────────────────────────────────────────────────
# A scratch root: the real renderer and template, a conf whose render puts solo
# first, and no .mergify.yml (so --check judges the render alone).
LR="$T/lint"; mkdir -p "$LR/bin" "$LR/config/mergify/repos"
cp "$MT" "$LR/bin/mergify-template.sh"; cp "$BH" "$LR/config/mergify/repos/cromford.conf"
cp "$DIR/config/mergify/template.yml" "$LR/config/mergify/template.yml"
bash "$LR/bin/mergify-template.sh" --check > "$T/m5a.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "M5 the committed template's order passes the lint (rc $RC): $(cat "$T/m5a.out")"
python3 - "$LR/config/mergify/template.yml" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
# move the solo placeholder above the hotfix queue
t = t.replace("  @@SOLO_QUEUE_BLOCK@@\n", "")
t = t.replace("  - name: hotfix\n", "  @@SOLO_QUEUE_BLOCK@@\n  - name: hotfix\n", 1)
open(p, "w").write(t)
PY
bash "$LR/bin/mergify-template.sh" --check > "$T/m5b.out" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q 'FAIL: cromford.conf: queue_rules must list hotfix, solo, default' "$T/m5b.out" && ok \
  || bad "M5 solo before hotfix fails the lint naming the order (rc $RC): $(cat "$T/m5b.out")"

# ── M6: --check on the committed tree ───────────────────────────────────────
bash "$MT" --check > "$T/m6.out" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q 'ok: cromford.conf renders and matches .mergify.yml' "$T/m6.out" && ok \
  || bad "M6 --check is green and .mergify.yml matches the render (rc $RC): $(cat "$T/m6.out")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
