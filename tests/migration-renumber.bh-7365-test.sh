#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/migration-renumber.bh-7365-test.sh — BH-7365: a branch-added migration
# whose number is taken on main is renumbered, with its references, in ONE
# commit that carries `Union-resolved:` trailers; a collision that cannot be
# renumbered prints one clear line and changes nothing.
#
#   U  bin/lib/migration-renumber.sh over scratch repos (U1-U19).
#   I  a real mc_rebase against a real bare origin (I1-I4).
#   P  rebase_job_run, the pool twin (P1-P2).
#   B  the `# >>> migration renumber (BH-7365)` block of bin/lib/rb/pr.sh,
#      lifted with awk and run in a scratch build tree (B1-B3).
#   S  the composed worker/jobs schema in sqlite3 reads the seeded rows (S1).
#
# Run from anywhere: bash tests/migration-renumber.bh-7365-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git  >/dev/null || { echo "git missing — skipping";  exit 0; }
command -v jq   >/dev/null || { echo "jq missing — skipping";   exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/migration-renumber.sh"
RB="$DIR/bin/lib/rb/pr.sh"
REALGIT=$(command -v git)

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.detachedHead false
unset MNR_DIR MNR_MODE MNR_LOCK_PREFIX

# Lock keys: the integer of the ASCII bytes of "mk<NNNN>" (project-6's form).
LK0213=120307137524019   # "mk0213"
LK0235=120307137524533   # "mk0235"
LK792=469950216498       # "mk792" — a near miss that must never change

# ============================================================================
# U. the lib over scratch repos
# ============================================================================
U="$T/u"
BASEFILES="0001_init.sql 0011_legacy_a.sql 0011_legacy_b.sql 0011_legacy_c.sql 0011_legacy_d.sql 0128_outlook_connector.sql 0213_project-5_import.sql 0214_other.sql 0216_thing.sql 0234_last.sql"
# newrepo [<dir>] [<files...>] — main with the base files, then branch `feature`.
newrepo() {
  local d="${1:-prisma/sql}"; shift || true
  local files="${*:-$BASEFILES}" f n
  scratch_rm "$U" || exit 1; git init -q "$U"; mkdir -p "$U/$d" "$U/docs"
  for f in $files; do
    n=${f%%_*}
    printf -- '-- migration:%s base file\n' "$n" > "$U/$d/$f"
  done
  printf 'index\n' > "$U/docs/index.md"
  git -C "$U" add -A && git -C "$U" commit -qm base
  git -C "$U" checkout -qb feature
}
# mig <path> <NNNN> — a branch migration in project-6's shape.
mig() {
  mkdir -p "$U/$(dirname "$1")"
  printf -- '-- migration:%s lock "mk%s"\nSELECT pg_advisory_xact_lock(%s);\n-- not ours: %s\nCREATE TABLE IF NOT EXISTS t_%s (id int);\n' \
    "$2" "$2" "$(lk "mk$2")" "$LK792" "$2" > "$U/$1"
}
lk() { ( . "$LIB" 2>/dev/null; mnr_lock_int "$1" ) 2>/dev/null; }
commitb() { git -C "$U" add -A && git -C "$U" commit -qm "${1:-branch}"; }
fix() { # fix [env...] — mnr_fix over $U; RC, $T/out, $T/err
  ( cd "$T" && env MNR_DIR="${MNR_DIR-prisma/sql}" MNR_LOCK_PREFIX="${MNR_LOCK_PREFIX-mk}" "$@" \
      bash -c '. "$0" || exit 9; mnr_fix "$1" main tproj' "$LIB" "$U" ) > "$T/out" 2>"$T/err"
  RC=$?
}
files() { git -C "$U" ls-files prisma/sql | sed 's|^prisma/sql/||' | tr '\n' ' '; }
has()   { git -C "$U" ls-files --error-unmatch "$1" >/dev/null 2>&1; }
nc()    { git -C "$U" rev-list --count main..HEAD; }
clean() { [ -z "$(git -C "$U" status --porcelain)" ]; }

# U6 (part): the lock integer itself.
[ "$(lk mk0128)" = 120307137458744 ] && ok || bad "U6: mnr_lock_int mk0128 must be 120307137458744 (got '$(lk mk0128)')"
[ "$(lk mk0213)" = "$LK0213" ] && ok || bad "U6: mnr_lock_int mk0213 (got '$(lk mk0213)')"

# U1 + U4 + U5 + U6 + U7 + U11 — one collision with a base file.
newrepo
mig prisma/sql/0213_x.sql 0213
mkdir -p "$U/tests"
printf 'import "../prisma/sql/0213_x.sql";\nconst stem = "0213_x";\nconst other = "prisma/sql/0213_xy.sql";\nconst m = "migration:0213";\nconst far = "migration:02130";\n' > "$U/tests/x.test.ts"
printf 'see 0213_x.sql and migration:0213\n' >> "$U/docs/index.md"
commitb; PRE=$(git -C "$U" rev-parse HEAD)
fix
[ "$RC" = 0 ] && ok || bad "U1: rc 0 (got $RC; err: $(cat "$T/err"))"
has prisma/sql/0235_x.sql && ! has prisma/sql/0213_x.sql && ok || bad "U1: 0213_x.sql must become 0235_x.sql (files: $(files))"
[ "$(nc)" = 2 ] && [ "$(git -C "$U" rev-parse HEAD~1)" = "$PRE" ] && ok || bad "U1: exactly one new commit (count $(nc))"
clean && ok || bad "U1: the tree is clean after the commit ($(git -C "$U" status --porcelain | tr '\n' ' '))"
grep -qxF "0213 is taken on main by 0213_project-5_import.sql; this PR's number is 0235 (prisma/sql/0213_x.sql -> prisma/sql/0235_x.sql)" "$T/out" \
  && ok || bad "U1: the move line (got: $(cat "$T/out"))"
TS=$(cat "$U/tests/x.test.ts")
grep -qF '"../prisma/sql/0235_x.sql"' <<<"$TS" && grep -qF '"0235_x"' <<<"$TS" && ok || bad "U4: the added test names 0235_x (got: $TS)"
grep -qF 'prisma/sql/0213_xy.sql' <<<"$TS" && ok || bad "U4: 0213_xy.sql must not change (got: $TS)"
grep -qxF 'see 0235_x.sql and migration:0213' <(tail -1 "$U/docs/index.md") && ok || bad "U4/U5: a MODIFIED file gets the file name and keeps migration:0213 (got: $(tail -1 "$U/docs/index.md"))"
grep -qF '"migration:0235"' <<<"$TS" && ok || bad "U5: migration:0213 in an added test becomes migration:0235 (got: $TS)"
grep -qF '"migration:02130"' <<<"$TS" && ok || bad "U5: migration:02130 must not change (got: $TS)"
M=$(cat "$U/prisma/sql/0235_x.sql")
grep -qF -- '-- migration:0235 lock "mk0235"' <<<"$M" && ok || bad "U5/U6: the renamed file says migration:0235 and \"mk0235\" (got: $M)"
grep -qF "pg_advisory_xact_lock($LK0235)" <<<"$M" && ok || bad "U6: the lock key is the integer of mk0235 (got: $M)"
grep -qF -- "-- not ours: $LK792" <<<"$M" && ok || bad "U6: the mk792 integer must not change (got: $M)"
grep -qF "$LK0213" <<<"$M" && bad "U6: the old lock key must be gone (got: $M)" || ok
ST=$(git -C "$U" diff --name-status main HEAD | sort | tr '\t\n' ' ')
[ "$ST" = "A prisma/sql/0235_x.sql A tests/x.test.ts M docs/index.md " ] && ok || bad "U7: only branch paths differ from main (got: $ST)"
[ -z "$(git -C "$U" diff main HEAD -- prisma/sql/0213_project-5_import.sql)" ] && ok || bad "U7: the base file is never edited"
BODY=$(git -C "$U" log -1 --format=%B)
[ "$(grep -c '^Union-resolved: ' <<<"$BODY")" = 1 ] && grep -qxF 'Union-resolved: prisma/sql/0213_x.sql -> prisma/sql/0235_x.sql (BH-7365, migration renumbered)' <<<"$BODY" \
  && ok || bad "U11: one Union-resolved line per move (got: $BODY)"
grep -q '^BH-7365: renumber migration(s) past main [0-9a-f]\{8\}$' <(git -C "$U" log -1 --format=%s) && ok || bad "U11: the subject (got: $(git -C "$U" log -1 --format=%s))"

# U2 + U11 — a collision and the file after it: both move, order kept.
newrepo; mig prisma/sql/0213_x.sql 0213; mig prisma/sql/0214_y.sql 0214; commitb; fix
[ "$RC" = 0 ] && has prisma/sql/0235_x.sql && has prisma/sql/0236_y.sql && ! has prisma/sql/0214_y.sql && ok || bad "U2: 0235_x, 0236_y (rc $RC, files: $(files))"
[ "$(git -C "$U" log -1 --format=%B | grep -c '^Union-resolved: ')" = 2 ] && ok || bad "U11: two moves, two trailers"
grep -qxF 'SELECT pg_advisory_xact_lock(120307137524534);' "$U/prisma/sql/0236_y.sql" && ok || bad "U2: 0236_y carries the lock of mk0236 (got: $(cat "$U/prisma/sql/0236_y.sql"))"

# U3 — a duplicate inside the branch: the second moves, the first keeps its text.
newrepo; mig prisma/sql/0235_a.sql 0235; mig prisma/sql/0235_b.sql 0235; commitb; fix
[ "$RC" = 0 ] && has prisma/sql/0235_a.sql && has prisma/sql/0236_b.sql && ! has prisma/sql/0235_b.sql && ok || bad "U3: 0235_a kept, 0236_b (rc $RC, files: $(files))"
grep -qF 'migration:0235 lock "mk0235"' "$U/prisma/sql/0235_a.sql" && ok || bad "U3: the kept file keeps migration:0235 (got: $(head -1 "$U/prisma/sql/0235_a.sql"))"
grep -qF 'migration:0236 lock "mk0236"' "$U/prisma/sql/0236_b.sql" && ok || bad "U3: the moved file says 0236 (got: $(head -1 "$U/prisma/sql/0236_b.sql"))"
grep -qxF "0235 is used twice in this PR (0235_a.sql, 0235_b.sql); this PR's number is 0236 (prisma/sql/0235_b.sql -> prisma/sql/0236_b.sql)" "$T/out" \
  && ok || bad "U3: the duplicate line (got: $(cat "$T/out"))"

# U8 — a free number below the base max (TK-1118): nothing.
newrepo; mig prisma/sql/0115_x.sql 0115; commitb; fix
[ "$RC" = 0 ] && [ "$(nc)" = 1 ] && [ ! -s "$T/out" ] && has prisma/sql/0115_x.sql && ok || bad "U8: no commit, no output (rc $RC, commits $(nc), out: $(cat "$T/out"))"

# U9 — check mode: the message, rc 1, nothing changed.
newrepo; mig prisma/sql/0213_x.sql 0213; commitb; PRE=$(git -C "$U" rev-parse HEAD); fix MNR_MODE=check
[ "$RC" = 1 ] && ok || bad "U9: check mode answers rc 1 (got $RC)"
grep -qxF "0213 is taken on main by 0213_project-5_import.sql; this PR's number is 0235 (prisma/sql/0213_x.sql -> prisma/sql/0235_x.sql)" "$T/out" \
  && ok || bad "U9: the exact message line (got: $(cat "$T/out"))"
[ "$(git -C "$U" rev-parse HEAD)" = "$PRE" ] && clean && has prisma/sql/0213_x.sql && ok || bad "U9: the tree is unchanged"

# U10 — dir unset, or mode off: rc 0, no output, no commit.
MNR_DIR="" fix
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(git -C "$U" rev-parse HEAD)" = "$PRE" ] && ok || bad "U10: an unset dir is a no-op (rc $RC, out: $(cat "$T/out"))"
fix MNR_MODE=off
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(git -C "$U" rev-parse HEAD)" = "$PRE" ] && ok || bad "U10: MNR_MODE=off is a no-op (rc $RC, out: $(cat "$T/out"))"

# U12 — no free number inside the width: decline, nothing changed.
newrepo prisma/sql 0001_init.sql 0213_project-5_import.sql 9999_last.sql
mig prisma/sql/0213_x.sql 0213; commitb; PRE=$(git -C "$U" rev-parse HEAD); fix
[ "$RC" = 1 ] && ok || bad "U12: a decline answers rc 1 (got $RC)"
grep -qxF "0213 is taken on main by 0213_project-5_import.sql; no free number above 9999 for prisma/sql/0213_x.sql (width 4) — not renumbered" "$T/out" \
  && ok || bad "U12: the decline line (got: $(cat "$T/out"))"
grep -q "this PR's number is" "$T/out" && bad "U12: a decline never claims a new number" || ok
[ "$(git -C "$U" rev-parse HEAD)" = "$PRE" ] && clean && ok || bad "U12: HEAD is the pre sha and the tree is clean"

# U13 — names that are not migrations, and a sub directory: ignored.
newrepo
mkdir -p "$U/prisma/sql/sub"
: > "$U/prisma/sql/.gitkeep"; printf 'r\n' > "$U/prisma/sql/README.md"
mig prisma/sql/0213-x.sql 0213; mig prisma/sql/0213_X.sql 0213; mig prisma/sql/sub/0213_x.sql 0213
commitb; fix
[ "$RC" = 0 ] && [ "$(nc)" = 1 ] && [ ! -s "$T/out" ] && ok || bad "U13: non-migration names are ignored (rc $RC, commits $(nc), out: $(cat "$T/out"))"

# U14 — the legacy group 0011 x4 on main: a new 0011 is still renumbered.
newrepo; mig prisma/sql/0011_new.sql 0011; commitb; fix
[ "$RC" = 0 ] && has prisma/sql/0235_new.sql && ok || bad "U14: 0011_new -> 0235_new (rc $RC, files: $(files))"
grep -qF "0011 is taken on main by 0011_legacy_a.sql;" "$T/out" && ok || bad "U14: the line names the first base file (got: $(cat "$T/out"))"

# U15 — a 3-digit dir keeps width 3.
newrepo db/migrations 001_a.sql 010_b.sql
mkdir -p "$U/db/migrations"; printf 'x\n' > "$U/db/migrations/010_x.sql"; commitb
MNR_DIR=db/migrations fix
[ "$RC" = 0 ] && git -C "$U" ls-files --error-unmatch db/migrations/011_x.sql >/dev/null 2>&1 && ok \
  || bad "U15: 010_x -> 011_x (rc $RC, files: $(git -C "$U" ls-files db | tr '\n' ' '))"

# U16 — a free file before the first collision keeps its number.
newrepo; mig prisma/sql/0215_a.sql 0215; mig prisma/sql/0216_b.sql 0216; mig prisma/sql/0217_c.sql 0217; commitb; fix
[ "$RC" = 0 ] && has prisma/sql/0215_a.sql && has prisma/sql/0235_b.sql && has prisma/sql/0236_c.sql && ok || bad "U16: 0215 kept, 0235_b, 0236_c (rc $RC, files: $(files))"

# U17 — a chain: 0213 -> 0235 while the branch's own 0235 -> 0236. One pass,
# so 0213's new references are never moved a second time.
newrepo; mig prisma/sql/0213_x.sql 0213; mig prisma/sql/0235_a.sql 0235
printf 'a "migration:0213" b "migration:0235"\n' > "$U/docs/chain.md"; commitb; fix
[ "$RC" = 0 ] && has prisma/sql/0235_x.sql && has prisma/sql/0236_a.sql && ok || bad "U17: 0235_x, 0236_a (rc $RC, files: $(files))"
grep -qF 'migration:0235 lock "mk0235"' "$U/prisma/sql/0235_x.sql" && grep -qF 'migration:0236 lock "mk0236"' "$U/prisma/sql/0236_a.sql" \
  && ok || bad "U17: each file names its own new number ($(head -1 "$U/prisma/sql/0235_x.sql") / $(head -1 "$U/prisma/sql/0236_a.sql"))"
grep -qxF 'a "migration:0235" b "migration:0236"' "$U/docs/chain.md" && ok || bad "U17: an added file maps each number once (got: $(cat "$U/docs/chain.md"))"

# U18 — a bad lock prefix: no lock rewrite, one warning, the rename still happens.
newrepo; mig prisma/sql/0213_x.sql 0213; commitb; MNR_LOCK_PREFIX='m-k' fix
[ "$RC" = 0 ] && has prisma/sql/0235_x.sql && ok || bad "U18: the rename still happens (rc $RC)"
grep -qF "pg_advisory_xact_lock($LK0213)" "$U/prisma/sql/0235_x.sql" && ok || bad "U18: no lock rewrite with a bad prefix"
grep -q 'lock_prefix' "$T/err" && ok || bad "U18: one warning names the knob (err: $(cat "$T/err"))"

# U19 — the knobs come from setting_get when the env does not set them.
newrepo; mig prisma/sql/0213_x.sql 0213; commitb
( cd "$T" && env -u MNR_DIR -u MNR_LOCK_PREFIX bash -c '
    setting_get() { case "$1" in migration_renumber.dir.tproj) printf prisma/sql ;; migration_renumber.lock_prefix.tproj) printf mk ;; *) return 2 ;; esac; }
    . "$0" || exit 9; mnr_fix "$1" main tproj' "$LIB" "$U" ) > "$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && has prisma/sql/0235_x.sql && grep -qF "pg_advisory_xact_lock($LK0235)" "$U/prisma/sql/0235_x.sql" \
  && ok || bad "U19: the settings rows turn it on (rc $RC, files: $(files), err: $(cat "$T/err"))"

