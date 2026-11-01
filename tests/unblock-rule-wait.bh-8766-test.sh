#!/bin/bash
# tests/unblock-rule-wait.bh-8766-test.sh — BH-8766: a record under its
# matched rule's own wait threshold (match.wait in catalog/unblock-rules.d) is
# a `wait` decision: no claim, no card, never CRITICAL, one log line; the next
# tick reads it again.
#
# Evidence: card u-ff49fb (PR #8663, head 1f3578d, idle 5 of the 20 min
# restamp_idle_min) and card u-b36998 (#8829, idle 1 of the 20 min
# approved_idle_min) both paged CRITICAL through U12 while the rule that owns
# the record only had to wait.
#
#   W1-W6   the shipped rules through the real ub_rules_eval: U13-RESTAMP,
#           U4, U13-REACH, U13-STARVE and U8 wait under their threshold, and
#           act or escalate at it, as on main.
#   W7      the u13 fixture's records decide as before (no full match turns
#           into a wait).
#   W8      a non-threshold predicate that fails, or a null measure, still
#           goes to U12 (unknown is not "not yet").
#   W9      priority decides between a waiting rule and a matching one.
#   W10     a match.wait pred that is not in match.all, or an under that reads
#           outside the record, refuses the whole load (rc 2).
#   W11     every shipped rule file loads; exactly the five planned rules
#           carry match.wait, and each pred is an entry of their match.all.
#   W12     an under that errors on the record is U: not a wait.
#   W13-W15 the REAL bin/unblock.sh tick (act, UNBLOCK_ACT=1) over a stub
#           collector: a wait makes 0 claims, 0 alerts, one `wait` line and
#           `waited=1`; at the threshold the claim is back.
#   B       0 non-GET gh calls, 0 model calls, 0 curl calls.
#
# MUTATIONS (D1), each tried once by hand: make every under read F -> W1, W3
# and W13 red; drop the pred membership check in the loader -> W10 red;
# remove the wait) arm in ubt_decide -> W13 red (deferred, no waited=).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-rule-wait.bh-8766-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }

RULES="$SRC/catalog/unblock-rules.d"
U13FX="$SRC/tests/fixtures/unblock-rules-u13/rules.json"
R=example-org/cromford
NOW=$(date -u -d '2026-10-30T12:00:00Z' +%s)

# The vendor fakes: every gh, model and network call is logged and refused.
mkdir -p "$T/pathbin"
for s in gh claude curl flyctl; do printf '#!/bin/bash\necho "%s $*" >> "$T/vendor.log"\nexit 7\n' "$s" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*
: > "$T/vendor.log"

# ev <rules dir> — one decision per stdin record, through the real engine.
ev() { (export PATH="$T/pathbin:$PATH"; . "$SRC/bin/lib/unblock/rules.sh"; HARNESS="$SRC" ub_rules_eval "$1"); }
dr() { jq -c "$1" <<<"$2" | ev "$RULES" | jq -r '"\(.decision) \(.rule_id)"'; }

RESTAMP=$(jq -nc --arg r "$R" '{kind: "pr-verdict-old-head", family: "queue", project: "cromford", repo: $r,
  subject: ($r + "#8663"), pr: 8663, head: "1f3578d000000000000000000000000000000000", old_verdict: "MERGE",
  lead_request_open: false, idle_min: 5, restamp_idle_min: 20, request_id: "none", priority: 5}')
U4REC=$(jq -nc --arg r "$R" '{kind: "pr-approved-idle", family: "queue", project: "cromford", repo: $r,
  subject: ($r + "#8829"), pr: 8829, head: "b36998b000000000000000000000000000000000", standing_approval: "1",
  verdict_on_head: "MERGE", idle_min: 1, approved_idle_min: 20, mergeable_state: "clean", checks: "green",
  changes_requested_open: false, touches_tests: false}')
REACH=$(jq -nc '{kind: "build-reach-blocked", family: "infra", project: "cromford", subject: "ticket:cromford:BH-8476",
  subject_kind: "build", ticket: "BH-8476", age_min: 10, reach_stuck_min: 45, has_pr: false, day: "2026-10-30"}')
