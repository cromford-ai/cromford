#!/bin/bash
# tests/rebase-job-workspaces.bh-7953-test.sh — the pool rebase links the
# nested node_modules of each npm workspace into its worktree (BH-7953).
#
# THE DEFECT. Step 7 linked only <repo>/node_modules into the worktree.
# project-6 is an npm workspaces repo ("workspaces": ["packages/*"]), and npm
# installs a nested packages/spec-compiler/node_modules (ajv) when a version
# conflicts with the root. The worktree had no nested node_modules, so
# `npm run typecheck --workspaces` was TS2307 on every project-6-os pool rebase
# from 2026-10-20. The fixture here is that shape: packages/a/node_modules/x
# exists on the machine ONLY nested, and the typecheck prints a tsc error and
# exits 2 when the worktree cannot see it.
#
# Cases (the REAL rebase_job_run on scratch git repos, the bh-7656 fixture):
#   W1. "workspaces": ["packages/*"] -> packages/a/node_modules is linked,
#       typecheck green, REBASED, `GATE: typecheck=0`. Not linked: a machine
#       dir the merged tree does not have (packages/gone), and a dir that is
#       not a workspace (tools). No node_modules is pushed.
#   W2. the {"packages": [...]} form with a plain path ("apps/x") -> linked,
#       REBASED.
#   W3. no "workspaces" -> nothing nested is linked (the old behavior), the
#       root node_modules still is, REBASED.
#   W4. no root node_modules -> gates skipped, nothing is linked, REBASED.
#   T.  no `rebase-log-*` file is left in $TMPDIR after any run.
#
# MUTATIONS THAT TURN THIS SUITE RED (checked 2026-10-21):
#   - delete the _rj_link_ws call in step 7          -> W1, W2 red
#   - link every <repo>/*/node_modules, declared or not -> W1 (tools), W3 red
#   - drop the `[ -d "$wt/$d" ]` check                -> W1 (packages/gone) red
#
# Run from anywhere: bash tests/rebase-job-workspaces.bh-7953-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=o/tproj
LIB="$DIR/bin/lib/rebase-job.sh"
TSERR="packages/a/src/v.ts(8,23): error TS2307: Cannot find module 'x/index.js'"

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.detachedHead false

mkdir -p "$T/fakebin" "$T/wt" "$T/tmp" "$T/h/logs" "$T/h/state"
scratch_install_closure bin/lib/rebase-job.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
rm -f "$T/h/bin/test-select.sh"

# --- the faked binaries: npm runs the package.json script through bash ------
cat > "$T/fakebin/npm" <<'NPMEOF'
#!/bin/bash
[ "${1:-}" = run ] || exit 0
S=$(jq -r --arg s "$2" '.scripts[$s] // ""' package.json 2>/dev/null)
[ -n "$S" ] || exit 1
printf '\n> tproj@1.0.0 %s\n> %s\n\n' "$2" "$S"
bash -c "$S"; rc=$?
[ "$rc" = 0 ] || printf 'npm ERR! code ELIFECYCLE\nnpm ERR! errno %s\n' "$rc"
exit "$rc"
NPMEOF
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_gh "$T/fakebin" || exit 1
chmod +x "$T/fakebin/npm"
export PATH="$T/fakebin:$PATH" REBASE_WT_DIR="$T/wt" TMPDIR="$T/tmp"
export SEEN="$T/seen"

# --- the fixture -------------------------------------------------------------
# tools/tc.sh is the typecheck. It writes what the worktree can see to $SEEN,
# then exits 2 with tsc's line when $NEED (a path in the tree) is missing.
PKG_ARR='{"name":"tproj","version":"1.0.0","workspaces":["packages/*"],"scripts":{"typecheck":"NEED=packages/a/node_modules/x/index.js sh tools/tc.sh"}}'
PKG_OBJ='{"name":"tproj","version":"1.0.0","workspaces":{"packages":["apps/x"]},"scripts":{"typecheck":"NEED=apps/x/node_modules/x/index.js sh tools/tc.sh"}}'
PKG_NONE='{"name":"tproj","version":"1.0.0","scripts":{"typecheck":"NEED=node_modules/.keep sh tools/tc.sh"}}'

