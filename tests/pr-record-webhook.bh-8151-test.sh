#!/bin/bash
# tests/pr-record-webhook.bh-8151-test.sh — BH-8151 (BH-8067 slice C2): a
# signed GitHub delivery to POST /webhooks/github writes the fleet's PR record
# (worker/jobs/src/lib/pr-record-intake.js, called from
# worker/jobs/src/routes/webhooks.js), and bin/lib/pr-record.sh pr_record_get
# then serves it with no GitHub read. Case 2 of the read rule: a field a named
# change did not carry (a push to main nulls mergeable_state; GitHub's own
# mergeable_state "unknown") is stored NULL, and the next get that asks for it
# reads GitHub. Driven over real curl against the REAL jobs worker
# (tests/lib/pr-record-worker.bh-8151.mjs, clock pinned to NOW), HMAC from
# openssl, and a stub `gh` first on PATH that logs every call.
#
#   C1  a check_run.completed for PR 201 after a fleet PUT: pr_record_get
#       <repo> 201 checks prints the check (conclusion, sha), 0 gh calls
#   C2  a pull_request.opened for PR 202 (no row): pr_record_get prints
#       head_sha and state open, 0 gh calls
#   C3  mergeable_state known (clean), then a push to main: the next get of
#       mergeable_state makes 1 read, reason=field:mergeable_state
#   C4  GitHub answers mergeable_state "unknown": the get prints null and a
#       second get reads again; GitHub answers clean: the get prints clean and
#       a further get makes 0 reads; a stale stored clean that GitHub now
#       calls unknown becomes null
#   C5  a row 901 s old receives a check_run: the get still reads (reason=stale)
#   C6  a delivery with a bad signature: 401, no row
#   B1  budget: 0 calls to a real host (JOBS_URL is 127.0.0.1, gh is the stub)
#
# Run from anywhere: tests/pr-record-webhook.bh-8151-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/pr-record-worker.bh-8151.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or openssl missing"; exit 0; }
# The worker imports these git-ignored renders; a fresh checkout has none.
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$REPO/bin/context-budgets-build.sh" --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/flags"
for L in bin/lib/pr-record.sh bin/lib/gh-rest.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done

NOW=$(date -u +%s)
export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-box
export JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR PR_RECORD_MAX_AGE_S
printf 'HARNESS_SECRET=fixture-harness-secret\n' > "$H/env/global.env"
WH_SECRET=fixture-webhook-secret

# ---- the stub gh: answers GET repos/<r>/pulls/<n> from $GHT/pr-<n>.json --------
GHT="$T/ghfx"; mkdir -p "$GHT" "$T/bin"
cat > "$T/bin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in
  *"-i -X GET"*"/pulls/"*)
    a="\$*"; n=\${a##*/pulls/}; n=\${n%% *}
    if [ -f "$GHT/pr-\$n.json" ]; then printf 'HTTP/2 200\r\nserver: x\r\n\r\n%s' "\$(cat "$GHT/pr-\$n.json")"; exit 0; fi
    printf 'HTTP/2 404\r\nserver: x\r\n\r\n{"message":"Not Found"}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH"
: > "$T/gh.log"

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
reads() { grep -c -- "/pulls/$1" "$T/gh.log" 2>/dev/null || true; }
LOG="$H/logs/pr-record.log"
get() { ( . "$H/bin/lib/pr-record.sh"; pr_record_get "$@" ) > "$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
put() { ( . "$H/bin/lib/pr-record.sh"; pr_record_put "$@" ) >/dev/null 2>&1; }
# hook <event> <json> [signature] -> the HTTP status in $T/hook.code, the body in $T/hook.out
DN=0
hook() {
  local sig="${3:-}"
  DN=$((DN + 1))
  [ -n "$sig" ] || sig="sha256=$(printf '%s' "$2" | openssl dgst -sha256 -hmac "$WH_SECRET" | awk '{print $NF}')"
  curl -sS -o "$T/hook.out" -w '%{http_code}' -X POST "$JOBS_URL/webhooks/github" \
    -H "content-type: application/json" -H "x-github-event: $1" -H "x-github-delivery: dlv-bh8151-$DN" \
    -H "x-hub-signature-256: $sig" --data-binary "$2" > "$T/hook.code"
}
SHA_A=$(printf 'a%.0s' $(seq 40)); SHA_B=$(printf 'b%.0s' $(seq 40)); SHA_C=$(printf 'c%.0s' $(seq 40))
R=fixture-org/fixture-r
REPOJ='{"full_name":"fixture-org/fixture-r","default_branch":"main"}'
check_run() { # <pr> <completed_at>
  jq -nc --argjson r "$REPOJ" --arg s "$SHA_C" --arg at "$2" --argjson n "$1" \
    '{action:"completed", repository:$r, check_run:{name:"harness-ci", status:"completed", conclusion:"success", head_sha:$s,
      started_at:$at, completed_at:$at, pull_requests:[{number:$n}]}}'
}
gh_pr() { # <n> <mergeable_state>
  jq -nc --arg a "$SHA_A" --arg b "$SHA_B" --arg m "$2" \
    '{state:"open", merged_at:null, draft:false, head:{sha:$a, ref:"ticket/x"}, base:{sha:$b, ref:"main"}, mergeable_state:$m, labels:[]}' > "$GHT/pr-$1.json"
}

