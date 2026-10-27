#!/bin/bash
# tests/unblock-queue-rules.bh-7723-test.sh — BH-7723 (UNB-1): the queue family
# of the unblock agent, in shadow. bin/lib/unblock/collectors/queue.sh reads
# GitHub (gh_rest GET only), the #7714 batch_failure tool, the verdict rows and
# the conductor memory and prints stall records; bin/lib/unblock/rules.sh
# loads catalog/unblock-rules.d/*.json and prints one decision per stall.
#
# Every case runs the production pipe `ub_collect_queue | ub_rules_eval`, then
# `ub_rules_would_lines`, in its own scratch dir, against the SHIPPED rule files
# in catalog/unblock-rules.d. Stubs: a `gh` on PATH that answers from the case
# fixture and logs every call with its method; a fake mcp/tools/batch-failure.mjs
# run by the real node through the collector's seam; vd_standing,
# mc_attempt_has, mc_requeued_mark and setting_get as shell functions; an
# agent-call/claude stub that logs any model call. The clock is UNBLOCK_NOW.
#
#   C1  batch #7699: #7617 U1-batch-culprit (cites G2,G12,G7, WOULD_POST_BLOCK,
#       args.source agent); #7592 #7666 #7588 #7363 U2-bystander-requeue;
#       5 WOULD lines; 0 non-GET calls; 0 model calls.
#       C1b two culprits: 0 act. C1c #7617 pushed a new head: escalate.
#       C1d #7592 already requeued on its head: no U2 for it.
#   C2  dead shards #7612/#7613: three green members U3; #7604 (own CI red)
#       escalates with `.own_ci == "green"` under failed.
#       C2b batch failed with no culprit: 0 act.
#   C3  #7609 with standing row "1": U4 (cites G1, judge null). project-2,
#       no row: escalate naming `.standing_approval == "1"`, 0 WOULD lines.
#       C3b idle 19 min: no U4; idle 20: U4. C3c a check running: no U4.
#       C3d an open CHANGES_REQUESTED: no U4; one the same reviewer approved
#       over: U4. C3e a test file in the diff: U4 with the test-weakening judge.
#       C3f vd_standing rc 2: one queue-unreadable record names #7609 #7620.
#   C4  #7588's verdict on an older head: no U2, escalate. C4b vd_standing rc 2:
#       the verdict predicate is unknown. C4c no conductor lib: 0 act.
#   C5  the pipe twice into a stub ledger (UNIQUE decision_key): run 1 inserts
#       N rows, run 2 inserts 0, the keys are byte-identical.
#   C6  a record carrying `<!-- tackler:` and a PR labelled staff:tackler: both
#       dropped by the collector.
#   C7  loader refusals: a duplicate id, an id that is not the stem, a missing
#       key, bad JSON, a cite not in the cites file, a missing cites file, a
#       predicate that does not compile, a predicate that reads input: rc 2,
#       nothing on stdout, ub_rules_eval prints no decision.
#   C8  the closed-PR list answers 500: one queue-unreadable record, 0 act.
#       C8b the batch_failure tool file is missing: one queue-unreadable record.
#       C8c the tool answers complete:false: inputs_unreadable names it, 0 act.
#   C9  ub_rules_load on catalog/unblock-rules.d: every shipped rule, U1-U4,
#       the review family's U5 U6 U7 U11 (BH-7724) and U8 U9 U10 U12, in
#       priority order.
#   C10 bin/unblock.sh tick, sandboxed, with the real queue collector, rules
#       engine and act layer in shadow: collectors=1 unwired=0, U1/U2 claims
#       with object actions, WOULD_ lines from act.sh, 0 bad-input records.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/unblock-queue-rules.bh-7723-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }

FX="$SRC/tests/fixtures/unblock"
RULES="$SRC/catalog/unblock-rules.d"
R=example-org/cromford

