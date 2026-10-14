#!/bin/bash
# tests/dequeue-watch-ship-dark.bh-3859-test.sh — BH-3859: dequeue-watch ships
# dark, reports once, owns per (pr, head, class), counts honestly and says when
# a tick timed out. Every case runs the SHIPPED bin/dequeue-watch.sh from a
# `cp -rs` scratch harness through the fixture seam, exactly as
# tests/dequeue-watch.bh-3719-test.sh does (see that file and the fixture header
# for the stubs and the ordered $F/requests.log).
#
#   D1      no DEQUEUE_WATCH_ACT in env -> WOULD_FIX_ROUND, no action, acted=0 would=1
#   D1-seed the schema seeds the knob at 0 (OR IGNORE), the registry defaults agree
#   D2      DEQUEUE_WATCH_OBSERVE_TICKS=3 -> one observe report after tick 3, none
#           after tick 5, never a settings write; D2-act: ACT=1 keeps no counter
#   D3      DEQUEUE_WATCH_OBSERVE_TICKS=abc -> a note, 12, the tick still counted
#   O1      same head, a new run failing another class -> gathered, classified, claimed
#   O2      ... with that claim unread past the window -> paged, NOT resolved off run 5001's
#           row; tick 3 (run 5002 classified, no row of its class) gathers and claims it
#   O3      the same run again -> already-owned (rule-break/fix-round, run 5001), no reads
#   O4      dark, the same run again -> the observe row owns it, no reads
#   O5      dark tick, then DEQUEUE_WATCH_ACT=1 -> the observe row is taken over
#   O6      run classified bystander + a live stale-status row -> already-owned
#           (stale-status/lead-request), no reads; O6-neg: bystander + only a
#           rule-break row -> not owned, gathered again
#   C1      one tick, three PRs: acted, owned, unread -> acted=1 would=0 owned=1 unread=1
#   T1      a tick killed by the timeout wrapper writes one ` tick timed-out` line
#   T1-seam the 1 s test timeout is ignored outside the sandbox
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/dequeue-watch-ship-dark.bh-3859-test.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/tests/fixtures/dequeue-watch"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $CASE: $1"; }

NOW=$(date -u +%s)
SLUG=example-org/cromford
HEAD=b49a1b832b0d294ee7a46325ac2ace79dc50d235
H12=${HEAD:0:12}
H="$T/h"; F="$T/fix"; LOG="$H/logs/dequeue-watch.log"; REQ="$F/requests.log"
FLIP='bin/harness-ctl.sh set dequeue-watch DEQUEUE_WATCH_ACT 1'
CASE=setup

mkdir -p "$H" "$T/shim" "$T/slowshim"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
for s in lane-alert lead-verdict needs-human-hold box-for agent-call; do
  rm -f "$H/bin/$s.sh"
  {
    echo '#!/bin/bash'
    echo 'printf "SCRIPT %s %s\n" "$(basename "$0")" "$*" >> "$DQW_FIX_DIR/requests.log"'
  } > "$H/bin/$s.sh"
done
echo 'echo box-2' >> "$H/bin/box-for.sh"
echo 'printf "%s\n" "${AGENT_ANSWER:-semantic-test}" > "$5"' >> "$H/bin/agent-call.sh"
cat > "$T/shim/gh" <<'EOF'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$DQW_FIX_DIR/requests.log"
case "$1 $2" in
  "api --paginate")
    n=$(printf '%s' "$3" | sed -n 's#.*/issues/\([0-9]*\)/comments.*#\1#p')
    [ -r "$DQW_FIX_DIR/comments-$n.json" ] && exec cat "$DQW_FIX_DIR/comments-$n.json" ;;
  "run view") [ -r "$DQW_FIX_DIR/log-$3.txt" ] && exec cat "$DQW_FIX_DIR/log-$3.txt" ;;
esac
exit 1
EOF
# T1-seam: a flock that takes 5 s, so a tick is slow with or without the fixture seam.
REAL_FLOCK=$(command -v flock)
printf '#!/bin/bash\nsleep 5\nexec %s "$@"\n' "$REAL_FLOCK" > "$T/slowshim/flock"
chmod +x "$T/shim/gh" "$T/slowshim/flock" "$H/bin/"{lane-alert,lead-verdict,needs-human-hold,box-for,agent-call}.sh

