#!/bin/bash
# tests/conductor-deadline-tags.bh-6347-test.sh — BH-6347: the WORKER_DEADLINE
# Sentry event names the step in its title and carries the tags pr, worker_key
# and deadline_secs, plus the worker start time and the configured deadline.
#
# Sentry CROMFORD-HARNESS-E: "worker killed after 93s on 6a7867e3 at stage:
# unknown", with no PR tag and no way to tell a configured 93 s deadline from a
# capped one. mc_fanin_outcome (bin/lib/fanin.sh) builds that event.
#
# Each case runs the REAL mc_worker_bounded (the killer writes the mark) and the
# REAL mc_fanin_outcome (the reader sends the event) from the repo's lib, in a
# subshell. sentry_report is a stub that keeps its real arguments, one JSON line
# per call; D6 runs the real bin/lib/sentry-report.sh against a fake curl.
#
#   D1  1 s deadline, step review: one event, title `in step review`, tags
#   D2  no mc_step call: title `in step start`
#   D3  an empty mark, and a mark with an empty first field: no deadline_secs
#       tag, no started_at, outcome killed:deadline
#   D4  started_at, deadline_cfg_s, deadline_cap_s; the env unset reads 180
#   D5  a capped deadline: deadline_secs 1, deadline_cfg_s 600, cap 1
#   D6  the real reporter: the tags reach the envelope, the standard tags stay
#   D7  a worker done in time: no event, the row's state is the outcome
#   D8  two kills of the same (PR, head): one event, one log line
#   D9  the lane log line for the kill: PR, step, elapsed seconds
#
# Run from anywhere: tests/conductor-deadline-tags.bh-6347-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v setsid >/dev/null || { echo "setsid missing — skipping"; exit 0; }

FANIN="$DIR/bin/lib/fanin.sh"
SLUG=o/r
HEAD=6a7867e3ff00000000000000000000000000beef
ROW=$(printf '61\turl\t%s\tbr\tfalse\tCLEAN\t-' "$HEAD")

# run_case <name> <worker body> [env...] — one tick in $T/<name>: the real
# killer and the real reader, stubs for the conductor's own helpers. The attempts
# ledger is a file, so the (PR, head) dedup is the real one. Leaves
# $T/<name>/ev (one JSON line per sentry_report call), log (mc_log lines),
# word (the outcome) and t0 (the epoch the worker started).
run_case() {
  local c="$T/$1" body="$2"; shift 2
  mkdir -p "$c/state"; : > "$c/ev"; : > "$c/log"; : > "$c/attempts"
  env "$@" bash -c '
    c=$1; body=$2; row=$3
    . "$4" || exit 1
    SLUG=o/r MC_STATE_DIR="$c/state" MC_TICK_ID=t1 MC_LOG="$c/lanelog" MC_FANIN_T0=0
    : > "$MC_LOG"
    mc_handoff_id() { printf "%s" "${1//[^A-Za-z0-9._-]/_}"; }
    mc_log() { printf "%s\n" "$*" >> "$c/log"; }
    _mc_fanin_alert() { :; }
    mc_attempt_has() { grep -qxF "$1" "$c/attempts"; }
    mc_attempt_put() { printf "%s\n" "$1" >> "$c/attempts"; }
    mc_row_field() { echo QUEUED; }
    sentry_report() {
      jq -nc --arg level "$1" --arg lane "$2" --arg reason "$3" --arg message "$4" \
        --argjson extra "${5:-null}" --argjson tags "${6:-null}" \
        "{level:\$level,lane:\$lane,reason:\$reason,message:\$message,extra:\$extra,tags:\$tags}" >> "$c/ev"
    }
    eval "pr_worker() { $body; }"
    n=${RUNS:-1}
    while [ "$n" -gt 0 ]; do
      date +%s > "$c/t0"
      mc_worker_bounded "$row"
      mc_fanin_outcome $? "$row" > "$c/word"
      n=$((n - 1))
    done
    ls "$c/state/worker-deadline" 2>/dev/null > "$c/left"
  ' _ "$c" "$body" "$ROW" "$FANIN" > "$c/out" 2>&1
}
ev()   { jq -rc "$2" "$T/$1/ev" 2>/dev/null | head -1; }
nev()  { wc -l < "$T/$1/ev"; }


