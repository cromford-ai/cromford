#!/bin/bash
# tests/lead-review-split-growth-lint.bh-6293-test.sh — BH-6293: the split host
# bin/lead-review.sh must not grow back, and a change under its module dir
# bin/lib/lead-review/ selects what a change to the host selects.
#
#   G0  the real bin/lead-review.sh marker round-trips through the lint: host
#       bin/lead-review.sh, dir bin/lib/lead-review/, limit 40.
#   G1  +60 to the host is refused, one line naming the host, `grew 60` and the
#       module dir. Red on a tree with no lint.
#   G2  +60 under the module dir only is clean.
#   G3  bin/test-impact.sh select (real tree): a change to result.sh, attempts.sh
#       or worker.sh selects a superset of what a change to the host selects.
#   G4  +41 net is refused; +40 net is clean.
#   G5  the fork's limit wins: raised to 500 in the diff (+60) is refused, the
#       marker deleted in the diff (+60) is refused, a malformed marker on a host
#       with no fork marker is a `malformed` finding, a valid fork marker made
#       malformed in the diff is a `malformed` finding (stderr says
#       `malformed`, not `over the limit`), deleting the marker prints a
#       `marker removed` note on stderr.
#   G6  clean: +60 to an unmarked file, +60/-60, -200, an empty diff, a
#       malformed marker already at the fork when the diff touches another file.
#   G7  the rules-pack row: `split-host-growth`, delta cmd, `--base <fork>`.
#   G8  rc 2: an unresolvable base, a root that is not a work tree, an unknown
#       flag. Never rc 0.
#   G9  the mm_load edge: `mm_load "${BASH_SOURCE[0]%/*}"` (quoted or not) gives
#       the script's directory as a map row; a `#` comment with that text,
#       `mm_load "$dir"` and `mm_load() {` give none.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-split-growth-lint.bh-6293-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/split-host-growth-lint.sh"
TI="$DIR/bin/test-impact.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export GIT_AUTHOR_DATE='2026-10-16T12:00:00Z' GIT_COMMITTER_DATE='2026-10-16T12:00:00Z'
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
gitc() { git -C "$1" -c user.email=t@example.invalid -c user.name=t "${@:2}"; }

# fx <name> <marker-line|-> — a repo with bin/host.sh (100 lines, the marker as
# line 2 unless -) committed on main, checked out on branch pr. Prints its path.
fx() {
  local r="$T/fx-$1"
  git init -q -b main "$r"; mkdir -p "$r/bin"
  { echo '#!/bin/bash'; [ "$2" = - ] || echo "$2"; seq 1 98 | sed 's/^/echo line /'; } > "$r/bin/host.sh"
  gitc "$r" add -A; gitc "$r" commit -qm base; gitc "$r" checkout -qb pr
  printf '%s\n' "$r"
}
grow() { mkdir -p "$(dirname "$1")"; seq 1 "$2" | sed 's/^/echo added /' >> "$1"; }
commit() { gitc "$1" add -A; gitc "$1" commit -qm change --allow-empty; }
# lint <repo> — runs the lint against main; sets RC and OUT.
lint() { OUT=$(bash "$LINT" --base main "$1" 2>/dev/null); RC=$?; }
M40='# split-host: bin/lib/host/ max-growth=40'

# ── G0 + G1: the real marker; +60 to the real host is refused ───────────────
r="$T/fx-real"; git init -q -b main "$r"; mkdir -p "$r/bin"
cp "$DIR/bin/lead-review.sh" "$r/bin/"; commit "$r"; gitc "$r" checkout -qb pr
grow "$r/bin/lead-review.sh" 60; commit "$r"; lint "$r"
if [ "$RC" = 1 ] && [ "$(grep -c . <<<"$OUT")" = 1 ] && [[ $OUT == "bin/lead-review.sh: grew 60 lines"* ]] \
   && [[ $OUT == *"Put new code in bin/lib/lead-review/ and"* ]]; then ok
else bad "G1: +60 on the real bin/lead-review.sh is refused with one line naming the host, grew 60 and bin/lib/lead-review/ (rc=$RC out=$OUT)"; fi
[[ $OUT == *"(limit 40; +60 -0)"* ]] && ok || bad "G0: the real marker's limit is not 40 (out=$OUT)"
gitc "$r" reset -q --hard main; grow "$r/bin/lead-review.sh" 40; commit "$r"; lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G0: +40 on the real bin/lead-review.sh is at its limit and clean (rc=$RC out=$OUT)"

# ── G2: growth in the module dir is clean ───────────────────────────────────
r=$(fx g2 "$M40"); grow "$r/bin/lib/host/new.sh" 60; commit "$r"; lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G2: +60 under the module dir is clean (rc=$RC out=$OUT)"
r="$T/fx-real2"; git init -q -b main "$r"; mkdir -p "$r/bin"
cp "$DIR/bin/lead-review.sh" "$r/bin/"; commit "$r"; gitc "$r" checkout -qb pr
grow "$r/bin/lib/lead-review/new.sh" 60; commit "$r"; lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G2: +60 under bin/lib/lead-review/ beside the real host is clean (rc=$RC out=$OUT)"