# One scratch harness per case: the two libs and gh-rest by their closures, the
# MCP config module the seam imports, a fake batch_failure tool, the stubs.
mkcase() { # mkcase <name> -> prints the case dir
  local C="$T/$1"
  mkdir -p "$C/h/mcp/tools" "$C/h/mcp/lib" "$C/bin" "$C/h/logs" "$C/h/state"
  scratch_install_closure bin/lib/unblock/collectors/queue.sh "$C/h" >/dev/null || return 1
  scratch_install_closure bin/lib/unblock/rules.sh "$C/h" >/dev/null || return 1
  scratch_install_closure bin/lib/gh-rest.sh "$C/h" >/dev/null || return 1
  cp "$SRC/mcp/lib/config.mjs" "$C/h/mcp/lib/config.mjs"
  cat > "$C/h/mcp/tools/batch-failure.mjs" <<'JS'
import { readFileSync, appendFileSync } from 'node:fs';
const text = (t) => [{ type: 'text', text: t }];
export const tools = [{
  name: 'batch_failure', kind: 'read', inputSchema: { type: 'object' },
  handler: async (a, ctx) => {
    appendFileSync(process.env.BF_LOG, `${a.repo} ${a.draft} ${typeof a.draft} ${ctx.cfg.url}\n`);
    const fx = JSON.parse(readFileSync(process.env.GH_FX, 'utf8'));
    const v = fx.batch_failure[String(a.draft)];
    if (!v) return { content: text('no such draft'), isError: true };
    return { content: text(JSON.stringify(v)), structuredContent: v };
  },
}];
JS
  cat > "$C/bin/gh" <<'SH'
#!/bin/bash
m=GET; p=
while [ $# -gt 0 ]; do
  case "$1" in api|-i) ;; -X) m="$2"; shift ;; -H) shift ;; *) p="$1" ;; esac
  shift
done
echo "$m $p" >> "$GH_LOG"
if [ "$m" != GET ]; then printf 'HTTP/2 405\r\n\r\n{"message":"fixture: writes refused"}\n'; exit 1; fi
st=$(jq -r --arg p "$p" '.gh_status[$p] // empty' "$GH_FX")
if [ -n "$st" ]; then printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n\r\n{"message":"fixture error"}\n' "$st"; exit 1; fi
if jq -e --arg p "$p" '.gh | has($p)' "$GH_FX" >/dev/null; then
  printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; jq -c --arg p "$p" '.gh[$p]' "$GH_FX"; exit 0
fi
printf 'HTTP/2 404\r\ncontent-type: application/json\r\n\r\n{"message":"Not Found"}\n'; exit 1
SH
  for s in claude agent-call.sh; do
    printf '#!/bin/bash\necho "%s $*" >> "$MODEL_LOG"\n' "$s" > "$C/bin/$s"
  done
  chmod +x "$C/bin/"*
  jq -n '[range(1;22)] | map({key: "G\(.)", value: {title: "fixture guardrail G\(.)"}}) | from_entries' > "$C/cites.json"
  : > "$C/gh.log"; : > "$C/calls.log"; : > "$C/bf.log"; : > "$C/model.log"
  printf '%s' "$C"
}

# fx <case dir> <base fixture> [jq transform] -> the case fixture path
fx() {
  jq "${3:-.}" "$FX/$2" > "$1/fx.json" || return 1
  printf '%s' "$1/fx.json"
}

# run_pipe <case dir> <project> [slug] [pre-commands]: collect | eval | would.
run_pipe() {
  local C="$1" proj="$2" slug="${3:-$R}" pre="${4:-}"
  (
    export HARNESS="$C/h" GH_FX="$C/fx.json" GH_LOG="$C/gh.log" CALLS="$C/calls.log" BF_LOG="$C/bf.log"
    export MODEL_LOG="$C/model.log" PATH="$C/bin:$PATH" GH_ETAG=0 TMPDIR="$C"
    export HARNESS_CONSOLE_URL=http://192.0.2.10 UNBLOCK_CITES_FILE="$C/cites.json"
    UNBLOCK_NOW=$(date -u -d "$(jq -r .now "$GH_FX")" +%s); export UNBLOCK_NOW
    . "$HARNESS/bin/lib/gh-rest.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/collectors/queue.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
    vd_standing() {
      echo "vd $1#$2 $3" >> "$CALLS"
      [ -n "${VD_RC:-}" ] && return "$VD_RC"
      local l; l=$(jq -r --arg k "$1#$2 $3" '.verdicts[$k] // empty' "$GH_FX")
      [ -n "$l" ] || return 1
      printf '%s\n' "$l"
    }
    mc_attempt_has() { echo "mc_has $1" >> "$CALLS"; jq -e --arg l "$1" '.attempts | index($l) != null' "$GH_FX" >/dev/null; }
    mc_requeued_mark() { echo "mc_rq $1 $2" >> "$CALLS"; jq -r --arg k "$1 $2" '.requeued[$k] // empty' "$GH_FX"; }
    setting_get() {
      echo "set $1" >> "$CALLS"
      local v; v=$(jq -r --arg k "$1" '.settings[$k] // empty' "$GH_FX")
      [ -n "$v" ] || return 2
      printf '%s' "$v"
    }
    eval "$pre"
    ub_collect_queue "$proj" "$slug" | tee "$C/stalls.jsonl" | ub_rules_eval "$RULES" > "$C/decisions.jsonl"
    echo "${PIPESTATUS[0]} ${PIPESTATUS[2]}" > "$C/rc"
    ub_rules_would_lines < "$C/decisions.jsonl" > "$C/would.txt"
  )
}

