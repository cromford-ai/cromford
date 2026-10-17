#!/bin/bash
# tests/mc-ci-read-bound.bh-6346-test.sh — BH-6346 (r2): the merge conductor's
# ci-read GitHub read (actions/runs) has a time bound, and a timed-out read is
# a named CI_READ_HELD line (no STEP_TIMEOUT, no alert, no Sentry).
#
# Sentry CROMFORD-HARNESS-K, project-3, step ci-read: mc_ci_state ran `gh api`
# with no time bound, so a stalled actions/runs read held the step until the
# worker deadline killed the worker. BH-6810 fixed the same class for head-lag.
#
#   C1  mc_ci_state, MC_CI_READ_TIMEOUT_S=2, actions/runs stalls: `unavailable`
#       in under 10 s, MC_CI_READ_WHY = "HTTP 000 timeout"
#   C2  mc_ci_read_timeout_s: abc -> 30, 0 -> 0, 007 -> 7, unset -> 30
#   C3  a fast 500: `unavailable`, MC_CI_READ_WHY "HTTP 500 ...", not timeout
#   C4  knob 0, a 3 s answer with one success run: `green` after >= 3 s,
#       MC_CI_READ_WHY empty
#   C4b mc_ci_flake_runs, knob 2, stalled read: prints nothing, rc 0, < 10 s
#   C5  the real bin/merge-conductor.sh tick, actions/runs stalls, knob 2: tick
#       under 60 s, one CI_READ_HELD line, 0 STEP_TIMEOUT / STEP_HELD /
#       WORKER_DEADLINE, 0 alerts, 0 Sentry events, no ci memo, no
#       ci-state.* file left, one cireadheld attempts line
#   C5  ... and the row is `WAIT_CI|checks unread ...`, never READY
#   C5d a fast 500 tick: no CI_READ_HELD; the row keeps the old `unavailable`
#       path (READY on a clean approved PR) — only a cut read is held
#   C5e merge budget 5: a cut read is WAIT_CI, never reaches the READY arm or
#       the prequeue (enqueue) step, writes nothing; a fast 500 does reach
#       prequeue (the control)
#   C5b actions/runs answers 429: no CI_READ_HELD line
#   C5c actions/runs answers 401: AUTH_401 during step ci-read, no CI_READ_HELD
#   C6  a second tick on the same head: no second CI_READ_HELD line
#   C7  knob 0, a small worker deadline, stalled read: WORKER_DEADLINE names
#       step ci-read; the Sentry event tags carry step and worker_key
#   K1  the knob fragment default equals mc_ci_read_timeout_s with env unset
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-ci-read-bound.bh-6346-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v timeout >/dev/null || { echo "timeout missing — skipping"; exit 0; }
# No GitHub credential or install id from the box reaches a stub (D60).
unset GH_TOKEN GITHUB_TOKEN GH_TOKEN_INSTALLATION_ID
NOW=$(date +%s)
hd() { printf '%02d%038d' "$1" 0; }

SLUG=example-org/demo
U="https://github.com/$SLUG/pull"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
F="$T/f"
mkdir -p "$F/h/logs" "$F/h/state/merge-conductor" "$F/h/flags" "$F/h/locks" "$F/h/builds" "$F/h/env" "$F/h/tmp" "$F/fakebin"
for s in bin/merge-conductor.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$F/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
scratch_rm "$F/h/bin/lib/gh-limit-logger.sh"
mkdir -p "$F/h/catalog" && cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$F/h/catalog/" || exit 1
printf 'demo %s - - 2 box-m\n' "$SLUG" > "$F/h/fleet.conf"
: > "$F/h/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/$s.sh"; chmod +x "$F/h/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$F" > "$F/h/bin/lane-alert.sh"; chmod +x "$F/h/bin/lane-alert.sh"
REC="$F/h/builds/pool-demo-BH-1-202610140001"; mkdir -p "$REC"
echo "PR_CREATED $U/1" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
hd 1 > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
cp "$DIR/tests/lib/rest-emit.sh" "$F/fakebin/restpr"; chmod +x "$F/fakebin/restpr"
jq -nc --arg s "$SLUG" --arg h "$(hd 1)" '[{number:1, html_url:("https://github.com/"+$s+"/pull/1"),
  title:"t", body:"", draft:false, state:"open", merged_at:null, labels:[], user:{login:"operator",type:"User"},
  updated_at:"2026-10-14T00:00:00Z", head:{ref:"ticket/bh-1", sha:$h, repo:{full_name:$s}},
  base:{ref:"main", repo:{full_name:$s}}, mergeable_state:"clean", mergeable:true}]' > "$F/open.json"
