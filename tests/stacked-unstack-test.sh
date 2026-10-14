#!/bin/bash
# tests/stacked-unstack-test.sh — a stacked child never loses its PR when the
# parent branch disappears mid-build, and no build ever writes PR_CREATED
# without a URL (#574).
#
# THE INCIDENT. project-5 child TK-1664 was cut from ticket/TK-1663. The parent's
# PR merged at 16:30Z and GitHub deleted the branch; the child's
# `gh pr create --base ticket/TK-1663` at 16:49Z had no base left, so it 422'd —
# and the build still wrote
#   PR_CREATED  | STACKED on ticket/TK-1663 (parent PR not resolved)
# which every close-out reader in the fleet treats as "there is a PR". There was
# no PR. The same silenced fetch is why the child also re-added a file its
# parent had deleted.
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is a decision under a condition
# that only a real repo produces: whether `git ls-remote` says gone or says the
# network is down, whether `rebase --onto` drops the parent's commits and keeps
# the child's, and which word `RESULT()` puts in the file. A grep for
# "PR_CREATE_FAILED" passes just as happily on a script that writes it never or
# always. So the three production blocks are extracted VERBATIM by their
# `# >>> …` markers and run — against a real bare origin whose parent branch is
# really deleted between the stack and the recheck, and a `gh` stub that runs
# the block's OWN jq query over a prebaked API answer.
#
# Run from anywhere: tests/stacked-unstack-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/hold-gate-fixture.sh" || exit 1  # BH-6091: the pr-open HOLD gate for a pipeline slice
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

mkdir -p "$T/h/builds/b" "$T/h/logs" "$T/fakebin"
export PATH="$T/fakebin:$PATH"
LOG="$T/h/builds/b/pipeline.log"
ALOG="$T/h/logs/ALERTS.log"

# A gh that answers `pr list` by running the REAL -q expression from the block
# under test over $GH_PR_JSON, and `pr create` from $GH_CREATE_*. Nothing here
# reaches the network; everything here is a shape gh genuinely produces.
# An npx that IS the repo's typecheck: $NPX_RC is what `npx tsc --noEmit` exits
# with and $NPX_OUT is what it prints. The unstack only carries a head-bound
# approval across a tree this actually passed, so the suite has to be able to
# make it pass and make it fail.
cat > "$T/fakebin/npx" <<'SH'
#!/bin/bash
[ -n "${NPX_OUT:-}" ] && printf '%s\n' "$NPX_OUT"
exit "${NPX_RC:-0}"
SH
chmod +x "$T/fakebin/npx"

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
Q=""; prev=""
for a in "$@"; do [ "$prev" = "-q" ] && Q="$a"; prev="$a"; done
case "$*" in
  *"pr create"*)
    [ -n "${GH_CREATE_ERR:-}" ] && printf '%s\n' "$GH_CREATE_ERR" >&2
    [ -n "${GH_CREATE_URL:-}" ] && { printf '%s\n' "$GH_CREATE_URL"; exit 0; }
    exit 1 ;;
  *"pr list"*)
    [ "${GH_FAIL:-}" = 1 ] && exit 1
    [ -n "${GH_PR_RAW:-}" ] && { printf '%s\n' "$GH_PR_RAW"; exit 0; }
    [ -s "${GH_PR_JSON:-/nonexistent}" ] || exit 0
    jq -r "$Q" < "$GH_PR_JSON" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

# ============================================================================
# 1. bin/run-build.sh `# >>> result pr url ratchet` — the word comes from the line
# ============================================================================
awk '/^# >>> result pr url ratchet/{f=1;next} /^# <<< result pr url ratchet/{exit} f' \
  "$RB_ALL" > "$T/result.sh"
[ -s "$T/result.sh" ] && ok || bad "could not extract the result-ratchet block — markers missing?"
grep -q '^RESULT()' "$T/result.sh" \
  && ok || bad "the extracted block must define the production RESULT(), not a paraphrase of it"

rr() { # rr <result-line> [PR_CREATE_ERR] ; prints the RESULT file byte-for-byte
  : > "$T/h/builds/b/RESULT"
  ( export BUILD="$T/h/builds/b"
    if [ -n "${2:-}" ]; then export PR_CREATE_ERR="$2"; else unset PR_CREATE_ERR; fi
    bash -c 'set -uo pipefail
      . "$1"
      RESULT "$2" >/dev/null' _ "$T/result.sh" "$1" )
  cat "$T/h/builds/b/RESULT"
}

# The #1664 line itself, byte for byte, fed to the real recorder.
R=$(rr "PR_CREATED  | STACKED on ticket/TK-611 (parent PR not resolved)")
case "$R" in PR_CREATE_FAILED:*) ok ;; *) bad "a url-less PR_CREATED must be recorded as PR_CREATE_FAILED (got '$R')" ;; esac
grep -q 'PR_CREATED' <<<"$R" \
  && bad "the rewritten line must not contain PR_CREATED anywhere — every close-out reader and the LLM results sweep key on that word (got '$R')" || ok
grep -q 'STACKED on ticket/TK-611' <<<"$R" \
  && ok || bad "the refused line's own notes must survive, or the reader cannot tell which build this was (got '$R')"
R=$(rr "PR_CREATED")
case "$R" in PR_CREATE_FAILED:*) ok ;; *) bad "a bare PR_CREATED with nothing at all after it must also be refused (got '$R')" ;; esac
R=$(rr "PR_CREATED " )
case "$R" in PR_CREATE_FAILED:*) ok ;; *) bad "PR_CREATED with an empty url and no notes must be refused (got '$R')" ;; esac

