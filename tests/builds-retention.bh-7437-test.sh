#!/bin/bash
# tests/builds-retention.bh-7437-test.sh — BH-7437 part 2, item 2: the
# retention rule for builds/. bin/builds-retention.sh moves SETTLED build-dir
# groups past the window to builds-archive/<YYYYMM>/<dir>, dry run first, one
# audit line per run. Drives the real script in a scratch tree, clock pinned
# with BUILDS_RETENTION_NOW, settings through the settings-cache seam.
#
#   R1   lane-off flag: no move, no run line
#   R2   no settings: dry=1 window=14(default), nothing moved
#   R3   the decision table, one group per row, kept-reason counters
#   R4   dry run: the list file holds exactly the eligible dirs
#   R6   real run: eligible dirs under builds-archive/<YYYYMM>/, byte-identical,
#        one index row each; kept dirs untouched; a second run moves nothing
#   R7   bin/fetch-artifact.sh answers archived:true for a moved build
#   R15  cross-filesystem seam: one alert, moved=0
#   R16  a failing mv: tombstone row, errors=1, live dir kept, one warn alert
#   R17  max_dirs: the run stops between groups, capped=1, a group whole
#   R18  the run line carries every field
#   R19  a held run lock: `already running`, rc 0
#   V    seeded volume: 1,000 old merged dirs + 5 young; young groups cost no
#        RESULT read
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

NOW=1792000000            # 2026-10-14, minute 46 (no lane start offset)
DAY=86400
ts() { date -u -d "@$1" "+$2"; }
export BUILDS_RETENTION_NOW="$NOW" LANE_GATE_NOW="$NOW"
export HARNESS_SECRET=fixture-harness-secret JOBS_URL="" JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=hub

