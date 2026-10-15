#!/bin/bash
# tests/conductor-worker-steps.bh-6346-test.sh — BH-6346: a merge-conductor
# worker names its step at a deadline kill, stops at a GitHub 401, and never
# waits on a project lock past its own deadline.
#
# Sentry CROMFORD-HARNESS-A: 119 conductor-worker-deadline events, and the one
# for cromford#6176 said `at stage: unknown`. The stage was the last log
# line that named the PR, and a worker that logged nothing before it stalled
# gave nothing. bin/lib/fanin.sh now keeps a step trail per worker (mc_step),
# and the kill reads it.
#
#   A1  a worker killed at its deadline: the log line, the lane alert and the
#       tally name the step (ci-read) and the seconds of each earlier step
#   A2  the same kill's Sentry event carries a non-empty `step` tag
#   A3  a stubbed gh that answers HTTP 401: the worker ends in under 60s, logs
#       one AUTH_401 line, sends no request twice, leaves the row as it was
#   A4  a PR whose lock another worker holds is skipped in under 5s
#   A5  a READY transition with an APPROVE on the head still enqueues in time
#   U1  _mc_steps_summary over fixed step files
#   U2  the deadline mark round-trip through mc_worker_bounded and
#       mc_fanin_outcome, with a tab in the stage
#   U3  mc_step: append, the auth exit, and the no-op cases
#   U4  mc_lock_wait_left's table
#   U5  sentry_report's 6th argument (extra tags)
#   U6  gh_rest after a 401 in a worker: no second request
#   U7  gh_rest after a 401 outside a worker: unchanged
#   U8  the gh() wrapper marks a 401 and changes nothing else
#   U9  mc_merge_locked / mc_git_locked cap their wait at the worker deadline
#   U10 no deadline: the 401 stop still returns to mc_worker_bounded; old
#       trails a killed tick left are swept
#
# Run from anywhere: tests/conductor-worker-steps.bh-6346-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v setsid >/dev/null || { echo "setsid missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
NOW=$(date +%s)
SLUG=example-org/demo
U="https://github.com/$SLUG/pull"
PRS="41 42 43 44"
hd() { printf '%02d%038d' "$1" 0; }

# ---- the scratch harness: the REAL backstop and conductor, gh/curl stubbed ----
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state/merge-conductor" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
for s in bin/merge-conductor-backstop.sh bin/merge-conductor.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
# The unit cases (U*) source the repo's libs; the conductor runs the scratch
# copies. gh-limit-logger.sh wraps gh in a function that calls `command gh`,
# which would step around tests/lib/gh-list-bridge.sh; U8 drives it on its own.
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
# BH-4148 (#4614): the lead's protected paths are worker rows, not
# catalog/lead-protected-paths.tsv; the fake worker answers the route with no
# rows for the repo (tests/lib/lpp-stub.sh), as the deleted TSV did.
mkdir -p "$T/h/catalog" "$T/fakebin"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_install "$T/fakebin" "$T/lpp-rows.json" "$T/lpp-down"
printf 'demo %s - - 2 box-m\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
for n in $PRS; do
  REC="$T/h/builds/pool-demo-DM-$n-202610130001"; mkdir -p "$REC"
  echo "PR_CREATED $U/$n" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  hd "$n" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
list() { local n first=1; printf '['
  for n in $PRS; do [ "$first" = 1 ] || printf ','; first=0
    printf '{"number":%s,"url":"%s/%s","headRefOid":"%s","headRefName":"ticket/dm-%s","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}' \
      "$n" "$U" "$n" "$(hd "$n")" "$n"
  done; printf ']\n'; }
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The gh stub. Every call is logged; the PR number is read off the path, or off
# the head sha in a commits/<sha> or head_sha=<sha> read. Two fixture seams:
#   $T/slowpat-<n>  a per-PR call for #n whose argv holds this text sleeps
#                   $T/slow-<n> seconds (default 60): the slow read (A1, A2)
#   $T/auth401-<n>  every REST GET of pulls/<n> or issues/<n> answers HTTP 401
#                   Bad credentials, rc 1, and lands in $T/auth-calls.txt (A3)
# The open list's own lazy per-PR reads are never slowed or refused: the list
# runs in the tick, before any worker.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/c-calls.txt"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
[ -n "\$N" ] || N=\$(grep -oE '(commits/|head_sha=)[0-9]{2}0{38}' <<<"\$A" | head -1 | grep -oE '[0-9]{40}' | cut -c1-2 | sed 's/^0//')
if [ -n "\$N" ] && [ "\${HPL_READ_ROLE:-}" != list-lazy ]; then
  if [ -e "$T/auth401-\$N" ]; then
    case "\$A" in "api -i -X GET repos/$SLUG/pulls/\$N"*|"api -i -X GET repos/$SLUG/issues/\$N"*)
      printf '%s\n' "\$A" >> "$T/auth-calls.txt"
      printf 'HTTP/2.0 401 Unauthorized\r\n\r\n{"message":"Bad credentials"}\n'
      echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1 ;;
    esac
  fi
  if [ -e "$T/slowpat-\$N" ] && [[ "\$A" == *"\$(cat "$T/slowpat-\$N")"* ]]; then
    Z=\$(cat "$T/slow-\$N" 2>/dev/null); sleep "\${Z:-60}"
  fi