# The real gh error is what the sweep needs to read.
GHERR='pull request create failed: GraphQL: Base ref "ticket/TK-611" does not exist (createPullRequest)'
R=$(rr "PR_CREATED  | STACKED on ticket/TK-611" "$GHERR")
grep -qF 'Base ref "ticket/TK-611" does not exist' <<<"$R" \
  && ok || bad "PR_CREATE_ERR must be carried into the RESULT line — the reason is the whole point (got '$R')"
R=$(rr "PR_CREATED ")
grep -q 'gh pr create produced no url' <<<"$R" \
  && ok || bad "with no PR_CREATE_ERR set the line must still state a reason (got '$R')"

# PASS-THROUGH. These are the shapes every live call site writes, and a ratchet
# that touched any of them would take the fleet's close-out down with it.
for L in \
  "PR_CREATED https://github.com/o/r/pull/1" \
  "PR_CREATED https://github.com/o/r/pull/1 | QUEUED: in the repo's merge queue, the merge conductor settles it" \
  "PR_CREATED https://github.com/o/r/pull/1 | STACKED on ticket/TK-611 (https://github.com/o/r/pull/900)" \
  "PR_MERGED https://github.com/o/r/pull/1" \
  "PR_MERGED " \
  "PLAN_BLOCKED /root/harness/builds/x/plan.md" \
  "BUILD_DEFERRED worktree setup failed" \
  "DECOMPOSED #12 #13" \
  "RESULT_UNVERIFIED PR_CREATED https://github.com/o/r/pull/1" \
  ; do
  R=$(rr "$L" "$GHERR")
  [ "$R" = "$L" ] && ok || bad "must pass through byte-for-byte: '$L' (got '$R')"
done

