#!/bin/bash
# tests/prequeue-restamp.bh-6842-test.sh — BH-6842: the merge conductor's
# pre-queue gate (pq_gate, bin/lib/mc-prequeue.sh) restamps a READY head's stale
# schema fragments before it is queued, through the hook
# bin/lib/mc-prequeue.d/restamp.sh and bin/lib/schema-restamp.sh.
#
#   P1  a stale head: hold; the origin branch gains exactly one commit,
#       "restamp schema fragments (no SQL change)"; one SCHEMA_RESTAMP pushed line
#   P2  a fresh head: proceed, no push
#   P3  pool mode (REBASE_ON_POOL): hold, SCHEMA_RESTAMP held, no push
#   P4  a name collision over two ticks: hold both ticks, one restampfail mark,
#       one warn alert
#   P5  MC_SCHEMA_RESTAMP=0: proceed, and no git command runs
#   P6  the branch moved on origin before the push: held, never pushed
#   P7  the git lock is busy: hold, no terminal mark, asked again next tick
#   P8  the push answers 0 but origin does not show the new sha: refused, never
#       pushed (the ls-remote proof)
#   P9  no local clone of the repo, and a clone whose main has no stamp
#       fragment: proceed, with no credential, git lock or fetch
#   P10 a HOLD on the ticket: hold, no push, no terminal mark, no alert; after
#       RESUME the next tick restamps (hold_push reads the ticket at push time)
#   M1  mutation: pq_gate without the pq_restamp call answers proceed on P1
# Real git: a local origin, the conductor's clone of it, the real bin/lib/hold-push.sh
# push (its hold read stubbed). The mc_* conductor helpers are stubs.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-restamp.bh-6842-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc-prequeue.d/restamp.sh" ] || { echo "FAIL: bin/lib/mc-prequeue.d/restamp.sh does not exist"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export SR_NOW_EPOCH
SR_NOW_EPOCH=$(date -u -d '2026-10-15 09:00' +%s)

# shellcheck source=bin/lib/mc-prequeue.sh
. "$DIR/bin/lib/mc-prequeue.sh" || { echo "FAIL: cannot source bin/lib/mc-prequeue.sh"; exit 1; }
# shellcheck source=bin/lib/hold-push.sh
. "$DIR/bin/lib/hold-push.sh" || { echo "FAIL: cannot source bin/lib/hold-push.sh"; exit 1; }

SLUG=o/r; NUM=31; SD=worker/jobs/schema.d
O="$T/origin.git"; W="$T/work"; CL="$T/repos/proj"
export MC_STATE_DIR="$T/state" MC_REPOS="$T/repos"
ATT="$T/att"; LOG="$T/log"; ALERTS="$T/alerts"; GITCALLS="$T/gitcalls"