rest() { mkdir -p "$F/rest"; cat > "$F/rest/$(printf '%s' "$1" | tr '/?&=' '____')"; }
list_prs() {
  local l
  for l in merge-queue dequeued; do
    printf '%s\n' "$@" | jq -sc 'map({number: ., pull_request: {url: "x"}, labels: [{name: "merge-queue"}, {name: "dequeued"}]})' \
      | rest "repos/$SLUG/issues?labels=$l&state=open&per_page=100"
  done
}
payload() {    # payload <num> <payload-file> <age_s>
  local at; at=$(date -u -d "@$((NOW - $3))" +%FT%TZ)
  jq -n --rawfile b "$2" --arg at "$at" --argjson n "$1" \
    '[{id: (9000 + $n), user: {login: "mergify[bot]"}, body: $b, created_at: $at, updated_at: $at}]' > "$F/comments-$1.json"
  jq -n --rawfile b "$2" '{body: $b}' | rest "repos/$SLUG/issues/comments/$((9000 + $1))"
}
pull() { jq -nc --arg h "$2" --arg r "ticket/bh-9$1" '{head: {sha: $h, ref: $r}, mergeable_state: "clean"}' | rest "repos/$SLUG/pulls/$1"; }
files() { rest "repos/$SLUG/pulls/$1/files?per_page=100" < "$2"; }
cilog() { cp "$1" "$F/log-$2.txt"; }

base() {       # base <case> — PR 101 of a batch of one, a rule break on run 5001
  CASE="$1"
  local d
  for d in "$F" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/tmp"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$F/rest" "$H/state/merge-conductor" "$H/logs"
  : > "$REQ"
  printf 'proj %s https://example.invalid - 5 box-2\n' "$SLUG" > "$H/fleet.conf"
  list_prs 101
  payload 101 "$FX/payload-dequeued-batch1.md" 120
  pull 101 "$HEAD"
  rest "repos/$SLUG/actions/runs?event=push&per_page=100" < "$FX/runs-batch1.json"
  cilog "$FX/log-rule-break.txt" 5001
  jq -n --arg c "$(base64 -w0 < "$FX/sources-lib-root.txt")" '{content: $c, encoding: "base64"}' \
    | rest "repos/$SLUG/contents/tests/lib-root-literal-ratchet.bh-2613-test.sh?ref=main"
  files 101 "$FX/pr-files-101.json"
  echo MERGE > "$F/verdict"
  echo '{"statuses":[{"context":"lead-verdict","state":"success"}]}' | rest "repos/$SLUG/commits/$HEAD/status"
}
# run5002 <age_s> — PR 101's newest payload is run 5002 on the SAME head,
# failing a semantic test (a different class from run 5001's rule break).
run5002() {
  sed 's#/runs/5001/#/runs/5002/#g' "$FX/payload-dequeued-batch1.md" > "$T/payload-5002.md"
  payload 101 "$T/payload-5002.md" "$1"
  cilog "$FX/log-semantic.txt" 5002
}

SUMRE='^[0-9-]+T[0-9:]+Z (tick |off$|disabled$|locked$|gh-budget$|lib-missing )'
sums() { grep -cE "$SUMRE" "$LOG" 2>/dev/null || true; }
lastsum() { grep -E "$SUMRE" "$LOG" 2>/dev/null | tail -1; }
cnt() { grep -cF -- "$1" "$REQ" 2>/dev/null || true; }
eq() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', wanted '$3'"; }
has() { grep -qF -- "$2" "$LOG" 2>/dev/null && ok || bad "$1: no '$2' in the lane log: $(tail -5 "$LOG" 2>/dev/null | tr '\n' '|')"; }
LANE_ENV=(PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL= HARNESS_SECRET=test-secret
          DEQUEUE_WATCH_FIXTURE="$FX/fixture.sh" DQW_FIX_DIR="$F")
# run_lane [VAR=val...] — the shipped entry, sandboxed, with NO DEQUEUE_WATCH_ACT
# unless a case passes one. Exactly one summary line per run.
run_lane() {
  local b; b=$(sums)
  env -i "${LANE_ENV[@]}" HARNESS_TEST_SANDBOX=1 "$@" bash "$H/bin/dequeue-watch.sh" > "$T/lane.out" 2> "$T/lane.err"
  RC=$?
  [ "$(( $(sums) - b ))" = 1 ] && ok || bad "wanted exactly one summary line, got $(( $(sums) - b )); log: $(tail -5 "$LOG" 2>/dev/null | tr '\n' '|') err: $(head -c 600 "$T/lane.err")"
  [ "$RC" = 0 ] && ok || bad "the lane exited $RC"
}
reports() { grep -c -- '--id observe-report:dequeue-watch' "$REQ" 2>/dev/null || true; }

