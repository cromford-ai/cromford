#!/bin/bash
# tests/list-file-lint.bh-6738-test.sh — BH-6738: bin/list-file-lint.sh refuses
# a PR that appends to a list file in catalog/list-files.tsv without adding its
# entry as a fragment file.
#
# WHAT THIS PINS. Each case builds a scratch git repo: a base commit with the
# shipped catalog and the seed files, branch `base` on it, then one PR commit.
# It runs the REAL bin/list-file-lint.sh as a process from inside that repo with
# `--base base` and asserts the exact rc plus output substrings.
#   L1  index.js +2, no routes/ file              -> rc 1, names file, dir, row, Fix
#   L2  index.js +2 and a new routes/x.js         -> rc 0, the clean line, k=1
#   L3  only bin/other.sh changes                 -> rc 0, no output at all
#   L4  --catalog with a 2-field row and a bad kind -> rc 2, names :3 and :4
#   L5  harness-ci.yml runs the step in the lint job; no new job
#   L6  the shipped catalog: 10 rows, all 3 kinds; a no-match run is rc 0
#   L7  .mergify.yml +3, nothing under config/mergify/ -> rc 1
#   L8  catalog/lanes.json force-added, plus a lanes.d/ file -> rc 1
#   L9  .mergify.yml +40 with template.yml modified -> rc 0
#   L10 .mergify.yml +1/-1 value edit             -> rc 0
#   L11 index.js +2 and its row deleted from the HEAD catalog -> rc 1
#   L12 new cron/lanes/100-x.cron                 -> rc 0, no output
#   L13 --base no-such-ref                        -> rc 2, cannot diff against
#   L14 MERGE-CONDUCTOR.md -5 lines               -> rc 0
#   L15 x/worker/jobs/src/index.js, MERGE-CONDUCTOR.md.bak -> rc 0, no output
#   L16 MERGE-CONDUCTOR.md +4 with a new docs/notes/ file -> rc 0
#
# Run from anywhere: tests/list-file-lint.bh-6738-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LINT="$REPO/bin/list-file-lint.sh"
CAT="$REPO/catalog/list-files.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-14T18:00:00Z' GIT_COMMITTER_DATE='2026-10-14T18:00:00Z'

lines() { local i; for i in $(seq 1 "$1"); do echo "$2 line $i"; done; }

