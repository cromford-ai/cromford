#!/bin/bash
# tests/review-prs-tmp-cap-change.bh-6132-test.sh — BH-6132: the review-prs
# /tmp cap event is sent once per cap change, not once per tick. Inside the
# BH-6130 window (REVIEW_TMP_CAPPED_REPORT_S) a cap that DROPS below the last
# reported concurrency is sent again (trigger cap_lowered); the same or a higher
# cap is not. The per-review /tmp need REVIEW_WORKER_TMP_MB is a registry knob.
# The lane runs WHOLE from a scratch harness with its real bin/lib closure (the
# setup of tests/review-prs-tmp.bh-6130-test.sh). Stubbed: gh, df, the jobs
# functions (BASH_ENV), /proc/meminfo, curl (HARNESS_SENTRY_CURL) and
# bin/agent-call.sh. /tmp free: 2048 MB gives concurrency 2, 1700 MB gives 1
# (floor 1536 MB, 256 MB a worker).
#   C0  enough /tmp: concurrency 3, no event, no marker.
#   C1  k=2 at N is sent (trigger window); k=1 at N+60 is sent (trigger
#       cap_lowered, previous_concurrency 2, worker_tmp_mb, top of 3); the
#       marker is `<N+60> 1`; the log line ends `reported (cap_lowered)`.
#   C2  k=1 at N and N+60: one event.
#   C3  k=1 at N, k=2 at N+60: one event; marker still `<N> 1`.
#   C7  then k=1 at N+120: still one event.
#   C4  k=2 at N and N+60: one event.
#   C5  a one-field BH-6130 marker <N-60>, k=1 at N: no event, marker unchanged.
#   C6  a marker `<N-60> abc`, k=1 at N: no event.
#   K1  REVIEW_WORKER_TMP_MB is a registry knob with default 256.
#   K2  REVIEW_WORKER_TMP_MB=512, 2048 MB free: concurrency 1, worker_tmp_mb 512.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-prs-tmp-cap-change.bh-6132-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }

PROJECT=project-1
P2=project-2
HEAD=ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12
NUMS="7"
H="$T/h"
FT="$T/faketmp"
LOG="$H/logs/pr-reviews.log"
MK="$H/state/review-prs-tmp-capped.last"
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

fresh() { # fresh <state-json> — a clean harness and /tmp, three dirs in /tmp
  scratch_rm "$H" 2>/dev/null; scratch_rm "$FT" 2>/dev/null; scratch_rm "$T/sent" 2>/dev/null
  rm -f "$T/tmpfree"
  mkdir -p "$H/bin" "$H/state" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/tmp" "$FT"
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
  for d in a b c; do mkdir -p "$FT/$d"; printf 'x\n' > "$FT/$d/f"; done
}
# run_rp <tag> <now> <free MB> [project] — one whole tick at concurrency 3.
# RP_WTMP, when set, is exported as REVIEW_WORKER_TMP_MB.
run_rp() {
  echo "$3" > "$T/tmpfree"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$SRC/fleet.conf" TEST_ROOT="$T" \
      REPOS_ROOT="$T/no-repos" BASH_ENV="$H/bin/stub.sh" REVIEW_LIVE_CI=0 REVIEW_DEDUPE=0 \
      REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05 TMPDIR="$T/tmp-$1" \
      REVIEW_POOL_TMP_PATH="$FT" REVIEW_POOL_TMP_SWEEP='' REVIEW_CONCURRENCY=3 \
      HARNESS_SENTRY_DSN=https://k-fixture@sentry.invalid/1 HARNESS_SENTRY_CURL="$T/fakebin/curl" \
      SENTRY_MAX_PER_FP_HOUR=6 SENTRY_REPORT_NOW="$2" RP_TMP_REPORT_NOW="$2" LANE_GATE_CACHE_S=0 \
      REVIEW_TMP_CAPPED_MIN_TICKS=1 REVIEW_TMP_TOP_N=3  # BH-9035: these suites pin the first-capped-tick rules
    mkdir -p "$TMPDIR"
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED REVIEW_BOX_MAX REVIEW_TMP_MIN_MB REVIEW_WORKER_TMP_MB \
      REVIEW_TMP_CAPPED_REPORT_S
    [ -n "${RP_WTMP:-}" ] && export REVIEW_WORKER_TMP_MB="$RP_WTMP"
    bash "$H/bin/review-prs.sh" "${4:-$PROJECT}" > "$T/out.$1" 2>&1 )
}
sent() { ls "$T/sent" 2>/dev/null | wc -l | tr -d ' '; }
event() { sed -n 3p "$T/sent/$1"; }
x() { jq -r "$2" <<<"$(event "$1" 2>/dev/null)" 2>/dev/null; }
DONE_ST=$(jq -nc --arg h "$HEAD" '{"7":{sha:$h,verdict:"REQUEST_CHANGES"}}')

# ── C0: enough /tmp ──
fresh "$DONE_ST"
run_rp c0 "$N" 102400
grep -q 'review-prs tick concurrency=3 ' "$LOG" && ok || bad "C0 tick not at concurrency=3: $(grep -E 'tick|capped' "$LOG")"
grep -q 'capped' "$LOG" && bad "C0 capped: $(grep capped "$LOG")" || ok
[ "$(sent)" = 0 ] && ok || bad "C0 events=$(sent) (want 0)"
[ -e "$MK" ] && bad "C0 marker written: $(cat "$MK")" || ok

