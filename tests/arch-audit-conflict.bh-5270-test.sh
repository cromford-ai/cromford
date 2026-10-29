#!/bin/bash
# tests/arch-audit-conflict.bh-5270-test.sh — BH-5270 (BH-5248.4): the
# architecture audit's conflict section.
#
# Driven, not grepped: every case from A1 to A8 runs the shipped
# bin/arch-conflict-scan.sh through its CLI against a fixture git repo built
# here, and asserts on its TSV rows, its markdown and its rc. A9 pins the brief,
# the template and the ticket body, and renders the template through
# bin/verification-map.sh the way a planner's primer is built.
#
# The ticket's own acceptance line is A2 and A1: a repo with a 2,000-line
# script, a schema file grown by 30 appended tables and a hand-kept route list
# yields three proposals of the right types; a repo with none of those yields an
# empty section, not an invented one.
#
# The clock: NOW is read ONCE below and every commit date is derived from it.
# The scan itself reads no clock.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/arch-audit-conflict.bh-5270-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$DIR/bin/arch-conflict-scan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

NOW=$(date +%s)
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"

# at <step> <git args...>: run git in $R with both dates pinned, <step> hours
# after a fixed point 400 days before NOW, so commit order is date order.
at() {
  local s=$1; shift
  GIT_AUTHOR_DATE="@$((NOW - 400*86400 + s*3600)) +0000" GIT_COMMITTER_DATE="@$((NOW - 400*86400 + s*3600)) +0000" \
    git -C "$R" "$@" >/dev/null 2>&1
}
newrepo() {
  R=$1
  git init -q -b main "$R"
  git -C "$R" config user.name fixture
  git -C "$R" config user.email fixture@example.invalid
  git -C "$R" config commit.gpgsign false
  STEP=0
}
# commit_all <msg>: add everything and commit at the next step.
commit_all() { STEP=$((STEP+1)); at "$STEP" add -A; at "$STEP" commit -q -m "$1"; }
lines() { awk -v n="$1" -v w="$2" 'BEGIN { for (i = 1; i <= n; i++) print w " " i }'; }

run() { OUT=$("$CLI" "$@" 2>"$T/err"); RC=$?; }
# data rows of a --tsv run: not the header, not a # footer
tsv_rows() { awk 'NR > 1 && !/^#/' <<<"$1"; }
# The regex goes in through ENVIRON, not `awk -v`: gawk processes escapes in a
# -v value, so "^\| " arrived as "^| " (match every line) on gawk, while mawk
# kept the backslash (the prompt-conflict-discipline.bh-5269 lesson).
count() { RE="$1" awk '$0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }' <<<"$2"; }

# --- A1: a clean repo yields an empty section -------------------------------
newrepo "$T/clean"
printf 'a\n' > "$R/a.txt"; printf 'b\n' > "$R/b.md"; mkdir -p "$R/src"; printf 'x\n' > "$R/src/c.js"
printf 'v0\nkeep\n' > "$R/src/conf.ini"
commit_all init
for i in $(seq 1 12); do printf 'v%s\nkeep\n' "$i" > "$R/src/conf.ini"; commit_all "edit $i"; done
printf 'b2\n' >> "$R/b.md"; commit_all "b"
run -C "$T/clean"
check "A1 clean repo: rc 0 (got $RC)" '[ "$RC" = 0 ]'
check "A1 exactly one '## Conflict shape' heading" '[ "$(count "^## Conflict shape$" "$OUT")" = 1 ]'
check "A1 says there are no findings" 'grep -qxF "No conflict-shape findings at this ref." <<<"$OUT"'
check "A1 no table rows" '[ "$(count "^\\| " "$OUT")" = 0 ]'
check "A1 no proposal blocks" '[ "$(count "^#### " "$OUT")" = 0 ]'
check "A1 no Proposed tickets heading" '! grep -q "Proposed tickets" <<<"$OUT"'
check "A1 the Scanned line counts 4 tracked text files" 'grep -q "^Scanned \`[0-9a-f]\{12\}\` of clean: 4 tracked text files\." <<<"$OUT"'
run -C "$T/clean" --tsv
check "A1 --tsv: rc 0 and the header only" '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "path\tkind\tfix\tconflicts\trebases\tevidence")" ]'