# ---- D1 the title names the step; the tags --------------------------------------
run_case d1 'mc_step review; sleep 5' MC_WORKER_DEADLINE_S=1 MC_WORKER_DEADLINE_CAP_S=   # determinism: ok the stub worker IS the stall the deadline kills, nothing waits on it
[ "$(nev d1)" = 1 ] && ok "D1 one event" || bad "D1 want 1 event, got $(nev d1): $(cat "$T/d1/ev" "$T/d1/out")"
M=$(ev d1 .message)
[ "$M" = "WORKER_DEADLINE: worker killed after 1s on 6a7867e3 in step review" ] && ok "D1 title" || bad "D1 title: $M"
[[ "$M" != *unknown* ]] && ok "D1 title has no unknown" || bad "D1 title says unknown: $M"
[ "$(ev d1 .reason)" = conductor-worker-deadline ] && ok "D1 reason" || bad "D1 reason: $(ev d1 .reason)"
[ "$(ev d1 .tags.pr)" = 61 ] && ok "D1 tag pr" || bad "D1 tag pr: $(ev d1 .tags)"
[ "$(ev d1 .tags.worker_key)" = "o/r#61" ] && ok "D1 tag worker_key" || bad "D1 tag worker_key: $(ev d1 .tags)"
[ "$(ev d1 .tags.deadline_secs)" = 1 ] && ok "D1 tag deadline_secs" || bad "D1 tag deadline_secs: $(ev d1 .tags)"
[ "$(ev d1 .tags.step)" = review ] && ok "D1 tag step" || bad "D1 tag step: $(ev d1 .tags)"
[ "$(cat "$T/d1/word")" = killed:deadline ] && ok "D1 outcome" || bad "D1 outcome: $(cat "$T/d1/word")"

# ---- D2 no step boundary: `in step start` --------------------------------------
run_case d2 'sleep 5' MC_WORKER_DEADLINE_S=1   # determinism: ok the stub worker IS the stall the deadline kills, nothing waits on it
M=$(ev d2 .message)
[[ "$M" == *" in step start" ]] && [[ "$M" != *unknown* ]] && ok "D2 title in step start" || bad "D2 title: $M"
[ "$(ev d2 .tags.step)" = start ] && ok "D2 tag step start" || bad "D2 tags: $(ev d2 .tags)"

# ---- D3 an unreadable deadline field ---------------------------------------------
# d3a: an empty mark (the file exists, nothing in it). d3b: the killer's printf
# field order with an empty first field; the tab reader folds the empty field,
# so field 1 reads as the stage text.
for v in d3a d3b; do
  c="$T/$v"; mkdir -p "$c/state/worker-deadline"; : > "$c/ev"; : > "$c/attempts"
  mk="$c/state/worker-deadline/o_r_61.t1"
  if [ "$v" = d3a ]; then : > "$mk"; else printf '%s\t%s\t%s\t%s\t%s\n' "" "unknown" "review" "3" "start=0s" > "$mk"; fi
  env -u MC_WORKER_DEADLINE_S bash -c '
    c=$1; . "$3" || exit 1
    SLUG=o/r MC_STATE_DIR="$c/state" MC_TICK_ID=t1
    mc_handoff_id() { printf "%s" "${1//[^A-Za-z0-9._-]/_}"; }
    mc_log() { :; }; _mc_fanin_alert() { :; }
    mc_attempt_has() { grep -qxF "$1" "$c/attempts"; }; mc_attempt_put() { printf "%s\n" "$1" >> "$c/attempts"; }
    sentry_report() { jq -nc --arg message "$4" --argjson extra "${5:-null}" --argjson tags "${6:-null}" "{message:\$message,extra:\$extra,tags:\$tags}" >> "$c/ev"; }
    mc_fanin_outcome 143 "$2"' _ "$c" "$ROW" "$FANIN" > "$c/word" 2>"$c/err"
  [ "$(cat "$c/word")" = killed:deadline ] && ok "D3 $v outcome" || bad "D3 $v outcome: $(cat "$c/word" "$c/err")"
  [ "$(nev "$v")" = 1 ] && ok "D3 $v one event" || bad "D3 $v events: $(nev "$v")"
  [ "$(ev "$v" '.tags | has("deadline_secs")')" = false ] && ok "D3 $v no deadline_secs tag" || bad "D3 $v tags: $(ev "$v" .tags)"
  [ "$(ev "$v" .extra.started_at)" = "" ] && ok "D3 $v started_at empty" || bad "D3 $v started_at: $(ev "$v" .extra.started_at)"
  [ "$(ev "$v" .tags.pr)" = 61 ] && ok "D3 $v tag pr still sent" || bad "D3 $v tags: $(ev "$v" .tags)"
  [[ "$(ev "$v" .message)" == *"after ?s"* ]] && ok "D3 $v title after ?s" || bad "D3 $v title: $(ev "$v" .message)"
  [ "$(ev "$v" .extra.deadline_cfg_s)" = 180 ] && ok "D3 $v deadline_cfg_s unset reads 180" || bad "D3 $v deadline_cfg_s: $(ev "$v" .extra)"