# ── D1: no knob in env -> observe only ───────────────────────────────────────
base D1
run_lane
has "observe" WOULD_FIX_ROUND
eq "fix-round POSTs" "$(cnt 'JOBS POST /api/fix-rounds')" 0
eq "requeues" "$(cnt 'FN mc_requeue_mergify')" 0
eq "observe claims" "$(grep -F 'actions/claim' "$REQ" | grep -cF '"action":"observe"')" 1
lastsum | grep -qE ' acted=0 would=1 ' && ok || bad "summary '$(lastsum)' should say acted=0 would=1"

# ── D1-seed: the knob ships at 0 in the schema seed and the registry ─────────
CASE=D1-seed
seeds=$(grep -E "^INSERT OR IGNORE INTO settings" -A1 "$DIR/worker/jobs/schema.sql" | grep -F "'lane.dequeue-watch.dequeue_watch_act'")
eq "dequeue_watch_act seeds (INSERT OR IGNORE)" "$(printf '%s' "$seeds" | grep -c .)" 1
eq "dequeue_watch_act mentions in schema.sql" "$(grep -cF "'lane.dequeue-watch.dequeue_watch_act'" "$DIR/worker/jobs/schema.sql")" 1
grep -qF "('lane.dequeue-watch.dequeue_watch_act','0'," <<<"$seeds" && ok || bad "the seed value is not '0': $seeds"
REG="$DIR/catalog/lanes.d/dequeue-watch.json"
eq "registry DEQUEUE_WATCH_ACT default" "$(jq -r '.knobs[] | select(.env == "DEQUEUE_WATCH_ACT") | .default' "$REG")" 0
eq "registry DEQUEUE_WATCH_OBSERVE_TICKS default" "$(jq -r '.knobs[] | select(.env == "DEQUEUE_WATCH_OBSERVE_TICKS") | .default' "$REG")" 12
eq "registry DEQUEUE_WATCH_TICK_TIMEOUT_S settable" "$(jq -r '.knobs[] | select(.env == "DEQUEUE_WATCH_TICK_TIMEOUT_S") | .settable' "$REG")" false

# ── D2: one observe report after N ticks, never a second, never a flip ────────
base D2
for i in 1 2 3 4 5; do
  run_lane DEQUEUE_WATCH_OBSERVE_TICKS=3
  case "$i" in
    1|2) eq "reports after tick $i" "$(reports)" 0 ;;
    3)   eq "reports after tick 3" "$(reports)" 1 ;;
  esac
done
eq "reports after tick 5" "$(reports)" 1
msg=$(grep -F -- '--id observe-report:dequeue-watch' "$REQ")
case "$msg" in "SCRIPT lane-alert.sh --severity warn --id observe-report:dequeue-watch dequeue-watch "*) ok ;; *) bad "report argv: $msg" ;; esac
case "$msg" in *WOULD_FIX_ROUND*) ok ;; *) bad "the report lacks WOULD_FIX_ROUND: $msg" ;; esac
case "$msg" in *"$FLIP"*) ok ;; *) bad "the report lacks the flip command: $msg" ;; esac
case "$msg" in *"1 thing on 1 PR:"*) ok ;; *) bad "the report should count one thing on one PR: $msg" ;; esac
eq "settings requests" "$(cnt '/api/settings')" 0
eq "fix-round POSTs while dark" "$(cnt 'JOBS POST /api/fix-rounds')" 0

base D2-act
run_lane DEQUEUE_WATCH_ACT=1 DEQUEUE_WATCH_OBSERVE_TICKS=1
[ -e "$H/state/observe-report/dequeue-watch.json" ] && bad "an acting tick counted an observe tick" || ok
eq "reports from an acting tick" "$(reports)" 0