# ── G4: the boundary ────────────────────────────────────────────────────────
r=$(fx g4a "$M40"); grow "$r/bin/host.sh" 41; commit "$r"; lint "$r"
[ "$RC" = 1 ] && [[ $OUT == "bin/host.sh: grew 41 lines in this diff (limit 40; +41 -0)."* ]] && ok \
  || bad "G4: +41 is refused (rc=$RC out=$OUT)"
r=$(fx g4b "$M40"); grow "$r/bin/host.sh" 40; commit "$r"; lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G4: +40 is clean (rc=$RC out=$OUT)"
r=$(fx g4c "$M40"); sed -i '10,29d' "$r/bin/host.sh"; grow "$r/bin/host.sh" 61; commit "$r"; lint "$r"
[ "$RC" = 1 ] && [[ $OUT == *"grew 41 lines"*"+61 -20"* ]] && ok || bad "G4: +61/-20 is net 41 and refused (rc=$RC out=$OUT)"

# ── G5: the fork's limit wins ───────────────────────────────────────────────
r=$(fx g5a "$M40"); sed -i '2s/max-growth=40/max-growth=500/' "$r/bin/host.sh"; grow "$r/bin/host.sh" 60; commit "$r"; lint "$r"
[ "$RC" = 1 ] && [[ $OUT == *"limit 40"* ]] && ok || bad "G5: raising the limit in the same diff does not count (rc=$RC out=$OUT)"
r=$(fx g5b "$M40"); sed -i '2d' "$r/bin/host.sh"; grow "$r/bin/host.sh" 61; commit "$r"; lint "$r"
[ "$RC" = 1 ] && [[ $OUT == *"grew 60 lines"*"limit 40"* ]] && ok || bad "G5: deleting the marker does not escape the lint (rc=$RC out=$OUT)"
ERR=$(bash "$LINT" --base main "$r" 2>&1 >/dev/null)
[[ $ERR == *"bin/host.sh: split-host marker removed"* ]] && ok || bad "G5: deleting the marker prints a marker removed note (err=$ERR)"
r=$(fx g5e "$M40"); sed -i '2s/max-growth=40/max-growth=forty/' "$r/bin/host.sh"; commit "$r"; lint "$r"
[ "$RC" = 1 ] && [ "$OUT" = "bin/host.sh: malformed split-host marker: # split-host: bin/lib/host/ max-growth=forty" ] && ok \
  || bad "G5: a valid fork marker made malformed in the diff is a finding (rc=$RC out=$OUT)"
ERR=$(bash "$LINT" --base main "$r" 2>&1 >/dev/null)
[[ $ERR == *"1 malformed split-host marker"* ]] && [[ $ERR != *"over the limit"* ]] && ok \
  || bad "G5: a malformed-only finding does not say over the limit on stderr (err=$ERR)"
r=$(fx g5c -); printf '#!/bin/bash\n# split-host: nope\necho x\n' > "$r/bin/new.sh"; commit "$r"; lint "$r"
[ "$RC" = 1 ] && [[ $OUT == "bin/new.sh: malformed split-host marker"* ]] && ok || bad "G5: a malformed marker is a finding (rc=$RC out=$OUT)"
r=$(fx g5d -); sed -i "2i $M40" "$r/bin/host.sh"; grow "$r/bin/host.sh" 10; commit "$r"; lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G5: a marker added in the diff with growth under its limit is clean (rc=$RC out=$OUT)"

