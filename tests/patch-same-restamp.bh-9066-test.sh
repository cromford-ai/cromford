#!/bin/bash
# tests/patch-same-restamp.bh-9066-test.sh — the restamp-rebase rung of
# bin/lib/patch-same.sh (BH-9066, slice C0) against REAL git histories.
#
# A PR adds worker/jobs/schema.d/<stamp>-bh-1-a.sql and names it in refs.txt.
# The reviewed head is R. The new head H is R rebased onto a newer main, then
# restamped (the fragment renamed to a later stamp, every reference rewritten),
# the conductor land-rebase shape (#9000). R is not an ancestor of H, so
# restamp_same (BH-6842) cannot see it.
#
#   SAME (patch_same_restamp and patch_same_review print restamp-rebase, rc 0):
#     1  rebase + restamp                     2  two fragments, both forward, in order
#     3  case 1 + the BH-7120 plan.md placeholder rewrite
#     4  case 1 + a later clean main merge
#   DIFFERENT (rc 1, and patch_same_review does not print restamp-rebase):
#     5  + one code line          6  + one SQL byte        7  a and b swap order
#     8  a stamp moved backwards  9  suffix renamed        10 an NNNN fragment renamed
#     11 a reference to a MAIN fragment changed            12 a PR fragment added
#     13 a whitespace-only edit   14 a lockfile-only edit  15 fragment mode 644 -> 755
#     16 a quoted path under schema.d                      17 no stamp differs
#     20 a restamp commit ON TOP of R (R an ancestor): the rung leaves it to
#        restamp_same, and patch_same_review answers `restamp`
#     18 a stubbed git           19 a binary file changed (`git diff` prints one line for any bytes)
# Run from anywhere: tests/patch-same-restamp.bh-9066-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
. "$DIR/bin/lib/patch-same.sh" || { echo "FAIL: cannot source bin/lib/patch-same.sh"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
G="$T/repo"
S=worker/jobs/schema.d
OLD_A=202611041200-bh-1-a.sql; NEW_A=202611051300-bh-1-a.sql
OLD_B=202611041201-bh-1-b.sql; NEW_B=202611051301-bh-1-b.sql
g() { git -C "$G" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$G/f.txt" && rm -f "$G/f.txt.bak"; }
commit() { g add -A; g commit -qm "$1"; g rev-parse HEAD; }

# seed — main: f.txt (30 lines), a main fragment, a lockfile.
seed() {
  scratch_rm "$G" 2>/dev/null; mkdir -p "$G/$S"
  g init -q -b main
  seq 1 30 | sed 's/^/line /' > "$G/f.txt"
  printf 'CREATE TABLE base (id INTEGER);\n' > "$G/$S/202610010000-bh-0-base.sql"
  printf '{"lockfileVersion": 3}\n' > "$G/package-lock.json"
  g add -A; g commit -qm base
}
# pr [extra...] — the PR branch: line 10 changed, fragment a, refs.txt naming it
# (and the main fragment), plus each extra: b (fragment b), plan, nnnn, quoted.
pr() {
  seed
  g checkout -qb pr
  edit 10 'line 10 CHANGED BY PR'
  printf 'CREATE TABLE a (id INTEGER);\n' > "$G/$S/$OLD_A"
  printf 'apply %s/%s after 202610010000-bh-0-base.sql\n' "$S" "$OLD_A" > "$G/refs.txt"
  local x
  for x in "$@"; do
    case "$x" in
      b) printf 'CREATE TABLE b (id INTEGER);\n' > "$G/$S/$OLD_B"; printf 'then %s\n' "$OLD_B" >> "$G/refs.txt" ;;
      plan) mkdir -p "$G/.harness/specs/BH-1"
            printf '# plan\n\n- add %s/<yyyymmddhhmm>-bh-1-a.sql\n' "$S" > "$G/.harness/specs/BH-1/plan.md" ;;
      nnnn) printf 'CREATE TABLE n (id INTEGER);\n' > "$G/$S/0005-n.sql" ;;
      quoted) printf 'CREATE TABLE q (id INTEGER);\n' > "$G/$S/202611041202-bh-1-q\"x.sql" ;;
    esac
  done
  R=$(commit pr-change)
}
# rebase_main — main moves on a far file, the PR rebases onto it (no restamp yet).
rebase_main() {
  g checkout -q main; printf 'main moved\n' > "$G/o.txt"; commit main-moved >/dev/null
  g checkout -q pr; g rebase -q main >/dev/null 2>&1
}
# restamp <old> <new> — git mv the fragment and rewrite every reference.
restamp() {
  g mv "$S/$1" "$S/$2"
  sed -i.bak "s/$1/$2/g" "$G/refs.txt" && rm -f "$G/refs.txt.bak"
}
finish() { H=$(commit "restamp schema fragments (no SQL change)"); }

