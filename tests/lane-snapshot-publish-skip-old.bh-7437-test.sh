#!/bin/bash
# tests/lane-snapshot-publish-skip-old.bh-7437-test.sh — BH-7437 part 1.
#
# The hub's builds/ held 9,579 record dirs, 7,060 older than a week. The
# publisher asked `find <dir> -maxdepth 0 -mtime -<days>` of EVERY dir a
# record glob matched, so one run took 30-60 min at load 245 and the Fly
# machines refused the stale snapshots (PROF lri_fetch rc=1). The dir name
# carries the build time: a name inside the window is in with no stat, and
# every other dir is decided by its mtime through the bash -nt test against
# one reference file. No dir costs a fork to decide.
#
#   S1  _lri_name_stamp: the name shapes the hub writes, and the ones that
#       carry no time (they fall back to the mtime check)
#   S2  1,000 old dirs + 5 new + odd shapes: no find fork decides an age; find
#       runs only to list the files of the dirs that are in
#   S3  the published snapshot holds exactly the dirs the mtime rule put in
#       (an old name written yesterday too), and the skip lines keep their
#       text; an empty match under pipefail is rc 0
#   S4  bin/lane-snapshot-publish.sh: a run longer than lane_snapshot.run_alert_s
#       pages ONE lane-snapshot-slow-<lane> alert; a short run of another lane
#       resolves only that lane's id; the log
#       line carries the run time and stdout keeps its shape
#
# Run from anywhere (exit 0 = pass). Needs GNU find, touch, date and tar.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
find /dev/null -maxdepth 0 -printf '' 2>/dev/null || { echo "SKIP: find is not GNU find"; exit 0; }
NOW=$(date -u +%s)
DAY=86400
# ts <epoch> <fmt> — a UTC stamp.
ts() { date -u -d "@$1" "+$2"; }

R="$T/r"
mkdir -p "$R/bin/lib" "$R/catalog" "$R/builds" "$R/logs" "$R/state"
( cd "$DIR" && scratch_install_closure bin/lib/lane-run-inputs.sh "$R" ) >/dev/null \
  || { echo "setup: could not install bin/lib/lane-run-inputs.sh"; exit 1; }
cp -r "$DIR/catalog/lane-run-inputs.d" "$R/catalog/"

# rec <name> <mtime-epoch> — one record dir with a RESULT and a job.json, the
# dir's mtime set last (the files do not move it back).
rec() {
  mkdir -p "$R/builds/$1"
  printf 'PR_CREATED\n' > "$R/builds/$1/RESULT"
  printf '{"key":"x"}\n' > "$R/builds/$1/job.json"
  touch -d "@$2" "$R/builds/$1/RESULT" "$R/builds/$1/job.json" "$R/builds/$1"
}

# ============================================================================
echo "S1: _lri_name_stamp"
stamp() { ( export HARNESS="$R"; . "$R/bin/lib/lane-run-inputs.sh"; _lri_name_stamp "$1" && printf '%s' "$LRI_STAMP" ) 2>/dev/null || printf 'none'; }
while IFS='|' read -r name want; do
  [ -n "$name" ] || continue
  got=$(stamp "$name")
  [ "$got" = "$want" ] && ok "S1 $name -> $want" || bad "S1 $name -> $got (want $want)"
done <<'EOF'
p1-BH-12-202610181203|20261018120300
builds/p1-BH-12-202610181203|20261018120300
pool-p1-BH-12-202605010000|20260501000000
fly-p1-BH-12-20261018120359|20261018120359
p1-BH-12-remote20261018120359|20261018120359
p1-BH-12-remote20261018120359-2|20261018120359
p1-BH-12-remote20261018120359-17|20261018120359
p1-BH-12-r2-202610181203|20261018120300
p1-BH-12-rerun-202610181203|20261018120300
p1-BH-12-rerun-20261018120359|20261018120359
p1-BH-12|none
p1-BH-12-old|none
p1-BH-202610181203|none
p1-BH-12-202613181203|none
p1-BH-12-202610321203|none
p1-BH-12-202610182460|none
p1-BH-12-2026101812|none
p1-BH-12-1018120300|none
p1-BH-12-202610181203-x|none
p1-BH-12-202610181203-123|none
p1-BH-12-x202610181203|none
EOF