# ============================================================================
# I + P. the conductor's mc_rebase and the pool twin, against a real origin
# ============================================================================
SLUG=example-org/demo-os
URL2="https://github.com/$SLUG/pull/2"
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos" "$T/wt"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/lib/rebase-job.sh "$T/h" >/dev/null || exit 1
[ -r "$T/h/bin/lib/migration-renumber.sh" ] && ok || bad "I0: the conductor closure must carry bin/lib/migration-renumber.sh"
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

# ofix <main-adds> <branch-adds> — a fresh origin. main: base migrations; the
# PR branch ticket/bh-9002 forks and adds <branch-adds>; then main adds
# <main-adds>. Each list is space-separated file names under prisma/sql.
ofix() {
  local S="$T/seed" f
  rm -rf "$T/origin.git" "$S" "$T/h/tmp/conductor" "$T/machine"
  : > "$T/events.txt"; : > "$T/rebinds.txt"; : > "$LOG"
  "$REALGIT" init -q --bare "$T/origin.git"
  "$REALGIT" clone -q "$T/origin.git" "$S" 2>/dev/null
  mkdir -p "$S/prisma/sql"
  for f in 0001_init.sql 0213_project-5_import.sql 0234_last.sql; do printf -- '-- migration:%s\n' "${f%%_*}" > "$S/prisma/sql/$f"; done
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm base
  "$REALGIT" -C "$S" checkout -qb ticket/bh-9002
  for f in $2; do printf -- '-- migration:%s branch\n' "${f%%_*}" > "$S/prisma/sql/$f"; done
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm branch
  CHEAD=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" checkout -q main
  for f in $1; do printf -- '-- migration:%s main\n' "${f%%_*}" > "$S/prisma/sql/$f"; done
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm 'main moves'
  "$REALGIT" -C "$S" push -q origin main ticket/bh-9002 2>/dev/null
}
origin_rev() { "$REALGIT" -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
otree() { "$REALGIT" -C "$T/origin.git" ls-tree --name-only "$(origin_rev ticket/bh-9002)" prisma/sql/ 2>/dev/null | sed 's|^prisma/sql/||' | tr '\n' ' '; }
arun() { # arun <out-file> — mc_rebase in a fresh subshell; rc to $T/arc
  ( . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init; MC_REPOS="$T/repos"
    MNR_DIR=prisma/sql mc_rebase "$SLUG" demo-os ticket/bh-9002 "$CHEAD" "$URL2" > "$1" 2>/dev/null; echo $? > "$T/arc" )
}

# I1 + I2 — main took 0235 after the branch forked; the branch's 0235 moves.
ofix 0235_a.sql 0235_b.sql
arun "$T/i1.out"; RC=$(cat "$T/arc"); NEW=$(origin_rev ticket/bh-9002)
[ "$NEW" != "$CHEAD" ] && ok || bad "I1: the branch was pushed (rc $RC; log: $(tail -3 "$LOG"))"
[ "$(otree)" = "0001_init.sql 0213_project-5_import.sql 0234_last.sql 0235_a.sql 0236_b.sql " ] && ok || bad "I1: the pushed head has 0235_a and 0236_b, no 0235_b (got: $(otree))"
[ "$RC" = 5 ] && ok || bad "I2: a renumbered rebase answers rc 5 (got $RC)"
[ -s "$T/rebinds.txt" ] && bad "I2: job_verdict_rebind must not be called (got: $(cat "$T/rebinds.txt"))" || ok
grep -qF 'union-resolved (prisma/sql/0235_b.sql -> prisma/sql/0236_b.sql (BH-7365, migration renumbered))' "$LOG" && ok || bad "I2: the union-resolved log line (got: $(cat "$LOG"))"
grep -qF "0235 is taken on main by 0235_a.sql; this PR's number is 0236" "$LOG" && ok || bad "I2: the log names the move (got: $(cat "$LOG"))"

# I3 — a forced decline: rc 2, nothing pushed, the message in the log.
ofix "0235_a.sql 9999_z.sql" 0235_b.sql
arun "$T/i3.out"; RC=$(cat "$T/arc")
[ "$RC" = 2 ] && ok || bad "I3: a decline answers rc 2 (got $RC; log: $(tail -3 "$LOG"))"
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ! grep -q '^PUSH' "$T/events.txt" && ok || bad "I3: nothing pushed (events: $(cat "$T/events.txt"))"
grep -qF "migration number collision not fixed — 0235 is taken on main by 0235_a.sql; no free number above 9999 for prisma/sql/0235_b.sql (width 4) — not renumbered" "$LOG" \
  && ok || bad "I3: the message in the conductor log (got: $(cat "$LOG"))"

# I4 — no collision: the rc 0 path, the rebind, no renumber commit.
ofix 0235_a.sql 0236_b.sql
arun "$T/i4.out"; RC=$(cat "$T/arc")
[ "$RC" = 0 ] && [ -s "$T/rebinds.txt" ] && ok || bad "I4: a clean main merge answers rc 0 and rebinds (rc $RC, rebinds: $(cat "$T/rebinds.txt"))"
grep -q 'BH-7365' <<<"$("$REALGIT" -C "$T/origin.git" log --format=%s "$CHEAD..$(origin_rev ticket/bh-9002)")" && bad "I4: no renumber commit" || ok

# P1 — the pool twin: REBASED and the UNION line.
pjob() { ( cd "$T" && . "$T/h/bin/lib/rebase-job.sh"
  REBASE_WT_DIR="$T/wt" MNR_DIR=prisma/sql PROJECT=demo-os \
    rebase_job_run "$T/machine" "$SLUG" ticket/bh-9002 "$CHEAD" main "$T/RESULT" "$T/h" ) >/dev/null 2>&1; }
ofix 0235_a.sql 0235_b.sql
"$REALGIT" clone -q "$T/origin.git" "$T/machine" 2>/dev/null
pjob
NEW=$(origin_rev ticket/bh-9002)
[ "$(head -1 "$T/RESULT" 2>/dev/null)" = "REBASED $NEW" ] && [ "$NEW" != "$CHEAD" ] && ok || bad "P1: REBASED <the pushed sha> (got: $(head -1 "$T/RESULT" 2>/dev/null))"
grep -qxF 'UNION: prisma/sql/0235_b.sql -> prisma/sql/0236_b.sql (BH-7365, migration renumbered)' "$T/RESULT" && ok || bad "P1: the UNION line (got: $(cat "$T/RESULT" 2>/dev/null))"
[ "$(otree)" = "0001_init.sql 0213_project-5_import.sql 0234_last.sql 0235_a.sql 0236_b.sql " ] && ok || bad "P1: the pushed head has 0236_b (got: $(otree))"

# P2 — the pool twin declines: GATE_RED migration-number, nothing pushed.
ofix "0235_a.sql 9999_z.sql" 0235_b.sql
"$REALGIT" clone -q "$T/origin.git" "$T/machine" 2>/dev/null
pjob
case "$(head -1 "$T/RESULT" 2>/dev/null)" in "GATE_RED migration-number: 0235 is taken on main by 0235_a.sql;"*) ok ;; *) bad "P2: GATE_RED migration-number: (got: $(head -1 "$T/RESULT" 2>/dev/null))" ;; esac
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "P2: nothing pushed"

