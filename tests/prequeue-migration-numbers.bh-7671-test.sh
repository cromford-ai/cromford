#!/bin/bash
# tests/prequeue-migration-numbers.bh-7671-test.sh — BH-7671: right before the
# merge conductor queues a READY head, its pre-queue gate (pq_gate,
# bin/lib/mc-prequeue.sh) checks the head's ADDED migration numbers against
# current main and every QUEUED PR, through the hook
# bin/lib/mc-prequeue.d/migration-numbers.sh and bin/lib/migration-renumber.sh.
# On a collision it renumbers, pushes and holds: the new head is re-reviewed
# before it queues.
#
#   Q1  the acceptance case: 0336 was free at the rebase and main took it
#       before the queue step: hold, one renumber commit on origin (every
#       reference form moved, one Union-resolved trailer), one pushed line,
#       never enqueued
#   Q2  main did not take 0336: proceed, no push, one list read
#   Q3  a QUEUED higher PR holds 0337: hold, moved above every open number
#   Q4  the same PR open but not queued: proceed, no push
#   Q5  the git lock is busy and the head is not in the clone: hold, no push,
#       no terminal mark, one held line over two ticks
#   Q6  a decline (main at 9999): hold, one mignumfail mark, one warn alert;
#       the next tick runs no git and sends no second alert
#   Q7  no migration_renumber.dir: proceed, no git, no lock, no list, no
#       PREQUEUE_CALL call=mignum line
#   Q8  MC_MIGRATION_RECHECK=0: proceed, no git
#   Q9  ACTIONS=0: proceed, no git
#   Q10 a HOLD on the ticket at push time: hold, nothing pushed, not terminal
#   Q11 the open-PR list read fails (rc 75): main only, still renumbered, one
#       note line in the conductor log
#   Q12 REBASE_ON_POOL: hold, one pool enqueue over two ticks
#   Q13 the push answers 0 but origin does not show the new sha: refused,
#       terminal mark, alert
#   Q14 after Q1: no reviewed-sha written, no job_verdict_rebind call, and
#       restamp_same refuses (old head, new head): lead-carry does not carry
#   Q15 pq_gate called as ec_requeue_gate calls it (PQ_MIN_AT): hold
#   X1  the project-6 #2055 replay names: caught, moved off 0336
#   M1  mutation: pq_gate without the pq_mignum call proceeds on Q1
#
# Real git: a local origin behind a github url (insteadOf), the conductor's
# clone of it, the real bin/lib/hold-push.sh push (its hold read stubbed). The
# mc_* conductor helpers and gh_rest_pr_list_all are stubs. No network.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-migration-numbers.bh-7671-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc-prequeue.d/migration-numbers.sh" ] || { echo "FAIL: bin/lib/mc-prequeue.d/migration-numbers.sh does not exist"; exit 1; }

SLUG=o/r; NUM=31; GHURL="https://github.com/$SLUG.git"
O="$T/origin.git"; W="$T/work"; CL="$T/repos/proj"; OJ="$T/open.json"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.invalid
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global advice.detachedHead false
git config --global "url.$O.insteadOf" "$GHURL"
export MC_STATE_DIR="$T/state" MC_REPOS="$T/repos"
ATT="$T/att"; LOG="$T/log"; ALERTS="$T/alerts"; GITCALLS="$T/gitcalls"; LOCKS="$T/locks"; LISTS="$T/lists"

# shellcheck source=bin/lib/mc-prequeue.sh
. "$DIR/bin/lib/mc-prequeue.sh" || { echo "FAIL: cannot source bin/lib/mc-prequeue.sh"; exit 1; }
# shellcheck source=bin/lib/hold-push.sh
. "$DIR/bin/lib/hold-push.sh" || { echo "FAIL: cannot source bin/lib/hold-push.sh"; exit 1; }
# shellcheck source=bin/lib/migration-renumber.sh
. "$DIR/bin/lib/migration-renumber.sh" || { echo "FAIL: cannot source bin/lib/migration-renumber.sh"; exit 1; }
# shellcheck source=bin/lib/schema-restamp.sh
. "$DIR/bin/lib/schema-restamp.sh" || { echo "FAIL: cannot source bin/lib/schema-restamp.sh"; exit 1; }

