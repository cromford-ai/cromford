#!/bin/bash
# tests/ci-nightly-full.bh-4964-test.sh — bin/ci-nightly-full.sh, the hub lane
# that starts one FULL harness-ci run on main a day and files the red as a map
# gap (BH-4970, slice 3 of BH-4964).
#
# Every case drives the REAL bin/ci-nightly-full.sh (installed with its closure
# into a scratch $HARNESS) with a fake `gh` on PATH that logs each call and
# answers from fixture files. The cromford checkout it reads is a scratch
# git repo with an origin, and the map it asks is the REAL bin/test-impact.sh
# committed into that repo, so "which changed file does not select the red
# suite" is the production question on a tree small enough to read.
#
#   D1  flags/automerge-disabled                  no dispatch, logged
#   D2  an open PR labelled merge-queue           no dispatch, logged
#   D2b the merge-queue read fails                no dispatch (fails closed)
#   D3  a second dispatch the same date           one `workflow run` in total
#   D4  clean                                     one `workflow run`, run.json
#   D5  `workflow run` exits 75                   claim gone, ONE ALERTS line, retry works
#   D6  before CI_NIGHTLY_FULL_HOUR               zero gh calls
#   D7  a claim dir with no run.json              held when fresh, reclaimed when stale
#   K1  flags/lane-off-ci-nightly-full            zero gh calls, both subcommands
#   B1  the gh budget is low                      zero gh calls, both subcommands
#   C1  run in_progress                           no issue call, no done
#   C2  run success                               last_green_sha, no issue call
#   C3  run failure                               ONE create labelled ai-build; body names
#                                                 the suite and bin/b.sh, never bin/a.sh
#   C4  a second red, the marker issue open       ONE comment, no create, no /labels
#   C5  the create fails                          no ticketed/done, ONE ALERTS; retry files
#   C6  no last_green_sha                         the body says sha~20 and why
#   C7  run cancelled                             no issue call, done
#   C8  the open-issue list read fails            no create
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ci-nightly-full.bh-4964-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The clock is pinned: 2026-10-07 03:20:00Z, an hour past the default knob.
NOW=1791343200
TODAY=2026-10-07
R=example-org/cromford

HH="$T/h"; FX="$T/fx"; STUB="$T/stub"
mkdir -p "$HH/logs" "$HH/flags" "$HH/env" "$HH/state/gh-budget" "$FX" "$STUB"
scratch_install_closure bin/ci-nightly-full.sh "$HH" >/dev/null || bad "scratch_install_closure bin/ci-nightly-full.sh (the lane is missing)"
scratch_install_closure bin/jobs-client.sh "$HH" >/dev/null || bad "scratch_install_closure bin/jobs-client.sh (the pause-flag reader is missing)"
scratch_install_closure bin/alert-line.sh "$HH" >/dev/null || bad "scratch_install_closure bin/alert-line.sh (the lane's ALERTS writer is missing)"
: > "$HH/env/global.env"
S="$HH/state/ci-nightly-full"

