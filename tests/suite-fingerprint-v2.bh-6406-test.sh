#!/bin/bash
# tests/suite-fingerprint-v2.bh-6406-test.sh — suite fingerprint v2 (BH-6406,
# C1 of BH-6371): a tests/lib/ helper or a catalog/ file is an input of the
# suites that reach it, not infra of every suite.
#
# v1 hashed every tests/lib/ and catalog/ path into infra_hash, so one helper
# edit moved all 2,147 fingerprints and a batch could reuse nothing. v2 keeps a
# path infra only when the tree's own catalog/ci-batch-escalate.tsv escalates
# it, when no suite reaches it, or when the rules cannot be read. Each case is
# a one-file commit in a committed scratch checkout carrying the real
# bin/test-impact.sh, bin/fast-lints.sh, bin/suite-reuse.sh,
# "$DIR/bin/lib/suite-fingerprint.sh" and "$DIR/bin/lib/ci-batch-escalate.sh",
# with sfp_compute before and after:
#
#   V1  edit tests/lib/h1.sh (u1 sources it) -> only u1 moves
#   V2  edit tests/lib/h2.sh (h1 names it, no suite does) -> only u1 moves
#   V3  edit catalog/c1.json (u3 reads it) -> only u3 moves
#   V4  edit tests/lib/orphan.sh (nothing reaches it) -> every fp moves
#   V5  edit catalog/c2.json (no suite names it) -> every fp moves
#   V6  h3 names h1 (a 2-cycle: h1 names h3), then edit h2 -> u1 and u2
#       move, u3 and u4 stay
#   V7a edit tests/lib/scratch.sh (an escalate row; u4 sources it) -> all move
#   V7b the rules file removed, then edit h3 -> all move (fails closed)
#   V7c the rules lib removed, then edit h3 -> all move (fails closed)
#   V8  the `inputs` rows themselves, and CI_BATCH_ESCALATE_TSV in the
#       environment changes nothing
#   V9  the canonical text is `suite-fp v2`: the same lib with a v1 header
#       gives another fingerprint, so no v1 ledger row can match
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
NOW=2026-10-13T00:00:00Z

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
unset HARNESS_CHECKOUT CI_BATCH_ESCALATE_TSV

R="$T/repo"
mkdir -p "$R"
for s in bin/suite-reuse.sh bin/test-impact.sh bin/fast-lints.sh bin/lib/suite-fingerprint.sh bin/lib/ci-batch-escalate.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
[ -f "$R/bin/lib/ci-batch-escalate.sh" ] || { echo "the rules lib was not installed"; exit 1; }
mkdir -p "$R/tests/lib" "$R/catalog"
# h1 names h2 and h3 through a variable the map cannot root, so only the
# helper closure can see them.
cat > "$R/tests/lib/h1.sh" <<'EOF'
H1_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H1_DIR/h2.sh"
. "$H1_DIR/h3.sh"
h1() { echo v1; }
EOF
printf 'h2() { echo v1; }\n' > "$R/tests/lib/h2.sh"
printf 'h3() { echo v1; }\n' > "$R/tests/lib/h3.sh"
printf 'orphan() { echo v1; }\n' > "$R/tests/lib/orphan.sh"
printf '# scratch v1\n' > "$R/tests/lib/scratch.sh"
printf '# helpers v1\n' > "$R/tests/lib/README.md"
printf '{"v":1}\n' > "$R/catalog/c1.json"
printf '{"v":1}\n' > "$R/catalog/c2.json"
printf 'tests/lib/scratch.sh\tescalate\tglobal\n' > "$R/catalog/ci-batch-escalate.tsv"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/h1.sh"\nh1\n' > "$R/tests/u1.sh"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/h3.sh"\nh3\n' > "$R/tests/u2.sh"
printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\ncat "$DIR/catalog/c1.json"\n' > "$R/tests/u3.sh"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh"\necho plain\n' > "$R/tests/u4.sh"
# An always suite: bin/fast-lints.sh --list refuses an empty always set.
printf '#!/bin/bash\necho always\n' > "$R/tests/sa.sh"
printf 'tests/sa.sh\n' > "$R/catalog/test-impact-always.txt"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm init || { echo "cannot build the scratch checkout"; exit 1; }
U="tests/u1.sh tests/u2.sh tests/u3.sh tests/u4.sh"
printf '%s\n' $U > "$T/suites"

fp() { ( cd "$R" && . "$R/bin/lib/suite-fingerprint.sh" && sfp_compute HEAD "$T/suites" "$1" ) 2> "$1.err"; }
col() { awk -F'\t' -v s="$2" '$1 == s { print $2 }' "$1"; }
# moved <before> <after> — the suites whose fp moved, space-joined.
moved() { local s m=""; for s in $U; do [ "$(col "$1" "$s")" != "$(col "$2" "$s")" ] && m="$m $s"; done; echo "${m# }"; }
# step <tag> <path> — append one line to <path>, commit, fingerprint as $T/<tag>.
step() { printf '# %s\n' "$1" >> "$R/$2"; G commit -qam "$1" || { echo "commit failed: $1"; exit 1; }; fp "$T/$1"; }
LAST="$T/v0"
fp "$LAST"; rc=$?
[ "$rc" = 0 ] && ok "V0 rc 0" || { bad "V0 rc=$rc: $(cat "$LAST.err")"; echo "suite-fingerprint-v2: $PASS passed, $FAIL failed"; exit 1; }
n=0; for s in $U; do col "$LAST" "$s" | grep -qE '^[0-9a-f]{64}$' && n=$((n + 1)); done
[ "$n" = 4 ] && ok "V0 every suite has a fingerprint" || bad "V0 only $n of 4: $(cat "$LAST")"

