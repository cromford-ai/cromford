#!/bin/bash
# tests/review-prs-tmp.bh-6130-test.sh — BH-6130: bin/review-prs.sh owns the
# /tmp scratch its review agents use, removes it on every exit path, removes a
# dead tick's scratch at the start of the next tick, and reports a /tmp cap to
# Sentry once per box per REVIEW_TMP_CAPPED_REPORT_S with the measured numbers.
# The lane runs WHOLE from a scratch harness with its real bin/lib closure (the
# setup of tests/review-prs-parallel.bh-5284-test.sh). Stubbed: gh, df, the jobs
# functions (BASH_ENV), /proc/meminfo, curl (HARNESS_SENTRY_CURL) and
# bin/agent-call.sh. The /tmp path is $T/faketmp (REVIEW_POOL_TMP_PATH).
#   AC1/R1  a dead tick's review-prs-wk-<pid> dir holds /tmp under the floor:
#           the next tick removes it and runs at concurrency=3, no event.
#   R2-R5   reap table: a live review-prs.sh pid is kept; the same pid running
#           another program is removed; review-prs-wk-abc and a symlink are kept.
#   AC2/E1  /tmp low from non-harness dirs: concurrency=1, one event whose extra
#           holds free_mb, tmp_min_mb, worker_tmp_mb, threshold_mb and the top
#           three (big, mid, small); nothing outside the lane is deleted.
#   E2      the lane log line carries the same numbers and ends in `reported`.
#   AC3/D1-D3  two ticks 60s apart send one event; a second project at +120s
#           sends none; a tick at +86401s sends the second.
#   D4-D6   a future-dated marker is due; a marker 86399s old is not;
#           REVIEW_TMP_CAPPED_REPORT_S=0 is due on every capped tick.
#   D7      an unwritable marker: no event, one `tmp report skipped` line.
#   AC4/K1  the agent fails (rc 1) after writing into its scratch: the prompt
#           named a dir under the owned root; the next worker sees no older
#           scratch; nothing under review-prs-wk-* is left.
#   K2      the worker is SIGKILLed: the tick removes its scratch on collect.
#   K3      the tick and its worker are SIGKILLed: the next tick removes it.
#   K0      the lib is installed with the lane; the knob's registry default is
#           86400; the sentry call is on one line.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-prs-tmp.bh-6130-test.sh
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
# df: $T/dfgone names a dir — 1700 MB free while it exists, 102400 once it is
# gone. Else $T/tmpfree, else 102400.
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
if [ -s "$T/dfgone" ]; then
  if [ -e "\$(cat "$T/dfgone")" ]; then mb=1700; else mb=102400; fi
else
  mb=\$(cat "$T/tmpfree" 2>/dev/null || echo 102400)
fi
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