# ============================================================================
# B. the builder's pre-PR block, lifted from bin/lib/rb/pr.sh
# ============================================================================
awk 'index($0,"# >>> migration renumber (BH-7365)")==1{f=1} f{print} index($0,"# <<< migration renumber (BH-7365)")==1{exit}' "$RB" > "$T/mnr-block.sh"
[ -s "$T/mnr-block.sh" ] && bash -n "$T/mnr-block.sh" && ok || bad "B0: could not lift a valid migration renumber block"
L_RV=$(grep -n '^# <<< rebase verify' "$RB" | head -1 | cut -d: -f1)
L_MN=$(grep -n '^# >>> migration renumber (BH-7365)' "$RB" | head -1 | cut -d: -f1)
L_CK=$(grep -n '^# >>> caller check (BH-5791)' "$RB" | head -1 | cut -d: -f1)
[ -n "$L_MN" ] && [ -n "$L_RV" ] && [ -n "$L_CK" ] && [ "$L_RV" -lt "$L_MN" ] && [ "$L_MN" -lt "$L_CK" ] && ok \
  || bad "B0: the block sits after the rebase verify and before the caller check (${L_RV:-?} < ${L_MN:-?} < ${L_CK:-?})"
brun() { # brun [env...] — the block in $U, origin/main = main; section to $T/sec
  mkdir -p "$T/build"; : > "$T/build/pipeline.log"
  "$REALGIT" -C "$U" update-ref refs/remotes/origin/main main
  ( cd "$U" && env BUILD="$T/build" PROJECT=tproj KEY=BH-7365 BASE=main STACK_ON="" PREPR_SECTION="" \
      MNR_DIR=prisma/sql MNR_LOCK_PREFIX=mk "$@" \
      bash -c 'STAMP() { echo TS; }; RESULT() { echo "$*" > "$0.result"; }; . "$0"; printf "%s" "$PREPR_SECTION"' "$T/mnr-block.sh" ) > "$T/sec" 2>"$T/b.err"
}
# B1 — a collision: renamed, one log line, the PR-body section.
newrepo; mig prisma/sql/0213_x.sql 0213; commitb; brun
has prisma/sql/0235_x.sql && [ "$(nc)" = 2 ] && ok || bad "B1: the block renames and commits (files: $(files); err: $(cat "$T/b.err"))"
[ "$(awk 'NF { print; exit }' "$T/sec")" = '## Migration numbers (BH-7365)' ] && ok || bad "B1: the section heading (got: $(cat "$T/sec"))"
grep -qxF -- "- 0213 is taken on main by 0213_project-5_import.sql; this PR's number is 0235 (prisma/sql/0213_x.sql -> prisma/sql/0235_x.sql)" "$T/sec" \
  && ok || bad "B1: the section lists the move (got: $(cat "$T/sec"))"