# THE REPRO, as the ticket reports it: the same extraction the incident used,
# now answering rc 0 because there is no url-less claim left to find.
: > "$T/h/builds/b/RESULT"
( export BUILD="$T/h/builds/b"
  bash -c 'set -u; . "$1"; PR_URL=""
    RESULT "PR_CREATED $PR_URL | STACKED on ticket/TK-1663 (parent PR not resolved)" >/dev/null' _ "$T/result.sh" )
grep -q '^PR_CREATED' "$T/h/builds/b/RESULT" \
  && bad "the #1664 shape must be extinct at the recorder (got '$(cat "$T/h/builds/b/RESULT")')" || ok
# bin/pipeline-health.sh check 5's own matcher, which is the fleet-level ratchet.
grep -qE "^PR_CREATED *(\||$)" <<<"$(head -1 "$T/h/builds/b/RESULT")" \
  && bad "pipeline-health check 5 must find nothing to report on a refused create" || ok

# ============================================================================
# 2. bin/run-build.sh `# >>> stack recheck` — the parent vanishing mid-build
# ============================================================================
awk '/^# >>> stack recheck/{f=1;next} /^# <<< stack recheck/{exit} f' \
  "$RB_ALL" > "$T/recheck.sh"
[ -s "$T/recheck.sh" ] && ok || bad "could not extract the stack-recheck block — markers missing?"
awk '/^# >>> pre-pr rebase/{f=1;next} /^# <<< pre-pr rebase/{exit} f' \
  "$RB_ALL" > "$T/rebase.sh"
[ -s "$T/rebase.sh" ] && ok || bad "could not extract the pre-PR rebase block — markers missing?"

# THE FIXTURE, a real one, because `git ls-remote` is the probe under test:
#   main            A -> S          (S is the parent's work as the SQUASH merge
#   ticket/TK-611   A -> P           left it on main: same tree as P, other sha)
#   ticket/bh-574   A -> P -> C1 -> C2
# P deletes dead.txt — the file the incident's child re-added.
# FIXTURE INTEGRITY (#1135). Every git step below used to run inside
# `( … && … ) >/dev/null 2>&1`: no rc checked anywhere, no byte of stderr kept.
# When a setup step failed the suite did not say the fixture was broken — it
# reported a BEHAVIOUR finding about bin/run-build.sh on a tree where
# bin/run-build.sh is innocent. PR #1014 head e999973 went red on exactly one
# assertion, "nothing may rewrite the branch when the parent is not provably
# merged", against a flattened pipeline text byte-identical to origin/main; the
# same export ran 113/0 on the same image minutes earlier and later. One
# failure, no diagnosis, and a resolver round spent on the wrong file.
#
# So: every step checks its rc, every byte git wrote is kept in
# $T/fixture-logs/<name>.setup.log, the fixture asserts its own postconditions
# before it hands the checkout back, and a setup that did not happen is reported
# as FIXTURE BROKEN and counted as a FAIL of its own (a broken fixture is a real
# failure — just an honestly named one). No assertion below is weakened.
FIXLOG_DIR="$T/fixture-logs"; mkdir -p "$FIXLOG_DIR"
FIXTURE_BROKEN_LOG="$T/fixture-broken.log"; : > "$FIXTURE_BROKEN_LOG"

# fixture_fail <name> <what> — name it on stderr NOW, because `C=$(fixture x)`
# runs in a command substitution that cannot reach PASS/FAIL, and record it for
# the counted tally that runs just before the summary line.
fixture_fail() {
  local n="$1" what="$2" log="$FIXLOG_DIR/$1.setup.log"
  printf 'FIXTURE BROKEN: %s — %s\n' "$n" "$what" >> "$FIXTURE_BROKEN_LOG"
  { printf 'FIXTURE BROKEN: %s — %s\n' "$n" "$what"
    printf '  --- %s (last 40 lines) ---\n' "$log"
    [ -s "$log" ] && sed 's/^/  /' "$log" | tail -40
  } >&2
}

# fx <name> <step> <cmd…> — run ONE setup step, keep its stdout and stderr in the
# setup log, check its rc, and name the step if it failed.
fx() {
  local n="$1" step="$2" rc; shift 2
  { printf '### %s\n' "$step"; "$@"; } >> "$FIXLOG_DIR/$n.setup.log" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fixture_fail "$n" "$step (rc $rc)"
  return "$rc"
}
# the seed's and the child's file writes, as commands fx can run, check and log
fx_write()  { printf '%s\n' "$2" >  "$1"; }
fx_append() { printf '%s\n' "$2" >> "$1"; }

# THE FIXTURE, a real one, because `git ls-remote` is the probe under test:
#   main            A -> S          (S is the parent's work as the SQUASH merge
#   ticket/TK-611   A -> P           left it on main: same tree as P, other sha)
#   ticket/bh-574   A -> P -> C1 -> C2
# P deletes dead.txt — the file the incident's child re-added.
fixture_build() { # fixture_build <name> <dir> <seed> <child> ; stops at the first bad step
  local n="$1" d="$2" s="$3" c="$4"
  fx "$n" 'git init (seed)'                      git init -q "$s" || return 1
  fx "$n" 'git config user.email (seed)'         git -C "$s" config user.email t@t || return 1
  fx "$n" 'git config user.name (seed)'          git -C "$s" config user.name t || return 1
  fx "$n" 'write seed/f.txt'                     fx_write "$s/f.txt" base || return 1
  fx "$n" 'write seed/dead.txt'                  fx_write "$s/dead.txt" doomed || return 1
  if [ -f "$d/seed-tsconfig" ]; then
    fx "$n" 'copy tsconfig.json into the seed'   cp "$d/seed-tsconfig" "$s/tsconfig.json" || return 1
  fi
  fx "$n" 'git add . (seed)'                     git -C "$s" add . || return 1
  fx "$n" 'git commit A (seed)'                  git -C "$s" commit -qm A || return 1
  fx "$n" 'git branch -M main (seed)'            git -C "$s" branch -M main || return 1
  fx "$n" 'git checkout -b ticket/TK-611 (seed)' git -C "$s" checkout -qb ticket/TK-611 || return 1
  fx "$n" 'git rm dead.txt on ticket/TK-611'     git -C "$s" rm -q dead.txt || return 1
  fx "$n" 'git commit "parent deletes dead.txt"' git -C "$s" commit -qm "parent deletes dead.txt" || return 1
  fx "$n" 'git checkout main (seed)'             git -C "$s" checkout -q main || return 1
  fx "$n" 'git rm dead.txt on main'              git -C "$s" rm -q dead.txt || return 1
  fx "$n" 'git commit "squash merge of the parent"' git -C "$s" commit -qm "squash merge of the parent" || return 1
  fx "$n" 'git clone --bare seed -> origin.git'  git clone -q --bare "$s" "$d/origin.git" || return 1
  fx "$n" 'git clone origin.git -> child'        git clone -q "$d/origin.git" "$c" || return 1
  fx "$n" 'git config user.email (child)'        git -C "$c" config user.email t@t || return 1
  fx "$n" 'git config user.name (child)'         git -C "$c" config user.name t || return 1
  fx "$n" 'git checkout -b ticket/bh-574 origin/ticket/TK-611' \
                                                 git -C "$c" checkout -q -b ticket/bh-574 origin/ticket/TK-611 || return 1
  fx "$n" 'write child/child.txt'                fx_write "$c/child.txt" one || return 1
  fx "$n" 'git add child.txt (child)'            git -C "$c" add child.txt || return 1
  fx "$n" 'git commit "child one"'               git -C "$c" commit -qm "child one" || return 1
  fx "$n" 'append to child/child.txt'            fx_append "$c/child.txt" two || return 1
  fx "$n" 'git commit "child two"'               git -C "$c" commit -qam "child two" || return 1
}

# THE POSTCONDITIONS every case below silently depends on. Without these, a seed
# whose `checkout -qb ticket/TK-611` failed still yields a child checkout — and
# then `git rev-parse origin/ticket/TK-611` prints its own ARGUMENT and exits
# 128, so $P_SHA becomes the literal string and exactly one behaviour assertion
# goes red with nothing to explain it.
fixture_assert() { # fixture_assert <name> <dir> <child>
  local n="$1" d="$2" c="$3" head psha
  git -C "$d/origin.git" rev-parse --verify -q refs/heads/ticket/TK-611 >/dev/null 2>&1 \
    || { fixture_fail "$n" 'origin.git has no refs/heads/ticket/TK-611 — the parent branch was never pushed'; return 1; }
  git -C "$d/origin.git" rev-parse --verify -q refs/heads/main >/dev/null 2>&1 \
    || { fixture_fail "$n" 'origin.git has no refs/heads/main'; return 1; }
  head=$(git -C "$c" symbolic-ref --short HEAD 2>/dev/null)
  [ "$head" = ticket/bh-574 ] \
    || { fixture_fail "$n" "the child's HEAD is '$head', not ticket/bh-574"; return 1; }
  psha=$(git -C "$c" rev-parse --verify -q origin/ticket/TK-611 2>/dev/null)
  grep -qE '^[0-9a-f]{40,64}$' <<<"$psha" \
    || { fixture_fail "$n" "origin/ticket/TK-611 does not resolve to a sha (got '$psha')"; return 1; }
  git -C "$c" merge-base --is-ancestor "$psha" HEAD 2>/dev/null \
    || { fixture_fail "$n" "the parent tip $psha is not an ancestor of the child's HEAD — the child was not cut from ticket/TK-611 (HEAD: $(git -C "$c" log --oneline HEAD 2>/dev/null | tr '\n' ' '))"; return 1; }
  return 0
}

fixture() { # fixture <name> [typed] ; prints the child checkout dir
  local n="$1" d="$T/$1" rc=0
  mkdir -p "$d/seed"
  : > "$FIXLOG_DIR/$n.setup.log"
  # `typed` gives the repo a tsconfig.json, which is what makes the unstack run
  # a typecheck at all — the difference between a tree something verified and a
  # tree nothing has read.
  if [ "${2:-}" = typed ]; then printf '{}\n' > "$d/seed-tsconfig"; fi
  fixture_build "$n" "$d" "$d/seed" "$d/child" || rc=1
  if [ "$rc" -eq 0 ]; then fixture_assert "$n" "$d" "$d/child" || rc=1; fi
  echo "$d/child"
  return "$rc"
}
kill_parent() { # the PR merged; GitHub deleted the branch
  local n="$1"
  fx "$n" 'kill_parent: git branch -D ticket/TK-611' \
     git -C "$T/$n/origin.git" branch -D ticket/TK-611 || return 1
  if git -C "$T/$n/origin.git" rev-parse --verify -q refs/heads/ticket/TK-611 >/dev/null 2>&1; then
    fixture_fail "$n" 'kill_parent: refs/heads/ticket/TK-611 still exists in origin.git after branch -D'
    return 1
  fi
  return 0
}
pr_json() { printf '%s' "$1" > "$T/pr.json"; export GH_PR_JSON="$T/pr.json"; }

run_recheck() { # run_recheck <childdir> [<block>...] ; prints "BASE|STACK_ON"
  local c="$1"; shift
  : > "$LOG"; : > "$ALOG"; : > "$T/stacknote.txt"
  local blocks=("$T/recheck.sh"); [ "$#" -gt 0 ] && blocks=("$@")
  ( cd "$c" || exit 1
    export HARNESS="$T/h" PROJECT=p KEY=BH-574 BUILD="$T/h/builds/b" ALERTS="$ALOG" \
           BRANCH=ticket/bh-574 BASE_MAIN=main
    bash -c 'set -uo pipefail
      STAMP()      { echo TS; }
      STAGE_START() { echo 0; }
      STAGE_END()   { :; }
      BASE="${BASE_IN-ticket/TK-611}"; STACK_ON="${STACK_IN-ticket/TK-611}"
      STACK_NOTE=""; REBASE_NOTE=""
      for b in "$@"; do . "$b"; done
      printf "%s" "$STACK_NOTE" > '"$T"'/stacknote.txt
      printf "%s|%s\n" "$BASE" "$STACK_ON"' _ "${blocks[@]}" )
}

# --- the parent is alive: nothing to do, and nothing said -------------------
C=$(fixture alive)
pr_json '[]'
R=$(run_recheck "$C")
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "a live parent must leave the stack exactly as it is (got '$R')"
[ ! -s "$LOG" ] && ok || bad "a live parent must not write a recheck line at all (got: $(cat "$LOG"))"
[ ! -s "$ALOG" ] && ok || bad "a live parent must never alert (got: $(cat "$ALOG"))"

# --- the parent merged and its branch is gone: UNSTACK onto main ------------
C=$(fixture merged); kill_parent merged
P_SHA=$(git -C "$C" rev-parse origin/ticket/TK-611)
MAIN_SHA=$(git -C "$C" rev-parse origin/main)
git -C "$C" rev-parse HEAD~1 > "$T/h/builds/b/review-head"   # the reviewed head, one commit back
RH_PRE_SHA=$(cat "$T/h/builds/b/review-head")
pr_json '[{"state":"MERGED","url":"https://github.com/o/r/pull/900","mergedAt":"2026-09-17T16:30:00Z","headRefName":"ticket/TK-611"}]'
R=$(run_recheck "$C")
[ "$R" = "main|" ] \
  && ok || bad "a merged parent whose branch is gone must retarget the build to main and clear the stack (got '$R')"
[ "$(git -C "$C" merge-base origin/main HEAD)" = "$MAIN_SHA" ] \
  && ok || bad "the child must now sit on top of origin/main — that is what makes the PR openable"
grep -q "$P_SHA" <<<"$(git -C "$C" log --format=%H HEAD)" \
  && bad "the parent's commits must be DROPPED by the unstack — main already carries them as its squash" || ok
[ -f "$C/child.txt" ] && ok || bad "the child's own work must survive the unstack"
[ "$(git -C "$C" log --oneline HEAD | wc -l)" = 4 ] \
  && ok || bad "the child must keep exactly its two commits on top of main's two (got: $(git -C "$C" log --oneline HEAD))"
[ ! -e "$C/dead.txt" ] \
  && ok || bad "the file the parent DELETED must not come back — re-adding it is the second half of #574"
grep -q 'UNSTACKED from ticket/TK-611' "$LOG" \
  && ok || bad "the unstack must be recorded in pipeline.log (got: $(cat "$LOG"))"
grep -q 'pull/900' "$LOG" \
  && ok || bad "the pipeline.log line must name the parent PR that merged"
grep -q 'UNSTACKED from ticket/TK-611' "$T/stacknote.txt" \
  && ok || bad "STACK_NOTE must tell the PR body and the RESULT line what happened (got: $(cat "$T/stacknote.txt"))"
grep -q 'this PR targets main' "$T/stacknote.txt" \
  && ok || bad "STACK_NOTE must say the PR now targets main (got: $(cat "$T/stacknote.txt"))"
[ ! -s "$ALOG" ] \
  && ok || bad "a clean unstack is not an incident and must not alert (got: $(cat "$ALOG"))"
# THE APPROVAL DOES NOT MOVE FOR FREE. This repo has no typecheck, so nothing
# read the child on top of THIS main — an unstack only happens when the parent
# merged, which means main has moved by construction. Rebinding the approval
# here would hand a tier-1 auto-merge (the stacked hold is released with
# STACK_ON) a tree no reviewer and no suite has seen. So the file stays where it
# was and the head-bound gate re-runs the suite and buys one re-review.
[ "$(cat "$T/h/builds/b/review-head")" = "$RH_PRE_SHA" ] \
  && ok || bad "with nothing verifying the rebased tree the approval must stay bound to the sha that WAS reviewed (got $(cat "$T/h/builds/b/review-head"))"
git -C "$C" merge-base --is-ancestor "$RH_PRE_SHA" HEAD 2>/dev/null \
  && bad "fixture bug: the reviewed sha should no longer be on the branch after the unstack" || ok
grep -q 'approval stays bound' "$LOG" \
  && ok || bad "the log must say the approval was NOT carried and why (got: $(cat "$LOG"))"
grep -q 'no typecheck to run' "$LOG" \
  && ok || bad "the log must name the reason nothing verified the rebased tree (got: $(cat "$LOG"))"

# --- a TYPED repo: the typecheck passes, so the approval rides across ---------
C=$(fixture typedok typed); kill_parent typedok
git -C "$C" rev-parse HEAD~1 > "$T/h/builds/b/review-head"
RH_SUBJ=$(git -C "$C" log -1 --format=%s HEAD~1)
pr_json '[{"state":"MERGED","url":"https://github.com/o/r/pull/900","mergedAt":"2026-09-17T16:30:00Z","headRefName":"ticket/TK-611"}]'
R=$(NPX_RC=0 run_recheck "$C")
[ "$R" = "main|" ] && ok || bad "a green typecheck must not stand in the way of the unstack (got '$R')"
grep -q 'typecheck green' "$LOG" \
  && ok || bad "the log must record that the rebased tree was typechecked (got: $(cat "$LOG"))"
RH_NEW=$(cat "$T/h/builds/b/review-head")
git -C "$C" merge-base --is-ancestor "$RH_NEW" HEAD 2>/dev/null \
  && ok || bad "a VERIFIED unstack carries the approval onto the rebased branch (got $RH_NEW)"
[ "$(git -C "$C" log -1 --format=%s "$RH_NEW" 2>/dev/null)" = "$RH_SUBJ" ] \
  && ok || bad "the carried review-head must point at the SAME reviewed commit, one back from the new head"

# --- a TYPED repo whose rebased tree typechecks RED: no unstack at all -------
C=$(fixture typedred typed); kill_parent typedred
P_SHA=$(git -C "$C" rev-parse origin/ticket/TK-611)
PRE_HEAD=$(git -C "$C" rev-parse HEAD)
git -C "$C" rev-parse HEAD~1 > "$T/h/builds/b/review-head"
RH_PRE_SHA=$(cat "$T/h/builds/b/review-head")
pr_json '[{"state":"MERGED","url":"https://github.com/o/r/pull/900","mergedAt":"2026-09-17T16:30:00Z","headRefName":"ticket/TK-611"}]'
R=$(NPX_RC=1 NPX_OUT='src/x.ts(1,1): error TS2345: boom' run_recheck "$C")
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "a rebased tree that typechecks RED must not be shipped as an unstacked PR (got '$R')"
[ "$(git -C "$C" rev-parse HEAD)" = "$PRE_HEAD" ] \
  && ok || bad "a red typecheck must leave the branch exactly where it was before the unstack"
grep -q "$P_SHA" <<<"$(git -C "$C" log --format=%H HEAD)" \
  && ok || bad "the reset must put the parent's commits back on the branch (parent tip '$P_SHA'; HEAD is: $(git -C "$C" log --oneline HEAD | tr '\n' ' '))"
[ "$(cat "$T/h/builds/b/review-head")" = "$RH_PRE_SHA" ] \
  && ok || bad "a refused unstack must not touch the approval either"
grep -q 'typechecked RED' "$LOG" \
  && ok || bad "the log must say the unstack was refused because the tree went red (got: $(cat "$LOG"))"
[ "$(wc -l < "$ALOG")" = 1 ] \
  && ok || bad "a merged parent this build could not rebase onto must escalate exactly once (got: $(cat "$ALOG"))"
grep -q 'IS merged, but this build could not rebase' "$LOG" \
  && ok || bad "the escalation line must say the parent IS merged and the rebase is what failed (got: $(cat "$LOG"))"
grep -q 'not provably merged' "$LOG" \
  && bad "a parent gh proved MERGED must never be logged as 'not provably merged' (got: $(cat "$LOG"))" || ok

# --- RED but every error is main's own baseline: accepted, and it says so ----
C=$(fixture typedbase typed); kill_parent typedbase
mkdir -p "$T/h/state"; printf 'src/x.ts(1,1): error TS2345: boom\n' > "$T/h/state/tsc-baseline-p.txt"
pr_json '[{"state":"MERGED","url":"https://github.com/o/r/pull/900","mergedAt":"2026-09-17T16:30:00Z","headRefName":"ticket/TK-611"}]'
R=$(NPX_RC=1 NPX_OUT='src/x.ts(1,1): error TS2345: boom' run_recheck "$C")
[ "$R" = "main|" ] \
  && ok || bad "an error main ALREADY has is not this unstack's damage and must not block it (got '$R')"
grep -q 'zero NEW errors' "$LOG" \
  && ok || bad "accepting on the baseline must say so in the log (got: $(cat "$LOG"))"
rm -f "$T/h/state/tsc-baseline-p.txt"

# --- the parent's tip cannot be resolved: nothing is rewritten, and it says so
C=$(fixture notip); kill_parent notip
git -C "$C" update-ref -d refs/remotes/origin/ticket/TK-611   # a pruned remote ref
PRE_HEAD=$(git -C "$C" rev-parse HEAD)
pr_json '[{"state":"MERGED","url":"https://github.com/o/r/pull/900","mergedAt":"2026-09-17T16:30:00Z","headRefName":"ticket/TK-611"}]'
R=$(run_recheck "$C")
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "with no parent tip to rebase off, the stack must be left alone (got '$R')"
[ "$(git -C "$C" rev-parse HEAD)" = "$PRE_HEAD" ] \
  && ok || bad "nothing may be rewritten when there is no --onto point"
grep -q "could not resolve the parent's tip" "$LOG" \
  && ok || bad "the log must name the real reason — no tip (got: $(cat "$LOG"))"
grep -q 'CONFLICTED' "$LOG" \
  && bad "a rebase that never ran must not be logged as CONFLICTED (got: $(cat "$LOG"))" || ok
[ "$(wc -l < "$ALOG")" = 1 ] && ok || bad "the no-tip case must still escalate exactly once (got: $(cat "$ALOG"))"

# --- the parent PR was closed unmerged: escalate, never unstack -------------
C=$(fixture closed); kill_parent closed
P_SHA=$(git -C "$C" rev-parse origin/ticket/TK-611)
pr_json '[{"state":"CLOSED","url":"https://github.com/o/r/pull/900","mergedAt":null,"headRefName":"ticket/TK-611"}]'
R=$(run_recheck "$C")
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "a parent closed WITHOUT merging must not unstack — main does not contain its work (got '$R')"
grep -q "$P_SHA" <<<"$(git -C "$C" log --format=%H HEAD)" \
  && ok || bad "nothing may rewrite the branch when the parent is not provably merged (parent tip '$P_SHA'; HEAD is: $(git -C "$C" log --oneline HEAD | tr '\n' ' '))"
[ "$(wc -l < "$ALOG")" = 1 ] \
  && ok || bad "a gone-and-unmerged parent must write exactly one ALERTS line (got: $(cat "$ALOG"))"
grep -q 'ticket/TK-611' "$ALOG" && ok || bad "the alert must name the parent branch (got: $(cat "$ALOG"))"
grep -q 'ticket/bh-574' "$ALOG" && ok || bad "the alert must name the child branch (got: $(cat "$ALOG"))"
grep -q 'pull/900'      "$ALOG" && ok || bad "the alert must name the parent PR url (got: $(cat "$ALOG"))"
grep -q 'BH-574'        "$ALOG" && ok || bad "the alert must name the ticket (got: $(cat "$ALOG"))"

# --- gh cannot answer: the same conservative escalation ---------------------
C=$(fixture silent); kill_parent silent
rm -f "$T/pr.json"; export GH_PR_JSON="$T/pr.json"       # gh prints nothing at all
R=$(run_recheck "$C")
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "an empty gh answer must never be read as a merge (got '$R')"
[ "$(wc -l < "$ALOG")" = 1 ] && ok || bad "a silent gh must still escalate exactly once (got: $(cat "$ALOG"))"

C=$(fixture ghfail); kill_parent ghfail
pr_json '[{"state":"MERGED","url":"https://github.com/o/r/pull/900","mergedAt":"2026-09-17T16:30:00Z","headRefName":"ticket/TK-611"}]'
R=$(GH_FAIL=1 run_recheck "$C")
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "a gh that EXITS NONZERO must not unstack, whatever it printed (got '$R')"
[ "$(wc -l < "$ALOG")" = 1 ] && ok || bad "a failing gh must escalate exactly once (got: $(cat "$ALOG"))"

# --- a PR on a branch that merely STARTS with the parent's name -------------
C=$(fixture prefix); kill_parent prefix
pr_json '[{"state":"MERGED","url":"https://github.com/o/r/pull/901","mergedAt":"2026-09-17T16:30:00Z","headRefName":"ticket/TK-611-r2"}]'
R=$(run_recheck "$C")
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "a merged PR on ticket/TK-611-r2 is NOT the parent's PR — prefix is not identity (got '$R')"
[ "$(wc -l < "$ALOG")" = 1 ] && ok || bad "the prefix case must escalate, not unstack (got: $(cat "$ALOG"))"

# --- gh answers with one field and no tabs: not a merge either --------------
C=$(fixture garbage); kill_parent garbage
R=$(GH_PR_RAW="ticket/TK-611" run_recheck "$C")   # one field, no tabs at all
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "a one-field answer must not read as state+url+mergedAt+head (got '$R')"
[ "$(wc -l < "$ALOG")" = 1 ] && ok || bad "the garbage case must escalate, not unstack (got: $(cat "$ALOG"))"

# --- origin unreachable: a network blip must never unstack a build ----------
C=$(fixture netdown)
git -C "$C" remote set-url origin "$T/netdown/gone.git"
pr_json '[{"state":"MERGED","url":"https://github.com/o/r/pull/900","mergedAt":"2026-09-17T16:30:00Z","headRefName":"ticket/TK-611"}]'
R=$(run_recheck "$C")
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "an unreachable origin must leave the stack alone — 'gone' and 'no network' are different answers (got '$R')"
grep -q 'could not probe origin' "$LOG" \
  && ok || bad "the probe failure must say so in pipeline.log (got: $(cat "$LOG"))"
[ ! -s "$ALOG" ] \
  && ok || bad "an outage at probe time is not a gone parent and must not page (got: $(cat "$ALOG"))"

# --- an ordinary, unstacked build is byte-for-byte untouched ----------------
C=$(fixture plain)
R=$(BASE_IN=main STACK_IN="" run_recheck "$C")
[ "$R" = "main|" ] && ok || bad "an unstacked build must pass through the block unchanged (got '$R')"
[ ! -s "$LOG" ]  && ok || bad "an unstacked build must write nothing (got: $(cat "$LOG"))"
[ ! -s "$ALOG" ] && ok || bad "an unstacked build must alert nothing (got: $(cat "$ALOG"))"

# --- R4: the parent is alive but MOVED — the child lands on its CURRENT head
C=$(fixture moved)
( cd "$T/moved/seed" && git checkout -q ticket/TK-611 && echo more >> f.txt \
  && git commit -qam "parent moves on" && git push -q "$T/moved/origin.git" ticket/TK-611 ) >/dev/null 2>&1
NEW_P=$(git -C "$T/moved/origin.git" rev-parse ticket/TK-611)
STALE_P=$(git -C "$C" rev-parse origin/ticket/TK-611)
[ "$NEW_P" != "$STALE_P" ] && ok || bad "fixture bug: the parent did not actually move"
pr_json '[]'
R=$(run_recheck "$C" "$T/recheck.sh" "$T/rebase.sh")
[ "$R" = "ticket/TK-611|ticket/TK-611" ] \
  && ok || bad "a moved-but-alive parent stays the base (got '$R')"
[ "$(git -C "$C" merge-base "$NEW_P" HEAD)" = "$NEW_P" ] \
  && ok || bad "the child must be rebased onto the parent's CURRENT head, not the stale ref it was cut from"

# --- and the whole chain: gone parent -> unstack -> the rebase block is safe
C=$(fixture chain); kill_parent chain
MAIN_SHA=$(git -C "$C" rev-parse origin/main)
pr_json '[{"state":"MERGED","url":"https://github.com/o/r/pull/900","mergedAt":"2026-09-17T16:30:00Z","headRefName":"ticket/TK-611"}]'
R=$(run_recheck "$C" "$T/recheck.sh" "$T/rebase.sh")
[ "$R" = "main|" ] && ok || bad "the recheck must settle \$BASE before the rebase block reads it (got '$R')"
[ "$(git -C "$C" merge-base origin/main HEAD)" = "$MAIN_SHA" ] \
  && ok || bad "the rebase block must find nothing left to do after the unstack"
[ ! -e "$C/dead.txt" ] && ok || bad "the rebase block must not resurrect the parent's deleted file either"

# ============================================================================
# 3. bin/run-build.sh `# >>> pr create call` — a failed create says so, loudly
# ============================================================================
awk '/^# >>> pr create call/{f=1;next} /^# <<< pr create call/{exit} f' \
  "$RB_ALL" > "$T/create.sh"
[ -s "$T/create.sh" ] && ok || bad "could not extract the pr-create block — markers missing?"
grep -q 'gh pr create --head "\$BRANCH" --base "\$BASE"' "$T/create.sh" \
  && ok || bad "the extracted block must be the REAL create call — if this moved, this suite is testing a ghost"
hold_gate_prepend "$RB_ALL" "$T/create.sh"   # BH-6091: the real gate, a no-HOLD ticket read
# The terminal call site, lifted verbatim out of the file rather than retyped:
# if it is ever renamed, this suite fails instead of quietly proving nothing.
PRLINE=$(grep -F 'RESULT "PR_CREATED $PR_URL$QA_NOTE' "$RB_ALL" | head -1)
[ -n "$PRLINE" ] && ok || bad "could not find the terminal PR_CREATED call site in bin/run-build.sh"
printf '%s\n' "$PRLINE" > "$T/prline.sh"

C=$(fixture create)
git -C "$C" remote set-url origin https://github.com/o/r.git
run_create() { # run_create <childdir> ; prints the RESULT line
  : > "$LOG"; : > "$ALOG"; : > "$T/h/builds/b/RESULT"; : > "$T/h/builds/b/gh-stderr.log"
  # $SEED_STDERR is what an EARLIER run of this build left in the log — the file
  # is append-only and survives RESUME_BUILD.
  [ -n "${SEED_STDERR:-}" ] && printf '%s\n' "$SEED_STDERR" > "$T/h/builds/b/gh-stderr.log"
  ( cd "$1" || exit 1
    export HARNESS="$T/h" PROJECT=p KEY=BH-574 BUILD="$T/h/builds/b" ALERTS="$ALOG" \
           BRANCH=ticket/bh-574 BASE=ticket/TK-611 BASE_MAIN=main
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      PR_BODY_FOR() { echo "body"; }
      EVIDENCE_SECTION=""; QA_NOTE=""; MIG_NOTE=""; REBASE_NOTE=""; STACK_NOTE=""
      . "$1"          # the production create + adopt + failure block
      . "$2"          # the production RESULT ratchet
      . "$3"          # the production terminal PR_CREATED call site
      ' _ "$T/create.sh" "$T/result.sh" "$T/prline.sh" >/dev/null 2>&1 )
  cat "$T/h/builds/b/RESULT"
}

# 422 on a base that no longer exists, and no PR to adopt.
GHERR='pull request create failed: GraphQL: Base ref "ticket/TK-611" does not exist (createPullRequest)'
rm -f "$T/pr.json"; export GH_PR_JSON="$T/pr.json"; unset GH_CREATE_URL
R=$(GH_CREATE_ERR="$GHERR" run_create "$C")
case "$R" in PR_CREATE_FAILED:*) ok ;; *) bad "a 422'd create with nothing to adopt must record PR_CREATE_FAILED (got '$R')" ;; esac
grep -qF 'Base ref "ticket/TK-611" does not exist' <<<"$R" \
  && ok || bad "the RESULT must carry gh's OWN error, so the sweep escalates for the right reason (got '$R')"
grep -q 'PR_CREATED' <<<"$R" && bad "a failed create must never leave PR_CREATED in the file (got '$R')" || ok
grep -q 'https://'   <<<"$R" && bad "a failed create must not print a url it never earned (got '$R')" || ok
[ "$(wc -l < "$ALOG")" = 1 ] \
  && ok || bad "a failed create must write exactly one ALERTS line (got: $(cat "$ALOG"))"
grep -q 'ticket/bh-574' "$ALOG" && ok || bad "the alert must name the branch that has no PR (got: $(cat "$ALOG"))"
grep -q 'gh pr create --head ticket/bh-574 --base main -R o/r' "$ALOG" \
  && ok || bad "the alert must carry the runnable command that recovers it (got: $(cat "$ALOG"))"
grep -qF 'Base ref "ticket/TK-611" does not exist' "$ALOG" \
  && ok || bad "the alert must say why the create failed (got: $(cat "$ALOG"))"

# A RESUMED BUILD MUST NOT QUOTE THE PREVIOUS RUN'S ERROR. gh-stderr.log is
# appended to and survives the resume, so the reason has to come from the bytes
# THIS create wrote — otherwise the RESULT line explains a failure that already
# happened once, with whatever text happened to be in the file.
STALE='pull request create failed: GraphQL: Base ref "ticket/TK-999" does not exist (createPullRequest)'
R=$(SEED_STDERR="$STALE" GH_CREATE_ERR="$GHERR" run_create "$C")
grep -qF 'ticket/TK-611' <<<"$R" \
  && ok || bad "the reason must be THIS create's error (got '$R')"
grep -qF 'ticket/TK-999' <<<"$R" \
  && bad "the reason must not carry the previous run's error out of the shared stderr log (got '$R')" || ok
R=$(SEED_STDERR="$STALE" run_create "$C")     # this create writes no stderr at all
case "$R" in PR_CREATE_FAILED:*) ok ;; *) bad "a silent failed create must still be refused (got '$R')" ;; esac
grep -q 'wrote no error' <<<"$R" \
  && ok || bad "a create that said nothing must say exactly that (got '$R')"