# The agent stub. $T/mode: ok | fail | killworker | killtick. It records the
# scratch path the prompt named ($T/log/scratch.<pr>) and what was under the
# owned root when it started ($T/log/seen.<pr>), writes into its scratch, then
# does what the mode says.
write_agent() {
  cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo "\$\$" > "$T/log/agentpid"
pr="\${AGENT_CALL_PR##*/}"
mode=\$(cat "$T/mode" 2>/dev/null || echo ok)
p=\$(sed -n 's/^Scratch space: .* create it under \([^ ]*\) (for example.*/\1/p' "\${6#@}" | head -1)
printf '%s\n' "\$p" > "$T/log/scratch.\$pr"
ls -d "$FT"/review-prs-wk-*/* > "$T/log/seen.\$pr" 2>/dev/null
[ -n "\$p" ] && mkdir -p "\$p/head" && printf 'x\n' > "\$p/head/x"
case "\$mode" in
  fail) exit 1 ;;
  killworker) [ "\$pr" = 7 ] && kill -KILL "\$PPID" ;;
  killtick)
    gp=\$(awk '{ print \$4 }' "/proc/\$PPID/stat")
    kill -KILL "\$gp" "\$PPID"; : > "$T/log/killed"; exit 0 ;;
esac
printf 'claude\n' > "\$5.runner"; printf 'claude-fable-5-1\n' > "\$5.model"
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "\$5"
exit 0
EOF
  chmod +x "$H/bin/agent-call.sh"
}

fresh() { # fresh <state-json> — a clean harness and /tmp
  scratch_rm "$H" 2>/dev/null; scratch_rm "$FT" 2>/dev/null; scratch_rm "$T/sent" 2>/dev/null
  scratch_rm "$T/log" 2>/dev/null; scratch_rm "$T/proc" 2>/dev/null
  rm -f "$T/dfgone" "$T/tmpfree" "$T/mode"
  mkdir -p "$H/bin" "$H/state" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/tmp" "$FT" "$T/log" "$T/proc"
  mkdir -p "$H/catalog/lanes.d"; cp "$SRC/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
  cp "$SRC/bin/review-prs.sh" "$SRC/bin/fleet-conf.sh" "$H/bin/"
  scratch_install_closure bin/review-prs.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
  mrs_fixture "$H" "$PROJECT" "$P2"
  cp "$T/stub.sh" "$H/bin/stub.sh"
  for b in beat.sh deploy-request.sh merge-queue.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$b"; chmod +x "$H/bin/$b"; done
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
  write_agent
  printf '%s\n' "$1" > "$H/state/$PROJECT.pr-reviews.json"
  printf '%s\n' "$1" > "$H/state/$P2.pr-reviews.json"
  jq -nc --arg h "$HEAD" --arg ns "$NUMS" '[$ns | split(" ")[] | tonumber
    | {number:., head:{sha:$h,ref:"feature"}, base:{ref:"main"}, user:{login:"externaldev",type:"User"},
       title:"Test PR \(.)", draft:false, state:"open", labels:[]}]' > "$T/prs.json"
}
run_rp() { # run_rp <tag> [project] — one tick; env REVIEW_CONCURRENCY etc. pass through
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$SRC/fleet.conf" TEST_ROOT="$T" \
      REPOS_ROOT="$T/no-repos" BASH_ENV="$H/bin/stub.sh" REVIEW_LIVE_CI=0 REVIEW_DEDUPE=0 \
      REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05 TMPDIR="$T/tmp-$1" \
      REVIEW_POOL_TMP_PATH="$FT" REVIEW_POOL_TMP_SWEEP='' \
      HARNESS_SENTRY_DSN=https://k-fixture@sentry.invalid/1 HARNESS_SENTRY_CURL="$T/fakebin/curl" \
      SENTRY_MAX_PER_FP_HOUR=6 SENTRY_REPORT_NOW="${RP_TMP_REPORT_NOW:-$N}" LANE_GATE_CACHE_S=0 \
      REVIEW_TMP_CAPPED_MIN_TICKS=1 REVIEW_TMP_TOP_N=3  # BH-9035: these suites pin the first-capped-tick rules
    mkdir -p "$TMPDIR"
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED REVIEW_BOX_MAX REVIEW_TMP_MIN_MB REVIEW_WORKER_TMP_MB
    bash "$H/bin/review-prs.sh" "${2:-$PROJECT}" > "$T/out.$1" 2>&1 )
}
sent() { ls "$T/sent" 2>/dev/null | wc -l | tr -d ' '; }
event() { sed -n 3p "$T/sent/$1"; }
wk_left() { ls -d "$FT"/review-prs-wk-* 2>/dev/null; }
# mkmb <name> <MB> — a dir holding a file of <MB>. The sync makes the blocks
# count now: with delayed allocation du reads an unflushed file as near 0.
mkmb() {
  mkdir -p "$FT/$1"
  [ "$2" -gt 0 ] && head -c "$(($2 * 1048576))" /dev/zero > "$FT/$1/f" && { sync "$FT/$1/f" 2>/dev/null || sync; }
  return 0
}
# A pid no process holds: a child that has already exited.
( : ) & DEADPID=$!; wait "$DEADPID"
DONE_ST=$(jq -nc --arg h "$HEAD" '{"7":{sha:$h,verdict:"REQUEST_CHANGES"}}')

# ── AC1 / R1: a dead tick's scratch holds /tmp under the floor ──
NUMS="7 8 9"; fresh '{}'
mkdir -p "$FT/review-prs-wk-$DEADPID/pr7"; printf 'x\n' > "$FT/review-prs-wk-$DEADPID/pr7/blob"
printf '%s\n' "$FT/review-prs-wk-$DEADPID" > "$T/dfgone"
REVIEW_CONCURRENCY=3 run_rp r1
[ -e "$FT/review-prs-wk-$DEADPID" ] && bad "R1 the dead tick's scratch is still there" || ok
grep -q 'review-prs tick concurrency=3 ' "$LOG" && ok || bad "R1 tick not at concurrency=3: $(grep -E 'tick|capped' "$LOG")"
grep -q 'concurrency capped at' "$LOG" && bad "R1 still capped: $(grep capped "$LOG")" || ok
[ "$(sent)" = 0 ] && ok || bad "R1 events=$(sent) (want 0)"
grep -q "removed 1 stale scratch dir(s) under $FT" "$LOG" && ok || bad "R1 no removal line: $(tail -5 "$LOG")"
NUMS="7"

# ── R2-R5: the reap table ──
fresh "$DONE_ST"
LIVE=4242420
mkdir -p "$FT/review-prs-wk-$LIVE/pr7" "$FT/review-prs-wk-abc" "$T/keep" "$T/proc/$LIVE"
printf 'keep\n' > "$T/keep/k"; ln -s "$T/keep" "$FT/review-prs-wk-123"
printf 'bash\0bin/review-prs.sh\0x\0' > "$T/proc/$LIVE/cmdline"
RP_TMP_PROC="$T/proc" run_rp r2
[ -d "$FT/review-prs-wk-$LIVE" ] && ok || bad "R2 a live review-prs.sh tick's scratch was removed"
[ -d "$FT/review-prs-wk-abc" ] && ok || bad "R4 review-prs-wk-abc was removed"
[ -L "$FT/review-prs-wk-123" ] && [ -f "$T/keep/k" ] && ok || bad "R5 the symlink or its target was removed"
printf 'sleep\0''30\0' > "$T/proc/$LIVE/cmdline"
RP_TMP_PROC="$T/proc" run_rp r3
[ -e "$FT/review-prs-wk-$LIVE" ] && bad "R3 a reused pid (sleep) kept its dead tick's scratch" || ok
[ -d "$FT/review-prs-wk-abc" ] && [ -L "$FT/review-prs-wk-123" ] && [ -f "$T/keep/k" ] && ok || bad "R4/R5 lost on the second tick"

# ── AC2 / E1 / E2: /tmp low from files that are not the harness's ──
fresh "$DONE_ST"
mkmb big 3; mkmb mid 2; mkmb small 1; mkmb tiny 0
echo 1700 > "$T/tmpfree"
RP_TMP_REPORT_NOW=$N REVIEW_CONCURRENCY=3 run_rp e1
grep -q 'review-prs tick concurrency=1 ' "$LOG" && ok || bad "E1 tick not at concurrency=1: $(grep -E 'tick|capped' "$LOG")"
[ "$(sent)" = 1 ] && ok || bad "E1 events=$(sent) (want 1): $(cat "$H/logs/sentry-report.log" 2>/dev/null)"
EV=$(event 1 2>/dev/null)
[ "$(jq -r '.extra.free_mb' <<<"$EV" 2>/dev/null)" = 1700 ] && ok || bad "E1 free_mb: $EV"
[ "$(jq -r '.extra.tmp_min_mb' <<<"$EV" 2>/dev/null)" = 1536 ] && ok || bad "E1 tmp_min_mb: $EV"
[ "$(jq -r '.extra.worker_tmp_mb' <<<"$EV" 2>/dev/null)" = 256 ] && ok || bad "E1 worker_tmp_mb: $EV"
[ "$(jq -r '.extra.threshold_mb' <<<"$EV" 2>/dev/null)" = 2304 ] && ok || bad "E1 threshold_mb: $EV"
[ "$(jq -r '.extra.top | length' <<<"$EV" 2>/dev/null)" = 3 ] && ok || bad "E1 top length: $EV"
[ "$(jq -r '[.extra.top[].path | split("/") | last] | join(",")' <<<"$EV" 2>/dev/null)" = big,mid,small ] && ok \
  || bad "E1 top order: $(jq -c '.extra.top' <<<"$EV" 2>/dev/null)"
[ "$(jq -r '.extra.top[0].mb | type' <<<"$EV" 2>/dev/null)" = number ] && ok || bad "E1 top mb is not a number: $EV"
[ "$(jq -r '.extra.tmp_path' <<<"$EV" 2>/dev/null)" = "$FT" ] && ok || bad "E1 tmp_path: $EV"
[ "$(jq -r '.extra.concurrency' <<<"$EV" 2>/dev/null)" = 1 ] && ok || bad "E1 concurrency: $EV"
[ "$(jq -r '.extra.project' <<<"$EV" 2>/dev/null)" = "$PROJECT" ] && ok || bad "E1 project: $EV"
[ -n "$(jq -r '.extra.fstype // empty' <<<"$EV" 2>/dev/null)" ] && ok || bad "E1 no fstype: $EV"
[ "$(jq -r '.tags.reason' <<<"$EV" 2>/dev/null)" = review-prs-tmp-capped ] && ok || bad "E1 reason tag: $EV"
[ -d "$FT/big" ] && [ -d "$FT/mid" ] && [ -d "$FT/small" ] && [ -d "$FT/tiny" ] && ok || bad "E1 a non-harness dir was deleted: $(ls "$FT")"
L=$(grep 'concurrency capped at 1 by .*threshold' "$LOG")
grep -q '1700MB free, threshold 2304MB (floor 1536MB + 3 x 256MB); top: [^ ]*/big [0-9]*MB, [^ ]*/mid [0-9]*MB, [^ ]*/small [0-9]*MB; reported (window)$' <<<"$L" \
  && ok || bad "E2 log line: ${L:-none}"

# ── AC3 / D1-D3: once per box per window ──
RP_TMP_REPORT_NOW=$((N + 60)) REVIEW_CONCURRENCY=3 run_rp d2
[ "$(sent)" = 1 ] && ok || bad "D2 a second tick 60s later sent again: events=$(sent)"
grep -q 'review-prs: /tmp capped at 1; not reported, last report .* at concurrency 1 (window 86400s)' "$LOG" && ok || bad "D2 no not-reported line: $(tail -3 "$LOG")"
RP_TMP_REPORT_NOW=$((N + 120)) REVIEW_CONCURRENCY=3 run_rp d3 "$P2"
[ "$(sent)" = 1 ] && ok || bad "D3 a second project on the same box sent again: events=$(sent)"
RP_TMP_REPORT_NOW=$((N + 86401)) REVIEW_CONCURRENCY=3 run_rp d1
[ "$(sent)" = 2 ] && ok || bad "D1 a tick past the window did not send: events=$(sent)"

# ── D4-D6: the window table ──
MK="$H/state/review-prs-tmp-capped.last"
fresh "$DONE_ST"; echo 1700 > "$T/tmpfree"; echo $((N + 999)) > "$MK"
RP_TMP_REPORT_NOW=$N REVIEW_CONCURRENCY=3 run_rp d4
[ "$(sent)" = 1 ] && ok || bad "D4 a future-dated marker was not due: events=$(sent)"
# BH-6132: the marker is `<epoch> <concurrency>`; the epoch is the first field.
[ "$(cut -d' ' -f1 "$MK")" = "$N" ] && ok || bad "D4 marker not rewritten with now: $(cat "$MK")"
fresh "$DONE_ST"; echo 1700 > "$T/tmpfree"; echo $((N - 86399)) > "$MK"
RP_TMP_REPORT_NOW=$N REVIEW_CONCURRENCY=3 run_rp d5
[ "$(sent)" = 0 ] && ok || bad "D5 a marker 86399s old was due: events=$(sent)"
fresh "$DONE_ST"; echo 1700 > "$T/tmpfree"
RP_TMP_REPORT_NOW=$N REVIEW_TMP_CAPPED_REPORT_S=0 REVIEW_CONCURRENCY=3 run_rp d6a
RP_TMP_REPORT_NOW=$((N + 1)) REVIEW_TMP_CAPPED_REPORT_S=0 REVIEW_CONCURRENCY=3 run_rp d6b
[ "$(sent)" = 2 ] && ok || bad "D6 window 0 did not send on both ticks: events=$(sent)"

# ── D7: the marker cannot be written ──
fresh "$DONE_ST"; echo 1700 > "$T/tmpfree"; mkdir -p "$MK"
RP_TMP_REPORT_NOW=$N REVIEW_CONCURRENCY=3 run_rp d7
[ "$(sent)" = 0 ] && ok || bad "D7 sent with an unwritable marker: events=$(sent)"
[ "$(grep -c "tmp report skipped: marker $MK not writable" "$LOG")" = 1 ] && ok || bad "D7 skip lines: $(tail -3 "$LOG")"

# ── AC4 / K1: the agent fails after writing into its scratch ──
NUMS="7 8"; fresh '{}'; echo fail > "$T/mode"
REVIEW_CONCURRENCY=1 run_rp k1
case "$(cat "$T/log/scratch.7" 2>/dev/null)" in
  "$FT"/review-prs-wk-[0-9]*/pr7) ok ;;
  *) bad "K1 the prompt named no scratch under the owned root: '$(cat "$T/log/scratch.7" 2>/dev/null)'" ;;