# ── stubs: the conductor helpers pq_gate and the hook read ──
mc_rest_var() { printf -v "$1" '{"sha":"%s"}' "$MAINSHA"; }
gh_rest() { echo "gh_rest $*" >> "$T/vendor"; return 97; }
gh_rest_pr_list_all() { echo "$*" >> "$LISTS"; [ -s "$T/list.rc" ] && { GH_REST_REASON=rate_limited; return "$(cat "$T/list.rc")"; }; cat "$OJ"; }
mc_log() { echo "$*" >> "$LOG"; }
mc_attempt_has() { grep -qxF "$1" "$ATT" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$ATT"; }
mc_alert() { printf 'key=%s st=%s crit=%s line=%s\n' "$1" "$2" "${4:-}" "$3" >> "$ALERTS"; }
mc_git_locked() { echo lock >> "$LOCKS"; shift; [ -e "$T/lock-busy" ] && return 99; "$@"; }
mc_funnel_repo() { MC_REMOTE="$O"; MC_FUNNEL_WT="$CL"; return 0; }
mc_git_auth_clear() { return 0; }
mc_pool_rebase_enabled() { [ -e "$T/pool" ]; }
mc_pool_rebase_enqueue() { echo "$*" >> "$T/pool-calls"; return 6; }
job_verdict_rebind() { echo "$*" >> "$T/rebind"; }
mc_enqueue() { echo "$*" >> "$T/enqueued"; }
lane_knob() {
  case "$2" in
    MC_SCHEMA_RESTAMP) printf 0 ;;     # the restamp hook is BH-6842's suite
    MC_MIGRATION_RECHECK) printf '%s' "${KNOB:-}" ;;
  esac; return 0
}
pq_resolve() { :; }                    # no dispatch: a miss proceeds
pq_status_gate() { :; }
hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }

lk() { mnr_lock_int "$1"; }
# migf <path> <NNNN> — a migration in project-6's shape: the number as a
# comment, a lock key and a RAISE text.
migf() {
  mkdir -p "$(dirname "$1")"
  printf -- '-- migration:%s\nSELECT pg_advisory_xact_lock(%s); -- mk%s\nDO $$ BEGIN RAISE NOTICE '"'"'%s: budget'"'"'; END $$;\n' \
    "$2" "$(lk "mk$2")" "$2" "$2" > "$1"
}
# jadd <n> <head-ref> <labels-json> <file...> — an open PR on origin that adds
# the files, listed with the labels.
jadd() {
  local n="$1" h="$2" l="$3" f; shift 3
  git -C "$W" checkout -q -B "$h" main
  for f in "$@"; do printf -- '-- pr %s\n' "$n" > "$W/prisma/sql/$f"; done
  git -C "$W" add -A; git -C "$W" commit -qm "pr $n"; git -C "$W" push -q -f "$O" "$h"
  git -C "$O" update-ref "refs/pull/$n/head" "$(git -C "$W" rev-parse HEAD)"
  git -C "$W" checkout -q main
  jq -c --argjson n "$n" --arg h "$h" --argjson l "$l" \
    '. + [{number:$n, head:{ref:$h}, base:{ref:"main"}, labels:($l | map({name:.}))}]' "$OJ" > "$OJ.n" && mv "$OJ.n" "$OJ"
}
# seed <pr-file> [<main-later-file>] — origin main holds BASE_FILES; the PR
#   branch `pr` adds <pr-file> (and a unit test naming it); main then gains
#   <main-later-file> when given. The conductor's clone is made last.
BASE_FILES="0001_init.sql 0334_starter_handoff_agent_add.sql 0335_agent_merge.sql"
seed() {
  local f
  scratch_rm "$O" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$CL" 2>/dev/null
  : > "$ATT"; : > "$LOG"; : > "$ALERTS"; : > "$GITCALLS"; : > "$LOCKS"; : > "$LISTS"; printf '[]' > "$OJ"
  rm -f "$T/pool" "$T/lock-busy" "$T/list.rc" "$T/pool-calls" "$T/rebind" "$T/enqueued" "$T/vendor"
  scratch_rm "$MC_STATE_DIR" 2>/dev/null; unset KNOB
  git init -q --bare -b main "$O"; mkdir -p "$W/prisma/sql" "$W/tests/unit"; git -C "$W" init -q -b main
  for f in $BASE_FILES; do printf -- '-- migration:%s base\n' "${f%%_*}" > "$W/prisma/sql/$f"; done
  git -C "$W" add -A; git -C "$W" commit -qm base
  git -C "$W" checkout -qb pr
  migf "$W/prisma/sql/$1" "${1%%_*}"
  printf "it('applies %s', () => expect(read('%s')).toContain('%s: budget'));\n" "${1%.sql}" "${1%.sql}" "${1%%_*}" > "$W/tests/unit/mig.test.ts"
  git -C "$W" add -A; git -C "$W" commit -qm pr; HEADSHA=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -q main
  if [ -n "${2:-}" ]; then
    printf -- '-- migration:%s main\n' "${2%%_*}" > "$W/prisma/sql/$2"
    git -C "$W" add -A; git -C "$W" commit -qm main-later
  fi
  git -C "$W" push -q "$O" main pr; MAINSHA=$(git -C "$W" rev-parse main)
  mkdir -p "$MC_REPOS"; git clone -q "$GHURL" "$CL"
  export ACTIONS=1 P=proj BR=pr KEY="$SLUG#$NUM" MNR_DIR=prisma/sql MNR_LOCK_PREFIX=mk MNR_OPEN_PRS=1
  unset MNR_MODE
}
gate() { pq_gate "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" main > "$T/word"; WORD=$(cat "$T/word"); }
# ready_arm — the READY arm's shape: enqueue only on proceed.
ready_arm() { gate; [ "$WORD" = proceed ] && mc_enqueue "$SLUG" "$NUM"; return 0; }
ohead() { git -C "$O" rev-parse refs/heads/pr; }
ofile() { git -C "$O" show "$(ohead):$1" 2>/dev/null; }
tapgit() { git() { echo "$*" >> "$GITCALLS"; command git "$@"; }; }
untapgit() { unset -f git; }