# --- the scratch cromford checkout: A (green) then B (red) ---------------
WORK="$T/work"; mkdir -p "$WORK/bin" "$WORK/tests"
scratch_install_closure bin/test-impact.sh "$WORK" >/dev/null || { echo "FAIL: scratch_install_closure bin/test-impact.sh"; exit 1; }
printf 'echo a\n' > "$WORK/bin/a.sh"; printf 'echo b\n' > "$WORK/bin/b.sh"
printf '#!/bin/bash\nDIR=$(dirname "$0")/..\nbash "$DIR/bin/a.sh"\n' > "$WORK/tests/x-test.sh"
G() { git -C "$WORK" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
G init -q -b main; G add -A; G commit -qm A
A=$(git -C "$WORK" rev-parse HEAD)
printf 'echo a2\n' > "$WORK/bin/a.sh"; printf 'echo b2\n' > "$WORK/bin/b.sh"
G add -A; G commit -qm B
B=$(git -C "$WORK" rev-parse HEAD)
git clone -q --bare "$WORK" "$T/origin.git" 2>/dev/null
mkdir -p "$T/repos"; git clone -q "$T/origin.git" "$T/repos/cromford" 2>/dev/null
[ -n "$A" ] && [ -n "$B" ] && [ -d "$T/repos/cromford/.git" ] || { echo "FAIL: fixture repo"; exit 1; }

# --- the fake gh ----------------------------------------------------------------
# Every call is one line in $HH/gh-calls.txt. `api` answers from $FX/<key>.json
# (<key> is the path minus repos/<R>/ and the query, / -> _, with -X POST
# prefixed `POST_`); `<key>.rc` overrides the exit code. --jq is applied with
# jq -r, as gh does. A `-F body=@<file>` is copied to $FX/body.<n>.md so the
# test reads exactly what was sent.
cat > "$STUB/gh" <<'SH'
#!/bin/bash
FX="$CNF_FX"
printf '%s\n' "$*" >> "$HARNESS/gh-calls.txt"
if [ "${1:-}" = workflow ]; then
  [ -f "$FX/workflow-run.rc" ] && exit "$(cat "$FX/workflow-run.rc")"
  exit 0
fi
[ "${1:-}" = api ] || exit 1
shift
P=""; Q=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    --jq|-q) Q="$2"; shift 2 ;;
    --paginate) shift ;;
    -f) shift 2 ;;
    -F) case "$2" in body=@*) n=$(ls "$FX"/body.*.md 2>/dev/null | wc -l); cp "${2#body=@}" "$FX/body.$((n+1)).md" ;; esac; shift 2 ;;
    *) P="$1"; shift ;;
  esac
done
K="${P#repos/example-org/cromford/}"
case "$K" in *labels=merge-queue*) K=mq ;; esac
K="${K%%\?*}"; K="${K//\//_}"
[ "$M" = POST ] && K="POST_$K"
[ -f "$FX/$K.rc" ] && { rc=$(cat "$FX/$K.rc"); [ "$rc" = 0 ] || exit "$rc"; }
F="$FX/$K.json"; [ -f "$F" ] || F="$FX/$K.txt"
[ -f "$F" ] || exit 1
if [ -n "$Q" ]; then jq -r "$Q" "$F"; else cat "$F"; fi
SH
chmod +x "$STUB/gh"

# The gh budget: a fresh cached rate_limit read for this token, so the REAL
# bin/lib/gh-budget.sh answers without a gh call. budget <remaining>.
# Stamped with the REAL clock, not $NOW: gh-budget.sh ages the cache against
# `date -u +%s`, so a pinned stamp goes stale an hour after the pinned instant.
FP=$(printf '%s' test-token-cnf | sha256sum | cut -c1-12)
budget() {
  jq -n --argjson n "$(date -u +%s)" --argjson r "$1" \
    '{fetched_at: $n, _threshold: 800, core: {remaining: $r, limit: 5000, reset: ($n + 3600)}, graphql: {remaining: $r, limit: 5000, reset: ($n + 3600)}}' \
    > "$HH/state/gh-budget/$FP.json"
}

