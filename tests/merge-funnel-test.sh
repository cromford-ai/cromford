#!/bin/bash
# tests/merge-funnel-test.sh — THE MERGE FUNNEL (W2-D, 2026-09-14): the three
# things that stop one merge into main from costing every other open PR a
# rebase, a re-review and a serialized build.
#
#   1. mc_merge_tree / merge_tree_clean — GitHub says DIRTY, git says the head
#      merges cleanly, and the conductor leaves the head alone instead of
#      rebasing it. Capped, so a PR can never sit here forever.
#   2. mc_no_overlap / rebind_no_overlap — the head moved because main moved,
#      and nothing that landed is a file this PR touches, so the approval is
#      REBOUND instead of a Fable re-review being bought.
#   3. bin/plan-overlap.sh — two plans that name the same file do not co-build;
#      the second one stands down with a not-before instead of meeting the first
#      one as a merge conflict.
#   4. mc_orphan_clean (2026-09-16) — the parent PR CLOSED without merging, and
#      the child stacked on its branch is either one PATCH from being a normal
#      PR against main or a branch an agent has to move. Same funnel logic, same
#      read-only local git, applied to the ending the conductor had no event for.
#
# WHY THE GIT HALF IS DRIVEN AGAINST A REAL REPOSITORY. Every assertion here is
# about what `git merge-tree` and two merge-bases actually answer; a stubbed git
# would only prove that the shell around them is spelled right, which is the
# half that was never in doubt. So a real bare origin is built with a clean
# branch and a conflicting one, and the fake remote url is pointed at it with
# `url.<path>.insteadOf` — real git, real merges, no network.
#
# Run from anywhere: tests/merge-funnel-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

SLUG=example-org/demo-os
PROJ=demo-os
URL="https://github.com/$SLUG/pull/21"

# --- a real repository, and a real remote that never leaves this box ---------
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
mkdir -p "$T/seed/src" "$T/seed/docs"
printf 'A1\n' > "$T/seed/src/a.ts"
seq 1 20 > "$T/seed/src/b.ts"
printf 'x\n' > "$T/seed/docs/x.md"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm base && git -C "$T/seed" push -q origin main
BASE=$(git -C "$T/seed" rev-parse HEAD)

# ticket/clean — adds a file nothing else touches.
git -C "$T/seed" checkout -q -b ticket/clean "$BASE"
printf 'export const c = 1\n' > "$T/seed/src/c.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm clean && git -C "$T/seed" push -q origin ticket/clean
CLEAN_HEAD=$(git -C "$T/seed" rev-parse HEAD)

# ticket/dirty — edits the same line main is about to edit.
git -C "$T/seed" checkout -q -b ticket/dirty "$BASE"
printf 'A-branch\n' > "$T/seed/src/a.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm dirty && git -C "$T/seed" push -q origin ticket/dirty
DIRTY_HEAD=$(git -C "$T/seed" rev-parse HEAD)

# main moves: src/a.ts (conflicts with ticket/dirty, not with ticket/clean).
git -C "$T/seed" checkout -q main
printf 'A2\n' > "$T/seed/src/a.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm advance && git -C "$T/seed" push -q origin main

# --- a parent that will CLOSE without merging, and three children of it -------
# All three are cut from $BASE explicitly, so what each one CARRIES is the thing
# under test and not an artefact of the order these lines run in.
git -C "$T/seed" checkout -q -b ticket/parent "$BASE"
printf 'export const p = 1\n' > "$T/seed/src/p.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm parent && git -C "$T/seed" push -q origin ticket/parent

# kid-carries: really cut from the parent's branch, so the parent's commit is
# still in it. Retargeting this to main would open the abandoned parent's diff.
git -C "$T/seed" checkout -q -b ticket/kid-carries ticket/parent
printf 'export const k = 1\n' > "$T/seed/src/k.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm kid && git -C "$T/seed" push -q origin ticket/kid-carries
KID_CARRIES=$(git -C "$T/seed" rev-parse HEAD)

# kid-own: the same ticket's work with nothing of the parent in it (a build cut
# from main, or a branch somebody has already rebased). One PATCH from normal.
git -C "$T/seed" checkout -q -b ticket/kid-own "$BASE"
printf 'export const k = 1\n' > "$T/seed/src/k.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm kid-own && git -C "$T/seed" push -q origin ticket/kid-own
KID_OWN=$(git -C "$T/seed" rev-parse HEAD)

# kid-conflict: carries nothing of the parent either, but it edits the line main
# advanced — clean of the parent is not the same as mergeable into main.
git -C "$T/seed" checkout -q -b ticket/kid-conflict "$BASE"
printf 'A-kid\n' > "$T/seed/src/a.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm kid-conflict && git -C "$T/seed" push -q origin ticket/kid-conflict
KID_CONFLICT=$(git -C "$T/seed" rev-parse HEAD)
git -C "$T/seed" checkout -q main

