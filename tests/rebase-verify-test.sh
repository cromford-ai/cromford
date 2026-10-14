#!/bin/bash
# tests/rebase-verify-test.sh — BH-575: a tsc that CRASHED never reads as a tsc
# that said no.
#
# The hole this closes: bin/run-build.sh's post-rebase verify ran
# `timeout 900 npx tsc --noEmit … || TC_OK=0` at Node's default heap, so a V8
# heap abort (134), a SIGKILL (137), a `timeout` (124) and an npx that could not
# find tsc all landed on the same sentence — "main moved and the rebase
# typechecks red" — and bin/merge-sweep.sh parked the PR on it. Nothing in the
# RESULT line let a reader tell a real red from a crash, and nothing printed the
# two shas behind the "main moved" claim, which an EMPTY merge-base could also
# trigger.
#
# WHY DRIVEN AND NOT GREPPED. What is under test is a classification: which of
# {green, FAILED, INCONCLUSIVE, CONFLICT, nothing} each exit code and each repo
# shape lands on. A regex over the source proves none of that. So the shipped
# block is extracted VERBATIM by its markers and run against real `git` in a
# scratch repo, with only `npx` (section 1) and `gh` (section 2) faked, and
# every assertion reads an artifact: the note, HEAD, pipeline.log, the env the
# fake npx saw, the sweep's merge calls.
# Run from anywhere: tests/rebase-verify-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || SCRATCH_LIB_MISSING=1
# BH-575 / A6: tests/lib/scratch.sh is not on main yet (PR #609 adds it). The
# fallback reproduces the lib's contract — a $T under TMPDIR, removed on exit,
# and a scratch_rm that refuses any path outside it — so this suite is not red
# on its own branch for a file it does not own. Dead code once #609 lands.
if [ -n "${SCRATCH_LIB_MISSING:-}" ]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX") || exit 1
  trap 'rm -rf "$T"' EXIT
  scratch_rm() { # scratch_rm <path under $T>
    local SCRATCH; SCRATCH=$(realpath -m "$1")
    case "$SCRATCH" in
      "$T"|"$T"/*) rm -rf "$SCRATCH" ;;
      *) echo "refusing to rm outside \$T: $1" >&2; return 1 ;;
    esac
  }
fi
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

mkdir -p "$T/fakebin" "$T/state" "$T/build"

# ============================================================================
# 1. bin/run-build.sh — the rebase verify step
# ============================================================================
awk '/^# >>> rebase verify/{f=1;next} /^# <<< rebase verify/{exit} f' \
  "$RB_ALL" > "$T/stage.sh"
[ -s "$T/stage.sh" ] && ok || bad "could not extract the rebase-verify block from bin/run-build.sh — markers missing?"
grep -q 'REBASE_VERIFY_INCONCLUSIVE' "$T/stage.sh" \
  && ok || bad "the extracted block never writes REBASE_VERIFY_INCONCLUSIVE — a crash still reads as red"

# The fake tsc. Reads its shape from $NPX_MODE, always records the NODE_OPTIONS
# it was handed and the fact that it ran at all.
cat > "$T/fakebin/npx" <<'EOF'
#!/bin/bash
printf '%s\n' "${NODE_OPTIONS:-}" >> "$NPX_ENV"
: > "$NPX_CALLED"
case "$(cat "$NPX_MODE" 2>/dev/null)" in
  crash134)  echo "FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory" >&2; exit 134 ;;
  crash134diag) echo "src/a.ts(1,1): error TS2322: Type 'string' is not assignable to type 'number'."
                echo "FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory" >&2; exit 134 ;;
  killed137) exit 137 ;;
  timeout124) exit 124 ;;
  nodiag1)   echo "npm ERR! could not determine executable to run" >&2; exit 1 ;;
  red1)      echo "src/a.ts(1,1): error TS2322: Type 'string' is not assignable to type 'number'."; exit 1 ;;
  red2)      echo "src/a.ts(1,1): error TS2322: Type 'string' is not assignable to type 'number'."; exit 2 ;;
  green)     exit 0 ;;
  *)         echo "fake npx: no mode armed" >&2; exit 99 ;;
esac
EOF
chmod +x "$T/fakebin/npx"

REPO="$T/repo"
MB=""; MAIN=""
rb_repo() { # rb_repo <moved|same|conflict|unrelated> [ci-workflow]
  scratch_rm "$REPO"; mkdir -p "$REPO"
  ( cd "$REPO" || exit 1
    git init -q -b main
    git config user.email t@example.com; git config user.name tester
    echo '{}' > tsconfig.json
    echo one > a.txt
    if [ "${2:-}" = ci-workflow ]; then
      mkdir -p .github/workflows
      printf 'jobs:\n  tc:\n    env:\n      NODE_OPTIONS: --max-old-space-size=6144\n' > .github/workflows/ci.yml
    fi
    git add -A; git -c commit.gpgsign=false commit -qm base
    git branch -q side
    case "$1" in
      moved)    echo m > main.txt; git add -A; git -c commit.gpgsign=false commit -qm moved
                git update-ref refs/remotes/origin/main HEAD ;;
      conflict) echo main-side > a.txt; git add -A; git -c commit.gpgsign=false commit -qm moved
                git update-ref refs/remotes/origin/main HEAD ;;
      same)     git update-ref refs/remotes/origin/main HEAD ;;
      unrelated) ET=$(git hash-object -t tree /dev/null)
                ORPH=$(git -c commit.gpgsign=false commit-tree "$ET" -m orphan)
                git update-ref refs/remotes/origin/main "$ORPH" ;;
    esac
    git checkout -q side
    case "$1" in
      conflict) echo work-side > a.txt ;;
      *)        echo w > w.txt ;;
    esac
    git add -A; git -c commit.gpgsign=false commit -qm work
  ) >/dev/null 2>&1
  MAIN=$( cd "$REPO" && git rev-parse --short=12 refs/remotes/origin/main 2>/dev/null )
  MB=$( cd "$REPO" && git rev-parse --short=12 "$(git merge-base refs/remotes/origin/main HEAD 2>/dev/null)" 2>/dev/null || true )
}

arm() { printf '%s\n' "$1" > "$T/npx-mode"; }

run_stage() { # run_stage [extra env assignments...]
  : > "$T/npx-env.txt"; rm -f "$T/npx-called"
  scratch_rm "$T/build"; mkdir -p "$T/build"
  ( cd "$REPO" && git rev-parse HEAD ) > "$T/prehead.txt"
  ( cd "$REPO" || exit 1
    env PATH="$T/fakebin:$PATH" BUILD="$T/build" HARNESS="$T" PROJECT=p KEY=K \
        BASE=main STACK_ON="" NPX_MODE="$T/npx-mode" NPX_ENV="$T/npx-env.txt" \
        NPX_CALLED="$T/npx-called" "$@" \
    bash -c '
      set -uo pipefail
      STAMP()       { echo TS; }
      STAGE_START() { echo 0; }
      STAGE_END()   { :; }
      REBASE_NOTE=""
      . "$1"
      printf "%s\n" "$REBASE_NOTE" > "$2"
    ' _ "$T/stage.sh" "$T/note.txt"
  ) > "$T/stage.out" 2>&1
  ( cd "$REPO" && git rev-parse HEAD ) > "$T/head.txt"
}

note()      { cat "$T/note.txt" 2>/dev/null; }
head_moved() { ! cmp -s "$T/prehead.txt" "$T/head.txt"; }
rebased_on_main() { ( cd "$REPO" && git merge-base --is-ancestor refs/remotes/origin/main HEAD ); }

# --- 1a. crashes: INCONCLUSIVE, exit code named, never FAILED ---------------
inconclusive_case() { # inconclusive_case <mode> <exit-text>
  rb_repo moved; arm "$1"; run_stage
  grep -q 'REBASE_VERIFY_INCONCLUSIVE' "$T/note.txt" && ok \
    || bad "$1: a tsc that crashed must be INCONCLUSIVE (note: $(note))"
  grep -q "$2" "$T/note.txt" && ok \
    || bad "$1: the note must name the real exit ($2) — got: $(note)"
  grep -q 'REBASE_VERIFY_FAILED' "$T/note.txt" \
    && bad "$1: a crash must NEVER carry REBASE_VERIFY_FAILED (note: $(note))" || ok
  cmp -s "$T/prehead.txt" "$T/head.txt" && ok \
    || bad "$1: the worktree must be reset to the pre-rebase head"
  grep -q 'INCONCLUSIVE' "$T/build/pipeline.log" && ok \
    || bad "$1: pipeline.log must say INCONCLUSIVE, not red (log: $(cat "$T/build/pipeline.log"))"
}
inconclusive_case crash134  'exit 134'   # 1a-1  V8 heap abort, no diagnostics
inconclusive_case killed137 'exit 137'   # 1a-2  SIGKILL
inconclusive_case timeout124 'exit 124'  # 1a-3  timeout 900 fired
inconclusive_case nodiag1   'exit 1'     # 1a-4  npx could not run tsc at all

# 1a-5 a tsc that printed diagnostics and THEN died is still a crash: the run
# never finished, so the error list it printed is not the whole answer.
rb_repo moved; arm crash134diag; run_stage
grep -q 'REBASE_VERIFY_INCONCLUSIVE' "$T/note.txt" && ok \
  || bad "1a-5: exit 134 is a crash even when some diagnostics were printed first (note: $(note))"
grep -q 'REBASE_VERIFY_FAILED' "$T/note.txt" \
  && bad "1a-5: a crash that printed an error line must still not be FAILED (note: $(note))" || ok

# 1a-6 the baseline-aware acceptance must not swallow a crash: a run with no
# error lines trivially has "zero new errors vs the baseline".
rb_repo moved; arm crash134
printf "src/a.ts(1,1): error TS2322: Type 'string' is not assignable to type 'number'.\n" > "$T/state/tsc-baseline-p.txt"
run_stage
grep -q 'REBASE_VERIFY_INCONCLUSIVE' "$T/note.txt" && ok \
  || bad "1a-6: a crash must not be accepted as 'zero new errors vs baseline' (note: $(note))"
cmp -s "$T/prehead.txt" "$T/head.txt" && ok || bad "1a-6: a crash must still reset to the pre-rebase head"
rm -f "$T/state/tsc-baseline-p.txt"

# 1s-2 (from the crash134 run above, re-run so the shas are this fixture's)
rb_repo moved; arm crash134; run_stage
grep -qF "base=$MB main=$MAIN" "$T/note.txt" && ok \
  || bad "1s-2: the INCONCLUSIVE note must carry base=$MB main=$MAIN — got: $(note)"

# --- 1b. real red typechecks stay FAILED ------------------------------------
rb_repo moved; arm red1; run_stage                                  # 1b-1
grep -q 'REBASE_VERIFY_FAILED' "$T/note.txt" && ok \
  || bad "1b-1: exit 1 with error TS lines is a red typecheck (note: $(note))"
grep -q 'REBASE_VERIFY_INCONCLUSIVE' "$T/note.txt" \
  && bad "1b-1: a red typecheck must not read as inconclusive (note: $(note))" || ok
cmp -s "$T/prehead.txt" "$T/head.txt" && ok || bad "1b-1: red must reset to the pre-rebase head"
grep -q 'TS2322' "$T/build/rebase-tsc.txt" && ok \
  || bad "1b-1: the tsc output must be kept in \$BUILD/rebase-tsc.txt"
grep -qF "base=$MB main=$MAIN" "$T/note.txt" && ok \
  || bad "1s-1: the FAILED note must carry base=$MB main=$MAIN — got: $(note)"

# 1b-2 baseline-aware acceptance still turns that red into a green
rb_repo moved; arm red1
printf "src/a.ts(1,1): error TS2322: Type 'string' is not assignable to type 'number'.\n" > "$T/state/tsc-baseline-p.txt"
run_stage
[ -z "$(note)" ] && ok || bad "1b-2: zero NEW errors vs the cached baseline must still be accepted (note: $(note))"
head_moved && rebased_on_main && ok || bad "1b-2: an accepted rebase must keep the rebased worktree"
rm -f "$T/state/tsc-baseline-p.txt"

rb_repo moved; arm red2; run_stage                                  # 1b-3
grep -q 'REBASE_VERIFY_FAILED' "$T/note.txt" && ok \
  || bad "1b-3: exit 2 WITH diagnostics is red, not a crash (note: $(note))"

# --- 1g. the green path is untouched ----------------------------------------
rb_repo moved; arm green; run_stage
[ -z "$(note)" ] && ok || bad "1g-1: a green rebase must carry no note (note: $(note))"
head_moved && rebased_on_main && ok || bad "1g-1: a green rebase must leave the worktree rebased"

# --- 1s. "main moved" only with merge-base proof ----------------------------
rb_repo same; arm crash134; run_stage                               # 1s-3
[ -f "$T/npx-called" ] && bad "1s-3: main did not move — nothing may be typechecked" || ok
[ -z "$(note)" ] && ok || bad "1s-3: main did not move — the note must stay empty (note: $(note))"
cmp -s "$T/prehead.txt" "$T/head.txt" && ok || bad "1s-3: main did not move — HEAD must be untouched"

rb_repo unrelated; arm crash134; run_stage                          # 1s-4
[ -f "$T/npx-called" ] && bad "1s-4: an unresolvable merge-base must not rebase or typecheck" || ok
grep -q 'REBASE_VERIFY_INCONCLUSIVE' "$T/note.txt" && ok \
  || bad "1s-4: an empty merge-base is inconclusive, not a move (note: $(note))"
grep -qF "base=unresolved main=$MAIN" "$T/note.txt" && ok \
  || bad "1s-4: the note must say base=unresolved main=$MAIN — got: $(note)"
grep -q 'main moved' "$T/note.txt" \
  && bad "1s-4: 'main moved' must not be claimed without merge-base proof (note: $(note))" || ok
cmp -s "$T/prehead.txt" "$T/head.txt" && ok || bad "1s-4: HEAD must be untouched when the rebase is skipped"

rb_repo conflict; arm green; run_stage                              # 1s-5
grep -q 'REBASE_CONFLICT' "$T/note.txt" && ok \
  || bad "1s-5: a conflicting rebase must still say REBASE_CONFLICT (note: $(note))"
grep -qF "base=$MB main=$MAIN" "$T/note.txt" && ok \
  || bad "1s-5: the CONFLICT note must carry base=$MB main=$MAIN — got: $(note)"
[ -f "$T/npx-called" ] && bad "1s-5: a conflicted rebase never reaches the typecheck" || ok
cmp -s "$T/prehead.txt" "$T/head.txt" && ok || bad "1s-5: a conflict must reset to the pre-rebase head"

# --- 1h. the heap the verify typecheck runs at ------------------------------
rb_repo moved; arm green; run_stage TSC_HEAP_MB=4321                # 1h-1
grep -q -- '--max-old-space-size=4321' "$T/npx-env.txt" && ok \
  || bad "1h-1: TSC_HEAP_MB must reach tsc's NODE_OPTIONS (saw: $(cat "$T/npx-env.txt"))"

rb_repo moved ci-workflow; arm green; run_stage                     # 1h-2
grep -q -- '--max-old-space-size=6144' "$T/npx-env.txt" && ok \
  || bad "1h-2: the heap the repo's CI workflow declares must be used (saw: $(cat "$T/npx-env.txt"))"

rb_repo moved; arm green; run_stage                                 # 1h-3
grep -qE -- '--max-old-space-size=[1-9][0-9]*' "$T/npx-env.txt" && ok \
  || bad "1h-3: with no knob and no workflow the fallback heap must still be a positive integer (saw: $(cat "$T/npx-env.txt"))"

rb_repo moved ci-workflow; arm green; run_stage TSC_HEAP_MB=abc     # 1h-4
grep -q -- '--max-old-space-size=6144' "$T/npx-env.txt" && ok \
  || bad "1h-4: a non-numeric TSC_HEAP_MB must be ignored, not passed through (saw: $(cat "$T/npx-env.txt"))"

# ============================================================================
# 2. bin/merge-sweep.sh — an INCONCLUSIVE note parks the PR exactly like FAILED
# ============================================================================
if ! command -v jq >/dev/null; then
  echo "jq missing — section 2 (merge-sweep) skipped"
else
mkdir -p "$T/bin/lib" "$T/logs" "$T/flags" "$T/locks" "$T/env" "$T/tmp"
cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
# gh-rest.sh rides with the lib because the sweep's decision reads go through it
# (BH-784). Without it the sweep's fail-closed shims answer "unverifiable" to
# every read and no record ever reaches the merge.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
printf 'p o/plain - - 3 box-p\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
for s in beat.sh deploy-request.sh codegraph-ensure.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"; done
printf '#!/bin/bash\nexit 0\n' > "$T/bin/pre-arm-guards.sh"; chmod +x "$T/bin/pre-arm-guards.sh"

# The committedDate is a literal older than any RESULT file this test writes —
# no clock read, and the sweep therefore takes the "note may be live" path.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"rulesets"*) : ;;
  "api repos/o/plain -q .id") echo 1 ;;
  # The PR state read, over REST since BH-597: OPEN and CLEAN, which is what the
  # state,mergeStateStatus,author,headRefOid case below answered.
  "api repos/o/plain/pulls/8")
    echo '{"number":8,"html_url":"https://github.com/o/plain/pull/8","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"headsha","ref":"ticket/x-1"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}' ;;
  # The head commit date, now read off the head sha (BH-597) in place of the
  # json commits GraphQL page.
  "api repos/o/plain/commits/headsha -q .commit.committer.date") echo "2000-01-01T00:00:00Z" ;;
  *"--json commits"*) echo "2000-01-01T00:00:00Z" ;;
  *"actions/runs"*) cat "$T/ci-conclusion" ;;
  *"--json headRefOid"*) echo headsha ;;
  *"--json state,mergeStateStatus,author,headRefOid"*) echo "OPEN CLEAN operator headsha" ;;
  # THE DECISION READS ARE REST NOW (BH-784): gh api -i -X GET, judged on the
  # HTTP status line, so restpr prints a whole response. Same facts the --json
  # arms above carry - OPEN, CLEAN, operator, headsha - just in the shape the
  # library parses. The diff shares the pulls path and is told apart by its
  # Accept header, so it is matched first, and the commits list before the
  # single-pull read for the same reason.
  *"v3.diff"*) restpr --diff "+ const x = 1;
" ;;
  *"api -i -X GET repos/o/plain/pulls/8/commits"*)
    restpr --raw 200 '[{"commit":{"committer":{"date":"2000-01-01T00:00:00Z"}}}]' ;;
  # gh exits 0 on the merge, and the marker it drops is what makes the NEXT read
  # of this PR say MERGED - the same before/after the old --json state arms gave.
  *"api -i -X GET repos/o/plain/pulls/8"*)
    if [ -f "$T/merged" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  # The issue close-out: the comment POST, the close PATCH, and the re-read
  # gh_rest_close does before it reports the close landed.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; touch "$T/merged"; exit 0 ;;
  *"pr view https://github.com/o/plain/pull/8 --json state,isInMergeQueue"*) echo "MERGED false" ;;
  *"pr view https://github.com/o/plain/pull/8 --json state"*) echo "MERGED" ;;
  *"--json mergeCommit"*) echo "deadbeefcafe" ;;
  *"issue comment"*|*"issue close"*) printf '%s\n' "\$*" >> "$T/issue-calls.txt" ;;
  *"pr diff"*) echo "+ const x = 1;" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

sweep_setup() { # sweep_setup <result-note> <ci-conclusion>
  scratch_rm "$T/builds"; mkdir -p "$T/builds/pool-p-XX-8-202609120001"
  echo "PR_CREATED https://github.com/o/plain/pull/8$1" > "$T/builds/pool-p-XX-8-202609120001/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/builds/pool-p-XX-8-202609120001/review.md"
  : > "$T/builds/pool-p-XX-8-202609120001/pipeline.log"
  printf '%s\n' "$2" > "$T/ci-conclusion"
  : > "$T/state/merge-sweep-done.txt"; : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"
  : > "$T/merge-calls.txt"; : > "$T/issue-calls.txt"; : > "$T/gh-calls.txt"
  rm -f "$T/merged"
  rm -f "$T/tmp"/*.probe 2>/dev/null
}
run_sweep() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T" SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
  bash "$T/bin/sweep.sh" >/dev/null 2>"$T/sweep.err" ) || true; }

INC_NOTE=" | REBASE_VERIFY_INCONCLUSIVE: main moved (base=aaaaaaaaaaaa main=bbbbbbbbbbbb) but the rebase typecheck did not finish — tsc exit 134 with no diagnostics at heap 6144MB — PR is based on the older main, rebase unverified"

sweep_setup "$INC_NOTE" failure                                      # 2-1
run_sweep
[ -s "$T/merge-calls.txt" ] \
  && bad "2-1 sweep: an INCONCLUSIVE note with red CI must park the PR, not merge it (calls: $(cat "$T/merge-calls.txt"))" || ok
grep -qxF 'https://github.com/o/plain/pull/8' "$T/state/merge-sweep-done.txt" \
  && bad "2-1 sweep: a parked PR must not be recorded as handled" || ok

sweep_setup "$INC_NOTE" success                                      # 2-2
run_sweep
grep -q 'REBASE_VERIFY note superseded by green CI Typecheck' "$T/logs/merge-sweep.log" && ok \
  || bad "2-2 sweep: a green CI Typecheck on the head must supersede the INCONCLUSIVE note (log: $(cat "$T/logs/merge-sweep.log"))"
[ -s "$T/merge-calls.txt" ] && ok \
  || bad "2-2 sweep: with CI green the sweep must proceed to the merge"

sweep_setup " | REBASE_VERIFY_FAILED: main moved (base=aaaaaaaaaaaa main=bbbbbbbbbbbb) and the rebase typechecks red — PR is based on the older main, needs a fix pass" failure   # 2-3
run_sweep
[ -s "$T/merge-calls.txt" ] \
  && bad "2-3 sweep: today's FAILED park must be unchanged (calls: $(cat "$T/merge-calls.txt"))" || ok
fi

echo "rebase-verify-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
