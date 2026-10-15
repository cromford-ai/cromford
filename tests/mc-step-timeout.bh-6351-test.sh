#!/bin/bash
# tests/mc-step-timeout.bh-6351-test.sh — BH-6351: a merge-conductor worker
# step that runs past MC_STEP_TIMEOUT_S ends the worker with a named
# STEP_TIMEOUT before the worker deadline; a READY-path worker logs
# STEP_START / STEP_END per step; a slow step logs STEP_SLOW while it runs; the
# WORKER_DEADLINE Sentry event carries a `step` tag and no copied log line.
#
# Sentry CROMFORD-HARNESS-G: project-6#191 was killed at its 600 s deadline
# 158 s after its `-> READY` line, and the event title was that log line. It
# did not name the step.
#
#   U1  mc_step writes the trail with a log flag; mc_step_read reads the last line
#   U2  MC_STEP_LOG=1: STEP_START / STEP_END per step, mc_step_close ends the last
#   U3  MC_STEP_LOG=0: only a slow step gets a STEP_END, with started=
#   U4  a bad name is written as `unknown`; no MC_STEP_FILE: no write, rc 0
#   S1  sentry_report extra.tags becomes a tag and leaves extra
#   S2  extra.tags: a core key cannot win, bad keys and values are dropped,
#       at most 8 pass, a value is cut to 200 chars
#   S3  no .tags: the five core tags only
#   S4  a 2-field mark (older writer): killed:deadline, tags.step == unknown
#   T1  a READY row stalled in dep-gate: STEP_TIMEOUT before the deadline, the
#       row left READY, the tally counts killed:step-timeout
#   T2  the deadline path: the Sentry title names the step and holds no log line
#   T3  the STEP_START/END lines of T1's READY worker; none for a fast WAIT_CI row
#   T4  a slow step logs one STEP_SLOW while it runs
#   R1  the tick after T1 (no stall) enqueues the PR: the lock was not held over
#   W2  MC_STEP_TIMEOUT_S=0: the deadline fires (covered by T2's tick)
#   W3  a second step timeout on the same head and step: no second alert or event
#   W4  MC_STEP_TIMEOUT_S >= the deadline: the deadline fires and names the step
#   W5  the enqueue step's floor: a wait under the floor is not killed
#   L1  the READY re-kick's PR lock wait (MC_PR_LOCK_WAIT_S) is not a stall:
#       lock-probe's timeout is the step timeout plus that wait; with no
#       wait a stalled lock-probe is still killed
#   W6  nothing is left under worker-deadline/ after a tick
#   K1  MC_STEP_TIMEOUT_S=abc reads as 240; the catalog lists the 3 knobs with
#       the same defaults as the code fallback
#   G1  no GitHub write verb beyond the enqueues in R1 and W5
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-step-timeout.bh-6351-test.sh   (exit 0 = all pass)
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
PRS="191 192"
# The head of #191 is project-6#191's head prefix; #192 is a plain fixture head.
hd() { if [ "$1" = 191 ]; then printf '6d12eb15%032d' 0; else printf '%03d%037d' "$1" 0; fi; }

# ---- the scratch harness: the REAL backstop and conductor, gh/curl stubbed ----
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state/merge-conductor" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
for s in bin/merge-conductor-backstop.sh bin/merge-conductor.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
# gh-limit-logger.sh wraps gh in a function that calls `command gh`, which would
# step around tests/lib/gh-list-bridge.sh; the conductor sources it optionally.
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
# Two stall seams, appended to the scratch copies (never the repo's):
#   $T/stall-<n>     pdg_hold (step dep-gate) sleeps that many seconds for #n
#   $T/enqstall-<n>  mc_enqueue (step enqueue) sleeps that many seconds for #n
cat >> "$T/h/bin/lib/pr-dep-gate.sh" <<EOF

eval "_fx_pdg_real() \$(declare -f pdg_hold | tail -n +2)"
pdg_hold() { [ -e "$T/stall-\$2" ] && sleep "\$(cat "$T/stall-\$2")"; _fx_pdg_real "\$@"; }
EOF
cat >> "$T/h/bin/lib/mc/queue.sh" <<EOF

eval "_fx_enq_real() \$(declare -f mc_enqueue | tail -n +2)"
mc_enqueue() { local n="\${1##*/}"; [ -e "$T/enqstall-\$n" ] && sleep "\$(cat "$T/enqstall-\$n")"; _fx_enq_real "\$@"; }
EOF
mkdir -p "$T/h/catalog" && cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$T/h/catalog/" || exit 1
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
# the head sha. $T/cipend-<n>: #n's CI is still running (it stays WAIT_CI).
# The enqueue's own writes (the merge-queue label, `@mergifyio queue`, the
# verdict statuses on the head) go to c-enq.txt; any other write to c-writes.txt.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/c-calls.txt"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
if [ -z "\$N" ]; then
  case "\$A" in *6d12eb15*) N=191 ;; *1920000000000000000000000000000000000000*) N=192 ;; esac
