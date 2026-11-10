#!/bin/bash
# tests/review-prs-tmp-streak.bh-9035-test.sh — BH-9035: the review-prs /tmp
# cap event is sent only after REVIEW_TMP_CAPPED_MIN_TICKS (default 3)
# consecutive capped ticks on the box, and it carries the REVIEW_TMP_TOP_N
# (default 5) largest /tmp entries. The streak is state/review-prs-tmp-capped.streak
# (`<count> <first_epoch>`), box-wide, under the marker's lock. A tick that
# measures free /tmp at or above the threshold resets it (rp_tmp_episode_end).
# The lane runs WHOLE from a scratch harness with its real bin/lib closure, the
# setup of tests/review-prs-tmp-episode.bh-6133-test.sh.
#   T1  min unset: tick 1 sends nothing, logs `capped tick 1 of 3`, streak 1, no marker.
#   T2  tick 2 sends nothing; tick 3 sends 1 event with capped_ticks 3, min_ticks 3.
#   T3  tick 4 in the window: still 1 event, `not reported, last report`.
#   T4  2 capped, 1 recovered tick (streak gone, `capped-tick streak reset`,
#       no `cap episode ended`), 2 capped: 0; 3rd: 1. T4b: with a marker the
#       recovered tick logs `cap episode ended` only.
#   T5  a REVIEW_BOX_MAX=1 tick between /tmp caps neither bumps nor resets.
#   T6  REVIEW_TMP_CAPPED_MIN_TICKS=1: the first capped tick sends.
#   T7  REVIEW_TMP_CAPPED_MIN_TICKS=abc and 0 behave as 3.
#   T8  6 dirs: the event top has the 5 largest in size order; TOP_N=2 -> 2; 0 -> 5.
#   T9  two projects on one box add to one streak.
#   T10 static: the knob rows and their named fallbacks; threshold_mb is a knob read.
#   T11 bin/tmp-sweep.sh removes a dir older than MIN_AGE_MIN, keeps a fresh one.
#   T12 bin/tmp-sweep.sh --dry-run removes nothing and lists what it would remove.
#   T13 the streak cannot be written: `tmp streak not counted`, the window rule sends.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-prs-tmp-streak.bh-9035-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset REVIEW_BOX_MAX REVIEW_TMP_MIN_MB REVIEW_WORKER_TMP_MB REVIEW_TMP_CAPPED_REPORT_S \
      REVIEW_TMP_CAPPED_MIN_TICKS REVIEW_TMP_TOP_N MIN_AGE_MIN

PROJECT=project-1
P2=project-2
HEAD=ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12
H="$T/h"
FT="$T/faketmp"
LOG="$H/logs/pr-reviews.log"
MK="$H/state/review-prs-tmp-capped.last"
# The marker is `<epoch> <concurrency>` since BH-6132; the episode checks read the epoch.
mk_epoch() { local e _; read -r e _ < "$MK" 2>/dev/null; printf %s "$e"; }
ST="$H/state/review-prs-tmp-capped.streak"
streak() { local c="" _; [ -f "$ST" ] && read -r c _ < "$ST"; printf %s "$c"; }
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
# df: nothing at all while $T/dfnone exists; else $T/tmpfree MB, else 102400.
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
[ -e "$T/dfnone" ] && exit 1
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
chmod +x "$T/fakebin/gh" "$T/fakebin/df" "$T/fakebin/curl"
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

# Every PR is already reviewed at its head, so no agent runs; the stub answers
# a static review if one does.
write_agent() {
  cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
printf 'claude\n' > "$5.runner"; printf 'claude-fable-5-1\n' > "$5.model"
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$5"
exit 0
EOF
  chmod +x "$H/bin/agent-call.sh"
}