[ "$(grep -c 'migration renumbered: ' "$T/build/pipeline.log")" = 1 ] && ok || bad "B1: one pipeline.log line (got: $(cat "$T/build/pipeline.log"))"
[ ! -e "$T/mnr-block.sh.result" ] && ok || bad "B1: the block never calls RESULT"
# B2 — no collision: no commit, an empty section.
newrepo; mig prisma/sql/0240_x.sql 0240; commitb; brun
[ "$(nc)" = 1 ] && [ ! -s "$T/sec" ] && ok || bad "B2: no commit and no section (commits $(nc), section: $(cat "$T/sec"))"
# B3 — a stacked build: nothing runs.
newrepo; mig prisma/sql/0213_x.sql 0213; commitb; brun STACK_ON=ticket/parent
[ "$(nc)" = 1 ] && [ ! -s "$T/sec" ] && has prisma/sql/0213_x.sql && ok || bad "B3: STACK_ON set = no call (commits $(nc), section: $(cat "$T/sec"))"
# B4 — a decline: the "not renumbered" section, no commit, no stop.
newrepo prisma/sql 0001_init.sql 0213_project-5_import.sql 9999_last.sql; mig prisma/sql/0213_x.sql 0213; commitb; brun
[ "$(nc)" = 1 ] && grep -qF '## Migration numbers (BH-7365): not renumbered' "$T/sec" && ok || bad "B4: a decline writes the not-renumbered section (commits $(nc), section: $(cat "$T/sec"))"
grep -q 'migration renumbered: ' "$T/build/pipeline.log" && bad "B4: a decline is never logged as renumbered" || ok