STARVE=$(jq -nc '{kind: "ticket-starved", family: "infra", project: "cromford", subject: "ticket:cromford:BH-8325",
  subject_kind: "build", ticket: "BH-8325", queued_min: 51, passes: 1, starve_min: 120, starve_passes: 3, triage_out: false,
  day: "2026-10-29"}')
HUNG=$(jq -nc '{kind: "box-hung", family: "infra", project: "cromford", subject: "box:orgo-7", stall_at_hour: "2026-10-30T11",
  orgo_hosted: true, orgo_state: "running", ssh_unreachable_min: 10, hung_min_threshold: 30, envbundle_fail_1h: 5,
  last_restart_min_ago: 120, build_claim_10m: false}')

# ═════ W1-W6: the shipped rules ══════════════════════════════════════════════
D=$(ev "$RULES" <<<"$RESTAMP")
check "W1 RESTAMP idle 5 of 20 (card u-ff49fb): wait U13-RESTAMP" "$(jq -r '"\(.decision) \(.rule_id)"' <<<"$D")" "wait U13-RESTAMP"
check "W1 waiting_on names the restamp under" "$(jq -r '.waiting_on | join(" and ")' <<<"$D")" \
  '(.idle_min | type) == "number" and (.restamp_idle_min | type) == "number" and .idle_min < .restamp_idle_min'
check "W1 the wait has no action, no judge, the rule's cites and class" \
  "$(jq -r '"\(.action) \(.judge) \(.cites | join(",")) \(.class) \(.reason)"' <<<"$D")" "null null G12,G21 review-rerequest under rule U13-RESTAMP threshold"
check "W1 the seam shape: subject, pr, head, decision_key" \
  "$(jq -r '"\(.subject) \(.pr) \(.head[0:7]) \(.decision_key | test("^[0-9a-f]{64}$"))"' <<<"$D")" "$R#8663 8663 1f3578d true"
check "W2 idle 19: wait" "$(dr '.idle_min = 19' "$RESTAMP")" "wait U13-RESTAMP"
check "W2 idle 20 (equal): act U13-RESTAMP" "$(dr '.idle_min = 20' "$RESTAMP")" "act U13-RESTAMP"
check "W2 idle 20: WOULD_LEAD_REREQUEST" \
  "$(jq -c '.idle_min = 20' <<<"$RESTAMP" | ev "$RULES" | (. "$SRC/bin/lib/unblock/rules.sh"; ub_rules_would_lines) | cut -d' ' -f1-2)" "WOULD_LEAD_REREQUEST U13-RESTAMP"
check "W3 U4 idle 1 of 20 (card u-b36998, #8829): wait U4-standing-approval" "$(dr . "$U4REC")" "wait U4-standing-approval"
check "W3 U4 idle 20: act U4-standing-approval" "$(dr '.idle_min = 20' "$U4REC")" "act U4-standing-approval"
check "W3 U4 idle 1 but checks red: escalate U12" "$(dr '.checks = "red"' "$U4REC")" "escalate U12"
check "W4 REACH age 10 of 45: wait U13-REACH" "$(dr . "$REACH")" "wait U13-REACH"
check "W4 REACH age 51: escalate U13-REACH (unchanged)" "$(dr '.age_min = 51' "$REACH")" "escalate U13-REACH"
check "W5 STARVE 51m / 1 pass, triage_out false: wait U13-STARVE" "$(dr . "$STARVE")" "wait U13-STARVE"
check "W5 STARVE both unders read T: waiting_on has 2 entries" "$(jq -c . <<<"$STARVE" | ev "$RULES" | jq -r '.waiting_on | length')" 2
check "W5 STARVE 51m / 3 passes: wait (one under)" "$(dr '.passes = 3' "$STARVE")" "wait U13-STARVE"
# A record with no head is U12's unkeyed escalation (rule_id null): a card.
check "W5 STARVE 51m / 1 pass, triage_out true: escalate (U12, unkeyed)" "$(dr '.triage_out = true' "$STARVE")" "escalate null"
check "W5 STARVE 130m / 3 passes: act U13-STARVE" "$(dr '.queued_min = 130 | .passes = 3' "$STARVE")" "act U13-STARVE"
check "W6 U8 ssh 10 of 30: wait U8" "$(dr . "$HUNG")" "wait U8"
check "W6 U8 ssh 30 of 30 (predicate is >): wait U8" "$(dr '.ssh_unreachable_min = 30' "$HUNG")" "wait U8"
check "W6 U8 ssh 31: act U8" "$(dr '.ssh_unreachable_min = 31' "$HUNG")" "act U8"
check "W6 U8 hung_min_threshold null: escalate (U12, unkeyed)" "$(dr '.hung_min_threshold = null' "$HUNG")" "escalate null"
check "W6 U8 restarted 10 min ago (not a wait threshold): escalate (U12, unkeyed)" "$(dr '.last_restart_min_ago = 10' "$HUNG")" "escalate null"