# --- A2: the ticket fixture -------------------------------------------------
newrepo "$T/a2"
mkdir -p "$R/bin" "$R/db" "$R/src/routes" "$R/lib"
echo 'module.exports = 0;' > "$R/lib/x.js"
lines 2000 'echo line' > "$R/bin/big.sh"
printf -- '-- schema\n' > "$R/db/schema.sql"
printf 'readme\n' > "$R/README.md"
commit_all init
for i in $(seq 1 30); do
  printf 'CREATE TABLE t%s (id int);\n' "$i" >> "$R/db/schema.sql"; commit_all "table t$i"
done
for i in $(seq 1 12); do
  printf 'module.exports = %s;\n' "$i" > "$R/src/routes/r$i.js"
  printf 'src/routes/r%s.js\n' "$i" >> "$R/src/routes.txt"; commit_all "route r$i"
done
A2HEAD=$(git -C "$R" rev-parse HEAD)

run -C "$T/a2" --tsv
TSV2=$OUT
check "A2 --tsv rc 0 (got $RC)" '[ "$RC" = 0 ]'
check "A2 exactly three findings" '[ "$(tsv_rows "$TSV2" | wc -l)" = 3 ]'
check "A2 bin/big.sh is a giant file -> module-map" 'tsv_rows "$TSV2" | cut -f1-3 | grep -qxF "$(printf "bin/big.sh\tgiant-file\tmodule-map")"'
check "A2 db/schema.sql is an append registry -> fragments" 'tsv_rows "$TSV2" | cut -f1-3 | grep -qxF "$(printf "db/schema.sql\tappend-registry\tfragments")"'
check "A2 src/routes.txt is a derived index -> generation" 'tsv_rows "$TSV2" | cut -f1-3 | grep -qxF "$(printf "src/routes.txt\tderived-index\tgeneration")"'
check "A2 no route module is a finding" '! tsv_rows "$TSV2" | grep -q "^src/routes/r"'
check "A2 the schema evidence counts its 31 appends" 'tsv_rows "$TSV2" | grep "^db/schema.sql" | grep -q "31 of 31 commits only appended"'

run -C "$T/a2"
MD2=$OUT
check "A2 markdown rc 0" '[ "$RC" = 0 ]'
check "A2 three '#### ' proposal blocks" '[ "$(count "^#### " "$MD2")" = 3 ]'
check "A2 three table rows plus the header row" '[ "$(count "^\\| " "$MD2")" = 4 ]'
check "A2 Hotspots: not supplied" 'grep -q "Hotspots: not supplied\." <<<"$MD2"'
check "A2 the proposals say they file nothing" 'grep -q "This scan files nothing and changes nothing\." <<<"$MD2"'
# each #### block: a Type line matching its row's fix, then a non-empty scope draft
PAIRS=$(awk '/^#### /{ t=$0; getline ty; getline sd; sub(/^Type: /, "", ty); ok = (sd ~ /^Scope draft: ./); print t "\t" ty "\t" ok }' <<<"$MD2")
check "A2 big.sh proposal is Type: module-map with a scope draft" 'grep -qP "^#### \d+\. Split \`bin/big.sh\` into modules with a generated module map\tmodule-map\t1$" <<<"$PAIRS"'
check "A2 schema proposal is Type: fragments with a scope draft" 'grep -qP "^#### \d+\. Split \`db/schema.sql\` into fragments\tfragments\t1$" <<<"$PAIRS"'
check "A2 routes proposal is Type: generation with a scope draft" 'grep -qP "^#### \d+\. Generate \`src/routes.txt\` from the files it lists\tgeneration\t1$" <<<"$PAIRS"'
check "A2 the fragments draft names the fragment dir" 'grep -q "^Scope draft: .*under \`db/schema.d/\`" <<<"$MD2"'
check "A2 scope drafts carry no em dash" '! grep "^Scope draft:" <<<"$MD2" | grep -q "—"'

