#!/bin/bash
# tests/test-impact-mix.bh-8050-test.sh — BH-8050: bin/test-impact-mix.sh
# prints the selection of each merge range BY REASON, as a markdown table.
#
#   M1  a scratch repo with four first-parent merges on origin/main: one row
#       per merge, newest first, with the right PR, files, suites and the
#       distinct-suite count of each kind
#   M2  the counts round-trip: each row equals the counts this test computes
#       from `bin/test-impact.sh select <range> --why` of the same range, and
#       the median: / max: lines match the suite counts
#   M3  a select that fails prints an `error` row, the other rows still
#       print, and the tool exits 1
#   M4  --batch runs the select with TI_BATCH_SELECT=1; without it the
#       variable is unset (a fake impact script records its environment)
#   M5  --ranges <file> reads `<base>..<head>` lines in place of the merges
#
# Self-contained: no network, no secrets, no clock read.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

MIX="$DIR/bin/test-impact-mix.sh"
TI="$DIR/bin/test-impact.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "test-impact-mix-8050: git is required"; exit 2; }

# ── the scratch repository: three merges ───────────────────────────────────
R="$T/repo"
mkdir -p "$R/bin" "$R/tests"
printf '#!/bin/bash\necho a\n' > "$R/bin/a.sh"
printf '#!/bin/bash\necho b\n' > "$R/bin/b.sh"
hdr() { printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\n'; }
{ hdr; echo 'bash "$DIR/bin/a.sh"'; } > "$R/tests/a-test.sh"
{ hdr; echo 'bash "$DIR/bin/a.sh"; bash "$DIR/bin/b.sh"'; } > "$R/tests/ab-test.sh"
{ hdr; echo 'grep -c b "$DIR/bin/b.sh"'; } > "$R/tests/b-test.sh"
{ hdr; echo 'git -C "$DIR" ls-files | wc -l'; } > "$R/tests/all-test.sh"
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q -b main; gitc add -A; gitc commit -qm base
merge() { # <pr> <branch> <file> <line>
  gitc checkout -q -b "$2"; echo "$4" >> "$R/$3"; gitc add -A; gitc commit -qm "$2"
  gitc checkout -q main; gitc merge -q --no-ff -m "Merge pull request #$1 from fixture/$2" "$2"
}
merge 101 m1 bin/a.sh 'echo a2'
merge 102 m2 bin/b.sh 'echo b2'
merge 103 m3 tests/a-test.sh 'echo self'
# m4 changes both scripts: ab-test has two `source` rows and counts once.
gitc checkout -q -b m4; echo 'echo a3' >> "$R/bin/a.sh"; echo 'echo b3' >> "$R/bin/b.sh"; gitc add -A; gitc commit -qm m4
gitc checkout -q main; gitc merge -q --no-ff -m "Merge pull request #104 from fixture/m4" m4
gitc update-ref refs/remotes/origin/main main
S1=$(git -C "$R" rev-parse --short=8 HEAD~3); S2=$(git -C "$R" rev-parse --short=8 HEAD~2); S3=$(git -C "$R" rev-parse --short=8 HEAD~1); S4=$(git -C "$R" rev-parse --short=8 HEAD)

# ── M1: one row per merge ───────────────────────────────────────────────────
"$MIX" --last 4 --root "$R" --impact "$TI" > "$T/m1.out" 2> "$T/m1.err"; RC=$?
[ "$RC" = 0 ] && ok || bad "M1: rc 0 expected (rc=$RC: $(cat "$T/m1.err"))"
grep -c '^| #' "$T/m1.out" | grep -qx 4 && ok || bad "M1: four '| #' rows expected ($(cat "$T/m1.out"))"
grep -q '^| pr | sha | files | suites | self | reads | named | source | learned | regression | closure | always | full |$' "$T/m1.out" && ok \
  || bad "M1: the header row names every kind ($(head -2 "$T/m1.out"))"
# Rows: newest first. m1 (bin/a.sh): a, ab by source + all always = 3.
row() { grep "^| #$1 |" "$T/$2.out" | tr -d ' '; }
[ "$(row 101 m1)" = "|#101|$S1|1|3|0|0|0|2|0|0|0|1|0|" ] && ok || bad "M1: #101 row (got '$(row 101 m1)')"
[ "$(row 102 m1)" = "|#102|$S2|1|3|0|1|0|1|0|0|0|1|0|" ] && ok || bad "M1: #102 row (got '$(row 102 m1)')"
[ "$(row 103 m1)" = "|#103|$S3|1|2|1|0|0|0|0|0|0|1|0|" ] && ok || bad "M1: #103 row (got '$(row 103 m1)')"
# m4: a and ab by source (ab twice, counted once), b reads, all always = 4.
[ "$(row 104 m1)" = "|#104|$S4|2|4|0|1|0|2|0|0|0|1|0|" ] && ok || bad "M1: #104 row, distinct suites per kind (got '$(row 104 m1)')"
[ "$(grep -n '^| #' "$T/m1.out" | head -1 | cut -d'|' -f2 | tr -d ' ')" = "#104" ] && ok || bad "M1: the newest merge is the first row"

# ── M2: the counts round-trip against select --why ─────────────────────────
for sha in "$S1" "$S2" "$S3" "$S4"; do
  "$TI" --root "$R" select "$sha^1..$sha" --why > "$T/why" 2>/dev/null
  want=$(awk -F'\t' '{ s[$1] = 1; k[$2 SUBSEP $1] = 1 } END {
      n = 0; for (x in s) n++; printf "%d", n
      split("self reads named source learned regression closure always full", K, " ")
      for (i = 1; i <= 9; i++) { c = 0; for (y in k) { split(y, p, SUBSEP); if (p[1] == K[i]) c++ }; printf "|%d", c } }' "$T/why")
  got=$(grep "| $sha |" "$T/m1.out" | awk -F'|' '{ g = $5; for (i = 6; i <= 14; i++) g = g "|" $i; gsub(/ /, "", g); print g }')
  [ "$got" = "$want" ] && ok || bad "M2: $sha row must equal the --why counts (want $want, got $got)"
done
grep -qx 'median: 3' "$T/m1.out" && grep -qx 'max: 4' "$T/m1.out" && ok || bad "M2: median 3 and max 4 expected ($(grep -E '^(median|max):' "$T/m1.out" | tr '\n' ' '))"

# ── M3 / M4: a fake impact script ──────────────────────────────────────────
cat > "$T/fake.sh" <<'FAKE'
#!/bin/bash
for a in "$@"; do case "$a" in *..*) range="$a" ;; esac; done
printf '%s %s\n' "$range" "${TI_BATCH_SELECT-unset}" >> "$FAKE_LOG"
case "$range" in "$FAKE_FAIL"*) echo "fake: boom" >&2; exit 2 ;; esac
printf 'tests/x-test.sh\tsource\tbin/a.sh\n'
echo 'impact: 1 of 9 suites (selected: 1 changed path(s))' >&2
FAKE
chmod +x "$T/fake.sh"
: > "$T/fake.map"
FAKE_LOG="$T/m3.log" FAKE_FAIL="$S2" "$MIX" --last 3 --root "$R" --impact "$T/fake.sh" --map "$T/fake.map" > "$T/m3.out" 2> "$T/m3.err"; RC=$?
[ "$RC" = 1 ] && ok || bad "M3: a failed select must make the tool exit 1 (rc=$RC)"
grep "^| #102 |" "$T/m3.out" | grep -q '| error |' && ok || bad "M3: #102 must be an error row ($(cat "$T/m3.out"))"
[ "$(grep -c '^| #' "$T/m3.out")" = 3 ] && ok || bad "M3: every merge keeps its row, the error one too"
grep -q 'fake: boom' "$T/m3.err" && ok || bad "M3: the select's stderr is passed on ($(cat "$T/m3.err"))"
grep -q " unset$" "$T/m3.log" && ! grep -q " 1$" "$T/m3.log" && ok || bad "M4: without --batch, TI_BATCH_SELECT is unset ($(cat "$T/m3.log"))"
FAKE_LOG="$T/m4.log" FAKE_FAIL=none "$MIX" --last 2 --batch --root "$R" --impact "$T/fake.sh" --map "$T/fake.map" > "$T/m4.out" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(grep -c ' 1$' "$T/m4.log")" = 2 ] && ok || bad "M4: --batch sets TI_BATCH_SELECT=1 on every select (rc=$RC: $(cat "$T/m4.log"))"

# ── M5: --ranges ────────────────────────────────────────────────────────────
printf '%s^1..%s\n' "$S1" "$S1" > "$T/ranges"
"$MIX" --ranges "$T/ranges" --root "$R" --impact "$TI" > "$T/m5.out" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(grep -c "| $S1 |" "$T/m5.out")" = 1 ] && grep -qx 'median: 3' "$T/m5.out" && ok \
  || bad "M5: one range row for $S1 and median 3 (rc=$RC: $(cat "$T/m5.out"))"

echo "test-impact-mix-8050: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
