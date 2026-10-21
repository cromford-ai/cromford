#!/bin/bash
# tests/merge-conductor-migration-hold.bh-7785-test.sh — BH-7785: the merge
# conductor holds a READY PR that adds a migration production has not applied.
#
# Part A (unit) sources bin/lib/migration-hold.sh and the fragment
# bin/merge-conductor.d/bh-7785-migration-hold.sh with their seams stubbed:
# setting_get from fixture files, gh_rest (under the real _gh_rest_list) from a
# fixture files list, curl on PATH as a fake that logs every call and answers
# the app's migration status from fixture files.
#   D1-D6  the decision tables (path, glob, name, probe answer, settings, cache)
#   R1     the cache writer/reader round trip
#   X1-X3  the exit paths of mc_mig_hold and their side-effect counts
#   L1     an apply lane: held for it, no probe, no comment, no alert
#   A1/A2  one alert per (PR, head); observe mode alerts nothing
# Part B (whole tick) drives the WHOLE bin/merge-conductor.sh in a scratch tree
# (the fixture of tests/conductor-hold-comment-sites.bh-3456-test.sh part 2).
#   M1-M7, R2, Z1, V1, and RED: the same M1 tick with the fragment absent
#   enqueues, which proves the gate is what holds.
# 0 network calls: the fake gh and curl are first on PATH, and V1 asserts every
# curl URL is on a .test host.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-migration-hold.bh-7785-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: merge-conductor-migration-hold: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/migration-hold.sh"
FRAG="$DIR/bin/merge-conductor.d/bh-7785-migration-hold.sh"
for SRC in "$LIB" "$FRAG" "$DIR/bin/merge-conductor.sh" "$DIR/bin/lib/mc-hold-comment.sh"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done

H1=$(printf 'a%.0s' $(seq 40)); H2=$(printf 'b%.0s' $(seq 40))
SLUG=example-org/mgfy-os

# ---- the fake curl, shared by both parts ------------------------------------
# FXD/curl.log: one "METHOD URL" line per call. FXD/status.log: one line per
# migrations/status call. st-code / st-body answer it (absent: 200 {"applied":[]});
# st-timeout answers code 000 and rc 28. FXD/set/<key> is a settings row.
mkfakecurl() { # mkfakecurl <fakebin> <fxd>
  mkdir -p "$1" "$2/set"
  cat > "$1/curl" <<EOF
#!/bin/bash
FXD="$2"
out=""; w=""; M=GET; URL=""
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;;
  -m|-H|--connect-timeout|--data-binary|-d|--max-time) shift 2 ;;
  -*) shift ;; *) URL="\$1"; shift ;;
esac; done
printf '%s %s\n' "\$M" "\$URL" >> "\$FXD/curl.log"; printf '%s %s\n' "\$M" "\$URL" >> "\$FXD.curl-all.log"
emit() {
  if [ -n "\$out" ]; then printf '%s' "\$2" > "\$out"; else printf '%s' "\$2"; fi
  case "\$w" in '') ;; \$'\n'*) printf '\n%s' "\$1" ;; *) printf '%s' "\$1" ;; esac
}
case "\$M \$URL" in
  "GET "*/api/internal/migrations/status)
    echo "\$URL" >> "\$FXD/status.log"
    [ -e "\$FXD/st-timeout" ] && { printf '000'; exit 28; }
    emit "\$(cat "\$FXD/st-code" 2>/dev/null || echo 200)" "\$(cat "\$FXD/st-body" 2>/dev/null || echo '{"applied":[]}')" ;;
  "GET "*/api/settings/*)
    k="\${URL##*/api/settings/}"
    if [ -f "\$FXD/set/\$k" ]; then emit 200 "\$(jq -nc --arg k "\$k" --arg v "\$(cat "\$FXD/set/\$k")" '{setting:{key:\$k,value:\$v}}')"
    else emit 404 '{"error":"not found"}'; fi ;;
  "PUT "*|"POST "*) emit 200 '{"ok":true}' ;;
  "GET "*/api/verdicts\?*) emit 200 '{"standing":null}' ;;
  *) emit 404 '{"error":"not found"}' ;;
esac
exit 0
EOF
  chmod +x "$1/curl"
}