# --- A3: generated but committed --------------------------------------------
newrepo "$T/a3"
mkdir -p "$R/gen" "$R/out" "$R/rules" "$R/tmp"
{ echo '// @generated by tool'; lines 20 'x'; } > "$R/gen/a.js"
echo '{"a":1}' > "$R/out/map.json"
{ echo '<!-- do not edit: rendered -->'; lines 1500 'rule'; } > "$R/rules/out.md"
cat > "$R/AGENT_ARCHITECTURE.md" <<'EOF'
# Agent architecture

## Generated files

| path | command | kept |
|---|---|---|
| `out/map.json` | `bin/gen-map.sh` | |
| `rules/out.md` | `bin/render.sh` | committed |
EOF
commit_all init
echo '// @generated by tool' > "$R/tmp/untracked.js"
run -C "$T/a3" --tsv
TSV3=$OUT
check "A3 rc 0 (got $RC)" '[ "$RC" = 0 ]'
check "A3 exactly two findings" '[ "$(tsv_rows "$TSV3" | wc -l)" = 2 ]'
check "A3a header-marked file -> generated-committed generation" 'tsv_rows "$TSV3" | cut -f1-3 | grep -qxF "$(printf "gen/a.js\tgenerated-committed\tgeneration")"'
check "A3a evidence quotes the marker" 'tsv_rows "$TSV3" | grep "^gen/a.js" | grep -q "@generated"'
check "A3b declared file -> generated-committed generation" 'tsv_rows "$TSV3" | cut -f1-3 | grep -qxF "$(printf "out/map.json\tgenerated-committed\tgeneration")"'
check "A3b evidence says declared" 'tsv_rows "$TSV3" | grep "^out/map.json" | grep -q "declared"'
check "A3c a row marked committed is no finding at all (not even giant)" '! tsv_rows "$TSV3" | grep -q "^rules/out.md"'
check "A3d an untracked marked file is no finding" '! tsv_rows "$TSV3" | grep -q "untracked"'
run -C "$T/a3"
check "A3 markdown proposes 'Stop committing generated'" '[ "$(count "^#### [0-9]+\\. Stop committing generated" "$OUT")" = 2 ]'