# ═════ W7: the u13 fixture's records ═════════════════════════════════════════
NC=$(jq '.cases | length' "$U13FX"); W7BAD=""
for i in $(seq 0 $((NC - 1))); do
  c=$(jq -c ".cases[$i]" "$U13FX"); rule=$(jq -r .rule <<<"$c"); want=$(jq -r .want <<<"$c")
  d=$(jq -c .record <<<"$c" | ev "$RULES")
  if [ "$want" = escalate ]; then got=$(jq -r '"\(.decision) \(.rule_id)"' <<<"$d"); exp="escalate $rule"
  else got=$(jq -r '"\(.would) \(.rule_id)"' <<<"$d"); exp="$want $rule"; fi
  [ "$got" = "$exp" ] || W7BAD="$W7BAD $rule:$got"
done
check "W7 all $NC u13 fixture records decide as before (no wait)" "${W7BAD:-none}" none

# ═════ W8: the adversarial negatives ═════════════════════════════════════════
check "W8 RESTAMP idle 5, lead request open: escalate U12" "$(dr '.lead_request_open = true' "$RESTAMP")" "escalate U12"
check "W8 RESTAMP idle 5, old verdict BLOCK: escalate U12" "$(dr '.old_verdict = "BLOCK"' "$RESTAMP")" "escalate U12"
check "W8 RESTAMP idle null: escalate U12" "$(dr '.idle_min = null' "$RESTAMP")" "escalate U12"
# restamp_idle_min null: the under reads F (not a number), so no wait. The
# match.all predicate reads 5 >= null as true in jq, so it is a full match, as
# on main (match.all is not this ticket's to change).
check "W8 RESTAMP restamp_idle_min null: not a wait (act, as on main)" "$(dr '.restamp_idle_min = null' "$RESTAMP")" "act U13-RESTAMP"
check "W8 a kind with no match.wait rule (U13-EMPTY-CARD) is unchanged" \
  "$(jq -c '.cases[] | select(.rule == "U13-EMPTY-CARD") | .record' "$U13FX" | ev "$RULES" | jq -r '"\(.decision) \(.rule_id)"')" "escalate U13-EMPTY-CARD"

