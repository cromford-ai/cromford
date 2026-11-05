#!/bin/bash
# tests/conductor-rereview-request.bh-9026-test.sh — BH-9026: when the newest
# `done` merge-conductor-pr row of a PR's key says `deferred=rereview` (the
# machine left the re-review of a moved head to the hub), the hub tick asks
# the lead for a review of that head in the same tick, through
# bin/lead-verdict.sh request. Idempotent: the attempt marker `rrleadreq`
# suppresses a second call, and a 409 is "exists". A failed request parks the
# PR BLOCKED_HUMAN with one log line and one alert per (PR, head).
#
# Driven through the REAL bin/merge-conductor.sh tick (gh and git stubbed, the
# fixture of tests/conductor-fly-fallback.bh-6817-test.sh) against the REAL
# jobs worker (tests/lib/lane-runs-worker.bh-6124.mjs) on localhost. The seam
# is a stub $HARNESS/bin/lead-verdict.sh: it logs its argv and answers from a
# control file in the real formats of lv_request / lr_post_lead.
#
#   C1  cromford#31, deferred=rereview: 1 request, no --priority, the
#       `rereview requested lr-fixture-1` line, the fallback line still there
#   C2  tick 2 over the same row: still 1 request, no second line
#   C3  #32 answers 409 -> `exists`, tick 2 makes 0 calls; #35 `nostore`
#       reads as requested `(priority not stored)`
#   C4  hotfix label -> --priority 500; knob 700 -> 700; knob abc -> 500 + a
#       line; hotfix-candidate / not-hotfix -> no --priority
#   C5  #34 answers HTTP 503 -> FAILED line, BLOCKED_HUMAN
#       rereview-request-failed, 1 alert, no local worker; tick 2: 2 calls,
#       still 1 alert
#   C6  deferred - / land / rereviewx / prerereview -> 0 calls;
#       rebase,rereview -> 1 call
#   C7  demo-os (not in LEAD_REVIEW_AUTO_REPOS) deferred=rereview -> 0 calls,
#       today's fallback line
#   C8  mc_fly_rereview_request with MC_ON_MACHINE=1 -> skip, 0 calls
#   C9  no gh write; every lead request went through the stub seam
#
# Run from anywhere: tests/conductor-rereview-request.bh-9026-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or setsid missing"; exit 0; }

# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
( export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
( cd "$DIR" && scratch_install_closure bin/merge-conductor.sh "$T/h" ) >/dev/null || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/mc/fly-workers.sh "$T/h" ) >/dev/null || exit 1
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
# The lane registry with the one lane this read needs: LEAD_REVIEW_AUTO_REPOS
# (lead-review-land's required knob, default example-org/cromford). The
# merge-conductor lane stays out, so the tick runs as in the 6817 fixture.
mkdir -p "$T/h/catalog" && jq '.lanes |= map(select(.id == "lead-review-land")) | .libs = []' \
  "$DIR/catalog/lanes.json" > "$T/h/catalog/lanes.json" || exit 1
{
  printf 'cromford example-org/cromford https://bh.example /api/board 2 box-bh\n'
  printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n'
} > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"

# The lead seam. Mode from $T/lv-mode: created | 409 | fail | nostore.
cat > "$T/h/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/lv-calls.txt"
[ "\${1:-}" = request ] || exit 0
h="\${4:-}"
case "\$(cat "$T/lv-mode" 2>/dev/null)" in
  created) echo "requested lead review #lr-fixture-1 on \$2#\$3 @ \${h:0:12} (requested)"; exit 0 ;;
  409) echo "HTTP 409" >&2; echo "lead-verdict: request refused: {\"error\":\"exists\"}" >&2; exit 1 ;;
  nostore) echo "requested lead review #lr-fixture-2 on \$2#\$3 @ \${h:0:12} (claimed)"
           echo "lead-verdict: priority 500 was not stored (request #lr-fixture-2 is claimed)" >&2; exit 1 ;;
  *) echo "HTTP 503" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/h/bin/lead-verdict.sh"

hd() { local s="$1aaaabbbbccccddddeeeeffff0000111122223333"; printf '%s' "${s:0:40}"; }
MAIN1=1111111111111111111111111111111111111111