# dec <case dir> <pr> <jq filter>: the filter over that PR's decision.
dec() { jq -rs --arg s "$R#$2" "map(select(.subject == \$s)) | if length == 1 then .[0] | $3 else \"count=\(length)\" end" "$1/decisions.jsonl"; }
acts() { jq -s '[.[] | select(.decision == "act")] | length' "$1/decisions.jsonl"; }
nonget() { grep -cv '^GET ' "$1/gh.log"; }

# ---------------------------------------------------------------- C1
C=$(mkcase c1) || exit 1; fx "$C" batch-7699.json >/dev/null; run_pipe "$C" cromford
check "C1 pipe rc (collect, eval)" "$(cat "$C/rc")" "0 0"
check "C1 #7617 U1" "$(dec "$C" 7617 .rule_id)" "U1-batch-culprit"
check "C1 #7617 cites" "$(dec "$C" 7617 '.cites | join(",")')" "G2,G12,G7"
check "C1 #7617 would" "$(dec "$C" 7617 .would)" "WOULD_POST_BLOCK"
check "C1 #7617 args.source agent" "$(dec "$C" 7617 .action.args.source)" "agent"
check "C1 #7617 args.verdict BLOCK, head resolved" "$(dec "$C" 7617 '"\(.action.args.verdict) \(.action.args.head)"')" "BLOCK $(jq -r '.heads["7617"]' "$FX/batch-7699.json")"
check "C1 #7617 fail_lines name the line" "$(dec "$C" 7617 '.action.args.lines | map(select(test("remote-results-retention.sh:79"))) | length > 0')" "true"
for n in 7592 7666 7588 7363; do
  check "C1 #$n U2 WOULD_REQUEUE" "$(dec "$C" $n '"\(.rule_id) \(.would)"')" "U2-bystander-requeue WOULD_REQUEUE"
done
check "C1 5 WOULD lines" "$(wc -l < "$C/would.txt" | tr -d ' ')" "5"
check "C1 WOULD_POST_BLOCK line" "$(grep -c "^WOULD_POST_BLOCK U1-batch-culprit $R#7617 7617aaaaaaaa key=[0-9a-f]\{12\} cites=G2,G12,G7$" "$C/would.txt")" "1"
check "C1 WOULD_REQUEUE lines" "$(grep -c "^WOULD_REQUEUE U2-bystander-requeue $R#" "$C/would.txt")" "4"
check "C1 0 non-GET calls" "$(nonget "$C")" "0"
check "C1 0 model calls" "$(wc -l < "$C/model.log" | tr -d ' ')" "0"
check "C1 one batch_failure call, draft 7699 as a number" "$(cat "$C/bf.log")" "$R 7699 number http://192.0.2.10"
check "C1 the old draft #7601 and the merged #7650 are not read" "$(grep -c 'pulls/7601\|pulls/7650' "$C/gh.log")" "0"
check "C1 decision keys are sha256" "$(jq -rs 'length == 5 and ([.[].decision_key | test("^[0-9a-f]{64}$")] | all)' "$C/decisions.jsonl")" "true"

C=$(mkcase c1b) || exit 1; fx "$C" batch-7699.json '.batch_failure["7699"].culprits = [7617, 7592]' >/dev/null; run_pipe "$C" cromford
check "C1b two culprits: 0 act" "$(acts "$C")" "0"
check "C1b two culprits: #7617 escalates" "$(dec "$C" 7617 .decision)" "escalate"

C=$(mkcase c1c) || exit 1
fx "$C" batch-7699.json '.gh["repos/example-org/cromford/pulls/7617"].head.sha = "7617111111111111111111111111111111111111"' >/dev/null
run_pipe "$C" cromford
check "C1c new head: #7617 escalates" "$(dec "$C" 7617 '"\(.decision) \(.head)"')" "escalate 7617111111111111111111111111111111111111"
check "C1c new head: the U1 near miss names the eject" "$(dec "$C" 7617 '.near_misses[] | select(.rule == "U1-batch-culprit") | .failed | index(".ejected_on_head == true") != null')" "true"