# ═════ W9-W12: scratch rule sets ═════════════════════════════════════════════
# rule <dir> <id> <priority> <match json> <action> — one rule file.
rule() {
  jq -n --arg id "$2" --argjson pr "$3" --argjson m "$4" --arg a "$5" \
    '{id: $id, priority: $pr, family: "queue", class: "queue-approve", cites: ["G1"], match: $m,
      action: {name: $a}, judge: null, key: ["subject", "id"]}' > "$1/$2.json"
}
WA='{"kind": "w-test", "all": [".n >= .t", ".x == 1"], "wait": [{"pred": ".n >= .t", "under": ".n < .t"}]}'
WB='{"kind": "w-test", "all": [".x == 1"]}'
WREC='{"kind": "w-test", "subject": "w:1", "n": 1, "t": 5, "x": 1}'
mkdir -p "$T/w9a" "$T/w9b"; cp "$RULES/_cites.json" "$T/w9a/"; cp "$RULES/_cites.json" "$T/w9b/"
rule "$T/w9a" UA 10 "$WA" do_a; rule "$T/w9a" UB 20 "$WB" do_b
check "W9 A (priority 10) waits, B (20) fully matches: wait UA" "$(ev "$T/w9a" <<<"$WREC" | jq -r '"\(.decision) \(.rule_id)"')" "wait UA"
rule "$T/w9b" UA 20 "$WA" do_a; rule "$T/w9b" UB 10 "$WB" do_b
check "W9 priorities swapped: act UB" "$(ev "$T/w9b" <<<"$WREC" | jq -r '"\(.decision) \(.rule_id)"')" "act UB"

mkdir -p "$T/w10a" "$T/w10b"; cp "$RULES/_cites.json" "$T/w10a/"; cp "$RULES/_cites.json" "$T/w10b/"
rule "$T/w10a" UA 10 '{"kind": "w-test", "all": [".n >= .t"], "wait": [{"pred": ".n > .t", "under": ".n < .t"}]}' do_a
(. "$SRC/bin/lib/unblock/rules.sh"; ub_rules_load "$T/w10a") > "$T/w10a.out" 2> "$T/w10a.err"; rc=$?
check "W10 a pred that is not in match.all: rc 2, nothing on stdout" "$rc $(grep -c . "$T/w10a.out")" "2 0"
check "W10 the stderr line names match.wait[0].pred" "$(grep -c 'UA: match.wait\[0\].pred ".n > .t" is not an entry of match.all' "$T/w10a.err")" 1
rule "$T/w10b" UA 10 '{"kind": "w-test", "all": [".n >= .t"], "wait": [{"pred": ".n >= .t", "under": "env.T == \"1\""}]}' do_a
(. "$SRC/bin/lib/unblock/rules.sh"; ub_rules_load "$T/w10b") > /dev/null 2> "$T/w10b.err"; rc=$?
check "W10 an under that uses env: rc 2 (reads outside the record)" "$rc $(grep -c 'reads outside the record (env)' "$T/w10b.err")" "2 1"
rule "$T/w10b" UA 10 '{"kind": "w-test", "all": [".n >= .t"], "wait": [{"pred": ".n >= .t"}]}' do_a
(. "$SRC/bin/lib/unblock/rules.sh"; ub_rules_load "$T/w10b") > /dev/null 2> "$T/w10c.err"; rc=$?
check "W10 a wait entry with no under: rc 2" "$rc $(grep -c 'match.wait\[0\] must be an object with string pred and under' "$T/w10c.err")" "2 1"

(. "$SRC/bin/lib/unblock/rules.sh"; HARNESS="$SRC" ub_rules_load) > "$T/w11.json" 2> "$T/w11.err"; rc=$?
check "W11 every shipped rule file loads (rc 0, no stderr)" "$rc $(grep -c . "$T/w11.err")" "0 0"
check "W11 exactly the five planned rules carry match.wait" \
  "$(jq -r '[.[] | select(.match | has("wait")) | .id] | sort | join(" ")' "$T/w11.json")" "U13-REACH U13-RESTAMP U13-STARVE U4-standing-approval U8"
check "W11 each pred is an entry of its match.all" \
  "$(jq -r '[.[] | select(.match | has("wait")) | .match as $m | $m.wait[] | (.pred as $p | $m.all | index($p)) != null] | all' "$T/w11.json")" true

mkdir -p "$T/w12"; cp "$RULES/_cites.json" "$T/w12/"
rule "$T/w12" UA 10 '{"kind": "w-test", "all": [".n >= .t"], "wait": [{"pred": ".n >= .t", "under": ".x | tonumber < 1"}]}' do_a
check "W12 an under that errors (x \"a\") is not a wait" \
  "$(ev "$T/w12" <<<'{"kind": "w-test", "subject": "w:1", "n": 1, "t": 5, "x": "a"}' | jq -r '"\(.decision) \(.rule_id)"')" "escalate null"