# --- A4: hotspots drive order and cells -------------------------------------
printf 'path\tconflicts\trebases\tprs\nsrc/routes.txt\t9\t11\t#1,#2\ndb/schema.sql\t4\t30\t#3\nlib/x.js\t7\t7\t#4\ngone.txt\t2\t2\t#5\n# ref=abc since=x until=y days=30 pr_merges=5\n' > "$T/hs.tsv"
printf 'prs\tpath\trebases\tconflicts\n#1\tsrc/routes.txt\t11\t9\n#3\tdb/schema.sql\t30\t4\n#4\tlib/x.js\t7\t7\n#5\tgone.txt\t2\t2\n' > "$T/hs-reordered.tsv"
run -C "$T/a2" --hotspots "$T/hs.tsv"
MD4=$OUT
check "A4 rc 0 (got $RC)" '[ "$RC" = 0 ]'
ROWS4=$(awk '/^## Conflict shape/{s=1} /^### /{s=0} s && /^\| `/' <<<"$MD4")
check "A4 table order routes, schema, big" '[ "$(cut -d"|" -f2 <<<"$ROWS4" | tr -d " \`" | paste -sd,)" = "src/routes.txt,db/schema.sql,bin/big.sh" ]'
check "A4 routes row carries 9 conflicts, 11 rebases" 'grep -q "^| \`src/routes.txt\` | derived-index | .* | 9 | 11 | generation |$" <<<"$ROWS4"'
check "A4 schema row carries 4 / 30" 'grep -q "^| \`db/schema.sql\` | append-registry | .* | 4 | 30 | fragments |$" <<<"$ROWS4"'
check "A4 big row reads — for both cells" 'grep -q "^| \`bin/big.sh\` | giant-file | .* | — | — | module-map |$" <<<"$ROWS4"'
check "A4 Hotspots line names the file and its rows" 'grep -q "Hotspots: hs.tsv (4 rows)\." <<<"$MD4"'
UNEXP=$(awk '/^### Measured hotspots with no structural finding/{s=1; next} /^#/{s=0} s' <<<"$MD4")
check "A4 lib/x.js listed under unexplained hotspots" 'grep -q "^| \`lib/x.js\` | 7 | 7 |$" <<<"$UNEXP"'
check "A4 a hotspot deleted at REF says so" 'grep -q "^| \`gone.txt\` (not at this ref) | 2 | 2 |$" <<<"$UNEXP"'
check "A4 lib/x.js is never a proposal or a finding row" '! grep -q "^####.*lib/x.js" <<<"$MD4" && ! grep -q "lib/x.js" <<<"$ROWS4"'
check "A4 still exactly three proposals" '[ "$(count "^#### " "$MD4")" = 3 ]'
check "A4 the fragments draft cites the measured conflicts" 'grep -q "^Scope draft: \`db/schema.sql\` grew by 31 pure appends out of 31 commits, and caused 4 merge conflicts in the hotspot window\." <<<"$MD4"'
run -C "$T/a2" --hotspots "$T/hs-reordered.tsv"
check "A4 a header-keyed TSV with columns reordered gives the same section" '[ "$RC" = 0 ] && [ "$(sed "s/hs-reordered.tsv/hs.tsv/" <<<"$OUT")" = "$MD4" ]'
# hotspots reorder findings: schema ahead of routes when it conflicts more
printf 'path\tconflicts\trebases\nsrc/routes.txt\t4\t1\ndb/schema.sql\t9\t1\n' > "$T/hs-flip.tsv"
run -C "$T/a2" --hotspots "$T/hs-flip.tsv" --tsv
check "A4 more conflicts sorts first (schema, routes, big)" '[ "$(tsv_rows "$OUT" | cut -f1 | paste -sd,)" = "db/schema.sql,src/routes.txt,bin/big.sh" ]'
# a duplicate row: the higher conflicts count wins
printf 'path\tconflicts\trebases\ndb/schema.sql\t2\t1\ndb/schema.sql\t6\t1\n' > "$T/hs-dup.tsv"
run -C "$T/a2" --hotspots "$T/hs-dup.tsv" --tsv
check "A4 duplicate hotspot path: the higher conflicts row wins" '[ "$(tsv_rows "$OUT" | awk -F"\t" "\$1==\"db/schema.sql\"{print \$4}")" = 6 ]'

# --- A5: adversarial negatives ----------------------------------------------
newrepo "$T/a5"
mkdir -p "$R/db" "$R/vendor"
lines 999 'l' > "$R/f999.txt"
for n in users orders items carts notes; do echo "$n" > "$R/$n"; done
lines 3000 '"dep":' > "$R/package-lock.json"
{ printf '\000'; head -c 1048575 /dev/zero | tr '\0' '\n'; } > "$R/blob.bin"
lines 2000 'v' > "$R/vendor/a.js"
echo 'n0' > "$R/nine.txt"
echo 'm0' > "$R/mixed.txt"
printf -- '-- users schema\n' > "$R/db/users.sql"
commit_all init
for i in $(seq 1 8); do echo "n$i" >> "$R/nine.txt"; commit_all "nine $i"; done
for i in $(seq 1 9); do echo "m$i" >> "$R/mixed.txt"; commit_all "mixed $i"; done
for i in $(seq 1 5); do sed -i "1s/.*/edited $i/" "$R/mixed.txt"; commit_all "mixed edit $i"; done
set -- users orders items carts notes
for i in $(seq 1 12); do
  n=$(( (i - 1) % 5 + 1 )); eval "tbl=\${$n}"
  printf 'CREATE TABLE %s (id int);\n' "$tbl" >> "$R/db/users.sql"; commit_all "users $i"
