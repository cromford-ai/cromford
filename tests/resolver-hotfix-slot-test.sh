#!/bin/bash
# tests/resolver-hotfix-slot-test.sh — the resolver's fix-round SLOTS and the
# cooperative yield (#643 fix 2, BH-646).
#
# WHY THIS IS THE TEST THAT MATTERS. A fix round is one execute-stage agent call
# that can hold its worktree for 90 minutes. Today they run unbounded across
# overlapping */10 ticks, so a hotfix park that arrives while three of them are
# working waits for one of them to finish. BR_FIX_SLOTS caps them, BR_HOTFIX_RESERVE
# holds slots back for rank-0 work, and when every slot is held by plain work the
# hotfix asks the OLDEST plain round to yield — a marker on disk, never a signal,
# never a wait.
#
# Three ways that goes wrong and every one of them is silent:
#   * the cap refuses a round and something records it as a rung anyway, so the
#     ladder walks a park toward REBUILD FRESH for a reason that was never about
#     the PR (§1: the state json must be byte-identical across a deferral);
#   * the yield KILLS the agent mid-write, which is the one thing the ticket says
#     must never happen (§3: the stub agent records every signal it receives, and
#     the assertion is that the record is empty);
#   * a yield throws the work away, so the tokens are spent twice (§3/§3b:
#     `brfix/<ck>` must still be there, carrying the agent's commit).
#
# So §3, §3b and §4 drive the REAL br_fix_round, lifted verbatim out of the
# script, against a REAL git repo with a REAL bare remote — "did it push" is a
# fact on disk rather than a stub's opinion — and §5 drives the whole lane
# through bin/blocked-resolver.sh itself.
# Run from anywhere: tests/resolver-hotfix-slot-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# ONE clock read for the whole suite (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"; export HARNESS="$H"
ST="$H/state/blocked-resolver"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$ST" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/scheduler-conf.sh" "$H/bin/lib/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/git-identity.sh" "$H/bin/lib/"
# BH-1134: the fix round pushes only commits authored AS the global git identity
# (bin/lib/git-identity.sh, fail-closed when absent). The scratch global is the
# t@t this suite's commits already carry; the real ~/.gitconfig is never read.
export GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/" 2>/dev/null || true
# BH-2504: the fix round pushes only through bin/lib/hold-push.sh.
cp "$DIR/bin/lib/hold-push.sh" "$H/bin/lib/"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"
for f in beat.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# ---------------------------------------------------------------------------
# A REAL repo and a REAL bare remote. "Did the round push" is then a sha on
# disk, which is the only form of that answer worth asserting.
# ---------------------------------------------------------------------------
export GIT_AUTHOR_NAME=harness GIT_AUTHOR_EMAIL=harness@test
export GIT_COMMITTER_NAME=harness GIT_COMMITTER_EMAIL=harness@test
ORIGIN="$T/origin.git"
git init -q --bare -b main "$ORIGIN"
CLONE="$T/repos/tproj"
git init -q -b main "$CLONE"
echo base > "$CLONE/base.txt"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm base
git -C "$CLONE" remote add origin "$ORIGIN"
git -C "$CLONE" push -q origin main
git -C "$CLONE" checkout -q -b ticket/TK-9
echo branch > "$CLONE/branch.txt"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "the ticket's own change"
git -C "$CLONE" push -q origin ticket/TK-9
git -C "$CLONE" checkout -q main
git -C "$CLONE" fetch -q origin
PRHEAD=$(git -C "$CLONE" rev-parse origin/ticket/TK-9)

