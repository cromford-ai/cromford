#!/bin/bash
# tests/unblock-review-shadow.bh-8532-test.sh — BH-8532 (rest of BH-7724):
# "Shadow rows for the review family, with judge answers recorded and priced"
# (docs/plan/PR_UNBLOCK_AGENT_PLAN_2026-10-20.html, Rollout row S2).
#
# One shipped entry point, end to end: bin/unblock.sh tick --project
# cromford in shadow mode, over the REAL review collector
# (collectors/review.sh), the REAL rules engine (rules.sh) with the shipped
# catalog/unblock-rules.d/*.json, the REAL act.sh and the REAL judge seam
# ubt_stage_judge (judge.sh). There is NO stand-in ub_rules_eval here: that is
# the point of the suite (bh-7724 C16 uses one, bh-8418 S3 feeds synthetic
# records). The input is the four shipped review fixtures merged into one
# corpus: block-7556 (U5), cap-7560 (U6), stuck-request (U7, #7590) and
# stale-cr-7553 (U11). The MERGE PR #7601 must give no claim.
#
# CASES
#   S1  one tick: 4 claims {U5,U6,U7,U11}, each mode shadow, each outcome would.
#   S2  the judge answer is recorded and priced (U6 model_calls 1, cost_usd
#       0.0123 from agent-call's <out>.json), paid once (a second tick is a 409
#       and 0 calls); UNSURE -> escalated, priced; empty -> escalated, ledger
#       `empty`, no retry.
#   S3  shadow writes nothing outside the ledger, also with UNBLOCK_ACT=1.
#   B   budget (BH-7563): curl only to the jobs stub, 0 claude/flyctl calls.
#
# STUBS, per case under $T/<case> (no shared state): `gh` and `curl` answer GETs
# from the case's fixture.json and log a write (any non-GET) to writes.txt;
# $HARNESS/bin/agent-call.sh logs to ac.calls, answers from judge-answer and
# writes {"total_cost_usd":0.0123} to <out>.json; `claude` and `flyctl` log to
# vendor.calls and exit 7. UNBLOCK_FIXTURE gives only setting_get,
# lane_gate_or_exit, lane_env_apply, lane_role_model and the two ledger POSTs
# (claim is UNIQUE on decision_key: a seen key answers rc 9, the 409).
#
# HAND MUTATIONS (BH-8532 T5, on a scratch copy of the repo, each turns a
# case red): (a) drop `judge` from bin/unblock.sh's `for m in rules judge
# card` -> S1 deferred=1; (b) no collectors/review.sh -> S1 records=0;
# (c) the agent-call stub writes no <out>.json -> S2 cost_usd 0.
# Run from anywhere: tests/unblock-review-shadow.bh-8532-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for b in jq flock; do
  command -v "$b" >/dev/null || { echo "SKIP: unblock-review-shadow: $b missing"; exit 0; }
done

FX="$DIR/tests/fixtures/unblock"
RULES="$DIR/catalog/unblock-rules.d"
NOWISO=2026-10-20T16:00:00Z
NOW=$(date -u -d "$NOWISO" +%s)
CASES=""

