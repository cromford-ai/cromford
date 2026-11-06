#!/bin/bash
# tests/mergify-queue-check-test.sh — bin/mergify-template.sh's queue_check= key
# (2026-09-24, "each tree is tested exactly once").
#
# WHY. cromford now runs its test corpus ONLY on the merge queue's batch
# draft. An ordinary PR never runs those checks, so a queue_conditions list
# that asks for them would keep every PR out of the queue forever; and an
# in-place check (a batch of one checked on the PR itself) would run the PR's
# fast CI only. The conf therefore says which checks let a PR IN (queue_check=)
# apart from which checks let a batch MERGE (check=); with the two lists
# different, Mergify always builds a draft (it deprecated allow_inplace_checks).
#
#   K1  queue_check= feeds queue_conditions in BOTH queues; check= still feeds
#       merge_conditions in both
#   K2  the two lists differ, so no queue can be checked in place
#   K3  a conf without the key renders exactly as before (the list in both
#       condition blocks) — project-5's render cannot move
#   K4  a queue_check that is not also a check= is refused (a PR could enter on a
#       check the batch never has to pass), and so is the retired inplace key
#   K5  the repo's own conf and .mergify.yml agree (--check)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
MT="$DIR/bin/mergify-template.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "mergify-queue-check: PyYAML missing — skipping on this dev machine"; exit 0
fi
q() { # q <yaml-file> <queue> <key> — that queue's check-success names, one per line
  python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for r in d.get("queue_rules") or []:
    if r.get("name") == sys.argv[2]:
        v = r.get(sys.argv[3])
        if isinstance(v, list):
            for c in v:
                c = str(c)
                if c.startswith("check-success"): print(c.split("=", 1)[1].strip())
        elif v is not None:
            print(str(v).lower())
PY
}

cat > "$T/split.conf" <<'CONF'
slug=o/r
check=fast
check=slow
queue_check=fast
CONF
"$MT" render "$T/split.conf" > "$T/split.yml" 2>"$T/err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "K1: a split conf must render (rc=$RC): $(cat "$T/err")"
for QN in hotfix default; do
  [ "$(q "$T/split.yml" "$QN" queue_conditions)" = "fast" ] && ok || bad "K1: $QN.queue_conditions must be the queue_check list: $(q "$T/split.yml" "$QN" queue_conditions | tr '\n' ' ')"
  [ "$(q "$T/split.yml" "$QN" merge_conditions | tr '\n' ' ')" = "fast slow " ] && ok || bad "K1: $QN.merge_conditions must be every check=: $(q "$T/split.yml" "$QN" merge_conditions | tr '\n' ' ')"
  [ "$(q "$T/split.yml" "$QN" queue_conditions)" != "$(q "$T/split.yml" "$QN" merge_conditions)" ] && ok || bad "K2: $QN queue and merge checks must differ"
done

cat > "$T/plain.conf" <<'CONF'
slug=o/r
check=fast
check=slow
CONF
"$MT" render "$T/plain.conf" > "$T/plain.yml" 2>"$T/err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "K3: a plain conf must render (rc=$RC)"
for QN in hotfix default; do
  [ "$(q "$T/plain.yml" "$QN" queue_conditions | tr '\n' ' ')" = "fast slow " ] && ok || bad "K3: without queue_check, $QN.queue_conditions must be every check="
  [ -z "$(q "$T/plain.yml" "$QN" allow_inplace_checks)" ] && ok || bad "K3: $QN must render no allow_inplace_checks line"
done
grep -q '@@' "$T/plain.yml" && bad "K3: an unresolved token leaked into the render" || ok
grep -q '^ *$' "$T/plain.yml" && [ "$(grep -c '^    $' "$T/plain.yml")" != 0 ] && bad "K3: the absent inplace line left a blank indented line" || ok

printf 'slug=o/r\ncheck=fast\nqueue_check=other\n' > "$T/bad1.conf"
"$MT" render "$T/bad1.conf" >/dev/null 2>"$T/err"; RC=$?
[ "$RC" -eq 2 ] && grep -q 'queue_check' "$T/err" && ok || bad "K4: a queue_check that is not a check= must be refused (rc=$RC): $(cat "$T/err")"
printf 'slug=o/r\ncheck=fast\nallow_inplace_checks=maybe\n' > "$T/bad2.conf"
"$MT" render "$T/bad2.conf" >/dev/null 2>"$T/err"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "K4: the retired allow_inplace_checks key must be refused (rc=$RC)"

OUT=$("$MT" --check 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "K5: the repo's .mergify.yml must match its conf: $OUT"
# BH-3348: plus the lead-verdict commit STATUS (status_check=), which is not a
# CI check; tests/mergify-status-check.bh-3348-test.sh pins it. TEST-CHANGE
# (BH-9039): that status is now the status_check_any regex
# `check-success~=^(lead-verdict|harness-verdict)$`, which q() prints as the
# regex; tests/verdict-builder-context.bh-9039-test.sh pins it.
[ "$(q "$DIR/.mergify.yml" default queue_conditions | grep -vxF -e '"lead-verdict"' -e '^(lead-verdict|harness-verdict)$' | wc -l | tr -d ' ')" = 3 ] && ok \
  || bad "K5: cromford queues a PR on the three fast checks: $(q "$DIR/.mergify.yml" default queue_conditions | tr '\n' ',')"

echo "mergify-queue-check: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