# The fake gh. The PR read is REST (br_pr_ref) and answers the REAL head sha of
# the branch above, so the push lease is the one the round would take on a box.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh decides over REST now (#783): the shared envelope
  # stub answers the -i routes off the fixture files written beside it.
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/TK-9' > "$T/prbranch"
    printf 'TK-9: a thing' > "$T/prtitle"
    printf '%s' "$PRHEAD" > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  # THE HOLD READ (bin/lib/hold.sh). br_hold_gate reads the issue and its
  # comments over plain \`gh api\`; an empty body is an UNREADABLE hold and the
  # park never reaches the rung under test. Nothing here is held.
  *"issues/"*"/comments"*) cat "$T/issue-comments.json" ;;
  *"repos/"*"/issues/"*)   cat "$T/issue.json" ;;
  *"pr comment"*)  printf '%s\n' "\$*" >> "$T/pr-comment.txt"; exit 0 ;;
  *"pr close"*)    printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)     echo "$PRHEAD ticket/TK-9" ;;
  *"--json headRefName"*) echo "ticket/TK-9" ;;
  *"--json comments"*) echo "Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated." ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# Issue 9: open, ai-build, no HOLD comment.
printf '%s\n' '{"number":9,"state":"open","labels":[{"name":"ai-build"}],"title":"TK-9: a thing","body":"## Scope"}' > "$T/issue.json"
printf '[]\n' > "$T/issue-comments.json"
# The PR comment the ladder reads to choose the FIX ROUND rung. It travels over
# REST now (#783), so it lives where the shared envelope stub looks for it.
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/prcomments"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
# ssh is RECORDED and never real: a test that reaches a box is a test that has
# already failed.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

# The stub agent. It RECORDS its call, RECORDS any signal it is sent (the
# ticket's "never killed mid-write" is only observable here), optionally plants
# the yield marker itself — which is how §3b reaches checkpoint (b) and only
# checkpoint (b) — and leaves a real commit behind, because a round that
# produced no commit is a different code path.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
trap 'printf "INT\n"  >> "$T/agent-signals.txt"' INT
trap 'printf "TERM\n" >> "$T/agent-signals.txt"' TERM
trap 'printf "HUP\n"  >> "$T/agent-signals.txt"' HUP
printf '%s\n' "\$1 \$2" >> "$T/agent-calls.txt"
[ -n "\${AGENT_PLANT_YIELD:-}" ] && printf 'requested_by=%s\n' "\${AGENT_PLANT_REQUESTER:-HOTFIX}" > "\$AGENT_PLANT_YIELD"
echo "the fix the agent made" >> agent-fix.txt
git add -A >/dev/null 2>&1
git commit -qm "fix round: the agent's commit" >/dev/null 2>&1
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"