# ── G6: clean shapes ────────────────────────────────────────────────────────
r=$(fx g6a "$M40"); grow "$r/bin/host-enqueue.sh" 60; commit "$r"; lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G6: +60 to an unmarked file of a similar name is clean (rc=$RC out=$OUT)"
r=$(fx g6b "$M40"); sed -i '10,69d' "$r/bin/host.sh"; grow "$r/bin/host.sh" 60; commit "$r"; lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G6: +60/-60 is clean (rc=$RC out=$OUT)"
r=$(fx g6c "$M40"); grow "$r/bin/host.sh" 200; gitc "$r" add -A; gitc "$r" commit -qm big; gitc "$r" branch -f main
sed -i '10,209d' "$r/bin/host.sh"; commit "$r"; lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G6: -200 is clean (rc=$RC out=$OUT)"
r=$(fx g6e '# split-host: bin/lib/host/ max-growth=forty'); grow "$r/bin/unrelated.sh" 5; commit "$r"; lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G6: a malformed marker already at the fork does not block a diff that touches another file (rc=$RC out=$OUT)"
r=$(fx g6d "$M40"); lint "$r"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G6: an empty diff is clean (rc=$RC out=$OUT)"
OUT=$(cd "$DIR" && bash "$LINT" --base HEAD . 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "G6: an empty diff on the real tree is clean (rc=$RC out=$OUT)"

# ── G7: the rules-pack row ──────────────────────────────────────────────────
row=$(awk -F'\t' '$1 == "split-host-growth"' "$DIR/catalog/rules-pack.tsv")
IFS=$'\t' read -r id shape kind argv _ <<<"$row"
[ "$id" = split-host-growth ] && [ "$shape" = delta ] && [ "$kind" = cmd ] \
  && [[ $argv == "bin/split-host-growth-lint.sh --base <fork>"* ]] && ok \
  || bad "G7: catalog/rules-pack.tsv has no split-host-growth delta cmd row with --base <fork> (got: $row)"
"$DIR/bin/rules-pack.sh" --list 2>/dev/null | awk '{ print $1 }' | grep -qx split-host-growth && ok \
  || bad "G7: bin/rules-pack.sh --list does not list the split-host-growth component"

# ── G8: rc 2, never rc 0 ────────────────────────────────────────────────────
r=$(fx g8 "$M40"); grow "$r/bin/host.sh" 60; commit "$r"
OUT=$(bash "$LINT" --base nosuchref "$r" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "G8: --base nosuchref is rc 2 (rc=$RC)"
mkdir -p "$T/notgit"
OUT=$(bash "$LINT" --base main "$T/notgit" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "G8: a root that is not a work tree is rc 2 (rc=$RC)"
OUT=$(bash "$LINT" --bogus "$r" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && ok || bad "G8: an unknown flag is rc 2 (rc=$RC)"
OUT=$(bash "$LINT" --base 2>/dev/null); RC=$?
[ "$RC" = 2 ] && ok || bad "G8: --base with no value is rc 2 (rc=$RC)"

# ── G9: the mm_load edge in bin/test-impact.sh ──────────────────────────────
S="$T/g9"; mkdir -p "$S/tests"
mkmod() { # mkmod <dir> <load line> — bin/lib/<dir>/load.sh plus one module, a host, a suite
  mkdir -p "$S/bin/lib/$1"
  printf '#!/bin/bash\n%s\n' "$2" > "$S/bin/lib/$1/load.sh"
  printf '#!/bin/bash\n# module: m\nm_%s() { :; }\n' "$1" > "$S/bin/lib/$1/m.sh"
  printf '#!/bin/bash\n. "$HARNESS/bin/lib/%s/load.sh"\n' "$1" > "$S/bin/host-$1.sh"
  printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\nbash "$DIR/bin/host-%s.sh"\n' "$1" > "$S/tests/$1-test.sh"
}
mkmod quoted 'mm_load "${BASH_SOURCE[0]%/*}"'
mkmod bare 'mm_load ${BASH_SOURCE[0]%/*}'
mkmod comment '# mm_load "${BASH_SOURCE[0]%/*}"'
mkmod vardir 'mm_load "$dir"'
mkmod defn 'mm_load() { :; }'
git init -q -b main "$S"; gitc "$S" add -A; gitc "$S" commit -qm base
"$TI" --root "$S" map --out "$T/g9.map" 2>"$T/g9.err" || bad "G9: the fixture map did not build: $(head -3 "$T/g9.err")"
for d in quoted bare; do
  grep -qxF "tests/$d-test.sh	bin/lib/$d/" "$T/g9.map" && ok \
    || bad "G9: no dir row for bin/lib/$d/ (mm_load on the script's own dir): $(grep "$d" "$T/g9.map" | tr '\n' ' ')"
done
for d in comment vardir defn; do
  ! awk -F'\t' -v p="bin/lib/$d/" '$2 == p { f = 1 } END { exit !f }' "$T/g9.map" && ok || bad "G9: bin/lib/$d/load.sh gave a dir row it should not"
done

# ── G3: a module change selects what a host change selects (real tree) ──────
if "$TI" map --root "$DIR" --out "$T/map" 2>"$T/map.err"; then
  sel() { printf '%s\n' "$1" > "$T/changed"
    "$TI" select --root "$DIR" --map "$T/map" --map-only --changed "$T/changed" 2>/dev/null | LC_ALL=C sort -u; }
  host=$(sel bin/lead-review.sh)
  lrs=$(cd "$DIR" && grep -l 'lead-review.sh' tests/*.sh | LC_ALL=C sort -u)
  inhost=$(comm -12 <(printf '%s\n' "$host") <(printf '%s\n' "$lrs"))
  [ "$(grep -c . <<<"$inhost")" -ge 10 ] && ok || bad "G3: the host selects fewer than 10 lead-review suites: $(grep -c . <<<"$inhost")"
  for m in result attempts worker; do
    p="bin/lib/lead-review/$m.sh"; mod=$(sel "$p")
    lost=$(comm -23 <(printf '%s\n' "$host") <(printf '%s\n' "$mod"))
    [ -n "$mod" ] && [ -z "$lost" ] && ok \
      || bad "G3: $p does not select every suite bin/lead-review.sh selects ($(grep -c . <<<"$lost") missing, e.g. $(head -n 3 <<<"$lost" | tr '\n' ' '))"
  done
else
  bad "G3: bin/test-impact.sh map could not be built: $(head -3 "$T/map.err")"
fi

echo "lead-review-split-growth-lint.bh-6293: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
