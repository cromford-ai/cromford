#!/bin/bash
# tests/test-impact-dir-rows.bh-8050-test.sh — BH-8050 (slice C0): A DIRECTORY
# ROW THAT IS NOT A SCAN IS NARROWED TO THE FILES IT REACHES.
#
# bin/test-impact.sh gave a suite a whole-directory row (`bin/`, `bin/lib/`)
# for a loop-bound copy (`for f in a.sh b.sh; do cp "$DIR/bin/$f" …`) and for a
# whole-directory copy into a scratch tree, and a bin script whose `source`
# line has a loop-bound tail gave an edge to its whole lib directory.
# bin/lib/test-impact-dir-rows.sh (tdr_rows, tdr_edges) narrows those rows to
# the files they name. Anything it cannot prove keeps today's row.
#
# Every case drives the real bin/test-impact.sh against a scratch git repo.
#   N1-N7  rows the map narrows (the row is gone, the file rows are there)
#   K1-K17 rows the map keeps (the near misses; K17, a list continued with
#          `\`, is kept because `\` is not a literal word)
#   K20    a copy line that also reads the copy (`cat` of a glob in it)
#   K21    a whole copy put on PATH: the copy, not a file of it, is named
#   K14    the knob: 0 and an unknown value give today's map
#   K15    `inputs` (the suite fingerprint) keeps today's map
#   K18    a lib that fails, or is missing: today's map, one fallback line
#   K19    the count line counts the rows it dropped
#   S1     a plain select over a range: a change to bin/b.sh selects the
#          suites that copy b.sh and not the ones that copy only a.sh
#
# Self-contained: no network, no secrets, no clock read.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"
LIB="$DIR/bin/lib/test-impact-dir-rows.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v git >/dev/null || { echo "test-impact-dir-rows-8050: git is required"; exit 2; }
[ -r "$LIB" ] && ok || bad "the lib bin/lib/test-impact-dir-rows.sh must exist"

# ── the scratch repository ──────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests" "$R/catalog/test-impact-learned.d" "$R/catalog/ci-batch-regression.d"
for f in foo a b other; do printf '#!/bin/bash\necho %s\n' "$f" > "$R/bin/$f.sh"; done
for f in q z l1 l2; do printf '#!/bin/bash\necho %s\n' "$f" > "$R/bin/lib/$f.sh"; done
# p.sh sources r.sh: the closure carries a narrowed p.sh row on to r.sh (N3).
printf '#!/bin/bash\n# shellcheck source=bin/lib/r.sh\n. "$(dirname "${BASH_SOURCE[0]}")/r.sh"\n' > "$R/bin/lib/p.sh"
printf '#!/bin/bash\necho r\n' > "$R/bin/lib/r.sh"

# N5: a loop-bound source tail in a bin script.
cat > "$R/bin/lane.sh" <<'SH'
#!/bin/bash
H="$(cd "$(dirname "$0")/.." && pwd)"
for _l in p.sh q.sh; do
  . "$H/bin/lib/$_l"
done
SH
# K3e: the same tail, bound by `read`.
cat > "$R/bin/lane-read.sh" <<'SH'
#!/bin/bash
H="$(cd "$(dirname "$0")/.." && pwd)"
while read -r _l; do
  . "$H/bin/lib/$_l"
done < /dev/null
SH
# K5e: the loop variable is also assigned.
cat > "$R/bin/lane-asg.sh" <<'SH'
#!/bin/bash
H="$(cd "$(dirname "$0")/.." && pwd)"
_l=${1:-l1.sh}
for _l in p.sh q.sh; do
  . "$H/bin/lib/$_l"
done
SH