DONE_ST=$(jq -nc --arg h "$HEAD" '{"7":{sha:$h,verdict:"REQUEST_CHANGES"}}')
fresh() { # a clean harness and /tmp, PR #7 already reviewed at its head
  scratch_rm "$H" 2>/dev/null; scratch_rm "$FT" 2>/dev/null; scratch_rm "$T/sent" 2>/dev/null
  rm -f "$T/dfnone" "$T/tmpfree"
  mkdir -p "$H/bin" "$H/state" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/tmp" "$FT"
  mkdir -p "$H/catalog/lanes.d"; cp "$SRC/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
  cp "$SRC/bin/review-prs.sh" "$SRC/bin/fleet-conf.sh" "$H/bin/"
  scratch_install_closure bin/review-prs.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
  mrs_fixture "$H" "$PROJECT" "$P2"
  cp "$T/stub.sh" "$H/bin/stub.sh"
  for b in beat.sh deploy-request.sh merge-queue.sh alert-line.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$b"; chmod +x "$H/bin/$b"; done
  write_agent
  printf '%s\n' "$DONE_ST" > "$H/state/$PROJECT.pr-reviews.json"
  printf '%s\n' "$DONE_ST" > "$H/state/$P2.pr-reviews.json"
  jq -nc --arg h "$HEAD" '[{number:7, head:{sha:$h,ref:"feature"}, base:{ref:"main"},
       user:{login:"externaldev",type:"User"}, title:"Test PR 7", draft:false, state:"open", labels:[]}]' > "$T/prs.json"
}
# run_rp <tag> [project] — one tick at RP_TMP_REPORT_NOW (default $N). The
# lane's own env (REVIEW_CONCURRENCY, REVIEW_BOX_MAX, RP_SWEEP = the
# REVIEW_POOL_TMP_SWEEP path, empty = off) passes through. rc is the tick's.
run_rp() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$SRC/fleet.conf" TEST_ROOT="$T" \
      REPOS_ROOT="$T/no-repos" BASH_ENV="$H/bin/stub.sh" REVIEW_LIVE_CI=0 REVIEW_DEDUPE=0 \
      REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05 TMPDIR="$T/tmp-$1" \
      REVIEW_POOL_TMP_PATH="$FT" REVIEW_POOL_TMP_SWEEP="${RP_SWEEP-}" \
      HARNESS_SENTRY_DSN=https://k-fixture@sentry.invalid/1 HARNESS_SENTRY_CURL="$T/fakebin/curl" \
      SENTRY_MAX_PER_FP_HOUR=6 SENTRY_REPORT_NOW="${RP_TMP_REPORT_NOW:-$N}" \
      RP_TMP_REPORT_NOW="${RP_TMP_REPORT_NOW:-$N}" LANE_GATE_CACHE_S=0
    mkdir -p "$TMPDIR"
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED
    bash "$H/bin/review-prs.sh" "${2:-$PROJECT}" > "$T/out.$1" 2>&1 )
}
sent() { ls "$T/sent" 2>/dev/null | wc -l | tr -d ' '; }
event() { sed -n 3p "$T/sent/$1"; }
capped() { echo 1700 > "$T/tmpfree"; }


# ── T1: min unset (fallback 3): tick 1 sends nothing ──
fresh; capped
REVIEW_CONCURRENCY=3 run_rp t1
[ "$(sent)" = 0 ] && ok || bad "T1 tick 1 sent: events=$(sent) $(tail -2 "$LOG")"
grep -q 'review-prs: /tmp capped at 1; capped tick 1 of 3, not reported' "$LOG" && ok || bad "T1 no 'capped tick 1 of 3' line: $(tail -3 "$LOG")"
[ "$(streak)" = 1 ] && ok || bad "T1 streak: '$(cat "$ST" 2>/dev/null)' (want 1)"
[ -e "$MK" ] && bad "T1 the window marker was claimed below the streak: $(cat "$MK")" || ok

