#!/bin/bash
# tests/rb-full-ci-label.bh-8049-test.sh — BH-8049: FULL_CI_LABEL=off turns the
# full-CI label off, the same as an empty value.
#
# WHY. A settings row cannot hold an empty value (setting_set and the worker
# PUT refuse it), so before this change a project row could not turn the label
# off: the row `off` made fcl_apply run the classifier and POST a label named
# `off` to every PR. The project-6-os row must move from `ci-impact` to `off`.
#
#   O1 row `off`          -> no classifier run, no POST, no log line, rc 0
#   O2 row `OFF`          -> same
#   O3 row ` off `        -> same
#   N1 row `offline`      -> classifier runs, one POST labels[]=offline
#   N2 row `full-ci-off`  -> classifier runs, one POST
#   N3 row `full-ci`      -> one POST labels[]=full-ci (control: the fixture catches a POST)
#   K1 the catalog note for FULL_CI_LABEL names `off`
#   M1 mutation: the scratch lib without its `off` line POSTs for row `off`
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/rb-full-ci-label.bh-8049-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
[ -f "$DIR/bin/lib/rb-full-ci-label.sh" ] || bad "setup: bin/lib/rb-full-ci-label.sh is missing"   # impact: bin/lib/rb-full-ci-label.sh catalog/lanes.d/_lib.rb-full-ci-label.json

export HARNESS="$T/h"
mkdir -p "$T/h/state" "$T/fakebin"
scratch_install_closure bin/lib/rb-full-ci-label.sh "$T/h" >/dev/null || bad "setup: the lib's closure did not install"
mkdir -p "$T/reg/catalog" && cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/" || exit 1
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 || bad "setup: the lane registry does not render"
export LANE_REGISTRY="$T/reg/catalog/lanes.json" JOBS_URL=""
NOW=$(date -u +%s)
# The row value, served through the scratch settings cache (the box's read path).
row() { jq -nc --argjson t "$NOW" --arg v "$1" \
  '{fetched_at:$t,values:{"lib.rb-full-ci-label.project-6-os.full_ci_label":$v}}' > "$T/h/state/settings-cache.json"; }

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com; git config --global user.name t
git config --global init.defaultBranch main; git config --global commit.gpgsign false
WT="$T/wt"; git init -q "$WT"
echo a > "$WT/a.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm base
git -C "$WT" update-ref refs/remotes/origin/main HEAD
echo b > "$WT/b.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm change
mkdir -p "$WT/scripts/ci"; : > "$WT/scripts/ci/lane.mjs"

# The stub node marks that the classifier ran and answers lane full.
cat > "$T/fakebin/node" <<EOF
#!/bin/bash
touch "$T/node.ran"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --github-output ] && out="\$2"; shift; done
[ -n "\$out" ] && echo lane=full >> "\$out"
exit 0
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X POST repos/"*"/labels"*) printf '%s\n' "\$*" >> "$T/posts.txt"; echo '[]' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/node" "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
LIB="$T/h/bin/lib/rb-full-ci-label.sh"
[ -r "$LIB" ] && . "$LIB"
URL=https://github.com/example-org/project-6/pull/8049
LOG="$T/pipeline.log"
run() { : > "$T/posts.txt"; : > "$LOG"; rm -f "$T/node.ran"; row "$1"
  local rc=0; fcl_apply project-6-os "$URL" "$WT" main "$LOG" || rc=$?; echo "$rc" > "$T/rc"; }
nothing() { # <case> — no classifier, no POST, no log line, rc 0
  [ ! -e "$T/node.ran" ] && [ ! -s "$T/posts.txt" ] && [ ! -s "$LOG" ] && [ "$(cat "$T/rc")" = 0 ] \
    && ok || bad "$1: off means no classifier run, no POST, no log line (ran: $([ -e "$T/node.ran" ] && echo yes || echo no); posts: $(cat "$T/posts.txt"); log: $(cat "$LOG"); rc $(cat "$T/rc"))"
}
labels() { # <case> <label> — classifier ran, exactly one POST of that label
  [ -e "$T/node.ran" ] && [ "$(wc -l < "$T/posts.txt")" = 1 ] \
    && grep -qF -- "-f labels[]=$2" "$T/posts.txt" \
    && ok || bad "$1: row '$2' is a label: classifier runs, one POST labels[]=$2 (ran: $([ -e "$T/node.ran" ] && echo yes || echo no); posts: $(cat "$T/posts.txt"))"
}

run off;   nothing O1
run OFF;   nothing O2
run ' off '; nothing O3
run offline;     labels N1 offline
run full-ci-off; labels N2 full-ci-off
run full-ci;     labels N3 full-ci

# K1 — the knob note documents off.
jq -r '.libs[0].knobs[] | select(.env=="FULL_CI_LABEL") | .note' "$DIR/catalog/lanes.d/_lib.rb-full-ci-label.json" \
  | grep -qw off && ok || bad "K1: the FULL_CI_LABEL note in catalog/lanes.d/_lib.rb-full-ci-label.json names 'off'"

# M1 — mutation check: drop the off line from the scratch copy, and row off labels.
if grep -q 'fcl-off (BH-8049)' "$LIB"; then
  sed -i '/fcl-off (BH-8049)/d' "$LIB"
  . "$LIB"
  run off
  [ -s "$T/posts.txt" ] && ok || bad "M1: without its off line the lib must POST for row off (the O cases would not catch a regression)"
else
  bad "M1: the lib has no 'fcl-off (BH-8049)' line to mutate"
fi

echo "rb-full-ci-label.bh-8049: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