# ---- C1: a check_run webhook, then a get with no GitHub read --------------------
put "$R" 201 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_C\"}" || bad "C1 setup put"
hook check_run "$(check_run 201 "$(iso 30)")"
eq "C1 the receiver answers 200" "$(cat "$T/hook.code")" 200
: > "$T/gh.log"
get "$R" 201 checks
eq "C1 rc 0" "$(cat "$T/rc")" 0
eq "C1 the check's conclusion" "$(jq -r '.checks["harness-ci"].conclusion' "$T/out")" success
eq "C1 the check's sha" "$(jq -r '.checks["harness-ci"].sha' "$T/out")" "$SHA_C"
eq "C1 last_source webhook" "$(jq -r '.last_source' "$T/out")" webhook
eq "C1 0 gh calls" "$(wc -l < "$T/gh.log" | tr -d ' ')" 0

# ---- C2: a pull_request.opened creates the record --------------------------------
PRJ=$(jq -nc --argjson r "$REPOJ" --arg a "$SHA_A" --arg b "$SHA_B" --arg at "$(iso 60)" \
  '{action:"opened", number:202, repository:$r, pull_request:{number:202, state:"open", draft:false, merged_at:null, updated_at:$at,
    head:{ref:"ticket/c2", sha:$a}, base:{ref:"main", sha:$b}, labels:[{name:"ai-build"}]}}')
hook pull_request "$PRJ"
eq "C2 the receiver answers 200" "$(cat "$T/hook.code")" 200
eq "C2 the response keeps its keys" "$(jq -c 'keys' "$T/hook.out")" '["as_of","duplicate","ok","vendor","wake"]'
: > "$T/gh.log"
get "$R" 202
eq "C2 rc 0" "$(cat "$T/rc")" 0
eq "C2 head_sha from the payload" "$(jq -r '.head_sha' "$T/out")" "$SHA_A"
eq "C2 state open" "$(jq -r '.state' "$T/out")" open
eq "C2 0 gh calls" "$(wc -l < "$T/gh.log" | tr -d ' ')" 0

# ---- C3: a push to main makes mergeable_state unknown again ----------------------
: > "$LOG"
gh_pr 202 clean
get "$R" 202 mergeable_state
eq "C3 setup: opened carried no mergeable_state, so one read fills it" "$(reads 202)" 1
eq "C3 setup: clean stored" "$(row "$R" 202 | jq -r '.mergeable_state')" clean
get "$R" 202 mergeable_state
eq "C3 setup: a known value is served with no read" "$(reads 202)" 1
hook push "$(jq -nc --argjson r "$REPOJ" --arg a "$SHA_A" --arg b "$SHA_B" '{ref:"refs/heads/main", before:$a, after:$b, repository:$r}')"
eq "C3 the push answers 200" "$(cat "$T/hook.code")" 200
eq "C3 the push nulled mergeable_state" "$(row "$R" 202 | jq -r '.mergeable_state')" null
eq "C3 the push kept head_sha" "$(row "$R" 202 | jq -r '.head_sha')" "$SHA_A"
: > "$T/gh.log"; : > "$LOG"
get "$R" 202 mergeable_state
eq "C3 1 GitHub read after the push" "$(reads 202)" 1
grep -q "get $R#202 reason=field:mergeable_state gh_rc=0 put=ok" "$LOG" \
  && ok "C3 the reason is field:mergeable_state" || bad "C3 log: $(cat "$LOG")"

