#!/bin/bash
# tests/gh-shim-pr-write.bh-789-test.sh — bin/lib/gh-shim/pr-write.sh (#769 chunk 3,
# BH-789): the eight `gh pr` write verbs translated to single REST calls.
#
# HOW IT DRIVES. Every block runs the REAL bin/gh-rest-shim through the PATH
# symlink $T/shim/gh with the shipped handler dir sourced (no GH_SHIM_LIB
# override except in the `mutation` block), and a stub standing in for the gh
# binary behind it (tests/lib/gh-shim-stub.sh). Assertions read the recorded
# argv in $T/gh-calls.txt, stdout, stderr, the exit code, $T/gh-env.txt and
# $T/h/logs/gh-passthrough.log — never the handler's source text.
#
# MUTATION CHECK (D1) is the `mutation` block: a `sed 's/APPROVE/APROVE/'` copy
# of the shipped handler dir must turn the `pr-review-events` assertion red.
# The other core behaviours were each broken once during the build and every one
# turned a block red:
#   - POST the labels call BEFORE the pulls POST        -> pr-create order red
#   - return 0 instead of 1 when the labels call fails  -> pr-create-label-fail red
#   - PATCH before the comment POST on pr close         -> pr-close-order red
#   - drop the `sha` field from the merge body          -> pr-merge-put-sha red
#   - map a merge 409 to exit 0                         -> pr-merge-409-exit1 red
#   - delete the branch before the merge PUT            -> pr-merge-delete-branch-after red
#   - accept --auto instead of passing it through       -> flag-passthru red
#   - DELETE the head ref without proving whose repo it is
#                                                       -> pr-merge-fork-skip red
#   - exit 1 after a LANDED merge when the branch is gone
#                                                       -> pr-merge-branch-gone red
#   - PUT on a merge-queue repo instead of passing the argv through
#                                                       -> pr-merge-queue red
#
# Run from anywhere:  bash tests/gh-shim-pr-write.bh-789-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-shim-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must not contain [$3]" ;; *) ok ;; esac; }
# lineno <needle> — 1-based index of the first recorded call containing <needle>,
# or 0. Ordering blocks compare two of these; 0 vs 0 can never read as ordered.
lineno() {
  local n=0 i=0 line
  while IFS= read -r line; do
    i=$((i+1))
    case "$line" in *"$1"*) [ "$n" -eq 0 ] && n=$i ;; esac
  done < <(gshim_calls)
  printf '%s\n' "$n"
}
before() { # before <name> <needle-a> <needle-b>
  local a b; a=$(lineno "$2"); b=$(lineno "$3")
  if [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; then ok
  else bad "$1: [$2]=$a is not recorded before [$3]=$b"; fi
}
# calls_no_bodies — the recorded argv with the decoded request bodies stripped,
# so a block can prove body text never travelled in a command line.
calls_no_bodies() { gshim_calls | sed 's/ input=.*//'; }
logfile() { [ -f "$T/h/logs/gh-passthrough.log" ] && cat "$T/h/logs/gh-passthrough.log"; return 0; }

gshim_stub_setup
printf 'https://github.com/o/r\n' >"$T/fixtures/git-origin.txt"

# Fixtures every block may hit.
printf '{"default_branch":"main"}\n' | gshim_fixture repos_o_r
printf '{"html_url":"https://github.com/o/r/pull/7","number":7,"title":"Fix it","head":{"ref":"feat","repo":{"full_name":"o/r"}},"state":"open"}\n' | gshim_fixture repos_o_r_pulls_7
printf '{"html_url":"https://github.com/o/r/pull/7","number":7,"title":"Fix it"}\n' | gshim_fixture repos_o_r_pulls
printf '[]\n' | gshim_fixture repos_o_r_issues_7_labels
printf '{}\n' | gshim_fixture repos_o_r_issues_7_labels_z
printf '{"html_url":"https://github.com/o/r/pull/7#issuecomment-1"}\n' | gshim_fixture repos_o_r_issues_7_comments
printf '{"id":11,"state":"APPROVED"}\n' | gshim_fixture repos_o_r_pulls_7_reviews
printf '{}\n' | gshim_fixture repos_o_r_git_refs_heads_feat
printf '{"sha":"deadbeef","merged":true,"message":"Pull Request successfully merged"}\n' | gshim_fixture repos_o_r_pulls_7_merge
# BH-1715: a --delete-branch first lists the open PRs based on the head ref
# (`pulls?state=open&base=feat&per_page=100`, which the stub serves from the
# `.p100` page fixture). Nothing is stacked on #7 here, so every delete block
# below still deletes; tests/branch-delete-order.bh-1715-test.sh covers children.
printf '[]\n' | gshim_fixture repos_o_r_pulls.p100

# A body that would break any handler that put it in argv.
BODY='a|b '"'"'c'"'"' $(echo x) ünïcode'

# ── pr-create ────────────────────────────────────────────────────────────────
gshim_reset
gshim_run pr create --title "T one" --body "$BODY" --head feat --label "a,b"
eq   "pr-create rc"        "$RC" "0"
eq   "pr-create stdout"    "$OUT" "https://github.com/o/r/pull/7"
has  "pr-create post"      "$(gshim_calls)" "-X POST repos/o/r/pulls --input"
has  "pr-create body"      "$(gshim_calls)" 'input={"title":"T one","body":"a|b '"'"'c'"'"' $(echo x) ünïcode","base":"main","head":"feat","draft":false}'
has  "pr-create default base read" "$(gshim_calls)" "repos/o/r "
has  "pr-create labels"    "$(gshim_calls)" '-X POST repos/o/r/issues/7/labels --input'
has  "pr-create labels body" "$(gshim_calls)" 'input={"labels":["a","b"]}'
before "pr-create labels after pulls" "repos/o/r/pulls --input" "issues/7/labels"
hasnt "pr-create body not in argv" "$(calls_no_bodies)" 'echo x'
hasnt "pr-create no passthru" "$(gshim_calls)" "PASSTHRU"

# ── pr-create-default-head (no --head → current branch) ──────────────────────
# The stub git answers only `remote get-url`; this thin wrapper adds the one
# rev-parse the handler needs and hands everything else to it.
mkdir -p "$T/gitfix"
{ printf '#!/bin/bash\nT=%q\n' "$T"
  cat <<'GITFIX'
if [ "${1:-}" = "rev-parse" ]; then
  printf 'git %s\n' "$*" >>"$T/git-calls.txt"
  echo "feat-auto"; exit 0
fi
exec "$T/real/git" "$@"
GITFIX
} >"$T/gitfix/git"
chmod 755 "$T/gitfix/git"
gshim_reset
STUB_PATH="$PATH"
PATH="$T/gitfix:$PATH" gshim_run pr create --title "T two" --body "b" --base main
PATH="$STUB_PATH"
eq  "pr-create-default-head rc" "$RC" "0"
has "pr-create-default-head body" "$(gshim_calls)" '"head":"feat-auto"'

# ── pr-create-label-fail-still-prints-url ────────────────────────────────────
gshim_reset
printf 'HTTP 422: label does not exist\n' | gshim_fixture repos_o_r_issues_7_labels 1
gshim_run pr create --title T --body b --head feat --base main --label zzz
eq  "pr-create-label-fail rc"  "$RC" "1"
eq  "pr-create-label-fail url" "$OUT" "https://github.com/o/r/pull/7"
has "pr-create-label-fail warn" "$ERR" "labels"
rm -f "$T/fixtures/repos_o_r_issues_7_labels.rc" "$T/fixtures/repos_o_r_issues_7_labels.err"
printf '[]\n' | gshim_fixture repos_o_r_issues_7_labels

# ── pr-edit-labels ───────────────────────────────────────────────────────────
gshim_reset
gshim_run pr edit 7 -R o/r --add-label x,y --remove-label z
eq  "pr-edit-labels rc"  "$RC" "0"
has "pr-edit-labels add" "$(gshim_calls)" '-X POST repos/o/r/issues/7/labels --input'
has "pr-edit-labels add body" "$(gshim_calls)" 'input={"labels":["x","y"]}'
has "pr-edit-labels remove" "$(gshim_calls)" "-X DELETE repos/o/r/issues/7/labels/z"
hasnt "pr-edit-labels no patch" "$(gshim_calls)" "-X PATCH"

# ── pr-edit-patch ────────────────────────────────────────────────────────────
gshim_reset
gshim_run pr edit https://github.com/o/r/pull/7 --title "NT" --body "$BODY"
eq  "pr-edit-patch rc"   "$RC" "0"
has "pr-edit-patch call" "$(gshim_calls)" "-X PATCH repos/o/r/pulls/7 --input"
has "pr-edit-patch body" "$(gshim_calls)" 'input={"title":"NT","body":"a|b '"'"'c'"'"' $(echo x) ünïcode"}'
hasnt "pr-edit-patch body not in argv" "$(calls_no_bodies)" 'echo x'

# ── pr-close-order ───────────────────────────────────────────────────────────
gshim_reset
gshim_run pr close 7 -R o/r --comment "closing this"
eq  "pr-close-order rc"      "$RC" "0"
has "pr-close-order comment" "$(gshim_calls)" "-X POST repos/o/r/issues/7/comments --input"
has "pr-close-order patch"   "$(gshim_calls)" '-X PATCH repos/o/r/pulls/7 --input'
has "pr-close-order state"   "$(gshim_calls)" 'input={"state":"closed"}'
before "pr-close-order comment first" "issues/7/comments" "-X PATCH repos/o/r/pulls/7"

# ── pr-close-delete-branch ───────────────────────────────────────────────────
gshim_reset
gshim_run pr close 7 -R o/r --delete-branch
eq  "pr-close-delete-branch rc" "$RC" "0"
has "pr-close-delete-branch ref read" "$(gshim_calls)" "api repos/o/r/pulls/7"
has "pr-close-delete-branch delete" "$(gshim_calls)" "-X DELETE repos/o/r/git/refs/heads/feat"
before "pr-close-delete-branch after patch" "-X PATCH repos/o/r/pulls/7" "git/refs/heads/feat"

# ── pr-reopen ────────────────────────────────────────────────────────────────
gshim_reset
gshim_run pr reopen 7 -R o/r
eq  "pr-reopen rc"   "$RC" "0"
has "pr-reopen call" "$(gshim_calls)" "-X PATCH repos/o/r/pulls/7 --input"
has "pr-reopen body" "$(gshim_calls)" 'input={"state":"open"}'

# ── pr-comment-body-file-stdin ───────────────────────────────────────────────
gshim_reset
printf '%s' "$BODY" >"$T/in.txt"
gshim_run pr comment 7 -R o/r --body-file - <"$T/in.txt"
eq  "pr-comment rc"     "$RC" "0"
eq  "pr-comment stdout" "$OUT" "https://github.com/o/r/pull/7#issuecomment-1"
has "pr-comment call"   "$(gshim_calls)" "-X POST repos/o/r/issues/7/comments --input"
has "pr-comment body"   "$(gshim_calls)" 'input={"body":"a|b '"'"'c'"'"' $(echo x) ünïcode"}'
hasnt "pr-comment body not in argv" "$(calls_no_bodies)" 'echo x'

# ── pr-review-events ─────────────────────────────────────────────────────────
gshim_reset
gshim_run pr review 7 -R o/r --approve
eq  "pr-review approve rc"   "$RC" "0"
has "pr-review approve call" "$(gshim_calls)" "-X POST repos/o/r/pulls/7/reviews --input"
has "pr-review approve body" "$(gshim_calls)" 'input={"event":"APPROVE"}'
gshim_reset
gshim_run pr review 7 -R o/r --comment --body "looks fine"
has "pr-review comment body" "$(gshim_calls)" 'input={"event":"COMMENT","body":"looks fine"}'
gshim_reset
gshim_run pr review 7 -R o/r --request-changes --body "no"
has "pr-review changes body" "$(gshim_calls)" 'input={"event":"REQUEST_CHANGES","body":"no"}'
gshim_reset
gshim_run pr review 7 -R o/r --body "no event flag"
has "pr-review no event passthru" "$(gshim_calls)" "PASSTHRU pr review 7 -R o/r --body"
has "pr-review no event logged"   "$(logfile)" "reason=flag:review-event"

# ── pr-diff-accept ───────────────────────────────────────────────────────────
gshim_reset
printf 'diff --git a/x b/x\n+one\n' | gshim_fixture repos_o_r_pulls_7 ''
mv "$T/fixtures/repos_o_r_pulls_7.json" "$T/fixtures/repos_o_r_pulls_7.diff"
printf '{"html_url":"https://github.com/o/r/pull/7","number":7,"title":"Fix it","head":{"ref":"feat","repo":{"full_name":"o/r"}},"state":"open"}\n' | gshim_fixture repos_o_r_pulls_7
gshim_run pr diff 7 -R o/r
eq  "pr-diff-accept rc"     "$RC" "0"
eq  "pr-diff-accept stdout" "$OUT" "$(printf 'diff --git a/x b/x\n+one')"
has "pr-diff-accept header" "$(gshim_calls)" "-H Accept: application/vnd.github.v3.diff"

# ── pr-diff-name-only ────────────────────────────────────────────────────────
gshim_reset
printf '[{"filename":"a/one.ts"},{"filename":"b/two.sh"}]\n' | gshim_fixture repos_o_r_pulls_7_files
gshim_run pr diff 7 -R o/r --name-only
eq  "pr-diff-name-only rc"     "$RC" "0"
eq  "pr-diff-name-only stdout" "$OUT" "$(printf 'a/one.ts\nb/two.sh')"
has "pr-diff-name-only call"   "$(gshim_calls)" "repos/o/r/pulls/7/files"
hasnt "pr-diff-name-only no diff header" "$(gshim_calls)" "vnd.github.v3.diff"

# ── pr-merge-put-sha ─────────────────────────────────────────────────────────
gshim_reset
gshim_run pr merge 7 -R o/r --squash --match-head-commit abc123
eq  "pr-merge-put-sha rc"   "$RC" "0"
has "pr-merge-put-sha call" "$(gshim_calls)" "-X PUT repos/o/r/pulls/7/merge --input"
has "pr-merge-put-sha body" "$(gshim_calls)" 'input={"merge_method":"squash","sha":"abc123"}'
eq  "pr-merge-put-sha stdout" "$OUT" "✓ Squashed and merged pull request #7 (Fix it)"
gshim_reset
gshim_run pr merge 7 -R o/r --rebase
has "pr-merge-rebase body"   "$(gshim_calls)" 'input={"merge_method":"rebase"}'
eq  "pr-merge-rebase stdout" "$OUT" "✓ Rebased and merged pull request #7 (Fix it)"
gshim_reset
gshim_run pr merge 7 -R o/r --merge
eq  "pr-merge-merge stdout" "$OUT" "✓ Merged pull request #7 (Fix it)"

# ── pr-merge-409-exit1 ───────────────────────────────────────────────────────
gshim_reset
printf 'HTTP 409: Head branch was modified (https://api.github.com/repos/o/r/pulls/7/merge)\n' | gshim_fixture repos_o_r_pulls_7_merge 1
gshim_run pr merge 7 -R o/r --squash --match-head-commit abc123
eq  "pr-merge-409 rc" "$RC" "1"
has "pr-merge-409 stderr line 1" "$(head -n1 <<<"$ERR")" "Head branch was modified"
eq  "pr-merge-409 stdout empty"  "$OUT" ""
rm -f "$T/fixtures/repos_o_r_pulls_7_merge.rc" "$T/fixtures/repos_o_r_pulls_7_merge.err"
printf '{"sha":"deadbeef","merged":true,"message":"Pull Request successfully merged"}\n' | gshim_fixture repos_o_r_pulls_7_merge

# ── pr-merge-delete-branch-after ─────────────────────────────────────────────
gshim_reset
gshim_run pr merge 7 -R o/r --squash --delete-branch
eq  "pr-merge-delete-branch rc" "$RC" "0"
has "pr-merge-delete-branch delete" "$(gshim_calls)" "-X DELETE repos/o/r/git/refs/heads/feat"
before "pr-merge-delete-branch after put" "pulls/7/merge" "git/refs/heads/feat"

# ── pr-merge-delete-branch-fork-skip ─────────────────────────────────────────
# A PR from a fork has its head IN THE FORK, so refs/heads/<ref> in the base
# repo is a DIFFERENT branch that happens to share the name. Real gh skips the
# remote delete on a cross-repository head and bin/lib/gh-pr-merge.sh refuses it
# (BH-892, "never delete a fork's branch"). The merge line still lands and the
# call is a success.
gshim_reset
printf '{"html_url":"https://github.com/o/r/pull/7","number":7,"title":"Fix it","head":{"ref":"feat","repo":{"full_name":"someone/r"}},"state":"open"}\n' | gshim_fixture repos_o_r_pulls_7
gshim_run pr merge 7 -R o/r --squash --delete-branch
eq    "pr-merge-fork-skip rc"     "$RC" "0"
eq    "pr-merge-fork-skip stdout" "$OUT" "✓ Squashed and merged pull request #7 (Fix it)"
hasnt "pr-merge-fork-skip no delete" "$(gshim_calls)" "git/refs/heads"
has   "pr-merge-fork-skip stderr"    "$ERR" "someone/r"

# ── pr-close-delete-branch-fork-skip ─────────────────────────────────────────
gshim_reset
gshim_run pr close 7 -R o/r --delete-branch
eq    "pr-close-fork-skip rc"     "$RC" "0"
has   "pr-close-fork-skip closed" "$(gshim_calls)" 'input={"state":"closed"}'
hasnt "pr-close-fork-skip no delete" "$(gshim_calls)" "git/refs/heads"

# ── pr-merge-delete-branch-head-repo-absent ──────────────────────────────────
# A head whose repo the answer does not name (a fork deleted before the merge
# settled) is not proof of ownership either.
gshim_reset
printf '{"number":7,"title":"Fix it","head":{"ref":"feat"},"state":"open"}\n' | gshim_fixture repos_o_r_pulls_7
gshim_run pr merge 7 -R o/r --squash --delete-branch
eq    "pr-merge-headless-repo rc" "$RC" "0"
hasnt "pr-merge-headless-repo no delete" "$(gshim_calls)" "git/refs/heads"

# ── pr-merge-delete-branch-case ──────────────────────────────────────────────
# GitHub's canonical full_name and a -R slug can differ in case; a case-only
# mismatch must not skip every delete.
gshim_reset
printf '{"number":7,"title":"Fix it","head":{"ref":"feat","repo":{"full_name":"O/R"}},"state":"open"}\n' | gshim_fixture repos_o_r_pulls_7
gshim_run pr merge 7 -R o/r --squash --delete-branch
eq  "pr-merge-case rc"     "$RC" "0"
has "pr-merge-case delete" "$(gshim_calls)" "-X DELETE repos/o/r/git/refs/heads/feat"
printf '{"html_url":"https://github.com/o/r/pull/7","number":7,"title":"Fix it","head":{"ref":"feat","repo":{"full_name":"o/r"}},"state":"open"}\n' | gshim_fixture repos_o_r_pulls_7

# ── pr-merge-delete-branch-gone-still-rc0 ────────────────────────────────────
# The merge has LANDED and its line is already on stdout. A branch GitHub
# deleted itself (delete-branch-on-merge) must not turn that into a non-zero
# exit: bin/poll-commands.sh:107 reads the rc as `merge failed:` and re-leases a
# console command toward a dead letter for a merge that is on main.
gshim_reset
printf 'HTTP 422: Reference does not exist\n' | gshim_fixture repos_o_r_git_refs_heads_feat 1
gshim_run pr merge 7 -R o/r --squash --delete-branch
eq  "pr-merge-branch-gone rc"          "$RC" "0"
eq  "pr-merge-branch-gone stdout"      "$OUT" "✓ Squashed and merged pull request #7 (Fix it)"
has "pr-merge-branch-gone delete tried" "$(gshim_calls)" "-X DELETE repos/o/r/git/refs/heads/feat"
has "pr-merge-branch-gone stderr"       "$ERR" "the merge stands"
# A close is not a landed merge: there a failed delete is still the exit code.
gshim_reset
gshim_run pr close 7 -R o/r --delete-branch
eq  "pr-close-branch-gone rc" "$RC" "1"
rm -f "$T/fixtures/repos_o_r_git_refs_heads_feat.rc" "$T/fixtures/repos_o_r_git_refs_heads_feat.err"
printf '{}\n' | gshim_fixture repos_o_r_git_refs_heads_feat

# ── pr-merge-never-reaches-real-pr-merge ─────────────────────────────────────
# Self-contained (its own reset and its own translated merge): the old shape
# asserted on whatever the previous block happened to leave in gh-calls.txt.
gshim_reset
gshim_run pr merge 7 -R o/r --squash
eq    "pr-merge-never-passthru rc" "$RC" "0"
hasnt "pr-merge never passthru" "$(gshim_calls)" "PASSTHRU pr merge"
hasnt "pr-merge no graphql"     "$(gshim_calls)" "graphql"

# ── pr-merge-native-queue-passthru ───────────────────────────────────────────
# BH-892: under GitHub's OWN merge queue `gh pr merge` ENQUEUES and REST has no
# equivalent, so the PUT is a 405 that wrote nothing and the original argv goes
# to the real binary — the enqueue every fleet caller expects on those repos.
gshim_reset
printf 'HTTP 405: Merge queue is required for this branch (https://api.github.com/repos/o/r/pulls/7/merge)\n' | gshim_fixture repos_o_r_pulls_7_merge 1
gshim_run pr merge 7 -R o/r --squash
eq    "pr-merge-queue rc"       "$RC" "0"
has   "pr-merge-queue passthru" "$(gshim_calls)" "PASSTHRU pr merge 7 -R o/r --squash"
has   "pr-merge-queue depth"    "$(gshim_env)"   "depth=1 pr merge 7 -R o/r --squash"
has   "pr-merge-queue log"      "$(logfile)"   "reason=merge-queue"
hasnt "pr-merge-queue no merge line" "$OUT" "Squashed and merged"

# ── pr-merge-405-not-a-queue-exit1 ───────────────────────────────────────────
# Every other 405 is GitHub refusing THIS merge, and a refusal is never retried
# through a second path.
gshim_reset
printf 'HTTP 405: Base branch was modified. Review and try the merge again.\n' | gshim_fixture repos_o_r_pulls_7_merge 1
gshim_run pr merge 7 -R o/r --squash
eq    "pr-merge-405-other rc"           "$RC" "1"
has   "pr-merge-405-other stderr line 1" "$(head -n1 <<<"$ERR")" "Base branch was modified"
hasnt "pr-merge-405-other no passthru"   "$(gshim_calls)" "PASSTHRU pr merge"
rm -f "$T/fixtures/repos_o_r_pulls_7_merge.rc" "$T/fixtures/repos_o_r_pulls_7_merge.err"
printf '{"sha":"deadbeef","merged":true,"message":"Pull Request successfully merged"}\n' | gshim_fixture repos_o_r_pulls_7_merge

# ── flag-passthru ────────────────────────────────────────────────────────────
gshim_reset
gshim_run pr merge 7 -R o/r --squash --auto
has "flag-passthru argv"  "$(gshim_calls)" "PASSTHRU pr merge 7 -R o/r --squash --auto"
has "flag-passthru depth" "$(gshim_env)"   "depth=1 pr merge 7 -R o/r --squash --auto"
has "flag-passthru log"   "$(logfile)"   "reason=flag:--auto"
hasnt "flag-passthru no merge call" "$(gshim_calls)" "pulls/7/merge"
gshim_reset
gshim_run pr merge 7 -R o/r --admin --squash
has "flag-passthru admin" "$(gshim_calls)" "PASSTHRU pr merge 7 -R o/r --admin --squash"
gshim_reset
gshim_run pr create --title T --body b --head feat --base main --web
has "flag-passthru web" "$(gshim_calls)" "PASSTHRU pr create"
hasnt "flag-passthru web no post" "$(gshim_calls)" "-X POST repos/o/r/pulls"
gshim_reset
gshim_run pr edit 7 -R o/r --milestone m1
has "flag-passthru milestone" "$(gshim_calls)" "PASSTHRU pr edit 7 -R o/r --milestone m1"

# ── mutation (D1): break the review event, watch pr-review-events go red ─────
mkdir -p "$T/lib"
for f in "$DIR"/bin/lib/gh-shim/*.sh; do
  [ -f "$f" ] || continue
  sed 's/APPROVE/APROVE/g' "$f" >"$T/lib/$(basename "$f")"
done
MUT_SHIPPED=$(grep -c 'APPROVE' "$DIR/bin/lib/gh-shim/pr-write.sh" 2>/dev/null); MUT_SHIPPED=${MUT_SHIPPED:-0}
MUT_COPY=$(grep -c 'APPROVE' "$T/lib/pr-write.sh" 2>/dev/null); MUT_COPY=${MUT_COPY:-0}
if [ "$MUT_SHIPPED" -ge 1 ] && [ "$MUT_COPY" -eq 0 ]; then ok
else bad "mutation: the sed did not change anything"; fi
gshim_reset
export GH_SHIM_LIB="$T/lib"
gshim_run pr review 7 -R o/r --approve
unset GH_SHIM_LIB
case "$(gshim_calls)" in
  *'input={"event":"APPROVE"}'*) bad "mutation: the mutant still sends APPROVE — pr-review-events pins nothing" ;;
  *) ok ;;
esac

echo "gh-shim-pr-write: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
