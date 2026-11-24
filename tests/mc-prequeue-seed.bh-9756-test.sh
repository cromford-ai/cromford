#!/bin/bash
# tests/mc-prequeue-seed.bh-9756-test.sh — BH-9756: Part 2 of
# tests/mc-prequeue-fast-lints.bh-8473-test.sh seeds its fixture repo through
# pq_seed_tree (tests/lib/mc-prequeue-seed.sh), not with a copy of the whole
# checkout. The whole checkout (177.6 MB, 16992 files on 2026-11-24) grows with
# every merge, and the real conductor's snapshot build ran out of its call
# budget on it (`could-not-run Terminated`), so the suite went red on main.
#   S1  the keep/drop rule on a fixture tree (17 rows, near misses included)
#   S2  the real tree: no .harness/specs, under half the bytes, and the static
#       lanes-registry suite (the catalog row the BH-8473 suite runs) is green
#       inside the reduced seed
#   S3  the BH-8473 suite calls pq_seed_tree and sets MC_WORKER_DEADLINE_S in
#       its conductor tick
# Real git, no network. Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-prequeue-seed.bh-9756-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/mc-prequeue-seed.sh" || { echo "FAIL: no tests/lib/mc-prequeue-seed.sh"; exit 1; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.invalid
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# ── S1: the keep/drop rule on a fixture tree ──
SRC="$T/src"; mkdir -p "$SRC"
git -C "$SRC" init -q
printf '*.ignored\n' > "$SRC/.gitignore"
TRACKED="bin/a.sh catalog/lanes.d/x.json fleet.conf cron/lanes/x.cron worker/jobs/src/lib/y.js
tests/lib/scratch.sh tests/lanes-registry-test.sh tests/other-test.sh tests/library/z.sh
tests/fixtures/big.bin docs/d.md docs-old/n.md console-ui/c.js .harness/specs/BH-1/plan.md .harness/other.txt"
for p in $TRACKED; do mkdir -p "$SRC/$(dirname "$p")"; echo "$p" > "$SRC/$p"; done
git -C "$SRC" add -A; git -C "$SRC" commit -qm seed
echo new > "$SRC/bin/new.sh"; echo ign > "$SRC/bin/x.ignored"
pq_seed_tree "$SRC" "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "S1 pq_seed_tree rc $rc, want 0"
while read -r p want; do
  if [ -e "$T/out/$p" ]; then got=present; else got=absent; fi
  [ "$got" = "$want" ] && ok || bad "S1 $p: $got, want $want"
done <<'EOF'
bin/a.sh present
bin/new.sh present
bin/x.ignored absent
catalog/lanes.d/x.json present
fleet.conf present
cron/lanes/x.cron present
worker/jobs/src/lib/y.js present
tests/lib/scratch.sh present
tests/lanes-registry-test.sh present
tests/other-test.sh absent
tests/library/z.sh absent
tests/fixtures/big.bin absent
docs/d.md absent
docs-old/n.md present
console-ui/c.js absent
.harness/specs/BH-1/plan.md absent
.harness/other.txt present
EOF
if [ -d "$T/out/docs" ] && [ -z "$(ls -A "$T/out/docs")" ]; then ok; else bad "S1 out/docs must be an empty directory"; fi

# ── S2: the real tree, and the fast lint the BH-8473 suite runs, inside it ──
pq_seed_tree "$DIR" "$T/real"; rc=$?
[ "$rc" = 0 ] && ok || bad "S2 pq_seed_tree on the real tree rc $rc, want 0"
[ ! -e "$T/real/.harness/specs" ] && ok || bad "S2 the real seed holds .harness/specs"
seed_b=$(du -sb "$T/real" | awk '{print $1}')
tree_b=$( cd "$DIR" && git ls-files -co --exclude-standard -z | xargs -0 stat -c %s 2>/dev/null | awk '{s+=$1} END {print s+0}' )
if [ "${tree_b:-0}" -gt 0 ] && [ "$((seed_b * 2))" -lt "$tree_b" ]; then ok
else bad "S2 the real seed is $seed_b bytes, want under half of the tree's $tree_b"; fi
( cd "$T/real" && HARNESS_TEST_SANDBOX=1 LANES_REGISTRY_SECTIONS=static bash tests/lanes-registry-test.sh ) > "$T/lr.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || { bad "S2 static lanes-registry in the reduced seed rc $rc, want 0"; tail -15 "$T/lr.out"; }

# ── S3: the BH-8473 suite uses the helper and long tick deadlines ──
SUITE="$DIR/tests/mc-prequeue-fast-lints.bh-8473-test.sh"
n=$(grep -v '^[[:space:]]*#' "$SUITE" | grep -c 'pq_seed_tree "\$DIR"')
[ "${n:-0}" -ge 1 ] && ok || bad "S3 the BH-8473 suite must seed Part 2 with pq_seed_tree (calls: ${n:-0})"
n=$(awk '/^ctick\(\) \{/ {p=1} p {print} p && /^\}$/ {exit}' "$SUITE" | grep -v '^[[:space:]]*#' | grep -c 'MC_WORKER_DEADLINE_S=')
[ "${n:-0}" -ge 1 ] && ok || bad "S3 ctick() must set MC_WORKER_DEADLINE_S (lines: ${n:-0})"

echo "mc-prequeue-seed: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
