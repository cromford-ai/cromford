#!/bin/bash
# tests/main-red-breaker.bh-8706-test.sh — BH-8706: the main-red breaker lane,
# driven through the REAL bin/main-red-breaker.sh in a scratch harness.
#
# WHAT IS REAL. The lane and its sourced closure (scratch_install_closure):
# lane-gate, env-path, hub-box, jobs-client, gh-rest-list (the real paging and
# the real jq shape filter), gh-app-auth, main-red-label, merge-conductor-lib.
# WHAT IS FAKED (tests/fixtures/main-red-breaker/fixture.sh, sourced through
# the sandbox-only MAIN_RED_BREAKER_FIXTURE seam): gh_rest (a recording store,
# tests/fixtures/main-red-breaker/fake_gh.py, 0 network, an unknown path is an
# UNFAKED line), job_ledger_row/put, mc_queue_provider, is_hub_box. The scratch
# bin/lane-alert.sh records its argv. Every case has its own harness tree.
#
# Cases: P1-P11 pause, F1-F9 file, R1-R9 resume, E1-E5 exits, B1 one warn,
# I1 no identity, X1-X2 --explain, K1 knob fallbacks == seed rows == registry,
# RT1 the round trip, P-SEAM the tracker adapter, N1 the project-6-os repo-side ticket text.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/main-red-breaker.bh-8706-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FAKE="$DIR/tests/fixtures/main-red-breaker/fake_gh.py"
FIX="$DIR/tests/fixtures/main-red-breaker/fixture.sh"
SEED="$DIR/worker/jobs/schema.d/202610290144-bh-8706-main-red-breaker-knobs.sql"
REG="$DIR/catalog/lanes.d/main-red-breaker.json"
NOTE="$DIR/docs/notes/2026-10-28-BH-8706-main-red-breaker.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

S=example-owner/example-repo
S2=example-owner/example-app
HR=example-owner/example-harness
RSHA=1111111111111111111111111111111111111111
RSHA2=3333333333333333333333333333333333333333
GSHA=2222222222222222222222222222222222222222
SINCE=2026-10-28T10:00:00Z

[ -f "$DIR/bin/main-red-breaker.sh" ] || echo "FAIL: $DIR/bin/main-red-breaker.sh is missing (every case below runs anyway)"
TPL="$T/tpl"; mkdir -p "$TPL/bin"
printf '#!/bin/bash\necho "$*" >> "$MRBK_F/alerts"\n' > "$TPL/bin/lane-alert.sh"; chmod +x "$TPL/bin/lane-alert.sh"
scratch_install_closure bin/main-red-breaker.sh "$TPL" >/dev/null || echo "FAIL: scratch_install_closure bin/main-red-breaker.sh"

# fresh <name> — a new case: H (harness) and F (fixture dir), fleet.conf, no flag.
fresh() {
  C="$T/c-$1"; H="$C/h"; F="$C/f"
  mkdir -p "$C" "$F"; cp -a "$TPL" "$H"; mkdir -p "$H/flags" "$H/logs" "$H/state"
  { echo "# project repo prod board offset box ip"
    echo "exrepo  $S  -  -  1 box-fixture 192.0.2.1"
    echo "exapp   $S2 https://app.example.com /api/board 2 box-fixture 192.0.2.2"; } > "$H/fleet.conf"
  : > "$F/calls"; : > "$F/ledger.calls"; : > "$F/alerts"
}
fx() { python3 -I "$FAKE" "$F" "$@"; }
# flag [slug] [sha] [since] [reason] — the detector's flag format (bin/main-red-detector.sh).
flag() {
  local s="${1:-$S}" sha="${2-$RSHA}" since="${3:-$SINCE}" reason="${4:-streak}"
  { [ -n "$sha" ] && echo "sha=$sha"; echo "workflow=CI"; echo "path=.github/workflows/ci.yml"; echo "job=unit"
    echo "since=$since"; echo "streak=2"; echo "run=https://github.com/$s/actions/runs/9001"
    echo "detected=$since"; echo "reason=$reason"; } > "$H/flags/main-red-$(echo "$s" | tr '/' '-')"
}
pairflag() { # the sha-less shape bin/main-red-pr-pair.sh raises
  { echo "owner=main-red-pr-pair"; echo "since=$SINCE"; echo "reason=pr-pair-suspected"; } > "$H/flags/main-red-$(echo "$S" | tr '/' '-')"
}
run() {
  env HARNESS="$H" HARNESS_TEST_SANDBOX=1 MAIN_RED_BREAKER_FIXTURE="$FIX" MRBK_F="$F" MRBK_FAKE="$FAKE" \
      JOBS_URL= HARNESS_SECRET= HARNESS_REPO="$HR" GH_TOKEN= TMPDIR="$C" "$@" bash "$H/bin/main-red-breaker.sh" ${ARGS_:-"$S"} 2>>"$C/stderr"
}
ARGS_=""
calls()  { grep -c -- "$1" "$F/calls"; }
lput()   { grep -c -- "^put $1" "$F/ledger.calls"; }
row()    { jq -c --arg k "$1" --arg v "$2" 'select(.kind==$k and .key==$v)' "$F/ledger" 2>/dev/null | tail -1; }
logged() { grep -c -- "$1" "$H/logs/main-red-breaker.log" 2>/dev/null; }
noun()   { ! grep -q UNFAKED "$F/calls"; }
seed_ticket() { # the jobs, annotations, last green and compare of run 9001
  fx set "jobs:9001" '{"jobs":[{"id":501,"name":"unit","conclusion":"failure","html_url":"https://github.com/'"$S"'/actions/runs/9001/job/501","steps":[{"name":"Set up","conclusion":"success"},{"name":"Run tests","conclusion":"failure"}]},{"id":502,"name":"lint","conclusion":"success","html_url":"x","steps":[]}]}'
  fx set "ann:501" '[{"annotation_level":"failure","path":"tests/a-test.sh","start_line":12,"message":"FAIL: case Q7 expected 3 got 2"},{"annotation_level":"warning","path":"w","start_line":1,"message":"just a warning"}]'
  fx set "green:ci.yml" "\"$GSHA\""
  fx set "compare:$GSHA...$RSHA" '{"commits":[{"sha":"aaaaaaaaaaaaaaaa","commit":{"message":"Merge pull request #41 from example-owner/ticket/a\n\nfirst"}},{"sha":"bbbbbbbbbbbbbbbb","commit":{"message":"chore: a direct push"}},{"sha":"cccccccccccccccc","commit":{"message":"fix the thing (#42)"}}]}'
}

