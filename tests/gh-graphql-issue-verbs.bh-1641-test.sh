#!/bin/bash
# tests/gh-graphql-issue-verbs.bh-1641-test.sh — BH-1648 (BH-1641.0): every
# `gh issue view|list|comment|close|edit` in bin/ counts against the GraphQL
# ratchet in tests/gh-graphql-reads-lint.bh-1585-test.sh. `gh issue create`,
# `gh api`, `gh_rest`, `gh pr` write verbs, comments and quoted text do not.
# It runs the lint's OWN scanner (extracted from that file), so a change to
# the lint's CALL regex is what this watches.
# BH-1652: a zero-grant loop keeps every file the BH-1641 children converted at
# zero issue-verb lines and at a grant no higher than its `gh pr` count.
#
# Run from anywhere: tests/gh-graphql-issue-verbs.bh-1641-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

awk '/cat > "\$T\/scan.py" <<'"'"'PY'"'"'/{f=1;next} /^PY$/{f=0} f' \
  "$DIR/tests/gh-graphql-reads-lint.bh-1585-test.sh" > "$T/scan.py"
[ -s "$T/scan.py" ] && ok || { bad "could not extract scan.py from the 1585 lint"; exit 1; }

check() { # check <label> <want-rc> <line>; SCANNER=<py> overrides the scanner
  rm -rf "$T/fx"; mkdir -p "$T/fx/bin"; : > "$T/fx/allow.tsv"
  printf '#!/bin/bash\n%s\n' "$3" > "$T/fx/bin/x.sh"
  local rc; python3 "${SCANNER:-$T/scan.py}" "$T/fx" "$T/fx/allow.tsv" > "$T/scan.out" 2>&1; rc=$?
  if [ "$rc" != "$2" ]; then bad "$1: rc=$rc want $2: $(cat "$T/scan.out")"; return; fi
  if [ "$2" = 1 ] && ! grep -qF 'bin/x.sh:2' "$T/scan.out"; then bad "$1: no bin/x.sh:2 in $(cat "$T/scan.out")"; return; fi
  ok
}

check 'P1 gh issue view'                    1 'gh issue view 7'
check 'P2 $(timeout gh issue view)'         1 'S=$(timeout 20 gh issue view 7 -R o/r --json state)'
check 'P3 gh issue comment'                 1 'gh issue comment 7 --body-file f'
check 'P4 if gh issue close'                1 'if gh issue close 7; then :; fi'
check 'P5 GH_TOKEN=x gh issue edit'         1 'GH_TOKEN=x gh issue edit 7 --remove-label ai-build'
check 'P6 gh issue list'                    1 'gh issue list'

check 'N1 gh issue create is out of scope'  0 'gh issue create -R o/r --title t --body b'
check 'N2 gh api REST path'                 0 'gh api repos/o/r/issues/7'
check 'N3 gh_rest GET'                      0 'gh_rest GET repos/o/r/issues/7'
check 'N4 gh_rest POST graphql'             0 'gh_rest POST graphql -f "query=$Q"'
check 'N5 printf format text'               0 "printf 'gh issue edit %s\\n' 7"
check 'N6 a comment'                        0 '# gh issue view 7'
# Documented expectation, not a skip: the scanner splits on `(` even inside
# quotes, so this text line IS counted. The scanner is out of BH-1648's scope;
# a real line of this shape takes a grant or a gh-guard-allow.
check 'N7 quoted "(gh issue view" text is a known hit' 1 'echo "(gh issue view failed)"'
check 'N8 gh pr merge is a write'           0 'gh pr merge 5'

# --- BH-1652: converted files carry no issue grant --------------------------
# An issue-only scanner: the lint's own scanner with only its CALL line swapped,
# so peel/split/strip-comment follow any later change to the lint.
sed 's/^CALL = re\.compile(.*$/CALL = re.compile(r"^gh\\s+issue\\s+(?:view|list|comment|close|edit)(?:\\s|$)")/' \
  "$T/scan.py" > "$T/scan-issue.py"
