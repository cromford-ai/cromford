#!/bin/bash
# tests/test-impact-inputs.bh-5366-test.sh — `bin/test-impact.sh inputs` (BH-5366).
#
# The suite fingerprint (bin/lib/suite-fingerprint.sh) hashes whatever this
# command says a suite reads, so a row it drops is a reuse that should not have
# happened. Every case drives the real CLI over a scratch git checkout:
#
#   I1  the self row, the sourced bin/lib/a.sh row, and the `*` row of an
#       always-suite
#   I2  a named edge: a suite that spells foo_helper gets bin/b.sh, the script
#       that defines it; a suite that names it only in a comment does not
#   I3  @infra rows: tests/lib/, bin/suite-reuse.sh and bin/lib/suite-fingerprint.sh
#   I4  sorted and unique; a root with no suites is rc 2 with stderr, never a
#       short list; a named-function scan that dies is rc 2 too, never a
#       list with every named edge missing
#   I5  the real tree: rc 0, every suite has its self row, the two new bin
#       files are infra
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
NOW=2026-10-08T00:00:00Z

TI="$DIR/bin/test-impact.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
has() { grep -qxF "$(printf '%s\t%s' "$1" "$2")" "$OUT"; }

R="$T/repo"
mkdir -p "$R/tests/lib" "$R/bin/lib" "$R/catalog"
printf '#!/bin/bash\nlib_a() { :; }\n' > "$R/bin/lib/a.sh"
printf '#!/bin/bash\nfoo_helper() { echo hi; }\n' > "$R/bin/b.sh"
printf '#!/bin/bash\n: suite-reuse\n' > "$R/bin/suite-reuse.sh"
printf '#!/bin/bash\n: fingerprint\n' > "$R/bin/lib/suite-fingerprint.sh"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
cat > "$R/tests/a.sh" <<'EOF'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/bin/lib/a.sh"
out=$(foo_helper)
EOF
cat > "$R/tests/b.sh" <<'EOF'
#!/bin/bash
# foo_helper is mentioned here only in a comment
echo b
EOF
printf '#!/bin/bash\necho c\n' > "$R/tests/c.sh"
printf 'tests/c.sh\n' > "$R/catalog/test-impact-always.txt"
git -C "$R" init -q && git -C "$R" add -A \
  && GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@t -c user.name=t commit -qm init \
  || { echo "cannot build the scratch checkout"; exit 1; }

OUT="$T/inputs.tsv"
"$TI" --root "$R" inputs > "$OUT" 2> "$T/err"; rc=$?
[ "$rc" = 0 ] && ok "I0 rc 0" || bad "I0 rc=$rc: $(cat "$T/err")"

has tests/a.sh tests/a.sh && ok "I1 self row" || bad "I1 no self row"
has tests/a.sh bin/lib/a.sh && ok "I1 sourced lib row" || bad "I1 no bin/lib/a.sh row"
has tests/c.sh '*' && ok "I1 always row" || bad "I1 no * row for the always-suite"
has tests/a.sh bin/b.sh && ok "I2 named edge to the defining script" || bad "I2 no tests/a.sh -> bin/b.sh row"
has tests/b.sh bin/b.sh && bad "I2 a comment-only mention made a named row" || ok "I2 comment mention is not an input"
has @infra tests/lib/scratch.sh && ok "I3 tests/lib is infra" || bad "I3 tests/lib/scratch.sh not infra"
has @infra bin/suite-reuse.sh && ok "I3 bin/suite-reuse.sh is infra" || bad "I3 bin/suite-reuse.sh not infra"
has @infra bin/lib/suite-fingerprint.sh && ok "I3 bin/lib/suite-fingerprint.sh is infra" || bad "I3 suite-fingerprint not infra"
has @infra bin/b.sh && bad "I3 bin/b.sh is not infra" || ok "I3 an ordinary script is not infra"

LC_ALL=C sort -u "$OUT" | cmp -s - "$OUT" && ok "I4 sorted and unique" || bad "I4 not sort -u"
E="$T/empty"; mkdir -p "$E/bin"
"$TI" --root "$E" inputs > "$T/e.out" 2> "$T/e.err"; rc=$?
{ [ "$rc" = 2 ] && [ ! -s "$T/e.out" ] && [ -s "$T/e.err" ]; } && ok "I4 no suites: rc 2, stderr, empty stdout" \
  || bad "I4 no suites: rc=$rc out=$(wc -l < "$T/e.out")"
"$TI" inputs --check > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "I4 --check is not an inputs flag" || bad "I4 inputs --check rc=$rc"

# I4 the named scan dies: an awk shim fails only on the scan's `-v nf=` call.
SH="$T/shim"; mkdir -p "$SH"; REAL_AWK=$(command -v awk)
printf '#!/bin/bash\nfor a in "$@"; do case "$a" in nf=*) exit 2 ;; esac; done\nexec %q "$@"\n' "$REAL_AWK" > "$SH/awk"
chmod +x "$SH/awk"
PATH="$SH:$PATH" "$TI" --root "$R" inputs > "$T/n.out" 2> "$T/n.err"; rc=$?
{ [ "$rc" = 2 ] && [ ! -s "$T/n.out" ] && grep -q 'named-function scan failed' "$T/n.err"; } \
  && ok "I4 a dead named scan: rc 2, stderr, empty stdout" \
  || bad "I4 dead named scan: rc=$rc out=$(wc -l < "$T/n.out") err=$(head -1 "$T/n.err")"

# I5 the real tree.
"$TI" inputs > "$T/real.tsv" 2> "$T/real.err"; rc=$?
[ "$rc" = 0 ] && ok "I5 real tree rc 0" || bad "I5 real tree rc=$rc: $(head -3 "$T/real.err")"
missing=$(cd "$DIR" && ls tests/*.sh | while IFS= read -r s; do grep -qxF "$(printf '%s\t%s' "$s" "$s")" "$T/real.tsv" || echo "$s"; done | awk 'NR <= 3')
[ -z "$missing" ] && ok "I5 every suite has a self row" || bad "I5 suites with no self row: $missing"
grep -qxF "$(printf '@infra\tbin/suite-reuse.sh')" "$T/real.tsv" && [ -f "$DIR/bin/suite-reuse.sh" ] \
  && ok "I5 bin/suite-reuse.sh is infra in the real tree" || bad "I5 bin/suite-reuse.sh not infra"

echo "test-impact-inputs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