# ── P1 red flag + 3 queued PRs ────────────────────────────────────────────────
fresh p1; flag; for n in 1 2 3; do fx add "$S" "$n" merge-queue; done
run MAIN_RED_BREAKER_TICKETS=0
check "P1 three label POSTs" '[ "$(calls "POST repos/$S/issues/[0-9]*/labels")" = 3 ]'
check "P1 every PR carries the pause label" '[ "$(fx labels "$S" 1)" = "merge-queue,merge-queue-paused" ] && [ "$(fx labels "$S" 3)" = "merge-queue,merge-queue-paused" ]'
check "P1 the row is paused with [1,2,3]" '[ "$(row main_red_breaker "$S" | jq -r ".status + \" \" + (.detail|fromjson|.paused|map(tostring)|join(\",\"))")" = "paused 1,2,3" ]'
check "P1 the log says paused 3 PR(s)" '[ "$(logged "paused 3 PR(s)")" = 1 ]'
check "P1 no UNFAKED path" noun

# ── P2 the decision table ─────────────────────────────────────────────────────
fresh p2; flag
for n in $(seq 1001 1100); do fx add "$S" "$n" merge-queue open issue; done   # (f) 100 plain issues fill page 1
fx add "$S" 11 merge-queue                    # (a)
fx add "$S" 12 merge-queue,queue-solo         # (b)
fx add "$S" 13 merge-queue,dequeued           # (c)
fx add "$S" 14 merge-queue                    # (d) on page 2 (the 104th row)
fx add "$S" 15 merge-queue,fix-main-red       # (e)
fx add "$S" 17 merge-queue-x                  # (g)
fx add "$S" 18 merge-queue,merge-queue-paused # (h)
fx add "$S" 19 merge-queue closed             # (i)
run MAIN_RED_BREAKER_TICKETS=0
for n in 11 12 13 14; do check "P2 #$n is paused" '[ "$(calls "POST repos/$S/issues/'"$n"'/labels")" = 1 ]'; done
for n in 15 17 18 19 1001 1100; do check "P2 #$n is not paused" '[ "$(calls "POST repos/$S/issues/'"$n"'/labels")" = 0 ]'; done
check "P2 page 2 was read" '[ "$(calls "GET repos/$S/issues")" -ge 2 ]'

# ── P3 one POST answers 422 ───────────────────────────────────────────────────
fresh p3; flag; for n in 1 2 3; do fx add "$S" "$n" merge-queue; done
fx fail "POST repos/$S/issues/2/labels" 422
run MAIN_RED_BREAKER_TICKETS=0
check "P3 the row lists 1 and 3 only" '[ "$(row main_red_breaker "$S" | jq -r ".detail|fromjson|.paused|map(tostring)|join(\",\")")" = "1,3" ]'
check "P3 the log says 2, never 3" '[ "$(logged "paused 2 PR(s)")" = 1 ] && [ "$(logged "paused 3 PR(s)")" = 0 ]'
check "P3 the failed POST is logged" '[ "$(logged "#2 label POST failed")" = 1 ]'

