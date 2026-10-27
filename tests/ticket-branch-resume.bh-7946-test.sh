#!/bin/bash
# tests/ticket-branch-resume.bh-7946-test.sh — a pool build that finds its own
# ticket branch on origin with no PR resumes it, and is not refused (BH-7946).
#
# THE INCIDENT (BH-7519, PR #7852 body). The pool cut ticket/bh-7519 at 14:59Z
# when the name was free. A Mac session created the same name at 15:40Z. The
# finished build pushed with lease "new", the remote refused it, the reap wrote
# a push-rejected terminal, and the stranded watch held the ticket for a human.
#
#   C1-C15  tbr_commit_own: the key in the subject, the body, lower case, a
#           ticket/<key> mention and a .harness/specs/<KEY>/ path are own; a
#           longer key, a shorter key, a .N child key, another ticket, the key
#           only in the author, a near-miss spec path are not; a merge is rc 2
#   V1-V14  tbr_classify, one case per row of its order: tracked, ls-remote
#           error, absent, dirty tree, fetch error, PR read error, open PR,
#           ancestor, shallow (unshallowed ONCE, then classified), no
#           merge-base, nothing past the base, all own, one foreign tip, one
#           foreign commit under own ones, own with a main merge in it
#   R1      THE REPRODUCTION: the real `# >>> ticket branch resume`,
#           `# >>> rebase verify` and `# >>> pr push` blocks of bin/lib/rb/pr.sh
#           with the real RB_PUSH -> hold_push. The build resumes the remote
#           branch, merges main, and the push is a fast-forward
#   A1      the remote head is already in HEAD: the lease is that sha, no resume
#   F1      the main merge conflicts: the remote head is pushed unchanged
#   F2      a foreign commit: refused, exit 3, the RESULT names it, remote unchanged
#   N1      a published head that lost the remote sha: exit 3, hold_push never runs
#   P1      the BH-6821 reap reads a suffixed rejected line
#   X1      the lib has no push, no force and no delete in it
#
# Every case has its own bare origin and clones under $T. The gh on PATH is a
# fake that answers the pulls read from a per-case file. Exit 0 = pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/ticket-branch-resume.sh"
# shellcheck source=bin/lib/ticket-branch-resume.sh
[ -r "$LIB" ] && . "$LIB"
command -v tbr_classify >/dev/null 2>&1 && ok || bad "bin/lib/ticket-branch-resume.sh does not define tbr_classify"

export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_DATE='2026-10-22T01:00:00Z' GIT_COMMITTER_DATE='2026-10-22T01:00:00Z'
# The product's own `git merge` (the rebase verify block) commits too: give it
# an identity so the suite does not depend on the runner's global git config.
export GIT_AUTHOR_NAME='Pool Builder' GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME='Pool Builder' GIT_COMMITTER_EMAIL=fixture@example.invalid
gitc() {
  local an="${AN:-Pool Builder}"
  GIT_AUTHOR_NAME="$an" GIT_COMMITTER_NAME="$an" GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$1" -c commit.gpgsign=false "${@:2}"
}
# CM <repo> <message> [<file> [<text>]] — one commit; prints its sha.
CM() {
  local f="${3:-f.txt}"
  mkdir -p "$(dirname "$1/$f")"; printf '%s\n' "${4:-$2}" >> "$1/$f"
  git -C "$1" add -A && gitc "$1" commit -qm "$2" && git -C "$1" rev-parse HEAD
}