# setlist <repo-short> "<num>:<labels> ..." — the open list of one repo.
setlist() {
  local r="$1" out="[" e n l lj; shift
  for e in $1; do
    n="${e%%:*}"; l="${e#*:}"
    if [ -z "$l" ] || [ "$l" = "$e" ]; then lj='[]'; else lj=$(jq -nc --arg l "$l" '$l | split(",") | map({name:.})'); fi
    out="$out{\"number\":$n,\"url\":\"https://github.com/example-org/$r/pull/$n\",\"headRefOid\":\"$(hd "$n")\",\"headRefName\":\"ticket/pb-$n\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"labels\":$lj},"
  done
  printf '%s\n' "${out%,}]" > "$T/list-$r.json"
}
setlist cromford ""; setlist demo-os ""

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*|*"-X DELETE"*)
    echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/cromford --state open"*) cat "$T/list-cromford.json" ;;
  *"pr list -R example-org/demo-os --state open"*) cat "$T/list-demo-os.json" ;;
  *"pulls?state=closed"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"actions/runs?head_sha="*)
    a="\$*"; h="\${a##*head_sha=}"
    printf '%s\n' "\${h:0:2}" >> "$T/worker-reads.txt"
    printf 'in_progress|\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
echo "$MAIN1" > "$T/ctl-main-sha"
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case "\$*" in
  *--version*) echo "git version 2.45.0" ;;
  *ls-remote*"refs/heads/"*) printf '%s\trefs/heads/main\n' "\$(cat "$T/ctl-main-sha")" ;;
  *ls-remote*) echo "0000000000000000000000000000000000000000	HEAD" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
: > "$T/gh-writes.txt"; : > "$T/c-alerts.txt"; : > "$T/lv-calls.txt"; echo created > "$T/lv-mode"
CLOG="$T/h/logs/merge-conductor.log"; : > "$CLOG"

PIDS=()
srv() {
  local n="w${#PIDS[@]}"
  : > "$T/$n.log"; : > "$T/$n.port"
  env "$@" node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  JOBS_URL="http://127.0.0.1:$PORT"
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
api() { curl -sS -X "$1" -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
          ${3:+-d "$3"} "$JOBS_URL$2"; }
ctick() {
  : > "$T/worker-reads.txt"; : > "$CLOG"
  ( cd "$T" && setsid -w env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=fixture-harness-secret \
      JOBS_URL="$JOBS_URL" JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
      MC_PR_PARALLEL=0 MC_KEYED_WAKE_MIN_S=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) 2>/dev/null || true
}
# ran_row <project> <repo-short> <pr> <prof> — a done rc 0 run of the PR's head,
# through the real enqueue, claim and report routes, as a machine does.
ran_row() {
  local p="$1" r="$2" n="$3" h key args id; h=$(hd "$n"); key="$p.$n.${h:0:12}"
  args=$(jq -nc --arg h "$h" --arg s "example-org/$r#$n" --arg p "$p" '["bin/merge-conductor-pr.sh",$p,$s,$h]')
  id=$(api POST /api/lane-runs "$(jq -nc --arg p "$key" --argjson a "$args" '{lane:"merge-conductor-pr",project:$p,args:$a}')" | jq -r .id)
  api POST /api/lane-runs/claim '{"machine":"m9"}' >/dev/null
  api POST "/api/lane-runs/$id/report" "$(jq -nc --arg pr "$4" '{machine:"m9",rc:0,prof:$pr}')" > "$T/report.json"
}
prof() { printf 'PROF mc-pr state=HEAD_MOVED reason=head-moved deferred=%s' "$1"; }
# calls <pr> — the request calls of one PR so far.
calls() { grep -c "^request example-org/[a-z-]* $1 " "$T/lv-calls.txt"; }
callline() { grep "^request example-org/[a-z-]* $1 " "$T/lv-calls.txt" | tail -1; }
fresh() { srv; setting conductor_workers_on_fly 1; }

srv; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T"/w0.err)"; exit 1; }
ctick
grep -q 'cromford LAND baseline' "$CLOG" && ok "setup: the land baseline is recorded" \
  || bad "setup: no land baseline: $(grep LAND "$CLOG" | head -3)"

# ============================================================================
echo "C1: deferred=rereview -> one lead request in the same tick"
fresh; setlist cromford "31"; echo created > "$T/lv-mode"
ran_row cromford cromford 31 "$(prof rereview)"
ctick
H31=$(hd 31)
[ "$(calls 31)" = 1 ] && ok "C1 exactly 1 request" || bad "C1 requests: $(calls 31); stderr: $(tail -3 "$T/tick.err")"
case "$(callline 31)" in
  "request example-org/cromford 31 $H31 --notes "*) ok "C1 request argv: repo, pr, head40, --notes, no --priority" ;;
  *) bad "C1 argv: '$(callline 31)'" ;;