done
set --
fix5=1
[ "$(git -C "$R" log --format=%H -- nine.txt | wc -l)" = 9 ] || fix5=0
[ "$(git -C "$R" log --format=%H -- mixed.txt | wc -l)" = 15 ] || fix5=0
# "$T/a5", not "$R" (the same tree): newrepo binds R from a positional, and a
# positional `git -C` ls-files reads as the whole checkout to bin/test-impact.sh.
[ "$(git -C "$T/a5" ls-files | wc -l)" = 12 ] || fix5=0
check "A5 fixture built as designed" '[ "$fix5" = 1 ]'
run -C "$T/a5" --exclude 'vendor/*' --tsv
check "A5 rc 0 (got $RC)" '[ "$RC" = 0 ]'
check "A5 exactly one finding: db/users.sql append-registry fragments" '[ "$(tsv_rows "$OUT" | cut -f1-3)" = "$(printf "db/users.sql\tappend-registry\tfragments")" ]'
run -C "$T/a5" --tsv
check "A5 without --exclude the vendored giant is a finding (the flag is what dropped it)" 'tsv_rows "$OUT" | cut -f1-2 | grep -qxF "$(printf "vendor/a.js\tgiant-file")"'
check "A5 the binary and the lockfile are never findings" '! tsv_rows "$OUT" | grep -qE "^(blob.bin|package-lock.json)\s"'

# --- A5c: a header marker is a comment in the file's syntax, never prose or data
# (lead review of 41d7a343: on cromford itself 8 of 9 generated-committed
# rows were rules/topics/00-intro.md's "Do not edit it here." and Mergify
# payloads carrying DO NOT EDIT inside JSON or an HTML comment's body).
newrepo "$T/a5c"
mkdir -p "$R/rules/topics" "$R/fixtures" "$R/gen" "$R/bin"
printf '# CLAUDE.md — Harness\n\n> **This file is REPO-MANAGED. Do not edit it here.** It is rendered.\n' > "$R/rules/topics/00-intro.md"
printf '{"body":"<!---\\nDO NOT EDIT\\n-*- Mergify Payload -*-\\n{}"}\n' > "$R/fixtures/payload.json"
printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n-->\n' > "$R/fixtures/payload.md"
printf '#!/bin/bash\necho "do not edit this file by hand"\n' > "$R/bin/tool.sh"
printf '# Notes\n\nDo not edit the generated table below.\n' > "$R/NOTES.md"
printf '# Code generated by gen-tool. DO NOT EDIT.\nx = 1\n' > "$R/gen/b.py"
commit_all init
run -C "$T/a5c" --tsv
check "A5c rc 0 (got $RC)" '[ "$RC" = 0 ]'
check "A5c the one real header (a comment, Go style) is generated-committed" '[ "$(tsv_rows "$OUT" | cut -f1-2)" = "$(printf "gen/b.py\tgenerated-committed")" ]'
for f in rules/topics/00-intro.md fixtures/payload.json fixtures/payload.md bin/tool.sh NOTES.md; do
  check "A5c $f (prose or string data) is not generated-committed" '! tsv_rows "$OUT" | grep -q "^$f	"'
done