# ── P7 the pausing row does not write: no label goes on ──────────────────────
fresh p7; flag; for n in 1 2; do fx add "$S" "$n" merge-queue; done; touch "$F/put-fail.pausing"
run MAIN_RED_BREAKER_TICKETS=0
check "P7 no label POST" '[ "$(calls "/labels")" = 0 ] && [ "$(fx labels "$S" 1)" = merge-queue ]'
check "P7 the log says why" '[ "$(logged "pausing row did not write — nothing labelled")" = 1 ]'

# ── P8 the pausing row goes first; a lost paused row still resumes ───────────
fresh p8; flag; for n in 1 2; do fx add "$S" "$n" merge-queue; done; touch "$F/put-fail.paused"
run MAIN_RED_BREAKER_TICKETS=0
check "P8 the pausing put is the first ledger write" '[ "$(grep "^put" "$F/ledger.calls" | head -1)" = "put main_red_breaker $S pausing" ]'
check "P8 the row stays pausing" '[ "$(row main_red_breaker "$S" | jq -r .status)" = pausing ]'
rm -f "$F/put-fail.paused" "$H/flags/main-red-example-owner-example-repo"; run
check "P8 green: the labels come off and the PRs are re-queued" '[ "$(fx labels "$S" 1)" = merge-queue ] && [ "$(fx labels "$S" 2)" = merge-queue ] && [ "$(grep -c . "$F/requeues")" = 2 ]'
check "P8 the row is resumed" '[ "$(row main_red_breaker "$S" | jq -r .status)" = resumed ]'

# ── P4 a GitHub-native queue ──────────────────────────────────────────────────
fresh p4; flag; fx add "$S" 1 merge-queue; echo github > "$F/provider"
run MAIN_RED_BREAKER_TICKETS=0; run MAIN_RED_BREAKER_TICKETS=0
check "P4 no label POST" '[ "$(calls "/labels")" = 0 ]'
check "P4 one provider line over two ticks" '[ "$(logged "pause: provider=github — not paused (no label hook)")" = 1 ]'

# ── P5 the cap ────────────────────────────────────────────────────────────────
fresh p5; flag; for n in 1 2 3; do fx add "$S" "$n" merge-queue; done
run MAIN_RED_BREAKER_TICKETS=0 MAIN_RED_BREAKER_MAX_PRS=2
check "P5 tick 1 pauses 2 and says capped" '[ "$(calls "/labels")" = 2 ] && [ "$(logged "pause: capped at 2, the rest next tick")" = 1 ]'
run MAIN_RED_BREAKER_TICKETS=0 MAIN_RED_BREAKER_MAX_PRS=2
check "P5 tick 2 pauses the third" '[ "$(calls "/labels")" = 3 ] && [ "$(fx labels "$S" 3)" = "merge-queue,merge-queue-paused" ]'
check "P5 tick 2 is not capped" '[ "$(logged "pause: capped")" = 1 ]'
check "P5 the row holds all three" '[ "$(row main_red_breaker "$S" | jq -r ".detail|fromjson|.paused|map(tostring)|join(\",\")")" = "1,2,3" ]'

# ── P6 two repos (fleet.conf) plus the harness repo, one red ──────────────────
fresh p6; flag "$S2"; fx add "$S" 1 merge-queue; fx add "$S2" 2 merge-queue
ARGS_=" " run MAIN_RED_BREAKER_TICKETS=0
check "P6 only the red repo is read for PRs" '[ "$(calls "GET repos/$S2/issues")" = 1 ] && [ "$(calls "GET repos/$S/issues")" = 0 ] && [ "$(calls "repos/$HR/")" = 0 ]'
check "P6 every listed repo had its one row read" '[ "$(grep -c "^row main_red_breaker" "$F/ledger.calls")" = 3 ]'
check "P6 the tick line counts 3 repos, 1 red" '[ "$(logged "tick: 3 repo(s), 1 red repo(s)")" = 1 ]'