# ── T2: tick 2 nothing, tick 3 one event ──
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=3 run_rp t2a
[ "$(sent)" = 0 ] && ok || bad "T2 tick 2 sent: events=$(sent)"
grep -q 'capped tick 2 of 3, not reported' "$LOG" && ok || bad "T2 no 'capped tick 2 of 3' line"
RP_TMP_REPORT_NOW=$((N + 120)) REVIEW_CONCURRENCY=3 run_rp t2b
[ "$(sent)" = 1 ] && ok || bad "T2 tick 3 events=$(sent) (want 1): $(tail -2 "$LOG")"
EV=$(event 1 2>/dev/null)
[ "$(jq -r '.extra.capped_ticks' <<<"$EV" 2>/dev/null)" = 3 ] && ok || bad "T2 capped_ticks: $(jq -c .extra <<<"$EV" 2>/dev/null)"
[ "$(jq -r '.extra.min_ticks' <<<"$EV" 2>/dev/null)" = 3 ] && ok || bad "T2 min_ticks: $(jq -c .extra <<<"$EV" 2>/dev/null)"
[ "$(jq -r '.tags.reason // empty' <<<"$EV" 2>/dev/null)" = review-prs-tmp-capped ] && ok || bad "T2 tags.reason: $(jq -c .tags <<<"$EV" 2>/dev/null)"
[ "$(jq -r '.extra.threshold_mb' <<<"$EV" 2>/dev/null)" = 2304 ] && ok || bad "T10 threshold_mb with the knobs unset: $(jq -c .extra <<<"$EV" 2>/dev/null)"
[ "$(mk_epoch)" = "$((N + 120))" ] && ok || bad "T2 marker: '$(cat "$MK" 2>/dev/null)'"

# ── T3: tick 4 inside the window: still 1 event ──
RP_TMP_REPORT_NOW=$((N + 180)) REVIEW_CONCURRENCY=3 run_rp t3
[ "$(sent)" = 1 ] && ok || bad "T3 tick 4 events=$(sent) (want 1)"
grep -q 'review-prs: /tmp capped at 1; not reported, last report' "$LOG" && ok || bad "T3 no window line: $(tail -2 "$LOG")"
[ "$(streak)" = 4 ] && ok || bad "T3 streak: '$(cat "$ST" 2>/dev/null)' (want 4)"

# ── T4: a recovered tick resets the streak ──
fresh; capped
REVIEW_CONCURRENCY=3 run_rp t4a
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=3 run_rp t4b
[ "$(streak)" = 2 ] && ok || bad "T4 setup streak: '$(cat "$ST" 2>/dev/null)' (want 2)"
echo 102400 > "$T/tmpfree"
RP_TMP_REPORT_NOW=$((N + 120)) REVIEW_CONCURRENCY=3 run_rp t4r
[ -e "$ST" ] && bad "T4 the streak survived a recovered tick: $(cat "$ST")" || ok
[ -e "$MK" ] && bad "T4 a marker after a recovered tick: $(cat "$MK")" || ok
[ "$(grep -c 'review-prs: /tmp recovered (102400MB free, threshold 2304MB); capped-tick streak reset' "$LOG")" = 1 ] && ok \
  || bad "T4 no streak-reset line for a streak with no marker: $(tail -2 "$LOG")"
grep -q 'cap episode ended' "$LOG" && bad "T4 an episode-ended line with no marker (BH-6133 EP2 rule)" || ok
capped
RP_TMP_REPORT_NOW=$((N + 180)) REVIEW_CONCURRENCY=3 run_rp t4c
RP_TMP_REPORT_NOW=$((N + 240)) REVIEW_CONCURRENCY=3 run_rp t4d
[ "$(sent)" = 0 ] && ok || bad "T4 2 capped ticks after the reset sent: events=$(sent)"
RP_TMP_REPORT_NOW=$((N + 300)) REVIEW_CONCURRENCY=3 run_rp t4e
[ "$(sent)" = 1 ] && ok || bad "T4 the 3rd capped tick after the reset: events=$(sent) (want 1)"

