#!/bin/bash
# tests/schema-untracked-u4.bh-6948-test.sh — check U4 of
# tests/schema-untracked.bh-6005-4-test.sh runs on every box, and a skip is
# never a pass (BH-6948).
#
# WHY. U4 ran only when worker/jobs/node_modules existed. CI shards have none,
# so U4 printed "NOTE: U4 skipped" and the suite was green, while on the Mac
# gate (node_modules present) U4 was red: its scratch copy never composed
# catalog/context-budgets.json (git-ignored since BH-6487), and the worker
# imports it.
#
#   K1 a scratch repo with no worker/jobs/node_modules: the 6005-4 suite runs U4
#      (no "U4 skipped", no "FAIL: U4"), exits 0, and the checkout is unchanged
#   K2 a node that reports "# skipped 1" with rc 0: a "FAIL: U4" line that
#      names "skipped", rc 1
#   K3 a context-budgets-build.sh that composes nothing: a "FAIL: U4" line that
#      carries context-budgets.json, rc 1
#   K4 the U4 block composes context-budgets.json with --repo "$U4", does not
#      test worker/jobs/node_modules, and has no "NOTE: U4 skipped" left
# Run from anywhere: tests/schema-untracked-u4.bh-6948-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUITE=tests/schema-untracked.bh-6005-4-test.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"

NODE=$(command -v node) || { echo "FAIL: K* need node on PATH"; echo "schema-untracked-u4.bh-6948-test: 0 pass, 1 fail"; exit 1; }

# mkrepo <dir> — a git repo of HEAD's paths the 6005-4 suite reads, with the
# checkout's own copy of the suite on top (the code under test) and no
# worker/jobs/node_modules.
mkrepo() {
  mkdir -p "$1"
  git -C "$DIR" archive HEAD bin catalog worker/jobs agent-core config tests/lib \
    tests/schema-additive.bh-1000-test.sh .gitignore | tar -x -C "$1"
  cp "$DIR/$SUITE" "$1/$SUITE"
  scratch_rm "$1/worker/jobs/node_modules"
  git -C "$1" init -q && git -C "$1" add -A && git -C "$1" commit -qm base
}
# suite <repo> [PATH prefix] — run the 6005-4 suite from <repo>; output in $T/s.out.
suite() {
  ( cd "$1" && PATH="${2:+$2:}$PATH" bash "$SUITE" ) >"$T/s.out" 2>&1; RC=$?
}

# ── K1 U4 runs with no node_modules ──────────────────────────────────────────
ST0=$(git -C "$DIR" status --porcelain)
mkrepo "$T/k1"
suite "$T/k1"
! grep -q 'U4 skipped' "$T/s.out" && ok || bad "K1 U4 must not be skipped with no node_modules: $(grep 'U4' "$T/s.out")"
! grep -q '^FAIL: U4' "$T/s.out" && ok || bad "K1 U4 must pass with no node_modules: $(grep '^FAIL: U4' "$T/s.out")"
[ "$RC" = 0 ] && ok || bad "K1 the suite must exit 0 (rc=$RC: $(tail -3 "$T/s.out"))"
[ ! -e "$T/k1/worker/jobs/schema.sql" ] && ok || bad "K1 the suite must leave no worker/jobs/schema.sql in the repo it ran from"
[ "$(git -C "$DIR" status --porcelain)" = "$ST0" ] && ok || bad "K1 the checkout's git status must not change"

# ── K2 a node-level skip is a FAIL ───────────────────────────────────────────
mkdir -p "$T/shim"
cat > "$T/shim/node" <<EOF
#!/bin/bash
if [ "\${1:-}" = --test ]; then
  printf '%s\n' 'ok 1 - a' 'ok 2 - b' 'ok 3 - c # SKIP' '1..3' '# tests 3' '# pass 2' '# fail 0' '# skipped 1'
  exit 0
fi
exec "$NODE" "\$@"
EOF
chmod +x "$T/shim/node"
suite "$T/k1" "$T/shim"
grep '^FAIL: U4' "$T/s.out" | grep -q 'skipped' && ok || bad "K2 a node '# skipped 1' must give a FAIL: U4 line naming skipped: $(grep 'U4' "$T/s.out")"
[ "$RC" = 1 ] && ok || bad "K2 the suite must exit 1 on a node-level skip (rc=$RC)"

# ── K3 a missing context-budgets compose is caught ───────────────────────────
mkrepo "$T/k3"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$T/k3/bin/context-budgets-build.sh"
git -C "$T/k3" commit -qam 'stub compose'
suite "$T/k3"
grep '^FAIL: U4' "$T/s.out" | grep -q 'context-budgets.json' && ok || bad "K3 no composed context-budgets.json must give a FAIL: U4 line naming it: $(grep 'U4' "$T/s.out")"
[ "$RC" = 1 ] && ok || bad "K3 the suite must exit 1 when context-budgets.json is not composed (rc=$RC)"

# ── K4 the U4 block's shape ──────────────────────────────────────────────────
awk '/^# ── U4 /{p=1} /^# ── U5 /{p=0} p' "$DIR/$SUITE" > "$T/u4.blk"
[ -s "$T/u4.blk" ] && ok || bad "K4 the U4 block was not found in $SUITE"
grep -q 'context-budgets-build.sh" --compose --repo "\$U4"' "$T/u4.blk" && ok || bad "K4 U4 must run context-budgets-build.sh --compose --repo \"\$U4\""
[ -s "$T/u4.blk" ] && ! grep -q 'worker/jobs/node_modules' "$T/u4.blk" && ok || bad "K4 U4 must not test worker/jobs/node_modules"
[ -s "$T/u4.blk" ] && ! grep -q 'echo "NOTE: U4 skipped' "$T/u4.blk" && ok || bad "K4 U4 must have no NOTE: U4 skipped path"

echo "schema-untracked-u4.bh-6948-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
