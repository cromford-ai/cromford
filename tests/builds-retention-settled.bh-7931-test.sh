#!/bin/bash
# tests/builds-retention-settled.bh-7931-test.sh — BH-7931: rule 2 of
# bin/builds-retention.sh (`settled`), the four new kept reasons, the drain
# alert, and the ticket-state seam (bin/lib/ticket-state.sh). Drives the real
# script in a scratch tree. The clock is BUILDS_RETENTION_NOW, the settings come
# from the settings-cache seam, and every ticket state comes from the
# BUILDS_RETENTION_TICKET_STATE_FILE fake. `curl` and `gh` PATH shims log every
# call, and S10 asserts the log is empty (0 vendor calls).
#
#   S1   a superseded unmerged group at 32 d moves (real run)
#   S2   the same at 29 d: settled-young; S2b a late file 20 d old: settled-young;
#        S2c a name stamp 29 d old with every mtime 40 d old: settled-young
#   S3   an open ticket: settled-open, two groups of one ticket cost one read;
#        S3b a closed ticket: moves
#   S4   unreadable ticket and no job.json: tracker-unreadable, errors=0;
#        S4b rate limited: no read after the first, every later group unreadable
#   S5   all-terminal moves; S5b near misses kept; S5c SUPERSEDED marker moves;
#        S5d ticket_id `-` and S5e another project's id supersede nothing
#   S6   a merged group follows rule 1; S6b unswept; S6c live lock, live claim,
#        remote-json
#   S7   settled_window_days=0: rule 2 off, `not-merged` as before
#   S8   tks_state against the seam file, every answer
#   S9   tracker_reads_max=1: tracker_reads=1, tracker-budget=2
#   S10  no settings: dry=1 settled=30(default), nothing moved; 0 vendor calls
#   S11  index rows = moved dirs, 1:1, with result1; ba_dirs finds a moved dir;
#        a second run moves 0
#   S12  the drain alert: two real capped runs within 48 h, once; resolve
#   S13  tks_state through the real tracker adapters, against local fakes
#   V    1,000 old superseded groups + 1,000 young: would_move=1000, the ticket
#        id map reads no job.json with jq
#
# Run from anywhere (exit 0 = pass). Needs GNU find, touch, date, flock, jq.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
find /dev/null -maxdepth 0 -printf '' 2>/dev/null || { echo "SKIP: find is not GNU find"; exit 0; }

NOW=1792000000            # 2026-10-14
DAY=86400
ts() { date -u -d "@$1" "+$2"; }
export BUILDS_RETENTION_NOW="$NOW" LANE_GATE_NOW="$NOW"
export HARNESS_SECRET=fixture-harness-secret JOBS_URL="" JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=box-fixture

# Vendor shims: any curl or gh call is logged, then fails.
mkdir -p "$T/vshim"
: > "$T/vendor.log"
for v in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "%s"\nexit 7\n' "$v" "$T/vendor.log" > "$T/vshim/$v"
  chmod +x "$T/vshim/$v"
done
export PATH="$T/vshim:$PATH"

TKS="$T/tickets.tsv"
export BUILDS_RETENTION_TICKET_STATE_FILE="$TKS"

