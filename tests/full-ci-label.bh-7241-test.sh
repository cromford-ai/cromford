#!/bin/bash
# tests/full-ci-label.bh-7241-test.sh — BH-7241: the builder adds the `full-ci`
# label when it opens a PR that needs the full CI lane.
#
# WHY. project-6's CI reads the `full-ci` label to pick its full lane. No code
# in the harness added it, so each harness PR waited about 11 min for a person
# to add it by hand (measured 2026-10-17).
#
#   L1 no FULL_CI_LABEL row                 -> no POST, no log line
#   L2 lane full                            -> one POST labels[]=full-ci, `labelled`
#   L3 lane frontend                        -> no POST, a line naming frontend
#   L4 the lane script is absent            -> one POST (the full lane is the safe side)
#   L5 the lane script exits 1              -> one POST
#   L6 the POST fails                       -> `could NOT label`, rc 0
#   L7 the lane script runs past its timeout -> one POST
#   L8 the bin/lib/rb/pr.sh block calls fcl_apply only when PR_URL is set
#
# fcl_apply runs against a real git worktree with a stub `node` (it writes the
# lane the case names to --github-output) and a stub `gh` that records POSTs.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/full-ci-label.bh-7241-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
[ -f "$DIR/bin/lib/rb-full-ci-label.sh" ] || bad "setup: bin/lib/rb-full-ci-label.sh is missing"   # impact: bin/lib/rb-full-ci-label.sh bin/lib/rb/pr.sh

export HARNESS="$T/h"
mkdir -p "$T/h/state" "$T/fakebin"
scratch_install_closure bin/lib/rb-full-ci-label.sh "$T/h" >/dev/null || bad "setup: the lib's closure did not install"
# The registry, rendered into the scratch tree, so FULL_CI_LABEL is read
# through lib_env_apply exactly as on a box.
mkdir -p "$T/reg/catalog" && cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/" || exit 1
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 || bad "setup: the lane registry does not render"
export LANE_REGISTRY="$T/reg/catalog/lanes.json" JOBS_URL=""
NOW=$(date -u +%s)
rows() { printf '{"fetched_at":%s,"values":{%s}}' "$NOW" "${1:-}" > "$T/h/state/settings-cache.json"; }

# A worktree with a base and one commit on top.
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com; git config --global user.name t
git config --global init.defaultBranch main; git config --global commit.gpgsign false
WT="$T/wt"; git init -q "$WT"
echo a > "$WT/a.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm base
git -C "$WT" update-ref refs/remotes/origin/main HEAD
echo b > "$WT/b.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm change
BASESHA=$(git -C "$WT" rev-parse origin/main)
mkdir -p "$WT/scripts/ci"; : > "$WT/scripts/ci/lane.mjs"

# The stub node: $T/lane is the lane it prints; $T/node.rc its exit code;
# $T/node.sleep seconds it sleeps first. Its argv goes to $T/node.argv.
cat > "$T/fakebin/node" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$T/node.argv"
[ -s "$T/node.sleep" ] && sleep "\$(cat "$T/node.sleep")"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --github-output ] && out="\$2"; shift; done
[ -s "$T/lane" ] && [ -n "\$out" ] && printf 'lane=%s\n' "\$(cat "$T/lane")" >> "\$out"
exit "\$(cat "$T/node.rc" 2>/dev/null || echo 0)"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X POST repos/"*"/labels"*) printf '%s\n' "\$*" >> "$T/posts.txt"; [ -e "$T/post.fail" ] && exit 1; echo '[]' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/node" "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
[ -r "$T/h/bin/lib/rb-full-ci-label.sh" ] && . "$T/h/bin/lib/rb-full-ci-label.sh"
URL=https://github.com/example-org/project-6/pull/1234
LOG="$T/pipeline.log"
reset() { : > "$T/posts.txt"; : > "$LOG"; rm -f "$T/node.rc" "$T/node.sleep" "$T/post.fail" "$T/node.argv"; echo "${1:-}" > "$T/lane"; }
apply() { local rc=0; fcl_apply project-6-os "$URL" "$WT" main "$LOG" || rc=$?; echo "$rc" > "$T/rc"; }
LABELROW='"lib.rb-full-ci-label.project-6-os.full_ci_label":"full-ci"'

# L1 — no row: nothing at all.
rows ''; reset full; apply
[ ! -s "$T/posts.txt" ] && [ ! -s "$LOG" ] && [ "$(cat "$T/rc")" = 0 ] \
  && ok || bad "L1: no FULL_CI_LABEL row means no POST and no log line (posts: $(cat "$T/posts.txt"); log: $(cat "$LOG"))"