mkorigin() { # mkorigin <name> <package.json> — origin + seed + one branch, main moved
  git init -q --bare "$T/$1.git"
  git clone -q "$T/$1.git" "$T/$1.seed" 2>/dev/null
  mkdir -p "$T/$1.seed/tools" "$T/$1.seed/packages/a/src" "$T/$1.seed/apps/x"
  printf 'node_modules\n' > "$T/$1.seed/.gitignore"
  printf '%s\n' "$2" > "$T/$1.seed/package.json"
  echo '{"name":"a"}' > "$T/$1.seed/packages/a/package.json"
  echo '{"name":"x"}' > "$T/$1.seed/apps/x/package.json"
  echo "import { v } from 'x/index.js'" > "$T/$1.seed/packages/a/src/v.ts"
  cat > "$T/$1.seed/tools/tc.sh" <<EOF
#!/bin/sh
echo "tsc --noEmit"
for p in node_modules packages/a/node_modules apps/x/node_modules packages/gone tools/node_modules; do
  if [ -e "\$p" ]; then echo "\$p=yes"; else echo "\$p=no"; fi
done > "\$SEEN"
if [ ! -e "\$NEED" ]; then
  printf '%s\n' "$TSERR"
  echo "Found 1 error in 1 file."
  exit 2
fi
exit 0
EOF
  git -C "$T/$1.seed" add -A && git -C "$T/$1.seed" commit -qm base1
  git -C "$T/$1.seed" push -q origin main
  git -C "$T/$1.seed" checkout -q -b ticket/bh-1
  echo d > "$T/$1.seed/d.txt"
  git -C "$T/$1.seed" add -A && git -C "$T/$1.seed" commit -qm branch >/dev/null
  git -C "$T/$1.seed" push -q origin ticket/bh-1
  HEAD_SHA=$(git -C "$T/$1.seed" rev-parse HEAD)
  git -C "$T/$1.seed" checkout -q main
  echo z > "$T/$1.seed/z.txt"
  git -C "$T/$1.seed" add -A && git -C "$T/$1.seed" commit -qm main2 >/dev/null
  git -C "$T/$1.seed" push -q origin main
}
mkmachine() { # mkmachine <origin> [nodeps] — the install: x only NESTED, never at the root
  rm -rf "$T/machine"
  git clone -q --depth 1 --single-branch "file://$T/$1.git" "$T/machine" 2>/dev/null
  if [ "${2:-}" != nodeps ]; then
    mkdir -p "$T/machine/node_modules"; : > "$T/machine/node_modules/.keep"
  fi
  local d
  for d in packages/a apps/x packages/gone tools; do
    mkdir -p "$T/machine/$d/node_modules/x"; : > "$T/machine/$d/node_modules/x/index.js"
  done
  rm -f "$SEEN"
}
RUNJOB() { # RUNJOB — rebase ticket/bh-1 at $HEAD_SHA
  rm -f "$T/RESULT"
  ( # shellcheck source=/dev/null
    . "$LIB"
    rebase_job_run "$T/machine" "$SLUG" ticket/bh-1 "$HEAD_SHA" main "$T/RESULT" "$T/h" ) >/dev/null 2>&1
}
R1()   { head -1 "$T/RESULT" 2>/dev/null; }
GATE() { grep '^GATE:' "$T/RESULT" 2>/dev/null; }
SAW()  { sed -n "s|^$1=||p" "$SEEN" 2>/dev/null; }
LEFT() { find "$T/tmp" -maxdepth 1 -name 'rebase-log-*' 2>/dev/null | wc -l | tr -d ' '; }