# --- A5b: a shallow clone never invents appends ------------------------------
# Every branch is cut from an OLD base and merged late, so cloning with
# --shallow-since makes each branch commit a boundary: a root that "adds" the
# whole tree. Counted, keep.txt would read as 14 pure appends out of 14.
newrepo "$T/deep"
echo keep > "$R/keep.txt"; commit_all base; BASE=$(git -C "$R" rev-parse HEAD)
STEP=100
for i in $(seq 1 14); do
  at "$STEP" checkout -q -b "b$i" "$BASE"; echo "f$i" > "$R/f$i.txt"; commit_all "b$i"
  at "$STEP" checkout -q main; STEP=$((STEP+1)); at "$STEP" merge -q --no-ff "b$i" -m "Merge b$i"
done
git clone -q --shallow-since="@$((NOW - 400*86400 + 50*3600))" "file://$T/deep" "$T/shallow" >/dev/null 2>&1
NB=$(wc -l < "$(git -C "$T/shallow" rev-parse --path-format=absolute --git-path shallow)" 2>/dev/null || echo 0)
check "A5b fixture: the clone is shallow with >= 10 boundary commits (got $NB)" '[ "${NB:-0}" -ge 10 ]'
run -C "$T/shallow" --tsv
check "A5b no finding from boundary roots (keep.txt is not an append registry)" '[ "$RC" = 0 ] && [ "$(tsv_rows "$OUT" | wc -l)" = 0 ]'
run -C "$T/shallow"
check "A5b the Scanned line says the history is shallow" 'grep -q "History: shallow, append counts are a lower bound\." <<<"$OUT"'
run -C "$T/deep"
check "A5b the full repo carries no shallow note" '[ "$RC" = 0 ] && ! grep -q "History: shallow" <<<"$OUT"'

# --- A6: thresholds are flags -----------------------------------------------
run -C "$T/a2" --giant-lines 2001 --tsv
check "A6 --giant-lines 2001 drops bin/big.sh" '[ "$RC" = 0 ] && ! tsv_rows "$OUT" | grep -q "^bin/big.sh" && [ "$(tsv_rows "$OUT" | wc -l)" = 2 ]'
run -C "$T/a2" --giant-lines 12 --tsv
check "A6 rule order: an appended file that is also giant keeps its append kind" '[ "$(tsv_rows "$OUT" | cut -f1-2 | sort | paste -sd,)" = "$(printf "bin/big.sh\tgiant-file,db/schema.sql\tappend-registry,src/routes.txt\tderived-index")" ]'
run -C "$T/a2" --min-appends 32 --tsv
check "A6 --min-appends 32 drops the schema" '[ "$RC" = 0 ] && ! tsv_rows "$OUT" | grep -q "^db/schema.sql"'
run -C "$T/a2" --giant-lines 2001 --min-appends 32 --append-pct 90 --min-refs 7
check "A6 the Scanned line prints the values used" 'grep -q "Thresholds: giant file >= 2001 lines; append registry >= 32 pure-append commits making >= 90% of its commits; derived index names >= 7 tracked files\." <<<"$OUT"'
run -C "$T/a2" --min-refs 13 --tsv
check "A6 --min-refs 13 turns the route list into an append registry" 'tsv_rows "$OUT" | cut -f1-3 | grep -qxF "$(printf "src/routes.txt\tappend-registry\tfragments")"'
run -C "$T/a2" --top 1
check "A6 --top 1 prints one row" '[ "$RC" = 0 ] && [ "$(count "^\\| \`" "$OUT")" = 1 ] && [ "$(count "^#### " "$OUT")" = 1 ]'
check "A6 --top 1 says what it cut" 'grep -qxF "2 more findings not shown (re-run with --top 3)." <<<"$OUT"'
run -C "$T/a2" --top 0;            check "A6 --top 0 -> rc 2 (got $RC)" '[ "$RC" = 2 ]'
run -C "$T/a2" --giant-lines x;    check "A6 --giant-lines x -> rc 2 (got $RC)" '[ "$RC" = 2 ]'
run -C "$T/a2" --append-pct 101;   check "A6 --append-pct 101 -> rc 2 (got $RC)" '[ "$RC" = 2 ]'
run -C "$T/a2" --bogus;            check "A6 unknown flag -> rc 2 (got $RC)" '[ "$RC" = 2 ]'
mkdir -p "$T/notgit"
run -C "$T/notgit";                check "A6 not a git dir -> rc 1 (got $RC)" '[ "$RC" = 1 ]'
run -C "$T/a2" --ref no-such-ref;  check "A6 unresolvable ref -> rc 1 (got $RC)" '[ "$RC" = 1 ]'
printf 'file\tconflicts\nx\t1\n' > "$T/hs-nopath.tsv"
run -C "$T/a2" --hotspots "$T/hs-nopath.tsv"; check "A6 --hotspots without a path column -> rc 2 (got $RC)" '[ "$RC" = 2 ]'
run -C "$T/a2" --hotspots "$T/no-such.tsv";   check "A6 unreadable --hotspots -> rc 2 (got $RC)" '[ "$RC" = 2 ]'
printf 'path\tconflicts\nx\tmany\n' > "$T/hs-bad.tsv"
run -C "$T/a2" --hotspots "$T/hs-bad.tsv";    check "A6 non-integer conflicts cell -> rc 2 (got $RC)" '[ "$RC" = 2 ]'