C=$(mkcase c1d) || exit 1
fx "$C" batch-7699.json '.requeued = {("example-org/cromford#7592 " + .heads["7592"]): "1760950000"}' >/dev/null
run_pipe "$C" cromford
check "C1d requeued on head: #7592 not U2" "$(dec "$C" 7592 .decision)" "escalate"
check "C1d the others still U2" "$(dec "$C" 7666 .rule_id)" "U2-bystander-requeue"

# ---------------------------------------------------------------- C2
C=$(mkcase c2) || exit 1; fx "$C" ejects-20261019.json >/dev/null; run_pipe "$C" cromford
for n in 7590 7595 7600; do
  check "C2 #$n U3" "$(dec "$C" $n '"\(.rule_id) \(.would) \(.action.args.note)"')" "U3-dead-shard-requeue WOULD_REQUEUE dead shards; shard cap ticket #7620"
done
check "C2 #7604 own CI red: escalate" "$(dec "$C" 7604 .decision)" "escalate"
check "C2 #7604 near miss names own_ci" "$(dec "$C" 7604 '.near_misses[] | select(.rule == "U3-dead-shard-requeue") | .failed | join("|")')" '.own_ci == "green"'
check "C2 batch_failure read once per draft" "$(wc -l < "$C/bf.log" | tr -d ' ')" "2"
check "C2 0 non-GET calls" "$(nonget "$C")" "0"

C=$(mkcase c2b) || exit 1
fx "$C" batch-7699.json '.batch_failure["7699"] |= (.culprits = [] | .culprit_unknown = true | .failed_checks[0].culprits = [])' >/dev/null
run_pipe "$C" cromford
check "C2b unknown culprit: 0 act" "$(acts "$C")" "0"
check "C2b unknown culprit: 5 escalations" "$(jq -s 'length' "$C/decisions.jsonl")" "5"

# ---------------------------------------------------------------- C3
C=$(mkcase c3) || exit 1; fx "$C" approved-7609.json >/dev/null; run_pipe "$C" cromford
check "C3 #7609 U4" "$(dec "$C" 7609 '"\(.rule_id) \(.would)"')" "U4-standing-approval WOULD_QUEUE_APPROVE"
check "C3 #7609 cites G1" "$(dec "$C" 7609 '.cites | index("G1") != null')" "true"
check "C3 #7609 judge null" "$(dec "$C" 7609 .judge)" "null"
check "C3 #7609 args" "$(dec "$C" 7609 '"\(.action.args.verdict) \(.action.args.source)"')" "MERGE-WITH-NOTES agent"
check "C3 only #7609 is a stall (draft, queued, BLOCK skipped)" "$(jq -rs 'map(.subject) | join(",")' "$C/stalls.jsonl")" "$R#7609"
check "C3 the setting read is per project" "$(grep -c '^set unblock.standing_approval.cromford$' "$C/calls.log")" "1"
check "C3 1 WOULD line" "$(wc -l < "$C/would.txt" | tr -d ' ')" "1"
check "C3 0 non-GET calls" "$(nonget "$C")" "0"

C=$(mkcase c3-project-2) || exit 1
fx "$C" approved-7609.json '(.gh, .verdicts) |= with_entries(.key |= sub("example-org/cromford"; "example-org/project-2")) | .repo = "example-org/project-2" | .settings = {}' >/dev/null
run_pipe "$C" project-2 example-org/project-2
check "C3 project-2: escalate" "$(jq -rs '.[0].decision' "$C/decisions.jsonl")" "escalate"
check "C3 project-2: near miss names the standing row" "$(jq -rs '.[0].near_misses[] | select(.rule == "U4-standing-approval") | .failed | index(".standing_approval == \"1\"") != null' "$C/decisions.jsonl")" "true"
check "C3 project-2: 0 WOULD lines" "$(wc -l < "$C/would.txt" | tr -d ' ')" "0"

