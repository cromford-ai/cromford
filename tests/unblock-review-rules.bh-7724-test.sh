#!/bin/bash
# tests/unblock-review-rules.bh-7724-test.sh — UNB-2 (BH-7724): the review
# family of the PR unblock agent, in shadow. It drives the collector CLI
# bin/lib/unblock/collectors/review.sh, the judge bin/lib/unblock/judge.sh, the
# four rule files catalog/unblock-rules.d/U{5,6,7,11}-*.json and the judge
# prompt catalog/prompts/unblock-judge.md.
#
# THE ENGINE IS A STAND-IN. UNB-1 (#7723) owns bin/lib/unblock/rules.sh, the
# first-match engine, and it is not on main. ure_eval below is a test-only
# evaluator: the record's kind equals match.kind and every match.all predicate
# answers exactly `true` (null, false or a jq error is no match).
#
# STUBS, per case under $T/<case>: `gh` and `curl` on PATH answer from the
# case's copy of a tests/fixtures/unblock/*.json fixture and log every call; a
# write (any method but GET) is logged to writes.txt, and C13 fails on one.
# $HARNESS/bin/agent-call.sh is a stub that counts calls and answers from
# judge-answer. lane_role_model comes from the judge's UNBLOCK_FIXTURE seam.
# Every case has its own scratch harness and its own ids: no shared state.
# Run from anywhere: tests/unblock-review-rules.bh-7724-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

COL="$DIR/bin/lib/unblock/collectors/review.sh"
JUDGE="$DIR/bin/lib/unblock/judge.sh"
RULES="$DIR/catalog/unblock-rules.d"
FX="$DIR/tests/fixtures/unblock"
SOP="$DIR/catalog/prompts/unblock-judge.md"
REPO=example-org/cromford
export JOBS_URL=https://jobs.example.test
A=7556aaaa0000000000000000000000000000a001
CH=7560cccc0000000000000000000000000000c001
D=7590dddd0000000000000000000000000000d001
E=ea3b333c74373b0711ad5441619e56972ea1f565
CASES=""

# newcase <name> <fixture> [jq args... edit] — a fresh harness for one case; sets C.
newcase() {
  C="$T/$1"; CASES="$CASES $C"
  mkdir -p "$C/stub" "$C/h/bin" "$C/h/logs" "$C/h/locks" "$C/h/catalog/prompts"
  if [ -z "$2" ]; then echo '{}' > "$C/fixture.json"
  elif [ "$#" -ge 3 ]; then jq "${@:3}" "$FX/$2" > "$C/fixture.json" || bad "$1: fixture $2 edit failed"
  else cp "$FX/$2" "$C/fixture.json"; fi
  cp "$SOP" "$C/h/catalog/prompts/" 2>/dev/null
  : > "$C/gh.calls"; : > "$C/curl.calls"; : > "$C/writes.txt"; : > "$C/ac.calls"; : > "$C/route.calls"
  printf '#!/bin/bash\nC=%q\n' "$C" > "$C/stub/gh"
  cat >> "$C/stub/gh" <<'EOF'
# gh api -i -X <method> <path> [-H ...]: the gh_rest envelope (status, blank, body).
m=""; p=""
while [ $# -gt 0 ]; do
  case "$1" in -X) m="$2"; shift 2 ;; -H|-F|-f) shift 2 ;; api|-i|-*) shift ;; *) [ -n "$p" ] || p="$1"; shift ;; esac
done
echo "$m $p" >> "$C/gh.calls"
if [ "$m" != GET ]; then echo "gh $m $p" >> "$C/writes.txt"; printf 'HTTP/2 403\r\n\r\n{"message":"write refused by the stub"}'; exit 1; fi
path="${p%%\?*}"; key=""
case "$path" in
  repos/*/pulls) key=pulls ;;
  search/issues) key=search ;;
  repos/*/pulls/*/reviews) n="${path%/reviews}"; key="reviews.${n##*/}" ;;
  repos/*/issues/*/comments) n="${path%/comments}"; key="comments.${n##*/}" ;;
esac
st=$(jq -r --arg k "$key" '.status[$k] // empty' "$C/fixture.json")
if [ -n "$st" ]; then printf 'HTTP/2 %s\r\n\r\n{"message":"stub status"}' "$st"; exit 1; fi
body=""; [ -z "$key" ] || body=$(jq -c --arg k "$key" 'getpath($k | split(".")) // empty' "$C/fixture.json")
if [ -z "$body" ]; then printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}'; exit 1; fi
printf 'HTTP/2 200\r\n\r\n%s' "$body"
EOF
  printf '#!/bin/bash\nC=%q\n' "$C" > "$C/stub/curl"
  cat >> "$C/stub/curl" <<'EOF'
# The jobs worker: prints the body, a newline and the status (curl -w '\n%{http_code}').
m=GET; url=""
while [ $# -gt 0 ]; do
  case "$1" in -X) m="$2"; shift 2 ;; -H|-w|-m|--connect-timeout|--data-binary|-d) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