hdr() { printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\nT=$(mktemp -d)\n'; }
suite() { { hdr; cat; } > "$R/tests/$1-test.sh"; }

suite n1 <<'SH'
cp -a "$DIR/bin" "$T/bin"
bash "$T/bin/foo.sh"
SH
suite n2 <<'SH'
H="$T/h"
for f in a.sh b.sh; do cp "$DIR/bin/$f" "$H/bin/$f"; done
SH
# scratch-closure-allow: the n3 line below is fixture text for the selector to read (case N3), written into the scratch repo and never run
suite n3 <<'SH'
H="$T/h"
for l in p.sh q.sh; do cp "$DIR/bin/lib/$l" "$H/bin/lib/$l"; done
SH
suite n4 <<'SH'
for f in a b; do cp "$DIR/bin/$f.sh" "$T/bin/"; done
SH
suite n5 <<'SH'
bash "$DIR/bin/lane.sh"
SH
suite n6 <<'SH'
cp -a "$DIR/bin" "$T/bin"
chmod +x "$T/bin/"*.sh
bash "$T/bin/foo.sh"
SH
suite n7 <<'SH'
LIBS=(a.sh b.sh)
for l in "${LIBS[@]}"; do cp "$DIR/bin/$l" "$T/bin/$l"; done
SH
suite k1 <<'SH'
grep -rn foo "$DIR/bin" >/dev/null
SH
suite k1b <<'SH'
grep -n foo "$DIR/bin/"*.sh >/dev/null
SH
suite k2 <<'SH'
for f in "$DIR"/bin/*.sh; do cp "$f" "$T/bin/"; done
SH
suite k3 <<'SH'
while read -r f; do cp "$DIR/bin/$f" "$T/bin/"; done < /dev/null
SH
suite k3b <<'SH'
for f in a.sh b.sh; do cp "$DIR/bin/$f" "$T/bin/"; done
read -r f < /dev/null
SH
suite k3e <<'SH'
bash "$DIR/bin/lane-read.sh"
SH
suite k4 <<'SH'
for f in a.sh missing.sh; do cp "$DIR/bin/$f" "$T/bin/"; done
SH
suite k5 <<'SH'
f=$1
for f in a.sh b.sh; do cp "$DIR/bin/$f" "$T/bin/"; done
SH
suite k5e <<'SH'
bash "$DIR/bin/lane-asg.sh"
SH
suite k6 <<'SH'
cp -a "$DIR/bin" "$T/bin"
name=foo
bash "$T/bin/$name.sh"
SH
suite k7 <<'SH'
cp -a "$DIR/bin" "$T/bin"
for s in "$T/bin/"*.sh; do bash "$s"; done
SH
suite k8 <<'SH'
HARNESS_ROOT="$DIR/bin" bash -c true
SH
suite k9 <<'SH'
cp -a "$DIR/bin" "$T/bin"
bash "$T/bin/foo.sh"
python3 - <<'PY'
import os
base = os.environ.get("K9_BASE", ".")
for d, _, fs in os.walk(os.path.join(base, "bin")):
    pass
PY
SH
suite k10a <<'SH'
cp -a "$DIR/bin" "$T/bin"
bash "$T/bin/foo.sh"
SH
suite k10b <<'SH'
cp -a "$DIR/bin" "$T/bin"
bash "$T/bin/foo.sh"
SH
suite k11 <<'SH'
# for f in a.sh b.sh; do
cp "$DIR/bin/$f" "$T/bin/"
SH
suite k12 <<'SH'
for f in a.sh $(ls); do cp "$DIR/bin/$f" "$T/bin/"; done
SH
suite k13 <<'SH'
for f in a.sh b.sh; do cp "$DIR/bin/$f" "$T/bin/"; done
for f in "$@"; do echo "$f"; done
SH
suite k16 <<'SH'
for f in a.sh b.sh; do cp "$DIR/bin/$f" "$T/bin/"; done
grep -n x "$DIR/bin/"*.sh >/dev/null
SH
suite k17 <<'SH'
for f in a.sh \
    b.sh; do cp "$DIR/bin/$f" "$T/bin/"; done
SH
suite k20 <<'SH'
cp -a "$DIR/bin" "$T/bin" && cat "$T/bin/"*.sh >/dev/null
bash "$T/bin/foo.sh"
SH
suite k21 <<'SH'
cp -a "$DIR/bin" "$T/bin"
PATH="$T/bin:$PATH" foo.sh
bash "$T/bin/foo.sh"
SH
printf 'bin/\ttests/k10a-test.sh\tbatch-fixture\t2026-10-22\n' > "$R/catalog/test-impact-learned.d/k10a.tsv"
printf 'tests/k10b-test.sh\tbin/\n' > "$R/catalog/ci-batch-regression.d/k10b.txt"

gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)

# map <label> [env...] — the real map, stderr kept.
map() { local l="$1"; shift; env "$@" "$TI" --root "$R" map > "$T/$l.map" 2> "$T/$l.err"; echo $? > "$T/$l.rc"; }
row()   { grep -qxF "tests/$2-test.sh	$3" "$T/$1.map"; }
yes_row() { row "$1" "$2" "$3" && ok || bad "$4: tests/$2-test.sh must have the row '$3' ($(grep "^tests/$2-test.sh" "$T/$1.map" | cut -f2 | tr '\n' ' '))"; }
no_row()  { row "$1" "$2" "$3" && bad "$4: tests/$2-test.sh must NOT have the row '$3' ($(grep "^tests/$2-test.sh" "$T/$1.map" | cut -f2 | tr '\n' ' '))" || ok; }

map on
map off TI_DIR_ROWS=0
[ "$(cat "$T/on.rc")" = 0 ] && [ -s "$T/on.map" ] && ok || bad "the map must build (rc $(cat "$T/on.rc"): $(cat "$T/on.err"))"

# The premise: with the knob off, every case below has its directory row.
for s in n1 n2 n4 n6 n7 k6 k7 k9 k10a k10b k20 k21; do yes_row off "$s" bin/ "premise (off)"; done
yes_row off n3 bin/lib/ "premise (off)"
yes_row off n5 bin/lib/ "premise (off)"

# ── N: narrowed ─────────────────────────────────────────────────────────────
no_row on n1 bin/ N1;  yes_row on n1 bin/foo.sh N1; no_row on n1 bin/a.sh N1
no_row on n2 bin/ N2;  yes_row on n2 bin/a.sh N2;   yes_row on n2 bin/b.sh N2; no_row on n2 bin/foo.sh N2
no_row on n3 bin/lib/ N3; yes_row on n3 bin/lib/p.sh N3; yes_row on n3 bin/lib/q.sh N3
yes_row on n3 bin/lib/r.sh "N3 (closure)"; no_row on n3 bin/lib/z.sh N3
no_row on n4 bin/ N4;  yes_row on n4 bin/a.sh N4;   yes_row on n4 bin/b.sh N4
no_row on n5 bin/lib/ N5; yes_row on n5 bin/lib/p.sh N5; yes_row on n5 bin/lib/q.sh N5
yes_row on n5 bin/lib/r.sh "N5 (closure)"; no_row on n5 bin/lib/z.sh N5
no_row on n6 bin/ N6;  yes_row on n6 bin/foo.sh N6
no_row on n7 bin/ N7;  yes_row on n7 bin/a.sh N7;   yes_row on n7 bin/b.sh N7

# ── K: kept ─────────────────────────────────────────────────────────────────
yes_row on k1 bin/ "K1 (grep -r)"
yes_row on k1b bin/ "K1b (grep over a glob)"
yes_row on k2 bin/ "K2 (a glob in a loop header)"
yes_row on k3 bin/ "K3 (while read)"
yes_row on k3b bin/ "K3b (a literal loop variable also bound by read)"
yes_row on k3e bin/lib/ "K3e (a read-bound source tail keeps the edge)"
yes_row on k4 bin/ "K4 (a word that is not a file)"; yes_row on k4 bin/a.sh "K4 (the file word is added)"
yes_row on k5 bin/ "K5 (the loop variable is assigned)"
yes_row on k5e bin/lib/ "K5e (an assigned source tail keeps the edge)"
yes_row on k6 bin/ "K6 (a dynamic run of the scratch copy)"
yes_row on k7 bin/ "K7 (a glob run of the scratch copy)"
yes_row on k8 bin/ "K8 (a root passed whole, no copy verb)"
yes_row on k9 bin/ "K9 (a treedir row is protected)"
yes_row on k10a bin/ "K10 (a learned row is protected)"
yes_row on k10b bin/ "K10 (a regression row is protected)"
yes_row on k11 bin/ "K11 (a commented loop binds nothing)"
yes_row on k12 bin/ "K12 (a command substitution in the loop list)"
yes_row on k13 bin/ "K13 (a second non-literal loop over the same name)"
yes_row on k16 bin/ "K16 (one loop-bound line and one scan line)"
yes_row on k17 bin/ "K17 (a loop list continued with a backslash)"
yes_row on k20 bin/ "K20 (a copy line that also scans the copy)"
yes_row on k21 bin/ "K21 (a whole copy on PATH)"

# A kept suite loses no row at all, and only a narrowed suite loses any: its
# directory row and the closure rows that came through it.
comm -23 "$T/off.map" "$T/on.map" > "$T/lost"
grep -v '^tests/n[0-9]-test\.sh	' "$T/lost" > "$T/lost.other"
[ ! -s "$T/lost.other" ] && ok || bad "only a narrowed (N) suite may lose rows (lost: $(tr '\n' ' ' < "$T/lost.other"))"
grep -q "	tests/n[0-9]-test\.sh$" "$T/lost" && bad "a self row was lost" || ok

# The log line: drops N1-N4, N6, N7 rows and the N5 edge (lane.sh -> bin/lib/).
grep -qx 'dir-rows: narrowed 6 directory row(s) of 6 suite(s), 1 edge(s)' "$T/on.err" && ok \
  || bad "the on map logs 'dir-rows: narrowed 6 directory row(s) of 6 suite(s), 1 edge(s)' (got: $(cat "$T/on.err"))"

# ── K14: the knob ───────────────────────────────────────────────────────────
grep -q 'dir-rows' "$T/off.err" && bad "K14: TI_DIR_ROWS=0 logs nothing (got: $(cat "$T/off.err"))" || ok
map odd TI_DIR_ROWS=yes
cmp -s "$T/odd.map" "$T/off.map" && ok || bad "K14: an unknown knob value is today's map ($(diff "$T/odd.map" "$T/off.map" | head -3 | tr '\n' ' '))"
[ "$(grep -c 'dir-rows: off (TI_DIR_ROWS=yes)' "$T/odd.err")" = 1 ] && ok || bad "K14: an unknown value logs one off line (got: $(cat "$T/odd.err"))"
map empty TI_DIR_ROWS=
cmp -s "$T/empty.map" "$T/on.map" && ok || bad "K14: an empty knob is on"
map one TI_DIR_ROWS=1
cmp -s "$T/one.map" "$T/on.map" && ok || bad "K14: TI_DIR_ROWS=1 is on"

# ── K15: inputs keep today's map ────────────────────────────────────────────
"$TI" --root "$R" inputs > "$T/inputs" 2> "$T/inputs.err"
grep -qxF "tests/n1-test.sh	bin/" "$T/inputs" && ok || bad "K15: inputs must keep the n1 bin/ row (today's map) ($(grep '^tests/n1-test.sh' "$T/inputs" | cut -f2 | tr '\n' ' '))"
grep -q 'dir-rows' "$T/inputs.err" && bad "K15: inputs builds with the knob off and logs nothing (got: $(cat "$T/inputs.err"))" || ok

# ── K18: a failing or missing lib is today's map ────────────────────────────
# The stub goes in first: scratch_install_closure skips a file that exists.
G="$T/stub"; mkdir -p "$G/bin/lib"
cat > "$G/bin/lib/test-impact-dir-rows.sh" <<'SH'
tdr_enabled() { return 0; }
tdr_rows() { echo partial; return 3; }
tdr_edges() { echo partial; return 3; }
SH
scratch_install_closure bin/test-impact.sh "$G" > /dev/null || bad "K18: the selector closure must install"
"$G/bin/test-impact.sh" --root "$R" map > "$T/stub.map" 2> "$T/stub.err"
cmp -s "$T/stub.map" "$T/off.map" && ok || bad "K18: a lib that fails must leave today's map ($(diff "$T/stub.map" "$T/off.map" | head -3 | tr '\n' ' '))"
grep -qx 'dir-rows: fallback (lib failed)' "$T/stub.err" && grep -qx 'dir-rows: fallback (edges: lib failed)' "$T/stub.err" && ok \
  || bad "K18: both fallback lines (got: $(cat "$T/stub.err"))"
rm -f "$G/bin/lib/test-impact-dir-rows.sh"
"$G/bin/test-impact.sh" --root "$R" map > "$T/miss.map" 2> "$T/miss.err"; RC=$?
[ "$RC" = 0 ] && cmp -s "$T/miss.map" "$T/off.map" && ok || bad "K18: a missing lib must leave today's map (rc $RC)"
grep -q 'dir-rows: fallback (lib failed)' "$T/miss.err" && ok || bad "K18: a missing lib logs the fallback (got: $(cat "$T/miss.err"))"

# ── S1: a plain select over a range ─────────────────────────────────────────
echo 'echo b2' >> "$R/bin/b.sh"; gitc add -A; gitc commit -qm S1
"$TI" --root "$R" select "$BASE..HEAD" > "$T/s1.sel" 2> "$T/s1.err"
TI_DIR_ROWS=0 "$TI" --root "$R" select "$BASE..HEAD" > "$T/s1off.sel" 2>/dev/null
grep -qxF tests/n2-test.sh "$T/s1.sel" && ok || bad "S1: a bin/b.sh change selects n2 (it copies b.sh) (got: $(tr '\n' ' ' < "$T/s1.sel"))"
grep -qxF tests/n1-test.sh "$T/s1.sel" && bad "S1: a bin/b.sh change must not select n1 (it runs only foo.sh)" || ok
grep -qxF tests/n1-test.sh "$T/s1off.sel" && ok || bad "S1: with the knob off, n1 is selected (today's map)"

# ── K19: the count is the rows dropped ──────────────────────────────────────
R2="$T/repo2"; mkdir -p "$R2/bin" "$R2/tests"
printf '#!/bin/bash\necho a\n' > "$R2/bin/a.sh"; printf '#!/bin/bash\necho b\n' > "$R2/bin/b.sh"
for s in d1 d2 d3; do { hdr; echo 'for f in a.sh b.sh; do cp "$DIR/bin/$f" "$T/bin/"; done'; } > "$R2/tests/$s-test.sh"; done
for s in e1 e2; do { hdr; echo 'grep -n x "$DIR/bin/"*.sh'; } > "$R2/tests/$s-test.sh"; done
git -C "$R2" init -q; git -C "$R2" -c user.email=t@example.com -c user.name=t add -A
git -C "$R2" -c user.email=t@example.com -c user.name=t commit -qm base
"$TI" --root "$R2" map > "$T/r2.map" 2> "$T/r2.err"
grep -qx 'dir-rows: narrowed 3 directory row(s) of 3 suite(s), 0 edge(s)' "$T/r2.err" && ok \
  || bad "K19: 3 drops and 2 keeps log 'narrowed 3 … of 3 suite(s), 0 edge(s)' (got: $(cat "$T/r2.err"))"
[ "$(grep -c "	bin/$" "$T/r2.map")" = 2 ] && ok || bad "K19: the two scan suites keep bin/ ($(grep "	bin/$" "$T/r2.map" | tr '\n' ' '))"

echo "test-impact-dir-rows-8050: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
