#!/bin/bash
# tests/mergify-template-paused.bh-8706-test.sh — the main-red breaker's pause
# label (BH-8706). bin/main-red-breaker.sh adds `merge-queue-paused` to a PR
# that is already in the Mergify queue while main is red. Every NON-hotfix
# pull_request_rule must exclude that label, so Mergify dequeues the PR and
# re-queues it when the breaker removes the label. The hotfix rule must NOT
# exclude it: a fix-main-red PR still lands while main is red.
#
# Every render goes through a scratch copy of the real CLI
# ("$DIR/bin/mergify-template.sh"), "$DIR/config/mergify/template.yml", the confs
# and "$DIR/.mergify.yml". Conditions are read from the PARSED YAML (python3 +
# PyYAML), never grepped from the text. Without PyYAML the suite skips when CI
# is not "true" and fails when it is.
#
# R7 pins the same exclusion in the queue_conditions of every non-hotfix queue.
#
# Run from anywhere: tests/mergify-template-paused.bh-8706-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
T=$SCRATCH
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if ! python3 -c 'import yaml' 2>/dev/null; then
  if [ "${CI:-}" = true ]; then echo "FAIL: PyYAML missing in CI"; exit 1; fi
  echo "SKIP: PyYAML missing"; exit 0
fi

R="$T/repo"
mkdir -p "$R/bin" "$R/config"
cp "$DIR/bin/mergify-template.sh" "$R/bin/"
cp -R "$DIR/config/mergify" "$R/config/"
cp "$DIR/.mergify.yml" "$R/.mergify.yml"
BIN="$R/bin/mergify-template.sh"

# rules_check <yaml-file> — rc 0 when every non-hotfix pull_request_rule holds
# `-label=merge-queue-paused`, the hotfix rule does not, and a default rule
# exists. Prints one line per rule: <queue name> <paused yes|no>.
rules_check() {
  python3 - "$1" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
rc, seen = 0, set()
for r in doc.get("pull_request_rules") or []:
    q = (((r.get("actions") or {}).get("queue") or {}).get("name"))
    conds = [str(c).replace(" ", "") for c in (r.get("conditions") or [])]
    paused = "-label=merge-queue-paused" in conds
    print("%s %s" % (q, "yes" if paused else "no"))
    seen.add(q)
    if q == "hotfix":
        if paused or any("merge-queue-paused" in c for c in conds):
            rc = 1
    elif not paused:
        rc = 1
if "default" not in seen or "hotfix" not in seen:
    rc = 1
sys.exit(rc)
PYEOF
}

# R1: the render of every conf pauses default/solo/flake-fix and not hotfix.
n=0
for conf in "$R"/config/mergify/repos/*.conf; do
  n=$((n+1)); name=$(basename "$conf")
  if ! "$BIN" render "$conf" > "$T/$name.yml" 2>"$T/$name.err"; then
    bad "R1 $name: render failed: $(head -c 300 "$T/$name.err")"; continue
  fi
  out=$(rules_check "$T/$name.yml"); rc=$?
  [ "$rc" = 0 ] && ok || bad "R1 $name: pause conditions wrong: $(echo "$out" | tr '\n' ' ')"
done
[ "$n" -ge 4 ] && ok || bad "R1 only $n conf(s) found under config/mergify/repos"

# R2: cromford carries all three non-hotfix rules (solo and flake-fix are set),
# so the pause condition appears on exactly default, solo and flake-fix.
out=$(rules_check "$T/cromford.conf.yml" | sort | tr '\n' ' ')
[ "$out" = "default yes flake-fix yes hotfix no solo yes " ] && ok || bad "R2 cromford rules: got '$out'"

# R3: the committed .mergify.yml (what Mergify reads) says the same.
out=$(rules_check "$R/.mergify.yml" | sort | tr '\n' ' '); rc=$?
[ "$out" = "default yes flake-fix yes hotfix no solo yes " ] && ok || bad "R3 .mergify.yml rules: got '$out'"

# R4: --check over the scratch tree is green.
"$BIN" --check > "$T/check.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "R4 --check rc $rc (want 0): $(head -c 400 "$T/check.out")"

# R5: a conf cannot reuse the pause label as its solo or flake-fix label (rc 2).
for key in solo_label flake_fix_label; do
  c="$T/bad-$key.conf"
  grep -v "^$key=" "$R/config/mergify/repos/cromford.conf" > "$c"
  echo "$key=merge-queue-paused" >> "$c"
  "$BIN" render "$c" > /dev/null 2>"$T/bad.err"; rc=$?
  [ "$rc" = 2 ] && ok || bad "R5 $key=merge-queue-paused rc $rc (want 2)"
  grep -q "merge-queue-paused" "$T/bad.err" && ok || bad "R5 $key: error does not name the label: $(head -c 200 "$T/bad.err")"
done

# R6: near miss — a .mergify.yml without the pause line on the default rule
# drifts from the render (--check rc 1).
python3 - "$R/.mergify.yml" "$T/drift.yml" <<'PYEOF'
import sys
s = open(sys.argv[1]).read()
needle = "      - -label = merge-queue-paused\n"
i = s.find("  - name: queue on the harness label")
j = s.find(needle, i)
open(sys.argv[2], "w").write(s[:j] + s[j + len(needle):] if i >= 0 and j >= 0 else s)
PYEOF
"$BIN" compare "$R/config/mergify/repos/cromford.conf" "$T/drift.yml" > /dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "R6 a .mergify.yml without the default rule's pause line compares rc $rc (want 1)"

# R7: the queue_conditions of every non-hotfix queue_rule carry the pause, and
# the hotfix queue's do not. queue_conditions bind a `@mergifyio queue` entry,
# which never meets a pull_request_rule (docs/MERGIFY.md), so this is the line
# that dequeues the PR.
qrules_check() {
  python3 - "$1" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
out = []
for q in doc.get("queue_rules") or []:
    conds = [str(c).replace(" ", "") for c in (q.get("queue_conditions") or [])]
    out.append("%s %s" % (q.get("name"), "yes" if "-label=merge-queue-paused" in conds else "no"))
print(" ".join(sorted(out)))
PYEOF
}
for f in "$T/cromford.conf.yml" "$R/.mergify.yml"; do
  out=$(qrules_check "$f")
  [ "$out" = "default yes flake-fix yes hotfix no solo yes" ] && ok || bad "R7 $(basename "$f") queue_conditions: got '$out'"
done
for f in "$T"/project-5.conf.yml "$T"/project-3.conf.yml "$T"/project-2.conf.yml; do
  out=$(qrules_check "$f")
  case "$out" in "default yes"*"hotfix no"*) ok ;; *) bad "R7 $(basename "$f") queue_conditions: got '$out'" ;; esac
done

echo "mergify-template-paused: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