# ── F1 a new episode files one ticket ─────────────────────────────────────────
fresh f1; flag; seed_ticket; fx add "$S" 1 merge-queue
run
fx created > "$C/created.json"
B=$(jq -r '.[0].body' "$C/created.json")
check "F1 one issue POST" '[ "$(calls "POST repos/$S/issues$")" = 1 ]'
check "F1 labels ai-build,hotfix" '[ "$(jq -r ".[0].labels|map(.name)|join(\",\")" "$C/created.json")" = "ai-build,hotfix" ]'
check "F1 title" '[ "$(jq -r ".[0].title" "$C/created.json")" = "HOTFIX: $S main is red — CI / unit" ]'
check "F1 Failing checks: job, failed step, log link" 'grep -qF "## Failing checks" <<<"$B" && grep -qF "**unit** (failed step: Run tests) — https://github.com/$S/actions/runs/9001/job/501" <<<"$B"'
check "F1 the failure annotation, not the warning" 'grep -qF "\`tests/a-test.sh:12\` FAIL: case Q7 expected 3 got 2" <<<"$B" && ! grep -qF "just a warning" <<<"$B"'
check "F1 the passing job is not listed" '! grep -qF "**lint**" <<<"$B"'
check "F1 suspect merges #41 then #42, the direct push left out" '[ "$(grep -oE "^- #[0-9]+" <<<"$B" | tr "\n" " ")" = "- #41 - #42 " ] && ! grep -q "direct push" <<<"$B"'
check "F1 Logs: the run and the job URL" 'grep -qF -- "- run: https://github.com/$S/actions/runs/9001" <<<"$B" && grep -qF -- "- job: https://github.com/$S/actions/runs/9001/job/501" <<<"$B"'
check "F1 PR-Labels and the marker" 'grep -qx "PR-Labels: fix-main-red" <<<"$B" && grep -qxF "<!-- main-red-breaker: $S@$SINCE -->" <<<"$B"'
check "F1 the hotfix row is filed with the URL" '[ "$(row main_red_hotfix "$S@$SINCE" | jq -r ".status + \" \" + (.detail|fromjson|.url)")" = "filed https://github.com/$S/issues/9001" ]'
check "F1 the log says filed <url>" '[ "$(logged "ticket: filed https://github.com/$S/issues/9001")" = 1 ]'
check "F1 the pause ran in the same tick" '[ "$(calls "POST repos/$S/issues/1/labels")" = 1 ]'
check "F1 no UNFAKED path" noun

check "F1 a templated repo: the body says the queue is paused" 'grep -qF "its Mergify queue is paused until main is green" <<<"$B"'

# ── P9 a Mergify repo whose .mergify.yml does not exclude the pause label ────
# (example-org/project-6 today): the label would pause nothing, so it is not
# written, no pausing row, and the ticket never says the queue is paused.
fresh p9; flag; seed_ticket; for n in 1 2; do fx add "$S" "$n" merge-queue; done
fx set "mergify:$S" '"queue_rules:\n  - name: default\n    queue_conditions:\n      - label=merge-queue\n      - -label=merge-queue-paused-not\n"'
run; run
fx created > "$C/created.json"
B=$(jq -r '.[0].body' "$C/created.json")
check "P9 no label POST over two ticks" '[ "$(calls "/labels")" = 0 ] && [ "$(fx labels "$S" 1)" = merge-queue ]'
check "P9 no main_red_breaker row" '[ "$(lput main_red_breaker)" = 0 ]'
check "P9 one not-paused line over two ticks" '[ "$(logged "does not exclude merge-queue-paused — not paused")" = 1 ]'
check "P9 the ticket is still filed once" '[ "$(calls "POST repos/$S/issues$")" = 1 ]'
check "P9 the body never claims the queue is paused" '! grep -qiF "queue is paused" <<<"$B"'
check "P9 the body says the queue is NOT paused and why" 'grep -qF "Its merge queue is NOT paused" <<<"$B" && grep -qF "does not exclude \`merge-queue-paused\`" <<<"$B"'
check "P9 no UNFAKED path" noun

# ── P10 a repo with no .mergify.yml (404) is not paused either ───────────────
fresh p10; flag; fx add "$S" 1 merge-queue; fx set "mergify:$S" 'null'
run MAIN_RED_BREAKER_TICKETS=0
check "P10 no label POST" '[ "$(calls "/labels")" = 0 ]'

# ── P11 the .mergify.yml read fails: labels go on, the pause is unconfirmed ─
fresh p11; flag; seed_ticket; fx add "$S" 1 merge-queue; fx fail "GET repos/$S/contents/" 502
run
fx created > "$C/created.json"
B=$(jq -r '.[0].body' "$C/created.json")
check "P11 the label goes on" '[ "$(fx labels "$S" 1)" = "merge-queue,merge-queue-paused" ]'
check "P11 the log says unconfirmed" '[ "$(logged "the pause is unconfirmed")" = 1 ]'
check "P11 the body says unconfirmed, never paused" 'grep -qF "queue pause is unconfirmed" <<<"$B" && ! grep -qiF "queue is paused" <<<"$B"'

# ── F2 a second tick, same sha ────────────────────────────────────────────────
run
check "F2 no second issue POST" '[ "$(calls "POST repos/$S/issues$")" = 1 ]'

# ── F3 a new red sha, same since ──────────────────────────────────────────────
flag "$S" "$RSHA2"; run
check "F3 no POST for a new sha in the same episode" '[ "$(calls "POST repos/$S/issues$")" = 1 ]'

# ── F4 the ledger lost the row, the marker is in an open issue ────────────────
fresh f4; flag; seed_ticket
fx add "$S" 77 hotfix open issue "body
<!-- main-red-breaker: $S@$SINCE -->"
fx add "$S" 78 hotfix open issue "<!-- main-red-breaker: $S@2026-10-01T00:00:00Z -->"
run
check "F4 no POST" '[ "$(calls "POST repos/$S/issues$")" = 0 ]'
check "F4 the row is written from the marker" '[ "$(row main_red_hotfix "$S@$SINCE" | jq -r ".detail|fromjson|.issue")" = 77 ]'

