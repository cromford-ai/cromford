#!/bin/bash
# tests/review-prs-tmp-episode.bh-6133-test.sh — BH-6133: the review-prs /tmp
# cap is reported to Sentry once per cap EPISODE (and again each
# REVIEW_TMP_CAPPED_REPORT_S while it lasts), and the event carries the count
# of review-prs dirs in /tmp. An episode ends when a tick measures free /tmp at
# or above TMP_MIN_MB + 3 x WORKER_TMP_MB (rp_tmp_episode_end removes the
# marker state/review-prs-tmp-capped.last). The lane runs WHOLE from a scratch
# harness with its real bin/lib closure, the setup of
# tests/review-prs-tmp.bh-6130-test.sh. Stubbed: gh, df ($T/tmpfree, or
# $T/dfnone for an unreadable df), the jobs functions (BASH_ENV),
# /proc/meminfo, curl (HARNESS_SENTRY_CURL) and bin/agent-call.sh.
#   EP1  a capped tick sends 1 event and writes the marker.
#   EP2  capped -> recovered (marker gone, `cap episode ended`) -> capped at
#        +60s: 2 events. (AT4)
#   EP3  10 capped ticks at +0..+540s: exactly 1 event. (AT3)
#   EP4  a tick not capped by tmp (REVIEW_CONCURRENCY=1, or REVIEW_BOX_MAX=1)
#        while /tmp is still under the threshold keeps the marker: no new event.
#   EP5  df unreadable: the marker is kept and the tick exits 0.
#   EP6  free exactly at the threshold (2304) ends the episode.
#   EP7  lane start with the real bin/tmp-sweep.sh: a review-prs dir 4 h old is
#        removed, a fresh one is kept. (AT2)
#   CT1  the event's extra.review_prs_dirs counts real review-prs-* dirs (3),
#        not a symlink or a non-harness dir, next to free_mb and threshold_mb.
#   CT2  no review-prs dirs: review_prs_dirs is 0. (AT5)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-prs-tmp-episode.bh-6133-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset REVIEW_BOX_MAX REVIEW_TMP_MIN_MB REVIEW_WORKER_TMP_MB REVIEW_TMP_CAPPED_REPORT_S

PROJECT=project-1
P2=project-2
HEAD=ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12
H="$T/h"
FT="$T/faketmp"
LOG="$H/logs/pr-reviews.log"
MK="$H/state/review-prs-tmp-capped.last"
# The marker is `<epoch> <concurrency>` since BH-6132; the episode checks read the epoch.
mk_epoch() { local e _; read -r e _ < "$MK" 2>/dev/null; printf %s "$e"; }
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
      RP_TMP_REPORT_NOW="${RP_TMP_REPORT_NOW:-$N}" LANE_GATE_CACHE_S=0 \
      REVIEW_TMP_CAPPED_MIN_TICKS=1  # BH-9035: these suites pin the first-capped-tick rules
    mkdir -p "$TMPDIR"
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED
    bash "$H/bin/review-prs.sh" "${2:-$PROJECT}" > "$T/out.$1" 2>&1 )
}
sent() { ls "$T/sent" 2>/dev/null | wc -l | tr -d ' '; }
event() { sed -n 3p "$T/sent/$1"; }
capped() { echo 1700 > "$T/tmpfree"; }

# ── EP1: a capped tick sends one event and writes the marker ──
fresh; capped
REVIEW_CONCURRENCY=3 run_rp ep1
[ "$(sent)" = 1 ] && ok || bad "EP1 events=$(sent) (want 1): $(tail -3 "$LOG")"
[ "$(mk_epoch)" = "$N" ] && ok || bad "EP1 marker: '$(cat "$MK" 2>/dev/null)' (want $N)"

# ── EP2: capped -> recovered -> capped sends a second event (AT4) ──
echo 102400 > "$T/tmpfree"
RP_TMP_REPORT_NOW=$((N + 30)) REVIEW_CONCURRENCY=3 run_rp ep2r
[ -e "$MK" ] && bad "EP2 the marker is still there after a recovered tick: $(cat "$MK")" || ok
[ "$(grep -c 'review-prs: /tmp recovered (102400MB free, threshold 2304MB); cap episode ended' "$LOG")" = 1 ] \
  && ok || bad "EP2 no episode-ended line: $(tail -3 "$LOG")"
