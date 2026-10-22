#!/bin/bash
# tests/migration-renumber-timestamp.bh-7875-test.sh — BH-7875: a migration
# whose prefix is exactly 14 digits (YYYYMMDDHHMMSS_slug.sql, project-6#2215)
# is a timestamp migration. bin/lib/migration-renumber.sh and the pre-queue
# hook bin/lib/mc-prequeue.d/migration-numbers.sh never read it as a number,
# never rename it and never count it as TAKEN. The settings row
# migration_renumber.format[.<project>] (env MNR_FORMAT) = timestamp turns the
# renumber off for a project, with one stderr line per branch it skipped.
#
#   T1  two 0450_* files collide with main's 0450: both move as today
#   T2  main 0451_x; branch adds 0451_y + 20261021183000_a: 0451_y -> 0452_y,
#       the timestamp file keeps its name (no 00000000000453_a.sql)
#   T2b main 0451_x; branch adds only 20261021183000_a: nothing changes
#   T3  main and branch share one timestamp: nothing changes
#   T4  main has a timestamp file: a 0450 collision still moves to 0451
#   T5  near misses: 13 and 15 digits are still sequential numbers
#   T6  open_prs on, a branch adds only a timestamp file: no PR list read
#   T7  mnr_conf reads migration_renumber.format.<project>
#   T8  MNR_FORMAT=timestamp: nothing moves, one stderr line; none with no
#       added file in the dir
#   T9  a bad value warns and reads as sequential; the env beats the row
#   T10 pre-queue, sequential, a head adds only a timestamp file: none, no
#       lock, no attempt mark, no list read
#   T11 pre-queue, sequential, 0336 collision + a timestamp file: pushed; the
#       pushed head keeps the timestamp file
#   T12 pq_gate, format.project-6-os=timestamp, a collision: proceed, no push,
#       no alert
#
# Real git over scratch repos; setting_get, gh_rest_pr_list_all and the mc_*
# conductor helpers are stubs. No network.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/migration-renumber-timestamp.bh-7875-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git  >/dev/null || { echo "git missing — skipping";  exit 0; }
command -v jq   >/dev/null || { echo "jq missing — skipping";   exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/migration-renumber.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB does not exist"; exit 1; }

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.invalid
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global advice.detachedHead false
unset MNR_DIR MNR_MODE MNR_LOCK_PREFIX MNR_FORMAT MNR_OPEN_PRS MNR_OPEN_PRS_MAX MNR_HEAD MNR_OPEN_QUEUED_ONLY

# ============================================================================
# Lib cases: each one builds its own repo in its own dir.
# ============================================================================
CASE=0
# newrepo <main-files...> — main holds the files, then branch `feature`.
newrepo() {
  local f
  CASE=$((CASE + 1)); U="$T/u$CASE"
  git init -q "$U"; mkdir -p "$U/prisma/sql" "$U/docs"
  for f in "$@"; do printf -- '-- migration:%s base\n' "${f%%_*}" > "$U/prisma/sql/$f"; done
  printf 'index\n' > "$U/docs/index.md"
  git -C "$U" add -A && git -C "$U" commit -qm base
  git -C "$U" checkout -qb feature
}
# addb <files...> — the branch adds the files in prisma/sql, in one commit.
addb() {
  local f
  for f in "$@"; do printf -- '-- migration:%s branch\nCREATE TABLE t_%s (id int);\n' "${f%%_*}" "${f%%_*}" > "$U/prisma/sql/$f"; done
  git -C "$U" add -A && git -C "$U" commit -qm branch
}
# SETTINGS: "key=value" lines setting_get answers; empty = no row.
SETTINGS="$T/settings"; : > "$SETTINGS"; LISTS="$T/lists"
# run <fn> <args...> — the lib function over $U in a clean shell; RC, $T/out, $T/err.
run() {
  ( cd "$T" && bash -c '
      . "$0" || exit 9
      setting_get() { local v; v=$(grep -m1 "^$1=" "$SETTINGS" 2>/dev/null) || return 1; printf "%s" "${v#*=}"; }
      gh_rest_pr_list_all() { echo "$*" >> "$LISTS"; printf "[]"; }
      "$@"' "$LIB" "$@" ) > "$T/out" 2>"$T/err"
  RC=$?
}
fix() { run mnr_fix "$U" main "${PROJ:-tproj}"; }
export SETTINGS LISTS
has()  { git -C "$U" ls-files --error-unmatch "prisma/sql/$1" >/dev/null 2>&1; }
nc()   { git -C "$U" rev-list --count main..HEAD; }
files() { git -C "$U" ls-files prisma/sql | sed 's|^prisma/sql/||' | tr '\n' ' '; }

export MNR_DIR=prisma/sql

# ── T1: two colliding 0450_* files still move as today ──
newrepo 0001_init.sql 0450_a.sql
addb 0450_b.sql 0450_c.sql
fix
[ "$RC" = 0 ] && has 0451_b.sql && has 0452_c.sql && ! has 0450_b.sql && ! has 0450_c.sql \
  && ok || bad "T1 0450_b -> 0451_b and 0450_c -> 0452_c, rc 0 (rc $RC; files: $(files); out: $(cat "$T/out"))"
[ "$(nc)" = 2 ] && [ "$(git -C "$U" log -1 --format=%B | grep -c '^Union-resolved: ')" = 2 ] \
  && ok || bad "T1 want one renumber commit with 2 Union-resolved trailers (commits $(nc))"

# ── T2: a timestamp file next to a moved sequential file keeps its name ──
newrepo 0001_init.sql 0451_x.sql
addb 0451_y.sql 20261021183000_a.sql
fix
[ "$RC" = 0 ] && has 0452_y.sql && ! has 0451_y.sql && ok || bad "T2 0451_y must move to 0452_y, rc 0 (rc $RC; files: $(files); out: $(cat "$T/out"))"
has 20261021183000_a.sql && ok || bad "T2 20261021183000_a.sql must keep its name (files: $(files))"
grep -q '/00000000000' <<<"$(git -C "$U" ls-files prisma/sql)" && bad "T2 no zero-padded name may exist (files: $(files))" || ok
grep -q 20261021183000 "$T/out" && bad "T2 the timestamp file must not be in the moves: $(cat "$T/out")" || ok

# ── T2b: the ticket's literal case ──
newrepo 0001_init.sql 0451_x.sql
addb 20261021183000_a.sql
pre=$(git -C "$U" rev-parse HEAD); fix
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(git -C "$U" rev-parse HEAD)" = "$pre" ] && has 20261021183000_a.sql \
  && ok || bad "T2b a timestamp-only branch changes nothing (rc $RC; out: $(cat "$T/out"))"

# ── T3: main and the branch share one timestamp ──
newrepo 0001_init.sql 20261021183000_z.sql
addb 20261021183000_s.sql
pre=$(git -C "$U" rev-parse HEAD); fix
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(git -C "$U" rev-parse HEAD)" = "$pre" ] && has 20261021183000_s.sql \
  && ok || bad "T3 a shared timestamp is not a collision (rc $RC; files: $(files); out: $(cat "$T/out"))"

# ── T4: main's timestamp file does not raise the highest number ──
newrepo 0001_init.sql 0450_w.sql 20261021183000_z.sql
addb 0450_q.sql
fix
[ "$RC" = 0 ] && has 0451_q.sql && ! has 0450_q.sql && ok || bad "T4 0450_q must move to 0451_q, not decline (rc $RC; files: $(files); out: $(cat "$T/out"))"

# ── T5: near misses stay sequential ──
newrepo 0001_init.sql 2026102118300_x.sql
addb 2026102118300_a.sql
fix
[ "$RC" = 0 ] && has 2026102118301_a.sql && ok || bad "T5 a 13-digit collision still moves (rc $RC; files: $(files); out: $(cat "$T/out"))"
newrepo 0001_init.sql 202610211830000_x.sql
addb 202610211830000_a.sql
fix
[ "$RC" = 0 ] && has 202610211830001_a.sql && ok || bad "T5 a 15-digit collision still moves (rc $RC; files: $(files); out: $(cat "$T/out"))"

# ── T6: open_prs on, a timestamp-only branch makes no PR list read ──
newrepo 0001_init.sql 0451_x.sql
git -C "$U" remote add origin https://github.com/o/r.git
addb 20261021183000_a.sql
: > "$LISTS"; MNR_OPEN_PRS=1 fix
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(grep -c . "$LISTS")" = 0 ] \
  && ok || bad "T6 want rc 0, no output, 0 list calls (rc $RC; lists $(grep -c . "$LISTS"); out: $(cat "$T/out"))"
# the same repo with a sequential file added: the list IS read (the stub counts)
addb 0452_n.sql
: > "$LISTS"; MNR_OPEN_PRS=1 fix
[ "$(grep -c . "$LISTS")" = 1 ] && ok || bad "T6 control: a sequential file must read the list once (lists $(grep -c . "$LISTS"))"

# ── T7: mnr_conf reads the format row ──
printf 'migration_renumber.format.project-6-os=timestamp\n' > "$SETTINGS"
run eval 'mnr_conf project-6-os; echo "$MNR_C_FORMAT $MNR_C_MODE"; mnr_conf other; echo "$MNR_C_FORMAT $MNR_C_MODE"'
[ "$(sed -n 1p "$T/out")" = "timestamp off" ] && [ "$(sed -n 2p "$T/out")" = "sequential fix" ] && [ ! -s "$T/err" ] \
  && ok || bad "T7 want 'timestamp off' then 'sequential fix', got: $(tr '\n' '|' < "$T/out") err: $(cat "$T/err")"
# timestamp wins over an explicit mode
MNR_MODE=fix run eval 'mnr_conf project-6-os; echo "$MNR_C_FORMAT $MNR_C_MODE"'
[ "$(cat "$T/out")" = "timestamp off" ] && ok || bad "T7 timestamp must win over MNR_MODE=fix, got: $(cat "$T/out")"
: > "$SETTINGS"

# ── T8: MNR_FORMAT=timestamp: nothing moves, one stderr line ──
newrepo 0001_init.sql 0450_a.sql
addb 0450_b.sql 0450_c.sql
pre=$(git -C "$U" rev-parse HEAD); MNR_FORMAT=timestamp fix
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(git -C "$U" rev-parse HEAD)" = "$pre" ] && has 0450_b.sql \
  && ok || bad "T8 timestamp must move nothing (rc $RC; files: $(files); out: $(cat "$T/out"))"
[ "$(grep -c . "$T/err")" = 1 ] \
  && grep -qx 'migration renumber: skipped — migration_renumber.format.tproj is timestamp (2 added file(s) in prisma/sql)' "$T/err" \
  && ok || bad "T8 want exactly one skip line, got: $(cat "$T/err")"
MNR_FORMAT=timestamp MNR_MODE=check run mnr_check "$U" main tproj
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok || bad "T8 mnr_check under timestamp is rc 0 with no output (rc $RC; out: $(cat "$T/out"))"
newrepo 0001_init.sql 0450_a.sql
printf 'more\n' >> "$U/docs/index.md"; git -C "$U" commit -qam docs
MNR_FORMAT=timestamp fix
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ] && ok || bad "T8 no added file in the dir: no line (rc $RC; err: $(cat "$T/err"))"

# ── T9: a bad value reads as sequential; the env beats the row ──
newrepo 0001_init.sql 0450_a.sql
addb 0450_b.sql 0450_c.sql
MNR_FORMAT=Timestamp fix
[ "$RC" = 0 ] && has 0451_b.sql && has 0452_c.sql && ok || bad "T9 'Timestamp' must read as sequential and move (rc $RC; files: $(files))"
[ "$(grep -c . "$T/err")" = 1 ] && grep -q "migration_renumber.format 'Timestamp' is not sequential|timestamp" "$T/err" \
  && ok || bad "T9 want one warning line, got: $(cat "$T/err")"
newrepo 0001_init.sql 0450_a.sql
addb 0450_b.sql
printf 'migration_renumber.format.tproj=timestamp\n' > "$SETTINGS"
MNR_FORMAT=sequential fix
[ "$RC" = 0 ] && has 0451_b.sql && ok || bad "T9 env MNR_FORMAT=sequential must beat a timestamp row (rc $RC; files: $(files); err: $(cat "$T/err"))"
: > "$SETTINGS"
unset MNR_DIR

# ============================================================================
# Pre-queue cases: the BH-7671 shape (real origin, the conductor's clone, the
# real hold-push; mc_* helpers stubbed).
# ============================================================================
[ -f "$DIR/bin/lib/mc-prequeue.d/migration-numbers.sh" ] || { echo "FAIL: migration-numbers.sh does not exist"; exit 1; }
SLUG=o/r; NUM=31; GHURL="https://github.com/$SLUG.git"
O="$T/origin.git"; W="$T/work"; OJ="$T/open.json"
git config --global "url.$O.insteadOf" "$GHURL"
export MC_STATE_DIR="$T/state" MC_REPOS="$T/repos"
ATT="$T/att"; LOG="$T/log"; ALERTS="$T/alerts"; LOCKS="$T/locks"

# shellcheck source=bin/lib/mc-prequeue.sh
. "$DIR/bin/lib/mc-prequeue.sh" || { echo "FAIL: cannot source bin/lib/mc-prequeue.sh"; exit 1; }
# shellcheck source=bin/lib/hold-push.sh
. "$DIR/bin/lib/hold-push.sh" || { echo "FAIL: cannot source bin/lib/hold-push.sh"; exit 1; }
# shellcheck source=bin/lib/migration-renumber.sh
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

mc_rest_var() { printf -v "$1" '{"sha":"%s"}' "$MAINSHA"; }
gh_rest() { echo "gh_rest $*" >> "$T/vendor"; return 97; }
gh_rest_pr_list_all() { echo "$*" >> "$LISTS"; cat "$OJ"; }
setting_get() { local v; v=$(grep -m1 "^$1=" "$SETTINGS" 2>/dev/null) || return 1; printf '%s' "${v#*=}"; }
mc_log() { echo "$*" >> "$LOG"; }
mc_attempt_has() { grep -qxF "$1" "$ATT" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$ATT"; }
mc_alert() { printf 'key=%s st=%s line=%s\n' "$1" "$2" "$3" >> "$ALERTS"; }
mc_git_locked() { echo lock >> "$LOCKS"; shift; "$@"; }
mc_funnel_repo() { MC_REMOTE="$O"; MC_FUNNEL_WT="$MC_REPOS/$P"; return 0; }
mc_git_auth_clear() { return 0; }
mc_pool_rebase_enabled() { return 1; }
mc_pool_rebase_enqueue() { echo "$*" >> "$T/pool-calls"; return 6; }
lane_knob() {
  case "$2" in
    MC_SCHEMA_RESTAMP) printf 0 ;;
    MC_MIGRATION_RECHECK) printf 1 ;;
  esac; return 0
}
pq_resolve() { :; }
pq_status_gate() { :; }
hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }

