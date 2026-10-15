#!/bin/bash
# tests/mc-state-drill.bh-4156-test.sh — BH-4156: "$DIR/bin/mc-state-drill.sh"
# runs ONE merge-conductor tick on an empty scratch state/, behind a write
# fence, and says PASS only when that fresh tick resumed every PR from the DB
# with no re-review and no duplicate merge. "$DIR/bin/lib/mc/tick-scope.sh"
# forces observe mode under MC_DRILL=1.
#
# A scratch harness plays the LIVE hub: the drill's closure, the real
# conductor, a fake jobs worker ("$DIR/tests/lib/fake-jobs-attempts.bh-4156.sh",
# a curl on PATH) and a fake gh.
#
#   D1   the real conductor: PASS, the batch read ran, the live
#        state/merge-conductor file list and mtimes unchanged
#   D1b  the real conductor with the APPROVE in no DB row: FAIL F3
#   D2   F1: a refused `gh pr merge`; a refused heartbeat POST alone is PASS
#   D3   F2: a refused PUT of an attempt the DB has; a new key alone is PASS
#   D4   F3: same head, the DB reviewed, the drill `-`; a moved head is PASS
#   D5   F4: no rehydrate line
#   D6   F5: a repo with open PRs and no batch GET
#   D7-D10  exit 2: the lock held, the flag down, the timeout, the route 404
#   M1, M2  MC_DRILL=1 forces observe; unset, the flags decide
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-state-drill.bh-4156-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/fake-jobs-attempts.bh-4156.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v timeout >/dev/null || { echo "timeout missing — skipping"; exit 0; }

# ── M1, M2: the mode under MC_DRILL ─────────────────────────────────────────
mode() { ( mc_log() { :; }; flag_on() { case " $FLAGS " in *" $1 "*) return 0 ;; esac; return 1; }
  pause_active() { return 1; }
  # shellcheck source=bin/lib/mc/tick-scope.sh
  . "$DIR/bin/lib/mc/tick-scope.sh" || exit 8
  mc_tick_mode; echo "$MODE $ACTIONS $MERGES" ); }
O=$(FLAGS="merge-conductor-actions merge-conductor-merge" MC_DRILL=1 mode)
[ "$O" = "observe 0 0" ] && ok || bad "M1 MC_DRILL=1 with the actions and merge flags up ($O)"
O=$(unset MC_DRILL; FLAGS="merge-conductor-actions merge-conductor-merge" mode)
[ "$O" = "merge 1 1" ] && ok || bad "M2 MC_DRILL unset: the flags decide ($O)"

# ── the "live" hub ──────────────────────────────────────────────────────────
SLUG=example-org/demo
hd() { printf '%02d%038d' "$1" 0; }
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
L="$T/live/h"; FB="$T/fakebin"
mkdir -p "$L/logs" "$L/state/merge-conductor" "$L/flags" "$L/locks" "$L/env" "$L/catalog" "$FB"
for s in bin/mc-state-drill.sh bin/merge-conductor.sh bin/jobs-client.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$L" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
scratch_rm "$L/bin/lib/gh-limit-logger.sh"
cp "$DIR/catalog/lead-protected-paths.tsv" "$L/catalog/" || exit 1
printf 'demo %s - - 2 box-m\n' "$SLUG" > "$L/fleet.conf"
printf 'JOBS_URL=http://worker.test\nHARNESS_SECRET=secret-fixture-4156\nJOBS_RETRIES=0\nJOBS_ALERT=0\n' > "$L/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure lane-alert; do printf '#!/bin/bash\nexit 0\n' > "$L/bin/$s.sh"; chmod +x "$L/bin/$s.sh"; done
touch "$L/flags/pr-state-rows"
# The live conductor state the drill must never touch.
printf 'rebase %s#1 %s\n' "$SLUG" "$(hd 1)" > "$L/state/merge-conductor/attempts.txt"
printf '%s#1\tREADY\t1791990000\t%s\t%s\t-\t-\thttps://github.com/%s/pull/1\n' "$SLUG" "$(hd 1)" "$(hd 1)" "$SLUG" > "$L/state/merge-conductor/pr-state.tsv"
touch -d '2026-10-01 00:00:00' "$L/state/merge-conductor/attempts.txt" "$L/state/merge-conductor/pr-state.tsv"
snap() { find "$L/state" -printf '%P %T@ %s\n' | sort; }
SNAP0=$(snap)

