#!/bin/bash
# tests/publish-cromford-brand.bh-4901-test.sh — the public tree is branded
# Cromford and its entry docs read as a project, not a copy (BH-4901).
#
# Builds the tree exactly as bin/publish-share.sh does before its guards:
# bin/share/sanitize.py over this checkout's files. The branding rewrites are a
# table in bin/share/mapping.py (BRANDING), applied as fail-loud patches, and
# sanitize refuses a tree whose entry docs carry PUBLIC_DOC_FORBIDDEN wording.
#
#   B1  sanitize exits 0: every BRANDING and PATCHES anchor exists here
#   B2  README's first heading is "# Cromford" and it links https://cromford.dev
#   B3  docs/MIRROR-NOTES.md is gone, docs/ABOUT.md is there, nothing links the old page
#   B4  CONTRIBUTING.md welcomes issues and PRs, states Apache inbound = outbound, links cromford.dev
#   B5  no PUBLIC_DOC_FILES file carries a PUBLIC_DOC_FORBIDDEN phrase; NOTICE names Cromford
#   B6  internal paths are unchanged; the harness's project id is cromford, once
#   B7  fail-loud: a moved anchor, or forbidden wording in an entry doc, stops sanitize
#   B8  the console title says Cromford; OPERATOR-SETUP calls nothing a private repository
#
# Run from anywhere: tests/publish-cromford-brand.bh-4901-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/share-mirror.sh" || exit 1
unset HARNESS_DEPLOYMENT_FILE
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if [ ! -f "$DIR/bin/publish-share.sh" ] || [ ! -d "$DIR/bin/share" ]; then
  echo "SKIP publish-cromford-brand: no bin/publish-share.sh or bin/share/ in this copy"
  exit 0
fi
SAN="$DIR/bin/share/sanitize.py"

# The checkout's files as git sees them (tracked plus untracked-not-ignored),
# so an uncommitted edit is tested the way its commit will be. A clean checkout
# IS its HEAD, so it reads the build tests/lib/share-mirror.sh shares with the
# other share suites; a dirty one gets a private build (BH-5543).
share_mirror_get "$DIR" --worktree || { bad "fixture: cannot copy the checkout"; }
SRC="$SM_SRC"

M="$SM_MIRROR"
# B1
rc=${SM_SANITIZE_RC:-3}
if [ "$rc" = 0 ]; then ok
else bad "B1 sanitize exited $rc on this checkout:"; tail -12 "${SM_SANITIZE_OUT:-/dev/null}"
  echo "publish-cromford-brand.bh-4901-test: $PASS pass, $FAIL fail"; exit 1; fi

# B2
[ "$(grep -m1 '^# ' "$M/README.md")" = "# Cromford" ] && ok \
  || bad "B2 README's first heading is '$(grep -m1 '^# ' "$M/README.md")', not '# Cromford'"
grep -qF 'https://cromford.dev' "$M/README.md" && ok || bad "B2 README does not link https://cromford.dev"

# B3
[ ! -e "$M/docs/MIRROR-NOTES.md" ] && ok || bad "B3 docs/MIRROR-NOTES.md is still in the public tree"
[ -s "$M/docs/ABOUT.md" ] && ok || bad "B3 docs/ABOUT.md is missing"
if grep -n 'MIRROR-NOTES' "$M/README.md" "$M/CONTRIBUTING.md" "$M/NOTICE" "$M/docs/ABOUT.md" 2>/dev/null; then
  bad "B3 a public entry doc still links MIRROR-NOTES (above)"
else ok; fi
grep -qF '(docs/ABOUT.md)' "$M/README.md" && ok || bad "B3 README does not link docs/ABOUT.md"

# B4
C="$M/CONTRIBUTING.md"
grep -q 'Apache' "$C" && grep -qi 'inbound' "$C" && grep -qF 'https://cromford.dev' "$C" && grep -qi 'welcome' "$C" && ok \
  || bad "B4 CONTRIBUTING.md must welcome PRs, state Apache inbound = outbound and link https://cromford.dev"
if grep -niwE 'mirror|port|private|squash' "$C"; then bad "B4 CONTRIBUTING.md has wording it must not (above)"; else ok; fi

# B5
python3 -I - "$DIR/bin/share" "$M" > "$T/b5.out" 2>&1 <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
from mapping import PUBLIC_DOC_FILES, PUBLIC_DOC_FORBIDDEN
root = sys.argv[2]
hits = []
seen = 0
for rel in PUBLIC_DOC_FILES:
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        continue
    seen += 1
    low = open(p, encoding="utf-8").read().lower()
    hits += ["%s: %s" % (rel, w) for w in PUBLIC_DOC_FORBIDDEN if w.lower() in low]
assert seen >= 6, "only %d of the public doc files exist" % seen
assert not hits, "; ".join(hits)
print("ok")
PY
[ $? = 0 ] && ok || bad "B5 forbidden wording in a public doc: $(cat "$T/b5.out" | tail -2)"
grep -q 'Cromford' "$M/NOTICE" && ! grep -qi 'private' "$M/NOTICE" && ok \
  || bad "B5 NOTICE must name Cromford and must not call anything private"

# B6
[ ! -e "$M/bin/publish-share.sh" ] && [ -f "$M/bin/run-build.sh" ] && ok \
  || bad "B6 internal paths moved (publish-share.sh shipped, or run-build.sh missing)"
# The harness's own project id is renamed with the repo (BH-6494: cromford
# becomes cromford in the public tree), and the website row that upstream
# already calls cromford becomes cromford-web, so the id stays unique.
if grep -q '^cromford' "$SRC/fleet.conf" 2>/dev/null; then
  [ "$(grep -c '^cromford ' "$M/fleet.conf")" = 1 ] && ! grep -q '^cromford' "$M/fleet.conf" && ok \
    || bad "B6 fleet.conf must carry the cromford project id once and no cromford row: $(grep -E '^(cromford|cromford)' "$M/fleet.conf" | tr '\n' '|')"
fi
grep -q 'bin/run-tests-in-docker.sh' "$M/README.md" && ok || bad "B6 README lost an internal script path"

# B7 fail-loud
B7S="$T/b7src"; share_mirror_copy "$B7S" src
sed -i '1s/.*/# something else/' "$B7S/README.md"
python3 "$SAN" "$B7S" "$T/b7out" > "$T/b7.out" 2>&1
rc=$?
[ "$rc" != 0 ] && grep -q 'anchor not found' "$T/b7.out" && ok \
  || bad "B7 a moved README anchor must stop sanitize (rc=$rc): $(tail -3 "$T/b7.out" | tr '\n' ' ')"
scratch_rm "$B7S"; share_mirror_copy "$B7S" src
echo 'This is a private repository.' >> "$B7S/docs/SELF-HOST.md"
python3 "$SAN" "$B7S" "$T/b7out" > "$T/b7.out" 2>&1
rc=$?
[ "$rc" != 0 ] && grep -q 'docs/SELF-HOST.md' "$T/b7.out" && ok \
  || bad "B7 forbidden wording in docs/SELF-HOST.md must stop sanitize and name the file (rc=$rc): $(tail -3 "$T/b7.out" | tr '\n' ' ')"

# B8
grep -q '<title>[^<]*Cromford' "$M/console-ui/index.html" && ok || bad "B8 console-ui/index.html <title> does not say Cromford"
grep -qi 'private repository' "$M/docs/OPERATOR-SETUP.md" && bad "B8 docs/OPERATOR-SETUP.md still says 'private repository'" || ok

echo "publish-cromford-brand.bh-4901-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