# The gh stub. $F/runs says how actions/runs answers: `stall` (exec sleep 300),
# `slow` (3 s, then one success run), `500`, `429`, `401`, else one success run.
cat > "$F/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$F/c-calls.txt"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"git/matching-refs/heads/"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/branches/ticket/bh-"*) restpr --raw 200 '{"name":"ticket/bh-1","commit":{"sha":"'"\$(printf '%02d%038d' 1 0)"'"}}' ;;
  *"actions/runs?head_sha="*)
    case "\$(cat "$F/runs" 2>/dev/null)" in
      stall) exec sleep 300 ;;   # determinism: ok the stub IS the stalled read under test
      slow) sleep 3 ;;   # determinism: ok a slow read the bound must not cut when off
      500) restpr --raw 500 '{"message":"boom"}'; exit 0 ;;
      429) restpr --raw 429 '{"message":"API rate limit exceeded"}'; exit 0 ;;
      401) printf 'HTTP/2.0 401 Unauthorized\r\n\r\n{"message":"Bad credentials"}\n'; echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1 ;;
    esac
    restpr --runs 'completed|success' ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=open"*) restpr --raw 200 "\$(cat "$F/open.json")" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*|*"pr merge"*) printf '%s\n' "\$A" >> "$F/c-writes.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"api repos/$SLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$N" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) restpr OPEN "\$(printf '%02d%038d' "\$N" 0)" "ticket/bh-\$N" main "" MERGEABLE CLEAN operator "" "" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
esac
exit 0
EOF
chmod +x "$F/fakebin/gh"
cat > "$F/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$URL" in *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$M" "$URL"; exit 0 ;; esac
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$F/fakebin/curl"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$F/lpp.json" "$SLUG"
lpp_install "$F/fakebin" "$F/lpp.json" "$F/lpp-down"
cat > "$F/fakebin/sentry-curl" <<EOF
#!/bin/bash
cat > /dev/null
f=""; while [ \$# -gt 0 ]; do case "\$1" in --data-binary) f="\${2#@}"; shift 2 ;; *) shift ;; esac; done
k=\$(ls "$F"/sentry-env-*.txt 2>/dev/null | wc -l)
[ -n "\$f" ] && cp "\$f" "$F/sentry-env-\$k.txt"
printf 200
EOF
chmod +x "$F/fakebin/sentry-curl"
touch "$F/h/flags/merge-conductor-actions" "$F/h/flags/merge-conductor-merge" "$F/h/flags/conductor-owns-merges"
CLOG="$F/h/logs/merge-conductor.log"
ROWS="$F/h/state/merge-conductor/pr-state.tsv"
# fresh <mode> — a clean state dir with one WAIT_CI row for #1; actions/runs answers <mode>.
fresh() { scratch_rm "$F/h/state"; mkdir -p "$F/h/state/merge-conductor"
  printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$SLUG#1" WAIT_CI $((NOW-600)) "$(hd 1)" "$(hd 1)" "$U" 1 > "$ROWS"
  echo "$1" > "$F/runs"
  rm -f "$F"/sentry-env-*.txt; : > "$F/c-calls.txt"; : > "$F/c-alerts.txt"; touch "$F/c-writes.txt"; }
ENVC=(PATH="$F/fakebin:$PATH" HARNESS="$F/h" FLEET_CONF="$F/h/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test
  GH_TOKEN=pat-fixture-default HARNESS_PR_AUTHORS=operator
  HARNESS_SENTRY_DSN=https://k-fixture@sentry.test/1 SENTRY_MAX_PER_FP_HOUR=50 HARNESS_SENTRY_CURL="$F/fakebin/sentry-curl"
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 MC_HEAD_LAG_MINS=10 MC_STEP_POLL_S=1
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0)
# tick [env...] — one real conductor tick.
tick() { ( unset -f gh; cd "$F" && env -u MC_STEP_HOLD_MAX -u MC_CI_READ_TIMEOUT_S -u MC_STEP_TIMEOUT_S -u MC_STEP_SLOW_S "${ENVC[@]}" \
  "$@" bash "$F/h/bin/merge-conductor.sh" > "$F/mc.out" 2>&1 ); }
since() { tail -n +"$(( ${1:-0} + 1 ))" "$CLOG" 2>/dev/null; }
loglen() { if [ -f "$CLOG" ]; then wc -l < "$CLOG"; else echo 0; fi; }
tally() { since "$1" | grep -F "FANIN merge-conductor $SLUG:" | tail -1; }
allevents() { local f; for f in "$F"/sentry-env-*.txt; do [ -f "$f" ] && tail -1 "$f"; done; }
events() { allevents | jq -c "select(.tags.reason == \"$1\")" 2>/dev/null; }

# C1-C4b — mc_ci_state / mc_ci_flake_runs through the real conductor lib.
cat > "$F/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" || exit 99
mc_init
s=$SECONDS; rc=0
case "${DRV_FN:-state}" in
  state) mc_ci_state example-org/demo "$(printf '%02d%038d' 1 0)" > "$TMPDIR/ci"; out=$(cat "$TMPDIR/ci"); why="${MC_CI_READ_WHY-unset}" ;;
  flake) out=$(mc_ci_flake_runs example-org/demo "$(printf '%02d%038d' 1 0)") || rc=$?; why=- ;;
  knob)  out=$(mc_ci_read_timeout_s); why=- ;;