# --- the harness tree --------------------------------------------------------
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
# bin/lib/gh-rest.sh rides with the conductor lib: since BH-784 every decision
# read goes through gh_rest, and without the file the lib's fail-closed shims
# answer "unverifiable" to all of them.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/plan-overlap.sh" "$DIR/bin/planned-files.sh" "$T/h/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
printf '%s %s https://demo.example /api/board 2 box-demo\n' "$PROJ" "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf 'job_verdict_rebind() { return 0; }\n' > "$T/h/bin/jobs-client.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "VERDICT: APPROVE\\n" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"

# The hub clone the conductor prefers. Its origin is rewritten to the fake url
# by mc_funnel_repo, which insteadOf sends straight back here.
git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null

# gh: one PR, approved at its head, DIRTY. PR_FILES / PR_HEAD steer the stubs.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
H="\${PR_HEAD:-$CLEAN_HEAD}"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"api -i -X PATCH repos/"*"/issues/"*) echo "WRITE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  # An empty rate_limit answer leaves bin/lib/gh-budget.sh a 0-byte cache file
  # and a later tick in this scratch tree dies on it.
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pr list -R $SLUG --state open"*)
    jq -nc --arg h "\$H" --arg u "$URL" --arg b "\${PR_BRANCH:-ticket/clean}" \
      --arg m "\${PR_MSTATE:-DIRTY}" --arg g "\${PR_MGABLE:-CONFLICTING}" \
      '[{number:21,url:\$u,headRefOid:\$h,headRefName:\$b,baseRefName:"main",isDraft:false,mergeStateStatus:\$m,mergeable:\$g,state:"OPEN",isInMergeQueue:false,labels:[]}]' ;;
  *"pr list"*) echo "" ;;
  # BH-1586: the CI read is gh_rest — a whole HTTP response, REST-shaped runs.
  *"actions/runs"*) restpr --runs 'completed|success' ;;
  # THE DECISION READS ARE REST (BH-784). All three share the pulls path, so the
  # order matters: the paginated FILES list and the diff (told apart by its
  # Accept header) are matched before the plain pull object.
  *"api -i -X GET repos/$SLUG/pulls/21/files"*)
    restpr --raw 200
    jq -nc --args '[\$ARGS.positional[] | {filename:.}]' \${PR_FILES:-src/c.ts} ;;
  *"v3.diff"*) restpr --raw 200; printf '+++ b/src/c.ts\n+const a = 1;\n' ;;
  *"api -i -X GET repos/$SLUG/pulls/21"*)
    restpr OPEN "\$H" "\${PR_BRANCH:-ticket/clean}" main "" "\${PR_MGABLE:-CONFLICTING}" "\${PR_MSTATE:-DIRTY}" operator "" "plain body" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

REC="$T/h/builds/$PROJ-TK-21-202609120021"
mkdir -p "$REC"
echo "PR_CREATED $URL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
touch "$T/h/flags/merge-conductor-actions"

# shellcheck source=/dev/null
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
export MC_REPOS="$T/repos"

echo "== 1. mc_merge_tree: the conflict test that is not a rebase =="

if mc_git_has_merge_tree; then ok; else
  echo "git $(git --version | awk '{print $3}') has no merge-tree --write-tree — the funnel's fallback path is what runs here; skipping section 1"
fi

if mc_git_has_merge_tree; then
  OUT=$(mc_merge_tree "$SLUG" "$PROJ" "$CLEAN_HEAD"); RC=$?
  [ "$RC" = 0 ] && ok || bad "a branch that merges cleanly answered rc $RC ($OUT)"

  OUT=$(mc_merge_tree "$SLUG" "$PROJ" "$DIRTY_HEAD"); RC=$?
  [ "$RC" = 1 ] && ok || bad "a branch that conflicts answered rc $RC ($OUT)"
  grep -q 'src/a.ts' <<<"$OUT" && ok || bad "the conflict answer does not name the conflicting path: $OUT"

  # A sha the remote does not have is "cannot tell", never "clean". Since
  # 2026-09-16 the cannot-tells are numbered so the log can name the cause:
  # rc 3 is "the two sides could not be fetched", which is what an unknown sha
  # is (rc 2 is an old git, rc 4 is merge-tree itself). See
  # tests/merge-tree-fetch-test.sh for the whole contract.
  mc_merge_tree "$SLUG" "$PROJ" 0000000000000000000000000000000000000000 >/dev/null 2>&1
  [ "$?" = 3 ] && ok || bad "an unknown sha must answer rc 3 (could not be fetched), not a verdict"