# ── D3: a junk tick count falls back to 12, says so, and still counts ───────
base D3
run_lane DEQUEUE_WATCH_OBSERVE_TICKS=abc
has "junk knob" "DEQUEUE_WATCH_OBSERVE_TICKS='abc' is not a positive integer, using 12"
eq "observe ticks counted" "$(jq -r .ticks "$H/state/observe-report/dequeue-watch.json" 2>/dev/null)" 1
eq "reports on tick 1 of 12" "$(reports)" 0

# ── O1: same head, a new run, another class -> its own action ─────────────────
base O1
run_lane DEQUEUE_WATCH_ACT=1
eq "tick 1 fix-round POSTs" "$(cnt 'JOBS POST /api/fix-rounds')" 1
run5002 120
: > "$REQ"
run_lane DEQUEUE_WATCH_ACT=1
eq "run 5002 event records" "$(grep -F 'JOBS POST /api/dequeue-watch/events ' "$REQ" | grep -cF '"run_id":"5002"')" 1
cls2=$(jq -r 'select(.run_id == "5002") | .class // ""' "$F/db/events.jsonl")
[ -n "$cls2" ] && [ "$cls2" != rule-break ] && ok || bad "run 5002 was classified '$cls2', wanted a class other than rule-break"
eq "claims for run 5002's class" "$(grep -F 'actions/claim' "$REQ" | grep -cF "\"class\":\"$cls2\"")" 1
eq "action rows on the head" "$(ls "$F/db/actions" | grep -c "_101_${HEAD}_")" 2
eq "event rows (run_id recorded)" "$(jq -r 'select(.pr == 101) | .run_id' "$F/db/events.jsonl" | sort | paste -sd, -)" 5001,5002

# ── O2: the second class unowned past the window -> paged, not resolved ───────
base O2
run_lane DEQUEUE_WATCH_ACT=1
run5002 2700
: > "$REQ"
run_lane DEQUEUE_WATCH_ACT=1 CLAIM_FAIL=1
eq "unowned pages" "$(cnt "SCRIPT lane-alert.sh --severity critical --id dqw-unowned:proj:101:$H12")" 1
eq "resolves off run 5001's row" "$(cnt "--resolve --id dqw-unowned:proj:101")" 0
# Tick 3: run 5002 is classified now but no row holds its class, so run 5001's
# row does not own it: gathered again, claimed, and only then resolved.
: > "$REQ"
run_lane DEQUEUE_WATCH_ACT=1
eq "tick 3 claims" "$(cnt 'actions/claim')" 1
eq "tick 3 action rows on the head" "$(ls "$F/db/actions" | grep -c "_101_${HEAD}_")" 2
eq "tick 3 resolves" "$(cnt "--resolve --id dqw-unowned:proj:101:$H12")" 1

# ── O3: the same run again -> owned by its class, nothing re-read ────────────
base O3
run_lane DEQUEUE_WATCH_ACT=1
: > "$REQ"
run_lane DEQUEUE_WATCH_ACT=1
has "same run" "already-owned (rule-break/fix-round, run 5001)"
eq "tick 2 claims" "$(cnt 'actions/claim')" 0
eq "tick 2 pull-files reads" "$(cnt '/files?per_page=100')" 0

# ── O4: dark, the same run again -> the observe row owns it, nothing re-read ─
base O4
run_lane
: > "$REQ"
run_lane
has "dark same run" "already-owned (rule-break/observe, run 5001)"
eq "dark tick 2 claims" "$(cnt 'actions/claim')" 0
eq "dark tick 2 pull-files reads" "$(cnt '/files?per_page=100')" 0

# ── O5: flipped to 1 -> the observe row is NOT owning; the lane takes it over ─
base O5
run_lane
: > "$REQ"
run_lane DEQUEUE_WATCH_ACT=1
has "flip" "observe row taken over for fix-round"
eq "fix-round POSTs after the flip" "$(cnt 'JOBS POST /api/fix-rounds')" 1
lastsum | grep -qE ' acted=1 would=0 ' && ok || bad "summary '$(lastsum)' should say acted=1 would=0"

