#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/restamp-land.bh-9154-test.sh — BH-9154 (Fix 2 of #9066): the schema
# restamp never moves a reviewed head on its own. The pre-queue hook
# (bin/lib/mc-prequeue.d/restamp.sh, pq_restamp) defers a reviewed head to the
# land rebase, and the land rebase (bin/lib/mc/rebase.sh, mc_rebase) writes the
# restamp in the push it already makes.
#
#   R1  no verdict on the head + a stale stamp: pushed (today's behavior)
#   R2  an APPROVE bound to this head + a stale stamp: `deferred-land 1`, no
#       push, one deferred-land line; pq_gate answers rebase on it
#   R2b an APPROVE bound to an older sha: pushed (the verdict is not this head's)
#   R2c pool mode + an APPROVE bound to this head: held, as before
#   R3  a verdict + a fresh stamp: none
#   R4  schema-restamp.sh missing: none, with a verdict too
#   R5  mc_rebase over a stale stamp: one push, and the pushed head carries the
#       restamp commit on top of the main merge; rc 0, the approval rebound
#   R5b MC_SCHEMA_RESTAMP=0: the merge alone is pushed, no restamp commit
#   R6  restamp_same carries the verdict from the reviewed head to that head
#   R7  sr_apply refuses (a name collision): rc 2, nothing pushed, a restampfail mark
#   R8  one log line per head: R2 asked twice and R7 asked twice each log once
# Real git: a bare origin, the real hold-push push (its hold read answered by
# tests/lib/hold-fixture.sh), the real conductor closure for mc_rebase.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/restamp-land.bh-9154-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
REALGIT=$(command -v git)

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.invalid
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.detachedHead false
export SR_NOW_EPOCH
SR_NOW_EPOCH=$(date -u -d '2026-10-15 09:00' +%s)
SD=worker/jobs/schema.d
unset MC_SCHEMA_RESTAMP VERDICT REVIEWED MNR_DIR