fi
# An older git is a fallback, not a wrong answer: the guard is what decides.
( PATH="$T/oldgit:$PATH"; mkdir -p "$T/oldgit"
  printf '#!/bin/bash\n[ "$1" = --version ] && { echo "git version 2.30.2"; exit 0; }\nexec /usr/bin/git "$@"\n' > "$T/oldgit/git"
  chmod +x "$T/oldgit/git"
  mc_git_has_merge_tree ) && bad "git 2.30 must not be treated as having merge-tree --write-tree" || ok

echo "== 2. the tick: MERGE_TREE clean leaves the head alone =="

LOG="$T/h/logs/merge-conductor.log"
# The rebase lane is held FULL so the tick logs REBASE_QUEUED instead of
# spawning a detached rebase: a cap of 1 with one running job already seeded.
# (This used to be MC_REBASE_PARALLEL=0 when 0 meant "queue everything"; since
# 2026-09-14 0 means unlimited, so the lever is a real occupied slot.)
hold_rebase_lane() {
  mkdir -p "$T/h/state/merge-conductor/rebase"
  jq -nc --argjson p "$$" --argjson st "$(date +%s)" \
    '{status:"running",pid:$p,started_at:$st,finished_at:0,rc:"-",head_sha:"held",new_head:"-",out_file:"-"}' \
    > "$T/h/state/merge-conductor/rebase/held-slot.json"
}
tick() { hold_rebase_lane
         ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_REPOS="$T/repos" \
            MC_REBASE_PARALLEL=1 MC_RR_PATH="$T/fakebin:$PATH" \
            env "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
          || { echo "tick rc=$? stderr:"; head -5 "$T/tick.err"; }; }
reset_log() { : > "$LOG"; }

if mc_git_has_merge_tree; then
  echo "$CLEAN_HEAD" > "$REC/reviewed-sha"
  reset_log
  tick PR_HEAD="$CLEAN_HEAD" PR_BRANCH=ticket/clean
  grep -q 'MERGE_TREE clean' "$LOG" && ok || { bad "a clean head logged no MERGE_TREE clean"; grep -i 'TK-21\|#21' "$LOG" | head -5; }
  grep -q 'REBASE_SPAWNED\|REBASE_QUEUED' "$LOG" && bad "a clean head still went down the rebase path" || ok

  # The kill flag: byte-for-byte today's path.
  reset_log
  tick PR_HEAD="$CLEAN_HEAD" PR_BRANCH=ticket/clean MC_MERGE_TREE=0
  grep -q 'MERGE_TREE' "$LOG" && bad "MC_MERGE_TREE=0 still ran the conflict test" || ok
  grep -q 'REBASE_SPAWNED\|REBASE_QUEUED' "$LOG" && ok || bad "MC_MERGE_TREE=0 must rebase exactly as before"

  # A real conflict takes today's path, with a line that names the files.
  rm -f "$T/h/state/merge-conductor/attempts.txt"; touch "$T/h/state/merge-conductor/attempts.txt"
  echo "$DIRTY_HEAD" > "$REC/reviewed-sha"
  reset_log
  tick PR_HEAD="$DIRTY_HEAD" PR_BRANCH=ticket/dirty
  grep -q 'MERGE_TREE conflict' "$LOG" && ok || bad "a genuinely conflicting head logged no MERGE_TREE conflict"
  grep -q 'REBASE_SPAWNED\|REBASE_QUEUED' "$LOG" && ok || bad "a genuinely conflicting head must still be rebased"

  # THE CAP. GitHub going on saying DIRTY while git says clean cannot hold a PR
  # forever: the third observation hands it back to the rebase.
  rm -f "$T/h/state/merge-conductor/attempts.txt"; touch "$T/h/state/merge-conductor/attempts.txt"
  echo "$CLEAN_HEAD" > "$REC/reviewed-sha"
  for i in 1 2; do tick PR_HEAD="$CLEAN_HEAD" PR_BRANCH=ticket/clean; done
  reset_log
  tick PR_HEAD="$CLEAN_HEAD" PR_BRANCH=ticket/clean
  grep -q 'trusting GitHub and rebasing' "$LOG" && ok || bad "the MC_MERGE_TREE_MAX cap never fired on the 3rd clean observation"
  grep -q 'REBASE_SPAWNED\|REBASE_QUEUED' "$LOG" && ok || bad "past the cap the rebase must run"
fi

echo "== 3. mc_no_overlap: re-review only when the merge touched our files =="