esac
grep -qF "example-org/cromford#31 rereview requested lr-fixture-1 for ${H31:0:12} (pool deferred)" "$CLOG" \
  && ok "C1 logs the rereview requested line" || bad "C1 log: $(grep 'cromford#31' "$CLOG" | tail -3)"
grep -qF "example-org/cromford#31 fallback=machine-deferred (rereview) — this PR runs on the hub this tick" "$CLOG" \
  && ok "C1 the fallback line is still there" || bad "C1 fallback: $(grep 'cromford#31' "$CLOG" | tail -3)"

echo "C2: tick 2 over the same row -> no second request"
ctick
[ "$(calls 31)" = 1 ] && ok "C2 still 1 request" || bad "C2 requests: $(calls 31)"
[ "$(grep -c 'cromford#31 rereview requested' "$CLOG")" = 0 ] && ok "C2 no second requested line" \
  || bad "C2 log: $(grep 'cromford#31 rereview' "$CLOG")"

# ============================================================================
echo "C3: a 409 is exists; nostore reads as requested"
fresh; setlist cromford "32"; echo 409 > "$T/lv-mode"
ran_row cromford cromford 32 "$(prof rereview)"
ctick
H32=$(hd 32)
[ "$(calls 32)" = 1 ] && ok "C3 1 call" || bad "C3 calls: $(calls 32)"
grep -qF "example-org/cromford#32 rereview request exists for ${H32:0:12} (pool deferred)" "$CLOG" \
  && ok "C3 logs exists" || bad "C3 log: $(grep 'cromford#32' "$CLOG" | tail -3)"
grep -q 'cromford#32 -> BLOCKED_HUMAN' "$CLOG" && bad "C3 a 409 parked the PR" || ok "C3 a 409 parks nothing"
ctick
[ "$(calls 32)" = 1 ] && ok "C3 tick 2 makes 0 calls" || bad "C3 tick 2 calls: $(calls 32)"
fresh; setlist cromford "35:hotfix"; echo nostore > "$T/lv-mode"
ran_row cromford cromford 35 "$(prof rereview)"
ctick
grep -qF "example-org/cromford#35 rereview requested lr-fixture-2 for $(hd 35 | cut -c1-12) (pool deferred) (priority not stored)" "$CLOG" \
  && ok "C3 nostore reads as requested (priority not stored)" || bad "C3 nostore log: $(grep 'cromford#35' "$CLOG" | tail -3)"
ctick
[ "$(calls 35)" = 1 ] && ok "C3 nostore marked: tick 2 makes 0 calls" || bad "C3 nostore calls: $(calls 35)"

# ============================================================================
echo "C4: the hotfix priority"
echo created > "$T/lv-mode"
pri_case() { # pri_case <pr> <labels> <want-priority|none> <label> [VAR=value]
  local n="$1" l="$2" want="$3" what="$4"; shift 4
  fresh; setlist cromford "$n${l:+:$l}"
  ran_row cromford cromford "$n" "$(prof rereview)"
  ctick "$@"
  local c; c=$(callline "$n")
  if [ "$want" = none ]; then
    [ "$(calls "$n")" = 1 ] && [[ $c != *--priority* ]] && ok "C4 $what -> no --priority" || bad "C4 $what: '$c'"
  else
    [ "$(calls "$n")" = 1 ] && [[ $c == *"--priority $want "* ]] && ok "C4 $what -> --priority $want" || bad "C4 $what: '$c'"
  fi
}
pri_case 33 hotfix 500 "hotfix label"
pri_case 36 "queued,hotfix" 700 "hotfix + knob 700" MC_REREVIEW_REQUEST_HOTFIX_PRIORITY=700
pri_case 37 hotfix 500 "hotfix + knob abc" MC_REREVIEW_REQUEST_HOTFIX_PRIORITY=abc
grep -q "MC_REREVIEW_REQUEST_HOTFIX_PRIORITY='abc'" "$CLOG" && ok "C4 knob abc logs one line" \
  || bad "C4 knob abc line: $(grep -c MC_REREVIEW_REQUEST_HOTFIX_PRIORITY "$CLOG")"
pri_case 38 hotfix-candidate none "hotfix-candidate"
pri_case 39 not-hotfix none "not-hotfix"

# ============================================================================
echo "C5: a failed request -> BLOCKED_HUMAN, one alert, no local worker"
fresh; setlist cromford "34"; echo fail > "$T/lv-mode"; : > "$T/c-alerts.txt"
ran_row cromford cromford 34 "$(prof rereview)"
ctick
H34=$(hd 34)
grep -qF "example-org/cromford#34 rereview request FAILED for ${H34:0:12} (pool deferred): HTTP 503" "$CLOG" \
  && ok "C5 logs FAILED with the reason" || bad "C5 log: $(grep 'cromford#34' "$CLOG" | tail -3)"
