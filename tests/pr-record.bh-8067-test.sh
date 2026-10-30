#!/bin/bash
# tests/pr-record.bh-8067-test.sh — BH-8067 (C0): the fleet's own PR record.
# bin/lib/pr-record.sh (pr_record_put, pr_record_get) and the PR-open write in
# bin/lib/gh-pr-create.sh, driven over real curl against the REAL jobs worker
# (tests/lib/gh-budget-worker.bh-6974.mjs, worker clock pinned to NOW) and a
# stub `gh` first on PATH that logs every call. GitHub REST answers use the
# tests/lib/gh-rest-stub.sh envelope; a case that needs PR fields the shared
# stub does not carry writes $GHT/pr-<n>.json.
#
#   A1  gh_pr_create_ladder opens a PR: stdout is the URL, rc 0; then
#       pr_record_get gives the branch's head sha and state open, 0 GitHub reads
#   A2  a fresh row with head_sha: 0 GitHub reads
#   A3  an unknown PR: 1 read, the record is written (last_source github);
#       a second get: 0 more reads
#   A4  a row 901 s old: 1 read; 899 s old: 0 reads
#   A5  head_sha null and asked: 1 read; checks null and asked: 0 reads; an
#       unasked null base_sha: 0 reads
#   A6  the record write fails (JOBS_URL empty): the ladder still prints the
#       URL, rc 0, and the pipeline log names the failed write
#   A7  the log line of a read: reason=unknown gh_rc=0 put=ok
#   A8  the worker refuses the PUT: put=failed, the GitHub values print, rc 0
#   A9  PR_RECORD_MAX_AGE_S=0: 1 read on a fresh row; =abc: read as 900, one
#       log line names abc
#   A10 GitHub 404: rc 44, nothing printed, no row; GitHub 403: rc 75,
#       nothing printed, the stale row unchanged
#   A11 an unknown field (logs): rc 2, 0 GitHub reads, 0 worker requests
#   A12 merged_at set -> state merged; closed unmerged -> closed
#   A14 BH-8735: PR_RECORD_FRESH=1 on a fresh `open` row: 1 read, reason=fresh,
#       the GitHub `merged` replaces it with last_source github; unset: 0 reads
#   A13 the repo spelled with capitals finds the lowercased row, 0 reads
#   B1  budget: 0 calls to a real host (JOBS_URL is 127.0.0.1, gh is the stub)
#
# Run from anywhere: tests/pr-record.bh-8067-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/gh-budget-worker.bh-6974.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
eqn() { if [ -n "$2" ] && [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or git missing"; exit 0; }
# The worker imports these git-ignored renders; a fresh checkout has none.
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$REPO/bin/context-budgets-build.sh" --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/flags"
for L in bin/lib/gh-pr-create.sh bin/lib/pr-record.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
[ -r "$H/bin/lib/pr-record.sh" ] && ok "the closure of bin/lib/gh-pr-create.sh carries bin/lib/pr-record.sh" \
  || bad "the closure of bin/lib/gh-pr-create.sh lacks bin/lib/pr-record.sh"

NOW=$(date -u +%s)
export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-box
export JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR PR_RECORD_MAX_AGE_S
printf 'HARNESS_SECRET=fixture-harness-secret\n' > "$H/env/global.env"

# ---- the stub gh ---------------------------------------------------------------
GHT="$T/ghfx"; mkdir -p "$GHT" "$T/bin"; export GHT
cat > "$T/bin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in
  "pr create"*) cat "$GHT/create-url" 2>/dev/null; exit 0 ;;
  *"-i -X GET"*"/pulls/"*)
    a="\$*"; n=\${a##*/pulls/}; n=\${n%% *}
    if [ -f "$GHT/pr-\$n.json" ]; then printf 'HTTP/2 200\r\nserver: x\r\n\r\n%s' "\$(cat "$GHT/pr-\$n.json")"; exit 0; fi ;;
esac
case "\$*" in
  *"-i -X "*) . "$REPO/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH"