want_same() { # <case> — both entry points print restamp-rebase, rc 0
  local out rc
  out=$(patch_same_restamp "$G" main "$R" "$H"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = restamp-rebase ] && ok || bad "$1 patch_same_restamp: rc=$rc out='$out', want restamp-rebase rc 0"
  out=$(patch_same_review "$G" main "$R" "$H"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = restamp-rebase ] && ok || bad "$1 patch_same_review: rc=$rc out='$out', want restamp-rebase rc 0"
}
want_diff() { # <case> — rc 1 from the rung and from the review chain
  local out rc
  out=$(patch_same_restamp "$G" main "$R" "$H"); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "$1 patch_same_restamp: rc=$rc out='$out', want rc 1"
  out=$(patch_same_review "$G" main "$R" "$H"); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "$1 patch_same_review: rc=$rc out='$out', want rc 1"
}

# ---- 1: rebase + restamp
pr; rebase_main; restamp "$OLD_A" "$NEW_A"; finish
want_same "case 1"
out=$(patch_same "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && ok || bad "case 1 byte patch_same must stay rc 1 (the rung is new): rc=$rc out='$out'"
. "$DIR/bin/lib/schema-restamp.sh" || bad "cannot source bin/lib/schema-restamp.sh"
out=$(restamp_same "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && ok || bad "case 1 precondition: restamp_same must not see a rebase (rc=$rc out='$out')"

# ---- 2: two fragments, both forward, in order
pr b; rebase_main; restamp "$OLD_A" "$NEW_A"; restamp "$OLD_B" "$NEW_B"; finish
want_same "case 2"

# ---- 3: + the BH-7120 plan placeholder rewrite
pr plan; rebase_main; restamp "$OLD_A" "$NEW_A"
sed -i.bak "s#<yyyymmddhhmm>-bh-1-a.sql#$NEW_A#" "$G/.harness/specs/BH-1/plan.md" && rm -f "$G/.harness/specs/BH-1/plan.md.bak"
grep -q "$NEW_A" "$G/.harness/specs/BH-1/plan.md" || bad "case 3 fixture: the plan rewrite did not happen"
finish
want_same "case 3"

# ---- 4: + a later clean main merge
pr; rebase_main; restamp "$OLD_A" "$NEW_A"; finish
g checkout -q main; printf 'later\n' > "$G/later.txt"; commit later >/dev/null
g checkout -q pr; g merge -q --no-edit main; H=$(g rev-parse HEAD)
want_same "case 4"

# ---- 5: + one code line
pr; rebase_main; restamp "$OLD_A" "$NEW_A"; edit 20 'line 20 NEW CODE'; finish
want_diff "case 5"

# ---- 6: + one SQL byte
pr; rebase_main; restamp "$OLD_A" "$NEW_A"; printf 'CREATE TABLE a (id INTEGER );\n' > "$G/$S/$NEW_A"; finish
want_diff "case 6"

# ---- 7: a and b swap order (stamps cross)
pr b; rebase_main
restamp "$OLD_A" 202611051302-bh-1-a.sql; restamp "$OLD_B" 202611051301-bh-1-b.sql; finish
want_diff "case 7"

# ---- 8: a stamp moved backwards
pr; rebase_main; restamp "$OLD_A" 202611031200-bh-1-a.sql; finish
want_diff "case 8"

# ---- 9: suffix renamed
pr; rebase_main; restamp "$OLD_A" 202611051300-bh-1-z.sql; finish
want_diff "case 9"

# ---- 10: an NNNN fragment renamed alongside the restamp
pr nnnn; rebase_main; restamp "$OLD_A" "$NEW_A"; g mv "$S/0005-n.sql" "$S/0006-n.sql"; finish
want_diff "case 10"

# ---- 11: a reference to a MAIN fragment's name changed
pr; rebase_main; restamp "$OLD_A" "$NEW_A"
sed -i.bak 's/202610010000-bh-0-base.sql/202610010001-bh-0-base.sql/' "$G/refs.txt" && rm -f "$G/refs.txt.bak"; finish
want_diff "case 11"

# ---- 12: a PR fragment added
pr; rebase_main; restamp "$OLD_A" "$NEW_A"; printf 'CREATE TABLE c (id INTEGER);\n' > "$G/$S/202611051305-bh-1-c.sql"; finish
want_diff "case 12"

# ---- 13: a whitespace-only edit (C0 keeps whitespace a change)
pr; rebase_main; restamp "$OLD_A" "$NEW_A"; edit 10 'line 10  CHANGED BY PR'; finish
want_diff "case 13"

# ---- 14: a lockfile-only edit (C0 keeps a lockfile a change)
pr; rebase_main; restamp "$OLD_A" "$NEW_A"; printf '{"lockfileVersion": 3, "x": 1}\n' > "$G/package-lock.json"; finish
want_diff "case 14"

# ---- 15: the fragment mode 644 -> 755
pr; rebase_main; restamp "$OLD_A" "$NEW_A"; chmod 755 "$G/$S/$NEW_A"; g update-index --chmod=+x "$S/$NEW_A"; finish
want_diff "case 15"

# ---- 16: a quoted path under schema.d, renamed with the restamp
pr quoted; rebase_main; restamp "$OLD_A" "$NEW_A"; g mv "$S/202611041202-bh-1-q\"x.sql" "$S/202611051302-bh-1-q\"x.sql"; finish
want_diff "case 16"

# ---- 17: no stamp differs (a plain rebase: the byte rungs own it)
pr; rebase_main; H=$(g rev-parse HEAD)
out=$(patch_same_restamp "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "case 17 patch_same_restamp must leave a plain rebase to the byte rungs: rc=$rc out='$out'"
out=$(patch_same_review "$G" main "$R" "$H"); rc=$?
[ "$rc" = 0 ] && [ "$out" = patch-id ] && ok || bad "case 17 patch_same_review must answer from the byte rung: rc=$rc out='$out', want patch-id"

# ---- 18: a stubbed git (rc 0, no output) never reads as the same patch
pr; rebase_main; restamp "$OLD_A" "$NEW_A"; finish
mkdir -p "$T/stub"; printf '#!/bin/bash\nexit 0\n' > "$T/stub/git"; chmod +x "$T/stub/git"
out=$(PATH="$T/stub:$PATH" patch_same_restamp "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "case 18 a stubbed git must never read as the same patch: rc=$rc out='$out'"
out=$(PATH="$T/stub:$PATH" patch_same_review "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "case 18 patch_same_review on a stubbed git: rc=$rc out='$out'"
# ...and one whose patch-id is an md5 of its input (equal for equal text only).
printf '#!/bin/bash\ncase "$*" in *patch-id*) md5sum | cut -d" " -f1 ;; *) exit 0 ;; esac\n' > "$T/stub/git"
out=$(PATH="$T/stub:$PATH" patch_same_restamp "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && ok || bad "case 18b an md5 patch-id stub must not read as the same patch: rc=$rc out='$out'"

# ---- 19: a binary file whose bytes change with the restamp
# (git 2.43 patch-id gives a binary diff with no index line a random id, so the
# rung refuses any binary file outright; this case pins the rc 1.)
pr; g checkout -q main; printf 'bin\0one\n' > "$G/blob.dat"; commit main-blob >/dev/null
g checkout -q pr; g rebase -q main >/dev/null 2>&1; printf 'bin\0two\n' > "$G/blob.dat"; R=$(commit pr-blob)
g checkout -q main; printf 'main moved\n' > "$G/o.txt"; commit main-moved >/dev/null
g checkout -q pr; g rebase -q main >/dev/null 2>&1; restamp "$OLD_A" "$NEW_A"; printf 'bin\0six\n' > "$G/blob.dat"; finish
want_diff "case 19"

# ---- 20: R is an ancestor of H (a restamp commit on top, no rebase)
pr; restamp "$OLD_A" "$NEW_A"; finish
out=$(patch_same_restamp "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "case 20 patch_same_restamp must leave a descendant head to restamp_same: rc=$rc out='$out'"
out=$(patch_same_review "$G" main "$R" "$H"); rc=$?
[ "$rc" = 0 ] && [ "$out" = restamp ] && ok || bad "case 20 patch_same_review must answer restamp from restamp_same: rc=$rc out='$out'"

echo "patch-same-restamp.bh-9066: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