# A reviewed sha on a branch, then main moves and the branch takes that move.
git -C "$T/seed" checkout -q -b ticket/ov "$BASE"
sed -i '1s/.*/B-branch/' "$T/seed/src/b.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm ov
REVIEWED=$(git -C "$T/seed" rev-parse HEAD)
git -C "$T/seed" push -q origin ticket/ov

# (a) main changes a file the PR does not touch -> the approval still holds.
git -C "$T/seed" checkout -q main
printf 'y\n' >> "$T/seed/docs/x.md"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm "docs only" && git -C "$T/seed" push -q origin main
git -C "$T/seed" checkout -q ticket/ov && git -C "$T/seed" merge -q --no-edit main >/dev/null 2>&1
HEAD_OK=$(git -C "$T/seed" rev-parse HEAD); git -C "$T/seed" push -q origin ticket/ov
git -C "$T/repos/$PROJ" fetch -q origin

OUT=$(PR_FILES="src/b.ts" mc_no_overlap "$SLUG" "$PROJ" 21 "$URL" "$REVIEWED" "$HEAD_OK"); RC=$?
[ "$RC" = 0 ] && ok || bad "a merge that touched only docs/x.md must be rebindable (rc $RC)"
grep -q 'docs/x.md' <<<"$OUT" && ok || bad "the rebind line does not say what landed: $OUT"

# (b) main changes a file the PR DOES touch -> today's re-review.
git -C "$T/seed" checkout -q main
sed -i '20s/.*/B-main/' "$T/seed/src/b.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm "main edits b" && git -C "$T/seed" push -q origin main
git -C "$T/seed" checkout -q ticket/ov && git -C "$T/seed" merge -q --no-edit main >/dev/null 2>&1
HEAD_HIT=$(git -C "$T/seed" rev-parse HEAD); git -C "$T/seed" push -q origin ticket/ov
git -C "$T/repos/$PROJ" fetch -q origin
PR_FILES="src/b.ts" mc_no_overlap "$SLUG" "$PROJ" 21 "$URL" "$REVIEWED" "$HEAD_HIT" >/dev/null 2>&1
[ "$?" != 0 ] && ok || bad "a merge that touched src/b.ts — a file this PR edits — must NOT be rebound"

# (c) somebody pushed a real commit -> today's re-review, whatever main did.
git -C "$T/seed" checkout -q ticket/ov
printf 'export const d = 1\n' > "$T/seed/src/d.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm "a new commit"
HEAD_PUSH=$(git -C "$T/seed" rev-parse HEAD); git -C "$T/seed" push -q origin ticket/ov
git -C "$T/repos/$PROJ" fetch -q origin
PR_FILES="src/b.ts" mc_no_overlap "$SLUG" "$PROJ" 21 "$URL" "$REVIEWED" "$HEAD_PUSH" >/dev/null 2>&1
[ "$?" != 0 ] && ok || bad "a head carrying a NEW commit must never be rebound as a no-overlap merge"

# The file list is cached per (PR, head) — the same head must not buy a second
# read of the PR's files (BH-784: that read is now GET /pulls/21/files). The
# pattern is main's own superset: any /files call plus the GraphQL spelling
# (BH-587 review round 1), so a reader that went back to either is caught here
# rather than counted as zero.
: > "$T/gh-calls.txt"
PR_FILES="src/b.ts" mc_pr_files "$SLUG" 21 "$URL" "$HEAD_OK" >/dev/null 2>&1
PR_FILES="src/b.ts" mc_pr_files "$SLUG" 21 "$URL" "$HEAD_OK" >/dev/null 2>&1
[ "$(grep -cE -- '/files|--json files' "$T/gh-calls.txt" || true)" -le 1 ] && ok \
  || bad "the PR file list is not cached per head — $(grep -cE -- '/files|--json files' "$T/gh-calls.txt") API calls for one head"

# ...and the same answer through a whole tick. The patch-id rebind runs FIRST
# and catches the pure-rebase case on its own, so the stored id for the reviewed
# sha is made stale here — which is exactly the shape NO_OVERLAP exists for: the
# patch is not provably identical, and the files say it does not matter.
echo "$REVIEWED" > "$REC/reviewed-sha"
printf 'notthepatchid\n' > "$REC/patch-id.$REVIEWED"
rm -f "$T/h/state/merge-conductor/attempts.txt"; touch "$T/h/state/merge-conductor/attempts.txt"
reset_log
tick PR_HEAD="$HEAD_OK" PR_BRANCH=ticket/ov PR_MSTATE=CLEAN PR_MGABLE=MERGEABLE PR_FILES=src/b.ts
grep -q 'NO_OVERLAP rebound' "$LOG" && ok || { bad "the tick bought a re-review for a merge that touched none of this PR's files"; grep '#21' "$LOG" | head -4; }
grep -q 'REREVIEW_SPAWNED' "$LOG" && bad "a rebound approval must not also buy a re-review" || ok
[ "$(cat "$REC/reviewed-sha")" = "$HEAD_OK" ] && ok || bad "the approval was not rebound onto the new head"
grep -q 'no file overlap with what landed' "$REC/rebind.log" && ok || bad "the rebind was not written to the record's rebind.log"