# L2 — lane full: one POST, a `labelled` line; the script gets the merge base.
rows "$LABELROW"; reset full; apply
[ "$(grep -c 'POST repos/example-org/project-6/issues/1234/labels -f labels\[\]=full-ci' "$T/posts.txt")" = 1 ] \
  && ok || bad "L2: lane full adds the label once (posts: $(cat "$T/posts.txt"))"
grep -q "labelled $URL 'full-ci'" "$LOG" && grep -q 'lane full' "$LOG" && ok || bad "L2: the line says labelled and why (log: $(cat "$LOG"))"
grep -q -- "--base $BASESHA --head HEAD --github-output" "$T/node.argv" 2>/dev/null \
  && ok || bad "L2: the lane script runs on the merge base with origin/main (argv: $(cat "$T/node.argv" 2>/dev/null))"
# Another project with no row stays off.
reset full; fcl_apply other-os "$URL" "$WT" main "$LOG"
[ ! -s "$T/posts.txt" ] && ok || bad "L2: a project with no row adds nothing"

# L3 — lane frontend: no label, and the line says so.
reset frontend; apply
[ ! -s "$T/posts.txt" ] && grep -q 'lane frontend' "$LOG" && ok || bad "L3: lane frontend adds no label and logs it (posts: $(cat "$T/posts.txt"); log: $(cat "$LOG"))"

# L4 — the script is absent: the safe side.
mv "$WT/scripts/ci/lane.mjs" "$T/lane.mjs.away"; reset full; apply
mv "$T/lane.mjs.away" "$WT/scripts/ci/lane.mjs"
[ "$(wc -l < "$T/posts.txt")" = 1 ] && grep -q 'lane script missing: full lane is the safe side' "$LOG" \
  && ok || bad "L4: a missing lane script labels (posts: $(cat "$T/posts.txt"); log: $(cat "$LOG"))"

# L5 — the script fails: the safe side.
reset frontend; echo 1 > "$T/node.rc"; apply
[ "$(wc -l < "$T/posts.txt")" = 1 ] && grep -q 'lane script failed' "$LOG" && ok || bad "L5: a failed lane script labels (log: $(cat "$LOG"))"

# L6 — the POST fails: one line, rc 0.
reset full; touch "$T/post.fail"; apply
grep -q "could NOT label $URL 'full-ci'" "$LOG" && [ "$(cat "$T/rc")" = 0 ] \
  && ok || bad "L6: a failed POST is one line and never fails the build (rc $(cat "$T/rc"); log: $(cat "$LOG"))"
grep -q 'labelled' "$LOG" && bad "L6: a failed POST never says labelled" || ok

# L7 — the script runs past the timeout: the safe side.
reset frontend; echo 3 > "$T/node.sleep"
rc=0; FULL_CI_LANE_TIMEOUT_S=1 fcl_apply project-6-os "$URL" "$WT" main "$LOG" || rc=$?
[ "$(wc -l < "$T/posts.txt")" = 1 ] && [ "$rc" = 0 ] && ok || bad "L7: a lane script past its timeout labels (log: $(cat "$LOG"))"

# L8 — the pr.sh block: fcl_apply runs only when PR_URL is set.
BLK=$(sed -n '/# >>> full-ci label (BH-7241)/,/# <<< full-ci label/p' "$DIR/bin/lib/rb/pr.sh")
[ -n "$BLK" ] || bad "L8: the '# >>> full-ci label (BH-7241)' block is missing from bin/lib/rb/pr.sh"
fcl_apply() { echo "called $*" >> "$T/fcl.calls"; }
: > "$T/fcl.calls"
PROJECT=project-6-os; BUILD="$T"; BASE=main; PR_URL=""
( cd "$WT" && eval "$BLK" )
[ ! -s "$T/fcl.calls" ] && ok || bad "L8: no PR_URL, no call (got: $(cat "$T/fcl.calls"))"
PR_URL="$URL"
( cd "$WT" && eval "$BLK" )
grep -q "called project-6-os $URL $WT main $T/pipeline.log" "$T/fcl.calls" \
  && ok || bad "L8: with PR_URL the block calls fcl_apply with the project, url, worktree, base and log (got: $(cat "$T/fcl.calls"))"

echo "full-ci-label.bh-7241: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