fja_install "$T/w" || exit 1
cp "$T/w/bin/curl" "$FB/curl"
cp "$DIR/tests/lib/rest-emit.sh" "$FB/restpr"; chmod +x "$FB/restpr"
jq -nc --arg s "$SLUG" --arg h "$(hd 1)" '[{number:1, html_url:("https://github.com/"+$s+"/pull/1"),
  title:"t", body:"", draft:false, state:"open", merged_at:null, labels:[], user:{login:"operator",type:"User"},
  updated_at:"2026-10-13T00:00:00Z", head:{ref:"ticket/bh-1", sha:$h, repo:{full_name:$s}},
  base:{ref:"main", repo:{full_name:$s}}, mergeable_state:"clean", mergeable:true}]' > "$T/open.json"
printf '[{"ref":"refs/heads/ticket/bh-1","object":{"sha":"%s","type":"commit"}}]' "$(hd 1)" > "$T/refs.json"
cat > "$FB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
HEADN=\$(printf '%02d%038d' "\${N:-0}" 0)
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"git/matching-refs/heads/"*) restpr --raw 200 "\$(cat "$T/refs.json")" ;;
  *"api -i -X GET repos/$SLUG/branches/"*) restpr --raw 200 '{"name":"x","commit":{"sha":"'"\$HEADN"'"}}' ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=open"*) restpr --raw 200 "\$(cat "$T/open.json")" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api repos/$SLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$N" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) restpr OPEN "\$HEADN" "ticket/bh-\$N" main "" MERGEABLE CLEAN operator "" "" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
esac
exit 0
EOF
chmod +x "$FB/gh"
# The DB: PR 1 READY, reviewed at its head, one rereview attempt on that head,
# and its APPROVE in the job verdict ledger.
vrow() { jq -nc --arg r "$SLUG" --arg n "$1" --arg h "$2" --arg rv "$3" '{id:($n|tonumber), repo:$r, number:($n|tonumber), state:"READY",
  since:"2026-10-14T00:00:00Z", head:$h, reviewed:$rv, alerted:"-", reason:"-", url:("https://github.com/"+$r+"/pull/"+$n)}'; }
set_view() { jq -sc '{rows:.}' > "$T/w/view.json"; }
vrow 1 "$(hd 1)" "$(hd 1)" | set_view
printf '%s\t1\trereview\t%s\n' "$SLUG" "$(hd 1)" > "$T/w/db.tsv"
# The approval is the job verdict ledger's row, not a build record: the drill
# hub has no builds/.
jq -nc --arg h "$(hd 1)" '{verdict:"APPROVE", tier:"2", provenance:"-", job_id:"job-fixture-1", reviewed_sha:$h, artifacts:[]}' > "$T/w/verdict.json"
DB0=$(cat "$T/w/db.tsv")

# drill [args…] — the drill as an operator runs it, from the live harness.
# Out: $T/out (stdout+stderr), $T/rc, $T/report (the newest report).
N=0
drill() { N=$((N + 1)); : > "$T/w/req.log"
  ( unset -f gh curl; cd "$T" && env PATH="$FB:$PATH" HARNESS="$L" HARNESS_ENV_DIR="$L/env" FLEET_CONF="$L/fleet.conf" \
    MC_DRILL_NOW="179199000$N" GH_TOKEN=pat-fixture-4156 HARNESS_PR_AUTHORS=operator PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 \
    MC_WORKER_DEADLINE_S=120 MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 \
    MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0 STUB="${STUB:-}" \
    bash "$L/bin/mc-state-drill.sh" "$@" > "$T/out" 2>&1; echo $? > "$T/rc" )
  cp "$L/logs/mc-state-drill-179199000$N.md" "$T/report" 2>/dev/null || : > "$T/report"; }
rc() { cat "$T/rc"; }
first() { head -1 "$T/out"; }