# The kill flag: today's detached re-review, unchanged.
echo "$REVIEWED" > "$REC/reviewed-sha"
printf 'notthepatchid\n' > "$REC/patch-id.$REVIEWED"
rm -f "$T/h/state/merge-conductor/attempts.txt"; touch "$T/h/state/merge-conductor/attempts.txt"
reset_log
tick PR_HEAD="$HEAD_OK" PR_BRANCH=ticket/ov PR_MSTATE=CLEAN PR_MGABLE=MERGEABLE PR_FILES=src/b.ts MC_OVERLAP_REREVIEW=0
grep -q 'NO_OVERLAP' "$LOG" && bad "MC_OVERLAP_REREVIEW=0 still ran the overlap rebind" || ok
grep -q 'REREVIEW_SPAWNED\|REREVIEW_QUEUED' "$LOG" && ok || bad "MC_OVERLAP_REREVIEW=0 must buy the re-review exactly as before"

echo "== 4. bin/plan-overlap.sh: two plans, one file =="

PO="$T/h/bin/plan-overlap.sh"
mkplan() { # mkplan <dir> <key> <file>...
  local d="$T/h/builds/$1" k="$2"; shift 2
  mkdir -p "$d"
  { echo "# plan"; for f in "$@"; do echo "- edit $f"; done; } > "$d/plan.md"
  printf '%s\n' "$@" > "$d/planned-files.txt"
  printf '{"key":"%s"}\n' "$k" > "$d/ticket-meta.json"
  printf '%s' "$d"
}
A=$(mkplan "$PROJ-K1-202609140001" K1 src/lib/pricing/rates.ts src/app/x/page.tsx)
B=$(mkplan "$PROJ-K2-202609140002" K2 src/lib/pricing/rates.ts)
C=$(mkplan "$PROJ-K3-202609140003" K3 src/app/other/page.tsx)

OUT=$("$PO" "$PROJ" "$B/plan.md"); RC=$?
[ "$RC" = 1 ] && ok || bad "two plans naming src/lib/pricing/rates.ts must not co-build (rc $RC)"
grep -qE '^OVERLAP_DEFER K2 vs K1 files=\[.*rates\.ts.*\]$' <<<"$OUT" && ok \
  || bad "the defer line is not the documented shape: $OUT"

OUT=$("$PO" "$PROJ" "$C/plan.md"); RC=$?
[ "$RC" = 0 ] && ok || bad "a disjoint plan must build (rc $RC, $OUT)"

# The kill flag, both spellings.
OVERLAP_SCHED=0 "$PO" "$PROJ" "$B/plan.md" >/dev/null 2>&1 && ok || bad "OVERLAP_SCHED=0 must be a no-op"
touch "$T/h/flags/plan-overlap-off"
"$PO" "$PROJ" "$B/plan.md" >/dev/null 2>&1 && ok || bad "flags/plan-overlap-off must be a no-op"
rm -f "$T/h/flags/plan-overlap-off"

# A FINISHED sibling is not in flight.
echo "PR_CREATED x" > "$A/RESULT"
"$PO" "$PROJ" "$B/plan.md" >/dev/null 2>&1 && ok || bad "a sibling with a RESULT is finished and must not defer anything"
rm -f "$A/RESULT"

# The claims ledger is the other half: a build whose directory this box cannot
# see is still visible through state/claims/<project>/<KEY>.
scratch_rm "$A"
mkdir -p "$T/h/state/claims/$PROJ"
printf 'src/lib/pricing/rates.ts\n' > "$T/h/state/claims/$PROJ/K9"
OUT=$("$PO" "$PROJ" "$B/plan.md"); RC=$?
[ "$RC" = 1 ] && grep -q 'vs K9' <<<"$OUT" && ok || bad "a claims-ledger sibling was not seen (rc $RC, $OUT)"

