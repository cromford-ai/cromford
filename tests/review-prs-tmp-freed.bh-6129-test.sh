#!/bin/bash
# tests/review-prs-tmp-freed.bh-6129-test.sh — BH-6129: the review-prs tick
# start cleanup (rp_scratch_reap in bin/lib/review-prs-tmp.sh) logs the bytes
# it freed, a /tmp cap is sent once over 10 ticks, and the pool returns to its
# configured concurrency on the first tick after /tmp is free again.
# The lane runs WHOLE from a scratch harness with its real bin/lib closure (the
# setup of tests/review-prs-tmp.bh-6130-test.sh). Stubbed: gh, df, the jobs
# functions (BASH_ENV), /proc/meminfo, curl (HARNESS_SENTRY_CURL) and
# bin/agent-call.sh. /tmp is $T/faketmp (REVIEW_POOL_TMP_PATH); a pid is live
# only when $T/proc/<pid>/cmdline names review-prs.sh (RP_TMP_PROC).
#   F1  one dead scratch dir: removed; the line states `freed <B> bytes` with
#       B = the fixture's `du -sk` x 1024.
#   F2  two dead dirs and one held by a live review-prs.sh: the held dir is
#       kept; `removed 2`; B = the two dead dirs only.
#   F3  du fails on the dead dir: it is still removed; the line says
#       `freed at least 0 bytes (1 dir(s) not measured)`.
#   F4  nothing stale: no `removed` line.
#   S1  10 capped ticks inside the window: one event with free_mb,
#       threshold_mb and concurrency.
#   U1  a capped tick at 1700 MB, then 102400 MB free: tick 2 runs at
#       concurrency=3 with no capped line and no second event.
#   U2  the same with REVIEW_CONCURRENCY=2: tick 2 runs at concurrency=2.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-prs-tmp-freed.bh-6129-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
REALDU=$(command -v du) || { echo "FAIL: du missing"; exit 1; }

PROJECT=project-1
P2=project-2
HEAD=ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12
NUMS="7"
H="$T/h"
FT="$T/faketmp"
LOG="$H/logs/pr-reviews.log"
N=1760000000
mkdir -p "$T/fakebin"
cp "$SRC/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *"/pulls -f state=open"*) case "$*" in *"page=1"|*"page=1 "*) restpr --raw 200 "$(cat "$TEST_ROOT/prs.json")" ;;
      *) restpr --raw 200 '[]' ;; esac ;;
  *"pr diff"*"name-only"*) printf 'f.txt\n' ;;
  *"pr diff"*) printf 'diff --git a/f.txt b/f.txt\n+line 10 CHANGED BY PR\n' ;;
  *"pr view"*"state,mergeStateStatus"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED"}\n' ;;
  *"pr view"*) printf '{"body":"test body","comments":[],"reviews":[]}\n' ;;
  *"pr review"*|*"pr comment"*) : ;;
  *actions/runs*) printf '{"s":"completed","c":"success","n":"CI"}\n' ;;
  *) : ;;
esac
exit 0
STUB
# df: $T/tmpfree MB free, else 102400.
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
mb=\$(cat "$T/tmpfree" 2>/dev/null || echo 102400)
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 999999999 1 %s 1%% /tmp\n' "\$((mb * 1024))"
EOF
# curl: every envelope saved as $T/sent/<n>, answers 200.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
cat > /dev/null
out=""; body=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift ;; --data-binary) body="\${2#@}"; shift ;; esac
  shift