CALL_I=$(grep '^CALL = ' "$T/scan-issue.py")
if cmp -s "$T/scan.py" "$T/scan-issue.py" || [ -z "$CALL_I" ] \
   || grep -qE 'pr\\s|graphql' <<<"$CALL_I" \
   || ! grep -qF 'issue' <<<"$CALL_I"; then
  bad "Z0 issue-only CALL rewrite did not take: ${CALL_I:-<none>}"; exit 1
fi
ok
SCANNER="$T/scan-issue.py" check 'Z0 issue-only scanner hits gh issue view' 1 'gh issue view 7'
SCANNER="$T/scan-issue.py" check 'Z0 issue-only scanner misses gh pr view'  0 'gh pr view 7'

# Every bin/ file named in the ## Files of children 2-4 (#1649, #1650, #1651).
CONVERTED="bin/run-build.sh bin/lib/rb/gates.sh bin/lib/rb/plan.sh bin/lib/rb/execute.sh
bin/lib/fc-issues.sh bin/decompose-parent-close.sh bin/unblocked-children.sh
bin/lib/revdep-lib.sh bin/wake-loop.sh bin/review-rescue.sh bin/planned-files-cheap.sh
bin/hotfix-after-deploy.sh bin/load-project.sh bin/up10-lane.sh bin/bootstrap-machine.sh"
for f in $CONVERTED; do
  [ -f "$DIR/$f" ] && ok || bad "Z0 converted file $f is missing (renamed? update CONVERTED)"
done

counts() { # counts <scanner> -> "<path> <n>" per file over an empty allowlist
  python3 "$1" "$DIR" /dev/null 2>/dev/null | sed -n 's/^OVER \([^:]*\): \([0-9]*\) .*/\1 \2/p' || true
}
zero_grant() { # zero_grant <allowlist> -> one Z1/Z2 line per violation
  local iss full f i a g
  iss=$(counts "$T/scan-issue.py"); full=$(counts "$T/scan.py")
  for f in $CONVERTED; do
    i=$(printf '%s\n' "$iss"  | awk -v f="$f" '$1==f{print $2}'); i=${i:-0}
    a=$(printf '%s\n' "$full" | awk -v f="$f" '$1==f{print $2}'); a=${a:-0}
    # the highest row for f: a duplicate row can never hide a raise
    g=$(sed 's/#.*//' "$1" | awk -v f="$f" '$2==f && $1+0>m{m=$1+0} END{print m+0}')
    [ "$i" -eq 0 ] || echo "Z1 $f has $i gh issue line(s)"
    [ "$g" -le $((a - i)) ] || echo "Z2 $f granted $g, gh pr count $((a - i))"
  done
}

Z=$(zero_grant "$DIR/tests/gh-graphql-reads-allowlist.tsv")
if [ -z "$Z" ]; then ok; else while IFS= read -r l; do bad "$l"; done <<<"$Z"; fi

# In-suite mutation: a raise on a converted file must read as an undo.
cp "$DIR/tests/gh-graphql-reads-allowlist.tsv" "$T/mut.tsv"
sed -i 's|^[0-9]* bin/review-rescue\.sh$|3 bin/review-rescue.sh|' "$T/mut.tsv"
echo '1 bin/lib/fc-issues.sh' >> "$T/mut.tsv"
Z=$(zero_grant "$T/mut.tsv")
grep -q '^Z2 bin/review-rescue.sh granted 3,' <<<"$Z" && ok \
  || bad "Z3 mutation: raising bin/review-rescue.sh to 3 did not fire Z2: ${Z:-<none>}"
grep -q '^Z2 bin/lib/fc-issues.sh granted 1,' <<<"$Z" && ok \
  || bad "Z3 mutation: granting bin/lib/fc-issues.sh 1 did not fire Z2: ${Z:-<none>}"

echo "gh-graphql-issue-verbs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