# ============================================================================
echo "S2: 1,000 old dirs + 5 new + odd shapes"
# Old: 40..1039 days ago, four name shapes, mtime = the name's time.
for i in $(seq 1 1000); do
  e=$((NOW - (39 + i) * DAY - 3600))
  case $((i % 4)) in
    0) n="p1-BH-$i-$(ts "$e" %Y%m%d%H%M)" ;;
    1) n="pool-p1-BH-$i-$(ts "$e" %Y%m%d%H%M)" ;;
    2) n="fly-p1-BH-$i-$(ts "$e" %Y%m%d%H%M%S)" ;;
    3) n="p1-BH-$i-remote$(ts "$e" %Y%m%d%H%M%S)-2" ;;
  esac
  rec "$n" "$e"
done
NEW=()
k=0
for shape in run pool fly remote rerun; do
  k=$((k + 1)); e=$((NOW - k * DAY))
  case $shape in
    run)    n="p1-BH-500$k-$(ts "$e" %Y%m%d%H%M)" ;;
    pool)   n="pool-p1-BH-500$k-$(ts "$e" %Y%m%d%H%M)" ;;
    fly)    n="fly-p1-BH-500$k-$(ts "$e" %Y%m%d%H%M%S)" ;;
    remote) n="p1-BH-500$k-remote$(ts "$e" %Y%m%d%H%M%S)" ;;
    rerun)  n="p1-BH-500$k-rerun-$(ts "$e" %Y%m%d%H%M)" ;;
  esac
  rec "$n" "$e"; NEW+=("$n")
done
# Odd shapes. No time in the name: the mtime decides, as before.
rec p1-BH-9001-old "$((NOW - 60 * DAY))"           # out (mtime)
rec p1-BH-9002-x   "$((NOW - 1 * DAY))"            # in (mtime)
# Old names: the mtime decides, through -nt.
B31=$(ts "$((NOW - 31 * DAY))" %Y%m%d%H%M)
rec "p1-BH-9003-$B31" "$((NOW - 31 * DAY))"        # out (mtime)
rec "p1-BH-9004-$B31" "$((NOW - 1 * DAY))"         # in (written later)
# A 200-day name written to yesterday (a late marker): in, as before BH-7437.
B200=$(ts "$((NOW - 200 * DAY))" %Y%m%d%H%M)
rec "p1-BH-9005-$B200" "$((NOW - 1 * DAY))"
# Not this project's, and not a record shape: never read.
rec "p2-BH-1-$(ts "$((NOW - DAY))" %Y%m%d%H%M)" "$((NOW - DAY))"
rec "mq-p1-train-$(ts "$((NOW - DAY))" %m%d%H%M)" "$((NOW - DAY))"
WANT_IN=$(printf '%s\n' "${NEW[@]}" p1-BH-9002-x "p1-BH-9004-$B31" "p1-BH-9005-$B200" | LC_ALL=C sort)
# find runs on a dir only to list the files of a dir that is in.
WANT_READ=$(printf 'builds/%s\n' $WANT_IN | LC_ALL=C sort)

# The find shim: logs the first argument of every call, then runs the real one.
FB="$T/fakebin"; mkdir -p "$FB"
REAL_FIND=$(command -v find)
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/find.log"\nexec "%s" "$@"\n' "$T" "$REAL_FIND" > "$FB/find"
chmod +x "$FB/find"