esac
echo "rc=$rc out=$out why=$why took=$((SECONDS - s))"
EOF
DRVN=0
drv() { DRVN=$((DRVN + 1)); ( unset -f gh; cd "$F" && timeout -k 5 40 env -u MC_CI_READ_TIMEOUT_S "${ENVC[@]}" TMPDIR="$F/h/tmp" GH_ETAG=0 MC_TICK_ID="drv$DRVN" "$@" bash "$F/drv.sh" 2>&1 | tail -1 ); }
took() { sed -E 's/.*took=([0-9]+).*/\1/' <<<"$1"; }

# C1 — knob 2, stalled read.
fresh stall
R=$(drv MC_CI_READ_TIMEOUT_S=2)
TK=$(took "$R")
grep -q '^rc=0 out=unavailable why=HTTP 000 timeout took=' <<<"$R" && [ "$TK" -lt 10 ] && ok || bad "C1 knob 2, a stalled actions/runs read: unavailable, HTTP 000 timeout, bounded ($R)"
# C2 — the knob reader.
for kv in abc:30 0:0 007:7 '':30; do
  IFS=: read -r k v <<<"$kv"
  if [ -n "$k" ]; then R=$(drv DRV_FN=knob MC_CI_READ_TIMEOUT_S="$k"); else R=$(drv DRV_FN=knob); fi
  grep -q "^rc=0 out=$v why=- " <<<"$R" && ok || bad "C2 MC_CI_READ_TIMEOUT_S='$k' reads as $v ($R)"
done
# C3 — a fast 500.
fresh 500
R=$(drv MC_CI_READ_TIMEOUT_S=2)
grep -q '^rc=0 out=unavailable why=HTTP 500' <<<"$R" && ! grep -q 'why=HTTP [0-9]* timeout ' <<<"$R" && ok || bad "C3 a fast 500: unavailable, HTTP 500, not timeout ($R)"
# C4 — knob 0: no bound, a 3 s answer is read.
fresh slow
R=$(drv MC_CI_READ_TIMEOUT_S=0 GH_REST_TIMEOUT_S=1)
TK=$(took "$R")
grep -q '^rc=0 out=green why= took=' <<<"$R" && [ "$TK" -ge 3 ] && ok || bad "C4 knob 0: green after >= 3 s, why empty ($R)"
# C4b — the flake read is bounded too.
fresh stall
R=$(drv DRV_FN=flake MC_CI_READ_TIMEOUT_S=2)
TK=$(took "$R")
grep -q '^rc=0 out= why=- took=' <<<"$R" && [ "$TK" -lt 10 ] && ok || bad "C4b mc_ci_flake_runs, knob 2, stalled: nothing, rc 0, < 10 s ($R)"