echo "== D1: the real conductor resumes from the DB: PASS =="
drill --timeout 300
[ "$(rc)" = 0 ] && [ "$(first)" = PASS ] && [ "$(head -1 "$T/report")" = PASS ] && ok || bad "D1 PASS (rc $(rc): $(cat "$T/out") / $(cat "$T/report"))"
grep -q "conductor-state batch GETs 1," "$T/report" && ok || bad "D1 one batch GET in the report ($(grep 'batch GETs' "$T/report"))"
[ "$(grep -c '^GET /api/conductor-state' "$T/w/req.log")" -ge 2 ] && ok || bad "D1 the probe and the tick's batch read reached the worker ($(grep conductor-state "$T/w/req.log"))"
[ "$(snap)" = "$SNAP0" ] && ok || bad "D1 the live state/ changed: $(diff <(echo "$SNAP0") <(snap))"
[ "$(cat "$T/w/db.tsv")" = "$DB0" ] && ok || bad "D1 the DB changed ($(cat "$T/w/db.tsv"))"
[ ! -s "$T/gh-calls" ] || ! grep -qE 'pr merge|-X (PUT|POST|PATCH|DELETE)' "$T/gh-calls" && ok || bad "D1 a write reached the fake gh ($(grep -E 'pr merge|-X (PUT|POST|PATCH|DELETE)' "$T/gh-calls"))"
grep -q "merge-conductor state drill: PASS" "$L/logs/merge-conductor.log" && ok || bad "D1 the summary line in the live log"
SC=$(sed -n 's/.*, scratch \(\/tmp\/mc-drill\.[A-Za-z0-9]*\)$/\1/p' "$T/report")
[ -n "$SC" ] && [ ! -e "$SC" ] && ok || bad "D1 the scratch tree was not removed ('$SC')"

echo "== D1b: the approval only in a build record (not in the DB): the real tick re-reviews, F3 =="
mv "$T/w/verdict.json" "$T/verdict.keep"
drill --timeout 300
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL: F3" ] && grep -q '^| F3 | example-org/demo#1 |' "$T/report" && ok || bad "D1b ($(rc): $(cat "$T/out") / $(grep '^| ' "$T/report"))"
mv "$T/verdict.keep" "$T/w/verdict.json"

# The rest run a STUB conductor (the real one cannot be made to merge in
# observe mode, which is the point of M1): each case makes the calls the
# classifier must judge, through the fence.
mv "$L/bin/merge-conductor.sh" "$T/merge-conductor.real"
cat > "$L/bin/merge-conductor.sh" <<'EOF'
#!/bin/bash
mkdir -p "$HARNESS/logs" "$HARNESS/state/merge-conductor"
LOG="$HARNESS/logs/merge-conductor.log"
hd() { printf '%02d%038d' "$1" 0; }
put() { curl -sS -X PUT -H "content-type: application/json" --data-binary "$1" "$JOBS_URL/api/pr-attempts" >/dev/null 2>&1; }
case " $STUB " in *" norehydrate "*) ;; *) echo "2026-10-14 00:00:00Z rehydrated 1 pr-state rows from the pr_state view (skipped=0)" >> "$LOG" ;; esac
echo "2026-10-14 00:00:00Z FANIN merge-conductor example-org/demo: enumerated 1 accounted 1 (ok 1)" >> "$LOG"
case " $STUB " in *" nobatch "*) ;; *) curl -sS "$JOBS_URL/api/conductor-state?repo=example-org%2Fdemo&numbers=1" >/dev/null 2>&1 ;; esac
RV=$(hd 1); case " $STUB " in *" lostreview "*) RV=- ;; esac
HEAD=$(hd 1); case " $STUB " in *" moved "*) HEAD=$(hd 9); RV=- ;; esac
printf 'example-org/demo#1\tREADY\t1791990000\t%s\t%s\t-\t-\thttps://github.com/example-org/demo/pull/1\n' "$HEAD" "$RV" > "$HARNESS/state/merge-conductor/pr-state.tsv"
case " $STUB " in *" merge "*) gh pr merge 1 --repo example-org/demo --squash ;; esac
case " $STUB " in *" heartbeat "*) curl -sS -X POST --data-binary '{"lane":"merge-conductor"}' "$JOBS_URL/api/heartbeat" >/dev/null 2>&1 ;; esac
case " $STUB " in *" oldput "*) put '{"repo":"example-org/demo","number":1,"kind":"rereview","sha":"'"$(hd 1)"'"}' ;; esac
case " $STUB " in *" newput "*) put '{"repo":"example-org/demo","number":1,"kind":"rebase","sha":"'"$(hd 1)"'"}' ;; esac
case " $STUB " in *" push "*) git push origin HEAD >/dev/null 2>&1 ;; esac
case " $STUB " in *" slow "*) sleep 30 ;; esac   # determinism: ok the stub IS the stalled tick the timeout bounds
exit 0
EOF
chmod +x "$L/bin/merge-conductor.sh"