# ---------------------------------------------------------------------------
# The functions under test, lifted out of the script the way
# tests/resolver-pr-read-failed-test.sh does it — the script's top level is a
# whole lane run.
# ---------------------------------------------------------------------------
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
# The name is matched EXACTLY (`<name>()`), never as a prefix: with the record
# layer in bin/lib/br/record.sh, `br_record_index()` comes before `br_record()`
# in the corpus, and awk reads an escaped "()" as an empty group, so a prefix match lifted
# the wrong function (merge-queue batch #6436).
fn() { awk -v N="$1" 'index($0, N "()") == 1 && substr($0, length(N) + 3, 1) ~ /^( |\{|$)/ {f=1} f{print} f&&/^}$/{exit}' "$T/br-corpus.sh"; }
LIFTED="$T/lifted.sh"; export LIFTED
{
  cat <<EOF
H="$H"; export HARNESS="$H"
ST="$H/state/blocked-resolver"
LOG="$H/logs/blocked-resolver.log"
NOTES="$H/state/build-notes"
REPOS="$T/repos"
OBSERVE=0
MAX_FIXROUNDS=\${MAX_FIXROUNDS:-1}
MAX_REBUILDS=3
MAX_MECHANICAL=1
CI_LOG_BYTES=6000
CI_LOG_RUNS=3
FIX_AGENT_TIMEOUT=120
EXECUTE_MODEL=test-model
# BH-1510.1: br_fix_round reads the env override the script captured at load
# (BR_EXECUTE_MODEL_ENV) through br_model, so both travel with the lift.
BR_EXECUTE_MODEL_ENV=test-model
BR_ROUND_FILE=""
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say()   { echo "\$(STAMP) \$*" >> "\$LOG"; }
. "$H/bin/lib/merge-conductor-lib.sh"; mc_init
. "$H/bin/lib/hotfix-lib.sh"
. "$H/bin/lib/scheduler-conf.sh"
declare -A _BR_AUTH_SAID
# The PR comment the round posts goes over REST (#783), so the contract travels
# with the lift — without it br_pr_comment is an undefined command and "the
# round commented" can never be observed.
. "$H/bin/lib/gh-rest.sh"
# BH-1134: the lane sources the commit-identity lib at its top level, and
# br_fix_round refuses to push (fail closed) when gi_check is not defined.
. "$H/bin/lib/git-identity.sh"
# BH-2504: the round's push goes through hold_push (bin/lib/hold-push.sh).
. "$H/bin/lib/hold-push.sh"
EOF
  for f in br_rkey br_cap_key br_file br_load br_save br_num br_record br_event br_ladder_class \
           br_slug_of_url br_use_token br_pr_ref br_ci_log br_findings \
           br_round_file br_rounds_live br_rounds_running br_round_begin br_round_end \
           br_pr_comment br_wt_drop br_model \
           br_cap_rows br_rows_count br_auth_log \
           br_yield_request br_yield_take br_fix_round; do
    src=$(fn "$f")
    [ -n "$src" ] || { echo "# MISSING $f" ; continue; }
    printf '%s\n' "$src"
  done
  # The stubs come LAST so they win: everything above is the real thing.
  cat <<EOF
br_findings()      { printf '%s\n' "Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated."; }
br_setup_blocked() { printf 'SETUP_BLOCKED %s\n' "\$*" >> "$T/rungs.txt"; }
br_rebuild_fresh() { printf 'REBUILD_FRESH %s\n' "\$*" >> "$T/rungs.txt"; }
# This suite is about the slot, not the hold: the park names no GitHub issue
# (rc 1, a board ticket), so the push is the lease alone.
br_hold_issue()    { return 1; }
EOF
} > "$LIFTED"
for f in br_round_file br_rounds_live br_rounds_running br_round_begin br_round_end \
         br_wt_drop br_yield_request br_yield_take; do
  grep -q "^# MISSING $f\$" "$LIFTED" && bad "$f is not defined in bin/blocked-resolver.sh" || ok
done

cat > "$T/round.sh" <<'EOS'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$LIFTED"
br_fix_round "$@"
EOS