# pseed <project> <main-later-file|-> <pr-files...> — origin main holds 0001 and
#   0335; branch `pr` adds the files; main then gains <main-later-file>. The
#   conductor's clone ($MC_REPOS/<project>) is made last.
pseed() {
  local p="$1" later="$2" f; shift 2
  scratch_rm "$O" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$MC_REPOS" 2>/dev/null
  scratch_rm "$MC_STATE_DIR" 2>/dev/null
  : > "$ATT"; : > "$LOG"; : > "$ALERTS"; : > "$LOCKS"; : > "$LISTS"; printf '[]' > "$OJ"
  rm -f "$T/pool-calls" "$T/vendor"
  git init -q --bare -b main "$O"; mkdir -p "$W/prisma/sql"; git -C "$W" init -q -b main
  for f in 0001_init.sql 0335_agent_merge.sql; do printf -- '-- migration:%s base\n' "${f%%_*}" > "$W/prisma/sql/$f"; done
  git -C "$W" add -A; git -C "$W" commit -qm base
  git -C "$W" checkout -qb pr
  for f in "$@"; do printf -- '-- migration:%s pr\n' "${f%%_*}" > "$W/prisma/sql/$f"; done
  git -C "$W" add -A; git -C "$W" commit -qm pr; HEADSHA=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -q main
  if [ "$later" != - ]; then
    printf -- '-- migration:%s main\n' "${later%%_*}" > "$W/prisma/sql/$later"
    git -C "$W" add -A; git -C "$W" commit -qm main-later
  fi
  git -C "$W" push -q "$O" main pr; MAINSHA=$(git -C "$W" rev-parse main)
  mkdir -p "$MC_REPOS"; git clone -q "$GHURL" "$MC_REPOS/$p"
  export ACTIONS=1 P="$p" BR=pr KEY="$SLUG#$NUM" MNR_DIR=prisma/sql MNR_OPEN_PRS=1
  unset MNR_MODE MNR_FORMAT
}
ohead() { git -C "$O" rev-parse refs/heads/pr; }
otree() { git -C "$O" ls-tree --name-only "$(ohead)" prisma/sql/ | sed 's|^prisma/sql/||' | tr '\n' ' '; }