[ "$(sent)" = 1 ] && ok || bad "EP2 the recovered tick sent: events=$(sent)"
capped
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=3 run_rp ep2c
[ "$(sent)" = 2 ] && ok || bad "EP2 a new episode 60s later sent no event: events=$(sent) $(tail -2 "$LOG")"
[ "$(mk_epoch)" = "$((N + 60))" ] && ok || bad "EP2 marker not rewritten: '$(cat "$MK" 2>/dev/null)'"
# A second recovered tick with no marker writes no second line.
echo 102400 > "$T/tmpfree"; rm -f "$MK"
RP_TMP_REPORT_NOW=$((N + 90)) REVIEW_CONCURRENCY=3 run_rp ep2n
[ "$(grep -c 'cap episode ended' "$LOG")" = 1 ] && ok || bad "EP2 an episode-ended line with no marker: $(grep -c 'cap episode ended' "$LOG")"

# ── EP3: 10 capped ticks in one episode send exactly one event (AT3) ──
fresh; capped
for i in 0 1 2 3 4 5 6 7 8 9; do RP_TMP_REPORT_NOW=$((N + i * 60)) REVIEW_CONCURRENCY=3 run_rp "ep3-$i"; done
[ "$(sent)" = 1 ] && ok || bad "EP3 10 capped ticks sent $(sent) events (want 1)"
[ "$(grep -c 'review-prs: /tmp capped at 1; not reported' "$LOG")" = 9 ] && ok \
  || bad "EP3 not-reported lines: $(grep -c 'not reported' "$LOG") (want 9)"

# ── EP4: a tick capped by something else while /tmp is still low keeps the episode ──
fresh; capped
REVIEW_CONCURRENCY=3 run_rp ep4a
echo 2000 > "$T/tmpfree"
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=1 run_rp ep4b
[ "$(mk_epoch)" = "$N" ] && ok || bad "EP4 a REVIEW_CONCURRENCY=1 tick at 2000MB ended the episode"
capped
RP_TMP_REPORT_NOW=$((N + 120)) REVIEW_CONCURRENCY=3 run_rp ep4c
[ "$(sent)" = 1 ] && ok || bad "EP4 the episode restarted: events=$(sent) (want 1)"
RP_TMP_REPORT_NOW=$((N + 180)) REVIEW_BOX_MAX=1 REVIEW_CONCURRENCY=3 run_rp ep4d
grep -q 'concurrency capped at 1 by REVIEW_BOX_MAX=1' "$LOG" && ok || bad "EP4 setup: box_max did not cap: $(tail -2 "$LOG")"
[ "$(mk_epoch)" = "$N" ] && ok || bad "EP4 a REVIEW_BOX_MAX=1 tick at 1700MB ended the episode"
RP_TMP_REPORT_NOW=$((N + 240)) REVIEW_CONCURRENCY=3 run_rp ep4e
[ "$(sent)" = 1 ] && ok || bad "EP4 the episode restarted after box_max: events=$(sent) (want 1)"

# ── EP5: df unreadable keeps the episode, the tick exits 0 ──
fresh; capped
REVIEW_CONCURRENCY=3 run_rp ep5a
: > "$T/dfnone"
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=3 run_rp ep5b; rc=$?
[ "$rc" = 0 ] && ok || bad "EP5 tick rc=$rc: $(tail -5 "$T/out.ep5b")"
[ "$(mk_epoch)" = "$N" ] && ok || bad "EP5 an unreadable df ended the episode"
grep -q 'cap episode ended' "$LOG" && bad "EP5 an episode-ended line with no reading" || ok

# ── EP6: free exactly at the threshold ends the episode ──
fresh; capped
REVIEW_CONCURRENCY=3 run_rp ep6a
echo 2303 > "$T/tmpfree"
RP_TMP_REPORT_NOW=$((N + 30)) REVIEW_CONCURRENCY=1 run_rp ep6b
[ -e "$MK" ] && ok || bad "EP6 2303MB (one under) ended the episode"
echo 2304 > "$T/tmpfree"
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=3 run_rp ep6c
[ -e "$MK" ] && bad "EP6 2304MB (= threshold) kept the episode" || ok