PARTS="$T/parts"
# publish [shim] — lri_publish for blocked-resolver/p1 with the jobs client
# stubbed: GET of the snapshot is a 404, the parts land in $PARTS.
publish() {
  scratch_rm "$PARTS"; mkdir -p "$PARTS"; : > "$T/find.log"
  (
    export HARNESS="$R" PARTS
    [ "${1:-}" = shim ] && export PATH="$FB:$PATH"
    _jobs_req() {
      JOBS_HTTP=200
      case "$1 $2" in
        "GET "*/writebacks) echo '{"writebacks":[]}' ;;
        "GET "*) JOBS_HTTP=404; echo '{}'; return 2 ;;
        *) echo '{}' ;;
      esac
    }
    _jobs_req_file() { cp "$3" "$PARTS/${2##*/}.json"; JOBS_HTTP=200; echo '{}'; }
    setting_get() {
      case "$1" in
        lane_snapshot.builds_days) echo 30 ;;
        *) return 1 ;;
      esac
    }
    . "$R/bin/lib/lane-run-inputs.sh"
    lri_publish blocked-resolver p1
  )
}
members() {
  : > "$T/snap.tgz"
  for f in $(ls "$PARTS"/*.json 2>/dev/null | LC_ALL=C sort); do jq -j .b64 "$f" | base64 -d >> "$T/snap.tgz"; done
  tar -tzf "$T/snap.tgz" 2>/dev/null | sed 's#/$##' | LC_ALL=C sort
}

S=$(date +%s.%N); out=$(publish); rc=$?; E=$(date +%s.%N)
SECS=$(awk -v s="$S" -v e="$E" 'BEGIN { printf "%.2f", e - s }')
echo "  timing: lri_publish over $(ls "$R/builds" | wc -l) record dirs: ${SECS}s (no shim)"
case "$rc:$out" in 0:published*) ok "S2 publish rc 0: $out" ;; *) bad "S2 publish rc=$rc: $out" ;; esac
cp "$R/logs/lane-snapshot-publish.log" "$T/skips.log" 2>/dev/null || : > "$T/skips.log"

out=$(publish shim); rc=$?
case "$rc:$out" in 0:published*) ok "S2 shimmed publish rc 0" ;; *) bad "S2 shimmed publish rc=$rc: $out" ;; esac
READ=$(grep -E '^builds/[^/]+$' "$T/find.log" | LC_ALL=C sort -u)
NREAD=$(printf '%s' "$READ" | grep -c .)
[ "$READ" = "$WANT_READ" ] && ok "S2 find ran on only the 8 dirs that are in, to list them ($NREAD of 1,009 record dirs; no age fork)" \
  || bad "S2 the run read $NREAD dirs; unexpected: $(LC_ALL=C comm -13 <(printf '%s\n' "$WANT_READ") <(printf '%s\n' "$READ") | head -3 | tr '\n' ' ') missing: $(LC_ALL=C comm -23 <(printf '%s\n' "$WANT_READ") <(printf '%s\n' "$READ") | tr '\n' ' ')"
grep -qE '^builds/(p2-|mq-)' "$T/find.log" && bad "S2 another project's or a non-record dir was read" || ok "S2 p2 and mq- dirs never read"
grep -qxF "builds/p1-BH-9001-old" "$T/find.log" && bad "S2 an old no-time dir cost a find fork" \
  || ok "S2 an old dir with no time in its name costs no find fork"

# ============================================================================
echo "S3: the snapshot content"
GOT=$(members)
# Plus the lane's @lines copy of logs/merge-conductor.log, which always rides.
WANT=$( { for d in $WANT_IN; do printf 'builds/%s\nbuilds/%s/RESULT\nbuilds/%s/job.json\n' "$d" "$d" "$d"; done
          echo logs/merge-conductor.log; } | LC_ALL=C sort)
[ "$GOT" = "$WANT" ] && ok "S3 the snapshot holds exactly the 8 in-window dirs (the 200-day name written yesterday too), their record files and the @lines log" \
  || bad "S3 snapshot differs: extra $(LC_ALL=C comm -13 <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") | head -3 | tr '\n' ' ') missing $(LC_ALL=C comm -23 <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") | head -3 | tr '\n' ' ')"
first_old=""; for f in "$R"/builds/p1-BH-4-*; do first_old="${f##*/}"; break; done
SK=$(sed -E 's/^[0-9-]+ [0-9:]+Z //' "$T/skips.log")
grep -qxF "lane-snapshot-publish: skip p1 builds/$first_old (record dir older than lane_snapshot.builds_days=30)" <<<"$SK" \
  && ok "S3 a name-skipped dir logs the same skip line" || bad "S3 no skip line for $first_old"
grep -qxF "lane-snapshot-publish: skip p1 builds/p1-BH-9001-old (record dir older than lane_snapshot.builds_days=30)" <<<"$SK" \
  && ok "S3 an mtime-skipped dir logs its skip line" || bad "S3 no skip line for p1-BH-9001-old"
NSK=$(printf '%s\n' "$SK" | grep -c 'record dir older')
[ "$NSK" = 1002 ] && ok "S3 1,002 skip lines (1,000 old + 9001 + 9003)" || bad "S3 $NSK skip lines"
out=$(publish); [ "$(grep -c 'record dir older' "$R/logs/lane-snapshot-publish.log")" = "$NSK" ] \
  && ok "S3 a second run logs no repeat skip line" || bad "S3 a second run repeated skip lines"

rc=$( set -o pipefail; export HARNESS="$R"; . "$R/bin/lib/lane-run-inputs.sh"; _lri_list p3 ro 30 >/dev/null; echo $? )
[ "$rc" = 0 ] && ok "S3 a project with no record dir lists rc 0 under pipefail" || bad "S3 empty match under pipefail rc=$rc"
LEFT=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'lri-age.*' -newer "$R/bin/lib/lane-run-inputs.sh" 2>/dev/null | head -1)
[ -z "$LEFT" ] && ok "S3 the age reference file is removed" || bad "S3 left behind: $LEFT"