# ...and the QUEUE is what says a claim is dead. A claim whose row is no longer
# claimed must not defer anything.
cat > "$T/h/bin/jobs-client.sh" <<'JC'
job_verdict_rebind() { return 0; }
queue_list() { printf '%s\tK7\t-\tclaimed\tfly\t0\tbox\t-\t-\t-\n' "$1"; }
JC
OUT=$("$PO" "$PROJ" "$B/plan.md"); RC=$?
[ "$RC" = 0 ] && ok || bad "a claim the queue no longer holds must be ignored (rc $RC, $OUT)"
cat > "$T/h/bin/jobs-client.sh" <<'JC'
job_verdict_rebind() { return 0; }
queue_list() { printf '%s\tK9\t-\tclaimed\tfly\t0\tbox\t-\t-\t-\n' "$1"; }
JC
"$PO" "$PROJ" "$B/plan.md" >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "a claim the queue DOES hold must still defer"
printf 'job_verdict_rebind() { return 0; }\n' > "$T/h/bin/jobs-client.sh"

# THE DIRECTORY ENTRY (project-5 TK-667/669, 2026-09-14). A pre-plan names both
# the migrations directory and the file it adds under it, so the bare directory
# used to collide with every sibling's migration — two builds that touch two
# different new files deferred on a path neither of them shares. The directory
# entry is dropped when the SAME list also names a file under it.
M1=$(mkplan "$PROJ-M1-202609140011" M1 prisma/migrations/manual prisma/migrations/manual/2026-09-14-TK-667-team-chart-max-members.sql)
M2=$(mkplan "$PROJ-M2-202609140012" M2 prisma/migrations/manual prisma/migrations/manual/2026-09-14-TK-669-hat-merge-knobs.sql)
OUT=$("$PO" "$PROJ" "$M2/plan.md"); RC=$?
[ "$RC" = 0 ] && ok || bad "two different new migrations in one directory must co-build (rc $RC, $OUT)"
# ...and the same two lists through bin/lib/dep-verify-lib.sh, because a second
# spelling of this rule is a child built on main that conflicts at merge time.
# shellcheck source=bin/lib/dep-verify-lib.sh
. "$DIR/bin/lib/dep-verify-lib.sh"
[ -z "$(dep_overlap "$M1/planned-files.txt" "$M2/planned-files.txt")" ] && ok \
  || bad "dep_overlap and plan-overlap.sh must answer the same: $(dep_overlap "$M1/planned-files.txt" "$M2/planned-files.txt")"
# a directory named ALONE still contains everything under it
M3=$(mkplan "$PROJ-M3-202609140013" M3 prisma/migrations/manual)
OUT=$("$PO" "$PROJ" "$M2/plan.md"); RC=$?
[ "$RC" = 1 ] && grep -q 'vs M3' <<<"$OUT" && ok \
  || bad "a bare directory scope must still contain a sibling's file under it (rc $RC, $OUT)"
[ -n "$(dep_overlap "$M3/planned-files.txt" "$M2/planned-files.txt")" ] && ok \
  || bad "dep_overlap must keep the directory-alone rule too"
scratch_rm "$M1"; scratch_rm "$M2"; scratch_rm "$M3"

# No plan data is not an overlap: an unjudgeable build is built, as before.
D=$(mkplan "$PROJ-K4-202609140004" K4 src/lib/pricing/rates.ts)
: > "$D/planned-files.txt"; : > "$D/plan.md"
"$PO" "$PROJ" "$D/plan.md" >/dev/null 2>&1 && ok || bad "a build with no plan data must not be deferred"

echo "== 5. bin/run-build.sh: one hook point, and a not-before that is honoured =="

RB="$RB_ALL"
NCALL=$(grep -c 'bin/plan-overlap\.sh" "\$PROJECT"' "$RB")
[ "$NCALL" = 1 ] && ok \
  || bad "plan-overlap.sh is invoked from $NCALL places in run-build.sh — the contract is exactly one"
# THESE FIVE READ A REGION, NOT A PIPELINE (fixed 2026-09-21, BH-1036 r1). They
# used to be `sed -n '/>>> x/,/<<< x/p' "$RB" | grep -q PAT`, which is a latent
# false negative under this file's `set -o pipefail`: `grep -q` exits on the
# FIRST match, sed is killed with SIGPIPE while it still has lines to write, and
# the pipeline's rc becomes 141 — so the assertion fails EXACTLY when the
# pattern matches early in a long region. It did: BH-1036 grew the not-before
# region past 70 lines with OVERLAP_SCHED near its top and turned a true
# statement into `FAIL: the not-before gate is not behind the kill flag`. The
# region goes into a variable first; the questions asked are unchanged.
RB_PLAN_HOOK=$(sed -n '/^# >>> plan overlap/,/^# <<< plan overlap/p' "$RB")
RB_NOTBEFORE=$(sed -n '/^# >>> overlap not-before/,/^# <<< overlap not-before/p' "$RB")
[ -n "$RB_PLAN_HOOK" ] && ok || bad "the plan-overlap hook region is not in the pipeline text at all"
[ -n "$RB_NOTBEFORE" ] && ok || bad "the not-before region is not in the pipeline text at all"
grep -q 'BUILD/plan.md' <<<"$RB_PLAN_HOOK" && ok \
  || bad "the hook does not hand plan-overlap.sh the plan"