# The fake gh: $TBR_PULLS holds the answer (a number, or `fail`).
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${TBR_GH_LOG:-/dev/null}"
a=$(cat "${TBR_PULLS:-/nonexistent}" 2>/dev/null)
[ "$a" = fail ] && { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
printf '%s\n' "$a"
SH
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# ── C: tbr_commit_own ──────────────────────────────────────────────────────
C="$T/c"; git init -q "$C"; CM "$C" base >/dev/null
own() { ( cd "$C" && tbr_commit_own "$1" "$2" 2>/dev/null ); echo $?; }
chk() { local want="$1" name="$2" key="$3" sha="$4" got; got=$(own "$key" "$sha"); [ "$got" = "$want" ] && ok || bad "$name: tbr_commit_own $key = rc $got, want $want"; }
chk 0 "C1 subject 'BH-7946: fix the push'"   BH-7946 "$(CM "$C" 'BH-7946: fix the push')"
chk 0 "C2 key only in the body"               BH-7946 "$(CM "$C" $'tidy the push\n\nRefs BH-7946')"
chk 0 "C3 lower case 'bh-7946 wip'"           BH-7946 "$(CM "$C" 'bh-7946 wip')"
chk 0 "C4 'merge ticket/bh-7946 into main'"   BH-7946 "$(CM "$C" 'merge ticket/bh-7946 into main')"
chk 0 "C5 a neutral subject on .harness/specs/BH-7946/" BH-7946 "$(CM "$C" 'spec: plan' .harness/specs/BH-7946/plan.md)"
chk 0 "C6 the #7852 shape 'BH-7519: …' for BH-7519" BH-7519 "$(CM "$C" 'BH-7519: resume the stranded build')"
chk 1 "C7 a longer key BH-79460"              BH-7946 "$(CM "$C" 'BH-79460: x')"
chk 1 "C8 a shorter key BH-794"               BH-7946 "$(CM "$C" 'BH-794: x')"
chk 1 "C9 the child key BH-7946.2"            BH-7946 "$(CM "$C" 'BH-7946.2: child slice')"
chk 1 "C10 'fix typo' by another author"      BH-7946 "$(AN='Other Person' CM "$C" 'fix typo')"
chk 1 "C11 another ticket's key"              BH-7946 "$(CM "$C" 'BH-7519: other ticket')"
chk 1 "C12 a near-miss spec path"             BH-7946 "$(CM "$C" 'spec: plan' .harness/specs/BH-79460/plan.md)"
chk 1 "C13 the key only in the author"        BH-7946 "$(AN='BH-7946 Bot' CM "$C" 'tidy')"
chk 0 "C14 the key then a full stop"          BH-7946 "$(CM "$C" 'Closes BH-7946.')"
git -C "$C" checkout -qb side HEAD~1; CM "$C" 'BH-7946: side' side.txt >/dev/null; git -C "$C" checkout -q -; gitc "$C" merge -q --no-ff --no-edit side
chk 2 "C15 a merge commit is skipped"         BH-7946 "$(git -C "$C" rev-parse HEAD)"

# ── V: tbr_classify ────────────────────────────────────────────────────────
# mk <name> — $R/origin.git with 4 main commits, $R/seed (a full clone) and
# $R/pool (a single-branch clone of main, the pool shape; POOL_DEPTH=<n> makes
# it shallow). Sets R.
mk() {
  R="$T/$1"; mkdir -p "$R"
  git init -q --bare "$R/origin.git"
  git clone -q "$R/origin.git" "$R/seed" 2>/dev/null
  git -C "$R/seed" symbolic-ref HEAD refs/heads/main
  local i; for i in 1 2 3 4; do CM "$R/seed" "main $i" "m$i.txt" >/dev/null; done
  git -C "$R/seed" push -q origin HEAD:refs/heads/main
  git -C "$R/origin.git" symbolic-ref HEAD refs/heads/main
}
pool() { # pool [<depth>] — clone, cut the ticket branch from main, build one commit
  git clone -q ${1:+--depth "$1"} --single-branch --branch main "file://$R/origin.git" "$R/pool" 2>/dev/null
  git -C "$R/pool" checkout -qb "$BR"
  BUILT=$(CM "$R/pool" "$KEY_U: built by the pool" built.txt)
}
# rbranch <start> <msg>... — the other writer's branch: from <start> in seed, one
# commit per message (AN= sets the author), sent to origin. Prints the tip.
rbranch() {
  local start="$1"; shift
  git -C "$R/seed" checkout -q -B "$BR" "$start"
  local m; for m in "$@"; do CM "$R/seed" "$m" >/dev/null; done
  git -C "$R/seed" push -q -f origin "$BR:refs/heads/$BR"
  git -C "$R/seed" rev-parse HEAD
  git -C "$R/seed" checkout -q main
}
main_more() { # main_more <n> [<author>] — main moves on in seed
  local i; for i in $(seq 1 "$1"); do AN="${2:-Pool Builder}" CM "$R/seed" "main later $i" "later$i.txt" >/dev/null; done
  git -C "$R/seed" push -q origin main
}
classify() { ( cd "$R/pool" && tbr_classify "$BR" "$KEY_U" origin/main o/tproj 2>/dev/null ); }
verdict() { classify | cut -f1; }
export TBR_PULLS="$T/pulls"; echo 0 > "$TBR_PULLS"
KEY_U=BH-9101; BR=ticket/bh-9101

mk v1; pool; git -C "$R/pool" update-ref "refs/remotes/origin/$BR" "$BUILT"
[ "$(verdict)" = tracked ] && ok || bad "V1 a tracked branch is 'tracked' (no read): $(classify)"
mk v2; pool; git -C "$R/pool" remote set-url origin "$T/no-such-origin.git"
[ "$(classify | cut -f1,3)" = $'unreadable\tls-remote' ] && ok || bad "V2 an ls-remote error is unreadable ls-remote: $(classify)"
mk v3; pool
[ "$(verdict)" = absent ] && ok || bad "V3 no branch on origin is 'absent': $(classify)"
mk v4; pool; rbranch main 'BH-9101: mac work' >/dev/null; echo dirty >> "$R/pool/built.txt"
[ "$(classify | cut -f1,3)" = $'unreadable\tdirty-tree' ] && ok || bad "V4 a dirty tree is unreadable dirty-tree: $(classify)"
mk v5; pool; rbranch main 'BH-9101: mac work' >/dev/null
V5=$( cd "$R/pool" && git() { [ "$1" = fetch ] && return 1; command git "$@"; }; tbr_classify "$BR" "$KEY_U" origin/main o/tproj 2>/dev/null )
[ "$(cut -f1,3 <<<"$V5")" = $'unreadable\tfetch' ] && ok || bad "V5 a failed fetch is unreadable fetch: $V5"
mk v6; pool; rbranch main 'BH-9101: mac work' >/dev/null; echo fail > "$TBR_PULLS"
[ "$(classify | cut -f1,3)" = $'unreadable\tpr-read' ] && ok || bad "V6 a 500 on the PR read is unreadable pr-read: $(classify)"
echo 1 > "$TBR_PULLS"
[ "$(verdict)" = open-pr ] && ok || bad "V6b an open PR is 'open-pr': $(classify)"
: > "$T/gh.log"; TBR_GH_LOG="$T/gh.log" classify >/dev/null
grep -q '^api repos/o/tproj/pulls?head=o:ticket/bh-9101&state=open&per_page=1 --jq length$' "$T/gh.log" && ok \
  || bad "V6c the PR read is the REST pulls read: $(cat "$T/gh.log")"
echo 0 > "$TBR_PULLS"
mk v7; pool; git -C "$R/pool" push -q origin "HEAD:refs/heads/$BR"; CM "$R/pool" 'BH-9101: one more' >/dev/null
[ "$(verdict)" = ancestor ] && ok || bad "V7 a remote head already in HEAD is 'ancestor': $(classify)"
# V8: a shallow pool clone whose branch forks below the boundary.
mk v8; FORK=$(git -C "$R/seed" rev-parse HEAD~3); main_more 6; pool 3
RTIP=$(rbranch "$FORK" 'BH-9101: mac 1' 'BH-9101: mac 2')
GIT_TRACE="$T/v8.trace" classify > "$T/v8.out"
[ "$(cut -f1,2,3 "$T/v8.out")" = "own	$RTIP	commits=2" ] && ok || bad "V8 the shallow clone is unshallowed and classified own: $(cat "$T/v8.out")"
[ "$(grep -c 'built-in: git fetch -q --unshallow origin' "$T/v8.trace")" = 1 ] && ok \
  || bad "V8 exactly one --unshallow fetch: $(grep -c unshallow "$T/v8.trace") ($(grep unshallow "$T/v8.trace"))"
# V9: unrelated history, in a shallow clone: one unshallow, still no merge-base.
mk v9; main_more 4; pool 2
git -C "$R/seed" checkout -q --orphan "$BR"; git -C "$R/seed" rm -rq --cached . ; CM "$R/seed" 'BH-9101: orphan' >/dev/null
git -C "$R/seed" push -q -f origin "$BR:refs/heads/$BR"; git -C "$R/seed" checkout -qf main
GIT_TRACE="$T/v9.trace" classify > "$T/v9.out"
[ "$(cut -f1,3 "$T/v9.out")" = $'unreadable\tno-merge-base' ] && ok || bad "V9 no merge-base after the unshallow is unreadable: $(cat "$T/v9.out")"
[ "$(grep -c 'built-in: git fetch -q --unshallow origin' "$T/v9.trace")" = 1 ] && ok || bad "V9 the unshallow ran once: $(grep -c unshallow "$T/v9.trace")"
# V10: the remote name points at a main commit the build does not have.
mk v10; pool; main_more 1; rbranch main >/dev/null
[ "$(verdict)" = ancestor-of-base ] && ok || bad "V10 nothing past the base is 'ancestor-of-base': $(classify)"
mk v11; pool; RTIP=$(rbranch main 'BH-9101: mac 1' 'spec: plan for bh-9101')
[ "$(classify)" = "own	$RTIP	commits=2" ] && ok || bad "V11 two own commits are 'own': $(classify)"
mk v12; pool; git -C "$R/seed" checkout -q -B "$BR" main; CM "$R/seed" 'BH-9101: mac 1' >/dev/null
FOREIGN=$(AN='Other Person' CM "$R/seed" 'fix typo'); git -C "$R/seed" push -q origin "$BR:refs/heads/$BR"; git -C "$R/seed" checkout -q main
[ "$(classify)" = "foreign	$FOREIGN	first=$FOREIGN by Other Person" ] && ok || bad "V12 a foreign tip is 'foreign' with its sha and author: $(classify)"
# V13: the near miss — most commits are own, the foreign one is buried.
mk v13; pool; git -C "$R/seed" checkout -q -B "$BR" main; CM "$R/seed" 'BH-9101: mac 1' >/dev/null
FOREIGN=$(AN='Other Person' CM "$R/seed" 'refactor the loader'); CM "$R/seed" 'BH-9101: mac 2' >/dev/null
git -C "$R/seed" push -q origin "$BR:refs/heads/$BR"; git -C "$R/seed" checkout -q main
[ "$(classify | cut -f1,3)" = "foreign	first=$FOREIGN by Other Person" ] && ok || bad "V13 one foreign commit under two own ones is 'foreign': $(classify)"
# V14: the other writer merged a newer main in. The pool's origin/main is stale,
# so main's commits must not read as foreign: the classifier fetches the base.
mk v14; pool; main_more 2 'Other Person'
git -C "$R/seed" checkout -q -B "$BR" main~2; CM "$R/seed" 'BH-9101: mac 1' >/dev/null
gitc "$R/seed" merge -q --no-edit main; git -C "$R/seed" push -q origin "$BR:refs/heads/$BR"; git -C "$R/seed" checkout -q main
[ "$(classify | cut -f1,3)" = $'own\tcommits=1' ] && ok || bad "V14 own work with a main merge in it is 'own' (main's commits are not foreign): $(classify)"

# ── R / A / F / N: the PR stage, through the real blocks ───────────────────
blk() { awk -v b="# >>> $1" -v e="# <<< ${2:-$1}" 'index($0, b) == 1 {on=1} on {print} on && index($0, e) == 1 {exit}' "$DIR/bin/lib/rb/pr.sh"; }
fn() { awk -v f="$1(){" 'index($0, f) == 1 {on=1} on {print} on && /^}/ {exit}' "$DIR/bin/lib/rb/gates.sh"; }
H="$T/h"; mkdir -p "$H/bin/lib"
scratch_install_closure bin/lib/hold-push.sh "$H" >/dev/null || { echo "FAIL: closure install of hold-push.sh"; exit 1; }
[ -r "$LIB" ] && cp "$LIB" "$H/bin/lib/"
{ fn RB_HOLD_YIELD; fn RB_PUSH; } > "$T/rb-fns.sh"
grep -q '^RB_PUSH(){' "$T/rb-fns.sh" && ok || bad "bin/lib/rb/gates.sh has no RB_PUSH"
{ blk 'ticket branch resume (BH-7946)' 'ticket branch resume'; blk 'rebase verify'; blk 'pr push'; } > "$T/stage.sh"
grep -q '^# >>> ticket branch resume (BH-7946)' "$T/stage.sh" && ok || bad "bin/lib/rb/pr.sh has no '# >>> ticket branch resume (BH-7946)' block"
grep -q 'RB_PUSH -u pr-push' "$T/stage.sh" && ok || bad "bin/lib/rb/pr.sh has no '# >>> pr push' block"
# The driver: a fresh bash per case, so an `exit` is observable as its rc.
cat > "$T/drive.sh" <<EOF
#!/bin/bash
PROJECT=tproj BASE=main HARNESS="$H" GH_AUTH_SLUG=o/tproj
STAMP() { printf '2026-10-22T01:00:00Z'; }
RESULT() { echo "\$*" > "\$BUILD/RESULT"; }
GH_LIVE() { :; }; sleep() { :; }
track_pushed() { git update-ref "refs/remotes/origin/\$BRANCH" "\$(git rev-parse HEAD)"; }
. "$H/bin/lib/hold-push.sh" 2>/dev/null
hold_push_verdict() { echo call >> "\$BUILD/hold-push-calls"; printf 'clear\tfixture\n'; return 0; }
. "$T/rb-fns.sh"
PREPR_SECTION=""; SQUASH_OK=1
cd "\$1" || exit 98
trap 'printf "%s" "\${PREPR_SECTION:-}" > "\$BUILD/prepr.txt"; echo "SQUASH_OK=\$SQUASH_OK" > "\$BUILD/vars.txt"' EXIT
eval "\${2:-}"
. "$T/stage.sh"
EOF
# stage <name> [<pre-eval>] — run the stage in $R/pool for KEY_U/BR; sets RC.
stage() {
  B="$T/build-$1"; mkdir -p "$B"; rm -f "$B/RESULT" "$B/hold-push-calls"; : > "$B/pipeline.log"
  BUILD="$B" KEY="$KEY_U" BRANCH="$BR" bash "$T/drive.sh" "$R/pool" "${2:-}" > "$B/out" 2>&1; RC=$?
}
rtip() { git -C "$R/origin.git" rev-parse "refs/heads/$BR" 2>/dev/null; }

# R1: the BH-7519 shape. Two BH-9101 commits on origin, three behind main, no PR;
# the pool cut its own ticket/bh-9101 from main and finished.
KEY_U=BH-9101; BR=ticket/bh-9101
mk r1; FORK=$(git -C "$R/seed" rev-parse HEAD)
main_more 3; pool 50
OLD=$(rbranch "$FORK" 'BH-9101: mac 1' 'BH-9101: mac 2')
MAINTIP=$(git -C "$R/origin.git" rev-parse refs/heads/main)
stage r1
NEW=$(rtip)
[ "$RC" = 0 ] && ok || bad "R1 THE POINT: the PR-stage push must land, got exit $RC (RESULT: $(cat "$B/RESULT" 2>/dev/null); log: $(grep -E 'REJECTED|hold-push|BRANCH-CHECK' "$B/pipeline.log" | tr '\n' ' '))"
[ ! -e "$B/RESULT" ] && ok || bad "R1 no deferral RESULT: $(cat "$B/RESULT" 2>/dev/null)"
[ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && git -C "$R/origin.git" merge-base --is-ancestor "$OLD" "$NEW" && ok \
  || bad "R1 the old remote head $OLD must be an ancestor of the new one ${NEW:-none} (a fast-forward)"
[ "$(git -C "$R/origin.git" rev-parse "$NEW^1" 2>/dev/null)" = "$OLD" ] && [ "$(git -C "$R/origin.git" rev-parse "$NEW^2" 2>/dev/null)" = "$MAINTIP" ] && ok \
  || bad "R1 the new head is a merge of main into the remote head (parents $(git -C "$R/origin.git" rev-parse "$NEW^1" "$NEW^2" 2>/dev/null | tr '\n' ' '))"
[ "$(git -C "$R/origin.git" log --format=%s "$MAINTIP..$NEW" | grep -c '^BH-9101: mac')" = 2 ] && ok || bad "R1 both BH-9101 commits are still on origin"
grep -q "BRANCH-CHECK own ticket/bh-9101 remote=$OLD commits=2" "$B/pipeline.log" && ok || bad "R1 pipeline.log has BRANCH-CHECK own: $(grep BRANCH-CHECK "$B/pipeline.log")"
grep -q 'pre-PR update by MERGE: ticket/bh-9101 is already on origin (BH-7946)' "$B/pipeline.log" && ok || bad "R1 the update is a merge: $(grep 'pre-PR' "$B/pipeline.log")"
grep -q '^## Resumed from an existing branch' "$B/prepr.txt" && grep -q "$BUILT" "$B/prepr.txt" && ok || bad "R1 the PR body section names the set-aside head: $(cat "$B/prepr.txt")"
[ "$(git -C "$R/pool" rev-parse refs/harness/superseded/BH-9101 2>/dev/null)" = "$BUILT" ] && ok || bad "R1 refs/harness/superseded/BH-9101 is the built head"
grep -q 'SQUASH_OK=0' "$B/vars.txt" && ok || bad "R1 the resumed branch may not be squashed: $(cat "$B/vars.txt")"
[ -s "$B/hold-push-calls" ] && ok || bad "R1 the push went through hold_push"

# A1: the remote head is already in HEAD (an earlier push of this build's own work).
KEY_U=BH-9102; BR=ticket/bh-9102
mk a1; pool; git -C "$R/pool" push -q origin "HEAD:refs/heads/$BR"; OLD=$BUILT
HEADA=$(CM "$R/pool" 'BH-9102: one more')
stage a1
[ "$RC" = 0 ] && [ "$(rtip)" = "$HEADA" ] && ok || bad "A1 the push lands as a fast-forward (exit $RC, remote $(rtip), want $HEADA; $(cat "$B/RESULT" 2>/dev/null))"
grep -q "BRANCH-CHECK ancestor ticket/bh-9102 remote=$OLD" "$B/pipeline.log" && ok || bad "A1 BRANCH-CHECK ancestor: $(grep BRANCH-CHECK "$B/pipeline.log")"
git -C "$R/pool" rev-parse -q --verify refs/harness/superseded/BH-9102 >/dev/null && bad "A1 nothing is resumed in the ancestor case" || ok

# F1: the main merge conflicts. The remote head is pushed as it is.
KEY_U=BH-9103; BR=ticket/bh-9103
mk f1; FORK=$(git -C "$R/seed" rev-parse HEAD)
AN=Main CM "$R/seed" 'main edits the shared line' shared.txt 'main side' >/dev/null; git -C "$R/seed" push -q origin main
pool
OLD=$(git -C "$R/seed" checkout -q -B "$BR" "$FORK" && CM "$R/seed" 'BH-9103: mac edits the shared line' shared.txt 'mac side')
git -C "$R/seed" push -q origin "$BR:refs/heads/$BR"; git -C "$R/seed" checkout -q main
stage f1
[ "$RC" = 0 ] && [ "$(rtip)" = "$OLD" ] && ok || bad "F1 a conflicting merge pushes the remote head unchanged (exit $RC, remote $(rtip), want $OLD)"
[ "$(git -C "$R/pool" rev-parse HEAD)" = "$OLD" ] && ok || bad "F1 HEAD stays the remote head"
grep -q 'CONFLICTED' "$B/pipeline.log" && ok || bad "F1 the conflict is logged: $(grep -i conflict "$B/pipeline.log")"

# F2 (Acceptance 2): a foreign commit on the remote branch is still refused.
KEY_U=BH-9104; BR=ticket/bh-9104
mk f2; pool; git -C "$R/seed" checkout -q -B "$BR" main
FOREIGN=$(AN='Other Person' CM "$R/seed" 'fix typo'); git -C "$R/seed" push -q origin "$BR:refs/heads/$BR"; git -C "$R/seed" checkout -q main
stage f2
[ "$RC" = 3 ] && ok || bad "F2 a foreign branch is refused with exit 3, got $RC"
[[ "$(cat "$B/RESULT" 2>/dev/null)" =~ ^BUILD_DEFERRED\ push\ of\ ticket/bh-9104\ rejected\ at\ [0-9a-f]{40}\ branch-check=foreign\ remote=$FOREIGN\ first=$FOREIGN\ by\ Other\ Person$ ]] \
  && ok || bad "F2 the RESULT names the foreign commit: $(cat "$B/RESULT" 2>/dev/null)"
[ "$(rtip)" = "$FOREIGN" ] && ok || bad "F2 the remote is unchanged"
git -C "$R/pool" rev-parse -q --verify "refs/remotes/origin/$BR" >/dev/null && bad "F2 a foreign verdict must leave the lease at new" || ok

# N1: a published head that does not contain the remote sha never reaches hold_push.
KEY_U=BH-9105; BR=ticket/bh-9105
mk n1; pool
awk 'index($0, "# >>> pr push") == 1 {on=1} on {print} on && index($0, "# <<< pr push") == 1 {exit}' "$DIR/bin/lib/rb/pr.sh" > "$T/stage-push.sh"
cp "$T/stage.sh" "$T/stage-full.sh"; cp "$T/stage-push.sh" "$T/stage.sh"
stage n1 "TBR_PUBLISHED=1 TBR_VERDICT=own TBR_REMOTE=$(CM "$R/seed" 'BH-9105: elsewhere') TBR_DETAIL=commits=1"
cp "$T/stage-full.sh" "$T/stage.sh"
[ "$RC" = 3 ] && ok || bad "N1 a non-fast-forward exits 3, got $RC"
grep -q "^BUILD_DEFERRED push of ticket/bh-9105 rejected at $BUILT branch-check=own remote=[0-9a-f]\{40\} not-fast-forward$" "$B/RESULT" 2>/dev/null && ok \
  || bad "N1 the RESULT says not-fast-forward: $(cat "$B/RESULT" 2>/dev/null)"
[ ! -e "$B/hold-push-calls" ] && ok || bad "N1 hold_push is never called"

# ── P1: the BH-6821 reap reads the suffixed line ───────────────────────────
(
  # shellcheck source=bin/lib/pool-push-rejected.sh
  . "$DIR/bin/lib/pool-push-rejected.sh" 2>/dev/null || exit 9
  S=f56eba45f0a1b2c3d4e5f60718293a4b5c6d7e8f
  L="BUILD_DEFERRED push of ticket/bh-9104 rejected at $S branch-check=foreign remote=c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2 first=c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2 by Other Person"
  ppr_rejected_line "$L" || exit 1
  [ "$(ppr_built_head "$L" /nonexistent)" = "$S" ] || exit 2
) && ok || bad "P1 ppr_rejected_line / ppr_built_head must read a branch-check-suffixed line (rc $?)"

# ── X1: the lib never sends to origin, forces or deletes ───────────────────
if [ -r "$LIB" ]; then
  X=$(grep -nE -- '--force|(^|[[:space:]])-f([[:space:]]|$)|--delete|git[^|]*\bpush\b' "$LIB")
  [ -z "$X" ] && ok || bad "X1 bin/lib/ticket-branch-resume.sh has a push, a force or a delete: $X"
else
  bad "X1 bin/lib/ticket-branch-resume.sh is missing"
fi

echo "ticket-branch-resume.bh-7946: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