# The merged review corpus, composed once from the four shipped fixtures (read only).
jq -s --arg now "$NOWISO" '{
    repo: .[0].repo, now: $now,
    pulls: (map(.pulls // []) | add),
    search: {total_count: (map(.search.items // []) | add | length), incomplete_results: false,
             items: (map(.search.items // []) | add)},
    reviews: (map(.reviews // {}) | add), comments: (map(.comments // {}) | add),
    verdicts: (map(.verdicts // {}) | add), artifacts: (map(.artifacts // {}) | add),
    lead_reviews_running: {as_of: $now, truncated: false,
                           requests: (map(.lead_reviews_running.requests // []) | add)}
  }' "$FX/block-7556.json" "$FX/cap-7560.json" "$FX/stuck-request.json" "$FX/stale-cr-7553.json" \
  > "$T/corpus.json" || { echo "FAIL: the corpus merge failed"; exit 1; }

# mkharness <case> <judge-answer> — a fresh scratch harness for one case; sets C.
mkharness() {
  local f
  C="$T/$1"; CASES="$CASES $C"
  mkdir -p "$C/stub" "$C/h/bin" "$C/h/logs" "$C/h/locks" "$C/h/state" "$C/h/env" "$C/h/catalog/prompts" "$C/h/catalog/unblock-rules.d"
  cp "$T/corpus.json" "$C/fixture.json"
  : > "$C/gh.calls"; : > "$C/curl.calls"; : > "$C/writes.txt"; : > "$C/ac.calls"; : > "$C/route.calls"
  : > "$C/vendor.calls"; : > "$C/seq.log"; : > "$C/h/env/global.env"
  printf '%s\n' "$2" > "$C/judge-answer"
  for f in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/gh-rest.sh bin/lib/br/record.sh \
           bin/lib/unblock/rules.sh bin/lib/unblock/act.sh bin/lib/unblock/judge.sh bin/lib/unblock/collectors/review.sh; do
    ( cd "$DIR" && scratch_install_closure "$f" "$C/h" ) >/dev/null || bad "$1: closure $f"
  done
  for f in "$C/h"/bin/lib/unblock/collectors/*.sh; do [ "$(basename "$f")" = review.sh ] || rm -f "$f"; done
  cp "$RULES"/*.json "$C/h/catalog/unblock-rules.d/"
  cp "$DIR/catalog/prompts/unblock-judge.md" "$C/h/catalog/prompts/"
  printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
  jq -nc --argjson fa "$NOW" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "shadow", "unblock.enabled": "1"}, seeded: {}}' \
    > "$C/h/state/settings-cache.json"
  printf '#!/bin/bash\necho "ALERT $*" >> %q\nexit 0\n' "$C/seq.log" > "$C/h/bin/lane-alert.sh"
  for f in claude flyctl; do printf '#!/bin/bash\necho "%s $*" >> %q\nexit 7\n' "$f" "$C/vendor.calls" > "$C/stub/$f"; done
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
echo "$m $url" >> "$C/curl.calls"
p="${url#"$JOBS_URL"}"
if [ "$m" != GET ]; then echo "curl $m $p" >> "$C/writes.txt"; printf '{"error":"write refused by the stub"}\n500'; exit 0; fi
path="${p%%\?*}"; key=""
case "$path" in
  /api/verdicts) key="verdicts.$(sed -n 's/.*[?&]pr=\([0-9]*\).*/\1/p' <<<"$p")" ;;
  /api/jobs/*/artifacts) j="${path#/api/jobs/}"; key="artifacts.${j%/artifacts}" ;;
  /api/lead-reviews) key=lead_reviews_running ;;
esac
body=""; [ -z "$key" ] || body=$(jq -c --arg k "$key" 'getpath($k | split(".")) // empty' "$C/fixture.json")
if [ -z "$body" ]; then printf '{"error":"not found"}\n404'; exit 0; fi
case "$key" in artifacts.*) body=$(jq -c '{artifacts: [to_entries[] | {artifact_kind: .key, detail: (.value | tojson)}]}' <<<"$body") ;; esac
printf '%s\n200' "$body"
EOF
  printf '#!/bin/bash\nC=%q\n' "$C" > "$C/h/bin/agent-call.sh"
  cat >> "$C/h/bin/agent-call.sh" <<'EOF'
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
echo "stage=$1 project=$2 model=$3 lane=${AGENT_CALL_LANE:-} guard=${AGENT_CALL_GUARD_STAGE:-}" >> "$C/ac.calls"
cat "$C/judge-answer" > "$5"
printf '{"result":"stub","total_cost_usd":0.0123}' > "$5.json"
exit 0
EOF
  chmod +x "$C/stub"/* "$C/h/bin/agent-call.sh" "$C/h/bin/lane-alert.sh"
  { printf 'UBS_C=%q\n' "$C"
    cat <<'SH'
setting_get() { case "$1" in unblock.enabled) echo 1 ;; *) return 2 ;; esac; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { echo "lane_role_model $*" >> "$UBS_C/route.calls"; echo stub-model-x; }
declare -F _ubs_real_jobs_req >/dev/null || eval "$(declare -f _jobs_req | sed '1s/^_jobs_req /_ubs_real_jobs_req /')"
_jobs_req() {
  local k
  case "$1 $2" in
    "POST /api/unblock/decisions/claim")
      printf 'CLAIM %s\n' "$3" >> "$UBS_C/seq.log"; k=$(jq -r .decision_key <<<"$3"); mkdir -p "$UBS_C/seen"
      if [ -f "$UBS_C/seen/$k" ]; then printf '{"claimed":false,"id":1,"outcome":"would"}'; return 9; fi
      touch "$UBS_C/seen/$k"; printf '{"claimed":true,"id":1}'; return 0 ;;
    "POST /api/unblock/decisions/record") printf 'RECORD %s\n' "$3" >> "$UBS_C/seq.log"; printf '{"ok":true}'; return 0 ;;
  esac
  _ubs_real_jobs_req "$@"
}
SH
  } > "$C/tick-fx.sh"
}

# tick [VAR=value...] — one shipped tick over the case's harness; output in tick.out.
tick() {
  env PATH="$C/stub:$PATH" HARNESS="$C/h" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW="$NOW" UNBLOCK_TIMED=1 \
    UNBLOCK_NOW="$NOW" UNBLOCK_FIXTURE="$C/tick-fx.sh" UNBLOCK_COLLECTORS_DIR="$C/h/bin/lib/unblock/collectors" \
    JOBS_URL=https://jobs.example.test HARNESS_SECRET=fixture-secret-1 GH_ETAG=0 "$@" \
    bash "$C/h/bin/unblock.sh" tick --project cromford > "$C/tick.out" 2>&1
}
tline()   { grep '^tick cromford ' "$C/tick.out" | tail -1; }
claims()  { sed -n 's/^CLAIM //p' "$C/seq.log"; }
records() { sed -n 's/^RECORD //p' "$C/seq.log"; }
# rec <rule-id> — the record body of the claim for that rule.
rec() {
  local k; k=$(claims | jq -r --arg r "$1" 'select(.rule_id == $r) | .decision_key' | head -1)
  [ -n "$k" ] || return 0
  records | jq -c --arg k "$k" 'select(.decision_key == $k)' | head -1
}
f()   { jq -r "$2" <<<"$1" 2>/dev/null; }
nl_() { grep -c . "$1" 2>/dev/null || true; }
ulog() { cat "$C/h/logs/unblock.log" 2>/dev/null; }

# ── S1: one shadow tick writes one would row per review rule ─────────────────
mkharness s1 CAP_ONLY
tick; rc=$?
L=$(tline)
[ "$rc" = 0 ] && ok || bad "S1: tick rc $rc: $(head -c 600 "$C/tick.out")"
[[ $L == *"mode=shadow collectors=1 unwired=0 failed=0 records=4 decisions=4 claimed=4 rows=4 deferred=0" ]] && ok \
  || bad "S1: tick line '$L'; log: $(ulog)"
[ "$(claims | jq -r .rule_id | sort | paste -sd' ' -)" = "U11 U5 U6 U7" ] && ok || bad "S1: want one claim each for U11 U5 U6 U7: $(claims)"
[ "$(claims | jq -r '[.mode, .decision] | join(" ")' | sort -u)" = "shadow act" ] && ok || bad "S1: every claim must be mode shadow, decision act: $(claims)"
for u in U5 U6 U7 U11; do
  want=$(jq -c .cites "$(ls "$RULES"/"$u"-*.json | head -1)")
  got=$(claims | jq -c --arg r "$u" 'select(.rule_id == $r) | .rule_cites')
  [ -n "$got" ] && [ "$got" != "[]" ] && [ "$got" = "$want" ] && ok || bad "S1: $u rule_cites '$got', want the rule file's '$want'"
done
[ "$(claims | jq -r '[.rule_id, .subject] | join(" ")' | sort | paste -sd, -)" \
  = "U11 example-org/cromford#7553,U5 example-org/cromford#7556,U6 example-org/cromford#7560,U7 example-org/cromford#7590" ] && ok \
  || bad "S1: rule subjects: $(claims | jq -r '[.rule_id, .subject] | join(" ")')"
[ "$(claims | grep -c '#7601')" = 0 ] && ok || bad "S1: the MERGE PR #7601 must get no claim"
[ "$(records | jq -r .outcome | sort -u)" = would ] && [ "$(records | grep -c .)" = 4 ] && ok || bad "S1: 4 records, each outcome would: $(records)"
[ "$(f "$(rec U5)" .outcome_detail)" = WOULD_POST_BLOCK ] && ok || bad "S1: U5 detail: $(rec U5)"
[ "$(f "$(rec U7)" .outcome_detail)" = WOULD_LEAD_REREQUEST ] && ok || bad "S1: U7 detail: $(rec U7)"
[ "$(f "$(rec U11)" .outcome_detail)" = WOULD_DISMISS_REVIEW ] && ok || bad "S1: U11 detail: $(rec U11)"
f "$(rec U6)" .outcome_detail | grep -q 'judge cap-only=CAP_ONLY (ok): proceed fix_round' && ok || bad "S1: U6 detail: $(rec U6)"
for a in "U5 WOULD_POST_BLOCK" "U7 WOULD_LEAD_REREQUEST" "U11 WOULD_DISMISS_REVIEW"; do
  ulog | grep -q " act cromford .* $a would" && ok || bad "S1: no 'act ... $a' log line: $(ulog)"
done

# ── S2: the judge answer is recorded and priced, and paid once ───────────────
[ "$(f "$(rec U6)" '[.model_calls, .cost_usd] | map(tostring) | join(" ")')" = "1 0.0123" ] && ok || bad "S2: U6 must record 1 call at 0.0123: $(rec U6)"
for u in U5 U7 U11; do
  [ "$(f "$(rec "$u")" '[.model_calls, .cost_usd] | map(tostring) | join(" ")')" = "0 0" ] && ok || bad "S2: $u must record 0 calls, 0 cost: $(rec "$u")"
done
[ "$(nl_ "$C/ac.calls")" = 1 ] && grep -q '^stage=unblock-judge project=fleet model=stub-model-x lane=unblock guard=unblock-judge$' "$C/ac.calls" && ok \
  || bad "S2: want 1 judge call on the routed model: $(cat "$C/ac.calls")"
grep -qx 'lane_role_model unblock.judge cromford' "$C/route.calls" && ok || bad "S2: the route read: $(cat "$C/route.calls")"
tick; rc=$?
L=$(tline)
[ "$rc" = 0 ] && [[ $L == *"claimed=0 rows=0"* ]] && ok || bad "S2: a second tick must claim 0 and record 0: '$L'"
[ "$(nl_ "$C/ac.calls")" = 1 ] && [ "$(records | grep -c .)" = 4 ] && ok || bad "S2: the second tick spent again: $(cat "$C/ac.calls")"

mkharness s2-unsure UNSURE
tick
R=$(rec U6)
[ "$(f "$R" '[.outcome, .model_calls, .cost_usd] | map(tostring) | join(" ")')" = "escalated 1 0.0123" ] && f "$R" .outcome_detail | grep -q 'cap-only=UNSURE (ok): escalate' && ok \
  || bad "S2-unsure: U6 must record escalated, priced: $R"
[ "$(for u in U5 U7 U11; do f "$(rec "$u")" .outcome; done | sort -u)" = would ] && ok || bad "S2-unsure: U5 U7 U11 must still record would: $(records)"

mkharness s2-empty ""
tick
R=$(rec U6)
[ "$(f "$R" '[.outcome, .model_calls] | map(tostring) | join(" ")')" = "escalated 1" ] && ok || bad "S2-empty: U6 must record escalated with 1 call: $R"
[ "$(cat "$C"/h/state/unblock-judge/*.json 2>/dev/null | jq -r .outcome)" = empty ] && ok \
  || bad "S2-empty: the judge ledger must say empty: $(cat "$C"/h/state/unblock-judge/*.json 2>/dev/null)"
tick
[ "$(nl_ "$C/ac.calls")" = 1 ] && ok || bad "S2-empty: an empty answer is terminal, no retry: $(cat "$C/ac.calls")"

# ── S3: shadow with UNBLOCK_ACT=1 is still shadow ────────────────────────────
mkharness s3-act CAP_ONLY
tick UNBLOCK_ACT=1
[[ $(tline) == *"claimed=4 rows=4 deferred=0" ]] && ok || bad "S3: tick line '$(tline)'"
[ "$(claims | jq -r .mode | sort -u)" = shadow ] && ok || bad "S3: UNBLOCK_ACT=1 under mode shadow must claim shadow: $(claims)"
[ "$(records | jq -r .outcome | sort -u)" = would ] && ok || bad "S3: UNBLOCK_ACT=1 under mode shadow must record would: $(records)"

# ── S3 + B: 0 writes in every case, 0 real vendor calls ──────────────────────
W=0; G=0; K=0; V=0; X=""
for c in $CASES; do
  W=$((W + $(nl_ "$c/writes.txt"))); G=$((G + $(nl_ "$c/gh.calls"))); K=$((K + $(nl_ "$c/curl.calls"))); V=$((V + $(nl_ "$c/vendor.calls")))
  X="$X$(grep -v '^[A-Z]* https://jobs\.example\.test/' "$c/curl.calls")"
done
[ "$W" = 0 ] && ok || bad "S3: $W GitHub or worker writes: $(cat "$T"/*/writes.txt)"
[ "$G" -gt 0 ] && [ "$K" -gt 0 ] && ok || bad "B: the stubs answered no read (gh $G, worker $K): the suite ran nothing"
[ -z "$X" ] && ok || bad "B: curl outside the jobs stub: $X"
[ "$V" = 0 ] && ok || bad "B: $V real vendor calls: $(cat "$T"/*/vendor.calls)"

echo "unblock-review-shadow: PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" = 0 ]