# ── Q1: the acceptance case ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql
ready_arm
[ "$WORD" = hold ] && [ "$PQ_VERDICT" = hold ] && ok || bad "Q1 a collision must hold, got '$WORD' ($(cat "$LOG"))"
[ ! -e "$T/enqueued" ] && ok || bad "Q1 a collision must never be enqueued"
NEW=$(ohead)
[ "$NEW" != "$HEADSHA" ] && [ "$(git -C "$O" rev-list --count "$HEADSHA..$NEW")" = 1 ] && [ "$(git -C "$O" rev-parse "$NEW^")" = "$HEADSHA" ] \
  && ok || bad "Q1 want exactly one new commit on the PR head"
git -C "$O" cat-file -e "$NEW:prisma/sql/0337_search_source_budget.sql" 2>/dev/null \
  && ! git -C "$O" cat-file -e "$NEW:prisma/sql/0336_search_source_budget.sql" 2>/dev/null && ok || bad "Q1 the file must be 0337_search_source_budget.sql on origin"
m=$(ofile prisma/sql/0337_search_source_budget.sql)
grep -qF -- '-- migration:0337' <<<"$m" && grep -qF "pg_advisory_xact_lock($(lk mk0337))" <<<"$m" && grep -qF "'0337: budget'" <<<"$m" \
  && ! grep -q 0336 <<<"$m" && ok || bad "Q1 every self-reference must move (got: $m)"
t=$(ofile tests/unit/mig.test.ts)
grep -qF "0337_search_source_budget" <<<"$t" && grep -qF "'0337: budget'" <<<"$t" && ! grep -q 0336 <<<"$t" && ok || bad "Q1 the test file references must move (got: $t)"
[ "$(git -C "$O" log -1 --format=%B "$NEW" | grep -c '^Union-resolved: prisma/sql/0336_search_source_budget.sql -> prisma/sql/0337_search_source_budget.sql (BH-7365, migration renumbered)$')" = 1 ] \
  && ok || bad "Q1 want one Union-resolved trailer (got: $(git -C "$O" log -1 --format=%B "$NEW"))"
grep -qx "$SLUG#$NUM MIGRATION_RECHECK pushed head=${HEADSHA:0:12} new=${NEW:0:12} main=${MAINSHA:0:12} moves=1 reason=0336 is taken on .* by 0336_schedule_zone_backfill_run.sql.*" "$LOG" \
  && ok || bad "Q1 want one MIGRATION_RECHECK pushed line, got: $(cat "$LOG")"