C=$(mkcase c3b) || exit 1
fx "$C" approved-7609.json '.verdicts |= map_values(sub("2026-10-20T11:00:00Z"; "2026-10-20T11:41:00Z"))' >/dev/null
run_pipe "$C" cromford
check "C3b idle 19 min: no U4" "$(dec "$C" 7609 '"\(.decision) \(.near_misses[0].failed | join("|"))"')" "escalate .idle_min >= .approved_idle_min"
C=$(mkcase c3b20) || exit 1
fx "$C" approved-7609.json '.verdicts |= map_values(sub("2026-10-20T11:00:00Z"; "2026-10-20T11:40:00Z"))' >/dev/null
run_pipe "$C" cromford
check "C3b idle 20 min: U4" "$(dec "$C" 7609 .rule_id)" "U4-standing-approval"

C=$(mkcase c3c) || exit 1
fx "$C" approved-7609.json '.gh |= with_entries(if (.key | test("check-runs")) then .value.check_runs[1] |= (.status = "in_progress" | .conclusion = null) else . end)' >/dev/null
run_pipe "$C" cromford
check "C3c a check running: no U4" "$(dec "$C" 7609 .decision)" "escalate"
check "C3c checks field is running" "$(jq -rs '.[0].checks' "$C/stalls.jsonl")" "running"

C=$(mkcase c3d) || exit 1
fx "$C" approved-7609.json '.gh |= with_entries(if (.key | test("reviews")) then .value += [{id:3, user:{login:"fixture-dev"}, state:"CHANGES_REQUESTED", submitted_at:"2026-10-20T11:30:00Z"}] else . end)' >/dev/null
run_pipe "$C" cromford
check "C3d open CHANGES_REQUESTED: no U4" "$(dec "$C" 7609 .decision)" "escalate"
C=$(mkcase c3d2) || exit 1
fx "$C" approved-7609.json '.gh |= with_entries(if (.key | test("reviews")) then .value = [{id:3, user:{login:"fixture-dev"}, state:"CHANGES_REQUESTED", submitted_at:"2026-10-20T09:30:00Z"}, {id:4, user:{login:"fixture-dev"}, state:"APPROVED", submitted_at:"2026-10-20T11:30:00Z"}] else . end)' >/dev/null
run_pipe "$C" cromford
check "C3d CHANGES_REQUESTED approved over by the same reviewer: U4" "$(dec "$C" 7609 .rule_id)" "U4-standing-approval"

C=$(mkcase c3e) || exit 1
fx "$C" approved-7609.json '.gh |= with_entries(if (.key | test("/files")) then .value += [{filename:"tests/review-pool.bh-7609-test.sh", status:"modified"}] else . end)' >/dev/null
run_pipe "$C" cromford
check "C3e test file: U4 with the test-weakening judge" "$(dec "$C" 7609 '"\(.rule_id) \(.judge.prompt) \(.judge.question)"')" "U4-standing-approval catalog/prompts/unblock-judge.md test-weakening"

C=$(mkcase c3f) || exit 1; fx "$C" approved-7609.json >/dev/null; run_pipe "$C" cromford "$R" 'VD_RC=2'
check "C3f verdicts unread: one queue-unreadable record naming the PRs" "$(jq -rs 'map(select(.kind == "queue-unreadable")) | map("\(.input) \(.prs | join(","))") | join(";")' "$C/stalls.jsonl")" "verdicts 7609,7620"
check "C3f verdicts unread: 0 act" "$(acts "$C")" "0"

# ---------------------------------------------------------------- C4
C=$(mkcase c4) || exit 1
fx "$C" batch-7699.json '.verdicts |= with_entries(select(.key | startswith("example-org/cromford#7588 ") | not)) | .verdicts += .verdicts_older_head' >/dev/null
run_pipe "$C" cromford
check "C4 #7588 verdict on an older head: escalate" "$(dec "$C" 7588 '"\(.decision) \(.rule_id)"')" "escalate U12"
check "C4 #7588 verdict_on_head none" "$(jq -rs --arg s "$R#7588" 'map(select(.subject == $s))[0].verdict_on_head' "$C/stalls.jsonl")" "none"
check "C4 #7588 the verdict was asked on the current head" "$(grep -c "^vd $R#7588 $(jq -r '.heads["7588"]' "$FX/batch-7699.json")$" "$C/calls.log")" "1"
check "C4 the other three still U2" "$(jq -s '[.[] | select(.rule_id == "U2-bystander-requeue")] | length' "$C/decisions.jsonl")" "3"