H="$T/h"
install_tree() {
  scratch_rm "$H"
  mkdir -p "$H/builds" "$H/logs" "$H/locks" "$H/state" "$H/flags" "$H/env"
  local s
  for s in bin/builds-retention.sh bin/jobs-client.sh bin/lane-alert.sh bin/fetch-artifact.sh bin/fleet-conf.sh; do
    ( cd "$DIR" && scratch_install_closure "$s" "$H" ) >/dev/null || { echo "setup: could not install $s"; exit 1; }
  done
  printf 'alpha-os  Org/alpha  https://alpha.example  /api/board  2 box-alpha\n' > "$H/fleet.conf"
}
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
run() { "$H/bin/builds-retention.sh" "$@" > "$T/run.out" 2>&1; RC=$?; }
lastlog() { tail -1 "$H/logs/builds-retention.log" 2>/dev/null; }
field() { lastlog | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
settings() { jq -nc --argjson fa "$NOW" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$H/state/settings-cache.json"; }
# ALERTS.log lines carry the text; the id and its severity are in
# state/alerts/<id>.json (bin/lane-alert.sh).
nalerts() { local n; n=$(grep -c "$1" "$H/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
ERR_TXT='builds-retention had [0-9]* error'
XFS_TXT='are on different filesystems'
astate() { cat "$H/state/alerts/$1.json" 2>/dev/null; }

# mk <name> <age-days> <result1|-> [marker...] — one build dir, the files and
# the dir itself at now - age days. `-` writes no RESULT.
mk() {
  local n="$1" age="$2" r="$3" d="$H/builds/$1" m e
  shift 3
  e=$(( NOW - age * DAY ))
  mkdir -p "$d"
  [ "$r" = - ] || printf '%s\n' "$r" > "$d/RESULT"
  printf '{"ticket_id":"t-%s","key":"x"}\n' "${n##*-}" > "$d/job.json"
  for m in "$@"; do : > "$d/$m"; done
  touch -d "@$e" "$d"/* "$d"
}
# stamp <age-days> — the 12-digit build stamp of a dir made age days ago.
stamp() { ts $(( NOW - $1 * DAY )) %Y%m%d%H%M; }
S30=$(stamp 30); S40=$(stamp 40); S5=$(stamp 5)
M30=${S30:0:6}; M40=${S40:0:6}
MERGED="PR_MERGED https://github.com/o/alpha/pull/1"

# ============================================================================
echo "Scenario A: the decision table"
install_tree
mk "alpha-os-TK-1-$S30" 30 "$MERGED" COMMENTED                          # archive
printf 'VERDICT: APPROVE\nthe TK-1 review\n' > "$H/builds/alpha-os-TK-1-$S30/review.md"
touch -d "@$(( NOW - 30 * DAY ))" "$H/builds/alpha-os-TK-1-$S30/review.md"
mk "alpha-os-TK-2-$S40" 40 "QUEUED_FLY TK-2" COMMENTED                  # archive: stub + merged twin
mk "pool-alpha-os-TK-2-$S30" 30 "$MERGED" COMMENTED
mk "alpha-os-TK-3-$S40" 40 "$MERGED" COMMENTED                          # young: one dir young
mk "alpha-os-TK-3-$S5" 5 "BUILD_DEFERRED x" COMMENTED
mk "alpha-os-TK-4-$S40" 40 "$MERGED" COMMENTED                          # young: RESULT rewritten
touch -d "@$(( NOW - 3 * DAY ))" "$H/builds/alpha-os-TK-4-$S40/RESULT"
mk "alpha-os-TK-5-$S40" 40 "REVIEW_BLOCKED x" COMMENTED                 # not-merged
mk "alpha-os-TK-6-$S40" 40 "$MERGED" COMMENTED                          # unswept
mk "alpha-os-TK-6-$S30" 30 "PR_CREATED https://github.com/o/alpha/pull/6"
mk "alpha-os-TK-7-$S40" 40 "$MERGED" COMMENTED                          # archive: RELAYED, no COMMENTED
mk "alpha-os-TK-7-remote$(ts $(( NOW - 39 * DAY )) %Y%m%d%H%M%S)" 39 "PR_CREATED https://github.com/o/alpha/pull/7" RELAYED
mk "alpha-os-TK-9-$S40" 40 "$MERGED" COMMENTED                          # remote-json
mkdir -p "$H/state/remote-results/alpha-os"; echo '{}' > "$H/state/remote-results/alpha-os/TK-9.json"
mk "alpha-os-TK-10-$S40" 40 "$MERGED" COMMENTED                         # live
mk "cost-rows-db-20260902" 40 -                                          # no-stamp (no key)
mk "alpha-os-TK-11-old" 40 "$MERGED" COMMENTED                          # no-stamp (key, no stamp)
mk "alpha-os-TK-11-$S40" 40 "$MERGED" COMMENTED
mk "alpha-os-TK-8-$S40" 40 "PLAN_BLOCKED x" COMMENTED                   # not-merged, TK-88 merged
mk "alpha-os-TK-88-$S40" 40 "$MERGED" COMMENTED                         # archive
mk "alpha-os-TK-13-$S40" 40 "QUEUED_FLY TK-13" COMMENTED                # young: stub old, twin young
mk "pool-alpha-os-TK-13-$S5" 5 "$MERGED" COMMENTED
ELIGIBLE=$(printf '%s\n' "alpha-os-TK-1-$S30" "alpha-os-TK-2-$S40" "pool-alpha-os-TK-2-$S30" "alpha-os-TK-7-$S40" \
  "alpha-os-TK-7-remote$(ts $(( NOW - 39 * DAY )) %Y%m%d%H%M%S)" "alpha-os-TK-88-$S40" | sort)
cp -a "$H/builds" "$T/before"

# TK-10's build-key lock is held through every run of scenario A.
exec 9>"$H/locks/build-key-alpha-os-TK-10.lock"; flock 9

# R1 lane off
: > "$H/flags/lane-off-builds-retention"
run
[ "$RC" = 0 ] && [ ! -s "$H/logs/builds-retention.log" ] && [ ! -e "$H/builds-archive/index.tsv" ] \
  && ok "R1 lane off: rc 0, no run line, nothing archived" || bad "R1 rc=$RC log=$(lastlog)"
rm -f "$H/flags/lane-off-builds-retention"

# R2 + R4: no settings at all -> the defaults, dry run
run
[ "$RC" = 0 ] && ok "R2 rc 0" || bad "R2 rc=$RC $(cat "$T/run.out")"
lastlog | grep -q " dry=1 window=14(default) " && ok "R2 dry=1 window=14(default)" || bad "R2 line: $(lastlog)"
[ "$(cd "$H/builds" && find . -mindepth 1 -maxdepth 1 | wc -l)" = "$(cd "$T/before" && find . -mindepth 1 -maxdepth 1 | wc -l)" ] \
  && [ ! -e "$H/builds-archive/index.tsv" ] && ok "R2 the dry run moved nothing and wrote no index" || bad "R2 something moved"
got=$(cut -f1 "$H/logs/builds-retention-dryrun.txt" | sort)
[ "$got" = "$ELIGIBLE" ] && ok "R4 the dry-run list is exactly the eligible dirs" || bad "R4 list [$got] want [$ELIGIBLE]"
grep -qxF "alpha-os-TK-1-$S30	$M30/alpha-os-TK-1-$S30" "$H/logs/builds-retention-dryrun.txt" \
  && ok "R4 list line is <dir> TAB <YYYYMM>/<dir>" || bad "R4 line shape: $(head -2 "$H/logs/builds-retention-dryrun.txt")"
[ "$(field would_move)" = 6 ] && [ "$(field moved)" = 0 ] && ok "R4 would_move=6 moved=0" || bad "R4 $(lastlog)"

# --dry-run forces a dry run whatever the row says
settings '{"builds_retention.dry_run":"0"}'
run --dry-run
[ "$(field dry)" = 1 ] && [ ! -e "$H/builds-archive/index.tsv" ] && ok "R4 --dry-run overrides dry_run=0" || bad "R4 --dry-run $(lastlog)"

# R6 real run, a held build-key lock on TK-10
settings '{"builds_retention.dry_run":"0","builds_retention.window_days":"14"}'
run
L=$(lastlog)
[ "$(field dry)" = 0 ] && lastlog | grep -q " window=14 " && ok "R6 dry=0 window=14 from the rows" || bad "R6 line: $L"
[ "$(field moved)" = 6 ] && [ "$(field eligible_groups)" = 4 ] && [ "$(field errors)" = 0 ] \
  && ok "R6 moved=6 eligible_groups=4 errors=0" || bad "R6 counts: $L"
for k in no-stamp:2 young:3 not-merged:2 unswept:1 remote-json:1 live:1 collision:0; do
  [ "$(field "${k%%:*}")" = "${k#*:}" ] && ok "R3 kept ${k%%:*}=${k#*:}" || bad "R3 ${k%%:*}=$(field "${k%%:*}") want ${k#*:}"
done
allin=1; same=1
while IFS= read -r n; do
  s=$(sed -E 's/.*-(remote)?([0-9]{12}).*/\2/' <<<"$n")
  a="$H/builds-archive/${s:0:6}/$n"
  { [ -d "$a" ] && [ ! -e "$H/builds/$n" ]; } || allin=0
  diff -r "$T/before/$n" "$a" >/dev/null 2>&1 || same=0
done <<<"$ELIGIBLE"
[ "$allin" = 1 ] && ok "R6 every eligible dir is under builds-archive/<YYYYMM>/ and gone from builds/" || bad "R6 placement: $(find "$H/builds-archive" -maxdepth 2)"
[ "$same" = 1 ] && ok "R6 the moved content is byte-identical" || bad "R6 content differs"
[ "$(grep -vc '^#' "$H/builds-archive/index.tsv")" = 6 ] && ok "R6 one index row per moved dir" || bad "R6 index: $(cat "$H/builds-archive/index.tsv")"
row=$(grep -F "	pool-alpha-os-TK-2-$S30	" "$H/builds-archive/index.tsv")
[ "$(cut -f3-7 <<<"$row")" = "$M30/pool-alpha-os-TK-2-$S30	alpha-os	TK-2	t-$S30	$MERGED" ] \
  && ok "R6 the index row carries relpath, project, key, ticket_id, result1" || bad "R6 row [$row]"
kept=1
for n in "alpha-os-TK-3-$S40" "alpha-os-TK-3-$S5" "alpha-os-TK-4-$S40" "alpha-os-TK-5-$S40" "alpha-os-TK-6-$S40" \
         "alpha-os-TK-6-$S30" "alpha-os-TK-9-$S40" "alpha-os-TK-10-$S40" cost-rows-db-20260902 alpha-os-TK-11-old \
         "alpha-os-TK-11-$S40" "alpha-os-TK-8-$S40" "alpha-os-TK-13-$S40" "pool-alpha-os-TK-13-$S5"; do
  diff -r "$T/before/$n" "$H/builds/$n" >/dev/null 2>&1 || { kept=0; echo "    kept dir changed: $n"; }
done
[ "$kept" = 1 ] && ok "R6 every kept dir is untouched (TK-8 stays while TK-88 moves)" || bad "R6 kept dirs moved"
[ "$(nalerts "$ERR_TXT")" = 0 ] && ok "R6 a clean run raises no errors alert" || bad "R6 alert: $(cat "$H/logs/ALERTS.log")"
run
[ "$(field moved)" = 0 ] && [ "$(field collision)" = 0 ] && [ "$(field errors)" = 0 ] \
  && ok "R6 a second run moves nothing and finds no collision" || bad "R6 second run: $(lastlog)"

exec 9>&-

# R7 the console artifact reader
OUT=$("$H/bin/fetch-artifact.sh" alpha-os TK-1 review cid-r7 2>/dev/null)
[ "$(jq -r .archived <<<"$OUT")" = true ] && [ "$(jq -r .missing <<<"$OUT")" = false ] \
  && [ "$(jq -r .build_dir <<<"$OUT")" = "$H/builds-archive/$M30/alpha-os-TK-1-$S30" ] \
  && ok "R7 fetch-artifact: archived:true, missing:false, the archive build_dir" || bad "R7 out=$OUT"

# R18 the run line carries every field, in order
re='^[0-9T:-]+Z run dry=[01] window=[0-9]+(\(default\))? cut=[0-9]{12} dirs=[0-9]+ groups=[0-9]+ eligible_groups=[0-9]+ moved=[0-9]+ would_move=[0-9]+ kept no-stamp=[0-9]+ young=[0-9]+ not-merged=[0-9]+ unswept=[0-9]+ remote-json=[0-9]+ live=[0-9]+ collision=[0-9]+ capped=[01] errors=[0-9]+ wall=[0-9]+s$'
[ "$(grep -c ' run ' "$H/logs/builds-retention.log")" = 4 ] && ok "R18 one run line per run (4 runs)" || bad "R18 lines: $(cat "$H/logs/builds-retention.log")"
bad18=$(grep ' run ' "$H/logs/builds-retention.log" | grep -cvE "$re")
[ "$bad18" = 0 ] && ok "R18 every run line has every field" || bad "R18 malformed: $(grep ' run ' "$H/logs/builds-retention.log" | grep -vE "$re")"
[ "$(field cut)" = "$(ts $(( NOW - 15 * DAY )) %Y%m%d%H%M)" ] && ok "R18 cut = now - (window + 1) days" || bad "R18 cut=$(field cut)"

# ============================================================================
echo "Scenario B: collision"
install_tree
settings '{"builds_retention.dry_run":"0"}'
mk "alpha-os-TK-12-$S40" 40 "$MERGED" COMMENTED
mkdir -p "$H/builds-archive/$M40/alpha-os-TK-12-$S40"; echo other > "$H/builds-archive/$M40/alpha-os-TK-12-$S40/x"
mk "alpha-os-TK-14-$S40" 40 "$MERGED" COMMENTED
( . "$H/bin/lib/build-archive.sh"; ba_index_append "$H" "alpha-os-TK-14-$S40" "$M40/alpha-os-TK-14-$S40" alpha-os TK-14 - "$MERGED" )
run
[ "$(field collision)" = 2 ] && [ "$(field errors)" = 2 ] && [ "$(field moved)" = 0 ] \
  && ok "R3 an existing archive path and an existing index row are collisions, errors=2" || bad "R3 collision: $(lastlog)"
[ -d "$H/builds/alpha-os-TK-12-$S40" ] && [ "$(cat "$H/builds-archive/$M40/alpha-os-TK-12-$S40/x")" = other ] \
  && ok "R3 a collision overwrites nothing" || bad "R3 collision moved something"
[ "$(nalerts "$ERR_TXT")" = 1 ] && ok "R3 one errors alert" || bad "R3 alerts: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# ============================================================================
echo "Scenario C: cross-filesystem (R15)"
install_tree
settings '{"builds_retention.dry_run":"0"}'
mk "alpha-os-TK-1-$S40" 40 "$MERGED" COMMENTED
BUILDS_RETENTION_FORCE_XFS=1 run
[ "$RC" = 0 ] && [ -d "$H/builds/alpha-os-TK-1-$S40" ] && [ ! -e "$H/builds-archive/index.tsv" ] \
  && ok "R15 cross-fs: rc 0, nothing moved, no index row" || bad "R15 rc=$RC $(lastlog)"
[ "$(nalerts "$XFS_TXT")" = 1 ] && ok "R15 one cross-fs alert" || bad "R15 alerts: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
lastlog | grep -q 'cross-fs (no move)' && ok "R15 the run line says cross-fs" || bad "R15 line: $(lastlog)"

# ============================================================================
echo "Scenario D: a failing move (R16)"
install_tree
settings '{"builds_retention.dry_run":"0"}'
mk "alpha-os-TK-1-$S40" 40 "$MERGED" COMMENTED
mkdir -p "$H/builds-archive"; : > "$H/builds-archive/$M40"     # a FILE where the month dir goes
run
[ "$(field moved)" = 0 ] && [ "$(field errors)" = 1 ] && ok "R16 moved=0 errors=1" || bad "R16 $(lastlog)"
[ -d "$H/builds/alpha-os-TK-1-$S40" ] && [ -f "$H/builds/alpha-os-TK-1-$S40/RESULT" ] && ok "R16 the live dir stays" || bad "R16 live dir gone"
[ "$(grep -F "alpha-os-TK-1-$S40" "$H/builds-archive/index.tsv" | cut -f7 | tail -1)" = MOVE_FAILED ] \
  && ok "R16 a MOVE_FAILED tombstone row follows the row" || bad "R16 index: $(cat "$H/builds-archive/index.tsv")"
[ "$(nalerts "$ERR_TXT")" = 1 ] && astate builds-retention_errors | grep -q '"warn"' \
  && ok "R16 one warn errors alert" || bad "R16 alerts: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
( . "$H/bin/lib/build-archive.sh"; ba_has_key "$H" alpha-os TK-1 ) && bad "R16 a reader sees the failed move as archived" \
  || ok "R16 readers skip the row with no dir"
rm -f "$H/builds-archive/$M40"
run
[ "$(field moved)" = 1 ] && [ "$(field errors)" = 0 ] && [ -d "$H/builds-archive/$M40/alpha-os-TK-1-$S40" ] \
  && ok "R16 after the fix the next run moves it (a tombstone is no collision)" || bad "R16 retry: $(lastlog)"
grep -q 'runs clean again' "$H/logs/ALERTS.log" \
  && ok "R16 the clean run resolves the errors alert" || bad "R16 resolve: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "Scenario E: the cap (R17)"
install_tree
settings '{"builds_retention.dry_run":"0","builds_retention.max_dirs":"2"}'
mk "alpha-os-TK-1-$(stamp 50)" 50 "$MERGED" COMMENTED
mk "alpha-os-TK-2-$(stamp 45)" 45 "$MERGED" COMMENTED
mk "alpha-os-TK-3-$S40" 40 "$MERGED" COMMENTED
run
[ "$(field moved)" = 2 ] && [ "$(field capped)" = 1 ] && ok "R17 max_dirs=2 of 3 groups: moved=2 capped=1" || bad "R17 $(lastlog)"
[ -d "$H/builds/alpha-os-TK-3-$S40" ] && ok "R17 the oldest groups go first; the newest waits" || bad "R17 order: $(ls "$H/builds")"
run
[ "$(field moved)" = 1 ] && [ "$(field capped)" = 0 ] && ok "R17 the next run drains the rest" || bad "R17 drain: $(lastlog)"
install_tree
settings '{"builds_retention.dry_run":"0","builds_retention.max_dirs":"1"}'
mk "alpha-os-TK-1-$(stamp 50)" 50 "QUEUED_FLY TK-1" COMMENTED
mk "pool-alpha-os-TK-1-$(stamp 49)" 49 "$MERGED" COMMENTED
mk "alpha-os-TK-2-$S40" 40 "$MERGED" COMMENTED
run
[ "$(field moved)" = 2 ] && [ "$(field capped)" = 1 ] && [ -z "$(ls "$H/builds" | grep TK-1)" ] && [ -d "$H/builds/alpha-os-TK-2-$S40" ] \
  && ok "R17 a group is never split: both TK-1 dirs move, then the cap stops" || bad "R17 split: $(lastlog) :: $(ls "$H/builds")"

# ============================================================================
echo "Scenario F: a held run lock (R19)"
exec 9>>"$H/locks/builds-retention.lock"; flock 9
run
exec 9>&-
[ "$RC" = 0 ] && [ "$(lastlog | sed 's/^[^ ]* //')" = "already running" ] && ok "R19 already running, rc 0" || bad "R19 rc=$RC $(lastlog)"

# ============================================================================
echo "Scenario V: seeded volume"
install_tree
mkdir -p "$T/shim"
cat > "$T/shim/head" <<SH
#!/bin/bash
for a in "\$@"; do case "\$a" in */RESULT) printf '%s\n' "\$a" >> "$T/head.log" ;; esac; done
exec $(command -v head) "\$@"
SH
chmod +x "$T/shim/head"; : > "$T/head.log"
for i in $(seq 1000 1999); do
  d="$H/builds/alpha-os-VB-$i-$S40"; mkdir -p "$d"; printf '%s\n' "$MERGED" > "$d/RESULT"; : > "$d/COMMENTED"
done
touch -d "@$(( NOW - 40 * DAY ))" "$H"/builds/*/RESULT "$H"/builds/*/COMMENTED
for i in 1 2 3 4 5; do mk "alpha-os-YB-$i-$S5" 5 "$MERGED" COMMENTED; done
rm -f "$H/state/settings-cache.json"
PATH="$T/shim:$PATH" run
[ "$(field dirs)" = 1005 ] && [ "$(field would_move)" = 1000 ] && [ "$(field young)" = 5 ] \
  && ok "V 1,005 dirs: would_move=1000 young=5" || bad "V $(lastlog)"
[ "$(grep -c 'YB-' "$T/head.log")" = 0 ] && ok "V young groups cost no RESULT read" || bad "V young reads: $(grep -c 'YB-' "$T/head.log")"
nreads=$(grep -c . "$T/head.log")
[ "$nreads" -le 1000 ] && ok "V at most one RESULT read per old dir ($nreads)" || bad "V reads=$nreads"

# ============================================================================
echo "Static: registration and no delete"
CODE=$(grep -vE '^[[:space:]]*#' "$DIR/bin/builds-retention.sh")
grep -qE '\brm -r|\brm -fr|\brm -rf' <<<"$CODE" && bad "R6 the lane has an rm -r" || ok "R6 the lane never deletes a dir (no rm -r)"
grep -qiE 'claude|opus|sonnet|haiku|agent-call' <<<"$CODE" && bad "the lane names a model" || ok "no model call"
jq -e '.id == "builds-retention" and .script == "bin/builds-retention.sh" and .switch.name == "lane-off-builds-retention"' \
  "$DIR/catalog/lanes.d/builds-retention.json" >/dev/null && ok "registry row" || bad "registry row"
grep -q '^27 4 \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/builds-retention.sh' "$DIR/cron/lanes/737-builds-retention.cron" \
  && ok "cron fragment: daily 04:27 behind the hub lease" || bad "cron fragment"
for k in window_days:14 dry_run:1 max_dirs:2000; do
  grep -q "'builds_retention.${k%%:*}','${k#*:}'" "$DIR/worker/jobs/schema.d/202610200111-bh-7437-builds-retention-settings.sql" \
    && ok "seed builds_retention.${k%%:*}=${k#*:}" || bad "seed ${k%%:*}"
done

echo "builds-retention.bh-7437: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