check "W12 the same under with x 0 reads T: wait" \
  "$(ev "$T/w12" <<<'{"kind": "w-test", "subject": "w:1", "n": 1, "t": 5, "x": "0"}' | jq -r '"\(.decision) \(.rule_id)"')" "wait UA"

# ═════ W13-W15: the tick ═════════════════════════════════════════════════════
# mktick <name> — modeled on tests/unblock-rules-contract.bh-8418-test.sh's
# mktick (copied, trimmed): the shipped bin/unblock.sh by its closure, the
# shipped rules, a logging lane-alert and agent-call, the jobs API fixture,
# and ONE stub collector that prints $FXT/lines.jsonl.
mktick() {
  local C="$T/$1" S
  mkdir -p "$C/h/env" "$C/h/state" "$C/h/logs" "$C/h/catalog/unblock-rules.d" "$C/h/catalog/prompts" "$C/fx" "$C/col"
  for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/unblock/rules.sh bin/lib/unblock/judge.sh bin/lib/unblock/card.sh; do
    ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || { echo "setup: closure $S" >&2; return 1; }
  done
  cp "$RULES"/*.json "$C/h/catalog/unblock-rules.d/"
  cp "$SRC/catalog/prompts/unblock-decide.md" "$SRC/catalog/prompts/unblock-judge.md" "$C/h/catalog/prompts/"
  : > "$C/h/env/global.env"
  printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
  rm -f "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  printf '#!/bin/bash\nIFS= read -r l <<<"ALERT $*"; printf "%%s\\n" "$l" >> "$FXT/alerts.log"\nexit 0\n' > "$C/h/bin/lane-alert.sh"
  printf '#!/bin/bash\necho "AGENTCALL $1 $2 $3" >> "$FXT/seq.log"\n: > "$5"\nexit 0\n' > "$C/h/bin/agent-call.sh"
  chmod +x "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  cat > "$C/fx.sh" <<'SH'
seq_log() { printf '%s\n' "$*" >> "$FXT/seq.log"; }
setting_get() { case "$1" in unblock.enabled) printf 1; return 0 ;; esac; return 2; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
_jobs_req() {
  local k n
  seq_log "JOBS $1 $2 ${3:-}"
  case "$1 $2" in
    "POST /api/unblock/decisions/claim")
      k=$(jq -r .decision_key <<<"$3"); mkdir -p "$FXT/seen"
      if [ -f "$FXT/seen/$k" ]; then printf '{"claimed":false,"id":%s,"outcome":"would"}' "$(cat "$FXT/seen/$k")"; return 9; fi
      n=$(( $(cat "$FXT/id.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/id.n"; echo "$n" > "$FXT/seen/$k"
      printf '{"claimed":true,"id":%s}' "$n"; return 0 ;;
    "POST /api/unblock/decisions/record") printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
lane_role_model() { seq_log "ROUTE $*"; printf 'model-fixture\n'; }
SH
  printf 'ub_collect_fixture() { cat "$FXT/lines.jsonl"; }\n' > "$C/col/fixture.sh"
  printf '%s' "$C"
}
mode() {
  jq -nc --argjson fa "$NOW" --arg m "$2" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": $m, "unblock.enabled": "1"}, seeded: {}}' \
    > "$1/h/state/settings-cache.json"
}
tick() {
  local C="$1"; shift
  ( env HARNESS="$C/h" FXT="$C/fx" UNBLOCK_FIXTURE="$C/fx.sh" FLEET_CONF="$C/h/fleet.conf" REGISTRY_SOURCE=file \
      UNBLOCK_COLLECTORS_DIR="$C/col" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60 \
      UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$C" \
      HARNESS_CONSOLE_URL=http://192.0.2.10 UNBLOCK_NOW="$NOW" UB_NOW="$NOW" "$@" \
      bash "$C/h/bin/unblock.sh" tick --project cromford ) > "$C/tick.out" 2>&1
}
claims() { grep '^JOBS POST /api/unblock/decisions/claim ' "$1/fx/seq.log" 2>/dev/null | sed 's/^JOBS POST [^ ]* //'; }
nclaims() { claims "$1" | grep -c .; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }
nalerts() { cnt . "$1/fx/alerts.log"; }
tickline() { grep ' tick cromford mode=' "$1/h/logs/unblock.log" 2>/dev/null | tail -n1; }
budget() {
  check "B $2: 0 model calls (agent-call)" "$(cnt '^AGENTCALL' "$1/fx/seq.log")" 0
  check "B $2: 0 gh, curl or model CLI calls" "$(grep -c . "$T/vendor.log")" 0
}

C=$(mktick w13) || { echo "FAIL: tick setup"; exit 1; }
mode "$C" act; printf '%s\n' "$RESTAMP" > "$C/fx/lines.jsonl"
tick "$C" UNBLOCK_ACT=1
check "W13 RESTAMP idle 5, act: 0 claim POSTs, 0 lane-alert calls" "$(nclaims "$C") $(nalerts "$C")" "0 0"
check "W13 one wait line naming U13-RESTAMP, the PR and the under" \
  "$(grep -c " wait U13-RESTAMP $R#8663 1f3578d00000: (.idle_min | type) == \"number\" and (.restamp_idle_min | type) == \"number\" and .idle_min < .restamp_idle_min\$" "$C/h/logs/unblock.log")" 1
case "$(tickline "$C")" in
  *" mode=act "*" decisions=1 claimed=0 "*" deferred=0"*" waited=1") ok "W13 the tick line: decisions=1 claimed=0 deferred=0 waited=1" ;;
  *) no "W13 the tick line: decisions=1 claimed=0 deferred=0 waited=1" "$(tickline "$C"); $(head -c 600 "$C/tick.out")" ;;
esac
budget "$C" W13

C=$(mktick w14) || { echo "FAIL: tick setup"; exit 1; }
mode "$C" act; printf '%s\n' "$U4REC" > "$C/fx/lines.jsonl"
tick "$C" UNBLOCK_ACT=1
check "W14 U4 idle 1 (#8829), act: 0 claim POSTs, 0 lane-alert calls" "$(nclaims "$C") $(nalerts "$C")" "0 0"
check "W14 one wait U4-standing-approval line" "$(grep -c " wait U4-standing-approval $R#8829 " "$C/h/logs/unblock.log")" 1
case "$(tickline "$C")" in
  *" waited=1") ok "W14 the tick line has waited=1" ;;
  *) no "W14 the tick line has waited=1" "$(tickline "$C")" ;;
esac
budget "$C" W14

C=$(mktick w15) || { echo "FAIL: tick setup"; exit 1; }
mode "$C" shadow; jq -c '.idle_min = 20' <<<"$RESTAMP" > "$C/fx/lines.jsonl"
tick "$C"
check "W15 RESTAMP idle 20, shadow: 1 claim POST for U13-RESTAMP lead_rerequest" \
  "$(claims "$C" | jq -r '"\(.rule_id) \(.action) \(.decision)"' | tr '\n' ';')" "U13-RESTAMP lead_rerequest act;"
check "W15 no wait line" "$(grep -c ' wait U13-RESTAMP ' "$C/h/logs/unblock.log")" 0
case "$(tickline "$C")" in
  *waited=*) no "W15 no waited= field on the tick line" "$(tickline "$C")" ;;
  *" claimed=1 "*) ok "W15 no waited= field on the tick line" ;;
  *) no "W15 no waited= field on the tick line" "$(tickline "$C"); $(head -c 600 "$C/tick.out")" ;;
esac
budget "$C" W15

check "B every case: 0 gh, curl or model CLI calls" "$(grep -c . "$T/vendor.log")" 0
echo "unblock-rule-wait.bh-8766: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