grep -qF 'ticket/TK-999' <<<"$R" \
  && bad "a create that wrote nothing must not borrow a stale reason (got '$R')" || ok
unset SEED_STDERR

# THE ADOPT PATH IS NOT REGRESSED: create fails because the PR already exists.
pr_json '[{"url":"https://github.com/o/r/pull/77"}]'
R=$(GH_CREATE_ERR="a pull request for branch already exists" run_create "$C")
[ "$R" = "PR_CREATED https://github.com/o/r/pull/77" ] \
  && ok || bad "an existing open PR must still be ADOPTED — the PR existing is success (got '$R')"
[ ! -s "$ALOG" ] && ok || bad "an adopted PR is not a failure and must not alert (got: $(cat "$ALOG"))"
grep -q 'adopted' "$LOG" && ok || bad "the adoption must be recorded in pipeline.log (got: $(cat "$LOG"))"

# AND THE HAPPY PATH, unchanged: a create that works writes the url.
rm -f "$T/pr.json"
R=$(GH_CREATE_URL="https://github.com/o/r/pull/78" run_create "$C")
[ "$R" = "PR_CREATED https://github.com/o/r/pull/78" ] \
  && ok || bad "a successful create must still write PR_CREATED with its url (got '$R')"
[ ! -s "$ALOG" ] && ok || bad "a successful create must not alert (got: $(cat "$ALOG"))"