C=$(mkcase c4b) || exit 1; fx "$C" batch-7699.json >/dev/null; run_pipe "$C" cromford "$R" 'VD_RC=2'
check "C4b vd rc 2: #7592 not U2" "$(dec "$C" 7592 .decision)" "escalate"
check "C4b vd rc 2: the verdict predicate is unknown" "$(dec "$C" 7592 '.near_misses[] | select(.rule == "U2-bystander-requeue") | .unknown | join("|")')" '.verdict_on_head | test("^MERGE")'
check "C4b vd rc 2: verdict named unreadable" "$(jq -rs --arg s "$R#7592" 'map(select(.subject == $s))[0] | "\(.verdict_on_head) \(.inputs_unreadable | index("verdict") != null)"' "$C/stalls.jsonl")" "null true"

C=$(mkcase c4c) || exit 1; fx "$C" batch-7699.json >/dev/null; run_pipe "$C" cromford "$R" 'unset -f mc_attempt_has mc_requeued_mark'
check "C4c no conductor lib: 0 act" "$(acts "$C")" "0"
check "C4c no conductor lib: requeued_on_head null" "$(jq -rs '[.[].requeued_on_head] | unique | map(tostring) | join(",")' "$C/stalls.jsonl")" "null"

# ---------------------------------------------------------------- C5
C=$(mkcase c5) || exit 1; fx "$C" batch-7699.json >/dev/null
: > "$C/ledger.keys"
ledger_insert() { # one INSERT ... ON CONFLICT (decision_key) DO NOTHING per decision
  local n=0 k
  while IFS= read -r k; do
    grep -qxF "$k" "$1/ledger.keys" && continue
    printf '%s\n' "$k" >> "$1/ledger.keys"; n=$((n + 1))
  done < <(jq -r '.decision_key' "$1/decisions.jsonl")
  printf '%s' "$n"
}
run_pipe "$C" cromford; cp "$C/decisions.jsonl" "$C/run1.jsonl"; n1=$(ledger_insert "$C")
run_pipe "$C" cromford; n2=$(ledger_insert "$C")
check "C5 run 1 inserts 5 rows" "$n1" "5"
check "C5 run 2 inserts 0 rows" "$n2" "0"
check "C5 keys byte-identical" "$(jq -r .decision_key "$C/run1.jsonl" | sha256sum | cut -c1-16)" "$(jq -r .decision_key "$C/decisions.jsonl" | sha256sum | cut -c1-16)"

# ---------------------------------------------------------------- C6
C=$(mkcase c6) || exit 1
fx "$C" ejects-20261019.json '.batch_failure["7612"].failed_checks[0].lines += ["<!-- tackler:abc -->"] | .gh["repos/example-org/cromford/pulls/7600"].labels = [{name:"staff:tackler"}]' >/dev/null
run_pipe "$C" cromford
check "C6 marker and staff label dropped: only #7604 left" "$(jq -rs 'map(.subject) | join(",")' "$C/stalls.jsonl")" "$R#7604"
check "C6 0 decisions for the dropped PRs" "$(jq -s --arg r "$R" '[.[] | select(.subject == "\($r)#7590" or .subject == "\($r)#7595" or .subject == "\($r)#7600")] | length' "$C/decisions.jsonl")" "0"