# --- A7: never files, never applies ------------------------------------------
mkdir -p "$T/stub"
for s in gh curl; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$s" "$T" > "$T/stub/$s"; chmod +x "$T/stub/$s"; done
: > "$T/calls.log"
BEFORE=$(find "$T/a2" | sort; git -C "$T/a2" rev-parse HEAD)
OUT=$(PATH="$T/stub:$PATH" "$CLI" -C "$T/a2" --hotspots "$T/hs.tsv" 2>&1); RC=$?
AFTER=$(find "$T/a2" | sort; git -C "$T/a2" rev-parse HEAD)
check "A7 rc 0 under the stubs (got $RC)" '[ "$RC" = 0 ]'
check "A7 no gh or curl call" '[ ! -s "$T/calls.log" ]'
check "A7 nothing new under the repo dir, HEAD unchanged" '[ "$BEFORE" = "$AFTER" ] && [ "$(git -C "$T/a2" rev-parse HEAD)" = "$A2HEAD" ]'
check "A7 the working tree is clean" '[ -z "$(git -C "$T/a2" status --porcelain)" ]'
check "A7 the stubs were reachable (PATH really carried them)" '[ "$(PATH="$T/stub:$PATH" command -v gh)" = "$T/stub/gh" ]'

# --- A8: the output never opens a regenerate table ---------------------------
newrepo "$T/a8"
printf '# Agent architecture\n\n## Generated files\n\n| path | command |\n|---|---|\n| `docs/index.md` | `bin/gen-index.sh` |\n\n' > "$R/AGENT_ARCHITECTURE.md"
printf '%s\n' "$MD4" >> "$R/AGENT_ARCHITECTURE.md"
commit_all contract
# shellcheck source=/dev/null
. "$DIR/bin/lib/generated-table.sh" || exit 1
check "A8 the contract's generated table still declares exactly one path" '[ "$(gen_table_paths "$T/a8" HEAD)" = "docs/index.md" ]'
check "A8 no output heading names generated files" '! grep -iE "^#+ .*generated files" <<<"$MD4$MD2"'
run -C "$T/a3"
check "A8 not even the generated-committed proposals' headings" '! grep -iqE "^#+ .*generated files" <<<"$OUT"'