# ROUND <env-assignments...> -- <br_fix_round args>  — one round, its own
# process, a TRUE exit code (never piped).
ROUND() {
  local envs=()
  while [ "${1:-}" != "--" ] && [ $# -gt 0 ]; do envs+=("$1"); shift; done
  shift
  timeout 120 env HARNESS="$H" FLEET_CONF="$H/fleet.conf" LIFTED="$LIFTED" T="$T" \
    ${envs[*]:+"${envs[@]}"} bash "$T/round.sh" "$@"
}
LOG="$H/logs/blocked-resolver.log"
ROUNDS="$ST/rounds"
CK=tproj-TK-9                       # br_cap_key tproj <rkey> TK-9
ROWFILE="$ROUNDS/tproj-$CK.json"    # br_round_file tproj $CK
MARKER="${ROWFILE%.json}.yield"
URL=https://github.com/o/tproj/pull/9
REC="$H/builds/tproj-TK-9-20260917000001"
HOTREC="$H/builds/tproj-TK-8-20260917000002"
mkdir -p "$REC" "$HOTREC"
printf 'PR_CREATED %s\n' "$URL" > "$REC/RESULT"
printf '{"labels":[]}\n' > "$REC/ticket-meta.json"
printf 'PR_CREATED https://github.com/o/tproj/pull/8\n' > "$HOTREC/RESULT"
printf '{"labels":[{"name":"hotfix"}]}\n' > "$HOTREC/ticket-meta.json"

LIVE_PID=""
live_round() { # live_round <name> <hotfix 0|1> <started_at> — a REAL running pid
  mkdir -p "$ROUNDS"
  sleep 600 >/dev/null 2>&1 <&- &   # determinism: ok this sleep is a process-liveness fixture, never waited on
  LIVE_PID=$!
  jq -nc --argjson pid "$LIVE_PID" --argjson t "$3" --argjson h "$2" --arg n "$1" \
    '{pid:$pid,started_at:$t,hotfix:$h,project:"tproj",ck:$n,rkey:$n}' > "$ROUNDS/$1.json"
}
kill_live() { [ -n "$LIVE_PID" ] && kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null; LIVE_PID=""; }
reset() {
  : > "$LOG"; : > "$T/agent-calls.txt"; : > "$T/agent-signals.txt"
  : > "$T/rungs.txt"; : > "$T/pr-comment.txt"; : > "$T/comments.txt"
  scratch_rm "$ROUNDS"; scratch_rm "$ST/tproj"
  scratch_rm "$H/tmp"
  git -C "$CLONE" worktree prune >/dev/null 2>&1
  git -C "$CLONE" branch -D "brfix/$CK" >/dev/null 2>&1
  git -C "$CLONE" push -q -f origin "$PRHEAD:refs/heads/ticket/TK-9" 2>/dev/null
  git -C "$CLONE" fetch -q origin
}

# ============================================================================
# §0. THE LEDGER. A row per running round, keyed the way the per-key flock
#     already is, and a row whose pid is dead is deleted ON READ — nothing
#     sweeps it later, because "later" is how a phantom slot outlives the box.
# ============================================================================
reset
# shellcheck source=/dev/null
. "$LIFTED"
[ "$(br_round_file tproj "$CK")" = "$ROWFILE" ] && ok \
  || bad "§0 br_round_file must name state/blocked-resolver/rounds/<project>-<ck>.json, got '$(br_round_file tproj "$CK")'"
br_round_begin tproj "$CK" 1 o-tproj-9
[ -s "$ROWFILE" ] && ok || bad "§0 br_round_begin must write the row"
missing=$(jq -r '[.pid,.started_at,.hotfix,.project,.ck,.rkey] | map(select(. == null)) | length' "$ROWFILE" 2>/dev/null)
[ "$missing" = 0 ] && ok || bad "§0 the row must carry pid, started_at, hotfix, project, ck, rkey: $(cat "$ROWFILE")"
[ "$(jq -r '.hotfix' "$ROWFILE")" = 1 ] && ok || bad "§0 the row must record that this is a hotfix round"
[ "$(br_rounds_running)" = 1 ] && ok || bad "§0 a live round counts 1, got '$(br_rounds_running)'"
# The marker and the row die together, and a second call is a no-op.
printf 'requested_by=OTHER\n' > "$MARKER"
br_round_end
[ -e "$ROWFILE" ] && bad "§0 br_round_end must remove the row" || ok
[ -e "$MARKER" ] && bad "§0 br_round_end must remove the yield marker with the row" || ok
br_round_end && ok || bad "§0 br_round_end must be safe to call twice"

# A DEAD pid is stale, and it is gone from DISK after one read.
live_round other-live 0 "$NOW"
( : ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
jq -nc --argjson pid "$DEADPID" --argjson t "$NOW" \
  '{pid:$pid,started_at:$t,hotfix:0,project:"tproj",ck:"dead",rkey:"dead"}' > "$ROUNDS/dead.json"
printf 'nonsense not json\n' > "$ROUNDS/garbage.json"
[ "$(br_rounds_running)" = 1 ] && ok || bad "§0 only the live round counts, got '$(br_rounds_running)' of $(ls "$ROUNDS")"
[ -e "$ROUNDS/dead.json" ] && bad "§0 a row whose pid is dead must be deleted on read" || ok
[ -e "$ROUNDS/garbage.json" ] && bad "§0 an unreadable row must be deleted on read" || ok
[ -e "$ROUNDS/other-live.json" ] && ok || bad "§0 the live row must survive the prune"
kill_live

# ============================================================================
# §1. THE SLOTS. A plain round is refused at BR_FIX_SLOTS - BR_HOTFIX_RESERVE;
#     a hotfix round only at BR_FIX_SLOTS. A refusal spends NOTHING.
# ============================================================================
reset
live_round other-live 0 "$NOW"
# The park's state row as it stands before the deferral. Byte-identical after
# is the assertion: a cap that refuses must not look like a rung that ran.
mkdir -p "$ST/tproj"
jq -nc --arg t "2026-09-17 00:00:00Z" \
  '{project:"tproj",rkey:"tproj-TK-9",first_seen:$t,rebuilds:0,fixrounds:0,mechanicals:0,adjudications:0,rereviews:0,outcome:"",attempts:[]}' \
  > "$ST/tproj/$CK.json"
cp "$ST/tproj/$CK.json" "$T/state-before.json"
ROUND BR_FIX_SLOTS=2 BR_HOTFIX_RESERVE=1 -- tproj o-tproj-9 head-not-reapproved "$URL" "$REC" TK-9
rc=$?
[ "$rc" = 0 ] && ok || bad "§1 a deferred plain round must exit 0, got $rc"
grep -q 'deferred: 1 of 2 slots busy, 1 reserved for hotfix' "$LOG" && ok \
  || bad "§1 the deferral must be logged with its numbers: $(cat "$LOG")"
[ -s "$T/agent-calls.txt" ] && bad "§1 a deferred round must call no agent: $(cat "$T/agent-calls.txt")" || ok
cmp -s "$T/state-before.json" "$ST/tproj/$CK.json" && ok \
  || bad "§1 a deferral must leave the state json byte-identical: $(cat "$ST/tproj/$CK.json")"
[ -e "$ROWFILE" ] && bad "§1 a deferred round must write no ledger row" || ok

# THE SAME TICK, THE SAME SLOTS, A HOTFIX PARK: it runs. This is the parent
# ticket's acceptance — "a blocked hotfix PR gets a resolver round while
# non-hotfix rounds are running".
: > "$LOG"; : > "$T/agent-calls.txt"
ROUND BR_FIX_SLOTS=2 BR_HOTFIX_RESERVE=1 -- tproj o-tproj-9 head-not-reapproved "$URL" "$HOTREC" TK-9
[ "$(wc -l < "$T/agent-calls.txt")" = 1 ] && ok \
  || bad "§1 a hotfix park must get its round while a plain one runs: calls=$(cat "$T/agent-calls.txt") log=$(cat "$LOG")"
grep -q 'deferred:' "$LOG" && bad "§1 a hotfix park must not be deferred below BR_FIX_SLOTS: $(cat "$LOG")" || ok

# AND THE DEFAULT CHANGES NOTHING. BR_FIX_SLOTS=0 is unlimited, which is what
# every box runs today.
reset
live_round other-live 0 "$NOW"
ROUND BR_FIX_SLOTS=0 -- tproj o-tproj-9 head-not-reapproved "$URL" "$REC" TK-9
[ "$(wc -l < "$T/agent-calls.txt")" = 1 ] && ok \
  || bad "§1 BR_FIX_SLOTS=0 must run the plain round: calls=$(cat "$T/agent-calls.txt") log=$(cat "$LOG")"
grep -q 'deferred:' "$LOG" && bad "§1 BR_FIX_SLOTS=0 must count nothing: $(cat "$LOG")" || ok
kill_live

# THE RESERVE CANNOT STARVE PLAIN WORK. BR_HOTFIX_RESERVE >= BR_FIX_SLOTS is
# clamped to slots-1, so one plain round can always run.
reset
ROUND BR_FIX_SLOTS=1 BR_HOTFIX_RESERVE=5 -- tproj o-tproj-9 head-not-reapproved "$URL" "$REC" TK-9
[ "$(wc -l < "$T/agent-calls.txt")" = 1 ] && ok \
  || bad "§1 a reserve at or above the cap must still leave one plain slot: $(cat "$LOG")"

# ============================================================================
# §2. THE YIELD REQUEST. Every slot held by plain work and a hotfix arrives:
#     one marker on the OLDEST plain round, no round this tick, nothing waits.
# ============================================================================
reset
live_round oldest-live 0 "$((NOW - 900))"
OLDEST=$LIVE_PID
sleep 600 >/dev/null 2>&1 <&- &   # determinism: ok this sleep is a process-liveness fixture, never waited on
YOUNGER=$!
jq -nc --argjson pid "$YOUNGER" --argjson t "$NOW" \
  '{pid:$pid,started_at:$t,hotfix:0,project:"tproj",ck:"younger",rkey:"younger"}' > "$ROUNDS/younger-live.json"
START=$(date +%s)
timeout 5 env HARNESS="$H" FLEET_CONF="$H/fleet.conf" LIFTED="$LIFTED" T="$T" \
  BR_FIX_SLOTS=1 BR_HOTFIX_RESERVE=0 \
  bash "$T/round.sh" tproj o-tproj-9 head-not-reapproved "$URL" "$HOTREC" TK-9
rc=$?
[ "$rc" = 0 ] && ok || bad "§2 the yield request must exit 0 inside 5s, got $rc"
[ "$(( $(date +%s) - START ))" -lt 5 ] && ok || bad "§2 the requester must not wait on the round it asked"
[ "$(ls "$ROUNDS"/*.yield 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "§2 exactly one yield marker must exist, got: $(ls "$ROUNDS")"
[ -e "$ROUNDS/oldest-live.yield" ] && ok \
  || bad "§2 the OLDEST plain round must be the one asked: $(ls "$ROUNDS")"
grep -q "requested_by=$CK" "$ROUNDS/oldest-live.yield" && ok \
  || bad "§2 the marker must name the hotfix that asked: $(cat "$ROUNDS/oldest-live.yield")"
[ -s "$T/agent-calls.txt" ] && bad "§2 the requester must run no agent: $(cat "$T/agent-calls.txt")" || ok
[ -e "$ROWFILE" ] && bad "§2 the requester must write no ledger row of its own" || ok
# IDEMPOTENT: a second identical tick leaves exactly one marker, unchanged.
cp "$ROUNDS/oldest-live.yield" "$T/marker-before"
ROUND BR_FIX_SLOTS=1 BR_HOTFIX_RESERVE=0 -- tproj o-tproj-9 head-not-reapproved "$URL" "$HOTREC" TK-9
[ "$(ls "$ROUNDS"/*.yield 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "§2 a second tick must not add a second marker: $(ls "$ROUNDS")"
cmp -s "$T/marker-before" "$ROUNDS/oldest-live.yield" && ok || bad "§2 the marker must be left alone once written"
kill "$YOUNGER" 2>/dev/null; wait "$YOUNGER" 2>/dev/null
kill_live

# A HOTFIX NEVER PREEMPTS A HOTFIX. One live round is itself rank 0: no marker,
# the ordinary deferral instead.
reset
live_round hot-live 1 "$((NOW - 900))"
ROUND BR_FIX_SLOTS=1 BR_HOTFIX_RESERVE=0 -- tproj o-tproj-9 head-not-reapproved "$URL" "$HOTREC" TK-9
[ "$(ls "$ROUNDS"/*.yield 2>/dev/null | wc -l)" = 0 ] && ok \
  || bad "§2 a hotfix must not preempt a hotfix round: $(ls "$ROUNDS")"
grep -q 'deferred:' "$LOG" && ok || bad "§2 the hotfix must log the ordinary deferral instead: $(cat "$LOG")"
[ -s "$T/agent-calls.txt" ] && bad "§2 no round runs past the cap: $(cat "$T/agent-calls.txt")" || ok
kill_live

# ============================================================================
# §3. THE YIELD TAKE, CHECKPOINT (a) — the marker is there before the agent
#     call. The round gives its slot back and gives up NOTHING else.
# ============================================================================
reset
mkdir -p "$ROUNDS"
printf 'requested_by=tproj-HOT-1\n' > "$MARKER"
BEFORE_ORIGIN=$(git -C "$CLONE" rev-parse origin/ticket/TK-9)
ROUND BR_FIX_SLOTS=0 -- tproj o-tproj-9 head-not-reapproved "$URL" "$REC" TK-9
rc=$?
[ "$rc" = 0 ] && ok || bad "§3 a yielding round must exit 0, got $rc"
grep -q 'EVENT resolver_yield' "$LOG" && ok || bad "§3 the yield must be one EVENT line: $(cat "$LOG")"
[ -s "$T/agent-calls.txt" ] && bad "§3 checkpoint (a) must yield BEFORE the agent call: $(cat "$T/agent-calls.txt")" || ok
[ -s "$T/agent-signals.txt" ] && bad "§3 the agent process must never be signalled: $(cat "$T/agent-signals.txt")" || ok
[ -e "$MARKER" ] && bad "§3 the marker must be removed by the round that took it" || ok
[ -e "$ROWFILE" ] && bad "§3 the ledger row must be removed on a yield" || ok
git -C "$CLONE" rev-parse --verify -q "brfix/$CK" >/dev/null && ok \
  || bad "§3 brfix/$CK must be LEFT IN PLACE so the next round reuses the work"
[ -z "$(git -C "$CLONE" worktree list --porcelain | awk -v b="refs/heads/brfix/$CK" '$1=="branch" && $2==b {print}')" ] && ok \
  || bad "§3 the worktree must be removed: $(git -C "$CLONE" worktree list --porcelain)"
git -C "$CLONE" fetch -q origin
[ "$(git -C "$CLONE" rev-parse origin/ticket/TK-9)" = "$BEFORE_ORIGIN" ] && ok \
  || bad "§3 a yield must push nothing"
{ [ -s "$T/pr-comment.txt" ] || [ -s "$T/comments.txt" ]; } \
  && bad "§3 a yield must post no PR comment: $(cat "$T/pr-comment.txt" "$T/comments.txt" 2>/dev/null)" || ok
[ -e "$ST/tproj/$CK.json" ] && bad "§3 a yield must write no state row: $(cat "$ST/tproj/$CK.json")" || ok

# §3b. CHECKPOINT (b) — the marker appears WHILE the agent is working, so only
#      the post-call checkpoint can see it. The agent's commit must survive.
reset
ROUND BR_FIX_SLOTS=0 AGENT_PLANT_YIELD="$MARKER" AGENT_PLANT_REQUESTER=tproj-HOT-2 \
  -- tproj o-tproj-9 head-not-reapproved "$URL" "$REC" TK-9
rc=$?
[ "$rc" = 0 ] && ok || bad "§3b a yielding round must exit 0, got $rc"
[ "$(wc -l < "$T/agent-calls.txt")" = 1 ] && ok || bad "§3b the agent must have run: $(cat "$LOG")"
grep -q 'EVENT resolver_yield' "$LOG" && ok || bad "§3b checkpoint (b) must yield after the call: $(cat "$LOG")"
[ -s "$T/agent-signals.txt" ] && bad "§3b the agent must never be signalled: $(cat "$T/agent-signals.txt")" || ok
[ -e "$MARKER" ] && bad "§3b the marker must be removed" || ok
[ -e "$ROWFILE" ] && bad "§3b the ledger row must be removed" || ok
BRFIXLOG=$(git -C "$CLONE" log --oneline "brfix/$CK" 2>/dev/null)
grep -q "the agent's commit" <<<"$BRFIXLOG" && ok \
  || bad "§3b brfix/$CK must carry the agent's commit — a yield that loses the work buys the tokens twice"
git -C "$CLONE" fetch -q origin
[ "$(git -C "$CLONE" rev-parse origin/ticket/TK-9)" = "$PRHEAD" ] && ok || bad "§3b a yield must push nothing"
[ -e "$ST/tproj/$CK.json" ] && bad "§3b a yield must bump no counter: $(cat "$ST/tproj/$CK.json")" || ok

# ============================================================================
# §4. THE NEGATIVE. No marker, no cap: the round pushes and bumps fixrounds
#     exactly as it does today.
# ============================================================================
reset
ROUND BR_FIX_SLOTS=0 -- tproj o-tproj-9 head-not-reapproved "$URL" "$REC" TK-9
rc=$?
[ "$rc" = 0 ] && ok || bad "§4 the ordinary round must exit 0, got $rc"
[ "$(wc -l < "$T/agent-calls.txt")" = 1 ] && ok || bad "§4 the agent must run exactly once: $(cat "$LOG")"
git -C "$CLONE" fetch -q origin
[ "$(git -C "$CLONE" rev-parse origin/ticket/TK-9)" != "$PRHEAD" ] && ok \
  || bad "§4 the round must push its commit to the real remote"
[ "$(jq -r '.fixrounds' "$ST/tproj/$CK.json" 2>/dev/null)" = 1 ] && ok \
  || bad "§4 fixrounds must be 1: $(cat "$ST/tproj/$CK.json" 2>/dev/null)"
{ grep -q 'pr comment' "$T/pr-comment.txt" || [ -s "$T/comments.txt" ]; } \
  && ok || bad "§4 the round must comment on the PR"
grep -q 'EVENT resolver_yield' "$LOG" && bad "§4 nothing yielded here: $(cat "$LOG")" || ok

# ============================================================================
# §5. THE WHOLE LANE, through bin/blocked-resolver.sh itself. The cap has to
#     work where it ships — inside a real tick, with the per-key lock, the
#     candidate loop and the EXIT trap that drops the ledger row.
# ============================================================================
reset
printf '%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\t%s\n' \
  "o/tproj#9" "$NOW" "head-not-reapproved" "$URL" > "$H/state/merge-conductor/pr-state.tsv"
live_round other-live 0 "$NOW"
TICK() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
             BR_SSH="$T/fakebin/br-ssh" \
             env "$@" bash "$H/bin/blocked-resolver.sh" >>"$T/tick.log" 2>&1 ) || true; }
TICK BR_FIX_SLOTS=1 BR_HOTFIX_RESERVE=0
grep -q 'deferred: 1 of 1 slots busy' "$LOG" && ok \
  || bad "§5 a real tick must defer the plain park: $(cat "$LOG")"
[ -s "$T/agent-calls.txt" ] && bad "§5 a deferred tick must call no agent: $(cat "$T/agent-calls.txt")" || ok
[ -e "$ST/tproj/$CK.json" ] && bad "§5 a deferred tick must write no state row" || ok
# The park is RE-OFFERED, never dropped: the slot frees and the next tick takes it.
kill_live
: > "$LOG"
TICK BR_FIX_SLOTS=1 BR_HOTFIX_RESERVE=0
[ "$(wc -l < "$T/agent-calls.txt")" = 1 ] && ok \
  || bad "§5 the freed slot must be taken by the next tick: $(cat "$LOG")"
[ "$(jq -r '.fixrounds' "$ST/tproj/$CK.json" 2>/dev/null)" = 1 ] && ok \
  || bad "§5 the round must have run for real: $(cat "$ST/tproj/$CK.json" 2>/dev/null)"
[ -z "$(ls -A "$ROUNDS" 2>/dev/null)" ] && ok \
  || bad "§5 the ledger row must be dropped when the round's subshell exits: $(ls -A "$ROUNDS")"

echo "resolver-hotfix-slot: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