# ── F5 the hotfix row read answers 75 ─────────────────────────────────────────
fresh f5; flag; seed_ticket; echo 75 > "$F/ledger-rc.main_red_hotfix"
run
check "F5 no POST, no hotfix row" '[ "$(calls "POST repos/$S/issues$")" = 0 ] && [ "$(lput main_red_hotfix)" = 0 ]'
check "F5 the log says why" '[ "$(logged "ticket: the main_red_hotfix row did not read (rc=75)")" = 1 ]'

# ── F6 a new episode after a clear files a second ticket ──────────────────────
fresh f6; flag; seed_ticket; run
rm -f "$H/flags/main-red-example-owner-example-repo"; run
flag "$S" "$RSHA" 2026-10-28T12:00:00Z; run
check "F6 two tickets over two episodes" '[ "$(calls "POST repos/$S/issues$")" = 2 ]'
check "F6 the second marker carries the new since" 'fx created | jq -r ".[1].body" | grep -qF "<!-- main-red-breaker: $S@2026-10-28T12:00:00Z -->"'
# F6 (i): the first episode's marker is still in an open issue and does not count as a hit.

# ── F7 a sha-less pr-pair flag pauses and files nothing ───────────────────────
fresh f7; pairflag; fx add "$S" 1 merge-queue
run
check "F7 the PR is paused" '[ "$(calls "POST repos/$S/issues/1/labels")" = 1 ]'
check "F7 no issue POST and no hotfix row read" '[ "$(calls "POST repos/$S/issues$")" = 0 ] && ! grep -q "^row main_red_hotfix" "$F/ledger.calls"'
check "F7 the log says why" '[ "$(logged "ticket: the flag has no judged sha yet (pr-pair-suspected)")" = 1 ]'

# ── F8 an in-app-board project ────────────────────────────────────────────────
fresh f8; flag "$S2"; seed_ticket
ARGS_="$S2" run
check "F8 no issue POST" '[ "$(calls "POST repos/$S2/issues$")" = 0 ]'
check "F8 the A6 line" '[ "$(logged "ticket: not filed — exapp uses an in-app board")" = 1 ]'

# ── F9 the green-run read fails ───────────────────────────────────────────────
fresh f9; flag; seed_ticket; fx fail "GET repos/$S/actions/workflows" 500
run
check "F9 the POST still happens" '[ "$(calls "POST repos/$S/issues$")" = 1 ]'
check "F9 the body says the suspects are unknown" 'fx created | jq -r ".[0].body" | grep -q "^Suspect merges: unknown — "'

# ── R1 green: remove the labels, row resumed ──────────────────────────────────
fresh r1; for n in 1 2 3; do fx add "$S" "$n" merge-queue,merge-queue-paused; done
job_put() { jq -nc --arg k "$1" --arg v "$2" --arg s "$3" --arg d "$4" '{kind:$k,key:$v,status:$s,detail:$d}' >> "$F/ledger"; }
job_put main_red_breaker "$S" paused "{\"since\":\"$SINCE\",\"paused\":[1,2,3]}"
run
check "R1 three DELETEs" '[ "$(calls "DELETE repos/$S/issues/[0-9]*/labels/merge-queue-paused")" = 3 ]'
check "R1 the labels are gone, merge-queue stays" '[ "$(fx labels "$S" 2)" = merge-queue ]'
check "R1 the row is resumed" '[ "$(row main_red_breaker "$S" | jq -r .status)" = resumed ]'
check "R1 the log says resumed" '[ "$(logged "resumed (3 PR(s) unpaused and re-queued)")" = 1 ]'
check "R1 each PR is re-queued once on its head" '[ "$(grep -c . "$F/requeues")" = 3 ] && grep -qxF "$S https://github.com/$S/pull/2 $(printf "head2%035d" 0)" "$F/requeues"'
check "R1 the conductor grace mark before the requeue" 'grep -qxF "qpaused $S#2 $(printf "head2%035d" 0)" "$F/attempts"'
check "R1 the requeue spends no BH-636 requeue" '! grep -q "^requeued " "$F/attempts"'
run
check "R1 a resumed row costs no GitHub read next tick" '[ "$(calls "GET repos/$S/issues")" = 2 ]'

# ── R2 one DELETE answers 500 ─────────────────────────────────────────────────
fresh r2; for n in 1 2 3; do fx add "$S" "$n" merge-queue,merge-queue-paused; done
job_put main_red_breaker "$S" paused "{\"since\":\"$SINCE\",\"paused\":[1,2,3]}"
fx fail "DELETE repos/$S/issues/2/labels" 500
run
check "R2 the row stays paused" '[ "$(row main_red_breaker "$S" | jq -r .status)" = paused ] && [ "$(lput main_red_breaker)" = 0 ]'
check "R2 no resumed line" '[ "$(logged "resumed")" = 0 ]'
fx fail "DELETE repos/$S/issues/2/labels" -; run
check "R2 the next tick finishes" '[ "$(row main_red_breaker "$S" | jq -r .status)" = resumed ]'