# T4b: a recovered tick after a report (marker set) is the episode end, not a streak reset.
fresh; capped
REVIEW_TMP_CAPPED_MIN_TICKS=1 REVIEW_CONCURRENCY=3 run_rp t4ba
echo 102400 > "$T/tmpfree"
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=3 run_rp t4bb
[ ! -e "$ST" ] && [ ! -e "$MK" ] && ok || bad "T4b marker or streak survived recovery: $(ls "$H/state")"
[ "$(grep -c 'cap episode ended' "$LOG")" = 1 ] && ok || bad "T4b no episode-ended line: $(tail -2 "$LOG")"
grep -q 'capped-tick streak reset' "$LOG" && bad "T4b a streak-reset line next to the episode end" || ok

# ── T5: a tick capped by REVIEW_BOX_MAX with /tmp still low neither bumps nor resets ──
fresh; capped
REVIEW_CONCURRENCY=3 run_rp t5a
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=3 run_rp t5b
RP_TMP_REPORT_NOW=$((N + 120)) REVIEW_BOX_MAX=1 REVIEW_CONCURRENCY=3 run_rp t5c
grep -q 'concurrency capped at 1 by REVIEW_BOX_MAX=1' "$LOG" && ok || bad "T5 setup: box_max did not cap: $(tail -2 "$LOG")"
[ "$(streak)" = 2 ] && ok || bad "T5 streak after a box_max tick: '$(cat "$ST" 2>/dev/null)' (want 2)"
[ "$(sent)" = 0 ] && ok || bad "T5 events before the 3rd /tmp tick: $(sent)"
RP_TMP_REPORT_NOW=$((N + 180)) REVIEW_CONCURRENCY=3 run_rp t5d
[ "$(sent)" = 1 ] && ok || bad "T5 3rd /tmp-capped tick events=$(sent) (want 1)"
[ "$(jq -r '.extra.capped_ticks' <<<"$(event 1 2>/dev/null)" 2>/dev/null)" = 3 ] && ok || bad "T5 capped_ticks: $(event 1 2>/dev/null | jq -c .extra 2>/dev/null)"

# ── T6: min 1 reports on the first capped tick ──
fresh; capped
REVIEW_TMP_CAPPED_MIN_TICKS=1 REVIEW_CONCURRENCY=3 run_rp t6
[ "$(sent)" = 1 ] && ok || bad "T6 min_ticks=1 first tick events=$(sent) (want 1): $(tail -2 "$LOG")"
[ "$(jq -r '.extra.min_ticks' <<<"$(event 1 2>/dev/null)" 2>/dev/null)" = 1 ] && ok || bad "T6 min_ticks in the event"

# ── T7: garbage and 0 fall back to 3 ──
for v in abc 0; do
  fresh; capped
  REVIEW_TMP_CAPPED_MIN_TICKS=$v REVIEW_CONCURRENCY=3 run_rp "t7$v"
  [ "$(sent)" = 0 ] && ok || bad "T7 min_ticks=$v tick 1 sent: events=$(sent)"
  grep -q 'capped tick 1 of 3, not reported' "$LOG" && ok || bad "T7 min_ticks=$v is not 3: $(tail -2 "$LOG")"
done