fi
HEADN=\$(printf '%02d%038d' "\${N:-0}" 0)
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments -f body=@mergifyio queue"*)
    printf '%s\n' "\$A" >> "$T/c-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"api -X POST repos/$SLUG/issues/"*"/labels -f labels[]=merge-queue"*) printf '%s\n' "\$A" >> "$T/c-writes.txt"; : > "$T/queued-\$N" ;;
  *"api -X POST repos/"*"/issues/"*) printf '%s\n' "\$A" >> "$T/c-writes.txt" ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$A" >> "$T/c-writes.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$A" >> "$T/c-comments.txt"; restpr --raw 201 '{"id":1}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*) printf '%s\n' "\$A" >> "$T/c-writes.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"api repos/"*"/issues/"*"/comments"*) : ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api repos/$SLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$N" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) LB=""; [ -e "$T/queued-\$N" ] && LB=merge-queue,queued
    restpr OPEN "\$HEADN" "ticket/dm-\$N" main "\$LB" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  *"/api/lead-protected-paths"*) "\$(dirname "\$0")/lpp-answer" "\$M" "\$URL"; exit 0 ;;
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"the-lead"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# The Sentry curl: keeps each envelope it is handed, answers 200.
cat > "$T/fakebin/sentry-curl" <<EOF
#!/bin/bash
cat > /dev/null
f=""; while [ \$# -gt 0 ]; do case "\$1" in --data-binary) f="\${2#@}"; shift 2 ;; *) shift ;; esac; done
k=\$(ls "$T"/sentry-env-*.txt 2>/dev/null | wc -l)
[ -n "\$f" ] && cp "\$f" "$T/sentry-env-\$k.txt"
printf 200
EOF
chmod +x "$T/fakebin/sentry-curl"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge" "$T/h/flags/conductor-owns-merges"
CLOG="$T/h/logs/merge-conductor.log"
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
# row <state> <n> — one pr-state row, approved on its head.
row() { printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$SLUG#$2" "$1" $((NOW-600)) "$(hd "$2")" "$(hd "$2")" "$U" "$2"; }
reset_calls() { : > "$T/c-posts.txt"; : > "$T/c-calls.txt"; : > "$T/c-alerts.txt"; : > "$T/auth-calls.txt"; touch "$T/c-writes.txt" "$T/c-comments.txt"; }
fresh() { scratch_rm "$T/h/state"; mkdir -p "$T/h/state/merge-conductor"; rm -f "$T"/slowpat-* "$T"/slow-* "$T"/auth401-* "$T"/queued-*; reset_calls; }
# bs [env...] — one backstop fire in its own session; output in $T/bs.out.
# TEST-CHANGE (BH-6000, #6015): the backstop starts one DETACHED keyed run per
# candidate and returns at once; bs then waits for every run to end (each holds
# its locks/mc-backstop-<key>.lock for its whole life), so the cases below read
# finished runs exactly as before. The same wait as tests/merge-path-stall.bh-4918.
bs() { ( cd "$T" && setsid -w env -u MC_ONLY_PR PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-fixture-default \
  MC_BACKSTOP_MAX_KEYS=0 MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0 "$@" \
  bash "$T/h/bin/merge-conductor-backstop.sh" > "$T/bs.out" 2>&1 ) 2>/dev/null
  local lk; for lk in "$T/h/locks"/mc-backstop-*.lock; do [ -e "$lk" ] && flock -w 300 "$lk" true 2>/dev/null; done; sleep 0.5; }
since() { tail -n +"$(( ${1:-0} + 1 ))" "$CLOG" 2>/dev/null; }
loglen() { if [ -f "$CLOG" ]; then wc -l < "$CLOG"; else echo 0; fi; }
tally() { since "$1" | grep -F "FANIN merge-conductor $SLUG:" | tail -1; }

# ============================================================================
# U — the pieces, on the repo's own libs, each in a subshell.
# ============================================================================
UL="$T/u"; mkdir -p "$UL"
# U1 — _mc_steps_summary.
( . "$DIR/bin/lib/fanin.sh"
  printf '100\tstart\n102\tlock-probe\n110\tci-read\n' > "$UL/s1"
  [ "$(_mc_steps_summary "$UL/s1" 130 2>/dev/null)" = $'ci-read\t20\tstart=2s lock-probe=8s' ] && echo ok1 || echo "bad1 $(_mc_steps_summary "$UL/s1" 130 2>&1)"
  : > "$UL/s2"; [ "$(_mc_steps_summary "$UL/s2" 130 2>/dev/null | cut -f1)" = start ] && echo ok2 || echo bad2
  [ "$(_mc_steps_summary "$UL/nope" 130 2>/dev/null | cut -f1)" = start ] && echo ok3 || echo bad3
  i=0; while [ "$i" -lt 200 ]; do printf '%s\tstep-%s\n' $((100 + i)) "$i"; i=$((i + 1)); done > "$UL/s3"
  e=$(_mc_steps_summary "$UL/s3" 400 2>/dev/null | cut -f3)
  [ -n "$e" ] && [ "${#e}" -le 300 ] && echo ok4 || echo "bad4 ${#e}"
) > "$UL/u1.out" 2>&1
grep -qx ok1 "$UL/u1.out" && ok || bad "U1 the summary of start/lock-probe/ci-read at 130 ($(cat "$UL/u1.out"))"
grep -qx ok2 "$UL/u1.out" && ok || bad "U1 an empty step file gives step start"
grep -qx ok3 "$UL/u1.out" && ok || bad "U1 a missing step file gives step start"
grep -qx ok4 "$UL/u1.out" && ok || bad "U1 200 steps cut earlier to 300 bytes ($(cat "$UL/u1.out"))"

# U2 — the mark round-trip: the real watcher writes it, the real reader reads it.
( . "$DIR/bin/lib/fanin.sh"
  mkdir -p "$UL/u2/state"
  SLUG=$SLUG MC_STATE_DIR="$UL/u2/state" MC_TICK_ID=u2 MC_LOG="$UL/u2/log" MC_WORKER_DEADLINE_S=2 MC_FANIN_T0=0
  printf '2026-10-13 00:00:00Z %s#51 a stage\twith a tab\n' "$SLUG" > "$MC_LOG"
  mc_handoff_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
  mc_log() { printf '%s\n' "$*" >> "$UL/u2/out"; }
  mc_attempt_has() { return 1; }; mc_attempt_put() { :; }
  pr_worker() { mc_step lock-probe; sleep 30; }   # determinism: ok the stub worker IS the stall the deadline kills, nothing waits on it
  mc_worker_bounded "51"$'\t'"x"$'\t'"$(hd 51)"
  [ -f "$(_mc_deadline_mark "$SLUG#51")" ] && IFS=$'\t' read -r d stage step step_s earlier kind sto < "$(_mc_deadline_mark "$SLUG#51")"
  printf 'd=%s|stage=%s|step=%s|s=%s|e=%s|kind=%s|sto=%s\n' "${d:-}" "${stage:-}" "${step:-}" "${step_s:-}" "${earlier:-}" "${kind:-}" "${sto:-}"
  w=$(mc_fanin_outcome 0 "51"$'\t'"x"$'\t'"$(hd 51)"$'\t'"b"$'\t'"false"$'\t'"CLEAN")
  echo "word=$w"
  ls "$UL/u2/state/worker-deadline" 2>/dev/null | sed 's/^/left=/'
  # No log line for the PR: the stage is empty, and the step must not move into it.
  : > "$MC_LOG"; mv "$UL/u2/out" "$UL/u2/out51"
  mc_worker_bounded "53"$'\t'"x"$'\t'"$(hd 53)"
  mc_fanin_outcome 0 "53"$'\t'"x"$'\t'"$(hd 53)"$'\t'"b"$'\t'"false"$'\t'"CLEAN" > /dev/null
  sed 's/^/empty: /' "$UL/u2/out"
) > "$UL/u2.out" 2>&1
grep -Eq '^d=2\|stage=.*a stage with a tab\|step=lock-probe\|s=[0-9]+\|e=start=[0-9]+s\|kind=deadline\|sto=[0-9]+$' "$UL/u2.out" && ok || bad "U2 the mark (5 fields, BH-6351's kind and step timeout after them), the tab flattened ($(cat "$UL/u2.out"))"
grep -Eq "WORKER_DEADLINE: worker killed after 2s on 51000000 at stage: .*a stage with a tab \| step: lock-probe \([0-9]+s\) \| earlier: start=[0-9]+s" "$UL/u2/out51" 2>/dev/null \
  && ok || bad "U2 the WORKER_DEADLINE line from the mark ($(cat "$UL/u2/out51" 2>/dev/null))"
grep -qx 'word=killed:deadline' "$UL/u2.out" && ok || bad "U2 the outcome is killed:deadline"
! grep -q '^left=' "$UL/u2.out" && ok || bad "U2 nothing left under worker-deadline/ ($(grep '^left=' "$UL/u2.out"))"
grep -Eq "^empty: $SLUG#53 WORKER_DEADLINE: worker killed after 2s on 53000000 at stage: lock-probe \| step: lock-probe \([0-9]+s\) \| earlier: start=[0-9]+s \| calls: none$" "$UL/u2.out" \
  && ok || bad "U2 an empty stage reads as the step (BH-6462) and the step stays the step ($(grep '^empty:' "$UL/u2.out"))"

# U3 — mc_step.
( . "$DIR/bin/lib/fanin.sh"
  KEY="$SLUG#52"; MC_LOG="$UL/u3.log"; mc_log() { printf '%s\n' "$*" >> "$MC_LOG"; }
  : > "$UL/u3.auth"
  MC_STEP_FILE="$UL/u3.steps"; printf '%s\tstart\n' "$NOW" > "$MC_STEP_FILE"
  unset GH_REST_AUTH_FAIL_FILE
  mc_step lock-probe; echo "rc1=$? lines=$(wc -l < "$MC_STEP_FILE")"
  ( GH_REST_AUTH_FAIL_FILE="$UL/u3.none"; mc_step head-lag; echo "noexit-nofile" )
  ( GH_REST_AUTH_FAIL_FILE=""; mc_step head-lag; echo "noexit-empty" )
  ( GH_REST_AUTH_FAIL_FILE="$UL/u3.auth"; FANIN_STAGE_FILE="$UL/u3.stage"; mc_step ci-read; echo "noexit-auth" ); echo "sub=$?"
  ( unset MC_STEP_FILE; mc_step x; echo "rc4=$?" )
) > "$UL/u3.out" 2>&1
grep -qx 'rc1=0 lines=2' "$UL/u3.out" && ok || bad "U3 the var unset and a stale .auth on disk: one line appended, no exit ($(cat "$UL/u3.out"))"
grep -qx noexit-nofile "$UL/u3.out" && grep -qx noexit-empty "$UL/u3.out" && ok || bad "U3 no exit with the var set and no file, or the var empty"
! grep -qx noexit-auth "$UL/u3.out" && grep -qx 'sub=0' "$UL/u3.out" && ok || bad "U3 the var set and the file present: the subshell exits 0 ($(cat "$UL/u3.out"))"
grep -q "^$SLUG#52 AUTH_401: a GitHub call answered HTTP 401 during step head-lag; worker stopped after [0-9]*s before step ci-read, the next tick retries$" "$UL/u3.log" 2>/dev/null \
  && ok || bad "U3 one AUTH_401 line naming the last step ($(cat "$UL/u3.log" 2>/dev/null))"
[ -f "$UL/u3.stage.auth" ] && ok || bad "U3 the stage marker .auth is written"
grep -qx 'rc4=0' "$UL/u3.out" && ok || bad "U3 MC_STEP_FILE unset: no write, rc 0"

# U10 — no deadline (MC_WORKER_DEADLINE_S=0): the 401 stop still comes back to
# mc_worker_bounded, which removes the trail; a day-old trail a killed tick
# left is swept, a fresh one of another worker is kept.
( . "$DIR/bin/lib/fanin.sh"
  SLUG=$SLUG KEY="$SLUG#54" MC_STATE_DIR="$UL/u10/state" MC_TICK_ID=u10 MC_WORKER_DEADLINE_S=0 FANIN_STAGE_FILE="$UL/u10/stage"
  mc_handoff_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
  mc_log() { printf '%s\n' "$*" >> "$UL/u10/log"; }
  mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; mc_row_field() { echo READY; }
  mkdir -p "$MC_STATE_DIR/worker-deadline"
  : > "$MC_STATE_DIR/worker-deadline/old.t1.steps"; : > "$MC_STATE_DIR/worker-deadline/old.t1.auth"
  touch -d "@$((NOW - 90000))" "$MC_STATE_DIR/worker-deadline/old.t1.steps" "$MC_STATE_DIR/worker-deadline/old.t1.auth"
  : > "$MC_STATE_DIR/worker-deadline/new.t1.steps"
  pr_worker() { mc_step lock-probe; : > "$GH_REST_AUTH_FAIL_FILE"; mc_step head-lag; echo not-reached; }
  mc_worker_bounded "54"$'\t'"x"$'\t'"$(hd 54)"; echo "rc=$?"
  echo "word=$(mc_fanin_outcome 0 "54"$'\t'"x"$'\t'"$(hd 54)"$'\t'"b"$'\t'"false"$'\t'"CLEAN")"
  ls "$MC_STATE_DIR/worker-deadline" | sed 's/^/left=/'
) > "$UL/u10.out" 2>&1
grep -qx 'rc=0' "$UL/u10.out" && ! grep -q not-reached "$UL/u10.out" && ok || bad "U10 the worker stops at the boundary after the 401, rc 0 ($(cat "$UL/u10.out"))"
grep -q "^$SLUG#54 AUTH_401: a GitHub call answered HTTP 401 during step lock-probe; worker stopped after [0-9]*s before step head-lag" "$UL/u10/log" 2>/dev/null \
  && ok || bad "U10 one AUTH_401 line with no deadline set ($(cat "$UL/u10/log" 2>/dev/null))"
grep -qx 'word=skipped:auth' "$UL/u10.out" && ok || bad "U10 the outcome is skipped:auth ($(cat "$UL/u10.out"))"
[ "$(grep '^left=' "$UL/u10.out" | tr '\n' ' ')" = 'left=new.t1.steps ' ] && ok || bad "U10 the worker's own trail and the day-old trail are gone, the fresh one kept ($(grep '^left=' "$UL/u10.out" | tr '\n' ' '))"

# U4 — mc_lock_wait_left. u4 <seconds left, or unset/abc> <configured>: the
# deadline is set from the clock the function itself reads, one call before it.
u4() { ( . "$DIR/bin/lib/fanin.sh"
  case "$1" in unset) unset MC_WORKER_DEADLINE_AT ;; abc) MC_WORKER_DEADLINE_AT=abc ;;
    *) printf -v n '%(%s)T' -1; MC_WORKER_DEADLINE_AT=$((n + $1)) ;; esac   # determinism: ok the function under test reads this same clock
  out=$(mc_lock_wait_left "$2"); echo "$out rc=$?" ); }