# ============================================================================
# 4. bin/run-build.sh `# >>> tier-1 merge gate` — the LEDGER says what the
#    RESULT says. The ratchet above cleaned up the file every reader greps;
#    the build also beats a row to the coordination DB one line earlier, and a
#    `stage:pr_created, pr_url:""` row is the same claim in the other record.
# ============================================================================
awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "could not extract the tier-1 merge gate — markers missing?"

run_gate() { # run_gate <pr_url> ; prints the ledger rows this build beat
  rm -f "$T/beats.txt"; : > "$T/h/builds/b/RESULT"
  printf 'VERDICT: APPROVE\n' > "$T/h/builds/b/review.md"; printf 'plan\n' > "$T/h/builds/b/plan.md"
  ( cd "$T" || exit 1
    export HARNESS="$T/h" BUILD="$T/h/builds/b" ALERTS="$ALOG" PROJECT=p KEY=BH-574 SLUG=o/r \
           TIER=2 PR_URL="$1" QA_NOTE="" MIG_NOTE="" REBASE_NOTE="" STACK_NOTE="" \
           PR_CREATE_ERR='pull request create failed: GraphQL: Base ref "ticket/TK-611" does not exist'
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      BB() { printf "%s|%s\n" "$1" "${4:-}" >> '"$T"'/beats.txt; }
      CLOSE_ISSUE_AFTER_MERGE() { :; }
      . "$1"          # the production RESULT ratchet, defined before its caller
      . "$2"          # the production tier-1 merge gate
      ' _ "$T/result.sh" "$T/gate.sh" >/dev/null 2>&1 )
  cat "$T/beats.txt" 2>/dev/null
}

R=$(run_gate "")
grep -q '^pr_created|' <<<"$R" \
  && bad "a build with no PR must not beat a pr_created row — the RESULT says PR_CREATE_FAILED and the ledger must not disagree (got '$R')" || ok
grep -q '^pr_create_failed|' <<<"$R" \
  && ok || bad "the failed create still owes the ledger a row, it just has to be the true one (got '$R')"
grep -q '^PR_CREATE_FAILED:' "$T/h/builds/b/RESULT" \
  && ok || bad "the gate's terminal line must still be refused by the ratchet (got '$(cat "$T/h/builds/b/RESULT")')"
R=$(run_gate "https://github.com/o/r/pull/12")
[ "$R" = "pr_created|https://github.com/o/r/pull/12" ] \
  && ok || bad "a build WITH a PR must beat pr_created carrying its url, exactly as it always has (got '$R')"
grep -q '^PR_CREATED https://github.com/o/r/pull/12' "$T/h/builds/b/RESULT" \
  && ok || bad "the ordinary tier-2 close-out must be untouched (got '$(cat "$T/h/builds/b/RESULT")')"

# A BROKEN FIXTURE IS A FAILURE WITH ITS OWN NAME (#1135). Each recorded line
# is counted here so the summary can never read 0 failed on a suite whose setup
# did not happen, and so the operator reads "FIXTURE BROKEN: <name> — <step>"
# instead of a bin/run-build.sh behaviour finding it did not earn.
while IFS= read -r __fb; do [ -n "$__fb" ] && bad "$__fb"; done < "$FIXTURE_BROKEN_LOG"

echo "stacked-unstack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