[ "$(grep -c 'MIGRATION_RECHECK pushed' "$LOG")" = 1 ] && ok || bad "Q1 want exactly one pushed line"
grep -q '^renumbered 1 migration(s)' <<<"$PQ_WHY" && grep -q "${NEW:0:12}" <<<"$PQ_WHY" && ok || bad "Q1 PQ_WHY: '$PQ_WHY'"
[ ! -s "$ALERTS" ] && ok || bad "Q1 a renumber that pushed must not alert: $(cat "$ALERTS")"
[ "$(git -C "$CL" worktree list --porcelain | grep -c '^worktree ')" = 1 ] && ok || bad "Q1 the temp worktree was left: $(git -C "$CL" worktree list)"
[ ! -e "$T/vendor" ] && ok || bad "Q1 no other GitHub call: $(cat "$T/vendor")"
# ── Q14: no approval moves to the renumbered head ──
[ -z "$(find "$T" -name '*reviewed-sha*' 2>/dev/null)" ] && ok || bad "Q14 the hook must write no reviewed-sha"
[ ! -e "$T/rebind" ] && ok || bad "Q14 the hook must not call job_verdict_rebind"
git -C "$CL" fetch -q origin
restamp_same "$CL" origin/main "$HEADSHA" "$NEW" >/dev/null 2>&1 && bad "Q14 restamp_same must refuse a migration renumber (lead-carry would carry the MERGE)" || ok
# the next tick on the new head proceeds and enqueues
HEADSHA="$NEW"; ready_arm
[ "$WORD" = proceed ] && [ -s "$T/enqueued" ] && ok || bad "Q1 the renumbered head must proceed next tick, got '$WORD' ($(cat "$LOG"))"