# --- A9: the brief, the template and the ticket carry the section ------------
python3 - "$DIR/prompts/arch-audit.md" "$DIR/docs/AGENT-ARCHITECTURE-TEMPLATE.md" "$DIR/docs/ARCH-AUDIT-TICKET.md" <<'PY'
import re, sys
brief, tpl, ticket = (open(p).read() for p in sys.argv[1:4])
fails = []
def section(text, start, stop_re=r'^## '):
    m = re.search(r'^' + re.escape(start) + r'.*$', text, re.M)
    if not m:
        return None
    rest = text[m.end():]
    n = re.search(stop_re, rest, re.M)
    return rest[: n.start()] if n else rest
req = section(brief, '## Required output')
if req is None:
    fails.append('brief: no ## Required output section')
else:
    for s in ('bin/arch-conflict-scan.sh', '## Conflict shape', 'Proposed tickets'):
        if s not in req:
            fails.append('brief Required output lacks %r' % s)
    # one sentence carries both refusals: "never files these tickets and never applies them"
    if not re.search(r'never\s+files[^.]*never\s+appl', req):
        fails.append('brief Required output has no never-files-never-applies sentence')
    if not re.search(r'week', req):
        fails.append('brief Required output does not say re-run after a week')
disc = section(brief, '## Discovery')
if disc is None or not re.search(r'^6\. \*\*Which files collide', disc, re.M) or 'bin/conflict-hotspots.sh' not in disc:
    fails.append('brief discovery has no question 6 naming bin/conflict-hotspots.sh')
hard = section(brief, '## Hard rules')
if hard is None or "conflict section's proposals" not in hard:
    fails.append('brief hard rules do not extend "do not restructure" to the proposals')
heads = re.findall(r'^#{1,6} +.*$', tpl, re.M)
try:
    cs = heads.index('## Conflict shape'); ch = heads.index('## Changing this contract')
    if cs > ch:
        fails.append('template: Conflict shape is not before Changing this contract')
except ValueError:
    fails.append('template: Conflict shape or Changing this contract heading missing')
if len([h for h in heads if re.match(r'^#{1,6} +Rule [1-5] ', h)]) != 5:
    fails.append('template: not exactly five Rule headings')
if any(re.search('generated files', h, re.I) for h in heads):
    fails.append('template: a heading names generated files')
cs_body = section(tpl, '## Conflict shape')
if cs_body is None or 'bin/arch-conflict-scan.sh' not in cs_body or '<CONFLICT_SHAPE_OUTPUT>' not in cs_body:
    fails.append('template Conflict shape section lacks the scan or its placeholder')
lo = ticket.lower()
oos = ticket[lo.find('## out of scope'):] if '## out of scope' in lo else ''
if not re.search(r'filing or applying the proposed', oos, re.I):
    fails.append('ticket Out of scope does not name filing or applying the proposed tickets')
body = ticket[ticket.find('\n---\n'):lo.find('## out of scope')]
if 'bin/arch-conflict-scan.sh' not in body or '## Conflict shape' not in body:
    fails.append('ticket Deliverable does not name the conflict section')
for f in fails:
    print('FAIL: A9 ' + f)
sys.exit(1 if fails else 0)
PY
[ $? = 0 ] && ok || FAIL=$((FAIL+1))

# render: the template as a repo's contract still lists Rule 1 and Conflict shape
H="$T/h"; mkdir -p "$H/state"
cp -R "$DIR/catalog/fixtures/verification-map/full" "$T/vmrepo"
cp "$DIR/docs/AGENT-ARCHITECTURE-TEMPLATE.md" "$T/vmrepo/AGENT_ARCHITECTURE.md"
HARNESS="$H" "$DIR/bin/verification-map.sh" render arch-os --repo "$T/vmrepo" >/dev/null 2>&1
P=$(cat "$H/state/arch-os-context.md" 2>/dev/null)
check "A9 the primer lists Rule 1 from the template" 'grep -qE "Rule 1 " <<<"$P"'
check "A9 the primer lists the Conflict shape section (inside head -20)" 'grep -q "Conflict shape" <<<"$P"'

echo "arch-audit-conflict: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