# ── T10: a head that adds only a timestamp file stops before the lock ──
pseed proj - 20261021183000_a.sql
w=$(pq_mignum "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" "$MAINSHA" 2>/dev/null | tail -n 1)
[ "$w" = none ] && ok || bad "T10 want none, got '$w' ($(cat "$LOG"))"
[ "$(grep -c . "$LOCKS")" = 0 ] && [ ! -s "$ATT" ] && [ "$(grep -c . "$LISTS")" = 0 ] \
  && ok || bad "T10 want 0 locks, 0 attempt marks, 0 list reads (locks $(grep -c . "$LOCKS"); att: $(cat "$ATT"); lists $(grep -c . "$LISTS"))"
[ "$(ohead)" = "$HEADSHA" ] && ok || bad "T10 nothing may be pushed"

# ── T11: a sequential collision next to a timestamp file ──
pseed proj 0336_main.sql 0336_x.sql 20261021183000_a.sql
w=$(pq_mignum "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" "$MAINSHA" 2>/dev/null | tail -n 1)
[ "${w%% *}" = pushed ] && ok || bad "T11 want pushed, got '$w' ($(cat "$LOG"))"
t=" $(otree)"
[[ "$t" == *" 0337_x.sql "* ]] && [[ "$t" == *" 20261021183000_a.sql "* ]] && [[ "$t" != *" 0336_x.sql "* ]] && [[ "$t" != *"00000000000"* ]] \
  && ok || bad "T11 the pushed head must hold 0337_x.sql and 20261021183000_a.sql (tree: $t)"