# C5 — the real tick; actions/runs stalls, knob 2.
fresh stall
M0=$(loglen); S0=$SECONDS
tick MC_WORKER_DEADLINE_S=60 MC_CI_READ_TIMEOUT_S=2
C5_S=$((SECONDS - S0)); C5=$(since "$M0")
[ "$C5_S" -lt 60 ] && ok || bad "C5 the tick ends in under 60 s (took ${C5_S}s)"
grep -q "actions/runs?head_sha=$(hd 1)" "$F/c-calls.txt" && ok || bad "C5 setup: the ci-read actions/runs read is sent ($(tail -5 "$F/c-calls.txt"))"
HL=$(grep -F "$SLUG#1 CI_READ_HELD" <<<"$C5")
[ -n "$HL" ] && [ "$(grep -c . <<<"$HL")" = 1 ] && ok || bad "C5 one CI_READ_HELD line ($(grep -F "$SLUG#1" <<<"$C5" | tail -8))"
[ "${HL#* * }" = "$SLUG#1 CI_READ_HELD reason=read-timeout on $(hd 1 | cut -c1-8) (bound 2s): the actions/runs read passed its bound; the row stays WAIT_CI this tick, no alert, the next tick reads again" ] \
  && ok || bad "C5 the CI_READ_HELD line format ($HL)"