[ "$(u4 unset 120)" = '120 rc=0' ] && ok || bad "U4 no deadline: 120 ($(u4 unset 120))"
[ "$(u4 abc 120)" = '120 rc=0' ] && ok || bad "U4 a garbage deadline: 120 ($(u4 abc 120))"
[ "$(u4 600 120)" = '120 rc=0' ] && ok || bad "U4 600s left: 120 ($(u4 600 120))"
[ "$(u4 136 120)" = '120 rc=0' ] && ok || bad "U4 the edge left-15 >= configured: 120 ($(u4 136 120))"
case "$(u4 100 120)" in '85 rc=0'|'84 rc=0') ok ;; *) bad "U4 100s left: 85 ($(u4 100 120))" ;; esac
[ "$(u4 15 120)" = ' rc=1' ] && ok || bad "U4 15s left: rc 1, nothing printed ($(u4 15 120))"
[ "$(u4 5 120)" = ' rc=1' ] && ok || bad "U4 5s left: rc 1 ($(u4 5 120))"
[ "$(u4 -10 120)" = ' rc=1' ] && ok || bad "U4 past: rc 1 ($(u4 -10 120))"

# U5 — sentry_report's 6th argument.
mkdir -p "$UL/u5h/logs" "$UL/u5h/state"
cat > "$UL/u5curl" <<EOF
#!/bin/bash
cat > /dev/null
f=""; while [ \$# -gt 0 ]; do case "\$1" in --data-binary) f="\${2#@}"; shift 2 ;; *) shift ;; esac; done
[ -n "\$f" ] && tail -1 "\$f" > "$UL/u5last.json"
printf 200
EOF
chmod +x "$UL/u5curl"
u5() { rm -f "$T/u/u5last.json"; scratch_rm "$T/u/u5h/state/sentry-report"
  ( unset -f gh; . "$DIR/bin/lib/sentry-report.sh"
    HARNESS="$UL/u5h" HARNESS_SENTRY_DSN=https://k-fixture@sentry.test/1 SENTRY_MAX_PER_FP_HOUR=50 \
    HARNESS_SENTRY_CURL="$UL/u5curl" HARNESS_CHECKOUT="$UL/none" JOBS_BOX=box-t LANE_GATE_CACHE_S=0 \
      sentry_report warning lane-real reason-x m '{"project":"p"}' "$@" )
  jq -c '.tags' "$UL/u5last.json" 2>/dev/null; }
STD='["box","harness_sha","lane","project","reason"]'
[ "$(u5 '{"step":"ci-read"}' | jq -r '.step')" = ci-read ] && [ "$(u5 '{"step":"ci-read"}' | jq -c '[keys[] | select(. != "step")]')" = "$STD" ] \
  && ok || bad "U5 {step:ci-read} adds the tag next to the five ($(u5 '{"step":"ci-read"}'))"
[ "$(u5 '{"lane":"evil"}' | jq -r '.lane')" = lane-real ] && ok || bad "U5 a standard key wins ($(u5 '{"lane":"evil"}'))"
[ "$(u5 '{"n":5}' | jq -c 'keys')" = "$STD" ] && ok || bad "U5 a non-string value is dropped ($(u5 '{"n":5}'))"
[ "$(u5 '"x"' | jq -c 'keys')" = "$STD" ] && ok || bad "U5 a non-object is ignored ($(u5 '"x"'))"
[ "$(u5 | jq -c 'keys')" = "$STD" ] && ok || bad "U5 no 6th argument: exactly the five ($(u5))"

# U6/U7 — gh_rest after a 401.
mkdir -p "$UL/ubin"
cat > "$UL/ubin/gh" <<EOF
#!/bin/bash
echo x >> "$UL/u6calls"
printf 'HTTP/2.0 401 Unauthorized\r\n\r\n{"message":"Bad credentials"}\n'
echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1
EOF
chmod +x "$UL/ubin/gh"
( unset -f gh; export PATH="$UL/ubin:$PATH" HARNESS="$UL/u6h"; mkdir -p "$HARNESS/logs"
  . "$DIR/bin/lib/gh-rest.sh"
  echo "from=$(shopt -s extdebug; declare -F _gh_auth_gate | awk '{print $3}')"
  GH_REST_AUTH_FAIL_FILE="$UL/u6/a"; mkdir -p "$UL/u6"; : > "$UL/u6calls"
  gh_rest GET repos/o/r/pulls/1 > /dev/null; echo "first rc=$? st=$GH_REST_STATUS why=$GH_REST_REASON file=$([ -f "$UL/u6/a" ] && echo y || echo n) calls=$(wc -l < "$UL/u6calls")"
  gh_rest GET repos/o/r/pulls/2 > /dev/null; echo "second rc=$? st=$GH_REST_STATUS why=$GH_REST_REASON calls=$(wc -l < "$UL/u6calls")"
) > "$UL/u6.out" 2>&1
AUTHLIB="$DIR/bin/lib/gh-rest-auth.sh"
grep -qxF "from=$AUTHLIB" "$UL/u6.out" && ok || bad "U6 gh-rest.sh loads _gh_auth_gate from bin/lib/gh-rest-auth.sh ($(cat "$UL/u6.out"))"
grep -qx 'first rc=75 st=401 why=auth file=y calls=1' "$UL/u6.out" && ok || bad "U6 the 401: rc 75, reason auth, marker written ($(cat "$UL/u6.out"))"
grep -qx 'second rc=75 st=401 why=auth-skipped calls=1' "$UL/u6.out" && ok || bad "U6 the next call: rc 75, auth-skipped, no request ($(cat "$UL/u6.out"))"
( unset -f gh; export PATH="$UL/ubin:$PATH" HARNESS="$UL/u7h"; mkdir -p "$HARNESS/logs"
  . "$DIR/bin/lib/gh-rest.sh"; unset GH_REST_AUTH_FAIL_FILE; : > "$UL/u6calls"
  gh_rest GET repos/o/r/pulls/1 > /dev/null; echo "first rc=$?"
  gh_rest GET repos/o/r/pulls/2 > /dev/null; echo "second rc=$? calls=$(wc -l < "$UL/u6calls")"
) > "$UL/u7.out" 2>&1
grep -qx 'first rc=75' "$UL/u7.out" && grep -qx 'second rc=75 calls=2' "$UL/u7.out" && ok || bad "U7 no var: the second call reaches gh ($(cat "$UL/u7.out"))"
[ -z "$(find "$UL/u7h" -name '*.auth' -o -name a 2>/dev/null)" ] && ok || bad "U7 no marker file is created"

# U8 — the gh() wrapper.
mkdir -p "$UL/u8bin"
cat > "$UL/u8bin/gh" <<'EOF'
#!/bin/bash
if [ "${1:-}" = clean ]; then echo fine; exit 0; fi
echo out-line; echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1
EOF
chmod +x "$UL/u8bin/gh"
u8() { ( unset -f gh; export PATH="$UL/u8bin:$PATH" HARNESS="$UL/u8h"; mkdir -p "$HARNESS/logs"
  . "$DIR/bin/lib/gh-limit-logger.sh"; "$@" ); }
OUT8=$(u8 eval 'GH_REST_AUTH_FAIL_FILE='"$UL"'/u8a; gh api x 2>'"$UL"'/u8err; echo "rc=$?"')
[ "$OUT8" = $'out-line\nrc=1' ] && [ "$(cat "$UL/u8err")" = 'gh: Bad credentials (HTTP 401)' ] && ok || bad "U8 stdout, stderr and rc unchanged ($OUT8 / $(cat "$UL/u8err"))"
[ -f "$UL/u8a" ] && ok || bad "U8 the marker is written on a 401 with the var set"
rm -f "$UL/u8a"; u8 eval 'unset GH_REST_AUTH_FAIL_FILE; gh api x' >/dev/null 2>&1
[ -z "$(find "$UL" -maxdepth 1 -name u8a)" ] && ok || bad "U8 no marker with the var unset"
OUT8=$(u8 eval 'set -e; GH_REST_AUTH_FAIL_FILE='"$UL"'/u8b; gh clean; echo went-on' 2>&1)
[ "$OUT8" = $'fine\nwent-on' ] && [ ! -e "$UL/u8b" ] && ok || bad "U8 a clean call under set -e returns 0 and the caller goes on ($OUT8)"

# U9 — the project locks cap their wait at the worker deadline.
u9() { ( unset -f gh; export HARNESS="$T/h" H="$T/h"
  . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1; . "$T/h/bin/lib/fanin.sh"
  eval "$1"; s=$SECONDS; "$2" demo true; echo "rc=$? took=$((SECONDS - s))"
  ls -l /proc/$BASHPID/fd 2>/dev/null | grep -c 'merge-conductor-demo-\(merge\|git\).lock' | sed 's/^/fds=/' ); }
for pair in "mc_merge_locked merge" "mc_git_locked git"; do
  set -- $pair
  LKF="$T/h/locks/merge-conductor-demo-$2.lock"
  ( exec 6>"$LKF"; flock 6; : > "$T/u9-held"; sleep 30 ) & LKP=$!
  for _ in $(seq 50); do [ -e "$T/u9-held" ] && break; sleep 0.1; done
  O=$(u9 "MC_WORKER_DEADLINE_AT=$(( $(date +%s) + 16 )); MC_MERGE_LOCK_WAIT=120; MC_GIT_LOCK_WAIT=120" "$1")  # determinism: ok a deadline relative to the live clock the function reads
  case "$O" in "rc=99 took="[01]*fds=0) ok ;; *) bad "U9 $1 with 1s left: 99 at once, no fd left ($O)" ;; esac
  O=$(u9 "unset MC_WORKER_DEADLINE_AT; MC_MERGE_LOCK_WAIT=2; MC_GIT_LOCK_WAIT=2" "$1")
  case "$O" in "rc=99 took="[23]*) ok ;; *) bad "U9 $1 with no deadline waits the knob, 2s ($O)" ;; esac
  kill "$LKP" 2>/dev/null; wait "$LKP" 2>/dev/null; rm -f "$T/u9-held"