# mk <case> — a repo at $T/<case> with the base commit on branch `base`.
mk() {
  local R="$T/$1"
  mkdir -p "$R" && cd "$R" || return 1
  git init -q -b main .
  mkdir -p catalog worker/jobs/src/routes worker/jobs/schema.d cron/lanes catalog/lanes.d \
    config/mergify/repos docs/notes docs/PR-OWNERSHIP.d bin
  cp "$CAT" catalog/list-files.tsv
  printf 'cron/*.cron\ncatalog/lanes.json\nworker/jobs/schema.sql\n' > .gitignore
  lines 10 route > worker/jobs/src/index.js
  echo 'export default 1' > worker/jobs/src/routes/a.js
  lines 10 rule > .mergify.yml
  lines 5 tpl > config/mergify/template.yml
  lines 10 doc > docs/MERGE-CONDUCTOR.md
  echo 'note' > docs/notes/2026-10-01-BH-1-a.md
  lines 5 own > docs/PR-OWNERSHIP.md
  echo 'intro' > docs/PR-OWNERSHIP.d/00-intro.md
  echo '{}' > catalog/lanes.d/a.json
  echo '0 * * * * a' > cron/lanes/010-a.cron
  echo 'echo hi' > bin/other.sh
  git add -A && git commit -q -m base && git branch base
}
pr() { git add -A && git commit -q -m pr; }
# run [args...] — the real lint from the current repo; sets OUT and RC.
run() { OUT=$("$LINT" "$@" 2>&1); RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

# L1
mk l1; lines 2 extra >> worker/jobs/src/index.js; pr
run --base base
ln=$(grep -n '^worker/jobs/src/index.js' "$CAT" | cut -d: -f1)
if [ "$RC" = 1 ] && has 'worker/jobs/src/index.js grew by 2 line(s)' && has 'worker/jobs/src/routes/' \
   && has "catalog/list-files.tsv:$ln" && has 'Fix: put the new entry in its own file under worker/jobs/src/routes/'; then
  ok "L1 index.js append with no routes file is rc 1 and names file, dir, row, fix"
else bad "L1 rc=$RC out: $OUT"; fi

# L2
mk l2; lines 2 extra >> worker/jobs/src/index.js; echo 'export default 2' > worker/jobs/src/routes/x.js; pr
run --base base
[ "$RC" = 0 ] && has 'list-file-lint: 1 list file(s) changed, all through their fragments.' \
  && ok "L2 the same append with a new routes/x.js is rc 0 with the clean line" || bad "L2 rc=$RC out: $OUT"

# L3
mk l3; echo 'echo bye' >> bin/other.sh; pr
run --base base
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "L3 a PR touching no list file is rc 0 with no output" || bad "L3 rc=$RC out: $OUT"

# L4
mk l4
printf '# header\n\nonly-two\tfields\nx.txt\tbogus x/\tnote\nok.txt\tok/\tfine\n' > "$T/bad.tsv"
run --base base --catalog "$T/bad.tsv"
[ "$RC" = 2 ] && has "$T/bad.tsv:3" && has "$T/bad.tsv:4" && ! has "$T/bad.tsv:5" \
  && ok "L4 malformed rows are rc 2 and name lines 3 and 4 only" || bad "L4 rc=$RC out: $OUT"
for bad_row in "/abs.txt	x/	n" "a.txt	../up/	n" "a.txt	nodir	n" "	x/	n" "a.txt	x/	n	extra"; do
  printf '%s\n' "$bad_row" > "$T/bad1.tsv"
  run --base base --catalog "$T/bad1.tsv"
  [ "$RC" = 2 ] && has "$T/bad1.tsv:1" || bad "L4 row '$bad_row' rc=$RC out: $OUT"
done

# L5
WF="$REPO/.github/workflows/harness-ci.yml"
lintblk=$(awk '/^  lint:/{f=1;print;next} f&&/^  [a-z]/{exit} f' "$WF")
# shellcheck disable=SC2016
want='bin/list-file-lint.sh --base "origin/$BASE_REF"'
jobs_named=$(grep -cE '^  [a-z][a-z0-9_-]*:.*list' "$WF")
if grep -qF "$want" <<<"$lintblk" \
   && grep -qF 'name: list files grow through fragments (BH-6738)' <<<"$lintblk" \
   && [ "$jobs_named" = 0 ]; then
  ok "L5 the lint job runs the step with --base origin/\$BASE_REF; no new job"
else bad "L5 step not in the lint job (jobs naming list: $jobs_named)"; fi

# L6
rows=$(grep -cvE '^(#|[[:space:]]*$)' "$CAT")
nfrag=$(grep -vE '^(#|[[:space:]]*$)' "$CAT" | awk -F'\t' '$2 !~ / /' | wc -l)
nrend=$(grep -vE '^(#|[[:space:]]*$)' "$CAT" | awk -F'\t' '$2 ~ /^rendered /' | wc -l)
nign=$(grep -vE '^(#|[[:space:]]*$)' "$CAT" | awk -F'\t' '$2 ~ /^ignored /' | wc -l)
mk l6; echo 'echo bye' >> bin/other.sh; pr
run --base base --catalog "$CAT"
[ "$rows" = 10 ] && [ "$nfrag" = 5 ] && [ "$nrend" = 2 ] && [ "$nign" = 3 ] && [ "$RC" = 0 ] && [ -z "$OUT" ] \
  && ok "L6 shipped catalog: 10 rows, 5 fragments, 2 rendered, 3 ignored; loads clean" \
  || bad "L6 rows=$rows frag=$nfrag rend=$nrend ign=$nign rc=$RC out: $OUT"

# L7
mk l7; lines 3 extra >> .mergify.yml; pr
run --base base
[ "$RC" = 1 ] && has '.mergify.yml grew by 3 line(s)' && has 'rendered config/mergify/' \
  && has 'Fix: edit the inputs under config/mergify/ and re-render .mergify.yml.' \
  && ok "L7 .mergify.yml +3 with no config/mergify/ edit is rc 1" || bad "L7 rc=$RC out: $OUT"

# L8
mk l8; echo '[]' > catalog/lanes.json; echo '{}' > catalog/lanes.d/x.json
git add -A && git add -f catalog/lanes.json && git commit -q -m pr
run --base base
[ "$RC" = 1 ] && has 'catalog/lanes.json is a git-ignored render' && has 'git rm --cached catalog/lanes.json' \
  && ok "L8 a force-added lanes.json is rc 1 even with a new lanes.d/ file" || bad "L8 rc=$RC out: $OUT"

# L9
mk l9; lines 40 extra >> .mergify.yml; echo 'tpl extra' >> config/mergify/template.yml; pr
run --base base
[ "$RC" = 0 ] && has '1 list file(s) changed' && ok "L9 .mergify.yml +40 with template.yml edited is rc 0" \
  || bad "L9 rc=$RC out: $OUT"

# L10
mk l10; sed -i 's/^rule line 3$/rule line three/' .mergify.yml; pr
run --base base
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "L10 a +1/-1 value edit is not an append" || bad "L10 rc=$RC out: $OUT"

# L11
mk l11; lines 2 extra >> worker/jobs/src/index.js
grep -v '^worker/jobs/src/index.js' catalog/list-files.tsv > c.tmp && mv c.tmp catalog/list-files.tsv; pr
run --base base
[ "$RC" = 1 ] && has 'worker/jobs/src/index.js grew by 2' && has 'base:catalog/list-files.tsv:' \
  && ok "L11 deleting the row in the same PR does not escape it (base union)" || bad "L11 rc=$RC out: $OUT"

# L12
mk l12; echo '0 * * * * x' > cron/lanes/100-x.cron; pr
run --base base
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "L12 cron/*.cron does not match cron/lanes/100-x.cron" || bad "L12 rc=$RC out: $OUT"

# L13
mk l13; echo 'echo bye' >> bin/other.sh; pr
run --base no-such-ref
[ "$RC" = 2 ] && has 'cannot diff against no-such-ref' && ok "L13 an unknown base is rc 2" || bad "L13 rc=$RC out: $OUT"

# L14
mk l14; head -n 5 docs/MERGE-CONDUCTOR.md > d.tmp && mv d.tmp docs/MERGE-CONDUCTOR.md; pr
run --base base
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "L14 a net shrink is not an append" || bad "L14 rc=$RC out: $OUT"

# L15
mk l15; mkdir -p x/worker/jobs/src; lines 3 r > x/worker/jobs/src/index.js
lines 3 b > docs/MERGE-CONDUCTOR.md.bak; pr
run --base base
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "L15 globs anchor to the repo root and the whole name" || bad "L15 rc=$RC out: $OUT"

# L16
mk l16; lines 4 extra >> docs/MERGE-CONDUCTOR.md; echo 'n' > docs/notes/2026-10-14-BH-6738-x.md; pr
run --base base
[ "$RC" = 0 ] && has '1 list file(s) changed' && ok "L16 a MERGE-CONDUCTOR append with a new note is rc 0" \
  || bad "L16 rc=$RC out: $OUT"

# L17: a modified (not added) routes/ file does not satisfy a fragments row,
# and routes-old.js is not under routes/.
mk l17; lines 2 extra >> worker/jobs/src/index.js; echo 'x' >> worker/jobs/src/routes/a.js
echo 'x' > worker/jobs/src/routes-old.js; pr
run --base base
[ "$RC" = 1 ] && has 'worker/jobs/src/index.js grew by 2' \
  && ok "L17 an edited routes/ file or a routes-old.js sibling is not a fragment" || bad "L17 rc=$RC out: $OUT"

# L18: run from a subdirectory; the lint resolves the repo root itself.
mk l18; lines 2 extra >> worker/jobs/src/index.js; pr
cd "$T/l18/docs" || exit 1
run --base base
[ "$RC" = 1 ] && has 'worker/jobs/src/index.js grew by 2' && ok "L18 works from a subdirectory" || bad "L18 rc=$RC out: $OUT"

# L19: an unknown flag is rc 2 with usage.
run --bogus
[ "$RC" = 2 ] && has 'usage:' && ok "L19 an unknown flag is rc 2 with usage" || bad "L19 rc=$RC out: $OUT"

echo
echo "list-file-lint.bh-6738: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