# ============================================================================
# A. pq_restamp, the pre-queue hook (R1-R4, R8a)
# ============================================================================
part_a() {
  # shellcheck source=bin/lib/mc-prequeue.sh
  . "$DIR/bin/lib/mc-prequeue.sh" || { bad "A0 cannot source bin/lib/mc-prequeue.sh"; return; }
  # shellcheck source=bin/lib/hold-push.sh
  . "$DIR/bin/lib/hold-push.sh" || { bad "A0 cannot source bin/lib/hold-push.sh"; return; }
  SLUG=o/r; NUM=31
  O="$T/a/origin.git"; W="$T/a/work"; CL="$T/a/repos/proj"
  export MC_STATE_DIR="$T/a/state" MC_REPOS="$T/a/repos"
  ATT="$T/a/att"; LOG="$T/a/log"
  mc_rest_var() { printf -v "$1" '{"sha":"%s"}' "$MAINSHA"; }
  gh_rest() { return 0; }
  mc_log() { echo "$*" >> "$LOG"; }
  mc_attempt_has() { grep -qxF "$1" "$ATT" 2>/dev/null; }
  mc_attempt_put() { echo "$1" >> "$ATT"; }
  mc_alert() { :; }
  mc_git_locked() { shift; "$@"; }
  mc_funnel_repo() { MC_REMOTE="$O"; MC_FUNNEL_WT="$CL"; return 0; }
  mc_git_auth_clear() { return 0; }
  mc_pool_rebase_enabled() { return 1; }
  lane_knob() { return 0; }
  pq_resolve() { :; }
  pq_status_gate() { :; }
  hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }
  # seed <pr-fragment> — main forks with 202610140000, the PR adds <pr-fragment>,
  #   main then gains 202610150259.
  seed() {
    scratch_rm "$T/a" 2>/dev/null; mkdir -p "$T/a"
    : > "$ATT"; : > "$LOG"; unset VERDICT REVIEWED
    git init -q --bare -b main "$O"; mkdir -p "$W/$SD"; git -C "$W" init -q -b main
    printf 'CREATE TABLE z (id INTEGER);\n' > "$W/$SD/202610140000-bh-0-z.sql"
    git -C "$W" add -A; git -C "$W" commit -qm base
    git -C "$W" checkout -qb pr
    printf 'CREATE TABLE t (id INTEGER);\n' > "$W/$SD/$1"
    git -C "$W" add -A; git -C "$W" commit -qm pr; HEADSHA=$(git -C "$W" rev-parse HEAD)
    git -C "$W" checkout -q main
    printf 'CREATE TABLE a (id INTEGER);\n' > "$W/$SD/202610150259-bh-1-a.sql"
    git -C "$W" add -A; git -C "$W" commit -qm main-a
    git -C "$W" push -q "$O" main pr; MAINSHA=$(git -C "$W" rev-parse main)
    mkdir -p "$MC_REPOS"; git clone -q "$O" "$CL"
    export ACTIONS=1 P=proj BR=pr KEY="$SLUG#$NUM"
  }
  hook() { pq_restamp "$SLUG" "$NUM" "$HEADSHA" "$MAINSHA" 2>/dev/null | tail -n 1; }
  ohead() { git -C "$O" rev-parse refs/heads/pr; }

  # R1 — no verdict: today's push
  seed 202610142106-bh-2-b.sql
  out=$(hook)
  case "$out" in "pushed "*" 1") ok ;; *) bad "R1 no verdict + stale must push, got '$out' ($(cat "$LOG"))" ;; esac
  [ "$(ohead)" != "$HEADSHA" ] && ok || bad "R1 origin pr must have moved"

  # R2 — an approval bound to this head: deferred to the land rebase, no push
  seed 202610142106-bh-2-b.sql; VERDICT=APPROVE; REVIEWED="$HEADSHA"
  out=$(hook)
  [ "$out" = "deferred-land 1" ] && ok || bad "R2 a reviewed stale head must answer 'deferred-land 1', got '$out' ($(cat "$LOG"))"
  [ "$(ohead)" = "$HEADSHA" ] && ok || bad "R2 a reviewed head must never be pushed by the restamp hook"
  grep -qx "$SLUG#$NUM SCHEMA_RESTAMP deferred-land head=${HEADSHA:0:12} new=- main=${MAINSHA:0:12} renames=1 reason=.*" "$LOG" \
    && ok || bad "R2 want one SCHEMA_RESTAMP deferred-land line, got: $(cat "$LOG")"
  [ "$(git -C "$CL" worktree list --porcelain | grep -c '^worktree ')" = 1 ] && ok || bad "R2 a temp worktree was left"
  # R8a — asked again: still deferred, still one line
  out=$(hook)
  [ "$out" = "deferred-land 1" ] && [ "$(grep -c 'SCHEMA_RESTAMP deferred-land' "$LOG")" = 1 ] \
    && ok || bad "R8 a second ask must defer with no second line (got '$out', $(grep -c 'SCHEMA_RESTAMP deferred-land' "$LOG") lines)"
  # the production entry: pq_gate hands the head to the conductor rebase
  # (rebase -> NEEDS_REBASE), never to the queue with a stale stamp, no push
  pq_gate "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" main > "$T/a.word"
  [ "$(cat "$T/a.word")" = rebase ] && [ "$(ohead)" = "$HEADSHA" ] && ok \
    || bad "R2 pq_gate on a deferred head must answer rebase with no push, got '$(cat "$T/a.word")' ($PQ_WHY)"

  # R2b — the approval is on another sha: not this head's verdict, pushed
  seed 202610142106-bh-2-b.sql; VERDICT=APPROVE; REVIEWED=0123456789abcdef0123456789abcdef01234567
  out=$(hook)
  case "$out" in "pushed "*) ok ;; *) bad "R2b an approval of another sha must not defer, got '$out'" ;; esac

  # R2c — pool mode (REBASE_ON_POOL): the pool rebase does not restamp, so a
  #   reviewed stale head is held as before, never handed to a rebase
  seed 202610142106-bh-2-b.sql; VERDICT=APPROVE; REVIEWED="$HEADSHA"
  out=$( mc_pool_rebase_enabled() { return 0; }; hook )
  case "$out" in "held "*REBASE_ON_POOL*) ok ;; *) bad "R2c pool mode must hold a reviewed stale head, got '$out'" ;; esac
  [ "$(ohead)" = "$HEADSHA" ] && ok || bad "R2c pool mode must not push"

  # R3 — a verdict and a fresh stamp: nothing to do
  seed 202610151000-bh-2-b.sql; VERDICT=APPROVE; REVIEWED="$HEADSHA"
  out=$(hook)
  [ "$out" = none ] && [ "$(ohead)" = "$HEADSHA" ] && ! grep -q SCHEMA_RESTAMP "$LOG" && ok \
    || bad "R3 a fresh head must answer none with no line, got '$out' ($(cat "$LOG"))"

  # R4 — the lib is missing: none, verdict or not
  seed 202610142106-bh-2-b.sql; VERDICT=APPROVE; REVIEWED="$HEADSHA"
  mkdir -p "$T/a/nolib/mc-prequeue.d"   # a hook dir with no schema-restamp.sh beside it
  out=$( unset -f sr_plan sr_apply sr_top restamp_same; _pq_rs_dir="$T/a/nolib/mc-prequeue.d"; hook )
  [ "$out" = none ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "R4 a missing lib must answer none, got '$out'"
  echo "$PASS $FAIL" > "$T/a.counts"
}
( part_a )
read -r ap af < "$T/a.counts" 2>/dev/null || { ap=0; af=1; echo "FAIL: part A gave no counts"; }
PASS=$((PASS+ap)); FAIL=$((FAIL+af))