# ============================================================================
# Part A — the lib and the fragment, sourced, seams stubbed. In a subshell; it
# prints its own FAIL lines and exits with its fail count.
# ============================================================================
(
  PASS=0; FAIL=0
  A="$T/a"; FXD="$A/fx"; mkdir -p "$A/h/env" "$A/h/state/merge-conductor"
  mkfakecurl "$A/fakebin" "$FXD"
  export PATH="$A/fakebin:$PATH" HARNESS="$A/h" HENV="$A/h/env" MC_STATE_DIR="$A/h/state/merge-conductor"
  printf 'DATA_LANE_APP_BASE=http://app.test\nMIGRATION_TOKEN=tok-fixture-1\n' > "$A/h/env/mgfy.env"
  setting_get() { [ -e "$FXD/set/.down" ] && return 1; [ -f "$FXD/set/$1" ] || return 2; cat "$FXD/set/$1"; }
  # gh_rest: the files list from FXD/files.json, paged as REST pages it.
  gh_rest() {
    local path="$2" page=1 a
    for a in "$@"; do case "$a" in page=*) page="${a#page=}" ;; esac; done
    echo "$path page=$page" >> "$FXD/files.log"
    [ -e "$FXD/files-fail" ] && { GH_REST_STATUS=502; return 75; }
    GH_REST_STATUS=200
    jq -c --argjson p "$page" '.[(($p-1)*100):($p*100)]' "$FXD/files.json"
  }
  mc_log() { printf '%s\n' "$*" >> "$FXD/log"; }
  mc_alert() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FXD/alerts"; }
  mc_attempt_has() { grep -qxF "$1" "$FXD/attempts" 2>/dev/null; }
  mc_attempt_put() { echo "$1" >> "$FXD/attempts"; }
  mc_hold_comment() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$FXD/trace"; }
  # shellcheck source=bin/lib/gh-rest-list.sh
  . "$DIR/bin/lib/gh-rest-list.sh" || exit 90
  H="$A/h"
  # shellcheck source=bin/lib/migration-hold.sh
  . "$LIB" || exit 91
  # shellcheck source=bin/merge-conductor.d/bh-7785-migration-hold.sh
  . "$FRAG" || exit 92
  F=0; no() { F=$((F+1)); echo "FAIL: merge-conductor-migration-hold: $1"; }
  n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
  # reset — a clean fixture: no rows, no files, no cache, no logs.
  reset() {
    scratch_rm "$FXD"; mkdir -p "$FXD/set"; scratch_rm "$MC_STATE_DIR/migration-hold"
    echo '[]' > "$FXD/files.json"; unset MMH_NOW
  }
  # files <path:status>... — the PR's files list.
  files() { local x; for x in "$@"; do printf '%s\n' "$x"; done | jq -Rnc '[inputs | split(":") | {filename: .[0], status: .[1]}]' > "$FXD/files.json"; }
  # run <key> <head> — one mc_mig_hold on a READY row of project mgfy.
  run() { STATE=READY; WHY="ready"; P=mgfy; SLUG=example-org/mgfy-os; NUM=31; KEY="${1:-$SLUG#31}"; HEAD="${2:-$H1}"; ACTIONS="${ACTIONS_X:-1}"; KILL=0; mc_mig_hold; }

  # ---- D1 path is a migration ----
  G='prisma/migrations/*/migration.sql supabase/migrations/*.sql migrations/*.sql worker/jobs/schema.d/*'
  for p in prisma/migrations/0423_x/migration.sql supabase/migrations/20261020_a.sql worker/jobs/schema.d/202610210400-bh-1-x.sql migrations/0001_a.sql; do
    reset; echo "$G" > "$FXD/set/mc_migration_hold.globs.mgfy"; files "$p:added"; run
    [ "$STATE" = WAIT_CI ] && [ "$(n "$FXD/status.log")" = 1 ] || no "D1 $p added must be probed and held (state $STATE, probes $(n "$FXD/status.log"))"
  done
  # index 150: past page 1 of the REST list
  reset; echo "$G" > "$FXD/set/mc_migration_hold.globs.mgfy"
  { for i in $(seq 1 149); do echo "src/f$i.ts:added"; done; echo "prisma/migrations/0423_x/migration.sql:added"; } > "$FXD/pl"
  jq -Rnc '[inputs | split(":") | {filename: .[0], status: .[1]}]' < "$FXD/pl" > "$FXD/files.json"
  run
  [ "$STATE" = WAIT_CI ] && [[ $WHY == "HELD_MIGRATION 0423_x:"* ]] || no "D1 a migration at index 150 (page 2) must hold (state $STATE why $WHY)"
  for p in prisma/migrations/0423_x/README.md prisma/migrations/migration_lock.toml supabase/migrations/sub/a.sql \
           migrations/x.sql.bak Migrations/x.sql docs/migrations/x.sql; do
    reset; echo "$G" > "$FXD/set/mc_migration_hold.globs.mgfy"; files "$p:added"; run
    [ "$STATE" = READY ] && [ "$(n "$FXD/status.log")" = 0 ] || no "D1 $p must not be a migration (state $STATE, probes $(n "$FXD/status.log"))"
  done
  for s in modified removed renamed; do
    reset; echo "$G" > "$FXD/set/mc_migration_hold.globs.mgfy"; files "prisma/migrations/0423_x/migration.sql:$s"; run
    [ "$STATE" = READY ] && [ "$(n "$FXD/status.log")" = 0 ] || no "D1 a $s migration file must not count (state $STATE)"
  done

  # ---- D2 glob validity ----
  for g in 'prisma/migrations/*/migration.sql' 'a/b-c_d.e/*.sql'; do mmh_glob_ok "$g" || no "D2 '$g' must be kept"; done
  for g in '/abs/*.sql' 'a/../b/*.sql' 'a/**/x.sql' '' 'a/[x]/y.sql' 'a/./b.sql'; do mmh_glob_ok "$g" && no "D2 '$g' must be dropped"; done
  reset; echo '/abs/*.sql a/**/x.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"
  mmh_globs mgfy >/dev/null; rc=$?
  [ "$rc" = 2 ] && [ "$(grep -c 'is not valid' "$FXD/log")" = 2 ] || no "D2 only-invalid globs: gate off (rc $rc) with one log line each ($(cat "$FXD/log"))"
  reset; echo 'supabase/migrations/*.sql   /abs/*.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"
  [ "$(mmh_globs mgfy)" = 'supabase/migrations/*.sql' ] || no "D2 a valid glob next to an invalid one is kept alone (got '$(mmh_globs mgfy)')"
  # match is segment-wise
  mmh_glob_match 'migrations/*.sql' 'migrations/a.sql' || no "D2 migrations/*.sql must match migrations/a.sql"
  mmh_glob_match 'migrations/*.sql' 'migrations/a/b.sql' && no "D2 * must not cross /"
  mmh_glob_match 'worker/jobs/schema.d/*' 'worker/jobs/schema.d/x.sql' || no "D2 schema.d/* must match"

  # ---- D3 name and applied match ----
  [ "$(mmh_name prisma/migrations/0423_x/migration.sql)" = 0423_x ] || no "D3 the prisma folder name"
  [ "$(mmh_name prisma/sql/0423_x.sql)" = 0423_x ] || no "D3 a .sql basename"
  [ "$(mmh_name worker/jobs/schema.d/202610210400-bh-1-x.sql)" = 202610210400-bh-1-x ] || no "D3 a schema.d fragment"
  d3() { # d3 <ledger-body> <want rc> <label>
    printf '%s' "$1" > "$FXD/b.json"; mmh_applied_has "$FXD/b.json" 0423_x; [ "$?" = "$2" ] || no "D3 $3 (body $1)"; }
  mkdir -p "$FXD"
  d3 '{"applied":[{"filename":"0423_x.sql"}]}' 0 "ledger 0423_x.sql is applied"
  d3 '{"applied":[{"filename":"0423_x"}]}' 0 "ledger 0423_x is applied"
  d3 '{"applied":[{"filename":"prisma/migrations/0423_x/migration.sql"}]}' 0 "the full path is applied"
  d3 '{"applied":[{"filename":"0423_xy.sql"}]}' 1 "a prefix near miss is not applied"
  d3 '{"applied":[{"filename":"0423_X.sql"}]}' 1 "case matters"
  d3 '{"applied":[],"pending":[{"filename":"0423_x.sql"}]}' 1 "pending is not applied"
  d3 '{"applied":["0423_x.sql"]}' 1 "a string entry is not an object row"
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"
  files prisma/migrations/0423_x/migration.sql:added prisma/migrations/0424_y/migration.sql:added
  echo '{"applied":[{"filename":"0423_x"}]}' > "$FXD/st-body"; run
  [ "$STATE" = WAIT_CI ] && [[ $WHY == "HELD_MIGRATION 0424_y: not in the production migration ledger" ]] \
    || no "D3 one applied, one missing: held naming only the missing one (why '$WHY')"

  # ---- D4 probe answer ----
  d4() { # d4 <want READY|WAIT_CI> <label> — st-* already set
    echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"
    files prisma/migrations/0423_x/migration.sql:added; run
    [ "$STATE" = "$1" ] || no "D4 $2: want $1, got $STATE ($WHY)"; }
  reset; echo '{"applied":[{"filename":"0423_x"}]}' > "$FXD/st-body"; d4 READY "200 with the name"
  reset; d4 WAIT_CI "200 without the name"
  for c in 500 503 401 403 404; do reset; echo "$c" > "$FXD/st-code"; d4 WAIT_CI "HTTP $c"
    [[ $WHY == *unreadable* ]] || no "D4 HTTP $c must say unreadable ($WHY)"; done
  reset; : > "$FXD/st-timeout"; d4 WAIT_CI "a timeout (000)"; [[ $WHY == *"HTTP 000"* ]] || no "D4 a timeout names HTTP 000 ($WHY)"
  for b in 'not json' '{"applied":null}' '[]'; do reset; echo "$b" > "$FXD/st-body"; d4 WAIT_CI "body $b"
    [[ $WHY == *unreadable* ]] || no "D4 body $b must say unreadable ($WHY)"; done
  reset; echo '{"error":"partial","applied":[{"filename":"0001_old"}]}' > "$FXD/st-body"; d4 WAIT_CI "an error next to a list without the name"
  reset; printf 'MIGRATION_TOKEN=tok-fixture-1\n' > "$A/h/env/mgfy.env"; d4 WAIT_CI "base unset"
  [[ $WHY == *"not configured"* ]] && [ "$(n "$FXD/status.log")" = 0 ] || no "D4 base unset: not configured, no call ($WHY)"
  reset; printf 'DATA_LANE_APP_BASE=http://app.test\n' > "$A/h/env/mgfy.env"; d4 WAIT_CI "token unset"
  [[ $WHY == *"not configured"* ]] || no "D4 token unset: not configured ($WHY)"
  printf 'DATA_LANE_APP_BASE=http://app.test\nMIGRATION_TOKEN=tok-fixture-1\n' > "$A/h/env/mgfy.env"
  # the token is never on curl's argv
  grep -q 'tok-fixture-1' "$FXD/curl.log" 2>/dev/null && no "D4 the token must not be on argv"

  # ---- D5 settings row ----
  reset; files prisma/migrations/0423_x/migration.sql:added; run
  [ "$STATE" = READY ] && [ "$(n "$FXD/files.log")" = 0 ] && [ "$(n "$FXD/status.log")" = 0 ] || no "D5 no row: not gated, no read"
  reset; : > "$FXD/set/.down"; files prisma/migrations/0423_x/migration.sql:added; run
  [ "$STATE" = READY ] && grep -q 'unreadable this tick' "$FXD/log" || no "D5 an unreadable row: not gated this tick, one log line"
  reset; echo '   ' > "$FXD/set/mc_migration_hold.globs.mgfy"; files prisma/migrations/0423_x/migration.sql:added; run
  [ "$STATE" = READY ] && [ "$(n "$FXD/files.log")" = 0 ] || no "D5 a whitespace-only row: gate off"
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.other"; files prisma/migrations/0423_x/migration.sql:added; run
  [ "$STATE" = READY ] && [ "$(n "$FXD/files.log")" = 0 ] || no "D5 a row for project other does not gate mgfy"
  reset; echo 'supabase/migrations/*.sql prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"
  files prisma/migrations/0423_x/migration.sql:added; run
  [ "$STATE" = WAIT_CI ] || no "D5 the second of two globs matches"

  # ---- D6 cache ----
  reset; FP=fp0000000001
  MMH_NOW=1000; mmh_cache_put k1 "$H1" "$FP" missing 0423_x "not in the ledger"
  MMH_NOW=1010; mmh_cache_get k1 "$H1" "$FP" 300 && [ "$MMH_VERDICT" = missing ] || no "D6 a hit at age 10 with TTL 300"
  mmh_cache_get k1 "$H2" "$FP" 300 && no "D6 another head is a miss"
  MMH_NOW=1301; mmh_cache_get k1 "$H1" "$FP" 300 && no "D6 age 301 is a miss"
  MMH_NOW=1010; mmh_cache_get k1 "$H1" fp0000000002 300 && no "D6 changed globs are a miss"
  printf '%s\t1000\t%s\tmissing\n' "$H1" "$FP" > "$(_mmh_cache_file k1)"; mmh_cache_get k1 "$H1" "$FP" 300 && no "D6 a short line is a miss"
  printf '%s\t1000\t%s\tmissing\ta\tb\tc\n' "$H1" "$FP" > "$(_mmh_cache_file k1)"; mmh_cache_get k1 "$H1" "$FP" 300 && no "D6 a long line is a miss"
  mmh_cache_get k-none "$H1" "$FP" 300 && no "D6 no file is a miss"
  unset MMH_NOW

  # ---- R1 round trip ----
  reset
  for v in applied none missing unreadable lane; do
    mmh_cache_put "r1-$v" "$H1" fpr1 "$v" "0423_x 0424_y" "detail with spaces	and a tab