# check <case> <tag> <path> <expected moved set>
check() {
  local c="$1" tag="$2" p="$3" want="$4" got
  step "$tag" "$p"
  got=$(moved "$LAST" "$T/$tag")
  [ "$got" = "$want" ] && ok "$c $p moved {${want}}" || bad "$c $p: want {${want}}, moved {${got}} $(cat "$T/$tag.err")"
  LAST="$T/$tag"
}
ALL="$U"

# ── V8 first, on the initial tree ──────────────────────────────────────────
"$R/bin/test-impact.sh" --root "$R" inputs > "$T/in.tsv" 2> "$T/in.err"; rc=$?
[ "$rc" = 0 ] && ok "V8 inputs rc 0" || bad "V8 inputs rc=$rc: $(cat "$T/in.err")"
has() { grep -qxF "$(printf '%s\t%s' "$1" "$2")" "$T/in.tsv"; }
for r in "tests/u1.sh tests/lib/h1.sh" "tests/u1.sh tests/lib/h2.sh" "tests/u1.sh tests/lib/h3.sh" \
         "tests/u3.sh catalog/c1.json" "@infra tests/lib/orphan.sh" "@infra catalog/c2.json" \
         "@infra tests/lib/scratch.sh" "@infra catalog/ci-batch-escalate.tsv"; do
  has ${r% *} ${r#* } && ok "V8 row present: $r" || bad "V8 no row: $r"
done
for r in "@infra tests/lib/h1.sh" "@infra tests/lib/h2.sh" "@infra tests/lib/h3.sh" "@infra catalog/c1.json" \
         "@infra tests/lib/README.md" "tests/u2.sh tests/lib/h1.sh" "tests/u2.sh tests/lib/h2.sh"; do
  has ${r% *} ${r#* } && bad "V8 row must be absent: $r" || ok "V8 row absent: $r"
done
CI_BATCH_ESCALATE_TSV=/dev/null "$R/bin/test-impact.sh" --root "$R" inputs > "$T/in-env.tsv" 2>/dev/null
cmp -s "$T/in.tsv" "$T/in-env.tsv" && ok "V8 CI_BATCH_ESCALATE_TSV=/dev/null: byte-identical rows" \
  || bad "V8 the environment's rules file leaked in: $(diff "$T/in.tsv" "$T/in-env.tsv" | head -5)"
printf 'nothing-here/\tescalate\tno path\n' > "$T/other.tsv"
CI_BATCH_ESCALATE_TSV="$T/other.tsv" "$R/bin/test-impact.sh" --root "$R" inputs > "$T/in-env2.tsv" 2>/dev/null
cmp -s "$T/in.tsv" "$T/in-env2.tsv" && ok "V8 CI_BATCH_ESCALATE_TSV=<other rules>: byte-identical rows" \
  || bad "V8 the environment's rules file leaked in: $(diff "$T/in.tsv" "$T/in-env2.tsv" | head -5)"

# ── V9 the canonical text names v2 ─────────────────────────────────────────
sed 's/suite-fp v2/suite-fp v1/g' "$R/bin/lib/suite-fingerprint.sh" > "$T/sfp-v1.sh"
( cd "$R" && . "$T/sfp-v1.sh" && sfp_compute HEAD "$T/suites" "$T/v9" ) 2>/dev/null
grep -q 'suite-fp v2' "$R/bin/lib/suite-fingerprint.sh" && ok "V9 the lib writes suite-fp v2" || bad "V9 no suite-fp v2 in the lib"
[ -n "$(col "$T/v9" tests/u4.sh)" ] && [ "$(col "$T/v9" tests/u4.sh)" != "$(col "$LAST" tests/u4.sh)" ] \
  && ok "V9 a v1 header gives another fingerprint for u4" || bad "V9 v1=$(col "$T/v9" tests/u4.sh) v2=$(col "$LAST" tests/u4.sh)"

# ── V1-V6 ──────────────────────────────────────────────────────────────────
check V1 v1 tests/lib/h1.sh "tests/u1.sh"
check V2 v2 tests/lib/h2.sh "tests/u1.sh"
check V3 v3 catalog/c1.json "tests/u3.sh"
check V4 v4 tests/lib/orphan.sh "$ALL"
check V5 v5 catalog/c2.json "$ALL"
check V5b v5b tests/lib/README.md ""
printf 'H3_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)\n. "$H3_DIR/h1.sh"\nh3() { echo v1; }\n' > "$R/tests/lib/h3.sh"
G commit -qam cycle; fp "$T/v6a"; LAST="$T/v6a"
check V6 v6 tests/lib/h2.sh "tests/u1.sh tests/u2.sh"

# ── V7 ─────────────────────────────────────────────────────────────────────
check V7a v7a tests/lib/scratch.sh "$ALL"
G rm -q bin/lib/ci-batch-escalate.sh && G commit -qm nolib; fp "$T/v7c0"; LAST="$T/v7c0"
check V7c v7c tests/lib/h3.sh "$ALL"
G checkout -q HEAD~2 -- bin/lib/ci-batch-escalate.sh && G commit -qm lib-back; fp "$T/v7b0"; LAST="$T/v7b0"
check V7c-back v7cb tests/lib/h3.sh "tests/u1.sh tests/u2.sh"
G rm -q catalog/ci-batch-escalate.tsv && G commit -qm norules; fp "$T/v7b1"; LAST="$T/v7b1"
check V7b v7b tests/lib/h3.sh "$ALL"

echo "suite-fingerprint-v2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