ST=$( ( export HARNESS="$T/h" MC_ROWS="$T/h/state/merge-conductor/pr-state.tsv"; . "$T/h/bin/lib/mc/settle.sh" 2>/dev/null; mc_row_get "example-org/cromford#34" ) | cut -f2,7)
[ "$ST" = "BLOCKED_HUMAN	rereview-request-failed" ] && ok "C5 pr-state BLOCKED_HUMAN rereview-request-failed" \
  || bad "C5 pr-state: '$ST' ($(grep 'cromford#34' "$CLOG" | grep -- '->' | tail -2))"
[ "$(grep -c 'cromford#34' "$T/c-alerts.txt")" = 1 ] && grep -q "${H34:0:12}" "$T/c-alerts.txt" \
  && ok "C5 1 alert naming #34 and the head" || bad "C5 alerts: $(cat "$T/c-alerts.txt")"
grep -qx "${H34:0:2}" "$T/worker-reads.txt" && bad "C5 a local worker ran for #34" || ok "C5 no local worker for #34"
grep -q 'cromford#34 skipped:rereview-request-failed\|cromford#34.*fallback=' "$CLOG" \
  && ! grep -q 'cromford#34 fallback=' "$CLOG" && ok "C5 no fallback line, skipped accounted" \
  || bad "C5 lines: $(grep 'cromford#34' "$CLOG" | tail -4)"
ctick
[ "$(calls 34)" = 2 ] && ok "C5 tick 2 asks again (2 calls)" || bad "C5 calls: $(calls 34)"
[ "$(grep -c 'cromford#34' "$T/c-alerts.txt")" = 1 ] && ok "C5 still 1 alert" || bad "C5 alerts: $(cat "$T/c-alerts.txt")"

# ============================================================================
echo "C6: the deferred word matcher"
echo created > "$T/lv-mode"
word_case() { # word_case <pr> <deferred> <want-calls>
  fresh; setlist cromford "$1"
  ran_row cromford cromford "$1" "$(prof "$2")"
  ctick
  [ "$(calls "$1")" = "$3" ] && ok "C6 deferred=$2 -> $3 call(s)" || bad "C6 deferred=$2: $(calls "$1") calls"
}
word_case 41 - 0
word_case 42 land 0
word_case 43 rereviewx 0
word_case 44 prerereview 0
word_case 45 rebase,rereview 1

# ============================================================================
echo "C7: a repo not in LEAD_REVIEW_AUTO_REPOS -> no request"
fresh; setlist cromford ""; setlist demo-os "51"
ran_row demo-os demo-os 51 "$(prof rereview)"
ctick
[ "$(calls 51)" = 0 ] && ok "C7 0 calls for demo-os#51" || bad "C7 calls: $(calls 51)"
grep -qF "example-org/demo-os#51 fallback=machine-deferred (rereview) — this PR runs on the hub this tick" "$CLOG" \
  && ok "C7 today's fallback line" || bad "C7 log: $(grep 'demo-os#51' "$CLOG" | tail -3)"
setlist demo-os ""

# ============================================================================
echo "C8: MC_ON_MACHINE=1 -> skip, 0 calls"
before=$(grep -c '^request ' "$T/lv-calls.txt")
out=$( ( export HARNESS="$T/h" MC_H="$T/h" MC_ON_MACHINE=1; . "$T/h/bin/lib/mc/fly-workers.sh" \
  && mc_fly_rereview_request cromford example-org/cromford 61 "$(hd 61)" https://x/61 - ) 2>/dev/null)
[ "$out" = skip ] && [ "$(grep -c '^request ' "$T/lv-calls.txt")" = "$before" ] && ok "C8 skip, 0 calls" \
  || bad "C8 out '$out', calls $(grep -c '^request ' "$T/lv-calls.txt") (was $before)"

# ============================================================================
echo "C9: no network beyond the localhost worker and the stub"
[ ! -s "$T/gh-writes.txt" ] && ok "C9 no gh write" || bad "C9 gh writes: $(head -3 "$T/gh-writes.txt")"
grep -v '^request \|^$' "$T/lv-calls.txt" | grep -q . && echo "  (note) other lead-verdict calls: $(grep -v '^request ' "$T/lv-calls.txt" | sort -u | head -3)"
[ "$(grep -c '^request ' "$T/lv-calls.txt")" -ge 1 ] && ok "C9 every lead request went through the stub seam" \
  || bad "C9 the stub saw no request"

echo "conductor-rereview-request: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