# ── stubs: the conductor helpers pq_gate and the hook read ──
mc_rest_var() { printf -v "$1" '{"sha":"%s"}' "$MAINSHA"; }
gh_rest() { return 0; }
mc_log() { echo "$*" >> "$LOG"; }
mc_attempt_has() { grep -qxF "$1" "$ATT" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$ATT"; }
mc_alert() { printf 'key=%s st=%s crit=%s line=%s\n' "$1" "$2" "${4:-}" "$3" >> "$ALERTS"; }
mc_git_locked() { shift; [ -e "$T/lock-busy" ] && return 99; "$@"; }
mc_funnel_repo() { MC_REMOTE="$O"; MC_FUNNEL_WT="$CL"; return 0; }
mc_git_auth_clear() { return 0; }
mc_pool_rebase_enabled() { [ -e "$T/pool" ]; }
lane_knob() { [ "$2" = MC_SCHEMA_RESTAMP ] && printf '%s' "${KNOB:-}"; return 0; }
pq_resolve() { :; }                    # no dispatch: a miss proceeds
pq_status_gate() { :; }
# hold-push's hold read: clear, and in P6 the branch moves on origin first
hold_push_verdict() {
  if [ -e "$T/move-branch" ]; then
    git -C "$W" checkout -q pr; echo moved >> "$W/moved.txt"; git -C "$W" add -A; git -C "$W" commit -qm moved
    git -C "$W" push -q "$O" pr; rm -f "$T/move-branch"
  fi
  printf 'clear\tfixture\n'; return 0
}

# seed <pr-fragment> — origin: main forks with 202610140000, the PR branch
#   `pr` adds <pr-fragment> and a doc naming it, main then gains 202610150259.
seed() {
  scratch_rm "$O" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$CL" 2>/dev/null
  : > "$ATT"; : > "$LOG"; : > "$ALERTS"; : > "$GITCALLS"; rm -f "$T/pool" "$T/lock-busy" "$T/move-branch"
  scratch_rm "$MC_STATE_DIR" 2>/dev/null; unset KNOB
  git init -q --bare -b main "$O"; mkdir -p "$W/$SD" "$W/docs"; git -C "$W" init -q -b main
  printf 'CREATE TABLE z (id INTEGER);\n' > "$W/$SD/202610140000-bh-0-z.sql"
  git -C "$W" add -A; git -C "$W" commit -qm base
  git -C "$W" checkout -qb pr
  local f; for f in "$@"; do printf 'CREATE TABLE t (id INTEGER);\n' > "$W/$SD/$f"; done
  printf 'Uses `%s`.\n' "$1" > "$W/docs/n.md"
  git -C "$W" add -A; git -C "$W" commit -qm pr; HEADSHA=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -q main
  printf 'CREATE TABLE a (id INTEGER);\n' > "$W/$SD/202610150259-bh-1-a.sql"
  git -C "$W" add -A; git -C "$W" commit -qm main-a
  git -C "$W" push -q "$O" main pr; MAINSHA=$(git -C "$W" rev-parse main)
  mkdir -p "$MC_REPOS"; git clone -q "$O" "$CL"
  export ACTIONS=1 P=proj BR=pr KEY="$SLUG#$NUM"
}
gate() { pq_gate "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" main > "$T/word"; WORD=$(cat "$T/word"); }
ohead() { git -C "$O" rev-parse refs/heads/pr; }

# ── P1: a stale head is restamped and held ──
seed 202610142106-bh-2-b.sql
gate
[ "$WORD" = hold ] && [ "$PQ_VERDICT" = hold ] && ok || bad "P1 a stale head must hold, got '$WORD' ($(cat "$LOG"))"
NEW=$(ohead)
[ "$NEW" != "$HEADSHA" ] && [ "$(git -C "$O" rev-list --count "$HEADSHA..$NEW")" = 1 ] && ok || bad "P1 want exactly one new commit on origin pr"
[ "$(git -C "$O" log -1 --format=%s "$NEW")" = 'restamp schema fragments (no SQL change)' ] && ok || bad "P1 subject: $(git -C "$O" log -1 --format=%s "$NEW")"
[ "$(git -C "$O" rev-parse "$NEW^")" = "$HEADSHA" ] && ok || bad "P1 the restamp must sit on the PR head"
git -C "$O" cat-file -e "$NEW:$SD/202610150900-bh-2-b.sql" 2>/dev/null && ok || bad "P1 the fragment was not renamed on origin"
doc=$(git -C "$O" show "$NEW:docs/n.md" 2>/dev/null)
grep -qF 202610150900-bh-2-b.sql <<<"$doc" && ok || bad "P1 the doc reference was not rewritten"
M12=$(git -C "$O" rev-parse main | cut -c1-12)
grep -qx "$SLUG#$NUM SCHEMA_RESTAMP pushed head=${HEADSHA:0:12} new=${NEW:0:12} main=$M12 renames=1 reason=.*" "$LOG" \
  && ok || bad "P1 want one SCHEMA_RESTAMP pushed line with the fields, got: $(cat "$LOG")"
grep -q "restamped 1 schema fragment" <<<"$PQ_WHY" && grep -q "${NEW:0:12}" <<<"$PQ_WHY" && ok || bad "P1 PQ_WHY: '$PQ_WHY'"
[ ! -s "$ALERTS" ] && ok || bad "P1 a restamp that pushed must not alert: $(cat "$ALERTS")"
[ "$(git -C "$CL" worktree list --porcelain | grep -c '^worktree ')" = 1 ] && ok || bad "P1 the temp worktree was left: $(git -C "$CL" worktree list)"
# the next tick on the new head proceeds
HEADSHA="$NEW"; gate
[ "$WORD" = proceed ] && ok || bad "P1 the restamped head must proceed next tick, got '$WORD'"

# ── P2: a fresh head proceeds, nothing pushed ──
seed 202610151000-bh-2-b.sql
gate
[ "$WORD" = proceed ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "P2 a fresh head must proceed with no push, got '$WORD'"
grep -q SCHEMA_RESTAMP "$LOG" && bad "P2 a fresh head must log nothing: $(cat "$LOG")" || ok

# ── P3: pool mode holds and pushes nothing ──
seed 202610142106-bh-2-b.sql; : > "$T/pool"
gate
[ "$WORD" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "P3 pool mode must hold with no push, got '$WORD'"
grep -q "^$SLUG#$NUM SCHEMA_RESTAMP held head=${HEADSHA:0:12} new=- .*reason=.*REBASE_ON_POOL" "$LOG" && ok || bad "P3 want a held line naming pool mode: $(cat "$LOG")"

# ── P4: a collision holds twice, one mark, one alert ──
seed 202610142106-bh-2-b.sql 202610150900-bh-2-b.sql
gate; w1="$WORD"; gate; w2="$WORD"
[ "$w1" = hold ] && [ "$w2" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "P4 a collision must hold both ticks with no push ($w1/$w2)"
[ "$(grep -c "^restampfail $SLUG#$NUM $HEADSHA 202610150259$" "$ATT")" = 1 ] && ok || bad "P4 want one restampfail mark: $(cat "$ATT")"
[ "$(grep -c . "$ALERTS")" = 1 ] && grep -q "SCHEMA_RESTAMP" "$ALERTS" && ok || bad "P4 want one alert over two ticks: $(cat "$ALERTS")"
[ "$(grep -c 'SCHEMA_RESTAMP refused' "$LOG")" = 1 ] && ok || bad "P4 want one refused line over two ticks: $(cat "$LOG")"
grep -q "^key=$SLUG#$NUM st=SCHEMA_RESTAMP crit= line=" "$ALERTS" && ok || bad "P4 the alert must be warn (no crit flag): $(cat "$ALERTS")"

# ── P5: the knob off runs no git at all ──
seed 202610142106-bh-2-b.sql; KNOB=0
git() { echo "$*" >> "$GITCALLS"; command git "$@"; }
gate
unset -f git
[ "$WORD" = proceed ] && ok || bad "P5 MC_SCHEMA_RESTAMP=0 must proceed, got '$WORD'"
[ ! -s "$GITCALLS" ] && ok || bad "P5 MC_SCHEMA_RESTAMP=0 must run no git command: $(cat "$GITCALLS")"
[ "$(ohead)" = "$HEADSHA" ] && ok || bad "P5 nothing may be pushed with the knob off"

# ── P6: the branch moved before the push: held, never pushed ──
seed 202610142106-bh-2-b.sql; : > "$T/move-branch"
gate
MOVED=$(ohead)
[ "$WORD" = hold ] && ok || bad "P6 a refused push must hold, got '$WORD'"
[ "$(git -C "$O" log -1 --format=%s "$MOVED")" = moved ] && ok || bad "P6 origin pr must be the moved commit, not the restamp"
grep -q 'SCHEMA_RESTAMP pushed' "$LOG" && bad "P6 a refused push must never log pushed: $(cat "$LOG")" || ok
grep -q "SCHEMA_RESTAMP refused head=${HEADSHA:0:12} .*reason=.*push" "$LOG" && ok || bad "P6 want a refused line naming the push: $(cat "$LOG")"

# ── P7: a busy git lock holds, with no terminal mark ──
seed 202610142106-bh-2-b.sql; : > "$T/lock-busy"
gate
[ "$WORD" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "P7 a busy lock must hold with no push, got '$WORD'"
grep -q '^restampfail ' "$ATT" && bad "P7 a busy lock must not write the terminal mark" || ok
rm -f "$T/lock-busy"; gate
[ "$WORD" = hold ] && [ "$(ohead)" != "$HEADSHA" ] && ok || bad "P7 the next tick with the lock free must restamp"

# ── P8: a push that answers 0 but never lands is not a push ──
seed 202610142106-bh-2-b.sql
hold_push() { return 0; }
gate
# shellcheck source=bin/lib/hold-push.sh
. "$DIR/bin/lib/hold-push.sh"
hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }
[ "$WORD" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "P8 a push that did not land must hold, got '$WORD'"
grep -q 'SCHEMA_RESTAMP pushed' "$LOG" && bad "P8 an unproven push must never log pushed: $(cat "$LOG")" || ok
grep -q "SCHEMA_RESTAMP refused head=${HEADSHA:0:12} .*reason=the push answered 0 but origin pr is ${HEADSHA}" "$LOG" \
  && ok || bad "P8 want a refused line naming the ls-remote answer: $(cat "$LOG")"

# ── P9: no clone, or no stamp fragment at the clone's main: no lock, proceed ──
seed 202610142106-bh-2-b.sql; scratch_rm "$CL"
mc_funnel_repo() { echo funnel >> "$T/funnel"; return 1; }
gate
[ "$WORD" = proceed ] && [ ! -e "$T/funnel" ] && [ ! -s "$LOG" ] && ok || bad "P9 no clone must proceed with no funnel call and no line, got '$WORD' ($(cat "$LOG"))"
seed 202610142106-bh-2-b.sql
nostamp=$(git -C "$CL" commit-tree "$(git -C "$CL" mktree </dev/null)" -m empty)
git -C "$CL" update-ref refs/remotes/origin/main "$nostamp"
gate
[ "$WORD" = proceed ] && [ ! -e "$T/funnel" ] && ok || bad "P9 a clone with no stamp fragment at origin/main must proceed with no funnel call, got '$WORD'"
mc_funnel_repo() { MC_REMOTE="$O"; MC_FUNNEL_WT="$CL"; return 0; }

# ── P10: a HOLD on the ticket stops the restamp push; not terminal ──
seed 202610142106-bh-2-b.sql
hold_push_verdict() { printf 'held\thold:comment HOLD (lead fix round)\n'; return 1; }
gate
[ "$WORD" = hold ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "P10 a HOLD on the ticket must hold with no push, got '$WORD' (origin pr $(ohead))"
grep -q 'SCHEMA_RESTAMP pushed' "$LOG" && bad "P10 a held ticket must never log pushed: $(cat "$LOG")" || ok
grep -q "SCHEMA_RESTAMP held head=${HEADSHA:0:12} new=- .*reason=.*HOLD" "$LOG" && ok || bad "P10 want a held line naming the HOLD: $(cat "$LOG")"
grep -q '^restampfail ' "$ATT" && bad "P10 a HOLD is not terminal: no restampfail mark ($(cat "$ATT"))" || ok
[ ! -s "$ALERTS" ] && ok || bad "P10 a HOLD must not alert: $(cat "$ALERTS")"
hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }
gate
[ "$WORD" = hold ] && [ "$(ohead)" != "$HEADSHA" ] && ok || bad "P10 after RESUME the next tick must restamp"

# ── M1: pq_gate without the restamp call proceeds on a stale head ──
sed 's/^\( *\)declare -F pq_restamp >\/dev\/null && rs=\$(pq_restamp /\1false \&\& rs=$(pq_restamp /' "$DIR/bin/lib/mc-prequeue.sh" > "$T/mut-pq.sh"
if cmp -s "$T/mut-pq.sh" "$DIR/bin/lib/mc-prequeue.sh"; then
  bad "M1 the mutation anchor 'declare -F pq_restamp >/dev/null && rs=\$(pq_restamp ' is missing from bin/lib/mc-prequeue.sh"
else
  (
    # shellcheck source=/dev/null
    . "$T/mut-pq.sh"
    pq_resolve() { :; }; pq_status_gate() { :; }
    seed 202610142106-bh-2-b.sql; gate; echo "word=$WORD"
  ) > "$T/m1.out" 2>&1
  grep -qx 'word=proceed' "$T/m1.out" && ok || bad "M1 without the call P1 must proceed (P1 would go red), got: $(cat "$T/m1.out")"
fi

echo "prequeue-restamp: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