done
mkdir -p "$T/sent"; n=\$(( \$(ls "$T/sent" | wc -l) + 1 ))
[ -n "\$body" ] && cp "\$body" "$T/sent/\$n"
[ -n "\$out" ] && : > "\$out"
printf 200
EOF
# du (F3 only, on PATH through $T/dufail): exits 1 for a scratch dir.
mkdir -p "$T/dufail"
cat > "$T/dufail/du" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in "$FT"/review-prs-wk-*) exit 1 ;; esac; done
exec "$REALDU" "\$@"
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/df" "$T/fakebin/curl" "$T/dufail/du"
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$T/meminfo"
cat > "$T/stub.sh" <<EOF
job_lane_open() { JOB_ID="job-\$2"; export JOB_ID; return 0; }
job_lane_close() { JOB_ID=""; export JOB_ID; return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
job_heartbeat() { return 0; }
job_update() { return 0; }
job_phase_open() { return 0; }
job_verdict_rebind() { return 0; }
EOF

fresh() { # fresh <state-json> — a clean harness, /tmp and fake /proc
  scratch_rm "$H" 2>/dev/null; scratch_rm "$FT" 2>/dev/null; scratch_rm "$T/sent" 2>/dev/null
  scratch_rm "$T/proc" 2>/dev/null
  rm -f "$T/tmpfree"
  mkdir -p "$H/bin" "$H/state" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/tmp" "$FT" "$T/proc"
  mkdir -p "$H/catalog/lanes.d"; cp "$SRC/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
  cp "$SRC/bin/review-prs.sh" "$SRC/bin/fleet-conf.sh" "$H/bin/"
  scratch_install_closure bin/review-prs.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
  mrs_fixture "$H" "$PROJECT" "$P2"
  cp "$T/stub.sh" "$H/bin/stub.sh"
  for b in beat.sh deploy-request.sh merge-queue.sh alert-line.sh agent-call.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$H/bin/$b"; chmod +x "$H/bin/$b"
  done
  printf '%s\n' "$1" > "$H/state/$PROJECT.pr-reviews.json"
  printf '%s\n' "$1" > "$H/state/$P2.pr-reviews.json"
  jq -nc --arg h "$HEAD" --arg ns "$NUMS" '[$ns | split(" ")[] | tonumber
    | {number:., head:{sha:$h,ref:"feature"}, base:{ref:"main"}, user:{login:"externaldev",type:"User"},
       title:"Test PR \(.)", draft:false, state:"open", labels:[]}]' > "$T/prs.json"
}
# run_rp <tag> <now> <free MB> — one whole tick. REVIEW_CONCURRENCY (default
# 3), REVIEW_TMP_CAPPED_REPORT_S and RP_PATH_PRE (a dir put first on PATH)
# pass through.
run_rp() {
  echo "$3" > "$T/tmpfree"
  ( export PATH="${RP_PATH_PRE:+$RP_PATH_PRE:}$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$SRC/fleet.conf" \
      TEST_ROOT="$T" REPOS_ROOT="$T/no-repos" BASH_ENV="$H/bin/stub.sh" REVIEW_LIVE_CI=0 REVIEW_DEDUPE=0 \
      REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05 TMPDIR="$T/tmp-$1" \
      REVIEW_POOL_TMP_PATH="$FT" REVIEW_POOL_TMP_SWEEP='' REVIEW_CONCURRENCY="${REVIEW_CONCURRENCY:-3}" \
      RP_TMP_PROC="$T/proc" REVIEW_TMP_CAPPED_REPORT_S="${REVIEW_TMP_CAPPED_REPORT_S:-86400}" \
      HARNESS_SENTRY_DSN=https://k-fixture@sentry.invalid/1 HARNESS_SENTRY_CURL="$T/fakebin/curl" \
      SENTRY_MAX_PER_FP_HOUR=6 SENTRY_REPORT_NOW="$2" RP_TMP_REPORT_NOW="$2" LANE_GATE_CACHE_S=0 \
      REVIEW_TMP_CAPPED_MIN_TICKS=1  # BH-9035: these suites pin the first-capped-tick rules
    mkdir -p "$TMPDIR"
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED REVIEW_BOX_MAX REVIEW_TMP_MIN_MB REVIEW_WORKER_TMP_MB
    bash "$H/bin/review-prs.sh" "$PROJECT" > "$T/out.$1" 2>&1 )
}
sent() { ls "$T/sent" 2>/dev/null | wc -l | tr -d ' '; }
event() { sed -n 3p "$T/sent/$1"; }
# mkwk <pid> <KiB>... — $FT/review-prs-wk-<pid> holding one file per size. The
# sync makes the blocks count now: with delayed allocation du reads an
# unflushed file as near 0.
mkwk() {
  local d="$FT/review-prs-wk-$1" i=0 kb; shift
  mkdir -p "$d/pr7"
  for kb in "$@"; do
    i=$((i + 1)); head -c "$((kb * 1024))" /dev/zero > "$d/pr7/f$i"
  done
  sync "$d"/pr7/f* 2>/dev/null || sync
}
# bytes <dir>... — the du -sk sum of the dirs, x 1024.
bytes() { "$REALDU" -sk -- "$@" | awk '{ s += $1 } END { print s * 1024 }'; }
# A pid with no $T/proc entry is dead to the reap; a live one names review-prs.sh.
D1=4242401; D2=4242402; LIVE=4242420
DONE_ST=$(jq -nc --arg h "$HEAD" '{"7":{sha:$h,verdict:"REQUEST_CHANGES"}}')

# ── F1: one dead scratch dir ──
fresh "$DONE_ST"
mkwk "$D1" 1024 4
B=$(bytes "$FT/review-prs-wk-$D1")
run_rp f1 "$N" 102400
[ -e "$FT/review-prs-wk-$D1" ] && bad "F1 the dead dir is still there" || ok
L=$(grep 'stale scratch dir' "$LOG")
case "$L" in
  *"] review-prs: removed 1 stale scratch dir(s) under $FT, freed $B bytes") ok ;;
  *) bad "F1 line (want freed $B bytes): ${L:-none}" ;;
esac
[ "$B" -ge 1052672 ] && ok || bad "F1 setup: the fixture measured $B bytes, under 1 MiB + 4 KiB"

