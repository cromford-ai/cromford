#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/migration-renumber-queued.bh-7671-test.sh — BH-7671: the renumber lib
# (bin/lib/migration-renumber.sh) knows which open PRs are IN the merge queue.
# A queued PR takes its numbers whatever its PR number (it lands first), the
# check can read a sha that is not HEAD (MNR_HEAD), and MNR_OPEN_QUEUED_ONLY=1
# reads only the queued PRs.
#
#   R1  the open-PR rows carry a queued flag: 1 for merge-queue, queued and
#       checking; 0 with dequeued too, or with no queue label
#   R2  MNR_HEAD=<sha> in a clone whose HEAD is elsewhere: mnr_check sees the
#       files that sha added
#   R3  at a rebase (self PR #20) a QUEUED PR #30 with 0270 moves the self 0270
#   R4  the same with PR #30 not queued: the self keeps 0270 (BH-7398 unchanged)
#   R5  MNR_OPEN_QUEUED_ONLY=1 fetches only the queued PRs' refs and drops
#       refs/mnr-open/ after
#   R6  a PR with the dequeued label does not take a number
#   R7  a queued PR of the self ticket (ticket/bh-20-r2) is left out
#   R8  the why line names the queued PR
#
# Real git, a local bare origin behind a github url (insteadOf), and a stub
# gh_rest_pr_list_all that reads a fixture list. No network.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/migration-renumber-queued.bh-7671-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git  >/dev/null || { echo "git missing — skipping";  exit 0; }
command -v jq   >/dev/null || { echo "jq missing — skipping";   exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/migration-renumber.sh"
REALGIT=$(command -v git)
SLUG=example-org/demo-os
GHURL="https://github.com/$SLUG.git"

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global advice.detachedHead false
git config --global "url.$T/origin.git.insteadOf" "$GHURL"
unset MNR_DIR MNR_MODE MNR_LOCK_PREFIX MNR_OPEN_PRS MNR_OPEN_PRS_MAX MNR_HEAD MNR_OPEN_QUEUED_ONLY
export T

S="$T/seed"; U="$T/u"; OJ="$T/open.json"; export OJ U
# A git shim on PATH records each fetch: the lib runs `timeout 120 git fetch`,
# which a shell function cannot see.
mkdir -p "$T/bin"
printf '#!/bin/bash\n[ "${1:-}" = -C ] && [ "${3:-}" = fetch ] && printf "%%s\\n" "$*" >> "$T/fetch-args"\nexec %q "$@"\n' "$REALGIT" > "$T/bin/git"
chmod +x "$T/bin/git"

reset_origin() {
  local f
  rm -rf "$T/origin.git" "$S"; printf '[]' > "$OJ"; rm -f "$T/fetch-args"
  "$REALGIT" init -q --bare "$T/origin.git"
  "$REALGIT" clone -q "$T/origin.git" "$S" 2>/dev/null
  mkdir -p "$S/prisma/sql"
  for f in 0001_init.sql 0269_last.sql; do printf -- '-- migration:%s base\n' "${f%%_*}" > "$S/prisma/sql/$f"; done
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm base
  "$REALGIT" -C "$S" push -q origin main 2>/dev/null
}
# opr <n> <head-ref> <labels-json> <file...> — an open PR that ADDS the files,
# published as refs/pull/<n>/head, listed with the given labels.
opr() {
  local n="$1" h="$2" l="$3" f; shift 3
  "$REALGIT" -C "$S" checkout -q -B "$h" main
  for f in "$@"; do printf -- '-- pr %s\n' "$n" > "$S/prisma/sql/$f"; done
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm "pr $n"
  "$REALGIT" -C "$S" push -q -f origin "$h" 2>/dev/null
  "$REALGIT" -C "$T/origin.git" update-ref "refs/pull/$n/head" "$("$REALGIT" -C "$S" rev-parse HEAD)"
  "$REALGIT" -C "$S" checkout -q main
  jq -c --argjson n "$n" --arg h "$h" --argjson l "$l" \
    '. + [{number:$n, head:{ref:$h}, base:{ref:"main"}, labels:($l | map({name:.}))}]' "$OJ" > "$OJ.n" && mv "$OJ.n" "$OJ"
}
selfb() {
  scratch_rm "$U" || exit 1
  "$REALGIT" clone -q "$GHURL" "$U" 2>/dev/null
  "$REALGIT" -C "$U" checkout -q -b "$1" origin/main
}
addmig() { printf -- '-- migration:%s\n' "${1%%_*}" > "$U/prisma/sql/$1"; git -C "$U" add -A && git -C "$U" commit -qm branch; }
# run <cmd...> — the lib in a child shell, the stub list and a git fetch tap.
run() {
  ( cd "$T" && env PATH="$T/bin:$PATH" MNR_DIR=prisma/sql MNR_OPEN_PRS=1 "$@" bash -c '
      gh_rest_pr_list_all() { cat "$OJ"; }
      . "$0" || exit 9; eval "$CMD"' "$LIB" ) > "$T/out" 2>"$T/err"
  RC=$?
}
has()    { git -C "$U" ls-files --error-unmatch "$1" >/dev/null 2>&1; }
norefs() { [ -z "$(git -C "$U" for-each-ref refs/mnr-open/)" ]; }

# R1 — the rows carry the queued flag.
reset_origin
opr 10 ticket/bh-10 '["merge-queue"]' 0270_a.sql
opr 11 ticket/bh-11 '["queued"]' 0271_a.sql
opr 12 ticket/bh-12 '["checking","ai-build"]' 0272_a.sql
opr 13 ticket/bh-13 '["merge-queue","dequeued"]' 0273_a.sql
opr 14 ticket/bh-14 '[]' 0274_a.sql
selfb ticket/bh-20; addmig 0275_b.sql
CMD='mnr_conf tproj; _mnr_open_taken "$U" origin/main ticket/bh-20; echo "rc=$?"; printf "%s\n" "$MNR_C_OPEN"' run
for want in "rc=0" $'0270\t0270_a.sql\t10\t1' $'0271\t0271_a.sql\t11\t1' $'0272\t0272_a.sql\t12\t1' \
            $'0273\t0273_a.sql\t13\t0' $'0274\t0274_a.sql\t14\t0'; do
  grep -qxF "$want" "$T/out" && ok || bad "R1: want row '$want' (got: $(cat "$T/out"), err: $(cat "$T/err"))"
done
# R5 — queued only: the fetch names #10, #11, #12 and neither #13 nor #14.
rm -f "$T/fetch-args"
CMD='mnr_conf tproj; _mnr_open_taken "$U" origin/main ticket/bh-20; echo "rc=$?"; printf "%s\n" "$MNR_C_OPEN"' run MNR_OPEN_QUEUED_ONLY=1
f=$(cat "$T/fetch-args" 2>/dev/null)
grep -q 'refs/pull/10/head' <<<"$f" && grep -q 'refs/pull/12/head' <<<"$f" && ! grep -q 'refs/pull/13/head' <<<"$f" \
  && ! grep -q 'refs/pull/14/head' <<<"$f" && ok || bad "R5: the fetch must name only queued PRs (got: $f)"
[ "$(grep -c "$(printf '\t')" "$T/out")" = 3 ] && ! grep -q '0274_a' "$T/out" && ok || bad "R5: only the queued rows (got: $(cat "$T/out"))"
norefs && ok || bad "R5: refs/mnr-open/ must be dropped (got: $(git -C "$U" for-each-ref refs/mnr-open/))"

# R2 — MNR_HEAD reads a sha that is not HEAD.
reset_origin
selfb ticket/bh-20; addmig 0269_dup.sql; SHA=$(git -C "$U" rev-parse HEAD); git -C "$U" checkout -q --detach origin/main
CMD='mnr_check "$U" origin/main tproj ticket/bh-20 20' run MNR_OPEN_PRS=0
[ "$RC" = 0 ] && ok || bad "R2: HEAD (main) adds nothing, want rc 0 (rc $RC, out: $(cat "$T/out"))"
CMD='mnr_check "$U" origin/main tproj ticket/bh-20 20' run MNR_OPEN_PRS=0 MNR_HEAD="$SHA"
[ "$RC" = 1 ] && grep -qF '0269 is taken on main by 0269_last.sql' "$T/out" && ok || bad "R2: MNR_HEAD=<sha> must see 0269_dup (rc $RC, out: $(cat "$T/out"), err: $(cat "$T/err"))"
[ "$(git -C "$U" rev-parse HEAD)" = "$(git -C "$U" rev-parse origin/main)" ] && ok || bad "R2: a check must not move HEAD"

# R3 + R8 — a queued higher PR takes its number at a rebase.
reset_origin; opr 30 ticket/bh-30 '["merge-queue"]' 0270_a.sql
selfb ticket/bh-20; addmig 0270_b.sql
CMD='mnr_fix "$U" origin/main tproj ticket/bh-20 20' run
[ "$RC" = 0 ] && has prisma/sql/0271_b.sql && ! has prisma/sql/0270_b.sql && ok || bad "R3: a queued #30 moves self 0270 (rc $RC, out: $(cat "$T/out"), err: $(cat "$T/err"))"
grep -qxF "0270 is taken by queued PR #30 (0270_a.sql); this PR's number is 0271 (prisma/sql/0270_b.sql -> prisma/sql/0271_b.sql)" "$T/out" \
  && ok || bad "R8: the why line names the queued PR (got: $(cat "$T/out"))"

# R4 — the same PR not queued: BH-7398's lower-number rule keeps the self number.
reset_origin; opr 30 ticket/bh-30 '[]' 0270_a.sql
selfb ticket/bh-20; addmig 0270_b.sql
CMD='mnr_fix "$U" origin/main tproj ticket/bh-20 20' run
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && has prisma/sql/0270_b.sql && ok || bad "R4: an open higher PR does not take (rc $RC, out: $(cat "$T/out"))"

# R6 — dequeued does not count.
reset_origin; opr 30 ticket/bh-30 '["merge-queue","dequeued"]' 0270_a.sql
selfb ticket/bh-20; addmig 0270_b.sql
CMD='mnr_fix "$U" origin/main tproj ticket/bh-20 20' run
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && has prisma/sql/0270_b.sql && ok || bad "R6: a dequeued PR does not take (rc $RC, out: $(cat "$T/out"))"

# R7 — a queued PR of the same ticket is left out.
reset_origin; opr 30 ticket/bh-20-r2 '["merge-queue"]' 0270_a.sql
selfb ticket/bh-20; addmig 0270_b.sql
CMD='mnr_fix "$U" origin/main tproj ticket/bh-20 20' run
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && has prisma/sql/0270_b.sql && ok || bad "R7: the self ticket's queued PR is left out (rc $RC, out: $(cat "$T/out"))"

echo "migration-renumber-queued: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