H="$T/h"
install_tree() {
  scratch_rm "$H"
  mkdir -p "$H/builds" "$H/logs" "$H/locks" "$H/state" "$H/flags" "$H/env"
  local s
  for s in bin/builds-retention.sh bin/lib/ticket-state.sh bin/jobs-client.sh bin/lane-alert.sh bin/fleet-conf.sh bin/internal-token-for.sh; do
    ( cd "$DIR" && scratch_install_closure "$s" "$H" ) >/dev/null || { echo "setup: could not install $s"; exit 1; }
  done
  cat > "$H/fleet.conf" <<'CONF'
alpha-os  Org/alpha  https://alpha.example  -           2  box-alpha
beta-os   Org/beta   https://beta.example   -           3  box-beta
gamma-os  Org/gamma  https://gamma.example  /api/board  4  box-gamma
CONF
  : > "$TKS"
}
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
run() { "$H/bin/builds-retention.sh" "$@" > "$T/run.out" 2>&1; RC=$?; }
lastlog() { grep ' run ' "$H/logs/builds-retention.log" 2>/dev/null | tail -1; }
field() { lastlog | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
settings() { jq -nc --argjson fa "$NOW" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$H/state/settings-cache.json"; }
nalerts() { local n; n=$(grep -c "$1" "$H/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
tk() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TKS"; }
# expect <label> <field=value>... — every named run-line field has that value.
expect() {
  local lbl="$1" kv miss=""; shift
  for kv in "$@"; do [ "$(field "${kv%%=*}")" = "${kv#*=}" ] || miss="$miss ${kv%%=*}=$(field "${kv%%=*}")(want ${kv#*=})"; done
  [ -z "$miss" ] && ok "$lbl" || bad "$lbl:$miss :: $(lastlog)"
}

# mk <name> <age-days> <ticket_id|none> <result1|-> [marker...] — one build dir,
# its files and the dir itself at now - age days. `none` writes no job.json,
# `-` writes no RESULT.
mk() {
  local n="$1" age="$2" tid="$3" r="$4" d="$H/builds/$1" m e
  shift 4
  e=$(( NOW - age * DAY ))
  mkdir -p "$d"
  [ "$r" = - ] || printf '%s\n' "$r" > "$d/RESULT"
  [ "$tid" = none ] || printf '{\n  "project": "x",\n  "ticket_id": "%s",\n  "key": "x"\n}\n' "$tid" > "$d/job.json"
  for m in "$@"; do : > "$d/$m"; done
  touch -c -d "@$e" "$d"/* "$d" 2>/dev/null
}
stamp() { ts $(( NOW - $1 * DAY )) %Y%m%d%H%M; }
S20=$(stamp 20); S29=$(stamp 29); S32=$(stamp 32); S40=$(stamp 40)
MERGED="PR_MERGED https://github.com/o/alpha/pull/1"
here() { [ -d "$H/builds/$1" ]; }
gone() { [ ! -e "$H/builds/$1" ] && [ -n "$(find "$H/builds-archive" -mindepth 2 -maxdepth 2 -name "$1" -type d 2>/dev/null)" ]; }

# ============================================================================
echo "Scenario S: the settled rule (S1-S6, S10, S11)"
install_tree
mk "alpha-os-SA-1-$S32" 32 101 "PLAN_BLOCKED x" COMMENTED              # S1 superseded by SA-2: moves
mk "alpha-os-SA-2-$S20" 20 101 "PLAN_BLOCKED y" COMMENTED              #    settled-young
mk "alpha-os-SB-1-$S29" 29 102 "PLAN_BLOCKED x" COMMENTED              # S2 superseded, 29 d: settled-young
mk "alpha-os-SB-2-$S20" 20 102 "PLAN_BLOCKED y" COMMENTED              #    settled-young
mk "alpha-os-SC-1-$S32" 32 103 "PLAN_BLOCKED x" COMMENTED              # S2b superseded, late file: settled-young
printf 'late\n' > "$H/builds/alpha-os-SC-1-$S32/review.md"; touch -d "@$(( NOW - 20 * DAY ))" "$H/builds/alpha-os-SC-1-$S32/review.md"
touch -d "@$(( NOW - 32 * DAY ))" "$H/builds/alpha-os-SC-1-$S32"
mk "alpha-os-SC-2-$S20" 20 103 "PLAN_BLOCKED y" COMMENTED              #    settled-young
mk "alpha-os-SU-1-$S29" 40 118 "PLAN_BLOCKED x" COMMENTED              # S2c stamp 29 d, every mtime 40 d: settled-young
mk "alpha-os-SU-2-$S20" 20 118 "PLAN_BLOCKED y" COMMENTED              #    settled-young
mk "alpha-os-SD-1-$S40" 40 104 "PLAN_BLOCKED x" COMMENTED              # S3 open, one read for two groups
mk "alpha-os-SD-2-$S40" 40 104 "REVIEW_BLOCKED x" COMMENTED
tk alpha-os 104 open
mk "alpha-os-SE-1-$S40" 40 105 "PLAN_BLOCKED x" COMMENTED              # S3b closed: moves
tk alpha-os 105 closed
mk "alpha-os-SF-1-$S40" 40 106 "PLAN_BLOCKED x" COMMENTED              # S4 unreadable
tk alpha-os 106 unreadable
mk "alpha-os-TK-1-$S40" 40 none "PLAN_BLOCKED x" COMMENTED             # S4 no job.json: unreadable, no read
mk "alpha-os-SH-1-$(stamp 50)" 50 107 "FAILED x" COMMENTED             # S5 all terminal, open: moves
mk "alpha-os-SH-1-$(stamp 45)" 45 107 "BUILD_DEFERRED y"
mk "pool-alpha-os-SH-1-$(stamp 42)" 42 107 "CLOSED z" COMMENTED
mk "alpha-os-SH-1-$S40" 40 107 "NEEDS_HUMAN_VERDICT w" COMMENTED
tk alpha-os 107 open
mk "alpha-os-SI-1-$(stamp 45)" 45 108 "FAILED x" COMMENTED             # S5b one PR_CREATED among FAILED
mk "alpha-os-SI-1-$S40" 40 108 "PR_CREATED https://github.com/o/alpha/pull/8" COMMENTED
tk alpha-os 108 open
mk "alpha-os-SJ-1-$S40" 40 109 "PLAN_FAILED x" COMMENTED               # S5b the word not at the start
tk alpha-os 109 open
mk "alpha-os-SK-1-$(stamp 45)" 45 110 "FAILED x" COMMENTED             # S5b one dir with no RESULT
mk "alpha-os-SK-1-$S40" 40 110 -
tk alpha-os 110 open
mk "alpha-os-SL-1-$S40" 40 111 "PR_CREATED https://github.com/o/alpha/pull/11" SUPERSEDED  # S5c marker: moves
tk alpha-os 111 open
mk "alpha-os-SM-1-$S40" 40 - "PLAN_BLOCKED x" COMMENTED                # S5d `-` supersedes nothing
mk "alpha-os-SM-2-$S20" 20 - "PLAN_BLOCKED y" COMMENTED
mk "alpha-os-TK-1-$S40" 40 112 "PLAN_BLOCKED x" COMMENTED              # S5e beta's 112 supersedes nothing
mk "beta-os-SN-1-$S20" 20 112 "PLAN_BLOCKED y" COMMENTED
tk alpha-os 112 open
mk "alpha-os-SP-1-$S20" 20 113 "$MERGED" COMMENTED                     # S6 merged, 20 d: rule 1 moves
mk "alpha-os-SQ-1-$S40" 40 114 "PLAN_BLOCKED x"                        # S6b unswept
tk alpha-os 114 closed
mk "alpha-os-SR-1-$S40" 40 115 "PLAN_BLOCKED x" COMMENTED              # S6c live lock
tk alpha-os 115 closed
mk "alpha-os-SS-1-$S40" 40 116 "PLAN_BLOCKED x" COMMENTED              # S6c remote-json
mkdir -p "$H/state/remote-results/alpha-os"; echo '{}' > "$H/state/remote-results/alpha-os/SS-1.json"
tk alpha-os 116 closed
mk "alpha-os-ST-1-$S40" 40 117 "PLAN_BLOCKED x" COMMENTED              # S6c live claim
mkdir -p "$H/state/claims/alpha-os"; : > "$H/state/claims/alpha-os/ST-1"
tk alpha-os 117 closed
MOVES=$(printf '%s\n' "alpha-os-SA-1-$S32" "alpha-os-SE-1-$S40" "alpha-os-SH-1-$(stamp 50)" "alpha-os-SH-1-$(stamp 45)" \
  "pool-alpha-os-SH-1-$(stamp 42)" "alpha-os-SH-1-$S40" "alpha-os-SL-1-$S40" "alpha-os-SP-1-$S20" | sort)
cp -a "$H/builds" "$T/before"
exec 9>"$H/locks/build-key-alpha-os-SR-1.lock"; flock 9

# S10 no settings: the defaults, dry
run
[ "$RC" = 0 ] && ok "S10 rc 0" || bad "S10 rc=$RC $(cat "$T/run.out")"
expect "S10 no settings: dry=1 settled=30(default) moved=0 would_move=8" dry=1 'settled=30(default)' moved=0 would_move=8
[ ! -e "$H/builds-archive/index.tsv" ] && diff -r "$T/before" "$H/builds" >/dev/null \
  && ok "S10 the dry run moved nothing and wrote no index" || bad "S10 something moved"
got=$(cut -f1 "$H/logs/builds-retention-dryrun.txt" | sort)
[ "$got" = "$MOVES" ] && ok "S10 the dry list is exactly the eligible dirs" || bad "S10 list [$got] want [$MOVES]"

# The real run.
settings '{"builds_retention.dry_run":"0"}'
run
expect "S1-S6 real run: moved=8 eligible_groups=5 errors=0" dry=0 moved=8 eligible_groups=5 errors=0 capped=0
expect "S2 kept settled-young=9" settled-young=9
expect "S3 kept settled-open=6" settled-open=6
expect "S4 kept tracker-unreadable=3, errors=0" tracker-unreadable=3 errors=0
expect "S6b/S6c kept unswept=1 live=2 remote-json=1" unswept=1 live=2 remote-json=1
expect "S6 rule 1 counters unchanged: not-merged=0 young=0 tracker-budget=0" not-merged=0 young=0 tracker-budget=0
expect "S3 one read per ticket: tracker_reads=7 (104 read once for SD-1 and SD-2)" tracker_reads=7
gone "alpha-os-SA-1-$S32" && ok "S1 the superseded group at 32 d moved" || bad "S1 SA-1 not moved"
here "alpha-os-SB-1-$S29" && here "alpha-os-SC-1-$S32" && here "alpha-os-SU-1-$S29" \
  && ok "S2/S2b/S2c the 29 d group, the late-file group and the 29 d name stamp stay" || bad "S2 moved"
here "alpha-os-SD-1-$S40" && here "alpha-os-SD-2-$S40" && ok "S3 the open ticket's groups stay" || bad "S3 moved"
gone "alpha-os-SE-1-$S40" && ok "S3b the closed ticket's group moved" || bad "S3b SE-1 not moved"
here "alpha-os-SF-1-$S40" && here "alpha-os-TK-1-$S40" && ok "S4 unreadable groups stay" || bad "S4 moved"
gone "alpha-os-SH-1-$S40" && gone "pool-alpha-os-SH-1-$(stamp 42)" && ok "S5 the all-terminal group moved whole (open ticket)" || bad "S5 SH-1"
here "alpha-os-SI-1-$S40" && here "alpha-os-SJ-1-$S40" && here "alpha-os-SK-1-$S40" && ok "S5b near misses stay" || bad "S5b moved"
gone "alpha-os-SL-1-$S40" && ok "S5c a SUPERSEDED marker moves (open ticket)" || bad "S5c SL-1"
here "alpha-os-SM-1-$S40" && here "alpha-os-TK-1-$S40" && ok "S5d/S5e '-' and another project's id supersede nothing" || bad "S5d/e moved"
gone "alpha-os-SP-1-$S20" && ok "S6 the merged group at 20 d moved under rule 1" || bad "S6 SP-1"
here "alpha-os-SQ-1-$S40" && here "alpha-os-SR-1-$S40" && here "alpha-os-SS-1-$S40" && here "alpha-os-ST-1-$S40" \
  && ok "S6b/S6c unswept, live and remote-json groups stay" || bad "S6c moved"

# S11 the index and a second run
rows=$(grep -v '^#' "$H/builds-archive/index.tsv" | cut -f2 | sort)
[ "$rows" = "$MOVES" ] && ok "S11 one index row per moved dir, 1:1" || bad "S11 rows [$rows]"
row=$(grep -F "	alpha-os-SE-1-$S40	" "$H/builds-archive/index.tsv")
[ "$(cut -f4-7 <<<"$row")" = "alpha-os	SE-1	105	PLAN_BLOCKED x" ] && ok "S11 the row carries project, key, ticket_id, result1" || bad "S11 row [$row]"
same=1
while IFS= read -r n; do
  a=$(find "$H/builds-archive" -mindepth 2 -maxdepth 2 -name "$n" -type d)
  diff -r "$T/before/$n" "$a" >/dev/null 2>&1 || same=0
done <<<"$MOVES"
[ "$same" = 1 ] && ok "S11 every moved dir is in builds-archive/, byte-identical (nothing deleted)" || bad "S11 content"
( . "$H/bin/lib/build-archive.sh"; ba_dirs "$H" alpha-os SE-1 | grep -q "/alpha-os-SE-1-$S40$" ) \
  && ok "S11 ba_dirs finds the moved settled dir" || bad "S11 ba_dirs"
run
expect "S11 a second run: moved=0 collision=0 errors=0" moved=0 collision=0 errors=0
exec 9>&-

# S10 0 vendor calls so far (every ticket read went to the seam)
[ ! -s "$T/vendor.log" ] && ok "S10 0 curl/gh calls" || bad "S10 vendor calls: $(cat "$T/vendor.log")"

# ============================================================================
echo "Scenario R: rate limit (S4b)"
install_tree
settings '{"builds_retention.dry_run":"0"}'
mk "alpha-os-RA-1-$(stamp 50)" 50 201 "PLAN_BLOCKED x" COMMENTED; tk alpha-os 201 ratelimited
mk "alpha-os-RB-1-$(stamp 45)" 45 202 "PLAN_BLOCKED x" COMMENTED; tk alpha-os 202 open
mk "alpha-os-RC-1-$S40" 40 203 "PLAN_BLOCKED x" COMMENTED; tk alpha-os 203 closed
run
expect "S4b rate limited: tracker_reads=1 tracker-unreadable=3 moved=0 errors=0" tracker_reads=1 tracker-unreadable=3 moved=0 errors=0
here "alpha-os-RC-1-$S40" && ok "S4b the closed ticket after the rate limit is not read and stays" || bad "S4b RC-1 moved"

# ============================================================================
echo "Scenario O: rule 2 off (S7)"
install_tree
settings '{"builds_retention.dry_run":"0","builds_retention.settled_window_days":"0"}'
mk "alpha-os-NA-1-$S40" 40 301 "PLAN_BLOCKED x" COMMENTED; tk alpha-os 301 closed
mk "alpha-os-NB-1-$S40" 40 302 "FAILED x" COMMENTED
run
expect "S7 settled_window_days=0: not-merged=2 moved=0 tracker_reads=0 settled=0" not-merged=2 moved=0 tracker_reads=0 settled=0
here "alpha-os-NA-1-$S40" && here "alpha-os-NB-1-$S40" && ok "S7 nothing moved" || bad "S7 moved"

# ============================================================================
echo "Scenario B: the read budget (S9)"
install_tree
settings '{"builds_retention.dry_run":"0","builds_retention.tracker_reads_max":"1"}'
mk "alpha-os-BA-1-$(stamp 50)" 50 401 "PLAN_BLOCKED x" COMMENTED; tk alpha-os 401 open
mk "alpha-os-BB-1-$(stamp 45)" 45 402 "PLAN_BLOCKED x" COMMENTED; tk alpha-os 402 open
mk "alpha-os-BC-1-$S40" 40 403 "PLAN_BLOCKED x" COMMENTED; tk alpha-os 403 closed
run
expect "S9 tracker_reads_max=1: tracker_reads=1 settled-open=1 tracker-budget=2 moved=0" tracker_reads=1 settled-open=1 tracker-budget=2 moved=0

# ============================================================================
echo "Scenario T: tks_state (S8, S13)"
install_tree
tk alpha-os 1 open; tk alpha-os 2 closed; tk alpha-os 3 unreadable; tk alpha-os 4 ratelimited
s8() { ( . "$H/bin/lib/ticket-state.sh"; out=$(tks_state "$H" "$1" "$2"); echo "$?:$out" ); }
[ "$(s8 alpha-os 1)" = "0:open" ] && [ "$(s8 alpha-os 2)" = "0:closed" ] && [ "$(s8 alpha-os 3)" = "1:" ] \
  && [ "$(s8 alpha-os 4)" = "75:" ] && [ "$(s8 alpha-os 5)" = "1:" ] && [ "$(s8 beta-os 1)" = "1:" ] && [ "$(s8 alpha-os -)" = "1:" ] \
  && ok "S8 the seam: open, closed, unreadable rc 1, ratelimited rc 75, absent rc 1, '-' rc 1" \
  || bad "S8 $(s8 alpha-os 1) $(s8 alpha-os 2) $(s8 alpha-os 3) $(s8 alpha-os 4) $(s8 alpha-os 5) $(s8 beta-os 1) $(s8 alpha-os -)"
[ ! -s "$T/vendor.log" ] && ok "S10 0 curl/gh calls after S8" || bad "S10 vendor calls: $(cat "$T/vendor.log")"

# S13 no seam: the real adapters against local fakes (no network).
mkdir -p "$T/fake"
cat > "$T/fake/gh" <<'SH'
#!/bin/bash
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "${2:-}"; exit 0; }
[ "$1 $2 $3" = "api -i -X" ] || exit 1
p="${5%%\?*}"
case "$4 $p" in
  "GET repos/Org/beta/issues/"*/comments) send 200 '[]' ;;
  "GET repos/Org/beta/issues/7") send 200 '{"number":7,"state":"closed"}' ;;
  "GET repos/Org/beta/issues/8") send 200 '{"number":8,"state":"open"}' ;;
  "GET repos/Org/beta/issues/9") send 403 '{"message":"API rate limit exceeded for installation"}' ;;
esac
send 404 '{"message":"Not Found"}'
SH
cat > "$T/fake/curl" <<'SH'
#!/bin/bash
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  https://gamma.example/api/board/tickets/5) printf '{"ticket":{"id":"5","status":"done"}}\n' ;;
  https://gamma.example/api/board/tickets/6) printf '{"ticket":{"id":"6","status":"review"}}\n' ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
SH
chmod +x "$T/fake/gh" "$T/fake/curl"
printf 'GAMMA_OS_API_BASE=https://gamma.example\nGAMMA_OS_INTERNAL_API_TOKEN=tok-fixture-7931\n' > "$H/env/gamma-os.env"
s13() { ( unset BUILDS_RETENTION_TICKET_STATE_FILE; export GH_ETAG=0 PATH="$T/fake:$PATH"
          . "$H/bin/lib/ticket-state.sh"; out=$(tks_state "$H" "$1" "$2"); echo "$?:$out" ); }
[ "$(s13 beta-os 7)" = "0:closed" ] && [ "$(s13 beta-os 8)" = "0:open" ] && [ "$(s13 beta-os 9)" = "75:" ] \
  && [ "$(s13 beta-os 10)" = "1:" ] && [ "$(s13 beta-os BH-7)" = "1:" ] \
  && ok "S13 github-issues: closed, open, rate limit rc 75, absent rc 1, a non-numeric id rc 1" \
  || bad "S13 github $(s13 beta-os 7) $(s13 beta-os 8) $(s13 beta-os 9) $(s13 beta-os 10) $(s13 beta-os BH-7)"
[ "$(s13 gamma-os 5)" = "0:closed" ] && [ "$(s13 gamma-os 6)" = "0:open" ] && [ "$(s13 gamma-os 99)" = "1:" ] \
  && ok "S13 board: done is closed, review is open, a failed read rc 1" \
  || bad "S13 board $(s13 gamma-os 5) $(s13 gamma-os 6) $(s13 gamma-os 99)"
rm -f "$H/env/gamma-os.env"
[ "$(s13 gamma-os 5)" = "1:" ] && [ "$(s13 delta-os 5)" = "1:" ] \
  && ok "S13 a board with no env and an unknown project: rc 1" || bad "S13 no ctx $(s13 gamma-os 5) $(s13 delta-os 5)"

# ============================================================================
echo "Scenario D: the drain alert (S12)"
install_tree
settings '{"builds_retention.dry_run":"0","builds_retention.max_dirs":"1"}'
for i in 1 2 3 4 5 6 7; do mk "alpha-os-DA-$i-$(stamp $((60 - i)))" $((60 - i)) "60$i" "$MERGED" COMMENTED; done
DRAIN_TXT='two runs in a row'
BUILDS_RETENTION_NOW=$NOW run
expect "S12 run 1: real, capped" dry=0 capped=1 moved=1
[ "$(nalerts "$DRAIN_TXT")" = 0 ] && ok "S12 one capped run raises no drain alert" || bad "S12 run 1 alert"
BUILDS_RETENTION_NOW=$(( NOW + 3 * DAY )) run
expect "S12 run 2, 3 days later: capped" capped=1 moved=1
[ "$(nalerts "$DRAIN_TXT")" = 0 ] && ok "S12 a previous capped run older than 48 h does not count" || bad "S12 stale alert"
BUILDS_RETENTION_NOW=$(( NOW + 3 * DAY + 3600 )) run --dry-run
expect "S12 a dry capped run" dry=1 capped=1
BUILDS_RETENTION_NOW=$(( NOW + 3 * DAY + 7200 )) run
expect "S12 run 4: real, capped" dry=0 capped=1 moved=1
[ "$(nalerts "$DRAIN_TXT")" = 0 ] && ok "S12 a dry capped run between does not count" || bad "S12 dry counted"
BUILDS_RETENTION_NOW=$(( NOW + 4 * DAY )) run
expect "S12 run 5: real, capped" capped=1 moved=1
[ "$(nalerts "$DRAIN_TXT")" = 1 ] && grep -q '"warn"' "$H/state/alerts/builds-retention_drain.json" 2>/dev/null \
  && ok "S12 two real capped runs in a row: one warn drain alert" || bad "S12 alert: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep "$DRAIN_TXT" "$H/logs/ALERTS.log" | grep -q 'max_dirs=1.*box-fixture' && ok "S12 the alert names max_dirs and the box" || bad "S12 text: $(grep "$DRAIN_TXT" "$H/logs/ALERTS.log")"
settings '{"builds_retention.dry_run":"0","builds_retention.max_dirs":"50"}'
BUILDS_RETENTION_NOW=$(( NOW + 5 * DAY )) run
expect "S12 run 6: real, not capped" capped=0 moved=3
grep -q 'drained' "$H/logs/ALERTS.log" && ok "S12 an uncapped real run resolves the drain alert" || bad "S12 resolve: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "Scenario V: seeded volume"
install_tree
mkdir -p "$T/jshim"
cat > "$T/jshim/jq" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/jq.log"
exec $(command -v jq) "\$@"
SH
chmod +x "$T/jshim/jq"; : > "$T/jq.log"
SV=$S40; SY=$(stamp 5)
for i in $(seq 1000 1999); do
  d="$H/builds/alpha-os-VA-$i-$SV"; mkdir -p "$d"; printf 'PLAN_BLOCKED x\n' > "$d/RESULT"; : > "$d/COMMENTED"
  printf '{"ticket_id":"%s"}\n' "$i" > "$d/job.json"
  d="$H/builds/alpha-os-VY-$i-$SY"; mkdir -p "$d"; printf 'PLAN_BLOCKED x\n' > "$d/RESULT"; : > "$d/COMMENTED"
  printf '{"ticket_id":"%s"}\n' "$i" > "$d/job.json"
done
touch -d "@$(( NOW - 40 * DAY ))" "$H"/builds/*-VA-*/* "$H"/builds/*-VA-*
touch -d "@$(( NOW - 5 * DAY ))" "$H"/builds/*-VY-*/* "$H"/builds/*-VY-*
rm -f "$H/state/settings-cache.json"
t0=$SECONDS
PATH="$T/jshim:$PATH" run
el=$(( SECONDS - t0 ))
expect "V 2,000 dirs: would_move=1000 young=1000 tracker_reads=0" dirs=2000 would_move=1000 young=1000 tracker_reads=0
[ "$el" -lt 60 ] && ok "V wall ${el}s < 60 s" || bad "V wall ${el}s"
[ "$(grep -c 'job.json' "$T/jq.log")" = 0 ] && ok "V the ticket id map reads no job.json with jq" || bad "V jq job.json reads: $(grep -c job.json "$T/jq.log")"

# ============================================================================
echo "Static: registration and seeds"
jq -e '.scope == "box" and (.boxes | length) == 11 and (.boxes | index("small")) != null and (.boxes | index("hub")) != null' \
  "$DIR/catalog/lanes.d/builds-retention.json" >/dev/null && ok "registry: scope box, 11 boxes" || bad "registry boxes"
jq -e '.env == "BUILDS_RETENTION_TICKET_STATE_FILE" and .settable == false' \
  "$DIR/catalog/lanes.d/builds-retention.knobs.d/BUILDS_RETENTION_TICKET_STATE_FILE.json" >/dev/null \
  && ok "registry: the seam knob row" || bad "registry seam knob"
F="$DIR/worker/jobs/schema.d/202610272153-bh-7931-builds-retention-settled.sql"
for k in settled_window_days:30 tracker_reads_max:200; do
  grep -q "'builds_retention.${k%%:*}','${k#*:}'" "$F" && ok "seed builds_retention.${k%%:*}=${k#*:}" || bad "seed ${k%%:*}"
done
grep -q "'builds_retention.dry_run'" "$F" && bad "the fragment seeds dry_run" || ok "the fragment does not seed or flip dry_run"

echo "builds-retention-settled.bh-7931: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
