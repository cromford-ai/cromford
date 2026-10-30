#!/bin/bash
# tests/retention-lint.bh-8398-test.sh — catalog/list-files.tsv lists
# worker/jobs/src/routes/retention.js with input retention.d/, so
# bin/list-file-lint.sh refuses a PR that grows retention.js without adding a
# rule fragment file (BH-8398.2).
#   L1  the real catalog has exactly one retention.js row, input
#       worker/jobs/src/routes/retention.d/
#   L2  a rule appended in-file before `];` is red (rc 1); the output names
#       retention.js and retention.d/
#   L3  a new retention.d/ fragment alone is green; L3b retention.js growth
#       plus a new fragment is green
#   L4  an in-place value edit of retention.js (+1/-1) is green. Since BH-8407
#       moved every rule into retention.d/, the edited value is the first rule
#       `def:` if retention.js still has one, else the retention.batch default
#   L5  growth of x/worker/jobs/src/routes/retention.js is green (the glob is
#       repo-root anchored)
# The fixture repo copies the real catalog, lint and retention files and runs
# the lint with no --catalog, so it reads the catalog at HEAD and at base as in
# production. Fixed commit dates, no network. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/retention-lint.bh-8398-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RJS=worker/jobs/src/routes/retention.js
RD=worker/jobs/src/routes/retention.d/

# ── L1 the catalog row ────────────────────────────────────────────────────────
ROWS=$(awk -F'\t' -v p="$RJS" '/^#/ || NF == 0 { next } $1 == p { print $2 }' "$DIR/catalog/list-files.tsv")
[ "$(printf '%s' "$ROWS" | grep -c '')" = 1 ] && ok || bad "L1 want exactly one $RJS row, got: [$ROWS]"
[ "$ROWS" = "$RD" ] && ok || bad "L1 the $RJS row input is [$ROWS], want $RD"

# ── fixture repo ──────────────────────────────────────────────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
L="$T/lint"
mkdir -p "$L/catalog" "$L/bin" "$L/$RD" "$L/x/worker/jobs/src/routes"
cp "$DIR/catalog/list-files.tsv" "$L/catalog/list-files.tsv"
cp "$DIR/bin/list-file-lint.sh" "$L/bin/list-file-lint.sh"
cp "$DIR/$RJS" "$L/$RJS"
cp "$DIR/$RD/bh-7598-web-task-human-step.js" "$L/$RD/"
cp "$DIR/$RJS" "$L/x/$RJS"
git init -q -b base "$L"; git -C "$L" add -A; git -C "$L" commit -qm base

# case_run <name> <setup> — run <setup> on a new branch off base, commit, lint.
# Sets RC and OUT.
case_run() {
  local name=$1 setup=$2
  git -C "$L" checkout -q -f base
  git -C "$L" checkout -q -b "$name"
  ( cd "$L" && eval "$setup" )
  git -C "$L" add -A; git -C "$L" commit -qm "$name"
  OUT=$(cd "$L" && bash bin/list-file-lint.sh --base base 2>&1); RC=$?
}
# numstat <branch> <path> — "<added> <deleted>" of <path> in base..<branch>.
numstat() { git -C "$L" diff --numstat base "$1" -- "$2" | awk '{print $1, $2}'; }
# rule_in <file> — insert a 3-line rule object before the first `];` line, or
# at the end of the file when there is none.
rule_in() {
  awk '!d && $0 == "];" { print "  {"; print "    rule: \"fixture.l2\", table: \"x\", key: \"x_retention_days\", def: 30,"; print "  },"; d=1 }
       { print } END { if (!d) { print "// fixture.l2 a"; print "// fixture.l2 b"; print "// fixture.l2 c" } }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# value_edit <file> — change ONE number in place (+1/-1): the first rule
# `def: N`, else (no rule left in the file, BH-8407) the retention.batch
# default in `intSetting(byKey, "retention.batch", N, ...)`.
value_edit() {
  awk '!d && /def: [0-9]+/ { sub(/def: [0-9]+/, "def: 9999"); d=1 }
       !d && /"retention\.batch", [0-9]+/ { sub(/"retention\.batch", [0-9]+/, "\"retention.batch\", 9999"); d=1 }
       { print }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# ── L2 in-file append is red ──────────────────────────────────────────────────
case_run l2 "rule_in $RJS"
read -r A D <<<"$(numstat l2 "$RJS")"
[ "${A:-0}" -gt "${D:-0}" ] && ok || bad "L2 the setup must grow $RJS: numstat [${A:-} ${D:-}]"
[ "$RC" = 1 ] && ok || bad "L2 in-file rule append: rc $RC, want 1: $OUT"
case "$OUT" in *"$RJS"*) ok ;; *) bad "L2 output does not name $RJS: $OUT" ;; esac
case "$OUT" in *"$RD"*) ok ;; *) bad "L2 output does not name $RD: $OUT" ;; esac

# ── L3 a fragment is green ────────────────────────────────────────────────────
case_run l3 "echo 'export default [];' >${RD}bh-90001-fixture-a.js"
[ "$RC" = 0 ] && ok || bad "L3 fragment only: rc $RC, want 0: $OUT"

case_run l3b "rule_in $RJS; echo 'export default [];' >${RD}bh-90002-fixture-b.js"
read -r A D <<<"$(numstat l3b "$RJS")"
[ "${A:-0}" -gt "${D:-0}" ] && ok || bad "L3b the setup must grow $RJS: numstat [${A:-} ${D:-}]"
[ "$RC" = 0 ] && ok || bad "L3b growth plus a fragment: rc $RC, want 0: $OUT"

# ── L4 a value edit is green ──────────────────────────────────────────────────
case_run l4 "value_edit $RJS"
[ "$(numstat l4 "$RJS")" = "1 1" ] && ok || bad "L4 the setup must be a +1/-1 edit: numstat [$(numstat l4 "$RJS")]"
[ "$RC" = 0 ] && ok || bad "L4 value edit: rc $RC, want 0: $OUT"

# ── L5 a same-named file elsewhere is green ───────────────────────────────────
case_run l5 "rule_in x/$RJS"
read -r A D <<<"$(numstat l5 "x/$RJS")"
[ "${A:-0}" -gt "${D:-0}" ] && ok || bad "L5 the setup must grow x/$RJS: numstat [${A:-} ${D:-}]"
[ "$RC" = 0 ] && ok || bad "L5 growth of x/$RJS: rc $RC, want 0: $OUT"

echo "retention-lint: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