done

# ---- D4 the start time and the configured deadline --------------------------------
run_case d4 'mc_step review; sleep 5' MC_WORKER_DEADLINE_S=1 MC_WORKER_DEADLINE_CAP_S=   # determinism: ok the stub worker IS the stall the deadline kills, nothing waits on it
SA=$(ev d4 .extra.started_at); T0=$(cat "$T/d4/t0")
[[ "$SA" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && ok "D4 started_at is ISO UTC" || bad "D4 started_at: '$SA'"
SE=$(date -u -d "$SA" +%s 2>/dev/null || echo 0)
[ $((SE - T0)) -le 10 ] && [ $((T0 - SE)) -le 10 ] && ok "D4 started_at within 10s of the start" || bad "D4 started_at $SA ($SE) vs start $T0"
[ "$(ev d4 .extra.deadline_cfg_s)" = 1 ] && ok "D4 deadline_cfg_s" || bad "D4 extra: $(ev d4 .extra)"
[ "$(ev d4 '.extra | has("deadline_cap_s")')" = true ] && [ "$(ev d4 .extra.deadline_cap_s)" = "" ] && ok "D4 deadline_cap_s empty" || bad "D4 extra: $(ev d4 .extra)"
# BH-6462: no log line + a known step: the stage is the step, not "unknown".
[ "$(ev d4 .extra.stage)" = review ] && [ "$(ev d4 .extra.deadline_s)" = 1 ] && ok "D4 stage and deadline_s stay in extra" || bad "D4 extra: $(ev d4 .extra)"

# ---- D5 a capped deadline is visible as capped -------------------------------------
run_case d5 'mc_step review; sleep 5' MC_WORKER_DEADLINE_S=600 MC_WORKER_DEADLINE_CAP_S=1   # determinism: ok the stub worker IS the stall the deadline kills, nothing waits on it
[ "$(ev d5 .tags.deadline_secs)" = 1 ] && ok "D5 deadline_secs is the capped value" || bad "D5 tags: $(ev d5 .tags)"
[ "$(ev d5 .extra.deadline_cfg_s)" = 600 ] && ok "D5 deadline_cfg_s 600" || bad "D5 extra: $(ev d5 .extra)"
[ "$(ev d5 .extra.deadline_cap_s)" = 1 ] && ok "D5 deadline_cap_s 1" || bad "D5 extra: $(ev d5 .extra)"

# ---- D6 the real reporter and a fake curl --------------------------------------------
c="$T/d6"; mkdir -p "$c/h/state" "$c/h/logs" "$c/h/flags" "$c/bin" "$c/co/.git" "$c/state/worker-deadline"
printf '%s\n' "$(printf 'bh-6347 fixture head' | sha1sum | cut -c1-40)" > "$c/co/.git/HEAD"
jq -n '{lanes: [], libs: [{id: "sentry-report", file: "bin/lib/sentry-report.sh",
  knobs: [{env: "SENTRY_MAX_PER_FP_HOUR", type: "int", default: 6, min: 0, max: 60,
           required: true, settable: true, zero_means: "off"}]}]}' > "$c/reg.json"