healthy_fx() { # the fixtures of a quiet main: nothing queued, B is the tip
  rm -f "$FX"/*
  echo '[]' > "$FX/mq.json"
  printf '{"sha":"%s"}\n' "$B" > "$FX/commits_main.json"
  printf '{"workflow_runs":[{"id":902,"head_sha":"%s","created_at":"2026-10-07T03:20:09Z"},{"id":901,"head_sha":"%s","created_at":"2026-10-07T03:20:04Z"},{"id":800,"head_sha":"%s","created_at":"2026-10-06T03:17:00Z"}]}\n' "$B" "$B" "$B" \
    > "$FX/actions_workflows_harness-ci.yml_runs.json"
}
reset() {
  scratch_rm "$S"; scratch_rm "$HH/flags"; scratch_rm "$HH/logs"; rm -f "$HH/gh-calls.txt"
  mkdir -p "$HH/flags" "$HH/logs" "$S"
  budget 5000
  healthy_fx
}
drive() { # drive <subcommand> [VAR=VAL ...]
  local sub="$1"; shift
  ( export HARNESS="$HH" NOW REPOS_ROOT="$T/repos" GH_TOKEN=test-token-cnf GH_BUDGET_TTL_S=3600 GH_BUDGET_DB=0 \
           CNF_FX="$FX" CNF_POLL_SLEEP=0 HARNESS_TEST_SANDBOX=1 JOBS_URL= PATH="$STUB:$PATH"
    unset CI_NIGHTLY_FULL_HOUR CI_NIGHTLY_FULL_LOOKBACK_DAYS CI_NIGHTLY_FULL_MAX_LOGS
    # BH-6838: dispatch is off unless the knob is 1; these cases pin the
    # dispatch path itself, so it is on (the off case is in
    # tests/nightly-ticket-split.bh-6838-test.sh, N6).
    export CI_NIGHTLY_FULL_DISPATCH=1
    while [ $# -gt 0 ]; do export "${1?}"; shift; done
    timeout 120 bash "$HH/bin/ci-nightly-full.sh" "$sub" ) >"$T/out.txt" 2>&1
  echo $? > "$T/rc.txt"
}
calls() { if [ -f "$HH/gh-calls.txt" ]; then grep -c "${1:-.}" "$HH/gh-calls.txt"; else echo 0; fi; }
LOG="$HH/logs/ci-nightly-full.log"
lastlog() { tail -1 "$LOG" 2>/dev/null; }
alerts() { if [ -f "$HH/logs/ALERTS.log" ]; then grep -c 'ci-nightly-full' "$HH/logs/ALERTS.log"; else echo 0; fi; }

# ── dispatch ─────────────────────────────────────────────────────────────────
# D1 automerge disabled
reset; touch "$HH/flags/automerge-disabled"
drive dispatch
[ "$(calls 'workflow run')" = 0 ] && [ ! -e "$S/$TODAY/run.json" ] && grep -q 'dispatch: skip automerge-disabled' "$LOG" 2>/dev/null \
  && ok || bad "D1 automerge-disabled must skip with a logged reason ($(calls 'workflow run') runs; log: $(lastlog))"

# D2 a merge-queue PR open
reset; echo '[{"number":12,"pull_request":{"url":"x"}},{"number":13}]' > "$FX/mq.json"
drive dispatch
[ "$(calls 'workflow run')" = 0 ] && grep -q 'dispatch: skip merge-armed (1 open PR(s) labelled merge-queue)' "$LOG" 2>/dev/null \
  && [ ! -d "$S/$TODAY" ] && ok || bad "D2 an open merge-queue PR must skip ($(calls 'workflow run') runs; log: $(lastlog))"
# D2b the read fails: armed until proven otherwise
reset; echo 1 > "$FX/mq.rc"
drive dispatch
[ "$(calls 'workflow run')" = 0 ] && grep -q 'dispatch: skip merge-armed-unknown' "$LOG" 2>/dev/null \
  && ok || bad "D2b a failed merge-queue read must not dispatch ($(calls 'workflow run') runs; log: $(lastlog))"
echo 75 > "$FX/mq.rc"
drive dispatch
[ "$(calls 'workflow run')" = 0 ] && ok || bad "D2b a rate-limited (75) merge-queue read must not dispatch"

# D4 clean
reset
drive dispatch
W=$(grep -c "^workflow run harness-ci.yml --ref main -R $R\$" "$HH/gh-calls.txt" 2>/dev/null)
J="$S/$TODAY/run.json"
[ "$W" = 1 ] && [ "$(calls 'workflow run')" = 1 ] && ok || bad "D4 exactly one 'workflow run harness-ci.yml --ref main -R $R' (got: $(grep workflow "$HH/gh-calls.txt" 2>/dev/null))"
[ "$(jq -r .date "$J" 2>/dev/null)" = "$TODAY" ] && [ "$(jq -r .sha "$J" 2>/dev/null)" = "$B" ] \
  && [ "$(jq -r .dispatched_at "$J" 2>/dev/null)" = 2026-10-07T03:20:00Z ] && [ "$(jq -r .run_id "$J" 2>/dev/null)" = 901 ] \
  && ok || bad "D4 run.json must carry date, sha, dispatched_at and the OLDEST matching run id 901: $(cat "$J" 2>/dev/null)"
grep -q "dispatch: dispatched sha=$B run_id=901" "$LOG" 2>/dev/null && ok || bad "D4 the log line names the dispatch: $(lastlog)"
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "D4 a clean dispatch exits 0 (rc $(cat "$T/rc.txt"))"

# D3 a second tick the same date: no second run
drive dispatch
[ "$(calls 'workflow run')" = 1 ] && grep -q "dispatch: skip already-dispatched $TODAY" "$LOG" \
  && ok || bad "D3 a second same-date dispatch must not run again ($(calls 'workflow run') runs; log: $(lastlog))"
# ...and a run nobody can see yet still counts as dispatched
reset; echo '{"workflow_runs":[]}' > "$FX/actions_workflows_harness-ci.yml_runs.json"
drive dispatch
[ "$(jq -r .run_id "$J" 2>/dev/null)" = null ] && grep -q 'run_id=pending' "$LOG" && [ "$(calls 'actions/workflows')" = 3 ] \
  && ok || bad "D4 an unresolved run id is null after 3 bounded reads ($(calls 'actions/workflows') reads): $(cat "$J" 2>/dev/null)"
drive dispatch
[ "$(calls 'workflow run')" = 1 ] && ok || bad "D3 a dispatched-but-unresolved date is never re-dispatched"

# D5 workflow run rc 75: the claim goes, one ALERTS line, the next tick retries
reset; echo 75 > "$FX/workflow-run.rc"
drive dispatch
[ ! -e "$S/$TODAY" ] && [ "$(alerts)" = 1 ] && grep -q 'dispatch failed rc=75' "$HH/logs/ALERTS.log" \
  && [ "$(cat "$T/rc.txt")" = 1 ] && ok || bad "D5 rc 75 must remove the claim and write one ALERTS line (dir: $(ls "$S" 2>/dev/null); alerts $(alerts); rc $(cat "$T/rc.txt"))"
drive dispatch
[ "$(alerts)" = 1 ] && ok || bad "D5 the dispatch ALERTS line is once per date ($(alerts))"
rm -f "$FX/workflow-run.rc"
drive dispatch
[ "$(jq -r .run_id "$J" 2>/dev/null)" = 901 ] && ok || bad "D5 the next healthy tick dispatches: $(cat "$J" 2>/dev/null); log $(lastlog)"
# a bad sha is a failure too, never a dispatch
reset; echo '{"sha":"nope"}' > "$FX/commits_main.json"
drive dispatch
[ "$(calls 'workflow run')" = 0 ] && [ ! -e "$S/$TODAY" ] && [ "$(alerts)" = 1 ] && ok || bad "D5 an unreadable main sha must not dispatch and must alert"

# D6 before the hour
reset
drive dispatch NOW=$((NOW - 3600))
[ "$(calls)" = 0 ] && grep -q 'dispatch: skip before-hour' "$LOG" && ok || bad "D6 02:20 with the knob at 3 makes no gh call ($(calls)); log $(lastlog)"
drive dispatch NOW=$((NOW - 3600)) CI_NIGHTLY_FULL_HOUR=2
[ "$(calls 'workflow run')" = 1 ] && ok || bad "D6 the knob moves the hour: 02:20 with CI_NIGHTLY_FULL_HOUR=2 dispatches"

# D7 a claim left with no run.json: held while fresh, reclaimed when stale
reset; mkdir -p "$S/$TODAY"; touch -d "@$((NOW - 60))" "$S/$TODAY"
drive dispatch
[ "$(calls 'workflow run')" = 0 ] && grep -q 'dispatch: skip claim-held' "$LOG" && ok || bad "D7 a fresh claim is held ($(lastlog))"
touch -d "@$((NOW - 1200))" "$S/$TODAY"
drive dispatch
[ "$(calls 'workflow run')" = 1 ] && [ -f "$J" ] && ok || bad "D7 a claim older than 10 min with no run.json is reclaimed ($(lastlog))"

# ── kill flag and budget ────────────────────────────────────────────────────
seed() { # seed <date> <sha> <run_id|null> [dispatched_at]
  mkdir -p "$S/$1"
  jq -n --arg d "$1" --arg s "$2" --argjson r "$3" --arg t "${4:-${1}T03:17:00Z}" \
    '{date: $d, sha: $s, dispatched_at: $t, run_id: $r}' > "$S/$1/run.json"
}
reset; touch "$HH/flags/lane-off-ci-nightly-full"; seed "$TODAY" "$B" 901
drive dispatch; drive collect
[ "$(calls)" = 0 ] && ok || bad "K1 the kill flag stops both subcommands before any gh call ($(calls))"

reset; budget 10; seed 2026-10-06 "$B" 901
drive dispatch
[ "$(calls)" = 0 ] && grep -q 'dispatch: skip gh-budget-low' "$LOG" && ok || bad "B1 a low budget skips dispatch with no gh call ($(calls)); log $(lastlog)"
drive collect
[ "$(calls)" = 0 ] && grep -q 'collect: skip gh-budget-low' "$LOG" && [ ! -e "$S/2026-10-06/done" ] \
  && ok || bad "B1 a low budget skips collect with no gh call ($(calls)); log $(lastlog)"

# ── collect ─────────────────────────────────────────────────────────────────
run_fx() { # run_fx <id> <status> <conclusion>
  jq -n --argjson i "$1" --arg s "$2" --arg c "$3" \
    '{id: $i, status: $s, conclusion: (if $c == "" then null else $c end), html_url: "https://github.com/example-org/cromford/actions/runs/\($i)"}' \
    > "$FX/actions_runs_$1.json"
}
red_fx() { # the red run 901's jobs and the failed shard's log
  run_fx 901 completed failure
  cat > "$FX/actions_runs_901_jobs.json" <<'JSON'
{"jobs":[{"id":77,"name":"Tests, traced (shard 0/4)","conclusion":"failure"},
         {"id":78,"name":"Tests, traced (shard 1/4)","conclusion":"success"},
         {"id":79,"name":"Syntax + shellcheck + config integrity","conclusion":"failure"}]}
JSON
  printf '2026-10-07T03:40:00.0000000Z --- tests/ok-test.sh rc=0 1s\n2026-10-07T03:40:00.0000000Z --- tests/x-test.sh rc=1 4s\n2026-10-07T03:40:01.0000000Z boom\n' > "$FX/actions_jobs_77_logs.txt"
  echo '[]' > "$FX/issues.json"
  echo '{"number":4999,"html_url":"https://github.com/example-org/cromford/issues/4999","labels":[{"name":"ai-build"}]}' > "$FX/POST_issues.json"
}
creates() { calls '^api -X POST repos/example-org/cromford/issues -f'; }
issuecalls() { calls '/issues'; }

# C1 in progress
reset; seed "$TODAY" "$B" 901; run_fx 901 in_progress ""
drive collect
[ "$(issuecalls)" = 0 ] && [ ! -e "$S/$TODAY/done" ] && grep -q "collect $TODAY: pending" "$LOG" \
  && ok || bad "C1 an in-progress run files nothing and is not done ($(issuecalls) issue calls; $(lastlog))"

# C2 green
reset; seed "$TODAY" "$A" 901; run_fx 901 completed success
drive collect
[ "$(cat "$S/last_green_sha" 2>/dev/null)" = "$A" ] && [ -e "$S/$TODAY/done" ] && [ "$(issuecalls)" = 0 ] \
  && grep -q "collect $TODAY: green sha=$A" "$LOG" && ok || bad "C2 a green run records last_green_sha=$A ($(cat "$S/last_green_sha" 2>/dev/null)); $(lastlog)"
drive collect
[ "$(calls 'actions/runs')" = 1 ] && ok || bad "C2 a done date is never read again ($(calls 'actions/runs') run reads)"

# C3 red, last green A is an ancestor: range A..B, x-test.sh fails, bin/b.sh missed
reset; echo "$A" > "$S/last_green_sha"; seed "$TODAY" "$B" 901; red_fx
drive collect
BODY="$FX/body.1.md"
[ "$(creates)" = 1 ] && grep -q "labels\[\]=ai-build" "$HH/gh-calls.txt" && ok || bad "C3 exactly one create labelled ai-build ($(creates)): $(cat "$HH/gh-calls.txt")"
grep -qF '<!-- harness-full-red -->' "$BODY" 2>/dev/null && grep -qF 'tests/x-test.sh' "$BODY" \
  && grep -qF 'Fix the map (bin/test-impact.sh / catalog), not the selection rule.' "$BODY" \
  && ok || bad "C3 the body carries the marker, the suite and the closing line: $(cat "$BODY" 2>/dev/null)"
L=$(grep -F '`tests/x-test.sh` (rc 1)' "$BODY" 2>/dev/null)
grep -qF 'missed: `bin/b.sh`' <<<"$L" && ! grep -qF 'bin/a.sh' <<<"$L" \
  && ok || bad "C3 bin/b.sh is missed, bin/a.sh (which selects the suite) is not: '$L'"
grep -qF 'tests/ok-test.sh' "$BODY" && bad "C3 a suite with rc=0 is not a failed suite" || ok
grep -qF "${A:0:12}..${B:0:12}" "$BODY" && ok || bad "C3 the body names the range last_green..sha: $(grep -i range "$BODY")"
[ "$(cat "$S/$TODAY/ticketed" 2>/dev/null)" = https://github.com/example-org/cromford/issues/4999 ] && [ -e "$S/$TODAY/done" ] \
  && ok || bad "C3 ticketed holds the URL gh returned and the date is done"
grep -q "collect $TODAY: red ticketed #4999" "$LOG" && ok || bad "C3 log line: $(lastlog)"
[ "$(calls '/labels')" = 0 ] && ok || bad "C3 a label that stuck is not re-added"
[ "$(calls 'actions/jobs/79/logs')" = 0 ] && ok || bad "C3 only shard jobs' logs are read"
drive collect
[ "$(creates)" = 1 ] && ok || bad "C3 one red files once ($(creates) creates)"
# a create whose label GitHub dropped gets it added once
reset; echo "$A" > "$S/last_green_sha"; seed "$TODAY" "$B" 901; red_fx
echo '{"number":4999,"html_url":"https://github.com/example-org/cromford/issues/4999","labels":[]}' > "$FX/POST_issues.json"
echo '{}' > "$FX/POST_issues_4999_labels.json"
drive collect
[ "$(calls 'issues/4999/labels')" = 1 ] && [ -e "$S/$TODAY/ticketed" ] && ok || bad "C3 a dropped ai-build label is added back once ($(calls 'issues/4999/labels'))"

# C4 a second red date with the marker issue open: comment, never create, never label
reset; echo "$A" > "$S/last_green_sha"; seed 2026-10-06 "$B" 901; red_fx
echo '[{"number":4999,"body":"<!-- harness-full-red -->\nold"},{"number":5000,"body":"other","pull_request":{}}]' > "$FX/issues.json"
echo '{"html_url":"https://github.com/example-org/cromford/issues/4999#issuecomment-1"}' > "$FX/POST_issues_4999_comments.json"
drive collect
[ "$(calls 'POST repos/example-org/cromford/issues/4999/comments')" = 1 ] && [ "$(creates)" = 0 ] && [ "$(calls '/labels')" = 0 ] \
  && ok || bad "C4 one comment, zero creates, zero /labels: $(cat "$HH/gh-calls.txt")"
grep -q 'paginate' <<<"$(grep 'issues?state=open&per_page' "$HH/gh-calls.txt")" && ok || bad "C4 the open-issue lookup reads every page"
[ -e "$S/2026-10-06/ticketed" ] && [ -e "$S/2026-10-06/done" ] && ok || bad "C4 the comment marks the date ticketed and done"

# C5 the create fails: nothing marked, one ALERTS line; the next collect files
reset; echo "$A" > "$S/last_green_sha"; seed "$TODAY" "$B" 901; red_fx; echo 1 > "$FX/POST_issues.rc"
drive collect
[ ! -e "$S/$TODAY/ticketed" ] && [ ! -e "$S/$TODAY/done" ] && [ "$(alerts)" = 1 ] && grep -q "collect $TODAY: red filing-failed" "$LOG" \
  && ok || bad "C5 a failed create leaves no ticketed/done and one ALERTS line (alerts $(alerts); $(lastlog))"
drive collect
[ "$(alerts)" = 1 ] && ok || bad "C5 the filing ALERTS line is once per date ($(alerts))"
rm -f "$FX/POST_issues.rc"; N0=$(creates)
drive collect
[ "$(( $(creates) - N0 ))" = 1 ] && [ -e "$S/$TODAY/ticketed" ] && [ -e "$S/$TODAY/done" ] \
  && ok || bad "C5 the next healthy collect creates once and writes ticketed"

# C6 no recorded green run: the fallback range is said
reset; seed "$TODAY" "$B" 901; red_fx
drive collect
BODY="$FX/body.1.md"
grep -qF 'sha~20' "$BODY" 2>/dev/null && grep -qF 'no recorded green run' "$BODY" && ok || bad "C6 no last_green_sha: the body says sha~20 and why: $(grep -i range "$BODY" 2>/dev/null)"
# a last green that is not an ancestor says that instead
reset; echo 0123456789012345678901234567890123456789 > "$S/last_green_sha"; seed "$TODAY" "$B" 901; red_fx
drive collect
grep -qF 'is not an ancestor' "$FX/body.1.md" 2>/dev/null && ok || bad "C6 a non-ancestor last green is named"

# C7 cancelled: not a red
reset; seed "$TODAY" "$B" 901; run_fx 901 completed cancelled
drive collect
[ "$(issuecalls)" = 0 ] && [ -e "$S/$TODAY/done" ] && [ ! -e "$S/last_green_sha" ] && grep -q "collect $TODAY: cancelled" "$LOG" \
  && ok || bad "C7 a cancelled run files nothing, records no green, and is done ($(issuecalls); $(lastlog))"

# C8 the open-issue list fails: never create blind
reset; echo "$A" > "$S/last_green_sha"; seed "$TODAY" "$B" 901; red_fx; echo 1 > "$FX/issues.rc"
drive collect
[ "$(creates)" = 0 ] && [ ! -e "$S/$TODAY/done" ] && [ "$(alerts)" = 1 ] && ok || bad "C8 a failed open-issue read creates nothing ($(creates) creates)"

# C9 an unresolved run id resolves in collect; one lost past 6h alerts once
reset; seed "$TODAY" "$B" null 2026-10-07T03:20:00Z; run_fx 901 completed success
drive collect
[ "$(jq -r .run_id "$S/$TODAY/run.json")" = 901 ] && [ -e "$S/$TODAY/done" ] && ok || bad "C9 collect resolves a null run id: $(cat "$S/$TODAY/run.json")"
reset; seed 2026-10-06 "$B" null 2026-10-06T03:17:00Z; echo '{"workflow_runs":[]}' > "$FX/actions_workflows_harness-ci.yml_runs.json"
drive collect
[ -e "$S/2026-10-06/lost" ] && [ "$(alerts)" = 1 ] && ok || bad "C9 a run not found after 6h is lost with one ALERTS line ($(alerts))"

echo "ci-nightly-full.bh-4964-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