# ── EP7: lane start removes a stale review-prs dir, keeps a fresh one (AT2) ──
fresh
mkdir -p "$FT/review-prs-old/x" "$FT/review-prs-new/x" "$T/claims" "$T/sweepproc"
printf 'x\n' > "$FT/review-prs-old/x/f"; printf 'x\n' > "$FT/review-prs-new/x/f"
touch -d '4 hours ago' "$FT/review-prs-old/x/f" "$FT/review-prs-old/x" "$FT/review-prs-old"
cp "$SRC/bin/tmp-sweep.sh" "$H/bin/"
scratch_install_closure bin/tmp-sweep.sh "$H" >/dev/null || { echo "tmp-sweep closure install failed"; exit 1; }
RP_SWEEP="$H/bin/tmp-sweep.sh" TMP_SWEEP_ROOT="$FT" TMP_SWEEP_PROC="$T/sweepproc" TMP_SWEEP_CLAIMS="$T/claims" \
  TMP_SWEEP_STOPGAP_FILE="$T/no-stopgap" REVIEW_CONCURRENCY=3 run_rp ep7
[ -e "$FT/review-prs-old" ] && bad "EP7 the 4h-old review-prs dir is still there: $(tail -3 "$H/logs/tmp-sweep.log" 2>/dev/null)" || ok
[ -d "$FT/review-prs-new" ] && ok || bad "EP7 the fresh review-prs dir was removed"
grep -q "removed $FT/review-prs-old " "$H/logs/tmp-sweep.log" 2>/dev/null && ok || bad "EP7 no sweep removal line: $(cat "$H/logs/tmp-sweep.log" 2>/dev/null)"

# ── CT1 / CT2: the event counts the review-prs dirs (AT5) ──
fresh; capped
mkdir -p "$FT/review-prs-wk-abc" "$FT/review-prs-x/a" "$FT/review-prs-y" "$FT/big" "$T/linked"
ln -s "$T/linked" "$FT/review-prs-l"
REVIEW_CONCURRENCY=3 run_rp ct1
EV=$(event 1 2>/dev/null)
[ "$(jq -r '.extra.review_prs_dirs' <<<"$EV" 2>/dev/null)" = 3 ] && ok || bad "CT1 review_prs_dirs: $(jq -c '.extra' <<<"$EV" 2>/dev/null)"
[ "$(jq -r '.extra.review_prs_dirs | type' <<<"$EV" 2>/dev/null)" = number ] && ok || bad "CT1 review_prs_dirs is not a number"
[ "$(jq -r '.extra.free_mb' <<<"$EV" 2>/dev/null)" = 1700 ] && ok || bad "CT1 free_mb: $EV"
[ "$(jq -r '.extra.threshold_mb' <<<"$EV" 2>/dev/null)" = 2304 ] && ok || bad "CT1 threshold_mb: $EV"
jq -r '.message.formatted // empty' <<<"$EV" 2>/dev/null | grep -q ', 3 review-prs dirs$' && ok \
  || bad "CT1 message has no dir count: $(jq -r '.message.formatted // empty' <<<"$EV" 2>/dev/null)"
[ -d "$FT/review-prs-wk-abc" ] && [ -d "$FT/review-prs-x" ] && [ -L "$FT/review-prs-l" ] && [ -d "$FT/big" ] && ok \
  || bad "CT1 the lane deleted a fixture dir: $(ls "$FT")"
fresh; capped
mkdir -p "$FT/big"
REVIEW_CONCURRENCY=3 run_rp ct2
EV=$(event 1 2>/dev/null)
[ "$(jq -r '.extra.review_prs_dirs' <<<"$EV" 2>/dev/null)" = 0 ] && ok || bad "CT2 review_prs_dirs: $(jq -c '.extra' <<<"$EV" 2>/dev/null)"

echo "review-prs-tmp-episode.bh-6133: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