# ── C1: the cap drops from 2 to 1 inside the window ──
fresh "$DONE_ST"
run_rp c1a "$N" 2048
[ "$(sent)" = 1 ] && ok || bad "C1 first capped tick events=$(sent) (want 1): $(tail -3 "$LOG")"
[ "$(x 1 .extra.trigger)" = window ] && ok || bad "C1 first trigger: $(event 1)"
[ "$(x 1 .extra.concurrency)" = 2 ] && ok || bad "C1 first concurrency: $(event 1)"
[ "$(x 1 .extra.previous_concurrency)" = null ] && ok || bad "C1 first previous_concurrency: $(event 1)"
[ "$(cat "$MK" 2>/dev/null)" = "$N 2" ] && ok || bad "C1 marker after k=2: $(cat "$MK" 2>/dev/null)"
run_rp c1b "$((N + 60))" 1700
[ "$(sent)" = 2 ] && ok || bad "C1 a drop 2 -> 1 was not sent: events=$(sent): $(tail -3 "$LOG")"
[ "$(x 2 .extra.trigger)" = cap_lowered ] && ok || bad "C1 trigger: $(event 2)"
[ "$(x 2 .extra.previous_concurrency)" = 2 ] && ok || bad "C1 previous_concurrency: $(event 2)"
[ "$(x 2 .extra.concurrency)" = 1 ] && ok || bad "C1 concurrency: $(event 2)"
[ "$(x 2 .extra.worker_tmp_mb)" = 256 ] && ok || bad "C1 worker_tmp_mb: $(event 2)"
[ "$(x 2 '.extra.top | length')" = 3 ] && ok || bad "C1 top length: $(event 2)"
[ "$(x 2 .extra.free_mb)" = 1700 ] && ok || bad "C1 free_mb: $(event 2)"
[ "$(cat "$MK" 2>/dev/null)" = "$((N + 60)) 1" ] && ok || bad "C1 marker after the drop: $(cat "$MK" 2>/dev/null)"
grep -qE 'concurrency capped at 1 by .*threshold.*reported \(cap_lowered\)$' "$LOG" && ok \
  || bad "C1 log line: $(grep 'threshold' "$LOG")"
grep -qE 'concurrency capped at 2 by .*threshold.*reported \(window\)$' "$LOG" && ok \
  || bad "C1 first log line: $(grep 'threshold' "$LOG")"

# ── C2: the same cap twice ──
fresh "$DONE_ST"
run_rp c2a "$N" 1700
run_rp c2b "$((N + 60))" 1700
[ "$(sent)" = 1 ] && ok || bad "C2 the same cap was sent twice: events=$(sent)"
grep -q 'review-prs: /tmp capped at 1; not reported, last report .* at concurrency 1 (window 86400s)' "$LOG" && ok \
  || bad "C2 no not-reported line: $(tail -3 "$LOG")"

# ── C3 / C7: a higher cap, then back down to the reported cap ──
fresh "$DONE_ST"
run_rp c3a "$N" 1700
run_rp c3b "$((N + 60))" 2048
[ "$(sent)" = 1 ] && ok || bad "C3 a higher cap was sent: events=$(sent)"
[ "$(cat "$MK" 2>/dev/null)" = "$N 1" ] && ok || bad "C3 marker rewritten on a not-due tick: $(cat "$MK" 2>/dev/null)"
run_rp c7 "$((N + 120))" 1700 "$P2"
[ "$(sent)" = 1 ] && ok || bad "C7 a flap back to the reported cap was sent: events=$(sent)"

# ── C4: k=2 twice ──
fresh "$DONE_ST"
run_rp c4a "$N" 2048
run_rp c4b "$((N + 60))" 2048
[ "$(sent)" = 1 ] && ok || bad "C4 the same cap was sent twice: events=$(sent)"

# ── C5: a BH-6130 one-field marker ──
fresh "$DONE_ST"; echo "$((N - 60))" > "$MK"
run_rp c5 "$N" 1700
[ "$(sent)" = 0 ] && ok || bad "C5 a one-field marker gave an event: events=$(sent)"
[ "$(cat "$MK")" = "$((N - 60))" ] && ok || bad "C5 marker changed: $(cat "$MK")"

# ── C6: a garbage concurrency in the marker ──
fresh "$DONE_ST"; echo "$((N - 60)) abc" > "$MK"
run_rp c6 "$N" 1700
[ "$(sent)" = 0 ] && ok || bad "C6 a garbage concurrency gave an event: events=$(sent)"
fresh "$DONE_ST"; echo "$((N - 60)) 0" > "$MK"
run_rp c6z "$N" 1700
[ "$(sent)" = 0 ] && ok || bad "C6 a zero concurrency gave an event: events=$(sent)"

# ── K1: the registry row ──
[ "$(jq -r '.knobs[] | select(.env == "REVIEW_WORKER_TMP_MB") | .default' "$SRC/catalog/lanes.d/review-prs.json")" = 256 ] \
  && ok || bad "K1 REVIEW_WORKER_TMP_MB is not a registry knob with default 256"

# ── K2: the knob sizes the cap and the payload ──
fresh "$DONE_ST"
RP_WTMP=512 run_rp k2 "$N" 2048
grep -q 'review-prs tick concurrency=1 ' "$LOG" && ok || bad "K2 tick not at concurrency=1: $(grep -E 'tick|capped' "$LOG")"
grep -q 'concurrency capped at 1 by' "$LOG" && ok || bad "K2 no capped line: $(grep capped "$LOG")"
[ "$(x 1 .extra.worker_tmp_mb)" = 512 ] && ok || bad "K2 worker_tmp_mb: $(event 1)"

echo "review-prs-tmp-cap-change.bh-6132: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
