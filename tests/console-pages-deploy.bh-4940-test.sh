#!/bin/bash
# tests/console-pages-deploy.bh-4940-test.sh — the console-pages-deploy-red
# alert names each failing test's FILE, not just its title (BH-4940).
#
# WHY. The 2026-10-06 20:07Z red alert named "B9 the mounted /now and /needs
# read the jobs ledger and count from it" and nothing else; finding the file
# meant opening the kept test log. Node 22's TAP has no per-file wrapper, so the
# file comes from the failing test's YAML `location:`.
#
#   N1  Node 22 shape: title [tests/<file>], no absolute path, no :L:C
#   N2  Node 20 wrapper shape: title [tests/panel.test.js], wrapper not listed
#   N3  a file that failed to load: listed once, by file
#   N4  two failures in two files with a passing test between: each its own file
#   N5  seven failures: five names (the cap)
#   N6  a location outside a .test.js: the bare title
#   N7  the fenced block exists and assigns NAMES=
#
# SCRIPT= points the suite at another deployer.
# Run from anywhere: tests/console-pages-deploy.bh-4940-test.sh  (0 = pass)
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk() { if eval "$2"; then ok; else bad "$1"; fi; }
SUT="${SCRIPT:-$DIR/bin/console-pages-deploy.sh}"

BLOCK=$(awk '/# >>> red test names/,/# <<< red test names/' "$SUT")
# names — the block run over the test.log on stdin; prints NAMES.
names() { cat > "$T/test.log"; D=$T bash -c "$BLOCK"$'\nprintf "%s" "$NAMES"'; }

# ── N7 ───────────────────────────────────────────────────────────────────────
chk "N7 the fenced block is present" '[ -n "$BLOCK" ]'
chk "N7 the block assigns NAMES" 'grep -qE "^[[:space:]]*NAMES=\\$\\(awk" <<<"$BLOCK"'

# ── N1 ───────────────────────────────────────────────────────────────────────
B9='B9 the mounted /now and /needs read the jobs ledger and count from it'
OUT=$(names <<EOF
TAP version 13
# Subtest: B8 earlier
ok 157 - B8 earlier
  ---
  duration_ms: 2.1
  type: 'test'
  location: '/root/harness/state/console-snap.Ab12/console-ui/tests/building-now.bh-3569.test.js:240:1'
  ...
# Subtest: $B9
not ok 158 - $B9
  ---
  duration_ms: 151.2
  type: 'test'
  location: '/root/harness/state/console-snap.Ab12/console-ui/tests/building-now.bh-3569.test.js:267:1'
  failureType: 'testCodeFailure'
  error: ''
  code: 'ERR_ASSERTION'
  stack: |-
    TestContext.<anonymous> (file:///root/harness/state/console-snap.Ab12/console-ui/tests/building-now.bh-3569.test.js:278:10)
  ...
1..158
# pass 157
# fail 1
EOF
)
chk "N1 title and file" '[ "$OUT" = "$B9 [tests/building-now.bh-3569.test.js]" ]'
chk "N1 no absolute path" '! grep -qF /root/ <<<"$OUT"'
chk "N1 no :L:C" '! grep -qF :267 <<<"$OUT"'

# ── N2 ───────────────────────────────────────────────────────────────────────
OUT=$(printf 'TAP version 13\n# Subtest: tests/panel.test.js\n    not ok 7 - BuildQueuePanel (mounted): a refused DROP keeps the row\nnot ok 1 - tests/panel.test.js\n# pass 40\n# fail 1\n' | names)
chk "N2 wrapper file attributed" '[ "$OUT" = "BuildQueuePanel (mounted): a refused DROP keeps the row [tests/panel.test.js]" ]'

# ── N3 ───────────────────────────────────────────────────────────────────────
OUT=$(printf 'TAP version 13\nnot ok 1 - tests/broken.test.js\n  ---\n  error: boom\n  ...\n# fail 1\n' | names)
chk "N3 failed load: the file, once" '[ "$OUT" = "tests/broken.test.js" ]'

# ── N4 ───────────────────────────────────────────────────────────────────────
OUT=$(names <<'EOF'
TAP version 13
# Subtest: A1 first
not ok 1 - A1 first
  ---
  location: '/s/console-ui/tests/a.bh-1.test.js:5:1'
  ...
# Subtest: P1 passes
ok 2 - P1 passes
  ---
  location: '/s/console-ui/tests/pass.bh-9.test.js:9:1'
  ...
# Subtest: C1 second
not ok 3 - C1 second
  ---
  location: '/s/console-ui/tests/c.bh-2.test.js:7:1'
  ...
# Subtest: C2 no yaml location
not ok 4 - C2 no yaml location
# Subtest: P2 passes after
ok 5 - P2 passes after
  ---
  location: '/s/console-ui/tests/pass.bh-9.test.js:12:1'
  ...
# fail 3
EOF
)
chk "N4 each title carries its own file" '[ "$OUT" = "A1 first [tests/a.bh-1.test.js]; C1 second [tests/c.bh-2.test.js]; C2 no yaml location" ]'
chk "N4 a passing test's file is never attributed" '! grep -qF pass.bh-9 <<<"$OUT"'
# The same without `# Subtest:` lines: the `ok` line alone ends the failure.
OUT=$(printf "not ok 1 - C3 bare\nok 2 - P3 passes\n  ---\n  location: '/s/tests/pass.bh-9.test.js:3:1'\n  ...\n" | names)
chk "N4 no Subtest lines: still not attributed" '[ "$OUT" = "C3 bare" ]'

# ── N5 ───────────────────────────────────────────────────────────────────────
OUT=$(for i in 1 2 3 4 5 6 7; do printf 'not ok %s - T%s\n  ---\n  location: %s/s/tests/f%s.test.js:1:1%s\n  ...\n' "$i" "$i" "'" "$i" "'"; done | names)
chk "N5 five names" '[ "$(printf "%s" "$OUT" | awk -F"; " "{print NF}")" = 5 ]'
chk "N5 the first five, each with its file" '[ "$OUT" = "T1 [tests/f1.test.js]; T2 [tests/f2.test.js]; T3 [tests/f3.test.js]; T4 [tests/f4.test.js]; T5 [tests/f5.test.js]" ]'

# ── N6 ───────────────────────────────────────────────────────────────────────
OUT=$(printf "not ok 1 - H1 helper threw\n  ---\n  location: 'tests/helpers/settle.js:9:3'\n  ...\n" | names)
chk "N6 location outside a .test.js: the bare title" '[ "$OUT" = "H1 helper threw" ]'

echo "console-pages-deploy.bh-4940: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