# ============================================================================
# S. the seed rows, through the composed schema
# ============================================================================
if command -v python3 >/dev/null && python3 -c 'import sqlite3' 2>/dev/null; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/schema-build.sh" --to "$T/schema.sql" >/dev/null 2>"$T/s.err" || bad "S1: schema-build --to failed ($(head -2 "$T/s.err"))"
  S1=$(python3 -I -c '
import sqlite3, sys
db = sqlite3.connect(":memory:")
db.executescript(open(sys.argv[1]).read())
for k in ("migration_renumber.dir.project-6-os", "migration_renumber.lock_prefix.project-6-os"):
    r = db.execute("SELECT value FROM settings WHERE key = ?", (k,)).fetchone()
    print(k + "=" + (r[0] if r else "-"))
' "$T/schema.sql" 2>"$T/s.err")
  grep -qxF 'migration_renumber.dir.project-6-os=prisma/sql' <<<"$S1" && ok || bad "S1: migration_renumber.dir.project-6-os = prisma/sql (got: $S1 $(head -2 "$T/s.err"))"
  grep -qxF 'migration_renumber.lock_prefix.project-6-os=mk' <<<"$S1" && ok || bad "S1: migration_renumber.lock_prefix.project-6-os = mk (got: $S1)"
else
  echo "S1: python3 sqlite3 missing — skipped"
fi

echo "migration-renumber.bh-7365-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