# ── O6: a bystander run is owned by the stale-status row it is remapped to ───
base O6
run_lane DEQUEUE_WATCH_ACT=1
A="$F/db/actions/example-org_cromford_101_${HEAD}"
jq -c 'if (.run_id | tostring) == "5001" then .class = "bystander" else . end' "$F/db/events.jsonl" > "$F/db/ev.tmp" && mv "$F/db/ev.tmp" "$F/db/events.jsonl"
jq -c '.class = "stale-status" | .action = "lead-request"' "${A}_rule-break" > "${A}_stale-status" && rm -f "${A}_rule-break"
: > "$REQ"
run_lane DEQUEUE_WATCH_ACT=1
has "bystander remap" "already-owned (stale-status/lead-request, run 5001)"
eq "O6 tick 2 claims" "$(cnt 'actions/claim')" 0
eq "O6 tick 2 pull-files reads" "$(cnt '/files?per_page=100')" 0

# ── O6-neg: a bystander run is NOT owned by another class's row ──────────────
base O6-neg
run_lane DEQUEUE_WATCH_ACT=1
jq -c 'if (.run_id | tostring) == "5001" then .class = "bystander" else . end' "$F/db/events.jsonl" > "$F/db/ev.tmp" && mv "$F/db/ev.tmp" "$F/db/events.jsonl"
b=$(wc -l < "$LOG")
: > "$REQ"
run_lane DEQUEUE_WATCH_ACT=1
grep -qF "nothing gathered" <<<"$(tail -n +"$((b + 1))" "$LOG")" && bad "a rule-break row owned a bystander run at gather" || ok
[ "$(cnt '/files?per_page=100')" -ge 1 ] && ok || bad "O6-neg did not gather again"

# ── C1: acted counts only real actions ────────────────────────────────────────
base C1
list_prs 101 102 103
for n in 102 103; do payload "$n" "$FX/payload-dequeued-batch1.md" 120; pull "$n" "$HEAD"; files "$n" "$FX/pr-files-101.json"; done
mkdir -p "$F/db/actions"
jq -nc --arg h "$HEAD" '{repo: "example-org/cromford", pr: 102, head: $h, class: "rule-break", action: "fix-round", project: "proj", status: "claimed"}' \
  > "$F/db/actions/example-org_cromford_102_${HEAD}_rule-break"
run_lane DEQUEUE_WATCH_ACT=1 ROUNDS_FAIL_PR=103
lastsum | grep -qE ' acted=1 would=0 owned=1 unread=1 ' && ok || bad "summary '$(lastsum)' should say acted=1 would=0 owned=1 unread=1"
eq "fix-round POSTs" "$(cnt 'JOBS POST /api/fix-rounds')" 1

# ── T1: the timeout wrapper writes the summary the killed tick could not ──────
base T1
b=$(sums)
start=$(date +%s)
env -i "${LANE_ENV[@]}" HARNESS_TEST_SANDBOX=1 DEQUEUE_WATCH_FIXTURE="$FX/slow.bh-3859.sh" DEQUEUE_WATCH_TICK_TIMEOUT_S=1 \
  bash "$H/bin/dequeue-watch.sh" > "$T/lane.out" 2> "$T/lane.err"; rc=$?
eq "rc of a timed-out tick" "$rc" 0
eq "summary lines" "$(( $(sums) - b ))" 1
lastsum | grep -qE ' tick timed-out$' && ok || bad "last summary is '$(lastsum)', wanted ' tick timed-out'"
eq "tick projects= lines" "$(grep -c ' tick projects=' "$LOG")" 0
[ $(( $(date +%s) - start )) -lt 5 ] && ok || bad "the 1 s test timeout did not bound the tick"
( exec 8>"$H/locks/dequeue-watch.lock"; flock -n 8 ) && ok || bad "the lock is still held after the timed-out tick"

# ── T1-seam: outside the sandbox the 1 s value is ignored (240 s applies) ────
base T1-seam
: > "$H/fleet.conf"
b=$(sums)
timeout 3 env -i "${LANE_ENV[@]}" PATH="$T/slowshim:$T/shim:$PATH" DEQUEUE_WATCH_TICK_TIMEOUT_S=1 \
  bash "$H/bin/dequeue-watch.sh" > "$T/lane.out" 2> "$T/lane.err"; rc=$?
eq "rc of the outer 3 s timeout" "$rc" 124
eq "timed-out lines outside the sandbox" "$(cat "$LOG" 2>/dev/null | grep -c " tick timed-out$")" 0
# Let the orphaned tick finish before the scratch tree goes away.
for i in $(seq 1 20); do [ "$(( $(sums) - b ))" -ge 1 ] && break; sleep 0.5; done

echo "dequeue-watch-ship-dark: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
