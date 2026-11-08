#!/bin/bash
# tests/count-builds-self.bh-wip-test.sh — the WIP gate in bin/lib/rb/gates.sh
# runs INSIDE run-build.sh, so a plain `count-builds.sh <project>` counts the
# asking build itself: with flags/wip-limit-<p> = 1 every non-hotfix local
# build answered BUILD_DEFERRED (project-6-desktop, 2026-10-27 to 2026-11-06,
# 2,027 deferred build dirs). count-builds.sh <project> <exclude-key> leaves
# that one build out; the gate passes $KEY.
# Run from anywhere: tests/count-builds-self.bh-wip-test.sh   (exit 0 = all pass)
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin"
# A fake ps: the asking build (p TK-8), one other build of p, one of q.
cat > "$T/bin/ps" <<'PS'
#!/bin/bash
cat <<'OUT'
/bin/bash /root/harness/bin/run-build.sh p 8 TK-8
/bin/bash /root/harness/bin/run-build.sh p 9 TK-9
/bin/bash /root/harness/bin/run-build.sh q 3 Q-3
/usr/bin/vim bin/run-build.sh p 1 X-1
OUT
PS
chmod +x "$T/bin/ps"
cb() { PATH="$T/bin:$PATH" bash "$DIR/bin/count-builds.sh" "$@"; }

[ "$(cb p)" = 2 ] && ok || bad "C1 count-builds p want 2 (self + sibling), got $(cb p)"
[ "$(cb p TK-8)" = 1 ] && ok || bad "C2 count-builds p TK-8 want 1 (sibling only), got $(cb p TK-8)"
[ "$(cb p TK-7)" = 2 ] && ok || bad "C3 an exclude key that is not running excludes nothing, got $(cb p TK-7)"
[ "$(cb)" = 3 ] && ok || bad "C4 box-wide count unchanged, want 3, got $(cb)"

# C5: the gate passes its own key, so the asking build is not its own blocker.
grep -q 'count-builds.sh" "$PROJECT" "$KEY"' "$DIR/bin/lib/rb/gates.sh" && ok \
  || bad "C5 the WIP gate in bin/lib/rb/gates.sh does not pass \$KEY to count-builds.sh"

echo "count-builds-self: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