# ---- the worker ----------------------------------------------------------------
: > "$T/w.log"
node "$SRV" "$T/w.log" "$NOW" > "$T/w.port" 2> "$T/w.err" &
WPID=$!
trap 'kill $WPID 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port" 2>/dev/null)
if [ -z "$PORT" ]; then
  wait "$WPID"; rc=$?
  [ "$rc" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/w.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
row() { curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/pr-records?repo=$1&number=$2" | jq -c '.row'; }
iso() { date -u -d "@$((NOW - $1))" +%Y-%m-%dT%H:%M:%SZ; }
age() { sql "UPDATE pr_records SET refreshed_at = ? WHERE repo = ? AND number = ?" "$(iso "$3")" "$1" "$2" >/dev/null; }
reads() { grep -c -- "/pulls/$1" "$T/gh.log" 2>/dev/null || true; }
LOG="$H/logs/pr-record.log"

# get <repo> <n> [field...] -> stdout to $T/out, rc to $T/rc, in a fresh shell
get() {
  ( . "$H/bin/lib/pr-record.sh"; pr_record_get "$@" ) > "$T/out" 2>"$T/err"; echo $? > "$T/rc"
}
put() { ( . "$H/bin/lib/pr-record.sh"; pr_record_put "$@" ) >/dev/null 2>&1; }
SHA_A=$(printf 'a%.0s' $(seq 40)); SHA_B=$(printf 'b%.0s' $(seq 40)); SHA_C=$(printf 'c%.0s' $(seq 40))
printf '%s' "$SHA_C" > "$GHT/prhead"; printf 'ticket/fixture' > "$GHT/prbranch"

# ---- A1: the ladder writes the record at PR open --------------------------------
GR="$T/repo"; mkdir -p "$GR"
( cd "$GR" && git init -q -b main && git -c user.email=f@fixture.invalid -c user.name=fixture commit -q --allow-empty -m init \
  && git checkout -q -b ticket/a1 && git -c user.email=f@fixture.invalid -c user.name=fixture commit -q --allow-empty -m a1 )
BR_SHA=$(git -C "$GR" rev-parse ticket/a1)
printf 'https://github.com/fixture-org/fixture-a1/pull/101\n' > "$GHT/create-url"
printf 'body\n' > "$T/body.md"
: > "$T/gh.log"
( cd "$GR" && . "$H/bin/lib/gh-pr-create.sh" && gh_pr_create_ladder fixture-org/fixture-a1 ticket/a1 main "BH: a1" "$T/body.md" "$T/a1.err" "$T/a1.plog" a1 ) > "$T/a1.out"
eq "A1 the ladder rc is 0" "$?" 0
eq "A1 stdout is exactly the URL" "$(cat "$T/a1.out")" "https://github.com/fixture-org/fixture-a1/pull/101"
get fixture-org/fixture-a1 101
eq "A1 pr_record_get rc 0" "$(cat "$T/rc")" 0
eqn "A1 the record's head_sha is the branch sha" "$(jq -r '.head_sha' "$T/out")" "$BR_SHA"
eq "A1 the record says open" "$(jq -r '.state' "$T/out")" open
eq "A1 head_ref and base_ref" "$(jq -r '[.head_ref,.base_ref]|join(" ")' "$T/out")" "ticket/a1 main"
eq "A1 last_source fleet" "$(jq -r '.last_source' "$T/out")" fleet
eq "A1 0 GitHub api calls after the create" "$(grep -c '^api' "$T/gh.log")" 0
eq "A1 gh was called once (the create)" "$(grep -c '^pr create' "$T/gh.log")" 1

# ---- A2: a fresh row is served from the record ---------------------------------
put fixture-org/fixture-a2 102 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "A2 setup put"
: > "$T/gh.log"
get fixture-org/fixture-a2 102 head_sha
eq "A2 rc 0" "$(cat "$T/rc")" 0
eq "A2 the stored head_sha" "$(jq -r '.head_sha' "$T/out")" "$SHA_A"
eq "A2 0 GitHub reads" "$(reads 102)" 0

# ---- A3 + A7: an unknown PR is read once, then served -------------------------
: > "$T/gh.log"; : > "$LOG"
get fixture-org/fixture-a3 103
eq "A3 rc 0" "$(cat "$T/rc")" 0
eq "A3 exactly 1 GitHub read" "$(reads 103)" 1
eq "A3 the printed row carries the GitHub head sha" "$(jq -r '.head_sha' "$T/out")" "$SHA_C"
eq "A3 the record exists with last_source github" "$(row fixture-org/fixture-a3 103 | jq -r '.last_source')" github
eq "A3 gh_read_at is set" "$(row fixture-org/fixture-a3 103 | jq -r '.gh_read_at')" "$(iso 0)"
get fixture-org/fixture-a3 103
eq "A3 a second get: no more reads" "$(reads 103)" 1
eq "A3 the second get prints the row" "$(jq -r '.head_sha' "$T/out")" "$SHA_C"
eq "A7 one log line for the one read" "$(grep -c 'get fixture-org/fixture-a3#103' "$LOG")" 1
grep -q 'get fixture-org/fixture-a3#103 reason=unknown gh_rc=0 put=ok$' "$LOG" \
  && ok "A7 the line says reason=unknown gh_rc=0 put=ok" || bad "A7 log line: $(cat "$LOG")"

# ---- A4: the max-age backstop, 901 s and 899 s ------------------------------
put fixture-org/fixture-a4 104 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "A4 setup put"
put fixture-org/fixture-a4 105 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "A4 setup put"
age fixture-org/fixture-a4 104 901; age fixture-org/fixture-a4 105 899
: > "$T/gh.log"; : > "$LOG"
get fixture-org/fixture-a4 104
eq "A4 901 s old: 1 read" "$(reads 104)" 1
eq "A4 901 s old: the GitHub value replaced the stored one" "$(jq -r '.head_sha' "$T/out")" "$SHA_C"
grep -q 'fixture-a4#104 reason=stale gh_rc=0 put=ok' "$LOG" && ok "A4 the read's reason is stale" || bad "A4 log: $(cat "$LOG")"
get fixture-org/fixture-a4 105
eq "A4 899 s old: 0 reads" "$(reads 105)" 0
eq "A4 899 s old: the stored value" "$(jq -r '.head_sha' "$T/out")" "$SHA_A"

# ---- A5: a null field asked for, a null field the read never fills ----------
put fixture-org/fixture-a5 106 fleet '{"state":"open"}' || bad "A5 setup put"
put fixture-org/fixture-a5 107 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "A5 setup put"
: > "$T/gh.log"; : > "$LOG"
get fixture-org/fixture-a5 106 head_sha
eq "A5 head_sha null and asked: 1 read" "$(reads 106)" 1
grep -q 'fixture-a5#106 reason=field:head_sha ' "$LOG" && ok "A5 the reason is field:head_sha" || bad "A5 log: $(cat "$LOG")"
get fixture-org/fixture-a5 107 head_sha checks
eq "A5 checks null and asked: 0 reads" "$(reads 107)" 0
eq "A5 checks is null in the printed row" "$(jq -r '.checks' "$T/out")" null
get fixture-org/fixture-a5 107
eq "A5 an unasked null base_sha: 0 reads" "$(reads 107)" 0

# ---- A6: a failed record write never changes the ladder ---------------------
printf 'https://github.com/fixture-org/fixture-a6/pull/108\n' > "$GHT/create-url"
( cd "$GR" && JOBS_URL="" && . "$H/bin/lib/gh-pr-create.sh" \
  && gh_pr_create_ladder fixture-org/fixture-a6 ticket/a1 main "BH: a6" "$T/body.md" "$T/a6.err" "$T/a6.plog" a6 ) > "$T/a6.out"
eq "A6 the ladder rc is 0" "$?" 0
eq "A6 stdout is exactly the URL" "$(cat "$T/a6.out")" "https://github.com/fixture-org/fixture-a6/pull/108"
grep -q '\[a6\] pr record: write failed for fixture-org/fixture-a6#108' "$T/a6.plog" \
  && ok "A6 the pipeline log names the failed write" || bad "A6 plog: $(cat "$T/a6.plog" 2>/dev/null)"
eq "A6 no record was written" "$(row fixture-org/fixture-a6 108)" null

# ---- A8: the worker refuses the PUT --------------------------------------------
jq -nc --arg s "$SHA_B" '{state:"open",merged_at:null,head:{sha:$s,ref:"ticket/a8"},base:{ref:"main"},mergeable_state:"NOT-A-WORD"}' > "$GHT/pr-109.json"
: > "$T/gh.log"; : > "$LOG"
get fixture-org/fixture-a8 109
eq "A8 rc 0" "$(cat "$T/rc")" 0
eq "A8 the GitHub head sha prints" "$(jq -r '.head_sha' "$T/out")" "$SHA_B"
grep -q 'fixture-a8#109 reason=unknown gh_rc=0 put=failed$' "$LOG" && ok "A8 the log says put=failed" || bad "A8 log: $(cat "$LOG")"
eq "A8 no record was written" "$(row fixture-org/fixture-a8 109)" null

# ---- A9: the knob ---------------------------------------------------------------
put fixture-org/fixture-a9 110 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "A9 setup put"
: > "$T/gh.log"; : > "$LOG"
PR_RECORD_MAX_AGE_S=0 get fixture-org/fixture-a9 110
eq "A9 max age 0: 1 read on a fresh row" "$(reads 110)" 1
put fixture-org/fixture-a9 111 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "A9 setup put"
PR_RECORD_MAX_AGE_S=abc get fixture-org/fixture-a9 111
eq "A9 max age abc: read as 900, 0 reads on a fresh row" "$(reads 111)" 0
eq "A9 one log line names abc" "$(grep -c "PR_RECORD_MAX_AGE_S='abc'" "$LOG")" 1
age fixture-org/fixture-a9 111 901
PR_RECORD_MAX_AGE_S=abc get fixture-org/fixture-a9 111
eq "A9 max age abc: a 901 s row is read (900 applies)" "$(reads 111)" 1

# ---- A10: GitHub absent and GitHub silent ---------------------------------------
: > "$T/gh.log"; : > "$LOG"
printf '404' > "$GHT/st-pr"
get fixture-org/fixture-a10 112
eq "A10 404: rc 44" "$(cat "$T/rc")" 44
eq "A10 404: nothing printed" "$(cat "$T/out")" ""
eq "A10 404: no row" "$(row fixture-org/fixture-a10 112)" null
grep -q 'fixture-a10#112 reason=unknown gh_rc=44 put=skipped$' "$LOG" && ok "A10 404 log line" || bad "A10 log: $(cat "$LOG")"
put fixture-org/fixture-a10 113 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "A10 setup put"
age fixture-org/fixture-a10 113 1000
BEFORE=$(row fixture-org/fixture-a10 113)
printf '403' > "$GHT/st-pr"
get fixture-org/fixture-a10 113
eq "A10 403: rc 75" "$(cat "$T/rc")" 75
eq "A10 403: nothing printed (the stale row is not served)" "$(cat "$T/out")" ""
eq "A10 403: the row is unchanged" "$(row fixture-org/fixture-a10 113)" "$BEFORE"
rm -f "$GHT/st-pr"

# ---- A11: an unknown field ------------------------------------------------------
: > "$T/gh.log"; W0=$(wc -l < "$T/w.log")
get fixture-org/fixture-a2 102 logs
eq "A11 rc 2" "$(cat "$T/rc")" 2
eq "A11 0 GitHub calls" "$(wc -l < "$T/gh.log" | tr -d ' ')" 0
eq "A11 0 worker requests" "$(wc -l < "$T/w.log")" "$W0"
get fixture-org/fixture-a2 0
eq "A11 number 0: rc 2" "$(cat "$T/rc")" 2

# ---- A12: merged and closed -----------------------------------------------------
jq -nc --arg s "$SHA_B" '{state:"closed",merged_at:"2026-10-20T00:00:00Z",draft:false,head:{sha:$s,ref:"t/m"},base:{ref:"main",sha:$s},labels:[{name:"ai-build"}]}' > "$GHT/pr-114.json"
jq -nc --arg s "$SHA_B" '{state:"closed",merged_at:null,head:{sha:$s,ref:"t/c"},base:{ref:"main"}}' > "$GHT/pr-115.json"
get fixture-org/fixture-a12 114
eq "A12 merged_at set: state merged" "$(jq -r '.state' "$T/out")" merged
eq "A12 labels mapped to names" "$(jq -c '.labels' "$T/out")" '["ai-build"]'
eq "A12 draft false stored as 0" "$(jq -r '.draft' "$T/out")" 0
eq "A12 base_sha from GitHub" "$(jq -r '.base_sha' "$T/out")" "$SHA_B"
get fixture-org/fixture-a12 115
eq "A12 closed unmerged: state closed" "$(jq -r '.state' "$T/out")" closed

# ---- A14: PR_RECORD_FRESH forces the read (BH-8735) ----------------------------
put fixture-org/fixture-a14 116 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "A14 setup put"
jq -nc --arg s "$SHA_A" '{state:"closed",merged_at:"2026-10-28T00:00:00Z",head:{sha:$s,ref:"t/f"},base:{ref:"main"}}' > "$GHT/pr-116.json"
: > "$T/gh.log"; : > "$LOG"
get fixture-org/fixture-a14 116 state
eq "A14 unset: 0 reads on a fresh row" "$(reads 116)" 0
eq "A14 unset: the stored open" "$(jq -r '.state' "$T/out")" open
PR_RECORD_FRESH=1 get fixture-org/fixture-a14 116 state
eq "A14 PR_RECORD_FRESH=1: 1 read" "$(reads 116)" 1
eq "A14 PR_RECORD_FRESH=1: rc 0" "$(cat "$T/rc")" 0
eq "A14 PR_RECORD_FRESH=1: GitHub's merged prints" "$(jq -r '.state' "$T/out")" merged
eq "A14 the record says merged, last_source github" "$(row fixture-org/fixture-a14 116 | jq -r '[.state,.last_source]|join(" ")')" "merged github"
grep -q 'fixture-a14#116 reason=fresh gh_rc=0 put=ok$' "$LOG" && ok "A14 the read's reason is fresh" || bad "A14 log: $(cat "$LOG")"

# ---- A13: case ------------------------------------------------------------------
: > "$T/gh.log"
get Fixture-Org/Fixture-A2 102
eq "A13 capitals: rc 0" "$(cat "$T/rc")" 0
eq "A13 capitals: the lowercased row" "$(jq -r '.head_sha' "$T/out")" "$SHA_A"
eq "A13 capitals: 0 reads" "$(wc -l < "$T/gh.log" | tr -d ' ')" 0

# ---- B1: budget -----------------------------------------------------------------
case "$JOBS_URL" in http://127.0.0.1:*) ok "B1 every worker request went to 127.0.0.1" ;; *) bad "B1 JOBS_URL is $JOBS_URL" ;; esac
eq "B1 gh resolves to the stub" "$(command -v gh)" "$T/bin/gh"

echo "pr-record.bh-8067: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