# ── R3 a DELETE 404 counts as ok ──────────────────────────────────────────────
fresh r3; fx add "$S" 1 merge-queue,merge-queue-paused; fx add "$S" 2 merge-queue,merge-queue-paused
job_put main_red_breaker "$S" paused "{\"since\":\"$SINCE\",\"paused\":[1,2]}"
fx set gone404 "[\"$S#1\"]"
run
check "R3 the 404 DELETE is not logged as a failure" '[ "$(logged "label DELETE failed")" = 0 ]'
check "R3 the 404 counts ok: the row is resumed" '[ "$(row main_red_breaker "$S" | jq -r .status)" = resumed ] && [ "$(logged "resumed (2 PR(s) unpaused and re-queued)")" = 1 ]'

# ── R6 a DELETE answers 200 but the label stays: the re-read gates resumed ───
fresh r6; fx add "$S" 1 merge-queue,merge-queue-paused
job_put main_red_breaker "$S" paused "{\"since\":\"$SINCE\",\"paused\":[1]}"
fx fail "DELETE repos/$S/issues/1/labels" 200
run
check "R6 the re-read still shows the label, so not resumed" '[ "$(row main_red_breaker "$S" | jq -r .status)" = paused ] && [ "$(logged "1 PR(s) still carry merge-queue-paused")" = 1 ] && [ "$(logged "resumed (")" = 0 ]'

# ── R7 a pausing row resumes too, and lists PRs whose label is already gone ──
fresh r7; fx add "$S" 1 merge-queue,merge-queue-paused; fx add "$S" 2 merge-queue,dequeued
job_put main_red_breaker "$S" pausing "{\"since\":\"$SINCE\",\"paused\":[2]}"
run
check "R7 the labelled PR is unpaused" '[ "$(fx labels "$S" 1)" = merge-queue ]'
check "R7 both PRs are re-queued (row list and label)" '[ "$(grep -c . "$F/requeues")" = 2 ] && grep -q "/pull/1 " "$F/requeues" && grep -q "/pull/2 " "$F/requeues"'
check "R7 the row is resumed" '[ "$(row main_red_breaker "$S" | jq -r .status)" = resumed ]'

# ── R8 a refused requeue keeps the row and retries only that PR ──────────────
fresh r8; for n in 1 2; do fx add "$S" "$n" merge-queue,merge-queue-paused; done
job_put main_red_breaker "$S" paused "{\"since\":\"$SINCE\",\"paused\":[1,2]}"
echo 1 > "$F/requeue-rc"; run
check "R8 refused: the row stays paused" '[ "$(row main_red_breaker "$S" | jq -r .status)" = paused ] && [ "$(logged "re-queue refused (rc=1")" = 2 ]'
check "R8 refused: the labels are off" '[ "$(fx labels "$S" 1)" = merge-queue ] && [ "$(fx labels "$S" 2)" = merge-queue ]'
echo 0 > "$F/requeue-rc"; run
check "R8 the next tick re-queues both and resumes" '[ "$(grep -c . "$F/requeues")" = 4 ] && [ "$(row main_red_breaker "$S" | jq -r .status)" = resumed ]'
run
check "R8 a resumed row re-queues nothing more" '[ "$(grep -c . "$F/requeues")" = 4 ]'

# ── R9 a PR that lost merge-queue or closed is not re-queued ─────────────────
fresh r9; fx add "$S" 1 merge-queue-paused; fx add "$S" 2 merge-queue closed
job_put main_red_breaker "$S" paused "{\"since\":\"$SINCE\",\"paused\":[1,2]}"
run
check "R9 no requeue" '[ ! -s "$F/requeues" ] && [ "$(logged "nothing to put back")" = 2 ]'
check "R9 the row is resumed" '[ "$(row main_red_breaker "$S" | jq -r .status)" = resumed ]'

# ── R4 no flag, no row ────────────────────────────────────────────────────────
fresh r4; fx add "$S" 1 merge-queue
run
check "R4 one ledger read" '[ "$(grep -c . "$F/ledger.calls")" = 1 ]'
check "R4 zero GitHub calls" '[ "$(grep -c . "$F/calls")" = 0 ]'

# ── R5 a hand-added pause label on a never-paused repo ────────────────────────
fresh r5; fx add "$S" 1 merge-queue,merge-queue-paused
run
check "R5 not removed" '[ "$(calls DELETE)" = 0 ] && [ "$(fx labels "$S" 1)" = "merge-queue,merge-queue-paused" ]'