# ============================================================================
# B. mc_rebase, the land rebase (R5-R8)
# ============================================================================
SLUG=example-org/demo-os; BR=ticket/bh-9002
URL2="https://github.com/$SLUG/pull/2"
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
[ -r "$T/h/bin/lib/schema-restamp.sh" ] && ok || bad "R0 the conductor closure must carry bin/lib/schema-restamp.sh"
: > "$T/h/env/global.env"
printf 'demo-os %s - - 2 box-d\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
cat > "$T/h/bin/jobs-client.sh" <<EOF
job_verdict_rebind() { printf '%s\n' "\$*" >> "$T/rebinds.txt"; return 0; }
job_ledger_put() { return 0; }
EOF
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case " \$* " in *" push "*) printf 'PUSH %s\n' "\$*" >> "$T/events.txt" ;; esac
exec "$REALGIT" "\$@"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pr list"*) echo "[]" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git" "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
LOG="$T/h/logs/merge-conductor.log"

# ofix <branch-fragment...> — a fresh origin. main: 202610140000-bh-0-z; the
#   PR branch adds each fragment and a doc naming the first; main then adds
#   202610150259-bh-1-a.
ofix() {
  local S="$T/seed" f
  rm -rf "$T/origin.git" "$S" "$T/h/tmp/conductor"
  : > "$T/events.txt"; : > "$T/rebinds.txt"; : > "$LOG"; rm -rf "$T/h/state"; mkdir -p "$T/h/state"
  "$REALGIT" init -q --bare "$T/origin.git"
  "$REALGIT" clone -q "$T/origin.git" "$S" 2>/dev/null
  mkdir -p "$S/$SD" "$S/docs"
  printf 'CREATE TABLE z (id INTEGER);\n' > "$S/$SD/202610140000-bh-0-z.sql"
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm base
  "$REALGIT" -C "$S" checkout -qb "$BR"
  for f in "$@"; do printf 'CREATE TABLE t_%s (id INTEGER);\n' "${#f}" > "$S/$SD/$f"; done
  printf 'Uses `%s`.\n' "$1" > "$S/docs/n.md"
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm branch
  CHEAD=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" checkout -q main
  printf 'CREATE TABLE a (id INTEGER);\n' > "$S/$SD/202610150259-bh-1-a.sql"
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm 'main moves'
  "$REALGIT" -C "$S" push -q origin main "$BR" 2>/dev/null
}
origin_rev() { "$REALGIT" -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
pushes() { grep -c '^PUSH' "$T/events.txt"; }
arun() { # arun — mc_rebase in a fresh subshell; rc to $T/arc
  ( . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init; MC_REPOS="$T/repos"
    mc_rebase "$SLUG" demo-os "$BR" "$CHEAD" "$URL2" > "$T/b.out" 2>/dev/null; echo $? > "$T/arc" )
}

# R5 — a stale stamp: one push, the restamp commit on top of the main merge
ofix 202610142106-bh-2-b.sql
arun; RC=$(cat "$T/arc"); NEW=$(origin_rev "$BR")
[ "$RC" = 0 ] && ok || bad "R5 mc_rebase must answer rc 0 (got $RC; log: $(tail -3 "$LOG"))"
[ "$(pushes)" = 1 ] && ok || bad "R5 want exactly one push, got $(pushes): $(cat "$T/events.txt")"
[ "$("$REALGIT" -C "$T/origin.git" log -1 --format=%s "$NEW")" = 'restamp schema fragments (no SQL change)' ] \
  && ok || bad "R5 the pushed head must be the restamp commit, got: $("$REALGIT" -C "$T/origin.git" log -1 --format=%s "$NEW")"
"$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$(origin_rev main)" "$NEW^" && [ "$("$REALGIT" -C "$T/origin.git" rev-parse "$NEW^^2" 2>/dev/null)" = "$(origin_rev main)" ] \
  && ok || bad "R5 the restamp must sit on the merge of main"
"$REALGIT" -C "$T/origin.git" cat-file -e "$NEW:$SD/202610150900-bh-2-b.sql" 2>/dev/null \
  && ! "$REALGIT" -C "$T/origin.git" cat-file -e "$NEW:$SD/202610142106-bh-2-b.sql" 2>/dev/null \
  && ok || bad "R5 the fragment must be renamed on the pushed head"
[ "$(cat "$T/b.out")" = "$NEW" ] && ok || bad "R5 stdout must be the pushed head (got '$(cat "$T/b.out")')"
grep -qF "$URL2 $NEW" "$T/rebinds.txt" && ok || bad "R5 the approval must be rebound onto the pushed head (rebinds: $(cat "$T/rebinds.txt"))"
grep -q "SCHEMA_RESTAMP land head=${CHEAD:0:12} new=${NEW:0:12} renames=1" "$LOG" && ok || bad "R5 want the land restamp line: $(cat "$LOG")"

# R6 — restamp_same carries the verdict from the reviewed head onto it
how=$( . "$DIR/bin/lib/schema-restamp.sh"; restamp_same "$T/origin.git" main "$CHEAD" "$NEW" ); rc=$?
[ "$rc" = 0 ] && [ "$how" = restamp ] && ok || bad "R6 restamp_same on the land head: rc=$rc how='$how'"

# R5b — the knob off: the merge alone, no restamp commit
ofix 202610142106-bh-2-b.sql
MC_SCHEMA_RESTAMP=0 arun; RC=$(cat "$T/arc"); NEW=$(origin_rev "$BR")
[ "$RC" = 0 ] && [ "$(pushes)" = 1 ] && [ "$("$REALGIT" -C "$T/origin.git" rev-list --count --no-merges "$CHEAD..$NEW")" = 1 ] \
  && ! grep -q "^restamp schema" <<<"$("$REALGIT" -C "$T/origin.git" log --format=%s "$CHEAD..$NEW")" \
  && ok || bad "R5b MC_SCHEMA_RESTAMP=0 must push the merge alone (rc $RC, pushes $(pushes))"

# R7 — sr_apply refuses: rc 2, nothing pushed, a terminal mark
ofix 202610142106-bh-2-b.sql 202610150900-bh-2-b.sql
arun; RC=$(cat "$T/arc")
[ "$RC" = 2 ] && ok || bad "R7 a refused restamp must answer rc 2 (got $RC; log: $(tail -3 "$LOG"))"
[ "$(pushes)" = 0 ] && [ "$(origin_rev "$BR")" = "$CHEAD" ] && ok || bad "R7 nothing may be pushed (events: $(cat "$T/events.txt"))"
[ ! -s "$T/rebinds.txt" ] && ok || bad "R7 no rebind on a refusal"
grep -q "SCHEMA_RESTAMP land refused head=${CHEAD:0:12} .*not pushed" "$LOG" && ok || bad "R7 want one refused line: $(cat "$LOG")"
grep -rqs "^restampfail .* $CHEAD 202610150259$" "$T/h/state" && ok || bad "R7 want a restampfail mark for the head"
# R8b — asked again: rc 2, still nothing pushed, still one line
arun; RC=$(cat "$T/arc")
[ "$RC" = 2 ] && [ "$(pushes)" = 0 ] && [ "$(grep -c 'SCHEMA_RESTAMP land refused' "$LOG")" = 1 ] \
  && ok || bad "R8 a second land on the refused head: rc $RC, pushes $(pushes), $(grep -c 'SCHEMA_RESTAMP land refused' "$LOG") lines"

echo "restamp-land.bh-9154-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