fi
if [ "\${N:-}" = 191 ]; then HEADN=\$(printf '6d12eb15%032d' 0); else HEADN=\$(printf '%03d%037d' "\${N:-0}" 0); fi
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"check-runs"*) if [ -e "$T/cipend-\$N" ]; then restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"in_progress","conclusion":null,"started_at":"2026-10-13T10:00:00Z"}]}'
    else restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-13T10:00:00Z"}]}'; fi ;;
  *"repos/$SLUG/issues/"*"/comments -f body=@mergifyio queue"*)
    printf '%s\n' "\$A" >> "$T/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"-X POST repos/$SLUG/statuses/"*) printf '%s\n' "\$A" >> "$T/c-enq.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/$SLUG/issues/"*"/labels -f labels[]=merge-queue"*) printf '%s\n' "\$A" >> "$T/c-enq.txt"; : > "$T/queued-\$N" ;;
  *"api -X POST repos/"*"/issues/"*) printf '%s\n' "\$A" >> "$T/c-writes.txt" ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$A" >> "$T/c-writes.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$A" >> "$T/c-writes.txt"; restpr --raw 201 '{"id":1}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*) printf '%s\n' "\$A" >> "$T/c-writes.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"api repos/"*"/issues/"*"/comments"*) : ;;
  *"actions/runs?head_sha="*) if [ -e "$T/cipend-\$N" ]; then restpr --runs 'in_progress|'; else restpr --runs 'completed|success'; fi ;;
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
case "\$URL" in *"/api/lead-protected-paths"*) "\$(dirname "\$0")/lpp-answer" "\$M" "\$URL"; exit 0 ;; esac
case "\$M \$URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"the-lead"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# BH-4148: the lead reads protected paths from the jobs route. The demo repo has
# no rows, so it is not governed, as it was under the old catalog file.
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$T/lpp.json" "$SLUG"
lpp_install "$T/fakebin" "$T/lpp.json" "$T/lpp-down"
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
WDIR="$T/h/state/merge-conductor/worker-deadline"
# row <state> <n> — one pr-state row, approved on its head.
row() { printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$SLUG#$2" "$1" $((NOW-600)) "$(hd "$2")" "$(hd "$2")" "$U" "$2"; }
reset_calls() { : > "$T/c-calls.txt"; : > "$T/c-alerts.txt"; : > "$T/c-enq.txt"; touch "$T/c-writes.txt"; }
fresh() { scratch_rm "$T/h/state"; mkdir -p "$T/h/state/merge-conductor"; rm -f "$T"/stall-* "$T"/enqstall-* "$T"/cipend-* "$T"/queued-* "$T"/sentry-env-*.txt; reset_calls; }
SENTRY=(HARNESS_SENTRY_DSN=https://k-fixture@sentry.test/1 SENTRY_MAX_PER_FP_HOUR=5 HARNESS_SENTRY_CURL="$T/fakebin/sentry-curl")
# bs [env...] — one backstop fire in its own session; output in $T/bs.out.
bs() { ( cd "$T" && setsid -w env -u MC_ONLY_PR PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-fixture-default \
  MC_BACKSTOP_MAX_KEYS=0 MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0 \
  MC_BACKSTOP_TIMEOUT_S=120 MC_STEP_POLL_S=1 "${SENTRY[@]}" "$@" \
  bash "$T/h/bin/merge-conductor-backstop.sh" > "$T/bs.out" 2>&1 ) 2>/dev/null
  # BH-6000: the backstop returns at once and each PR's keyed run is detached,
  # holding locks/mc-backstop-<key>.lock until it exits. Wait on those locks.
  local l; for l in "$T"/h/locks/mc-backstop-*.lock; do [ -e "$l" ] && flock -w 150 "$l" true; done; }
since() { tail -n +"$(( ${1:-0} + 1 ))" "$CLOG" 2>/dev/null; }
loglen() { if [ -f "$CLOG" ]; then wc -l < "$CLOG"; else echo 0; fi; }
tally() { since "$1" | grep -F "FANIN merge-conductor $SLUG:" | tail -1; }
events() { local f; for f in "$T"/sentry-env-*.txt; do [ -f "$f" ] && tail -1 "$f"; done | jq -c "select(.tags.reason == \"$1\")" 2>/dev/null; }
leftover() { find "$WDIR" -type f 2>/dev/null | sed 's|.*/||' | tr '\n' ' '; }

# ============================================================================
# U — mc_step, mc_step_read and mc_step_close on the repo's own fanin.sh.
# ============================================================================
UL="$T/u"; mkdir -p "$UL"
# U1 — the trail line and its reader.
( . "$DIR/bin/lib/fanin.sh"
  KEY="$SLUG#1"; mc_log() { :; }; unset GH_REST_AUTH_FAIL_FILE
  MC_STEP_FILE="$UL/u1.steps"; : > "$MC_STEP_FILE"
  mc_step a; IFS=$'\t' read -r t n f <<<"$(mc_step_read "$MC_STEP_FILE")"
  [[ "$t" =~ ^[0-9]+$ ]] && [ "$n" = a ] && [ "$f" = 0 ] && echo ok1 || echo "bad1 $t|$n|$f"
  MC_STEP_LOG=1 mc_step b; IFS=$'\t' read -r t n f <<<"$(mc_step_read "$MC_STEP_FILE")"
  [ "$n" = b ] && [ "$f" = 1 ] && echo ok2 || echo "bad2 $t|$n|$f"
  [ -z "$(mc_step_read "$UL/none" 2>/dev/null)" ] && echo ok3 || echo bad3
  printf 'garbage\n' > "$UL/u1.bad"; [ -z "$(mc_step_read "$UL/u1.bad" 2>/dev/null)" ] && echo ok4 || echo bad4
) > "$UL/u1.out" 2>&1
grep -qx ok1 "$UL/u1.out" && ok || bad "U1 mc_step a, then mc_step_read: <epoch> a 0 ($(cat "$UL/u1.out"))"
grep -qx ok2 "$UL/u1.out" && ok || bad "U1 mc_step b replaces the last line, flag 1 with MC_STEP_LOG=1 ($(cat "$UL/u1.out"))"
grep -qx ok3 "$UL/u1.out" && grep -qx ok4 "$UL/u1.out" && ok || bad "U1 an absent or malformed trail reads as nothing ($(cat "$UL/u1.out"))"

# U2 — MC_STEP_LOG=1: one STEP_START and one STEP_END per step.
( . "$DIR/bin/lib/fanin.sh"
  KEY="$SLUG#2"; mc_log() { printf '%s\n' "$*" >> "$UL/u2.log"; }; unset GH_REST_AUTH_FAIL_FILE
  MC_STEP_FILE="$UL/u2.steps"; : > "$MC_STEP_FILE"; MC_STEP_LOG=1
  mc_step a; mc_step b; mc_step_close "$KEY" rc:0
  [ -e "$MC_STEP_FILE" ] && echo "left" || echo "gone"
) > "$UL/u2.out" 2>&1
U2=$(sed 's/took=[0-9]*s/took=Ns/' "$UL/u2.log" 2>/dev/null)
[ "$U2" = "$SLUG#2 STEP_START step=a
$SLUG#2 STEP_END step=a took=Ns
$SLUG#2 STEP_START step=b
$SLUG#2 STEP_END step=b took=Ns result=rc:0" ] && ok || bad "U2 the four lines in order ($(cat "$UL/u2.log" 2>/dev/null))"
grep -qx gone "$UL/u2.out" && ok || bad "U2 mc_step_close removes the trail ($(cat "$UL/u2.out"))"

# U3 — MC_STEP_LOG=0: a fast step logs nothing; a slow one logs STEP_END started=.
( . "$DIR/bin/lib/fanin.sh"
  KEY="$SLUG#3"; mc_log() { printf '%s\n' "$*" >> "$UL/u3.log"; }; unset GH_REST_AUTH_FAIL_FILE
  MC_STEP_FILE="$UL/u3.steps"; : > "$MC_STEP_FILE"; MC_STEP_LOG=0; MC_STEP_SLOW_S=1
  mc_step fast; mc_step a; sleep 2; mc_step b   # determinism: ok a 2 s step is the slow step under test
  MC_STEP_SLOW_S=0; mc_step c; sleep 1; mc_step d   # determinism: ok slow lines are off at 0
) > "$UL/u3.out" 2>&1
[ "$(grep -c . "$UL/u3.log" 2>/dev/null)" = 1 ] && grep -Eq "^$SLUG#3 STEP_END step=a took=[2-3]s started=[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$UL/u3.log" \
  && ok || bad "U3 one STEP_END for the 2 s step, none for the fast one or with MC_STEP_SLOW_S=0 ($(cat "$UL/u3.log" 2>/dev/null))"
! grep -q STEP_START "$UL/u3.log" 2>/dev/null && ok || bad "U3 no STEP_START with MC_STEP_LOG=0"

# U4 — a bad name, and no MC_STEP_FILE.
( . "$DIR/bin/lib/fanin.sh"
  KEY="$SLUG#4"; mc_log() { printf '%s\n' "$*" >> "$UL/u4.log"; }; unset GH_REST_AUTH_FAIL_FILE
  MC_STEP_FILE="$UL/u4.steps"; : > "$MC_STEP_FILE"
  mc_step "two words"; mc_step_read "$MC_STEP_FILE" | cut -f2
  mc_step "$(printf 'a\tb')"; mc_step_read "$MC_STEP_FILE" | cut -f2
  mc_step 'arm:READY'; mc_step_read "$MC_STEP_FILE" | cut -f2
  unset MC_STEP_FILE; out=$(MC_STEP_LOG=1 mc_step x); echo "rc=$? out=[$out]"
) > "$UL/u4.out" 2>&1
[ "$(sed -n 1,3p "$UL/u4.out" | tr '\n' ' ')" = 'unknown unknown arm:READY ' ] && ok || bad "U4 a space or a tab is written as unknown, arm:READY kept ($(cat "$UL/u4.out"))"
grep -qx 'rc=0 out=\[\]' "$UL/u4.out" && [ ! -s "$UL/u4.log" ] && ok || bad "U4 no MC_STEP_FILE: rc 0, no output, no log line ($(cat "$UL/u4.out"))"

# ============================================================================
# S — sentry_report's extra.tags, and the 2-field mark.
# ============================================================================
mkdir -p "$UL/sh/logs" "$UL/sh/state"
cat > "$UL/scurl" <<EOF
#!/bin/bash
cat > /dev/null
f=""; while [ \$# -gt 0 ]; do case "\$1" in --data-binary) f="\${2#@}"; shift 2 ;; *) shift ;; esac; done
[ -n "\$f" ] && tail -1 "\$f" > "$UL/slast.json"
printf 200
EOF
chmod +x "$UL/scurl"
sr() { rm -f "$UL/slast.json"; scratch_rm "$UL/sh/state/sentry-report"
  ( unset -f gh; . "$DIR/bin/lib/sentry-report.sh"
    HARNESS="$UL/sh" HARNESS_SENTRY_DSN=https://k-fixture@sentry.test/1 SENTRY_MAX_PER_FP_HOUR=50 \
    HARNESS_SENTRY_CURL="$UL/scurl" HARNESS_CHECKOUT="$UL/none" JOBS_BOX=box-t LANE_GATE_CACHE_S=0 \
      sentry_report warning lane-real reason-x m "$@" )
  cat "$UL/slast.json" 2>/dev/null; }
STD='["box","harness_sha","lane","project","reason"]'
EV=$(sr '{"project":"p","tags":{"step":"x"}}')
[ "$(jq -r '.tags.step' <<<"$EV")" = x ] && [ "$(jq -c '.extra | has("tags")' <<<"$EV")" = false ] && [ "$(jq -r '.extra.project' <<<"$EV")" = p ] \
  && ok || bad "S1 extra.tags.step becomes tags.step and leaves extra ($EV)"
LONG=$(printf 'v%.0s' $(seq 250))
EV=$(sr "$(jq -nc --arg l "$LONG" '{project:"p",tags:{lane:"evil",n:5,Up:"x",long:$l,a1:"1",a2:"2",a3:"3",a4:"4",a5:"5",a6:"6",a9:"9"}}')")
TG=$(jq -c '.tags' <<<"$EV")
[ "$(jq -r '.lane' <<<"$TG")" = lane-real ] && ok || bad "S2 a core key cannot win ($TG)"
[ "$(jq -c 'has("n"), has("Up")' <<<"$TG" | tr '\n' ' ')" = 'false false ' ] && ok || bad "S2 a non-string value and an uppercase key are dropped ($TG)"
[ "$(jq -r '.long | length' <<<"$TG")" = 200 ] && ok || bad "S2 a value is cut to 200 chars ($TG)"
# lane, long and a1..a6 are the 8 valid entries in order; a9 is the 9th.
[ "$(jq -c '[keys[] | select(test("^(a[0-9]|long)$"))] | length' <<<"$TG")" = 7 ] && [ "$(jq -c 'has("a9")' <<<"$TG")" = false ] \
  && ok || bad "S2 at most 8 extra entries pass, the 9th (a9) is dropped ($TG)"
EV=$(sr '{"project":"p"}')
[ "$(jq -c '.tags | keys' <<<"$EV")" = "$STD" ] && ok || bad "S3 no .tags: the five core tags only ($EV)"
EV=$(sr '{"project":"p","tags":{"step":"from-extra"}}' '{"step":"from-arg"}')
[ "$(jq -r '.tags.step' <<<"$EV")" = from-arg ] && ok || bad "S3 the 6th argument wins over extra.tags ($EV)"
# S4 — a mark from an older writer: <s>\t<stage> only.
mkdir -p "$UL/s4/worker-deadline"
printf '900\tagent-review\n' > "$UL/s4/worker-deadline/example-org_demo_5.tick-1"
S4ROW=$(printf '5\turl\t%s\tbr\tfalse\tCLEAN\t-' "$(hd 5)")
OUT=$( MC_STATE_DIR="$UL/s4" MC_TICK_ID=tick-1 SLUG=$SLUG P=proj-mc HARNESS="$UL/sh" HARNESS_SENTRY_DSN=https://k-fixture@sentry.test/1 SENTRY_MAX_PER_FP_HOUR=50 \
  HARNESS_SENTRY_CURL="$UL/scurl" HARNESS_CHECKOUT="$UL/none" JOBS_BOX=box-t LANE_GATE_CACHE_S=0 bash -c '
  . "$1"; . "$2"
  mc_attempt_has() { return 1; }; mc_attempt_put() { return 0; }; mc_log() { :; }
  mc_handoff_id() { printf "%s" "$1" | tr "/#" "__"; }
  mc_fanin_outcome 143 "$3"' _ "$DIR/bin/lib/fanin.sh" "$DIR/bin/lib/sentry-report.sh" "$S4ROW" 2>&1)
EV=$(cat "$UL/slast.json" 2>/dev/null)
[ "$OUT" = killed:deadline ] && ok || bad "S4 a 2-field mark is killed:deadline ($OUT)"
[ "$(jq -r '.tags.step' <<<"$EV" 2>/dev/null)" = unknown ] && ok || bad "S4 a 2-field mark has tags.step == unknown ($EV)"

# The T/R/W/K cases run the conductor through the bridge.
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
list > "$T/list.json"

# ============================================================================
# T1 + T3 — #191 READY, its dep-gate step stalls 60 s; the step timeout is 4 s
# and the worker deadline 30 s. #192 is a WAIT_CI row whose CI is still running.
# ============================================================================
fresh; { row READY 191; row WAIT_CI 192; } > "$ROWS"; echo 60 > "$T/stall-191"; touch "$T/cipend-192"
M0=$(loglen); S0=$SECONDS
bs MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=4
T1_S=$((SECONDS - S0))
[ "$T1_S" -lt 30 ] && ok || bad "T1 the tick ends in under 30 s (took ${T1_S}s; bs: $(tail -3 "$T/bs.out"))"
STL=$(since "$M0" | grep -F "$SLUG#191 STEP_TIMEOUT step=dep-gate after ")
[ "$(grep -c . <<<"$STL")" = 1 ] && ok || bad "T1 one STEP_TIMEOUT step=dep-gate line for #191 (log: $(since "$M0" | grep -F '#191' | tail -5))"
grep -Eq "after [4-9]s on 6d12eb15 \(step timeout 4s, worker deadline 30s\): worker stopped; row left READY, the next tick works it again \| calls: .+$" <<<"$STL" \
  && ok || bad "T1 the line names the timeout, the deadline and the row state ($STL)"
! grep -q "$SLUG#191 WORKER_DEADLINE" <<<"$(since "$M0")" && ok || bad "T1 no WORKER_DEADLINE for #191"
grep -Eq 'killed:step-timeout( rc=[0-9]+)? 1(,|\))' <<<"$(tally "$M0")" && ok || bad "T1 the tally counts one killed:step-timeout ($(tally "$M0"))"
[ "$(grep -F "$SLUG#191"$'\t' "$ROWS" | cut -f2)" = READY ] && grep -q 'row left READY' <<<"$STL" && ok || bad "T1 the row is READY in pr-state.tsv, as the line says ($(grep -F "$SLUG#191" "$ROWS"))"
AL=$(grep -F "STEP_TIMEOUT $SLUG#191" "$T/c-alerts.txt")
[ "$(grep -c . <<<"$AL")" = 1 ] && grep -q 'step=dep-gate' <<<"$AL" && ok || bad "T1 one lane alert naming step dep-gate (alerts: $(cat "$T/c-alerts.txt"))"
EV=$(events conductor-step-timeout | head -1)
[ "$(jq -r '.tags.step // empty' <<<"$EV")" = dep-gate ] && [ "$(jq -r '.message.formatted' <<<"$EV")" = "STEP_TIMEOUT: step dep-gate passed 4s on 6d12eb15" ] \
  && [ "$(jq -r '.extra.step_timeout_s' <<<"$EV")" = 4 ] && ok || bad "T1 one Sentry event, tagged step=dep-gate ($EV)"
[ -z "$(leftover)" ] && ok || bad "W6 nothing left under worker-deadline/ after T1 ($(leftover))"
# T3 — the STEP lines of T1's tick.
L191=$(since "$M0" | grep -F "$SLUG#191 STEP_")
for s in ready-checks land-rebase arm:READY base-guard dep-gate; do
  grep -qE "$SLUG#191 STEP_START step=$s$" <<<"$L191" && ok || bad "T3 STEP_START step=$s ($L191)"
done
for s in ready-checks land-rebase arm:READY base-guard; do
  grep -qE "$SLUG#191 STEP_END step=$s took=[0-9]+s$" <<<"$L191" && ok || bad "T3 STEP_END step=$s ($L191)"
done
grep -qE "$SLUG#191 STEP_END step=dep-gate took=[0-9]+s result=step-timeout$" <<<"$L191" && ok || bad "T3 dep-gate ends result=step-timeout ($L191)"
since "$M0" | grep -F "$SLUG#191 STEP_" | tail -2 | head -1 | grep -q 'step=dep-gate .*result=step-timeout' \
  && since "$M0" | grep -F "$SLUG#191 STEP_" | tail -1 | grep -q 'STEP_TIMEOUT step=dep-gate' && ok || bad "T3 the dep-gate STEP_END comes just before the STEP_TIMEOUT line"
! grep -qE "$SLUG#191 STEP_START step=(classify|ci-read|verdict-read)" <<<"$(since "$M0")" && ok || bad "T3 no STEP_START before the READY transition"
[ "$(since "$M0" | grep -c "$SLUG#192 STEP_")" = 0 ] && ok || bad "T3 the WAIT_CI row #192 has no STEP lines ($(since "$M0" | grep -F '#192' | tail -3))"
[ "$(grep -F "$SLUG#192"$'\t' "$ROWS" | cut -f2)" = WAIT_CI ] && ok || bad "T3 setup: #192 stays WAIT_CI ($(grep -F "$SLUG#192" "$ROWS"))"

# ============================================================================
# W3 — the same head stalls in the same step again: the tally says so, nothing
# is sent twice.
# ============================================================================
reset_calls; M0=$(loglen); NS=$(events conductor-step-timeout | grep -c .)
bs MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=4
grep -Eq 'killed:step-timeout( rc=[0-9]+)? 1(,|\))' <<<"$(tally "$M0")" && ok || bad "W3 the tally counts killed:step-timeout again ($(tally "$M0"))"
! grep -q "STEP_TIMEOUT $SLUG#191" "$T/c-alerts.txt" && ok || bad "W3 no second lane alert ($(cat "$T/c-alerts.txt"))"
[ "$(events conductor-step-timeout | grep -c .)" = "$NS" ] && ok || bad "W3 no second Sentry event"

# ============================================================================
# R1 — project-6#191's replay: the stall is gone; the next tick enqueues #191.
# ============================================================================
rm -f "$T/stall-191"; reset_calls; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=4 MC_MERGE_BUDGET=5
{ [ "$(grep -F "$SLUG#191"$'\t' "$ROWS" | cut -f2)" = QUEUED ] && grep -qE 'issues/191/(labels|comments)' "$T/c-enq.txt"; } && ok \
  || bad "R1 #191 is enqueued and QUEUED (row: $(grep -F "$SLUG#191" "$ROWS"); log: $(since "$M0" | grep -F '#191' | tail -4))"
! grep -q "$SLUG#191: an earlier conductor worker still holds this PR's lock" <<<"$(since "$M0")" && ok || bad "R1 the PR lock was not held over"
since "$M0" | grep -qE "$SLUG#191 STEP_END step=enqueue took=[0-9]+s result=rc:0$" && ok || bad "R1 the last step (enqueue) ends result=rc:0 ($(since "$M0" | grep -F "$SLUG#191 STEP_" | tail -3))"
[ -z "$(leftover)" ] && ok || bad "W6 nothing left under worker-deadline/ after R1 ($(leftover))"

# ============================================================================
# T2 + W2 — MC_STEP_TIMEOUT_S=0: the deadline (6 s) fires. The Sentry title
# names the step and holds no log line; extra.stage is kept.
# ============================================================================
fresh; row READY 191 > "$ROWS"; echo 60 > "$T/stall-191"; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=6 MC_STEP_TIMEOUT_S=0
WL=$(since "$M0" | grep -F "$SLUG#191 WORKER_DEADLINE: worker killed after 6s on 6d12eb15 at stage: ")
[ "$(grep -c . <<<"$WL")" = 1 ] && grep -q '| step: dep-gate (' <<<"$WL" && ok || bad "W2 st=0: the deadline fires and names dep-gate ($WL)"
grep -Eq 'killed:deadline( rc=[0-9]+)? 1(,|\))' <<<"$(tally "$M0")" && ok || bad "W2 the tally counts killed:deadline ($(tally "$M0"))"
EV=$(events conductor-worker-deadline | head -1)
[ "$(jq -r '.tags.step // empty' <<<"$EV")" = dep-gate ] && ok || bad "T2 tags.step == dep-gate ($EV)"
MSG=$(jq -r '.message.formatted // empty' <<<"$EV")
[[ "$MSG" =~ ^WORKER_DEADLINE:\ worker\ killed\ after\ 6s\ on\ 6d12eb15\ in\ step\ dep-gate$ ]] && ok || bad "T2 the title is '$MSG'"
[[ "$MSG" != *" -> READY"* ]] && ok || bad "T2 the title holds no copied log line ($MSG)"
jq -e '(.extra.stage | type == "string" and length > 0) and .fingerprint == ["merge-conductor","demo","conductor-worker-deadline"]' <<<"$EV" >/dev/null 2>&1 \
  && ok || bad "T2 extra.stage is kept and the fingerprint is unchanged ($EV)"
since "$M0" | grep -qE "$SLUG#191 STEP_END step=dep-gate took=[0-9]+s result=deadline$" && ok || bad "T2 dep-gate ends result=deadline"
[ -z "$(leftover)" ] && ok || bad "W6 nothing left under worker-deadline/ after T2 ($(leftover))"

# ============================================================================
# W4 — the step timeout is not below the deadline: the deadline fires.
# ============================================================================
fresh; row READY 191 > "$ROWS"; echo 60 > "$T/stall-191"; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=8 MC_STEP_TIMEOUT_S=10
since "$M0" | grep -F "$SLUG#191 WORKER_DEADLINE: worker killed after 8s" | grep -q '| step: dep-gate (' && ok || bad "W4 st >= d: the deadline names dep-gate ($(since "$M0" | grep -F '#191' | tail -3))"
! grep -q "STEP_TIMEOUT" <<<"$(since "$M0")" && ok || bad "W4 no STEP_TIMEOUT"

# ============================================================================
# T4 — a slow step logs one STEP_SLOW line while it runs.
# ============================================================================
fresh; row READY 191 > "$ROWS"; echo 4 > "$T/stall-191"; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=0 MC_STEP_SLOW_S=2
[ "$(since "$M0" | grep -cE "$SLUG#191 STEP_SLOW step=dep-gate running=[0-9]+s$")" = 1 ] && ok || bad "T4 one STEP_SLOW step=dep-gate ($(since "$M0" | grep -F "$SLUG#191 STEP_"))"
! grep -q 'killed:' <<<"$(tally "$M0")" && ok || bad "T4 the slow step is not killed ($(tally "$M0"))"

# ============================================================================
# W5 — the enqueue step waits 8 s on purpose; the floor (max of the two queue
# waits + 10 = 16 s) keeps a 4 s step timeout from killing it.
# ============================================================================
fresh; row READY 191 > "$ROWS"; echo 8 > "$T/enqstall-191"; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=40 MC_STEP_TIMEOUT_S=4 MC_MERGE_BUDGET=5 MC_MERGIFY_WAIT_S=6 MC_MERGE_LOCK_WAIT=6
! grep -q STEP_TIMEOUT <<<"$(since "$M0")" && ! grep -q 'killed:' <<<"$(tally "$M0")" && ok || bad "W5 the enqueue step is not killed ($(tally "$M0"); $(since "$M0" | grep STEP_TIMEOUT))"
[ "$(grep -F "$SLUG#191"$'\t' "$ROWS" | cut -f2)" = QUEUED ] && ok || bad "W5 #191 is enqueued ($(grep -F "$SLUG#191" "$ROWS"))"
fresh; row READY 191 > "$ROWS"; echo 60 > "$T/enqstall-191"; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=40 MC_STEP_TIMEOUT_S=4 MC_MERGE_BUDGET=5 MC_MERGIFY_WAIT_S=6 MC_MERGE_LOCK_WAIT=6
since "$M0" | grep -Eq "$SLUG#191 STEP_TIMEOUT step=enqueue after (1[6-9]|2[0-9])s .*\(step timeout 16s, worker deadline 40s\)" && ok \
  || bad "W5 an enqueue stall past the 16 s floor is killed at the floor ($(since "$M0" | grep -F "$SLUG#191 STEP_TIMEOUT"))"

# ============================================================================
# L1 — BH-6000's READY re-kick waits for its PR lock on purpose: its launcher
# holds the lock, and the keyed run waits MC_PR_LOCK_WAIT_S (the launcher's
# deadline) in the lock-probe step. Scaled from project-6: deadline 600 -> 6 s,
# step timeout 240 -> 2 s, the launcher holds the lock 4 s (past the step
# timeout). The real mc_worker_bounded and mc_pr_lock_take run.
# ============================================================================
l1() { # l1 <name> <lock wait or -> <hold s> — prints rc= and word=
  local n="$1" lw="$2" hold="$3"; mkdir -p "$UL/$n/state"
  ( SLUG=$SLUG MC_STATE_DIR="$UL/$n/state" MC_TICK_ID="$n" KEY="$SLUG#71" MC_H="$UL/$n/h"
    . "$DIR/bin/lib/fanin.sh"; . "$DIR/bin/lib/mc/locks.sh"
    MC_WORKER_DEADLINE_S=6 MC_STEP_TIMEOUT_S=2 MC_STEP_POLL_S=1 MC_STEP_SLOW_S=0
    unset MC_PR_LOCK_WAIT_S MC_WORKER_DEADLINE_CAP_S; [ "$lw" = - ] || MC_PR_LOCK_WAIT_S=$lw
    mc_handoff_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    mc_log() { printf '%s\n' "$*" >> "$UL/$n.log"; }
    mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; sentry_report() { :; }; _mc_fanin_alert() { :; }
    L="$UL/$n/pr.lock"; : > "$L"
    flock "$L" sleep "$hold" &   # determinism: ok the launcher's held lock IS the wait under test
    hp=$!; i=0; while flock -n "$L" true 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done   # determinism: ok waits for the holder to take the lock
    if [ "$lw" = - ]; then
      pr_worker() { mc_step lock-probe; sleep "$hold"; mc_step state-guard; return 0; }   # determinism: ok the stall the step timeout must kill
    else
      pr_worker() { mc_step lock-probe; exec 9>"$L"; mc_pr_lock_take || return 7; mc_step state-guard; return 0; }
    fi
    mc_worker_bounded "71"$'\t'"x"$'\t'"$(hd 71)"; echo "rc=$?"
    echo "word=$(mc_fanin_outcome 0 "71"$'\t'"x"$'\t'"$(hd 71)"$'\t'"b"$'\t'"false"$'\t'"CLEAN")"
    wait "$hp" 2>/dev/null ) > "$UL/$n.out" 2>&1
}
l1 l1a 6 4
grep -qx 'rc=0' "$UL/l1a.out" && ! grep -q 'word=killed' "$UL/l1a.out" && ! grep -q STEP_TIMEOUT "$UL/l1a.log" 2>/dev/null && ok \
  || bad "L1 a 4 s PR lock wait (MC_PR_LOCK_WAIT_S=6) past the 2 s step timeout is not killed ($(tr '\n' ' ' < "$UL/l1a.out"); $(grep STEP_TIMEOUT "$UL/l1a.log" 2>/dev/null))"
l1 l1b - 4
grep -qx 'word=killed:step-timeout' "$UL/l1b.out" && grep -q "STEP_TIMEOUT step=lock-probe" "$UL/l1b.log" 2>/dev/null && ok \
  || bad "L1b no lock wait: a lock-probe stalled 4 s is killed at the 2 s step timeout ($(tr '\n' ' ' < "$UL/l1b.out"); $(grep STEP_TIMEOUT "$UL/l1b.log" 2>/dev/null))"

# ============================================================================
# K1 — the knob: garbage reads as 240; the catalog carries the three knobs.
# ============================================================================
fresh; row READY 191 > "$ROWS"; echo 8 > "$T/stall-191"; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=abc
! grep -q 'killed:' <<<"$(tally "$M0")" && ! grep -q STEP_TIMEOUT <<<"$(since "$M0")" && ok || bad "K1 MC_STEP_TIMEOUT_S=abc reads as 240: the 8 s stall is not killed ($(tally "$M0"))"
KD="$DIR/catalog/lanes.d/merge-conductor.knobs.d"
K1CAT=$(jq -sc 'map([.env, .default, .min, .max])' "$KD/MC_STEP_TIMEOUT_S.json" "$KD/MC_STEP_SLOW_S.json" "$KD/MC_STEP_POLL_S.json" 2>&1)
[ "$K1CAT" = '[["MC_STEP_TIMEOUT_S",240,0,1500],["MC_STEP_SLOW_S",60,0,1500],["MC_STEP_POLL_S",5,1,60]]' ] \
  && ok || bad "K1 the catalog knob files carry the code's fallback defaults ($K1CAT)"

# ============================================================================
# G1 — no GitHub write verb beyond the enqueues (R1, W5).
# ============================================================================
[ ! -s "$T/c-writes.txt" ] && ok || bad "G1 a GitHub write outside the enqueue ($(head -3 "$T/c-writes.txt"))"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "mc-step-timeout.bh-6351: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