! grep -qE 'STEP_TIMEOUT|STEP_HELD|WORKER_DEADLINE' <<<"$C5" && ok || bad "C5 no STEP_TIMEOUT, STEP_HELD or WORKER_DEADLINE ($(grep -E 'STEP_TIMEOUT|STEP_HELD|WORKER_DEADLINE' <<<"$C5"))"
[ ! -s "$F/c-alerts.txt" ] && ok || bad "C5 no lane alert ($(cat "$F/c-alerts.txt"))"
[ -z "$(allevents)" ] && ok || bad "C5 no Sentry event ($(allevents))"
C5_ROW=$(awk -F'\t' -v k="$SLUG#1" '$1 == k {print $2 "|" $7}' "$ROWS")
case "$C5_ROW" in "WAIT_CI|checks unread — the actions/runs read passed its bound this tick; the next tick reads again") ok ;; *) bad "C5 a cut read leaves the row WAIT_CI checks unread, never READY ($C5_ROW)" ;; esac
T1=$(tally "$M0")
grep -q 'enumerated 1 accounted 1' <<<"$T1" && ! grep -q 'killed:' <<<"$T1" && ok || bad "C5 the PR is worked to an outcome, not killed ($T1)"
[ -z "$(ls "$F/h/state/merge-conductor/read-memo" 2>/dev/null | grep '\.ci$')" ] && ok || bad "C5 no ci memo file ($(ls "$F/h/state/merge-conductor/read-memo" 2>/dev/null))"
[ -z "$(find "$F/h/state" -name 'ci-state.*' 2>/dev/null)" ] && ok || bad "C5 no ci-state.* file left ($(find "$F/h/state" -name 'ci-state.*'))"
[ "$(grep -c "^cireadheld $SLUG#1 $(hd 1)" "$F/h/state/merge-conductor/attempts.txt" 2>/dev/null)" = 1 ] \
  && ok || bad "C5 one cireadheld attempts line"
# C6 — a second tick on the same head: the line is not said again.
M1=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_CI_READ_TIMEOUT_S=2
[ "$(since "$M1" | grep -c 'CI_READ_HELD')" = 0 ] && ok || bad "C6 no second CI_READ_HELD on the same head ($(since "$M1" | grep CI_READ_HELD))"
grep -q 'enumerated 1 accounted 1' <<<"$(tally "$M1")" && ok || bad "C6 the PR is still worked ($(tally "$M1"))"

# C5d — a fast 500 tick: no CI_READ_HELD, and the row keeps the old path.
# TEST-CHANGE (lead review 5544115846): C5d used to pin the cut read's row equal
# to the 500 row. Both were READY, so it passed on the defect. A cut read is now
# held WAIT_CI (C5, C5e); a 500 keeps the old unavailable path.
fresh 500
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_CI_READ_TIMEOUT_S=2
! grep -q CI_READ_HELD <<<"$(since "$M0")" && ok || bad "C5d a 500: no CI_READ_HELD ($(since "$M0" | grep CI_READ_HELD))"
R500=$(awk -F'\t' -v k="$SLUG#1" '$1 == k {print $2 "|" $7}' "$ROWS")
[ "$R500" = "READY|clean, approved, checks green" ] && ok || bad "C5d a fast 500 keeps the old unavailable path ($R500)"

# C5e — a non-zero merge budget: the cut read must not reach the READY arm or
# the prequeue (enqueue) step. The fast 500 is the control: it does reach them.
fresh stall; : > "$F/c-writes.txt"; M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_CI_READ_TIMEOUT_S=2 MC_MERGE_BUDGET=5
RE=$(awk -F'\t' -v k="$SLUG#1" '$1 == k {print $2}' "$ROWS"); C=$(since "$M0")
[ "$RE" = WAIT_CI ] && ! grep -qE "$SLUG#1 STEP_START step=(arm:READY|prequeue)" <<<"$C" && [ ! -s "$F/c-writes.txt" ] \
  && ok || bad "C5e budget 5, cut read: WAIT_CI, no READY arm, no prequeue, no write ($RE / $(grep -E 'arm:READY|prequeue' <<<"$C") / $(cat "$F/c-writes.txt"))"
fresh 500; M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_CI_READ_TIMEOUT_S=2 MC_MERGE_BUDGET=5
C=$(since "$M0")
grep -qF "$SLUG#1 STEP_START step=prequeue" <<<"$C" && ! grep -q 'spent this tick.s merge budget' <<<"$C" \
  && ok || bad "C5e control: budget 5, fast 500 (READY) reaches prequeue ($(grep -E 'prequeue|merge budget' <<<"$C"))"

# C5b — a 429 is not a timeout.
fresh 429
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_CI_READ_TIMEOUT_S=2
grep -q "actions/runs?head_sha=" "$F/c-calls.txt" && ! grep -q CI_READ_HELD <<<"$(since "$M0")" && ok || bad "C5b a 429: no CI_READ_HELD ($(since "$M0" | grep CI_READ_HELD))"
# C5c — a 401 is the AUTH_401 stop, not a held read.
fresh 401
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_CI_READ_TIMEOUT_S=2
C=$(since "$M0")
grep -qF "$SLUG#1 AUTH_401: a GitHub call answered HTTP 401 during step ci-read" <<<"$C" && ! grep -q CI_READ_HELD <<<"$C" \
  && ok || bad "C5c a 401: AUTH_401 in ci-read, no CI_READ_HELD ($(grep -E 'AUTH_401|CI_READ_HELD' <<<"$C"))"

# C7 — knob 0: the old stall, now killed by the worker deadline, names its step.
fresh stall
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=8 MC_CI_READ_TIMEOUT_S=0
C=$(since "$M0")
grep -qE "$SLUG#1 WORKER_DEADLINE: worker killed after [0-9]+s on $(hd 1 | cut -c1-8) at stage: .* \| step: ci-read " <<<"$C" && ! grep -q CI_READ_HELD <<<"$C" \
  && ok || bad "C7 knob 0: WORKER_DEADLINE names step ci-read ($(grep -E 'WORKER_DEADLINE|CI_READ_HELD' <<<"$C"))"
EV=$(events conductor-worker-deadline | tail -1)
[ "$(jq -r '.tags.step + "|" + .tags.worker_key' <<<"$EV" 2>/dev/null)" = "ci-read|$SLUG#1" ] && ok || bad "C7 the Sentry event tags step=ci-read, worker_key=$SLUG#1 ($EV / $(allevents))"

# K1 — the knob fragment.
KF="$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_CI_READ_TIMEOUT_S.json"
R=$(drv DRV_FN=knob)
[ "$(jq -r '.env, .default, .min, .read_in' "$KF" 2>/dev/null | tr '\n' ' ')" = "MC_CI_READ_TIMEOUT_S 30 0 bin/lib/mc/classify.sh " ] \
  && grep -q '^rc=0 out=30 ' <<<"$R" && ok || bad "K1 the fragment default 30 = the code default ($(cat "$KF" 2>/dev/null) / $R)"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "mc-ci-read-bound.bh-6346: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