grep -q 'RESULT "BUILD_DEFERRED' <<<"$RB_PLAN_HOOK" && ok \
  || bad "the hook does not end in a BUILD_DEFERRED terminal"
grep -q 'state/overlap-defer' <<<"$RB_PLAN_HOOK" && ok \
  || bad "the hook writes no not-before marker"
grep -q 'OVERLAP_SCHED' <<<"$RB_NOTBEFORE" && ok \
  || bad "the not-before gate is not behind the kill flag"
# The gate itself, run as its own script: inside the window it defers, outside it
# builds, and it consumes the marker on the way through.
GATE="$T/gate.sh"
{ echo 'set -uo pipefail'; echo 'RESULT() { printf "%s\n" "$*" > "$T_RES"; }'
  sed -n '/^# >>> overlap not-before/,/^# <<< overlap not-before/p' "$RB"; echo 'echo BUILT'; } > "$GATE"
bash -n "$GATE" && ok || bad "the extracted not-before gate is not valid bash"
mkdir -p "$T/h/state/overlap-defer/$PROJ"
echo "$(( $(date -u +%s) + 300 ))" > "$T/h/state/overlap-defer/$PROJ/K2"
OUT=$(HARNESS="$T/h" PROJECT="$PROJ" KEY=K2 T_RES="$T/res.txt" bash "$GATE"); RC=$?
[ "$RC" = 3 ] && ok || bad "a key inside its not-before window must exit 3, got $RC ($OUT)"
grep -q 'BUILD_DEFERRED plan overlap not-before' "$T/res.txt" && ok \
  || bad "the not-before terminal is not the documented one: $(cat "$T/res.txt" 2>/dev/null)"
echo "$(( $(date -u +%s) - 10 ))" > "$T/h/state/overlap-defer/$PROJ/K2"
OUT=$(HARNESS="$T/h" PROJECT="$PROJ" KEY=K2 T_RES="$T/res.txt" bash "$GATE"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = BUILT ] && ok || bad "an expired not-before must build (rc $RC, $OUT)"
[ -e "$T/h/state/overlap-defer/$PROJ/K2" ] && bad "an expired marker must be consumed" || ok
echo "$(( $(date -u +%s) + 300 ))" > "$T/h/state/overlap-defer/$PROJ/K2"
OUT=$(HARNESS="$T/h" PROJECT="$PROJ" KEY=K2 OVERLAP_SCHED=0 T_RES="$T/res.txt" bash "$GATE"); RC=$?
[ "$RC" = 0 ] && ok || bad "OVERLAP_SCHED=0 must ignore the marker entirely (rc $RC)"

echo "== 6. mc_orphan_clean: the parent CLOSED without merging (2026-09-16) =="

# THE INCIDENT. bin/blocked-resolver.sh closed project-5 #1556 at 09:35Z on
# 2026-09-16 to rebuild TK-1529 fresh, and #1586/#1585/#1587 — all cut from
# ticket/TK-1529 — were left based on a branch nothing would ever merge. The
# conductor had an event for a parent that MERGES and none for one that CLOSES,
# so all three parked on `parent-closed`, a reason no lane owns, and stopped.
#
# Driven against the real repository above, because every claim here is about
# what git actually answers: which commits a branch carries, and whether it
# merges into main. A stub would only prove the shell is spelled right.
if mc_git_has_merge_tree; then
  OUT=$(mc_orphan_clean "$SLUG" "$PROJ" main ticket/parent "$KID_OWN"); RC=$?
  [ "$RC" = 0 ] && ok || bad "a child that carries nothing of the closed parent and merges into main must be retargetable (rc $RC: $OUT)"
  grep -q 'cleanly' <<<"$OUT" && ok || bad "the clean answer must say what it checked, for the log line (got: $OUT)"

  OUT=$(mc_orphan_clean "$SLUG" "$PROJ" main ticket/parent "$KID_CARRIES"); RC=$?
  [ "$RC" = 1 ] && ok || bad "a child that still carries the closed parent's commits must NOT be retargeted — that opens the abandoned parent's diff under the child's number (rc $RC: $OUT)"
  grep -q 'carries 1 commit' <<<"$OUT" && ok || bad "the refusal must name how much of the parent is still in the branch (got: $OUT)"

  # Carrying nothing of the parent is only half of it: this one is clean of the
  # parent and still conflicts with what main did while it sat there.
  OUT=$(mc_orphan_clean "$SLUG" "$PROJ" main ticket/parent "$KID_CONFLICT"); RC=$?
  [ "$RC" = 1 ] && ok || bad "a child that conflicts with main must go to the resolver, not to a retarget (rc $RC: $OUT)"
  grep -q 'src/a.ts' <<<"$OUT" && ok || bad "the conflict answer must name the path (got: $OUT)"

  # THE PARENT BRANCH IS GONE. Whoever tidied up after the close took the only
  # witness to what the child still carries with them. That is a hand-off, not a
  # wait — a branch that will never come back must not be waited for.
  OUT=$(mc_orphan_clean "$SLUG" "$PROJ" main ticket/never-existed "$KID_OWN"); RC=$?
  [ "$RC" = 1 ] && ok || bad "a parent branch that is gone from origin must be handed to the resolver, never waited on (rc $RC: $OUT)"
  grep -q 'gone from origin' <<<"$OUT" && ok || bad "and it must say so (got: $OUT)"