done

# The A cases run the conductor through the bridge.
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
list > "$T/list.json"

# ============================================================================
# A1 + A2 — a worker killed at its deadline names its step; Sentry is tagged.
# ============================================================================
fresh; row READY 41 > "$ROWS"
echo actions/runs > "$T/slowpat-41"; echo 60 > "$T/slow-41"
M0=$(loglen)
bs MC_WORKER_DEADLINE_S=8 MC_BACKSTOP_TIMEOUT_S=120 \
   HARNESS_SENTRY_DSN=https://k-fixture@sentry.test/1 SENTRY_MAX_PER_FP_HOUR=5 HARNESS_SENTRY_CURL="$T/fakebin/sentry-curl"
WL=$(since "$M0" | grep -F "$SLUG#41 WORKER_DEADLINE: worker killed after 8s on 41000000 at stage: ")
[ "$(grep -c . <<<"$WL")" = 1 ] && ok || bad "A1 one WORKER_DEADLINE line for #41 (got: ${WL:-none}; bs: $(tail -3 "$T/bs.out"))"
SS=$(grep -oE '\| step: ci-read \([0-9]+s\)' <<<"$WL" | grep -oE '[0-9]+')
[ -n "$SS" ] && [ "$SS" -ge 5 ] && ok || bad "A1 the line names step ci-read with >= 5s (got: ${WL:-none})"
for s in start lock-probe head-lag verdict-read rebase-result; do
  grep -qE "\| earlier: (.* )?$s=[0-9]+s( |$)" <<<"$WL" && ok || bad "A1 earlier names $s=<n>s (got: ${WL:-none})"