p="${url#"$JOBS_URL"}"
echo "$m $p" >> "$C/curl.calls"
if [ "$m" != GET ]; then echo "curl $m $p" >> "$C/writes.txt"; printf '{"error":"write refused by the stub"}\n500'; exit 0; fi
path="${p%%\?*}"; key=""
case "$path" in
  /api/verdicts) key="verdicts.$(sed -n 's/.*[?&]pr=\([0-9]*\).*/\1/p' <<<"$p")" ;;
  /api/jobs/*/artifacts) j="${path#/api/jobs/}"; key="artifacts.${j%/artifacts}" ;;
  /api/lead-reviews) key=lead_reviews_running ;;
esac
st=$(jq -r --arg k "$key" '.status[$k] // empty' "$C/fixture.json")
if [ -n "$st" ]; then printf '{"error":"stub status"}\n%s' "$st"; exit 0; fi
body=""; [ -z "$key" ] || body=$(jq -c --arg k "$key" 'getpath($k | split(".")) // empty' "$C/fixture.json")
if [ -z "$body" ]; then printf '{"error":"not found"}\n404'; exit 0; fi
case "$key" in artifacts.*) body=$(jq -c '{artifacts: [to_entries[] | {artifact_kind: .key, detail: (.value | tojson)}]}' <<<"$body") ;; esac
printf '%s\n200' "$body"
EOF
  printf '#!/bin/bash\nC=%q\n' "$C" > "$C/h/bin/agent-call.sh"
  cat >> "$C/h/bin/agent-call.sh" <<'EOF'
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
echo "stage=$1 project=$2 model=$3 to=$4 notools=${AGENT_CALL_NO_TOOLS:-} lane=${AGENT_CALL_LANE:-} guard=${AGENT_CALL_GUARD_STAGE:-} usd=${AGENT_CALL_BUDGET_USD_UNBLOCK_JUDGE:-} fp=${AGENT_CALL_FP:-}" >> "$C/ac.calls"
case "$6" in @*) cp "${6#@}" "$C/prompt.txt" 2>/dev/null ;; *) printf '%s' "$6" > "$C/prompt.txt" ;; esac
rc=$(cat "$C/ac-rc" 2>/dev/null || echo 0)
if [ "$rc" = 0 ]; then
  cat "$C/judge-answer" > "$5" 2>/dev/null
  printf '{"result":"stub","total_cost_usd":0.0123}' > "$5.json"
fi
exit "$rc"
EOF
  chmod +x "$C/stub/gh" "$C/stub/curl" "$C/h/bin/agent-call.sh"
  printf 'lane_role_model() { echo "lane_role_model $*" >> %q; if [ -f %q ]; then return "$(cat %q)"; fi; echo stub-model-x; }\n' \
    "$C/route.calls" "$C/route-rc" "$C/route-rc" > "$C/fixture.sh"
  touch -d '2026-01-01' "$C/fixture.json"
}

# col [VAR=value...] — the collector CLI over the case's fixture.
col() {
  local now; now=$(date -u -d "$(jq -r '.now // "2026-10-20T16:00:00Z"' "$C/fixture.json")" +%s)
  env PATH="$C/stub:$PATH" HARNESS="$C/h" HARNESS_SECRET=fixture-secret-1 GH_ETAG=0 UNBLOCK_NOW="$now" "$@" \
    bash "$COL" --project cromford --repo "$REPO" > "$C/out.jsonl" 2> "$C/col.err"
  echo $? > "$C/col.rc"
}
recs() { jq -c --arg k "$1" 'select(.kind == $k)' "$C/out.jsonl" 2>/dev/null; }
meta() { tail -1 "$C/out.jsonl" 2>/dev/null; }
f() { jq -r "$2" <<<"$1" 2>/dev/null; }
nl_() { grep -c . "$1" 2>/dev/null || true; }

# judge <question> <input-file> <key> — the judge, sourced the way the tick will.
judge() {
  ( export HARNESS="$C/h" HARNESS_TEST_SANDBOX=1 UNBLOCK_FIXTURE="$C/fixture.sh"
    . "$JUDGE" || exit 9
    unblock_judge "$@" )
}
route() { ( . "$JUDGE" || exit 9; unblock_judge_route "$@" ); }
ledger() { cat "$C/h/state/unblock-judge/$1.json" 2>/dev/null; }

# ure_eval <rule-file> <record-json> — rc 0 when the rule matches (test-only engine).
ure_eval() {
  local rule="$1" rec="$2" p
  [ -r "$rule" ] || return 1
  [ "$(jq -r '.kind' <<<"$rec")" = "$(jq -r '.match.kind' "$rule")" ] || return 1
  while IFS= read -r p; do
    [ "$(jq -c "$p" <<<"$rec" 2>/dev/null)" = true ] || return 1
  done < <(jq -r '.match.all[]' "$rule")
  return 0
}
# matches <record> — the ids of the review rules that match, space separated.
matches() {
  local r
  for r in "$RULES"/U5-*.json "$RULES"/U6-*.json "$RULES"/U7-*.json "$RULES"/U11-*.json; do
    ure_eval "$r" "$1" && jq -r .id "$r"
  done | paste -sd' ' -
}
rule() { ls "$RULES"/"$1"-*.json 2>/dev/null | head -1; }
# action <rule-id> <record> — the would-action {name, args}; each arg is a jq expression over the record.
action() {
  local r k e v out='{}'; r=$(rule "$1")
  [ -n "$r" ] || { echo '{}'; return; }
  while IFS=$'\t' read -r k e; do
    v=$(jq -c "$e" <<<"$2" 2>/dev/null) || v=null
    out=$(jq -c --arg k "$k" --argjson v "${v:-null}" '.[$k] = $v' <<<"$out")
  done < <(jq -r '.action.args | to_entries[] | [.key, .value] | @tsv' "$r")
  jq -c --arg n "$(jq -r .action.name "$r")" '{name: $n, args: .}' <<<"$out"
}

# ── C1: #7556, a lead BLOCK nobody routed ────────────────────────────────────
newcase c1 block-7556.json
col
[ "$(cat "$C/col.rc")" = 0 ] && ok || bad "C1: collector rc $(cat "$C/col.rc"): $(head -3 "$C/col.err")"
r=$(recs lead-block-unrouted)
[ "$(printf '%s' "$r" | grep -c .)" = 1 ] && ok || bad "C1: want 1 lead-block-unrouted record, got: $(cat "$C/out.jsonl")"
[ "$(f "$r" '[.family, .repo, .pr, .head] | join(" ")')" = "review $REPO 7556 $A" ] && ok || bad "C1: family/repo/pr/head: $r"
# the UNB-0 record fields the rules engine and act.sh read (act.sh refuses no project)
[ "$(f "$r" '[.project, .subject_kind, .subject] | join(" ")')" = "cromford pr $REPO#7556" ] && ok || bad "C1: project/subject_kind/subject: $r"
[ "$(f "$r" '[.job_id, .report_readable, .cr_on_head, .findings_comment_on_head, .fix_round_running, .cap_only_candidate] | map(tostring) | join(" ")')" \
  = "job-fixture-7556 true false false false false" ] && ok || bad "C1: routing fields: $r"
[ "$(f "$r" '.block_lines | length')" = 3 ] && [ "$(f "$r" '.block_lines_truncated')" = false ] && ok || bad "C1: want the 3 BLOCK lines: $r"
[ "$(f "$r" '.stall_at')" = 2026-10-20T13:10:00Z ] && [ "$(f "$r" '.unknown | length')" = 0 ] && ok || bad "C1: stall_at/unknown: $r"
[ "$(matches "$r")" = U5 ] && ok || bad "C1: want U5 only, got '$(matches "$r")'"
a=$(action U5 "$r")
[ "$(f "$a" .name)" = post_block ] && [ "$(f "$a" .args.head)" = "$A" ] && [ "$(f "$a" .args.pr)" = 7556 ] && ok || bad "C1: would-action: $a"
[ "$(f "$a" '.args.lines | length')" = 3 ] && f "$a" '.args.lines[0]' | grep -q '^- \[BLOCK wrong-data\] bin/lib/fixture-a.sh:41' && ok || bad "C1: the would-action must carry the BLOCK lines: $a"
[ "$(jq -c 'select(.pr == 7601)' "$C/out.jsonl" | grep -c .)" = 0 ] && ok || bad "C1: the MERGE PR #7601 must give no record"
m=$(meta)
[ "$(f "$m" '[.kind, .family, .prs_seen, .truncated, (.unreadable | length)] | map(tostring) | join(" ")')" = "collector-meta review 2 false 0" ] && ok || bad "C1: meta: $m"
grep -q "review: $REPO prs=2 records=1 unknown=0 rest=4 worker=4" "$C/h/logs/unblock.log" 2>/dev/null && ok || bad "C1: log line: $(cat "$C/h/logs/unblock.log" 2>/dev/null)"
[ "$(nl_ "$C/ac.calls")" = 0 ] && ok || bad "C1: the collector made a model call"

# The failure table rows around U5 (plan, Failure modes).
newcase c1-draft block-7556.json '.pulls[0].draft = true'
col
[ -n "$(recs lead-block-unrouted)" ] && ok || bad "C1-draft: an open draft PR is still read"
newcase c1-cr block-7556.json --arg a "$A" '.reviews["7556"] += [{id: 5002, user: {login: "person-fixture"}, state: "CHANGES_REQUESTED", commit_id: $a, body: "x", submitted_at: "2026-10-20T13:30:00Z"}]'
col
[ -z "$(recs lead-block-unrouted)" ] && ok || bad "C1-cr: a CR on the head is routed already: $(cat "$C/out.jsonl")"
newcase c1-box block-7556.json '.verdicts["7556"].standing = null'
col
[ -z "$(recs lead-block-unrouted)$(recs lead-block-cap-only)" ] && ok || bad "C1-box: a box BLOCK row never stands: $(cat "$C/out.jsonl")"
newcase c1-cut block-7556.json '.artifacts["job-fixture-7556"].lead_review_report.truncated = true'
col
r=$(recs lead-block-unrouted)
[ "$(f "$r" '.report_readable')" = null ] && f "$r" '.unknown[]' | grep -qx report && [ -z "$(matches "$r")" ] && ok || bad "C1-cut: a cut report is unknown, not 'no BLOCK lines': $r"
newcase c1-near block-7556.json '.artifacts["job-fixture-7556"].lead_review_report.body |= sub("- review level"; "- outcome cap: 1 INCONCLUSIVE claim row (claim 2) on perf (LEAD_REVIEW_INCONCLUSIVE_BLOCK=1); agent verdict BLOCK\n- review level")'
col
r=$(recs lead-block-unrouted)
[ -n "$r" ] && [ -z "$(recs lead-block-cap-only)" ] && [ "$(matches "$r")" = U5 ] && f "$r" .cap_line | grep -q 'outcome cap' && ok || bad "C1-near: a cap line next to code BLOCK lines is U5, not U6: $(cat "$C/out.jsonl")"
newcase c1-fix block-7556.json
LK="$C/h/locks/blocked-resolver-cromford-example-org-cromford-7556.lock"
( exec 9>"$LK"; flock 9; touch "$C/held"; sleep 20 ) & HP=$!
for _ in $(seq 1 50); do [ -f "$C/held" ] && break; sleep 0.1; done
col
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
r=$(recs lead-block-unrouted)
[ "$(f "$r" .fix_round_running)" = true ] && [ -z "$(matches "$r")" ] && ok || bad "C1-fix: a held resolver key lock is a fix round running: $r"

# ── C2: #7560, the outcome cap only; the judge says CAP_ONLY ─────────────────
newcase c2 cap-7560.json
col
r=$(recs lead-block-cap-only)
[ "$(f "$r" '[.pr, .head, .cap_only_candidate, (.block_lines | length), .metric] | map(tostring) | join(" ")')" = "7560 $CH true 0 claim 1" ] && ok || bad "C2: cap-only record: $(cat "$C/out.jsonl")"
[ -z "$(recs lead-block-unrouted)" ] && ok || bad "C2: the cap-only PR must not be a U5 record"
[ "$(matches "$r")" = U6 ] && ok || bad "C2: want U6 only, got '$(matches "$r")'"
[ "$(nl_ "$C/ac.calls")" = 0 ] && ok || bad "C2: the collector made a model call"
U6=$(rule U6)
jq -r "$( (. "$JUDGE" && unblock_judge_spec "$(jq -r .judge.question "$U6")") | jq -r .input)" <<<"$r" > "$C/input.txt"
printf 'CAP_ONLY\n' > "$C/judge-answer"
j=$(judge cap-only "$C/input.txt" "$REPO#7560@$CH:U6")
[ "$(f "$j" '[.question, .answer, .outcome, .model_calls, .cost_usd] | map(tostring) | join(" ")')" = "cap-only CAP_ONLY ok 1 0.0123" ] && ok || bad "C2: first judge run: $j"
[ "$(route "$U6" CAP_ONLY | head -1)" = proceed ] && ok || bad "C2: CAP_ONLY must route proceed on U6"
a=$(action U6 "$r")
[ "$(f "$a" .name)" = fix_round ] && f "$a" .args.brief | grep -q 'claim 1' && ok || bad "C2: the fix-round brief must name the metric: $a"
grep -q '^stage=unblock-judge project=fleet model=stub-model-x to=120 notools=1 lane=unblock guard=unblock-judge usd=0.6 fp=unblock-judge:[0-9a-f]\{64\}$' "$C/ac.calls" && ok || bad "C2: agent-call argv/env: $(cat "$C/ac.calls")"
grep -q 'exactly one word' "$C/prompt.txt" 2>/dev/null && grep -q '^=== UNTRUSTED INPUT unblock-judge ===$' "$C/prompt.txt" \
  && grep -q 'outcome cap: 1 INCONCLUSIVE' "$C/prompt.txt" && grep -q '^=== END UNTRUSTED INPUT unblock-judge ===$' "$C/prompt.txt" && ok || bad "C2: the prompt must carry the SOP and the fenced input"
FP=$(f "$j" .fp)
[ "$(ledger "$FP" | jq -r '[.outcome, .attempts, .answer] | map(tostring) | join(" ")')" = "ok 1 CAP_ONLY" ] && ok || bad "C2: ledger: $(ledger "$FP")"
j2=$(judge cap-only "$C/input.txt" "$REPO#7560@$CH:U6")
[ "$(f "$j2" '[.answer, .outcome, .model_calls] | map(tostring) | join(" ")')" = "CAP_ONLY cached 0" ] && [ "$(nl_ "$C/ac.calls")" = 1 ] && ok || bad "C2: the second tick must make 0 model calls: $j2"
grep -q 'judge: cap-only' "$C/h/logs/unblock.log" 2>/dev/null && ok || bad "C2: the judge must log its call"

# ── C3: the judge says UNSURE: escalate, no action ───────────────────────────
newcase c3 cap-7560.json
col
r=$(recs lead-block-cap-only); jq -r .cap_line <<<"$r" > "$C/input.txt"
printf 'UNSURE\n' > "$C/judge-answer"
j=$(judge cap-only "$C/input.txt" "$REPO#7560@$CH:U6")
[ "$(f "$j" '[.answer, .outcome] | join(" ")')" = "UNSURE ok" ] && ok || bad "C3: judge: $j"
[ "$(route "$(rule U6)" UNSURE)" = escalate ] && ok || bad "C3: UNSURE must route escalate"

# ── C4: a lead review request whose heartbeat is 40 minutes old ──────────────
newcase c4 stuck-request.json
col
r=$(recs lead-request-stale)
[ "$(printf '%s' "$r" | grep -c .)" = 1 ] && ok || bad "C4: want 1 lead-request-stale record: $(cat "$C/out.jsonl")"
[ "$(f "$r" '[.pr, .head, .request_id, .heartbeat_age_s, .attempts, .priority, .head_current] | map(tostring) | join(" ")')" = "7590 $D lr-fixture-7590 2400 0 5 true" ] && ok || bad "C4: record fields: $r"
[ "$(f "$r" '[.project, .subject_kind, .subject] | join(" ")')" = "cromford pr $REPO#7590" ] && ok || bad "C4: project/subject_kind/subject: $r"
[ "$(matches "$r")" = U7 ] && ok || bad "C4: want U7, got '$(matches "$r")'"
a=$(action U7 "$r")
[ "$(f "$a" '[.name, .args.request_id, .args.head] | join(" ")')" = "lead_rerequest lr-fixture-7590 $D" ] && ok || bad "C4: would-action: $a"
newcase c4-3 stuck-request.json '.lead_reviews_running.requests[0] |= (.reset_count = 2 | .stale_reclaims = 1)'
col
r=$(recs lead-request-stale)
[ "$(f "$r" .attempts)" = 3 ] && [ -z "$(matches "$r")" ] && ok || bad "C4-3: attempt 3 matches no review rule: $r"
newcase c4-fresh stuck-request.json '.lead_reviews_running.requests[0] |= (.heartbeat_at = "2026-10-20T15:50:00Z" | .updated_at = "2026-10-20T15:50:00Z")'
col
[ -z "$(recs lead-request-stale)" ] && ok || bad "C4-fresh: a 10-minute heartbeat is not stale"
newcase c4-moved stuck-request.json '.lead_reviews_running.requests[0].head_sha = "7590eeee0000000000000000000000000000e001"'
col
r=$(recs lead-request-stale)
[ -z "$r" ] || { [ "$(f "$r" .head_current)" = false ] && [ -z "$(matches "$r")" ]; } && ok || bad "C4-moved: a request on an old head must not match U7: $r"

# ── C5: #7553, a stale lead CR next to a MERGE on the new head ───────────────
newcase c5 stale-cr-7553.json
col
r=$(recs stale-change-request)
[ "$(printf '%s' "$r" | grep -c .)" = 1 ] && ok || bad "C5: want 1 stale-change-request record: $(cat "$C/out.jsonl")"
[ "$(f "$r" '[.pr, .head, .review_id, .review_marker, .standing_verdict] | map(tostring) | join(" ")')" = "7553 $E 3001 review-verdict MERGE" ] && ok || bad "C5: record fields: $r"
[ "$(matches "$r")" = U11 ] && ok || bad "C5: want U11, got '$(matches "$r")'"
a=$(action U11 "$r")
[ "$(f "$a" '[.name, .args.review_id] | map(tostring) | join(" ")')" = "dismiss_review 3001" ] && ok || bad "C5: would-action: $a"
[ "$(jq -c 'select(.review_id == 3002)' "$C/out.jsonl" | grep -c .)" = 0 ] && ok || bad "C5: a person's CR with no marker must not be a record"
# The rule itself refuses a person's CR (defense in depth behind the collector).
r2=$(jq -c '.review_marker = null | .review_author_listed = false' <<<"$r")
[ -z "$(matches "$r2")" ] && ok || bad "C5: U11 must not match a CR with no marker by an unlisted author"
newcase c5-listed stale-cr-7553.json
col UNBLOCK_CR_DISMISS_LOGINS=other-fixture,person-fixture
r=$(jq -c 'select(.review_id == 3002)' "$C/out.jsonl")
[ "$(f "$r" .review_author_listed)" = true ] && [ "$(matches "$r")" = U11 ] && ok || bad "C5-listed: a listed author's CR qualifies: $r"
newcase c5-cur stale-cr-7553.json --arg e "$E" '.reviews["7553"][0].commit_id = $e'
col
[ -z "$(recs stale-change-request)" ] && ok || bad "C5-cur: a CR on the current head is not stale"
newcase c5-block stale-cr-7553.json '.verdicts["7553"].standing.verdict = "BLOCK"'
col
[ -z "$(recs stale-change-request)" ] && ok || bad "C5-block: no dismiss while the head stands BLOCK"

# ── C6: the judge answers nothing: billed, terminal, UNSURE ──────────────────
newcase c6 ""
: > "$C/judge-answer"
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7601@x:U4")
[ "$(f "$j" '[.answer, .outcome, .model_calls] | map(tostring) | join(" ")')" = "UNSURE empty 1" ] && ok || bad "C6: first run: $j"
[ "$(ledger "$(f "$j" .fp)" | jq -r .outcome)" = empty ] && ok || bad "C6: the ledger must say empty"
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7601@x:U4")
[ "$(f "$j" '[.answer, .outcome, .model_calls] | map(tostring) | join(" ")')" = "UNSURE cached 0" ] && [ "$(nl_ "$C/ac.calls")" = 1 ] && ok || bad "C6: an empty answer is never asked again: $j"

# ── C7: a weakened test diff routes block, cite G16 ──────────────────────────
newcase c7 ""
printf 'WEAKENED\n' > "$C/judge-answer"
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7602@y:U4")
[ "$(f "$j" '[.question, .answer, .outcome] | join(" ")')" = "test-weakening WEAKENED ok" ] && ok || bad "C7: judge: $j"
grep -q '^-assert_eq' "$C/prompt.txt" 2>/dev/null && ok || bad "C7: the diff must reach the prompt"
printf '%s\n' '{"id":"U4-fixture","judge":{"question":"test-weakening","proceed_on":["LEGIT"],"block_on":["WEAKENED"],"block_cites":["G16"]}}' > "$C/u4.json"
[ "$(route "$C/u4.json" WEAKENED | paste -sd' ' -)" = "block G16" ] && ok || bad "C7: WEAKENED must route block with cite G16, got '$(route "$C/u4.json" WEAKENED)'"
[ "$(route "$C/u4.json" LEGIT)" = proceed ] && [ "$(route "$C/u4.json" UNSURE)" = escalate ] && ok || bad "C7: LEGIT proceeds, UNSURE escalates"

# ── C8: unknown is not false ─────────────────────────────────────────────────
newcase c8 block-7556.json '.status = {"reviews.7556": "503"}'
col
r=$(recs lead-block-unrouted)
[ "$(f "$r" .cr_on_head)" = null ] && f "$r" '.unknown[]' | grep -qx reviews && ok || bad "C8: a failed reviews read is null + unknown: $r"
[ -z "$(matches "$r")" ] && ok || bad "C8: U5 must not match on an unknown"
[ "$(f "$(meta)" .truncated)" = false ] && ok || bad "C8: meta must not claim truncated"
newcase c8-list block-7556.json '.status = {"pulls": "502"}'
col
[ "$(jq -c 'select(.kind != "collector-meta")' "$C/out.jsonl" | grep -c .)" = 0 ] && f "$(meta)" '.unreadable[]' | grep -qx pulls && ok || bad "C8-list: an unreadable PR list gives no record and names pulls: $(cat "$C/out.jsonl")"
newcase c8-vd block-7556.json '.status = {"verdicts.7556": "500"}'
col
[ -z "$(recs lead-block-unrouted)" ] && f "$(meta)" '.unreadable[]' | grep -qx 'verdicts#7556' && ok || bad "C8-vd: an unreadable verdict gives no record: $(cat "$C/out.jsonl")"

# ── C9: own output routes, it is never a finding source ──────────────────────
newcase c9 block-7556.json --arg a "${A:0:12}" '.comments["7556"] += [{id: 6002, user: {login: "cromford[bot]"}, body: ("<!-- tackler:unblock U5 " + $a + " -->\nLead review findings on " + $a + ":\n- [BLOCK wrong-data] bin/lib/fixture-a.sh:41: doubled."), created_at: "2026-10-20T13:40:00Z"}]'
col
[ -z "$(recs lead-block-unrouted)" ] && ok || bad "C9: a tackler findings comment on the head means routed: $(cat "$C/out.jsonl")"
newcase c9-note block-7556.json --arg a "${A:0:12}" '.comments["7556"] += [{id: 6004, user: {login: "cromford[bot]"}, body: ("<!-- tackler:unblock U5 " + $a + " -->\nRouted to the fix round."), created_at: "2026-10-20T13:41:00Z"}]'
col
[ -z "$(recs lead-block-unrouted)" ] && ok || bad "C9-note: the tackler marker alone on the head means routed: $(cat "$C/out.jsonl")"
newcase c9-old block-7556.json '.comments["7556"] += [{id: 6003, user: {login: "cromford[bot]"}, body: "<!-- tackler:unblock U5 7556ffff0000 -->\n- [BLOCK wrong-data] old head", created_at: "2026-10-20T10:00:00Z"}]'
col
[ "$(f "$(recs lead-block-unrouted)" .findings_comment_on_head)" = false ] && ok || bad "C9-old: a findings comment on another head does not route this one"

# ── C10: no model route: no call ─────────────────────────────────────────────
newcase c10 ""
echo 75 > "$C/route-rc"; printf 'LEGIT\n' > "$C/judge-answer"
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7603@z:U4")
[ "$(f "$j" '[.answer, .outcome, .model_calls] | map(tostring) | join(" ")')" = "UNSURE no-route 0" ] && [ "$(nl_ "$C/ac.calls")" = 0 ] && ok || bad "C10: no route must make no call: $j"
grep -q 'lane_role_model unblock.judge' "$C/route.calls" && ok || bad "C10: the model must come from the unblock.judge route"

newcase c10-sop ""
rm -f "$C/h/catalog/prompts/unblock-judge.md"; printf 'LEGIT\n' > "$C/judge-answer"
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7603@y:U4")
[ "$(f "$j" '[.answer, .outcome, .model_calls] | map(tostring) | join(" ")')" = "UNSURE no-prompt 0" ] && [ "$(nl_ "$C/ac.calls")" = 0 ] && ok || bad "C10-sop: no SOP file must make no call: $j"

# ── C11: the failure cap, and a refused call hands the attempt back ──────────
newcase c11 ""
echo 1 > "$C/ac-rc"
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7604@w:U4")
[ "$(f "$j" '[.answer, .outcome, .model_calls] | map(tostring) | join(" ")')" = "UNSURE failed 1" ] && ok || bad "C11: first failure: $j"
judge test-weakening "$FX/test-weakened.diff" "$REPO#7604@w:U4" >/dev/null
[ "$(ledger "$(f "$j" .fp)" | jq -r .attempts)" = 2 ] && ok || bad "C11: want 2 attempts: $(ledger "$(f "$j" .fp)")"
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7604@w:U4")
[ "$(f "$j" '[.outcome, .model_calls] | map(tostring) | join(" ")')" = "failed 0" ] && [ "$(nl_ "$C/ac.calls")" = 2 ] && ok || bad "C11: the third call must make 0 calls: $j"
newcase c11-refused ""
echo 75 > "$C/ac-rc"
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7605@v:U4")
[ "$(f "$j" '[.answer, .outcome] | join(" ")')" = "UNSURE refused" ] && [ "$(ledger "$(f "$j" .fp)" | jq -r .attempts)" = 0 ] && ok || bad "C11-refused: rc 75 hands the attempt back: $j / $(ledger "$(f "$j" .fp)")"

# ── C12: the closed answer set ───────────────────────────────────────────────
newcase c12 ""
i=0
for qa in 'test-weakening|LEGIT, but' 'cap-only|answer: CAP_ONLY' 'cap-only|cap_only' 'test-weakening|CAP_ONLY' 'test-weakening|answer LEGIT'; do
  i=$((i + 1)); printf '%s\n' "${qa#*|}" > "$C/judge-answer"
  j=$(judge "${qa%%|*}" "$FX/test-weakened.diff" "$REPO#7606@u$i:U4")
  [ "$(f "$j" '[.answer, .outcome] | join(" ")')" = "UNSURE ok" ] && [ "$(ledger "$(f "$j" .fp)" | jq -r .answer)" = UNSURE ] && ok || bad "C12: '${qa#*|}' must be UNSURE (billed, terminal): $j"
done
printf 'WEAKENED\nThe diff deletes an assert.\n' > "$C/judge-answer"
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7606@t:U4")
[ "$(f "$j" .answer)" = WEAKENED ] && ok || bad "C12: the first line is the answer: $j"
judge bogus "$FX/test-weakened.diff" k >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "C12: an unknown question is rc 1, got $rc"
seq 1 401 | sed 's/^/+line /' > "$C/big.diff"; n0=$(nl_ "$C/ac.calls")
j=$(judge test-weakening "$C/big.diff" "$REPO#7606@s:U4")
[ "$(f "$j" '[.answer, .outcome, .model_calls] | map(tostring) | join(" ")')" = "UNSURE over-cap 0" ] && [ "$(nl_ "$C/ac.calls")" = "$n0" ] && ok || bad "C12: a 401-line diff is over the cap: $j"
# a held per-fp lock is `busy`, never a second call
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7606@r:U4"); FPB=$(f "$j" .fp)
rm -f "$C/h/state/unblock-judge/$FPB.json"; n0=$(nl_ "$C/ac.calls")
( exec 9>"$C/h/locks/unblock-judge-${FPB:0:12}.lock"; flock 9; touch "$C/jheld"; sleep 20 ) & HP=$!
for _ in $(seq 1 50); do [ -f "$C/jheld" ] && break; sleep 0.1; done
j=$(judge test-weakening "$FX/test-weakened.diff" "$REPO#7606@r:U4")
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
[ "$(f "$j" '[.outcome, .model_calls] | map(tostring) | join(" ")')" = "busy 0" ] && [ "$(nl_ "$C/ac.calls")" = "$n0" ] && ok || bad "C12: a held fp lock is busy with 0 calls: $j"

# ── C14: the judge ledger's retention ────────────────────────────────────────
newcase c14 ""
mkdir -p "$C/h/state/unblock-judge"
printf '{"outcome":"ok"}' > "$C/h/state/unblock-judge/old-fixture.json"; touch -d '40 days ago' "$C/h/state/unblock-judge/old-fixture.json"
printf '{"outcome":"ok"}' > "$C/h/state/unblock-judge/new-fixture.json"
printf 'LEGIT\n' > "$C/judge-answer"
UNBLOCK_JUDGE_PRUNE_DRY=1 judge test-weakening "$FX/test-weakened.diff" "$REPO#7607@q:U4" >/dev/null
[ -f "$C/h/state/unblock-judge/old-fixture.json" ] && grep -q 'prune: dry run, 1 ledger file' "$C/h/logs/unblock.log" 2>/dev/null && ok || bad "C14: the dry run keeps the file and logs the count"
judge test-weakening "$FX/test-weakened.diff" "$REPO#7607@p:U4" >/dev/null
[ ! -f "$C/h/state/unblock-judge/old-fixture.json" ] && [ -f "$C/h/state/unblock-judge/new-fixture.json" ] && grep -q 'prune: deleted 1 ledger file' "$C/h/logs/unblock.log" && ok || bad "C14: a 40-day-old ledger file is pruned, a new one kept"

# ── C15: the four size and time knobs are honoured (lead BLOCK hardcoded-knob) ─
# catalog/lanes.d/unblock.knobs.d/: UNBLOCK_JUDGE_TIMEOUT_S, UNBLOCK_JUDGE_DIFF_MAX_LINES,
# UNBLOCK_JUDGE_CAP_MAX_LINES, UNBLOCK_REVIEW_BLOCK_LINES_MAX. The old literal is the fallback.
newcase c15 ""
printf 'LEGIT\n' > "$C/judge-answer"
judge test-weakening "$FX/test-weakened.diff" "$REPO#7608@a:U4" >/dev/null
grep -q ' to=120 ' "$C/ac.calls" && ok || bad "C15: the default timeout must be 120: $(cat "$C/ac.calls")"
UNBLOCK_JUDGE_TIMEOUT_S=45 judge test-weakening "$FX/test-weakened.diff" "$REPO#7608@b:U4" >/dev/null
[ "$(sed -n 2p "$C/ac.calls" | grep -c ' to=45 ')" = 1 ] && ok || bad "C15: UNBLOCK_JUDGE_TIMEOUT_S=45 must reach agent-call: $(cat "$C/ac.calls")"
UNBLOCK_JUDGE_TIMEOUT_S=abc judge test-weakening "$FX/test-weakened.diff" "$REPO#7608@c:U4" >/dev/null
[ "$(sed -n 3p "$C/ac.calls" | grep -c ' to=120 ')" = 1 ] && grep -q "warn: UNBLOCK_JUDGE_TIMEOUT_S='abc'" "$C/h/logs/unblock.log" && ok || bad "C15: a bad timeout is the fallback 120 and one warn line"
n0=$(nl_ "$C/ac.calls")
j=$(UNBLOCK_JUDGE_DIFF_MAX_LINES=5 judge test-weakening "$FX/test-weakened.diff" "$REPO#7608@d:U4")
[ "$(f "$j" '[.outcome, .model_calls] | map(tostring) | join(" ")')" = "over-cap 0" ] && [ "$(nl_ "$C/ac.calls")" = "$n0" ] && ok || bad "C15: UNBLOCK_JUDGE_DIFF_MAX_LINES=5 must refuse an 18-line diff: $j"
seq 1 5 > "$C/cap5.txt"
j=$(UNBLOCK_JUDGE_CAP_MAX_LINES=3 judge cap-only "$C/cap5.txt" "$REPO#7608@e:U6")
[ "$(f "$j" '[.outcome, .model_calls] | map(tostring) | join(" ")')" = "over-cap 0" ] && ok || bad "C15: UNBLOCK_JUDGE_CAP_MAX_LINES=3 must refuse a 5-line input: $j"
printf 'CAP_ONLY\n' > "$C/judge-answer"
j=$(judge cap-only "$C/cap5.txt" "$REPO#7608@f:U6")
[ "$(f "$j" '[.answer, .outcome] | join(" ")')" = "CAP_ONLY ok" ] && ok || bad "C15: a 5-line input is under the default cap-only cap 60: $j"
newcase c15-col block-7556.json
col UNBLOCK_REVIEW_BLOCK_LINES_MAX=2
r=$(recs lead-block-unrouted)
[ "$(f "$r" '[(.block_lines | length), .block_lines_truncated] | map(tostring) | join(" ")')" = "2 true" ] && ok || bad "C15: UNBLOCK_REVIEW_BLOCK_LINES_MAX=2 keeps 2 of 3 lines, truncated: $r"
col UNBLOCK_REVIEW_BLOCK_LINES_MAX=0
r=$(recs lead-block-unrouted)
[ "$(f "$r" '[(.block_lines | length), .block_lines_truncated] | map(tostring) | join(" ")')" = "3 false" ] && ok || bad "C15: an out-of-range block-lines cap is the fallback 60: $r"

# ── C16: the tick path (lead BLOCK #4214) ────────────────────────────────────
# bin/unblock.sh tick, the shipped entry point, over the REAL review collector
# (installed at bin/lib/unblock/collectors/review.sh in a scratch harness) and
# the REAL judge seam ubt_stage_judge from judge.sh. The fixture file holds the
# settings read, the lane gate, the model route, a test-only rules engine for
# U6 (UNB-1's rules.sh is not on main) and the decision ledger (claim/record);
# every other jobs read goes to the real jobs-client and the curl stub. The
# tick harness is not in CASES: its installed bin/ files are not writes.
C16_RULES="$RULES"
# tickcase <name> <judge-answer> — a fresh tick harness over cap-7560.json; sets C, NOW16.
tickcase() {
  local f
  newcase "$1" cap-7560.json; CASES="${CASES% "$C"}"
  NOW16=$(date -u -d "$(jq -r '.now // "2026-10-20T16:00:00Z"' "$C/fixture.json")" +%s)
  mkdir -p "$C/h/env" "$C/h/state"; : > "$C/h/env/global.env"; : > "$C/seq.log"
  printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
  for f in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/gh-rest.sh bin/lib/br/record.sh \
           bin/lib/unblock/judge.sh bin/lib/unblock/collectors/review.sh; do
    ( cd "$DIR" && scratch_install_closure "$f" "$C/h" ) >/dev/null || bad "$1: closure $f"
  done
  for f in "$C/h"/bin/lib/unblock/collectors/*.sh; do [ "$(basename "$f")" = review.sh ] || rm -f "$f"; done
  printf '#!/bin/bash\necho "ALERT $*" >> %q\nexit 0\n' "$C/seq.log" > "$C/h/bin/lane-alert.sh"; chmod +x "$C/h/bin/lane-alert.sh"
  jq -nc --argjson fa "$NOW16" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "shadow"}, seeded: {}}' \
    > "$C/h/state/settings-cache.json"
  printf '%s\n' "$2" > "$C/judge-answer"
  { printf 'C16=%q\nC16_RULE=%q\n' "$C" "$(rule U6)"
    cat <<'SH'
c16_log() { printf '%s\n' "$*" >> "$C16/seq.log"; }
setting_get() { case "$1" in unblock.enabled) echo 1 ;; *) return 2 ;; esac; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { echo "lane_role_model $*" >> "$C16/route.calls"; echo stub-model-x; }
declare -F _c16_real_jobs_req >/dev/null || eval "$(declare -f _jobs_req | sed '1s/^_jobs_req /_c16_real_jobs_req /')"
_jobs_req() {
  local k
  case "$1 $2" in
    "POST /api/unblock/decisions/claim")
      c16_log "CLAIM $3"; k=$(jq -r .decision_key <<<"$3"); mkdir -p "$C16/seen"
      if [ -f "$C16/seen/$k" ]; then printf '{"claimed":false,"id":1,"outcome":"would"}'; return 9; fi
      touch "$C16/seen/$k"; printf '{"claimed":true,"id":1}'; return 0 ;;
    "POST /api/unblock/decisions/record") c16_log "RECORD $3"; printf '{"ok":true}'; return 0 ;;
  esac
  _c16_real_jobs_req "$@"
}
ub_rules_eval() {
  local rec p m
  while IFS= read -r rec; do
    printf '%s\n' "$rec" >> "$C16/rules-in.jsonl"
    [ "$(jq -r .kind <<<"$rec")" = "$(jq -r .match.kind "$C16_RULE")" ] || continue
    m=1
    while IFS= read -r p; do [ "$(jq -c "$p" <<<"$rec" 2>/dev/null)" = true ] || m=0; done < <(jq -r '.match.all[]' "$C16_RULE")
    [ "$m" = 1 ] || continue
    jq -c --slurpfile u "$C16_RULE" '$u[0] as $u | {decision_key: ((.repo | gsub("/"; ".")) + "." + (.pr | tostring) + "." + .head + "." + $u.id),
      project: "cromford", repo, subject_kind: "pr", subject: (.repo + "#" + (.pr | tostring)), pr, head,
      stall_class: .kind, rule_id: $u.id, cites: $u.cites, class: $u.class, decision: "act",
      action: {name: $u.action.name, args: {}}, judge: $u.judge, evidence: .}' <<<"$rec"
  done
}
SH
  } > "$C/tick-fx.sh"
}
tick16() {
  env PATH="$C/stub:$PATH" HARNESS="$C/h" UNBLOCK_FIXTURE="$C/tick-fx.sh" UNBLOCK_COLLECTORS_DIR="$C/h/bin/lib/unblock/collectors" \
    HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW="$NOW16" LANE_GATE_CACHE_S=60 UNBLOCK_TIMED=1 \
    JOBS_URL=https://jobs.example.test HARNESS_SECRET=fixture-secret-1 GH_ETAG=0 UNBLOCK_NOW="$NOW16" \
    bash "$C/h/bin/unblock.sh" tick --project cromford > "$C/tick.out" 2>&1
}
c16_records() { sed -n 's/^RECORD //p' "$C/seq.log"; }

( . "$COL" >/dev/null 2>&1; declare -F ub_collect_review >/dev/null ) && ok || bad "C16: collectors/review.sh must define ub_collect_review (collect.sh calls ub_collect_<family>)"
( . "$JUDGE" >/dev/null 2>&1; declare -F ubt_stage_judge >/dev/null ) && ok || bad "C16: judge.sh must define ubt_stage_judge (bin/unblock.sh's judge seam)"

tickcase c16 CAP_ONLY
tick16; rc=$?
L=$(grep '^tick cromford ' "$C/tick.out" | tail -1)
[ "$rc" = 0 ] && ok || bad "C16: tick rc $rc: $(head -c 600 "$C/tick.out")"
[[ $L == *"collectors=1 unwired=0 failed=0 records="[1-9]* ]] && ok || bad "C16: the review family must be wired with records: '$L' log: $(cat "$C/h/logs/unblock.log" 2>/dev/null)"
[[ $L == *"decisions=1 claimed=1 rows=1 deferred=0"* ]] && ok || bad "C16: one U6 judge decision, claimed and recorded, none deferred: '$L'"
! grep -q 'unwired review\|deferred ubt_stage_judge\|seam not loaded' "$C/h/logs/unblock.log" 2>/dev/null && ok || bad "C16: unwired/deferred line: $(cat "$C/h/logs/unblock.log")"
[ "$(grep -c collector-meta "$C/rules-in.jsonl" 2>/dev/null)" = 0 ] && grep -q '"kind":"lead-block-cap-only"' "$C/rules-in.jsonl" 2>/dev/null && ok || bad "C16: the rules get the stall records and no meta line: $(cat "$C/rules-in.jsonl" 2>/dev/null)"
[ "$(nl_ "$C/ac.calls")" = 1 ] && grep -q '^stage=unblock-judge project=fleet model=stub-model-x .* lane=unblock guard=unblock-judge ' "$C/ac.calls" && ok || bad "C16: ubt_stage_judge must make 1 judge call on the routed model: $(cat "$C/ac.calls")"
grep -qx 'lane_role_model unblock.judge cromford' "$C/route.calls" && ok || bad "C16: the tick reads the unblock.judge route with the project: $(cat "$C/route.calls")"
R=$(c16_records)
[ "$(f "$R" '[.outcome, .model_calls, .cost_usd] | map(tostring) | join(" ")')" = "would 1 0.0123" ] && f "$R" .outcome_detail | grep -q 'cap-only=CAP_ONLY (ok): proceed fix_round' && ok || bad "C16: the record of a CAP_ONLY answer: $R"
[ "$(grep -c '^CLAIM ' "$C/seq.log")" = 1 ] && ok || bad "C16: one claim: $(cat "$C/seq.log")"
tick16
[ "$(nl_ "$C/ac.calls")" = 1 ] && [ "$(grep -c '^RECORD ' "$C/seq.log")" = 1 ] && grep -q 'claimed=0 rows=0' "$C/tick.out" && ok || bad "C16: a second tick is a 409 and 0 judge calls: $(cat "$C/tick.out")"
[ "$(nl_ "$C/writes.txt")" = 0 ] && ok || bad "C16: GitHub or worker writes: $(cat "$C/writes.txt")"

tickcase c16-unsure UNSURE
tick16
R=$(c16_records)
[ "$(f "$R" '[.outcome, .model_calls] | map(tostring) | join(" ")')" = "escalated 1" ] && f "$R" .outcome_detail | grep -q 'cap-only=UNSURE (ok): escalate' && ok || bad "C16-unsure: an UNSURE answer records escalated: $R"
[ "$(nl_ "$C/writes.txt")" = 0 ] && ok || bad "C16-unsure: GitHub or worker writes: $(cat "$C/writes.txt")"

# ubt_stage_judge directly: a block answer, a non-path input, an empty input.
newcase c16-seam ""
DJ=$(jq -nc '{decision_key: "k.1", action: {name: "x"}, judge: {question: "test-weakening", input: ".diff", proceed_on: ["LEGIT"], block_on: ["WEAKENED"], block_cites: ["G16"]},
  evidence: {diff: "--- a/t\n+++ b/t\n-assert 1\n"}}')
printf 'WEAKENED\n' > "$C/judge-answer"
j=$( export HARNESS="$C/h" HARNESS_TEST_SANDBOX=1 UNBLOCK_FIXTURE="$C/fixture.sh"; . "$JUDGE"; ubt_stage_judge "$DJ" stub-model-x )
[ "$(f "$j" '[.outcome, .model_calls, .judge.answer] | map(tostring) | join(" ")')" = "refused 1 WEAKENED" ] && f "$j" .detail | grep -q 'block cites G16' && ok || bad "C16-seam: WEAKENED is refused with the cite: $j"
n0=$(nl_ "$C/ac.calls")
j=$( export HARNESS="$C/h"; . "$JUDGE"; ubt_stage_judge "$(jq -c '.judge.input = "env"' <<<"$DJ")" stub-model-x )
[ "$(f "$j" '[.outcome, .model_calls] | map(tostring) | join(" ")')" = "escalated 0" ] && ok || bad "C16-seam: a non-path input is escalated with 0 calls: $j"
j=$( export HARNESS="$C/h"; . "$JUDGE"; ubt_stage_judge "$(jq -c '.evidence.diff = ""' <<<"$DJ")" stub-model-x )
[ "$(f "$j" '[.outcome, .model_calls] | map(tostring) | join(" ")')" = "escalated 0" ] && [ "$(nl_ "$C/ac.calls")" = "$n0" ] && ok || bad "C16-seam: an empty input is escalated with 0 calls: $j"
j=$( export HARNESS="$C/h"; . "$JUDGE"; ubt_stage_judge "$(jq -c '.judge.question = "other"' <<<"$DJ")" stub-model-x )
[ "$(f "$j" .outcome)" = failed ] && ok || bad "C16-seam: an unknown question is failed: $j"

# ── C13: the budget: 0 writes, 0 vendor calls outside the stubs ──────────────
# state/gh-rest-ledger and state/lane-gate are bin/lib/gh-rest.sh's own quota
# bookkeeping (every gh_rest caller writes them); they are not the collector's.
W=0; G=0; K=0; X=""
for c in $CASES; do
  W=$((W + $(nl_ "$c/writes.txt"))); G=$((G + $(nl_ "$c/gh.calls"))); K=$((K + $(nl_ "$c/curl.calls")))
  if [ -d "$c/h" ]; then
    X="$X$(find "$c/h" -type f -newer "$c/fixture.json" ! -path '*/logs/*' ! -path '*/state/unblock-judge/*' ! -path '*/locks/*' ! -path '*/state/gh-rest-ledger/*' ! -path '*/state/lane-gate/*' ! -name agent-call.sh ! -path '*/catalog/*' 2>/dev/null)"
  fi
done
[ "$W" = 0 ] && ok || bad "C13: $W GitHub or worker writes: $(cat "$T"/*/writes.txt)"
[ "$G" -gt 0 ] && [ "$K" -gt 0 ] && ok || bad "C13: the stubs answered no read (gh $G, worker $K): the suite ran nothing"
[ -z "$X" ] && ok || bad "C13: files written outside the log and the judge ledger: $X"

echo "unblock-review-rules: PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" = 0 ]