# ── E1-E5 exit paths ──────────────────────────────────────────────────────────
fresh e1; flag; fx add "$S" 1 merge-queue; touch "$H/flags/lane-off-main-red-breaker"
run; check "E1 off flag: no read" '[ "$(grep -c . "$F/calls")" = 0 ] && [ "$(grep -c . "$F/ledger.calls")" = 0 ]'
fresh e2; flag; fx add "$S" 1 merge-queue; touch "$F/not-hub"
run; check "E2 not hub: no read" '[ "$(grep -c . "$F/calls")" = 0 ] && [ "$(grep -c . "$F/ledger.calls")" = 0 ]'
fresh e3; flag; fx add "$S" 1 merge-queue; mkdir -p "$H/locks"
( exec 8>"$H/locks/main-red-breaker.lock"; flock -n 8; run )
check "E3 lock held: one line, no read" '[ "$(logged "another main-red-breaker tick holds the lock, skipping")" = 1 ] && [ "$(grep -c . "$F/calls")" = 0 ]'
fresh e4; flag; fx add "$S" 1 merge-queue; echo 1 > "$F/ledger-rc.main_red_breaker"
run; check "E4 ledger unreadable: nothing paused or filed" '[ "$(grep -c . "$F/calls")" = 0 ] && [ "$(grep -c "^put" "$F/ledger.calls")" = 0 ] && [ "$(logged "row did not read (rc=1) — repo skipped")" = 1 ]'
fresh e5; flag; seed_ticket; fx add "$S" 1 merge-queue; fx fail "GET repos/$S/issues" 429
run; check "E5 list 429: no POST, no row" '[ "$(calls POST)" = 0 ] && [ "$(grep -c "^put" "$F/ledger.calls")" = 0 ] && [ "$(logged "merge-queue list did not read (rc=75 http=429")" = 1 ]'
check "E1-E5 the flag is never touched" '[ -f "$T/c-e5/h/flags/main-red-example-owner-example-repo" ] && [ -f "$T/c-e4/h/flags/main-red-example-owner-example-repo" ]'

# ── B1 the create fails three ticks running ───────────────────────────────────
fresh b1; flag; seed_ticket; fx fail "POST repos/$S/issues" 500
run; run; run
check "B1 three create attempts" '[ "$(calls "POST repos/$S/issues$")" = 3 ]'
check "B1 exactly one warn with the episode id" '[ "$(grep -c . "$F/alerts")" = 1 ] && grep -qF -- "--severity warn --id main-red-breaker-file:$S@$SINCE main-red-breaker" "$F/alerts"'
check "B1 no hotfix row" '[ "$(lput main_red_hotfix)" = 0 ]'

# ── I1 no identity for the repo ───────────────────────────────────────────────
fresh i1; flag; fx add "$S" 1 merge-queue; touch "$F/noauth"
run; check "I1 nothing paused or filed" '[ "$(grep -c . "$F/calls")" = 0 ] && [ "$(logged "no identity for $S")" = 1 ]'

# ── X1 --explain writes nothing ───────────────────────────────────────────────
fresh x1; flag; seed_ticket; fx add "$S" 1 merge-queue
ARGS_="--explain $S" run
check "X1 no POST, no DELETE, no ledger write" '[ "$(calls POST)" = 0 ] && [ "$(calls DELETE)" = 0 ] && [ "$(grep -c "^put" "$F/ledger.calls")" = 0 ]'
check "X1 the WOULD lines" '[ "$(logged "WOULD PAUSE #1")" = 1 ] && [ "$(logged "WOULD FILE \"HOTFIX: $S main is red — CI / unit\"")" = 1 ]'
fresh x2; fx add "$S" 1 merge-queue,merge-queue-paused
job_put main_red_breaker "$S" paused "{\"since\":\"$SINCE\",\"paused\":[1]}"
ARGS_="--explain $S" run
check "X2 explain resume: no DELETE, no requeue, no write" '[ "$(calls DELETE)" = 0 ] && [ ! -s "$F/requeues" ] && [ "$(grep -c "^put" "$F/ledger.calls")" = 0 ] && [ "$(logged "WOULD REQUEUE #1")" = 1 ]'