done
grep -qE 'killed:deadline( rc=[0-9]+)? 1(,|\))' <<<"$(tally "$M0")" && ok || bad "A1 the tally counts one killed:deadline ($(tally "$M0"))"
AL=$(grep -F "WORKER_DEADLINE $SLUG#41" "$T/c-alerts.txt")
[ "$(grep -c . <<<"$AL")" = 1 ] && grep -q 'step: ci-read' <<<"$AL" && ok || bad "A1 one lane alert naming step ci-read (got: ${AL:-none})"
[ -z "$(find "$T/h/state/merge-conductor/worker-deadline" -type f 2>/dev/null)" ] && ok || bad "A1 nothing left under worker-deadline/ ($(find "$T/h/state/merge-conductor/worker-deadline" -type f))"
EV=$(for f in "$T"/sentry-env-*.txt; do [ -f "$f" ] && tail -1 "$f"; done | jq -c 'select(.tags.reason == "conductor-worker-deadline")' 2>/dev/null | head -1)
[ "$(jq -r '.tags.step // empty' <<<"$EV" 2>/dev/null)" = ci-read ] && ok || bad "A2 the Sentry event has tags.step == ci-read (event: ${EV:-none})"
jq -e '.extra.step_s | test("^[0-9]+$")' <<<"$EV" >/dev/null 2>&1 && ok || bad "A2 extra.step_s is a number of seconds (event: ${EV:-none})"