# ── Q2: main did not take the number ──
seed 0336_search_source_budget.sql
gate
[ "$WORD" = proceed ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q2 a free number must proceed with no push, got '$WORD' ($(cat "$LOG"))"
[ "$(grep -c . "$LISTS")" = 1 ] && ok || bad "Q2 want one list read, got $(grep -c . "$LISTS")"
grep -q 'MIGRATION_RECHECK' "$LOG" && bad "Q2 a free number must log nothing: $(cat "$LOG")" || ok

# ── Q3: a queued higher PR holds the number ──
BASE_FILES="0001_init.sql 0334_starter_handoff_agent_add.sql 0335_agent_merge.sql 0336_schedule_zone_backfill_run.sql"
seed 0337_search_source_budget.sql
jadd 9000 ticket/TK-9000 '["merge-queue"]' 0337_other.sql
gate
[ "$WORD" = hold ] && ok || bad "Q3 a queued PR's number must hold, got '$WORD' ($(cat "$LOG"))"
git -C "$O" cat-file -e "$(ohead):prisma/sql/0338_search_source_budget.sql" 2>/dev/null && ok || bad "Q3 want 0338 on origin (files: $(git -C "$O" ls-tree --name-only "$(ohead)" prisma/sql/ | tr '\n' ' '))"
grep -q "MIGRATION_RECHECK pushed .*reason=0337 is taken by queued PR #9000 (0337_other.sql)" "$LOG" && ok || bad "Q3 the line names the queued PR: $(cat "$LOG")"

# ── Q4: the same PR open but not queued ──
seed 0337_search_source_budget.sql
jadd 9000 ticket/TK-9000 '["ai-build"]' 0337_other.sql
gate
[ "$WORD" = proceed ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q4 an open, not queued, higher PR must not hold, got '$WORD' ($(cat "$LOG"))"
BASE_FILES="0001_init.sql 0334_starter_handoff_agent_add.sql 0335_agent_merge.sql"

# ── Q5: the lock is busy and the head is not in the clone ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql
scratch_rm "$CL"; git clone -q --no-local --single-branch -b main "$GHURL" "$CL"
git -C "$CL" cat-file -e "$HEADSHA^{commit}" 2>/dev/null && bad "Q5 setup: the head must not be in the clone" || ok
: > "$T/lock-busy"
gate; w1="$WORD"; gate; w2="$WORD"
[ "$w1" = hold ] && [ "$w2" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q5 a busy lock must hold with no push ($w1/$w2)"
grep -q '^mignumfail ' "$ATT" && bad "Q5 a busy lock is not terminal: $(cat "$ATT")" || ok
[ "$(grep -c "MIGRATION_RECHECK held head=${HEADSHA:0:12} .*reason=the git lock for proj was busy" "$LOG")" = 1 ] && ok || bad "Q5 want one held line over two ticks: $(cat "$LOG")"
rm -f "$T/lock-busy"; gate
[ "$WORD" = hold ] && [ "$(ohead)" != "$HEADSHA" ] && ok || bad "Q5 with the lock free the next tick must fetch and renumber ($WORD; $(cat "$LOG"))"

# ── Q6: a decline is terminal: one mark, one alert, then no git ──
BASE_FILES="0001_init.sql 9999_last.sql"
seed 9999_b.sql
gate; w1="$WORD"
tapgit; gate; w2="$WORD"; untapgit
[ "$w1" = hold ] && [ "$w2" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q6 a decline must hold both ticks with no push ($w1/$w2; $(cat "$LOG"))"
[ "$(grep -c "^mignumfail $SLUG#$NUM $HEADSHA$" "$ATT")" = 1 ] && ok || bad "Q6 want one mignumfail mark: $(cat "$ATT")"
[ "$(grep -c . "$ALERTS")" = 1 ] && grep -q "^key=$SLUG#$NUM st=MIGRATION_RECHECK crit= line=${HEADSHA:0:12} adds migration .*9999_b.sql" "$ALERTS" \
  && ok || bad "Q6 want one warn alert over two ticks: $(cat "$ALERTS")"
[ "$(grep -c 'MIGRATION_RECHECK refused' "$LOG")" = 1 ] && ok || bad "Q6 want one refused line: $(cat "$LOG")"
[ ! -s "$GITCALLS" ] && ok || bad "Q6 the second tick must run no git: $(cat "$GITCALLS")"
BASE_FILES="0001_init.sql 0334_starter_handoff_agent_add.sql 0335_agent_merge.sql"

# ── Q7: no migration dir: nothing runs ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql; unset MNR_DIR
tapgit; gate; untapgit
[ "$WORD" = proceed ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q7 no dir must proceed, got '$WORD'"
[ ! -s "$GITCALLS" ] && [ ! -s "$LOCKS" ] && [ ! -s "$LISTS" ] && ok || bad "Q7 want no git, lock or list (git: $(cat "$GITCALLS"); locks: $(grep -c . "$LOCKS"); lists: $(grep -c . "$LISTS"))"
grep -q 'PREQUEUE_CALL call=mignum' "$LOG" && bad "Q7 no PREQUEUE_CALL call=mignum line: $(cat "$LOG")" || ok

# ── Q8: the knob off ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql; KNOB=0
tapgit; gate; untapgit
[ "$WORD" = proceed ] && [ ! -s "$GITCALLS" ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q8 MC_MIGRATION_RECHECK=0 must proceed with no git, got '$WORD' (git: $(cat "$GITCALLS"))"

# ── Q9: observe mode ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql; ACTIONS=0
tapgit; gate; untapgit
[ "$WORD" = proceed ] && [ ! -s "$GITCALLS" ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q9 ACTIONS=0 must proceed with no git, got '$WORD'"

# ── Q10: a HOLD on the ticket at push time ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql
hold_push_verdict() { printf 'held\thold:comment HOLD (lead fix round)\n'; return 1; }
gate
hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }
[ "$WORD" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q10 a HOLD must hold with no push, got '$WORD'"
grep -q 'MIGRATION_RECHECK pushed' "$LOG" && bad "Q10 never a pushed line: $(cat "$LOG")" || ok
grep -q "MIGRATION_RECHECK held head=${HEADSHA:0:12} new=- .*reason=.*HOLD" "$LOG" && ok || bad "Q10 want a held line naming the HOLD: $(cat "$LOG")"
grep -q '^mignumfail ' "$ATT" && bad "Q10 a HOLD is not terminal" || ok
[ ! -s "$ALERTS" ] && ok || bad "Q10 a HOLD must not alert: $(cat "$ALERTS")"

# ── Q11: the list read fails: main only, still renumbered ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql; echo 75 > "$T/list.rc"
gate
[ "$WORD" = hold ] && git -C "$O" cat-file -e "$(ohead):prisma/sql/0337_search_source_budget.sql" 2>/dev/null && ok || bad "Q11 a main collision must still renumber, got '$WORD' ($(cat "$LOG"))"
[ "$(grep -c "MIGRATION_RECHECK note head=${HEADSHA:0:12} .*open PRs not read (rate limited)" "$LOG")" -ge 1 ] && ok || bad "Q11 want a note line in the conductor log: $(cat "$LOG")"

# ── Q12: pool mode enqueues one pool rebase per head ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql; : > "$T/pool"
gate; w1="$WORD"; gate; w2="$WORD"
[ "$w1" = hold ] && [ "$w2" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q12 pool mode must hold with no hub push ($w1/$w2)"
[ "$(grep -c . "$T/pool-calls" 2>/dev/null)" = 1 ] && grep -qx "$SLUG proj pr $HEADSHA https://github.com/$SLUG/pull/$NUM" "$T/pool-calls" \
  && ok || bad "Q12 want one pool enqueue: $(cat "$T/pool-calls" 2>/dev/null)"
[ ! -s "$ALERTS" ] && ok || bad "Q12 a pool enqueue must not alert"

# ── Q13: a push that answers 0 but never lands ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql
hold_push() { return 0; }
gate
# shellcheck source=bin/lib/hold-push.sh
. "$DIR/bin/lib/hold-push.sh"
hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }
[ "$WORD" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "Q13 an unproven push must hold, got '$WORD'"
grep -q 'MIGRATION_RECHECK pushed' "$LOG" && bad "Q13 never a pushed line: $(cat "$LOG")" || ok
grep -q "MIGRATION_RECHECK refused head=${HEADSHA:0:12} .*reason=the push answered 0 but origin pr is $HEADSHA" "$LOG" && ok || bad "Q13 want a refused line naming ls-remote: $(cat "$LOG")"
[ "$(grep -c "^mignumfail $SLUG#$NUM $HEADSHA$" "$ATT")" = 1 ] && [ "$(grep -c . "$ALERTS")" = 1 ] && ok || bad "Q13 want one mark and one alert"

# ── Q15: the requeue gate's call shape ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql
PQ_MIN_AT=1760900000 pq_gate "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" main >/dev/null
[ "$PQ_VERDICT" = hold ] && [ "$(ohead)" != "$HEADSHA" ] && ok || bad "Q15 the requeue gate must hold and renumber, got '$PQ_VERDICT'"

# ── X1: the project-6 #2055 replay ──
seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql
grep -qx prisma/sql/0336_search_source_budget.sql <<<"$(git -C "$O" ls-tree --name-only "$HEADSHA" prisma/sql/)" && ok || bad "X1 setup: the head adds 0336_search_source_budget.sql"
gate
X=$(git -C "$O" ls-tree --name-only "$(ohead)" prisma/sql/ | grep '_search_source_budget.sql$')
[ "$WORD" = hold ] && [ -n "$X" ] && [ "$X" != prisma/sql/0336_search_source_budget.sql ] && ok || bad "X1 #2055 must be caught and moved off 0336, got '$WORD' ($X)"

# ── M1: pq_gate without the pq_mignum call proceeds on Q1 ──
sed 's/^\( *\)declare -F pq_mignum >\/dev\/null && pq_mignum_wanted && mn=/\1false \&\& mn=/' "$DIR/bin/lib/mc-prequeue.sh" > "$T/mut-pq.sh"
if cmp -s "$T/mut-pq.sh" "$DIR/bin/lib/mc-prequeue.sh"; then
  bad "M1 the mutation anchor 'declare -F pq_mignum >/dev/null && pq_mignum_wanted && mn=' is missing from bin/lib/mc-prequeue.sh"
else
  (
    # shellcheck source=/dev/null
    . "$T/mut-pq.sh"
    pq_resolve() { :; }; pq_status_gate() { :; }
    seed 0336_search_source_budget.sql 0336_schedule_zone_backfill_run.sql; gate; echo "word=$WORD"
  ) > "$T/m1.out" 2>&1
  grep -qx 'word=proceed' "$T/m1.out" && ok || bad "M1 without the call Q1 must proceed (Q1 would go red), got: $(cat "$T/m1.out")"
fi

echo "prequeue-migration-numbers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