# ============================================================================
# W1. the array form: the declared workspace's node_modules is linked
# ============================================================================
mkorigin arr "$PKG_ARR"
mkmachine arr
RUNJOB; RC=$?
[ "$RC" = 0 ] && ok || bad "W1: rc must be 0 (got $RC, RESULT '$(R1)')"
case "$(R1)" in REBASED\ *) ok ;; *) bad "W1: first line must be REBASED (got '$(R1)')" ;; esac
[ "$(GATE)" = "GATE: typecheck=0 unit=skipped" ] && ok || bad "W1: GATE line (got '$(GATE)')"
[ "$(SAW packages/a/node_modules)" = yes ] && ok || bad "W1: packages/a/node_modules must be linked"
[ "$(SAW node_modules)" = yes ] && ok || bad "W1: the root node_modules must still be linked"
[ "$(SAW packages/gone)" = no ] && ok || bad "W1: a dir the merged tree lacks must not be made"
[ "$(SAW tools/node_modules)" = no ] && ok || bad "W1: a dir that is not a workspace must not be linked"
[ "$(SAW apps/x/node_modules)" = no ] && ok || bad "W1: apps/x is not declared here, so it must not be linked"
git -C "$T/arr.seed" fetch -q origin
PUSHED=$(git -C "$T/arr.seed" ls-tree -r --name-only origin/ticket/bh-1)
[ -n "$PUSHED" ] && ok || bad "W1: could not read the pushed tree"
grep -q node_modules <<<"$PUSHED" && bad "W1: no node_modules link may be pushed" || ok
[ "$(LEFT)" = 0 ] && ok || bad "T: W1 left $(LEFT) rebase-log-* file(s) in TMPDIR"

# ============================================================================
# W2. the {"packages": [...]} form, with a plain path
# ============================================================================
mkorigin obj "$PKG_OBJ"
mkmachine obj
RUNJOB; RC=$?
[ "$RC" = 0 ] && ok || bad "W2: rc must be 0 (got $RC, RESULT '$(R1)')"
[ "$(SAW apps/x/node_modules)" = yes ] && ok || bad "W2: apps/x/node_modules must be linked"
[ "$(SAW packages/a/node_modules)" = no ] && ok || bad "W2: packages/a is not declared here, so it must not be linked"

# ============================================================================
# W3. no workspaces: the old behavior, only the root link
# ============================================================================
mkorigin none "$PKG_NONE"
mkmachine none
RUNJOB; RC=$?
[ "$RC" = 0 ] && ok || bad "W3: rc must be 0 (got $RC, RESULT '$(R1)')"
[ "$(GATE)" = "GATE: typecheck=0 unit=skipped" ] && ok || bad "W3: GATE line (got '$(GATE)')"
[ "$(SAW node_modules)" = yes ] && ok || bad "W3: the root node_modules must be linked"
[ "$(SAW packages/a/node_modules)" = no ] && ok || bad "W3: no workspaces, so nothing nested may be linked"
[ "$(SAW apps/x/node_modules)" = no ] && ok || bad "W3: no workspaces, so apps/x must not be linked"
[ "$(LEFT)" = 0 ] && ok || bad "T: W3 left $(LEFT) rebase-log-* file(s) in TMPDIR"

# ============================================================================
# W4. no root node_modules: gates skipped, nothing linked
# ============================================================================
mkorigin arr4 "$PKG_ARR"
mkmachine arr4 nodeps
RUNJOB; RC=$?
[ "$RC" = 0 ] && ok || bad "W4: rc must be 0 (got $RC, RESULT '$(R1)')"
[ "$(GATE)" = "GATE: typecheck=skipped unit=skipped" ] && ok || bad "W4: GATE line (got '$(GATE)')"
[ -e "$SEEN" ] && bad "W4: no node_modules, so typecheck must not run" || ok

echo "rebase-job-workspaces.bh-7953-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