# ── T8: the event carries the REVIEW_TMP_TOP_N largest /tmp entries ──
mkmb() { mkdir -p "$FT/$1"; head -c $(($2 * 1048576)) /dev/zero > "$FT/$1/blob"; sync "$FT/$1/blob" 2>/dev/null; }
top_names() { jq -r '[.extra.top[].path | split("/") | last] | join(",")' <<<"$(event 1 2>/dev/null)" 2>/dev/null; }
for spec in ":d6,d5,d4,d3,d2" "2:d6,d5" "0:d6,d5,d4,d3,d2"; do
  n=${spec%%:*}; want=${spec#*:}
  fresh; capped
  mkmb d6 12; mkmb d5 10; mkmb d4 8; mkmb d3 6; mkmb d2 4; mkmb d1 2
  REVIEW_TMP_TOP_N=$n REVIEW_TMP_CAPPED_MIN_TICKS=1 REVIEW_CONCURRENCY=3 run_rp "t8-$n"
  [ "$(top_names)" = "$want" ] && ok || bad "T8 TOP_N='$n' top: '$(top_names)' (want $want)"
  tl=$(grep -o 'top: [^;]*' "$LOG" | tail -1)
  [ "$(grep -o "$FT/d[0-9] [0-9]*MB" <<<"$tl" | sed "s|$FT/||; s| .*||" | paste -sd,)" = "$want" ] && ok \
    || bad "T8 TOP_N='$n' log top line: $tl (want $want)"
done

# ── T9: two projects on one box share one streak ──
fresh; capped
REVIEW_CONCURRENCY=3 run_rp t9a "$PROJECT"
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=3 run_rp t9b "$P2"
[ "$(sent)" = 0 ] && ok || bad "T9 2 ticks sent: events=$(sent)"
[ "$(streak)" = 2 ] && ok || bad "T9 streak after 2 projects: '$(cat "$ST" 2>/dev/null)'"
RP_TMP_REPORT_NOW=$((N + 120)) REVIEW_CONCURRENCY=3 run_rp t9c "$PROJECT"
[ "$(sent)" = 1 ] && ok || bad "T9 3rd box tick events=$(sent) (want 1)"

# ── T10: knob rows, named fallbacks, threshold from the knobs ──
CAT="$SRC/catalog/lanes.d/review-prs.json"
KD="$SRC/catalog/lanes.d/review-prs.knobs.d"
# A knob is inline in the lane file or its own file in review-prs.knobs.d (BH-4987).
kd() { { jq -c '.knobs[]' "$CAT"; cat "$KD"/*.json; } 2>/dev/null | jq -rs --arg e "$1" '[.[] | select(.env == $e)][0].default // empty' 2>/dev/null; }
[ "$(kd REVIEW_TMP_CAPPED_MIN_TICKS)" = 3 ] && ok || bad "T10 REVIEW_TMP_CAPPED_MIN_TICKS default: '$(kd REVIEW_TMP_CAPPED_MIN_TICKS)'"
[ "$(kd REVIEW_TMP_TOP_N)" = 5 ] && ok || bad "T10 REVIEW_TMP_TOP_N default: '$(kd REVIEW_TMP_TOP_N)'"
[ "$(kd REVIEW_TMP_MIN_MB)" = 1536 ] && ok || bad "T10 REVIEW_TMP_MIN_MB default: '$(kd REVIEW_TMP_MIN_MB)'"
[ "$(kd REVIEW_WORKER_TMP_MB)" = 256 ] && ok || bad "T10 REVIEW_WORKER_TMP_MB default: '$(kd REVIEW_WORKER_TMP_MB)'"
LIB="$SRC/bin/lib/review-prs-tmp.sh"
grep -q 'REVIEW_TMP_CAPPED_MIN_TICKS:-3}.*lane.review-prs.review_tmp_capped_min_ticks' "$LIB" && ok || bad "T10 the min_ticks fallback does not name its row"
grep -q 'REVIEW_TMP_TOP_N:-5}.*lane.review-prs.review_tmp_top_n' "$LIB" && ok || bad "T10 the top_n fallback does not name its row"
fresh; capped
REVIEW_TMP_MIN_MB=1000 REVIEW_TMP_CAPPED_MIN_TICKS=1 REVIEW_CONCURRENCY=3 run_rp t10
[ "$(jq -r '.extra.threshold_mb' <<<"$(event 1 2>/dev/null)" 2>/dev/null)" = 1768 ] && ok \
  || bad "T10 threshold_mb with REVIEW_TMP_MIN_MB=1000: $(event 1 2>/dev/null | jq -c .extra 2>/dev/null) $(tail -2 "$LOG")"

# ── T11 / T12: the existing sweep honours the age knob and --dry-run ──
SW="$T/sw"; SR="$T/sweeproot"; SNOW=1790000000
scratch_install_closure bin/tmp-sweep.sh "$SW" >/dev/null || { echo "FAIL: tmp-sweep closure install failed"; exit 1; }
mkdir -p "$SW/logs" "$SW/flags" "$SW/state" "$SW/env"
printf '#!/bin/bash\nexit 0\n' > "$SW/bin/lane-alert.sh"; chmod +x "$SW/bin/lane-alert.sh"
printf 'job_ledger_put() { :; }\n' > "$SW/bin/jobs-client.sh"
sweep_fx() {
  scratch_rm "$SR" 2>/dev/null; rm -f "$SW/logs/tmp-sweep.log"
  mkdir -p "$SR/rv1/d" "$SR/rv2/d"; printf x > "$SR/rv1/d/f"; printf x > "$SR/rv2/d/f"
  find "$SR/rv1" -exec touch -h -d "@$((SNOW - 300 * 60))" {} +
  find "$SR/rv2" -exec touch -h -d "@$((SNOW - 10 * 60))" {} +
}
sweep() { timeout 120 env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$SW" HARNESS="$SW" HOME="$T" TMP_SWEEP_ROOT="$SR" \
  TMP_SWEEP_NOW="$SNOW" TMP_SWEEP_STOPGAP_FILE="$T/no-stopgap" TMP_SWEEP_PROC="$T/sweepproc" TMP_SWEEP_CLAIMS="$T/sweepclaims" \
  MIN_AGE_MIN=180 bash "$SW/bin/tmp-sweep.sh" "$@"; }
mkdir -p "$T/sweepproc" "$T/sweepclaims"
sweep_fx
sweep > "$T/sweep.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "T11 sweep rc=$rc: $(tail -3 "$T/sweep.out")"
[ -e "$SR/rv1" ] && bad "T11 the 300 min old rv1 is still there: $(cat "$SW/logs/tmp-sweep.log" 2>/dev/null)" || ok
[ -d "$SR/rv2" ] && ok || bad "T11 the fresh rv2 was removed"
sweep_fx
sweep --dry-run > "$T/sweep.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "T12 dry-run rc=$rc"
[ -d "$SR/rv1" ] && [ -d "$SR/rv2" ] && ok || bad "T12 --dry-run removed a dir: $(ls "$SR")"
grep -q "would remove $SR/rv1 " "$T/sweep.out" && ok || bad "T12 no 'would remove .../rv1': $(cat "$T/sweep.out")"
grep -q "would remove $SR/rv2" "$T/sweep.out" && bad "T12 the fresh rv2 is listed" || ok
grep -qE 'tmp-sweep: dry-run .*would_remove=1( |$)' "$SW/logs/tmp-sweep.log" 2>/dev/null && ok \
  || bad "T12 no dry-run summary with would_remove=1: $(cat "$SW/logs/tmp-sweep.log" 2>/dev/null)"

# ── T13: a streak that cannot be written falls back to the window rule ──
fresh; capped
mkdir -p "$ST.tmp/block"
REVIEW_CONCURRENCY=3 run_rp t13
grep -q "review-prs: tmp streak not counted: $ST not writable" "$LOG" && ok || bad "T13 no 'tmp streak not counted' line: $(tail -3 "$LOG")"
[ "$(sent)" = 1 ] && ok || bad "T13 events=$(sent) (want 1: the window rule)"
[ -e "$ST" ] && bad "T13 a streak file was written: $(cat "$ST")" || ok

echo "review-prs-tmp-streak.bh-9035: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