# ── T12: format.project-6-os=timestamp: pq_gate passes and does not push ──
pseed project-6-os 0450_w.sql 0450_q.sql 20261021183000_a.sql
printf 'migration_renumber.format.project-6-os=timestamp\n' > "$SETTINGS"
pq_mignum_wanted && bad "T12 pq_mignum_wanted must answer rc 1 under timestamp" || ok
w=$(pq_mignum "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" "$MAINSHA" 2>/dev/null | tail -n 1)
[ "$w" = none ] && ok || bad "T12 pq_mignum must answer none, got '$w'"
pq_gate "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" main > "$T/word"
[ "$(cat "$T/word")" = proceed ] && ok || bad "T12 pq_gate must proceed, got '$(cat "$T/word")' ($(cat "$LOG"))"
[ "$(ohead)" = "$HEADSHA" ] && ok || bad "T12 origin's pr branch must not move (tree: $(otree))"
[ ! -s "$ALERTS" ] && [ "$(grep -c . "$LOCKS")" = 0 ] && ok || bad "T12 want no alert and no lock (alerts: $(cat "$ALERTS"); locks $(grep -c . "$LOCKS"))"
grep -q MIGRATION_RECHECK "$LOG" && bad "T12 no MIGRATION_RECHECK line: $(cat "$LOG")" || ok
# control: the same seed with no row renumbers and pushes (the gate is live)
: > "$SETTINGS"
pq_gate "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" main > "$T/word"
[ "$(cat "$T/word")" = hold ] && [ "$(ohead)" != "$HEADSHA" ] && ok || bad "T12 control: with no row the collision must hold and push, got '$(cat "$T/word")'"

echo "migration-renumber-timestamp: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