cat > "$c/bin/curl" <<EOF
#!/bin/bash
cat > /dev/null
while [ \$# -gt 0 ]; do case "\$1" in --data-binary) cp "\${2#@}" "$c/body"; shift ;; esac; shift; done
printf 200
EOF
chmod +x "$c/bin/curl"
HARNESS="$c/h" HARNESS_CHECKOUT="$c/co" JOBS_BOX=box-t SENTRY_REPORT_NOW=1760000000 LANE_GATE_CACHE_S=0 \
  SENTRY_MAX_PER_FP_HOUR=6 LANE_REGISTRY="$c/reg.json" HARNESS_SENTRY_CURL="$c/bin/curl" \
  HARNESS_SENTRY_DSN="https://fixture0123public@sentry.example.test/42" P=proj-d6 MC_WORKER_DEADLINE_S=1 \
  bash -c '
    c=$1; . "$3" || exit 1; . "$4" || exit 1; . "$5" || exit 1
    SLUG=o/r MC_STATE_DIR="$c/state" MC_TICK_ID=t1 MC_LOG="$c/lanelog" MC_FANIN_T0=0; : > "$MC_LOG"
    mc_handoff_id() { printf "%s" "${1//[^A-Za-z0-9._-]/_}"; }
    mc_log() { :; }; _mc_fanin_alert() { :; }
    mc_attempt_has() { return 1; }; mc_attempt_put() { :; }
    pr_worker() { mc_step review; sleep 5; }   # determinism: ok the stub worker IS the stall the deadline kills, nothing waits on it
    mc_worker_bounded "$2"; mc_fanin_outcome $? "$2"' _ "$c" "$ROW" "$FANIN" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/sentry-report.sh" > "$c/word" 2>"$c/err"
EV=$(sed -n 3p "$c/body" 2>/dev/null)
[ "$(cat "$c/word")" = killed:deadline ] && ok "D6 outcome word exact" || bad "D6 outcome: $(cat "$c/word" "$c/err")"
jq -e '.tags.pr == "61" and .tags.worker_key == "o/r#61" and .tags.deadline_secs == "1" and .tags.step == "review"' <<<"$EV" >/dev/null 2>&1 \
  && ok "D6 the four tags reach the envelope" || bad "D6 envelope tags: $(jq -c .tags <<<"$EV" 2>&1)"
jq -e '.tags.lane == "merge-conductor" and .tags.project == "proj-d6" and .tags.box == "box-t" and .tags.reason == "conductor-worker-deadline" and (.tags.harness_sha | length) > 0' <<<"$EV" >/dev/null 2>&1 \
  && ok "D6 the five standard tags stay" || bad "D6 standard tags: $(jq -c .tags <<<"$EV" 2>&1)"
jq -e '.message.formatted == "WORKER_DEADLINE: worker killed after 1s on 6a7867e3 in step review"' <<<"$EV" >/dev/null 2>&1 \
  && ok "D6 message.formatted" || bad "D6 message: $(jq -c .message <<<"$EV" 2>&1)"
jq -e '.fingerprint == ["merge-conductor","proj-d6","conductor-worker-deadline"]' <<<"$EV" >/dev/null 2>&1 \
  && ok "D6 fingerprint unchanged" || bad "D6 fingerprint: $(jq -c .fingerprint <<<"$EV" 2>&1)"

# ---- D7 a worker done before its deadline raises no event ----------------------------
run_case d7 'mc_step review; return 0' MC_WORKER_DEADLINE_S=5
[ "$(nev d7)" = 0 ] && ok "D7 no event" || bad "D7 events: $(cat "$T/d7/ev")"
[ "$(cat "$T/d7/word")" = QUEUED ] && ok "D7 outcome is the row state" || bad "D7 outcome: $(cat "$T/d7/word")"
[ ! -s "$T/d7/left" ] && ok "D7 no mark left" || bad "D7 left: $(cat "$T/d7/left")"
! grep -q WORKER_DEADLINE "$T/d7/log" && ok "D7 no WORKER_DEADLINE log line" || bad "D7 log: $(cat "$T/d7/log")"

# ---- D8 two kills of the same (PR, head): one event, one line --------------------------
run_case d8 'mc_step review; sleep 5' MC_WORKER_DEADLINE_S=1 RUNS=2   # determinism: ok the stub worker IS the stall the deadline kills, nothing waits on it
[ "$(nev d8)" = 1 ] && ok "D8 one event for two kills" || bad "D8 events: $(nev d8)"
[ "$(grep -c 'WORKER_DEADLINE:' "$T/d8/log")" = 1 ] && ok "D8 one log line for two kills" || bad "D8 log: $(cat "$T/d8/log")"
[ "$(cat "$T/d8/word")" = killed:deadline ] && ok "D8 second kill still killed:deadline" || bad "D8 outcome: $(cat "$T/d8/word")"

# ---- D9 the lane log line (AC 3) ---------------------------------------------------------
[ "$(grep -c '^o/r#61 WORKER_DEADLINE: ' "$T/d1/log")" = 1 ] && ok "D9 one line for the kill" || bad "D9 log: $(cat "$T/d1/log")"
grep -Eq '^o/r#61 WORKER_DEADLINE: worker killed after 1s on 6a7867e3 at stage: .* \| step: review \([0-9]+s\) \| earlier: ' "$T/d1/log" \
  && ok "D9 the line names PR, step and elapsed seconds" || bad "D9 log: $(cat "$T/d1/log")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