echo "== D2: F1 — a refused merge; a refused heartbeat alone is not a FAIL =="
STUB="heartbeat" drill
[ "$(rc)" = 0 ] && [ "$(first)" = PASS ] && ok || bad "D2 a heartbeat POST alone ($(rc): $(cat "$T/out"))"
grep -q '/api/heartbeat' "$T/report" && ok || bad "D2 the refused heartbeat is listed ($(cat "$T/report"))"
STUB="heartbeat merge" drill
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL: F1" ] && ok || bad "D2 a merge is F1 ($(rc): $(cat "$T/out"))"
STUB="push" drill
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL: F1" ] && ok || bad "D2 a git push is F1 ($(rc): $(cat "$T/out"))"
! grep -q 'pr merge' "$T/gh-calls" 2>/dev/null && ok || bad "D2 the merge reached the fake gh"

echo "== D3: F2 — a refused PUT of an attempt the DB has; a new key alone is not =="
STUB="newput" drill
[ "$(rc)" = 0 ] && [ "$(first)" = PASS ] && ok || bad "D3 a new attempt key alone ($(rc): $(cat "$T/out"))"
STUB="oldput" drill
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL: F2" ] && ok || bad "D3 a known attempt is F2 ($(rc): $(cat "$T/out"))"
grep -q "example-org/demo#1 rereview $(hd 1)" "$T/report" && ok || bad "D3 the report names the attempt ($(cat "$T/report"))"
[ "$(cat "$T/w/db.tsv")" = "$DB0" ] && ok || bad "D3 a PUT reached the worker ($(cat "$T/w/db.tsv"))"

echo "== D4: F3 — the same head lost its review; a moved head is not compared =="
STUB="lostreview" drill
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL: F3" ] && ok || bad "D4 a lost reviewed is F3 ($(rc): $(cat "$T/out"))"
STUB="moved" drill
[ "$(rc)" = 0 ] && [ "$(first)" = PASS ] && grep -q '| head-moved |' "$T/report" && ok || bad "D4 a moved head ($(rc): $(cat "$T/out") / $(grep '^| ' "$T/report"))"

echo "== D5: F4 — no rehydrate line =="
STUB="norehydrate" drill
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL: F4" ] && ok || bad "D5 ($(rc): $(cat "$T/out"))"

echo "== D6: F5 — open PRs and no batch read =="
STUB="nobatch" drill
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL: F5" ] && ok || bad "D6 ($(rc): $(cat "$T/out"))"
STUB="nobatch merge" drill
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL: F1 F5" ] && ok || bad "D6 two codes in one line ($(cat "$T/out"))"

echo "== D7-D10: could not run =="
exec 8>"$L/locks/mc-state-drill.lock"; flock -n 8
drill
[ "$(rc)" = 2 ] && [[ "$(first)" == "COULD NOT RUN: another drill is running"* ]] && ok || bad "D7 the lock held ($(rc): $(cat "$T/out"))"
exec 8>&-
rm -f "$L/flags/pr-state-rows"
drill
[ "$(rc)" = 2 ] && [[ "$(first)" == "COULD NOT RUN: the pr-state-rows flag is down"* ]] && ok || bad "D8 the flag down ($(rc): $(cat "$T/out"))"
touch "$L/flags/pr-state-rows"
STUB="slow" drill --timeout 1
[ "$(rc)" = 2 ] && [[ "$(first)" == "COULD NOT RUN: the tick hit the 1s timeout"* ]] && ok || bad "D9 the timeout ($(rc): $(cat "$T/out"))"
touch "$T/w/route404"
drill
[ "$(rc)" = 2 ] && [[ "$(first)" == *"answered 404"* ]] && ok || bad "D10 the route not deployed ($(rc): $(cat "$T/out"))"
rm -f "$T/w/route404"
[ "$(snap)" = "$SNAP0" ] && ok || bad "the live state/ changed over the run: $(diff <(echo "$SNAP0") <(snap))"
mv "$T/merge-conductor.real" "$L/bin/merge-conductor.sh"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "mc-state-drill.bh-4156: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