# ---- C4: GitHub's own "unknown" is stored as unknown -----------------------------
put "$R" 204 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "C4 setup put"
gh_pr 204 unknown
: > "$T/gh.log"; : > "$LOG"
get "$R" 204 mergeable_state
eq "C4 rc 0" "$(cat "$T/rc")" 0
eq "C4 unknown prints null" "$(jq -r '.mergeable_state' "$T/out")" null
eq "C4 the record holds null" "$(row "$R" 204 | jq -r '.mergeable_state')" null
eq "C4 1 read" "$(reads 204)" 1
grep -q "get $R#204 reason=field:mergeable_state gh_rc=0 put=ok" "$LOG" \
  && ok "C4 the stored null was a successful put" || bad "C4 log: $(cat "$LOG")"
eq "C4 the null has a time (stored, not left out)" "$(row "$R" 204 | jq -r '.fields_at.mergeable_state')" "$(iso 0)"
get "$R" 204 mergeable_state
eq "C4 a second get reads again" "$(reads 204)" 2
gh_pr 204 clean
get "$R" 204 mergeable_state
eq "C4 clean prints clean" "$(jq -r '.mergeable_state' "$T/out")" clean
eq "C4 3 reads so far" "$(reads 204)" 3
get "$R" 204 mergeable_state
eq "C4 a further get makes 0 reads" "$(reads 204)" 3

put "$R" 206 github "{\"state\":\"open\",\"head_sha\":\"$SHA_A\",\"mergeable_state\":\"clean\"}" "$(iso 1000)" || bad "C4 setup put 206"
sql "UPDATE pr_records SET refreshed_at = ? WHERE repo = ? AND number = ?" "$(iso 1000)" "$R" 206 >/dev/null
gh_pr 206 unknown
get "$R" 206 mergeable_state
eq "C4 a stale clean, GitHub now unknown: the record holds null" "$(row "$R" 206 | jq -r '.mergeable_state')" null
eq "C4 a stale clean, GitHub now unknown: the get prints null" "$(jq -r '.mergeable_state' "$T/out")" null

# ---- C5: a check write does not refresh an old record ----------------------------
put "$R" 203 fleet "{\"state\":\"open\",\"head_sha\":\"$SHA_A\"}" || bad "C5 setup put"
sql "UPDATE pr_records SET refreshed_at = ? WHERE repo = ? AND number = ?" "$(iso 901)" "$R" 203 >/dev/null
hook check_run "$(check_run 203 "$(iso 10)")"
eq "C5 the receiver answers 200" "$(cat "$T/hook.code")" 200
eq "C5 the check is stored" "$(row "$R" 203 | jq -r '.checks["harness-ci"].conclusion')" success
gh_pr 203 clean
: > "$T/gh.log"; : > "$LOG"
get "$R" 203
eq "C5 1 read" "$(reads 203)" 1
grep -q "get $R#203 reason=stale " "$LOG" && ok "C5 the reason is stale" || bad "C5 log: $(cat "$LOG")"

# ---- C6: a bad signature writes nothing -----------------------------------------
hook check_run "$(check_run 205 "$(iso 10)")" "sha256=$(printf '0%.0s' $(seq 64))"
eq "C6 401" "$(cat "$T/hook.code")" 401
eq "C6 no row" "$(row "$R" 205)" null

# ---- B1: budget -----------------------------------------------------------------
case "$JOBS_URL" in http://127.0.0.1:*) ok "B1 every worker request went to 127.0.0.1" ;; *) bad "B1 JOBS_URL is $JOBS_URL" ;; esac
eq "B1 gh resolves to the stub" "$(command -v gh)" "$T/bin/gh"

echo "pr-record-webhook.bh-8151: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