# ============================================================================
# A3 — a 401 stops the worker: it does not run to its deadline.
# ============================================================================
fresh; row READY 42 > "$ROWS"; touch "$T/auth401-42"
M0=$(loglen); S0=$SECONDS
bs MC_WORKER_DEADLINE_S=600 MC_BACKSTOP_TIMEOUT_S=900
A3_S=$((SECONDS - S0))
[ "$A3_S" -lt 60 ] && ok || bad "A3 the fire ends in under 60s (took ${A3_S}s)"
[ "$(since "$M0" | grep -c "$SLUG#42 AUTH_401: a GitHub call answered HTTP 401 during step ")" = 1 ] && ok \
  || bad "A3 one AUTH_401 line for #42 (log: $(since "$M0" | grep -F '#42' | tail -5))"
grep -q 'skipped:auth 1' <<<"$(tally "$M0")" && ! grep -q 'killed:deadline' <<<"$(tally "$M0")" && ok || bad "A3 the tally has skipped:auth 1 and no killed:deadline ($(tally "$M0"))"
[ -s "$T/auth-calls.txt" ] && ok || bad "A3 setup: the stub answered at least one 401"
[ -z "$(sort "$T/auth-calls.txt" | uniq -d)" ] && ok || bad "A3 no 401 read is sent twice ($(sort "$T/auth-calls.txt" | uniq -c | sort -rn | head -3))"
! grep -rqs "mergefail $SLUG#42" "$T/h/state/merge-conductor" && ok || bad "A3 no mergefail attempt for #42"
IFS=$'\t' read -r _ A3ST _ A3H _ <<<"$(grep -F "$SLUG#42"$'\t' "$ROWS")"
[ "${A3ST:-}" = READY ] && [ "${A3H:-}" = "$(hd 42)" ] && ok || bad "A3 the row is left READY on the same head ($(grep -F "$SLUG#42" "$ROWS"))"
! grep -q "AUTH_401" "$T/c-alerts.txt" && ok || bad "A3 AUTH_401 pages nothing"

# ============================================================================
# A4 — a PR whose lock another worker holds is skipped, never waited on.
# ============================================================================
fresh; row READY 43 > "$ROWS"
S0=$SECONDS; bs MC_MERGE_BUDGET=0; T_FREE=$((SECONDS - S0))
fresh; row READY 43 > "$ROWS"; M0=$(loglen)
LK="$T/h/locks/merge-conductor-demo-43.lock"
( exec 9>"$LK"; flock 9; : > "$T/lk-held"; sleep 60 ) & LKP=$!
for _ in $(seq 50); do [ -e "$T/lk-held" ] && break; sleep 0.1; done
S0=$SECONDS; bs MC_MERGE_BUDGET=0; T_LOCK=$((SECONDS - S0))
kill "$LKP" 2>/dev/null; wait "$LKP" 2>/dev/null; rm -f "$T/lk-held"
[ "$T_LOCK" -le $((T_FREE + 5)) ] && ok || bad "A4 the locked fire is not slower than the free one by 5s (free ${T_FREE}s, locked ${T_LOCK}s)"
since "$M0" | grep -q "$SLUG#43: an earlier conductor worker still holds this PR's lock — skipped" && ok || bad "A4 the lock-skip line ($(since "$M0" | grep -F '#43' | tail -3))"
grep -q 'READY held:worker-locked 1' <<<"$(tally "$M0")" && ok || bad "A4 READY held:worker-locked ($(tally "$M0"))"

# ============================================================================
# A5 — a READY transition (APPROVE on the head, CLEAN) still enqueues in time.
# The row starts WAIT_CI: the backstop picks only WAIT_CI and READY rows.
# ============================================================================
fresh; row WAIT_CI 44 > "$ROWS"; M0=$(loglen)
S0=$SECONDS; bs MC_MERGE_BUDGET=5 MC_WORKER_DEADLINE_S=600; A5_S=$((SECONDS - S0))
[ "$A5_S" -lt 600 ] && [ "$A5_S" -lt 120 ] && ok || bad "A5 the fire ends in under 120s (took ${A5_S}s)"
{ [ "$(grep -F "$SLUG#44"$'\t' "$ROWS" | cut -f2)" = QUEUED ] || grep -q 'issues/44/labels' "$T/c-writes.txt"; } && ok \
  || bad "A5 #44 is enqueued (row: $(grep -F "$SLUG#44" "$ROWS"); log: $(since "$M0" | grep -F '#44' | tail -3))"
! grep -qE 'killed:deadline|skipped:auth|READY unexplained' <<<"$(tally "$M0")" && ok || bad "A5 no kill, auth skip or unexplained READY ($(tally "$M0"))"
! grep -q 'AUTH_401' <<<"$(since "$M0")" && ok || bad "A5 no AUTH_401 on a healthy fire"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "conductor-worker-steps.bh-6346: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