# ── F2: two dead dirs and one held by a live review-prs.sh ──
fresh "$DONE_ST"
mkwk "$D1" 1024; mkwk "$D2" 2048; mkwk "$LIVE" 3072
mkdir -p "$T/proc/$LIVE"; printf 'bash\0bin/review-prs.sh\0x\0' > "$T/proc/$LIVE/cmdline"
B=$(bytes "$FT/review-prs-wk-$D1" "$FT/review-prs-wk-$D2")
run_rp f2 "$N" 102400
[ -f "$FT/review-prs-wk-$LIVE/pr7/f1" ] && ok || bad "F2 the held dir or its file was removed"
[ -e "$FT/review-prs-wk-$D1" ] || [ -e "$FT/review-prs-wk-$D2" ] && bad "F2 a dead dir is still there: $(ls "$FT")" || ok
L=$(grep 'stale scratch dir' "$LOG")
case "$L" in
  *"review-prs: removed 2 stale scratch dir(s) under $FT, freed $B bytes") ok ;;
  *) bad "F2 line (want removed 2, freed $B bytes): ${L:-none}" ;;
esac

# ── F3: du fails on the dead dir ──
fresh "$DONE_ST"
mkwk "$D1" 1024
RP_PATH_PRE="$T/dufail" run_rp f3 "$N" 102400
[ -e "$FT/review-prs-wk-$D1" ] && bad "F3 the dead dir is still there" || ok
L=$(grep 'stale scratch dir' "$LOG")
case "$L" in
  *"review-prs: removed 1 stale scratch dir(s) under $FT, freed at least 0 bytes (1 dir(s) not measured)") ok ;;
  *) bad "F3 line: ${L:-none}" ;;
esac
grep -q 'review-prs tick concurrency=3 ' "$LOG" && ok || bad "F3 the tick did not run: $(tail -3 "$LOG")"

# ── F4: nothing stale ──
fresh "$DONE_ST"
mkwk "$LIVE" 4
mkdir -p "$T/proc/$LIVE"; printf 'bash\0bin/review-prs.sh\0' > "$T/proc/$LIVE/cmdline"
run_rp f4 "$N" 102400
grep -q 'removed .* stale scratch' "$LOG" && bad "F4 a removed line with nothing stale: $(grep removed "$LOG")" || ok
grep -q 'review-prs tick concurrency=3 ' "$LOG" && ok || bad "F4 the tick did not run: $(tail -3 "$LOG")"

# ── S1: 10 capped ticks inside the window ──
fresh "$DONE_ST"
for i in 0 1 2 3 4 5 6 7 8 9; do run_rp "s1-$i" "$((N + i * 60))" 1700; done
[ "$(sent)" = 1 ] && ok || bad "S1 10 capped ticks sent $(sent) events (want 1)"
[ "$(grep -c 'review-prs tick concurrency=1 ' "$LOG")" = 10 ] && ok || bad "S1 not 10 ticks at concurrency=1: $(grep -c 'tick concurrency' "$LOG")"
EV=$(event 1 2>/dev/null)
[ "$(jq -r '.extra.free_mb' <<<"$EV" 2>/dev/null)" = 1700 ] && ok || bad "S1 free_mb: $EV"
[ "$(jq -r '.extra.threshold_mb' <<<"$EV" 2>/dev/null)" = 2304 ] && ok || bad "S1 threshold_mb: $EV"
[ "$(jq -r '.extra.concurrency' <<<"$EV" 2>/dev/null)" = 1 ] && ok || bad "S1 concurrency: $EV"

# ── U1 / U2: free space returns, the next tick runs at the configured value ──
for want in 3 2; do
  fresh "$DONE_ST"
  REVIEW_CONCURRENCY=$want run_rp "u$want-a" "$N" 1700
  grep -q 'concurrency capped at 1 by' "$LOG" && ok || bad "U($want) tick 1 not capped: $(grep -E 'tick|capped' "$LOG")"
  grep -q 'review-prs tick concurrency=1 ' "$LOG" && ok || bad "U($want) tick 1 not at concurrency=1: $(grep tick "$LOG")"
  before=$(wc -l < "$LOG")
  REVIEW_CONCURRENCY=$want run_rp "u$want-b" "$((N + 60))" 102400
  T2=$(tail -n +"$((before + 1))" "$LOG")
  grep -q "review-prs tick concurrency=$want " <<<"$T2" && ok || bad "U($want) tick 2 not at concurrency=$want: $(grep tick <<<"$T2")"
  grep -q 'capped' <<<"$T2" && bad "U($want) tick 2 still capped: $(grep capped <<<"$T2")" || ok
  [ "$(sent)" = 1 ] && ok || bad "U($want) events=$(sent) (want 1)"
done

echo "review-prs-tmp-freed.bh-6129: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