esac
[ -e "$T/log/seen.8" ] && ok || bad "K1 #8 never ran"
grep -q pr7 "$T/log/seen.8" 2>/dev/null && bad "K1 #7's scratch was still there when #8 started: $(cat "$T/log/seen.8")" || ok
[ -z "$(wk_left)" ] && ok || bad "K1 scratch left after the tick: $(wk_left)"

# ── K2: the worker is SIGKILLed ──
fresh '{}'; echo killworker > "$T/mode"
REVIEW_CONCURRENCY=1 run_rp k2
grep -q 'worker pr7 ended with no result' "$LOG" && ok || bad "K2 no collect line: $(tail -5 "$LOG")"
grep -q pr7 "$T/log/seen.8" 2>/dev/null && bad "K2 the killed worker's scratch was still there when #8 started: $(cat "$T/log/seen.8")" || ok
[ -z "$(wk_left)" ] && ok || bad "K2 scratch left after the tick: $(wk_left)"

# ── K3: the tick and its worker are SIGKILLed ──
NUMS="7"; fresh '{}'; echo killtick > "$T/mode"
REVIEW_CONCURRENCY=1 run_rp k3a
AP=$(cat "$T/log/agentpid" 2>/dev/null); i=0
while [ -n "$AP" ] && kill -0 "$AP" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
[ -e "$T/log/killed" ] && ok || bad "K3 the stub never killed the tick"
[ -n "$(wk_left)" ] && ok || bad "K3 setup: the killed tick left no scratch to remove"
echo ok > "$T/mode"
REVIEW_CONCURRENCY=1 run_rp k3b
[ -z "$(wk_left)" ] && ok || bad "K3 the next tick left the dead tick's scratch: $(wk_left)"

# ── K0: static ──
[ -f "$SRC/bin/lib/review-prs-tmp.sh" ] && [ -f "$H/bin/lib/review-prs-tmp.sh" ] && ok \
  || bad "K0 bin/lib/review-prs-tmp.sh is missing or the closure did not install it"
[ "$(jq -r '.knobs[] | select(.env == "REVIEW_TMP_CAPPED_REPORT_S") | .default' "$SRC/catalog/lanes.d/review-prs.json")" = 86400 ] \
  && ok || bad "K0 REVIEW_TMP_CAPPED_REPORT_S default is not 86400"
grep -v '^[[:space:]]*#' "$SRC/bin/review-prs.sh" | grep -q 'sentry_report.*review-prs-tmp-capped' \
  && ok || bad "K0 the sentry_report review-prs-tmp-capped call is not on one line"

echo "review-prs-tmp.bh-6130: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