# ---------------------------------------------------------------- C7
c7() { # c7 <label> <setup commands, run in the rules dir>
  local C; C=$(mkcase "c7-$1") || return 1
  mkdir -p "$C/rules"; cp "$RULES"/*.json "$C/rules/"
  ( cd "$C/rules" && eval "$2" )
  ( export HARNESS="$C/h" UNBLOCK_CITES_FILE="${C7_CITES:-$C/cites.json}"
    . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
    ub_rules_load "$C/rules" > "$C/load.out" 2> "$C/load.err"; echo "$?" > "$C/load.rc"
    printf '%s\n' '{"kind":"pr-ejected","repo":"o/r","subject":"o/r#1","pr":1,"head":"h"}' | ub_rules_eval "$C/rules" > "$C/eval.out" 2>/dev/null
    echo "$?" > "$C/eval.rc" )
  check "C7 $1: load rc 2, nothing printed, eval rc 2 with no decision" \
    "$(cat "$C/load.rc") $(wc -c < "$C/load.out" | tr -d ' ') $(cat "$C/eval.rc") $(wc -c < "$C/eval.out" | tr -d ' ')" "2 0 2 0"
  C7_LAST="$C"
}
c7 dup-id 'cp U1-batch-culprit.json U1-batch-culprit-copy.json'
check "C7 dup-id names the duplicated id" "$(grep -c 'U1-batch-culprit' "$C7_LAST/load.err" | awk '{print ($1 >= 1)}')" "1"
c7 bad-id 'jq ".id = \"x9-other\"" U1-batch-culprit.json > t && mv t U1-batch-culprit.json'
c7 missing-key 'jq "del(.key)" U2-bystander-requeue.json > t && mv t U2-bystander-requeue.json'
c7 bad-json 'printf "{not json" > U5-broken.json'
c7 bad-cite 'jq ".cites += [\"G99\"]" U3-dead-shard-requeue.json > t && mv t U3-dead-shard-requeue.json'
C7_CITES=/nonexistent/_cites.json c7 no-cites ':'
c7 no-compile 'jq ".match.all += [\".pr ==\"]" U1-batch-culprit.json > t && mv t U1-batch-culprit.json'
c7 reads-input 'jq ".match.all += [\"input | .pr == 1\"]" U1-batch-culprit.json > t && mv t U1-batch-culprit.json'
grep -q 'G99' "$T/c7-bad-cite/load.err" && ok "C7 bad-cite names G99" || no "C7 bad-cite names G99" "$(cat "$T/c7-bad-cite/load.err")"

# ---------------------------------------------------------------- C8
C=$(mkcase c8) || exit 1
fx "$C" batch-7699.json '.gh_status = {"repos/example-org/cromford/pulls?state=closed&sort=updated&direction=desc&per_page=100": "500"}' >/dev/null
run_pipe "$C" cromford
check "C8 closed list 500: one queue-unreadable record" "$(jq -rs 'map(select(.kind == "queue-unreadable")) | map(.input) | join(",")' "$C/stalls.jsonl")" "closed-pulls"
check "C8 0 act" "$(acts "$C")" "0"
check "C8 collect rc 0" "$(cut -d' ' -f1 "$C/rc")" "0"

C=$(mkcase c8b) || exit 1; fx "$C" batch-7699.json >/dev/null; rm -f "$C/h/mcp/tools/batch-failure.mjs"
run_pipe "$C" cromford
check "C8b tool missing: one queue-unreadable record" "$(jq -rs 'map(select(.kind == "queue-unreadable")) | map(.input) | join(",")' "$C/stalls.jsonl")" "batch_failure:7699"
check "C8b 0 act" "$(acts "$C")" "0"

C=$(mkcase c8c) || exit 1; fx "$C" batch-7699.json '.batch_failure["7699"].complete = false' >/dev/null
run_pipe "$C" cromford
check "C8c complete:false: 0 act" "$(acts "$C")" "0"
check "C8c complete:false: every record names batch_failure unreadable" "$(jq -s 'map(select(.kind == "pr-ejected") | .inputs_unreadable | index("batch_failure") != null) | (length == 5 and all)' "$C/stalls.jsonl")" "true"

# ---------------------------------------------------------------- C9
C=$(mkcase c9) || exit 1
ids=$( export HARNESS="$C/h" UNBLOCK_CITES_FILE="$C/cites.json"
  . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
  ub_rules_load "$RULES" | jq -r 'map(.id) | join(" ")' )
check "C9 shipped rules load in priority order" "$ids" "U1-batch-culprit U2-bystander-requeue U3-dead-shard-requeue U4-standing-approval U6 U5 U7 U11 U8 U9 U10 U12"

# ---------------------------------------------------------------- C10
# The tick path: the shipped bin/unblock.sh, sandboxed (HARNESS_TEST_SANDBOX=1,
# UNBLOCK_FIXTURE, UNBLOCK_COLLECTORS_DIR), with the REAL queue collector and
# the REAL rules engine and act layer in shadow. ubc_collect must call
# ub_collect_queue (collectors=1 unwired=0), ub_rules_eval must load main's
# whole catalog, and each U1-U4 decision must reach ub_act with an object
# action that act.sh accepts: a WOULD_ line, never failed bad-input.
C=$(mkcase c10) || exit 1; fx "$C" batch-7699.json >/dev/null
for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || no "C10 setup: closure $S"
done
mkdir -p "$C/h/catalog/unblock-rules.d" "$C/col" "$C/h/env"
cp "$RULES"/*.json "$C/h/catalog/unblock-rules.d/"
# scratch-closure-allow: places the already-installed queue collector into the UNBLOCK_COLLECTORS_DIR seam the tick reads; the closure itself comes from scratch_install_closure above
cp "$C/h/bin/lib/unblock/collectors/queue.sh" "$C/col/queue.sh"
: > "$C/h/env/global.env"
printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$C/h/bin/lane-alert.sh"; chmod +x "$C/h/bin/lane-alert.sh"
TNOW=$(date -u -d "$(jq -r .now "$C/fx.json")" +%s)
jq -nc --argjson fa "$TNOW" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "shadow", "unblock.enabled": "1"}, seeded: {}}' \
  > "$C/h/state/settings-cache.json"
cat > "$C/fx.sh" <<'SH'
setting_get() {
  case "$1" in unblock.enabled) printf 1; return 0 ;; esac
  local v; v=$(jq -r --arg k "$1" '.settings[$k] // empty' "$GH_FX"); [ -n "$v" ] || return 2; printf '%s' "$v"
}
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$JOBS_LOG"
  case "$1 $2" in
    "POST /api/unblock/decisions/claim") printf '{"claimed":true,"id":1}'; return 0 ;;
    "POST /api/unblock/decisions/record") printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
vd_standing() { local l; l=$(jq -r --arg k "$1#$2 $3" '.verdicts[$k] // empty' "$GH_FX"); [ -n "$l" ] || return 1; printf '%s\n' "$l"; }
mc_attempt_has() { jq -e --arg l "$1" '.attempts | index($l) != null' "$GH_FX" >/dev/null; }
mc_requeued_mark() { jq -r --arg k "$1 $2" '.requeued[$k] // empty' "$GH_FX"; }
SH
: > "$C/jobs.log"
( env HARNESS="$C/h" GH_FX="$C/fx.json" GH_LOG="$C/gh.log" BF_LOG="$C/bf.log" MODEL_LOG="$C/model.log" JOBS_LOG="$C/jobs.log" \
    PATH="$C/bin:$PATH" GH_ETAG=0 TMPDIR="$C" HARNESS_CONSOLE_URL=http://192.0.2.10 UNBLOCK_NOW="$TNOW" UB_NOW="$TNOW" \
    UNBLOCK_FIXTURE="$C/fx.sh" UNBLOCK_COLLECTORS_DIR="$C/col" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 \
    LANE_GATE_NOW="$TNOW" LANE_GATE_CACHE_S=60 UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= \
    bash "$C/h/bin/unblock.sh" tick --project cromford ) > "$C/tick.out" 2>&1
TL=$(grep ' tick cromford mode=' "$C/h/logs/unblock.log" | tail -n1)
case "$TL" in *"collectors=1 unwired=0 failed=0"*) ok "C10 tick: collectors=1 unwired=0 failed=0" ;; *) no "C10 tick: collectors=1 unwired=0 failed=0" "$TL $(head -c 600 "$C/tick.out")" ;; esac
case "$TL" in *rules=unwired*) no "C10 tick: rules wired" "$TL" ;; *) ok "C10 tick: rules wired" ;; esac
check "C10 claims carry U1-U4 rule ids with object actions" \
  "$(grep '^POST /api/unblock/decisions/claim ' "$C/jobs.log" | sed 's/^POST [^ ]* //' | jq -rs 'map(select(.rule_id | tostring | test("^U[1-4]-"))) | map("\(.rule_id) \(.action)") | unique | join(",")')" \
  "U1-batch-culprit post_block,U2-bystander-requeue requeue"
check "C10 act.sh logged WOULD_POST_BLOCK for #7617" "$(grep -c " act cromford example-org/cromford#7617 U1-batch-culprit WOULD_POST_BLOCK would " "$C/h/logs/unblock.log")" "1"
check "C10 act.sh logged 4 WOULD_REQUEUE" "$(grep -c " U2-bystander-requeue WOULD_REQUEUE would " "$C/h/logs/unblock.log")" "4"
check "C10 no record failed bad-input" "$(grep '^POST /api/unblock/decisions/record ' "$C/jobs.log" | grep -c '"outcome":"failed"')" "0"
check "C10 5 records would" "$(grep '^POST /api/unblock/decisions/record ' "$C/jobs.log" | grep -c '"outcome":"would"')" "5"
check "C10 0 non-GET gh calls" "$(nonget "$C")" "0"
check "C10 0 model calls" "$(wc -l < "$C/model.log" | tr -d ' ')" "0"

echo "unblock-queue-rules: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