# ── K1 knob fallbacks == seed rows == registry defaults ──────────────────────
for kv in MAIN_RED_BREAKER_MAX_PRS=50 MAIN_RED_BREAKER_MAX_JOBS=5 MAIN_RED_BREAKER_MAX_ANNOTATIONS=10 \
          MAIN_RED_BREAKER_MAX_SUSPECTS=20 MAIN_RED_BREAKER_TICKETS=1 MAIN_RED_BREAKER_PAUSE_LABEL=merge-queue-paused \
          MAIN_RED_BREAKER_TICKET_LABELS=ai-build,hotfix; do
  k=${kv%%=*}; v=${kv#*=}; lk=$(echo "$k" | tr 'A-Z' 'a-z')
  check "K1 $k code fallback is $v" 'grep -qF "\${$k:-$v}" "$DIR/bin/main-red-breaker.sh"'
  check "K1 $k seed row is $v" 'grep -qF "('"'"'lane.main-red-breaker.$lk'"'"','"'"'$v'"'"'" "$SEED"'
  check "K1 $k registry default is $v" '[ "$(jq -r --arg e "$k" ".knobs[] | select(.env==\$e) | .default | tostring" "$REG")" = "$v" ]'
done
check "K1 MAIN_RED_SKIP_RE_OVERRIDES seed row is {}" 'grep -qF "('"'"'lane.main-red-breaker.main_red_skip_re_overrides'"'"','"'"'{}'"'"'" "$SEED"'

# ── RT1 the round trip ────────────────────────────────────────────────────────
fresh rt1; seed_ticket; for n in 1 2; do fx add "$S" "$n" merge-queue; done; fx add "$S" 3 merge-queue,fix-main-red
flag; run
check "RT1 red: 2 paused, the fix PR not" '[ "$(fx labels "$S" 1)" = "merge-queue,merge-queue-paused" ] && [ "$(fx labels "$S" 3)" = "merge-queue,fix-main-red" ]'
check "RT1 red: one ticket" '[ "$(calls "POST repos/$S/issues$")" = 1 ] && [ "$(row main_red_hotfix "$S@$SINCE" | jq -r .status)" = filed ]'
fx add "$S" 4 merge-queue; run
check "RT1 repeat tick: no new ticket, the newly queued PR is paused" '[ "$(calls "POST repos/$S/issues$")" = 1 ] && [ "$(fx labels "$S" 4)" = "merge-queue,merge-queue-paused" ]'
check "RT1 the row now holds 1,2,4" '[ "$(row main_red_breaker "$S" | jq -r ".detail|fromjson|.paused|map(tostring)|join(\",\")")" = "1,2,4" ]'
rm -f "$H/flags/main-red-example-owner-example-repo"; run
check "RT1 green: every pause label gone" '[ "$(fx labels "$S" 1)" = merge-queue ] && [ "$(fx labels "$S" 4)" = merge-queue ] && [ "$(row main_red_breaker "$S" | jq -r .status)" = resumed ]'
check "RT1 green: 1, 2 and 4 re-queued, the fix PR not" '[ "$(grep -oE "/pull/[0-9]+ " "$F/requeues" | sort | tr -d "\n")" = "/pull/1 /pull/2 /pull/4 " ]'
check "RT1 the fix PR was never touched" '[ "$(calls "repos/$S/issues/3/")" = 0 ]'
check "RT1 no --critical from the breaker" '! grep -q -- "--critical\|--severity critical" "$F/alerts"'
check "RT1 no UNFAKED path" noun

# ── P-SEAM the issue writes go through the tracker adapter (BH-7919) ─────────
# TRK_LOG is the github-issues adapter's command log: a line there proves the
# write went through bin/lib/tracker/github-issues.sh, not a direct gh_rest.
fresh pseam; flag; seed_ticket; fx add "$S" 1 merge-queue
run TRK_LOG="$C/trk.log"
check "P-SEAM the label POST goes through trk_gh_label_add" 'grep -qxF "gh api -X POST repos/$S/issues/1/labels -f labels[]=merge-queue-paused" "$C/trk.log" && [ "$(fx labels "$S" 1)" = "merge-queue,merge-queue-paused" ]'
check "P-SEAM the issue POST goes through trk_gh_create" '[ "$(grep -c "^gh api -X POST repos/$S/issues --input " "$C/trk.log")" = 1 ] && [ "$(fx created | jq length)" = 1 ] && [ "$(logged "ticket: filed https://github.com/$S/issues/")" = 1 ]'
rm -f "$H/flags/main-red-$(echo "$S" | tr '/' '-')"
run TRK_LOG="$C/trk.log"
check "P-SEAM the label DELETE goes through trk_gh_label_remove" 'grep -qxF "gh api -X DELETE repos/$S/issues/1/labels/merge-queue-paused" "$C/trk.log" && [ "$(fx labels "$S" 1)" = merge-queue ]'
check "P-SEAM no UNFAKED path" noun
check "P-SEAM no stderr" '[ ! -s "$C/stderr" ]'

# ── N1 the project-6-os repo-side ticket text ─────────────────────────────────
check "N1 the note carries the project-6-os repo-side ticket" 'grep -q "^## project-6-os repo-side ticket" "$NOTE" && grep -q -- "-label=merge-queue-paused" "$NOTE" && grep -qi "push" "$NOTE" && grep -q "example-org/project-6" "$NOTE"'

check "no stderr from any tick" '[ ! -s "$T/c-p1/stderr" ] && [ ! -s "$T/c-rt1/stderr" ]'
[ "$FAIL" = 0 ] || { echo "--- stderr of rt1:"; head -20 "$T/c-rt1/stderr" 2>/dev/null; }
echo "main-red-breaker.bh-8706: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