and a newline"
    mmh_cache_get "r1-$v" "$H1" fpr1 300 && [ "$MMH_VERDICT" = "$v" ] && [ "$MMH_NAMES" = "0423_x 0424_y" ] \
      && [ "$MMH_DETAIL" = "detail with spaces and a tab and a newline" ] || no "R1 $v round trip (got $MMH_VERDICT/$MMH_NAMES/$MMH_DETAIL)"
  done
  mmh_cache_put r1-empty "$H1" fpr1 none "" ""
  mmh_cache_get r1-empty "$H1" fpr1 300 && [ -z "$MMH_NAMES" ] && [ -z "$MMH_DETAIL" ] || no "R1 empty names and detail round trip"
  # retention: a file older than 7 days goes on the next put
  touch -d '10 days ago' "$(_mmh_cache_file r1-applied)"; mmh_cache_put r1-new "$H1" fpr1 none - -
  [ -e "$(_mmh_cache_file r1-applied)" ] && no "R1 a cache file older than 7 days is pruned"
  [ -e "$(_mmh_cache_file r1-new)" ] || no "R1 the new file stays"

  # ---- X1-X3 exit paths ----
  # X1 not READY: nothing read, state as it was
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"; files prisma/migrations/0423_x/migration.sql:added
  STATE=WAIT_CI; WHY="checks pending"; P=mgfy; SLUG=$SLUG; NUM=31; KEY="$SLUG#31"; HEAD=$H1; mc_mig_hold
  [ "$STATE" = WAIT_CI ] && [ "$WHY" = "checks pending" ] && [ "$(n "$FXD/files.log")" = 0 ] || no "X1 a row that is not READY is left alone"
  # X2 applied: READY, one cache file, one log line, one files read, one probe
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"; files prisma/migrations/0423_x/migration.sql:added
  echo '{"applied":[{"filename":"0423_x"}]}' > "$FXD/st-body"; run
  [ "$STATE" = READY ] && [ "$(n "$FXD/files.log")" = 1 ] && [ "$(n "$FXD/status.log")" = 1 ] && [ -s "$(_mmh_cache_file "$SLUG#31")" ] \
    && [ "$(grep -c '0423_x applied in production' "$FXD/log")" = 1 ] && [ "$(n "$FXD/alerts")" = 0 ] && [ "$(n "$FXD/trace")" = 0 ] \
    || no "X2 applied: READY, 1 read, 1 probe, 1 cache file, 1 log line, no comment, no alert"
  # X3 held: WAIT_CI, one comment, one attempts line, one alert
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"; files prisma/migrations/0423_x/migration.sql:added; run
  [ "$STATE" = WAIT_CI ] && [ "$(n "$FXD/trace")" = 1 ] && [ "$(n "$FXD/attempts")" = 1 ] && [ "$(n "$FXD/alerts")" = 1 ] \
    && grep -q "	migration	0423_x not applied in production .*Apply step: apply them" "$FXD/trace" \
    && [ "$(cat "$FXD/attempts")" = "mighold $SLUG#31 $H1" ] || no "X3 held: 1 comment naming the apply step, 1 mark, 1 alert"
  # X4 a failed files read: held unreadable, not cached
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"; : > "$FXD/files-fail"; run
  [ "$STATE" = WAIT_CI ] && [[ $WHY == *"files read failed"*"HTTP 502"* ]] && [ ! -e "$(_mmh_cache_file "$SLUG#31")" ] \
    || no "X4 a failed files read: held, names HTTP 502, not cached ($WHY)"

  # ---- L1 apply lane ----
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"; echo project-6-d7-drain > "$FXD/set/mc_migration_hold.apply_lane.mgfy"
  files prisma/migrations/0423_x/migration.sql:added; run
  [ "$STATE" = WAIT_CI ] && [[ $WHY == "HELD_MIGRATION 0423_x: left to the project-6-d7-drain lane"* ]] && [ "$(n "$FXD/status.log")" = 0 ] \
    && [ "$(n "$FXD/trace")" = 0 ] && [ "$(n "$FXD/alerts")" = 0 ] || no "L1 apply lane: held for the lane, no probe/comment/alert ($WHY)"
  # L1b an apply lane and no migration file: READY
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"; echo project-6-d7-drain > "$FXD/set/mc_migration_hold.apply_lane.mgfy"
  files src/a.ts:added; run
  [ "$STATE" = READY ] || no "L1b an apply lane without a migration file: READY"
  # L1c an invalid lane name is ignored: the conductor probes
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"; echo 'Bad Lane!' > "$FXD/set/mc_migration_hold.apply_lane.mgfy"
  files prisma/migrations/0423_x/migration.sql:added; run
  [ "$(n "$FXD/status.log")" = 1 ] && grep -q 'is not a lane name' "$FXD/log" || no "L1c an invalid lane name is ignored and the conductor probes"

  # ---- A1/A2 alert dedupe; observe mode ----
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"; files prisma/migrations/0423_x/migration.sql:added
  run; run
  [ "$(n "$FXD/alerts")" = 1 ] && [ "$(n "$FXD/status.log")" = 1 ] || no "A1 two runs on one head: 1 alert, 1 probe (alerts $(n "$FXD/alerts"))"
  run "$SLUG#31" "$H2"
  [ "$(n "$FXD/alerts")" = 2 ] || no "A2 a new head: 1 more alert (alerts $(n "$FXD/alerts"))"
  reset; echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"; files prisma/migrations/0423_x/migration.sql:added
  ACTIONS_X=0 run
  [ "$STATE" = WAIT_CI ] && [ "$(n "$FXD/alerts")" = 0 ] && [ "$(n "$FXD/attempts")" = 0 ] && grep -q 'WOULD alert HELD_MIGRATION' "$FXD/log" \
    || no "A3 observe mode: held, a WOULD line, no alert, no mark"

  echo "part A: $F failed"
  exit "$F"
)
PA=$?; FAIL=$((FAIL + PA))

# ============================================================================
# Part B — the WHOLE bin/merge-conductor.sh in a scratch tree.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
C="$T/w"; CH="$C/h"; FX="$C/fx"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
( cd "$DIR" && for s in bin/lib/autoenqueue.sh bin/lib/mc-hold-comment.sh bin/lib/gh-repo-token.sh; do scratch_install_closure "$s" "$CH" >/dev/null || exit 1; done ) || exit 1
mkfakecurl "$C/fakebin" "$FX"
# The ticket fences answer "no hold" (their real reads are pinned in their own
# suites; this fixture serves no ticket thread), as in the 3456 fixture.
cat > "$CH/bin/lib/ticket-ownership.sh" <<'EOF2'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
EOF2
printf 'pdg_hold() { return 1; }\n' > "$CH/bin/lib/pr-dep-gate.sh"
# install_frag — the fragment and its lib, as the closure of the fragment.
install_frag() { ( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-7785-migration-hold.sh "$CH" >/dev/null ); }
install_frag || exit 1
printf 'mgfy %s - - 2 box-m\n' "$SLUG" > "$CH/fleet.conf"
: > "$CH/env/global.env"
printf 'DATA_LANE_APP_BASE=http://app.test\nMIGRATION_TOKEN=tok-fixture-1\n' > "$CH/env/mgfy.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$CH/bin/$s.sh"; chmod +x "$CH/bin/$s.sh"; done
REC="$CH/builds/pool-mgfy-MG-31-202609120001"; mkdir -p "$REC"
U="https://github.com/$SLUG/pull"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
# FX/head: the PR's head (absent: H1). FX/files.json: pulls/31/files.
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
HD=\$(cat "$FX/head" 2>/dev/null || echo "$H1")
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-09-29T10:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/31/comments -f body=@mergifyio queue"*) printf '%s\n' "\$*" >> "$FX/queue-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"issues/31/labels"*) printf '%s\n' "\$*" >> "$FX/label-posts.txt"; restpr --raw 200 '[]' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$FX/merges.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$FX/merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$FX/comment-posts.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/$SLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/$SLUG/pulls/31/files"*) printf '%s\n' "\$*" >> "$FX/files-reads.txt"; restpr --raw 200 "\$(cat "$FX/files.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*) restpr OPEN "\$HD" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) jq -c --arg h "\$HD" '.[0].headRefOid = \$h' "$C/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/gh"
cat > "$C/list.json" <<J
[{"number":31,"url":"$U/31","headRefOid":"$H1","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
printf '#!/bin/bash\nexit 0\n' > "$C/fakebin/flock"; chmod +x "$C/fakebin/flock"
touch "$CH/flags/merge-conductor-actions" "$CH/flags/merge-conductor-merge"
TR="$C/trace"
# fresh <head> — a clean slate: state, logs, fixture answers and the build record.
fresh() {
  scratch_rm "$CH/state"; scratch_rm "$FX"; mkdir -p "$CH/state" "$FX/set"
  : > "$CH/logs/merge-conductor.log"; : > "$CH/logs/ALERTS.log"; : > "$TR"
  local h="${1:-$H1}"; echo "$h" > "$FX/head"
  echo "PR_CREATED $U/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$h" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
}
# tick [env...] — one conductor tick; state carries over until fresh.
tick() {
  ( cd "$C" && env PATH="$C/fakebin:$PATH" HARNESS="$CH" HARNESS_ENV_DIR= HARNESS_SECRET=fixture-secret JOBS_URL=http://worker.test JOBS_RETRIES=0 GH_TOKEN=pat-fixture \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_HOLD_COMMENT_TRACE="$TR" "$@" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>"$C/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$C/tick.err"; }
}
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
clog() { grep -E '#31' "$CH/logs/merge-conductor.log" | tail -"${1:-6}"; }
crow() { awk -F'\t' -v k="$SLUG#31" '$1==k' "$CH/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
globs() { echo "${1:-prisma/migrations/*/migration.sql}" > "$FX/set/mc_migration_hold.globs.mgfy"; }
mig_files() { echo '[{"filename":"prisma/migrations/0423_x/migration.sql","status":"added"},{"filename":"src/a.ts","status":"modified"}]' > "$FX/files.json"; }
alerts() { grep -c 'HELD_MIGRATION' "$CH/logs/ALERTS.log" 2>/dev/null || true; }

# M1 — not applied: no queue POST, no label POST, WAIT_CI HELD_MIGRATION, 1 comment, 1 alert.
fresh; globs; mig_files; echo '{"applied":[]}' > "$FX/st-body"; tick
[ "$(n "$FX/queue-posts.txt")" = 0 ] && [ "$(n "$FX/label-posts.txt")" = 0 ] && [ "$(n "$FX/merges.txt")" = 0 ] \
  && ok || bad "M1 a held PR gets no @mergifyio queue, no label, no merge (queue $(n "$FX/queue-posts.txt"), labels $(n "$FX/label-posts.txt"); log: $(clog))"
ROW=$(crow)
[ "$(cut -f2 <<<"$ROW")" = WAIT_CI ] && grep -q $'\tHELD_MIGRATION 0423_x: not in the production migration ledger' <<<"$ROW" && ok \
  || bad "M1 the stored row is WAIT_CI HELD_MIGRATION 0423_x (row: $ROW)"
[ "$(grep -c "	migration	" "$TR")" = 1 ] && grep -q "^$SLUG#31	$H1	migration	0423_x not applied in production.*Apply step: apply them to production ahead of the merge" "$TR" && ok \
  || bad "M1 exactly one migration hold-comment line naming 0423_x and the apply step (trace: $(cat "$TR"))"
# The body rides a temp file (-F body=@file), so its text is checked in the trace above.
[ "$(n "$FX/comment-posts.txt")" = 1 ] && grep -q 'issues/31/comments' "$FX/comment-posts.txt" && ok \
  || bad "M1 exactly one comment POST reaches GitHub (posts: $(cat "$FX/comment-posts.txt" 2>/dev/null))"
[ "$(alerts)" = 1 ] && ok || bad "M1 exactly one HELD_MIGRATION alert (ALERTS: $(cat "$CH/logs/ALERTS.log"))"
grep -q "#31 HELD_MIGRATION 0423_x on ${H1:0:8}" "$CH/logs/merge-conductor.log" && ok || bad "M1 the held log line (log: $(clog))"
# R2 — the stored row has no tab or newline inside the reason: the row has the same field count as a READY one.
NF_HELD=$(awk -F'\t' '{print NF}' <<<"$ROW")

# M2 — applied: enqueued as today (one @mergifyio queue POST), the applied log line.
fresh; globs; mig_files; echo '{"applied":[{"filename":"0423_x","checksum":"x"}]}' > "$FX/st-body"; tick
[ "$(n "$FX/queue-posts.txt")" = 1 ] && ok || bad "M2 an applied migration is enqueued (queue $(n "$FX/queue-posts.txt"); log: $(clog))"
grep -q "migration hold: 0423_x applied in production on ${H1:0:8} (probed)" "$CH/logs/merge-conductor.log" && ok || bad "M2 the applied log line (log: $(clog))"
[ "$(alerts)" = 0 ] && [ "$(grep -c "	migration	" "$TR")" = 0 ] && ok || bad "M2 applied: no alert, no comment"
NF_READY=$(awk -F'\t' '{print NF}' <<<"$(crow)")
[ -n "$NF_HELD" ] && [ "$NF_HELD" = "$NF_READY" ] && ok || bad "R2 the held row has the READY row's field count ($NF_HELD vs $NF_READY)"

# M3 — unreadable: 500, 503, 401, a timeout: held, never enqueued, reason says unreadable.
for c in 500 503 401 timeout; do
  fresh; globs; mig_files
  if [ "$c" = timeout ]; then : > "$FX/st-timeout"; else echo "$c" > "$FX/st-code"; fi
  tick
  [ "$(n "$FX/queue-posts.txt")" = 0 ] && [ "$(cut -f2 <<<"$(crow)")" = WAIT_CI ] && grep -q 'HELD_MIGRATION 0423_x: probe unreadable' <<<"$(crow)" && ok \
    || bad "M3 probe $c: held unreadable, not enqueued (row: $(crow); queue $(n "$FX/queue-posts.txt"))"
done

# M4 — no migration file: no status call, enqueued.
fresh; globs; echo '[{"filename":"src/a.ts","status":"added"}]' > "$FX/files.json"; tick
[ "$(n "$FX/status.log")" = 0 ] && [ "$(n "$FX/queue-posts.txt")" = 1 ] && ok \
  || bad "M4 no migration file: 0 probes, enqueued (probes $(n "$FX/status.log"), queue $(n "$FX/queue-posts.txt"))"

# M5 / Z1 — no globs row: no gate files read, no probe, enqueued. The files-read
# count is compared with the same tick when the fragment is absent.
scratch_rm "$CH/bin/merge-conductor.d"
fresh; mig_files; tick
BASE_READS=$(n "$FX/files-reads.txt"); BASE_Q=$(n "$FX/queue-posts.txt")
# RED — the M1 fixture with the fragment absent: the PR is enqueued. This is the
# conductor before BH-7785, and the reason M1 is not vacuous.
fresh; globs; mig_files; tick
[ "$(n "$FX/queue-posts.txt")" = 1 ] && ok || bad "RED without the fragment the M1 PR is enqueued (queue $(n "$FX/queue-posts.txt"))"
install_frag || exit 1
fresh; mig_files; tick
[ "$(n "$FX/files-reads.txt")" = "$BASE_READS" ] && [ "$(n "$FX/status.log")" = 0 ] && [ "$(n "$FX/queue-posts.txt")" = 1 ] && [ "$BASE_Q" = 1 ] \
  && [ ! -d "$CH/state/merge-conductor/migration-hold" ] && ok \
  || bad "M5 no row: no extra files read ($(n "$FX/files-reads.txt") vs $BASE_READS), 0 probes ($(n "$FX/status.log")), enqueued"
fresh; globs 'prisma/migrations/*/migration.sql' ; mv "$FX/set/mc_migration_hold.globs.mgfy" "$FX/set/mc_migration_hold.globs.other"; mig_files; tick
[ "$(n "$FX/status.log")" = 0 ] && [ "$(n "$FX/queue-posts.txt")" = 1 ] && ok || bad "M5 a row for project other: mgfy not probed"

# M6 — two ticks on one head inside cache_s: one probe, both held.
# The cache clock is pinned (MMH_NOW), never the wall clock.
fresh; globs; mig_files; tick MMH_NOW=2000000000
S1=$(cut -f2 <<<"$(crow)"); tick MMH_NOW=2000000010
[ "$(n "$FX/status.log")" = 1 ] && [ "$S1" = WAIT_CI ] && [ "$(cut -f2 <<<"$(crow)")" = WAIT_CI ] && ok \
  || bad "M6 two ticks on one head: 1 probe, both held (probes $(n "$FX/status.log"), $S1 / $(cut -f2 <<<"$(crow)"))"
grep -q "HELD_MIGRATION 0423_x on ${H1:0:8}: .*(cached)" "$CH/logs/merge-conductor.log" && ok || bad "M6 the second tick says cached (log: $(clog))"
[ "$(alerts)" = 1 ] && ok || bad "A1 whole tick: two ticks on one head send one alert ($(alerts))"

# M7 — re-check: the ledger now answers applied and the cache aged out: enqueued.
echo '{"applied":[{"filename":"0423_x"}]}' > "$FX/st-body"
tick MMH_NOW=2000000400
[ "$(n "$FX/queue-posts.txt")" = 1 ] && [ "$(n "$FX/status.log")" = 2 ] && ok \
  || bad "M7 after the apply the next tick past the cache window enqueues (queue $(n "$FX/queue-posts.txt"), probes $(n "$FX/status.log"); log: $(clog))"

# A2 — a new head on a held PR: one more alert.
fresh; globs; mig_files; tick
echo "$H2" > "$FX/head"; echo "$H2" > "$REC/reviewed-sha"; tick
[ "$(alerts)" = 2 ] && ok || bad "A2 whole tick: a new head sends one more alert ($(alerts); log: $(clog))"

# L1 — apply lane: held for the lane, no probe, no comment, no alert, no enqueue.
fresh; globs; mig_files; echo project-6-d7-drain > "$FX/set/mc_migration_hold.apply_lane.mgfy"; tick
[ "$(n "$FX/status.log")" = 0 ] && [ "$(grep -c "	migration	" "$TR")" = 0 ] && [ "$(alerts)" = 0 ] && [ "$(n "$FX/queue-posts.txt")" = 0 ] \
  && grep -q 'HELD_MIGRATION 0423_x: left to the project-6-d7-drain lane' <<<"$(crow)" && ok \
  || bad "L1 apply lane (probes $(n "$FX/status.log"), alerts $(alerts), queue $(n "$FX/queue-posts.txt"), row $(crow))"

# V1 — every curl went to a .test host.
[ -s "$FX.curl-all.log" ] && ok || bad "V1 the fake curl saw no call at all"
OUT=$(awk '{print $2}' "$FX.curl-all.log" 2>/dev/null | grep -vE '^https?://[a-z0-9.-]+\.test(/|$)' || true)
[ -z "$OUT" ] && ok || bad "V1 a curl left the fixture hosts: $OUT"

echo "merge-conductor-migration-hold: part B $PASS passed; $FAIL failed in all (part A counted above)"
[ "$FAIL" -eq 0 ]