fi

# EVERY UNKNOWN IS rc 2, AND rc 2 CHANGES NOTHING. These four are the ways this
# box can fail to answer, and not one of them may read as "clean" (which would
# retarget a branch nobody looked at) or as "dirty" (which would buy an agent
# fix round on a branch that is fine).
OUT=$(mc_orphan_clean "$SLUG" "$PROJ" main ticket/parent -); RC=$?
[ "$RC" = 2 ] && ok || bad "no head sha must answer rc 2 (got rc $RC: $OUT)"
OUT=$(mc_orphan_clean "$SLUG" "$PROJ" main 'ticket/../../etc; rm -rf /' "$KID_OWN"); RC=$?
[ "$RC" = 2 ] && ok || bad "an unsafe branch name must be refused before it reaches git (got rc $RC: $OUT)"
OUT=$(mc_orphan_clean "$SLUG" "$PROJ" main --upload-pack=evil "$KID_OWN"); RC=$?
[ "$RC" = 2 ] && ok || bad "a ref starting with - must be refused (got rc $RC: $OUT)"
OUT=$(mc_orphan_clean "$SLUG" "$PROJ" main main "$KID_OWN"); RC=$?
[ "$RC" = 2 ] && ok || bad "a parent branch equal to the base is not a stack at all (got rc $RC: $OUT)"
OUT=$(mc_orphan_clean "$SLUG" "$PROJ" main ticket/parent 0000000000000000000000000000000000000000); RC=$?
[ "$RC" = 2 ] && ok || bad "a head the remote does not have must answer rc 2, never a verdict (got rc $RC: $OUT)"

# READ-ONLY, like everything else in this funnel: no ref written on the child or
# the parent, no branch pushed, and no gh WRITE bought to answer the question.
PH=$(git -C "$T/repos/$PROJ" rev-parse refs/remotes/origin/ticket/parent 2>/dev/null)
[ "$PH" = "$(git -C "$T/seed" rev-parse ticket/parent)" ] \
  && ok || bad "mc_orphan_clean must not move the parent's ref"
[ ! -s "$T/gh-writes.txt" ] && ok || bad "mc_orphan_clean must buy no gh write (got: $(cat "$T/gh-writes.txt"))"

# The reason word has to reach the lane that owns it, or this is a nicer park
# and nothing else. #1586/#1585/#1587 sat on `parent-closed` precisely because
# mc_resolver_owns did not know it.
mc_resolver_owns 'orphaned-child: the PR this one is stacked on (ticket/parent) closed without merging' \
  && ok || bad "orphaned-child must be a reason bin/blocked-resolver.sh owns"
mc_resolver_owns parent-closed \
  && bad "parent-closed must stay unowned: it is the word for a tick that could NOT read the branch, and a fix round on it would be a guess" || ok
H0=aaaaaaaa1111
[ "$(MC_STACK=parent-closed-orphan MC_STACK_BASE=ticket/parent mc_classify OPEN CLEAN MERGEABLE $H0 $H0 APPROVE claude green 0 0 0 0 - - | cut -f1)" = BLOCKED_HUMAN ] \
  && ok || bad "an orphaned child must park"
[ "$(mc_state_display BLOCKED_HUMAN "$(MC_STACK=parent-closed-orphan MC_STACK_BASE=ticket/parent mc_classify OPEN CLEAN MERGEABLE $H0 $H0 APPROVE claude green 0 0 0 0 - - | cut -f2)")" = BLOCKED_AGENT ] \
  && ok || bad "and it must DISPLAY as BLOCKED_AGENT — the work is with the resolver, not with a person"

echo
echo "merge-funnel: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
