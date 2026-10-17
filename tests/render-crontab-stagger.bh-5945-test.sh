#!/bin/bash
# tests/render-crontab-stagger.bh-5945-test.sh — BH-5945: merge-queue and
# review-prs start minutes come from each project's fleet.conf cron offset, and
# two projects on one box never share a start minute.
#   ST1 cron_project_block p 3 -> merge-queue 9,29,49 and review-prs 10,40
#   ST2 offset 0 -> 6,26,46 and 7,37 (the lines every project had before)
#   ST3 the same call twice -> byte-identical output
#   ST4 bin/render-crontab.sh small on the real fleet.conf: its 4 projects get
#       4 distinct merge-queue minute sets and 4 distinct review-prs sets
#   ST5 fixture: two projects with offset 3 on one box -> merge-queue 9 then 10,
#       review-prs 10 then 11
#   ST6 fixture: 21 projects with offset 0 on one box -> rc 0 inside 20 s and
#       20 distinct merge-queue first minutes (the 21st reuses its base)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/render-crontab-stagger.bh-5945-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset REGISTRY_SOURCE

# sched <block> <script> <project> — the schedule field (column 1) of that lane's line
sched() { awk -v s="/root/harness/bin/$2.sh" -v p="$3" '$6 == s && $7 == p { print $1 }' <<<"$1"; }
block() { bash -c '. "$1/bin/lib/cron-lines.sh" || exit 1; shift; cron_project_block "$@"' _ "$DIR" "$@"; }

# --- ST1 / ST2 / ST3 ------------------------------------------------------
B=$(block p 3 - "$T")
[ "$(sched "$B" merge-queue p)" = 9,29,49 ] && ok || bad "ST1 merge-queue '$(sched "$B" merge-queue p)' (want 9,29,49): $B"
[ "$(sched "$B" review-prs p)" = 10,40 ] && ok || bad "ST1 review-prs '$(sched "$B" review-prs p)' (want 10,40)"
B0=$(block p 0 - "$T")
[ "$(sched "$B0" merge-queue p)" = 6,26,46 ] && ok || bad "ST2 merge-queue '$(sched "$B0" merge-queue p)' (want 6,26,46)"
[ "$(sched "$B0" review-prs p)" = 7,37 ] && ok || bad "ST2 review-prs '$(sched "$B0" review-prs p)' (want 7,37)"
grep -qxF '6,26,46 * * * * /root/harness/bin/merge-queue.sh p >> /root/harness/logs/merge-queue.log 2>&1' <<<"$B0" && ok || bad "ST2 merge-queue line changed shape: $B0"
[ "$B" = "$(block p 3 - "$T")" ] && ok || bad "ST3 two calls differ"
B23=$(block p 23 - "$T")
[ "$(sched "$B23" merge-queue p)" = 9,29,49 ] && ok || bad "ST1 offset 23 merge-queue '$(sched "$B23" merge-queue p)' (want 9,29,49)"

# --- ST4: the real fleet.conf, box small ----------------------------------
printf '# base\n' > "$T/base"
OUT=$(bash "$DIR/bin/render-crontab.sh" --base "$T/base" small 2>"$T/err"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "ST4 render rc $RC: $(cat "$T/err")"
PS=$(awk '$1 !~ /^#/ && NF >= 6 && $6 == "box-small" { print $1 }' "$DIR/fleet.conf")
[ "$(printf "%s\n" $PS | grep -c .)" -ge 2 ] && ok || bad "ST4 box small has fewer than 2 projects: $PS"
MQ=""; RP=""
for p in $PS; do MQ="$MQ $(sched "$OUT" merge-queue "$p")"; RP="$RP $(sched "$OUT" review-prs "$p")"; done
n=$(printf '%s\n' $PS | wc -l | tr -d ' ')
[ "$(printf '%s\n' $MQ | sort -u | wc -l | tr -d ' ')" = "$n" ] && ok || bad "ST4 merge-queue minutes not distinct over $n projects: $MQ"
[ "$(printf '%s\n' $RP | sort -u | wc -l | tr -d ' ')" = "$n" ] && ok || bad "ST4 review-prs minutes not distinct over $n projects: $RP"
# no two projects share a single minute either (a set like 9,29,49 vs 29,49,9)
[ "$(printf '%s\n' $MQ | tr ',' '\n' | sort | uniq -d | wc -l | tr -d ' ')" = 0 ] && ok || bad "ST4 a merge-queue minute is shared: $MQ"
[ "$(printf '%s\n' $RP | tr ',' '\n' | sort | uniq -d | wc -l | tr -d ' ')" = 0 ] && ok || bad "ST4 a review-prs minute is shared: $RP"

# --- ST5: a collision on one box ------------------------------------------
F="$T/f5"; mkdir -p "$F"
printf 'pa o/a - - 3 box-demo\npb o/b - - 3 box-demo\n' > "$F/fleet.conf"
OUT=$(bash "$DIR/bin/render-crontab.sh" --root "$F" --base "$T/base" demo 2>"$T/err"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "ST5 render rc $RC: $(cat "$T/err")"
[ "$(sched "$OUT" merge-queue pa) $(sched "$OUT" merge-queue pb)" = "9,29,49 10,30,50" ] && ok || bad "ST5 merge-queue '$(sched "$OUT" merge-queue pa) $(sched "$OUT" merge-queue pb)' (want 9,29,49 10,30,50)"
[ "$(sched "$OUT" review-prs pa) $(sched "$OUT" review-prs pb)" = "10,40 11,41" ] && ok || bad "ST5 review-prs '$(sched "$OUT" review-prs pa) $(sched "$OUT" review-prs pb)' (want 10,40 11,41)"
# the run-triage line still uses the raw offset for both
[ "$(grep -c '^3,13,23,33,43,53 \* \* \* \* /root/harness/bin/run-triage.sh p[ab]$' <<<"$OUT")" = 2 ] && ok || bad "ST5 run-triage lines changed: $OUT"

# --- ST6: more projects than minutes --------------------------------------
F="$T/f6"; mkdir -p "$F"; : > "$F/fleet.conf"
for i in $(seq 1 21); do printf 'p%s o/p%s - - 0 box-demo\n' "$i" "$i" >> "$F/fleet.conf"; done
OUT=$(timeout 20 bash "$DIR/bin/render-crontab.sh" --root "$F" --base "$T/base" demo 2>"$T/err"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "ST6 render rc $RC: $(cat "$T/err")"
FIRST=$(for i in $(seq 1 21); do sched "$OUT" merge-queue "p$i" | cut -d, -f1; done)
[ "$(printf '%s\n' "$FIRST" | sort -u | grep -c .)" = 20 ] && ok || bad "ST6 distinct merge-queue first minutes: $(printf '%s\n' "$FIRST" | sort -u | grep -c .) (want 20): $(echo $FIRST)"
[ "$(printf '%s\n' "$FIRST" | tail -1)" = 6 ] && ok || bad "ST6 the 21st project's minute '$(printf '%s\n' "$FIRST" | tail -1)' (want its base, 6)"

echo "render-crontab-stagger.bh-5945: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