# ============================================================================
echo "S4: a run longer than its cron period pages once"
P="$T/p"; mkdir -p "$P/bin/lib" "$P/logs"
cp "$DIR/bin/lane-snapshot-publish.sh" "$P/bin/"
cat > "$P/bin/jobs-client.sh" <<'EOF'
# shellcheck shell=bash
setting_get() { [ "$1" = lane_snapshot.run_alert_s ] && [ -n "${RUN_ALERT_S:-}" ] && { echo "$RUN_ALERT_S"; return 0; }; return 1; }
EOF
cat > "$P/bin/lib/project-lanes.sh" <<'EOF'
# shellcheck shell=bash
pl_name_ok() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
EOF
cat > "$P/bin/lib/lane-placement.sh" <<'EOF'
# shellcheck shell=bash
lp_decide() { LP_PLACE=hub; LP_WHY="fixture"; }
EOF
cat > "$P/bin/lib/lane-run-inputs.sh" <<'EOF'
# shellcheck shell=bash
lri_apply_pending() { sleep "${APPLY_SLEEP:-0}"; echo "applied=0 conflicts=0 rejected=0"; }
EOF
cat > "$P/bin/lib/alert-line-remote.sh" <<'EOF'
# shellcheck shell=bash
alr_apply() { echo "alert lines: 0 replayed, 0 already applied, ack none"; }
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$P/bin/lane-alert.sh"
chmod +x "$P/bin/"*.sh
LINE_WANT="lane-snapshot-publish: 0 published, 0 unchanged, 0 write-backs applied, 0 conflicts, 0 rejected, 0 failed; blocked-resolver placed hub (fixture); alert lines: 0 replayed, 0 already applied, ack none"
: > "$T/alerts.txt"
out=$(HARNESS="$P" RUN_ALERT_S=1 APPLY_SLEEP=2 bash "$P/bin/lane-snapshot-publish.sh" p1); rc=$?
[ "$rc:$out" = "0:$LINE_WANT" ] && ok "S4 stdout keeps its one-line shape" || bad "S4 rc=$rc stdout: $out"
N=$(grep -c -- '--id lane-snapshot-slow' "$T/alerts.txt")
grep -E -- '^--severity warn --id lane-snapshot-slow-blocked-resolver lane-snapshot-publish .*took [0-9]+s.*lane_snapshot.run_alert_s=1' "$T/alerts.txt" >/dev/null && [ "$N" = 1 ] \
  && ok "S4 a 2s run over run_alert_s=1 pages ONE lane-snapshot-slow-blocked-resolver alert" || bad "S4 alerts: $(cat "$T/alerts.txt")"
tail -1 "$P/logs/lane-snapshot-publish.log" | grep -qE "; blocked-resolver placed hub \(fixture\); .*; run [0-9]+s$" \
  && ok "S4 the log line ends with the run time" || bad "S4 log: $(tail -1 "$P/logs/lane-snapshot-publish.log")"
: > "$T/alerts.txt"
out=$(HARNESS="$P" bash "$P/bin/lane-snapshot-publish.sh" --lane pipeline-health p1); rc=$?
grep -qE -- '^--resolve --id lane-snapshot-slow-pipeline-health lane-snapshot-publish ' "$T/alerts.txt" \
  && ! grep -q -- 'lane-snapshot-slow-blocked-resolver' "$T/alerts.txt" && ! grep -q -- '--severity warn --id lane-snapshot-slow' "$T/alerts.txt" \
  && ok "S4 a short pipeline-health run (no row: 600s) resolves only lane-snapshot-slow-pipeline-health" || bad "S4 short-run alerts: $(cat "$T/alerts.txt")"
: > "$T/alerts.txt"
for v in abc 0; do
out=$(HARNESS="$P" RUN_ALERT_S="$v" APPLY_SLEEP=0 bash "$P/bin/lane-snapshot-publish.sh" p1); rc=$?
grep -q -- '--severity warn --id lane-snapshot-slow' "$T/alerts.txt" && bad "S4 row '$v' paged" || ok "S4 row '$v' falls back to 600s"
: > "$T/alerts.txt"
done

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
